local function loadModule(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return assert(load("return " .. source, "@" .. path, "t", _G))()
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

DEBUG = 0
RUNTIME_CACHE_DEVELOPMENT_BYPASS = true

function getLoreBooks(triggerId, loreName)
    local command = "find . -type f -name " .. shellQuote(loreName) .. " -print | sort"
    local pipe = assert(io.popen(command, "r"))
    local entries = {}
    for path in pipe:lines() do
        local file = assert(io.open(path, "rb"))
        local content = file:read("*a")
        file:close()
        entries[#entries + 1] = { content = content }
    end
    pipe:close()
    return entries
end

local handlers = {}
function runScript(triggerId, moduleName, action, ...)
    if handlers[moduleName] == nil then
        handlers[moduleName] = loadModule("System/" .. moduleName .. ".lua")
    end
    return handlers[moduleName](triggerId, action, ...)
end

local function dumpErrors(label, report)
    io.stderr:write(label .. " failed\n")
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        io.stderr:write(string.format("- %s at %s: %s\n", tostring(item.code), tostring(item.path), tostring(item.message)))
    end
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        dumpErrors(label, report)
        error(label .. " failed", 0)
    end
    return report
end

local staticReport = assertOk("staticData.loadAll", runScript(nil, "staticData", "loadAll"))
local staticData = assert(staticReport.data)

local boot = assertOk("battleBootstrap.verticalSlice", runScript(nil, "battleBootstrap", "verticalSlice", {
    battleId = "hypnotic-ui-check",
    seed = 1,
}, staticData))

-- Keep all production modules and state validation in the path, but make the first
-- draw deterministic by rotating the already-valid player deck before initialization.
local hypnoticInstance
for _, instance in ipairs(boot.state.cardInstances) do
    if instance.owner == "player" and instance.zone == "deck" then
        if instance.cardId == "hypnotic_whisper" then
            hypnoticInstance = instance
            instance.position = 1
        else
            instance.position = instance.position + 1
        end
    end
end
assert(hypnoticInstance ~= nil, "hypnotic_whisper instance is missing")

local turnId = boot.state.battleId .. "-turn-001"
local initialized = assertOk("turnInitializer.prepareTurn", runScript(nil, "turnInitializer", "prepareTurn", boot.state, staticData, {
    turnId = turnId,
}))
for _, instance in ipairs(initialized.state.cardInstances) do
    if instance.instanceId == hypnoticInstance.instanceId then
        hypnoticInstance = instance
        break
    end
end
assert(hypnoticInstance.zone == "hand", "hypnotic_whisper was not drawn")

local state = initialized.state
local draft = assertOk("turnDraft.newDraft", runScript(nil, "turnDraft", "newDraft", state, staticData)).draft
local inspected = assertOk("turnDraft.inspect", runScript(nil, "turnDraft", "inspect", state, staticData, draft))
local registered = assertOk("turnDraft.applyInteraction", runScript(nil, "turnDraft", "applyInteraction", state, staticData, draft, {
    action = "register",
    instanceId = hypnoticInstance.instanceId,
    expectedInteractionToken = inspected.interactionToken,
}))
local projected = assertOk("turnDraft.project", runScript(nil, "turnDraft", "project", state, staticData, registered.draft))
local pendingReport = assertOk("battleRuntime.preparePending", runScript(nil, "battleRuntime", "preparePending", state, staticData, projected.projection))
local pending = pendingReport.pendingTurn

local eventTypes = {}
for _, event in ipairs(pending.turnResult.events) do
    eventTypes[#eventTypes + 1] = event.type .. ":" .. tostring(event.source and event.source.id or "")
end
print("events=" .. table.concat(eventTypes, ","))

local committed = assertOk("battleRuntime.commitPending", runScript(nil, "battleRuntime", "commitPending", state, staticData, pending))
assert(committed.applied == true)
assert(committed.state.status == "active")
local nextTurnId = committed.state.battleId .. "-turn-" .. string.format("%03d", committed.state.turnNumber)
local nextTurn = assertOk("turnInitializer.prepareTurn(next)", runScript(nil, "turnInitializer", "prepareTurn", committed.state, staticData, {
    turnId = nextTurnId,
}))
assert(type(nextTurn.state) == "table" and type(nextTurn.draft) == "table")
print("hypnotic runtime commit check: ok")
