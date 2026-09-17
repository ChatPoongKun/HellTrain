-- This harness calls the unchanged production domain modules; no LLM or UI is needed.
decks = {
  predator = {'pc_predator_001','pc_predator_002','pc_predator_003',
    'pc_predator_009','pc_predator_009','pc_predator_010','pc_predator_012','pc_predator_012',
    'pc_deceiver_003','pc_deceiver_003'},
  harmonizer = {'pc_harmonizer_001','pc_harmonizer_001','pc_harmonizer_004','pc_harmonizer_004',
    'pc_harmonizer_007','pc_harmonizer_008','pc_harmonizer_012','pc_harmonizer_012',
    'pc_deceiver_003','pc_deceiver_003'},
  glutton = {'pc_glutton_002','pc_glutton_002','pc_glutton_003','pc_glutton_004',
    'pc_glutton_006','pc_glutton_007','pc_glutton_008','pc_glutton_013',
    'pc_deceiver_003','pc_deceiver_003'},
  deceiver = {'pc_deceiver_001','pc_deceiver_001','pc_deceiver_003','pc_deceiver_003',
    'pc_deceiver_005','pc_deceiver_007','pc_deceiver_010','pc_deceiver_012',
    'pc_predator_012','pc_predator_002'},
}
local MI = {rejection=1,suspicion=2,ignore=3,confusion=4,compliance=5}
local function copy(t)
  if type(t)~='table' then return t end
  local r={} for k,v in pairs(t) do r[k]=copy(v) end return r
