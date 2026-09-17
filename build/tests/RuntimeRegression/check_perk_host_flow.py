"""Exercise the actual init button routes and persistent next-battle handoff."""
from pathlib import Path
import re,sys
from lupa.lua54 import LuaRuntime
source=re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@",Path('build/tests/setup-to-battle-flow-check.ps1').read_text(encoding='utf-8-sig'),re.S)[1]
source=source[:source.index('print("DEBUG_SELECTED=')]
source+=r'''
setmetatable(modules,{__index=function(t,n)local h=loadLore('System/'..n..'.lua');rawset(t,n,h);return h end})
json=dofile('build/tests/fixtures/json.lua')
lorePaths['postBattle.html']='html/postBattle.html'
local function call(m,a,...) return assertOk(m..'.'..a,runScript('test',m,a,...)) end
local data=call('staticData','loadAll').data
local state=call('battleBootstrap','fromSetup',{battleId=receipt.battleSpec.battleId,seed=receipt.battleSpec.seed,playerCardIds=receipt.selectedCardIds,characterId=receipt.selectedCharacterId},data).state
state.player.stealth=1000;state.character.resistance=1
state.player.baseDrawCount,state.player.maxHandSize=10,10
local initial=call('turnInitializer','prepareTurn',state,data,{turnId=state.battleId..'-turn-001'})
local won,winningDraft
local token=call('turnDraft','inspect',initial.state,data,initial.draft).interactionToken
for _,instance in ipairs(initial.state.cardInstances) do
 if instance.owner=='player' and instance.zone=='hand' and not data.cards[instance.cardId].effectChoices then
  local selected=runScript('test','turnDraft','applyInteraction',initial.state,data,initial.draft,{action='register',instanceId=instance.instanceId,expectedInteractionToken=token})
  if selected.ok then
   local projection=call('turnDraft','project',initial.state,data,selected.draft).projection
   local pending=call('battleRuntime','preparePending',initial.state,data,projection).pendingTurn
   if pending.afterState.status=='victory' then
    won=call('battleRuntime','commitPending',initial.state,data,pending).state
    states['battleRuntimeV1.lastCommittedPending']=pending
    winningDraft=selected.draft
    break
   end
  end
 end
end
assert(won,'winning card fixture')
states['battleRuntimeV1.authority']=initial.state;states['battleRuntimeV1.draft']=winningDraft
states['battleRuntimeV1.pending']=nil
states['battleRuntimeV1.lastCommittedPending']=nil
local chat={{role='char',data='Approach'}}
function getFullChat()return clone(chat)end
function addChat(_,role,text)chat[#chat+1]={role=role,data=text}end
function removeChat(_,index)table.remove(chat,index+1)end
local token=call('turnDraft','inspect',initial.state,data,winningDraft).interactionToken
call('battleController','publishCurrentView')
call('battleController','armSubmission',token)
call('battleController','prepareGeneration')
call('battleController','injectRequest',{{role='user',content=chat[#chat].data}})
addChat('test','char','Victory.')
call('battleController','commitOutput')
local aftermath=states['battleRuntimeV1.aftermath']
call('battleController','skipAftermath',won.battleId,won.battleId..string.format('-aftermath-%03d',aftermath.completedTurnNumber))
local reward=call('init','start').view.rewardOffer
local id=reward.perks[1].perkId
local choice=call('init','choose',id,reward.interactionToken)
assert(choice.view.perkCount==1)
assert(states['runProgressionV1.authority'].perkIds[1]==id)
assert(call('init','choose',id,reward.interactionToken).stale)
local offer=choice.view.characterOffer
call('init','chooseCharacter',offer.characters[1].characterId,offer.interactionToken)
call('init','start')
local battle=states['battleRuntimeV1.authority']
assert(battle.player.perkIds[1]==id)
local before=canonical(battle)
call('init','start')
assert(canonical(states['battleRuntimeV1.authority'])==before,'resume reapplied initial perk')
-- Rebuild later reward states and test the same choose route's replacement payload.
local run=states['runProgressionV1.authority']
for round=1,3 do
 local spec=run.battleSpec
 local boot=call('battleBootstrap','fromSetup',{battleId=spec.battleId,seed=spec.seed,playerCardIds=spec.playerCardIds,characterId=spec.characterId,perkIds=spec.perkIds},data).state
 local summary={battleId=boot.battleId,turnId=boot.battleId..'-turn-001',characterId=boot.character.characterId,status='victory',reasonCode='card_checkpoint',turnNumber=1,turnLimit=boot.turnLimit,finalStealth=20,finalResistance=0,transit=boot.transit}
 run=call('runProgression','settle',run,receipt,summary,data).state
 if round<3 then
  run=call('runProgression','claimReward',run,receipt,{perkId=run.rewardOffer.perkIds[1],interactionToken=run.rewardOffer.interactionToken},data).state
  run=call('runProgression','chooseCharacter',run,receipt,{characterId=run.characterOffer.characterIds[1],interactionToken=run.characterOffer.interactionToken},data).state
 end
end
states['runProgressionV1.authority']=run
local removed,new=run.perkIds[1],run.rewardOffer.perkIds[1]
local result=call('init','choose',new..':'..removed,run.rewardOffer.interactionToken)
assert(result.view.perkCount==3)
local owned=states['runProgressionV1.authority'].perkIds
for _,perk in ipairs(owned) do assert(perk~=removed) end
assert(owned[3]==new)
print('perk host flow: actual victory, choose route, stale click, next-battle handoff/resume and replacement payload: OK')
'''
LuaRuntime().execute(source)
