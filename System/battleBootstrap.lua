(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991
    local MAX_PLAN_CAPACITY = 16
    local DEFAULT_PLAYER_PLAN_CAPACITY = 1

    local PLAYER_CARD_IDS = {
        "pc_c01_standard",
        "pc_c03_heavy_damage",
        "pc_c19_recovery_mood",
        "pc_c26_choice_control",
        "pc_c28_chain_standard",
        "pc_c33_plan_recovery",
    }

    local CHARACTER_ID = "yoo_jiyoung"
    local CHARACTER_CARD_IDS = {
        "jiyoung_close_collar",
        "jiyoung_quiet_warning",
        "jiyoung_turn_to_corner",
        "jiyoung_silent_glare",
        "jiyoung_timid_call_for_help",
        "jiyoung_hug_bag_close",
        "jiyoung_half_step_back",
        "jiyoung_avoid_eye_contact",
        "jiyoung_find_courage",
        "jiyoung_phone_in_hand",
    }
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

    local function success(state)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            referencesValidated = true,
            state = state,
        }
    end

    local function setupSuccess(state)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            referencesValidated = true,
            initialDecksShuffled = true,
            state = state,
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

    local function isPlanCapacity(value)
        return isSafeInteger(value, 1) and value <= MAX_PLAN_CAPACITY
    end

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function getArrayLength(value)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return nil
        end

        local count = 0
        local maximum = 0
        for key in pairs(value) do
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
                return nil
            end
            count = count + 1
            maximum = math.max(maximum, key)
        end
        if count ~= maximum then
            return nil
        end
        return maximum
    end

    local function copyArray(value)
        local copy = {}
        for index = 1, #value do
            copy[index] = value[index]
        end
        return copy
    end

    local function effectiveCharacterPlanCapacity(characterId, battle, staticData)
        local capacityPath = "$.staticData.characters." .. characterId .. ".battle.planCapacity"
        if not isPlanCapacity(type(battle) == "table" and battle.planCapacity or nil) then
            return nil, makeError(
                "invalid_plan_capacity",
                capacityPath,
                "캐릭터 기본 계획 용량은 1 이상 16 이하의 정수여야 합니다."
            )
        end
        if getArrayLength(battle.traitIds) == nil then
            return nil, makeError(
                "invalid_character_traits",
                "$.staticData.characters." .. characterId .. ".battle.traitIds",
                "캐릭터 특징 ID 목록이 연속 배열이 아닙니다."
            )
        end

        local traits = type(staticData) == "table" and staticData.traits or nil
        if type(traits) ~= "table" or getmetatable(traits) ~= nil then
            return nil, makeError(
                "invalid_static_traits",
                "$.staticData.traits",
                "계획 용량 특징 보정을 계산할 전체 특징 컬렉션이 필요합니다."
            )
        end

        local capacity = battle.planCapacity
        for traitIndex, traitId in ipairs(battle.traitIds) do
            local trait = traits[traitId]
            if type(trait) ~= "table" then
                return nil, makeError(
                    "unknown_character_trait",
                    "$.staticData.characters." .. characterId .. ".battle.traitIds[" .. traitIndex .. "]",
                    "계획 용량을 계산할 캐릭터 특징을 찾을 수 없습니다."
                )
            end
            if trait.modifiers ~= nil then
                local modifierCount = getArrayLength(trait.modifiers)
                if modifierCount == nil then
                    return nil, makeError(
                        "invalid_trait_modifiers",
                        "$.staticData.traits." .. tostring(traitId) .. ".modifiers",
                        "특징 보정은 연속 배열이어야 합니다."
                    )
                end
                for modifierIndex = 1, modifierCount do
                    local modifier = trait.modifiers[modifierIndex]
                    local modifierPath = "$.staticData.traits." .. tostring(traitId)
                        .. ".modifiers[" .. modifierIndex .. "]"
                    if type(modifier) ~= "table" or getmetatable(modifier) ~= nil then
                        return nil, makeError(
                            "invalid_trait_plan_capacity_modifier",
                            modifierPath,
                            "계획 용량 특징 보정은 메타테이블 없는 객체여야 합니다."
                        )
                    end
                    for field in pairs(modifier) do
                        if field ~= "stat" and field ~= "operation" and field ~= "amount" then
                            return nil, makeError(
                                "unknown_trait_modifier_field",
                                modifierPath .. "." .. tostring(field),
                                "계획 용량 특징 보정에 허용되지 않은 필드가 있습니다."
                            )
                        end
                    end
                    if modifier.stat ~= "planCapacity"
                        or modifier.operation ~= "add"
                        or not isSafeInteger(modifier.amount) then
                        return nil, makeError(
                            "invalid_trait_plan_capacity_modifier",
                            modifierPath,
                            "계획 용량 특징 보정은 planCapacity/add/정수 amount 형식이어야 합니다."
                        )
                    end
                    capacity = capacity + modifier.amount
                    if not isSafeInteger(capacity) then
                        return nil, makeError(
                            "invalid_effective_plan_capacity",
                            capacityPath,
                            "계획 용량 특징 보정 합계가 안전한 정수 범위를 벗어났습니다."
                        )
                    end
                end
            end
        end

        if not isPlanCapacity(capacity) then
            return nil, makeError(
                "invalid_effective_plan_capacity",
                capacityPath,
                "캐릭터 기본 계획 용량과 특징 보정의 합은 1 이상 16 이하여야 합니다."
            )
        end
        return capacity, nil
    end

    local function copyErrors(report)
        local errors = {}
        if type(report) ~= "table" or type(report.errors) ~= "table" then
            return errors
        end
        for _, item in ipairs(report.errors) do
            if type(item) == "table" then
                errors[#errors + 1] = makeError(
                    type(item.code) == "string" and item.code or "nested_error",
                    type(item.path) == "string" and item.path or "$",
                    type(item.message) == "string" and item.message or "하위 상태 생성 작업이 실패했습니다."
                )
            end
        end
        return errors
    end

    local function validateSpec(spec)
        local errors = {}
        if type(spec) ~= "table" or getmetatable(spec) ~= nil then
            return nil, {
                makeError("invalid_spec", "$", "verticalSlice 생성 사양은 메타테이블 없는 객체여야 합니다."),
            }
        end

        local allowed = {
            battleId = true,
            seed = true,
        }
        for key in pairs(spec) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError(
                    "unknown_spec_field",
                    "$." .. tostring(key),
                    "verticalSlice 생성 사양에 알 수 없는 필드가 있습니다."
                )
            end
        end

        if not isRuntimeId(spec.battleId) then
            errors[#errors + 1] = makeError(
                "invalid_battle_id",
                "$.battleId",
                "명시적인 runtime battleId가 필요합니다."
            )
        end
        if not isSafeInteger(spec.seed, 0) then
            errors[#errors + 1] = makeError(
                "invalid_rng_seed",
                "$.seed",
                "명시적인 비음수 안전 정수 RNG 시드가 필요합니다."
            )
        end

        if #errors > 0 then
            return nil, errors
        end
        return {
            battleId = spec.battleId,
            seed = spec.seed,
        }, nil
    end

    local function validateSetupSpec(spec)
        local errors = {}
        if type(spec) ~= "table" or getmetatable(spec) ~= nil then
            return nil, {
                makeError("invalid_spec", "$", "fromSetup 생성 사양은 메타테이블 없는 객체여야 합니다."),
            }
        end

        local allowed = {
            battleId = true,
            seed = true,
            playerCardIds = true,
            characterId = true,
        }
        for key in pairs(spec) do
            if type(key) ~= "string" or not allowed[key] then
                errors[#errors + 1] = makeError(
                    "unknown_spec_field",
                    "$." .. tostring(key),
                    "fromSetup 생성 사양에 알 수 없는 필드가 있습니다."
                )
            end
        end

        if not isRuntimeId(spec.battleId) then
            errors[#errors + 1] = makeError(
                "invalid_battle_id",
                "$.battleId",
                "명시적인 runtime battleId가 필요합니다."
            )
        end
        if not isSafeInteger(spec.seed, 0) then
            errors[#errors + 1] = makeError(
                "invalid_rng_seed",
                "$.seed",
                "전투 전용 비음수 안전 정수 RNG 시드가 필요합니다."
            )
        end

        local playerDeckLength = getArrayLength(spec.playerCardIds)
        if playerDeckLength == nil
            or playerDeckLength < 10
            or playerDeckLength > 20 then
            errors[#errors + 1] = makeError(
                "invalid_player_deck",
                "$.playerCardIds",
                "플레이어 덱은 10장 이상 20장 이하의 연속 배열이어야 합니다."
            )
        else
            local counts = {}
            for index, cardId in ipairs(spec.playerCardIds) do
                if not isAsciiId(cardId) then
                    errors[#errors + 1] = makeError(
                        "invalid_player_card_id",
                        "$.playerCardIds[" .. index .. "]",
                        "플레이어 카드 ID는 lower_snake_case ASCII ID여야 합니다."
                    )
                else
                    counts[cardId] = (counts[cardId] or 0) + 1
                    if counts[cardId] > 2 then
                        errors[#errors + 1] = makeError(
                            "player_card_copy_limit_exceeded",
                            "$.playerCardIds[" .. index .. "]",
                            "플레이어 덱에는 같은 카드를 2장까지만 넣을 수 있습니다."
                        )
                    end
                end
            end
        end

        if not isAsciiId(spec.characterId) then
            errors[#errors + 1] = makeError(
                "invalid_character_id",
                "$.characterId",
                "캐릭터 ID는 lower_snake_case ASCII ID여야 합니다."
            )
        end
        if #errors > 0 then
            return nil, errors
        end
        return {
            battleId = spec.battleId,
            seed = spec.seed,
            playerCardIds = copyArray(spec.playerCardIds),
            characterId = spec.characterId,
        }, nil
    end

    local function getCharacterDefinition(staticData)
        if type(staticData) ~= "table" or getmetatable(staticData) ~= nil then
            return nil, makeError(
                "invalid_static_data",
                "$.staticData",
                "전체 정적 데이터 객체가 필요합니다."
            )
        end

        local characters = staticData.characters
        local character = type(characters) == "table" and characters[CHARACTER_ID] or nil
        local battle = type(character) == "table" and character.battle or nil
        if type(battle) ~= "table" then
            return nil, makeError(
                "missing_character_definition",
                "$.staticData.characters." .. CHARACTER_ID,
                "verticalSlice 캐릭터 전투 정의를 찾을 수 없습니다."
            )
        end

        local deckLength = getArrayLength(battle.deck)
        if deckLength ~= #CHARACTER_CARD_IDS then
            return nil, makeError(
                "vertical_slice_character_deck_mismatch",
                "$.staticData.characters." .. CHARACTER_ID .. ".battle.deck",
                "verticalSlice 캐릭터 덱 구성이 고정 사양과 다릅니다."
            )
        end
        for index, cardId in ipairs(CHARACTER_CARD_IDS) do
            if battle.deck[index] ~= cardId then
                return nil, makeError(
                    "vertical_slice_character_deck_mismatch",
                    "$.staticData.characters." .. CHARACTER_ID .. ".battle.deck[" .. index .. "]",
                    "verticalSlice 캐릭터 덱 순서가 고정 사양과 다릅니다."
                )
            end
        end
        if getArrayLength(battle.traitIds) == nil then
            return nil, makeError(
                "invalid_character_traits",
                "$.staticData.characters." .. CHARACTER_ID .. ".battle.traitIds",
                "캐릭터 특징 ID 목록이 연속 배열이 아닙니다."
            )
        end

        return character, nil
    end

    local function makeInstances(cardIds, owner)
        local instances = {}
        for index, cardId in ipairs(cardIds) do
            instances[index] = {
                instanceId = string.format("%s-%03d", owner, index),
                cardId = cardId,
                owner = owner,
                zone = "deck",
                position = index,
            }
        end
        return instances
    end

    local function getSetupDefinitions(spec, staticData)
        local errors = {}
        if type(staticData) ~= "table" or getmetatable(staticData) ~= nil then
            return nil, nil, errors, makeError(
                "invalid_static_data",
                "$.staticData",
                "전체 정적 데이터 객체가 필요합니다."
            )
        end

        local cards = staticData.cards
        if type(cards) ~= "table" or getmetatable(cards) ~= nil then
            return nil, nil, errors, makeError(
                "invalid_static_cards",
                "$.staticData.cards",
                "정적 카드 컬렉션이 필요합니다."
            )
        end
        for index, cardId in ipairs(spec.playerCardIds) do
            local card = cards[cardId]
            if type(card) ~= "table" then
                errors[#errors + 1] = makeError(
                    "unknown_player_card",
                    "$.playerCardIds[" .. index .. "]",
                    "정적 DB에서 플레이어 카드를 찾을 수 없습니다."
                )
            elseif card.owner ~= "player" then
                errors[#errors + 1] = makeError(
                    "player_card_owner_mismatch",
                    "$.playerCardIds[" .. index .. "]",
                    "선택한 카드의 정적 소유자가 player가 아닙니다."
                )
            end
        end

        local characters = staticData.characters
        local character = type(characters) == "table" and characters[spec.characterId] or nil
        local battle = type(character) == "table" and character.battle or nil
        if type(battle) ~= "table" or getmetatable(battle) ~= nil then
            return nil, nil, errors, makeError(
                "missing_character_definition",
                "$.staticData.characters." .. spec.characterId,
                "선택한 캐릭터의 전투 정의를 찾을 수 없습니다."
            )
        end

        local characterDeckLength = getArrayLength(battle.deck)
        if characterDeckLength == nil then
            errors[#errors + 1] = makeError(
                "invalid_character_deck",
                "$.staticData.characters." .. spec.characterId .. ".battle.deck",
                "캐릭터 덱은 연속 배열이어야 합니다."
            )
        else
            for index, cardId in ipairs(battle.deck) do
                local path = "$.staticData.characters." .. spec.characterId .. ".battle.deck[" .. index .. "]"
                if not isAsciiId(cardId) then
                    errors[#errors + 1] = makeError(
                        "invalid_character_card_id",
                        path,
                        "캐릭터 카드 ID는 lower_snake_case ASCII ID여야 합니다."
                    )
                else
                    local card = cards[cardId]
                    if type(card) ~= "table" then
                        errors[#errors + 1] = makeError(
                            "unknown_character_card",
                            path,
                            "정적 DB에서 캐릭터 카드를 찾을 수 없습니다."
                        )
                    elseif card.owner ~= "character" then
                        errors[#errors + 1] = makeError(
                            "character_card_owner_mismatch",
                            path,
                            "캐릭터 덱 카드의 정적 소유자가 character가 아닙니다."
                        )
                    end
                end
            end
        end

        if getArrayLength(battle.traitIds) == nil then
            errors[#errors + 1] = makeError(
                "invalid_character_traits",
                "$.staticData.characters." .. spec.characterId .. ".battle.traitIds",
                "캐릭터 특징 ID 목록이 연속 배열이 아닙니다."
            )
        end

        return character, battle, errors, nil
    end

    local function buildJourney(seed, staticData, turnLimit)
        if type(runScript) ~= "function" then
            return nil, {
                makeError(
                    "runtime_unavailable",
                    "$.runtime.subwayJourney",
                    "전투 여정을 생성할 실행기를 찾을 수 없습니다."
                ),
            }
        end
        local ok, report = pcall(
            runScript,
            triggerId,
            "subwayJourney",
            "build",
            seed,
            staticData,
            turnLimit
        )
        if not ok then
            return nil, {
                makeError(
                    "subway_journey_call_failed",
                    "$.runtime.subwayJourney",
                    "전투 여정 생성 호출에 실패했습니다: " .. tostring(report)
                ),
            }
        end
        if type(report) ~= "table" or report.ok ~= true
            or not isSafeInteger(report.turnLimit, 1)
            or report.turnLimit ~= turnLimit
            or type(report.transit) ~= "table"
            or type(report.sceneContext) ~= "table" then
            local nestedErrors = copyErrors(report)
            if #nestedErrors == 0 then
                nestedErrors[1] = makeError(
                    "invalid_subway_journey_result",
                    "$.runtime.subwayJourney",
                    "전투 여정 생성기가 제한 턴과 이동 구간을 반환하지 않았습니다."
                )
            end
            return nil, nestedErrors
        end
        return {
            turnLimit = report.turnLimit,
            transit = report.transit,
            sceneContext = report.sceneContext,
        }, nil
    end

    local function verticalSlice(spec, staticData)
        local normalized, specErrors = validateSpec(spec)
        if specErrors then
            return failure(specErrors)
        end

        local characterDefinition, characterError = getCharacterDefinition(staticData)
        if characterError then
            return failure({ characterError })
        end
        local characterBattle = characterDefinition.battle
        local characterPlanCapacity, planCapacityError = effectiveCharacterPlanCapacity(
            CHARACTER_ID,
            characterBattle,
            staticData
        )
        if planCapacityError then
            return failure({ planCapacityError })
        end
        local journey, journeyErrors = buildJourney(normalized.seed, staticData, characterBattle.turnLimit)
        if journeyErrors then
            return failure(journeyErrors)
        end

        local cardInstances = makeInstances(PLAYER_CARD_IDS, "player")
        local characterInstances = makeInstances(CHARACTER_CARD_IDS, "character")
        for _, instance in ipairs(characterInstances) do
            cardInstances[#cardInstances + 1] = instance
        end

        local stateSpec = {
            battleId = normalized.battleId,
            status = "active",
            turnNumber = 1,
            turnLimit = journey.turnLimit,
            transit = journey.transit,
            sceneContext = journey.sceneContext,
            rng = {
                seed = normalized.seed,
                cursor = 0,
            },
            player = {
                stealth = 30,
                baseDrawCount = 3,
                maxHandSize = 5,
                perkIds = {},
                planCapacity = DEFAULT_PLAYER_PLAN_CAPACITY,
                planSlots = {},
            },
            character = {
                characterId = CHARACTER_ID,
                resistance = characterBattle.startingResistance,
                mood = characterBattle.startingMood,
                traitIds = copyArray(characterBattle.traitIds),
                baseDrawCount = characterBattle.baseDrawCount,
                maxHandSize = characterBattle.maxHandSize,
                planCapacity = characterPlanCapacity,
                planSlots = {},
            },
            cardInstances = cardInstances,
            selection = {
                playerCardInstanceIds = {},
            },
            characterIntent = {
                cardInstanceIds = {},
            },
        }

        if type(runScript) ~= "function" then
            return failure({
                makeError(
                    "runtime_unavailable",
                    "$.runtime.stateSchema",
                    "stateSchema 실행기를 찾을 수 없습니다."
                ),
            })
        end

        local ok, report = pcall(
            runScript,
            triggerId,
            "stateSchema",
            "newBattleState",
            stateSpec,
            staticData
        )
        if not ok then
            return failure({
                makeError(
                    "state_schema_call_error",
                    "$.runtime.stateSchema",
                    "stateSchema.newBattleState 호출 중 오류가 발생했습니다."
                ),
            })
        end
        if type(report) ~= "table" then
            return failure({
                makeError(
                    "invalid_state_schema_result",
                    "$.runtime.stateSchema",
                    "stateSchema.newBattleState가 테이블 결과를 반환하지 않았습니다."
                ),
            })
        end
        if report.ok ~= true then
            local nestedErrors = copyErrors(report)
            if #nestedErrors == 0 then
                nestedErrors[1] = makeError(
                    "state_construction_failed",
                    "$",
                    "stateSchema.newBattleState가 오류 상세 없이 실패했습니다."
                )
            end
            return failure(nestedErrors)
        end
        if report.referencesValidated ~= true then
            return failure({
                makeError(
                    "static_references_not_validated",
                    "$.staticData",
                    "verticalSlice battleState는 전체 정적 참조 검증이 필요합니다."
                ),
            })
        end
        if type(report.value) ~= "table" then
            return failure({
                makeError(
                    "missing_battle_state",
                    "$.state",
                    "stateSchema.newBattleState 성공 결과에 battleState가 없습니다."
                ),
            })
        end

        return success(report.value)
    end

    local function fromSetup(spec, staticData)
        local normalized, specErrors = validateSetupSpec(spec)
        if specErrors then
            return failure(specErrors)
        end

        local characterDefinition, characterBattle, definitionErrors, definitionFatal =
            getSetupDefinitions(normalized, staticData)
        if definitionFatal then
            definitionErrors[#definitionErrors + 1] = definitionFatal
        end
        if #definitionErrors > 0 then
            return failure(definitionErrors)
        end
        local characterPlanCapacity, planCapacityError = effectiveCharacterPlanCapacity(
            normalized.characterId,
            characterBattle,
            staticData
        )
        if planCapacityError then
            return failure({ planCapacityError })
        end
        local journey, journeyErrors = buildJourney(normalized.seed, staticData, characterBattle.turnLimit)
        if journeyErrors then
            return failure(journeyErrors)
        end

        local cardInstances = makeInstances(normalized.playerCardIds, "player")
        local characterInstances = makeInstances(characterBattle.deck, "character")
        for _, instance in ipairs(characterInstances) do
            cardInstances[#cardInstances + 1] = instance
        end

        local stateSpec = {
            battleId = normalized.battleId,
            status = "active",
            turnNumber = 1,
            turnLimit = journey.turnLimit,
            transit = journey.transit,
            sceneContext = journey.sceneContext,
            rng = {
                seed = normalized.seed,
                cursor = 0,
            },
            player = {
                stealth = 30,
                baseDrawCount = 3,
                maxHandSize = 5,
                perkIds = {},
                planCapacity = DEFAULT_PLAYER_PLAN_CAPACITY,
                planSlots = {},
            },
            character = {
                characterId = normalized.characterId,
                resistance = characterBattle.startingResistance,
                mood = characterBattle.startingMood,
                traitIds = copyArray(characterBattle.traitIds),
                baseDrawCount = characterBattle.baseDrawCount,
                maxHandSize = characterBattle.maxHandSize,
                planCapacity = characterPlanCapacity,
                planSlots = {},
            },
            cardInstances = cardInstances,
            selection = {
                playerCardInstanceIds = {},
            },
            characterIntent = {
                cardInstanceIds = {},
            },
        }

        if type(runScript) ~= "function" then
            return failure({
                makeError(
                    "runtime_unavailable",
                    "$.runtime.stateSchema",
                    "전투 초기 상태 생성에 필요한 실행기를 찾을 수 없습니다."
                ),
            })
        end

        local constructOk, constructReport = pcall(
            runScript,
            triggerId,
            "stateSchema",
            "newBattleState",
            stateSpec,
            staticData
        )
        if not constructOk then
            return failure({
                makeError(
                    "state_schema_call_error",
                    "$.runtime.stateSchema",
                    "stateSchema.newBattleState 호출 중 오류가 발생했습니다."
                ),
            })
        end
        if type(constructReport) ~= "table" then
            return failure({
                makeError(
                    "invalid_state_schema_result",
                    "$.runtime.stateSchema",
                    "stateSchema.newBattleState가 테이블 결과를 반환하지 않았습니다."
                ),
            })
        end
        if constructReport.ok ~= true then
            local nestedErrors = copyErrors(constructReport)
            if #nestedErrors == 0 then
                nestedErrors[1] = makeError(
                    "state_construction_failed",
                    "$",
                    "stateSchema.newBattleState가 오류 상세 없이 실패했습니다."
                )
            end
            return failure(nestedErrors)
        end
        if constructReport.referencesValidated ~= true then
            return failure({
                makeError(
                    "static_references_not_validated",
                    "$.staticData",
                    "fromSetup battleState는 전체 정적 참조 검증이 필요합니다."
                ),
            })
        end
        if type(constructReport.value) ~= "table" then
            return failure({
                makeError(
                    "missing_battle_state",
                    "$.state",
                    "stateSchema.newBattleState 성공 결과에 battleState가 없습니다."
                ),
            })
        end

        local playerShuffleOk, playerShuffleReport = pcall(
            runScript,
            triggerId,
            "cardZones",
            "shuffleDeck",
            constructReport.value,
            "player"
        )
        if not playerShuffleOk then
            return failure({
                makeError(
                    "player_shuffle_call_error",
                    "$.runtime.cardZones",
                    "플레이어 초기 덱 셔플 호출 중 오류가 발생했습니다."
                ),
            })
        end
        if type(playerShuffleReport) ~= "table" then
            return failure({
                makeError(
                    "invalid_player_shuffle_result",
                    "$.runtime.cardZones",
                    "플레이어 초기 덱 셔플이 테이블 결과를 반환하지 않았습니다."
                ),
            })
        end
        if playerShuffleReport.ok ~= true then
            local nestedErrors = copyErrors(playerShuffleReport)
            if #nestedErrors == 0 then
                nestedErrors[1] = makeError(
                    "player_shuffle_failed",
                    "$.state.player",
                    "플레이어 초기 덱 셔플이 오류 상세 없이 실패했습니다."
                )
            end
            return failure(nestedErrors)
        end
        if type(playerShuffleReport.state) ~= "table" then
            return failure({
                makeError(
                    "missing_player_shuffle_state",
                    "$.state",
                    "플레이어 초기 덱 셔플 성공 결과에 battleState가 없습니다."
                ),
            })
        end

        local characterShuffleOk, characterShuffleReport = pcall(
            runScript,
            triggerId,
            "cardZones",
            "shuffleDeck",
            playerShuffleReport.state,
            "character"
        )
        if not characterShuffleOk then
            return failure({
                makeError(
                    "character_shuffle_call_error",
                    "$.runtime.cardZones",
                    "캐릭터 초기 덱 셔플 호출 중 오류가 발생했습니다."
                ),
            })
        end
        if type(characterShuffleReport) ~= "table" then
            return failure({
                makeError(
                    "invalid_character_shuffle_result",
                    "$.runtime.cardZones",
                    "캐릭터 초기 덱 셔플이 테이블 결과를 반환하지 않았습니다."
                ),
            })
        end
        if characterShuffleReport.ok ~= true then
            local nestedErrors = copyErrors(characterShuffleReport)
            if #nestedErrors == 0 then
                nestedErrors[1] = makeError(
                    "character_shuffle_failed",
                    "$.state.character",
                    "캐릭터 초기 덱 셔플이 오류 상세 없이 실패했습니다."
                )
            end
            return failure(nestedErrors)
        end
        if type(characterShuffleReport.state) ~= "table" then
            return failure({
                makeError(
                    "missing_character_shuffle_state",
                    "$.state",
                    "캐릭터 초기 덱 셔플 성공 결과에 battleState가 없습니다."
                ),
            })
        end

        local validateOk, validateReport = pcall(
            runScript,
            triggerId,
            "stateSchema",
            "validateBattleState",
            characterShuffleReport.state,
            staticData
        )
        if not validateOk then
            return failure({
                makeError(
                    "state_validation_call_error",
                    "$.runtime.stateSchema",
                    "셔플된 battleState 최종 검증 호출 중 오류가 발생했습니다."
                ),
            })
        end
        if type(validateReport) ~= "table" then
            return failure({
                makeError(
                    "invalid_state_validation_result",
                    "$.runtime.stateSchema",
                    "stateSchema.validateBattleState가 테이블 결과를 반환하지 않았습니다."
                ),
            })
        end
        if validateReport.ok ~= true then
            local nestedErrors = copyErrors(validateReport)
            if #nestedErrors == 0 then
                nestedErrors[1] = makeError(
                    "state_validation_failed",
                    "$.state",
                    "셔플된 battleState 최종 검증이 오류 상세 없이 실패했습니다."
                )
            end
            return failure(nestedErrors)
        end
        if validateReport.referencesValidated ~= true then
            return failure({
                makeError(
                    "static_references_not_validated",
                    "$.staticData",
                    "셔플된 fromSetup battleState는 전체 정적 참조 검증이 필요합니다."
                ),
            })
        end

        return setupSuccess(characterShuffleReport.state)
    end

    local arguments = { ... }
    if action == "verticalSlice" then
        return verticalSlice(arguments[1], arguments[2])
    elseif action == "fromSetup" then
        return fromSetup(arguments[1], arguments[2])
    end

    return failure({
        makeError(
            "unknown_action",
            "$.action",
            "지원하지 않는 battleBootstrap 작업입니다: " .. tostring(action)
        ),
    })
end)
