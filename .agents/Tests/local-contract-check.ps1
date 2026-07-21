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
    throw 'Lua 실행기를 찾을 수 없습니다. 이 검사는 실제 RisuAI 통합 검사를 대신하지 않습니다.'
}

$luaTest = @'
local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadDatabase(path)
    return assert(load(readFile(path), "@" .. path, "t", _G))()
end

local function loadLore(path)
    return assert(load("return" .. readFile(path), "@" .. path, "t", _G))()
end

local modules = {
    init = loadLore("System/init.lua"),
    deterministicRng = loadLore("System/deterministicRng.lua"),
    effectEngine = loadLore("System/effectEngine.lua"),
    staticData = loadLore("System/staticData.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
    characterSelector = loadLore("System/characterSelector.lua"),
    cardZones = loadLore("System/cardZones.lua"),
    turnDraft = loadLore("System/turnDraft.lua"),
    viewBuilder = loadLore("System/viewBuilder.lua"),
    dataBridge = loadLore("System/dataBridge.lua"),
}

function runScript(triggerId, name, ...)
    local module = assert(modules[name], "unknown module: " .. tostring(name))
    return module(triggerId, ...)
end

local published = {}
local publishCount = 0
local wireMarkers = {}
function setChatVar(triggerId, name, value)
    publishCount = publishCount + 1
    published[name] = value
end

local function recordWire(name, value)
    table.insert(wireMarkers, name .. "=" .. value)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
}
local loreOverrides = {}

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    if not path then
        return {}
    end
    return { { content = loreOverrides[name] or readFile(path) } }
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

local function reverseClone(value, active)
    if type(value) ~= "table" then
        return value
    end
    active = active or {}
    assert(not active[value], "cycle in test fixture")
    active[value] = true

    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return left > right
        end
        return type(left) > type(right)
    end)

    local copy = {}
    for _, key in ipairs(keys) do
        copy[reverseClone(key, active)] = reverseClone(value[key], active)
    end
    active[value] = nil
    return copy
end

local function deepEqual(left, right, visited)
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return left == right
    end

    visited = visited or {}
    if visited[left] == right then
        return true
    end
    visited[left] = right

    local leftCount = 0
    for key, value in pairs(left) do
        leftCount = leftCount + 1
        if not deepEqual(value, right[key], visited) then
            return false
        end
    end
    local rightCount = 0
    for _ in pairs(right) do
        rightCount = rightCount + 1
    end
    return leftCount == rightCount
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
    return report
end

local function assertError(label, report, expectedCode, expectedPath)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    for _, item in ipairs(type(report.errors) == "table" and report.errors or {}) do
        if item.code == expectedCode and (expectedPath == nil or item.path == expectedPath) then
            return item
        end
    end
    failReport(label .. " (missing " .. expectedCode .. " at " .. tostring(expectedPath) .. ")", report)
end

local staticLoad = assertOk(
    "static lore load",
    runScript("test", "staticData", "loadAll")
)
local staticData = staticLoad.data
local registry = staticData.registry
local cards = staticData.cards
assert(staticLoad.counts.cards == 14)
assert(staticLoad.counts.traits == 1)
assert(staticLoad.counts.environments == 1)
assert(staticLoad.counts.characters == 1)
assert(staticData.characters.yoo_jiyoung.battle.baseDrawCount == 3)
assert(staticData.characters.yoo_jiyoung.battle.maxHandSize == 5)

local fractionalPlanSource, durationReplacementCount = string.gsub(
    readFile("DB/PlayerCards.db"),
    "durationTurns = 1",
    "durationTurns = 0.5",
    1
)
assert(durationReplacementCount == 1, "fractional duration fixture replacement failed")
local chargeReplacementCount
fractionalPlanSource, chargeReplacementCount = string.gsub(
    fractionalPlanSource,
    "charges = 1",
    "charges = 0.5",
    1
)
assert(chargeReplacementCount == 1, "fractional charge fixture replacement failed")
loreOverrides["PlayerCards.db"] = fractionalPlanSource
local fractionalPlanReport = runScript("test", "staticData", "loadAll")
loreOverrides["PlayerCards.db"] = nil
assertError(
    "fractional static plan duration",
    fractionalPlanReport,
    "invalid_plan_duration",
    "cards.subtle_approach.mechanismData.plan.durationTurns"
)
assertError(
    "fractional static plan charges",
    fractionalPlanReport,
    "invalid_plan_charges",
    "cards.subtle_approach.mechanismData.plan.charges"
)

local missingPolicyDurationSource, missingPolicyDurationCount = string.gsub(
    readFile("DB/PlayerCards.db"),
    "durationTurns = 1,%s+durationIncludesPlacementTurn = true,",
    "durationIncludesPlacementTurn = true,",
    1
)
assert(missingPolicyDurationCount == 1, "placement-turn policy fixture replacement failed")
loreOverrides["PlayerCards.db"] = missingPolicyDurationSource
local missingPolicyDurationReport = runScript("test", "staticData", "loadAll")
loreOverrides["PlayerCards.db"] = nil
assertError(
    "static placement-turn policy without duration",
    missingPolicyDurationReport,
    "plan_duration_policy_requires_duration",
    "cards.cut_off_escape.mechanismData.plan.durationIncludesPlacementTurn"
)

local baseState = {
    schemaVersion = 1,
    kind = "battleState",
    battleId = "battle-0001",
    status = "active",
    turnNumber = 1,
    turnLimit = 10,
    environmentId = "uncrowded",
    rng = { seed = 12345, cursor = 0 },
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
        planSlot = {
            occupied = true,
            cardInstanceId = "character-plan-001",
            cardId = "silent_glare",
            placedTurn = 1,
            remainingTurns = 1,
            remainingCharges = 1,
            revealed = false,
        },
    },
    cardInstances = {
        {
            instanceId = "player-001",
            cardId = "read_the_room",
            owner = "player",
            zone = "hand",
            position = 1,
            temporaryModifiers = {},
        },
        { instanceId = "player-002", cardId = "accidental_brush", owner = "player", zone = "hand", position = 2 },
        { instanceId = "player-003", cardId = "pin_down", owner = "player", zone = "hand", position = 3 },
        { instanceId = "character-plan-001", cardId = "silent_glare", owner = "character", zone = "plan", position = 1 },
        { instanceId = "character-hand-001", cardId = "quiet_warning", owner = "character", zone = "hand", position = 1 },
    },
    selection = {
        playerCardInstanceIds = { "player-001", "player-002" },
    },
    characterIntent = {
        cardInstanceIds = { "character-hand-001" },
        publicActionTag = "vigilance",
    },
}

local fullyValidatedState = assertOk(
    "battleState",
    runScript("test", "stateSchema", "validateBattleState", baseState, staticData)
)
assert(fullyValidatedState.referencesValidated == true)

local structuralState = assertOk(
    "battleState structural-only",
    runScript("test", "stateSchema", "validateBattleState", baseState, nil)
)
assert(structuralState.referencesValidated == false)

local receiptState = clone(baseState)
local baseFingerprintReport = assertOk(
    "battleState authority fingerprint",
    runScript("test", "stateSchema", "fingerprintBattleState", receiptState, staticData)
)
local baseFingerprint = baseFingerprintReport.fingerprint
assert(baseFingerprint.algorithm == "canonical_poly131_137_receipt_v2")
assert(type(baseFingerprint.length) == "number")
assert(type(baseFingerprint.hashA) == "number")
assert(type(baseFingerprint.hashB) == "number")
local reorderedFingerprint = assertOk(
    "battleState reordered authority fingerprint",
    runScript("test", "stateSchema", "fingerprintBattleState", reverseClone(receiptState), staticData)
).fingerprint
assert(reorderedFingerprint.algorithm == baseFingerprint.algorithm)
assert(reorderedFingerprint.length == baseFingerprint.length)
assert(reorderedFingerprint.hashA == baseFingerprint.hashA)
assert(reorderedFingerprint.hashB == baseFingerprint.hashB)
assertError(
    "battleState fingerprint requires references",
    runScript("test", "stateSchema", "fingerprintBattleState", receiptState, nil),
    "static_references_not_validated",
    "$.staticData"
)

