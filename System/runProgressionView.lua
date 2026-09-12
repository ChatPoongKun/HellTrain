(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local VIEW_KIND = "runProgressionView"
    local STATE_KIND = "runProgressionV1"
    local SETUP_KIND = "gameSetupV1"
    local DECK_MIN = 10
    local DECK_MAX = 20
    local CHARACTER_OFFER_SIZE = 3
    local REWARD_OFFER_MAX = 3
    local REWARD_KINDS = {
        card = { label = "카드 획득", description = "무작위 카드 3장 중 한 장을 획득합니다." },
        remove_card = { label = "카드 제거", description = "보유 카드 한 장을 제거합니다." },
        perk = { label = "퍽 획득", description = "무작위 퍽 3개 중 하나를 획득합니다." },
    }

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
        turn_start_checkpoint = "턴 시작 효과로 승패 확정",
        turn_end_checkpoint = "턴 종료 판정",
        mood_state_checkpoint = "무드 효과로 은폐 소진",
        plan_exit_checkpoint = "계획 만료 효과로 승패 확정",
        turn_limit = "제한 구간 도착",
        surrender = "공략 포기 · 하차",
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

    local function inspectCanonicalInputs(runState, setupState, staticInput)
        local errors = {}
        if type(runState) ~= "table" or getmetatable(runState) ~= nil then
            addError(errors, "invalid_canonical_run_state", "$.runState", "내부 canonical 진행 상태가 일반 테이블이 아닙니다.")
        elseif runState.schemaVersion ~= SCHEMA_VERSION
            or runState.kind ~= STATE_KIND
            or VALID_PHASES[runState.phase] ~= true
            or not isRuntimeId(runState.setupId)
            or type(runState.stats) ~= "table"
            or type(runState.playerCardIds) ~= "table"
            or type(runState.lastSettlement) ~= "table" then
            addError(errors, "invalid_canonical_run_contract", "$.runState", "내부 canonical 진행 상태가 필수 postcondition을 만족하지 않습니다.")
        elseif (runState.phase == "reward" and type(runState.rewardOffer) ~= "table")
            or (runState.phase == "characterSelect" and type(runState.characterOffer) ~= "table")
            or (runState.phase == "battleReady" and type(runState.battleSpec) ~= "table") then
            addError(errors, "invalid_canonical_run_phase", "$.runState", "내부 canonical 진행 상태와 phase 자료가 일치하지 않습니다.")
        end

        if type(setupState) ~= "table" or getmetatable(setupState) ~= nil then
            addError(errors, "invalid_canonical_setup_state", "$.setupState", "내부 canonical 설정 상태가 일반 테이블이 아닙니다.")
        elseif setupState.schemaVersion ~= SCHEMA_VERSION
            or setupState.kind ~= SETUP_KIND
            or setupState.phase ~= "battleReady"
            or not isRuntimeId(setupState.setupId)
            or (type(runState) == "table" and runState.setupId ~= setupState.setupId) then
            addError(errors, "invalid_canonical_setup_contract", "$.setupState", "내부 canonical 설정 상태가 필수 postcondition을 만족하지 않습니다.")
        end

        local staticData = normalizeStaticData(staticInput)
        if type(staticData) ~= "table"
            or getmetatable(staticData) ~= nil
            or type(staticData.registry) ~= "table"
            or type(staticData.registry.cardTypes) ~= "table"
            or type(staticData.registry.roles) ~= "table"
            or type(staticData.registry.mechanisms) ~= "table"
            or type(staticData.registry.moods) ~= "table"
            or type(staticData.cards) ~= "table"
            or type(staticData.traits) ~= "table"
            or type(staticData.subwayLines) ~= "table"
            or type(staticData.characters) ~= "table" then
            addError(errors, "missing_static_data", "$.staticData", "검증된 전체 정적 데이터가 필요합니다.")
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
        if type(character) ~= "table" then
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
            route = route,
        }
    end

    local function buildCardView(slot, cardId, ownedCopies, staticData, errors, basePath)
        local path = (basePath or "$.rewardOffer.cards") .. "[" .. slot .. "]"
        local card = staticData.cards[cardId]
        if type(card) ~= "table" or card.owner ~= "player" or card.id ~= cardId then
            addError(errors, "unknown_player_card", path .. ".cardId", "플레이어 카드 정의를 찾을 수 없습니다.")
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
            rarity = card.rarity,
            draftStyle = card.draftStyle,
            descriptionSegments = presentation.card.descriptionSegments,
            ruleLines = presentation.card.ruleLines,
            cardType = presentation.card.cardType,
            roles = presentation.card.roles,
            mechanisms = presentation.card.mechanisms,
            terms = presentation.card.terms,
            baseStealthCost = card.base.stealthCost,
            baseResistanceDamage = card.base.resistanceDamage,
            ownedCopies = ownedCopies,
            maxCopies = card.rarity == "legendary" and 1 or 2,
        }
    end

    local function buildRewardOfferView(runState, staticData, errors)
        local offer = runState.rewardOffer
        local result = {
            kind = offer.kind,
            interactionToken = offer.interactionToken,
            cards = {},
            removableCards = {},
            perks = {},
            kinds = {},
            canRemove = false,
            requiresReplacement = #runState.perkIds == 3,
        }
        for slot, kind in ipairs(offer.rewardKinds) do
            local definition = REWARD_KINDS[kind]
            result.kinds[slot] = {
                slot = slot,
                kind = kind,
                label = definition.label,
                description = definition.description,
            }
            if kind == "remove_card" and #runState.playerCardIds > DECK_MIN then
                result.canRemove = true
            end
        end
        for _,id in ipairs(offer.perkIds) do
            local perk=staticData.perks[id]
            result.perks[#result.perks+1]={perkId=id,name=perk.name,description=perk.description}
        end
        if offer.kind == "card" then
            local copies = {}
            for _, cardId in ipairs(runState.playerCardIds) do
                copies[cardId] = (copies[cardId] or 0) + 1
            end
            for slot, cardId in ipairs(offer.cardIds) do
                local cardView = buildCardView(
                    slot,
                    cardId,
                    copies[cardId] or 0,
                    staticData,
                    errors,
                    "$.rewardOffer.cards"
                )
                if cardView ~= nil then result.cards[#result.cards + 1] = cardView end
            end
        end
        local copies = {}
        for _, cardId in ipairs(runState.playerCardIds) do
            copies[cardId] = (copies[cardId] or 0) + 1
        end
        for slot, cardId in ipairs(offer.removableCardIds) do
            local cardView = buildCardView(
                slot,
                cardId,
                copies[cardId],
                staticData,
                errors,
                "$.rewardOffer.removableCards"
            )
            if cardView ~= nil then result.removableCards[#result.removableCards + 1] = cardView end
        end
        result.count = #result.cards
        return result
    end

    local function buildDeckView(runState, staticData, errors)
        local copies = {}
        local cardIds = {}
        local totalCost = 0
        for _, cardId in ipairs(runState.playerCardIds) do
            if copies[cardId] == nil then
                copies[cardId] = 0
                cardIds[#cardIds + 1] = cardId
            end
            copies[cardId] = copies[cardId] + 1
            local card = staticData.cards[cardId]
            if type(card) == "table" and type(card.base) == "table"
                and isFinite(card.base.stealthCost) then
                totalCost = totalCost + card.base.stealthCost
            end
        end
        local function cardCost(cardId)
            local card = staticData.cards[cardId]
            local cost = type(card) == "table" and type(card.base) == "table"
                and card.base.stealthCost or nil
            return isFinite(cost) and cost or math.huge
        end
        table.sort(cardIds, function(left, right)
            local leftCost = cardCost(left)
            local rightCost = cardCost(right)
            if leftCost ~= rightCost then return leftCost < rightCost end
            return left < right
        end)

        local items = {}
        for slot, cardId in ipairs(cardIds) do
            local cardView = buildCardView(
                slot,
                cardId,
                copies[cardId],
                staticData,
                errors,
                "$.deck.items"
            )
            if cardView ~= nil then items[#items + 1] = cardView end
        end
        return {
            count = #runState.playerCardIds,
            limit = DECK_MAX,
            averageCost = math.floor(totalCost / #runState.playerCardIds * 10 + 0.5) / 10,
            items = items,
        }
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
            turnLimit = battle.turnLimit,
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
        if value.tagKind ~= "type" and value.tagKind ~= "role" and value.tagKind ~= "mechanism" and value.tagKind ~= "term" then
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

    local function validateCardView(card, path, expectedSlot, errors, allowFullCopies)
        if type(card) ~= "table" then
            addError(errors, "invalid_card_view", path, "보상 카드 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(card, {
            slot = true,
            cardId = true,
            name = true,
            rarity = true,
            draftStyle = true,
            descriptionSegments = true,
            ruleLines = true,
            cardType = true,
            roles = true,
            mechanisms = true,
            terms = true,
            baseStealthCost = true,
            baseResistanceDamage = true,
            ownedCopies = true,
            maxCopies = true,
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
        validateTagView(card.cardType, path .. ".cardType", errors, "type")
        local roleCount = getArrayLength(card.roles, path .. ".roles", errors)
        if roleCount ~= nil then
            if roleCount < 1 or roleCount > 2 then
                addError(errors, "invalid_card_roles", path .. ".roles", "플레이어 카드는 역할 태그를 하나 또는 둘 가져야 합니다.")
            end
            for index = 1, roleCount do
                validateTagView(card.roles[index], path .. ".roles[" .. index .. "]", errors, "role")
            end
        end
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
        local termCount = getArrayLength(card.terms, path .. ".terms", errors)
        if termCount ~= nil then
            local seen = {}
            for index = 1, termCount do
                local term = card.terms[index]
                validateTagView(term, path .. ".terms[" .. index .. "]", errors, "term")
                if type(term) == "table" and type(term.id) == "string" then
                    if seen[term.id] then
                        addError(errors, "duplicate_term", path .. ".terms[" .. index .. "]", "규칙 용어가 중복되었습니다.")
                    end
                    seen[term.id] = true
                end
            end
        end
        if not isFinite(card.baseStealthCost) or card.baseStealthCost < 0 then
            addError(errors, "invalid_stealth_cost", path .. ".baseStealthCost", "기본 은폐 비용이 올바르지 않습니다.")
        end
        if not isFinite(card.baseResistanceDamage) or card.baseResistanceDamage < 0 then
            addError(errors, "invalid_resistance_damage", path .. ".baseResistanceDamage", "기본 저항 피해가 올바르지 않습니다.")
        end
        if card.rarity ~= "common" and card.rarity ~= "rare" and card.rarity ~= "legendary" then
            addError(errors, "invalid_card_rarity", path .. ".rarity", "카드 희귀도가 올바르지 않습니다.")
        end
        if card.draftStyle ~= "predator"
            and card.draftStyle ~= "harmonizer"
            and card.draftStyle ~= "glutton"
            and card.draftStyle ~= "deceiver" then
            addError(errors, "invalid_draft_style", path .. ".draftStyle", "카드 드래프트 스타일이 올바르지 않습니다.")
        end
        local expectedMaxCopies = card.rarity == "legendary" and 1 or 2
        if card.maxCopies ~= expectedMaxCopies then
            addError(errors, "invalid_max_copies", path .. ".maxCopies", "희귀도에 따른 카드 보유 제한이 올바르지 않습니다.")
        end
        local ownedMaximum = allowFullCopies and expectedMaxCopies or expectedMaxCopies - 1
        if not isInteger(card.ownedCopies, allowFullCopies and 1 or 0, ownedMaximum) then
            addError(errors, "invalid_owned_copies", path .. ".ownedCopies", "카드 보유 수가 카드별 제한 범위를 벗어났습니다.")
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
            turnLimit = true,
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
        if not isInteger(character.turnLimit, 7, 12) then
            addError(errors, "invalid_turn_limit", path .. ".turnLimit", "제한 턴은 7 이상 12 이하의 정수여야 합니다.")
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

    local function validatePerkItems(items, path, slots, errors)
        local count=getArrayLength(items,path,errors)
        if count == nil then return end
        if (slots and count~=3) or count>3 then addError(errors,"invalid_perk_count",path,"퍽 목록은 최대 3개이며 보유 슬롯은 3칸이어야 합니다.") end
        local seen={}
        for i,item in ipairs(items) do
            local p=path .. "[" .. i .. "]"
            if type(item)~="table" then addError(errors,"invalid_perk_view",p,"퍽 표시가 객체가 아닙니다.")
            else
                checkAllowedKeys(item,{perkId=true,name=true,description=true,owned=slots},p,errors)
                if not isAsciiId(item.perkId) or (item.perkId~="empty" and seen[item.perkId]) then addError(errors,"invalid_perk_id",p,"퍽 ID가 잘못되었거나 중복되었습니다.") end
                seen[item.perkId or ""]=true
                validateString(item.name,p .. ".name",errors)
                validateString(item.description,p .. ".description",errors)
                if slots and (type(item.owned)~="boolean" or item.owned~=(item.perkId~="empty")) then addError(errors,"invalid_perk_slot",p,"퍽 소유 여부가 올바르지 않습니다.") end
            end
        end
    end

    local function validateRewardKinds(items, path, errors)
        local count = getArrayLength(items, path, errors)
        if count == nil then return end
        if count ~= REWARD_OFFER_MAX then
            addError(errors, "invalid_reward_kind_count", path, "승리 보상 종류는 정확히 3개여야 합니다.")
        end
        local seen = {}
        for index, item in ipairs(items) do
            local itemPath = path .. "[" .. index .. "]"
            if type(item) ~= "table" then
                addError(errors, "invalid_reward_kind_view", itemPath, "보상 종류 View가 객체가 아닙니다.")
            else
                checkAllowedKeys(item, { slot=true, kind=true, label=true, description=true }, itemPath, errors)
                if item.slot ~= index or type(item.kind) ~= "string"
                    or REWARD_KINDS[item.kind] == nil or seen[item.kind] then
                    addError(errors, "invalid_reward_kind", itemPath, "보상 종류의 순서, ID 또는 중복이 올바르지 않습니다.")
                else
                    seen[item.kind] = true
                end
                validateString(item.label, itemPath .. ".label", errors)
                validateString(item.description, itemPath .. ".description", errors)
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
            perks = true,
            perkCount = true,
        }, "$", errors)
        validatePerkItems(view.perks,"$.perks",true,errors)
        local ownedCount=0
        for _,item in ipairs(type(view.perks)=="table" and view.perks or {}) do if type(item)=="table" and item.owned then ownedCount=ownedCount+1 end end
        if view.perkCount~=ownedCount then addError(errors,"perk_count_mismatch","$.perkCount","보유 퍽 집계가 슬롯과 다릅니다.") end
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
            checkAllowedKeys(view.deck, {
                count = true,
                limit = true,
                averageCost = true,
                items = true,
            }, "$.deck", errors)
            if not isInteger(view.deck.count, DECK_MIN, DECK_MAX) then
                addError(errors, "invalid_deck_count", "$.deck.count", "덱 수는 10장 이상 20장 이하여야 합니다.")
            end
            if view.deck.limit ~= DECK_MAX then
                addError(errors, "invalid_deck_limit", "$.deck.limit", "덱 상한 표시는 20이어야 합니다.")
            end
            if not isFinite(view.deck.averageCost) or view.deck.averageCost < 0 then
                addError(errors, "invalid_deck_average_cost", "$.deck.averageCost", "덱 평균 은폐 비용이 올바르지 않습니다.")
            end
            local itemCount = getArrayLength(view.deck.items, "$.deck.items", errors)
            if itemCount ~= nil then
                local seen = {}
                local copies = 0
                local totalCost = 0
                for index = 1, itemCount do
                    local card = view.deck.items[index]
                    validateCardView(card, "$.deck.items[" .. index .. "]", index, errors, true)
                    if type(card) == "table" and type(card.cardId) == "string" then
                        if seen[card.cardId] then
                            addError(errors, "duplicate_deck_card", "$.deck.items[" .. index .. "].cardId", "덱 카드가 중복 집계되었습니다.")
                        end
                        seen[card.cardId] = true
                    end
                    if type(card) == "table"
                        and isInteger(card.ownedCopies, 1)
                        and isFinite(card.baseStealthCost) then
                        copies = copies + card.ownedCopies
                        totalCost = totalCost + card.baseStealthCost * card.ownedCopies
                    end
                end
                if isInteger(view.deck.count, DECK_MIN, DECK_MAX) and copies ~= view.deck.count then
                    addError(errors, "deck_copy_sum_mismatch", "$.deck.items", "덱 카드 장수 합계가 덱 수와 다릅니다.")
                elseif copies > 0 and isFinite(view.deck.averageCost) then
                    local expectedAverage = math.floor(totalCost / copies * 10 + 0.5) / 10
                    if view.deck.averageCost ~= expectedAverage then
                        addError(errors, "deck_average_cost_mismatch", "$.deck.averageCost", "덱 평균 은폐 비용이 카드 구성과 다릅니다.")
                    end
                end
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
                    removableCards = true,
                    perks = true,
                    kinds = true,
                    canRemove = true,
                    requiresReplacement = true,
                }, "$.rewardOffer", errors)
                validateRewardKinds(view.rewardOffer.kinds, "$.rewardOffer.kinds", errors)
                if view.rewardOffer.kind ~= "card" and view.rewardOffer.kind ~= "none" then
                    addError(errors, "invalid_reward_kind", "$.rewardOffer.kind", "보상 종류가 올바르지 않습니다.")
                end
                validatePerkItems(view.rewardOffer.perks,"$.rewardOffer.perks",false,errors)
                if view.rewardOffer.requiresReplacement~=(view.perkCount==3) then addError(errors,"perk_replacement_mismatch","$.rewardOffer","퍽 교체 여부가 보유 수와 다릅니다.") end
                local removeOffered = false
                for _, item in ipairs(type(view.rewardOffer.kinds) == "table" and view.rewardOffer.kinds or {}) do
                    if type(item) == "table" and item.kind == "remove_card" then removeOffered = true end
                end
                if type(view.rewardOffer.canRemove) ~= "boolean"
                    or view.rewardOffer.canRemove ~= (removeOffered and view.deck.count > DECK_MIN) then
                    addError(errors, "invalid_card_removal_availability", "$.rewardOffer.canRemove", "카드 제거 가능 여부가 덱 크기와 다릅니다.")
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
                local removableCount = getArrayLength(view.rewardOffer.removableCards, "$.rewardOffer.removableCards", errors)
                if removableCount ~= nil then
                    local seenCards = {}
                    for index = 1, removableCount do
                        local card = view.rewardOffer.removableCards[index]
                        validateCardView(card, "$.rewardOffer.removableCards[" .. index .. "]", index, errors, true)
                        if type(card) == "table" and type(card.cardId) == "string" then
                            if seenCards[card.cardId] then
                                addError(errors, "duplicate_removable_card", "$.rewardOffer.removableCards[" .. index .. "]", "제거 후보 카드가 중복되었습니다.")
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
        local staticData, inputErrors = inspectCanonicalInputs(runState, setupState, staticInput)
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
            deck = buildDeckView(runState, staticData, errors),
            result = resultView,
        }
        view.perks, view.perkCount = {}, #runState.perkIds
        for i=1,3 do
            local id=runState.perkIds[i]
            local perk=id and staticData.perks[id]
            view.perks[i]={perkId=id or "empty",name=perk and perk.name or "빈 슬롯",description=perk and perk.description or "승리 보상에서 퍽을 획득하세요.",owned=perk~=nil}
        end
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

    -- 조우 기록은 기존 정산 이력과 현재 전투에서 파생한다. 별도 카운터를 저장하지 않는다.
    local function validateCharacterJournal(view)
        local errors = {}
        if type(view) ~= "table" then
            addError(errors, "invalid_character_journal", "$", "캐릭터 기록 View가 필요합니다.")
            return failure(errors)
        end
        checkAllowedKeys(view, { kind = true, schemaVersion = true, count = true, items = true, selected = true }, "$", errors)
        if view.kind ~= "characterJournalView" or view.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "invalid_character_journal", "$", "캐릭터 기록 View 형식이 올바르지 않습니다.")
        end
        local count = getArrayLength(view.items, "$.items", errors)
        if view.count ~= count then addError(errors, "character_count_mismatch", "$.count", "캐릭터 수가 목록과 다릅니다.") end
        local byId = {}
        for index = 1, count or 0 do
            local item = view.items[index]
            local path = "$.items[" .. index .. "]"
            if type(item) ~= "table" then
                addError(errors, "invalid_character_record", path, "캐릭터 기록이 필요합니다.")
            else
                checkAllowedKeys(item, { profile = true, encounters = true, victories = true, defeats = true, active = true, family = true, hobbies = true }, path, errors)
                validateCharacterView(item.profile, path .. ".profile", index, errors)
                validateString(item.family, path .. ".family", errors)
                validateString(item.hobbies, path .. ".hobbies", errors)
                for _, field in ipairs({ "encounters", "victories", "defeats", "active" }) do
                    if not isInteger(item[field], 0) then addError(errors, "invalid_encounter_count", path .. "." .. field, "조우 집계가 올바르지 않습니다.") end
                end
                if isInteger(item.encounters, 1) and isInteger(item.victories, 0) and isInteger(item.defeats, 0) and isInteger(item.active, 0, 1) then
                    if item.encounters ~= item.victories + item.defeats + item.active then
                        addError(errors, "encounter_count_mismatch", path, "조우 수와 전투 결과 합계가 다릅니다.")
                    end
                else
                    addError(errors, "invalid_encounter_count", path, "조우한 캐릭터만 기록에 표시할 수 있습니다.")
                end
                local id = type(item.profile) == "table" and item.profile.characterId or nil
                if type(id) == "string" then
                    if byId[id] then addError(errors, "duplicate_character", path, "캐릭터 기록이 중복되었습니다.") end
                    byId[id] = item
                end
            end
        end
        if view.selected ~= nil then
            local id = type(view.selected) == "table" and type(view.selected.profile) == "table" and view.selected.profile.characterId
            if not id or not byId[id] or not deepEqual(view.selected, byId[id]) then
                addError(errors, "unknown_selected_character", "$.selected", "조우한 캐릭터만 상세 조회할 수 있습니다.")
            end
        end
        if #errors > 0 then return failure(errors) end
        return success("valid", true)
    end

    local function buildCharacterJournal(input, staticInput)
        local errors = {}
        if type(input) ~= "table" then
            addError(errors, "invalid_journal_input", "$", "캐릭터 기록 입력이 필요합니다.")
            return failure(errors)
        end
        local data = normalizeStaticData(staticInput)
        if type(data) ~= "table" or type(data.characters) ~= "table" then
            addError(errors, "missing_static_data", "$.staticData", "검증된 캐릭터 데이터가 필요합니다.")
            return failure(errors)
        end
        local sessions = {}
        if input.runState ~= nil then
            local report, callError = callRuntime("runProgression", "validate", input.runState, input.setupState, data)
            if callError then return failure({ callError }) end
            if not report.ok then return report end
            sessions = report.state.sessions
        end
        local battle = input.battleState
        if battle ~= nil then
            local report, callError = callRuntime("stateSchema", "validateBattleState", battle, data)
            if callError then return failure({ callError }) end
            if not report.ok then return report end
            battle = report.value
        end
        local counts, seen = {}, {}
        local function add(battleId, characterId, status)
            if seen[battleId] then return end
            seen[battleId] = true
            local item = counts[characterId] or { encounters = 0, victories = 0, defeats = 0, active = 0 }
            counts[characterId] = item
            item.encounters = item.encounters + 1
            local field = status == "victory" and "victories" or status == "defeat" and "defeats" or "active"
            item[field] = item[field] + 1
        end
        for _, session in ipairs(sessions) do add(session.battleId, session.characterId, session.status) end
        if battle then add(battle.battleId, battle.character.characterId, battle.status) end
        local ids = {}
        for id in pairs(counts) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return data.characters[a].name < data.characters[b].name end)
        local view = { kind = "characterJournalView", schemaVersion = SCHEMA_VERSION, count = #ids, items = {} }
        for index, id in ipairs(ids) do
            local item = counts[id]
            item.profile = buildCharacterView(index, id, data, errors)
            local background = data.characters[id].publicProfile.background or {}
            item.family = type(background.family) == "string" and background.family ~= "" and background.family or "알려진 정보 없음"
            item.hobbies = type(background.hobbies) == "string" and background.hobbies ~= "" and background.hobbies or "알려진 정보 없음"
            view.items[index] = item
            if input.characterId == id then view.selected = item end
        end
        if input.characterId ~= nil and view.selected == nil then
            addError(errors, "character_not_encountered", "$.characterId", "아직 조우하지 않은 캐릭터입니다.")
        end
        if #errors > 0 then return failure(errors) end
        local checked = validateCharacterJournal(view)
        if not checked.ok then return checked end
        return success("view", view)
    end

    local function capabilityAllows(capability)
        if type(capability) ~= "function" then return false end
        local ok, allowed = pcall(capability, "runProgressionViewCanonicalV1")
        return ok and allowed == true
    end

    local arguments = { ... }
    if action == "validate" then
        return validateRunProgressionView(arguments[1])
    elseif action == "buildCharacterJournal" then
        return buildCharacterJournal(arguments[1], arguments[2])
    elseif action == "validateCharacterJournal" then
        return validateCharacterJournal(arguments[1])
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
