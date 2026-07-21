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
}

local moduleCalls = {}
function runScript(triggerId, name, ...)
    moduleCalls[name] = (moduleCalls[name] or 0) + 1
    local module = assert(modules[name], "unknown module: " .. tostring(name))
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
}

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    if not path then return {} end
    return { { content = readFile(path) } }
end

local function clone(value, active)
    if type(value) ~= "table" then return value end
    active = active or {}
    assert(not active[value], "cycle in test data")
    active[value] = true
    local copy = {}
    for key, item in pairs(value) do
        copy[clone(key, active)] = clone(item, active)
    end
    active[value] = nil
    return copy
end

local function canonical(value, active)
    local valueType = type(value)
    if valueType == "nil" then return "null" end
    if valueType == "boolean" or valueType == "number" then return tostring(value) end
    if valueType == "string" then return string.format("%q", value) end
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
        for index = 1, maximum do
            parts[index] = canonical(value[index], active)
        end
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
    for index = 1, #value do
        hash = (hash * 131 + string.byte(value, index)) % 2147483647
    end
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
    for _, item in ipairs(report.errors or {}) do
        if item.code == expectedCode then return end
    end
    failReport(label .. " (missing " .. tostring(expectedCode) .. ")", report)
end

local function assertJsonSafe(label, value, active)
    local valueType = type(value)
    if valueType == "nil" or valueType == "string" or valueType == "boolean" then return end
    if valueType == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, label .. " has non-finite number")
        return
    end
    assert(valueType == "table" and getmetatable(value) == nil, label .. " is not plain JSON data")
    active = active or {}
    assert(not active[value], label .. " has a cycle")
    active[value] = true
    local numericCount = 0
    local maximum = 0
    local stringCount = 0
    for key, item in pairs(value) do
        if type(key) == "number" then
            assert(key % 1 == 0 and key >= 1, label .. " has invalid array key")
            numericCount = numericCount + 1
            maximum = math.max(maximum, key)
        else
            assert(type(key) == "string", label .. " has invalid object key")
            stringCount = stringCount + 1
        end
        assertJsonSafe(label .. "." .. tostring(key), item, active)
    end
    assert(numericCount == 0 or stringCount == 0, label .. " mixes object and array keys")
    assert(numericCount == 0 or numericCount == maximum, label .. " is sparse")
    active[value] = nil
end

local staticData = assertOk(
    "static load",
    runScript("battle-runtime-check", "staticData", "loadAll")
).data

local function makeCard(instanceId, cardId, owner, zone, position)
    return {
        instanceId = instanceId,
        cardId = cardId,
        owner = owner,
        zone = zone,
        position = position,
    }
end

local function makeState(options)
    options = options or {}
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = assert(options.battleId),
        status = "active",
        turnNumber = 1,
        turnLimit = 10,
        environmentId = "uncrowded",
        rng = { seed = options.seed or 20260718, cursor = 0 },
        player = {
            stealth = options.stealth or 30,
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
            makeCard(options.prefix .. "-brush", "accidental_brush", "player", "hand", 1),
            makeCard(options.prefix .. "-warning", "quiet_warning", "character", "hand", 1),
        },
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local function initialize(label, rawState, turnId)
    return assertOk(
        label,
        runScript(
            "battle-runtime-check",
            "turnInitializer",
            "prepareTurn",
            rawState,
            staticData,
            { turnId = turnId }
        )
    )
end

local rawState = makeState({ battleId = "runtime-battle", prefix = "runtime" })
local initialized = initialize("initialize", rawState, "runtime-battle-turn-001")
local beforeState = initialized.state
local draft = assertOk(
    "register player card",
    runScript(
        "battle-runtime-check",
        "turnDraft",
        "registerCard",
        beforeState,
        staticData,
        initialized.draft,
        "runtime-brush"
    )
).draft
local projection = assertOk(
    "project draft",
    runScript("battle-runtime-check", "turnDraft", "project", beforeState, staticData, draft)
).projection

local beforeSnapshot = canonical(beforeState)
local projectionSnapshot = canonical(projection)
local resolverCallsBefore = moduleCalls.turnResolver or 0
local projectorCallsBefore = moduleCalls.turnEventProjector or 0
local prepared = assertOk(
    "prepare pending",
    runScript("battle-runtime-check", "battleRuntime", "preparePending", beforeState, staticData, projection)
)
assert((moduleCalls.turnResolver or 0) == resolverCallsBefore + 1, "prepare did not call resolver exactly once")
assert((moduleCalls.turnEventProjector or 0) == projectorCallsBefore + 1, "prepare did not call projector exactly once")
assert(canonical(beforeState) == beforeSnapshot, "prepare mutated authority state")
assert(canonical(projection) == projectionSnapshot, "prepare mutated projection")
assert(prepared.reused == false and prepared.turnId == "runtime-battle-turn-001", "prepare result flags changed")

