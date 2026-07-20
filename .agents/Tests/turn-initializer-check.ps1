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
    viewBuilder = loadLore("System/viewBuilder.lua"),
    turnDraft = loadLore("System/turnDraft.lua"),
    triggerPipeline = loadLore("System/triggerPipeline.lua"),
    characterSelector = loadLore("System/characterSelector.lua"),
    turnInitializer = loadLore("System/turnInitializer.lua"),
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
    assert(not active[value], "cycle in fixture")
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

local function assertHasError(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    for _, item in ipairs(type(report.errors) == "table" and report.errors or {}) do
        if item.code == expectedCode then
            return item
        end
    end
    failReport(label .. " (missing " .. expectedCode .. ")", report)
end

local function assertIds(label, actual, expected)
    assert(type(actual) == "table", label .. " is not an array")
    assert(#actual == #expected, label .. " length mismatch")
    for index, expectedId in ipairs(expected) do
        assert(actual[index] == expectedId, label .. " mismatch at " .. index)
    end
end

local function card(instanceId, cardId, owner, zone, position)
    return {
        instanceId = instanceId,
        cardId = cardId,
        owner = owner,
        zone = zone,
        position = position,
    }
end

local function zoneIds(state, owner, zone)
    local entries = {}
    for sourceIndex, instance in ipairs(state.cardInstances) do
        if instance.owner == owner and instance.zone == zone then
            entries[#entries + 1] = { instance = instance, sourceIndex = sourceIndex }
        end
    end
    table.sort(entries, function(left, right)
        if left.instance.position ~= right.instance.position then
            return left.instance.position < right.instance.position
        end
        if left.instance.instanceId ~= right.instance.instanceId then
            return left.instance.instanceId < right.instance.instanceId
        end
        return left.sourceIndex < right.sourceIndex
    end)
    local ids = {}
    for index, entry in ipairs(entries) do
        ids[index] = entry.instance.instanceId
    end
    return ids
end

local staticData = assertOk(
    "static load",
    runScript("turn-initializer-check", "staticData", "loadAll")
).data

local function fixture()
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "initializer-battle",
        status = "active",
        turnNumber = 2,
        turnLimit = 10,
        environmentId = "uncrowded",
        rng = { seed = 777, cursor = 0 },
        player = {
            stealth = 30,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = {},
            planSlot = {
                occupied = true,
                cardInstanceId = "player-plan-001",
                cardId = "subtle_approach",
                placedTurn = 1,
                remainingTurns = 1,
                remainingCharges = 1,
                revealed = false,
            },
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
            card("player-plan-001", "subtle_approach", "player", "plan", 1),
            card("player-deck-001", "accidental_brush", "player", "deck", 1),
            card("player-deck-002", "read_the_room", "player", "deck", 2),
            card("player-deck-003", "pin_down", "player", "deck", 3),
            card("character-deck-001", "close_collar", "character", "deck", 1),
            card("character-deck-002", "quiet_warning", "character", "deck", 2),
            card("character-deck-003", "turn_to_corner", "character", "deck", 3),
            card("character-deck-004", "silent_glare", "character", "deck", 4),
        },
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
        lastCommittedTurnId = "initializer-battle-turn-001",
    }
end

local before = fixture()
assertOk("fixture validation", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    before,
    staticData
))
local beforeSnapshot = canonical(before)
local initialized = assertOk("prepare turn", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    before,
    staticData,
    { turnId = "initializer-battle-turn-002" }
))
assert(canonical(before) == beforeSnapshot, "initializer mutated authority input")
assert(initialized.reused == false, "first initialization cannot be marked reused")
assert(initialized.receipt.kind == "turnStartReceipt", "receipt kind mismatch")
assert(initialized.receipt.turnId == "initializer-battle-turn-002", "receipt turnId mismatch")
assert(initialized.receipt.turnNumber == 2, "receipt turn number mismatch")
assert(initialized.receipt.authorityFingerprint.algorithm == "canonical_poly131_137_receipt_v2", "authority fingerprint missing")
assert(canonical(initialized.receipt.draws) == canonical(initialized.draws), "draw audit was not preserved")
assert(canonical(initialized.receipt.characterSelection) == canonical(initialized.characterSelection), "selection audit was not preserved")
assert(initialized.receipt.baseline.stealth == 30, "baseline stealth mismatch")
assert(initialized.receipt.baseline.resistance == 30, "baseline resistance mismatch")
assert(initialized.receipt.baseline.mood == "ignore", "baseline mood mismatch")
assert(initialized.receipt.transient.moodLock.mood == "ignore", "turn-start mood lock was not preserved")
assert(initialized.receipt.transient.moodLock["until"] == "turn_end", "mood lock lifetime mismatch")
assert(initialized.state.player.planSlot.occupied == false, "triggered player plan remained occupied")
assertIds("triggered player plan discard", zoneIds(initialized.state, "player", "discard"), { "player-plan-001" })
assertIds("player draw", initialized.draws.player.drawnInstanceIds, {
    "player-deck-001",
    "player-deck-002",
    "player-deck-003",
})
assertIds("character draw", initialized.draws.character.drawnInstanceIds, {
    "character-deck-001",
    "character-deck-002",
    "character-deck-003",
})
assertIds("character intent", initialized.state.characterIntent.cardInstanceIds, { "character-deck-001" })
assert(initialized.state.characterIntent.publicActionTag == "block", "wrong public action tag")
assert(initialized.characterSelection.weightOffset == 0, "positive selection pool shifted weights")
assert(initialized.characterSelection.draw.kind == "weighted", "multi-card selection did not use weighted RNG")
assert(initialized.characterSelection.draw.totalWeight == 9 and initialized.characterSelection.draw.roll == 3,
    "weighted selection receipt changed")
