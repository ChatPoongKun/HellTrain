local trials = tonumber(rawget(_G, "SIM_TRIALS")) or 200
assert(trials >= 1 and trials % 1 == 0, "SIM_TRIALS must be a positive integer")

local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadLore(path)
    local source = readFile(path)
    if path == "System/subwayJourney.lua" or path == "System/battleHistory.lua" then
        source = assert(source:gsub("local MAX_TURNS = 12", "local MAX_TURNS = 13", 1))
    elseif path == "System/stateSchema.lua" then
        source = assert(source:gsub("state.turnLimit > 12", "state.turnLimit > 13", 1))
    end
    return assert(load("return" .. source, "@" .. path, "t", _G))()
end

local modules = {}
for _, name in ipairs({
    "battleBootstrap", "battleHistory", "cardZones", "characterSelector",
    "deterministicRng", "effectEngine", "stateSchema", "staticData",
    "subwayJourney", "triggerPipeline", "turnDraft", "turnInitializer", "turnResolver",
}) do
    modules[name] = loadLore("System/" .. name .. ".lua")
end

function runScript(triggerId, name, ...)
    return assert(modules[name], "unknown module: " .. tostring(name))(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["TokyoSubwayLines.db"] = "DB/TokyoSubwayLines.db",
    ["CharacterList.db"] = "Char/CharacterList.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
    ["YoonSeoa.db"] = "Char/YoonSeoa.db",
    ["HanJenny.db"] = "Char/HanJenny.db",
    ["SeoMiryeong.db"] = "Char/SeoMiryeong.db",
    ["SisterAgnes.db"] = "Char/SisterAgnes.db",
}

