$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$luaCommand = Get-Command lua -ErrorAction SilentlyContinue
$luaHost = if ($luaCommand) {
    $luaCommand.Source
} else {
    Get-ChildItem "$env:USERPROFILE\.vscode\extensions\sumneko.lua-*-win32-x64\server\bin\lua-language-server.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $luaHost) { throw 'Lua 실행기를 찾을 수 없습니다.' }

$luaTest = @'
local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadLore(path)
    return assert(load("return" .. readFile(path), "@" .. path, "t", _G))()
end

local modules = {}
for _, name in ipairs({
    "battleBootstrap", "battleHistory", "battleRuntime", "cardZones", "characterSelector",
    "deterministicRng", "effectEngine", "stateSchema", "staticData", "subwayJourney",
    "triggerPipeline", "turnDraft", "turnEventProjector", "turnInitializer",
    "turnPresentation", "turnPromptFormatter", "turnResolver",
}) do
    modules[name] = loadLore("System/" .. name .. ".lua")
end

function runScript(triggerId, name, ...)
    return assert(modules[name], "unknown module: " .. tostring(name))(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["TokyoSubwayLines.db"] = "DB/TokyoSubwayLines.db",
    ["CharacterList.db"] = "Char/CharacterList.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
    ["YoonSeoa.db"] = "Char/YoonSeoa.db",
    ["HanJenny.db"] = "Char/HanJenny.db",
    ["SeoMiryeong.db"] = "Char/SeoMiryeong.db",
    ["SisterAgnes.db"] = "Char/SisterAgnes.db",
}

function getLoreBooks(_, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end

function loadLores(triggerId, name)
    local chunks = {}
    for _, lore in ipairs(getLoreBooks(triggerId, name)) do chunks[#chunks + 1] = lore.content end
    return #chunks > 0 and table.concat(chunks) or nil
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local errors = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            errors[#errors + 1] = tostring(item.code) .. " at " .. tostring(item.path)
        end
        error(label .. " failed: " .. table.concat(errors, ", "))
    end
    return report
end

local function findInstance(state, side, cardId, zone)
    for _, instance in ipairs(state.cardInstances) do
        if instance.owner == side and instance.cardId == cardId and instance.zone == zone then
            return instance.instanceId
        end
    end
    error("instance missing: " .. side .. "/" .. cardId .. "/" .. zone)
end

local function planSpec(staticData, cardId, charges)
    local plan = assert(staticData.cards[cardId].mechanismData.plan)
    return {
        durationTurns = plan.durationTurns,
        durationIncludesPlacementTurn = plan.durationIncludesPlacementTurn == true,
        charges = charges or plan.charges,
        revealed = false,
    }
end

local staticData = assertOk("static data", runScript("remove-all-plan", "staticData", "loadAll")).data
local deck = {
    "pc_deceiver_004", "pc_deceiver_008", "pc_predator_011", "pc_harmonizer_009", "pc_glutton_001",
    "pc_glutton_002", "pc_glutton_003", "pc_glutton_004", "pc_glutton_005", "pc_glutton_006",
}
local state = assertOk("bootstrap", runScript("remove-all-plan", "battleBootstrap", "fromSetup", {
    battleId = "remove-all-plan-battle",
    seed = 20260903,
    playerCardIds = deck,
    characterId = "yoo_jiyoung",
}, staticData)).state
state.player.maxHandSize = #deck
state.character.maxHandSize = 20
state = assertOk("draw player", runScript(
    "remove-all-plan", "cardZones", "draw", state, "player", #deck
)).state
state = assertOk("draw character", runScript(
    "remove-all-plan", "cardZones", "draw", state, "character", 20
)).state
state = assertOk("expand player plans", runScript(
    "remove-all-plan", "cardZones", "setPlanCapacity", state, "player", 3
)).state

for _, cardId in ipairs({ "pc_deceiver_008", "pc_predator_011", "pc_harmonizer_009" }) do
    state = assertOk("place " .. cardId, runScript(
        "remove-all-plan", "cardZones", "placePlan", state, "player",
        findInstance(state, "player", cardId, "hand"), planSpec(staticData, cardId)
    )).state
end
state = assertOk("place character plan", runScript(
    "remove-all-plan", "cardZones", "placePlan", state, "character",
    findInstance(state, "character", "jiyoung_silent_glare", "hand"),
    planSpec(staticData, "jiyoung_silent_glare", 2)
)).state

local turnId = state.battleId .. "-turn-001"
local initialized = assertOk("initialize", runScript(
    "remove-all-plan", "turnInitializer", "prepareTurn", state, staticData, { turnId = turnId }
))
local draft = assertOk("register sudden event", runScript(
    "remove-all-plan", "turnDraft", "registerCard", initialized.state, staticData,
    initialized.draft, findInstance(initialized.state, "player", "pc_deceiver_004", "hand")
)).draft
local projection = assertOk("project", runScript(
    "remove-all-plan", "turnDraft", "project", initialized.state, staticData, draft
)).projection
local pending = assertOk("prepare pending", runScript(
    "remove-all-plan", "battleRuntime", "preparePending", initialized.state, staticData, projection
)).pendingTurn

assert(#pending.afterState.player.planSlots == 0, "player plans were not removed")
assert(#pending.afterState.character.planSlots == 0, "character plans were not removed")
local removed = 0
local exitEffects = 0
for _, event in ipairs(pending.turnResult.events) do
    if event.type == "plan_changed" and event.payload.action == "removed" then removed = removed + 1 end
    if event.type == "effect_applied" and event.source.id == "pc_deceiver_008"
        and event.cause.kind == "plan_explicit_exit" and event.payload.amount == 3 then
        exitEffects = exitEffects + 1
    end
end
assert(removed == 4, "expected four plan removal events, got " .. tostring(removed))
assert(exitEffects == 1, "plan exit callback was not applied exactly once")
print("REMOVE_ALL_PLAN|player=3|character=1|exit=ok|projection=ok")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[remove-all-plan-check]],[[t]],_G))()'
    $output = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "전체 계획 제거 검사가 실패했습니다.`n$($output -join "`n")" }
    if (($output -join "`n") -cne 'REMOVE_ALL_PLAN|player=3|character=1|exit=ok|projection=ok') {
        throw "전체 계획 제거 표식이 예상과 다릅니다: $($output -join "`n")"
    }
    Write-Output 'remove-all-plan-check: ok'
}
finally {
    Pop-Location
}
