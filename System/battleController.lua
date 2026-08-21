(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local ACTIVE_REQUEST_SCHEMA_VERSION = 3
    local AFTERMATH_SCHEMA_VERSION = 2
    local VIEW_NAME = "battleView"
    local BATTLE_LOG_VIEW_NAME = "battleLogView"
    local UI_BODY_NAME = "🔯🔯🔯"
    local UI_INTERACTION_NAME = "helltrainBattleInteractionV1"
    local UI_INTERACTION_MARKER = "<!--HELLTRAIN_BATTLE_INTERACTION_V1-->"
    local TURN_SUBMIT_MARKER = "@@HELLTRAIN_TURN_SUBMIT_V1@@"
    local SAY_NOTHING = "*says nothing*"
    local CHAT_FINGERPRINT_ALGORITHM = "canonical_poly131_137_chat_v1"

    local KEYS = {
        authority = "battleRuntimeV1.authority",
        draft = "battleRuntimeV1.draft",
        pending = "battleRuntimeV1.pending",
        lastCommittedPending = "battleRuntimeV1.lastCommittedPending",
        activeRequest = "battleRuntimeV1.activeRequest",
        submission = "battleRuntimeV1.submission",
        aftermath = "battleRuntimeV1.aftermath",
    }

    local function permitCanonicalBattleView(purpose, viewName)
        return purpose == "dataBridgeCanonicalV1"
            and (viewName == VIEW_NAME or viewName == BATTLE_LOG_VIEW_NAME)
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

    local function validateAftermathOutputObserved(receipt, request, path, errors)
        if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then
            errors[#errors + 1] = makeError("invalid_aftermath_output_observed", path, "자유행동 출력 관측 영수증이 일반 객체가 아닙니다.")
            return
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            attemptNumber = true,
            responseLuaIndex = true,
            responseFingerprint = true,
        }
        for key in pairs(receipt) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_aftermath_output_observed_field", path .. "." .. tostring(key), "자유행동 출력 관측 영수증에 알 수 없는 필드가 있습니다.")
            end
        end
        local attemptNumber = type(request) == "table" and (request.attemptNumber or 1) or nil
        if receipt.schemaVersion ~= 1 or receipt.kind ~= "battleAftermathOutputObserved" then
            errors[#errors + 1] = makeError("invalid_aftermath_output_observed_schema", path, "자유행동 출력 관측 영수증 형식이 올바르지 않습니다.")
        end
        if receipt.attemptNumber ~= attemptNumber then
            errors[#errors + 1] = makeError("aftermath_output_observed_attempt_mismatch", path .. ".attemptNumber", "자유행동 출력 관측 시도가 현재 요청과 다릅니다.")
        end
        local expectedIndex = type(request) == "table"
            and isInteger(request.userLuaIndex, 1)
            and request.userLuaIndex + 1
            or nil
        if not isInteger(receipt.responseLuaIndex, 1) or receipt.responseLuaIndex ~= expectedIndex then
            errors[#errors + 1] = makeError("aftermath_output_observed_index_mismatch", path .. ".responseLuaIndex", "자유행동 출력 관측 위치가 현재 요청과 다릅니다.")
        end
        validateFingerprint(receipt.responseFingerprint, path .. ".responseFingerprint", errors)
    end

    local function validateAftermathRecoveringCleanup(receipt, request, path, errors)
        if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then
            errors[#errors + 1] = makeError("invalid_aftermath_recovering_cleanup", path, "자유행동 응답 삭제 복구 영수증이 일반 객체가 아닙니다.")
            return
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            attemptNumber = true,
            responseLuaIndex = true,
            responseFingerprint = true,
        }
        for key in pairs(receipt) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_aftermath_recovering_cleanup_field", path .. "." .. tostring(key), "자유행동 응답 삭제 복구 영수증에 알 수 없는 필드가 있습니다.")
            end
        end
        if receipt.schemaVersion ~= 1 or receipt.kind ~= "battleAftermathRecoveringCleanup" then
            errors[#errors + 1] = makeError("invalid_aftermath_recovering_cleanup_schema", path, "자유행동 응답 삭제 복구 영수증 형식이 올바르지 않습니다.")
        end
        if receipt.attemptNumber ~= (type(request) == "table" and (request.attemptNumber or 1) or nil) then
            errors[#errors + 1] = makeError("aftermath_recovering_cleanup_attempt_mismatch", path .. ".attemptNumber", "자유행동 응답 삭제 복구 시도가 현재 요청과 다릅니다.")
        end
        local expectedIndex = type(request) == "table"
            and isInteger(request.userLuaIndex, 1)
            and request.userLuaIndex + 1
            or nil
        if not isInteger(receipt.responseLuaIndex, 1) or receipt.responseLuaIndex ~= expectedIndex then
            errors[#errors + 1] = makeError("aftermath_recovering_cleanup_index_mismatch", path .. ".responseLuaIndex", "자유행동 응답 삭제 복구 위치가 현재 요청과 다릅니다.")
        end
        validateFingerprint(receipt.responseFingerprint, path .. ".responseFingerprint", errors)
    end

    local function validateAftermathCommitted(receipt, completedTurnNumber, path, errors)
        if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then
            errors[#errors + 1] = makeError("invalid_aftermath_committed", path, "확정된 자유행동 영수증이 일반 객체가 아닙니다.")
            return
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            turnNumber = true,
            responseLuaIndex = true,
            prefixFingerprint = true,
            responseIdentityFingerprint = true,
        }
        for key in pairs(receipt) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_aftermath_committed_field", path .. "." .. tostring(key), "확정된 자유행동 영수증에 알 수 없는 필드가 있습니다.")
            end
        end
        if receipt.schemaVersion ~= 1 or receipt.kind ~= "battleAftermathCommitted" then
            errors[#errors + 1] = makeError("invalid_aftermath_committed_schema", path, "확정된 자유행동 영수증 형식이 올바르지 않습니다.")
        end
        if receipt.turnNumber ~= completedTurnNumber then
            errors[#errors + 1] = makeError("aftermath_committed_turn_mismatch", path .. ".turnNumber", "확정된 자유행동 영수증의 턴이 현재 진행과 다릅니다.")
        end
        if not isInteger(receipt.responseLuaIndex, 1) then
            errors[#errors + 1] = makeError("invalid_aftermath_committed_index", path .. ".responseLuaIndex", "확정된 자유행동 응답 위치가 올바르지 않습니다.")
        end
        validateFingerprint(receipt.prefixFingerprint, path .. ".prefixFingerprint", errors)
        validateFingerprint(receipt.responseIdentityFingerprint, path .. ".responseIdentityFingerprint", errors)
    end

    local function validateAftermath(value, authority)
        local errors = {}
        local path = "$.aftermath"
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return {
                makeError("invalid_aftermath", path, "승리 후 자유행동 상태가 일반 객체가 아닙니다."),
            }
        end
        local allowed = {
            schemaVersion = true,
            kind = true,
            battleId = true,
            victoryTurnNumber = true,
            completedTurnNumber = true,
            phase = true,
            request = true,
            lastCommitted = true,
        }
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError(
                    "unknown_aftermath_field",
                    path .. "." .. tostring(key),
                    "승리 후 자유행동 상태에 알 수 없는 필드가 있습니다."
                )
            end
        end
        if (value.schemaVersion ~= 1 and value.schemaVersion ~= AFTERMATH_SCHEMA_VERSION)
            or value.kind ~= "battleAftermath" then
            errors[#errors + 1] = makeError("invalid_aftermath_schema", path, "승리 후 자유행동 상태 형식이 올바르지 않습니다.")
        end
        if not isRuntimeId(value.battleId) then
            errors[#errors + 1] = makeError("invalid_aftermath_battle", path .. ".battleId", "자유행동 battleId가 올바르지 않습니다.")
        end
        if not isInteger(value.victoryTurnNumber, 1)
            or not isInteger(value.completedTurnNumber, 1)
            or value.completedTurnNumber < value.victoryTurnNumber then
            errors[#errors + 1] = makeError("invalid_aftermath_turn", path, "자유행동 턴 범위가 올바르지 않습니다.")
        end
        if value.phase ~= "ready"
            and value.phase ~= "inFlight"
            and value.phase ~= "requestInjected"
            and value.phase ~= "settling"
            and value.phase ~= "complete" then
            errors[#errors + 1] = makeError("invalid_aftermath_phase", path .. ".phase", "자유행동 phase가 올바르지 않습니다.")
        end
        if type(authority) ~= "table"
            or authority.status ~= "victory"
            or authority.battleId ~= value.battleId
            or authority.turnNumber ~= value.victoryTurnNumber
            or not isInteger(authority.turnLimit, 1) then
            errors[#errors + 1] = makeError("aftermath_authority_mismatch", path, "자유행동 상태가 조기 승리 전투와 일치하지 않습니다.")
        elseif value.phase == "complete" then
            if value.completedTurnNumber ~= authority.turnLimit then
                errors[#errors + 1] = makeError("incomplete_aftermath", path .. ".completedTurnNumber", "완료된 자유행동이 도착 턴에 이르지 않았습니다.")
            end
        elseif value.phase == "settling" then
            if value.completedTurnNumber ~= authority.turnLimit then
                errors[#errors + 1] = makeError("invalid_aftermath_settlement", path .. ".completedTurnNumber", "정산 중인 자유행동이 도착 턴에 이르지 않았습니다.")
            end
        elseif value.completedTurnNumber >= authority.turnLimit then
            errors[#errors + 1] = makeError("aftermath_over_limit", path .. ".completedTurnNumber", "진행 중인 자유행동이 턴 제한을 넘었습니다.")
        end

        local needsRequest = value.phase == "inFlight" or value.phase == "requestInjected"
        local legacySettlingRequest = value.schemaVersion == 1 and value.phase == "settling"
        local request = value.request
        if needsRequest or legacySettlingRequest then
            if type(request) ~= "table" or getmetatable(request) ~= nil then
                if needsRequest then
                    errors[#errors + 1] = makeError("missing_aftermath_request", path .. ".request", "생성 중인 자유행동 요청 영수증이 없습니다.")
                end
            else
                local requestAllowed = {
                    turnNumber = true,
                    userLuaIndex = true,
                    userFingerprint = true,
                    attemptNumber = true,
                    outputObserved = true,
                    recoveringCleanup = true,
                }
                for key in pairs(request) do
                    if type(key) ~= "string" or not requestAllowed[key] then
                        errors[#errors + 1] = makeError(
                            "unknown_aftermath_request_field",
                            path .. ".request." .. tostring(key),
                            "자유행동 요청 영수증에 알 수 없는 필드가 있습니다."
                        )
                    end
                end
                local expectedTurnNumber = value.phase == "settling"
                    and value.completedTurnNumber
                    or value.completedTurnNumber + 1
                if request.turnNumber ~= expectedTurnNumber then
                    errors[#errors + 1] = makeError("aftermath_request_turn_mismatch", path .. ".request.turnNumber", "자유행동 요청 턴이 현재 진행과 다릅니다.")
                end
                if not isInteger(request.userLuaIndex, 1) then
                    errors[#errors + 1] = makeError("invalid_aftermath_user_index", path .. ".request.userLuaIndex", "자유행동 사용자 메시지 위치가 올바르지 않습니다.")
                end
                if request.attemptNumber ~= nil and not isInteger(request.attemptNumber, 1) then
                    errors[#errors + 1] = makeError("invalid_aftermath_attempt", path .. ".request.attemptNumber", "자유행동 요청 시도 번호가 올바르지 않습니다.")
                elseif value.schemaVersion == AFTERMATH_SCHEMA_VERSION and not isInteger(request.attemptNumber, 1) then
                    errors[#errors + 1] = makeError("missing_aftermath_attempt", path .. ".request.attemptNumber", "자유행동 요청 시도 번호가 없습니다.")
                end
                validateFingerprint(request.userFingerprint, path .. ".request.userFingerprint", errors)
                if request.outputObserved ~= nil then
                    if value.phase ~= "requestInjected" then
                        errors[#errors + 1] = makeError("aftermath_output_observed_phase_mismatch", path .. ".request.outputObserved", "자유행동 출력 관측 영수증은 지시가 주입된 요청에만 존재할 수 있습니다.")
                    end
                    validateAftermathOutputObserved(request.outputObserved, request, path .. ".request.outputObserved", errors)
                end
                if request.recoveringCleanup ~= nil then
                    if value.phase ~= "requestInjected" then
                        errors[#errors + 1] = makeError("aftermath_recovering_cleanup_phase_mismatch", path .. ".request.recoveringCleanup", "자유행동 응답 삭제 복구 영수증은 지시가 주입된 요청에만 존재할 수 있습니다.")
                    end
                    if request.outputObserved ~= nil then
                        errors[#errors + 1] = makeError("aftermath_recovery_receipt_conflict", path .. ".request", "출력 관측과 응답 삭제 복구 영수증은 함께 존재할 수 없습니다.")
                    end
                    validateAftermathRecoveringCleanup(request.recoveringCleanup, request, path .. ".request.recoveringCleanup", errors)
                end
            end
        elseif value.request ~= nil then
            errors[#errors + 1] = makeError("unexpected_aftermath_request", path .. ".request", "대기 또는 완료 상태에 생성 요청이 남아 있습니다.")
        end
        if value.lastCommitted ~= nil then
            validateAftermathCommitted(value.lastCommitted, value.completedTurnNumber, path .. ".lastCommitted", errors)
        elseif value.schemaVersion == AFTERMATH_SCHEMA_VERSION then
            errors[#errors + 1] = makeError("missing_aftermath_committed", path .. ".lastCommitted", "확정된 자유행동 영수증이 없습니다.")
        end
        return errors
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
            responseIndex = true,
            prefixFingerprint = true,
            repairableTail = true,
        }
        for key in pairs(anchor) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError("unknown_chat_anchor_field", path .. "." .. tostring(key), "채팅 anchor에 알 수 없는 필드가 있습니다.")
            end
        end
        if anchor.schemaVersion ~= 2 or anchor.kind ~= "battleChatAnchor" then
            errors[#errors + 1] = makeError("invalid_chat_anchor_schema", path, "채팅 anchor 스키마가 올바르지 않습니다.")
        end
        if not isInteger(anchor.prefixMessageCount, 0) then
            errors[#errors + 1] = makeError("invalid_chat_anchor_count", path .. ".prefixMessageCount", "anchor prefix 메시지 수가 올바르지 않습니다.")
        end
        if not isInteger(anchor.responseIndex, 0) or anchor.responseIndex ~= anchor.prefixMessageCount then
            errors[#errors + 1] = makeError("invalid_chat_anchor_index", path .. ".responseIndex", "0-based 응답 위치가 prefix 메시지 수와 일치하지 않습니다.")
        end
        validateFingerprint(anchor.prefixFingerprint, path .. ".prefixFingerprint", errors)
        if anchor.repairableTail ~= nil then
            local repair = anchor.repairableTail
            local repairPath = path .. ".repairableTail"
            if type(repair) ~= "table" or getmetatable(repair) ~= nil then
                errors[#errors + 1] = makeError("invalid_chat_anchor_repair", repairPath, "복원 가능한 채팅 tail이 일반 객체가 아닙니다.")
            else
                local repairAllowed = { message = true, prefixFingerprint = true }
                for key in pairs(repair) do
                    if type(key) ~= "string" or not repairAllowed[key] then
                        errors[#errors + 1] = makeError("unknown_chat_anchor_repair_field", repairPath .. "." .. tostring(key), "복원 가능한 채팅 tail에 알 수 없는 필드가 있습니다.")
                    end
                end
                local message = repair.message
                if anchor.prefixMessageCount < 1
                    or type(message) ~= "table"
                    or getmetatable(message) ~= nil
                    or message.role ~= "char"
                    or type(message.data) ~= "string"
                    or string.match(message.data, "%S") == nil
                    or message.time ~= 0 then
                    errors[#errors + 1] = makeError("invalid_chat_anchor_repair_message", repairPath .. ".message", "Lua로 추가된 실제 캐릭터 장면만 anchor tail로 복원할 수 있습니다.")
                else
                    for key in pairs(message) do
                        if key ~= "role" and key ~= "data" and key ~= "time" then
                            errors[#errors + 1] = makeError("unknown_chat_anchor_repair_message_field", repairPath .. ".message." .. tostring(key), "복원할 캐릭터 장면에 알 수 없는 필드가 있습니다.")
                        end
                    end
                end
                validateFingerprint(repair.prefixFingerprint, repairPath .. ".prefixFingerprint", errors)
            end
        end
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
        local expectedIndex = type(binding.chatAnchor) == "table" and binding.chatAnchor.responseIndex or nil
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
        local expectedIndex = type(binding.chatAnchor) == "table" and binding.chatAnchor.responseIndex or nil
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

    local function inspectDraftInteractionToken(authority, staticData, draft)
        local inspected, inspectErrors = callModule(
            "turnDraft",
            "inspect",
            authority,
            staticData,
            draft
        )
        if inspectErrors then return nil, inspectErrors end
        if type(inspected.interactionToken) ~= "string" or inspected.interactionToken == "" then
            return nil, {
                makeError("missing_interaction_token", "$.runtime.turnDraft.inspect", "현재 turnDraft의 interaction token을 만들지 못했습니다."),
            }
        end
        return inspected.interactionToken, nil
    end

    local function readArmedSubmission(authority, staticData, draft)
        local receipt, readErrors = readStored(KEYS.submission, false)
        if readErrors then return nil, readErrors end
        if receipt == nil then return nil, nil end
        if type(receipt) ~= "string" or receipt == "" then
            return nil, {
                makeError("invalid_submission", "$.submission", "턴 제출 변수는 비어 있지 않은 interaction token이어야 합니다."),
            }
        end
        local interactionToken, tokenErrors = inspectDraftInteractionToken(authority, staticData, draft)
        if tokenErrors then return nil, tokenErrors end
        if receipt ~= interactionToken then
            return nil, {
                makeError("stale_submission", "$.submission", "턴 제출 변수가 현재 카드 선택과 일치하지 않습니다."),
            }
        end
        return receipt, nil
    end

    local function clearSubmission()
        return writeStored(KEYS.submission, nil)
    end

    local function isExactFiller(message)
        return type(message) == "table"
            and message.role == "user"
            and (message.data == SAY_NOTHING or message.data == TURN_SUBMIT_MARKER)
    end

    local function createPlannedChatAnchor(chat)
        local logicalLength = #chat
        while logicalLength > 0 and isExactFiller(chat[logicalLength]) do
            logicalLength = logicalLength - 1
        end
        local prefixMessageCount = logicalLength
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            1,
            prefixMessageCount,
            "$.chatAnchor.prefix"
        )
        if fingerprintError then return nil, { fingerprintError } end
        local anchor = {
            schemaVersion = 2,
            kind = "battleChatAnchor",
            prefixMessageCount = prefixMessageCount,
            responseIndex = prefixMessageCount,
            prefixFingerprint = fingerprint,
        }
        local tail = chat[prefixMessageCount]
        if prefixMessageCount > 0
            and type(tail) == "table"
            and tail.role == "char"
            and type(tail.data) == "string"
            and string.match(tail.data, "%S") ~= nil
            and tail.time == 0 then
            local previousFingerprint, previousFingerprintError = fingerprintChatRange(
                chat,
                1,
                prefixMessageCount - 1,
                "$.chatAnchor.repairablePrefix"
            )
            if previousFingerprintError then return nil, { previousFingerprintError } end
            local tailCopy, tailCopyError = cloneJson(tail, "$.chatAnchor.repairableTail.message")
            if tailCopyError then return nil, { tailCopyError } end
            anchor.repairableTail = {
                message = tailCopy,
                prefixFingerprint = previousFingerprint,
            }
        end
        return anchor, nil
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
                makeError("chat_anchor_prefix_mismatch", "$.chat", "요청 이전 대화가 요청 준비 시점의 채팅 anchor와 다릅니다."),
            }
        end
        return nil
    end

    local function restoreRepairableAnchorTail(binding, chat)
        local anchor = binding.chatAnchor
        if #chat >= anchor.prefixMessageCount then
            return chat, false, nil
        end
        local repair = anchor.repairableTail
        if type(repair) ~= "table" or #chat ~= anchor.prefixMessageCount - 1 then
            return chat, false, nil
        end
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            1,
            #chat,
            "$.chatAnchor.repairableCurrentPrefix"
        )
        if fingerprintError then return nil, false, { fingerprintError } end
        if not fingerprintsEqual(fingerprint, repair.prefixFingerprint) then
            return chat, false, nil
        end
        if type(addChat) ~= "function" then
            return nil, false, {
                makeError("chat_write_unavailable", "$.host.addChat", "리롤이 함께 제거한 접근 장면을 복원할 addChat 호스트 함수를 찾을 수 없습니다."),
            }
        end
        local ok, addError = pcall(addChat, triggerId, "char", repair.message.data)
        if not ok then
            return nil, false, {
                makeError("chat_anchor_repair_failed", "$.chat", "리롤이 함께 제거한 접근 장면을 복원하지 못했습니다: " .. tostring(addError)),
            }
        end
        local restored, readErrors = readChat()
        if readErrors then return nil, false, readErrors end
        local prefixErrors = validateAnchorPrefix(binding, restored)
        if prefixErrors then
            return nil, false, prefixErrors
        end
        return restored, true, nil
    end

    local function inspectPreparingTopology(binding, chat)
        local prefixErrors = validateAnchorPrefix(binding, chat)
        if prefixErrors then return nil, prefixErrors end
        local cursor = binding.chatAnchor.prefixMessageCount + 1
        local fillerCount = 0
        for index = cursor, #chat do
            if not isExactFiller(chat[index]) then
                return nil, {
                    makeError("preparing_chat_topology_mismatch", "$.chat[" .. index .. "]", "준비 중인 요청의 기준 대화 뒤에는 trailing filler만 올 수 있습니다."),
                }
            end
            fillerCount = fillerCount + 1
        end
        return {
            fillerCount = fillerCount,
        }, nil
    end

    local function inspectAnchoredTopology(binding, chat, requireFiller)
        local prefixErrors = validateAnchorPrefix(binding, chat)
        if prefixErrors then return nil, prefixErrors end
        local prefixCount = binding.chatAnchor.prefixMessageCount
        local fillerCount = 0
        local cursor = #chat
        while cursor > prefixCount and isExactFiller(chat[cursor]) do
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
        local responseLuaIndex = prefixCount + 1
        if cursor == responseLuaIndex then
            local response = chat[responseLuaIndex]
            if type(response) ~= "table" or response.role ~= "char" then
                return nil, {
                    makeError("recovery_response_role_mismatch", "$.chat[" .. responseLuaIndex .. "]", "요청 응답 위치의 미확정 메시지가 캐릭터 메시지가 아닙니다."),
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
        elseif cursor ~= prefixCount then
            return nil, {
                makeError("recovery_chat_topology_mismatch", "$.chat", "요청 기준 대화 뒤에 자동 복구가 소유한다고 증명할 수 없는 메시지가 있습니다."),
            }
        end
        return {
            responseLuaIndex = responseLuaIndex,
            responseIndex = binding.chatAnchor.responseIndex,
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

    local function removeTrailingSayNothing(chat, minimumLength)
        local current = chat
        local removedCount = 0
        while true do
            local last = current[#current]
            if #current <= (minimumLength or 0)
                or not isExactFiller(last) then
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
                    makeError("say_nothing_remove_failed", "$.chat[" .. #current .. "]", "자동 제출 메시지를 제거하지 못했습니다: " .. tostring(removeError)),
                }
            end
            local after, readErrors = readChat()
            if readErrors then
                return nil, removedCount, readErrors
            end
            if #after ~= #current - 1 then
                return nil, removedCount, {
                    makeError("say_nothing_remove_not_persisted", "$.chat", "자동 제출 메시지 제거 뒤 대화 길이가 바뀌지 않았습니다."),
                }
            end
            for index = 1, #after do
                if not deepEqual(after[index], current[index]) then
                    return nil, removedCount, {
                        makeError("say_nothing_remove_mismatch", "$.chat[" .. index .. "]", "자동 제출 메시지 제거가 앞선 대화를 변경했습니다."),
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

    local function publishCurrentViewInternal(staticData, suppressRefresh, skipUiRender, interactionOnly)
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
        local aftermath, aftermathErrors = readStored(KEYS.aftermath, false)
        if aftermathErrors then
            return nil, aftermathErrors
        end
        if aftermath ~= nil then
            local aftermathValidationErrors = validateAftermath(aftermath, authority)
            if #aftermathValidationErrors > 0 then
                return nil, aftermathValidationErrors
            end
            if aftermath.phase == "ready"
                or aftermath.phase == "inFlight"
                or aftermath.phase == "requestInjected" then
                context.aftermath = {
                    completedTurnNumber = aftermath.completedTurnNumber,
                    phase = aftermath.phase,
                }
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
                else
                    local submission, submissionErrors = readArmedSubmission(
                        authority,
                        staticData,
                        draft
                    )
                    if submissionErrors then return nil, submissionErrors end
                    if submission ~= nil then
                        context.submissionArmed = true
                    end
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

        if skipUiRender == true then
            return {
                view = built.view,
                wireFormat = published.wireFormat,
                bytes = published.bytes,
            }, nil
        end

        -- getLoreBooks/loadLores는 HTML을 반환하기 전에 CBS를 평가한다.
        -- 따라서 UI 조각은 방금 쓴 battleView wire를 재읽어 확인한 뒤에만
        -- 로드해야 현재 턴의 View로 렌더링된다.
        if type(loadLores) ~= "function" then
            return nil, {
                makeError("lore_loader_unavailable", "$.host.loadLores", "전투 UI 로어북을 읽을 loadLores 함수를 찾을 수 없습니다."),
            }
        end
        if type(setChatVar) ~= "function" or type(getChatVar) ~= "function" then
            return nil, {
                makeError("ui_write_unavailable", "$.host.setChatVar", "전투 UI를 게시할 setChatVar/getChatVar 함수를 찾을 수 없습니다."),
            }
        end

        local frameUi = nil
        if interactionOnly == true then
            local frameReadOk, storedFrame = pcall(getChatVar, triggerId, UI_BODY_NAME)
            if frameReadOk
                and type(storedFrame) == "string"
                and string.find(storedFrame, UI_INTERACTION_MARKER, 1, true) ~= nil then
                frameUi = storedFrame
            else
                return nil, {
                    makeError("missing_ui_frame", "$.chatVar.battleUi", "카드 상호작용을 반영할 현재 턴의 전투 UI 프레임이 없습니다."),
                }
            end
        end

        if interactionOnly ~= true then
            local frameLoadOk, loadedFrame = pcall(loadLores, triggerId, "battleui.html")
            if not frameLoadOk then
                return nil, {
                    makeError("lore_load_failed", "$.lore.battleui", "battleui.html을 읽지 못했습니다: " .. tostring(loadedFrame)),
                }
            end
            if type(loadedFrame) ~= "string"
                or loadedFrame == ""
                or string.find(loadedFrame, UI_INTERACTION_MARKER, 1, true) == nil then
                return nil, {
                    makeError("invalid_ui_frame", "$.lore.battleui", "battleui.html 고정 프레임에 상호작용 마커가 없습니다."),
                }
            end
            frameUi = loadedFrame
        end

        local interactionLoadOk, interactionUi = pcall(loadLores, triggerId, "battleui-interaction.html")
        if not interactionLoadOk then
            return nil, {
                makeError("lore_load_failed", "$.lore.battleuiInteraction", "battleui-interaction.html을 읽지 못했습니다: " .. tostring(interactionUi)),
            }
        end
        if type(interactionUi) ~= "string" or interactionUi == "" then
            return nil, {
                makeError("missing_lore", "$.lore.battleuiInteraction", "battleui-interaction.html 로어북 내용이 없습니다."),
            }
        end

        if interactionOnly ~= true then
            local frameWriteOk, frameWriteError = pcall(setChatVar, triggerId, UI_BODY_NAME, frameUi)
            if not frameWriteOk then
                return nil, {
                    makeError("ui_write_failed", "$.chatVar.battleUi", "전투 UI 프레임 쓰기에 실패했습니다: " .. tostring(frameWriteError)),
                }
            end
            local frameReadOk, storedFrame = pcall(getChatVar, triggerId, UI_BODY_NAME)
            if not frameReadOk or storedFrame ~= frameUi then
                return nil, {
                    makeError("ui_write_not_persisted", "$.chatVar.battleUi", "쓰기 뒤 읽은 전투 UI 프레임이 battleui.html과 다릅니다."),
                }
            end
        end

        local interactionWriteOk, interactionWriteError = pcall(
            setChatVar,
            triggerId,
            UI_INTERACTION_NAME,
            interactionUi
        )
        if not interactionWriteOk then
            return nil, {
                makeError("ui_write_failed", "$.chatVar.battleUiInteraction", "전투 UI 상호작용 조각 쓰기에 실패했습니다: " .. tostring(interactionWriteError)),
            }
        end
        local interactionReadOk, storedInteraction = pcall(getChatVar, triggerId, UI_INTERACTION_NAME)
        if not interactionReadOk or storedInteraction ~= interactionUi then
            return nil, {
                makeError("ui_write_not_persisted", "$.chatVar.battleUiInteraction", "쓰기 뒤 읽은 전투 UI 상호작용 조각이 로어북과 다릅니다."),
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
            uiFrame = frameUi,
            uiInteraction = interactionUi,
            interactionOnly = interactionOnly == true,
        }, nil
    end

    local function publishTerminalBattleLog(authority, staticData)
        if type(authority) ~= "table"
            or (authority.status ~= "victory" and authority.status ~= "defeat") then
            return nil, {
                makeError("battle_log_requires_terminal", "$.authority.status", "종료된 전투에서만 상세 로그를 게시할 수 있습니다."),
            }
        end
        local built, buildErrors = callModule(
            "battleHistory",
            "buildPublicView",
            authority.history,
            staticData
        )
        if buildErrors then return nil, buildErrors end
        if type(built.view) ~= "table" or built.view.available ~= true then
            return nil, {
                makeError("missing_terminal_battle_log", "$.runtime.battleHistory.view", "종료 전투의 공개 상세 로그를 만들지 못했습니다."),
            }
        end
        local published, publishErrors = callModule(
            "dataBridge",
            "_publishCanonical",
            BATTLE_LOG_VIEW_NAME,
            built.view,
            permitCanonicalBattleView
        )
        if publishErrors then return nil, publishErrors end
        if type(published.encoded) ~= "string" or published.encoded == "" then
            return nil, {
                makeError("missing_published_battle_log", "$.runtime.dataBridge.encoded", "상세 전투 로그 게시 문자열이 없습니다."),
            }
        end
        if type(getChatVar) ~= "function" then
            return nil, {
                makeError("battle_log_verify_unavailable", "$.host.getChatVar", "게시한 상세 전투 로그를 검증할 수 없습니다."),
            }
        end
        local readOk, storedWire = pcall(getChatVar, triggerId, BATTLE_LOG_VIEW_NAME)
        if not readOk then
            return nil, {
                makeError("battle_log_verify_failed", "$.chatVar.battleLogView", "게시한 상세 전투 로그를 다시 읽지 못했습니다: " .. tostring(storedWire)),
            }
        end
        if storedWire ~= published.encoded then
            return nil, {
                makeError("battle_log_write_not_persisted", "$.chatVar.battleLogView", "게시 뒤 읽은 상세 전투 로그가 인코딩 결과와 다릅니다."),
            }
        end
        return built.view, nil
    end

    local function validateBattleReadySetup(setupState, staticData)
        local setupCopy, setupCopyError = cloneJson(setupState, "$.setupState")
        if setupCopyError then
            return nil, nil, { setupCopyError }
        end
        local validated, validationErrors = callModule(
            "gameSetup",
            "validate",
            setupCopy,
            staticData
        )
        if validationErrors then
            return nil, nil, validationErrors
        end
        if type(validated.state) ~= "table" or getmetatable(validated.state) ~= nil then
            return nil, nil, {
                makeError("missing_validated_setup", "$.runtime.gameSetup.state", "gameSetup.validate가 정규 설정 상태를 반환하지 않았습니다."),
            }
        end
        if not deepEqual(setupCopy, validated.state) then
            return nil, nil, {
                makeError("setup_validation_mismatch", "$.setupState", "설정 상태가 gameSetup.validate의 정규 상태와 정확히 일치하지 않습니다."),
            }
        end
        if validated.state.phase ~= "battleReady" then
            return nil, nil, {
                makeError("setup_not_battle_ready", "$.setupState.phase", "캐릭터 선택까지 끝난 battleReady 설정만 전투를 시작할 수 있습니다."),
            }
        end

        local battleSpec = validated.state.battleSpec
        if type(battleSpec) ~= "table" or getmetatable(battleSpec) ~= nil then
            return nil, nil, {
                makeError("missing_battle_spec", "$.setupState.battleSpec", "battleReady 설정에 전투 사양이 없습니다."),
            }
        end
        local playerCardIds, deckCopyError = cloneJson(
            validated.state.selectedCardIds,
            "$.setupState.selectedCardIds"
        )
        if deckCopyError then
            return nil, nil, { deckCopyError }
        end
        local normalizedSetup, normalizedError = cloneJson(validated.state, "$.setupState")
        if normalizedError then
            return nil, nil, { normalizedError }
        end
        return normalizedSetup, {
            battleId = battleSpec.battleId,
            seed = battleSpec.seed,
            playerCardIds = playerCardIds,
            characterId = validated.state.selectedCharacterId,
            environmentId = battleSpec.environmentId,
        }, nil
    end

    local function buildInitialBattleFromSetup(spec, staticData)
        local bootstrap, bootstrapErrors = callModule(
            "battleBootstrap",
            "fromSetup",
            spec,
            staticData
        )
        if bootstrapErrors then
            return nil, bootstrapErrors
        end
        if bootstrap.referencesValidated ~= true or type(bootstrap.state) ~= "table" then
            return nil, {
                makeError("invalid_setup_bootstrap_result", "$.runtime.battleBootstrap", "fromSetup이 검증된 battleState를 반환하지 않았습니다."),
            }
        end
        local turnId, turnIdErrors = makeTurnId(bootstrap.state)
        if turnIdErrors then
            return nil, turnIdErrors
        end
        local initialized, initializeErrors = callModule(
            "turnInitializer",
            "prepareTurn",
            bootstrap.state,
            staticData,
            { turnId = turnId }
        )
        if initializeErrors then
            return nil, initializeErrors
        end
        if type(initialized.state) ~= "table" or type(initialized.draft) ~= "table" then
            return nil, {
                makeError("invalid_initial_turn", "$.runtime.turnInitializer", "setup 전투의 첫 턴 상태와 draft가 없습니다."),
            }
        end
        if initialized.state.battleId ~= spec.battleId then
            return nil, {
                makeError("initialized_battle_id_mismatch", "$.runtime.turnInitializer.state.battleId", "첫 턴 상태의 battleId가 설정 사양과 다릅니다."),
            }
        end
        return {
            authority = initialized.state,
            draft = initialized.draft,
            pending = nil,
            lastCommittedPending = nil,
            activeRequest = nil,
            submission = nil,
            aftermath = nil,
            turnId = turnId,
        }, nil
    end

    local function readRuntimeBundle()
        local values = {}
        for _, name in ipairs({
            "authority",
            "draft",
            "pending",
            "lastCommittedPending",
            "activeRequest",
            "submission",
            "aftermath",
        }) do
            local value, errors = readStored(KEYS[name], false)
            if errors then
                return nil, errors
            end
            values[name] = value
        end
        return values, nil
    end

    local function buildTerminalSummary(authority, lastCommitted, staticData)
        if type(authority) ~= "table"
            or (authority.status ~= "victory" and authority.status ~= "defeat") then
            return nil, {
                makeError(
                    "battle_not_terminal",
                    "$.state.authority.status",
                    "승리 또는 패배로 확정된 전투만 정산할 수 있습니다."
                ),
            }
        end
        if type(lastCommitted) ~= "table"
            or lastCommitted.battleId ~= authority.battleId
            or lastCommitted.turnId ~= authority.lastCommittedTurnId
            or type(lastCommitted.afterState) ~= "table"
            or not deepEqual(lastCommitted.afterState, authority) then
            return nil, {
                makeError(
                    "terminal_receipt_mismatch",
                    "$.state.lastCommittedPending",
                    "마지막 확정 턴 영수증이 종료 권위 상태와 정확히 일치하지 않습니다."
                ),
            }
        end

        local presented, presentationErrors = callModule(
            "turnPresentation",
            "build",
            lastCommitted,
            staticData
        )
        if presentationErrors then return nil, presentationErrors end
        if type(presented.lastTurn) ~= "table" or presented.lastTurn.available ~= true then
            return nil, {
                makeError(
                    "missing_terminal_presentation",
                    "$.runtime.turnPresentation.lastTurn",
                    "종료 턴의 공개 결과를 검증하지 못했습니다."
                ),
            }
        end

        local events = type(lastCommitted.turnResult) == "table"
            and type(lastCommitted.turnResult.publicResult) == "table"
            and lastCommitted.turnResult.publicResult.events
            or nil
        if type(events) ~= "table" then
            return nil, {
                makeError(
                    "missing_terminal_events",
                    "$.state.lastCommittedPending.turnResult.publicResult.events",
                    "종료 턴의 공개 사건 배열이 없습니다."
                ),
            }
        end
        local outcomePayload
        local outcomeCount = 0
        local sessionStatus
        local sessionCount = 0
        for _, event in ipairs(events) do
            if type(event) == "table" and event.type == "outcome" then
                outcomeCount = outcomeCount + 1
                outcomePayload = event.payload
            elseif type(event) == "table" and event.type == "session_ended" then
                sessionCount = sessionCount + 1
                sessionStatus = type(event.payload) == "table" and event.payload.status or nil
            end
        end
        if outcomeCount ~= 1
            or sessionCount ~= 1
            or type(outcomePayload) ~= "table"
            or outcomePayload.status ~= authority.status
            or sessionStatus ~= authority.status
            or (outcomePayload.reasonCode ~= "card_checkpoint"
                and outcomePayload.reasonCode ~= "turn_end_checkpoint"
                and outcomePayload.reasonCode ~= "turn_limit")
            or outcomePayload.stealth ~= authority.player.stealth
            or outcomePayload.resistance ~= authority.character.resistance then
            return nil, {
                makeError(
                    "invalid_terminal_events",
                    "$.state.lastCommittedPending.turnResult.publicResult.events",
                    "종료 공개 사건이 권위 상태의 승패와 최종 수치에 일치하지 않습니다."
                ),
            }
        end
        if outcomePayload.reasonCode == "turn_limit" and authority.status ~= "defeat" then
            return nil, {
                makeError(
                    "invalid_terminal_reason",
                    "$.state.lastCommittedPending.turnResult.publicResult.events",
                    "턴 제한 종료는 패배 결과여야 합니다."
                ),
            }
        end

        local transitCopy, transitError = cloneJson(authority.transit, "$.summary.transit")
        if transitError then return nil, { transitError } end
        return {
            battleId = authority.battleId,
            turnId = authority.lastCommittedTurnId,
            characterId = authority.character.characterId,
            status = authority.status,
            reasonCode = outcomePayload.reasonCode,
            turnNumber = authority.turnNumber,
            turnLimit = authority.turnLimit,
            finalStealth = authority.player.stealth,
            finalResistance = authority.character.resistance,
            environmentId = authority.environmentId,
            transit = transitCopy,
        }, nil
    end

    local function buildAftermathInstruction(authority, aftermath)
        local finalTurn = aftermath.completedTurnNumber + 1 == authority.turnLimit
        local lines = {
            "[함락 후 자유행동]",
            "전투 승리는 이미 확정되었다. 카드, 저항, 은폐, 무드, 전투 판정이나 보상을 언급하지 마라.",
            "사용자가 방금 입력한 행위를 그대로 존중하여 캐릭터의 반응과 열차 안의 장면을 자연스럽게 이어서 묘사하라.",
            "사용자가 입력하지 않은 추가 행동, 대사, 생각을 플레이어에게 부여하지 마라.",
        }
        if finalTurn then
            lines[#lines + 1] = "이번 자유행동은 마지막이다. 응답의 끝에서 반드시 열차가 목적지 역에 도착하고 캐릭터가 황급히 열차에서 내리는 장면으로 마무리하라."
        end
        return {
            role = "system",
            content = table.concat(lines, "\n"),
        }
    end

    local function fingerprintAftermathResponseIdentity(response, path)
        if type(response) ~= "table" or response.role ~= "char" then
            return nil, makeError("invalid_aftermath_response_identity", path, "자유행동 응답 식별자를 만들 수 없습니다.")
        end
        return fingerprintChatRange({ {
            role = response.role,
            time = response.time or 0,
        } }, 1, 1, path)
    end

    local function buildAftermathCommitted(chat, turnNumber, responseLuaIndex)
        local response = isInteger(responseLuaIndex, 1) and chat[responseLuaIndex] or nil
        if not isInteger(responseLuaIndex, 1)
            or type(response) ~= "table"
            or response.role ~= "char" then
            return nil, {
                makeError("invalid_aftermath_committed_response", "$.chat", "확정할 자유행동 캐릭터 응답 위치가 올바르지 않습니다."),
            }
        end
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            1,
            responseLuaIndex - 1,
            "$.aftermath.lastCommitted.prefix"
        )
        if fingerprintError then return nil, { fingerprintError } end
        local responseIdentity, identityError = fingerprintAftermathResponseIdentity(
            response,
            "$.aftermath.lastCommitted.responseIdentity"
        )
        if identityError then return nil, { identityError } end
        return {
            schemaVersion = 1,
            kind = "battleAftermathCommitted",
            turnNumber = turnNumber,
            responseLuaIndex = responseLuaIndex,
            prefixFingerprint = fingerprint,
            responseIdentityFingerprint = responseIdentity,
        }, nil
    end

    local function validateAftermathCommittedChat(aftermath, chat)
        local receipt = aftermath.lastCommitted
        if receipt == nil then return nil end
        if #chat < receipt.responseLuaIndex then
            return {
                makeError("aftermath_committed_chat_missing", "$.chat", "이미 확정된 자유행동 장면이 대화에서 삭제되었습니다."),
            }
        end
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            1,
            receipt.responseLuaIndex - 1,
            "$.aftermath.lastCommitted.currentPrefix"
        )
        if fingerprintError then return { fingerprintError } end
        local response = chat[receipt.responseLuaIndex]
        if type(response) ~= "table" or response.role ~= "char" then
            return {
                makeError("aftermath_committed_chat_changed", "$.chat", "이미 확정된 자유행동 장면이 변경되었습니다."),
            }
        end
        local responseIdentity, identityError = fingerprintAftermathResponseIdentity(
            response,
            "$.aftermath.lastCommitted.currentResponseIdentity"
        )
        if identityError then return { identityError } end
        if not fingerprintsEqual(fingerprint, receipt.prefixFingerprint)
            or not fingerprintsEqual(responseIdentity, receipt.responseIdentityFingerprint) then
            return {
                makeError("aftermath_committed_chat_changed", "$.chat", "이미 확정된 자유행동 장면이 변경되었습니다."),
            }
        end
        return nil
    end

    local function migrateLegacyAftermath(authority, aftermath)
        if aftermath.schemaVersion ~= 1 or aftermath.phase == "complete" then
            return aftermath, nil
        end
        local chat, chatErrors = readChat()
        if chatErrors then return nil, chatErrors end
        local binding, bindingErrors = readStored(KEYS.activeRequest, true)
        if bindingErrors then return nil, bindingErrors end
        local bindingValidationErrors = validateBinding(binding, nil)
        if #bindingValidationErrors > 0 then return nil, bindingValidationErrors end
        if binding.phase ~= "committed" or binding.battleId ~= aftermath.battleId then
            return nil, {
                makeError("legacy_aftermath_migration_unsafe", "$.activeRequest", "기존 자유행동의 기준 전투 응답을 안전하게 찾을 수 없습니다."),
            }
        end
        local prefixErrors = validateAnchorPrefix(binding, chat)
        if prefixErrors then return nil, prefixErrors end
        local responseLuaIndex = binding.chatAnchor.responseIndex + 1
            + (aftermath.completedTurnNumber - aftermath.victoryTurnNumber) * 2
        if aftermath.phase == "ready" then
            local suffixCount = #chat - responseLuaIndex
            local first = chat[responseLuaIndex + 1]
            local firstIsInput = type(first) == "table"
                and first.role == "user"
                and not isExactFiller(first)
            if suffixCount < 0
                or (suffixCount == 1
                    and not (firstIsInput or isExactFiller(first)))
                or suffixCount > 1 then
                return nil, {
                    makeError("legacy_aftermath_migration_unsafe", "$.chat", "기존 자유행동 대화 끝을 안전하게 이전할 수 없습니다."),
                }
            end
        elseif aftermath.phase == "settling" then
            if type(aftermath.request) ~= "table"
                or aftermath.request.userLuaIndex + 1 ~= responseLuaIndex then
                return nil, {
                    makeError("legacy_aftermath_migration_unsafe", "$.aftermath.request", "기존 자유행동 정산 응답 위치를 안전하게 이전할 수 없습니다."),
                }
            end
        elseif type(aftermath.request) ~= "table"
            or aftermath.request.userLuaIndex ~= responseLuaIndex + 1 then
            return nil, {
                makeError("legacy_aftermath_migration_unsafe", "$.aftermath.request", "기존 자유행동 요청 위치를 안전하게 이전할 수 없습니다."),
            }
        end
        local receipt, receiptErrors = buildAftermathCommitted(
            chat,
            aftermath.completedTurnNumber,
            responseLuaIndex
        )
        if receiptErrors then return nil, receiptErrors end
        aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
        aftermath.lastCommitted = receipt
        if aftermath.phase == "settling" then
            aftermath.request = nil
        elseif type(aftermath.request) == "table" then
            aftermath.request.attemptNumber = aftermath.request.attemptNumber or 1
        end
        local validationErrors = validateAftermath(aftermath, authority)
        if #validationErrors > 0 then return nil, validationErrors end
        local writeErrors = writeStored(KEYS.aftermath, aftermath)
        if writeErrors then return nil, writeErrors end
        return aftermath, nil
    end

    local function validateAftermathRequestChat(aftermath, chat, requireResponse, allowTrailingFillers)
        local committedErrors = validateAftermathCommittedChat(aftermath, chat)
        if committedErrors then return nil, committedErrors end
        local request = aftermath.request
        local user = type(request) == "table" and chat[request.userLuaIndex] or nil
        if type(user) ~= "table" or user.role ~= "user" then
            return nil, {
                makeError("aftermath_user_missing", "$.chat", "자유행동 요청에 연결된 사용자 입력이 없습니다."),
            }
        end
        if type(aftermath.lastCommitted) == "table"
            and request.userLuaIndex ~= aftermath.lastCommitted.responseLuaIndex + 1 then
            return nil, {
                makeError("aftermath_chat_topology_mismatch", "$.chat", "확정 장면과 현재 자유행동 입력 사이에 예상하지 않은 메시지가 있습니다."),
            }
        end
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            request.userLuaIndex,
            1,
            "$.aftermath.request.user"
        )
        if fingerprintError then return nil, { fingerprintError } end
        if not fingerprintsEqual(fingerprint, request.userFingerprint) then
            return nil, {
                makeError("aftermath_user_changed", "$.chat", "생성 중인 자유행동 사용자 입력이 변경되었습니다."),
            }
        end
        local response = chat[request.userLuaIndex + 1]
        if allowTrailingFillers and isExactFiller(response) then
            response = nil
        end
        if response ~= nil and (type(response) ~= "table" or response.role ~= "char") then
            return nil, {
                makeError("aftermath_response_role_mismatch", "$.chat", "자유행동 응답 위치에 캐릭터 메시지가 아닌 항목이 있습니다."),
            }
        end
        local expectedLength = request.userLuaIndex + (response ~= nil and 1 or 0)
        if #chat ~= expectedLength then
            if #chat < expectedLength or not allowTrailingFillers then
                return nil, {
                    makeError("aftermath_chat_topology_mismatch", "$.chat", "자유행동 요청 뒤에 소유권을 확인할 수 없는 메시지가 있습니다."),
                }
            end
            for index = expectedLength + 1, #chat do
                if not isExactFiller(chat[index]) then
                    return nil, {
                        makeError("aftermath_chat_topology_mismatch", "$.chat", "자유행동 요청 뒤에 소유권을 확인할 수 없는 메시지가 있습니다."),
                    }
                end
            end
        end
        if requireResponse and response == nil then
            return nil, {
                makeError("aftermath_output_missing", "$.chat", "확정할 자유행동 응답이 없습니다."),
            }
        end
        return response, nil
    end

    local function validateAftermathOutput(response)
        if type(response.data) ~= "string" then
            return {
                makeError("invalid_aftermath_output", "$.chat", "자유행동 캐릭터 응답이 문자열이 아닙니다."),
            }
        end
        if string.match(response.data, "%S") == nil then
            return {
                makeError("aftermath_output_blank", "$.chat", "빈 자유행동 응답은 확정할 수 없습니다."),
            }
        end
        if string.find(response.data, "```risuerror", 1, true) ~= nil then
            return {
                makeError("aftermath_output_error", "$.chat", "LLM 오류 응답은 자유행동 장면으로 확정할 수 없습니다."),
            }
        end
        return nil
    end

    local function observeAftermathOutput(authority, aftermath, chat)
        local request = aftermath.request
        local responseLuaIndex = request.userLuaIndex + 1
        local fingerprint, fingerprintError = fingerprintAftermathResponseIdentity(
            chat[responseLuaIndex],
            "$.aftermath.request.outputObserved.response"
        )
        if fingerprintError then return { fingerprintError } end
        local observed = request.outputObserved
        if observed ~= nil then
            if observed.attemptNumber ~= (request.attemptNumber or 1)
                or observed.responseLuaIndex ~= responseLuaIndex
                or not fingerprintsEqual(observed.responseFingerprint, fingerprint) then
                return {
                    makeError("aftermath_observed_output_mismatch", "$.chat", "현재 자유행동 응답이 저장된 출력 관측 영수증과 다릅니다."),
                }
            end
            return nil
        end
        request.attemptNumber = request.attemptNumber or 1
        request.outputObserved = {
            schemaVersion = 1,
            kind = "battleAftermathOutputObserved",
            attemptNumber = request.attemptNumber,
            responseLuaIndex = responseLuaIndex,
            responseFingerprint = fingerprint,
        }
        aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
        local validationErrors = validateAftermath(aftermath, authority)
        if #validationErrors > 0 then return validationErrors end
        return writeStored(KEYS.aftermath, aftermath)
    end

    local function beginAftermathRecoveringCleanup(authority, aftermath, chat)
        local request = aftermath.request
        local responseLuaIndex = request.userLuaIndex + 1
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            responseLuaIndex,
            1,
            "$.aftermath.retry.response"
        )
        if fingerprintError then return nil, { fingerprintError } end
        request.outputObserved = nil
        request.recoveringCleanup = {
            schemaVersion = 1,
            kind = "battleAftermathRecoveringCleanup",
            attemptNumber = request.attemptNumber or 1,
            responseLuaIndex = responseLuaIndex,
            responseFingerprint = fingerprint,
        }
        aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
        local validationErrors = validateAftermath(aftermath, authority)
        if #validationErrors > 0 then return nil, validationErrors end
        local writeErrors = writeStored(KEYS.aftermath, aftermath)
        if writeErrors then return nil, writeErrors end
        return request.recoveringCleanup, nil
    end

    local function settleAftermath(authority, aftermath, staticData)
        local lastCommitted, lastErrors = readStored(KEYS.lastCommittedPending, true)
        if lastErrors then return failure(lastErrors) end
        local summary, summaryErrors = buildTerminalSummary(authority, lastCommitted, staticData)
        if summaryErrors then return failure(summaryErrors) end
        local _, battleLogErrors = publishTerminalBattleLog(authority, staticData)
        if battleLogErrors then return failure(battleLogErrors) end
        local settled, settlementErrors = callModule(
            "gameSetupController",
            "completeBattle",
            summary
        )
        if settlementErrors then return failure(settlementErrors) end
        if type(settled.view) ~= "table" or type(settled.state) ~= "table" then
            return failure({
                makeError("invalid_settlement_result", "$.runtime.gameSetupController.completeBattle", "자유행동 종료 정산이 진행 상태와 보상 View를 반환하지 않았습니다."),
            })
        end
        aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
        aftermath.phase = "complete"
        aftermath.request = nil
        local writeErrors = writeStored(KEYS.aftermath, aftermath)
        if writeErrors then return failure(writeErrors) end
        return success({
            generationReady = false,
            outputCommitted = true,
            uiTargetIndex = aftermath.lastCommitted.responseLuaIndex - 1,
            aftermathComplete = true,
            status = authority.status,
            view = settled.view,
            progressionState = settled.state,
        })
    end

    local function commitAftermathOutput(authority, aftermath, staticData)
        if aftermath.phase == "settling" then
            return settleAftermath(authority, aftermath, staticData)
        end
        if aftermath.phase ~= "requestInjected" then
            return failure({
                makeError("aftermath_request_not_injected", "$.aftermath.phase", "장면 지시가 주입되지 않은 자유행동 출력은 확정할 수 없습니다."),
            })
        end
        if aftermath.request.recoveringCleanup ~= nil then
            return failure({
                makeError("aftermath_cleanup_in_progress", "$.aftermath.request.recoveringCleanup", "미확정 자유행동 응답 삭제 복구 중에는 출력을 확정할 수 없습니다."),
            })
        end
        local chat, chatErrors = readChat()
        if chatErrors then return failure(chatErrors) end
        local response, topologyErrors = validateAftermathRequestChat(aftermath, chat, true)
        if topologyErrors then return failure(topologyErrors) end
        local outputErrors = validateAftermathOutput(response)
        if outputErrors then return failure(outputErrors) end
        local observedErrors = observeAftermathOutput(authority, aftermath, chat)
        if observedErrors then return failure(observedErrors) end

        local completedTurnNumber = aftermath.completedTurnNumber + 1
        local committedReceipt, receiptErrors = buildAftermathCommitted(
            chat,
            completedTurnNumber,
            aftermath.request.userLuaIndex + 1
        )
        if receiptErrors then return failure(receiptErrors) end
        aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
        aftermath.completedTurnNumber = completedTurnNumber
        aftermath.lastCommitted = committedReceipt
        aftermath.request = nil
        aftermath.phase = completedTurnNumber == authority.turnLimit and "settling" or "ready"
        local validationErrors = validateAftermath(aftermath, authority)
        if #validationErrors > 0 then return failure(validationErrors) end
        local writeErrors = writeStored(KEYS.aftermath, aftermath)
        if writeErrors then return failure(writeErrors) end
        if aftermath.phase == "settling" then
            return settleAftermath(authority, aftermath, staticData)
        end

        local published, publishErrors = publishCurrentViewInternal(staticData, true)
        if publishErrors then return failure(publishErrors) end
        return success({
            generationReady = false,
            outputCommitted = true,
            uiTargetIndex = aftermath.lastCommitted.responseLuaIndex - 1,
            aftermathComplete = false,
            status = authority.status,
            view = published.view,
        })
    end

    local function skipAftermath(expectedBattleId, expectedViewTurnId)
        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then return failure(authorityErrors) end
        if expectedBattleId ~= authority.battleId then
            return failure({
                makeError("stale_aftermath_skip", "$.expectedBattleId", "현재 전투와 다른 화면의 도착 건너뛰기 요청입니다."),
            })
        end

        local aftermath, aftermathReadErrors = readStored(KEYS.aftermath, false)
        if aftermathReadErrors then return failure(aftermathReadErrors) end
        if aftermath == nil then
            return failure({
                makeError("aftermath_skip_unavailable", "$.aftermath", "건너뛸 승리 후 자유행동이 없습니다."),
            })
        end
        local aftermathErrors = validateAftermath(aftermath, authority)
        if #aftermathErrors > 0 then return failure(aftermathErrors) end
        local migrated, migrationErrors = migrateLegacyAftermath(authority, aftermath)
        if migrationErrors then return failure(migrationErrors) end
        aftermath = migrated

        if aftermath.phase == "settling" then
            local settled = settleAftermath(authority, aftermath, staticData)
            if type(settled) == "table" and settled.ok == true then
                settled.skipped = true
                settled.reused = true
            end
            return settled
        end
        if aftermath.phase == "complete" then
            return success({
                generationReady = false,
                outputCommitted = true,
                uiTargetIndex = aftermath.lastCommitted.responseLuaIndex - 1,
                aftermathComplete = true,
                skipped = true,
                reused = true,
                status = authority.status,
            })
        end
        local currentViewTurnId = string.format(
            "%s-aftermath-%03d",
            authority.battleId,
            aftermath.completedTurnNumber
        )
        if expectedViewTurnId ~= currentViewTurnId then
            return failure({
                makeError("stale_aftermath_skip", "$.expectedViewTurnId", "현재 승리 후 화면과 다른 도착 건너뛰기 요청입니다."),
            })
        end
        if aftermath.phase ~= "ready" then
            return failure({
                makeError("aftermath_skip_in_flight", "$.aftermath.phase", "자유행동 장면을 생성하는 중에는 남은 턴을 건너뛸 수 없습니다."),
            })
        end

        local chat, chatErrors = readChat()
        if chatErrors then return failure(chatErrors) end
        local committedErrors = validateAftermathCommittedChat(aftermath, chat)
        if committedErrors then return failure(committedErrors) end
        local responseLuaIndex = aftermath.lastCommitted.responseLuaIndex
        if #chat ~= responseLuaIndex then
            return failure({
                makeError("aftermath_skip_chat_not_clean", "$.chat", "확정 장면 뒤에 자유행동 입력 또는 예상하지 않은 메시지가 있어 건너뛸 수 없습니다."),
            })
        end

        local previousCompletedTurnNumber = aftermath.completedTurnNumber
        local committedReceipt, receiptErrors = buildAftermathCommitted(
            chat,
            authority.turnLimit,
            responseLuaIndex
        )
        if receiptErrors then return failure(receiptErrors) end
        aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
        aftermath.completedTurnNumber = authority.turnLimit
        aftermath.lastCommitted = committedReceipt
        aftermath.request = nil
        aftermath.phase = "settling"
        local validationErrors = validateAftermath(aftermath, authority)
        if #validationErrors > 0 then return failure(validationErrors) end
        local writeErrors = writeStored(KEYS.aftermath, aftermath)
        if writeErrors then return failure(writeErrors) end

        local settled = settleAftermath(authority, aftermath, staticData)
        if type(settled) == "table" and settled.ok == true then
            settled.skipped = true
            settled.reused = false
            settled.skippedTurnCount = authority.turnLimit - previousCompletedTurnNumber
        end
        return settled
    end

    local function prepareAftermathGeneration(authority, aftermath, staticData)
        if aftermath.phase == "complete" then
            return success({
                generationReady = false,
                outputCommitted = false,
                aftermathComplete = true,
            })
        end
        if aftermath.phase == "settling" then
            local chat, chatErrors = readChat()
            if chatErrors then return failure(chatErrors) end
            local _, removedFillers, cleanupErrors = removeTrailingSayNothing(chat, 0)
            if cleanupErrors then return failure(cleanupErrors) end
            local settled = settleAftermath(authority, aftermath, staticData)
            if type(settled) == "table" and settled.ok == true then
                settled.commitRecovered = true
                settled.removedSayNothing = removedFillers > 0
                settled.removedSayNothingCount = removedFillers
            end
            return settled
        end
        if aftermath.phase == "inFlight" or aftermath.phase == "requestInjected" then
            local chat, chatErrors = readChat()
            if chatErrors then return failure(chatErrors) end
            local response, topologyErrors = validateAftermathRequestChat(aftermath, chat, false, true)
            if topologyErrors then return failure(topologyErrors) end
            local observed = aftermath.request.outputObserved
            if observed ~= nil then
                if response == nil then
                    return failure({
                        makeError("aftermath_observed_output_missing", "$.chat", "관측된 자유행동 응답이 대화에서 삭제되었습니다."),
                    })
                end
                local observedErrors = observeAftermathOutput(authority, aftermath, chat)
                if observedErrors then return failure(observedErrors) end
                local outputErrors = validateAftermathOutput(response)
                if outputErrors then
                    if not isExactFiller(chat[#chat]) then return failure(outputErrors) end
                    local _, beginErrors = beginAftermathRecoveringCleanup(
                        authority,
                        aftermath,
                        chat
                    )
                    if beginErrors then return failure(beginErrors) end
                else
                    local cleaned, removedFillers, cleanupErrors = removeTrailingSayNothing(
                        chat,
                        aftermath.request.userLuaIndex + 1
                    )
                    if cleanupErrors then return failure(cleanupErrors) end
                    chat = cleaned
                    local committed = commitAftermathOutput(authority, aftermath, staticData)
                    if type(committed) ~= "table" or committed.ok ~= true then return committed end
                    committed.commitRecovered = true
                    committed.removedSayNothing = removedFillers > 0
                    committed.removedSayNothingCount = removedFillers
                    return committed
                end
            end
            local retryCleanup = aftermath.request.recoveringCleanup
            local hasRetryFiller = isExactFiller(chat[#chat])
            if response ~= nil and not hasRetryFiller and retryCleanup == nil then
                return failure({
                    makeError("aftermath_request_already_in_flight", "$.aftermath.phase", "아직 관측되지 않은 자유행동 응답이 있어 재시도를 시작할 수 없습니다."),
                })
            end

            if retryCleanup == nil and response ~= nil then
                local beginErrors
                retryCleanup, beginErrors = beginAftermathRecoveringCleanup(
                    authority,
                    aftermath,
                    chat
                )
                if beginErrors then return failure(beginErrors) end
            elseif retryCleanup ~= nil and response ~= nil then
                local fingerprint, fingerprintError = fingerprintChatRange(
                    chat,
                    retryCleanup.responseLuaIndex,
                    1,
                    "$.aftermath.retry.currentResponse"
                )
                if fingerprintError then return failure({ fingerprintError }) end
                if not fingerprintsEqual(fingerprint, retryCleanup.responseFingerprint) then
                    return failure({
                        makeError("aftermath_recovering_cleanup_response_mismatch", "$.chat", "삭제 복구 중인 자유행동 응답이 변경되었습니다."),
                    })
                end
            end

            local cleaned, removedFillers, cleanupErrors = removeTrailingSayNothing(
                chat,
                aftermath.request.userLuaIndex
            )
            if cleanupErrors then return failure(cleanupErrors) end
            chat = cleaned
            local removedResponse = retryCleanup ~= nil
            response = chat[aftermath.request.userLuaIndex + 1]
            if retryCleanup ~= nil and response ~= nil then
                local afterRemoval, removeErrors = removeRecoveryResponse(
                    chat,
                    retryCleanup.responseLuaIndex,
                    retryCleanup.responseFingerprint
                )
                if removeErrors then return failure(removeErrors) end
                chat = afterRemoval
            end
            local _, finalTopologyErrors = validateAftermathRequestChat(aftermath, chat, false)
            if finalTopologyErrors then return failure(finalTopologyErrors) end
            aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
            aftermath.phase = "inFlight"
            aftermath.request.attemptNumber = (aftermath.request.attemptNumber or 1) + 1
            aftermath.request.outputObserved = nil
            aftermath.request.recoveringCleanup = nil
            local validationErrors = validateAftermath(aftermath, authority)
            if #validationErrors > 0 then return failure(validationErrors) end
            local writeErrors = writeStored(KEYS.aftermath, aftermath)
            if writeErrors then return failure(writeErrors) end
            return success({
                generationReady = true,
                aftermath = true,
                reused = true,
                zeroOutputRetry = not removedResponse,
                commitRecovered = false,
                turnNumber = aftermath.request.turnNumber,
                attemptNumber = aftermath.request.attemptNumber,
                removedSayNothing = removedFillers > 0,
                removedSayNothingCount = removedFillers,
                removedUncommittedOutput = removedResponse,
            })
        end

        local chat, chatErrors = readChat()
        if chatErrors then return failure(chatErrors) end
        local committedErrors = validateAftermathCommittedChat(aftermath, chat)
        if committedErrors then return failure(committedErrors) end
        local removedFillers = 0
        if isExactFiller(chat[#chat]) then
            local cleaned, cleanupCount, cleanupErrors = removeTrailingSayNothing(
                chat,
                aftermath.lastCommitted.responseLuaIndex
            )
            if cleanupErrors then return failure(cleanupErrors) end
            chat = cleaned
            removedFillers = cleanupCount
        end
        if #chat == aftermath.lastCommitted.responseLuaIndex then
            local published, publishErrors = publishCurrentViewInternal(staticData, true)
            if publishErrors then return failure(publishErrors) end
            return success({
                generationReady = false,
                outputCommitted = false,
                aftermathComplete = false,
                uiTargetRequired = true,
                uiTargetIndex = aftermath.lastCommitted.responseLuaIndex - 1,
                commitRecovered = false,
                removedSayNothing = removedFillers > 0,
                removedSayNothingCount = removedFillers,
                view = published.view,
            })
        end
        if removedFillers > 0 then
            return failure({
                makeError("aftermath_automatic_continue_rejected", "$.chat", "빈 전송이나 Continue는 자유행동으로 처리하지 않습니다."),
            })
        end
        local userLuaIndex = #chat
        local user = chat[userLuaIndex]
        if type(user) ~= "table" or user.role ~= "user" then
            return failure({
                makeError("missing_aftermath_input", "$.chat", "함락 후에는 원하는 행위를 입력한 뒤 전송해야 합니다."),
            })
        end
        if type(aftermath.lastCommitted) == "table"
            and userLuaIndex ~= aftermath.lastCommitted.responseLuaIndex + 1 then
            return failure({
                makeError("aftermath_chat_topology_mismatch", "$.chat", "확정 장면 뒤에는 하나의 새 자유행동 입력만 올 수 있습니다."),
            })
        end
        local fingerprint, fingerprintError = fingerprintChatRange(
            chat,
            userLuaIndex,
            1,
            "$.aftermath.request.user"
        )
        if fingerprintError then return failure({ fingerprintError }) end
        aftermath.schemaVersion = AFTERMATH_SCHEMA_VERSION
        aftermath.phase = "inFlight"
        aftermath.request = {
            turnNumber = aftermath.completedTurnNumber + 1,
            userLuaIndex = userLuaIndex,
            userFingerprint = fingerprint,
            attemptNumber = 1,
        }
        local validationErrors = validateAftermath(aftermath, authority)
        if #validationErrors > 0 then return failure(validationErrors) end
        local writeErrors = writeStored(KEYS.aftermath, aftermath)
        if writeErrors then return failure(writeErrors) end
        return success({
            generationReady = true,
            aftermath = true,
            reused = false,
            turnNumber = aftermath.request.turnNumber,
            attemptNumber = aftermath.request.attemptNumber,
        })
    end

    local function injectAftermathRequest(promptArray, authority, aftermath)
        if aftermath.phase ~= "inFlight" and aftermath.phase ~= "requestInjected" then
            return failure({
                makeError("aftermath_request_not_in_flight", "$.aftermath.phase", "생성 중인 자유행동 요청이 없습니다."),
            })
        end
        local promptCopy, cloneError = cloneJson(promptArray, "$.promptArray")
        if cloneError then return failure({ cloneError }) end
        if type(promptCopy) ~= "table" then
            return failure({
                makeError("invalid_prompt_array", "$.promptArray", "editRequest 값은 메시지 배열이어야 합니다."),
            })
        end
        local promptCount = 0
        for key, message in pairs(promptCopy) do
            if type(key) ~= "number" or not isInteger(key, 1) or type(message) ~= "table" then
                return failure({
                    makeError("invalid_prompt_array", "$.promptArray", "editRequest 값은 1부터 이어지는 메시지 객체 배열이어야 합니다."),
                })
            end
            promptCount = promptCount + 1
        end
        if promptCount ~= #promptCopy then
            return failure({
                makeError("invalid_prompt_array", "$.promptArray", "editRequest 메시지 배열에 빈 인덱스가 있습니다."),
            })
        end
        local chat, chatErrors = readChat()
        if chatErrors then return failure(chatErrors) end
        local response, topologyErrors = validateAftermathRequestChat(aftermath, chat, false)
        if topologyErrors then return failure(topologyErrors) end
        if response ~= nil
            or aftermath.request.outputObserved ~= nil
            or aftermath.request.recoveringCleanup ~= nil then
            return failure({
                makeError("aftermath_request_not_clean", "$.chat", "응답이 시작되거나 관측된 자유행동 요청에는 프롬프트를 다시 주입할 수 없습니다."),
            })
        end

        local instruction = buildAftermathInstruction(authority, aftermath)
        local normalized = {}
        local removed = 0
        for _, message in ipairs(promptCopy) do
            if deepEqual(message, instruction) then
                removed = removed + 1
            else
                normalized[#normalized + 1] = message
            end
        end
        normalized[#normalized + 1] = instruction
        if aftermath.phase == "inFlight" then
            aftermath.phase = "requestInjected"
            local validationErrors = validateAftermath(aftermath, authority)
            if #validationErrors > 0 then return failure(validationErrors) end
            local writeErrors = writeStored(KEYS.aftermath, aftermath)
            if writeErrors then return failure(writeErrors) end
        end
        return success({
            promptArray = normalized,
            injected = removed == 0,
            deduplicated = removed > 1,
            aftermath = true,
            finalTurn = aftermath.completedTurnNumber + 1 == authority.turnLimit,
            requestPhase = aftermath.phase,
            attemptNumber = aftermath.request.attemptNumber,
        })
    end

    local function getTerminalSummary()
        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end
        local current, currentErrors = readRuntimeBundle()
        if currentErrors then return failure(currentErrors) end
        if current.authority == nil then
            return success({
                terminal = false,
                hasBattle = false,
                settlementAvailable = false,
            })
        end
        if current.authority.status == "active" then
            return success({
                terminal = false,
                hasBattle = true,
                settlementAvailable = false,
                battleId = current.authority.battleId,
                status = current.authority.status,
            })
        end
        if current.aftermath ~= nil then
            local aftermathErrors = validateAftermath(current.aftermath, current.authority)
            if #aftermathErrors > 0 then return failure(aftermathErrors) end
            if current.aftermath.phase ~= "complete" then
                return success({
                    terminal = true,
                    hasBattle = true,
                    settlementAvailable = false,
                    battleId = current.authority.battleId,
                    status = current.authority.status,
                })
            end
        elseif current.authority.status == "victory"
            and current.authority.turnNumber < current.authority.turnLimit then
            return success({
                terminal = true,
                hasBattle = true,
                settlementAvailable = false,
                battleId = current.authority.battleId,
                status = current.authority.status,
            })
        end
        if current.lastCommittedPending == nil
            and current.draft == nil
            and current.pending == nil
            and current.activeRequest == nil
            and current.submission == nil then
            -- startFromRun은 종료 영수증을 확인한 뒤 보조 상태를 먼저
            -- 비운다. 그 직후 중단된 경우에도 다음 호출이 run의 저장된
            -- 정산 영수증으로 retirement를 재개할 수 있게 identity만
            -- 반환한다.
            return success({
                terminal = true,
                hasBattle = true,
                settlementAvailable = false,
                battleId = current.authority.battleId,
                status = current.authority.status,
            })
        end
        local summary, summaryErrors = buildTerminalSummary(
            current.authority,
            current.lastCommittedPending,
            staticData
        )
        if summaryErrors then return failure(summaryErrors) end
        return success({
            terminal = true,
            hasBattle = true,
            settlementAvailable = true,
            battleId = current.authority.battleId,
            status = current.authority.status,
            summary = summary,
        })
    end

    local function writeInitialRuntime(expected)
        for _, name in ipairs({
            "authority",
            "draft",
            "pending",
            "lastCommittedPending",
            "activeRequest",
            "submission",
            "aftermath",
        }) do
            local writeErrors = writeStored(KEYS[name], expected[name])
            if writeErrors then
                return writeErrors
            end
        end
        return nil
    end

    local function validateExistingSetupBinding(authority, spec, staticData)
        local errors = {}
        local function conflict(path, message)
            errors[#errors + 1] = makeError("battle_setup_conflict", path, message)
        end

        if type(authority.rng) ~= "table" or authority.rng.seed ~= spec.seed then
            conflict("$.state.authority.rng.seed", "기존 전투의 RNG seed가 setup 전투 사양과 다릅니다.")
        end
        if authority.environmentId ~= spec.environmentId then
            conflict("$.state.authority.environmentId", "기존 전투의 환경이 setup 전투 사양과 다릅니다.")
        end
        local journey, journeyErrors = callModule(
            "subwayJourney",
            "build",
            spec.seed,
            staticData
        )
        if journeyErrors then
            for _, item in ipairs(journeyErrors) do
                errors[#errors + 1] = item
            end
        elseif type(journey) ~= "table"
            or authority.turnLimit ~= journey.turnLimit
            or not deepEqual(authority.transit, journey.transit) then
            conflict("$.state.authority.transit", "기존 전투의 제한 턴 또는 지하철 여정이 setup seed에서 결정한 값과 다릅니다.")
        end
        if type(authority.character) ~= "table"
            or authority.character.characterId ~= spec.characterId then
            conflict("$.state.authority.character.characterId", "기존 전투의 캐릭터가 setup 선택 결과와 다릅니다.")
        end

        local initialPlayerCards = {}
        for _, instance in ipairs(type(authority.cardInstances) == "table" and authority.cardInstances or {}) do
            if type(instance) == "table" and type(instance.instanceId) == "string" then
                local rawIndex = string.match(instance.instanceId, "^player%-(%d%d%d)$")
                local index = rawIndex ~= nil and tonumber(rawIndex) or nil
                if index ~= nil and index >= 1 and index <= #spec.playerCardIds then
                    if initialPlayerCards[index] ~= nil then
                        conflict(
                            "$.state.authority.cardInstances",
                            "기존 전투에 같은 초기 플레이어 instanceId가 중복되었습니다."
                        )
                    else
                        initialPlayerCards[index] = {
                            cardId = instance.cardId,
                            owner = instance.owner,
                        }
                    end
                end
            end
        end
        for index, expectedCardId in ipairs(spec.playerCardIds) do
            local actual = initialPlayerCards[index]
            local instanceId = string.format("player-%03d", index)
            if type(actual) ~= "table"
                or actual.owner ~= "player"
                or actual.cardId ~= expectedCardId then
                conflict(
                    "$.state.authority.cardInstances[" .. string.format("%q", instanceId) .. "]",
                    "기존 전투의 초기 플레이어 덱이 setup에서 선택한 카드 순서와 다릅니다."
                )
            end
        end

        if #errors > 0 then
            return errors
        end
        return nil
    end

    local function startFromSetup(setupState)
        local staticData, staticErrors = loadStaticData()
        if staticErrors then
            return failure(staticErrors)
        end
        local canonicalSetup, spec, setupErrors = validateBattleReadySetup(setupState, staticData)
        if setupErrors then
            return failure(setupErrors)
        end

        local current, currentErrors = readRuntimeBundle()
        if currentErrors then
            return failure(currentErrors)
        end
        if current.authority ~= nil then
            if type(current.authority) ~= "table"
                or current.authority.battleId ~= spec.battleId then
                return failure({
                    makeError(
                        "battle_runtime_conflict",
                        "$.state.authority.battleId",
                        "다른 전투의 권위 상태가 있어 setup 전투로 덮어쓸 수 없습니다."
                    ),
                })
            end
            local bindingErrors = validateExistingSetupBinding(current.authority, spec, staticData)
            if bindingErrors then
                return failure(bindingErrors)
            end

            -- 정상적인 같은 전투는 첫 턴 중이라도 draft 선택, pending,
            -- generation binding이 진행됐을 수 있다. 이 상태를 다시 만들지
            -- 않고 현재 권위 경계에서 View/UI만 재게시한다.
            local looksLikeInitialPartial = current.authority.status == "active"
                and current.draft == nil
                and current.pending == nil
                and current.lastCommittedPending == nil
                and current.activeRequest == nil
                and current.submission == nil
                and current.aftermath == nil
            if not looksLikeInitialPartial then
                local published, publishErrors = publishCurrentViewInternal(staticData, true)
                if publishErrors then
                    return failure(publishErrors)
                end
                return success({
                    applied = false,
                    reused = true,
                    recovered = false,
                    battleId = current.authority.battleId,
                    turnNumber = current.authority.turnNumber,
                    setupId = canonicalSetup.setupId,
                    view = published.view,
                })
            end
        end

        -- 새 시작, 또는 authority까지만 저장된 안전한 부분 write를 같은
        -- 결정적 초기 상태와 exact 비교한 뒤에만 완성한다.
        local expected, expectedErrors = buildInitialBattleFromSetup(spec, staticData)
        if expectedErrors then
            return failure(expectedErrors)
        end
        for _, name in ipairs({
            "authority",
            "draft",
            "pending",
            "lastCommittedPending",
            "activeRequest",
            "submission",
            "aftermath",
        }) do
            local existing = current[name]
            if existing ~= nil and not deepEqual(existing, expected[name]) then
                return failure({
                    makeError(
                        "unsafe_partial_battle_runtime",
                        "$.state[" .. string.format("%q", KEYS[name]) .. "]",
                        "기존 부분 전투 상태가 setup에서 재생한 초기 상태와 일치하지 않아 복구할 수 없습니다."
                    ),
                })
            end
        end

        local recovered = current.authority ~= nil or current.draft ~= nil
        local writeErrors = writeInitialRuntime(expected)
        if writeErrors then
            return failure(writeErrors)
        end
        local published, publishErrors = publishCurrentViewInternal(staticData, true)
        if publishErrors then
            return failure(publishErrors)
        end
        return success({
            applied = true,
            reused = false,
            recovered = recovered,
            battleId = expected.authority.battleId,
            turnId = expected.turnId,
            turnNumber = expected.authority.turnNumber,
            setupId = canonicalSetup.setupId,
            view = published.view,
        })
    end

    local function validateBattleReadyRun(runState, setupState, staticData)
        local canonicalSetup, _, setupErrors = validateBattleReadySetup(
            setupState,
            staticData
        )
        if setupErrors then return nil, nil, nil, setupErrors end

        local runCopy, runCopyError = cloneJson(runState, "$.runState")
        if runCopyError then return nil, nil, nil, { runCopyError } end
        local validated, validationErrors = callModule(
            "runProgression",
            "validate",
            runCopy,
            canonicalSetup,
            staticData
        )
        if validationErrors then return nil, nil, nil, validationErrors end
        if type(validated.state) ~= "table"
            or getmetatable(validated.state) ~= nil
            or not deepEqual(runCopy, validated.state) then
            return nil, nil, nil, {
                makeError(
                    "run_validation_mismatch",
                    "$.runState",
                    "진행 상태가 runProgression.validate의 정규 상태와 정확히 일치하지 않습니다."
                ),
            }
        end
        if validated.state.phase ~= "battleReady" then
            return nil, nil, nil, {
                makeError(
                    "run_not_battle_ready",
                    "$.runState.phase",
                    "다음 상대 선택까지 끝난 battleReady 진행 상태만 전투를 시작할 수 있습니다."
                ),
            }
        end
        local battleSpec = validated.state.battleSpec
        if type(battleSpec) ~= "table" or getmetatable(battleSpec) ~= nil then
            return nil, nil, nil, {
                makeError(
                    "missing_battle_spec",
                    "$.runState.battleSpec",
                    "진행 상태에 다음 전투 사양이 없습니다."
                ),
            }
        end
        local deckCopy, deckCopyError = cloneJson(
            battleSpec.playerCardIds,
            "$.runState.battleSpec.playerCardIds"
        )
        if deckCopyError then return nil, nil, nil, { deckCopyError } end
        local normalizedRun, normalizedRunError = cloneJson(
            validated.state,
            "$.runState"
        )
        if normalizedRunError then
            return nil, nil, nil, { normalizedRunError }
        end
        return normalizedRun, canonicalSetup, {
            battleId = battleSpec.battleId,
            seed = battleSpec.seed,
            playerCardIds = deckCopy,
            characterId = battleSpec.characterId,
            environmentId = battleSpec.environmentId,
        }, nil
    end

    local function latestRunSession(runState)
        local sessions = type(runState) == "table" and runState.sessions or nil
        if type(sessions) ~= "table" then return nil end
        return sessions[#sessions]
    end

    local function summaryMatchesRunSession(summary, session)
        return type(summary) == "table"
            and type(session) == "table"
            and summary.battleId == session.battleId
            and summary.turnId == session.turnId
            and summary.characterId == session.characterId
            and summary.status == session.status
            and summary.reasonCode == session.reasonCode
            and summary.turnNumber == session.turnNumber
            and summary.turnLimit == session.turnLimit
            and summary.finalStealth == session.finalStealth
            and summary.finalResistance == session.finalResistance
            and summary.environmentId == session.environmentId
            and deepEqual(summary.transit, session.transit)
    end

    local function validateRetiredBattle(current, runState, staticData)
        local authority = current.authority
        local session = latestRunSession(runState)
        if type(authority) ~= "table"
            or (authority.status ~= "victory" and authority.status ~= "defeat")
            or type(authority.character) ~= "table"
            or type(authority.player) ~= "table"
            or type(session) ~= "table"
            or authority.battleId ~= session.battleId
            or authority.lastCommittedTurnId ~= session.turnId
            or authority.character.characterId ~= session.characterId
            or authority.status ~= session.status
            or authority.turnNumber ~= session.turnNumber
            or authority.turnLimit ~= session.turnLimit
            or authority.player.stealth ~= session.finalStealth
            or authority.character.resistance ~= session.finalResistance
            or authority.environmentId ~= session.environmentId
            or not deepEqual(authority.transit, session.transit) then
            return {
                makeError(
                    "unsettled_battle_runtime",
                    "$.state.authority",
                    "기존 종료 전투가 저장된 진행 정산 영수증과 일치하지 않습니다."
                ),
            }
        end
        if current.aftermath ~= nil then
            local aftermathErrors = validateAftermath(current.aftermath, authority)
            if #aftermathErrors > 0 then return aftermathErrors end
            if current.aftermath.phase ~= "complete" then
                return {
                    makeError(
                        "aftermath_not_complete",
                        "$.state.aftermath",
                        "승리 후 자유행동이 끝나기 전에는 전투를 퇴역시킬 수 없습니다."
                    ),
                }
            end
        end

        if current.lastCommittedPending ~= nil then
            local summary, summaryErrors = buildTerminalSummary(
                authority,
                current.lastCommittedPending,
                staticData
            )
            if summaryErrors then return summaryErrors end
            if not summaryMatchesRunSession(summary, session) then
                return {
                    makeError(
                        "settlement_receipt_mismatch",
                        "$.runState.sessions",
                        "종료 턴 공개 영수증과 진행 정산 기록이 일치하지 않습니다."
                    ),
                }
            end
        elseif current.draft ~= nil
            or current.pending ~= nil
            or current.activeRequest ~= nil
            or current.submission ~= nil
            or current.aftermath ~= nil then
            return {
                makeError(
                    "unsafe_retirement_partial",
                    "$.state",
                    "종료 영수증이 사라진 부분 정리 상태에 다른 전투 보조 상태가 남아 있습니다."
                ),
            }
        end
        return nil
    end

    local function clearRetiredRuntimeAuxiliary()
        for _, name in ipairs({
            "draft",
            "pending",
            "activeRequest",
            "submission",
            "aftermath",
            "lastCommittedPending",
        }) do
            local writeErrors = writeStored(KEYS[name], nil)
            if writeErrors then return writeErrors end
        end
        return nil
    end

    local function startFromRun(runState, setupState)
        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end
        local canonicalRun, canonicalSetup, spec, runErrors =
            validateBattleReadyRun(runState, setupState, staticData)
        if runErrors then return failure(runErrors) end

        local current, currentErrors = readRuntimeBundle()
        if currentErrors then return failure(currentErrors) end
        local retired = false
        if current.authority ~= nil and current.authority.battleId ~= spec.battleId then
            local retirementErrors = validateRetiredBattle(
                current,
                canonicalRun,
                staticData
            )
            if retirementErrors then return failure(retirementErrors) end
            local clearErrors = clearRetiredRuntimeAuxiliary()
            if clearErrors then return failure(clearErrors) end
            current.draft = nil
            current.pending = nil
            current.activeRequest = nil
            current.submission = nil
            current.lastCommittedPending = nil
            current.aftermath = nil
            retired = true
        end

        local expected, expectedErrors = buildInitialBattleFromSetup(spec, staticData)
        if expectedErrors then return failure(expectedErrors) end

        if current.authority ~= nil and current.authority.battleId == spec.battleId then
            local bindingErrors = validateExistingSetupBinding(
                current.authority,
                spec,
                staticData
            )
            if bindingErrors then return failure(bindingErrors) end
            if current.authority.status ~= "active" then
                return failure({
                    makeError(
                        "battle_already_terminal",
                        "$.state.authority.status",
                        "종료된 현재 전투를 먼저 정산해야 다음 상태를 게시할 수 있습니다."
                    ),
                })
            end
            local looksLikeInitialPartial = deepEqual(
                current.authority,
                expected.authority
            )
                and current.draft == nil
                and current.pending == nil
                and current.lastCommittedPending == nil
                and current.activeRequest == nil
                and current.submission == nil
                and current.aftermath == nil
            if not looksLikeInitialPartial then
                local published, publishErrors = publishCurrentViewInternal(
                    staticData,
                    true
                )
                if publishErrors then return failure(publishErrors) end
                return success({
                    applied = false,
                    reused = true,
                    recovered = false,
                    battleId = current.authority.battleId,
                    turnNumber = current.authority.turnNumber,
                    setupId = canonicalSetup.setupId,
                    view = published.view,
                })
            end
        end

        for _, name in ipairs({
            "authority",
            "draft",
            "pending",
            "lastCommittedPending",
            "activeRequest",
            "submission",
            "aftermath",
        }) do
            local existing = current[name]
            if name == "authority"
                and retired
                and type(existing) == "table"
                and existing.battleId ~= spec.battleId then
                existing = nil
            end
            if existing ~= nil and not deepEqual(existing, expected[name]) then
                return failure({
                    makeError(
                        "unsafe_partial_battle_runtime",
                        "$.state[" .. string.format("%q", KEYS[name]) .. "]",
                        "기존 부분 전투 상태가 다음 전투 사양에서 재생한 초기 상태와 일치하지 않습니다."
                    ),
                })
            end
        end

        local recovered = retired
            or current.authority ~= nil
            or current.draft ~= nil
            or current.pending ~= nil
            or current.lastCommittedPending ~= nil
            or current.activeRequest ~= nil
            or current.submission ~= nil
            or current.aftermath ~= nil
        local writeErrors = writeInitialRuntime(expected)
        if writeErrors then return failure(writeErrors) end
        local published, publishErrors = publishCurrentViewInternal(
            staticData,
            true
        )
        if publishErrors then return failure(publishErrors) end
        return success({
            applied = true,
            reused = false,
            recovered = recovered,
            battleId = expected.authority.battleId,
            turnId = expected.turnId,
            turnNumber = expected.authority.turnNumber,
            setupId = canonicalSetup.setupId,
            view = published.view,
        })
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
            { KEYS.submission, nil },
            { KEYS.aftermath, nil },
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

    local function interactCard(interactionAction, instanceId, expectedInteractionToken, choiceId)
        if interactionAction ~= "click"
            and interactionAction ~= "register"
            and interactionAction ~= "cancel"
            and interactionAction ~= "choose" then
            return failure({
                makeError(
                    "invalid_interaction_action",
                    "$.interactionAction",
                    "카드 상호작용 작업은 click, register, cancel, choose 중 하나여야 합니다."
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
        if interactionAction == "choose"
            and (type(choiceId) ~= "string" or string.match(choiceId, "^[a-z][a-z0-9_]*$") == nil) then
            return failure({ makeError("invalid_effect_choice_id", "$.choiceId", "효과 선택지 ID가 올바르지 않습니다.") })
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
                choiceId = choiceId,
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
            local published, publishErrors = publishCurrentViewInternal(staticData, true, false, true)
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
            local submissionWriteErrors = writeStored(
                KEYS.submission,
                interacted.interactionToken
            )
            if submissionWriteErrors then return failure(submissionWriteErrors) end
        end
        local published, publishErrors = publishCurrentViewInternal(staticData, true, false, true)
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

    local function selectCardEffect(instanceId, choiceId, expectedInteractionToken)
        return interactCard("choose", instanceId, expectedInteractionToken, choiceId)
    end

    local function armSubmission(expectedInteractionToken)
        if type(expectedInteractionToken) ~= "string" or expectedInteractionToken == "" then
            return failure({
                makeError("invalid_interaction_token", "$.expectedInteractionToken", "비어 있지 않은 draft interaction token이 필요합니다."),
            })
        end
        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then return failure(authorityErrors) end
        local pending, pendingErrors = readStored(KEYS.pending, false)
        if pendingErrors then return failure(pendingErrors) end
        if pending ~= nil then
            return failure({
                makeError("battle_view_locked", "$.pendingTurn", "출력 대기 중에는 턴 제출을 다시 준비할 수 없습니다."),
            })
        end
        local activeRequest, requestErrors = readStored(KEYS.activeRequest, false)
        if requestErrors then return failure(requestErrors) end
        if type(activeRequest) == "table" then
            local activeErrors = validateBinding(activeRequest, nil)
            if #activeErrors > 0 then return failure(activeErrors) end
            if activeRequest.phase ~= "committed" then
                return failure({
                    makeError("battle_view_locked", "$.activeRequest.phase", "생성 요청 처리 중에는 턴 제출을 다시 준비할 수 없습니다."),
                })
            end
        end
        local draft, draftErrors = readStored(KEYS.draft, true)
        if draftErrors then return failure(draftErrors) end
        local interactionToken, tokenErrors = inspectDraftInteractionToken(
            authority,
            staticData,
            draft
        )
        if tokenErrors then return failure(tokenErrors) end
        if interactionToken ~= expectedInteractionToken then
            local published, publishErrors = publishCurrentViewInternal(
                staticData,
                true,
                false,
                true
            )
            if publishErrors then return failure(publishErrors) end
            return success({
                applied = false,
                stale = true,
                interactionToken = interactionToken,
                view = published.view,
            })
        end
        local writeErrors = writeStored(KEYS.submission, interactionToken)
        if writeErrors then return failure(writeErrors) end
        local published, publishErrors = publishCurrentViewInternal(
            staticData,
            true,
            false,
            true
        )
        if publishErrors then return failure(publishErrors) end
        return success({
            applied = true,
            stale = false,
            interactionToken = interactionToken,
            view = published.view,
        })
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
                makeError("zero_output_retry_topology_mismatch", "$.chat", "무출력 재시도에는 요청 응답 위치가 완전히 비어 있어야 합니다."),
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

    local function retryCommittedOutput(binding, chat, staticData)
        local repairedChat, repairedTail, repairErrors = restoreRepairableAnchorTail(
            binding,
            chat
        )
        if repairErrors then return failure(repairErrors) end
        local topology, topologyErrors = inspectAnchoredTopology(
            binding,
            repairedChat,
            false
        )
        if topologyErrors then return failure(topologyErrors) end
        if topology.responsePresent or topology.fillerCount ~= 0 then
            return failure({
                makeError("committed_reroll_topology_mismatch", "$.chat", "확정 응답 리롤 뒤 응답 위치가 비어 있지 않습니다."),
            })
        end
        local pending, _, boundErrors = loadAndValidateBoundRequest(binding, staticData)
        if boundErrors then return failure(boundErrors) end
        local nextBinding, cloneError = cloneJson(binding, "$.activeRequest")
        if cloneError then return failure({ cloneError }) end
        nextBinding.phase = "inFlight"
        nextBinding.attemptNumber = nextBinding.attemptNumber + 1
        nextBinding.outputObserved = nil
        nextBinding.recoveringCleanup = nil
        local validationErrors = validateBinding(nextBinding, pending)
        if #validationErrors > 0 then return failure(validationErrors) end
        local submissionClearErrors = clearSubmission()
        if submissionClearErrors then return failure(submissionClearErrors) end
        local writeErrors = writeStored(KEYS.activeRequest, nextBinding)
        if writeErrors then return failure(writeErrors) end
        local published, publishErrors = publishCurrentViewInternal(staticData)
        if publishErrors then return failure(publishErrors) end
        return success({
            generationReady = true,
            rerolledCommittedOutput = true,
            repairedStoryTail = repairedTail,
            recoveredAbandonedRequest = false,
            zeroOutputRetry = false,
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

    local function prepareGeneration()
        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then return failure(authorityErrors) end
        local aftermath, aftermathReadErrors = readStored(KEYS.aftermath, false)
        if aftermathReadErrors then return failure(aftermathReadErrors) end
        if aftermath ~= nil then
            local aftermathErrors = validateAftermath(aftermath, authority)
            if #aftermathErrors > 0 then return failure(aftermathErrors) end
            local migrated, migrationErrors = migrateLegacyAftermath(authority, aftermath)
            if migrationErrors then return failure(migrationErrors) end
            aftermath = migrated
            return prepareAftermathGeneration(authority, aftermath, staticData)
        end
        local chat, chatErrors = readChat()
        if chatErrors then return failure(chatErrors) end
        local removedCount
        chat, removedCount, chatErrors = removeTrailingSayNothing(chat)
        if chatErrors then return failure(chatErrors) end

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
                    chat, removedCount, chatErrors = removeTrailingSayNothing(chat)
                    if chatErrors then return failure(chatErrors) end
                    storedBinding, storedBindingErrors = readStored(KEYS.activeRequest, true)
                    if storedBindingErrors then return failure(storedBindingErrors) end
                end
            end

            if storedBinding.phase == "committed" then
                local committedChat, repairedTail, repairErrors = restoreRepairableAnchorTail(
                    storedBinding,
                    chat
                )
                if repairErrors then return failure(repairErrors) end
                chat = committedChat
                local committedTopology, committedTopologyErrors = inspectAnchoredTopology(
                    storedBinding,
                    chat,
                    false
                )
                if committedTopologyErrors then return failure(committedTopologyErrors) end
                if not committedTopology.responsePresent then
                    local retried = retryCommittedOutput(
                        storedBinding,
                        chat,
                        staticData
                    )
                    if type(retried) == "table" and retried.ok == true and repairedTail then
                        retried.repairedStoryTail = true
                    end
                    return retried
                end
            end

            if storedBinding.phase == "inFlight" or storedBinding.phase == "requestInjected" then
                if storedBinding.recoveringCleanup == nil then
                    local topology, topologyErrors = inspectAnchoredTopology(storedBinding, chat, false)
                    if topologyErrors then return failure(topologyErrors) end
                    if storedBinding.outputObserved == nil
                        and not topology.responsePresent
                        and topology.fillerCount == 0 then
                        return retryWithoutOutput(storedBinding, chat, staticData, authority)
                    end
                    if storedBinding.outputObserved ~= nil
                        and topology.responsePresent
                        and topology.fillerCount == 0 then
                        local committed = commitOutput()
                        if type(committed) ~= "table" or committed.ok ~= true then return committed end
                        committed.generationReady = false
                        committed.commitRecovered = true
                        committed.zeroOutputRetry = false
                        committed.removedSayNothing = false
                        committed.removedSayNothingCount = 0
                        committed.removedUncommittedOutput = false
                        return committed
                    end
                    if topology.fillerCount == 0 then
                        return failure({
                            makeError(
                                "request_already_in_flight",
                                "$.activeRequest.phase",
                                "이미 생성 중이거나 프롬프트 주입을 마친 요청이 있습니다. 응답을 리롤한 뒤 다시 시도하세요."
                            ),
                        })
                    end
                end
                return recoverLockedRequest(storedBinding, chat, staticData, authority)
            end
        end

        local selectedPending
        local sourceName
        local reused = false
        local recoveryBinding
        local pending, pendingErrors = readStored(KEYS.pending, false)
        if pendingErrors then return failure(pendingErrors) end
        if type(storedBinding) == "table" and storedBinding.phase == "preparing" then
            local boundPending, boundPendingErrors = loadBoundPending(storedBinding)
            if boundPendingErrors then
                return failure(boundPendingErrors)
            end
            selectedPending = boundPending
            sourceName = storedBinding.source
            recoveryBinding = storedBinding
            reused = true
        elseif pending ~= nil then
            local reuse, reuseErrors = callModule(
                "battleRuntime",
                "reusePending",
                authority,
                staticData,
                pending
            )
            if reuseErrors then return failure(reuseErrors) end
            selectedPending = reuse.pendingTurn
            sourceName = "pending"
            reused = true
        else
            local draft, draftErrors = readStored(KEYS.draft, true)
            if draftErrors then return failure(draftErrors) end
            local submission, submissionErrors = readArmedSubmission(
                authority,
                staticData,
                draft
            )
            if submissionErrors then return failure(submissionErrors) end
            if submission ~= nil then
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
                sourceName = "pending"
            end
        end

        if selectedPending == nil then
            if type(storedBinding) == "table" and storedBinding.phase == "committed" then
                local published, publishErrors = publishCurrentViewInternal(staticData, true)
                if publishErrors then return failure(publishErrors) end
                return success({
                    generationReady = false,
                    idle = true,
                    uiTargetRequired = true,
                    uiTargetIndex = storedBinding.chatAnchor.responseIndex,
                    outputCommitted = false,
                    commitRecovered = false,
                    turnId = storedBinding.turnId,
                    turnNumber = storedBinding.turnNumber,
                    source = storedBinding.source,
                    publicMarker = storedBinding.publicMarker,
                    attemptNumber = storedBinding.attemptNumber,
                    reused = true,
                    removedSayNothing = removedCount > 0,
                    removedSayNothingCount = removedCount,
                    removedUncommittedOutput = false,
                    markerAdded = false,
                    view = published.view,
                })
            end
            return success({
                generationReady = false,
                idle = true,
                removedSayNothing = removedCount > 0,
                removedSayNothingCount = removedCount,
            })
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
            local chatAnchor, anchorErrors = createPlannedChatAnchor(chat)
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
        local submissionClearErrors = clearSubmission()
        if submissionClearErrors then return failure(submissionClearErrors) end

        -- 생성 중에는 잠긴 canonical View만 영속한다. 전체 HTML/CBS 렌더는
        -- 응답 commit 뒤 게시하므로 HTTP 요청 전 중복 평가하지 않는다.
        local published, publishErrors = publishCurrentViewInternal(staticData, true, true)
        if publishErrors then
            return failure(publishErrors)
        end

        local finalTopology, finalTopologyErrors = inspectAnchoredTopology(binding, chat, false)
        if finalTopologyErrors then return failure(finalTopologyErrors) end
        if finalTopology.responsePresent or finalTopology.fillerCount ~= 0 then
            return failure({
                makeError("prepared_chat_topology_mismatch", "$.chat", "요청 준비 뒤 응답 위치에 예상하지 않은 메시지가 남아 있습니다."),
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
            markerAdded = false,
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
        local authority, authorityErrors = readStored(KEYS.authority, true)
        if authorityErrors then return failure(authorityErrors) end
        local aftermath, aftermathReadErrors = readStored(KEYS.aftermath, false)
        if aftermathReadErrors then return failure(aftermathReadErrors) end
        if aftermath ~= nil then
            local aftermathErrors = validateAftermath(aftermath, authority)
            if #aftermathErrors > 0 then return failure(aftermathErrors) end
            local migrated, migrationErrors = migrateLegacyAftermath(authority, aftermath)
            if migrationErrors then return failure(migrationErrors) end
            aftermath = migrated
            return injectAftermathRequest(promptArray, authority, aftermath)
        end
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

        local requestCue = {
            role = "user",
            content = formatted.publicMarker,
        }
        local systemCount = 0
        local cueCount = 0
        local normalizedPrompt = {}
        for _, message in ipairs(promptCopy) do
            if deepEqual(message, formatted.message) then
                systemCount = systemCount + 1
            elseif deepEqual(message, requestCue) then
                cueCount = cueCount + 1
            elseif message.role == "user" and message.content == TURN_SUBMIT_MARKER then
                -- 이전 배포가 남긴 표시 전용 marker는 모델 요청에 포함하지 않는다.
            else
                normalizedPrompt[#normalizedPrompt + 1] = message
            end
        end
        local alreadyInjected = systemCount >= 1 and cueCount >= 1
        local deduplicated = systemCount > 1 or cueCount > 1
        promptCopy = normalizedPrompt
        local messageCopy, messageCloneError = cloneJson(formatted.message, "$.activeRequest.message")
        if messageCloneError then
            return failure({ messageCloneError })
        end
        local cueCopy, cueCloneError = cloneJson(requestCue, "$.activeRequest.publicMarker")
        if cueCloneError then
            return failure({ cueCloneError })
        end
        -- 확정 사건을 먼저 제공하고 장면 묘사 지시를 마지막 user 메시지로 둔다.
        -- 두 메시지는 editRequest 결과에만 존재하며 실제 채팅에는 저장하지 않는다.
        promptCopy[#promptCopy + 1] = messageCopy
        promptCopy[#promptCopy + 1] = cueCopy

        -- This durable phase is the authority boundary between editRequest and
        -- onOutput. Without it, a host-side editRequest failure could still run
        -- onOutput and commit a turn whose event/cue never reached the model.
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
        local aftermath, aftermathReadErrors = readStored(KEYS.aftermath, false)
        if aftermathReadErrors then return failure(aftermathReadErrors) end
        if aftermath ~= nil then
            local aftermathErrors = validateAftermath(aftermath, authority)
            if #aftermathErrors > 0 then return failure(aftermathErrors) end
            local migrated, migrationErrors = migrateLegacyAftermath(authority, aftermath)
            if migrationErrors then return failure(migrationErrors) end
            aftermath = migrated
            if aftermath.phase == "ready" then
                local published, publishErrors = publishCurrentViewInternal(staticData, true)
                if publishErrors then return failure(publishErrors) end
                return success({
                    generationReady = false,
                    outputCommitted = true,
                    uiTargetIndex = aftermath.lastCommitted.responseLuaIndex - 1,
                    aftermathComplete = false,
                    status = authority.status,
                    view = published.view,
                })
            elseif aftermath.phase == "complete" then
                return success({
                    generationReady = false,
                    outputCommitted = true,
                    uiTargetIndex = aftermath.lastCommitted.responseLuaIndex - 1,
                    aftermathComplete = true,
                    status = authority.status,
                })
            end
            return commitAftermathOutput(authority, aftermath, staticData)
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

        -- 활성 전투는 다음 턴 View를, 종료 전투는 멱등 정산 뒤 결과/보상 View를
        -- 게시한다. onOutput 훅이 완성 응답을 새 UI target으로 지정한다.
        local published
        local progressionState
        if nextState.status == "active" then
            local publishErrors
            published, publishErrors = publishCurrentViewInternal(staticData, true)
            if publishErrors then return failure(publishErrors) end
        elseif nextState.status == "victory" and nextState.turnNumber < nextState.turnLimit then
            local currentAftermath, aftermathErrors = readStored(KEYS.aftermath, false)
            if aftermathErrors then return failure(aftermathErrors) end
            if currentAftermath == nil then
                local aftermathChat, chatErrors = readChat()
                if chatErrors then return failure(chatErrors) end
                local committedReceipt, receiptErrors = buildAftermathCommitted(
                    aftermathChat,
                    nextState.turnNumber,
                    #aftermathChat
                )
                if receiptErrors then return failure(receiptErrors) end
                currentAftermath = {
                    schemaVersion = AFTERMATH_SCHEMA_VERSION,
                    kind = "battleAftermath",
                    battleId = nextState.battleId,
                    victoryTurnNumber = nextState.turnNumber,
                    completedTurnNumber = nextState.turnNumber,
                    phase = "ready",
                    lastCommitted = committedReceipt,
                }
                local validationErrors = validateAftermath(currentAftermath, nextState)
                if #validationErrors > 0 then return failure(validationErrors) end
                local writeErrors = writeStored(KEYS.aftermath, currentAftermath)
                if writeErrors then return failure(writeErrors) end
            else
                local validationErrors = validateAftermath(currentAftermath, nextState)
                if #validationErrors > 0 then return failure(validationErrors) end
            end
            local publishErrors
            published, publishErrors = publishCurrentViewInternal(staticData, true)
            if publishErrors then return failure(publishErrors) end
        else
            local summary, summaryErrors = buildTerminalSummary(
                nextState,
                selectedPending,
                staticData
            )
            if summaryErrors then return failure(summaryErrors) end
            local _, battleLogErrors = publishTerminalBattleLog(nextState, staticData)
            if battleLogErrors then return failure(battleLogErrors) end
            local settled, settlementErrors = callModule(
                "gameSetupController",
                "completeBattle",
                summary
            )
            if settlementErrors then return failure(settlementErrors) end
            if type(settled.view) ~= "table" or type(settled.state) ~= "table" then
                return failure({
                    makeError(
                        "invalid_settlement_result",
                        "$.runtime.gameSetupController.completeBattle",
                        "전투 정산이 진행 상태와 결과 View를 반환하지 않았습니다."
                    ),
                })
            end
            published = { view = settled.view }
            progressionState = settled.state
        end
        return success({
            generationReady = false,
            outputCommitted = true,
            uiTargetIndex = committedBinding.chatAnchor.responseIndex,
            turnId = committed.turnId,
            applied = committed.applied == true,
            initializedNextTurn = initialized,
            status = nextState.status,
            turnNumber = nextState.turnNumber,
            publicResult = selectedPending.turnResult.publicResult,
            view = published.view,
            progressionState = progressionState,
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
                submission = KEYS.submission,
                aftermath = KEYS.aftermath,
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
        local submission, submissionErrors = readStored(KEYS.submission, false)
        if submissionErrors then return failure(submissionErrors) end
        local aftermath, aftermathErrors = readStored(KEYS.aftermath, false)
        if aftermathErrors then return failure(aftermathErrors) end

        snapshot.hasBattle = authority ~= nil
        snapshot.authorityState = authority
        snapshot.draft = draft
        snapshot.pendingTurn = pending
        snapshot.lastCommittedPending = lastCommitted
        snapshot.activeRequest = activeRequest
        snapshot.submission = submission
        snapshot.aftermath = aftermath
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
    elseif action == "startFromSetup" then
        return startFromSetup(arguments[1])
    elseif action == "startFromRun" then
        return startFromRun(arguments[1], arguments[2])
    elseif action == "clickCard" then
        return clickCard(arguments[1], arguments[2])
    elseif action == "registerCard" then
        return registerCard(arguments[1], arguments[2])
    elseif action == "cancelCard" then
        return cancelCard(arguments[1], arguments[2])
    elseif action == "selectCardEffect" then
        return selectCardEffect(arguments[1], arguments[2], arguments[3])
    elseif action == "armSubmission" then
        return armSubmission(arguments[1])
    elseif action == "prepareGeneration" then
        return prepareGeneration()
    elseif action == "injectRequest" then
        return injectRequest(arguments[1])
    elseif action == "commitOutput" then
        return commitOutput()
    elseif action == "skipAftermath" then
        return skipAftermath(arguments[1], arguments[2])
    elseif action == "publishCurrentView" then
        return publishCurrentView()
    elseif action == "getSnapshot" then
        return getSnapshot()
    elseif action == "getTerminalSummary" then
        return getTerminalSummary()
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 battleController 작업입니다: " .. tostring(action)),
    })
end)
