"""Victory reward-kind draw, card acquisition/removal and replay regression."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime

lua, _ = runtime('lua54')
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local setup=checked('gameSetup','start',{setupId='reward-kinds',seed=912},data).state
while setup.phase=='deckDraft' do
 setup=checked('gameSetup','choose',setup,{cardId=setup.offer.cardIds[1],interactionToken=setup.offer.interactionToken},data).state
end
setup=checked('gameSetup','beginCharacterSelect',setup,data).state
setup=checked('gameSetup','chooseCharacter',setup,{characterId=setup.characterOffer.characterIds[1],interactionToken=setup.characterOffer.interactionToken},data).state

local function win(spec)
 local boot=checked('battleBootstrap','fromSetup',{battleId=spec.battleId,seed=spec.seed,
  playerCardIds=spec.playerCardIds,characterId=spec.characterId,perkIds=spec.perkIds or {}},data).state
 return {battleId=boot.battleId,turnId=boot.battleId..'-turn-001',characterId=boot.character.characterId,
  status='victory',reasonCode='card_checkpoint',turnNumber=1,turnLimit=boot.turnLimit,
  finalStealth=20,finalResistance=0,transit=boot.transit}
end
local function has(items,value) for _,item in ipairs(items) do if item==value then return true end end end
local function count(items,value) local n=0 for _,item in ipairs(items) do if item==value then n=n+1 end end return n end

local spec={battleId=setup.battleSpec.battleId,seed=setup.battleSpec.seed,playerCardIds=setup.selectedCardIds,
 characterId=setup.selectedCharacterId,perkIds={}}
local run=checked('runProgression','settle',nil,setup,win(spec),data).state
assert(#run.rewardOffer.rewardKinds==3)
assert(has(run.rewardOffer.rewardKinds,'card') and has(run.rewardOffer.rewardKinds,'remove_card') and has(run.rewardOffer.rewardKinds,'perk'))
assert(json.encode(checked('runProgression','validate',run,setup,data).state.rewardOffer)==json.encode(run.rewardOffer))
local view=checked('runProgressionView','build',run,setup,data).view
assert(#view.rewardOffer.kinds==3 and not view.rewardOffer.canRemove)
assert(view.rewardOffer.cardDraftNumber==1 and view.rewardOffer.cardDraftTotal==2)
assert(not runScript('test','runProgression','claimReward',run,setup,
 {removeCardId=run.rewardOffer.removableCardIds[1],interactionToken=run.rewardOffer.interactionToken},data).ok)

local firstToken=run.rewardOffer.interactionToken
run=checked('runProgression','claimReward',run,setup,
 {cardId=run.rewardOffer.cardIds[1],interactionToken=run.rewardOffer.interactionToken},data).state
assert(#run.playerCardIds==11)
assert(run.phase=='reward' and #run.sessions[#run.sessions].rewardChoices==1)
assert(run.rewardOffer.cardDraftNumber==2 and run.rewardOffer.cardDraftTotal==2)
assert(#run.rewardOffer.rewardKinds==1 and run.rewardOffer.rewardKinds[1]=='card')
assert(run.rewardOffer.interactionToken~=firstToken)
assert(checked('runProgression','claimReward',run,setup,
 {cardId=run.rewardOffer.cardIds[1],interactionToken=firstToken},data).stale)
view=checked('runProgressionView','build',run,setup,data).view
assert(#view.rewardOffer.kinds==1 and view.rewardOffer.kinds[1].kind=='card')
assert(view.rewardOffer.cardDraftNumber==2 and view.deck.count==11)
run=checked('runProgression','claimReward',run,setup,
 {cardId=run.rewardOffer.cardIds[1],interactionToken=run.rewardOffer.interactionToken},data).state
assert(#run.playerCardIds==12 and run.phase=='characterSelect')
assert(#run.sessions[#run.sessions].rewardChoices==2)
run=checked('runProgression','chooseCharacter',run,setup,
 {characterId=run.characterOffer.characterIds[1],interactionToken=run.characterOffer.interactionToken},data).state
spec=run.battleSpec
run=checked('runProgression','settle',run,setup,win(spec),data).state
view=checked('runProgressionView','build',run,setup,data).view
assert(view.rewardOffer.canRemove)
local removed=run.rewardOffer.removableCardIds[1]
local before=count(run.playerCardIds,removed)
local stale={removeCardId=removed,interactionToken='run-progression-reward-v1:0:0:0'}
assert(checked('runProgression','claimReward',run,setup,stale,data).stale)
run=checked('runProgression','claimReward',run,setup,
 {removeCardId=removed,interactionToken=run.rewardOffer.interactionToken},data).state
assert(#run.playerCardIds==11 and count(run.playerCardIds,removed)==before-1)
checked('runProgression','validate',run,setup,data)
checked('runProgressionView','build',run,setup,data)
local file=assert(io.open('System/gameSetupController.lua','rb'))
local source=file:read('*a');file:close()
source=source:gsub('    local callOk, result = pcall%(execute%).*','    return validateInvocation()\nend)')
local command,errors=assert(load('return '..source))()('test','choose','remove:pc_test','token')
assert(not errors and command.removeCardId=='pc_test' and command.interactionToken=='token')
print('victory rewards: 3 kinds, two card drafts, deterministic replay, add/remove/minimum/stale: OK')
''')

template = Path('html/postBattle.html').read_text(encoding='utf-8-sig')
for contract in ('::kinds}} as reward_kind', '::removableCards}} as removable_card',
                 'init|choose|remove:', '::canRemove}}::is::true', '카드 드래프트 · 2 / 2'):
    assert contract in template, f'missing reward UI contract: {contract}'
