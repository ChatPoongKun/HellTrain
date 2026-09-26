"""A deferred character load failure must reach the user-facing alert."""
from pathlib import Path
from importlib import import_module
import sys


engine = 'luajit21' if 'jit' in sys.argv else 'lua54'
lua = import_module('lupa.' + engine).LuaRuntime()
host_flow = (Path('System') / 'hostFlow.lua').read_text(encoding='utf-8-sig')
lua.globals().host_flow_source = host_flow
lua.execute(r'''
local vars, alerts = {}, {}
table.unpack = table.unpack or unpack

function debug() end
function getChatVar(_, key) return vars[key] or '' end
function getFullChat() return {} end
function alertError(_, message) alerts[#alerts + 1] = tostring(message) end
function splitByDelimiter(value, delimiter)
    local parts = {}
    for part in value:gmatch('[^' .. delimiter .. ']+') do parts[#parts + 1] = part end
    return parts
end

HostCompat = {
    writeChatVar = function(_, key, value) vars[key] = value end,
    readState = function() return nil end,
}

function runScript(_, module, action)
    assert(module == 'init' and action == 'chooseCharacter')
    return {
        ok = false,
        schemaVersion = 1,
        errors = {{
            code = 'invalid_starting_resistance',
            path = 'HanJenny.db[1].characters.han_jenny.battle.startingResistance',
            message = '시작 저항이 양수의 유한한 숫자가 아닙니다.',
        }},
    }
end

local hostFlow = assert(load('return ' .. host_flow_source, 'hostFlow'))()
hostFlow('test', 'buttonClick', 'init|chooseCharacter|han_jenny|token')

assert(#alerts == 1, 'deferred character load failure did not open an alert')
assert(alerts[1]:find('HanJenny.db[1].characters.han_jenny.battle.startingResistance', 1, true),
    'alert omitted the character DB filename or exact field')
assert(vars.helltrainSceneRequestV1 == '', 'failed character selection retained the scene lock')
print('PASS: deferred character DB errors reach the alert with a precise path')
''')
