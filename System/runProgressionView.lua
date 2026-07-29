(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local VIEW_KIND = "runProgressionView"
    local STATE_KIND = "runProgressionV1"
    local SETUP_KIND = "gameSetupV1"
    local DECK_MIN = 10
    local DECK_MAX = 20
    local CARD_COPY_LIMIT = 2
    local CHARACTER_OFFER_SIZE = 3
    local REWARD_OFFER_MAX = 3

    local VALID_PHASES = {
        reward = true,
        characterSelect = true,
        battleReady = true,
    }

    local VALID_OUTCOMES = {
        victory = true,
        defeat = true,
    }

    local REASON_LABELS = {
        card_checkpoint = "카드 해결 중 승패 확정",
        turn_end_checkpoint = "턴 종료 판정",
        turn_limit = "제한 구간 도착",
    }

    local function addError(errors, code, path, message)
        errors[#errors + 1] = {
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

    local function success(key, value)
        local result = {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
        }
        if key ~= nil then
            result[key] = value
        end
        return result
    end

    local function isFinite(value)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
    end

    local function isInteger(value, minimum, maximum)
        return isFinite(value)
            and value % 1 == 0
            and (minimum == nil or value >= minimum)
            and (maximum == nil or value <= maximum)
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
            and value ~= ""
            and #value <= 512
            and string.find(value, "[%z\1-\31\127]") == nil
    end

    local function objectPath(path, key)
        if type(key) == "string"
            and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", tostring(key)) .. "]"
    end

    local function inspectTable(value, path, errors)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            addError(errors, "expected_plain_table", path, "메타테이블이 없는 테이블이어야 합니다.")
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
                if key > maximum then maximum = key end
            elseif type(key) == "string" then
                hasString = true
                stringKeys[#stringKeys + 1] = key
            else
                addError(errors, "invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
                return nil
            end
        end

        if hasNumeric and hasString then
            addError(errors, "mixed_table", path, "배열 인덱스와 객체 키를 함께 사용할 수 없습니다.")
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

    local function getArrayLength(value, path, errors)
        local kind, length = inspectTable(value, path, errors)
        if kind ~= "array" then
            if kind ~= nil then
                addError(errors, "expected_array", path, "1부터 이어지는 연속 배열이어야 합니다.")
            end
            return nil
        end
        return length
    end

    local function validateJsonSafe(value, path, errors, active)
        local valueType = type(value)
        if valueType == "string" or valueType == "boolean" then return end
        if valueType == "number" then
            if not isFinite(value) then
                addError(errors, "non_finite_number", path, "NaN과 무한대는 View에 넣을 수 없습니다.")
            end
            return
        end
        if valueType ~= "table" then
            addError(errors, "unsupported_type", path, "View에 넣을 수 없는 자료형입니다: " .. valueType)
            return
        end
        if getmetatable(value) ~= nil then
            addError(errors, "metatable_not_allowed", path, "View에는 메타테이블을 사용할 수 없습니다.")
            return
        end

        active = active or {}
        if active[value] then
            addError(errors, "circular_reference", path, "순환 참조가 있는 값은 사용할 수 없습니다.")
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
        if type(value) ~= "table" then return end
        for key in pairs(value) do
            if type(key) ~= "string" or allowed[key] ~= true then
                addError(errors, "unknown_field", objectPath(path, key), "허용 목록에 없는 필드입니다.")
            end
        end
    end

    local function cloneJson(value, path, active)
        if type(value) ~= "table" then return value, nil end
        if getmetatable(value) ~= nil then
            return nil, {
                code = "metatable_not_allowed",
                path = path,
                message = "복제할 값에는 메타테이블을 사용할 수 없습니다.",
            }
        end
        active = active or {}
        if active[value] then
            return nil, {
                code = "circular_reference",
                path = path,
                message = "순환 참조가 있는 값을 복제할 수 없습니다.",
            }
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            local itemCopy, itemError = cloneJson(item, objectPath(path, key), active)
            if itemError then
                active[value] = nil
                return nil, itemError
            end
            copy[key] = itemCopy
        end
        active[value] = nil
        return copy, nil
    end

    local function deepEqual(left, right, active)
        if type(left) ~= type(right) then return false end
        if type(left) ~= "table" then return left == right end
        if getmetatable(left) ~= nil or getmetatable(right) ~= nil then return false end
        active = active or {}
        if active[left] ~= nil then return active[left] == right end
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
        if type(staticData) == "table"
            and getmetatable(staticData) == nil
            and type(rawget(staticData, "data")) == "table" then
            return rawget(staticData, "data")
        end
        return staticData
    end

    local function appendNestedErrors(target, prefix, report)
        if type(report) ~= "table" or type(report.errors) ~= "table" then
            addError(target, "validation_failed", prefix, "하위 검증 결과를 읽을 수 없습니다.")
            return
        end
        local appended = false
        for _, item in ipairs(report.errors) do
            appended = true
            local suffix = tostring(type(item) == "table" and item.path or "$")
            if string.sub(suffix, 1, 1) == "$" then
                suffix = string.sub(suffix, 2)
            else
                suffix = "." .. suffix
            end
            addError(
                target,
                tostring(type(item) == "table" and item.code or "validation_failed"),
                prefix .. suffix,
                tostring(type(item) == "table" and item.message or "하위 검증에 실패했습니다.")
            )
        end
        if not appended then
            addError(target, "validation_failed", prefix, "하위 검증이 상세 오류 없이 실패했습니다.")
        end
    end

    local function callRuntime(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                code = "runtime_unavailable",
                path = "$.runtime." .. moduleName,
                message = "runScript 실행기를 찾을 수 없습니다.",
            }
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok then
            return nil, {
                code = "runtime_call_error",
                path = "$.runtime." .. moduleName,
                message = moduleName .. "." .. moduleAction .. " 실행에 실패했습니다: " .. tostring(report),
            }
        end
        if type(report) ~= "table" or getmetatable(report) ~= nil then
            return nil, {
                code = "invalid_runtime_result",
                path = "$.runtime." .. moduleName,
                message = "하위 모듈이 일반 테이블 결과를 반환하지 않았습니다.",
            }
        end
        return report, nil
    end

    local function validateIdArray(value, path, errors, minimum, maximum, allowDuplicates)
        local length = getArrayLength(value, path, errors)
        if length == nil then return nil end
        if minimum ~= nil and length < minimum then
            addError(errors, "array_too_short", path, "항목 수가 최소값보다 작습니다.")
        end
        if maximum ~= nil and length > maximum then
            addError(errors, "array_too_long", path, "항목 수가 최대값보다 큽니다.")
        end
        local seen = {}
        for index = 1, length do
            local id = value[index]
            if not isAsciiId(id) then
                addError(errors, "invalid_id", path .. "[" .. index .. "]", "lower_snake_case ASCII ID여야 합니다.")
            elseif seen[id] and allowDuplicates ~= true then
                addError(errors, "duplicate_id", path .. "[" .. index .. "]", "같은 ID를 중복할 수 없습니다.")
            else
                seen[id] = true
            end
        end
        return length
    end

    local function validateTransit(transit, path, staticData, turnLimit, errors)
        if type(transit) ~= "table" or getmetatable(transit) ~= nil then
            addError(errors, "invalid_transit", path, "이동 구간은 일반 테이블이어야 합니다.")
            return
        end
        checkAllowedKeys(transit, {
            algorithm = true,
            lineId = true,
            stationIds = true,
        }, path, errors)
        if transit.algorithm ~= "tokyo_subway_segment_v1" then
            addError(errors, "invalid_transit_algorithm", path .. ".algorithm", "지원하지 않는 이동 구간 알고리즘입니다.")
        end
        if not isAsciiId(transit.lineId) then
            addError(errors, "invalid_line_id", path .. ".lineId", "노선 ID가 올바르지 않습니다.")
        end
        local stationCount = validateIdArray(
            transit.stationIds,
            path .. ".stationIds",
            errors,
            2,
            nil,
            true
        )
        if stationCount ~= nil
            and isInteger(turnLimit, 1)
            and stationCount ~= turnLimit + 1 then
            addError(errors, "transit_length_mismatch", path .. ".stationIds", "역 수는 제한 턴보다 하나 많아야 합니다.")
        end

        local line = type(staticData) == "table"
            and type(staticData.subwayLines) == "table"
            and staticData.subwayLines[transit.lineId]
            or nil
        if type(line) ~= "table" then
            addError(errors, "unknown_line", path .. ".lineId", "정적 데이터에서 노선을 찾을 수 없습니다.")
            return
        end

        local knownStations = {}
        local adjacency = {}
        for _, routePath in ipairs(type(line.paths) == "table" and line.paths or {}) do
            local stations = type(routePath) == "table" and routePath.stations or {}
            for index, station in ipairs(stations) do
                if type(station) == "table" and isAsciiId(station.id) then
                    knownStations[station.id] = true
                    adjacency[station.id] = adjacency[station.id] or {}
                    local nextStation = stations[index + 1]
                    if type(nextStation) == "table" and isAsciiId(nextStation.id) then
                        adjacency[station.id][nextStation.id] = true
                        adjacency[nextStation.id] = adjacency[nextStation.id] or {}
                        adjacency[nextStation.id][station.id] = true
                    end
                end
            end
            if type(routePath) == "table"
                and routePath.circular == true
                and #stations > 1 then
                local first = stations[1]
                local last = stations[#stations]
                if type(first) == "table" and type(last) == "table" then
                    adjacency[first.id] = adjacency[first.id] or {}
                    adjacency[last.id] = adjacency[last.id] or {}
                    adjacency[first.id][last.id] = true
                    adjacency[last.id][first.id] = true
                end
            end
        end
        if stationCount ~= nil then
            for index = 1, stationCount do
                local stationId = transit.stationIds[index]
                if isAsciiId(stationId) and not knownStations[stationId] then
                    addError(errors, "unknown_station", path .. ".stationIds[" .. index .. "]", "선택 노선에서 역을 찾을 수 없습니다.")
                end
                if index > 1 then
                    local previousId = transit.stationIds[index - 1]
                    if isAsciiId(previousId)
                        and isAsciiId(stationId)
                        and not (adjacency[previousId] and adjacency[previousId][stationId]) then
                        addError(errors, "non_adjacent_station", path .. ".stationIds[" .. index .. "]", "서로 인접하지 않은 역이 이동 구간에 있습니다.")
                    end
                end
            end
        end
    end

    local function validateSettlement(settlement, path, staticData, errors)
        if type(settlement) ~= "table" or getmetatable(settlement) ~= nil then
            addError(errors, "invalid_settlement", path, "세션 정산은 일반 테이블이어야 합니다.")
            return
        end
        checkAllowedKeys(settlement, {
            battleId = true,
            turnId = true,
            characterId = true,
            status = true,
            reasonCode = true,
            turnNumber = true,
            turnLimit = true,
            finalStealth = true,
            finalResistance = true,
            environmentId = true,
            transit = true,
        }, path, errors)
        if not isRuntimeId(settlement.battleId) then
            addError(errors, "invalid_battle_id", path .. ".battleId", "battleId가 올바르지 않습니다.")
        end
        if not isRuntimeId(settlement.turnId) then
            addError(errors, "invalid_turn_id", path .. ".turnId", "turnId가 올바르지 않습니다.")
        end
        if not isAsciiId(settlement.characterId)
            or type(staticData.characters[settlement.characterId]) ~= "table" then
            addError(errors, "unknown_character", path .. ".characterId", "정적 데이터에서 상대를 찾을 수 없습니다.")
        end
        if VALID_OUTCOMES[settlement.status] ~= true then
            addError(errors, "invalid_outcome", path .. ".status", "세션 결과는 victory 또는 defeat여야 합니다.")
        end
        if REASON_LABELS[settlement.reasonCode] == nil then
            addError(errors, "invalid_reason_code", path .. ".reasonCode", "지원하지 않는 세션 종료 사유입니다.")
        elseif settlement.reasonCode == "turn_limit" and settlement.status ~= "defeat" then
            addError(errors, "turn_limit_outcome_mismatch", path, "제한 턴 종료는 패배여야 합니다.")
        end
        if not isInteger(settlement.turnNumber, 1) then
            addError(errors, "invalid_turn_number", path .. ".turnNumber", "종료 턴은 1 이상의 정수여야 합니다.")
        end
        if not isInteger(settlement.turnLimit, 1) then
            addError(errors, "invalid_turn_limit", path .. ".turnLimit", "제한 턴은 1 이상의 정수여야 합니다.")
        elseif isInteger(settlement.turnNumber, 1)
            and settlement.turnNumber > settlement.turnLimit then
            addError(errors, "turn_number_exceeds_limit", path .. ".turnNumber", "종료 턴은 제한 턴을 넘을 수 없습니다.")
        end
        if not isFinite(settlement.finalStealth) then
            addError(errors, "invalid_final_stealth", path .. ".finalStealth", "최종 은폐는 유한한 숫자여야 합니다.")
        end
        if not isFinite(settlement.finalResistance) then
            addError(errors, "invalid_final_resistance", path .. ".finalResistance", "최종 저항은 유한한 숫자여야 합니다.")
        end
        if not isAsciiId(settlement.environmentId)
            or type(staticData.environments[settlement.environmentId]) ~= "table" then
            addError(errors, "unknown_environment", path .. ".environmentId", "정적 데이터에서 환경을 찾을 수 없습니다.")
        end
        validateTransit(settlement.transit, path .. ".transit", staticData, settlement.turnLimit, errors)
    end

    local function validateRewardChoice(choice, path, staticData, errors)
        if type(choice) ~= "table" or getmetatable(choice) ~= nil then
            addError(errors, "invalid_reward_choice", path, "보상 선택 영수증은 일반 테이블이어야 합니다.")
            return
        end
        if choice.kind == "card" then
            checkAllowedKeys(choice, { kind = true, cardId = true }, path, errors)
            if not isAsciiId(choice.cardId)
                or type(staticData.cards[choice.cardId]) ~= "table"
                or staticData.cards[choice.cardId].owner ~= "player" then
                addError(errors, "unknown_reward_card", path .. ".cardId", "선택한 플레이어 보상 카드를 찾을 수 없습니다.")
            end
        elseif choice.kind == "none" then
            checkAllowedKeys(choice, { kind = true }, path, errors)
        else
            addError(errors, "invalid_reward_kind", path .. ".kind", "보상 종류는 card 또는 none이어야 합니다.")
        end
    end

    local SETTLEMENT_FIELDS = {
        "battleId",
        "turnId",
        "characterId",
        "status",
        "reasonCode",
        "turnNumber",
        "turnLimit",
        "finalStealth",
        "finalResistance",
        "environmentId",
        "transit",
    }

    local function settlementFromSession(receipt)
        local settlement = {}
        for _, field in ipairs(SETTLEMENT_FIELDS) do
            settlement[field] = receipt[field]
        end
        return settlement
    end

    local function validateSessionReceipt(receipt, path, staticData, errors)
        if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then
            addError(errors, "invalid_session_receipt", path, "세션 영수증은 일반 테이블이어야 합니다.")
            return
        end
        checkAllowedKeys(receipt, {
            battleId = true,
            turnId = true,
            characterId = true,
            status = true,
            reasonCode = true,
            turnNumber = true,
            turnLimit = true,
            finalStealth = true,
            finalResistance = true,
            environmentId = true,
            transit = true,
            rewardChoice = true,
            nextCharacterId = true,
        }, path, errors)
        validateSettlement(settlementFromSession(receipt), path, staticData, errors)
        if receipt.rewardChoice ~= nil then
            validateRewardChoice(receipt.rewardChoice, path .. ".rewardChoice", staticData, errors)
        end
        if receipt.nextCharacterId ~= nil
            and (not isAsciiId(receipt.nextCharacterId)
                or type(staticData.characters[receipt.nextCharacterId]) ~= "table") then
            addError(errors, "unknown_next_character", path .. ".nextCharacterId", "다음 상대를 정적 데이터에서 찾을 수 없습니다.")
        end
        if receipt.nextCharacterId ~= nil and receipt.rewardChoice == nil then
            addError(errors, "next_character_before_reward", path, "보상을 확정하기 전에 다음 상대를 기록할 수 없습니다.")
        end
    end

    local function validateRewardOffer(offer, path, cardCopies, deckCount, staticData, errors)
        if type(offer) ~= "table" or getmetatable(offer) ~= nil then
            addError(errors, "invalid_reward_offer", path, "보상 제안은 일반 테이블이어야 합니다.")
            return
        end
        if offer.kind == "card" then
            checkAllowedKeys(offer, {
                kind = true,
                cardIds = true,
                interactionToken = true,
            }, path, errors)
            local length = validateIdArray(
                offer.cardIds,
                path .. ".cardIds",
                errors,
                1,
                REWARD_OFFER_MAX
            )
            if length ~= nil then
                if deckCount >= DECK_MAX then
                    addError(errors, "reward_card_at_deck_limit", path, "덱 한도에서는 새 카드 보상을 제안할 수 없습니다.")
                end
                for index = 1, length do
                    local cardId = offer.cardIds[index]
                    local card = staticData.cards[cardId]
                    if type(card) ~= "table" or card.owner ~= "player" then
                        addError(errors, "unknown_reward_card", path .. ".cardIds[" .. index .. "]", "플레이어 보상 카드를 찾을 수 없습니다.")
                    elseif (cardCopies[cardId] or 0) >= CARD_COPY_LIMIT then
                        addError(errors, "reward_copy_limit", path .. ".cardIds[" .. index .. "]", "이미 두 장 보유한 카드는 보상으로 제안할 수 없습니다.")
                    end
                end
            end
        elseif offer.kind == "none" then
            checkAllowedKeys(offer, {
                kind = true,
                interactionToken = true,
            }, path, errors)
        else
            addError(errors, "invalid_reward_kind", path .. ".kind", "보상 제안 종류는 card 또는 none이어야 합니다.")
        end
        if not isInteractionToken(offer.interactionToken) then
            addError(errors, "invalid_interaction_token", path .. ".interactionToken", "보상 상호작용 토큰이 올바르지 않습니다.")
        end
    end

    local function validateCharacterOffer(offer, path, staticData, errors)
        if type(offer) ~= "table" or getmetatable(offer) ~= nil then
            addError(errors, "invalid_character_offer", path, "캐릭터 제안은 일반 테이블이어야 합니다.")
            return
        end
        checkAllowedKeys(offer, {
            characterIds = true,
            interactionToken = true,
        }, path, errors)
        local length = validateIdArray(
            offer.characterIds,
            path .. ".characterIds",
            errors,
            CHARACTER_OFFER_SIZE,
            CHARACTER_OFFER_SIZE
        )
        if length ~= nil then
            for index = 1, length do
                local characterId = offer.characterIds[index]
                if type(staticData.characters[characterId]) ~= "table" then
                    addError(errors, "unknown_character", path .. ".characterIds[" .. index .. "]", "제안 캐릭터를 찾을 수 없습니다.")
                end
            end
        end
        if not isInteractionToken(offer.interactionToken) then
            addError(errors, "invalid_interaction_token", path .. ".interactionToken", "캐릭터 상호작용 토큰이 올바르지 않습니다.")
        end
    end

    local function validateBattleSpec(spec, path, playerCardIds, perkIds, staticData, errors)
        if type(spec) ~= "table" or getmetatable(spec) ~= nil then
            addError(errors, "invalid_battle_spec", path, "다음 전투 사양은 일반 테이블이어야 합니다.")
            return
        end
        checkAllowedKeys(spec, {
            battleId = true,
            seed = true,
            characterId = true,
            playerCardIds = true,
            perkIds = true,
            environmentId = true,
            turnLimit = true,
            lineId = true,
            stationIds = true,
        }, path, errors)
        if not isRuntimeId(spec.battleId) then
            addError(errors, "invalid_battle_id", path .. ".battleId", "다음 battleId가 올바르지 않습니다.")
        end
        if not isInteger(spec.seed, 1, 2147483646) then
            addError(errors, "invalid_battle_seed", path .. ".seed", "전투 seed가 허용 범위를 벗어났습니다.")
        end
        if not isAsciiId(spec.characterId)
            or type(staticData.characters[spec.characterId]) ~= "table" then
            addError(errors, "unknown_character", path .. ".characterId", "다음 상대를 찾을 수 없습니다.")
        end
        if not deepEqual(spec.playerCardIds, playerCardIds) then
            addError(errors, "battle_deck_mismatch", path .. ".playerCardIds", "전투 사양의 덱이 진행 상태 덱과 다릅니다.")
        end
        if not deepEqual(spec.perkIds, perkIds) then
            addError(errors, "battle_perk_mismatch", path .. ".perkIds", "전투 사양의 퍽이 진행 상태와 다릅니다.")
        end
        if not isAsciiId(spec.environmentId)
            or type(staticData.environments[spec.environmentId]) ~= "table" then
            addError(errors, "unknown_environment", path .. ".environmentId", "다음 전투 환경을 찾을 수 없습니다.")
        end
        if not isAsciiId(spec.lineId)
            or type(staticData.subwayLines[spec.lineId]) ~= "table" then
            addError(errors, "unknown_line", path .. ".lineId", "다음 전투 노선을 찾을 수 없습니다.")
        end
        if not isInteger(spec.turnLimit, 1) then
            addError(errors, "invalid_turn_limit", path .. ".turnLimit", "다음 전투 제한 턴이 올바르지 않습니다.")
        end
        local stationCount = validateIdArray(
            spec.stationIds,
            path .. ".stationIds",
            errors,
            2,
            nil,
            true
        )
        if stationCount ~= nil and isInteger(spec.turnLimit, 1) then
            if stationCount ~= spec.turnLimit + 1 then
                addError(errors, "transit_length_mismatch", path .. ".stationIds", "다음 전투 역 수는 제한 턴보다 하나 많아야 합니다.")
            end
            local transit = {
                algorithm = "tokyo_subway_segment_v1",
                lineId = spec.lineId,
                stationIds = spec.stationIds,
            }
            validateTransit(transit, path, staticData, spec.turnLimit, errors)
        end
    end

    local function validateCanonicalInputs(runState, setupState, staticInput)
        local errors = {}
        validateJsonSafe(runState, "$.runState", errors)
        validateJsonSafe(setupState, "$.setupState", errors)
        local staticData = normalizeStaticData(staticInput)
        if type(staticData) ~= "table"
            or getmetatable(staticData) ~= nil
            or type(staticData.registry) ~= "table"
            or type(staticData.registry.actionTags) ~= "table"
            or type(staticData.registry.mechanisms) ~= "table"
            or type(staticData.registry.moods) ~= "table"
            or type(staticData.cards) ~= "table"
            or type(staticData.traits) ~= "table"
            or type(staticData.environments) ~= "table"
            or type(staticData.subwayLines) ~= "table"
            or type(staticData.characters) ~= "table" then
            addError(errors, "missing_static_data", "$.staticData", "검증된 전체 정적 데이터가 필요합니다.")
            return nil, errors
        end
        if #errors > 0 then return nil, errors end

        if type(setupState) ~= "table" or getmetatable(setupState) ~= nil then
            addError(errors, "invalid_setup_state", "$.setupState", "gameSetupV1 상태가 필요합니다.")
        else
            if setupState.schemaVersion ~= SCHEMA_VERSION then
                addError(errors, "unsupported_setup_schema", "$.setupState.schemaVersion", "지원하지 않는 gameSetup 스키마입니다.")
            end
            if setupState.kind ~= SETUP_KIND then
                addError(errors, "invalid_setup_kind", "$.setupState.kind", "gameSetupV1 상태가 아닙니다.")
            end
            if not isRuntimeId(setupState.setupId) then
                addError(errors, "invalid_setup_id", "$.setupState.setupId", "setupId가 올바르지 않습니다.")
            end
            if setupState.phase ~= "battleReady" then
                addError(errors, "setup_not_battle_ready", "$.setupState.phase", "완료된 초기 설정 상태가 필요합니다.")
            end
        end

        if type(runState) ~= "table" or getmetatable(runState) ~= nil then
            addError(errors, "invalid_run_state", "$.runState", "runProgressionV1 상태가 필요합니다.")
            return nil, errors
        end
        checkAllowedKeys(runState, {
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
        }, "$.runState", errors)
        if runState.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_run_schema", "$.runState.schemaVersion", "지원하지 않는 진행 상태 스키마입니다.")
        end
        if runState.kind ~= STATE_KIND then
            addError(errors, "invalid_run_kind", "$.runState.kind", "runProgressionV1 상태가 아닙니다.")
        end
        if not isRuntimeId(runState.setupId)
            or (type(setupState) == "table" and runState.setupId ~= setupState.setupId) then
            addError(errors, "run_setup_mismatch", "$.runState.setupId", "진행 상태와 초기 설정의 setupId가 다릅니다.")
        end
        if VALID_PHASES[runState.phase] ~= true then
            addError(errors, "invalid_run_phase", "$.runState.phase", "지원하지 않는 진행 상태 phase입니다.")
        end
        if not isInteger(runState.sessionNumber, 1) then
            addError(errors, "invalid_session_number", "$.runState.sessionNumber", "세션 번호는 1 이상의 정수여야 합니다.")
        end
        if type(runState.rng) ~= "table" or getmetatable(runState.rng) ~= nil then
            addError(errors, "invalid_rng", "$.runState.rng", "진행 RNG가 일반 테이블이 아닙니다.")
        else
            checkAllowedKeys(runState.rng, { seed = true, cursor = true }, "$.runState.rng", errors)
            if not isInteger(runState.rng.seed, 0) then
                addError(errors, "invalid_rng_seed", "$.runState.rng.seed", "진행 RNG seed가 올바르지 않습니다.")
            end
            if not isInteger(runState.rng.cursor, 0) then
                addError(errors, "invalid_rng_cursor", "$.runState.rng.cursor", "진행 RNG cursor가 올바르지 않습니다.")
            end
        end

        local deckCount = getArrayLength(runState.playerCardIds, "$.runState.playerCardIds", errors)
        local cardCopies = {}
        if deckCount ~= nil then
            if deckCount < DECK_MIN or deckCount > DECK_MAX then
                addError(errors, "invalid_deck_size", "$.runState.playerCardIds", "덱은 10장 이상 20장 이하여야 합니다.")
            end
            for index = 1, deckCount do
                local cardId = runState.playerCardIds[index]
                local card = staticData.cards[cardId]
                if not isAsciiId(cardId)
                    or type(card) ~= "table"
                    or card.owner ~= "player" then
                    addError(errors, "unknown_player_card", "$.runState.playerCardIds[" .. index .. "]", "플레이어 카드를 찾을 수 없습니다.")
                else
                    cardCopies[cardId] = (cardCopies[cardId] or 0) + 1
                    if cardCopies[cardId] > CARD_COPY_LIMIT then
                        addError(errors, "card_copy_limit", "$.runState.playerCardIds[" .. index .. "]", "같은 카드는 최대 두 장까지 보유할 수 있습니다.")
                    end
                end
            end
        end

        local perkCount = getArrayLength(runState.perkIds, "$.runState.perkIds", errors)
        if perkCount ~= nil then
            if perkCount ~= 0 then
                addError(errors, "unsupported_perks", "$.runState.perkIds", "현재 진행 버전의 perkIds는 빈 배열이어야 합니다.")
            end
        end

        if type(runState.stats) ~= "table" or getmetatable(runState.stats) ~= nil then
            addError(errors, "invalid_stats", "$.runState.stats", "누적 전적이 일반 테이블이 아닙니다.")
        else
            checkAllowedKeys(runState.stats, {
                completed = true,
                victories = true,
                defeats = true,
            }, "$.runState.stats", errors)
            for _, field in ipairs({ "completed", "victories", "defeats" }) do
                if not isInteger(runState.stats[field], 0) then
                    addError(errors, "invalid_stat", "$.runState.stats." .. field, "누적 전적은 0 이상의 정수여야 합니다.")
                end
            end
            if isInteger(runState.stats.completed, 0)
                and isInteger(runState.stats.victories, 0)
                and isInteger(runState.stats.defeats, 0)
                and runState.stats.completed ~= runState.stats.victories + runState.stats.defeats then
                addError(errors, "stats_total_mismatch", "$.runState.stats", "완료 세션 수가 승리와 패배의 합과 다릅니다.")
            end
        end

        local sessionCount = getArrayLength(runState.sessions, "$.runState.sessions", errors)
        if sessionCount ~= nil then
            if sessionCount < 1 or sessionCount > 999 then
                addError(errors, "invalid_session_count", "$.runState.sessions", "세션 기록은 1개 이상 999개 이하여야 합니다.")
            end
            if type(runState.stats) == "table"
                and isInteger(runState.stats.completed, 0)
                and sessionCount ~= runState.stats.completed then
                addError(errors, "session_count_mismatch", "$.runState.sessions", "세션 영수증 수와 완료 전적이 다릅니다.")
            end
            local victories = 0
            local defeats = 0
            for index = 1, sessionCount do
                local receipt = runState.sessions[index]
                local receiptPath = "$.runState.sessions[" .. index .. "]"
                validateSessionReceipt(receipt, receiptPath, staticData, errors)
                if type(receipt) == "table" then
                    if receipt.status == "victory" then victories = victories + 1 end
                    if receipt.status == "defeat" then defeats = defeats + 1 end
                    if index < sessionCount then
                        if receipt.rewardChoice == nil or receipt.nextCharacterId == nil then
                            addError(errors, "incomplete_historical_session", receiptPath, "이전 세션에는 보상과 다음 상대 선택이 모두 기록되어야 합니다.")
                        end
                    elseif runState.phase == "reward" then
                        if receipt.rewardChoice ~= nil or receipt.nextCharacterId ~= nil then
                            addError(errors, "phase_receipt_mismatch", receiptPath, "보상 단계의 최근 세션에는 아직 선택 기록이 없어야 합니다.")
                        end
                    elseif runState.phase == "characterSelect" then
                        if receipt.rewardChoice == nil or receipt.nextCharacterId ~= nil then
                            addError(errors, "phase_receipt_mismatch", receiptPath, "상대 선택 단계에는 보상 기록만 있어야 합니다.")
                        end
                    elseif runState.phase == "battleReady"
                        and (receipt.rewardChoice == nil or receipt.nextCharacterId == nil) then
                        addError(errors, "phase_receipt_mismatch", receiptPath, "전투 준비 단계에는 보상과 다음 상대 선택이 기록되어야 합니다.")
                    end
                end
            end
            if type(runState.stats) == "table" then
                if isInteger(runState.stats.victories, 0) and victories ~= runState.stats.victories then
                    addError(errors, "victory_count_mismatch", "$.runState.stats.victories", "영수증에서 계산한 승리 수와 다릅니다.")
                end
                if isInteger(runState.stats.defeats, 0) and defeats ~= runState.stats.defeats then
                    addError(errors, "defeat_count_mismatch", "$.runState.stats.defeats", "영수증에서 계산한 패배 수와 다릅니다.")
                end
            end
        end

        validateSettlement(runState.lastSettlement, "$.runState.lastSettlement", staticData, errors)
        if sessionCount ~= nil and sessionCount > 0
            and type(runState.sessions[sessionCount]) == "table"
            and not deepEqual(
                runState.lastSettlement,
                settlementFromSession(runState.sessions[sessionCount])
            ) then
            addError(errors, "last_settlement_mismatch", "$.runState.lastSettlement", "최근 정산이 마지막 세션 영수증과 다릅니다.")
        end
        if sessionCount ~= nil and VALID_PHASES[runState.phase] == true then
            local expectedSessionNumber = runState.phase == "battleReady"
                and sessionCount + 1
                or sessionCount
            if runState.sessionNumber ~= expectedSessionNumber then
                addError(
                    errors,
                    "session_number_mismatch",
                    "$.runState.sessionNumber",
                    "현재 단계의 세션 번호가 정산 기록 수와 다릅니다."
                )
            end
        end

        if runState.phase == "reward" then
            validateRewardOffer(
                runState.rewardOffer,
                "$.runState.rewardOffer",
                cardCopies,
                deckCount or 0,
                staticData,
                errors
            )
            if runState.characterOffer ~= nil
                or runState.battleSpec ~= nil then
                addError(errors, "unexpected_phase_field", "$.runState", "보상 단계에 다음 상대 또는 전투 사양을 둘 수 없습니다.")
            end
        elseif runState.phase == "characterSelect" then
            validateCharacterOffer(
                runState.characterOffer,
                "$.runState.characterOffer",
                staticData,
                errors
            )
            if runState.rewardOffer ~= nil
                or runState.battleSpec ~= nil then
                addError(errors, "unexpected_phase_field", "$.runState", "상대 선택 단계에 보상 제안 또는 전투 사양을 둘 수 없습니다.")
            end
        elseif runState.phase == "battleReady" then
            if runState.rewardOffer ~= nil or runState.characterOffer ~= nil then
                addError(errors, "unexpected_phase_field", "$.runState", "전투 준비 단계에 제안을 둘 수 없습니다.")
            end
            validateBattleSpec(
                runState.battleSpec,
                "$.runState.battleSpec",
                runState.playerCardIds,
                runState.perkIds,
                staticData,
                errors
            )
            local selectedCharacterId = type(runState.battleSpec) == "table"
                and runState.battleSpec.characterId
                or nil
            if not isAsciiId(selectedCharacterId)
                or type(staticData.characters[selectedCharacterId]) ~= "table" then
                addError(errors, "unknown_selected_character", "$.runState.battleSpec.characterId", "선택한 다음 상대를 찾을 수 없습니다.")
            end
        end

        if #errors > 0 then return nil, errors end
        return staticData, nil
    end

    local function lookupStation(line, stationId)
        for _, routePath in ipairs(type(line) == "table" and line.paths or {}) do
            for _, station in ipairs(type(routePath) == "table" and routePath.stations or {}) do
                if type(station) == "table" and station.id == stationId then
                    return station
                end
            end
        end
        return nil
    end

    local function stationView(station)
        return {
            id = station.id,
            code = station.code,
            name = station.name,
        }
    end

    local function buildRouteView(settlement, staticData, errors)
        local transit = settlement.transit
        local line = staticData.subwayLines[transit.lineId]
        if type(line) ~= "table" then
            addError(errors, "unknown_line", "$.result.route", "정산 노선을 찾을 수 없습니다.")
            return nil
        end
        local ids = transit.stationIds
        local reachedIndex = math.min(#ids, settlement.turnNumber + 1)
        local startStation = lookupStation(line, ids[1])
        local reachedStation = lookupStation(line, ids[reachedIndex])
        local destinationStation = lookupStation(line, ids[#ids])
        if type(startStation) ~= "table"
            or type(reachedStation) ~= "table"
            or type(destinationStation) ~= "table" then
            addError(errors, "unknown_route_station", "$.result.route", "정산 이동 구간의 역 정보를 찾을 수 없습니다.")
            return nil
        end
        return {
            lineId = line.id,
            lineName = line.name,
            lineCode = line.code,
            lineColor = line.color,
            operatorName = line.operatorName,
            startStation = stationView(startStation),
            reachedStation = stationView(reachedStation),
            destinationStation = stationView(destinationStation),
        }
    end

    local function buildResultView(runState, staticData, errors)
        local settlement = runState.lastSettlement
        local character = staticData.characters[settlement.characterId]
        local environment = staticData.environments[settlement.environmentId]
        if type(character) ~= "table" or type(environment) ~= "table" then
            addError(errors, "missing_result_reference", "$.result", "최근 세션의 공개 참조를 찾을 수 없습니다.")
            return nil
        end
        local route = buildRouteView(settlement, staticData, errors)
        if route == nil then return nil end
        local statusLabel = settlement.status == "victory" and "승리" or "패배"
        local headline = settlement.status == "victory"
            and character.name .. "의 저항을 무너뜨렸습니다"
            or character.name .. " 공략에 실패했습니다"
        return {
            sessionNumber = runState.stats.completed,
            battleId = settlement.battleId,
            status = settlement.status,
            statusLabel = statusLabel,
            headline = headline,
            reasonCode = settlement.reasonCode,
            reasonLabel = REASON_LABELS[settlement.reasonCode],
            character = {
                id = character.id,
                name = character.name,
            },
            turnNumber = settlement.turnNumber,
            turnLimit = settlement.turnLimit,
            finalStealth = settlement.finalStealth,
            finalResistance = settlement.finalResistance,
            environment = {
                id = environment.id,
                name = environment.name,
            },
            route = route,
        }
    end

    local function buildCardView(slot, cardId, ownedCopies, staticData, errors)
        local path = "$.rewardOffer.cards[" .. slot .. "]"
        local card = staticData.cards[cardId]
        if type(card) ~= "table" or card.owner ~= "player" or card.id ~= cardId then
            addError(errors, "unknown_reward_card", path .. ".cardId", "보상 카드 정의를 찾을 수 없습니다.")
            return nil
        end
        local presentation, callError = callRuntime(
            "viewBuilder",
            "buildCardPresentation",
            card,
            staticData.registry,
            path
        )
        if callError then
            errors[#errors + 1] = callError
            return nil
        end
        if presentation.ok ~= true or type(presentation.card) ~= "table" then
            appendNestedErrors(errors, path, presentation)
            return nil
        end
        if type(card.base) ~= "table"
            or not isFinite(card.base.stealthCost)
            or not isFinite(card.base.resistanceDamage) then
            addError(errors, "invalid_card_base", path, "보상 카드의 기본 수치를 표시할 수 없습니다.")
            return nil
        end
        return {
            slot = slot,
            cardId = presentation.card.cardId,
            name = presentation.card.name,
            descriptionSegments = presentation.card.descriptionSegments,
            ruleLines = presentation.card.ruleLines,
            actionTag = presentation.card.actionTag,
            mechanisms = presentation.card.mechanisms,
            baseStealthCost = card.base.stealthCost,
            baseResistanceDamage = card.base.resistanceDamage,
            ownedCopies = ownedCopies,
        }
    end

    local function buildRewardOfferView(runState, staticData, errors)
        local offer = runState.rewardOffer
        local result = {
            kind = offer.kind,
            interactionToken = offer.interactionToken,
            cards = {},
        }
        if offer.kind == "card" then
            local copies = {}
            for _, cardId in ipairs(runState.playerCardIds) do
                copies[cardId] = (copies[cardId] or 0) + 1
            end
            for slot, cardId in ipairs(offer.cardIds) do
                local cardView = buildCardView(slot, cardId, copies[cardId] or 0, staticData, errors)
                if cardView ~= nil then result.cards[#result.cards + 1] = cardView end
            end
        end
        result.count = #result.cards
        return result
    end

    local function buildAppearanceSummary(profile, path, errors)
        if type(profile) ~= "table" or type(profile.appearance) ~= "table" then
            addError(errors, "missing_public_appearance", path, "공개 외형 정보를 찾을 수 없습니다.")
            return nil
        end
        local appearance = profile.appearance
        local parts = {}
        local function appendText(value, suffix)
            if type(value) == "string" and value ~= "" then
                parts[#parts + 1] = value .. (suffix or "")
            end
        end
        local function appendNumber(value, suffix)
            if isFinite(value) then parts[#parts + 1] = tostring(value) .. suffix end
        end
        appendText(appearance.hairColor, " 머리")
        appendText(appearance.eyeColor, " 눈")
        appendText(appearance.skin)
        appendNumber(appearance.height, "cm")
        appendNumber(appearance.weight, "kg")
        appendText(appearance.threeSize)
        appendText(appearance.style)
        if #parts == 0 then
            addError(errors, "empty_public_appearance", path, "표시할 공개 외형 요약이 없습니다.")
            return nil
        end
        return table.concat(parts, " · ")
    end

    local function buildCharacterView(slot, characterId, staticData, errors)
        local path = "$.characterOffer.characters[" .. slot .. "]"
        local character = staticData.characters[characterId]
        if type(character) ~= "table"
            or character.id ~= characterId
            or type(character.name) ~= "string"
            or character.name == "" then
            addError(errors, "unknown_character", path .. ".characterId", "제안 캐릭터를 찾을 수 없습니다.")
            return nil
        end
        local profile = character.publicProfile
        local battle = character.battle
        if type(profile) ~= "table" or type(battle) ~= "table" then
            addError(errors, "missing_character_public_data", path, "캐릭터 공개 정보를 표시할 수 없습니다.")
            return nil
        end
        local appearanceSummary = buildAppearanceSummary(profile, path .. ".appearanceSummary", errors)
        local mood = staticData.registry.moods[battle.startingMood]
        if type(mood) ~= "table" or type(mood.label) ~= "string" or mood.label == "" then
            addError(errors, "unknown_starting_mood", path .. ".startingMood", "시작 무드를 찾을 수 없습니다.")
            return nil
        end
        local traits = {}
        for index, traitId in ipairs(type(battle.traitIds) == "table" and battle.traitIds or {}) do
            local trait = staticData.traits[traitId]
            if type(trait) ~= "table"
                or trait.owner ~= "character"
                or trait.visibility ~= "public"
                or type(trait.name) ~= "string"
                or type(trait.description) ~= "string" then
                addError(errors, "invalid_public_trait", path .. ".traits[" .. index .. "]", "공개 특징을 표시할 수 없습니다.")
            else
                traits[#traits + 1] = {
                    id = trait.id,
                    name = trait.name,
                    description = trait.description,
                }
            end
        end
        return {
            slot = slot,
            characterId = character.id,
            name = character.name,
            age = profile.age,
            occupation = profile.occupation,
            appearanceSummary = appearanceSummary,
            startingResistance = battle.startingResistance,
            startingMood = {
                id = mood.id,
                label = mood.label,
            },
            baseDrawCount = battle.baseDrawCount,
            maxHandSize = battle.maxHandSize,
            traits = traits,
        }
    end

    local function buildCharacterOfferView(runState, staticData, errors)
        local characters = {}
        for slot, characterId in ipairs(runState.characterOffer.characterIds) do
            local characterView = buildCharacterView(slot, characterId, staticData, errors)
            if characterView ~= nil then characters[#characters + 1] = characterView end
        end
        return {
            interactionToken = runState.characterOffer.interactionToken,
            characters = characters,
        }
    end

    local function validateString(value, path, errors)
        if type(value) ~= "string" or value == "" then
            addError(errors, "invalid_text", path, "비어 있지 않은 문자열이어야 합니다.")
        end
    end

    local function validateStationView(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_station_view", path, "역 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, { id = true, code = true, name = true }, path, errors)
        if not isAsciiId(value.id) then
            addError(errors, "invalid_station_id", path .. ".id", "역 ID가 올바르지 않습니다.")
        end
        validateString(value.code, path .. ".code", errors)
        validateString(value.name, path .. ".name", errors)
    end

    local function validateTagView(value, path, errors, expectedKind)
        if type(value) ~= "table" then
            addError(errors, "invalid_tag_view", path, "태그 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            kind = true,
            id = true,
            label = true,
            tagKind = true,
            tooltip = true,
        }, path, errors)
        if value.kind ~= "tag" or not isAsciiId(value.id) then
            addError(errors, "invalid_tag_identity", path, "태그 View 식별자가 올바르지 않습니다.")
        end
        if value.tagKind ~= "action" and value.tagKind ~= "mechanism" then
            addError(errors, "invalid_tag_kind", path .. ".tagKind", "태그 종류가 올바르지 않습니다.")
        elseif expectedKind ~= nil and value.tagKind ~= expectedKind then
            addError(errors, "tag_kind_mismatch", path .. ".tagKind", "이 위치의 태그 종류가 다릅니다.")
        end
        validateString(value.label, path .. ".label", errors)
        validateString(value.tooltip, path .. ".tooltip", errors)
    end

    local function validateSegments(value, path, errors)
        local length = getArrayLength(value, path, errors)
        if length == nil then return end
        for index = 1, length do
            local segment = value[index]
            local segmentPath = path .. "[" .. index .. "]"
            if type(segment) ~= "table" then
                addError(errors, "invalid_segment", segmentPath, "문장 조각이 테이블이 아닙니다.")
            elseif segment.kind == "text" then
                checkAllowedKeys(segment, { kind = true, value = true }, segmentPath, errors)
                validateString(segment.value, segmentPath .. ".value", errors)
            elseif segment.kind == "tag" then
                validateTagView(segment, segmentPath, errors)
            else
                addError(errors, "invalid_segment_kind", segmentPath .. ".kind", "문장 조각 종류가 올바르지 않습니다.")
            end
        end
    end

    local function validateRuleLines(value, path, errors)
        local length = getArrayLength(value, path, errors)
        if length == nil then return end
        if length < 1 then
            addError(errors, "empty_rule_lines", path, "카드 규칙은 한 줄 이상이어야 합니다.")
        end
        for index = 1, length do
            local line = value[index]
            local linePath = path .. "[" .. index .. "]"
            if type(line) ~= "table" then
                addError(errors, "invalid_rule_line", linePath, "규칙 줄이 테이블이 아닙니다.")
            else
                checkAllowedKeys(line, { segments = true }, linePath, errors)
                validateSegments(line.segments, linePath .. ".segments", errors)
            end
        end
    end

    local function validateCardView(card, path, expectedSlot, errors)
        if type(card) ~= "table" then
            addError(errors, "invalid_card_view", path, "보상 카드 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(card, {
            slot = true,
            cardId = true,
            name = true,
            descriptionSegments = true,
            ruleLines = true,
            actionTag = true,
            mechanisms = true,
            baseStealthCost = true,
            baseResistanceDamage = true,
            ownedCopies = true,
        }, path, errors)
        if card.slot ~= expectedSlot then
            addError(errors, "card_slot_mismatch", path .. ".slot", "카드 슬롯이 배열 순서와 다릅니다.")
        end
        if not isAsciiId(card.cardId) then
            addError(errors, "invalid_card_id", path .. ".cardId", "카드 ID가 올바르지 않습니다.")
        end
        validateString(card.name, path .. ".name", errors)
        validateSegments(card.descriptionSegments, path .. ".descriptionSegments", errors)
        validateRuleLines(card.ruleLines, path .. ".ruleLines", errors)
        validateTagView(card.actionTag, path .. ".actionTag", errors, "action")
        local mechanismCount = getArrayLength(card.mechanisms, path .. ".mechanisms", errors)
        if mechanismCount ~= nil then
            local seen = {}
            for index = 1, mechanismCount do
                local mechanism = card.mechanisms[index]
                validateTagView(mechanism, path .. ".mechanisms[" .. index .. "]", errors, "mechanism")
                if type(mechanism) == "table" and type(mechanism.id) == "string" then
                    if seen[mechanism.id] then
                        addError(errors, "duplicate_mechanism", path .. ".mechanisms[" .. index .. "]", "메커니즘이 중복되었습니다.")
                    end
                    seen[mechanism.id] = true
                end
            end
        end
        if not isFinite(card.baseStealthCost) or card.baseStealthCost < 0 then
            addError(errors, "invalid_stealth_cost", path .. ".baseStealthCost", "기본 은폐 비용이 올바르지 않습니다.")
        end
        if not isFinite(card.baseResistanceDamage) or card.baseResistanceDamage < 0 then
            addError(errors, "invalid_resistance_damage", path .. ".baseResistanceDamage", "기본 저항 피해가 올바르지 않습니다.")
        end
        if not isInteger(card.ownedCopies, 0, CARD_COPY_LIMIT - 1) then
            addError(errors, "invalid_owned_copies", path .. ".ownedCopies", "보상 카드 보유 수는 0 또는 1이어야 합니다.")
        end
    end

    local function validateCharacterView(character, path, expectedSlot, errors)
        if type(character) ~= "table" then
            addError(errors, "invalid_character_view", path, "캐릭터 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(character, {
            slot = true,
            characterId = true,
            name = true,
            age = true,
            occupation = true,
            appearanceSummary = true,
            startingResistance = true,
            startingMood = true,
            baseDrawCount = true,
            maxHandSize = true,
            traits = true,
        }, path, errors)
        if character.slot ~= expectedSlot then
            addError(errors, "character_slot_mismatch", path .. ".slot", "캐릭터 슬롯이 배열 순서와 다릅니다.")
        end
        if not isAsciiId(character.characterId) then
            addError(errors, "invalid_character_id", path .. ".characterId", "캐릭터 ID가 올바르지 않습니다.")
        end
        validateString(character.name, path .. ".name", errors)
        if not isInteger(character.age, 1) then
            addError(errors, "invalid_character_age", path .. ".age", "캐릭터 나이가 올바르지 않습니다.")
        end
        validateString(character.occupation, path .. ".occupation", errors)
        validateString(character.appearanceSummary, path .. ".appearanceSummary", errors)
        if not isFinite(character.startingResistance) or character.startingResistance <= 0 then
            addError(errors, "invalid_starting_resistance", path .. ".startingResistance", "시작 저항은 양수여야 합니다.")
        end
        if type(character.startingMood) ~= "table" then
            addError(errors, "invalid_starting_mood", path .. ".startingMood", "시작 무드 View가 필요합니다.")
        else
            checkAllowedKeys(character.startingMood, { id = true, label = true }, path .. ".startingMood", errors)
            if not isAsciiId(character.startingMood.id) then
                addError(errors, "invalid_mood_id", path .. ".startingMood.id", "무드 ID가 올바르지 않습니다.")
            end
            validateString(character.startingMood.label, path .. ".startingMood.label", errors)
        end
        if not isInteger(character.baseDrawCount, 1)
            or not isInteger(character.maxHandSize, 1)
            or (isInteger(character.baseDrawCount, 1)
                and isInteger(character.maxHandSize, 1)
                and character.baseDrawCount > character.maxHandSize) then
            addError(errors, "invalid_character_hand_values", path, "드로우와 손패 상한이 올바르지 않습니다.")
        end
        local traitCount = getArrayLength(character.traits, path .. ".traits", errors)
        if traitCount ~= nil then
            local seen = {}
            for index = 1, traitCount do
                local trait = character.traits[index]
                local traitPath = path .. ".traits[" .. index .. "]"
                if type(trait) ~= "table" then
                    addError(errors, "invalid_trait_view", traitPath, "특징 View가 테이블이 아닙니다.")
                else
                    checkAllowedKeys(trait, { id = true, name = true, description = true }, traitPath, errors)
                    if not isAsciiId(trait.id) then
                        addError(errors, "invalid_trait_id", traitPath .. ".id", "특징 ID가 올바르지 않습니다.")
                    elseif seen[trait.id] then
                        addError(errors, "duplicate_trait", traitPath .. ".id", "특징이 중복되었습니다.")
                    else
                        seen[trait.id] = true
                    end
                    validateString(trait.name, traitPath .. ".name", errors)
                    validateString(trait.description, traitPath .. ".description", errors)
                end
            end
        end
    end

    local function validateRunProgressionView(view)
        local errors = {}
        validateJsonSafe(view, "$", errors)
        if #errors > 0 then return failure(errors) end
        if type(view) ~= "table" or getmetatable(view) ~= nil then
            addError(errors, "invalid_view_root", "$", "runProgressionView 최상위 값은 일반 테이블이어야 합니다.")
            return failure(errors)
        end
        checkAllowedKeys(view, {
            schemaVersion = true,
            kind = true,
            phase = true,
            sessionIndex = true,
            stats = true,
            deck = true,
            result = true,
            rewardOffer = true,
            characterOffer = true,
            selectedCharacter = true,
        }, "$", errors)
        if view.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", "$.schemaVersion", "지원하지 않는 runProgressionView 스키마입니다.")
        end
        if view.kind ~= VIEW_KIND then
            addError(errors, "invalid_view_kind", "$.kind", "View kind가 runProgressionView가 아닙니다.")
        end
        if VALID_PHASES[view.phase] ~= true then
            addError(errors, "invalid_phase", "$.phase", "지원하지 않는 View phase입니다.")
        end
        if not isInteger(view.sessionIndex, 1) then
            addError(errors, "invalid_session_index", "$.sessionIndex", "세션 순번은 1 이상의 정수여야 합니다.")
        end

        if type(view.stats) ~= "table" then
            addError(errors, "invalid_stats", "$.stats", "누적 전적 View가 필요합니다.")
        else
            checkAllowedKeys(view.stats, {
                completed = true,
                victories = true,
                defeats = true,
            }, "$.stats", errors)
            for _, field in ipairs({ "completed", "victories", "defeats" }) do
                if not isInteger(view.stats[field], 0) then
                    addError(errors, "invalid_stat", "$.stats." .. field, "누적 전적은 0 이상의 정수여야 합니다.")
                end
            end
            if isInteger(view.stats.completed, 0)
                and isInteger(view.stats.victories, 0)
                and isInteger(view.stats.defeats, 0)
                and view.stats.completed ~= view.stats.victories + view.stats.defeats then
                addError(errors, "stats_total_mismatch", "$.stats", "완료 수가 승리와 패배 합과 다릅니다.")
            end
        end

        if type(view.deck) ~= "table" then
            addError(errors, "invalid_deck", "$.deck", "덱 요약 View가 필요합니다.")
        else
            checkAllowedKeys(view.deck, { count = true, limit = true }, "$.deck", errors)
            if not isInteger(view.deck.count, DECK_MIN, DECK_MAX) then
                addError(errors, "invalid_deck_count", "$.deck.count", "덱 수는 10장 이상 20장 이하여야 합니다.")
            end
            if view.deck.limit ~= DECK_MAX then
                addError(errors, "invalid_deck_limit", "$.deck.limit", "덱 상한 표시는 20이어야 합니다.")
            end
        end

        if type(view.result) ~= "table" then
            addError(errors, "invalid_result", "$.result", "최근 세션 결과 View가 필요합니다.")
        else
            checkAllowedKeys(view.result, {
                sessionNumber = true,
                battleId = true,
                status = true,
                statusLabel = true,
                headline = true,
                reasonCode = true,
                reasonLabel = true,
                character = true,
                turnNumber = true,
                turnLimit = true,
                finalStealth = true,
                finalResistance = true,
                environment = true,
                route = true,
            }, "$.result", errors)
            if not isInteger(view.result.sessionNumber, 1) then
                addError(errors, "invalid_result_session", "$.result.sessionNumber", "결과 세션 번호가 올바르지 않습니다.")
            elseif type(view.stats) == "table"
                and isInteger(view.stats.completed, 0)
                and view.result.sessionNumber ~= view.stats.completed then
                addError(errors, "result_session_mismatch", "$.result.sessionNumber", "결과 세션 번호와 완료 전적이 다릅니다.")
            end
            if not isRuntimeId(view.result.battleId) then
                addError(errors, "invalid_result_battle", "$.result.battleId", "결과 battleId가 올바르지 않습니다.")
            end
            if VALID_OUTCOMES[view.result.status] ~= true then
                addError(errors, "invalid_result_status", "$.result.status", "결과 상태가 올바르지 않습니다.")
            end
            validateString(view.result.statusLabel, "$.result.statusLabel", errors)
            validateString(view.result.headline, "$.result.headline", errors)
            if REASON_LABELS[view.result.reasonCode] == nil then
                addError(errors, "invalid_result_reason", "$.result.reasonCode", "결과 종료 사유가 올바르지 않습니다.")
            end
            validateString(view.result.reasonLabel, "$.result.reasonLabel", errors)
            if type(view.result.character) ~= "table" then
                addError(errors, "invalid_result_character", "$.result.character", "결과 상대 View가 필요합니다.")
            else
                checkAllowedKeys(view.result.character, { id = true, name = true }, "$.result.character", errors)
                if not isAsciiId(view.result.character.id) then
                    addError(errors, "invalid_character_id", "$.result.character.id", "결과 상대 ID가 올바르지 않습니다.")
                end
                validateString(view.result.character.name, "$.result.character.name", errors)
            end
            if not isInteger(view.result.turnNumber, 1)
                or not isInteger(view.result.turnLimit, 1)
                or (isInteger(view.result.turnNumber, 1)
                    and isInteger(view.result.turnLimit, 1)
                    and view.result.turnNumber > view.result.turnLimit) then
                addError(errors, "invalid_result_turn", "$.result", "결과 턴 수치가 올바르지 않습니다.")
            end
            if not isFinite(view.result.finalStealth)
                or not isFinite(view.result.finalResistance) then
                addError(errors, "invalid_result_resources", "$.result", "최종 자원 수치가 올바르지 않습니다.")
            end
            if type(view.result.environment) ~= "table" then
                addError(errors, "invalid_result_environment", "$.result.environment", "결과 환경 View가 필요합니다.")
            else
                checkAllowedKeys(view.result.environment, { id = true, name = true }, "$.result.environment", errors)
                if not isAsciiId(view.result.environment.id) then
                    addError(errors, "invalid_environment_id", "$.result.environment.id", "환경 ID가 올바르지 않습니다.")
                end
                validateString(view.result.environment.name, "$.result.environment.name", errors)
            end
            if type(view.result.route) ~= "table" then
                addError(errors, "invalid_route_view", "$.result.route", "결과 노선 View가 필요합니다.")
            else
                checkAllowedKeys(view.result.route, {
                    lineId = true,
                    lineName = true,
                    lineCode = true,
                    lineColor = true,
                    operatorName = true,
                    startStation = true,
                    reachedStation = true,
                    destinationStation = true,
                }, "$.result.route", errors)
                if not isAsciiId(view.result.route.lineId) then
                    addError(errors, "invalid_line_id", "$.result.route.lineId", "노선 ID가 올바르지 않습니다.")
                end
                for _, field in ipairs({ "lineName", "lineCode", "lineColor", "operatorName" }) do
                    validateString(view.result.route[field], "$.result.route." .. field, errors)
                end
                validateStationView(view.result.route.startStation, "$.result.route.startStation", errors)
                validateStationView(view.result.route.reachedStation, "$.result.route.reachedStation", errors)
                validateStationView(view.result.route.destinationStation, "$.result.route.destinationStation", errors)
            end
        end

        if view.phase == "reward" then
            if type(view.rewardOffer) ~= "table" then
                addError(errors, "missing_reward_offer", "$.rewardOffer", "보상 단계에는 보상 제안 View가 필요합니다.")
            else
                checkAllowedKeys(view.rewardOffer, {
                    kind = true,
                    interactionToken = true,
                    count = true,
                    cards = true,
                }, "$.rewardOffer", errors)
                if view.rewardOffer.kind ~= "card" and view.rewardOffer.kind ~= "none" then
                    addError(errors, "invalid_reward_kind", "$.rewardOffer.kind", "보상 종류가 올바르지 않습니다.")
                end
                if not isInteractionToken(view.rewardOffer.interactionToken) then
                    addError(errors, "invalid_interaction_token", "$.rewardOffer.interactionToken", "보상 token이 올바르지 않습니다.")
                end
                local cardCount = getArrayLength(view.rewardOffer.cards, "$.rewardOffer.cards", errors)
                if cardCount ~= nil then
                    if view.rewardOffer.count ~= cardCount then
                        addError(errors, "reward_count_mismatch", "$.rewardOffer.count", "보상 카드 수 요약이 배열과 다릅니다.")
                    end
                    if view.rewardOffer.kind == "card"
                        and (cardCount < 1 or cardCount > REWARD_OFFER_MAX) then
                        addError(errors, "invalid_reward_card_count", "$.rewardOffer.cards", "카드 보상은 한 장 이상 세 장 이하여야 합니다.")
                    elseif view.rewardOffer.kind == "none" and cardCount ~= 0 then
                        addError(errors, "unexpected_reward_cards", "$.rewardOffer.cards", "none 보상에는 카드가 없어야 합니다.")
                    end
                    local seenCards = {}
                    for index = 1, cardCount do
                        local card = view.rewardOffer.cards[index]
                        validateCardView(card, "$.rewardOffer.cards[" .. index .. "]", index, errors)
                        if type(card) == "table" and type(card.cardId) == "string" then
                            if seenCards[card.cardId] then
                                addError(errors, "duplicate_reward_card", "$.rewardOffer.cards[" .. index .. "]", "보상 카드가 중복되었습니다.")
                            end
                            seenCards[card.cardId] = true
                        end
                    end
                end
            end
            if view.characterOffer ~= nil or view.selectedCharacter ~= nil then
                addError(errors, "unexpected_phase_view", "$", "보상 단계에 상대 선택 View를 둘 수 없습니다.")
            end
        elseif view.phase == "characterSelect" then
            if type(view.characterOffer) ~= "table" then
                addError(errors, "missing_character_offer", "$.characterOffer", "상대 선택 View가 필요합니다.")
            else
                checkAllowedKeys(view.characterOffer, {
                    interactionToken = true,
                    characters = true,
                }, "$.characterOffer", errors)
                if not isInteractionToken(view.characterOffer.interactionToken) then
                    addError(errors, "invalid_interaction_token", "$.characterOffer.interactionToken", "상대 선택 token이 올바르지 않습니다.")
                end
                local characterCount = getArrayLength(view.characterOffer.characters, "$.characterOffer.characters", errors)
                if characterCount ~= nil then
                    if characterCount ~= CHARACTER_OFFER_SIZE then
                        addError(errors, "invalid_character_offer_size", "$.characterOffer.characters", "다음 상대는 정확히 세 명이어야 합니다.")
                    end
                    local seenCharacters = {}
                    for index = 1, characterCount do
                        local character = view.characterOffer.characters[index]
                        validateCharacterView(character, "$.characterOffer.characters[" .. index .. "]", index, errors)
                        if type(character) == "table" and type(character.characterId) == "string" then
                            if seenCharacters[character.characterId] then
                                addError(errors, "duplicate_character", "$.characterOffer.characters[" .. index .. "]", "같은 상대가 중복되었습니다.")
                            end
                            seenCharacters[character.characterId] = true
                        end
                    end
                end
            end
            if view.rewardOffer ~= nil or view.selectedCharacter ~= nil then
                addError(errors, "unexpected_phase_view", "$", "상대 선택 단계에 보상 또는 선택 완료 View를 둘 수 없습니다.")
            end
        elseif view.phase == "battleReady" then
            if type(view.selectedCharacter) ~= "table" then
                addError(errors, "missing_selected_character", "$.selectedCharacter", "선택 완료 상대 View가 필요합니다.")
            else
                checkAllowedKeys(view.selectedCharacter, { characterId = true, name = true }, "$.selectedCharacter", errors)
                if not isAsciiId(view.selectedCharacter.characterId) then
                    addError(errors, "invalid_character_id", "$.selectedCharacter.characterId", "선택 상대 ID가 올바르지 않습니다.")
                end
                validateString(view.selectedCharacter.name, "$.selectedCharacter.name", errors)
            end
            if view.rewardOffer ~= nil or view.characterOffer ~= nil then
                addError(errors, "unexpected_phase_view", "$", "전투 준비 단계에 제안 View를 둘 수 없습니다.")
            end
        end

        if #errors > 0 then return failure(errors) end
        return success("valid", true)
    end

    local function buildCanonicalView(runState, setupState, staticInput)
        local staticData, inputErrors = validateCanonicalInputs(runState, setupState, staticInput)
        if inputErrors then return failure(inputErrors) end
        local errors = {}
        local statsCopy, statsError = cloneJson(runState.stats, "$.stats")
        if statsError then return failure({ statsError }) end
        local resultView = buildResultView(runState, staticData, errors)
        local view = {
            schemaVersion = SCHEMA_VERSION,
            kind = VIEW_KIND,
            phase = runState.phase,
            sessionIndex = runState.sessionNumber,
            stats = statsCopy,
            deck = {
                count = #runState.playerCardIds,
                limit = DECK_MAX,
            },
            result = resultView,
        }
        if runState.phase == "reward" then
            view.rewardOffer = buildRewardOfferView(runState, staticData, errors)
        elseif runState.phase == "characterSelect" then
            view.characterOffer = buildCharacterOfferView(runState, staticData, errors)
        elseif runState.phase == "battleReady" then
            local characterId = type(runState.battleSpec) == "table"
                and runState.battleSpec.characterId
                or nil
            local character = staticData.characters[characterId]
            if type(character) ~= "table" then
                addError(errors, "unknown_selected_character", "$.selectedCharacter", "선택한 상대 공개 정보를 찾을 수 없습니다.")
            else
                view.selectedCharacter = {
                    characterId = character.id,
                    name = character.name,
                }
            end
        end
        if #errors > 0 then return failure(errors) end
        local validation = validateRunProgressionView(view)
        if validation.ok ~= true then return validation end
        return success("view", view)
    end

    local function buildPublic(runInput, setupInput, staticInput)
        local setupReport, setupCallError = callRuntime(
            "gameSetup",
            "validate",
            setupInput,
            staticInput
        )
        if setupCallError then return failure({ setupCallError }) end
        if setupReport.ok ~= true or type(setupReport.state) ~= "table" then
            local errors = {}
            appendNestedErrors(errors, "$.setupState", setupReport)
            return failure(errors)
        end
        if not deepEqual(setupInput, setupReport.state) then
            return failure({
                {
                    code = "setup_validation_mismatch",
                    path = "$.setupState",
                    message = "gameSetup.validate의 canonical 상태가 입력과 정확히 일치하지 않습니다.",
                },
            })
        end

        local runReport, runCallError = callRuntime(
            "runProgression",
            "validate",
            runInput,
            setupReport.state,
            staticInput
        )
        if runCallError then return failure({ runCallError }) end
        if runReport.ok ~= true or type(runReport.state) ~= "table" then
            local errors = {}
            appendNestedErrors(errors, "$.runState", runReport)
            return failure(errors)
        end
        if not deepEqual(runInput, runReport.state) then
            return failure({
                {
                    code = "run_validation_mismatch",
                    path = "$.runState",
                    message = "runProgression.validate의 canonical 상태가 입력과 정확히 일치하지 않습니다.",
                },
            })
        end
        return buildCanonicalView(runReport.state, setupReport.state, staticInput)
    end

    local function capabilityAllows(capability)
        if type(capability) ~= "function" then return false end
        local ok, allowed = pcall(capability, "runProgressionViewCanonicalV1")
        return ok and allowed == true
    end

    local arguments = { ... }
    if action == "validate" then
        return validateRunProgressionView(arguments[1])
    elseif action == "build" then
        return buildPublic(arguments[1], arguments[2], arguments[3])
    elseif action == "_buildCanonical" then
        if not capabilityAllows(arguments[4]) then
            return failure({
                {
                    code = "internal_action_denied",
                    path = "$.action",
                    message = "내부 canonical View 작업에 접근할 수 없습니다.",
                },
            })
        end
        return buildCanonicalView(arguments[1], arguments[2], arguments[3])
    end
    return failure({
        {
            code = "unknown_action",
            path = "$.action",
            message = "지원하지 않는 runProgressionView 작업입니다: " .. tostring(action),
        },
    })
end)
