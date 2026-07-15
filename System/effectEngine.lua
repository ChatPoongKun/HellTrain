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

    local function success(commands, cardId)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            commands = commands or {},
            cardId = cardId,
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
            if key > maximum then
                maximum = key
            end
        end
        return count == maximum
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function hasMechanism(card, mechanismId)
        for _, currentId in ipairs(type(card) == "table" and type(card.mechanisms) == "table" and card.mechanisms or {}) do
            if currentId == mechanismId then
                return true
            end
        end
        return false
    end

    local function findInstance(state, instanceId)
        if type(state) ~= "table" or type(state.cardInstances) ~= "table" then
            return nil
        end
        for _, instance in ipairs(state.cardInstances) do
            if type(instance) == "table" and instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function checkAllowedKeys(value, allowed, path, errors)
        if type(value) ~= "table" then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                table.insert(errors, makeError(
                    "unexpected_field",
                    path .. "." .. tostring(key),
                    "선택 단계 효과에 허용되지 않은 필드가 있습니다."
                ))
            end
        end
    end

    local function evaluateSelectionPreview(staticData, state, instanceId)
        staticData = normalizeStaticData(staticData)
        local errors = {}
        if type(staticData) ~= "table"
            or type(staticData.cards) ~= "table"
            or type(staticData.registry) ~= "table" then
            table.insert(errors, makeError(
                "invalid_static_data",
                "$.staticData",
                "선택 단계 효과에는 전체 정적 데이터가 필요합니다."
            ))
        end
        if type(state) ~= "table" or type(state.cardInstances) ~= "table" then
            table.insert(errors, makeError(
                "invalid_state",
                "$.state",
                "선택 단계 전투 상태가 올바르지 않습니다."
            ))
        elseif state.status ~= "active" then
            table.insert(errors, makeError(
                "battle_not_active",
                "$.state.status",
                "진행 중인 전투에서만 선택 단계 효과를 평가할 수 있습니다."
            ))
        end
        if type(instanceId) ~= "string" or instanceId == "" then
            table.insert(errors, makeError(
                "invalid_instance_id",
                "$.instanceId",
                "카드 인스턴스 ID가 없습니다."
            ))
        end
        if #errors > 0 then
            return failure(errors)
        end

        local instance = findInstance(state, instanceId)
        if not instance then
            return failure({
                makeError("instance_not_found", "$.instanceId", "카드 인스턴스를 찾을 수 없습니다."),
            })
        end
        if instance.owner ~= "player" or instance.zone ~= "hand" then
            return failure({
                makeError(
                    "preview_card_not_in_hand",
                    "$.instanceId",
                    "선택 단계 효과의 원본 카드는 플레이어 손패에 있어야 합니다."
                ),
            })
        end

        local card = staticData.cards[instance.cardId]
        if type(card) ~= "table" or card.id ~= instance.cardId then
            return failure({
                makeError("unknown_card", "$.instanceId", "정적 DB에서 카드를 찾을 수 없습니다."),
            })
        end
        if card.selectionPreview == nil then
            return success({}, card.id)
        end

        local policy = card.selectionPreview
        if type(policy) ~= "table" or getmetatable(policy) ~= nil then
            return failure({
                makeError(
                    "invalid_preview_policy",
                    "$.card.selectionPreview",
                    "선택 단계 효과 정책은 일반 테이블이어야 합니다."
                ),
            })
        end
        checkAllowedKeys(policy, { effects = true }, "$.card.selectionPreview", errors)
        if card.owner ~= "player" or not hasMechanism(card, "chain") then
            table.insert(errors, makeError(
                "preview_requires_player_chain",
                "$.card.selectionPreview",
                "선택 단계 효과는 플레이어 연계 카드에만 선언할 수 있습니다."
            ))
        end
        if not isDenseArray(policy.effects) or #policy.effects == 0 then
            table.insert(errors, makeError(
                "invalid_preview_effects",
                "$.card.selectionPreview.effects",
                "선택 단계 효과는 비어 있지 않은 연속 배열이어야 합니다."
            ))
        end
        if #errors > 0 then
            return failure(errors)
        end

        local commands = {}
        local seenIds = {}
        for index, effect in ipairs(policy.effects) do
            local path = "$.card.selectionPreview.effects[" .. index .. "]"
            if type(effect) ~= "table" or getmetatable(effect) ~= nil then
                table.insert(errors, makeError(
                    "invalid_preview_effect",
                    path,
                    "선택 단계 효과는 일반 테이블이어야 합니다."
                ))
            else
                checkAllowedKeys(effect, {
                    id = true,
                    op = true,
                    target = true,
                    amount = true,
                }, path, errors)
                if type(effect.id) ~= "string"
                    or string.match(effect.id, "^[a-z][a-z0-9_]*$") == nil then
                    table.insert(errors, makeError(
                        "invalid_preview_effect_id",
                        path .. ".id",
                        "선택 단계 효과 ID는 lower_snake_case여야 합니다."
                    ))
                elseif seenIds[effect.id] then
                    table.insert(errors, makeError(
                        "duplicate_preview_effect_id",
                        path .. ".id",
                        "선택 단계 효과 ID가 중복되었습니다."
                    ))
                else
                    seenIds[effect.id] = true
                end

                local registered = type(staticData.registry.effectOps) == "table"
                    and staticData.registry.effectOps[effect.op]
                    or nil
                if type(effect.op) ~= "string" or not registered then
                    table.insert(errors, makeError(
                        "unknown_preview_op",
                        path .. ".op",
                        "등록되지 않은 선택 단계 효과 작업입니다."
                    ))
                elseif effect.op ~= "draw_cards" then
                    table.insert(errors, makeError(
                        "unsupported_preview_op",
                        path .. ".op",
                        "선택 단계 효과 v1은 draw_cards만 지원합니다."
                    ))
                end
                if effect.target ~= "player" then
                    table.insert(errors, makeError(
                        "invalid_preview_target",
                        path .. ".target",
                        "선택 단계 드로우 대상은 player여야 합니다."
                    ))
                end
                if not isInteger(effect.amount, 1) then
                    table.insert(errors, makeError(
                        "invalid_preview_amount",
                        path .. ".amount",
                        "선택 단계 드로우 수량은 1 이상의 정수여야 합니다."
                    ))
                end
                commands[index] = {
                    id = effect.id,
                    op = effect.op,
                    target = effect.target,
                    amount = effect.amount,
                }
            end
        end
        if #errors > 0 then
            return failure(errors)
        end
        return success(commands, card.id)
    end

    local arguments = { ... }
    local actions = {
        evaluateSelectionPreview = evaluateSelectionPreview,
    }
    local handler = actions[action]
    if not handler then
        return failure({
            makeError(
                "unknown_action",
                "$.action",
                "지원하지 않는 효과 엔진 작업입니다: " .. tostring(action)
            ),
        })
    end
    return handler(arguments[1], arguments[2], arguments[3])
end)
