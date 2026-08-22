(function()
    local function requireHostFunction(name, value)
        if type(value) ~= "function" then
            error(name .. " host function is unavailable")
        end
        return value
    end

    local function install()
        HostCompat = {
            readState = function(triggerId, name)
                return requireHostFunction("getState", getState)(triggerId, name)
            end,
            writeState = function(triggerId, name, value)
                local writer = type(setStateChanged) == "function" and setStateChanged or setState
                return requireHostFunction("setStateChanged/setState", writer)(triggerId, name, value)
            end,
            writeChatVar = function(triggerId, name, value)
                local writer = type(setChatVarChanged) == "function" and setChatVarChanged or setChatVar
                return requireHostFunction("setChatVarChanged/setChatVar", writer)(triggerId, name, value)
            end,
            recentChats = function(triggerId, count)
                count = math.max(0, math.floor(tonumber(count) or 0))
                if type(getRecentChats) == "function" then
                    return getRecentChats(triggerId, count)
                end
                local chat = requireHostFunction("getFullChat", getFullChat)(triggerId)
                local recent = {}
                local first = math.max(1, #chat - count + 1)
                for index = first, #chat do
                    recent[#recent + 1] = chat[index]
                end
                return recent
            end,
            chatData = function(triggerId, index)
                if type(getChatData) == "function" then
                    return getChatData(triggerId, index)
                end
                local message = requireHostFunction("getChat", getChat)(triggerId, index)
                return type(message) == "table" and message.data or ""
            end,
        }
        return true
    end

    return function(_, action)
        if action == "install" then
            return install()
        end
        error("unsupported hostCompat action: " .. tostring(action))
    end
end)()
