"""Check both conditional plan-removal choices with real active plan fixtures."""
from pathlib import Path
import re,sys
from importlib import import_module
LuaRuntime=import_module('lupa.'+('luajit21' if len(sys.argv)>1 and sys.argv[1]=='jit' else 'lua54')).LuaRuntime
s=re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@",Path('build/tests/turn-phase-draw-replay-check.ps1').read_text(encoding='utf-8-sig'),re.S)[1]
s=s[:s.index('local function runPass')]
s+='''
setmetatable(modules,{__index=function(t,n)local h=loadLore('System/'..n..'.lua');rawset(t,n,h);return h end})
json=dofile('build/tests/fixtures/json.lua')
local data=assertOk('data',runScript('test','staticData','loadAll')).data
for _,hasPlans in ipairs({false,true}) do
for _,choice in ipairs({'player_plan','character_plan'}) do
 local state=newState(data,'plan-choice',{playerBaseDrawCount=5,
  playerDeck={'pc_deceiver_006','pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004'},
  characterPlanCardId=hasPlans and 'jiyoung_silent_glare' or nil,characterPlanRemainingCharges=1})
 if not hasPlans then
  state.player.planSlots={}
  state.cardInstances[1].zone='discard';state.cardInstances[1].position=1
 end
 local initialized=assertOk('initialize',runScript('test','turnInitializer','prepareTurn',state,data,{turnId='plan-choice-turn-001'}))
 local view=assertOk('view',runScript('test','viewBuilder','buildBattleView',initialized.state,data,{draft=initialized.draft})).view
 local found=false
 for _,item in ipairs(view.hand.items) do
  if item.cardId=='pc_deceiver_006' then
   found=true
   for _,effect in ipairs(item.effectChoices) do assert(effect.selectable==hasPlans,'view choice mismatch') end
  end
 end
 assert(found)
 local token=assertOk('inspect',runScript('test','turnDraft','inspect',initialized.state,data,initialized.draft)).interactionToken
 local selected=runScript('test','turnDraft','applyInteraction',initialized.state,data,initialized.draft,{action='choose',instanceId='plan-choice-p1',choiceId=choice,expectedInteractionToken=token})
 if not hasPlans then assert(not selected.ok and selected.errors[1].code=='effect_choice_unavailable') else
 local draft=assertOk('choose '..choice,selected).draft
 local projection=assertOk('project',runScript('test','turnDraft','project',initialized.state,data,draft)).projection
 local pending=assertOk('pending '..choice,runScript('test','battleRuntime','preparePending',initialized.state,data,projection)).pendingTurn
 assertOk('presentation',runScript('test','turnPresentation','build',pending,data))
 assertOk('prompt',runScript('test','turnPromptFormatter','formatPending',pending,data))
 local committed=assertOk('commit',runScript('test','battleRuntime','commitPending',initialized.state,data,pending))
 assert(not assertOk('duplicate',runScript('test','battleRuntime','commitPending',committed.state,data,pending)).applied)
 print('active plan choice OK',choice)
 end
end
end
'''
LuaRuntime().execute(s)
