from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(relative_path: str, old: str, new: str) -> None:
    path = ROOT / relative_path
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{relative_path}: expected one match, found {count}\n--- needle ---\n{old[:500]}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def insert_before_once(relative_path: str, marker: str, addition: str) -> None:
    replace_once(relative_path, marker, addition + marker)


BATTLE_HISTORY_LUA = r'''(function(triggerId, action, ...)
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
        if not isAsciiId(record.actionTag) then
            addError(errors, "invalid_history_action_tag", path .. ".actionTag", "카드 이력 행동 태그가 올바르지 않습니다.")
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
            elseif card.actionTag ~= record.actionTag then
                addError(errors, "history_card_tag_mismatch", path .. ".actionTag", "카드 이력 행동 태그와 정적 카드 정의가 다릅니다.")
            end
        end
    end

    local function validateTagCounts(value, path, errors, staticData)
        if type(value) ~= "table" or getmetatable(value) ~= nil then
            addError(errors, "invalid_history_tag_counts", path, "행동 태그 집계가 일반 객체가 아닙니다.")
            return
        end
        for tagId, count in pairs(value) do
            if not isAsciiId(tagId) then
                addError(errors, "invalid_history_action_tag", path, "집계 행동 태그 ID가 올바르지 않습니다.")
            elseif not isInteger(count, 0) then
                addError(errors, "invalid_history_tag_count", path .. "." .. tostring(tagId), "행동 태그 횟수는 0 이상의 정수여야 합니다.")
            elseif type(staticData) == "table"
                and type(staticData.registry) == "table"
                and type(staticData.registry.actionTags) == "table"
                and staticData.registry.actionTags[tagId] == nil then
                addError(errors, "unknown_history_action_tag", path .. "." .. tagId, "집계 행동 태그를 정적 레지스트리에서 찾을 수 없습니다.")
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
                counts[card.actionTag] = (counts[card.actionTag] or 0) + 1
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

        if type(entry.mood) ~= "table" or getmetatable(entry.mood) ~= nil then
            addError(errors, "invalid_history_mood_result", path .. ".mood", "무드 판정 이력이 일반 객체가 아닙니다.")
        else
            if entry.mood.before ~= entry.start.mood or entry.mood.after ~= entry.finish.mood then
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

        if type(entry.tagCounts) ~= "table" then
            addError(errors, "invalid_history_tag_counts", path .. ".tagCounts", "턴 행동 태그 집계가 객체가 아닙니다.")
        else
            for _, side in ipairs({ "player", "character" }) do
                local sideCounts = entry.tagCounts[side]
                if type(sideCounts) ~= "table" then
                    addError(errors, "invalid_history_tag_counts", path .. ".tagCounts." .. side, "진영별 행동 태그 집계가 객체가 아닙니다.")
                else
                    validateTagCounts(sideCounts.declared, path .. ".tagCounts." .. side .. ".declared", errors, staticData)
                    validateTagCounts(sideCounts.resolved, path .. ".tagCounts." .. side .. ".resolved", errors, staticData)
                    if type(entry.cards) == "table" and isDenseArray(entry.cards[side]) then
                        if not dataEqual(sideCounts.declared, countCards(entry.cards[side], "declared")) then
                            addError(errors, "history_declared_count_mismatch", path .. ".tagCounts." .. side .. ".declared", "선언 태그 집계가 카드 이력과 다릅니다.")
                        end
                        if not dataEqual(sideCounts.resolved, countCards(entry.cards[side], "resolved")) then
                            addError(errors, "history_resolved_count_mismatch", path .. ".tagCounts." .. side .. ".resolved", "해결 태그 집계가 카드 이력과 다릅니다.")
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
                if type(state.player) == "table" and state.player.stealth ~= last.finish.stealth then
                    addError(errors, "battle_history_stealth_mismatch", "$.turns[" .. count .. "].finish.stealth", "마지막 이력의 은폐가 현재 상태와 다릅니다.")
                end
                if type(state.character) == "table"
                    and (state.character.resistance ~= last.finish.resistance
                        or state.character.mood ~= last.finish.mood) then
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
            if type(card) ~= "table" or card.owner ~= side or not isAsciiId(card.actionTag) then
                return nil
            end
            local record = {
                cardId = cardId,
                instanceId = instanceId,
                actionTag = card.actionTag,
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
            tagCounts = {
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
        return {
            cardId = record.cardId,
            instanceId = record.instanceId,
            actionTag = record.actionTag,
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
            playerCards = {},
            characterCards = {},
            playerActionTags = {},
            characterActionTags = {},
        }
        for _, side in ipairs({ "player", "character" }) do
            local outputCards = side == "player" and value.playerCards or value.characterCards
            local outputTags = side == "player" and value.playerActionTags or value.characterActionTags
            for _, record in ipairs(entry.cards[side]) do
                outputCards[#outputCards + 1] = cardContextRecord(record)
                if record.resolved then outputTags[#outputTags + 1] = record.actionTag end
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
                declaredTagCounts = {},
                resolvedTagCounts = {},
            },
            character = {
                declaredTagCounts = {},
                resolvedTagCounts = {},
            },
        }

        for index, entry in ipairs(turns) do
            context.turns[index] = turnContext(entry)
            for _, side in ipairs({ "player", "character" }) do
                addCounts(context[side].declaredTagCounts, entry.tagCounts[side].declared)
                addCounts(context[side].resolvedTagCounts, entry.tagCounts[side].resolved)
                for _, card in ipairs(entry.cards[side]) do
                    if card.declared then context[side].lastDeclaredActionTag = card.actionTag end
                    if card.resolved then context[side].lastResolvedActionTag = card.actionTag end
                end
            end
        end
        if #turns > 0 then
            context.previousTurn = turnContext(turns[#turns])
        end

        for window = 1, #turns do
            local windowValue = {
                turns = window,
                player = { declaredTagCounts = {}, resolvedTagCounts = {} },
                character = { declaredTagCounts = {}, resolvedTagCounts = {} },
            }
            local first = math.max(1, #turns - window + 1)
            for index = first, #turns do
                local entry = turns[index]
                for _, side in ipairs({ "player", "character" }) do
                    addCounts(windowValue[side].declaredTagCounts, entry.tagCounts[side].declared)
                    addCounts(windowValue[side].resolvedTagCounts, entry.tagCounts[side].resolved)
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
        elseif #value.turns ~= value.completedTurns or #value.windows ~= value.completedTurns then
            addError(errors, "history_context_count_mismatch", "$", "컨텍스트 완료 턴 수와 배열 길이가 다릅니다.")
        end
        for _, side in ipairs({ "player", "character" }) do
            if type(value[side]) ~= "table"
                or type(value[side].declaredTagCounts) ~= "table"
                or type(value[side].resolvedTagCounts) ~= "table" then
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

    local function tagLabel(staticData, tagId)
        local tag = type(staticData) == "table"
            and type(staticData.registry) == "table"
            and type(staticData.registry.actionTags) == "table"
            and staticData.registry.actionTags[tagId]
            or nil
        return type(tag) == "table" and tag.label or tostring(tagId)
    end

    local EFFECT_TEXT = {
        pay_stealth_cost = "은폐 비용",
        lose_stealth = "은폐 감소",
        recover_stealth = "은폐 회복",
        damage_resistance = "저항 피해",
        recover_resistance = "저항 회복",
    }

    local function buildPublicView(history, staticInput)
        local staticData = normalizeStaticData(staticInput)
        local validation = validateHistory(history, nil, staticData)
        if not validation.ok then return validation end
        local turns = validation.history.turns
        if #turns == 0 then
            return success({ view = { available = false, turnCount = 0, entries = {} } })
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
                elseif eventType == "character_intent" and type(payload) == "table" and isAsciiId(payload.actionTag) then
                    text = "상대 예고 행동 — " .. tagLabel(staticData, payload.actionTag)
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
                            .. "」 · " .. tagLabel(staticData, card.actionTag)
                    )
                end
            end
            for _, card in ipairs(entry.cards.character) do
                if card.resolved then
                    append(
                        entry.turnNumber,
                        card.resolutionSequence or 9100,
                        "character_card_resolved",
                        "상대 행동 해결 — " .. tagLabel(staticData, card.actionTag)
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
        return success({
            view = {
                available = true,
                turnCount = #turns,
                entries = entries,
            },
        })
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
    end
    return failure({ makeError("unknown_action", "$.action", "지원하지 않는 전투 이력 작업입니다: " .. tostring(action)) })
end)
'''

