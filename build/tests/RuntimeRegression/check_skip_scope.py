from pathlib import Path
import sys,re
from importlib import import_module
LuaRuntime=import_module('lupa.'+('luajit21' if len(sys.argv)>1 and sys.argv[1]=='jit' else 'lua54')).LuaRuntime
lua=LuaRuntime()
s=re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@",Path('build/tests/turn-phase-draw-replay-check.ps1').read_text(encoding='utf-8-sig'),re.S)[1]
s=s[:s.index('local function runPass')]
s=s.replace('local modules = {','local modules = {\n battleRuntime=loadLore("System/battleRuntime.lua"),\n turnPresentation=loadLore("System/turnPresentation.lua"),\n turnPromptFormatter=loadLore("System/turnPromptFormatter.lua"),')
s+='''
json=dofile('build/tests/fixtures/json.lua')
local data=assertOk('data',runScript('test','staticData','loadAll')).data
local state=newState(data,'skip-scope',{playerBaseDrawCount=5,playerDeck={
 'pc_glutton_014','pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004'
}})
local initialized=assertOk('initialize',runScript('test','turnInitializer','prepareTurn',state,data,{turnId='skip-scope-turn-001'}))
local draft=assertOk('register',runScript('test','turnDraft','registerCard',initialized.state,data,initialized.draft,'skip-scope-p1')).draft
local projection=assertOk('project',runScript('test','turnDraft','project',initialized.state,data,draft)).projection
local resolution=assertOk('resolve',runScript('test','turnResolver','resolveTurn',initialized.state,data,projection,{turnId='skip-scope-turn-001'})).resolution
local stopped=false
for _,event in ipairs(resolution.events) do
 if event.type=='action_sequence_stopped' and event.payload.side=='character' then
  assert(event.payload.reasonCode=='skip_actions' and #event.payload.unresolvedInstanceIds>0)
  stopped=true
 end
 assert(not(event.type=='card_declared' and event.side=='character'))
end
assert(stopped,'character actions were not skipped')
local pending=assertOk('preparePending',runScript('test','battleRuntime','preparePending',initialized.state,data,projection)).pendingTurn
assertOk('presentation',runScript('test','turnPresentation','build',pending,data))
assertOk('prompt',runScript('test','turnPromptFormatter','formatPending',pending,data))
assertOk('reuse',runScript('test','battleRuntime','reusePending',initialized.state,data,pending))
local committed=assertOk('commit',runScript('test','battleRuntime','commitPending',initialized.state,data,pending))
assert(assertOk('duplicate',runScript('test','battleRuntime','commitPending',committed.state,data,pending)).applied==false)
local sawSkip=false
for _,event in ipairs(pending.turnResult.publicResult.events) do
 if event.payload.op=='skip_actions' then
  assert(event.payload.scope=='remainingTurn' and event.payload.target=='character' and event.payload.changed)
  sawSkip=true
 end
end
assert(sawSkip)
local nextTurn=assertOk('next turn',runScript('test','turnInitializer','prepareTurn',committed.state,data,{turnId='skip-scope-turn-002'}))
assert(nextTurn.state.turnStartReceipt.transient.skipRemaining.character==false,'skip leaked into next turn')
assert(pending.afterState.character.mood=='ignore')
for _,scope in ipairs({false,'allTurns','remainingTurn'}) do
 local command={op='skip_actions',target='character',cause='cardEffect',scope=scope or nil}
 local result=runScript('test','effectEngine','validateCommands',data,{command})
 assert(result.ok==(scope=='remainingTurn'))
end
print('skip scope: card, pending, presentation, prompt, reuse, commit and invalid scopes OK')
'''
lua.execute(s)
