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
    turnDraft = loadLore("System/turnDraft.lua"),
    triggerPipeline = loadLore("System/triggerPipeline.lua"),
    characterSelector = loadLore("System/characterSelector.lua"),
    turnInitializer = loadLore("System/turnInitializer.lua"),
    turnResolver = loadLore("System/turnResolver.lua"),
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
    if not path then
        return {}
    end
    return { { content = readFile(path) } }
end

local function clone(value, active)
    if type(value) ~= "table" then
        return value
    end
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
    if valueType == "nil" then
        return "null"
    end
    if valueType == "boolean" or valueType == "number" then
        return tostring(value)
    end
    if valueType == "string" then
        return string.format("%q", value)
    end
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
    error(label .. " failed\n" .. table.concat(messages, "\n"))
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        failReport(label, report)
    end
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
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

local function initialState()
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "multi-turn-battle",
        status = "active",
        turnNumber = 1,
        turnLimit = 20,
        environmentId = "uncrowded",
        rng = { seed = 20260717, cursor = 0 },
        player = {
            stealth = 100,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = {},
            planSlot = { occupied = false },
        },
        character = {
            characterId = "yoo_jiyoung",
            resistance = 100,
            mood = "ignore",
            traitIds = { "reserved" },
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = { occupied = false },
        },
        cardInstances = {
            makeCard("player-001", "subtle_approach", "player", "deck", 1),
            makeCard("player-002", "accidental_brush", "player", "deck", 2),
            makeCard("player-003", "play_it_cool", "player", "deck", 3),
            makeCard("player-004", "read_the_room", "player", "deck", 4),
            makeCard("player-005", "pin_down", "player", "deck", 5),
            makeCard("player-006", "hypnotic_whisper", "player", "deck", 6),
            makeCard("character-001", "close_collar", "character", "deck", 1),
            makeCard("character-002", "quiet_warning", "character", "deck", 2),
            makeCard("character-003", "turn_to_corner", "character", "deck", 3),
            makeCard("character-004", "silent_glare", "character", "deck", 4),
        },
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local staticData = assertOk(
    "static load",
    runScript("multi-turn-check", "staticData", "loadAll")
).data

