"""Character journal popup must show deferred DB validation details."""
from pathlib import Path
from importlib import import_module
import sys


engine = 'luajit21' if 'jit' in sys.argv else 'lua54'
lua = import_module('lupa.' + engine).LuaRuntime()
profile_source = (Path('System') / '캐릭터 프로필.lua').read_text(encoding='utf-8-sig')
lua.globals().profile_source = profile_source
lua.execute(r'''
local popup
HostCompat = {
    readState = function(_, key)
        if key == 'battleRuntimeV1.authority' then
            return {character = {characterId = 'han_jenny'}}
        end
        return nil
    end,
    writeChatVar = function(_, key, value)
        if key == 'helltrainUiPopupV1' then popup = value end
    end,
}
function debug() end
function runScript(_, module, action)
    assert(module == 'staticData' and action == 'loadCharacters')
    return {
        ok = false,
        errors = {{
            code = 'invalid_starting_resistance',
            path = 'HanJenny.db[1].characters.han_jenny.battle.startingResistance',
            message = '시작 저항이 양수의 유한한 숫자가 아닙니다.',
        }},
    }
end

local profile = assert(load('return ' .. profile_source, 'character-profile'))()
local report = profile('test', 'han_jenny')
assert(report.ok == false, 'invalid character DB unexpectedly opened the journal')
assert(type(popup) == 'string' and popup:find(
    'HanJenny.db[1].characters.han_jenny.battle.startingResistance',
    1,
    true
), 'character journal popup omitted the DB filename or exact field')
print('PASS: character journal popup shows deferred DB validation details')
''')
