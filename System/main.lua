-- RisuAI host entrypoint. Runtime and host orchestration are loaded lazily
-- because lore access requires the current event triggerId.
RUNTIME_BUNDLE_REVISION = "runtime-bundle-turn-start-history-integrated-v1-20260805"

local runtimeHandler = nil
local hostFlowHandler = nil
local UI_READY_VAR = "gameSetupReady"

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
        print(
            "bootstrap warning: duplicate lorebook '" .. loreName
                .. "'; using the last match."
        )
    end

    local chunk, compileError = load(
        "return" .. source,
        "bootstrap_lore:" .. moduleName,
        "t",
        _G
    )
    if not chunk then
        error(
            "bootstrap compile failed for " .. moduleName
                .. ": " .. tostring(compileError)
        )
    end

    local loaded, handler = pcall(chunk)
    if not loaded then
        error(
            "bootstrap load failed for " .. moduleName
                .. ": " .. tostring(handler)
        )
    end
    if type(handler) ~= "function" then
        error("bootstrap lore did not return a handler: " .. moduleName)
    end
    return handler
end

local function installBootstrapHandler(triggerId, moduleName)
    local candidate = loadBootstrapLore(triggerId, moduleName)
    local installed, result = pcall(candidate, triggerId, "install")
    if not installed or result ~= true then
        error(moduleName .. " bootstrap failed: " .. tostring(result))
    end
    return candidate
end

local function ensureBootstrap(triggerId)
    if runtimeHandler == nil then
        runtimeHandler = installBootstrapHandler(triggerId, "runtime")
    end

    if hostFlowHandler == nil then
        hostFlowHandler = loadBootstrapLore(triggerId, "hostFlow")
    end
end

local function dispatch(triggerId, mode, action, ...)
    ensureBootstrap(triggerId)
    runtimeHandler(triggerId, "beginEvent", mode)
    return hostFlowHandler(triggerId, action, ...)
end

-- commitOutput은 상태 검증 실패를 report로 반환할 수 있고, 예외 경로에서도
-- 이미 출력 관측 과정에서 기존 UI anchor가 제거되었을 수 있다. 게임 UI가
-- 활성화된 채팅에 한해 onOutput 종료 시 anchor를 멱등 복구한다.
local function restoreOutputUiAnchor(triggerId)
    if type(getChatVar) ~= "function"
        or type(ensureGameUiAnchor) ~= "function" then
        return false
    end

    local readyOk, ready = pcall(getChatVar, triggerId, UI_READY_VAR)
    if not readyOk or ready ~= "ready" then
        return false
    end

    local anchorOk, anchorError = pcall(ensureGameUiAnchor, triggerId)
    if anchorOk then
        return true
    end

    local message = "onOutput: UI anchor recovery failed: " .. tostring(anchorError)
    if type(debug) == "function" then
        debug(1, message)
    elseif type(print) == "function" then
        print(message)
    end
    return false
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
    local packed = table.pack(pcall(
        dispatch,
        triggerId,
        "onOutput",
        "output"
    ))

    -- 성공 경로에서는 기존 ensureGameUiAnchor 호출을 멱등 재사용하고,
    -- 실패 경로에서는 사라진 anchor를 즉시 다시 만든다.
    restoreOutputUiAnchor(triggerId)

    if not packed[1] then
        error(packed[2])
    end
    return table.unpack(packed, 2, packed.n)
end)
