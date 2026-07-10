(function(triggerId, mode, htmlName)
    local UI_VAR = "🔯🔯🔯"

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
            local currentUi = getChatVar(triggerId, UI_VAR) or ""
            setChatVar(triggerId, UI_VAR, currentUi .. html)
        end
    }

    local render = renderModes[mode]

    if not render then
        debug(1, "uiRender error: unknown mode " .. tostring(mode))
        return
    end

    render()
end)