receiptState.turnStartReceipt = {
    schemaVersion = 1,
    kind = "turnStartReceipt",
    turnId = "battle-0001-turn-001",
    turnNumber = 1,
    draws = {
        player = {
            requested = 3,
            drawnInstanceIds = {},
            rngBefore = { seed = 12345, cursor = 0 },
            rngAfter = { seed = 12345, cursor = 0 },
        },
        character = {
            requested = 3,
            drawnInstanceIds = {},
            rngBefore = { seed = 12345, cursor = 0 },
            rngAfter = { seed = 12345, cursor = 0 },
        },
    },
    characterSelection = {
        schemaVersion = 1,
        kind = "characterIntentSelection",
        battleId = "battle-0001",
        turnNumber = 1,
        characterId = "yoo_jiyoung",
        selectionContext = {
            turnNumber = 1,
            player = {
                stealth = 30,
                handCount = 3,
            },
            character = {
                resistance = 30,
                mood = "ignore",
            },
            characterHand = {
                {
                    instanceId = "character-hand-001",
                    cardId = "quiet_warning",
                    actionTag = "vigilance",
                    handPosition = 1,
                },
            },
        },
        candidates = {
            {
                instanceId = "character-hand-001",
                cardId = "quiet_warning",
                actionTag = "vigilance",
                handPosition = 1,
                score = 2,
                projectedPlayerStealth = 28,
                lethal = false,
                weight = 2,
                totals = {
                    recoverResistance = 0,
                    loseStealth = 2,
                    damageResistance = 0,
                    recoverStealth = 0,
                },
                planChargesEvaluated = 0,
            },
        },
        weightedPoolInstanceIds = { "character-hand-001" },
        lethalPriorityApplied = false,
        weightOffset = 0,
        rngBefore = { seed = 12345, cursor = 0 },
        rngAfter = { seed = 12345, cursor = 0 },
        draw = {
            kind = "single",
            totalWeight = 2,
        },
        selectedInstanceId = "character-hand-001",
        selectedCardId = "quiet_warning",
        publicActionTag = "vigilance",
    },
    baseline = {
        stealth = 30,
        resistance = 30,
        mood = "ignore",
    },
    transient = {
        skipRemaining = {
            player = false,
            character = false,
        },
        directMoodChanged = false,
        moodLock = {
            mood = "ignore",
            ["until"] = "turn_end",
            cause = "plan",
        },
    },
    events = {
        {
            eventId = "battle-0001-turn-001-event-001",
            sequence = 1,
            type = "trigger_resolved",
            phase = "turn_start",
            side = "player",
            source = {
                kind = "plan",
                id = "subtle_approach",
                side = "player",
                instanceId = "player-plan-001",
            },
            cause = { kind = "turn_event" },
            payload = {
                inputEventType = "turn_start",
                commandCount = 1,
            },
        },
        {
            eventId = "battle-0001-turn-001-event-002",
            sequence = 2,
            type = "cards_drawn",
            phase = "turn_start",
            side = "player",
            source = {
                kind = "system",
                id = "card_zones",
            },
            cause = { kind = "turn_rule", eventId = "battle-0001-turn-001-event-001" },
            payload = {
                requested = 3,
                drawn = 3,
            },
        },
    },
}
local unsealedReceiptState = receiptState
local sealedReceiptReport = assertOk(
    "seal turnStartReceipt",
    runScript("test", "stateSchema", "sealTurnStartReceipt", unsealedReceiptState, staticData)
)
assert(unsealedReceiptState.turnStartReceipt.authorityFingerprint == nil, "receipt sealing mutated its input state")
receiptState = sealedReceiptReport.state
assert(receiptState ~= unsealedReceiptState
    and receiptState.player ~= unsealedReceiptState.player
    and receiptState.turnStartReceipt.characterSelection ~= unsealedReceiptState.turnStartReceipt.characterSelection,
    "receipt sealing returned aliases into its input state")
local sealedStateHashA = receiptState.turnStartReceipt.authorityFingerprint.hashA
sealedReceiptReport.fingerprint.hashA = (sealedReceiptReport.fingerprint.hashA + 1) % 2147483647
assert(receiptState.turnStartReceipt.authorityFingerprint.hashA == sealedStateHashA,
    "receipt sealing returned sibling aliases between state and fingerprint")
assert(receiptState.turnStartReceipt.authorityFingerprint.algorithm == "canonical_poly131_137_receipt_v2")
local receiptValidated = assertOk(
    "battleState turnStartReceipt",
    runScript("test", "stateSchema", "validateBattleState", receiptState, staticData)
)
assert(receiptValidated.referencesValidated == true)
local structuralReceipt = assertOk(
    "battleState turnStartReceipt structural-only",
    runScript("test", "stateSchema", "validateBattleState", receiptState, nil)
)
assert(structuralReceipt.referencesValidated == false)
local receiptFingerprint = assertOk(
    "battleState fingerprint includes sealed receipt",
    runScript("test", "stateSchema", "fingerprintBattleState", receiptState, staticData)
).fingerprint
assert(receiptFingerprint.algorithm == receiptState.turnStartReceipt.authorityFingerprint.algorithm)
assert(receiptFingerprint.length == receiptState.turnStartReceipt.authorityFingerprint.length)
assert(receiptFingerprint.hashA == receiptState.turnStartReceipt.authorityFingerprint.hashA)
assert(receiptFingerprint.hashB == receiptState.turnStartReceipt.authorityFingerprint.hashB)
assert(receiptFingerprint.length > baseFingerprint.length, "turnStartReceipt was omitted from authority fingerprint")

local alteredFingerprint = clone(receiptState)
alteredFingerprint.turnStartReceipt.authorityFingerprint.hashA =
    (alteredFingerprint.turnStartReceipt.authorityFingerprint.hashA + 1) % 2147483647
assertError(
    "turnStartReceipt altered authority fingerprint",
    runScript("test", "stateSchema", "validateBattleState", alteredFingerprint, staticData),
    "receipt_authority_mismatch",
    "$.turnStartReceipt.authorityFingerprint"
)

local alteredAuthority = clone(receiptState)
alteredAuthority.rng.cursor = alteredAuthority.rng.cursor + 1
assertError(
    "turnStartReceipt altered authority state",
    runScript("test", "stateSchema", "validateBattleState", alteredAuthority, staticData),
    "receipt_authority_mismatch",
    "$.turnStartReceipt.authorityFingerprint"
)

local alteredIntent = clone(receiptState)
alteredIntent.characterIntent = { cardInstanceIds = {} }
assertError(
    "turnStartReceipt altered character intent",
    runScript("test", "stateSchema", "validateBattleState", alteredIntent, staticData),
    "character_selection_intent_mismatch",
    "$.characterIntent"
)

local alteredDrawRequested = clone(receiptState)
alteredDrawRequested.turnStartReceipt.draws.player.requested = 2
assertError(
    "turnStartReceipt altered draw request",
    runScript("test", "stateSchema", "validateBattleState", alteredDrawRequested, staticData),
    "receipt_draw_count_mismatch",
    "$.turnStartReceipt.draws.player.requested"
)

local duplicateDrawId = clone(receiptState)
duplicateDrawId.turnStartReceipt.draws.player.drawnInstanceIds = { "player-001", "player-001" }
assertError(
    "turnStartReceipt duplicate drawn instance",
    runScript("test", "stateSchema", "validateBattleState", duplicateDrawId, staticData),
    "duplicate_id",
    "$.turnStartReceipt.draws.player.drawnInstanceIds[2]"
)

local brokenDrawRng = clone(receiptState)
brokenDrawRng.turnStartReceipt.draws.player.rngAfter.cursor = 1
assertError(
    "turnStartReceipt draw rng discontinuity",
    runScript("test", "stateSchema", "validateBattleState", brokenDrawRng, staticData),
    "receipt_rng_discontinuity",
    "$.turnStartReceipt.draws.character.rngBefore"
)

local brokenSelectionRng = clone(receiptState)
brokenSelectionRng.turnStartReceipt.characterSelection.rngBefore.cursor = 1
brokenSelectionRng.turnStartReceipt.characterSelection.rngAfter.cursor = 1
assertError(
    "turnStartReceipt selection rng discontinuity",
    runScript("test", "stateSchema", "validateBattleState", brokenSelectionRng, staticData),
    "receipt_rng_discontinuity",
    "$.turnStartReceipt.characterSelection.rngBefore"
)

local contradictorySelection = clone(receiptState)
contradictorySelection.turnStartReceipt.characterSelection.selectedInstanceId = nil
assertError(
    "turnStartReceipt contradictory selection fields",
    runScript("test", "stateSchema", "validateBattleState", contradictorySelection, staticData),
    "selection_pass_field_conflict",
    "$.turnStartReceipt.characterSelection"
)

local selectionFunction = clone(receiptState)
selectionFunction.turnStartReceipt.characterSelection.candidates[1].totals.resolve = function() end
assertError(
    "turnStartReceipt selection function",
    runScript("test", "stateSchema", "validateBattleState", selectionFunction, staticData),
    "unsupported_type",
    "$.turnStartReceipt.characterSelection.candidates[1].totals.resolve"
)

local alteredSelectionWeight = clone(receiptState)
alteredSelectionWeight.turnStartReceipt.characterSelection.candidates[1].weight = 1
assertError(
    "turnStartReceipt altered selection weight",
    runScript("test", "stateSchema", "validateBattleState", alteredSelectionWeight, staticData),
    "selection_weight_mismatch",
    "$.turnStartReceipt.characterSelection.candidates[1].weight"
)

local alteredWeightOffset = clone(receiptState)
alteredWeightOffset.turnStartReceipt.characterSelection.weightOffset = 1
assertError(
    "turnStartReceipt altered weight offset",
    runScript("test", "stateSchema", "validateBattleState", alteredWeightOffset, staticData),
    "selection_weight_offset_mismatch",
    "$.turnStartReceipt.characterSelection.weightOffset"
)

local alteredWeightedPool = clone(receiptState)
alteredWeightedPool.turnStartReceipt.characterSelection.weightedPoolInstanceIds = {}
assertError(
    "turnStartReceipt missing weighted pool",
    runScript("test", "stateSchema", "validateBattleState", alteredWeightedPool, staticData),
    "selection_missing_weighted_pool",
    "$.turnStartReceipt.characterSelection.weightedPoolInstanceIds"
)

