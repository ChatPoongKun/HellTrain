"""Character image filenames come from DB data, with a paired dummy fallback."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime

lua, _ = runtime('jit' if 'jit' in sys.argv else 'lua54')
lua.execute(r'''
local sample = checked('staticData', 'loadCharacters', {'hakurei_reimu'}).data.characters.hakurei_reimu
assert(sample.portraitImage == 'dummy.png' and sample.fallenImage == 'dummy.png',
    'Reimu sample must exercise the paired dummy fallback')
assert(#sample.battle.deck == 11 and sample.battle.deck[11] == 'reimu_boundary_guard',
    'Reimu sample must append its own card to the common deck')

local listing = sources['CharacterList.db']
sources['CharacterList.db'] = listing:gsub('characters = {', [[characters = {
    image_probe = {id='image_probe', database='ImageProbe.db', name='파일명과 다른 표시 이름', turnLimit=8, cardPool='common'},
]], 1)
local definition = [[
return {
    schemaVersion=1, kind='characterDatabase',
    characters={image_probe={
        id='image_probe', name='파일명과 다른 표시 이름',
        portraitImage='probe_portrait.png', fallenImage='probe_fallen.png',
        publicProfile={age=25,occupation='직장인',appearance={style='외투'},background={}},
        battle={startingResistance=30,turnLimit=8,startingMood='suspicion',
            baseDrawCount=3,maxHandSize=5,planCapacity=1,traitIds={},extraDeck={}},
    }}, cards={},
}
]]
sources['ImageProbe.db'] = definition
local explicit = checked('staticData', 'loadCharacters', {'image_probe'}).data
local character = explicit.characters.image_probe
assert(character.portraitImage == 'probe_portrait.png')
assert(character.fallenImage == 'probe_fallen.png')
local playerDeck = {
    'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005',
    'pc_predator_006','pc_predator_007','pc_predator_008','pc_predator_009','pc_predator_010',
}
local sampleData = checked('staticData', 'loadCharacters', {'hakurei_reimu'}).data
local sampleState = checked('battleBootstrap', 'fromSetup', {
    battleId='reimu-dummy',seed=12345,playerCardIds=playerDeck,characterId='hakurei_reimu',
}, sampleData).state
local sampleTurn = checked('turnInitializer', 'prepareTurn', sampleState, sampleData, {turnId='reimu-turn-001'})
local sampleView = checked('viewBuilder', 'buildBattleView', sampleTurn.state, sampleData, {draft=sampleTurn.draft}).view
assert(sampleView.character.portraitImage == 'dummy.png' and sampleView.character.fallenImage == 'dummy.png',
    'Reimu battle view must use both dummy images')
local state = checked('battleBootstrap', 'fromSetup', {
    battleId='image-probe',seed=12345,playerCardIds=playerDeck,characterId='image_probe',
}, explicit).state
local turn = checked('turnInitializer', 'prepareTurn', state, explicit, {turnId='image-turn-001'})
local view = checked('viewBuilder', 'buildBattleView', turn.state, explicit, {draft=turn.draft}).view
assert(view.character.portraitImage == 'probe_portrait.png')
assert(view.character.fallenImage == 'probe_fallen.png')

sources['ImageProbe.db'] = definition:gsub("fallenImage='probe_fallen.png',", '', 1)
local missing = checked('staticData', 'loadCharacters', {'image_probe'}).data.characters.image_probe
assert(missing.portraitImage == 'dummy.png' and missing.fallenImage == 'dummy.png',
    'missing fallen image did not replace both images')
sources['ImageProbe.db'] = definition:gsub("portraitImage='probe_portrait.png'", "portraitImage=''", 1)
local empty = checked('staticData', 'loadCharacters', {'image_probe'}).data.characters.image_probe
assert(empty.portraitImage == 'dummy.png' and empty.fallenImage == 'dummy.png',
    'empty portrait did not replace both images')
sources['ImageProbe.db'] = definition:gsub("portraitImage='probe_portrait.png'", "portraitImage='imgs/probe_portrait.png'", 1)
assert(not runScript('test', 'staticData', 'loadCharacters', {'image_probe'}).ok,
    'image path accepted where a filename is required')
print('PASS: character image filenames and paired dummy fallback')
''')
