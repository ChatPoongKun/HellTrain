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
    error(label .. " failed: " .. table.concat(messages, " | "))
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        failReport(label, report)
    end
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    return report
end

local function assertFails(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    if expectedCode ~= nil then
        for _, item in ipairs(report.errors or {}) do
            if item.code == expectedCode then
                return
            end
        end
        failReport(label .. " (missing " .. expectedCode .. ")", report)
    end
end

local staticData = assertOk(
    "static load",
    runScript("turn-event-projector-check", "staticData", "loadAll")
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

local function planSlot(instanceId, cardId, options)
    options = options or {}
    return {
        occupied = true,
        cardInstanceId = instanceId,
        cardId = cardId,
        placedTurn = options.placedTurn or 1,
        remainingTurns = options.remainingTurns or 1,
        remainingCharges = options.remainingCharges or 1,
        revealed = options.revealed == true,
    }
end

local function makeState(options)
    options = options or {}
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = assert(options.battleId),
        status = "active",
        turnNumber = options.turnNumber or 1,
        turnLimit = options.turnLimit or 10,
        environmentId = "uncrowded",
        rng = { seed = options.seed or 20260718, cursor = 0 },
        player = {
            stealth = options.stealth or 30,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = {},
            planSlot = clone(options.playerPlan or { occupied = false }),
        },
        character = {
            characterId = "yoo_jiyoung",
            resistance = options.resistance or 30,
            mood = options.mood or "ignore",
            traitIds = options.traitIds or { "reserved" },
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = clone(options.characterPlan or { occupied = false }),
        },
        cardInstances = clone(options.cards or {}),
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local function assertJsonSafe(label, value, active)
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean" or valueType == "string" then return end
    if valueType == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, label .. " has non-finite number")
        return
    end
    assert(valueType == "table", label .. " has non-JSON value")
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
            assert(type(key) == "string", label .. " has non-string object key")
            stringCount = stringCount + 1
        end
        assertJsonSafe(label .. "." .. tostring(key), item, active)
    end
    assert(numericCount == 0 or stringCount == 0, label .. " mixes object and array keys")
    assert(numericCount == 0 or numericCount == maximum, label .. " is sparse")
    active[value] = nil
end

local PUBLIC_TYPES = {
    turn_mode = true,
    turn_started = true,
    player_cards_drawn = true,
    character_intent = true,
    effect_applied = true,
    card_declared = true,
    trigger_suppressed = true,
    plan_changed = true,
    actions_stopped = true,
    card_removed = true,
    outcome = true,
    mood_evaluated = true,
    turn_ended = true,
    session_ended = true,
}

local LLM_TYPES = {
    turn_mode = true,
    turn_context = true,
    character_intent = true,
    effect_applied = true,
    action = true,
    plan_suppressed = true,
    plan = true,
    actions_stopped = true,
    outcome = true,
    mood_changed = true,
    session_ended = true,
}

local PRIVATE_KEYS = {
    eventid = true,
    resolutionid = true,
    turnid = true,
    battleid = true,
    seed = true,
    cursor = true,
    rng = true,
    authority = true,
    metrics = true,
    selectedcards = true,
    afterstate = true,
    beforestate = true,
    workingstate = true,
    projectionreceipt = true,
}

local PRIVATE_PROFILE_VALUES = {
    ["섹스를 야동으로만 접함"] = true,
    ["실제 관계는 한 적 없으나 몇 번 자위를 해본 적 있음"] = true,
    ["자위 때 사용한 딱풀"] = true,
}

local function assertNoPrivate(label, value, bannedValues, public, active)
    if type(value) ~= "table" then
        if type(value) == "string" then
            assert(not bannedValues[value], label .. " leaked runtime/private value: " .. value)
            assert(not PRIVATE_PROFILE_VALUES[value], label .. " leaked character private profile")
        end
        return
    end
    active = active or {}
    assert(not active[value], label .. " has a cycle")
    active[value] = true
    for key, item in pairs(value) do
        if type(key) == "string" then
            local lower = string.lower(key)
            assert(not PRIVATE_KEYS[lower], label .. " leaked private key " .. key)
            assert(not string.find(lower, "instance", 1, true), label .. " leaked instance key " .. key)
            if public then
                assert(lower ~= "actoraction" and lower ~= "actorthought", label .. " leaked narration into public output")
            end
        end
        assertNoPrivate(label .. "." .. tostring(key), item, bannedValues, public, active)
    end
    active[value] = nil
end

local function assertEnvelope(label, envelope, allowedTypes, bannedValues, public)
    assert(type(envelope) == "table" and envelope.schemaVersion == 1, label .. " envelope header changed")
    for key in pairs(envelope) do
        assert(key == "schemaVersion" or key == "events", label .. " unexpected envelope field " .. tostring(key))
    end
    assert(type(envelope.events) == "table", label .. " events missing")
    for index, event in ipairs(envelope.events) do
        for key in pairs(event) do
            assert(key == "sequence" or key == "type" or key == "payload", label .. " leaked event field " .. tostring(key))
        end
        assert(event.sequence == index, label .. " sequence is not contiguous")
        assert(allowedTypes[event.type] == true, label .. " unknown projected event " .. tostring(event.type))
        assert(type(event.payload) == "table", label .. " event payload missing")
    end
    assertJsonSafe(label, envelope)
    assertNoPrivate(label, envelope, bannedValues, public)
end

local function collectBannedValues(beforeState, resolution)
    local values = {
        [beforeState.battleId] = true,
        [resolution.turnId] = true,
    }
    for _, instance in ipairs(beforeState.cardInstances) do
        values[instance.instanceId] = true
    end
    for _, event in ipairs(resolution.events) do
        values[event.eventId] = true
        if event.resolutionId ~= nil then values[event.resolutionId] = true end
        if event.source.instanceId ~= nil then values[event.source.instanceId] = true end
    end
    return values
end

local function matchingEvents(envelope, eventType, predicate)
    local result = {}
    for index, event in ipairs(envelope.events) do
        if event.type == eventType and (predicate == nil or predicate(event)) then
            result[#result + 1] = { event = event, index = index }
        end
    end
    return result
end

local function onlyEvent(label, envelope, eventType, predicate)
    local matches = matchingEvents(envelope, eventType, predicate)
    assert(#matches == 1, label .. " expected one " .. eventType .. ", got " .. tostring(#matches))
    return matches[1]
end

local function containsValue(value, expected, active)
    if type(value) ~= "table" then return value == expected end
    active = active or {}
    if active[value] then return false end
    active[value] = true
    for _, item in pairs(value) do
        if containsValue(item, expected, active) then
            active[value] = nil
            return true
        end
    end
    active[value] = nil
    return false
end

local function runTurn(label, rawState, selectedPlayerIds, data)
    data = data or staticData
    local turnId = rawState.battleId .. "-turn-" .. string.format("%03d", rawState.turnNumber)
    local rawSnapshot = canonical(rawState)
    local initialized = assertOk(
        label .. " initialize",
        runScript(
            "turn-event-projector-check",
            "turnInitializer",
            "prepareTurn",
            rawState,
            data,
            { turnId = turnId }
        )
    )
    assert(canonical(rawState) == rawSnapshot, label .. " initializer mutated raw state")
    local beforeState = initialized.state
    local draft = initialized.draft
    for _, instanceId in ipairs(selectedPlayerIds or {}) do
        draft = assertOk(
            label .. " register " .. instanceId,
            runScript(
                "turn-event-projector-check",
                "turnDraft",
                "registerCard",
                beforeState,
                data,
                draft,
                instanceId
            )
        ).draft
    end
    local projection = assertOk(
        label .. " project",
        runScript("turn-event-projector-check", "turnDraft", "project", beforeState, data, draft)
    ).projection
    local resolution = assertOk(
        label .. " resolve",
        runScript(
            "turn-event-projector-check",
            "turnResolver",
            "resolveTurn",
            beforeState,
            data,
            projection,
            { turnId = turnId }
        )
    ).resolution
    return beforeState, resolution
end

local function project(label, beforeState, resolution, data)
    data = data or staticData
    local beforeSnapshot = canonical(beforeState)
    local resolutionSnapshot = canonical(resolution)
    local report = assertOk(
        label,
        runScript(
            "turn-event-projector-check",
            "turnEventProjector",
            "projectTurn",
            beforeState,
            data,
            resolution
        )
    )
    assert(canonical(beforeState) == beforeSnapshot, label .. " mutated beforeState")
    assert(canonical(resolution) == resolutionSnapshot, label .. " mutated resolution")
    local banned = collectBannedValues(beforeState, resolution)
    assertEnvelope(label .. " public", report.publicResult, PUBLIC_TYPES, banned, true)
    assertEnvelope(label .. " llm", report.llmEvent, LLM_TYPES, banned, false)
    return report
end

-- Ordinary player and character actions expose only the player's card identity,
-- the character action tag, and LLM-only narration.
local normalBefore, normalResolution = runTurn(
    "ordinary actions",
    makeState({
        battleId = "projector-normal",
        cards = {
            makeCard("normal-brush", "accidental_brush", "player", "hand", 1),
            makeCard("normal-warning", "quiet_warning", "character", "hand", 1),
        },
    }),
    { "normal-brush" }
)
local normalProjection = project("ordinary actions projector", normalBefore, normalResolution)
local playerDeclaration = onlyEvent("player declaration", normalProjection.publicResult, "card_declared", function(item)
    return item.payload.side == "player"
end)
local characterDeclaration = onlyEvent("character declaration", normalProjection.publicResult, "card_declared", function(item)
    return item.payload.side == "character"
end)
assert(playerDeclaration.event.payload.cardId == "accidental_brush", "player card identity was not public")
assert(characterDeclaration.event.payload.cardId == nil, "character card identity leaked")
assert(characterDeclaration.event.payload.actionTag == "vigilance", "character action tag changed")
local playerAction = onlyEvent("player narration", normalProjection.llmEvent, "action", function(item)
    return item.payload.actor == "player"
end).event.payload
local characterAction = onlyEvent("character narration", normalProjection.llmEvent, "action", function(item)
    return item.payload.actor == "character"
end).event.payload
assert(type(playerAction.actorAction) == "string" and playerAction.actorThought == nil, "player narration contract changed")
assert(type(characterAction.actorAction) == "string" and type(characterAction.actorThought) == "string",
    "character narration contract changed")
local playerCost = onlyEvent("player cost", normalProjection.publicResult, "effect_applied", function(item)
    return item.payload.op == "pay_stealth_cost"
end)
assert(playerDeclaration.index < playerCost.index, "cost was projected before its card declaration")

-- Removal, direct mood movement, and skip summaries expose no restored or
-- unresolved instance IDs.
local removeBefore, removeResolution = runTurn(
    "remove action",
    makeState({
        battleId = "projector-remove",
        cards = {
            makeCard("remove-whisper", "hypnotic_whisper", "player", "hand", 1),
            makeCard("remove-warning", "quiet_warning", "character", "hand", 1),
        },
    }),
    { "remove-whisper" }
)
local removeProjection = project("remove action projector", removeBefore, removeResolution)
local removedCard = onlyEvent("removed player card", removeProjection.publicResult, "card_removed").event.payload
assert(removedCard.side == "player" and removedCard.cardId == "hypnotic_whisper", "remove projection changed")
local skippedActions = onlyEvent("skipped character actions", removeProjection.publicResult, "actions_stopped").event.payload
assert(skippedActions.side == "character" and skippedActions.count == 1, "skip summary changed")

-- Mood-token effects are validated and projected to both public and LLM streams.
local tokenEffectData = clone(staticData)
tokenEffectData.cards.hypnotic_whisper.resolve = function(context)
    return {
        {
            op = "add_mood_token",
            target = "character",
            mood = "confusion",
            amount = 1,
            cause = "cardEffect",
        },
    }
end
local tokenEffectBefore, tokenEffectResolution = runTurn(
    "mood token effect",
    makeState({
        battleId = "projector-mood-token",
        cards = {
            makeCard("token-whisper", "hypnotic_whisper", "player", "hand", 1),
        },
    }),
    { "token-whisper" },
    tokenEffectData
)
local tokenEffectProjection = project(
    "mood token effect projector",
    tokenEffectBefore,
    tokenEffectResolution,
    tokenEffectData
)
local tokenEffect = onlyEvent("mood token public effect", tokenEffectProjection.publicResult, "effect_applied", function(item)
    return item.payload.op == "add_mood_token"
end).event.payload
assert(tokenEffect.mood == "confusion" and tokenEffect.amount == 1 and tokenEffect.changed == true,
    "mood token effect was not preserved")
assert(#matchingEvents(tokenEffectProjection.llmEvent, "effect_applied", function(item)
    return item.payload.op == "add_mood_token"
end) == 1, "mood token effect did not reach the LLM")
local forgedTokenEffect = clone(tokenEffectResolution)
for _, event in ipairs(forgedTokenEffect.events) do
    if event.type == "effect_applied" and event.payload.op == "add_mood_token" then
        event.payload.after = event.payload.after + 1
        break
    end
end
assertFails(
    "forged mood token result",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", tokenEffectBefore, tokenEffectData, forgedTokenEffect),
    "invalid_effect_payload"
)

local drawEffectData = clone(staticData)
drawEffectData.cards.hypnotic_whisper.resolve = function(context)
    return {
        {
            op = "draw_cards",
            target = "player",
            amount = 1,
            cause = "cardEffect",
        },
    }
end
local drawEffectBefore, drawEffectResolution = runTurn(
    "draw effect",
    makeState({
        battleId = "projector-draw-effect",
        cards = {
            makeCard("draw-effect-whisper", "hypnotic_whisper", "player", "hand", 1),
            makeCard("draw-effect-brush", "accidental_brush", "player", "deck", 1),
            makeCard("draw-effect-cool", "play_it_cool", "player", "deck", 2),
            makeCard("draw-effect-pin", "pin_down", "player", "deck", 3),
            makeCard("draw-effect-approach", "subtle_approach", "player", "deck", 4),
        },
    }),
    { "draw-effect-whisper" },
    drawEffectData
)
local drawEffectProjection = project("draw effect projector", drawEffectBefore, drawEffectResolution, drawEffectData)
local forgedDrawCount = clone(drawEffectResolution)
for _, event in ipairs(forgedDrawCount.events) do
    if event.type == "effect_applied" and event.payload.op == "draw_cards" then
        event.payload.drawnInstanceIds[#event.payload.drawnInstanceIds + 1] = "draw-effect-forged"
        break
    end
end
assertFails(
    "draw count exceeds request",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", drawEffectBefore, drawEffectData, forgedDrawCount),
    "invalid_effect_payload"
)

-- Terminal turns keep exact public resources but reduce LLM outcome data to the
-- semantic status/reason pair, then emit one matching session end.
local terminalBefore, terminalResolution = runTurn(
    "terminal action",
    makeState({
        battleId = "projector-terminal",
        stealth = 1,
        resistance = 1,
        cards = {
            makeCard("terminal-brush", "accidental_brush", "player", "hand", 1),
            makeCard("terminal-warning", "quiet_warning", "character", "hand", 1),
        },
    }),
    { "terminal-brush" }
)
assert(terminalResolution.afterState.status == "victory", "terminal fixture did not end in victory")
local terminalProjection = project("terminal action projector", terminalBefore, terminalResolution)
local publicOutcome = onlyEvent("public terminal outcome", terminalProjection.publicResult, "outcome").event.payload
local llmOutcome = onlyEvent("LLM terminal outcome", terminalProjection.llmEvent, "outcome").event.payload
assert(publicOutcome.status == "victory" and type(publicOutcome.stealth) == "number"
        and type(publicOutcome.resistance) == "number", "public terminal resources changed")
assert(publicOutcome.stealth == terminalResolution.afterState.player.stealth
        and publicOutcome.resistance == terminalResolution.afterState.character.resistance,
    "public terminal resources differ from the committed state")
assert(llmOutcome.status == "victory" and llmOutcome.stealth == nil and llmOutcome.resistance == nil,
    "LLM outcome received raw resource state")
assert(#matchingEvents(terminalProjection.publicResult, "session_ended") == 1,
    "terminal public session event count changed")
assert(#matchingEvents(terminalProjection.llmEvent, "session_ended") == 1,
    "terminal LLM session event count changed")
local forgedOutcome = clone(terminalResolution)
for _, event in ipairs(forgedOutcome.events) do
    if event.type == "outcome_latched" then
        event.payload.stealth = 999
        event.payload.resistance = 888
        break
    end
end
assertFails(
    "forged terminal resources",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", terminalBefore, staticData, forgedOutcome),
    "invalid_outcome"
)
local forgedOutcomeReason = clone(terminalResolution)
for _, event in ipairs(forgedOutcomeReason.events) do
    if event.type == "outcome_latched" then
        event.payload.reasonCode = "turn_end_checkpoint"
        break
    end
end
assertFails(
    "forged terminal reason",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", terminalBefore, staticData, forgedOutcomeReason),
    "invalid_outcome"
)

-- A plan placed on the resolved turn survives cleanup, then a zero-command
-- session_end trigger may consume its last charge before the committed state.
local sessionPlanData = clone(staticData)
local sessionPlan = sessionPlanData.cards.subtle_approach.mechanismData.plan
sessionPlan.event = "session_end"
sessionPlan.trigger = function(context, event)
    return event.type == "session_end"
end
sessionPlan.resolve = function(context, event)
    return {}
end
local sessionPlanBefore, sessionPlanResolution = runTurn(
    "session-end zero-command plan",
    makeState({
        battleId = "projector-session-plan",
        turnLimit = 1,
        playerPlan = planSlot("session-plan-001", "subtle_approach", {
            placedTurn = 1,
            remainingTurns = 1,
            remainingCharges = 1,
            revealed = true,
        }),
        cards = {
            makeCard("session-plan-001", "subtle_approach", "player", "plan", 1),
        },
    }),
    {},
    sessionPlanData
)
assert(sessionPlanResolution.afterState.status == "defeat", "turn-limit terminal fixture changed")
local sessionCleanup, sessionPlanChange, sessionTrigger, sessionEnd
for index, event in ipairs(sessionPlanResolution.events) do
    if event.type == "turn_cleanup" then sessionCleanup = { event = event, index = index } end
    if event.type == "plan_changed" and event.source.id == "subtle_approach"
        and event.payload.action == "triggered" then
        sessionPlanChange = { event = event, index = index }
    end
    if event.type == "trigger_resolved" and event.source.id == "subtle_approach"
        and event.payload.inputEventType == "session_end" then
        sessionTrigger = { event = event, index = index }
    end
    if event.type == "session_end" then sessionEnd = { event = event, index = index } end
end
assert(sessionCleanup and sessionCleanup.event.payload.after.player.planSlot.occupied == true,
    "cleanup should retain a plan placed on the resolved turn")
assert(sessionPlanChange and sessionPlanChange.event.payload.discarded == true,
    "session plan was not charge-discarded")
assert(sessionTrigger and sessionTrigger.event.payload.commandCount == 0,
    "session plan must be a zero-command trigger")
assert(sessionCleanup.index < sessionPlanChange.index
        and sessionPlanChange.index < sessionTrigger.index
        and sessionTrigger.index < sessionEnd.index,
    "cleanup/session plan/session_end order changed")
assert(sessionPlanResolution.afterState.player.planSlot.occupied == false,
    "session plan remained in final slot")
local sessionPlanProjection = project(
    "session-end zero-command plan projector",
    sessionPlanBefore,
    sessionPlanResolution,
    sessionPlanData
)

-- Canary data in an internal-only metrics field must be discarded rather than
-- copied into either output.
local canaryResolution = clone(normalResolution)
canaryResolution.metrics.projectorPrivateCanary = {
    selectedInstanceId = "normal-warning",
    seed = 987654,
}
local canaryProjection = project("internal metric canary", normalBefore, canaryResolution)
assert(not containsValue(canaryProjection.publicResult, "normal-warning"), "public result leaked the metric canary")
assert(not containsValue(canaryProjection.llmEvent, "normal-warning"), "LLM event leaked the metric canary")

-- Insight suppression of an unrevealed opposing plan leaves no observable trace.
local hiddenBefore, hiddenResolution = runTurn(
    "hidden suppression",
    makeState({
        battleId = "projector-hidden",
        cards = {
            makeCard("hidden-pin", "pin_down", "player", "hand", 1),
            makeCard("hidden-glare", "silent_glare", "character", "plan", 1),
        },
        characterPlan = planSlot("hidden-glare", "silent_glare"),
    }),
    { "hidden-pin" }
)
local rawSuppression = nil
for _, event in ipairs(hiddenResolution.events) do
    if event.type == "trigger_suppressed" then rawSuppression = event end
end
assert(rawSuppression and rawSuppression.payload.hidden == true, "fixture did not produce hidden suppression")
local hiddenProjection = project("hidden suppression projector", hiddenBefore, hiddenResolution)
assert(#matchingEvents(hiddenProjection.publicResult, "trigger_suppressed") == 0, "hidden suppression became public")
assert(#matchingEvents(hiddenProjection.llmEvent, "plan_suppressed") == 0, "hidden suppression reached the LLM")
assert(not containsValue(hiddenProjection.publicResult, "silent_glare"), "hidden plan ID leaked publicly")
assert(not containsValue(hiddenProjection.llmEvent, "silent_glare"), "hidden plan ID leaked to the LLM")

-- A real trigger reveals the plan before its buffered effects are narrated.
local triggerBefore, triggerResolution = runTurn(
    "plan trigger",
    makeState({
        battleId = "projector-trigger",
        cards = {
            makeCard("trigger-brush", "accidental_brush", "player", "hand", 1),
            makeCard("trigger-glare", "silent_glare", "character", "plan", 1),
        },
        characterPlan = planSlot("trigger-glare", "silent_glare"),
    }),
    { "trigger-brush" }
)
local rawPlanEffectIndex = nil
local rawPlanChangeIndex = nil
for index, event in ipairs(triggerResolution.events) do
    if event.type == "effect_applied" and event.source.kind == "plan" then rawPlanEffectIndex = index end
    if event.type == "plan_changed" and event.payload.action == "triggered" then rawPlanChangeIndex = index end
end
assert(rawPlanEffectIndex and rawPlanChangeIndex and rawPlanEffectIndex < rawPlanChangeIndex,
    "fixture no longer exercises effect-before-plan raw order")
local triggerProjection = project("plan trigger projector", triggerBefore, triggerResolution)
local publicPlan = onlyEvent("revealed public plan", triggerProjection.publicResult, "plan_changed", function(item)
    return item.payload.action == "triggered"
end)
local publicPlanEffect = onlyEvent("revealed plan effect", triggerProjection.publicResult, "effect_applied", function(item)
    return item.payload.op == "lose_stealth" and item.payload.amount == 3
end)
assert(publicPlan.event.payload.cardId == "silent_glare" and publicPlan.event.payload.identityKnown == true,
    "triggered plan identity was not revealed")
assert(publicPlan.index < publicPlanEffect.index, "plan effect was projected before the plan meaning event")
local llmPlan = onlyEvent("revealed LLM plan", triggerProjection.llmEvent, "plan", function(item)
    return item.payload.action == "triggered"
end).event.payload
assert(type(llmPlan.actorAction) == "string" and type(llmPlan.actorThought) == "string",
    "revealed character plan narration was not projected")

-- A newly placed character plan stays anonymous in both outputs.
local placementBefore, placementResolution = runTurn(
    "hidden placement",
    makeState({
        battleId = "projector-placement",
        cards = {
            makeCard("placement-glare", "silent_glare", "character", "hand", 1),
        },
    }),
    {}
)
local placementProjection = project("hidden placement projector", placementBefore, placementResolution)
local placedPublic = onlyEvent("hidden public placement", placementProjection.publicResult, "plan_changed", function(item)
    return item.payload.action == "placed"
end).event.payload
local placedLlm = onlyEvent("hidden LLM placement", placementProjection.llmEvent, "plan", function(item)
    return item.payload.action == "placed"
end).event.payload
assert(placedPublic.identityKnown == false and placedPublic.cardId == nil, "hidden placement identity leaked publicly")
assert(placedLlm.identityKnown == false and placedLlm.actorAction == nil and placedLlm.actorThought == nil,
    "hidden placement narration leaked to the LLM")
assert(not containsValue(placementProjection.publicResult, "silent_glare"), "hidden placement card ID leaked publicly")
assert(not containsValue(placementProjection.llmEvent, "silent_glare"), "hidden placement card ID leaked to the LLM")

-- A placement-turn-counting player plan may be placed and expire in one
-- resolution. The policy remains an internal integrity field, not narration
-- or public UI data.
local placementTurnExpiryBefore, placementTurnExpiryResolution = runTurn(
    "placement turn expiry",
    makeState({
        battleId = "projector-placement-turn-expiry",
        cards = {
            makeCard("placement-turn-escape", "cut_off_escape", "player", "hand", 1),
        },
    }),
    { "placement-turn-escape" }
)
local placementTurnPlacedEvent = nil
local placementTurnCleanupEvent = nil
for _, event in ipairs(placementTurnExpiryResolution.events) do
    if event.type == "plan_changed"
        and event.payload.action == "placed"
        and event.source.id == "cut_off_escape" then
        placementTurnPlacedEvent = event
    elseif event.type == "turn_cleanup" then
        placementTurnCleanupEvent = event
    end
end
assert(placementTurnPlacedEvent
        and placementTurnPlacedEvent.payload.planSpec.durationTurns == 1
        and placementTurnPlacedEvent.payload.planSpec.durationIncludesPlacementTurn == true
        and placementTurnPlacedEvent.payload.after.durationIncludesPlacementTurn == true,
    "placement-turn expiry fixture lost its plan policy")
assert(placementTurnCleanupEvent
        and placementTurnCleanupEvent.payload.before.player.planSlot.durationIncludesPlacementTurn == true
        and placementTurnCleanupEvent.payload.after.player.planSlot.occupied == false,
    "placement-turn expiry fixture did not expire during cleanup")
assert(placementTurnExpiryResolution.afterState.player.planSlot.occupied == false,
    "placement-turn expiry resolution retained the plan slot")
local placementTurnExpiryProjection = project(
    "placement turn expiry projector",
    placementTurnExpiryBefore,
    placementTurnExpiryResolution
)
assert(not string.find(canonical(placementTurnExpiryProjection.publicResult),
        "durationIncludesPlacementTurn", 1, true),
    "public projection leaked the internal plan duration policy")
assert(not string.find(canonical(placementTurnExpiryProjection.llmEvent),
        "durationIncludesPlacementTurn", 1, true),
    "LLM projection leaked the internal plan duration policy")

local missingPlacementDuration = clone(placementTurnExpiryResolution)
for _, event in ipairs(missingPlacementDuration.events) do
    if event.type == "plan_changed" and event.payload.action == "placed" then
        event.payload.planSpec.durationTurns = nil
        break
    end
end
assertFails(
    "placement policy planSpec without duration",
    runScript(
        "turn-event-projector-check",
        "turnEventProjector",
        "projectTurn",
        placementTurnExpiryBefore,
        staticData,
        missingPlacementDuration
    ),
    "plan_duration_policy_requires_duration"
)

local mismatchedPlacementSlot = clone(placementTurnExpiryResolution)
for _, event in ipairs(mismatchedPlacementSlot.events) do
    if event.type == "plan_changed" and event.payload.action == "placed" then
        event.payload.after.durationIncludesPlacementTurn = false
        break
    end
end
assertFails(
    "placement planSpec and slot policy mismatch",
    runScript(
        "turn-event-projector-check",
        "turnEventProjector",
        "projectTurn",
        placementTurnExpiryBefore,
        staticData,
        mismatchedPlacementSlot
    ),
    "invalid_plan_placement"
)

local mismatchedPlacementStaticData = clone(staticData)
mismatchedPlacementStaticData.cards.cut_off_escape.mechanismData.plan.durationIncludesPlacementTurn = false
assertFails(
    "placement event and static policy mismatch",
    runScript(
        "turn-event-projector-check",
        "turnEventProjector",
        "projectTurn",
        placementTurnExpiryBefore,
        mismatchedPlacementStaticData,
        placementTurnExpiryResolution
    ),
    "invalid_plan_placement"
)

-- The resolver always places a character plan unrevealed. Matching two forged
-- `revealed=true` fields must not be enough to disclose its identity.
local forgedPlacement = clone(placementResolution)
for _, event in ipairs(forgedPlacement.events) do
    if event.type == "plan_changed" and event.payload.action == "placed" then
        event.payload.planSpec.revealed = true
        event.payload.after.revealed = true
        break
    end
end
assertFails(
    "forged revealed character placement",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", placementBefore, staticData, forgedPlacement),
    "invalid_plan_placement"
)

-- planExpired narration is optional. A known plan may expire successfully with
-- only the semantic fallback event when the DB has no planExpired entry.
local expiryBefore, expiryResolution = runTurn(
    "known expiration",
    makeState({
        battleId = "projector-expiry",
        turnNumber = 2,
        mood = "confusion",
        cards = {
            makeCard("expiry-glare", "silent_glare", "character", "plan", 1),
        },
        characterPlan = planSlot("expiry-glare", "silent_glare", { revealed = true }),
    }),
    {}
)
local expiryProjection = project("known expiration projector", expiryBefore, expiryResolution)
local expiredPublic = onlyEvent("known public expiration", expiryProjection.publicResult, "plan_changed", function(item)
    return item.payload.action == "expired"
end).event.payload
local expiredLlm = onlyEvent("known LLM expiration", expiryProjection.llmEvent, "plan", function(item)
    return item.payload.action == "expired"
end).event.payload
assert(expiredPublic.identityKnown == true and expiredPublic.cardId == "silent_glare", "known expiration lost identity")
assert(expiredLlm.identityKnown == true and expiredLlm.actorAction == nil,
    "missing optional planExpired narration did not use the semantic fallback")

-- Cleanup cannot forge an unrevealed plan into a known expiration.
local hiddenExpiryBefore, hiddenExpiryResolution = runTurn(
    "hidden expiration",
    makeState({
        battleId = "projector-hidden-expiry",
        turnNumber = 2,
        mood = "confusion",
        cards = {
            makeCard("hidden-expiry-glare", "silent_glare", "character", "plan", 1),
        },
        characterPlan = planSlot("hidden-expiry-glare", "silent_glare"),
    }),
    {}
)
local hiddenExpiryProjection = project("hidden expiration projector", hiddenExpiryBefore, hiddenExpiryResolution)
assert(not containsValue(hiddenExpiryProjection.publicResult, "silent_glare"),
    "unrevealed expired plan leaked publicly")
assert(not containsValue(hiddenExpiryProjection.llmEvent, "silent_glare"),
    "unrevealed expired plan leaked to the LLM")
local forgedHiddenExpiry = clone(hiddenExpiryResolution)
for _, event in ipairs(forgedHiddenExpiry.events) do
    if event.type == "turn_cleanup" then
        event.payload.before.character.planSlot.revealed = true
        break
    end
end
assertFails(
    "forged revealed cleanup plan",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", hiddenExpiryBefore, staticData, forgedHiddenExpiry),
    "invalid_turn_cleanup"
)

-- A player plan placed on one turn may trigger inside the next initializer.
-- Receipt events remain projectable even when the initialized beforeState no
-- longer contains the consumed plan slot.
local playerPlanBeforeOne, playerPlanResolutionOne = runTurn(
    "player plan placement",
    makeState({
        battleId = "projector-player-plan",
        cards = {
            makeCard("player-plan-card", "subtle_approach", "player", "hand", 1),
        },
    }),
    { "player-plan-card" }
)
local playerPlanProjectionOne = project(
    "player plan placement projector",
    playerPlanBeforeOne,
    playerPlanResolutionOne
)
local playerPlanBeforeTwo, playerPlanResolutionTwo = runTurn(
    "player plan receipt trigger",
    playerPlanResolutionOne.afterState,
    {}
)
local playerPlanProjectionTwo = project(
    "player plan receipt trigger projector",
    playerPlanBeforeTwo,
    playerPlanResolutionTwo
)
local receiptPlan = onlyEvent("receipt player plan", playerPlanProjectionTwo.publicResult, "plan_changed", function(item)
    return item.payload.action == "triggered" and item.payload.side == "player"
end)
local receiptToken = onlyEvent("receipt plan token", playerPlanProjectionTwo.publicResult, "effect_applied", function(item)
    return item.payload.op == "add_mood_token"
end)
assert(receiptPlan.event.payload.cardId == "subtle_approach" and receiptPlan.index < receiptToken.index,
    "turn-start receipt plan meaning/effect order changed")

-- turn_start callbacks run before character selection. The initialized
-- beforeState already contains the selected intent, so replay must restore the
-- earlier nil publicActionTag instead of leaking that later value into context.
local turnStartContextData = clone(staticData)
local turnStartContextPlan = turnStartContextData.cards.subtle_approach.mechanismData.plan
turnStartContextPlan.trigger = function(context, event)
    return event.type == "turn_start" and context.character.publicActionTag == nil
end
local turnStartContextBefore, turnStartContextResolution = runTurn(
    "turn-start callback context",
    makeState({
        battleId = "projector-turn-start-context",
        turnNumber = 2,
        mood = "ignore",
        cards = {
            makeCard("context-plan", "subtle_approach", "player", "plan", 1),
            makeCard("context-warning", "quiet_warning", "character", "hand", 1),
        },
        playerPlan = planSlot("context-plan", "subtle_approach"),
    }),
    {},
    turnStartContextData
)
assert(turnStartContextBefore.characterIntent.publicActionTag == "vigilance",
    "fixture did not select a later character action tag")
project(
    "turn-start callback context projector",
    turnStartContextBefore,
    turnStartContextResolution,
    turnStartContextData
)

-- Repeated real turns exercise non-plan character actions, hidden placement and
-- expiration, deck reshuffles, and non-zero initializer draw receipts together.
local cycleState = makeState({
    battleId = "projector-cycle",
    turnLimit = 20,
    stealth = 100,
    resistance = 100,
    cards = {
        makeCard("cycle-player-001", "subtle_approach", "player", "deck", 1),
        makeCard("cycle-player-002", "accidental_brush", "player", "deck", 2),
        makeCard("cycle-player-003", "play_it_cool", "player", "deck", 3),
        makeCard("cycle-player-004", "read_the_room", "player", "deck", 4),
        makeCard("cycle-player-005", "pin_down", "player", "deck", 5),
        makeCard("cycle-player-006", "hypnotic_whisper", "player", "deck", 6),
        makeCard("cycle-character-001", "close_collar", "character", "deck", 1),
        makeCard("cycle-character-002", "quiet_warning", "character", "deck", 2),
        makeCard("cycle-character-003", "turn_to_corner", "character", "deck", 3),
        makeCard("cycle-character-004", "silent_glare", "character", "deck", 4),
    },
})
local cycleProjections = {}
for turn = 1, 10 do
    local cycleBefore, cycleResolution = runTurn("cycle turn " .. turn, cycleState, {})
    cycleProjections[turn] = project("cycle projector " .. turn, cycleBefore, cycleResolution)
    cycleState = cycleResolution.afterState
end
assert(cycleState.status == "active" and cycleState.turnNumber == 11, "ten-turn projection cycle changed")

-- Fail closed on values placed under otherwise allowed raw fields.
local forgedStartDraw = clone(normalResolution)
for _, event in ipairs(forgedStartDraw.events) do
    if event.type == "cards_drawn" and event.side == "player" then
        event.payload.requested = 99
        event.payload.drawnCount = 99
        break
    end
end
assertFails(
    "forged start draw counts",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, forgedStartDraw),
    "invalid_draw_event"
)

local forgedTriggerAmount = clone(normalResolution)
local shiftedStealth = false
for _, event in ipairs(forgedTriggerAmount.events) do
    if event.type == "effect_applied" and event.source.kind == "environment"
        and shiftedStealth == false then
        event.payload.amount = event.payload.amount + 1
        event.payload.after = event.payload.after - 1
        shiftedStealth = true
    elseif shiftedStealth and event.type == "effect_applied"
        and (event.payload.op == "pay_stealth_cost"
            or event.payload.op == "lose_stealth"
            or event.payload.op == "recover_stealth") then
        event.payload.before = event.payload.before - 1
        event.payload.after = event.payload.after - 1
    elseif shiftedStealth and event.type == "outcome_latched" then
        event.payload.stealth = event.payload.stealth - 1
    end
end
assert(shiftedStealth, "trigger amount fixture needs an environment effect")
forgedTriggerAmount.afterState.player.stealth = forgedTriggerAmount.afterState.player.stealth - 1
assertFails(
    "coherently forged trigger amount",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, forgedTriggerAmount),
    "trigger_command_mismatch"
)

local omittedTrigger = clone(normalResolution)
local omittedResolutionId = nil
for _, event in ipairs(omittedTrigger.events) do
    if event.type == "effect_applied" and event.source.kind == "environment" then
        omittedResolutionId = event.resolutionId
        break
    end
end
assert(omittedResolutionId ~= nil, "omitted trigger fixture needs an environment batch")
local keptEvents = {}
local omittedBatch = false
for _, event in ipairs(omittedTrigger.events) do
    local omit = event.resolutionId == omittedResolutionId
        and event.source.kind == "environment"
        and (event.type == "effect_applied" or event.type == "trigger_resolved")
    if omit then
        omittedBatch = true
    else
        if omittedBatch and event.type == "effect_applied"
            and (event.payload.op == "pay_stealth_cost"
                or event.payload.op == "lose_stealth"
                or event.payload.op == "recover_stealth") then
            event.payload.before = event.payload.before + 1
            event.payload.after = event.payload.after + 1
        elseif omittedBatch and event.type == "outcome_latched" then
            event.payload.stealth = event.payload.stealth + 1
        end
        keptEvents[#keptEvents + 1] = event
    end
end
omittedTrigger.events = keptEvents
omittedTrigger.afterState.player.stealth = omittedTrigger.afterState.player.stealth + 1
for index, event in ipairs(omittedTrigger.events) do
    event.sequence = index
    event.eventId = omittedTrigger.turnId .. "-event-" .. string.format("%03d", index)
end
assertFails(
    "omitted matching trigger",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, omittedTrigger),
    "missing_trigger_batch"
)

local forgedTriggerSide = clone(normalResolution)
local characterDeclarationIndex, characterResolutionId, characterStealthBefore
for index, event in ipairs(forgedTriggerSide.events) do
    if event.type == "card_declared" and event.side == "character" then
        characterDeclarationIndex = index
        characterResolutionId = event.resolutionId
    elseif characterDeclarationIndex ~= nil and characterStealthBefore == nil
        and event.type == "effect_applied"
        and (event.payload.op == "lose_stealth" or event.payload.op == "recover_stealth") then
        characterStealthBefore = event.payload.before
    end
end
assert(characterDeclarationIndex and characterResolutionId and characterStealthBefore,
    "wrong-side trigger fixture needs a character declaration and later stealth effect")
local lateEnvironmentEffect = {
    type = "effect_applied",
    phase = "character_card",
    source = { kind = "environment", id = "uncrowded" },
    payload = {
        index = 1,
        op = "lose_stealth",
        target = "player",
        cause = "environmentEffect",
        changed = true,
        amount = 1,
        before = characterStealthBefore,
        after = characterStealthBefore - 1,
    },
    resolutionId = characterResolutionId,
    cause = { kind = "environment_trigger", resolutionId = characterResolutionId },
}
local lateEnvironmentResolved = {
    type = "trigger_resolved",
    phase = "character_card",
    source = { kind = "environment", id = "uncrowded" },
    payload = { inputEventType = "card_declared", commandCount = 1 },
    resolutionId = characterResolutionId,
    cause = { kind = "card_resolution", resolutionId = characterResolutionId },
}
table.insert(forgedTriggerSide.events, characterDeclarationIndex + 1, lateEnvironmentEffect)
table.insert(forgedTriggerSide.events, characterDeclarationIndex + 2, lateEnvironmentResolved)
for index = characterDeclarationIndex + 3, #forgedTriggerSide.events do
    local event = forgedTriggerSide.events[index]
    if event.type == "effect_applied"
        and (event.payload.op == "pay_stealth_cost"
            or event.payload.op == "lose_stealth"
            or event.payload.op == "recover_stealth") then
        event.payload.before = event.payload.before - 1
        event.payload.after = event.payload.after - 1
    elseif event.type == "outcome_latched" then
        event.payload.stealth = event.payload.stealth - 1
    end
end
forgedTriggerSide.afterState.player.stealth = forgedTriggerSide.afterState.player.stealth - 1
for index, event in ipairs(forgedTriggerSide.events) do
    event.sequence = index
    event.eventId = forgedTriggerSide.turnId .. "-event-" .. string.format("%03d", index)
end
assertFails(
    "wrong-side environment trigger",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, forgedTriggerSide),
    "trigger_condition_mismatch"
)

local forgedMoodTokens = clone(normalResolution)
for _, event in ipairs(forgedMoodTokens.events) do
    if event.type == "mood_evaluated" then
        event.payload.tokensAfter.ignore = event.payload.tokensAfter.ignore + 1
        break
    end
end
assertFails(
    "forged mood token evaluation",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, forgedMoodTokens),
    "invalid_mood_evaluation"
)

local forgedCleanupOrder = clone(normalResolution)
for _, event in ipairs(forgedCleanupOrder.events) do
    if event.type == "turn_cleanup" then
        assert(#event.payload.movedInstanceIds >= 2, "cleanup order fixture needs at least two moved cards")
        event.payload.movedInstanceIds[1], event.payload.movedInstanceIds[2]
            = event.payload.movedInstanceIds[2], event.payload.movedInstanceIds[1]
        break
    end
end
assertFails(
    "forged cleanup move order",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, forgedCleanupOrder),
    "invalid_turn_cleanup"
)

local postCleanupEffect = clone(normalResolution)
local forgedLateEffect = nil
for _, event in ipairs(postCleanupEffect.events) do
    if event.type == "effect_applied" and event.source.kind == "environment" then
        forgedLateEffect = clone(event)
        break
    end
end
assert(forgedLateEffect ~= nil, "post-cleanup fixture needs an environment effect")
forgedLateEffect.phase = "session_end"
forgedLateEffect.resolutionId = nil
forgedLateEffect.cause = { kind = "environment_trigger" }
postCleanupEffect.events[#postCleanupEffect.events + 1] = forgedLateEffect
for index, event in ipairs(postCleanupEffect.events) do
    event.sequence = index
    event.eventId = postCleanupEffect.turnId .. "-event-" .. string.format("%03d", index)
end
assertFails(
    "effect after cleanup",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, postCleanupEffect),
    "invalid_post_cleanup_event"
)

local badCost = clone(normalResolution)
for _, event in ipairs(badCost.events) do
    if event.type == "card_declared" and event.side == "player" then
        event.payload.finalStealthCost = { selectedInstanceId = "normal-warning", seed = 1 }
        break
    end
end
assertFails(
    "nested cost payload",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, badCost)
)

