from pathlib import Path
import sys,re
from importlib import import_module
LuaRuntime=import_module('lupa.' + ('luajit21' if len(sys.argv)>1 and sys.argv[1]=='jit' else 'lua54')).LuaRuntime
lua=LuaRuntime()
s=Path('build/tests/turn-phase-draw-replay-check.ps1').read_text(encoding='utf-8-sig')
s=re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@",s,re.S)[1]
s=s[:s.index('local staticData = assertOk')]
s=s.replace('local modules = {','local modules = {\n battleRuntime=loadLore("System/battleRuntime.lua"),\n turnPresentation=loadLore("System/turnPresentation.lua"),\n turnPromptFormatter=loadLore("System/turnPromptFormatter.lua"),')
s=s.replace('    local sawDraw = false', '''
    local pending = assertOk("prepare pending",runScript("test","battleRuntime","preparePending",initialized.state,data,projection)).pendingTurn
    assertOk("presentation",runScript("test","turnPresentation","build",pending,data))
    assertOk("prompt",runScript("test","turnPromptFormatter","formatPending",pending,data))
    assertOk("reuse",runScript("test","battleRuntime","reusePending",initialized.state,data,pending))
    local committed=assertOk("commit",runScript("test","battleRuntime","commitPending",initialized.state,data,pending))
    assertOk("duplicate",runScript("test","battleRuntime","commitPending",committed.state,data,pending))
    for _, envelope in ipairs({'publicResult','llmEvent'}) do
      for index,event in ipairs(pending.turnResult[envelope].events) do
        if event.payload.op=='add_mood_token' and event.payload.moodTokenDebtBefore~=nil then
          for _,bad in ipairs({-1,false,0.5,9007199254740992}) do
            local forged=clone(pending)
            forged.turnResult[envelope].events[index].payload.moodTokenDebtBefore=bad
            local name=envelope=='publicResult' and 'turnPresentation' or 'turnPromptFormatter'
            local action=envelope=='publicResult' and 'build' or 'formatPending'
            assert(runScript('test',name,action,forged,data).ok==false,'invalid debt accepted')
          end
        end
      end
    end
    local sawDraw = false''')
s+='''
json=dofile("build/tests/fixtures/json.lua")
local data=assertOk("data",runScript("test","staticData","loadAll")).data
for _,amount in ipairs({1,3,5,7}) do
 data.cards.pc_deceiver_011.mechanismData.plan.resolve=function() return {
 {op="remove_mood_token",target="character",mood="suspicion",amount=amount==7 and 1 or 3,cause="plan_effect"},
 {op="add_mood_token",target="character",mood="suspicion",amount=amount,cause="plan_effect"},
 {op="draw_cards",target="player",amount=1,cause="plan_effect"},
 } end
 runPass(data,"debt-"..amount,"turn_start")
 print("debt pipeline OK",amount)
end
'''
lua.execute(s)

