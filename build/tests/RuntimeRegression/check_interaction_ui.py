"""Pure interaction renderer: routes, branches, accessible markup and escaping."""
from importlib import import_module
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
engine = 'luajit21' if any(arg in ('jit', 'luajit21') for arg in sys.argv) else 'lua54'
lua = import_module('lupa.' + engine).LuaRuntime(unpack_returned_tuples=True)
source = (ROOT / 'System/battleInteractionUi.lua').read_text(encoding='utf-8-sig')
assert '{{' not in source and '}}' not in source
lua.globals().render = lua.execute('return ' + source)
lua.execute(r'''
local function has(html, text) assert(html:find(text,1,true), 'missing: '..text) end
local function lacks(html, text) assert(not html:find(text,1,true), 'unexpected: '..text) end
local c = {instanceId='card-1',name='A<&"\'',selected=false,hasEffectChoices=false,
 origin='preview',playable=false,finalStealthCost=7,finalResistanceDamage=9,
 cardType={id='action',label='행동'}, roles={{id='chain',label='연계'}},
 mechanisms={{id='draw',label='드로우'}}, descriptionSegments={{kind='text',value='<detail>'},
 {kind='tag',id='draw',label='드로우',tagKind='mechanism'}},
 ruleLines={{segments={{kind='tag',id='chain',label='연계',tagKind='role'}}}},
 reasonCode='insufficient_stealth',selectionOrder=2,
 effectChoices={{id='yes',label='선택',selectable=true,descriptionSegments={{kind='text',value='<choice>'},{kind='tag',label='태그'}}},
 {id='no',label='불가',selectable=false,unavailableText='<blocked>',descriptionSegments={}}},
 selectedEffectChoice={label='선택'}}
local v = {battleId='b',turnId='t',interactionToken='token&"',locked=false,phase='selecting',
 hand={count=1,items={c}},zones={deckCount=3,discardCount=4,removedCount=5},
 selection={focusedInstanceId='card-1',count=1,mode='pass',submissionArmed=false,canSubmit=true}}
local function html()
 local r=render('test','render',v); assert(r.ok==true and type(r.html)=='string')
 assert(r.schemaVersion==1 and type(r.errors)=='table' and #r.errors==0, 'invalid module envelope')
 return r.html
end
local h=html()
has(h,'is-focused');has(h,'is-preview');has(h,'is-unplayable');has(h,'DRAW PREVIEW')
has(h,'A&lt;&amp;&quot;&#39;');has(h,'battleController|clickCard|card-1|token&amp;&quot;')
has(h,'popovertarget="htp-b-t-tag-action"');has(h,'popovertarget="htp-b-t-tag-chain"')
has(h,'ht-inline-tag--mechanism');has(h,'&lt;detail&gt;');has(h,'은폐가 부족합니다')
has(h,'<b>7</b>');has(h,'<b>9</b>');has(h,'카드 없이 패스');has(h,'턴 넘기기 준비')
has(h,'battleController|surrender|token&amp;&quot;');has(h,'battleController|armSubmission|token&amp;&quot;')
has(h,'aria-pressed="false"');lacks(h,'EFFECT CHOICE')
c.hasEffectChoices=true;c.reasonCode='no_available_effect_choice'
h=html();has(h,'popovertarget="htp-b-t-choice-card-1"');has(h,'aria-haspopup="dialog"')
lacks(h,'battleController|clickCard|');has(h,'누르면 사용할 효과 선택')
has(h,'battleController|selectCardEffect|card-1|yes|token&amp;&quot;')
has(h,'disabled aria-disabled="true"');has(h,'&lt;choice&gt;태그');has(h,'&lt;blocked&gt;')
has(h,'선택 가능한 효과가 없습니다');has(h,'popovertargetaction="hide"')
c.selected=true;v.selection.mode='action';v.locked=true
h=html();has(h,'is-selected');has(h,'aria-expanded="true"');has(h,'aria-pressed="true" disabled')
has(h,'다시 누르면 선택 취소');has(h,'선택 효과 · 선택');has(h,'1장 선택됨')
has(h,'battleController|clickCard|card-1|token&amp;&quot;')
local action=h:match('<button type="button" class="ht%-card%-action"(.-)</button>')
lacks(action,'popovertarget');has(action,'disabled')
v.selection.focusedInstanceId='';h=html();has(h,'aria-expanded="false"');lacks(h,'ht-card-detail')
v.selection.mode='chain_pass';v.selection.canSubmit=false;h=html()
has(h,'연계만 사용 · 주 행동 패스');has(h,'disabled>선택 확정')
v.selection.submissionArmed=true;h=html();has(h,'ht-submit is-armed');has(h,'전송하면 확정')
lacks(h,'battleController|armSubmission')
v.phase='awaitingOutput';h=html();has(h,'ht-selection-dot--wait');has(h,'턴 결과를 기다리는 중…')
lacks(h,'battleController|surrender');lacks(h,'ht-submit')
v.phase='ended';h=html();has(h,'전투 종료');lacks(h,'ht-selection-dot')
v.hand={count=0,items={}};h=html();lacks(h,'ht-card-action');has(h,'ht-cards')
assert(c.name=='A<&"\'' and v.interactionToken=='token&"', 'input was mutated')
v.hand={count=1,items={c}};c.instanceId='evil"><script>x</script>';v.battleId='b"';v.turnId='t&'
h=html();lacks(h,'<script>');has(h,'evil&quot;&gt;&lt;script&gt;x&lt;/script&gt;')
has(h,'htp-b&quot;-t&amp;-tag-action')
local failed=render('test','unknown',v)
assert(failed.ok==false and failed.schemaVersion==1 and #failed.errors==1)
''')
print('PASS interaction UI (' + engine + ')')
