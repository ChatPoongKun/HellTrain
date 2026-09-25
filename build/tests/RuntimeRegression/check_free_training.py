"""Exercise free-training eligibility and idempotent state transitions."""
from importlib import import_module
import sys

LuaRuntime = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime
lua = LuaRuntime()
lua.execute(r'''
local function loadModule(path)
 local file=assert(io.open(path,'r'));local source=file:read('*a');file:close()
 return assert((loadstring or load)('return '..source))()
end
local free=loadModule('System/freeTraining.lua')
local function call(action,...)
 local result=free('test',action,...);assert(result and result.ok,action);return result
end
local function record(id,battle,status)
 return {battleId=battle,characterId=id,status=status}
end
local run={phase='characterSelect',setupId='setup-1',characterOffer={interactionToken='run-token'},sessions={
 record('a','b1','victory'),record('a','b2','victory'),
}}
assert(#call('eligibility',run).eligibleIds==0)
run.sessions[3]=record('a','b3','victory')
local eligibility=call('eligibility',run)
assert(eligibility.eligibleIds[1]=='a' and eligibility.victoriesById.a==3)
run.sessions[4]=record('b','b4','victory')
run.sessions[5]=record('b','b5','defeat')
assert(call('eligibility',run).victoriesById.b==1)
run.sessions[6]=record('a','b3','victory')
assert(call('eligibility',run).victoriesById.a==3,'duplicate battleId counted')
run.sessions[7]=record('a','b6','victory')
assert(call('eligibility',run).victoriesById.a==4,'fourth victory was not counted')
run.sessions[8]=record('c','b7','victory')
run.sessions[9]=record('d','b8','victory')
assert(call('eligibility',run).victoriesById.c==1 and call('eligibility',run).victoriesById.d==1,'victories leaked across characters')
local reward={phase='reward',setupId='setup-1',sessions=run.sessions}
assert(#call('eligibility',reward).eligibleIds==0)

local opened=call('open',nil,run)
assert(opened.applied and opened.state.active.phase=='selecting')
local cancelled=call('cancel',opened.state,opened.state.active.interactionToken)
assert(cancelled.applied and cancelled.state.active==nil)
local stale=call('begin',opened.state,'a','old-token',{})
assert(stale.stale and not stale.applied)
local begun=call('begin',opened.state,'a',opened.state.active.interactionToken,{
 startChatIndex=5,boundary={role='char',data='boundary'},context='context',characterName='A',journalSnapshot={kind='characterJournalView'},
})
assert(begun.applied and begun.state.active.phase=='active')
assert(begun.state.active.sessionId=='setup-1:free:1')
local closed=call('close',begun.state,begun.sessionId,{messages={{role='user',content='hello'}},endChatIndex=7})
assert(closed.state.active.phase=='closing')
local finished=call('finish',closed.state,begun.sessionId,{status='complete',text='summary',truncated=false})
assert(#finished.state.records==1 and finished.state.active.phase=='returning')
local duplicate=call('finish',finished.state,begun.sessionId,{status='complete',text='other',truncated=false})
assert(duplicate.stale and #duplicate.state.records==1)
local returned=call('returned',finished.state,begun.sessionId)
assert(returned.state.active==nil and #returned.state.records==1)
local reopened=call('open',returned.state,run)
assert(reopened.state.nextSessionNumber==2 and #reopened.state.records==1)
local other={phase='characterSelect',setupId='setup-2',characterOffer={interactionToken='run-token-2'},sessions=run.sessions}
local reset=call('open',returned.state,other)
assert(reset.state.setupId=='setup-2' and #reset.state.records==0)
print('PASS: free training eligibility and transitions')
''')
