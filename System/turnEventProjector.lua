(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991
    local MAX_PLAN_SLOTS = 16

    local KNOWN_EVENT_TYPES = {
        turn_start = true,
        cards_drawn = true,
        character_intent_selected = true,
        role_revealed = true,
        effect_applied = true,
        trigger_suppressed = true,
        trigger_resolved = true,
        plan_changed = true,
        card_declared = true,
        card_resolved = true,
        card_restored = true,
        action_sequence_stopped = true,
        card_zone_changed = true,
        outcome_latched = true,
        mood_evaluated = true,
        turn_cleanup = true,
        session_end = true,
    }

    local RAW_PAYLOAD_KEYS = {
        turn_start = { turnNumber = true },
        cards_drawn = { requested = true, drawnCount = true },
        character_intent_selected = { selected = true },
        role_revealed = { role = true },
        effect_applied = {
            index = true,
            op = true,
            target = true,
            cause = true,
            changed = true,
            amount = true,
            before = true,
            after = true,
            drawnInstanceIds = true,
            scope = true,
            mood = true,
        },
        trigger_suppressed = { inputEventType = true, reasonCode = true, hidden = true },
        trigger_resolved = { inputEventType = true, commandCount = true },
        plan_changed = {
            action = true,
            instanceId = true,
            before = true,
            after = true,
            planSpec = true,
            movedInstanceIds = true,
            discarded = true,
        },
        card_declared = { cardId = true, instanceId = true, finalStealthCost = true, effectChoiceId = true, narrationConditionMet = true },
        card_resolved = {
            cardId = true,
            instanceId = true,
            finalResistanceDamage = true,
            grossStealthRecovery = true,
            finalStealthCost = true,
        },
        card_restored = { instanceId = true, reasonCode = true, destination = true },
        action_sequence_stopped = {
            side = true,
            reasonCode = true,
            restoredInstanceIds = true,
            unresolvedInstanceIds = true,
        },
        card_zone_changed = { instanceId = true, origin = true, destination = true },
        outcome_latched = { status = true, reasonCode = true, stealth = true, resistance = true },
        mood_evaluated = {
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
        },
        turn_cleanup = { before = true, after = true, movedInstanceIds = true, resolvedTurnNumber = true },
        session_end = { status = true },
    }

    local SUPPORTED_EFFECT_OPS = {
        pay_stealth_cost = true,
        damage_resistance = true,
        recover_resistance = true,
        lose_stealth = true,
        recover_stealth = true,
        draw_cards = true,
        skip_actions = true,
        add_mood_token = true,
        remove_mood_token = true,
        force_mood = true,
    }

    local CATEGORY_ORDER = {
        plan = 1,
        trait = 2,
        perk = 3,
    }

    local function makeError(code, path, message)
        return { code = code, path = path, message = message }
    end

    local function failure(errors)
        return { ok = false, schemaVersion = SCHEMA_VERSION, errors = errors }
    end

    local function success(publicResult, llmEvent)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            publicResult = publicResult,
            llmEvent = llmEvent,
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

    local function isSafeInteger(value, minimum)
        return isInteger(value, minimum) and math.abs(value) <= MAX_SAFE_INTEGER
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

    local function isRuntimeId(value)
        return type(value) == "string"
            and value ~= ""
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_.:-]*$") ~= nil
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function isSide(value)
        return value == "player" or value == "character"
    end

    local function isOutcome(value)
        return value == "victory" or value == "defeat"
    end

    local function cloneData(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "NaN과 무한대는 사건 입력에 사용할 수 없습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError("unsupported_type", path, "사건 입력에 사용할 수 없는 자료형입니다: " .. valueType)
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "사건 입력에는 메타테이블을 사용할 수 없습니다.")
        end
        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조가 있는 사건 입력은 사용할 수 없습니다.")
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            local keyType = type(key)
            if keyType ~= "string" and not isInteger(key, 1) then
                active[value] = nil
                return nil, makeError("invalid_key", path, "JSON 사건 입력에는 문자열 키 또는 양의 배열 인덱스만 사용할 수 있습니다.")
            end
            local childPath = type(key) == "number" and (path .. "[" .. key .. "]") or (path .. ".*")
            local itemCopy, itemError = cloneData(item, childPath, active)
            if itemError then
                active[value] = nil
                return nil, itemError
            end
            copy[key] = itemCopy
        end
        active[value] = nil
        return copy, nil
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function appendNestedErrors(target, prefix, report)
        local nested = type(report) == "table" and report.errors or nil
        if type(nested) ~= "table" or #nested == 0 then
            target[#target + 1] = makeError("nested_validation_failed", prefix, "하위 검증이 실패했습니다.")
            return
        end
        for _, item in ipairs(nested) do
            local nestedCode = type(item) == "table" and item.code or nil
            target[#target + 1] = makeError(
                isAsciiId(nestedCode) and nestedCode or "nested_error",
                prefix,
                "하위 검증이 실패했습니다."
            )
        end
    end

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, makeError("runtime_unavailable", "$.runtime." .. moduleName, "스크립트 실행기를 찾을 수 없습니다.")
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok then
            return nil, makeError("module_call_error", "$.runtime." .. moduleName, "하위 모듈 호출 중 오류가 발생했습니다.")
        end
        if type(report) ~= "table" then
            return nil, makeError("invalid_module_result", "$.runtime." .. moduleName, "하위 모듈이 테이블을 반환하지 않았습니다.")
        end
        return report, nil
    end

    local function checkAllowedKeys(value, allowed, path, errors)
        if type(value) ~= "table" then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or allowed[key] ~= true then
                errors[#errors + 1] = makeError("unexpected_field", path, "사건 계약에 없는 필드가 있습니다.")
            end
        end
    end

    local function arraysEqual(left, right)
        if not isDenseArray(left) or not isDenseArray(right) or #left ~= #right then
            return false
        end
        for index = 1, #left do
            if left[index] ~= right[index] then
                return false
            end
        end
        return true
    end

    local function dataEqual(left, right, active)
        if type(left) ~= type(right) then return false end
        if type(left) ~= "table" then return left == right end
        active = active or {}
        if active[left] == right then return true end
        active[left] = right
        for key, value in pairs(left) do
            if not dataEqual(value, right[key], active) then return false end
        end
        for key in pairs(right) do
            if left[key] == nil then return false end
        end
        return true
    end

    local function orderedZoneIds(state, owner, zone)
        local entries = {}
        for index, instance in ipairs(state.cardInstances) do
            if instance.owner == owner and instance.zone == zone then
                entries[#entries + 1] = {
                    instanceId = instance.instanceId,
                    position = instance.position,
                    sourceIndex = index,
                }
            end
        end
        table.sort(entries, function(left, right)
            if left.position ~= right.position then return left.position < right.position end
            if left.instanceId ~= right.instanceId then return left.instanceId < right.instanceId end
            return left.sourceIndex < right.sourceIndex
        end)
        local ids = {}
        for index, entry in ipairs(entries) do ids[index] = entry.instanceId end
        return ids
    end

    local function cleanupSnapshotFromState(state)
        return {
            turnNumber = state.turnNumber,
            player = {
                used = orderedZoneIds(state, "player", "used"),
                hand = orderedZoneIds(state, "player", "hand"),
                discard = orderedZoneIds(state, "player", "discard"),
                planSlots = state.player.planSlots,
            },
            character = {
                used = orderedZoneIds(state, "character", "used"),
                hand = orderedZoneIds(state, "character", "hand"),
                discard = orderedZoneIds(state, "character", "discard"),
                planSlots = state.character.planSlots,
            },
        }
    end

    local function expectedCleanupTransition(before, resolvedTurnNumber, afterTurnNumber)
        local expected = { turnNumber = afterTurnNumber }
        local moved = {}
        for _, side in ipairs({ "player", "character" }) do
            local sideBefore = before[side]
            local planCopy, planError = cloneData(sideBefore.planSlots, "$.turnResolution.events.cleanup.planSlots", {})
            if planError then return nil, nil, planError end
            local sideAfter = { used = {}, hand = {}, discard = {}, planSlots = planCopy }
            expected[side] = sideAfter
            for _, instanceId in ipairs(sideBefore.discard) do sideAfter.discard[#sideAfter.discard + 1] = instanceId end
            for _, zone in ipairs({ "used", "hand" }) do
                for _, instanceId in ipairs(sideBefore[zone]) do
                    sideAfter.discard[#sideAfter.discard + 1] = instanceId
                    moved[#moved + 1] = instanceId
                end
            end
        end
        for _, side in ipairs({ "player", "character" }) do
            local retained = {}
            for _, slot in ipairs(expected[side].planSlots) do
                if slot.remainingTurns ~= nil
                    and (slot.placedTurn < resolvedTurnNumber
                        or slot.durationIncludesPlacementTurn == true) then
                    slot.remainingTurns = slot.remainingTurns - 1
                end
                if slot.remainingTurns == 0 then
                    local instanceId = slot.cardInstanceId
                    expected[side].discard[#expected[side].discard + 1] = instanceId
                    moved[#moved + 1] = instanceId
                else
                    retained[#retained + 1] = slot
                end
            end
            expected[side].planSlots = retained
        end
        return expected, moved, nil
    end

    local function findCard(staticData, cardId, side, path, errors)
        local card = type(staticData.cards) == "table" and staticData.cards[cardId] or nil
        if type(card) ~= "table" or card.id ~= cardId then
            errors[#errors + 1] = makeError("unknown_card", path, "사건의 카드 정의를 찾을 수 없습니다.")
            return nil
        end
        if side ~= nil and card.owner ~= side then
            errors[#errors + 1] = makeError("card_owner_mismatch", path, "사건의 카드 소유자와 side가 다릅니다.")
            return nil
        end
        return card
    end

    local function findEffectChoice(card, choiceId)
        for _, choice in ipairs(type(card) == "table" and type(card.effectChoices) == "table" and card.effectChoices or {}) do
            if choice.id == choiceId then return choice end
        end
        return nil
    end

    local function validateSource(source, path, errors)
        if type(source) ~= "table" then
            errors[#errors + 1] = makeError("invalid_event_source", path, "사건 source가 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(source, {
            kind = true,
            id = true,
            side = true,
            instanceId = true,
        }, path, errors)
        if not isAsciiId(source.kind) then
            errors[#errors + 1] = makeError("invalid_source_kind", path .. ".kind", "사건 source kind가 올바르지 않습니다.")
        end
        if not isAsciiId(source.id) then
            errors[#errors + 1] = makeError("invalid_source_id", path .. ".id", "사건 source id가 올바르지 않습니다.")
        end
        if source.side ~= nil and source.side ~= "player" and source.side ~= "character" then
            errors[#errors + 1] = makeError("invalid_source_side", path .. ".side", "사건 source side가 올바르지 않습니다.")
        end
        if source.instanceId ~= nil and not isRuntimeId(source.instanceId) then
            errors[#errors + 1] = makeError("invalid_source_instance", path .. ".instanceId", "사건 source instanceId가 올바르지 않습니다.")
        end
    end

    local function validateCause(cause, path, eventResolutionId, errors)
        if cause == nil then
            return
        end
        if type(cause) ~= "table" or getmetatable(cause) ~= nil then
            errors[#errors + 1] = makeError("invalid_event_cause", path, "사건 cause가 일반 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(cause, {
            kind = true,
            resolutionId = true,
            eventId = true,
        }, path, errors)
        if not isAsciiId(cause.kind) then
            errors[#errors + 1] = makeError("invalid_cause_kind", path .. ".kind", "사건 cause kind가 올바르지 않습니다.")
        end
        if cause.resolutionId ~= nil then
            if not isRuntimeId(cause.resolutionId) then
                errors[#errors + 1] = makeError("invalid_cause_resolution", path .. ".resolutionId", "cause resolutionId가 올바르지 않습니다.")
            elseif cause.resolutionId ~= eventResolutionId then
                errors[#errors + 1] = makeError("cause_resolution_mismatch", path .. ".resolutionId", "cause와 사건의 resolutionId가 다릅니다.")
            end
        end
        if cause.eventId ~= nil and not isRuntimeId(cause.eventId) then
            errors[#errors + 1] = makeError("invalid_cause_event", path .. ".eventId", "cause eventId가 올바르지 않습니다.")
        end
    end

    local function validateIdArray(value, path)
        if not isDenseArray(value) then
            return nil, makeError("invalid_id_array", path, "runtime ID 목록이 연속 배열이 아닙니다.")
        end
        local seen = {}
        for index, instanceId in ipairs(value) do
            if not isRuntimeId(instanceId) then
                return nil, makeError("invalid_runtime_id", path .. "[" .. index .. "]", "runtime ID가 올바르지 않습니다.")
            end
            if seen[instanceId] then
                return nil, makeError("duplicate_runtime_id", path .. "[" .. index .. "]", "runtime ID가 중복되었습니다.")
            end
            seen[instanceId] = true
        end
        return true, nil
    end

    local function validatePlanSlotSnapshot(slot, path)
        if type(slot) ~= "table" or getmetatable(slot) ~= nil then
            return nil, makeError("invalid_plan_slot", path, "계획 슬롯 스냅숏이 일반 객체가 아닙니다.")
        end
        local errors = {}
        checkAllowedKeys(slot, {
            occupied = true,
            cardInstanceId = true,
            cardId = true,
            placedTurn = true,
            durationIncludesPlacementTurn = true,
            remainingTurns = true,
            remainingCharges = true,
            revealed = true,
            effectChoiceId = true,
        }, path, errors)
        if #errors > 0 then
            return nil, errors[1]
        end
        if slot.occupied ~= true
            or not isRuntimeId(slot.cardInstanceId)
            or not isAsciiId(slot.cardId)
            or not isInteger(slot.placedTurn, 1)
            or type(slot.revealed) ~= "boolean" then
            return nil, makeError("invalid_plan_slot", path, "점유된 계획 슬롯의 식별 정보가 올바르지 않습니다.")
        end
        if slot.remainingTurns == nil and slot.remainingCharges == nil then
            return nil, makeError("missing_plan_lifetime", path, "점유된 계획에는 지속시간 또는 충전이 필요합니다.")
        end
        if slot.durationIncludesPlacementTurn ~= nil
            and type(slot.durationIncludesPlacementTurn) ~= "boolean" then
            return nil, makeError(
                "invalid_plan_duration_policy",
                path .. ".durationIncludesPlacementTurn",
                "배치 턴 포함 여부가 불리언이 아닙니다."
            )
        end
        if slot.durationIncludesPlacementTurn == true and slot.remainingTurns == nil then
            return nil, makeError(
                "plan_duration_policy_requires_duration",
                path .. ".durationIncludesPlacementTurn",
                "배치 턴을 포함하는 계획에는 남은 지속시간이 필요합니다."
            )
        end
        if slot.remainingTurns ~= nil and not isInteger(slot.remainingTurns, 1) then
            return nil, makeError("invalid_plan_duration", path .. ".remainingTurns", "계획 남은 지속시간이 올바르지 않습니다.")
        end
        if slot.remainingCharges ~= nil and not isInteger(slot.remainingCharges, 1) then
            return nil, makeError("invalid_plan_charges", path .. ".remainingCharges", "계획 남은 충전이 올바르지 않습니다.")
        end
        if slot.effectChoiceId ~= nil and not isAsciiId(slot.effectChoiceId) then
            return nil, makeError("invalid_effect_choice_id", path .. ".effectChoiceId", "계획 효과 선택지 ID가 올바르지 않습니다.")
        end
        return true, nil
    end

    local function validatePlanSlotsSnapshot(slots, path, capacity)
        if not isDenseArray(slots) then
            return nil, makeError("invalid_plan_slots", path, "계획 슬롯 목록이 연속 배열이 아닙니다.")
        end
        if #slots > MAX_PLAN_SLOTS then
            return nil, makeError(
                "plan_slot_limit_exceeded",
                path,
                "계획 슬롯 목록이 지원 상한을 초과했습니다."
            )
        end
        if capacity ~= nil and #slots > capacity then
            return nil, makeError(
                "plan_capacity_exceeded",
                path,
                "계획 슬롯 목록이 해당 진영의 계획 용량을 초과했습니다."
            )
        end
        local seen = {}
        for index, slot in ipairs(slots) do
            local _, slotError = validatePlanSlotSnapshot(slot, path .. "[" .. index .. "]")
            if slotError then
                return nil, slotError
            end
            if seen[slot.cardInstanceId] then
                return nil, makeError("duplicate_plan_instance", path .. "[" .. index .. "].cardInstanceId", "계획 슬롯 인스턴스가 중복되었습니다.")
            end
            seen[slot.cardInstanceId] = true
        end
        return true, nil
    end

    local function validatePlanSpecSnapshot(spec, path)
        if type(spec) ~= "table" or getmetatable(spec) ~= nil then
            return nil, makeError("invalid_plan_spec", path, "계획 배치 명세가 일반 객체가 아닙니다.")
        end
        local errors = {}
        checkAllowedKeys(spec, {
            durationTurns = true,
            durationIncludesPlacementTurn = true,
            charges = true,
            revealed = true,
            effectChoiceId = true,
        }, path, errors)
        if #errors > 0 then
            return nil, errors[1]
        end
        if spec.durationTurns == nil and spec.charges == nil then
            return nil, makeError("missing_plan_lifetime", path, "계획 배치 명세에는 지속시간 또는 충전이 필요합니다.")
        end
        if spec.durationTurns ~= nil and not isInteger(spec.durationTurns, 1) then
            return nil, makeError("invalid_plan_duration", path .. ".durationTurns", "계획 배치 지속시간이 올바르지 않습니다.")
        end
        if spec.durationIncludesPlacementTurn ~= nil
            and type(spec.durationIncludesPlacementTurn) ~= "boolean" then
            return nil, makeError(
                "invalid_plan_duration_policy",
                path .. ".durationIncludesPlacementTurn",
                "계획 배치의 배치 턴 포함 여부가 불리언이 아닙니다."
            )
        end
        if spec.durationIncludesPlacementTurn == true and spec.durationTurns == nil then
            return nil, makeError(
                "plan_duration_policy_requires_duration",
                path .. ".durationIncludesPlacementTurn",
                "배치 턴을 포함하는 계획 배치에는 지속시간이 필요합니다."
            )
        end
        if spec.charges ~= nil and not isInteger(spec.charges, 1) then
            return nil, makeError("invalid_plan_charges", path .. ".charges", "계획 배치 충전이 올바르지 않습니다.")
        end
        if type(spec.revealed) ~= "boolean" then
            return nil, makeError("invalid_plan_revealed", path .. ".revealed", "계획 배치 공개 여부가 불리언이 아닙니다.")
        end
        if spec.effectChoiceId ~= nil and not isAsciiId(spec.effectChoiceId) then
            return nil, makeError("invalid_effect_choice_id", path .. ".effectChoiceId", "계획 효과 선택지 ID가 올바르지 않습니다.")
        end
        return true, nil
    end

    local function validateCleanupSnapshot(snapshot, path, capacities)
        if type(snapshot) ~= "table" or getmetatable(snapshot) ~= nil then
            return nil, makeError("invalid_cleanup_snapshot", path, "턴 정리 스냅숏이 일반 객체가 아닙니다.")
        end
        local errors = {}
        checkAllowedKeys(snapshot, { turnNumber = true, player = true, character = true }, path, errors)
        if #errors > 0 or not isInteger(snapshot.turnNumber, 1) then
            return nil, errors[1] or makeError("invalid_cleanup_turn", path .. ".turnNumber", "턴 정리 번호가 올바르지 않습니다.")
        end
        for _, side in ipairs({ "player", "character" }) do
            local sidePath = path .. "." .. side
            local value = snapshot[side]
            if type(value) ~= "table" or getmetatable(value) ~= nil then
                return nil, makeError("invalid_cleanup_side", sidePath, "턴 정리 진영 스냅숏이 일반 객체가 아닙니다.")
            end
            errors = {}
            checkAllowedKeys(value, { used = true, hand = true, discard = true, planSlots = true }, sidePath, errors)
            if #errors > 0 then
                return nil, errors[1]
            end
            for _, zone in ipairs({ "used", "hand", "discard" }) do
                local _, idError = validateIdArray(value[zone], sidePath .. "." .. zone)
                if idError then
                    return nil, idError
                end
            end
            local capacity = type(capacities) == "table" and capacities[side] or nil
            local _, slotError = validatePlanSlotsSnapshot(
                value.planSlots,
                sidePath .. ".planSlots",
                capacity
            )
            if slotError then
                return nil, slotError
            end
        end
        return true, nil
    end

    local function validateResolution(beforeState, staticData, resolution)
        local errors = {}
        if type(staticData) ~= "table"
            or type(staticData.registry) ~= "table"
            or type(staticData.cards) ~= "table"
            or type(staticData.characters) ~= "table" then
            return nil, { makeError("invalid_static_data", "$.staticData", "전체 정적 데이터가 필요합니다.") }
        end

        local beforeValidation, beforeCallError = callModule("stateSchema", "validateBattleState", beforeState, staticData)
        if beforeCallError then
            return nil, { beforeCallError }
        end
        if beforeValidation.ok ~= true then
            appendNestedErrors(errors, "$.beforeState", beforeValidation)
        elseif beforeValidation.referencesValidated ~= true then
            errors[#errors + 1] = makeError("static_references_not_validated", "$.staticData", "beforeState의 정적 참조 검증이 필요합니다.")
        end

        local resolutionCopy, cloneError = cloneData(resolution, "$.turnResolution", {})
        if cloneError then
            errors[#errors + 1] = cloneError
            return nil, errors
        end
        if type(resolutionCopy) ~= "table" then
            return nil, { makeError("invalid_turn_resolution", "$.turnResolution", "turnResolution이 객체가 아닙니다.") }
        end
        checkAllowedKeys(resolutionCopy, {
            schemaVersion = true,
            kind = true,
            battleId = true,
            turnId = true,
            turnNumber = true,
            source = true,
            selectedCards = true,
            events = true,
            metrics = true,
            afterState = true,
        }, "$.turnResolution", errors)
        if resolutionCopy.schemaVersion ~= SCHEMA_VERSION or resolutionCopy.kind ~= "turnResolution" then
            errors[#errors + 1] = makeError("invalid_turn_resolution", "$.turnResolution", "지원하지 않는 turnResolution입니다.")
        end
        if not isRuntimeId(resolutionCopy.battleId) or resolutionCopy.battleId ~= beforeState.battleId then
            errors[#errors + 1] = makeError("resolution_battle_mismatch", "$.turnResolution.battleId", "turnResolution battleId가 beforeState와 다릅니다.")
        end
        if not isRuntimeId(resolutionCopy.turnId) then
            errors[#errors + 1] = makeError("invalid_turn_id", "$.turnResolution.turnId", "turnResolution turnId가 올바르지 않습니다.")
        end
        local startReceipt = type(beforeState) == "table" and beforeState.turnStartReceipt or nil
        if type(startReceipt) ~= "table" or startReceipt.turnId ~= resolutionCopy.turnId then
            errors[#errors + 1] = makeError("resolution_turn_mismatch", "$.turnResolution.turnId", "turnResolution turnId가 beforeState.turnStartReceipt와 다릅니다.")
        end
        if not isInteger(resolutionCopy.turnNumber, 1) or resolutionCopy.turnNumber ~= beforeState.turnNumber then
            errors[#errors + 1] = makeError("resolution_turn_number_mismatch", "$.turnResolution.turnNumber", "해결 턴 번호가 beforeState와 다릅니다.")
        end
        if type(resolutionCopy.source) ~= "table" then
            errors[#errors + 1] = makeError("invalid_resolution_source", "$.turnResolution.source", "turnResolution source가 없습니다.")
        else
            checkAllowedKeys(resolutionCopy.source, {
                kind = true,
                mode = true,
                authority = true,
                projectedRng = true,
            }, "$.turnResolution.source", errors)
            if resolutionCopy.source.kind ~= "turnDraftProjection"
                or (resolutionCopy.source.mode ~= "pass"
                    and resolutionCopy.source.mode ~= "chain_pass"
                    and resolutionCopy.source.mode ~= "action") then
                errors[#errors + 1] = makeError("invalid_resolution_source", "$.turnResolution.source", "해결 source의 projection mode가 올바르지 않습니다.")
            end
        end
        if type(resolutionCopy.selectedCards) ~= "table"
            or not isDenseArray(resolutionCopy.selectedCards.player)
            or not isDenseArray(resolutionCopy.selectedCards.character) then
            errors[#errors + 1] = makeError("invalid_selected_cards", "$.turnResolution.selectedCards", "선택 카드 배열이 올바르지 않습니다.")
        else
            local _, playerIdsError = validateIdArray(
                resolutionCopy.selectedCards.player,
                "$.turnResolution.selectedCards.player"
            )
            local _, characterIdsError = validateIdArray(
                resolutionCopy.selectedCards.character,
                "$.turnResolution.selectedCards.character"
            )
            if playerIdsError then errors[#errors + 1] = playerIdsError end
            if characterIdsError then errors[#errors + 1] = characterIdsError end
            if type(beforeState.characterIntent) == "table"
                and not arraysEqual(resolutionCopy.selectedCards.character, beforeState.characterIntent.cardInstanceIds) then
                errors[#errors + 1] = makeError("character_selection_mismatch", "$.turnResolution.selectedCards.character", "캐릭터 선택이 beforeState 의도와 다릅니다.")
            end
        end

        local afterValidation, afterCallError = callModule("stateSchema", "validateBattleState", resolutionCopy.afterState, staticData)
        if afterCallError then
            errors[#errors + 1] = afterCallError
        elseif afterValidation.ok ~= true then
            appendNestedErrors(errors, "$.turnResolution.afterState", afterValidation)
        elseif afterValidation.referencesValidated ~= true then
            errors[#errors + 1] = makeError("static_references_not_validated", "$.turnResolution.afterState", "afterState의 정적 참조 검증이 필요합니다.")
        end
        if type(resolutionCopy.afterState) == "table" then
            if resolutionCopy.afterState.battleId ~= resolutionCopy.battleId then
                errors[#errors + 1] = makeError("after_battle_mismatch", "$.turnResolution.afterState.battleId", "afterState battleId가 다릅니다.")
            end
            if resolutionCopy.afterState.lastCommittedTurnId ~= resolutionCopy.turnId then
                errors[#errors + 1] = makeError("after_turn_not_committed", "$.turnResolution.afterState.lastCommittedTurnId", "afterState가 해결 turnId를 확정하지 않았습니다.")
            end
            for _, side in ipairs({ "player", "character" }) do
                local beforeOwner = type(beforeState[side]) == "table" and beforeState[side] or nil
                local afterOwner = type(resolutionCopy.afterState[side]) == "table"
                    and resolutionCopy.afterState[side]
                    or nil
                if beforeOwner ~= nil
                    and afterOwner ~= nil
                    and afterOwner.planCapacity ~= beforeOwner.planCapacity then
                    errors[#errors + 1] = makeError(
                        "plan_capacity_changed",
                        "$.turnResolution.afterState." .. side .. ".planCapacity",
                        "v1 턴 해결은 계획 용량을 변경할 수 없습니다."
                    )
                end
            end
        end

        if not isDenseArray(resolutionCopy.events) then
            errors[#errors + 1] = makeError("invalid_event_array", "$.turnResolution.events", "사건 목록이 연속 배열이 아닙니다.")
        else
            for index, event in ipairs(resolutionCopy.events) do
                local path = "$.turnResolution.events[" .. index .. "]"
                if type(event) ~= "table" then
                    errors[#errors + 1] = makeError("invalid_event", path, "사건이 객체가 아닙니다.")
                else
                    checkAllowedKeys(event, {
                        eventId = true,
                        sequence = true,
                        type = true,
                        phase = true,
                        source = true,
                        payload = true,
                        resolutionId = true,
                        side = true,
                        cause = true,
                    }, path, errors)
                    if event.sequence ~= index then
                        errors[#errors + 1] = makeError("event_sequence_mismatch", path .. ".sequence", "원본 사건 sequence가 연속적이지 않습니다.")
                    end
                    local expectedEventId = tostring(resolutionCopy.turnId) .. "-event-" .. string.format("%03d", index)
                    if event.eventId ~= expectedEventId then
                        errors[#errors + 1] = makeError("event_id_mismatch", path .. ".eventId", "원본 사건 eventId가 turnId와 sequence에 맞지 않습니다.")
                    end
                    if type(event.type) ~= "string" or KNOWN_EVENT_TYPES[event.type] ~= true then
                        errors[#errors + 1] = makeError("unknown_event_type", path .. ".type", "지원하지 않는 원본 사건입니다.")
                    end
                    if type(event.phase) ~= "string" or not isAsciiId(event.phase) then
                        errors[#errors + 1] = makeError("invalid_event_phase", path .. ".phase", "원본 사건 phase가 올바르지 않습니다.")
                    end
                    if event.side ~= nil and event.side ~= "player" and event.side ~= "character" then
                        errors[#errors + 1] = makeError("invalid_event_side", path .. ".side", "원본 사건 side가 올바르지 않습니다.")
                    end
                    if event.resolutionId ~= nil and not isRuntimeId(event.resolutionId) then
                        errors[#errors + 1] = makeError("invalid_resolution_id", path .. ".resolutionId", "원본 사건 resolutionId가 올바르지 않습니다.")
                    end
                    validateSource(event.source, path .. ".source", errors)
                    validateCause(event.cause, path .. ".cause", event.resolutionId, errors)
                    if type(event.payload) ~= "table" then
                        errors[#errors + 1] = makeError("invalid_event_payload", path .. ".payload", "원본 사건 payload가 객체가 아닙니다.")
                    elseif KNOWN_EVENT_TYPES[event.type] then
                        checkAllowedKeys(event.payload, RAW_PAYLOAD_KEYS[event.type], path .. ".payload", errors)
                    end
                    if event.type == "effect_applied" then
                        local op = type(event.payload) == "table" and event.payload.op or nil
                        if type(op) ~= "string" or SUPPORTED_EFFECT_OPS[op] ~= true then
                            errors[#errors + 1] = makeError("unsupported_effect_op", path .. ".payload.op", "지원하지 않는 효과 작업입니다.")
                        end
                    end
                end
            end
        end

        if #errors > 0 then
            return nil, errors
        end
        return resolutionCopy, nil
    end

    local function newEnvelope()
        return { schemaVersion = SCHEMA_VERSION, events = {} }
    end

    local function emit(envelope, eventType, payload)
        envelope.events[#envelope.events + 1] = {
            sequence = #envelope.events + 1,
            type = eventType,
            payload = payload,
        }
    end

    local function copySafeEffect(payload, path, moods)
        if type(payload) ~= "table" or type(payload.changed) ~= "boolean" then
            return nil, makeError("invalid_effect_payload", path, "효과 payload 또는 changed가 올바르지 않습니다.")
        end
        if not isSide(payload.target) then
            return nil, makeError("invalid_effect_target", path .. ".target", "효과 대상이 올바르지 않습니다.")
        end
        local op = payload.op
        local output = {
            op = op,
            target = payload.target,
            changed = payload.changed == true,
        }
        local function requireFinite(field)
            if not isFinite(payload[field]) then
                return nil, makeError("invalid_effect_payload", path .. "." .. field, "효과 수치가 유한하지 않습니다.")
            end
            return payload[field], nil
        end

        if op == "pay_stealth_cost"
            or op == "damage_resistance"
            or op == "recover_resistance"
            or op == "lose_stealth"
            or op == "recover_stealth" then
            local expectedTargets = {
                pay_stealth_cost = "player",
                damage_resistance = "character",
                recover_resistance = "character",
                lose_stealth = "player",
                recover_stealth = "player",
            }
            if payload.target ~= expectedTargets[op] then
                return nil, makeError("effect_target_mismatch", path .. ".target", "자원 효과 대상이 op와 다릅니다.")
            end
            local amount, amountError = requireFinite("amount")
            local before, beforeError = requireFinite("before")
            local after, afterError = requireFinite("after")
            if amountError or beforeError or afterError or amount < 0 then
                return nil, amountError or beforeError or afterError
                    or makeError("invalid_effect_payload", path .. ".amount", "자원 효과량은 0 이상이어야 합니다.")
            end
            local direction = (op == "recover_resistance" or op == "recover_stealth") and 1 or -1
            if after ~= before + direction * amount then
                return nil, makeError("effect_result_mismatch", path .. ".after", "자원 효과 결과가 before·amount와 다릅니다.")
            end
            if payload.changed ~= (before ~= after) then
                return nil, makeError("effect_change_mismatch", path .. ".changed", "자원 효과의 changed가 before/after와 다릅니다.")
            end
            output.amount = amount
            output.before = before
            output.after = after
        elseif op == "draw_cards" then
            local requested, requestedError = requireFinite("amount")
            local _, idError = validateIdArray(payload.drawnInstanceIds, path .. ".drawnInstanceIds")
            if requestedError or not isInteger(requested, 1) or idError
                or #payload.drawnInstanceIds > requested then
                return nil, requestedError or makeError("invalid_effect_payload", path, "드로우 효과 payload가 올바르지 않습니다.")
            end
            output.requested = requested
            output.drawnCount = #payload.drawnInstanceIds
            if payload.changed ~= (#payload.drawnInstanceIds > 0) then
                return nil, makeError("effect_change_mismatch", path .. ".changed", "드로우 효과의 changed가 실제 드로우 수와 다릅니다.")
            end
        elseif op == "skip_actions" then
            if payload.scope ~= "remainingTurn" or type(payload.before) ~= "boolean" or payload.after ~= true then
                return nil, makeError("invalid_effect_payload", path, "행동 생략 효과 payload가 올바르지 않습니다.")
            end
            output.scope = payload.scope
            output.before = payload.before
            output.after = true
            if payload.changed ~= (not payload.before) then
                return nil, makeError("effect_change_mismatch", path .. ".changed", "행동 생략 효과의 changed가 before와 다릅니다.")
            end
        elseif op == "add_mood_token" or op == "remove_mood_token" then
            if payload.target ~= "character" then
                return nil, makeError("effect_target_mismatch", path .. ".target", "무드 토큰 대상은 character여야 합니다.")
            end
            if not isAsciiId(payload.mood) or type(moods) ~= "table" or type(moods[payload.mood]) ~= "table"
                or not isInteger(payload.amount, 1)
                or not isInteger(payload.before, 0)
                or not isInteger(payload.after, 0)
                or payload.after ~= (op == "add_mood_token"
                    and payload.before + payload.amount
                    or math.max(0, payload.before - payload.amount))
                or payload.changed ~= (payload.before ~= payload.after) then
                return nil, makeError("invalid_effect_payload", path, "무드 토큰 효과 payload가 올바르지 않습니다.")
            end
            output.mood = payload.mood
            output.amount = payload.amount
            output.before = payload.before
            output.after = payload.after
        elseif op == "force_mood" then
            if payload.target ~= "character" then
                return nil, makeError("effect_target_mismatch", path .. ".target", "무드 강제 변경 대상은 character여야 합니다.")
            end
            if not isAsciiId(payload.mood) or type(moods) ~= "table" or type(moods[payload.mood]) ~= "table"
                or not isInteger(payload.before, 0)
                or payload.after ~= payload.before + 1
                or payload.changed ~= true then
                return nil, makeError("invalid_effect_payload", path, "무드 강제 변경 요청 payload가 올바르지 않습니다.")
            end
            output.mood = payload.mood
            output.before = payload.before
            output.after = payload.after
        else
            return nil, makeError("unsupported_effect_op", path .. ".op", "지원하지 않는 효과 작업입니다.")
        end

        return output, nil
    end

    local function findPlanSlot(slots, instanceId)
        if not isDenseArray(slots) or not isRuntimeId(instanceId) then
            return nil, nil
        end
        for index, slot in ipairs(slots) do
            if type(slot) == "table" and slot.cardInstanceId == instanceId then
                return slot, index
            end
        end
        return nil, nil
    end

    local function planKnown(side, slot)
        return side == "player"
            or (type(slot) == "table" and slot.occupied == true and slot.revealed == true)
    end

    local function sideRank(side, actingSide)
        if actingSide ~= nil and side == actingSide then
            return 1
        end
        if actingSide ~= nil and isSide(side) then
            return 2
        end
        if actingSide == nil and side == "player" then
            return 1
        end
        if actingSide == nil and side == "character" then
            return 2
        end
        return 3
    end

    local function projectTurn(beforeStateInput, staticInput, resolutionInput)
        local staticData = normalizeStaticData(staticInput)
        local beforeState, beforeCloneError = cloneData(beforeStateInput, "$.beforeState", {})
        if beforeCloneError then
            return failure({ beforeCloneError })
        end
        if type(beforeState) ~= "table" then
            return failure({ makeError("invalid_before_state", "$.beforeState", "beforeState가 객체가 아닙니다.") })
        end
        local resolution, validationErrors = validateResolution(beforeState, staticData, resolutionInput)
        if validationErrors then
            return failure(validationErrors)
        end

        local publicResult = newEnvelope()
        local llmEvent = newEnvelope()
        local mode = resolution.source.mode
        emit(publicResult, "turn_mode", { mode = mode })
        emit(llmEvent, "turn_mode", { mode = mode })

        local startReceipt = beforeState.turnStartReceipt
        local startBaseline = type(startReceipt) == "table" and startReceipt.baseline or nil
        local function initialPlanSlots(side)
            for _, receiptEvent in ipairs(type(startReceipt) == "table" and startReceipt.events or {}) do
                local receiptSide = receiptEvent.side
                    or (type(receiptEvent.source) == "table" and receiptEvent.source.side or nil)
                if receiptEvent.type == "plan_changed" and receiptSide == side
                    and type(receiptEvent.payload) == "table"
                    and type(receiptEvent.payload.before) == "table" then
                    return receiptEvent.payload.before
                end
            end
            return beforeState[side].planSlots
        end
        local trackers = {
            player = {
                slots = initialPlanSlots("player"),
            },
            character = {
                slots = initialPlanSlots("character"),
            },
        }
        for _, side in ipairs({ "player", "character" }) do
            local _, initialSlotsError = validatePlanSlotsSnapshot(
                trackers[side].slots,
                "$.beforeState.turnStartReceipt.events.planSlots." .. side,
                beforeState[side].planCapacity
            )
            if initialSlotsError then
                return failure({ initialSlotsError })
            end
        end
        local startingStealth = type(startBaseline) == "table" and startBaseline.stealth or beforeState.player.stealth
        local startingResistance = type(startBaseline) == "table" and startBaseline.resistance or beforeState.character.resistance
        local trackedStealth = startingStealth
        local trackedResistance = startingResistance
        local trackedMood = type(startBaseline) == "table" and startBaseline.mood or beforeState.character.mood
        local function normalizedMoodTokens(source)
            local counts = {}
            source = type(source) == "table" and source or {}
            for moodId in pairs(staticData.registry.moods) do
                counts[moodId] = source[moodId] or 0
            end
            return counts
        end
        local trackedMoodTokens = normalizedMoodTokens(
            type(startBaseline) == "table" and startBaseline.moodTokens
                or beforeState.character.moodTokens
        )
        local trackedForcedMoodRequests = {}
        local trackedSkipRemaining = { player = false, character = false }
        local function findBeforeInstance(instanceId)
            for _, instance in ipairs(beforeState.cardInstances) do
                if instance.instanceId == instanceId then return instance end
            end
            return nil
        end
        local function countAuthorityHand(side)
            local count = 0
            for _, instance in ipairs(beforeState.cardInstances) do
                if instance.owner == side and instance.zone == "hand" then count = count + 1 end
            end
            return count
        end
        local function countBeforeHand(side)
            -- beforeState already includes every initializer draw; rewind them all before replay.
            local draw = type(startReceipt.draws) == "table" and startReceipt.draws[side] or nil
            local drawnCount = #(type(draw) == "table" and draw.drawnInstanceIds or {})
            for _, receiptEvent in ipairs(startReceipt.events or {}) do
                local payload = type(receiptEvent) == "table" and receiptEvent.payload or nil
                if receiptEvent.type == "effect_applied"
                    and type(payload) == "table"
                    and payload.op == "draw_cards"
                    and payload.target == side then
                    drawnCount = drawnCount + #(type(payload.drawnInstanceIds) == "table"
                        and payload.drawnInstanceIds or {})
                end
            end
            return countAuthorityHand(side) - drawnCount
        end
        local trackedHandCount = {
            player = countBeforeHand("player"),
            character = countBeforeHand("character"),
        }
        local turnStartSettled = false
        local pendingCosts = {}
        local pendingTriggerEffects = {}
        local pendingPlanSlots = {}
        local pendingPlanMeanings = {}
        local triggerInputs = {}
        local seenTriggerBatches = {}
        local seenTriggerOrder = {}
        local expectedCharacterIntent = beforeState.characterIntent
        local expectedCharacterSelected = #expectedCharacterIntent.cardInstanceIds > 0
        local expectedCharacterRole = expectedCharacterIntent.publicRole
        local pendingCharacterIntent = false
        local pendingDeclarations = {}
        local sawTurnStart = false
        local sawStartDraw = { player = false, character = false }
        local sawCharacterIntent = false
        local sawMoodEvaluation = false
        local expectedMoodStealthEffect = nil
        local sawMoodStealthEffect = false
        local sawCleanup = false
        local sawSessionEnd = false
        local latchedOutcome = nil
        local postCleanupSnapshot = nil

        local function moodStealthEffect(moodId, repeated)
            local op
            local amount
            if moodId == "rejection" then
                op = "lose_stealth"
                amount = repeated and 6 or 3
            elseif moodId == "suspicion" then
                op = "lose_stealth"
                amount = repeated and 2 or 1
            elseif moodId == "confusion" then
                op = "recover_stealth"
                amount = 1
            elseif moodId == "compliance" then
                op = "recover_stealth"
                amount = 2
            else
                return nil
            end
            return {
                op = op,
                amount = amount,
                delta = op == "recover_stealth" and amount or -amount,
            }
        end

        local triggerPhases = {
            turn_start = true,
            player_card = true,
            character_card = true,
            turn_end = true,
            session_end = true,
        }

        local function triggerInputKey(resolutionId, phase, eventType)
            if resolutionId ~= nil then return "resolution|" .. resolutionId .. "|" .. eventType end
            return "phase|" .. phase .. "|" .. eventType
        end

        local function makeTriggerContext(eventType, phase, currentCard)
            local publicRole = beforeState.characterIntent.publicRole
            if eventType == "turn_start" then
                -- turnInitializer runs this trigger before character selection.
                publicRole = nil
            end
            local context = {
                turn = resolution.turnNumber,
                phase = phase,
                mood = trackedMood,
                player = {
                    stealth = trackedStealth,
                    handCount = trackedHandCount.player,
                },
                character = {
                    resistance = trackedResistance,
                    publicRole = publicRole,
                },
            }
            if currentCard ~= nil then
                context.card = {
                    id = currentCard.id,
                    instanceId = currentCard.instanceId,
                    owner = currentCard.owner,
                    roles = currentCard.roles,
                }
            end
            return context
        end

        local function registerTriggerInput(eventType, phase, resolutionId, inputEvent, currentCard, eventId)
            local key = triggerInputKey(resolutionId, phase, eventType)
            if triggerInputs[key] == nil then
                triggerInputs[key] = {
                    event = inputEvent,
                    context = makeTriggerContext(eventType, phase, currentCard),
                    eventId = eventId,
                    plans = {
                        player = trackers.player.slots,
                        character = trackers.character.slots,
                    },
                }
            end
            return triggerInputs[key]
        end

        local function sourceBatchKey(inputKey, kind, sourceId, side, instanceId)
            return inputKey
                .. "|" .. kind
                .. "|" .. tostring(side or "")
                .. "|" .. tostring(instanceId or "")
                .. "|" .. sourceId
        end

        local function triggerBatchKey(inputKey, event)
            return sourceBatchKey(
                inputKey,
                event.source.kind,
                event.source.id,
                event.side or event.source.side,
                event.source.instanceId
            )
        end

        local function requireSource(event, path, expectedKind, expectedId)
            if event.source.kind ~= expectedKind
                or (expectedId ~= nil and event.source.id ~= expectedId) then
                return nil, makeError("event_source_mismatch", path .. ".source", "사건 source가 사건 종류와 다릅니다.")
            end
            return true, nil
        end

        local function requireSideSource(event, path, side)
            if not isSide(side)
                or event.side ~= side
                or event.source.side ~= side then
                return nil, makeError("event_side_mismatch", path, "사건 side와 source.side가 다릅니다.")
            end
            return true, nil
        end

        local function findTriggerDefinition(kind, sourceId, side, path)
            if kind == "plan" then
                local lookupErrors = {}
                local card = findCard(staticData, sourceId, side, path, lookupErrors)
                if #lookupErrors > 0 then
                    return nil, lookupErrors[1]
                end
                local plan = type(card.mechanismData) == "table" and card.mechanismData.plan or nil
                if card.cardType ~= "plan" or type(plan) ~= "table" then
                    return nil, makeError("invalid_plan_source", path, "트리거 source가 계획 정의가 아닙니다.")
                end
                return plan, nil
            end

            local collections = {
                trait = staticData.traits,
                perk = staticData.perks,
            }
            local collection = collections[kind]
            local definition = type(collection) == "table" and collection[sourceId] or nil
            if type(definition) ~= "table" or definition.id ~= sourceId then
                return nil, makeError("unknown_trigger_source", path, "트리거 source 정의를 찾을 수 없습니다.")
            end
            local active = false
            local activeIds = kind == "trait" and beforeState.character.traitIds
                or (kind == "perk" and beforeState.player.perkIds or nil)
            for _, activeId in ipairs(type(activeIds) == "table" and activeIds or {}) do
                if activeId == sourceId then active = true break end
            end
            if active ~= true then
                return nil, makeError("inactive_trigger_source", path, "트리거 source가 현재 전투에 활성화되어 있지 않습니다.")
            end
            if not isDenseArray(definition.triggers) or #definition.triggers == 0 then
                return nil, makeError("source_has_no_triggers", path, "트리거 사건 source에 선언된 trigger가 없습니다.")
            end
            local owner = definition.owner
            if kind == "perk" and owner == nil then owner = "player" end
            if owner ~= side then
                return nil, makeError("event_side_mismatch", path, "트리거 source owner와 side가 다릅니다.")
            end
            return definition, nil
        end

        local function triggerMatchesInput(kind, definition, inputEventType)
            if kind == "plan" then
                return definition.event == nil or definition.event == inputEventType
            end
            for _, spec in ipairs(definition.triggers) do
                if spec.event == inputEventType then
                    return true
                end
            end
            return false
        end

        local function replayTrigger(kind, definition, inputRecord, planSlot, planSide, planSlotIndex, path)
            local context, contextError = cloneData(inputRecord.context, path .. ".context", {})
            if contextError then return nil, nil, contextError end
            if kind == "plan" then
                if type(planSlot) ~= "table" or planSlot.occupied ~= true then
                    return nil, nil, makeError("missing_plan_context", path, "계획 트리거 재현에 필요한 슬롯이 없습니다.")
                end
                context.plan = {
                    cardId = planSlot.cardId,
                    cardInstanceId = planSlot.cardInstanceId,
                    side = planSide,
                    revealed = planSlot.revealed == true,
                    slotIndex = planSlotIndex,
                }
                if planSlot.remainingTurns ~= nil then context.plan.remainingTurns = planSlot.remainingTurns end
                if planSlot.remainingCharges ~= nil then context.plan.remainingCharges = planSlot.remainingCharges end
                if planSlot.effectChoiceId ~= nil then context.effectChoiceId = planSlot.effectChoiceId end
            end

            local specs = kind == "plan" and { definition } or definition.triggers
            local matched = {}
            for _, spec in ipairs(specs) do
                local condition, callError = callModule(
                    "effectEngine",
                    "evaluateTriggerCondition",
                    staticData,
                    spec,
                    context,
                    inputRecord.event
                )
                if callError or type(condition) ~= "table" or condition.ok ~= true then
                    return nil, nil, callError or makeError("trigger_replay_failed", path, "트리거 조건 재현에 실패했습니다.")
                end
                if condition.matched == true then matched[#matched + 1] = spec end
            end
            if #matched ~= 1 then
                return nil, nil, makeError(
                    #matched == 0 and "trigger_condition_mismatch" or "ambiguous_trigger_definition",
                    path,
                    #matched == 0 and "트리거 조건이 현재 입력과 일치하지 않습니다." or "같은 source에서 구분할 수 없는 트리거 정의가 둘 이상 일치합니다."
                )
            end
            local resolved, resolveError = callModule(
                "effectEngine",
                "evaluateTriggerResolve",
                staticData,
                matched[1],
                context,
                inputRecord.event
            )
            if resolveError or type(resolved) ~= "table" or resolved.ok ~= true or not isDenseArray(resolved.commands) then
                return nil, nil, resolveError or makeError("trigger_replay_failed", path, "트리거 명령 재현에 실패했습니다.")
            end
            return resolved.commands, context, nil
        end

        local function triggerCommandMatches(record, command, index)
            if type(record) ~= "table" or type(record.effect) ~= "table" or type(command) ~= "table" then
                return false
            end
            local effect = record.effect
            if record.index ~= index
                or record.cause ~= command.cause
                or effect.op ~= command.op
                or effect.target ~= command.target then
                return false
            end
            if command.op == "damage_resistance"
                or command.op == "recover_resistance"
                or command.op == "lose_stealth"
                or command.op == "recover_stealth" then
                return effect.amount == command.amount
            end
            if command.op == "draw_cards" then return effect.requested == command.amount end
            if command.op == "skip_actions" then return effect.scope == command.scope end
            if command.op == "add_mood_token" or command.op == "remove_mood_token" then
                return effect.mood == command.mood and effect.amount == command.amount
            end
            if command.op == "force_mood" then return effect.mood == command.mood end
            return false
        end

        local function collectExpectedTriggerBatches()
            local expected = {}
            local matchedByInput = {}
            local nextOrdinalByInput = {}
            local function addCandidate(
                inputKey,
                inputRecord,
                kind,
                sourceId,
                side,
                instanceId,
                declarationIndex,
                spec,
                planSlot,
                planSlotIndex
            )
                local context, contextError = cloneData(inputRecord.context, "$.triggerReplay.context", {})
                if contextError then return nil, contextError end
                if planSlot ~= nil then
                    context.plan = {
                        cardId = planSlot.cardId,
                        cardInstanceId = planSlot.cardInstanceId,
                        side = side,
                        revealed = planSlot.revealed == true,
                        slotIndex = planSlotIndex,
                    }
                    if planSlot.remainingTurns ~= nil then context.plan.remainingTurns = planSlot.remainingTurns end
                    if planSlot.remainingCharges ~= nil then context.plan.remainingCharges = planSlot.remainingCharges end
                    if planSlot.effectChoiceId ~= nil then context.effectChoiceId = planSlot.effectChoiceId end
                end
                local condition, callError = callModule(
                    "effectEngine",
                    "evaluateTriggerCondition",
                    staticData,
                    spec,
                    context,
                    inputRecord.event
                )
                if callError or type(condition) ~= "table" or condition.ok ~= true then
                    return nil, callError or makeError("trigger_replay_failed", "$.turnResolution.events", "트리거 조건 재현에 실패했습니다.")
                end
                if condition.matched == true then
                    local key = sourceBatchKey(inputKey, kind, sourceId, side, instanceId)
                    if expected[key] then
                        return nil, makeError("ambiguous_trigger_definition", "$.staticData", "같은 입력과 source에서 둘 이상의 트리거 정의가 일치합니다.")
                    end
                    expected[key] = true
                    local nextOrdinal = (nextOrdinalByInput[inputKey] or 0) + 1
                    nextOrdinalByInput[inputKey] = nextOrdinal
                    matchedByInput[inputKey] = matchedByInput[inputKey] or {
                        actingSide = inputRecord.event.side,
                        candidates = {},
                    }
                    local candidates = matchedByInput[inputKey].candidates
                    candidates[#candidates + 1] = {
                        key = key,
                        categoryOrder = CATEGORY_ORDER[kind],
                        side = side,
                        sourceId = sourceId,
                        declarationIndex = declarationIndex or 1,
                        ordinal = nextOrdinal,
                    }
                end
                return true, nil
            end

            for inputKey, inputRecord in pairs(triggerInputs) do
                for _, side in ipairs({ "player", "character" }) do
                    local slots = inputRecord.plans[side]
                    for slotIndex, slot in ipairs(slots) do
                        local card = staticData.cards[slot.cardId]
                        local plan = type(card) == "table"
                            and type(card.mechanismData) == "table"
                            and card.mechanismData.plan
                            or nil
                        if type(plan) ~= "table" then
                            return nil, makeError("invalid_plan_source", "$.staticData.cards.*.mechanismData.plan", "활성 계획 정의를 찾을 수 없습니다.")
                        end
                        local ok, candidateError = addCandidate(
                            inputKey,
                            inputRecord,
                            "plan",
                            slot.cardId,
                            side,
                            slot.cardInstanceId,
                            slotIndex,
                            plan,
                            slot,
                            slotIndex
                        )
                        if not ok then return nil, candidateError end
                    end
                end
                for _, traitId in ipairs(beforeState.character.traitIds) do
                    local trait = staticData.traits[traitId]
                    for declarationIndex, spec in ipairs(type(trait) == "table" and trait.triggers or {}) do
                        local ok, candidateError = addCandidate(
                            inputKey,
                            inputRecord,
                            "trait",
                            traitId,
                            trait.owner,
                            nil,
                            declarationIndex,
                            spec,
                            nil
                        )
                        if not ok then return nil, candidateError end
                    end
                end
                for _, perkId in ipairs(beforeState.player.perkIds) do
                    local perk = staticData.perks[perkId]
                    for declarationIndex, spec in ipairs(type(perk) == "table" and perk.triggers or {}) do
                        local ok, candidateError = addCandidate(
                            inputKey,
                            inputRecord,
                            "perk",
                            perkId,
                            perk.owner or "player",
                            nil,
                            declarationIndex,
                            spec,
                            nil
                        )
                        if not ok then return nil, candidateError end
                    end
                end
            end
            local orders = {}
            for inputKey, batch in pairs(matchedByInput) do
                table.sort(batch.candidates, function(left, right)
                    if left.categoryOrder ~= right.categoryOrder then
                        return left.categoryOrder < right.categoryOrder
                    end
                    local leftSide = sideRank(left.side, batch.actingSide)
                    local rightSide = sideRank(right.side, batch.actingSide)
                    if leftSide ~= rightSide then
                        return leftSide < rightSide
                    end
                    if left.sourceId ~= right.sourceId then
                        return left.sourceId < right.sourceId
                    end
                    if left.declarationIndex ~= right.declarationIndex then
                        return left.declarationIndex < right.declarationIndex
                    end
                    return left.ordinal < right.ordinal
                end)
                orders[inputKey] = {}
                for index, candidate in ipairs(batch.candidates) do
                    orders[inputKey][index] = candidate.key
                end
            end
            return expected, orders, nil
        end

        local function planKey(event)
            local source = event.source
            return tostring(event.side or source.side or "")
                .. "|" .. tostring(source.kind or "")
                .. "|" .. tostring(source.instanceId or "")
                .. "|" .. tostring(source.id or "")
        end

        local function publicEffectSource(event)
            local source = {
                kind = event.source.kind,
                id = event.source.id,
            }
            if event.source.side ~= nil then
                source.side = event.source.side
            end
            return source
        end

        local function emitEffect(effect, source)
            local publicEffect, cloneError = cloneData(effect, "$.publicEffect", {})
            if cloneError then
                return nil, cloneError
            end
            if effect.changed == true then
                publicEffect.source = source
            end
            emit(publicResult, "effect_applied", publicEffect)
            if effect.changed == true or effect.blocked == true then
                local llmCopy, cloneError = cloneData(effect, "$.llmEffect", {})
                if cloneError then
                    return nil, cloneError
                end
                emit(llmEvent, "effect_applied", llmCopy)
            end
            return true, nil
        end

        local function narration(card, key, side, actionName, identityKnown, required, conditionMet)
            local payload = {
                actor = side,
                action = actionName,
                identityKnown = identityKnown == true,
            }
            if identityKnown ~= true then
                return payload, nil
            end
            local entry = type(card.narration) == "table" and card.narration[key] or nil
            if type(entry) ~= "table" or type(entry.actorAction) ~= "string" or entry.actorAction == "" then
                if required == false then
                    return payload, nil
                end
                return nil, makeError(
                    "missing_card_narration",
                    "$.staticData.cards.*.narration." .. key,
                    "공개된 카드 사건에 필요한 narration.actorAction이 없습니다."
                )
            end
            if conditionMet == true then
                entry = entry.conditionMet
                if type(entry) ~= "table" or type(entry.actorAction) ~= "string" or entry.actorAction == "" then
                    return nil, makeError(
                        "missing_card_narration",
                        "$.staticData.cards.*.narration." .. key .. ".conditionMet",
                        "조건 충족 사건에 필요한 narration.actorAction이 없습니다."
                    )
                end
            end
            payload.actorAction = entry.actorAction
            if side == "character" and entry.actorThought ~= nil then
                if type(entry.actorThought) ~= "string" or entry.actorThought == "" then
                    return nil, makeError("invalid_card_narration", "$.staticData.cards.*.narration." .. key .. ".actorThought", "actorThought가 올바르지 않습니다.")
                end
                payload.actorThought = entry.actorThought
            end
            return payload, nil
        end

        local function emitPlan(side, actionName, cardId, identityKnown, remainingTurns, slotIndex, narrationKey, narrationRequired)
            local publicPayload = {
                side = side,
                action = actionName,
                identityKnown = identityKnown == true,
                slotIndex = slotIndex,
            }
            if not isInteger(slotIndex, 1) or slotIndex > MAX_PLAN_SLOTS then
                return nil, makeError("invalid_plan_slot_index", "$.plan.slotIndex", "계획 슬롯 순번이 올바르지 않습니다.")
            end
            local card = nil
            if identityKnown == true and cardId ~= nil then
                local lookupErrors = {}
                card = findCard(staticData, cardId, side, "$.plan.cardId", lookupErrors)
                if #lookupErrors > 0 then
                    return nil, lookupErrors[1]
                end
                publicPayload.cardId = cardId
            end
            if remainingTurns ~= nil then
                if not isInteger(remainingTurns, 0) then
                    return nil, makeError("invalid_plan_duration", "$.plan.remainingTurns", "계획 남은 턴이 올바르지 않습니다.")
                end
                publicPayload.remainingTurns = remainingTurns
            end
            emit(publicResult, "plan_changed", publicPayload)

            local llmPayload
            if narrationKey ~= nil and card ~= nil then
                local narrationError
                llmPayload, narrationError = narration(
                    card,
                    narrationKey,
                    side,
                    actionName,
                    true,
                    narrationRequired
                )
                if narrationError then
                    return nil, narrationError
                end
            else
                llmPayload = {
                    actor = side,
                    action = actionName,
                    identityKnown = identityKnown == true,
                }
            end
            emit(llmEvent, "plan", llmPayload)
            return true, nil
        end

        local function flushTriggerEffects(key)
            local records = pendingTriggerEffects[key] or {}
            pendingTriggerEffects[key] = nil
            for _, record in ipairs(records) do
                local ok, effectError = emitEffect(record.effect, record.source)
                if not ok then
                    return nil, effectError
                end
            end
            return true, nil
        end

        for index, event in ipairs(resolution.events) do
            local payload = event.payload
            local path = "$.turnResolution.events[" .. index .. "]"
            if event.phase == "turn_end"
                and latchedOutcome == nil
                and not (event.type == "outcome_latched" and payload.reasonCode == "turn_limit") then
                registerTriggerInput(
                    "turn_end",
                    "turn_end",
                    nil,
                    { type = "turn_end", turnNumber = resolution.turnNumber },
                    nil,
                    nil
                )
            elseif event.phase == "session_end" then
                registerTriggerInput(
                    "session_end",
                    "session_end",
                    nil,
                    {
                        type = "session_end",
                        status = resolution.afterState.status,
                        turnNumber = resolution.turnNumber,
                    },
                    nil,
                    nil
                )
            end
            if sawCleanup then
                local allowedAfterCleanup = event.type == "plan_changed"
                    or event.type == "trigger_resolved"
                    or event.type == "session_end"
                if resolution.afterState.status == "active"
                    or event.phase ~= "session_end"
                    or not allowedAfterCleanup then
                    return failure({ makeError("invalid_post_cleanup_event", path, "턴 정리 뒤에는 세션 종료 감사 사건만 올 수 있습니다.") })
                end
            elseif sawMoodEvaluation then
                local expectedTailType = "turn_cleanup"
                if expectedMoodStealthEffect ~= nil and sawMoodStealthEffect ~= true then
                    expectedTailType = "effect_applied"
                elseif sawMoodStealthEffect == true
                    and trackedStealth <= 0
                    and latchedOutcome == nil then
                    expectedTailType = "outcome_latched"
                end
                if event.type ~= expectedTailType then
                    return failure({
                        makeError(
                            "invalid_turn_tail_order",
                            path,
                            "무드 평가 뒤 사건 순서가 올바르지 않습니다: "
                                .. expectedTailType
                                .. " 사건이 필요합니다."
                        ),
                    })
                end
            elseif event.phase == "session_end" then
                return failure({ makeError("invalid_turn_tail_order", path, "세션 종료 사건은 턴 정리 뒤에만 올 수 있습니다.") })
            end
            if event.phase ~= "turn_start" and turnStartSettled ~= true then
                local expectedForcedMoodRequests = type(startReceipt) == "table"
                    and type(startReceipt.transient) == "table"
                    and startReceipt.transient.forcedMoodRequests
                    or {}
                local expectedSkipRemaining = type(startReceipt) == "table"
                    and type(startReceipt.transient) == "table"
                    and startReceipt.transient.skipRemaining
                    or { player = false, character = false }
                if not dataEqual(trackers.player.slots, beforeState.player.planSlots)
                    or not dataEqual(trackers.character.slots, beforeState.character.planSlots)
                    or trackedStealth ~= beforeState.player.stealth
                    or trackedResistance ~= beforeState.character.resistance
                    or trackedMood ~= beforeState.character.mood
                    or not dataEqual(trackedMoodTokens, normalizedMoodTokens(beforeState.character.moodTokens))
                    or not dataEqual(trackedForcedMoodRequests, expectedForcedMoodRequests)
                    or not dataEqual(trackedSkipRemaining, expectedSkipRemaining)
                    or trackedHandCount.player ~= countAuthorityHand("player")
                    or trackedHandCount.character ~= countAuthorityHand("character") then
                    return failure({ makeError("turn_start_replay_mismatch", path, "턴 시작 사건 재생 결과가 beforeState와 다릅니다.") })
                end
                for _, instanceId in ipairs(resolution.selectedCards.player) do
                    local instance = findBeforeInstance(instanceId)
                    if instance ~= nil and instance.zone == "hand" then
                        trackedHandCount.player = trackedHandCount.player - 1
                    end
                end
                turnStartSettled = true
            end
            if event.type == "turn_start" then
                local _, sourceError = requireSource(event, path, "system", "turn_initializer")
                if sourceError or event.phase ~= "turn_start" or event.side ~= nil
                    or sawTurnStart or index ~= 1
                    or not isInteger(payload.turnNumber, 1)
                    or payload.turnNumber ~= resolution.turnNumber then
                    return failure({ makeError("invalid_turn_start", path .. ".payload.turnNumber", "turn_start 턴 번호가 올바르지 않습니다.") })
                end
                sawTurnStart = true
                registerTriggerInput(
                    "turn_start",
                    "turn_start",
                    nil,
                    { type = "turn_start", turnNumber = payload.turnNumber },
                    nil,
                    event.eventId
                )
                emit(publicResult, "turn_started", { turnNumber = payload.turnNumber })
                emit(llmEvent, "turn_context", { turnNumber = payload.turnNumber })
            elseif event.type == "cards_drawn" then
                local _, sourceError = requireSource(event, path, "system", "card_zones")
                local _, sideError = requireSideSource(event, path, event.side)
                local expectedDraw = type(startReceipt.draws) == "table" and startReceipt.draws[event.side] or nil
                if sourceError or sideError or event.phase ~= "turn_start"
                    or sawStartDraw[event.side] == true
                    or type(expectedDraw) ~= "table"
                    or not isInteger(payload.requested, 0)
                    or not isInteger(payload.drawnCount, 0)
                    or payload.drawnCount > payload.requested
                    or payload.requested ~= expectedDraw.requested
                    or not isDenseArray(expectedDraw.drawnInstanceIds)
                    or payload.drawnCount ~= #expectedDraw.drawnInstanceIds then
                    return failure({ sourceError or sideError or makeError("invalid_draw_event", path .. ".payload", "드로우 사건 수치가 올바르지 않습니다.") })
                end
                sawStartDraw[event.side] = true
                trackedHandCount[event.side] = trackedHandCount[event.side] + payload.drawnCount
                if event.side == "player" then
                    emit(publicResult, "player_cards_drawn", {
                        requested = payload.requested,
                        drawnCount = payload.drawnCount,
                    })
                end
            elseif event.type == "character_intent_selected" then
                local _, sourceError = requireSource(event, path, "system", "character_selector")
                local _, sideError = requireSideSource(event, path, "character")
                if sourceError or sideError or event.phase ~= "turn_start"
                    or sawCharacterIntent
                    or type(payload.selected) ~= "boolean"
                    or payload.selected ~= expectedCharacterSelected then
                    return failure({ makeError("invalid_character_intent", path .. ".payload.selected", "캐릭터 의도 selected가 beforeState와 다릅니다.") })
                end
                sawCharacterIntent = true
                if payload.selected then
                    pendingCharacterIntent = true
                else
                    emit(publicResult, "character_intent", { selected = false })
                    emit(llmEvent, "character_intent", { selected = false })
                end
            elseif event.type == "role_revealed" then
                local role = payload.role
                local tag = type(staticData.registry.roles) == "table" and staticData.registry.roles[role] or nil
                local _, sourceError = requireSource(event, path, "system", "character_selector")
                local _, sideError = requireSideSource(event, path, "character")
                if sourceError or sideError or event.phase ~= "turn_start"
                    or pendingCharacterIntent ~= true
                    or not isAsciiId(role)
                    or role ~= expectedCharacterRole
                    or type(tag) ~= "table" or tag.owner ~= "character" then
                    return failure({ makeError("invalid_role_reveal", path .. ".payload.role", "캐릭터 공개 역할 태그가 beforeState·정적 레지스트리와 다릅니다.") })
                end
                emit(publicResult, "character_intent", { selected = true, role = role })
                emit(llmEvent, "character_intent", { selected = true, role = role })
                local selectedInstanceId = expectedCharacterIntent.cardInstanceIds[#expectedCharacterIntent.cardInstanceIds]
                local selectedInstance = findBeforeInstance(selectedInstanceId)
                local selectedCard = selectedInstance and staticData.cards[selectedInstance.cardId] or nil
                if type(selectedCard) ~= "table" then
                    return failure({ makeError("character_intent_card_missing", path, "캐릭터 의도 카드를 찾을 수 없습니다.") })
                end
                registerTriggerInput(
                    "role_revealed",
                    "turn_start",
                    nil,
                    {
                        type = "role_revealed",
                        side = "character",
                        cardId = selectedCard.id,
                        cardInstanceId = selectedInstanceId,
                        role = role,
                    },
                    {
                        id = selectedCard.id,
                        instanceId = selectedInstanceId,
                        owner = "character",
                        roles = selectedCard.roles,
                    },
                    event.eventId
                )
                pendingCharacterIntent = false
            elseif event.type == "effect_applied" then
                local isMoodStateEffect = event.source.kind == "system"
                    and event.source.id == "mood_state"
                local allowedEffectSources = {
                    card = true,
                    plan = true,
                    trait = true,
                    perk = true,
                }
                if allowedEffectSources[event.source.kind] ~= true and not isMoodStateEffect then
                    return failure({ makeError("invalid_effect_source", path .. ".source.kind", "효과 source 종류가 올바르지 않습니다.") })
                end
                if event.source.kind == "card" or event.source.kind == "plan" then
                    local _, sideError = requireSideSource(event, path, event.source.side)
                    if sideError then
                        return failure({ sideError })
                    end
                end
                local triggerKinds = { plan = true, trait = true, perk = true }
                if triggerKinds[event.source.kind] then
                    local triggerDefinition, triggerError = findTriggerDefinition(
                        event.source.kind,
                        event.source.id,
                        event.source.side,
                        path .. ".source.id"
                    )
                    if triggerError then
                        return failure({ triggerError })
                    end
                    local _, sideError = requireSideSource(event, path, event.source.side)
                    if sideError then
                        return failure({ sideError })
                    end
                    if triggerPhases[event.phase] ~= true
                        or type(event.cause) ~= "table"
                        or event.cause.kind ~= event.source.kind .. "_trigger" then
                        return failure({ makeError("effect_cause_mismatch", path .. ".cause", "트리거 효과 cause가 source와 다릅니다.") })
                    end
                elseif event.source.kind == "card" then
                    local lookupErrors = {}
                    findCard(staticData, event.source.id, event.source.side, path .. ".source.id", lookupErrors)
                    if #lookupErrors > 0 then
                        return failure(lookupErrors)
                    end
                    if event.phase ~= event.source.side .. "_card" then
                        return failure({ makeError("effect_phase_mismatch", path .. ".phase", "카드 효과 phase가 소유자와 다릅니다.") })
                    end
                elseif isMoodStateEffect then
                    if sawMoodEvaluation ~= true
                        or sawMoodStealthEffect == true
                        or expectedMoodStealthEffect == nil
                        or event.phase ~= "turn_end"
                        or event.side ~= "player"
                        or event.source.side ~= nil
                        or event.source.instanceId ~= nil
                        or event.resolutionId ~= nil
                        or type(event.cause) ~= "table"
                        or event.cause.kind ~= "mood_state"
                        or event.cause.resolutionId ~= nil
                        or event.cause.eventId ~= nil then
                        return failure({
                            makeError(
                                "invalid_mood_state_effect",
                                path,
                                "무드 은폐 효과 사건의 위치 또는 출처가 올바르지 않습니다."
                            ),
                        })
                    end
                end
                if payload.op == "pay_stealth_cost" then
                    if event.source.kind ~= "card" or event.side ~= "player" or event.phase ~= "player_card"
                        or type(event.cause) ~= "table" or event.cause.kind ~= "card_resolution"
                        or payload.index ~= nil or payload.cause ~= nil then
                        return failure({ makeError("invalid_cost_source", path, "은폐 비용 사건의 source 또는 phase가 올바르지 않습니다.") })
                    end
                elseif event.source.kind == "card"
                    and (type(event.cause) ~= "table"
                        or (event.cause.kind ~= "card_base"
                            and event.cause.kind ~= "card_effect"
                            and event.cause.kind ~= "mood_effect")) then
                    return failure({ makeError("effect_cause_mismatch", path .. ".cause", "카드 효과 cause가 올바르지 않습니다.") })
                elseif not isInteger(payload.index, 1) or type(payload.cause) ~= "string" or payload.cause == "" then
                    return failure({ makeError("invalid_effect_audit", path .. ".payload", "효과 index 또는 cause가 올바르지 않습니다.") })
                end
                local effect, effectError = copySafeEffect(
                    payload,
                    path .. ".payload",
                    staticData.registry.moods
                )
                if effectError then
                    return failure({ effectError })
                end
                if isMoodStateEffect then
                    local expected = expectedMoodStealthEffect
                    if payload.index ~= 1
                        or payload.cause ~= "moodState"
                        or effect.op ~= expected.op
                        or effect.target ~= "player"
                        or effect.amount ~= expected.amount
                        or effect.before ~= trackedStealth
                        or effect.after ~= trackedStealth + expected.delta
                        or effect.changed ~= true then
                        return failure({
                            makeError(
                                "invalid_mood_state_effect",
                                path .. ".payload",
                                "무드 은폐 효과가 무드 평가 결과와 다릅니다."
                            ),
                        })
                    end
                    sawMoodStealthEffect = true
                end
                if payload.op == "add_mood_token" or payload.op == "remove_mood_token" or payload.op == "force_mood" then
                    local moods = type(staticData.registry) == "table" and staticData.registry.moods or nil
                    if type(moods) ~= "table"
                        or type(moods[payload.mood]) ~= "table" then
                        return failure({ makeError("unknown_effect_mood", path .. ".payload", "무드 효과가 등록되지 않은 무드를 참조합니다.") })
                    end
                end
                if payload.op == "pay_stealth_cost" or payload.op == "lose_stealth" or payload.op == "recover_stealth" then
                    if effect.before ~= trackedStealth then
                        return failure({ makeError("effect_state_mismatch", path .. ".payload.before", "은폐 효과 before가 앞선 사건 결과와 다릅니다.") })
                    end
                    trackedStealth = effect.after
                elseif payload.op == "damage_resistance" or payload.op == "recover_resistance" then
                    if effect.before ~= trackedResistance then
                        return failure({ makeError("effect_state_mismatch", path .. ".payload.before", "저항 효과 before가 앞선 사건 결과와 다릅니다.") })
                    end
                    trackedResistance = effect.after
                elseif payload.op == "draw_cards" then
                    trackedHandCount[effect.target] = trackedHandCount[effect.target] + effect.drawnCount
                elseif payload.op == "skip_actions" then
                    if effect.before ~= trackedSkipRemaining[effect.target] then
                        return failure({ makeError("effect_state_mismatch", path .. ".payload.before", "행동 생략 효과 before가 앞선 사건 결과와 다릅니다.") })
                    end
                    trackedSkipRemaining[effect.target] = effect.after
                elseif payload.op == "add_mood_token" or payload.op == "remove_mood_token" then
                    if effect.before ~= trackedMoodTokens[effect.mood] then
                        return failure({ makeError("effect_state_mismatch", path .. ".payload.before", "무드 토큰 효과 before가 앞선 토큰 수와 다릅니다.") })
                    end
                    trackedMoodTokens[effect.mood] = effect.after
                elseif payload.op == "force_mood" then
                    if effect.before ~= #trackedForcedMoodRequests then
                        return failure({ makeError("effect_state_mismatch", path .. ".payload.before", "무드 강제 변경 요청 순서가 앞선 요청 수와 다릅니다.") })
                    end
                    trackedForcedMoodRequests[#trackedForcedMoodRequests + 1] = {
                        mood = effect.mood,
                        cause = payload.cause,
                    }
                end
                if payload.op == "pay_stealth_cost" then
                    if event.resolutionId == nil then
                        return failure({ makeError("missing_resolution_id", path .. ".resolutionId", "은폐 비용 사건에는 resolutionId가 필요합니다.") })
                    end
                    if pendingCosts[event.resolutionId] ~= nil then
                        return failure({ makeError("duplicate_card_cost", path .. ".resolutionId", "같은 카드 해결에 은폐 비용 사건이 중복되었습니다.") })
                    end
                    pendingCosts[event.resolutionId] = {
                        effect = effect,
                        source = publicEffectSource(event),
                        cardId = event.source.id,
                        instanceId = event.source.instanceId,
                    }
                elseif triggerKinds[event.source.kind] then
                    local key = planKey(event)
                    pendingTriggerEffects[key] = pendingTriggerEffects[key] or {}
                    pendingTriggerEffects[key][#pendingTriggerEffects[key] + 1] = {
                        effect = effect,
                        source = publicEffectSource(event),
                        index = payload.index,
                        cause = payload.cause,
                    }
                    if event.source.kind == "plan" and pendingPlanSlots[key] == nil then
                        local pendingSlot, pendingSlotIndex = findPlanSlot(
                            trackers[event.source.side].slots,
                            event.source.instanceId
                        )
                        pendingPlanSlots[key] = {
                            slot = pendingSlot,
                            slotIndex = pendingSlotIndex,
                        }
                    end
                else
                    local ok, emitError = emitEffect(effect, publicEffectSource(event))
                    if not ok then
                        return failure({ emitError })
                    end
                end
            elseif event.type == "card_declared" then
                local side = event.side
                if side ~= "player" and side ~= "character" then
                    return failure({ makeError("invalid_card_side", path .. ".side", "card_declared side가 올바르지 않습니다.") })
                end
                local lookupErrors = {}
                local card = findCard(staticData, payload.cardId or event.source.id, side, path .. ".payload.cardId", lookupErrors)
                if #lookupErrors > 0 then
                    return failure(lookupErrors)
                end
                if event.source.kind ~= "card"
                    or event.phase ~= side .. "_card"
                    or event.source.id ~= card.id
                    or event.source.side ~= side
                    or payload.cardId ~= card.id
                    or not isRuntimeId(payload.instanceId)
                    or payload.instanceId ~= event.source.instanceId
                    or not isFinite(payload.finalStealthCost)
                    or payload.finalStealthCost < 0
                    or not isRuntimeId(event.resolutionId)
                    or pendingDeclarations[event.resolutionId] ~= nil then
                    return failure({ makeError("card_event_mismatch", path, "card_declared source와 payload 카드가 다릅니다.") })
                end
                if side == "character" and payload.finalStealthCost ~= 0 then
                    return failure({ makeError("invalid_character_cost", path .. ".payload.finalStealthCost", "캐릭터 카드 비용은 0이어야 합니다.") })
                end
                local effectChoice = findEffectChoice(card, payload.effectChoiceId)
                if side == "player" and type(card.effectChoices) == "table" and effectChoice == nil then
                    return failure({ makeError("missing_effect_choice", path .. ".payload.effectChoiceId", "선택형 플레이어 카드에 유효한 효과 선택값이 없습니다.") })
                elseif (side ~= "player" or type(card.effectChoices) ~= "table") and payload.effectChoiceId ~= nil then
                    return failure({ makeError("unexpected_effect_choice", path .. ".payload.effectChoiceId", "효과 선택지가 없는 카드 선언에 선택값이 있습니다.") })
                end
                local hasNarrationCondition = card.narrationCondition ~= nil
                if hasNarrationCondition and type(payload.narrationConditionMet) ~= "boolean" then
                    return failure({ makeError("missing_narration_condition_result", path .. ".payload.narrationConditionMet", "조건부 사용 묘사의 판정 결과가 없습니다.") })
                elseif not hasNarrationCondition and payload.narrationConditionMet ~= nil then
                    return failure({ makeError("unexpected_narration_condition_result", path .. ".payload.narrationConditionMet", "조건부 사용 묘사가 없는 카드에 판정 결과가 있습니다.") })
                end
                local publicPayload = {
                    side = side,
                    roles = card.roles,
                    stealthCost = payload.finalStealthCost,
                }
                if side == "player" then
                    publicPayload.cardId = card.id
                    if effectChoice ~= nil then publicPayload.effectChoiceId = effectChoice.id end
                end
                emit(publicResult, "card_declared", publicPayload)

                if card.cardType ~= "plan" or (effectChoice ~= nil and effectChoice.placesPlan == false) then
                    local llmPayload, narrationError = narration(card, "play", side, "played", true, nil, payload.narrationConditionMet)
                    if narrationError then
                        return failure({ narrationError })
                    end
                    if payload.narrationConditionMet ~= true and effectChoice ~= nil and effectChoice.actorAction ~= nil then
                        llmPayload.actorAction = effectChoice.actorAction
                    end
                    llmPayload.roles = card.roles
                    emit(llmEvent, "action", llmPayload)
                end

                local costReceipt = pendingCosts[event.resolutionId]
                if side == "player" and costReceipt == nil then
                    return failure({ makeError("missing_card_cost", path, "플레이어 card_declared보다 앞선 은폐 비용 사건이 없습니다.") })
                end
                if side == "character" and costReceipt ~= nil then
                    return failure({ makeError("unexpected_card_cost", path, "캐릭터 카드에는 은폐 비용 사건이 있을 수 없습니다.") })
                end
                if costReceipt ~= nil then
                    if costReceipt.cardId ~= card.id
                        or costReceipt.instanceId ~= payload.instanceId
                        or costReceipt.effect.amount ~= payload.finalStealthCost then
                        return failure({ makeError("card_cost_mismatch", path, "은폐 비용 사건이 선언 카드와 일치하지 않습니다.") })
                    end
                    pendingCosts[event.resolutionId] = nil
                    local ok, emitError = emitEffect(costReceipt.effect, costReceipt.source)
                    if not ok then
                        return failure({ emitError })
                    end
                end
                pendingDeclarations[event.resolutionId] = {
                    side = side,
                    cardId = card.id,
                    instanceId = payload.instanceId,
                    effectChoiceId = payload.effectChoiceId,
                }
                if side == "character" then
                    trackedHandCount.character = trackedHandCount.character - 1
                    if trackedHandCount.character < 0 then
                        return failure({ makeError("hand_count_mismatch", path, "캐릭터 선언 전 손패 수가 올바르지 않습니다.") })
                    end
                end
                registerTriggerInput(
                    "card_declared",
                    event.phase,
                    event.resolutionId,
                    {
                        type = "card_declared",
                        side = side,
                        cardId = card.id,
                        cardInstanceId = payload.instanceId,
                        roles = card.roles,
                        resolutionId = event.resolutionId,
                        effectChoiceId = payload.effectChoiceId,
                    },
                    {
                        id = card.id,
                        instanceId = payload.instanceId,
                        owner = side,
                        roles = card.roles,
                        effectChoiceId = payload.effectChoiceId,
                    },
                    event.eventId
                )
            elseif event.type == "card_resolved" then
                local cardId = payload.cardId or event.source.id
                local lookupErrors = {}
                local card = findCard(staticData, cardId, event.side, path .. ".payload.cardId", lookupErrors)
                local declaration = event.resolutionId and pendingDeclarations[event.resolutionId] or nil
                if #lookupErrors > 0
                    or event.source.kind ~= "card"
                    or event.phase ~= tostring(event.side) .. "_card"
                    or event.source.id ~= cardId
                    or event.source.side ~= event.side
                    or not isRuntimeId(payload.instanceId)
                    or payload.instanceId ~= event.source.instanceId
                    or not isFinite(payload.finalResistanceDamage)
                    or payload.finalResistanceDamage < 0
                    or not isFinite(payload.grossStealthRecovery)
                    or payload.grossStealthRecovery < 0
                    or not isFinite(payload.finalStealthCost)
                    or payload.finalStealthCost < 0
                    or declaration == nil
                    or declaration.side ~= event.side
                    or declaration.cardId ~= cardId
                    or declaration.instanceId ~= payload.instanceId then
                    return failure(#lookupErrors > 0 and lookupErrors or { makeError("card_event_mismatch", path, "card_resolved source와 payload 카드가 다릅니다.") })
                end
                pendingDeclarations[event.resolutionId] = nil
                registerTriggerInput(
                    "card_resolved",
                    event.phase,
                    event.resolutionId,
                    {
                        type = "card_resolved",
                        side = event.side,
                        cardId = card.id,
                        cardInstanceId = payload.instanceId,
                        roles = card.roles,
                        resolutionId = event.resolutionId,
                        effectChoiceId = declaration.effectChoiceId,
                        finalResistanceDamage = payload.finalResistanceDamage,
                        grossStealthRecovery = payload.grossStealthRecovery,
                        finalStealthCost = payload.finalStealthCost,
                    },
                    {
                        id = card.id,
                        instanceId = payload.instanceId,
                        owner = event.side,
                        roles = card.roles,
                        effectChoiceId = declaration.effectChoiceId,
                    },
                    event.eventId
                )
            elseif event.type == "trigger_suppressed" then
                local side = event.side or event.source.side
                local lookupErrors = {}
                local planCard = findCard(staticData, event.source.id, side, path .. ".source.id", lookupErrors)
                local planDefinition = type(planCard) == "table"
                    and type(planCard.mechanismData) == "table"
                    and planCard.mechanismData.plan
                    or nil
                local trackedSlots = trackers[side] and trackers[side].slots or nil
                local trackedSlot, trackedSlotIndex = findPlanSlot(trackedSlots, event.source.instanceId)
                local expectedHidden = type(trackedSlot) == "table"
                    and trackedSlot.occupied == true
                    and trackedSlot.revealed ~= true
                local inputRecord = nil
                local inputKeyValue = nil
                if isAsciiId(payload.inputEventType) then
                    inputKeyValue = triggerInputKey(
                        event.resolutionId,
                        event.phase,
                        payload.inputEventType
                    )
                    inputRecord = triggerInputs[inputKeyValue]
                end
                local inputPlanSlot, inputPlanSlotIndex = nil, nil
                if inputRecord ~= nil and type(inputRecord.plans) == "table" then
                    inputPlanSlot, inputPlanSlotIndex = findPlanSlot(
                        inputRecord.plans[side],
                        event.source.instanceId
                    )
                end
                local _, sideError = requireSideSource(event, path, side)
                if #lookupErrors > 0
                    or sideError
                    or event.source.kind ~= "plan"
                    or planCard.cardType ~= "plan"
                    or type(planDefinition) ~= "table"
                    or event.resolutionId == nil
                    or (event.phase ~= "player_card" and event.phase ~= "character_card")
                    or type(event.cause) ~= "table"
                    or event.cause.kind ~= "card_resolution"
                    or inputRecord == nil
                    or (event.cause.eventId ~= nil and event.cause.eventId ~= inputRecord.eventId)
                    or not isAsciiId(payload.inputEventType)
                    or not triggerMatchesInput("plan", planDefinition, payload.inputEventType)
                    or not isAsciiId(payload.reasonCode)
                    or payload.reasonCode ~= "insight"
                    or type(payload.hidden) ~= "boolean"
                    or type(trackedSlot) ~= "table"
                    or trackedSlot.occupied ~= true
                    or trackedSlot.cardId ~= event.source.id
                    or inputPlanSlot == nil
                    or payload.hidden ~= expectedHidden then
                    return failure(#lookupErrors > 0 and lookupErrors or {
                        sideError or makeError("invalid_trigger_suppression", path, "억제 사건의 계획 source 또는 payload가 올바르지 않습니다."),
                    })
                end
                local suppressionContext, suppressionContextError = cloneData(
                    inputRecord.context,
                    path .. ".context",
                    {}
                )
                if suppressionContextError then return failure({ suppressionContextError }) end
                suppressionContext.plan = {
                    cardId = inputPlanSlot.cardId,
                    cardInstanceId = inputPlanSlot.cardInstanceId,
                    side = side,
                    revealed = inputPlanSlot.revealed == true,
                    slotIndex = inputPlanSlotIndex,
                }
                if inputPlanSlot.remainingTurns ~= nil then
                    suppressionContext.plan.remainingTurns = inputPlanSlot.remainingTurns
                end
                if inputPlanSlot.remainingCharges ~= nil then
                    suppressionContext.plan.remainingCharges = inputPlanSlot.remainingCharges
                end
                if inputPlanSlot.effectChoiceId ~= nil then
                    suppressionContext.effectChoiceId = inputPlanSlot.effectChoiceId
                end
                local suppressionCondition, suppressionCallError = callModule(
                    "effectEngine",
                    "evaluateTriggerCondition",
                    staticData,
                    planDefinition,
                    suppressionContext,
                    inputRecord.event
                )
                if suppressionCallError
                    or type(suppressionCondition) ~= "table"
                    or suppressionCondition.ok ~= true
                    or suppressionCondition.matched ~= true then
                    return failure({ suppressionCallError
                        or makeError("trigger_condition_mismatch", path, "억제된 계획 조건이 현재 입력과 일치하지 않습니다.") })
                end
                local suppressionBatchKey = triggerBatchKey(inputKeyValue, event)
                if seenTriggerBatches[suppressionBatchKey] then
                    return failure({ makeError("duplicate_trigger_batch", path, "같은 입력과 source의 트리거 batch가 중복되었습니다.") })
                end
                seenTriggerBatches[suppressionBatchKey] = true
                seenTriggerOrder[inputKeyValue] = seenTriggerOrder[inputKeyValue] or {}
                seenTriggerOrder[inputKeyValue][#seenTriggerOrder[inputKeyValue] + 1] = suppressionBatchKey
                if payload.hidden == true then
                    -- A hidden suppression leaves no public or LLM trace and does not reveal the plan.
                elseif payload.hidden == false then
                    local known = planKnown(side, trackedSlot)
                    if known ~= true
                        or trackedSlot.cardId ~= event.source.id then
                        return failure({ makeError("suppression_visibility_mismatch", path, "공개 억제 계획의 알려진 정체가 source와 다릅니다.") })
                    end
                    local publicPayload = {
                        side = side,
                        reasonCode = payload.reasonCode,
                        identityKnown = known,
                        slotIndex = trackedSlotIndex,
                    }
                    if known then
                        publicPayload.cardId = event.source.id
                    end
                    emit(publicResult, "trigger_suppressed", publicPayload)
                    emit(llmEvent, "plan_suppressed", {
                        actor = side,
                        reasonCode = payload.reasonCode,
                        identityKnown = known,
                    })
                end
            elseif event.type == "trigger_resolved" then
                local allowedTriggerSources = { plan = true, trait = true, perk = true }
                local definition, definitionError = findTriggerDefinition(
                    event.source.kind,
                    event.source.id,
                    event.source.side,
                    path .. ".source.id"
                )
                local expectedCause = event.resolutionId ~= nil and "card_resolution" or "turn_event"
                local inputRecord = nil
                local inputKeyValue = nil
                if isAsciiId(payload.inputEventType) then
                    inputKeyValue = triggerInputKey(
                        event.resolutionId,
                        event.phase,
                        payload.inputEventType
                    )
                    inputRecord = triggerInputs[inputKeyValue]
                end
                if allowedTriggerSources[event.source.kind] ~= true
                    or definitionError
                    or triggerPhases[event.phase] ~= true
                    or not isAsciiId(payload.inputEventType)
                    or not isInteger(payload.commandCount, 0)
                    or inputRecord == nil
                    or not triggerMatchesInput(event.source.kind, definition, payload.inputEventType)
                    or type(event.cause) ~= "table"
                    or event.cause.kind ~= expectedCause
                    or (event.cause.eventId ~= nil and event.cause.eventId ~= inputRecord.eventId) then
                    return failure({ definitionError or makeError("invalid_trigger_resolution", path, "트리거 해결 감사 사건이 올바르지 않습니다.") })
                end
                if sawCleanup and (payload.inputEventType ~= "session_end"
                    or payload.commandCount ~= 0
                    or event.resolutionId ~= nil) then
                    return failure({ makeError("invalid_session_end_trigger", path, "세션 종료 트리거는 게임플레이 명령을 가질 수 없습니다.") })
                end
                local resolvedBatchKey = triggerBatchKey(inputKeyValue, event)
                if seenTriggerBatches[resolvedBatchKey] then
                    return failure({ makeError("duplicate_trigger_batch", path, "같은 입력과 source의 트리거 batch가 중복되었습니다.") })
                end
                local _, sideError = requireSideSource(event, path, event.source.side)
                if sideError then
                    return failure({ sideError })
                end
                local key = planKey(event)
                local records = pendingTriggerEffects[key] or {}
                local pendingPlan = pendingPlanSlots[key]
                local replayPlanSlot, replayPlanSlotIndex = nil, nil
                if event.source.kind == "plan" then
                    replayPlanSlot, replayPlanSlotIndex = findPlanSlot(
                        inputRecord.plans[event.source.side],
                        event.source.instanceId
                    )
                    if type(pendingPlan) ~= "table"
                        or type(pendingPlan.slot) ~= "table"
                        or pendingPlan.slot.cardInstanceId ~= event.source.instanceId then
                        return failure({ makeError("missing_plan_context", path, "계획 트리거 재현에 필요한 인스턴스 문맥이 없습니다.") })
                    end
                end
                local commands, _, replayError = replayTrigger(
                    event.source.kind,
                    definition,
                    inputRecord,
                    replayPlanSlot,
                    event.source.side,
                    replayPlanSlotIndex,
                    path
                )
                if replayError then return failure({ replayError }) end
                if #records ~= payload.commandCount or #commands ~= payload.commandCount then
                    return failure({ makeError("trigger_command_count_mismatch", path .. ".payload.commandCount", "트리거 명령 수와 효과 사건 수가 다릅니다.") })
                end
                for commandIndex, command in ipairs(commands) do
                    if not triggerCommandMatches(records[commandIndex], command, commandIndex) then
                        return failure({ makeError("trigger_command_mismatch", path, "트리거 효과가 정적 resolve 명령과 다릅니다.") })
                    end
                end
                if event.source.kind == "plan" and pendingPlanMeanings[key] ~= true then
                    return failure({ makeError("missing_plan_meaning", path, "계획 효과보다 앞선 계획 발동 의미 사건이 없습니다.") })
                end
                local flushed, flushError = flushTriggerEffects(key)
                if not flushed then
                    return failure({ flushError })
                end
                pendingPlanMeanings[key] = nil
                pendingPlanSlots[key] = nil
                seenTriggerBatches[resolvedBatchKey] = true
                seenTriggerOrder[inputKeyValue] = seenTriggerOrder[inputKeyValue] or {}
                seenTriggerOrder[inputKeyValue][#seenTriggerOrder[inputKeyValue] + 1] = resolvedBatchKey
                -- Internal audit event; intentionally omitted.
            elseif event.type == "plan_changed" then
                local side = event.side or event.source.side
                local _, sideError = requireSideSource(event, path, side)
                if sideError then
                    return failure({ makeError("invalid_plan_side", path .. ".side", "계획 사건 side가 올바르지 않습니다.") })
                end
                local beforeSlots = payload.before
                local afterSlots = payload.after
                local capacity = beforeState[side].planCapacity
                local _, beforeSlotError = validatePlanSlotsSnapshot(
                    beforeSlots,
                    path .. ".payload.before",
                    capacity
                )
                local _, afterSlotError = validatePlanSlotsSnapshot(
                    afterSlots,
                    path .. ".payload.after",
                    capacity
                )
                local _, movedIdsError = validateIdArray(payload.movedInstanceIds, path .. ".payload.movedInstanceIds")
                if beforeSlotError or afterSlotError or movedIdsError then
                    return failure({ beforeSlotError or afterSlotError or movedIdsError })
                end
                if not dataEqual(beforeSlots, trackers[side].slots) then
                    return failure({ makeError("plan_before_mismatch", path .. ".payload.before", "계획 사건 before가 앞선 계획 상태와 다릅니다.") })
                end
                local cardId = event.source.id
                if payload.action == "triggered" then
                    local lookupErrors = {}
                    local card = findCard(staticData, cardId, side, path .. ".source.id", lookupErrors)
                    local beforeSlot, beforeIndex = findPlanSlot(beforeSlots, event.source.instanceId)
                    local expectedAfter, expectedAfterError = cloneData(beforeSlots, path .. ".payload.before", {})
                    if expectedAfterError then return failure({ expectedAfterError }) end
                    local expectedSlot = beforeIndex and expectedAfter[beforeIndex] or nil
                    if expectedSlot ~= nil then
                        expectedSlot.revealed = true
                        if expectedSlot.remainingCharges ~= nil then
                            expectedSlot.remainingCharges = expectedSlot.remainingCharges - 1
                            if expectedSlot.remainingCharges == 0 then
                                table.remove(expectedAfter, beforeIndex)
                            end
                        end
                    end
                    local afterSlot, afterIndex = findPlanSlot(afterSlots, event.source.instanceId)
                    local discarded = afterSlot == nil
                    if #lookupErrors > 0
                        or event.source.kind ~= "plan"
                        or card.cardType ~= "plan"
                        or triggerPhases[event.phase] ~= true
                        or type(event.cause) ~= "table"
                        or event.cause.kind ~= (event.resolutionId ~= nil and "card_resolution" or "turn_event")
                        or payload.instanceId ~= nil
                        or type(payload.discarded) ~= "boolean"
                        or payload.planSpec ~= nil
                        or beforeSlot == nil
                        or beforeSlot.cardId ~= cardId
                        or not dataEqual(afterSlots, expectedAfter)
                        or (afterSlot ~= nil
                            and (afterSlot.cardId ~= cardId
                                or afterSlot.revealed ~= true
                                or afterIndex ~= beforeIndex))
                        or (payload.discarded == true
                            and not arraysEqual(payload.movedInstanceIds, { beforeSlot.cardInstanceId }))
                        or (payload.discarded == false and #payload.movedInstanceIds ~= 0)
                        or payload.discarded ~= discarded then
                        return failure(#lookupErrors > 0 and lookupErrors or {
                            makeError("invalid_plan_trigger", path, "계획 발동 사건이 source·슬롯과 일치하지 않습니다."),
                        })
                    end
                    local key = planKey(event)
                    if pendingPlanSlots[key] == nil then
                        pendingPlanSlots[key] = { slot = beforeSlot, slotIndex = beforeIndex }
                    end
                    local remainingTurns = afterSlot and afterSlot.remainingTurns or nil
                    local ok, planError = emitPlan(
                        side,
                        "triggered",
                        card.id,
                        true,
                        remainingTurns,
                        beforeIndex,
                        "planTriggered",
                        true
                    )
                    if not ok then
                        return failure({ planError })
                    end
                    trackers[side].slots = afterSlots
                    if postCleanupSnapshot ~= nil then
                        postCleanupSnapshot[side].planSlots = afterSlots
                        if payload.discarded == true then
                            postCleanupSnapshot[side].discard[#postCleanupSnapshot[side].discard + 1] = beforeSlot.cardInstanceId
                        end
                    end
                    if pendingPlanMeanings[key] ~= nil then
                        return failure({ makeError("duplicate_plan_meaning", path, "같은 계획 발동 의미 사건이 중복되었습니다.") })
                    end
                    pendingPlanMeanings[key] = true
                elseif payload.action == "placed" then
                    local lookupErrors = {}
                    local placedCard = findCard(staticData, cardId, side, path .. ".source.id", lookupErrors)
                    local placedPlanData = type(placedCard) == "table"
                        and type(placedCard.mechanismData) == "table"
                        and placedCard.mechanismData.plan
                        or nil
                    local expectedIncludesPlacementTurn = type(placedPlanData) == "table"
                        and placedPlanData.durationIncludesPlacementTurn == true
                    local _, planSpecError = validatePlanSpecSnapshot(payload.planSpec, path .. ".payload.planSpec")
                    local planSpec = type(payload.planSpec) == "table" and payload.planSpec or {}
                    local expectedPlanSpec = nil
                    if type(placedPlanData) == "table" then
                        expectedPlanSpec = {
                            revealed = false,
                        }
                        if planSpec.effectChoiceId ~= nil then
                            local planChoice = findEffectChoice(placedCard, planSpec.effectChoiceId)
                            if planChoice == nil or planChoice.placesPlan == false then
                                planSpecError = planSpecError or makeError(
                                    "invalid_plan_effect_choice",
                                    path .. ".payload.planSpec.effectChoiceId",
                                    "계획 배치에 유효하지 않은 효과 선택값입니다."
                                )
                            else
                                expectedPlanSpec.effectChoiceId = planSpec.effectChoiceId
                            end
                        elseif type(placedCard.effectChoices) == "table" then
                            planSpecError = planSpecError or makeError(
                                "missing_plan_effect_choice",
                                path .. ".payload.planSpec.effectChoiceId",
                                "선택형 계획 배치에 효과 선택값이 없습니다."
                            )
                        end
                        if placedPlanData.durationTurns ~= nil then
                            expectedPlanSpec.durationTurns = placedPlanData.durationTurns
                        end
                        if placedPlanData.durationIncludesPlacementTurn ~= nil then
                            expectedPlanSpec.durationIncludesPlacementTurn =
                                placedPlanData.durationIncludesPlacementTurn
                        end
                        if placedPlanData.charges ~= nil then
                            expectedPlanSpec.charges = placedPlanData.charges
                        end
                    end
                    local planSpecStaticError = expectedPlanSpec ~= nil
                        and not dataEqual(planSpec, expectedPlanSpec)
                        and makeError(
                            "plan_spec_static_mismatch",
                            path .. ".payload.planSpec",
                            "계획 배치 명세가 정적 카드 계획 정의와 다릅니다."
                        )
                        or nil
                    local capacity = type(beforeState[side]) == "table" and beforeState[side].planCapacity or nil
                    local expectedAfter, expectedAfterError = cloneData(beforeSlots, path .. ".payload.before", {})
                    if expectedAfterError then return failure({ expectedAfterError }) end
                    local replacedSlot = nil
                    if isInteger(capacity, 1) and #expectedAfter >= capacity then
                        replacedSlot = table.remove(expectedAfter, 1)
                    end
                    local expectedPlacedSlot = {
                        occupied = true,
                        cardInstanceId = payload.instanceId,
                        cardId = cardId,
                        placedTurn = resolution.turnNumber,
                        durationIncludesPlacementTurn = planSpec.durationIncludesPlacementTurn == true,
                        revealed = planSpec.revealed,
                    }
                    if planSpec.durationTurns ~= nil then
                        expectedPlacedSlot.remainingTurns = planSpec.durationTurns
                    end
                    if planSpec.charges ~= nil then
                        expectedPlacedSlot.remainingCharges = planSpec.charges
                    end
                    if planSpec.effectChoiceId ~= nil then
                        expectedPlacedSlot.effectChoiceId = planSpec.effectChoiceId
                    end
                    expectedAfter[#expectedAfter + 1] = expectedPlacedSlot
                    local expectedMovedIds = replacedSlot ~= nil
                        and { replacedSlot.cardInstanceId, payload.instanceId }
                        or { payload.instanceId }
                    local afterSlot, afterIndex = findPlanSlot(afterSlots, payload.instanceId)
                    if #lookupErrors > 0
                        or planSpecError
                        or planSpecStaticError
                        or event.source.kind ~= "card"
                        or placedCard.cardType ~= "plan"
                        or event.phase ~= side .. "_card"
                        or event.resolutionId == nil
                        or type(event.cause) ~= "table"
                        or event.cause.kind ~= "card_resolution"
                        or not isRuntimeId(payload.instanceId)
                        or payload.instanceId ~= event.source.instanceId
                        or payload.discarded ~= nil
                        or not isInteger(capacity, 1)
                        or #beforeSlots > capacity
                        or not dataEqual(afterSlots, expectedAfter)
                        or afterSlot == nil
                        or afterIndex ~= #afterSlots
                        or (planSpec.durationIncludesPlacementTurn == true)
                            ~= expectedIncludesPlacementTurn
                        or (side == "character" and planSpec.revealed ~= false)
                        or not arraysEqual(payload.movedInstanceIds, expectedMovedIds) then
                        return failure(#lookupErrors > 0 and lookupErrors or {
                            planSpecError
                                or planSpecStaticError
                                or makeError("invalid_plan_placement", path, "계획 배치 사건이 카드·슬롯과 일치하지 않습니다."),
                        })
                    end
                    if replacedSlot ~= nil then
                        local previousKnown = planKnown(side, replacedSlot)
                        local replaced, replaceError = emitPlan(
                            side,
                            "replaced",
                            replacedSlot.cardId,
                            previousKnown,
                            nil,
                            1,
                            previousKnown and "planExpired" or nil,
                            false
                        )
                        if not replaced then
                            return failure({ replaceError })
                        end
                    end
                    local newCardId = afterSlot.cardId
                    local newKnown = planKnown(side, afterSlot)
                    local remainingTurns = afterSlot.remainingTurns
                    local placed, placeError = emitPlan(
                        side,
                        "placed",
                        newCardId,
                        newKnown,
                        remainingTurns,
                        afterIndex,
                        newKnown and "planPlaced" or nil,
                        true
                    )
                    if not placed then
                        return failure({ placeError })
                    end
                    trackers[side].slots = afterSlots
                else
                    return failure({ makeError("unknown_plan_action", path .. ".payload.action", "지원하지 않는 plan_changed action입니다.") })
                end
            elseif event.type == "card_restored" then
                local lookupErrors = {}
                findCard(staticData, event.source.id, "player", path .. ".source.id", lookupErrors)
                if #lookupErrors > 0
                    or event.source.kind ~= "card"
                    or event.side ~= "player"
                    or event.source.side ~= "player"
                    or event.phase ~= "player_card"
                    or not isRuntimeId(payload.instanceId)
                    or payload.instanceId ~= event.source.instanceId
                    or not isAsciiId(payload.reasonCode)
                    or payload.destination ~= "hand" then
                    return failure(#lookupErrors > 0 and lookupErrors or {
                        makeError("invalid_card_restore", path, "카드 복원 사건이 올바르지 않습니다."),
                    })
                end
                trackedHandCount.player = trackedHandCount.player + 1
                -- Individual instance IDs are private; the following summary event carries a safe count.
            elseif event.type == "action_sequence_stopped" then
                local side = payload.side or event.side
                local hasRestored = payload.restoredInstanceIds ~= nil
                local hasUnresolved = payload.unresolvedInstanceIds ~= nil
                local ids = hasRestored and payload.restoredInstanceIds or payload.unresolvedInstanceIds
                local _, idsError = validateIdArray(ids, path .. ".payload.instances")
                local _, sourceError = requireSource(event, path, "system", "turn_resolver")
                if sourceError
                    or not isSide(side)
                    or event.side ~= side
                    or event.phase ~= side .. "_card"
                    or payload.side ~= side
                    or hasRestored == hasUnresolved
                    or idsError
                    or not isAsciiId(payload.reasonCode) then
                    return failure({ sourceError or idsError or makeError("invalid_stopped_event", path .. ".payload", "중단 카드 사건이 올바르지 않습니다.") })
                end
                local safe = {
                    side = side,
                    reasonCode = payload.reasonCode,
                    count = #ids,
                }
                emit(publicResult, "actions_stopped", safe)
                emit(llmEvent, "actions_stopped", {
                    side = safe.side,
                    reasonCode = safe.reasonCode,
                    count = safe.count,
                })
            elseif event.type == "card_zone_changed" then
                local side = event.side
                local lookupErrors = {}
                findCard(staticData, event.source.id, side, path .. ".source.id", lookupErrors)
                if #lookupErrors > 0
                    or event.source.kind ~= "card"
                    or not isSide(side)
                    or event.source.side ~= side
                    or event.phase ~= side .. "_card"
                    or not isRuntimeId(payload.instanceId)
                    or payload.instanceId ~= event.source.instanceId
                    or payload.origin ~= "used"
                    or payload.destination ~= "removed" then
                    return failure({ makeError("unsupported_zone_change", path .. ".payload.destination", "공개 투영에서 지원하지 않는 카드 영역 이동입니다.") })
                end
                local safe = { side = side }
                if side == "player" then
                    safe.cardId = event.source.id
                end
                emit(publicResult, "card_removed", safe)
            elseif event.type == "outcome_latched" then
                local _, sourceError = requireSource(event, path, "system", "turn_resolver")
                local resourceOutcome = trackedResistance <= 0 and "victory"
                    or (trackedStealth <= 0 and "defeat" or nil)
                local expectedOutcome = resourceOutcome
                local expectedReason = event.phase == "turn_end" and "turn_end_checkpoint" or "card_checkpoint"
                if event.phase == "turn_end"
                    and sawMoodStealthEffect == true
                    and resourceOutcome == "defeat" then
                    expectedReason = "mood_state_checkpoint"
                elseif resourceOutcome == nil
                    and event.phase == "turn_end"
                    and resolution.turnNumber == beforeState.turnLimit then
                    expectedOutcome = "defeat"
                    expectedReason = "turn_limit"
                end
                if sourceError
                    or latchedOutcome ~= nil
                    or (event.phase ~= "player_card" and event.phase ~= "character_card" and event.phase ~= "turn_end")
                    or not isOutcome(payload.status)
                    or payload.status ~= expectedOutcome
                    or not isAsciiId(payload.reasonCode)
                    or payload.reasonCode ~= expectedReason
                    or (event.phase == "turn_end" and event.resolutionId ~= nil)
                    or (event.phase ~= "turn_end" and event.resolutionId == nil)
                    or not isFinite(payload.stealth)
                    or not isFinite(payload.resistance)
                    or payload.stealth ~= trackedStealth
                    or payload.resistance ~= trackedResistance
                    or payload.stealth ~= resolution.afterState.player.stealth
                    or payload.resistance ~= resolution.afterState.character.resistance then
                    return failure({ sourceError or makeError("invalid_outcome", path .. ".payload", "승패 사건 payload가 올바르지 않습니다.") })
                end
                latchedOutcome = payload.status
                local safe = {
                    status = payload.status,
                    reasonCode = payload.reasonCode,
                    stealth = payload.stealth,
                    resistance = payload.resistance,
                }
                emit(publicResult, "outcome", safe)
                emit(llmEvent, "outcome", {
                    status = payload.status,
                    reasonCode = payload.reasonCode,
                })
            elseif event.type == "mood_evaluated" then
                local _, sourceError = requireSource(event, path, "system", "mood_tokens")
                local moods = staticData.registry.moods
                local moodByOrder = {}
                for moodId, mood in pairs(moods) do moodByOrder[mood.order] = moodId end
                local expectedMoodAfter = trackedMood
                local expectedTokensAfter = normalizedMoodTokens(trackedMoodTokens)
                local expectedResolution
                local expectedTargetMood
                local expectedTiedMoods
                local forcedCount = #trackedForcedMoodRequests
                if forcedCount == 1 then
                    expectedResolution = "forced"
                    expectedTargetMood = trackedForcedMoodRequests[1].mood
                    expectedMoodAfter = expectedTargetMood
                else
                    local maximum = 0
                    local leaders = {}
                    for order = 1, #moodByOrder do
                        local moodId = moodByOrder[order]
                        local count = expectedTokensAfter[moodId]
                        if count > maximum then
                            maximum = count
                            leaders = { moodId }
                        elseif count == maximum then
                            leaders[#leaders + 1] = moodId
                        end
                    end
                    if maximum < 3 then
                        expectedResolution = "none"
                    elseif #leaders == 1 then
                        expectedResolution = "token"
                        expectedTargetMood = leaders[1]
                        expectedTokensAfter[expectedTargetMood] = 0
                        expectedMoodAfter = expectedTargetMood
                    else
                        expectedResolution = "tie"
                        expectedTiedMoods = leaders
                        for _, moodId in ipairs(leaders) do
                            expectedTokensAfter[moodId] = expectedTokensAfter[moodId] - 1
                        end
                    end
                end
                local expectedApplied = trackedMood ~= expectedMoodAfter
                if sourceError
                    or sawMoodEvaluation
                    or event.phase ~= "turn_end"
                    or event.side ~= "character"
                    or type(moods) ~= "table"
                    or type(moods[payload.before]) ~= "table"
                    or type(moods[payload.after]) ~= "table"
                    or payload.before ~= trackedMood
                    or payload.after ~= resolution.afterState.character.mood
                    or payload.after ~= expectedMoodAfter
                    or type(payload.applied) ~= "boolean"
                    or payload.applied ~= expectedApplied
                    or payload.forcedCount ~= forcedCount
                    or payload.forceCancelled ~= (forcedCount >= 2)
                    or payload.resolution ~= expectedResolution
                    or payload.targetMood ~= expectedTargetMood
                    or not dataEqual(payload.tiedMoods, expectedTiedMoods)
                    or not dataEqual(payload.tokensBefore, trackedMoodTokens)
                    or not dataEqual(payload.tokensAfter, expectedTokensAfter)
                    or not dataEqual(expectedTokensAfter, normalizedMoodTokens(resolution.afterState.character.moodTokens)) then
                    return failure({ sourceError or makeError("invalid_mood_evaluation", path .. ".payload", "무드 평가 사건 payload가 올바르지 않습니다.") })
                end
                sawMoodEvaluation = true
                trackedMood = payload.after
                trackedMoodTokens = expectedTokensAfter
                expectedMoodStealthEffect = nil
                if latchedOutcome == nil then
                    expectedMoodStealthEffect = moodStealthEffect(
                        payload.after,
                        resolution.turnNumber > 1 and payload.before == payload.after
                    )
                end
                local safe = {
                    before = payload.before,
                    after = payload.after,
                    applied = payload.applied == true,
                    forcedCount = payload.forcedCount,
                    forceCancelled = payload.forceCancelled,
                    resolution = payload.resolution,
                    tokensBefore = payload.tokensBefore,
                    tokensAfter = payload.tokensAfter,
                }
                if payload.targetMood ~= nil then safe.targetMood = payload.targetMood end
                if payload.tiedMoods ~= nil then safe.tiedMoods = payload.tiedMoods end
                emit(publicResult, "mood_evaluated", safe)
                if payload.applied == true then
                    emit(llmEvent, "mood_changed", {
                        before = payload.before,
                        after = payload.after,
                        resolution = payload.resolution,
                    })
                end
            elseif event.type == "turn_cleanup" then
                local _, sourceError = requireSource(event, path, "system", "card_zones")
                local capacities = {
                    player = beforeState.player.planCapacity,
                    character = beforeState.character.planCapacity,
                }
                local _, beforeError = validateCleanupSnapshot(
                    payload.before,
                    path .. ".payload.before",
                    capacities
                )
                local _, afterError = validateCleanupSnapshot(
                    payload.after,
                    path .. ".payload.after",
                    capacities
                )
                local _, movedError = validateIdArray(payload.movedInstanceIds, path .. ".payload.movedInstanceIds")
                local expectedAfter, expectedMoved, transitionError
                if beforeError == nil and afterError == nil then
                    expectedAfter, expectedMoved, transitionError = expectedCleanupTransition(
                        payload.before,
                        resolution.turnNumber,
                        payload.after.turnNumber
                    )
                end
                if sourceError
                    or beforeError
                    or afterError
                    or movedError
                    or transitionError
                    or sawCleanup
                    or sawMoodEvaluation ~= true
                    or event.phase ~= "cleanup"
                    or event.side ~= nil
                    or not isInteger(payload.resolvedTurnNumber, 1)
                    or payload.resolvedTurnNumber ~= resolution.turnNumber
                    or payload.before.turnNumber ~= resolution.turnNumber
                    or (resolution.afterState.status == "active"
                        and payload.after.turnNumber ~= resolution.turnNumber + 1)
                    or (resolution.afterState.status ~= "active"
                        and payload.after.turnNumber ~= resolution.turnNumber)
                    or not dataEqual(payload.after, expectedAfter)
                    or not arraysEqual(payload.movedInstanceIds, expectedMoved)
                    or not dataEqual(payload.before.player.planSlots, trackers.player.slots)
                    or not dataEqual(payload.before.character.planSlots, trackers.character.slots)
                    or trackedStealth ~= resolution.afterState.player.stealth
                    or trackedResistance ~= resolution.afterState.character.resistance
                    or trackedMood ~= resolution.afterState.character.mood
                    or not dataEqual(trackedMoodTokens, normalizedMoodTokens(resolution.afterState.character.moodTokens)) then
                    return failure({ sourceError or beforeError or afterError or movedError or transitionError
                        or makeError("invalid_turn_cleanup", path .. ".payload", "턴 정리 사건 payload가 올바르지 않습니다.") })
                end
                sawCleanup = true
                postCleanupSnapshot = payload.after
                trackedHandCount.player = 0
                trackedHandCount.character = 0
                for _, side in ipairs({ "player", "character" }) do
                    local beforeSlots = type(payload.before) == "table"
                        and type(payload.before[side]) == "table"
                        and payload.before[side].planSlots
                        or {}
                    local afterSlots = type(payload.after) == "table"
                        and type(payload.after[side]) == "table"
                        and payload.after[side].planSlots
                        or {}
                    for beforeIndex, beforeSlot in ipairs(beforeSlots) do
                        local afterSlot = findPlanSlot(afterSlots, beforeSlot.cardInstanceId)
                        if afterSlot == nil then
                            local known = planKnown(side, beforeSlot)
                            local expired, expireError = emitPlan(
                                side,
                                "expired",
                                beforeSlot.cardId,
                                known,
                                nil,
                                beforeIndex,
                                known and "planExpired" or nil,
                                false
                            )
                            if not expired then
                                return failure({ expireError })
                            end
                        end
                    end
                    trackers[side].slots = afterSlots
                end
                emit(publicResult, "turn_ended", { turnNumber = payload.resolvedTurnNumber })
            elseif event.type == "session_end" then
                local _, sourceError = requireSource(event, path, "system", "turn_resolver")
                if sourceError
                    or sawSessionEnd
                    or index ~= #resolution.events
                    or event.phase ~= "session_end"
                    or event.side ~= nil
                    or not isOutcome(payload.status)
                    or payload.status ~= resolution.afterState.status then
                    return failure({ sourceError or makeError("invalid_session_end", path .. ".payload.status", "세션 종료 사건이 최종 상태와 다릅니다.") })
                end
                sawSessionEnd = true
                emit(publicResult, "session_ended", { status = payload.status })
                emit(llmEvent, "session_ended", { status = payload.status })
            else
                return failure({ makeError("unknown_event_type", path .. ".type", "지원하지 않는 원본 사건입니다.") })
            end
        end

        if sawTurnStart ~= true then
            return failure({ makeError("missing_turn_start", "$.turnResolution.events", "턴 시작 사건이 없습니다.") })
        end
        if sawCharacterIntent ~= true then
            return failure({ makeError("missing_character_intent", "$.turnResolution.events", "캐릭터 의도 선택 사건이 없습니다.") })
        end
        if sawStartDraw.player ~= true or sawStartDraw.character ~= true then
            return failure({ makeError("missing_start_draw", "$.turnResolution.events", "양측 턴 시작 드로우 사건이 모두 필요합니다.") })
        end
        if pendingCharacterIntent then
            return failure({ makeError("missing_role_reveal", "$.turnResolution.events", "선택된 캐릭터 의도의 공개 역할 사건이 없습니다.") })
        end
        if sawMoodEvaluation ~= true or sawCleanup ~= true then
            return failure({ makeError("incomplete_turn_tail", "$.turnResolution.events", "무드 평가 또는 턴 정리 사건이 없습니다.") })
        end
        if resolution.afterState.status == "active" then
            if latchedOutcome ~= nil or sawSessionEnd then
                return failure({ makeError("active_turn_has_terminal_event", "$.turnResolution.events", "진행 중 상태에 종료 사건이 있습니다.") })
            end
        elseif not isOutcome(resolution.afterState.status)
            or latchedOutcome ~= resolution.afterState.status
            or sawSessionEnd ~= true then
            return failure({ makeError("terminal_event_mismatch", "$.turnResolution.events", "최종 상태와 승패·세션 종료 사건이 일치하지 않습니다.") })
        end
        for _ in pairs(pendingCosts) do
            return failure({ makeError("unmatched_card_cost", "$.turnResolution.events", "card_declared와 짝이 없는 은폐 비용 사건이 있습니다.") })
        end
        for _ in pairs(pendingDeclarations) do
            return failure({ makeError("unmatched_card_declaration", "$.turnResolution.events", "card_resolved와 짝이 없는 카드 선언이 있습니다.") })
        end
        for _, effects in pairs(pendingTriggerEffects) do
            if #effects > 0 then
                return failure({ makeError("unmatched_trigger_effect", "$.turnResolution.events", "trigger_resolved와 짝이 없는 트리거 효과 사건이 있습니다.") })
            end
        end
        for _ in pairs(pendingPlanMeanings) do
            return failure({ makeError("unmatched_plan_meaning", "$.turnResolution.events", "trigger_resolved와 짝이 없는 계획 발동 사건이 있습니다.") })
        end
        local expectedTriggerBatches, expectedTriggerOrder, expectedTriggerError = collectExpectedTriggerBatches()
        if expectedTriggerError then return failure({ expectedTriggerError }) end
        if expectedTriggerBatches == nil then
            return failure({
                expectedTriggerOrder
                    or makeError("trigger_replay_failed", "$.turnResolution.events", "예상 트리거 batch를 재구성하지 못했습니다."),
            })
        end
        for key in pairs(expectedTriggerBatches) do
            if seenTriggerBatches[key] ~= true then
                return failure({ makeError("missing_trigger_batch", "$.turnResolution.events", "조건을 만족한 트리거 batch가 사건 로그에 없습니다.") })
            end
        end
        for key in pairs(seenTriggerBatches) do
            if expectedTriggerBatches[key] ~= true then
                return failure({ makeError("unexpected_trigger_batch", "$.turnResolution.events", "조건과 일치하지 않는 트리거 batch가 사건 로그에 있습니다.") })
            end
        end
        for inputKey, expectedOrder in pairs(expectedTriggerOrder) do
            local seenOrder = seenTriggerOrder[inputKey] or {}
            if not arraysEqual(seenOrder, expectedOrder) then
                return failure({ makeError("trigger_batch_order_mismatch", "$.turnResolution.events", "트리거 batch 순서가 snapshot 정렬 규칙과 다릅니다.") })
            end
        end
        for inputKey, seenOrder in pairs(seenTriggerOrder) do
            if expectedTriggerOrder[inputKey] == nil and #seenOrder > 0 then
                return failure({ makeError("unexpected_trigger_batch_order", "$.turnResolution.events", "예상 입력에 없는 트리거 batch 순서가 기록되었습니다.") })
            end
        end
        local finalCleanupSnapshot = cleanupSnapshotFromState(resolution.afterState)
        if postCleanupSnapshot == nil
            or not dataEqual(postCleanupSnapshot, finalCleanupSnapshot)
            or not dataEqual(trackers.player.slots, resolution.afterState.player.planSlots)
            or not dataEqual(trackers.character.slots, resolution.afterState.character.planSlots) then
            return failure({ makeError("final_state_event_mismatch", "$.turnResolution.events", "사건 재생 결과가 최종 상태와 다릅니다.") })
        end

        return success(publicResult, llmEvent)
    end

    local arguments = { ... }
    if action == "projectTurn" then
        return projectTurn(arguments[1], arguments[2], arguments[3])
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 턴 사건 투영 작업입니다."),
    })
end)
