-- Focused lifecycle checks, using a quiet opponent and a full visible hand to
-- isolate card effects. Production DB files and combat rules are not modified.
local originalData = data
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {} for k, item in pairs(v) do out[k] = copy(item) end return out
end
local ids = {"pc_deceiver_008", "pc_deceiver_004", "pc_deceiver_013", "pc_deceiver_014",
    "pc_deceiver_003", "pc_glutton_007", "pc_predator_001", "pc_predator_007",
    "pc_deceiver_010", "pc_harmonizer_001"}
local function fixture(resistance, stealth, limit)
    data = copy(originalData)
    data.characters.yoo_jiyoung.battle.turnLimit = limit or 9
    for _, card in pairs(data.cards) do
        if card.owner == "character" then
            card.resolve = function() return {} end
            card.moodEffects = nil
            if card.mechanismData and card.mechanismData.plan then
                card.mechanismData.plan.resolve = function() return {} end
            end
        end
    end
    local state = checked("battleBootstrap", "fromSetup", {
        battleId = "expiry-check", seed = 20365635, playerCardIds = ids, characterId = "yoo_jiyoung",
    }, data).state
    state.player.baseDrawCount, state.player.maxHandSize = 10, 10
    state.player.stealth, state.character.resistance = stealth or 10, resistance or 20
    checked("stateSchema", "validateBattleState", state, data)
    return state
end

