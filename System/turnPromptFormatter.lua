(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1

    local function makeError(code, path, message)
        return {
            code = code,
            path = path,
            message = message,
        }
    end

    local function failure(errors)
        return {
            ok = false,
            schemaVersion = SCHEMA_VERSION,
            errors = errors,
        }
    end

    local function success(message, publicMarker)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            message = message,
            publicMarker = publicMarker,
        }
    end

    local function isFinite(value)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
    end

    local function isInteger(value, minimum)
        return isFinite(value)
            and value % 1 == 0
            and (minimum == nil or value >= minimum)
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function isSide(value)
        return value == "player" or value == "character"
    end

    local function isDenseArray(value)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return false
        end
        local count = 0
        local maximum = 0
        for key in pairs(value) do
            if not isInteger(key, 1) then
                return false
            end
            count = count + 1
            maximum = math.max(maximum, key)
        end
        return count == maximum
    end

    local function checkAllowedKeys(value, allowed, path)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return makeError("invalid_object", path, "프롬프트 사건 값은 일반 객체여야 합니다.")
        end
        for key in pairs(value) do
            if type(key) ~= "string" or allowed[key] ~= true then
                return makeError("unexpected_field", path, "프롬프트 허용 목록 밖의 필드가 있습니다.")
            end
        end
        return nil
    end

    local function nestedFailure(prefix, report)
        local errors = {}
        local nested = type(report) == "table" and report.errors or nil
        if type(nested) == "table" and #nested > 0 then
            for _, item in ipairs(nested) do
                local code = type(item) == "table" and item.code or nil
                local path = type(item) == "table" and item.path or nil
                local suffix = type(path) == "string" and path or "$"
                if suffix:sub(1, 1) == "$" then
                    suffix = suffix:sub(2)
                else
                    suffix = "." .. suffix
                end
                errors[#errors + 1] = makeError(
                    type(code) == "string" and code or "nested_validation_failed",
                    prefix .. suffix,
                    "저장된 턴 자료의 하위 검증에 실패했습니다."
                )
            end
        else
            errors[1] = makeError(
                "nested_validation_failed",
                prefix,
                "저장된 턴 자료의 하위 검증에 실패했습니다."
            )
        end
        return errors
    end

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError("runtime_unavailable", "$.runtime", "스크립트 실행기를 찾을 수 없습니다."),
            }
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok or type(report) ~= "table" then
            return nil, {
                makeError("module_call_failed", "$.runtime." .. moduleName, "하위 검증 모듈 호출에 실패했습니다."),
            }
        end
        if report.ok ~= true then
            return nil, nestedFailure("$.runtime." .. moduleName, report)
        end
        return report, nil
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function actionTagMatches(staticData, actionTag, actor)
        local tags = type(staticData.registry) == "table" and staticData.registry.actionTags or nil
        local definition = type(tags) == "table" and tags[actionTag] or nil
        return type(definition) == "table"
            and definition.id == actionTag
            and definition.owner == actor
    end

    local function hasMechanism(card, mechanismId)
        for _, currentId in ipairs(type(card) == "table" and type(card.mechanisms) == "table" and card.mechanisms or {}) do
            if currentId == mechanismId then
                return true
            end
        end
        return false
    end

    local function narrationMatches(staticData, payload, narrationKey, planRequired)
        for _, card in pairs(type(staticData.cards) == "table" and staticData.cards or {}) do
            local isPlan = hasMechanism(card, "plan")
            if type(card) == "table"
                and card.owner == payload.actor
                and (planRequired == true) == isPlan
                and (payload.actionTag == nil or card.actionTag == payload.actionTag) then
                local entry = type(card.narration) == "table" and card.narration[narrationKey] or nil
                if type(entry) == "table"
                    and entry.actorAction == payload.actorAction
                    and (payload.actor ~= "character" or entry.actorThought == payload.actorThought)
                    and (payload.actor == "character" or payload.actorThought == nil) then
                    return true
                end
                if narrationKey == "play" and payload.actor == "player" then
                    for _, choice in ipairs(type(card.effectChoices) == "table" and card.effectChoices or {}) do
                        if choice.actorAction == payload.actorAction then return true end
                    end
                end
            end
        end
        return false
    end

    local function knownPlanWithoutNarration(staticData, actor, narrationKey)
        for _, card in pairs(type(staticData.cards) == "table" and staticData.cards or {}) do
            if type(card) == "table" and card.owner == actor and hasMechanism(card, "plan") then
                local entry = type(card.narration) == "table" and card.narration[narrationKey] or nil
                if entry == nil then
                    return true
                end
            end
        end
        return false
    end

    local function validateEffect(payload, path, staticData)
        if type(payload) ~= "table" or getmetatable(payload) ~= nil then
            return nil, makeError("invalid_effect", path, "LLM 효과 사건이 일반 객체가 아닙니다.")
        end
        local op = payload.op
        local allowed
        if op == "pay_stealth_cost"
            or op == "damage_resistance"
            or op == "recover_resistance"
            or op == "lose_stealth"
            or op == "recover_stealth" then
            allowed = { op = true, target = true, changed = true, amount = true, before = true, after = true }
        elseif op == "draw_cards" then
            allowed = { op = true, target = true, changed = true, requested = true, drawnCount = true }
        elseif op == "skip_actions" then
            allowed = { op = true, target = true, changed = true, scope = true, before = true, after = true }
        elseif op == "add_mood_token" or op == "remove_mood_token" then
            allowed = { op = true, target = true, changed = true, mood = true, amount = true, before = true, after = true }
        elseif op == "force_mood" then
            allowed = { op = true, target = true, changed = true, mood = true, before = true, after = true }
        else
            return nil, makeError("unsupported_effect_op", path .. ".op", "지원하지 않는 LLM 효과 작업입니다.")
        end

        local keyError = checkAllowedKeys(payload, allowed, path)
        if keyError then
            return nil, keyError
        end
        if not isSide(payload.target) or type(payload.changed) ~= "boolean" then
            return nil, makeError("invalid_effect", path, "효과 대상 또는 changed가 올바르지 않습니다.")
        end
        if payload.changed ~= true then
            return nil, makeError("non_narrative_effect", path, "LLM 사건에는 실제 효과가 있는 작업만 들어갈 수 있습니다.")
        end

        local safe = {
            op = op,
            target = payload.target,
            changed = payload.changed,
        }
        if op == "pay_stealth_cost"
            or op == "damage_resistance"
            or op == "recover_resistance"
            or op == "lose_stealth"
            or op == "recover_stealth" then
            local targets = {
                pay_stealth_cost = "player",
                damage_resistance = "character",
                recover_resistance = "character",
                lose_stealth = "player",
                recover_stealth = "player",
            }
            if payload.target ~= targets[op]
                or not isFinite(payload.amount)
                or payload.amount < 0
                or not isFinite(payload.before)
                or not isFinite(payload.after) then
                return nil, makeError("invalid_effect", path, "자원 효과 값이 올바르지 않습니다.")
            end
            local direction = (op == "recover_resistance" or op == "recover_stealth") and 1 or -1
            if payload.after ~= payload.before + direction * payload.amount
                or payload.changed ~= (payload.before ~= payload.after) then
                return nil, makeError("effect_result_mismatch", path, "자원 효과 결과가 연산과 다릅니다.")
            end
            safe.amount = payload.amount
            safe.before = payload.before
            safe.after = payload.after
        elseif op == "draw_cards" then
            if not isInteger(payload.requested, 1)
                or not isInteger(payload.drawnCount, 1)
                or payload.drawnCount > payload.requested
                or payload.changed ~= true then
                return nil, makeError("invalid_effect", path, "드로우 효과 값이 올바르지 않습니다.")
            end
            safe.requested = payload.requested
            safe.drawnCount = payload.drawnCount
        elseif op == "skip_actions" then
            if payload.scope ~= "remainingTurn"
                or payload.before ~= false
                or payload.after ~= true
                or payload.changed ~= true then
                return nil, makeError("invalid_effect", path, "행동 생략 효과 값이 올바르지 않습니다.")
            end
            safe.scope = payload.scope
            safe.before = false
            safe.after = true
        elseif op == "add_mood_token" or op == "remove_mood_token" then
            local moods = type(staticData.registry) == "table" and staticData.registry.moods or nil
            if payload.target ~= "character"
                or type(moods) ~= "table"
                or type(moods[payload.mood]) ~= "table"
                or not isInteger(payload.amount, 1)
                or not isInteger(payload.before, 0)
                or payload.after ~= (op == "add_mood_token"
                    and payload.before + payload.amount
                    or math.max(0, payload.before - payload.amount)) then
                return nil, makeError("invalid_effect", path, "무드 토큰 효과 값이 올바르지 않습니다.")
            end
            safe.mood = payload.mood
            safe.amount = payload.amount
            safe.before = payload.before
            safe.after = payload.after
        elseif op == "force_mood" then
            local moods = type(staticData.registry) == "table" and staticData.registry.moods or nil
            if payload.target ~= "character"
                or type(moods) ~= "table"
                or type(moods[payload.mood]) ~= "table"
                or not isInteger(payload.before, 0)
                or payload.after ~= payload.before + 1 then
                return nil, makeError("invalid_effect", path, "무드 강제 변경 요청 값이 올바르지 않습니다.")
            end
            safe.mood = payload.mood
            safe.before = payload.before
            safe.after = payload.after
        end
        return safe, nil
    end

    local function validateLlmPayload(eventType, payload, path, staticData, pending)
        if eventType == "turn_mode" then
            local keyError = checkAllowedKeys(payload, { mode = true }, path)
            if keyError then return nil, keyError end
            if payload.mode ~= "pass" and payload.mode ~= "chain_pass" and payload.mode ~= "action" then
                return nil, makeError("invalid_turn_mode", path .. ".mode", "턴 mode가 올바르지 않습니다.")
            end
            if type(pending.projectionReceipt) ~= "table" or payload.mode ~= pending.projectionReceipt.mode then
                return nil, makeError("turn_mode_mismatch", path .. ".mode", "LLM 턴 mode가 projection 영수증과 다릅니다.")
            end
            return { mode = payload.mode }, nil
        elseif eventType == "turn_context" then
            local keyError = checkAllowedKeys(payload, { turnNumber = true }, path)
            if keyError then return nil, keyError end
            if not isInteger(payload.turnNumber, 1) or payload.turnNumber ~= pending.beforeState.turnNumber then
                return nil, makeError("turn_context_mismatch", path .. ".turnNumber", "LLM 턴 번호가 권위 상태와 다릅니다.")
            end
            return { turnNumber = payload.turnNumber }, nil
        elseif eventType == "character_intent" then
            local keyError = checkAllowedKeys(payload, { selected = true, actionTag = true }, path)
            if keyError then return nil, keyError end
            if type(payload.selected) ~= "boolean" then
                return nil, makeError("invalid_character_intent", path, "캐릭터 의도 선택 여부가 올바르지 않습니다.")
            end
            local expectedTag = pending.beforeState.characterIntent.publicActionTag
            if payload.selected == true then
                if not actionTagMatches(staticData, payload.actionTag, "character") or payload.actionTag ~= expectedTag then
                    return nil, makeError("character_intent_mismatch", path, "캐릭터 공개 행동 태그가 권위 상태와 다릅니다.")
                end
                return { selected = true, actionTag = payload.actionTag }, nil
            end
            if payload.actionTag ~= nil or expectedTag ~= nil then
                return nil, makeError("character_intent_mismatch", path, "선택하지 않은 캐릭터 의도에 행동 태그가 있습니다.")
            end
            return { selected = false }, nil
        elseif eventType == "effect_applied" then
            return validateEffect(payload, path, staticData)
        elseif eventType == "action" then
            local keyError = checkAllowedKeys(payload, {
                actor = true,
                action = true,
                identityKnown = true,
                actionTag = true,
                actorAction = true,
                actorThought = true,
            }, path)
            if keyError then return nil, keyError end
            if not isSide(payload.actor)
                or payload.action ~= "played"
                or payload.identityKnown ~= true
                or not actionTagMatches(staticData, payload.actionTag, payload.actor)
                or type(payload.actorAction) ~= "string"
                or payload.actorAction == ""
                or (payload.actor == "player" and payload.actorThought ~= nil)
                or (payload.actorThought ~= nil and (type(payload.actorThought) ~= "string" or payload.actorThought == ""))
                or not narrationMatches(staticData, payload, "play", false) then
                return nil, makeError("invalid_action_narration", path, "행동 narration이 검증된 카드 데이터와 다릅니다.")
            end
            local safe = {
                actor = payload.actor,
                action = "played",
                identityKnown = true,
                actionTag = payload.actionTag,
                actorAction = payload.actorAction,
            }
            if payload.actorThought ~= nil then safe.actorThought = payload.actorThought end
            return safe, nil
        elseif eventType == "plan" then
            local keyError = checkAllowedKeys(payload, {
                actor = true,
                action = true,
                identityKnown = true,
                actorAction = true,
                actorThought = true,
            }, path)
            if keyError then return nil, keyError end
            local actionNames = { placed = true, triggered = true, replaced = true, expired = true }
            if not isSide(payload.actor)
                or actionNames[payload.action] ~= true
                or type(payload.identityKnown) ~= "boolean"
                or (payload.actor == "player" and payload.identityKnown ~= true)
                or (payload.actor == "player" and payload.actorThought ~= nil)
                or (payload.actorThought ~= nil and (type(payload.actorThought) ~= "string" or payload.actorThought == "")) then
                return nil, makeError("invalid_plan_event", path, "계획 narration 사건이 올바르지 않습니다.")
            end
            if payload.identityKnown ~= true then
                if payload.actorAction ~= nil or payload.actorThought ~= nil then
                    return nil, makeError("hidden_plan_narration", path, "숨은 계획에 카드별 narration이 있습니다.")
                end
            else
                local narrationKeys = {
                    placed = "planPlaced",
                    triggered = "planTriggered",
                    replaced = "planExpired",
                    expired = "planExpired",
                }
                local key = narrationKeys[payload.action]
                if payload.actorAction ~= nil then
                    if type(payload.actorAction) ~= "string"
                        or payload.actorAction == ""
                        or not narrationMatches(staticData, payload, key, true) then
                        return nil, makeError("invalid_plan_narration", path, "계획 narration이 검증된 카드 데이터와 다릅니다.")
                    end
                elseif (payload.action == "placed" or payload.action == "triggered")
                    or not knownPlanWithoutNarration(staticData, payload.actor, key) then
                    return nil, makeError("missing_plan_narration", path, "알려진 계획 사건에 필요한 narration이 없습니다.")
                end
            end
            local safe = {
                actor = payload.actor,
                action = payload.action,
                identityKnown = payload.identityKnown,
            }
            if payload.actorAction ~= nil then safe.actorAction = payload.actorAction end
            if payload.actorThought ~= nil then safe.actorThought = payload.actorThought end
            return safe, nil
        elseif eventType == "plan_suppressed" then
            local keyError = checkAllowedKeys(payload, { actor = true, reasonCode = true, identityKnown = true }, path)
            if keyError then return nil, keyError end
            if not isSide(payload.actor) or not isAsciiId(payload.reasonCode) or payload.identityKnown ~= true then
                return nil, makeError("invalid_plan_suppression", path, "계획 억제 사건이 올바르지 않습니다.")
            end
            return {
                actor = payload.actor,
                reasonCode = payload.reasonCode,
                identityKnown = true,
            }, nil
        elseif eventType == "actions_stopped" then
            local keyError = checkAllowedKeys(payload, { side = true, reasonCode = true, count = true }, path)
            if keyError then return nil, keyError end
            if not isSide(payload.side) or not isAsciiId(payload.reasonCode) or not isInteger(payload.count, 1) then
                return nil, makeError("invalid_actions_stopped", path, "행동 중단 사건이 올바르지 않습니다.")
            end
            return { side = payload.side, reasonCode = payload.reasonCode, count = payload.count }, nil
        elseif eventType == "outcome" then
            local keyError = checkAllowedKeys(payload, { status = true, reasonCode = true }, path)
            if keyError then return nil, keyError end
            if (payload.status ~= "victory" and payload.status ~= "defeat")
                or not isAsciiId(payload.reasonCode)
                or payload.status ~= pending.afterState.status then
                return nil, makeError("outcome_mismatch", path, "승패 사건이 확정 상태와 다릅니다.")
            end
            return { status = payload.status, reasonCode = payload.reasonCode }, nil
        elseif eventType == "mood_changed" then
            local keyError = checkAllowedKeys(payload, { before = true, after = true, resolution = true }, path)
            if keyError then return nil, keyError end
            local moods = type(staticData.registry) == "table" and staticData.registry.moods or nil
            if type(moods) ~= "table"
                or type(moods[payload.before]) ~= "table"
                or type(moods[payload.after]) ~= "table"
                or (payload.resolution ~= "forced" and payload.resolution ~= "token")
                or payload.before == payload.after then
                return nil, makeError("invalid_mood_change", path, "무드 변화 사건이 올바르지 않습니다.")
            end
            return { before = payload.before, after = payload.after, resolution = payload.resolution }, nil
        elseif eventType == "session_ended" then
            local keyError = checkAllowedKeys(payload, { status = true }, path)
            if keyError then return nil, keyError end
            if (payload.status ~= "victory" and payload.status ~= "defeat")
                or payload.status ~= pending.afterState.status then
                return nil, makeError("session_outcome_mismatch", path, "세션 종료 사건이 확정 상태와 다릅니다.")
            end
            return { status = payload.status }, nil
        end
        return nil, makeError("unknown_llm_event", path, "지원하지 않는 LLM 사건입니다.")
    end

    local function validateLlmEvent(envelope, staticData, pending)
        local envelopeError = checkAllowedKeys(envelope, { schemaVersion = true, events = true }, "$.pendingTurn.turnResult.llmEvent")
        if envelopeError then return nil, { envelopeError } end
        if envelope.schemaVersion ~= SCHEMA_VERSION or not isDenseArray(envelope.events) then
            return nil, {
                makeError("invalid_llm_envelope", "$.pendingTurn.turnResult.llmEvent", "LLM 사건 envelope가 올바르지 않습니다."),
            }
        end

        local sanitized = { schemaVersion = SCHEMA_VERSION, events = {} }
        local seenMode = false
        local seenContext = false
        local seenIntent = false
        local seenOutcome = false
        local seenSessionEnd = false
        for index, event in ipairs(envelope.events) do
            local path = "$.pendingTurn.turnResult.llmEvent.events[" .. index .. "]"
            local eventError = checkAllowedKeys(event, { sequence = true, type = true, payload = true }, path)
            if eventError then return nil, { eventError } end
            if event.sequence ~= index or not isAsciiId(event.type) then
                return nil, { makeError("invalid_llm_event", path, "LLM 사건 sequence 또는 type이 올바르지 않습니다.") }
            end
            if index == 1 and event.type ~= "turn_mode" then
                return nil, { makeError("missing_turn_mode", path, "첫 LLM 사건은 turn_mode여야 합니다.") }
            end
            if index == 2 and event.type ~= "turn_context" then
                return nil, { makeError("missing_turn_context", path, "두 번째 LLM 사건은 turn_context여야 합니다.") }
            end
            if event.type == "turn_mode" then
                if seenMode then return nil, { makeError("duplicate_turn_mode", path, "turn_mode가 중복되었습니다.") } end
                seenMode = true
            elseif event.type == "turn_context" then
                if seenContext then return nil, { makeError("duplicate_turn_context", path, "turn_context가 중복되었습니다.") } end
                seenContext = true
            elseif event.type == "character_intent" then
                if seenIntent then return nil, { makeError("duplicate_character_intent", path, "character_intent가 중복되었습니다.") } end
                seenIntent = true
            elseif event.type == "outcome" then
                if seenOutcome then return nil, { makeError("duplicate_outcome", path, "outcome이 중복되었습니다.") } end
                seenOutcome = true
            elseif event.type == "session_ended" then
                if seenSessionEnd or index ~= #envelope.events then
                    return nil, { makeError("invalid_session_end", path, "session_ended는 한 번만 마지막에 있어야 합니다.") }
                end
                seenSessionEnd = true
            end

            local safePayload, payloadError = validateLlmPayload(
                event.type,
                event.payload,
                path .. ".payload",
                staticData,
                pending
            )
            if payloadError then return nil, { payloadError } end
            sanitized.events[index] = {
                sequence = index,
                type = event.type,
                payload = safePayload,
            }
        end

        if not seenMode or not seenContext or not seenIntent then
            return nil, {
                makeError("missing_required_llm_event", "$.pendingTurn.turnResult.llmEvent.events", "필수 턴 문맥 사건이 없습니다."),
            }
        end
        local ended = pending.afterState.status ~= "active"
        if ended ~= seenOutcome or ended ~= seenSessionEnd then
            return nil, {
                makeError("llm_outcome_mismatch", "$.pendingTurn.turnResult.llmEvent.events", "LLM 종료 사건과 확정 상태가 다릅니다."),
            }
        end
        return sanitized, nil
    end

    local function encodeString(value)
        local parts = { '"' }
        for index = 1, #value do
            local byte = string.byte(value, index)
            if byte == 34 then
                parts[#parts + 1] = '\\"'
            elseif byte == 92 then
                parts[#parts + 1] = "\\\\"
            elseif byte == 8 then
                parts[#parts + 1] = "\\b"
            elseif byte == 12 then
                parts[#parts + 1] = "\\f"
            elseif byte == 10 then
                parts[#parts + 1] = "\\n"
            elseif byte == 13 then
                parts[#parts + 1] = "\\r"
            elseif byte == 9 then
                parts[#parts + 1] = "\\t"
            elseif byte < 32 then
                parts[#parts + 1] = string.format("\\u%04X", byte)
            else
                parts[#parts + 1] = string.char(byte)
            end
        end
        parts[#parts + 1] = '"'
        return table.concat(parts)
    end

    local encodeCanonical
    encodeCanonical = function(value)
        local valueType = type(value)
        if valueType == "string" then return encodeString(value) end
        if valueType == "boolean" then return value and "true" or "false" end
        if valueType == "number" then
            local encoded = string.format("%.17g", value)
            return encoded == "-0" and "0" or encoded
        end
        if valueType ~= "table" then error("unsupported canonical value") end

        local numeric = false
        local strings = false
        local maximum = 0
        local count = 0
        local keys = {}
        for key in pairs(value) do
            if type(key) == "number" then
                numeric = true
                maximum = math.max(maximum, key)
                count = count + 1
            elseif type(key) == "string" then
                strings = true
                keys[#keys + 1] = key
            else
                error("unsupported canonical key")
            end
        end
        if numeric and strings then error("mixed canonical table") end
        local parts = {}
        if numeric then
            if count ~= maximum then error("sparse canonical array") end
            for index = 1, maximum do parts[index] = encodeCanonical(value[index]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = encodeString(key) .. ":" .. encodeCanonical(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    local function formatPending(pendingTurn, staticInput)
        local staticData = normalizeStaticData(staticInput)
        if type(staticData) ~= "table"
            or type(staticData.registry) ~= "table"
            or type(staticData.cards) ~= "table"
            or type(staticData.traits) ~= "table"
            or type(staticData.environments) ~= "table"
            or type(staticData.characters) ~= "table" then
            return failure({ makeError("invalid_static_data", "$.staticData", "전체 정적 데이터가 필요합니다.") })
        end

        local validation, validationErrors = callModule(
            "stateSchema",
            "validatePendingTurn",
            pendingTurn,
            staticData
        )
        if validationErrors then return failure(validationErrors) end
        if validation.referencesValidated ~= true or type(validation.value) ~= "table" then
            return failure({ makeError("pending_not_validated", "$.pendingTurn", "pendingTurn의 전체 참조를 검증하지 못했습니다.") })
        end

        local pending = validation.value
        local replay, replayErrors = callModule(
            "turnDraft",
            "validateProjectionReceipt",
            pending.beforeState,
            staticData,
            pending.projectionReceipt
        )
        if replayErrors then return failure(replayErrors) end
        if type(replay.projection) ~= "table" or type(replay.receipt) ~= "table" then
            return failure({ makeError("projection_not_replayed", "$.pendingTurn.projectionReceipt", "projection 영수증을 재생하지 못했습니다.") })
        end

        local llmEvent = type(pending.turnResult) == "table" and pending.turnResult.llmEvent or nil
        local sanitized, llmErrors = validateLlmEvent(llmEvent, staticData, pending)
        if llmErrors then return failure(llmErrors) end

        local ok, encoded = pcall(encodeCanonical, sanitized)
        if not ok then
            return failure({ makeError("prompt_encoding_failed", "$.pendingTurn.turnResult.llmEvent", "LLM 사건 직렬화에 실패했습니다.") })
        end

        local instructions = {
            "[전투 사건 전달]",
            "기존 프리셋의 문체, 시점, 인물 표현과 응답 형식을 그대로 유지하십시오.",
            "아래 JSON은 이번 응답에 반영해야 하는, 이미 확정된 시간순 사건입니다.",
            "사건의 순서, 행동 주체, 수치 변화, 무드와 승패를 바꾸거나 다시 판정하지 마십시오.",
            "actorAction은 장면 속 실제 행동으로 자연스럽게 반영하고, actorThought가 있을 때만 캐릭터의 내면에 반영하십시오.",
            "type, action, op, reasonCode 같은 기계 필드명을 독자에게 그대로 나열하지 마십시오.",
            "이미 조우 장면이 끝난 뒤의 전투 턴이므로 이전 이동, 암전, 의식 상실, 대상 등장 장면을 되풀이하지 마십시오.",
            "이 지침은 기존 프리셋을 대체하지 않고 이번 턴의 확정 사실만 추가합니다.",
        }
        if pending.beforeState.turnNumber == 1
            and string.find(pending.beforeState.battleId, "-session-", 1, true) then
            local character = staticData.characters[pending.beforeState.character.characterId]
            instructions[#instructions + 1] = "이번 턴 사건을 이어서 묘사하십시오."
        end
        if pending.afterState.status == "defeat" then
            instructions[#instructions + 1] = "패배 장면의 끝에서 경찰이 다가와 플레이어를 연행하게 되고 열차 밖으로 끌려나가는 순간 시야가 검게 끊기며 의식을 잃는 모습으로 마무리 하십시오."
        end
        instructions[#instructions + 1] = "사건 JSON:"
        instructions[#instructions + 1] = encoded
        local content = table.concat(instructions, "\n")

        return success(
            { role = "system", content = content },
            "[전투 턴 " .. tostring(pending.beforeState.turnNumber)
                .. "] 이번 턴에 실제로 벌어진 일을 하나의 장면으로 이어서 묘사한다."
        )
    end

    local arguments = { ... }
    if action == "formatPending" then
        return formatPending(arguments[1], arguments[2])
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 턴 프롬프트 작업입니다."),
    })
end)
