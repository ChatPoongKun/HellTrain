(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991
    local FINGERPRINT_ALGORITHM = "canonical_poly131_137_v1"

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

    local function success(draft, projection)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            draft = draft,
            projection = projection,
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

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
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
                cloneFailure("non_finite_number", path, "NaN과 무한대는 turnDraft에 사용할 수 없습니다.")
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
            cloneFailure("metatable_not_allowed", path, "turnDraft 테이블에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            cloneFailure("circular_reference", path, "순환 참조가 있는 값은 turnDraft에 사용할 수 없습니다.")
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

    local function cloneValue(value, path)
        local ok, copy = pcall(cloneJson, value, path or "$", {})
        if not ok then
            if type(copy) == "table" and copy.code and copy.path and copy.message then
                return nil, copy
            end
            return nil, makeError("clone_failed", path or "$", "값 복제에 실패했습니다: " .. tostring(copy))
        end
        return copy, nil
    end

    local function deepEqual(left, right, active)
        if type(left) ~= type(right) then
            return false
        end
        if type(left) ~= "table" then
            return left == right
        end

        active = active or {}
        active[left] = active[left] or {}
        if active[left][right] then
            return true
        end
        active[left][right] = true

        for key, value in pairs(left) do
            if right[key] == nil and value ~= nil then
                return false
            end
            if not deepEqual(value, right[key], active) then
                return false
            end
        end
        for key, value in pairs(right) do
            if left[key] == nil and value ~= nil then
                return false
            end
        end
        return true
    end

    local function inspectTable(value, path)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            cloneFailure("invalid_table", path, "일반 테이블이어야 합니다.")
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
        if hasNumeric and numericCount ~= maximum then
            cloneFailure("sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
        end
        table.sort(stringKeys)
        return hasNumeric, maximum, stringKeys
    end

    local function canonicalJson(value, path, active)
        local valueType = type(value)
        if valueType == "nil" then
            return "n"
        end
        if valueType == "boolean" then
            return value and "t" or "f"
        end
        if valueType == "number" then
            if not isFinite(value) then
                cloneFailure("non_finite_number", path, "NaN과 무한대는 fingerprint에 사용할 수 없습니다.")
            end
            return "d" .. string.format("%.17g", value) .. ";"
        end
        if valueType == "string" then
            return "s" .. tostring(#value) .. ":" .. value
        end
        if valueType ~= "table" then
            cloneFailure("unsupported_type", path, "fingerprint에 사용할 수 없는 자료형입니다: " .. valueType)
        end

        active = active or {}
        if active[value] then
            cloneFailure("circular_reference", path, "순환 참조가 있는 값은 fingerprint에 사용할 수 없습니다.")
        end
        active[value] = true

        local isArray, length, stringKeys = inspectTable(value, path)
        local parts = {}
        if isArray then
            parts[1] = "["
            for index = 1, length do
                parts[#parts + 1] = canonicalJson(value[index], path .. "[" .. index .. "]", active)
            end
            parts[#parts + 1] = "]"
        else
            parts[1] = "{"
            for _, key in ipairs(stringKeys) do
                parts[#parts + 1] = "k" .. tostring(#key) .. ":" .. key
                parts[#parts + 1] = canonicalJson(value[key], path .. "." .. key, active)
            end
            parts[#parts + 1] = "}"
        end
        active[value] = nil
        return table.concat(parts)
    end

    local function fingerprint(value)
        local ok, canonical = pcall(canonicalJson, value, "$", {})
        if not ok then
            if type(canonical) == "table" and canonical.code and canonical.path and canonical.message then
                return nil, canonical
            end
            return nil, makeError("fingerprint_failed", "$", "전투 상태 fingerprint 생성에 실패했습니다: " .. tostring(canonical))
        end

        local hashA = 0
        local hashB = 0
        for index = 1, #canonical do
            local byte = string.byte(canonical, index)
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        return {
            algorithm = FINGERPRINT_ALGORITHM,
            length = #canonical,
            hashA = hashA,
            hashB = hashB,
        }, nil
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function callModule(scriptName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, makeError(
                "missing_run_script",
                "$.runtime",
                "다른 로어북 모듈을 호출할 runScript가 없습니다."
            )
        end

        local ok, report = pcall(runScript, triggerId, scriptName, moduleAction, ...)
        if not ok then
            return nil, makeError(
                "module_call_failed",
                "$.runtime." .. scriptName,
                scriptName .. " 호출에 실패했습니다: " .. tostring(report)
            )
        end
        if type(report) ~= "table" then
            return nil, makeError(
                "invalid_module_result",
                "$.runtime." .. scriptName,
                scriptName .. "가 구조화 결과를 반환하지 않았습니다."
            )
        end
        if report.ok ~= true then
            local first = type(report.errors) == "table" and report.errors[1] or nil
            return nil, makeError(
                "module_rejected",
                "$.runtime." .. scriptName,
                first and (tostring(first.code) .. " at " .. tostring(first.path) .. ": " .. tostring(first.message))
                    or (scriptName .. "가 작업을 거부했습니다.")
            )
        end
        return report, nil
    end

    local function validateAuthority(state, staticData)
        staticData = normalizeStaticData(staticData)
        if type(staticData) ~= "table" then
            return nil, nil, {
                makeError("invalid_static_data", "$.staticData", "turnDraft에는 전체 정적 데이터가 필요합니다."),
            }
        end

        local report, moduleError = callModule("stateSchema", "validateBattleState", state, staticData)
        if moduleError then
            return nil, nil, { moduleError }
        end
        if report.referencesValidated ~= true then
            return nil, nil, {
                makeError(
                    "static_references_not_validated",
                    "$.staticData",
                    "turnDraft는 참조까지 검증된 전체 정적 데이터가 필요합니다."
                ),
            }
        end
        if state.status ~= "active" then
            return nil, nil, {
                makeError("battle_not_active", "$.state.status", "진행 중인 전투에서만 turnDraft를 만들 수 있습니다."),
            }
        end

        local stateCopy, cloneError = cloneValue(state, "$.state")
        if cloneError then
            return nil, nil, { cloneError }
        end
        return stateCopy, staticData, nil
    end

    local function buildSource(state)
        local stateFingerprint, fingerprintError = fingerprint(state)
        if fingerprintError then
            return nil, fingerprintError
        end
        local source = {
            battleId = state.battleId,
            status = state.status,
            turnNumber = state.turnNumber,
            rng = {
                seed = state.rng.seed,
                cursor = state.rng.cursor,
            },
            fingerprint = stateFingerprint,
        }
        if state.lastCommittedTurnId ~= nil then
            source.lastCommittedTurnId = state.lastCommittedTurnId
        end
        return source, nil
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
                    "turnDraft 스키마에 없는 필드입니다."
                ))
            end
        end
    end

    local function getArrayLength(value, path, errors)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            table.insert(errors, makeError("invalid_array", path, "연속 배열이어야 합니다."))
            return nil
        end
        local count = 0
        local maximum = 0
        for key in pairs(value) do
            if not isInteger(key, 1) then
                table.insert(errors, makeError("invalid_array", path, "연속 배열이어야 합니다."))
                return nil
            end
            count = count + 1
            if key > maximum then
                maximum = key
            end
        end
        if count ~= maximum then
            table.insert(errors, makeError("sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다."))
            return nil
        end
        return maximum
    end

    local function validateIdArray(value, path, errors)
        local length = getArrayLength(value, path, errors)
        if not length then
            return
        end
        local seen = {}
        for index = 1, length do
            local instanceId = value[index]
            if not isRuntimeId(instanceId) then
                table.insert(errors, makeError(
                    "invalid_instance_id",
                    path .. "[" .. index .. "]",
                    "카드 인스턴스 ID 형식이 올바르지 않습니다."
                ))
            elseif seen[instanceId] then
                table.insert(errors, makeError(
                    "duplicate_instance_id",
                    path .. "[" .. index .. "]",
                    "같은 카드 인스턴스를 중복 등록할 수 없습니다."
                ))
            else
                seen[instanceId] = true
            end
        end
    end

    local function validateRng(value, path, errors)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            table.insert(errors, makeError("invalid_rng", path, "RNG 상태가 일반 테이블이 아닙니다."))
            return
        end
        checkAllowedKeys(value, { seed = true, cursor = true }, path, errors)
        if not isSafeInteger(value.seed, 1) then
            table.insert(errors, makeError("invalid_rng_seed", path .. ".seed", "RNG seed는 양의 안전 정수여야 합니다."))
        end
        if not isSafeInteger(value.cursor, 0) then
            table.insert(errors, makeError("invalid_rng_cursor", path .. ".cursor", "RNG cursor는 0 이상의 안전 정수여야 합니다."))
        end
    end

    local function validatePreviewShape(preview, path, errors)
        if type(preview) ~= "table" or getmetatable(preview) ~= nil then
            table.insert(errors, makeError("invalid_preview", path, "preview가 일반 테이블이 아닙니다."))
            return
        end
        checkAllowedKeys(preview, {
            events = true,
            drawnInstanceIds = true,
            availableDrawnInstanceIds = true,
            rng = true,
        }, path, errors)
        validateIdArray(preview.drawnInstanceIds, path .. ".drawnInstanceIds", errors)
        validateIdArray(preview.availableDrawnInstanceIds, path .. ".availableDrawnInstanceIds", errors)
        validateRng(preview.rng, path .. ".rng", errors)

        local eventCount = getArrayLength(preview.events, path .. ".events", errors)
        if eventCount then
            local sourceSeen = {}
            for index = 1, eventCount do
                local event = preview.events[index]
                local eventPath = path .. ".events[" .. index .. "]"
                if type(event) ~= "table" or getmetatable(event) ~= nil then
                    table.insert(errors, makeError("invalid_preview_event", eventPath, "프리뷰 사건이 일반 테이블이 아닙니다."))
                else
                    checkAllowedKeys(event, {
                        sourceInstanceId = true,
                        drawnInstanceIds = true,
                    }, eventPath, errors)
                    if not isRuntimeId(event.sourceInstanceId) then
                        table.insert(errors, makeError(
                            "invalid_instance_id",
                            eventPath .. ".sourceInstanceId",
                            "프리뷰 원본 카드 ID가 올바르지 않습니다."
                        ))
                    elseif sourceSeen[event.sourceInstanceId] then
                        table.insert(errors, makeError(
                            "duplicate_preview_source",
                            eventPath .. ".sourceInstanceId",
                            "같은 카드의 프리뷰 사건이 중복되었습니다."
                        ))
                    else
                        sourceSeen[event.sourceInstanceId] = true
                    end
                    validateIdArray(event.drawnInstanceIds, eventPath .. ".drawnInstanceIds", errors)
                end
            end
        end
    end

    local function validateDraftShape(draft)
        local errors = {}
        if type(draft) ~= "table" or getmetatable(draft) ~= nil then
            return { makeError("invalid_draft", "$.draft", "turnDraft가 일반 테이블이 아닙니다.") }
        end
        checkAllowedKeys(draft, {
            schemaVersion = true,
            kind = true,
            source = true,
            focusedInstanceId = true,
            registeredCardInstanceIds = true,
            preview = true,
        }, "$.draft", errors)
        if draft.schemaVersion ~= SCHEMA_VERSION then
            table.insert(errors, makeError("unsupported_schema", "$.draft.schemaVersion", "지원하지 않는 turnDraft 스키마입니다."))
        end
        if draft.kind ~= "turnDraft" then
            table.insert(errors, makeError("invalid_kind", "$.draft.kind", "kind는 turnDraft여야 합니다."))
        end
        if draft.focusedInstanceId ~= nil and not isRuntimeId(draft.focusedInstanceId) then
            table.insert(errors, makeError(
                "invalid_focus",
                "$.draft.focusedInstanceId",
                "상세 표시 카드 인스턴스 ID가 올바르지 않습니다."
            ))
        end
        validateIdArray(draft.registeredCardInstanceIds, "$.draft.registeredCardInstanceIds", errors)
        validatePreviewShape(draft.preview, "$.draft.preview", errors)

        local source = draft.source
        if type(source) ~= "table" or getmetatable(source) ~= nil then
            table.insert(errors, makeError("invalid_source", "$.draft.source", "turnDraft 원본 표식이 올바르지 않습니다."))
        else
            checkAllowedKeys(source, {
                battleId = true,
                status = true,
                turnNumber = true,
                lastCommittedTurnId = true,
                rng = true,
                fingerprint = true,
            }, "$.draft.source", errors)
            if not isRuntimeId(source.battleId) then
                table.insert(errors, makeError("invalid_battle_id", "$.draft.source.battleId", "전투 ID가 올바르지 않습니다."))
            end
            if source.status ~= "active" then
                table.insert(errors, makeError("invalid_source_status", "$.draft.source.status", "turnDraft 원본은 active 상태여야 합니다."))
            end
            if not isInteger(source.turnNumber, 1) then
                table.insert(errors, makeError("invalid_turn_number", "$.draft.source.turnNumber", "턴 번호가 올바르지 않습니다."))
            end
            if source.lastCommittedTurnId ~= nil and not isRuntimeId(source.lastCommittedTurnId) then
                table.insert(errors, makeError(
                    "invalid_turn_id",
                    "$.draft.source.lastCommittedTurnId",
                    "마지막 확정 턴 ID가 올바르지 않습니다."
                ))
            end
            validateRng(source.rng, "$.draft.source.rng", errors)

            local stateFingerprint = source.fingerprint
            if type(stateFingerprint) ~= "table" or getmetatable(stateFingerprint) ~= nil then
                table.insert(errors, makeError(
                    "invalid_fingerprint",
                    "$.draft.source.fingerprint",
                    "전투 상태 fingerprint가 올바르지 않습니다."
                ))
            else
                checkAllowedKeys(stateFingerprint, {
                    algorithm = true,
                    length = true,
                    hashA = true,
                    hashB = true,
                }, "$.draft.source.fingerprint", errors)
                if stateFingerprint.algorithm ~= FINGERPRINT_ALGORITHM then
                    table.insert(errors, makeError(
                        "invalid_fingerprint_algorithm",
                        "$.draft.source.fingerprint.algorithm",
                        "지원하지 않는 fingerprint 알고리즘입니다."
                    ))
                end
                for _, field in ipairs({ "length", "hashA", "hashB" }) do
                    if not isSafeInteger(stateFingerprint[field], 0) then
                        table.insert(errors, makeError(
                            "invalid_fingerprint_value",
                            "$.draft.source.fingerprint." .. field,
                            "fingerprint 값은 0 이상의 안전 정수여야 합니다."
                        ))
                    end
                end
            end
        end
        return errors
    end

    local function findInstance(state, instanceId)
        for _, instance in ipairs(state.cardInstances) do
            if instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function findCard(staticData, state, instanceId)
        local instance = findInstance(state, instanceId)
        if not instance then
            return nil, nil
        end
        return instance, staticData.cards[instance.cardId]
    end

    local function hasMechanism(card, mechanismId)
        for _, currentId in ipairs(type(card) == "table" and type(card.mechanisms) == "table" and card.mechanisms or {}) do
            if currentId == mechanismId then
                return true
            end
        end
        return false
    end

    local function copyArray(values)
        local copy = {}
        for index, value in ipairs(values or {}) do
            copy[index] = value
        end
        return copy
    end

    local function appendAll(target, values)
        for _, value in ipairs(values or {}) do
            table.insert(target, value)
        end
    end

    local function emptyPreview(state)
        return {
            events = {},
            drawnInstanceIds = {},
            availableDrawnInstanceIds = {},
            rng = {
                seed = state.rng.seed,
                cursor = state.rng.cursor,
            },
        }
    end

    local function replaySelection(state, staticData, registeredIds, dropUnavailable)
        local working, cloneError = cloneValue(state, "$.state")
        if cloneError then
            return nil, { cloneError }
        end

        local keptIds = {}
        local previewEvents = {}
        local drawnInstanceIds = {}
        local mainActionCount = 0
        local mainActionIndex = nil

        for inputIndex, instanceId in ipairs(registeredIds) do
            local instance, card = findCard(staticData, working, instanceId)
            local available = instance and instance.owner == "player" and instance.zone == "hand"
            if not available then
                if not dropUnavailable then
                    return nil, {
                        makeError(
                            "card_not_available",
                            "$.draft.registeredCardInstanceIds[" .. inputIndex .. "]",
                            "등록 카드는 권위 손패 또는 앞선 프리뷰 드로우에 있어야 합니다."
                        ),
                    }
                end
            elseif type(card) ~= "table" then
                return nil, {
                    makeError(
                        "unknown_card",
                        "$.draft.registeredCardInstanceIds[" .. inputIndex .. "]",
                        "정적 DB에서 등록 카드를 찾을 수 없습니다."
                    ),
                }
            else
                table.insert(keptIds, instanceId)
                if not hasMechanism(card, "chain") then
                    mainActionCount = mainActionCount + 1
                    mainActionIndex = #keptIds
                    if mainActionCount > 1 then
                        return nil, {
                            makeError(
                                "multiple_main_actions",
                                "$.draft.registeredCardInstanceIds",
                                "주 행동 카드는 하나만 등록할 수 있습니다."
                            ),
                        }
                    end
                end

                local effectReport, effectError = callModule(
                    "effectEngine",
                    "evaluateSelectionPreview",
                    staticData,
                    working,
                    instanceId
                )
                if effectError then
                    return nil, { effectError }
                end

                local moveReport, moveError = callModule(
                    "cardZones",
                    "moveHandToUsed",
                    working,
                    instanceId
                )
                if moveError then
                    return nil, { moveError }
                end
                working = moveReport.state

                if #effectReport.commands > 0 then
                    local eventDrawn = {}
                    for _, command in ipairs(effectReport.commands) do
                        if command.op ~= "draw_cards" or command.target ~= "player" then
                            return nil, {
                                makeError(
                                    "unsupported_preview_command",
                                    "$.runtime.effectEngine",
                                    "turnDraft v1이 적용할 수 없는 선택 프리뷰 명령입니다."
                                ),
                            }
                        end
                        local drawReport, drawError = callModule(
                            "cardZones",
                            "draw",
                            working,
                            "player",
                            command.amount
                        )
                        if drawError then
                            return nil, { drawError }
                        end
                        working = drawReport.state
                        appendAll(eventDrawn, drawReport.drawnInstanceIds)
                        appendAll(drawnInstanceIds, drawReport.drawnInstanceIds)
                    end
                    table.insert(previewEvents, {
                        sourceInstanceId = instanceId,
                        drawnInstanceIds = eventDrawn,
                    })
                end
            end
        end

        if mainActionIndex and mainActionIndex ~= #keptIds then
            return nil, {
                makeError(
                    "main_action_not_last",
                    "$.draft.registeredCardInstanceIds",
                    "연계 카드는 주 행동보다 앞에 있어야 합니다."
                ),
            }
        end

        -- 등록된 프리뷰 카드도 다시 클릭해 취소할 수 있어야 하므로 draft UI에서는
        -- workingState의 used 이동과 무관하게 이 분기에서 뽑힌 카드 전부를 유지한다.
        local availableDrawnInstanceIds = copyArray(drawnInstanceIds)

        working.selection = {
            playerCardInstanceIds = copyArray(keptIds),
        }
        return {
            workingState = working,
            registeredCardInstanceIds = keptIds,
            mainActionCount = mainActionCount,
            preview = {
                events = previewEvents,
                drawnInstanceIds = drawnInstanceIds,
                availableDrawnInstanceIds = availableDrawnInstanceIds,
                rng = {
                    seed = working.rng.seed,
                    cursor = working.rng.cursor,
                },
            },
        }, nil
    end

    local function visibleInstanceSet(state, preview)
        local visible = {}
        for _, instance in ipairs(state.cardInstances) do
            if instance.owner == "player" and instance.zone == "hand" then
                visible[instance.instanceId] = true
            end
        end
        for _, instanceId in ipairs(preview.drawnInstanceIds) do
            visible[instanceId] = true
        end
        return visible
    end

    local function validateInternal(state, staticData, draft)
        local stateCopy, normalizedStaticData, authorityErrors = validateAuthority(state, staticData)
        if authorityErrors then
            return nil, authorityErrors
        end

        local draftCopy, cloneError = cloneValue(draft, "$.draft")
        if cloneError then
            return nil, { cloneError }
        end
        local shapeErrors = validateDraftShape(draftCopy)
        if #shapeErrors > 0 then
            return nil, shapeErrors
        end

        local expectedSource, sourceError = buildSource(stateCopy)
        if sourceError then
            return nil, { sourceError }
        end
        if not deepEqual(draftCopy.source, expectedSource) then
            return nil, {
                makeError(
                    "draft_stale",
                    "$.draft.source",
                    "turnDraft를 만든 뒤 권위 전투 상태가 변경되었습니다. 자동 재기준화하지 않습니다."
                ),
            }
        end

        local replay, replayErrors = replaySelection(
            stateCopy,
            normalizedStaticData,
            draftCopy.registeredCardInstanceIds,
            false
        )
        if replayErrors then
            return nil, replayErrors
        end
        if not deepEqual(draftCopy.preview, replay.preview) then
            return nil, {
                makeError(
                    "preview_mismatch",
                    "$.draft.preview",
                    "저장된 선택 프리뷰가 같은 권위 상태에서 다시 계산한 결과와 다릅니다."
                ),
            }
        end

        if draftCopy.focusedInstanceId ~= nil then
            local visible = visibleInstanceSet(stateCopy, replay.preview)
            if not visible[draftCopy.focusedInstanceId] then
                return nil, {
                    makeError(
                        "focused_card_not_visible",
                        "$.draft.focusedInstanceId",
                        "상세 표시 카드는 현재 손패 또는 프리뷰에 있어야 합니다."
                    ),
                }
            end
        end

        return {
            state = stateCopy,
            staticData = normalizedStaticData,
            draft = draftCopy,
            replay = replay,
        }, nil
    end

    local function buildDraft(state, registeredIds, focusedInstanceId, replay)
        local source, sourceError = buildSource(state)
        if sourceError then
            return nil, sourceError
        end
        local draft = {
            schemaVersion = SCHEMA_VERSION,
            kind = "turnDraft",
            source = source,
            registeredCardInstanceIds = copyArray(registeredIds),
            preview = replay and replay.preview or emptyPreview(state),
        }
        if focusedInstanceId ~= nil then
            draft.focusedInstanceId = focusedInstanceId
        end
        return draft, nil
    end

    local function newDraft(state, staticData)
        local stateCopy, normalizedStaticData, errors = validateAuthority(state, staticData)
        if errors then
            return failure(errors)
        end
        local replay, replayErrors = replaySelection(stateCopy, normalizedStaticData, {}, false)
        if replayErrors then
            return failure(replayErrors)
        end
        local draft, draftError = buildDraft(stateCopy, {}, nil, replay)
        if draftError then
            return failure({ draftError })
        end
        return success(draft)
    end

    local function validateDraft(state, staticData, draft)
        local validated, errors = validateInternal(state, staticData, draft)
        if errors then
            return failure(errors)
        end
        return success(validated.draft)
    end

    local function focusCard(state, staticData, draft, instanceId)
        local validated, errors = validateInternal(state, staticData, draft)
        if errors then
            return failure(errors)
        end
        if not isRuntimeId(instanceId) then
            return failure({
                makeError("invalid_instance_id", "$.instanceId", "상세 표시 카드 ID가 올바르지 않습니다."),
            })
        end
        local visible = visibleInstanceSet(validated.state, validated.replay.preview)
        if not visible[instanceId] then
            return failure({
                makeError(
                    "card_not_visible",
                    "$.instanceId",
                    "상세 표시 카드는 현재 손패 또는 프리뷰에 있어야 합니다."
                ),
            })
        end

        local nextDraft, draftError = buildDraft(
            validated.state,
            validated.draft.registeredCardInstanceIds,
            instanceId,
            validated.replay
        )
        if draftError then
            return failure({ draftError })
        end
        return success(nextDraft)
    end

    local function registeredSet(values)
        local set = {}
        for _, instanceId in ipairs(values) do
            set[instanceId] = true
        end
        return set
    end

    local function baseHandSet(state)
        local set = {}
        for _, instance in ipairs(state.cardInstances) do
            if instance.owner == "player" and instance.zone == "hand" then
                set[instance.instanceId] = true
            end
        end
        return set
    end

    local function registerCard(state, staticData, draft, instanceId)
        local validated, errors = validateInternal(state, staticData, draft)
        if errors then
            return failure(errors)
        end
        if not isRuntimeId(instanceId) then
            return failure({
                makeError("invalid_instance_id", "$.instanceId", "등록 카드 ID가 올바르지 않습니다."),
            })
        end

        local visible = visibleInstanceSet(validated.state, validated.replay.preview)
        if not visible[instanceId] then
            return failure({
                makeError(
                    "card_not_visible",
                    "$.instanceId",
                    "등록 카드는 현재 손패 또는 프리뷰에 있어야 합니다."
                ),
            })
        end

        local currentIds = validated.draft.registeredCardInstanceIds
        if registeredSet(currentIds)[instanceId] then
            return success(validated.draft)
        end

        local targetInstance, targetCard = findCard(validated.staticData, validated.state, instanceId)
        if not targetInstance then
            targetInstance = findInstance(validated.replay.workingState, instanceId)
            targetCard = targetInstance and validated.staticData.cards[targetInstance.cardId] or nil
        end
        if type(targetCard) ~= "table" then
            return failure({
                makeError("unknown_card", "$.instanceId", "정적 DB에서 등록 카드를 찾을 수 없습니다."),
            })
        end

        local originalHand = baseHandSet(validated.state)
        local hasSpeculativeRegisteredCard = false
        for _, currentId in ipairs(currentIds) do
            if not originalHand[currentId] then
                hasSpeculativeRegisteredCard = true
                break
            end
        end

        local nextIds = {}
        if originalHand[instanceId] and hasSpeculativeRegisteredCard then
            nextIds = { instanceId }
        else
            local chainIds = {}
            local mainId = nil
            for _, currentId in ipairs(currentIds) do
                local _, currentCard = findCard(validated.staticData, validated.replay.workingState, currentId)
                if not currentCard then
                    local sourceInstance = findInstance(validated.state, currentId)
                    currentCard = sourceInstance and validated.staticData.cards[sourceInstance.cardId] or nil
                end
                if currentCard and hasMechanism(currentCard, "chain") then
                    table.insert(chainIds, currentId)
                else
                    mainId = currentId
                end
            end

            if hasMechanism(targetCard, "chain") then
                appendAll(nextIds, chainIds)
                table.insert(nextIds, instanceId)
                if mainId then
                    table.insert(nextIds, mainId)
                end
            else
                appendAll(nextIds, chainIds)
                table.insert(nextIds, instanceId)
            end
        end

        local replay, replayErrors = replaySelection(validated.state, validated.staticData, nextIds, false)
        if replayErrors then
            return failure(replayErrors)
        end
        local nextDraft, draftError = buildDraft(validated.state, nextIds, instanceId, replay)
        if draftError then
            return failure({ draftError })
        end
        return success(nextDraft)
    end

    local function cancelCard(state, staticData, draft, instanceId)
        local validated, errors = validateInternal(state, staticData, draft)
        if errors then
            return failure(errors)
        end
        if not isRuntimeId(instanceId) then
            return failure({
                makeError("invalid_instance_id", "$.instanceId", "취소 카드 ID가 올바르지 않습니다."),
            })
        end

        local found = false
        local remainingIds = {}
        for _, currentId in ipairs(validated.draft.registeredCardInstanceIds) do
            if currentId == instanceId then
                found = true
            else
                table.insert(remainingIds, currentId)
            end
        end
        if not found then
            return success(validated.draft)
        end

        local replay, replayErrors = replaySelection(
            validated.state,
            validated.staticData,
            remainingIds,
            true
        )
        if replayErrors then
            return failure(replayErrors)
        end

        local focusedInstanceId = validated.draft.focusedInstanceId
        local visible = visibleInstanceSet(validated.state, replay.preview)
        if focusedInstanceId ~= nil and not visible[focusedInstanceId] then
            focusedInstanceId = nil
        end
        local nextDraft, draftError = buildDraft(
            validated.state,
            replay.registeredCardInstanceIds,
            focusedInstanceId,
            replay
        )
        if draftError then
            return failure({ draftError })
        end
        return success(nextDraft)
    end

    local function clickCard(state, staticData, draft, instanceId)
        local validated, errors = validateInternal(state, staticData, draft)
        if errors then
            return failure(errors)
        end
        if not isRuntimeId(instanceId) then
            return failure({
                makeError("invalid_instance_id", "$.instanceId", "클릭 카드 ID가 올바르지 않습니다."),
            })
        end

        if registeredSet(validated.draft.registeredCardInstanceIds)[instanceId] then
            return cancelCard(state, staticData, validated.draft, instanceId)
        end
        if validated.draft.focusedInstanceId == instanceId then
            return registerCard(state, staticData, validated.draft, instanceId)
        end
        return focusCard(state, staticData, validated.draft, instanceId)
    end

    local function project(state, staticData, draft)
        local validated, errors = validateInternal(state, staticData, draft)
        if errors then
            return failure(errors)
        end

        local selectedIds = copyArray(validated.draft.registeredCardInstanceIds)
        local mode = "pass"
        if #selectedIds > 0 then
            mode = validated.replay.mainActionCount == 1 and "action" or "chain_pass"
        end
        local workingState, stateCloneError = cloneValue(validated.replay.workingState, "$.workingState")
        if stateCloneError then
            return failure({ stateCloneError })
        end
        local preview, previewCloneError = cloneValue(validated.replay.preview, "$.preview")
        if previewCloneError then
            return failure({ previewCloneError })
        end
        local source, sourceCloneError = cloneValue(validated.draft.source, "$.source")
        if sourceCloneError then
            return failure({ sourceCloneError })
        end

        local projection = {
            schemaVersion = SCHEMA_VERSION,
            kind = "turnDraftProjection",
            battleId = validated.state.battleId,
            turnNumber = validated.state.turnNumber,
            mode = mode,
            hasMainAction = validated.replay.mainActionCount == 1,
            passAfterChain = #selectedIds > 0 and validated.replay.mainActionCount == 0,
            selectedCardInstanceIds = selectedIds,
            source = source,
            preview = preview,
            projectedRng = {
                seed = workingState.rng.seed,
                cursor = workingState.rng.cursor,
            },
            workingState = workingState,
        }
        return success(validated.draft, projection)
    end

    local arguments = { ... }
    local actions = {
        newDraft = newDraft,
        validate = validateDraft,
        focusCard = focusCard,
        registerCard = registerCard,
        cancelCard = cancelCard,
        clickCard = clickCard,
        project = project,
    }
    local handler = actions[action]
    if not handler then
        return failure({
            makeError(
                "unknown_action",
                "$.action",
                "지원하지 않는 turnDraft 작업입니다: " .. tostring(action)
            ),
        })
    end

    return handler(arguments[1], arguments[2], arguments[3], arguments[4])
end)