BATTLE_HISTORY_TEST = r'''local function loadModule(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return assert(load("return " .. source, "@" .. path))()
end

local historyModule = loadModule("System/battleHistory.lua")
local staticData = {
    registry = {
        moods = {
            ignore = { id = "ignore", label = "무시" },
            suspicion = { id = "suspicion", label = "의심" },
        },
        actionTags = {
            contact = { id = "contact", label = "접촉", owner = "player" },
            vigilance = { id = "vigilance", label = "경계", owner = "character" },
        },
    },
    cards = {
        touch = { id = "touch", name = "접촉", owner = "player", actionTag = "contact" },
        watch = { id = "watch", name = "주시", owner = "character", actionTag = "vigilance" },
    },
}

local before = {
    status = "active",
    turnNumber = 1,
    lastCommittedTurnId = nil,
    player = { stealth = 30 },
    character = { resistance = 30, mood = "ignore" },
    cardInstances = {
        { instanceId = "player-001", cardId = "touch", owner = "player" },
        { instanceId = "character-001", cardId = "watch", owner = "character" },
    },
    history = { schemaVersion = 1, kind = "battleHistory", turns = {} },
}
local after = {
    status = "active",
    turnNumber = 2,
    lastCommittedTurnId = "battle-turn-001",
    player = { stealth = 27 },
    character = { resistance = 25, mood = "suspicion" },
    cardInstances = before.cardInstances,
    history = before.history,
}
local spec = {
    turnId = "battle-turn-001",
    turnNumber = 1,
    selectedCards = {
        player = { "player-001" },
        character = { "character-001" },
    },
    start = { stealth = 30, resistance = 30, mood = "ignore" },
    finish = { stealth = 27, resistance = 25, mood = "suspicion", status = "active" },
    mood = {
        before = "ignore",
        after = "suspicion",
        applied = true,
        forcedCount = 0,
        forceCancelled = false,
        resolution = "token",
    },
    events = {
        {
            sequence = 1,
            type = "card_declared",
            side = "player",
            source = { kind = "card", id = "touch", side = "player", instanceId = "player-001" },
            payload = { finalStealthCost = 0 },
        },
        {
            sequence = 2,
            type = "card_resolved",
            side = "player",
            source = { kind = "card", id = "touch", side = "player", instanceId = "player-001" },
            payload = { finalResistanceDamage = 5 },
        },
        {
            sequence = 3,
            type = "card_declared",
            side = "character",
            source = { kind = "card", id = "watch", side = "character", instanceId = "character-001" },
            payload = { finalStealthCost = 0 },
        },
        {
            sequence = 4,
            type = "card_resolved",
            side = "character",
            source = { kind = "card", id = "watch", side = "character", instanceId = "character-001" },
            payload = { finalResistanceDamage = 0 },
        },
    },
}

local appended = historyModule(nil, "appendResolvedTurn", before, after, spec, staticData)
assert(appended.ok, appended.errors[1] and appended.errors[1].message)
assert(#appended.state.history.turns == 1)
assert(appended.state.history.turns[1].tagCounts.player.resolved.contact == 1)
assert(appended.state.history.turns[1].tagCounts.character.resolved.vigilance == 1)

local publicResult = {
    schemaVersion = 1,
    events = {
        { sequence = 1, type = "card_declared", payload = { cardId = "touch" } },
        { sequence = 2, type = "effect_applied", payload = { op = "damage_resistance", amount = 5, before = 30, after = 25 } },
        { sequence = 3, type = "mood_evaluated", payload = { before = "ignore", after = "suspicion" } },
    },
}
local attached = historyModule(nil, "attachPublicResult", appended.state, "battle-turn-001", publicResult, staticData)
assert(attached.ok, attached.errors[1] and attached.errors[1].message)
assert(attached.state.history.turns[1].publicResult.events[2].payload.amount == 5)

local context = historyModule(nil, "context", attached.state.history)
assert(context.ok)
assert(context.context.completedTurns == 1)
assert(context.context.previousTurn.startMood == "ignore")
assert(context.context.previousTurn.endMood == "suspicion")
assert(context.context.player.lastResolvedActionTag == "contact")
assert(context.context.windows[1].player.resolvedTagCounts.contact == 1)

local view = historyModule(nil, "buildPublicView", attached.state.history, staticData)
assert(view.ok)
assert(view.view.available == true)
assert(view.view.turnCount == 1)
assert(#view.view.entries >= 4)
print("battle-history-check: ok")
'''

