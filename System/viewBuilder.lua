(function()
    local PRESENTATION_CACHE_MAX_ENTRIES = 256
    local presentationCache = {}
    local presentationCacheSize = 0
    local presentationClock = 0
    local presentationStats = { hits = 0, misses = 0, evictions = 0 }

    local function resolveRegistry(registry)
        if type(registry) == "table" and type(registry.registry) == "table" then
            return registry.registry
        end
        if type(registry) == "table" and type(registry.data) == "table" then
            return resolveRegistry(registry.data)
        end
        return registry
    end

    local function clonePresentation(value, seen)
        if type(value) ~= "table" then return value end
        seen = seen or {}
        if seen[value] ~= nil then return seen[value] end
        local copy = {}
        seen[value] = copy
        for key, item in pairs(value) do
            copy[clonePresentation(key, seen)] = clonePresentation(item, seen)
        end
        return copy
    end

    local function presentationKey(card, registry)
        local parts = {}
        local function append(value)
            local text = tostring(value or "")
            parts[#parts + 1] = tostring(#text) .. ":" .. text
        end
        append("presentation-v2")
        append("card.id")
        append(type(card) == "table" and card.id)
        append("card.name")
        append(type(card) == "table" and card.name)
        append("card.description")
        append(type(card) == "table" and card.description)
        append("card.actionTag")
        append(type(card) == "table" and card.actionTag)
        local mechanisms = type(card) == "table" and type(card.mechanisms) == "table" and card.mechanisms or {}
        append("card.mechanisms")
        append(#mechanisms)
        for _, value in ipairs(mechanisms) do append(value) end
        local rules = type(card) == "table" and type(card.rules) == "table" and card.rules or {}
        append("card.rules")
        append(#rules)
        for _, value in ipairs(rules) do append(value) end

        registry = resolveRegistry(registry)
        for _, collectionName in ipairs({ "actionTags", "mechanisms" }) do
            append("registry." .. collectionName)
            local collection = type(registry) == "table" and registry[collectionName] or nil
            local keys = {}
            for key in pairs(type(collection) == "table" and collection or {}) do keys[#keys + 1] = key end
            table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
            append(#keys)
            for _, key in ipairs(keys) do
                local entry = collection[key]
                append(key)
                append(type(entry) == "table" and entry.id)
                append(type(entry) == "table" and entry.label)
                append(type(entry) == "table" and entry.tooltip)
            end
        end
        return table.concat(parts, "|")
    end

    local function evictPresentationIfNeeded()
        if presentationCacheSize < PRESENTATION_CACHE_MAX_ENTRIES then return end
        local oldestKey
        local oldest
        for key, entry in pairs(presentationCache) do
            if oldest == nil or entry.lastUsed < oldest.lastUsed then
                oldestKey, oldest = key, entry
            end
        end
        if oldestKey ~= nil then
            presentationCache[oldestKey] = nil
            presentationCacheSize = presentationCacheSize - 1
            presentationStats.evictions = presentationStats.evictions + 1
        end
    end

    return function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_PLAN_CAPACITY = 16

    local function addError(errors, code, path, message)
        table.insert(errors, {
            code = code,
            path = path,
            message = message,
        })
    end

    local function failure(errors)
        return {
            ok = false,
            schemaVersion = SCHEMA_VERSION,
            errors = errors,
        }
    end

    local function success(key, value)
        local response = {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
        }
        if key then
            response[key] = value
        end
        return response
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

    local function isPlanCapacity(value)
        return isInteger(value, 1) and value <= MAX_PLAN_CAPACITY
    end

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
    end

    local function objectPath(path, key)
        if type(key) == "string" and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", tostring(key)) .. "]"
    end

    local function inspectTable(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "expected_table", path, "테이블이어야 합니다.")
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
                if key > maximum then
                    maximum = key
                end
            elseif type(key) == "string" then
                hasString = true
                table.insert(stringKeys, key)
            else
                addError(errors, "invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
                return nil
            end
        end

        if hasNumeric and hasString then
            addError(errors, "mixed_table", path, "숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
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

    local function validateJsonSafe(value, path, errors, active)
        local valueType = type(value)
        if valueType == "string" or valueType == "boolean" then
            return
        end
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
            addError(errors, "circular_reference", path, "순환 참조가 있는 View는 허용하지 않습니다.")
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
        if type(value) ~= "table" then
            return
        end
        for key in pairs(value) do
            if type(key) ~= "string" or not allowed[key] then
                addError(errors, "unknown_field", objectPath(path, key), "battleView에 허용되지 않은 필드입니다.")
            end
        end
    end

    local function getArrayLength(value, path, errors)
        local kind, length = inspectTable(value, path, errors)
        if kind ~= "array" then
            if kind ~= nil then
                addError(errors, "expected_array", path, "연속 배열이어야 합니다.")
            end
            return nil
        end
        return length
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function hasMechanism(card, mechanismId)
        if type(card) ~= "table" or type(card.mechanisms) ~= "table" then
            return false
        end
        for _, id in ipairs(card.mechanisms) do
            if id == mechanismId then
                return true
            end
        end
        return false
    end

    local function appendNestedErrors(target, prefix, nested)
        if type(nested) ~= "table" or type(nested.errors) ~= "table" then
            addError(target, "validation_failed", prefix, "하위 검증 결과를 읽을 수 없습니다.")
            return
        end
        for _, item in ipairs(nested.errors) do
            local suffix = tostring(item.path or "$")
            if string.sub(suffix, 1, 1) == "$" then
                suffix = string.sub(suffix, 2)
            end
            addError(
                target,
                tostring(item.code or "validation_failed"),
                prefix .. suffix,
                tostring(item.message or "하위 검증에 실패했습니다.")
            )
        end
    end

    local function lookupTag(registry, tagId, path, errors)
        registry = resolveRegistry(registry)
        local action = type(registry) == "table"
            and type(registry.actionTags) == "table"
            and registry.actionTags[tagId]
            or nil
        local mechanism = type(registry) == "table"
            and type(registry.mechanisms) == "table"
            and registry.mechanisms[tagId]
            or nil

        if action and mechanism then
            addError(errors, "tag_registry_collision", path, "행동 태그와 메커니즘 ID가 충돌합니다: " .. tagId)
            return nil
        end
        local entry = action or mechanism
        if not entry then
            addError(errors, "unknown_tag_token", path, "등록되지 않은 태그입니다: " .. tagId)
            return nil
        end
        if type(entry.label) ~= "string" or entry.label == ""
            or type(entry.tooltip) ~= "string" or entry.tooltip == "" then
            addError(errors, "invalid_tag_metadata", path, "태그 표시명과 툴팁이 필요합니다: " .. tagId)
            return nil
        end

        return {
            kind = "tag",
            id = tagId,
            label = entry.label,
            tagKind = action and "action" or "mechanism",
            tooltip = entry.tooltip,
        }
    end

    local function buildTagGlossary(publicAction, handItems)
        local byId = {}
        local function appendTag(tag)
            if type(tag) ~= "table" or tag.kind ~= "tag" or type(tag.id) ~= "string" then
                return
            end
            byId[tag.id] = {
                kind = "tag",
                id = tag.id,
                label = tag.label,
                tagKind = tag.tagKind,
                tooltip = tag.tooltip,
            }
        end
        local function appendSegments(segments)
            for _, segment in ipairs(type(segments) == "table" and segments or {}) do
                if type(segment) == "table" and segment.kind == "tag" then
                    appendTag(segment)
                end
            end
        end
        local function appendRuleLines(ruleLines)
            for _, ruleLine in ipairs(type(ruleLines) == "table" and ruleLines or {}) do
                appendSegments(type(ruleLine) == "table" and ruleLine.segments or nil)
            end
        end

        if type(publicAction) == "table" and publicAction.status == "tagRevealed" then
            appendTag(publicAction.tag)
        end
        for _, item in ipairs(type(handItems) == "table" and handItems or {}) do
            appendTag(item.actionTag)
            for _, mechanism in ipairs(type(item.mechanisms) == "table" and item.mechanisms or {}) do
                appendTag(mechanism)
            end
            appendSegments(item.descriptionSegments)
            appendRuleLines(item.ruleLines)
        end

        local glossary = {}
        local ids = {}
        for id in pairs(byId) do
            ids[#ids + 1] = id
        end
        table.sort(ids, function(left, right)
            return tostring(left) < tostring(right)
        end)
        for _, id in ipairs(ids) do
            glossary[#glossary + 1] = byId[id]
        end
        return glossary
    end

    local function appendText(segments, value)
        if value == "" then
            return
        end
        local previous = segments[#segments]
        if previous and previous.kind == "text" then
            previous.value = previous.value .. value
        else
            table.insert(segments, {
                kind = "text",
                value = value,
            })
        end
    end

    local function tokenizeTags(source, registry, sourcePath)
        local errors = {}
        sourcePath = sourcePath or "$"
        if type(source) ~= "string" then
            addError(errors, "invalid_text", sourcePath, "태그를 해석할 값이 문자열이 아닙니다.")
            return failure(errors)
        end

        local segments = {}
        local cursor = 1
        while cursor <= #source do
            local tokenStart = string.find(source, "::tag[", cursor, true)
            if not tokenStart then
                appendText(segments, string.sub(source, cursor))
                break
            end

            appendText(segments, string.sub(source, cursor, tokenStart - 1))
            local idStart = tokenStart + #"::tag["
            local tokenCloseStart, tokenCloseEnd = string.find(source, "]::", idStart, true)
            if not tokenCloseStart then
                addError(errors, "malformed_tag_token", sourcePath, "닫히지 않은 태그 토큰이 있습니다.")
                return failure(errors)
            end

            local tagId = string.sub(source, idStart, tokenCloseStart - 1)
            if not isAsciiId(tagId) then
                addError(errors, "malformed_tag_token", sourcePath, "태그 ID는 소문자 ASCII ID여야 합니다: " .. tagId)
                return failure(errors)
            end

            local tag = lookupTag(registry, tagId, sourcePath, errors)
            if not tag then
                return failure(errors)
            end
            table.insert(segments, tag)
            cursor = tokenCloseEnd + 1
        end

        if #source == 0 then
            return success("segments", {})
        end
        return success("segments", segments)
    end

    local function tokenizeForBuild(source, registry, path, errors)
        local tokenized = tokenizeTags(source, registry, "$")
        if not tokenized.ok then
            appendNestedErrors(errors, path, tokenized)
            return {}
        end
        return tokenized.segments
    end

    local function buildRuleLines(rules, registry, path, errors)
        local lines = {}
        if type(rules) ~= "table" then
            addError(errors, "invalid_rules", path, "규칙 목록이 배열이 아닙니다.")
            return lines
        end
        for index, rule in ipairs(rules) do
            table.insert(lines, {
                segments = tokenizeForBuild(rule, registry, path .. "[" .. index .. "]", errors),
            })
        end
        return lines
    end

    local SOURCE_KIND_LABELS = {
        card = "카드",
        plan = "계획",
        trait = "특징",
        perk = "퍽",
        environment = "환경",
    }

    local function collectRelatedTags(explicitTags, descriptionSegments, ruleLines)
        local tags = {}
        local seen = {}
        local function append(tag)
            if type(tag) == "table" and tag.kind == "tag" and not seen[tag.id] then
                seen[tag.id] = true
                tags[#tags + 1] = tag
            end
        end
        for _, tag in ipairs(explicitTags or {}) do append(tag) end
        for _, segment in ipairs(descriptionSegments or {}) do append(segment) end
        for _, line in ipairs(ruleLines or {}) do
            for _, segment in ipairs(line.segments or {}) do append(segment) end
        end
        return tags
    end

    local function buildEffectSourceView(source, registry, path, errors)
        if type(source) ~= "table" then
            addError(errors, "invalid_effect_source", path, "효과 원인 정보가 테이블이 아닙니다.")
            return nil
        end
        local kindLabel = SOURCE_KIND_LABELS[source.kind]
        if kindLabel == nil
            or (source.side ~= nil and source.side ~= "player" and source.side ~= "character")
            or type(source.name) ~= "string" or source.name == ""
            or type(source.description) ~= "string" or source.description == ""
            or type(source.rules) ~= "table"
            or type(source.tags) ~= "table" then
            addError(errors, "invalid_effect_source", path, "효과 원인 표시값이 올바르지 않습니다.")
            return nil
        end

        local explicitTags = {}
        for index, tagId in ipairs(source.tags) do
            local tag = lookupTag(registry, tagId, path .. ".tags[" .. index .. "]", errors)
            if tag then explicitTags[#explicitTags + 1] = tag end
        end
        local descriptionSegments = tokenizeForBuild(
            source.description,
            registry,
            path .. ".description",
            errors
        )
        local ruleLines = buildRuleLines(source.rules, registry, path .. ".rules", errors)
        local relatedTags = collectRelatedTags(explicitTags, descriptionSegments, ruleLines)
        local view = {
            kind = source.kind,
            kindLabel = kindLabel,
            name = source.name,
            descriptionSegments = descriptionSegments,
            ruleLines = ruleLines,
            relatedTags = relatedTags,
            hasRelatedTags = #relatedTags > 0,
        }
        if source.side ~= nil then view.side = source.side end
        return view
    end

    local function signedNumber(value)
        local text = value % 1 == 0 and string.format("%.0f", value) or tostring(value)
        return value > 0 and ("+" .. text) or text
    end

    local function buildLastTurnView(lastTurn, registry, errors)
        if type(lastTurn) ~= "table" or lastTurn.available ~= true then
            return { available = false }
        end
        local view = {
            available = true,
            turnNumber = lastTurn.turnNumber,
            summaries = lastTurn.summaries,
            resourceChanges = {
                stealth = {},
                resistance = {},
            },
        }
        for _, resource in ipairs({ "stealth", "resistance" }) do
            local sourceEntries = type(lastTurn.resourceChanges) == "table"
                and lastTurn.resourceChanges[resource]
                or nil
            if type(sourceEntries) ~= "table" then
                addError(errors, "invalid_resource_changes", "$.lastTurn.resourceChanges." .. resource, "자원 변화 목록이 배열이 아닙니다.")
            else
                for index, entry in ipairs(sourceEntries) do
                    local path = "$.lastTurn.resourceChanges." .. resource .. "[" .. index .. "]"
                    local source = type(entry) == "table"
                        and buildEffectSourceView(entry.source, registry, path .. ".source", errors)
                        or nil
                    if type(entry) ~= "table"
                        or not isInteger(entry.sequence, 1)
                        or not isFinite(entry.amount)
                        or entry.amount == 0 then
                        addError(errors, "invalid_resource_change", path, "자원 변화 표시값이 올바르지 않습니다.")
                    elseif source then
                        view.resourceChanges[resource][#view.resourceChanges[resource] + 1] = {
                            sequence = entry.sequence,
                            amount = entry.amount,
                            amountLabel = signedNumber(entry.amount),
                            direction = entry.amount > 0 and "increase" or "decrease",
                            source = source,
                        }
                    end
                end
            end
        end
        return view
    end

    local function buildSafeCardSummaryUncached(card, registry, path, errors)
        if type(card) ~= "table" then
            addError(errors, "missing_card", path, "카드 정의를 찾을 수 없습니다.")
            return nil
        end

        local actionTag = lookupTag(registry, card.actionTag, path .. ".actionTag", errors)
        local mechanisms = {}
        for index, mechanismId in ipairs(card.mechanisms or {}) do
            local tag = lookupTag(registry, mechanismId, path .. ".mechanisms[" .. index .. "]", errors)
            if tag then
                table.insert(mechanisms, tag)
            end
        end

        return {
            cardId = card.id,
            name = card.name,
            descriptionSegments = tokenizeForBuild(card.description, registry, path .. ".description", errors),
            ruleLines = buildRuleLines(card.rules, registry, path .. ".rules", errors),
            actionTag = actionTag or {
                kind = "tag",
                id = "invalid",
                label = "오류",
                tagKind = "action",
                tooltip = "태그 정보를 불러오지 못했습니다.",
            },
            mechanisms = mechanisms,
        }
    end

    local function buildSafeCardSummary(card, registry, path, errors)
        local key = presentationKey(card, registry)
        local cached = presentationCache[key]
        if cached ~= nil then
            presentationClock = presentationClock + 1
            cached.lastUsed = presentationClock
            cached.hits = cached.hits + 1
            presentationStats.hits = presentationStats.hits + 1
            return clonePresentation(cached.value)
        end

        presentationStats.misses = presentationStats.misses + 1
        local beforeErrors = #errors
        local built = buildSafeCardSummaryUncached(card, registry, path, errors)
        if built ~= nil and #errors == beforeErrors then
            evictPresentationIfNeeded()
            presentationClock = presentationClock + 1
            presentationCache[key] = {
                value = clonePresentation(built),
                lastUsed = presentationClock,
                hits = 0,
            }
            presentationCacheSize = presentationCacheSize + 1
        end
        return built
    end

    local function buildPlanView(slot, slotIndex, owner, cards, registry, path, errors)
        local hasDuration = slot.remainingTurns ~= nil
        local hidden = owner == "character" and slot.revealed ~= true
        local view = {
            slotIndex = slotIndex,
            status = hidden and "hidden" or "revealed",
            hasDuration = hasDuration,
        }
        if hasDuration then
            view.remainingTurns = slot.remainingTurns
        end
        if not hidden then
            view.card = buildSafeCardSummary(cards[slot.cardId], registry, path .. ".card", errors)
        end
        return view
    end

    local function buildPlanViews(ownerState, owner, cards, registry, path, errors)
        local capacity = ownerState.planCapacity
        local slots = ownerState.planSlots
        local views = {}
        if not isPlanCapacity(capacity) then
            addError(
                errors,
                "invalid_plan_capacity",
                "$." .. owner .. ".planCapacity",
                "계획 용량은 1 이상 " .. MAX_PLAN_CAPACITY .. " 이하의 정수여야 합니다."
            )
            return views
        end
        for slotIndex = 1, capacity do
            local slot = slots[slotIndex]
            if slot == nil then
                views[slotIndex] = {
                    slotIndex = slotIndex,
                    status = "empty",
                    hasDuration = false,
                }
            else
                views[slotIndex] = buildPlanView(
                    slot,
                    slotIndex,
                    owner,
                    cards,
                    registry,
                    path .. "[" .. slotIndex .. "]",
                    errors
                )
            end
        end
        return views
    end

    local function buildMoodView(state, data, errors)
        local moodId = state.character.mood
        local mood = data.registry.moods[moodId]
        if type(mood) ~= "table" then
            addError(errors, "unknown_mood", "$.character.mood", "무드 표시 정보를 찾을 수 없습니다.")
            mood = { id = moodId, label = moodId, order = 0 }
        end

        local tokens = {}
        local stateTokens = type(state.character.moodTokens) == "table" and state.character.moodTokens or {}
        for registeredMoodId in pairs(data.registry.moods) do
            tokens[registeredMoodId] = stateTokens[registeredMoodId] or 0
        end

        return {
            id = moodId,
            label = mood.label,
            tokenThreshold = 3,
            tokens = tokens,
        }
    end

    local function buildTraitViews(state, data, errors)
        local views = {}
        for _, traitId in ipairs(state.character.traitIds) do
            local trait = data.traits[traitId]
            if type(trait) == "table" and trait.visibility == "public" then
                table.insert(views, {
                    id = trait.id,
                    name = trait.name,
                    description = trait.description,
                    ruleLines = buildRuleLines(trait.rules, data.registry, "$.character.traits." .. traitId .. ".rules", errors),
                })
            end
        end
        return views
    end

    local function countZones(instances)
        local counts = {
            deckCount = 0,
            usedCount = 0,
            discardCount = 0,
            removedCount = 0,
        }
        for _, instance in ipairs(instances) do
            if instance.owner == "player" then
                if instance.zone == "deck" then
                    counts.deckCount = counts.deckCount + 1
                elseif instance.zone == "used" then
                    counts.usedCount = counts.usedCount + 1
                elseif instance.zone == "discard" then
                    counts.discardCount = counts.discardCount + 1
                elseif instance.zone == "removed" then
                    counts.removedCount = counts.removedCount + 1
                end
            end
        end
        return counts
    end

    local function callRuntime(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                code = "runtime_unavailable",
                path = "$.runtime." .. moduleName,
                message = "스크립트 실행기를 찾을 수 없습니다.",
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
        if type(report) ~= "table" then
            return nil, {
                code = "invalid_runtime_result",
                path = "$.runtime." .. moduleName,
                message = "하위 모듈 결과가 테이블이 아닙니다.",
            }
        end
        return report, nil
    end

    local function findInstance(instances, instanceId)
        for _, instance in ipairs(type(instances) == "table" and instances or {}) do
            if instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function findSubwayStation(line, stationId)
        for _, routePath in ipairs(type(line) == "table" and line.paths or {}) do
            for _, station in ipairs(routePath.stations or {}) do
                if station.id == stationId then
                    return station
                end
            end
        end
        return nil
    end

    local function buildSubwayView(state, data, errors, completedTurnsOverride)
        local transit = state.transit
        local line = type(transit) == "table"
            and type(data.subwayLines) == "table"
            and data.subwayLines[transit.lineId]
            or nil
        if type(line) ~= "table" then
            addError(errors, "missing_subway_line", "$.transit.lineId", "전투 지하철 노선 표시 정보를 찾을 수 없습니다.")
            return nil
        end

        local completedTurns = completedTurnsOverride
        if completedTurns == nil then
            completedTurns = state.status == "active"
                and state.turnNumber - 1
                or state.turnNumber
        end
        if completedTurns < 0 then completedTurns = 0 end
        if completedTurns > state.turnLimit then completedTurns = state.turnLimit end
        local currentIndex = completedTurns + 1
        local stations = {}
        for index, stationId in ipairs(transit.stationIds) do
            local station = findSubwayStation(line, stationId)
            if type(station) ~= "table" then
                addError(errors, "missing_subway_station", "$.transit.stationIds[" .. index .. "]", "전투 이동 역 표시 정보를 찾을 수 없습니다.")
            else
                local status = index < currentIndex and "passed"
                    or (index == currentIndex and "current" or "upcoming")
                stations[index] = {
                    index = index,
                    id = station.id,
                    code = station.code,
                    name = station.name,
                    status = status,
                    isStart = index == 1,
                    isDestination = index == #transit.stationIds,
                }
            end
        end
        if #stations ~= #transit.stationIds then
            return nil
        end

        return {
            lineId = line.id,
            lineName = line.name,
            lineCode = line.code,
            lineColor = line.color,
            operatorName = line.operatorName,
            startStation = stations[1],
            currentStation = stations[currentIndex],
            destinationStation = stations[#stations],
            stations = stations,
        }
    end

    local function buildBattleView(state, staticData, context)
        local errors = {}
        local data = normalizeStaticData(staticData)
        if type(data) ~= "table"
            or type(data.registry) ~= "table"
            or type(data.cards) ~= "table"
            or type(data.traits) ~= "table"
            or type(data.environments) ~= "table"
            or type(data.subwayLines) ~= "table"
            or type(data.characters) ~= "table" then
            addError(errors, "missing_static_data", "$", "battleView 생성에는 검증된 전체 정적 데이터가 필요합니다.")
            return failure(errors)
        end

        local stateValidation, stateCallError = callRuntime("stateSchema", "validateBattleState", state, data)
        if stateCallError then
            table.insert(errors, stateCallError)
            return failure(errors)
        end
        if stateValidation.ok ~= true then
            appendNestedErrors(errors, "$.state", stateValidation)
            return failure(errors)
        end

        if context ~= nil and (type(context) ~= "table" or getmetatable(context) ~= nil) then
            addError(errors, "invalid_view_context", "$.context", "battleView context는 메타테이블 없는 객체여야 합니다.")
            return failure(errors)
        end
        context = context or {}
        checkAllowedKeys(context, {
            draft = true,
            pendingTurn = true,
            lastCommittedPending = true,
            generationLocked = true,
            aftermath = true,
        }, "$.context", errors)
        local draftInput = rawget(context, "draft")
        local pendingInput = rawget(context, "pendingTurn")
        local lastCommittedInput = rawget(context, "lastCommittedPending")
        local generationLocked = rawget(context, "generationLocked")
        local aftermathInput = rawget(context, "aftermath")
        if generationLocked ~= nil and generationLocked ~= true then
            addError(
                errors,
                "invalid_generation_lock",
                "$.context.generationLocked",
                "generationLocked는 생성을 기다리는 동안에만 true로 지정할 수 있습니다."
            )
            return failure(errors)
        end
        if draftInput ~= nil and pendingInput ~= nil then
            addError(errors, "ambiguous_view_context", "$.context", "draft와 pendingTurn을 동시에 표시할 수 없습니다.")
            return failure(errors)
        end
        if generationLocked and pendingInput ~= nil then
            addError(
                errors,
                "ambiguous_generation_lock",
                "$.context",
                "pendingTurn 자체가 이미 출력 대기 잠금을 나타내므로 generationLocked를 함께 사용할 수 없습니다."
            )
            return failure(errors)
        end
        if aftermathInput ~= nil then
            if type(aftermathInput) ~= "table" or getmetatable(aftermathInput) ~= nil then
                addError(errors, "invalid_aftermath_context", "$.context.aftermath", "승리 후 자유행동 View context가 일반 객체가 아닙니다.")
                return failure(errors)
            end
            checkAllowedKeys(aftermathInput, {
                completedTurnNumber = true,
                phase = true,
            }, "$.context.aftermath", errors)
            if state.status ~= "victory"
                or not isInteger(aftermathInput.completedTurnNumber, state.turnNumber)
                or aftermathInput.completedTurnNumber >= state.turnLimit then
                addError(errors, "invalid_aftermath_context", "$.context.aftermath", "자유행동 진행이 조기 승리 전투 범위와 다릅니다.")
            end
            if aftermathInput.phase ~= "ready"
                and aftermathInput.phase ~= "inFlight"
                and aftermathInput.phase ~= "requestInjected" then
                addError(errors, "invalid_aftermath_phase", "$.context.aftermath.phase", "자유행동 View phase가 올바르지 않습니다.")
            end
            if draftInput ~= nil or pendingInput ~= nil or generationLocked then
                addError(errors, "ambiguous_aftermath_context", "$.context", "자유행동과 전투 선택 또는 생성 잠금을 함께 표시할 수 없습니다.")
            end
            if #errors > 0 then return failure(errors) end
        end

        local displayState = state
        local phase
        local locked
        local turnId
        local selectedIds = {}
        local previewIds = {}
        local focusedInstanceId = nil
        local interactionToken = nil
        if state.status == "active" and pendingInput ~= nil then
            local pendingValidation, pendingCallError = callRuntime(
                "stateSchema",
                "validatePendingTurn",
                pendingInput,
                data
            )
            if pendingCallError then
                table.insert(errors, pendingCallError)
                return failure(errors)
            end
            if pendingValidation.ok ~= true then
                appendNestedErrors(errors, "$.context.pendingTurn", pendingValidation)
                return failure(errors)
            end
            local receiptValidation, receiptCallError = callRuntime(
                "turnDraft",
                "validateProjectionReceipt",
                state,
                data,
                pendingInput.projectionReceipt
            )
            if receiptCallError then
                table.insert(errors, receiptCallError)
                return failure(errors)
            end
            if receiptValidation.ok ~= true then
                appendNestedErrors(errors, "$.context.pendingTurn.projectionReceipt", receiptValidation)
                return failure(errors)
            end
            phase = "awaitingOutput"
            locked = true
            turnId = pendingInput.turnId
            selectedIds = receiptValidation.receipt.selectedCardInstanceIds
            previewIds = receiptValidation.projection.preview.availableDrawnInstanceIds
        elseif state.status == "active" then
            if draftInput == nil then
                addError(errors, "missing_turn_draft", "$.context.draft", "선택 중 battleView에는 검증할 turnDraft가 필요합니다.")
                return failure(errors)
            end
            -- turnDraft inspect는 외부 draft를 한 번만 재생 검증하면서
            -- 정규 draft와 interaction token을 함께 반환한다.
            local draftInspection, draftCallError = callRuntime(
                "turnDraft",
                "inspect",
                state,
                data,
                draftInput
            )
            if draftCallError then
                table.insert(errors, draftCallError)
                return failure(errors)
            end
            if draftInspection.ok ~= true then
                appendNestedErrors(errors, "$.context.draft", draftInspection)
                return failure(errors)
            end
            if type(draftInspection.interactionToken) ~= "string"
                or string.match(draftInspection.interactionToken, "^draftv1_%d+_%d+_%d+$") == nil then
                addError(
                    errors,
                    "invalid_interaction_token",
                    "$.context.draft",
                    "turnDraft가 유효한 UI 상호작용 토큰을 반환하지 않았습니다."
                )
                return failure(errors)
            end
            interactionToken = draftInspection.interactionToken
            phase = generationLocked and "awaitingOutput" or "selecting"
            locked = generationLocked == true
            local startReceipt = type(state.turnStartReceipt) == "table" and state.turnStartReceipt or nil
            turnId = startReceipt and startReceipt.turnId
                or string.format("%s-turn-%03d", state.battleId, state.turnNumber)
            selectedIds = draftInspection.draft.registeredCardInstanceIds
            previewIds = draftInspection.draft.preview.availableDrawnInstanceIds
            if not generationLocked then
                focusedInstanceId = draftInspection.draft.focusedInstanceId
            end
        else
            if draftInput ~= nil or pendingInput ~= nil or generationLocked then
                addError(errors, "ended_view_context", "$.context", "종료된 battleView에는 draft, 현재 pendingTurn, 생성 잠금을 사용할 수 없습니다.")
                return failure(errors)
            end
            phase = "ended"
            locked = true
            turnId = aftermathInput ~= nil
                and string.format("%s-aftermath-%03d", state.battleId, aftermathInput.completedTurnNumber)
                or state.lastCommittedTurnId
                or string.format("%s-turn-%03d", state.battleId, state.turnNumber)
        end

        local lastTurn = { available = false }
        if lastCommittedInput ~= nil then
            if state.lastCommittedTurnId == nil then
                addError(
                    errors,
                    "unexpected_last_committed_pending",
                    "$.context.lastCommittedPending",
                    "확정 턴이 없는 상태에는 직전 pendingTurn을 표시할 수 없습니다."
                )
                return failure(errors)
            end
            if type(lastCommittedInput) ~= "table"
                or lastCommittedInput.battleId ~= state.battleId
                or lastCommittedInput.turnId ~= state.lastCommittedTurnId then
                addError(
                    errors,
                    "last_committed_pending_mismatch",
                    "$.context.lastCommittedPending",
                    "직전 pendingTurn이 현재 전투의 마지막 확정 턴과 일치하지 않습니다."
                )
                return failure(errors)
            end
            local presented, presentationCallError = callRuntime(
                "turnPresentation",
                "build",
                lastCommittedInput,
                data
            )
            if presentationCallError then
                table.insert(errors, presentationCallError)
                return failure(errors)
            end
            if presented.ok ~= true then
                appendNestedErrors(errors, "$.context.lastCommittedPending", presented)
                return failure(errors)
            end
            if type(presented.lastTurn) ~= "table" or presented.lastTurn.available ~= true then
                addError(
                    errors,
                    "missing_last_turn_presentation",
                    "$.context.lastCommittedPending",
                    "직전 확정 턴에서 공개 표시 자료를 만들지 못했습니다."
                )
                return failure(errors)
            end
            lastTurn = buildLastTurnView(presented.lastTurn, data.registry, errors)
        end

        local characterDefinition = data.characters[displayState.character.characterId]
        local environment = data.environments[displayState.environmentId]
        if type(characterDefinition) ~= "table" or type(environment) ~= "table" then
            addError(errors, "missing_static_reference", "$", "캐릭터 또는 환경 정의를 찾을 수 없습니다.")
            return failure(errors)
        end

        local selectedOrder = {}
        for index, instanceId in ipairs(selectedIds) do
            selectedOrder[instanceId] = index
        end

        local displayEntries = {}
        local visibleSet = {}
        local handInstances = {}
        for _, instance in ipairs(displayState.cardInstances) do
            if instance.owner == "player" and instance.zone == "hand" then
                table.insert(handInstances, instance)
            end
        end
        table.sort(handInstances, function(left, right)
            return left.position < right.position
        end)
        for _, instance in ipairs(handInstances) do
            visibleSet[instance.instanceId] = true
            table.insert(displayEntries, { instance = instance, origin = "hand" })
        end
        for index, instanceId in ipairs(previewIds) do
            if visibleSet[instanceId] then
                addError(errors, "duplicate_preview_card", "$.preview[" .. index .. "]", "프리뷰 카드가 권위 손패와 중복되었습니다.")
            else
                local instance = findInstance(displayState.cardInstances, instanceId)
                if type(instance) ~= "table" or instance.owner ~= "player" then
                    addError(errors, "invalid_preview_card", "$.preview[" .. index .. "]", "프리뷰 카드 인스턴스를 권위 상태에서 찾을 수 없습니다.")
                else
                    visibleSet[instanceId] = true
                    table.insert(displayEntries, { instance = instance, origin = "preview" })
                end
            end
        end

        local handItems = {}
        local playableById = {}
        for slot, entry in ipairs(displayEntries) do
            local instance = entry.instance
            local card = data.cards[instance.cardId]
            local summary = buildSafeCardSummary(card, data.registry, "$.hand.items[" .. slot .. "]", errors)
            if summary then
                local baseStealthCost = card.base.stealthCost
                local baseResistanceDamage = card.base.resistanceDamage
                local playable = true
                local reasonCode = "none"
                if locked then
                    playable = false
                    reasonCode = phase == "awaitingOutput" and "awaiting_output" or "battle_ended"
                elseif displayState.player.stealth <= baseStealthCost then
                    playable = false
                    reasonCode = "insufficient_stealth"
                end
                playableById[instance.instanceId] = playable

                table.insert(handItems, {
                    slot = slot,
                    origin = entry.origin,
                    instanceId = instance.instanceId,
                    cardId = summary.cardId,
                    name = summary.name,
                    descriptionSegments = summary.descriptionSegments,
                    ruleLines = summary.ruleLines,
                    actionTag = summary.actionTag,
                    mechanisms = summary.mechanisms,
                    baseStealthCost = baseStealthCost,
                    finalStealthCost = baseStealthCost,
                    baseResistanceDamage = baseResistanceDamage,
                    finalResistanceDamage = baseResistanceDamage,
                    playable = playable,
                    reasonCode = reasonCode,
                    selected = selectedOrder[instance.instanceId] ~= nil,
                    selectionOrder = selectedOrder[instance.instanceId] or 0,
                })
            end
        end

        local mainActionCount = 0
        local mainActionIndex = nil
        local selectedPlayable = true
        for index, instanceId in ipairs(selectedIds) do
            local instance = findInstance(displayState.cardInstances, instanceId)
            local card = instance and data.cards[instance.cardId] or nil
            if card and not hasMechanism(card, "chain") then
                mainActionCount = mainActionCount + 1
                mainActionIndex = index
            end
            if visibleSet[instanceId] ~= true or playableById[instanceId] ~= true then
                selectedPlayable = false
            end
        end

        local selectedCount = #selectedIds
        local hasMainAction = mainActionCount == 1
        local mainActionLast = mainActionCount == 0 or mainActionIndex == selectedCount
        local mode = selectedCount == 0 and "pass"
            or (hasMainAction and "action" or "chain_pass")
        local canSubmit = not locked
            and mainActionCount <= 1
            and mainActionLast
            and selectedPlayable
        local selectionReason = "none"
        if locked then
            selectionReason = phase == "awaitingOutput" and "awaiting_output" or "battle_ended"
        elseif mainActionCount > 1 then
            selectionReason = "multiple_main_actions"
        elseif not mainActionLast then
            selectionReason = "main_action_not_last"
        elseif not selectedPlayable then
            selectionReason = "unplayable_selection"
        end

        local publicAction = { status = "none" }
        if displayState.characterIntent.publicActionTag ~= nil then
            local tag = lookupTag(data.registry, displayState.characterIntent.publicActionTag, "$.character.publicAction.tag", errors)
            if tag then
                publicAction = {
                    status = "tagRevealed",
                    tag = tag,
                }
            end
        end

        local outcomeLabels = {
            active = "진행 중",
            victory = "승리",
            defeat = "패배",
        }
        local subwayView = buildSubwayView(
            displayState,
            data,
            errors,
            aftermathInput and aftermathInput.completedTurnNumber or nil
        )
        if subwayView == nil then
            return failure(errors)
        end

        local selectionView = {
            count = selectedCount,
            mode = mode,
            hasMainAction = hasMainAction,
            canSubmit = canSubmit,
            reasonCode = selectionReason,
        }
        if phase == "selecting" and focusedInstanceId ~= nil then
            selectionView.focusedInstanceId = focusedInstanceId
        end

        local view = {
            schemaVersion = SCHEMA_VERSION,
            kind = "battleView",
            battleId = displayState.battleId,
            turnId = turnId,
            phase = phase,
            locked = locked,
            tagGlossary = buildTagGlossary(publicAction, handItems),
            subway = subwayView,
            environment = {
                id = environment.id,
                name = environment.name,
                description = environment.description,
                ruleLines = buildRuleLines(environment.rules, data.registry, "$.environment.rules", errors),
            },
            player = {
                stealth = displayState.player.stealth,
                planCapacity = displayState.player.planCapacity,
                plans = buildPlanViews(
                    displayState.player,
                    "player",
                    data.cards,
                    data.registry,
                    "$.player.plans",
                    errors
                ),
            },
            character = {
                id = characterDefinition.id,
                name = characterDefinition.name,
                resistance = displayState.character.resistance,
                startingResistance = characterDefinition.battle.startingResistance,
                mood = buildMoodView(displayState, data, errors),
                publicAction = publicAction,
                traits = buildTraitViews(displayState, data, errors),
                planCapacity = displayState.character.planCapacity,
                plans = buildPlanViews(
                    displayState.character,
                    "character",
                    data.cards,
                    data.registry,
                    "$.character.plans",
                    errors
                ),
            },
            hand = {
                count = #handItems,
                items = handItems,
            },
            selection = selectionView,
            zones = countZones(displayState.cardInstances),
            lastTurn = lastTurn,
            outcome = {
                status = displayState.status,
                label = outcomeLabels[displayState.status],
            },
            aftermath = aftermathInput == nil and { active = false } or {
                active = true,
                awaitingOutput = aftermathInput.phase ~= "ready",
                finalTurn = aftermathInput.completedTurnNumber + 1 == state.turnLimit,
            },
        }
        if interactionToken ~= nil then
            view.interactionToken = interactionToken
        end

        if #errors > 0 then
            return failure(errors)
        end

        return success("view", view)
    end

    local function validateTagView(value, path, errors, expectedTagKind)
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
        if value.kind ~= "tag" then
            addError(errors, "invalid_tag_kind", path .. ".kind", "태그 조각의 kind는 tag여야 합니다.")
        end
        if not isAsciiId(value.id) then
            addError(errors, "invalid_tag_id", path .. ".id", "태그 ID가 올바르지 않습니다.")
        end
        if type(value.label) ~= "string" or value.label == "" then
            addError(errors, "invalid_tag_label", path .. ".label", "태그 표시명이 필요합니다.")
        end
        if value.tagKind ~= "action" and value.tagKind ~= "mechanism" then
            addError(errors, "invalid_tag_type", path .. ".tagKind", "tagKind가 올바르지 않습니다.")
        elseif expectedTagKind and value.tagKind ~= expectedTagKind then
            addError(errors, "tag_role_mismatch", path .. ".tagKind", "이 위치의 태그 종류는 " .. expectedTagKind .. "이어야 합니다.")
        end
        if type(value.tooltip) ~= "string" or value.tooltip == "" then
            addError(errors, "invalid_tag_tooltip", path .. ".tooltip", "태그 툴팁이 필요합니다.")
        end
    end

    local function validateSegments(value, path, errors)
        local length = getArrayLength(value, path, errors)
        if length == nil then
            return
        end
        for index = 1, length do
            local segment = value[index]
            local segmentPath = path .. "[" .. index .. "]"
            if type(segment) ~= "table" then
                addError(errors, "invalid_segment", segmentPath, "문장 조각이 테이블이 아닙니다.")
            elseif segment.kind == "text" then
                checkAllowedKeys(segment, { kind = true, value = true }, segmentPath, errors)
                if type(segment.value) ~= "string" or segment.value == "" then
                    addError(errors, "invalid_text_segment", segmentPath .. ".value", "빈 텍스트 조각은 허용하지 않습니다.")
                end
            elseif segment.kind == "tag" then
                validateTagView(segment, segmentPath, errors)
            else
                addError(errors, "invalid_segment_kind", segmentPath .. ".kind", "알 수 없는 문장 조각입니다.")
            end
        end
    end

    local function validateRuleLines(value, path, errors)
        local length = getArrayLength(value, path, errors)
        if length == nil then
            return
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

    local function validateTagArray(value, path, errors, expectedTagKind)
        local length = getArrayLength(value, path, errors)
        if length == nil then
            return
        end
        for index = 1, length do
            validateTagView(value[index], path .. "[" .. index .. "]", errors, expectedTagKind)
        end
    end

    local function validateSafeCardSummary(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_card_summary", path, "카드 요약이 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            cardId = true,
            name = true,
            descriptionSegments = true,
            ruleLines = true,
            actionTag = true,
            mechanisms = true,
        }, path, errors)
        if not isAsciiId(value.cardId) then
            addError(errors, "invalid_card_id", path .. ".cardId", "카드 ID가 올바르지 않습니다.")
        end
        if type(value.name) ~= "string" or value.name == "" then
            addError(errors, "invalid_card_name", path .. ".name", "카드 이름이 필요합니다.")
        end
        validateSegments(value.descriptionSegments, path .. ".descriptionSegments", errors)
        validateRuleLines(value.ruleLines, path .. ".ruleLines", errors)
        validateTagView(value.actionTag, path .. ".actionTag", errors, "action")
        validateTagArray(value.mechanisms, path .. ".mechanisms", errors, "mechanism")
    end

    local function validateEffectSourceView(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_effect_source", path, "효과 원인 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            kind = true,
            kindLabel = true,
            side = true,
            name = true,
            descriptionSegments = true,
            ruleLines = true,
            relatedTags = true,
            hasRelatedTags = true,
        }, path, errors)
        if SOURCE_KIND_LABELS[value.kind] ~= value.kindLabel then
            addError(errors, "invalid_effect_source_kind", path .. ".kind", "효과 원인 종류와 표시명이 일치하지 않습니다.")
        end
        if value.side ~= nil and value.side ~= "player" and value.side ~= "character" then
            addError(errors, "invalid_effect_source_side", path .. ".side", "효과 원인 진영이 올바르지 않습니다.")
        end
        if type(value.name) ~= "string" or value.name == "" then
            addError(errors, "invalid_effect_source_name", path .. ".name", "효과 원인 이름이 필요합니다.")
        end
        validateSegments(value.descriptionSegments, path .. ".descriptionSegments", errors)
        validateRuleLines(value.ruleLines, path .. ".ruleLines", errors)
        local tagCount = getArrayLength(value.relatedTags, path .. ".relatedTags", errors)
        if tagCount then
            validateTagArray(value.relatedTags, path .. ".relatedTags", errors)
            if value.hasRelatedTags ~= (tagCount > 0) then
                addError(errors, "effect_source_tag_flag_mismatch", path .. ".hasRelatedTags", "관련 태그 표시 여부가 태그 목록과 다릅니다.")
            end
        end
        if value.hasRelatedTags ~= true and value.hasRelatedTags ~= false then
            addError(errors, "invalid_effect_source_tag_flag", path .. ".hasRelatedTags", "관련 태그 표시 여부는 불리언이어야 합니다.")
        end
    end

    local function validateResourceChanges(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_resource_changes", path, "자원 변화 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, { stealth = true, resistance = true }, path, errors)
        local seenSequences = {}
        for _, resource in ipairs({ "stealth", "resistance" }) do
            local entries = value[resource]
            local length = getArrayLength(entries, path .. "." .. resource, errors)
            if length then
                for index = 1, length do
                    local entry = entries[index]
                    local entryPath = path .. "." .. resource .. "[" .. index .. "]"
                    if type(entry) ~= "table" then
                        addError(errors, "invalid_resource_change", entryPath, "자원 변화 항목이 테이블이 아닙니다.")
                    else
                        checkAllowedKeys(entry, {
                            sequence = true,
                            amount = true,
                            amountLabel = true,
                            direction = true,
                            source = true,
                        }, entryPath, errors)
                        if not isInteger(entry.sequence, 1) or seenSequences[entry.sequence] then
                            addError(errors, "invalid_resource_change_sequence", entryPath .. ".sequence", "자원 변화 사건 순번이 올바르지 않습니다.")
                        else
                            seenSequences[entry.sequence] = true
                        end
                        if not isFinite(entry.amount)
                            or entry.amount == 0
                            or entry.amountLabel ~= signedNumber(entry.amount)
                            or entry.direction ~= (entry.amount > 0 and "increase" or "decrease") then
                            addError(errors, "invalid_resource_change_amount", entryPath, "자원 변화량 표시가 올바르지 않습니다.")
                        end
                        validateEffectSourceView(entry.source, entryPath .. ".source", errors)
                    end
                end
            end
        end
    end

    local function validatePlanView(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_plan_view", path, "계획 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            slotIndex = true,
            status = true,
            hasDuration = true,
            remainingTurns = true,
            card = true,
        }, path, errors)
        if not isInteger(value.slotIndex, 1) then
            addError(errors, "invalid_plan_slot_index", path .. ".slotIndex", "계획 슬롯 번호가 올바르지 않습니다.")
        end
        if value.status ~= "empty" and value.status ~= "hidden" and value.status ~= "revealed" then
            addError(errors, "invalid_plan_status", path .. ".status", "계획 공개 상태가 올바르지 않습니다.")
        end
        if value.hasDuration ~= true and value.hasDuration ~= false then
            addError(errors, "invalid_plan_duration_flag", path .. ".hasDuration", "hasDuration은 불리언이어야 합니다.")
        elseif value.hasDuration then
            if not isInteger(value.remainingTurns, 1) then
                addError(errors, "invalid_remaining_turns", path .. ".remainingTurns", "남은 지속 턴이 올바르지 않습니다.")
            end
        elseif value.remainingTurns ~= nil then
            addError(errors, "unexpected_remaining_turns", path .. ".remainingTurns", "지속시간이 없는 계획에 남은 턴을 표시할 수 없습니다.")
        end

        if value.status == "revealed" then
            validateSafeCardSummary(value.card, path .. ".card", errors)
        elseif value.card ~= nil then
            addError(errors, "hidden_plan_leak", path .. ".card", "미공개 또는 빈 계획에 카드 정보를 넣을 수 없습니다.")
        end
        if value.status == "empty" and value.hasDuration ~= false then
            addError(errors, "empty_plan_duration", path .. ".hasDuration", "빈 계획에는 지속시간이 없습니다.")
        end
    end

    local function validatePlanViews(value, capacity, path, errors, allowHidden)
        local length = getArrayLength(value, path, errors)
        if length == nil then
            return
        end
        if isPlanCapacity(capacity) and length ~= capacity then
            addError(errors, "plan_capacity_mismatch", path, "계획 View 배열 길이가 계획 용량과 다릅니다.")
        end

        local emptyStarted = false
        for index = 1, length do
            local plan = value[index]
            local planPath = path .. "[" .. index .. "]"
            validatePlanView(plan, planPath, errors)
            if type(plan) == "table" then
                if plan.slotIndex ~= index then
                    addError(errors, "plan_slot_index_mismatch", planPath .. ".slotIndex", "계획 배열 순서와 슬롯 번호가 다릅니다.")
                end
                if plan.status == "empty" then
                    emptyStarted = true
                elseif emptyStarted then
                    addError(errors, "plan_slot_order_mismatch", planPath .. ".status", "활성 계획은 빈 계획 슬롯보다 앞에 있어야 합니다.")
                end
                if plan.status == "hidden" and not allowHidden then
                    addError(errors, "hidden_player_plan", planPath .. ".status", "플레이어 자신의 계획은 숨김 상태로 표시할 수 없습니다.")
                end
            end
        end
    end

    local function validateCardView(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_card_view", path, "손패 카드 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            slot = true,
            origin = true,
            instanceId = true,
            cardId = true,
            name = true,
            descriptionSegments = true,
            ruleLines = true,
            actionTag = true,
            mechanisms = true,
            baseStealthCost = true,
            finalStealthCost = true,
            baseResistanceDamage = true,
            finalResistanceDamage = true,
            playable = true,
            reasonCode = true,
            selected = true,
            selectionOrder = true,
        }, path, errors)
        if not isInteger(value.slot, 1) then
            addError(errors, "invalid_card_slot", path .. ".slot", "손패 슬롯이 올바르지 않습니다.")
        end
        if value.origin ~= "hand" and value.origin ~= "preview" then
            addError(errors, "invalid_card_origin", path .. ".origin", "카드 표시 origin은 hand 또는 preview여야 합니다.")
        end
        if not isRuntimeId(value.instanceId) then
            addError(errors, "invalid_instance_id", path .. ".instanceId", "카드 인스턴스 ID가 올바르지 않습니다.")
        end
        if not isAsciiId(value.cardId) then
            addError(errors, "invalid_card_id", path .. ".cardId", "카드 ID가 올바르지 않습니다.")
        end
        if type(value.name) ~= "string" or value.name == "" then
            addError(errors, "invalid_card_name", path .. ".name", "카드 이름이 필요합니다.")
        end
        validateSegments(value.descriptionSegments, path .. ".descriptionSegments", errors)
        validateRuleLines(value.ruleLines, path .. ".ruleLines", errors)
        validateTagView(value.actionTag, path .. ".actionTag", errors, "action")
        validateTagArray(value.mechanisms, path .. ".mechanisms", errors, "mechanism")
        for _, field in ipairs({
            "baseStealthCost",
            "finalStealthCost",
            "baseResistanceDamage",
            "finalResistanceDamage",
        }) do
            if not isFinite(value[field]) or value[field] < 0 then
                addError(errors, "invalid_card_number", path .. "." .. field, "카드 수치는 0 이상의 유한한 숫자여야 합니다.")
            end
        end
        if value.playable ~= true and value.playable ~= false then
            addError(errors, "invalid_playable", path .. ".playable", "playable은 불리언이어야 합니다.")
        end
        if type(value.reasonCode) ~= "string" then
            addError(errors, "invalid_reason_code", path .. ".reasonCode", "사유 코드는 문자열이어야 합니다.")
        elseif value.playable == true and value.reasonCode ~= "none" then
            addError(errors, "playable_reason_mismatch", path .. ".reasonCode", "사용 가능한 카드는 사유 코드가 none이어야 합니다.")
        elseif value.playable == false and value.reasonCode == "none" then
            addError(errors, "disabled_reason_missing", path .. ".reasonCode", "사용할 수 없는 카드에는 사유 코드가 필요합니다.")
        end
        if value.selected ~= true and value.selected ~= false then
            addError(errors, "invalid_selected", path .. ".selected", "selected는 불리언이어야 합니다.")
        end
        if not isInteger(value.selectionOrder, 0) then
            addError(errors, "invalid_selection_order", path .. ".selectionOrder", "선택 순서가 올바르지 않습니다.")
        elseif value.selected and value.selectionOrder == 0 then
            addError(errors, "selected_order_missing", path .. ".selectionOrder", "선택 카드에는 1 이상의 선택 순서가 필요합니다.")
        elseif not value.selected and value.selectionOrder ~= 0 then
            addError(errors, "unselected_order_present", path .. ".selectionOrder", "미선택 카드의 선택 순서는 0이어야 합니다.")
        end
    end

    local function validateSubwayStationView(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_subway_station_view", path, "역 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            index = true,
            id = true,
            code = true,
            name = true,
            status = true,
            isStart = true,
            isDestination = true,
        }, path, errors)
        if not isInteger(value.index, 1) then
            addError(errors, "invalid_subway_station_index", path .. ".index", "역 순번이 올바르지 않습니다.")
        end
        if not isAsciiId(value.id) then
            addError(errors, "invalid_subway_station_id", path .. ".id", "역 ID가 올바르지 않습니다.")
        end
        if type(value.code) ~= "string"
            or string.match(value.code, "^[A-Za-z]+%d%d$") == nil then
            addError(errors, "invalid_subway_station_code", path .. ".code", "역 번호가 올바르지 않습니다.")
        end
        if type(value.name) ~= "string" or value.name == "" then
            addError(errors, "invalid_subway_station_name", path .. ".name", "역 이름이 필요합니다.")
        end
        if value.status ~= "passed" and value.status ~= "current" and value.status ~= "upcoming" then
            addError(errors, "invalid_subway_station_status", path .. ".status", "역 진행 상태가 올바르지 않습니다.")
        end
        if value.isStart ~= true and value.isStart ~= false then
            addError(errors, "invalid_subway_start_flag", path .. ".isStart", "isStart는 불리언이어야 합니다.")
        end
        if value.isDestination ~= true and value.isDestination ~= false then
            addError(errors, "invalid_subway_destination_flag", path .. ".isDestination", "isDestination은 불리언이어야 합니다.")
        end
    end

    local function sameSubwayStation(left, right)
        return type(left) == "table"
            and type(right) == "table"
            and left.index == right.index
            and left.id == right.id
            and left.code == right.code
            and left.name == right.name
            and left.status == right.status
            and left.isStart == right.isStart
            and left.isDestination == right.isDestination
    end

    local function validateSubwayView(value, path, errors)
        if type(value) ~= "table" then
            addError(errors, "invalid_subway_view", path, "지하철 노선 View가 테이블이 아닙니다.")
            return
        end
        checkAllowedKeys(value, {
            lineId = true,
            lineName = true,
            lineCode = true,
            lineColor = true,
            operatorName = true,
            startStation = true,
            currentStation = true,
            destinationStation = true,
            stations = true,
        }, path, errors)
        if not isAsciiId(value.lineId) then
            addError(errors, "invalid_subway_line_id", path .. ".lineId", "노선 ID가 올바르지 않습니다.")
        end
        for _, field in ipairs({ "lineName", "lineCode", "operatorName" }) do
            if type(value[field]) ~= "string" or value[field] == "" then
                addError(errors, "invalid_subway_line_label", path .. "." .. field, "노선 표시 문자열이 필요합니다.")
            end
        end
        if type(value.lineColor) ~= "string"
            or string.match(value.lineColor, "^#%x%x%x%x%x%x$") == nil then
            addError(errors, "invalid_subway_line_color", path .. ".lineColor", "노선 색상은 #RRGGBB 형식이어야 합니다.")
        end

        validateSubwayStationView(value.startStation, path .. ".startStation", errors)
        validateSubwayStationView(value.currentStation, path .. ".currentStation", errors)
        validateSubwayStationView(value.destinationStation, path .. ".destinationStation", errors)

        local length = getArrayLength(value.stations, path .. ".stations", errors)
        if length == nil then
            return
        end
        if length < 8 or length > 13 then
            addError(errors, "invalid_subway_route_length", path .. ".stations", "전투 노선은 8~13개 역이어야 합니다.")
        end

        local currentCount = 0
        local currentStation = nil
        local reachedCurrent = false
        for index = 1, length do
            local station = value.stations[index]
            local stationPath = path .. ".stations[" .. index .. "]"
            validateSubwayStationView(station, stationPath, errors)
            if type(station) == "table" then
                if station.index ~= index then
                    addError(errors, "subway_station_index_mismatch", stationPath .. ".index", "역 순번과 배열 위치가 다릅니다.")
                end
                if station.isStart ~= (index == 1) then
                    addError(errors, "subway_start_mismatch", stationPath .. ".isStart", "출발역 표시는 첫 역에만 있어야 합니다.")
                end
                if station.isDestination ~= (index == length) then
                    addError(errors, "subway_destination_mismatch", stationPath .. ".isDestination", "도착역 표시는 마지막 역에만 있어야 합니다.")
                end
                if station.status == "current" then
                    currentCount = currentCount + 1
                    currentStation = station
                    reachedCurrent = true
                elseif station.status == "passed" and reachedCurrent then
                    addError(errors, "invalid_subway_status_order", stationPath .. ".status", "통과한 역은 현재역보다 앞에 있어야 합니다.")
                elseif station.status == "upcoming" and not reachedCurrent then
                    addError(errors, "invalid_subway_status_order", stationPath .. ".status", "예정 역은 현재역보다 뒤에 있어야 합니다.")
                end
            end
        end
        if currentCount ~= 1 then
            addError(errors, "invalid_subway_current_count", path .. ".stations", "현재역은 정확히 하나여야 합니다.")
        end
        if length > 0 then
            if not sameSubwayStation(value.startStation, value.stations[1]) then
                addError(errors, "subway_start_reference_mismatch", path .. ".startStation", "출발역 요약과 노선의 첫 역이 다릅니다.")
            end
            if not sameSubwayStation(value.destinationStation, value.stations[length]) then
                addError(errors, "subway_destination_reference_mismatch", path .. ".destinationStation", "도착역 요약과 노선의 마지막 역이 다릅니다.")
            end
            if not sameSubwayStation(value.currentStation, currentStation) then
                addError(errors, "subway_current_reference_mismatch", path .. ".currentStation", "현재역 요약과 노선의 현재역이 다릅니다.")
            end
        end
    end

    local function validateAftermathView(value, path, errors)
        if value == nil then return end
        if type(value) ~= "table" then
            addError(errors, "invalid_aftermath_view", path, "승리 후 자유행동 View가 테이블이 아닙니다.")
            return
        end
        if value.active == false then
            checkAllowedKeys(value, { active = true }, path, errors)
            return
        end
        checkAllowedKeys(value, {
            active = true,
            awaitingOutput = true,
            finalTurn = true,
        }, path, errors)
        if value.active ~= true then
            addError(errors, "invalid_aftermath_active", path .. ".active", "자유행동 active는 불리언이어야 합니다.")
        end
        for _, field in ipairs({ "awaitingOutput", "finalTurn" }) do
            if value[field] ~= true and value[field] ~= false then
                addError(errors, "invalid_aftermath_flag", path .. "." .. field, "자유행동 표시 플래그는 불리언이어야 합니다.")
            end
        end
    end

    local function validateBattleView(view)
        local errors = {}
        if type(view) ~= "table" then
            addError(errors, "invalid_view", "$", "battleView가 테이블이 아닙니다.")
            return failure(errors)
        end
        validateJsonSafe(view, "$", errors)
        if #errors > 0 then
            return failure(errors)
        end
        checkAllowedKeys(view, {
            schemaVersion = true,
            kind = true,
            battleId = true,
            turnId = true,
            phase = true,
            locked = true,
            interactionToken = true,
            tagGlossary = true,
            subway = true,
            environment = true,
            player = true,
            character = true,
            hand = true,
            selection = true,
            zones = true,
            lastTurn = true,
            outcome = true,
            aftermath = true,
        }, "$", errors)
        if view.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", "$.schemaVersion", "지원하지 않는 battleView 스키마입니다.")
        end
        if view.kind ~= "battleView" then
            addError(errors, "invalid_kind", "$.kind", "kind는 battleView여야 합니다.")
        end
        if not isRuntimeId(view.battleId) or not isRuntimeId(view.turnId) then
            addError(errors, "invalid_runtime_id", "$", "battleId와 turnId가 올바르지 않습니다.")
        end
        if view.phase ~= "selecting" and view.phase ~= "awaitingOutput" and view.phase ~= "ended" then
            addError(errors, "invalid_phase", "$.phase", "알 수 없는 battleView phase입니다.")
        end
        if view.locked ~= true and view.locked ~= false then
            addError(errors, "invalid_locked", "$.locked", "locked는 불리언이어야 합니다.")
        elseif (view.phase == "selecting" and view.locked) or (view.phase ~= "selecting" and not view.locked) then
            addError(errors, "phase_lock_mismatch", "$.locked", "phase와 locked 값이 일치하지 않습니다.")
        end
        if view.interactionToken ~= nil
            and (type(view.interactionToken) ~= "string"
                or string.match(view.interactionToken, "^draftv1_%d+_%d+_%d+$") == nil) then
            addError(errors, "invalid_interaction_token", "$.interactionToken", "UI 상호작용 토큰이 올바르지 않습니다.")
        elseif view.phase == "selecting" and view.interactionToken == nil then
            addError(errors, "missing_interaction_token", "$.interactionToken", "선택 가능한 View에는 상호작용 토큰이 필요합니다.")
        elseif view.phase == "ended" and view.interactionToken ~= nil then
            addError(errors, "ended_interaction_token", "$.interactionToken", "종료 View에는 상호작용 토큰을 넣을 수 없습니다.")
        end
        validateAftermathView(view.aftermath, "$.aftermath", errors)

        local glossaryLength = getArrayLength(view.tagGlossary, "$.tagGlossary", errors)
        if glossaryLength then
            local seenTagIds = {}
            for index = 1, glossaryLength do
                local tag = view.tagGlossary[index]
                local path = "$.tagGlossary[" .. index .. "]"
                validateTagView(tag, path, errors)
                if type(tag) == "table" and type(tag.id) == "string" then
                    if seenTagIds[tag.id] then
                        addError(errors, "duplicate_glossary_tag", path .. ".id", "태그 설명 ID가 중복되었습니다.")
                    end
                    seenTagIds[tag.id] = true
                end
            end
        end

        validateSubwayView(view.subway, "$.subway", errors)

        if type(view.environment) ~= "table" then
            addError(errors, "invalid_environment", "$.environment", "environment가 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.environment, { id = true, name = true, description = true, ruleLines = true }, "$.environment", errors)
            if not isAsciiId(view.environment.id) or type(view.environment.name) ~= "string" or type(view.environment.description) ~= "string" then
                addError(errors, "invalid_environment_value", "$.environment", "환경 표시 값이 올바르지 않습니다.")
            end
            validateRuleLines(view.environment.ruleLines, "$.environment.ruleLines", errors)
        end

        if type(view.player) ~= "table" then
            addError(errors, "invalid_player", "$.player", "player가 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.player, {
                stealth = true,
                planCapacity = true,
                plans = true,
            }, "$.player", errors)
            if not isFinite(view.player.stealth) then
                addError(errors, "invalid_stealth", "$.player.stealth", "은폐 표시값이 올바르지 않습니다.")
            end
            if not isPlanCapacity(view.player.planCapacity) then
                addError(
                    errors,
                    "invalid_plan_capacity",
                    "$.player.planCapacity",
                    "플레이어 계획 용량은 1 이상 " .. MAX_PLAN_CAPACITY .. " 이하의 정수여야 합니다."
                )
            end
            validatePlanViews(view.player.plans, view.player.planCapacity, "$.player.plans", errors, false)
        end

        if type(view.character) ~= "table" then
            addError(errors, "invalid_character", "$.character", "character가 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.character, {
                id = true,
                name = true,
                resistance = true,
                startingResistance = true,
                mood = true,
                publicAction = true,
                traits = true,
                planCapacity = true,
                plans = true,
            }, "$.character", errors)
            if not isAsciiId(view.character.id) or type(view.character.name) ~= "string" then
                addError(errors, "invalid_character_value", "$.character", "캐릭터 표시 값이 올바르지 않습니다.")
            end
            if not isFinite(view.character.resistance) or not isFinite(view.character.startingResistance) then
                addError(errors, "invalid_resistance", "$.character", "저항 표시값이 올바르지 않습니다.")
            end

            local mood = view.character.mood
            if type(mood) ~= "table" then
                addError(errors, "invalid_mood", "$.character.mood", "무드 View가 테이블이 아닙니다.")
            else
                checkAllowedKeys(mood, {
                    id = true,
                    label = true,
                    tokenThreshold = true,
                    tokens = true,
                }, "$.character.mood", errors)
                if not isAsciiId(mood.id) or type(mood.label) ~= "string" then
                    addError(errors, "invalid_mood_value", "$.character.mood", "무드 표시 값이 올바르지 않습니다.")
                end
                if mood.tokenThreshold ~= 3 or type(mood.tokens) ~= "table" then
                    addError(errors, "invalid_mood_tokens", "$.character.mood", "무드 토큰 표시값이 올바르지 않습니다.")
                else
                    for _, moodId in ipairs({ "rejection", "suspicion", "ignore", "confusion", "compliance" }) do
                        if not isInteger(mood.tokens[moodId], 0) then
                            addError(errors, "invalid_mood_token_count", "$.character.mood.tokens." .. moodId, "무드 토큰 표시값은 0 이상의 정수여야 합니다.")
                        end
                    end
                end
            end

            local publicAction = view.character.publicAction
            if type(publicAction) ~= "table" then
                addError(errors, "invalid_public_action", "$.character.publicAction", "공개 행동 View가 테이블이 아닙니다.")
            elseif publicAction.status == "none" then
                checkAllowedKeys(publicAction, { status = true }, "$.character.publicAction", errors)
            elseif publicAction.status == "tagRevealed" then
                checkAllowedKeys(publicAction, { status = true, tag = true }, "$.character.publicAction", errors)
                validateTagView(publicAction.tag, "$.character.publicAction.tag", errors, "action")
            else
                addError(errors, "invalid_public_action_status", "$.character.publicAction.status", "공개 행동 상태가 올바르지 않습니다.")
            end

            local traitCount = getArrayLength(view.character.traits, "$.character.traits", errors)
            if traitCount then
                for index = 1, traitCount do
                    local trait = view.character.traits[index]
                    local path = "$.character.traits[" .. index .. "]"
                    if type(trait) ~= "table" then
                        addError(errors, "invalid_trait_view", path, "특징 View가 테이블이 아닙니다.")
                    else
                        checkAllowedKeys(trait, { id = true, name = true, description = true, ruleLines = true }, path, errors)
                        if not isAsciiId(trait.id) or type(trait.name) ~= "string" or type(trait.description) ~= "string" then
                            addError(errors, "invalid_trait_value", path, "특징 표시 값이 올바르지 않습니다.")
                        end
                        validateRuleLines(trait.ruleLines, path .. ".ruleLines", errors)
                    end
                end
            end
            if not isPlanCapacity(view.character.planCapacity) then
                addError(
                    errors,
                    "invalid_plan_capacity",
                    "$.character.planCapacity",
                    "캐릭터 계획 용량은 1 이상 " .. MAX_PLAN_CAPACITY .. " 이하의 정수여야 합니다."
                )
            end
            validatePlanViews(view.character.plans, view.character.planCapacity, "$.character.plans", errors, true)
        end

        if type(view.hand) ~= "table" then
            addError(errors, "invalid_hand", "$.hand", "hand가 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.hand, { count = true, items = true }, "$.hand", errors)
            local handCount = getArrayLength(view.hand.items, "$.hand.items", errors)
            if handCount and view.hand.count ~= handCount then
                addError(errors, "hand_count_mismatch", "$.hand.count", "손패 개수와 항목 수가 다릅니다.")
            end
            if handCount then
                local instanceSeen = {}
                local previewStarted = false
                for index = 1, handCount do
                    local item = view.hand.items[index]
                    local itemPath = "$.hand.items[" .. index .. "]"
                    validateCardView(item, itemPath, errors)
                    if type(item) == "table" and item.slot ~= index then
                        addError(errors, "hand_slot_mismatch", itemPath .. ".slot", "손패 배열 순서와 슬롯이 다릅니다.")
                    end
                    if type(item) == "table" and isRuntimeId(item.instanceId) then
                        if instanceSeen[item.instanceId] then
                            addError(errors, "duplicate_view_card", itemPath .. ".instanceId", "같은 카드 인스턴스를 View에 중복 표시할 수 없습니다.")
                        end
                        instanceSeen[item.instanceId] = true
                    end
                    if type(item) == "table" then
                        if item.origin == "preview" then
                            previewStarted = true
                        elseif item.origin == "hand" and previewStarted then
                            addError(errors, "view_origin_order", itemPath .. ".origin", "권위 손패 카드는 프리뷰 카드보다 앞에 표시해야 합니다.")
                        end
                        if view.phase == "awaitingOutput"
                            and (item.playable ~= false or item.reasonCode ~= "awaiting_output") then
                            addError(errors, "awaiting_card_not_locked", itemPath, "출력 대기 중인 카드는 awaiting_output으로 잠겨야 합니다.")
                        elseif view.phase == "ended"
                            and (item.playable ~= false or item.reasonCode ~= "battle_ended") then
                            addError(errors, "ended_card_not_locked", itemPath, "종료된 전투의 카드는 battle_ended로 잠겨야 합니다.")
                        end
                    end
                end
            end
        end

        if type(view.selection) ~= "table" then
            addError(errors, "invalid_selection", "$.selection", "selection이 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.selection, {
                count = true,
                mode = true,
                hasMainAction = true,
                canSubmit = true,
                reasonCode = true,
                focusedInstanceId = true,
            }, "$.selection", errors)
            if not isInteger(view.selection.count, 0)
                or (view.selection.mode ~= "pass"
                    and view.selection.mode ~= "chain_pass"
                    and view.selection.mode ~= "action")
                or (view.selection.hasMainAction ~= true and view.selection.hasMainAction ~= false)
                or (view.selection.canSubmit ~= true and view.selection.canSubmit ~= false)
                or type(view.selection.reasonCode) ~= "string" then
                addError(errors, "invalid_selection_value", "$.selection", "선택 표시 값이 올바르지 않습니다.")
            end
            if view.selection.focusedInstanceId ~= nil and not isRuntimeId(view.selection.focusedInstanceId) then
                addError(errors, "invalid_focus", "$.selection.focusedInstanceId", "상세 표시 카드 인스턴스 ID가 올바르지 않습니다.")
            elseif view.phase ~= "selecting" and view.selection.focusedInstanceId ~= nil then
                addError(errors, "locked_view_focus", "$.selection.focusedInstanceId", "출력 대기 또는 종료 View에는 focus를 보존하지 않습니다.")
            end
            if type(view.hand) == "table" and type(view.hand.items) == "table" then
                local selectedCount = 0
                local orders = {}
                local mainActionCount = 0
                local mainActionOrder = nil
                local selectedPlayable = true
                local focusedVisible = view.selection.focusedInstanceId == nil
                for _, item in ipairs(view.hand.items) do
                    if type(item) == "table" and item.instanceId == view.selection.focusedInstanceId then
                        focusedVisible = true
                    end
                    if type(item) == "table" and item.selected == true then
                        selectedCount = selectedCount + 1
                        if isInteger(item.selectionOrder, 1) then
                            orders[item.selectionOrder] = (orders[item.selectionOrder] or 0) + 1
                        end
                        if item.playable ~= true then
                            selectedPlayable = false
                        end

                        local hasChain = false
                        if type(item.mechanisms) == "table" then
                            for _, mechanism in ipairs(item.mechanisms) do
                                if type(mechanism) == "table" and mechanism.id == "chain" then
                                    hasChain = true
                                    break
                                end
                            end
                        end
                        if not hasChain then
                            mainActionCount = mainActionCount + 1
                            mainActionOrder = item.selectionOrder
                        end
                    end
                end
                if view.selection.count ~= selectedCount then
                    addError(errors, "selection_count_mismatch", "$.selection.count", "선택 개수와 손패의 선택 표시가 다릅니다.")
                end
                if not focusedVisible then
                    addError(errors, "focused_card_not_visible", "$.selection.focusedInstanceId", "focus 카드는 현재 표시 카드에 있어야 합니다.")
                end
                for order = 1, selectedCount do
                    if orders[order] ~= 1 then
                        addError(errors, "selection_order_gap", "$.hand.items", "선택 순서는 1부터 중복 없이 이어져야 합니다.")
                        break
                    end
                end

                local expectedHasMainAction = mainActionCount == 1
                local mainActionLast = mainActionCount == 0 or mainActionOrder == selectedCount
                local expectedMode = selectedCount == 0 and "pass"
                    or (expectedHasMainAction and "action" or "chain_pass")
                local expectedCanSubmit = view.locked == false
                    and mainActionCount <= 1
                    and mainActionLast
                    and selectedPlayable
                local expectedReason = "none"
                if view.locked == true then
                    expectedReason = view.phase == "awaitingOutput" and "awaiting_output" or "battle_ended"
                elseif mainActionCount > 1 then
                    expectedReason = "multiple_main_actions"
                elseif not mainActionLast then
                    expectedReason = "main_action_not_last"
                elseif not selectedPlayable then
                    expectedReason = "unplayable_selection"
                end

                if view.selection.hasMainAction ~= expectedHasMainAction then
                    addError(errors, "main_action_summary_mismatch", "$.selection.hasMainAction", "손패 선택에서 계산한 주 행동 여부와 다릅니다.")
                end
                if view.selection.mode ~= expectedMode then
                    addError(errors, "selection_mode_mismatch", "$.selection.mode", "손패 선택에서 계산한 projection mode와 다릅니다.")
                end
                if view.selection.canSubmit ~= expectedCanSubmit then
                    addError(errors, "submit_summary_mismatch", "$.selection.canSubmit", "손패 선택에서 계산한 전송 가능 여부와 다릅니다.")
                end
                if view.selection.reasonCode ~= expectedReason then
                    addError(errors, "selection_reason_mismatch", "$.selection.reasonCode", "손패 선택에서 계산한 사유 코드와 다릅니다.")
                end
            end
        end

        if type(view.zones) ~= "table" then
            addError(errors, "invalid_zones", "$.zones", "zones가 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.zones, {
                deckCount = true,
                usedCount = true,
                discardCount = true,
                removedCount = true,
            }, "$.zones", errors)
            for _, field in ipairs({ "deckCount", "usedCount", "discardCount", "removedCount" }) do
                if not isInteger(view.zones[field], 0) then
                    addError(errors, "invalid_zone_count", "$.zones." .. field, "카드 영역 개수가 올바르지 않습니다.")
                end
            end
        end

        if type(view.lastTurn) ~= "table" then
            addError(errors, "invalid_last_turn", "$.lastTurn", "lastTurn이 테이블이 아닙니다.")
        else
            if view.lastTurn.available == false then
                checkAllowedKeys(view.lastTurn, { available = true }, "$.lastTurn", errors)
            elseif view.lastTurn.available == true then
                checkAllowedKeys(view.lastTurn, {
                    available = true,
                    turnNumber = true,
                    summaries = true,
                    resourceChanges = true,
                }, "$.lastTurn", errors)
                if not isInteger(view.lastTurn.turnNumber, 1) then
                    addError(errors, "invalid_last_turn_number", "$.lastTurn.turnNumber", "직전 공개 턴 번호가 올바르지 않습니다.")
                end
                local summaryCount = getArrayLength(view.lastTurn.summaries, "$.lastTurn.summaries", errors)
                if summaryCount then
                    for index = 1, summaryCount do
                        local item = view.lastTurn.summaries[index]
                        local itemPath = "$.lastTurn.summaries[" .. index .. "]"
                        if type(item) ~= "table" then
                            addError(errors, "invalid_turn_summary", itemPath, "턴 공개 요약이 테이블이 아닙니다.")
                        else
                            checkAllowedKeys(item, {
                                sequence = true,
                                type = true,
                                text = true,
                            }, itemPath, errors)
                            if item.sequence ~= index
                                or not isAsciiId(item.type)
                                or type(item.text) ~= "string"
                                or item.text == "" then
                                addError(errors, "invalid_turn_summary", itemPath, "턴 공개 요약 값이 올바르지 않습니다.")
                            end
                        end
                    end
                end
                validateResourceChanges(view.lastTurn.resourceChanges, "$.lastTurn.resourceChanges", errors)
            else
                addError(errors, "invalid_last_turn_availability", "$.lastTurn.available", "lastTurn.available은 불리언이어야 합니다.")
            end
        end

        if type(view.outcome) ~= "table" then
            addError(errors, "invalid_outcome", "$.outcome", "outcome이 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.outcome, { status = true, label = true }, "$.outcome", errors)
            if view.outcome.status ~= "active" and view.outcome.status ~= "victory" and view.outcome.status ~= "defeat" then
                addError(errors, "invalid_outcome_status", "$.outcome.status", "결과 상태가 올바르지 않습니다.")
            end
            if type(view.outcome.label) ~= "string" or view.outcome.label == "" then
                addError(errors, "invalid_outcome_label", "$.outcome.label", "결과 표시명이 필요합니다.")
            end
            if view.phase == "ended" and view.outcome.status == "active" then
                addError(errors, "ended_outcome_mismatch", "$.outcome.status", "종료 View의 결과는 active일 수 없습니다.")
            elseif view.phase ~= "ended" and view.outcome.status ~= "active" then
                addError(errors, "active_phase_outcome_mismatch", "$.outcome.status", "선택 또는 출력 대기 View의 결과는 active여야 합니다.")
            end
        end
        if type(view.aftermath) == "table" and view.aftermath.active == true then
            if view.phase ~= "ended"
                or type(view.outcome) ~= "table"
                or view.outcome.status ~= "victory" then
                addError(errors, "aftermath_view_mismatch", "$.aftermath", "자유행동 View는 확정된 승리 화면에서만 표시할 수 있습니다.")
            end
        end

        if #errors > 0 then
            return failure(errors)
        end
        return success(nil, nil)
    end

    local arguments = { ... }
    if action == "tokenizeTags" then
        return tokenizeTags(arguments[1], arguments[2], arguments[3])
    elseif action == "buildCardPresentation" then
        local errors = {}
        local card = buildSafeCardSummary(arguments[1], arguments[2], arguments[3] or "$.card", errors)
        if #errors > 0 or card == nil then
            return failure(errors)
        end
        return success("card", card)
    elseif action == "presentationCacheStats" then
        return {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
            cache = {
                entries = presentationCacheSize,
                maxEntries = PRESENTATION_CACHE_MAX_ENTRIES,
                hits = presentationStats.hits,
                misses = presentationStats.misses,
                evictions = presentationStats.evictions,
            },
        }
    elseif action == "clearPresentationCache" then
        local removed = presentationCacheSize
        presentationCache = {}
        presentationCacheSize = 0
        return success("removed", removed)
    elseif action == "validateBattleView" then
        return validateBattleView(arguments[1])
    elseif action == "buildBattleView" then
        local built = buildBattleView(arguments[1], arguments[2], arguments[3])
        if type(built) ~= "table" or built.ok ~= true then
            return built
        end
        local validation = validateBattleView(built.view)
        if not validation.ok then
            return validation
        end
        return built
    end

    local errors = {}
    addError(errors, "unknown_action", "$", "지원하지 않는 View 작업입니다: " .. tostring(action))
    return failure(errors)
    end
end)()
