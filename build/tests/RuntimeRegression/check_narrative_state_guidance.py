"""Verify narrative guidance uses final resistance and stealth bands."""
from pathlib import Path
from importlib import import_module
import re

ROOT = Path(__file__).resolve().parents[3]
LuaRuntime = import_module("lupa.lua54").LuaRuntime

source = (ROOT / "build/tests/turn-phase-draw-replay-check.ps1").read_text(encoding="utf-8-sig")
harness = re.search(r"\$luaTest\s*=\s*@'\n(.*?)\n'@", source, re.S)[1]
harness = harness[:harness.index("local function runPass")]
harness += r'''
setmetatable(modules, { __index = function(t, name)
    local handler = loadLore("System/" .. name .. ".lua")
    rawset(t, name, handler)
    return handler
end })

local data = assertOk("data", runScript("test", "staticData", "loadAll")).data

local cases = {
    { value = 9, resistance = "[저항 상태: 거의 붕괴]", stealth = "[은폐 상태: 발각 임박]" },
    { value = 10, resistance = "[저항 상태: 동요]", stealth = "[은폐 상태: 경계받음]" },
    { value = 19, resistance = "[저항 상태: 동요]", stealth = "[은폐 상태: 경계받음]" },
    { value = 20, resistance = "[저항 상태: 완강]", stealth = "[은폐 상태: 안전]" },
}

local resistanceMarkers = {
    "[저항 상태: 거의 붕괴]",
    "[저항 상태: 동요]",
    "[저항 상태: 완강]",
}
local stealthMarkers = {
    "[은폐 상태: 발각 임박]",
    "[은폐 상태: 경계받음]",
    "[은폐 상태: 안전]",
}

local function assertOnlyMarker(content, expected, markers, label)
    for _, marker in ipairs(markers) do
        local found = content:find(marker, 1, true) ~= nil
        assert(found == (marker == expected), label .. " selected the wrong narrative band")
    end
end

for _, case in ipairs(cases) do
    local battleId = "narrative-band-" .. case.value
    local state = newState(data, battleId, { stealth = case.value, resistance = case.value })
    local initialized = assertOk("initialize", runScript("test", "turnInitializer", "prepareTurn", state, data, {
        turnId = battleId .. "-turn-001",
    }))
    local projection = assertOk("project", runScript(
        "test", "turnDraft", "project", initialized.state, data, initialized.draft
    )).projection
    local pending = assertOk("surrender", runScript(
        "test", "battleRuntime", "preparePending", initialized.state, data, projection, true
    )).pendingTurn
    local content = assertOk("format", runScript(
        "test", "turnPromptFormatter", "formatPending", pending, data
    )).message.content

    assert(pending.afterState.character.resistance == case.value)
    assert(pending.afterState.player.stealth == case.value)
    assertOnlyMarker(content, case.resistance, resistanceMarkers, "resistance " .. case.value)
    assertOnlyMarker(content, case.stealth, stealthMarkers, "stealth " .. case.value)
end

-- The formatter must use the state after both sides' cards and all effects resolve.
local battleId = "narrative-after-state"
local state = newState(data, battleId, { stealth = 20, resistance = 20 })
local initialized = assertOk("initialize crossing turn", runScript(
    "test", "turnInitializer", "prepareTurn", state, data, { turnId = battleId .. "-turn-001" }
))
local draft = assertOk("register crossing card", runScript(
    "test", "turnDraft", "registerCard", initialized.state, data, initialized.draft, battleId .. "-p1"
)).draft
local projection = assertOk("project crossing turn", runScript(
    "test", "turnDraft", "project", initialized.state, data, draft
)).projection
local pending = assertOk("prepare crossing turn", runScript(
    "test", "battleRuntime", "preparePending", initialized.state, data, projection
)).pendingTurn
assert(pending.beforeState.player.stealth == 20, "fixture must begin at the high stealth boundary")
assert(pending.beforeState.character.resistance == 20, "fixture must begin at the high resistance boundary")
assert(
    pending.afterState.player.stealth >= 10 and pending.afterState.player.stealth < 20,
    "fixture must cross into the middle stealth band after every resolved effect"
)
assert(
    pending.afterState.character.resistance >= 10 and pending.afterState.character.resistance < 20,
    "fixture must cross into the middle resistance band after every resolved effect"
)
local content = assertOk("format crossing turn", runScript(
    "test", "turnPromptFormatter", "formatPending", pending, data
)).message.content
assertOnlyMarker(content, "[저항 상태: 동요]", resistanceMarkers, "post-resolution resistance")
assertOnlyMarker(content, "[은폐 상태: 경계받음]", stealthMarkers, "post-resolution stealth")

print("narrative state guidance regression passed")
'''

LuaRuntime().execute(harness)