(ROOT / "System/battleHistory.lua").write_text(BATTLE_HISTORY_LUA, encoding="utf-8")
(ROOT / ".agents/Tests/battle-history-check.lua").write_text(BATTLE_HISTORY_TEST, encoding="utf-8")

replace_once(
    "System/main.lua",
    'or "runtime-bundle-character-memory-v1-20260730"',
    'or "runtime-bundle-battle-history-v1-20260731"',
)

# stateSchema: battleState history field, constructor default, validation, and
# character-selection receipt history context.
replace_once(
    "System/stateSchema.lua",
    '''            characterIntent = true,
            turnStartReceipt = true,
        }, "$", errors)''',
    '''            characterIntent = true,
            history = true,
            turnStartReceipt = true,
        }, "$", errors)''',
)
replace_once(
    "System/stateSchema.lua",
    '''                for moodId in pairs(normalizedStaticData.registry.moods) do
                    value.character.moodTokens[moodId] = 0
                end
            end
            return value''',
    '''                for moodId in pairs(normalizedStaticData.registry.moods) do
                    value.character.moodTokens[moodId] = 0
                end
            end
            if value.history == nil then
                value.history = {
                    schemaVersion = SCHEMA_VERSION,
                    kind = "battleHistory",
                    turns = {},
                }
            end
            return value''',
)
replace_once(
    "System/stateSchema.lua",
    '''        if state.turnStartReceipt ~= nil then
            validateTurnStartReceipt(state.turnStartReceipt, state, staticData, referencesValidated, errors)
        end''',
    '''        local historyReport, historyCallError = callReceiptValidator(
            "battleHistory",
            "validate",
            state.history,
            state,
            staticData
        )
        if historyCallError ~= nil then
            addError(errors, "history_validation_unavailable", "$.history", "전투 이력 검증을 실행할 수 없습니다: " .. historyCallError)
        elseif historyReport.ok ~= true then
            appendNestedErrors(errors, "$.history", historyReport)
        end

        if state.turnStartReceipt ~= nil then
            validateTurnStartReceipt(state.turnStartReceipt, state, staticData, referencesValidated, errors)
        end''',
)