assert(initialized.state.rng.cursor == 1, "weighted character selection did not consume RNG")
assert(initialized.draft.kind == "turnDraft", "turn draft was not constructed")
assert(initialized.draft.source.turnNumber == 2, "turn draft source mismatch")
local publicView = assertOk("initialized public view", runScript(
    "turn-initializer-check",
    "viewBuilder",
    "buildBattleView",
    initialized.state,
    staticData,
    { draft = initialized.draft }
)).view
local publicCanonical = canonical(publicView)
assert(string.find(publicCanonical, "close_collar", 1, true) == nil, "public view leaked selected character card id")
assert(string.find(publicCanonical, "character-deck-001", 1, true) == nil, "public view leaked selected character instance")
assert(string.find(publicCanonical, "characterSelection", 1, true) == nil, "public view leaked private selection receipt")
assert(publicView.character.publicAction.tag.id == "block", "public view lost revealed action tag")

-- Persisted selection receipts replay both the exact RNG transition and actual card effects.
local alteredRoll = clone(initialized.state)
alteredRoll.turnStartReceipt.characterSelection.draw.roll = 4
assertHasError("selection roll replay", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    alteredRoll,
    staticData
), "selection_roll_replay_mismatch")

local advancedSelectionRng = clone(initialized.state)
advancedSelectionRng.turnStartReceipt.characterSelection.rngAfter.cursor = 2
assertHasError("selection rngAfter replay", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    advancedSelectionRng,
    staticData
), "selection_rng_after_replay_mismatch")

local missingCandidate = clone(initialized.state)
table.remove(missingCandidate.turnStartReceipt.characterSelection.candidates, 3)
assertHasError("selection candidate removed", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    missingCandidate,
    staticData
), "selection_candidate_count_mismatch")

local reorderedCandidates = clone(initialized.state)
local reorderedSelection = reorderedCandidates.turnStartReceipt.characterSelection
reorderedSelection.candidates[1], reorderedSelection.candidates[2] =
    reorderedSelection.candidates[2], reorderedSelection.candidates[1]
assertHasError("selection candidate reordered", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    reorderedCandidates,
    staticData
), "selection_candidate_hand_mismatch")

