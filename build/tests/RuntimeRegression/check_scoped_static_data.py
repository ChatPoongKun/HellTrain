"""Scoped loading must avoid unrelated lore and preserve cache isolation."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime

lua, _ = runtime('jit' if 'jit' in sys.argv else 'lua54')
lua.execute(r'''
local full = data
local reads = {}
local original = getLoreBooks
function getLoreBooks(t, name)
    reads[name] = (reads[name] or 0) + 1
    return original(t, name)
end
checked('staticData', 'clearCache')
local catalog = checked('staticData', 'loadCatalog').data
assert(catalog.characters.han_jenny and not catalog.characters.han_jenny.publicProfile)
assert(not reads['HanJenny.db'] and not reads['YooJiyoung.db'])
local jenny = checked('staticData', 'loadCharacters', {'han_jenny'}).data
assert(reads['HanJenny.db'] and not reads['YooJiyoung.db'])
assert(jenny.characters.han_jenny.publicProfile)
assert(jenny.cards.jenny_fix_makeup and not jenny.cards[full.characters.yoo_jiyoung.battle.deck[1]])
for _, id in ipairs(full.characters.han_jenny.battle.deck) do
    assert(jenny.cards[id].name == full.cards[id].name)
end
RUNTIME_CACHE_DEVELOPMENT_BYPASS = false
local other = checked('staticData', 'loadCharacters', {'yoo_jiyoung'}).data
assert(not other.cards.jenny_fix_makeup)
jenny.characters.han_jenny.name = 'mutated'
local again = checked('staticData', 'loadCharacters', {'han_jenny'}).data
assert(again.characters.han_jenny.name == full.characters.han_jenny.name)
assert(not again.cards[full.characters.yoo_jiyoung.battle.deck[1]])
reads = {}
checked('staticData', 'loadCharacters', {'han_jenny', 'han_jenny'})
assert(next(reads) == nil, 'production scope cache reread lore')
assert(not runScript('test','staticData','loadCharacters',{'missing_character'}).ok)
assert(not runScript('test','staticData','loadCharacters','han_jenny').ok)
assert(not runScript('test','staticData','loadCharacters').ok)
local oldId = full.characters.yoo_jiyoung.battle.deck[1]
local stored = {schemaVersion=1, kind='cardCodexState', playerCardIds={}, characterCardIds={oldId}, perkIds={}}
HostCompat = {
    readState = function() return stored end,
    writeState = function(_, _, value) stored = value end,
}
checked('cardCodex','record',{cardId='jenny_fix_makeup'},again)
local found = {}
for _, id in ipairs(stored.characterCardIds) do found[id] = true end
assert(found[oldId] and found.jenny_fix_makeup, 'scoped discovery discarded another opponent')
checked('cardCodex','record',{},catalog)
assert(#stored.characterCardIds == 2, 'catalog recording discarded discoveries')
RUNTIME_CACHE_DEVELOPMENT_BYPASS = nil
local saved = sources['YooJiyoung.db']
sources['YooJiyoung.db'] = 'invalid Lua!'
assert(checked('staticData','loadCharacters',{'han_jenny'}).ok)
assert(not runScript('test','staticData','loadAll').ok)
sources['YooJiyoung.db'] = saved
checked('staticData','loadAll')
local listing = sources['CharacterList.db']
sources['CharacterList.db'] = listing:gsub('turnLimit = 8', 'turnLimit = 9', 1)
assert(not runScript('test','staticData','loadAll').ok, 'catalog drift accepted')
sources['CharacterList.db'] = listing
-- A larger catalog must not cause additional character DB reads.
local additions = {}
for i=1,200 do
    additions[#additions+1] = 'extra_'..i..' = {id="extra_'..i..'", database="Extra'..i..'.db", name="Extra '..i..'", turnLimit=8},'
end
sources['CharacterList.db'] = listing:gsub('characters = {', 'characters = {'..table.concat(additions), 1)
reads = {}
local expanded = checked('staticData','loadCharacters',{'han_jenny'})
assert(expanded.counts.characters == 1)
assert(expanded.counts.cards == 66)
for name in pairs(reads) do assert(not name:match('^Extra'), 'catalog expansion loaded an unrelated DB') end
sources['CharacterList.db'] = listing
-- Isolate journal rendering/cache behavior from session replay (covered by the
-- character journal regression). Five encountered characters exceed the LRU.
local dispatch = runScript
local sessions = {}
for id in pairs(full.characters) do
    sessions[#sessions+1] = {battleId='journal-'..id, characterId=id, status='victory'}
end
function runScript(t, module, action, ...)
    if module == 'runProgression' and action == 'validate' then
        return {ok=true, state={sessions=sessions}}
    end
    return dispatch(t,module,action,...)
end
RUNTIME_CACHE_DEVELOPMENT_BYPASS = false
checked('staticData','clearCache')
for pass=1,3 do
    local before = checked('staticData','cacheStats').cache.validations
    local input = checked('staticData','loadCatalog').data
    local view = checked('runProgressionView','buildCharacterJournal',{runState={}},input).view
    assert(view.count == 5)
    local validations = checked('staticData','cacheStats').cache.validations - before
    assert(validations <= (pass == 1 and 2 or 0), 'journal scopes thrash the static cache: '..validations)
    assert(input.characters.han_jenny.publicProfile == nil, 'journal mutated the caller catalog')
end
runScript = dispatch
print('PASS: scoped static loading, cache and error isolation')
''')
