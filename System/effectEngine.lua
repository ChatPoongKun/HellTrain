(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1

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

    local function success(commands, cardId)
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            commands = commands or {},
            cardId = cardId,
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

    local function isDenseArray(value)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return false
        end
        local count = 0
        local maximum = 0
        for key in pairs(value) do
            if not isInteger(key, 1) then
                return false
            end
            count = count + 1
            if key > maximum then
                maximum = key
            end
        end
        return count == maximum
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function hasMechanism(card, mechanismId)
        for _, currentId in ipairs(type(card) == "table" and type(card.mechanisms) == "table" and card.mechanisms or {}) do
            if currentId == mechanismId then
                return true
            end
        end
        return false
    end

    local function findInstance(state, instanceId)
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

    local function checkAllowedKeys(value, allowed, path, errors)
        if type(value) ~= "table" then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                table.insert(errors, makeError(
                    "unexpected_field",
                    path .. "." .. tostring(key),
                    "선택 단계 효과에 허용되지 않은 필드가 있습니다."
                ))
            end
        end
    end

    local function evaluateSelectionPreview(staticData, state, instanceId)
        staticData = normalizeStaticData(staticData)
        local errors = {}
        if type(staticData) ~= "table"
            or type(staticData.cards) ~= "table"
            or type(staticData.registry) ~= "table" then
            table.insert(errors, makeError(
                "invalid_static_data",
                "$.staticData",
                "선택 단계 효과에는 전체 정적 데이터가 필요합니다."
            ))
        end
        if type(state) ~= "table" or type(state.cardInstances) ~= "table" then
            table.insert(errors, makeError(
                "invalid_state",
                "$.state",
                "선택 단계 전투 상태가 올바르지 않습니다."
            ))
        elseif state.status ~= "active" then
            table.insert(errors, makeError(
                "battle_not_active",
                "$.state.status",
                "진행 중인 전투에서만 선택 단계 효과를 평가할 수 있습니다."
            ))
        end
        if type(instanceId) ~= "string" or instanceId == "" then
            table.insert(errors, makeError(
                "invalid_instance_id",
                "$.instanceId",
                "카드 인스턴스 ID가 없습니다."
            ))
        end
        if #errors > 0 then
            return failure(errors)
        end

        local instance = findInstance(state, instanceId)
        if not instance then
            return failure({
                makeError("instance_not_found", "$.instanceId", "카드 인스턴스를 찾을 수 없습니다."),
            })
        end
        if instance.owner ~= "player" or instance.zone ~= "hand" then
            return failure({
                makeError(
                    "preview_card_not_in_hand",
                    "$.instanceId",
                    "선택 단계 효과의 원본 카드는 플레이어 손패에 있어야 합니다."
                ),
            })
        end

        local card = staticData.cards[instance.cardId]
        if type(card) ~= "table" or card.id ~= instance.cardId then
            return failure({
                makeError("unknown_card", "$.instanceId", "정적 DB에서 카드를 찾을 수 없습니다."),
            })
        end
        if card.selectionPreview == nil then
            return success({}, card.id)
        end

        local policy = card.selectionPreview
        if type(policy) ~= "table" or getmetatable(policy) ~= nil then
            return failure({
                makeError(
                    "invalid_preview_policy",
                    "$.card.selectionPreview",
                    "선택 단계 효과 정책은 일반 테이블이어야 합니다."
                ),
            })
        end
        checkAllowedKeys(policy, { effects = true }, "$.card.selectionPreview", errors)
        if card.owner ~= "player" or not hasMechanism(card, "chain") then
            table.insert(errors, makeError(
                "preview_requires_player_chain",
                "$.card.selectionPreview",
                "선택 단계 효과는 플레이어 연계 카드에만 선언할 수 있습니다."
            ))
        end
        if not isDenseArray(policy.effects) or #policy.effects == 0 then
            table.insert(errors, makeError(
                "invalid_preview_effects",
                "$.card.selectionPreview.effects",
                "선택 단계 효과는 비어 있지 않은 연속 배열이어야 합니다."
            ))
        end
        if #errors > 0 then
            return failure(errors)
        end

        local commands = {}
        local seenIds = {}
        for index, effect in ipairs(policy.effects) do
            local path = "$.card.selectionPreview.effects[" .. index .. "]"
            if type(effect) ~= "table" or getmetatable(effect) ~= nil then
                table.insert(errors, makeError(
                    "invalid_preview_effect",
                    path,
                    "선택 단계 효과는 일반 테이블이어야 합니다."
                ))
            else
                checkAllowedKeys(effect, {
                    id = true,
                    op = true,
                    target = true,
                    amount = true,
                }, path, errors)
                if type(effect.id) ~= "string"
                    or string.match(effect.id, "^[a-z][a-z0-9_]*$") == nil then
                    table.insert(errors, makeError(
                        "invalid_preview_effect_id",
                        path .. ".id",
                        "선택 단계 효과 ID는 lower_snake_case여야 합니다."
                    ))
                elseif seenIds[effect.id] then
                    table.insert(errors, makeError(
                        "duplicate_preview_effect_id",
                        path .. ".id",
                        "선택 단계 효과 ID가 중복되었습니다."
                    ))
                else
                    seenIds[effect.id] = true
                end

                local registered = type(staticData.registry.effectOps) == "table"
                    and staticData.registry.effectOps[effect.op]
                    or nil
                if type(effect.op) ~= "string" or not registered then
                    table.insert(errors, makeError(
                        "unknown_preview_op",
                        path .. ".op",
                        "등록되지 않은 선택 단계 효과 작업입니다."
                    ))
                elseif effect.op ~= "draw_cards" then
                    table.insert(errors, makeError(
                        "unsupported_preview_op",
                        path .. ".op",
                        "선택 단계 효과 v1은 draw_cards만 지원합니다."
                    ))
                end
                if effect.target ~= "player" then
                    table.insert(errors, makeError(
                        "invalid_preview_target",
                        path .. ".target",
                        "선택 단계 드로우 대상은 player여야 합니다."
                    ))
                end
                if not isInteger(effect.amount, 1) then
                    table.insert(errors, makeError(
                        "invalid_preview_amount",
                        path .. ".amount",
                        "선택 단계 드로우 수량은 1 이상의 정수여야 합니다."
                    ))
                end
                commands[index] = {
                    id = effect.id,
                    op = effect.op,
                    target = effect.target,
                    amount = effect.amount,
                }
            end
        end
        if #errors > 0 then
            return failure(errors)
        end
        return success(commands, card.id)
    end

    local SUPPORTED_COMMANDS = {
        damage_resistance = true,
        recover_resistance = true,
        lose_stealth = true,
        recover_stealth = true,
        draw_cards = true,
        skip_actions = true,
        add_mood_token = true,
        force_mood = true,
    }

    local RESOURCE_COMMANDS = {
        damage_resistance = {
            owner = "character",
            field = "resistance",
            direction = -1,
        },
        recover_resistance = {
            owner = "character",
            field = "resistance",
            direction = 1,
        },
        lose_stealth = {
            owner = "player",
            field = "stealth",
            direction = -1,
        },
        recover_stealth = {
            owner = "player",
            field = "stealth",
            direction = 1,
        },
    }

    local function addError(errors, code, path, message)
        table.insert(errors, makeError(code, path, message))
    end

    local function reportSuccess(fields)
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

    local function cloneData(value, path, active)
        path = path or "$"
        local valueType = type(value)
        if value == nil or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "효과 입력에는 유한한 숫자만 허용됩니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError(
                "non_data_value",
                path,
                "효과 입력에는 함수, 스레드, userdata를 넣을 수 없습니다."
            )
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "효과 입력에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            return nil, makeError("cyclic_value", path, "효과 입력에는 순환 참조를 사용할 수 없습니다.")
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            local keyType = type(key)
            if keyType ~= "string" and not isInteger(key, 1) then
                active[value] = nil
                return nil, makeError(
                    "invalid_table_key",
                    path,
                    "효과 입력 테이블 키는 문자열 또는 1 이상의 정수여야 합니다."
                )
            end
            local childPath = keyType == "string"
                and (path .. "." .. key)
                or (path .. "[" .. key .. "]")
            local cloned, cloneError = cloneData(item, childPath, active)
            if cloneError then
                active[value] = nil
                return nil, cloneError
            end
            copy[key] = cloned
        end
        active[value] = nil
        return copy, nil
    end

    local function appendNestedErrors(errors, prefix, nested)
        for _, item in ipairs(type(nested) == "table" and nested or {}) do
            local nestedPath = type(item.path) == "string" and item.path or "$"
            if string.sub(nestedPath, 1, 1) == "$" then
                nestedPath = prefix .. string.sub(nestedPath, 2)
            else
                nestedPath = prefix .. "." .. nestedPath
            end
            addError(
                errors,
                type(item.code) == "string" and item.code or "nested_error",
                nestedPath,
                type(item.message) == "string" and item.message or "하위 효과 처리에 실패했습니다."
            )
        end
    end

    local function validateRuntimeStaticData(staticData, requireCards)
        staticData = normalizeStaticData(staticData)
        if type(staticData) ~= "table"
            or type(staticData.registry) ~= "table"
            or type(staticData.registry.effectOps) ~= "table"
            or type(staticData.registry.moods) ~= "table"
            or (requireCards and type(staticData.cards) ~= "table") then
            return nil, {
                makeError(
                    "invalid_static_data",
                    "$.staticData",
                    "효과 평가에는 카드와 레지스트리를 포함한 전체 정적 데이터가 필요합니다."
                ),
            }
        end
        return staticData, nil
    end

    local function validateModifiers(modifiers, path)
        path = path or "$.modifiers"
        if modifiers == nil then
            return reportSuccess({ modifiers = {} })
        end
        if not isDenseArray(modifiers) then
            return failure({
                makeError("invalid_modifiers", path, "수치 보정은 연속 배열이어야 합니다."),
            })
        end
        if #modifiers > 0 then
            return failure({
                makeError(
                    "unsupported_modifiers",
                    path,
                    "일반 수치 보정 파이프라인이 확정되기 전에는 비어 있지 않은 보정을 적용할 수 없습니다."
                ),
            })
        end
        return reportSuccess({ modifiers = {} })
    end

    local function validateOptions(options)
        if options == nil then
            return {}, nil
        end
        if type(options) ~= "table" or getmetatable(options) ~= nil then
            return nil, {
                makeError("invalid_options", "$.options", "효과 옵션은 일반 테이블이어야 합니다."),
            }
        end
        for key in pairs(options) do
            if key ~= "modifiers" then
                return nil, {
                    makeError(
                        "unexpected_option",
                        "$.options." .. tostring(key),
                        "지원하지 않는 효과 옵션입니다."
                    ),
                }
            end
        end
        local modifierReport = validateModifiers(options.modifiers, "$.options.modifiers")
        if not modifierReport.ok then
            return nil, modifierReport.errors
        end
        return options, nil
    end

    local function validateCause(value, path, errors)
        if type(value) ~= "string" or value == "" then
            addError(errors, "invalid_command_cause", path, "효과 명령에는 비어 있지 않은 cause가 필요합니다.")
        end
    end

    local function checkCommandKeys(command, allowed, path, errors)
        for key in pairs(command) do
            if type(key) ~= "string" or not allowed[key] then
                addError(
                    errors,
                    "unexpected_command_field",
                    path .. "." .. tostring(key),
                    "이 효과 명령에 허용되지 않은 필드가 있습니다."
                )
            end
        end
    end

    local function validateCommands(staticData, commands)
        local normalizedStaticData, staticErrors = validateRuntimeStaticData(staticData, false)
        if staticErrors then
            return failure(staticErrors)
        end
        if not isDenseArray(commands) then
            return failure({
                makeError("invalid_commands", "$.commands", "효과 명령은 1부터 이어지는 배열이어야 합니다."),
            })
        end

        local errors = {}
        local normalized = {}
        for index, command in ipairs(commands) do
            local path = "$.commands[" .. index .. "]"
            if type(command) ~= "table" or getmetatable(command) ~= nil then
                addError(errors, "invalid_command", path, "효과 명령은 일반 테이블이어야 합니다.")
            else
                local registered = type(command.op) == "string"
                    and normalizedStaticData.registry.effectOps[command.op]
                    or nil
                if not registered then
                    addError(errors, "unknown_effect_op", path .. ".op", "등록되지 않은 효과 작업입니다.")
                elseif not SUPPORTED_COMMANDS[command.op] then
                    addError(errors, "unsupported_effect_op", path .. ".op", "v1 해결기가 지원하지 않는 효과 작업입니다.")
                end

                local common = { op = true, target = true, cause = true }
                local output = {
                    op = command.op,
                    target = command.target,
                    cause = command.cause,
                }
                validateCause(command.cause, path .. ".cause", errors)

                local resource = RESOURCE_COMMANDS[command.op]
                if resource then
                    common.amount = true
                    checkCommandKeys(command, common, path, errors)
                    if command.target ~= resource.owner then
                        addError(errors, "invalid_command_target", path .. ".target", "자원 효과 대상이 올바르지 않습니다.")
                    end
                    if not isFinite(command.amount) or command.amount < 0 then
                        addError(errors, "invalid_command_amount", path .. ".amount", "자원 효과 수치는 0 이상의 유한한 숫자여야 합니다.")
                    end
                    output.amount = command.amount
                elseif command.op == "draw_cards" then
                    common.amount = true
                    checkCommandKeys(command, common, path, errors)
                    if command.target ~= "player" and command.target ~= "character" then
                        addError(errors, "invalid_command_target", path .. ".target", "드로우 대상이 올바르지 않습니다.")
                    end
                    if not isInteger(command.amount, 1) then
                        addError(errors, "invalid_command_amount", path .. ".amount", "드로우 수량은 1 이상의 정수여야 합니다.")
                    end
                    output.amount = command.amount
                elseif command.op == "skip_actions" then
                    common.scope = true
                    checkCommandKeys(command, common, path, errors)
                    if command.target ~= "player" and command.target ~= "character" then
                        addError(errors, "invalid_command_target", path .. ".target", "행동 생략 대상이 올바르지 않습니다.")
                    end
                    if command.scope ~= "remainingTurn" then
                        addError(errors, "invalid_command_scope", path .. ".scope", "v1 행동 생략 범위는 remainingTurn이어야 합니다.")
                    end
                    output.scope = command.scope
                elseif command.op == "add_mood_token" then
                    common.amount = true
                    common.mood = true
                    checkCommandKeys(command, common, path, errors)
                    if command.target ~= "character" then
                        addError(errors, "invalid_command_target", path .. ".target", "무드 토큰 대상은 character여야 합니다.")
                    end
                    if not isInteger(command.amount, 1) then
                        addError(errors, "invalid_command_amount", path .. ".amount", "무드 토큰 수는 1 이상의 정수여야 합니다.")
                    end
                    if type(command.mood) ~= "string" or not normalizedStaticData.registry.moods[command.mood] then
                        addError(errors, "unknown_mood", path .. ".mood", "등록되지 않은 무드입니다.")
                    end
                    output.amount = command.amount
                    output.mood = command.mood
                elseif command.op == "force_mood" then
                    common.mood = true
                    checkCommandKeys(command, common, path, errors)
                    if command.target ~= "character" then
                        addError(errors, "invalid_command_target", path .. ".target", "무드 강제 변경 대상은 character여야 합니다.")
                    end
                    if type(command.mood) ~= "string" or not normalizedStaticData.registry.moods[command.mood] then
                        addError(errors, "unknown_mood", path .. ".mood", "등록되지 않은 무드입니다.")
                    end
                    output.mood = command.mood
                elseif registered and not SUPPORTED_COMMANDS[command.op] then
                    checkCommandKeys(command, common, path, errors)
                elseif not registered then
                    checkCommandKeys(command, common, path, errors)
                end
                normalized[index] = output
            end
        end
        if #errors > 0 then
            return failure(errors)
        end
        return reportSuccess({ commands = normalized })
    end

    local function prepareCallbackValue(value, path)
        local copy, cloneError = cloneData(value, path)
        if cloneError then
            return nil, failure({ cloneError })
        end
        return copy, nil
    end

    local function evaluateCommandCallback(staticData, callback, context, event, errorCode, errorPath)
        local contextCopy, contextFailure = prepareCallbackValue(context, "$.context")
        if contextFailure then
            return contextFailure
        end
        local eventCopy = nil
        if event ~= nil then
            eventCopy, contextFailure = prepareCallbackValue(event, "$.event")
            if contextFailure then
                return contextFailure
            end
        end
        local ok, returned = pcall(callback, contextCopy, eventCopy)
        if not ok then
            return failure({
                makeError(errorCode, errorPath, "효과 콜백 실행에 실패했습니다: " .. tostring(returned)),
            })
        end
        local commandReport = validateCommands(staticData, returned)
        if not commandReport.ok then
            return commandReport
        end
        return reportSuccess({ commands = commandReport.commands })
    end

    local function findRuntimeCard(staticData, cardId)
        local normalizedStaticData, staticErrors = validateRuntimeStaticData(staticData, true)
        if staticErrors then
            return nil, nil, staticErrors
        end
        if type(cardId) ~= "string" or cardId == "" then
            return nil, nil, {
                makeError("invalid_card_id", "$.cardId", "카드 ID가 없습니다."),
            }
        end
        local card = normalizedStaticData.cards[cardId]
        if type(card) ~= "table" or card.id ~= cardId then
            return nil, nil, {
                makeError("unknown_card", "$.cardId", "정적 DB에서 카드를 찾을 수 없습니다."),
            }
        end
        return normalizedStaticData, card, nil
    end

    local function evaluateCanPlay(staticData, cardId, context, options)
        local _, optionsErrors = validateOptions(options)
        if optionsErrors then
            return failure(optionsErrors)
        end
        local _, card, cardErrors = findRuntimeCard(staticData, cardId)
        if cardErrors then
            return failure(cardErrors)
        end
        if card.canPlay == nil then
            return reportSuccess({ cardId = cardId, playable = true })
        end
        if type(card.canPlay) ~= "function" then
            return failure({
                makeError("invalid_can_play", "$.card.canPlay", "카드 canPlay가 함수가 아닙니다."),
            })
        end
        local contextCopy, contextFailure = prepareCallbackValue(context, "$.context")
        if contextFailure then
            return contextFailure
        end
        local ok, playable, reasonCode, unexpected = pcall(card.canPlay, contextCopy)
        if not ok then
            return failure({
                makeError("can_play_error", "$.card.canPlay", "canPlay 실행에 실패했습니다: " .. tostring(playable)),
            })
        end
        if type(playable) ~= "boolean" then
            return failure({
                makeError("invalid_can_play_result", "$.card.canPlay", "canPlay의 첫 반환값은 불리언이어야 합니다."),
            })
        end
        if unexpected ~= nil then
            return failure({
                makeError("invalid_can_play_result", "$.card.canPlay", "canPlay는 두 값을 초과해 반환할 수 없습니다."),
            })
        end
        if playable and reasonCode ~= nil then
            return failure({
                makeError("invalid_can_play_reason", "$.card.canPlay", "사용 가능한 카드에는 실패 사유가 없어야 합니다."),
            })
        end
        if not playable and (type(reasonCode) ~= "string" or string.match(reasonCode, "^[a-z][a-z0-9_]*$") == nil) then
            return failure({
                makeError("invalid_can_play_reason", "$.card.canPlay", "사용 불가 사유는 lower_snake_case 코드여야 합니다."),
            })
        end
        return reportSuccess({
            cardId = cardId,
            playable = playable,
            reasonCode = reasonCode,
        })
    end

    local function evaluateCardResolve(staticData, cardId, context, options)
        local _, optionsErrors = validateOptions(options)
        if optionsErrors then
            return failure(optionsErrors)
        end
        local _, card, cardErrors = findRuntimeCard(staticData, cardId)
        if cardErrors then
            return failure(cardErrors)
        end
        if card.resolve == nil then
            return reportSuccess({ cardId = cardId, commands = {} })
        end
        if type(card.resolve) ~= "function" then
            return failure({
                makeError("invalid_resolve", "$.card.resolve", "카드 resolve가 함수가 아닙니다."),
            })
        end
        local evaluated = evaluateCommandCallback(
            staticData,
            card.resolve,
            context,
            nil,
            "card_resolve_error",
            "$.card.resolve"
        )
        if not evaluated.ok then
            return evaluated
        end
        evaluated.cardId = cardId
        return evaluated
    end

    local function evaluateMoodEffect(staticData, cardId, moodId, context, options)
        local _, optionsErrors = validateOptions(options)
        if optionsErrors then
            return failure(optionsErrors)
        end
        local normalizedStaticData, card, cardErrors = findRuntimeCard(staticData, cardId)
        if cardErrors then
            return failure(cardErrors)
        end
        if type(moodId) ~= "string" or not normalizedStaticData.registry.moods[moodId] then
            return failure({
                makeError("unknown_mood", "$.moodId", "등록되지 않은 무드입니다."),
            })
        end
        local callback = type(card.moodEffects) == "table" and card.moodEffects[moodId] or nil
        if callback == nil then
            return reportSuccess({ cardId = cardId, moodId = moodId, commands = {} })
        end
        if type(callback) ~= "function" then
            return failure({
                makeError("invalid_mood_callback", "$.card.moodEffects." .. moodId, "무드 효과가 함수가 아닙니다."),
            })
        end
        local evaluated = evaluateCommandCallback(
            staticData,
            callback,
            context,
            nil,
            "mood_effect_error",
            "$.card.moodEffects." .. moodId
        )
        if not evaluated.ok then
            return evaluated
        end
        evaluated.cardId = cardId
        evaluated.moodId = moodId
        return evaluated
    end

    local function validateTriggerInput(staticData, triggerSpec, event, options)
        local _, optionsErrors = validateOptions(options)
        if optionsErrors then
            return optionsErrors
        end
        local normalizedStaticData, staticErrors = validateRuntimeStaticData(staticData, false)
        if staticErrors then
            return staticErrors
        end
        if type(triggerSpec) ~= "table" or getmetatable(triggerSpec) ~= nil then
            return {
                makeError("invalid_trigger", "$.trigger", "트리거 설정은 일반 테이블이어야 합니다."),
            }
        end
        if type(event) ~= "table" or getmetatable(event) ~= nil then
            return {
                makeError("invalid_trigger_event", "$.event", "트리거 입력 사건은 일반 테이블이어야 합니다."),
            }
        end
        if type(event.type) ~= "string"
            or type(normalizedStaticData.registry.events) ~= "table"
            or not normalizedStaticData.registry.events[event.type] then
            return {
                makeError("unknown_trigger_event", "$.event.type", "등록되지 않은 트리거 입력 사건입니다."),
            }
        end
        if triggerSpec.event ~= nil
            and (type(triggerSpec.event) ~= "string"
                or not normalizedStaticData.registry.events[triggerSpec.event]) then
            return {
                makeError("unknown_trigger_event", "$.trigger.event", "트리거가 등록되지 않은 사건을 참조합니다."),
            }
        end
        if triggerSpec.side ~= nil
            and triggerSpec.side ~= "player"
            and triggerSpec.side ~= "character" then
            return {
                makeError("invalid_trigger_side", "$.trigger.side", "트리거 진영은 player 또는 character여야 합니다."),
            }
        end
        return nil
    end

    local function evaluateTriggerCondition(staticData, triggerSpec, context, event, options)
        local inputErrors = validateTriggerInput(staticData, triggerSpec, event, options)
        if inputErrors then
            return failure(inputErrors)
        end

        if triggerSpec.event ~= nil and triggerSpec.event ~= event.type then
            return reportSuccess({ matched = false })
        end
        if triggerSpec.side ~= nil and triggerSpec.side ~= event.side then
            return reportSuccess({ matched = false })
        end

        local matched = true
        if triggerSpec.trigger ~= nil then
            if type(triggerSpec.trigger) ~= "function" then
                return failure({
                    makeError("invalid_trigger_condition", "$.trigger.trigger", "트리거 조건이 함수가 아닙니다."),
                })
            end
            local contextCopy, contextFailure = prepareCallbackValue(context, "$.context")
            if contextFailure then
                return contextFailure
            end
            local eventCopy
            eventCopy, contextFailure = prepareCallbackValue(event, "$.event")
            if contextFailure then
                return contextFailure
            end
            local ok, result = pcall(triggerSpec.trigger, contextCopy, eventCopy)
            if not ok then
                return failure({
                    makeError(
                        "trigger_condition_error",
                        "$.trigger.trigger",
                        "트리거 조건 실행에 실패했습니다: " .. tostring(result)
                    ),
                })
            end
            if type(result) ~= "boolean" then
                return failure({
                    makeError("invalid_trigger_result", "$.trigger.trigger", "트리거 조건은 불리언을 반환해야 합니다."),
                })
            end
            matched = result
        end
        return reportSuccess({ matched = matched })
    end

    local function evaluateTriggerResolve(staticData, triggerSpec, context, event, options)
        local inputErrors = validateTriggerInput(staticData, triggerSpec, event, options)
        if inputErrors then
            return failure(inputErrors)
        end
        if type(triggerSpec.resolve) ~= "function" then
            return failure({
                makeError("invalid_trigger_resolve", "$.trigger.resolve", "트리거 resolve가 함수가 아닙니다."),
            })
        end

        local evaluated = evaluateCommandCallback(
            staticData,
            triggerSpec.resolve,
            context,
            event,
            "trigger_resolve_error",
            "$.trigger.resolve"
        )
        if not evaluated.ok then
            return evaluated
        end
        return evaluated
    end

    local function evaluateTrigger(staticData, triggerSpec, context, event, options)
        local condition = evaluateTriggerCondition(staticData, triggerSpec, context, event, options)
        if not condition.ok then
            return condition
        end
        if not condition.matched then
            return reportSuccess({ matched = false, commands = {} })
        end
        local evaluated = evaluateTriggerResolve(staticData, triggerSpec, context, event, options)
        if not evaluated.ok then
            return evaluated
        end
        evaluated.matched = true
        return evaluated
    end

    local function callCardZones(action, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError("runtime_unavailable", "$.runtime.cardZones", "cardZones 실행기를 찾을 수 없습니다."),
            }
        end
        local ok, report = pcall(runScript, triggerId, "cardZones", action, ...)
        if not ok then
            return nil, {
                makeError("card_zones_error", "$.runtime.cardZones", "cardZones 실행에 실패했습니다: " .. tostring(report)),
            }
        end
        if type(report) ~= "table" or report.ok ~= true or type(report.state) ~= "table" then
            local errors = {}
            appendNestedErrors(errors, "$.runtime.cardZones", type(report) == "table" and report.errors or {})
            if #errors == 0 then
                addError(errors, "card_zones_error", "$.runtime.cardZones", "cardZones가 올바른 성공 결과를 반환하지 않았습니다.")
            end
            return nil, errors
        end
        return report, nil
    end

    local function drawReceipt(state, owner)
        local receipt = {
            deckInstanceIds = {},
            handInstanceIds = {},
            discardInstanceIds = {},
            rng = {
                seed = type(state.rng) == "table" and state.rng.seed or nil,
                cursor = type(state.rng) == "table" and state.rng.cursor or nil,
            },
        }
        local grouped = {
            deck = {},
            hand = {},
            discard = {},
        }
        for _, instance in ipairs(type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if type(instance) == "table"
                and instance.owner == owner
                and grouped[instance.zone] ~= nil then
                grouped[instance.zone][#grouped[instance.zone] + 1] = instance
            end
        end
        for _, zone in ipairs({ "deck", "hand", "discard" }) do
            table.sort(grouped[zone], function(left, right)
                if left.position ~= right.position then
                    return left.position < right.position
                end
                return left.instanceId < right.instanceId
            end)
            local output = receipt[zone .. "InstanceIds"]
            for _, instance in ipairs(grouped[zone]) do
                output[#output + 1] = instance.instanceId
            end
        end
        return receipt
    end

    local function applyCommands(staticData, working, commands, options)
        local _, optionsErrors = validateOptions(options)
        if optionsErrors then
            return failure(optionsErrors)
        end
        local normalizedStaticData, staticErrors = validateRuntimeStaticData(staticData, false)
        if staticErrors then
            return failure(staticErrors)
        end
        local commandReport = validateCommands(normalizedStaticData, commands)
        if not commandReport.ok then
            return commandReport
        end
        if type(working) ~= "table" or getmetatable(working) ~= nil then
            return failure({
                makeError("invalid_working", "$.working", "효과 working 값은 일반 테이블이어야 합니다."),
            })
        end
        if type(working.state) ~= "table" then
            return failure({
                makeError("invalid_working_state", "$.working.state", "효과를 적용할 전투 상태가 없습니다."),
            })
        end
        if working.transient ~= nil and type(working.transient) ~= "table" then
            return failure({
                makeError("invalid_transient", "$.working.transient", "효과 transient 값은 테이블이어야 합니다."),
            })
        end

        local state, cloneError = cloneData(working.state, "$.working.state")
        if cloneError then
            return failure({ cloneError })
        end
        local transient
        transient, cloneError = cloneData(working.transient or {}, "$.working.transient")
        if cloneError then
            return failure({ cloneError })
        end

        local applied = {}
        for index, command in ipairs(commandReport.commands) do
            local entry = {
                index = index,
                op = command.op,
                target = command.target,
                cause = command.cause,
                changed = false,
            }
            local resource = RESOURCE_COMMANDS[command.op]
            if resource then
                local ownerState = state[resource.owner]
                local before = type(ownerState) == "table" and ownerState[resource.field] or nil
                if not isFinite(before) then
                    return failure({
                        makeError(
                            "invalid_resource_state",
                            "$.working.state." .. resource.owner .. "." .. resource.field,
                            "효과 대상 자원이 유한한 숫자가 아닙니다."
                        ),
                    })
                end
                local after = before + resource.direction * command.amount
                if not isFinite(after) then
                    return failure({
                        makeError("non_finite_result", "$.commands[" .. index .. "]", "효과 결과가 유한한 숫자 범위를 벗어났습니다."),
                    })
                end
                ownerState[resource.field] = after
                entry.amount = command.amount
                entry.before = before
                entry.after = after
                entry.changed = before ~= after
            elseif command.op == "draw_cards" then
                local before = drawReceipt(state, command.target)
                local zoneReport, zoneErrors = callCardZones("draw", state, command.target, command.amount)
                if zoneErrors then
                    return failure(zoneErrors)
                end
                state = zoneReport.state
                entry.amount = command.amount
                entry.drawnInstanceIds = zoneReport.drawnInstanceIds or {}
                entry.before = before
                entry.after = drawReceipt(state, command.target)
                entry.changed = #entry.drawnInstanceIds > 0
            elseif command.op == "skip_actions" then
                if transient.skipRemaining == nil then
                    transient.skipRemaining = { player = false, character = false }
                elseif type(transient.skipRemaining) ~= "table" then
                    return failure({
                        makeError("invalid_skip_state", "$.working.transient.skipRemaining", "남은 행동 생략 상태가 테이블이 아닙니다."),
                    })
                end
                local before = transient.skipRemaining[command.target] == true
                transient.skipRemaining[command.target] = true
                entry.scope = command.scope
                entry.before = before
                entry.after = true
                entry.changed = not before
            elseif command.op == "add_mood_token" then
                if type(state.character) ~= "table" then
                    return failure({
                        makeError("invalid_mood_state", "$.working.state.character", "캐릭터 무드 상태가 없습니다."),
                    })
                end
                if state.character.moodTokens == nil then
                    state.character.moodTokens = {}
                end
                if type(state.character.moodTokens) ~= "table" then
                    return failure({
                        makeError("invalid_mood_tokens", "$.working.state.character.moodTokens", "무드 토큰 상태가 테이블이 아닙니다."),
                    })
                end
                for moodId in pairs(normalizedStaticData.registry.moods) do
                    local count = state.character.moodTokens[moodId]
                    if count == nil then
                        state.character.moodTokens[moodId] = 0
                    elseif not isInteger(count, 0) then
                        return failure({
                            makeError("invalid_mood_token_count", "$.working.state.character.moodTokens." .. moodId, "무드 토큰 수가 0 이상의 정수가 아닙니다."),
                        })
                    end
                end
                local before = state.character.moodTokens[command.mood] or 0
                if not isInteger(before, 0) then
                    return failure({
                        makeError("invalid_mood_token_count", "$.working.state.character.moodTokens." .. command.mood, "무드 토큰 수가 0 이상의 정수가 아닙니다."),
                    })
                end
                local after = before + command.amount
                if after > 9007199254740991 then
                    return failure({
                        makeError("mood_token_overflow", "$.commands[" .. index .. "].amount", "무드 토큰 수가 안전한 정수 범위를 벗어났습니다."),
                    })
                end
                entry.mood = command.mood
                entry.amount = command.amount
                entry.before = before
                entry.after = after
                entry.changed = true
                state.character.moodTokens[command.mood] = after
            elseif command.op == "force_mood" then
                if transient.forcedMoodRequests == nil then
                    transient.forcedMoodRequests = {}
                elseif not isDenseArray(transient.forcedMoodRequests) then
                    return failure({
                        makeError("invalid_forced_mood_requests", "$.working.transient.forcedMoodRequests", "무드 강제 변경 요청이 연속 배열이 아닙니다."),
                    })
                end
                entry.mood = command.mood
                entry.before = #transient.forcedMoodRequests
                transient.forcedMoodRequests[#transient.forcedMoodRequests + 1] = {
                    mood = command.mood,
                    cause = command.cause,
                }
                entry.after = #transient.forcedMoodRequests
                entry.changed = true
            end
            applied[index] = entry
        end
        return reportSuccess({
            state = state,
            transient = transient,
            commands = commandReport.commands,
            applied = applied,
        })
    end

    local arguments = { ... }
    local actions = {
        evaluateSelectionPreview = evaluateSelectionPreview,
        evaluateCanPlay = evaluateCanPlay,
        evaluateCardResolve = evaluateCardResolve,
        evaluateMoodEffect = evaluateMoodEffect,
        evaluateTriggerCondition = evaluateTriggerCondition,
        evaluateTriggerResolve = evaluateTriggerResolve,
        evaluateTrigger = evaluateTrigger,
        validateCommands = validateCommands,
        validateModifiers = validateModifiers,
        applyCommands = applyCommands,
    }
    local handler = actions[action]
    if not handler then
        return failure({
            makeError(
                "unknown_action",
                "$.action",
                "지원하지 않는 효과 엔진 작업입니다: " .. tostring(action)
            ),
        })
    end
    return handler(arguments[1], arguments[2], arguments[3], arguments[4], arguments[5])
end)
