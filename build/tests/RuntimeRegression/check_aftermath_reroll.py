"""Committed free-input rerolls must replace a turn, not advance it twice."""
from pathlib import Path
import re
import sys
from importlib import import_module

LuaRuntime = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime
source = re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@", Path('build/tests/setup-to-battle-flow-check.ps1').read_text(encoding='utf-8-sig'), re.S)[1]
source = source[:source.index('print("DEBUG_SELECTED=')]
# Reuse the actual victory/host fixture, stopping before its reward-skip test.
fixture = Path('build/tests/RuntimeRegression/check_perk_host_flow.py').read_text(encoding='utf-8')
source += fixture.split("source+=r'''")[1].split("local aftermath=states[")[0]
source += r'''
table.unpack=table.unpack or unpack
local key='battleRuntimeV1.aftermath'
local victory=states[key].completedTurnNumber
local authoritySnapshot=canonical(states['battleRuntimeV1.authority'])
local function generate(text)
 local prepared=call('battleController','prepareGeneration')
 assert(prepared.generationReady)
 call('battleController','injectRequest',{{role='user',content=chat[#chat].data}})
 addChat('test','char',text)
 call('battleController','commitOutput')
end
addChat('test','user','Look outside.')
generate('First response.')
local completed=states[key].completedTurnNumber
assert(completed==victory+1 and states[key].phase=='ready')
local savedChat,savedState=clone(chat),clone(states[key])
-- Risu reroll removes only the last assistant response.
table.remove(chat)
assert(runScript('test','hostFlow','start')==true,'onStart rejected the reroll')
generate('Replacement response.')
assert(states[key].completedTurnNumber==completed,'reroll consumed an extra turn')
assert(#chat==#savedChat and chat[#chat].data=='Replacement response.')
call('battleController','commitOutput')
assert(states[key].completedTurnNumber==completed,'duplicate commit consumed a turn')
-- Repeated rerolls and failed/zero-output attempts reuse the original input.
table.remove(chat)
local prepared=call('battleController','prepareGeneration')
assert(prepared.generationReady and prepared.turnNumber==completed)
call('battleController','injectRequest',{{role='user',content=chat[#chat].data}})
generate('Retry response.')
assert(states[key].completedTurnNumber==completed)
-- A new user input advances normally after reroll.
addChat('test','user','Wait quietly.')
generate('Next response.')
assert(states[key].completedTurnNumber==completed+1)
table.remove(chat)
generate('Second turn replacement.')
assert(states[key].completedTurnNumber==completed+1)
assert(canonical(states['battleRuntimeV1.authority'])==authoritySnapshot)
-- Earlier dialogue edits/deletions must not be mistaken for a reroll.
for _,change in ipairs({'input','prefix','truncate'}) do
 chat=clone(savedChat);states[key]=clone(savedState)
 table.remove(chat)
 if change=='input' then chat[#chat].data='Changed input.'
 elseif change=='prefix' then chat[1].data='Changed past.'
 else table.remove(chat) end
 local snapshot=canonical(states[key])
 local rejected=runScript('test','battleController','prepareGeneration')
 assert(not rejected.ok,change..' must be rejected')
 assert(canonical(states[key])==snapshot,'rejection changed progress')
end
-- A failed persistence write must not consume the turn or lose the original receipt.
chat=clone(savedChat);states[key]=clone(savedState);table.remove(chat)
local write=HostCompat.writeState
HostCompat.writeState=function(id,k,v) if k~=key then return write(id,k,v) end end
local rejected=runScript('test','battleController','prepareGeneration')
assert(not rejected.ok and states[key].completedTurnNumber==completed)
HostCompat.writeState=write
generate('Recovered write.')
assert(states[key].completedTurnNumber==completed)
local prepared=call('battleController','prepareGeneration')
assert(not prepared.generationReady,'no-input start generated another scene')
-- Explicit skip/settlement must remain complete, even if a response is removed.
local current=states[key]
call('battleController','skipAftermath',won.battleId,won.battleId..string.format('-aftermath-%03d',current.completedTurnNumber))
assert(states[key].phase=='complete')
local settled=canonical(states['runProgressionV1.authority'])
table.remove(chat)
assert(not call('battleController','prepareGeneration').generationReady)
assert(states[key].phase=='complete' and canonical(states['runProgressionV1.authority'])==settled)
print('PASS: aftermath reroll, repeated/zero-output retry, duplicate commit, next input, altered chat and dropped write')
'''
LuaRuntime().execute(source)
