"""Ensure free-training sends bypass battle validation and resolution."""
from importlib import import_module
import sys

lua = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime()
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local vars={helltrainFreeTrainingRouteV1=json.encode({phase='active',sessionId='setup:free:1',context='free context'})}
function getChatVar(_,name) return vars[name] or '' end
function getFullChat() return {{role='char',data='boundary'}} end
function debug() end
function alertError() end
HostCompat={readState=function() return nil end,writeChatVar=function(_,key,value) vars[key]=value end}
local calls=0
function runScript(_,module,action)
 if module=='freeTrainingController' and action=='restore' then
  return {ok=true}
 end
 calls=calls+1
 error('free input entered '..module..'.'..action)
end
local file=assert(io.open('System/hostFlow.lua','r'))
local source=file:read('*a');file:close()
local host=assert((loadstring or load)('return '..source))()
assert(host('test','start')==true)
local request={{role='user',content='plain input'}}
local injected=host('test','editRequest',request)
assert(#injected==2 and injected[1].role=='system' and injected[2].content=='plain input')
local output=host('test','output')
assert(output.ok and calls==0,'battle path was called')
vars.helltrainFreeTrainingRouteV1=json.encode({phase='selecting'})
assert(host('test','start')==false and calls==0)
print('PASS: free training host flow bypasses battle runtime')
''')