local alteredSelectionDraw = clone(receiptState)
alteredSelectionDraw.turnStartReceipt.characterSelection.draw.totalWeight = 3
assertError(
    "turnStartReceipt altered draw total",
    runScript("test", "stateSchema", "validateBattleState", alteredSelectionDraw, staticData),
    "draw_weight_mismatch",
    "$.turnStartReceipt.characterSelection.draw.totalWeight"
)

local removedAffinityField = clone(receiptState)
removedAffinityField.turnStartReceipt.characterSelection.candidates[1].affinity = "preferred"
assertError(
    "turnStartReceipt removed affinity field",
    runScript("test", "stateSchema", "validateBattleState", removedAffinityField, staticData),
    "unknown_field",
    "$.turnStartReceipt.characterSelection.candidates[1].affinity"
)

local receiptUnknownField = clone(receiptState)
receiptUnknownField.turnStartReceipt.turnNubmer = receiptUnknownField.turnStartReceipt.turnNumber
assertError(
    "turnStartReceipt unknown field",
    runScript("test", "stateSchema", "validateBattleState", receiptUnknownField, staticData),
    "unknown_field",
    "$.turnStartReceipt.turnNubmer"
)

local receiptTurnMismatch = clone(receiptState)
receiptTurnMismatch.turnStartReceipt.turnNumber = 2
assertError(
    "turnStartReceipt turn mismatch",
    runScript("test", "stateSchema", "validateBattleState", receiptTurnMismatch, staticData),
    "receipt_turn_mismatch",
    "$.turnStartReceipt.turnNumber"
)

local committedReceipt = clone(receiptState)
committedReceipt.lastCommittedTurnId = committedReceipt.turnStartReceipt.turnId
assertError(
    "turnStartReceipt committed turnId",
    runScript("test", "stateSchema", "validateBattleState", committedReceipt, staticData),
    "turn_already_committed",
    "$.turnStartReceipt.turnId"
)

local endedReceipt = clone(receiptState)
endedReceipt.status = "defeat"
endedReceipt.player.stealth = 0
assertError(
    "turnStartReceipt ended state",
    runScript("test", "stateSchema", "validateBattleState", endedReceipt, staticData),
    "receipt_requires_active",
    "$.turnStartReceipt"
)

local unknownBaselineMood = clone(receiptState)
unknownBaselineMood.turnStartReceipt.baseline.mood = "missing_mood"
assertError(
    "turnStartReceipt unknown baseline mood",
    runScript("test", "stateSchema", "validateBattleState", unknownBaselineMood, staticData),
    "unknown_mood",
    "$.turnStartReceipt.baseline.mood"
)

local badSkipReceipt = clone(receiptState)
badSkipReceipt.turnStartReceipt.transient.skipRemaining.character = "false"
assertError(
    "turnStartReceipt invalid skip state",
    runScript("test", "stateSchema", "validateBattleState", badSkipReceipt, staticData),
    "invalid_skip_state",
    "$.turnStartReceipt.transient.skipRemaining.character"
)

local badDirectMoodReceipt = clone(receiptState)
badDirectMoodReceipt.turnStartReceipt.transient.directMoodChanged = 0
assertError(
    "turnStartReceipt invalid direct mood flag",
    runScript("test", "stateSchema", "validateBattleState", badDirectMoodReceipt, staticData),
    "invalid_direct_mood_flag",
    "$.turnStartReceipt.transient.directMoodChanged"
)

local unknownLockMood = clone(receiptState)
unknownLockMood.turnStartReceipt.transient.moodLock.mood = "missing_mood"
assertError(
    "turnStartReceipt unknown lock mood",
    runScript("test", "stateSchema", "validateBattleState", unknownLockMood, staticData),
    "unknown_mood",
    "$.turnStartReceipt.transient.moodLock.mood"
)

local badLockUntil = clone(receiptState)
badLockUntil.turnStartReceipt.transient.moodLock["until"] = "session_end"
assertError(
    "turnStartReceipt invalid lock until",
    runScript("test", "stateSchema", "validateBattleState", badLockUntil, staticData),
    "invalid_mood_lock_until",
    "$.turnStartReceipt.transient.moodLock.until"
)

local badEventSequence = clone(receiptState)
badEventSequence.turnStartReceipt.events[2].sequence = 3
assertError(
    "turnStartReceipt event sequence",
    runScript("test", "stateSchema", "validateBattleState", badEventSequence, staticData),
    "invalid_event_sequence",
    "$.turnStartReceipt.events[2].sequence"
)

local badEventId = clone(receiptState)
badEventId.turnStartReceipt.events[1].eventId = "battle-0001-turn-001-event-002"
assertError(
    "turnStartReceipt event id",
    runScript("test", "stateSchema", "validateBattleState", badEventId, staticData),
    "invalid_event_id",
    "$.turnStartReceipt.events[1].eventId"
)

local badEventPhase = clone(receiptState)
badEventPhase.turnStartReceipt.events[1].phase = "player_card"
assertError(
    "turnStartReceipt event phase",
    runScript("test", "stateSchema", "validateBattleState", badEventPhase, staticData),
    "invalid_event_phase",
    "$.turnStartReceipt.events[1].phase"
)

local badEventType = clone(receiptState)
badEventType.turnStartReceipt.events[1].type = "TriggerResolved"
assertError(
    "turnStartReceipt event type",
    runScript("test", "stateSchema", "validateBattleState", badEventType, staticData),
    "invalid_event_type",
    "$.turnStartReceipt.events[1].type"
)

local badEventSource = clone(receiptState)
badEventSource.turnStartReceipt.events[1].source.kind = "Plan"
assertError(
    "turnStartReceipt event source",
    runScript("test", "stateSchema", "validateBattleState", badEventSource, staticData),
    "invalid_event_source",
    "$.turnStartReceipt.events[1].source.kind"
)

local badEventCause = clone(receiptState)
badEventCause.turnStartReceipt.events[1].cause.kind = "TurnEvent"
assertError(
    "turnStartReceipt event cause",
    runScript("test", "stateSchema", "validateBattleState", badEventCause, staticData),
    "invalid_event_cause",
    "$.turnStartReceipt.events[1].cause.kind"
)

local badEventPayload = clone(receiptState)
badEventPayload.turnStartReceipt.events[1].payload = { "not", "an", "object" }
assertError(
    "turnStartReceipt event payload",
    runScript("test", "stateSchema", "validateBattleState", badEventPayload, staticData),
    "invalid_event_payload",
    "$.turnStartReceipt.events[1].payload"
)

assertError(
    "incomplete static data",
    runScript("test", "stateSchema", "validateBattleState", baseState, { cards = staticData.cards }),
    "invalid_static_data",
    "$"
)

local nanState = clone(baseState)
nanState.player.perkIds = { 0 / 0 }
assert(runScript("test", "stateSchema", "validateBattleState", nanState, staticData).ok == false)

local unsafeRng = clone(baseState)
unsafeRng.rng.seed = 9007199254740992
assertError(
    "unsafe rng seed",
    runScript("test", "stateSchema", "validateBattleState", unsafeRng, staticData),
    "invalid_rng_seed",
    "$.rng.seed"
)

local missingBaseDraw = clone(baseState)
missingBaseDraw.player.baseDrawCount = nil
assertError(
    "missing player base draw",
    runScript("test", "stateSchema", "validateBattleState", missingBaseDraw, staticData),
    "invalid_base_draw_count",
    "$.player.baseDrawCount"
)

local oversizedBaseDraw = clone(baseState)
oversizedBaseDraw.character.baseDrawCount = 6
assertError(
    "character base draw over hand limit",
    runScript("test", "stateSchema", "validateBattleState", oversizedBaseDraw, staticData),
    "draw_exceeds_hand_limit",
    "$.character.baseDrawCount"
)

local oversizedHand = clone(baseState)
table.insert(oversizedHand.cardInstances, {
    instanceId = "player-004", cardId = "play_it_cool", owner = "player", zone = "hand", position = 4,
})
table.insert(oversizedHand.cardInstances, {
    instanceId = "player-005", cardId = "hypnotic_whisper", owner = "player", zone = "hand", position = 5,
})
table.insert(oversizedHand.cardInstances, {
    instanceId = "player-006", cardId = "subtle_approach", owner = "player", zone = "hand", position = 6,
})
assertError(
    "player hand over limit",
    runScript("test", "stateSchema", "validateBattleState", oversizedHand, staticData),
    "hand_limit_exceeded",
    "$.cardInstances"
)

local zeroTurnPlan = clone(baseState)
zeroTurnPlan.character.planSlot.remainingTurns = 0
assertError(
    "occupied plan with zero duration",
    runScript("test", "stateSchema", "validateBattleState", zeroTurnPlan, staticData),
    "invalid_remaining_turns",
    "$.character.planSlot.remainingTurns"
)

local zeroChargePlan = clone(baseState)
zeroChargePlan.character.planSlot.remainingCharges = 0
assertError(
    "occupied plan with zero charges",
    runScript("test", "stateSchema", "validateBattleState", zeroChargePlan, staticData),
    "invalid_remaining_charges",
    "$.character.planSlot.remainingCharges"
)

