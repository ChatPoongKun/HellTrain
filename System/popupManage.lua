(function(triggerId, action, targetScript, ...)
    local POPUP_VAR = "helltrainUiPopupV1"
    local POPUP_STATE = "popupState"
    local targetArgs = {...}
    local ALLOWED_POPUP_HTML = {
        ["캐릭터 리스트"] = true,
        ["도감"] = true,
        ["덱 확인"] = true,
        ["플레이 가이드"] = true,
        ["설정"] = true,
    }

    local function emptyState()
        return {
            current = nil,
            history = {}
        }
    end

    local function getPopupState()
        local state = HostCompat.readState(triggerId, POPUP_STATE)

        if type(state) ~= "table" then
            return emptyState()
        end

        if type(state.history) ~= "table" then
            state.history = {}
        end

        return state
    end

    local function setPopupState(state)
        HostCompat.writeState(triggerId, POPUP_STATE, state)

        local ok, encoded = pcall(json.encode, state)
        if ok then
            debug(2, "popup state saved: " .. encoded)
        end
    end

    local function clearPopupHtml()
        HostCompat.writeChatVar(triggerId, POPUP_VAR, "")
    end

    local function makeEntry(script, args)
        return {
            script = script,
            args = args or {}
        }
    end

    local function isAllowedEntry(entry)
        if type(entry) ~= "table" or type(entry.script) ~= "string" then
            return false
        end
        local args = type(entry.args) == "table" and entry.args or {}
        if entry.script == "uiRender" then
            return (args[1] == "append" or args[1] == "popup")
                and ALLOWED_POPUP_HTML[args[2]] == true
                and args[3] == nil
        end
        if entry.script == "캐릭터 프로필" then
            return args[1] == "유지영" and args[2] == nil
        end
        return false
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
            return false
        end
        if not isAllowedEntry(entry) then
            debug(1, "popupManage error: disallowed popup target.")
            return false
        end

        clearPopupHtml()
        runScript(triggerId, entry.script, table.unpack(entry.args or {}))
        return true
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

        if not renderPopup(nextEntry) then
            return
        end
        setPopupState(nextState)
    end

    actions.push = function()
        local state = getPopupState()
        local nextEntry = makeEntry(targetScript, targetArgs)

        if state.current and state.current.script then
            table.insert(state.history, state.current)
        end

        state.current = nextEntry
        if not renderPopup(nextEntry) then
            return
        end
        setPopupState(state)
    end

    actions.replace = function()
        local state = getPopupState()
        local nextEntry = makeEntry(targetScript, targetArgs)

        state.current = nextEntry
        if not renderPopup(nextEntry) then
            return
        end
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
        if not renderPopup(previous) then
            return
        end
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
