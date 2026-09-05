(function()
local function alertTurnFailure(triggerId, detail)
    if type(alertError) == "function" then
        pcall(
            alertError,
            triggerId,
            "치명적인 오류로 턴을 진행할 수 없습니다.\n\n"
                .. detail
                .. "\n\n위 오류 내용을 복사하여 개발자에게 제보해 주세요."
        )
    end
end

local function controllerSucceeded(triggerId, label, report)
    if type(report) ~= "table" then
        local detail = label .. ": battleController가 결과를 반환하지 않았습니다."
        debug(1, detail)
        alertTurnFailure(triggerId, detail)
        return false
    end
    if report.ok == true then
        return true
    end

    local errors = type(report.errors) == "table" and report.errors or {}
    if #errors == 0 then
        local detail = label .. ": battleController가 상세 오류 없이 실패했습니다."
        debug(1, detail)
        alertTurnFailure(triggerId, detail)
        return false
    end
    local details = {}
    for _, item in ipairs(errors) do
        local detail = nil
        if type(item) == "table" then
            detail = label
                .. ": [" .. tostring(item.code or "error") .. "] "
                .. tostring(item.message or "알 수 없는 오류")
                .. " (" .. tostring(item.path or "$") .. ")"
        else
            detail = label .. ": " .. tostring(item)
        end
        debug(1, detail)
        details[#details + 1] = detail
    end
    alertTurnFailure(triggerId, table.concat(details, "\n"))
    return false
end

local UI_BODY_VAR = "🔯🔯🔯"
local UI_SHELL_VAR = "helltrainUiShellV1"
local UI_POPUP_VAR = "helltrainUiPopupV1"
local UI_INTERACTION_VAR = "helltrainBattleInteractionV1"
local UI_TARGET_INDEX_VAR = "helltrainUiTargetIndexV1"
local UI_READY_VAR = "gameSetupReady"
local APPROACH_RETRY_VAR = "helltrainApproachRetryV1"
local RUN_PROGRESSION_AUTHORITY_KEY = "runProgressionV1.authority"
local APPROACH_REQUEST_ATTEMPTS = 1
local UI_CONTAINER_OPEN = [[<div class="helltrain-dynamic-ui" aria-label="게임 화면">]]
local UI_CONTAINER_EMPTY = UI_CONTAINER_OPEN .. "</div>"
local UI_INTERACTION_MARKER = "<!--HELLTRAIN_BATTLE_INTERACTION_V1-->"
-- 리롤이 직전 턴 경계에서 멈추도록 marker 메시지를 숨겨서 유지한다.
local TURN_SUBMIT_MARKER = "@@HELLTRAIN_TURN_SUBMIT_V1@@"
local TURN_SUBMIT_HIDDEN_MARKUP = [[<style>
[data-chat-index]:has([data-helltrain-turn-submit]) { display: none !important; }
</style>
<span data-helltrain-turn-submit hidden aria-hidden="true"></span>]]
local SETUP_START_MARKUP = [[<section class="helltrain-setup" aria-labelledby="helltrain-start-title">
<p class="helltrain-setup-label">BOARDING PROTOCOL</p>
<h2 class="helltrain-setup-title" id="helltrain-start-title">지옥철에 탑승하시겠습니까?</h2>
<p class="helltrain-setup-copy" id="helltrain-start-copy">게임을 시작하면 초기 상태를 만들고, 덱을 구성하기 위한 카드 드래프트를 엽니다.</p>
<button class="helltrain-start" type="button" risu-btn="init|start" aria-describedby="helltrain-start-copy">게임 시작</button>
</section>]]
local APPROACH_PROCESSING_MARKUP = [[<style>
.helltrain-approach-processing,
.helltrain-approach-processing * {
box-sizing: border-box;
}
.helltrain-approach-processing {
--approach-bg: #0d0c12;
--approach-panel: rgba(22, 19, 28, .96);
--approach-line: rgba(220, 204, 176, .2);
--approach-text: #ece6dc;
--approach-muted: #afa69d;
--approach-accent: #e06a70;
display: grid;
width: min(100%, 600px);
min-height: 180px;
margin: 8px auto;
place-items: center;
overflow: hidden;
border: 1px solid var(--approach-line);
border-radius: 16px;
background:
radial-gradient(circle at 50% 0%, rgba(224, 106, 112, .12), transparent 48%),
var(--approach-bg);
color: var(--approach-text);
box-shadow: 0 18px 48px rgba(0, 0, 0, .32);
font-family: Pretendard, "Noto Sans KR", system-ui, sans-serif;
}
.helltrain-approach-processing__body {
display: flex;
align-items: center;
flex-direction: column;
padding: 34px 24px;
text-align: center;
}
.helltrain-approach-processing__spinner {
position: relative;
width: 34px;
height: 34px;
margin-bottom: 16px;
border: 2px solid rgba(255, 255, 255, .1);
border-top-color: var(--approach-accent);
border-radius: 50%;
animation: helltrain-approach-spin .85s linear infinite;
}
.helltrain-approach-processing__spinner::after {
position: absolute;
inset: 6px;
border: 1px solid rgba(224, 106, 112, .22);
border-radius: inherit;
content: "";
}
.helltrain-approach-processing__label {
margin: 0;
font-size: 15px;
font-weight: 850;
letter-spacing: .04em;
}
.helltrain-approach-processing__dot {
display: inline-block;
animation: helltrain-approach-dot 1.2s ease-in-out infinite;
}
.helltrain-approach-processing__dot:nth-child(2) {
animation-delay: .15s;
}
.helltrain-approach-processing__dot:nth-child(3) {
animation-delay: .3s;
}
.helltrain-approach-processing__copy {
margin: 9px 0 0;
color: var(--approach-muted);
font-size: 11px;
}
@keyframes helltrain-approach-spin {
to { transform: rotate(360deg); }
}
@keyframes helltrain-approach-dot {
0%, 70%, 100% { opacity: .28; transform: translateY(0); }
35% { opacity: 1; transform: translateY(-2px); }
}
@media (prefers-reduced-motion: reduce) {
.helltrain-approach-processing__spinner,
.helltrain-approach-processing__dot {
animation: none;
}
}
</style>
<section class="helltrain-approach-processing" role="status" aria-live="polite" aria-label="처리중...">
<div class="helltrain-approach-processing__body">
<span class="helltrain-approach-processing__spinner" aria-hidden="true"></span>
<p class="helltrain-approach-processing__label">처리중<span aria-hidden="true"><span class="helltrain-approach-processing__dot">.</span><span class="helltrain-approach-processing__dot">.</span><span class="helltrain-approach-processing__dot">.</span></span></p>
<p class="helltrain-approach-processing__copy">{{approachCharacterName}}에게 접근하고 있습니다.</p>
</div>
</section>]]

local function readUiFragment(triggerId, name)
    if type(getChatVar) ~= "function" then
        return ""
    end
    local ok, value = pcall(getChatVar, triggerId, name)
    return ok and type(value) == "string" and value ~= "null" and value or ""
end

local function parseUiTargetIndex(rawIndex)
    local index = tonumber(rawIndex)
    if index == nil or index % 1 ~= 0 or index < -1 then
        return nil
    end
    return index
end

local function latestCharacterIndex(triggerId)
    if type(getFullChat) ~= "function" then
        error("getFullChat host function is unavailable")
    end
    local readOk, chat = pcall(getFullChat, triggerId)
    if not readOk or type(chat) ~= "table" then
        error("failed to read chat for UI target: " .. tostring(chat))
    end
    for index = #chat, 1, -1 do
        if type(chat[index]) == "table" and chat[index].role == "char" then
            return index - 1
        end
    end
    return -1
end

local appendChatVerified

local function reloadGameUiAt(triggerId, index)
    if type(reloadChat) == "function" then
        local targetedOk, targetedError = pcall(reloadChat, triggerId, index)
        if targetedOk then
            return true
        end
        debug(2, "targeted UI reload failed: " .. tostring(targetedError))
    end
    if type(reloadDisplay) ~= "function" then
        error("reloadChat/reloadDisplay host functions are unavailable")
    end
    reloadDisplay(triggerId)
    return true
end

-- 초기 진입 전에는 first message(-1), 이후에는 UI가 붙은 캐릭터 메시지만 다시 그린다.
function refreshGameUi(triggerId)
    local rawIndex = readUiFragment(triggerId, UI_TARGET_INDEX_VAR)
    local index = parseUiTargetIndex(rawIndex)
    if index == nil then
        index = -1
        if rawIndex ~= "" then
            debug(2, "invalid UI target index; falling back to first message: " .. tostring(rawIndex))
        end
    end
    return reloadGameUiAt(triggerId, index)
end

-- UI를 붙일 메시지를 바꾸고 이전/새 대상만 다시 그린다. nil이면 최신 char를 찾는다.
function syncGameUiTarget(triggerId, targetIndex)
    if targetIndex == nil then
        targetIndex = latestCharacterIndex(triggerId)
    end
    if type(targetIndex) ~= "number"
        or targetIndex % 1 ~= 0
        or targetIndex < -1 then
        error("invalid UI target index: " .. tostring(targetIndex))
    end
    if type(HostCompat) ~= "table" or type(HostCompat.writeChatVar) ~= "function" then
        error("chat variable write compatibility function is unavailable")
    end

    local rawPreviousIndex = readUiFragment(triggerId, UI_TARGET_INDEX_VAR)
    local previousIndex = parseUiTargetIndex(rawPreviousIndex)
    if previousIndex == nil then
        previousIndex = -1
    end
    local encodedTargetIndex = tostring(targetIndex)
    if rawPreviousIndex ~= encodedTargetIndex then
        HostCompat.writeChatVar(triggerId, UI_TARGET_INDEX_VAR, encodedTargetIndex)
    end

    -- 새 대상을 먼저 저장해야 이전 메시지의 editDisplay가 UI를 제거한다.
    if previousIndex ~= targetIndex and type(reloadChat) == "function" then
        local retiredOk, retiredError = pcall(reloadChat, triggerId, previousIndex)
        if not retiredOk then
            debug(2, "previous UI target reload failed: " .. tostring(retiredError))
        end
    end
    reloadGameUiAt(triggerId, targetIndex)
    return targetIndex
end

local function writeUiFragment(triggerId, name, value)
    if type(HostCompat) ~= "table" or type(HostCompat.writeChatVar) ~= "function" then
        error("chat variable write compatibility function is unavailable")
    end
    HostCompat.writeChatVar(triggerId, name, value)
end

local function readApproachRetry(triggerId)
    if type(getChatVar) ~= "function" then
        error("getChatVar host function is unavailable")
    end
    local readOk, value = pcall(getChatVar, triggerId, APPROACH_RETRY_VAR)
    if not readOk then
        error("failed to read approach retry state: " .. tostring(value))
    end
    if value == nil or value == "" or value == "null" then
        return nil, nil
    end
    if type(value) ~= "string" then
        error("invalid approach retry state")
    end
    local separator = string.find(value, "|", 1, true)
    local phase = separator and string.sub(value, 1, separator - 1) or nil
    local characterId = separator and string.sub(value, separator + 1) or nil
    if (phase ~= "pending" and phase ~= "generated")
        or type(characterId) ~= "string"
        or string.match(characterId, "^[a-z][a-z0-9_]*$") == nil then
        error("invalid approach retry state")
    end
    return phase, characterId
end

local function writeApproachRetryVerified(triggerId, phase, characterId)
    local value = ""
    if phase ~= nil then
        value = phase .. "|" .. characterId
    end
    writeUiFragment(triggerId, APPROACH_RETRY_VAR, value)
end

local function escapeApproachName(name)
    return (name:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function showApproachProcessing(triggerId, characterName)
    local markup = APPROACH_PROCESSING_MARKUP:gsub("{{approachCharacterName}}", function()
        return escapeApproachName(characterName)
    end)
    writeUiFragment(triggerId, UI_BODY_VAR, markup)
    writeUiFragment(triggerId, UI_POPUP_VAR, "")
    writeUiFragment(triggerId, UI_READY_VAR, "ready")
    refreshGameUi(triggerId)
end

local function selectedApproachCharacter(triggerId, report, characterId)
    local selected = type(report) == "table"
        and type(report.view) == "table"
        and report.view.selectedCharacter
        or nil
    local name = type(selected) == "table" and selected.name or nil
    local profile = selected

    local staticOk, staticReport = pcall(
        runScript,
        triggerId,
        "staticData",
        "loadAll"
    )
    if staticOk
        and type(staticReport) == "table"
        and staticReport.ok == true
        and type(staticReport.data) == "table"
        and type(staticReport.data.characters) == "table"
        and type(staticReport.data.characters[characterId]) == "table" then
        profile = staticReport.data.characters[characterId]
        if type(profile.name) == "string" and profile.name ~= "" then
            name = profile.name
        end
    end

    if type(name) ~= "string" or name == "" then
        name = characterId
    end
    return name, profile
end

local function pastApproachEncounters(triggerId, report, characterId)
    local runState = type(report) == "table"
        and type(report.state) == "table"
        and report.state.kind == "runProgressionV1"
        and report.state
        or nil
    if runState == nil
        and type(HostCompat) == "table"
        and type(HostCompat.readState) == "function" then
        local readOk, stored = pcall(HostCompat.readState, triggerId, RUN_PROGRESSION_AUTHORITY_KEY)
        if readOk and type(stored) == "table" and stored.kind == "runProgressionV1" then
            runState = stored
        end
    end

    local encounters = {}
    for sessionNumber, session in ipairs(
        type(runState) == "table" and type(runState.sessions) == "table" and runState.sessions or {}
    ) do
        if type(session) == "table" and session.characterId == characterId then
            encounters[#encounters + 1] = {
                sessionNumber = sessionNumber,
                result = session.status,
                reasonCode = session.reasonCode,
                turnNumber = session.turnNumber,
                turnLimit = session.turnLimit,
                finalStealth = session.finalStealth,
                finalResistance = session.finalResistance,
                transit = session.transit,
            }
        end
    end
    return encounters
end

local function encodeApproachData(value, fallback)
    if type(value) == "table" and type(json) == "table" and type(json.encode) == "function" then
        local encodeOk, result = pcall(json.encode, value)
        if encodeOk and type(result) == "string" then return result end
    end
    return fallback
end

local function buildApproachPrompt(characterName, profile, encounters)
    local encodedProfile = encodeApproachData(profile, "{}")
    local encodedEncounters = encodeApproachData(encounters, "[]")
    return {
        {
            role = "system",
            content = table.concat({
                "당신은 성인용 한국어 다크 픽션 롤플레이의 장면 서술자다.",
                "무한히 반복되는 지하철 안에서 플레이어가 선택한 성인 캐릭터에게 다가가는 순간을 2~4문단으로 묘사하라.",
                "장면은 플레이어의 시야가 갑자기 검게 끊기는 순간으로 시작하라.",
                "시야가 돌아오면 선택한 대상 캐릭터가 바로 눈앞에 나타나 있는 모습을 분명히 묘사하라.",
                "암전과 대상의 등장은 이 접근 장면에서 한 번만 묘사하고, 이후 전투 턴에서 반복하지 마라.",
                "경찰 연행이나 패배는 이 접근 장면에서 임의로 추론하거나 묘사하지 마라.",
                "캐릭터의 성격과 배경을 지키고, 아직 카드·수치·전투 UI나 게임 규칙은 언급하지 마라.",
                "플레이어가 입력하지 않은 추가 행동·대사·생각은 만들어내지 마라.",
                "선택한 캐릭터의 자연스러운 행동과 반응, 객실의 분위기에 집중하라.",
                "과거 조우 정보가 있으면 캐릭터는 플레이어를 분명히 알아보고, 이전 결과에 맞는 기억과 태도를 자연스럽게 드러내라. 정보가 없으면 초면으로 묘사하라.",
                "과거 결과의 victory는 플레이어가 캐릭터의 저항을 무너뜨린 경우이고, defeat는 캐릭터가 플레이어를 물리친 경우다.",
                "과거 조우 정보의 내부 ID와 수치는 직접 나열하지 말고 관계의 기억으로만 반영하라.",
                "대상 캐릭터: " .. characterName,
                "캐릭터 자료(JSON): " .. encodedProfile,
                "과거 조우 정보(JSON): " .. encodedEncounters,
            }, "\n"),
        },
        {
            role = "user",
            content = characterName .. "에게 접근한다.",
        },
    }
end

appendChatVerified = function(triggerId, role, content)
    if type(getFullChat) ~= "function" or type(addChat) ~= "function" then
        error("getFullChat/addChat host functions are unavailable")
    end
    local before = getFullChat(triggerId)
    if type(before) ~= "table" then
        error("failed to read chat before append")
    end
    addChat(triggerId, role, content)
    local after = getFullChat(triggerId)
    local appended = type(after) == "table" and after[#after] or nil
    if type(after) ~= "table"
        or #after ~= #before + 1
        or type(appended) ~= "table"
        or appended.role ~= role
        or appended.data ~= content then
        error("chat append was not persisted")
    end
end

local function generateApproachScene(triggerId, report, characterId)
    if type(LLM) ~= "function" then
        return nil, "LLM 함수를 사용할 수 없습니다. Lua 스크립트의 low-level access를 활성화해야 합니다."
    end
    local characterName, profile = selectedApproachCharacter(triggerId, report, characterId)
    local chat = getFullChat(triggerId)
    local last = type(chat) == "table" and chat[#chat] or nil
    if type(last) == "table"
        and last.role == "char"
        and type(last.data) == "string"
        and last.data:match("%S") ~= nil
        and last.time == 0 then
        return last.data, nil
    end

    local encounters = pastApproachEncounters(triggerId, report, characterId)
    local prompt = buildApproachPrompt(characterName, profile, encounters)
    local lastError = "알 수 없는 LLM 오류"
    for _ = 1, APPROACH_REQUEST_ATTEMPTS do
        local requestOk, response = pcall(LLM, triggerId, prompt, false, { streaming = true })
        if requestOk
            and type(response) == "table"
            and response.success == true
            and type(response.result) == "string"
            and response.result:match("%S") ~= nil then
            appendChatVerified(triggerId, "char", response.result)
            return response.result, nil
        end
        if requestOk and type(response) == "table" and response.result ~= nil then
            lastError = tostring(response.result)
        elseif not requestOk then
            lastError = tostring(response)
        end
    end
    return nil, lastError
end

local function removeApproachRetryFiller(triggerId)
    if type(getFullChat) ~= "function" then
        error("getFullChat host function is unavailable")
    end
    local chat = getFullChat(triggerId)
    local last = type(chat) == "table" and chat[#chat] or nil
    if type(last) ~= "table"
        or last.role ~= "user"
        or last.data ~= "*says nothing*" then
        return
    end
    if type(removeChat) ~= "function" then
        error("removeChat host function is unavailable")
    end
    removeChat(triggerId, #chat - 1)
    local after = getFullChat(triggerId)
    if type(after) ~= "table" or #after ~= #chat - 1 then
        error("approach retry filler removal was not persisted")
    end
end

local function finishApproachTransition(triggerId)
    local report = runScript(triggerId, "init", "start")
    if not controllerSucceeded(triggerId, "approach.init.start", report) then
        return false
    end
    local targetOk, targetError = pcall(syncGameUiTarget, triggerId)
    if not targetOk then
        debug(1, "approach: Battle UI target 갱신 실패: " .. tostring(targetError))
        return false
    end
    return true
end

local function resumeApproachTransition(triggerId, report, characterId, phase)
    removeApproachRetryFiller(triggerId)
    if phase == "pending" then
        showApproachProcessing(triggerId, selectedApproachCharacter(triggerId, report, characterId))
        local output, generationError = generateApproachScene(
            triggerId,
            report,
            characterId
        )
        if output == nil then
            return false, generationError
        end
        writeApproachRetryVerified(triggerId, "generated", characterId)
    end
    if not finishApproachTransition(triggerId) then
        return false, "전투 화면으로 전환하지 못했습니다."
    end
    writeApproachRetryVerified(triggerId, nil, nil)
    return true, nil
end

local function resumeApproachWithAlert(triggerId, report, characterId, phase)
    local runOk, completed, detail = pcall(
        resumeApproachTransition,
        triggerId,
        report,
        characterId,
        phase
    )
    if runOk and completed then
        return true
    end
    detail = runOk and detail or completed
    debug(1, "character approach: 생성 또는 전환 실패: " .. tostring(detail))
    local uiOk, uiError = pcall(function()
        local characterName = escapeApproachName(selectedApproachCharacter(triggerId, report, characterId))
        writeUiFragment(triggerId, UI_BODY_VAR, [[<section style="padding: 28px; text-align: center;" aria-live="polite">
<h2>요청을 완료하지 못했습니다</h2>
<p>]] .. characterName .. [[에게 접근하지 못했습니다. 아래 버튼을 눌러 다시 시도하세요.</p>
<button type="button" risu-btn="hostFlow|retryApproach" style="padding: 12px 20px; cursor: pointer;">다시 시도</button>
</section>]])
        writeUiFragment(triggerId, UI_READY_VAR, "ready")
        refreshGameUi(triggerId)
    end)
    if not uiOk then
        debug(1, "character approach: 재시도 화면 표시 실패: " .. tostring(uiError))
    end
    if type(alertError) == "function" then
        pcall(
            alertError,
            triggerId,
            "요청을 완료하지 못했습니다. 다시 시도 버튼을 누르세요. 전송 버튼으로도 재시도할 수 있습니다.\n"
                .. tostring(detail)
        )
    end
    return false
end

-- target 메시지에만 최신 UI를 붙인다. 이전 target은 reloadChat될 때 원문으로 돌아간다.
local function handleEditDisplay(triggerId, data, meta)
    if type(data) ~= "string" then
        return data
    end
    if data == TURN_SUBMIT_MARKER then
        return TURN_SUBMIT_HIDDEN_MARKUP
    end
    local index = type(meta) == "table" and meta.index or nil
    if type(index) ~= "number" then
        return data
    end

    local activeIndex = parseUiTargetIndex(readUiFragment(triggerId, UI_TARGET_INDEX_VAR)) or -1
    if index ~= activeIndex then
        return data
    end

    local rendered = SETUP_START_MARKUP
    if readUiFragment(triggerId, UI_READY_VAR) == "ready" then
        local body = readUiFragment(triggerId, UI_BODY_VAR)
        local markerStart = string.find(body, UI_INTERACTION_MARKER, 1, true)
        if markerStart ~= nil then
            body = string.sub(body, 1, markerStart - 1)
                .. readUiFragment(triggerId, UI_INTERACTION_VAR)
                .. string.sub(body, markerStart + #UI_INTERACTION_MARKER)
        end
        rendered = readUiFragment(triggerId, UI_SHELL_VAR)
            .. body
            .. readUiFragment(triggerId, UI_POPUP_VAR)
    end
    if index == -1 then
        local containerStart = string.find(data, UI_CONTAINER_EMPTY, 1, true)
        if containerStart ~= nil then
            local containerEnd = containerStart + #UI_CONTAINER_EMPTY - 1
            return string.sub(data, 1, containerStart - 1)
                .. UI_CONTAINER_OPEN .. rendered .. "</div>"
                .. string.sub(data, containerEnd + 1)
        end
        return data
    end
    return data .. "\n" .. UI_CONTAINER_OPEN .. rendered .. "</div>"
end

--버튼 클릭시 동작
local BUTTON_ACTIONS = {
    hostFlow = { retryApproach = true },
    init = { start = true, choose = true, chooseCharacter = true },
    battleController = { clickCard = true, registerCard = true, cancelCard = true, selectCardEffect = true, armSubmission = true, skipAftermath = true },
    popupManage = { root = true, push = true, replace = true, back = true, close = true },
}

local function isAllowedButtonRoute(script, arguments)
    local actions = BUTTON_ACTIONS[script]
    local action = arguments[1]
    if type(actions) ~= "table" or actions[action] ~= true then
        return false
    end
    if script == "hostFlow" then
        return #arguments == 1
    elseif script == "init" then
        return (action == "start" and #arguments == 1)
            or (action == "choose" and #arguments == 3)
            or (action == "chooseCharacter" and #arguments == 3)
    elseif script == "battleController" then
        return (action == "selectCardEffect" and #arguments == 4)
            or (action == "armSubmission" and #arguments == 2)
            or ((action == "clickCard"
                or action == "registerCard"
                or action == "cancelCard"
                or action == "skipAftermath") and #arguments == 3)
    elseif action == "back" or action == "close" then
        return #arguments == 1
    end
    return #arguments >= 3 and #arguments <= 5
end

local function handleButtonClick(triggerId, data)
    --risu-btn 값을 "스크립트|인자1|인자2" 형식으로 해석
    local parts = splitByDelimiter(data, "|")
    local script = table.remove(parts, 1)

    if not script or script == "" then
        debug(1, "button dispatch error: empty script.")
        return
    end
    if not isAllowedButtonRoute(script, parts) then
        debug(1, "button dispatch error: disallowed route " .. tostring(script) .. ".")
        return
    end
    debug(3, "Button route: " .. tostring(script) .. "|" .. tostring(parts[1]))

    if script == "hostFlow" then
        local readOk, phase, characterId = pcall(readApproachRetry, triggerId)
        if not readOk then
            alertTurnFailure(triggerId, "재시도 상태를 읽지 못했습니다: " .. tostring(phase))
        elseif phase ~= nil then
            resumeApproachWithAlert(triggerId, nil, characterId, phase)
        end
        return
    end

    local report = runScript(triggerId, script, table.unpack(parts))
    if script == "init" and parts[1] == "start" then
        if controllerSucceeded(triggerId, "onButtonClick.init.start", report) then
            local targetOk, targetError = pcall(syncGameUiTarget, triggerId)
            if not targetOk then
                debug(1, "onButtonClick.init.start: UI target 갱신 실패: " .. tostring(targetError))
            end
        end
    elseif script == "init"
        and parts[1] == "chooseCharacter"
        and type(report) == "table"
        and report.ok == true
        and report.applied == true then
        local stateOk, stateError = pcall(
            writeApproachRetryVerified,
            triggerId,
            "pending",
            parts[2]
        )
        if not stateOk then
            debug(1, "character approach: 재시도 상태 저장 실패: " .. tostring(stateError))
            if type(alertError) == "function" then
                pcall(alertError, triggerId, "접근 장면의 재시도 상태를 저장하지 못했습니다.")
            end
            return
        end
        resumeApproachWithAlert(
            triggerId,
            report,
            parts[2],
            "pending"
        )
    end
end

--정상 요청에 저장된 비공개 턴 사건과 사용자 장면 지시를 request에만 추가
local function handleEditRequest(triggerId, data)
    local report = runScript(
        triggerId,
        "battleController",
        "injectRequest",
        data
    )
    if not controllerSucceeded(triggerId, "editRequest", report) then
        return data
    end
    if type(report.promptArray) ~= "table" then
        debug(1, "editRequest: 주입된 promptArray가 없습니다.")
        return data
    end
    return report.promptArray
end

--수동 전송의 턴 준비·실패 복구·commit-only 복구
local function handleStart(triggerId)
    local retryReadOk, retryPhase, retryCharacterId = pcall(
        readApproachRetry,
        triggerId
    )
    if not retryReadOk then
        debug(1, "onStart: 접근 장면 재시도 상태 읽기 실패: " .. tostring(retryPhase))
        if type(alertError) == "function" then
            pcall(alertError, triggerId, "접근 장면의 재시도 상태가 올바르지 않습니다.")
        end
        return false
    end
    if retryPhase ~= nil then
        resumeApproachWithAlert(
            triggerId,
            nil,
            retryCharacterId,
            retryPhase
        )
        return false
    end
    local report = runScript(
        triggerId,
        "battleController",
        "prepareGeneration"
    )
    if not controllerSucceeded(triggerId, "onStart", report) then
        return false
    end

    if report.commitRecovered == true or report.uiTargetRequired == true then
        local targetOk, targetError = pcall(syncGameUiTarget, triggerId, report.uiTargetIndex)
        if not targetOk then
            debug(1, "onStart: 복구 UI target 갱신 실패: " .. tostring(targetError))
            return false
        end
    end

    -- 관측된 출력을 보존하고 commit만 복구한 경우 새 HTTP 요청은 취소한다.
    return report.generationReady == true
end

--완성 응답을 관측한 뒤 턴을 한 번만 확정
local function handleOutput(triggerId)
    return runScript(
        triggerId,
        "battleController",
        "commitOutput"
    )
end

    return function(triggerId, action, ...)
        if action == "editDisplay" then
            return handleEditDisplay(triggerId, ...)
        elseif action == "buttonClick" then
            return handleButtonClick(triggerId, ...)
        elseif action == "editRequest" then
            return handleEditRequest(triggerId, ...)
        elseif action == "start" then
            return handleStart(triggerId, ...)
        elseif action == "output" then
            return handleOutput(triggerId, ...)
        end
        error("unsupported hostFlow action: " .. tostring(action))
    end
end)()
