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
            -- 기존 버튼 route 이름은 호환용으로 유지한다. popup slot은 한 번에
            -- 하나의 창만 소유하므로 append도 교체로 처리한다.
            setChatVar(triggerId, POPUP_VAR, html)
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