local cutOffPolicyState = clone(baseState)
cutOffPolicyState.player.planSlot = {
    occupied = true,
    cardInstanceId = "player-cut-off-plan",
    cardId = "cut_off_escape",
    placedTurn = 1,
    durationIncludesPlacementTurn = true,
    remainingTurns = 1,
    remainingCharges = 1,
    revealed = false,
}
table.insert(cutOffPolicyState.cardInstances, {
    instanceId = "player-cut-off-plan",
    cardId = "cut_off_escape",
    owner = "player",
    zone = "plan",
    position = 1,
})
assertOk(
    "cut off escape matching placement-turn policy",
    runScript("test", "stateSchema", "validateBattleState", cutOffPolicyState, staticData)
)

local missingCutOffPolicy = clone(cutOffPolicyState)
missingCutOffPolicy.player.planSlot.durationIncludesPlacementTurn = nil
assertError(
    "cut off escape missing placement-turn policy",
    runScript("test", "stateSchema", "validateBattleState", missingCutOffPolicy, staticData),
    "plan_duration_policy_mismatch",
    "$.player.planSlot.durationIncludesPlacementTurn"
)

local mismatchedCutOffPolicy = clone(cutOffPolicyState)
mismatchedCutOffPolicy.player.planSlot.durationIncludesPlacementTurn = false
assertError(
    "cut off escape mismatched placement-turn policy",
    runScript("test", "stateSchema", "validateBattleState", mismatchedCutOffPolicy, staticData),
    "plan_duration_policy_mismatch",
    "$.player.planSlot.durationIncludesPlacementTurn"
)

local cutOffPolicyViewState = clone(cutOffPolicyState)
cutOffPolicyViewState.selection = { playerCardInstanceIds = {} }
local cutOffPolicyViewDraft = assertOk(
    "cut off escape policy view draft",
    runScript("test", "turnDraft", "newDraft", cutOffPolicyViewState, staticData)
).draft
local cutOffPolicyView = assertOk(
    "cut off escape policy view",
    runScript("test", "viewBuilder", "buildBattleView", cutOffPolicyViewState, staticData, {
        draft = cutOffPolicyViewDraft,
    })
).view
assert(cutOffPolicyView.player.plan.durationIncludesPlacementTurn == nil,
    "battle view leaked the internal plan duration policy")

local orphanPlanState = clone(baseState)
orphanPlanState.character.planSlot = { occupied = false }
assert(runScript("test", "stateSchema", "validateBattleState", orphanPlanState, staticData).ok == false)

assert(runScript("test", "stateSchema", "newBattleState", { player = false }, staticData).ok == false)

local typoSpec = clone(baseState)
typoSpec.turnLimt = typoSpec.turnLimit
typoSpec.turnLimit = nil
assertError(
    "constructor typo",
    runScript("test", "stateSchema", "newBattleState", typoSpec, staticData),
    "unknown_field",
    "$.turnLimt"
)

local hostileState = setmetatable({}, {
    __pairs = function()
        error("PAIR_BOOM")
    end,
})
assertError(
    "metatable state",
    runScript("test", "stateSchema", "validateBattleState", hostileState, staticData),
    "metatable_not_allowed",
    "$"
)
assertError(
    "metatable constructor",
    runScript("test", "stateSchema", "newBattleState", hostileState, staticData),
    "construct_failed",
    "$"
)

local hostileStaticData = setmetatable({}, {
    __index = function()
        error("STATIC_INDEX_BOOM")
    end,
})
assertError(
    "metatable static data",
    runScript("test", "stateSchema", "validateBattleState", baseState, hostileStaticData),
    "invalid_static_data",
    "$"
)

local hostileNestedStaticData = {
    registry = {},
    cards = setmetatable({}, {
        __index = function()
            error("NESTED_STATIC_INDEX_BOOM")
        end,
    }),
    traits = {},
    environments = {},
    characters = {},
}
assertError(
    "nested metatable static data",
    runScript("test", "stateSchema", "validateBattleState", baseState, hostileNestedStaticData),
    "invalid_static_data",
    "$"
)

local structurallyConstructed = assertOk(
    "battleState constructor structural-only",
    runScript("test", "stateSchema", "newBattleState", clone(baseState), nil)
)
assert(structurallyConstructed.referencesValidated == false)
local fullyConstructed = assertOk(
    "battleState constructor with references",
    runScript("test", "stateSchema", "newBattleState", clone(baseState), staticData)
)
assert(fullyConstructed.referencesValidated == true)

local prematureModifier = clone(baseState)
prematureModifier.cardInstances[1].temporaryModifiers = {
    { unexpected = "payload" },
}
assertError(
    "temporary modifier before schema",
    runScript("test", "stateSchema", "validateBattleState", prematureModifier, staticData),
    "temporary_modifier_schema_pending",
    "$.cardInstances[1].temporaryModifiers"
)

local multiplePlayerMain = clone(baseState)
multiplePlayerMain.selection.playerCardInstanceIds = { "player-002", "player-003" }
assertError(
    "multiple player main actions",
    runScript("test", "stateSchema", "validateBattleState", multiplePlayerMain, staticData),
    "multiple_player_main_actions",
    "$.selection.playerCardInstanceIds"
)

local earlyPlayerMain = clone(baseState)
earlyPlayerMain.selection.playerCardInstanceIds = { "player-002", "player-001" }
assertError(
    "player main action order",
    runScript("test", "stateSchema", "validateBattleState", earlyPlayerMain, staticData),
    "player_main_action_not_last",
    "$.selection.playerCardInstanceIds"
)

local descriptionTokens = assertOk(
    "description tokenizer",
    runScript("test", "viewBuilder", "tokenizeTags", cards.read_the_room.description, registry)
).segments
assert(#descriptionTokens == 8, "read_the_room description must have 8 segments")
assert(descriptionTokens[1].id == "observation")
assert(descriptionTokens[3].id == "chain")
assert(descriptionTokens[5].id == "insight")
assert(descriptionTokens[7].id == "plan")

local ruleTokens = assertOk(
    "rule tokenizer",
    runScript("test", "viewBuilder", "tokenizeTags", cards.read_the_room.rules[2], registry)
).segments
assert(#ruleTokens == 3 and ruleTokens[2].id == "plan")

local viewState = clone(baseState)
viewState.selection = { playerCardInstanceIds = {} }
local emptyViewDraft = assertOk(
    "battleView draft",
    runScript("test", "turnDraft", "newDraft", viewState, staticData)
).draft
assertError(
    "selecting View requires draft",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData),
    "missing_turn_draft",
    "$.context.draft"
)
assertError(
    "View context is mutually exclusive",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData, {
        draft = emptyViewDraft,
        pendingTurn = {},
    }),
    "ambiguous_view_context",
    "$.context"
)
assertError(
    "generation lock only accepts true",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData, {
        draft = emptyViewDraft,
        generationLocked = false,
    }),
    "invalid_generation_lock",
    "$.context.generationLocked"
)
assertError(
    "generation lock rejects pending context",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData, {
        pendingTurn = {},
        generationLocked = true,
    }),
    "ambiguous_generation_lock",
    "$.context"
)
local passView = assertOk(
    "empty pass battleView",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData, { draft = emptyViewDraft })
).view
assert(passView.selection.mode == "pass" and passView.selection.canSubmit == true)
assert(passView.selection.count == 0 and passView.selection.hasMainAction == false)
assert(type(passView.interactionToken) == "string"
    and string.match(passView.interactionToken, "^draftv1_%d+_%d+_%d+$") ~= nil)
local endedViewState = clone(viewState)
endedViewState.status = "defeat"
endedViewState.player.stealth = 0
local endedView = assertOk(
    "ended battleView",
    runScript("test", "viewBuilder", "buildBattleView", endedViewState, staticData)
).view
assert(endedView.phase == "ended" and endedView.locked == true)
assert(endedView.interactionToken == nil)
assertError(
    "ended View rejects draft context",
    runScript("test", "viewBuilder", "buildBattleView", endedViewState, staticData, { draft = emptyViewDraft }),
    "ended_view_context",
    "$.context"
)
local viewDraft = clone(emptyViewDraft)
viewDraft = assertOk(
    "battleView register chain",
    runScript("test", "turnDraft", "registerCard", viewState, staticData, viewDraft, "player-001")
).draft
viewDraft = assertOk(
    "battleView register main",
    runScript("test", "turnDraft", "registerCard", viewState, staticData, viewDraft, "player-002")
).draft

local viewStateSnapshot = clone(viewState)
local viewDraftSnapshot = clone(viewDraft)
local view = assertOk(
    "battleView",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData, { draft = viewDraft })
).view
assert(deepEqual(viewState, viewStateSnapshot) and deepEqual(viewDraft, viewDraftSnapshot),
    "battleView build mutated authority state or draft")
local staticEyeName = staticData.cards.read_the_room.name
local detachedView = assertOk(
    "detached battleView",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData, { draft = viewDraft })
).view
detachedView.hand.items[1].name = "OUTPUT_ALIAS_TAMPER"
detachedView.selection.mode = "pass"
assert(deepEqual(viewState, viewStateSnapshot) and deepEqual(viewDraft, viewDraftSnapshot),
    "mutating battleView output changed authority state or draft")
