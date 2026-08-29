(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local KIND = "runProgressionV1"
    local MIN_DECK_SIZE = 10
    local MAX_DECK_SIZE = 20
    local MAX_CARD_COPIES = 2
    local REWARD_OFFER_SIZE = 3
    local CHARACTER_OFFER_SIZE = 3
    local MAX_SESSIONS = 999
    local BATTLE_SEED_MAX = 2147483646
    local MAX_SAFE_INTEGER = 9007199254740991
    local TRANSIT_ALGORITHM = "tokyo_subway_segment_v1"

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

    local function success(state, applied, stale)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            state = state,
            applied = applied == true,
            stale = stale == true,
        }
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

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function objectPath(path, key)
        if type(key) == "string"
            and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", tostring(key)) .. "]"
    end

    local function appendError(errors, code, path, message)
        errors[#errors + 1] = makeError(code, path, message)
    end

    local function inspectJsonTable(value, path, errors)
        if type(value) ~= "table" then
            appendError(errors, "expected_table", path, "테이블이어야 합니다.")
            return nil, nil
        end
        if getmetatable(value) ~= nil then
            appendError(errors, "metatable_not_allowed", path, "JSON 값에는 메타테이블을 사용할 수 없습니다.")
            return nil, nil
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
                if not isSafeInteger(key, 1) then
                    appendError(errors, "invalid_array_index", path, "배열 인덱스는 1 이상의 연속 정수여야 합니다.")
                    return nil, nil
                end
                if key > maximum then
                    maximum = key
                end
            elseif type(key) == "string" then
                hasString = true
                stringKeys[#stringKeys + 1] = key
            else
                appendError(errors, "invalid_object_key", path, "JSON 객체 키는 문자열이어야 합니다.")
                return nil, nil
            end
        end
        if hasNumeric and hasString then
            appendError(errors, "mixed_table", path, "배열 인덱스와 객체 키를 함께 사용할 수 없습니다.")
            return nil, nil
        end
        if hasNumeric then
            if numericCount ~= maximum then
                appendError(errors, "sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
                return nil, nil
            end
            return "array", maximum
        end
        table.sort(stringKeys)
        return "object", stringKeys
    end

    local function validateJson(value, path, errors, active)
        local valueType = type(value)
        if valueType == "string" or valueType == "boolean" or valueType == "nil" then
            return
        end
        if valueType == "number" then
            if not isFinite(value) then
                appendError(errors, "non_finite_number", path, "유한하지 않은 숫자는 상태에 저장할 수 없습니다.")
            end
            return
        end
        if valueType ~= "table" then
            appendError(
                errors,
                "unsupported_type",
                path,
                "상태에 저장할 수 없는 자료형입니다: " .. valueType
            )
            return
        end
        if getmetatable(value) ~= nil then
            appendError(errors, "metatable_not_allowed", path, "상태 값에는 메타테이블을 사용할 수 없습니다.")
            return
        end

        active = active or {}
        if active[value] then
            appendError(errors, "circular_reference", path, "순환 참조가 있는 상태는 사용할 수 없습니다.")
            return
        end
        active[value] = true
        local kind, shape = inspectJsonTable(value, path, errors)
        if kind == "array" then
            for index = 1, shape do
                validateJson(value[index], path .. "[" .. index .. "]", errors, active)
            end
        elseif kind == "object" then
            for _, key in ipairs(shape) do
                validateJson(value[key], objectPath(path, key), errors, active)
            end
        end
        active[value] = nil
    end

    local function cloneJson(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "유한하지 않은 숫자는 상태에 저장할 수 없습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError(
                "unsupported_type",
                path,
                "상태에 저장할 수 없는 자료형입니다: " .. valueType
            )
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "상태 값에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조가 있는 상태는 사용할 수 없습니다.")
        end
        active[value] = true

        local shapeErrors = {}
        local kind, shape = inspectJsonTable(value, path, shapeErrors)
        if #shapeErrors > 0 then
            active[value] = nil
            return nil, shapeErrors[1]
        end

        local copy = {}
        if kind == "array" then
            for index = 1, shape do
                local itemCopy, itemError = cloneJson(value[index], path .. "[" .. index .. "]", active)
                if itemError then
                    active[value] = nil
                    return nil, itemError
                end
                copy[index] = itemCopy
            end
        else
            for _, key in ipairs(shape) do
                local itemCopy, itemError = cloneJson(value[key], objectPath(path, key), active)
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

    local function deepEqual(left, right, seen)
        if type(left) ~= type(right) then
            return false
        end
        if type(left) ~= "table" then
            return left == right
        end
        if getmetatable(left) ~= nil or getmetatable(right) ~= nil then
            return false
        end
        seen = seen or {}
        if seen[left] ~= nil then
            return seen[left] == right
        end
        seen[left] = right
        for key, value in pairs(left) do
            if not deepEqual(value, right[key], seen) then
                seen[left] = nil
                return false
            end
        end
        for key in pairs(right) do
            if left[key] == nil then
                seen[left] = nil
                return false
            end
        end
        seen[left] = nil
        return true
    end

    local function checkAllowedKeys(value, allowed, path, errors)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or allowed[key] ~= true then
                appendError(errors, "unknown_field", objectPath(path, key), "허용되지 않은 필드입니다.")
            end
        end
    end

    local function denseArrayLength(value, path, errors)
        local kind, shape = inspectJsonTable(value, path, errors)
        if kind == "object" and type(shape) == "table" and #shape == 0 then
            return 0
        end
        if kind ~= "array" then
            if kind ~= nil then
                appendError(errors, "expected_array", path, "1부터 시작하는 연속 배열이어야 합니다.")
            end
            return nil
        end
        return shape
    end

    local function copyArray(value)
        local copy = {}
        for index, item in ipairs(value or {}) do
            copy[index] = item
        end
        return copy
    end

    local function contains(value, target)
        for _, item in ipairs(value or {}) do
            if item == target then
                return true
            end
        end
        return false
    end

    local function normalizeStaticData(staticInput)
        if type(staticInput) == "table"
            and getmetatable(staticInput) == nil
            and type(rawget(staticInput, "data")) == "table" then
            return rawget(staticInput, "data")
        end
        return staticInput
    end

    local function appendNestedErrors(target, moduleName, report)
        local nested = type(report) == "table" and report.errors or nil
        if type(nested) ~= "table" or #nested == 0 then
            target[#target + 1] = makeError(
                "module_failed_without_errors",
                "$.runtime." .. moduleName,
                moduleName .. "이 오류 상세 없이 실패했습니다."
            )
            return
        end
        for index, item in ipairs(nested) do
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

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError(
                    "runtime_unavailable",
                    "$.runtime." .. moduleName,
                    moduleName .. "을 호출할 runScript 실행기가 없습니다."
                ),
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
        if report.schemaVersion ~= SCHEMA_VERSION
            or type(report.errors) ~= "table"
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
        if #report.errors ~= 0 then
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

    local function buildPools(staticInput)
        local staticData = normalizeStaticData(staticInput)
        local errors = {}
        if type(staticData) ~= "table" or getmetatable(staticData) ~= nil then
            appendError(errors, "invalid_static_data", "$.staticData", "정적 데이터는 일반 테이블이어야 합니다.")
            return nil, nil, nil, errors
        end

        local cards = rawget(staticData, "cards")
        local characters = rawget(staticData, "characters")
        if type(cards) ~= "table" or getmetatable(cards) ~= nil then
            appendError(errors, "invalid_card_database", "$.staticData.cards", "플레이어 카드 풀을 만들 cards 맵이 필요합니다.")
        end
        if type(characters) ~= "table" or getmetatable(characters) ~= nil then
            appendError(errors, "invalid_character_database", "$.staticData.characters", "대상 후보를 만들 characters 맵이 필요합니다.")
        end
        if #errors > 0 then
            return nil, nil, nil, errors
        end

        local playerPool = {}
        for cardId, card in pairs(cards) do
            local path = objectPath("$.staticData.cards", cardId)
            if type(cardId) ~= "string" then
                appendError(errors, "invalid_card_key", "$.staticData.cards", "카드 맵 키는 문자열이어야 합니다.")
            elseif type(card) ~= "table" or getmetatable(card) ~= nil then
                appendError(errors, "invalid_card_record", path, "카드 레코드는 일반 테이블이어야 합니다.")
            elseif card.owner == "player" then
                if not isAsciiId(cardId) or card.id ~= cardId then
                    appendError(errors, "invalid_player_card", path, "플레이어 카드 키와 내부 ID가 올바르지 않습니다.")
                else
                    playerPool[#playerPool + 1] = cardId
                end
            end
        end
        table.sort(playerPool)

        local characterPool = {}
        for characterId, character in pairs(characters) do
            local path = objectPath("$.staticData.characters", characterId)
            if not isAsciiId(characterId) then
                appendError(errors, "invalid_character_id", path, "캐릭터 키는 lower_snake_case ASCII ID여야 합니다.")
            elseif type(character) ~= "table"
                or getmetatable(character) ~= nil
                or character.id ~= characterId then
                appendError(errors, "invalid_character_record", path, "캐릭터 키와 내부 ID가 올바르지 않습니다.")
            else
                characterPool[#characterPool + 1] = characterId
            end
        end
        table.sort(characterPool)

        if #playerPool == 0 then
            appendError(errors, "empty_player_card_pool", "$.staticData.cards", "카드 보상 후보가 될 플레이어 카드가 없습니다.")
        end
        if #characterPool < CHARACTER_OFFER_SIZE then
            appendError(
                errors,
                "insufficient_character_pool",
                "$.staticData.characters",
                "다음 대상 선택에는 서로 다른 캐릭터가 최소 3명 필요합니다."
            )
        end
        if #errors > 0 then
            return nil, nil, nil, errors
        end
        return staticData, playerPool, characterPool, nil
    end

    local function validateSetup(setupInput, staticInput)
        local setupCopy, setupCopyError = cloneJson(setupInput, "$.gameSetup")
        if setupCopyError then
            return nil, nil, nil, nil, { setupCopyError }
        end
        local staticData, playerPool, characterPool, poolErrors = buildPools(staticInput)
        if poolErrors then
            return nil, nil, nil, nil, poolErrors
        end

        local validated, validationErrors = callModule(
            "gameSetup",
            "validate",
            setupCopy,
            staticInput
        )
        if validationErrors then
            return nil, nil, nil, nil, validationErrors
        end
        if type(validated.state) ~= "table" or getmetatable(validated.state) ~= nil then
            return nil, nil, nil, nil, {
                makeError(
                    "missing_validated_setup",
                    "$.runtime.gameSetup.state",
                    "gameSetup.validate가 canonical 설정 상태를 반환하지 않았습니다."
                ),
            }
        end
        if not deepEqual(setupCopy, validated.state) then
            return nil, nil, nil, nil, {
                makeError(
                    "setup_validation_mismatch",
                    "$.gameSetup",
                    "원본 설정 상태가 seed와 선택 이력으로 재생한 canonical 상태와 다릅니다."
                ),
            }
        end
        if validated.state.kind ~= "gameSetupV1" or validated.state.phase ~= "battleReady" then
            return nil, nil, nil, nil, {
                makeError(
                    "setup_not_battle_ready",
                    "$.gameSetup.phase",
                    "runProgression에는 원본 gameSetupV1 battleReady 상태가 필요합니다."
                ),
            }
        end
        return validated.state, staticData, playerPool, characterPool, nil
    end

    local function callNextIntegers(rng, ranges)
        local report, callErrors = callModule(
            "deterministicRng",
            "nextIntegers",
            rng,
            ranges
        )
        if callErrors then
            return nil, nil, callErrors
        end

        local errors = {}
        local valueCount = denseArrayLength(report.value, "$.runtime.deterministicRng.value", errors)
        if valueCount ~= #ranges then
            appendError(
                errors,
                "invalid_rng_batch_size",
                "$.runtime.deterministicRng.value",
                "결정적 RNG 결과 개수가 요청 범위 개수와 다릅니다."
            )
        elseif valueCount ~= nil then
            for index = 1, valueCount do
                local value = report.value[index]
                local range = ranges[index]
                if not isSafeInteger(value, range.minimum) or value > range.maximum then
                    appendError(
                        errors,
                        "invalid_rng_batch_value",
                        "$.runtime.deterministicRng.value[" .. index .. "]",
                        "결정적 RNG 결과가 요청 범위를 벗어났습니다."
                    )
                end
            end
        end
        if type(report.rng) ~= "table"
            or getmetatable(report.rng) ~= nil
            or not isSafeInteger(report.rng.seed, 0)
            or not isSafeInteger(report.rng.cursor, 0)
            or report.rng.seed ~= rng.seed
            or (#ranges > 0 and report.rng.cursor <= rng.cursor)
            or (#ranges == 0 and report.rng.cursor ~= rng.cursor) then
            appendError(
                errors,
                "invalid_rng_result",
                "$.runtime.deterministicRng.rng",
                "결정적 RNG가 올바른 다음 상태를 반환하지 않았습니다."
            )
        end
        if #errors > 0 then
            return nil, nil, errors
        end
        return copyArray(report.value), {
            seed = report.rng.seed,
            cursor = report.rng.cursor,
        }, nil
    end

    local function pickWithoutReplacement(rng, candidates, count)
        local remaining = copyArray(candidates)
        local ranges = {}
        for pick = 1, count do
            ranges[pick] = {
                minimum = 1,
                maximum = #remaining - pick + 1,
            }
        end
        local selectedIndices, nextRng, rngErrors = callNextIntegers(rng, ranges)
        if rngErrors then
            return nil, nil, rngErrors
        end
        local selected = {}
        for pick = 1, count do
            local selectedIndex = selectedIndices[pick]
            selected[pick] = remaining[selectedIndex]
            table.remove(remaining, selectedIndex)
        end
        return selected, nextRng, nil
    end

    local function hashCanonical(prefix, canonical)
        local hashA = 0
        local hashB = 0
        for index = 1, #canonical do
            local byte = string.byte(canonical, index)
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        return prefix
            .. ":" .. tostring(#canonical)
            .. ":" .. tostring(hashA)
            .. ":" .. tostring(hashB)
    end

    local function appendCanonicalArray(parts, label, array)
        parts[#parts + 1] = "|" .. label .. "=" .. tostring(#array) .. ":"
        for _, value in ipairs(array) do
            parts[#parts + 1] = tostring(#value)
            parts[#parts + 1] = ":"
            parts[#parts + 1] = value
            parts[#parts + 1] = ";"
        end
    end

    local function buildRewardToken(setupId, sessionNumber, rng, settlement, deck, kind, cardIds)
        local parts = {
            "setupId=", tostring(#setupId), ":", setupId,
            "|session=", tostring(sessionNumber),
            "|cursor=", tostring(rng.cursor),
            "|battleId=", tostring(#settlement.battleId), ":", settlement.battleId,
            "|turnId=", tostring(#settlement.turnId), ":", settlement.turnId,
            "|kind=", kind,
        }
        appendCanonicalArray(parts, "deck", deck)
        appendCanonicalArray(parts, "offer", cardIds or {})
        return hashCanonical("run-progression-reward-v1", table.concat(parts))
    end

    local function buildCharacterToken(setupId, sessionNumber, rng, settlement, deck, characterIds)
        local parts = {
            "setupId=", tostring(#setupId), ":", setupId,
            "|session=", tostring(sessionNumber),
            "|cursor=", tostring(rng.cursor),
            "|battleId=", tostring(#settlement.battleId), ":", settlement.battleId,
            "|turnId=", tostring(#settlement.turnId), ":", settlement.turnId,
        }
        appendCanonicalArray(parts, "deck", deck)
        appendCanonicalArray(parts, "characters", characterIds)
        return hashCanonical("run-progression-character-v1", table.concat(parts))
    end

    local function countDeck(deck, playerPool, path)
        local errors = {}
        local length = denseArrayLength(deck, path, errors)
        if length ~= nil and (length < MIN_DECK_SIZE or length > MAX_DECK_SIZE) then
            appendError(
                errors,
                "invalid_deck_size",
                path,
                "런 덱은 10장 이상 20장 이하여야 합니다."
            )
        end
        local allowed = {}
        for _, cardId in ipairs(playerPool) do
            allowed[cardId] = true
        end
        local counts = {}
        if length ~= nil then
            for index = 1, length do
                local cardId = deck[index]
                if not isAsciiId(cardId) or allowed[cardId] ~= true then
                    appendError(
                        errors,
                        "unknown_player_card",
                        path .. "[" .. index .. "]",
                        "런 덱 카드가 현재 플레이어 카드 풀에 없습니다."
                    )
                else
                    counts[cardId] = (counts[cardId] or 0) + 1
                    if counts[cardId] > MAX_CARD_COPIES then
                        appendError(
                            errors,
                            "card_copy_limit_exceeded",
                            path .. "[" .. index .. "]",
                            "런 덱에는 같은 카드를 2장까지만 넣을 수 있습니다."
                        )
                    end
                end
            end
        end
        if #errors > 0 then
            return nil, nil, errors
        end
        return counts, length, nil
    end

    local function generateRewardOffer(
        setupId,
        sessionNumber,
        rng,
        settlement,
        deck,
        playerPool
    )
        local counts, deckLength, deckErrors = countDeck(deck, playerPool, "$.playerCardIds")
        if deckErrors then
            return nil, nil, deckErrors
        end
        local eligible = {}
        if deckLength < MAX_DECK_SIZE then
            for _, cardId in ipairs(playerPool) do
                if (counts[cardId] or 0) < MAX_CARD_COPIES then
                    eligible[#eligible + 1] = cardId
                end
            end
        end

        if #eligible == 0 then
            return {
                kind = "none",
                interactionToken = buildRewardToken(
                    setupId,
                    sessionNumber,
                    rng,
                    settlement,
                    deck,
                    "none",
                    {}
                ),
            }, {
                seed = rng.seed,
                cursor = rng.cursor,
            }, nil
        end

        local offerCount = math.min(REWARD_OFFER_SIZE, #eligible)
        local cardIds, nextRng, offerErrors = pickWithoutReplacement(rng, eligible, offerCount)
        if offerErrors then
            return nil, nil, offerErrors
        end
        return {
            kind = "card",
            cardIds = cardIds,
            interactionToken = buildRewardToken(
                setupId,
                sessionNumber,
                nextRng,
                settlement,
                deck,
                "card",
                cardIds
            ),
        }, nextRng, nil
    end

    local function generateCharacterOffer(
        setupId,
        sessionNumber,
        rng,
        settlement,
        deck,
        characterPool
    )
        local characterIds, nextRng, offerErrors = pickWithoutReplacement(
            rng,
            characterPool,
            CHARACTER_OFFER_SIZE
        )
        if offerErrors then
            return nil, nil, offerErrors
        end
        return {
            characterIds = characterIds,
            interactionToken = buildCharacterToken(
                setupId,
                sessionNumber,
                nextRng,
                settlement,
                deck,
                characterIds
            ),
        }, nextRng, nil
    end

    local function generateBattleSeed(rng)
        local values, nextRng, rngErrors = callNextIntegers(rng, {
            {
                minimum = 1,
                maximum = BATTLE_SEED_MAX,
            },
        })
        if rngErrors then
            return nil, nil, rngErrors
        end
        return values[1], nextRng, nil
    end

    local function buildJourney(seed, staticInput, turnLimit)
        local report, journeyErrors = callModule(
            "subwayJourney",
            "build",
            seed,
            staticInput,
            turnLimit
        )
        if journeyErrors then
            return nil, journeyErrors
        end
        local errors = {}
        if not isSafeInteger(report.turnLimit, 1) or report.turnLimit ~= turnLimit then
            appendError(errors, "invalid_turn_limit", "$.runtime.subwayJourney.turnLimit", "여정 제한 턴이 올바르지 않습니다.")
        end
        local transit = report.transit
        if type(transit) ~= "table" or getmetatable(transit) ~= nil then
            appendError(errors, "invalid_transit", "$.runtime.subwayJourney.transit", "여정 이동 구간이 일반 객체가 아닙니다.")
        else
            checkAllowedKeys(
                transit,
                { algorithm = true, lineId = true, stationIds = true },
                "$.runtime.subwayJourney.transit",
                errors
            )
            if transit.algorithm ~= TRANSIT_ALGORITHM then
                appendError(
                    errors,
                    "invalid_transit_algorithm",
                    "$.runtime.subwayJourney.transit.algorithm",
                    "지원하지 않는 여정 알고리즘입니다."
                )
            end
            if not isAsciiId(transit.lineId) then
                appendError(
                    errors,
                    "invalid_transit_line",
                    "$.runtime.subwayJourney.transit.lineId",
                    "여정 노선 ID가 올바르지 않습니다."
                )
            end
            local stationCount = denseArrayLength(
                transit.stationIds,
                "$.runtime.subwayJourney.transit.stationIds",
                errors
            )
            if stationCount ~= nil
                and isSafeInteger(report.turnLimit, 1)
                and stationCount ~= report.turnLimit + 1 then
                appendError(
                    errors,
                    "transit_length_mismatch",
                    "$.runtime.subwayJourney.transit.stationIds",
                    "여정 역 개수는 제한 턴보다 하나 많아야 합니다."
                )
            elseif stationCount ~= nil then
                for index = 1, stationCount do
                    if not isAsciiId(transit.stationIds[index]) then
                        appendError(
                            errors,
                            "invalid_station_id",
                            "$.runtime.subwayJourney.transit.stationIds[" .. index .. "]",
                            "여정 역 ID가 올바르지 않습니다."
                        )
                    end
                end
            end
        end
        if #errors > 0 then
            return nil, errors
        end
        return {
            turnLimit = report.turnLimit,
            transit = {
                algorithm = transit.algorithm,
                lineId = transit.lineId,
                stationIds = copyArray(transit.stationIds),
            },
        }, nil
    end

    local function buildBattleSpec(
        setupId,
        sessionNumber,
        seed,
        characterId,
        deck,
        staticInput
    )
        local staticData = normalizeStaticData(staticInput)
        local turnLimit = staticData.characters[characterId].battle.turnLimit
        local journey, journeyErrors = buildJourney(seed, staticInput, turnLimit)
        if journeyErrors then
            return nil, journeyErrors
        end
        return {
            battleId = "battle-" .. setupId .. "-session-" .. string.format("%03d", sessionNumber),
            seed = seed,
            playerCardIds = copyArray(deck),
            characterId = characterId,
            perkIds = {},
            turnLimit = journey.turnLimit,
            lineId = journey.transit.lineId,
            stationIds = copyArray(journey.transit.stationIds),
        }, nil
    end

    local function buildInitialBattleSpec(setup, staticInput)
        local staticData = normalizeStaticData(staticInput)
        local turnLimit = staticData.characters[setup.selectedCharacterId].battle.turnLimit
        local journey, journeyErrors = buildJourney(setup.battleSpec.seed, staticInput, turnLimit)
        if journeyErrors then
            return nil, journeyErrors
        end
        return {
            battleId = setup.battleSpec.battleId,
            seed = setup.battleSpec.seed,
            playerCardIds = copyArray(setup.selectedCardIds),
            characterId = setup.selectedCharacterId,
            perkIds = {},
            turnLimit = journey.turnLimit,
            lineId = journey.transit.lineId,
            stationIds = copyArray(journey.transit.stationIds),
        }, nil
    end

    local OUTCOME_REASONS = {
        card_checkpoint = true,
        turn_end_checkpoint = true,
        turn_limit = true,
    }

    local function normalizeSummary(summaryInput, staticData, path)
        path = path or "$.summary"
        local summary, cloneError = cloneJson(summaryInput, path)
        if cloneError then
            return nil, { cloneError }
        end
        local errors = {}
        if type(summary) ~= "table" or getmetatable(summary) ~= nil then
            appendError(errors, "invalid_summary", path, "전투 종료 summary는 일반 객체여야 합니다.")
            return nil, errors
        end
        checkAllowedKeys(summary, {
            battleId = true,
            turnId = true,
            characterId = true,
            status = true,
            reasonCode = true,
            turnNumber = true,
            turnLimit = true,
            finalStealth = true,
            finalResistance = true,
            transit = true,
        }, path, errors)

        if not isRuntimeId(summary.battleId) then
            appendError(errors, "invalid_battle_id", path .. ".battleId", "summary battleId가 올바르지 않습니다.")
        end
        if not isRuntimeId(summary.turnId) then
            appendError(errors, "invalid_turn_id", path .. ".turnId", "summary turnId가 올바르지 않습니다.")
        end
        if not isAsciiId(summary.characterId)
            or type(staticData.characters[summary.characterId]) ~= "table" then
            appendError(errors, "unknown_character", path .. ".characterId", "summary 캐릭터를 정적 데이터에서 찾을 수 없습니다.")
        end
        if summary.status ~= "victory" and summary.status ~= "defeat" then
            appendError(errors, "invalid_status", path .. ".status", "summary status는 victory 또는 defeat여야 합니다.")
        end
        if OUTCOME_REASONS[summary.reasonCode] ~= true then
            appendError(errors, "invalid_reason_code", path .. ".reasonCode", "summary 종료 사유가 올바르지 않습니다.")
        end
        if not isSafeInteger(summary.turnNumber, 1) then
            appendError(errors, "invalid_turn_number", path .. ".turnNumber", "summary 턴 번호는 1 이상의 정수여야 합니다.")
        end
        if not isSafeInteger(summary.turnLimit, 1)
            or (isSafeInteger(summary.turnNumber, 1) and summary.turnNumber > summary.turnLimit) then
            appendError(errors, "invalid_turn_limit", path .. ".turnLimit", "summary 제한 턴이 올바르지 않습니다.")
        end
        if not isFinite(summary.finalStealth) then
            appendError(errors, "invalid_final_stealth", path .. ".finalStealth", "최종 은폐는 유한한 숫자여야 합니다.")
        end
        if not isFinite(summary.finalResistance) then
            appendError(errors, "invalid_final_resistance", path .. ".finalResistance", "최종 저항은 유한한 숫자여야 합니다.")
        end
        local transit = summary.transit
        if type(transit) ~= "table" or getmetatable(transit) ~= nil then
            appendError(errors, "invalid_transit", path .. ".transit", "summary transit은 일반 객체여야 합니다.")
        else
            checkAllowedKeys(
                transit,
                { algorithm = true, lineId = true, stationIds = true },
                path .. ".transit",
                errors
            )
            if transit.algorithm ~= TRANSIT_ALGORITHM then
                appendError(
                    errors,
                    "invalid_transit_algorithm",
                    path .. ".transit.algorithm",
                    "summary transit 알고리즘이 올바르지 않습니다."
                )
            end
            if not isAsciiId(transit.lineId)
                or type(staticData.subwayLines) ~= "table"
                or type(staticData.subwayLines[transit.lineId]) ~= "table" then
                appendError(errors, "unknown_subway_line", path .. ".transit.lineId", "summary 지하철 노선을 찾을 수 없습니다.")
            end
            local stationCount = denseArrayLength(
                transit.stationIds,
                path .. ".transit.stationIds",
                errors
            )
            if stationCount ~= nil
                and isSafeInteger(summary.turnLimit, 1)
                and stationCount ~= summary.turnLimit + 1 then
                appendError(
                    errors,
                    "transit_length_mismatch",
                    path .. ".transit.stationIds",
                    "summary 역 개수는 제한 턴보다 하나 많아야 합니다."
                )
            elseif stationCount ~= nil then
                for index = 1, stationCount do
                    if not isAsciiId(transit.stationIds[index]) then
                        appendError(
                            errors,
                            "invalid_station_id",
                            path .. ".transit.stationIds[" .. index .. "]",
                            "summary 역 ID가 올바르지 않습니다."
                        )
                    end
                end
            end
        end

        if isRuntimeId(summary.battleId)
            and isSafeInteger(summary.turnNumber, 1)
            and summary.turnId ~= string.format("%s-turn-%03d", summary.battleId, summary.turnNumber) then
            appendError(
                errors,
                "turn_identity_mismatch",
                path .. ".turnId",
                "summary turnId가 battleId와 턴 번호에서 결정되는 ID와 다릅니다."
            )
        end

        if isFinite(summary.finalResistance)
            and isFinite(summary.finalStealth)
            and (summary.status == "victory" or summary.status == "defeat") then
            if summary.finalResistance <= 0 and summary.status ~= "victory" then
                appendError(errors, "victory_priority", path .. ".status", "저항이 0 이하이면 승리를 우선해야 합니다.")
            elseif summary.finalResistance > 0
                and summary.finalStealth <= 0
                and summary.status ~= "defeat" then
                appendError(errors, "defeat_required", path .. ".status", "은폐가 0 이하이면 패배여야 합니다.")
            elseif summary.status == "victory" and summary.finalResistance > 0 then
                appendError(errors, "invalid_victory", path .. ".status", "저항이 남은 summary는 승리일 수 없습니다.")
            elseif summary.status == "defeat"
                and summary.finalStealth > 0
                and summary.turnNumber < summary.turnLimit then
                appendError(errors, "invalid_defeat", path .. ".status", "은폐가 남고 제한 턴 전이면 패배일 수 없습니다.")
            end
        end
        if summary.reasonCode == "turn_limit"
            and (summary.status ~= "defeat"
                or summary.turnNumber ~= summary.turnLimit
                or (isFinite(summary.finalResistance) and summary.finalResistance <= 0)
                or (isFinite(summary.finalStealth) and summary.finalStealth <= 0)) then
            appendError(
                errors,
                "invalid_turn_limit_outcome",
                path .. ".reasonCode",
                "turn_limit 패배는 마지막 턴에 저항과 은폐가 모두 남은 경우여야 합니다."
            )
        elseif (summary.reasonCode == "card_checkpoint"
                or summary.reasonCode == "turn_end_checkpoint")
            and isFinite(summary.finalResistance)
            and isFinite(summary.finalStealth)
            and summary.finalResistance > 0
            and summary.finalStealth > 0 then
            appendError(
                errors,
                "invalid_resource_outcome",
                path .. ".reasonCode",
                "자원 checkpoint 종료에는 저항 또는 은폐가 0 이하여야 합니다."
            )
        end

        if #errors > 0 then
            return nil, errors
        end
        return summary, nil
    end

    local function summaryMatchesSpec(summary, battleSpec, path)
        path = path or "$.summary"
        local errors = {}
        if type(battleSpec) ~= "table" then
            appendError(errors, "missing_battle_spec", "$.battleSpec", "summary와 대조할 현재 전투 사양이 없습니다.")
            return errors
        end
        local comparisons = {
            { field = "battleId", expected = battleSpec.battleId },
            { field = "characterId", expected = battleSpec.characterId },
            { field = "turnLimit", expected = battleSpec.turnLimit },
        }
        for _, comparison in ipairs(comparisons) do
            if summary[comparison.field] ~= comparison.expected then
                appendError(
                    errors,
                    "settlement_battle_mismatch",
                    path .. "." .. comparison.field,
                    "종료 summary가 현재 battleReady 전투 사양과 다릅니다."
                )
            end
        end
        if type(summary.transit) == "table" then
            if summary.transit.lineId ~= battleSpec.lineId then
                appendError(
                    errors,
                    "settlement_transit_mismatch",
                    path .. ".transit.lineId",
                    "종료 summary 노선이 현재 전투 사양과 다릅니다."
                )
            end
            if not deepEqual(summary.transit.stationIds, battleSpec.stationIds) then
                appendError(
                    errors,
                    "settlement_transit_mismatch",
                    path .. ".transit.stationIds",
                    "종료 summary 이동 구간이 현재 전투 사양과 다릅니다."
                )
            end
        end
        return errors
    end

    local function validateRewardChoice(choiceInput, path)
        local choice, cloneError = cloneJson(choiceInput, path)
        if cloneError then
            return nil, { cloneError }
        end
        local errors = {}
        if type(choice) ~= "table" or getmetatable(choice) ~= nil then
            appendError(errors, "invalid_reward_choice", path, "보상 선택은 일반 객체여야 합니다.")
            return nil, errors
        end
        checkAllowedKeys(choice, { kind = true, cardId = true }, path, errors)
        if choice.kind == "card" then
            if not isAsciiId(choice.cardId) then
                appendError(errors, "invalid_reward_card", path .. ".cardId", "카드 보상 선택에는 cardId가 필요합니다.")
            end
        elseif choice.kind == "none" then
            if choice.cardId ~= nil then
                appendError(errors, "unexpected_reward_card", path .. ".cardId", "none 보상 선택에는 cardId를 넣을 수 없습니다.")
            end
        else
            appendError(errors, "invalid_reward_kind", path .. ".kind", "보상 선택 kind는 card 또는 none이어야 합니다.")
        end
        if #errors > 0 then
            return nil, errors
        end
        return choice, nil
    end

    local function applyRewardChoice(offer, choice, deck, playerPool, path)
        local counts, deckLength, deckErrors = countDeck(deck, playerPool, "$.playerCardIds")
        if deckErrors then
            return nil, deckErrors
        end
        if choice.kind == "none" then
            return copyArray(deck), nil
        end
        if offer.kind == "none" then
            return nil, {
                makeError(
                    "reward_choice_mismatch",
                    path .. ".kind",
                    "보상 카드가 없을 때는 continue 선택만 사용할 수 있습니다."
                ),
            }
        end
        if choice.kind ~= "card" or not contains(offer.cardIds, choice.cardId) then
            return nil, {
                makeError(
                    "reward_not_in_offer",
                    path,
                    "선택한 카드가 현재 보상 제안에 없습니다."
                ),
            }
        end
        if deckLength >= MAX_DECK_SIZE or (counts[choice.cardId] or 0) >= MAX_CARD_COPIES then
            return nil, {
                makeError(
                    "reward_no_longer_eligible",
                    path .. ".cardId",
                    "선택한 카드를 현재 덱에 추가할 수 없습니다."
                ),
            }
        end
        local nextDeck = copyArray(deck)
        nextDeck[#nextDeck + 1] = choice.cardId
        return nextDeck, nil
    end

    local SUMMARY_FIELDS = {
        "battleId",
        "turnId",
        "characterId",
        "status",
        "reasonCode",
        "turnNumber",
        "turnLimit",
        "finalStealth",
        "finalResistance",
        "transit",
    }

    local function copySettlementFromRecord(record, path)
        local summaryInput = {}
        for _, field in ipairs(SUMMARY_FIELDS) do
            local value = record[field]
            if field == "transit" then
                local transitCopy, transitError = cloneJson(value, path .. ".transit")
                if transitError then
                    return nil, transitError
                end
                summaryInput.transit = transitCopy
            else
                summaryInput[field] = value
            end
        end
        return summaryInput, nil
    end

    local function makeSessionRecord(settlement)
        local record = {}
        for _, field in ipairs(SUMMARY_FIELDS) do
            if field == "transit" then
                record.transit = {
                    algorithm = settlement.transit.algorithm,
                    lineId = settlement.transit.lineId,
                    stationIds = copyArray(settlement.transit.stationIds),
                }
            else
                record[field] = settlement[field]
            end
        end
        return record
    end

    local function buildState(
        setupId,
        phase,
        sessions,
        rng,
        deck,
        stats,
        phaseValue
    )
        local sessionCount = #sessions
        local state = {
            schemaVersion = SCHEMA_VERSION,
            kind = KIND,
            setupId = setupId,
            phase = phase,
            sessionNumber = phase == "battleReady" and sessionCount + 1 or sessionCount,
            rng = {
                seed = rng.seed,
                cursor = rng.cursor,
            },
            playerCardIds = copyArray(deck),
            perkIds = {},
            stats = {
                completed = stats.completed,
                victories = stats.victories,
                defeats = stats.defeats,
            },
            sessions = sessions,
            lastSettlement = makeSessionRecord(sessions[sessionCount]),
        }
        if phase == "reward" then
            state.rewardOffer = phaseValue
        elseif phase == "characterSelect" then
            state.characterOffer = phaseValue
        elseif phase == "battleReady" then
            state.battleSpec = phaseValue
        end
        return state
    end

    local function replaySessions(setup, staticData, staticInput, playerPool, characterPool, sessionInput)
        local sessionShapeErrors = {}
        local sessionCount = denseArrayLength(sessionInput, "$.state.sessions", sessionShapeErrors)
        if sessionCount ~= nil and (sessionCount < 1 or sessionCount > MAX_SESSIONS) then
            appendError(
                sessionShapeErrors,
                "invalid_session_count",
                "$.state.sessions",
                "runProgression에는 1개 이상 999개 이하의 정산 이력이 필요합니다."
            )
        end
        if #sessionShapeErrors > 0 then
            return nil, sessionShapeErrors
        end

        local initialSpec, initialSpecErrors = buildInitialBattleSpec(setup, staticInput)
        if initialSpecErrors then
            return nil, initialSpecErrors
        end
        local _, _, initialDeckErrors = countDeck(
            setup.selectedCardIds,
            playerPool,
            "$.gameSetup.selectedCardIds"
        )
        if initialDeckErrors then
            return nil, initialDeckErrors
        end
        local rng = {
            seed = setup.rng.seed,
            cursor = setup.rng.cursor,
        }
        local deck = copyArray(setup.selectedCardIds)
        local currentSpec = initialSpec
        local stats = {
            completed = 0,
            victories = 0,
            defeats = 0,
        }
        local canonicalSessions = {}

        for sessionIndex = 1, sessionCount do
            local inputRecord = sessionInput[sessionIndex]
            local recordPath = "$.state.sessions[" .. sessionIndex .. "]"
            if type(inputRecord) ~= "table" or getmetatable(inputRecord) ~= nil then
                return nil, {
                    makeError("invalid_session_record", recordPath, "정산 이력 항목은 일반 객체여야 합니다."),
                }
            end
            local recordErrors = {}
            checkAllowedKeys(
                inputRecord,
                {
                    battleId = true,
                    turnId = true,
                    characterId = true,
                    status = true,
                    reasonCode = true,
                    turnNumber = true,
                    turnLimit = true,
                    finalStealth = true,
                    finalResistance = true,
                    transit = true,
                    rewardChoice = true,
                    nextCharacterId = true,
                },
                recordPath,
                recordErrors
            )
            if #recordErrors > 0 then
                return nil, recordErrors
            end

            local settlementInput, settlementCopyError = copySettlementFromRecord(
                inputRecord,
                recordPath
            )
            if settlementCopyError then
                return nil, { settlementCopyError }
            end
            local settlement, settlementErrors = normalizeSummary(
                settlementInput,
                staticData,
                recordPath
            )
            if settlementErrors then
                return nil, settlementErrors
            end
            local matchErrors = summaryMatchesSpec(
                settlement,
                currentSpec,
                recordPath
            )
            if #matchErrors > 0 then
                return nil, matchErrors
            end

            stats.completed = stats.completed + 1
            if settlement.status == "victory" then
                stats.victories = stats.victories + 1
            else
                stats.defeats = stats.defeats + 1
            end

            local canonicalRecord = makeSessionRecord(settlement)
            canonicalSessions[sessionIndex] = canonicalRecord

            if settlement.status == "victory" then
                local rewardOffer, afterRewardRng, rewardErrors = generateRewardOffer(
                    setup.setupId,
                    sessionIndex,
                    rng,
                    settlement,
                    deck,
                    playerPool
                )
                if rewardErrors then
                    return nil, rewardErrors
                end
                rng = afterRewardRng

                if inputRecord.rewardChoice == nil then
                    if sessionIndex ~= sessionCount then
                        return nil, {
                            makeError(
                                "incomplete_historical_session",
                                recordPath .. ".rewardChoice",
                                "마지막 항목이 아닌 승리 정산 이력에는 보상 선택이 필요합니다."
                            ),
                        }
                    end
                    return buildState(
                        setup.setupId,
                        "reward",
                        canonicalSessions,
                        rng,
                        deck,
                        stats,
                        rewardOffer
                    ), nil
                end

                local rewardChoice, choiceErrors = validateRewardChoice(
                    inputRecord.rewardChoice,
                    recordPath .. ".rewardChoice"
                )
                if choiceErrors then
                    return nil, choiceErrors
                end
                local nextDeck, applyErrors = applyRewardChoice(
                    rewardOffer,
                    rewardChoice,
                    deck,
                    playerPool,
                    recordPath .. ".rewardChoice"
                )
                if applyErrors then
                    return nil, applyErrors
                end
                deck = nextDeck
                canonicalRecord.rewardChoice = rewardChoice
            else
                if inputRecord.rewardChoice ~= nil then
                    local rewardChoice, choiceErrors = validateRewardChoice(
                        inputRecord.rewardChoice,
                        recordPath .. ".rewardChoice"
                    )
                    if choiceErrors then
                        return nil, choiceErrors
                    end
                    if rewardChoice.kind ~= "none" then
                        return nil, {
                            makeError(
                                "reward_not_allowed_after_defeat",
                                recordPath .. ".rewardChoice",
                                "패배한 세션에서는 카드 보상을 획득할 수 없습니다."
                            ),
                        }
                    end
                end
                canonicalRecord.rewardChoice = {
                    kind = "none",
                }
            end

            local characterOffer, afterCharacterRng, characterErrors = generateCharacterOffer(
                setup.setupId,
                sessionIndex,
                rng,
                settlement,
                deck,
                characterPool
            )
            if characterErrors then
                return nil, characterErrors
            end
            rng = afterCharacterRng

            if inputRecord.nextCharacterId == nil then
                if sessionIndex ~= sessionCount then
                    return nil, {
                        makeError(
                            "incomplete_historical_session",
                            recordPath .. ".nextCharacterId",
                            "마지막 항목이 아닌 정산 이력에는 다음 대상 선택이 필요합니다."
                        ),
                    }
                end
                return buildState(
                    setup.setupId,
                    "characterSelect",
                    canonicalSessions,
                    rng,
                    deck,
                    stats,
                    characterOffer
                ), nil
            end
            if not isAsciiId(inputRecord.nextCharacterId)
                or not contains(characterOffer.characterIds, inputRecord.nextCharacterId) then
                return nil, {
                    makeError(
                        "character_not_in_replayed_offer",
                        recordPath .. ".nextCharacterId",
                        "다음 대상이 결정적으로 재생한 캐릭터 후보에 포함되지 않습니다."
                    ),
                }
            end
            canonicalRecord.nextCharacterId = inputRecord.nextCharacterId

            if sessionIndex >= MAX_SESSIONS then
                return nil, {
                    makeError(
                        "session_limit_reached",
                        recordPath .. ".nextCharacterId",
                        "세션 번호 999 뒤에는 새 전투를 만들 수 없습니다."
                    ),
                }
            end
            local battleSeed, afterSeedRng, seedErrors = generateBattleSeed(rng)
            if seedErrors then
                return nil, seedErrors
            end
            rng = afterSeedRng
            local nextSpec, specErrors = buildBattleSpec(
                setup.setupId,
                sessionIndex + 1,
                battleSeed,
                inputRecord.nextCharacterId,
                deck,
                staticInput
            )
            if specErrors then
                return nil, specErrors
            end
            currentSpec = nextSpec

            if sessionIndex == sessionCount then
                return buildState(
                    setup.setupId,
                    "battleReady",
                    canonicalSessions,
                    rng,
                    deck,
                    stats,
                    currentSpec
                ), nil
            end
        end
        return nil, {
            makeError("missing_progression_state", "$.state", "정산 이력에서 runProgression 상태를 재생하지 못했습니다."),
        }
    end

    local function validateStateShape(state, setupId)
        local errors = {}
        validateJson(state, "$.state", errors, {})
        if type(state) ~= "table" or getmetatable(state) ~= nil then
            return errors
        end
        checkAllowedKeys(state, {
            schemaVersion = true,
            kind = true,
            setupId = true,
            phase = true,
            sessionNumber = true,
            rng = true,
            playerCardIds = true,
            perkIds = true,
            stats = true,
            sessions = true,
            lastSettlement = true,
            rewardOffer = true,
            characterOffer = true,
            battleSpec = true,
        }, "$.state", errors)

        if state.schemaVersion ~= SCHEMA_VERSION then
            appendError(errors, "unsupported_schema_version", "$.state.schemaVersion", "지원하지 않는 runProgression 스키마입니다.")
        end
        if state.kind ~= KIND then
            appendError(errors, "invalid_state_kind", "$.state.kind", "상태 kind는 runProgressionV1이어야 합니다.")
        end
        if state.setupId ~= setupId then
            appendError(errors, "setup_identity_mismatch", "$.state.setupId", "상태가 원본 gameSetup에 속하지 않습니다.")
        end
        if state.phase ~= "reward"
            and state.phase ~= "characterSelect"
            and state.phase ~= "battleReady" then
            appendError(errors, "invalid_phase", "$.state.phase", "지원하지 않는 runProgression phase입니다.")
        end
        if not isSafeInteger(state.sessionNumber, 1) or state.sessionNumber > MAX_SESSIONS then
            appendError(errors, "invalid_session_number", "$.state.sessionNumber", "세션 번호는 1 이상 999 이하여야 합니다.")
        end

        if type(state.rng) ~= "table" or getmetatable(state.rng) ~= nil then
            appendError(errors, "invalid_rng", "$.state.rng", "progression rng는 일반 객체여야 합니다.")
        else
            checkAllowedKeys(state.rng, { seed = true, cursor = true }, "$.state.rng", errors)
            if not isSafeInteger(state.rng.seed, 0) then
                appendError(errors, "invalid_rng_seed", "$.state.rng.seed", "progression RNG seed가 올바르지 않습니다.")
            end
            if not isSafeInteger(state.rng.cursor, 0) then
                appendError(errors, "invalid_rng_cursor", "$.state.rng.cursor", "progression RNG cursor가 올바르지 않습니다.")
            end
        end

        local perkCount = denseArrayLength(state.perkIds, "$.state.perkIds", errors)
        if perkCount ~= nil and perkCount ~= 0 then
            appendError(errors, "unsupported_perks", "$.state.perkIds", "현재 progression 버전의 perkIds는 빈 배열이어야 합니다.")
        end

        if type(state.stats) ~= "table" or getmetatable(state.stats) ~= nil then
            appendError(errors, "invalid_stats", "$.state.stats", "누적 전적은 일반 객체여야 합니다.")
        else
            checkAllowedKeys(
                state.stats,
                { completed = true, victories = true, defeats = true },
                "$.state.stats",
                errors
            )
            for _, field in ipairs({ "completed", "victories", "defeats" }) do
                if not isSafeInteger(state.stats[field], 0) then
                    appendError(errors, "invalid_stat", "$.state.stats." .. field, "누적 전적은 0 이상의 정수여야 합니다.")
                end
            end
            if isSafeInteger(state.stats.completed, 0)
                and isSafeInteger(state.stats.victories, 0)
                and isSafeInteger(state.stats.defeats, 0)
                and state.stats.completed ~= state.stats.victories + state.stats.defeats then
                appendError(errors, "stats_total_mismatch", "$.state.stats", "완료 세션 수가 승리와 패배 합계와 다릅니다.")
            end
        end

        local sessionCount = denseArrayLength(state.sessions, "$.state.sessions", errors)
        if sessionCount ~= nil and (sessionCount < 1 or sessionCount > MAX_SESSIONS) then
            appendError(errors, "invalid_session_count", "$.state.sessions", "정산 이력 개수가 올바르지 않습니다.")
        end
        if state.phase == "reward" then
            if state.rewardOffer == nil then
                appendError(errors, "missing_reward_offer", "$.state.rewardOffer", "reward phase에는 보상 제안이 필요합니다.")
            end
            if state.characterOffer ~= nil or state.battleSpec ~= nil then
                appendError(errors, "unexpected_phase_field", "$.state", "reward phase에는 다른 phase 자료를 넣을 수 없습니다.")
            end
        elseif state.phase == "characterSelect" then
            if state.characterOffer == nil then
                appendError(errors, "missing_character_offer", "$.state.characterOffer", "characterSelect phase에는 대상 후보가 필요합니다.")
            end
            if state.rewardOffer ~= nil or state.battleSpec ~= nil then
                appendError(errors, "unexpected_phase_field", "$.state", "characterSelect phase에는 다른 phase 자료를 넣을 수 없습니다.")
            end
        elseif state.phase == "battleReady" then
            if state.battleSpec == nil then
                appendError(errors, "missing_battle_spec", "$.state.battleSpec", "battleReady phase에는 다음 전투 사양이 필요합니다.")
            end
            if state.rewardOffer ~= nil or state.characterOffer ~= nil then
                appendError(errors, "unexpected_phase_field", "$.state", "battleReady phase에는 다른 phase 자료를 넣을 수 없습니다.")
            end
        end
        return errors
    end

    local function validateAndReplay(
        stateInput,
        setup,
        staticData,
        staticInput,
        playerPool,
        characterPool
    )
        local state, cloneError = cloneJson(stateInput, "$.state")
        if cloneError then
            return nil, { cloneError }
        end
        local shapeErrors = validateStateShape(state, setup.setupId)
        if #shapeErrors > 0 then
            return nil, shapeErrors
        end
        local expected, replayErrors = replaySessions(
            setup,
            staticData,
            staticInput,
            playerPool,
            characterPool,
            state.sessions
        )
        if replayErrors then
            return nil, replayErrors
        end
        if not deepEqual(state, expected) then
            return nil, {
                makeError(
                    "progression_state_replay_mismatch",
                    "$.state",
                    "저장된 runProgression 상태가 원본 setup과 선택 이력으로 재생한 canonical 상태와 다릅니다."
                ),
            }
        end
        return expected, nil
    end

    local function validateClaimCommand(commandInput)
        local command, cloneError = cloneJson(commandInput, "$.command")
        if cloneError then
            return nil, { cloneError }
        end
        local errors = {}
        if type(command) ~= "table" or getmetatable(command) ~= nil then
            appendError(errors, "invalid_command", "$.command", "보상 선택 명령은 일반 객체여야 합니다.")
            return nil, errors
        end
        checkAllowedKeys(
            command,
            { cardId = true, interactionToken = true },
            "$.command",
            errors
        )
        if not isAsciiId(command.cardId) then
            appendError(
                errors,
                "invalid_command_card",
                "$.command.cardId",
                "보상 선택에는 플레이어 cardId 또는 continue가 필요합니다."
            )
        end
        if type(command.interactionToken) ~= "string"
            or string.match(
                command.interactionToken,
                "^run%-progression%-reward%-v1:%d+:%d+:%d+$"
            ) == nil then
            appendError(errors, "invalid_command_token", "$.command.interactionToken", "보상 interactionToken 형식이 올바르지 않습니다.")
        end
        if #errors > 0 then
            return nil, errors
        end
        return command, nil
    end

    local function validateCharacterCommand(commandInput)
        local command, cloneError = cloneJson(commandInput, "$.command")
        if cloneError then
            return nil, { cloneError }
        end
        local errors = {}
        if type(command) ~= "table" or getmetatable(command) ~= nil then
            appendError(errors, "invalid_command", "$.command", "대상 선택 명령은 일반 객체여야 합니다.")
            return nil, errors
        end
        checkAllowedKeys(
            command,
            { characterId = true, interactionToken = true },
            "$.command",
            errors
        )
        if not isAsciiId(command.characterId) then
            appendError(errors, "invalid_command_character", "$.command.characterId", "대상 선택에는 characterId가 필요합니다.")
        end
        if type(command.interactionToken) ~= "string"
            or string.match(
                command.interactionToken,
                "^run%-progression%-character%-v1:%d+:%d+:%d+$"
            ) == nil then
            appendError(errors, "invalid_command_token", "$.command.interactionToken", "대상 interactionToken 형식이 올바르지 않습니다.")
        end
        if #errors > 0 then
            return nil, errors
        end
        return command, nil
    end

    local function settle(currentInput, setupInput, summaryInput, staticInput)
        local setup, staticData, playerPool, characterPool, setupErrors =
            validateSetup(setupInput, staticInput)
        if setupErrors then
            return failure(setupErrors)
        end
        local summary, summaryErrors = normalizeSummary(summaryInput, staticData, "$.summary")
        if summaryErrors then
            return failure(summaryErrors)
        end

        local sessions
        local current
        if currentInput == nil then
            local initialSpec, specErrors = buildInitialBattleSpec(setup, staticInput)
            if specErrors then
                return failure(specErrors)
            end
            local matchErrors = summaryMatchesSpec(summary, initialSpec, "$.summary")
            if #matchErrors > 0 then
                return failure(matchErrors)
            end
            sessions = {
                makeSessionRecord(summary),
            }
        else
            local currentErrors
            current, currentErrors = validateAndReplay(
                currentInput,
                setup,
                staticData,
                staticInput,
                playerPool,
                characterPool
            )
            if currentErrors then
                return failure(currentErrors)
            end
            if current.lastSettlement.battleId == summary.battleId
                and current.lastSettlement.turnId == summary.turnId then
                if not deepEqual(current.lastSettlement, summary) then
                    return failure({
                        makeError(
                            "settlement_receipt_conflict",
                            "$.summary",
                            "같은 battleId와 turnId의 정산 summary가 이미 저장된 내용과 다릅니다."
                        ),
                    })
                end
                return success(current, false, true)
            end
            if current.phase ~= "battleReady" then
                return failure({
                    makeError(
                        "different_settlement_while_pending",
                        "$.summary",
                        "현재 정산의 보상과 다음 대상 선택을 마치기 전에는 다른 전투를 정산할 수 없습니다."
                    ),
                })
            end
            local matchErrors = summaryMatchesSpec(summary, current.battleSpec, "$.summary")
            if #matchErrors > 0 then
                return failure(matchErrors)
            end
            sessions = {}
            for index, record in ipairs(current.sessions) do
                local recordCopy, recordError = cloneJson(record, "$.state.sessions[" .. index .. "]")
                if recordError then
                    return failure({ recordError })
                end
                sessions[index] = recordCopy
            end
            sessions[#sessions + 1] = makeSessionRecord(summary)
        end

        local nextState, replayErrors = replaySessions(
            setup,
            staticData,
            staticInput,
            playerPool,
            characterPool,
            sessions
        )
        if replayErrors then
            return failure(replayErrors)
        end
        return success(nextState, true, false)
    end

    local function claimReward(currentInput, setupInput, commandInput, staticInput)
        local command, commandErrors = validateClaimCommand(commandInput)
        if commandErrors then
            return failure(commandErrors)
        end
        local setup, staticData, playerPool, characterPool, setupErrors =
            validateSetup(setupInput, staticInput)
        if setupErrors then
            return failure(setupErrors)
        end
        local current, currentErrors = validateAndReplay(
            currentInput,
            setup,
            staticData,
            staticInput,
            playerPool,
            characterPool
        )
        if currentErrors then
            return failure(currentErrors)
        end
        if current.phase ~= "reward"
            or command.interactionToken ~= current.rewardOffer.interactionToken then
            return success(current, false, true)
        end

        local choice
        if command.cardId == "continue" then
            choice = {
                kind = "none",
            }
        else
            choice = {
                kind = "card",
            }
            choice.cardId = command.cardId
        end
        local _, applyErrors = applyRewardChoice(
            current.rewardOffer,
            choice,
            current.playerCardIds,
            playerPool,
            "$.command"
        )
        if applyErrors then
            return failure(applyErrors)
        end

        local sessions, sessionsError = cloneJson(current.sessions, "$.state.sessions")
        if sessionsError then
            return failure({ sessionsError })
        end
        sessions[#sessions].rewardChoice = choice
        local nextState, replayErrors = replaySessions(
            setup,
            staticData,
            staticInput,
            playerPool,
            characterPool,
            sessions
        )
        if replayErrors then
            return failure(replayErrors)
        end
        return success(nextState, true, false)
    end

    local function chooseCharacter(currentInput, setupInput, commandInput, staticInput)
        local command, commandErrors = validateCharacterCommand(commandInput)
        if commandErrors then
            return failure(commandErrors)
        end
        local setup, staticData, playerPool, characterPool, setupErrors =
            validateSetup(setupInput, staticInput)
        if setupErrors then
            return failure(setupErrors)
        end
        local current, currentErrors = validateAndReplay(
            currentInput,
            setup,
            staticData,
            staticInput,
            playerPool,
            characterPool
        )
        if currentErrors then
            return failure(currentErrors)
        end
        if current.phase ~= "characterSelect"
            or command.interactionToken ~= current.characterOffer.interactionToken then
            return success(current, false, true)
        end
        if not contains(current.characterOffer.characterIds, command.characterId) then
            return failure({
                makeError(
                    "character_not_in_offer",
                    "$.command.characterId",
                    "선택한 캐릭터가 현재 대상 후보에 없습니다."
                ),
            })
        end

        local sessions, sessionsError = cloneJson(current.sessions, "$.state.sessions")
        if sessionsError then
            return failure({ sessionsError })
        end
        sessions[#sessions].nextCharacterId = command.characterId
        local nextState, replayErrors = replaySessions(
            setup,
            staticData,
            staticInput,
            playerPool,
            characterPool,
            sessions
        )
        if replayErrors then
            return failure(replayErrors)
        end
        return success(nextState, true, false)
    end

    local function validateState(currentInput, setupInput, staticInput)
        local setup, staticData, playerPool, characterPool, setupErrors =
            validateSetup(setupInput, staticInput)
        if setupErrors then
            return failure(setupErrors)
        end
        if currentInput == nil then
            return failure({
                makeError("missing_progression_state", "$.state", "검증할 runProgression 상태가 필요합니다."),
            })
        end
        local current, currentErrors = validateAndReplay(
            currentInput,
            setup,
            staticData,
            staticInput,
            playerPool,
            characterPool
        )
        if currentErrors then
            return failure(currentErrors)
        end
        return success(current, false, false)
    end

    local arguments = { ... }
    if action == "settle" then
        return settle(arguments[1], arguments[2], arguments[3], arguments[4])
    elseif action == "claimReward" then
        return claimReward(arguments[1], arguments[2], arguments[3], arguments[4])
    elseif action == "chooseCharacter" then
        return chooseCharacter(arguments[1], arguments[2], arguments[3], arguments[4])
    elseif action == "validate" then
        return validateState(arguments[1], arguments[2], arguments[3])
    end
    return failure({
        makeError(
            "unknown_action",
            "$.action",
            "지원하지 않는 runProgression 작업입니다: " .. tostring(action)
        ),
    })
end)
