local file = assert(io.open("DB/PlayerCards.db", "rb"))
local source = file:read("*a")
file:close()
local cards = assert(load(source, "@DB/PlayerCards.db", "t", _G))().cards

local function base(id, cost, damage)
    local card = assert(cards[id], "missing card: " .. id)
    assert(card.base.stealthCost == cost, id .. " stealth cost mismatch")
    assert(card.base.resistanceDamage == damage, id .. " base damage mismatch")
    return card
end

local function commands(card, mood)
    return card.resolve and card.resolve({
        mood = mood,
        character = { publicActionTag = "block", moodTokens = {} },
        history = {},
    }) or {}
end

local function hasCommand(values, op, amount)
    for _, value in ipairs(values) do
        if value.op == op and value.amount == amount then return true end
    end
    return false
end

local standard = base("p005_blame_the_crowd", 1, 3)
assert(hasCommand(commands(standard, "ignore"), "add_mood_token", 1), "standard card must manipulate one")
base("p038_twist_arm_behind_back", 1, 4)
base("p009_grind_hips", 0, 1)
base("p033_catch_counter_tell", 1, 2)

local recovery = base("p007_feign_indifference", 1, 2)
local recoveryCommands = commands(recovery, "rejection")
assert(hasCommand(recoveryCommands, "recover_stealth", 5), "p007 must net four stealth")
assert(hasCommand(recoveryCommands, "remove_mood_token", 2), "p007 must help escape negative mood")
assert(hasCommand(recoveryCommands, "damage_resistance", 1), "p007 must deal conditional damage in negative mood")
assert(hasCommand(commands(base("p012_check_passenger_gazes", 1, 0), "ignore"), "recover_stealth", 3),
    "chain recovery must net two stealth")
assert(hasCommand(commands(base("p020_dominate_with_gaze", 0, 2), "suspicion"), "recover_stealth", 4),
    "conditional recovery must net four stealth")

local payoff = base("p045_press_between_thighs", 3, 5)
assert(hasCommand(commands(payoff, "compliance"), "damage_resistance", 5), "p045 compliance total must be ten")
payoff = base("p047_unhesitating_touch", 5, 7)
assert(hasCommand(commands(payoff, "compliance"), "damage_resistance", 5), "p047 compliance total must be twelve")
payoff = base("p043_finger_penetration", 6, 9)
assert(hasCommand(commands(payoff, "compliance"), "damage_resistance", 4), "p043 compliance total must be thirteen")
local setup = base("p044_overwhelm_both_halves", 2, 4)
assert(hasCommand(commands(setup, "ignore"), "add_mood_token", 2), "p044 must manipulate two")

print("player-card-floor-check: ok")
