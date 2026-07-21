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
    turnPresentation = loadLore("System/turnPresentation.lua"),
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

local hostWrites = 0
local function rejectHostWrite(name)
    return function()
        hostWrites = hostWrites + 1
        error("unexpected host write: " .. name)
    end
end
setState = rejectHostWrite("setState")
setChatVar = rejectHostWrite("setChatVar")
setFullChat = rejectHostWrite("setFullChat")
addChat = rejectHostWrite("addChat")
upsertLocalLoreBook = rejectHostWrite("upsertLocalLoreBook")

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

local function failReport(label, report)
    local messages = {}
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path) .. ": " .. tostring(item.message)
    end
    error(label .. " failed\n" .. table.concat(messages, "\n"))
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then failReport(label, report) end
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    return report
end

local function assertFails(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.lastTurn == nil, label .. " exposed a lastTurn on failure")
    if expectedCode then
        for _, item in ipairs(report.errors or {}) do
            if item.code == expectedCode then return report end
        end
        failReport(label .. " (missing " .. expectedCode .. ")", report)
    end
    return report
end

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
    local playerCardId = options.playerCardId or "accidental_brush"
    local characterCardId = options.characterCardId or "quiet_warning"
    local cards = {}
    if playerCardId then
        cards[#cards + 1] = makeCard(options.prefix .. "-player", playerCardId, "player", "hand", 1)
    end
    if options.hiddenPlan then
        cards[#cards + 1] = makeCard(options.prefix .. "-old-plan", "silent_glare", "character", "plan", 1)
    end
    if characterCardId then
        cards[#cards + 1] = makeCard(options.prefix .. "-character", characterCardId, "character", "hand", 1)
    end
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = options.battleId,
        status = "active",
        turnNumber = options.turnNumber or 1,
        turnLimit = 10,
        environmentId = "uncrowded",
        rng = { seed = options.seed or 20260719, cursor = 0 },
        player = {
            stealth = 30,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = {},
            planSlot = { occupied = false },
        },
        character = {
            characterId = "yoo_jiyoung",
            resistance = options.resistance or 30,
            mood = "ignore",
            traitIds = { "reserved" },
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = options.hiddenPlan and {
                occupied = true,
                cardInstanceId = options.prefix .. "-old-plan",
                cardId = "silent_glare",
                placedTurn = options.planPlacedTurn or 1,
                remainingTurns = 1,
                remainingCharges = 1,
                revealed = false,
            } or { occupied = false },
        },
        cardInstances = cards,
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local staticData = assertOk(
    "static load",
    runScript("turn-presentation-check", "staticData", "loadAll")
).data

local CHARACTER_CANARY = "CHARACTER_PRIVATE_CANARY_8B31"
local THOUGHT_CANARY = "THOUGHT_PRIVATE_CANARY_2D74"
staticData.cards.quiet_warning.name = CHARACTER_CANARY
staticData.cards.quiet_warning.narration.play.actorThought = THOUGHT_CANARY
staticData.cards.silent_glare.name = CHARACTER_CANARY .. "_PLAN"
staticData.characters.yoo_jiyoung.privateProfile.canary = "PROFILE_PRIVATE_CANARY_17A0"
local staticPresentationSnapshot = canonical({
    playerCardName = staticData.cards.accidental_brush.name,
    characterCardName = staticData.cards.quiet_warning.name,
    characterThought = staticData.cards.quiet_warning.narration.play.actorThought,
    actionLabel = staticData.registry.actionTags.vigilance.label,
    moodLabel = staticData.registry.moods.ignore.label,
    privateCanary = staticData.characters.yoo_jiyoung.privateProfile.canary,
})

local absent = assertOk(
    "absent presentation",
    runScript("turn-presentation-check", "turnPresentation", "build", nil, nil)
)
assert(canonical(absent.lastTurn) == canonical({ available = false }), "absent result shape changed")

local function preparePending(label, options, registerPlayer)
    local raw = makeState(options)
    local initialized = assertOk(
        label .. " initialize",
        runScript(
            "turn-presentation-check",
            "turnInitializer",
            "prepareTurn",
            raw,
            staticData,
            { turnId = options.battleId .. "-turn-" .. string.format("%03d", options.turnNumber or 1) }
        )
    )
    local draft = initialized.draft
    if registerPlayer then
        draft = assertOk(
            label .. " register",
            runScript(
                "turn-presentation-check",
                "turnDraft",
                "registerCard",
                initialized.state,
                staticData,
                draft,
                options.prefix .. "-player"
            )
        ).draft
    end
    local projection = assertOk(
        label .. " project",
        runScript("turn-presentation-check", "turnDraft", "project", initialized.state, staticData, draft)
    ).projection
    local pending = assertOk(
        label .. " pending",
        runScript("turn-presentation-check", "battleRuntime", "preparePending", initialized.state, staticData, projection)
    ).pendingTurn
    local committed = assertOk(
        label .. " commit",
        runScript("turn-presentation-check", "battleRuntime", "commitPending", initialized.state, staticData, pending)
    )
    assert(committed.state.lastCommittedTurnId == pending.turnId, label .. " did not commit")
    return pending, committed.state
end

local activePending, activeState = preparePending("active", {
    battleId = "presentation-active",
    prefix = "active",
    playerCardId = "accidental_brush",
    characterCardId = "quiet_warning",
    resistance = 30,
}, true)
assert(activeState.status == "active", "active fixture unexpectedly ended")

local activeSnapshot = canonical(activePending)
local activePresentation = assertOk(
    "active presentation",
    runScript("turn-presentation-check", "turnPresentation", "build", activePending, { data = staticData })
)
assert(canonical(activePending) == activeSnapshot, "presentation mutated active pending")
assert(activePresentation.lastTurn.available == true, "active presentation unavailable")
assert(activePresentation.lastTurn.turnNumber == 1, "active turn number changed")
assert(#activePresentation.lastTurn.summaries > 0, "active summaries missing")

local activeText = {}
local sawCharacterIntent = false
local sawPlayerCardName = false
for index, item in ipairs(activePresentation.lastTurn.summaries) do
    local keyCount = 0
    for key in pairs(item) do
        assert(key == "sequence" or key == "type" or key == "text", "summary leaked an unexpected field")
        keyCount = keyCount + 1
    end
    assert(keyCount == 3, "summary field count changed")
    assert(item.sequence == index and type(item.type) == "string" and type(item.text) == "string" and item.text ~= "", "summary shape invalid")
    activeText[#activeText + 1] = item.text
    if item.type == "character_intent" then sawCharacterIntent = true end
    if string.find(item.text, staticData.cards.accidental_brush.name, 1, true) then sawPlayerCardName = true end
end
local joinedActive = table.concat(activeText, "\n")
assert(sawCharacterIntent, "character intent summary missing")
assert(sawPlayerCardName, "public player DB name was not used")
for _, canary in ipairs({ CHARACTER_CANARY, THOUGHT_CANARY, "PROFILE_PRIVATE_CANARY_17A0", "quiet_warning", "active-character" }) do
    assert(not string.find(joinedActive, canary, 1, true), "private character data leaked: " .. canary)
end
assert(not string.find(canonical(activePresentation), "actorThought", 1, true), "LLM-only field leaked")

local terminalPending, terminalState = preparePending("terminal", {
    battleId = "presentation-terminal",
    prefix = "terminal",
    playerCardId = "accidental_brush",
    characterCardId = "quiet_warning",
    resistance = 3,
}, true)
assert(terminalState.status == "victory", "terminal fixture did not end in victory")
local terminalPresentation = assertOk(
    "terminal presentation",
    runScript("turn-presentation-check", "turnPresentation", "build", terminalPending, staticData)
)
local terminalTypes = {}
for _, item in ipairs(terminalPresentation.lastTurn.summaries) do terminalTypes[item.type] = true end
assert(terminalTypes.outcome and terminalTypes.session_ended, "terminal public events missing")
assert(terminalTypes.mood_evaluated and terminalTypes.turn_ended, "terminal cleanup summaries missing")

local hiddenPlacedPending = preparePending("hidden placed", {
    battleId = "presentation-hidden-placed",
    prefix = "hidden-placed",
    playerCardId = nil,
    characterCardId = "silent_glare",
}, false)
local hiddenPlaced = assertOk(
    "hidden placed presentation",
    runScript("turn-presentation-check", "turnPresentation", "build", hiddenPlacedPending, staticData)
)
local hiddenPlacedText = canonical(hiddenPlaced)
assert(string.find(hiddenPlacedText, "plan_changed", 1, true), "hidden placed plan summary missing")
assert(not string.find(hiddenPlacedText, CHARACTER_CANARY, 1, true), "hidden placed plan name leaked")
assert(not string.find(hiddenPlacedText, "silent_glare", 1, true), "hidden placed plan id leaked")

local hiddenReplacedPending = preparePending("hidden replaced", {
    battleId = "presentation-hidden-replaced",
    prefix = "hidden-replaced",
    playerCardId = nil,
    characterCardId = "silent_glare",
    hiddenPlan = true,
    turnNumber = 2,
    planPlacedTurn = 1,
}, false)
local hiddenReplaced = assertOk(
    "hidden replaced presentation",
    runScript("turn-presentation-check", "turnPresentation", "build", hiddenReplacedPending, staticData)
)
local hiddenReplacedText = canonical(hiddenReplaced)
assert(string.find(hiddenReplacedText, "교체", 1, true), "hidden replaced plan summary missing")
assert(string.find(hiddenReplacedText, "배치", 1, true), "replacement plan placement summary missing")
assert(not string.find(hiddenReplacedText, CHARACTER_CANARY, 1, true), "hidden replaced plan name leaked")
assert(not string.find(hiddenReplacedText, "silent_glare", 1, true), "hidden replaced plan id leaked")

local hiddenExpiredPending = preparePending("hidden expired", {
    battleId = "presentation-hidden-expired",
    prefix = "hidden-expired",
    playerCardId = nil,
    characterCardId = nil,
    hiddenPlan = true,
    turnNumber = 2,
    planPlacedTurn = 1,
}, false)
local hiddenExpired = assertOk(
    "hidden expired presentation",
    runScript("turn-presentation-check", "turnPresentation", "build", hiddenExpiredPending, staticData)
)
local hiddenExpiredText = canonical(hiddenExpired)
assert(string.find(hiddenExpiredText, "plan_changed", 1, true), "hidden expired plan summary missing")
assert(not string.find(hiddenExpiredText, CHARACTER_CANARY, 1, true), "hidden expired plan name leaked")
assert(not string.find(hiddenExpiredText, "silent_glare", 1, true), "hidden expired plan id leaked")

local function reseal(spec)
    spec.integrity = nil
    return assertOk(
        "reseal fixture",
        runScript("turn-presentation-check", "stateSchema", "newPendingTurn", spec, staticData)
    ).value
end

local activeTerminalSpec = clone(activePending)
local activeTerminalEvents = activeTerminalSpec.turnResult.publicResult.events
activeTerminalEvents[#activeTerminalEvents + 1] = {
    sequence = #activeTerminalEvents + 1,
    type = "outcome",
    payload = {
        status = "victory",
        reasonCode = "card_checkpoint",
        stealth = 30,
        resistance = 0,
    },
}
activeTerminalEvents[#activeTerminalEvents + 1] = {
    sequence = #activeTerminalEvents + 1,
    type = "session_ended",
    payload = { status = "victory" },
}
local activeTerminalPending = reseal(activeTerminalSpec)
assertFails(
    "active state with terminal events",
    runScript("turn-presentation-check", "turnPresentation", "build", activeTerminalPending, staticData),
    "active_turn_has_terminal_event"
)

local terminalWithoutEventsSpec = clone(terminalPending)
local terminalWithoutEvents = {}
for _, event in ipairs(terminalWithoutEventsSpec.turnResult.publicResult.events) do
    if event.type ~= "outcome" and event.type ~= "session_ended" then
        event.sequence = #terminalWithoutEvents + 1
        terminalWithoutEvents[#terminalWithoutEvents + 1] = event
    end
end
terminalWithoutEventsSpec.turnResult.publicResult.events = terminalWithoutEvents
local terminalWithoutEventsPending = reseal(terminalWithoutEventsSpec)
assertFails(
    "terminal state without terminal events",
    runScript("turn-presentation-check", "turnPresentation", "build", terminalWithoutEventsPending, staticData),
    "terminal_state_event_mismatch"
)

local llmFieldSpec = clone(activePending)
for _, event in ipairs(llmFieldSpec.turnResult.publicResult.events) do
    if event.type == "character_intent" then
        event.payload.actorThought = THOUGHT_CANARY
        break
    end
end
local llmFieldPending = reseal(llmFieldSpec)
local llmFieldSnapshot = canonical(llmFieldPending)
local llmFieldFailure = assertFails(
    "LLM-only public field",
    runScript("turn-presentation-check", "turnPresentation", "build", llmFieldPending, staticData),
    "unexpected_field"
)
assert(canonical(llmFieldPending) == llmFieldSnapshot, "failure path mutated pending")
assert(not string.find(canonical(llmFieldFailure), THOUGHT_CANARY, 1, true), "failure error leaked private canary")

local unknownSpec = clone(activePending)
unknownSpec.turnResult.publicResult.events[1] = {
    sequence = 1,
    type = "private_event",
    payload = { canary = THOUGHT_CANARY },
}
local unknownPending = reseal(unknownSpec)
local unknownFailure = assertFails(
    "unknown public event",
    runScript("turn-presentation-check", "turnPresentation", "build", unknownPending, staticData),
    "unknown_public_event"
)
assert(not string.find(canonical(unknownFailure), THOUGHT_CANARY, 1, true), "unknown event error leaked canary")

local hiddenTriggerSpec = clone(activePending)
local planIndex = #hiddenTriggerSpec.turnResult.publicResult.events + 1
hiddenTriggerSpec.turnResult.publicResult.events[planIndex] = {
    sequence = planIndex,
    type = "plan_changed",
    payload = {
        side = "character",
        action = "triggered",
        identityKnown = false,
    },
}
local hiddenTriggerPending = reseal(hiddenTriggerSpec)
assertFails(
    "hidden triggered plan",
    runScript("turn-presentation-check", "turnPresentation", "build", hiddenTriggerPending, staticData),
    "invalid_plan_change"
)

assertFails(
    "unknown action",
    runScript("turn-presentation-check", "turnPresentation", "unknown", activePending, staticData),
    "unknown_action"
)
assert(canonical({
    playerCardName = staticData.cards.accidental_brush.name,
    characterCardName = staticData.cards.quiet_warning.name,
    characterThought = staticData.cards.quiet_warning.narration.play.actorThought,
    actionLabel = staticData.registry.actionTags.vigilance.label,
    moodLabel = staticData.registry.moods.ignore.label,
    privateCanary = staticData.characters.yoo_jiyoung.privateProfile.canary,
}) == staticPresentationSnapshot, "presentation mutated static data")
assert(hostWrites == 0, "turn presentation attempted host writes")

print("turn-presentation-check: ok")
'@

$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("turn-presentation-check-{0}.lua" -f [guid]::NewGuid())
try {
    Set-Content -LiteralPath $tempFile -Value $luaTest -Encoding UTF8
    Push-Location $projectRoot
    try {
        & $luaHost $tempFile
        if ($LASTEXITCODE -ne 0) {
            throw "Lua turn presentation check failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
}