function getLoreBooks(_, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end

function loadLores(triggerId, name)
    local chunks = {}
    for _, lore in ipairs(getLoreBooks(triggerId, name)) do chunks[#chunks + 1] = lore.content end
    return #chunks > 0 and table.concat(chunks) or nil
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local messages = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            messages[#messages + 1] = tostring(item.code) .. "@" .. tostring(item.path)
        end
        error(label .. " failed: " .. table.concat(messages, ","))
    end
    return report
end

local data = assertOk("static data", runScript("turn-sensitivity", "staticData", "loadAll")).data
data.environments.no_environment = {
    id = "no_environment",
    name = "환경 효과 없음",
    description = "턴 민감도 분석 전용 환경입니다.",
    rules = {},
    triggers = {},
}

local decks = {
    {
        id = "tempo_payoff",
        cards = {
            "p009_grind_hips", "p009_grind_hips",
            "p012_check_passenger_gazes", "p012_check_passenger_gazes",
            "p020_dominate_with_gaze", "p020_dominate_with_gaze",
            "p044_overwhelm_both_halves", "p044_overwhelm_both_halves",
            "p045_press_between_thighs", "p047_unhesitating_touch",
        },
    },
    {
        id = "direct_damage",
        cards = {
            "p005_blame_the_crowd", "p005_blame_the_crowd",
            "p009_grind_hips", "p009_grind_hips",
            "p021_fake_accidental_brush", "p021_fake_accidental_brush",
            "p036_obscene_whisper", "p036_obscene_whisper",
            "p038_twist_arm_behind_back", "p038_twist_arm_behind_back",
        },
    },
    {
        id = "survival_shift",
        cards = {
            "p004_press_from_behind", "p004_press_from_behind",
            "p007_feign_indifference", "p007_feign_indifference",
            "p017_grope_behind_the_crowd", "p017_grope_behind_the_crowd",
            "p020_dominate_with_gaze", "p020_dominate_with_gaze",
            "p024_pin_by_force", "p024_pin_by_force",
        },
    },
}
local requestedDeck = rawget(_G, "SIM_DECK")
if requestedDeck ~= nil then
    local filtered = {}
    for _, deck in ipairs(decks) do
        if deck.id == requestedDeck then filtered[#filtered + 1] = deck end
    end
    assert(#filtered == 1, "unknown SIM_DECK: " .. tostring(requestedDeck))
    decks = filtered
end

local characters = {
    { id = "han_jenny", turns = 8 },
    { id = "yoo_jiyoung", turns = 9 },
    { id = "seo_miryeong", turns = 11 },
    { id = "sister_agnes", turns = 12 },
    { id = "yoon_seoa", turns = 12 },
}

local function effectiveCost(card, mood)
    local moodCosts = card.stealthCostByMood
    return type(moodCosts) == "table" and moodCosts[mood] or card.base.stealthCost
end

local function mainScore(cardId, state)
    local card = data.cards[cardId]
    local mood = state.character.mood
    local cost = effectiveCost(card, mood)
    if state.player.stealth <= cost then return -math.huge end
    if cardId == "p024_pin_by_force" and mood ~= "rejection" and mood ~= "suspicion" then
        return -math.huge
    end

    local score = card.base.resistanceDamage * 100 - cost * 8
    if cardId == "p007_feign_indifference" then
        score = score + 150
        if mood == "rejection" or mood == "suspicion" then score = score + 80 end
        if state.player.stealth <= 15 then score = score + 250 end
    elseif cardId == "p020_dominate_with_gaze" then
        if mood == "rejection" or mood == "suspicion" then score = score + 120 end
        if state.player.stealth <= 15 then score = score + 300 end
    elseif cardId == "p017_grope_behind_the_crowd" and mood == "suspicion" then
        score = score + 150
    elseif cardId == "p024_pin_by_force" then
        score = score + (state.player.stealth <= 7 and 180 or 40)
    elseif cardId == "p036_obscene_whisper" then
        local tag = state.characterIntent.publicActionTag
        if tag == "vigilance" or tag == "block" then score = score + 300 end
    elseif cardId == "p041_reach_under_skirt" then
        if mood == "compliance" then score = score + 400
        elseif mood == "confusion" then score = score + 200 end
    elseif cardId == "p043_finger_penetration" and mood == "compliance" then
        score = score + 400
    elseif cardId == "p044_overwhelm_both_halves" and mood ~= "compliance" then
        score = score + 70
    elseif cardId == "p045_press_between_thighs" or cardId == "p047_unhesitating_touch" then
        if mood == "compliance" then score = score + 500
        elseif mood == "confusion" then score = score + 200 end
    end
    return score
end

local function playerHand(state)
    local hand = {}
    for _, instance in ipairs(state.cardInstances) do
        if instance.owner == "player" and instance.zone == "hand" then hand[#hand + 1] = instance end
    end
    table.sort(hand, function(left, right) return left.instanceId < right.instanceId end)
    return hand
end

local function chooseDraft(state, draft)
    local spent = 0
    for _, instance in ipairs(playerHand(state)) do
        local card = data.cards[instance.cardId]
        local chain = false
        for _, mechanism in ipairs(card.mechanisms or {}) do chain = chain or mechanism == "chain" end
        local allowed = instance.cardId ~= "p004_press_from_behind"
            or state.character.mood == "rejection"
            or state.character.mood == "suspicion"
            or state.player.stealth >= 5
        local cost = effectiveCost(card, state.character.mood)
        if chain and allowed and state.player.stealth - spent > cost then
            local report = assertOk(
                "register chain",
                runScript("turn-sensitivity", "turnDraft", "registerCard", state, data, draft, instance.instanceId)
            )
            draft = report.draft
            spent = spent + cost
        end
    end

    local candidates = {}
    for _, instance in ipairs(playerHand(state)) do
        local card = data.cards[instance.cardId]
        local chain = false
        for _, mechanism in ipairs(card.mechanisms or {}) do chain = chain or mechanism == "chain" end
        if not chain then
            candidates[#candidates + 1] = { instance = instance, score = mainScore(instance.cardId, state) }
        end
    end
    table.sort(candidates, function(left, right)
        return left.score > right.score
            or (left.score == right.score and left.instance.instanceId < right.instance.instanceId)
    end)
    for _, candidate in ipairs(candidates) do
        local card = data.cards[candidate.instance.cardId]
        if candidate.score > -math.huge and state.player.stealth - spent > effectiveCost(card, state.character.mood) then
            draft = assertOk(
                "register main",
                runScript("turn-sensitivity", "turnDraft", "registerCard", state, data, draft, candidate.instance.instanceId)
            ).draft
            break
        end
    end
    return draft
end

local function simulate(deck, character, turnLimit, seed, trial)
    local battle = data.characters[character.id].battle
    local originalTurnLimit = battle.turnLimit
    battle.turnLimit = turnLimit
    local bootstrap = assertOk(
        "bootstrap",
        runScript("turn-sensitivity", "battleBootstrap", "fromSetup", {
            battleId = "sim-" .. deck.id .. "-" .. character.id .. "-" .. turnLimit .. "-" .. trial,
            seed = seed,
            playerCardIds = deck.cards,
            characterId = character.id,
            environmentId = "no_environment",
        }, data)
    )
    battle.turnLimit = originalTurnLimit

    local state = bootstrap.state
    local trace = {}
    while state.status == "active" do
        local turnId = state.battleId .. "-turn-" .. string.format("%03d", state.turnNumber)
        local initialized = assertOk(
            "initialize",
            runScript("turn-sensitivity", "turnInitializer", "prepareTurn", state, data, { turnId = turnId })
        )
        local draft = chooseDraft(initialized.state, initialized.draft)
        local projection = assertOk(
            "project",
            runScript("turn-sensitivity", "turnDraft", "project", initialized.state, data, draft, nil)
        ).projection
        local resolved = assertOk(
            "resolve",
            runScript("turn-sensitivity", "turnResolver", "resolveTurn", initialized.state, data, projection, { turnId = turnId })
        )
        state = resolved.resolution.afterState
        trace[#trace + 1] = {
            win = state.status == "victory",
            resistance = state.character.resistance,
            stealth = state.player.stealth,
        }
        assert(#trace <= turnLimit, "battle exceeded turn limit")
    end
    return trace
end

print("CELL,deck,character,delta,turnLimit,trials,wins,winRate,avgTurns,avgLossResistance,stealthLosses")
local outcomes = {}
for deckIndex, deck in ipairs(decks) do
    outcomes[deck.id] = {}
    for characterIndex, character in ipairs(characters) do
        local cells = {}
        outcomes[deck.id][character.id] = cells
        for delta = -1, 1 do
            cells[delta] = { wins = 0, turns = 0, lossResistance = 0, losses = 0, stealthLosses = 0, byTrial = {} }
        end
        for trial = 1, trials do
            local seed = 1000000 * deckIndex + 10000 * characterIndex + trial
            -- Combat is independent of the route; one +1-turn trace contains the exact paired
            -- prefixes for the shorter limits and avoids running the same turns three times.
            local trace = simulate(deck, character, character.turns + 1, seed, trial)
            for delta = -1, 1 do
                local cell = cells[delta]
                local cutoff = character.turns + delta
                local turn = math.min(cutoff, #trace)
                local result = trace[turn]
                local win = result.win == true
                cell.byTrial[trial] = win
                cell.turns = cell.turns + turn
                if win then
                    cell.wins = cell.wins + 1
                else
                    cell.losses = cell.losses + 1
                    cell.lossResistance = cell.lossResistance + result.resistance
                    if result.stealth <= 0 then cell.stealthLosses = cell.stealthLosses + 1 end
                end
            end
        end
        for delta = -1, 1 do
            local cell = cells[delta]
            print(table.concat({
                "CELL", deck.id, character.id, delta, character.turns + delta, trials, cell.wins,
                string.format("%.6f", cell.wins / trials), string.format("%.3f", cell.turns / trials),
                string.format("%.3f", cell.losses > 0 and cell.lossResistance / cell.losses or 0),
                cell.stealthLosses,
            }, ","))
        end
    end
end

print("PAIR,deck,character,fromDelta,toDelta,rescued,lost,rateDelta")
for _, deck in ipairs(decks) do
    for _, character in ipairs(characters) do
        local cells = outcomes[deck.id][character.id]
        for fromDelta = -1, 0 do
            local rescued, lost = 0, 0
            for trial = 1, trials do
                local before = cells[fromDelta].byTrial[trial]
                local after = cells[fromDelta + 1].byTrial[trial]
                if not before and after then rescued = rescued + 1 end
                if before and not after then lost = lost + 1 end
            end
            print(table.concat({
                "PAIR", deck.id, character.id, fromDelta, fromDelta + 1, rescued, lost,
                string.format("%.6f", (rescued - lost) / trials),
            }, ","))
        end
    end
end
