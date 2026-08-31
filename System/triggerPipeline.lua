(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local CATEGORY_ORDER = {
        plan = 1,
        trait = 2,
        perk = 3,
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

    local function success(state, transient, records)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            state = state,
            transient = transient,
            records = records,
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
                    return nil, makeError(
                        "non_finite_number",
                        path,
                        "유한하지 않은 숫자는 트리거 파이프라인 데이터에 복제할 수 없습니다."
                    )
                end
                return value, nil
            end
            return nil, makeError(
                "unsupported_type",
                path,
                "트리거 파이프라인 데이터에 복제할 수 없는 자료형입니다: " .. valueType
            )
        end
        if getmetatable(value) ~= nil then
            return nil, makeError(
                "metatable_not_allowed",
                path,
                "메타테이블이 있는 값은 트리거 파이프라인 데이터에 복제할 수 없습니다."
            )
        end
        active = active or {}
        if active[value] then
            return nil, makeError(
                "circular_reference",
                path,
                "순환 참조는 트리거 파이프라인 데이터에 복제할 수 없습니다."
            )
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

    local function appendErrors(target, nested)
        if type(nested) ~= "table" then
            target[#target + 1] = makeError(
                "invalid_nested_error",
                "$",
                "하위 모듈 오류 목록이 올바르지 않습니다."
            )
            return
        end
        for _, item in ipairs(nested) do
            target[#target + 1] = {
                code = tostring(type(item) == "table" and item.code or "nested_error"),
                path = tostring(type(item) == "table" and item.path or "$"),
                message = tostring(
                    type(item) == "table" and item.message
                        or "하위 모듈 작업이 실패했습니다."
                ),
            }
        end
    end

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError(
                    "runtime_unavailable",
                    "$.runtime." .. moduleName,
                    "스크립트 실행기를 찾을 수 없습니다."
                ),
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
                makeError(
                    "invalid_module_result",
                    "$.runtime." .. moduleName,
                    "하위 모듈이 테이블 결과를 반환하지 않았습니다."
                ),
            }
        end
        if report.ok ~= true then
            local errors = {}
            appendErrors(errors, report.errors)
            return nil, errors
        end
        return report, nil
    end

    local function isSide(value)
        return value == "player" or value == "character"
    end

    local function normalizeOptions(options, inputEvent)
        if options == nil then
            options = {}
        end
        if type(options) ~= "table" or getmetatable(options) ~= nil then
            return nil, {
                makeError("invalid_options", "$.options", "트리거 파이프라인 옵션은 일반 테이블이어야 합니다."),
            }
        end

        local errors = {}
        local allowed = {
            phase = true,
            currentCard = true,
            insightSide = true,
            allowGameplayCommands = true,
        }
        for key in pairs(options) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError(
                    "unexpected_option",
                    "$.options." .. tostring(key),
                    "지원하지 않는 트리거 파이프라인 옵션입니다."
                )
            end
        end

        local phase = options.phase
        if phase == nil and type(inputEvent) == "table" then
            phase = inputEvent.type
        end
        if type(phase) ~= "string" or string.match(phase, "^[a-z][a-z0-9_]*$") == nil then
            errors[#errors + 1] = makeError(
                "invalid_phase",
                "$.options.phase",
                "phase는 lower_snake_case 문자열이어야 합니다."
            )
        end

        if options.insightSide ~= nil and not isSide(options.insightSide) then
            errors[#errors + 1] = makeError(
                "invalid_insight_side",
                "$.options.insightSide",
                "insightSide는 player 또는 character여야 합니다."
            )
        end
        if options.allowGameplayCommands ~= nil and type(options.allowGameplayCommands) ~= "boolean" then
            errors[#errors + 1] = makeError(
                "invalid_allow_gameplay_commands",
                "$.options.allowGameplayCommands",
                "allowGameplayCommands는 불리언이어야 합니다."
            )
        end

        local currentCard = nil
        if options.currentCard ~= nil then
            local value = options.currentCard
            if type(value) ~= "table" or getmetatable(value) ~= nil then
                errors[#errors + 1] = makeError(
                    "invalid_current_card",
                    "$.options.currentCard",
                    "currentCard는 일반 테이블이어야 합니다."
                )
            else
                local cardAllowed = {
                    id = true,
                    instanceId = true,
                    owner = true,
                    roles = true,
                    effectChoiceId = true,
                }
                for key in pairs(value) do
                    if type(key) ~= "string" or not cardAllowed[key] then
                        errors[#errors + 1] = makeError(
                            "unexpected_current_card_field",
                            "$.options.currentCard." .. tostring(key),
                            "currentCard에 허용되지 않은 필드가 있습니다."
                        )
                    end
                end
                if type(value.id) ~= "string" or value.id == "" then
                    errors[#errors + 1] = makeError(
                        "invalid_current_card_id",
                        "$.options.currentCard.id",
                        "현재 카드 ID가 없습니다."
                    )
                end
                if type(value.instanceId) ~= "string" or value.instanceId == "" then
                    errors[#errors + 1] = makeError(
                        "invalid_current_instance_id",
                        "$.options.currentCard.instanceId",
                        "현재 카드 인스턴스 ID가 없습니다."
                    )
                end
                if not isSide(value.owner) then
                    errors[#errors + 1] = makeError(
                        "invalid_current_card_owner",
                        "$.options.currentCard.owner",
                        "현재 카드 소유자는 player 또는 character여야 합니다."
                    )
                end
                if not isDenseArray(value.roles) or #value.roles < 1 then
                    errors[#errors + 1] = makeError(
                        "invalid_current_roles",
                        "$.options.currentCard.roles",
                        "현재 카드 역할이 올바르지 않습니다."
                    )
                end
                if value.effectChoiceId ~= nil
                    and (type(value.effectChoiceId) ~= "string"
                        or string.match(value.effectChoiceId, "^[a-z][a-z0-9_]*$") == nil) then
                    errors[#errors + 1] = makeError("invalid_effect_choice_id", "$.options.currentCard.effectChoiceId", "현재 카드 효과 선택값이 올바르지 않습니다.")
                end
                currentCard = {
                    id = value.id,
                    instanceId = value.instanceId,
                    owner = value.owner,
                    roles = value.roles,
                    effectChoiceId = value.effectChoiceId,
                }
            end
        end

        if #errors > 0 then
            return nil, errors
        end
        return {
            phase = phase,
            currentCard = currentCard,
            insightSide = options.insightSide,
            allowGameplayCommands = options.allowGameplayCommands ~= false,
        }, nil
    end

    local function validateInputs(staticData, working, inputEvent)
        local errors = {}
        staticData = normalizeStaticData(staticData)
        if type(staticData) ~= "table"
            or getmetatable(staticData) ~= nil
            or type(staticData.registry) ~= "table"
            or type(staticData.registry.events) ~= "table"
            or type(staticData.cards) ~= "table"
            or type(staticData.traits) ~= "table" then
            errors[#errors + 1] = makeError(
                "invalid_static_data",
                "$.staticData",
                "트리거 파이프라인에는 전체 정적 데이터가 필요합니다."
            )
        end

        if type(working) ~= "table" or getmetatable(working) ~= nil then
            errors[#errors + 1] = makeError(
                "invalid_working",
                "$.working",
                "트리거 파이프라인 working 값은 일반 테이블이어야 합니다."
            )
        elseif type(working.state) ~= "table"
            or getmetatable(working.state) ~= nil
            or type(working.state.player) ~= "table"
            or type(working.state.character) ~= "table"
            or type(working.state.cardInstances) ~= "table" then
            errors[#errors + 1] = makeError(
                "invalid_working_state",
                "$.working.state",
                "트리거를 적용할 전투 상태가 올바르지 않습니다."
            )
        elseif working.transient ~= nil
            and (type(working.transient) ~= "table" or getmetatable(working.transient) ~= nil) then
            errors[#errors + 1] = makeError(
                "invalid_transient",
                "$.working.transient",
                "트리거 transient 값은 일반 테이블이어야 합니다."
            )
        end

        if type(inputEvent) ~= "table" or getmetatable(inputEvent) ~= nil then
            errors[#errors + 1] = makeError(
                "invalid_trigger_event",
                "$.inputEvent",
                "트리거 입력 사건은 일반 테이블이어야 합니다."
            )
        elseif type(staticData) == "table" and type(staticData.registry) == "table"
            and type(staticData.registry.events) == "table" then
            if type(inputEvent.type) ~= "string" or not staticData.registry.events[inputEvent.type] then
                errors[#errors + 1] = makeError(
                    "unknown_trigger_event",
                    "$.inputEvent.type",
                    "등록되지 않은 트리거 입력 사건입니다."
                )
            end
            if inputEvent.side ~= nil and not isSide(inputEvent.side) then
                errors[#errors + 1] = makeError(
                    "invalid_event_side",
                    "$.inputEvent.side",
                    "입력 사건 진영은 player 또는 character여야 합니다."
                )
            end
        end

        if #errors > 0 then
            return nil, errors
        end
        return staticData, nil
    end

    local function countZone(state, owner, zone)
        local count = 0
        for _, instance in ipairs(state.cardInstances) do
            if type(instance) == "table" and instance.owner == owner and instance.zone == zone then
                count = count + 1
            end
        end
        return count
    end

    local function buildHistoryContext(history)
        if type(runScript) ~= "function" then
            error("battleHistory.context runtime is unavailable", 0)
        end
        local ok, report = pcall(runScript, triggerId, "battleHistory", "context", history)
        if not ok or type(report) ~= "table" or report.ok ~= true or type(report.context) ~= "table" then
            error("battleHistory.context failed", 0)
        end
        return report.context
    end

    local function buildContext(state, options, planState)
        local intent = type(state.characterIntent) == "table" and state.characterIntent or {}
        local context = {
            turn = state.turnNumber,
            turnLimit = state.turnLimit,
            remainingTurns = math.max(0, state.turnLimit - state.turnNumber + 1),
            phase = options.phase,
            mood = state.character.mood,
            history = buildHistoryContext(state.history),
            player = {
                stealth = state.player.stealth,
                handCount = countZone(state, "player", "hand"),
                planCount = #(state.player.planSlots or {}),
            },
            character = {
                resistance = state.character.resistance,
                moodTokens = state.character.moodTokens,
                publicRole = intent.publicRole,
                planCount = #(state.character.planSlots or {}),
            },
        }
        if options.currentCard ~= nil then
            context.card = {
                id = options.currentCard.id,
                instanceId = options.currentCard.instanceId,
                owner = options.currentCard.owner,
                roles = options.currentCard.roles,
            }
            if options.currentCard.effectChoiceId ~= nil then
                context.effectChoiceId = options.currentCard.effectChoiceId
            end
        end
        if planState ~= nil then
            context.plan = {
                cardId = planState.cardId,
                cardInstanceId = planState.cardInstanceId,
                side = planState.side,
                revealed = planState.revealed,
                slotIndex = planState.slotIndex,
            }
            if planState.remainingTurns ~= nil then
                context.plan.remainingTurns = planState.remainingTurns
            end
            if planState.remainingCharges ~= nil then
                context.plan.remainingCharges = planState.remainingCharges
            end
            if planState.effectChoiceId ~= nil then context.effectChoiceId = planState.effectChoiceId end
        end
        return context
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

    local function candidateSource(candidate)
        local value = {
            kind = candidate.kind,
            id = candidate.sourceId,
        }
        if candidate.side ~= nil then
            value.side = candidate.side
        end
        if candidate.planState ~= nil then
            value.instanceId = candidate.planState.cardInstanceId
        end
        return value
    end

    local function appendRecord(records, recordType, candidate, payload)
        local record = {
            type = recordType,
            source = candidateSource(candidate),
        }
        if candidate.side ~= nil then
            record.side = candidate.side
        end
        if payload ~= nil then
            record.payload = payload
        end
        records[#records + 1] = record
    end

    local function collectCandidates(staticData, snapshot, inputEvent, options)
        local candidates = {}
        local nextOrdinal = 1

        local function addCandidate(kind, sourceId, ownerSide, declarationIndex, spec, planState, path)
            if type(sourceId) ~= "string" or sourceId == "" then
                return false, {
                    makeError("invalid_trigger_source", path, "트리거 source ID가 올바르지 않습니다."),
                }
            end
            if ownerSide ~= nil and not isSide(ownerSide) then
                return false, {
                    makeError("invalid_trigger_owner", path, "트리거 소유 진영이 올바르지 않습니다."),
                }
            end
            if type(spec) ~= "table" or getmetatable(spec) ~= nil or type(spec.resolve) ~= "function" then
                return false, {
                    makeError("invalid_trigger", path, "트리거 정의가 올바르지 않습니다: " .. sourceId),
                }
            end
            candidates[#candidates + 1] = {
                kind = kind,
                categoryOrder = CATEGORY_ORDER[kind],
                sourceId = sourceId,
                side = ownerSide,
                declarationIndex = declarationIndex or 1,
                ordinal = nextOrdinal,
                spec = spec,
                planState = planState,
                path = path,
            }
            nextOrdinal = nextOrdinal + 1
            return true, nil
        end

        for _, planSide in ipairs({ "player", "character" }) do
            local ownerState = snapshot[planSide]
            local slots = type(ownerState) == "table" and ownerState.planSlots or nil
            if not isDenseArray(slots) then
                return nil, {
                    makeError(
                        "invalid_plan_slots",
                        "$.working.state." .. planSide .. ".planSlots",
                        "계획 슬롯 목록이 올바르지 않습니다."
                    ),
                }
            end
            for slotIndex, slot in ipairs(slots) do
                if type(slot) ~= "table" or slot.occupied ~= true then
                    return nil, {
                        makeError(
                            "invalid_plan_slot",
                            "$.working.state." .. planSide .. ".planSlots[" .. slotIndex .. "]",
                            "점유 계획 슬롯이 올바르지 않습니다."
                        ),
                    }
                end
                local card = staticData.cards[slot.cardId]
                local planData = type(card) == "table"
                    and type(card.mechanismData) == "table"
                    and card.mechanismData.plan
                    or nil
                local path = "$.staticData.cards." .. tostring(slot.cardId) .. ".mechanismData.plan"
                if type(planData) ~= "table" then
                    return nil, {
                        makeError("missing_plan_definition", path, "계획 정의를 찾을 수 없습니다."),
                    }
                end
                local planState = {
                    side = planSide,
                    cardId = slot.cardId,
                    cardInstanceId = slot.cardInstanceId,
                    revealed = slot.revealed == true,
                    slotIndex = slotIndex,
                }
                if slot.remainingTurns ~= nil then
                    planState.remainingTurns = slot.remainingTurns
                end
                if slot.remainingCharges ~= nil then
                    planState.remainingCharges = slot.remainingCharges
                end
                if slot.effectChoiceId ~= nil then
                    planState.effectChoiceId = slot.effectChoiceId
                end
                local added, addErrors = addCandidate(
                    "plan",
                    slot.cardId,
                    planSide,
                    slotIndex,
                    planData,
                    planState,
                    path
                )
                if not added then
                    return nil, addErrors
                end
            end
        end

        local traitIds = snapshot.character.traitIds or {}
        if not isDenseArray(traitIds) then
            return nil, {
                makeError("invalid_trait_ids", "$.working.state.character.traitIds", "특징 ID 목록이 배열이 아닙니다."),
            }
        end
        for _, traitId in ipairs(traitIds) do
            local trait = staticData.traits[traitId]
            if type(trait) ~= "table" then
                return nil, {
                    makeError("unknown_trait", "$.working.state.character.traitIds", "특징을 찾을 수 없습니다: " .. tostring(traitId)),
                }
            end
            if trait.triggers ~= nil then
                local path = "$.staticData.traits." .. tostring(traitId) .. ".triggers"
                if not isDenseArray(trait.triggers) then
                    return nil, {
                        makeError("invalid_triggers", path, "특징 트리거가 배열이 아닙니다."),
                    }
                end
                for index, spec in ipairs(trait.triggers) do
                    local added, addErrors = addCandidate(
                        "trait",
                        traitId,
                        trait.owner,
                        index,
                        spec,
                        nil,
                        path .. "[" .. index .. "]"
                    )
                    if not added then
                        return nil, addErrors
                    end
                end
            end
        end

        local perkIds = snapshot.player.perkIds or {}
        if not isDenseArray(perkIds) then
            return nil, {
                makeError("invalid_perk_ids", "$.working.state.player.perkIds", "퍽 ID 목록이 배열이 아닙니다."),
            }
        end
        for _, perkId in ipairs(perkIds) do
            local perk = type(staticData.perks) == "table" and staticData.perks[perkId] or nil
            if type(perk) ~= "table" then
                return nil, {
                    makeError("unknown_perk", "$.working.state.player.perkIds", "퍽을 찾을 수 없습니다: " .. tostring(perkId)),
                }
            end
            if perk.triggers ~= nil then
                local path = "$.staticData.perks." .. tostring(perkId) .. ".triggers"
                if not isDenseArray(perk.triggers) then
                    return nil, {
                        makeError("invalid_triggers", path, "퍽 트리거가 배열이 아닙니다."),
                    }
                end
                for index, spec in ipairs(perk.triggers) do
                    local added, addErrors = addCandidate(
                        "perk",
                        perkId,
                        perk.owner or "player",
                        index,
                        spec,
                        nil,
                        path .. "[" .. index .. "]"
                    )
                    if not added then
                        return nil, addErrors
                    end
                end
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
            if left.declarationIndex ~= right.declarationIndex then
                return left.declarationIndex < right.declarationIndex
            end
            return left.ordinal < right.ordinal
        end)

        local matched = {}
        for _, candidate in ipairs(candidates) do
            local context = buildContext(snapshot, options, candidate.planState)
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

    local function runPipeline(staticData, working, inputEvent, options)
        local normalizedStaticData, inputErrors = validateInputs(staticData, working, inputEvent)
        if inputErrors then
            return failure(inputErrors)
        end
        local normalizedOptions, optionErrors = normalizeOptions(options, inputEvent)
        if optionErrors then
            return failure(optionErrors)
        end

        local state, cloneError = cloneData(working.state, "$.working.state")
        if cloneError then
            return failure({ cloneError })
        end
        local transient
        transient, cloneError = cloneData(working.transient or {}, "$.working.transient")
        if cloneError then
            return failure({ cloneError })
        end
        local eventSnapshot
        eventSnapshot, cloneError = cloneData(inputEvent, "$.inputEvent")
        if cloneError then
            return failure({ cloneError })
        end
        local stateSnapshot
        stateSnapshot, cloneError = cloneData(state, "$.triggerSnapshot")
        if cloneError then
            return failure({ cloneError })
        end

        local candidates, candidateErrors = collectCandidates(
            normalizedStaticData,
            stateSnapshot,
            eventSnapshot,
            normalizedOptions
        )
        if candidateErrors then
            return failure(candidateErrors)
        end

        local records = {}
        for _, candidate in ipairs(candidates) do
            local suppressed = normalizedOptions.insightSide ~= nil
                and candidate.kind == "plan"
                and candidate.side ~= normalizedOptions.insightSide
            if suppressed then
                appendRecord(records, "trigger_suppressed", candidate, {
                    inputEventType = eventSnapshot.type,
                    reasonCode = "insight",
                    hidden = candidate.planState.revealed ~= true,
                })
            else
                local resolveReport, resolveErrors = callModule(
                    "effectEngine",
                    "evaluateTriggerResolve",
                    normalizedStaticData,
                    candidate.spec,
                    candidate.context,
                    eventSnapshot
                )
                if resolveErrors then
                    return failure(resolveErrors)
                end
                if not normalizedOptions.allowGameplayCommands and #resolveReport.commands > 0 then
                    return failure({
                        makeError(
                            "unsupported_session_end_commands",
                            candidate.path,
                            "게임플레이 명령이 금지된 트리거 batch에서 명령을 반환했습니다."
                        ),
                    })
                end

                local beforePlanSlots = nil
                if candidate.kind == "plan" then
                    beforePlanSlots, cloneError = cloneData(
                        state[candidate.side].planSlots,
                        "$.plan.before"
                    )
                    if cloneError then
                        return failure({ cloneError })
                    end
                end

                if #resolveReport.commands > 0 then
                    local applyReport, applyErrors = callModule(
                        "effectEngine",
                        "applyCommands",
                        normalizedStaticData,
                        { state = state, transient = transient },
                        resolveReport.commands
                    )
                    if applyErrors then
                        return failure(applyErrors)
                    end
                    state = applyReport.state
                    transient = applyReport.transient
                    for _, applied in ipairs(applyReport.applied or {}) do
                        local payload
                        payload, cloneError = cloneData(applied, "$.records.effect_applied.payload")
                        if cloneError then
                            return failure({ cloneError })
                        end
                        appendRecord(records, "effect_applied", candidate, payload)
                    end
                end

                if candidate.kind == "plan" then
                    local zoneReport, zoneErrors = callModule(
                        "cardZones",
                        "consumePlanCharge",
                        state,
                        candidate.side,
                        candidate.planState.cardInstanceId
                    )
                    if zoneErrors then
                        return failure(zoneErrors)
                    end
                    state = zoneReport.state
                    local afterPlanSlots
                    afterPlanSlots, cloneError = cloneData(
                        state[candidate.side].planSlots,
                        "$.plan.after"
                    )
                    if cloneError then
                        return failure({ cloneError })
                    end
                    local movedInstanceIds
                    movedInstanceIds, cloneError = cloneData(
                        zoneReport.movedInstanceIds or {},
                        "$.plan.movedInstanceIds"
                    )
                    if cloneError then
                        return failure({ cloneError })
                    end
                    appendRecord(records, "plan_changed", candidate, {
                        action = "triggered",
                        before = beforePlanSlots,
                        after = afterPlanSlots,
                        discarded = #movedInstanceIds > 0,
                        movedInstanceIds = movedInstanceIds,
                    })
                end

                appendRecord(records, "trigger_resolved", candidate, {
                    inputEventType = eventSnapshot.type,
                    commandCount = #resolveReport.commands,
                })
            end
        end

        return success(state, transient, records)
    end

    local arguments = { ... }
    local actions = {
        run = runPipeline,
    }
    local handler = actions[action]
    if not handler then
        return failure({
            makeError(
                "unknown_action",
                "$.action",
                "지원하지 않는 트리거 파이프라인 작업입니다: " .. tostring(action)
            ),
        })
    end
    return handler(arguments[1], arguments[2], arguments[3], arguments[4])
end)
