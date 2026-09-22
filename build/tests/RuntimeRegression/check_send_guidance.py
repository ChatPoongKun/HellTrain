"""Blocked sends explain the next game action without entering battle resolution."""
from importlib import import_module
import sys

lua = import_module('lupa.' + ('luajit21' if 'jit' in sys.argv else 'lua54')).LuaRuntime()
lua.execute(r'''
local states, vars, alerts = {}, {}, {}
HostCompat = {readState=function(_, key) return states[key] end}
function getChatVar(_, key) return vars[key] end
function alertError(_, text) alerts[#alerts+1]=text end
function debug() end
local preparations=0
local report={ok=true,generationReady=true}
function runScript(_, module, action)
 assert(module=='battleController' and action=='prepareGeneration')
 preparations=preparations+1
 return report
end
local file=assert(io.open('System/hostFlow.lua','r'))
local source=file:read('*a');file:close()
local host=assert((loadstring or load)('return '..source))()
local function blocked(code, guide)
 local count=preparations
 assert(host('test','start')==false)
 local notice=assert(alerts[#alerts])
 assert(notice:find('['..code..']',1,true),notice)
 assert(notice:find(guide,1,true),notice)
 assert(preparations==count,'blocked send entered battle resolution')
end
blocked('game_not_started','게임 시작')
states['gameSetupV1.authority']={phase='deckDraft'}
blocked('draft_selection_required','카드')
states['gameSetupV1.authority']={phase='deckComplete'}
blocked('setup_transition_pending','게임 시작')
states['gameSetupV1.authority']={phase='characterSelect'}
blocked('character_selection_required','확정')
states['gameSetupV1.authority']={phase='battleReady'}
states['battleRuntimeV1.authority']={status='victory'}
states['runProgressionV1.authority']={phase='reward'}
blocked('reward_selection_required','선택하지 않기')
states['runProgressionV1.authority']={phase='characterSelect'}
blocked('character_selection_required','확정')
states['runProgressionV1.authority']={phase='battleReady'}
assert(host('test','start')==true,'valid turn or aftermath send was blocked')
report={ok=true,generationReady=false,idle=true}
assert(host('test','start')==false)
assert(alerts[#alerts]:find('[turn_not_prepared]',1,true))
report={ok=true,generationReady=false,aftermathComplete=false}
assert(host('test','start')==false)
assert(alerts[#alerts]:find('[aftermath_input_required]',1,true))
report={ok=true,generationReady=false,aftermathComplete=true}
assert(host('test','start')==false)
assert(alerts[#alerts]:find('[aftermath_complete]',1,true))
for _,code in ipairs({'missing_aftermath_input','aftermath_automatic_continue_rejected','recovery_filler_missing'}) do
 report={ok=false,errors={{code=code,message='detail',path='$.chat'}}}
 assert(host('test','start')==false)
 assert(alerts[#alerts]:find('['..code..']',1,true))
 assert(alerts[#alerts]:find('전송',1,true))
 assert(not alerts[#alerts]:find('치명적인',1,true))
end
report={ok=false,errors={{code='original_error',message='detail',path='$.test'}}}
assert(host('test','start')==false)
assert(alerts[#alerts]:find('[original_error]',1,true),'original error code was lost')
HostCompat.readState=function() error('read failure') end
blocked('send_phase_read_failed','진행 상태')
print('PASS: blocked-send phase guidance and valid generation routing')
''')
