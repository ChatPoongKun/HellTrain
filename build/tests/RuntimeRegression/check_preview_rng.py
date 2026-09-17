from pathlib import Path
import sys
sys.path.insert(0,str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime
lua,_=runtime(sys.argv[1] if len(sys.argv)>1 else 'lua54')
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
for _,id in ipairs({'pc_glutton_011','pc_predator_010'}) do
 local deck={id,'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004','pc_predator_005','pc_deceiver_003','pc_harmonizer_001','pc_glutton_002','pc_glutton_003'}
 local state=checked('battleBootstrap','fromSetup',{battleId='preview-rng',seed=12345,playerCardIds=deck,characterId='yoo_jiyoung'},data).state
 -- One preview card in the draw pile; the other cards await a reshuffle.
 local instanceId,n=nil,0
 for _,v in ipairs(state.cardInstances) do
  if v.owner=='player' then
   if v.cardId==id then v.zone='deck';v.position=1;instanceId=v.instanceId
   else n=n+1;v.zone='discard';v.position=n end
  end
 end
 state.player.baseDrawCount=1
 local initialized=checked('turnInitializer','prepareTurn',state,data,{turnId='preview-rng-turn-001'})
 local draft=checked('turnDraft','registerCard',initialized.state,data,initialized.draft,instanceId).draft
 local projection=checked('turnDraft','project',initialized.state,data,draft).projection
 assert(projection.projectedRng.cursor>initialized.state.rng.cursor,'fixture did not shuffle')
 local cancelled=checked('turnDraft','cancelCard',initialized.state,data,draft,instanceId).draft
 local reset=checked('turnDraft','project',initialized.state,data,cancelled).projection
 assert(reset.projectedRng.cursor==initialized.state.rng.cursor,'cancel consumed RNG')
 checked('battleRuntime','preparePending',initialized.state,data,reset)
 local resolution=checked('turnResolver','resolveTurn',initialized.state,data,projection,{turnId='preview-rng-turn-001'}).resolution
 local cursor=resolution.source.projectedRng.cursor
 resolution.source.projectedRng.cursor=cursor+1
 local invalid=runScript('test','turnEventProjector','projectTurn',initialized.state,data,resolution)
 assert(not invalid.ok and invalid.errors[1].code=='projection_receipt_mismatch','tampered preview RNG not rejected by replay')
 resolution.source.projectedRng.cursor=cursor
 resolution.afterState.rng.cursor=resolution.afterState.rng.cursor+1
 invalid=runScript('test','turnEventProjector','projectTurn',initialized.state,data,resolution)
 assert(not invalid.ok and invalid.errors[1].code=='rng_result_mismatch','final RNG verification lost')
 local pending=checked('battleRuntime','preparePending',initialized.state,data,projection).pendingTurn
 checked('turnPresentation','build',pending,data)
 checked('turnPromptFormatter','formatPending',pending,data)
 checked('battleRuntime','reusePending',initialized.state,data,pending)
 local committed=checked('battleRuntime','commitPending',initialized.state,data,pending)
 assert(not checked('battleRuntime','commitPending',committed.state,data,pending).applied)
 checked('battleRuntime','preparePending',initialized.state,data,projection,true)
 print('PASS: preview reshuffle',id)
end
''')