assert(staticData.cards.read_the_room.name == staticEyeName,
    "mutating battleView output changed static data")
assert(view.hand.count == 3)
assert(view.hand.items[1].instanceId == "player-001")
assert(view.hand.items[2].instanceId == "player-002")
assert(view.hand.items[3].instanceId == "player-003")
assert(view.selection.canSubmit == true)
assert(view.selection.mode == "action")
assert(view.hand.items[1].origin == "hand")
assert(view.character.mood.thresholdToCompliance == 5, "reserved must add 1 to compliance threshold")
assert(view.character.mood.thresholdToRejection == 4)
assert(view.character.publicAction.tag.id == "vigilance")
assert(view.character.plan.status == "hidden")
assert(view.character.plan.card == nil)
for _, item in ipairs(view.hand.items) do
    assert(item.finalStealthCost == item.baseStealthCost)
    assert(item.finalResistanceDamage == item.baseResistanceDamage)
end

local generationLockedView = assertOk(
    "generation-locked draft battleView",
    runScript("test", "viewBuilder", "buildBattleView", viewState, staticData, {
        draft = viewDraft,
        generationLocked = true,
    })
).view
assert(generationLockedView.phase == "awaitingOutput" and generationLockedView.locked == true)
assert(generationLockedView.interactionToken == view.interactionToken)
assert(generationLockedView.selection.count == 2 and generationLockedView.selection.canSubmit == false)
assert(generationLockedView.selection.reasonCode == "awaiting_output")
assert(generationLockedView.selection.focusedInstanceId == nil)
for _, item in ipairs(generationLockedView.hand.items) do
    assert(item.playable == false and item.reasonCode == "awaiting_output")
end

local encoded = assertOk(
    "battleView encode",
    runScript("test", "dataBridge", "encode", "battleView", view)
)
assert(not encoded.encoded:find("::", 1, true), "wire must not contain raw ::")
assert(not encoded.encoded:find("{{", 1, true), "wire must not contain raw {{")
assert(not encoded.encoded:find("silent_glare", 1, true), "hidden plan id leaked")
assert(not encoded.encoded:find("quiet_warning", 1, true), "character intent card id leaked")
assert(encoded.encoded:find('"locked":false', 1, true), "boolean type was not preserved")
recordWire("WIRE_MAIN", encoded.encoded)

local reorderedEncoded = assertOk(
    "reordered deterministic encode",
    runScript("test", "dataBridge", "encode", "battleView", reverseClone(view))
)
assert(reorderedEncoded.encoded == encoded.encoded, "equivalent insertion order changed encoding")

local canaryView = clone(view)
local risuPrivateUseCanary = ""
for offset = 0, 7 do
    risuPrivateUseCanary = risuPrivateUseCanary .. string.char(238, 166, 184 + offset)
end
local canaryText = "한글 CBS canary ::tag[contact]:: {{literal}} <b data-x=\"quoted\">& 'markup'</b> (끝):" .. risuPrivateUseCanary
canaryView.environment.description = canaryText
local canaryEncoded = assertOk(
    "CBS punctuation canary encode",
    runScript("test", "dataBridge", "encode", "battleView", canaryView)
)
assert(not canaryEncoded.encoded:find("::", 1, true), "wire exposed raw CBS argument delimiter")
assert(not canaryEncoded.encoded:find("{{", 1, true), "wire exposed raw CBS opening braces")
assert(not canaryEncoded.encoded:find("}}", 1, true), "wire exposed raw CBS closing braces")
assert(not canaryEncoded.encoded:find("<b", 1, true), "wire exposed a raw HTML tag from display text")
assert(canaryEncoded.encoded:find("&lt;b", 1, true), "wire did not entity-escape HTML display text")
for offset = 0, 7 do
    local privateUseCharacter = string.char(238, 166, 184 + offset)
    assert(not canaryEncoded.encoded:find(privateUseCharacter, 1, true),
        "wire exposed a raw Risu private-use escape character")
end
assert(canaryEncoded.encoded:find("&#59832;", 1, true),
    "wire did not entity-escape the first Risu private-use character")
recordWire("WIRE_CANARY", canaryEncoded.encoded)

local emptyStringView = clone(view)
emptyStringView.environment.description = ""
local emptyStringEncoded = assertOk(
    "empty string encode",
    runScript("test", "dataBridge", "encode", "battleView", emptyStringView)
)
recordWire("WIRE_EMPTY_STRING", emptyStringEncoded.encoded)

local preciseNumberView = clone(view)
preciseNumberView.turn.number = 123456789012345
preciseNumberView.turn.limit = 123456789012345
preciseNumberView.turn.remaining = 1
local preciseNumberEncoded = assertOk(
    "precise number encode",
    runScript("test", "dataBridge", "encode", "battleView", preciseNumberView)
)
recordWire("WIRE_PRECISE_NUMBER", preciseNumberEncoded.encoded)

for _ = 1, 10 do
    local repeated = assertOk(
        "deterministic encode",
        runScript("test", "dataBridge", "encode", "battleView", view)
    )
    assert(repeated.encoded == encoded.encoded, "encoding is not deterministic")
end

local pendingBefore = clone(receiptState)
pendingBefore.selection = { playerCardInstanceIds = {} }
pendingBefore.turnStartReceipt.authorityFingerprint = nil
table.insert(pendingBefore.cardInstances, {
    instanceId = "player-preview-001",
    cardId = "play_it_cool",
    owner = "player",
    zone = "deck",
    position = 1,
})
pendingBefore = assertOk(
    "seal pending authority",
    runScript("test", "stateSchema", "sealTurnStartReceipt", pendingBefore, staticData)
).state
local pendingEmptyDraft = assertOk(
    "pending draft",
    runScript("test", "turnDraft", "newDraft", pendingBefore, staticData)
).draft
local pendingDraft = clone(pendingEmptyDraft)
pendingDraft = assertOk(
    "pending register read the room",
    runScript("test", "turnDraft", "registerCard", pendingBefore, staticData, pendingDraft, "player-001")
).draft
assert(pendingDraft.preview.availableDrawnInstanceIds[1] == "player-preview-001")
local pendingChainDraft = clone(pendingDraft)
local chainPassView = assertOk(
    "read the room preview View",
    runScript("test", "viewBuilder", "buildBattleView", pendingBefore, staticData, { draft = pendingChainDraft })
).view
assert(chainPassView.selection.mode == "chain_pass" and chainPassView.selection.canSubmit == true)
assert(chainPassView.hand.items[4].instanceId == "player-preview-001"
    and chainPassView.hand.items[4].origin == "preview"
    and chainPassView.hand.items[4].selected == false,
    "read_the_room preview was not appended to the selectable View")
pendingDraft = assertOk(
    "pending register preview action",
    runScript("test", "turnDraft", "registerCard", pendingBefore, staticData, pendingDraft, "player-preview-001")
).draft
local selectedPreviewView = assertOk(
    "selected preview View",
    runScript("test", "viewBuilder", "buildBattleView", pendingBefore, staticData, { draft = pendingDraft })
).view
assert(selectedPreviewView.selection.mode == "action" and selectedPreviewView.selection.canSubmit == true)
assert(selectedPreviewView.selection.focusedInstanceId == "player-preview-001")
assert(selectedPreviewView.hand.items[4].selected == true
    and selectedPreviewView.hand.items[4].selectionOrder == 2)
local pendingProjection = assertOk(
    "pending projection",
    runScript("test", "turnDraft", "project", pendingBefore, staticData, pendingDraft)
).projection
local pendingProjectionReceipt = assertOk(
    "pending projection receipt",
    runScript("test", "turnDraft", "sealProjection", pendingBefore, staticData, pendingProjection)
).receipt
assert(pendingProjectionReceipt.preview == nil and pendingProjectionReceipt.workingState == nil)

local afterState = clone(pendingBefore)
afterState.turnStartReceipt = nil
afterState.selection = { playerCardInstanceIds = {} }
afterState.characterIntent = { cardInstanceIds = {} }
afterState.character.resistance = 987654
afterState.turnNumber = 2
afterState.lastCommittedTurnId = "battle-0001-turn-001"
local pending = {
    schemaVersion = 1,
    kind = "pendingTurn",
    battleId = "battle-0001",
    turnId = "battle-0001-turn-001",
    status = "awaitingOutput",
    beforeState = clone(pendingBefore),
    projectionReceipt = clone(pendingProjectionReceipt),
    selectedCards = {
        player = { "player-001", "player-preview-001" },
        character = { "character-hand-001" },
    },
    turnResult = {
        events = { { type = "internal_test" } },
        publicResult = { schemaVersion = 1, events = { { type = "public_test" } } },
        llmEvent = { schemaVersion = 1, events = { { type = "llm_test" } } },
    },
    afterState = afterState,
}
pending = assertOk(
    "pendingTurn integrity constructor",
    runScript("test", "stateSchema", "newPendingTurn", pending, staticData)
).value
assert(type(pending.integrity) == "table"
    and pending.integrity.algorithm == "canonical_poly131_137_pending_v1",
    "pendingTurn integrity receipt missing")

