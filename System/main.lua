-- RisuAI host entrypoint. Runtime and host orchestration are loaded lazily
-- because lore access requires the current event triggerId.
RUNTIME_BUNDLE_REVISION = "runtime-bundle-safe-error-reroll-v1-20260826"

local hostCompatHandler = nil
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

local function ensureHostCompat(triggerId)
    if hostCompatHandler == nil then
        hostCompatHandler = installBootstrapHandler(triggerId, "hostCompat")
    end
end

local function ensureRuntime(triggerId)
    if runtimeHandler == nil then
        runtimeHandler = installBootstrapHandler(triggerId, "runtime")
    end
end

local function ensureHostFlow(triggerId)
    if hostFlowHandler == nil then
        hostFlowHandler = loadBootstrapLore(triggerId, "hostFlow")
    end
end

local function dispatch(triggerId, mode, action, ...)
    ensureHostCompat(triggerId)
    if mode ~= "editDisplay" then
        ensureRuntime(triggerId)
        runtimeHandler(triggerId, "beginEvent", mode)
    end
    ensureHostFlow(triggerId)
    return hostFlowHandler(triggerId, action, ...)
end

-- commitOutput 성공 시 알려준 응답 인덱스를 사용하고, 예외 경로에서는 최신
-- 캐릭터 메시지를 찾아 onOutput 종료 시 UI target을 한 번만 복구한다.
local function restoreOutputUiTarget(triggerId, report)
    if type(getChatVar) ~= "function"
        or type(syncGameUiTarget) ~= "function" then
        return false
    end

    local readyOk, ready = pcall(getChatVar, triggerId, UI_READY_VAR)
    if not readyOk or ready ~= "ready" then
        return false
    end

    local targetIndex = type(report) == "table" and report.uiTargetIndex or nil
    local targetOk, targetError = pcall(syncGameUiTarget, triggerId, targetIndex)
    if targetOk then
        return true
    end

    local message = "onOutput: UI target recovery failed: " .. tostring(targetError)
    if type(debug) == "function" then
        debug(1, message)
    elseif type(print) == "function" then
        print(message)
    end
    return false
end

local function outputFailureMessage(report)
    if type(report) ~= "table" or report.ok ~= false then
        return nil
    end
    local parts = { "전투 턴 확정에 실패했습니다." }
    local errors = type(report.errors) == "table" and report.errors or {}
    for _, item in ipairs(errors) do
        if type(item) == "table" then
            parts[#parts + 1] = "[" .. tostring(item.code or "error") .. "] "
                .. tostring(item.message or "알 수 없는 오류")
                .. " (" .. tostring(item.path or "$") .. ")"
        else
            parts[#parts + 1] = tostring(item)
        end
    end
    return table.concat(parts, "\n")
end

listenEdit("editDisplay", function(triggerId, data, meta)
    return dispatch(triggerId, "editDisplay", "editDisplay", data, meta)
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

    local report = packed[1] and packed[2] or nil
    restoreOutputUiTarget(triggerId, report)

    if not packed[1] then
        error(packed[2])
    end

    local failureMessage = outputFailureMessage(report)
    if failureMessage ~= nil then
        if type(debug) == "function" then
            debug(1, failureMessage)
        elseif type(print) == "function" then
            print(failureMessage)
        end
        error(failureMessage)
    end

    return table.unpack(packed, 2, packed.n)
end)
