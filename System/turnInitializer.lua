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

    local function success(state, draft, receipt, characterSelection, draws, reused)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            state = state,
            draft = draft,
            receipt = receipt,
            characterSelection = characterSelection,
            draws = draws or {},
            reused = reused == true,
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
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "유한하지 않은 숫자는 턴 초기화 데이터에 복제할 수 없습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError(
                "unsupported_type",
                path,
                "턴 초기화 데이터에 복제할 수 없는 자료형입니다: " .. valueType
            )
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "턴 초기화 데이터에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조는 턴 초기화 데이터에 복제할 수 없습니다.")
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

    local function deepEqual(left, right, active)
        if type(left) ~= type(right) then
            return false
        end
        if type(left) ~= "table" then
            return left == right
        end
        if getmetatable(left) ~= nil or getmetatable(right) ~= nil then
            return false
        end
        active = active or {}
        if active[left] ~= nil then
            return active[left] == right
        end
        active[left] = right
        for key, value in pairs(left) do
            if not deepEqual(value, right[key], active) then
                active[left] = nil
                return false
            end
        end
        for key in pairs(right) do
            if left[key] == nil then
                active[left] = nil
                return false
            end
        end
        active[left] = nil
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
            target[#target + 1] = makeError("invalid_nested_error", "$", "하위 모듈 오류 목록이 올바르지 않습니다.")
            return
        end
        for _, item in ipairs(source) do
            target[#target + 1] = {
                code = tostring(type(item) == "table" and item.code or "nested_error"),
                path = tostring(type(item) == "table" and item.path or "$"),
                message = tostring(type(item) == "table" and item.message or "하위 모듈 작업이 실패했습니다."),
            }
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
        if type(report) ~= "table" or getmetatable(report) ~= nil then
            return nil, {
                makeError("invalid_module_result", "$.runtime." .. moduleName, "하위 모듈이 일반 테이블 결과를 반환하지 않았습니다."),
            }
        end
        if report.ok ~= true then
            local errors = {}
            appendErrors(errors, report.errors)
            return nil, errors
        end
        return report, nil
    end

    local function validateOptions(options, authorityState)
        local errors = {}
        if type(options) ~= "table" or getmetatable(options) ~= nil then
            return nil, {
                makeError("invalid_options", "$.options", "턴 초기화 옵션은 일반 테이블이어야 합니다."),
            }
        end
        for key in pairs(options) do
            if key ~= "turnId" then
                errors[#errors + 1] = makeError(
                    "unexpected_option",
                    "$.options." .. tostring(key),
                    "지원하지 않는 턴 초기화 옵션입니다."
                )
            end
        end
        if not isRuntimeId(options.turnId) then
            errors[#errors + 1] = makeError("invalid_turn_id", "$.options.turnId", "turnId가 올바르지 않습니다.")
        elseif type(authorityState) == "table" and authorityState.lastCommittedTurnId == options.turnId then
            errors[#errors + 1] = makeError(
                "turn_already_committed",
                "$.options.turnId",
                "이미 확정한 turnId를 다시 초기화할 수 없습니다."
            )
        end
        if #errors > 0 then
            return nil, errors
        end
        return { turnId = options.turnId }, nil
    end

    local function source(kind, id, side, instanceId)
        local value = {
            kind = kind,
            id = id,
        }
        if side ~= nil then
            value.side = side
        end
        if instanceId ~= nil then
            value.instanceId = instanceId
        end
        return value
    end

    local function findInstance(state, instanceId)
        for _, instance in ipairs(type(state) == "table" and type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if type(instance) == "table" and instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function validateStateEnvelope(state, path, code, label)
        local errors = {}
        if type(state) ~= "table" or getmetatable(state) ~= nil then
            return false, {
                makeError(code, path, label .. " state가 일반 테이블이 아닙니다."),
            }
        end

        local player = state.player
        local character = state.character
        if type(player) ~= "table" or getmetatable(player) ~= nil then
            errors[#errors + 1] = makeError(code, path .. ".player", label .. " player가 일반 테이블이 아닙니다.")
        else
            if not isFinite(player.stealth) then
                errors[#errors + 1] = makeError(code, path .. ".player.stealth", label .. " player.stealth가 유한한 숫자가 아닙니다.")
            end
            if not isInteger(player.baseDrawCount, 1) then
                errors[#errors + 1] = makeError(code, path .. ".player.baseDrawCount", label .. " player.baseDrawCount가 1 이상의 정수가 아닙니다.")
            end
        end
        if type(character) ~= "table" or getmetatable(character) ~= nil then
            errors[#errors + 1] = makeError(code, path .. ".character", label .. " character가 일반 테이블이 아닙니다.")
        else
            if not isFinite(character.resistance) then
                errors[#errors + 1] = makeError(code, path .. ".character.resistance", label .. " character.resistance가 유한한 숫자가 아닙니다.")
            end
            if not isInteger(character.baseDrawCount, 1) then
                errors[#errors + 1] = makeError(code, path .. ".character.baseDrawCount", label .. " character.baseDrawCount가 1 이상의 정수가 아닙니다.")
            end
        end

        if type(state.rng) ~= "table" or getmetatable(state.rng) ~= nil then
            errors[#errors + 1] = makeError(code, path .. ".rng", label .. " rng가 일반 테이블이 아닙니다.")
        elseif not isInteger(state.rng.seed, 0) or not isInteger(state.rng.cursor, 0) then
            errors[#errors + 1] = makeError(code, path .. ".rng", label .. " rng seed/cursor가 0 이상의 정수가 아닙니다.")
        end
        if type(state.cardInstances) ~= "table" or getmetatable(state.cardInstances) ~= nil then
            errors[#errors + 1] = makeError(code, path .. ".cardInstances", label .. " cardInstances가 일반 테이블이 아닙니다.")
        end

        if #errors > 0 then
            return false, errors
        end
        return true, nil
    end

    local function validateDrawReportEnvelope(report)
        if type(report) ~= "table" or getmetatable(report) ~= nil then
            return false, {
                makeError("invalid_draw_result", "$.runtime.cardZones", "cardZones.draw 결과가 일반 테이블이 아닙니다."),
            }
        end
        local validState, stateErrors = validateStateEnvelope(
            report.state,
            "$.runtime.cardZones.state",
            "invalid_draw_state",
            "cardZones.draw 결과"
        )
        if not validState then
            return false, stateErrors
        end
        if not isDenseArray(report.drawnInstanceIds) then
            return false, {
                makeError(
                    "invalid_draw_result",
                    "$.runtime.cardZones.drawnInstanceIds",
                    "cardZones.draw의 drawnInstanceIds가 연속 배열이 아닙니다."
                ),
            }
        end
        local seen = {}
        for index, instanceId in ipairs(report.drawnInstanceIds) do
            if not isRuntimeId(instanceId) then
                return false, {
                    makeError(
                        "invalid_draw_result",
                        "$.runtime.cardZones.drawnInstanceIds[" .. index .. "]",
                        "cardZones.draw가 올바르지 않은 카드 인스턴스 ID를 반환했습니다."
                    ),
                }
            end
            if seen[instanceId] then
                return false, {
                    makeError(
                        "invalid_draw_result",
                        "$.runtime.cardZones.drawnInstanceIds[" .. index .. "]",
                        "cardZones.draw가 중복 카드 인스턴스 ID를 반환했습니다."
                    ),
                }
            end
            seen[instanceId] = true
        end
        return true, nil
    end

    local function validateSelectorReportEnvelope(report)
        if type(report) ~= "table" or getmetatable(report) ~= nil then
            return false, {
                makeError("invalid_character_selection_result", "$.characterSelection", "캐릭터 선택 결과가 일반 테이블이 아닙니다."),
            }
        end
        local validState, stateErrors = validateStateEnvelope(
            report.state,
            "$.characterSelection.state",
            "invalid_character_selection_state",
            "캐릭터 선택 결과"
        )
        if not validState then
            return false, stateErrors
        end
        if type(report.intent) ~= "table" or getmetatable(report.intent) ~= nil then
            return false, {
                makeError("invalid_character_selection_result", "$.characterSelection.intent", "캐릭터 선택 intent가 일반 테이블이 아닙니다."),
            }
        end
        if type(report.receipt) ~= "table" or getmetatable(report.receipt) ~= nil then
            return false, {
                makeError("invalid_character_selection_result", "$.characterSelection.receipt", "캐릭터 선택 receipt가 일반 테이블이 아닙니다."),
            }
        end
        return true, nil
    end

    local function hasOutcome(state)
        return type(state) == "table"
            and type(state.player) == "table"
            and type(state.character) == "table"
            and isFinite(state.player.stealth)
            and isFinite(state.character.resistance)
            and (state.player.stealth <= 0 or state.character.resistance <= 0)
    end

    local function prepareTurn(authorityState, staticInput, options)
        local normalizedOptions, optionErrors = validateOptions(options, authorityState)
        if optionErrors then
            return failure(optionErrors)
        end
        local staticData = normalizeStaticData(staticInput)

        local validation, validationErrors = callModule(
            "stateSchema",
            "validateBattleState",
            authorityState,
            staticData
        )
        if validationErrors then
            return failure(validationErrors)
        end
        if validation.referencesValidated ~= true then
            return failure({
                makeError("static_references_not_validated", "$.staticData", "턴 초기화에는 전체 정적 데이터 참조 검증이 필요합니다."),
            })
        end
        if authorityState.status ~= "active" then
            return failure({
                makeError("battle_not_active", "$.state.status", "진행 중인 전투만 턴을 초기화할 수 있습니다."),
            })
        end

        local turnId = normalizedOptions.turnId
        if authorityState.turnStartReceipt ~= nil then
            if authorityState.turnStartReceipt.turnId ~= turnId then
                return failure({
                    makeError(
                        "turn_already_initialized",
                        "$.state.turnStartReceipt.turnId",
                        "현재 턴은 다른 turnId로 이미 초기화되었습니다."
                    ),
                })
            end
            local reusedState, stateCloneError = cloneData(authorityState, "$.state")
            if stateCloneError then
                return failure({ stateCloneError })
            end
            local receiptCopy, receiptCloneError = cloneData(authorityState.turnStartReceipt, "$.state.turnStartReceipt")
            if receiptCloneError then
                return failure({ receiptCloneError })
            end
            local selectionCopy, selectionCloneError = cloneData(
                authorityState.turnStartReceipt.characterSelection,
                "$.state.turnStartReceipt.characterSelection"
            )
            if selectionCloneError then
                return failure({ selectionCloneError })
            end
            local drawsCopy, drawsCloneError = cloneData(
                authorityState.turnStartReceipt.draws,
                "$.state.turnStartReceipt.draws"
            )
            if drawsCloneError then
                return failure({ drawsCloneError })
            end
            local draftReport, draftErrors = callModule("turnDraft", "newDraft", reusedState, staticData)
            if draftErrors then
                return failure(draftErrors)
            end
            return success(reusedState, draftReport.draft, receiptCopy, selectionCopy, drawsCopy, true)
        end

        if type(authorityState.selection) ~= "table"
            or not isDenseArray(authorityState.selection.playerCardInstanceIds)
            or #authorityState.selection.playerCardInstanceIds > 0 then
            return failure({
                makeError(
                    "player_selection_not_empty",
                    "$.state.selection.playerCardInstanceIds",
                    "턴 초기화 전 플레이어 선택은 비어 있어야 합니다."
                ),
            })
        end
        if type(authorityState.characterIntent) ~= "table"
            or not isDenseArray(authorityState.characterIntent.cardInstanceIds)
            or #authorityState.characterIntent.cardInstanceIds > 0
            or authorityState.characterIntent.publicActionTag ~= nil then
            return failure({
                makeError(
                    "character_intent_not_empty",
                    "$.state.characterIntent",
                    "턴 초기화 전 캐릭터 의도는 비어 있어야 합니다."
                ),
            })
        end

        local baseline = {
            stealth = authorityState.player.stealth,
            resistance = authorityState.character.resistance,
            mood = authorityState.character.mood,
        }
        local baselineTokens, baselineTokensError = cloneData(
            authorityState.character.moodTokens or {},
            "$.state.character.moodTokens"
        )
        if baselineTokensError then
            return failure({ baselineTokensError })
        end
        for moodId in pairs(staticData.registry.moods) do
            if baselineTokens[moodId] == nil then
                baselineTokens[moodId] = 0
            end
        end
        baseline.moodTokens = baselineTokens
        local state, stateCloneError = cloneData(authorityState, "$.state")
        if stateCloneError then
            return failure({ stateCloneError })
        end
        local transient = {
            skipRemaining = {
                player = false,
                character = false,
            },
            forcedMoodRequests = {},
        }
        local events = {}

        local function appendEvent(eventType, eventSource, payload, side, cause)
            local sequence = #events + 1
            local event = {
                eventId = turnId .. "-event-" .. string.format("%03d", sequence),
                sequence = sequence,
                type = eventType,
                phase = "turn_start",
                source = eventSource,
            }
            if payload ~= nil then
                event.payload = payload
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

        local function appendPipelineRecords(records, inputEventId)
            if not isDenseArray(records) then
                return false, {
                    makeError("invalid_trigger_records", "$.triggerPipeline.records", "트리거 기록이 연속 배열이 아닙니다."),
                }
            end
            for index, record in ipairs(records) do
                if type(record) ~= "table"
                    or type(record.type) ~= "string"
                    or string.match(record.type, "^[a-z][a-z0-9_]*$") == nil
                    or type(record.source) ~= "table"
                    or type(record.source.kind) ~= "string"
                    or string.match(record.source.kind, "^[a-z][a-z0-9_]*$") == nil
                    or type(record.source.id) ~= "string"
                    or string.match(record.source.id, "^[a-z][a-z0-9_]*$") == nil
                    or record.side ~= record.source.side then
                    return false, {
                        makeError(
                            "invalid_trigger_record",
                            "$.triggerPipeline.records[" .. index .. "]",
                            "트리거 기록 envelope가 올바르지 않습니다."
                        ),
                    }
                end
                local sourceCopy, sourceError = cloneData(record.source, "$.triggerPipeline.records[" .. index .. "].source")
                if sourceError then
                    return false, { sourceError }
                end
                local payloadCopy = nil
                if record.payload ~= nil then
                    local payloadError
                    payloadCopy, payloadError = cloneData(
                        record.payload,
                        "$.triggerPipeline.records[" .. index .. "].payload"
                    )
                    if payloadError then
                        return false, { payloadError }
                    end
                end
                appendEvent(
                    record.type,
                    sourceCopy,
                    payloadCopy,
                    record.side,
                    record.type == "effect_applied" and {
                        kind = record.source.kind .. "_trigger",
                        eventId = inputEventId,
                    } or {
                        kind = "turn_event",
                        eventId = inputEventId,
                    }
                )
            end
            return true, nil
        end

        local function validatePipelineReport(report)
            if type(report) ~= "table" or getmetatable(report) ~= nil then
                return false, {
                    makeError(
                        "invalid_trigger_pipeline_result",
                        "$.runtime.triggerPipeline",
                        "triggerPipeline.run 결과가 일반 테이블이 아닙니다."
                    ),
                }
            end
            local validState, stateErrors = validateStateEnvelope(
                report.state,
                "$.runtime.triggerPipeline.state",
                "invalid_trigger_pipeline_state",
                "triggerPipeline.run 결과"
            )
            if not validState then
                return false, stateErrors
            end
            if type(report.transient) ~= "table"
                or getmetatable(report.transient) ~= nil
                or not isDenseArray(report.records) then
                return false, {
                    makeError(
                        "invalid_trigger_pipeline_result",
                        "$.runtime.triggerPipeline",
                        "triggerPipeline.run 결과의 transient 또는 records가 올바르지 않습니다."
                    ),
                }
            end
            local skipRemaining = report.transient.skipRemaining
            if type(skipRemaining) ~= "table"
                or (skipRemaining.player ~= true and skipRemaining.player ~= false)
                or (skipRemaining.character ~= true and skipRemaining.character ~= false)
                or not isDenseArray(report.transient.forcedMoodRequests) then
                return false, {
                    makeError(
                        "invalid_trigger_pipeline_transient",
                        "$.runtime.triggerPipeline.transient",
                        "triggerPipeline.run 결과의 턴 일시 상태가 올바르지 않습니다."
                    ),
                }
            end
            return true, nil
        end

        local function validateWorkingState(value)
            local workingValidation, workingErrors = callModule(
                "stateSchema",
                "validateBattleState",
                value,
                staticData
            )
            if workingErrors then
                return false, workingErrors
            end
            if workingValidation.referencesValidated ~= true then
                return false, {
                    makeError(
                        "working_references_not_validated",
                        "$.runtime.stateSchema",
                        "턴 초기화 중간 상태의 전체 정적 참조를 검증하지 못했습니다."
                    ),
                }
            end
            return true, nil
        end

        local turnStartEvent = appendEvent(
            "turn_start",
            source("system", "turn_initializer"),
            { turnNumber = state.turnNumber },
            nil,
            { kind = "turn_rule" }
        )
        local turnStartInput = {
            type = "turn_start",
            turnNumber = state.turnNumber,
        }
        local startPipeline, startPipelineErrors = callModule(
            "triggerPipeline",
            "run",
            staticData,
            { state = state, transient = transient },
            turnStartInput,
            { phase = "turn_start" }
        )
        if startPipelineErrors then
            return failure(startPipelineErrors)
        end
        local validPipeline, pipelineShapeErrors = validatePipelineReport(startPipeline)
        if not validPipeline then
            return failure(pipelineShapeErrors)
        end
        state = startPipeline.state
        transient = startPipeline.transient
        local appended, appendRecordErrors = appendPipelineRecords(startPipeline.records, turnStartEvent.eventId)
        if not appended then
            return failure(appendRecordErrors)
        end
        if hasOutcome(state) then
            return failure({
                makeError(
                    "turn_start_outcome_policy_pending",
                    "$.state.status",
                    "턴 시작 효과만으로 승패가 정해질 때의 세션 종료 연결 정책은 아직 지원하지 않습니다."
                ),
            })
        end
        local validWorkingState, workingStateErrors = validateWorkingState(state)
        if not validWorkingState then
            return failure(workingStateErrors)
        end

        local draws = {}
        for _, owner in ipairs({ "player", "character" }) do
            local ownerState = state[owner]
            if type(ownerState) ~= "table" or not isInteger(ownerState.baseDrawCount, 1) then
                return failure({
                    makeError(
                        "invalid_base_draw_count",
                        "$.state." .. owner .. ".baseDrawCount",
                        "기본 드로우 수는 1 이상의 정수여야 합니다."
                    ),
                })
            end
            local rngBefore, rngBeforeError = cloneData(state.rng, "$.state.rng")
            if rngBeforeError then
                return failure({ rngBeforeError })
            end
            local drawReport, drawErrors = callModule(
                "cardZones",
                "draw",
                state,
                owner,
                ownerState.baseDrawCount
            )
            if drawErrors then
                return failure(drawErrors)
            end
            local validDrawReport, drawShapeErrors = validateDrawReportEnvelope(drawReport)
            if not validDrawReport then
                return failure(drawShapeErrors)
            end
            state = drawReport.state
            validWorkingState, workingStateErrors = validateWorkingState(state)
            if not validWorkingState then
                return failure(workingStateErrors)
            end
            local rngAfter, rngAfterError = cloneData(state.rng, "$.state.rng")
            if rngAfterError then
                return failure({ rngAfterError })
            end
            local drawnIds, drawnIdsError = cloneData(drawReport.drawnInstanceIds or {}, "$.drawnInstanceIds")
            if drawnIdsError then
                return failure({ drawnIdsError })
            end
            draws[owner] = {
                requested = ownerState.baseDrawCount,
                drawnInstanceIds = drawnIds,
                rngBefore = rngBefore,
                rngAfter = rngAfter,
            }
            appendEvent(
                "cards_drawn",
                source("system", "card_zones", owner),
                {
                    requested = ownerState.baseDrawCount,
                    drawnCount = #drawnIds,
                },
                owner,
                { kind = "turn_rule" }
            )
        end

        local stateBeforeSelection, stateBeforeSelectionError = cloneData(state, "$.stateBeforeSelection")
        if stateBeforeSelectionError then
            return failure({ stateBeforeSelectionError })
        end
        local selectionRngBefore, selectionRngBeforeError = cloneData(state.rng, "$.state.rng")
        if selectionRngBeforeError then
            return failure({ selectionRngBeforeError })
        end
        local selectionReport, selectionErrors = callModule(
            "characterSelector",
            "selectIntent",
            state,
            staticData
        )
        if selectionErrors then
            return failure(selectionErrors)
        end
        local validSelectionReport, selectionShapeErrors = validateSelectorReportEnvelope(selectionReport)
        if not validSelectionReport then
            return failure(selectionShapeErrors)
        end
        validWorkingState, workingStateErrors = validateWorkingState(selectionReport.state)
        if not validWorkingState then
            return failure(workingStateErrors)
        end
        state = selectionReport.state
        local selectionIntent, selectionIntentError = cloneData(selectionReport.intent, "$.characterSelection.intent")
        if selectionIntentError then
            return failure({ selectionIntentError })
        end
        local selectionReceipt, selectionReceiptError = cloneData(
            selectionReport.receipt,
            "$.characterSelection"
        )
        if selectionReceiptError then
            return failure({ selectionReceiptError })
        end
        local selectionReplay, selectionReplayErrors = callModule(
            "characterSelector",
            "validateReceipt",
            staticData,
            selectionReceipt,
            stateBeforeSelection
        )
        if selectionReplayErrors then
            return failure(selectionReplayErrors)
        end
        if selectionReplay.valid ~= true then
            return failure({
                makeError(
                    "invalid_character_selection_replay",
                    "$.characterSelection",
                    "선택기가 실제 선택 직전 상태에 대한 재생 검증을 완료하지 못했습니다."
                ),
            })
        end
        if type(state.characterIntent) ~= "table"
            or not deepEqual(selectionIntent, state.characterIntent) then
            return failure({
                makeError(
                    "character_selection_intent_mismatch",
                    "$.characterSelection.intent",
                    "선택기가 반환한 intent와 상태의 characterIntent가 일치하지 않습니다."
                ),
            })
        end
        local expectedSelectionState, expectedSelectionStateError = cloneData(
            stateBeforeSelection,
            "$.expectedSelectionState"
        )
        if expectedSelectionStateError then
            return failure({ expectedSelectionStateError })
        end
        local selectedRng, selectedRngError = cloneData(state.rng, "$.characterSelection.state.rng")
        if selectedRngError then
            return failure({ selectedRngError })
        end
        expectedSelectionState.rng = selectedRng
        local expectedIntent, expectedIntentError = cloneData(selectionIntent, "$.characterSelection.intent")
        if expectedIntentError then
            return failure({ expectedIntentError })
        end
        expectedSelectionState.characterIntent = expectedIntent
        if not deepEqual(expectedSelectionState, state) then
            return failure({
                makeError(
                    "character_selection_state_scope_violation",
                    "$.characterSelection.state",
                    "선택기가 RNG와 characterIntent 이외의 권위 상태를 변경했습니다."
                ),
            })
        end
        if selectionReceipt.battleId ~= state.battleId
            or selectionReceipt.turnNumber ~= state.turnNumber
            or selectionReceipt.characterId ~= state.character.characterId then
            return failure({
                makeError(
                    "character_selection_identity_mismatch",
                    "$.characterSelection",
                    "선택 영수증의 전투·턴·캐릭터 식별자가 상태와 일치하지 않습니다."
                ),
            })
        end
        if not deepEqual(selectionReceipt.rngBefore, selectionRngBefore)
            or not deepEqual(selectionReceipt.rngAfter, state.rng) then
            return failure({
                makeError(
                    "character_selection_rng_mismatch",
                    "$.characterSelection.rngAfter",
                    "선택 영수증의 RNG 전이가 실제 선택 상태와 일치하지 않습니다."
                ),
            })
        end

        local selectedInstanceId = selectionReceipt.selectedInstanceId
        local selectedInstance = selectedInstanceId and findInstance(state, selectedInstanceId) or nil
        if selectedInstanceId == nil then
            if not isDenseArray(selectionIntent.cardInstanceIds)
                or #selectionIntent.cardInstanceIds ~= 0
                or selectionIntent.publicActionTag ~= nil
                or selectionReceipt.selectedCardId ~= nil
                or selectionReceipt.publicActionTag ~= nil
                or type(selectionReceipt.draw) ~= "table"
                or selectionReceipt.draw.kind ~= "pass" then
                return failure({
                    makeError(
                        "character_selection_pass_mismatch",
                        "$.characterSelection",
                        "패스 선택 영수증과 characterIntent가 일치하지 않습니다."
                    ),
                })
            end
        elseif not isDenseArray(selectionIntent.cardInstanceIds)
            or #selectionIntent.cardInstanceIds ~= 1
            or selectionIntent.cardInstanceIds[1] ~= selectedInstanceId
            or selectionIntent.publicActionTag ~= selectionReceipt.publicActionTag then
            return failure({
                makeError(
                    "character_selection_selected_mismatch",
                    "$.characterSelection",
                    "선택 영수증과 선택된 characterIntent가 일치하지 않습니다."
                ),
            })
        end
        appendEvent(
            "character_intent_selected",
            source("system", "character_selector", "character"),
            { selected = selectedInstanceId ~= nil },
            "character",
            { kind = "turn_rule" }
        )

        if selectedInstanceId ~= nil then
            if selectedInstance == nil or selectedInstance.owner ~= "character" or selectedInstance.zone ~= "hand" then
                return failure({
                    makeError(
                        "invalid_selected_character_card",
                        "$.characterSelection.selectedInstanceId",
                        "선택기가 캐릭터 손패에 없는 카드를 반환했습니다."
                    ),
                })
            end
            local card = staticData.cards[selectedInstance.cardId]
            if type(card) ~= "table"
                or card.id ~= selectionReceipt.selectedCardId
                or card.actionTag ~= selectionReceipt.publicActionTag then
                return failure({
                    makeError(
                        "selected_action_tag_mismatch",
                        "$.characterSelection.publicActionTag",
                        "선택 카드와 공개 행동 태그가 일치하지 않습니다."
                    ),
                })
            end
            local revealEvent = appendEvent(
                "action_tag_revealed",
                source("system", "character_selector", "character"),
                {
                    actionTag = card.actionTag,
                },
                "character",
                { kind = "turn_rule" }
            )
            local revealInput = {
                type = "action_tag_revealed",
                side = "character",
                cardId = card.id,
                cardInstanceId = selectedInstance.instanceId,
                actionTag = card.actionTag,
            }
            local revealPipeline, revealPipelineErrors = callModule(
                "triggerPipeline",
                "run",
                staticData,
                { state = state, transient = transient },
                revealInput,
                {
                    phase = "turn_start",
                    currentCard = {
                        id = card.id,
                        instanceId = selectedInstance.instanceId,
                        owner = "character",
                        actionTag = card.actionTag,
                    },
                }
            )
            if revealPipelineErrors then
                return failure(revealPipelineErrors)
            end
            validPipeline, pipelineShapeErrors = validatePipelineReport(revealPipeline)
            if not validPipeline then
                return failure(pipelineShapeErrors)
            end
            state = revealPipeline.state
            transient = revealPipeline.transient
            appended, appendRecordErrors = appendPipelineRecords(revealPipeline.records, revealEvent.eventId)
            if not appended then
                return failure(appendRecordErrors)
            end
            if hasOutcome(state) then
                return failure({
                    makeError(
                        "turn_start_outcome_policy_pending",
                        "$.state.status",
                        "행동 태그 공개 효과만으로 승패가 정해질 때의 세션 종료 연결 정책은 아직 지원하지 않습니다."
                    ),
                })
            end
            validWorkingState, workingStateErrors = validateWorkingState(state)
            if not validWorkingState then
                return failure(workingStateErrors)
            end
        end

        local storedTransient = {
            skipRemaining = {
                player = type(transient.skipRemaining) == "table" and transient.skipRemaining.player == true,
                character = type(transient.skipRemaining) == "table" and transient.skipRemaining.character == true,
            },
            forcedMoodRequests = {},
        }
        local forcedRequestsCopy, forcedRequestsError = cloneData(
            transient.forcedMoodRequests or {},
            "$.transient.forcedMoodRequests"
        )
        if forcedRequestsError then
            return failure({ forcedRequestsError })
        end
        storedTransient.forcedMoodRequests = forcedRequestsCopy

        local receiptDraws, receiptDrawsError = cloneData(draws, "$.draws")
        if receiptDrawsError then
            return failure({ receiptDrawsError })
        end
        local receiptSelection, receiptSelectionError = cloneData(
            selectionReceipt,
            "$.characterSelection"
        )
        if receiptSelectionError then
            return failure({ receiptSelectionError })
        end
        local receipt = {
            schemaVersion = SCHEMA_VERSION,
            kind = "turnStartReceipt",
            turnId = turnId,
            turnNumber = state.turnNumber,
            baseline = baseline,
            transient = storedTransient,
            draws = receiptDraws,
            characterSelection = receiptSelection,
            events = events,
        }
        state.turnStartReceipt = receipt

        local sealReport, sealErrors = callModule(
            "stateSchema",
            "sealTurnStartReceipt",
            state,
            staticData
        )
        if sealErrors then
            return failure(sealErrors)
        end
        if type(sealReport.state) ~= "table"
            or type(sealReport.state.turnStartReceipt) ~= "table"
            or type(sealReport.state.turnStartReceipt.authorityFingerprint) ~= "table" then
            return failure({
                makeError("invalid_turn_receipt_seal", "$.state.turnStartReceipt", "stateSchema가 봉인된 턴 영수증 상태를 반환하지 않았습니다."),
            })
        end
        state = sealReport.state
        receipt = state.turnStartReceipt

        local outputValidation, outputValidationErrors = callModule(
            "stateSchema",
            "validateBattleState",
            state,
            staticData
        )
        if outputValidationErrors then
            return failure(outputValidationErrors)
        end
        if outputValidation.referencesValidated ~= true then
            return failure({
                makeError("output_references_not_validated", "$.state", "초기화 결과의 정적 참조를 검증하지 못했습니다."),
            })
        end
        local conservation, conservationErrors = callModule(
            "cardZones",
            "validateConservation",
            authorityState,
            state
        )
        if conservationErrors then
            return failure(conservationErrors)
        end
        local draftReport, draftErrors = callModule("turnDraft", "newDraft", state, staticData)
        if draftErrors then
            return failure(draftErrors)
        end

        local receiptCopy, receiptCopyError = cloneData(receipt, "$.receipt")
        if receiptCopyError then
            return failure({ receiptCopyError })
        end
        local selectionOutput, selectionOutputError = cloneData(
            receipt.characterSelection,
            "$.receipt.characterSelection"
        )
        if selectionOutputError then
            return failure({ selectionOutputError })
        end
        local drawsOutput, drawsOutputError = cloneData(receipt.draws, "$.receipt.draws")
        if drawsOutputError then
            return failure({ drawsOutputError })
        end
        return success(
            state,
            draftReport.draft,
            receiptCopy,
            selectionOutput,
            drawsOutput,
            false
        )
    end

    local arguments = { ... }
    local actions = {
        prepareTurn = prepareTurn,
    }
    local handler = actions[action]
    if not handler then
        return failure({
            makeError("unknown_action", "$.action", "지원하지 않는 턴 초기화 작업입니다: " .. tostring(action)),
        })
    end
    return handler(arguments[1], arguments[2], arguments[3])
end)