local function inventory(state)
    assert(type(state.cardInstances) == "table", "cardInstances missing")
    local result = {}
    local seen = {}
    for _, instance in ipairs(state.cardInstances) do
        assert(not seen[instance.instanceId], "duplicate card instance: " .. tostring(instance.instanceId))
        seen[instance.instanceId] = true
        result[#result + 1] = instance.instanceId .. "|" .. instance.cardId .. "|" .. instance.owner
    end
    table.sort(result)
    return result
end

local function assertInventory(label, state, expected)
    local actual = inventory(state)
    assert(#actual == 10, label .. " card instance count changed: " .. tostring(#actual))
    assert(#actual == #expected, label .. " inventory length changed")
    for index, expectedItem in ipairs(expected) do
        assert(actual[index] == expectedItem, label .. " inventory changed at " .. index)
    end
end

local function assertState(label, state)
    local report = assertOk(
        label,
        runScript("multi-turn-check", "stateSchema", "validateBattleState", state, staticData)
    )
    assert(report.referencesValidated == true, label .. " did not validate static references")
end

local function assertConservation(label, beforeState, afterState)
    assertOk(
        label,
        runScript("multi-turn-check", "cardZones", "validateConservation", beforeState, afterState)
    )
end

local function assertDraft(label, state, draft)
    local stateSnapshot = canonical(state)
    local draftSnapshot = canonical(draft)
    assertOk(
        label,
        runScript("multi-turn-check", "turnDraft", "validate", state, staticData, draft, nil)
    )
    assert(canonical(state) == stateSnapshot, label .. " mutated state")
    assert(canonical(draft) == draftSnapshot, label .. " mutated draft")
end

local function assertProjection(label, state, projection)
    local stateSnapshot = canonical(state)
    local projectionSnapshot = canonical(projection)
    local report = assertOk(
        label,
        runScript("multi-turn-check", "turnDraft", "validateProjection", state, staticData, projection, nil)
    )
    assert(canonical(report.projection) == projectionSnapshot, label .. " returned a different projection")
    assert(canonical(state) == stateSnapshot, label .. " mutated state")
    assert(canonical(projection) == projectionSnapshot, label .. " mutated projection")
end

local function assertEventIds(label, events, turnId)
    assert(type(events) == "table" and #events > 0, label .. " events missing")
    for index, event in ipairs(events) do
        assert(event.sequence == index, label .. " event sequence changed at " .. index)
        local expectedId = turnId .. "-event-" .. string.format("%03d", index)
        assert(event.eventId == expectedId,
            label .. " expected " .. expectedId .. ", got " .. tostring(event.eventId))
    end
end

local function assertReceiptPrefix(label, receiptEvents, resolutionEvents)
    assert(#resolutionEvents >= #receiptEvents, label .. " lost initializer events")
    for index, receiptEvent in ipairs(receiptEvents) do
        assert(canonical(resolutionEvents[index]) == canonical(receiptEvent),
            label .. " changed initializer event " .. index)
    end
end

local function simulate(inputState, label)
    local originalSnapshot = canonical(inputState)
    local state = clone(inputState)
    local expectedInventory = inventory(inputState)
    local trace = {
        initialState = clone(inputState),
        turns = {},
    }

    for turn = 1, 10 do
        local turnLabel = label .. " turn " .. turn
        local turnId = "multi-turn-battle-turn-" .. string.format("%03d", turn)
        assert(state.status == "active", turnLabel .. " did not start active")
        assert(state.turnNumber == turn, turnLabel .. " started at wrong turn number")
        assert(state.turnStartReceipt == nil, turnLabel .. " retained the previous receipt")
        assert(#state.selection.playerCardInstanceIds == 0, turnLabel .. " retained player selection")
        assert(#state.characterIntent.cardInstanceIds == 0, turnLabel .. " retained character intent")
        assertState(turnLabel .. " before state", state)
        assertInventory(turnLabel .. " before", state, expectedInventory)

        local beforeState = state
        local beforeSnapshot = canonical(beforeState)
        local initialized = assertOk(
            turnLabel .. " initialize",
            runScript(
                "multi-turn-check",
                "turnInitializer",
                "prepareTurn",
                beforeState,
                staticData,
                { turnId = turnId }
            )
        )
        assert(canonical(beforeState) == beforeSnapshot, turnLabel .. " initializer mutated authority")
        assert(initialized.reused == false, turnLabel .. " unexpectedly reused initialization")
        local initializedState = initialized.state
        local receipt = initializedState.turnStartReceipt
        assert(type(receipt) == "table", turnLabel .. " receipt missing")
        assert(canonical(receipt) == canonical(initialized.receipt), turnLabel .. " receipt output diverged from state")
        assert(receipt.turnId == turnId and receipt.turnNumber == turn, turnLabel .. " receipt identity changed")
        assert(type(receipt.authorityFingerprint) == "table"
                and receipt.authorityFingerprint.algorithm == "canonical_poly131_137_receipt_v2",
            turnLabel .. " authority fingerprint missing")
        assert(canonical(receipt.draws) == canonical(initialized.draws), turnLabel .. " draw audit changed")
        assert(canonical(receipt.characterSelection) == canonical(initialized.characterSelection),
            turnLabel .. " character selection audit changed")
        assertEventIds(turnLabel .. " initializer", receipt.events, turnId)
        assertState(turnLabel .. " initialized state", initializedState)
        assertInventory(turnLabel .. " initialized", initializedState, expectedInventory)
        assertConservation(turnLabel .. " initialization conservation", beforeState, initializedState)
        assertDraft(turnLabel .. " draft", initializedState, initialized.draft)
        assert(#initialized.draft.registeredCardInstanceIds == 0, turnLabel .. " draft was not a pass draft")

        local initializedSnapshot = canonical(initializedState)
        local draftSnapshot = canonical(initialized.draft)
        local projectReport = assertOk(
            turnLabel .. " project pass",
            runScript(
                "multi-turn-check",
                "turnDraft",
                "project",
                initializedState,
                staticData,
                initialized.draft,
                nil
            )
        )
        assert(canonical(initializedState) == initializedSnapshot, turnLabel .. " projection mutated authority")
        assert(canonical(initialized.draft) == draftSnapshot, turnLabel .. " projection mutated draft")
        local projection = projectReport.projection
        assert(projection.mode == "pass", turnLabel .. " projection mode was not pass")
        assert(projection.hasMainAction == false and projection.passAfterChain == false,
            turnLabel .. " pass projection flags changed")
        assert(#projection.selectedCardInstanceIds == 0, turnLabel .. " pass projection selected a card")
        assert(type(projection.workingState.turnStartReceipt) == "table",
            turnLabel .. " projection lost turnStartReceipt")
        assertState(turnLabel .. " projection state", projection.workingState)
        assertInventory(turnLabel .. " projection", projection.workingState, expectedInventory)
        assertConservation(turnLabel .. " projection conservation", initializedState, projection.workingState)
        assertProjection(turnLabel .. " projection validation", initializedState, projection)

        local authoritySnapshot = canonical(initializedState)
        local projectionSnapshot = canonical(projection)
        local resolved = assertOk(
            turnLabel .. " resolve",
            runScript(
                "multi-turn-check",
                "turnResolver",
                "resolveTurn",
                initializedState,
                staticData,
                projection,
                { turnId = turnId }
            )
        )
        assert(canonical(initializedState) == authoritySnapshot, turnLabel .. " resolver mutated authority")
        assert(canonical(projection) == projectionSnapshot, turnLabel .. " resolver mutated projection")
        local resolution = resolved.resolution
        assertEventIds(turnLabel .. " resolution", resolution.events, turnId)
        assertReceiptPrefix(turnLabel, receipt.events, resolution.events)
        assert(resolution.turnNumber == turn, turnLabel .. " resolution turn number changed")
        assert(resolution.afterState.turnStartReceipt == nil, turnLabel .. " resolver retained receipt")
        assert(resolution.afterState.status == "active", turnLabel .. " ended the battle")
        assert(resolution.afterState.turnNumber == turn + 1, turnLabel .. " did not advance one turn")
        assert(resolution.afterState.lastCommittedTurnId == turnId, turnLabel .. " commit marker changed")
        assert(#resolution.afterState.selection.playerCardInstanceIds == 0, turnLabel .. " retained selection")
        assert(#resolution.afterState.characterIntent.cardInstanceIds == 0, turnLabel .. " retained intent")
        assertState(turnLabel .. " after state", resolution.afterState)
        assertInventory(turnLabel .. " after", resolution.afterState, expectedInventory)
        assertConservation(turnLabel .. " resolution conservation", projection.workingState, resolution.afterState)
        assertConservation(turnLabel .. " whole-turn conservation", beforeState, resolution.afterState)

        trace.turns[turn] = {
            turnId = turnId,
            initialization = initialized,
            projection = projection,
            resolution = resolution,
        }
        state = resolution.afterState
    end

    assert(canonical(inputState) == originalSnapshot, label .. " mutated initial input")
    assert(state.status == "active", label .. " final state was not active")
    assert(state.turnNumber == 11, label .. " final turn number was not 11")
    assert(state.turnStartReceipt == nil, label .. " final state retained receipt")
    assertInventory(label .. " final", state, expectedInventory)
    trace.finalState = state
    return trace
end

local fixture = initialState()
assertState("initial fixture", fixture)
assert(#fixture.cardInstances == 10, "fixture must contain exactly ten card instances")
local first = simulate(fixture, "simulation A")
local second = simulate(clone(fixture), "simulation B")
local firstCanonical = canonical(first)
local secondCanonical = canonical(second)
assert(firstCanonical == secondCanonical, "same initial input produced different ten-turn results")

print(
    "TRACE"
        .. "|hash=" .. stableHash(firstCanonical)
        .. "|turn=" .. tostring(first.finalState.turnNumber)
        .. "|status=" .. tostring(first.finalState.status)
        .. "|cards=" .. tostring(#first.finalState.cardInstances)
        .. "|rng=" .. tostring(first.finalState.rng.cursor)
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[multi-turn-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua multi-turn check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua multi-turn check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different multi-turn results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^TRACE\|hash=\d{10}\|turn=11\|status=active\|cards=10\|rng=\d+$') {
        throw "Unexpected multi-turn determinism vector: $firstText"
    }

    Write-Output 'multi-turn-check: ok'
    Write-Output 'NOTE: UI, LLM, pendingTurn, and actual RisuAI integration remain untested.'
}
finally {
    Pop-Location
}
