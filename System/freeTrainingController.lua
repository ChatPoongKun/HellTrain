(function(triggerId, action, ...)
    local STATE_KEY = "freeTrainingV1.authority"
    local ROUTING_VAR = "helltrainFreeTrainingRouteV1"
    local UI_BODY_VAR = "🔯🔯🔯"
    local UI_POPUP_VAR = "helltrainUiPopupV1"
    local UI_INTERACTION_VAR = "helltrainBattleInteractionV1"
    local UI_READY_VAR = "gameSetupReady"

    local function failure(code, path, message)
        return { ok = false, schemaVersion = 1, errors = { { code = code, path = path, message = message } } }
    end

    local function clone(value, active)
        if type(value) ~= "table" then return value end
        active = active or {}
        if active[value] then error("circular value") end
        active[value] = true
        local result = {}
        for key, item in pairs(value) do result[key] = clone(item, active) end
        active[value] = nil
        return result
    end

    local function deepEqual(left, right, seen)
        if left == right then return true end
        if type(left) ~= type(right) or type(left) ~= "table" then return false end
        seen = seen or {}
        if seen[left] == right then return true end
        seen[left] = right
        for key, value in pairs(left) do if not deepEqual(value, right[key], seen) then return false end end
        for key in pairs(right) do if left[key] == nil then return false end end
        return true
    end

    local function readState(name)
        if type(HostCompat) ~= "table" or type(HostCompat.readState) ~= "function" then
            return nil, failure("state_read_unavailable", "$.host", "상태 읽기 기능을 사용할 수 없습니다.")
        end
        local ok, value = pcall(HostCompat.readState, triggerId, name)
        if not ok then return nil, failure("state_read_failed", "$.state", tostring(value)) end
        return value, nil
    end

    local function writeState(previous, state)
        local current, readError = readState(STATE_KEY)
        if readError then return readError end
        if not deepEqual(current, previous) then
            return failure("concurrent_change", "$.state", "자유조교 상태가 다른 요청에 의해 변경되었습니다.")
        end
        local ok, writeError = pcall(HostCompat.writeState, triggerId, STATE_KEY, clone(state))
        if not ok then return failure("state_write_failed", "$.state", tostring(writeError)) end
        local stored, verifyError = readState(STATE_KEY)
        if verifyError then return verifyError end
        if not deepEqual(stored, state) then
            return failure("state_write_not_persisted", "$.state", "자유조교 상태가 저장되지 않았습니다.")
        end
        return nil
    end

    local function writeVar(name, value)
        local ok, writeError = pcall(HostCompat.writeChatVar, triggerId, name, value)
        if not ok then return failure("chat_var_write_failed", "$.chatVar." .. name, tostring(writeError)) end
        return nil
    end

    local function routingValue(active)
        if type(active) ~= "table" then return "" end
        return json.encode({
            phase = active.phase,
            sessionId = active.sessionId,
            context = active.context,
        })
    end

    local function publishRouting(active)
        return writeVar(ROUTING_VAR, routingValue(active))
    end

    local function readRunAndSetup()
        local run, runError = readState("runProgressionV1.authority")
        if runError then return nil, nil, nil, runError end
        local setup, setupError = readState("gameSetupV1.authority")
        if setupError then return nil, nil, nil, setupError end
        if type(run) ~= "table" or type(setup) ~= "table" then
            return nil, nil, nil, failure("missing_progression", "$.state", "전투 진행 상태를 찾을 수 없습니다.")
        end
        local catalog = runScript(triggerId, "staticData", "loadCatalog")
        if type(catalog) ~= "table" or catalog.ok ~= true then
            return nil, nil, nil, catalog or failure("static_data_failed", "$.staticData", "정적 데이터를 불러오지 못했습니다.")
        end
        local validated = runScript(triggerId, "runProgression", "validate", run, setup, catalog.data)
        if type(validated) ~= "table" or validated.ok ~= true then return nil, nil, nil, validated end
        return validated.state, setup, catalog.data, nil
    end

    local function eligibleData(run)
        local result = runScript(triggerId, "freeTraining", "eligibility", run)
        if type(result) ~= "table" or result.ok ~= true then return nil, result end
        return result, nil
    end

    local function refreshCharacterLore(characterId)
        local report = runScript(triggerId, "characterContextLore", "sync", characterId)
        if type(report) ~= "table" or report.ok ~= true then
            if type(debug) == "function" then debug(1, "characterContextLore.sync failed") end
            return false
        end
        return true
    end

    local function buildCandidates(eligibility)
        local loaded = runScript(triggerId, "staticData", "loadCharacters", eligibility.eligibleIds)
        if type(loaded) ~= "table" or loaded.ok ~= true then return nil, loaded end
        local candidates = {}
        for _, characterId in ipairs(eligibility.eligibleIds) do
            local character = loaded.data.characters[characterId]
            candidates[#candidates + 1] = {
                characterId = characterId,
                name = character.name,
                portraitImage = character.portraitImage or "dummy.png",
                victories = eligibility.victoriesById[characterId],
            }
        end
        table.sort(candidates, function(left, right) return left.name < right.name end)
        return candidates, nil
    end

    local function publishUi(state, candidates)
        local built = runScript(triggerId, "freeTrainingView", "build", state, candidates)
        if type(built) ~= "table" or built.ok ~= true then return built end
        local published = runScript(
            triggerId,
            "dataBridge",
            "_publishCanonical",
            "freeTrainingView",
            built.view,
            function(purpose, name)
                return purpose == "dataBridgeCanonicalV1" and name == "freeTrainingView"
            end
        )
        if type(published) ~= "table" or published.ok ~= true then return published end
        local html = loadLores(triggerId, "freeTraining.html")
        if type(html) ~= "string" or html == "" then
            return failure("missing_lore", "$.lore.freeTraining", "자유조교 화면을 불러오지 못했습니다.")
        end
        for _, item in ipairs({
            { UI_BODY_VAR, html },
            { UI_POPUP_VAR, "" },
            { UI_INTERACTION_VAR, "" },
            { UI_READY_VAR, "ready" },
        }) do
            local writeError = writeVar(item[1], item[2])
            if writeError then return writeError end
        end
        local routeError = publishRouting(state.active)
        if routeError then return routeError end
        if type(refreshGameUi) == "function" then pcall(refreshGameUi, triggerId) end
        return { ok = true, schemaVersion = 1, errors = {}, view = built.view }
    end

    local function open(token)
        local run, _, _, readError = readRunAndSetup()
        if readError then return readError end
        if run.phase ~= "characterSelect" or type(run.characterOffer) ~= "table"
            or token ~= run.characterOffer.interactionToken then
            return failure("stale_character_offer", "$.token", "현재 캐릭터 선택 화면에서 다시 시도해 주세요.")
        end
        local eligibility, eligibilityError = eligibleData(run)
        if eligibilityError then return eligibilityError end
        local previous, stateError = readState(STATE_KEY)
        if stateError then return stateError end
        local transition = runScript(triggerId, "freeTraining", "open", previous, run)
        if type(transition) ~= "table" or transition.ok ~= true then return transition end
        if transition.applied then
            local writeError = writeState(previous, transition.state)
            if writeError then return writeError end
        end
        local candidates, candidateError = buildCandidates(eligibility)
        if candidateError then return candidateError end
        return publishUi(transition.state, candidates)
    end

    local function appendBoundary(characterName, sessionId)
        if type(getFullChat) ~= "function" or type(addChat) ~= "function" then
            return nil, nil, failure("chat_unavailable", "$.chat", "채팅 기능을 사용할 수 없습니다.")
        end
        local sessionNumber = tostring(sessionId):match("(%d+)$") or "?"
        local notice = "[자유조교 시작 · " .. characterName .. " · 제 " .. sessionNumber .. "회] 전투 판정 없이 자유 대화를 시작합니다."
        local chat = getFullChat(triggerId)
        local last = type(chat) == "table" and chat[#chat] or nil
        if type(last) == "table" and last.role == "char" and last.data == notice then
            return #chat - 1, { role = "char", data = notice }, nil
        end
        addChat(triggerId, "char", notice)
        local after = getFullChat(triggerId)
        local appended = type(after) == "table" and after[#after] or nil
        if type(after) ~= "table" or #after ~= #chat + 1 or type(appended) ~= "table"
            or appended.role ~= "char" or appended.data ~= notice then
            return nil, nil, failure("chat_append_failed", "$.chat", "자유조교 시작 경계를 저장하지 못했습니다.")
        end
        return #after - 1, { role = "char", data = notice }, nil
    end

    local function begin(characterId, token)
        local run, setup, catalog, readError = readRunAndSetup()
        if readError then return readError end
        local eligibility, eligibilityError = eligibleData(run)
        if eligibilityError then return eligibilityError end
        local allowed = false
        for _, id in ipairs(eligibility.eligibleIds) do if id == characterId then allowed = true break end end
        if not allowed then return failure("character_not_eligible", "$.characterId", "3회 이상 함락한 캐릭터만 선택할 수 있습니다.") end
        local previous, stateError = readState(STATE_KEY)
        if stateError then return stateError end
        if type(previous) == "table" and type(previous.active) == "table"
            and previous.active.phase == "active" and previous.active.characterId == characterId
            and token == previous.active.returnToken .. ":free:select" then
            local recovered = publishUi(previous, {})
            if recovered.ok and type(syncGameUiTarget) == "function" then pcall(syncGameUiTarget, triggerId) end
            return recovered
        end
        if type(previous) ~= "table" or type(previous.active) ~= "table"
            or previous.active.phase ~= "selecting" or previous.active.interactionToken ~= token then
            return failure("stale_free_training_selection", "$.token", "자유조교 대상을 다시 선택해 주세요.")
        end
        local candidates, candidateError = buildCandidates(eligibility)
        if candidateError then return candidateError end
        local chosen
        for _, item in ipairs(candidates) do if item.characterId == characterId then chosen = item break end end
        if not chosen then return failure("character_load_failed", "$.characterId", "캐릭터 정보를 불러오지 못했습니다.") end
        local lore = runScript(triggerId, "characterContextLore", "sync", characterId)
        if type(lore) ~= "table" or lore.ok ~= true then return lore end
        local sessionId = previous.setupId .. ":free:" .. tostring(previous.nextSessionNumber)
        local startChatIndex, boundary, boundaryError = appendBoundary(chosen.name, sessionId)
        if boundaryError then return boundaryError end
        local journal = runScript(triggerId, "runProgressionView", "buildCharacterJournal", {
            setupState = setup,
            runState = run,
            freeTrainingState = previous,
        }, catalog)
        if type(journal) ~= "table" or journal.ok ~= true then return journal end
        local context = table.concat({
            "현재는 전투가 아닌 자유조교 대화다. 카드, 턴, 저항, 은폐, 승패를 계산하거나 출력하지 마라.",
            "플레이어의 자유 입력에 대상 캐릭터로 자연스럽게 응답하라.",
            "대상: " .. chosen.name,
            "대상 설정과 과거 관계는 현재 채팅의 항상 활성 로컬 로어북을 따른다.",
        }, "\n")
        local transition = runScript(triggerId, "freeTraining", "begin", previous, characterId, token, {
            startChatIndex = startChatIndex,
            boundary = boundary,
            context = context,
            characterName = chosen.name,
            journalSnapshot = journal.view,
        })
        if type(transition) ~= "table" or transition.ok ~= true then return transition end
        local writeError = writeState(previous, transition.state)
        if writeError then return writeError end
        local published = publishUi(transition.state, {})
        if published.ok and type(syncGameUiTarget) == "function" then pcall(syncGameUiTarget, triggerId) end
        return published
    end

    local function returnToSelection(state, sessionId)
        local active = type(state) == "table" and state.active or nil
        if type(active) ~= "table" or active.phase ~= "returning" or active.sessionId ~= sessionId then
            return failure("invalid_return", "$.state.active", "복귀할 자유조교 세션이 아닙니다.")
        end
        local restored = runScript(triggerId, "gameSetupController", "start")
        if type(restored) ~= "table" or restored.ok ~= true then return restored end
        local routeError = publishRouting(active)
        if routeError then return routeError end
        if type(syncGameUiTarget) == "function" then pcall(syncGameUiTarget, triggerId) end
        return { ok = true, schemaVersion = 1, errors = {}, applied = true, releasePending = true }
    end

    local function release(sessionId)
        local previous, stateError = readState(STATE_KEY)
        if stateError then return stateError end
        if type(previous) ~= "table" or previous.active == nil then
            local routeError = publishRouting(nil)
            if routeError then return routeError end
            return { ok = true, schemaVersion = 1, errors = {}, applied = false, stale = true }
        end
        local transition = runScript(triggerId, "freeTraining", "returned", previous, sessionId)
        if type(transition) ~= "table" or transition.ok ~= true then return transition end
        local writeError = writeState(previous, transition.state)
        if writeError then return writeError end
        local routeError = publishRouting(nil)
        if routeError then return routeError end
        return { ok = true, schemaVersion = 1, errors = {}, applied = transition.applied == true }
    end

    local function cancel(token)
        local previous, stateError = readState(STATE_KEY)
        if stateError then return stateError end
        local transition = runScript(triggerId, "freeTraining", "cancel", previous, token)
        if type(transition) ~= "table" or transition.ok ~= true then return transition end
        if transition.applied then
            local writeError = writeState(previous, transition.state)
            if writeError then return writeError end
        end
        local restored = runScript(triggerId, "gameSetupController", "start")
        if type(restored) ~= "table" or restored.ok ~= true then return restored end
        local routeError = publishRouting(nil)
        if routeError then return routeError end
        if type(syncGameUiTarget) == "function" then pcall(syncGameUiTarget, triggerId) end
        return restored
    end

    local function finish(sessionId, token, skipSummary)
        local previous, stateError = readState(STATE_KEY)
        if stateError then return stateError end
        local active = type(previous) == "table" and previous.active or nil
        if type(active) ~= "table" or active.sessionId ~= sessionId then
            return failure("stale_finish_request", "$.token", "이미 종료되었거나 오래된 자유조교 세션입니다.")
        end
        local closing, transcript
        if active.phase == "active" and active.interactionToken == token then
            if type(stopChat) == "function" then pcall(stopChat, triggerId) end
            local chat = getFullChat(triggerId)
            local extracted = runScript(triggerId, "freeTrainingSummary", "extract", chat, active)
            if type(extracted) == "table" and extracted.ok == true then
                transcript = { messages = extracted.messages, endChatIndex = extracted.endChatIndex }
            else
                transcript = { messages = {}, endChatIndex = #chat - 1, boundaryError = true }
            end
            closing = runScript(triggerId, "freeTraining", "close", previous, sessionId, transcript)
            if type(closing) ~= "table" or closing.ok ~= true then return closing end
            local writeError = writeState(previous, closing.state)
            if writeError then return writeError end
            local routeError = publishRouting(closing.state.active)
            if routeError then
                pcall(function() writeState(closing.state, previous) end)
                return routeError
            end
            local closingView = publishUi(closing.state, {})
            if type(closingView) ~= "table" or closingView.ok ~= true then return closingView end
        elseif skipSummary == true and active.phase == "closing" and active.interactionToken == token then
            closing = { state = previous }
            transcript = type(active.frozenTranscript) == "table"
                and active.frozenTranscript or { messages = {}, boundaryError = true }
        else
            return failure("stale_finish_request", "$.token", "이미 종료되었거나 오래된 자유조교 세션입니다.")
        end
        local summary
        if skipSummary == true then
            summary = { status = "failed", text = "요약 없이 자유조교를 종료했습니다.", truncated = false, reason = "사용자가 요약을 생략했습니다." }
        elseif transcript.boundaryError then
            summary = { status = "failed", text = "자유조교 내용의 요약을 생성하지 못했습니다.", truncated = false, reason = "세션 시작 경계를 찾을 수 없습니다." }
        else
            summary = runScript(triggerId, "freeTrainingSummary", "generate", active.characterName, transcript.messages)
            if type(summary) ~= "table" or summary.ok ~= true then
                summary = { status = "failed", text = "자유조교 내용의 요약을 생성하지 못했습니다.", truncated = false, reason = "요약 모듈 오류" }
            end
        end
        local finished = runScript(triggerId, "freeTraining", "finish", closing.state, sessionId, summary)
        if type(finished) ~= "table" or finished.ok ~= true then return finished end
        local writeError = writeState(closing.state, finished.state)
        if writeError then
            local current = readState(STATE_KEY)
            for _, record in ipairs(type(current) == "table" and current.records or {}) do
                if record.sessionId == sessionId then
                    return { ok = true, schemaVersion = 1, errors = {}, applied = false, stale = true }
                end
            end
            return writeError
        end
        publishRouting(finished.state.active)
        refreshCharacterLore(active.characterId)
        return returnToSelection(finished.state, sessionId)
    end

    local function retrySummary(sessionId)
        local previous, stateError = readState(STATE_KEY)
        if stateError then return stateError end
        if type(previous) ~= "table" or previous.active ~= nil then
            return failure("retry_not_available", "$.state", "자유조교 중에는 기록 요약을 재시도할 수 없습니다.")
        end
        local record
        for _, item in ipairs(previous.records or {}) do if item.sessionId == sessionId then record = item break end end
        if type(record) ~= "table" or record.summaryStatus ~= "failed" or type(record.frozenTranscript) ~= "table" then
            return failure("retry_not_available", "$.sessionId", "재시도할 요약 자료가 없습니다.")
        end
        local loaded = runScript(triggerId, "staticData", "loadCharacters", { record.characterId })
        if type(loaded) ~= "table" or loaded.ok ~= true then return loaded end
        local character = loaded.data.characters[record.characterId]
        local summary = runScript(triggerId, "freeTrainingSummary", "generate", character.name, record.frozenTranscript.messages)
        if type(summary) ~= "table" or summary.ok ~= true
            or (summary.status ~= "complete" and summary.status ~= "empty") then
            return failure("summary_retry_failed", "$.summary", "요약을 다시 생성하지 못했습니다.")
        end
        local transition = runScript(triggerId, "freeTraining", "retrySummary", previous, sessionId, summary)
        if type(transition) ~= "table" or transition.ok ~= true then return transition end
        local writeError = writeState(previous, transition.state)
        if writeError then return writeError end
        local runState = readState("runProgressionV1.authority")
        local battleState = readState("battleRuntimeV1.authority")
        if type(runState) == "table" and runState.phase == "battleReady"
            and type(battleState) == "table" and battleState.status == "active"
            and type(battleState.character) == "table"
            and battleState.character.characterId == record.characterId then
            refreshCharacterLore(record.characterId)
        end
        pcall(runScript, triggerId, "캐릭터 프로필", record.characterId)
        if type(refreshGameUi) == "function" then pcall(refreshGameUi, triggerId) end
        return { ok = true, schemaVersion = 1, errors = {}, applied = true }
    end

    local function restore()
        local state, stateError = readState(STATE_KEY)
        if stateError then return stateError end
        if type(state) ~= "table" or state.active == nil then
            local restored = runScript(triggerId, "gameSetupController", "start")
            if type(restored) ~= "table" or restored.ok ~= true then return restored end
            local routeError = publishRouting(nil)
            if routeError then return routeError end
            return restored
        end
        if state.active.phase == "returning" then return returnToSelection(state, state.active.sessionId) end
        if state.active.phase == "closing" then
            local active = state.active
            local transcript = type(active.frozenTranscript) == "table" and active.frozenTranscript or { messages = {} }
            local summary = runScript(triggerId, "freeTrainingSummary", "generate", active.characterName, transcript.messages or {})
            if type(summary) ~= "table" or summary.ok ~= true then
                summary = { status = "failed", text = "자유조교 내용의 요약을 생성하지 못했습니다.", truncated = false, reason = "요약 복구 실패" }
            end
            local finished = runScript(triggerId, "freeTraining", "finish", state, active.sessionId, summary)
            if type(finished) ~= "table" or finished.ok ~= true then return finished end
            local writeError = writeState(state, finished.state)
            if writeError then return writeError end
            publishRouting(finished.state.active)
            refreshCharacterLore(active.characterId)
            return returnToSelection(finished.state, active.sessionId)
        end
        local candidates = {}
        if state.active.phase == "selecting" then
            local run, _, _, readError = readRunAndSetup()
            if readError then return readError end
            local eligibility, eligibilityError = eligibleData(run)
            if eligibilityError then return eligibilityError end
            local candidateError
            candidates, candidateError = buildCandidates(eligibility)
            if candidateError then return candidateError end
        end
        return publishUi(state, candidates)
    end

    local args = { ... }
    if action == "open" then return open(args[1]) end
    if action == "begin" then return begin(args[1], args[2]) end
    if action == "cancel" then return cancel(args[1]) end
    if action == "finish" then return finish(args[1], args[2], false) end
    if action == "skipSummary" then return finish(args[1], args[2], true) end
    if action == "retrySummary" then return retrySummary(args[1]) end
    if action == "restore" then return restore() end
    if action == "release" then return release(args[1]) end
    return failure("unknown_action", "$.action", "지원하지 않는 자유조교 controller 작업입니다: " .. tostring(action))
end)
