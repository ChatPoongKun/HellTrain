"""Fault every write position, including later writes to the same key."""
import check_draft_persistence as base
base.lua.execute(r'''
local writer=HostCompat.writeState
local writes,nth,position={},nil,0
HostCompat.writeState=function(t,k,v)
 position=position+1;writes[#writes+1]=k
 if position~=nth then writer(t,k,v) end
end
ctrl('startVerticalSlice','fault-positions',12345)
local s=store['battleRuntimeV1.authority']
ctrl('armSubmission',checked('turnDraft','inspect',s,data,store['battleRuntimeV1.draft']).interactionToken)
local initialStore,initialVars,initialChat=copy(store),copy(vars),copy(chat)
writes={};position=0
ctrl('prepareGeneration')
local expected,prepareWrites=copy(store),copy(writes)
for i,k in ipairs(prepareWrites) do
 store,vars,chat=copy(initialStore),copy(initialVars),copy(initialChat)
 nth=i;position=0;writes={}
 local r=runScript('test','battleController','prepareGeneration')
 nth=nil
 if not r.ok then ctrl('prepareGeneration') end
 assert(equal(store,expected),'prepare recovery mismatch '..i..' '..k)
end
store=copy(expected)
ctrl('injectRequest',{{role='user',content='test'}})
chat[#chat+1]={role='char',data='output'}
initialStore,initialVars,initialChat=copy(store),copy(vars),copy(chat)
writes={};position=0
ctrl('commitOutput')
expected=copy(store)
local commitWrites=copy(writes)
for i,k in ipairs(commitWrites) do
 store,vars,chat=copy(initialStore),copy(initialVars),copy(initialChat)
 nth=i;position=0;writes={}
 local r=runScript('test','battleController','commitOutput')
 nth=nil
 if not r.ok then
  if store['battleRuntimeV1.activeRequest'].outputObserved then
   local recovery=ctrl('prepareGeneration')
   assert(recovery.generationReady==false,'unexpected duplicate generation')
  else ctrl('commitOutput') end
 end
 assert(equal(store,expected),'commit recovery mismatch '..i..' '..k)
end
print('all write positions:',#prepareWrites,'prepare,',#commitWrites,'commit: OK')
''')