local badMood = clone(normalResolution)
for _, event in ipairs(badMood.events) do
    if event.type == "mood_evaluated" then
        event.payload.reasonCode = { selectedInstanceId = "normal-warning" }
        break
    end
end
assertFails(
    "nested mood reason",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, badMood)
)

local badCleanup = clone(normalResolution)
for _, event in ipairs(badCleanup.events) do
    if event.type == "turn_cleanup" then
        event.payload.resolvedTurnNumber = { seed = 123 }
        break
    end
end
assertFails(
    "nested cleanup turn",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, badCleanup)
)

local unknownField = clone(normalResolution)
unknownField.events[1].payload["normal-warning"] = true
local unknownFieldFailure = runScript(
    "turn-event-projector-check",
    "turnEventProjector",
    "projectTurn",
    normalBefore,
    staticData,
    unknownField
)
assertFails(
    "unknown raw payload field",
    unknownFieldFailure,
    "unexpected_field"
)
assert(not string.find(canonical(unknownFieldFailure), "normal-warning", 1, true),
    "unknown raw key leaked through the failure channel")

local unknownEvent = clone(normalResolution)
unknownEvent.events[1].type = "normal-warning"
local unknownEventFailure = runScript(
    "turn-event-projector-check",
    "turnEventProjector",
    "projectTurn",
    normalBefore,
    staticData,
    unknownEvent
)
assertFails("unknown raw event", unknownEventFailure, "unknown_event_type")
assert(not string.find(canonical(unknownEventFailure), "normal-warning", 1, true),
    "unknown raw event type leaked through the failure channel")

