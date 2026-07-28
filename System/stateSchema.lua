(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991
    local MAX_PLAN_CAPACITY = 16
    local FINGERPRINT_ALGORITHM = "canonical_poly131_137_receipt_v2"
    local DRAFT_FINGERPRINT_ALGORITHM = "canonical_poly131_137_v1"
    local PENDING_INTEGRITY_ALGORITHM = "canonical_poly131_137_pending_v1"

    local VALID_STATUS = {
        active = true,
        victory = true,
        defeat = true,
    }

    local VALID_OWNER = {
        player = true,
        character = true,
    }

    local VALID_ZONE = {
        deck = true,
        hand = true,
        used = true,
        discard = true,
        removed = true,
        plan = true,
    }

    local function addError(errors, code, path, message)
        table.insert(errors, {
            code = code,
            path = path,
            message = message,
        })
    end

    local function result(errors, value)
        return {
            ok = #errors == 0,
            schemaVersion = SCHEMA_VERSION,
            errors = errors,
            value = #errors == 0 and value or nil,
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
        return isInteger(value, minimum)
            and math.abs(value) <= MAX_SAFE_INTEGER
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
    end

    local function objectPath(path, key)
        if type(key) == "string" and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", tostring(key)) .. "]"
    end

    local function inspectTable(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "expected_table", path, "테이블이어야 합니다.")
            return nil
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
                    addError(errors, "invalid_array_index", path, "배열 인덱스는 1 이상의 정수여야 합니다.")
                    return nil
                end
                if key > maximum then
                    maximum = key
                end
            elseif type(key) == "string" then
                hasString = true
                table.insert(stringKeys, key)
            else
                addError(errors, "invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
                return nil
            end
        end

        if hasNumeric and hasString then
            addError(errors, "mixed_table", path, "숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
            return nil
        end

        if hasNumeric then
            if numericCount ~= maximum then
                addError(errors, "sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
                return nil
            end
            return "array", maximum
        end

        if hasString then
            table.sort(stringKeys)
            return "object", stringKeys
        end

        return "array", 0
    end

    local function validateJsonSafe(value, path, errors, active)
        local valueType = type(value)
        if valueType == "string" or valueType == "boolean" then
            return
        end
        if valueType == "number" then
            if not isFinite(value) then
                addError(errors, "non_finite_number", path, "NaN과 무한대는 저장할 수 없습니다.")
            end
            return
        end
        if valueType ~= "table" then
            addError(errors, "unsupported_type", path, "JSON 상태에 저장할 수 없는 자료형입니다: " .. valueType)
            return
        end
        if getmetatable(value) ~= nil then
            addError(errors, "metatable_not_allowed", path, "상태 테이블에는 메타테이블을 사용할 수 없습니다.")
            return
        end

        active = active or {}
        if active[value] then
            addError(errors, "circular_reference", path, "순환 참조가 있는 테이블은 저장할 수 없습니다.")
            return
        end

        active[value] = true
        local kind, shape = inspectTable(value, path, errors)
        if kind == "array" then
            for index = 1, shape do
                validateJsonSafe(value[index], path .. "[" .. index .. "]", errors, active)
            end
        elseif kind == "object" then
            for _, key in ipairs(shape) do
                validateJsonSafe(value[key], objectPath(path, key), errors, active)
            end
        end
        active[value] = nil
    end

    local function checkAllowedKeys(value, allowed, path, errors)
        if type(value) ~= "table" then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                addError(errors, "unknown_field", objectPath(path, key), "허용되지 않은 필드입니다.")
            end
        end
    end

    local function getArrayLength(value, path, errors)
        local kind, length = inspectTable(value, path, errors)
        if kind ~= "array" then
            if kind ~= nil then
                addError(errors, "expected_array", path, "연속 배열이어야 합니다.")
            end
            return nil
        end
        return length
    end

    local function validateIdArray(value, path, errors, idValidator)
        local length = getArrayLength(value, path, errors)
        if length == nil then
            return
        end

        local seen = {}
        for index = 1, length do
            local item = value[index]
            if not idValidator(item) then
                addError(errors, "invalid_id", path .. "[" .. index .. "]", "올바른 ID 문자열이 아닙니다.")
            else
                if seen[item] then
                    addError(errors, "duplicate_id", path .. "[" .. index .. "]", "같은 ID가 중복되었습니다: " .. item)
                end
                seen[item] = true
            end
        end
    end

    local function normalizeStaticData(staticData)
        if type(staticData) ~= "table" or getmetatable(staticData) ~= nil then
            return staticData
        end
        local data = rawget(staticData, "data")
        if type(data) == "table" and getmetatable(data) == nil then
            return data
        end
        return staticData
    end

    local function isPlainTableTree(value, active, seen)
        if type(value) ~= "table" then
            return true
        end
        if getmetatable(value) ~= nil then
            return false
        end

        active = active or {}
        seen = seen or {}
        if active[value] then
            return false
        end
        if seen[value] then
            return true
        end

        active[value] = true
        for key, item in pairs(value) do
            if not isPlainTableTree(key, active, seen)
                or not isPlainTableTree(item, active, seen) then
                active[value] = nil
                return false
            end
        end
        active[value] = nil
        seen[value] = true
        return true
    end

    local function fingerprintFailure(code, path, message)
        error({
            code = code,
            path = path,
            message = message,
        }, 0)
    end

    local function inspectCanonicalTable(value, path)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            fingerprintFailure("invalid_table", path, "fingerprint 대상은 일반 테이블이어야 합니다.")
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
                    fingerprintFailure("invalid_array_index", path, "배열 인덱스는 1 이상의 정수여야 합니다.")
                end
                if key > maximum then
                    maximum = key
                end
            elseif type(key) == "string" then
                hasString = true
                table.insert(stringKeys, key)
            else
                fingerprintFailure("invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
            end
        end
        if hasNumeric and hasString then
            fingerprintFailure("mixed_table", path, "숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
        end
        if hasNumeric and numericCount ~= maximum then
            fingerprintFailure("sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
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
                fingerprintFailure("non_finite_number", path, "NaN과 무한대는 fingerprint에 사용할 수 없습니다.")
            end
            return "d" .. string.format("%.17g", value) .. ";"
        end
        if valueType == "string" then
            return "s" .. tostring(#value) .. ":" .. value
        end
        if valueType ~= "table" then
            fingerprintFailure("unsupported_type", path, "fingerprint에 사용할 수 없는 자료형입니다: " .. valueType)
        end

        active = active or {}
        if active[value] then
            fingerprintFailure("circular_reference", path, "순환 참조가 있는 값은 fingerprint에 사용할 수 없습니다.")
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

    local function fingerprintAuthorityState(state)
        local authorityState = {}
        for key, value in pairs(state) do
            if key == "turnStartReceipt" and type(value) == "table" then
                local receipt = {}
                for receiptKey, receiptValue in pairs(value) do
                    if receiptKey ~= "authorityFingerprint" then
                        receipt[receiptKey] = receiptValue
                    end
                end
                authorityState[key] = receipt
            else
                authorityState[key] = value
            end
        end

        local ok, canonical = pcall(canonicalJson, authorityState, "$", {})
        if not ok then
            if type(canonical) == "table" and canonical.code and canonical.path and canonical.message then
                return nil, canonical
            end
            return nil, {
                code = "fingerprint_failed",
                path = "$",
                message = "전투 상태 fingerprint 생성에 실패했습니다: " .. tostring(canonical),
            }
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

    local function fingerprintDraftAuthorityState(state)
        local ok, canonical = pcall(canonicalJson, state, "$", {})
        if not ok then
            if type(canonical) == "table" and canonical.code and canonical.path and canonical.message then
                return nil, canonical
            end
            return nil, {
                code = "fingerprint_failed",
                path = "$",
                message = "드래프트 권위 상태 fingerprint 생성에 실패했습니다: " .. tostring(canonical),
            }
        end

        local hashA = 0
        local hashB = 0
        for index = 1, #canonical do
            local byte = string.byte(canonical, index)
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        return {
            algorithm = DRAFT_FINGERPRINT_ALGORITHM,
            length = #canonical,
            hashA = hashA,
            hashB = hashB,
        }, nil
    end

    local function fingerprintPendingTurn(pending)
        local payload = {}
        for key, value in pairs(pending) do
            if key ~= "integrity" then
                payload[key] = value
            end
        end
        local ok, canonical = pcall(canonicalJson, payload, "$", {})
        if not ok then
            if type(canonical) == "table" and canonical.code and canonical.path and canonical.message then
                return nil, canonical
            end
            return nil, {
                code = "fingerprint_failed",
                path = "$.integrity",
                message = "pendingTurn 무결성 fingerprint 생성에 실패했습니다: " .. tostring(canonical),
            }
        end

        local hashA = 0
        local hashB = 0
        for index = 1, #canonical do
            local byte = string.byte(canonical, index)
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        return {
            algorithm = PENDING_INTEGRITY_ALGORITHM,
            length = #canonical,
            hashA = hashA,
            hashB = hashB,
        }, nil
    end

    local function hasCompleteStaticData(staticData)
        return type(staticData) == "table"
            and getmetatable(staticData) == nil
            and type(rawget(staticData, "registry")) == "table"
            and type(rawget(staticData, "cards")) == "table"
            and type(rawget(staticData, "traits")) == "table"
            and type(rawget(staticData, "environments")) == "table"
            and type(rawget(staticData, "subwayLines")) == "table"
            and type(rawget(staticData, "characters")) == "table"
            and isPlainTableTree(staticData)
    end

    local function cardHasMechanism(card, mechanismId)
        if type(card) ~= "table" or type(card.mechanisms) ~= "table" then
            return false
        end
        for _, id in ipairs(card.mechanisms) do
            if id == mechanismId then
                return true
            end
        end
        return false
    end

    local function appendNestedErrors(target, prefix, nested)
        if type(nested) ~= "table" or type(nested.errors) ~= "table" then
            addError(target, "validation_failed", prefix, "하위 스키마 검증 결과가 올바르지 않습니다.")
            return
        end
        for _, item in ipairs(nested.errors) do
            local suffix = tostring(item.path or "$")
            if string.sub(suffix, 1, 1) == "$" then
                suffix = string.sub(suffix, 2)
            end
            addError(
                target,
                tostring(item.code or "validation_failed"),
                prefix .. suffix,
                tostring(item.message or "하위 스키마 검증에 실패했습니다.")
            )
        end
    end

    local function validatePlanSlot(slot, side, path, errors, instances, staticData, currentTurn)
        if type(slot) ~= "table" then
            addError(errors, "invalid_plan_slot", path, "계획 슬롯이 테이블이 아닙니다.")
            return
        end

        local occupied = slot.occupied
        checkAllowedKeys(slot, {
            occupied = true,
            cardInstanceId = true,
            cardId = true,
            placedTurn = true,
            durationIncludesPlacementTurn = true,
            remainingTurns = true,
            remainingCharges = true,
            revealed = true,
        }, path, errors)

        if occupied ~= true then
            addError(errors, "invalid_plan_occupied", path .. ".occupied", "planSlots에는 occupied = true인 점유 슬롯만 저장할 수 있습니다.")
            return
        end
        if not isRuntimeId(slot.cardInstanceId) then
            addError(errors, "invalid_instance_id", path .. ".cardInstanceId", "계획 카드 인스턴스 ID가 올바르지 않습니다.")
        end
        if not isAsciiId(slot.cardId) then
            addError(errors, "invalid_card_id", path .. ".cardId", "계획 카드 ID가 올바르지 않습니다.")
        end
        if not isInteger(slot.placedTurn, 1) then
            addError(errors, "invalid_placed_turn", path .. ".placedTurn", "배치 턴은 1 이상의 정수여야 합니다.")
        elseif isInteger(currentTurn, 1) and slot.placedTurn > currentTurn then
            addError(errors, "future_placed_turn", path .. ".placedTurn", "계획 배치 턴은 현재 턴보다 클 수 없습니다.")
        end
        if slot.revealed ~= true and slot.revealed ~= false then
            addError(errors, "invalid_revealed", path .. ".revealed", "revealed는 불리언이어야 합니다.")
        end
        if slot.durationIncludesPlacementTurn ~= nil
            and type(slot.durationIncludesPlacementTurn) ~= "boolean" then
            addError(
                errors,
                "invalid_plan_duration_policy",
                path .. ".durationIncludesPlacementTurn",
                "배치 턴 포함 여부는 불리언이어야 합니다."
            )
        elseif slot.durationIncludesPlacementTurn == true and slot.remainingTurns == nil then
            addError(
                errors,
                "plan_duration_policy_requires_duration",
                path .. ".durationIncludesPlacementTurn",
                "배치 턴을 포함하는 계획에는 남은 지속시간이 필요합니다."
            )
        end

        local hasLifetime = false
        if slot.remainingTurns ~= nil then
            hasLifetime = true
            if not isInteger(slot.remainingTurns, 1) then
                addError(errors, "invalid_remaining_turns", path .. ".remainingTurns", "점유된 계획의 남은 지속 턴은 1 이상의 정수여야 합니다.")
            end
        end
        if slot.remainingCharges ~= nil then
            hasLifetime = true
            if not isInteger(slot.remainingCharges, 1) then
                addError(errors, "invalid_remaining_charges", path .. ".remainingCharges", "점유된 계획의 남은 충전은 1 이상의 정수여야 합니다.")
            end
        end
        if not hasLifetime then
            addError(errors, "missing_plan_lifetime", path, "점유된 계획에는 제한된 수명이 필요합니다.")
        end

        local instance = instances[slot.cardInstanceId]
        if not instance then
            addError(errors, "missing_plan_instance", path .. ".cardInstanceId", "계획 카드 인스턴스를 찾을 수 없습니다.")
        else
            if instance.owner ~= side then
                addError(errors, "plan_owner_mismatch", path .. ".cardInstanceId", "계획 슬롯과 카드 소유자가 다릅니다.")
            end
            if instance.zone ~= "plan" then
                addError(errors, "plan_zone_mismatch", path .. ".cardInstanceId", "계획 카드 인스턴스의 zone이 plan이 아닙니다.")
            end
            if instance.cardId ~= slot.cardId then
                addError(errors, "plan_card_mismatch", path .. ".cardId", "계획 슬롯과 카드 인스턴스의 카드 ID가 다릅니다.")
            end
        end

        local cards = type(staticData) == "table" and staticData.cards or nil
        local card = type(cards) == "table" and cards[slot.cardId] or nil
        if card and not cardHasMechanism(card, "plan") then
            addError(errors, "plan_mechanism_missing", path .. ".cardId", "계획 슬롯의 카드에 plan 메커니즘이 없습니다.")
        elseif card then
            local planData = type(card.mechanismData) == "table" and card.mechanismData.plan or nil
            local expectedIncludesPlacementTurn = type(planData) == "table"
                and planData.durationIncludesPlacementTurn == true
            if (slot.durationIncludesPlacementTurn == true) ~= expectedIncludesPlacementTurn then
                addError(
                    errors,
                    "plan_duration_policy_mismatch",
                    path .. ".durationIncludesPlacementTurn",
                    "계획 슬롯의 배치 턴 포함 정책이 정적 카드 정의와 다릅니다."
                )
            end

            local initialDurationTurns = type(planData) == "table" and planData.durationTurns or nil
            if initialDurationTurns ~= nil and slot.remainingTurns == nil then
                addError(
                    errors,
                    "plan_remaining_turns_missing",
                    path .. ".remainingTurns",
                    "정적 카드 정의에 지속시간이 있는 활성 계획에는 remainingTurns가 필요합니다."
                )
            elseif slot.remainingTurns ~= nil then
                if initialDurationTurns == nil then
                    addError(
                        errors,
                        "plan_remaining_turns_undefined",
                        path .. ".remainingTurns",
                        "정적 카드 정의에 지속시간이 없는 계획은 remainingTurns를 가질 수 없습니다."
                    )
                elseif isInteger(slot.remainingTurns, 1)
                    and isInteger(initialDurationTurns, 1)
                    and slot.remainingTurns > initialDurationTurns then
                    addError(
                        errors,
                        "plan_remaining_turns_exceeded",
                        path .. ".remainingTurns",
                        "계획의 남은 지속시간은 정적 카드 정의의 초기 지속시간을 초과할 수 없습니다."
                    )
                end
            end

            local initialCharges = type(planData) == "table" and planData.charges or nil
            if initialCharges ~= nil and slot.remainingCharges == nil then
                addError(
                    errors,
                    "plan_remaining_charges_missing",
                    path .. ".remainingCharges",
                    "정적 카드 정의에 충전이 있는 활성 계획에는 remainingCharges가 필요합니다."
                )
            elseif slot.remainingCharges ~= nil then
                if initialCharges == nil then
                    addError(
                        errors,
                        "plan_remaining_charges_undefined",
                        path .. ".remainingCharges",
                        "정적 카드 정의에 충전이 없는 계획은 remainingCharges를 가질 수 없습니다."
                    )
                elseif isInteger(slot.remainingCharges, 1)
                    and isInteger(initialCharges, 1)
                    and slot.remainingCharges > initialCharges then
                    addError(
                        errors,
                        "plan_remaining_charges_exceeded",
                        path .. ".remainingCharges",
                        "계획의 남은 충전은 정적 카드 정의의 초기 충전을 초과할 수 없습니다."
                    )
                end
            end
        end
    end

    local function validatePlanSlots(
        slots,
        capacity,
        side,
        path,
        errors,
        instances,
        staticData,
        currentTurn
    )
        local capacityPath = "$." .. side .. ".planCapacity"
        local capacityValid = isSafeInteger(capacity, 1) and capacity <= MAX_PLAN_CAPACITY
        if not capacityValid then
            addError(errors, "invalid_plan_capacity", capacityPath, "계획 용량은 1 이상 16 이하의 정수여야 합니다.")
        end

        local slotCount = getArrayLength(slots, path, errors)
        if slotCount == nil then
            return
        end
        if capacityValid and slotCount > capacity then
            addError(errors, "plan_capacity_exceeded", path, "점유 계획 수가 계획 용량을 초과했습니다.")
        end

        local seenInstanceIds = {}
        for index = 1, slotCount do
            local slot = slots[index]
            local slotPath = path .. "[" .. index .. "]"
            validatePlanSlot(slot, side, slotPath, errors, instances, staticData, currentTurn)
            if type(slot) == "table" and isRuntimeId(slot.cardInstanceId) then
                if seenInstanceIds[slot.cardInstanceId] then
                    addError(
                        errors,
                        "duplicate_plan_slot",
                        slotPath .. ".cardInstanceId",
                        "같은 계획 카드 인스턴스를 둘 이상의 슬롯에 저장할 수 없습니다."
                    )
                else
                    seenInstanceIds[slot.cardInstanceId] = true
                end

                local instance = instances[slot.cardInstanceId]
                if instance and instance.owner == side and instance.zone == "plan"
                    and instance.position ~= index then
                    addError(
                        errors,
                        "plan_position_mismatch",
                        slotPath .. ".cardInstanceId",
                        "plan 영역 position은 planSlots 배열 인덱스와 일치해야 합니다."
                    )
                end
            end
        end
    end

    local function validateTurnStartEventSource(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_event_source", path, "턴 시작 사건의 source가 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            kind = true,
            id = true,
            side = true,
            instanceId = true,
        }, path, errors)
        if not isAsciiId(value.kind) then
            addError(errors, "invalid_event_source", path .. ".kind", "사건 source.kind는 lower_snake_case여야 합니다.")
        end
        if not isAsciiId(value.id) then
            addError(errors, "invalid_event_source", path .. ".id", "사건 source.id는 lower_snake_case여야 합니다.")
        end
        if value.side ~= nil and not VALID_OWNER[value.side] then
            addError(errors, "invalid_event_side", path .. ".side", "사건 source.side는 player 또는 character여야 합니다.")
        end
        if value.instanceId ~= nil and not isRuntimeId(value.instanceId) then
            addError(errors, "invalid_instance_id", path .. ".instanceId", "사건 source.instanceId가 올바르지 않습니다.")
        end
    end

    local function validateTurnStartEventCause(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_event_cause", path, "턴 시작 사건의 cause가 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            kind = true,
            resolutionId = true,
            eventId = true,
        }, path, errors)
        if not isAsciiId(value.kind) then
            addError(errors, "invalid_event_cause", path .. ".kind", "사건 cause.kind는 lower_snake_case여야 합니다.")
        end
        if value.resolutionId ~= nil and not isRuntimeId(value.resolutionId) then
            addError(errors, "invalid_resolution_id", path .. ".resolutionId", "사건 cause.resolutionId가 올바르지 않습니다.")
        end
        if value.eventId ~= nil and not isRuntimeId(value.eventId) then
            addError(errors, "invalid_event_id", path .. ".eventId", "사건 cause.eventId가 올바르지 않습니다.")
        end
    end

    local function validateTurnStartEvents(events, turnId, path, errors)
        local eventCount = getArrayLength(events, path, errors)
        if eventCount == nil then
            return
        end

        for index = 1, eventCount do
            local event = events[index]
            local eventPath = path .. "[" .. index .. "]"
            if type(event) ~= "table" then
                addError(errors, "invalid_turn_start_event", eventPath, "턴 시작 사건이 객체가 아닙니다.")
            else
                checkAllowedKeys(event, {
                    eventId = true,
                    sequence = true,
                    type = true,
                    phase = true,
                    resolutionId = true,
                    side = true,
                    source = true,
                    cause = true,
                    payload = true,
                }, eventPath, errors)

                if event.sequence ~= index then
                    addError(errors, "invalid_event_sequence", eventPath .. ".sequence", "턴 시작 사건 sequence는 배열 순서와 일치해야 합니다.")
                end
                if isRuntimeId(turnId) then
                    local expectedEventId = turnId .. "-event-" .. string.format("%03d", index)
                    if event.eventId ~= expectedEventId then
                        addError(errors, "invalid_event_id", eventPath .. ".eventId", "턴 시작 사건 ID가 turnId와 순번에 일치하지 않습니다.")
                    end
                elseif not isRuntimeId(event.eventId) then
                    addError(errors, "invalid_event_id", eventPath .. ".eventId", "턴 시작 사건 ID가 올바르지 않습니다.")
                end
                if not isAsciiId(event.type) then
                    addError(errors, "invalid_event_type", eventPath .. ".type", "사건 type은 lower_snake_case여야 합니다.")
                end
                if event.phase ~= "turn_start" then
                    addError(errors, "invalid_event_phase", eventPath .. ".phase", "turnStartReceipt 사건 phase는 turn_start여야 합니다.")
                end
                if event.resolutionId ~= nil and not isRuntimeId(event.resolutionId) then
                    addError(errors, "invalid_resolution_id", eventPath .. ".resolutionId", "사건 resolutionId가 올바르지 않습니다.")
                end
                if event.side ~= nil and not VALID_OWNER[event.side] then
                    addError(errors, "invalid_event_side", eventPath .. ".side", "사건 side는 player 또는 character여야 합니다.")
                end

                validateTurnStartEventSource(event.source, eventPath .. ".source", errors)
                if event.cause ~= nil then
                    validateTurnStartEventCause(event.cause, eventPath .. ".cause", errors)
                end
                if event.payload ~= nil then
                    local payloadKind = inspectTable(event.payload, eventPath .. ".payload", errors)
                    if payloadKind ~= "object" then
                        addError(errors, "invalid_event_payload", eventPath .. ".payload", "사건 payload는 비어 있지 않은 JSON 객체여야 합니다.")
                    end
                end
            end
        end
    end

    local function rngEqual(left, right)
        return type(left) == "table"
            and type(right) == "table"
            and left.seed == right.seed
            and left.cursor == right.cursor
    end

    local function validateReceiptRng(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_receipt_rng", path, "영수증 RNG가 객체가 아닙니다.")
            return false
        end
        checkAllowedKeys(value, {
            seed = true,
            cursor = true,
        }, path, errors)
        local valid = true
        if not isSafeInteger(value.seed, 0) then
            addError(errors, "invalid_receipt_rng", path .. ".seed", "영수증 RNG seed는 0 이상의 안전한 정수여야 합니다.")
            valid = false
        end
        if not isSafeInteger(value.cursor, 0) then
            addError(errors, "invalid_receipt_rng", path .. ".cursor", "영수증 RNG cursor는 0 이상의 안전한 정수여야 합니다.")
            valid = false
        end
        return valid
    end

    local function validateAuthorityFingerprint(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_authority_fingerprint", path, "권위 상태 fingerprint가 객체가 아닙니다.")
            return false
        end
        checkAllowedKeys(value, {
            algorithm = true,
            length = true,
            hashA = true,
            hashB = true,
        }, path, errors)

        local valid = true
        if value.algorithm ~= FINGERPRINT_ALGORITHM then
            addError(
                errors,
                "invalid_fingerprint_algorithm",
                path .. ".algorithm",
                "지원하지 않는 권위 상태 fingerprint 알고리즘입니다."
            )
            valid = false
        end
        for _, field in ipairs({ "length", "hashA", "hashB" }) do
            if not isSafeInteger(value[field], 0) then
                addError(
                    errors,
                    "invalid_authority_fingerprint",
                    path .. "." .. field,
                    "권위 상태 fingerprint 수치는 0 이상의 안전한 정수여야 합니다."
                )
                valid = false
            end
        end
        return valid
    end

    local function validateDrawReport(report, side, state, path, errors)
        if type(report) ~= "table" then
            addError(errors, "invalid_draw_receipt", path, "기본 드로우 영수증이 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(report, {
            requested = true,
            drawnInstanceIds = true,
            rngBefore = true,
            rngAfter = true,
        }, path, errors)

        local ownerState = type(state) == "table" and state[side] or nil
        local expectedRequested = type(ownerState) == "table" and ownerState.baseDrawCount or nil
        if not isInteger(report.requested, 1) then
            addError(errors, "invalid_draw_requested", path .. ".requested", "기본 드로우 요청 수는 1 이상의 정수여야 합니다.")
        elseif isInteger(expectedRequested, 1) and report.requested ~= expectedRequested then
            addError(
                errors,
                "receipt_draw_count_mismatch",
                path .. ".requested",
                "기본 드로우 요청 수가 현재 진영의 baseDrawCount와 다릅니다."
            )
        end

        local drawnCount = getArrayLength(report.drawnInstanceIds, path .. ".drawnInstanceIds", errors)
        if drawnCount ~= nil then
            validateIdArray(report.drawnInstanceIds, path .. ".drawnInstanceIds", errors, isRuntimeId)
            if isInteger(report.requested, 1) and drawnCount > report.requested then
                addError(errors, "draw_count_exceeded", path .. ".drawnInstanceIds", "실제 드로우 수가 요청 수보다 많습니다.")
            end
        end

        local beforeValid = validateReceiptRng(report.rngBefore, path .. ".rngBefore", errors)
        local afterValid = validateReceiptRng(report.rngAfter, path .. ".rngAfter", errors)
        if beforeValid and afterValid then
            if report.rngAfter.seed ~= report.rngBefore.seed then
                addError(errors, "receipt_rng_seed_changed", path .. ".rngAfter.seed", "드로우 중 RNG seed가 바뀔 수 없습니다.")
            end
            if report.rngAfter.cursor < report.rngBefore.cursor then
                addError(errors, "receipt_rng_reversed", path .. ".rngAfter.cursor", "드로우 중 RNG cursor가 이전으로 돌아갈 수 없습니다.")
            end
        end
    end

    local function validateDraws(draws, state, path, errors)
        if type(draws) ~= "table" then
            addError(errors, "invalid_draw_receipts", path, "기본 드로우 영수증 묶음이 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(draws, {
            player = true,
            character = true,
        }, path, errors)
        validateDrawReport(draws.player, "player", state, path .. ".player", errors)
        validateDrawReport(draws.character, "character", state, path .. ".character", errors)

        local playerAfter = type(draws.player) == "table" and draws.player.rngAfter or nil
        local characterBefore = type(draws.character) == "table" and draws.character.rngBefore or nil
        if type(playerAfter) == "table"
            and type(characterBefore) == "table"
            and not rngEqual(playerAfter, characterBefore) then
            addError(
                errors,
                "receipt_rng_discontinuity",
                path .. ".character.rngBefore",
                "캐릭터 드로우 RNG 시작점이 플레이어 드로우 종료점과 다릅니다."
            )
        end
    end

    local function validateCandidateTotals(totals, path, errors)
        if type(totals) ~= "table" then
            addError(errors, "invalid_selection_totals", path, "후보 효과 합계가 객체가 아닙니다.")
            return
        end
        local fields = {
            "recoverResistance",
            "loseStealth",
            "damageResistance",
            "recoverStealth",
        }
        checkAllowedKeys(totals, {
            recoverResistance = true,
            loseStealth = true,
            damageResistance = true,
            recoverStealth = true,
        }, path, errors)
        for _, field in ipairs(fields) do
            if not isFinite(totals[field]) or totals[field] < 0 then
                addError(
                    errors,
                    "invalid_selection_total",
                    path .. "." .. field,
                    "후보 효과 합계는 0 이상의 유한한 숫자여야 합니다."
                )
            end
        end
    end

    local function validateSelectionContext(context, path, errors)
        if type(context) ~= "table" then
            addError(errors, "invalid_selection_context", path, "선택 시점 컨텍스트가 객체가 아닙니다.")
            return nil
        end
        checkAllowedKeys(context, {
            turnNumber = true,
            player = true,
            character = true,
            characterHand = true,
        }, path, errors)
        if not isInteger(context.turnNumber, 1) then
            addError(errors, "invalid_turn_number", path .. ".turnNumber", "선택 시점 턴 번호는 1 이상의 정수여야 합니다.")
        end

        if type(context.player) ~= "table" then
            addError(errors, "invalid_selection_context", path .. ".player", "선택 시점 플레이어 컨텍스트가 객체가 아닙니다.")
        else
            checkAllowedKeys(context.player, {
                stealth = true,
                handCount = true,
            }, path .. ".player", errors)
            if not isFinite(context.player.stealth) then
                addError(errors, "invalid_selection_context", path .. ".player.stealth", "선택 시점 은폐가 유한한 숫자가 아닙니다.")
            end
            if not isSafeInteger(context.player.handCount, 0) then
                addError(errors, "invalid_selection_context", path .. ".player.handCount", "선택 시점 플레이어 손패 수가 안전한 비음수 정수가 아닙니다.")
            end
        end

        if type(context.character) ~= "table" then
            addError(errors, "invalid_selection_context", path .. ".character", "선택 시점 캐릭터 컨텍스트가 객체가 아닙니다.")
        else
            checkAllowedKeys(context.character, {
                resistance = true,
                mood = true,
            }, path .. ".character", errors)
            if not isFinite(context.character.resistance) then
                addError(errors, "invalid_selection_context", path .. ".character.resistance", "선택 시점 저항이 유한한 숫자가 아닙니다.")
            end
            if not isAsciiId(context.character.mood) then
                addError(errors, "invalid_selection_context", path .. ".character.mood", "선택 시점 무드 ID가 올바르지 않습니다.")
            end
        end

        local handCount = getArrayLength(context.characterHand, path .. ".characterHand", errors)
        local seen = {}
        if handCount ~= nil then
            for index = 1, handCount do
                local entry = context.characterHand[index]
                local entryPath = path .. ".characterHand[" .. index .. "]"
                if type(entry) ~= "table" then
                    addError(errors, "invalid_selection_hand_entry", entryPath, "선택 시점 손패 항목이 객체가 아닙니다.")
                else
                    checkAllowedKeys(entry, {
                        instanceId = true,
                        cardId = true,
                        actionTag = true,
                        handPosition = true,
                    }, entryPath, errors)
                    if not isRuntimeId(entry.instanceId) then
                        addError(errors, "invalid_instance_id", entryPath .. ".instanceId", "선택 시점 손패 인스턴스 ID가 올바르지 않습니다.")
                    elseif seen[entry.instanceId] then
                        addError(errors, "duplicate_id", entryPath .. ".instanceId", "선택 시점 손패 인스턴스 ID가 중복되었습니다.")
                    else
                        seen[entry.instanceId] = true
                    end
                    if not isAsciiId(entry.cardId) then
                        addError(errors, "invalid_card_id", entryPath .. ".cardId", "선택 시점 손패 카드 ID가 올바르지 않습니다.")
                    end
                    if not isAsciiId(entry.actionTag) then
                        addError(errors, "invalid_action_tag", entryPath .. ".actionTag", "선택 시점 손패 행동 태그가 올바르지 않습니다.")
                    end
                    if entry.handPosition ~= index then
                        addError(errors, "invalid_hand_position", entryPath .. ".handPosition", "선택 시점 캐릭터 손패 위치는 안정 순서의 1부터 연속되어야 합니다.")
                    end
                end
            end
        end
        return handCount
    end

    local function validateSelectionCandidate(candidate, path, errors)
        if type(candidate) ~= "table" then
            addError(errors, "invalid_selection_candidate", path, "캐릭터 선택 후보가 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(candidate, {
            instanceId = true,
            cardId = true,
            actionTag = true,
            handPosition = true,
            score = true,
            projectedPlayerStealth = true,
            lethal = true,
            weight = true,
            totals = true,
            planChargesEvaluated = true,
        }, path, errors)

        if not isRuntimeId(candidate.instanceId) then
            addError(errors, "invalid_instance_id", path .. ".instanceId", "후보 카드 인스턴스 ID가 올바르지 않습니다.")
        end
        if not isAsciiId(candidate.cardId) then
            addError(errors, "invalid_card_id", path .. ".cardId", "후보 카드 ID가 올바르지 않습니다.")
        end
        if not isAsciiId(candidate.actionTag) then
            addError(errors, "invalid_action_tag", path .. ".actionTag", "후보 행동 태그가 올바르지 않습니다.")
        end
        if not isInteger(candidate.handPosition, 1) then
            addError(errors, "invalid_hand_position", path .. ".handPosition", "후보 손패 위치는 1 이상의 정수여야 합니다.")
        end
        if not isSafeInteger(candidate.score) then
            addError(errors, "invalid_selection_score", path .. ".score", "후보 점수는 안전한 정수여야 합니다.")
        end
        if not isFinite(candidate.projectedPlayerStealth) then
            addError(errors, "invalid_projected_stealth", path .. ".projectedPlayerStealth", "예상 플레이어 은폐가 유한한 숫자가 아닙니다.")
        end
        if candidate.lethal ~= true and candidate.lethal ~= false then
            addError(errors, "invalid_lethal_flag", path .. ".lethal", "lethal은 불리언이어야 합니다.")
        elseif isFinite(candidate.projectedPlayerStealth)
            and candidate.lethal ~= (candidate.projectedPlayerStealth <= 0) then
            addError(errors, "lethal_projection_mismatch", path .. ".lethal", "lethal 값이 예상 플레이어 은폐와 다릅니다.")
        end
        if not isSafeInteger(candidate.weight, 0) then
            addError(errors, "invalid_selection_weight", path .. ".weight", "후보 가중치는 0 이상의 안전한 정수여야 합니다.")
        end

        validateCandidateTotals(candidate.totals, path .. ".totals", errors)
        if not isSafeInteger(candidate.planChargesEvaluated, 0) then
            addError(
                errors,
                "invalid_plan_charge_count",
                path .. ".planChargesEvaluated",
                "평가한 계획 충전 수는 0 이상의 안전한 정수여야 합니다."
            )
        end
    end

    local function validateSelectionDraw(draw, path, errors)
        if type(draw) ~= "table" then
            addError(errors, "invalid_selection_draw", path, "선택 추첨 영수증이 객체가 아닙니다.")
            return
        end

        if draw.kind == "pass" then
            checkAllowedKeys(draw, { kind = true }, path, errors)
        elseif draw.kind == "single" then
            checkAllowedKeys(draw, { kind = true, totalWeight = true }, path, errors)
            if not isSafeInteger(draw.totalWeight, 1) then
                addError(errors, "invalid_draw_weight", path .. ".totalWeight", "단독 후보 가중치는 1 이상의 안전한 정수여야 합니다.")
            end
        elseif draw.kind == "weighted" then
            checkAllowedKeys(draw, {
                kind = true,
                totalWeight = true,
                roll = true,
            }, path, errors)
            if not isSafeInteger(draw.totalWeight, 1) then
                addError(errors, "invalid_draw_weight", path .. ".totalWeight", "가중 추첨의 총 가중치는 1 이상의 안전한 정수여야 합니다.")
            end
            if not isSafeInteger(draw.roll, 1) then
                addError(errors, "invalid_draw_roll", path .. ".roll", "가중 추첨 roll은 1 이상의 안전한 정수여야 합니다.")
            elseif isSafeInteger(draw.totalWeight, 1) and draw.roll > draw.totalWeight then
                addError(errors, "invalid_draw_roll", path .. ".roll", "가중 추첨 roll이 총 가중치를 초과합니다.")
            end
        else
            checkAllowedKeys(draw, {
                kind = true,
                totalWeight = true,
                roll = true,
            }, path, errors)
            addError(errors, "invalid_selection_draw", path .. ".kind", "알 수 없는 선택 추첨 방식입니다.")
        end
    end

    local function findStateInstance(state, instanceId)
        if type(state) ~= "table" or type(state.cardInstances) ~= "table" then
            return nil
        end
        for _, instance in ipairs(state.cardInstances) do
            if type(instance) == "table" and instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function countStateZone(state, owner, zone)
        local count = 0
        for _, instance in ipairs(type(state) == "table" and type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if type(instance) == "table" and instance.owner == owner and instance.zone == zone then
                count = count + 1
            end
        end
        return count
    end

    local function buildExpectedSelectionContext(state, events, staticData)
        local revealEventIds = {}
        for _, event in ipairs(type(events) == "table" and events or {}) do
            if type(event) == "table" and event.type == "action_tag_revealed" and isRuntimeId(event.eventId) then
                revealEventIds[event.eventId] = true
            end
        end

        local playerStealth = type(state.player) == "table" and state.player.stealth or nil
        local playerHandCount = countStateZone(state, "player", "hand")
        local characterResistance = type(state.character) == "table" and state.character.resistance or nil
        local characterMood = type(state.character) == "table" and state.character.mood or nil
        local postSelectionCharacterDraws = {}

        if type(events) == "table" then
            for index = #events, 1, -1 do
                local event = events[index]
                local causedByReveal = type(event) == "table"
                    and event.type == "effect_applied"
                    and type(event.cause) == "table"
                    and revealEventIds[event.cause.eventId] == true
                local payload = causedByReveal and event.payload or nil
                if type(payload) == "table" then
                    if (payload.op == "lose_stealth" or payload.op == "recover_stealth")
                        and payload.target == "player"
                        and isFinite(payload.before) then
                        playerStealth = payload.before
                    elseif (payload.op == "recover_resistance" or payload.op == "damage_resistance")
                        and payload.target == "character"
                        and isFinite(payload.before) then
                        characterResistance = payload.before
                    elseif payload.op == "draw_cards" and payload.target == "player" then
                        local drawnCount = type(payload.drawnInstanceIds) == "table" and #payload.drawnInstanceIds or 0
                        playerHandCount = playerHandCount - drawnCount
                    elseif payload.op == "draw_cards" and payload.target == "character" then
                        for _, instanceId in ipairs(type(payload.drawnInstanceIds) == "table" and payload.drawnInstanceIds or {}) do
                            postSelectionCharacterDraws[instanceId] = true
                        end
                    end
                end
            end
        end

        local hand = {}
        for sourceIndex, instance in ipairs(type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if type(instance) == "table"
                and instance.owner == "character"
                and instance.zone == "hand"
                and not postSelectionCharacterDraws[instance.instanceId] then
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
                stealth = playerStealth,
                handCount = playerHandCount,
            },
            character = {
                resistance = characterResistance,
                mood = characterMood,
            },
            characterHand = characterHand,
        }
    end

    local function selectionContextEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table"
            or left.turnNumber ~= right.turnNumber
            or type(left.player) ~= "table" or type(right.player) ~= "table"
            or left.player.stealth ~= right.player.stealth
            or left.player.handCount ~= right.player.handCount
            or type(left.character) ~= "table" or type(right.character) ~= "table"
            or left.character.resistance ~= right.character.resistance
            or left.character.mood ~= right.character.mood
            or type(left.characterHand) ~= "table" or type(right.characterHand) ~= "table"
            or #left.characterHand ~= #right.characterHand then
            return false
        end
        for index, expected in ipairs(right.characterHand) do
            local actual = left.characterHand[index]
            if type(actual) ~= "table"
                or actual.instanceId ~= expected.instanceId
                or actual.cardId ~= expected.cardId
                or actual.actionTag ~= expected.actionTag
                or actual.handPosition ~= expected.handPosition then
                return false
            end
        end
        return true
    end

    local function callReceiptValidator(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, "스크립트 실행기를 찾을 수 없습니다."
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok then
            return nil, tostring(report)
        end
        if type(report) ~= "table" then
            return nil, "하위 검증기가 테이블 결과를 반환하지 않았습니다."
        end
        return report, nil
    end

    local function validateCharacterSelection(selection, state, staticData, referencesValidated, events, path, errors)
        if type(selection) ~= "table" then
            addError(errors, "invalid_character_selection_receipt", path, "캐릭터 선택 영수증이 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(selection, {
            schemaVersion = true,
            kind = true,
            battleId = true,
            turnNumber = true,
            characterId = true,
            selectionContext = true,
            candidates = true,
            weightedPoolInstanceIds = true,
            lethalPriorityApplied = true,
            weightOffset = true,
            rngBefore = true,
            rngAfter = true,
            draw = true,
            selectedInstanceId = true,
            selectedCardId = true,
            publicActionTag = true,
        }, path, errors)

        if selection.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "invalid_selection_schema", path .. ".schemaVersion", "지원하지 않는 캐릭터 선택 영수증 스키마입니다.")
        end
        if selection.kind ~= "characterIntentSelection" then
            addError(errors, "invalid_selection_kind", path .. ".kind", "kind는 characterIntentSelection이어야 합니다.")
        end
        if not isRuntimeId(selection.battleId) then
            addError(errors, "invalid_battle_id", path .. ".battleId", "선택 영수증 battleId가 올바르지 않습니다.")
        elseif selection.battleId ~= state.battleId then
            addError(errors, "selection_battle_mismatch", path .. ".battleId", "선택 영수증 battleId가 현재 전투와 다릅니다.")
        end
        if not isInteger(selection.turnNumber, 1) then
            addError(errors, "invalid_turn_number", path .. ".turnNumber", "선택 영수증 턴 번호는 1 이상의 정수여야 합니다.")
        elseif selection.turnNumber ~= state.turnNumber then
            addError(errors, "selection_turn_mismatch", path .. ".turnNumber", "선택 영수증 턴 번호가 현재 전투와 다릅니다.")
        end
        if not isAsciiId(selection.characterId) then
            addError(errors, "invalid_character_id", path .. ".characterId", "선택 영수증 캐릭터 ID가 올바르지 않습니다.")
        elseif type(state.character) == "table" and selection.characterId ~= state.character.characterId then
            addError(errors, "selection_character_mismatch", path .. ".characterId", "선택 영수증 캐릭터 ID가 현재 전투와 다릅니다.")
        end

        local contextPath = path .. ".selectionContext"
        local contextHandCount = validateSelectionContext(selection.selectionContext, contextPath, errors)
        if type(selection.selectionContext) == "table" then
            if selection.selectionContext.turnNumber ~= selection.turnNumber then
                addError(errors, "selection_context_turn_mismatch", contextPath .. ".turnNumber", "선택 시점 컨텍스트의 턴 번호가 선택 영수증과 다릅니다.")
            end
            local contextMood = type(selection.selectionContext.character) == "table"
                and selection.selectionContext.character.mood
                or nil
            if referencesValidated and isAsciiId(contextMood) then
                local moods = type(staticData.registry) == "table" and staticData.registry.moods or nil
                if type(moods) ~= "table" or moods[contextMood] == nil then
                    addError(errors, "unknown_mood", contextPath .. ".character.mood", "선택 시점 무드가 정적 레지스트리에 없습니다.")
                end
            end
            local expectedContext = referencesValidated and buildExpectedSelectionContext(state, events, staticData) or nil
            if expectedContext ~= nil and not selectionContextEqual(selection.selectionContext, expectedContext) then
                addError(
                    errors,
                    "selection_context_state_mismatch",
                    contextPath,
                    "선택 시점 컨텍스트가 현재 상태와 행동 태그 공개 이후 효과를 역산한 결과와 다릅니다."
                )
            end
        end

        local candidateCount = getArrayLength(selection.candidates, path .. ".candidates", errors)
        local candidateById = {}
        local positionSeen = {}
        if candidateCount ~= nil then
            for index = 1, candidateCount do
                local candidate = selection.candidates[index]
                local candidatePath = path .. ".candidates[" .. index .. "]"
                validateSelectionCandidate(candidate, candidatePath, errors)
                if type(candidate) == "table" then
                    if isRuntimeId(candidate.instanceId) then
                        if candidateById[candidate.instanceId] then
                            addError(errors, "duplicate_selection_candidate", candidatePath .. ".instanceId", "후보 인스턴스 ID가 중복되었습니다.")
                        else
                            candidateById[candidate.instanceId] = candidate
                        end
                    end
                    if isInteger(candidate.handPosition, 1) then
                        if positionSeen[candidate.handPosition] then
                            addError(errors, "duplicate_hand_position", candidatePath .. ".handPosition", "후보 손패 위치가 중복되었습니다.")
                        end
                        positionSeen[candidate.handPosition] = true
                    end
                end
            end
        end

        if candidateCount ~= nil and contextHandCount ~= nil then
            if candidateCount ~= contextHandCount then
                addError(errors, "selection_candidate_count_mismatch", path .. ".candidates", "후보 목록이 선택 시점 캐릭터 손패 전체와 장수가 다릅니다.")
            end
            local comparisonCount = math.min(candidateCount, contextHandCount)
            for index = 1, comparisonCount do
                local candidate = selection.candidates[index]
                local handEntry = selection.selectionContext.characterHand[index]
                local candidatePath = path .. ".candidates[" .. index .. "]"
                if type(candidate) == "table" and type(handEntry) == "table" then
                    if candidate.instanceId ~= handEntry.instanceId
                        or candidate.cardId ~= handEntry.cardId
                        or candidate.actionTag ~= handEntry.actionTag
                        or candidate.handPosition ~= handEntry.handPosition then
                        addError(errors, "selection_candidate_hand_mismatch", candidatePath, "후보의 순서·인스턴스·카드·행동 태그·위치가 선택 시점 손패와 다릅니다.")
                    end
                    local totals = candidate.totals
                    if type(totals) == "table"
                        and isFinite(totals.recoverResistance)
                        and isFinite(totals.loseStealth)
                        and isFinite(totals.damageResistance)
                        and isFinite(totals.recoverStealth) then
                        local expectedScore = totals.recoverResistance
                            + totals.loseStealth
                            - totals.damageResistance
                            - totals.recoverStealth
                        if candidate.score ~= expectedScore then
                            addError(errors, "selection_score_mismatch", candidatePath .. ".score", "후보 점수가 효과 합계의 순저항 감소치와 다릅니다.")
                        end
                        local contextStealth = type(selection.selectionContext.player) == "table"
                            and selection.selectionContext.player.stealth
                            or nil
                        if isFinite(contextStealth) then
                            local expectedStealth = contextStealth
                                - totals.loseStealth
                                + totals.recoverStealth
                            if candidate.projectedPlayerStealth ~= expectedStealth then
                                addError(errors, "selection_projection_mismatch", candidatePath .. ".projectedPlayerStealth", "예상 플레이어 은폐가 선택 시점 효과 합계와 다릅니다.")
                            end
                        end
                    end
                    if referencesValidated and isAsciiId(candidate.cardId) then
                        local card = staticData.cards[candidate.cardId]
                        local expectedCharges = 0
                        if type(card) == "table"
                            and type(card.mechanisms) == "table" then
                            for _, mechanismId in ipairs(card.mechanisms) do
                                if mechanismId == "plan" then
                                    local plan = type(card.mechanismData) == "table" and card.mechanismData.plan or nil
                                    expectedCharges = type(plan) == "table" and plan.charges or nil
                                    break
                                end
                            end
                        end
                        if candidate.planChargesEvaluated ~= expectedCharges then
                            addError(errors, "selection_plan_charges_mismatch", candidatePath .. ".planChargesEvaluated", "평가한 계획 충전 수가 정적 카드 정의와 다릅니다.")
                        end
                    end
                end
            end
        end

        if referencesValidated and type(selection.selectionContext) == "table" then
            local replayReport, replayCallError = callReceiptValidator(
                "characterSelector",
                "validateReceipt",
                staticData,
                selection
            )
            if replayCallError ~= nil then
                addError(errors, "selection_replay_unavailable", path, "캐릭터 선택 효과 재생 검증을 실행할 수 없습니다: " .. replayCallError)
            elseif replayReport.ok ~= true then
                local nestedErrors = type(replayReport.errors) == "table" and replayReport.errors or {}
                if #nestedErrors == 0 then
                    addError(errors, "selection_replay_failed", path, "캐릭터 선택 효과 재생 검증이 실패했습니다.")
                else
                    for _, nested in ipairs(nestedErrors) do
                        local nestedPath = type(nested) == "table" and nested.path or "$"
                        if type(nestedPath) == "string" and string.sub(nestedPath, 1, 9) == "$.receipt" then
                            nestedPath = path .. string.sub(nestedPath, 10)
                        else
                            nestedPath = path
                        end
                        addError(
                            errors,
                            type(nested) == "table" and tostring(nested.code) or "selection_replay_failed",
                            nestedPath,
                            type(nested) == "table" and tostring(nested.message) or "캐릭터 선택 효과 재생 검증이 실패했습니다."
                        )
                    end
                end
            elseif replayReport.valid ~= true then
                addError(errors, "selection_replay_failed", path, "캐릭터 선택 효과 재생 검증기가 valid 결과를 반환하지 않았습니다.")
            end
        end

        validateIdArray(selection.weightedPoolInstanceIds, path .. ".weightedPoolInstanceIds", errors, isRuntimeId)
        local poolCount = type(selection.weightedPoolInstanceIds) == "table" and #selection.weightedPoolInstanceIds or 0
        local poolIdSet = {}
        for index, instanceId in ipairs(type(selection.weightedPoolInstanceIds) == "table" and selection.weightedPoolInstanceIds or {}) do
            if candidateById[instanceId] == nil then
                addError(errors, "unknown_selection_pool_candidate", path .. ".weightedPoolInstanceIds[" .. index .. "]", "가중 추첨 후보가 candidates에 없습니다.")
            elseif poolIdSet[instanceId] then
                addError(errors, "duplicate_selection_pool_candidate", path .. ".weightedPoolInstanceIds[" .. index .. "]", "가중 추첨 후보가 중복되었습니다.")
            else
                poolIdSet[instanceId] = true
            end
        end

        if selection.lethalPriorityApplied ~= true and selection.lethalPriorityApplied ~= false then
            addError(errors, "invalid_lethal_priority", path .. ".lethalPriorityApplied", "lethalPriorityApplied는 불리언이어야 합니다.")
        end
        local beforeValid = validateReceiptRng(selection.rngBefore, path .. ".rngBefore", errors)
        local afterValid = validateReceiptRng(selection.rngAfter, path .. ".rngAfter", errors)
        if beforeValid and afterValid then
            if selection.rngAfter.seed ~= selection.rngBefore.seed then
                addError(errors, "receipt_rng_seed_changed", path .. ".rngAfter.seed", "캐릭터 선택 중 RNG seed가 바뀔 수 없습니다.")
            end
            if selection.rngAfter.cursor < selection.rngBefore.cursor then
                addError(errors, "receipt_rng_reversed", path .. ".rngAfter.cursor", "캐릭터 선택 중 RNG cursor가 이전으로 돌아갈 수 없습니다.")
            end
        end
        validateSelectionDraw(selection.draw, path .. ".draw", errors)

        local intent = type(state) == "table" and state.characterIntent or nil
        local intentIds = type(intent) == "table" and intent.cardInstanceIds or nil
        local selected = selection.selectedInstanceId ~= nil
        if not selected then
            if selection.selectedCardId ~= nil
                or selection.publicActionTag ~= nil
                or selection.weightOffset ~= nil then
                addError(errors, "selection_pass_field_conflict", path, "패스 영수증에는 선택 카드 필드를 둘 수 없습니다.")
            end
            if type(selection.draw) ~= "table" or selection.draw.kind ~= "pass" then
                addError(errors, "selection_pass_draw_mismatch", path .. ".draw", "패스 영수증의 draw.kind는 pass여야 합니다.")
            end
            if candidateCount ~= nil and candidateCount ~= 0 then
                addError(errors, "selection_pass_has_candidates", path .. ".candidates", "패스 영수증에는 후보가 없어야 합니다.")
            end
            if poolCount ~= 0 then
                addError(errors, "selection_pass_has_pool", path .. ".weightedPoolInstanceIds", "패스 영수증에는 가중 추첨 후보가 없어야 합니다.")
            end
            if selection.lethalPriorityApplied ~= false then
                addError(errors, "selection_pass_lethal_priority", path .. ".lethalPriorityApplied", "패스에는 치명 우선순위를 적용할 수 없습니다.")
            end
            if beforeValid and afterValid and not rngEqual(selection.rngBefore, selection.rngAfter) then
                addError(errors, "selection_pass_consumed_rng", path .. ".rngAfter", "패스는 RNG를 소비할 수 없습니다.")
            end
            if type(intentIds) ~= "table" or #intentIds ~= 0 or (type(intent) == "table" and intent.publicActionTag ~= nil) then
                addError(errors, "character_selection_intent_mismatch", "$.characterIntent", "패스 영수증과 현재 characterIntent가 다릅니다.")
            end
            return
        end

        if not isRuntimeId(selection.selectedInstanceId) then
            addError(errors, "invalid_instance_id", path .. ".selectedInstanceId", "선택한 카드 인스턴스 ID가 올바르지 않습니다.")
        end
        if not isAsciiId(selection.selectedCardId) then
            addError(errors, "invalid_card_id", path .. ".selectedCardId", "선택한 카드 ID가 올바르지 않습니다.")
        end
        if not isAsciiId(selection.publicActionTag) then
            addError(errors, "invalid_action_tag", path .. ".publicActionTag", "선택한 공개 행동 태그가 올바르지 않습니다.")
        end
        if not isSafeInteger(selection.weightOffset, 0) then
            addError(errors, "invalid_selection_weight_offset", path .. ".weightOffset", "점수 가중치 평행이동 값은 0 이상의 안전한 정수여야 합니다.")
        end
        if type(selection.draw) ~= "table"
            or (selection.draw.kind ~= "single" and selection.draw.kind ~= "weighted") then
            addError(errors, "selection_selected_draw_mismatch", path .. ".draw", "선택 영수증은 single 또는 weighted 추첨을 사용해야 합니다.")
        end
        if candidateCount == 0 then
            addError(errors, "selection_missing_candidates", path .. ".candidates", "선택 영수증에는 후보가 필요합니다.")
        end
        if poolCount == 0 then
            addError(errors, "selection_missing_weighted_pool", path .. ".weightedPoolInstanceIds", "선택 영수증에는 가중 추첨 후보가 필요합니다.")
        end

        local selectedCandidate = candidateById[selection.selectedInstanceId]
        if selectedCandidate == nil then
            addError(errors, "selected_candidate_missing", path .. ".selectedInstanceId", "선택한 인스턴스가 candidates에 없습니다.")
        else
            if selectedCandidate.cardId ~= selection.selectedCardId then
                addError(errors, "selected_card_mismatch", path .. ".selectedCardId", "선택 카드 ID가 후보와 다릅니다.")
            end
            if selectedCandidate.actionTag ~= selection.publicActionTag then
                addError(errors, "selected_action_tag_mismatch", path .. ".publicActionTag", "선택 행동 태그가 후보와 다릅니다.")
            end
        end

        local anyLethal = false
        if type(selection.candidates) == "table" then
            for _, candidate in ipairs(selection.candidates) do
                if type(candidate) == "table" and candidate.lethal == true then
                    anyLethal = true
                    break
                end
            end
        end
        if (selection.lethalPriorityApplied == true) ~= anyLethal then
            addError(errors, "lethal_priority_mismatch", path .. ".lethalPriorityApplied", "치명 우선순위가 후보의 lethal 값과 다릅니다.")
        end

        local expectedPool = {}
        local expectedPoolSet = {}
        local minimumPoolScore = nil
        local anyPositivePoolScore = false
        if type(selection.candidates) == "table" then
            for _, candidate in ipairs(selection.candidates) do
                if type(candidate) == "table"
                    and isRuntimeId(candidate.instanceId)
                    and isSafeInteger(candidate.score)
                    and (not anyLethal or candidate.lethal == true) then
                    expectedPool[#expectedPool + 1] = candidate.instanceId
                    expectedPoolSet[candidate.instanceId] = true
                    if minimumPoolScore == nil or candidate.score < minimumPoolScore then
                        minimumPoolScore = candidate.score
                    end
                    if candidate.score > 0 then
                        anyPositivePoolScore = true
                    end
                end
            end
        end

        local poolMatches = #expectedPool == poolCount
        if poolMatches then
            for index = 1, poolCount do
                if expectedPool[index] ~= selection.weightedPoolInstanceIds[index] then
                    poolMatches = false
                    break
                end
            end
        end
        if not poolMatches then
            addError(errors, "selection_weighted_pool_mismatch", path .. ".weightedPoolInstanceIds", "가중 추첨 후보 배열이 치명 우선순위 결과와 다릅니다.")
        end

        local expectedOffset = nil
        if minimumPoolScore ~= nil then
            expectedOffset = anyPositivePoolScore and 0 or (1 - minimumPoolScore)
            if not isSafeInteger(expectedOffset, 0) then
                addError(errors, "invalid_selection_weight_offset", path .. ".weightOffset", "후보 점수에서 안전한 평행이동 값을 계산할 수 없습니다.")
            elseif selection.weightOffset ~= expectedOffset then
                addError(errors, "selection_weight_offset_mismatch", path .. ".weightOffset", "점수 가중치 평행이동 값이 후보 점수와 다릅니다.")
            end
        end

        local totalWeight = 0
        if type(selection.candidates) == "table" then
            for index, candidate in ipairs(selection.candidates) do
                if type(candidate) == "table" and isSafeInteger(candidate.score) then
                    local expectedWeight = 0
                    if expectedPoolSet[candidate.instanceId] and isSafeInteger(expectedOffset, 0) then
                        local adjusted = candidate.score + expectedOffset
                        if isSafeInteger(adjusted) and adjusted > 0 then
                            expectedWeight = adjusted
                        end
                    end
                    if candidate.weight ~= expectedWeight then
                        addError(errors, "selection_weight_mismatch", path .. ".candidates[" .. index .. "].weight", "후보 가중치가 총효과 점수 정책과 다릅니다.")
                    end
                    if expectedPoolSet[candidate.instanceId] and isSafeInteger(expectedWeight, 0) then
                        if isSafeInteger(totalWeight + expectedWeight, 0) then
                            totalWeight = totalWeight + expectedWeight
                        else
                            addError(errors, "selection_total_weight_overflow", path .. ".candidates", "가중 추첨 총합이 안전한 정수 범위를 벗어났습니다.")
                        end
                    end
                end
            end
        end
        if totalWeight <= 0 and poolCount > 0 then
            addError(errors, "selection_zero_total_weight", path .. ".candidates", "가중 추첨 후보의 총 가중치는 1 이상이어야 합니다.")
        end
        if selectedCandidate ~= nil and not expectedPoolSet[selection.selectedInstanceId] then
            addError(errors, "selected_candidate_outside_pool", path .. ".selectedInstanceId", "선택된 카드는 가중 추첨 후보에 포함되어야 합니다.")
        end

        local draw = selection.draw
        if type(draw) == "table" and draw.kind == "single" then
            if poolCount ~= 1 or selection.weightedPoolInstanceIds[1] ~= selection.selectedInstanceId then
                addError(errors, "single_draw_mismatch", path .. ".draw", "single 추첨은 유일한 가중 추첨 후보를 선택해야 합니다.")
            elseif draw.totalWeight ~= totalWeight then
                addError(errors, "draw_weight_mismatch", path .. ".draw.totalWeight", "single 총 가중치가 후보 가중치와 다릅니다.")
            end
            if beforeValid and afterValid and not rngEqual(selection.rngBefore, selection.rngAfter) then
                addError(errors, "single_selection_consumed_rng", path .. ".rngAfter", "single 선택은 RNG를 소비할 수 없습니다.")
            end
        elseif type(draw) == "table" and draw.kind == "weighted" then
            if poolCount < 2 then
                addError(errors, "weighted_draw_missing_candidates", path .. ".weightedPoolInstanceIds", "weighted 추첨에는 후보가 둘 이상 필요합니다.")
            end
            if draw.totalWeight ~= totalWeight then
                addError(errors, "draw_weight_mismatch", path .. ".draw.totalWeight", "weighted 총 가중치가 추첨 후보 가중치 합과 다릅니다.")
            end
            if isSafeInteger(draw.roll, 1) then
                local cumulative = 0
                local rolledInstanceId = nil
                for _, instanceId in ipairs(type(selection.weightedPoolInstanceIds) == "table" and selection.weightedPoolInstanceIds or {}) do
                    local candidate = candidateById[instanceId]
                    if candidate and isSafeInteger(candidate.weight, 0) then
                        cumulative = cumulative + candidate.weight
                        if candidate.weight > 0 and draw.roll <= cumulative then
                            rolledInstanceId = instanceId
                            break
                        end
                    end
                end
                if rolledInstanceId ~= selection.selectedInstanceId then
                    addError(errors, "weighted_result_mismatch", path .. ".selectedInstanceId", "weighted roll 결과와 선택 인스턴스가 다릅니다.")
                end
            end
            if beforeValid and isSafeInteger(totalWeight, 1) then
                local rngReplay, rngReplayCallError = callReceiptValidator(
                    "deterministicRng",
                    "nextInteger",
                    selection.rngBefore,
                    1,
                    totalWeight
                )
                if rngReplayCallError ~= nil then
                    addError(errors, "selection_rng_replay_unavailable", path .. ".draw", "선택 RNG를 재생할 수 없습니다: " .. rngReplayCallError)
                elseif rngReplay.ok ~= true then
                    addError(errors, "selection_rng_replay_failed", path .. ".draw", "결정적 선택 RNG 재생이 실패했습니다.")
                else
                    if rngReplay.value ~= draw.roll then
                        addError(errors, "selection_roll_replay_mismatch", path .. ".draw.roll", "기록된 roll이 rngBefore와 총 가중치의 결정적 재생 결과와 다릅니다.")
                    end
                    if afterValid and not rngEqual(rngReplay.rng, selection.rngAfter) then
                        addError(errors, "selection_rng_after_replay_mismatch", path .. ".rngAfter", "기록된 rngAfter가 결정적 가중 추첨 재생 결과와 다릅니다.")
                    end
                end
            end
            if beforeValid and afterValid and selection.rngAfter.cursor <= selection.rngBefore.cursor then
                addError(errors, "weighted_selection_rng_missing", path .. ".rngAfter.cursor", "weighted 선택은 RNG cursor를 전진시켜야 합니다.")
            end
        end

        if type(intentIds) ~= "table"
            or #intentIds ~= 1
            or intentIds[1] ~= selection.selectedInstanceId
            or type(intent) ~= "table"
            or intent.publicActionTag ~= selection.publicActionTag then
            addError(errors, "character_selection_intent_mismatch", "$.characterIntent", "선택 영수증과 현재 characterIntent가 다릅니다.")
        end

        local instance = findStateInstance(state, selection.selectedInstanceId)
        if instance == nil
            or instance.owner ~= "character"
            or instance.zone ~= "hand"
            or instance.cardId ~= selection.selectedCardId then
            addError(errors, "selected_instance_mismatch", path .. ".selectedInstanceId", "선택 인스턴스가 현재 캐릭터 손패·카드와 일치하지 않습니다.")
        end
        if referencesValidated and isAsciiId(selection.selectedCardId) then
            local card = staticData.cards[selection.selectedCardId]
            if type(card) ~= "table"
                or card.owner ~= "character"
                or card.actionTag ~= selection.publicActionTag then
                addError(errors, "selected_static_card_mismatch", path .. ".selectedCardId", "선택 카드와 정적 카드 행동 태그가 일치하지 않습니다.")
            end
        end
    end

    local function validateTurnStartReceipt(receipt, state, staticData, referencesValidated, errors)
        local path = "$.turnStartReceipt"
        if type(receipt) ~= "table" then
            addError(errors, "invalid_turn_start_receipt", path, "turnStartReceipt가 객체가 아닙니다.")
            return
        end

        checkAllowedKeys(receipt, {
            schemaVersion = true,
            kind = true,
            turnId = true,
            turnNumber = true,
            authorityFingerprint = true,
            draws = true,
            characterSelection = true,
            baseline = true,
            transient = true,
            events = true,
        }, path, errors)
        if receipt.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "invalid_receipt_schema", path .. ".schemaVersion", "지원하지 않는 turnStartReceipt 스키마입니다.")
        end
        if receipt.kind ~= "turnStartReceipt" then
            addError(errors, "invalid_receipt_kind", path .. ".kind", "kind는 turnStartReceipt여야 합니다.")
        end
        if not isRuntimeId(receipt.turnId) then
            addError(errors, "invalid_turn_id", path .. ".turnId", "turnStartReceipt turnId가 올바르지 않습니다.")
        elseif state.lastCommittedTurnId == receipt.turnId then
            addError(errors, "turn_already_committed", path .. ".turnId", "이미 확정한 turnId를 현재 턴 초기화에 사용할 수 없습니다.")
        end
        if not isInteger(receipt.turnNumber, 1) then
            addError(errors, "invalid_turn_number", path .. ".turnNumber", "turnStartReceipt 턴 번호는 1 이상의 정수여야 합니다.")
        elseif receipt.turnNumber ~= state.turnNumber then
            addError(errors, "receipt_turn_mismatch", path .. ".turnNumber", "turnStartReceipt 턴 번호가 현재 전투 턴과 다릅니다.")
        end
        if state.status ~= "active" then
            addError(errors, "receipt_requires_active", path, "turnStartReceipt는 active 전투 상태에만 존재할 수 있습니다.")
        end

        local fingerprintPath = path .. ".authorityFingerprint"
        local fingerprintValid = validateAuthorityFingerprint(receipt.authorityFingerprint, fingerprintPath, errors)
        if fingerprintValid then
            local expectedFingerprint, fingerprintError = fingerprintAuthorityState(state)
            if fingerprintError then
                addError(errors, fingerprintError.code, fingerprintError.path, fingerprintError.message)
            elseif receipt.authorityFingerprint.algorithm ~= expectedFingerprint.algorithm
                or receipt.authorityFingerprint.length ~= expectedFingerprint.length
                or receipt.authorityFingerprint.hashA ~= expectedFingerprint.hashA
                or receipt.authorityFingerprint.hashB ~= expectedFingerprint.hashB then
                addError(
                    errors,
                    "receipt_authority_mismatch",
                    fingerprintPath,
                    "turnStartReceipt가 현재 권위 battleState와 일치하지 않습니다."
                )
            end
        end

        validateDraws(receipt.draws, state, path .. ".draws", errors)
        validateCharacterSelection(
            receipt.characterSelection,
            state,
            staticData,
            referencesValidated,
            receipt.events,
            path .. ".characterSelection",
            errors
        )
        local characterDrawAfter = type(receipt.draws) == "table"
            and type(receipt.draws.character) == "table"
            and receipt.draws.character.rngAfter
            or nil
        local selectionRngBefore = type(receipt.characterSelection) == "table"
            and receipt.characterSelection.rngBefore
            or nil
        if type(characterDrawAfter) == "table"
            and type(selectionRngBefore) == "table"
            and not rngEqual(characterDrawAfter, selectionRngBefore) then
            addError(
                errors,
                "receipt_rng_discontinuity",
                path .. ".characterSelection.rngBefore",
                "캐릭터 선택 RNG 시작점이 캐릭터 드로우 종료점과 다릅니다."
            )
        end

        local baseline = receipt.baseline
        if type(baseline) ~= "table" then
            addError(errors, "invalid_receipt_baseline", path .. ".baseline", "turnStartReceipt baseline이 객체가 아닙니다.")
        else
            checkAllowedKeys(baseline, {
                stealth = true,
                resistance = true,
                mood = true,
                moodTokens = true,
            }, path .. ".baseline", errors)
            if not isFinite(baseline.stealth) then
                addError(errors, "invalid_receipt_baseline", path .. ".baseline.stealth", "baseline 은폐가 유한한 숫자가 아닙니다.")
            end
            if not isFinite(baseline.resistance) then
                addError(errors, "invalid_receipt_baseline", path .. ".baseline.resistance", "baseline 저항이 유한한 숫자가 아닙니다.")
            end
            if not isAsciiId(baseline.mood) then
                addError(errors, "invalid_receipt_baseline", path .. ".baseline.mood", "baseline 무드 ID가 올바르지 않습니다.")
            elseif referencesValidated then
                local moods = type(staticData.registry) == "table" and staticData.registry.moods or nil
                if type(moods) ~= "table" or not moods[baseline.mood] then
                    addError(errors, "unknown_mood", path .. ".baseline.mood", "baseline 무드가 레지스트리에 없습니다.")
                end
            end
            if type(baseline.moodTokens) ~= "table" then
                addError(errors, "invalid_receipt_baseline", path .. ".baseline.moodTokens", "baseline 무드 토큰이 객체가 아닙니다.")
            elseif referencesValidated then
                local moods = staticData.registry.moods
                for moodId in pairs(moods) do
                    if not isSafeInteger(baseline.moodTokens[moodId], 0) then
                        addError(errors, "invalid_mood_token_count", path .. ".baseline.moodTokens." .. moodId, "무드 토큰 수는 0 이상의 안전한 정수여야 합니다.")
                    end
                end
                for moodId in pairs(baseline.moodTokens) do
                    if not moods[moodId] then
                        addError(errors, "unknown_mood", path .. ".baseline.moodTokens." .. tostring(moodId), "등록되지 않은 무드의 토큰입니다.")
                    end
                end
            end
        end

        local transient = receipt.transient
        if type(transient) ~= "table" then
            addError(errors, "invalid_receipt_transient", path .. ".transient", "turnStartReceipt transient가 객체가 아닙니다.")
        else
            checkAllowedKeys(transient, {
                skipRemaining = true,
                forcedMoodRequests = true,
            }, path .. ".transient", errors)

            local skipRemaining = transient.skipRemaining
            if type(skipRemaining) ~= "table" then
                addError(errors, "invalid_skip_state", path .. ".transient.skipRemaining", "skipRemaining이 객체가 아닙니다.")
            else
                checkAllowedKeys(skipRemaining, {
                    player = true,
                    character = true,
                }, path .. ".transient.skipRemaining", errors)
                for _, side in ipairs({ "player", "character" }) do
                    if skipRemaining[side] ~= true and skipRemaining[side] ~= false then
                        addError(errors, "invalid_skip_state", path .. ".transient.skipRemaining." .. side, "skipRemaining 값은 불리언이어야 합니다.")
                    end
                end
            end

            local forcedRequestCount = getArrayLength(
                transient.forcedMoodRequests,
                path .. ".transient.forcedMoodRequests",
                errors
            )
            if forcedRequestCount then
                for index = 1, forcedRequestCount do
                    local request = transient.forcedMoodRequests[index]
                    local requestPath = path .. ".transient.forcedMoodRequests[" .. index .. "]"
                    if type(request) ~= "table" then
                        addError(errors, "invalid_forced_mood_request", requestPath, "무드 강제 변경 요청이 객체가 아닙니다.")
                    else
                        checkAllowedKeys(request, {
                            mood = true,
                            cause = true,
                        }, requestPath, errors)
                        if not isAsciiId(request.mood) then
                            addError(errors, "invalid_forced_mood_request", requestPath .. ".mood", "강제 변경 무드 ID가 올바르지 않습니다.")
                        elseif referencesValidated and not staticData.registry.moods[request.mood] then
                            addError(errors, "unknown_mood", requestPath .. ".mood", "강제 변경 무드가 레지스트리에 없습니다.")
                        end
                        if not isAsciiId(request.cause) then
                            addError(errors, "invalid_forced_mood_cause", requestPath .. ".cause", "강제 변경 cause는 lower_snake_case여야 합니다.")
                        end
                    end
                end
            end
        end

        validateTurnStartEvents(receipt.events, receipt.turnId, path .. ".events", errors)
    end

    local function subwayStationsAdjacent(line, leftId, rightId)
        for _, routePath in ipairs(type(line) == "table" and line.paths or {}) do
            local stations = routePath.stations
            for index = 1, #stations - 1 do
                local left = stations[index].id
                local right = stations[index + 1].id
                if (left == leftId and right == rightId)
                    or (left == rightId and right == leftId) then
                    return true
                end
            end
            if routePath.circular == true and #stations > 1 then
                local first = stations[1].id
                local last = stations[#stations].id
                if (first == leftId and last == rightId)
                    or (first == rightId and last == leftId) then
                    return true
                end
            end
        end
        return false
    end

    local function subwayStationExists(line, stationId)
        for _, routePath in ipairs(type(line) == "table" and line.paths or {}) do
            for _, station in ipairs(routePath.stations or {}) do
                if station.id == stationId then
                    return true
                end
            end
        end
        return false
    end

    local function transitEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table"
            or left.algorithm ~= right.algorithm
            or left.lineId ~= right.lineId
            or type(left.stationIds) ~= "table"
            or type(right.stationIds) ~= "table"
            or #left.stationIds ~= #right.stationIds then
            return false
        end
        for index = 1, #left.stationIds do
            if left.stationIds[index] ~= right.stationIds[index] then
                return false
            end
        end
        return true
    end

    local function validateTransit(transit, turnLimit, staticData, errors)
        local path = "$.transit"
        if type(transit) ~= "table" then
            addError(errors, "invalid_transit", path, "전투 이동 구간이 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(transit, {
            algorithm = true,
            lineId = true,
            stationIds = true,
        }, path, errors)
        if transit.algorithm ~= "tokyo_subway_segment_v1" then
            addError(errors, "invalid_transit_algorithm", path .. ".algorithm", "지원하지 않는 지하철 여정 알고리즘입니다.")
        end
        if not isAsciiId(transit.lineId) then
            addError(errors, "invalid_transit_line_id", path .. ".lineId", "지하철 노선 ID가 올바르지 않습니다.")
        end
        local stationCount = getArrayLength(transit.stationIds, path .. ".stationIds", errors)
        if stationCount ~= nil then
            if isInteger(turnLimit, 1) and stationCount ~= turnLimit + 1 then
                addError(errors, "transit_length_mismatch", path .. ".stationIds", "이동 역 수는 제한 턴보다 하나 많아야 합니다.")
            end
            local seen = {}
            for index = 1, stationCount do
                local stationId = transit.stationIds[index]
                if not isAsciiId(stationId) then
                    addError(errors, "invalid_transit_station_id", path .. ".stationIds[" .. index .. "]", "이동 역 ID가 올바르지 않습니다.")
                elseif seen[stationId] then
                    addError(errors, "duplicate_transit_station", path .. ".stationIds[" .. index .. "]", "한 여정에서 같은 역을 두 번 지날 수 없습니다.")
                else
                    seen[stationId] = true
                end
            end
        end

        if type(staticData) == "table" and type(staticData.subwayLines) == "table" then
            local line = staticData.subwayLines[transit.lineId]
            if type(line) ~= "table" then
                addError(errors, "unknown_transit_line", path .. ".lineId", "정적 DB에서 지하철 노선을 찾을 수 없습니다.")
            elseif stationCount ~= nil then
                for index = 1, stationCount do
                    local stationId = transit.stationIds[index]
                    if isAsciiId(stationId) and not subwayStationExists(line, stationId) then
                        addError(errors, "unknown_transit_station", path .. ".stationIds[" .. index .. "]", "선택 노선에서 이동 역을 찾을 수 없습니다.")
                    end
                    if index > 1 then
                        local previousId = transit.stationIds[index - 1]
                        if isAsciiId(previousId)
                            and isAsciiId(stationId)
                            and not subwayStationsAdjacent(line, previousId, stationId) then
                            addError(errors, "non_adjacent_transit_station", path .. ".stationIds[" .. index .. "]", "이동 구간에 서로 인접하지 않은 역이 있습니다.")
                        end
                    end
                end
            end
        end
    end

    local function validateBattleState(state, staticData)
        local errors = {}
        local staticDataProvided = staticData ~= nil
        staticData = normalizeStaticData(staticData)
        local referencesValidated = hasCompleteStaticData(staticData)

        if staticDataProvided and not referencesValidated then
            addError(errors, "invalid_static_data", "$", "전달한 정적 데이터가 전체 참조 검증에 필요한 컬렉션을 갖추지 못했습니다.")
        end
        if not referencesValidated then
            staticData = nil
        end

        if type(state) ~= "table" then
            addError(errors, "invalid_state", "$", "battleState가 테이블이 아닙니다.")
            return result(errors)
        end

        validateJsonSafe(state, "$", errors)
        if #errors > 0 then
            local report = result(errors)
            report.referencesValidated = referencesValidated
            return report
        end
        checkAllowedKeys(state, {
            schemaVersion = true,
            kind = true,
            battleId = true,
            status = true,
            turnNumber = true,
            turnLimit = true,
            environmentId = true,
            transit = true,
            lastCommittedTurnId = true,
            rng = true,
            player = true,
            character = true,
            cardInstances = true,
            selection = true,
            characterIntent = true,
            turnStartReceipt = true,
        }, "$", errors)

        if state.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", "$.schemaVersion", "지원하지 않는 battleState 스키마 버전입니다.")
        end
        if state.kind ~= "battleState" then
            addError(errors, "invalid_kind", "$.kind", "kind는 battleState여야 합니다.")
        end
        if not isRuntimeId(state.battleId) then
            addError(errors, "invalid_battle_id", "$.battleId", "battleId가 올바르지 않습니다.")
        end
        if not VALID_STATUS[state.status] then
            addError(errors, "invalid_status", "$.status", "알 수 없는 전투 상태입니다.")
        end
        if not isInteger(state.turnNumber, 1) then
            addError(errors, "invalid_turn_number", "$.turnNumber", "현재 턴은 1 이상의 정수여야 합니다.")
        end
        if not isInteger(state.turnLimit, 7) or state.turnLimit > 12 then
            addError(errors, "invalid_turn_limit", "$.turnLimit", "제한 턴은 7 이상 12 이하의 정수여야 합니다.")
        elseif isInteger(state.turnNumber, 1) and state.turnNumber > state.turnLimit then
            addError(errors, "turn_over_limit", "$.turnNumber", "현재 턴이 제한 턴을 초과했습니다.")
        end
        if not isAsciiId(state.environmentId) then
            addError(errors, "invalid_environment_id", "$.environmentId", "환경 ID가 올바르지 않습니다.")
        end
        validateTransit(state.transit, state.turnLimit, staticData, errors)
        if state.lastCommittedTurnId ~= nil and not isRuntimeId(state.lastCommittedTurnId) then
            addError(errors, "invalid_turn_id", "$.lastCommittedTurnId", "마지막 확정 턴 ID가 올바르지 않습니다.")
        end

        if type(state.rng) ~= "table" then
            addError(errors, "invalid_rng", "$.rng", "rng가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.rng, { seed = true, cursor = true }, "$.rng", errors)
            if not isSafeInteger(state.rng.seed, 0) then
                addError(errors, "invalid_rng_seed", "$.rng.seed", "난수 시드는 0 이상이고 안전한 숫자 범위 안의 정수여야 합니다.")
            end
            if not isSafeInteger(state.rng.cursor, 0) then
                addError(errors, "invalid_rng_cursor", "$.rng.cursor", "난수 커서는 0 이상이고 안전한 숫자 범위 안의 정수여야 합니다.")
            end
        end

        if type(state.player) ~= "table" then
            addError(errors, "invalid_player", "$.player", "player가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.player, {
                stealth = true,
                baseDrawCount = true,
                maxHandSize = true,
                perkIds = true,
                planCapacity = true,
                planSlots = true,
            }, "$.player", errors)
            if not isFinite(state.player.stealth) then
                addError(errors, "invalid_stealth", "$.player.stealth", "은폐는 유한한 숫자여야 합니다.")
            end
            if not isInteger(state.player.baseDrawCount, 1) then
                addError(errors, "invalid_base_draw_count", "$.player.baseDrawCount", "기본 드로우 수는 1 이상의 정수여야 합니다.")
            end
            if not isInteger(state.player.maxHandSize, 1) then
                addError(errors, "invalid_hand_size", "$.player.maxHandSize", "최대 손패는 1 이상의 정수여야 합니다.")
            end
            if isInteger(state.player.baseDrawCount, 1)
                and isInteger(state.player.maxHandSize, 1)
                and state.player.baseDrawCount > state.player.maxHandSize then
                addError(errors, "draw_exceeds_hand_limit", "$.player.baseDrawCount", "기본 드로우 수는 최대 손패보다 클 수 없습니다.")
            end
            validateIdArray(state.player.perkIds, "$.player.perkIds", errors, isAsciiId)
        end

        if type(state.character) ~= "table" then
            addError(errors, "invalid_character", "$.character", "character가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.character, {
                characterId = true,
                resistance = true,
                mood = true,
                moodTokens = true,
                traitIds = true,
                baseDrawCount = true,
                maxHandSize = true,
                planCapacity = true,
                planSlots = true,
            }, "$.character", errors)
            if not isAsciiId(state.character.characterId) then
                addError(errors, "invalid_character_id", "$.character.characterId", "캐릭터 ID가 올바르지 않습니다.")
            end
            if not isFinite(state.character.resistance) then
                addError(errors, "invalid_resistance", "$.character.resistance", "저항은 유한한 숫자여야 합니다.")
            end
            if not isAsciiId(state.character.mood) then
                addError(errors, "invalid_mood", "$.character.mood", "무드 ID가 올바르지 않습니다.")
            end
            if state.character.moodTokens ~= nil then
                if type(state.character.moodTokens) ~= "table" then
                    addError(errors, "invalid_mood_tokens", "$.character.moodTokens", "무드 토큰이 객체가 아닙니다.")
                elseif referencesValidated then
                    local moods = staticData.registry.moods
                    for moodId in pairs(moods) do
                        if not isSafeInteger(state.character.moodTokens[moodId], 0) then
                            addError(errors, "invalid_mood_token_count", "$.character.moodTokens." .. moodId, "무드 토큰 수는 0 이상의 안전한 정수여야 합니다.")
                        end
                    end
                    for moodId in pairs(state.character.moodTokens) do
                        if not moods[moodId] then
                            addError(errors, "unknown_mood", "$.character.moodTokens." .. tostring(moodId), "등록되지 않은 무드의 토큰입니다.")
                        end
                    end
                end
            end
            if not isInteger(state.character.baseDrawCount, 1) then
                addError(errors, "invalid_base_draw_count", "$.character.baseDrawCount", "기본 드로우 수는 1 이상의 정수여야 합니다.")
            end
            if not isInteger(state.character.maxHandSize, 1) then
                addError(errors, "invalid_hand_size", "$.character.maxHandSize", "최대 손패는 1 이상의 정수여야 합니다.")
            end
            if isInteger(state.character.baseDrawCount, 1)
                and isInteger(state.character.maxHandSize, 1)
                and state.character.baseDrawCount > state.character.maxHandSize then
                addError(errors, "draw_exceeds_hand_limit", "$.character.baseDrawCount", "기본 드로우 수는 최대 손패보다 클 수 없습니다.")
            end
            validateIdArray(state.character.traitIds, "$.character.traitIds", errors, isAsciiId)
        end

        local instances = {}
        local positions = {}
        local instanceCount = getArrayLength(state.cardInstances, "$.cardInstances", errors)
        if instanceCount then
            for index = 1, instanceCount do
                local item = state.cardInstances[index]
                local path = "$.cardInstances[" .. index .. "]"
                if type(item) ~= "table" then
                    addError(errors, "invalid_card_instance", path, "카드 인스턴스가 테이블이 아닙니다.")
                else
                    checkAllowedKeys(item, {
                        instanceId = true,
                        cardId = true,
                        owner = true,
                        zone = true,
                        position = true,
                        temporaryModifiers = true,
                    }, path, errors)
                    if not isRuntimeId(item.instanceId) then
                        addError(errors, "invalid_instance_id", path .. ".instanceId", "카드 인스턴스 ID가 올바르지 않습니다.")
                    elseif instances[item.instanceId] then
                        addError(errors, "duplicate_instance_id", path .. ".instanceId", "카드 인스턴스 ID가 중복되었습니다.")
                    else
                        instances[item.instanceId] = item
                    end
                    if not isAsciiId(item.cardId) then
                        addError(errors, "invalid_card_id", path .. ".cardId", "카드 ID가 올바르지 않습니다.")
                    end
                    if not VALID_OWNER[item.owner] then
                        addError(errors, "invalid_owner", path .. ".owner", "카드 소유자가 올바르지 않습니다.")
                    end
                    if not VALID_ZONE[item.zone] then
                        addError(errors, "invalid_zone", path .. ".zone", "카드 영역이 올바르지 않습니다.")
                    end
                    if not isInteger(item.position, 1) then
                        addError(errors, "invalid_position", path .. ".position", "카드 위치는 1 이상의 정수여야 합니다.")
                    elseif VALID_OWNER[item.owner] and VALID_ZONE[item.zone] then
                        local group = item.owner .. ":" .. item.zone
                        positions[group] = positions[group] or {}
                        positions[group][item.position] = (positions[group][item.position] or 0) + 1
                    end
                    if item.temporaryModifiers ~= nil then
                        local modifierCount = getArrayLength(item.temporaryModifiers, path .. ".temporaryModifiers", errors)
                        if modifierCount and modifierCount > 0 then
                            addError(
                                errors,
                                "temporary_modifier_schema_pending",
                                path .. ".temporaryModifiers",
                                "임시 카드 보정 스키마가 확정되기 전에는 빈 배열만 허용합니다."
                            )
                        end
                    end

                    local cards = type(staticData) == "table" and staticData.cards or nil
                    local card = type(cards) == "table" and cards[item.cardId] or nil
                    if type(cards) == "table" and not card then
                        addError(errors, "unknown_card", path .. ".cardId", "정적 DB에서 카드를 찾을 수 없습니다.")
                    elseif card and card.owner ~= item.owner then
                        addError(errors, "card_owner_mismatch", path .. ".owner", "정적 카드와 인스턴스의 소유자가 다릅니다.")
                    end
                end
            end
        end

        for group, groupPositions in pairs(positions) do
            local count = 0
            local maximum = 0
            for position, occurrence in pairs(groupPositions) do
                count = count + occurrence
                if position > maximum then
                    maximum = position
                end
                if occurrence > 1 then
                    addError(errors, "duplicate_position", "$.cardInstances", group .. " 영역의 position이 중복되었습니다: " .. position)
                end
            end
            if count ~= maximum then
                addError(errors, "non_contiguous_positions", "$.cardInstances", group .. " 영역의 position이 1부터 이어지지 않습니다.")
            end
            if group == "player:hand"
                and type(state.player) == "table"
                and isInteger(state.player.maxHandSize, 1)
                and count > state.player.maxHandSize then
                addError(errors, "hand_limit_exceeded", "$.cardInstances", "플레이어 손패가 최대 손패를 초과했습니다.")
            elseif group == "character:hand"
                and type(state.character) == "table"
                and isInteger(state.character.maxHandSize, 1)
                and count > state.character.maxHandSize then
                addError(errors, "hand_limit_exceeded", "$.cardInstances", "캐릭터 손패가 최대 손패를 초과했습니다.")
            end
        end

        if type(state.player) == "table" then
            validatePlanSlots(
                state.player.planSlots,
                state.player.planCapacity,
                "player",
                "$.player.planSlots",
                errors,
                instances,
                staticData,
                state.turnNumber
            )
        end
        if type(state.character) == "table" then
            validatePlanSlots(
                state.character.planSlots,
                state.character.planCapacity,
                "character",
                "$.character.planSlots",
                errors,
                instances,
                staticData,
                state.turnNumber
            )
        end

        for instanceId, instance in pairs(instances) do
            if instance.zone == "plan" and VALID_OWNER[instance.owner] then
                local ownerState = instance.owner == "player" and state.player or state.character
                local slots = type(ownerState) == "table" and ownerState.planSlots or nil
                local slot = type(slots) == "table" and slots[instance.position] or nil
                if type(slot) ~= "table"
                    or slot.occupied ~= true
                    or slot.cardInstanceId ~= instanceId then
                    addError(
                        errors,
                        "orphan_plan_instance",
                        "$.cardInstances",
                        "plan 영역의 카드 인스턴스는 같은 진영의 점유 슬롯과 정확히 연결되어야 합니다: " .. instanceId
                    )
                end
            end
        end

        if type(state.selection) ~= "table" then
            addError(errors, "invalid_selection", "$.selection", "selection이 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.selection, { playerCardInstanceIds = true }, "$.selection", errors)
            validateIdArray(state.selection.playerCardInstanceIds, "$.selection.playerCardInstanceIds", errors, isRuntimeId)
            if type(state.selection.playerCardInstanceIds) == "table" then
                local mainActionCount = 0
                local mainActionIndex = nil
                for index, instanceId in ipairs(state.selection.playerCardInstanceIds) do
                    local instance = instances[instanceId]
                    if not instance or instance.owner ~= "player" or instance.zone ~= "hand" then
                        addError(errors, "invalid_selected_card", "$.selection.playerCardInstanceIds[" .. index .. "]", "선택 카드는 플레이어 손패에 있어야 합니다.")
                    elseif referencesValidated then
                        local card = staticData.cards[instance.cardId]
                        if card and not cardHasMechanism(card, "chain") then
                            mainActionCount = mainActionCount + 1
                            mainActionIndex = index
                        end
                    end
                end
                if mainActionCount > 1 then
                    addError(errors, "multiple_player_main_actions", "$.selection.playerCardInstanceIds", "플레이어 선택에는 주 행동을 둘 이상 넣을 수 없습니다.")
                elseif mainActionIndex and mainActionIndex ~= #state.selection.playerCardInstanceIds then
                    addError(errors, "player_main_action_not_last", "$.selection.playerCardInstanceIds", "연계 카드는 주 행동보다 앞에 있어야 합니다.")
                end
            end
        end

        if type(state.characterIntent) ~= "table" then
            addError(errors, "invalid_character_intent", "$.characterIntent", "characterIntent가 테이블이 아닙니다.")
        else
            checkAllowedKeys(state.characterIntent, {
                cardInstanceIds = true,
                publicActionTag = true,
            }, "$.characterIntent", errors)
            validateIdArray(state.characterIntent.cardInstanceIds, "$.characterIntent.cardInstanceIds", errors, isRuntimeId)

            local intentCount = type(state.characterIntent.cardInstanceIds) == "table"
                and #state.characterIntent.cardInstanceIds
                or 0
            if intentCount == 0 then
                if state.characterIntent.publicActionTag ~= nil then
                    addError(errors, "orphan_public_action", "$.characterIntent.publicActionTag", "선택 카드가 없으면 공개 행동 태그도 없어야 합니다.")
                end
            elseif not isAsciiId(state.characterIntent.publicActionTag) then
                addError(errors, "missing_public_action", "$.characterIntent.publicActionTag", "캐릭터 선택의 공개 행동 태그가 필요합니다.")
            end

            local mainCards = {}
            local mainCardIndex = nil
            if type(state.characterIntent.cardInstanceIds) == "table" then
                for index, instanceId in ipairs(state.characterIntent.cardInstanceIds) do
                    local instance = instances[instanceId]
                    if not instance or instance.owner ~= "character" or instance.zone ~= "hand" then
                        addError(errors, "invalid_intent_card", "$.characterIntent.cardInstanceIds[" .. index .. "]", "캐릭터 선택 카드는 캐릭터 손패에 있어야 합니다.")
                    else
                        local cards = type(staticData) == "table" and staticData.cards or nil
                        local card = type(cards) == "table" and cards[instance.cardId] or nil
                        if card and not cardHasMechanism(card, "chain") then
                            table.insert(mainCards, card)
                            mainCardIndex = index
                        end
                    end
                end
            end

            if type(staticData) == "table" and intentCount > 0 then
                if #mainCards ~= 1 then
                    addError(errors, "invalid_character_main_action", "$.characterIntent.cardInstanceIds", "캐릭터 선택에는 주 행동 카드가 정확히 하나 있어야 합니다.")
                elseif mainCardIndex ~= intentCount then
                    addError(errors, "character_main_action_not_last", "$.characterIntent.cardInstanceIds", "캐릭터 연계 카드는 주 행동보다 앞에 있어야 합니다.")
                elseif mainCards[1].actionTag ~= state.characterIntent.publicActionTag then
                    addError(errors, "public_action_mismatch", "$.characterIntent.publicActionTag", "공개 행동 태그가 실제 주 행동과 다릅니다.")
                end
            end

            local registry = type(staticData) == "table" and staticData.registry or nil
            local actionTags = type(registry) == "table" and registry.actionTags or nil
            local publicAction = type(actionTags) == "table" and actionTags[state.characterIntent.publicActionTag] or nil
            if state.characterIntent.publicActionTag ~= nil and type(actionTags) == "table" then
                if not publicAction then
                    addError(errors, "unknown_public_action", "$.characterIntent.publicActionTag", "등록되지 않은 행동 태그입니다.")
                elseif publicAction.owner ~= "character" then
                    addError(errors, "public_action_owner_mismatch", "$.characterIntent.publicActionTag", "캐릭터 행동 태그가 아닙니다.")
                end
            end
        end

        if type(staticData) == "table" then
            if type(staticData.environments) == "table" and not staticData.environments[state.environmentId] then
                addError(errors, "unknown_environment", "$.environmentId", "정적 DB에서 환경을 찾을 수 없습니다.")
            end
            if type(state.character) == "table" then
                if type(staticData.characters) == "table" and not staticData.characters[state.character.characterId] then
                    addError(errors, "unknown_character", "$.character.characterId", "정적 DB에서 캐릭터를 찾을 수 없습니다.")
                end
                if type(staticData.registry) == "table"
                    and type(staticData.registry.moods) == "table"
                    and not staticData.registry.moods[state.character.mood] then
                    addError(errors, "unknown_mood", "$.character.mood", "등록되지 않은 무드입니다.")
                end
                if type(staticData.traits) == "table" and type(state.character.traitIds) == "table" then
                    for index, traitId in ipairs(state.character.traitIds) do
                        if not staticData.traits[traitId] then
                            addError(errors, "unknown_trait", "$.character.traitIds[" .. index .. "]", "정적 DB에서 특징을 찾을 수 없습니다.")
                        end
                    end
                end
            end
        end

        if state.turnStartReceipt ~= nil then
            validateTurnStartReceipt(state.turnStartReceipt, state, staticData, referencesValidated, errors)
        end

        if type(state.player) == "table" and type(state.character) == "table"
            and isFinite(state.player.stealth) and isFinite(state.character.resistance) then
            if state.character.resistance <= 0 and state.status ~= "victory" then
                addError(errors, "victory_priority", "$.status", "저항이 0 이하이면 동시 은폐 소진보다 승리를 우선해야 합니다.")
            elseif state.character.resistance > 0 and state.player.stealth <= 0 and state.status ~= "defeat" then
                addError(errors, "defeat_required", "$.status", "은폐가 0 이하이면 패배 상태여야 합니다.")
            elseif state.status == "active" and (state.character.resistance <= 0 or state.player.stealth <= 0) then
                addError(errors, "active_outcome_conflict", "$.status", "종료 수치에서 active 상태를 유지할 수 없습니다.")
            elseif state.status == "victory" and state.character.resistance > 0 then
                addError(errors, "invalid_victory", "$.status", "저항이 남아 있으면 승리 상태일 수 없습니다.")
            elseif state.status == "defeat"
                and state.player.stealth > 0
                and isInteger(state.turnNumber, 1)
                and isInteger(state.turnLimit, 1)
                and state.turnNumber < state.turnLimit then
                addError(errors, "invalid_defeat", "$.status", "은폐가 남고 제한 턴 전이면 패배 상태일 수 없습니다.")
            end
        end

        local report = result(errors, state)
        report.referencesValidated = referencesValidated
        return report
    end

    local function fingerprintBattleState(state, staticData)
        local validation = validateBattleState(state, staticData)
        if not validation.ok then
            return validation
        end
        if validation.referencesValidated ~= true then
            local errors = {}
            addError(
                errors,
                "static_references_not_validated",
                "$.staticData",
                "battleState fingerprint에는 전체 정적 데이터 참조 검증이 필요합니다."
            )
            local report = result(errors)
            report.referencesValidated = false
            return report
        end

        local authorityFingerprint, fingerprintError = fingerprintAuthorityState(state)
        if fingerprintError then
            local errors = {}
            addError(errors, fingerprintError.code, fingerprintError.path, fingerprintError.message)
            local report = result(errors)
            report.referencesValidated = true
            return report
        end
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            referencesValidated = true,
            fingerprint = authorityFingerprint,
        }
    end

    local function sealTurnStartReceipt(state, staticData)
        local errors = {}
        if type(state) ~= "table" or type(state.turnStartReceipt) ~= "table" then
            addError(errors, "missing_unsealed_turn_receipt", "$.turnStartReceipt", "봉인할 turnStartReceipt가 없습니다.")
            return result(errors)
        end
        if state.turnStartReceipt.authorityFingerprint ~= nil then
            addError(errors, "turn_receipt_already_sealed", "$.turnStartReceipt.authorityFingerprint", "이미 authorityFingerprint가 있는 영수증은 다시 봉인할 수 없습니다.")
            return result(errors)
        end

        local authorityFingerprint, fingerprintError = fingerprintAuthorityState(state)
        if fingerprintError then
            addError(errors, fingerprintError.code, fingerprintError.path, fingerprintError.message)
            return result(errors)
        end

        local function cloneValue(value, path, active)
            local valueType = type(value)
            if valueType == "nil" or valueType == "string" or valueType == "boolean" then
                return value, nil
            end
            if valueType == "number" then
                if not isFinite(value) then
                    return nil, { code = "non_finite_number", path = path, message = "NaN과 무한대는 봉인 상태에 사용할 수 없습니다." }
                end
                return value, nil
            end
            if valueType ~= "table" or getmetatable(value) ~= nil then
                return nil, { code = "unsupported_type", path = path, message = "봉인 상태에 사용할 수 없는 값입니다." }
            end
            active = active or {}
            if active[value] then
                return nil, { code = "circular_reference", path = path, message = "순환 참조가 있는 상태는 봉인할 수 없습니다." }
            end
            active[value] = true
            local copy = {}
            for key, item in pairs(value) do
                local itemCopy, itemError = cloneValue(item, objectPath(path, key), active)
                if itemError then
                    active[value] = nil
                    return nil, itemError
                end
                copy[key] = itemCopy
            end
            active[value] = nil
            return copy, nil
        end

        local sealedState, cloneError = cloneValue(state, "$", {})
        if cloneError then
            addError(errors, cloneError.code, cloneError.path, cloneError.message)
            return result(errors)
        end
        sealedState.turnStartReceipt.authorityFingerprint = authorityFingerprint

        local reportFingerprint, reportFingerprintError = cloneValue(
            authorityFingerprint,
            "$.fingerprint",
            {}
        )
        if reportFingerprintError then
            addError(
                errors,
                reportFingerprintError.code,
                reportFingerprintError.path,
                reportFingerprintError.message
            )
            return result(errors)
        end

        local validation = validateBattleState(sealedState, staticData)
        if not validation.ok then
            return validation
        end
        if validation.referencesValidated ~= true then
            addError(errors, "static_references_not_validated", "$.staticData", "turnStartReceipt 봉인에는 전체 정적 데이터 참조 검증이 필요합니다.")
            local report = result(errors)
            report.referencesValidated = false
            return report
        end
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            referencesValidated = true,
            state = sealedState,
            fingerprint = reportFingerprint,
        }
    end

    local function validateEventEnvelope(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_event_envelope", path, "사건 묶음이 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, { schemaVersion = true, events = true }, path, errors)
        if value.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", path .. ".schemaVersion", "지원하지 않는 사건 묶음 스키마입니다.")
        end
        getArrayLength(value.events, path .. ".events", errors)
    end

    local function arraysEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
            return false
        end
        for index = 1, #left do
            if left[index] ~= right[index] then
                return false
            end
        end
        return true
    end

    local function fingerprintsEqual(left, right)
        return type(left) == "table"
            and type(right) == "table"
            and left.algorithm == right.algorithm
            and left.length == right.length
            and left.hashA == right.hashA
            and left.hashB == right.hashB
    end

    local function validateDraftFingerprint(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_projection_fingerprint", path, "projection 원본 fingerprint가 객체가 아닙니다.")
            return false
        end
        checkAllowedKeys(value, {
            algorithm = true,
            length = true,
            hashA = true,
            hashB = true,
        }, path, errors)
        local valid = true
        if value.algorithm ~= DRAFT_FINGERPRINT_ALGORITHM then
            addError(errors, "invalid_projection_fingerprint_algorithm", path .. ".algorithm", "지원하지 않는 projection 원본 fingerprint 알고리즘입니다.")
            valid = false
        end
        for _, field in ipairs({ "length", "hashA", "hashB" }) do
            if not isSafeInteger(value[field], 0) then
                addError(errors, "invalid_projection_fingerprint", path .. "." .. field, "projection 원본 fingerprint 수치는 0 이상의 안전한 정수여야 합니다.")
                valid = false
            end
        end
        return valid
    end

    local function validatePendingIntegrity(pending, errors)
        local path = "$.integrity"
        local value = pending.integrity
        if type(value) ~= "table" then
            addError(errors, "missing_pending_integrity", path, "pendingTurn에는 전체 저장값 무결성 영수증이 필요합니다.")
            return
        end
        checkAllowedKeys(value, {
            algorithm = true,
            length = true,
            hashA = true,
            hashB = true,
        }, path, errors)

        local valid = true
        if value.algorithm ~= PENDING_INTEGRITY_ALGORITHM then
            addError(errors, "invalid_pending_integrity_algorithm", path .. ".algorithm", "지원하지 않는 pendingTurn 무결성 알고리즘입니다.")
            valid = false
        end
        for _, field in ipairs({ "length", "hashA", "hashB" }) do
            if not isSafeInteger(value[field], 0) then
                addError(errors, "invalid_pending_integrity", path .. "." .. field, "pendingTurn 무결성 수치는 0 이상의 안전한 정수여야 합니다.")
                valid = false
            end
        end
        if not valid then
            return
        end

        local expected, fingerprintError = fingerprintPendingTurn(pending)
        if fingerprintError then
            addError(errors, fingerprintError.code, fingerprintError.path, fingerprintError.message)
        elseif not fingerprintsEqual(value, expected) then
            addError(errors, "pending_integrity_mismatch", path, "pendingTurn 저장값이 생성 뒤 변경되었습니다.")
        end
    end

    local function validateProjectionReceiptShape(receipt, path, errors)
        if type(receipt) ~= "table" then
            addError(errors, "invalid_projection_receipt", path, "projectionReceipt가 객체가 아닙니다.")
            return
        end
        checkAllowedKeys(receipt, {
            schemaVersion = true,
            kind = true,
            mode = true,
            selectedCardInstanceIds = true,
            source = true,
            projectedRng = true,
        }, path, errors)
        if receipt.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_projection_receipt_schema", path .. ".schemaVersion", "지원하지 않는 projectionReceipt 스키마입니다.")
        end
        if receipt.kind ~= "turnDraftProjectionReceipt" then
            addError(errors, "invalid_projection_receipt_kind", path .. ".kind", "kind는 turnDraftProjectionReceipt여야 합니다.")
        end
        if receipt.mode ~= "pass" and receipt.mode ~= "chain_pass" and receipt.mode ~= "action" then
            addError(errors, "invalid_projection_mode", path .. ".mode", "알 수 없는 projection mode입니다.")
        end
        validateIdArray(receipt.selectedCardInstanceIds, path .. ".selectedCardInstanceIds", errors, isRuntimeId)
        local selectedCount = type(receipt.selectedCardInstanceIds) == "table" and #receipt.selectedCardInstanceIds or 0
        if receipt.mode == "pass" and selectedCount ~= 0 then
            addError(errors, "projection_pass_has_selection", path .. ".selectedCardInstanceIds", "pass projection에는 등록 카드가 없어야 합니다.")
        elseif (receipt.mode == "chain_pass" or receipt.mode == "action") and selectedCount == 0 then
            addError(errors, "projection_mode_missing_selection", path .. ".selectedCardInstanceIds", "카드가 있는 projection mode에는 등록 카드가 필요합니다.")
        end

        local source = receipt.source
        if type(source) ~= "table" then
            addError(errors, "invalid_projection_source", path .. ".source", "projection 원본 표식이 객체가 아닙니다.")
        else
            checkAllowedKeys(source, {
                battleId = true,
                status = true,
                turnNumber = true,
                lastCommittedTurnId = true,
                rng = true,
                fingerprint = true,
            }, path .. ".source", errors)
            if not isRuntimeId(source.battleId) then
                addError(errors, "invalid_battle_id", path .. ".source.battleId", "projection 원본 battleId가 올바르지 않습니다.")
            end
            if source.status ~= "active" then
                addError(errors, "invalid_projection_source_status", path .. ".source.status", "projection 원본 상태는 active여야 합니다.")
            end
            if not isInteger(source.turnNumber, 1) then
                addError(errors, "invalid_turn_number", path .. ".source.turnNumber", "projection 원본 턴 번호가 올바르지 않습니다.")
            end
            if source.lastCommittedTurnId ~= nil and not isRuntimeId(source.lastCommittedTurnId) then
                addError(errors, "invalid_turn_id", path .. ".source.lastCommittedTurnId", "projection 원본 마지막 확정 턴 ID가 올바르지 않습니다.")
            end
            validateReceiptRng(source.rng, path .. ".source.rng", errors)
            validateDraftFingerprint(source.fingerprint, path .. ".source.fingerprint", errors)
        end
        validateReceiptRng(receipt.projectedRng, path .. ".projectedRng", errors)
        if type(source) == "table" and type(source.rng) == "table" and type(receipt.projectedRng) == "table" then
            if receipt.projectedRng.seed ~= source.rng.seed then
                addError(errors, "projection_rng_seed_changed", path .. ".projectedRng.seed", "projection 중 RNG seed가 바뀔 수 없습니다.")
            end
            if isInteger(source.rng.cursor, 0)
                and isInteger(receipt.projectedRng.cursor, 0)
                and receipt.projectedRng.cursor < source.rng.cursor then
                addError(errors, "projection_rng_reversed", path .. ".projectedRng.cursor", "projection RNG cursor가 이전으로 돌아갈 수 없습니다.")
            end
        end
    end

    local function validatePendingTurn(pending, staticData)
        local errors = {}
        local staticDataProvided = staticData ~= nil
        staticData = normalizeStaticData(staticData)
        local referencesValidated = hasCompleteStaticData(staticData)

        if staticDataProvided and not referencesValidated then
            addError(errors, "invalid_static_data", "$", "전달한 정적 데이터가 전체 참조 검증에 필요한 컬렉션을 갖추지 못했습니다.")
        end
        if not referencesValidated then
            staticData = nil
        end

        if type(pending) ~= "table" then
            addError(errors, "invalid_pending_turn", "$", "pendingTurn이 테이블이 아닙니다.")
            return result(errors)
        end

        validateJsonSafe(pending, "$", errors)
        if #errors > 0 then
            local report = result(errors)
            report.referencesValidated = referencesValidated
            return report
        end
        checkAllowedKeys(pending, {
            schemaVersion = true,
            kind = true,
            battleId = true,
            turnId = true,
            status = true,
            beforeState = true,
            projectionReceipt = true,
            selectedCards = true,
            turnResult = true,
            afterState = true,
            integrity = true,
        }, "$", errors)

        if pending.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", "$.schemaVersion", "지원하지 않는 pendingTurn 스키마 버전입니다.")
        end
        if pending.kind ~= "pendingTurn" then
            addError(errors, "invalid_kind", "$.kind", "kind는 pendingTurn이어야 합니다.")
        end
        if not isRuntimeId(pending.battleId) then
            addError(errors, "invalid_battle_id", "$.battleId", "battleId가 올바르지 않습니다.")
        end
        if not isRuntimeId(pending.turnId) then
            addError(errors, "invalid_turn_id", "$.turnId", "turnId가 올바르지 않습니다.")
        end
        if pending.status ~= "awaitingOutput" then
            addError(errors, "invalid_pending_status", "$.status", "대기 트랜잭션 상태는 awaitingOutput이어야 합니다.")
        end

        local beforeResult = validateBattleState(pending.beforeState, staticData)
        if not beforeResult.ok then
            appendNestedErrors(errors, "$.beforeState", beforeResult)
        end
        local afterResult = validateBattleState(pending.afterState, staticData)
        if not afterResult.ok then
            appendNestedErrors(errors, "$.afterState", afterResult)
        end

        validateProjectionReceiptShape(pending.projectionReceipt, "$.projectionReceipt", errors)

        if type(pending.selectedCards) ~= "table" then
            addError(errors, "invalid_selected_cards", "$.selectedCards", "selectedCards가 테이블이 아닙니다.")
        else
            checkAllowedKeys(pending.selectedCards, { player = true, character = true }, "$.selectedCards", errors)
            validateIdArray(pending.selectedCards.player, "$.selectedCards.player", errors, isRuntimeId)
            validateIdArray(pending.selectedCards.character, "$.selectedCards.character", errors, isRuntimeId)
        end

        if type(pending.turnResult) ~= "table" then
            addError(errors, "invalid_turn_result", "$.turnResult", "turnResult가 테이블이 아닙니다.")
        else
            checkAllowedKeys(pending.turnResult, {
                events = true,
                publicResult = true,
                llmEvent = true,
            }, "$.turnResult", errors)

            getArrayLength(pending.turnResult.events, "$.turnResult.events", errors)
            validateEventEnvelope(pending.turnResult.publicResult, "$.turnResult.publicResult", errors)
            validateEventEnvelope(pending.turnResult.llmEvent, "$.turnResult.llmEvent", errors)
        end

        if type(pending.beforeState) == "table" and type(pending.afterState) == "table" then
            if pending.beforeState.battleId ~= pending.battleId then
                addError(errors, "before_battle_mismatch", "$.beforeState.battleId", "beforeState의 전투 ID가 다릅니다.")
            end
            if pending.afterState.battleId ~= pending.battleId then
                addError(errors, "after_battle_mismatch", "$.afterState.battleId", "afterState의 전투 ID가 다릅니다.")
            end
            if pending.beforeState.lastCommittedTurnId == pending.turnId then
                addError(errors, "turn_already_committed", "$.beforeState.lastCommittedTurnId", "beforeState에 이미 같은 턴이 반영되었습니다.")
            end
            if pending.afterState.lastCommittedTurnId ~= pending.turnId then
                addError(errors, "after_turn_not_marked", "$.afterState.lastCommittedTurnId", "afterState에 대기 턴 ID가 기록되어야 합니다.")
            end
            if pending.beforeState.status ~= "active" then
                addError(errors, "before_state_not_active", "$.beforeState.status", "종료된 전투에서 새 대기 턴을 만들 수 없습니다.")
            end
            local beforeSelection = type(pending.beforeState.selection) == "table"
                and pending.beforeState.selection.playerCardInstanceIds
                or nil
            if type(beforeSelection) ~= "table" or #beforeSelection ~= 0 then
                addError(errors, "pending_authority_selection_not_empty", "$.beforeState.selection.playerCardInstanceIds", "pendingTurn의 권위 beforeState에는 플레이어 드래프트 선택을 저장할 수 없습니다.")
            end
            local startReceipt = pending.beforeState.turnStartReceipt
            if type(startReceipt) ~= "table" then
                addError(errors, "pending_missing_turn_start_receipt", "$.beforeState.turnStartReceipt", "pendingTurn beforeState에는 봉인된 turnStartReceipt가 필요합니다.")
            elseif startReceipt.turnId ~= pending.turnId then
                addError(errors, "pending_turn_id_mismatch", "$.turnId", "pendingTurn turnId가 beforeState.turnStartReceipt와 다릅니다.")
            end
            if pending.afterState.turnStartReceipt ~= nil then
                addError(errors, "pending_after_turn_receipt_present", "$.afterState.turnStartReceipt", "해결된 afterState에는 turnStartReceipt를 남길 수 없습니다.")
            end
            local afterSelection = type(pending.afterState.selection) == "table"
                and pending.afterState.selection.playerCardInstanceIds
                or nil
            if type(afterSelection) ~= "table" or #afterSelection ~= 0 then
                addError(errors, "pending_after_selection_not_empty", "$.afterState.selection.playerCardInstanceIds", "해결된 afterState에는 플레이어 선택을 남길 수 없습니다.")
            end
            local afterIntent = pending.afterState.characterIntent
            local afterIntentIds = type(afterIntent) == "table" and afterIntent.cardInstanceIds or nil
            if type(afterIntentIds) ~= "table" or #afterIntentIds ~= 0 then
                addError(errors, "pending_after_character_intent_not_empty", "$.afterState.characterIntent.cardInstanceIds", "해결된 afterState에는 캐릭터 선택을 남길 수 없습니다.")
            end
            if type(afterIntent) == "table" and afterIntent.publicActionTag ~= nil then
                addError(errors, "pending_after_public_action_present", "$.afterState.characterIntent.publicActionTag", "해결된 afterState에는 공개 행동 태그를 남길 수 없습니다.")
            end
            if isInteger(pending.beforeState.turnNumber, 1)
                and isInteger(pending.afterState.turnNumber, 1)
                and pending.afterState.turnNumber < pending.beforeState.turnNumber then
                addError(errors, "turn_number_reversed", "$.afterState.turnNumber", "afterState의 턴 번호가 이전으로 돌아갈 수 없습니다.")
            elseif isInteger(pending.beforeState.turnNumber, 1)
                and isInteger(pending.afterState.turnNumber, 1)
                and pending.afterState.turnNumber > pending.beforeState.turnNumber + 1 then
                addError(errors, "turn_number_skipped", "$.afterState.turnNumber", "한 번의 대기 트랜잭션에서 턴을 둘 이상 건너뛸 수 없습니다.")
            end
            if pending.afterState.turnLimit ~= pending.beforeState.turnLimit then
                addError(errors, "turn_limit_changed", "$.afterState.turnLimit", "한 턴 판정 중 제한 턴을 바꿀 수 없습니다.")
            end
            if pending.afterState.environmentId ~= pending.beforeState.environmentId then
                addError(errors, "environment_changed", "$.afterState.environmentId", "한 턴 판정 중 환경을 바꿀 수 없습니다.")
            end
            if not transitEqual(pending.afterState.transit, pending.beforeState.transit) then
                addError(errors, "transit_changed", "$.afterState.transit", "한 턴 판정 중 지하철 이동 구간을 바꿀 수 없습니다.")
            end
            local beforeCharacter = type(pending.beforeState.character) == "table" and pending.beforeState.character.characterId or nil
            local afterCharacter = type(pending.afterState.character) == "table" and pending.afterState.character.characterId or nil
            if afterCharacter ~= beforeCharacter then
                addError(errors, "character_changed", "$.afterState.character.characterId", "한 전투의 캐릭터를 턴 판정 중 바꿀 수 없습니다.")
            end
            local beforeRng = pending.beforeState.rng
            local afterRng = pending.afterState.rng
            if type(beforeRng) == "table" and type(afterRng) == "table" then
                if afterRng.seed ~= beforeRng.seed then
                    addError(errors, "rng_seed_changed", "$.afterState.rng.seed", "한 전투의 난수 시드를 턴 판정 중 바꿀 수 없습니다.")
                end
                if isInteger(beforeRng.cursor, 0)
                    and isInteger(afterRng.cursor, 0)
                    and afterRng.cursor < beforeRng.cursor then
                    addError(errors, "rng_cursor_reversed", "$.afterState.rng.cursor", "난수 커서는 이전으로 돌아갈 수 없습니다.")
                end
            end

            local projectionReceipt = pending.projectionReceipt
            if type(projectionReceipt) == "table" then
                local source = projectionReceipt.source
                if type(source) == "table" then
                    if source.battleId ~= pending.battleId
                        or source.battleId ~= pending.beforeState.battleId then
                        addError(errors, "projection_battle_mismatch", "$.projectionReceipt.source.battleId", "projectionReceipt battleId가 pendingTurn 권위 상태와 다릅니다.")
                    end
                    if source.status ~= pending.beforeState.status then
                        addError(errors, "projection_status_mismatch", "$.projectionReceipt.source.status", "projectionReceipt 상태가 beforeState와 다릅니다.")
                    end
                    if source.turnNumber ~= pending.beforeState.turnNumber then
                        addError(errors, "projection_turn_mismatch", "$.projectionReceipt.source.turnNumber", "projectionReceipt 턴 번호가 beforeState와 다릅니다.")
                    end
                    if source.lastCommittedTurnId ~= pending.beforeState.lastCommittedTurnId then
                        addError(errors, "projection_commit_mismatch", "$.projectionReceipt.source.lastCommittedTurnId", "projectionReceipt 마지막 확정 턴 ID가 beforeState와 다릅니다.")
                    end
                    if not rngEqual(source.rng, pending.beforeState.rng) then
                        addError(errors, "projection_rng_mismatch", "$.projectionReceipt.source.rng", "projectionReceipt 시작 RNG가 beforeState와 다릅니다.")
                    end
                    local expectedFingerprint, fingerprintError = fingerprintDraftAuthorityState(pending.beforeState)
                    if fingerprintError then
                        addError(errors, fingerprintError.code, fingerprintError.path, fingerprintError.message)
                    elseif not fingerprintsEqual(source.fingerprint, expectedFingerprint) then
                        addError(errors, "projection_fingerprint_mismatch", "$.projectionReceipt.source.fingerprint", "projectionReceipt fingerprint가 beforeState 전체와 다릅니다.")
                    end
                end
                local projectedRng = projectionReceipt.projectedRng
                if type(projectedRng) == "table"
                    and type(afterRng) == "table"
                    and isInteger(projectedRng.cursor, 0)
                    and isInteger(afterRng.cursor, 0)
                    and afterRng.cursor < projectedRng.cursor then
                    addError(errors, "after_rng_before_projection", "$.afterState.rng.cursor", "afterState RNG cursor는 선택 projection이 소비한 위치보다 이전일 수 없습니다.")
                end
            end

            if type(pending.selectedCards) == "table" then
                local selected = type(projectionReceipt) == "table"
                    and projectionReceipt.selectedCardInstanceIds
                    or nil
                local intent = type(pending.beforeState.characterIntent) == "table"
                    and pending.beforeState.characterIntent.cardInstanceIds
                    or nil
                if not arraysEqual(pending.selectedCards.player, selected) then
                    addError(errors, "player_selection_mismatch", "$.selectedCards.player", "projectionReceipt의 플레이어 선택과 다릅니다.")
                end
                if not arraysEqual(pending.selectedCards.character, intent) then
                    addError(errors, "character_selection_mismatch", "$.selectedCards.character", "beforeState의 캐릭터 선택과 다릅니다.")
                end
            end
        end

        validatePendingIntegrity(pending, errors)

        local report = result(errors, pending)
        report.referencesValidated = referencesValidated
        report.projectionReplayValidated = false
        return report
    end

    local function cloneJson(value, active)
        local valueType = type(value)
        if valueType ~= "table" then
            if valueType == "string" or valueType == "number" or valueType == "boolean" or valueType == "nil" then
                return value
            end
            error("unsupported type: " .. valueType)
        end
        if getmetatable(value) ~= nil then
            error("metatable is not allowed")
        end
        active = active or {}
        if active[value] then
            error("circular reference")
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            copy[cloneJson(key, active)] = cloneJson(item, active)
        end
        active[value] = nil
        return copy
    end

    local function constructBattleState(options, staticData)
        if type(options) ~= "table" then
            local errors = {}
            addError(errors, "invalid_options", "$", "battleState 생성 사양이 테이블이 아닙니다.")
            return result(errors)
        end

        local ok, state = pcall(function()
            local value = cloneJson(options)
            value.schemaVersion = SCHEMA_VERSION
            value.kind = "battleState"
            local normalizedStaticData = normalizeStaticData(staticData)
            if type(value.character) == "table" and value.character.moodTokens == nil
                and type(normalizedStaticData) == "table"
                and type(normalizedStaticData.registry) == "table"
                and type(normalizedStaticData.registry.moods) == "table" then
                value.character.moodTokens = {}
                for moodId in pairs(normalizedStaticData.registry.moods) do
                    value.character.moodTokens[moodId] = 0
                end
            end
            return value
        end)

        if not ok then
            local errors = {}
            addError(errors, "construct_failed", "$", "battleState 생성에 실패했습니다: " .. tostring(state))
            return result(errors)
        end

        local validation = validateBattleState(state, staticData)
        if not validation.ok then
            return validation
        end
        local report = result({}, state)
        report.referencesValidated = validation.referencesValidated
        return report
    end

    local function constructPendingTurn(spec, staticData)
        if type(spec) ~= "table" then
            local errors = {}
            addError(errors, "invalid_spec", "$", "pendingTurn 생성 사양이 테이블이 아닙니다.")
            return result(errors)
        end

        local ok, pending = pcall(function()
            local value = cloneJson(spec)
            value.schemaVersion = SCHEMA_VERSION
            value.kind = "pendingTurn"
            value.status = "awaitingOutput"
            value.integrity = nil
            return value
        end)

        if not ok then
            local errors = {}
            addError(errors, "construct_failed", "$", "pendingTurn 생성에 실패했습니다: " .. tostring(pending))
            return result(errors)
        end

        local integrity, integrityError = fingerprintPendingTurn(pending)
        if integrityError then
            local errors = {}
            addError(errors, integrityError.code, integrityError.path, integrityError.message)
            return result(errors)
        end
        pending.integrity = integrity

        local validation = validatePendingTurn(pending, staticData)
        if not validation.ok then
            return validation
        end
        local report = result({}, pending)
        report.referencesValidated = validation.referencesValidated
        report.projectionReplayValidated = false
        return report
    end

    local arguments = { ... }
    if action == "newBattleState" then
        return constructBattleState(arguments[1], arguments[2])
    elseif action == "validateBattleState" then
        return validateBattleState(arguments[1], arguments[2])
    elseif action == "fingerprintBattleState" then
        return fingerprintBattleState(arguments[1], arguments[2])
    elseif action == "sealTurnStartReceipt" then
        return sealTurnStartReceipt(arguments[1], arguments[2])
    elseif action == "newPendingTurn" then
        return constructPendingTurn(arguments[1], arguments[2])
    elseif action == "validatePendingTurn" then
        return validatePendingTurn(arguments[1], arguments[2])
    end

    local errors = {}
    addError(errors, "unknown_action", "$", "지원하지 않는 상태 스키마 작업입니다: " .. tostring(action))
    return result(errors)
end)
