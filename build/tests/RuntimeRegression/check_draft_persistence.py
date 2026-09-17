from pathlib import Path
import sys
sys.path.insert(0, str(Path('build/tests/BattleSimulation/StyleDecks').resolve()))
from simulate_balance import runtime
lua, _ = runtime(sys.argv[1] if len(sys.argv) > 1 else 'lua54')
lua.execute(r'''
function copy(v) if type(v) ~= 'table' then return v end local r={} for k,x in pairs(v) do r[k]=copy(x) end return r end
store, vars, chat = {}, {}, {{role='char',data='initial'}}
HostCompat = {
 readState=function(_,k) return copy(store[k]) end,
 writeState=function(_,k,v) if k ~= drop then store[k]=copy(v) end end,
 writeChatVar=function(_,k,v) vars[k]=v end,
}
getChatVar=function(_,k) return vars[k] end
getFullChat=function() return copy(chat) end
addChat=function(_,role,text) chat[#chat+1]={role=role,data=text} end
removeChat=function(_,index) table.remove(chat,index+1) end
loadLores=function() return '<!--HELLTRAIN_BATTLE_INTERACTION_V1-->' end
reloadDisplay=function() end
local original=runScript
runScript=function(t,m,a,...)
 if m=='dataBridge' then return {ok=true,schemaVersion=1,errors={},encoded='view'} end
 return original(t,m,a,...)
end
function ctrl(a,...) return checked('battleController',a,...) end
ctrl('startVerticalSlice','regression',12345)
local s=store['battleRuntimeV1.authority']
local d=store['battleRuntimeV1.draft']
local token=checked('turnDraft','inspect',s,data,d).interactionToken
ctrl('armSubmission',token)
ctrl('prepareGeneration')
ctrl('injectRequest',{{role='user',content='test'}})
chat[#chat+1]={role='char',data='output'}
ctrl('commitOutput')
assert(store['battleRuntimeV1.draft'])
print('normal turn OK')
''')
lua.execute(r'''
ctrl('startVerticalSlice','regression2',12345)
local s=store['battleRuntimeV1.authority']
local d=store['battleRuntimeV1.draft']
ctrl('armSubmission',checked('turnDraft','inspect',s,data,d).interactionToken)
drop='battleRuntimeV1.pending'
local r=runScript('test','battleController','prepareGeneration')
print('dropped pending:',r.ok,r.errors[1].code,r.errors[1].path)
assert(store['battleRuntimeV1.draft'], 'lost selected draft after pending write was dropped')
''')
lua.execute(r'''
assert(store['battleRuntimeV1.submission'])
drop=nil
assert(ctrl('prepareGeneration').generationReady)
ctrl('injectRequest',{{role='user',content='test'}})
chat[#chat+1]={role='char',data='output2'}
local before=copy(store)
function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
ctrl('commitOutput')
local expected=copy(store)
for _,key in ipairs({'lastCommittedPending','authority','draft','activeRequest','pending'}) do
 store=copy(before)
 drop='battleRuntimeV1.'..key
 local result=runScript('test','battleController','commitOutput')
 assert(not result.ok and result.errors[1].code=='state_write_not_persisted', key)
 drop=nil
 ctrl('commitOutput')
 assert(equal(store,expected),'commit retry diverged: '..key)
 ctrl('commitOutput')
 assert(equal(store,expected),'duplicate commit diverged: '..key)
 print('commit write failure and idempotent retry OK:',key)
end
''')
lua.execute(r'''
for _,key in ipairs({'pending','draft','activeRequest','submission'}) do
 ctrl('startVerticalSlice','prepare-'..key,12345)
 local s=store['battleRuntimeV1.authority']
 local d=store['battleRuntimeV1.draft']
 local selected=0
 for _,card in ipairs(s.cardInstances) do
  if card.owner=='player' and card.zone=='hand' and selected<2 then
   local token=checked('turnDraft','inspect',s,data,store['battleRuntimeV1.draft']).interactionToken
   local result=runScript('test','battleController','registerCard',card.instanceId,token)
   if result.ok and result.applied then selected=selected+1 end
  end
 end
 assert(selected==2,'expected two selected cards')
 d=copy(store['battleRuntimeV1.draft'])
 ctrl('armSubmission',checked('turnDraft','inspect',s,data,d).interactionToken)
 local projected=checked('turnDraft','project',s,data,d).projection
 local expected=checked('battleRuntime','preparePending',s,data,projected).pendingTurn
 drop='battleRuntimeV1.'..key
 local result=runScript('test','battleController','prepareGeneration')
 assert(not result.ok and result.errors[1].code=='state_write_not_persisted',key)
 drop=nil
 assert(ctrl('prepareGeneration').generationReady)
 local pending=store['battleRuntimeV1.pending']
 assert(equal(pending,expected),'pending changed during retry: '..key)
 print('two-card prepare retry OK:',key)
end
''')


