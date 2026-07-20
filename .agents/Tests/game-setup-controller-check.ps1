$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$luaCommand = Get-Command lua -ErrorAction SilentlyContinue
$luaHost = if ($luaCommand) {
    $luaCommand.Source
} else {
    Get-ChildItem "$env:USERPROFILE\.vscode\extensions\sumneko.lua-*-win32-x64\server\bin\lua-language-server.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $luaHost) { throw 'A Lua host is required. This check does not replace RisuAI integration testing.' }

$initSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'System\init.lua')
if (-not $initSource.Contains('runScript(triggerId, "gameSetupController", action, ...)')) {
    throw 'init.lua is not a thin gameSetupController route'
}
if ($initSource.Contains('setState(') -or $initSource.Contains('setChatVar(') -or $initSource.Contains('reloadDisplay(')) {
    throw 'init.lua directly owns setup host state instead of delegating it'
}

$luaTest = @'
local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadLore(path)
    return assert(load("return" .. readFile(path), "@" .. path, "t", _G))()
end

local modules = {
    deterministicRng = loadLore("System/deterministicRng.lua"),
    staticData = loadLore("System/staticData.lua"),
    gameSetup = loadLore("System/gameSetup.lua"),
    viewBuilder = loadLore("System/viewBuilder.lua"),
    gameSetupView = loadLore("System/gameSetupView.lua"),
    dataBridge = loadLore("System/dataBridge.lua"),
    gameSetupController = loadLore("System/gameSetupController.lua"),
}

local moduleCalls = {}
function runScript(triggerId, name, ...)
    moduleCalls[name] = (moduleCalls[name] or 0) + 1
    local module = assert(modules[name], "unknown module: " .. tostring(name))
    return module(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
}
function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end
function loadLores(triggerId, name)
    if name == "sideBar.html" then return readFile("html/sideBar.html") end
    if name == "cardDraft.html" then return readFile("html/cardDraft.html") end
    return nil
end

local function clone(value, active)
    if type(value) ~= "table" then return value end
    active = active or {}
    assert(not active[value], "cycle in clone fixture")
    active[value] = true
    local copy = {}
    for key, item in pairs(value) do copy[clone(key, active)] = clone(item, active) end
    active[value] = nil
    return copy
end

