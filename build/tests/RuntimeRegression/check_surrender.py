"""Run surrender through resolution, prompt generation, retry and commit."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
from lupa.lua54 import LuaRuntime

source = (ROOT / 'build/tests/turn-phase-draw-replay-check.ps1').read_text(encoding='utf-8-sig')
harness = re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@", source, re.S)[1]
harness = harness[:harness.index('local function runPass')]
harness += '''
setmetatable(modules, { __index = function(t, name)
    local handler = loadLore("System/" .. name .. ".lua")
    rawset(t, name, handler)
    return handler
end })
json = dofile("build/tests/fixtures/json.lua")
local data = assertOk("data", runScript("test", "staticData", "loadAll")).data
for _, turn in ipairs({1}) do
    local state = newState(data, "surrender-" .. turn, {turnNumber = turn})
    local initialized = assertOk("initialize", runScript("test", "turnInitializer", "prepareTurn", state, data, {
        turnId = string.format("surrender-%d-turn-%03d", turn, turn)
    }))
    local before = initialized.state
    local projection = assertOk("project", runScript("test", "turnDraft", "project", before, data, initialized.draft)).projection
    local pending = assertOk("surrender", runScript("test", "battleRuntime", "preparePending", before, data, projection, true)).pendingTurn
    assert(pending.afterState.status == "defeat" and pending.afterState.surrendered == true)
    assert(pending.afterState.player.stealth == before.player.stealth)
    assert(pending.afterState.character.resistance == before.character.resistance)
    for _, event in ipairs(pending.turnResult.events) do
        assert(event.type ~= "card_declared", "surrender played a card")
    end
    local formatted = assertOk("prompt", runScript("test", "turnPromptFormatter", "formatPending", pending, data))
    assert(formatted.message.content:find("열차문을 나서자 눈앞이 깜깜하게 암전된다", 1, true))
    assertOk("reuse", runScript("test", "battleRuntime", "reusePending", before, data, pending))
    local committed = assertOk("commit", runScript("test", "battleRuntime", "commitPending", before, data, pending))
    local duplicate = assertOk("duplicate", runScript("test", "battleRuntime", "commitPending", committed.state, data, pending))
    assert(duplicate.applied == false)

    local store, vars, chat = {}, {}, {{role = "char", data = "Approach scene"}}
    function getState(_, key) return clone(store[key]) end
    function setState(_, key, value) store[key] = clone(value) end
    function getChatVar(_, key) return vars[key] end
    function setChatVar(_, key, value) vars[key] = value end
    function getFullChat() return clone(chat) end
    function addChat(_, role, text) chat[#chat + 1] = {role = role, data = text} end
    function removeChat(_, index) table.remove(chat, index + 1) end
    function loadLores(_, name) return readFile("html/" .. name) end
    function refreshGameUi() end
    function reloadChat() end
    function debug() end
    modules.gameSetupController = function(_, action, summary)
        assert(action == "completeBattle" and summary.reasonCode == "surrender")
        return {ok = true, schemaVersion = 1, errors = {}, view = {}, state = {}}
    end
    assert(runScript("test", "hostCompat", "install") == true)
    store['battleRuntimeV1.authority'] = before
    store['battleRuntimeV1.draft'] = initialized.draft
    assertOk("publish", runScript("test", "battleController", "publishCurrentView"))
    local token = assertOk("inspect", runScript("test", "turnDraft", "inspect", before, data, initialized.draft)).interactionToken
    local stale = assertOk("stale", runScript("test", "battleController", "surrender", "old-token"))
    assert(stale.stale and not store['battleRuntimeV1.pending'])
    assertOk("button", runScript("test", "battleController", "surrender", token))
    assert(runScript("test", "battleController", "surrender", token).ok == false)
    assertOk("prepare", runScript("test", "battleController", "prepareGeneration"))
    local retry = assertOk("retry without output", runScript("test", "battleController", "prepareGeneration"))
    assert(retry.generationReady)
    assertOk("inject", runScript("test", "battleController", "injectRequest", {{role = "user", content = chat[#chat].data}}))
    addChat("test", "char", "The player leaves the train and everything goes dark.")
    assertOk("controller commit", runScript("test", "battleController", "commitOutput"))
    local summary = assertOk("terminal summary", runScript("test", "battleController", "getTerminalSummary"))
    assert(summary.summary.reasonCode == "surrender")

    store, vars, chat = {}, {}, {{role = "char", data = "Approach scene"}}
    store['battleRuntimeV1.authority'] = before
    store['battleRuntimeV1.draft'] = initialized.draft
    function splitByDelimiter(value, delimiter)
        local parts = {}
        for part in value:gmatch('[^' .. delimiter .. ']+') do parts[#parts + 1] = part end
        return parts
    end
    function alertError(_, message) error(message) end
    local calls = 0
    function LLM(_, prompt)
        calls = calls + 1
        local found = false
        for _, message in ipairs(prompt) do
            found = found or message.content:find("열차문을 나서자 눈앞이 깜깜하게 암전된다", 1, true) ~= nil
        end
        assert(found, "surrender prompt missing")
        return {success = true, result = "The player leaves the train and everything goes dark."}
    end
    runScript("test", "hostFlow", "buttonClick", "battleController|surrender|" .. token)
    assert(calls == 1 and store['battleRuntimeV1.authority'].surrendered == true)
end
print("surrender regression passed")
'''
LuaRuntime().execute(harness)

source = (ROOT / 'build/tests/setup-to-battle-flow-check.ps1').read_text(encoding='utf-8-sig')
setup = re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@", source, re.S)[1]
setup = setup[:setup.index('print("DEBUG_SELECTED=')]
setup += '''
setmetatable(modules, { __index = function(t, name)
    local handler = loadLore("System/" .. name .. ".lua")
    rawset(t, name, handler)
    return handler
end })
json = dofile("build/tests/fixtures/json.lua")
lorePaths["postBattle.html"] = "html/postBattle.html"
local chat = {{role = "char", data = "Approach scene"}}
function getFullChat() return clone(chat) end
function addChat(_, role, text) chat[#chat + 1] = {role = role, data = text} end
function removeChat(_, index) table.remove(chat, index + 1) end
local function battle(action, ...)
    return assertOk(action, runScript("test", "battleController", action, ...))
end
battle("surrender", selected.battleView.interactionToken)
battle("prepareGeneration")
battle("injectRequest", {{role = "user", content = chat[#chat].data}})
addChat("test", "char", "The player leaves the train and everything goes dark.")
local committed = battle("commitOutput")
assert(committed.view.result.reasonCode == "surrender")
assert(committed.view.result.reasonLabel == "공략 포기 · 하차")
print("surrender settlement and result view passed")
'''
LuaRuntime().execute(setup)