local coherentEffectTamper = clone(initialized.state)
local alteredSelection = coherentEffectTamper.turnStartReceipt.characterSelection
local closeCandidate = alteredSelection.candidates[1]
closeCandidate.totals.recoverResistance = 20
closeCandidate.score = 20
closeCandidate.weight = 20
alteredSelection.draw.totalWeight = 26
alteredSelection.draw.roll = 19
assertHasError("selection candidate effect replay", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    coherentEffectTamper,
    staticData
), "selection_candidate_replay_mismatch")

local expectedEventTypes = {
    "turn_start",
    "effect_applied",
    "plan_changed",
    "trigger_resolved",
    "cards_drawn",
    "cards_drawn",
    "character_intent_selected",
    "action_tag_revealed",
}
assert(#initialized.receipt.events == #expectedEventTypes, "unexpected initializer event count")
for index, expectedType in ipairs(expectedEventTypes) do
    local event = initialized.receipt.events[index]
    assert(event.type == expectedType, "event type mismatch at " .. index)
    assert(event.sequence == index, "event sequence mismatch at " .. index)
    assert(event.eventId == "initializer-battle-turn-002-event-" .. string.format("%03d", index), "event id mismatch at " .. index)
    assert(event.phase == "turn_start", "initializer event phase mismatch")
end
assert(initialized.receipt.events[2].cause.eventId == initialized.receipt.events[1].eventId, "turn-start trigger cause mismatch")
assert(initialized.receipt.events[2].cause.kind == "plan_trigger", "turn-start effect lost its trigger source cause")
assert(initialized.receipt.events[7].payload.selection == nil, "private selection receipt leaked into event payload")
assert(initialized.receipt.events[7].payload.selected == true, "selection event summary mismatch")
assert(initialized.receipt.events[8].source.kind == "system", "action tag event exposed its private card source")
assert(initialized.receipt.events[8].payload.cardInstanceId == nil, "action tag event exposed its private instance")
assertOk("initialized state validation", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    initialized.state,
    staticData
))
assertOk("initialized draft validation", runScript(
    "turn-initializer-check",
    "turnDraft",
    "validate",
    initialized.state,
    staticData,
    initialized.draft
))
assertOk("initialized conservation", runScript(
    "turn-initializer-check",
    "cardZones",
    "validateConservation",
    before,
    initialized.state
))

local initializedSnapshot = canonical(initialized.state)
local reused = assertOk("reuse initialized turn", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    initialized.state,
    staticData,
    { turnId = "initializer-battle-turn-002" }
))
assert(reused.reused == true, "same initialized turn was not reused")
assert(canonical(reused.state) == initializedSnapshot, "idempotent initialization changed state")
assert(canonical(reused.draft) == canonical(initialized.draft), "idempotent initialization changed draft")
assert(canonical(reused.characterSelection) == canonical(initialized.characterSelection), "idempotent initialization lost selection audit")
assert(canonical(reused.draws) == canonical(initialized.draws), "idempotent initialization lost draw audit")

local receiptCanary = initialized.receipt.events[1].payload.turnNumber
initialized.receipt.events[1].payload.turnNumber = 999
assert(initialized.state.turnStartReceipt.events[1].payload.turnNumber == receiptCanary, "receipt return aliases authority state")
initialized.receipt.events[1].payload.turnNumber = receiptCanary
local selectionCanary = initialized.state.turnStartReceipt.characterSelection.turnNumber
initialized.characterSelection.turnNumber = 999
assert(initialized.state.turnStartReceipt.characterSelection.turnNumber == selectionCanary, "selection return aliases authority state")
initialized.characterSelection.turnNumber = selectionCanary
local drawCanary = initialized.state.turnStartReceipt.draws.player.requested
initialized.draws.player.requested = 999
assert(initialized.state.turnStartReceipt.draws.player.requested == drawCanary, "draw return aliases authority state")
initialized.draws.player.requested = drawCanary

