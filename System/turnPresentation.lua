(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_PLAN_SLOTS = 16

    local VALID_MODES = {
        pass = true,
        chain_pass = true,
        action = true,
    }

    local VALID_EVENT_TYPES = {
        turn_mode = true,
        turn_started = true,
        player_cards_drawn = true,
        character_intent = true,
        card_declared = true,
        effect_applied = true,
        trigger_suppressed = true,
        plan_changed = true,
        actions_stopped = true,
        card_removed = true,
        outcome = true,
        mood_evaluated = true,
        turn_ended = true,
        session_ended = true,
    }

    local RESOURCE_EFFECTS = {
        pay_stealth_cost = { target = "player", resource = "stealth", direction = -1, noun = "은폐" },
        damage_resistance = { target = "character", resource = "resistance", direction = -1, noun = "상대의 저항" },
        recover_resistance = { target = "character", resource = "resistance", direction = 1, noun = "상대의 저항" },
        lose_stealth = { target = "player", resource = "stealth", direction = -1, noun = "은폐" },
        recover_stealth = { target = "player", resource = "stealth", direction = 1, noun = "은폐" },
    }

    local SOURCE_COLLECTIONS = {
        card = "cards",
        plan = "cards",
        trait = "traits",
        perk = "perks",
    }

    local SYSTEM_EFFECT_SOURCES = {
        mood_state = {
            name = "무드 효과",
            description = "턴 종료 시 확정된 무드가 은폐에 미치는 상태 효과입니다.",
            rules = {
                "무드 효과에 따라 은폐가 감소하거나 회복됩니다.",
            },
            tags = {},
        },
    }

    local EFFECT_SOURCE_LABELS = {
        card = "카드",
        plan = "계획",
        trait = "특징",
        perk = "퍽",
        system = "상태 효과",
    }

    local ACTION_STOP_REASONS = {
        outcome_latched = "승패가 결정되어",
        skip_actions = "남은 행동이 생략되어",
        insufficient_stealth = "은폐가 부족해",
        card_unavailable = "등록한 카드를 사용할 수 없어",
        requires_negative_mood = "현재 무드가 의심 또는 거절이 아니어서",
    }

    local OUTCOME_REASONS = {
        card_checkpoint = true,
        turn_start_checkpoint = true,
        turn_end_checkpoint = true,
        mood_state_checkpoint = true,
        turn_limit = true,
    }

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

    local function success(lastTurn)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            lastTurn = lastTurn,
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

    local function isSide(value)
        return value == "player" or value == "character"
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function getArrayLength(value)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return nil
        end
        local count = 0
        local maximum = 0
        for key in pairs(value) do
            if not isInteger(key, 1) then
                return nil
            end
            count = count + 1
            maximum = math.max(maximum, key)
        end
        if count ~= maximum then
            return nil
        end
        return maximum
    end

    local function checkAllowedKeys(value, allowed, path)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return makeError("invalid_object", path, "공개 표시 자료는 일반 객체여야 합니다.")
        end
        for key in pairs(value) do
            if type(key) ~= "string" or allowed[key] ~= true then
                return makeError("unexpected_field", path, "공개 허용 목록 밖의 필드가 있습니다.")
            end
        end
        return nil
    end

    local function nestedFailure(prefix, report)
        local errors = {}
        local nested = type(report) == "table" and report.errors or nil
        if type(nested) == "table" and #nested > 0 then
            for _, item in ipairs(nested) do
                local suffix = type(item) == "table" and item.path or "$"
                if type(suffix) ~= "string" then suffix = "$" end
                if suffix:sub(1, 1) == "$" then
                    suffix = suffix:sub(2)
                else
                    suffix = "." .. suffix
                end
                errors[#errors + 1] = makeError(
                    type(item) == "table" and type(item.code) == "string" and item.code
                        or "nested_validation_failed",
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

    local function hasCompleteStaticData(staticData)
        return type(staticData) == "table"
            and type(staticData.registry) == "table"
            and type(staticData.registry.roles) == "table"
            and type(staticData.registry.moods) == "table"
            and type(staticData.cards) == "table"
            and type(staticData.traits) == "table"
            and type(staticData.subwayLines) == "table"
            and type(staticData.characters) == "table"
    end

    local function sideLabel(side)
        return side == "player" and "플레이어" or "상대"
    end

    local function numberText(value)
        if value % 1 == 0 then
            return string.format("%.0f", value)
        end
        return tostring(value)
    end

    local function lookupRoleLabel(staticData, role, owner, path)
        local definition = staticData.registry.roles[role]
        if type(role) ~= "string"
            or type(definition) ~= "table"
            or definition.id ~= role
            or definition.owner ~= owner
            or type(definition.label) ~= "string"
            or definition.label == "" then
            return nil, makeError("unknown_role", path, "공개 역할 태그 라벨을 확인할 수 없습니다.")
        end
        return definition.label, nil
    end

    local function lookupRoleLabels(staticData, roles, owner, path)
        local count = getArrayLength(roles)
        if count == nil or count < 1 or (owner == "character" and count ~= 1) or count > 2 then
            return nil, makeError("invalid_roles", path, "공개 역할 태그 목록이 올바르지 않습니다.")
        end
        local labels = {}
        local seen = {}
        for index = 1, count do
            local role = roles[index]
            if seen[role] then
                return nil, makeError("duplicate_role", path .. "[" .. index .. "]", "역할 태그가 중복되었습니다.")
            end
            local label, roleError = lookupRoleLabel(staticData, role, owner, path .. "[" .. index .. "]")
            if roleError then return nil, roleError end
            seen[role] = true
            labels[index] = label
        end
        return labels, nil
    end

    local function rolesEqual(left, right)
        local count = getArrayLength(left)
        if count == nil or count ~= getArrayLength(right) then return false end
        for index = 1, count do
            if left[index] ~= right[index] then return false end
        end
        return true
    end

    local function lookupMood(staticData, moodId, path)
        local definition = staticData.registry.moods[moodId]
        if type(moodId) ~= "string"
            or type(definition) ~= "table"
            or definition.id ~= moodId
            or type(definition.label) ~= "string"
            or definition.label == ""
            or not isInteger(definition.order, 1) then
            return nil, makeError("unknown_mood", path, "공개 무드 라벨을 확인할 수 없습니다.")
        end
        return definition, nil
    end

    local function lookupCardName(staticData, cardId, owner, path, requirePlan)
        local card = staticData.cards[cardId]
        if type(cardId) ~= "string"
            or type(card) ~= "table"
            or card.id ~= cardId
            or card.owner ~= owner
            or type(card.name) ~= "string"
            or card.name == ""
            or (requirePlan == true and card.cardType ~= "plan") then
            return nil, nil, makeError("unknown_public_card", path, "공개할 카드 라벨을 확인할 수 없습니다.")
        end
        return card.name, card, nil
    end

    local function buildEffectSource(source, staticData, path)
        local keyError = checkAllowedKeys(source, {
            kind = true,
            id = true,
            side = true,
        }, path)
        if keyError then return nil, keyError end

        if source.kind == "system" then
            local definition = type(source.id) == "string" and SYSTEM_EFFECT_SOURCES[source.id] or nil
            if not isAsciiId(source.id) or type(definition) ~= "table" then
                return nil, makeError("unknown_effect_source", path, "효과 원인의 공개 정보를 확인할 수 없습니다.")
            end
            if source.side ~= nil then
                return nil, makeError("invalid_effect_source_side", path .. ".side", "시스템 상태 효과 원인에는 진영이 없어야 합니다.")
            end
            local rules = {}
            for index, rule in ipairs(definition.rules) do rules[index] = rule end
            local tags = {}
            for index, tag in ipairs(definition.tags) do tags[index] = tag end
            return {
                kind = "system",
                name = definition.name,
                description = definition.description,
                rules = rules,
                tags = tags,
            }, nil
        end

        local collectionName = SOURCE_COLLECTIONS[source.kind]
        local collection = collectionName and staticData[collectionName] or nil
        local definition = type(collection) == "table" and collection[source.id] or nil
        if not isAsciiId(source.id)
            or type(definition) ~= "table"
            or definition.id ~= source.id then
            return nil, makeError("unknown_effect_source", path, "효과 원인의 공개 정보를 확인할 수 없습니다.")
        end

        local owner = definition.owner
        if source.kind == "perk" and owner == nil then owner = "player" end
        if not isSide(source.side) or owner ~= source.side then
            return nil, makeError("invalid_effect_source_side", path .. ".side", "효과 원인과 진영이 일치하지 않습니다.")
        end
        if source.kind == "plan" and definition.cardType ~= "plan" then
            return nil, makeError("invalid_plan_source", path, "계획 효과 원인이 계획 카드가 아닙니다.")
        end
        if type(definition.name) ~= "string" or definition.name == ""
            or type(definition.description) ~= "string" or definition.description == "" then
            return nil, makeError("invalid_effect_source_detail", path, "효과 원인의 이름과 설명이 필요합니다.")
        end
        local ruleCount = getArrayLength(definition.rules)
        if ruleCount == nil or ruleCount == 0 then
            return nil, makeError("invalid_effect_source_rules", path, "효과 원인의 규칙 목록이 올바르지 않습니다.")
        end

        local rules = {}
        for index = 1, ruleCount do
            if type(definition.rules[index]) ~= "string" or definition.rules[index] == "" then
                return nil, makeError("invalid_effect_source_rule", path, "효과 원인의 규칙 문장이 올바르지 않습니다.")
            end
            rules[index] = definition.rules[index]
        end
        local tags = {}
        if source.kind == "card" or source.kind == "plan" then
            tags[1] = definition.cardType
            for _, role in ipairs(definition.roles or {}) do
                tags[#tags + 1] = role
            end
            for _, mechanismId in ipairs(definition.mechanisms or {}) do
                tags[#tags + 1] = mechanismId
            end
        end

        local safe = {
            kind = source.kind,
            name = definition.name,
            description = definition.description,
            rules = rules,
            tags = tags,
        }
        if source.side ~= nil then safe.side = source.side end
        return safe, nil
    end

    local function effectSourceSuffix(source)
        if type(source) ~= "table" then return "" end
        return " — 원인: " .. tostring(EFFECT_SOURCE_LABELS[source.kind] or source.kind)
            .. " 「" .. tostring(source.name) .. "」"
    end

    local function buildOptionalEffectSource(payload, path, staticData)
        if payload.source == nil then return nil, nil end
        if payload.changed ~= true then
            return nil, makeError("unexpected_effect_source", path .. ".source", "변화가 없는 효과에는 원인 상세정보를 넣을 수 없습니다.")
        end
        return buildEffectSource(payload.source, staticData, path .. ".source")
    end

    local function summary(sequence, eventType, text)
        return {
            sequence = sequence,
            type = eventType,
            text = text,
        }
    end

    local function validateResourceEffect(payload, path, spec, staticData)
        local keyError = checkAllowedKeys(payload, {
            op = true,
            target = true,
            changed = true,
            amount = true,
            before = true,
            after = true,
            source = true,
        }, path)
        if keyError then return nil, keyError end
        if payload.target ~= spec.target
            or type(payload.changed) ~= "boolean"
            or not isFinite(payload.amount)
            or payload.amount < 0
            or not isFinite(payload.before)
            or not isFinite(payload.after)
            or payload.after ~= payload.before + spec.direction * payload.amount
            or payload.changed ~= (payload.before ~= payload.after) then
            return nil, makeError("invalid_effect_payload", path, "자원 변화 표시값이 서로 일치하지 않습니다.")
        end
        local source = nil
        if payload.changed == true and payload.amount > 0 then
            local sourceError
            source, sourceError = buildEffectSource(payload.source, staticData, path .. ".source")
            if sourceError then return nil, sourceError end
        elseif payload.source ~= nil then
            return nil, makeError("unexpected_effect_source", path .. ".source", "변화가 없는 자원 효과에는 원인 상세정보를 넣을 수 없습니다.")
        end
        local verb = spec.direction < 0 and "감소" or "회복"
        local text = spec.noun .. "이(가) " .. numberText(payload.amount) .. " " .. verb .. "했습니다. ("
            .. numberText(payload.before) .. " → " .. numberText(payload.after) .. ")"
        if payload.changed ~= true then
            text = spec.noun .. "에 변화가 없습니다. (" .. numberText(payload.before) .. ")"
        end
        return text .. effectSourceSuffix(source), nil, source
    end

    local function validateEffect(payload, path, staticData)
        if type(payload) ~= "table" or getmetatable(payload) ~= nil then
            return nil, makeError("invalid_effect_payload", path, "효과 표시값이 일반 객체가 아닙니다.")
        end
        local spec = RESOURCE_EFFECTS[payload.op]
        if spec then
            return validateResourceEffect(payload, path, spec, staticData)
        elseif payload.op == "draw_cards" then
            local keyError = checkAllowedKeys(payload, {
                op = true,
                target = true,
                changed = true,
                requested = true,
                drawnCount = true,
                source = true,
            }, path)
            if keyError then return nil, keyError end
            if not isSide(payload.target)
                or type(payload.changed) ~= "boolean"
                or not isInteger(payload.requested, 1)
                or not isInteger(payload.drawnCount, 0)
                or payload.drawnCount > payload.requested
                or payload.changed ~= (payload.drawnCount > 0) then
                return nil, makeError("invalid_effect_payload", path, "드로우 표시값이 서로 일치하지 않습니다.")
            end
            local source, sourceError = buildOptionalEffectSource(payload, path, staticData)
            if sourceError then return nil, sourceError end
            return sideLabel(payload.target) .. "가 카드 " .. tostring(payload.drawnCount)
                .. "장을 더 뽑았습니다. (요청 " .. tostring(payload.requested) .. "장)"
                .. effectSourceSuffix(source), nil
        elseif payload.op == "skip_actions" then
            local keyError = checkAllowedKeys(payload, {
                op = true,
                target = true,
                changed = true,
                scope = true,
                before = true,
                after = true,
                source = true,
            }, path)
            if keyError then return nil, keyError end
            if not isSide(payload.target)
                or type(payload.changed) ~= "boolean"
                or payload.scope ~= "remainingTurn"
                or type(payload.before) ~= "boolean"
                or payload.after ~= true
                or payload.changed ~= (payload.before ~= true) then
                return nil, makeError("invalid_effect_payload", path, "행동 생략 표시값이 서로 일치하지 않습니다.")
            end
            local source, sourceError = buildOptionalEffectSource(payload, path, staticData)
            if sourceError then return nil, sourceError end
            if payload.changed then
                return sideLabel(payload.target) .. "의 이번 턴 남은 행동이 생략됩니다."
                    .. effectSourceSuffix(source), nil
            end
            return sideLabel(payload.target) .. "의 남은 행동은 이미 생략된 상태입니다.", nil
        elseif payload.op == "add_mood_token" or payload.op == "remove_mood_token" then
            local keyError = checkAllowedKeys(payload, {
                op = true,
                target = true,
                changed = true,
                mood = true,
                amount = true,
                before = true,
                after = true,
                source = true,
            }, path)
            if keyError then return nil, keyError end
            local mood, moodError = lookupMood(staticData, payload.mood, path .. ".mood")
            if moodError then return nil, moodError end
            if payload.target ~= "character"
                or not isInteger(payload.amount, 1)
                or not isInteger(payload.before, 0)
                or not isInteger(payload.after, 0)
                or payload.after ~= (payload.op == "add_mood_token"
                    and payload.before + payload.amount
                    or math.max(0, payload.before - payload.amount))
                or payload.changed ~= (payload.before ~= payload.after) then
                return nil, makeError("invalid_effect_payload", path, "무드 토큰 표시값이 서로 일치하지 않습니다.")
            end
            local source, sourceError = buildOptionalEffectSource(payload, path, staticData)
            if sourceError then return nil, sourceError end
            local verb = payload.op == "add_mood_token" and "생성했습니다" or "제거했습니다"
            return mood.label .. " 토큰을 " .. numberText(payload.amount) .. "개 " .. verb .. ". ("
                .. numberText(payload.before) .. " → " .. numberText(payload.after) .. ")"
                .. effectSourceSuffix(source), nil
        elseif payload.op == "force_mood" then
            local keyError = checkAllowedKeys(payload, {
                op = true,
                target = true,
                changed = true,
                mood = true,
                before = true,
                after = true,
                source = true,
            }, path)
            if keyError then return nil, keyError end
            local mood, moodError = lookupMood(staticData, payload.mood, path .. ".mood")
            if moodError then return nil, moodError end
            if payload.target ~= "character"
                or payload.changed ~= true
                or not isInteger(payload.before, 0)
                or payload.after ~= payload.before + 1 then
                return nil, makeError("invalid_effect_payload", path, "무드 강제 변경 요청 표시값이 서로 일치하지 않습니다.")
            end
            local source, sourceError = buildOptionalEffectSource(payload, path, staticData)
            if sourceError then return nil, sourceError end
            return "턴 종료 시 " .. mood.label .. "(으)로 강제 변경하는 효과가 발생했습니다."
                .. effectSourceSuffix(source), nil
        end
        return nil, makeError("unsupported_effect_op", path .. ".op", "공개 표시를 지원하지 않는 효과입니다.")
    end

    local function presentEvent(event, index, turnNumber, staticData)
        local path = "$.pendingTurn.turnResult.publicResult.events[" .. index .. "]"
        local eventError = checkAllowedKeys(event, { sequence = true, type = true, payload = true }, path)
        if eventError then return nil, eventError end
        if event.sequence ~= index then
            return nil, makeError("event_sequence_mismatch", path .. ".sequence", "공개 사건 순번이 연속적이지 않습니다.")
        end
        if VALID_EVENT_TYPES[event.type] ~= true then
            return nil, makeError("unknown_public_event", path .. ".type", "표시 허용 목록에 없는 공개 사건입니다.")
        end
        local payload = event.payload
        if type(payload) ~= "table" or getmetatable(payload) ~= nil then
            return nil, makeError("invalid_public_payload", path .. ".payload", "공개 사건 payload가 일반 객체가 아닙니다.")
        end
        local payloadPath = path .. ".payload"

        if event.type == "turn_mode" then
            local keyError = checkAllowedKeys(payload, { mode = true }, payloadPath)
            if keyError then return nil, keyError end
            if VALID_MODES[payload.mode] ~= true then
                return nil, makeError("invalid_turn_mode", payloadPath .. ".mode", "표시할 턴 모드가 올바르지 않습니다.")
            end
            local texts = {
                pass = "카드를 사용하지 않고 턴을 넘겼습니다.",
                chain_pass = "연계 행동만 사용하고 턴을 넘겼습니다.",
                action = "등록한 카드 행동을 실행했습니다.",
            }
            return summary(index, event.type, texts[payload.mode]), nil
        elseif event.type == "turn_started" then
            local keyError = checkAllowedKeys(payload, { turnNumber = true }, payloadPath)
            if keyError then return nil, keyError end
            if not isInteger(payload.turnNumber, 1) or payload.turnNumber ~= turnNumber then
                return nil, makeError("turn_number_mismatch", payloadPath .. ".turnNumber", "시작 사건의 턴 번호가 저장된 턴과 다릅니다.")
            end
            return summary(index, event.type, tostring(turnNumber) .. "턴이 시작되었습니다."), nil
        elseif event.type == "player_cards_drawn" then
            local keyError = checkAllowedKeys(payload, { requested = true, drawnCount = true }, payloadPath)
            if keyError then return nil, keyError end
            if not isInteger(payload.requested, 0)
                or not isInteger(payload.drawnCount, 0)
                or payload.drawnCount > payload.requested then
                return nil, makeError("invalid_draw_summary", payloadPath, "턴 시작 드로우 수치가 올바르지 않습니다.")
            end
            return summary(index, event.type, "플레이어가 턴 시작에 카드 " .. tostring(payload.drawnCount)
                .. "장을 뽑았습니다. (요청 " .. tostring(payload.requested) .. "장)"), nil
        elseif event.type == "character_intent" then
            local allowed = { selected = true, role = true }
            local keyError = checkAllowedKeys(payload, allowed, payloadPath)
            if keyError then return nil, keyError end
            if type(payload.selected) ~= "boolean"
                or (payload.selected == false and payload.role ~= nil)
                or (payload.selected == true and payload.role == nil) then
                return nil, makeError("invalid_character_intent", payloadPath, "캐릭터 의도 공개값이 올바르지 않습니다.")
            end
            if payload.selected == false then
                return summary(index, event.type, "상대는 이번 턴에 카드 행동을 준비하지 못했습니다."), nil
            end
            local label, labelError = lookupRoleLabel(staticData, payload.role, "character", payloadPath .. ".role")
            if labelError then return nil, labelError end
            return summary(index, event.type, "상대는 " .. label .. " 행동을 준비했습니다."), nil
        elseif event.type == "card_declared" then
            local keyError = checkAllowedKeys(payload, {
                side = true,
                roles = true,
                stealthCost = true,
                cardId = true,
                effectChoiceId = true,
            }, payloadPath)
            if keyError then return nil, keyError end
            if not isSide(payload.side) or not isFinite(payload.stealthCost) or payload.stealthCost < 0 then
                return nil, makeError("invalid_card_declaration", payloadPath, "카드 선언 표시값이 올바르지 않습니다.")
            end
            local roleLabels, roleError = lookupRoleLabels(staticData, payload.roles, payload.side, payloadPath .. ".roles")
            if roleError then return nil, roleError end
            local roleText = table.concat(roleLabels, "·")
            if payload.side == "character" then
                if payload.cardId ~= nil or payload.stealthCost ~= 0 then
                    return nil, makeError("character_card_identity_exposed", payloadPath, "캐릭터 일반 카드의 정체를 공개할 수 없습니다.")
                end
                return summary(index, event.type, "상대가 " .. roleText .. " 역할의 카드를 실행했습니다."), nil
            end
            if payload.cardId == nil then
                return nil, makeError("missing_player_card_identity", payloadPath .. ".cardId", "플레이어 카드 표시명이 필요합니다.")
            end
            local cardName, card, cardError = lookupCardName(staticData, payload.cardId, "player", payloadPath .. ".cardId", false)
            if cardError then return nil, cardError end
            if not rolesEqual(card.roles, payload.roles) then
                return nil, makeError("card_role_mismatch", payloadPath .. ".roles", "카드와 공개 역할 태그가 다릅니다.")
            end
            local choiceLabel = nil
            if type(card.effectChoices) == "table" then
                for _, choice in ipairs(card.effectChoices) do
                    if choice.id == payload.effectChoiceId then choiceLabel = choice.label end
                end
                if choiceLabel == nil then
                    return nil, makeError("missing_effect_choice", payloadPath .. ".effectChoiceId", "선택형 카드의 효과 선택값이 올바르지 않습니다.")
                end
            elseif payload.effectChoiceId ~= nil then
                return nil, makeError("unexpected_effect_choice", payloadPath .. ".effectChoiceId", "일반 카드에 효과 선택값이 있습니다.")
            end
            return summary(index, event.type, "플레이어가 ‘" .. cardName .. "’(" .. roleText
                .. ")을(를) 사용했습니다."
                .. (choiceLabel and (" 선택 효과: " .. choiceLabel .. ".") or "")
                .. " 은폐 비용 " .. numberText(payload.stealthCost) .. "."), nil
        elseif event.type == "effect_applied" then
            local text, effectError, source = validateEffect(payload, payloadPath, staticData)
            if effectError then return nil, effectError end
            local resourceChange = nil
            local spec = RESOURCE_EFFECTS[payload.op]
            if spec and payload.changed == true and payload.amount > 0 then
                resourceChange = {
                    sequence = index,
                    resource = spec.resource,
                    amount = spec.direction * payload.amount,
                    source = source,
                }
            end
            return summary(index, event.type, text), nil, resourceChange
        elseif event.type == "trigger_suppressed" then
            local keyError = checkAllowedKeys(payload, {
                side = true,
                reasonCode = true,
                identityKnown = true,
                cardId = true,
                slotIndex = true,
            }, payloadPath)
            if keyError then return nil, keyError end
            if not isSide(payload.side)
                or payload.reasonCode ~= "insight"
                or payload.identityKnown ~= true
                or payload.cardId == nil
                or not isInteger(payload.slotIndex, 1)
                or payload.slotIndex > MAX_PLAN_SLOTS then
                return nil, makeError("invalid_trigger_suppression", payloadPath, "공개 억제 사건이 알려진 계획과 일치하지 않습니다.")
            end
            local cardName, _, cardError = lookupCardName(staticData, payload.cardId, payload.side, payloadPath .. ".cardId", true)
            if cardError then return nil, cardError end
            return summary(index, event.type, sideLabel(payload.side) .. "의 " .. tostring(payload.slotIndex)
                .. "번 계획 ‘" .. cardName .. "’ 발동이 간파로 억제되었습니다."), nil
        elseif event.type == "plan_changed" then
            local keyError = checkAllowedKeys(payload, {
                side = true,
                action = true,
                identityKnown = true,
                cardId = true,
                remainingTurns = true,
                slotIndex = true,
            }, payloadPath)
            if keyError then return nil, keyError end
            local validActions = { placed = true, triggered = true, replaced = true, expired = true }
            if not isSide(payload.side)
                or validActions[payload.action] ~= true
                or type(payload.identityKnown) ~= "boolean"
                or not isInteger(payload.slotIndex, 1)
                or payload.slotIndex > MAX_PLAN_SLOTS
                or (payload.remainingTurns ~= nil and not isInteger(payload.remainingTurns, 0))
                or (payload.identityKnown == true) ~= (payload.cardId ~= nil)
                or (payload.side == "player" and payload.identityKnown ~= true)
                or (payload.action == "triggered" and payload.identityKnown ~= true)
                or (payload.side == "character" and payload.action == "placed" and payload.identityKnown ~= false)
                or ((payload.action == "replaced" or payload.action == "expired") and payload.remainingTurns ~= nil) then
                return nil, makeError("invalid_plan_change", payloadPath, "계획 변화 공개값이 올바르지 않습니다.")
            end
            local actionTexts = {
                placed = "배치했습니다.",
                triggered = "발동했습니다.",
                replaced = "교체했습니다.",
                expired = "만료되었습니다.",
            }
            local identityText
            if payload.identityKnown then
                local cardName, _, cardError = lookupCardName(staticData, payload.cardId, payload.side, payloadPath .. ".cardId", true)
                if cardError then return nil, cardError end
                identityText = tostring(payload.slotIndex) .. "번 계획 ‘" .. cardName .. "’을(를) "
            else
                identityText = tostring(payload.slotIndex) .. "번 슬롯의 정체가 드러나지 않은 계획을 "
            end
            local text = sideLabel(payload.side) .. "가 " .. identityText .. actionTexts[payload.action]
            if payload.remainingTurns ~= nil then
                text = text .. " (남은 지속 " .. tostring(payload.remainingTurns) .. "턴)"
            end
            return summary(index, event.type, text), nil
        elseif event.type == "actions_stopped" then
            local keyError = checkAllowedKeys(payload, { side = true, reasonCode = true, count = true }, payloadPath)
            if keyError then return nil, keyError end
            local reason = ACTION_STOP_REASONS[payload.reasonCode]
            if not isSide(payload.side)
                or not isAsciiId(payload.reasonCode)
                or not isInteger(payload.count, 1) then
                return nil, makeError("invalid_actions_stopped", payloadPath, "행동 중단 공개값이 올바르지 않습니다.")
            end
            reason = reason or "카드 사용 조건을 만족하지 못해"
            return summary(index, event.type, reason .. " " .. sideLabel(payload.side) .. "의 카드 "
                .. tostring(payload.count) .. "장을 처리하지 않았습니다."), nil
        elseif event.type == "card_removed" then
            local keyError = checkAllowedKeys(payload, { side = true, cardId = true }, payloadPath)
            if keyError then return nil, keyError end
            if not isSide(payload.side) then
                return nil, makeError("invalid_card_removed", payloadPath, "카드 제거 공개값이 올바르지 않습니다.")
            end
            if payload.side == "character" then
                if payload.cardId ~= nil then
                    return nil, makeError("character_card_identity_exposed", payloadPath, "캐릭터 일반 카드의 정체를 공개할 수 없습니다.")
                end
                return summary(index, event.type, "상대가 사용한 카드가 이번 전투에서 제거되었습니다."), nil
            end
            if payload.cardId == nil then
                return nil, makeError("missing_player_card_identity", payloadPath .. ".cardId", "제거된 플레이어 카드의 표시명이 필요합니다.")
            end
            local cardName, _, cardError = lookupCardName(staticData, payload.cardId, "player", payloadPath .. ".cardId", false)
            if cardError then return nil, cardError end
            return summary(index, event.type, "플레이어 카드 ‘" .. cardName .. "’이(가) 이번 전투에서 제거되었습니다."), nil
        elseif event.type == "outcome" then
            local keyError = checkAllowedKeys(payload, {
                status = true,
                reasonCode = true,
                stealth = true,
                resistance = true,
            }, payloadPath)
            if keyError then return nil, keyError end
            if (payload.status ~= "victory" and payload.status ~= "defeat")
                or OUTCOME_REASONS[payload.reasonCode] ~= true
                or (payload.reasonCode == "turn_limit" and payload.status ~= "defeat")
                or not isFinite(payload.stealth)
                or not isFinite(payload.resistance) then
                return nil, makeError("invalid_outcome", payloadPath, "승패 공개값이 올바르지 않습니다.")
            end
            local label = payload.status == "victory" and "승리" or "패배"
            return summary(index, event.type, "전투 " .. label .. "가 확정되었습니다. (은폐 "
                .. numberText(payload.stealth) .. ", 저항 " .. numberText(payload.resistance) .. ")"), nil
        elseif event.type == "mood_evaluated" then
            local keyError = checkAllowedKeys(payload, {
                before = true,
                after = true,
                applied = true,
                forcedCount = true,
                forceCancelled = true,
                resolution = true,
                targetMood = true,
                tiedMoods = true,
                tokensBefore = true,
                tokensAfter = true,
            }, payloadPath)
            if keyError then return nil, keyError end
            local beforeMood, beforeError = lookupMood(staticData, payload.before, payloadPath .. ".before")
            local afterMood, afterError = lookupMood(staticData, payload.after, payloadPath .. ".after")
            if beforeError or afterError then return nil, beforeError or afterError end
            if type(payload.applied) ~= "boolean"
                or not isInteger(payload.forcedCount, 0)
                or type(payload.forceCancelled) ~= "boolean"
                or payload.forceCancelled ~= (payload.forcedCount >= 2)
                or type(payload.tokensBefore) ~= "table"
                or type(payload.tokensAfter) ~= "table" then
                return nil, makeError("invalid_mood_evaluation", payloadPath, "무드 평가 공개값이 올바르지 않습니다.")
            end
            local cancelled = payload.forceCancelled and "강제 변경 효과 " .. payload.forcedCount .. "건은 상쇄되었습니다. " or ""
            if payload.resolution == "forced" then
                if payload.forcedCount ~= 1 or payload.forceCancelled or payload.targetMood ~= payload.after then
                    return nil, makeError("invalid_mood_evaluation", payloadPath, "강제 무드 평가의 필드가 서로 모순됩니다.")
                end
                return summary(index, event.type, "강제 변경 효과로 무드가 "
                    .. beforeMood.label .. "에서 " .. afterMood.label .. "(으)로 결정되었습니다. 토큰은 차감하지 않습니다."), nil
            elseif payload.resolution == "token" then
                local targetMood, targetError = lookupMood(staticData, payload.targetMood, payloadPath .. ".targetMood")
                if targetError then return nil, targetError end
                return summary(index, event.type, cancelled .. targetMood.label
                    .. " 토큰이 단독 최다여서 무드를 " .. afterMood.label .. "(으)로 결정하고 해당 토큰을 0으로 만들었습니다."), nil
            elseif payload.resolution == "tie" then
                if type(payload.tiedMoods) ~= "table" or #payload.tiedMoods < 2 or payload.before ~= payload.after then
                    return nil, makeError("invalid_mood_evaluation", payloadPath, "동률 무드 평가의 필드가 서로 모순됩니다.")
                end
                local labels = {}
                for tieIndex, moodId in ipairs(payload.tiedMoods) do
                    local mood, moodError = lookupMood(staticData, moodId, payloadPath .. ".tiedMoods[" .. tieIndex .. "]")
                    if moodError then return nil, moodError end
                    labels[#labels + 1] = mood.label
                end
                return summary(index, event.type, cancelled .. table.concat(labels, ", ")
                    .. " 토큰이 최다 동률이어서 각각 1개 차감하고 무드를 유지했습니다."), nil
            elseif payload.resolution ~= "none" or payload.before ~= payload.after then
                return nil, makeError("invalid_mood_evaluation", payloadPath, "무드 유지 평가의 필드가 서로 모순됩니다.")
            end
            return summary(index, event.type, cancelled .. "3개 이상인 최다 무드 토큰이 없어 "
                .. beforeMood.label .. " 무드를 유지했습니다."), nil
        elseif event.type == "turn_ended" then
            local keyError = checkAllowedKeys(payload, { turnNumber = true }, payloadPath)
            if keyError then return nil, keyError end
            if not isInteger(payload.turnNumber, 1) or payload.turnNumber ~= turnNumber then
                return nil, makeError("turn_number_mismatch", payloadPath .. ".turnNumber", "종료 사건의 턴 번호가 저장된 턴과 다릅니다.")
            end
            return summary(index, event.type, tostring(turnNumber) .. "턴이 종료되었습니다."), nil
        elseif event.type == "session_ended" then
            local keyError = checkAllowedKeys(payload, { status = true }, payloadPath)
            if keyError then return nil, keyError end
            if payload.status ~= "victory" and payload.status ~= "defeat" then
                return nil, makeError("invalid_session_end", payloadPath .. ".status", "세션 종료 상태가 올바르지 않습니다.")
            end
            local label = payload.status == "victory" and "승리" or "패배"
            return summary(index, event.type, "전투가 " .. label .. "로 종료되었습니다."), nil
        end
        return nil, makeError("unknown_public_event", path .. ".type", "표시 허용 목록에 없는 공개 사건입니다.")
    end

    local function buildPresentation(pendingInput, staticInput)
        if pendingInput == nil then
            return success({ available = false })
        end

        local staticData = normalizeStaticData(staticInput)
        if not hasCompleteStaticData(staticData) then
            return failure({ makeError("invalid_static_data", "$.staticData", "전체 정적 데이터가 필요합니다.") })
        end

        local validation, validationErrors = callModule(
            "stateSchema",
            "validatePendingTurn",
            pendingInput,
            staticData
        )
        if validationErrors then return failure(validationErrors) end
        if validation.referencesValidated ~= true or type(validation.value) ~= "table" then
            return failure({ makeError("pending_not_validated", "$.pendingTurn", "pendingTurn의 전체 참조를 검증하지 못했습니다.") })
        end

        local pending = validation.value
        if type(pending.afterState) ~= "table" or pending.afterState.lastCommittedTurnId ~= pending.turnId then
            return failure({ makeError("pending_not_committed", "$.pendingTurn.afterState", "확정 상태에 반영된 pendingTurn만 표시할 수 있습니다.") })
        end
        local turnNumber = type(pending.beforeState) == "table" and pending.beforeState.turnNumber or nil
        if not isInteger(turnNumber, 1) then
            return failure({ makeError("invalid_turn_number", "$.pendingTurn.beforeState.turnNumber", "표시할 턴 번호가 올바르지 않습니다.") })
        end

        local envelope = type(pending.turnResult) == "table" and pending.turnResult.publicResult or nil
        local envelopeError = checkAllowedKeys(envelope, { schemaVersion = true, events = true }, "$.pendingTurn.turnResult.publicResult")
        if envelopeError then return failure({ envelopeError }) end
        if envelope.schemaVersion ~= SCHEMA_VERSION then
            return failure({ makeError("unsupported_public_schema", "$.pendingTurn.turnResult.publicResult.schemaVersion", "지원하지 않는 공개 사건 스키마입니다.") })
        end
        local eventCount = getArrayLength(envelope.events)
        if eventCount == nil then
            return failure({ makeError("invalid_public_events", "$.pendingTurn.turnResult.publicResult.events", "공개 사건은 1부터 이어지는 배열이어야 합니다.") })
        end

        local summaries = {}
        local resourceChanges = {
            stealth = {},
            resistance = {},
        }
        local counts = {}
        local outcomeStatus = nil
        local sessionStatus = nil
        for index = 1, eventCount do
            local event = envelope.events[index]
            local item, eventError, resourceChange = presentEvent(event, index, turnNumber, staticData)
            if eventError then return failure({ eventError }) end
            summaries[index] = item
            if resourceChange ~= nil then
                local entries = resourceChanges[resourceChange.resource]
                entries[#entries + 1] = resourceChange
            end
            counts[event.type] = (counts[event.type] or 0) + 1
            if event.type == "outcome" then outcomeStatus = event.payload.status end
            if event.type == "session_ended" then sessionStatus = event.payload.status end
        end

        for _, eventType in ipairs({
            "turn_mode",
            "turn_started",
            "player_cards_drawn",
            "character_intent",
            "mood_evaluated",
            "turn_ended",
        }) do
            if counts[eventType] ~= 1 then
                return failure({ makeError("required_public_event_count", "$.pendingTurn.turnResult.publicResult.events", "필수 공개 사건의 개수가 올바르지 않습니다.") })
            end
        end
        for _, eventType in ipairs({ "outcome", "session_ended" }) do
            if (counts[eventType] or 0) > 1 then
                return failure({ makeError("duplicate_terminal_event", "$.pendingTurn.turnResult.publicResult.events", "종료 공개 사건이 중복되었습니다.") })
            end
        end
        if outcomeStatus ~= sessionStatus then
            return failure({ makeError("terminal_event_mismatch", "$.pendingTurn.turnResult.publicResult.events", "승패와 세션 종료 공개가 서로 다릅니다.") })
        end
        local afterStatus = pending.afterState.status
        if afterStatus == "active" then
            if outcomeStatus ~= nil or sessionStatus ~= nil then
                return failure({ makeError("active_turn_has_terminal_event", "$.pendingTurn.turnResult.publicResult.events", "계속 중인 전투 턴에 종료 공개가 있습니다.") })
            end
        elseif afterStatus == "victory" or afterStatus == "defeat" then
            if outcomeStatus ~= afterStatus or sessionStatus ~= afterStatus then
                return failure({ makeError("terminal_state_event_mismatch", "$.pendingTurn.turnResult.publicResult.events", "확정 상태와 승패·세션 종료 공개가 서로 다릅니다.") })
            end
        else
            return failure({ makeError("invalid_after_status", "$.pendingTurn.afterState.status", "확정 상태가 올바르지 않습니다.") })
        end

        return success({
            available = true,
            turnNumber = turnNumber,
            summaries = summaries,
            resourceChanges = resourceChanges,
        })
    end

    local arguments = { ... }
    if action == "build" then
        return buildPresentation(arguments[1], arguments[2])
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 턴 표시 작업입니다."),
    })
end)
