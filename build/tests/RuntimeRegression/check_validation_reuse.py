"""Exercise the production dispatcher, including event-local validation reuse.

Optional --baseline PATH measures an older runtime without the reuse assertions.
Timings are diagnostics, not machine-dependent pass/fail thresholds.
"""
from importlib import import_module
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
engine = 'luajit21' if 'jit' in sys.argv else 'lua54'
baseline = '--baseline' in sys.argv
runtime_path = Path(sys.argv[sys.argv.index('--baseline') + 1]) if baseline else ROOT / 'System/runtime.lua'
lua = import_module('lupa.' + engine).LuaRuntime(unpack_returned_tuples=True)
lua.globals().runtime_source = runtime_path.read_text(encoding='utf-8-sig')
lua.globals().check_reuse = not baseline
fixture = (ROOT / 'build/tests/turn-phase-draw-replay-check.ps1').read_text(encoding='utf-8-sig')
harness = re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@", fixture, re.S)[1]
harness = harness[:harness.index('local function runPass')]
lua.execute(harness + r'''
table.unpack = table.unpack or unpack
table.pack = table.pack or function(...) return {n=select('#',...),...} end
json = dofile('build/tests/fixtures/json.lua')
local store, vars, chat = {}, {}, {}
local stateReads, htmlReads, moduleCalls = 0, 0, {}
function getState(_, k) stateReads=stateReads+1;return clone(store[k]) end
function setState(_, k, v) store[k] = clone(v) end
function getChatVar(_, k) return vars[k] end
function setChatVar(_, k, v) vars[k] = v end
function getFullChat() return clone(chat) end
function addChat(_, r, t) chat[#chat+1] = {role=r,data=t} end
function removeChat(_, i) table.remove(chat,i+1) end
function refreshGameUi() end
function reloadChat() end
function getLoreBooks(_, name)
    if name:match('%.html$') then htmlReads=htmlReads+1 end
    local path = lorePaths[name]
        or (name:match('%.lua$') and ('System/'..name))
        or (name:match('%.html$') and ('html/'..name))
    return path and {{content=readFile(path)}} or {}
end
assert(load('return '..runtime_source))()
DEBUG = 0
assert(runScript('test','hostCompat','install'))
local dispatch = runScript
function runScript(t,m,a,...)
    local key=m..'.'..tostring(a);moduleCalls[key]=(moduleCalls[key] or 0)+1
    return dispatch(t,m,a,...)
end
local function call(m,a,...) return assertOk(m..'.'..a,runScript('test',m,a,...)) end
beginRunScriptEvent('test','buttonClick')
local data = call('staticData','loadAll').data
local init = call('turnInitializer','prepareTurn',newState(data,'perf',{turnNumber=1}),data,{turnId='perf-turn-001'})

if check_reuse then
    beginRunScriptEvent('test','buttonClick')
    local first = call('turnDraft','inspect',init.state,data,init.draft)
    local hits = getRunScriptCacheDiagnostics().validationHits or 0
    local second = call('turnDraft','inspect',clone(init.state),data,clone(init.draft))
    assert(getRunScriptCacheDiagnostics().validationHits == hits+1, 'equal inputs were replayed')
    second.draft.source.turnNumber = -99
    assert(call('turnDraft','inspect',init.state,data,init.draft).draft.source.turnNumber == first.draft.source.turnNumber,
        'caller mutated the cached result')
    local invalid = clone(init.draft)
    invalid.preview.rng.cursor = invalid.preview.rng.cursor + 1
    assert(not runScript('test','turnDraft','inspect',init.state,data,invalid).ok,'changed draft reused')
    local changed = clone(init.state)
    changed.player.stealth = changed.player.stealth - 1
    assert(not runScript('test','turnDraft','inspect',changed,data,init.draft).ok,'changed state reused')
    local stealth = init.state.player.stealth
    init.state.player.stealth = stealth - 1
    assert(not runScript('test','turnDraft','inspect',init.state,data,init.draft).ok,'in-place mutation reused')
    init.state.player.stealth = stealth
    local misses = getRunScriptCacheDiagnostics().validationMisses
    beginRunScriptEvent('test','buttonClick')
    call('turnDraft','inspect',init.state,data,init.draft)
    assert(getRunScriptCacheDiagnostics().validationMisses > misses,'reuse crossed event boundary')
    misses = getRunScriptCacheDiagnostics().validationMisses
    call('turnDraft','inspect',init.state,clone(data),init.draft)
    assert(getRunScriptCacheDiagnostics().validationMisses > misses,'different DB snapshot reused')
    misses = getRunScriptCacheDiagnostics().validationMisses
    assertOk('other chat',runScript('other-chat','turnDraft','inspect',init.state,data,init.draft))
    assert(getRunScriptCacheDiagnostics().validationMisses > misses,'reuse crossed trigger boundary')
    beginRunScriptEvent('test','unscoped')
    hits = getRunScriptCacheDiagnostics().validationHits
    call('turnDraft','inspect',init.state,data,init.draft)
    call('turnDraft','inspect',init.state,data,init.draft)
    assert(getRunScriptCacheDiagnostics().validationHits == hits,'unscoped calls retained reports')
end

local function event(a,...)
    beginRunScriptEvent('test','buttonClick')
    return call('battleController',a,...)
end
-- A successful validation must not turn a failed host write into a success.
store = {['battleRuntimeV1.authority']=clone(init.state),['battleRuntimeV1.draft']=clone(init.draft)}
chat = {{role='char',data='scene'}}
local ready = event('publishCurrentView').view
event('armSubmission',ready.interactionToken)
local writer = HostCompat.writeState
HostCompat.writeState = function(t,k,v)
    if k~='battleRuntimeV1.pending' then writer(t,k,v) end
end
beginRunScriptEvent('test','buttonClick')
local failed = runScript('test','battleController','prepareGeneration')
assert(not failed.ok and failed.errors[1].code=='state_write_not_persisted','dropped write hidden')
assert(store['battleRuntimeV1.draft'] and store['battleRuntimeV1.submission'],'retry inputs lost')
HostCompat.writeState = writer
assert(event('prepareGeneration').generationReady,'failed write could not retry')
local timings = {clickCard={},armSubmission={},prepareGeneration={},injectRequest={},commitOutput={}}
local snapshots = {}
local function measure(a,...)
    stateReads,htmlReads,moduleCalls=0,0,{}
    local start = os.clock()
    local result = event(a,...)
    if check_reuse and a=='clickCard' then
        assert(not moduleCalls['stateSchema.validateBattleState'],'click still fully validates authority')
        assert(not moduleCalls['cardCodex.record'],'click still scans codex/history')
        assert(htmlReads==0,'click still evaluates HTML lore through CBS')
        assert(stateReads<=6,'click still rereads persistent battle context')
    end
    timings[a][#timings[a]+1] = (os.clock()-start)*1000
    return result
end
for trial=1,7 do
    store = {['battleRuntimeV1.authority']=clone(init.state),['battleRuntimeV1.draft']=clone(init.draft)}
    chat = {{role='char',data='scene'}}
    local view = event('publishCurrentView').view
    local id
    for _,v in ipairs(init.state.cardInstances) do
        if v.owner=='player' and v.zone=='hand' then id=v.instanceId;break end
    end
    local clicked = measure('clickCard',assert(id),view.interactionToken)
    local stale = event('clickCard',id,view.interactionToken)
    assert(stale.stale and not stale.applied,'old click applied twice')
    measure('armSubmission',clicked.interactionToken)
    assert(measure('prepareGeneration').generationReady)
    local pending = clone(store['battleRuntimeV1.pending'])
    local injected = measure('injectRequest',{{role='user',content=chat[#chat].data}})
    assert(injected.promptArray)
    addChat('test','char','The turn is complete.')
    measure('commitOutput')
    assert(store['battleRuntimeV1.authority'].lastCommittedTurnId==pending.turnId,'turn not committed')
    local duplicate = call('battleRuntime','commitPending',store['battleRuntimeV1.authority'],data,pending)
    assert(not duplicate.applied,'duplicate turn applied')
    -- Return a full transcript for exact differential checks against the baseline runtime.
    if trial==7 then
        snapshots.controller = {pending=pending,prompt=injected.promptArray,authority=store['battleRuntimeV1.authority']}
    end
end
-- Preview draws that reshuffle must cancel without consuming authority RNG.
for _,cardId in ipairs({'pc_glutton_011','pc_predator_010'}) do
    beginRunScriptEvent('test','buttonClick')
    local deck={cardId,'pc_predator_001','pc_predator_002','pc_predator_003','pc_predator_004',
        'pc_predator_005','pc_deceiver_003','pc_harmonizer_001','pc_glutton_002','pc_glutton_003'}
    local state=call('battleBootstrap','fromSetup',{battleId='preview',seed=12345,
        playerCardIds=deck,characterId='yoo_jiyoung'},data).state
    local id,n=nil,0
    for _,v in ipairs(state.cardInstances) do
        if v.owner=='player' then
            if v.cardId==cardId then v.zone='deck';v.position=1;id=v.instanceId
            else n=n+1;v.zone='discard';v.position=n end
        end
    end
    state.player.baseDrawCount=1
    local initialized=call('turnInitializer','prepareTurn',state,data,{turnId='preview-turn-001'})
    store = {['battleRuntimeV1.authority']=clone(initialized.state),['battleRuntimeV1.draft']=clone(initialized.draft)}
    chat = {{role='char',data='scene'}}
    local initialView=event('publishCurrentView').view
    local uiWriter=HostCompat.writeChatVar
    HostCompat.writeChatVar=function(t,k,v)
        if k=='helltrainBattleInteractionV1' then error('injected UI write failure') end
        return uiWriter(t,k,v)
    end
    beginRunScriptEvent('test','buttonClick')
    local failedUi=runScript('test','battleController','clickCard',id,initialView.interactionToken)
    assert(not failedUi.ok and failedUi.errors[1].code=='ui_write_failed','UI fault not exercised')
    HostCompat.writeChatVar=uiWriter
    local selected=event('clickCard',id,initialView.interactionToken)
    assert(selected.stale and not selected.applied,'UI retry changed selection twice')
    local seen={}
    for _,card in ipairs(store.cardCodexV1.playerCardIds) do seen[card]=true end
    for _,drawn in ipairs(selected.draft.preview.availableDrawnInstanceIds) do
        for _,instance in ipairs(initialized.state.cardInstances) do
            if instance.instanceId==drawn then assert(seen[instance.cardId],'preview discovery lost') end
        end
    end
    local saved=clone(store['battleRuntimeV1.draft'])
    store['battleRuntimeV1.draft'].preview.rng.cursor=store['battleRuntimeV1.draft'].preview.rng.cursor+1
    beginRunScriptEvent('test','onStart')
    assert(not runScript('test','battleController','prepareGeneration').ok,'send accepted invalid preview')
    assert(store['battleRuntimeV1.pending']==nil,'invalid send created a pending turn')
    store['battleRuntimeV1.draft']=saved
    event('cancelCard',id,selected.interactionToken)
    local retained={}
    for _,card in ipairs(store.cardCodexV1.playerCardIds) do retained[card]=true end
    for card in pairs(seen) do assert(retained[card],'cancel removed a discovery') end
    beginRunScriptEvent('test','buttonClick')
    local draft=call('turnDraft','registerCard',initialized.state,data,initialized.draft,id).draft
    local projection=call('turnDraft','project',initialized.state,data,draft).projection
    assert(projection.projectedRng.cursor>initialized.state.rng.cursor,'shuffle fixture not exercised')
    local cancelled=call('turnDraft','cancelCard',initialized.state,data,draft,id).draft
    local reset=call('turnDraft','project',initialized.state,data,cancelled).projection
    assert(reset.projectedRng.cursor==initialized.state.rng.cursor,'cancel consumed RNG')
    local pending=call('battleRuntime','preparePending',initialized.state,data,projection).pendingTurn
    local prompt=call('turnPromptFormatter','formatPending',pending,data)
    local committed=call('battleRuntime','commitPending',initialized.state,data,pending)
    snapshots[cardId]={pending=pending,prompt=prompt,state=committed.state}
end
result_snapshot = json.encode(snapshots)
for _,action in ipairs({'clickCard','armSubmission','prepareGeneration','injectRequest','commitOutput'}) do
    local values=timings[action];table.sort(values)
    print(action..': median '..string.format('%.2f',values[4])..' ms')
end
print('PASS: production dispatcher selection, stale click, request, commit and reuse checks')
''')
if '--snapshot' in sys.argv:
    Path(sys.argv[sys.argv.index('--snapshot') + 1]).write_text(lua.globals().result_snapshot, encoding='utf-8')
