(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local TOTAL_ROUNDS = 10
    local OFFER_SIZE = 3
    local COPY_LIMIT = 2

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

        -- Lua의 빈 테이블은 JSON 배열로 취급한다. View에서 빈 객체는 없다.
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
                addError(errors, "unknown_field", objectPath(path, key), "gameSetupView에 허용되지 않은 필드입니다.")
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

    local function appendNestedErrors(target, prefix, report)
        if type(report) ~= "table" or type(report.errors) ~= "table" then
            addError(target, "validation_failed", prefix, "하위 검증 결과를 읽을 수 없습니다.")
            return
        end
        for _, item in ipairs(report.errors) do
            local suffix = tostring(type(item) == "table" and item.path or "$.")
            if string.sub(suffix, 1, 1) == "$" then
                suffix = string.sub(suffix, 2)
            end
            addError(
                target,
                tostring(type(item) == "table" and item.code or "validation_failed"),
                prefix .. suffix,
                tostring(type(item) == "table" and item.message or "하위 검증에 실패했습니다.")
            )
        end
        if #report.errors == 0 then
            addError(target, "validation_failed", prefix, "하위 검증이 실패했지만 오류 내용이 없습니다.")
        end
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

    local function buildOfferCard(slot, cardId, ownedCopies, data, errors)
        local path = "$.offer.cards[" .. slot .. "]"
        local card = data.cards[cardId]
        if type(card) ~= "table" or card.owner ~= "player" then
            addError(errors, "missing_player_card", path .. ".cardId", "제안된 플레이어 카드를 찾을 수 없습니다: " .. tostring(cardId))
            return nil
        end
        if card.id ~= cardId then
            addError(errors, "card_identity_mismatch", path .. ".cardId", "제안 카드의 DB 키와 내부 ID가 일치하지 않습니다.")
            return nil
        end

        local presentation, presentationError = callRuntime(
            "viewBuilder",
            "buildCardPresentation",
            card,
            data.registry,
            path
        )
        if presentationError then
            table.insert(errors, presentationError)
            return nil
        end
        if presentation.ok ~= true or type(presentation.card) ~= "table" then
            appendNestedErrors(errors, path, presentation)
            return nil
        end
        if type(card.base) ~= "table" then
            addError(errors, "missing_card_base", path, "카드 기본 수치를 찾을 수 없습니다.")
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
        elseif expectedTagKind ~= nil and value.tagKind ~= expectedTagKind then
            addError(errors, "tag_role_mismatch", path .. ".tagKind", "이 위치의 태그 종류가 올바르지 않습니다.")
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

    local function validateMechanisms(value, path, errors)
        local length = getArrayLength(value, path, errors)
        if length == nil then
            return
        end
        local seen = {}
        for index = 1, length do
            local tag = value[index]
            validateTagView(tag, path .. "[" .. index .. "]", errors, "mechanism")
            if type(tag) == "table" and type(tag.id) == "string" then
                if seen[tag.id] then
                    addError(errors, "duplicate_mechanism", path .. "[" .. index .. "].id", "메커니즘 태그가 중복되었습니다.")
                end
                seen[tag.id] = true
            end
        end
    end

    local function validateOfferCard(card, path, expectedSlot, deckCopies, seenCards, errors)
        if type(card) ~= "table" then
            addError(errors, "invalid_offer_card", path, "제안 카드가 테이블이 아닙니다.")
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
            addError(errors, "invalid_offer_slot", path .. ".slot", "제안 카드 슬롯은 배열 순서와 같아야 합니다.")
        end
        if not isAsciiId(card.cardId) then
            addError(errors, "invalid_card_id", path .. ".cardId", "카드 ID가 올바르지 않습니다.")
        elseif seenCards[card.cardId] then
            addError(errors, "duplicate_offer_card", path .. ".cardId", "같은 카드가 한 제안에 중복되었습니다.")
        else
            seenCards[card.cardId] = true
        end
        if type(card.name) ~= "string" or card.name == "" then
            addError(errors, "invalid_card_name", path .. ".name", "카드 이름이 필요합니다.")
        end
        validateSegments(card.descriptionSegments, path .. ".descriptionSegments", errors)
        validateRuleLines(card.ruleLines, path .. ".ruleLines", errors)
        validateTagView(card.actionTag, path .. ".actionTag", errors, "action")
        validateMechanisms(card.mechanisms, path .. ".mechanisms", errors)
        if not isFinite(card.baseStealthCost) or card.baseStealthCost < 0 then
            addError(errors, "invalid_stealth_cost", path .. ".baseStealthCost", "기본 은폐 비용은 0 이상의 유한한 숫자여야 합니다.")
        end
        if not isFinite(card.baseResistanceDamage) or card.baseResistanceDamage < 0 then
            addError(errors, "invalid_resistance_damage", path .. ".baseResistanceDamage", "기본 저항 피해는 0 이상의 유한한 숫자여야 합니다.")
        end
        if not isInteger(card.ownedCopies, 0, COPY_LIMIT - 1) then
            addError(errors, "invalid_owned_copies", path .. ".ownedCopies", "제안 카드 보유 수는 0 또는 1이어야 합니다.")
        elseif isAsciiId(card.cardId) and card.ownedCopies ~= (deckCopies[card.cardId] or 0) then
            addError(errors, "owned_copies_mismatch", path .. ".ownedCopies", "제안 카드 보유 수가 덱 요약과 다릅니다.")
        end
    end

    local function validateGameSetupView(view)
        local errors = {}
        validateJsonSafe(view, "$", errors)
        if #errors > 0 then
            if type(view) ~= "table" then
                addError(errors, "invalid_view_root", "$", "gameSetupView 최상위 값은 테이블이어야 합니다.")
            end
            return failure(errors)
        end
        if type(view) ~= "table" or getmetatable(view) ~= nil then
            if type(view) ~= "table" then
                addError(errors, "invalid_view_root", "$", "gameSetupView 최상위 값은 테이블이어야 합니다.")
            end
            return failure(errors)
        end

        checkAllowedKeys(view, {
            schemaVersion = true,
            kind = true,
            phase = true,
            locked = true,
            progress = true,
            deck = true,
            offer = true,
        }, "$", errors)
        if view.schemaVersion ~= SCHEMA_VERSION then
            addError(errors, "unsupported_schema", "$.schemaVersion", "지원하지 않는 gameSetupView 스키마입니다.")
        end
        if view.kind ~= "gameSetupView" then
            addError(errors, "unexpected_kind", "$.kind", "View 종류가 gameSetupView가 아닙니다.")
        end
        if view.phase ~= "deckDraft" and view.phase ~= "deckComplete" then
            addError(errors, "invalid_phase", "$.phase", "초기 덱 구성 단계가 올바르지 않습니다.")
        end
        if type(view.locked) ~= "boolean" then
            addError(errors, "invalid_locked", "$.locked", "locked는 불리언이어야 합니다.")
        elseif (view.phase == "deckComplete") ~= view.locked then
            addError(errors, "locked_phase_mismatch", "$.locked", "완료 단계와 잠금 상태가 일치하지 않습니다.")
        end

        local selectedCount = nil
        if type(view.progress) ~= "table" then
            addError(errors, "invalid_progress", "$.progress", "progress가 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.progress, {
                selectedCount = true,
                totalRounds = true,
                currentRound = true,
                remainingRounds = true,
            }, "$.progress", errors)
            selectedCount = view.progress.selectedCount
            if not isInteger(selectedCount, 0, TOTAL_ROUNDS) then
                addError(errors, "invalid_selected_count", "$.progress.selectedCount", "선택 수가 올바르지 않습니다.")
            end
            if view.progress.totalRounds ~= TOTAL_ROUNDS then
                addError(errors, "invalid_total_rounds", "$.progress.totalRounds", "초기 덱 드래프트는 10회여야 합니다.")
            end
            local expectedRound = view.phase == "deckComplete"
                and TOTAL_ROUNDS
                or (isInteger(selectedCount, 0, TOTAL_ROUNDS - 1) and selectedCount + 1 or nil)
            if expectedRound == nil or view.progress.currentRound ~= expectedRound then
                addError(errors, "invalid_current_round", "$.progress.currentRound", "현재 드래프트 회차가 올바르지 않습니다.")
            end
            local expectedRemaining = isInteger(selectedCount, 0, TOTAL_ROUNDS)
                and TOTAL_ROUNDS - selectedCount
                or nil
            if expectedRemaining == nil or view.progress.remainingRounds ~= expectedRemaining then
                addError(errors, "invalid_remaining_rounds", "$.progress.remainingRounds", "남은 드래프트 횟수가 올바르지 않습니다.")
            end
            if view.phase == "deckDraft" and selectedCount == TOTAL_ROUNDS then
                addError(errors, "draft_count_mismatch", "$.progress.selectedCount", "진행 중인 드래프트는 아직 10장을 선택할 수 없습니다.")
            elseif view.phase == "deckComplete" and selectedCount ~= TOTAL_ROUNDS then
                addError(errors, "complete_count_mismatch", "$.progress.selectedCount", "완료된 드래프트는 정확히 10장을 선택해야 합니다.")
            end
        end

        local deckCopies = {}
        local deckSum = 0
        if type(view.deck) ~= "table" then
            addError(errors, "invalid_deck", "$.deck", "deck이 테이블이 아닙니다.")
        else
            checkAllowedKeys(view.deck, { count = true, limit = true, items = true }, "$.deck", errors)
            if not isInteger(view.deck.count, 0, TOTAL_ROUNDS) then
                addError(errors, "invalid_deck_count", "$.deck.count", "덱 카드 수가 올바르지 않습니다.")
            elseif isInteger(selectedCount, 0, TOTAL_ROUNDS) and view.deck.count ~= selectedCount then
                addError(errors, "deck_count_mismatch", "$.deck.count", "덱 카드 수와 선택 수가 다릅니다.")
            end
            if view.deck.limit ~= TOTAL_ROUNDS then
                addError(errors, "invalid_deck_limit", "$.deck.limit", "초기 덱 한도는 10장이어야 합니다.")
            end
            local itemCount = getArrayLength(view.deck.items, "$.deck.items", errors)
            if itemCount then
                for index = 1, itemCount do
                    local item = view.deck.items[index]
                    local path = "$.deck.items[" .. index .. "]"
                    if type(item) ~= "table" then
                        addError(errors, "invalid_deck_item", path, "덱 요약 항목이 테이블이 아닙니다.")
                    else
                        checkAllowedKeys(item, { cardId = true, name = true, copies = true }, path, errors)
                        if not isAsciiId(item.cardId) then
                            addError(errors, "invalid_card_id", path .. ".cardId", "카드 ID가 올바르지 않습니다.")
                        elseif deckCopies[item.cardId] ~= nil then
                            addError(errors, "duplicate_deck_item", path .. ".cardId", "덱 요약에 같은 카드가 중복되었습니다.")
                        else
                            deckCopies[item.cardId] = item.copies
                        end
                        if type(item.name) ~= "string" or item.name == "" then
                            addError(errors, "invalid_card_name", path .. ".name", "카드 이름이 필요합니다.")
                        end
                        if not isInteger(item.copies, 1, COPY_LIMIT) then
                            addError(errors, "invalid_card_copies", path .. ".copies", "같은 카드는 1장 또는 2장이어야 합니다.")
                        else
                            deckSum = deckSum + item.copies
                        end
                    end
                end
            end
            if isInteger(view.deck.count, 0, TOTAL_ROUNDS) and deckSum ~= view.deck.count then
                addError(errors, "deck_item_sum_mismatch", "$.deck.items", "덱 요약의 장수 합계가 덱 카드 수와 다릅니다.")
            end
        end

        if view.phase == "deckDraft" then
            if type(view.offer) ~= "table" then
                addError(errors, "missing_offer", "$.offer", "진행 중인 드래프트에는 카드 제안이 필요합니다.")
            else
                checkAllowedKeys(view.offer, { interactionToken = true, cards = true }, "$.offer", errors)
                if type(view.offer.interactionToken) ~= "string" or view.offer.interactionToken == "" then
                    addError(errors, "invalid_interaction_token", "$.offer.interactionToken", "상호작용 토큰이 필요합니다.")
                end
                local cardCount = getArrayLength(view.offer.cards, "$.offer.cards", errors)
                if cardCount ~= nil then
                    if cardCount ~= OFFER_SIZE then
                        addError(errors, "invalid_offer_size", "$.offer.cards", "카드 제안은 정확히 3장이어야 합니다.")
                    end
                    local seenCards = {}
                    for index = 1, cardCount do
                        validateOfferCard(
                            view.offer.cards[index],
                            "$.offer.cards[" .. index .. "]",
                            index,
                            deckCopies,
                            seenCards,
                            errors
                        )
                    end
                end
            end
        elseif view.offer ~= nil then
            addError(errors, "unexpected_offer", "$.offer", "완료된 드래프트에는 카드 제안이 없어야 합니다.")
        end

        if #errors > 0 then
            return failure(errors)
        end
        return success("valid", true)
    end

    local function buildGameSetupView(state, staticData, canonicalInput)
        local errors = {}
        local canonicalState = state
        if canonicalInput ~= true then
            local authorityValidation, authorityCallError = callRuntime("gameSetup", "validate", state, staticData)
            if authorityCallError then
                table.insert(errors, authorityCallError)
                return failure(errors)
            end
            if authorityValidation.ok ~= true then
                appendNestedErrors(errors, "$.state", authorityValidation)
                return failure(errors)
            end
            canonicalState = authorityValidation.state
            if type(canonicalState) ~= "table" then
                addError(errors, "invalid_authority_result", "$.state", "gameSetup.validate가 정규화된 권위 상태를 반환하지 않았습니다.")
                return failure(errors)
            end
        elseif type(canonicalState) ~= "table" then
            addError(errors, "invalid_canonical_authority", "$.state", "내부 canonical authority가 테이블이 아닙니다.")
            return failure(errors)
        end

        local data = normalizeStaticData(staticData)
        if type(data) ~= "table"
            or type(data.cards) ~= "table"
            or type(data.registry) ~= "table"
            or type(data.registry.actionTags) ~= "table"
            or type(data.registry.mechanisms) ~= "table" then
            addError(errors, "missing_static_data", "$.staticData", "gameSetupView 생성에는 검증된 카드와 태그 데이터가 필요합니다.")
            return failure(errors)
        end

        local selectedCardIds = canonicalState.selectedCardIds
        local copies = {}
        local firstSeen = {}
        for _, cardId in ipairs(selectedCardIds) do
            if copies[cardId] == nil then
                copies[cardId] = 0
                table.insert(firstSeen, cardId)
            end
            copies[cardId] = copies[cardId] + 1
        end

        local deckItems = {}
        for index, cardId in ipairs(firstSeen) do
            local card = data.cards[cardId]
            if type(card) ~= "table" or card.owner ~= "player" then
                addError(errors, "missing_player_card", "$.state.selectedCardIds[" .. index .. "]", "선택한 플레이어 카드를 찾을 수 없습니다.")
            elseif card.id ~= cardId then
                addError(errors, "card_identity_mismatch", "$.state.selectedCardIds[" .. index .. "]", "선택 카드의 DB 키와 내부 ID가 일치하지 않습니다.")
            else
                table.insert(deckItems, {
                    cardId = card.id,
                    name = card.name,
                    copies = copies[cardId],
                })
            end
        end

        local selectedCount = #selectedCardIds
        local view = {
            schemaVersion = SCHEMA_VERSION,
            kind = "gameSetupView",
            phase = canonicalState.phase,
            locked = canonicalState.phase == "deckComplete",
            progress = {
                selectedCount = selectedCount,
                totalRounds = TOTAL_ROUNDS,
                currentRound = canonicalState.phase == "deckComplete" and TOTAL_ROUNDS or selectedCount + 1,
                remainingRounds = TOTAL_ROUNDS - selectedCount,
            },
            deck = {
                count = selectedCount,
                limit = TOTAL_ROUNDS,
                items = deckItems,
            },
        }

        if canonicalState.phase == "deckDraft" then
            local offerCards = {}
            for slot, cardId in ipairs(canonicalState.offer.cardIds) do
                local cardView = buildOfferCard(slot, cardId, copies[cardId] or 0, data, errors)
                if cardView then
                    table.insert(offerCards, cardView)
                end
            end
            view.offer = {
                interactionToken = canonicalState.offer.interactionToken,
                cards = offerCards,
            }
        end

        if #errors > 0 then
            return failure(errors)
        end
        local validation = validateGameSetupView(view)
        if validation.ok ~= true then
            return validation
        end
        return success("view", view)
    end

    local arguments = { ... }
    if action == "build" then
        return buildGameSetupView(arguments[1], arguments[2])
    elseif action == "_buildCanonical" then
        -- 버튼 dispatcher는 문자열 인자만 전달할 수 있다. 이 경로는
        -- 동일 Lua transaction에서 authority를 이미 검증한 controller가
        -- 함수 capability를 전달한 경우에만 열린다.
        local permit = arguments[3]
        local permitOk = false
        if type(permit) == "function" then
            local callOk, permitted = pcall(permit, "gameSetupViewCanonicalV1")
            permitOk = callOk and permitted == true
        end
        if not permitOk then
            local errors = {}
            addError(errors, "internal_action_denied", "$.action", "내부 canonical View 작업에 접근할 수 없습니다.")
            return failure(errors)
        end
        return buildGameSetupView(arguments[1], arguments[2], true)
    elseif action == "validate" then
        return validateGameSetupView(arguments[1])
    end

    local errors = {}
    addError(errors, "unknown_action", "$", "지원하지 않는 gameSetupView 작업입니다: " .. tostring(action))
    return failure(errors)
end)
