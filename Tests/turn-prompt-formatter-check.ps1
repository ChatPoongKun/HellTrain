$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
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

local modules = {
    deterministicRng = loadLore("System/deterministicRng.lua"),
    cardZones = loadLore("System/cardZones.lua"),
    effectEngine = loadLore("System/effectEngine.lua"),
    staticData = loadLore("System/staticData.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
    triggerPipeline = loadLore("System/triggerPipeline.lua"),
    characterSelector = loadLore("System/characterSelector.lua"),
    turnInitializer = loadLore("System/turnInitializer.lua"),
    turnDraft = loadLore("System/turnDraft.lua"),
    turnResolver = loadLore("System/turnResolver.lua"),
    turnEventProjector = loadLore("System/turnEventProjector.lua"),
    battleRuntime = loadLore("System/battleRuntime.lua"),
    turnPromptFormatter = loadLore("System/turnPromptFormatter.lua"),
}

function runScript(triggerId, name, ...)
    local module = assert(modules[name], "unknown module: " .. tostring(name))
    return module(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
}

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    if not path then return {} end
    return { { content = readFile(path) } }
end

local hostWriteCalls = 0
local function rejectHostWrite(name)
    return function()
        hostWriteCalls = hostWriteCalls + 1
        error("formatter attempted host write through " .. name)
    end
end
setState = rejectHostWrite("setState")
setChatVar = rejectHostWrite("setChatVar")
addChat = rejectHostWrite("addChat")
setChat = rejectHostWrite("setChat")
editRequest = rejectHostWrite("editRequest")

local function clone(value, active)
    if type(value) ~= "table" then return value end
    active = active or {}
    assert(not active[value], "cycle in test data")
    active[value] = true
    local copy = {}
    for key, item in pairs(value) do copy[clone(key, active)] = clone(item, active) end
    active[value] = nil
    return copy
end

local function canonical(value, active)
    local valueType = type(value)
    if valueType == "nil" then return "null" end
    if valueType == "boolean" or valueType == "number" then return tostring(value) end
    if valueType == "string" then return string.format("%q", value) end
    if valueType == "function" then return string.format("%q", tostring(value)) end
    assert(valueType == "table", "non-data canonical value: " .. valueType)
    active = active or {}
    assert(not active[value], "cycle in canonical value")
    active[value] = true
    local keys = {}
    local numericCount = 0
    local maximum = 0
    local hasOther = false
    for key in pairs(value) do
        keys[#keys + 1] = key
        if type(key) == "number" and key % 1 == 0 and key >= 1 then
            numericCount = numericCount + 1
            maximum = math.max(maximum, key)
        else
            hasOther = true
        end
    end
    local parts = {}
    if not hasOther and numericCount == maximum then
        for index = 1, maximum do parts[index] = canonical(value[index], active) end
        active[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end
    table.sort(keys, function(left, right)
        return type(left) .. ":" .. tostring(left) < type(right) .. ":" .. tostring(right)
    end)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = canonical(tostring(key), active) .. ":" .. canonical(value[key], active)
    end
    active[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function stableHash(value)
    local hash = 0
    for index = 1, #value do hash = (hash * 131 + string.byte(value, index)) % 2147483647 end
    return string.format("%010d", hash)
end

local function failReport(label, report)
    local messages = {}
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path) .. ": " .. tostring(item.message)
    end
    error(label .. " failed | " .. table.concat(messages, " | "))
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then failReport(label, report) end
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    return report
end

local function assertFails(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.message == nil and report.publicMarker == nil, label .. " exposed partial prompt output")
    for _, item in ipairs(report.errors or {}) do
        if item.code == expectedCode then return end
    end
    failReport(label .. " (missing " .. tostring(expectedCode) .. ")", report)
end

local staticReport = assertOk("static load", runScript("prompt-check", "staticData", "loadAll"))
local staticData = staticReport.data

local rawState = {
    schemaVersion = 1,
    kind = "battleState",
    battleId = "prompt-runtime",
    status = "active",
    turnNumber = 1,
    turnLimit = 10,
    environmentId = "uncrowded",
    rng = { seed = 20260719, cursor = 0 },
    player = {
        stealth = 30,
        baseDrawCount = 3,
        maxHandSize = 5,
        perkIds = {},
        planSlot = { occupied = false },
    },
    character = {
        characterId = "yoo_jiyoung",
        resistance = 30,
        mood = "ignore",
        traitIds = { "reserved" },
        baseDrawCount = 3,
        maxHandSize = 5,
        planSlot = { occupied = false },
    },
    cardInstances = {
        { instanceId = "prompt-brush", cardId = "accidental_brush", owner = "player", zone = "hand", position = 1 },
        { instanceId = "prompt-warning", cardId = "quiet_warning", owner = "character", zone = "hand", position = 1 },
    },
    selection = { playerCardInstanceIds = {} },
    characterIntent = { cardInstanceIds = {} },
}

local initialized = assertOk(
    "initialize",
    runScript("prompt-check", "turnInitializer", "prepareTurn", rawState, staticData, {
        turnId = "prompt-runtime-turn-001",
    })
)
local beforeState = initialized.state
local draft = assertOk(
    "register player card",
    runScript(
        "prompt-check",
        "turnDraft",
        "registerCard",
        beforeState,
        staticData,
        initialized.draft,
        "prompt-brush"
    )
).draft
local projection = assertOk(
    "project draft",
    runScript("prompt-check", "turnDraft", "project", beforeState, staticData, draft)
).projection
local pending = assertOk(
    "prepare pending",
    runScript("prompt-check", "battleRuntime", "preparePending", beforeState, staticData, projection)
).pendingTurn

local pendingSnapshot = canonical(pending)
local staticSnapshot = canonical(staticData)
local formatted = assertOk(
    "format pending",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", pending, staticData)
)
assert(canonical(pending) == pendingSnapshot, "formatter mutated pendingTurn")
assert(canonical(staticData) == staticSnapshot, "formatter mutated staticData")
assert(hostWriteCalls == 0, "formatter attempted a host write")

assert(type(formatted.message) == "table", "formatter message missing")
for key in pairs(formatted.message) do
    assert(key == "role" or key == "content", "formatter message has an extra field")
end
assert(formatted.message.role == "system", "formatter message role changed")
assert(type(formatted.message.content) == "string", "formatter content missing")
local expectedMarker = "[전투 턴 1] 이번 턴에 실제로 벌어진 일을 하나의 장면으로 이어서 묘사한다."
if formatted.publicMarker ~= expectedMarker then
    local difference = 0
    for index = 1, math.max(#formatted.publicMarker, #expectedMarker) do
        if string.byte(formatted.publicMarker, index) ~= string.byte(expectedMarker, index) then
            difference = index
            break
        end
    end
    error("public marker changed: actualBytes=" .. tostring(#formatted.publicMarker)
        .. " expectedBytes=" .. tostring(#expectedMarker) .. " difference=" .. tostring(difference))
end

local content = formatted.message.content
local requiredText = {
    "[전투 사건 전달]",
    "기존 프리셋의 문체, 시점, 인물 표현과 응답 형식을 그대로 유지하십시오.",
    "사건의 순서, 행동 주체, 수치 변화, 무드와 승패를 바꾸거나 다시 판정하지 마십시오.",
    "열차가 흔들리는 순간에 맞춰 우연인 듯 움직인다.",
    "시선을 피한 채 작은 목소리로 그만두라고 말한다.",
    "크게 말하고 싶진 않지만, 멈추게 해야 해...",
}
for _, needle in ipairs(requiredText) do
    assert(string.find(content, needle, 1, true), "formatted prompt omitted required text: " .. needle)
end

local forbiddenText = {
    "prompt-runtime",
    "prompt-brush",
    "prompt-warning",
    "battleId",
    "turnId",
    "eventId",
    "resolutionId",
    "instanceId",
    "selectedCards",
    "projectionReceipt",
    "beforeState",
    "afterState",
    "accidental_brush",
    "quiet_warning",
    "privateProfile",
    "섹스를 야동으로만 접함",
    "자위 때 사용한 딱풀",
}
for _, needle in ipairs(forbiddenText) do
    assert(not string.find(content, needle, 1, true), "formatted prompt leaked forbidden text: " .. needle)
end

local wrapped = assertOk(
    "wrapped static data",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", pending, staticReport)
)
assert(canonical(wrapped) == canonical(formatted), "static data wrapper changed the prompt")

local function rebuildPending(label, mutate)
    local spec = {
        battleId = pending.battleId,
        turnId = pending.turnId,
        beforeState = clone(pending.beforeState),
        projectionReceipt = clone(pending.projectionReceipt),
        selectedCards = clone(pending.selectedCards),
        turnResult = clone(pending.turnResult),
        afterState = clone(pending.afterState),
    }
    mutate(spec.turnResult.llmEvent)
    return assertOk(label, runScript("prompt-check", "stateSchema", "newPendingTurn", spec, staticData)).value
end

local canaryField = rebuildPending("seal canary field", function(llmEvent)
    llmEvent.events[1].payload.turnId = "prompt-canary"
end)
assertFails(
    "reject payload canary",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", canaryField, staticData),
    "unexpected_field"
)

local eventCanary = rebuildPending("seal event canary", function(llmEvent)
    llmEvent.events[1].debug = true
end)
assertFails(
    "reject event canary",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", eventCanary, staticData),
    "unexpected_field"
)

local unknownEvent = rebuildPending("seal unknown event", function(llmEvent)
    llmEvent.events[3].type = "future_event"
end)
assertFails(
    "reject unknown event",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", unknownEvent, staticData),
    "unknown_llm_event"
)

local badNarration = rebuildPending("seal bad narration", function(llmEvent)
    for _, event in ipairs(llmEvent.events) do
        if event.type == "action" then
            event.payload.actorAction = "CANARY NARRATION"
            return
        end
    end
    error("test pending has no action event")
end)
assertFails(
    "reject forged narration",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", badNarration, staticData),
    "invalid_action_narration"
)

local badEffect = rebuildPending("seal bad effect", function(llmEvent)
    for _, event in ipairs(llmEvent.events) do
        if event.type == "effect_applied" then
            event.payload.op = "future_op"
            return
        end
    end
    error("test pending has no effect event")
end)
assertFails(
    "reject unknown effect op",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", badEffect, staticData),
    "unsupported_effect_op"
)

local duplicateMode = rebuildPending("seal duplicate mode", function(llmEvent)
    table.insert(llmEvent.events, 3, clone(llmEvent.events[1]))
    for index, event in ipairs(llmEvent.events) do event.sequence = index end
end)
assertFails(
    "reject duplicate mode",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", duplicateMode, staticData),
    "duplicate_turn_mode"
)

local brokenIntegrity = clone(pending)
brokenIntegrity.integrity.hashA = brokenIntegrity.integrity.hashA + 1
assertFails(
    "reject broken pending integrity",
    runScript("prompt-check", "turnPromptFormatter", "formatPending", brokenIntegrity, staticData),
    "pending_integrity_mismatch"
)

assertFails(
    "reject unknown formatter action",
    runScript("prompt-check", "turnPromptFormatter", "futureAction", pending, staticData),
    "unknown_action"
)

assert(canonical(pending) == pendingSnapshot, "negative formatter cases mutated pendingTurn")
assert(canonical(staticData) == staticSnapshot, "negative formatter cases mutated staticData")
assert(hostWriteCalls == 0, "negative formatter cases attempted a host write")

local signature = canonical({
    message = formatted.message,
    marker = formatted.publicMarker,
})
print("TURN_PROMPT_FORMATTER|hash=" .. stableHash(signature) .. "|bytes=" .. tostring(#content) .. "|scenarios=10")
'@

Push-Location $projectRoot
$previousOutputEncoding = $OutputEncoding
try {
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[turn-prompt-formatter-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua turn prompt formatter check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua turn prompt formatter check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different prompt formatter results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^TURN_PROMPT_FORMATTER\|hash=\d{10}\|bytes=\d+\|scenarios=10$') {
        throw "Unexpected turn prompt formatter determinism vector: $firstText"
    }

    Write-Output 'turn-prompt-formatter-check: ok'
    Write-Output 'NOTE: RisuAI editRequest insertion, onStart/onOutput hook order, and public marker chat rendering remain untested.'
}
finally {
    $OutputEncoding = $previousOutputEncoding
    Pop-Location
}
