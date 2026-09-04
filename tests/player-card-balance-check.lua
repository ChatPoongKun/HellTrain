local cards = assert(loadfile("DB/PlayerCards.db"))().cards

assert(cards.pc_harmonizer_013.base.stealthCost == 3)
assert(cards.pc_predator_013.base.stealthCost == 2)
assert(cards.pc_deceiver_004.base.resistanceDamage == 2)

assert(cards.pc_predator_002.base.resistanceDamage == 3)
assert(cards.pc_predator_006.base.resistanceDamage == 2 and cards.pc_predator_006.effectChoices == nil)
assert(cards.pc_predator_007.cardType == "action" and cards.pc_predator_007.base.stealthCost == 0)
assert(cards.pc_predator_008.cardType == "action" and cards.pc_predator_008.base.stealthCost == 4 and cards.pc_predator_008.base.resistanceDamage == 6)
assert(cards.pc_predator_014.base.stealthCost == 3)
assert(cards.pc_harmonizer_007.base.resistanceDamage == 2)
assert(cards.pc_harmonizer_009.base.stealthCost == 1)
assert(cards.pc_harmonizer_011.rarity == "common" and cards.pc_harmonizer_011.base.resistanceDamage == 2 and cards.pc_harmonizer_011.effectChoices == nil)
assert(cards.pc_harmonizer_012.name == "감미로운 절정" and cards.pc_harmonizer_012.base.resistanceDamage == 2)
assert(cards.pc_harmonizer_013.base.stealthCost == 3)
assert(cards.pc_harmonizer_014.base.stealthCost == 4)
assert(cards.pc_glutton_006.base.resistanceDamage == 2)
assert(cards.pc_deceiver_004.cardType == "action")
assert(cards.pc_deceiver_007.base.stealthCost == 2 and cards.pc_deceiver_007.base.resistanceDamage == 3)
assert(cards.pc_deceiver_008.mechanismData.plan.resolve()[1].amount == 2)
assert(cards.pc_deceiver_013.base.stealthCost == 2 and cards.pc_deceiver_013.planOperation.all == true)
assert(cards.pc_deceiver_014.planOperation.all == true)

local normal = cards.pc_glutton_004.resolve({ mood = "ignore" })
assert(#normal == 1 and normal[1].op == "add_mood_token" and normal[1].amount == 1)

local negative = cards.pc_glutton_004.resolve({ mood = "suspicion" })
assert(#negative == 3)
assert(negative[1].op == "add_mood_token" and negative[1].amount == 1)
assert(negative[2].op == "remove_mood_token" and negative[2].amount == 1)
assert(negative[3].op == "add_mood_token" and negative[3].amount == 1)

local choices = cards.pc_deceiver_006.effectChoices
local allowed, reason = choices[1].canSelect({ character = { planCount = 0 } })
assert(allowed == false and reason == "no_character_plan")
assert(choices[1].canSelect({ character = { planCount = 1 } }) == true)
allowed, reason = choices[2].canSelect({ player = { planCount = 0 } })
assert(allowed == false and reason == "no_player_plan")
assert(choices[2].canSelect({ player = { planCount = 1 } }) == true)

for _, card in pairs(cards) do
    if type(card.effectChoices) == "table" then
        assert(card.description:find("중 하나", 1, true), card.id)
        assert(card.description:find("선택합니다.", 1, true), card.id)
    end
end

print("player-card-balance-check: ok")
