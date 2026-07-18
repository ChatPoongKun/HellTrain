(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991

    local PLAYER_CARD_IDS = {
        "subtle_approach",
        "accidental_brush",
        "play_it_cool",
        "read_the_room",
        "pin_down",
        "hypnotic_whisper",
    }

    local CHARACTER_ID = "yoo_jiyoung"
    local CHARACTER_CARD_IDS = {
        "close_collar",
        "quiet_warning",
        "turn_to_corner",
        "silent_glare",
    }
    local ENVIRONMENT_ID = "uncrowded"
    local TURN_LIMIT = 10

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

        local cardInstances = makeInstances(PLAYER_CARD_IDS, "player")
        local characterInstances = makeInstances(CHARACTER_CARD_IDS, "character")
        for _, instance in ipairs(characterInstances) do
            cardInstances[#cardInstances + 1] = instance
        end

        local stateSpec = {
            battleId = normalized.battleId,
            status = "active",
            turnNumber = 1,
            turnLimit = TURN_LIMIT,
            environmentId = ENVIRONMENT_ID,
            rng = {
                seed = normalized.seed,
                cursor = 0,
            },
            player = {
                stealth = 30,
                baseDrawCount = 3,
                maxHandSize = 5,
                perkIds = {},
                planSlot = { occupied = false },
            },
            character = {
                characterId = CHARACTER_ID,
                resistance = characterBattle.startingResistance,
                mood = characterBattle.startingMood,
                traitIds = copyArray(characterBattle.traitIds),
                baseDrawCount = characterBattle.baseDrawCount,
                maxHandSize = characterBattle.maxHandSize,
                planSlot = { occupied = false },
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

    local arguments = { ... }
    if action == "verticalSlice" then
        return verticalSlice(arguments[1], arguments[2])
    end

    return failure({
        makeError(
            "unknown_action",
            "$.action",
            "지원하지 않는 battleBootstrap 작업입니다: " .. tostring(action)
        ),
    })
end)