insert_before_once(
    "System/stateSchema.lua",
    "    local function validateSelectionContext(context, path, errors)\n",
    '''    local function projectHistoryContext(history)
        if type(runScript) ~= "function" then return nil end
        local ok, report = pcall(runScript, triggerId, "battleHistory", "context", history)
        if not ok or type(report) ~= "table" or report.ok ~= true or type(report.context) ~= "table" then
            return nil
        end
        return report.context
    end

    local function validateHistoryContext(value, path, errors)
        if type(runScript) ~= "function" then
            addError(errors, "history_context_validation_unavailable", path, "전투 이력 컨텍스트 검증기를 찾을 수 없습니다.")
            return
        end
        local ok, report = pcall(runScript, triggerId, "battleHistory", "validateContext", value)
        if not ok or type(report) ~= "table" then
            addError(errors, "history_context_validation_failed", path, "전투 이력 컨텍스트 검증 호출에 실패했습니다.")
        elseif report.ok ~= true then
            appendNestedErrors(errors, path, report)
        end
    end

''',
)
replace_once(
    "System/stateSchema.lua",
    '''            character = true,
            characterHand = true,
        }, path, errors)''',
    '''            character = true,
            characterHand = true,
            history = true,
        }, path, errors)''',
)
replace_once(
    "System/stateSchema.lua",
    '''        if not isInteger(context.turnNumber, 1) then
            addError(errors, "invalid_turn_number", path .. ".turnNumber", "선택 시점 턴 번호는 1 이상의 정수여야 합니다.")
        end

        if type(context.player) ~= "table" then''',
    '''        if not isInteger(context.turnNumber, 1) then
            addError(errors, "invalid_turn_number", path .. ".turnNumber", "선택 시점 턴 번호는 1 이상의 정수여야 합니다.")
        end
        validateHistoryContext(context.history, path .. ".history", errors)

        if type(context.player) ~= "table" then''',
)
replace_once(
    "System/stateSchema.lua",
    '''            characterHand = characterHand,
        }
    end

    local function selectionContextEqual''',
    '''            characterHand = characterHand,
            history = projectHistoryContext(state.history),
        }
    end

    local function historyContextEqual(left, right, seen)
        if type(left) ~= type(right) then return false end
        if type(left) ~= "table" then return left == right end
        seen = seen or {}
        if seen[left] ~= nil then return seen[left] == right end
        seen[left] = right
        for key, value in pairs(left) do
            if not historyContextEqual(value, right[key], seen) then return false end
        end
        for key in pairs(right) do
            if left[key] == nil then return false end
        end
        return true
    end

    local function selectionContextEqual''',
)
replace_once(
    "System/stateSchema.lua",
    '''            or left.character.mood ~= right.character.mood
            or type(left.characterHand) ~= "table" or type(right.characterHand) ~= "table"''',
    '''            or left.character.mood ~= right.character.mood
            or not historyContextEqual(left.history, right.history)
            or type(left.characterHand) ~= "table" or type(right.characterHand) ~= "table"''',
)

