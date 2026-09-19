"""Run every player card and choice through real turn and presentation modules."""
from pathlib import Path
import sys
sys.path.insert(0,str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime
lua,_=runtime(sys.argv[1] if len(sys.argv)>1 else 'lua54')
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local ids={} for id,card in pairs(data.cards) do if card.owner=='player' then ids[#ids+1]=id end end table.sort(ids)
local moods={'rejection','suspicion','ignore','confusion','compliance'}
local passed,skipped,seen=0,0,{}
assert(#ids>0,'no player card IDs loaded')
for _,mood in ipairs(moods) do
 for _,id in ipairs(ids) do
  local card=data.cards[id]
  local deck={id,'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005','pc_deceiver_003','pc_harmonizer_001','pc_glutton_002','pc_glutton_003'}
  local state=checked('battleBootstrap','fromSetup',{battleId='audit',seed=12345,playerCardIds=deck,characterId='yoo_jiyoung'},data).state
  state.player.baseDrawCount,state.player.maxHandSize=10,10
  state.character.mood=mood
  state.character.moodTokens={rejection=1,suspicion=1,ignore=1,confusion=1,compliance=1}
  -- Both choices require an active plan; a no-plan fixture can only reject this card.
  if id=='pc_deceiver_006' then
   for side,planId in pairs({player='pc_deceiver_010',character='jiyoung_silent_glare'}) do
    local plan=data.cards[planId].mechanismData.plan
    local planInstance='audit-fixture-'..side..'-plan'
    state.cardInstances[#state.cardInstances+1]={instanceId=planInstance,cardId=planId,owner=side,zone='plan',position=1}
    state[side].planSlots={{occupied=true,cardInstanceId=planInstance,cardId=planId,placedTurn=1,
     remainingTurns=plan.durationTurns,remainingCharges=plan.charges,revealed=false}}
   end
  end
  local initialized=checked('turnInitializer','prepareTurn',state,data,{turnId='audit-turn-001'})
  local instance
  for _,v in ipairs(initialized.state.cardInstances) do if v.owner=='player' and v.zone=='hand' and v.cardId==id then instance=v.instanceId break end end
  assert(instance,id)
  for _,choice in ipairs(card.effectChoices or {{}}) do
   local token=checked('turnDraft','inspect',initialized.state,data,initialized.draft).interactionToken
   local selected=runScript('audit','turnDraft','applyInteraction',initialized.state,data,initialized.draft,{action=choice.id and 'choose' or 'register',instanceId=instance,choiceId=choice.id,expectedInteractionToken=token})
   local fast=runScript('audit','turnDraft','applySelection',initialized.state,data,initialized.draft,{action=choice.id and 'choose' or 'register',instanceId=instance,choiceId=choice.id,expectedInteractionToken=token})
   assert(equal(selected,fast),'fast selection differs: '..id..'/'..mood..'/'..(choice.id or 'default'))
   if fast.ok then
    local cancel={action='cancel',instanceId=instance,expectedInteractionToken=fast.interactionToken}
    local normalCancel=runScript('audit','turnDraft','applyInteraction',initialized.state,data,fast.draft,cancel)
    local fastCancel=runScript('audit','turnDraft','applySelection',initialized.state,data,fast.draft,cancel)
    assert(equal(normalCancel,fastCancel),'fast cancellation differs: '..id)
   end
   selected=fast
   if not selected.ok then
    local e=selected.errors[1]
    assert(e.code=='card_not_playable' or e.code=='effect_choice_unavailable',id..'/'..mood..': '..e.code..' '..e.message)
    skipped=skipped+1
   else
    local projection=checked('turnDraft','project',initialized.state,data,selected.draft).projection
    local pending=checked('battleRuntime','preparePending',initialized.state,data,projection).pendingTurn
    checked('turnPresentation','build',pending,data)
    checked('turnPromptFormatter','formatPending',pending,data)
    checked('battleRuntime','reusePending',initialized.state,data,pending)
    local committed=checked('battleRuntime','commitPending',initialized.state,data,pending)
    assert(not checked('battleRuntime','commitPending',committed.state,data,pending).applied)
    local declared=false
    for _,event in ipairs(pending.turnResult.events) do
     if event.type=='card_declared' and event.payload.instanceId==instance
      and event.payload.cardId==id and event.payload.effectChoiceId==choice.id then declared=true end
    end
    assert(declared,'card was not played: '..id..'/'..(choice.id or 'default'))
    passed=passed+1
    seen[id]=seen[id] or {}
    seen[id][choice.id or 'default']=true
   end
  end
 end
 print('player pipeline mood done:',mood,passed,skipped)
end
local missing={}
for _,id in ipairs(ids) do
 for _,choice in ipairs(data.cards[id].effectChoices or {{}}) do
  local choiceId=choice.id or 'default'
  if not seen[id] or not seen[id][choiceId] then missing[#missing+1]=id..'/'..choiceId end
 end
end
assert(#missing==0,'missing successful player card IDs/choices: '..table.concat(missing,', '))
local count=0
for id in pairs(seen) do
 assert(data.cards[id] and data.cards[id].owner=='player','unexpected successful card ID: '..id)
 count=count+1
end
print('player pipeline:',count,'cards,',passed,'legal scenarios,',skipped,'unavailable choices')
''')
