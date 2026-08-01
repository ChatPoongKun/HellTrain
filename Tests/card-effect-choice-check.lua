local function loadModule(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return assert(load("return " .. source, "@" .. path))()
end

local function clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = clone(item) end
    return copy
end

local effectEngine = loadModule("System/effectEngine.lua")
local turnDraft = loadModule("System/turnDraft.lua")

local card = {
    id = "clear_the_air",
    owner = "player",
    actionTag = "deception",
    mechanisms = {},
    effectChoices = {
        {
            id = "remove_rejection",
            canSelect = function(context)
                if context.character.moodTokens.rejection > 0 then return true end
                return false, "no_target_token"
            end,
        },
        {
            id = "remove_suspicion",
            canSelect = function(context)
                if context.character.moodTokens.suspicion > 0 then return true end
                return false, "no_target_token"
            end,
        },
    },
    resolve = function(context)
        return {{
            op = "remove_mood_token",
            target = "character",
            mood = context.effectChoiceId == "remove_rejection" and "rejection" or "suspicion",
            amount = 1,
            cause = "cardChoice",
        }}
    end,
}

local staticData = {
    registry = {
        effectOps = { remove_mood_token = { id = "remove_mood_token" } },
        moods = {
            rejection = { id = "rejection" },
            suspicion = { id = "suspicion" },
        },
    },
    cards = { clear_the_air = card },
}

local function context(rejection, suspicion, choiceId)
    return {
        turn = 1,
        phase = "player_card",
        mood = "ignore",
        effectChoiceId = choiceId,
        player = { stealth = 30 },
        character = {
            resistance = 30,
            publicActionTag = nil,
            moodTokens = { rejection = rejection, suspicion = suspicion },
        },
        card = { id = card.id, instanceId = "player-001", owner = "player", actionTag = card.actionTag },
    }
end

assert(effectEngine(nil, "evaluateEffectChoice", staticData, card.id, "remove_rejection", context(0, 0)).selectable == false)
assert(effectEngine(nil, "evaluateEffectChoice", staticData, card.id, "remove_rejection", context(1, 0)).selectable == true)
assert(effectEngine(nil, "evaluateEffectChoice", staticData, card.id, "remove_suspicion", context(0, 1)).selectable == true)

local resolved = effectEngine(nil, "evaluateCardResolve", staticData, card.id, context(1, 0, "remove_rejection"))
assert(resolved.ok and resolved.commands[1].mood == "rejection")
local applied = effectEngine(nil, "applyCommands", staticData, {
    state = { character = { moodTokens = { rejection = 1, suspicion = 0 } } },
    transient = {},
}, resolved.commands)
assert(applied.ok and applied.state.character.moodTokens.rejection == 0)

local state = {
    battleId = "battle-001",
    status = "active",
    turnNumber = 1,
    lastCommittedTurnId = nil,
    rng = { seed = 1, cursor = 0 },
    player = { stealth = 30 },
    character = {
        resistance = 30,
        mood = "ignore",
        moodTokens = { rejection = 1, suspicion = 0 },
    },
    characterIntent = { publicActionTag = nil },
    cardInstances = {{
        instanceId = "player-001",
        cardId = card.id,
        owner = "player",
        zone = "hand",
        position = 1,
    }},
}

function runScript(triggerId, moduleName, action, ...)
    if moduleName == "stateSchema" and action == "validateBattleState" then
        return { ok = true, value = select(1, ...), referencesValidated = true }
    end
    if moduleName == "effectEngine" then
        return effectEngine(triggerId, action, ...)
    end
    if moduleName == "cardZones" and action == "moveHandToUsed" then
        local nextState = clone(select(1, ...))
        local instanceId = select(2, ...)
        for _, instance in ipairs(nextState.cardInstances) do
            if instance.instanceId == instanceId then instance.zone = "used" end
        end
        return { ok = true, state = nextState }
    end
    error("unexpected module call: " .. tostring(moduleName) .. "." .. tostring(action))
end

local fresh = turnDraft(nil, "newDraft", state, staticData)
assert(fresh.ok and next(fresh.draft.effectChoiceByInstanceId) == nil)
local inspected = turnDraft(nil, "inspect", state, staticData, fresh.draft)
assert(inspected.ok)

local chosen = turnDraft(nil, "applyInteraction", state, staticData, fresh.draft, {
    action = "choose",
    instanceId = "player-001",
    choiceId = "remove_rejection",
    expectedInteractionToken = inspected.interactionToken,
})
assert(chosen.ok and chosen.draft.effectChoiceByInstanceId["player-001"] == "remove_rejection")

local stale = turnDraft(nil, "applyInteraction", state, staticData, chosen.draft, {
    action = "cancel",
    instanceId = "player-001",
    expectedInteractionToken = inspected.interactionToken,
})
assert(stale.ok and stale.stale == true and stale.applied == false)

local cancelled = turnDraft(nil, "applyInteraction", state, staticData, chosen.draft, {
    action = "cancel",
    instanceId = "player-001",
    expectedInteractionToken = chosen.interactionToken,
})
assert(cancelled.ok and #cancelled.draft.registeredCardInstanceIds == 0)
assert(next(cancelled.draft.effectChoiceByInstanceId) == nil)

local invalid = turnDraft(nil, "applyInteraction", state, staticData, cancelled.draft, {
    action = "choose",
    instanceId = "player-001",
    choiceId = "remove_suspicion",
    expectedInteractionToken = cancelled.interactionToken,
})
assert(invalid.ok == false)

print("card effect choice check: ok")
