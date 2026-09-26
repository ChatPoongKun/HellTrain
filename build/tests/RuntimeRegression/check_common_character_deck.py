"""Character decks use own cards first and automatically receive seed-based common supplements."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime

lua, _ = runtime('jit' if 'jit' in sys.argv else 'lua54')
lua.execute(r'''
local listing = sources['CharacterList.db']
local common = sources['CommonCharacterCards.db']
sources['CharacterList.db'] = listing:gsub('characters = {', [[characters = {
    custom_probe = {id='custom_probe', database='CustomProbe.db', name='공용 덱 검사', turnLimit=8},
]], 1)

local function commonSource(cardCount)
    local deck, cards = {}, {}
    for index = 1, cardCount do
        local id = string.format('common_probe_%02d', index)
        deck[#deck + 1] = string.format("'%s'", id)
        cards[#cards + 1] = string.format([[
%s=characterCardSupport.card(
    '%s', '공용 카드 %d', {'recovery'}, {}, {'저항 1 회복.'}, '공용 카드',
    {actorAction='거리를 둔다.', actorThought='침착하게.'},
    function() return {characterCardSupport.recoverResistance(1)} end)]], id, id, index)
    end
    return string.format(
        "return {schemaVersion=1, kind='commonCharacterCards', deck={%s}, cards={%s}}",
        table.concat(deck, ','), table.concat(cards, ','))
end

sources['CommonCharacterCards.db'] = commonSource(12)
local fixtureCommon = sources['CommonCharacterCards.db']

local function customSource(cardCount)
    local deck, cards = {}, {}
    for index = 1, cardCount do
        local id = string.format('probe_own_%02d', index)
        deck[#deck + 1] = string.format("'%s'", id)
        cards[#cards + 1] = string.format([[
%s=characterCardSupport.card(
    '%s', '전용 카드 %d', {'recovery'}, {}, {'저항 1 회복.'}, '전용 카드',
    {actorAction='몸을 피한다.', actorThought='지켜야 해.'},
    function() return {characterCardSupport.recoverResistance(1)} end)]], id, id, index)
    end
    return string.format([[
return {
    schemaVersion=1, kind='characterDatabase',
    characters={custom_probe={
        id='custom_probe', name='공용 덱 검사', publicProfile={},
        sexualPreference='상호 존중을 중시함', backgroundNarrative='공용 덱 검사 캐릭터.',
        battle={startingResistance=30, turnLimit=8, startingMood='suspicion',
            baseDrawCount=3, maxHandSize=5, planCapacity=1, traitIds={}, deck={%s}},
    }},
    cards={%s},
}
]], table.concat(deck, ','), table.concat(cards, ','))
end

local playerDeck = {
    'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005',
    'pc_predator_006','pc_predator_007','pc_predator_008','pc_predator_009','pc_predator_010',
}

local function loadCustom(cardCount)
    sources['CustomProbe.db'] = customSource(cardCount)
    checked('staticData', 'clearCache')
    return checked('staticData', 'loadCharacters', {'custom_probe'}).data
end

local function startCustom(cardCount, seed)
    local scoped = loadCustom(cardCount)
    local started = checked('battleBootstrap', 'fromSetup', {
        battleId='common-probe-' .. cardCount .. '-' .. seed,
        seed=seed, playerCardIds=playerDeck, characterId='custom_probe',
    }, scoped)
    local ids = {}
    for _, instance in ipairs(started.state.cardInstances) do
        if instance.owner == 'character' then ids[#ids + 1] = instance.cardId end
    end
    return ids, started.state
end

local function analyze(ids)
    local own, shared, seen = 0, 0, {}
    for _, id in ipairs(ids) do
        assert(not seen[id], 'final character deck contains a duplicate card: ' .. id)
        seen[id] = true
        if id:match('^probe_own_') then own = own + 1
        elseif id:match('^common_probe_') then shared = shared + 1
        else error('unexpected character card: ' .. tostring(id)) end
    end
    return own, shared, seen
end

local function commonSignature(ids)
    local commonIds = {}
    for _, id in ipairs(ids) do
        if id:match('^common_probe_') then commonIds[#commonIds + 1] = id end
    end
    table.sort(commonIds)
    return table.concat(commonIds, ',')
end

local emptyIds = startCustom(0, 12345)
local emptyOwn, emptyShared = analyze(emptyIds)
assert(#emptyIds == 10 and emptyOwn == 0 and emptyShared == 10,
    'zero-card character must receive ten common cards')

local partialIds = startCustom(3, 12345)
local partialOwn, partialShared = analyze(partialIds)
assert(#partialIds == 10 and partialOwn == 3 and partialShared == 7,
    'partial character deck must be supplemented to ten cards')

local sameSeedIds = startCustom(3, 12345)
assert(table.concat(partialIds, ',') == table.concat(sameSeedIds, ','),
    'same character and seed did not reproduce the common supplement')
local otherSeedIds = startCustom(3, 98765)
assert(commonSignature(partialIds) ~= commonSignature(otherSeedIds),
    'different seeds did not vary the common supplement')

local exactIds = startCustom(10, 12345)
local exactOwn, exactShared = analyze(exactIds)
assert(#exactIds == 10 and exactOwn == 10 and exactShared == 0,
    'exactly ten own cards must not use the common pool')

local largeIds = startCustom(11, 12345)
local largeOwn, largeShared = analyze(largeIds)
assert(#largeIds == 11 and largeOwn == 11 and largeShared == 0,
    'more than ten own cards must use only the own deck')

local reads = {}
local original = getLoreBooks
function getLoreBooks(t, name)
    reads[name] = (reads[name] or 0) + 1
    return original(t, name)
end
checked('staticData', 'clearCache')
local catalog = checked('staticData', 'loadCatalog').data
assert(catalog.characters.custom_probe and not catalog.characters.custom_probe.publicProfile)
assert(not reads['CommonCharacterCards.db'] and not reads['CustomProbe.db'],
    'catalog loaded character content')

local existing = checked('staticData', 'loadCharacters', {'han_jenny'}).data
assert(reads['CommonCharacterCards.db'], 'character load did not include common card pool')
assert(existing.cards.common_probe_01, 'character scope did not include common cards')

sources['CustomProbe.db'] = customSource(1):gsub(
    "deck={'probe_own_01'}", "deck={'missing_card'}", 1)
checked('staticData', 'clearCache')
assert(not runScript('test', 'staticData', 'loadCharacters', {'custom_probe'}).ok,
    'unknown character deck card accepted')

sources['CustomProbe.db'] = customSource(1)
sources['CommonCharacterCards.db'] = fixtureCommon:gsub(
    "deck={'common_probe_01'", "deck={'missing_card'", 1)
checked('staticData', 'clearCache')
assert(not runScript('test', 'staticData', 'loadCharacters', {'custom_probe'}).ok,
    'unknown shared card accepted')
assert(not runScript('test', 'staticData', 'loadCharacters', {'han_jenny'}).ok,
    'malformed shared deck did not affect a character-scoped load')

sources['CommonCharacterCards.db'] = [[
local id = 'only_common'
return {
    schemaVersion=1, kind='commonCharacterCards', deck={id},
    cards={[id]=characterCardSupport.card(
        id, '부족한 공용 카드', {'recovery'}, {}, {'저항 1 회복.'}, '공용 카드',
        {actorAction='거리를 둔다.', actorThought='침착하게.'},
        function() return {characterCardSupport.recoverResistance(1)} end)},
}
]]
sources['CustomProbe.db'] = customSource(3)
checked('staticData', 'clearCache')
local insufficient = runScript('test', 'staticData', 'loadCharacters', {'custom_probe'})
assert(not insufficient.ok, 'insufficient common supplement pool was accepted')
local insufficientReported = false
for _, issue in ipairs(insufficient.errors or {}) do
    if issue.code == 'insufficient_common_character_cards' then insufficientReported = true end
end
assert(insufficientReported, 'insufficient common pool lacked an actionable validation error')

sources['CommonCharacterCards.db'] = common
sources['CharacterList.db'] = listing
print('PASS: automatic seeded common supplements, unified deck schema and validation')
''')
