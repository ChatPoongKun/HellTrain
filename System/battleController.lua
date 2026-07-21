(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local ACTIVE_REQUEST_SCHEMA_VERSION = 2
    local VIEW_NAME = "battleView"
    local SAY_NOTHING = "*says nothing*"
    local CHAT_FINGERPRINT_ALGORITHM = "canonical_poly131_137_chat_v1"

    local KEYS = {
        authority = "battleRuntimeV1.authority",
        draft = "battleRuntimeV1.draft",
        pending = "battleRuntimeV1.pending",
        lastCommittedPending = "battleRuntimeV1.lastCommittedPending",
        activeRequest = "battleRuntimeV1.activeRequest",
    }

    local function permitCanonicalBattleView(purpose, viewName)
        return purpose == "dataBridgeCanonicalV1" and viewName == VIEW_NAME
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

    local function success(fields)
        local report = {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
        }
        for key, value in pairs(fields or {}) do
            report[key] = value
        end
        return report
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

    local function objectPath(path, key)
        if string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", key) .. "]"
    end

    local function cloneJson(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "유한하지 않은 숫자는 컨트롤러 데이터에 사용할 수 없습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError(
                "unsupported_type",
                path,
                "JSON 컨트롤러 데이터에 사용할 수 없는 자료형입니다: " .. valueType
            )
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "컨트롤러 데이터에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조는 컨트롤러 데이터에 사용할 수 없습니다.")
        end
        active[value] = true

        local hasNumeric = false
        local hasString = false
        local numericCount = 0
        local maximum = 0
        for key in pairs(value) do
            if type(key) == "number" then
                hasNumeric = true
                if not isInteger(key, 1) then
                    active[value] = nil
                    return nil, makeError("invalid_array_index", path, "배열 인덱스는 1 이상의 정수여야 합니다.")
                end
                numericCount = numericCount + 1
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
                local itemCopy, itemError = cloneJson(value[index], path .. "[" .. index .. "]", active)
                if itemError then
                    active[value] = nil
                    return nil, itemError
                end
                copy[index] = itemCopy
            end
        else
            for key, item in pairs(value) do
                local itemCopy, itemError = cloneJson(item, objectPath(path, key), active)
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
        local seen = active[left]
        if seen ~= nil then
            return seen == right
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

    local function canonicalFailure(code, path, message)
        error(makeError(code, path, message), 0)
    end

    local function inspectCanonicalTable(value, path)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            canonicalFailure("invalid_fingerprint_table", path, "fingerprint 대상은 일반 테이블이어야 합니다.")
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
                    canonicalFailure("invalid_fingerprint_array_index", path, "fingerprint 배열 인덱스는 1 이상의 정수여야 합니다.")
                end
                maximum = math.max(maximum, key)
            elseif type(key) == "string" then
                hasString = true
                stringKeys[#stringKeys + 1] = key
            else
                canonicalFailure("invalid_fingerprint_object_key", path, "fingerprint 객체 키는 문자열이어야 합니다.")
            end
        end
        if hasNumeric and hasString then
            canonicalFailure("mixed_fingerprint_table", path, "fingerprint에는 숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
        end
        if hasNumeric and numericCount ~= maximum then
            canonicalFailure("sparse_fingerprint_array", path, "fingerprint 배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
        end
        table.sort(stringKeys)
        return hasNumeric, maximum, stringKeys
    end

    local function canonicalJson(value, path, active)
        local valueType = type(value)
        if valueType == "nil" then return "n" end
        if valueType == "boolean" then return value and "t" or "f" end
        if valueType == "number" then
            if not isFinite(value) then
                canonicalFailure("non_finite_fingerprint_number", path, "유한하지 않은 숫자는 fingerprint에 사용할 수 없습니다.")
            end
            return "d" .. string.format("%.17g", value) .. ";"
        end
        if valueType == "string" then
            return "s" .. tostring(#value) .. ":" .. value
        end
        if valueType ~= "table" then
            canonicalFailure("unsupported_fingerprint_type", path, "fingerprint에 사용할 수 없는 자료형입니다: " .. valueType)
        end
        active = active or {}
        if active[value] then
            canonicalFailure("circular_fingerprint_value", path, "순환 참조는 fingerprint에 사용할 수 없습니다.")
        end
        active[value] = true
        local isArray, length, stringKeys = inspectCanonicalTable(value, path)
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
                parts[#parts + 1] = canonicalJson(value[key], objectPath(path, key), active)
            end
            parts[#parts + 1] = "}"
        end
        active[value] = nil
        return table.concat(parts)
    end

    local function fingerprintChatRange(chat, firstIndex, count, path)
        if type(chat) ~= "table" or not isInteger(firstIndex, 1) or not isInteger(count, 0) then
            return nil, makeError("invalid_chat_fingerprint_range", path, "채팅 fingerprint 범위가 올바르지 않습니다.")
        end
        if count > 0 and firstIndex + count - 1 > #chat then
            return nil, makeError("chat_fingerprint_range_out_of_bounds", path, "채팅 fingerprint 범위가 대화 길이를 벗어났습니다.")
        end
        local ok, canonical = pcall(function()
            local parts = { "[" }
            for offset = 0, count - 1 do
                parts[#parts + 1] = canonicalJson(chat[firstIndex + offset], path .. "[" .. offset .. "]", {})
            end
            parts[#parts + 1] = "]"
            return table.concat(parts)
        end)
        if not ok then
            if type(canonical) == "table" and canonical.code and canonical.path and canonical.message then
                return nil, canonical
            end
            return nil, makeError("chat_fingerprint_failed", path, "채팅 fingerprint 생성에 실패했습니다: " .. tostring(canonical))
        end
        local hashA = 0
        local hashB = 0
        for index = 1, #canonical do
            local byte = string.byte(canonical, index)
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        return {
            algorithm = CHAT_FINGERPRINT_ALGORITHM,
            length = #canonical,
            hashA = hashA,
            hashB = hashB,
        }, nil
    end

    local function fingerprintsEqual(left, right)
        return type(left) == "table"
            and type(right) == "table"
            and left.algorithm == right.algorithm
            and left.length == right.length
            and left.hashA == right.hashA
            and left.hashB == right.hashB
    end

    local function validateFingerprint(value, path, errors)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            errors[#errors + 1] = makeError("invalid_chat_fingerprint", path, "채팅 fingerprint가 일반 객체가 아닙니다.")
            return false
        end
        local allowed = { algorithm = true, length = true, hashA = true, hashB = true }
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_chat_fingerprint_field", path .. "." .. tostring(key), "채팅 fingerprint에 알 수 없는 필드가 있습니다.")
            end
        end
        if value.algorithm ~= CHAT_FINGERPRINT_ALGORITHM then
            errors[#errors + 1] = makeError("invalid_chat_fingerprint_algorithm", path .. ".algorithm", "지원하지 않는 채팅 fingerprint 알고리즘입니다.")
        end
        for _, field in ipairs({ "length", "hashA", "hashB" }) do
            if not isInteger(value[field], 0) then
                errors[#errors + 1] = makeError("invalid_chat_fingerprint", path .. "." .. field, "채팅 fingerprint 수치는 0 이상의 정수여야 합니다.")
            end
        end
        return #errors == 0
    end

    local function appendNestedErrors(target, moduleName, report)
        if type(report) == "table" and type(report.errors) == "table" then
            for index, item in ipairs(report.errors) do
                if type(item) == "table" then
                    target[#target + 1] = makeError(
                        type(item.code) == "string" and item.code or "nested_error",
                        type(item.path) == "string" and item.path or ("$.runtime." .. moduleName),
                        type(item.message) == "string"
                            and item.message
                            or (moduleName .. " 오류 " .. index .. "에 설명이 없습니다.")
                    )
                else
                    target[#target + 1] = makeError(
                        "invalid_nested_error",
                        "$.runtime." .. moduleName .. ".errors[" .. index .. "]",
                        "하위 모듈 오류 항목이 객체가 아닙니다."
                    )
                end
            end
        end
        if #target == 0 then
            target[1] = makeError(
                "module_failed_without_errors",
                "$.runtime." .. moduleName,
                moduleName .. "이 오류 상세 없이 실패했습니다."
            )
        end
    end

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError("runtime_unavailable", "$.runtime", "runScript 실행기를 찾을 수 없습니다."),
            }
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok then
            return nil, {
                makeError(
                    "module_call_error",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. " 호출 중 오류가 발생했습니다: " .. tostring(report)
                ),
            }
        end
        if type(report) ~= "table" or getmetatable(report) ~= nil then
            return nil, {
                makeError(
                    "invalid_module_result",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. "이 일반 테이블 결과를 반환하지 않았습니다."
                ),
            }
        end
        local envelopeVersionOk = report.schemaVersion == SCHEMA_VERSION
            or (moduleName == "dataBridge"
                and report.schemaVersion == nil
                and report.wireFormat == "cbs-json-nodes-v1")
        local envelopeErrorsOk = type(report.errors) == "table"
            or (moduleName == "dataBridge" and report.ok == true and report.errors == nil)
        if not envelopeVersionOk
            or not envelopeErrorsOk
            or (report.ok ~= true and report.ok ~= false) then
            return nil, {
                makeError(
                    "invalid_module_envelope",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. " 결과 envelope가 올바르지 않습니다."
                ),
            }
        end
        if report.ok ~= true then
            local errors = {}
            appendNestedErrors(errors, moduleName, report)
            return nil, errors
        end
        if type(report.errors) == "table" and #report.errors ~= 0 then
            return nil, {
                makeError(
                    "success_with_errors",
                    "$.runtime." .. moduleName .. ".errors",
                    "성공한 하위 모듈 결과에 오류가 포함되어 있습니다."
                ),
            }
        end
        return report, nil
    end

    local function loadStaticData()
        local report, errors = callModule("staticData", "loadAll")
        if errors then
            return nil, errors
        end
        if type(report.data) ~= "table" or getmetatable(report.data) ~= nil then
            return nil, {
                makeError("missing_static_data", "$.runtime.staticData.data", "검증된 전체 정적 데이터가 없습니다."),
            }
        end
        return report.data, nil
    end

    local function readStored(key, required)
        if type(getState) ~= "function" then
            return nil, {
                makeError("state_read_unavailable", "$.host.getState", "getState 호스트 함수를 찾을 수 없습니다."),
            }
        end
        local ok, value = pcall(getState, triggerId, key)
        if not ok then
            return nil, {
                makeError("state_read_failed", "$.state[" .. string.format("%q", key) .. "]", "저장 상태를 읽지 못했습니다: " .. tostring(value)),
            }
        end
        if value == nil then
            if required then
                return nil, {
                    makeError("missing_persistent_state", "$.state[" .. string.format("%q", key) .. "]", "필수 저장 상태가 없습니다."),
                }
            end
            return nil, nil
        end
        local copy, cloneError = cloneJson(value, "$.state[" .. string.format("%q", key) .. "]")
        if cloneError then
            return nil, { cloneError }
        end
        return copy, nil
    end

    local function writeStored(key, value)
        if type(setState) ~= "function" or type(getState) ~= "function" then
            return {
                makeError("state_write_unavailable", "$.host.setState", "setState/getState 호스트 함수를 찾을 수 없습니다."),
            }
        end
        local storedCopy, cloneError = cloneJson(value, "$.state[" .. string.format("%q", key) .. "]")
        if cloneError then
            return { cloneError }
        end
        local writeOk, writeError = pcall(setState, triggerId, key, storedCopy)
        if not writeOk then
            return {
                makeError("state_write_failed", "$.state[" .. string.format("%q", key) .. "]", "저장 상태 쓰기에 실패했습니다: " .. tostring(writeError)),
            }
        end
        local readOk, readValue = pcall(getState, triggerId, key)
        if not readOk then
            return {
                makeError("state_verify_read_failed", "$.state[" .. string.format("%q", key) .. "]", "쓰기 뒤 저장 상태를 다시 읽지 못했습니다: " .. tostring(readValue)),
            }
        end
        if not deepEqual(storedCopy, readValue) then
            return {
                makeError("state_write_not_persisted", "$.state[" .. string.format("%q", key) .. "]", "쓰기 뒤 읽은 상태가 저장하려던 값과 다릅니다."),
            }
        end
        return nil
    end

    local function makeTurnId(state)
        if type(state) ~= "table" or not isRuntimeId(state.battleId) or not isInteger(state.turnNumber, 1) then
            return nil, {
                makeError("invalid_turn_identity", "$.authorityState", "battleId와 현재 턴 번호로 turnId를 만들 수 없습니다."),
            }
        end
        return string.format("%s-turn-%03d", state.battleId, state.turnNumber), nil
    end

    local function expectedPublicMarker(turnNumber)
        return "[전투 턴 " .. tostring(turnNumber) .. "] 이번 턴에 실제로 벌어진 일을 하나의 장면으로 이어서 묘사한다."
    end

    local function validatePromptMessage(message, path)
        if type(message) ~= "table" or getmetatable(message) ~= nil then
            return makeError("invalid_prompt_message", path, "프롬프트 메시지는 일반 객체여야 합니다.")
        end
        for key in pairs(message) do
            if key ~= "role" and key ~= "content" then
                return makeError("unknown_prompt_message_field", path .. "." .. tostring(key), "프롬프트 메시지에 알 수 없는 필드가 있습니다.")
            end
        end
        if message.role ~= "system" or type(message.content) ~= "string" or message.content == "" then
            return makeError("invalid_prompt_message", path, "프롬프트 메시지는 비어 있지 않은 system 메시지여야 합니다.")
        end
        return nil
    end

    local function formatPending(pendingTurn, staticData)
        local report, errors = callModule(
            "turnPromptFormatter",
            "formatPending",
            pendingTurn,
            staticData
        )
        if errors then
            return nil, errors
        end
        local messageError = validatePromptMessage(report.message, "$.runtime.turnPromptFormatter.message")
        if messageError then
            return nil, { messageError }
        end
        local turnNumber = type(pendingTurn) == "table"
            and type(pendingTurn.beforeState) == "table"
            and pendingTurn.beforeState.turnNumber
            or nil
        if not isInteger(turnNumber, 1) then
            return nil, {
                makeError("invalid_pending_turn_number", "$.pendingTurn.beforeState.turnNumber", "pendingTurn의 공개 턴 번호가 올바르지 않습니다."),
            }
        end
        if report.publicMarker ~= expectedPublicMarker(turnNumber) then
            return nil, {
                makeError("invalid_public_marker", "$.runtime.turnPromptFormatter.publicMarker", "formatter가 계약된 공개 턴 마커를 반환하지 않았습니다."),
            }
        end
        local messageCopy, cloneError = cloneJson(report.message, "$.runtime.turnPromptFormatter.message")
        if cloneError then
            return nil, { cloneError }
        end
        return {
            message = messageCopy,
            publicMarker = report.publicMarker,
            turnNumber = turnNumber,
        }, nil
    end

    local function validateChatAnchor(anchor, path, errors)
        if type(anchor) ~= "table" or getmetatable(anchor) ~= nil then
            errors[#errors + 1] = makeError("invalid_chat_anchor", path, "채팅 anchor가 일반 객체가 아닙니다.")
            return
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            prefixMessageCount = true,
            markerIndex = true,
            prefixFingerprint = true,
        }
        for key in pairs(anchor) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_chat_anchor_field", path .. "." .. tostring(key), "채팅 anchor에 알 수 없는 필드가 있습니다.")
            end
        end
        if anchor.schemaVersion ~= 1 or anchor.kind ~= "battleChatAnchor" then
            errors[#errors + 1] = makeError("invalid_chat_anchor_schema", path, "채팅 anchor 스키마가 올바르지 않습니다.")
        end
        if not isInteger(anchor.prefixMessageCount, 0) then
            errors[#errors + 1] = makeError("invalid_chat_anchor_count", path .. ".prefixMessageCount", "anchor prefix 메시지 수가 올바르지 않습니다.")
        end
        if not isInteger(anchor.markerIndex, 0) or anchor.markerIndex ~= anchor.prefixMessageCount then
            errors[#errors + 1] = makeError("invalid_chat_anchor_index", path .. ".markerIndex", "0-based 마커 위치가 prefix 메시지 수와 일치하지 않습니다.")
        end
        validateFingerprint(anchor.prefixFingerprint, path .. ".prefixFingerprint", errors)
    end

    local function validateOutputObserved(receipt, binding, path, errors)
        if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then
            errors[#errors + 1] = makeError("invalid_output_observed", path, "출력 관측 영수증이 일반 객체가 아닙니다.")
            return
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            attemptNumber = true,
            responseIndex = true,
            responseFingerprint = true,
        }
        for key in pairs(receipt) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_output_observed_field", path .. "." .. tostring(key), "출력 관측 영수증에 알 수 없는 필드가 있습니다.")
            end
        end
        if receipt.schemaVersion ~= 1 or receipt.kind ~= "battleOutputObserved" then
            errors[#errors + 1] = makeError("invalid_output_observed_schema", path, "출력 관측 영수증 스키마가 올바르지 않습니다.")
        end
        if receipt.attemptNumber ~= binding.attemptNumber then
            errors[#errors + 1] = makeError("output_observed_attempt_mismatch", path .. ".attemptNumber", "출력 관측 영수증의 시도 번호가 요청과 다릅니다.")
        end
        local expectedIndex = type(binding.chatAnchor) == "table" and binding.chatAnchor.markerIndex + 1 or nil
        if not isInteger(receipt.responseIndex, 0) or receipt.responseIndex ~= expectedIndex then
            errors[#errors + 1] = makeError("output_observed_index_mismatch", path .. ".responseIndex", "출력 관측 위치가 채팅 anchor 다음 위치와 다릅니다.")
        end
        validateFingerprint(receipt.responseFingerprint, path .. ".responseFingerprint", errors)
    end

    local function validateCleanupReceipt(receipt, binding, path, errors)
        if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then
            errors[#errors + 1] = makeError("invalid_cleanup_receipt", path, "복구 정리 영수증이 일반 객체가 아닙니다.")
            return
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            mode = true,
            originalPhase = true,
            attemptNumber = true,
            responseIndex = true,
            responsePresent = true,
            responseFingerprint = true,
            initialFillerCount = true,
        }
        for key in pairs(receipt) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_cleanup_receipt_field", path .. "." .. tostring(key), "복구 정리 영수증에 알 수 없는 필드가 있습니다.")
            end
        end
        if receipt.schemaVersion ~= 1 or receipt.kind ~= "battleRecoveringCleanup" then
            errors[#errors + 1] = makeError("invalid_cleanup_receipt_schema", path, "복구 정리 영수증 스키마가 올바르지 않습니다.")
        end
        if receipt.mode ~= "retry" and receipt.mode ~= "resumeCommit" then
            errors[#errors + 1] = makeError("invalid_cleanup_mode", path .. ".mode", "복구 정리 mode가 올바르지 않습니다.")
        end
        if receipt.originalPhase ~= "inFlight" and receipt.originalPhase ~= "requestInjected" then
            errors[#errors + 1] = makeError("invalid_cleanup_phase", path .. ".originalPhase", "복구 정리 원본 phase가 올바르지 않습니다.")
        elseif receipt.originalPhase ~= binding.phase then
            errors[#errors + 1] = makeError("cleanup_phase_mismatch", path .. ".originalPhase", "복구 정리 원본 phase가 현재 요청 phase와 다릅니다.")
        end
        if receipt.attemptNumber ~= binding.attemptNumber then
            errors[#errors + 1] = makeError("cleanup_attempt_mismatch", path .. ".attemptNumber", "복구 정리 시도 번호가 요청과 다릅니다.")
        end
        local expectedIndex = type(binding.chatAnchor) == "table" and binding.chatAnchor.markerIndex + 1 or nil
        if not isInteger(receipt.responseIndex, 0) or receipt.responseIndex ~= expectedIndex then
            errors[#errors + 1] = makeError("cleanup_response_index_mismatch", path .. ".responseIndex", "복구 정리 응답 위치가 채팅 anchor 다음 위치와 다릅니다.")
        end
        if type(receipt.responsePresent) ~= "boolean" then
            errors[#errors + 1] = makeError("invalid_cleanup_response_flag", path .. ".responsePresent", "복구 정리 응답 존재 표식이 불리언이 아닙니다.")
        elseif receipt.responsePresent then
            validateFingerprint(receipt.responseFingerprint, path .. ".responseFingerprint", errors)
        elseif receipt.responseFingerprint ~= nil then
            errors[#errors + 1] = makeError("unexpected_cleanup_response_fingerprint", path .. ".responseFingerprint", "응답이 없는 복구 정리에 응답 fingerprint가 있습니다.")
        end
        if not isInteger(receipt.initialFillerCount, 1) then
            errors[#errors + 1] = makeError("invalid_cleanup_filler_count", path .. ".initialFillerCount", "복구 정리에는 최초 filler가 하나 이상 필요합니다.")
        end
        if receipt.mode == "retry" and binding.outputObserved ~= nil then
            errors[#errors + 1] = makeError("retry_cleanup_has_observed_output", path .. ".mode", "출력이 관측된 요청을 삭제 재시도로 정리할 수 없습니다.")
        elseif receipt.mode == "resumeCommit" and binding.outputObserved == nil then
            errors[#errors + 1] = makeError("commit_cleanup_missing_observed_output", path .. ".mode", "commit 재개 정리에는 출력 관측 영수증이 필요합니다.")
        end
    end

    local function buildBinding(pendingTurn, formatted, sourceName, phase, chatAnchor, attemptNumber)
        if sourceName ~= "pending" and sourceName ~= "lastCommittedPending" then
            return nil, {
                makeError("invalid_request_source", "$.activeRequest.source", "알 수 없는 요청 source입니다."),
            }
        end
        if phase ~= "preparing"
            and phase ~= "inFlight"
            and phase ~= "requestInjected"
            and phase ~= "committed" then
            return nil, {
                makeError("invalid_request_phase", "$.activeRequest.phase", "알 수 없는 요청 phase입니다."),
            }
        end
        if phase == "committed" and sourceName ~= "lastCommittedPending" then
            return nil, {
                makeError("committed_request_source_mismatch", "$.activeRequest.source", "확정 요청은 lastCommittedPending을 가리켜야 합니다."),
            }
        end
        if type(pendingTurn) ~= "table"
            or not isRuntimeId(pendingTurn.battleId)
            or not isRuntimeId(pendingTurn.turnId) then
            return nil, {
                makeError("invalid_pending_identity", "$.pendingTurn", "요청에 연결할 pendingTurn 식별자가 올바르지 않습니다."),
            }
        end
        return {
            schemaVersion = ACTIVE_REQUEST_SCHEMA_VERSION,
            kind = "battleActiveRequest",
            battleId = pendingTurn.battleId,
            turnId = pendingTurn.turnId,
            turnNumber = formatted.turnNumber,
            source = sourceName,
            phase = phase,
            attemptNumber = attemptNumber or 1,
            publicMarker = formatted.publicMarker,
            message = formatted.message,
            chatAnchor = chatAnchor,
        }, nil
    end

    local function validateBinding(binding, pendingTurn, path)
        path = path or "$.activeRequest"
        if type(binding) ~= "table" or getmetatable(binding) ~= nil then
            return { makeError("invalid_active_request", path, "활성 요청 binding이 일반 객체가 아닙니다.") }
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            battleId = true,
            turnId = true,
            turnNumber = true,
            source = true,
            phase = true,
            publicMarker = true,
            message = true,
            attemptNumber = true,
            chatAnchor = true,
            outputObserved = true,
            recoveringCleanup = true,
        }
        local errors = {}
        for key in pairs(binding) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_active_request_field", path .. "." .. tostring(key), "활성 요청 binding에 알 수 없는 필드가 있습니다.")
            end
        end
        if binding.schemaVersion ~= ACTIVE_REQUEST_SCHEMA_VERSION or binding.kind ~= "battleActiveRequest" then
            errors[#errors + 1] = makeError("invalid_active_request_schema", path, "활성 요청 binding 스키마가 올바르지 않습니다.")
        end
        if not isRuntimeId(binding.battleId) or not isRuntimeId(binding.turnId) then
            errors[#errors + 1] = makeError("invalid_active_request_identity", path, "활성 요청 식별자가 올바르지 않습니다.")
        end
        if not isInteger(binding.turnNumber, 1) then
            errors[#errors + 1] = makeError("invalid_active_request_turn", path .. ".turnNumber", "활성 요청 턴 번호가 올바르지 않습니다.")
        end
        if not isInteger(binding.attemptNumber, 1) then
            errors[#errors + 1] = makeError("invalid_request_attempt", path .. ".attemptNumber", "활성 요청 시도 번호가 올바르지 않습니다.")
        end
        if binding.source ~= "pending" and binding.source ~= "lastCommittedPending" then
            errors[#errors + 1] = makeError("invalid_request_source", path .. ".source", "활성 요청 source가 올바르지 않습니다.")
        end
        if binding.phase ~= "preparing"
            and binding.phase ~= "inFlight"
            and binding.phase ~= "requestInjected"
            and binding.phase ~= "committed" then
            errors[#errors + 1] = makeError("invalid_request_phase", path .. ".phase", "활성 요청 phase가 올바르지 않습니다.")
        elseif binding.phase == "committed" and binding.source ~= "lastCommittedPending" then
            errors[#errors + 1] = makeError("committed_request_source_mismatch", path .. ".source", "확정 요청은 lastCommittedPending을 가리켜야 합니다.")
        end
        if binding.publicMarker ~= expectedPublicMarker(binding.turnNumber) then
            errors[#errors + 1] = makeError("invalid_public_marker", path .. ".publicMarker", "활성 요청의 공개 마커가 턴 번호와 일치하지 않습니다.")
        end
        local messageError = validatePromptMessage(binding.message, path .. ".message")
        if messageError then
            errors[#errors + 1] = messageError
        end
        validateChatAnchor(binding.chatAnchor, path .. ".chatAnchor", errors)
        if binding.outputObserved ~= nil then
            if binding.phase ~= "requestInjected" then
                errors[#errors + 1] = makeError("output_observed_phase_mismatch", path .. ".outputObserved", "출력 관측 영수증은 requestInjected phase에만 존재할 수 있습니다.")
            end
            validateOutputObserved(binding.outputObserved, binding, path .. ".outputObserved", errors)
        end
        if binding.recoveringCleanup ~= nil then
            if binding.phase ~= "inFlight" and binding.phase ~= "requestInjected" then
                errors[#errors + 1] = makeError("cleanup_receipt_phase_mismatch", path .. ".recoveringCleanup", "복구 정리 영수증은 잠긴 요청 phase에만 존재할 수 있습니다.")
            end
            validateCleanupReceipt(binding.recoveringCleanup, binding, path .. ".recoveringCleanup", errors)
        end
        if binding.phase == "committed" and (binding.outputObserved ~= nil or binding.recoveringCleanup ~= nil) then
            errors[#errors + 1] = makeError("committed_request_has_transient_receipt", path, "확정 요청에 임시 출력·정리 영수증이 남아 있습니다.")
        end
        if type(pendingTurn) == "table" then
            local pendingTurnNumber = type(pendingTurn.beforeState) == "table" and pendingTurn.beforeState.turnNumber or nil
            if binding.battleId ~= pendingTurn.battleId
                or binding.turnId ~= pendingTurn.turnId
                or binding.turnNumber ~= pendingTurnNumber then
                errors[#errors + 1] = makeError("active_request_pending_mismatch", path, "활성 요청이 선택한 pendingTurn과 일치하지 않습니다.")
            end
        end
        return errors
    end

    local function readChat()
        if type(getFullChat) ~= "function" then
            return nil, {
                makeError("chat_read_unavailable", "$.host.getFullChat", "getFullChat 호스트 함수를 찾을 수 없습니다."),
            }
        end
        local ok, chat = pcall(getFullChat, triggerId)
        if not ok then
            return nil, {
                makeError("chat_read_failed", "$.chat", "대화 기록을 읽지 못했습니다: " .. tostring(chat)),
            }
        end
        local copy, cloneError = cloneJson(chat, "$.chat")
        if cloneError then
            return nil, { cloneError }
        end
        local count = 0
        for key in pairs(copy) do
            if type(key) ~= "number" or not isInteger(key, 1) then
                return nil, {
                    makeError("invalid_chat_array", "$.chat", "대화 기록은 1부터 이어지는 배열이어야 합니다."),
                }
            end
            count = count + 1
        end
        if count ~= #copy then
            return nil, {
                makeError("invalid_chat_array", "$.chat", "대화 기록 배열에 빈 인덱스가 있습니다."),
            }
        end
        return copy, nil
    end

    local function isExactFiller(message)
        return type(message) == "table"
            and message.role == "user"
            and message.data == SAY_NOTHING
    end

    local function isExactMarker(message, marker)
        return type(message) == "table"
            and message.role == "user"
            and message.data == marker
    end

    local function createPlannedChatAnchor(chat, marker)
        local logicalLength = #chat
        while logicalLength > 0 and isExactFiller(chat[logicalLength]) do
            logicalLength = logicalLength - 1
        end
        local prefixMessageCount = logicalLength
        if logicalLength > 0 and isExactMarker(chat[logicalLength], marker) then
            prefixMessageCount = logicalLength - 1
        end
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            1,
            prefixMessageCount,
            "$.chatAnchor.prefix"
        )
        if fingerprintError then return nil, { fingerprintError } end
        return {
            schemaVersion = 1,
            kind = "battleChatAnchor",
            prefixMessageCount = prefixMessageCount,
            markerIndex = prefixMessageCount,
            prefixFingerprint = fingerprint,
        }, nil
    end

    local function validateAnchorPrefix(binding, chat)
        local anchor = binding.chatAnchor
        local prefixCount = anchor.prefixMessageCount
        if #chat < prefixCount then
            return {
                makeError("chat_anchor_prefix_missing", "$.chat", "현재 대화가 저장된 채팅 anchor prefix보다 짧습니다."),
            }
        end
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            1,
            prefixCount,
            "$.chatAnchor.currentPrefix"
        )
        if fingerprintError then return { fingerprintError } end
        if not fingerprintsEqual(fingerprint, anchor.prefixFingerprint) then
            return {
                makeError("chat_anchor_prefix_mismatch", "$.chat", "마커 이전 대화가 요청 준비 시점의 채팅 anchor와 다릅니다."),
            }
        end
        return nil
    end

    local function inspectPreparingTopology(binding, chat)
        local prefixErrors = validateAnchorPrefix(binding, chat)
        if prefixErrors then return nil, prefixErrors end
        local markerLuaIndex = binding.chatAnchor.markerIndex + 1
        local cursor = markerLuaIndex
        local markerPresent = isExactMarker(chat[cursor], binding.publicMarker)
        if markerPresent then cursor = cursor + 1 end
        local fillerCount = 0
        for index = cursor, #chat do
            if not isExactFiller(chat[index]) then
                return nil, {
                    makeError("preparing_chat_topology_mismatch", "$.chat[" .. index .. "]", "준비 중인 요청의 anchor 뒤에는 고정 공개 마커와 trailing filler만 올 수 있습니다."),
                }
            end
            fillerCount = fillerCount + 1
        end
        return {
            markerPresent = markerPresent,
            fillerCount = fillerCount,
        }, nil
    end

    local function inspectAnchoredTopology(binding, chat, requireFiller)
        local prefixErrors = validateAnchorPrefix(binding, chat)
        if prefixErrors then return nil, prefixErrors end
        local markerLuaIndex = binding.chatAnchor.markerIndex + 1
        if not isExactMarker(chat[markerLuaIndex], binding.publicMarker) then
            return nil, {
                makeError("chat_anchor_marker_mismatch", "$.chat[" .. markerLuaIndex .. "]", "저장된 위치에 이 요청의 공개 턴 마커가 없습니다."),
            }
        end
        local fillerCount = 0
        local cursor = #chat
        while cursor > markerLuaIndex and isExactFiller(chat[cursor]) do
            fillerCount = fillerCount + 1
            cursor = cursor - 1
        end
        if requireFiller and fillerCount == 0 then
            return nil, {
                makeError("recovery_filler_missing", "$.chat", "잠긴 요청을 복구하려면 새 정확한 빈 입력이 필요합니다."),
            }
        end
        local responsePresent = false
        local responseFingerprint
        local responseLuaIndex = markerLuaIndex + 1
        if cursor == responseLuaIndex then
            local response = chat[responseLuaIndex]
            if type(response) ~= "table" or response.role ~= "char" then
                return nil, {
                    makeError("recovery_response_role_mismatch", "$.chat[" .. responseLuaIndex .. "]", "공개 마커 뒤의 미확정 응답이 캐릭터 메시지가 아닙니다."),
                }
            end
            responsePresent = true
            local fingerprintError
            responseFingerprint, fingerprintError = fingerprintChatRange(
                chat,
                responseLuaIndex,
                1,
                "$.recovery.response"
            )
            if fingerprintError then return nil, { fingerprintError } end
        elseif cursor ~= markerLuaIndex then
            return nil, {
                makeError("recovery_chat_topology_mismatch", "$.chat", "채팅 anchor 뒤에 자동 복구가 소유한다고 증명할 수 없는 메시지가 있습니다."),
            }
        end
        return {
            markerLuaIndex = markerLuaIndex,
            responseLuaIndex = responseLuaIndex,
            responseIndex = responseLuaIndex - 1,
            responsePresent = responsePresent,
            responseFingerprint = responseFingerprint,
            fillerCount = fillerCount,
        }, nil
    end

    local function inspectObservedOutput(binding, chat, allowTrailingFillers)
        local topology, topologyErrors = inspectAnchoredTopology(binding, chat, false)
        if topologyErrors then return nil, topologyErrors end
        if not topology.responsePresent then
            return nil, {
                makeError("observed_output_missing", "$.chat", "출력 관측 영수증에 연결할 캐릭터 응답이 없습니다."),
            }
        end
        if not allowTrailingFillers and topology.fillerCount ~= 0 then
            return nil, {
                makeError("unexpected_output_suffix", "$.chat", "정상 onOutput 관측 시점에 응답 뒤 추가 메시지가 있습니다."),
            }
        end
        local observed = binding.outputObserved
        if observed ~= nil then
            if topology.responseIndex ~= observed.responseIndex
                or not fingerprintsEqual(topology.responseFingerprint, observed.responseFingerprint) then
                return nil, {
                    makeError("observed_output_mismatch", "$.chat", "현재 캐릭터 응답이 저장된 출력 관측 영수증과 다릅니다."),
                }
            end
        end
        return topology, nil
    end

    local function removeTrailingSayNothing(chat)
        local current = chat
        local removedCount = 0
        while true do
            local last = current[#current]
            if type(last) ~= "table" or last.role ~= "user" or last.data ~= SAY_NOTHING then
                return current, removedCount, nil
            end
            if type(removeChat) ~= "function" then
                return nil, removedCount, {
                    makeError("chat_write_unavailable", "$.host.removeChat", "removeChat 호스트 함수를 찾을 수 없습니다."),
                }
            end
            local ok, removeError = pcall(removeChat, triggerId, #current - 1)
            if not ok then
                return nil, removedCount, {
                    makeError("say_nothing_remove_failed", "$.chat[" .. #current .. "]", "자동 빈 입력 메시지를 제거하지 못했습니다: " .. tostring(removeError)),
                }
            end
            local after, readErrors = readChat()
            if readErrors then
                return nil, removedCount, readErrors
            end
            if #after ~= #current - 1 then
                return nil, removedCount, {
                    makeError("say_nothing_remove_not_persisted", "$.chat", "자동 빈 입력 메시지 제거 뒤 대화 길이가 바뀌지 않았습니다."),
                }
            end
            for index = 1, #after do
                if not deepEqual(after[index], current[index]) then
                    return nil, removedCount, {
                        makeError("say_nothing_remove_mismatch", "$.chat[" .. index .. "]", "자동 빈 입력 메시지 제거가 앞선 대화를 변경했습니다."),
                    }
                end
            end
            current = after
            removedCount = removedCount + 1
        end
    end

    local function removeRecoveryResponse(chat, luaIndex, expectedFingerprint)
        if luaIndex ~= #chat then
            return nil, {
                makeError("recovery_response_not_last", "$.chat", "filler 정리 뒤 삭제할 미확정 응답이 마지막 메시지가 아닙니다."),
            }
        end
        local currentFingerprint, fingerprintError = fingerprintChatRange(
            chat,
            luaIndex,
            1,
            "$.recovery.response"
        )
        if fingerprintError then return nil, { fingerprintError } end
        if not fingerprintsEqual(currentFingerprint, expectedFingerprint) then
            return nil, {
                makeError("recovery_response_fingerprint_mismatch", "$.chat[" .. luaIndex .. "]", "삭제 대상 응답이 복구 영수증과 다릅니다."),
            }
        end
        if type(chat[luaIndex]) ~= "table" or chat[luaIndex].role ~= "char" then
            return nil, {
                makeError("recovery_response_role_mismatch", "$.chat[" .. luaIndex .. "]", "삭제 대상이 캐릭터 응답이 아닙니다."),
            }
        end
        if type(removeChat) ~= "function" then
            return nil, {
                makeError("chat_write_unavailable", "$.host.removeChat", "removeChat 호스트 함수를 찾을 수 없습니다."),
            }
        end
        local ok, removeError = pcall(removeChat, triggerId, luaIndex - 1)
        if not ok then
            return nil, {
                makeError("recovery_response_remove_failed", "$.chat[" .. luaIndex .. "]", "미확정 응답을 삭제하지 못했습니다: " .. tostring(removeError)),
            }
        end
        local after, readErrors = readChat()
        if readErrors then return nil, readErrors end
        if #after ~= #chat - 1 then
            return nil, {
                makeError("recovery_response_remove_not_persisted", "$.chat", "미확정 응답 삭제 뒤 대화 길이가 바뀌지 않았습니다."),
            }
        end
        for index = 1, #after do
            if not deepEqual(after[index], chat[index]) then
                return nil, {
                    makeError("recovery_response_remove_mismatch", "$.chat[" .. index .. "]", "미확정 응답 삭제가 앞선 대화를 변경했습니다."),
                }
            end
        end
        return after, nil
    end

    local function ensurePublicMarker(chat, marker)
        local last = chat[#chat]
        if type(last) == "table" and last.role == "user" and last.data == marker then
            return chat, false, nil
        end
        if type(addChat) ~= "function" then
            return nil, false, {
                makeError("chat_write_unavailable", "$.host.addChat", "addChat 호스트 함수를 찾을 수 없습니다."),
            }
        end
        local ok, addError = pcall(addChat, triggerId, "user", marker)
        if not ok then
            return nil, false, {
                makeError("public_marker_add_failed", "$.chat", "공개 턴 마커를 추가하지 못했습니다: " .. tostring(addError)),
            }
        end
        local after, readErrors = readChat()
        if readErrors then
            return nil, false, readErrors
        end
        local added = after[#after]
        if #after ~= #chat + 1
            or type(added) ~= "table"
            or added.role ~= "user"
            or added.data ~= marker then
            return nil, false, {
                makeError("public_marker_add_not_persisted", "$.chat", "쓰기 뒤 공개 턴 마커를 확인하지 못했습니다."),
            }
        end
        for index = 1, #chat do
            if not deepEqual(after[index], chat[index]) then
                return nil, false, {
                    makeError("public_marker_add_mismatch", "$.chat[" .. index .. "]", "공개 턴 마커 추가가 기존 대화를 변경했습니다."),
                }
            end
        end
        return after, true, nil
    end

    local function publishCurrentViewInternal(staticData, suppressRefresh)
        staticData = staticData or select(1, loadStaticData())
        if staticData == nil then
            local _, errors = loadStaticData()
            return nil, errors
        end
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then
            return nil, authorityErrors
        end

        local context = {}
        local lastCommitted, lastCommittedErrors = readStored(KEYS.lastCommittedPending, false)
        if lastCommittedErrors then
            return nil, lastCommittedErrors
        end
        if authority.lastCommittedTurnId ~= nil and lastCommitted == nil then
            return nil, {
                makeError(
                    "missing_last_committed_pending",
                    "$.lastCommittedPending",
                    "확정 turnId가 있는 authority에는 공개 결과를 재현할 직전 pendingTurn이 필요합니다."
                ),
            }
        end
        if lastCommitted ~= nil then
            context.lastCommittedPending = lastCommitted
        end
        local activeRequest, activeRequestErrors = readStored(KEYS.activeRequest, false)
        if activeRequestErrors then
            return nil, activeRequestErrors
        end
        if activeRequest ~= nil then
            local activeValidationErrors = validateBinding(activeRequest, nil)
            if #activeValidationErrors > 0 then
                return nil, activeValidationErrors
            end
        end
        if authority.status == "active" then
            local pending, pendingErrors = readStored(KEYS.pending, false)
            if pendingErrors then
                return nil, pendingErrors
            end
            if pending ~= nil then
                context.pendingTurn = pending
            else
                local draft, draftErrors = readStored(KEYS.draft, true)
                if draftErrors then
                    return nil, draftErrors
                end
                context.draft = draft
                if type(activeRequest) == "table"
                    and (activeRequest.phase == "preparing"
                        or activeRequest.phase == "inFlight"
                        or activeRequest.phase == "requestInjected") then
                    context.generationLocked = true
                end
            end
        end

        local built, buildErrors = callModule(
            "viewBuilder",
            "buildBattleView",
            authority,
            staticData,
            context
        )
        if buildErrors then
            return nil, buildErrors
        end
        if type(built.view) ~= "table" then
            return nil, {
                makeError("missing_battle_view", "$.runtime.viewBuilder.view", "viewBuilder 성공 결과에 battleView가 없습니다."),
            }
        end

        local published, publishErrors = callModule(
            "dataBridge",
            "_publishCanonical",
            VIEW_NAME,
            built.view,
            permitCanonicalBattleView
        )
        if publishErrors then
            return nil, publishErrors
        end
        if type(published.encoded) ~= "string" or published.encoded == "" then
            return nil, {
                makeError("missing_published_view", "$.runtime.dataBridge.encoded", "dataBridge 성공 결과에 게시 문자열이 없습니다."),
            }
        end
        if type(getChatVar) ~= "function" then
            return nil, {
                makeError("view_verify_unavailable", "$.host.getChatVar", "게시한 battleView를 검증할 getChatVar가 없습니다."),
            }
        end
        local readOk, storedWire = pcall(getChatVar, triggerId, VIEW_NAME)
        if not readOk then
            return nil, {
                makeError("view_verify_read_failed", "$.chatVar.battleView", "게시 뒤 battleView를 읽지 못했습니다: " .. tostring(storedWire)),
            }
        end
        if storedWire ~= published.encoded then
            return nil, {
                makeError("view_write_not_persisted", "$.chatVar.battleView", "게시 뒤 읽은 battleView가 인코딩 결과와 다릅니다."),
            }
        end
        if suppressRefresh ~= true then
            local uiRefresh = type(refreshGameUi) == "function" and refreshGameUi or reloadDisplay
            if type(uiRefresh) ~= "function" then
                return nil, {
                    makeError("display_reload_unavailable", "$.host.refreshGameUi", "게시한 battleView를 화면에 반영할 UI 갱신 함수가 없습니다."),
                }
            end
            local reloadOk, reloadError = pcall(uiRefresh, triggerId)
            if not reloadOk then
                return nil, {
                    makeError("display_reload_failed", "$.host.refreshGameUi", "battleView 게시 뒤 화면 갱신에 실패했습니다: " .. tostring(reloadError)),
                }
            end
        end

        return {
            view = built.view,
            wireFormat = published.wireFormat,
            bytes = published.bytes,
        }, nil
    end

    local function startVerticalSlice(battleId, seed)
        local staticData, staticErrors = loadStaticData()
        if staticErrors then
            return failure(staticErrors)
        end
        local bootstrap, bootstrapErrors = callModule(
            "battleBootstrap",
            "verticalSlice",
            { battleId = battleId, seed = seed },
            staticData
        )
        if bootstrapErrors then
            return failure(bootstrapErrors)
        end
        if bootstrap.referencesValidated ~= true or type(bootstrap.state) ~= "table" then
            return failure({
                makeError("invalid_bootstrap_result", "$.runtime.battleBootstrap", "bootstrap이 검증된 battleState를 반환하지 않았습니다."),
            })
        end
        local turnId, turnIdErrors = makeTurnId(bootstrap.state)
        if turnIdErrors then
            return failure(turnIdErrors)
        end
        local initialized, initializeErrors = callModule(
            "turnInitializer",
            "prepareTurn",
            bootstrap.state,
            staticData,
            { turnId = turnId }
        )
        if initializeErrors then
            return failure(initializeErrors)
        end
        if type(initialized.state) ~= "table" or type(initialized.draft) ~= "table" then
            return failure({
                makeError("invalid_initial_turn", "$.runtime.turnInitializer", "첫 턴 초기화 상태와 draft가 없습니다."),
            })
        end

        for _, write in ipairs({
            { KEYS.authority, initialized.state },
            { KEYS.draft, initialized.draft },
            { KEYS.pending, nil },
            { KEYS.lastCommittedPending, nil },
            { KEYS.activeRequest, nil },
        }) do
            local writeErrors = writeStored(write[1], write[2])
            if writeErrors then
                return failure(writeErrors)
            end
        end

        local published, publishErrors = publishCurrentViewInternal(staticData)
        if publishErrors then
            return failure(publishErrors)
        end
        return success({
            battleId = initialized.state.battleId,
            turnId = turnId,
            turnNumber = initialized.state.turnNumber,
            view = published.view,
        })
    end

    local function interactCard(interactionAction, instanceId, expectedInteractionToken)
        if interactionAction ~= "click"
            and interactionAction ~= "register"
            and interactionAction ~= "cancel" then
            return failure({
                makeError(
                    "invalid_interaction_action",
                    "$.interactionAction",
                    "카드 상호작용 작업은 click, register, cancel 중 하나여야 합니다."
                ),
            })
        end
        local staticData, staticErrors = loadStaticData()
        if staticErrors then
            return failure(staticErrors)
        end
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then
            return failure(authorityErrors)
        end
        local pending, pendingErrors = readStored(KEYS.pending, false)
        if pendingErrors then
            return failure(pendingErrors)
        end
        if pending ~= nil then
            return failure({
                makeError("battle_view_locked", "$.pendingTurn", "출력 대기 중에는 카드 선택을 변경할 수 없습니다."),
            })
        end
        local activeRequest, requestErrors = readStored(KEYS.activeRequest, false)
        if requestErrors then
            return failure(requestErrors)
        end
        if activeRequest ~= nil then
            local activeErrors = validateBinding(activeRequest, nil)
            if #activeErrors > 0 then
                return failure(activeErrors)
            end
            if activeRequest.phase == "preparing"
                or activeRequest.phase == "inFlight"
                or activeRequest.phase == "requestInjected" then
                return failure({
                    makeError("battle_view_locked", "$.activeRequest.phase", "생성 요청 처리 중에는 카드 선택을 변경할 수 없습니다."),
                })
            end
        end
        if not isRuntimeId(instanceId) then
            return failure({
                makeError("invalid_instance_id", "$.instanceId", "카드 인스턴스 ID가 올바르지 않습니다."),
            })
        end
        if type(expectedInteractionToken) ~= "string" or expectedInteractionToken == "" then
            return failure({
                makeError("invalid_interaction_token", "$.expectedInteractionToken", "비어 있지 않은 draft interaction token이 필요합니다."),
            })
        end
        local draft, draftErrors = readStored(KEYS.draft, true)
        if draftErrors then
            return failure(draftErrors)
        end
        local interacted, interactionErrors = callModule(
            "turnDraft",
            "applyInteraction",
            authority,
            staticData,
            draft,
            {
                action = interactionAction,
                instanceId = instanceId,
                expectedInteractionToken = expectedInteractionToken,
            }
        )
        if interactionErrors then
            return failure(interactionErrors)
        end
        if type(interacted.draft) ~= "table"
            or type(interacted.interactionToken) ~= "string"
            or interacted.interactionToken == ""
            or type(interacted.applied) ~= "boolean"
            or type(interacted.stale) ~= "boolean"
            or interacted.interactionAction ~= interactionAction then
            return failure({
                makeError(
                    "invalid_interaction_result",
                    "$.runtime.turnDraft.applyInteraction",
                    "검증된 카드 상호작용 결과와 다음 interaction token이 없습니다."
                ),
            })
        end
        if interacted.stale then
            if interacted.applied then
                return failure({
                    makeError(
                        "invalid_stale_interaction_result",
                        "$.runtime.turnDraft.applyInteraction",
                        "stale 카드 상호작용은 전이를 적용할 수 없습니다."
                    ),
                })
            end
            -- risu-btn host가 클릭 message를 자동 remount하므로 수동
            -- refresh를 중복하지 않는다.
            local published, publishErrors = publishCurrentViewInternal(staticData, true)
            if publishErrors then
                return failure(publishErrors)
            end
            if published.view.interactionToken ~= interacted.interactionToken then
                return failure({
                    makeError("view_interaction_token_mismatch", "$.view.interactionToken", "재게시 View가 현재 draft interaction token과 일치하지 않습니다."),
                })
            end
            return success({
                applied = false,
                stale = true,
                interactionAction = interactionAction,
                interactionToken = interacted.interactionToken,
                draft = interacted.draft,
                view = published.view,
            })
        end
        if interacted.applied then
            local writeErrors = writeStored(KEYS.draft, interacted.draft)
            if writeErrors then
                return failure(writeErrors)
            end
        end
        local published, publishErrors = publishCurrentViewInternal(staticData, true)
        if publishErrors then
            return failure(publishErrors)
        end
        if published.view.interactionToken ~= interacted.interactionToken then
            return failure({
                makeError("view_interaction_token_mismatch", "$.view.interactionToken", "카드 전이 View가 계산된 다음 interaction token과 일치하지 않습니다."),
            })
        end
        return success({
            applied = interacted.applied,
            stale = false,
            interactionAction = interactionAction,
            interactionToken = interacted.interactionToken,
            draft = interacted.draft,
            view = published.view,
        })
    end

    local function clickCard(instanceId, expectedInteractionToken)
        return interactCard("click", instanceId, expectedInteractionToken)
    end

    local function registerCard(instanceId, expectedInteractionToken)
        return interactCard("register", instanceId, expectedInteractionToken)
    end

    local function cancelCard(instanceId, expectedInteractionToken)
        return interactCard("cancel", instanceId, expectedInteractionToken)
    end

    local loadBoundPending
    local commitOutput

    local function loadAndValidateBoundRequest(binding, staticData)
        local pending, pendingErrors = loadBoundPending(binding)
        if pendingErrors then return nil, nil, pendingErrors end
        local formatted, formatErrors = formatPending(pending, staticData)
        if formatErrors then return nil, nil, formatErrors end
        if binding.publicMarker ~= formatted.publicMarker
            or not deepEqual(binding.message, formatted.message) then
            return nil, nil, {
                makeError("active_request_prompt_mismatch", "$.activeRequest", "복구할 요청 binding이 pendingTurn에서 다시 만든 프롬프트와 다릅니다."),
            }
        end
        return pending, formatted, nil
    end

    local function validateNoPendingCommitTrace(binding, authority)
        if binding.source ~= "pending" then return nil end
        local lastCommitted, lastErrors = readStored(KEYS.lastCommittedPending, false)
        if lastErrors then return lastErrors end
        if authority.lastCommittedTurnId == binding.turnId
            or (type(lastCommitted) == "table" and lastCommitted.turnId == binding.turnId) then
            return {
                makeError("commit_trace_without_output_receipt", "$.activeRequest", "현재 턴의 commit 흔적이 있어 출력 관측 영수증 없이 요청을 재시도할 수 없습니다."),
            }
        end
        return nil
    end

    local function beginRecoveringCleanup(binding, chat, staticData, authority)
        local pending, _, boundErrors = loadAndValidateBoundRequest(binding, staticData)
        if boundErrors then return nil, nil, nil, boundErrors end
        local topology, topologyErrors = inspectAnchoredTopology(binding, chat, true)
        if topologyErrors then return nil, nil, nil, topologyErrors end

        local mode = binding.outputObserved ~= nil and "resumeCommit" or "retry"
        if mode == "resumeCommit" then
            if not topology.responsePresent
                or topology.responseIndex ~= binding.outputObserved.responseIndex
                or not fingerprintsEqual(topology.responseFingerprint, binding.outputObserved.responseFingerprint) then
                return nil, nil, nil, {
                    makeError("observed_output_mismatch", "$.chat", "완성 출력 복구 대상이 출력 관측 영수증과 다릅니다."),
                }
            end
        else
            local traceErrors = validateNoPendingCommitTrace(binding, authority)
            if traceErrors then return nil, nil, nil, traceErrors end
        end

        local nextBinding, cloneError = cloneJson(binding, "$.activeRequest")
        if cloneError then return nil, nil, nil, { cloneError } end
        nextBinding.recoveringCleanup = {
            schemaVersion = 1,
            kind = "battleRecoveringCleanup",
            mode = mode,
            originalPhase = binding.phase,
            attemptNumber = binding.attemptNumber,
            responseIndex = topology.responseIndex,
            responsePresent = topology.responsePresent,
            responseFingerprint = topology.responseFingerprint,
            initialFillerCount = topology.fillerCount,
        }
        local validationErrors = validateBinding(nextBinding, pending)
        if #validationErrors > 0 then return nil, nil, nil, validationErrors end
        local writeErrors = writeStored(KEYS.activeRequest, nextBinding)
        if writeErrors then return nil, nil, nil, writeErrors end
        return nextBinding, pending, topology, nil
    end

    local function resumeRecoveringCleanup(binding, chat)
        local receipt = binding.recoveringCleanup
        local topology, topologyErrors = inspectAnchoredTopology(binding, chat, false)
        if topologyErrors then return nil, nil, nil, topologyErrors end

        if receipt.responsePresent then
            if topology.responsePresent
                and (topology.responseIndex ~= receipt.responseIndex
                    or not fingerprintsEqual(topology.responseFingerprint, receipt.responseFingerprint)) then
                return nil, nil, nil, {
                    makeError("cleanup_response_mismatch", "$.chat", "현재 미확정 응답이 복구 정리 영수증과 다릅니다."),
                }
            end
        elseif topology.responsePresent then
            return nil, nil, nil, {
                makeError("unexpected_cleanup_response", "$.chat", "응답이 없었던 복구 정리에 새 캐릭터 메시지가 나타났습니다."),
            }
        end

        local nextChat, removedFillers, fillerErrors = removeTrailingSayNothing(chat)
        if fillerErrors then return nil, nil, nil, fillerErrors end
        local removedResponse = false
        if receipt.mode == "retry" and receipt.responsePresent then
            local afterFillerTopology, afterFillerErrors = inspectAnchoredTopology(binding, nextChat, false)
            if afterFillerErrors then return nil, nil, nil, afterFillerErrors end
            if afterFillerTopology.responsePresent then
                local afterRemoval, removeErrors = removeRecoveryResponse(
                    nextChat,
                    afterFillerTopology.responseLuaIndex,
                    receipt.responseFingerprint
                )
                if removeErrors then return nil, nil, nil, removeErrors end
                nextChat = afterRemoval
                removedResponse = true
            end
        end

        local finalTopology, finalErrors = inspectAnchoredTopology(binding, nextChat, false)
        if finalErrors then return nil, nil, nil, finalErrors end
        if receipt.mode == "retry" and finalTopology.responsePresent then
            return nil, nil, nil, {
                makeError("cleanup_response_remains", "$.chat", "삭제 재시도 정리 뒤 미확정 응답이 남아 있습니다."),
            }
        end
        if receipt.mode == "resumeCommit" then
            if not finalTopology.responsePresent
                or finalTopology.responseIndex ~= binding.outputObserved.responseIndex
                or not fingerprintsEqual(finalTopology.responseFingerprint, binding.outputObserved.responseFingerprint) then
                return nil, nil, nil, {
                    makeError("observed_output_mismatch", "$.chat", "commit 재개 전에 완성 응답이 출력 관측 영수증과 달라졌습니다."),
                }
            end
        end
        return nextChat, removedFillers, removedResponse, nil
    end

    local function retryWithoutOutput(binding, chat, staticData, authority)
        if binding.outputObserved ~= nil or binding.recoveringCleanup ~= nil then
            return failure({
                makeError("zero_output_retry_has_receipt", "$.activeRequest", "출력 또는 정리 영수증이 있는 요청을 무출력 재시도로 되돌릴 수 없습니다."),
            })
        end
        local pending, _, boundErrors = loadAndValidateBoundRequest(binding, staticData)
        if boundErrors then return failure(boundErrors) end
        local topology, topologyErrors = inspectAnchoredTopology(binding, chat, false)
        if topologyErrors then return failure(topologyErrors) end
        if topology.responsePresent or topology.fillerCount ~= 0 then
            return failure({
                makeError("zero_output_retry_topology_mismatch", "$.chat", "무출력 재시도에는 공개 마커 뒤가 완전히 비어 있어야 합니다."),
            })
        end
        local traceErrors = validateNoPendingCommitTrace(binding, authority)
        if traceErrors then return failure(traceErrors) end

        local nextBinding, cloneError = cloneJson(binding, "$.activeRequest")
        if cloneError then return failure({ cloneError }) end
        nextBinding.phase = "inFlight"
        nextBinding.attemptNumber = nextBinding.attemptNumber + 1
        local validationErrors = validateBinding(nextBinding, pending)
        if #validationErrors > 0 then return failure(validationErrors) end

        -- The visible View is already locked and does not expose attemptNumber.
        -- Publish it before the sole state mutation so a publication failure
        -- cannot consume a retry attempt.
        local published, publishErrors = publishCurrentViewInternal(staticData)
        if publishErrors then return failure(publishErrors) end
        local writeErrors = writeStored(KEYS.activeRequest, nextBinding)
        if writeErrors then return failure(writeErrors) end
        return success({
            generationReady = true,
            recoveredAbandonedRequest = true,
            zeroOutputRetry = true,
            commitRecovered = false,
            turnId = nextBinding.turnId,
            turnNumber = nextBinding.turnNumber,
            source = nextBinding.source,
            publicMarker = nextBinding.publicMarker,
            attemptNumber = nextBinding.attemptNumber,
            reused = true,
            removedSayNothing = false,
            removedSayNothingCount = 0,
            removedUncommittedOutput = false,
            markerAdded = false,
            view = published.view,
        })
    end

    local function recoverLockedRequest(binding, chat, staticData, authority)
        local workingBinding = binding
        local pending
        if workingBinding.recoveringCleanup == nil then
            local topology
            local beginErrors
            workingBinding, pending, topology, beginErrors = beginRecoveringCleanup(
                workingBinding,
                chat,
                staticData,
                authority
            )
            if beginErrors then return failure(beginErrors) end
        else
            local boundErrors
            pending, _, boundErrors = loadAndValidateBoundRequest(workingBinding, staticData)
            if boundErrors then return failure(boundErrors) end
        end

        local cleanedChat, removedFillers, removedResponse, cleanupErrors = resumeRecoveringCleanup(
            workingBinding,
            chat
        )
        if cleanupErrors then return failure(cleanupErrors) end

        if workingBinding.recoveringCleanup.mode == "resumeCommit" then
            local committed = commitOutput()
            if type(committed) ~= "table" or committed.ok ~= true then return committed end
            committed.generationReady = false
            committed.commitRecovered = true
            committed.zeroOutputRetry = false
            committed.removedSayNothing = removedFillers > 0
            committed.removedSayNothingCount = removedFillers
            committed.removedUncommittedOutput = false
            return committed
        end

        workingBinding.phase = "inFlight"
        workingBinding.attemptNumber = workingBinding.attemptNumber + 1
        workingBinding.outputObserved = nil
        workingBinding.recoveringCleanup = nil
        local validationErrors = validateBinding(workingBinding, pending)
        if #validationErrors > 0 then return failure(validationErrors) end
        local writeErrors = writeStored(KEYS.activeRequest, workingBinding)
        if writeErrors then return failure(writeErrors) end
        local published, publishErrors = publishCurrentViewInternal(staticData)
        if publishErrors then return failure(publishErrors) end
        return success({
            generationReady = true,
            recoveredAbandonedRequest = true,
            zeroOutputRetry = false,
            commitRecovered = false,
            turnId = workingBinding.turnId,
            turnNumber = workingBinding.turnNumber,
            source = workingBinding.source,
            publicMarker = workingBinding.publicMarker,
            attemptNumber = workingBinding.attemptNumber,
            reused = true,
            removedSayNothing = removedFillers > 0,
            removedSayNothingCount = removedFillers,
            removedUncommittedOutput = removedResponse,
            markerAdded = false,
            view = published.view,
        })
    end

    local function prepareGeneration()
        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then return failure(authorityErrors) end
        local chat, chatErrors = readChat()
        if chatErrors then return failure(chatErrors) end
        local last = chat[#chat]
        local freshSend = isExactFiller(last)

        local storedBinding, storedBindingErrors = readStored(KEYS.activeRequest, false)
        if storedBindingErrors then return failure(storedBindingErrors) end
        if storedBinding ~= nil then
            local storedBindingValidationErrors = validateBinding(storedBinding, nil)
            if #storedBindingValidationErrors > 0 then return failure(storedBindingValidationErrors) end

            if storedBinding.phase == "committed" then
                local stalePending, stalePendingErrors = readStored(KEYS.pending, false)
                if stalePendingErrors then return failure(stalePendingErrors) end
                if type(stalePending) == "table" and stalePending.turnId == storedBinding.turnId then
                    local cleanupCommit = commitOutput()
                    if type(cleanupCommit) ~= "table" or cleanupCommit.ok ~= true then return cleanupCommit end
                    authority, authorityErrors = readStored(KEYS.authority, true)
                    if authorityErrors then return failure(authorityErrors) end
                    chat, chatErrors = readChat()
                    if chatErrors then return failure(chatErrors) end
                    last = chat[#chat]
                    freshSend = isExactFiller(last)
                    storedBinding, storedBindingErrors = readStored(KEYS.activeRequest, true)
                    if storedBindingErrors then return failure(storedBindingErrors) end
                end
            end

            if storedBinding.phase == "inFlight" or storedBinding.phase == "requestInjected" then
                if storedBinding.recoveringCleanup == nil and not freshSend then
                    if storedBinding.outputObserved == nil
                        and isExactMarker(last, storedBinding.publicMarker) then
                        return retryWithoutOutput(storedBinding, chat, staticData, authority)
                    end
                    return failure({
                        makeError(
                            "request_already_in_flight",
                            "$.activeRequest.phase",
                            "이미 생성 중이거나 프롬프트 주입을 마친 요청이 있습니다. 새 정확한 빈 입력만 실패 복구를 시작할 수 있습니다."
                        ),
                    })
                end
                return recoverLockedRequest(storedBinding, chat, staticData, authority)
            end
        end

        local selectedPending
        local sourceName
        local reused = false
        local recoveryBinding
        if type(storedBinding) == "table" and storedBinding.phase == "preparing" then
            local pending, pendingErrors = loadBoundPending(storedBinding)
            if pendingErrors then
                return failure(pendingErrors)
            end
            selectedPending = pending
            sourceName = storedBinding.source
            recoveryBinding = storedBinding
            reused = true
        elseif freshSend then
            local pending, pendingErrors = readStored(KEYS.pending, false)
            if pendingErrors then
                return failure(pendingErrors)
            end
            if pending ~= nil then
                local reuse, reuseErrors = callModule(
                    "battleRuntime",
                    "reusePending",
                    authority,
                    staticData,
                    pending
                )
                if reuseErrors then
                    return failure(reuseErrors)
                end
                selectedPending = reuse.pendingTurn
                reused = true
            else
                local draft, draftErrors = readStored(KEYS.draft, true)
                if draftErrors then
                    return failure(draftErrors)
                end
                local projected, projectErrors = callModule(
                    "turnDraft",
                    "project",
                    authority,
                    staticData,
                    draft
                )
                if projectErrors then
                    return failure(projectErrors)
                end
                if type(projected.projection) ~= "table" then
                    return failure({
                        makeError("missing_turn_projection", "$.runtime.turnDraft.projection", "전송할 turnDraft projection이 없습니다."),
                    })
                end
                local prepared, prepareErrors = callModule(
                    "battleRuntime",
                    "preparePending",
                    authority,
                    staticData,
                    projected.projection
                )
                if prepareErrors then
                    return failure(prepareErrors)
                end
                selectedPending = prepared.pendingTurn
            end
            sourceName = "pending"
        else
            local lastCommitted, lastErrors = readStored(KEYS.lastCommittedPending, true)
            if lastErrors then
                return failure({
                    makeError("unsupported_generation_source", "$.chat", "새 빈 입력도 준비 중인 요청도 직전 턴 재생성 마커도 찾지 못했습니다."),
                })
            end
            local formattedLast, formatLastErrors = formatPending(lastCommitted, staticData)
            if formatLastErrors then
                return failure(formatLastErrors)
            end
            if type(last) ~= "table" or last.role ~= "user" or last.data ~= formattedLast.publicMarker then
                return failure({
                    makeError("unsupported_generation_source", "$.chat", "Continue와 프롬프트 미리보기는 지원하지 않으며, 직전 공개 턴 마커의 즉시 재생성만 허용합니다."),
                })
            end
            local reuse, reuseErrors = callModule(
                "battleRuntime",
                "reusePending",
                authority,
                staticData,
                lastCommitted
            )
            if reuseErrors then
                return failure(reuseErrors)
            end
            selectedPending = reuse.pendingTurn
            sourceName = "lastCommittedPending"
            reused = true
        end

        if type(selectedPending) ~= "table" then
            return failure({
                makeError("missing_selected_pending", "$.pendingTurn", "생성 요청에 연결할 pendingTurn이 없습니다."),
            })
        end
        local formatted, formatErrors = formatPending(selectedPending, staticData)
        if formatErrors then
            return failure(formatErrors)
        end
        local binding
        if recoveryBinding ~= nil then
            if recoveryBinding.publicMarker ~= formatted.publicMarker
                or not deepEqual(recoveryBinding.message, formatted.message) then
                return failure({
                    makeError("active_request_prompt_mismatch", "$.activeRequest", "준비 중인 요청 binding이 pendingTurn에서 다시 만든 프롬프트와 다릅니다."),
                })
            end
            binding = recoveryBinding
            local topology, topologyErrors = inspectPreparingTopology(binding, chat)
            if topologyErrors then return failure(topologyErrors) end
        else
            local chatAnchor, anchorErrors = createPlannedChatAnchor(chat, formatted.publicMarker)
            if anchorErrors then return failure(anchorErrors) end
            local bindingErrors
            binding, bindingErrors = buildBinding(
                selectedPending,
                formatted,
                sourceName,
                "preparing",
                chatAnchor,
                1
            )
            if bindingErrors then
                return failure(bindingErrors)
            end
            local topology, topologyErrors = inspectPreparingTopology(binding, chat)
            if topologyErrors then return failure(topologyErrors) end
        end

        if sourceName == "pending" then
            local pendingWriteErrors = writeStored(KEYS.pending, selectedPending)
            if pendingWriteErrors then
                return failure(pendingWriteErrors)
            end
            local draftClearErrors = writeStored(KEYS.draft, nil)
            if draftClearErrors then
                return failure(draftClearErrors)
            end
        end
        local bindingWriteErrors = writeStored(KEYS.activeRequest, binding)
        if bindingWriteErrors then
            return failure(bindingWriteErrors)
        end

        local published, publishErrors = publishCurrentViewInternal(staticData)
        if publishErrors then
            return failure(publishErrors)
        end

        -- State and the locked View must be durable before touching the chat. If a
        -- host write above is silently dropped, the exact filler remains and the
        -- next onStart resumes the durable preparing binding first, or reuses the
        -- stored pendingTurn when that binding itself was the dropped write.
        local nextChat, removedCount, removeErrors = removeTrailingSayNothing(chat)
        if removeErrors then
            return failure(removeErrors)
        end
        if not freshSend and removedCount > 0 then
            return failure({
                makeError("generation_classification_changed", "$.chat", "생성 분류 뒤 대화의 빈 입력 상태가 바뀌었습니다."),
            })
        end
        local finalChat, markerAdded, markerErrors = ensurePublicMarker(nextChat, formatted.publicMarker)
        if markerErrors then
            return failure(markerErrors)
        end
        if type(finalChat) ~= "table" then
            return failure({ makeError("invalid_chat_result", "$.chat", "공개 턴 마커 처리 결과가 올바르지 않습니다.") })
        end
        local finalTopology, finalTopologyErrors = inspectAnchoredTopology(binding, finalChat, false)
        if finalTopologyErrors then return failure(finalTopologyErrors) end
        if finalTopology.responsePresent or finalTopology.fillerCount ~= 0 then
            return failure({
                makeError("prepared_chat_topology_mismatch", "$.chat", "요청 준비 뒤 공개 마커 다음에 예상하지 않은 메시지가 남아 있습니다."),
            })
        end
        binding.phase = "inFlight"
        binding.outputObserved = nil
        binding.recoveringCleanup = nil
        local finalBindingErrors = validateBinding(binding, selectedPending)
        if #finalBindingErrors > 0 then return failure(finalBindingErrors) end
        local readyWriteErrors = writeStored(KEYS.activeRequest, binding)
        if readyWriteErrors then
            return failure(readyWriteErrors)
        end
        return success({
            generationReady = true,
            turnId = binding.turnId,
            turnNumber = binding.turnNumber,
            source = binding.source,
            publicMarker = binding.publicMarker,
            reused = reused,
            removedSayNothing = removedCount > 0,
            removedSayNothingCount = removedCount,
            markerAdded = markerAdded,
            attemptNumber = binding.attemptNumber,
            recoveredAbandonedRequest = false,
            zeroOutputRetry = false,
            commitRecovered = false,
            removedUncommittedOutput = false,
            view = published.view,
        })
    end

    loadBoundPending = function(binding)
        local bindingErrors = validateBinding(binding, nil)
        if #bindingErrors > 0 then
            return nil, bindingErrors
        end
        local key = binding.source == "pending" and KEYS.pending or KEYS.lastCommittedPending
        local pending, pendingErrors = readStored(key, true)
        if pendingErrors then
            return nil, pendingErrors
        end
        local linkedErrors = validateBinding(binding, pending)
        if #linkedErrors > 0 then
            return nil, linkedErrors
        end
        return pending, nil
    end

    local function injectRequest(promptArray)
        local promptCopy, cloneError = cloneJson(promptArray, "$.promptArray")
        if cloneError then
            return failure({ cloneError })
        end
        if type(promptCopy) ~= "table" then
            return failure({
                makeError("invalid_prompt_array", "$.promptArray", "editRequest 값은 메시지 배열이어야 합니다."),
            })
        end
        local count = 0
        for key, message in pairs(promptCopy) do
            if type(key) ~= "number" or not isInteger(key, 1) or type(message) ~= "table" then
                return failure({
                    makeError("invalid_prompt_array", "$.promptArray", "editRequest 값은 1부터 이어지는 메시지 객체 배열이어야 합니다."),
                })
            end
            count = count + 1
        end
        if count ~= #promptCopy then
            return failure({
                makeError("invalid_prompt_array", "$.promptArray", "editRequest 메시지 배열에 빈 인덱스가 있습니다."),
            })
        end

        local binding, bindingReadErrors = readStored(KEYS.activeRequest, true)
        if bindingReadErrors then
            return failure(bindingReadErrors)
        end
        local pending, pendingErrors = loadBoundPending(binding)
        if pendingErrors then
            return failure(pendingErrors)
        end
        if binding.phase ~= "inFlight" and binding.phase ~= "requestInjected" then
            return failure({
                makeError("request_not_in_flight", "$.activeRequest.phase", "editRequest에는 inFlight 또는 같은 requestInjected 요청 binding이 필요합니다."),
            })
        end
        if binding.recoveringCleanup ~= nil then
            return failure({
                makeError("request_cleanup_in_progress", "$.activeRequest.recoveringCleanup", "복구 정리 중에는 프롬프트를 주입할 수 없습니다."),
            })
        end
        if binding.outputObserved ~= nil then
            return failure({
                makeError("request_output_already_observed", "$.activeRequest.outputObserved", "이미 완성 출력이 관측된 요청에는 프롬프트를 다시 주입할 수 없습니다."),
            })
        end
        local staticData, staticErrors = loadStaticData()
        if staticErrors then
            return failure(staticErrors)
        end
        local formatted, formatErrors = formatPending(pending, staticData)
        if formatErrors then
            return failure(formatErrors)
        end
        if binding.publicMarker ~= formatted.publicMarker or not deepEqual(binding.message, formatted.message) then
            return failure({
                makeError("active_request_prompt_mismatch", "$.activeRequest", "저장된 요청 binding이 pendingTurn에서 다시 만든 프롬프트와 다릅니다."),
            })
        end

        local alreadyInjected = false
        local deduplicated = false
        local normalizedPrompt = {}
        for _, message in ipairs(promptCopy) do
            if deepEqual(message, formatted.message) then
                if alreadyInjected then
                    deduplicated = true
                else
                    normalizedPrompt[#normalizedPrompt + 1] = message
                    alreadyInjected = true
                end
            else
                normalizedPrompt[#normalizedPrompt + 1] = message
            end
        end
        promptCopy = normalizedPrompt
        if not alreadyInjected then
            local messageCopy, messageCloneError = cloneJson(formatted.message, "$.activeRequest.message")
            if messageCloneError then
                return failure({ messageCloneError })
            end
            promptCopy[#promptCopy + 1] = messageCopy
        end

        -- This durable phase is the authority boundary between editRequest and
        -- onOutput. Without it, a host-side editRequest failure could still run
        -- onOutput and commit a turn whose private event never reached the model.
        if binding.phase == "inFlight" then
            binding.phase = "requestInjected"
            local receiptWriteErrors = writeStored(KEYS.activeRequest, binding)
            if receiptWriteErrors then
                return failure(receiptWriteErrors)
            end
        end
        return success({
            promptArray = promptCopy,
            injected = not alreadyInjected,
            deduplicated = deduplicated,
            turnId = binding.turnId,
            requestPhase = binding.phase,
        })
    end

    local function prepareCurrentActiveTurn(state, staticData, allowExistingDraft)
        if state.status ~= "active" then
            return state, nil, false, nil
        end
        if allowExistingDraft then
            local currentDraft, draftReadErrors = readStored(KEYS.draft, false)
            if draftReadErrors then
                return nil, nil, false, draftReadErrors
            end
            if currentDraft ~= nil then
                local validated, validateErrors = callModule(
                    "turnDraft",
                    "validate",
                    state,
                    staticData,
                    currentDraft
                )
                if validateErrors then
                    return nil, nil, false, validateErrors
                end
                return state, validated.draft, false, nil
            end
        end
        local turnId, turnIdErrors = makeTurnId(state)
        if turnIdErrors then
            return nil, nil, false, turnIdErrors
        end
        local initialized, initializeErrors = callModule(
            "turnInitializer",
            "prepareTurn",
            state,
            staticData,
            { turnId = turnId }
        )
        if initializeErrors then
            return nil, nil, false, initializeErrors
        end
        if type(initialized.state) ~= "table" or type(initialized.draft) ~= "table" then
            return nil, nil, false, {
                makeError("invalid_next_turn", "$.runtime.turnInitializer", "다음 활성 턴 상태와 draft가 없습니다."),
            }
        end
        return initialized.state, initialized.draft, initialized.reused ~= true, nil
    end

    commitOutput = function()
        local staticData, staticErrors = loadStaticData()
        if staticErrors then
            return failure(staticErrors)
        end
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then
            return failure(authorityErrors)
        end
        local binding, bindingErrors = readStored(KEYS.activeRequest, true)
        if bindingErrors then
            return failure(bindingErrors)
        end
        local bindingValidationErrors = validateBinding(binding, nil)
        if #bindingValidationErrors > 0 then
            return failure(bindingValidationErrors)
        end
        if binding.phase ~= "requestInjected" and binding.phase ~= "committed" then
            return failure({
                makeError("request_not_committable", "$.activeRequest.phase", "출력 확정에는 requestInjected 또는 이미 committed인 요청 binding이 필요합니다."),
            })
        end
        if binding.recoveringCleanup ~= nil
            and binding.recoveringCleanup.mode ~= "resumeCommit" then
            return failure({
                makeError("request_cleanup_in_progress", "$.activeRequest.recoveringCleanup", "미확정 출력 삭제 복구 중에는 출력을 확정할 수 없습니다."),
            })
        end
        local selectedPending, pendingErrors = loadBoundPending(binding)
        if pendingErrors then
            return failure(pendingErrors)
        end
        local formatted, formatErrors = formatPending(selectedPending, staticData)
        if formatErrors then
            return failure(formatErrors)
        end
        if binding.publicMarker ~= formatted.publicMarker or not deepEqual(binding.message, formatted.message) then
            return failure({
                makeError("active_request_prompt_mismatch", "$.activeRequest", "출력과 연결된 prompt binding이 pendingTurn과 다릅니다."),
            })
        end

        if binding.phase == "requestInjected" then
            local chat, chatErrors = readChat()
            if chatErrors then return failure(chatErrors) end
            local topology, topologyErrors = inspectObservedOutput(binding, chat, false)
            if topologyErrors then return failure(topologyErrors) end
            if binding.outputObserved == nil then
                local observedBinding, cloneError = cloneJson(binding, "$.activeRequest")
                if cloneError then return failure({ cloneError }) end
                observedBinding.outputObserved = {
                    schemaVersion = 1,
                    kind = "battleOutputObserved",
                    attemptNumber = binding.attemptNumber,
                    responseIndex = topology.responseIndex,
                    responseFingerprint = topology.responseFingerprint,
                }
                local observedErrors = validateBinding(observedBinding, selectedPending)
                if #observedErrors > 0 then return failure(observedErrors) end
                local observedWriteErrors = writeStored(KEYS.activeRequest, observedBinding)
                if observedWriteErrors then return failure(observedWriteErrors) end
                binding = observedBinding
            end
        end

        local committed, commitErrors = callModule(
            "battleRuntime",
            "commitPending",
            authority,
            staticData,
            selectedPending
        )
        if commitErrors then
            return failure(commitErrors)
        end
        if type(committed.state) ~= "table" or committed.turnId ~= binding.turnId then
            return failure({
                makeError("invalid_commit_result", "$.runtime.battleRuntime", "commit 결과가 활성 요청과 연결되지 않습니다."),
            })
        end
        if binding.phase == "committed" and committed.applied == true then
            return failure({
                makeError("committed_request_reapplied", "$.activeRequest", "committed 요청이 새 상태 변경으로 다시 적용되었습니다."),
            })
        end

        local nextState, nextDraft, initialized, nextErrors = prepareCurrentActiveTurn(
            committed.state,
            staticData,
            committed.applied ~= true
        )
        if nextErrors then
            return failure(nextErrors)
        end
        local committedBinding, committedBindingErrors = buildBinding(
            selectedPending,
            formatted,
            "lastCommittedPending",
            "committed",
            binding.chatAnchor,
            binding.attemptNumber
        )
        if committedBindingErrors then
            return failure(committedBindingErrors)
        end
        local committedBindingValidationErrors = validateBinding(committedBinding, selectedPending)
        if #committedBindingValidationErrors > 0 then
            return failure(committedBindingValidationErrors)
        end

        local lastWriteErrors = writeStored(KEYS.lastCommittedPending, selectedPending)
        if lastWriteErrors then
            return failure(lastWriteErrors)
        end
        local authorityWriteErrors = writeStored(KEYS.authority, nextState)
        if authorityWriteErrors then
            return failure(authorityWriteErrors)
        end
        local draftWriteErrors = writeStored(KEYS.draft, nextDraft)
        if draftWriteErrors then
            return failure(draftWriteErrors)
        end
        local bindingWriteErrors = writeStored(KEYS.activeRequest, committedBinding)
        if bindingWriteErrors then
            return failure(bindingWriteErrors)
        end
        -- Move the binding first. If either write is silently dropped, a retry can
        -- still locate the same turn through pending or lastCommittedPending.
        local storedPending, storedPendingErrors = readStored(KEYS.pending, false)
        if storedPendingErrors then
            return failure(storedPendingErrors)
        end
        if type(storedPending) == "table" and storedPending.turnId == selectedPending.turnId then
            local pendingClearErrors = writeStored(KEYS.pending, nil)
            if pendingClearErrors then
                return failure(pendingClearErrors)
            end
        end

        local published, publishErrors = publishCurrentViewInternal(staticData)
        if publishErrors then
            return failure(publishErrors)
        end
        return success({
            generationReady = false,
            outputCommitted = true,
            turnId = committed.turnId,
            applied = committed.applied == true,
            initializedNextTurn = initialized,
            status = nextState.status,
            turnNumber = nextState.turnNumber,
            publicResult = selectedPending.turnResult.publicResult,
            view = published.view,
        })
    end

    local function getSnapshot()
        local snapshot = {
            keys = {
                authority = KEYS.authority,
                draft = KEYS.draft,
                pending = KEYS.pending,
                lastCommittedPending = KEYS.lastCommittedPending,
                activeRequest = KEYS.activeRequest,
            },
        }
        local authority, authorityErrors = readStored(KEYS.authority, false)
        if authorityErrors then return failure(authorityErrors) end
        local draft, draftErrors = readStored(KEYS.draft, false)
        if draftErrors then return failure(draftErrors) end
        local pending, pendingErrors = readStored(KEYS.pending, false)
        if pendingErrors then return failure(pendingErrors) end
        local lastCommitted, lastErrors = readStored(KEYS.lastCommittedPending, false)
        if lastErrors then return failure(lastErrors) end
        local activeRequest, requestErrors = readStored(KEYS.activeRequest, false)
        if requestErrors then return failure(requestErrors) end

        snapshot.hasBattle = authority ~= nil
        snapshot.authorityState = authority
        snapshot.draft = draft
        snapshot.pendingTurn = pending
        snapshot.lastCommittedPending = lastCommitted
        snapshot.activeRequest = activeRequest
        if type(lastCommitted) == "table" and type(lastCommitted.turnResult) == "table" then
            snapshot.lastPublicResult = lastCommitted.turnResult.publicResult
        end
        return success({ snapshot = snapshot })
    end

    local function publishCurrentView()
        local staticData, staticErrors = loadStaticData()
        if staticErrors then
            return failure(staticErrors)
        end
        local published, publishErrors = publishCurrentViewInternal(staticData)
        if publishErrors then
            return failure(publishErrors)
        end
        return success(published)
    end

    local arguments = { ... }
    if action == "startVerticalSlice" then
        return startVerticalSlice(arguments[1], arguments[2])
    elseif action == "clickCard" then
        return clickCard(arguments[1], arguments[2])
    elseif action == "registerCard" then
        return registerCard(arguments[1], arguments[2])
    elseif action == "cancelCard" then
        return cancelCard(arguments[1], arguments[2])
    elseif action == "prepareGeneration" then
        return prepareGeneration()
    elseif action == "injectRequest" then
        return injectRequest(arguments[1])
    elseif action == "commitOutput" then
        return commitOutput()
    elseif action == "publishCurrentView" then
        return publishCurrentView()
    elseif action == "getSnapshot" then
        return getSnapshot()
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 battleController 작업입니다: " .. tostring(action)),
    })
end)
