(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local ALGORITHM = "park_miller_schrage_v1"
    local MODULUS = 2147483647
    local MULTIPLIER = 16807
    local QUOTIENT = 127773
    local REMAINDER = 2836
    local SOURCE_SIZE = MODULUS - 1
    local MAX_SAFE_INTEGER = 9007199254740991

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
            algorithm = ALGORITHM,
            errors = errors,
        }
    end

    local function success(value, rng)
        local response = {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            algorithm = ALGORITHM,
            errors = {},
            value = value,
        }
        if rng ~= nil then
            response.rng = rng
        end
        return response
    end

    local function isFinite(value)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
    end

    local function isSafeInteger(value, minimum)
        return isFinite(value)
            and value % 1 == 0
            and math.abs(value) <= MAX_SAFE_INTEGER
            and (minimum == nil or value >= minimum)
    end

    local function cloneRng(rng)
        return {
            seed = rng.seed,
            cursor = rng.cursor,
        }
    end

    local function validateRng(rng)
        local errors = {}
        if type(rng) ~= "table" then
            table.insert(errors, makeError("invalid_rng", "$.rng", "rng는 테이블이어야 합니다."))
            return errors
        end
        if getmetatable(rng) ~= nil then
            table.insert(errors, makeError("rng_metatable_not_allowed", "$.rng", "rng에는 메타테이블을 사용할 수 없습니다."))
            return errors
        end

        for key in pairs(rng) do
            if key ~= "seed" and key ~= "cursor" then
                table.insert(
                    errors,
                    makeError("unknown_rng_field", "$.rng." .. tostring(key), "rng에 허용되지 않은 필드가 있습니다.")
                )
            end
        end

        if not isSafeInteger(rng.seed, 0) then
            table.insert(
                errors,
                makeError(
                    "invalid_rng_seed",
                    "$.rng.seed",
                    "seed는 0 이상이고 IEEE-754 안전 범위 안의 정수여야 합니다."
                )
            )
        end
        if not isSafeInteger(rng.cursor, 0) then
            table.insert(
                errors,
                makeError(
                    "invalid_rng_cursor",
                    "$.rng.cursor",
                    "cursor는 0 이상이고 IEEE-754 안전 범위 안의 정수여야 합니다."
                )
            )
        end
        return errors
    end

    local function normalizeSeed(seed)
        -- 외부 seed는 그대로 보존하고 생성기 내부 상태만 1..M-1로 정규화한다.
        local normalized = seed % MODULUS
        if normalized == 0 then
            return 1
        end
        return normalized
    end

    local function parkMillerStep(value)
        -- Schrage 분해를 사용해 32비트 범위 안에서 A * value mod M을 계산한다.
        local high = math.floor(value / QUOTIENT)
        local low = value - high * QUOTIENT
        local nextValue = MULTIPLIER * low - REMAINDER * high
        if nextValue <= 0 then
            nextValue = nextValue + MODULUS
        end
        return nextValue
    end

    local function multiplyModulo(left, right)
        -- 모든 중간 덧셈을 2*M 미만으로 유지하는 정확한 double-and-add 곱셈이다.
        local result = 0
        while right > 0 do
            if right % 2 == 1 then
                result = result + left
                if result >= MODULUS then
                    result = result - MODULUS
                end
            end
            right = math.floor(right / 2)
            if right > 0 then
                left = left + left
                if left >= MODULUS then
                    left = left - MODULUS
                end
            end
        end
        return result
    end

    local function powerModulo(base, exponent)
        local result = 1
        while exponent > 0 do
            if exponent % 2 == 1 then
                result = multiplyModulo(result, base)
            end
            exponent = math.floor(exponent / 2)
            if exponent > 0 then
                base = multiplyModulo(base, base)
            end
        end
        return result
    end

    local function stateAtCursor(rng)
        if rng.cursor == 0 then
            return normalizeSeed(rng.seed)
        end
        local jump = powerModulo(MULTIPLIER, rng.cursor)
        return multiplyModulo(normalizeSeed(rng.seed), jump)
    end

    local function nextRaw(rng)
        if rng.cursor >= MAX_SAFE_INTEGER then
            return nil, makeError(
                "rng_cursor_exhausted",
                "$.rng.cursor",
                "cursor를 안전하게 증가시킬 수 있는 범위를 모두 사용했습니다."
            )
        end

        local raw = parkMillerStep(stateAtCursor(rng))
        return raw, {
            seed = rng.seed,
            cursor = rng.cursor + 1,
        }
    end

    local function validateRange(minimum, maximum)
        local errors = {}
        if not isSafeInteger(minimum) then
            table.insert(
                errors,
                makeError("invalid_range_minimum", "$.minimum", "minimum은 IEEE-754 안전 범위 안의 정수여야 합니다.")
            )
        end
        if not isSafeInteger(maximum) then
            table.insert(
                errors,
                makeError("invalid_range_maximum", "$.maximum", "maximum은 IEEE-754 안전 범위 안의 정수여야 합니다.")
            )
        end
        if #errors > 0 then
            return errors
        end
        if minimum > maximum then
            table.insert(errors, makeError("invalid_range_order", "$.maximum", "maximum은 minimum보다 작을 수 없습니다."))
            return errors
        end
        if maximum - minimum >= SOURCE_SIZE then
            table.insert(
                errors,
                makeError(
                    "range_too_wide",
                    "$.maximum",
                    "한 번의 Park-Miller 표본으로 만들 수 있는 정수 범위를 초과했습니다."
                )
            )
        end
        return errors
    end

    local function generateInteger(rng, minimum, maximum)
        local span = maximum - minimum + 1
        local acceptedSize = SOURCE_SIZE - (SOURCE_SIZE % span)
        local currentRng = cloneRng(rng)

        while true do
            local raw, nextStateOrError = nextRaw(currentRng)
            if raw == nil then
                return nil, nil, nextStateOrError
            end
            currentRng = nextStateOrError

            local zeroBased = raw - 1
            if zeroBased < acceptedSize then
                return minimum + (zeroBased % span), currentRng, nil
            end
        end
    end

    local function validateAction(rng)
        local errors = validateRng(rng)
        if #errors > 0 then
            return failure(errors)
        end
        return success(cloneRng(rng), cloneRng(rng))
    end

    local function nextInteger(rng, minimum, maximum)
        local errors = validateRng(rng)
        local rangeErrors = validateRange(minimum, maximum)
        for _, item in ipairs(rangeErrors) do
            table.insert(errors, item)
        end
        if #errors > 0 then
            return failure(errors)
        end

        local value, nextRng, generationError = generateInteger(rng, minimum, maximum)
        if generationError ~= nil then
            return failure({ generationError })
        end
        return success(value, nextRng)
    end

    local function inspectArray(array)
        local errors = {}
        if type(array) ~= "table" then
            table.insert(errors, makeError("invalid_array", "$.array", "shuffle 대상은 배열 테이블이어야 합니다."))
            return errors, nil
        end
        if getmetatable(array) ~= nil then
            table.insert(errors, makeError("array_metatable_not_allowed", "$.array", "배열에는 메타테이블을 사용할 수 없습니다."))
            return errors, nil
        end

        local count = 0
        local maximum = 0
        for key in pairs(array) do
            if not isSafeInteger(key, 1) then
                table.insert(
                    errors,
                    makeError("invalid_array_index", "$.array", "배열 인덱스는 1 이상의 연속된 정수여야 합니다.")
                )
                return errors, nil
            end
            count = count + 1
            if key > maximum then
                maximum = key
            end
        end
        if count ~= maximum then
            table.insert(errors, makeError("sparse_array", "$.array", "배열 인덱스는 1부터 빈틈없이 이어져야 합니다."))
            return errors, nil
        end
        if maximum > SOURCE_SIZE then
            table.insert(
                errors,
                makeError("array_too_large", "$.array", "한 번의 Park-Miller 표본으로 섞을 수 있는 배열 길이를 초과했습니다.")
            )
            return errors, nil
        end
        return errors, maximum
    end

    local function shuffle(rng, array)
        local errors = validateRng(rng)
        local arrayErrors, length = inspectArray(array)
        for _, item in ipairs(arrayErrors) do
            table.insert(errors, item)
        end
        if #errors > 0 then
            return failure(errors)
        end

        local shuffled = {}
        for index = 1, length do
            shuffled[index] = array[index]
        end
        local currentRng = cloneRng(rng)

        for index = length, 2, -1 do
            local swapIndex, nextRng, generationError = generateInteger(currentRng, 1, index)
            if generationError ~= nil then
                return failure({ generationError })
            end
            currentRng = nextRng
            shuffled[index], shuffled[swapIndex] = shuffled[swapIndex], shuffled[index]
        end

        return success(shuffled, currentRng)
    end

    local arguments = { ... }
    local actions = {
        validate = validateAction,
        nextInteger = nextInteger,
        shuffle = shuffle,
    }

    local handler = actions[action]
    if not handler then
        return failure({
            makeError(
                "unknown_action",
                "$",
                "지원하지 않는 결정적 RNG 작업입니다: " .. tostring(action)
            ),
        })
    end

    return handler(arguments[1], arguments[2], arguments[3])
end)
