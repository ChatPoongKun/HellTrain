-- RisuAI host entrypoint. Runtime and host orchestration are loaded lazily
-- because lore access requires the current event triggerId.
local runtimeHandler = nil
local hostFlowHandler = nil

local function loadBootstrapLore(triggerId, moduleName)
    local loreName = moduleName .. ".lua"
    local matches = getLoreBooks(triggerId, loreName)
    if type(matches) ~= "table" then
        error("bootstrap lore lookup failed: " .. loreName)
    end

    local source = nil
    local sourceCount = 0
    for _, entry in ipairs(matches) do
        local content = type(entry) == "table" and entry.content or nil
        if type(content) == "string" and content ~= "" then
  sourceCount = sourceCount + 1
  source = content
        end
    end
    if source == nil then
        error("bootstrap lore not found: " .. loreName)
    end
    if sourceCount > 1 and type(print) == "function" then
        print("bootstrap warning: duplicate lorebook '" .. loreName
  .. "'; using the last match.")
    end

    local chunk, compileError = load(
        "return" .. source,
        "bootstrap_lore:" .. moduleName,
        "t",
        _G
    )
    if not chunk then
        error("bootstrap compile failed for " .. moduleName
  .. ": " .. tostring(compileError))
    end

    local loaded, handler = pcall(chunk)
    if not loaded then
        error("bootstrap load failed for " .. moduleName
  .. ": " .. tostring(handler))
    end
    if type(handler) ~= "function" then
        error("bootstrap lore did not return a handler: " .. moduleName)
    end
    return handler
end

local function ensureBootstrap(triggerId)
    if runtimeHandler ~= nil and hostFlowHandler ~= nil then
        return
    end

    runtimeHandler = loadBootstrapLore(triggerId, "runtime")
    local installed, result = pcall(runtimeHandler, triggerId, "install")
    if not installed or result ~= true then
        runtimeHandler = nil
        error("runtime bootstrap failed: " .. tostring(result))
    end

    local loaded, handler = pcall(loadBootstrapLore, triggerId, "hostFlow")
    if not loaded then
        runtimeHandler = nil
        error(tostring(handler))
    end
    hostFlowHandler = handler
end

local function dispatch(triggerId, mode, action, ...)
    ensureBootstrap(triggerId)
    runtimeHandler(triggerId, "beginEvent", mode)
    return hostFlowHandler(triggerId, action, ...)
end

listenEdit("editDisplay", function(triggerId, data, meta)
    return dispatch(triggerId, "editDisplay", "editDisplay", data, meta)
end)

listenEdit("editInput", function(triggerId, data)
    return dispatch(triggerId, "editInput", "editInput", data)
end)

onButtonClick = async(function(triggerId, data)
    return dispatch(triggerId, "onButtonClick", "buttonClick", data)
end)

listenEdit("editRequest", function(triggerId, data)
    return dispatch(triggerId, "editRequest", "editRequest", data)
end)

onStart = async(function(triggerId)
    return dispatch(triggerId, "onStart", "start")
end)

onOutput = async(function(triggerId)
    return dispatch(triggerId, "onOutput", "output")
end)