end
for style,deck in pairs(decks) do
  local counts,off,rare={},0,0
  assert(#deck==10)
  for _,id in ipairs(deck) do
    local c=assert(data.cards[id]); assert(c.rarity~='legendary' and c.owner=='player')
    counts[id]=(counts[id] or 0)+1; assert(counts[id]<=2)
    if c.draftStyle~=style then off=off+1 end
    if c.rarity=='rare' then rare=rare+1 end
  end
  assert(off==2 and rare==2)
end

local function context(state, card, instance, chainCount)
  local hand=0
  for _,i in ipairs(state.cardInstances) do if i.owner=='player' and i.zone=='hand' then hand=hand+1 end end
  return {turn=state.turnNumber,turnLimit=state.turnLimit,
    remainingTurns=state.turnLimit-state.turnNumber+1,phase='player_card',mood=state.character.mood,
    history=checked('battleHistory','context',state.history).context,
    player={stealth=state.player.stealth,handCount=hand,planCount=#state.player.planSlots},
    character={resistance=state.character.resistance,moodTokens=copy(state.character.moodTokens),
      publicRole=state.characterIntent.publicRole,planCount=#state.character.planSlots},
    card={id=card.id,instanceId=instance.instanceId,owner='player',roles=card.roles},
    playerChainCardsResolved=chainCount}
end

local function survivalWeight(state)
  local s=state.player.stealth
  return s<7 and 2.2 or s<13 and 1.3 or s<20 and 0.65 or 0.25
end

-- ponytail: finite-horizon heuristic, not an optimal policy. Use human trials or
-- information-set search before treating these rates as a skill ceiling.
local function planValue(id,state)
  local left=state.turnLimit-state.turnNumber
  if left<=0 then return 0 end
  local charges=math.min(2,left)
  if id=='pc_glutton_008' then
    return charges*3*survivalWeight(state)*(MI[state.character.mood]<=2 and 0.95 or 0.3)
  elseif id=='pc_deceiver_008' then
    return charges*2*(state.player.stealth>=18 and 0.9 or 0.35)+(left>=3 and 2.3 or 0)
  elseif id=='pc_deceiver_012' then
    return charges*4*0.85
  elseif id=='pc_deceiver_010' then
    return charges*3*0.9
  end
  return 0
end

local function evaluate(state,instance,chainCount)
  local card=data.cards[instance.cardId]
  local ctx=context(state,card,instance,chainCount)
  if not checked('effectEngine','evaluateCanPlay',data,card.id,ctx).playable then return nil end
  local cost=card.base.stealthCost
  if state.player.stealth<=cost then return nil end
  local effects=checked('effectEngine','evaluateCardResolve',data,card.id,ctx).commands
  local damage,heal=card.base.resistanceDamage,0
  local moods={}
  for _,c in ipairs(effects) do
    if c.op=='damage_resistance' then damage=damage+c.amount
    elseif c.op=='recover_stealth' then heal=heal+c.amount
    elseif c.op=='add_mood_token' or c.op=='remove_mood_token' or c.op=='force_mood' then moods[#moods+1]=c end
  end
  local sw=survivalWeight(state)
  local score=damage+(heal-cost)*sw
  if damage>=state.character.resistance then score=1000+damage-cost end
  local before=checked('effectEngine','projectMood',data,{turnNumber=state.turnNumber,
    mood=state.character.mood,moodTokens=state.character.moodTokens}).resolution
  local after=checked('effectEngine','projectMood',data,{turnNumber=state.turnNumber,
    mood=state.character.mood,moodTokens=state.character.moodTokens,commands=moods}).resolution
  local future=math.min(1,(state.turnLimit-state.turnNumber)/2)
  score=score+future*((MI[after.mood]-MI[before.mood])*1.5+(after.stealthDelta-before.stealthDelta)*sw)
  for _,c in ipairs(moods) do
    if c.op=='add_mood_token' or c.op=='remove_mood_token' then
      local n=c.op=='add_mood_token' and c.amount or -math.min(c.amount,state.character.moodTokens[c.mood] or 0)
      score=score+future*n*(MI[c.mood]-MI[state.character.mood])*0.25
    end
  end
  if card.id=='pc_predator_009' then score=score+sw*1.3 end
  if card.id=='pc_predator_010' and ctx.remainingTurns>=5 then score=score+1.5 end
  for _,slot in ipairs(state.player.planSlots) do
    if slot.cardId=='pc_deceiver_012' and heal>=3 then score=score+4 end
  end
  if card.cardType=='plan' then
    score=score+planValue(card.id,state)
    for _,slot in ipairs(state.player.planSlots) do
      if #state.player.planSlots>=state.player.planCapacity then
        score=score-math.min(slot.remainingCharges or 0,slot.remainingTurns or 0)*2.5
      end
    end
  end
  return {instance=instance,card=card,score=score,damage=damage,heal=heal,cost=cost,effects=effects}
end

local function choose(state,draft)
  if state.turnStartOutcome then return draft end
  local projected=checked('turnDraft','project',state,data,draft).projection
  local hypothetical=copy(projected.workingState)
  local chains=0
  local originalHand={}
  for _,inst in ipairs(state.cardInstances) do
    if inst.owner=='player' and inst.zone=='hand' then originalHand[inst.instanceId]=true end
  end
  local mainChosen=false
  local speculativeChosen=false
  local function registerMain()
    local best
    for _,inst in ipairs(hypothetical.cardInstances) do
      if inst.owner=='player' and inst.zone=='hand' and data.cards[inst.cardId].cardType~='chain'
        and (not speculativeChosen or not originalHand[inst.instanceId]) then
        local value=evaluate(hypothetical,inst,chains)
        if value and (not best or value.score>best.score) then best=value end
      end
    end
    if best then
      draft=checked('turnDraft','registerCard',state,data,draft,best.instance.instanceId).draft
      best.instance.zone='used'
      mainChosen=true
    end
  end
  while true do
    local best
    for _,inst in ipairs(hypothetical.cardInstances) do
      if inst.owner=='player' and inst.zone=='hand' and data.cards[inst.cardId].cardType=='chain'
        and (not speculativeChosen or not originalHand[inst.instanceId]) then
        local value=evaluate(hypothetical,inst,chains)
        if value then value.rank=value.score+(originalHand[inst.instanceId] and 10000 or 0) end
        if value and value.score>0 and (not best or value.rank>best.rank) then best=value end
      end
    end
    if not best then break end
    -- Register an original-hand main action before speculative chains: the real
    -- UI intentionally resets the speculative branch if an original card is chosen later.
    if not originalHand[best.instance.instanceId] then
      if not mainChosen then registerMain() end
      speculativeChosen=true
    end
    draft=checked('turnDraft','registerCard',state,data,draft,best.instance.instanceId).draft
    local previous=hypothetical
    projected=checked('turnDraft','project',state,data,draft).projection
    hypothetical=copy(projected.workingState)
    hypothetical.player.stealth=previous.player.stealth-best.cost+best.heal
    hypothetical.character.resistance=math.max(0,previous.character.resistance-best.damage)
    hypothetical.character.moodTokens=copy(previous.character.moodTokens)
    for _,c in ipairs(best.effects) do
      if c.op=='add_mood_token' then hypothetical.character.moodTokens[c.mood]=hypothetical.character.moodTokens[c.mood]+c.amount
      elseif c.op=='remove_mood_token' then hypothetical.character.moodTokens[c.mood]=math.max(0,hypothetical.character.moodTokens[c.mood]-c.amount) end
    end
    chains=chains+1
    if hypothetical.character.resistance<=0 then return draft end
    assert(chains<=20,'chain loop')
  end
  if not mainChosen then registerMain() end
  return draft
end

function oneBattle(style,character,seed)
  local state=checked('battleBootstrap','fromSetup',{battleId='sim-'..seed,seed=seed,
    playerCardIds=decks[style],characterId=character},data).state
  local stats={turns=0,damage=0,healing=0,enemyHealing=0,chains=0,actions=0,plans=0,
    moodChanges=0,moods={},cards={},enemyCards={},reason='unknown',planTriggers=0}
  while state.status=='active' do
    local turnId='turn-'..state.turnNumber
    local prepared=checked('turnInitializer','prepareTurn',state,data,{turnId=turnId})
    state=prepared.state
    local mood=state.character.mood; stats.moods[mood]=(stats.moods[mood] or 0)+1
    local draft=choose(state,prepared.draft)
    local projection=checked('turnDraft','project',state,data,draft).projection
    local resolution=checked('turnResolver','resolveTurn',state,data,projection,{turnId=turnId}).resolution
    stats.turns=stats.turns+1
    if resolution.metrics.moodChanged then stats.moodChanges=stats.moodChanges+1 end
    for _,event in ipairs(resolution.events) do
      local p=event.payload or {}
      if event.type=='card_declared' then
        local card=data.cards[p.cardId]
        if card.owner=='player' then
          stats.cards[card.id]=(stats.cards[card.id] or 0)+1
          local key=card.cardType=='chain' and 'chains' or card.cardType=='plan' and 'plans' or 'actions'
          stats[key]=stats[key]+1
        else stats.enemyCards[card.id]=(stats.enemyCards[card.id] or 0)+1 end
      elseif event.type=='effect_applied' and p.changed then
        if p.op=='damage_resistance' then stats.damage=stats.damage+math.max(0,p.before-p.after)
        elseif p.op=='recover_stealth' then stats.healing=stats.healing+math.max(0,p.after-p.before)
        elseif p.op=='recover_resistance' then stats.enemyHealing=stats.enemyHealing+math.max(0,p.after-p.before) end
      elseif event.type=='trigger_resolved' and event.source and event.source.kind=='plan' and event.side=='player' then
        stats.planTriggers=stats.planTriggers+1
      elseif event.type=='outcome_latched' then stats.reason=p.reasonCode or 'unknown' end
    end
    state=resolution.afterState
    assert(stats.turns<=state.turnLimit)
  end
  stats.status=state.status; stats.stealth=state.player.stealth; stats.resistance=state.character.resistance
  stats.turnLimit=state.turnLimit
  return stats
end

function simulate(style,character,n,seed)
  local r={style=style,character=character,n=n,wins=0,turns=0,winTurns=0,stealth=0,
    lossResistance=0,tenPlus=0,chains=0,actions=0,plans=0,moodChanges=0,damage=0,healing=0,enemyHealing=0,
    planTriggers=0,moods={},cards={},enemyCards={},reasons={},trials={}}
  for i=1,n do
    -- Identical independent seed list for all matchups; does not inspect hidden RNG or intent IDs.
    local s=(seed+i*104729)%2147483646
    local b=oneBattle(style,character,s)
    if b.status=='victory' then r.wins=r.wins+1;r.winTurns=r.winTurns+b.turns
    else r.lossResistance=r.lossResistance+b.resistance end
    if b.turns>=10 then r.tenPlus=r.tenPlus+1 end
    for _,k in ipairs({'turns','stealth','chains','actions','plans','moodChanges','damage','healing','enemyHealing','planTriggers'}) do r[k]=r[k]+b[k] end
    for _,k in ipairs({'moods','cards','enemyCards'}) do for id,v in pairs(b[k]) do r[k][id]=(r[k][id] or 0)+v end end
    r.reasons[b.reason]=(r.reasons[b.reason] or 0)+1
    r.trials[#r.trials+1]={seed=s,status=b.status,turns=b.turns,stealth=b.stealth,
      resistance=b.resistance,reason=b.reason,damage=b.damage,healing=b.healing,enemyHealing=b.enemyHealing}
  end
  return r
end
