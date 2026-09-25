(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local KIND = "freeTrainingView"

    local function failure(code, path, message)
        return { ok = false, schemaVersion = SCHEMA_VERSION, errors = { { code = code, path = path, message = message } } }
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

    local function validate(view)
        if type(view) ~= "table" or view.kind ~= KIND or view.schemaVersion ~= SCHEMA_VERSION
            or (view.phase ~= "selecting" and view.phase ~= "active"
                and view.phase ~= "closing" and view.phase ~= "returning")
            or type(view.interactionToken) ~= "string" or view.interactionToken == "" then
            return failure("invalid_view", "$", "자유조교 View 형식이 올바르지 않습니다.")
        end
        if view.phase == "selecting" then
            if type(view.candidates) ~= "table" or #view.candidates < 1 then
                return failure("missing_candidates", "$.candidates", "선택할 자유조교 대상이 없습니다.")
            end
            for index, candidate in ipairs(view.candidates) do
                if type(candidate) ~= "table" or type(candidate.characterId) ~= "string"
                    or type(candidate.name) ~= "string" or candidate.name == ""
                    or type(candidate.portraitImage) ~= "string" or candidate.portraitImage == ""
                    or not isInteger(candidate.victories, 3) then
                    return failure("invalid_candidate", "$.candidates[" .. index .. "]", "자유조교 대상 View가 올바르지 않습니다.")
                end
            end
        elseif type(view.sessionId) ~= "string" or type(view.characterName) ~= "string"
            or view.characterName == "" then
            return failure("invalid_session_view", "$", "자유조교 세션 View가 올바르지 않습니다.")
        end
        return success({ valid = true })
    end

    local function build(state, candidates)
        if type(state) ~= "table" or type(state.active) ~= "table" then
            return failure("missing_active_state", "$.state.active", "표시할 자유조교 상태가 없습니다.")
        end
        local active = state.active
        local view = {
            kind = KIND,
            schemaVersion = SCHEMA_VERSION,
            phase = active.phase,
            interactionToken = active.interactionToken,
            candidates = {},
        }
        if active.phase == "selecting" then
            for _, item in ipairs(type(candidates) == "table" and candidates or {}) do
                view.candidates[#view.candidates + 1] = {
                    characterId = item.characterId,
                    name = item.name,
                    portraitImage = item.portraitImage or "dummy.png",
                    victories = item.victories,
                }
            end
        else
            view.sessionId = active.sessionId
            view.characterName = active.characterName
            view.message = active.phase == "active"
                and "자유 입력을 전송해 대화를 이어가세요. 전투 판정은 진행되지 않습니다."
                or active.phase == "closing" and "대화를 정리하고 기록을 작성하고 있습니다."
                or "다음 조우 대상 선택 화면으로 돌아가고 있습니다."
        end
        local checked = validate(view)
        if not checked.ok then return checked end
        return success({ view = view })
    end

    local args = { ... }
    if action == "validate" then return validate(args[1]) end
    if action == "build" then return build(args[1], args[2]) end
    return failure("unknown_action", "$.action", "지원하지 않는 자유조교 View 작업입니다: " .. tostring(action))
end)
