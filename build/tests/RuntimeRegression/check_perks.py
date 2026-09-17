"""Exercise every perk through turn preparation, resolution, presentation and commit."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime
lua, _ = runtime('lua54')
lua.globals().firstGroup = int(sys.argv[1]) if len(sys.argv)>1 else 1
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local groups={
 {'perk_chain_recovery','perk_stealth_overflow','perk_pressure_cycle'},
 {'perk_damage_draw','perk_stealth_pressure','perk_positive_stockpile'},
 {'perk_manipulation_damage','perk_negative_violation','perk_backlash_conversion'},
 {'perk_token_consumption','perk_positive_stockpile','perk_starting_stealth'},
 {'perk_positive_tiebreak','perk_mood_refund','perk_end_calm'},
 {'perk_extra_plan','perk_insight_strike','perk_starting_stealth'},
}
local ids={} for id,c in pairs(data.cards) do if c.owner=='player' then ids[#ids+1]=id end end table.sort(ids)
local passed=0
for gi,perks in ipairs(groups) do
 if gi>=firstGroup then
 for _,mood in ipairs({'rejection','suspicion','ignore','confusion','compliance'}) do
  for _,id in ipairs(ids) do
   local deck={id,'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005','pc_deceiver_003','pc_harmonizer_001','pc_glutton_002','pc_glutton_003'}
   local state=checked('battleBootstrap','fromSetup',{battleId='audit',seed=12345,playerCardIds=deck,perkIds=perks,characterId='yoo_jiyoung'},data).state
   if gi==4 or gi==6 then assert(state.player.stealth==35) end
   if gi==6 then assert(state.player.planCapacity==2) end
   state.player.baseDrawCount,state.player.maxHandSize=10,10
   state.character.mood=mood
   state.character.moodTokens={rejection=3,suspicion=3,ignore=0,confusion=3,compliance=3}
   local initialized=checked('turnInitializer','prepareTurn',state,data,{turnId='audit-turn-001'})
   local instance
   for _,v in ipairs(initialized.state.cardInstances) do if v.owner=='player' and v.zone=='hand' and v.cardId==id then instance=v.instanceId break end end
   assert(instance,id)
   for _,choice in ipairs(data.cards[id].effectChoices or {{}}) do
    local token=checked('turnDraft','inspect',initialized.state,data,initialized.draft).interactionToken
    local selected=runScript('audit','turnDraft','applyInteraction',initialized.state,data,initialized.draft,{action=choice.id and 'choose' or 'register',instanceId=instance,choiceId=choice.id,expectedInteractionToken=token})
    if selected.ok then
     local projection=checked('turnDraft','project',initialized.state,data,selected.draft).projection
     local pending=checked('battleRuntime','preparePending',initialized.state,data,projection).pendingTurn
     checked('turnPresentation','build',pending,data)
     checked('turnPromptFormatter','formatPending',pending,data)
     checked('battleRuntime','reusePending',initialized.state,data,pending)
     local committed=checked('battleRuntime','commitPending',initialized.state,data,pending)
     assert(not checked('battleRuntime','commitPending',committed.state,data,pending).applied)
     passed=passed+1
    else
     assert(selected.errors[1].code=='card_not_playable' or selected.errors[1].code=='effect_choice_unavailable')
    end
   end
  end
 end
 print('perk group',gi,'passed',passed)
 end
end
print('perk pipeline scenarios:',passed)
''')