local unknownActionFailure = runScript("turn-event-projector-check", "turnEventProjector", "normal-warning")
assertFails("unknown projector action", unknownActionFailure, "unknown_action")
assert(not string.find(canonical(unknownActionFailure), "normal-warning", 1, true),
    "unknown action leaked through the failure channel")

local forgedIntentSelection = clone(normalResolution)
for _, event in ipairs(forgedIntentSelection.events) do
    if event.type == "character_intent_selected" then
        event.payload.selected = false
        break
    end
end
assertFails(
    "forged character intent selection",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, forgedIntentSelection),
    "invalid_character_intent"
)

local forgedActionTag = clone(normalResolution)
for _, event in ipairs(forgedActionTag.events) do
    if event.type == "action_tag_revealed" then
        event.payload.actionTag = "block"
        break
    end
end
assertFails(
    "forged character action tag",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", normalBefore, staticData, forgedActionTag),
    "invalid_action_tag_reveal"
)

-- A plan effect mislabeled as another valid trigger category must be rejected;
-- otherwise it would bypass plan buffering and reveal the hidden effect early.
local mislabeledPlan = clone(triggerResolution)
for _, event in ipairs(mislabeledPlan.events) do
    if event.type == "effect_applied" and event.source.kind == "plan" then
        event.source.kind = "trait"
        event.source.id = "reserved"
        event.source.instanceId = nil
        event.cause.kind = "trait_trigger"
        break
    end
