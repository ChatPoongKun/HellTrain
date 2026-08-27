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

    local function pendingSuccess(pendingTurn, reused)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            pendingTurn = pendingTurn,
            turnId = pendingTurn.turnId,
            reused = reused == true,
        }
    end

    local function commitSuccess(state, turnId, applied)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            state = state,
            turnId = turnId,
            applied = applied == true,
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

    local function cloneData(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "유한하지 않은 숫자는 런타임 트랜잭션에 저장할 수 없습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError("unsupported_type", path, "런타임 트랜잭션에 저장할 수 없는 자료형입니다.")
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "런타임 트랜잭션 데이터에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조는 런타임 트랜잭션에 저장할 수 없습니다.")
        end
        active[value] = true

        local numericCount = 0
        local maximum = 0
        local hasNumeric = false
        local hasString = false
        for key in pairs(value) do
            if type(key) == "number" then
                hasNumeric = true
                numericCount = numericCount + 1
                if not isInteger(key, 1) then
                    active[value] = nil
                    return nil, makeError("invalid_array_index", path, "배열 인덱스는 1 이상의 정수여야 합니다.")
                end
                maximum = math.max(maximum, key)
            elseif type(key) == "string" then
                hasString = true
            else
                active[value] = nil
                return nil, makeError("invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
            end
        end
        if hasNumeric and hasString then
            active[value] = nil
            return nil, makeError("mixed_table", path, "숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
        end
        if hasNumeric and numericCount ~= maximum then
            active[value] = nil
            return nil, makeError("sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
        end

        local copy = {}
        if hasNumeric then
            for index = 1, maximum do
                local item, itemError = cloneData(value[index], path .. "[" .. index .. "]", active)
                if itemError then
                    active[value] = nil
                    return nil, itemError
                end
                copy[index] = item
            end
        else
            for key, item in pairs(value) do
                local itemCopy, itemError = cloneData(item, path .. "." .. key, active)
                if itemError then
                    active[value] = nil
                    return nil, itemError
                end
                copy[key] = itemCopy
            end
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

    local function appendNestedErrors(target, prefix, report)
        local nested = type(report) == "table" and report.errors or nil
        if type(nested) ~= "table" or #nested == 0 then
            target[#target + 1] = makeError("nested_operation_failed", prefix, "하위 런타임 작업이 실패했습니다.")
            return
        end
        for _, item in ipairs(nested) do
            local code = type(item) == "table" and item.code or nil
            local path = type(item) == "table" and item.path or nil
            local message = type(item) == "table" and item.message or nil
            local nestedPath = prefix
            if type(path) == "string" then
                nestedPath = path:sub(1, 1) == "$" and (prefix .. path:sub(2)) or (prefix .. "." .. path)
            end
            target[#target + 1] = makeError(
                type(code) == "string" and code or "nested_error",
                nestedPath,
                type(message) == "string" and message or "하위 런타임 작업이 실패했습니다."
            )
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
                makeError("module_call_error", "$.runtime." .. moduleName, "하위 모듈 호출 중 오류가 발생했습니다."),
            }
        end
        if type(report) ~= "table" then
            return nil, {
                makeError("invalid_module_result", "$.runtime." .. moduleName, "하위 모듈이 테이블 결과를 반환하지 않았습니다."),
            }
        end
        if report.ok ~= true then
            local errors = {}
            appendNestedErrors(errors, "$.runtime." .. moduleName, report)
            return nil, errors
        end
        return report, nil
    end

    local function validateAuthority(authorityState, staticData)
        local report, errors = callModule(
            "stateSchema",
            "validateBattleState",
            authorityState,
            staticData
        )
        if errors then
            return nil, errors
        end
        if report.referencesValidated ~= true then
            return nil, {
                makeError("static_references_not_validated", "$.staticData", "런타임 트랜잭션에는 전체 정적 데이터 검증이 필요합니다."),
            }
        end
        return report.value or authorityState, nil
    end

    local function validateStoredPending(pendingTurn, staticData)
        local shapeReport, shapeErrors = callModule(
            "stateSchema",
            "validatePendingTurn",
            pendingTurn,
            staticData
        )
        if shapeErrors then
            return nil, shapeErrors
        end
        if shapeReport.referencesValidated ~= true then
            return nil, {
                makeError("static_references_not_validated", "$.staticData", "대기 트랜잭션 검증에는 전체 정적 데이터가 필요합니다."),
            }
        end

        local replayReport, replayErrors = callModule(
            "turnDraft",
            "validateProjectionReceipt",
            pendingTurn.beforeState,
            staticData,
            pendingTurn.projectionReceipt
        )
        if replayErrors then
            return nil, replayErrors
        end
        if type(replayReport.projection) ~= "table" or type(replayReport.receipt) ~= "table" then
            return nil, {
                makeError("invalid_projection_replay", "$.projectionReceipt", "projection 영수증 재생 결과가 올바르지 않습니다."),
            }
        end

        local pendingCopy, cloneError = cloneData(shapeReport.value or pendingTurn, "$.pendingTurn")
        if cloneError then
            return nil, { cloneError }
        end
        local presented, presentationErrors = callModule(
            "turnPresentation",
            "build",
            pendingCopy,
            staticData
        )
        if presentationErrors then
            return nil, presentationErrors
        end
        if type(presented.lastTurn) ~= "table" or presented.lastTurn.available ~= true then
            return nil, {
                makeError(
                    "invalid_public_presentation",
                    "$.pendingTurn.turnResult.publicResult",
                    "공개 턴 표시를 생성하지 못했습니다."
                ),
            }
        end
        return pendingCopy, nil
    end

    local function preparePending(authorityState, staticData, projection)
        local validatedState, authorityErrors = validateAuthority(authorityState, staticData)
        if authorityErrors then
            return failure(authorityErrors)
        end
        if validatedState.status ~= "active" then
            return failure({
                makeError("prepare_requires_active", "$.authorityState.status", "active 전투에서만 턴을 판정할 수 있습니다."),
            })
        end
        local receipt = validatedState.turnStartReceipt
        if type(receipt) ~= "table" or type(receipt.turnId) ~= "string" then
            return failure({
                makeError("missing_turn_start_receipt", "$.authorityState.turnStartReceipt", "턴 판정 전 봉인된 turnStartReceipt가 필요합니다."),
            })
        end

        local sealed, sealErrors = callModule(
            "turnDraft",
            "sealProjection",
            validatedState,
            staticData,
            projection
        )
        if sealErrors then
            return failure(sealErrors)
        end
        if type(sealed.projection) ~= "table" or type(sealed.receipt) ~= "table" then
            return failure({
                makeError("invalid_sealed_projection", "$.projection", "봉인된 projection 결과가 올바르지 않습니다."),
            })
        end

        local resolved, resolveErrors = callModule(
            "turnResolver",
            "resolveTurn",
            validatedState,
            staticData,
            sealed.projection,
            { turnId = receipt.turnId }
        )
        if resolveErrors then
            return failure(resolveErrors)
        end
        local resolution = resolved.resolution
        if type(resolution) ~= "table"
            or resolution.battleId ~= validatedState.battleId
            or resolution.turnId ~= receipt.turnId
            or resolution.turnNumber ~= validatedState.turnNumber
            or type(resolution.selectedCards) ~= "table"
            or type(resolution.events) ~= "table"
            or type(resolution.afterState) ~= "table" then
            return failure({
                makeError("invalid_turn_resolution", "$.turnResolution", "턴 해결 결과가 권위 상태와 연결되지 않습니다."),
            })
        end

        local projected, projectErrors = callModule(
            "turnEventProjector",
            "projectTurn",
            validatedState,
            staticData,
            resolution
        )
        if projectErrors then
            return failure(projectErrors)
        end
        if type(projected.publicResult) ~= "table" or type(projected.llmEvent) ~= "table" then
            return failure({
                makeError("invalid_event_projection", "$.turnResolution", "턴 사건 투영 결과가 올바르지 않습니다."),
            })
        end

        local historyReport, historyErrors = callModule(
            "battleHistory",
            "attachPublicResult",
            resolution.afterState,
            resolution.turnId,
            projected.publicResult,
            staticData
        )
        if historyErrors then
            return failure(historyErrors)
        end
        if type(historyReport.state) ~= "table" then
            return failure({
                makeError("invalid_public_history_result", "$.runtime.battleHistory", "공개 전투 로그 연결 결과에 상태가 없습니다."),
            })
        end
        resolution.afterState = historyReport.state

        local constructed, constructErrors = callModule(
            "stateSchema",
            "newPendingTurn",
            {
                battleId = resolution.battleId,
                turnId = resolution.turnId,
                beforeState = validatedState,
                projectionReceipt = sealed.receipt,
                selectedCards = resolution.selectedCards,
                turnResult = {
                    events = resolution.events,
                    publicResult = projected.publicResult,
                    llmEvent = projected.llmEvent,
                },
                afterState = resolution.afterState,
            },
            staticData
        )
        if constructErrors then
            return failure(constructErrors)
        end
        local pendingTurn = constructed.value
        if type(pendingTurn) ~= "table" then
            return failure({
                makeError("invalid_pending_result", "$.pendingTurn", "대기 트랜잭션 생성 결과가 올바르지 않습니다."),
            })
        end

        local validatedPending, pendingErrors = validateStoredPending(pendingTurn, staticData)
        if pendingErrors then
            return failure(pendingErrors)
        end
        return pendingSuccess(validatedPending, false)
    end

    local function reusePending(authorityState, staticData, pendingTurn)
        local validatedState, authorityErrors = validateAuthority(authorityState, staticData)
        if authorityErrors then
            return failure(authorityErrors)
        end
        local validatedPending, pendingErrors = validateStoredPending(pendingTurn, staticData)
        if pendingErrors then
            return failure(pendingErrors)
        end
        if validatedState.battleId ~= validatedPending.battleId then
            return failure({
                makeError("pending_battle_mismatch", "$.pendingTurn.battleId", "대기 트랜잭션이 현재 전투에 속하지 않습니다."),
            })
        end
        if validatedState.lastCommittedTurnId == validatedPending.turnId then
            return pendingSuccess(validatedPending, true)
        end
        if not deepEqual(validatedState, validatedPending.beforeState) then
            return failure({
                makeError("pending_authority_conflict", "$.authorityState", "현재 확정 상태가 대기 트랜잭션의 beforeState와 다릅니다."),
            })
        end
        return pendingSuccess(validatedPending, true)
    end

    local function commitPending(authorityState, staticData, pendingTurn)
        local validatedState, authorityErrors = validateAuthority(authorityState, staticData)
        if authorityErrors then
            return failure(authorityErrors)
        end
        local validatedPending, pendingErrors = validateStoredPending(pendingTurn, staticData)
        if pendingErrors then
            return failure(pendingErrors)
        end
        if validatedState.battleId ~= validatedPending.battleId then
            return failure({
                makeError("pending_battle_mismatch", "$.pendingTurn.battleId", "대기 트랜잭션이 현재 전투에 속하지 않습니다."),
            })
        end

        if validatedState.lastCommittedTurnId == validatedPending.turnId then
            local currentCopy, currentError = cloneData(validatedState, "$.authorityState")
            if currentError then
                return failure({ currentError })
            end
            return commitSuccess(currentCopy, validatedPending.turnId, false)
        end
        if not deepEqual(validatedState, validatedPending.beforeState) then
            return failure({
                makeError("pending_authority_conflict", "$.authorityState", "현재 확정 상태가 대기 트랜잭션의 beforeState와 다릅니다."),
            })
        end

        local afterCopy, afterError = cloneData(validatedPending.afterState, "$.pendingTurn.afterState")
        if afterError then
            return failure({ afterError })
        end
        return commitSuccess(afterCopy, validatedPending.turnId, true)
    end

    local arguments = { ... }
    if action == "preparePending" then
        return preparePending(arguments[1], arguments[2], arguments[3])
    elseif action == "reusePending" then
        return reusePending(arguments[1], arguments[2], arguments[3])
    elseif action == "commitPending" then
        return commitPending(arguments[1], arguments[2], arguments[3])
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 battleRuntime 작업입니다."),
    })
end)