local pending = prepared.pendingTurn
assertJsonSafe("pending", pending)
assert(pending.kind == "pendingTurn" and pending.status == "awaitingOutput", "pending header changed")
assert(canonical(pending.beforeState) == beforeSnapshot, "pending beforeState is not the authority snapshot")
assert(pending.selectedCards.player[1] == "runtime-brush", "pending player selection changed")
assert(pending.selectedCards.character[1] == "runtime-warning", "pending character selection changed")
assert(pending.projectionReceipt.kind == "turnDraftProjectionReceipt", "pending projection receipt missing")
for key in pairs(pending.turnResult) do
    assert(key == "events" or key == "publicResult" or key == "llmEvent", "turnResult leaked resolver audit fields")
end

local sealed = assertOk(
    "direct seal",
    runScript("battle-runtime-check", "turnDraft", "sealProjection", beforeState, staticData, projection)
)
local directResolution = assertOk(
    "direct resolve",
    runScript(
        "battle-runtime-check",
        "turnResolver",
        "resolveTurn",
        beforeState,
        staticData,
        sealed.projection,
        { turnId = beforeState.turnStartReceipt.turnId }
    )
).resolution
local directProjection = assertOk(
    "direct event projection",
    runScript("battle-runtime-check", "turnEventProjector", "projectTurn", beforeState, staticData, directResolution)
)
assert(canonical(pending.projectionReceipt) == canonical(sealed.receipt), "runtime changed the projection receipt")
assert(canonical(pending.turnResult.events) == canonical(directResolution.events), "runtime changed resolver events")
assert(canonical(pending.turnResult.publicResult) == canonical(directProjection.publicResult), "runtime changed public projection")
assert(canonical(pending.turnResult.llmEvent) == canonical(directProjection.llmEvent), "runtime changed LLM projection")
assert(canonical(pending.afterState) == canonical(directResolution.afterState), "runtime changed afterState")

local preparedAgain = assertOk(
    "deterministic prepare",
    runScript("battle-runtime-check", "battleRuntime", "preparePending", beforeState, staticData, projection)
)
assert(canonical(preparedAgain.pendingTurn) == canonical(pending), "same projection produced another pending result")
preparedAgain.pendingTurn.beforeState.player.stealth = -999
assert(canonical(beforeState) == beforeSnapshot, "prepared output aliases authority state")
assert(canonical(pending.beforeState) == beforeSnapshot, "separate prepare results alias each other")

local resolverCallsBeforeReuse = moduleCalls.turnResolver or 0
local projectorCallsBeforeReuse = moduleCalls.turnEventProjector or 0
local reused = assertOk(
    "reuse pending",
    runScript("battle-runtime-check", "battleRuntime", "reusePending", beforeState, staticData, pending)
)
assert(reused.reused == true and reused.turnId == pending.turnId, "reuse result flags changed")
assert(canonical(reused.pendingTurn) == canonical(pending), "reuse changed stored pending")
assert((moduleCalls.turnResolver or 0) == resolverCallsBeforeReuse, "reuse reran resolver")
assert((moduleCalls.turnEventProjector or 0) == projectorCallsBeforeReuse, "reuse reran projector")
reused.pendingTurn.afterState.player.stealth = -999
assert(canonical(pending.afterState) == canonical(directResolution.afterState), "reuse output aliases stored pending")

local wrappedStaticPrepare = assertOk(
    "wrapped static prepare",
    runScript("battle-runtime-check", "battleRuntime", "preparePending", beforeState, { data = staticData }, projection)
)
assert(canonical(wrappedStaticPrepare.pendingTurn) == canonical(pending), "static data wrapper changed pending")

local tamperedReceipt = clone(pending)
tamperedReceipt.projectionReceipt.mode = "chain_pass"
assertFails(
    "tampered receipt reuse",
    runScript("battle-runtime-check", "battleRuntime", "reusePending", beforeState, staticData, tamperedReceipt),
    "pending_integrity_mismatch"
)
local resealedSemanticTamper = assertOk(
    "reseal semantic receipt tamper",
    runScript("battle-runtime-check", "stateSchema", "newPendingTurn", tamperedReceipt, staticData)
).value
assertFails(
    "resealed semantic receipt reuse",
    runScript("battle-runtime-check", "battleRuntime", "reusePending", beforeState, staticData, resealedSemanticTamper),
    "projection_receipt_mismatch"
)

local tamperedAfterState = clone(pending)
tamperedAfterState.afterState.player.stealth = tamperedAfterState.afterState.player.stealth + 1
assertFails(
    "tampered afterState commit",
    runScript("battle-runtime-check", "battleRuntime", "commitPending", beforeState, staticData, tamperedAfterState),
    "pending_integrity_mismatch"
)

local tamperedLlmEvent = clone(pending)
tamperedLlmEvent.turnResult.llmEvent.events[1].type = "tampered_event"
assertFails(
    "tampered LLM event reuse",
    runScript("battle-runtime-check", "battleRuntime", "reusePending", beforeState, staticData, tamperedLlmEvent),
    "pending_integrity_mismatch"
)