# Shared history context for resolution, triggers, and character AI scoring.
TURN_RESOLVER_HISTORY_HELPER = '''    local function buildHistoryContext(history)
        if type(runScript) ~= "function" then
            error("battleHistory.context runtime is unavailable", 0)
        end
        local ok, report = pcall(runScript, triggerId, "battleHistory", "context", history)
        if not ok or type(report) ~= "table" or report.ok ~= true or type(report.context) ~= "table" then
            error("battleHistory.context failed", 0)
        end
        return report.context
    end

'''
insert_before_once(
    "System/turnResolver.lua",
    "    local function buildContext(state, phase, card, instance, plan)\n",
    TURN_RESOLVER_HISTORY_HELPER,
)
replace_once(
    "System/turnResolver.lua",
    '''            mood = state.character.mood,
            player = {''',
    '''            mood = state.character.mood,
            history = buildHistoryContext(state.history),
            player = {''',
)
replace_once(
    "System/turnResolver.lua",
    '''        working.state.lastCommittedTurnId = turnId

        local stateReport, stateErrors = callModule(''',
    '''        working.state.lastCommittedTurnId = turnId

        local historyReport, historyErrors = callModule(
            "battleHistory",
            "appendResolvedTurn",
            authorityState,
            working.state,
            {
                turnId = turnId,
                turnNumber = resolvedTurnNumber,
                selectedCards = {
                    player = playerSelection,
                    character = characterSelection,
                },
                events = events,
                start = {
                    stealth = startValues.stealth,
                    resistance = startValues.resistance,
                    mood = startValues.mood,
                },
                finish = {
                    stealth = endingStealth,
                    resistance = endingResistance,
                    mood = working.state.character.mood,
                    status = working.state.status,
                },
                mood = moodPayload,
            },
            staticData
        )
        if historyErrors then
            return failure(historyErrors)
        end
        if type(historyReport.state) ~= "table" then
            return failure({
                makeError("invalid_history_append_result", "$.runtime.battleHistory", "전투 이력 추가 결과에 상태가 없습니다."),
            })
        end
        working.state = historyReport.state

        local stateReport, stateErrors = callModule(''',
)

TRIGGER_HISTORY_HELPER = '''    local function buildHistoryContext(history)
        if type(runScript) ~= "function" then
            error("battleHistory.context runtime is unavailable", 0)
        end
        local ok, report = pcall(runScript, triggerId, "battleHistory", "context", history)
        if not ok or type(report) ~= "table" or report.ok ~= true or type(report.context) ~= "table" then
            error("battleHistory.context failed", 0)
        end
        return report.context
    end

'''
insert_before_once(
    "System/triggerPipeline.lua",
    "    local function buildContext(state, options, planState)\n",
    TRIGGER_HISTORY_HELPER,
)
replace_once(
    "System/triggerPipeline.lua",
    '''            mood = state.character.mood,
            player = {''',
    '''            mood = state.character.mood,
            history = buildHistoryContext(state.history),
            player = {''',
)

