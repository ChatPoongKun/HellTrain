(function(triggerId, action, targetScript, ...)
    local POPUP_VAR = "🔯🔯🔯"
    local POPUP_STATE = "popupState"
    local targetArgs = {...}

    local function emptyState()
        return {
            current = nil,
            history = {}
        }
    end

    local function getPopupState()
        local state = getState(triggerId, POPUP_STATE)

        if type(state) ~= "table" then
            return emptyState()
        end

        if type(state.history) ~= "table" then
            state.history = {}
        end

        return state
    end

    local function setPopupState(state)
        setState(triggerId, POPUP_STATE, state)

        local savedState = getState(triggerId, POPUP_STATE)
        local ok, encoded = pcall(json.encode, savedState)
        if ok then
            debug(2, "popup state saved: " .. encoded)
        end
    end

    local function clearPopupHtml()
        local uiBuilder = getChatVar(triggerId, POPUP_VAR) or ""
        uiBuilder = uiBuilder:gsub("(<!%-%- popup %-%->).-(<!%-%- popup %-%->)", "%1%2")
        setChatVar(triggerId, POPUP_VAR, uiBuilder)
    end

    local function makeEntry(script, args)
        return {
            script = script,
            args = args or {}
        }
    end

    local function argsEqual(left, right)
        left = left or {}
        right = right or {}

        if #left ~= #right then
            return false
        end

        for index, value in ipairs(left) do
            if value ~= right[index] then
                return false
            end
        end

        return true
    end

    local function entriesEqual(left, right)
        return type(left) == "table"
            and type(right) == "table"
            and left.script == right.script
            and argsEqual(left.args, right.args)
    end

    local function clearPopupState()
        setPopupState(emptyState())
    end

    local function closePopup()
        clearPopupHtml()
        clearPopupState()
    end

    local function renderPopup(entry)
        if not entry or not entry.script or entry.script == "" then
            debug(1, "popupManage error: empty target script.")
            return
        end

        clearPopupHtml()
        runScript(triggerId, entry.script, table.unpack(entry.args or {}))
    end

    local actions = {}

    actions.root = function()
        local state = getPopupState()
        local nextEntry = makeEntry(targetScript, targetArgs)

        if entriesEqual(state.current, nextEntry) then
            closePopup()
            return
        end

        local nextState = {
            current = nextEntry,
            history = {}
        }

        renderPopup(nextEntry)
        setPopupState(nextState)
    end

    actions.push = function()
        local state = getPopupState()
        local nextEntry = makeEntry(targetScript, targetArgs)

        if state.current and state.current.script then
            table.insert(state.history, state.current)
        end

        state.current = nextEntry
        renderPopup(nextEntry)
        setPopupState(state)
    end

    actions.replace = function()
        local state = getPopupState()
        local nextEntry = makeEntry(targetScript, targetArgs)

        state.current = nextEntry
        renderPopup(nextEntry)
        setPopupState(state)
    end

    actions.back = function()
        local state = getPopupState()
        local previous = table.remove(state.history)

        if not previous then
            closePopup()
            return
        end

        state.current = previous
        renderPopup(previous)
        setPopupState(state)
    end

    actions.close = function()
        closePopup()
    end

    local handler = actions[action]

    if not handler then
        debug(1, "popupManage error: unknown action " .. tostring(action))
        return
    end

    handler()
end)
