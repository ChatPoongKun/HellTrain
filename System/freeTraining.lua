(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local KIND = "freeTrainingV1"

    local function errorItem(code, path, message)
        return { code = code, path = path, message = message }
    end

    local function failure(code, path, message)
        return { ok = false, schemaVersion = SCHEMA_VERSION, errors = { errorItem(code, path, message) } }
    end

    local function success(fields)
        local result = { ok = true, schemaVersion = SCHEMA_VERSION, errors = {} }
        for key, value in pairs(fields or {}) do result[key] = value end
        return result
    end

    local function isInteger(value, minimum)
        return type(value) == "number" and value == value and value % 1 == 0
            and (minimum == nil or value >= minimum)
    end

    local function isAsciiId(value)
        return type(value) == "string" and value:match("^[a-z][a-z0-9_]*$") ~= nil
    end

    local function clone(value, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then return value end
        if valueType == "number" then
            if value ~= value or value == math.huge or value == -math.huge then error("non-finite number") end
            return value
        end
        if valueType ~= "table" or getmetatable(value) ~= nil then error("non-json value") end
        active = active or {}
        if active[value] then error("circular value") end
        active[value] = true
        local result = {}
        for key, item in pairs(value) do
            if type(key) ~= "string" and not isInteger(key, 1) then error("invalid json key") end
            result[key] = clone(item, active)
        end
        active[value] = nil
        return result
    end

    local function cloneSafe(value, path)
        local ok, result = pcall(clone, value)
        if not ok then return nil, errorItem("invalid_json", path, "JSON 저장 형식이 아닙니다: " .. tostring(result)) end
        return result, nil
    end

    local function eligible(runState)
        if type(runState) ~= "table" then
            return failure("invalid_run_state", "$.runState", "진행 상태가 필요합니다.")
        end
        local victoriesById, seen = {}, {}
        if runState.phase == "characterSelect" and type(runState.sessions) == "table" then
            for _, record in ipairs(runState.sessions) do
                if type(record) == "table" and record.status == "victory"
                    and type(record.battleId) == "string" and not seen[record.battleId]
                    and isAsciiId(record.characterId) then
                    seen[record.battleId] = true
                    victoriesById[record.characterId] = (victoriesById[record.characterId] or 0) + 1
                end
            end
        end
        local ids = {}
        for characterId, count in pairs(victoriesById) do
            if count >= 3 then ids[#ids + 1] = characterId end
        end
        table.sort(ids)
        return success({ eligibleIds = ids, victoriesById = victoriesById })
    end

    local function validate(state)
        local copy, copyError = cloneSafe(state, "$.state")
        if copyError then return { ok = false, schemaVersion = SCHEMA_VERSION, errors = { copyError } } end
        if type(copy) ~= "table" or copy.kind ~= KIND or copy.schemaVersion ~= SCHEMA_VERSION
            or type(copy.setupId) ~= "string" or copy.setupId == ""
            or not isInteger(copy.nextSessionNumber, 1) or type(copy.records) ~= "table" then
            return failure("invalid_state", "$.state", "자유조교 상태 형식이 올바르지 않습니다.")
        end
        local seen = {}
        for index, record in ipairs(copy.records) do
            if type(record) ~= "table" or type(record.sessionId) ~= "string" or record.sessionId == ""
                or not isAsciiId(record.characterId) or not isInteger(record.number, 1)
                or (record.summaryStatus ~= "complete" and record.summaryStatus ~= "failed" and record.summaryStatus ~= "empty")
                or type(record.summary) ~= "string" or record.summary == "" or type(record.truncated) ~= "boolean" then
                return failure("invalid_record", "$.state.records[" .. index .. "]", "자유조교 기록 형식이 올바르지 않습니다.")
            end
            if seen[record.sessionId] then
                return failure("duplicate_session", "$.state.records[" .. index .. "].sessionId", "같은 자유조교 세션이 중복되었습니다.")
            end
            seen[record.sessionId] = true
        end
        if copy.active ~= nil then
            local active = copy.active
            if type(active) ~= "table"
                or (active.phase ~= "selecting" and active.phase ~= "active"
                    and active.phase ~= "closing" and active.phase ~= "returning")
                or type(active.interactionToken) ~= "string" or active.interactionToken == "" then
                return failure("invalid_active_session", "$.state.active", "진행 중인 자유조교 상태가 올바르지 않습니다.")
            end
            if active.phase ~= "selecting" and (type(active.sessionId) ~= "string"
                or not isAsciiId(active.characterId) or not isInteger(active.number, 1)) then
                return failure("invalid_active_session", "$.state.active", "진행 중인 자유조교 식별자가 올바르지 않습니다.")
            end
        end
        return success({ state = copy })
    end

    local function baseState(previous, runState)
        if type(runState) ~= "table" or type(runState.setupId) ~= "string" then
            return nil, failure("invalid_run_state", "$.runState", "setupId가 있는 진행 상태가 필요합니다.")
        end
        if previous == nil or previous.setupId ~= runState.setupId then
            return {
                kind = KIND,
                schemaVersion = SCHEMA_VERSION,
                setupId = runState.setupId,
                nextSessionNumber = 1,
                records = {},
            }, nil
        end
        local checked = validate(previous)
        if not checked.ok then return nil, checked end
        return checked.state, nil
    end

    local function open(previous, runState)
        local eligibility = eligible(runState)
        if not eligibility.ok then return eligibility end
        if runState.phase ~= "characterSelect" or #eligibility.eligibleIds == 0 then
            return failure("free_training_locked", "$.runState", "자유조교 진입 조건을 충족하지 못했습니다.")
        end
        local state, stateError = baseState(previous, runState)
        if stateError then return stateError end
        local token = runState.characterOffer and runState.characterOffer.interactionToken
        if type(token) ~= "string" or token == "" then
            return failure("missing_return_token", "$.runState.characterOffer.interactionToken", "복귀할 캐릭터 선택 token이 없습니다.")
        end
        if state.active ~= nil then
            return success({ state = state, applied = false, stale = true })
        end
        state.active = {
            phase = "selecting",
            returnToken = token,
            interactionToken = token .. ":free:select",
        }
        return success({ state = state, applied = true, stale = false })
    end

    local function begin(stateInput, characterId, interactionToken, entryContext)
        local checked = validate(stateInput)
        if not checked.ok then return checked end
        local state, active = checked.state, checked.state.active
        if type(active) ~= "table" or active.phase ~= "selecting" then
            return failure("invalid_phase", "$.state.active.phase", "대상 선택 단계가 아닙니다.")
        end
        if interactionToken ~= active.interactionToken then
            return success({ state = state, applied = false, stale = true })
        end
        if not isAsciiId(characterId) or type(entryContext) ~= "table" then
            return failure("invalid_begin_request", "$.request", "자유조교 대상과 진입 자료가 올바르지 않습니다.")
        end
        local context, contextError = cloneSafe(entryContext, "$.entryContext")
        if contextError then return { ok = false, schemaVersion = SCHEMA_VERSION, errors = { contextError } } end
        local number = state.nextSessionNumber
        local sessionId = state.setupId .. ":free:" .. tostring(number)
        state.nextSessionNumber = number + 1
        state.active = {
            phase = "active",
            sessionId = sessionId,
            number = number,
            characterId = characterId,
            returnToken = active.returnToken,
            interactionToken = sessionId .. ":active",
            startChatIndex = context.startChatIndex,
            boundary = context.boundary,
            context = context.context,
            characterName = context.characterName,
            journalSnapshot = context.journalSnapshot,
        }
        return success({ state = state, applied = true, stale = false, sessionId = sessionId })
    end

    local function cancel(stateInput, interactionToken)
        local checked = validate(stateInput)
        if not checked.ok then return checked end
        local state, active = checked.state, checked.state.active
        if type(active) ~= "table" or active.phase ~= "selecting" then
            return failure("invalid_phase", "$.state.active.phase", "대상 선택 단계가 아닙니다.")
        end
        if active.interactionToken ~= interactionToken then
            return success({ state = state, applied = false, stale = true })
        end
        state.active = nil
        return success({ state = state, applied = true, stale = false })
    end

    local function close(stateInput, sessionId, frozenTranscript)
        local checked = validate(stateInput)
        if not checked.ok then return checked end
        local state, active = checked.state, checked.state.active
        if type(active) ~= "table" or active.sessionId ~= sessionId then
            return success({ state = state, applied = false, stale = true })
        end
        if active.phase == "closing" or active.phase == "returning" then
            return success({ state = state, applied = false, stale = true })
        end
        if active.phase ~= "active" then
            return failure("invalid_phase", "$.state.active.phase", "종료할 자유조교 세션이 아닙니다.")
        end
        local transcript, transcriptError = cloneSafe(frozenTranscript, "$.frozenTranscript")
        if transcriptError then return { ok = false, schemaVersion = SCHEMA_VERSION, errors = { transcriptError } } end
        active.phase = "closing"
        active.interactionToken = sessionId .. ":closing"
        active.frozenTranscript = transcript
        return success({ state = state, applied = true, stale = false })
    end

    local function finish(stateInput, sessionId, summaryResult)
        local checked = validate(stateInput)
        if not checked.ok then return checked end
        local state, active = checked.state, checked.state.active
        if type(active) ~= "table" or active.sessionId ~= sessionId then
            return success({ state = state, applied = false, stale = true })
        end
        if active.phase == "returning" then
            return success({ state = state, applied = false, stale = true })
        end
        if active.phase ~= "closing" or type(summaryResult) ~= "table" then
            return failure("invalid_finish_request", "$.request", "요약 확정 요청이 올바르지 않습니다.")
        end
        local status = summaryResult.status
        if status ~= "complete" and status ~= "failed" and status ~= "empty" then
            return failure("invalid_summary_status", "$.summary.status", "요약 상태가 올바르지 않습니다.")
        end
        if type(summaryResult.text) ~= "string" or summaryResult.text == "" then
            return failure("invalid_summary_text", "$.summary.text", "요약 내용이 비어 있습니다.")
        end
        local record = {
            sessionId = sessionId,
            number = active.number,
            characterId = active.characterId,
            startChatIndex = active.startChatIndex,
            endChatIndex = active.frozenTranscript.endChatIndex,
            summary = tostring(summaryResult.text or ""),
            summaryStatus = status,
            truncated = summaryResult.truncated == true,
        }
        if status == "failed" then
            record.reason = tostring(summaryResult.reason or "요약 생성 실패")
            record.frozenTranscript = clone(active.frozenTranscript)
        end
        local found = false
        for _, existing in ipairs(state.records) do
            if existing.sessionId == sessionId then found = true break end
        end
        if not found then state.records[#state.records + 1] = record end
        active.phase = "returning"
        active.interactionToken = sessionId .. ":returning"
        return success({ state = state, applied = not found, stale = found })
    end

    local function returned(stateInput, sessionId)
        local checked = validate(stateInput)
        if not checked.ok then return checked end
        local state, active = checked.state, checked.state.active
        if active == nil then return success({ state = state, applied = false, stale = true }) end
        if active.sessionId ~= sessionId or active.phase ~= "returning" then
            return failure("invalid_return", "$.state.active", "복귀할 자유조교 세션이 아닙니다.")
        end
        state.active = nil
        return success({ state = state, applied = true, stale = false })
    end

    local function retrySummary(stateInput, sessionId, summaryResult)
        local checked = validate(stateInput)
        if not checked.ok then return checked end
        local state = checked.state
        for _, record in ipairs(state.records) do
            if record.sessionId == sessionId then
                if record.summaryStatus ~= "failed" then
                    return success({ state = state, applied = false, stale = true })
                end
                if type(summaryResult) ~= "table"
                    or (summaryResult.status ~= "complete" and summaryResult.status ~= "empty")
                    or type(summaryResult.text) ~= "string" or summaryResult.text == "" then
                    return failure("summary_retry_failed", "$.summary", "새 요약을 확정할 수 없습니다.")
                end
                record.summary = tostring(summaryResult.text or "")
                record.summaryStatus = summaryResult.status
                record.truncated = summaryResult.truncated == true
                record.reason = nil
                record.frozenTranscript = nil
                return success({ state = state, applied = true, stale = false })
            end
        end
        return failure("unknown_session", "$.sessionId", "자유조교 기록을 찾을 수 없습니다.")
    end

    local args = { ... }
    if action == "eligibility" then return eligible(args[1]) end
    if action == "validate" then return validate(args[1]) end
    if action == "open" then return open(args[1], args[2]) end
    if action == "begin" then return begin(args[1], args[2], args[3], args[4]) end
    if action == "cancel" then return cancel(args[1], args[2]) end
    if action == "close" then return close(args[1], args[2], args[3]) end
    if action == "finish" then return finish(args[1], args[2], args[3]) end
    if action == "returned" then return returned(args[1], args[2]) end
    if action == "retrySummary" then return retrySummary(args[1], args[2], args[3]) end
    return failure("unknown_action", "$.action", "지원하지 않는 자유조교 작업입니다: " .. tostring(action))
end)