CHARACTER_HISTORY_HELPER = '''    local function buildHistoryContext(state)
        if type(state) == "table" and type(state.historyContextOverride) == "table" then
            return state.historyContextOverride
        end
        local report, errors = callModule(
            "battleHistory",
            "context",
            type(state) == "table" and state.history or nil
        )
        if errors or type(report) ~= "table" or type(report.context) ~= "table" then
            error("battleHistory.context failed", 0)
        end
        return report.context
    end

'''
insert_before_once(
    "System/characterSelector.lua",
    "    local function buildSelectionContext(state, staticData, hand)\n",
    CHARACTER_HISTORY_HELPER,
)
replace_once(
    "System/characterSelector.lua",
    '''        return {
            turnNumber = state.turnNumber,
            player = {''',
    '''        return {
            turnNumber = state.turnNumber,
            history = buildHistoryContext(state),
            player = {''',
)
replace_once(
    "System/characterSelector.lua",
    '''            phase = "character_selection",
            mood = state.character.mood,
            player = {''',
    '''            phase = "character_selection",
            mood = state.character.mood,
            history = buildHistoryContext(state),
            player = {''',
)
replace_once(
    "System/characterSelector.lua",
    '''            or type(context.character) ~= "table"
            or not isFinite(context.character.resistance)''',
    '''            or type(context.character) ~= "table"
            or type(context.history) ~= "table"
            or not isFinite(context.character.resistance)''',
)
replace_once(
    "System/characterSelector.lua",
    '''        local syntheticState = {
            turnNumber = context.turnNumber,
            player = {''',
    '''        local syntheticState = {
            turnNumber = context.turnNumber,
            historyContextOverride = context.history,
            player = {''',
)

# Attach the public projection to the canonical history before pending integrity is sealed.
replace_once(
    "System/battleRuntime.lua",
    '''        if type(projected.publicResult) ~= "table" or type(projected.llmEvent) ~= "table" then
            return failure({
                makeError("invalid_event_projection", "$.turnResolution", "턴 사건 투영 결과가 올바르지 않습니다."),
            })
        end

        local constructed, constructErrors = callModule(''',
    '''        if type(projected.publicResult) ~= "table" or type(projected.llmEvent) ~= "table" then
            return failure({
                makeError("invalid_event_projection", "$.turnResolution", "턴 사건 투영 결과가 올바르지 않습니다."),
            })
        end

        local historyReport, historyErrors = callModule(
            "battleHistory",
            "attachPublicResult",
            resolution.afterState,
            resolution.turnId,
            projected.publicResult,
            staticData
        )
        if historyErrors then
            return failure(historyErrors)
        end
        if type(historyReport.state) ~= "table" then
            return failure({
                makeError("invalid_public_history_result", "$.runtime.battleHistory", "공개 전투 로그 연결 결과에 상태가 없습니다."),
            })
        end
        resolution.afterState = historyReport.state

        local constructed, constructErrors = callModule(''',
)

# Project the complete public battle log into battleView on terminal states.
VIEW_HISTORY_HELPER = '''    local function buildBattleLogView(state, staticData, errors)
        if type(state) ~= "table" or state.status == "active" then
            return { available = false, turnCount = 0, entries = {} }
        end
        if type(runScript) ~= "function" then
            addError(errors, "history_view_runtime_unavailable", "$.history", "상세 전투 로그 빌더를 찾을 수 없습니다.")
            return { available = false, turnCount = 0, entries = {} }
        end
        local ok, report = pcall(runScript, triggerId, "battleHistory", "buildPublicView", state.history, staticData)
        if not ok or type(report) ~= "table" then
            addError(errors, "history_view_failed", "$.history", "상세 전투 로그 생성 호출에 실패했습니다.")
            return { available = false, turnCount = 0, entries = {} }
        end
        if report.ok ~= true then
            appendNestedErrors(errors, "$.history", report)
            return { available = false, turnCount = 0, entries = {} }
        end
        if type(report.view) ~= "table" then
            addError(errors, "invalid_history_view", "$.history", "상세 전투 로그 View가 없습니다.")
            return { available = false, turnCount = 0, entries = {} }
        end
        return report.view
    end

'''
insert_before_once(
    "System/viewBuilder.lua",
    "    local function buildLastTurnView(lastTurn, registry, errors)\n",
    VIEW_HISTORY_HELPER,
)
replace_once(
    "System/viewBuilder.lua",
    '''            lastTurn = lastTurn,
            outcome = {''',
    '''            lastTurn = lastTurn,
            battleLog = buildBattleLogView(displayState, data, errors),
            outcome = {''',
)
replace_once(
    "System/viewBuilder.lua",
    '''            zones = true,
            lastTurn = true,
            outcome = true,''',
    '''            zones = true,
            lastTurn = true,
            battleLog = true,
            outcome = true,''',
)