local pendingShape = assertOk("pendingTurn", runScript("test", "stateSchema", "validatePendingTurn", pending, staticData))
assert(pendingShape.projectionReplayValidated == false, "stateSchema claimed semantic projection replay")
assertOk(
    "pending projection semantic replay",
    runScript("test", "turnDraft", "validateProjectionReceipt", pending.beforeState, staticData, pending.projectionReceipt)
)
local structurallyConstructedPending = assertOk(
    "pendingTurn constructor structural-only",
    runScript("test", "stateSchema", "newPendingTurn", clone(pending), nil)
)
assert(structurallyConstructedPending.referencesValidated == false)
local fullyConstructedPending = assertOk(
    "pendingTurn constructor with references",
    runScript("test", "stateSchema", "newPendingTurn", clone(pending), staticData)
)
assert(fullyConstructedPending.referencesValidated == true)
assert(fullyConstructedPending.projectionReplayValidated == false)

local afterReceiptPresent = clone(pending)
afterReceiptPresent.afterState.turnStartReceipt = clone(pending.beforeState.turnStartReceipt)
assertError(
    "pending afterState clears turn receipt",
    runScript("test", "stateSchema", "validatePendingTurn", afterReceiptPresent, staticData),
    "pending_after_turn_receipt_present",
    "$.afterState.turnStartReceipt"
)

local afterSelectionPresent = clone(pending)
afterSelectionPresent.afterState.selection.playerCardInstanceIds = { "player-002" }
assertError(
    "pending afterState clears player selection",
    runScript("test", "stateSchema", "validatePendingTurn", afterSelectionPresent, staticData),
    "pending_after_selection_not_empty",
    "$.afterState.selection.playerCardInstanceIds"
)

local afterIntentPresent = clone(pending)
afterIntentPresent.afterState.characterIntent = {
    cardInstanceIds = { "character-hand-001" },
    publicActionTag = "vigilance",
}
assertError(
    "pending afterState clears character intent",
    runScript("test", "stateSchema", "validatePendingTurn", afterIntentPresent, staticData),
    "pending_after_character_intent_not_empty",
    "$.afterState.characterIntent.cardInstanceIds"
)
assertError(
    "pending afterState clears public action",
    runScript("test", "stateSchema", "validatePendingTurn", afterIntentPresent, staticData),
    "pending_after_public_action_present",
    "$.afterState.characterIntent.publicActionTag"
)

local afterRngBeforeProjection = clone(pending)
afterRngBeforeProjection.projectionReceipt.projectedRng.cursor =
    afterRngBeforeProjection.afterState.rng.cursor + 1
assertError(
    "pending after RNG covers projection",
    runScript("test", "stateSchema", "validatePendingTurn", afterRngBeforeProjection, staticData),
    "after_rng_before_projection",
    "$.afterState.rng.cursor"
)

local fingerprintTamperedPending = clone(pending)
fingerprintTamperedPending.beforeState.cardInstances[2].temporaryModifiers = {}
fingerprintTamperedPending.beforeState.turnStartReceipt.authorityFingerprint = nil
fingerprintTamperedPending.beforeState = assertOk(
    "reseal harmlessly changed pending authority",
    runScript("test", "stateSchema", "sealTurnStartReceipt", fingerprintTamperedPending.beforeState, staticData)
).state
assertError(
    "pending source fingerprint covers optional state fields",
    runScript("test", "stateSchema", "validatePendingTurn", fingerprintTamperedPending, staticData),
    "projection_fingerprint_mismatch",
    "$.projectionReceipt.source.fingerprint"
)

local skippedTurn = clone(pending)
skippedTurn.afterState.turnNumber = skippedTurn.beforeState.turnNumber + 2
assertError(
    "pending turn skip",
    runScript("test", "stateSchema", "validatePendingTurn", skippedTurn, staticData),
    "turn_number_skipped",
    "$.afterState.turnNumber"
)

local endedBefore = clone(pending)
endedBefore.beforeState.status = "defeat"
endedBefore.beforeState.turnNumber = endedBefore.beforeState.turnLimit
assert(runScript("test", "stateSchema", "validatePendingTurn", endedBefore, staticData).ok == false)

local nonEmptyPendingAuthority = clone(pending)
nonEmptyPendingAuthority.beforeState.selection.playerCardInstanceIds = { "player-001" }
assertError(
    "pending authority selection must stay empty",
    runScript("test", "stateSchema", "validatePendingTurn", nonEmptyPendingAuthority, staticData),
    "pending_authority_selection_not_empty",
    "$.beforeState.selection.playerCardInstanceIds"
)

local pendingTurnMismatch = clone(pending)
pendingTurnMismatch.turnId = "battle-0001-turn-999"
pendingTurnMismatch.afterState.lastCommittedTurnId = pendingTurnMismatch.turnId
assertError(
    "pending turnId receipt mismatch",
    runScript("test", "stateSchema", "validatePendingTurn", pendingTurnMismatch, staticData),
    "pending_turn_id_mismatch",
    "$.turnId"
)

local pendingReceiptRngTamper = clone(pending)
pendingReceiptRngTamper.projectionReceipt.projectedRng.cursor =
    pendingReceiptRngTamper.projectionReceipt.projectedRng.cursor + 1
pendingReceiptRngTamper.afterState.rng.cursor =
    pendingReceiptRngTamper.projectionReceipt.projectedRng.cursor
pendingReceiptRngTamper = assertOk(
    "reseal pending semantic receipt tamper",
    runScript("test", "stateSchema", "newPendingTurn", pendingReceiptRngTamper, staticData)
).value
assertOk(
    "pending shape permits deferred semantic replay",
    runScript("test", "stateSchema", "validatePendingTurn", pendingReceiptRngTamper, staticData)
)
assertError(
    "pending semantic receipt tamper",
    runScript("test", "turnDraft", "validateProjectionReceipt", pendingReceiptRngTamper.beforeState, staticData, pendingReceiptRngTamper.projectionReceipt),
    "projection_receipt_mismatch",
    "$.receipt"
)
assertError(
    "awaiting View rejects semantic receipt tamper",
    runScript("test", "viewBuilder", "buildBattleView", pendingBefore, staticData, {
        pendingTurn = pendingReceiptRngTamper,
    }),
    "projection_receipt_mismatch"
)

local alternateAuthority = clone(pendingBefore)
alternateAuthority.cardInstances[2].temporaryModifiers = {}
alternateAuthority.turnStartReceipt.authorityFingerprint = nil
alternateAuthority = assertOk(
    "seal alternate awaiting authority",
    runScript("test", "stateSchema", "sealTurnStartReceipt", alternateAuthority, staticData)
).state
assertError(
    "awaiting View rejects another valid authority",
    runScript("test", "viewBuilder", "buildBattleView", alternateAuthority, staticData, { pendingTurn = pending }),
    "projection_receipt_stale"
)

local pendingBeforeSnapshot = clone(pendingBefore)
local pendingSnapshot = clone(pending)
local waitingView = assertOk(
    "awaiting battleView",
    runScript("test", "viewBuilder", "buildBattleView", pendingBefore, staticData, { pendingTurn = pending })
).view
assert(waitingView.phase == "awaitingOutput" and waitingView.locked == true)
assert(waitingView.interactionToken == nil)
assert(waitingView.character.resistance == 30, "afterState leaked before output")
assert(waitingView.selection.mode == "action" and waitingView.selection.focusedInstanceId == nil)
assert(waitingView.hand.items[4].instanceId == "player-preview-001"
    and waitingView.hand.items[4].origin == "preview"
    and waitingView.hand.items[4].selected == true
    and waitingView.hand.items[4].selectionOrder == 2,
    "awaiting View did not replay the selected preview card")
local repeatedWaitingView = assertOk(
    "deterministic awaiting battleView",
    runScript("test", "viewBuilder", "buildBattleView", pendingBefore, staticData, { pendingTurn = pending })
).view
assert(deepEqual(waitingView, repeatedWaitingView), "awaiting View replay was not deterministic")
assert(deepEqual(pendingBefore, pendingBeforeSnapshot) and deepEqual(pending, pendingSnapshot),
    "awaiting View build mutated authority state or pendingTurn")
repeatedWaitingView.hand.items[1].name = "PENDING_OUTPUT_ALIAS_TAMPER"
repeatedWaitingView.selection.mode = "pass"
assert(deepEqual(pendingBefore, pendingBeforeSnapshot) and deepEqual(pending, pendingSnapshot),
    "mutating awaiting View output changed authority state or pendingTurn")
assert(staticData.cards.read_the_room.name == staticEyeName,
    "mutating awaiting View output changed static data")
for _, item in ipairs(waitingView.hand.items) do
    assert(item.playable == false and item.reasonCode == "awaiting_output")
end
local waitingEncoded = assertOk(
    "awaiting encode",
    runScript("test", "dataBridge", "encode", "battleView", waitingView)
).encoded
assert(not waitingEncoded:find("987654", 1, true), "afterState value leaked into waiting View")
assert(not waitingEncoded:find("internal_test", 1, true), "pending internal event leaked into View")
assert(not waitingEncoded:find("llm_test", 1, true), "pending LLM event leaked into View")
assert(not waitingEncoded:find("character-hand-001", 1, true), "character intent instance leaked into waiting View")
assert(not waitingEncoded:find("projectedRng", 1, true), "projection RNG receipt leaked into waiting View")

