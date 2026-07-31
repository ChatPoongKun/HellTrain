local function loadModule(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return assert(load("return " .. source, "@" .. path))()
end

local historyModule = loadModule("System/battleHistory.lua")
local staticData = {
    registry = {
        moods = {
            ignore = { id = "ignore", label = "무시" },
            suspicion = { id = "suspicion", label = "의심" },
        },
        actionTags = {
            contact = { id = "contact", label = "접촉", owner = "player" },
            vigilance = { id = "vigilance", label = "경계", owner = "character" },
        },
    },
    cards = {
        touch = { id = "touch", name = "접촉", owner = "player", actionTag = "contact" },
        watch = { id = "watch", name = "주시", owner = "character", actionTag = "vigilance" },
    },
}

local before = {
    status = "active",
    turnNumber = 1,
    lastCommittedTurnId = nil,
    player = { stealth = 30 },
    character = { resistance = 30, mood = "ignore" },
    cardInstances = {
        { instanceId = "player-001", cardId = "touch", owner = "player" },
        { instanceId = "character-001", cardId = "watch", owner = "character" },
    },
    history = { schemaVersion = 1, kind = "battleHistory", turns = {} },
}
local after = {
    status = "active",
    turnNumber = 2,
    lastCommittedTurnId = "battle-turn-001",
    player = { stealth = 27 },
    character = { resistance = 25, mood = "suspicion" },
    cardInstances = before.cardInstances,
    history = before.history,
}
local spec = {
    turnId = "battle-turn-001",
    turnNumber = 1,
    selectedCards = {
        player = { "player-001" },
        character = { "character-001" },
    },
    start = { stealth = 30, resistance = 30, mood = "ignore" },
    finish = { stealth = 27, resistance = 25, mood = "suspicion", status = "active" },
    mood = {
        before = "ignore",
        after = "suspicion",
        applied = true,
        forcedCount = 0,
        forceCancelled = false,
        resolution = "token",
    },
    events = {
        {
            sequence = 1,
            type = "card_declared",
            side = "player",
            source = { kind = "card", id = "touch", side = "player", instanceId = "player-001" },
            payload = { finalStealthCost = 0 },
        },
        {
            sequence = 2,
            type = "card_resolved",
            side = "player",
            source = { kind = "card", id = "touch", side = "player", instanceId = "player-001" },
            payload = { finalResistanceDamage = 5 },
        },
        {
            sequence = 3,
            type = "card_declared",
            side = "character",
            source = { kind = "card", id = "watch", side = "character", instanceId = "character-001" },
            payload = { finalStealthCost = 0 },
        },
        {
            sequence = 4,
            type = "card_resolved",
            side = "character",
            source = { kind = "card", id = "watch", side = "character", instanceId = "character-001" },
            payload = { finalResistanceDamage = 0 },
        },
    },
}

local appended = historyModule(nil, "appendResolvedTurn", before, after, spec, staticData)
assert(appended.ok, appended.errors[1] and appended.errors[1].message)
assert(#appended.state.history.turns == 1)
assert(appended.state.history.turns[1].tagCounts.player.resolved.contact == 1)
assert(appended.state.history.turns[1].tagCounts.character.resolved.vigilance == 1)

local publicResult = {
    schemaVersion = 1,
    events = {
        { sequence = 1, type = "card_declared", payload = { cardId = "touch" } },
        {
            sequence = 2,
            type = "effect_applied",
            payload = { op = "damage_resistance", amount = 5, before = 30, after = 25 },
        },
        {
            sequence = 3,
            type = "mood_evaluated",
            payload = { before = "ignore", after = "suspicion" },
        },
    },
}
local attached = historyModule(
    nil,
    "attachPublicResult",
    appended.state,
    "battle-turn-001",
    publicResult,
    staticData
)
assert(attached.ok, attached.errors[1] and attached.errors[1].message)
assert(attached.state.history.turns[1].publicResult.events[2].payload.amount == 5)

local context = historyModule(nil, "context", attached.state.history)
assert(context.ok)
assert(context.context.completedTurns == 1)
assert(context.context.previousTurn.startMood == "ignore")
assert(context.context.previousTurn.endMood == "suspicion")
assert(context.context.player.lastResolvedActionTag == "contact")
assert(context.context.windows[1].player.resolvedTagCounts.contact == 1)

local view = historyModule(nil, "buildPublicView", attached.state.history, staticData)
assert(view.ok)
assert(view.view.available == true)
assert(view.view.turnCount == 1)
assert(#view.view.entries >= 4)

print("battle-history-check: ok")
