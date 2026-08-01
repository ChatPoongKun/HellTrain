local function loadModule(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return assert(load("return " .. source, "@" .. path, "t", _G))()
end

local characterSelector = loadModule("System/characterSelector.lua")
local effectEngine = loadModule("System/effectEngine.lua")

local staticData = {
    registry = {
        moods = {
            rejection = { id = "rejection", order = 1 },
            suspicion = { id = "suspicion", order = 2 },
            ignore = { id = "ignore", order = 3 },
            confusion = { id = "confusion", order = 4 },
            compliance = { id = "compliance", order = 5 },
        },
        effectOps = {
            lose_stealth = { id = "lose_stealth" },
            add_mood_token = { id = "add_mood_token" },
        },
    },
    cards = {
        plain = {
            id = "plain",
            owner = "character",
            actionTag = "vigilance",
            mechanisms = {},
            base = { stealthCost = 0, resistanceDamage = 0 },
            resolve = function()
                return { { op = "lose_stealth", target = "player", amount = 2, cause = "cardEffect" } }
            end,
        },
        suspicious = {
            id = "suspicious",
            owner = "character",
            actionTag = "vigilance",
            mechanisms = {},
            base = { stealthCost = 0, resistanceDamage = 0 },
            resolve = function()
                return {
                    { op = "lose_stealth", target = "player", amount = 2, cause = "cardEffect" },
                    { op = "add_mood_token", target = "character", mood = "suspicion", amount = 1, cause = "cardEffect" },
                }
            end,
        },
    },
}

function runScript(triggerId, moduleName, action, ...)
    if moduleName == "effectEngine" then return effectEngine(triggerId, action, ...) end
    if moduleName == "stateSchema" then
        return { ok = true, schemaVersion = 1, errors = {}, referencesValidated = true }
    end
    if moduleName == "battleHistory" then
        return { ok = true, schemaVersion = 1, errors = {}, context = {} }
    end
    if moduleName == "deterministicRng" then
        local rng, minimum = ...
        return {
            ok = true,
            schemaVersion = 1,
            errors = {},
            value = minimum,
            rng = { seed = rng.seed, cursor = rng.cursor + 1 },
        }
    end
    error("unexpected module: " .. tostring(moduleName))
end

local state = {
    status = "active",
    battleId = "battle-001",
    turnNumber = 2,
    rng = { seed = 1, cursor = 0 },
    player = { stealth = 20 },
    character = {
        characterId = "tester",
        resistance = 20,
        mood = "ignore",
        moodTokens = { rejection = 0, suspicion = 0, ignore = 0, confusion = 0, compliance = 0 },
    },
    characterIntent = { cardInstanceIds = {} },
    cardInstances = {
        { instanceId = "character-001", cardId = "plain", owner = "character", zone = "hand", position = 1 },
        { instanceId = "character-002", cardId = "suspicious", owner = "character", zone = "hand", position = 2 },
    },
}

local report = characterSelector(nil, "selectIntent", state, staticData)
assert(report.ok, report.errors and report.errors[1] and report.errors[1].message)
assert(report.receipt.candidates[1].score == 6)
assert(report.receipt.candidates[1].moodScore == 0)
assert(report.receipt.candidates[2].score == 7)
assert(report.receipt.candidates[2].moodScore == 1)
local replay = characterSelector(nil, "validateReceipt", staticData, report.receipt, state)
assert(replay.ok and replay.valid)
report.receipt.candidates[2].moodScore = 0
assert(characterSelector(nil, "validateReceipt", staticData, report.receipt, state).ok == false)

local threshold = effectEngine(nil, "projectMood", staticData, {
    turnNumber = 2,
    mood = "ignore",
    moodTokens = { rejection = 2, suspicion = 0, ignore = 0, confusion = 0, compliance = 0 },
    commands = {
        { op = "add_mood_token", mood = "rejection", amount = 1 },
    },
})
assert(threshold.ok)
assert(threshold.resolution.mood == "rejection")
assert(threshold.resolution.moodTokens.rejection == 0)
assert(threshold.resolution.stealthDelta == -3)

local tie = effectEngine(nil, "projectMood", staticData, {
    turnNumber = 2,
    mood = "ignore",
    moodTokens = { rejection = 2, suspicion = 0, ignore = 0, confusion = 0, compliance = 2 },
    commands = {
        { op = "add_mood_token", mood = "rejection", amount = 1 },
        { op = "add_mood_token", mood = "compliance", amount = 1 },
    },
})
assert(tie.ok and tie.resolution.payload.resolution == "tie")
assert(tie.resolution.mood == "ignore")
assert(tie.resolution.moodTokens.rejection == 2 and tie.resolution.moodTokens.compliance == 2)

local forced = effectEngine(nil, "projectMood", staticData, {
    turnNumber = 2,
    mood = "rejection",
    moodTokens = {},
    commands = { { op = "force_mood", mood = "compliance" } },
})
assert(forced.ok and forced.resolution.mood == "compliance" and forced.resolution.stealthDelta == 2)

local repeated = effectEngine(nil, "projectMood", staticData, {
    turnNumber = 2,
    mood = "rejection",
    moodTokens = {},
})
assert(repeated.ok and repeated.resolution.stealthDelta == -6)

print("character mood score check: ok")