local authorityTamper = clone(initialized.state)
authorityTamper.player.stealth = authorityTamper.player.stealth + 1
assertHasError("receipt authority mismatch", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    authorityTamper,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "receipt_authority_mismatch")
assertHasError("different turn id after initialization", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    initialized.state,
    staticData,
    { turnId = "initializer-battle-turn-other" }
), "turn_already_initialized")

local revealData = clone(staticData)
table.insert(revealData.environments.uncrowded.triggers, {
    event = "action_tag_revealed",
    side = "character",
    resolve = function(context, event)
        assert(context.phase == "turn_start", "reveal trigger phase mismatch")
        assert(context.card.id == "close_collar", "reveal trigger currentCard missing")
        assert(context.card.instanceId == "character-deck-001", "reveal trigger current instance missing")
        assert(event.actionTag == "block" and event.cardId == "close_collar", "reveal input event mismatch")
        return {
            {
                op = "skip_actions",
                target = "player",
                scope = "remainingTurn",
                cause = "environmentEffect",
            },
        }
    end,
})
local revealResult = assertOk("action tag reveal pipeline", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    fixture(),
    revealData,
    { turnId = "initializer-battle-turn-002" }
))
assert(revealResult.receipt.transient.skipRemaining.player == true, "reveal transient was not preserved")
assert(revealResult.receipt.transient.moodLock.mood == "ignore", "turn-start transient was lost before reveal")
local revealInputEvent
local revealEffect
for _, event in ipairs(revealResult.receipt.events) do
    if event.type == "action_tag_revealed" then
        revealInputEvent = event
    elseif event.type == "effect_applied"
        and event.source.kind == "environment"
        and event.payload.op == "skip_actions" then
        revealEffect = event
    end
end
assert(revealInputEvent ~= nil and revealEffect ~= nil, "reveal pipeline events missing")
assert(revealEffect.cause.kind == "environment_trigger", "reveal effect cause kind mismatch")
assert(revealEffect.cause.eventId == revealInputEvent.eventId, "reveal effect cause event mismatch")

-- Persisted validation reconstructs the selection point across allowed reveal-time draws/resources.
local revealMutationData = clone(staticData)
table.insert(revealMutationData.environments.uncrowded.triggers, {
    event = "action_tag_revealed",
    side = "character",
    resolve = function()
        return {
            {
                op = "lose_stealth",
                target = "player",
                amount = 1,
                cause = "environmentEffect",
            },
            {
                op = "draw_cards",
                target = "character",
                amount = 1,
                cause = "environmentEffect",
            },
        }
    end,
})
local revealMutation = assertOk("reveal mutation selection context", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    fixture(),
    revealMutationData,
    { turnId = "initializer-battle-turn-002" }
))
assert(revealMutation.state.player.stealth == 29, "reveal resource effect was not applied")
assert(revealMutation.characterSelection.selectionContext.player.stealth == 30,
    "selection context did not preserve pre-reveal stealth")
assert(#revealMutation.characterSelection.selectionContext.characterHand == 3,
    "selection context absorbed a post-selection character draw")
assert(#zoneIds(revealMutation.state, "character", "hand") == 4,
    "reveal-time character draw was not applied")
assertOk("reveal mutation persisted receipt", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    revealMutation.state,
    revealMutationData
))

local inverseAuditTamper = clone(revealMutation.state)
local inverseReceipt = inverseAuditTamper.turnStartReceipt
local inverseSelection = inverseReceipt.characterSelection
inverseSelection.selectionContext.player.stealth = 31
for _, candidate in ipairs(inverseSelection.candidates) do
    candidate.projectedPlayerStealth = candidate.projectedPlayerStealth + 1
end
local inverseClose = inverseSelection.candidates[1]
inverseClose.totals.recoverResistance = 20
inverseClose.score = 20
inverseClose.weight = 20
inverseSelection.draw.totalWeight = 26
inverseSelection.draw.roll = 19
for _, event in ipairs(inverseReceipt.events) do
    if event.type == "effect_applied"
        and type(event.payload) == "table"
        and event.payload.op == "lose_stealth" then
        event.payload.amount = 2
        event.payload.before = 31
        event.payload.after = 29
    end
