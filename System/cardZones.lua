(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_PLAN_CAPACITY = 16

    local VALID_OWNER = {
        player = true,
        character = true,
    }

    local ZONE_ORDER = {
        "deck",
        "hand",
        "used",
        "discard",
        "removed",
        "plan",
    }

    local VALID_ZONE = {}
    for _, zone in ipairs(ZONE_ORDER) do
        VALID_ZONE[zone] = true
    end

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

    local function success(state, movedInstanceIds, drawnInstanceIds)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            state = state,
            movedInstanceIds = movedInstanceIds or {},
            drawnInstanceIds = drawnInstanceIds or {},
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

    local function isPlanCapacity(value)
        return isInteger(value, 1) and value <= MAX_PLAN_CAPACITY
    end

    local function cloneFailure(code, path, message)
        error(makeError(code, path, message), 0)
    end

    local function cloneJson(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value
        end
        if valueType == "number" then
            if not isFinite(value) then
                cloneFailure("non_finite_number", path, "NaN과 무한대는 카드 영역 상태에 사용할 수 없습니다.")
            end
            return value
        end
        if valueType ~= "table" then
            cloneFailure(
                "unsupported_type",
                path,
                "JSON 상태에 저장할 수 없는 자료형입니다: " .. valueType
            )
        end
        if getmetatable(value) ~= nil then
            cloneFailure("metatable_not_allowed", path, "상태 테이블에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            cloneFailure("circular_reference", path, "순환 참조가 있는 상태는 복제할 수 없습니다.")
        end
        active[value] = true

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
                    cloneFailure("invalid_array_index", path, "배열 인덱스는 1 이상의 정수여야 합니다.")
                end
                if key > maximum then
                    maximum = key
                end
            elseif type(key) == "string" then
                hasString = true
                table.insert(stringKeys, key)
            else
                cloneFailure("invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
            end
        end

        if hasNumeric and hasString then
            cloneFailure("mixed_table", path, "숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
        end

        local copy = {}
        if hasNumeric then
            if numericCount ~= maximum then
                cloneFailure("sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
            end
            for index = 1, maximum do
                copy[index] = cloneJson(value[index], path .. "[" .. index .. "]", active)
            end
        else
            table.sort(stringKeys)
            for _, key in ipairs(stringKeys) do
                copy[key] = cloneJson(value[key], path .. "." .. key, active)
            end
        end

        active[value] = nil
        return copy
    end

    local function cloneState(state, rootPath)
        rootPath = rootPath or "$"
        if type(state) ~= "table" then
            return nil, makeError("invalid_state", rootPath, "battleState가 테이블이 아닙니다.")
        end

        local ok, cloned = pcall(cloneJson, state, rootPath, {})
        if not ok then
            if type(cloned) == "table" and cloned.code and cloned.path and cloned.message then
                return nil, cloned
            end
            return nil, makeError("clone_failed", rootPath, "battleState 복제에 실패했습니다: " .. tostring(cloned))
        end
        return cloned, nil
    end

    local function validateOwner(owner, path)
        if not VALID_OWNER[owner] then
            return makeError("invalid_owner", path, "소유자는 player 또는 character여야 합니다.")
        end
        return nil
    end

    local validatePlanLinks

    local function validateCardInstances(state, rootPath)
        rootPath = rootPath or "$"
        local errors = {}
        if type(state.cardInstances) ~= "table" then
            table.insert(errors, makeError("invalid_card_instances", rootPath .. ".cardInstances", "카드 인스턴스 배열이 없습니다."))
            return errors
        end

        local itemCount = 0
        local maximum = 0
        local arrayShapeValid = true
        for key in pairs(state.cardInstances) do
            if not isInteger(key, 1) then
                arrayShapeValid = false
                table.insert(errors, makeError(
                    "invalid_card_instances",
                    rootPath .. ".cardInstances",
                    "cardInstances는 1부터 이어지는 배열이어야 합니다."
                ))
                break
            end
            itemCount = itemCount + 1
            if key > maximum then
                maximum = key
            end
        end
        if arrayShapeValid and itemCount ~= maximum then
            arrayShapeValid = false
            table.insert(errors, makeError(
                "sparse_card_instances",
                rootPath .. ".cardInstances",
                "cardInstances 배열에 빈 인덱스가 있습니다."
            ))
        end
        if not arrayShapeValid then
            return errors
        end

        local seenIds = {}
        local instancesById = {}
        local positions = {}
        local groupCounts = {}
        for index, instance in ipairs(state.cardInstances) do
            local path = rootPath .. ".cardInstances[" .. index .. "]"
            if type(instance) ~= "table" then
                table.insert(errors, makeError("invalid_card_instance", path, "카드 인스턴스가 테이블이 아닙니다."))
            else
                if type(instance.instanceId) ~= "string" or instance.instanceId == "" then
                    table.insert(errors, makeError("invalid_instance_id", path .. ".instanceId", "카드 인스턴스 ID가 없습니다."))
                elseif seenIds[instance.instanceId] then
                    table.insert(errors, makeError("duplicate_instance_id", path .. ".instanceId", "카드 인스턴스 ID가 중복되었습니다."))
                else
                    seenIds[instance.instanceId] = true
                    instancesById[instance.instanceId] = instance
                end
                if type(instance.cardId) ~= "string" or instance.cardId == "" then
                    table.insert(errors, makeError("invalid_card_id", path .. ".cardId", "카드 ID가 없습니다."))
                end

                local ownerError = validateOwner(instance.owner, path .. ".owner")
                if ownerError then
                    table.insert(errors, ownerError)
                end
                if not VALID_ZONE[instance.zone] then
                    table.insert(errors, makeError("invalid_zone", path .. ".zone", "알 수 없는 카드 영역입니다."))
                end
                if not isInteger(instance.position, 1) then
                    table.insert(errors, makeError("invalid_position", path .. ".position", "카드 위치는 1 이상의 정수여야 합니다."))
                elseif VALID_OWNER[instance.owner] and VALID_ZONE[instance.zone] then
                    local group = instance.owner .. ":" .. instance.zone
                    positions[group] = positions[group] or {}
                    groupCounts[group] = (groupCounts[group] or 0) + 1
                    if positions[group][instance.position] then
                        table.insert(errors, makeError(
                            "duplicate_position",
                            path .. ".position",
                            group .. " 영역의 position이 중복되었습니다."
                        ))
                    end
                    positions[group][instance.position] = true
                end
            end
        end

        for group, groupPositions in pairs(positions) do
            local uniqueCount = 0
            local maximum = 0
            for position in pairs(groupPositions) do
                uniqueCount = uniqueCount + 1
                if position > maximum then
                    maximum = position
                end
            end
            if uniqueCount ~= maximum then
                table.insert(errors, makeError(
                    "non_contiguous_positions",
                    rootPath .. ".cardInstances",
                    group .. " 영역의 position이 1부터 이어지지 않습니다."
                ))
            end
        end

        for _, owner in ipairs({ "player", "character" }) do
            local ownerState = state[owner]
            if type(ownerState) ~= "table" then
                table.insert(errors, makeError("missing_owner_state", rootPath .. "." .. owner, "소유자 전투 상태가 없습니다."))
            elseif not isInteger(ownerState.maxHandSize, 1) then
                table.insert(errors, makeError(
                    "invalid_hand_size",
                    rootPath .. "." .. owner .. ".maxHandSize",
                    "최대 손패는 1 이상의 정수여야 합니다."
                ))
            else
                local handCount = groupCounts[owner .. ":hand"] or 0
                if handCount > ownerState.maxHandSize then
                    local overflowAllowed = false
                    if owner == "player"
                        and type(state.selection) == "table"
                        and type(state.selection.playerCardInstanceIds) == "table" then
                        local restoredSelectionCount = 0
                        local counted = {}
                        for _, instanceId in ipairs(state.selection.playerCardInstanceIds) do
                            local selected = instancesById[instanceId]
                            if selected
                                and selected.owner == "player"
                                and selected.zone == "hand"
                                and not counted[instanceId] then
                                counted[instanceId] = true
                                restoredSelectionCount = restoredSelectionCount + 1
                            end
                        end
                        overflowAllowed = restoredSelectionCount >= handCount - ownerState.maxHandSize
                    end
                    if not overflowAllowed then
                        table.insert(errors, makeError(
                            "hand_limit_exceeded",
                            rootPath .. ".cardInstances",
                            owner .. " 손패가 최대 손패를 초과했습니다."
                        ))
                    end
                end
            end
        end
        return errors
    end

    local function prepareState(state)
        local cloned, cloneError = cloneState(state)
        if cloneError then
            return nil, { cloneError }
        end

        local errors = validateCardInstances(cloned)
        if #errors == 0 then
            local planErrors = validatePlanLinks(cloned, "$")
            for _, item in ipairs(planErrors) do
                table.insert(errors, item)
            end
        end
        if #errors > 0 then
            return nil, errors
        end
        return cloned, nil
    end

    local function collectZone(state, owner, zone)
        local values = {}
        for index, instance in ipairs(state.cardInstances) do
            if instance.owner == owner and instance.zone == zone then
                table.insert(values, {
                    instance = instance,
                    sourceIndex = index,
                })
            end
        end

        table.sort(values, function(left, right)
            if left.instance.position ~= right.instance.position then
                return left.instance.position < right.instance.position
            end
            if left.instance.instanceId ~= right.instance.instanceId then
                return left.instance.instanceId < right.instance.instanceId
            end
            return left.sourceIndex < right.sourceIndex
        end)
        return values
    end

    local function normalizeZone(state, owner, zone)
        for position, entry in ipairs(collectZone(state, owner, zone)) do
            entry.instance.position = position
        end
    end

    local function normalizeAll(state)
        for _, owner in ipairs({ "player", "character" }) do
            for _, zone in ipairs(ZONE_ORDER) do
                normalizeZone(state, owner, zone)
            end
        end
    end

    local function findInstance(state, instanceId)
        for _, instance in ipairs(state.cardInstances) do
            if instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function nextPosition(state, owner, zone)
        return #collectZone(state, owner, zone) + 1
    end

    local function denseArrayLength(value)
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
            if key > maximum then
                maximum = key
            end
        end
        if count ~= maximum then
            return nil
        end
        return maximum
    end

    local function validatePositionContinuity(state, rootPath)
        rootPath = rootPath or "$"
        local errors = {}
        local groups = {}
        for index, instance in ipairs(state.cardInstances) do
            if VALID_OWNER[instance.owner]
                and VALID_ZONE[instance.zone]
                and isInteger(instance.position, 1) then
                local group = instance.owner .. ":" .. instance.zone
                groups[group] = groups[group] or {}
                if groups[group][instance.position] then
                    table.insert(errors, makeError(
                        "duplicate_position",
                        rootPath .. ".cardInstances[" .. index .. "].position",
                        group .. " 영역의 position이 중복되었습니다."
                    ))
                end
                groups[group][instance.position] = true
            end
        end

        for group, positions in pairs(groups) do
            local count = 0
            local maximum = 0
            for position in pairs(positions) do
                count = count + 1
                if position > maximum then
                    maximum = position
                end
            end
            if count ~= maximum then
                table.insert(errors, makeError(
                    "non_contiguous_positions",
                    rootPath .. ".cardInstances",
                    group .. " 영역의 position이 1부터 이어지지 않습니다."
                ))
            end
        end
        return errors
    end

    validatePlanLinks = function(state, rootPath)
        rootPath = rootPath or "$"
        local errors = {}
        for _, side in ipairs({ "player", "character" }) do
            local sidePath = rootPath .. "." .. side
            local ownerState = state[side]
            if type(ownerState) ~= "table" then
                table.insert(errors, makeError("missing_owner_state", sidePath, "소유자 전투 상태가 없습니다."))
            else
                local slots = ownerState.planSlots
                local slotsPath = sidePath .. ".planSlots"
                local slotCount = denseArrayLength(slots)
                local planInstances = collectZone(state, side, "plan")
                if not isPlanCapacity(ownerState.planCapacity) then
                    table.insert(errors, makeError(
                        "invalid_plan_capacity",
                        sidePath .. ".planCapacity",
                        "계획 용량은 1 이상 16 이하의 정수여야 합니다."
                    ))
                end
                if slotCount == nil then
                    table.insert(errors, makeError(
                        "invalid_plan_slots",
                        slotsPath,
                        "planSlots는 점유 계획만 담는 1부터 이어지는 배열이어야 합니다."
                    ))
                else
                    if isPlanCapacity(ownerState.planCapacity) and slotCount > ownerState.planCapacity then
                        table.insert(errors, makeError(
                            "plan_capacity_exceeded",
                            slotsPath,
                            "점유 계획 수가 계획 용량을 초과했습니다."
                        ))
                    end
                    if #planInstances ~= slotCount then
                        table.insert(errors, makeError(
                            "plan_link_mismatch",
                            rootPath .. ".cardInstances",
                            "plan 영역과 planSlots 수가 일치하지 않습니다: " .. side
                        ))
                    end

                    local seenInstanceIds = {}
                    for index = 1, slotCount do
                        local slot = slots[index]
                        local slotPath = slotsPath .. "[" .. index .. "]"
                        if type(slot) ~= "table" or getmetatable(slot) ~= nil then
                            table.insert(errors, makeError("invalid_plan_slot", slotPath, "계획 슬롯이 일반 테이블이 아닙니다."))
                        elseif slot.occupied ~= true then
                            table.insert(errors, makeError(
                                "invalid_plan_occupied",
                                slotPath .. ".occupied",
                                "planSlots에는 occupied = true인 점유 슬롯만 저장할 수 있습니다."
                            ))
                        else
                            if type(slot.cardInstanceId) == "string" and slot.cardInstanceId ~= "" then
                                if seenInstanceIds[slot.cardInstanceId] then
                                    table.insert(errors, makeError(
                                        "duplicate_plan_slot",
                                        slotPath .. ".cardInstanceId",
                                        "같은 계획 카드 인스턴스가 planSlots에 중복되었습니다."
                                    ))
                                else
                                    seenInstanceIds[slot.cardInstanceId] = true
                                end
                            end

                            local instance = findInstance(state, slot.cardInstanceId)
                            if not instance then
                                table.insert(errors, makeError("missing_plan_instance", slotPath .. ".cardInstanceId", "계획 카드 인스턴스를 찾을 수 없습니다."))
                            else
                                if instance.owner ~= side then
                                    table.insert(errors, makeError("plan_owner_mismatch", slotPath .. ".cardInstanceId", "계획 슬롯과 카드 소유자가 다릅니다."))
                                end
                                if instance.zone ~= "plan" then
                                    table.insert(errors, makeError("plan_zone_mismatch", slotPath .. ".cardInstanceId", "계획 카드의 zone이 plan이 아닙니다."))
                                end
                                if instance.cardId ~= slot.cardId then
                                    table.insert(errors, makeError("plan_card_mismatch", slotPath .. ".cardId", "계획 슬롯과 카드 인스턴스의 cardId가 다릅니다."))
                                end
                                if instance.position ~= index then
                                    table.insert(errors, makeError(
                                        "plan_position_mismatch",
                                        slotPath .. ".cardInstanceId",
                                        "plan 영역 position은 planSlots 배열 인덱스와 일치해야 합니다."
                                    ))
                                end
                            end
                            if not planInstances[index]
                                or planInstances[index].instance.instanceId ~= slot.cardInstanceId then
                                table.insert(errors, makeError(
                                    "plan_link_mismatch",
                                    rootPath .. ".cardInstances",
                                    "plan 영역 순서와 planSlots 배열 순서가 일치하지 않습니다: " .. side
                                ))
                            end
                            if not isInteger(slot.placedTurn, 1) then
                                table.insert(errors, makeError("invalid_placed_turn", slotPath .. ".placedTurn", "계획 배치 턴은 1 이상의 정수여야 합니다."))
                            elseif isInteger(state.turnNumber, 1) and slot.placedTurn > state.turnNumber then
                                table.insert(errors, makeError("future_placed_turn", slotPath .. ".placedTurn", "계획 배치 턴은 현재 턴보다 클 수 없습니다."))
                            end
                            if slot.revealed ~= true and slot.revealed ~= false then
                                table.insert(errors, makeError("invalid_revealed", slotPath .. ".revealed", "revealed는 불리언이어야 합니다."))
                            end
                            if slot.effectChoiceId ~= nil
                                and (type(slot.effectChoiceId) ~= "string"
                                    or string.match(slot.effectChoiceId, "^[a-z][a-z0-9_]*$") == nil) then
                                table.insert(errors, makeError("invalid_effect_choice_id", slotPath .. ".effectChoiceId", "계획 효과 선택지 ID가 올바르지 않습니다."))
                            end
                            if slot.durationIncludesPlacementTurn ~= nil
                                and type(slot.durationIncludesPlacementTurn) ~= "boolean" then
                                table.insert(errors, makeError(
                                    "invalid_plan_duration_policy",
                                    slotPath .. ".durationIncludesPlacementTurn",
                                    "배치 턴 포함 여부는 불리언이어야 합니다."
                                ))
                            elseif slot.durationIncludesPlacementTurn == true and slot.remainingTurns == nil then
                                table.insert(errors, makeError(
                                    "plan_duration_policy_requires_duration",
                                    slotPath .. ".durationIncludesPlacementTurn",
                                    "배치 턴을 포함하는 계획에는 남은 지속시간이 필요합니다."
                                ))
                            end

                            local hasLifetime = false
                            if slot.remainingTurns ~= nil then
                                hasLifetime = true
                                if not isInteger(slot.remainingTurns, 1) then
                                    table.insert(errors, makeError("invalid_remaining_turns", slotPath .. ".remainingTurns", "점유된 계획의 남은 지속시간은 양의 정수여야 합니다."))
                                end
                            end
                            if slot.remainingCharges ~= nil then
                                hasLifetime = true
                                if not isInteger(slot.remainingCharges, 1) then
                                    table.insert(errors, makeError("invalid_remaining_charges", slotPath .. ".remainingCharges", "점유된 계획의 남은 충전은 양의 정수여야 합니다."))
                                end
                            end
                            if not hasLifetime then
                                table.insert(errors, makeError("missing_plan_lifetime", slotPath, "점유된 계획에는 지속시간이나 충전이 필요합니다."))
                            end
                        end
                    end
                end
            end
        end
        return errors
    end

    local function appendErrors(target, source)
        for _, item in ipairs(source or {}) do
            table.insert(target, item)
        end
    end

    local function syncPlanPositions(state, side)
        local ownerState = state[side]
        for index, slot in ipairs(ownerState.planSlots) do
            local instance = findInstance(state, slot.cardInstanceId)
            if instance then
                instance.position = index
            end
        end
    end

    local function discardPlanAt(state, side, slotIndex)
        local ownerState = state[side]
        local slot = ownerState.planSlots[slotIndex]
        local instance = findInstance(state, slot.cardInstanceId)
        instance.zone = "discard"
        instance.position = nextPosition(state, side, "discard")
        table.remove(ownerState.planSlots, slotIndex)
        syncPlanPositions(state, side)
        return instance.instanceId
    end

    local function findPlanSlotIndex(state, side, instanceId)
        for index, slot in ipairs(state[side].planSlots) do
            if slot.cardInstanceId == instanceId then
                return index
            end
        end
        return nil
    end

    local function appendNestedErrors(errors, nested)
        if type(nested) ~= "table" or #nested == 0 then
            table.insert(errors, makeError("rng_failed", "$.rng", "결정적 셔플이 실패했습니다."))
            return
        end
        for _, item in ipairs(nested) do
            table.insert(errors, makeError(
                "rng_" .. tostring(item.code or "failed"),
                tostring(item.path or "$.rng"),
                tostring(item.message or "결정적 셔플이 실패했습니다.")
            ))
        end
    end

    local function shuffleIds(state, instanceIds)
        local callOk, report = pcall(
            runScript,
            triggerId,
            "deterministicRng",
            "shuffle",
            state.rng,
            instanceIds
        )
        if not callOk then
            return nil, { makeError("rng_call_failed", "$.rng", "결정적 셔플 호출에 실패했습니다: " .. tostring(report)) }
        end
        if type(report) ~= "table" or report.ok ~= true then
            local errors = {}
            appendNestedErrors(errors, type(report) == "table" and report.errors or nil)
            return nil, errors
        end
        if type(report.value) ~= "table" or #report.value ~= #instanceIds then
            return nil, { makeError("invalid_rng_result", "$.rng", "셔플 결과 배열의 길이가 올바르지 않습니다.") }
        end

        local expected = {}
        for _, instanceId in ipairs(instanceIds) do
            expected[instanceId] = (expected[instanceId] or 0) + 1
        end
        for index, instanceId in ipairs(report.value) do
            if type(instanceId) ~= "string" or not expected[instanceId] or expected[instanceId] == 0 then
                return nil, { makeError("invalid_rng_result", "$.rng.value[" .. index .. "]", "셔플 결과가 원본 카드 ID 순열이 아닙니다.") }
            end
            expected[instanceId] = expected[instanceId] - 1
        end

        local rngOk, rngCopy = pcall(cloneJson, report.rng, "$.rng", {})
        if not rngOk or type(rngCopy) ~= "table" then
            return nil, { makeError("invalid_rng_result", "$.rng", "셔플 결과의 RNG 상태가 올바르지 않습니다.") }
        end
        state.rng = rngCopy

        local valueCopy = {}
        for index, instanceId in ipairs(report.value) do
            valueCopy[index] = instanceId
        end
        return valueCopy, nil
    end

    local function applyZoneOrder(state, owner, zone, instanceIds)
        for position, instanceId in ipairs(instanceIds) do
            local instance = findInstance(state, instanceId)
            if not instance or instance.owner ~= owner then
                return makeError("invalid_zone_order", "$.cardInstances", "카드 영역 순서를 적용할 인스턴스를 찾을 수 없습니다.")
            end
            instance.zone = zone
            instance.position = position
        end
        return nil
    end

    local function shuffleDeck(state, owner)
        local ownerError = validateOwner(owner, "$.owner")
        if ownerError then
            return failure({ ownerError })
        end

        local nextState, errors = prepareState(state)
        if errors then
            return failure(errors)
        end
        normalizeAll(nextState)

        local instanceIds = {}
        for _, entry in ipairs(collectZone(nextState, owner, "deck")) do
            table.insert(instanceIds, entry.instance.instanceId)
        end
        local shuffled, shuffleErrors = shuffleIds(nextState, instanceIds)
        if shuffleErrors then
            return failure(shuffleErrors)
        end
        local orderError = applyZoneOrder(nextState, owner, "deck", shuffled)
        if orderError then
            return failure({ orderError })
        end

        normalizeAll(nextState)
        return success(nextState, {}, {})
    end

    local function draw(state, owner, amount)
        local errors = {}
        local ownerError = validateOwner(owner, "$.owner")
        if ownerError then
            table.insert(errors, ownerError)
        end
        if not isInteger(amount, 0) then
            table.insert(errors, makeError("invalid_draw_amount", "$.amount", "드로우 수량은 0 이상의 정수여야 합니다."))
        end
        if #errors > 0 then
            return failure(errors)
        end

        local nextState, stateErrors = prepareState(state)
        if stateErrors then
            return failure(stateErrors)
        end
        normalizeAll(nextState)

        local ownerState = nextState[owner]
        if type(ownerState) ~= "table" then
            return failure({ makeError("missing_owner_state", "$." .. owner, "소유자 전투 상태가 없습니다.") })
        end
        if not isInteger(ownerState.maxHandSize, 1) then
            return failure({ makeError("invalid_hand_size", "$." .. owner .. ".maxHandSize", "최대 손패는 1 이상의 정수여야 합니다.") })
        end

        local handCount = #collectZone(nextState, owner, "hand")
        local capacity = math.max(0, ownerState.maxHandSize - handCount)
        local targetCount = math.min(amount, capacity)
        local drawnInstanceIds = {}

        while #drawnInstanceIds < targetCount do
            local deck = collectZone(nextState, owner, "deck")
            if #deck == 0 then
                local discardIds = {}
                for _, entry in ipairs(collectZone(nextState, owner, "discard")) do
                    table.insert(discardIds, entry.instance.instanceId)
                end
                if #discardIds == 0 then
                    break
                end

                local shuffled, shuffleErrors = shuffleIds(nextState, discardIds)
                if shuffleErrors then
                    return failure(shuffleErrors)
                end
                local orderError = applyZoneOrder(nextState, owner, "deck", shuffled)
                if orderError then
                    return failure({ orderError })
                end
                normalizeZone(nextState, owner, "discard")
                normalizeZone(nextState, owner, "deck")
                deck = collectZone(nextState, owner, "deck")
            end

            local drawn = deck[1].instance
            drawn.zone = "hand"
            drawn.position = nextPosition(nextState, owner, "hand")
            table.insert(drawnInstanceIds, drawn.instanceId)
            normalizeZone(nextState, owner, "deck")
            normalizeZone(nextState, owner, "hand")
        end

        normalizeAll(nextState)
        return success(nextState, {}, drawnInstanceIds)
    end

    local function moveHandToUsed(state, instanceId)
        if type(instanceId) ~= "string" or instanceId == "" then
            return failure({ makeError("invalid_instance_id", "$.instanceId", "카드 인스턴스 ID가 없습니다.") })
        end

        local nextState, errors = prepareState(state)
        if errors then
            return failure(errors)
        end
        normalizeAll(nextState)

        local instance = findInstance(nextState, instanceId)
        if not instance then
            return failure({ makeError("instance_not_found", "$.instanceId", "카드 인스턴스를 찾을 수 없습니다.") })
        end
        if instance.zone ~= "hand" then
            return failure({ makeError("invalid_source_zone", "$.instanceId", "used 영역으로 옮길 카드는 hand 영역에 있어야 합니다.") })
        end

        instance.zone = "used"
        instance.position = nextPosition(nextState, instance.owner, "used")
        normalizeAll(nextState)
        return success(nextState, { instanceId }, {})
    end

    local function moveUsedToHand(state, instanceId)
        if type(instanceId) ~= "string" or instanceId == "" then
            return failure({ makeError("invalid_instance_id", "$.instanceId", "카드 인스턴스 ID가 없습니다.") })
        end

        local nextState, errors = prepareState(state)
        if errors then
            return failure(errors)
        end
        normalizeAll(nextState)

        local instance = findInstance(nextState, instanceId)
        if not instance then
            return failure({ makeError("instance_not_found", "$.instanceId", "카드 인스턴스를 찾을 수 없습니다.") })
        end
        if instance.zone ~= "used" then
            return failure({ makeError("invalid_source_zone", "$.instanceId", "hand 영역으로 복원할 카드는 used 영역에 있어야 합니다.") })
        end
        if instance.owner ~= "player" then
            return failure({ makeError("invalid_restore_owner", "$.instanceId", "used → hand 구조 복원은 플레이어 등록 카드에만 사용할 수 있습니다.") })
        end
        local registered = false
        for _, selectedId in ipairs(
            type(nextState.selection) == "table"
                and type(nextState.selection.playerCardInstanceIds) == "table"
                and nextState.selection.playerCardInstanceIds
                or {}
        ) do
            if selectedId == instanceId then
                registered = true
                break
            end
        end
        if not registered then
            return failure({ makeError("restore_requires_selection", "$.instanceId", "등록 선택에 없는 used 카드는 손패로 복원할 수 없습니다.") })
        end

        local ownerState = nextState[instance.owner]
        if type(ownerState) ~= "table" or not isInteger(ownerState.maxHandSize, 1) then
            return failure({ makeError(
                "invalid_hand_size",
                "$." .. tostring(instance.owner) .. ".maxHandSize",
                "최대 손패는 1 이상의 정수여야 합니다."
            ) })
        end
        instance.zone = "hand"
        instance.position = nextPosition(nextState, instance.owner, "hand")
        normalizeAll(nextState)
        return success(nextState, { instanceId }, {})
    end

    local function moveToRemoved(state, instanceId)
        if type(instanceId) ~= "string" or instanceId == "" then
            return failure({ makeError("invalid_instance_id", "$.instanceId", "카드 인스턴스 ID가 없습니다.") })
        end

        local nextState, errors = prepareState(state)
        if errors then
            return failure(errors)
        end
        normalizeAll(nextState)

        local instance = findInstance(nextState, instanceId)
        if not instance then
            return failure({ makeError("instance_not_found", "$.instanceId", "카드 인스턴스를 찾을 수 없습니다.") })
        end
        if instance.zone == "removed" then
            return failure({ makeError("already_removed", "$.instanceId", "카드가 이미 removed 영역에 있습니다.") })
        end
        if instance.zone == "plan" then
            return failure({ makeError("plan_slot_required", "$.instanceId", "plan 카드는 계획 슬롯 처리 없이 removed 영역으로 옮길 수 없습니다.") })
        end

        instance.zone = "removed"
        instance.position = nextPosition(nextState, instance.owner, "removed")
        normalizeAll(nextState)
        return success(nextState, { instanceId }, {})
    end

    local function validatePlanSpec(planSpec)
        local errors = {}
        if type(planSpec) ~= "table" or getmetatable(planSpec) ~= nil then
            return nil, {
                makeError("invalid_plan_spec", "$.planSpec", "planSpec은 메타테이블 없는 테이블이어야 합니다."),
            }
        end

        local allowed = {
            durationTurns = true,
            durationIncludesPlacementTurn = true,
            charges = true,
            revealed = true,
            effectChoiceId = true,
        }
        for key in pairs(planSpec) do
            if type(key) ~= "string" or not allowed[key] then
                table.insert(errors, makeError(
                    "unknown_plan_spec_field",
                    "$.planSpec." .. tostring(key),
                    "planSpec에 허용되지 않은 필드가 있습니다."
                ))
            end
        end

        if planSpec.durationTurns ~= nil and not isInteger(planSpec.durationTurns, 1) then
            table.insert(errors, makeError(
                "invalid_plan_duration",
                "$.planSpec.durationTurns",
                "계획 지속시간은 양의 정수여야 합니다."
            ))
        end
        if planSpec.durationIncludesPlacementTurn ~= nil
            and type(planSpec.durationIncludesPlacementTurn) ~= "boolean" then
            table.insert(errors, makeError(
                "invalid_plan_duration_policy",
                "$.planSpec.durationIncludesPlacementTurn",
                "배치 턴 포함 여부는 불리언이어야 합니다."
            ))
        elseif planSpec.durationIncludesPlacementTurn == true
            and not isInteger(planSpec.durationTurns, 1) then
            table.insert(errors, makeError(
                "plan_duration_policy_requires_duration",
                "$.planSpec.durationIncludesPlacementTurn",
                "배치 턴을 포함하려면 양의 durationTurns가 필요합니다."
            ))
        end
        if planSpec.charges ~= nil and not isInteger(planSpec.charges, 1) then
            table.insert(errors, makeError(
                "invalid_plan_charges",
                "$.planSpec.charges",
                "계획 충전은 양의 정수여야 합니다."
            ))
        end
        if planSpec.durationTurns == nil and planSpec.charges == nil then
            table.insert(errors, makeError(
                "missing_plan_lifetime",
                "$.planSpec",
                "계획에는 durationTurns 또는 charges가 필요합니다."
            ))
        end
        if planSpec.revealed ~= nil and planSpec.revealed ~= true and planSpec.revealed ~= false then
            table.insert(errors, makeError(
                "invalid_plan_revealed",
                "$.planSpec.revealed",
                "revealed는 불리언이어야 합니다."
            ))
        end
        if planSpec.effectChoiceId ~= nil
            and (type(planSpec.effectChoiceId) ~= "string"
                or string.match(planSpec.effectChoiceId, "^[a-z][a-z0-9_]*$") == nil) then
            table.insert(errors, makeError("invalid_effect_choice_id", "$.planSpec.effectChoiceId", "계획 효과 선택지 ID가 올바르지 않습니다."))
        end

        if #errors > 0 then
            return nil, errors
        end
        return {
            durationTurns = planSpec.durationTurns,
            durationIncludesPlacementTurn = planSpec.durationIncludesPlacementTurn == true,
            charges = planSpec.charges,
            revealed = planSpec.revealed == true,
            effectChoiceId = planSpec.effectChoiceId,
        }, nil
    end

    local function placePlan(state, side, instanceId, planSpec)
        local errors = {}
        local sideError = validateOwner(side, "$.side")
        if sideError then
            table.insert(errors, sideError)
        end
        if type(instanceId) ~= "string" or instanceId == "" then
            table.insert(errors, makeError("invalid_instance_id", "$.instanceId", "카드 인스턴스 ID가 없습니다."))
        end
        local normalizedSpec, specErrors = validatePlanSpec(planSpec)
        appendErrors(errors, specErrors)
        if #errors > 0 then
            return failure(errors)
        end

        local nextState, stateErrors = prepareState(state)
        if stateErrors then
            return failure(stateErrors)
        end
        normalizeAll(nextState)
        if not isInteger(nextState.turnNumber, 1) then
            return failure({ makeError("invalid_turn_number", "$.turnNumber", "현재 턴은 1 이상의 정수여야 합니다.") })
        end

        local planErrors = validatePlanLinks(nextState, "$")
        if #planErrors > 0 then
            return failure(planErrors)
        end

        local instance = findInstance(nextState, instanceId)
        if not instance then
            return failure({ makeError("instance_not_found", "$.instanceId", "카드 인스턴스를 찾을 수 없습니다.") })
        end
        if instance.owner ~= side then
            return failure({ makeError("plan_owner_mismatch", "$.instanceId", "계획 카드와 슬롯의 소유자가 다릅니다.") })
        end
        if instance.zone ~= "hand" and instance.zone ~= "used" then
            return failure({ makeError("invalid_source_zone", "$.instanceId", "계획 카드는 hand 또는 used 영역에 있어야 합니다.") })
        end

        local movedInstanceIds = {}
        local ownerState = nextState[side]
        if #ownerState.planSlots >= ownerState.planCapacity then
            table.insert(movedInstanceIds, discardPlanAt(nextState, side, 1))
        end

        instance.zone = "plan"
        instance.position = #ownerState.planSlots + 1
        local slot = {
            occupied = true,
            cardInstanceId = instance.instanceId,
            cardId = instance.cardId,
            placedTurn = nextState.turnNumber,
            durationIncludesPlacementTurn = normalizedSpec.durationIncludesPlacementTurn,
            revealed = normalizedSpec.revealed,
        }
        if normalizedSpec.durationTurns ~= nil then
            slot.remainingTurns = normalizedSpec.durationTurns
        end
        if normalizedSpec.charges ~= nil then
            slot.remainingCharges = normalizedSpec.charges
        end
        if normalizedSpec.effectChoiceId ~= nil then
            slot.effectChoiceId = normalizedSpec.effectChoiceId
        end
        table.insert(ownerState.planSlots, slot)
        table.insert(movedInstanceIds, instance.instanceId)

        normalizeAll(nextState)
        local outputErrors = validatePlanLinks(nextState, "$")
        if #outputErrors > 0 then
            return failure(outputErrors)
        end
        return success(nextState, movedInstanceIds, {})
    end

    local function consumePlanCharge(state, side, instanceId)
        local errors = {}
        local sideError = validateOwner(side, "$.side")
        if sideError then
            table.insert(errors, sideError)
        end
        if instanceId ~= nil and (type(instanceId) ~= "string" or instanceId == "") then
            table.insert(errors, makeError("invalid_instance_id", "$.instanceId", "계획 카드 인스턴스 ID가 올바르지 않습니다."))
        end
        if #errors > 0 then
            return failure(errors)
        end

        local nextState, stateErrors = prepareState(state)
        if stateErrors then
            return failure(stateErrors)
        end
        normalizeAll(nextState)
        local planErrors = validatePlanLinks(nextState, "$")
        if #planErrors > 0 then
            return failure(planErrors)
        end

        local slots = nextState[side].planSlots
        local slotIndex
        if instanceId == nil then
            if #slots == 0 then
                return failure({ makeError("empty_plan_slots", "$." .. side .. ".planSlots", "발동할 계획이 없습니다.") })
            end
            if #slots > 1 then
                return failure({ makeError(
                    "ambiguous_plan_slot",
                    "$.instanceId",
                    "점유 계획이 둘 이상이면 소비할 카드 인스턴스 ID를 지정해야 합니다."
                ) })
            end
            slotIndex = 1
            instanceId = slots[1].cardInstanceId
        else
            slotIndex = findPlanSlotIndex(nextState, side, instanceId)
            if slotIndex == nil then
                return failure({ makeError(
                    "plan_instance_not_found",
                    "$.instanceId",
                    "해당 진영의 점유 계획에서 카드 인스턴스를 찾을 수 없습니다."
                ) })
            end
        end

        local slot = slots[slotIndex]
        slot.revealed = true
        local movedInstanceIds = {}
        if slot.remainingCharges ~= nil then
            slot.remainingCharges = slot.remainingCharges - 1
            if slot.remainingCharges == 0 then
                table.insert(movedInstanceIds, discardPlanAt(nextState, side, slotIndex))
            end
        end

        normalizeAll(nextState)
        local outputErrors = validatePlanLinks(nextState, "$")
        if #outputErrors > 0 then
            return failure(outputErrors)
        end
        return success(nextState, movedInstanceIds, {})
    end

    local function setPlanCapacity(state, side, capacity)
        local errors = {}
        local sideError = validateOwner(side, "$.side")
        if sideError then
            table.insert(errors, sideError)
        end
        if not isPlanCapacity(capacity) then
            table.insert(errors, makeError(
                "invalid_plan_capacity",
                "$.capacity",
                "계획 용량은 1 이상 16 이하의 정수여야 합니다."
            ))
        end
        if #errors > 0 then
            return failure(errors)
        end

        local nextState, stateErrors = prepareState(state)
        if stateErrors then
            return failure(stateErrors)
        end
        normalizeAll(nextState)

        local ownerState = nextState[side]
        ownerState.planCapacity = capacity
        local movedInstanceIds = {}
        while #ownerState.planSlots > capacity do
            table.insert(movedInstanceIds, discardPlanAt(nextState, side, 1))
        end

        normalizeAll(nextState)
        local outputErrors = validatePlanLinks(nextState, "$")
        if #outputErrors > 0 then
            return failure(outputErrors)
        end
        return success(nextState, movedInstanceIds, {})
    end

    local function modifyOldestPlan(state, side, spec)
        local ownerError = validateOwner(side, "$.side")
        if ownerError then return failure({ ownerError }) end
        if type(spec) ~= "table" or getmetatable(spec) ~= nil then
            return failure({ makeError("invalid_plan_modification", "$.spec", "계획 변경 명세가 올바르지 않습니다.") })
        end
        local nextState, stateErrors = prepareState(state)
        if stateErrors then return failure(stateErrors) end
        normalizeAll(nextState)
        local slots = nextState[side].planSlots
        if #slots == 0 then return success(nextState, {}, {}) end
        local affectedIds = {}
        local lastIndex = spec.all == true and #slots or 1
        for index = lastIndex, 1, -1 do
            local slot = slots[index]
            table.insert(affectedIds, 1, slot.cardInstanceId)
            if spec.remove == true then
                discardPlanAt(nextState, side, index)
            else
                if spec.remainingTurnsDelta ~= nil and slot.remainingTurns ~= nil then
                    slot.remainingTurns = slot.remainingTurns + spec.remainingTurnsDelta
                end
                if spec.remainingChargesDelta ~= nil and slot.remainingCharges ~= nil then
                    slot.remainingCharges = math.max(1, slot.remainingCharges + spec.remainingChargesDelta)
                end
                if slot.remainingTurns ~= nil and slot.remainingTurns <= 0 then
                    discardPlanAt(nextState, side, index)
                end
            end
        end
        normalizeAll(nextState)
        local outputErrors = validatePlanLinks(nextState, "$")
        if #outputErrors > 0 then return failure(outputErrors) end
        return success(nextState, affectedIds, {})
    end

    local function endTurnCleanup(state)
        local nextState, stateErrors = prepareState(state)
        if stateErrors then
            return failure(stateErrors)
        end
        normalizeAll(nextState)
        if not isInteger(nextState.turnNumber, 1) then
            return failure({ makeError("invalid_turn_number", "$.turnNumber", "현재 턴은 1 이상의 정수여야 합니다.") })
        end

        local planErrors = validatePlanLinks(nextState, "$")
        if #planErrors > 0 then
            return failure(planErrors)
        end

        local movedInstanceIds = {}
        for _, side in ipairs({ "player", "character" }) do
            for _, sourceZone in ipairs({ "used", "hand" }) do
                local source = collectZone(nextState, side, sourceZone)
                for _, entry in ipairs(source) do
                    entry.instance.zone = "discard"
                    entry.instance.position = nextPosition(nextState, side, "discard")
                    table.insert(movedInstanceIds, entry.instance.instanceId)
                end
            end
        end

        nextState.selection = {
            playerCardInstanceIds = {},
        }
        nextState.characterIntent = {
            cardInstanceIds = {},
        }
        nextState.turnStartReceipt = nil

        for _, side in ipairs({ "player", "character" }) do
            local survivors = {}
            for _, slot in ipairs(nextState[side].planSlots) do
                if slot.remainingTurns ~= nil
                    and (slot.placedTurn < nextState.turnNumber
                        or slot.durationIncludesPlacementTurn == true) then
                    slot.remainingTurns = slot.remainingTurns - 1
                end

                if slot.remainingTurns == 0 then
                    local instance = findInstance(nextState, slot.cardInstanceId)
                    instance.zone = "discard"
                    instance.position = nextPosition(nextState, side, "discard")
                    table.insert(movedInstanceIds, instance.instanceId)
                else
                    table.insert(survivors, slot)
                end
            end
            nextState[side].planSlots = survivors
            syncPlanPositions(nextState, side)
        end

        normalizeAll(nextState)
        local outputErrors = validatePlanLinks(nextState, "$")
        if #outputErrors > 0 then
            return failure(outputErrors)
        end
        return success(nextState, movedInstanceIds, {})
    end

    local function validateConservation(beforeState, afterState)
        local beforeCopy, beforeCloneError = cloneState(beforeState, "$.beforeState")
        if beforeCloneError then
            return failure({ beforeCloneError })
        end
        local afterCopy, afterCloneError = cloneState(afterState, "$.afterState")
        if afterCloneError then
            return failure({ afterCloneError })
        end

        local errors = {}
        appendErrors(errors, validateCardInstances(beforeCopy, "$.beforeState"))
        appendErrors(errors, validateCardInstances(afterCopy, "$.afterState"))
        if #errors > 0 then
            return failure(errors)
        end

        appendErrors(errors, validatePositionContinuity(beforeCopy, "$.beforeState"))
        appendErrors(errors, validatePositionContinuity(afterCopy, "$.afterState"))
        appendErrors(errors, validatePlanLinks(beforeCopy, "$.beforeState"))
        appendErrors(errors, validatePlanLinks(afterCopy, "$.afterState"))

        local beforeById = {}
        local afterById = {}
        for _, instance in ipairs(beforeCopy.cardInstances) do
            beforeById[instance.instanceId] = instance
        end
        for _, instance in ipairs(afterCopy.cardInstances) do
            afterById[instance.instanceId] = instance
        end

        for instanceId, beforeInstance in pairs(beforeById) do
            local afterInstance = afterById[instanceId]
            if not afterInstance then
                table.insert(errors, makeError(
                    "missing_card_instance",
                    "$.afterState.cardInstances",
                    "이후 상태에서 카드 인스턴스가 사라졌습니다: " .. instanceId
                ))
            else
                if beforeInstance.cardId ~= afterInstance.cardId then
                    table.insert(errors, makeError(
                        "card_id_changed",
                        "$.afterState.cardInstances",
                        "카드 인스턴스의 cardId가 변경되었습니다: " .. instanceId
                    ))
                end
                if beforeInstance.owner ~= afterInstance.owner then
                    table.insert(errors, makeError(
                        "card_owner_changed",
                        "$.afterState.cardInstances",
                        "카드 인스턴스의 owner가 변경되었습니다: " .. instanceId
                    ))
                end
            end
        end
        for instanceId in pairs(afterById) do
            if not beforeById[instanceId] then
                table.insert(errors, makeError(
                    "unexpected_card_instance",
                    "$.afterState.cardInstances",
                    "이후 상태에 새 카드 인스턴스가 생겼습니다: " .. instanceId
                ))
            end
        end

        if #errors > 0 then
            return failure(errors)
        end
        return success(afterCopy, {}, {})
    end

    local arguments = { ... }
    local actions = {
        shuffleDeck = shuffleDeck,
        draw = draw,
        moveHandToUsed = moveHandToUsed,
        moveUsedToHand = moveUsedToHand,
        moveToRemoved = moveToRemoved,
        placePlan = placePlan,
        consumePlanCharge = consumePlanCharge,
        setPlanCapacity = setPlanCapacity,
        modifyOldestPlan = modifyOldestPlan,
        endTurnCleanup = endTurnCleanup,
        validateConservation = validateConservation,
    }

    local handler = actions[action]
    if not handler then
        return failure({
            makeError(
                "unknown_action",
                "$.action",
                "지원하지 않는 카드 영역 작업입니다: " .. tostring(action)
            ),
        })
    end

    return handler(arguments[1], arguments[2], arguments[3], arguments[4])
end)