end
assertFails(
    "coordinated mislabeled plan effect",
    runScript("turn-event-projector-check", "turnEventProjector", "projectTurn", triggerBefore, staticData, mislabeledPlan),
    "source_has_no_triggers"
)

local nilBeforeOk, nilBeforeReport = pcall(
    runScript,
    "turn-event-projector-check",
    "turnEventProjector",
    "projectTurn",
    nil,
    staticData,
    normalResolution
)
assert(nilBeforeOk, "nil beforeState raised a Lua exception")
assertFails("nil beforeState", nilBeforeReport, "invalid_before_state")

local signature = canonical({
    normal = normalProjection,
    remove = removeProjection,
    zeroShift = zeroShiftProjection,
    drawEffect = drawEffectProjection,
    terminal = terminalProjection,
    sessionPlan = sessionPlanProjection,
    canary = canaryProjection,
    hidden = hiddenProjection,
    trigger = triggerProjection,
    placement = placementProjection,
    placementTurnExpiry = placementTurnExpiryProjection,
    expiry = expiryProjection,
    hiddenExpiry = hiddenExpiryProjection,
    playerPlanPlacement = playerPlanProjectionOne,
    playerPlanTrigger = playerPlanProjectionTwo,
    cycle = cycleProjections,
})
print("PROJECTOR|hash=" .. stableHash(signature) .. "|scenarios=16")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[turn-event-projector-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua turn-event projector check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua turn-event projector check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different projector results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^PROJECTOR\|hash=\d{10}\|scenarios=16$') {
        throw "Unexpected turn-event projector determinism vector: $firstText"
    }

    Write-Output 'turn-event-projector-check: ok'
    Write-Output 'NOTE: prompt injection, CBS rendering, and actual RisuAI hook integration remain untested.'
}
finally {
    Pop-Location
}
