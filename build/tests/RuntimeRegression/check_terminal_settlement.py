from pathlib import Path
import re,sys
from importlib import import_module
LuaRuntime=import_module('lupa.'+('luajit21' if len(sys.argv)>1 and sys.argv[1]=='jit' else 'lua54')).LuaRuntime
s=re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@",Path('build/tests/setup-to-battle-flow-check.ps1').read_text(encoding='utf-8-sig'),re.S)[1]
s=s[:s.index('print("DEBUG_SELECTED=')]
s=s.replace('local selectedCharacterId = candidates[1]', 'local selectedCharacterId = candidates[2]')
s+='''
setmetatable(modules,{__index=function(t,n)local h=loadLore('System/'..n..'.lua');rawset(t,n,h);return h end})
json=dofile('build/tests/fixtures/json.lua')
lorePaths['postBattle.html']='html/postBattle.html'
local data=assertOk('data',runScript('test','staticData','loadAll')).data
local function call(m,a,...)return assertOk(m..'.'..a,runScript('test',m,a,...))end
local initial
for stealth=1,30 do
 local state=call('battleBootstrap','fromSetup',{battleId=receipt.battleSpec.battleId,seed=receipt.battleSpec.seed,playerCardIds=receipt.selectedCardIds,characterId=receipt.selectedCharacterId},data).state
 state.player.stealth=stealth;state.character.mood='rejection'
 local candidate=call('turnInitializer','prepareTurn',state,data,{turnId=state.battleId..'-turn-001'})
 local projection=call('turnDraft','project',candidate.state,data,candidate.draft).projection
 local pending=call('battleRuntime','preparePending',candidate.state,data,projection).pendingTurn
 for _,e in ipairs(pending.turnResult.publicResult.events) do
  if e.type=='outcome' and e.payload.reasonCode=='mood_state_checkpoint' then initial=candidate break end
 end
 if initial then break end
end
assert(initial,'no mood defeat fixture')
states['battleRuntimeV1.authority']=initial.state
states['battleRuntimeV1.draft']=initial.draft
local chat={{role='char',data='Approach scene'}}
function getFullChat()return clone(chat)end
function addChat(_,role,text)chat[#chat+1]={role=role,data=text}end
function removeChat(_,index)table.remove(chat,index+1)end
local token=call('turnDraft','inspect',initial.state,data,initial.draft).interactionToken
call('battleController','publishCurrentView')
call('battleController','armSubmission',token)
call('battleController','prepareGeneration')
call('battleController','injectRequest',{{role='user',content=chat[#chat].data}})
addChat('test','char','Battle ended.')
local fixedController=modules.battleController
local previousSource,count=readFile('System/battleController.lua'):gsub('                and outcomePayload.reasonCode ~= "mood_state_checkpoint"','')
assert(count==1)
modules.battleController=assert(load('return '..previousSource))()
local failed=runScript('test','battleController','commitOutput')
assert(not failed.ok and failed.errors[1].code=='invalid_terminal_events')
local alreadyCommitted=canonical(states['battleRuntimeV1.authority'])
modules.battleController=fixedController
local committed=call('battleController','commitOutput')
assert(canonical(states['battleRuntimeV1.authority'])==alreadyCommitted,'recovery applied the turn twice')
assert(committed.view.result.reasonCode=='mood_state_checkpoint')
assert(committed.view.result.reasonLabel=='무드 효과로 은폐 소진')
local summary=call('battleController','getTerminalSummary').summary
assert(summary.status=='defeat' and summary.finalStealth<=0)
call('battleController','commitOutput')
print('real controller mood defeat -> settlement -> result -> duplicate commit: OK')
-- Test the sibling turn-start reason through the settlement and result APIs.
local saved=clone(summary)
for _,reason in ipairs({'mood_state_checkpoint','turn_start_checkpoint'}) do
 local value=clone(saved);value.reasonCode=reason
 local result=call('runProgression','settle',nil,receipt,value,data)
 call('runProgression','validate',result.state,receipt,data)
 call('runProgressionView','build',result.state,receipt,data)
 assert(not call('runProgression','settle',result.state,receipt,value,data).applied)
 local bad=clone(value);bad.finalStealth=1
 assert(not runScript('test','runProgression','settle',nil,receipt,bad,data).ok)
 bad.turnNumber=bad.turnLimit;bad.turnId=bad.battleId..string.format('-turn-%03d',bad.turnLimit)
 assert(not runScript('test','runProgression','settle',nil,receipt,bad,data).ok)
end
local startVictory=clone(saved);startVictory.reasonCode='turn_start_checkpoint';startVictory.status='victory';startVictory.finalResistance=0;startVictory.finalStealth=1
local won=call('runProgression','settle',nil,receipt,startVictory,data)
call('runProgressionView','build',won.state,receipt,data)
local bad=clone(saved);bad.status='victory';bad.finalResistance=0
assert(not runScript('test','runProgression','settle',nil,receipt,bad,data).ok)
print('terminal reason acceptance and invalid-resource rejection: OK')
'''
LuaRuntime().execute(s)
# A new resolver outcome must also be accepted and labelled by settlement.
def reasons(path, table):
    text=Path(path).read_text(encoding='utf-8')
    block=re.search(r'local '+table+r' = \{(.*?)\n    \}',text,re.S)[1]
    return set(re.findall(r'^\s*([a-z_]+)\s*=',block,re.M))
expected=reasons('System/turnPresentation.lua','OUTCOME_REASONS')
assert expected==reasons('System/runProgression.lua','OUTCOME_REASONS')
assert expected==reasons('System/runProgressionView.lua','REASON_LABELS')
assert expected==set(re.findall(r'outcomePayload.reasonCode ~= "([a-z_]+)"',Path('System/battleController.lua').read_text(encoding='utf-8')))
print('all terminal reason consumers agree:',len(expected))