local passProjection = assertOk(
    "pending pass projection",
    runScript("test", "turnDraft", "project", pendingBefore, staticData, pendingEmptyDraft)
).projection
local passReceipt = assertOk(
    "pending pass receipt",
    runScript("test", "turnDraft", "sealProjection", pendingBefore, staticData, passProjection)
).receipt
local passPending = clone(pending)
passPending.projectionReceipt = passReceipt
passPending.selectedCards.player = {}
passPending = assertOk(
    "seal pass pending",
    runScript("test", "stateSchema", "newPendingTurn", passPending, staticData)
).value
local waitingPassView = assertOk(
    "awaiting pass battleView",
    runScript("test", "viewBuilder", "buildBattleView", pendingBefore, staticData, { pendingTurn = passPending })
).view
assert(waitingPassView.selection.mode == "pass"
    and waitingPassView.selection.canSubmit == false
    and waitingPassView.selection.reasonCode == "awaiting_output")

local chainProjection = assertOk(
    "pending chain-pass projection",
    runScript("test", "turnDraft", "project", pendingBefore, staticData, pendingChainDraft)
).projection
local chainReceipt = assertOk(
    "pending chain-pass receipt",
    runScript("test", "turnDraft", "sealProjection", pendingBefore, staticData, chainProjection)
).receipt
local chainPending = clone(pending)
chainPending.projectionReceipt = chainReceipt
chainPending.selectedCards.player = { "player-001" }
chainPending = assertOk(
    "seal chain pending",
    runScript("test", "stateSchema", "newPendingTurn", chainPending, staticData)
).value
local waitingChainView = assertOk(
    "awaiting chain-pass battleView",
    runScript("test", "viewBuilder", "buildBattleView", pendingBefore, staticData, { pendingTurn = chainPending })
).view
assert(waitingChainView.selection.mode == "chain_pass"
    and waitingChainView.selection.canSubmit == false
    and waitingChainView.selection.reasonCode == "awaiting_output")

local revealedState = clone(viewState)
revealedState.character.planSlot.revealed = true
local revealedDraft = assertOk(
    "revealed plan draft",
    runScript("test", "turnDraft", "newDraft", revealedState, staticData)
).draft
local revealedView = assertOk(
    "revealed plan View",
    runScript("test", "viewBuilder", "buildBattleView", revealedState, staticData, { draft = revealedDraft })
).view
assert(revealedView.character.plan.status == "revealed")
assert(revealedView.character.plan.card.cardId == "silent_glare")
local revealedEncoded = assertOk(
    "revealed plan encode",
    runScript("test", "dataBridge", "encode", "battleView", revealedView)
).encoded
assert(not revealedEncoded:find("remainingCharges", 1, true), "plan charges leaked")
assert(not revealedEncoded:find("actorThought", 1, true), "narration leaked")
assert(not revealedEncoded:find("mechanismData", 1, true), "mechanismData leaked")

local badExtra = clone(view)
badExtra.privateProfile = { canary = "PRIVATE_CANARY" }
assertError(
    "unknown View field",
    runScript("test", "viewBuilder", "validateBattleView", badExtra),
    "unknown_field",
    "$.privateProfile"
)

local badOrigin = clone(view)
badOrigin.hand.items[1].origin = "deck"
assertError(
    "invalid View card origin",
    runScript("test", "viewBuilder", "validateBattleView", badOrigin),
    "invalid_card_origin",
    "$.hand.items[1].origin"
)

local badMode = clone(view)
badMode.selection.mode = "legacy"
assertError(
    "invalid View selection mode",
    runScript("test", "viewBuilder", "validateBattleView", badMode),
    "invalid_selection_value",
    "$.selection"
)

local missingFocus = clone(view)
missingFocus.selection.focusedInstanceId = "missing-card-001"
assertError(
    "focused View card must be visible",
    runScript("test", "viewBuilder", "validateBattleView", missingFocus),
    "focused_card_not_visible",
    "$.selection.focusedInstanceId"
)

local lockedFocus = clone(waitingView)
lockedFocus.selection.focusedInstanceId = "player-001"
assertError(
    "awaiting View drops focus",
    runScript("test", "viewBuilder", "validateBattleView", lockedFocus),
    "locked_view_focus",
    "$.selection.focusedInstanceId"
)
assertError(
    "bridge unknown View field",
    runScript("test", "dataBridge", "encode", "battleView", badExtra),
    "unknown_field",
    "$.privateProfile"
)

local inconsistentSubmit = clone(view)
inconsistentSubmit.selection.canSubmit = false
assertError(
    "submit summary consistency",
    runScript("test", "viewBuilder", "validateBattleView", inconsistentSubmit),
    "submit_summary_mismatch",
    "$.selection.canSubmit"
)

local inconsistentPlayable = clone(view)
inconsistentPlayable.hand.items[2].playable = false
inconsistentPlayable.hand.items[2].reasonCode = "insufficient_stealth"
assertError(
    "selected playable consistency",
    runScript("test", "viewBuilder", "validateBattleView", inconsistentPlayable),
    "submit_summary_mismatch",
    "$.selection.canSubmit"
)

local inconsistentMain = clone(view)
inconsistentMain.selection.hasMainAction = false
inconsistentMain.selection.canSubmit = false
inconsistentMain.selection.reasonCode = "missing_main_action"
assertError(
    "main action summary consistency",
    runScript("test", "viewBuilder", "validateBattleView", inconsistentMain),
    "main_action_summary_mismatch",
    "$.selection.hasMainAction"
)

local hostileView = setmetatable({}, {
    __pairs = function()
        error("VIEW_PAIR_BOOM")
    end,
})
assertError(
    "metatable View",
    runScript("test", "viewBuilder", "validateBattleView", hostileView),
    "metatable_not_allowed",
    "$"
)

local badFunction = clone(view)
badFunction.hand.items[1].resolve = function() end
assert(runScript("test", "dataBridge", "encode", "battleView", badFunction).ok == false)

local badCycle = clone(view)
badCycle.cycle = badCycle
assert(runScript("test", "dataBridge", "encode", "battleView", badCycle).ok == false)

local badSparse = clone(view)
badSparse.hand.items = {
    [1] = badSparse.hand.items[1],
    [3] = badSparse.hand.items[3],
}
assertError(
    "sparse bridge array",
    runScript("test", "dataBridge", "encode", "battleView", badSparse),
    "sparse_array",
    "$.hand.items"
)

local badMixed = clone(view)
badMixed.hand.items.marker = "mixed"
assertError(
    "mixed bridge table",
    runScript("test", "dataBridge", "encode", "battleView", badMixed),
    "mixed_table",
    "$.hand.items"
)

local publishedResult = assertOk(
    "publish",
    runScript("test", "dataBridge", "publish", "battleView", view)
)
assert(publishCount == 1 and published.battleView == publishedResult.encoded)
local previousPublished = published.battleView
assert(runScript("test", "dataBridge", "publish", "battleView", badExtra).ok == false)
assert(publishCount == 1 and published.battleView == previousPublished, "failed publish changed chatVar")
assertError(
    "canonical bridge requires a function capability",
    runScript("test", "dataBridge", "_publishCanonical", "battleView", view, "dataBridgeCanonicalV1"),
    "internal_action_denied",
    "$.action"
)
assert(publishCount == 1 and published.battleView == previousPublished,
    "denied canonical publish changed chatVar")
local canonicalPublished = assertOk(
    "capability-gated canonical publish",
    runScript("test", "dataBridge", "_publishCanonical", "battleView", view, function(purpose, viewName)
        return purpose == "dataBridgeCanonicalV1" and viewName == "battleView"
    end)
)
assert(publishCount == 2 and canonicalPublished.encoded == publishedResult.encoded
    and published.battleView == publishedResult.encoded,
    "canonical publish changed the validated View wire")