end
assertHasError("receipt-wide inverse audit tamper", runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    inverseAuditTamper,
    revealMutationData
), "receipt_authority_mismatch")

local revealDrawAuditTamper = clone(revealMutation.state)
local drawAuditReceipt = revealDrawAuditTamper.turnStartReceipt
local drawAuditSelection = drawAuditReceipt.characterSelection
drawAuditSelection.selectionContext.characterHand[4] = {
    instanceId = "character-deck-004",
    cardId = "silent_glare",
    actionTag = "intimidate",
    handPosition = 4,
}
drawAuditSelection.candidates[4] = {
    instanceId = "character-deck-004",
    cardId = "silent_glare",
    actionTag = "intimidate",
    handPosition = 4,
    score = 3,
    projectedPlayerStealth = 27,
    lethal = false,
    weight = 3,
    totals = {
        recoverResistance = 0,
        loseStealth = 3,
        damageResistance = 0,
        recoverStealth = 0,
    },
    planChargesEvaluated = 1,
}
drawAuditSelection.weightedPoolInstanceIds[4] = "character-deck-004"
drawAuditSelection.draw.totalWeight = 12
drawAuditSelection.draw.roll = 3
for _, event in ipairs(drawAuditReceipt.events) do
    if event.type == "effect_applied"
        and type(event.payload) == "table"
        and event.payload.op == "draw_cards"
        and event.payload.target == "character" then
        event.payload.drawnInstanceIds = {}
    end
end
local revealDrawAuditReport = runScript(
    "turn-initializer-check",
    "stateSchema",
    "validateBattleState",
    revealDrawAuditTamper,
    revealMutationData
)
assertHasError("receipt-wide reveal draw audit tamper", revealDrawAuditReport, "receipt_authority_mismatch")
assert(#revealDrawAuditReport.errors == 1
    and revealDrawAuditReport.errors[1].code == "receipt_authority_mismatch",
    "coherent reveal draw audit tamper was rejected by something other than the receipt fingerprint boundary")

local realTriggerPipeline = modules.triggerPipeline
modules.triggerPipeline = function(currentTriggerId, currentAction, ...)
    local report = realTriggerPipeline(currentTriggerId, currentAction, ...)
    if currentAction == "run" and report.ok == true then
        report.transient = {}
    end
    return report
