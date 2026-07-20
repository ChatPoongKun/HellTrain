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
    assert(not active[value], "cycle in test fixture")
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
    assert(valueType == "table", "non-data value in canonical fixture: " .. valueType)

    active = active or {}
    assert(not active[value], "cycle in canonical fixture")
    active[value] = true

    local numericCount = 0
    local maximum = 0
    local hasOther = false
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
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
        table.insert(parts, canonical(tostring(key), active) .. ":" .. canonical(value[key], active))
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
        table.insert(messages, tostring(item.code) .. " at " .. tostring(item.path) .. ": " .. tostring(item.message))
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

local function assertHasError(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    for _, item in ipairs(type(report.errors) == "table" and report.errors or {}) do
        if item.code == expectedCode then
            assert(type(item.path) == "string" and item.path ~= "", label .. " error has no path")
            return item
        end
    end
    failReport(label .. " (missing " .. expectedCode .. ")", report)
end

local function assertIds(label, actual, expected)
    assert(type(actual) == "table", label .. " is not an array")
    assert(#actual == #expected, label .. " length mismatch")
    for index, expectedId in ipairs(expected) do
        assert(actual[index] == expectedId, label .. " mismatch at " .. index .. ": " .. tostring(actual[index]))
    end
end

local staticLoad = assertOk("static lore load", runScript("turn-resolver-check", "staticData", "loadAll"))
local staticData = staticLoad.data
assert(staticLoad.counts.cards == 14, "resolver fixture did not load all fourteen cards")

local function makeCard(instanceId, cardId, owner, zone, position)
    return {
        instanceId = instanceId,
        cardId = cardId,
        owner = owner,
        zone = zone,
        position = position,
    }
end

local function findCard(state, instanceId)
    for _, instance in ipairs(state.cardInstances) do
        if instance.instanceId == instanceId then
            return instance
        end
    end
    return nil
end

local function zoneIds(state, owner, zone)
    local entries = {}
    for index, instance in ipairs(state.cardInstances) do
        if instance.owner == owner and instance.zone == zone then
            table.insert(entries, { instance = instance, index = index })
        end
    end
    table.sort(entries, function(left, right)
        if left.instance.position ~= right.instance.position then
            return left.instance.position < right.instance.position
        end
        return left.index < right.index
    end)
    local result = {}
    for index, entry in ipairs(entries) do
        result[index] = entry.instance.instanceId
    end
    return result
end

local function makeState(options, data)
    options = options or {}
    data = data or staticData
    local intentIds = clone(options.intentIds or {})
    local intent = { cardInstanceIds = intentIds }
    if #intentIds > 0 then
        local lastInstance
        for _, instance in ipairs(options.cards or {}) do
            if instance.instanceId == intentIds[#intentIds] then
                lastInstance = instance
                break
            end
        end
        assert(lastInstance, "intent main instance missing")
        intent.publicActionTag = assert(data.cards[lastInstance.cardId]).actionTag
    end

    local state = {
        schemaVersion = 1,
        kind = "battleState",
        battleId = options.battleId or "resolver-battle",
        status = "active",
        turnNumber = options.turnNumber or 1,
        turnLimit = options.turnLimit or 10,
        environmentId = "uncrowded",
        rng = clone(options.rng or { seed = 42, cursor = 0 }),
        player = {
            stealth = options.stealth or 30,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = clone(options.perkIds or {}),
            planSlot = clone(options.playerPlan or { occupied = false }),
        },
        character = {
            characterId = "yoo_jiyoung",
            resistance = options.resistance or 30,
            mood = options.mood or "ignore",
            traitIds = options.traitIds == nil and { "reserved" } or clone(options.traitIds),
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = clone(options.characterPlan or { occupied = false }),
        },
        cardInstances = clone(options.cards or {}),
        selection = { playerCardInstanceIds = {} },
        characterIntent = intent,
    }
    if options.turnStartReceipt ~= nil then
        state.turnStartReceipt = clone(options.turnStartReceipt)
    end
    return state
end

local function attachTurnStartReceipt(state, turnId, options)
    options = options or {}
    local initialized = assertOk(
        "turn-start receipt authority",
        runScript(
            "turn-resolver-check",
            "turnInitializer",
            "prepareTurn",
            state,
            staticData,
            { turnId = turnId }
        )
    )
    local initializedState = initialized.state
    local receipt = initializedState.turnStartReceipt
    assert(type(receipt) == "table", "turn initializer did not attach a receipt")
    if options.baseline ~= nil then
        receipt.baseline = clone(options.baseline)
    end
    if options.transient ~= nil then
        receipt.transient = clone(options.transient)
    end
    if options.events ~= nil then
        receipt.events = clone(options.events)
    end
    receipt.authorityFingerprint = nil
    initializedState = assertOk(
        "turn-start receipt override",
        runScript(
            "turn-resolver-check",
            "stateSchema",
            "sealTurnStartReceipt",
            initializedState,
            staticData
        )
    ).state
    return initializedState
end

local function planSlot(instanceId, cardId, placedTurn, duration, charges)
    return {
        occupied = true,
        cardInstanceId = instanceId,
        cardId = cardId,
        placedTurn = placedTurn,
        remainingTurns = duration,
        remainingCharges = charges,
        revealed = false,
    }
end

local function assertState(label, state, data)
    assertOk(label, runScript("turn-resolver-check", "stateSchema", "validateBattleState", state, data or staticData))
end

local function draftCall(label, action, state, data, draft, instanceId)
    local report = runScript(
        "turn-resolver-check",
        "turnDraft",
        action,
        state,
        data,
        draft,
        instanceId
    )
    return assertOk(label, report)
end

local function makeProjection(label, state, selectedIds, data)
    data = data or staticData
    assertState(label .. " authority", state, data)
    local draft = draftCall(label .. " new draft", "newDraft", state, data, nil, nil).draft
    for index, instanceId in ipairs(selectedIds or {}) do
        draft = draftCall(
            label .. " register " .. index,
            "registerCard",
            state,
            data,
            draft,
            instanceId
        ).draft
    end
    local report = draftCall(label .. " project", "project", state, data, draft, nil)
    assert(type(report.projection) == "table", label .. " projection missing")
    return report.projection
end

local function assertLowerSnake(label, value)
    assert(type(value) == "string" and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil,
        label .. " is not lower_snake_case: " .. tostring(value))
end

local function assertJsonSafe(label, value, active)
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean" or valueType == "string" then
        return
    end
    if valueType == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, label .. " has a non-finite number")
        return
    end
    assert(valueType == "table", label .. " has non-JSON value type " .. valueType)

    active = active or {}
    assert(not active[value], label .. " has a cycle")
    active[value] = true

    local numericCount = 0
    local maximum = 0
    local stringCount = 0
    for key, item in pairs(value) do
        local keyType = type(key)
        if keyType == "number" then
            assert(key % 1 == 0 and key >= 1, label .. " has an invalid numeric key")
            numericCount = numericCount + 1
            maximum = math.max(maximum, key)
        else
            assert(keyType == "string", label .. " has a non-string object key")
            stringCount = stringCount + 1
        end
        assertJsonSafe(label .. "." .. tostring(key), item, active)
    end
    assert(numericCount == 0 or stringCount == 0, label .. " mixes array and object keys")
    assert(numericCount == 0 or numericCount == maximum, label .. " is a sparse array")
    active[value] = nil
end

local function assertEventEnvelope(label, events, turnId)
    assert(type(events) == "table", label .. " events missing")
    local ids = {}
    local observedResolutionIds = {}
    local declaredResolutionIds = {}
    for index, event in ipairs(events) do
        assert(type(event) == "table", label .. " event is not a table")
        assert(event.sequence == index, label .. " event sequence is not contiguous")
        local expectedEventId = turnId .. "-event-" .. string.format("%03d", index)
        assert(event.eventId == expectedEventId,
            label .. " eventId mismatch: expected " .. expectedEventId .. ", got " .. tostring(event.eventId))
        assert(not ids[event.eventId], label .. " duplicate eventId")
        ids[event.eventId] = true
        assertLowerSnake(label .. " event type", event.type)
        assertLowerSnake(label .. " event phase", event.phase)
        assert(type(event.source) == "table", label .. " event source missing")
        assertLowerSnake(label .. " source kind", event.source.kind)
        assertLowerSnake(label .. " source id", event.source.id)
        assert(event.payload == nil or type(event.payload) == "table", label .. " event payload is not data")
        if event.resolutionId ~= nil then
            local resolutionPrefix = turnId .. "-resolution-"
            local resolutionSuffix = type(event.resolutionId) == "string"
                and string.sub(event.resolutionId, #resolutionPrefix + 1)
                or nil
            assert(type(event.resolutionId) == "string"
                    and string.sub(event.resolutionId, 1, #resolutionPrefix) == resolutionPrefix
                    and string.match(resolutionSuffix, "^%d%d%d$") ~= nil,
                label .. " invalid resolutionId: " .. tostring(event.resolutionId))
            observedResolutionIds[event.resolutionId] = true
            if event.type == "card_declared" then
                local expectedResolutionId = resolutionPrefix .. string.format("%03d", #declaredResolutionIds + 1)
                assert(event.resolutionId == expectedResolutionId,
                    label .. " declaration resolutionId is not contiguous: " .. tostring(event.resolutionId))
                declaredResolutionIds[#declaredResolutionIds + 1] = event.resolutionId
            end
        end
        if event.cause ~= nil then
            assert(type(event.cause) == "table", label .. " event cause is not an object")
            assertLowerSnake(label .. " cause kind", event.cause.kind)
            if event.cause.resolutionId ~= nil then
                assert(event.cause.resolutionId == event.resolutionId,
                    label .. " cause resolutionId does not match event resolutionId")
            end
        end
        assertJsonSafe(label .. " event " .. index, event)
    end
    local declarationSet = {}
    for _, resolutionId in ipairs(declaredResolutionIds) do
        declarationSet[resolutionId] = true
    end
    for resolutionId in pairs(observedResolutionIds) do
        assert(declarationSet[resolutionId], label .. " event references an undeclared resolutionId: " .. resolutionId)
    end
end

local function resolve(label, state, projection, turnId, data)
    data = data or staticData
    local stateSnapshot = canonical(state)
    local projectionSnapshot = canonical(projection)
    local options = { turnId = turnId }
    local optionsSnapshot = canonical(options)
    local report = assertOk(
        label,
        runScript(
            "turn-resolver-check",
            "turnResolver",
            "resolveTurn",
            state,
            data,
            projection,
            options
        )
    )
    assert(canonical(state) == stateSnapshot, label .. " mutated authoritative state")
    assert(canonical(projection) == projectionSnapshot, label .. " mutated projection")
    assert(canonical(options) == optionsSnapshot, label .. " mutated options")

    local resolution = report.resolution
    assert(type(resolution) == "table", label .. " resolution missing")
    assert(resolution.schemaVersion == 1 and resolution.kind == "turnResolution", label .. " resolution header changed")
    assert(resolution.battleId == state.battleId, label .. " battleId mismatch")
    assert(resolution.turnId == turnId, label .. " turnId mismatch")
    assert(resolution.turnNumber == state.turnNumber, label .. " turnNumber mismatch")
    assert(type(resolution.source) == "table", label .. " source receipt missing")
    assert(type(resolution.selectedCards) == "table", label .. " selectedCards missing")
    assert(type(resolution.selectedCards.player) == "table", label .. " player selectedCards missing")
    assert(type(resolution.selectedCards.character) == "table", label .. " character selectedCards missing")
    assert(type(resolution.metrics) == "table", label .. " metrics missing")
    assert(type(resolution.afterState) == "table" and resolution.afterState ~= state, label .. " afterState missing or aliased")
    assert(resolution.afterState.lastCommittedTurnId == turnId, label .. " afterState was not marked committed")
    assert(resolution.afterState.turnStartReceipt == nil, label .. " retained turnStartReceipt after cleanup")
    assertEventEnvelope(label, resolution.events, turnId)
    assertState(label .. " afterState", resolution.afterState, data)
    assertOk(
        label .. " conservation",
        runScript("turn-resolver-check", "cardZones", "validateConservation", state, resolution.afterState)
    )
    return resolution
end

local function sourceEvents(resolution, acceptedTypes)
    local result = {}
    for _, event in ipairs(resolution.events) do
        if acceptedTypes[event.type] then
            table.insert(result, event)
        end
    end
    return result
end

local function matchingEvents(resolution, eventType, predicate)
    local result = {}
    for _, event in ipairs(resolution.events) do
        if event.type == eventType and (predicate == nil or predicate(event)) then
            result[#result + 1] = event
        end
    end
    return result
end

local function onlyEvent(label, resolution, eventType, predicate)
    local events = matchingEvents(resolution, eventType, predicate)
    assert(#events == 1, label .. " expected one " .. eventType .. " event, got " .. tostring(#events))
    return events[1]
end

local function assertTriggerSequence(label, resolution, expected)
    local events = sourceEvents(resolution, {
        trigger_resolved = true,
        trigger_suppressed = true,
    })
    assert(#events == #expected, label .. " trigger count mismatch: " .. tostring(#events))
    for index, item in ipairs(expected) do
        local event = events[index]
        assert(event.type == item.type, label .. " trigger type mismatch at " .. index)
        assert(event.source.kind == item.kind, label .. " trigger kind mismatch at " .. index)
        assert(event.source.id == item.id, label .. " trigger id mismatch at " .. index)
    end
end

local function cardEvents(resolution, eventType)
    local result = {}
    for _, event in ipairs(resolution.events) do
        if event.type == eventType and event.source.kind == "card" then
            table.insert(result, event)
        end
    end
    return result
end

local function assertCardEventIds(label, resolution, eventType, expectedCardIds)
    local events = cardEvents(resolution, eventType)
    assert(#events == #expectedCardIds, label .. " card event count mismatch")
    for index, expectedId in ipairs(expectedCardIds) do
        assert(events[index].source.id == expectedId, label .. " card event mismatch at " .. index)
    end
end

local function assertMetrics(label, resolution, expected)
    for key, value in pairs(expected) do
        assert(resolution.metrics[key] == value, label .. " metric " .. key .. " expected " .. tostring(value)
            .. " but got " .. tostring(resolution.metrics[key]))
    end
end

-- A turn-start receipt is the authoritative handoff from initialization. Its
-- events remain at the head of the final log, its baseline drives performance,
-- and its transient mood lock survives until the resolver's mood checkpoint.
local receiptTurnId = "resolver-receipt-turn-001"
local receiptState = makeState({
    battleId = "resolver-receipt",
    stealth = 30,
    resistance = 30,
    traitIds = {},
})
receiptState = attachTurnStartReceipt(receiptState, receiptTurnId, {
    baseline = { stealth = 32, resistance = 36, mood = "ignore" },
    transient = {
        skipRemaining = { player = false, character = false },
        directMoodChanged = false,
        moodLock = { mood = "ignore", ["until"] = "turn_end", cause = "plan" },
    },
})
local receiptProjection = makeProjection("turn-start receipt", receiptState, {})

local receiptIdMismatch = runScript(
    "turn-resolver-check",
    "turnResolver",
    "resolveTurn",
    receiptState,
    staticData,
    receiptProjection,
    { turnId = "resolver-receipt-turn-other" }
)
assertHasError("receipt turnId mismatch", receiptIdMismatch, "receipt_turn_id_mismatch")

local receiptTurnMismatchState = clone(receiptState)
receiptTurnMismatchState.turnStartReceipt.turnNumber = receiptTurnMismatchState.turnNumber + 1
local receiptTurnMismatch = runScript(
    "turn-resolver-check",
    "turnResolver",
    "resolveTurn",
    receiptTurnMismatchState,
    staticData,
    receiptProjection,
    { turnId = receiptTurnId }
)
assertHasError("receipt turn number mismatch", receiptTurnMismatch, "receipt_turn_mismatch")

local receiptTamperedState = clone(receiptState)
receiptTamperedState.turnStartReceipt.events[1].eventId = receiptTurnId .. "-event-999"
local receiptTampered = runScript(
    "turn-resolver-check",
    "turnResolver",
    "resolveTurn",
    receiptTamperedState,
    staticData,
    receiptProjection,
    { turnId = receiptTurnId }
)
local receiptTamperError = assertHasError("tampered receipt event", receiptTampered, "module_rejected")
assert(string.find(receiptTamperError.message, "receipt_authority_mismatch", 1, true) ~= nil,
    "tampered receipt did not fail at the authority fingerprint boundary")

local receiptFirstEvent = canonical(receiptState.turnStartReceipt.events[1])
local receiptEventCount = #receiptState.turnStartReceipt.events
local receiptResolution = resolve(
    "turn-start receipt",
    receiptState,
    receiptProjection,
    receiptTurnId
)
assert(canonical(receiptResolution.events[1]) == receiptFirstEvent, "turn-start event was not preserved verbatim")
assert(receiptResolution.events[receiptEventCount + 1].eventId
        == receiptTurnId .. "-event-" .. string.format("%03d", receiptEventCount + 1),
    "resolver event numbering did not continue after turn-start events")
assertMetrics("receipt baseline", receiptResolution, {
    startingStealth = 32,
    endingStealth = 30,
    startingResistance = 36,
    endingResistance = 30,
    resistancePerformance = 6,
    stealthSpent = 2,
    moodPerformance = 4,
    commonMoodApplied = false,
})
assert(receiptResolution.afterState.character.mood == "ignore", "receipt mood lock did not survive handoff")
local receiptMood = onlyEvent("receipt mood lock", receiptResolution, "mood_evaluated")
assert(receiptMood.payload.reasonCode == "mood_locked", "receipt mood lock reason changed")

-- Skip and direct-mood flags are also resolver inputs, not effects to replay.
local receiptSkipTurnId = "resolver-receipt-skip-turn-001"
local receiptSkipState = makeState({
    battleId = "resolver-receipt-skip",
    cards = {
        makeCard("receipt-warning", "quiet_warning", "character", "hand", 1),
    },
})
receiptSkipState = attachTurnStartReceipt(receiptSkipState, receiptSkipTurnId, {
    transient = {
        skipRemaining = { player = false, character = true },
        directMoodChanged = true,
    },
})
local receiptSkipProjection = makeProjection("receipt transient flags", receiptSkipState, {})
local receiptSkipResolution = resolve(
    "receipt transient flags",
    receiptSkipState,
    receiptSkipProjection,
    receiptSkipTurnId
)
assertCardEventIds("receipt character skip", receiptSkipResolution, "card_declared", {})
local receiptSkippedCharacter = onlyEvent(
    "receipt character skip",
    receiptSkipResolution,
    "action_sequence_stopped",
    function(event)
        return event.payload.side == "character"
    end
)
assert(receiptSkippedCharacter.payload.reasonCode == "skip_actions", "receipt skip reason changed")
assertIds("receipt skipped character ids", receiptSkippedCharacter.payload.unresolvedInstanceIds, {
    "receipt-warning",
})
local receiptDirectMood = onlyEvent("receipt direct mood", receiptSkipResolution, "mood_evaluated")
assert(receiptDirectMood.payload.reasonCode == "direct_mood_changed",
    "receipt directMoodChanged flag was not handed off")
assert(findCard(receiptSkipResolution.afterState, "receipt-warning").zone == "discard",
    "receipt-skipped character card was not cleaned up")

-- A player card declaration snapshots both matching sources. The character plan
-- resolves before the environment, consumes its charge, and base damage follows.
local orderState = makeState({
    battleId = "resolver-order",
    cards = {
        makeCard("order-brush", "accidental_brush", "player", "hand", 1),
        makeCard("order-unused-p", "play_it_cool", "player", "hand", 2),
        makeCard("order-glare", "silent_glare", "character", "plan", 1),
        makeCard("order-unused-c", "quiet_warning", "character", "hand", 1),
    },
    characterPlan = planSlot("order-glare", "silent_glare", 1, 1, 1),
})
local orderProjection = makeProjection("trigger order", orderState, { "order-brush" })
local orderResolution = resolve("trigger order", orderState, orderProjection, "resolver-order-turn-001")
assertTriggerSequence("trigger order", orderResolution, {
    { type = "trigger_resolved", kind = "plan", id = "silent_glare" },
    { type = "trigger_resolved", kind = "environment", id = "uncrowded" },
})
assert(orderResolution.afterState.player.stealth == 26, "trigger order stealth result changed")
assert(orderResolution.afterState.character.resistance == 27, "trigger order resistance result changed")
assert(orderResolution.afterState.character.planSlot.occupied == false, "spent plan remained occupied")
assertMetrics("trigger order", orderResolution, {
    startingStealth = 30,
    endingStealth = 26,
    startingResistance = 30,
    endingResistance = 27,
    resistancePerformance = 3,
    stealthSpent = 4,
    moodPerformance = -1,
    commonMoodApplied = false,
})
assertIds("trigger order player discard", zoneIds(orderResolution.afterState, "player", "discard"), {
    "order-brush", "order-unused-p",
})
assertIds("trigger order character discard", zoneIds(orderResolution.afterState, "character", "discard"), {
    "order-glare", "order-unused-c",
})
local triggeredPlanChange = onlyEvent("triggered plan receipt", orderResolution, "plan_changed", function(event)
    return event.payload.action == "triggered"
end)
assert(triggeredPlanChange.source.kind == "plan" and triggeredPlanChange.source.id == "silent_glare",
    "triggered plan receipt source changed")
assert(triggeredPlanChange.payload.before.occupied == true, "triggered plan receipt lost its before slot")
assert(triggeredPlanChange.payload.before.cardInstanceId == "order-glare"
        and triggeredPlanChange.payload.before.remainingCharges == 1
        and triggeredPlanChange.payload.before.revealed == false,
    "triggered plan before payload changed")
assert(triggeredPlanChange.payload.after.occupied == false, "spent plan after payload stayed occupied")
assert(triggeredPlanChange.payload.discarded == true, "spent plan did not report discard")
assertIds("triggered plan moved ids", triggeredPlanChange.payload.movedInstanceIds, { "order-glare" })

local orderCleanup = onlyEvent("trigger order cleanup", orderResolution, "turn_cleanup")
assert(orderCleanup.payload.before.turnNumber == 1 and orderCleanup.payload.after.turnNumber == 2,
    "active cleanup did not expose its before/after turn numbers")
assertIds("trigger order cleanup before player used", orderCleanup.payload.before.player.used, { "order-brush" })
assertIds("trigger order cleanup before player hand", orderCleanup.payload.before.player.hand, { "order-unused-p" })
assertIds("trigger order cleanup before character discard", orderCleanup.payload.before.character.discard, {
    "order-glare",
})
assertIds("trigger order cleanup after player discard", orderCleanup.payload.after.player.discard, {
    "order-brush", "order-unused-p",
})
assertIds("trigger order cleanup after character discard", orderCleanup.payload.after.character.discard, {
    "order-glare", "order-unused-c",
})
assertIds("trigger order cleanup moved ids", orderCleanup.payload.movedInstanceIds, {
    "order-brush", "order-unused-p", "order-unused-c",
})

-- Test-only trigger content makes category order observable: each lane sets a
-- different mood, so only plan -> trait -> perk -> environment can end at
-- rejection. The perk lane is reserved by the runtime even though production
-- perk content is not loaded yet.
local categoryData = clone(staticData)
local function setMoodTrigger(mood, cause)
    return function(context, event)
        return {
            {
                op = "set_mood",
                target = "character",
                mood = mood,
                cause = cause,
            },
        }
    end
end
categoryData.cards.silent_glare.mechanismData.plan.resolve = setMoodTrigger("suspicion", "fixture_plan")
categoryData.traits.reserved.triggers = {
    {
        event = "card_declared",
        side = "player",
        resolve = setMoodTrigger("confusion", "fixture_trait"),
    },
}
categoryData.perks = {
    fixture_perk = {
        id = "fixture_perk",
        owner = "player",
        triggers = {
            {
                event = "card_declared",
                side = "player",
                resolve = setMoodTrigger("compliance", "fixture_perk"),
            },
        },
    },
}
categoryData.environments.uncrowded.triggers = {
    {
        event = "card_declared",
        side = "player",
        resolve = setMoodTrigger("rejection", "fixture_environment"),
    },
}
local categoryState = makeState({
    battleId = "resolver-category-order",
    perkIds = { "fixture_perk" },
    cards = {
        makeCard("category-brush", "accidental_brush", "player", "hand", 1),
        makeCard("category-glare", "silent_glare", "character", "plan", 1),
    },
    characterPlan = planSlot("category-glare", "silent_glare", 1, 1, 1),
}, categoryData)
local categoryProjection = makeProjection(
    "all trigger categories",
    categoryState,
    { "category-brush" },
    categoryData
)
local categoryResolution = resolve(
    "all trigger categories",
    categoryState,
    categoryProjection,
    "resolver-category-order-turn-001",
    categoryData
)
assertTriggerSequence("all trigger categories", categoryResolution, {
    { type = "trigger_resolved", kind = "plan", id = "silent_glare" },
    { type = "trigger_resolved", kind = "trait", id = "reserved" },
    { type = "trigger_resolved", kind = "perk", id = "fixture_perk" },
    { type = "trigger_resolved", kind = "environment", id = "uncrowded" },
})
assert(categoryResolution.afterState.character.mood == "rejection",
    "noncommutative category fixture did not preserve plan -> trait -> perk -> environment")
assert(categoryResolution.metrics.commonMoodApplied == false,
    "direct trigger mood changes unexpectedly allowed common mood")

-- Invalid declarative filters must reach the effect-engine validator. They
-- cannot be silently discarded as ordinary nonmatches by resolver prefiltering.
local invalidTriggerState = makeState({
    battleId = "resolver-invalid-trigger",
    cards = {
        makeCard("invalid-trigger-brush", "accidental_brush", "player", "hand", 1),
    },
})
local invalidEventData = clone(staticData)
invalidEventData.environments.uncrowded.triggers[1].event = "missing_event"
local invalidEventProjection = makeProjection(
    "invalid trigger event",
    invalidTriggerState,
    { "invalid-trigger-brush" },
    invalidEventData
)
assertHasError(
    "invalid trigger event",
    runScript(
        "turn-resolver-check",
        "turnResolver",
        "resolveTurn",
        invalidTriggerState,
        invalidEventData,
        invalidEventProjection,
        { turnId = "resolver-invalid-trigger-event-turn-001" }
    ),
    "unknown_trigger_event"
)
local invalidSideData = clone(staticData)
invalidSideData.environments.uncrowded.triggers[1].side = "ownerless"
local invalidSideProjection = makeProjection(
    "invalid trigger side",
    invalidTriggerState,
    { "invalid-trigger-brush" },
    invalidSideData
)
assertHasError(
    "invalid trigger side",
    runScript(
        "turn-resolver-check",
        "turnResolver",
        "resolveTurn",
        invalidTriggerState,
        invalidSideData,
        invalidSideProjection,
        { turnId = "resolver-invalid-trigger-side-turn-001" }
    ),
    "invalid_trigger_side"
)

-- Character base fields are reserved at exact zero in v1. Check raw values,
-- including negatives that would otherwise disappear through max(0, value).
local negativeCharacterCostData = clone(staticData)
negativeCharacterCostData.cards.quiet_warning.base.stealthCost = -1
local negativeCharacterCostState = makeState({
    battleId = "resolver-negative-character-cost",
    cards = {
        makeCard("negative-cost-warning", "quiet_warning", "character", "hand", 1),
    },
    intentIds = { "negative-cost-warning" },
}, negativeCharacterCostData)
local negativeCharacterCostProjection = makeProjection(
    "negative character cost",
    negativeCharacterCostState,
    {},
    negativeCharacterCostData
)
assertHasError(
    "negative character cost",
    runScript(
        "turn-resolver-check",
        "turnResolver",
        "resolveTurn",
        negativeCharacterCostState,
        negativeCharacterCostData,
        negativeCharacterCostProjection,
        { turnId = "resolver-negative-character-cost-turn-001" }
    ),
    "unsupported_character_cost"
)
local negativeCharacterDamageData = clone(staticData)
negativeCharacterDamageData.cards.quiet_warning.base.resistanceDamage = -1
local negativeCharacterDamageState = makeState({
    battleId = "resolver-negative-character-damage",
    cards = {
        makeCard("negative-damage-warning", "quiet_warning", "character", "hand", 1),
    },
    intentIds = { "negative-damage-warning" },
}, negativeCharacterDamageData)
local negativeCharacterDamageProjection = makeProjection(
    "negative character damage",
    negativeCharacterDamageState,
    {},
    negativeCharacterDamageData
)
assertHasError(
    "negative character damage",
    runScript(
        "turn-resolver-check",
        "turnResolver",
        "resolveTurn",
        negativeCharacterDamageState,
        negativeCharacterDamageData,
        negativeCharacterDamageProjection,
        { turnId = "resolver-negative-character-damage-turn-001" }
    ),
    "unsupported_character_base_damage"
)

-- Insight suppresses only the opposing plan tied to this resolution. It stays
-- hidden and keeps its charge while the environment still resolves normally.
local insightState = makeState({
    battleId = "resolver-insight",
    cards = {
        makeCard("insight-pin", "pin_down", "player", "hand", 1),
        makeCard("insight-glare", "silent_glare", "character", "plan", 1),
    },
    characterPlan = planSlot("insight-glare", "silent_glare", 1, 1, 1),
})
local insightProjection = makeProjection("insight", insightState, { "insight-pin" })
local insightResolution = resolve("insight", insightState, insightProjection, "resolver-insight-turn-001")
assertTriggerSequence("insight", insightResolution, {
    { type = "trigger_suppressed", kind = "plan", id = "silent_glare" },
    { type = "trigger_resolved", kind = "environment", id = "uncrowded" },
})
assert(insightResolution.afterState.player.stealth == 26, "insight suppressed the environment or changed cost order")
assert(insightResolution.afterState.character.resistance == 23, "insight base damage changed")
local retainedPlan = insightResolution.afterState.character.planSlot
assert(retainedPlan.occupied == true, "suppressed plan was discarded")
assert(retainedPlan.remainingCharges == 1 and retainedPlan.revealed == false, "suppressed plan leaked or consumed charge")
assert(findCard(insightResolution.afterState, "insight-glare").zone == "plan", "suppressed plan left its zone")

-- A pure pass is an explicit, deterministic receipt rather than an absent turn.
-- Neither side declares a card, while normal structural cleanup still discards
-- both hands and advances the active battle exactly once.
local passState = makeState({
    battleId = "resolver-pass",
    cards = {
        makeCard("pass-player-one", "accidental_brush", "player", "hand", 1),
        makeCard("pass-player-two", "play_it_cool", "player", "hand", 2),
        makeCard("pass-character-one", "quiet_warning", "character", "hand", 1),
    },
})
local passProjection = makeProjection("pure pass", passState, {})
assert(passProjection.mode == "pass", "empty selection projection is not pass")
local passResolution = resolve("pure pass", passState, passProjection, "resolver-pass-turn-001")
assert(passResolution.source.mode == "pass", "resolution lost the pass receipt")
assertIds("pass player selection", passResolution.selectedCards.player, {})
assertIds("pass character selection", passResolution.selectedCards.character, {})
assert(#cardEvents(passResolution, "card_declared") == 0, "pass declared a card")
assert(#cardEvents(passResolution, "card_resolved") == 0, "pass resolved a card")
assert(passResolution.afterState.turnNumber == 2, "pass did not advance the active turn")
assertIds("pass player discard", zoneIds(passResolution.afterState, "player", "discard"), {
    "pass-player-one", "pass-player-two",
})
assertIds("pass character discard", zoneIds(passResolution.afterState, "character", "discard"), {
    "pass-character-one",
})
local passCleanup = onlyEvent("pass cleanup", passResolution, "turn_cleanup")
assert(passCleanup.payload.resolvedTurnNumber == 1, "pass cleanup lost the resolved turn")
assert(passCleanup.payload.before.turnNumber == 1 and passCleanup.payload.after.turnNumber == 2,
    "pass cleanup turn transition changed")
assertIds("pass cleanup before player hand", passCleanup.payload.before.player.hand, {
    "pass-player-one", "pass-player-two",
})
assertIds("pass cleanup after player hand", passCleanup.payload.after.player.hand, {})
assertIds("pass cleanup after player discard", passCleanup.payload.after.player.discard, {
    "pass-player-one", "pass-player-two",
})

-- Eye alone is a real chain-pass action: its speculative draw is already in the
-- validated projection, the eye still declares once, and the unregistered draw
-- is discarded as an unused hand card during structural cleanup.
local chainPassState = makeState({
    battleId = "resolver-chain-pass",
    cards = {
        makeCard("chain-eye", "read_the_room", "player", "hand", 1),
        makeCard("chain-preview", "play_it_cool", "player", "deck", 1),
    },
})
local chainPassProjection = makeProjection("chain pass", chainPassState, { "chain-eye" })
assert(chainPassProjection.mode == "chain_pass", "eye-only projection is not chain_pass")
local chainPassResolution = resolve(
    "chain pass",
    chainPassState,
    chainPassProjection,
    "resolver-chain-pass-turn-001"
)
assert(chainPassResolution.source.mode == "chain_pass", "resolution lost chain_pass receipt")
assertCardEventIds("chain pass declaration", chainPassResolution, "card_declared", { "read_the_room" })
assert(chainPassResolution.afterState.player.stealth == 29, "chain pass environment trigger changed")
assertIds("chain pass cleanup", zoneIds(chainPassResolution.afterState, "player", "discard"), {
    "chain-eye", "chain-preview",
})

-- Eye resolves as the affordable prefix. Its environment loss makes the later
-- pin unaffordable (3 is not strictly greater than cost 3); the pin is never
-- declared, while the character's intent still resolves.
local lateState = makeState({
    battleId = "resolver-late",
    stealth = 4,
    cards = {
        makeCard("late-eye", "read_the_room", "player", "hand", 1),
        makeCard("late-pin", "pin_down", "player", "hand", 2),
        makeCard("late-preview", "play_it_cool", "player", "deck", 1),
        makeCard("late-warning", "quiet_warning", "character", "hand", 1),
    },
    intentIds = { "late-warning" },
})
local lateProjection = makeProjection("late unaffordable", lateState, { "late-eye", "late-pin" })
local lateResolution = resolve("late unaffordable", lateState, lateProjection, "resolver-late-turn-001")
assertIds("late registered player cards", lateResolution.selectedCards.player, { "late-eye", "late-pin" })
assertIds("late registered character cards", lateResolution.selectedCards.character, { "late-warning" })
assertCardEventIds("late declarations", lateResolution, "card_declared", {
    "read_the_room", "quiet_warning",
})
assertCardEventIds("late resolutions", lateResolution, "card_resolved", {
    "read_the_room", "quiet_warning",
})
assert(lateResolution.afterState.player.stealth == 1, "late unaffordable prefix or character continuation changed")
assert(lateResolution.afterState.character.resistance == 30, "unaffordable pin dealt damage")
assertIds("late player cleanup", zoneIds(lateResolution.afterState, "player", "discard"), {
    "late-eye", "late-preview", "late-pin",
})
assertIds("late character cleanup", zoneIds(lateResolution.afterState, "character", "discard"), {
    "late-warning",
})

-- A preceding runtime draw can refill the hand before a later affordability
-- failure. Restoring two registered used cards is then allowed to exceed the
-- hand cap only inside the receipt-bearing working state; cleanup must commit a
-- valid capped state without losing or duplicating any card.
local restoreData = clone(staticData)
restoreData.cards.read_the_room.mechanisms = { "chain" }
restoreData.cards.play_it_cool.mechanisms = { "chain" }
restoreData.cards.play_it_cool.base.stealthCost = 3
restoreData.environments.uncrowded.triggers = {
    {
        event = "card_declared",
        side = "player",
        resolve = function(context, event)
            return {
                {
                    op = "draw_cards",
                    target = "player",
                    amount = 3,
                    cause = "fixture_runtime_draw",
                },
            }
        end,
    },
}
local restoreState = makeState({
    battleId = "resolver-restore-overcap",
    stealth = 4,
    cards = {
        makeCard("restore-eye", "read_the_room", "player", "hand", 1),
        makeCard("restore-cool", "play_it_cool", "player", "hand", 2),
        makeCard("restore-pin", "pin_down", "player", "hand", 3),
        makeCard("restore-filler-one", "accidental_brush", "player", "hand", 4),
        makeCard("restore-filler-two", "hypnotic_whisper", "player", "hand", 5),
        makeCard("restore-preview", "subtle_approach", "player", "deck", 1),
        makeCard("restore-runtime-one", "accidental_brush", "player", "deck", 2),
        makeCard("restore-runtime-two", "play_it_cool", "player", "deck", 3),
        makeCard("restore-deck-left", "pin_down", "player", "deck", 4),
        makeCard("restore-glare", "silent_glare", "character", "plan", 1),
    },
    characterPlan = planSlot("restore-glare", "silent_glare", 1, 1, 1),
}, restoreData)
local restoreProjection = makeProjection(
    "multi restore over cap",
    restoreState,
    { "restore-eye", "restore-cool", "restore-pin" },
    restoreData
)
assertIds("multi restore projected player selection", restoreProjection.selectedCardInstanceIds, {
    "restore-eye", "restore-cool", "restore-pin",
})
local restoreResolution = resolve(
    "multi restore over cap",
    restoreState,
    restoreProjection,
    "resolver-restore-overcap-turn-001",
    restoreData
)
assertCardEventIds("multi restore declarations", restoreResolution, "card_declared", { "read_the_room" })
assertCardEventIds("multi restore resolutions", restoreResolution, "card_resolved", { "read_the_room" })
local restoredCards = matchingEvents(restoreResolution, "card_restored")
assert(#restoredCards == 2, "multi restore did not restore exactly two cards")
assert(restoredCards[1].source.instanceId == "restore-cool"
        and restoredCards[2].source.instanceId == "restore-pin",
    "multi restore registration order changed")
local restoreStop = onlyEvent(
    "multi restore stop receipt",
    restoreResolution,
    "action_sequence_stopped",
    function(event)
        return event.payload.side == "player"
    end
)
assert(restoreStop.payload.reasonCode == "insufficient_stealth", "multi restore stop reason changed")
assertIds("multi restore receipt ids", restoreStop.payload.restoredInstanceIds, {
    "restore-cool", "restore-pin",
})
local restoreCleanup = onlyEvent("multi restore cleanup", restoreResolution, "turn_cleanup")
assert(#restoreCleanup.payload.before.player.hand == 7,
    "multi restore did not expose the temporary seven-card receipt state")
assertIds("multi restore cleanup before hand", restoreCleanup.payload.before.player.hand, {
    "restore-filler-one", "restore-filler-two", "restore-preview",
    "restore-runtime-one", "restore-runtime-two", "restore-cool", "restore-pin",
})
assertIds("multi restore final hand", zoneIds(restoreResolution.afterState, "player", "hand"), {})
assertIds("multi restore final discard", zoneIds(restoreResolution.afterState, "player", "discard"), {
    "restore-eye", "restore-filler-one", "restore-filler-two", "restore-preview",
    "restore-runtime-one", "restore-runtime-two", "restore-cool", "restore-pin",
})
assertIds("multi restore remaining deck", zoneIds(restoreResolution.afterState, "player", "deck"), {
    "restore-deck-left",
})

-- Player actions are fully resolved before character intents.
local orderSidesState = makeState({
    battleId = "resolver-sides",
    cards = {
        makeCard("sides-brush", "accidental_brush", "player", "hand", 1),
        makeCard("sides-collar", "close_collar", "character", "hand", 1),
    },
    intentIds = { "sides-collar" },
})
local orderSidesProjection = makeProjection("player character order", orderSidesState, { "sides-brush" })
local orderSidesResolution = resolve(
    "player character order",
    orderSidesState,
    orderSidesProjection,
    "resolver-sides-turn-001"
)
assertCardEventIds("player character declaration order", orderSidesResolution, "card_declared", {
    "accidental_brush", "close_collar",
})
assert(orderSidesResolution.afterState.player.stealth == 29, "side order stealth changed")
assert(orderSidesResolution.afterState.character.resistance == 30, "character did not recover after player damage")
assert(orderSidesResolution.afterState.turnNumber == 2, "active cleanup did not advance exactly one turn")

-- Outcome is latched only after the whole card resolution. The environment can
-- reduce stealth to zero, then the card can reduce resistance to zero, and the
-- shared checkpoint must award victory and stop the character action.
local simultaneousState = makeState({
    battleId = "resolver-simultaneous",
    stealth = 1,
    resistance = 3,
    cards = {
        makeCard("sim-brush", "accidental_brush", "player", "hand", 1),
        makeCard("sim-warning", "quiet_warning", "character", "hand", 1),
    },
    intentIds = { "sim-warning" },
})
local simultaneousProjection = makeProjection("simultaneous outcome", simultaneousState, { "sim-brush" })
local simultaneousResolution = resolve(
    "simultaneous outcome",
    simultaneousState,
    simultaneousProjection,
    "resolver-simultaneous-turn-001"
)
assert(simultaneousResolution.afterState.status == "victory", "simultaneous zero did not prioritize victory")
assert(simultaneousResolution.afterState.turnNumber == 1, "ended battle advanced past its resolved turn")
assert(simultaneousResolution.afterState.player.stealth == 0, "simultaneous stealth changed")
assert(simultaneousResolution.afterState.character.resistance == 0, "simultaneous resistance changed")
assertCardEventIds("victory stopped character", simultaneousResolution, "card_declared", { "accidental_brush" })
assert(simultaneousResolution.afterState.character.mood == "ignore", "ended battle applied common mood")
assert(simultaneousResolution.metrics.commonMoodApplied == false, "ended battle reported common mood")
local outcomeStoppedCharacter = onlyEvent(
    "outcome stopped character",
    simultaneousResolution,
    "action_sequence_stopped",
    function(event)
        return event.payload.side == "character"
    end
)
assert(outcomeStoppedCharacter.payload.reasonCode == "outcome_latched",
    "outcome character stop reason changed")
assertIds("outcome unresolved character ids", outcomeStoppedCharacter.payload.unresolvedInstanceIds, {
    "sim-warning",
})

local stealthDefeatState = makeState({
    battleId = "resolver-stealth-defeat",
    stealth = 1,
    cards = {
        makeCard("defeat-warning", "quiet_warning", "character", "hand", 1),
    },
    intentIds = { "defeat-warning" },
})
local stealthDefeatProjection = makeProjection("stealth defeat", stealthDefeatState, {})
local stealthDefeatResolution = resolve(
    "stealth defeat",
    stealthDefeatState,
    stealthDefeatProjection,
    "resolver-stealth-defeat-turn-001"
)
assert(stealthDefeatResolution.afterState.status == "defeat", "stealth zero did not cause defeat")
assert(stealthDefeatResolution.afterState.player.stealth == -1, "stealth defeat amount changed")
assert(stealthDefeatResolution.afterState.character.mood == "ignore", "defeat applied common mood")

-- The final allowed turn resolves both sides completely, then becomes a defeat
-- before the common mood step if resistance remains positive.
local lastTurnState = makeState({
    battleId = "resolver-last-turn",
    turnNumber = 3,
    turnLimit = 3,
    cards = {
        makeCard("last-brush", "accidental_brush", "player", "hand", 1),
        makeCard("last-collar", "close_collar", "character", "hand", 1),
    },
    intentIds = { "last-collar" },
})
local lastTurnProjection = makeProjection("last turn", lastTurnState, { "last-brush" })
local lastTurnResolution = resolve("last turn", lastTurnState, lastTurnProjection, "resolver-last-turn-003")
assertCardEventIds("last turn fully resolved", lastTurnResolution, "card_resolved", {
    "accidental_brush", "close_collar",
})
assert(lastTurnResolution.afterState.status == "defeat", "last turn with resistance remaining did not end in defeat")
assert(lastTurnResolution.afterState.turnNumber == 3, "last-turn defeat changed its resolved turn number")
assert(lastTurnResolution.afterState.character.resistance == 30, "last turn did not finish character recovery")
assert(lastTurnResolution.afterState.character.mood == "ignore", "last-turn defeat applied common mood")
assert(lastTurnResolution.metrics.commonMoodApplied == false, "last-turn defeat reported common mood")

-- Post-resolution triggers run before the card outcome checkpoint. Once the
-- post trigger defeats the player, turn_end is skipped, cleanup still runs,
-- and a command-free session_end trigger receives the terminal notification.
local postData = clone(staticData)
postData.environments.uncrowded.triggers = {
    {
        event = "card_resolved",
        side = "player",
        resolve = function(context, event)
            return {
                {
                    op = "lose_stealth",
                    target = "player",
                    amount = 2,
                    cause = "fixture_post",
                },
            }
        end,
    },
    {
        event = "turn_end",
        resolve = function(context, event)
            return {
                {
                    op = "lose_stealth",
                    target = "player",
                    amount = 100,
                    cause = "fixture_turn_end_must_not_run",
                },
            }
        end,
    },
    {
        event = "session_end",
        resolve = function(context, event)
            return {}
        end,
    },
}
local postState = makeState({
    battleId = "resolver-post-outcome",
    stealth = 2,
    cards = {
        makeCard("post-brush", "accidental_brush", "player", "hand", 1),
        makeCard("post-warning", "quiet_warning", "character", "hand", 1),
    },
    intentIds = { "post-warning" },
}, postData)
local postProjection = makeProjection("post outcome", postState, { "post-brush" }, postData)
local postResolution = resolve(
    "post outcome",
    postState,
    postProjection,
    "resolver-post-outcome-turn-001",
    postData
)
assert(postResolution.afterState.status == "defeat", "post card_resolved trigger did not latch defeat")
assert(postResolution.afterState.player.stealth == 0, "skipped turn_end fixture still changed stealth")
local postTriggerEvents = matchingEvents(postResolution, "trigger_resolved")
assert(#postTriggerEvents == 2, "post/session trigger count changed")
assert(postTriggerEvents[1].payload.inputEventType == "card_resolved"
        and postTriggerEvents[1].phase == "player_card",
    "card_resolved post trigger timing changed")
assert(postTriggerEvents[2].payload.inputEventType == "session_end"
        and postTriggerEvents[2].phase == "session_end",
    "session_end trigger timing changed")
for _, event in ipairs(postTriggerEvents) do
    assert(event.payload.inputEventType ~= "turn_end", "turn_end trigger ran after card-checkpoint defeat")
end
onlyEvent("post terminal receipt", postResolution, "session_end")
local postStoppedCharacter = onlyEvent(
    "post outcome stopped character",
    postResolution,
    "action_sequence_stopped",
    function(event)
        return event.payload.side == "character"
    end
)
assertIds("post outcome unresolved character", postStoppedCharacter.payload.unresolvedInstanceIds, {
    "post-warning",
})

-- A side-less turn_end trigger can itself cause the terminal outcome. Its
-- checkpoint precedes cleanup and is followed by session_end in stable order.
local turnEndData = clone(staticData)
turnEndData.environments.uncrowded.triggers = {
    {
        event = "turn_end",
        resolve = function(context, event)
            return {
                {
                    op = "lose_stealth",
                    target = "player",
                    amount = 1,
                    cause = "fixture_turn_end",
                },
            }
        end,
    },
    {
        event = "session_end",
        resolve = function(context, event)
            return {}
        end,
    },
}
local turnEndState = makeState({
    battleId = "resolver-turn-end-outcome",
    stealth = 1,
}, turnEndData)
local turnEndProjection = makeProjection("turn end outcome", turnEndState, {}, turnEndData)
local turnEndResolution = resolve(
    "turn end outcome",
    turnEndState,
    turnEndProjection,
    "resolver-turn-end-outcome-turn-001",
    turnEndData
)
assert(turnEndResolution.afterState.status == "defeat", "turn_end trigger did not latch defeat")
local lifecycleTriggers = matchingEvents(turnEndResolution, "trigger_resolved")
assert(#lifecycleTriggers == 2, "turn_end/session_end trigger count changed")
assert(lifecycleTriggers[1].payload.inputEventType == "turn_end"
        and lifecycleTriggers[1].phase == "turn_end",
    "turn_end trigger timing changed")
assert(lifecycleTriggers[2].payload.inputEventType == "session_end"
        and lifecycleTriggers[2].phase == "session_end",
    "turn_end outcome did not continue to session_end")
local turnEndOutcome = onlyEvent("turn end outcome receipt", turnEndResolution, "outcome_latched")
assert(turnEndOutcome.payload.reasonCode == "turn_end_checkpoint", "turn_end outcome reason changed")
local turnEndCleanup = onlyEvent("turn end cleanup", turnEndResolution, "turn_cleanup")
assert(turnEndCleanup.payload.before.turnNumber == 1 and turnEndCleanup.payload.after.turnNumber == 1,
    "terminal cleanup advanced the resolved turn")
onlyEvent("turn end terminal receipt", turnEndResolution, "session_end")

-- session_end v1 is notification-only. A trigger that tries to mutate battle
-- resources must reject the entire resolution with a structured error.
local invalidSessionData = clone(turnEndData)
invalidSessionData.environments.uncrowded.triggers[2].resolve = function(context, event)
    return {
        {
            op = "recover_stealth",
            target = "player",
            amount = 1,
            cause = "fixture_invalid_session",
        },
    }
end
local invalidSessionState = makeState({
    battleId = "resolver-invalid-session",
    stealth = 1,
}, invalidSessionData)
local invalidSessionProjection = makeProjection(
    "invalid session command",
    invalidSessionState,
    {},
    invalidSessionData
)
local invalidSessionStateSnapshot = canonical(invalidSessionState)
local invalidSessionProjectionSnapshot = canonical(invalidSessionProjection)
local invalidSessionReport = runScript(
    "turn-resolver-check",
    "turnResolver",
    "resolveTurn",
    invalidSessionState,
    invalidSessionData,
    invalidSessionProjection,
    { turnId = "resolver-invalid-session-turn-001" }
)
assertHasError("invalid session command", invalidSessionReport, "unsupported_session_end_commands")
assert(canonical(invalidSessionState) == invalidSessionStateSnapshot,
    "session_end command rejection mutated authority")
assert(canonical(invalidSessionProjection) == invalidSessionProjectionSnapshot,
    "session_end command rejection mutated projection")

-- Reserved changes only compliance-direction thresholds. A -4 performance at
-- ignore therefore still moves one step toward rejection.
local commonState = makeState({
    battleId = "resolver-common",
    cards = {
        makeCard("common-corner", "turn_to_corner", "character", "hand", 1),
    },
    intentIds = { "common-corner" },
})
local commonProjection = makeProjection("common mood", commonState, {})
local commonResolution = resolve("common mood", commonState, commonProjection, "resolver-common-turn-001")
assert(commonResolution.afterState.character.resistance == 34, "common mood recovery changed")
assert(commonResolution.afterState.character.mood == "suspicion", "-4 common performance did not move toward rejection")
assertMetrics("common mood", commonResolution, {
    resistancePerformance = -4,
    stealthSpent = 0,
    moodPerformance = -4,
    commonMoodApplied = true,
})

-- Neutralizing only the environment isolates the current pin's exact P=4. The
-- base ignore->confusion threshold accepts it, while Yoo's reserved +1 rejects it.
local neutralData = clone(staticData)
neutralData.environments.uncrowded.triggers = {}
local reservedThresholdState = makeState({
    battleId = "resolver-reserved-threshold",
    cards = {
        makeCard("reserved-pin", "pin_down", "player", "hand", 1),
    },
}, neutralData)
local reservedThresholdProjection = makeProjection(
    "reserved compliance threshold",
    reservedThresholdState,
    { "reserved-pin" },
    neutralData
)
local reservedThresholdResolution = resolve(
    "reserved compliance threshold",
    reservedThresholdState,
    reservedThresholdProjection,
    "resolver-reserved-threshold-turn-001",
    neutralData
)
assert(reservedThresholdResolution.metrics.moodPerformance == 4, "reserved threshold fixture is not exact P=4")
assert(reservedThresholdResolution.afterState.character.mood == "ignore", "reserved failed to raise compliance threshold")
assert(reservedThresholdResolution.metrics.commonMoodApplied == false, "reserved threshold unexpectedly moved mood")

local plainThresholdState = makeState({
    battleId = "resolver-plain-threshold",
    traitIds = {},
    cards = {
        makeCard("plain-pin", "pin_down", "player", "hand", 1),
    },
}, neutralData)
local plainThresholdProjection = makeProjection(
    "plain compliance threshold",
    plainThresholdState,
    { "plain-pin" },
    neutralData
)
local plainThresholdResolution = resolve(
    "plain compliance threshold",
    plainThresholdState,
    plainThresholdProjection,
    "resolver-plain-threshold-turn-001",
    neutralData
)
assert(plainThresholdResolution.metrics.moodPerformance == 4, "plain threshold fixture is not exact P=4")
assert(plainThresholdResolution.afterState.character.mood == "confusion", "base P=4 did not move toward compliance")
assert(plainThresholdResolution.metrics.commonMoodApplied == true, "base threshold movement was not reported")

-- A real direct shift suppresses common mood, skips the character, and remove
-- moves the card out of the active cycle.
local directState = makeState({
    battleId = "resolver-direct",
    cards = {
        makeCard("direct-hypnotic", "hypnotic_whisper", "player", "hand", 1),
        makeCard("direct-warning", "quiet_warning", "character", "hand", 1),
    },
    intentIds = { "direct-warning" },
})
local directProjection = makeProjection("direct mood", directState, { "direct-hypnotic" })
local directResolution = resolve("direct mood", directState, directProjection, "resolver-direct-turn-001")
assert(directResolution.afterState.character.mood == "confusion", "direct mood shift was not applied")
assert(directResolution.metrics.commonMoodApplied == false, "actual direct shift allowed common mood")
assert(findCard(directResolution.afterState, "direct-hypnotic").zone == "removed", "remove card returned to discard")
assertCardEventIds("direct skip character", directResolution, "card_declared", { "hypnotic_whisper" })
assert(findCard(directResolution.afterState, "direct-warning").zone == "discard", "skipped character card was not cleaned up")
local skippedCharacter = onlyEvent(
    "direct skip receipt",
    directResolution,
    "action_sequence_stopped",
    function(event)
        return event.payload.side == "character"
    end
)
assert(skippedCharacter.payload.reasonCode == "skip_actions", "direct skip reason changed")
assertIds("direct skip unresolved ids", skippedCharacter.payload.unresolvedInstanceIds, { "direct-warning" })

-- At the compliance edge, shift +1 causes no actual movement. It must not by
-- itself suppress the later -5 common result. Cost 1 is a fixture-only numeric
-- change; all callbacks and trigger definitions remain the current DB versions.
local edgeData = clone(staticData)
edgeData.cards.hypnotic_whisper.base.stealthCost = 1
local edgeState = makeState({
    battleId = "resolver-direct-edge",
    mood = "compliance",
    cards = {
        makeCard("edge-hypnotic", "hypnotic_whisper", "player", "hand", 1),
        makeCard("edge-glare", "silent_glare", "character", "plan", 1),
    },
    characterPlan = planSlot("edge-glare", "silent_glare", 1, 1, 1),
}, edgeData)
local edgeProjection = makeProjection("direct edge", edgeState, { "edge-hypnotic" }, edgeData)
local edgeResolution = resolve(
    "direct edge",
    edgeState,
    edgeProjection,
    "resolver-direct-edge-turn-001",
    edgeData
)
assert(edgeResolution.metrics.moodPerformance == -5, "direct edge fixture is not exact P=-5")
assert(edgeResolution.afterState.character.mood == "confusion", "clamped direct shift incorrectly suppressed common mood")
assert(edgeResolution.metrics.commonMoodApplied == true, "edge common movement was not reported")

-- A lock applied during this resolver call always suppresses common mood. The
-- fixture keeps the current pin and lock command contracts, but adds a resolve
-- callback because the real subtle_approach lock belongs to the earlier turn
-- initializer and cannot be reconstructed after a projection has been made.
local lockData = clone(neutralData)
lockData.cards.pin_down.resolve = function(context)
    return {
        {
            op = "lock_mood",
            target = "character",
            mood = "ignore",
            ["until"] = "turn_end",
            cause = "cardEffect",
        },
        {
            op = "shift_mood",
            target = "character",
            amount = 1,
            cause = "cardEffect",
        },
    }
end
local lockState = makeState({
    battleId = "resolver-lock",
    traitIds = {},
    cards = {
        makeCard("lock-pin", "pin_down", "player", "hand", 1),
    },
}, lockData)
local lockProjection = makeProjection("mood lock", lockState, { "lock-pin" }, lockData)
local lockResolution = resolve(
    "mood lock",
    lockState,
    lockProjection,
    "resolver-lock-turn-001",
    lockData
)
assert(lockResolution.metrics.moodPerformance == 4, "lock fixture is not exact P=4")
assert(lockResolution.afterState.character.mood == "ignore", "lock failed to block direct or common mood")
assert(lockResolution.metrics.commonMoodApplied == false, "locked turn reported common mood")

-- A character plan card moves from hand to the plan slot and survives the
-- structural end-turn cleanup with its declared lifetime intact.
local placementState = makeState({
    battleId = "resolver-plan-placement",
    cards = {
        makeCard("placement-glare", "silent_glare", "character", "hand", 1),
        makeCard("placement-unused", "close_collar", "character", "hand", 2),
    },
    intentIds = { "placement-glare" },
})
local placementProjection = makeProjection("plan placement", placementState, {})
local placementResolution = resolve(
    "plan placement",
    placementState,
    placementProjection,
    "resolver-plan-placement-turn-001"
)
assertCardEventIds("plan placement action", placementResolution, "card_resolved", { "silent_glare" })
local placedPlan = placementResolution.afterState.character.planSlot
assert(placedPlan.occupied == true and placedPlan.cardId == "silent_glare", "character plan was not placed")
assert(placedPlan.placedTurn == 1 and placedPlan.remainingTurns == 1 and placedPlan.remainingCharges == 1,
    "placed plan lifetime changed during same-turn cleanup")
assert(placedPlan.revealed == false, "new plan started revealed")
assert(findCard(placementResolution.afterState, "placement-glare").zone == "plan", "placed card is not in plan zone")
assertIds("plan placement unused cleanup", zoneIds(placementResolution.afterState, "character", "discard"), {
    "placement-unused",
})
local placedPlanChange = onlyEvent("placed plan receipt", placementResolution, "plan_changed", function(event)
    return event.payload.action == "placed"
end)
assert(placedPlanChange.source.kind == "card" and placedPlanChange.source.id == "silent_glare",
    "placed plan receipt source changed")
assert(placedPlanChange.payload.instanceId == "placement-glare", "placed plan receipt lost its instance")
assert(placedPlanChange.payload.before.occupied == false, "placed plan before payload was not empty")
assert(placedPlanChange.payload.after.occupied == true
        and placedPlanChange.payload.after.cardInstanceId == "placement-glare"
        and placedPlanChange.payload.after.remainingTurns == 1
        and placedPlanChange.payload.after.remainingCharges == 1,
    "placed plan after payload changed")
assert(placedPlanChange.payload.planSpec.durationTurns == 1
        and placedPlanChange.payload.planSpec.charges == 1
        and placedPlanChange.payload.planSpec.revealed == false,
    "placed plan specification receipt changed")
assertIds("placed plan moved ids", placedPlanChange.payload.movedInstanceIds, { "placement-glare" })
local placementCleanup = onlyEvent("placement cleanup", placementResolution, "turn_cleanup")
assert(placementCleanup.payload.before.character.planSlot.cardInstanceId == "placement-glare"
        and placementCleanup.payload.after.character.planSlot.cardInstanceId == "placement-glare",
    "cleanup did not expose the retained plan before and after")
assertIds("placement cleanup before character hand", placementCleanup.payload.before.character.hand, {
    "placement-unused",
})
assertIds("placement cleanup after character hand", placementCleanup.payload.after.character.hand, {})

-- A projection is untrusted input. Resolver validation must replay it and reject
-- a derived-state edit without mutating either authority or request.
local tamperedProjection = clone(orderProjection)
tamperedProjection.workingState.player.stealth = tamperedProjection.workingState.player.stealth + 1
local tamperedStateSnapshot = canonical(orderState)
local tamperedProjectionSnapshot = canonical(tamperedProjection)
local tamperedReport = runScript(
    "turn-resolver-check",
    "turnResolver",
    "resolveTurn",
    orderState,
    staticData,
    tamperedProjection,
    { turnId = "resolver-order-turn-tampered" }
)
assertHasError("tampered projection", tamperedReport, "projection_mismatch")
assert(canonical(orderState) == tamperedStateSnapshot, "tamper rejection mutated authority")
assert(canonical(tamperedProjection) == tamperedProjectionSnapshot, "tamper rejection mutated projection")

-- The same authority, validated projection, static data and turn ID must yield
-- byte-for-byte equivalent JSON data within one process. The PowerShell harness
-- repeats the whole program in a second Lua process as well.
local deterministicA = resolve(
    "deterministic replay A",
    orderState,
    orderProjection,
    "resolver-order-turn-deterministic"
)
local deterministicB = resolve(
    "deterministic replay B",
    orderState,
    orderProjection,
    "resolver-order-turn-deterministic"
)
assert(canonical(deterministicA) == canonical(deterministicB), "same resolver input produced different output")
local deterministicResolutionHash = stableHash(canonical(deterministicA))

local orderTriggers = sourceEvents(orderResolution, { trigger_resolved = true, trigger_suppressed = true })
local orderVector = {}
for index, event in ipairs(orderTriggers) do
    orderVector[index] = event.source.kind .. ":" .. event.source.id
end
print(
    "VECTOR"
        .. "|order=" .. table.concat(orderVector, ",")
        .. "|insight-stealth=" .. tostring(insightResolution.afterState.player.stealth)
        .. "|late-stealth=" .. tostring(lateResolution.afterState.player.stealth)
        .. "|simultaneous=" .. simultaneousResolution.afterState.status
        .. "|last=" .. lastTurnResolution.afterState.status
        .. "|common=" .. commonResolution.afterState.character.mood
        .. "|reserved=" .. reservedThresholdResolution.afterState.character.mood
        .. "|plain=" .. plainThresholdResolution.afterState.character.mood
        .. "|direct=" .. directResolution.afterState.character.mood
        .. "|edge=" .. edgeResolution.afterState.character.mood
        .. "|lock=" .. lockResolution.afterState.character.mood
        .. "|resolution=" .. deterministicResolutionHash
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[turn-resolver-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua turnResolver check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua turnResolver check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different turnResolver results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    $expectedVectorPrefix = 'VECTOR|order=plan:silent_glare,environment:uncrowded|insight-stealth=26|late-stealth=1|simultaneous=victory|last=defeat|common=suspicion|reserved=ignore|plain=confusion|direct=confusion|edge=confusion|lock=ignore|resolution='
    if (-not $firstText.StartsWith($expectedVectorPrefix) -or $firstText -notmatch '\|resolution=\d{10}$') {
        throw "Unexpected turnResolver determinism vector: $firstText"
    }

    Write-Output 'turn-resolver-check: ok'
    Write-Output 'NOTE: RisuAI lorebook and UI/pendingTurn integration remains untested.'
}
finally {
    Pop-Location
}
