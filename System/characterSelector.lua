(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991

    local SCORE_OPERATIONS = {
        recover_resistance = { scoreDirection = 1, stealthDirection = 0 },
        lose_stealth = { scoreDirection = 1, stealthDirection = -1 },
        damage_resistance = { scoreDirection = -1, stealthDirection = 0 },
        recover_stealth = { scoreDirection = -1, stealthDirection = 1 },
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

    local function success(state, intent, receipt)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            state = state,
            intent = intent,
            receipt = receipt,
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
            if key > maximum then
                maximum = key
            end
        end
        return count == maximum
    end

    local function cloneData(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "NaN과 무한대는 선택 상태에 사용할 수 없습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError("unsupported_type", path, "JSON 선택 상태에 저장할 수 없는 자료형입니다: " .. valueType)
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "선택 상태에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조가 있는 선택 상태는 복제할 수 없습니다.")
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

    local function deepEqual(left, right, seen)
        if type(left) ~= type(right) then
            return false
        end
        if type(left) ~= "table" then
            return left == right
        end
        seen = seen or {}
        if seen[left] == right then
            return true
        end
        seen[left] = right
        for key, value in pairs(left) do
            if not deepEqual(value, right[key], seen) then
                return false
            end
        end
        for key in pairs(right) do
            if left[key] == nil then
                return false
            end
        end
        return true
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

    local function hasMechanism(card, mechanismId)
        for _, currentId in ipairs(type(card) == "table" and type(card.mechanisms) == "table" and card.mechanisms or {}) do
            if currentId == mechanismId then
                return true
            end
        end
        return false
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

    local function orderedCharacterHand(state)
        local hand = {}
        for sourceIndex, instance in ipairs(type(state) == "table" and type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if instance.owner == "character" and instance.zone == "hand" then
                hand[#hand + 1] = {
                    instance = instance,
                    sourceIndex = sourceIndex,
                }
            end
        end
        table.sort(hand, function(left, right)
            if left.instance.position ~= right.instance.position then
                return left.instance.position < right.instance.position
            end
            if left.instance.instanceId ~= right.instance.instanceId then
                return left.instance.instanceId < right.instance.instanceId
            end
            return left.sourceIndex < right.sourceIndex
        end)
        return hand
    end

    local function buildSelectionContext(state, staticData, hand)
        local characterHand = {}
        for index, entry in ipairs(hand) do
            local instance = entry.instance
            local card = type(staticData) == "table" and type(staticData.cards) == "table" and staticData.cards[instance.cardId] or nil
            characterHand[index] = {
                instanceId = instance.instanceId,
                cardId = instance.cardId,
                actionTag = type(card) == "table" and card.actionTag or nil,
                handPosition = instance.position,
            }
        end
        return {
            turnNumber = state.turnNumber,
            player = {
                stealth = state.player.stealth,
                handCount = countZone(state, "player", "hand"),
            },
            character = {
                resistance = state.character.resistance,
                mood = state.character.mood,
            },
            characterHand = characterHand,
        }
    end

    local function buildContext(state, card, instance, plan)
        local context = {
            turn = state.turnNumber,
            phase = "character_selection",
            mood = state.character.mood,
            player = {
                stealth = state.player.stealth,
                handCount = countZone(state, "player", "hand"),
            },
            character = {
                resistance = state.character.resistance,
                publicActionTag = nil,
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
                revealed = false,
                remainingCharges = plan.remainingCharges,
            }
            if plan.remainingTurns ~= nil then
                context.plan.remainingTurns = plan.remainingTurns
            end
        end
        return context
    end

    local function emptyTotals()
        return {
            recoverResistance = 0,
            loseStealth = 0,
            damageResistance = 0,
            recoverStealth = 0,
        }
    end

    local TOTAL_FIELD = {
        recover_resistance = "recoverResistance",
        lose_stealth = "loseStealth",
        damage_resistance = "damageResistance",
        recover_stealth = "recoverStealth",
    }

    local function scoreCommands(commands, totals, path)
        if not isDenseArray(commands) then
            return nil, makeError("invalid_scoring_commands", path, "점수화할 효과 명령이 연속 배열이 아닙니다.")
        end
        local scoreDelta = 0
        local stealthDelta = 0
        for index, command in ipairs(commands) do
            local commandPath = path .. "[" .. index .. "]"
            local operation = type(command) == "table" and SCORE_OPERATIONS[command.op] or nil
            if not operation then
                return nil, makeError(
                    "unsupported_character_score_op",
                    commandPath .. ".op",
                    "캐릭터 선택 점수로 해석할 수 없는 효과 작업입니다: " .. tostring(type(command) == "table" and command.op or nil)
                )
            end
            if not isFinite(command.amount) or command.amount < 0 then
                return nil, makeError("invalid_character_score_amount", commandPath .. ".amount", "선택 점수 효과 수치가 올바르지 않습니다.")
            end
            local field = TOTAL_FIELD[command.op]
            totals[field] = totals[field] + command.amount
            scoreDelta = scoreDelta + operation.scoreDirection * command.amount
            stealthDelta = stealthDelta + operation.stealthDirection * command.amount
            if not isFinite(totals[field]) or not isFinite(scoreDelta) or not isFinite(stealthDelta) then
                return nil, makeError("non_finite_character_score", commandPath, "캐릭터 선택 점수가 유한한 범위를 벗어났습니다.")
            end
        end
        return {
            scoreDelta = scoreDelta,
            stealthDelta = stealthDelta,
        }, nil
    end

    local function scoreCandidate(state, staticData, card, instance)
        if card.canPlay ~= nil then
            return nil, {
                makeError(
                    "unsupported_character_can_play_selection",
                    "$.staticData.cards." .. card.id .. ".canPlay",
                    "캐릭터 canPlay 카드의 사전 선택 정책은 아직 확정되지 않았습니다."
                ),
            }
        end
        if card.base.stealthCost ~= 0 or card.base.resistanceDamage ~= 0 then
            return nil, {
                makeError(
                    "unsupported_character_base_values",
                    "$.staticData.cards." .. card.id .. ".base",
                    "캐릭터 카드의 기본 비용과 기본 저항 피해는 선택 점수 버전 1에서 0이어야 합니다."
                ),
            }
        end

        local totals = emptyTotals()
        local score = 0
        local stealthDelta = 0
        local context = buildContext(state, card, instance, nil)
        local cardReport, cardErrors = callModule(
            "effectEngine",
            "evaluateCardResolve",
            staticData,
            card.id,
            context
        )
        if cardErrors then
            return nil, cardErrors
        end
        local cardScore, cardScoreError = scoreCommands(
            cardReport.commands,
            totals,
            "$.staticData.cards." .. card.id .. ".resolve.commands"
        )
        if cardScoreError then
            return nil, { cardScoreError }
        end
        score = score + cardScore.scoreDelta
        stealthDelta = stealthDelta + cardScore.stealthDelta

        local moodReport, moodErrors = callModule(
            "effectEngine",
            "evaluateMoodEffect",
            staticData,
            card.id,
            state.character.mood,
            context
        )
        if moodErrors then
            return nil, moodErrors
        end
        local moodScore, moodScoreError = scoreCommands(
            moodReport.commands,
            totals,
            "$.staticData.cards." .. card.id .. ".moodEffects." .. state.character.mood .. ".commands"
        )
        if moodScoreError then
            return nil, { moodScoreError }
        end
        score = score + moodScore.scoreDelta
        stealthDelta = stealthDelta + moodScore.stealthDelta

        local planChargesEvaluated = 0
        if hasMechanism(card, "plan") then
            local plan = type(card.mechanismData) == "table" and card.mechanismData.plan or nil
            local assumption = type(plan) == "table" and plan.selectionAssumption or nil
            local event = type(assumption) == "table" and assumption.event or nil
            if type(plan) ~= "table"
                or not isInteger(plan.charges, 1)
                or type(assumption) ~= "table"
                or assumption.chargePolicy ~= "all"
                or type(event) ~= "table"
                or type(event.type) ~= "string"
                or (event.side ~= "player" and event.side ~= "character") then
                return nil, {
                    makeError(
                        "invalid_plan_selection_assumption",
                        "$.staticData.cards." .. card.id .. ".mechanismData.plan.selectionAssumption",
                        "캐릭터 계획 선택 가정이 정적 데이터 계약과 맞지 않습니다."
                    ),
                }
            end

            for chargeIndex = 1, plan.charges do
                local remainingCharges = plan.charges - chargeIndex + 1
                local planContext = buildContext(state, nil, nil, {
                    cardId = card.id,
                    cardInstanceId = instance.instanceId,
                    side = "character",
                    remainingTurns = plan.durationTurns,
                    remainingCharges = remainingCharges,
                })
                local triggerReport, triggerErrors = callModule(
                    "effectEngine",
                    "evaluateTrigger",
                    staticData,
                    plan,
                    planContext,
                    event
                )
                if triggerErrors then
                    return nil, triggerErrors
                end
                if triggerReport.matched ~= true then
                    return nil, {
                        makeError(
                            "plan_selection_assumption_not_matched",
                            "$.staticData.cards." .. card.id .. ".mechanismData.plan.selectionAssumption.event",
                            "명시한 계획 선택 가정이 계획 발동 조건과 일치하지 않습니다."
                        ),
                    }
                end
                local planScore, planScoreError = scoreCommands(
                    triggerReport.commands,
                    totals,
                    "$.staticData.cards." .. card.id .. ".mechanismData.plan.resolve.commands[charge=" .. chargeIndex .. "]"
                )
                if planScoreError then
                    return nil, { planScoreError }
                end
                score = score + planScore.scoreDelta
                stealthDelta = stealthDelta + planScore.stealthDelta
                planChargesEvaluated = planChargesEvaluated + 1
            end
        end

        local projectedStealth = state.player.stealth + stealthDelta
        if not isFinite(score) or not isFinite(projectedStealth) then
            return nil, {
                makeError("non_finite_character_score", "$.staticData.cards." .. card.id, "캐릭터 선택 점수가 유한한 범위를 벗어났습니다."),
            }
        end
        if not isSafeInteger(score) then
            return nil, {
                makeError(
                    "non_integer_character_score",
                    "$.staticData.cards." .. card.id,
                    "캐릭터 선택 점수는 결정적 가중 추첨에 사용할 수 있는 안전한 정수여야 합니다."
                ),
            }
        end
        return {
            instanceId = instance.instanceId,
            cardId = card.id,
            actionTag = card.actionTag,
            handPosition = instance.position,
            score = score,
            projectedPlayerStealth = projectedStealth,
            lethal = projectedStealth <= 0,
            weight = 0,
            totals = totals,
            planChargesEvaluated = planChargesEvaluated,
        }, nil
    end

    -- This validation action intentionally does not call stateSchema or selectIntent.
    -- stateSchema may invoke it for a persisted receipt without creating a runtime cycle.
    local function validateReceipt(staticInput, receipt, expectedState)
        local staticData = normalizeStaticData(staticInput)
        if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then
            return failure({
                makeError("invalid_character_selection_receipt", "$.receipt", "캐릭터 선택 영수증이 일반 테이블이 아닙니다."),
            })
        end
        local context = receipt.selectionContext
        if type(context) ~= "table" or getmetatable(context) ~= nil then
            return failure({
                makeError("invalid_selection_context", "$.receipt.selectionContext", "선택 시점 컨텍스트가 일반 테이블이 아닙니다."),
            })
        end

        if expectedState ~= nil then
            if type(expectedState) ~= "table" or getmetatable(expectedState) ~= nil then
                return failure({
                    makeError("invalid_selection_context_state", "$.expectedState", "선택 직전 상태가 일반 테이블이 아닙니다."),
                })
            end
            local expectedContext = buildSelectionContext(
                expectedState,
                staticData,
                orderedCharacterHand(expectedState)
            )
            if not deepEqual(context, expectedContext) then
                return failure({
                    makeError(
                        "selection_context_state_mismatch",
                        "$.receipt.selectionContext",
                        "선택 영수증 컨텍스트가 실제 선택 직전 상태와 일치하지 않습니다."
                    ),
                })
            end
        end

        if not isInteger(context.turnNumber, 1)
            or type(context.player) ~= "table"
            or not isFinite(context.player.stealth)
            or not isInteger(context.player.handCount, 0)
            or type(context.character) ~= "table"
            or not isFinite(context.character.resistance)
            or type(context.character.mood) ~= "string"
            or context.character.mood == ""
            or not isDenseArray(context.characterHand)
            or not isDenseArray(receipt.candidates) then
            return failure({
                makeError("invalid_selection_context", "$.receipt.selectionContext", "선택 시점 컨텍스트 필드가 올바르지 않습니다."),
            })
        end
        if #context.characterHand ~= #receipt.candidates then
            return failure({
                makeError("selection_candidate_count_mismatch", "$.receipt.candidates", "선택 시점 손패와 후보 수가 다릅니다."),
            })
        end

        local syntheticState = {
            turnNumber = context.turnNumber,
            player = {
                stealth = context.player.stealth,
            },
            character = {
                resistance = context.character.resistance,
                mood = context.character.mood,
            },
            cardInstances = {},
        }
        for index = 1, context.player.handCount do
            syntheticState.cardInstances[index] = {
                owner = "player",
                zone = "hand",
            }
        end

        for index, handEntry in ipairs(context.characterHand) do
            local path = "$.receipt.candidates[" .. index .. "]"
            local candidate = receipt.candidates[index]
            if type(handEntry) ~= "table"
                or type(candidate) ~= "table"
                or type(handEntry.instanceId) ~= "string"
                or type(handEntry.cardId) ~= "string"
                or type(handEntry.actionTag) ~= "string"
                or not isInteger(handEntry.handPosition, 1) then
                return failure({
                    makeError("invalid_selection_hand_entry", "$.receipt.selectionContext.characterHand[" .. index .. "]", "선택 시점 손패 항목이 올바르지 않습니다."),
                })
            end
            local card = type(staticData) == "table"
                and type(staticData.cards) == "table"
                and staticData.cards[handEntry.cardId]
                or nil
            if type(card) ~= "table"
                or card.owner ~= "character"
                or card.actionTag ~= handEntry.actionTag then
                return failure({
                    makeError("selection_hand_static_mismatch", "$.receipt.selectionContext.characterHand[" .. index .. "]", "선택 시점 손패가 정적 캐릭터 카드와 일치하지 않습니다."),
                })
            end
            local instance = {
                instanceId = handEntry.instanceId,
                cardId = handEntry.cardId,
                owner = "character",
                zone = "hand",
                position = handEntry.handPosition,
            }
            local expected, replayErrors = scoreCandidate(syntheticState, staticData, card, instance)
            if replayErrors then
                return failure(replayErrors)
            end
            if candidate.instanceId ~= expected.instanceId
                or candidate.cardId ~= expected.cardId
                or candidate.actionTag ~= expected.actionTag
                or candidate.handPosition ~= expected.handPosition
                or candidate.score ~= expected.score
                or candidate.projectedPlayerStealth ~= expected.projectedPlayerStealth
                or candidate.lethal ~= expected.lethal
                or candidate.planChargesEvaluated ~= expected.planChargesEvaluated
                or not deepEqual(candidate.totals, expected.totals) then
                return failure({
                    makeError(
                        "selection_candidate_replay_mismatch",
                        path,
                        "후보 감사 값이 정적 카드 효과의 선택 시점 재평가 결과와 다릅니다."
                    ),
                })
            end
        end

        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            valid = true,
        }
    end

    local function selectIntent(state, staticInput)
        local staticData = normalizeStaticData(staticInput)
        local validation, validationErrors = callModule("stateSchema", "validateBattleState", state, staticData)
        if validationErrors then
            return failure(validationErrors)
        end
        if validation.referencesValidated ~= true then
            return failure({
                makeError("static_references_not_validated", "$.staticData", "캐릭터 선택에는 전체 정적 데이터 참조 검증이 필요합니다."),
            })
        end
        if state.status ~= "active" then
            return failure({ makeError("battle_not_active", "$.state.status", "진행 중인 전투에서만 캐릭터 의도를 선택할 수 있습니다.") })
        end
        if type(state.characterIntent) ~= "table"
            or type(state.characterIntent.cardInstanceIds) ~= "table"
            or #state.characterIntent.cardInstanceIds > 0
            or state.characterIntent.publicActionTag ~= nil then
            return failure({
                makeError("character_intent_already_selected", "$.state.characterIntent", "이미 캐릭터 의도가 있는 상태를 다시 선택할 수 없습니다."),
            })
        end

        local hand = orderedCharacterHand(state)

        local candidates = {}
        for _, entry in ipairs(hand) do
            local instance = entry.instance
            local card = staticData.cards[instance.cardId]
            if type(card) ~= "table" or card.owner ~= "character" then
                return failure({
                    makeError("invalid_character_hand_card", "$.state.cardInstances", "캐릭터 손패의 카드 정의가 올바르지 않습니다: " .. tostring(instance.cardId)),
                })
            end
            if hasMechanism(card, "chain") then
                return failure({
                    makeError(
                        "unsupported_character_chain_selection",
                        "$.staticData.cards." .. card.id .. ".mechanisms",
                        "캐릭터 연계 카드 선택 순서와 장수 정책은 아직 지원하지 않습니다."
                    ),
                })
            end
            local candidate, candidateErrors = scoreCandidate(state, staticData, card, instance)
            if candidateErrors then
                return failure(candidateErrors)
            end
            candidates[#candidates + 1] = candidate
        end

        local rngBefore, rngBeforeError = cloneData(state.rng, "$.state.rng")
        if rngBeforeError then
            return failure({ rngBeforeError })
        end
        local nextState, stateCloneError = cloneData(state, "$.state")
        if stateCloneError then
            return failure({ stateCloneError })
        end

        local receipt = {
            schemaVersion = SCHEMA_VERSION,
            kind = "characterIntentSelection",
            battleId = state.battleId,
            turnNumber = state.turnNumber,
            characterId = state.character.characterId,
            selectionContext = buildSelectionContext(state, staticData, hand),
            candidates = candidates,
            weightedPoolInstanceIds = {},
            lethalPriorityApplied = false,
            rngBefore = rngBefore,
        }

        if #candidates == 0 then
            nextState.characterIntent = { cardInstanceIds = {} }
            local rngAfter, rngAfterError = cloneData(nextState.rng, "$.state.rng")
            if rngAfterError then
                return failure({ rngAfterError })
            end
            receipt.rngAfter = rngAfter
            receipt.draw = { kind = "pass" }
            local outputValidation, outputErrors = callModule("stateSchema", "validateBattleState", nextState, staticData)
            if outputErrors then
                return failure(outputErrors)
            end
            local intentCopy, intentCopyError = cloneData(nextState.characterIntent, "$.intent")
            if intentCopyError then
                return failure({ intentCopyError })
            end
            return success(nextState, intentCopy, receipt)
        end

        local pool = candidates
        local lethal = {}
        for _, candidate in ipairs(candidates) do
            if candidate.lethal then
                lethal[#lethal + 1] = candidate
            end
        end
        if #lethal > 0 then
            pool = lethal
            receipt.lethalPriorityApplied = true
        end

        local anyPositive = false
        local minimumScore = pool[1].score
        for _, candidate in ipairs(pool) do
            receipt.weightedPoolInstanceIds[#receipt.weightedPoolInstanceIds + 1] = candidate.instanceId
            if candidate.score > 0 then
                anyPositive = true
            end
            if candidate.score < minimumScore then
                minimumScore = candidate.score
            end
        end

        local weightOffset = anyPositive and 0 or (1 - minimumScore)
        if not isSafeInteger(weightOffset, 0) then
            return failure({
                makeError("invalid_character_weight_offset", "$.candidates", "점수 가중치 평행이동 값을 안전한 정수로 만들 수 없습니다."),
            })
        end
        receipt.weightOffset = weightOffset

        local totalWeight = 0
        for _, candidate in ipairs(pool) do
            local adjusted = candidate.score + weightOffset
            candidate.weight = adjusted > 0 and adjusted or 0
            if not isSafeInteger(candidate.weight, 0)
                or not isSafeInteger(totalWeight + candidate.weight, 0) then
                return failure({
                    makeError("invalid_character_selection_weight", "$.candidates", "후보 가중치 합이 안전한 정수 범위를 벗어났습니다."),
                })
            end
            totalWeight = totalWeight + candidate.weight
        end
        if totalWeight <= 0 then
            return failure({
                makeError("no_weighted_character_candidate", "$.candidates", "선택 후보의 총 가중치가 0입니다."),
            })
        end

        local selected
        if #pool == 1 then
            selected = pool[1]
            receipt.draw = {
                kind = "single",
                totalWeight = totalWeight,
            }
        else
            local rngReport, rngErrors = callModule(
                "deterministicRng",
                "nextInteger",
                state.rng,
                1,
                totalWeight
            )
            if rngErrors then
                return failure(rngErrors)
            end
            local roll = rngReport.value
            local cumulative = 0
            for _, candidate in ipairs(pool) do
                cumulative = cumulative + candidate.weight
                if candidate.weight > 0 and roll <= cumulative then
                    selected = candidate
                    break
                end
            end
            if selected == nil then
                return failure({
                    makeError("invalid_weighted_character_result", "$.rng", "결정적 가중 추첨 결과를 후보에 대응할 수 없습니다."),
                })
            end
            local rngCopy, rngCopyError = cloneData(rngReport.rng, "$.rng")
            if rngCopyError then
                return failure({ rngCopyError })
            end
            nextState.rng = rngCopy
            receipt.draw = {
                kind = "weighted",
                totalWeight = totalWeight,
                roll = roll,
            }
        end

        nextState.characterIntent = {
            cardInstanceIds = { selected.instanceId },
            publicActionTag = selected.actionTag,
        }
        receipt.selectedInstanceId = selected.instanceId
        receipt.selectedCardId = selected.cardId
        receipt.publicActionTag = selected.actionTag
        local rngAfter, rngAfterError = cloneData(nextState.rng, "$.state.rng")
        if rngAfterError then
            return failure({ rngAfterError })
        end
        receipt.rngAfter = rngAfter

        local outputValidation, outputErrors = callModule("stateSchema", "validateBattleState", nextState, staticData)
        if outputErrors then
            return failure(outputErrors)
        end
        if outputValidation.referencesValidated ~= true then
            return failure({
                makeError("output_references_not_validated", "$.state", "선택 결과의 정적 참조를 검증하지 못했습니다."),
            })
        end

        local intentCopy, intentCopyError = cloneData(nextState.characterIntent, "$.intent")
        if intentCopyError then
            return failure({ intentCopyError })
        end
        return success(nextState, intentCopy, receipt)
    end

    local arguments = { ... }
    local actions = {
        selectIntent = selectIntent,
        validateReceipt = validateReceipt,
    }
    local handler = actions[action]
    if not handler then
        return failure({
            makeError("unknown_action", "$.action", "지원하지 않는 캐릭터 선택 작업입니다: " .. tostring(action)),
        })
    end
    return handler(arguments[1], arguments[2], arguments[3])
end)