local malformedPending = clone(pending)
malformedPending.turnResult.extra = true
assertFails(
    "malformed pending reuse",
    runScript("battle-runtime-check", "battleRuntime", "reusePending", beforeState, staticData, malformedPending),
    "unknown_field"
)

local realProjector = modules.turnEventProjector
modules.turnEventProjector = function()
    return {
        ok = false,
        schemaVersion = 1,
        errors = {
            { code = "forced_projection_failure", path = "$", message = "forced projector failure" },
        },
    }
end
local forcedFailure = runScript(
    "battle-runtime-check",
    "battleRuntime",
    "preparePending",
    beforeState,
    staticData,
    projection
)
modules.turnEventProjector = realProjector
assertFails("projector failure propagation", forcedFailure, "forced_projection_failure")
assert(canonical(beforeState) == beforeSnapshot and canonical(projection) == projectionSnapshot,
    "failed prepare mutated its inputs")

local alternateRaw = makeState({
    battleId = "runtime-battle",
    prefix = "runtime",
    stealth = 31,
})
local alternateBefore = initialize(
    "alternate initialize",
    alternateRaw,
    "runtime-battle-turn-001"
).state
assertFails(
    "stale projection prepare",
    runScript("battle-runtime-check", "battleRuntime", "preparePending", alternateBefore, staticData, projection),
    "projection_stale"
)
assertFails(
    "conflicting pending reuse",
    runScript("battle-runtime-check", "battleRuntime", "reusePending", alternateBefore, staticData, pending),
    "pending_authority_conflict"
)

local commit = assertOk(
    "commit pending",
    runScript("battle-runtime-check", "battleRuntime", "commitPending", beforeState, staticData, pending)
)
assert(commit.applied == true and commit.turnId == pending.turnId, "first commit was not applied")
assert(canonical(commit.state) == canonical(pending.afterState), "first commit did not return afterState")
assert(canonical(beforeState) == beforeSnapshot, "commit mutated current authority state")
commit.state.player.stealth = -999
assert(canonical(pending.afterState) == canonical(directResolution.afterState), "commit output aliases pending afterState")

local committedState = clone(pending.afterState)
local secondCommit = assertOk(
    "idempotent commit",
    runScript("battle-runtime-check", "battleRuntime", "commitPending", committedState, staticData, pending)
)
assert(secondCommit.applied == false, "second commit applied the turn twice")
assert(canonical(secondCommit.state) == canonical(committedState), "second commit changed current authority state")

local nextInitialized = initialize(
    "next turn initialize",
    committedState,
    "runtime-battle-turn-002"
).state
local nextSnapshot = canonical(nextInitialized)
local lateCommit = assertOk(
    "late duplicate output commit",
    runScript("battle-runtime-check", "battleRuntime", "commitPending", nextInitialized, staticData, pending)
)
assert(lateCommit.applied == false, "late duplicate output reapplied an old pending turn")
assert(canonical(lateCommit.state) == nextSnapshot, "late duplicate output rolled back the next initialized turn")
local regenerated = assertOk(
    "reuse committed pending",
    runScript("battle-runtime-check", "battleRuntime", "reusePending", nextInitialized, staticData, pending)
)
assert(regenerated.reused == true and canonical(regenerated.pendingTurn) == canonical(pending),
    "output regeneration did not reuse the committed turn result")

assertFails(
    "conflicting commit",
    runScript("battle-runtime-check", "battleRuntime", "commitPending", alternateBefore, staticData, pending),
    "pending_authority_conflict"
)

local otherBefore = initialize(
    "other battle initialize",
    makeState({ battleId = "runtime-other", prefix = "other" }),
    "runtime-other-turn-001"
).state
assertFails(
    "other battle commit",
    runScript("battle-runtime-check", "battleRuntime", "commitPending", otherBefore, staticData, pending),
    "pending_battle_mismatch"
)

assertFails(
    "prepare without initializer",
    runScript("battle-runtime-check", "battleRuntime", "preparePending", rawState, staticData, projection),
    "missing_turn_start_receipt"
)
assertFails(
    "unknown runtime action",
    runScript("battle-runtime-check", "battleRuntime", "notAnAction", beforeState, staticData, projection),
    "unknown_action"
)

local signature = canonical({
    pending = pending,
    firstCommit = {
        turnId = pending.turnId,
        state = pending.afterState,
        applied = true,
    },
    lateState = nextInitialized,
})
print("BATTLE_RUNTIME|hash=" .. stableHash(signature) .. "|scenarios=18")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[battle-runtime-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua battle runtime check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua battle runtime check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different battle runtime results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^BATTLE_RUNTIME\|hash=\d{10}\|scenarios=18$') {
        throw "Unexpected battle runtime determinism vector: $firstText"
    }

    Write-Output 'battle-runtime-check: ok'
    Write-Output 'NOTE: persistent chat-variable storage, RisuAI hooks, prompt assembly, and UI replacement remain untested.'
}
finally {
    Pop-Location
}
