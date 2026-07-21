(function(triggerId, mode, htmlName)
    local UI_VAR = "🔯🔯🔯"
    local POPUP_VAR = "helltrainUiPopupV1"

    if not htmlName or htmlName == "" then
        debug(1, "uiRender error: empty html name.")
        return
    end

    local html = loadLores(triggerId, htmlName .. ".html")

    if not html then
        debug(1, "uiRender error: html not found " .. tostring(htmlName))
        return
    end

    local renderModes = {
        set = function()
            setChatVar(triggerId, UI_VAR, html)
        end,
        append = function()
            -- 기존 버튼 route 이름은 유지하되 popup을 기본 화면과 별도
            -- slot에 둔다. 화면 전체 문자열 복사와 regex 제거를 피한다.
            local currentPopup = getChatVar(triggerId, POPUP_VAR) or ""
            setChatVar(triggerId, POPUP_VAR, currentPopup .. html)
        end,
        popup = function()
            setChatVar(triggerId, POPUP_VAR, html)
        end
    }

    local render = renderModes[mode]

    if not render then
        debug(1, "uiRender error: unknown mode " .. tostring(mode))
        return
    end

    render()
end)
