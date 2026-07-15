(function(triggerId, action)
    local SUPPORTED_SCHEMA_VERSION = 1

    local SOURCES = {
        registry = {
            kind = "gameRegistry",
            collection = nil,
            lores = { "GameRegistry.db" },
        },
        cards = {
            kind = "cardDatabase",
            collection = "cards",
            lores = { "PlayerCards.db", "CharacterCards.db" },
        },
        traits = {
            kind = "traitDatabase",
            collection = "traits",
            lores = { "CharTraits.db" },
        },
        environments = {
            kind = "environmentDatabase",
            collection = "environments",
            lores = { "Environments.db" },
        },
        characters = {
            kind = "characterDatabase",
            collection = "characters",
            lores = { "YooJiyoung.db" },
        },
    }

    local function addError(errors, code, path, message)
        table.insert(errors, {
            code = code,
            path = path,
            message = message,
        })
    end

    local function countEntries(value)
        if type(value) ~= "table" then
            return 0
        end

        local count = 0
        for _ in pairs(value) do
            count = count + 1
        end
        return count
    end

    local function isArray(value)
        if type(value) ~= "table" then
            return false
        end

        local count = 0
        local maximum = 0
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                return false
            end
            count = count + 1
            if key > maximum then
                maximum = key
            end
        end

        return count == maximum
    end

    local function isFiniteNonNegative(value)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
            and value >= 0
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function makeDatabaseEnvironment()
        return {
            ipairs = ipairs,
            next = next,
            pairs = pairs,
            tonumber = tonumber,
            tostring = tostring,
            type = type,
        }
    end

    local function loadLoreModules(loreName, errors)
        local lores = getLoreBooks(triggerId, loreName)
        if type(lores) ~= "table" or #lores == 0 then
            addError(errors, "missing_lore", loreName, "정적 DB 로어북을 찾을 수 없습니다.")
            return {}
        end

        local modules = {}
        for index, lore in ipairs(lores) do
            if type(lore) ~= "table" or type(lore.content) ~= "string" then
                addError(errors, "invalid_lore", loreName .. "[" .. index .. "]", "로어북 내용이 문자열이 아닙니다.")
            else
                local chunk, compileError = load(
                    lore.content,
                    "static_db:" .. loreName .. ":" .. index,
                    "t",
                    makeDatabaseEnvironment()
                )

                if not chunk then
                    addError(errors, "compile_error", loreName .. "[" .. index .. "]", tostring(compileError))
                else
                    local ok, result = pcall(chunk)
                    if not ok then
                        addError(errors, "load_error", loreName .. "[" .. index .. "]", tostring(result))
                    elseif type(result) ~= "table" then
                        addError(errors, "invalid_module", loreName .. "[" .. index .. "]", "DB 청크가 테이블을 반환하지 않았습니다.")
                    else
                        table.insert(modules, result)
                    end
                end
            end
        end

        return modules
    end

    local function validateModuleHeader(module, expectedKind, path, errors)
        if module.schemaVersion ~= SUPPORTED_SCHEMA_VERSION then
            addError(errors, "unsupported_schema", path .. ".schemaVersion", "지원하지 않는 스키마 버전입니다.")
        end

        if module.kind ~= expectedKind then
            addError(errors, "unexpected_kind", path .. ".kind", "예상한 DB 종류와 다릅니다.")
        end
    end

    local function loadSingleModule(source, errors)
        local loaded = nil

        for _, loreName in ipairs(source.lores) do
            local modules = loadLoreModules(loreName, errors)
            for index, module in ipairs(modules) do
                local path = loreName .. "[" .. index .. "]"
                validateModuleHeader(module, source.kind, path, errors)

                if loaded then
                    addError(errors, "duplicate_module", path, "단일 DB가 여러 번 등록되었습니다.")
                else
                    loaded = module
                end
            end
        end

        return loaded
    end

    local function loadMergedCollection(source, errors)
        local merged = {}
        local origins = {}

        for _, loreName in ipairs(source.lores) do
            local modules = loadLoreModules(loreName, errors)
            for index, module in ipairs(modules) do
                local modulePath = loreName .. "[" .. index .. "]"
                validateModuleHeader(module, source.kind, modulePath, errors)

                local collection = module[source.collection]
                if type(collection) ~= "table" then
                    addError(errors, "missing_collection", modulePath .. "." .. source.collection, "DB 컬렉션이 없습니다.")
                else
                    for id, definition in pairs(collection) do
                        local itemPath = modulePath .. "." .. source.collection .. "." .. tostring(id)
                        if merged[id] ~= nil then
                            addError(
                                errors,
                                "duplicate_id",
                                itemPath,
                                "이미 " .. tostring(origins[id]) .. "에서 정의된 ID입니다."
                            )
                        else
                            merged[id] = definition
                            origins[id] = itemPath
                        end
                    end
                end
            end
        end

        return merged
    end

    local function validateRegistryCollection(collection, path, errors, ownerRequired)
        if type(collection) ~= "table" then
            addError(errors, "missing_registry", path, "레지스트리 컬렉션이 없습니다.")
            return
        end

        for key, entry in pairs(collection) do
            local entryPath = path .. "." .. tostring(key)
            if not isAsciiId(key) then
                addError(errors, "invalid_id", entryPath, "레지스트리 키는 ASCII ID여야 합니다.")
            end
            if type(entry) ~= "table" or entry.id ~= key then
                addError(errors, "id_mismatch", entryPath, "레지스트리 키와 내부 ID가 다릅니다.")
            elseif ownerRequired and entry.owner ~= "player" and entry.owner ~= "character" then
                addError(errors, "invalid_owner", entryPath .. ".owner", "행동 태그 소유자가 올바르지 않습니다.")
            end
        end
    end

    local function validateRegistry(registry, errors)
        if type(registry) ~= "table" then
            addError(errors, "missing_registry", "registry", "중앙 게임 레지스트리가 없습니다.")
            return
        end

        validateRegistryCollection(registry.actionTags, "registry.actionTags", errors, true)
        validateRegistryCollection(registry.mechanisms, "registry.mechanisms", errors, false)
        validateRegistryCollection(registry.moods, "registry.moods", errors, false)
        validateRegistryCollection(registry.events, "registry.events", errors, false)
        validateRegistryCollection(registry.effectOps, "registry.effectOps", errors, false)

        if type(registry.actionTags) == "table" and type(registry.mechanisms) == "table" then
            for id in pairs(registry.actionTags) do
                if registry.mechanisms[id] then
                    addError(errors, "registry_id_collision", "registry." .. id, "행동 태그와 메커니즘 ID가 중복됩니다.")
                end
            end
        end
    end

    local function hasTagToken(description, id)
        return type(description) == "string"
            and type(id) == "string"
            and string.find(description, "::tag[" .. id .. "]::", 1, true) ~= nil
    end

    local function validateTagTokens(text, path, registry, errors)
        if type(text) ~= "string" then
            return
        end

        local remainder = string.gsub(text, "::tag%[[a-z][a-z0-9_]*%]::", "")
        if string.find(remainder, "::tag[", 1, true) then
            addError(errors, "malformed_tag_token", path, "형식이 잘못된 태그 토큰이 있습니다.")
        end

        for tagId in string.gmatch(text, "::tag%[([a-z][a-z0-9_]*)%]::") do
            local knownAction = type(registry) == "table"
                and type(registry.actionTags) == "table"
                and registry.actionTags[tagId]
            local knownMechanism = type(registry) == "table"
                and type(registry.mechanisms) == "table"
                and registry.mechanisms[tagId]

            if not knownAction and not knownMechanism then
                addError(errors, "unknown_tag_token", path, "등록되지 않은 태그 토큰입니다: " .. tagId)
            end
        end
    end

    local function validateNarration(card, path, isPlan, errors)
        if type(card.narration) ~= "table" then
            addError(errors, "missing_narration", path .. ".narration", "카드 묘사가 없습니다.")
            return
        end

        if isPlan then
            if type(card.narration.planPlaced) ~= "table"
                or type(card.narration.planPlaced.actorAction) ~= "string"
                or card.narration.planPlaced.actorAction == "" then
                addError(errors, "missing_plan_placed_narration", path .. ".narration.planPlaced", "계획 배치 묘사가 없습니다.")
            end
            if type(card.narration.planTriggered) ~= "table"
                or type(card.narration.planTriggered.actorAction) ~= "string"
                or card.narration.planTriggered.actorAction == "" then
                addError(errors, "missing_plan_triggered_narration", path .. ".narration.planTriggered", "계획 발동 묘사가 없습니다.")
            end
        elseif type(card.narration.play) ~= "table"
            or type(card.narration.play.actorAction) ~= "string"
            or card.narration.play.actorAction == "" then
            addError(errors, "missing_play_narration", path .. ".narration.play", "카드 사용 묘사가 없습니다.")
        end
    end

    local function validateCards(cards, registry, errors)
        if type(cards) ~= "table" then
            addError(errors, "missing_cards", "cards", "카드 컬렉션이 없습니다.")
            return
        end

        for key, card in pairs(cards) do
            local path = "cards." .. tostring(key)
            if not isAsciiId(key) then
                addError(errors, "invalid_id", path, "카드 키는 ASCII ID여야 합니다.")
            end

            if type(card) ~= "table" then
                addError(errors, "invalid_card", path, "카드 정의가 테이블이 아닙니다.")
            else
                if card.id ~= key then
                    addError(errors, "id_mismatch", path .. ".id", "카드 키와 내부 ID가 다릅니다.")
                end
                if card.owner ~= "player" and card.owner ~= "character" then
                    addError(errors, "invalid_owner", path .. ".owner", "카드 소유자가 올바르지 않습니다.")
                end
                if type(card.name) ~= "string" or card.name == "" then
                    addError(errors, "missing_name", path .. ".name", "카드 이름이 없습니다.")
                end
                if type(card.description) ~= "string" or card.description == "" then
                    addError(errors, "missing_description", path .. ".description", "카드 설명이 없습니다.")
                end
                validateTagTokens(card.description, path .. ".description", registry, errors)

                local action = type(registry) == "table"
                    and type(registry.actionTags) == "table"
                    and registry.actionTags[card.actionTag]
                    or nil
                if not action then
                    addError(errors, "unknown_action_tag", path .. ".actionTag", "등록되지 않은 행동 태그입니다.")
                elseif action.owner ~= card.owner then
                    addError(errors, "action_owner_mismatch", path .. ".actionTag", "행동 태그 소유자와 카드 소유자가 다릅니다.")
                end
                if not hasTagToken(card.description, card.actionTag) then
                    addError(errors, "missing_action_token", path .. ".description", "설명에 자신의 행동 태그 토큰이 없습니다.")
                end

                if not isArray(card.mechanisms) then
                    addError(errors, "invalid_mechanisms", path .. ".mechanisms", "메커니즘 목록이 배열이 아닙니다.")
                else
                    local seenMechanisms = {}
                    for index, mechanismId in ipairs(card.mechanisms) do
                        local mechanismPath = path .. ".mechanisms[" .. index .. "]"
                        if type(registry) ~= "table"
                            or type(registry.mechanisms) ~= "table"
                            or not registry.mechanisms[mechanismId] then
                            addError(errors, "unknown_mechanism", mechanismPath, "등록되지 않은 메커니즘입니다.")
                        end
                        if seenMechanisms[mechanismId] then
                            addError(errors, "duplicate_mechanism", mechanismPath, "같은 메커니즘이 중복되었습니다.")
                        end
                        seenMechanisms[mechanismId] = true
                        if not hasTagToken(card.description, mechanismId) then
                            addError(errors, "missing_mechanism_token", path .. ".description", "설명에 메커니즘 태그 토큰이 없습니다.")
                        end
                    end

                    if type(card.mechanismData) == "table" then
                        for mechanismId in pairs(card.mechanismData) do
                            if not seenMechanisms[mechanismId] then
                                addError(errors, "orphan_mechanism_data", path .. ".mechanismData." .. tostring(mechanismId), "보유하지 않은 메커니즘의 설정입니다.")
                            end
                        end
                    end

                    local hasPlan = seenMechanisms.plan == true
                    local plan = type(card.mechanismData) == "table" and card.mechanismData.plan or nil
                    if hasPlan then
                        if type(plan) ~= "table" then
                            addError(errors, "missing_plan_data", path .. ".mechanismData.plan", "계획 설정이 없습니다.")
                        else
                            local hasLifetime = isFiniteNonNegative(plan.durationTurns) and plan.durationTurns > 0
                                or isFiniteNonNegative(plan.charges) and plan.charges > 0
                                or type(plan.expires) == "function"
                            if not hasLifetime then
                                addError(errors, "unlimited_plan", path .. ".mechanismData.plan", "계획 수명이 제한되지 않았습니다.")
                            end
                            if type(plan.trigger) ~= "function" then
                                addError(errors, "invalid_plan_trigger", path .. ".mechanismData.plan.trigger", "계획 조건이 함수가 아닙니다.")
                            end
                            if type(plan.resolve) ~= "function" then
                                addError(errors, "invalid_plan_resolve", path .. ".mechanismData.plan.resolve", "계획 효과가 함수가 아닙니다.")
                            end
                        end
                    elseif plan ~= nil then
                        addError(errors, "unexpected_plan_data", path .. ".mechanismData.plan", "계획 메커니즘이 없는 카드에 계획 설정이 있습니다.")
                    end

                    validateNarration(card, path, hasPlan, errors)
                end

                if type(card.base) ~= "table" then
                    addError(errors, "missing_base", path .. ".base", "카드 기본 수치가 없습니다.")
                else
                    if not isFiniteNonNegative(card.base.stealthCost) then
                        addError(errors, "invalid_stealth_cost", path .. ".base.stealthCost", "기본 은폐 비용이 0 이상의 유한한 숫자가 아닙니다.")
                    end
                    if not isFiniteNonNegative(card.base.resistanceDamage) then
                        addError(errors, "invalid_resistance_damage", path .. ".base.resistanceDamage", "기본 저항 피해가 0 이상의 유한한 숫자가 아닙니다.")
                    end
                end

                if not isArray(card.rules) or #card.rules == 0 then
                    addError(errors, "invalid_rules", path .. ".rules", "카드 규칙 문장이 비어 있습니다.")
                else
                    for index, rule in ipairs(card.rules) do
                        if type(rule) ~= "string" or rule == "" then
                            addError(errors, "invalid_rule", path .. ".rules[" .. index .. "]", "카드 규칙이 빈 문자열이거나 문자열이 아닙니다.")
                        else
                            validateTagTokens(rule, path .. ".rules[" .. index .. "]", registry, errors)
                        end
                    end
                end
                if card.canPlay ~= nil and type(card.canPlay) ~= "function" then
                    addError(errors, "invalid_can_play", path .. ".canPlay", "사용 조건이 함수가 아닙니다.")
                end
                if card.resolve ~= nil and type(card.resolve) ~= "function" then
                    addError(errors, "invalid_resolve", path .. ".resolve", "카드 효과가 함수가 아닙니다.")
                end
                if card.moodEffects ~= nil then
                    if type(card.moodEffects) ~= "table" then
                        addError(errors, "invalid_mood_effects", path .. ".moodEffects", "무드 효과가 테이블이 아닙니다.")
                    else
                        for moodId, callback in pairs(card.moodEffects) do
                            if type(registry) ~= "table"
                                or type(registry.moods) ~= "table"
                                or not registry.moods[moodId] then
                                addError(errors, "unknown_mood", path .. ".moodEffects." .. tostring(moodId), "등록되지 않은 무드입니다.")
                            end
                            if type(callback) ~= "function" then
                                addError(errors, "invalid_mood_callback", path .. ".moodEffects." .. tostring(moodId), "무드 효과가 함수가 아닙니다.")
                            end
                        end
                    end
                end
            end
        end
    end

    local function validateTraits(traits, errors)
        if type(traits) ~= "table" then
            addError(errors, "missing_traits", "traits", "특징 컬렉션이 없습니다.")
            return
        end

        for key, trait in pairs(traits) do
            local path = "traits." .. tostring(key)
            if not isAsciiId(key) or type(trait) ~= "table" or trait.id ~= key then
                addError(errors, "invalid_trait_id", path, "특징 키와 내부 ID가 올바르지 않습니다.")
            else
                if trait.owner ~= "player" and trait.owner ~= "character" then
                    addError(errors, "invalid_owner", path .. ".owner", "특징 소유자가 올바르지 않습니다.")
                end
                if trait.visibility ~= "public" and trait.visibility ~= "hidden" then
                    addError(errors, "invalid_visibility", path .. ".visibility", "특징 공개 범위가 올바르지 않습니다.")
                end
                if type(trait.name) ~= "string" or trait.name == "" then
                    addError(errors, "missing_name", path .. ".name", "특징 이름이 없습니다.")
                end
                if type(trait.description) ~= "string" or trait.description == "" then
                    addError(errors, "missing_description", path .. ".description", "특징 설명이 없습니다.")
                end
                if not isArray(trait.rules) or #trait.rules == 0 then
                    addError(errors, "invalid_rules", path .. ".rules", "특징 규칙 문장이 비어 있습니다.")
                end
                if not isArray(trait.modifiers) or #trait.modifiers == 0 then
                    addError(errors, "invalid_modifiers", path .. ".modifiers", "특징 보정 목록이 비어 있습니다.")
                else
                    for index, modifier in ipairs(trait.modifiers) do
                        local modifierPath = path .. ".modifiers[" .. index .. "]"
                        if type(modifier) ~= "table"
                            or modifier.timing ~= "moodPerformanceThreshold"
                            or modifier.operation ~= "add"
                            or modifier.direction ~= "compliance"
                            or not isFiniteNonNegative(modifier.amount)
                            or modifier.amount == 0 then
                            addError(errors, "invalid_modifier", modifierPath, "지원하지 않는 특징 보정입니다.")
                        end
                    end
                end
            end
        end
    end

    local function validateEnvironments(environments, registry, errors)
        if type(environments) ~= "table" then
            addError(errors, "missing_environments", "environments", "환경 컬렉션이 없습니다.")
            return
        end

        for key, environment in pairs(environments) do
            local path = "environments." .. tostring(key)
            if not isAsciiId(key) or type(environment) ~= "table" or environment.id ~= key then
                addError(errors, "invalid_environment_id", path, "환경 키와 내부 ID가 올바르지 않습니다.")
            else
                if type(environment.name) ~= "string" or environment.name == "" then
                    addError(errors, "missing_name", path .. ".name", "환경 이름이 없습니다.")
                end
                if type(environment.description) ~= "string" or environment.description == "" then
                    addError(errors, "missing_description", path .. ".description", "환경 설명이 없습니다.")
                end
                if not isArray(environment.rules) or #environment.rules == 0 then
                    addError(errors, "invalid_rules", path .. ".rules", "환경 규칙 문장이 비어 있습니다.")
                end
                if not isArray(environment.triggers) or #environment.triggers == 0 then
                    addError(errors, "invalid_triggers", path .. ".triggers", "환경 트리거가 비어 있습니다.")
                else
                    for index, trigger in ipairs(environment.triggers) do
                        local triggerPath = path .. ".triggers[" .. index .. "]"
                        if type(trigger) ~= "table" then
                            addError(errors, "invalid_trigger", triggerPath, "환경 트리거가 테이블이 아닙니다.")
                        else
                            if type(registry) ~= "table"
                                or type(registry.events) ~= "table"
                                or not registry.events[trigger.event] then
                                addError(errors, "unknown_event", triggerPath .. ".event", "등록되지 않은 사건입니다.")
                            end
                            if trigger.side ~= "player" and trigger.side ~= "character" then
                                addError(errors, "invalid_side", triggerPath .. ".side", "트리거 진영이 올바르지 않습니다.")
                            end
                            if type(trigger.resolve) ~= "function" then
                                addError(errors, "invalid_resolve", triggerPath .. ".resolve", "환경 효과가 함수가 아닙니다.")
                            end
                        end
                    end
                end
            end
        end
    end

    local function validateCharacterTagList(values, path, registry, errors)
        if not isArray(values) then
            addError(errors, "invalid_action_tags", path, "행동 태그 목록이 배열이 아닙니다.")
            return
        end

        for index, actionTag in ipairs(values) do
            local action = type(registry) == "table"
                and type(registry.actionTags) == "table"
                and registry.actionTags[actionTag]
                or nil
            if not action or action.owner ~= "character" then
                addError(errors, "invalid_character_action", path .. "[" .. index .. "]", "캐릭터 행동 태그가 아닙니다.")
            end
        end
    end

    local function validateCharacters(characters, cards, traits, registry, errors)
        if type(characters) ~= "table" then
            addError(errors, "missing_characters", "characters", "캐릭터 컬렉션이 없습니다.")
            return
        end

        for key, character in pairs(characters) do
            local path = "characters." .. tostring(key)
            if not isAsciiId(key) or type(character) ~= "table" or character.id ~= key then
                addError(errors, "invalid_character_id", path, "캐릭터 키와 내부 ID가 올바르지 않습니다.")
            else
                if type(character.name) ~= "string" or character.name == "" then
                    addError(errors, "missing_name", path .. ".name", "캐릭터 이름이 없습니다.")
                end
                if type(character.publicProfile) ~= "table" then
                    addError(errors, "missing_public_profile", path .. ".publicProfile", "공개 프로필이 없습니다.")
                end
                if character.privateProfile ~= nil and type(character.privateProfile) ~= "table" then
                    addError(errors, "invalid_private_profile", path .. ".privateProfile", "비공개 프로필이 테이블이 아닙니다.")
                end

                local battle = character.battle
                if type(battle) ~= "table" then
                    addError(errors, "missing_battle", path .. ".battle", "전투 정의가 없습니다.")
                else
                    if not isFiniteNonNegative(battle.startingResistance) or battle.startingResistance == 0 then
                        addError(errors, "invalid_starting_resistance", path .. ".battle.startingResistance", "시작 저항이 양수의 유한한 숫자가 아닙니다.")
                    end
                    if type(registry) ~= "table"
                        or type(registry.moods) ~= "table"
                        or not registry.moods[battle.startingMood] then
                        addError(errors, "unknown_starting_mood", path .. ".battle.startingMood", "등록되지 않은 시작 무드입니다.")
                    end

                    if not isArray(battle.traitIds) then
                        addError(errors, "invalid_trait_ids", path .. ".battle.traitIds", "특징 ID 목록이 배열이 아닙니다.")
                    else
                        for index, traitId in ipairs(battle.traitIds) do
                            local trait = traits[traitId]
                            if not trait or trait.owner ~= "character" then
                                addError(errors, "unknown_character_trait", path .. ".battle.traitIds[" .. index .. "]", "캐릭터 특징을 찾을 수 없습니다.")
                            end
                        end
                    end

                    if not isArray(battle.deck) or #battle.deck == 0 then
                        addError(errors, "invalid_character_deck", path .. ".battle.deck", "캐릭터 덱이 비어 있거나 배열이 아닙니다.")
                    else
                        for index, cardId in ipairs(battle.deck) do
                            local card = cards[cardId]
                            if not card or card.owner ~= "character" then
                                addError(errors, "invalid_character_card", path .. ".battle.deck[" .. index .. "]", "캐릭터 카드를 찾을 수 없습니다.")
                            end
                        end
                    end

                    local profile = battle.selectionProfile
                    if type(profile) ~= "table" then
                        addError(errors, "missing_selection_profile", path .. ".battle.selectionProfile", "행동 선택 성향이 없습니다.")
                    else
                        validateCharacterTagList(profile.preferredActionTags, path .. ".battle.selectionProfile.preferredActionTags", registry, errors)
                        validateCharacterTagList(profile.excludedActionTags, path .. ".battle.selectionProfile.excludedActionTags", registry, errors)
                    end
                end
            end
        end
    end

    local function loadAndValidateAll()
        local errors = {}
        local registry = loadSingleModule(SOURCES.registry, errors)
        local cards = loadMergedCollection(SOURCES.cards, errors)
        local traits = loadMergedCollection(SOURCES.traits, errors)
        local environments = loadMergedCollection(SOURCES.environments, errors)
        local characters = loadMergedCollection(SOURCES.characters, errors)

        validateRegistry(registry, errors)
        validateCards(cards, registry, errors)
        validateTraits(traits, errors)
        validateEnvironments(environments, registry, errors)
        validateCharacters(characters, cards, traits, registry, errors)

        return {
            ok = #errors == 0,
            schemaVersion = SUPPORTED_SCHEMA_VERSION,
            errors = errors,
            counts = {
                cards = countEntries(cards),
                traits = countEntries(traits),
                environments = countEntries(environments),
                characters = countEntries(characters),
            },
            data = #errors == 0 and {
                registry = registry,
                cards = cards,
                traits = traits,
                environments = environments,
                characters = characters,
            } or nil,
        }
    end

    local actions = {
        loadAll = loadAndValidateAll,
        validateAll = function()
            local result = loadAndValidateAll()
            result.data = nil
            return result
        end,
    }

    local handler = actions[action]
    if not handler then
        return {
            ok = false,
            schemaVersion = SUPPORTED_SCHEMA_VERSION,
            errors = {
                {
                    code = "unknown_action",
                    path = "staticData",
                    message = "지원하지 않는 정적 데이터 작업입니다: " .. tostring(action),
                },
            },
        }
    end

    return handler()
end)
