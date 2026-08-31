(function()
    local STATIC_CACHE_MAX_ENTRIES = 4
    local MAX_PLAN_CAPACITY = 16
    local DIAGNOSTIC_SCOPE = "helltrain.staticData"
    local STATIC_BASE_LORE_ORDER = {
        "GameRegistry.db",
        "PlayerCards.db",
        "CharacterCards.db",
        "CharTraits.db",
        "TokyoSubwayLines.db",
        "CharacterList.db",
    }
    local staticCacheEntries = {}
    local staticCacheClock = 0
    local staticCacheStats = {
        requests = 0,
        captures = 0,
        fastHits = 0,
        hits = 0,
        misses = 0,
        validations = 0,
        failedValidations = 0,
        evictions = 0,
        clears = 0,
    }

    -- 호스트 진단 출력은 print 한 줄로 통일한다. DB 본문이나 프로필은 남기지
    -- 않고 로어 이름, 개수, 헤더와 오류 경로만 기록한다.
    local function diagnosticsEnabled(depth)
        return type(DEBUG) == "number" and depth <= DEBUG
    end

    local function diagnosticText(value)
        return tostring(value):gsub("[\r\n]+", " ")
    end

    local function emitDiagnostic(depth, event, fields)
        if not diagnosticsEnabled(depth) then
            return
        end

        if type(print) ~= "function" then
            return
        end

        local parts = {
            "[" .. DIAGNOSTIC_SCOPE .. "]",
            "depth=" .. tostring(depth),
            "event=" .. diagnosticText(event),
        }
        local fieldOrder = {
            "action", "forceRefresh", "cachedEntries", "cache", "ok",
            "lore", "status", "entryCount", "error", "entryIndex",
            "schemaVersion", "kindType", "kind", "code", "path", "message",
            "expectedKind", "actualKindType", "actualKind", "errorCount",
            "cards", "traits", "subwayLines", "characters",
        }
        for _, key in ipairs(fieldOrder) do
            local value = type(fields) == "table" and fields[key] or nil
            if value ~= nil then
                parts[#parts + 1] = key .. "=" .. diagnosticText(value)
            end
        end
        pcall(print, table.concat(parts, " | "))
    end

    -- 캐시의 canonical snapshot을 호출자에게 직접 노출하지 않는다. 함수는 정적
    -- DB callback이므로 identity를 유지하고, 모든 table은 alias가 없도록 복제한다.
    local function cloneStaticValue(value, seen)
        if type(value) ~= "table" then
            return value
        end

        seen = seen or {}
        if seen[value] ~= nil then
            return seen[value]
        end

        local copy = {}
        seen[value] = copy
        for key, item in pairs(value) do
            copy[cloneStaticValue(key, seen)] = cloneStaticValue(item, seen)
        end
        return copy
    end

    -- getLoreBooks 결과의 metadata는 DB 판정에 사용하지 않는다. 개발/강제 refresh
    -- 경로에서는 content와 순서 전체를 비교해 context 오염과 stale hit를 막는다.
    -- production fast path의 배포 무효화는 main의 RUNTIME_BUNDLE_REVISION 계약이다.
    local function captureStaticLore(triggerId, captured, loreName)
        if captured[loreName] ~= nil then
            return
        end

        local ok, lores = pcall(getLoreBooks, triggerId, loreName)
        local source = {
            status = ok and type(lores) or "read_error",
            entries = {},
        }
        if not ok then
            source.error = tostring(lores)
        elseif type(lores) == "table" then
            for _, lore in ipairs(lores) do
                if type(lore) == "table" and type(lore.content) == "string" then
                    table.insert(source.entries, {
                        valid = true,
                        content = lore.content,
                    })
                else
                    table.insert(source.entries, {
                        valid = false,
                        loreType = type(lore),
                        contentType = type(lore) == "table" and type(lore.content) or "none",
                    })
                end
            end
        end
        captured[loreName] = source
        table.insert(captured.order, loreName)

        emitDiagnostic(source.status == "read_error" and 1 or 2, "lore_capture", {
            lore = loreName,
            status = source.status,
            entryCount = #source.entries,
            error = source.error,
        })
    end

    local function captureBaseStaticLores(triggerId)
        staticCacheStats.captures = staticCacheStats.captures + 1
        local captured = {
            order = {},
        }
        for _, loreName in ipairs(STATIC_BASE_LORE_ORDER) do
            captureStaticLore(triggerId, captured, loreName)
        end
        return captured
    end

    local function sameStaticLoreSource(leftSource, rightSource)
        if leftSource == nil
            or rightSource == nil
            or leftSource.status ~= rightSource.status
            or leftSource.error ~= rightSource.error
            or #leftSource.entries ~= #rightSource.entries then
            return false
        end
        for index, leftEntry in ipairs(leftSource.entries) do
            local rightEntry = rightSource.entries[index]
            if rightEntry == nil
                or leftEntry.valid ~= rightEntry.valid
                or leftEntry.content ~= rightEntry.content
                or leftEntry.loreType ~= rightEntry.loreType
                or leftEntry.contentType ~= rightEntry.contentType then
                return false
            end
        end
        return true
    end

    local function sameStaticLoreCapture(left, right)
        if type(left.order) ~= "table"
            or type(right.order) ~= "table"
            or #left.order ~= #right.order then
            return false
        end
        for index, loreName in ipairs(left.order) do
            if right.order[index] ~= loreName
                or not sameStaticLoreSource(left[loreName], right[loreName]) then
                return false
            end
        end
        return true
    end

    local function findCachedDynamicLoreOrder(captured)
        for _, entry in ipairs(staticCacheEntries) do
            local sameBase = true
            for _, loreName in ipairs(STATIC_BASE_LORE_ORDER) do
                if not sameStaticLoreSource(entry.sources[loreName], captured[loreName]) then
                    sameBase = false
                    break
                end
            end
            if sameBase then
                local dynamicOrder = {}
                for index = #STATIC_BASE_LORE_ORDER + 1, #entry.sources.order do
                    table.insert(dynamicOrder, entry.sources.order[index])
                end
                return dynamicOrder
            end
        end
        return nil
    end

    local function findStaticCacheEntry(captured)
        for _, entry in ipairs(staticCacheEntries) do
            if sameStaticLoreCapture(entry.sources, captured) then
                staticCacheClock = staticCacheClock + 1
                entry.lastUsed = staticCacheClock
                entry.hits = entry.hits + 1
                return entry
            end
        end
        return nil
    end

    local function storeStaticCacheEntry(captured, report)
        if #staticCacheEntries >= STATIC_CACHE_MAX_ENTRIES then
            local oldestIndex = 1
            for index = 2, #staticCacheEntries do
                if staticCacheEntries[index].lastUsed < staticCacheEntries[oldestIndex].lastUsed then
                    oldestIndex = index
                end
            end
            table.remove(staticCacheEntries, oldestIndex)
            staticCacheStats.evictions = staticCacheStats.evictions + 1
        end

        staticCacheClock = staticCacheClock + 1
        table.insert(staticCacheEntries, {
            sources = captured,
            report = report,
            lastUsed = staticCacheClock,
            hits = 0,
        })
    end

    local function clearStaticCache()
        local removed = #staticCacheEntries
        staticCacheEntries = {}
        staticCacheStats.clears = staticCacheStats.clears + 1
        return removed
    end

    local function getStaticCacheDiagnostics()
        local diagnostics = {
            maxEntries = STATIC_CACHE_MAX_ENTRIES,
            entries = #staticCacheEntries,
            requests = staticCacheStats.requests,
            captures = staticCacheStats.captures,
            fastHits = staticCacheStats.fastHits,
            hits = staticCacheStats.hits,
            misses = staticCacheStats.misses,
            validations = staticCacheStats.validations,
            failedValidations = staticCacheStats.failedValidations,
            evictions = staticCacheStats.evictions,
            clears = staticCacheStats.clears,
            cached = {},
        }
        for _, entry in ipairs(staticCacheEntries) do
            table.insert(diagnostics.cached, {
                hits = entry.hits,
                lastUsed = entry.lastUsed,
                counts = cloneStaticValue(entry.report.counts),
            })
        end
        return diagnostics
    end

    return function(triggerId, action)
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
        subwayLines = {
            kind = "subwayLineDatabase",
            collection = "subwayLines",
            lores = { "TokyoSubwayLines.db" },
        },
        characterList = {
            kind = "characterList",
            collection = "characters",
            lores = { "CharacterList.db" },
        },
    }
    local RESERVED_CHARACTER_DATABASES = {
        ["GameRegistry.db"] = true,
        ["PlayerCards.db"] = true,
        ["CharacterCards.db"] = true,
        ["CharTraits.db"] = true,
        ["TokyoSubwayLines.db"] = true,
        ["CharacterList.db"] = true,
    }

    local function addError(errors, code, path, message)
        table.insert(errors, {
            code = code,
            path = path,
            message = message,
        })
        emitDiagnostic(1, "validation_error", {
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

    local function isPositiveInteger(value)
        return isFiniteNonNegative(value)
            and value >= 1
            and value % 1 == 0
    end

    local function isFiniteInteger(value)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
            and value % 1 == 0
    end

    local function isPlanCapacity(value)
        return isPositiveInteger(value) and value <= MAX_PLAN_CAPACITY
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function isCharacterDatabaseName(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z][A-Za-z0-9_]*%.db$") ~= nil
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

    local function loadLoreModules(loreName, errors, captured)
        local source = captured[loreName]
        if source == nil or source.status == "read_error" then
            addError(
                errors,
                "lore_read_error",
                loreName,
                source and source.error or "정적 DB 로어북을 읽을 수 없습니다."
            )
            return {}
        end
        if source.status ~= "table" or #source.entries == 0 then
            addError(errors, "missing_lore", loreName, "정적 DB 로어북을 찾을 수 없습니다.")
            return {}
        end

        local modules = {}
        for index, lore in ipairs(source.entries) do
            if lore.valid ~= true then
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
                        emitDiagnostic(2, "module_loaded", {
                            lore = loreName,
                            entryIndex = index,
                            schemaVersion = tostring(result.schemaVersion),
                            kindType = type(result.kind),
                            kind = type(result.kind) == "string" and result.kind or tostring(result.kind),
                        })
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
            local actualKind = type(module.kind) == "string" and module.kind or tostring(module.kind)
            emitDiagnostic(1, "module_header_mismatch", {
                path = path .. ".kind",
                expectedKind = expectedKind,
                actualKindType = type(module.kind),
                actualKind = actualKind,
            })
            addError(
                errors,
                "unexpected_kind",
                path .. ".kind",
                "예상한 DB 종류와 다릅니다. (expected="
                    .. tostring(expectedKind)
                    .. ", actual="
                    .. actualKind
                    .. ")"
            )
        end
    end

    local function loadSingleModule(source, errors, captured)
        local loaded = nil

        for _, loreName in ipairs(source.lores) do
            local modules = loadLoreModules(loreName, errors, captured)
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

    local function loadMergedCollection(source, errors, captured)
        local merged = {}
        local origins = {}

        for _, loreName in ipairs(source.lores) do
            local modules = loadLoreModules(loreName, errors, captured)
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

    local function sortedAsciiKeys(collection)
        local keys = {}
        if type(collection) == "table" then
            for key in pairs(collection) do
                if isAsciiId(key) then
                    table.insert(keys, key)
                end
            end
        end
        table.sort(keys)
        return keys
    end

    local function collectCharacterDatabaseNames(characterList)
        local names = {}
        local seen = {}
        for _, characterId in ipairs(sortedAsciiKeys(characterList)) do
            local entry = characterList[characterId]
            local database = type(entry) == "table" and entry.database or nil
            if isCharacterDatabaseName(database)
                and RESERVED_CHARACTER_DATABASES[database] ~= true
                and seen[database] ~= true then
                seen[database] = true
                table.insert(names, database)
            end
        end
        return names
    end

    local function validateCharacterList(characterList, errors)
        if type(characterList) ~= "table" then
            addError(errors, "missing_character_list", "characterList", "캐릭터 목록이 없습니다.")
            return
        end
        if next(characterList) == nil then
            addError(errors, "empty_character_list", "characterList", "캐릭터 목록이 비어 있습니다.")
            return
        end

        local firstCharacterByDatabase = {}
        for key, entry in pairs(characterList) do
            local path = "characterList." .. tostring(key)
            if not isAsciiId(key) or type(entry) ~= "table" or entry.id ~= key then
                addError(errors, "invalid_character_list_id", path, "캐릭터 목록 키와 내부 ID가 올바르지 않습니다.")
            else
                for field in pairs(entry) do
                    if field ~= "id" and field ~= "database" then
                        addError(
                            errors,
                            "unexpected_character_list_field",
                            path .. "." .. tostring(field),
                            "캐릭터 목록에는 id와 database만 사용할 수 있습니다."
                        )
                    end
                end

                if not isCharacterDatabaseName(entry.database) then
                    addError(
                        errors,
                        "invalid_character_database_name",
                        path .. ".database",
                        "개별 캐릭터 DB 이름은 영문자로 시작하고 영문자, 숫자, 밑줄만 사용한 .db 파일명이어야 합니다."
                    )
                elseif RESERVED_CHARACTER_DATABASES[entry.database] == true then
                    addError(
                        errors,
                        "reserved_character_database_name",
                        path .. ".database",
                        "공용 정적 DB 이름은 개별 캐릭터 DB로 사용할 수 없습니다."
                    )
                else
                    local firstId = firstCharacterByDatabase[entry.database]
                    if firstId ~= nil then
                        addError(
                            errors,
                            "duplicate_character_database",
                            path .. ".database",
                            "개별 캐릭터 DB '" .. entry.database .. "'는 이미 characterList."
                                .. firstId .. ".database에서 사용되었습니다."
                        )
                    else
                        firstCharacterByDatabase[entry.database] = key
                    end
                end
            end
        end
    end

    local function loadCharacterDefinitions(characterList, errors, captured)
        local characters = {}
        for _, characterId in ipairs(sortedAsciiKeys(characterList)) do
            local entry = characterList[characterId]
            local database = type(entry) == "table" and entry.database or nil
            if isCharacterDatabaseName(database)
                and RESERVED_CHARACTER_DATABASES[database] ~= true then
                local modules = loadLoreModules(database, errors, captured)
                if #modules > 1 then
                    addError(
                        errors,
                        "duplicate_character_module",
                        database,
                        "개별 캐릭터 DB는 하나의 로어 엔트리만 등록할 수 있습니다."
                    )
                end

                for index, module in ipairs(modules) do
                    local modulePath = database .. "[" .. index .. "]"
                    validateModuleHeader(module, "characterDatabase", modulePath, errors)
                    local collection = module.characters
                    if type(collection) ~= "table" then
                        addError(errors, "missing_collection", modulePath .. ".characters", "캐릭터 DB 컬렉션이 없습니다.")
                    else
                        local definition = collection[characterId]
                        if definition == nil then
                            addError(
                                errors,
                                "missing_listed_character",
                                modulePath .. ".characters." .. characterId,
                                "캐릭터 목록에 등록된 ID의 정의가 개별 DB에 없습니다."
                            )
                        elseif characters[characterId] == nil then
                            characters[characterId] = definition
                        end

                        for definedId in pairs(collection) do
                            if definedId ~= characterId then
                                addError(
                                    errors,
                                    "unlisted_character_definition",
                                    modulePath .. ".characters." .. tostring(definedId),
                                    "개별 캐릭터 DB에는 목록에서 연결한 캐릭터 한 명만 정의할 수 있습니다."
                                )
                            end
                        end
                    end
                end
            end
        end
        return characters
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
                addError(errors, "invalid_owner", entryPath .. ".owner", "역할 소유자가 올바르지 않습니다.")
            end
        end
    end

    local function validateRegistry(registry, errors)
        if type(registry) ~= "table" then
            addError(errors, "missing_registry", "registry", "중앙 게임 레지스트리가 없습니다.")
            return
        end

        validateRegistryCollection(registry.cardTypes, "registry.cardTypes", errors, false)
        validateRegistryCollection(registry.roles, "registry.roles", errors, true)
        validateRegistryCollection(registry.mechanisms, "registry.mechanisms", errors, false)
        validateRegistryCollection(registry.ruleTerms, "registry.ruleTerms", errors, false)
        validateRegistryCollection(registry.moods, "registry.moods", errors, false)
        validateRegistryCollection(registry.events, "registry.events", errors, false)
        validateRegistryCollection(registry.effectOps, "registry.effectOps", errors, false)

        local registryIds = {}
        for _, collectionName in ipairs({ "cardTypes", "roles", "mechanisms", "ruleTerms" }) do
            local collection = type(registry[collectionName]) == "table" and registry[collectionName] or {}
            for id in pairs(collection) do
                if registryIds[id] then
                    addError(errors, "registry_id_collision", "registry." .. id, "태그와 규칙 용어 ID가 중복됩니다.")
                else
                    registryIds[id] = collectionName
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
            local knownCardType = type(registry) == "table"
                and type(registry.cardTypes) == "table"
                and registry.cardTypes[tagId]
            local knownRole = type(registry) == "table"
                and type(registry.roles) == "table"
                and registry.roles[tagId]
            local knownMechanism = type(registry) == "table"
                and type(registry.mechanisms) == "table"
                and registry.mechanisms[tagId]
            local knownRuleTerm = type(registry) == "table"
                and type(registry.ruleTerms) == "table"
                and registry.ruleTerms[tagId]

            if not knownCardType and not knownRole and not knownMechanism and not knownRuleTerm then
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

        local play = type(card.narration.play) == "table" and card.narration.play or nil
        local conditionMet = play and play.conditionMet or nil
        if card.narrationCondition ~= nil then
            if card.owner ~= "player" or isPlan then
                addError(errors, "invalid_narration_condition_owner", path .. ".narrationCondition", "조건부 사용 묘사는 플레이어의 비계획 카드에만 사용할 수 있습니다.")
            end
            if type(card.narrationCondition) ~= "function" then
                addError(errors, "invalid_narration_condition", path .. ".narrationCondition", "조건부 사용 묘사의 판정식이 함수가 아닙니다.")
            end
            if type(conditionMet) ~= "table"
                or type(conditionMet.actorAction) ~= "string"
                or conditionMet.actorAction == "" then
                addError(errors, "missing_condition_met_narration", path .. ".narration.play.conditionMet", "조건 충족 시 카드 사용 묘사가 없습니다.")
            end
        elseif conditionMet ~= nil then
            addError(errors, "missing_narration_condition", path .. ".narrationCondition", "조건 충족 묘사에 대응하는 판정식이 없습니다.")
        end
    end

    local function validatePlanSelectionAssumption(card, plan, path, registry, errors)
        local assumption = plan.selectionAssumption
        if card.owner == "character" and assumption == nil then
            addError(
                errors,
                "missing_plan_selection_assumption",
                path .. ".selectionAssumption",
                "캐릭터 계획에는 선택 점수용 발동 가정이 필요합니다."
            )
            return
        end
        if assumption == nil then
            return
        end
        if card.owner ~= "character" then
            addError(
                errors,
                "unexpected_plan_selection_assumption",
                path .. ".selectionAssumption",
                "선택 점수용 계획 발동 가정은 캐릭터 카드에만 사용할 수 있습니다."
            )
        end
        if type(assumption) ~= "table" then
            addError(
                errors,
                "invalid_plan_selection_assumption",
                path .. ".selectionAssumption",
                "계획 선택 가정이 테이블이 아닙니다."
            )
            return
        end

        for field in pairs(assumption) do
            if field ~= "event" and field ~= "chargePolicy" then
                addError(
                    errors,
                    "unexpected_plan_selection_assumption_field",
                    path .. ".selectionAssumption." .. tostring(field),
                    "계획 선택 가정에 허용되지 않은 필드가 있습니다."
                )
            end
        end

        local event = assumption.event
        local eventPath = path .. ".selectionAssumption.event"
        if type(event) ~= "table" then
            addError(errors, "invalid_plan_selection_event", eventPath, "계획 선택 가정 사건이 테이블이 아닙니다.")
        else
            for field in pairs(event) do
                if field ~= "type" and field ~= "side" and field ~= "roles" then
                    addError(
                        errors,
                        "unexpected_plan_selection_event_field",
                        eventPath .. "." .. tostring(field),
                        "계획 선택 가정 사건에는 type, side와 roles만 사용할 수 있습니다."
                    )
                end
            end
            if type(registry) ~= "table"
                or type(registry.events) ~= "table"
                or type(event.type) ~= "string"
                or not registry.events[event.type] then
                addError(errors, "unknown_plan_selection_event", eventPath .. ".type", "등록되지 않은 계획 선택 가정 사건입니다.")
            end
            if event.side ~= "player" and event.side ~= "character" then
                addError(errors, "invalid_plan_selection_side", eventPath .. ".side", "계획 선택 가정 진영이 올바르지 않습니다.")
            end
            if not isArray(event.roles) then
                addError(errors, "invalid_plan_selection_roles", eventPath .. ".roles", "계획 선택 가정 역할은 배열이어야 합니다.")
            else
                local seenRoles = {}
                for index, roleId in ipairs(event.roles) do
                    local role = type(registry) == "table"
                        and type(registry.roles) == "table"
                        and registry.roles[roleId]
                        or nil
                    if type(role) ~= "table" or role.owner ~= event.side or seenRoles[roleId] then
                        addError(errors, "invalid_plan_selection_role", eventPath .. ".roles[" .. index .. "]", "계획 선택 가정 역할이 진영과 맞지 않거나 중복되었습니다.")
                    end
                    seenRoles[roleId] = true
                end
            end
        end

        if assumption.chargePolicy ~= "all" then
            addError(
                errors,
                "invalid_plan_selection_charge_policy",
                path .. ".selectionAssumption.chargePolicy",
                "캐릭터 계획 선택 점수는 모든 충전을 합산해야 합니다."
            )
        end
        if not isPositiveInteger(plan.charges) then
            addError(
                errors,
                "plan_selection_requires_charges",
                path .. ".charges",
                "캐릭터 계획 선택 점수에는 양의 충전 수가 필요합니다."
            )
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
                if card.owner == "player"
                    and card.rarity ~= "common"
                    and card.rarity ~= "rare"
                    and card.rarity ~= "legendary" then
                    addError(errors, "invalid_rarity", path .. ".rarity", "플레이어 카드 희귀도는 common, rare 또는 legendary여야 합니다.")
                elseif card.owner == "character" and card.rarity ~= nil then
                    addError(errors, "unexpected_rarity", path .. ".rarity", "캐릭터 카드에는 희귀도를 사용하지 않습니다.")
                end
                if card.owner == "player"
                    and card.draftStyle ~= "predator"
                    and card.draftStyle ~= "glutton"
                    and card.draftStyle ~= "deceiver"
                    and card.draftStyle ~= "harmonizer" then
                    addError(errors, "invalid_draft_style", path .. ".draftStyle", "플레이어 카드에는 정확히 하나의 유효한 draftStyle이 필요합니다.")
                elseif card.owner == "character" and card.draftStyle ~= nil then
                    addError(errors, "unexpected_draft_style", path .. ".draftStyle", "캐릭터 카드에는 draftStyle을 사용하지 않습니다.")
                end
                if type(card.description) ~= "string" or card.description == "" then
                    addError(errors, "missing_description", path .. ".description", "카드 설명이 없습니다.")
                end
                validateTagTokens(card.description, path .. ".description", registry, errors)

                local cardType = type(registry) == "table"
                    and type(registry.cardTypes) == "table"
                    and registry.cardTypes[card.cardType]
                    or nil
                if not cardType then
                    addError(errors, "unknown_card_type", path .. ".cardType", "등록되지 않은 카드 유형입니다.")
                end

                if not isArray(card.roles) then
                    addError(errors, "invalid_roles", path .. ".roles", "카드 역할이 배열이 아닙니다.")
                else
                    local maximum = card.owner == "player" and 2 or 1
                    if #card.roles < 1 or #card.roles > maximum then
                        addError(errors, "invalid_role_count", path .. ".roles", "카드 역할 수가 소유자 규칙과 맞지 않습니다.")
                    end
                    local seenRoles = {}
                    for index, roleId in ipairs(card.roles) do
                        local rolePath = path .. ".roles[" .. index .. "]"
                        local role = type(registry) == "table"
                            and type(registry.roles) == "table"
                            and registry.roles[roleId]
                            or nil
                        if not role then
                            addError(errors, "unknown_role", rolePath, "등록되지 않은 카드 역할입니다.")
                        elseif role.owner ~= card.owner then
                            addError(errors, "role_owner_mismatch", rolePath, "카드 역할 소유자와 카드 소유자가 다릅니다.")
                        end
                        if seenRoles[roleId] then
                            addError(errors, "duplicate_role", rolePath, "같은 카드 역할이 중복되었습니다.")
                        end
                        seenRoles[roleId] = true
                    end
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
                            if mechanismId ~= "plan" or card.cardType ~= "plan" then
                                addError(errors, "orphan_mechanism_data", path .. ".mechanismData." .. tostring(mechanismId), "보유하지 않은 메커니즘의 설정입니다.")
                            end
                        end
                    end

                    local hasPlan = card.cardType == "plan"
                    local plan = type(card.mechanismData) == "table" and card.mechanismData.plan or nil
                    if hasPlan then
                        if type(plan) ~= "table" then
                            addError(errors, "missing_plan_data", path .. ".mechanismData.plan", "계획 설정이 없습니다.")
                        else
                            if plan.durationTurns ~= nil and not isPositiveInteger(plan.durationTurns) then
                                addError(errors, "invalid_plan_duration", path .. ".mechanismData.plan.durationTurns", "계획 지속 턴은 1 이상의 정수여야 합니다.")
                            end
                            if plan.durationIncludesPlacementTurn ~= nil
                                and type(plan.durationIncludesPlacementTurn) ~= "boolean" then
                                addError(
                                    errors,
                                    "invalid_plan_duration_policy",
                                    path .. ".mechanismData.plan.durationIncludesPlacementTurn",
                                    "배치 턴 포함 여부는 불리언이어야 합니다."
                                )
                            elseif plan.durationIncludesPlacementTurn == true
                                and not isPositiveInteger(plan.durationTurns) then
                                addError(
                                    errors,
                                    "plan_duration_policy_requires_duration",
                                    path .. ".mechanismData.plan.durationIncludesPlacementTurn",
                                    "배치 턴을 포함하려면 양의 durationTurns가 필요합니다."
                                )
                            end
                            if plan.charges ~= nil and not isPositiveInteger(plan.charges) then
                                addError(errors, "invalid_plan_charges", path .. ".mechanismData.plan.charges", "계획 충전은 1 이상의 정수여야 합니다.")
                            end
                            local hasLifetime = isPositiveInteger(plan.durationTurns)
                                or isPositiveInteger(plan.charges)
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
                            validatePlanSelectionAssumption(
                                card,
                                plan,
                                path .. ".mechanismData.plan",
                                registry,
                                errors
                            )
                        end
                    elseif plan ~= nil then
                        addError(errors, "unexpected_plan_data", path .. ".mechanismData.plan", "계획 메커니즘이 없는 카드에 계획 설정이 있습니다.")
                    end

                    local selectionPreview = card.selectionPreview
                    if selectionPreview ~= nil then
                        local previewPath = path .. ".selectionPreview"
                        if card.owner ~= "player" or card.cardType ~= "chain" then
                            addError(errors, "preview_requires_player_chain", previewPath, "선택 단계 효과는 플레이어 연계 카드에만 선언할 수 있습니다.")
                        end
                        if card.resolve ~= nil then
                            addError(errors, "preview_with_resolve", path .. ".resolve", "선택 단계 효과 카드에는 v1 resolve를 함께 둘 수 없습니다.")
                        end
                        if type(selectionPreview) ~= "table" then
                            addError(errors, "invalid_selection_preview", previewPath, "선택 단계 효과 정책이 테이블이 아닙니다.")
                        else
                            for field in pairs(selectionPreview) do
                                if field ~= "effects" and field ~= "when" then
                                    addError(errors, "unexpected_preview_field", previewPath .. "." .. tostring(field), "선택 단계 효과 정책에 허용되지 않은 필드가 있습니다.")
                                end
                            end

                            if selectionPreview.when ~= nil and type(selectionPreview.when) ~= "function" then
                                addError(errors, "invalid_preview_condition", previewPath .. ".when", "선택 단계 조건은 함수여야 합니다.")
                            end

                            if not isArray(selectionPreview.effects) or #selectionPreview.effects == 0 then
                                addError(errors, "invalid_preview_effects", previewPath .. ".effects", "선택 단계 효과는 비어 있지 않은 배열이어야 합니다.")
                            else
                                local seenEffectIds = {}
                                for effectIndex, effect in ipairs(selectionPreview.effects) do
                                    local effectPath = previewPath .. ".effects[" .. effectIndex .. "]"
                                    if type(effect) ~= "table" then
                                        addError(errors, "invalid_preview_effect", effectPath, "선택 단계 효과가 테이블이 아닙니다.")
                                    else
                                        for field in pairs(effect) do
                                            if field ~= "id" and field ~= "op" and field ~= "target" and field ~= "amount" then
                                                addError(errors, "unexpected_preview_effect_field", effectPath .. "." .. tostring(field), "선택 단계 효과에 허용되지 않은 필드가 있습니다.")
                                            end
                                        end
                                        if not isAsciiId(effect.id) then
                                            addError(errors, "invalid_preview_effect_id", effectPath .. ".id", "선택 단계 효과 ID는 ASCII ID여야 합니다.")
                                        elseif seenEffectIds[effect.id] then
                                            addError(errors, "duplicate_preview_effect_id", effectPath .. ".id", "선택 단계 효과 ID가 중복되었습니다.")
                                        else
                                            seenEffectIds[effect.id] = true
                                        end

                                        local registeredOp = type(registry) == "table"
                                            and type(registry.effectOps) == "table"
                                            and registry.effectOps[effect.op]
                                            or nil
                                        if not registeredOp then
                                            addError(errors, "unknown_preview_op", effectPath .. ".op", "등록되지 않은 선택 단계 효과 작업입니다.")
                                        elseif effect.op ~= "draw_cards" then
                                            addError(errors, "unsupported_preview_op", effectPath .. ".op", "선택 단계 효과 v1은 draw_cards만 지원합니다.")
                                        end
                                        if effect.target ~= "player" then
                                            addError(errors, "invalid_preview_target", effectPath .. ".target", "선택 단계 드로우 대상은 player여야 합니다.")
                                        end
                                        if not isPositiveInteger(effect.amount) then
                                            addError(errors, "invalid_preview_amount", effectPath .. ".amount", "선택 단계 드로우 수량은 1 이상의 정수여야 합니다.")
                                        end
                                    end
                                end
                            end
                        end
                    end

                    validateNarration(card, path, hasPlan, errors)
                    if hasPlan and type(card.effectChoices) == "table" then
                        local hasImmediateChoice = false
                        for _, choice in ipairs(card.effectChoices) do
                            if type(choice) == "table" and choice.placesPlan == false then
                                hasImmediateChoice = true
                            end
                        end
                        if hasImmediateChoice
                            and (type(card.narration) ~= "table"
                                or type(card.narration.play) ~= "table"
                                or type(card.narration.play.actorAction) ~= "string"
                                or card.narration.play.actorAction == "") then
                            addError(errors, "missing_immediate_choice_narration", path .. ".narration.play", "즉시 발동 선택지가 있는 계획 카드에는 사용 묘사가 필요합니다.")
                        end
                    end
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
                if card.stealthCostByMood ~= nil then
                    if card.owner ~= "player" or type(card.stealthCostByMood) ~= "table" then
                        addError(errors, "invalid_mood_stealth_costs", path .. ".stealthCostByMood", "플레이어 카드의 무드별 은폐 비용은 테이블이어야 합니다.")
                    else
                        for moodId, cost in pairs(card.stealthCostByMood) do
                            if type(registry) ~= "table"
                                or type(registry.moods) ~= "table"
                                or registry.moods[moodId] == nil then
                                addError(errors, "unknown_mood_stealth_cost", path .. ".stealthCostByMood." .. tostring(moodId), "등록되지 않은 무드의 은폐 비용입니다.")
                            elseif not isFiniteNonNegative(cost) then
                                addError(errors, "invalid_mood_stealth_cost", path .. ".stealthCostByMood." .. moodId, "무드별 은폐 비용이 0 이상의 유한한 숫자가 아닙니다.")
                            end
                        end
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
                if card.effectChoices ~= nil then
                    local choicesPath = path .. ".effectChoices"
                    if card.owner ~= "player" then
                        addError(errors, "choice_requires_player", choicesPath, "효과 선택지는 플레이어 카드에만 선언할 수 있습니다.")
                    end
                    if not isArray(card.effectChoices) or #card.effectChoices < 2 then
                        addError(errors, "invalid_effect_choices", choicesPath, "효과 선택지는 2개 이상의 배열이어야 합니다.")
                    else
                        local seenChoiceIds = {}
                        for choiceIndex, choice in ipairs(card.effectChoices) do
                            local choicePath = choicesPath .. "[" .. choiceIndex .. "]"
                            if type(choice) ~= "table" then
                                addError(errors, "invalid_effect_choice", choicePath, "효과 선택지가 테이블이 아닙니다.")
                            else
                                for field in pairs(choice) do
                                    if field ~= "id"
                                        and field ~= "label"
                                        and field ~= "description"
                                        and field ~= "actorAction"
                                        and field ~= "unavailableText"
                                        and field ~= "canSelect"
                                        and field ~= "placesPlan" then
                                        addError(errors, "unexpected_effect_choice_field", choicePath .. "." .. tostring(field), "효과 선택지에 허용되지 않은 필드가 있습니다.")
                                    end
                                end
                                if not isAsciiId(choice.id) then
                                    addError(errors, "invalid_effect_choice_id", choicePath .. ".id", "효과 선택지 ID는 ASCII ID여야 합니다.")
                                elseif seenChoiceIds[choice.id] then
                                    addError(errors, "duplicate_effect_choice_id", choicePath .. ".id", "효과 선택지 ID가 중복되었습니다.")
                                else
                                    seenChoiceIds[choice.id] = true
                                end
                                if type(choice.label) ~= "string" or choice.label == "" then
                                    addError(errors, "invalid_effect_choice_label", choicePath .. ".label", "효과 선택지 표시명이 필요합니다.")
                                end
                                if type(choice.description) ~= "string" or choice.description == "" then
                                    addError(errors, "invalid_effect_choice_description", choicePath .. ".description", "효과 선택지 설명이 필요합니다.")
                                else
                                    validateTagTokens(choice.description, choicePath .. ".description", registry, errors)
                                end
                                if choice.actorAction ~= nil
                                    and (type(choice.actorAction) ~= "string" or choice.actorAction == "") then
                                    addError(errors, "invalid_effect_choice_actor_action", choicePath .. ".actorAction", "선택지 행동 묘사는 비어 있지 않은 문자열이어야 합니다.")
                                end
                                if choice.unavailableText ~= nil
                                    and (type(choice.unavailableText) ~= "string" or choice.unavailableText == "") then
                                    addError(errors, "invalid_effect_choice_unavailable_text", choicePath .. ".unavailableText", "비활성 안내는 비어 있지 않은 문자열이어야 합니다.")
                                end
                                if choice.canSelect ~= nil and type(choice.canSelect) ~= "function" then
                                    addError(errors, "invalid_effect_choice_predicate", choicePath .. ".canSelect", "효과 선택 가능 조건이 함수가 아닙니다.")
                                end
                                if choice.placesPlan ~= nil then
                                    if type(choice.placesPlan) ~= "boolean" then
                                        addError(errors, "invalid_effect_choice_plan_flag", choicePath .. ".placesPlan", "계획 배치 여부는 불리언이어야 합니다.")
                                    elseif card.cardType ~= "plan" then
                                        addError(errors, "effect_choice_plan_without_type", choicePath .. ".placesPlan", "계획 카드가 아닌 카드에는 계획 배치 선택을 선언할 수 없습니다.")
                                    end
                                end
                            end
                        end
                    end
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
                if trait.modifiers ~= nil then
                    local modifiersPath = path .. ".modifiers"
                    if not isArray(trait.modifiers) then
                        addError(errors, "invalid_trait_modifiers", modifiersPath, "특징 보정은 연속 배열이어야 합니다.")
                    else
                        for index, modifier in ipairs(trait.modifiers) do
                            local modifierPath = modifiersPath .. "[" .. index .. "]"
                            if type(modifier) ~= "table" then
                                addError(
                                    errors,
                                    "invalid_trait_modifier",
                                    modifierPath,
                                    "특징 보정 항목은 객체여야 합니다."
                                )
                            else
                                local allowed = {
                                    stat = true,
                                    operation = true,
                                    amount = true,
                                }
                                for field in pairs(modifier) do
                                    if not allowed[field] then
                                        addError(
                                            errors,
                                            "unknown_trait_modifier_field",
                                            modifierPath .. "." .. tostring(field),
                                            "특징 보정에 허용되지 않은 필드가 있습니다."
                                        )
                                    end
                                end
                                if modifier.stat ~= "planCapacity" then
                                    addError(
                                        errors,
                                        "unsupported_trait_modifier_stat",
                                        modifierPath .. ".stat",
                                        "현재 특징 보정은 planCapacity만 지원합니다."
                                    )
                                end
                                if modifier.operation ~= "add" then
                                    addError(
                                        errors,
                                        "unsupported_trait_modifier_operation",
                                        modifierPath .. ".operation",
                                        "planCapacity 특징 보정은 add 연산만 지원합니다."
                                    )
                                end
                                if not isFiniteInteger(modifier.amount) then
                                    addError(
                                        errors,
                                        "invalid_trait_modifier_amount",
                                        modifierPath .. ".amount",
                                        "planCapacity 특징 보정량은 유한한 정수여야 합니다."
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local function validateSubwayLines(subwayLines, errors)
        if type(subwayLines) ~= "table" then
            addError(errors, "missing_subway_lines", "subwayLines", "지하철 노선 컬렉션이 없습니다.")
            return
        end
        if next(subwayLines) == nil then
            addError(errors, "empty_subway_lines", "subwayLines", "지하철 노선 컬렉션이 비어 있습니다.")
            return
        end

        for key, line in pairs(subwayLines) do
            local linePath = "subwayLines." .. tostring(key)
            if not isAsciiId(key) or type(line) ~= "table" or line.id ~= key then
                addError(errors, "invalid_subway_line_id", linePath, "노선 키와 내부 ID가 올바르지 않습니다.")
            else
                if not isAsciiId(line.operatorId) then
                    addError(errors, "invalid_subway_operator_id", linePath .. ".operatorId", "운영사 ID가 올바르지 않습니다.")
                end
                if type(line.operatorName) ~= "string" or line.operatorName == "" then
                    addError(errors, "missing_subway_operator_name", linePath .. ".operatorName", "운영사 표시명이 없습니다.")
                end
                if type(line.name) ~= "string" or line.name == "" then
                    addError(errors, "missing_subway_line_name", linePath .. ".name", "노선 표시명이 없습니다.")
                end
                if type(line.code) ~= "string"
                    or string.match(line.code, "^[A-Z]$") == nil then
                    addError(errors, "invalid_subway_line_code", linePath .. ".code", "노선 코드는 영문 대문자 한 글자여야 합니다.")
                end
                if type(line.color) ~= "string"
                    or string.match(line.color, "^#%x%x%x%x%x%x$") == nil then
                    addError(errors, "invalid_subway_line_color", linePath .. ".color", "노선 색상은 #RRGGBB 형식이어야 합니다.")
                end

                if not isArray(line.paths) or #line.paths == 0 then
                    addError(errors, "invalid_subway_paths", linePath .. ".paths", "노선 경로 목록이 비어 있습니다.")
                else
                    local pathIds = {}
                    local stationDefinitions = {}
                    local supportsMinimum = false
                    local supportsMaximum = false
                    for pathIndex, routePath in ipairs(line.paths) do
                        local pathPath = linePath .. ".paths[" .. pathIndex .. "]"
                        if type(routePath) ~= "table" then
                            addError(errors, "invalid_subway_path", pathPath, "노선 경로가 테이블이 아닙니다.")
                        else
                            if not isAsciiId(routePath.id) then
                                addError(errors, "invalid_subway_path_id", pathPath .. ".id", "노선 경로 ID가 올바르지 않습니다.")
                            elseif pathIds[routePath.id] then
                                addError(errors, "duplicate_subway_path_id", pathPath .. ".id", "노선 경로 ID가 중복되었습니다.")
                            else
                                pathIds[routePath.id] = true
                            end
                            if type(routePath.circular) ~= "boolean" then
                                addError(errors, "invalid_subway_path_circular", pathPath .. ".circular", "순환 경로 여부는 불리언이어야 합니다.")
                            end
                            if not isArray(routePath.stations) or #routePath.stations < 2 then
                                addError(errors, "invalid_subway_stations", pathPath .. ".stations", "경로에는 두 개 이상의 역이 필요합니다.")
                            else
                                if routePath.circular == true or #routePath.stations >= 8 then
                                    supportsMinimum = true
                                end
                                if routePath.circular == true or #routePath.stations >= 13 then
                                    supportsMaximum = true
                                end
                                local stationIds = {}
                                for stationIndex, station in ipairs(routePath.stations) do
                                    local stationPath = pathPath .. ".stations[" .. stationIndex .. "]"
                                    if type(station) ~= "table" then
                                        addError(errors, "invalid_subway_station", stationPath, "역 정의가 테이블이 아닙니다.")
                                    else
                                        if not isAsciiId(station.id) then
                                            addError(errors, "invalid_subway_station_id", stationPath .. ".id", "역 ID가 올바르지 않습니다.")
                                        elseif stationIds[station.id] then
                                            addError(errors, "duplicate_subway_station_id", stationPath .. ".id", "한 경로 안에서 역 ID가 중복되었습니다.")
                                        else
                                            stationIds[station.id] = true
                                        end
                                        if type(station.code) ~= "string"
                                            or string.match(station.code, "^[A-Za-z]+[0-9][0-9]$") == nil then
                                            addError(errors, "invalid_subway_station_code", stationPath .. ".code", "역 코드는 영문자와 두 자리 숫자로 구성해야 합니다.")
                                        end
                                        if type(station.name) ~= "string" or station.name == "" then
                                            addError(errors, "missing_subway_station_name", stationPath .. ".name", "역 표시명이 없습니다.")
                                        end

                                        local previous = stationDefinitions[station.id]
                                        if previous ~= nil
                                            and (previous.code ~= station.code or previous.name ~= station.name) then
                                            addError(errors, "subway_station_definition_conflict", stationPath, "같은 역 ID의 코드나 표시명이 경로마다 다릅니다.")
                                        elseif previous == nil and isAsciiId(station.id) then
                                            stationDefinitions[station.id] = {
                                                code = station.code,
                                                name = station.name,
                                            }
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if not supportsMinimum then
                        addError(errors, "subway_line_too_short", linePath .. ".paths", "이 노선에는 7턴 여정을 만들 수 있는 경로가 없습니다.")
                    end
                    if not supportsMaximum then
                        addError(errors, "subway_line_missing_maximum_route", linePath .. ".paths", "이 노선에는 12턴 여정을 만들 수 있는 경로가 없습니다.")
                    end
                end
            end
        end
    end

    local function validateCharacters(characters, cards, traits, registry, errors)
        if type(characters) ~= "table" then
            addError(errors, "missing_characters", "characters", "캐릭터 컬렉션이 없습니다.")
            return
        end

        local namedCharacters = {}

        for key, character in pairs(characters) do
            local path = "characters." .. tostring(key)
            if not isAsciiId(key) or type(character) ~= "table" or character.id ~= key then
                addError(errors, "invalid_character_id", path, "캐릭터 키와 내부 ID가 올바르지 않습니다.")
            else
                if type(character.name) ~= "string" or character.name == "" then
                    addError(errors, "missing_name", path .. ".name", "캐릭터 이름이 없습니다.")
                else
                    table.insert(namedCharacters, {
                        id = key,
                        name = character.name,
                    })
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
                    if not isPositiveInteger(battle.turnLimit) or battle.turnLimit < 7 or battle.turnLimit > 12 then
                        addError(errors, "invalid_turn_limit", path .. ".battle.turnLimit", "캐릭터 제한 턴은 7 이상 12 이하의 정수여야 합니다.")
                    end
                    if not isPositiveInteger(battle.baseDrawCount) then
                        addError(errors, "invalid_base_draw_count", path .. ".battle.baseDrawCount", "기본 드로우 수는 1 이상의 정수여야 합니다.")
                    end
                    if not isPositiveInteger(battle.maxHandSize) then
                        addError(errors, "invalid_hand_size", path .. ".battle.maxHandSize", "최대 손패는 1 이상의 정수여야 합니다.")
                    end
                    if not isPlanCapacity(battle.planCapacity) then
                        addError(errors, "invalid_plan_capacity", path .. ".battle.planCapacity", "기본 계획 용량은 1 이상 16 이하의 정수여야 합니다.")
                    end
                    if isPositiveInteger(battle.baseDrawCount)
                        and isPositiveInteger(battle.maxHandSize)
                        and battle.baseDrawCount > battle.maxHandSize then
                        addError(errors, "draw_exceeds_hand_limit", path .. ".battle.baseDrawCount", "기본 드로우 수는 최대 손패보다 클 수 없습니다.")
                    end
                    if type(registry) ~= "table"
                        or type(registry.moods) ~= "table"
                        or not registry.moods[battle.startingMood] then
                        addError(errors, "unknown_starting_mood", path .. ".battle.startingMood", "등록되지 않은 시작 무드입니다.")
                    end

                    if not isArray(battle.traitIds) then
                        addError(errors, "invalid_trait_ids", path .. ".battle.traitIds", "특징 ID 목록이 배열이 아닙니다.")
                    else
                        local effectivePlanCapacity = battle.planCapacity
                        for index, traitId in ipairs(battle.traitIds) do
                            local trait = traits[traitId]
                            if not trait or trait.owner ~= "character" then
                                addError(errors, "unknown_character_trait", path .. ".battle.traitIds[" .. index .. "]", "캐릭터 특징을 찾을 수 없습니다.")
                            elseif isFiniteInteger(effectivePlanCapacity) and isArray(trait.modifiers) then
                                for _, modifier in ipairs(trait.modifiers) do
                                    if type(modifier) == "table"
                                        and modifier.stat == "planCapacity"
                                        and modifier.operation == "add"
                                        and isFiniteInteger(modifier.amount) then
                                        effectivePlanCapacity = effectivePlanCapacity + modifier.amount
                                    end
                                end
                            end
                        end
                        if isPlanCapacity(battle.planCapacity)
                            and not isPlanCapacity(effectivePlanCapacity) then
                            addError(
                                errors,
                                "invalid_effective_plan_capacity",
                                path .. ".battle.planCapacity",
                                "기본 계획 용량과 특징 보정의 합은 1 이상 16 이하여야 합니다."
                            )
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

                end
            end
        end

        -- pairs 순서에 따라 중복 오류의 위치가 달라지지 않도록 내부 ID 순으로
        -- 검사한다. 같은 표시 이름은 선택 화면에서 구분할 수 없으므로 정적 데이터
        -- 로딩 자체를 실패시킨다.
        table.sort(namedCharacters, function(left, right)
            return left.id < right.id
        end)
        local firstCharacterByName = {}
        for _, entry in ipairs(namedCharacters) do
            local firstId = firstCharacterByName[entry.name]
            if firstId ~= nil then
                addError(
                    errors,
                    "duplicate_character_name",
                    "characters." .. entry.id .. ".name",
                    "캐릭터 이름 '" .. entry.name .. "'은 이미 characters."
                        .. firstId .. ".name에서 사용되었습니다. 캐릭터 이름은 중복될 수 없습니다."
                )
            else
                firstCharacterByName[entry.name] = entry.id
            end
        end
    end

    local function validateCapturedStaticData(captured, discoveredCharacterList, discoveryErrors)
        local errors = {}
        for _, item in ipairs(discoveryErrors or {}) do
            table.insert(errors, item)
        end
        local registry = loadSingleModule(SOURCES.registry, errors, captured)
        local cards = loadMergedCollection(SOURCES.cards, errors, captured)
        local traits = loadMergedCollection(SOURCES.traits, errors, captured)
        local subwayLines = loadMergedCollection(SOURCES.subwayLines, errors, captured)
        local characterList = discoveredCharacterList
        if characterList == nil then
            characterList = loadMergedCollection(SOURCES.characterList, errors, captured)
        end
        validateCharacterList(characterList, errors)
        local characters = loadCharacterDefinitions(characterList, errors, captured)

        validateRegistry(registry, errors)
        validateCards(cards, registry, errors)
        validateTraits(traits, errors)
        validateSubwayLines(subwayLines, errors)
        validateCharacters(characters, cards, traits, registry, errors)

        return {
            ok = #errors == 0,
            schemaVersion = SUPPORTED_SCHEMA_VERSION,
            errors = errors,
            counts = {
                cards = countEntries(cards),
                traits = countEntries(traits),
                subwayLines = countEntries(subwayLines),
                characters = countEntries(characters),
            },
            data = #errors == 0 and {
                registry = registry,
                cards = cards,
                traits = traits,
                subwayLines = subwayLines,
                characters = characters,
            } or nil,
        }
    end

    local function loadAndValidateAll(forceRefresh)
        staticCacheStats.requests = staticCacheStats.requests + 1
        emitDiagnostic(2, "validation_requested", {
            forceRefresh = forceRefresh == true,
            cachedEntries = #staticCacheEntries,
        })

        -- main production warm cache는 bundle revision + mode + chat + character별로
        -- handler closure를 분리한다. 따라서 같은 handler의 성공 snapshot은 source를
        -- 다시 읽지 않고 안전하게 재사용할 수 있다. main 없이 직접 실행되는 로컬
        -- 계약 검사는 global이 nil이므로 기존처럼 매번 source identity를 확인한다.
        if forceRefresh ~= true
            and RUNTIME_CACHE_DEVELOPMENT_BYPASS == false
            and #staticCacheEntries > 0 then
            local newest = staticCacheEntries[1]
            for index = 2, #staticCacheEntries do
                if staticCacheEntries[index].lastUsed > newest.lastUsed then
                    newest = staticCacheEntries[index]
                end
            end
            staticCacheClock = staticCacheClock + 1
            newest.lastUsed = staticCacheClock
            newest.hits = newest.hits + 1
            staticCacheStats.fastHits = staticCacheStats.fastHits + 1
            staticCacheStats.hits = staticCacheStats.hits + 1
            emitDiagnostic(2, "validation_cache_hit", {
                cache = "production_fast",
                ok = newest.report.ok == true,
            })
            return cloneStaticValue(newest.report)
        end

        local captured = captureBaseStaticLores(triggerId)
        local discoveredCharacterList = nil
        local discoveryErrors = nil
        local dynamicLoreOrder = findCachedDynamicLoreOrder(captured)
        if dynamicLoreOrder == nil then
            discoveryErrors = {}
            discoveredCharacterList = loadMergedCollection(SOURCES.characterList, discoveryErrors, captured)
            dynamicLoreOrder = collectCharacterDatabaseNames(discoveredCharacterList)
        end
        for _, database in ipairs(dynamicLoreOrder) do
            captureStaticLore(triggerId, captured, database)
        end
        local cached = findStaticCacheEntry(captured)
        if cached ~= nil then
            staticCacheStats.hits = staticCacheStats.hits + 1
            emitDiagnostic(2, "validation_cache_hit", {
                cache = "source_identity",
                ok = cached.report.ok == true,
            })
            return cloneStaticValue(cached.report)
        end

        staticCacheStats.misses = staticCacheStats.misses + 1
        staticCacheStats.validations = staticCacheStats.validations + 1
        local report = validateCapturedStaticData(captured, discoveredCharacterList, discoveryErrors)
        emitDiagnostic(report.ok == true and 2 or 1, "validation_completed", {
            ok = report.ok == true,
            errorCount = #report.errors,
            cards = report.counts.cards,
            traits = report.counts.traits,
            subwayLines = report.counts.subwayLines,
            characters = report.counts.characters,
        })
        if report.ok == true then
            -- canonical report는 cache 내부에만 남기고 호출자에게는 별도 snapshot을 준다.
            storeStaticCacheEntry(captured, report)
            return cloneStaticValue(report)
        end

        -- 실패한 compile/validation 결과는 수정 후 즉시 다시 검사할 수 있도록 캐시하지 않는다.
        staticCacheStats.failedValidations = staticCacheStats.failedValidations + 1
        return report
    end

    local actions = {
        loadAll = loadAndValidateAll,
        validateAll = function()
            local result = loadAndValidateAll()
            result.data = nil
            return result
        end,
        reloadAll = function()
            return loadAndValidateAll(true)
        end,
        cacheStats = function()
            return {
                ok = true,
                schemaVersion = SUPPORTED_SCHEMA_VERSION,
                errors = {},
                cache = getStaticCacheDiagnostics(),
            }
        end,
        clearCache = function()
            return {
                ok = true,
                schemaVersion = SUPPORTED_SCHEMA_VERSION,
                errors = {},
                removed = clearStaticCache(),
            }
        end,
    }

    emitDiagnostic(2, "request", {
        action = tostring(action),
    })

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
    end
end)()
