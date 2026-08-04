local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

currentHistory = nil
currentState = nil
capturedState = nil
explodeTurnInitializer = false

local moduleSources = {
    ["turnInitializer.lua"] = [[(function(triggerId, action)
        if action ~= "prepareTurn" then error("unexpected action") end
        if explodeTurnInitializer then error("expected turn initializer failure") end
        return runScript(
            triggerId,
            "battleHistory",
            "validate",
            currentHistory,
            currentState,
            {}
        )
    end)]],
    ["battleHistory.lua"] = [[(function(_, action, _, state)
        if action ~= "validate" then error("unexpected action") end
        capturedState = state
        return { ok = true, schemaVersion = 1, errors = {} }
    end)]],
}

getLoreBooks = function(_, name)
    local source = moduleSources[name]
    if source == nil then return {} end
    return { { content = source } }
end
getChatVar = function() return nil end
setChatVar = function() end
getName = function() return "test" end
getCharacterFirstMessage = function() return "hello" end
print = function() end

local chunk = assert(load(
    "return" .. readFile("System/runtime.lua"),
    "@System/runtime.lua",
    "t",
    _G
))
local runtime = chunk()
assert(type(runtime) == "function")
assert(runtime(nil, "install") == true)
runtime(nil, "beginEvent", "test")

currentHistory = {
    schemaVersion = 1,
    kind = "battleHistory",
    turns = {
        {
            turnId = "battle-001-turn-001",
            finish = {
                stealth = 20,
                resistance = 14,
                mood = "suspicion",
                status = "active",
            },
        },
    },
}
currentState = {
    status = "active",
    turnNumber = 2,
    lastCommittedTurnId = "battle-001-turn-001",
    player = { stealth = 18 },
    character = { resistance = 17, mood = "anger" },
}

local report = runtime(nil, "run", "turnInitializer", "prepareTurn")
assert(report.ok == true)
assert(capturedState ~= currentState)
assert(capturedState.player ~= currentState.player)
assert(capturedState.character ~= currentState.character)
assert(capturedState.player.stealth == 20)
assert(capturedState.character.resistance == 14)
assert(capturedState.character.mood == "suspicion")
assert(currentState.player.stealth == 18)
assert(currentState.character.resistance == 17)
assert(currentState.character.mood == "anger")

currentState.turnStartReceipt = {
    baseline = { stealth = 20, resistance = 14, mood = "suspicion" },
}
runtime(nil, "run", "turnInitializer", "prepareTurn")
assert(capturedState.character.resistance == 14)

currentState.turnStartReceipt.baseline.resistance = 999
runtime(nil, "run", "turnInitializer", "prepareTurn")
assert(capturedState == currentState)
assert(capturedState.character.resistance == 17)

currentState.turnStartReceipt = nil
runtime(nil, "run", "battleHistory", "validate", currentHistory, currentState, {})
assert(capturedState == currentState)

explodeTurnInitializer = true
local failedReport = runtime(nil, "run", "turnInitializer", "prepareTurn")
assert(failedReport == nil)
local diagnostics = runtime(nil, "diagnostics")
assert(diagnostics.turnInitializationDepth == 0)

io.stdout:write("runtime integration policy check passed\n")
