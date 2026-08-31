(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local HISTORY_KIND = "battleHistory"
    local CONTEXT_KIND = "battleHistoryContext"
    local MAX_TURNS = 12

    local VALID_SIDE = {
        player = true,
        character = true,
    }

    local VALID_STATUS = {
        active = true,
        victory = true,
        defeat = true,
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

    local function success(fields)
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

    local function isAsciiId(value)
        return type(value) == "string"
            and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
    end

    local function isRuntimeId(value)
        return type(value) == "string"
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
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
            if key > maximum then maximum = key end
        end
        return count == maximum
    end

    local function cloneData(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "전투 이력에는 유한한 숫자만 저장할 수 있습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" or getmetatable(value) ~= nil then
            return nil, makeError("unsupported_type", path, "전투 이력에는 JSON-safe 일반 테이블만 저장할 수 있습니다.")
        end
        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "전투 이력에는 순환 참조를 저장할 수 없습니다.")
        end
        active[value] = true
        local copy = {}
        for key, item in pairs(value) do
            local keyType = type(key)
            if keyType ~= "string" and not isInteger(key, 1) then
                active[value] = nil
                return nil, makeError("invalid_key", path, "전투 이력 키는 문자열 또는 양의 배열 인덱스여야 합니다.")
            end
            local childPath = keyType == "number"
                and (path .. "[" .. key .. "]")
                or (path .. "." .. tostring(key))
            local itemCopy, itemError = cloneData(item, childPath, active)
            if itemError then
                active[value] = nil
                return nil, itemError
            end
            copy[key] = itemCopy
        end
        active[value] = nil
        return copy, nil
    end

    local function dataEqual(left, right, seen)
        if type(left) ~= type(right) then return false end
        if type(left) ~= "table" then return left == right end
        if getmetatable(left) ~= nil or getmetatable(right) ~= nil then return false end
        seen = seen or {}
        if seen[left] ~= nil then return seen[left] == right end
        seen[left] = right
        for key, value in pairs(left) do
            if not dataEqual(value, right[key], seen) then return false end
        end
        for key in pairs(right) do
            if left[key] == nil then return false end
        end
        return true
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function emptyHistory()
        return {
            schemaVersion = SCHEMA_VERSION,
            kind = HISTORY_KIND,
            turns = {},
        }
    end

    local function addError(errors, code, path, message)
        errors[#errors + 1] = makeError(code, path, message)
    end

    local function validateSnapshot(value, path, errors, staticData, allowStatus)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            addError(errors, "invalid_history_snapshot", path, "턴 상태 스냅샷이 일반 객체가 아닙니다.")
            return
        end
        if not isFinite(value.stealth) then
            addError(errors, "invalid_history_stealth", path .. ".stealth", "기록된 은폐가 유한한 숫자가 아닙니다.")
        end
        if not isFinite(value.resistance) then
            addError(errors, "invalid_history_resistance", path .. ".resistance", "기록된 저항이 유한한 숫자가 아닙니다.")
        end
        if not isAsciiId(value.mood) then
            addError(errors, "invalid_history_mood", path .. ".mood", "기록된 무드 ID가 올바르지 않습니다.")
        elseif type(staticData) == "table"
            and type(staticData.registry) == "table"
            and type(staticData.registry.moods) == "table"
            and staticData.registry.moods[value.mood] == nil then
            addError(errors, "unknown_history_mood", path .. ".mood", "기록된 무드를 정적 레지스트리에서 찾을 수 없습니다.")
        end
        if allowStatus then
            if not VALID_STATUS[value.status] then
                addError(errors, "invalid_history_status", path .. ".status", "기록된 전투 상태가 올바르지 않습니다.")
            end
        elseif value.status ~= nil then
            addError(errors, "unexpected_history_status", path .. ".status", "턴 시작 스냅샷에는 전투 상태를 저장하지 않습니다.")
        end
    end

    local function validateCardRecord(record, side, path, errors, staticData)
        if type(record) ~= "table" or getmetatable(record) ~= nil then
            addError(errors, "invalid_history_card", path, "카드 이력 항목이 일반 객체가 아닙니다.")
            return
        end
        if not isAsciiId(record.cardId) then
            addError(errors, "invalid_history_card_id", path .. ".cardId", "카드 이력 ID가 올바르지 않습니다.")
        end
        if not isRuntimeId(record.instanceId) then
            addError(errors, "invalid_history_instance_id", path .. ".instanceId", "카드 이력 인스턴스 ID가 올바르지 않습니다.")
        end
        if not isDenseArray(record.roles) or #record.roles < 1 or #record.roles > 2 or (side == "character" and #record.roles ~= 1) then
            addError(errors, "invalid_history_roles", path .. ".roles", "카드 이력 역할 태그 목록이 올바르지 않습니다.")
        else
            local seenRoles = {}
            for roleIndex, role in ipairs(record.roles) do
                local definition = type(staticData) == "table"
                    and type(staticData.registry) == "table"
                    and type(staticData.registry.roles) == "table"
                    and staticData.registry.roles[role]
                    or nil
                if not isAsciiId(role) or seenRoles[role] or (definition ~= nil and definition.owner ~= side) then
                    addError(errors, "invalid_history_role", path .. ".roles[" .. roleIndex .. "]", "카드 이력 역할 태그가 올바르지 않습니다.")
                end
                seenRoles[role] = true
            end
        end
        for _, field in ipairs({ "selected", "declared", "resolved" }) do
            if type(record[field]) ~= "boolean" then
                addError(errors, "invalid_history_card_flag", path .. "." .. field, "카드 이력 상태 표시는 불리언이어야 합니다.")
            end
        end
        if record.declarationSequence ~= nil and not isInteger(record.declarationSequence, 1) then
            addError(errors, "invalid_history_sequence", path .. ".declarationSequence", "선언 사건 순번이 올바르지 않습니다.")
        end
        if record.resolutionSequence ~= nil and not isInteger(record.resolutionSequence, 1) then
            addError(errors, "invalid_history_sequence", path .. ".resolutionSequence", "해결 사건 순번이 올바르지 않습니다.")
        end
        if record.resolved == true and record.resolutionSequence == nil then
            addError(errors, "missing_history_resolution", path .. ".resolutionSequence", "해결된 카드에는 해결 사건 순번이 필요합니다.")
        end
        if record.finalStealthCost ~= nil and not isFinite(record.finalStealthCost) then
            addError(errors, "invalid_history_cost", path .. ".finalStealthCost", "최종 은폐 비용이 유한한 숫자가 아닙니다.")
        end
        if record.finalResistanceDamage ~= nil and not isFinite(record.finalResistanceDamage) then
            addError(errors, "invalid_history_damage", path .. ".finalResistanceDamage", "최종 저항 피해가 유한한 숫자가 아닙니다.")
        end

        local card = type(staticData) == "table"
            and type(staticData.cards) == "table"
            and staticData.cards[record.cardId]
            or nil
        if type(staticData) == "table" and type(staticData.cards) == "table" then
            if type(card) ~= "table" then
                addError(errors, "unknown_history_card", path .. ".cardId", "카드 이력의 정적 카드 정의를 찾을 수 없습니다.")
            elseif card.owner ~= side then
                addError(errors, "history_card_owner_mismatch", path .. ".cardId", "카드 이력 진영과 정적 카드 소유자가 다릅니다.")
            elseif not dataEqual(card.roles, record.roles) then
                addError(errors, "history_card_role_mismatch", path .. ".roles", "카드 이력 역할 태그와 정적 카드 정의가 다릅니다.")
            end
        end
    end

    local function validateRoleCounts(value, path, errors, staticData)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            addError(errors, "invalid_history_role_counts", path, "역할 태그 집계가 일반 객체가 아닙니다.")
            return
        end
        for roleId, count in pairs(value) do
            if not isAsciiId(roleId) then
                addError(errors, "invalid_history_role", path, "집계 역할 태그 ID가 올바르지 않습니다.")
            elseif not isInteger(count, 0) then
                addError(errors, "invalid_history_role_count", path .. "." .. tostring(roleId), "역할 태그 횟수는 0 이상의 정수여야 합니다.")
            elseif type(staticData) == "table"
                and type(staticData.registry) == "table"
                and type(staticData.registry.roles) == "table"
                and staticData.registry.roles[roleId] == nil then
                addError(errors, "unknown_history_role", path .. "." .. roleId, "집계 역할 태그를 정적 레지스트리에서 찾을 수 없습니다.")
            end
        end
    end

    local function validatePublicResult(value, path, errors)
        if value == nil then return end
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            addError(errors, "invalid_history_public_result", path, "공개 전투 로그 묶음이 일반 객체가 아닙니다.")
            return
        end
        if value.schemaVersion ~= SCHEMA_VERSION or not isDenseArray(value.events) then
            addError(errors, "invalid_history_public_result", path, "공개 전투 로그 사건 묶음이 올바르지 않습니다.")
        end
    end

    local function countCards(cards, field)
        local counts = {}
        for _, card in ipairs(cards or {}) do
            if card[field] == true then
                for _, role in ipairs(card.roles or {}) do
                    counts[role] = (counts[role] or 0) + 1
                end
            end
        end
        return counts
    end

    local function validateTurnEntry(entry, index, errors, staticData)
        local path = "$.turns[" .. index .. "]"
        if type(entry) ~= "table" or getmetatable(entry) ~= nil then
            addError(errors, "invalid_history_turn", path, "턴 이력 항목이 일반 객체가 아닙니다.")
            return
        end
        if entry.turnNumber ~= index then
            addError(errors, "history_turn_sequence_mismatch", path .. ".turnNumber", "턴 이력 번호가 배열 순서와 다릅니다.")
        end
        if not isRuntimeId(entry.turnId) then
            addError(errors, "invalid_history_turn_id", path .. ".turnId", "턴 이력 ID가 올바르지 않습니다.")
        end
        validateSnapshot(entry.start, path .. ".start", errors, staticData, false)
        validateSnapshot(entry.finish, path .. ".finish", errors, staticData, true)
        local startMood = type(entry.start) == "table" and entry.start.mood or nil
        local finishMood = type(entry.finish) == "table" and entry.finish.mood or nil

        if type(entry.mood) ~= "table" or getmetatable(entry.mood) ~= nil then
            addError(errors, "invalid_history_mood_result", path .. ".mood", "무드 판정 이력이 일반 객체가 아닙니다.")
        else
            if entry.mood.before ~= startMood or entry.mood.after ~= finishMood then
                addError(errors, "history_mood_snapshot_mismatch", path .. ".mood", "무드 판정과 턴 시작·종료 스냅샷이 다릅니다.")
            end
            if type(entry.mood.applied) ~= "boolean" then
                addError(errors, "invalid_history_mood_applied", path .. ".mood.applied", "무드 변경 여부는 불리언이어야 합니다.")
            end
            if not isInteger(entry.mood.forcedCount, 0) then
                addError(errors, "invalid_history_forced_mood_count", path .. ".mood.forcedCount", "강제 무드 요청 수가 올바르지 않습니다.")
            end
            if type(entry.mood.forceCancelled) ~= "boolean" then
                addError(errors, "invalid_history_force_cancelled", path .. ".mood.forceCancelled", "강제 무드 상쇄 여부는 불리언이어야 합니다.")
            end
            if not isAsciiId(entry.mood.resolution) then
                addError(errors, "invalid_history_mood_resolution", path .. ".mood.resolution", "무드 판정 종류가 올바르지 않습니다.")
            end
        end

        if type(entry.cards) ~= "table" then
            addError(errors, "invalid_history_cards", path .. ".cards", "턴 카드 이력이 객체가 아닙니다.")
        else
            for _, side in ipairs({ "player", "character" }) do
                local cards = entry.cards[side]
                if not isDenseArray(cards) then
                    addError(errors, "invalid_history_cards", path .. ".cards." .. side, "진영별 카드 이력이 연속 배열이 아닙니다.")
                else
                    local seen = {}
                    for cardIndex, card in ipairs(cards) do
                        validateCardRecord(card, side, path .. ".cards." .. side .. "[" .. cardIndex .. "]", errors, staticData)
                        if type(card) == "table" and isRuntimeId(card.instanceId) then
                            if seen[card.instanceId] then
                                addError(errors, "duplicate_history_card", path .. ".cards." .. side .. "[" .. cardIndex .. "].instanceId", "같은 카드 인스턴스가 한 턴 이력에 중복되었습니다.")
                            end
                            seen[card.instanceId] = true
                        end
                    end
                end
            end
        end

        if type(entry.roleCounts) ~= "table" then
            addError(errors, "invalid_history_role_counts", path .. ".roleCounts", "턴 역할 태그 집계가 객체가 아닙니다.")
        else
            for _, side in ipairs({ "player", "character" }) do
                local sideCounts = entry.roleCounts[side]
                if type(sideCounts) ~= "table" then
                    addError(errors, "invalid_history_role_counts", path .. ".roleCounts." .. side, "진영별 역할 태그 집계가 객체가 아닙니다.")
                else
                    validateRoleCounts(sideCounts.declared, path .. ".roleCounts." .. side .. ".declared", errors, staticData)
                    validateRoleCounts(sideCounts.resolved, path .. ".roleCounts." .. side .. ".resolved", errors, staticData)
                    if type(entry.cards) == "table" and isDenseArray(entry.cards[side]) then
                        if not dataEqual(sideCounts.declared, countCards(entry.cards[side], "declared")) then
                            addError(errors, "history_declared_count_mismatch", path .. ".roleCounts." .. side .. ".declared", "선언 역할 집계가 카드 이력과 다릅니다.")
                        end
                        if not dataEqual(sideCounts.resolved, countCards(entry.cards[side], "resolved")) then
                            addError(errors, "history_resolved_count_mismatch", path .. ".roleCounts." .. side .. ".resolved", "해결 역할 집계가 카드 이력과 다릅니다.")
                        end
                    end
                end
            end
        end
        validatePublicResult(entry.publicResult, path .. ".publicResult", errors)
    end

    local function validateHistory(history, state, staticInput)
        local errors = {}
        local staticData = normalizeStaticData(staticInput)
        if type(history) ~= "table" or getmetatable(history) ~= nil then
            return failure({ makeError("invalid_battle_history", "$", "전투 이력이 일반 객체가 아닙니다.") })
        end
        if history.schemaVersion ~= SCHEMA_VERSION or history.kind ~= HISTORY_KIND then
            addError(errors, "invalid_battle_history_schema", "$", "지원하지 않는 전투 이력 형식입니다.")
        end
        if not isDenseArray(history.turns) then
            addError(errors, "invalid_battle_history_turns", "$.turns", "전투 턴 이력이 연속 배열이 아닙니다.")
        elseif #history.turns > MAX_TURNS then
            addError(errors, "battle_history_too_long", "$.turns", "전투 이력은 최대 12턴까지만 저장할 수 있습니다.")
        else
            local seenTurnIds = {}
            for index, entry in ipairs(history.turns) do
                validateTurnEntry(entry, index, errors, staticData)
                if type(entry) == "table" and isRuntimeId(entry.turnId) then
                    if seenTurnIds[entry.turnId] then
                        addError(errors, "duplicate_history_turn_id", "$.turns[" .. index .. "].turnId", "턴 이력 ID가 중복되었습니다.")
                    end
                    seenTurnIds[entry.turnId] = true
                end
                if index > 1 then
                    local previous = history.turns[index - 1]
                    if type(previous) == "table"
                        and type(previous.finish) == "table"
                        and type(entry) == "table"
                        and type(entry.start) == "table" then
                        if previous.finish.stealth ~= entry.start.stealth
                            or previous.finish.resistance ~= entry.start.resistance
                            or previous.finish.mood ~= entry.start.mood then
                            addError(errors, "battle_history_discontinuity", "$.turns[" .. index .. "].start", "이전 턴 종료 상태와 다음 턴 시작 상태가 이어지지 않습니다.")
                        end
                    end
                end
            end
        end

        if type(state) == "table" and isDenseArray(history.turns) then
            local count = #history.turns
            local expectedCount = nil
            if state.status == "active" and isInteger(state.turnNumber, 1) then
                expectedCount = state.turnNumber - 1
            elseif (state.status == "victory" or state.status == "defeat") and isInteger(state.turnNumber, 1) then
                expectedCount = state.turnNumber
            end
            if expectedCount ~= nil and count ~= expectedCount then
                addError(errors, "battle_history_turn_count_mismatch", "$.turns", "전투 상태와 완료된 턴 이력 수가 다릅니다.")
            end
            local last = history.turns[count]
            if count == 0 then
                if state.lastCommittedTurnId ~= nil then
                    addError(errors, "battle_history_missing_last_turn", "$.turns", "마지막 확정 턴 ID가 있지만 전투 이력이 비어 있습니다.")
                end
            elseif type(last) == "table" and state.lastCommittedTurnId ~= last.turnId then
                addError(errors, "battle_history_last_turn_mismatch", "$.turns[" .. count .. "].turnId", "전투 이력의 마지막 턴과 권위 상태의 마지막 확정 턴이 다릅니다.")
            end
            if type(last) == "table" and type(last.finish) == "table" then
                local currentStealth = type(state.player) == "table" and state.player.stealth or nil
                local currentResistance = type(state.character) == "table" and state.character.resistance or nil
                local currentMood = type(state.character) == "table" and state.character.mood or nil
                local receipt = state.status == "active" and state.turnStartReceipt or nil
                local baseline = type(receipt) == "table" and receipt.baseline or nil
                if isInteger(state.turnNumber, 1)
                    and count == state.turnNumber - 1
                    and state.lastCommittedTurnId == last.turnId
                    and type(receipt) == "table"
                    and receipt.turnNumber == state.turnNumber
                    and type(baseline) == "table"
                    and isFinite(baseline.stealth)
                    and isFinite(baseline.resistance)
                    and type(baseline.mood) == "string" then
                    currentStealth = baseline.stealth
                    currentResistance = baseline.resistance
                    currentMood = baseline.mood
                end
                if type(state.player) == "table" and currentStealth ~= last.finish.stealth then
                    addError(errors, "battle_history_stealth_mismatch", "$.turns[" .. count .. "].finish.stealth", "마지막 이력의 은폐가 현재 상태와 다릅니다.")
                end
                if type(state.character) == "table"
                    and (currentResistance ~= last.finish.resistance
                        or currentMood ~= last.finish.mood) then
                    addError(errors, "battle_history_character_mismatch", "$.turns[" .. count .. "].finish", "마지막 이력의 저항 또는 무드가 현재 상태와 다릅니다.")
                end
                if state.status ~= last.finish.status then
                    addError(errors, "battle_history_status_mismatch", "$.turns[" .. count .. "].finish.status", "마지막 이력의 전투 상태가 현재 상태와 다릅니다.")
                end
            end
        end

        if #errors > 0 then return failure(errors) end
        local copy, copyError = cloneData(history, "$", {})
        if copyError then return failure({ copyError }) end
        return success({ history = copy })
    end

    local function findInstance(state, instanceId)
        for _, instance in ipairs(type(state) == "table" and type(state.cardInstances) == "table" and state.cardInstances or {}) do
            if type(instance) == "table" and instance.instanceId == instanceId then
                return instance
            end
        end
        return nil
    end

    local function selectedSet(selected)
        local set = {}
        for _, instanceId in ipairs(type(selected) == "table" and selected or {}) do
            set[instanceId] = true
        end
        return set
    end

    local function buildCardRecords(beforeState, events, selectedCards, staticData)
        local records = { player = {}, character = {} }
        local byInstance = { player = {}, character = {} }
        local selected = {
            player = selectedSet(type(selectedCards) == "table" and selectedCards.player or nil),
            character = selectedSet(type(selectedCards) == "table" and selectedCards.character or nil),
        }

        local function ensureRecord(side, cardId, instanceId)
            if not VALID_SIDE[side] or not isAsciiId(cardId) or not isRuntimeId(instanceId) then
                return nil
            end
            local existing = byInstance[side][instanceId]
            if existing then return existing end
            local card = type(staticData) == "table"
                and type(staticData.cards) == "table"
                and staticData.cards[cardId]
                or nil
            if type(card) ~= "table" or card.owner ~= side or not isDenseArray(card.roles) then
                return nil
            end
            local roles = {}
            for index, role in ipairs(card.roles) do roles[index] = role end
            local record = {
                cardId = cardId,
                instanceId = instanceId,
                roles = roles,
                selected = selected[side][instanceId] == true,
                declared = false,
                resolved = false,
            }
            records[side][#records[side] + 1] = record
            byInstance[side][instanceId] = record
            return record
        end

        for _, event in ipairs(type(events) == "table" and events or {}) do
            local source = type(event) == "table" and event.source or nil
            local side = type(event) == "table" and (event.side or (type(source) == "table" and source.side)) or nil
            if type(source) == "table" and source.kind == "card" and VALID_SIDE[side] then
                local record = ensureRecord(side, source.id, source.instanceId)
                if record and event.type == "card_declared" then
                    record.declared = true
                    record.declarationSequence = event.sequence
                    local payload = type(event.payload) == "table" and event.payload or nil
                    if payload and isFinite(payload.finalStealthCost) then
                        record.finalStealthCost = payload.finalStealthCost
                    end
                elseif record and event.type == "card_resolved" then
                    record.resolved = true
                    record.resolutionSequence = event.sequence
                    local payload = type(event.payload) == "table" and event.payload or nil
                    if payload and isFinite(payload.finalResistanceDamage) then
                        record.finalResistanceDamage = payload.finalResistanceDamage
                    end
                end
            end
        end

        for _, side in ipairs({ "player", "character" }) do
            local selectedIds = type(selectedCards) == "table" and selectedCards[side] or nil
            for _, instanceId in ipairs(type(selectedIds) == "table" and selectedIds or {}) do
                if byInstance[side][instanceId] == nil then
                    local instance = findInstance(beforeState, instanceId)
                    if type(instance) == "table" then
                        ensureRecord(side, instance.cardId, instance.instanceId)
                    end
                end
            end
            table.sort(records[side], function(left, right)
                local leftSequence = left.declarationSequence or (100000 + (left.resolutionSequence or 0))
                local rightSequence = right.declarationSequence or (100000 + (right.resolutionSequence or 0))
                if leftSequence ~= rightSequence then return leftSequence < rightSequence end
                return left.instanceId < right.instanceId
            end)
        end
        return records
    end

    local function appendResolvedTurn(beforeState, afterState, spec, staticInput)
        local staticData = normalizeStaticData(staticInput)
        if type(beforeState) ~= "table" or type(afterState) ~= "table" or type(spec) ~= "table" then
            return failure({ makeError("invalid_append_input", "$", "턴 이력 추가 입력이 올바르지 않습니다.") })
        end
        local beforeValidation = validateHistory(beforeState.history, beforeState, staticData)
        if not beforeValidation.ok then return beforeValidation end
        if not dataEqual(beforeState.history, afterState.history) then
            return failure({ makeError("history_changed_before_append", "$.afterState.history", "턴 해결 전에 전투 이력이 임의로 변경되었습니다.") })
        end
        if not isInteger(spec.turnNumber, 1)
            or spec.turnNumber ~= #beforeState.history.turns + 1
            or not isRuntimeId(spec.turnId)
            or not isDenseArray(spec.events) then
            return failure({ makeError("invalid_turn_history_spec", "$.spec", "턴 이력 추가 사양이 현재 전투 순서와 맞지 않습니다.") })
        end

        local stateCopy, stateError = cloneData(afterState, "$.afterState", {})
        if stateError then return failure({ stateError }) end
        local historyCopy, historyError = cloneData(beforeState.history, "$.history", {})
        if historyError then return failure({ historyError }) end
        local cards = buildCardRecords(beforeState, spec.events, spec.selectedCards, staticData)
        local startCopy, startError = cloneData(spec.start, "$.spec.start", {})
        if startError then return failure({ startError }) end
        local finishCopy, finishError = cloneData(spec.finish, "$.spec.finish", {})
        if finishError then return failure({ finishError }) end
        local moodCopy, moodError = cloneData(spec.mood, "$.spec.mood", {})
        if moodError then return failure({ moodError }) end

        local entry = {
            turnNumber = spec.turnNumber,
            turnId = spec.turnId,
            start = startCopy,
            finish = finishCopy,
            mood = moodCopy,
            cards = cards,
            roleCounts = {
                player = {
                    declared = countCards(cards.player, "declared"),
                    resolved = countCards(cards.player, "resolved"),
                },
                character = {
                    declared = countCards(cards.character, "declared"),
                    resolved = countCards(cards.character, "resolved"),
                },
            },
        }
        historyCopy.turns[#historyCopy.turns + 1] = entry
        stateCopy.history = historyCopy

        local validation = validateHistory(historyCopy, stateCopy, staticData)
        if not validation.ok then return validation end
        local entryCopy, entryError = cloneData(entry, "$.entry", {})
        if entryError then return failure({ entryError }) end
        return success({ state = stateCopy, history = validation.history, entry = entryCopy })
    end

    local function attachPublicResult(state, turnId, publicResult, staticInput)
        local staticData = normalizeStaticData(staticInput)
        if type(state) ~= "table" or not isRuntimeId(turnId) then
            return failure({ makeError("invalid_public_log_input", "$", "공개 턴 로그 연결 입력이 올바르지 않습니다.") })
        end
        local validation = validateHistory(state.history, state, staticData)
        if not validation.ok then return validation end
        local eventErrors = {}
        validatePublicResult(publicResult, "$.publicResult", eventErrors)
        if #eventErrors > 0 then return failure(eventErrors) end

        local stateCopy, stateError = cloneData(state, "$.state", {})
        if stateError then return failure({ stateError }) end
        local turns = stateCopy.history.turns
        local entry = turns[#turns]
        if type(entry) ~= "table" or entry.turnId ~= turnId then
            return failure({ makeError("public_log_turn_mismatch", "$.state.history.turns", "공개 로그를 연결할 마지막 턴을 찾을 수 없습니다.") })
        end
        if entry.publicResult ~= nil and not dataEqual(entry.publicResult, publicResult) then
            return failure({ makeError("public_log_conflict", "$.state.history.turns", "같은 턴에 서로 다른 공개 로그를 연결할 수 없습니다.") })
        end
        local publicCopy, publicError = cloneData(publicResult, "$.publicResult", {})
        if publicError then return failure({ publicError }) end
        entry.publicResult = publicCopy
        local outputValidation = validateHistory(stateCopy.history, stateCopy, staticData)
        if not outputValidation.ok then return outputValidation end
        return success({ state = stateCopy, history = outputValidation.history })
    end

    local function copyCounts(source)
        local copy = {}
        for key, value in pairs(type(source) == "table" and source or {}) do
            copy[key] = value
        end
        return copy
    end

    local function addCounts(target, source)
        for key, value in pairs(type(source) == "table" and source or {}) do
            target[key] = (target[key] or 0) + value
        end
    end

    local function cardContextRecord(record)
        local roles = {}
        for index, role in ipairs(record.roles) do roles[index] = role end
        return {
            cardId = record.cardId,
            instanceId = record.instanceId,
            roles = roles,
            selected = record.selected,
            declared = record.declared,
            resolved = record.resolved,
        }
    end

    local function turnContext(entry)
        local value = {
            turnNumber = entry.turnNumber,
            turnId = entry.turnId,
            startMood = entry.start.mood,
            endMood = entry.finish.mood,
            status = entry.finish.status,
            start = {
                stealth = entry.start.stealth,
                resistance = entry.start.resistance,
                mood = entry.start.mood,
            },
            finish = {
                stealth = entry.finish.stealth,
                resistance = entry.finish.resistance,
                mood = entry.finish.mood,
                status = entry.finish.status,
            },
            mood = {
                before = entry.mood.before,
                after = entry.mood.after,
                applied = entry.mood.applied,
                forcedCount = entry.mood.forcedCount,
                forceCancelled = entry.mood.forceCancelled,
                resolution = entry.mood.resolution,
                tokensBefore = copyCounts(entry.mood.tokensBefore),
                tokensAfter = copyCounts(entry.mood.tokensAfter),
            },
            playerCards = {},
            characterCards = {},
            playerRoles = {},
            characterRoles = {},
        }
        if entry.mood.targetMood ~= nil then value.mood.targetMood = entry.mood.targetMood end
        if type(entry.mood.tiedMoods) == "table" then
            value.mood.tiedMoods = {}
            for index, moodId in ipairs(entry.mood.tiedMoods) do
                value.mood.tiedMoods[index] = moodId
            end
        end
        for _, side in ipairs({ "player", "character" }) do
            local outputCards = side == "player" and value.playerCards or value.characterCards
            local outputRoles = side == "player" and value.playerRoles or value.characterRoles
            for _, record in ipairs(entry.cards[side]) do
                outputCards[#outputCards + 1] = cardContextRecord(record)
                if record.resolved then
                    for _, role in ipairs(record.roles) do outputRoles[#outputRoles + 1] = role end
                end
            end
        end
        return value
    end

    local function buildContext(history)
        local validation = validateHistory(history, nil, nil)
        if not validation.ok then return validation end
        local turns = validation.history.turns
        local context = {
            schemaVersion = SCHEMA_VERSION,
            kind = CONTEXT_KIND,
            completedTurns = #turns,
            turns = {},
            windows = {},
            player = {
                declaredRoleCounts = {},
                resolvedRoleCounts = {},
            },
            character = {
                declaredRoleCounts = {},
                resolvedRoleCounts = {},
            },
        }

        for index, entry in ipairs(turns) do
            context.turns[index] = turnContext(entry)
            for _, side in ipairs({ "player", "character" }) do
                addCounts(context[side].declaredRoleCounts, entry.roleCounts[side].declared)
                addCounts(context[side].resolvedRoleCounts, entry.roleCounts[side].resolved)
                for _, card in ipairs(entry.cards[side]) do
                    if card.declared then context[side].lastDeclaredRoles = cardContextRecord(card).roles end
                    if card.resolved then context[side].lastResolvedRoles = cardContextRecord(card).roles end
                end
            end
        end
        if #turns > 0 then
            context.previousTurn = turnContext(turns[#turns])
        end

        for window = 1, MAX_TURNS do
            local availableTurns = math.min(window, #turns)
            local windowValue = {
                requestedTurns = window,
                availableTurns = availableTurns,
                player = { declaredRoleCounts = {}, resolvedRoleCounts = {} },
                character = { declaredRoleCounts = {}, resolvedRoleCounts = {} },
            }
            local first = math.max(1, #turns - window + 1)
            for index = first, #turns do
                local entry = turns[index]
                for _, side in ipairs({ "player", "character" }) do
                    addCounts(windowValue[side].declaredRoleCounts, entry.roleCounts[side].declared)
                    addCounts(windowValue[side].resolvedRoleCounts, entry.roleCounts[side].resolved)
                end
            end
            context.windows[window] = windowValue
        end
        return success({ context = context })
    end

    local function validateContext(value)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            return failure({ makeError("invalid_history_context", "$", "전투 이력 컨텍스트가 일반 객체가 아닙니다.") })
        end
        local errors = {}
        if value.schemaVersion ~= SCHEMA_VERSION or value.kind ~= CONTEXT_KIND then
            addError(errors, "invalid_history_context_schema", "$", "지원하지 않는 전투 이력 컨텍스트입니다.")
        end
        if not isInteger(value.completedTurns, 0) then
            addError(errors, "invalid_history_context_turns", "$.completedTurns", "완료 턴 수가 올바르지 않습니다.")
        end
        if not isDenseArray(value.turns) or not isDenseArray(value.windows) then
            addError(errors, "invalid_history_context_arrays", "$", "컨텍스트 턴 또는 기간 집계가 연속 배열이 아닙니다.")
        elseif #value.turns ~= value.completedTurns or #value.windows ~= MAX_TURNS then
            addError(errors, "history_context_count_mismatch", "$", "컨텍스트 완료 턴 수 또는 기간 창 개수가 다릅니다.")
        else
            for window = 1, MAX_TURNS do
                local current = value.windows[window]
                if type(current) ~= "table"
                    or current.requestedTurns ~= window
                    or current.availableTurns ~= math.min(window, value.completedTurns) then
                    addError(errors, "invalid_history_window", "$.windows[" .. window .. "]", "기간 창의 요청·가용 턴 수가 올바르지 않습니다.")
                else
                    for _, side in ipairs({ "player", "character" }) do
                        local sideValue = current[side]
                        if type(sideValue) ~= "table"
                            or type(sideValue.declaredRoleCounts) ~= "table"
                            or type(sideValue.resolvedRoleCounts) ~= "table" then
                            addError(errors, "invalid_history_window_side", "$.windows[" .. window .. "]." .. side, "기간 창의 진영별 태그 집계가 올바르지 않습니다.")
                        end
                    end
                end
            end
        end
        for _, side in ipairs({ "player", "character" }) do
            if type(value[side]) ~= "table"
                or type(value[side].declaredRoleCounts) ~= "table"
                or type(value[side].resolvedRoleCounts) ~= "table" then
                addError(errors, "invalid_history_context_side", "$." .. side, "진영별 이력 집계가 올바르지 않습니다.")
            end
        end
        if #errors > 0 then return failure(errors) end
        return success({ valid = true })
    end

    local function numberText(value)
        if type(value) ~= "number" then return tostring(value) end
        if value % 1 == 0 then return string.format("%.0f", value) end
        return tostring(value)
    end

    local function moodLabel(staticData, moodId)
        local mood = type(staticData) == "table"
            and type(staticData.registry) == "table"
            and type(staticData.registry.moods) == "table"
            and staticData.registry.moods[moodId]
            or nil
        return type(mood) == "table" and mood.label or tostring(moodId)
    end

    local function cardName(staticData, cardId)
        local card = type(staticData) == "table"
            and type(staticData.cards) == "table"
            and staticData.cards[cardId]
            or nil
        return type(card) == "table" and card.name or tostring(cardId)
    end

    local function roleLabel(staticData, roleId)
        local role = type(staticData) == "table"
            and type(staticData.registry) == "table"
            and type(staticData.registry.roles) == "table"
            and staticData.registry.roles[roleId]
            or nil
        return type(role) == "table" and role.label or tostring(roleId)
    end

    local function roleLabels(staticData, roles)
        local labels = {}
        for index, roleId in ipairs(roles or {}) do labels[index] = roleLabel(staticData, roleId) end
        return table.concat(labels, "·")
    end

    local EFFECT_TEXT = {
        pay_stealth_cost = "은폐 비용",
        lose_stealth = "은폐 감소",
        recover_stealth = "은폐 회복",
        damage_resistance = "저항 피해",
        recover_resistance = "저항 회복",
    }

    local EFFECT_SOURCE_COLLECTIONS = {
        card = "cards",
        plan = "cards",
        trait = "traits",
        perk = "perks",
    }

    local EFFECT_SOURCE_LABELS = {
        card = "카드",
        plan = "계획",
        trait = "특징",
        perk = "퍽",
        system = "상태 효과",
    }

    local SYSTEM_EFFECT_NAMES = {
        mood_state = "무드 효과",
    }

    local function effectSourceText(staticData, source)
        if type(source) ~= "table" or not isAsciiId(source.kind) or not isAsciiId(source.id) then
            return nil
        end
        local name = source.kind == "system" and SYSTEM_EFFECT_NAMES[source.id] or nil
        local collectionName = EFFECT_SOURCE_COLLECTIONS[source.kind]
        local definition = collectionName and type(staticData) == "table"
            and type(staticData[collectionName]) == "table"
            and staticData[collectionName][source.id]
            or nil
        if name == nil and type(definition) == "table" then name = definition.name end
        local label = EFFECT_SOURCE_LABELS[source.kind]
        if type(label) ~= "string" or type(name) ~= "string" or name == "" then return nil end
        return label .. " 「" .. name .. "」"
    end

    local function validatePublicView(view)
        local errors = {}
        if type(view) ~= "table" or getmetatable(view) ~= nil then
            return failure({ makeError("invalid_battle_log_view", "$", "상세 전투 로그 View가 일반 객체가 아닙니다.") })
        end
        local allowedViewKeys = {
            available = true,
            turnCount = true,
            entries = true,
        }
        for key in pairs(view) do
            if type(key) ~= "string" or allowedViewKeys[key] ~= true then
                addError(errors, "unknown_battle_log_view_field", "$", "상세 전투 로그 View에 허용되지 않은 필드가 있습니다.")
            end
        end
        if type(view.available) ~= "boolean" then
            addError(errors, "invalid_battle_log_availability", "$.available", "상세 전투 로그 사용 가능 여부는 불리언이어야 합니다.")
        end
        if not isInteger(view.turnCount, 0) or view.turnCount > MAX_TURNS then
            addError(errors, "invalid_battle_log_turn_count", "$.turnCount", "상세 전투 로그 턴 수가 올바르지 않습니다.")
        end
        if not isDenseArray(view.entries) then
            addError(errors, "invalid_battle_log_entries", "$.entries", "상세 전투 로그 항목이 연속 배열이 아닙니다.")
        else
            if view.available == false and (view.turnCount ~= 0 or #view.entries ~= 0) then
                addError(errors, "unavailable_battle_log_has_content", "$", "사용할 수 없는 상세 전투 로그에는 턴과 항목이 없어야 합니다.")
            elseif view.available == true and (not isInteger(view.turnCount, 1) or #view.entries == 0) then
                addError(errors, "available_battle_log_missing_content", "$", "사용 가능한 상세 전투 로그에는 턴과 항목이 필요합니다.")
            end
            local previousTurnNumber = 0
            for index, entry in ipairs(view.entries) do
                local path = "$.entries[" .. index .. "]"
                if type(entry) ~= "table" or getmetatable(entry) ~= nil then
                    addError(errors, "invalid_battle_log_entry", path, "상세 전투 로그 항목이 일반 객체가 아닙니다.")
                else
                    local allowedEntryKeys = {
                        turnNumber = true,
                        sequence = true,
                        type = true,
                        text = true,
                        label = true,
                    }
                    for key in pairs(entry) do
                        if type(key) ~= "string" or allowedEntryKeys[key] ~= true then
                            addError(errors, "unknown_battle_log_entry_field", path, "상세 전투 로그 항목에 허용되지 않은 필드가 있습니다.")
                        end
                    end
                    if not isInteger(entry.turnNumber, 1)
                        or (isInteger(view.turnCount, 0) and entry.turnNumber > view.turnCount) then
                        addError(errors, "invalid_battle_log_entry_turn", path .. ".turnNumber", "상세 전투 로그 항목의 턴 번호가 올바르지 않습니다.")
                    elseif entry.turnNumber < previousTurnNumber then
                        addError(errors, "unordered_battle_log_entry", path .. ".turnNumber", "상세 전투 로그 턴 순서가 역행합니다.")
                    else
                        previousTurnNumber = entry.turnNumber
                    end
                    if not isInteger(entry.sequence, 0) then
                        addError(errors, "invalid_battle_log_entry_sequence", path .. ".sequence", "상세 전투 로그 사건 순번이 올바르지 않습니다.")
                    end
                    if not isAsciiId(entry.type) then
                        addError(errors, "invalid_battle_log_entry_type", path .. ".type", "상세 전투 로그 사건 종류가 올바르지 않습니다.")
                    end
                    if type(entry.text) ~= "string" or entry.text == "" then
                        addError(errors, "invalid_battle_log_entry_text", path .. ".text", "상세 전투 로그 문장이 비어 있습니다.")
                    end
                    local expectedLabel = tostring(entry.turnNumber) .. "턴 · " .. tostring(entry.text)
                    if entry.label ~= expectedLabel then
                        addError(errors, "battle_log_entry_label_mismatch", path .. ".label", "상세 전투 로그 표시 문장이 턴 번호와 본문에 일치하지 않습니다.")
                    end
                end
            end
        end
        if #errors > 0 then return failure(errors) end
        return success({ valid = true })
    end

    local function buildPublicView(history, staticInput)
        local staticData = normalizeStaticData(staticInput)
        local validation = validateHistory(history, nil, staticData)
        if not validation.ok then return validation end
        local turns = validation.history.turns
        if #turns == 0 then
            local emptyView = { available = false, turnCount = 0, entries = {} }
            local emptyValidation = validatePublicView(emptyView)
            if not emptyValidation.ok then return emptyValidation end
            return success({ view = emptyView })
        end

        local entries = {}
        local function append(turnNumber, sequence, eventType, text)
            entries[#entries + 1] = {
                turnNumber = turnNumber,
                sequence = sequence,
                type = eventType,
                text = text,
                label = tostring(turnNumber) .. "턴 · " .. text,
            }
        end

        for _, entry in ipairs(turns) do
            append(
                entry.turnNumber,
                0,
                "turn_start",
                "시작 — 은폐 " .. numberText(entry.start.stealth)
                    .. " / 저항 " .. numberText(entry.start.resistance)
                    .. " / 무드 " .. moodLabel(staticData, entry.start.mood)
            )

            local publicEvents = type(entry.publicResult) == "table" and entry.publicResult.events or {}
            for publicIndex, event in ipairs(type(publicEvents) == "table" and publicEvents or {}) do
                local payload = type(event) == "table" and event.payload or nil
                local sequence = type(event) == "table" and event.sequence or publicIndex
                local eventType = type(event) == "table" and event.type or "unknown"
                local text = nil
                if eventType == "card_declared" and type(payload) == "table" and isAsciiId(payload.cardId) then
                    text = "플레이어 카드 「" .. cardName(staticData, payload.cardId) .. "」 선언"
                elseif eventType == "character_intent" and type(payload) == "table" and isAsciiId(payload.role) then
                    text = "상대 예고 역할 — " .. roleLabel(staticData, payload.role)
                elseif eventType == "effect_applied" and type(payload) == "table" then
                    local effectLabel = EFFECT_TEXT[payload.op]
                    if effectLabel and isFinite(payload.amount) then
                        text = effectLabel .. " " .. numberText(payload.amount)
                        if isFinite(payload.before) and isFinite(payload.after) then
                            text = text .. " (" .. numberText(payload.before) .. " → " .. numberText(payload.after) .. ")"
                        end
                    elseif payload.op == "draw_cards" and isInteger(payload.drawnCount, 0) then
                        text = "추가 드로우 " .. tostring(payload.drawnCount) .. "장"
                    elseif payload.op == "skip_actions" then
                        text = "남은 행동 생략"
                    elseif (payload.op == "add_mood_token" or payload.op == "remove_mood_token")
                        and isAsciiId(payload.mood) and isFinite(payload.amount) then
                        text = moodLabel(staticData, payload.mood) .. " 토큰 "
                            .. (payload.op == "add_mood_token" and "추가 " or "제거 ")
                            .. numberText(payload.amount) .. "개"
                        if isFinite(payload.before) and isFinite(payload.after) then
                            text = text .. " (" .. numberText(payload.before) .. " → " .. numberText(payload.after) .. ")"
                        end
                    elseif payload.op == "force_mood" and isAsciiId(payload.mood) then
                        text = moodLabel(staticData, payload.mood) .. " 무드 강제 변경 요청"
                    end
                    local sourceText = effectSourceText(staticData, payload.source)
                    if text ~= nil and sourceText ~= nil then
                        text = text .. " — 원인: " .. sourceText
                    end
                elseif eventType == "plan_changed" and type(payload) == "table" then
                    local planText = payload.action == "placed" and "계획 배치"
                        or payload.action == "discarded" and "계획 폐기"
                        or payload.action == "revealed" and "계획 공개"
                        or "계획 변화"
                    if isAsciiId(payload.cardId) then
                        planText = planText .. " — 「" .. cardName(staticData, payload.cardId) .. "」"
                    end
                    text = planText
                elseif eventType == "actions_stopped" then
                    text = "남은 행동이 중단됨"
                elseif eventType == "card_removed" and type(payload) == "table" and isAsciiId(payload.cardId) then
                    text = "카드 제거 — 「" .. cardName(staticData, payload.cardId) .. "」"
                elseif eventType == "mood_evaluated" and type(payload) == "table"
                    and isAsciiId(payload.before) and isAsciiId(payload.after) then
                    text = "무드 판정 — " .. moodLabel(staticData, payload.before)
                        .. " → " .. moodLabel(staticData, payload.after)
                elseif eventType == "outcome" and type(payload) == "table" then
                    text = payload.status == "victory" and "승리 확정" or "패배 확정"
                elseif eventType == "session_ended" and type(payload) == "table" then
                    text = payload.status == "victory" and "전투 종료 — 승리" or "전투 종료 — 패배"
                end
                if text ~= nil then append(entry.turnNumber, sequence, eventType, text) end
            end

            for _, card in ipairs(entry.cards.player) do
                if card.resolved then
                    append(
                        entry.turnNumber,
                        card.resolutionSequence or 9000,
                        "player_card_resolved",
                        "플레이어 해결 — 「" .. cardName(staticData, card.cardId)
                            .. "」 · " .. roleLabels(staticData, card.roles)
                    )
                end
            end
            for _, card in ipairs(entry.cards.character) do
                if card.resolved then
                    append(
                        entry.turnNumber,
                        card.resolutionSequence or 9100,
                        "character_card_resolved",
                        "상대 행동 해결 — " .. roleLabels(staticData, card.roles)
                    )
                end
            end

            append(
                entry.turnNumber,
                99999,
                "turn_end",
                "종료 — 은폐 " .. numberText(entry.finish.stealth)
                    .. " / 저항 " .. numberText(entry.finish.resistance)
                    .. " / 무드 " .. moodLabel(staticData, entry.finish.mood)
            )
        end
        local view = {
            available = true,
            turnCount = #turns,
            entries = entries,
        }
        local viewValidation = validatePublicView(view)
        if not viewValidation.ok then return viewValidation end
        return success({ view = view })
    end

    local arguments = { ... }
    if action == "empty" then
        return success({ history = emptyHistory() })
    elseif action == "validate" then
        return validateHistory(arguments[1], arguments[2], arguments[3])
    elseif action == "appendResolvedTurn" then
        return appendResolvedTurn(arguments[1], arguments[2], arguments[3], arguments[4])
    elseif action == "attachPublicResult" then
        return attachPublicResult(arguments[1], arguments[2], arguments[3], arguments[4])
    elseif action == "context" then
        return buildContext(arguments[1])
    elseif action == "validateContext" then
        return validateContext(arguments[1])
    elseif action == "buildPublicView" then
        return buildPublicView(arguments[1], arguments[2])
    elseif action == "validatePublicView" then
        return validatePublicView(arguments[1])
    end
    return failure({ makeError("unknown_action", "$.action", "지원하지 않는 전투 이력 작업입니다: " .. tostring(action)) })
end)
