(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MOOD_BOUNDARIES = { 5, 4, 4, 5 }
    local TRIGGER_CATEGORY_ORDER = {
        plan = 1,
        trait = 2,
        perk = 3,
        environment = 4,
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

    local function success(resolution)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            resolution = resolution,
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

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
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

    local function cloneData(value, path, active)
        local valueType = type(value)
        if valueType ~= "table" then
            if valueType == "nil"
                or valueType == "string"
                or valueType == "number"
                or valueType == "boolean" then
                if valueType == "number" and not isFinite(value) then
                    return nil, makeError("non_finite_number", path, "유한하지 않은 숫자는 결과 데이터에 복제할 수 없습니다.")
                end
                return value, nil
            end
            return nil, makeError("unsupported_type", path, "결과 데이터에 복제할 수 없는 자료형입니다: " .. valueType)
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "메타테이블이 있는 값은 결과 데이터에 복제할 수 없습니다.")
        end
        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조는 결과 데이터에 복제할 수 없습니다.")
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            local keyCopy, keyError = cloneData(key, path .. ".<key>", active)
            if keyError then
                active[value] = nil
                return nil, keyError
            end
            local itemCopy, itemError = cloneData(item, path .. "." .. tostring(key), active)
            if itemError then
                active[value] = nil
                return nil, itemError
            end
            copy[keyCopy] = itemCopy
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

    local function appendErrors(target, source)
        if type(source) ~= "table" then
            table.insert(target, makeError("invalid_nested_error", "$", "하위 모듈 오류 목록이 올바르지 않습니다."))
            return
        end
        for _, item in ipairs(source) do
            table.insert(target, {
                code = tostring(type(item) == "table" and item.code or "nested_error"),
                path = tostring(type(item) == "table" and item.path or "$"),
                message = tostring(type(item) == "table" and item.message or "하위 모듈 작업이 실패했습니다."),
            })
        end
    end

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError("runtime_unavailable", "$.runtime." .. moduleName, "스크립트 실행기를 찾을 수 없습니다."),
            }
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok then
            return nil, {
                makeError(
                    "module_call_error",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. " 실행에 실패했습니다: " .. tostring(report)
                ),
            }
        end
        if type(report) ~= "table" then
            return nil, {
                makeError("invalid_module_result", "$.runtime." .. moduleName, "하위 모듈이 테이블 결과를 반환하지 않았습니다."),
            }
        end
        if report.ok ~= true then
            local errors = {}
            appendErrors(errors, report.errors)
            return nil, errors
        end
        return report, nil
    end

    local function findInstance(state, instanceId)
        for _, instance in ipairs(type(state) == "table" and type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if type(instance) == "table" and instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function countZone(state, owner, zone)
        local count = 0
        for _, instance in ipairs(type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if instance.owner == owner and instance.zone == zone then
                count = count + 1
            end
        end
        return count
    end

    local function hasMechanism(card, mechanismId)
        for _, currentId in ipairs(type(card) == "table" and type(card.mechanisms) == "table" and card.mechanisms or {}) do
            if currentId == mechanismId then
                return true
            end
        end
        return false
    end

    local function validateOptions(options, authorityState)
        local errors = {}
        if type(options) ~= "table" or getmetatable(options) ~= nil then
            return nil, { makeError("invalid_options", "$.options", "턴 해결 옵션은 일반 테이블이어야 합니다.") }
        end
        for key in pairs(options) do
            if key ~= "turnId" then
                table.insert(errors, makeError(
                    "unexpected_option",
                    "$.options." .. tostring(key),
                    "지원하지 않는 턴 해결 옵션입니다."
                ))
            end
        end
        if not isRuntimeId(options.turnId) then
            table.insert(errors, makeError("invalid_turn_id", "$.options.turnId", "turnId가 올바르지 않습니다."))
        elseif type(authorityState) == "table" and authorityState.lastCommittedTurnId == options.turnId then
            table.insert(errors, makeError("turn_already_committed", "$.options.turnId", "이미 확정한 turnId를 다시 해결할 수 없습니다."))
        end
        if #errors > 0 then
            return nil, errors
        end
        return { turnId = options.turnId }, nil
    end

    local function buildContext(state, phase, card, instance, plan)
        local context = {
            turn = state.turnNumber,
            phase = phase,
            mood = state.character.mood,
            player = {
                stealth = state.player.stealth,
                handCount = countZone(state, "player", "hand"),
            },
            character = {
                resistance = state.character.resistance,
                publicActionTag = state.characterIntent.publicActionTag,
            },
        }
        if card ~= nil and instance ~= nil then
            context.card = {
                id = card.id,
                instanceId = instance.instanceId,
                owner = card.owner,
                actionTag = card.actionTag,
            }
        end
        if plan ~= nil then
            context.plan = {
                cardId = plan.cardId,
                cardInstanceId = plan.cardInstanceId,
                side = plan.side,
                revealed = plan.revealed,
            }
            if plan.remainingTurns ~= nil then
                context.plan.remainingTurns = plan.remainingTurns
            end
            if plan.remainingCharges ~= nil then
                context.plan.remainingCharges = plan.remainingCharges
            end
        end
        return context
    end

    local function resolveTurn(authorityState, staticData, projection, options)
        local normalizedOptions, optionErrors = validateOptions(options, authorityState)
        if optionErrors then
            return failure(optionErrors)
        end
        staticData = normalizeStaticData(staticData)

        local projectionReport, projectionErrors = callModule(
            "turnDraft",
            "validateProjection",
            authorityState,
            staticData,
            projection
        )
        if projectionErrors then
            return failure(projectionErrors)
        end
        local validatedProjection = projectionReport.projection
        if type(validatedProjection) ~= "table" or type(validatedProjection.workingState) ~= "table" then
            return failure({
                makeError("invalid_projection_result", "$.projection", "검증된 projection에 workingState가 없습니다."),
            })
        end

        local workingState, cloneError = cloneData(validatedProjection.workingState, "$.projection.workingState")
        if cloneError then
            return failure({ cloneError })
        end
        local playerSelection, selectionCloneError = cloneData(
            validatedProjection.selectedCardInstanceIds,
            "$.projection.selectedCardInstanceIds"
        )
        if selectionCloneError then
            return failure({ selectionCloneError })
        end
        local characterSelection, characterCloneError = cloneData(
            workingState.characterIntent.cardInstanceIds,
            "$.projection.workingState.characterIntent.cardInstanceIds"
        )
        if characterCloneError then
            return failure({ characterCloneError })
        end
        if not isDenseArray(playerSelection) or not isDenseArray(characterSelection) then
            return failure({ makeError("invalid_selection", "$.projection", "선택 목록이 연속 배열이 아닙니다.") })
        end

        local turnId = normalizedOptions.turnId
        local resolvedTurnNumber = authorityState.turnNumber
        local events = {}
        local nextResolutionOrdinal = 1
        local working = {
            state = workingState,
            transient = {
                skipRemaining = { player = false, character = false },
                directMoodChanged = false,
                moodLockApplied = false,
                halted = false,
            },
        }
        local startValues = {
            stealth = authorityState.player.stealth,
            resistance = authorityState.character.resistance,
            mood = authorityState.character.mood,
        }

        local function source(kind, id, side, instanceId)
            local value = { kind = kind, id = id }
            if side ~= nil then
                value.side = side
            end
            if instanceId ~= nil then
                value.instanceId = instanceId
            end
            return value
        end

        local function appendEvent(eventType, phase, eventSource, payload, resolutionId, side, cause)
            local sequence = #events + 1
            local event = {
                eventId = turnId .. "-event-" .. string.format("%03d", sequence),
                sequence = sequence,
                type = eventType,
                phase = phase,
                source = eventSource,
            }
            if payload ~= nil then
                event.payload = payload
            end
            if resolutionId ~= nil then
                event.resolutionId = resolutionId
            end
            if side ~= nil then
                event.side = side
            end
            if cause ~= nil then
                event.cause = cause
            end
            events[sequence] = event
            return event
        end

        local function cardSource(card, instance)
            return source("card", card.id, card.owner, instance.instanceId)
        end

        local function resolutionCause(resolutionId)
            return {
                kind = "card_resolution",
                resolutionId = resolutionId,
            }
        end

        local function applyCommands(commands, eventSource, phase, resolutionId, side, causeKind)
            if #commands == 0 then
                return true, nil
            end
            local report, errors = callModule(
                "effectEngine",
                "applyCommands",
                staticData,
                { state = working.state, transient = working.transient },
                commands
            )
            if errors then
                return false, errors
            end
            working.state = report.state
            working.transient = report.transient
            for _, applied in ipairs(report.applied or {}) do
                local payload, payloadError = cloneData(applied, "$.effect.applied")
                if payloadError then
                    return false, { payloadError }
                end
                appendEvent(
                    "effect_applied",
                    phase,
                    eventSource,
                    payload,
                    resolutionId,
                    side,
                    {
                        kind = causeKind,
                        resolutionId = resolutionId,
                    }
                )
            end
            return true, nil
        end

        local function applyCost(card, instance, finalCost, phase, resolutionId)
            local before = working.state.player.stealth
            local after = before - finalCost
            if not isFinite(after) then
                return false, {
                    makeError("non_finite_result", "$.player.stealth", "은폐 비용 적용 결과가 유한하지 않습니다."),
                }
            end
            working.state.player.stealth = after
            appendEvent(
                "effect_applied",
                phase,
                cardSource(card, instance),
                {
                    op = "pay_stealth_cost",
                    target = "player",
                    amount = finalCost,
                    before = before,
                    after = after,
                    changed = before ~= after,
                },
                resolutionId,
                card.owner,
                resolutionCause(resolutionId)
            )
            return true, nil
        end

        local function sideRank(side, actingSide)
            if actingSide ~= nil and side == actingSide then
                return 1
            end
            if actingSide ~= nil and (side == "player" or side == "character") then
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

        local function collectTriggers(inputEvent, phase, currentCard, currentInstance)
            local snapshot, snapshotError = cloneData(working.state, "$.triggerSnapshot")
            if snapshotError then
                return nil, { snapshotError }
            end
            local candidates = {}

            local function addCandidate(kind, sourceId, ownerSide, declarationIndex, spec, planState)
                if type(spec) ~= "table" or type(spec.resolve) ~= "function" then
                    return false, {
                        makeError("invalid_trigger", "$.staticData", "트리거 정의가 올바르지 않습니다: " .. tostring(sourceId)),
                    }
                end
                candidates[#candidates + 1] = {
                    kind = kind,
                    categoryOrder = TRIGGER_CATEGORY_ORDER[kind],
                    sourceId = sourceId,
                    side = ownerSide,
                    declarationIndex = declarationIndex or 1,
                    spec = spec,
                    planState = planState,
                }
                return true, nil
            end

            for _, planSide in ipairs({ "player", "character" }) do
                local ownerState = snapshot[planSide]
                local slot = type(ownerState) == "table" and ownerState.planSlot or nil
                if type(slot) == "table" and slot.occupied == true then
                    local card = staticData.cards[slot.cardId]
                    local planData = type(card) == "table"
                        and type(card.mechanismData) == "table"
                        and card.mechanismData.plan
                        or nil
                    if type(planData) ~= "table" then
                        return nil, {
                            makeError("missing_plan_definition", "$.staticData.cards." .. tostring(slot.cardId), "계획 정의를 찾을 수 없습니다."),
                        }
                    end
                    local planState = {
                        side = planSide,
                        cardId = slot.cardId,
                        cardInstanceId = slot.cardInstanceId,
                        revealed = slot.revealed,
                    }
                    if slot.remainingTurns ~= nil then
                        planState.remainingTurns = slot.remainingTurns
                    end
                    if slot.remainingCharges ~= nil then
                        planState.remainingCharges = slot.remainingCharges
                    end
                    local added, addErrors = addCandidate("plan", slot.cardId, planSide, 1, planData, planState)
                    if not added then
                        return nil, addErrors
                    end
                end
            end

            for _, traitId in ipairs(snapshot.character.traitIds or {}) do
                local trait = staticData.traits[traitId]
                if type(trait) ~= "table" then
                    return nil, { makeError("unknown_trait", "$.character.traitIds", "특징을 찾을 수 없습니다: " .. tostring(traitId)) }
                end
                if trait.triggers ~= nil then
                    if not isDenseArray(trait.triggers) then
                        return nil, { makeError("invalid_triggers", "$.staticData.traits." .. traitId, "특징 트리거가 배열이 아닙니다.") }
                    end
                    for index, spec in ipairs(trait.triggers) do
                        local added, addErrors = addCandidate("trait", traitId, trait.owner, index, spec, nil)
                        if not added then
                            return nil, addErrors
                        end
                    end
                end
            end

            for _, perkId in ipairs(snapshot.player.perkIds or {}) do
                local perk = type(staticData.perks) == "table" and staticData.perks[perkId] or nil
                if type(perk) ~= "table" then
                    return nil, { makeError("unknown_perk", "$.player.perkIds", "퍽을 찾을 수 없습니다: " .. tostring(perkId)) }
                end
                if perk.triggers ~= nil then
                    if not isDenseArray(perk.triggers) then
                        return nil, { makeError("invalid_triggers", "$.staticData.perks." .. perkId, "퍽 트리거가 배열이 아닙니다.") }
                    end
                    for index, spec in ipairs(perk.triggers) do
                        local added, addErrors = addCandidate("perk", perkId, perk.owner or "player", index, spec, nil)
                        if not added then
                            return nil, addErrors
                        end
                    end
                end
            end

            local environment = staticData.environments[snapshot.environmentId]
            if type(environment) ~= "table" then
                return nil, { makeError("unknown_environment", "$.environmentId", "환경을 찾을 수 없습니다.") }
            end
            if not isDenseArray(environment.triggers) then
                return nil, { makeError("invalid_triggers", "$.staticData.environments." .. environment.id, "환경 트리거가 배열이 아닙니다.") }
            end
            for index, spec in ipairs(environment.triggers) do
                local added, addErrors = addCandidate("environment", environment.id, nil, index, spec, nil)
                if not added then
                    return nil, addErrors
                end
            end

            table.sort(candidates, function(left, right)
                if left.categoryOrder ~= right.categoryOrder then
                    return left.categoryOrder < right.categoryOrder
                end
                local leftSide = sideRank(left.side, inputEvent.side)
                local rightSide = sideRank(right.side, inputEvent.side)
                if leftSide ~= rightSide then
                    return leftSide < rightSide
                end
                if left.sourceId ~= right.sourceId then
                    return left.sourceId < right.sourceId
                end
                return left.declarationIndex < right.declarationIndex
            end)

            local matched = {}
            for _, candidate in ipairs(candidates) do
                local context = buildContext(
                    snapshot,
                    phase,
                    currentCard,
                    currentInstance,
                    candidate.planState
                )
                local conditionReport, conditionErrors = callModule(
                    "effectEngine",
                    "evaluateTriggerCondition",
                    staticData,
                    candidate.spec,
                    context,
                    inputEvent
                )
                if conditionErrors then
                    return nil, conditionErrors
                end
                if conditionReport.matched == true then
                    candidate.context = context
                    matched[#matched + 1] = candidate
                end
            end
            return matched, nil
        end

        local function applyTriggerBatch(candidates, inputEvent, phase, resolutionId, insightSide, allowGameplayCommands)
            for _, candidate in ipairs(candidates) do
                local triggerSource = source(
                    candidate.kind,
                    candidate.sourceId,
                    candidate.side,
                    candidate.planState and candidate.planState.cardInstanceId or nil
                )
                local suppressed = insightSide ~= nil
                    and candidate.kind == "plan"
                    and candidate.side ~= insightSide
                if suppressed then
                    appendEvent(
                        "trigger_suppressed",
                        phase,
                        triggerSource,
                        {
                            inputEventType = inputEvent.type,
                            reasonCode = "insight",
                            hidden = candidate.side == "character",
                        },
                        resolutionId,
                        candidate.side,
                        resolutionId and resolutionCause(resolutionId) or { kind = "turn_event" }
                    )
                else
                    local resolveReport, resolveErrors = callModule(
                        "effectEngine",
                        "evaluateTriggerResolve",
                        staticData,
                        candidate.spec,
                        candidate.context,
                        inputEvent
                    )
                    if resolveErrors then
                        return false, resolveErrors
                    end
                    if allowGameplayCommands == false and #resolveReport.commands > 0 then
                        return false, {
                            makeError(
                                "unsupported_session_end_commands",
                                "$.staticData." .. candidate.kind .. "." .. candidate.sourceId,
                                "session_end v1 트리거는 전투 자원을 변경하는 명령을 반환할 수 없습니다."
                            ),
                        }
                    end
                    local beforePlanSlot = nil
                    if candidate.kind == "plan" then
                        local slotError
                        beforePlanSlot, slotError = cloneData(
                            working.state[candidate.side].planSlot,
                            "$.plan.before"
                        )
                        if slotError then
                            return false, { slotError }
                        end
                    end
                    local applied, applyErrors = applyCommands(
                        resolveReport.commands,
                        triggerSource,
                        phase,
                        resolutionId,
                        candidate.side,
                        candidate.kind .. "_trigger"
                    )
                    if not applied then
                        return false, applyErrors
                    end

                    if candidate.kind == "plan" then
                        local zoneReport, zoneErrors = callModule(
                            "cardZones",
                            "consumePlanCharge",
                            working.state,
                            candidate.side
                        )
                        if zoneErrors then
                            return false, zoneErrors
                        end
                        working.state = zoneReport.state
                        local afterPlanSlot, slotError = cloneData(
                            working.state[candidate.side].planSlot,
                            "$.plan.after"
                        )
                        if slotError then
                            return false, { slotError }
                        end
                        local planChange = {
                            action = "triggered",
                            before = beforePlanSlot,
                            after = afterPlanSlot,
                            discarded = afterPlanSlot.occupied ~= true,
                            movedInstanceIds = zoneReport.movedInstanceIds or {},
                        }
                        appendEvent(
                            "plan_changed",
                            phase,
                            triggerSource,
                            planChange,
                            resolutionId,
                            candidate.side,
                            resolutionId and resolutionCause(resolutionId) or { kind = "turn_event" }
                        )
                    end

                    appendEvent(
                        "trigger_resolved",
                        phase,
                        triggerSource,
                        {
                            inputEventType = inputEvent.type,
                            commandCount = #resolveReport.commands,
                        },
                        resolutionId,
                        candidate.side,
                        resolutionId and resolutionCause(resolutionId) or { kind = "turn_event" }
                    )
                end
            end
            return true, nil
        end

        local function latchOutcome(reasonCode, phase, resolutionId)
            if working.state.status ~= "active" then
                return working.state.status
            end
            local outcome = nil
            if working.state.character.resistance <= 0 then
                outcome = "victory"
            elseif working.state.player.stealth <= 0 then
                outcome = "defeat"
            end
            if outcome ~= nil then
                working.state.status = outcome
                working.transient.halted = true
                working.transient.haltReason = reasonCode
                appendEvent(
                    "outcome_latched",
                    phase,
                    source("system", "turn_resolver"),
                    {
                        status = outcome,
                        reasonCode = reasonCode,
                        stealth = working.state.player.stealth,
                        resistance = working.state.character.resistance,
                    },
                    resolutionId,
                    nil,
                    resolutionId and resolutionCause(resolutionId) or { kind = "turn_rule" }
                )
            end
            return outcome
        end

        local function restorePlayerCards(startIndex, reasonCode, phase, resolutionId)
            local restored = {}
            for index = startIndex, #playerSelection do
                local instanceId = playerSelection[index]
                local instance = findInstance(working.state, instanceId)
                if instance ~= nil and instance.zone == "used" then
                    local card = staticData.cards[instance.cardId]
                    local zoneReport, zoneErrors = callModule("cardZones", "moveUsedToHand", working.state, instanceId)
                    if zoneErrors then
                        return false, zoneErrors
                    end
                    working.state = zoneReport.state
                    restored[#restored + 1] = instanceId
                    appendEvent(
                        "card_restored",
                        phase,
                        source("card", card.id, "player", instanceId),
                        {
                            instanceId = instanceId,
                            reasonCode = reasonCode,
                            destination = "hand",
                        },
                        resolutionId,
                        "player",
                        resolutionId and resolutionCause(resolutionId) or { kind = "action_sequence" }
                    )
                end
            end
            if #restored > 0 then
                appendEvent(
                    "action_sequence_stopped",
                    phase,
                    source("system", "turn_resolver"),
                    {
                        side = "player",
                        reasonCode = reasonCode,
                        restoredInstanceIds = restored,
                    },
                    resolutionId,
                    "player",
                    resolutionId and resolutionCause(resolutionId) or { kind = "turn_rule" }
                )
            end
            return true, nil
        end

        local function recordSequenceStopped(side, selectedIds, startIndex, reasonCode, phase, resolutionId)
            local unresolved = {}
            for index = startIndex, #selectedIds do
                unresolved[#unresolved + 1] = selectedIds[index]
            end
            if #unresolved == 0 then
                return
            end
            appendEvent(
                "action_sequence_stopped",
                phase,
                source("system", "turn_resolver"),
                {
                    side = side,
                    reasonCode = reasonCode,
                    unresolvedInstanceIds = unresolved,
                },
                resolutionId,
                side,
                resolutionId and resolutionCause(resolutionId) or { kind = "turn_rule" }
            )
        end

        local function finishCardZone(card, instance, phase, resolutionId)
            local isPlan = hasMechanism(card, "plan")
            local isRemove = hasMechanism(card, "remove")
            if isPlan and isRemove then
                return false, {
                    makeError(
                        "unsupported_mechanism_combination",
                        "$.staticData.cards." .. card.id .. ".mechanisms",
                        "plan과 remove의 동시 완료 영역은 아직 정의되지 않았습니다."
                    ),
                }
            end
            if isPlan then
                local planData = type(card.mechanismData) == "table" and card.mechanismData.plan or nil
                if type(planData) ~= "table" then
                    return false, { makeError("missing_plan_definition", "$.staticData.cards." .. card.id, "계획 데이터가 없습니다.") }
                end
                local planSpec = { revealed = false }
                if planData.durationTurns ~= nil then
                    planSpec.durationTurns = planData.durationTurns
                end
                if planData.charges ~= nil then
                    planSpec.charges = planData.charges
                end
                local beforePlanSlot, slotError = cloneData(
                    working.state[card.owner].planSlot,
                    "$.plan.before"
                )
                if slotError then
                    return false, { slotError }
                end
                local zoneReport, zoneErrors = callModule(
                    "cardZones",
                    "placePlan",
                    working.state,
                    card.owner,
                    instance.instanceId,
                    planSpec
                )
                if zoneErrors then
                    return false, zoneErrors
                end
                working.state = zoneReport.state
                local afterPlanSlot
                afterPlanSlot, slotError = cloneData(
                    working.state[card.owner].planSlot,
                    "$.plan.after"
                )
                if slotError then
                    return false, { slotError }
                end
                appendEvent(
                    "plan_changed",
                    phase,
                    cardSource(card, instance),
                    {
                        action = "placed",
                        instanceId = instance.instanceId,
                        before = beforePlanSlot,
                        after = afterPlanSlot,
                        planSpec = planSpec,
                        movedInstanceIds = zoneReport.movedInstanceIds or {},
                    },
                    resolutionId,
                    card.owner,
                    resolutionCause(resolutionId)
                )
            elseif isRemove then
                local origin = instance.zone
                local zoneReport, zoneErrors = callModule("cardZones", "moveToRemoved", working.state, instance.instanceId)
                if zoneErrors then
                    return false, zoneErrors
                end
                working.state = zoneReport.state
                appendEvent(
                    "card_zone_changed",
                    phase,
                    cardSource(card, instance),
                    {
                        instanceId = instance.instanceId,
                        origin = origin,
                        destination = "removed",
                    },
                    resolutionId,
                    card.owner,
                    resolutionCause(resolutionId)
                )
            end
            return true, nil
        end

        local function resolveCard(instanceId, expectedSide, selectionIndex)
            local phase = expectedSide == "player" and "player_card" or "character_card"
            local instance = findInstance(working.state, instanceId)
            if type(instance) ~= "table" then
                return false, { makeError("instance_not_found", "$.selectedCards", "선택 카드 인스턴스를 찾을 수 없습니다.") }
            end
            if instance.owner ~= expectedSide then
                return false, { makeError("card_owner_mismatch", "$.selectedCards", "선택 카드의 소유자가 해결 진영과 다릅니다.") }
            end
            local card = staticData.cards[instance.cardId]
            if type(card) ~= "table" or card.id ~= instance.cardId then
                return false, { makeError("unknown_card", "$.selectedCards", "정적 카드 정의를 찾을 수 없습니다.") }
            end
            if type(card.base) ~= "table"
                or not isFinite(card.base.stealthCost)
                or not isFinite(card.base.resistanceDamage) then
                return false, { makeError("invalid_card_base", "$.staticData.cards." .. card.id .. ".base", "카드 기본 수치가 올바르지 않습니다.") }
            end

            local modifierReport, modifierErrors = callModule(
                "effectEngine",
                "validateModifiers",
                instance.temporaryModifiers or {}
            )
            if modifierErrors then
                return false, modifierErrors
            end
            local modifiers = modifierReport.modifiers
            local rawCost = card.base.stealthCost
            local rawDamage = card.base.resistanceDamage
            local finalCost = math.max(0, rawCost)
            local finalDamage = math.max(0, rawDamage)
            if expectedSide == "character" and rawCost ~= 0 then
                return false, {
                    makeError(
                        "unsupported_character_cost",
                        "$.staticData.cards." .. card.id .. ".base.stealthCost",
                        "캐릭터 카드의 은폐 비용은 v1에서 0이어야 합니다."
                    ),
                }
            end
            if expectedSide == "character" and rawDamage ~= 0 then
                return false, {
                    makeError(
                        "unsupported_character_base_damage",
                        "$.staticData.cards." .. card.id .. ".base.resistanceDamage",
                        "캐릭터 카드의 base.resistanceDamage 의미는 v1에서 0으로 제한합니다."
                    ),
                }
            end

            local context = buildContext(working.state, phase, card, instance, nil)
            local canPlayReport, canPlayErrors = callModule(
                "effectEngine",
                "evaluateCanPlay",
                staticData,
                card.id,
                context,
                { modifiers = modifiers }
            )
            if canPlayErrors then
                return false, canPlayErrors
            end
            local playable = canPlayReport.playable == true
            local reasonCode = canPlayReport.reasonCode
            if expectedSide == "player" and working.state.player.stealth <= finalCost then
                playable = false
                reasonCode = "insufficient_stealth"
            end
            if not playable then
                if expectedSide == "player" then
                    local restored, restoreErrors = restorePlayerCards(
                        selectionIndex,
                        reasonCode or "card_unavailable",
                        phase,
                        nil
                    )
                    if not restored then
                        return false, restoreErrors
                    end
                else
                    return false, {
                        makeError(
                            "character_card_unavailable_policy_pending",
                            "$.selectedCards.character[" .. selectionIndex .. "]",
                            "캐릭터 의도가 해결 중 사용 불가가 되었을 때의 후속 행동 정책은 아직 확정되지 않았습니다."
                        ),
                    }
                end
                return true, { declared = false, stopped = true }
            end

            local resolutionId = turnId .. "-resolution-" .. string.format("%03d", nextResolutionOrdinal)
            nextResolutionOrdinal = nextResolutionOrdinal + 1

            if expectedSide == "player" then
                if instance.zone ~= "used" then
                    return false, { makeError("invalid_source_zone", "$.selectedCards.player", "projection의 플레이어 선택 카드는 used에 있어야 합니다.") }
                end
                local paid, paymentErrors = applyCost(card, instance, finalCost, phase, resolutionId)
                if not paid then
                    return false, paymentErrors
                end
            else
                if instance.zone ~= "hand" then
                    return false, { makeError("invalid_source_zone", "$.selectedCards.character", "캐릭터 의도 카드는 선언 전 hand에 있어야 합니다.") }
                end
                local zoneReport, zoneErrors = callModule("cardZones", "moveHandToUsed", working.state, instance.instanceId)
                if zoneErrors then
                    return false, zoneErrors
                end
                working.state = zoneReport.state
                instance = findInstance(working.state, instanceId)
            end

            appendEvent(
                "card_declared",
                phase,
                cardSource(card, instance),
                {
                    cardId = card.id,
                    instanceId = instance.instanceId,
                    finalStealthCost = finalCost,
                },
                resolutionId,
                expectedSide,
                resolutionCause(resolutionId)
            )

            local declaredInput = {
                type = "card_declared",
                side = expectedSide,
                cardId = card.id,
                cardInstanceId = instance.instanceId,
                actionTag = card.actionTag,
                resolutionId = resolutionId,
            }
            local preTriggers, preErrors = collectTriggers(declaredInput, phase, card, instance)
            if preErrors then
                return false, preErrors
            end
            local preApplied, preApplyErrors = applyTriggerBatch(
                preTriggers,
                declaredInput,
                phase,
                resolutionId,
                hasMechanism(card, "insight") and expectedSide or nil
            )
            if not preApplied then
                return false, preApplyErrors
            end

            local baseApplied, baseErrors = applyCommands(
                {
                    {
                        op = "damage_resistance",
                        target = "character",
                        amount = finalDamage,
                        cause = "baseDamage",
                    },
                },
                cardSource(card, instance),
                phase,
                resolutionId,
                expectedSide,
                "card_base"
            )
            if not baseApplied then
                return false, baseErrors
            end

            context = buildContext(working.state, phase, card, instance, nil)
            local cardEffect, cardEffectErrors = callModule(
                "effectEngine",
                "evaluateCardResolve",
                staticData,
                card.id,
                context,
                { modifiers = modifiers }
            )
            if cardEffectErrors then
                return false, cardEffectErrors
            end
            local cardCommandsApplied, cardCommandErrors = applyCommands(
                cardEffect.commands,
                cardSource(card, instance),
                phase,
                resolutionId,
                expectedSide,
                "card_effect"
            )
            if not cardCommandsApplied then
                return false, cardCommandErrors
            end

            local currentMood = working.state.character.mood
            context = buildContext(working.state, phase, card, instance, nil)
            local moodEffect, moodEffectErrors = callModule(
                "effectEngine",
                "evaluateMoodEffect",
                staticData,
                card.id,
                currentMood,
                context,
                { modifiers = modifiers }
            )
            if moodEffectErrors then
                return false, moodEffectErrors
            end
            local moodCommandsApplied, moodCommandErrors = applyCommands(
                moodEffect.commands,
                cardSource(card, instance),
                phase,
                resolutionId,
                expectedSide,
                "mood_effect"
            )
            if not moodCommandsApplied then
                return false, moodCommandErrors
            end

            appendEvent(
                "card_resolved",
                phase,
                cardSource(card, instance),
                {
                    cardId = card.id,
                    instanceId = instance.instanceId,
                    finalResistanceDamage = finalDamage,
                },
                resolutionId,
                expectedSide,
                resolutionCause(resolutionId)
            )
            local resolvedInput = {
                type = "card_resolved",
                side = expectedSide,
                cardId = card.id,
                cardInstanceId = instance.instanceId,
                actionTag = card.actionTag,
                resolutionId = resolutionId,
            }
            local postTriggers, postErrors = collectTriggers(resolvedInput, phase, card, instance)
            if postErrors then
                return false, postErrors
            end
            local postApplied, postApplyErrors = applyTriggerBatch(
                postTriggers,
                resolvedInput,
                phase,
                resolutionId,
                nil
            )
            if not postApplied then
                return false, postApplyErrors
            end

            local zoneFinished, zoneFinishErrors = finishCardZone(card, instance, phase, resolutionId)
            if not zoneFinished then
                return false, zoneFinishErrors
            end
            local outcome = latchOutcome("card_checkpoint", phase, resolutionId)
            return true, {
                declared = true,
                stopped = outcome ~= nil,
                resolutionId = resolutionId,
            }
        end

        for index, instanceId in ipairs(playerSelection) do
            if working.transient.halted or working.transient.skipRemaining.player == true then
                local restored, restoreErrors = restorePlayerCards(
                    index,
                    working.transient.halted and "outcome_latched" or "skip_actions",
                    "player_card",
                    nil
                )
                if not restored then
                    return failure(restoreErrors)
                end
                break
            end
            local resolved, resultOrErrors = resolveCard(instanceId, "player", index)
            if not resolved then
                return failure(resultOrErrors)
            end
            if resultOrErrors.stopped then
                if working.transient.halted and index < #playerSelection then
                    local restored, restoreErrors = restorePlayerCards(index + 1, "outcome_latched", "player_card", resultOrErrors.resolutionId)
                    if not restored then
                        return failure(restoreErrors)
                    end
                end
                break
            end
        end

        if working.transient.halted or working.transient.skipRemaining.character == true then
            recordSequenceStopped(
                "character",
                characterSelection,
                1,
                working.transient.halted and "outcome_latched" or "skip_actions",
                "character_card",
                nil
            )
        else
            for index, instanceId in ipairs(characterSelection) do
                if working.transient.halted or working.transient.skipRemaining.character == true then
                    recordSequenceStopped(
                        "character",
                        characterSelection,
                        index,
                        working.transient.halted and "outcome_latched" or "skip_actions",
                        "character_card",
                        nil
                    )
                    break
                end
                local resolved, resultOrErrors = resolveCard(instanceId, "character", index)
                if not resolved then
                    return failure(resultOrErrors)
                end
                if resultOrErrors.stopped then
                    recordSequenceStopped(
                        "character",
                        characterSelection,
                        index + 1,
                        "outcome_latched",
                        "character_card",
                        resultOrErrors.resolutionId
                    )
                    break
                end
            end
        end

        if working.state.status == "active" and resolvedTurnNumber == working.state.turnLimit then
            working.state.status = "defeat"
            working.transient.halted = true
            working.transient.haltReason = "turn_limit"
            appendEvent(
                "outcome_latched",
                "turn_end",
                source("system", "turn_resolver"),
                {
                    status = "defeat",
                    reasonCode = "turn_limit",
                    stealth = working.state.player.stealth,
                    resistance = working.state.character.resistance,
                },
                nil,
                nil,
                { kind = "turn_rule" }
            )
        elseif working.state.status == "active" then
            local turnEndInput = {
                type = "turn_end",
                turnNumber = resolvedTurnNumber,
            }
            local endTriggers, endTriggerErrors = collectTriggers(turnEndInput, "turn_end", nil, nil)
            if endTriggerErrors then
                return failure(endTriggerErrors)
            end
            local endApplied, endApplyErrors = applyTriggerBatch(endTriggers, turnEndInput, "turn_end", nil, nil)
            if not endApplied then
                return failure(endApplyErrors)
            end
            latchOutcome("turn_end_checkpoint", "turn_end", nil)
        end

        local endingStealth = working.state.player.stealth
        local endingResistance = working.state.character.resistance
        local resistancePerformance = startValues.resistance - endingResistance
        local stealthSpent = math.max(0, startValues.stealth - endingStealth)
        local moodPerformance = resistancePerformance - stealthSpent
        local commonMoodApplied = false

        local function moodOrder()
            local order = {}
            local count = 0
            for moodId, mood in pairs(staticData.registry.moods) do
                if type(mood) ~= "table" or mood.id ~= moodId or not isInteger(mood.order, 1) then
                    return nil, makeError("invalid_mood_registry", "$.staticData.registry.moods", "무드 순서가 올바르지 않습니다.")
                end
                if order[mood.order] ~= nil then
                    return nil, makeError("invalid_mood_registry", "$.staticData.registry.moods", "무드 순서가 중복되었습니다.")
                end
                order[mood.order] = moodId
                count = count + 1
            end
            for index = 1, count do
                if order[index] == nil then
                    return nil, makeError("invalid_mood_registry", "$.staticData.registry.moods", "무드 순서가 1부터 이어지지 않습니다.")
                end
            end
            return order, nil
        end

        local order, moodOrderError = moodOrder()
        if moodOrderError then
            return failure({ moodOrderError })
        end
        local currentMoodIndex = nil
        for index, moodId in ipairs(order) do
            if moodId == working.state.character.mood then
                currentMoodIndex = index
                break
            end
        end
        if currentMoodIndex == nil or #order ~= #MOOD_BOUNDARIES + 1 then
            return failure({ makeError("invalid_mood_registry", "$.staticData.registry.moods", "v1 무드 경계 수와 순서가 일치하지 않습니다.") })
        end

        local complianceAdjustment = 0
        for _, traitId in ipairs(working.state.character.traitIds or {}) do
            local trait = staticData.traits[traitId]
            for index, modifier in ipairs(type(trait) == "table" and type(trait.modifiers) == "table" and trait.modifiers or {}) do
                if modifier.timing ~= "moodPerformanceThreshold"
                    or modifier.operation ~= "add"
                    or modifier.direction ~= "compliance"
                    or not isFinite(modifier.amount)
                    or modifier.amount <= 0 then
                    return failure({
                        makeError(
                            "unsupported_trait_modifier",
                            "$.staticData.traits." .. tostring(traitId) .. ".modifiers[" .. index .. "]",
                            "지원하지 않는 특징 보정입니다."
                        ),
                    })
                end
                complianceAdjustment = complianceAdjustment + modifier.amount
            end
        end

        local moodPayload = {
            performance = moodPerformance,
            before = working.state.character.mood,
            after = working.state.character.mood,
            applied = false,
        }
        if working.state.status ~= "active" then
            moodPayload.reasonCode = "battle_ended"
        elseif working.transient.moodLockApplied == true or working.transient.moodLock ~= nil then
            moodPayload.reasonCode = "mood_locked"
        elseif working.transient.directMoodChanged == true then
            moodPayload.reasonCode = "direct_mood_changed"
        else
            local nextIndex = currentMoodIndex
            local direction = nil
            local threshold = nil
            if currentMoodIndex < #order then
                local complianceThreshold = MOOD_BOUNDARIES[currentMoodIndex] + complianceAdjustment
                if moodPerformance >= complianceThreshold then
                    nextIndex = currentMoodIndex + 1
                    direction = "compliance"
                    threshold = complianceThreshold
                end
            end
            if direction == nil and currentMoodIndex > 1 then
                local rejectionThreshold = MOOD_BOUNDARIES[currentMoodIndex - 1]
                if moodPerformance <= -rejectionThreshold then
                    nextIndex = currentMoodIndex - 1
                    direction = "rejection"
                    threshold = rejectionThreshold
                end
            end
            if nextIndex ~= currentMoodIndex then
                working.state.character.mood = order[nextIndex]
                commonMoodApplied = true
                moodPayload.after = working.state.character.mood
                moodPayload.applied = true
                moodPayload.direction = direction
                moodPayload.threshold = threshold
            else
                moodPayload.reasonCode = "threshold_not_met"
            end
        end
        appendEvent(
            "mood_evaluated",
            "turn_end",
            source("system", "mood_performance"),
            moodPayload,
            nil,
            "character",
            { kind = "turn_rule" }
        )

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
                if left.position ~= right.position then
                    return left.position < right.position
                end
                if left.instanceId ~= right.instanceId then
                    return left.instanceId < right.instanceId
                end
                return left.sourceIndex < right.sourceIndex
            end)
            local ids = {}
            for index, entry in ipairs(entries) do
                ids[index] = entry.instanceId
            end
            return ids
        end

        local function cleanupSnapshot(state)
            local playerPlan, playerPlanError = cloneData(state.player.planSlot, "$.cleanup.playerPlan")
            if playerPlanError then
                return nil, playerPlanError
            end
            local characterPlan, characterPlanError = cloneData(
                state.character.planSlot,
                "$.cleanup.characterPlan"
            )
            if characterPlanError then
                return nil, characterPlanError
            end
            return {
                turnNumber = state.turnNumber,
                player = {
                    used = orderedZoneIds(state, "player", "used"),
                    hand = orderedZoneIds(state, "player", "hand"),
                    discard = orderedZoneIds(state, "player", "discard"),
                    planSlot = playerPlan,
                },
                character = {
                    used = orderedZoneIds(state, "character", "used"),
                    hand = orderedZoneIds(state, "character", "hand"),
                    discard = orderedZoneIds(state, "character", "discard"),
                    planSlot = characterPlan,
                },
            }, nil
        end

        local cleanupBefore, cleanupSnapshotError = cleanupSnapshot(working.state)
        if cleanupSnapshotError then
            return failure({ cleanupSnapshotError })
        end
        local cleanupReport, cleanupErrors = callModule("cardZones", "endTurnCleanup", working.state)
        if cleanupErrors then
            return failure(cleanupErrors)
        end
        working.state = cleanupReport.state
        local battleEnded = working.state.status ~= "active"
        if not battleEnded then
            working.state.turnNumber = resolvedTurnNumber + 1
        end
        local cleanupAfter
        cleanupAfter, cleanupSnapshotError = cleanupSnapshot(working.state)
        if cleanupSnapshotError then
            return failure({ cleanupSnapshotError })
        end
        appendEvent(
            "turn_cleanup",
            "cleanup",
            source("system", "card_zones"),
            {
                before = cleanupBefore,
                after = cleanupAfter,
                movedInstanceIds = cleanupReport.movedInstanceIds or {},
                resolvedTurnNumber = resolvedTurnNumber,
            },
            nil,
            nil,
            { kind = "turn_rule" }
        )

        if battleEnded then
            local sessionEndInput = {
                type = "session_end",
                status = working.state.status,
                turnNumber = resolvedTurnNumber,
            }
            local sessionTriggers, sessionErrors = collectTriggers(sessionEndInput, "session_end", nil, nil)
            if sessionErrors then
                return failure(sessionErrors)
            end
            local sessionApplied, sessionApplyErrors = applyTriggerBatch(
                sessionTriggers,
                sessionEndInput,
                "session_end",
                nil,
                nil,
                false
            )
            if not sessionApplied then
                return failure(sessionApplyErrors)
            end
            appendEvent(
                "session_end",
                "session_end",
                source("system", "turn_resolver"),
                { status = working.state.status },
                nil,
                nil,
                { kind = "outcome" }
            )
        end
        working.state.lastCommittedTurnId = turnId

        local stateReport, stateErrors = callModule(
            "stateSchema",
            "validateBattleState",
            working.state,
            staticData
        )
        if stateErrors then
            return failure(stateErrors)
        end
        local conservationReport, conservationErrors = callModule(
            "cardZones",
            "validateConservation",
            authorityState,
            working.state
        )
        if conservationErrors then
            return failure(conservationErrors)
        end

        local sourceAuthority, sourceError = cloneData(validatedProjection.source, "$.projection.source")
        if sourceError then
            return failure({ sourceError })
        end
        local projectedRng, rngCloneError = cloneData(validatedProjection.projectedRng, "$.projection.projectedRng")
        if rngCloneError then
            return failure({ rngCloneError })
        end
        local afterState, afterCloneError = cloneData(stateReport.value or working.state, "$.afterState")
        if afterCloneError then
            return failure({ afterCloneError })
        end

        return success({
            schemaVersion = SCHEMA_VERSION,
            kind = "turnResolution",
            battleId = authorityState.battleId,
            turnId = turnId,
            turnNumber = resolvedTurnNumber,
            source = {
                kind = "turnDraftProjection",
                mode = validatedProjection.mode,
                authority = sourceAuthority,
                projectedRng = projectedRng,
            },
            selectedCards = {
                player = playerSelection,
                character = characterSelection,
            },
            events = events,
            metrics = {
                startingStealth = startValues.stealth,
                endingStealth = endingStealth,
                startingResistance = startValues.resistance,
                endingResistance = endingResistance,
                resistancePerformance = resistancePerformance,
                stealthSpent = stealthSpent,
                moodPerformance = moodPerformance,
                commonMoodApplied = commonMoodApplied,
            },
            afterState = afterState,
        })
    end

    local arguments = { ... }
    if action == "resolveTurn" then
        return resolveTurn(arguments[1], arguments[2], arguments[3], arguments[4])
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 턴 해결 작업입니다: " .. tostring(action)),
    })
end)
