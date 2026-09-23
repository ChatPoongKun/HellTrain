(function()
local function alertTurnFailure(triggerId, detail, inputGuidance)
    if type(alertError) == "function" then
        pcall(
            alertError,
            triggerId,
            (inputGuidance and "입력을 확인해 주세요.\n\n" or "치명적인 오류로 턴을 진행할 수 없습니다.\n\n")
                .. detail
                .. (inputGuidance and ("\n\n" .. inputGuidance) or "\n\n위 오류 내용을 복사하여 개발자에게 제보해 주세요.")
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
    local inputGuides = {
        missing_aftermath_input = "자유행동 내용을 입력한 뒤 전송하세요. 바로 다음 단계로 가려면 ‘남은 자유행동 건너뛰기’를 누르세요.",
        aftermath_automatic_continue_rejected = "자유행동은 빈 전송이나 Continue로 진행할 수 없습니다. 행동 내용을 직접 입력해 전송하거나 ‘남은 자유행동 건너뛰기’를 누르세요.",
        recovery_filler_missing = "현재 요청을 재시도하려면 입력창을 비운 채 전송해 주세요.",
    }
    local guide = #errors == 1 and inputGuides[errors[1].code] or nil
    alertTurnFailure(triggerId, table.concat(details, "\n"), guide)
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
<p class="helltrain-approach-processing__copy">@@processingMessage@@</p>
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

-- Only live calls own locks. A saved/branched chat or a reloaded Lua runtime
-- cannot remain locked by an abandoned request marker.
local SCENE_REQUEST_VAR = "helltrainSceneRequestV1"
local liveSceneRequests = {}
local sceneRequestSerial = 0

local function currentSceneRequest(triggerId)
    return liveSceneRequests[getChatVar(triggerId, SCENE_REQUEST_VAR)]
end

local function withSceneRequest(triggerId, operation)
    sceneRequestSerial = sceneRequestSerial + 1
    local token = tostring(triggerId) .. ":" .. tostring(sceneRequestSerial)
    local request = { chat = getFullChat(triggerId) }
    liveSceneRequests[token] = request
    local ok, result = pcall(function()
        writeUiFragment(triggerId, SCENE_REQUEST_VAR, token)
        if getChatVar(triggerId, SCENE_REQUEST_VAR) ~= token then
            error("scene request marker was not persisted")
        end
        return operation()
    end)
    liveSceneRequests[token] = nil
    pcall(function()
        if getChatVar(triggerId, SCENE_REQUEST_VAR) == token then
            writeUiFragment(triggerId, SCENE_REQUEST_VAR, "")
        end
    end)
    if not ok then error(result) end
    return result
end

local function sceneLLM(triggerId, prompt)
    local request = currentSceneRequest(triggerId)
    if request then request.chat = getFullChat(triggerId) end
    return LLM(triggerId, prompt, false, { streaming = true })
end

local function blockSceneInput(triggerId, request, isSend)
    local notice = "[scene_request_in_progress] 아직 장면을 생성하고 있습니다. 응답이 끝난 뒤 다시 시도해 주세요."
    if isSend then
        local ok, detail = pcall(function()
            local chat = getFullChat(triggerId)
            if #chat < #request.chat then error("진행 중인 요청의 대화가 변경되었습니다.") end
            for index, original in ipairs(request.chat) do
                local current = chat[index]
                if current.role ~= original.role or current.data ~= original.data or current.time ~= original.time then
                    error("진행 중인 요청의 대화가 변경되었습니다.")
                end
            end
            local cancelled = {}
            for index = #request.chat + 1, #chat do
                if chat[index].role ~= "user" then error("추가 입력의 위치를 확인하지 못했습니다.") end
                if chat[index].data ~= "*says nothing*" then cancelled[#cancelled + 1] = chat[index].data end
            end
            -- Remove only inputs appended by the rejected send, never the request's anchor.
            for index = #chat, #request.chat + 1, -1 do removeChat(triggerId, index - 1) end
            if #getFullChat(triggerId) ~= #request.chat then error("추가 전송 취소를 완료하지 못했습니다.") end
            if #cancelled > 0 then
                notice = notice .. "\n\n전송되지 않은 입력(복사 후 다시 입력해 주세요):\n" .. table.concat(cancelled, "\n")
            end
        end)
        if not ok then notice = notice .. "\n" .. tostring(detail) end
    end
    if type(alertError) == "function" then pcall(alertError, triggerId, notice) end
    return false
end

local function showSceneProcessing(triggerId, message)
    local markup = APPROACH_PROCESSING_MARKUP:gsub("@@processingMessage@@", function()
        return escapeApproachName(message)
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
        "loadCharacters",
        {characterId}
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

local function addRequestContext(triggerId, prompt)
    local report = runScript(triggerId, "battleController", "getRequestContext")
    if not controllerSucceeded(triggerId, "getRequestContext", report) then
        error("현재 장면 정보를 구성하지 못했습니다.")
    end
    local marker = "[현재 주변 정보]"
    local normalized = {}
    for _, message in ipairs(prompt) do
        if not (message.role == "system" and type(message.content) == "string"
            and message.content:sub(1, #marker) == marker) then
            normalized[#normalized + 1] = message
        end
    end
    table.insert(normalized, math.max(1, #normalized), {
        role = "system",
        content = marker .. "\n" .. json.encode(report.context)
            .. "\n현재 화면과 동일한 배경 정보입니다. scene.time은 시간대이며, 달력 날짜는 제공되지 않았습니다.",
    })
    return normalized
end

local function showApproachProcessing(triggerId, characterName)
    showSceneProcessing(triggerId, characterName .. "에게 접근하고 있습니다.")
end

local function generateApproachScene(triggerId, report, characterId)
    if type(LLM) ~= "function" then
        return nil, "LLM 함수를 사용할 수 없습니다. Lua 스크립트의 low-level access를 활성화해야 합니다."
    end
    local characterName, profile = selectedApproachCharacter(triggerId, report, characterId)
    local encounters = pastApproachEncounters(triggerId, report, characterId)
    local prompt = addRequestContext(triggerId, buildApproachPrompt(characterName, profile, encounters))
    local lastError = "알 수 없는 LLM 오류"
    for _ = 1, APPROACH_REQUEST_ATTEMPTS do
        local requestOk, response = pcall(sceneLLM, triggerId, prompt)
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
    battleController = { clickCard = true, registerCard = true, cancelCard = true, selectCardEffect = true, armSubmission = true, surrender = true, skipAftermath = true },
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
            or ((action == "armSubmission" or action == "surrender") and #arguments == 2)
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
    if type(report) == "table" and report.ok == true and report.draftRecovered == true then
        syncGameUiTarget(triggerId)
        if type(alertError) == "function" then
            alertError(triggerId, "카드 선택 저장 상태가 없어 선택 화면을 복구했습니다. 카드 선택을 확인하거나 ‘포기하고 내리기’를 다시 눌러 주세요.")
        end
        return
    end
    if script == "battleController" and parts[1] == "surrender" then
        if not controllerSucceeded(triggerId, "surrender", report) or report.applied ~= true then return end
        local completed = false
        local ok, detail = pcall(function()
            showSceneProcessing(triggerId, "선택한 카드를 초기화했습니다. 이번 역에서 내리고 있습니다.")
            local prepared = runScript(triggerId, "battleController", "prepareGeneration")
            if not controllerSucceeded(triggerId, "surrender.prepare", prepared) or prepared.generationReady ~= true then return end
            local prompt = {}
            for _, message in ipairs(getFullChat(triggerId)) do
                prompt[#prompt + 1] = {
                    role = message.role == "char" and "assistant" or message.role,
                    content = message.data,
                }
            end
            local injected = runScript(triggerId, "battleController", "injectRequest", prompt)
            if not controllerSucceeded(triggerId, "surrender.inject", injected) then return end
            local response = sceneLLM(triggerId, addRequestContext(triggerId, injected.promptArray))
            if type(response) ~= "table" or response.success ~= true
                or type(response.result) ~= "string" or not response.result:match("%S") then
                error(type(response) == "table" and tostring(response.result) or "빈 LLM 응답")
            end
            appendChatVerified(triggerId, "char", response.result)
            local committed = runScript(triggerId, "battleController", "commitOutput")
            if controllerSucceeded(triggerId, "surrender.commit", committed) then
                completed = true
                syncGameUiTarget(triggerId, committed.uiTargetIndex)
            end
        end)
        if not completed then
            local restored, restoreReport = pcall(runScript, triggerId, "battleController", "publishCurrentView")
            if not restored or type(restoreReport) ~= "table" or restoreReport.ok ~= true then
                pcall(function()
                    writeUiFragment(triggerId, UI_BODY_VAR, '<section role="status"><p>하차 요청을 완료하지 못했습니다. 입력창을 비운 채 전송하여 다시 시도해 주세요.</p></section>')
                    refreshGameUi(triggerId)
                end)
            end
        end
        if not ok then
            alertTurnFailure(triggerId, "포기 장면 전송에 실패했습니다. 입력창을 비운 채 전송하여 재시도하세요.\n" .. tostring(detail))
        end
        return
    end
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
    return addRequestContext(triggerId, report.promptArray)
end

--수동 전송의 턴 준비·실패 복구·commit-only 복구
local function showSendGuidance(triggerId, code, guidance)
    if type(alertError) == "function" then
        pcall(alertError, triggerId, "지금은 전송으로 진행할 수 없습니다.\n\n[" .. code .. "]\n" .. guidance)
    end
    return false
end

local function selectionSendGuidance(triggerId)
    local run = HostCompat.readState(triggerId, "runProgressionV1.authority")
    local setup = HostCompat.readState(triggerId, "gameSetupV1.authority")
    local phase = type(run) == "table" and run.phase or type(setup) == "table" and setup.phase
    if phase == "deckDraft" then
        return "draft_selection_required", "카드 드래프트 중입니다. 원하는 카드를 열고 ‘이 카드를 초기 덱에 추가’를 누르세요. 덱 구성을 마치면 상대 선택으로 진행합니다."
    elseif phase == "deckComplete" then
        return "setup_transition_pending", "덱 구성이 완료되어 상대 선택 화면으로 전환 중입니다. 잠시 기다린 뒤, 화면이 그대로라면 ‘게임 시작’ 버튼을 다시 눌러 저장된 진행 화면을 여세요."
    elseif phase == "characterSelect" then
        return "character_selection_required", "상대 캐릭터를 선택할 차례입니다. 캐릭터 카드를 열고 아래의 캐릭터 선택 확정 버튼을 누르세요. 접근 장면 응답이 끝나면 전투를 진행할 수 있습니다."
    elseif phase == "reward" then
        return "reward_selection_required", "전투 보상을 선택할 차례입니다. 보상 화면에서 원하는 보상을 확정하거나 ‘선택하지 않기’를 누르세요. 카드 드래프트 보상은 두 번 선택해야 완료됩니다."
    elseif setup == nil and run == nil and HostCompat.readState(triggerId, "battleRuntimeV1.authority") == nil then
        return "game_not_started", "먼저 ‘게임 시작’ 버튼을 누르고 카드 드래프트와 상대 선택을 완료해 주세요."
    end
end

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
        withSceneRequest(triggerId, function() return resumeApproachWithAlert(
            triggerId,
            nil,
            retryCharacterId,
            retryPhase
        ) end)
        return false
    end
    -- Setup/reward sends must never enter a battle controller requiring a draft.
    -- Approach recovery above remains available even while selection is pending.
    local guidanceOk, code, guidance = pcall(selectionSendGuidance, triggerId)
    if not guidanceOk then
        alertTurnFailure(triggerId, "onStart: [send_phase_read_failed] 진행 상태를 읽지 못했습니다.\n" .. tostring(code))
        return false
    end
    if code then return showSendGuidance(triggerId, code, guidance) end
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

    if report.generationReady ~= true and report.commitRecovered ~= true then
        if report.idle == true then
            return showSendGuidance(triggerId, "turn_not_prepared", "전투 화면에서 카드를 고르고 ‘선택 확정’을 누르거나, 카드 선택 없이 ‘턴 넘기기 준비’를 누르세요. ‘전송 준비됨’ 표시를 확인한 뒤 입력창을 비우고 전송해 주세요.")
        elseif report.aftermathComplete == false then
            return showSendGuidance(triggerId, "aftermath_input_required", "자유행동 내용을 입력한 뒤 전송하세요. 바로 다음 단계로 가려면 ‘남은 자유행동 건너뛰기’를 눌러 주세요.")
        elseif report.aftermathComplete == true then
            return showSendGuidance(triggerId, "aftermath_complete", "자유행동이 종료되었습니다. 게임 화면에서 보상을 선택한 뒤 다음 상대를 확정해 주세요.")
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
        if action == "start" or action == "buttonClick" then
            local request = currentSceneRequest(triggerId)
            if request then return blockSceneInput(triggerId, request, action == "start") end
        end
        if action == "editDisplay" then
            return handleEditDisplay(triggerId, ...)
        elseif action == "buttonClick" then
            local route = ...
            if type(route) == "string" and (route:match("^init|chooseCharacter|")
                or route:match("^battleController|surrender|") or route == "hostFlow|retryApproach") then
                return withSceneRequest(triggerId, function() return handleButtonClick(triggerId, route) end)
            end
            return handleButtonClick(triggerId, route)
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
