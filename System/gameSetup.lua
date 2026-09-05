(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local KIND = "gameSetupV1"
    local TOTAL_DRAFTS = 10
    local OFFER_SIZE = 3
    local MINIMUM_POOL_SIZE = 7
    local RARITY_WEIGHTS = { common = 80, rare = 10, legendary = 1 }
    local RARITY_ORDER = { "common", "rare", "legendary" }
    local CHARACTER_OFFER_SIZE = 3
    local MINIMUM_CHARACTER_POOL_SIZE = 3
    local BATTLE_SEED_MODULUS = 2147483646
    local BATTLE_SEED_DOMAIN_OFFSET = 104729
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
            errors = errors,
        }
    end

    local function success(state, applied, stale)
        local report = {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            state = state,
        }
        if applied ~= nil then
            report.applied = applied
        end
        if stale ~= nil then
            report.stale = stale
        end
        return report
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

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
    end

    local function isInteractionToken(value)
        return type(value) == "string"
            and string.match(value, "^game%-setup%-draft%-v1:%d+:%d+:%d+$") ~= nil
    end

    local function isCharacterInteractionToken(value)
        return type(value) == "string"
            and string.match(value, "^game%-setup%-character%-v1:%d+:%d+:%d+$") ~= nil
    end

    local function appendError(errors, code, path, message)
        errors[#errors + 1] = makeError(code, path, message)
    end

    local function appendNestedErrors(errors, nested, fallbackPath)
        if type(nested) ~= "table" then
            appendError(errors, "invalid_nested_errors", fallbackPath, "하위 모듈의 오류 목록이 올바르지 않습니다.")
            return
        end
        for _, item in ipairs(nested) do
            errors[#errors + 1] = {
                code = tostring(type(item) == "table" and item.code or "nested_error"),
                path = tostring(type(item) == "table" and item.path or fallbackPath),
                message = tostring(type(item) == "table" and item.message or "하위 모듈 작업이 실패했습니다."),
            }
        end
    end

    local function pathForKey(path, key)
        if type(key) == "string" and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        if type(key) == "string" or type(key) == "number" or type(key) == "boolean" then
            return path .. "[" .. string.format("%q", tostring(key)) .. "]"
        end
        return path .. "[<" .. type(key) .. ">]"
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
                    appendError(errors, "invalid_array_index", path, "배열 인덱스는 1 이상의 연속된 정수여야 합니다.")
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
        if valueType == "string" or valueType == "boolean" then
            return
        end
        if valueType == "number" then
            if not isFinite(value) then
                appendError(errors, "non_finite_number", path, "NaN과 무한대는 JSON 상태에 저장할 수 없습니다.")
            end
            return
        end
        if valueType ~= "table" then
            appendError(errors, "unsupported_type", path, "JSON 상태에 저장할 수 없는 자료형입니다: " .. valueType)
            return
        end
        if getmetatable(value) ~= nil then
            appendError(errors, "metatable_not_allowed", path, "JSON 값에는 메타테이블을 사용할 수 없습니다.")
            return
        end

        active = active or {}
        if active[value] then
            appendError(errors, "circular_reference", path, "순환 참조가 있는 JSON 값은 사용할 수 없습니다.")
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
                validateJson(value[key], pathForKey(path, key), errors, active)
            end
        end
        active[value] = nil
    end

    local function checkAllowedKeys(value, allowed, path, errors)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                appendError(errors, "unknown_field", pathForKey(path, key), "허용되지 않은 필드입니다.")
            end
        end
    end

    local function denseArrayLength(value, path, errors)
        local kind, length = inspectJsonTable(value, path, errors)
        -- Lua의 빈 테이블은 빈 객체와 빈 배열을 구분할 수 없으므로,
        -- 배열을 요구하는 이 문맥에서는 빈 테이블을 길이 0으로 해석한다.
        if kind == "object" and type(length) == "table" and #length == 0 then
            return 0
        end
        if kind ~= "array" then
            if kind ~= nil then
                appendError(errors, "expected_array", path, "1부터 시작하는 연속 배열이어야 합니다.")
            end
            return nil
        end
        return length
    end

    local function cloneJson(value, path, active)
        local valueType = type(value)
        if valueType ~= "table" then
            return value
        end
        active = active or {}
        if active[value] then
            error(makeError("circular_reference", path, "순환 참조가 있는 값을 복제할 수 없습니다."), 0)
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = cloneJson(item, pathForKey(path, key), active)
        end
        active[value] = nil
        return copy
    end

    local function cloneChecked(value, path)
        local ok, copy = pcall(cloneJson, value, path or "$", {})
        if not ok then
            if type(copy) == "table" and copy.code then
                return nil, copy
            end
            return nil, makeError("clone_failed", path or "$", "JSON 값 복제에 실패했습니다: " .. tostring(copy))
        end
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
        seen[left] = seen[left] or {}
        if seen[left][right] then
            return true
        end
        seen[left][right] = true
        for key, item in pairs(left) do
            if not deepEqual(item, right[key], seen) then
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
        if type(staticData) == "table"
            and getmetatable(staticData) == nil
            and type(rawget(staticData, "data")) == "table" then
            return rawget(staticData, "data")
        end
        return staticData
    end

    local function buildPlayerPool(staticInput)
        local errors = {}
        local staticData = normalizeStaticData(staticInput)
        if type(staticData) ~= "table" or getmetatable(staticData) ~= nil then
            appendError(errors, "invalid_static_data", "$.staticData", "정적 데이터는 메타테이블이 없는 테이블이어야 합니다.")
            return nil, errors
        end
        local cards = rawget(staticData, "cards")
        if type(cards) ~= "table" or getmetatable(cards) ~= nil then
            appendError(errors, "invalid_card_database", "$.staticData.cards", "cards는 메타테이블이 없는 카드 맵이어야 합니다.")
            return nil, errors
        end

        local cardIds = {}
        local cardsById = {}
        for cardId, card in pairs(cards) do
            local cardPath = pathForKey("$.staticData.cards", cardId)
            if type(cardId) ~= "string" then
                appendError(errors, "invalid_card_key", "$.staticData.cards", "카드 맵 키는 ASCII ID 문자열이어야 합니다.")
            elseif type(card) ~= "table" or getmetatable(card) ~= nil then
                appendError(errors, "invalid_card_record", cardPath, "카드 레코드는 메타테이블이 없는 테이블이어야 합니다.")
            elseif rawget(card, "owner") == "player" then
                if not isAsciiId(cardId) then
                    appendError(errors, "invalid_player_card_id", cardPath, "플레이어 카드 키는 ASCII cardId여야 합니다.")
                elseif RARITY_WEIGHTS[card.rarity] == nil then
                    appendError(errors, "invalid_player_card_rarity", cardPath .. ".rarity", "플레이어 카드 희귀도는 common, rare 또는 legendary여야 합니다.")
                elseif not isAsciiId(card.draftStyle) then
                    appendError(errors, "invalid_player_card_style", cardPath .. ".draftStyle", "플레이어 카드에는 ASCII draftStyle이 필요합니다.")
                else
                    cardIds[#cardIds + 1] = cardId
                    cardsById[cardId] = {
                        rarity = card.rarity,
                        draftStyle = card.draftStyle,
                        maxCopies = card.rarity == "legendary" and 1 or 2,
                    }
                end
            end
        end
        table.sort(cardIds)
        if #cardIds < MINIMUM_POOL_SIZE then
            appendError(
                errors,
                "insufficient_player_card_pool",
                "$.staticData.cards",
                "10회 드래프트에서 항상 3장을 제시하려면 플레이어 카드가 최소 7종 필요합니다."
            )
        end
        if #errors > 0 then
            return nil, errors
        end
        return { cardIds = cardIds, cardsById = cardsById }, nil
    end

    local function buildCharacterPool(staticInput)
        local errors = {}
        local staticData = normalizeStaticData(staticInput)
        if type(staticData) ~= "table" or getmetatable(staticData) ~= nil then
            appendError(errors, "invalid_static_data", "$.staticData", "정적 데이터는 메타테이블이 없는 테이블이어야 합니다.")
            return nil, errors
        end
        local characters = rawget(staticData, "characters")
        if type(characters) ~= "table" or getmetatable(characters) ~= nil then
            appendError(errors, "invalid_character_database", "$.staticData.characters", "characters는 메타테이블이 없는 캐릭터 맵이어야 합니다.")
            return nil, errors
        end

        local pool = {}
        for characterId, character in pairs(characters) do
            local characterPath = pathForKey("$.staticData.characters", characterId)
            if type(characterId) ~= "string" or not isAsciiId(characterId) then
                appendError(errors, "invalid_character_id", characterPath, "캐릭터 맵 키는 lower_snake_case ASCII ID여야 합니다.")
            elseif type(character) ~= "table" or getmetatable(character) ~= nil then
                appendError(errors, "invalid_character_record", characterPath, "캐릭터 레코드는 메타테이블이 없는 테이블이어야 합니다.")
            else
                pool[#pool + 1] = characterId
            end
        end
        table.sort(pool)
        if #pool < MINIMUM_CHARACTER_POOL_SIZE then
            appendError(
                errors,
                "insufficient_character_pool",
                "$.staticData.characters",
                "캐릭터 선택에서는 서로 다른 후보가 최소 3명 필요합니다."
            )
        end
        if #errors > 0 then
            return nil, errors
        end
        return pool, nil
    end

    local function callNextIntegers(rng, ranges)
        if type(runScript) ~= "function" then
            return nil, nil, {
                makeError("runtime_unavailable", "$.runtime.deterministicRng", "deterministicRng를 호출할 runScript가 없습니다."),
            }
        end
        local ok, report = pcall(
            runScript,
            triggerId,
            "deterministicRng",
            "nextIntegers",
            rng,
            ranges
        )
        if not ok then
            return nil, nil, {
                makeError("module_call_failed", "$.runtime.deterministicRng", "deterministicRng.nextIntegers 호출에 실패했습니다: " .. tostring(report)),
            }
        end
        if type(report) ~= "table" then
            return nil, nil, {
                makeError("invalid_module_result", "$.runtime.deterministicRng", "deterministicRng가 테이블 결과를 반환하지 않았습니다."),
            }
        end
        if report.ok ~= true then
            local errors = {}
            appendNestedErrors(errors, report.errors, "$.runtime.deterministicRng")
            return nil, nil, errors
        end

        local errors = {}
        local valueCount = denseArrayLength(report.value, "$.runtime.deterministicRng.value", errors)
        if valueCount ~= #ranges then
            appendError(
                errors,
                "invalid_rng_batch_size",
                "$.runtime.deterministicRng.value",
                "deterministicRng의 batch 결과 개수가 요청 개수와 다릅니다."
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
                        "deterministicRng의 batch 결과가 요청 범위를 벗어났습니다."
                    )
                end
            end
        end
        if type(report.rng) ~= "table"
            or not isSafeInteger(report.rng.seed, 0)
            or not isSafeInteger(report.rng.cursor, 0)
            or report.rng.seed ~= rng.seed
            or report.rng.cursor <= rng.cursor then
            appendError(errors, "invalid_rng_result", "$.runtime.deterministicRng", "deterministicRng의 결과 계약이 올바르지 않습니다.")
        end
        if #errors > 0 then
            return nil, nil, errors
        end
        local values = {}
        for index = 1, valueCount do
            values[index] = report.value[index]
        end
        return values, {
            seed = report.rng.seed,
            cursor = report.rng.cursor,
        }, nil
    end

    local function buildToken(setupId, round, rng, selectedCardIds, offerCardIds)
        local parts = {
            "setupId=", tostring(#setupId), ":", setupId,
            "|round=", tostring(round),
            "|cursor=", tostring(rng.cursor),
            "|selected=", tostring(#selectedCardIds), ":",
        }
        for _, cardId in ipairs(selectedCardIds) do
            parts[#parts + 1] = tostring(#cardId)
            parts[#parts + 1] = ":"
            parts[#parts + 1] = cardId
            parts[#parts + 1] = ";"
        end
        parts[#parts + 1] = "|offer="
        for _, cardId in ipairs(offerCardIds) do
            parts[#parts + 1] = tostring(#cardId)
            parts[#parts + 1] = ":"
            parts[#parts + 1] = cardId
            parts[#parts + 1] = ";"
        end
        local canonical = table.concat(parts)
        local hashA = 0
        local hashB = 0
        for index = 1, #canonical do
            local byte = string.byte(canonical, index)
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        return "game-setup-draft-v1:" .. tostring(#canonical) .. ":" .. tostring(hashA) .. ":" .. tostring(hashB)
    end

    local function copyArray(array)
        local copy = {}
        for index, item in ipairs(array) do
            copy[index] = item
        end
        return copy
    end

    local function buildCharacterToken(setupId, rng, characterIds)
        local parts = {
            "setupId=", tostring(#setupId), ":", setupId,
            "|cursor=", tostring(rng.cursor),
            "|characters=", tostring(#characterIds), ":",
        }
        for _, characterId in ipairs(characterIds) do
            parts[#parts + 1] = tostring(#characterId)
            parts[#parts + 1] = ":"
            parts[#parts + 1] = characterId
            parts[#parts + 1] = ";"
        end
        local canonical = table.concat(parts)
        local hashA = 0
        local hashB = 0
        for index = 1, #canonical do
            local byte = string.byte(canonical, index)
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        return "game-setup-character-v1:" .. tostring(#canonical) .. ":" .. tostring(hashA) .. ":" .. tostring(hashB)
    end

    local function generateCharacterOffer(setupId, rng, characterPool)
        local candidates = copyArray(characterPool)
        local ranges = {}
        for pick = 1, CHARACTER_OFFER_SIZE do
            ranges[pick] = {
                minimum = 1,
                maximum = #candidates - pick + 1,
            }
        end
        local selectedIndices, nextRng, rngErrors = callNextIntegers(rng, ranges)
        if rngErrors then
            return nil, nil, rngErrors
        end

        local selected = {}
        for pick = 1, CHARACTER_OFFER_SIZE do
            local selectedIndex = selectedIndices[pick]
            selected[pick] = candidates[selectedIndex]
            table.remove(candidates, selectedIndex)
        end
        return {
            characterIds = selected,
            interactionToken = buildCharacterToken(setupId, nextRng, selected),
        }, nextRng, nil
    end

    local function deriveBattleSeed(setupSeed)
        -- 1-based seed 공간 안에서 고정 domain offset만큼 순환한다.
        -- setup RNG cursor와 드래프트/캐릭터 선택 경로는 결과에 관여하지 않는다.
        -- 큰 IEEE-754 안전 정수도 offset 덧셈 전에 범위를 줄여 중간 계산이
        -- MAX_SAFE_INTEGER를 넘지 않게 한다.
        local normalized = (setupSeed - 1) % BATTLE_SEED_MODULUS
        return ((normalized + BATTLE_SEED_DOMAIN_OFFSET) % BATTLE_SEED_MODULUS) + 1
    end

    local function buildBattleSpec(setupId, setupSeed)
        return {
            battleId = "battle-" .. setupId,
            seed = deriveBattleSeed(setupSeed),
        }
    end

    local function chooseOne(rng, candidates)
        local values, nextRng, errors = callNextIntegers(rng, {
            { minimum = 1, maximum = #candidates },
        })
        if errors then return nil, nil, errors end
        return candidates[values[1]], nextRng, nil
    end

    local function chooseRarity(rng)
        local total = 0
        for _, rarity in ipairs(RARITY_ORDER) do total = total + RARITY_WEIGHTS[rarity] end
        local values, nextRng, errors = callNextIntegers(rng, {
            { minimum = 1, maximum = total },
        })
        if errors then return nil, nil, errors end
        local cumulative = 0
        for _, rarity in ipairs(RARITY_ORDER) do
            cumulative = cumulative + RARITY_WEIGHTS[rarity]
            if values[1] <= cumulative then return rarity, nextRng, nil end
        end
    end

    local function eligibleCards(pool, counts, excluded, rarity, style)
        local candidates = {}
        for _, cardId in ipairs(pool.cardIds) do
            local card = pool.cardsById[cardId]
            if card.rarity == rarity
                and (style == nil or card.draftStyle == style)
                and excluded[cardId] ~= true
                and (counts[cardId] or 0) < card.maxCopies then
                candidates[#candidates + 1] = cardId
            end
        end
        return candidates
    end

    local function rarityFallbacks(rarity)
        if rarity == "legendary" then return { "legendary", "rare", "common" } end
        if rarity == "rare" then return { "rare", "common" } end
        return { "common", "rare", "legendary" }
    end

    local function generateOffer(setupId, round, rng, selectedCardIds, counts, pool)
        local totalEligible = 0
        for _, cardId in ipairs(pool.cardIds) do
            local card = pool.cardsById[cardId]
            if (counts[cardId] or 0) < card.maxCopies then totalEligible = totalEligible + 1 end
        end
        if totalEligible < OFFER_SIZE then
            return nil, nil, {
                makeError("insufficient_eligible_cards", "$.selectedCardIds", "복제 제한을 지키며 3장을 제시할 수 없습니다."),
            }
        end

        local offered = {}
        local excluded = {}
        local currentRng = rng
        local anchorStyle = nil
        if round > 1 then
            local anchorId = selectedCardIds[#selectedCardIds]
            anchorStyle = pool.cardsById[anchorId].draftStyle
        end
        for pick = 1, OFFER_SIZE do
            local rarity, rngErrors
            rarity, currentRng, rngErrors = chooseRarity(currentRng)
            if rngErrors then return nil, nil, rngErrors end
            local requestedStyle = pick == 1 and anchorStyle or nil
            local candidates = {}
            for _, fallbackRarity in ipairs(rarityFallbacks(rarity)) do
                candidates = eligibleCards(pool, counts, excluded, fallbackRarity, requestedStyle)
                if #candidates > 0 then break end
            end
            if #candidates == 0 and requestedStyle ~= nil then
                for _, fallbackRarity in ipairs(rarityFallbacks(rarity)) do
                    candidates = eligibleCards(pool, counts, excluded, fallbackRarity, nil)
                    if #candidates > 0 then break end
                end
            end
            local selectedId
            selectedId, currentRng, rngErrors = chooseOne(currentRng, candidates)
            if rngErrors then return nil, nil, rngErrors end
            offered[pick] = selectedId
            excluded[selectedId] = true
        end
        if anchorStyle ~= nil then
            -- 스타일 우선 카드를 확보한 뒤 표시 위치만 무작위로 바꿉니다.
            local positions, positionErrors
            positions, currentRng, positionErrors = callNextIntegers(currentRng, {
                { minimum = 1, maximum = OFFER_SIZE },
            })
            if positionErrors then return nil, nil, positionErrors end
            local position = positions[1]
            offered[1], offered[position] = offered[position], offered[1]
        end
        return {
            round = round,
            cardIds = offered,
            interactionToken = buildToken(setupId, round, currentRng, selectedCardIds, offered),
        }, currentRng, nil
    end

    local function contains(array, target)
        for _, value in ipairs(array) do
            if value == target then
                return true
            end
        end
        return false
    end

    local function replay(setupId, seed, selectedCardIds, pool)
        -- 저장/복구 경계의 기준 구현이다. seed와 전체 선택 이력만으로
        -- authority를 처음부터 다시 만들며 validate는 항상 이 경로를 쓴다.
        -- 버튼 처리의 다음 상태 생성은 아래 advanceValidatedState에서 현재
        -- 검증이 끝난 RNG cursor부터 이어 가되, 이 구현은 삭제하지 않는다.
        local counts = {}
        local rng = { seed = seed, cursor = 0 }

        for round = 1, TOTAL_DRAFTS do
            local history = {}
            for index = 1, round - 1 do
                history[index] = selectedCardIds[index]
            end
            local offer, nextRng, offerErrors = generateOffer(setupId, round, rng, history, counts, pool)
            if offerErrors then
                return nil, offerErrors
            end
            rng = nextRng

            if round <= #selectedCardIds then
                local selectedId = selectedCardIds[round]
                if not contains(offer.cardIds, selectedId) then
                    return nil, {
                        makeError(
                            "selection_not_in_replayed_offer",
                            "$.selectedCardIds[" .. round .. "]",
                            "선택 이력이 결정적 드래프트 제안과 일치하지 않습니다."
                        ),
                    }
                end
                counts[selectedId] = (counts[selectedId] or 0) + 1
                if counts[selectedId] > pool.cardsById[selectedId].maxCopies then
                    return nil, {
                        makeError("card_copy_limit_exceeded", "$.selectedCardIds[" .. round .. "]", "카드별 보유 제한을 초과했습니다."),
                    }
                end
            else
                return {
                    schemaVersion = SCHEMA_VERSION,
                    kind = KIND,
                    setupId = setupId,
                    phase = "deckDraft",
                    rng = rng,
                    selectedCardIds = copyArray(selectedCardIds),
                    offer = offer,
                }, nil
            end
        end

        return {
            schemaVersion = SCHEMA_VERSION,
            kind = KIND,
            setupId = setupId,
            phase = "deckComplete",
            rng = rng,
            selectedCardIds = copyArray(selectedCardIds),
        }, nil
    end

    local function replayForPhase(setupId, seed, selectedCardIds, pool, phase, characterPool, selectedCharacterId)
        local deckState, deckErrors = replay(setupId, seed, selectedCardIds, pool)
        if deckErrors then
            return nil, deckErrors
        end
        if phase == "deckDraft" or phase == "deckComplete" then
            return deckState, nil
        end
        if deckState.phase ~= "deckComplete" then
            return nil, {
                makeError("character_selection_before_deck_complete", "$.state.phase", "캐릭터 선택은 초기 덱 10장을 완성한 뒤에만 시작할 수 있습니다."),
            }
        end
        if type(characterPool) ~= "table" then
            return nil, {
                makeError("character_pool_unavailable", "$.staticData.characters", "캐릭터 선택을 재생할 캐릭터 풀이 없습니다."),
            }
        end

        local characterOffer, nextRng, offerErrors = generateCharacterOffer(
            setupId,
            deckState.rng,
            characterPool
        )
        if offerErrors then
            return nil, offerErrors
        end
        if phase == "characterSelect" then
            return {
                schemaVersion = SCHEMA_VERSION,
                kind = KIND,
                setupId = setupId,
                phase = "characterSelect",
                rng = nextRng,
                selectedCardIds = copyArray(selectedCardIds),
                characterOffer = characterOffer,
            }, nil
        end
        if phase ~= "battleReady" then
            return nil, {
                makeError("invalid_setup_phase", "$.state.phase", "지원하지 않는 게임 설정 phase입니다."),
            }
        end
        if not contains(characterOffer.characterIds, selectedCharacterId) then
            return nil, {
                makeError("selection_not_in_replayed_character_offer", "$.state.selectedCharacterId", "선택 캐릭터가 결정적으로 재생한 후보에 포함되지 않습니다."),
            }
        end
        return {
            schemaVersion = SCHEMA_VERSION,
            kind = KIND,
            setupId = setupId,
            phase = "battleReady",
            rng = nextRng,
            selectedCardIds = copyArray(selectedCardIds),
            selectedCharacterId = selectedCharacterId,
            battleSpec = buildBattleSpec(setupId, seed),
        }, nil
    end

    local function advanceValidatedState(current, selectedCardId, pool)
        -- current는 같은 choose 호출에서 validateAndReplay를 통과해 얻은
        -- canonical snapshot이다. 외부/저장 값을 이 함수에 직접 넣지 않는다.
        local selected = copyArray(current.selectedCardIds)
        selected[#selected + 1] = selectedCardId

        local counts = {}
        for _, cardId in ipairs(selected) do
            counts[cardId] = (counts[cardId] or 0) + 1
            if counts[cardId] > pool.cardsById[cardId].maxCopies then
                return nil, {
                    makeError(
                        "card_copy_limit_exceeded",
                        "$.selectedCardIds[" .. #selected .. "]",
                        "카드별 보유 제한을 초과했습니다."
                    ),
                }
            end
        end

        if #selected == TOTAL_DRAFTS then
            return {
                schemaVersion = SCHEMA_VERSION,
                kind = KIND,
                setupId = current.setupId,
                phase = "deckComplete",
                rng = {
                    seed = current.rng.seed,
                    cursor = current.rng.cursor,
                },
                selectedCardIds = selected,
            }, nil
        end

        local nextRound = #selected + 1
        local offer, nextRng, offerErrors = generateOffer(
            current.setupId,
            nextRound,
            current.rng,
            selected,
            counts,
            pool
        )
        if offerErrors then
            return nil, offerErrors
        end
        return {
            schemaVersion = SCHEMA_VERSION,
            kind = KIND,
            setupId = current.setupId,
            phase = "deckDraft",
            rng = nextRng,
            selectedCardIds = selected,
            offer = offer,
        }, nil
    end

    local function validateStateShape(state, pool, characterPool)
        local errors = {}
        validateJson(state, "$.state", errors, {})
        if type(state) ~= "table" or getmetatable(state) ~= nil then
            return nil, errors
        end
        checkAllowedKeys(state, {
            schemaVersion = true,
            kind = true,
            setupId = true,
            phase = true,
            rng = true,
            selectedCardIds = true,
            offer = true,
            characterOffer = true,
            selectedCharacterId = true,
            battleSpec = true,
        }, "$.state", errors)

        if state.schemaVersion ~= SCHEMA_VERSION then
            appendError(errors, "unsupported_schema_version", "$.state.schemaVersion", "지원하지 않는 게임 설정 스키마입니다.")
        end
        if state.kind ~= KIND then
            appendError(errors, "invalid_state_kind", "$.state.kind", "게임 설정 상태 kind가 올바르지 않습니다.")
        end
        if not isRuntimeId(state.setupId) then
            appendError(errors, "invalid_setup_id", "$.state.setupId", "setupId는 ASCII 런타임 ID여야 합니다.")
        end
        if state.phase ~= "deckDraft"
            and state.phase ~= "deckComplete"
            and state.phase ~= "characterSelect"
            and state.phase ~= "battleReady" then
            appendError(errors, "invalid_setup_phase", "$.state.phase", "지원하지 않는 게임 설정 phase입니다.")
        end

        if type(state.rng) ~= "table" or getmetatable(state.rng) ~= nil then
            appendError(errors, "invalid_rng", "$.state.rng", "rng는 메타테이블이 없는 테이블이어야 합니다.")
        else
            checkAllowedKeys(state.rng, { seed = true, cursor = true }, "$.state.rng", errors)
            if not isSafeInteger(state.rng.seed, 0) then
                appendError(errors, "invalid_rng_seed", "$.state.rng.seed", "seed는 0 이상의 IEEE-754 안전 정수여야 합니다.")
            end
            if not isSafeInteger(state.rng.cursor, 0) then
                appendError(errors, "invalid_rng_cursor", "$.state.rng.cursor", "cursor는 0 이상의 IEEE-754 안전 정수여야 합니다.")
            end
        end

        local selectedLength = denseArrayLength(state.selectedCardIds, "$.state.selectedCardIds", errors)
        local poolSet = {}
        for _, cardId in ipairs(pool.cardIds) do
            poolSet[cardId] = true
        end
        if selectedLength ~= nil then
            if selectedLength > TOTAL_DRAFTS then
                appendError(errors, "too_many_selected_cards", "$.state.selectedCardIds", "초기 덱은 10장을 초과할 수 없습니다.")
            end
            local counts = {}
            for index = 1, selectedLength do
                local cardId = state.selectedCardIds[index]
                if not isAsciiId(cardId) then
                    appendError(errors, "invalid_selected_card_id", "$.state.selectedCardIds[" .. index .. "]", "선택한 카드 ID가 올바르지 않습니다.")
                elseif not poolSet[cardId] then
                    appendError(errors, "unknown_selected_card", "$.state.selectedCardIds[" .. index .. "]", "현재 플레이어 카드 풀에 없는 카드입니다.")
                else
                    counts[cardId] = (counts[cardId] or 0) + 1
                    if counts[cardId] > pool.cardsById[cardId].maxCopies then
                        appendError(errors, "card_copy_limit_exceeded", "$.state.selectedCardIds[" .. index .. "]", "카드별 보유 제한을 초과했습니다.")
                    end
                end
            end
        end

        local characterPoolSet = {}
        for _, characterId in ipairs(characterPool or {}) do
            characterPoolSet[characterId] = true
        end

        if state.phase == "deckDraft" then
            if selectedLength ~= nil and selectedLength >= TOTAL_DRAFTS then
                appendError(errors, "invalid_draft_progress", "$.state.phase", "10장을 모두 선택한 상태는 deckComplete이어야 합니다.")
            end
            if type(state.offer) ~= "table" or getmetatable(state.offer) ~= nil then
                appendError(errors, "missing_draft_offer", "$.state.offer", "deckDraft 상태에는 현재 제안이 필요합니다.")
            else
                checkAllowedKeys(state.offer, {
                    round = true,
                    cardIds = true,
                    interactionToken = true,
                }, "$.state.offer", errors)
                if not isSafeInteger(state.offer.round, 1) or state.offer.round > TOTAL_DRAFTS then
                    appendError(errors, "invalid_offer_round", "$.state.offer.round", "제안 라운드는 1부터 10 사이의 정수여야 합니다.")
                end
                if selectedLength ~= nil and state.offer.round ~= selectedLength + 1 then
                    appendError(errors, "offer_round_mismatch", "$.state.offer.round", "제안 라운드가 선택 진행도와 일치하지 않습니다.")
                end
                local offerLength = denseArrayLength(state.offer.cardIds, "$.state.offer.cardIds", errors)
                if offerLength ~= nil then
                    if offerLength ~= OFFER_SIZE then
                        appendError(errors, "invalid_offer_size", "$.state.offer.cardIds", "드래프트 제안은 서로 다른 카드 3장이어야 합니다.")
                    end
                    local seen = {}
                    for index = 1, offerLength do
                        local cardId = state.offer.cardIds[index]
                        if not isAsciiId(cardId) or not poolSet[cardId] then
                            appendError(errors, "invalid_offer_card", "$.state.offer.cardIds[" .. index .. "]", "제안 카드가 현재 플레이어 카드 풀에 없습니다.")
                        elseif seen[cardId] then
                            appendError(errors, "duplicate_offer_card", "$.state.offer.cardIds[" .. index .. "]", "한 제안에 같은 카드를 두 번 넣을 수 없습니다.")
                        end
                        seen[cardId] = true
                    end
                end
                if not isInteractionToken(state.offer.interactionToken) then
                    appendError(errors, "invalid_interaction_token", "$.state.offer.interactionToken", "interactionToken 형식이 올바르지 않습니다.")
                end
            end
            if rawget(state, "characterOffer") ~= nil
                or rawget(state, "selectedCharacterId") ~= nil
                or rawget(state, "battleSpec") ~= nil then
                appendError(errors, "character_fields_not_allowed", "$.state", "deckDraft 상태에는 캐릭터 선택 필드를 저장하지 않습니다.")
            end
        elseif state.phase == "deckComplete" then
            if selectedLength ~= nil and selectedLength ~= TOTAL_DRAFTS then
                appendError(errors, "invalid_complete_progress", "$.state.selectedCardIds", "deckComplete 상태에는 카드가 정확히 10장 있어야 합니다.")
            end
            if rawget(state, "offer") ~= nil then
                appendError(errors, "offer_not_allowed", "$.state.offer", "deckComplete 상태에는 제안을 저장하지 않습니다.")
            end
            if rawget(state, "characterOffer") ~= nil
                or rawget(state, "selectedCharacterId") ~= nil
                or rawget(state, "battleSpec") ~= nil then
                appendError(errors, "character_fields_not_allowed", "$.state", "deckComplete 상태에는 캐릭터 선택 결과를 저장하지 않습니다.")
            end
        elseif state.phase == "characterSelect" then
            if selectedLength ~= nil and selectedLength ~= TOTAL_DRAFTS then
                appendError(errors, "invalid_character_select_progress", "$.state.selectedCardIds", "characterSelect 상태에는 카드가 정확히 10장 있어야 합니다.")
            end
            if rawget(state, "offer") ~= nil then
                appendError(errors, "offer_not_allowed", "$.state.offer", "characterSelect 상태에는 카드 제안을 저장하지 않습니다.")
            end
            if rawget(state, "selectedCharacterId") ~= nil or rawget(state, "battleSpec") ~= nil then
                appendError(errors, "battle_fields_not_allowed", "$.state", "characterSelect 상태에는 전투 준비 결과를 저장하지 않습니다.")
            end
            if type(state.characterOffer) ~= "table" or getmetatable(state.characterOffer) ~= nil then
                appendError(errors, "missing_character_offer", "$.state.characterOffer", "characterSelect 상태에는 캐릭터 후보가 필요합니다.")
            else
                checkAllowedKeys(state.characterOffer, {
                    characterIds = true,
                    interactionToken = true,
                }, "$.state.characterOffer", errors)
                local characterLength = denseArrayLength(
                    state.characterOffer.characterIds,
                    "$.state.characterOffer.characterIds",
                    errors
                )
                if characterLength ~= nil then
                    if characterLength ~= CHARACTER_OFFER_SIZE then
                        appendError(errors, "invalid_character_offer_size", "$.state.characterOffer.characterIds", "캐릭터 후보는 서로 다른 3명이어야 합니다.")
                    end
                    local seen = {}
                    for index = 1, characterLength do
                        local characterId = state.characterOffer.characterIds[index]
                        if not isAsciiId(characterId) or not characterPoolSet[characterId] then
                            appendError(errors, "invalid_offered_character", "$.state.characterOffer.characterIds[" .. index .. "]", "후보가 현재 캐릭터 풀에 없습니다.")
                        elseif seen[characterId] then
                            appendError(errors, "duplicate_offered_character", "$.state.characterOffer.characterIds[" .. index .. "]", "한 제안에 같은 캐릭터를 두 번 넣을 수 없습니다.")
                        end
                        seen[characterId] = true
                    end
                end
                if not isCharacterInteractionToken(state.characterOffer.interactionToken) then
                    appendError(errors, "invalid_character_interaction_token", "$.state.characterOffer.interactionToken", "캐릭터 interactionToken 형식이 올바르지 않습니다.")
                end
            end
        elseif state.phase == "battleReady" then
            if selectedLength ~= nil and selectedLength ~= TOTAL_DRAFTS then
                appendError(errors, "invalid_battle_ready_progress", "$.state.selectedCardIds", "battleReady 상태에는 카드가 정확히 10장 있어야 합니다.")
            end
            if rawget(state, "offer") ~= nil or rawget(state, "characterOffer") ~= nil then
                appendError(errors, "offer_not_allowed", "$.state", "battleReady 상태에는 제안을 저장하지 않습니다.")
            end
            if not isAsciiId(state.selectedCharacterId) or not characterPoolSet[state.selectedCharacterId] then
                appendError(errors, "invalid_selected_character", "$.state.selectedCharacterId", "선택 캐릭터가 현재 캐릭터 풀에 없습니다.")
            end
            if type(state.battleSpec) ~= "table" or getmetatable(state.battleSpec) ~= nil then
                appendError(errors, "invalid_battle_spec", "$.state.battleSpec", "battleSpec은 메타테이블이 없는 객체여야 합니다.")
            else
                checkAllowedKeys(state.battleSpec, {
                    battleId = true,
                    seed = true,
                }, "$.state.battleSpec", errors)
                if not isRuntimeId(state.battleSpec.battleId) then
                    appendError(errors, "invalid_battle_id", "$.state.battleSpec.battleId", "battleId는 ASCII 런타임 ID여야 합니다.")
                end
                if not isSafeInteger(state.battleSpec.seed, 1) or state.battleSpec.seed > BATTLE_SEED_MODULUS then
                    appendError(errors, "invalid_battle_seed", "$.state.battleSpec.seed", "전투 seed는 1부터 2147483646 사이의 정수여야 합니다.")
                end
            end
        end

        if #errors > 0 then
            return nil, errors
        end
        return selectedLength, nil
    end

    local function validateAndReplay(state, staticInput)
        local pool, poolErrors = buildPlayerPool(staticInput)
        if poolErrors then
            return nil, poolErrors
        end
        local characterPool = nil
        if type(state) == "table"
            and (state.phase == "characterSelect" or state.phase == "battleReady") then
            local characterErrors
            characterPool, characterErrors = buildCharacterPool(staticInput)
            if characterErrors then
                return nil, characterErrors
            end
        end
        local _, shapeErrors = validateStateShape(state, pool, characterPool)
        if shapeErrors then
            return nil, shapeErrors
        end
        local expected, replayErrors = replayForPhase(
            state.setupId,
            state.rng.seed,
            state.selectedCardIds,
            pool,
            state.phase,
            characterPool,
            state.selectedCharacterId
        )
        if replayErrors then
            return nil, replayErrors
        end
        if not deepEqual(state, expected) then
            return nil, {
                makeError("setup_state_replay_mismatch", "$.state", "저장된 상태가 seed와 선택 이력으로 재생성한 RNG·제안·토큰과 일치하지 않습니다."),
            }
        end
        return expected, nil, pool, characterPool
    end

    local function validateSpec(spec)
        local errors = {}
        validateJson(spec, "$.spec", errors, {})
        if type(spec) ~= "table" or getmetatable(spec) ~= nil then
            return errors
        end
        checkAllowedKeys(spec, { setupId = true, seed = true }, "$.spec", errors)
        if not isRuntimeId(spec.setupId) then
            appendError(errors, "invalid_setup_id", "$.spec.setupId", "setupId는 ASCII 런타임 ID여야 합니다.")
        end
        if not isSafeInteger(spec.seed, 0) then
            appendError(errors, "invalid_seed", "$.spec.seed", "seed는 0 이상의 IEEE-754 안전 정수여야 합니다.")
        end
        return errors
    end

    local function validateCommand(command)
        local errors = {}
        validateJson(command, "$.command", errors, {})
        if type(command) ~= "table" or getmetatable(command) ~= nil then
            return errors
        end
        checkAllowedKeys(command, { cardId = true, interactionToken = true }, "$.command", errors)
        if not isAsciiId(command.cardId) then
            appendError(errors, "invalid_command_card_id", "$.command.cardId", "cardId는 ASCII 카드 ID여야 합니다.")
        end
        if not isInteractionToken(command.interactionToken) then
            appendError(errors, "invalid_command_token", "$.command.interactionToken", "interactionToken 형식이 올바르지 않습니다.")
        end
        return errors
    end

    local function validateCharacterCommand(command)
        local errors = {}
        validateJson(command, "$.command", errors, {})
        if type(command) ~= "table" or getmetatable(command) ~= nil then
            return errors
        end
        checkAllowedKeys(command, { characterId = true, interactionToken = true }, "$.command", errors)
        if not isAsciiId(command.characterId) then
            appendError(errors, "invalid_command_character_id", "$.command.characterId", "characterId는 ASCII 캐릭터 ID여야 합니다.")
        end
        if not isCharacterInteractionToken(command.interactionToken) then
            appendError(errors, "invalid_command_token", "$.command.interactionToken", "캐릭터 interactionToken 형식이 올바르지 않습니다.")
        end
        return errors
    end

    local function startSetup(spec, staticInput)
        local specErrors = validateSpec(spec)
        if #specErrors > 0 then
            return failure(specErrors)
        end
        local pool, poolErrors = buildPlayerPool(staticInput)
        if poolErrors then
            return failure(poolErrors)
        end
        local state, replayErrors = replay(spec.setupId, spec.seed, {}, pool)
        if replayErrors then
            return failure(replayErrors)
        end
        return success(state)
    end

    local function validateSetup(state, staticInput)
        local expected, errors = validateAndReplay(state, staticInput)
        if errors then
            return failure(errors)
        end
        return success(expected)
    end

    local function chooseCard(state, command, staticInput)
        local commandErrors = validateCommand(command)
        if #commandErrors > 0 then
            return failure(commandErrors)
        end
        local current, stateErrors, pool = validateAndReplay(state, staticInput)
        if stateErrors then
            return failure(stateErrors)
        end
        if current.phase ~= "deckDraft" then
            local stateCopy, cloneError = cloneChecked(state, "$.state")
            if cloneError then
                return failure({ cloneError })
            end
            return success(stateCopy, false, true)
        end

        if command.interactionToken ~= current.offer.interactionToken then
            local stateCopy, cloneError = cloneChecked(state, "$.state")
            if cloneError then
                return failure({ cloneError })
            end
            return success(stateCopy, false, true)
        end
        if not contains(current.offer.cardIds, command.cardId) then
            return failure({
                makeError("card_not_in_current_offer", "$.command.cardId", "현재 드래프트 제안에 없는 카드입니다."),
            })
        end

        local nextState, advanceErrors = advanceValidatedState(current, command.cardId, pool)
        if advanceErrors then
            return failure(advanceErrors)
        end
        return success(nextState, true, false)
    end

    local function beginCharacterSelect(state, staticInput)
        local current, stateErrors = validateAndReplay(state, staticInput)
        if stateErrors then
            return failure(stateErrors)
        end
        if current.phase ~= "deckComplete" then
            return failure({
                makeError("deck_not_complete", "$.state.phase", "캐릭터 선택은 deckComplete 상태에서만 시작할 수 있습니다."),
            })
        end
        local characterPool, characterErrors = buildCharacterPool(staticInput)
        if characterErrors then
            return failure(characterErrors)
        end
        local characterOffer, nextRng, offerErrors = generateCharacterOffer(
            current.setupId,
            current.rng,
            characterPool
        )
        if offerErrors then
            return failure(offerErrors)
        end
        return success({
            schemaVersion = SCHEMA_VERSION,
            kind = KIND,
            setupId = current.setupId,
            phase = "characterSelect",
            rng = nextRng,
            selectedCardIds = copyArray(current.selectedCardIds),
            characterOffer = characterOffer,
        }, true, false)
    end

    local function chooseCharacter(state, command, staticInput)
        local commandErrors = validateCharacterCommand(command)
        if #commandErrors > 0 then
            return failure(commandErrors)
        end
        local current, stateErrors = validateAndReplay(state, staticInput)
        if stateErrors then
            return failure(stateErrors)
        end
        if current.phase == "battleReady" then
            return success(current, false, true)
        end
        if current.phase ~= "characterSelect" then
            return failure({
                makeError("character_selection_not_started", "$.state.phase", "현재 상태에서는 캐릭터를 선택할 수 없습니다."),
            })
        end
        if command.interactionToken ~= current.characterOffer.interactionToken then
            return success(current, false, true)
        end
        if not contains(current.characterOffer.characterIds, command.characterId) then
            return failure({
                makeError("character_not_in_current_offer", "$.command.characterId", "현재 제안에 없는 캐릭터입니다."),
            })
        end

        return success({
            schemaVersion = SCHEMA_VERSION,
            kind = KIND,
            setupId = current.setupId,
            phase = "battleReady",
            rng = {
                seed = current.rng.seed,
                cursor = current.rng.cursor,
            },
            selectedCardIds = copyArray(current.selectedCardIds),
            selectedCharacterId = command.characterId,
            battleSpec = buildBattleSpec(current.setupId, current.rng.seed),
        }, true, false)
    end

    local arguments = { ... }
    local actions = {
        start = startSetup,
        choose = chooseCard,
        beginCharacterSelect = beginCharacterSelect,
        chooseCharacter = chooseCharacter,
        validate = validateSetup,
    }
    local handler = actions[action]
    if not handler then
        return failure({
            makeError("unknown_action", "$.action", "지원하지 않는 게임 설정 작업입니다: " .. tostring(action)),
        })
    end
    return handler(arguments[1], arguments[2], arguments[3])
end)
