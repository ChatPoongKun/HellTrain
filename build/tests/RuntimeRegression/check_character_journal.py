"""Exercise the character journal with the existing real-runtime host harness."""
from pathlib import Path
from importlib import import_module
import re
import sys

LuaRuntime = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime
source = re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@", Path('build/tests/setup-to-battle-flow-check.ps1').read_text(encoding='utf-8-sig'), re.S)[1]
source = source[:source.index('print("DEBUG_SELECTED=')]
source += r'''
table.unpack=table.unpack or unpack
setmetatable(modules, {__index=function(t,n)
 local h=loadLore('System/'..n..'.lua');rawset(t,n,h);return h
end})
json=dofile('build/tests/fixtures/json.lua')
local function call(m,a,...) return assertOk(m..'.'..a,runScript('test',m,a,...)) end
local data=call('staticData','loadAll').data
local function journal(input) return call('runProgressionView','buildCharacterJournal',input,data).view end
local empty=journal({})
assert(empty.count==0)
local active=clone(states['battleRuntimeV1.authority'])
local id=active.character.characterId
local input={setupState=receipt,battleState=active,characterId=id}
local view=journal(input)
assert(view.count==1 and view.selected.encounters==1 and view.selected.active==1)
assert(view.selected.victories==0 and view.selected.defeats==0)
assert(view.selected.profile.name==data.characters[id].name)
assert(view.selected.profile.portraitImage==data.characters[id].portraitImage)
assert(view.selected.profile.appearanceSummary and #view.selected.profile.traits>0)
assert(not view.selected.profile.privateProfile and not view.selected.profile.deck)
local before=canonical(input)
assert(canonical(journal(input))==canonical(view) and canonical(input)==before)

-- Use the real surrender/settlement path to check duplicate battle IDs.
lorePaths['postBattle.html']='html/postBattle.html'
local chat={{role='char',data='Approach scene'}}
function getFullChat()return clone(chat)end
function addChat(_,role,text)chat[#chat+1]={role=role,data=text}end
function removeChat(_,index)table.remove(chat,index+1)end
call('battleController','surrender',call('turnDraft','inspect',active,data,states['battleRuntimeV1.draft']).interactionToken)
call('battleController','prepareGeneration')
call('battleController','injectRequest',{{role='user',content=chat[#chat].data}})
addChat('test','char','The battle is over.')
call('battleController','commitOutput')
local terminal=clone(states['battleRuntimeV1.authority'])
local summary=call('battleController','getTerminalSummary').summary
local run=call('runProgression','settle',nil,receipt,summary,data).state
local settled=journal({setupState=receipt,runState=run,battleState=terminal,characterId=id})
assert(settled.selected.encounters==1 and settled.selected.defeats==1 and settled.selected.active==0)
local wonSummary=clone(summary)
wonSummary.status='victory';wonSummary.reasonCode='turn_start_checkpoint'
wonSummary.finalResistance=0;wonSummary.finalStealth=1
local wonRun=call('runProgression','settle',nil,receipt,wonSummary,data).state
local resultView=call('runProgressionView','build',wonRun,receipt,data).view
assert(resultView.result.character.fallenImage==data.characters[id].fallenImage)
local catalog=call('staticData','loadCatalog').data
local partialResult=call('runProgressionView','build',wonRun,receipt,catalog).view
assert(partialResult.result.character.fallenImage==data.characters[id].fallenImage)
local won=journal({setupState=receipt,runState=wonRun,characterId=id})
assert(won.selected.encounters==1 and won.selected.victories==1 and won.selected.defeats==0)
-- A later battle against the same character adds a single active encounter.
local later=clone(active);later.battleId='journal-next-battle'
later.turnStartReceipt=nil
call('stateSchema','validateBattleState',later,data)
local repeatView=journal({setupState=receipt,runState=wonRun,battleState=later,characterId=id})
assert(repeatView.selected.encounters==2 and repeatView.selected.victories==1 and repeatView.selected.active==1)
assert(not runScript('test','runProgressionView','buildCharacterJournal',{characterId=id},data).ok)
local malformed=clone(wonRun);malformed.stats.victories=999
assert(not runScript('test','runProgressionView','buildCharacterJournal',{setupState=receipt,runState=malformed},data).ok)
local invalid=clone(won);invalid.selected.privateProfile={secret='hidden'}
assert(not runScript('test','dataBridge','encode','characterJournalView',invalid).ok)
local encoded=runScript('test','dataBridge','encode','characterJournalView',repeatView)
assert(encoded.ok and encoded.bytes>0)
-- All registered public profiles use the same presentation/validation path.
for characterId in pairs(data.characters) do
 local state=call('battleBootstrap','fromSetup',{battleId='journal-profile',seed=7,playerCardIds=receipt.selectedCardIds,characterId=characterId},data).state
 local profile=journal({battleState=state,characterId=characterId})
 assert(profile.count==1 and profile.selected.profile.characterId==characterId)
 assert(profile.selected.profile.portraitImage==data.characters[characterId].portraitImage)
end
-- Real popup root -> detail -> back -> close, without changing authority.
function debug(_,message) if message:find('조회 실패',1,true) then error(message) end end
lorePaths['캐릭터 리스트.html']='html/캐릭터 리스트.html'
lorePaths['캐릭터 프로필.html']='html/캐릭터 프로필.html'
local originalLoad=loadLores
function loadLores(triggerId,name)
 if name=='캐릭터 리스트.html' or name=='캐릭터 프로필.html' then
  assert(type(chatVars.characterJournalView)=='string','view must be published before CBS evaluation')
 end
 return originalLoad(triggerId,name)
end
states['runProgressionV1.authority']=run
local saved=canonical(states['runProgressionV1.authority'])
runScript('test','popupManage','root','캐릭터 프로필','list')
assert(states.popupState.current.args[1]=='list')
assert(chatVars.helltrainUiPopupV1:find('조우한 캐릭터',1,true))
runScript('test','popupManage','push','캐릭터 프로필',id)
assert(states.popupState.current.args[1]==id)
assert(chatVars.helltrainUiPopupV1:find('journal_person',1,true))
runScript('test','popupManage','back')
assert(states.popupState.current.args[1]=='list')
runScript('test','popupManage','close')
assert(not states.popupState.current)
assert(canonical(states['runProgressionV1.authority'])==saved)
print('PASS: character journal counts, profiles, validation and popup navigation')
'''
LuaRuntime().execute(source)

for filename in ('캐릭터 리스트.html', '캐릭터 프로필.html'):
    html = (Path('html') / filename).read_text(encoding='utf-8')
    assert all(not line[:1].isspace() for line in html.splitlines())
    assert html.count('{{') == html.count('}}')
    for directive in ('each', 'when'):
        assert html.count('{{#' + directive) == html.count('{{/' + directive + '}}')
