"""Exercise free-training transcript boundaries and summary behavior."""
from importlib import import_module
import sys

LuaRuntime = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime
lua = LuaRuntime()
lua.execute(r'''
local calls=0
local tokenCalls=0
function getTokens(_,value)
 tokenCalls=tokenCalls+1
 return {await=function() return math.ceil(#value/3) end}
end
function LLM(_,prompt)
 calls=calls+1
 assert(prompt[2].content:find('<session>',1,true))
 return {success=true,result=' 실제로 있었던 일을 두 문장으로 요약했습니다. '}
end
local file=assert(io.open('System/freeTrainingSummary.lua','r'))
local source=file:read('*a');file:close()
local summary=assert((loadstring or load)('return '..source))()
local active={startChatIndex=1,boundary={role='char',data='boundary'}}
local chat={{role='char',data='old battle'},{role='char',data='boundary'},{role='user',data='hello'},{role='char',data='reply'}}
local extracted=summary('test','extract',chat,active)
assert(extracted.ok and #extracted.messages==2 and extracted.messages[1].content=='hello')
local generated=summary('test','generate','Character',extracted.messages)
assert(generated.ok and generated.status=='complete' and generated.text:find('요약했습니다',1,true))
assert(calls==1)
local empty=summary('test','generate','Character',{})
assert(empty.ok and empty.status=='empty' and calls==1)
chat[2].data='deleted boundary'
local missing=summary('test','extract',chat,active)
assert(not missing.ok and missing.errors[1].code=='session_boundary_missing')
function LLM() return {success=false,result='model failure'} end
local failed=summary('test','generate','Character',{{role='user',content='hello'}})
assert(failed.ok and failed.status=='failed')
function LLM() return {success=true,result=string.rep('가',900)} end
local limited=summary('test','generate','Character',{{role='user',content='hello'}})
local _,characters=limited.text:gsub('[^\128-\193]','')
assert(limited.ok and characters==800)
function LLM(_,prompt)
 assert(#prompt[2].content<#string.rep('가',15000))
 return {success=true,result='긴 대화를 발췌해 요약했습니다.'}
end
local long=summary('test','generate','Character',{{role='user',content=string.rep('가',15000)}})
assert(long.ok and long.truncated and tokenCalls>1)
print('PASS: free training summary boundaries and failures')
''')
