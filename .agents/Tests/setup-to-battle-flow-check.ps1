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
if (-not $luaHost) {
    throw 'A Lua host is required. This check does not replace RisuAI integration testing.'
}

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

-- These are the real runtime modules used by the setup button route and its
-- battle handoff. Only the Risu host boundary is simulated below.
local modules = {
    deterministicRng = loadLore("System/deterministicRng.lua"),
    cardZones = loadLore("System/cardZones.lua"),
    effectEngine = loadLore("System/effectEngine.lua"),
    staticData = loadLore("System/staticData.lua"),
    gameSetup = loadLore("System/gameSetup.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
    triggerPipeline = loadLore("System/triggerPipeline.lua"),
    characterSelector = loadLore("System/characterSelector.lua"),
    turnInitializer = loadLore("System/turnInitializer.lua"),
    turnDraft = loadLore("System/turnDraft.lua"),
    turnResolver = loadLore("System/turnResolver.lua"),
    turnEventProjector = loadLore("System/turnEventProjector.lua"),
    battleRuntime = loadLore("System/battleRuntime.lua"),
    turnPresentation = loadLore("System/turnPresentation.lua"),
    viewBuilder = loadLore("System/viewBuilder.lua"),
    dataBridge = loadLore("System/dataBridge.lua"),
    battleBootstrap = loadLore("System/battleBootstrap.lua"),
    turnPromptFormatter = loadLore("System/turnPromptFormatter.lua"),
    gameSetupView = loadLore("System/gameSetupView.lua"),
    battleController = loadLore("System/battleController.lua"),
    gameSetupController = loadLore("System/gameSetupController.lua"),
}

local moduleActions = {}
function runScript(triggerId, name, ...)
    local module = assert(modules[name], "unknown module: " .. tostring(name))
    local action = select(1, ...)
    local key = tostring(name) .. "." .. tostring(action)
    moduleActions[key] = (moduleActions[key] or 0) + 1
    return module(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["CharacterList.db"] = "Char/CharacterList.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
    ["YoonSeoa.db"] = "Char/YoonSeoa.db",
    ["HanJenny.db"] = "Char/HanJenny.db",
    ["SeoMiryeong.db"] = "Char/SeoMiryeong.db",
    ["SisterAgnes.db"] = "Char/SisterAgnes.db",
    ["sideBar.html"] = "html/sideBar.html",
    ["cardDraft.html"] = "html/cardDraft.html",
    ["characterSelect.html"] = "html/characterSelect.html",
    ["battleui.html"] = "html/battleui.html",
}

local loreLoads = {}
function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    if path == nil then return {} end
    return { { content = readFile(path) } }
end
function loadLores(triggerId, name)
    loreLoads[name] = (loreLoads[name] or 0) + 1
    local content = ""
    for _, lore in ipairs(getLoreBooks(triggerId, name)) do
        content = content .. lore.content
    end
    return content ~= "" and content or nil
end

local function clone(value, active)
    if type(value) ~= "table" then return value end
    active = active or {}
    assert(active[value] == nil, "cycle in host fixture")
    active[value] = true
    local copy = {}
    for key, item in pairs(value) do
        copy[clone(key, active)] = clone(item, active)
    end
    active[value] = nil
    return copy
end

local function canonical(value, active)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    assert(kind == "table", "unsupported canonical type: " .. kind)
    active = active or {}
    assert(active[value] == nil, "cycle in canonical fixture")
    active[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        return type(left) .. ":" .. tostring(left) < type(right) .. ":" .. tostring(right)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = canonical(key, active) .. "=" .. canonical(value[key], active)
    end
    active[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function stableHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 131 + string.byte(value, index)) % 2147483647
    end
    return string.format("%010d", hash)
end

local function failReport(label, report)
    local messages = {}
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        messages[#messages + 1] = tostring(item.code)
            .. " at " .. tostring(item.path) .. ": " .. tostring(item.message)
    end
    error(label .. " failed | " .. table.concat(messages, " | "))
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        failReport(label, report)
    end
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0,
        label .. " returned errors")
    return report
end

local SETUP_AUTHORITY = "gameSetupV1.authority"
local SETUP_VIEW = "gameSetupView"
local BATTLE_VIEW = "battleView"
local UI_BODY = string.char(240, 159, 148, 175):rep(3)
local RUNTIME_KEYS = {
    "battleRuntimeV1.authority",
    "battleRuntimeV1.draft",
    "battleRuntimeV1.pending",
    "battleRuntimeV1.lastCommittedPending",
    "battleRuntimeV1.activeRequest",
}

local states = {}
local stateWrites = {}
local chatVars = {}
local cbsCalls = 0
local refreshCalls = 0
local alerts = {}

function setState(triggerId, key, value)
    stateWrites[key] = (stateWrites[key] or 0) + 1
    states[key] = clone(value)
end
function getState(triggerId, key)
    return clone(states[key])
end
function setChatVar(triggerId, key, value)
    chatVars[key] = value
end
function getChatVar(triggerId, key)
    return chatVars[key]
end
function cbs(source)
    cbsCalls = cbsCalls + 1
    assert(source == "{{randint::1::2147483646}}",
        "setup requested an unexpected CBS seed expression")
    return "13579"
end
function reloadDisplay(triggerId)
    refreshCalls = refreshCalls + 1
end
function refreshGameUi(triggerId)
    refreshCalls = refreshCalls + 1
end
function alertError(triggerId, message)
    alerts[#alerts + 1] = tostring(message)
end

local function controller(action, ...)
    return modules.gameSetupController("setup-to-battle-flow-check", action, ...)
end

local function runtimeSnapshot()
    local parts = {}
    for index, key in ipairs(RUNTIME_KEYS) do
        parts[index] = key .. "=" .. canonical(states[key])
    end
    return table.concat(parts, "|")
end

local function runtimeWriteSnapshot()
    local parts = {}
    for index, key in ipairs(RUNTIME_KEYS) do
        parts[index] = key .. "=" .. tostring(stateWrites[key] or 0)
    end
    return table.concat(parts, "|")
end

-- Start through the real gameSetupController and choose one deterministic
-- offered card in every round.
local started = assertOk("start setup", controller("start"))
assert(started.action == "start" and started.applied == true
        and started.state.phase == "deckDraft",
    "start did not create the first deck draft")
assert(cbsCalls == 1, "fresh setup must consume exactly one CBS seed")
assert(chatVars[UI_BODY] == readFile("html/cardDraft.html"),
    "fresh setup did not publish cardDraft.html")
assert(refreshCalls == 0, "setup start manually refreshed the display")

local finalCardId
local finalCardToken
local rounds = 0
while states[SETUP_AUTHORITY].phase == "deckDraft" do
    local current = clone(states[SETUP_AUTHORITY])
    rounds = rounds + 1
    finalCardId = current.offer.cardIds[1]
    finalCardToken = current.offer.interactionToken
    local chosen = assertOk("choose card " .. rounds,
        controller("choose", finalCardId, finalCardToken))
    assert(chosen.applied == true and chosen.stale == false,
        "card choice was not applied")
end
assert(rounds == 10, "setup did not require exactly ten card choices")

local characterSelect = clone(states[SETUP_AUTHORITY])
assert(characterSelect.phase == "characterSelect"
        and #characterSelect.selectedCardIds == 10,
    "tenth card did not advance directly to characterSelect")
local candidates = characterSelect.characterOffer.characterIds
assert(#candidates == 3
        and candidates[1] ~= candidates[2]
        and candidates[1] ~= candidates[3]
        and candidates[2] ~= candidates[3],
    "character offer must contain three distinct candidates")
assert(chatVars[UI_BODY] == readFile("html/characterSelect.html"),
    "characterSelect did not publish characterSelect.html")
assert(type(chatVars[SETUP_VIEW]) == "string" and chatVars[SETUP_VIEW] ~= "",
    "characterSelect did not publish gameSetupView")
assert(cbsCalls == 1, "draft or character offer consumed another CBS seed")
assert(refreshCalls == 0, "card draft manually refreshed the display")

-- Confirm a candidate. The real battleController must bootstrap the selected
-- deck/character, initialize turn one, publish battleView, and replace the UI.
local selectedCharacterId = candidates[1]
local characterToken = characterSelect.characterOffer.interactionToken
local selected = assertOk("choose character", controller(
    "chooseCharacter",
    selectedCharacterId,
    characterToken
))
local receipt = states[SETUP_AUTHORITY]
assert(receipt.phase == "battleReady"
        and receipt.selectedCharacterId == selectedCharacterId
        and #receipt.selectedCardIds == 10
        and type(receipt.battleSpec) == "table"
        and receipt.battleSpec.battleId == "battle-" .. receipt.setupId
        and receipt.battleSpec.environmentId == "uncrowded"
        and receipt.battleSpec.turnLimit == 10,
    "character choice did not persist the canonical battleReady receipt")
assert(selected.action == "chooseCharacter"
        and selected.applied == true
        and selected.stale == false
        and selected.view.phase == "battleReady"
        and selected.battle.applied == true
        and selected.battle.reused == false
        and selected.battleView.phase == "selecting"
        and type(selected.battleView.turn) == "table"
        and selected.battleView.turn.number == 1
        and type(selected.battleView.hand) == "table"
        and #selected.battleView.hand.items > 0,
    "character choice did not reach a playable first selecting battle View")

assert(type(states[RUNTIME_KEYS[1]]) == "table"
        and states[RUNTIME_KEYS[1]].battleId == receipt.battleSpec.battleId
        and states[RUNTIME_KEYS[1]].turnNumber == 1,
    "battle authority was not initialized from the setup receipt")
assert(type(states[RUNTIME_KEYS[2]]) == "table"
        and type(states[RUNTIME_KEYS[2]].source) == "table"
        and states[RUNTIME_KEYS[2]].source.turnNumber == 1,
    "first selecting draft was not initialized")
assert(states[RUNTIME_KEYS[3]] == nil
        and states[RUNTIME_KEYS[4]] == nil
        and states[RUNTIME_KEYS[5]] == nil,
    "new battle must not start with pending or request state")
for _, key in ipairs(RUNTIME_KEYS) do
    assert(stateWrites[key] == 1,
        "initial handoff did not write and verify runtime slot " .. key)
end
assert(type(chatVars[BATTLE_VIEW]) == "string" and chatVars[BATTLE_VIEW] ~= "",
    "battle handoff did not publish battleView")
assert(chatVars[UI_BODY] == readFile("html/battleui.html"),
    "battle handoff did not replace the setup body with battleui.html")
assert((loreLoads["battleui.html"] or 0) == 1,
    "initial battle UI was not loaded exactly once")
assert(cbsCalls == 1, "battle handoff consumed another CBS seed")
assert(refreshCalls == 0, "setup-to-battle handoff manually refreshed the display")
assert(#alerts == 0, "successful flow emitted an error alert")
assert((moduleActions["battleController.startFromSetup"] or 0) == 1,
    "gameSetupController did not use the real battleController handoff once")

local setupReceiptSnapshot = canonical(receipt)
local battleSnapshot = runtimeSnapshot()
local battleWriteSnapshot = runtimeWriteSnapshot()
local battleWire = chatVars[BATTLE_VIEW]

local function assertRetryPreserved(label, report, expectedStale)
    assert(report.applied == false
            and report.stale == expectedStale
            and report.battle.applied == false
            and report.battle.reused == true
            and report.battleView.phase == "selecting",
        label .. " did not reuse the selecting battle")
    assert(canonical(states[SETUP_AUTHORITY]) == setupReceiptSnapshot,
        label .. " changed the battleReady setup receipt")
    assert(runtimeSnapshot() == battleSnapshot,
        label .. " changed one of the five battle runtime values")
    assert(runtimeWriteSnapshot() == battleWriteSnapshot,
        label .. " rewrote one of the five battle runtime slots")
    assert(chatVars[BATTLE_VIEW] == battleWire,
        label .. " produced a different battle View from unchanged runtime")
    assert(chatVars[UI_BODY] == readFile("html/battleui.html"),
        label .. " did not preserve battleui.html")
    assert(cbsCalls == 1, label .. " consumed another CBS seed")
    assert(refreshCalls == 0, label .. " manually refreshed the display")
end

-- All routes that may be delivered twice by a remounted Risu button must
-- converge on the same progressed runtime without bootstrapping again.
assertRetryPreserved(
    "start retry",
    assertOk("start retry", controller("start")),
    false
)
assertRetryPreserved(
    "character double click",
    assertOk("character double click", controller(
        "chooseCharacter",
        selectedCharacterId,
        characterToken
    )),
    true
)
assertRetryPreserved(
    "old final-card retry",
    assertOk("old final-card retry", controller(
        "choose",
        finalCardId,
        finalCardToken
    )),
    true
)

assert((moduleActions["battleController.startFromSetup"] or 0) == 4,
    "setup retries did not pass through the idempotent real battle handoff")
assert((loreLoads["battleui.html"] or 0) == 4,
    "battle retry did not republish the current battle UI exactly once per route")
assert(#alerts == 0, "successful retry flow emitted an error alert")

local signature = table.concat({
    receipt.setupId,
    receipt.selectedCharacterId,
    table.concat(candidates, ","),
    table.concat(receipt.selectedCardIds, ","),
    receipt.battleSpec.battleId,
    tostring(states[RUNTIME_KEYS[1]].turnNumber),
    stableHash(battleSnapshot),
}, "|")
print("SETUP_TO_BATTLE_FLOW|hash=" .. stableHash(signature)
    .. "|rounds=" .. rounds .. "|candidates=" .. #candidates .. "|retries=3")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[setup-to-battle-flow-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first setup-to-battle flow check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second setup-to-battle flow check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different setup-to-battle results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^SETUP_TO_BATTLE_FLOW\|hash=\d{10}\|rounds=10\|candidates=3\|retries=3$') {
        throw "Unexpected setup-to-battle flow output: $firstText"
    }

    Write-Output $firstText
    Write-Output 'PASS: real setup controller reaches a deterministic, idempotent first battle without manual reload.'
    Write-Output 'NOTE: register the four HTML lores and all DB/character lores by exact filename before RisuAI integration testing.'
}
finally {
    Pop-Location
}
