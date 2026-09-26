"""Progression views must preserve deferred character DB validation details."""
from pathlib import Path
import sys


sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime


lua, _ = runtime('jit' if 'jit' in sys.argv else 'lua54')
lua.execute(r'''
local setup = checked('gameSetup', 'start', {
    setupId = 'setup-character-error-progression',
    seed = 912,
}, data).state
while setup.phase == 'deckDraft' do
    setup = checked('gameSetup', 'choose', setup, {
        cardId = setup.offer.cardIds[1],
        interactionToken = setup.offer.interactionToken,
    }, data).state
end
setup = checked('gameSetup', 'beginCharacterSelect', setup, data).state
setup = checked('gameSetup', 'chooseCharacter', setup, {
    characterId = setup.characterOffer.characterIds[1],
    interactionToken = setup.characterOffer.interactionToken,
}, data).state

local spec = {
    battleId = setup.battleSpec.battleId,
    seed = setup.battleSpec.seed,
    playerCardIds = setup.selectedCardIds,
    characterId = setup.selectedCharacterId,
    perkIds = {},
}
local boot = checked('battleBootstrap', 'fromSetup', spec, data).state
local summary = {
    battleId = boot.battleId,
    turnId = boot.battleId .. '-turn-001',
    characterId = boot.character.characterId,
    status = 'victory',
    reasonCode = 'card_checkpoint',
    turnNumber = 1,
    turnLimit = boot.turnLimit,
    finalStealth = 20,
    finalResistance = 0,
    transit = boot.transit,
}
local run = checked('runProgression', 'settle', nil, setup, summary, data).state
local catalog = checked('staticData', 'loadCatalog').data
local characterId = setup.selectedCharacterId
local database = catalog.characterList[characterId].database
local original = sources[database]
local replacements
sources[database], replacements = original:gsub(
    'startingResistance%s*=%s*%d+',
    'startingResistance = 0',
    1
)
assert(replacements == 1, 'fixture did not corrupt the settled character DB')
checked('staticData', 'clearCache')

local report = runScript(
    'test',
    'runProgressionView',
    '_buildCanonical',
    run,
    setup,
    catalog,
    function() return true end
)
assert(not report.ok, 'progression view accepted an invalid character DB')
local expectedPath = database .. '[1].characters.' .. characterId .. '.battle.startingResistance'
local sawPrecisePath = false
for _, item in ipairs(report.errors or {}) do
    if item.code == 'invalid_starting_resistance' and item.path == expectedPath then
        sawPrecisePath = true
    end
end
assert(sawPrecisePath, 'progression view replaced the precise DB field error')
print('PASS: progression view preserves deferred character DB validation details')
''')
