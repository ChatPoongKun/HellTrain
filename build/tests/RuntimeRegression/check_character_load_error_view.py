"""Character selection views must preserve deferred DB validation details."""
from pathlib import Path
import sys


sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime


lua, _ = runtime('jit' if 'jit' in sys.argv else 'lua54')
lua.execute(r'''
checked('staticData', 'clearCache')
local catalog = checked('staticData', 'loadCatalog').data
local state = checked('gameSetup', 'start', {
    setupId = 'setup-character-error-view',
    seed = 13579,
}, catalog).state

while state.phase == 'deckDraft' do
    state = checked('gameSetup', 'choose', state, {
        cardId = state.offer.cardIds[1],
        interactionToken = state.offer.interactionToken,
    }, catalog).state
end
assert(state.phase == 'deckComplete')
state = checked('gameSetup', 'beginCharacterSelect', state, catalog).state

local characterId = state.characterOffer.characterIds[1]
local database = catalog.characterList[characterId].database
local original = sources[database]
local replacements
sources[database], replacements = original:gsub(
    'startingResistance%s*=%s*%d+',
    'startingResistance = 0',
    1
)
assert(replacements == 1, 'fixture did not corrupt the offered character DB')
checked('staticData', 'clearCache')

local report = runScript(
    'test',
    'gameSetupView',
    '_buildCanonical',
    state,
    catalog,
    function() return true end
)
assert(not report.ok, 'character selection view accepted an invalid character DB')
local expectedPath = database .. '[1].characters.' .. characterId .. '.battle.startingResistance'
local sawPrecisePath = false
for _, item in ipairs(report.errors or {}) do
    if item.code == 'invalid_starting_resistance' and item.path == expectedPath then
        sawPrecisePath = true
    end
end
assert(sawPrecisePath, 'character selection view replaced the precise DB field error')
print('PASS: character selection view preserves deferred DB validation details')
''')
