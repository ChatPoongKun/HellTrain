local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

local currentHistory
local currentState
local capturedState
local explodeTurnInitializer = false

runScript = function(triggerId, script, ...)
    local arguments = table.pack(...)
    if script == "turnInitializer" and arguments[1] == "prepareTurn" then
        if explodeTurnInitializer then
            error("expected turn initializer failure")
        end
        return runScript(
            triggerId,
            "battleHistory",
            "validate",
            currentHistory,
            currentState,
            {}
        )
    elseif script == "battleHistory" and arguments[1] == "validate" then
        capturedState = arguments[3]
        return {
            ok = true,
            schemaVersion = 1,
            errors = {},
        }
    end
    error("unexpected test route: " .. tostring(script))
end

local chunk = assert(load(
    "return" .. readFile("System/runtimePolicy.lua"),
    "@System/runtimePolicy.lua",
    "t",
    _G
))
local policy = chunk()
assert(type(policy) == "function")
assert(policy(nil, "install") == true)
assert(policy(nil, "install") == true)

currentHistory = {
    schemaVersion = 1,
    kind = "battleHistory",
    turns = {
        {
            turnId = "battle-001-turn-003",
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
    lastCommittedTurnId = "battle-001-turn-003",
    player = { stealth = 18 },
    character = { resistance = 17, mood = "anger" },
}

local report = runScript(nil, "turnInitializer", "prepareTurn")
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
    baseline = {
        stealth = 20,
        resistance = 14,
        mood = "suspicion",
    },
}
runScript(nil, "turnInitializer", "prepareTurn")
assert(capturedState.player.stealth == 20)
assert(capturedState.character.resistance == 14)
assert(capturedState.character.mood == "suspicion")

currentState.turnStartReceipt.baseline.resistance = 999
runScript(nil, "turnInitializer", "prepareTurn")
assert(capturedState == currentState)
assert(capturedState.character.resistance == 17)

currentState.turnStartReceipt = nil
runScript(nil, "battleHistory", "validate", currentHistory, currentState, {})
assert(capturedState == currentState)
assert(capturedState.character.resistance == 17)

explodeTurnInitializer = true
local failed, detail = pcall(runScript, nil, "turnInitializer", "prepareTurn")
assert(failed == false)
assert(tostring(detail):find("expected turn initializer failure", 1, true))
local diagnostics = policy(nil, "diagnostics")
assert(diagnostics.installed == true)
assert(diagnostics.turnInitializationDepth == 0)

print("runtime policy check passed")
