local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {} for k, item in pairs(v) do out[k] = copy(item) end return out
end
local chain = "pc_predator_009"
local ids = {chain, chain, "pc_predator_012", "pc_predator_001", "pc_predator_002",
    "pc_predator_005", "pc_deceiver_003", "pc_glutton_007", "pc_predator_011", "pc_deceiver_012"}
local function turn(state, selected, expected)
    local options = {turnId = state.battleId .. "-turn-" .. string.format("%03d", state.turnNumber)}
    local prepared = checked("turnInitializer", "prepareTurn", state, data, options)
    local draft, used = prepared.draft, {}
    for _, cardId in ipairs(selected) do
        local instanceId
        for _, i in ipairs(prepared.state.cardInstances) do
            if i.owner == "player" and i.zone == "hand" and i.cardId == cardId and not used[i.instanceId] then
                instanceId = i.instanceId break
            end
        end
        assert(instanceId, "missing test card: " .. cardId)
        used[instanceId] = true
        draft = checked("turnDraft", "registerCard", prepared.state, data, draft, instanceId).draft
    end
    local projection = checked("turnDraft", "project", prepared.state, data, draft).projection
    local resolution = checked("turnResolver", "resolveTurn", prepared.state, data, projection, options).resolution
    local count, followupIndex = 0, nil
    for i, event in ipairs(resolution.events) do
        if event.cause and event.cause.kind == "card_followup" then
            count, followupIndex = count + 1, i
            assert(event.payload.op == "recover_stealth" and event.payload.amount == 2)
        end
    end
    assert(count == expected, "unexpected follow-up count: " .. count)
    checked("turnEventProjector", "projectTurn", prepared.state, data, resolution)
    local pending = checked("battleRuntime", "preparePending", prepared.state, data, projection).pendingTurn
    checked("battleRuntime", "reusePending", prepared.state, data, pending)
    local committed = checked("battleRuntime", "commitPending", prepared.state, data, pending)
    assert(committed.applied)
    assert(not checked("battleRuntime", "commitPending", committed.state, data, pending).applied)
    if followupIndex then
        for _, mutation in ipairs({
            function(e) e.source.instanceId = "wrong-instance" end,
            function(e) e.payload.amount = 3 end,
            function(e) e.cause.resolutionId = "wrong-resolution" end,
            function(e) e.source.id = "pc_deceiver_003" end,
            function(e) e.cause.kind = "card_effect" end, -- missing required follow-up receipt
        }) do
            local bad = copy(resolution)
            mutation(bad.events[followupIndex])
            assert(not runScript("simulation", "turnEventProjector", "projectTurn", prepared.state, data, bad).ok)
        end
    end
    return committed.state
end
local function fixture(resistance, perks)
    local state = checked("battleBootstrap", "fromSetup", {
        battleId = "followup-check", seed = 20365635, playerCardIds = ids, characterId = "yoo_jiyoung", perkIds = perks,
    }, data).state
    state.player.baseDrawCount, state.player.maxHandSize = 10, 10
    state.character.resistance = resistance or 30
    return state
end
turn(fixture(), {chain, "pc_predator_005"}, 0) -- 4 damage, below threshold
turn(fixture(), {chain, "pc_predator_012"}, 1) -- exactly 5
turn(fixture(), {chain, "pc_glutton_007"}, 1) -- 7 damage
turn(fixture(), {chain, "pc_predator_002"}, 1) -- base 3 + conditional 2
turn(fixture(), {"pc_predator_012"}, 0) -- no follow-up source
turn(fixture(), {chain, "pc_deceiver_003", "pc_predator_012"}, 0) -- next card consumes opportunity
turn(fixture(), {chain, chain, "pc_predator_012"}, 1) -- only the second chain rewards the strike
assert(turn(fixture(5), {chain, "pc_predator_012"}, 1).status == "victory")
assert(turn(fixture(4), {chain, "pc_predator_012"}, 1).status == "victory") -- existing rules count overkill damage
local state = turn(fixture(), {chain}, 0)
turn(state, {"pc_predator_012"}, 0) -- opportunity does not persist across turns
state = turn(fixture(), {"pc_predator_011"}, 0)
turn(state, {chain, "pc_predator_012"}, 1) -- card_resolved damage plan
state = turn(fixture(), {"pc_deceiver_012"}, 0)
turn(state, {chain, "pc_predator_012"}, 1) -- follow-up recovery is not the next card's own recovery

-- Four card damage plus one perk damage must not meet the card-only threshold of five.
ids[4] = "pc_glutton_001"
state = turn(fixture(100, {"perk_backlash_conversion", "perk_damage_draw"}), {chain, "pc_glutton_001"}, 0)
assert(state.history.turns[1].playerResistanceDamage == 5, "turn total still includes perk damage")
turn(fixture(100, {"perk_backlash_conversion"}), {chain, "pc_predator_012"}, 1)
