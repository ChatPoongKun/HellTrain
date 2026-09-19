(function(triggerId, action, view)
    if action ~= "render" then
        return { schemaVersion = 1, ok = false, errors = { { code = "unknown_action", path = "$.action", message = "지원하지 않는 상호작용 UI 작업입니다." } } }
    end

    local function escape(value)
        return (tostring(value == nil and "" or value):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;"))
    end

    local out = {}
    local function add(text) out[#out + 1] = text end
    local prefix = "htp-" .. tostring(view.battleId) .. "-" .. tostring(view.turnId) .. "-"
    local token = escape(view.interactionToken)
    local selection = view.selection
    local locked = view.locked == true and " disabled" or ""

    local function tag(item, class, hint)
        return '<button type="button" class="' .. class .. '" popovertarget="' .. escape(prefix .. "tag-" .. item.id)
            .. '" aria-haspopup="dialog" aria-label="' .. escape(item.label) .. hint .. '">' .. escape(item.label) .. '</button>'
    end

    local function segments(items, plain)
        for _, item in ipairs(items or {}) do
            if item.kind == "text" then
                add(escape(item.value))
            elseif item.kind == "tag" then
                if plain then
                    add(escape(item.label))
                else
                    add(tag(item, "ht-inline-tag ht-tip-trigger" .. (item.tagKind == "mechanism" and " ht-inline-tag--mechanism" or ""), " 태그 정보 보기"))
                end
            end
        end
    end

    add('<section class="ht-hand" aria-label="플레이어 손패"><div class="ht-hand-head"><h3>핸드</h3><span class="ht-hand-count">' .. escape(view.hand.count) .. '</span><div class="ht-zones">')
    add('<span>덱 ' .. escape(view.zones.deckCount) .. '</span><span>버림 ' .. escape(view.zones.discardCount) .. '</span><span>제거 ' .. escape(view.zones.removedCount) .. '</span></div></div><div class="ht-cards">')

    for _, card in ipairs(view.hand.items) do
        local focused = selection.focusedInstanceId == card.instanceId
        local name = escape(card.name)
        local choiceId = escape(prefix .. "choice-" .. card.instanceId)
        local route = 'battleController|clickCard|' .. escape(card.instanceId) .. '|' .. token
        local classes = "ht-card" .. (focused and " is-focused" or "") .. (card.selected and " is-selected" or "")
            .. (card.origin == "preview" and " is-preview" or "") .. (card.playable == false and " is-unplayable" or "")
        add('<article class="' .. classes .. '" aria-label="' .. name .. ' 카드">')
        if card.selected then
            add('<button type="button" class="ht-card-action" risu-btn="' .. route .. '" aria-label="' .. name .. ' 카드 상세 보기 및 선택" aria-expanded="' .. tostring(focused) .. '" aria-pressed="true"' .. locked .. '></button>')
        elseif card.hasEffectChoices then
            add('<button type="button" class="ht-card-action" popovertarget="' .. choiceId .. '" aria-haspopup="dialog" aria-label="' .. name .. ' 효과 선택" aria-pressed="false"' .. locked .. '></button>')
        else
            add('<button type="button" class="ht-card-action" risu-btn="' .. route .. '" aria-label="' .. name .. ' 카드 상세 보기 및 선택" aria-pressed="false"' .. locked .. '></button>')
        end
        if card.origin == "preview" then add('<span class="ht-preview-flag">DRAW PREVIEW</span>') end
        add('<span class="ht-card-top"><span class="ht-order">' .. (card.selected and escape(card.selectionOrder) or "＋") .. '</span><span class="ht-card-name"><strong>' .. name .. '</strong><span class="ht-card-tags">')
        add(tag(card.cardType, "ht-tag ht-tag--type ht-tip-trigger", " 카드 유형 정보 보기"))
        for _, role in ipairs(card.roles or {}) do add(tag(role, "ht-tag ht-tip-trigger", " 역할 정보 보기")) end
        for _, mechanism in ipairs(card.mechanisms or {}) do add(tag(mechanism, "ht-tag ht-tag--mechanism ht-tip-trigger", " 태그 정보 보기")) end
        add('</span></span><span class="ht-stat ht-stat--cost" aria-label="은폐 비용 ' .. escape(card.finalStealthCost) .. '"><b>' .. escape(card.finalStealthCost) .. '</b><small>비용</small></span>')
        add('<span class="ht-stat ht-stat--damage" aria-label="저항 피해 ' .. escape(card.finalResistanceDamage) .. '"><b>' .. escape(card.finalResistanceDamage) .. '</b><small>피해</small></span></span>')
        if focused then
            add('<span class="ht-card-detail"><span class="ht-description">')
            segments(card.descriptionSegments)
            add('</span><span class="ht-rules">')
            for _, rule in ipairs(card.ruleLines or {}) do
                add('<span>'); segments(rule.segments); add('</span>')
            end
            add('</span><span class="ht-card-help"><strong>')
            add(card.selected and "다시 누르면 선택 취소" or (card.hasEffectChoices and "누르면 사용할 효과 선택" or "누르면 상세 표시 및 사용 등록"))
            add('</strong>')
            if card.selected and card.hasEffectChoices then add('<span>선택 효과 · ' .. escape(card.selectedEffectChoice.label) .. '</span>') end
            if card.reasonCode == "insufficient_stealth" then add('<span>은폐가 부족합니다</span>') end
            if card.reasonCode == "no_available_effect_choice" then add('<span>선택 가능한 효과가 없습니다</span>') end
            add('</span></span>')
        end
        if card.hasEffectChoices then
            add('<div id="' .. choiceId .. '" class="ht-popover" popover="auto" role="dialog" aria-label="' .. name .. ' 효과 선택"><div class="ht-choice-body"><span class="ht-popover-kicker">EFFECT CHOICE</span><span class="ht-popover-title">' .. name .. '</span><span class="ht-popover-copy">이번 사용에 적용할 효과 하나를 선택하세요.</span><div class="ht-choice-options">')
            for _, choice in ipairs(card.effectChoices or {}) do
                add('<button type="button" class="ht-choice-option" risu-btn="battleController|selectCardEffect|' .. escape(card.instanceId) .. '|' .. escape(choice.id) .. '|' .. token .. '"' .. (choice.selectable == false and ' disabled aria-disabled="true"' or '') .. '><strong>' .. escape(choice.label) .. '</strong><span>')
                segments(choice.descriptionSegments, true)
                add('</span>')
                if choice.selectable == false then add('<small>' .. escape(choice.unavailableText) .. '</small>') end
                add('</button>')
            end
            add('</div><button type="button" class="ht-choice-close" popovertarget="' .. choiceId .. '" popovertargetaction="hide">닫기</button></div></div>')
        end
        add('</article>')
    end
    add('</div></section><div class="ht-footer">')
    if view.phase == "selecting" then
        add('<button type="button" class="ht-submit ht-surrender" risu-btn="battleController|surrender|' .. token .. '" aria-label="공략을 포기하고 이번 역에서 내리기"' .. locked .. '>포기하고 내리기</button>')
    end
    add('<div class="ht-selection-state">')
    if view.phase == "selecting" then add('<i class="ht-selection-dot" aria-hidden="true"></i>') end
    if view.phase == "awaitingOutput" then add('<i class="ht-selection-dot ht-selection-dot--wait" aria-hidden="true"></i>') end
    if selection.mode == "pass" then add('카드 없이 패스') end
    if selection.mode == "chain_pass" then add('연계만 사용 · 주 행동 패스') end
    if selection.mode == "action" then add(escape(selection.count) .. '장 선택됨') end
    add('</div>')
    if view.phase == "selecting" then
        if selection.submissionArmed then
            add('<button type="button" class="ht-submit is-armed" disabled aria-label="현재 카드 선택 전송 준비 완료">전송 준비됨</button>')
        else
            add('<button type="button" class="ht-submit" risu-btn="battleController|armSubmission|' .. token .. '"' .. (selection.canSubmit == false and ' disabled' or '') .. '>' .. (selection.mode == "pass" and '턴 넘기기 준비' or '선택 확정') .. '</button>')
        end
    end
    add('<div class="ht-selection-help">')
    if view.phase == "selecting" then add(selection.submissionArmed and '입력창을 비운 채 <strong>전송하면 확정</strong>' or '먼저 턴을 준비하세요') end
    if view.phase == "awaitingOutput" then add('턴 결과를 기다리는 중…') end
    if view.phase == "ended" then add('전투 종료') end
    add('</div></div>')
    return { schemaVersion = 1, ok = true, errors = {}, html = table.concat(out) }
end)