# End-of-battle expandable log UI.
replace_once(
    "html/battleui.html",
    '''.ht-log-list {
display: grid;
gap: 3px;
margin: 5px 0 0;
padding: 0 0 0 13px;
color: #9f9892;
font-size: 8px;
}''',
    '''.ht-log-list {
display: grid;
gap: 3px;
margin: 5px 0 0;
padding: 0 0 0 13px;
color: #9f9892;
font-size: 8px;
}
.ht-log--battle {
margin-top: 8px;
padding: 7px 8px 8px;
border: 1px solid rgba(239, 213, 143, .20);
border-radius: 8px;
background: rgba(239, 213, 143, .035);
}
.ht-log--battle > summary {
padding-top: 0;
color: #e5cf91;
font-size: 9px;
font-weight: 850;
}
.ht-log--battle .ht-log-list {
max-height: 260px;
padding-right: 5px;
overflow-y: auto;
overscroll-behavior: contain;
line-height: 1.5;
}''',
)
replace_once(
    "html/battleui.html",
    '''{{#if {{equal::{{dict_element::{{dict_element::{{getvar::battleView}}::lastTurn}}::available}}::true}}}}
<details class="ht-log">
<summary>직전 판정 결과 보기</summary>
<ol class="ht-log-list">
{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::lastTurn}}::summaries}} summary}}
<li>{{dict_element::{{slot::summary}}::text}}</li>
{{/each}}
</ol>
</details>
{{/if}}

{{#if {{equal::{{dict_element::{{getvar::battleView}}::phase}}::awaitingOutput}}}}''',
    '''{{#if {{equal::{{dict_element::{{dict_element::{{getvar::battleView}}::lastTurn}}::available}}::true}}}}
<details class="ht-log">
<summary>직전 판정 결과 보기</summary>
<ol class="ht-log-list">
{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::lastTurn}}::summaries}} summary}}
<li>{{dict_element::{{slot::summary}}::text}}</li>
{{/each}}
</ol>
</details>
{{/if}}

{{#if {{equal::{{dict_element::{{dict_element::{{getvar::battleView}}::battleLog}}::available}}::true}}}}
<details class="ht-log ht-log--battle">
<summary>상세 전투 로그 펼쳐보기 · {{dict_element::{{dict_element::{{getvar::battleView}}::battleLog}}::turnCount}}턴</summary>
<ol class="ht-log-list">
{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::battleLog}}::entries}} battleLogEntry}}
<li>{{dict_element::{{slot::battleLogEntry}}::label}}</li>
{{/each}}
</ol>
</details>
{{/if}}

{{#if {{equal::{{dict_element::{{getvar::battleView}}::phase}}::awaitingOutput}}}}''',
)

# Documentation for card/trait authors.
(ROOT / "docs").mkdir(exist_ok=True)
(ROOT / "docs/battle-history.md").write_text(r'''# 전투 이력 계약 v1

`battleState.history`는 완료된 턴만 보존하는 권위 이력이다. 턴 해결은 `turnResolver`에서 기계적 이력을 추가하고, `battleRuntime`에서 비공개 정보를 제거한 `publicResult`를 같은 턴에 연결한 뒤 pending 무결성을 봉인한다.

효과 콜백에는 `context.history`가 제공된다.

```lua
local previousMood = context.history.previousTurn
    and context.history.previousTurn.endMood

local sameTag = context.history.player.lastResolvedActionTag
    == context.card.actionTag

local recentContactCount = context.history.windows[3]
    and (context.history.windows[3].player.resolvedTagCounts.contact or 0)
    or 0
```

카드 사용 횟수는 `declaredTagCounts`와 `resolvedTagCounts`를 구분한다. 일반적인 “사용했다” 조건은 `resolvedTagCounts`를 사용한다. `windows[N]`은 직전 완료 N턴을 포함하며 현재 해결 중인 턴은 포함하지 않는다.

전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영하고 `battleView.battleLog`에 넣는다. `html/battleui.html`은 이를 접을 수 있는 상세 전투 로그로 표시한다.
''', encoding="utf-8")

print("battle history patch applied")
