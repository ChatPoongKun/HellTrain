"""Exercise every character card in all moods, including hidden intent and plans."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime

lua, _ = runtime(sys.argv[1] if len(sys.argv) > 1 else 'lua54')
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local moods={'rejection','suspicion','ignore','confusion','compliance'}
local deck={'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005','pc_deceiver_003','pc_harmonizer_001','pc_glutton_002','pc_glutton_003','pc_deceiver_001'}
local function clone(v)
 if type(v)~='table' then return v end
 local out={} for k,x in pairs(v) do out[k]=clone(x) end return out
end
local scenarios,plans=0,0
assert(data.registry.roles.unknown==nil,'unknown must not be a real card role')
for characterId,definition in pairs(data.characters) do
 local originalDeck=definition.battle.deck
 local originalCommonDeck=definition.battle.commonDeck
 definition.battle.commonDeck=nil
 local hybrids,planCount=0,0
 assert(#originalDeck>0,characterId..' has no character cards to exercise')
 for _,id in ipairs(originalDeck) do
  local card=data.cards[id]
  if #card.roles==2 then hybrids=hybrids+1 end
  if card.cardType=='plan' then planCount=planCount+1 end
  for _,mood in ipairs(moods) do
   -- A one-card fixture makes selection deterministic without bypassing the selector.
   definition.battle.deck={id}
   local state=checked('battleBootstrap','fromSetup',{battleId='char-audit',seed=12345,playerCardIds=deck,characterId=characterId},data).state
   state.player.baseDrawCount,state.player.maxHandSize=10,10
   state.player.stealth=100
   state.character.mood=mood
   state.character.moodTokens={rejection=1,suspicion=1,ignore=1,confusion=1,compliance=1}
   local initialized=checked('turnInitializer','prepareTurn',state,data,{turnId='char-audit-turn-001'})
   local expected=#card.roles==2 and 'unknown' or card.roles[1]
   assert(initialized.state.characterIntent.publicRole==expected,id)
   local view=checked('viewBuilder','buildBattleView',initialized.state,data,{draft=initialized.draft}).view
   if expected=='unknown' then
    assert(view.character.publicAction.status=='unknown' and view.character.publicAction.role==nil,id..' intent leaked')
   else assert(view.character.publicAction.status=='roleRevealed' and view.character.publicAction.role.id==expected) end
   local forged=clone(initialized.state)
   forged.characterIntent.publicRole=expected=='unknown' and card.roles[1] or 'unknown'
   assert(not runScript('test','stateSchema','validateBattleState',forged,data).ok,'forged intent accepted')
   local projection=checked('turnDraft','project',initialized.state,data,initialized.draft).projection
   local pending=checked('battleRuntime','preparePending',initialized.state,data,projection).pendingTurn
   checked('turnPresentation','build',pending,data)
   checked('turnPromptFormatter','formatPending',pending,data)
   checked('battleRuntime','reusePending',initialized.state,data,pending)
   for _,envelope in ipairs({'publicResult','llmEvent'}) do
    local found=false
    for _,event in ipairs(pending.turnResult[envelope].events) do
     if event.type=='character_intent' then
      assert(event.payload.role==expected and event.payload.roles==nil)
      found=true
     end
    end
    assert(found,'missing intent')
   end
   local committed=checked('battleRuntime','commitPending',initialized.state,data,pending)
   assert(not checked('battleRuntime','commitPending',committed.state,data,pending).applied)
   local recorded=committed.state.history.turns[1].cards.character[1]
   assert(#recorded.roles==#card.roles,'history lost hybrid roles')
   for i,role in ipairs(card.roles) do assert(recorded.roles[i]==role) end
   if card.cardType=='plan' then
    assert(#committed.state.character.planSlots==1,'plan was not placed')
    local plan=card.mechanismData.plan
    local required=plan.selectionAssumption.event.roles[1]
    -- Check role gating and condition-at-trigger semantics for every plan.
    for _,role in ipairs({'pressure','deception','violation'}) do
     local context={mood=mood,character={moodTokens=state.character.moodTokens},plan={remainingTurns=plan.durationTurns,remainingCharges=1}}
     local event={type='card_declared',side='player',roles={role}}
     local result=checked('effectEngine','evaluateTrigger',data,plan,context,event)
     assert(result.matched==(required==nil or required==role),id..' trigger role')
    end
    local nextTurn=checked('turnInitializer','prepareTurn',committed.state,data,{turnId='char-audit-turn-002'})
    local chosen
    for _,instance in ipairs(nextTurn.state.cardInstances) do
     if instance.owner=='player' and instance.zone=='hand' then
      local pc=data.cards[instance.cardId]
      for _,role in ipairs(pc.roles) do
       if (required==nil or role==required) and pc.cardType=='action' and not pc.effectChoices and not pc.canPlay then chosen=instance end
      end
     end
    end
    assert(chosen,'no matching fixture card for '..id)
    local token=checked('turnDraft','inspect',nextTurn.state,data,nextTurn.draft).interactionToken
    local selected=checked('turnDraft','applyInteraction',nextTurn.state,data,nextTurn.draft,{action='register',instanceId=chosen.instanceId,expectedInteractionToken=token})
    local nextProjection=checked('turnDraft','project',nextTurn.state,data,selected.draft).projection
    local nextPending=checked('battleRuntime','preparePending',nextTurn.state,data,nextProjection).pendingTurn
    checked('turnPresentation','build',nextPending,data)
    checked('turnPromptFormatter','formatPending',nextPending,data)
    checked('battleRuntime','commitPending',nextTurn.state,data,nextPending)
    local fired=false
    for _,event in ipairs(nextPending.turnResult.events) do
     if event.type=='effect_applied' and event.source and event.source.kind=='plan' then fired=true end
    end
    assert(fired,id..' plan did not apply')
    plans=plans+1
   end
   scenarios=scenarios+1
  end
 end
 definition.battle.deck=originalDeck
 definition.battle.commonDeck=originalCommonDeck
 print('character pipeline:',characterId,#originalDeck,'cards,',hybrids,'hybrids,',planCount,'plans')
end
print('character pipeline complete:',scenarios,'scenarios,',plans,'plan resolutions')
''')
