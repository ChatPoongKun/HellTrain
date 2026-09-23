"""Custom characters receive a shared deck plus their own optional cards."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime

lua, _ = runtime('jit' if 'jit' in sys.argv else 'lua54')
lua.execute(r'''
local listing = sources['CharacterList.db']
local common = sources['CommonCharacterCards.db']
sources['CharacterList.db'] = listing:gsub('characters = {', [[characters = {
    custom_probe = {id='custom_probe', database='CustomProbe.db', name='공용 덱 검사', turnLimit=8, cardPool='common'},
]], 1)
sources['CustomProbe.db'] = [[
return {
    schemaVersion=1, kind='characterDatabase',
    characters={custom_probe={
        id='custom_probe', name='공용 덱 검사', publicProfile={},
        battle={startingResistance=30, turnLimit=8, startingMood='suspicion',
            baseDrawCount=3, maxHandSize=5, planCapacity=1, traitIds={},
            extraDeck={'probe_defend'}},
    }},
    cards={probe_defend=characterCardSupport.card(
        'probe_defend', '전용 방어', {'recovery'}, {}, {'저항 1 회복.'},
        '전용 카드', {actorAction='몸을 피한다.', actorThought='지켜야 해.'},
        function() return {characterCardSupport.recoverResistance(1)} end)},
}
]]
sources['CommonCharacterCards.db'] = [[
return {
    schemaVersion=1, kind='commonCharacterCards',
    deck={'common_guard', 'common_warning'},
    cards={
        common_guard=characterCardSupport.card('common_guard', '기본 방어', {'recovery'}, {},
            {'저항 2 회복.'}, '공용 카드',
            {actorAction='거리를 둔다.', actorThought='침착하게.'},
            function() return {characterCardSupport.recoverResistance(2)} end),
        common_warning=characterCardSupport.card('common_warning', '기본 경고', {'exposure'}, {},
            {'은폐 피해 1.'}, '공용 카드',
            {actorAction='주변을 살핀다.', actorThought='도움을 청해야 해.'},
            function() return {characterCardSupport.loseStealth(1)} end),
    },
}
]]
local fixtureCommon = sources['CommonCharacterCards.db']
local customWithExtra = sources['CustomProbe.db']

local reads = {}
local original = getLoreBooks
function getLoreBooks(t, name)
    reads[name] = (reads[name] or 0) + 1
    return original(t, name)
end

checked('staticData', 'clearCache')
local catalog = checked('staticData', 'loadCatalog').data
assert(catalog.characters.custom_probe and not catalog.characters.custom_probe.publicProfile)
assert(not reads['CommonCharacterCards.db'] and not reads['CustomProbe.db'], 'catalog loaded custom content')
local existing = checked('staticData', 'loadCharacters', {'han_jenny'}).data
assert(not reads['CommonCharacterCards.db'], 'ordinary character loaded common deck')
assert(not existing.cards.common_guard)

local scoped = checked('staticData', 'loadCharacters', {'custom_probe'}).data
local deck = scoped.characters.custom_probe.battle.deck
assert(#deck == 3 and deck[1] == 'common_guard' and deck[2] == 'common_warning'
    and deck[3] == 'probe_defend', 'shared deck and extra card order')
assert(scoped.cards.common_guard and scoped.cards.common_warning and scoped.cards.probe_defend)
assert(not scoped.cards.jenny_fix_makeup, 'scoped custom load copied unrelated cards')
local playerDeck = {
    'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005',
    'pc_predator_006','pc_predator_007','pc_predator_008','pc_predator_009','pc_predator_010',
}
local started = checked('battleBootstrap', 'fromSetup', {
    battleId='common-probe', seed=12345, playerCardIds=playerDeck, characterId='custom_probe',
}, scoped)
assert(started.state.character.characterId == 'custom_probe', 'composed deck could not start battle')
assert(checked('staticData', 'loadAll').data.characters.custom_probe.battle.deck[3] == 'probe_defend')

sources['CommonCharacterCards.db'] = common
sources['CustomProbe.db'] = [[
return {
    schemaVersion=1, kind='characterDatabase',
    characters={custom_probe={
        id='custom_probe', name='공용 덱 검사', publicProfile={},
        battle={startingResistance=30, turnLimit=8, startingMood='suspicion',
            baseDrawCount=3, maxHandSize=5, planCapacity=1, traitIds={}, extraDeck={}},
    }}, cards={},
}
]]
local defaultOnly = checked('staticData', 'loadCharacters', {'custom_probe'}).data
local shippedCommonDeck = assert(load('return ' .. assert(common:match('deck%s*=%s*(%b{})'))))()
assert(#defaultOnly.characters.custom_probe.battle.deck == #shippedCommonDeck,
    'empty extra deck changed the shared deck length')
for index, cardId in ipairs(shippedCommonDeck) do
    assert(defaultOnly.characters.custom_probe.battle.deck[index] == cardId,
        'empty extra deck changed the shared deck order')
end
checked('battleBootstrap', 'fromSetup', {
    battleId='default-only-probe', seed=12345, playerCardIds=playerDeck, characterId='custom_probe',
}, defaultOnly)
sources['CustomProbe.db'] = customWithExtra:gsub("extraDeck={'probe_defend'}", 'extraDeck={}', 1)
local orphan = runScript('test', 'staticData', 'loadCharacters', {'custom_probe'})
assert(not orphan.ok, 'defined but unlisted custom card was silently omitted')
local orphanReported = false
for _, issue in ipairs(orphan.errors or {}) do
    if issue.code == 'unlisted_extra_card' then orphanReported = true end
end
assert(orphanReported, 'unlisted custom card had no actionable validation error')
sources['CustomProbe.db'] = customWithExtra
sources['CommonCharacterCards.db'] = fixtureCommon

sources['CustomProbe.db'] = sources['CustomProbe.db']:gsub("extraDeck={'probe_defend'}", "extraDeck={'missing_card'}", 1)
assert(not runScript('test', 'staticData', 'loadCharacters', {'custom_probe'}).ok,
    'unknown extra card accepted')
sources['CustomProbe.db'] = sources['CustomProbe.db']:gsub("extraDeck={'missing_card'}", "extraDeck={'probe_defend'}", 1)
sources['CommonCharacterCards.db'] = sources['CommonCharacterCards.db']:gsub(
    "deck={'common_guard', 'common_warning'}", "deck={'missing_card'}", 1)
assert(not runScript('test', 'staticData', 'loadCharacters', {'custom_probe'}).ok,
    'unknown shared card accepted')
assert(checked('staticData', 'loadCharacters', {'han_jenny'}).ok,
    'malformed shared deck affected an ordinary character')
sources['CommonCharacterCards.db'] = common
sources['CharacterList.db'] = listing
print('PASS: common deck composition, scoping and invalid references')
''')
