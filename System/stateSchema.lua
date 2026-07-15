(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1

    local VALID_STATUS = {
        active = true,
        victory = true,
        defeat = true,
    }

    local VALID_OWNER = {
        player = true,
        character = true,
    }

    local VALID_ZONE = {
        deck = true,
        hand = true,
        used = true,
        discard = true,
        removed = true,
        plan = true,
    }

    local function addError(errors, code, path, message)
        table.insert(errors, {
            code = code,
            path = path,
            message = message,
        })
    end

    local function result(errors, value)
        return {
            ok = #errors == 0,
            schemaVersion = SCHEMA_VERSION,
            errors = errors,
            value = #errors == 0 and value or nil,
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

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
    end

    local function objectPath(path, key)
        if type(key) == "string" and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", tostring(key)) .. "]"
    end

    local function inspectTable(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "expected_table", path, "테이블이어야 합니다.")
            return nil
        end

        local numericCount = 0
        local maximum = 0
        local hasNumeric = false
        local hasString = false
        local stringKeys = {}

        for key in pairs(value) do
            if type(key) == "number" then
                hasNumeric = true
                numericCount = numericCount + 1
                if not isInteger(key, 1) then
                    addError(errors, "invalid_array_index", path, "배열 인덱스는 1 이상의 정수여야 합니다.")
                    return nil
                end
                if key > maximum then
                    maximum = key
                end
            elseif type(key) == "string" then
                hasString = true
                table.insert(stringKeys, key)
            else
                addError(errors, "invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
                return nil
            end
        end

        if hasNumeric and hasString then
            addError(errors, "mixed_table", path, "숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
            return nil
        end

        if hasNumeric then
            if numericCount ~= maximum then
                addError(errors, "sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
                return nil
            end
            return "array", maximum
        end

        if hasString then
            table.sort(stringKeys)
            return "object", stringKeys
        end

        return "array", 0
    end

    local function validateJsonSafe(value, path, errors, active)
        local valueType = type(value)
        if valueType == "string" or valueType == "boolean" then
            return
        end
        if valueType == "number" then
            if not isFinite(value) then
                addError(errors, "non_finite_number", path, "NaN과 무한대는 저장할 수 없습니다.")
            end
            return
        end
        if valueType ~= "table" then
            addError(errors, "unsupported_type", path, "JSON 상태에 저장할 수 없는 자료형입니다: " .. valueType)
            return
        end
        if getmetatable(value) ~= nil then
            addError(errors, "metatable_not_allowed", path, "상태 테이블에는 메타테이블을 사용할 수 없습니다.")
            return
        end

        active = active or {}
        if active[value] then
            addError(errors, "circular_reference", path, "순환 참조가 있는 테이블은 저장할 수 없습니다.")
            return
        end

        active[value] = true
        local kind, shape = inspectTable(value, path, errors)
        if kind == "array" then
            for index = 1, shape do
                validateJsonSafe(value[index], path .. "[" .. index .. "]", errors, active)
            end
        elseif kind == "object" then
            for _, key in ipairs(shape) do
                validateJsonSafe(value[key], objectPath(path, key), errors, active)
            end
        end
        active[value] = nil
    end

    local function checkAllowedKeys(value, allowed, path, errors)
        if type(value) ~= "table" then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                addError(errors, "unknown_field", objectPath(path, key), "허용되지 않은 필드입니다.")
            end
        end
    end

    local function getArrayLength(value, path, errors)
        local kind, length = inspectTable(value, path, errors)
        if kind ~= "array" then
            if kind ~= nil then
                addError(errors, "expected_array", path, "연속 배열이어야 합니다.")
            end
            return nil
        end
        return length
    end

    local function validateIdArray(value, path, errors, idValidator)
        local length = getArrayLength(value, path, errors)
        if length == nil then
            return
        end

        local seen = {}
        for index = 1, length do
            local item = value[index]
            if not idValidator(item) then
                addError(errors, "invalid_id", path .. "[" .. index .. "]", "올바른 ID 문자열이 아닙니다.")
            else
                if seen[item] then
                    addError(errors, "duplicate_id", path .. "[" .. index .. "]", "같은 ID가 중복되었습니다: " .. item)
                end
                seen[item] = true
            end
        end
    end

    local function normalizeStaticData(staticData)
        if type(staticData) ~= "table" or getmetatable(staticData) ~= nil then
            return staticData
        end
        local data = rawget(staticData, "data")
        if type(data) == "table" and getmetatable(data) == nil then
            return data
        end
        return staticData
    end

    local function isPlainTableTree(value, active, seen)
        if type(value) ~= "table" then
            return true
        end
        if getmetatable(value) ~= nil then
            return false
        end

        active = active or {}
        seen = seen or {}
        if active[value] then
            return false
        end
        if seen[value] then
            return true
        end

        active[value] = true
        for key, item in pairs(value) do
            if not isPlainTableTree(key, active, seen)
                or not isPlainTableTree(item, active, seen) then
                active[value] = nil
                return false
            end
        end
        active[value] = nil
        seen[value] = true
        return true
    end

    local function hasCompleteStaticData(staticData)
        return type(staticData) == "table"
            and getmetatable(staticData) == nil
            and type(rawget(staticData, "registry")) == "table"
            and type(rawget(staticData, "cards")) == "table"
            and type(rawget(staticData, "traits")) == "table"
            and type(rawget(staticData, "environments")) == "table"
            and type(rawget(staticData, "characters")) == "table"
            and isPlainTableTree(staticData)
    end

    local function cardHasMechanism(card, mechanismId)
        if type(card) ~= "table" or type(card.mechanisms) ~= "table" then
            return false
        end
        for _, id in ipairs(card.mechanisms) do
            if id == mechanismId then
                return true
            end
        end
        return false
    end

    local function appendNestedErrors(target, prefix, nested)
        if type(nested) ~= "table" or type(nested.errors) ~= "table" then
            addError(target, "validation_failed", prefix, "하위 스키마 검증 결과가 올바르지 않습니다.")
            return
        end
        for _, item in ipairs(nested.errors) do
            local suffix = tostring(item.path or "$")
            if string.sub(suffix, 1, 1) == "$" then
                suffix = string.sub(suffix, 2)
            end
            addError(
                target,
                tostring(item.code or "validation_failed"),
                prefix .. suffix,
                tostring(item.message or "하위 스키마 검증에 실패했습니다.")
            )
        end
    end

    local function validatePlanSlot(slot, side, path, errors, instances, staticData, currentTurn)
        if type(slot) ~= "table" then
            addError(errors, "invalid_plan_slot", path, "계획 슬롯이 테이블이 아닙니다.")
            return
        end

        local occupied = slot.occupied
        if occupied == false then
            checkAllowedKeys(slot, { occupied = true }, path, errors)
            return
        end

        checkAllowedKeys(slot, {
            occupied = true,
            cardInstanceId = true,
            cardId = true,
            placedTurn = true,
            remainingTurns = true,
            remainingCharges = true,
            revealed = true,
        }, path, errors)

        if occupied ~= true then
            addError(errors, "invalid_plan_occupied", path .. ".occupied", "occupied는 불리언이어야 합니다.")
            return
        end
        if not isRuntimeId(slot.cardInstanceId) then
            addError(errors, "invalid_instance_id", path .. ".cardInstanceId", "계획 카드 인스턴스 ID가 올바르지 않습니다.")
        end
        if not isAsciiId(slot.cardId) then
            addError(errors, "invalid_card_id", path .. ".cardId", "계획 카드 ID가 올바르지 않습니다.")
        end
        if not isInteger(slot.placedTurn, 1) then
            addError(errors, "invalid_placed_turn", path .. ".placedTurn", "배치 턴은 1 이상의 정수여야 합니다.")
        elseif isInteger(currentTurn, 1) and slot.placedTurn > currentTurn then
            addError(errors, "future_placed_turn", path .. ".placedTurn", "계획 배치 턴은 현재 턴보다 클 수 없습니다.")
        end
        if slot.revealed ~= true and slot.revealed ~= false then
            addError(errors, "invalid_revealed", path .. ".revealed", "revealed는 불리언이어야 합니다.")
        end

        local hasLifetime = false
        if slot.remainingTurns ~= nil then
            hasLifetime = true
            if not isInteger(slot.remainingTurns, 0) then
                addError(errors, "invalid_remaining_turns", path .. ".remainingTurns", "남은 지속 턴은 0 이상의 정수여야 합니다.")
            end
        end
        if slot.remainingCharges ~= nil then
            hasLifetime = true
            if not isInteger(slot.remainingCharges, 0) then
                addError(errors, "invalid_remaining_charges", path .. ".remainingCharges", "남은 충전은 0 이상의 정수여야 합니다.")
            end
        end
        if not hasLifetime then
            addError(errors, "missing_plan_lifetime", path, "점유된 계획에는 제한된 수명이 필요합니다.")
        end

        local instance = instances[slot.cardInstanceId]
        if not instance then
            addError(errors, "missing_plan_instance", path .. ".cardInstanceId", "계획 카드 인스턴스를 찾을 수 없습니다.")
        else
            if instance.owner ~= side then
                addError(errors, "plan_owner_mismatch", path .. ".cardInstanceId", "계획 슬롯과 카드 소유자가 다릅니다.")
            end
            if instance.zone ~= "plan" then
                addError(errors, "plan_zone_mismatch", path .. ".cardInstanceId", "계획 카드 인스턴스의 zone이 plan이 아닙니다.")
            end
            if instance.cardId ~= slot.cardId then
                addError(errors, "plan_card_mismatch", path .. ".cardId", "계획 슬롯과 카드 인스턴스의 카드 ID가 다릅니다.")
            end
        end

        local cards = type(staticData) == "table" and staticData.cards or nil
        local card = type(cards) == "table" and cards[slot.cardId] or nil
        if card and not cardHasMechanism(card, "plan") then
            addError(errors, "plan_mechanism_missing", path .. ".cardId", "계획 슬롯의 카드에 plan 메커니즘이 없습니다.")
        end
    end

    local function validateBattleState(state, staticData)
        local errors = {}
        local staticDataProvided = staticData ~= nil
        staticData = normalizeStaticData(staticData)
        local referencesValidated = hasCompleteStaticData(staticData)

        if staticDataProvided and not referencesValidated then
            addError(errors, "invalid_static_data", "$", "전달한 정적 데이터가 전체 참조 검증에 필요한 컬렉션을 갖추지 못했습니다.")
        end
        if not referencesValidated then
            staticData = nil
        end

        if type(state) ~= "table" then
            addError(errors, "invalid_state", "$", "battleState가 테이블이 아닙니다.")
            return result(errors)
        end

        validateJsonSafe(state, "$", errors)
        if #errors > 0 then
            local report = result(errors)
            report.referencesValidated = referencesValidated
            return report
        end
        checkAllowedKeys(state, {
            schemaVersion = true,
            kind = true,
            battleId = true,
            status = true,
            turnNumber = true,
            turnLimit = true,
            environmentId = true,
            lastCommittedTurnId = true,
            rng = true,
            player = true,
            character = true,
            cardInstances = true,
            selection = true,
            characterIntent = true,
        }, "$", errors)

        if state.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", "$.schemaVersion", "지원하지 않는 battleState 스키마 버전입니다.")
        end
        if state.kind ~= "battleState" then
            addError(errors, "invalid_kind", "$.kind", "kind는 battleState여야 합니다.")
        end
        if not isRuntimeId(state.battleId) then
            addError(errors, "invalid_battle_id", "$.battleId", "battleId가 올바르지 않습니다.")
        end
        if not VALID_STATUS[state.status] then
            addError(errors, "invalid_status", "$.status", "알 수 없는 전투 상태입니다.")
        end
        if not isInteger(state.turnNumber, 1) then
            addError(errors, "invalid_turn_number", "$.turnNumber", "현재 턴은 1 이상의 정수여야 합니다.")
        end
        if not isInteger(state.turnLimit, 1) then
            addError(errors, "invalid_turn_limit", "$.turnLimit", "제한 턴은 1 이상의 정수여야 합니다.")
        elseif isInteger(state.turnNumber, 1) and state.turnNumber > state.turnLimit then
            addError(errors, "turn_over_limit", "$.turnNumber", "현재 턴이 제한 턴을 초과했습니다.")
        end
        if not isAsciiId(state.environmentId) then
            addError(errors, "invalid_environment_id", "$.environmentId", "환경 ID가 올바르지 않습니다.")
        end
        if state.lastCommittedTurnId ~= nil and not isRuntimeId(state.lastCommittedTurnId) then
            addError(errors, "invalid_turn_id", "$.lastCommittedTurnId", "마지막 확정 턴 ID가 올바르지 않습니다.")
        end

        if type(state.rng) ~= "table" then
            addError(errors, "invalid_rng", "$.rng", "rng가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.rng, { seed = true, cursor = true }, "$.rng", errors)
            if not isInteger(state.rng.seed, 0) then
                addError(errors, "invalid_rng_seed", "$.rng.seed", "난수 시드는 0 이상의 정수여야 합니다.")
            end
            if not isInteger(state.rng.cursor, 0) then
                addError(errors, "invalid_rng_cursor", "$.rng.cursor", "난수 커서는 0 이상의 정수여야 합니다.")
            end
        end

        if type(state.player) ~= "table" then
            addError(errors, "invalid_player", "$.player", "player가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.player, {
                stealth = true,
                maxHandSize = true,
                perkIds = true,
                planSlot = true,
            }, "$.player", errors)
            if not isFinite(state.player.stealth) then
                addError(errors, "invalid_stealth", "$.player.stealth", "은폐는 유한한 숫자여야 합니다.")
            end
            if not isInteger(state.player.maxHandSize, 0) then
                addError(errors, "invalid_hand_size", "$.player.maxHandSize", "최대 손패는 0 이상의 정수여야 합니다.")
            end
            validateIdArray(state.player.perkIds, "$.player.perkIds", errors, isAsciiId)
        end

        if type(state.character) ~= "table" then
            addError(errors, "invalid_character", "$.character", "character가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.character, {
                characterId = true,
                resistance = true,
                mood = true,
                traitIds = true,
                planSlot = true,
            }, "$.character", errors)
            if not isAsciiId(state.character.characterId) then
                addError(errors, "invalid_character_id", "$.character.characterId", "캐릭터 ID가 올바르지 않습니다.")
            end
            if not isFinite(state.character.resistance) then
                addError(errors, "invalid_resistance", "$.character.resistance", "저항은 유한한 숫자여야 합니다.")
            end
            if not isAsciiId(state.character.mood) then
                addError(errors, "invalid_mood", "$.character.mood", "무드 ID가 올바르지 않습니다.")
            end
            validateIdArray(state.character.traitIds, "$.character.traitIds", errors, isAsciiId)
        end

        local instances = {}
        local positions = {}
        local instanceCount = getArrayLength(state.cardInstances, "$.cardInstances", errors)
        if instanceCount then
            for index = 1, instanceCount do
                local item = state.cardInstances[index]
                local path = "$.cardInstances[" .. index .. "]"
                if type(item) ~= "table" then
                    addError(errors, "invalid_card_instance", path, "카드 인스턴스가 테이블이 아닙니다.")
                else
                    checkAllowedKeys(item, {
                        instanceId = true,
                        cardId = true,
                        owner = true,
                        zone = true,
                        position = true,
                        temporaryModifiers = true,
                    }, path, errors)
                    if not isRuntimeId(item.instanceId) then
                        addError(errors, "invalid_instance_id", path .. ".instanceId", "카드 인스턴스 ID가 올바르지 않습니다.")
                    elseif instances[item.instanceId] then
                        addError(errors, "duplicate_instance_id", path .. ".instanceId", "카드 인스턴스 ID가 중복되었습니다.")
                    else
                        instances[item.instanceId] = item
                    end
                    if not isAsciiId(item.cardId) then
                        addError(errors, "invalid_card_id", path .. ".cardId", "카드 ID가 올바르지 않습니다.")
                    end
                    if not VALID_OWNER[item.owner] then
                        addError(errors, "invalid_owner", path .. ".owner", "카드 소유자가 올바르지 않습니다.")
                    end
                    if not VALID_ZONE[item.zone] then
                        addError(errors, "invalid_zone", path .. ".zone", "카드 영역이 올바르지 않습니다.")
                    end
                    if not isInteger(item.position, 1) then
                        addError(errors, "invalid_position", path .. ".position", "카드 위치는 1 이상의 정수여야 합니다.")
                    elseif VALID_OWNER[item.owner] and VALID_ZONE[item.zone] then
                        local group = item.owner .. ":" .. item.zone
                        positions[group] = positions[group] or {}
                        positions[group][item.position] = (positions[group][item.position] or 0) + 1
                    end
                    if item.temporaryModifiers ~= nil then
                        local modifierCount = getArrayLength(item.temporaryModifiers, path .. ".temporaryModifiers", errors)
                        if modifierCount and modifierCount > 0 then
                            addError(
                                errors,
                                "temporary_modifier_schema_pending",
                                path .. ".temporaryModifiers",
                                "임시 카드 보정 스키마가 확정되기 전에는 빈 배열만 허용합니다."
                            )
                        end
                    end

                    local cards = type(staticData) == "table" and staticData.cards or nil
                    local card = type(cards) == "table" and cards[item.cardId] or nil
                    if type(cards) == "table" and not card then
                        addError(errors, "unknown_card", path .. ".cardId", "정적 DB에서 카드를 찾을 수 없습니다.")
                    elseif card and card.owner ~= item.owner then
                        addError(errors, "card_owner_mismatch", path .. ".owner", "정적 카드와 인스턴스의 소유자가 다릅니다.")
                    end
                end
            end
        end

        for group, groupPositions in pairs(positions) do
            local count = 0
            local maximum = 0
            for position, occurrence in pairs(groupPositions) do
                count = count + occurrence
                if position > maximum then
                    maximum = position
                end
                if occurrence > 1 then
                    addError(errors, "duplicate_position", "$.cardInstances", group .. " 영역의 position이 중복되었습니다: " .. position)
                end
            end
            if count ~= maximum then
                addError(errors, "non_contiguous_positions", "$.cardInstances", group .. " 영역의 position이 1부터 이어지지 않습니다.")
            end
        end

        if type(state.player) == "table" then
            validatePlanSlot(state.player.planSlot, "player", "$.player.planSlot", errors, instances, staticData, state.turnNumber)
        end
        if type(state.character) == "table" then
            validatePlanSlot(state.character.planSlot, "character", "$.character.planSlot", errors, instances, staticData, state.turnNumber)
        end

        for instanceId, instance in pairs(instances) do
            if instance.zone == "plan" and VALID_OWNER[instance.owner] then
                local ownerState = instance.owner == "player" and state.player or state.character
                local slot = type(ownerState) == "table" and ownerState.planSlot or nil
                if type(slot) ~= "table"
                    or slot.occupied ~= true
                    or slot.cardInstanceId ~= instanceId then
                    addError(
                        errors,
                        "orphan_plan_instance",
                        "$.cardInstances",
                        "plan 영역의 카드 인스턴스는 같은 진영의 점유 슬롯과 정확히 연결되어야 합니다: " .. instanceId
                    )
                end
            end
        end

        if type(state.selection) ~= "table" then
            addError(errors, "invalid_selection", "$.selection", "selection이 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.selection, { playerCardInstanceIds = true }, "$.selection", errors)
            validateIdArray(state.selection.playerCardInstanceIds, "$.selection.playerCardInstanceIds", errors, isRuntimeId)
            if type(state.selection.playerCardInstanceIds) == "table" then
                local mainActionCount = 0
                local mainActionIndex = nil
                for index, instanceId in ipairs(state.selection.playerCardInstanceIds) do
                    local instance = instances[instanceId]
                    if not instance or instance.owner ~= "player" or instance.zone ~= "hand" then
                        addError(errors, "invalid_selected_card", "$.selection.playerCardInstanceIds[" .. index .. "]", "선택 카드는 플레이어 손패에 있어야 합니다.")
                    elseif referencesValidated then
                        local card = staticData.cards[instance.cardId]
                        if card and not cardHasMechanism(card, "chain") then
                            mainActionCount = mainActionCount + 1
                            mainActionIndex = index
                        end
                    end
                end
                if mainActionCount > 1 then
                    addError(errors, "multiple_player_main_actions", "$.selection.playerCardInstanceIds", "플레이어 선택에는 주 행동을 둘 이상 넣을 수 없습니다.")
                elseif mainActionIndex and mainActionIndex ~= #state.selection.playerCardInstanceIds then
                    addError(errors, "player_main_action_not_last", "$.selection.playerCardInstanceIds", "연계 카드는 주 행동보다 앞에 있어야 합니다.")
                end
            end
        end

        if type(state.characterIntent) ~= "table" then
            addError(errors, "invalid_character_intent", "$.characterIntent", "characterIntent가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.characterIntent, {
                cardInstanceIds = true,
                publicActionTag = true,
            }, "$.characterIntent", errors)
            validateIdArray(state.characterIntent.cardInstanceIds, "$.characterIntent.cardInstanceIds", errors, isRuntimeId)

            local intentCount = type(state.characterIntent.cardInstanceIds) == "table"
                and #state.characterIntent.cardInstanceIds
                or 0
            if intentCount == 0 then
                if state.characterIntent.publicActionTag ~= nil then
                    addError(errors, "orphan_public_action", "$.characterIntent.publicActionTag", "선택 카드가 없으면 공개 행동 태그도 없어야 합니다.")
                end
            elseif not isAsciiId(state.characterIntent.publicActionTag) then
                addError(errors, "missing_public_action", "$.characterIntent.publicActionTag", "캐릭터 선택의 공개 행동 태그가 필요합니다.")
            end

            local mainCards = {}
            local mainCardIndex = nil
            if type(state.characterIntent.cardInstanceIds) == "table" then
                for index, instanceId in ipairs(state.characterIntent.cardInstanceIds) do
                    local instance = instances[instanceId]
                    if not instance or instance.owner ~= "character" or instance.zone ~= "hand" then
                        addError(errors, "invalid_intent_card", "$.characterIntent.cardInstanceIds[" .. index .. "]", "캐릭터 선택 카드는 캐릭터 손패에 있어야 합니다.")
                    else
                        local cards = type(staticData) == "table" and staticData.cards or nil
                        local card = type(cards) == "table" and cards[instance.cardId] or nil
                        if card and not cardHasMechanism(card, "chain") then
                            table.insert(mainCards, card)
                            mainCardIndex = index
                        end
                    end
                end
            end

            if type(staticData) == "table" and intentCount > 0 then
                if #mainCards ~= 1 then
                    addError(errors, "invalid_character_main_action", "$.characterIntent.cardInstanceIds", "캐릭터 선택에는 주 행동 카드가 정확히 하나 있어야 합니다.")
                elseif mainCardIndex ~= intentCount then
                    addError(errors, "character_main_action_not_last", "$.characterIntent.cardInstanceIds", "캐릭터 연계 카드는 주 행동보다 앞에 있어야 합니다.")
                elseif mainCards[1].actionTag ~= state.characterIntent.publicActionTag then
                    addError(errors, "public_action_mismatch", "$.characterIntent.publicActionTag", "공개 행동 태그가 실제 주 행동과 다릅니다.")
                end
            end

            local registry = type(staticData) == "table" and staticData.registry or nil
            local actionTags = type(registry) == "table" and registry.actionTags or nil
            local publicAction = type(actionTags) == "table" and actionTags[state.characterIntent.publicActionTag] or nil
            if state.characterIntent.publicActionTag ~= nil and type(actionTags) == "table" then
                if not publicAction then
                    addError(errors, "unknown_public_action", "$.characterIntent.publicActionTag", "등록되지 않은 행동 태그입니다.")
                elseif publicAction.owner ~= "character" then
                    addError(errors, "public_action_owner_mismatch", "$.characterIntent.publicActionTag", "캐릭터 행동 태그가 아닙니다.")
                end
            end
        end

        if type(staticData) == "table" then
            if type(staticData.environments) == "table" and not staticData.environments[state.environmentId] then
                addError(errors, "unknown_environment", "$.environmentId", "정적 DB에서 환경을 찾을 수 없습니다.")
            end
            if type(state.character) == "table" then
                if type(staticData.characters) == "table" and not staticData.characters[state.character.characterId] then
                    addError(errors, "unknown_character", "$.character.characterId", "정적 DB에서 캐릭터를 찾을 수 없습니다.")
                end
                if type(staticData.registry) == "table"
                    and type(staticData.registry.moods) == "table"
                    and not staticData.registry.moods[state.character.mood] then
                    addError(errors, "unknown_mood", "$.character.mood", "등록되지 않은 무드입니다.")
                end
                if type(staticData.traits) == "table" and type(state.character.traitIds) == "table" then
                    for index, traitId in ipairs(state.character.traitIds) do
                        if not staticData.traits[traitId] then
                            addError(errors, "unknown_trait", "$.character.traitIds[" .. index .. "]", "정적 DB에서 특징을 찾을 수 없습니다.")
                        end
                    end
                end
            end
        end

        if type(state.player) == "table" and type(state.character) == "table"
            and isFinite(state.player.stealth) and isFinite(state.character.resistance) then
            if state.character.resistance <= 0 and state.status ~= "victory" then
                addError(errors, "victory_priority", "$.status", "저항이 0 이하이면 동시 은폐 소진보다 승리를 우선해야 합니다.")
            elseif state.character.resistance > 0 and state.player.stealth <= 0 and state.status ~= "defeat" then
                addError(errors, "defeat_required", "$.status", "은폐가 0 이하이면 패배 상태여야 합니다.")
            elseif state.status == "active" and (state.character.resistance <= 0 or state.player.stealth <= 0) then
                addError(errors, "active_outcome_conflict", "$.status", "종료 수치에서 active 상태를 유지할 수 없습니다.")
            elseif state.status == "victory" and state.character.resistance > 0 then
                addError(errors, "invalid_victory", "$.status", "저항이 남아 있으면 승리 상태일 수 없습니다.")
            elseif state.status == "defeat"
                and state.player.stealth > 0
                and isInteger(state.turnNumber, 1)
                and isInteger(state.turnLimit, 1)
                and state.turnNumber < state.turnLimit then
                addError(errors, "invalid_defeat", "$.status", "은폐가 남고 제한 턴 전이면 패배 상태일 수 없습니다.")
            end
        end

        local report = result(errors, state)
        report.referencesValidated = referencesValidated
        return report
    end

    local function validateEventEnvelope(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_event_envelope", path, "사건 묶음이 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, { schemaVersion = true, events = true }, path, errors)
        if value.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", path .. ".schemaVersion", "지원하지 않는 사건 묶음 스키마입니다.")
        end
        getArrayLength(value.events, path .. ".events", errors)
    end

    local function arraysEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
            return false
        end
        for index = 1, #left do
            if left[index] ~= right[index] then
                return false
            end
        end
        return true
    end

    local function validatePendingTurn(pending, staticData)
        local errors = {}
        local staticDataProvided = staticData ~= nil
        staticData = normalizeStaticData(staticData)
        local referencesValidated = hasCompleteStaticData(staticData)

        if staticDataProvided and not referencesValidated then
            addError(errors, "invalid_static_data", "$", "전달한 정적 데이터가 전체 참조 검증에 필요한 컬렉션을 갖추지 못했습니다.")
        end
        if not referencesValidated then
            staticData = nil
        end

        if type(pending) ~= "table" then
            addError(errors, "invalid_pending_turn", "$", "pendingTurn이 테이블이 아닙니다.")
            return result(errors)
        end

        validateJsonSafe(pending, "$", errors)
        if #errors > 0 then
            local report = result(errors)
            report.referencesValidated = referencesValidated
            return report
        end
        checkAllowedKeys(pending, {
            schemaVersion = true,
            kind = true,
            battleId = true,
            turnId = true,
            status = true,
            beforeState = true,
            selectedCards = true,
            turnResult = true,
            afterState = true,
        }, "$", errors)

        if pending.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", "$.schemaVersion", "지원하지 않는 pendingTurn 스키마 버전입니다.")
        end
        if pending.kind ~= "pendingTurn" then
            addError(errors, "invalid_kind", "$.kind", "kind는 pendingTurn이어야 합니다.")
        end
        if not isRuntimeId(pending.battleId) then
            addError(errors, "invalid_battle_id", "$.battleId", "battleId가 올바르지 않습니다.")
        end
        if not isRuntimeId(pending.turnId) then
            addError(errors, "invalid_turn_id", "$.turnId", "turnId가 올바르지 않습니다.")
        end
        if pending.status ~= "awaitingOutput" then
            addError(errors, "invalid_pending_status", "$.status", "대기 트랜잭션 상태는 awaitingOutput이어야 합니다.")
        end

        local beforeResult = validateBattleState(pending.beforeState, staticData)
        if not beforeResult.ok then
            appendNestedErrors(errors, "$.beforeState", beforeResult)
        end
        local afterResult = validateBattleState(pending.afterState, staticData)
        if not afterResult.ok then
            appendNestedErrors(errors, "$.afterState", afterResult)
        end

        if type(pending.selectedCards) ~= "table" then
            addError(errors, "invalid_selected_cards", "$.selectedCards", "selectedCards가 테이블이 아닙니다.")
        else
            checkAllowedKeys(pending.selectedCards, { player = true, character = true }, "$.selectedCards", errors)
            validateIdArray(pending.selectedCards.player, "$.selectedCards.player", errors, isRuntimeId)
            validateIdArray(pending.selectedCards.character, "$.selectedCards.character", errors, isRuntimeId)
        end

        if type(pending.turnResult) ~= "table" then
            addError(errors, "invalid_turn_result", "$.turnResult", "turnResult가 테이블이 아닙니다.")
        else
            checkAllowedKeys(pending.turnResult, {
                events = true,
                publicResult = true,
                llmEvent = true,
            }, "$.turnResult", errors)

            getArrayLength(pending.turnResult.events, "$.turnResult.events", errors)
            validateEventEnvelope(pending.turnResult.publicResult, "$.turnResult.publicResult", errors)
            validateEventEnvelope(pending.turnResult.llmEvent, "$.turnResult.llmEvent", errors)
        end

        if type(pending.beforeState) == "table" and type(pending.afterState) == "table" then
            if pending.beforeState.battleId ~= pending.battleId then
                addError(errors, "before_battle_mismatch", "$.beforeState.battleId", "beforeState의 전투 ID가 다릅니다.")
            end
            if pending.afterState.battleId ~= pending.battleId then
                addError(errors, "after_battle_mismatch", "$.afterState.battleId", "afterState의 전투 ID가 다릅니다.")
            end
            if pending.beforeState.lastCommittedTurnId == pending.turnId then
                addError(errors, "turn_already_committed", "$.beforeState.lastCommittedTurnId", "beforeState에 이미 같은 턴이 반영되었습니다.")
            end
            if pending.afterState.lastCommittedTurnId ~= pending.turnId then
                addError(errors, "after_turn_not_marked", "$.afterState.lastCommittedTurnId", "afterState에 대기 턴 ID가 기록되어야 합니다.")
            end
            if pending.beforeState.status ~= "active" then
                addError(errors, "before_state_not_active", "$.beforeState.status", "종료된 전투에서 새 대기 턴을 만들 수 없습니다.")
            end
            if isInteger(pending.beforeState.turnNumber, 1)
                and isInteger(pending.afterState.turnNumber, 1)
                and pending.afterState.turnNumber < pending.beforeState.turnNumber then
                addError(errors, "turn_number_reversed", "$.afterState.turnNumber", "afterState의 턴 번호가 이전으로 돌아갈 수 없습니다.")
            elseif isInteger(pending.beforeState.turnNumber, 1)
                and isInteger(pending.afterState.turnNumber, 1)
                and pending.afterState.turnNumber > pending.beforeState.turnNumber + 1 then
                addError(errors, "turn_number_skipped", "$.afterState.turnNumber", "한 번의 대기 트랜잭션에서 턴을 둘 이상 건너뛸 수 없습니다.")
            end
            if pending.afterState.turnLimit ~= pending.beforeState.turnLimit then
                addError(errors, "turn_limit_changed", "$.afterState.turnLimit", "한 턴 판정 중 제한 턴을 바꿀 수 없습니다.")
            end
            if pending.afterState.environmentId ~= pending.beforeState.environmentId then
                addError(errors, "environment_changed", "$.afterState.environmentId", "한 턴 판정 중 환경을 바꿀 수 없습니다.")
            end
            local beforeCharacter = type(pending.beforeState.character) == "table" and pending.beforeState.character.characterId or nil
            local afterCharacter = type(pending.afterState.character) == "table" and pending.afterState.character.characterId or nil
            if afterCharacter ~= beforeCharacter then
                addError(errors, "character_changed", "$.afterState.character.characterId", "한 전투의 캐릭터를 턴 판정 중 바꿀 수 없습니다.")
            end
            local beforeRng = pending.beforeState.rng
            local afterRng = pending.afterState.rng
            if type(beforeRng) == "table" and type(afterRng) == "table" then
                if afterRng.seed ~= beforeRng.seed then
                    addError(errors, "rng_seed_changed", "$.afterState.rng.seed", "한 전투의 난수 시드를 턴 판정 중 바꿀 수 없습니다.")
                end
                if isInteger(beforeRng.cursor, 0)
                    and isInteger(afterRng.cursor, 0)
                    and afterRng.cursor < beforeRng.cursor then
                    addError(errors, "rng_cursor_reversed", "$.afterState.rng.cursor", "난수 커서는 이전으로 돌아갈 수 없습니다.")
                end
            end

            if type(pending.selectedCards) == "table" then
                local selected = type(pending.beforeState.selection) == "table"
                    and pending.beforeState.selection.playerCardInstanceIds
                    or nil
                local intent = type(pending.beforeState.characterIntent) == "table"
                    and pending.beforeState.characterIntent.cardInstanceIds
                    or nil
                if not arraysEqual(pending.selectedCards.player, selected) then
                    addError(errors, "player_selection_mismatch", "$.selectedCards.player", "beforeState의 플레이어 선택과 다릅니다.")
                end
                if not arraysEqual(pending.selectedCards.character, intent) then
                    addError(errors, "character_selection_mismatch", "$.selectedCards.character", "beforeState의 캐릭터 선택과 다릅니다.")
                end
            end
        end

        local report = result(errors, pending)
        report.referencesValidated = referencesValidated
        return report
    end

    local function cloneJson(value, active)
        local valueType = type(value)
        if valueType ~= "table" then
            if valueType == "string" or valueType == "number" or valueType == "boolean" or valueType == "nil" then
                return value
            end
            error("unsupported type: " .. valueType)
        end
        if getmetatable(value) ~= nil then
            error("metatable is not allowed")
        end
        active = active or {}
        if active[value] then
            error("circular reference")
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            copy[cloneJson(key, active)] = cloneJson(item, active)
        end
        active[value] = nil
        return copy
    end

    local function constructBattleState(options, staticData)
        if type(options) ~= "table" then
            local errors = {}
            addError(errors, "invalid_options", "$", "battleState 생성 사양이 테이블이 아닙니다.")
            return result(errors)
        end

        local ok, state = pcall(function()
            local value = cloneJson(options)
            value.schemaVersion = SCHEMA_VERSION
            value.kind = "battleState"
            return value
        end)

        if not ok then
            local errors = {}
            addError(errors, "construct_failed", "$", "battleState 생성에 실패했습니다: " .. tostring(state))
            return result(errors)
        end

        local validation = validateBattleState(state, staticData)
        if not validation.ok then
            return validation
        end
        local report = result({}, state)
        report.referencesValidated = validation.referencesValidated
        return report
    end

    local function constructPendingTurn(spec, staticData)
        if type(spec) ~= "table" then
            local errors = {}
            addError(errors, "invalid_spec", "$", "pendingTurn 생성 사양이 테이블이 아닙니다.")
            return result(errors)
        end

        local ok, pending = pcall(function()
            local value = cloneJson(spec)
            value.schemaVersion = SCHEMA_VERSION
            value.kind = "pendingTurn"
            value.status = "awaitingOutput"
            return value
        end)

        if not ok then
            local errors = {}
            addError(errors, "construct_failed", "$", "pendingTurn 생성에 실패했습니다: " .. tostring(pending))
            return result(errors)
        end

        local validation = validatePendingTurn(pending, staticData)
        if not validation.ok then
            return validation
        end
        local report = result({}, pending)
        report.referencesValidated = validation.referencesValidated
        return report
    end

    local arguments = { ... }
    if action == "newBattleState" then
        return constructBattleState(arguments[1], arguments[2])
    elseif action == "validateBattleState" then
        return validateBattleState(arguments[1], arguments[2])
    elseif action == "newPendingTurn" then
        return constructPendingTurn(arguments[1], arguments[2])
    elseif action == "validatePendingTurn" then
        return validatePendingTurn(arguments[1], arguments[2])
    end

    local errors = {}
    addError(errors, "unknown_action", "$", "지원하지 않는 상태 스키마 작업입니다: " .. tostring(action))
    return result(errors)
end)