local lastBefore, lastProjection, lastResolution
local function step(state, cardId)
    local options = {turnId = "expiry-turn-" .. state.turnNumber}
    local prepared = checked("turnInitializer", "prepareTurn", state, data, options)
    local draft = prepared.draft
    if cardId then
        local instanceId
        for _, instance in ipairs(prepared.state.cardInstances) do
            if instance.owner == "player" and instance.zone == "hand" and instance.cardId == cardId then
                instanceId = instance.instanceId break
            end
        end
        assert(instanceId, "missing test hand card: " .. cardId)
        draft = checked("turnDraft", "registerCard", prepared.state, data, draft, instanceId).draft
    end
    local projection = checked("turnDraft", "project", prepared.state, data, draft).projection
    local resolution = checked("turnResolver", "resolveTurn", prepared.state, data, projection, options).resolution
    local after, metrics = resolution.afterState, resolution.metrics
    local finish = after.history.turns[#after.history.turns].finish
    assert(finish.resistance == after.character.resistance and finish.stealth == after.player.stealth)
    assert(metrics.endingResistance == finish.resistance and metrics.endingStealth == finish.stealth)
    assert(metrics.resistancePerformance == metrics.startingResistance - finish.resistance)
    assert(metrics.stealthSpent == math.max(0, metrics.startingStealth - finish.stealth))
    checked("turnEventProjector", "projectTurn", prepared.state, data, resolution)
    lastBefore, lastProjection, lastResolution = prepared.state, projection, resolution
    return after
end

local function exits(resolution)
    local count = 0
    for _, event in ipairs(resolution.events) do
        if event.type == "effect_applied" and event.cause.kind == "plan_duration_exit" then
            count = count + 1
            assert(event.payload.op == "damage_resistance" and event.payload.amount == 3)
        end
    end
    return count
end

local function atExpiry(resistance, stealth, limit)
    local state = step(fixture(resistance, stealth, limit), "pc_deceiver_008")
    state = step(state)
    return step(state)
end

local function checkPending()
    local pending = checked("battleRuntime", "preparePending", lastBefore, data, lastProjection).pendingTurn
    checked("battleRuntime", "reusePending", lastBefore, data, pending)
    local first = checked("battleRuntime", "commitPending", lastBefore, data, pending)
    local second = checked("battleRuntime", "commitPending", first.state, data, pending)
    assert(first.applied == true and second.applied == false)
    assert(first.state.character.resistance == lastResolution.afterState.character.resistance)
end

local state = step(atExpiry())
assert(state.status == "active" and state.character.resistance == 17 and exits(lastResolution) == 1)
assert(#state.player.planSlots == 0)
checkPending()
local good = copy(lastResolution)
for _, event in ipairs(good.events) do
    if event.type == "effect_applied" and event.cause.kind == "plan_duration_exit" then
        event.cause.kind = "plan_explicit_exit"
    end
end
assert(not runScript("simulation", "turnEventProjector", "projectTurn", lastBefore, data, good).ok)
state = step(state)
assert(state.character.resistance == 17, "expiry must not repeat next turn")

state = step(atExpiry(3))
assert(state.status == "victory" and state.character.resistance == 0 and exits(lastResolution) == 1)
checkPending()

state = step(atExpiry(1), "pc_deceiver_003")
assert(state.status == "victory" and state.character.resistance == 0 and exits(lastResolution) == 0)
checkPending()

state = step(atExpiry(20, 6), "pc_glutton_007")
assert(state.status == "defeat" and state.player.stealth == 0 and state.character.resistance == 13,
    state.status .. " stealth=" .. state.player.stealth .. " resistance=" .. state.character.resistance)
assert(exits(lastResolution) == 0)
checkPending()

state = step(step(step(fixture(3, 10, 7))))
state = step(state, "pc_deceiver_008")
state = step(step(step(state)))
assert(state.status == "defeat" and state.character.resistance == 3 and exits(lastResolution) == 0)
checkPending()

state = step(fixture(), "pc_deceiver_008")
state = step(state, "pc_deceiver_004")
assert(state.character.resistance == 13 and #state.player.planSlots == 0 and exits(lastResolution) == 0)

state = step(fixture(), "pc_deceiver_008")
state = step(state, "pc_deceiver_013")
state = step(step(state))
assert(state.character.resistance == 20 and #state.player.planSlots == 1)
state = step(state)
assert(state.character.resistance == 17 and exits(lastResolution) == 1)

state = step(fixture(), "pc_deceiver_008")
state = step(state, "pc_deceiver_014")
assert(state.character.resistance == 18)
state = step(step(state))
assert(state.character.resistance == 15 and exits(lastResolution) == 1)

state = step(fixture(20, 30), "pc_deceiver_008")
state = step(step(state))
assert(state.character.resistance == 16 and #state.player.planSlots == 0)
state = step(state)
assert(state.character.resistance == 16 and exits(lastResolution) == 0)

state = step(fixture(), "pc_deceiver_008")
state = step(state, "pc_deceiver_010")
state = step(step(state))
assert(state.character.resistance == 20 and exits(lastResolution) == 0)

data = originalData

-- Exercise the public settlement/replay/view APIs with a legitimately drafted
-- setup and a synthetic terminal summary carrying the newly supported reason.
local setup = checked("gameSetup", "start", {setupId = "expiry-settlement", seed = 20365635}, data).state
while setup.phase == "deckDraft" do
    setup = checked("gameSetup", "choose", setup, {
        cardId = setup.offer.cardIds[1], interactionToken = setup.offer.interactionToken,
    }, data).state
end
setup = checked("gameSetup", "beginCharacterSelect", setup, data).state
setup = checked("gameSetup", "chooseCharacter", setup, {
    characterId = setup.characterOffer.characterIds[1],
    interactionToken = setup.characterOffer.interactionToken,
}, data).state
local journey = checked("subwayJourney", "build", setup.battleSpec.seed, data,
    data.characters[setup.selectedCharacterId].battle.turnLimit)
local summary = {battleId = setup.battleSpec.battleId,
    turnId = setup.battleSpec.battleId .. "-turn-004", characterId = setup.selectedCharacterId,
    status = "victory", reasonCode = "plan_exit_checkpoint", turnNumber = 4,
    turnLimit = journey.turnLimit, finalStealth = 8, finalResistance = 0, transit = journey.transit}
local settled = checked("runProgression", "settle", nil, setup, summary, data).state
checked("runProgression", "validate", settled, setup, data)
checked("runProgressionView", "build", settled, setup, data)
assert(checked("runProgression", "settle", settled, setup, summary, data).applied == false)
summary.finalResistance = 1
assert(not runScript("simulation", "runProgression", "settle", nil, setup, summary, data).ok,
    "expiry reason must not allow a victory with resistance remaining")
return {ok = true, lifecycleCases = 10, pendingCases = 5, invalidEventRejected = true}
