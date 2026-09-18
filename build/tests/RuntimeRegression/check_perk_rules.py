"""Boundary assertions for all sixteen perk rules, without host UI dependencies."""
from pathlib import Path
import sys
sys.path.insert(0,str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime
lua,_=runtime('lua54')
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local deck={'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005','pc_deceiver_003','pc_harmonizer_001','pc_glutton_002','pc_glutton_003','pc_deceiver_001'}
local function new(perks)
 return checked('battleBootstrap','fromSetup',{battleId='rules',seed=123,playerCardIds=deck,perkIds=perks,characterId='yoo_jiyoung'},data).state
end
local function pipe(s,event,options)
 return checked('triggerPipeline','run',data,{state=s},event,options or {phase=event.type})
end
local function start(s) return pipe(s,{type='turn_start',turnNumber=s.turnNumber}) end
local function cardEvent(s,id,event,count)
 local c=data.cards[id]
 return pipe(s,{type=event,side='player',roles=c.roles},
  {phase='player_card',playerPressureCardsResolved=count or 1,currentCard={id=id,instanceId='rule-card',owner='player',roles=c.roles}})
end
local function damage(before,after) return before.character.resistance-after.state.character.resistance end
local s=new({'perk_extra_plan','perk_starting_stealth'})
assert(s.player.stealth==35 and s.player.planCapacity==2)
assert(new({}).player.stealth==30 and new({}).player.planCapacity==1)
assert(not runScript('test','battleBootstrap','fromSetup',{battleId='rules',seed=1,playerCardIds=deck,characterId='yoo_jiyoung',perkIds={'perk_extra_plan','perk_extra_plan'}},data).ok)
s=new({'perk_stealth_pressure'})
for _,n in ipairs({14,15,30}) do s.player.stealth=n assert(damage(s,start(s))==(n>=15 and 1 or 0)) end
s=new({'perk_positive_stockpile','perk_token_consumption'})
s.character.moodTokens.confusion=2;s.character.moodTokens.compliance=3
local r=start(s)
assert(damage(s,r)==7,'stockpile snapshot must survive consumption')
local left=0 for _,n in pairs(r.state.character.moodTokens) do left=left+n end assert(left==4)
assert(json.encode(start(s).state)==json.encode(r.state),'same seed must replay')
s=new({'perk_token_consumption'})
assert(damage(s,start(s))==0 and start(s).state.rng.cursor==s.rng.cursor)
s.character.moodTokens.ignore=1;r=start(s)
assert(damage(s,r)==2 and r.state.character.moodTokens.ignore==0 and r.state.rng.cursor==s.rng.cursor)
s.character.moodTokens.compliance=3
assert(start(s).state.rng.cursor>s.rng.cursor)

local chain, deceptionChain, pressure, insight, violation
for id,c in pairs(data.cards) do if c.owner=='player' then
 if c.cardType=='chain' then chain=id end
 for _,role in ipairs(c.roles) do
  if role=='deception' and c.cardType=='chain' then deceptionChain=id end
  if role=='pressure' then pressure=id end
  if role=='violation' then violation=id end
 end
 for _,m in ipairs(c.mechanisms) do if m=='insight' then insight=id end end
end end
assert(chain and deceptionChain and pressure and insight and violation)
s=new({'perk_chain_recovery','perk_stealth_overflow'})
for _,n in ipairs({25,26,30}) do
 s.player.stealth=n;r=cardEvent(s,deceptionChain,'card_resolved')
 assert(r.state.player.stealth==n+1 and damage(s,r)==math.max(0,n-25),'same batch snapshot')
end
assert(cardEvent(s,chain,'card_declared').state.player.stealth==s.player.stealth)
s=new({'perk_pressure_cycle'})
for n=1,7 do assert(damage(s,cardEvent(s,pressure,'card_resolved',n))==(n%3==0 and 2 or 0)) end
s=new({'perk_insight_strike'})
assert(damage(s,cardEvent(s,insight,'card_declared'))==0)
s.cardInstances[#s.cardInstances+1]={instanceId='hidden-plan',cardId='jiyoung_silent_glare',owner='character',zone='plan',position=1}
s.character.planSlots={{occupied=true,cardInstanceId='hidden-plan',cardId='jiyoung_silent_glare',placedTurn=1,remainingCharges=1,remainingTurns=2,revealed=false}}
assert(damage(s,cardEvent(s,insight,'card_declared'))==3)
assert(not s.character.planSlots[1].revealed)
s=new({'perk_negative_violation','perk_manipulation_damage'})
for _,mood in ipairs({'rejection','suspicion','ignore','confusion','compliance'}) do
 s.character.mood=mood;r=cardEvent(s,violation,'card_declared')
 local n=0 for _,v in pairs(r.state.character.moodTokens) do n=n+v end
 assert(n==((mood=='rejection' or mood=='suspicion') and 1 or 0))
 assert(damage(s,r)==0)
end
local function semantic(term,side,mood,n,debt)
 local state=new({'perk_manipulation_damage','perk_backlash_conversion'})
 state.character.mood=mood
 local applied=checked('effectEngine','applyCommands',data,{state=state,transient={moodTokenDebt={compliance=debt or 0}}},
  {{op='add_mood_token',target='character',mood='compliance',amount=n,cause='cardEffect',ruleTerm=term}})
 local reacted=checked('triggerPipeline','react',data,{state=applied.state,transient=applied.transient},
  {{type='effect_applied',source={kind='card',side=side,id=deck[1]},payload=applied.applied[1]}},{phase='player_card'})
 return state,reacted
end
for _,n in ipairs({1,3}) do
 for _,m in ipairs({'ignore','confusion','compliance'}) do
  s,r=semantic('manipulate','player',m,n,5);assert(damage(s,r)==(m=='ignore' and 0 or n))
 end
 s,r=semantic('backlash','player','ignore',n);assert(damage(s,r)==n and s.player.stealth-r.state.player.stealth==n)
 s,r=semantic('backlash','character','ignore',n);assert(damage(s,r)==0 and s.player.stealth==r.state.player.stealth)
 s,r=semantic(nil,'player','compliance',n);assert(damage(s,r)==0)
end
s=new({'perk_end_calm'});s.character.mood='ignore'
r=pipe(s,{type='turn_end'});assert(r.transient.moodTokenDebt.suspicion==1)
local function mood(tokens,tie,forced,before)
 return checked('effectEngine','projectMood',data,{turnNumber=1,mood=before or 'ignore',moodTokens=tokens,positiveTiebreak=tie,forcedMoodRequests=forced or {}}).resolution
end
for _,case in ipairs({
 {{rejection=2,compliance=2},'ignore','none'},
 {{rejection=3,compliance=3},'compliance','token'},
 {{rejection=4,compliance=3},'rejection','token'},
 {{rejection=3,confusion=3,compliance=3},'compliance','token'},
}) do local x=mood(case[1],true) assert(x.mood==case[2] and x.payload.resolution==case[3]) end
local x=mood({rejection=3,compliance=3},false);assert(x.payload.resolution=='tie' and x.moodTokens.compliance==2)
x=mood({rejection=3,compliance=3},true,{{mood='suspicion'}});assert(x.mood=='suspicion' and x.moodTokens.compliance==3)
x=mood({rejection=3,compliance=3},true,{{mood='suspicion'},{mood='confusion'}});assert(x.mood=='compliance' and x.moodTokens.compliance==0)
s=new({'perk_mood_refund'})
for _,case in ipairs({{'ignore','suspicion',3,3},{'ignore','ignore',3,0},{'ignore','compliance',0,0}}) do
 r=pipe(s,{type='mood_resolved',before=case[1],after=case[2],consumed=case[3]},{phase='turn_end'})
 assert(r.state.player.stealth-s.player.stealth==case[4])
end
local function prepare(state)
 return checked('turnInitializer','prepareTurn',state,data,{turnId=state.battleId..string.format('-turn-%03d',state.turnNumber)})
end
local function finish(initialized,draft)
 local projection=checked('turnDraft','project',initialized.state,data,draft or initialized.draft).projection
 local pending=checked('battleRuntime','preparePending',initialized.state,data,projection).pendingTurn
 checked('turnPresentation','build',pending,data)
 return checked('battleRuntime','commitPending',initialized.state,data,pending).state,pending
end
for _,n in ipairs({5,6,12}) do
 s=new({'perk_damage_draw','perk_positive_stockpile'})
 s.character.resistance=100;s.character.moodTokens.confusion=n
 local completed=finish(prepare(s))
 assert(completed.history.turns[1].playerResistanceDamage==n,'total damage must include turn-start perk')
 local nextTurn=prepare(completed);local drawn=0
 for _,event in ipairs(nextTurn.state.turnStartReceipt.events) do
  if event.type=='effect_applied' and event.source.id=='perk_damage_draw' then drawn=drawn+event.payload.amount end
 end
 assert(drawn==(n>=6 and 1 or 0),'draw threshold, once only even for 12 damage')
end
s=new({'perk_pressure_cycle'});s.character.resistance=1000;s.player.stealth=1000
s.player.baseDrawCount,s.player.maxHandSize=10,10
for turn=1,3 do
 local initialized=prepare(s);local selected
 local token=checked('turnDraft','inspect',initialized.state,data,initialized.draft).interactionToken
 for _,instance in ipairs(initialized.state.cardInstances) do
  if instance.owner=='player' and instance.zone=='hand' then
   local isPressure=false for _,role in ipairs(data.cards[instance.cardId].roles) do if role=='pressure' then isPressure=true end end
   if isPressure and not data.cards[instance.cardId].effectChoices then
    local result=runScript('test','turnDraft','applyInteraction',initialized.state,data,initialized.draft,{action='register',instanceId=instance.instanceId,expectedInteractionToken=token})
    if result.ok then selected=result.draft break end
   end
  end
 end
 assert(selected,'pressure card available')
 local pending;s,pending=finish(initialized,selected)
 local fired=0
 for _,event in ipairs(pending.turnResult.publicResult.events) do
  if event.type=='effect_applied' and event.payload.source and event.payload.source.id=='perk_pressure_cycle' then fired=fired+1 end
 end
 assert(fired==(turn==3 and 1 or 0),'pressure count must persist across turn boundaries')
end
s=new({'perk_insight_strike','perk_extra_plan'})
s.player.baseDrawCount,s.player.maxHandSize=10,10
s.cardInstances[1].cardId='pc_deceiver_006'
s.cardInstances[#s.cardInstances+1]={instanceId='hidden-plan',cardId='jiyoung_silent_glare',owner='character',zone='plan',position=1}
s.character.planSlots={{occupied=true,cardInstanceId='hidden-plan',cardId='jiyoung_silent_glare',placedTurn=1,remainingCharges=1,remainingTurns=2,revealed=false}}
local initialized=prepare(s)
local token=checked('turnDraft','inspect',initialized.state,data,initialized.draft).interactionToken
local chosen=checked('turnDraft','applyInteraction',initialized.state,data,initialized.draft,{action='choose',instanceId=s.cardInstances[1].instanceId,choiceId='character_plan',expectedInteractionToken=token}).draft
local completed,pending=finish(initialized,chosen)
-- The character may place a new plan after the player's removal resolves.
-- Verify the targeted instance, independently of the selector's current weights.
for _,slot in ipairs(completed.character.planSlots) do
 assert(slot.cardInstanceId~='hidden-plan','removed plan remains active')
end
local removed=false
for _,instance in ipairs(completed.cardInstances) do
 if instance.instanceId=='hidden-plan' then
  assert(instance.zone=='discard','removed plan was not discarded')
  removed=true
 end
end
assert(removed,'removed plan instance was lost')
local strike=false
for _,event in ipairs(pending.turnResult.publicResult.events) do
 if event.type=='effect_applied' and event.payload.source and event.payload.source.id=='perk_insight_strike' then assert(event.payload.amount==3);strike=true end
end
assert(strike and not json.encode(pending.turnResult.llmEvent):find('jiyoung_silent_glare',1,true))
s=new({'perk_extra_plan'})
local planIds={} for id,c in pairs(data.cards) do if c.owner=='player' and c.cardType=='plan' then planIds[#planIds+1]=id end end table.sort(planIds)
for i=1,3 do
 local id=planIds[i];local p=data.cards[id].mechanismData.plan
 local instance='extra-plan-'..i
 s.cardInstances[#s.cardInstances+1]={instanceId=instance,cardId=id,owner='player',zone='hand',position=1}
 s=checked('cardZones','placePlan',s,'player',instance,{durationTurns=p.durationTurns,charges=p.charges,revealed=false}).state
 assert(#s.player.planSlots==math.min(i,2))
end
assert(s.player.planSlots[1].cardInstanceId=='extra-plan-2' and s.player.planSlots[2].cardInstanceId=='extra-plan-3')
-- A controlled plan fixture exercises the automatic-batch semantic boundary.
local plan=data.cards.pc_deceiver_011.mechanismData.plan
local savedEvent,savedSide,savedTrigger,savedResolve=plan.event,plan.side,plan.trigger,plan.resolve
plan.event='turn_start';plan.side=nil;plan.trigger=function()return true end
plan.resolve=function()return {
 {op='add_mood_token',target='character',mood='compliance',amount=3,cause='cardEffect',ruleTerm='manipulate'},
 {op='add_mood_token',target='character',mood='ignore',amount=2,cause='cardEffect',ruleTerm='backlash'},
} end
s=new({'perk_manipulation_damage','perk_backlash_conversion','perk_damage_draw'})
s.character.mood='compliance'
s.cardInstances[#s.cardInstances+1]={instanceId='semantic-plan',cardId='pc_deceiver_011',owner='player',zone='plan',position=1}
s.player.planSlots={{occupied=true,cardInstanceId='semantic-plan',cardId='pc_deceiver_011',placedTurn=1,remainingTurns=4,remainingCharges=2,revealed=false}}
initialized=prepare(s)
assert(initialized.state.character.resistance==s.character.resistance-5 and initialized.state.player.stealth==s.player.stealth-2)
finish(initialized)
plan.event,plan.side,plan.trigger,plan.resolve=savedEvent,savedSide,savedTrigger,savedResolve
-- Atomic removal has no reward or RNG consumption when the live state is empty.
s=new({})
local empty=checked('effectEngine','applyCommands',data,{state=s},{{op='random_token_strike',target='character',amount=2,cause='perkEffect'}})
assert(not empty.applied[1].changed and empty.state.character.resistance==s.character.resistance and empty.state.rng.cursor==s.rng.cursor)
for seed=1,40 do
 s.rng.seed=seed;s.character.moodTokens.ignore=1;s.character.moodTokens.compliance=3
 local pick=checked('deterministicRng','nextInteger',s.rng,1,4)
 local result=checked('effectEngine','applyCommands',data,{state=s},{{op='random_token_strike',target='character',amount=2,cause='perkEffect'}})
 assert(result.applied[1].mood==(pick.value==1 and 'ignore' or 'compliance'),'individual-token weighting')
end
-- The public projector must reject a changed RNG receipt, not merely trust it.
s=new({'perk_token_consumption'});s.character.moodTokens.ignore=1;s.character.moodTokens.compliance=3
initialized=prepare(s)
local projection=checked('turnDraft','project',initialized.state,data,initialized.draft).projection
local resolved=checked('turnResolver','resolveTurn',initialized.state,data,projection,{turnId=initialized.state.turnStartReceipt.turnId}).resolution
checked('turnEventProjector','projectTurn',initialized.state,data,resolved)
local corrupted=false
for _,event in ipairs(resolved.events) do
 if event.type=='effect_applied' and event.payload.op=='random_token_strike' then event.payload.after.rng.cursor=event.payload.after.rng.cursor+1;corrupted=true;break end
end
assert(corrupted and not runScript('test','turnEventProjector','projectTurn',initialized.state,data,resolved).ok)
print('16 perk rules: boundaries/history, hidden plans, extra slots, automatic semantic reactions and RNG integrity: OK')
''')