local function canonical(value, active)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    assert(kind == "table", "unsupported canonical type: " .. kind)
    active = active or {}
    assert(not active[value], "cycle in canonical fixture")
    active[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        return type(left) .. ":" .. tostring(left) < type(right) .. ":" .. tostring(right)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = canonical(key, active) .. "=" .. canonical(value[key], active)
    end
    active[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local messages = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path) .. ": " .. tostring(item.message)
        end
        error(label .. " failed | " .. table.concat(messages, " | "))
    end
    assert(report.schemaVersion == 1 and type(report.errors) == "table" and #report.errors == 0,
        label .. " returned an invalid success envelope")
    return report
end

local function hasError(report, code)
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        if item.code == code then return true end
    end
    return false
end

local function assertFailed(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.schemaVersion == 1 and type(report.errors) == "table" and #report.errors > 0,
        label .. " must return a structured failure")
    for _, item in ipairs(report.errors) do
        assert(type(item.code) == "string" and item.code ~= "", label .. " error code missing")
        assert(type(item.path) == "string" and item.path ~= "", label .. " error path missing")
        assert(type(item.message) == "string" and item.message ~= "", label .. " error message missing")
    end
    assert(hasError(report, expectedCode), label .. " missing error code " .. expectedCode)
    return report
end

local AUTHORITY = "gameSetupV1.authority"
local VIEW = "gameSetupView"
local READY = "gameSetupReady"
-- Keep this byte-exact when PowerShell pipes the Lua fixture to a fallback host.
local UI = string.char(240, 159, 148, 175):rep(3)
local states = {}
local chatVars = {}
local events = {}
local stateWrites = 0
local reloads = 0
local cbsCalls = 0
local cbsValue = "12345"
local cbsThrows = false
local dropStateWrite = false
local dropChatKey
local dropReadyValue

local function record(value) events[#events + 1] = value end
function setState(triggerId, key, value)
    stateWrites = stateWrites + 1
    record("state:" .. key)
    if dropStateWrite then dropStateWrite = false return end
    states[key] = clone(value)
end
function getState(triggerId, key)
    record("get-state:" .. key)
    return clone(states[key])
end
function setChatVar(triggerId, key, value)
    record("chat:" .. key .. ":" .. (key == READY and tostring(value) or "value"))
    if dropChatKey == key then dropChatKey = nil return end
    if key == READY and dropReadyValue == value then dropReadyValue = nil return end
    chatVars[key] = value
end
function getChatVar(triggerId, key)
    record("get-chat:" .. key)
    return chatVars[key]
end
function reloadDisplay(triggerId)
    reloads = reloads + 1
    record("reload")
end
function cbs(source)
    cbsCalls = cbsCalls + 1
    assert(source == "{{randint::1::2147483646}}", "controller used an unexpected seed macro")
    if cbsThrows then error("injected cbs failure") end
    return cbsValue
end
function alertError() end

local originalHosts = {
    setState = setState,
    getState = getState,
    setChatVar = setChatVar,
    getChatVar = getChatVar,
    reloadDisplay = reloadDisplay,
    cbs = cbs,
    loadLores = loadLores,
}

local function reset(seed)
    states = {}
    chatVars = {}
    events = {}
    stateWrites = 0
    reloads = 0
    cbsCalls = 0
    cbsValue = seed or "12345"
    cbsThrows = false
    dropStateWrite = false
    dropChatKey = nil
    dropReadyValue = nil
    setState = originalHosts.setState
    getState = originalHosts.getState
    setChatVar = originalHosts.setChatVar
    getChatVar = originalHosts.getChatVar
    reloadDisplay = originalHosts.reloadDisplay
    cbs = originalHosts.cbs
    loadLores = originalHosts.loadLores
end

local function controller(action, ...)
    return modules.gameSetupController("game-setup-controller-check", action, ...)
end

local function writeEvents()
    local selected = {}
    for _, event in ipairs(events) do
        if string.sub(event, 1, 6) == "state:"
            or string.sub(event, 1, 5) == "chat:"
            or event == "reload" then
            selected[#selected + 1] = event
        end
    end
    return selected
end

local function assertWriteOrder(label, expected)
    local actual = writeEvents()
    assert(#actual == #expected, label .. " write count changed: " .. table.concat(actual, ","))
    for index, value in ipairs(expected) do
        assert(actual[index] == value,
            label .. " write order mismatch at " .. index .. ": " .. tostring(actual[index]) .. " ~= " .. value)
    end
end

local fullWriteOrder = {
    "chat:" .. READY .. ":updating",
    "state:" .. AUTHORITY,
    "chat:" .. VIEW .. ":value",
    "chat:" .. UI .. ":value",
    "chat:" .. READY .. ":ready",
    "reload",
}
local publishOnlyOrder = {
    "chat:" .. READY .. ":updating",
    "chat:" .. VIEW .. ":value",
    "chat:" .. UI .. ":value",
    "chat:" .. READY .. ":ready",
    "reload",
}

-- Fresh start consumes exactly one CBS randint and publishes only verified data.
reset("12345")
local started = assertOk("fresh start", controller("start"))
assert(started.action == "start" and started.applied == true and started.stale == false)
assert(cbsCalls == 1, "fresh start must call cbs exactly once")
assert(states[AUTHORITY].setupId == "setup-12345" and states[AUTHORITY].rng.seed == 12345,
    "generated seed/setupId were not persisted")
assert(chatVars[READY] == "ready" and type(chatVars[VIEW]) == "string" and chatVars[VIEW] ~= "",
    "fresh start did not publish a ready View")
assert(chatVars[UI] == readFile("html/sideBar.html") .. readFile("html/cardDraft.html"),
    "fresh start UI anchor is not sidebar plus card draft; actual=" .. tostring(type(chatVars[UI]) == "string" and #chatVars[UI] or -1)
        .. ", expected=" .. tostring(#readFile("html/sideBar.html") + #readFile("html/cardDraft.html")))
assert(reloads == 1, "fresh start did not reload exactly once")
assertWriteOrder("fresh start", fullWriteOrder)
local storedSnapshot = canonical(states[AUTHORITY])
local storedWrites = stateWrites
started.state.selectedCardIds[1] = "mutated_result_canary"
assert(canonical(states[AUTHORITY]) == storedSnapshot, "returned start state aliases host authority")

-- Restart/recovery validates and republishes without a new seed or authority write.
events = {}
local restarted = assertOk("idempotent restart", controller("start"))
assert(restarted.applied == false and restarted.stale == false)
assert(cbsCalls == 1, "restart consumed another CBS seed")
assert(stateWrites == storedWrites and canonical(states[AUTHORITY]) == storedSnapshot,
    "restart rewrote or changed authority")
assert(reloads == 2, "restart did not reload once")
assertWriteOrder("idempotent restart", publishOnlyOrder)

-- A valid choice is stored once. Repeating the old token is a state-write-free stale recovery.
local beforeChoice = clone(states[AUTHORITY])
local chosenCard = beforeChoice.offer.cardIds[1]
local oldToken = beforeChoice.offer.interactionToken
events = {}
local chosen = assertOk("valid choose", controller("choose", chosenCard, oldToken))
assert(chosen.applied == true and chosen.stale == false and #states[AUTHORITY].selectedCardIds == 1,
    "valid choose was not persisted once")
assert(cbsCalls == 1, "choose consumed a setup seed")
assertWriteOrder("valid choose", fullWriteOrder)
local afterChoiceSnapshot = canonical(states[AUTHORITY])
local writesAfterChoice = stateWrites
events = {}
local stale = assertOk("stale double click", controller("choose", chosenCard, oldToken))
assert(stale.applied == false and stale.stale == true, "old token was not a successful stale no-op")
assert(canonical(states[AUTHORITY]) == afterChoiceSnapshot and stateWrites == writesAfterChoice,
    "stale double click wrote authority")
assert(cbsCalls == 1, "stale recovery consumed a setup seed")
assertWriteOrder("stale double click", publishOnlyOrder)

-- Finish all ten rounds through the controller, preserving the setup seed.
local finalCard
local finalToken
while states[AUTHORITY].phase == "deckDraft" do
    local current = clone(states[AUTHORITY])
    finalCard = current.offer.cardIds[1]
    finalToken = current.offer.interactionToken
    local report = assertOk("choose round " .. current.offer.round,
        controller("choose", finalCard, finalToken))
    assert(report.applied == true and report.stale == false, "draft round was not applied")
end
assert(states[AUTHORITY].phase == "deckComplete" and #states[AUTHORITY].selectedCardIds == 10,
    "controller did not persist a ten-card completed deck")
assert(states[AUTHORITY].offer == nil, "completed setup retained an offer")
assert(cbsCalls == 1, "ten-round draft consumed another setup seed")
local completedSnapshot = canonical(states[AUTHORITY])
local completedWrites = stateWrites
events = {}
local finalStale = assertOk("tenth choice double click", controller("choose", finalCard, finalToken))
assert(finalStale.applied == false and finalStale.stale == true,
    "tenth choice double click was not a successful stale no-op")
assert(canonical(states[AUTHORITY]) == completedSnapshot and stateWrites == completedWrites,
    "tenth choice double click rewrote completed authority")
assertWriteOrder("tenth choice double click", publishOnlyOrder)
local completed = assertOk("restart completed setup", controller("start"))
assert(completed.view.phase == "deckComplete" and completed.view.offer == nil and completed.view.deck.count == 10,
    "completed setup did not recover as a deckComplete View")
assert(cbsCalls == 1, "completed setup recovery consumed another setup seed")

-- Authority may be committed before a later publication failure. Restart must reuse it.
reset("24680")
dropChatKey = VIEW
local failedView = assertFailed("dropped View publication", controller("start"), "view_write_not_persisted")
assert(type(states[AUTHORITY]) == "table" and states[AUTHORITY].rng.seed == 24680,
    "publication failure lost its verified authority")
assert(cbsCalls == 1 and reloads == 0 and chatVars[READY] ~= "ready",
    "failed publication reloaded/marked ready or consumed the wrong seed count")
local failedAuthority = canonical(states[AUTHORITY])
local failedWrites = stateWrites
local recovered = assertOk("recover persisted start", controller("start"))
assert(recovered.applied == false and canonical(states[AUTHORITY]) == failedAuthority,
    "publication recovery replaced authority")
assert(cbsCalls == 1 and stateWrites == failedWrites,
    "publication recovery generated a new seed or rewrote authority")

local function assertFailureBoundary(label, report, expectedCode)
    assertFailed(label, report, expectedCode)
    assert(reloads == 0, label .. " reloaded the display")
    assert(chatVars[READY] ~= "ready", label .. " marked setup ready")
end

-- Seed provider boundaries: no fallback randomness and no persisted authority.
local function seedFailure(label, value, throws, missing, expectedCode)
    reset(value)
    cbsThrows = throws == true
    if missing then cbs = nil end
    assertFailureBoundary(label, controller("start"), expectedCode)
    assert(states[AUTHORITY] == nil and stateWrites == 0, label .. " persisted authority")
    assert(cbsCalls == (missing and 0 or 1), label .. " called cbs an unexpected number of times")
end
seedFailure("missing cbs", "1", false, true, "cbs_unavailable")
seedFailure("throwing cbs", "1", true, false, "seed_generation_failed")
seedFailure("NaN seed", "NaN", false, false, "invalid_generated_seed")
seedFailure("fraction seed", "1.5", false, false, "invalid_generated_seed")
seedFailure("zero seed", "0", false, false, "invalid_generated_seed")
seedFailure("out of range seed", "2147483647", false, false, "generated_seed_out_of_range")

-- Corrupt authority is rejected without replacement or a seed retry.
reset("333")
assertOk("corruption fixture", controller("start"))
states[AUTHORITY].rng.cursor = states[AUTHORITY].rng.cursor + 1
local corruptSnapshot = canonical(states[AUTHORITY])
chatVars[READY] = nil
reloads = 0
local callsBeforeCorrupt = cbsCalls
local writesBeforeCorrupt = stateWrites
assertFailureBoundary("corrupt authority", controller("start"), "setup_state_replay_mismatch")
assert(canonical(states[AUTHORITY]) == corruptSnapshot and stateWrites == writesBeforeCorrupt,
    "corrupt authority was overwritten")
assert(cbsCalls == callsBeforeCorrupt, "corrupt authority triggered a new seed")

-- Every host persistence boundary is read back; mismatch never reloads or marks ready.
reset("444")
dropStateWrite = true
assertFailureBoundary("authority write mismatch", controller("start"), "state_write_not_persisted")

reset("445")
dropChatKey = VIEW
assertFailureBoundary("View write mismatch", controller("start"), "view_write_not_persisted")

reset("446")
dropChatKey = UI
assertFailureBoundary("UI write mismatch", controller("start"), "chat_var_write_not_persisted")

reset("447")
dropReadyValue = "ready"
assertFailureBoundary("ready write mismatch", controller("start"), "chat_var_write_not_persisted")

-- Once CBS has issued a seed, even build/View/lore failures retain that exact
-- authority so retry never rolls a different initial offer.
reset("448")
local realGameSetupView = modules.gameSetupView
modules.gameSetupView = function() error("injected module exception") end
assertFailureBoundary("module exception", controller("start"), "module_call_error")
assert(type(states[AUTHORITY]) == "table" and states[AUTHORITY].rng.seed == 448,
    "module exception did not retain the generated authority")
assert(cbsCalls == 1, "module exception consumed an unexpected seed count")
local moduleFailureState = canonical(states[AUTHORITY])
local moduleFailureWrites = stateWrites
modules.gameSetupView = realGameSetupView
local moduleRecovered = assertOk("module exception retry", controller("start"))
assert(moduleRecovered.applied == false and canonical(states[AUTHORITY]) == moduleFailureState,
    "module exception retry replaced authority")
assert(cbsCalls == 1 and stateWrites == moduleFailureWrites,
    "module exception retry rerolled or rewrote authority")

reset("4481")
local realLoadLores = loadLores
loadLores = function() error("injected lore exception") end
assertFailureBoundary("lore exception", controller("start"), "lore_load_failed")
assert(type(states[AUTHORITY]) == "table" and states[AUTHORITY].rng.seed == 4481,
    "lore exception did not retain the generated authority")
assert(cbsCalls == 1, "lore exception consumed an unexpected seed count")
local loreFailureState = canonical(states[AUTHORITY])
local loreFailureWrites = stateWrites
loadLores = realLoadLores
local loreRecovered = assertOk("lore exception retry", controller("start"))
assert(loreRecovered.applied == false and canonical(states[AUTHORITY]) == loreFailureState,
    "lore exception retry replaced authority")
assert(cbsCalls == 1 and stateWrites == loreFailureWrites,
    "lore exception retry rerolled or rewrote authority")

-- Absent host functions are contained in structured failures.
reset("449")
setState = nil
assertFailureBoundary("missing state host", controller("start"), "host_function_unavailable")
assert(states[AUTHORITY] == nil, "missing host persisted authority")

reset("450")
getChatVar = nil
assertFailureBoundary("missing chat host", controller("start"), "host_function_unavailable")
assert(states[AUTHORITY] == nil, "missing chat host persisted authority")

-- Failed commands and returned values do not mutate the authority input supplied by the host.
reset("451")
local immutabilityStart = assertOk("immutability fixture", controller("start"))
local immutableSnapshot = canonical(states[AUTHORITY])
local badCard = "not_in_offer"
chatVars[READY] = nil
reloads = 0
assertFailureBoundary("invalid card", controller("choose", badCard,
    states[AUTHORITY].offer.interactionToken), "card_not_in_current_offer")
assert(canonical(states[AUTHORITY]) == immutableSnapshot, "failed choose mutated stored authority")
immutabilityStart.view.phase = "mutated_view_canary"
assert(canonical(states[AUTHORITY]) == immutableSnapshot, "returned View aliases stored authority")

print("game-setup-controller-check: ok")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[game-setup-controller-check]],[[t]],_G))()'
    $output = $luaTest | & $luaHost -e $luaEntry 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    $output
}
finally {
    Pop-Location
}
