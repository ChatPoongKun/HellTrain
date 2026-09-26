"""Exercise the active-character local lorebook projection."""
from importlib import import_module
import sys

lua = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime()
lua.execute(r'''
json=dofile('build/tests/fixtures/json.lua')
local states={
 ['gameSetupV1.authority']={setupId='setup-1'},
 ['runProgressionV1.authority']={setupId='setup-1',sessions={
  {characterId='a',status='victory',reasonCode='resistance_depleted',turnNumber=5,turnLimit=8,finalStealth=17,finalResistance=0,transit={lineName='A'}},
  {characterId='b',status='defeat',reasonCode='turn_limit',turnNumber=7,turnLimit=7,finalStealth=9,finalResistance=4,transit={lineName='B'}},
  {characterId='a',status='defeat',reasonCode='stealth_depleted',turnNumber=6,turnLimit=8,finalStealth=0,finalResistance=3,transit={lineName='C'}},
 }},
 ['freeTrainingV1.authority']={kind='freeTrainingV1',schemaVersion=1,setupId='setup-1',nextSessionNumber=6,records={
  {sessionId='f1',characterId='a',number=1,summary='첫 기록',summaryStatus='complete',truncated=false},
  {sessionId='f2',characterId='a',number=2,summary='둘째 기록',summaryStatus='complete',truncated=false},
  {sessionId='f3',characterId='b',number=3,summary='다른 캐릭터',summaryStatus='complete',truncated=false},
  {sessionId='f4',characterId='a',number=4,summary='{{user}} 셋째 기록',summaryStatus='complete',truncated=false},
  {sessionId='f5',characterId='a',number=5,summary='넷째 기록',summaryStatus='complete',truncated=true},
 }},
}
HostCompat={readState=function(_,key)return states[key]end}
local characters={
 a={id='a',name='A',portraitImage='a.png',fallenImage='af.png',publicProfile={age=24,occupation='A job'},sexualPreference='A preference',backgroundNarrative='A background',battle={startingResistance=30,deck={'secret_card'}}},
 b={id='b',name='B',portraitImage='b.png',fallenImage='bf.png',publicProfile={age=25,occupation='B job'},sexualPreference='B preference',backgroundNarrative='B background',battle={startingResistance=20,deck={'other_card'}}},
}
function runScript(_,module,action,arg)
 if module=='staticData' and action=='loadCharacters' then
  local selected={};for _,id in ipairs(arg)do selected[id]=characters[id]end
  return {ok=true,data={characters=selected}}
 end
 if module=='freeTraining' and action=='validate' then return {ok=true,state=arg} end
 error('unexpected module call: '..tostring(module)..'.'..tostring(action))
end
local lores={}
local writeOptions
function upsertLocalLoreBook(_,name,content,options)
 lores[name]={comment=name,content=content,alwaysActive=options.alwaysActive,insertorder=options.insertOrder}
 writeOptions=options
end
function getLoreBooks(_,name)
 return lores[name] and {lores[name]} or {}
end
local file=assert(io.open('System/characterContextLore.lua','r'))
local source=file:read('*a');file:close()
local lore=assert((loadstring or load)('return '..source))()
local first=lore('test','sync','a')
assert(first.ok and first.synced and first.loreName=='helltrain.activeCharacter.v1')
assert(first.document.name=='A' and first.document.publicProfile.age==24)
assert(first.document.sexualPreference=='A preference')
assert(first.document.backgroundNarrative=='A background')
assert(first.document.privateProfile==nil)
assert(#first.document.pastBattleResults==2)
assert(#first.document.recentFreeTrainingSummaries==3)
assert(first.document.recentFreeTrainingSummaries[1].number==5)
assert(first.document.recentFreeTrainingSummaries[2].number==4)
assert(first.document.recentFreeTrainingSummaries[3].number==2)
assert(not first.content:find('{{',1,true),'CBS directive leaked into lore content')
assert(not first.content:find('startingResistance',1,true),'battle definition leaked into relationship lore')
assert(not first.content:find('secret_card',1,true),'card ids leaked into relationship lore')
assert(writeOptions.alwaysActive==true and writeOptions.key=='')
local second=lore('test','sync','b')
assert(second.ok and second.document.name=='B')
local count=0;for _ in pairs(lores)do count=count+1 end
assert(count==1,'active character lore was not replaced')
states['freeTrainingV1.authority'].setupId='old-setup'
local stale=lore('test','build','a')
assert(stale.ok and #stale.document.recentFreeTrainingSummaries==0)
print('PASS: active character local lorebook projection')
''')