local playerCardIds = {
    "read_the_room",
    "accidental_brush",
    "pin_down",
    "play_it_cool",
    "hypnotic_whisper",
}
for _, handSize in ipairs({ 0, 1, 3, 5 }) do
    local handState = clone(baseState)
    handState.cardInstances = {
        { instanceId = "character-plan-001", cardId = "silent_glare", owner = "character", zone = "plan", position = 1 },
        { instanceId = "character-hand-001", cardId = "quiet_warning", owner = "character", zone = "hand", position = 1 },
    }
    handState.selection.playerCardInstanceIds = {}
    for index = 1, handSize do
        table.insert(handState.cardInstances, {
            instanceId = string.format("player-hand-%03d", index),
            cardId = playerCardIds[index],
            owner = "player",
            zone = "hand",
            position = index,
        })
    end
    local handDraft = assertOk(
        "hand draft " .. handSize,
        runScript("test", "turnDraft", "newDraft", handState, staticData)
    ).draft
    local sizedView = assertOk(
        "hand size " .. handSize,
        runScript("test", "viewBuilder", "buildBattleView", handState, staticData, { draft = handDraft })
    ).view
    assert(sizedView.hand.count == handSize and #sizedView.hand.items == handSize)
    local sizedEncoded = assertOk(
        "hand encode " .. handSize,
        runScript("test", "dataBridge", "encode", "battleView", sizedView)
    )
    recordWire("WIRE_HAND_" .. handSize, sizedEncoded.encoded)
end

local wirePath = os.getenv("RISU_LOCAL_CONTRACT_WIRE_PATH")
if wirePath then
    local wireFile = assert(io.open(wirePath, "wb"))
    wireFile:write(table.concat(wireMarkers, "\n"), "\n")
    wireFile:close()
else
    for _, marker in ipairs(wireMarkers) do
        print(marker)
    end
end

print("local-contract-check: ok")
print("note: actual RisuAI lore/CBS integration is not covered")
'@

Push-Location $projectRoot
$firstWirePath = $null
$secondWirePath = $null
$luaTestPath = $null
try {
    $firstWirePath = [IO.Path]::GetTempFileName()
    $secondWirePath = [IO.Path]::GetTempFileName()
    $luaTestPath = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($luaTestPath, $luaTest, [Text.UTF8Encoding]::new($false))
    $env:RISU_LOCAL_CONTRACT_LUA_PATH = $luaTestPath
    $env:RISU_LOCAL_CONTRACT_WIRE_PATH = $firstWirePath

    $firstOutput = @(& $luaHost -e 'assert(loadfile(os.getenv([[RISU_LOCAL_CONTRACT_LUA_PATH]]),[[t]],_G))()' 2>&1)
    $firstExitCode = $LASTEXITCODE
    if ($firstExitCode -ne 0) {
        $firstOutput | ForEach-Object { Write-Output $_ }
        exit $firstExitCode
    }
    $firstWireOutput = [IO.File]::ReadAllLines($firstWirePath, [Text.UTF8Encoding]::new($false))

    $env:RISU_LOCAL_CONTRACT_WIRE_PATH = $secondWirePath
    $secondOutput = @(& $luaHost -e 'assert(loadfile(os.getenv([[RISU_LOCAL_CONTRACT_LUA_PATH]]),[[t]],_G))()' 2>&1)
    $secondExitCode = $LASTEXITCODE
    if ($secondExitCode -ne 0) {
        $secondOutput | ForEach-Object { Write-Output $_ }
        exit $secondExitCode
    }
    $secondWireOutput = [IO.File]::ReadAllLines($secondWirePath, [Text.UTF8Encoding]::new($false))

    function Get-WireMarker {
        param(
            [object[]]$Output,
            [string]$Name
        )

        $prefix = "$Name="
        $matches = @($Output | Where-Object { ([string]$_).StartsWith($prefix) })
        if ($matches.Count -ne 1) {
            throw "wire marker $Name must appear exactly once"
        }
        return ([string]$matches[0]).Substring($prefix.Length)
    }

    function Assert-Contract {
        param(
            [bool]$Condition,
            [string]$Message
        )

        if (-not $Condition) {
            throw "wire contract failed: $Message"
        }
    }

    $markerNames = @(
        'WIRE_MAIN',
        'WIRE_CANARY',
        'WIRE_EMPTY_STRING',
        'WIRE_PRECISE_NUMBER',
        'WIRE_HAND_0',
        'WIRE_HAND_1',
        'WIRE_HAND_3',
        'WIRE_HAND_5'
    )
    $firstMarkers = @{}
    foreach ($markerName in $markerNames) {
        $firstMarkers[$markerName] = Get-WireMarker -Output $firstWireOutput -Name $markerName
        $secondWire = Get-WireMarker -Output $secondWireOutput -Name $markerName
        Assert-Contract ($firstMarkers[$markerName] -ceq $secondWire) "$markerName changed across Lua processes"
    }

    $root = ConvertFrom-Json -InputObject $firstMarkers.WIRE_MAIN
    Assert-Contract ($root.locked -is [bool] -and $root.locked -eq $false) 'root false boolean was not preserved'
    Assert-Contract ($root.schemaVersion -isnot [string] -and $root.schemaVersion -eq 1) 'root number was not preserved'

    $turn = ConvertFrom-Json -InputObject $root.turn
    Assert-Contract ($turn.number -isnot [string] -and $turn.number -eq 1) 'nested number was not preserved'

    $hand = ConvertFrom-Json -InputObject $root.hand
    [object[]]$itemNodes = ConvertFrom-Json -InputObject $hand.items
    Assert-Contract ($itemNodes.Count -eq 3) 'main wire hand count changed'
    $items = @($itemNodes | ForEach-Object { ConvertFrom-Json -InputObject ([string]$_) })
    Assert-Contract ($items[0].instanceId -ceq 'player-001') 'first hand item order changed'
    Assert-Contract ($items[1].instanceId -ceq 'player-002') 'second hand item order changed'
    Assert-Contract ($items[2].instanceId -ceq 'player-003') 'third hand item order changed'
    Assert-Contract ($items[0].baseStealthCost -isnot [string] -and $items[0].baseStealthCost -eq 0) 'numeric zero became a string or changed'
    Assert-Contract ($items[0].playable -is [bool] -and $items[0].playable -eq $true) 'card true boolean was not preserved'
    Assert-Contract ($items[0].selected -is [bool] -and $items[0].selected -eq $true) 'selected true boolean was not preserved'

    [object[]]$segmentNodes = ConvertFrom-Json -InputObject $items[0].descriptionSegments
    $segments = @($segmentNodes | ForEach-Object { ConvertFrom-Json -InputObject ([string]$_) })
    Assert-Contract ($segments.Count -eq 8) 'description segment count changed after wire decode'
    Assert-Contract ($segments[0].kind -ceq 'tag' -and $segments[0].id -ceq 'observation') 'first description tag changed'
    Assert-Contract ($segments[1].kind -ceq 'text' -and $segments[1].value.Contains('행동입니다.')) 'Korean description text changed'
    Assert-Contract ($segments[2].id -ceq 'chain' -and $segments[4].id -ceq 'insight' -and $segments[6].id -ceq 'plan') 'description tag order changed'

    $canaryRoot = ConvertFrom-Json -InputObject $firstMarkers.WIRE_CANARY
    $canaryEnvironment = ConvertFrom-Json -InputObject $canaryRoot.environment
    $risuPrivateUseCanary = [string]::Concat(@(0xE9B8..0xE9BF | ForEach-Object { [char]$_ }))
    $expectedCanary = '한글 CBS canary ::tag[contact]:: {{literal}} <b data-x="quoted">& ''markup''</b> (끝):' + $risuPrivateUseCanary
    Assert-Contract (-not $canaryEnvironment.description.Contains('<b')) 'HTML canary remained active markup after wire decode'
    Assert-Contract (-not $canaryEnvironment.description.Contains('{{literal}}')) 'CBS canary remained active syntax after wire decode'
    Assert-Contract ([System.Net.WebUtility]::HtmlDecode($canaryEnvironment.description) -ceq $expectedCanary) 'HTML/CBS entity text did not render back to the original canary'

    $emptyRoot = ConvertFrom-Json -InputObject $firstMarkers.WIRE_EMPTY_STRING
    $emptyEnvironment = ConvertFrom-Json -InputObject $emptyRoot.environment
    Assert-Contract ($emptyEnvironment.description -is [string] -and $emptyEnvironment.description -ceq '') 'empty string was not preserved'

    $preciseRoot = ConvertFrom-Json -InputObject $firstMarkers.WIRE_PRECISE_NUMBER
    $preciseTurn = ConvertFrom-Json -InputObject $preciseRoot.turn
    Assert-Contract ($preciseTurn.number -eq 123456789012345) '15-digit integer lost precision in the wire encoder'

    foreach ($handSize in @(0, 1, 3, 5)) {
        $sizedRoot = ConvertFrom-Json -InputObject $firstMarkers["WIRE_HAND_$handSize"]
        $sizedHand = ConvertFrom-Json -InputObject $sizedRoot.hand
        [object[]]$sizedNodes = ConvertFrom-Json -InputObject $sizedHand.items
        Assert-Contract ($sizedNodes.Count -eq $handSize) "hand size $handSize changed after wire decode"
        if ($handSize -eq 0) {
            Assert-Contract ($sizedHand.items -ceq '[]') 'empty hand was not encoded as an empty array node'
        }
        for ($index = 0; $index -lt $handSize; $index++) {
            $sizedItem = ConvertFrom-Json -InputObject ([string]$sizedNodes[$index])
            $expectedId = 'player-hand-{0:d3}' -f ($index + 1)
            Assert-Contract ($sizedItem.instanceId -ceq $expectedId) "hand size $handSize order changed at index $index"
        }
    }

    $firstOutput |
        Where-Object { -not ([string]$_).StartsWith('WIRE_') } |
        ForEach-Object { Write-Output $_ }
}
finally {
    Remove-Item Env:RISU_LOCAL_CONTRACT_LUA_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:RISU_LOCAL_CONTRACT_WIRE_PATH -ErrorAction SilentlyContinue
    if ($firstWirePath) {
        Remove-Item -LiteralPath $firstWirePath -Force -ErrorAction SilentlyContinue
    }
    if ($secondWirePath) {
        Remove-Item -LiteralPath $secondWirePath -Force -ErrorAction SilentlyContinue
    }
    if ($luaTestPath) {
        Remove-Item -LiteralPath $luaTestPath -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
