"""Deterministic rewards, replacement, replay, views and discovery regression."""
from pathlib import Path
import sys
sys.path.insert(0,str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime
lua,_=runtime('lua54')
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local function copy(v) if type(v)~='table' then return v end local t={} for k,x in pairs(v) do t[k]=copy(x) end return t end
local setup=checked('gameSetup','start',{setupId='perk-run',seed=321},data).state
while setup.phase=='deckDraft' do
 setup=checked('gameSetup','choose',setup,{cardId=setup.offer.cardIds[1],interactionToken=setup.offer.interactionToken},data).state
end
setup=checked('gameSetup','beginCharacterSelect',setup,data).state
setup=checked('gameSetup','chooseCharacter',setup,{characterId=setup.characterOffer.characterIds[1],interactionToken=setup.characterOffer.interactionToken},data).state
local spec={battleId=setup.battleSpec.battleId,seed=setup.battleSpec.seed,playerCardIds=setup.selectedCardIds,characterId=setup.selectedCharacterId}
local run
local saved={}
HostCompat={readState=function(_,k)return saved[k]end,writeState=function(_,k,v)saved[k]=copy(v)end}
local allSeen={}
for round=1,6 do
 local boot=checked('battleBootstrap','fromSetup',spec,data).state
 assert(#boot.player.perkIds==math.min(round-1,3))
 local won={battleId=boot.battleId,turnId=boot.battleId..'-turn-001',characterId=boot.character.characterId,status='victory',reasonCode='card_checkpoint',turnNumber=1,turnLimit=boot.turnLimit,finalStealth=20,finalResistance=0,transit=boot.transit}
 local result=checked('runProgression','settle',run,setup,won,data)
 run=result.state
 assert(not checked('runProgression','settle',run,setup,won,data).applied)
 local validated=checked('runProgression','validate',run,setup,data).state
 assert(json.encode(validated.rewardOffer)==json.encode(run.rewardOffer))
 local view=checked('runProgressionView','build',run,setup,data).view
 checked('runProgressionView','validate',view)
 checked('cardCodex','record',view,data)
 local offered={}
 for _,id in ipairs(run.rewardOffer.perkIds) do
  assert(not offered[id]);offered[id]=true;allSeen[id]=true
  for _,owned in ipairs(run.perkIds) do assert(id~=owned) end
 end
 assert(#run.rewardOffer.perkIds==3)
 local token=run.rewardOffer.interactionToken
 local cmd={perkId=run.rewardOffer.perkIds[1],interactionToken=token}
 assert(not runScript('test','runProgression','claimReward',run,setup,{perkId='perk_missing',interactionToken=token},data).ok)
 if #run.perkIds==3 then
  assert(not runScript('test','runProgression','claimReward',run,setup,cmd,data).ok)
  cmd.replacedPerkId='perk_missing'
  assert(not runScript('test','runProgression','claimReward',run,setup,cmd,data).ok)
  cmd.replacedPerkId=run.perkIds[1]
 end
 local stale=copy(cmd);stale.interactionToken='run-progression-reward-v1:0:0:0'
 assert(checked('runProgression','claimReward',run,setup,stale,data).stale)
 local deckCount=#run.playerCardIds
 run=checked('runProgression','claimReward',run,setup,cmd,data).state
 assert(#run.playerCardIds==deckCount and #run.perkIds==math.min(round,3))
 assert(checked('runProgression','claimReward',run,setup,cmd,data).stale)
 for _,id in ipairs(run.perkIds) do assert(id~=cmd.replacedPerkId) end
 checked('runProgressionView','build',run,setup,data)
 run=checked('runProgression','chooseCharacter',run,setup,{characterId=run.characterOffer.characterIds[1],interactionToken=run.characterOffer.interactionToken},data).state
 checked('runProgression','validate',run,setup,data)
 checked('runProgressionView','build',run,setup,data)
 assert(json.encode(run.perkIds)==json.encode(run.battleSpec.perkIds))
 spec={battleId=run.battleSpec.battleId,seed=run.battleSpec.seed,playerCardIds=run.battleSpec.playerCardIds,perkIds=run.battleSpec.perkIds,characterId=run.battleSpec.characterId}
end
local recorded={} for _,id in ipairs(saved.cardCodexV1.perkIds) do recorded[id]=true end
for id in pairs(allSeen) do assert(recorded[id],'offered perk missing in codex') end
print('perk rewards: 6 victories, 3 acquisitions, 3 replacements, replay/stale/codex/views: OK')
''')
