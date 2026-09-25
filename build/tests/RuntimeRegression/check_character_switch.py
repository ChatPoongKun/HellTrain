"""Real surrender -> next encounter, with Risu's time=0 chat serialization."""
from pathlib import Path
from importlib import import_module
import re
import sys

LuaRuntime = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime
source = re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@", Path('build/tests/setup-to-battle-flow-check.ps1').read_text(encoding='utf-8-sig'), re.S)[1]
source = source[:source.index('print("DEBUG_SELECTED=')]
source += r'''
table.unpack=table.unpack or unpack
setmetatable(modules,{__index=function(t,n)
 local h=loadLore('System/'..n..'.lua');rawset(t,n,h);return h
end})
json=dofile('build/tests/fixtures/json.lua')
local fixtureGetLoreBooks=getLoreBooks
local localLorebooks={}
function upsertLocalLoreBook(_,name,content,options)
 localLorebooks[name]={comment=name,content=content,alwaysActive=options.alwaysActive,insertorder=options.insertOrder}
end
function getLoreBooks(id,name)
 if localLorebooks[name] then return {localLorebooks[name]} end
 return fixtureGetLoreBooks(id,name)
end
lorePaths['postBattle.html']='html/postBattle.html'
local function call(m,a,...) return assertOk(m..'.'..a,runScript('test',m,a,...)) end
local data=call('staticData','loadAll').data
local chat={{role='char',data='First encounter',time=0}}
function getFullChat()return clone(chat)end
function addChat(_,role,text)chat[#chat+1]={role=role,data=text,time=0}end
function removeChat(_,index)table.remove(chat,index+1)end
function reloadChat()end
function debug()end
local failures={}
function alertError(_,text)failures[#failures+1]=text end
function splitByDelimiter(text,delimiter)
 local parts={};for part in text:gmatch('[^'..delimiter..']+')do parts[#parts+1]=part end;return parts
end
local oldId=states['battleRuntimeV1.authority'].character.characterId
local requests=0
function LLM(_,prompt)
 requests=requests+1
 return {success=true,result='Departure of '..oldId}
end
runScript('test','hostFlow','buttonClick','battleController|surrender|'..selected.battleView.interactionToken)
assert(requests==1 and #failures==0)
assert(states['battleRuntimeV1.authority'].surrendered)
local nextView=call('init','start').view
local offer=assert(nextView.characterOffer)
local nextId
for _,character in ipairs(offer.characters)do
 if character.characterId~=oldId then nextId=character.characterId;break end
end
assert(nextId,'fixture needs a different character')
local failGeneration=true
local probing=false
function LLM(_,prompt)
 requests=requests+1
 assert(not probing,'concurrent approach generated a second request')
 probing=true
 local count,chatCount=requests,#chat
 addChat('test','user','*says nothing*')
 assert(runScript('second-event','hostFlow','start')==false)
 assert(requests==count and #chat==chatCount,'concurrent approach was not blocked cleanly')
 runScript('third-event','hostFlow','buttonClick','hostFlow|retryApproach')
 assert(requests==count,'retry button generated a concurrent approach')
 probing=false
 assert(prompt[1].content:find('대상 캐릭터: '..data.characters[nextId].name,1,true))
 assert(not prompt[1].content:find('대상 캐릭터: '..data.characters[oldId].name,1,true))
 assert(prompt[1].content:find('"privateProfile"',1,true),'private profile missing from compact relationship context')
 assert(prompt[1].content:find('recentFreeTrainingSummaries',1,true),'free-training summaries field missing from approach context')
 assert(not prompt[1].content:find('startingResistance',1,true),'battle definition leaked into approach context')
 local activeLore=assert(localLorebooks['helltrain.activeCharacter.v1'])
 assert(activeLore.alwaysActive==true and activeLore.content:find(data.characters[nextId].name,1,true))
 if failGeneration then return {success=false,result='temporary failure'} end
 return {success=true,result='Approach of '..nextId}
end
local route='init|chooseCharacter|'..nextId..'|'..offer.interactionToken
runScript('test','hostFlow','buttonClick',route)
assert(requests>1,'BUG: previous time=0 departure skipped the new approach request')
assert(chatVars.helltrainApproachRetryV1=='pending|'..nextId)
assert(chatVars.helltrainSceneRequestV1=='','failed approach retained lock')
assert(chat[#chat].data=='Departure of '..oldId)
local originalWrite=HostCompat.writeChatVar
HostCompat.writeChatVar=function(id,key,value)
 if key=='helltrainSceneRequestV1' and value~='' then return end
 return originalWrite(id,key,value)
end
local previousRequests=requests
assert(not pcall(runScript,'test','hostFlow','buttonClick','hostFlow|retryApproach'))
assert(requests==previousRequests,'unpersisted marker allowed a request')
HostCompat.writeChatVar=originalWrite
-- A persisted marker without a live owner (e.g. reload) must never lock retries.
chatVars.helltrainSceneRequestV1='abandoned-request'
failGeneration=false
local originalRun=runScript
local failTransition=true
function runScript(id,module,action,...)
 if failTransition and module=='init' and action=='start' then return {ok=false} end
 return originalRun(id,module,action,...)
end
runScript('test','hostFlow','buttonClick','hostFlow|retryApproach')
assert(chatVars.helltrainApproachRetryV1=='generated|'..nextId)
assert(chat[#chat].data=='Approach of '..nextId)
local count,chatCount=requests,#chat
failTransition=false
runScript('test','hostFlow','buttonClick','hostFlow|retryApproach')
assert(requests==count and #chat==chatCount,'transition retry duplicated scene')
assert(chatVars.helltrainApproachRetryV1=='')
assert(chatVars.helltrainSceneRequestV1=='','successful approach retained lock')
local current=states['battleRuntimeV1.authority']
assert(current.character.characterId==nextId)
runScript('test','hostFlow','buttonClick',route)
assert(requests==count and #chat==chatCount,'stale selection regenerated approach')
-- The subsequent ordinary turn also names the authoritative current opponent.
local draft=states['battleRuntimeV1.draft']
local projection=call('turnDraft','project',current,data,draft).projection
local pending=call('battleRuntime','preparePending',current,data,projection).pendingTurn
local formatted=call('turnPromptFormatter','formatPending',pending,data).message.content
assert(formatted:find('현재 전투 상대: '..data.characters[nextId].name,1,true))
assert(not formatted:find('현재 전투 상대: '..data.characters[oldId].name,1,true))
print('PASS: first-turn surrender, different character, generation/transition retries, stale click and next-turn identity')
'''
LuaRuntime().execute(source)