end
local malformedPipelineState = fixture()
local malformedPipelineSnapshot = canonical(malformedPipelineState)
assertHasError("malformed trigger pipeline success", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    malformedPipelineState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_trigger_pipeline_transient")
assert(canonical(malformedPipelineState) == malformedPipelineSnapshot, "malformed pipeline failure mutated input")
modules.triggerPipeline = realTriggerPipeline

modules.triggerPipeline = function(currentTriggerId, currentAction, ...)
    local report = realTriggerPipeline(currentTriggerId, currentAction, ...)
    if currentAction == "run" and report.ok == true then
        report.state.player.stealth = "not-a-number"
    end
    return report
end
local scalarPipelineState = fixture()
local scalarPipelineSnapshot = canonical(scalarPipelineState)
assertHasError("pipeline scalar success envelope", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    scalarPipelineState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_trigger_pipeline_state")
assert(canonical(scalarPipelineState) == scalarPipelineSnapshot, "pipeline scalar failure mutated input")
modules.triggerPipeline = realTriggerPipeline

modules.triggerPipeline = function(currentTriggerId, currentAction, ...)
    local report = realTriggerPipeline(currentTriggerId, currentAction, ...)
    if currentAction == "run" and report.ok == true then
        setmetatable(report.state, {})
    end
    return report
end
local metatablePipelineState = fixture()
local metatablePipelineSnapshot = canonical(metatablePipelineState)
assertHasError("pipeline state metatable success envelope", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    metatablePipelineState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_trigger_pipeline_state")
assert(canonical(metatablePipelineState) == metatablePipelineSnapshot, "pipeline metatable failure mutated input")
modules.triggerPipeline = realTriggerPipeline

modules.triggerPipeline = function(currentTriggerId, currentAction, ...)
    local report = realTriggerPipeline(currentTriggerId, currentAction, ...)
    if currentAction == "run" and report.ok == true then
        setmetatable(report, {})
    end
    return report
end
local rootMetatablePipelineState = fixture()
local rootMetatablePipelineSnapshot = canonical(rootMetatablePipelineState)
assertHasError("pipeline root metatable success envelope", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    rootMetatablePipelineState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_module_result")
assert(canonical(rootMetatablePipelineState) == rootMetatablePipelineSnapshot, "pipeline root metatable failure mutated input")
modules.triggerPipeline = realTriggerPipeline

local realCardZones = modules.cardZones
modules.cardZones = function(currentTriggerId, currentAction, ...)
    local report = realCardZones(currentTriggerId, currentAction, ...)
    if currentAction == "draw" and report.ok == true then
        setmetatable(report.state.player, {})
    end
    return report
end
local metatableDrawState = fixture()
local metatableDrawSnapshot = canonical(metatableDrawState)
assertHasError("draw child metatable success envelope", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    metatableDrawState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_draw_state")
assert(canonical(metatableDrawState) == metatableDrawSnapshot, "draw metatable failure mutated input")
modules.cardZones = realCardZones

modules.cardZones = function(currentTriggerId, currentAction, ...)
    local report = realCardZones(currentTriggerId, currentAction, ...)
    if currentAction == "draw" and report.ok == true then
        report.state.rng.cursor = "not-a-number"
    end
    return report
end
local scalarDrawState = fixture()
local scalarDrawSnapshot = canonical(scalarDrawState)
assertHasError("draw scalar success envelope", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    scalarDrawState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_draw_state")
assert(canonical(scalarDrawState) == scalarDrawSnapshot, "draw scalar failure mutated input")
modules.cardZones = realCardZones

local selectedBefore = fixture()
for _, instance in ipairs(selectedBefore.cardInstances) do
    if instance.instanceId == "player-deck-001" then
        instance.zone = "hand"
        instance.position = 1
    elseif instance.instanceId == "player-deck-002" then
        instance.position = 1
    elseif instance.instanceId == "player-deck-003" then
        instance.position = 2
    end
end
selectedBefore.selection.playerCardInstanceIds = { "player-deck-001" }
assertHasError("nonempty player selection", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    selectedBefore,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "player_selection_not_empty")

local realCharacterSelector = modules.characterSelector
modules.characterSelector = function(currentTriggerId, currentAction, ...)
    local report = realCharacterSelector(currentTriggerId, currentAction, ...)
    if currentAction == "selectIntent" and report.ok == true then
        report.receipt.selectionContext.player.stealth = report.receipt.selectionContext.player.stealth + 1
    end
    return report
end
local contextMismatchState = fixture()
local contextMismatchSnapshot = canonical(contextMismatchState)
assertHasError("selector preselection context mismatch", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    contextMismatchState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "selection_context_state_mismatch")
assert(canonical(contextMismatchState) == contextMismatchSnapshot, "selector context mismatch failure mutated input")
modules.characterSelector = realCharacterSelector

modules.characterSelector = function(currentTriggerId, currentAction, ...)
    local report = realCharacterSelector(currentTriggerId, currentAction, ...)
    if currentAction == "selectIntent" and report.ok == true then
        report.state.character.resistance = "not-a-number"
    end
    return report
end
local scalarSelectorState = fixture()
local scalarSelectorSnapshot = canonical(scalarSelectorState)
assertHasError("selector scalar success envelope", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    scalarSelectorState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_character_selection_state")
assert(canonical(scalarSelectorState) == scalarSelectorSnapshot, "selector scalar failure mutated input")
modules.characterSelector = realCharacterSelector

modules.characterSelector = function(currentTriggerId, currentAction, ...)
    local report = realCharacterSelector(currentTriggerId, currentAction, ...)
    if currentAction == "selectIntent" and report.ok == true then
        setmetatable(report.state.character, {})
    end
    return report
end
local metatableSelectorState = fixture()
local metatableSelectorSnapshot = canonical(metatableSelectorState)
assertHasError("selector child metatable success envelope", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    metatableSelectorState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "invalid_character_selection_state")
assert(canonical(metatableSelectorState) == metatableSelectorSnapshot, "selector metatable failure mutated input")
modules.characterSelector = realCharacterSelector

modules.characterSelector = function(currentTriggerId, currentAction, ...)
    local report = realCharacterSelector(currentTriggerId, currentAction, ...)
    if currentAction == "selectIntent" and report.ok == true then
        report.receipt.selectedInstanceId = "character-deck-003"
        report.receipt.selectedCardId = "turn_to_corner"
        report.receipt.publicActionTag = "evade"
    end
    return report
end
local mismatchState = fixture()
local mismatchSnapshot = canonical(mismatchState)
assertHasError("selector receipt mismatch", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    mismatchState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
), "character_selection_selected_mismatch")
assert(canonical(mismatchState) == mismatchSnapshot, "selector mismatch failure mutated input")
modules.characterSelector = realCharacterSelector

local function reshuffleFixture()
    local value = fixture()
    value.player.planSlot = { occupied = false }
    value.cardInstances = {
        card("player-discard-001", "accidental_brush", "player", "discard", 1),
        card("player-discard-002", "read_the_room", "player", "discard", 2),
        card("player-discard-003", "pin_down", "player", "discard", 3),
        card("character-discard-001", "close_collar", "character", "discard", 1),
        card("character-discard-002", "quiet_warning", "character", "discard", 2),
        card("character-discard-003", "turn_to_corner", "character", "discard", 3),
        card("character-discard-004", "silent_glare", "character", "discard", 4),
    }
    value.rng = { seed = 2468, cursor = 0 }
    return value
end

local reshuffleState = reshuffleFixture()
local manualPlayer = assertOk("manual player-first draw", runScript(
    "turn-initializer-check",
    "cardZones",
    "draw",
    reshuffleState,
    "player",
    3
))
local manualCharacter = assertOk("manual character-second draw", runScript(
    "turn-initializer-check",
    "cardZones",
    "draw",
    manualPlayer.state,
    "character",
    3
))
local manualSelection = assertOk("manual character selection", runScript(
    "turn-initializer-check",
    "characterSelector",
    "selectIntent",
    manualCharacter.state,
    staticData
))
local reshuffled = assertOk("initializer reshuffle order", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    reshuffleState,
    staticData,
    { turnId = "initializer-battle-turn-002" }
))
assertIds("player-first reshuffle ids", reshuffled.draws.player.drawnInstanceIds, manualPlayer.drawnInstanceIds)
assertIds("character-second reshuffle ids", reshuffled.draws.character.drawnInstanceIds, manualCharacter.drawnInstanceIds)
assert(canonical(reshuffled.state.rng) == canonical(manualSelection.state.rng), "initializer RNG order differs from player-then-character")
assert(canonical(reshuffled.state.characterIntent) == canonical(manualSelection.state.characterIntent), "initializer selection differs after draw order")

local deterministicRepeat = assertOk("deterministic repeat", runScript(
    "turn-initializer-check",
    "turnInitializer",
    "prepareTurn",
    clone(reshuffleState),
    staticData,
    { turnId = "initializer-battle-turn-002" }
))
assert(canonical(deterministicRepeat.state) == canonical(reshuffled.state), "same initializer input changed state")
assert(canonical(deterministicRepeat.receipt) == canonical(reshuffled.receipt), "same initializer input changed receipt")

print("turn-initializer-check: ok")
print("note: actual RisuAI lore/trigger integration is not covered")
'@

$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("turn-initializer-check-" + [guid]::NewGuid().ToString('N') + '.lua')
try {
    Set-Content -LiteralPath $tempPath -Value $luaTest -Encoding UTF8
    Push-Location $projectRoot
    try {
        & $luaHost $tempPath
        if ($LASTEXITCODE -ne 0) {
            throw "Lua turn initializer check failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
}
