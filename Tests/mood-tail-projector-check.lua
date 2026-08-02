local function loadModule(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return assert(load("return " .. source, "@" .. path, "t", _G))()
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[deepCopy(key, seen)] = deepCopy(item, seen)
    end
    return copy
end

local function zeros()
    return {
        rejection = 0,
        suspicion = 0,
        ignore = 0,
        confusion = 0,
        compliance = 0,
    }
end

local projector = loadModule("System/turnEventProjector.lua")

function runScript(triggerId, moduleName, action, ...)
    if moduleName == "stateSchema" and action == "validateBattleState" then
        return {
            ok = true,
            schemaVersion = 1,
            errors = {},
            referencesValidated = true,
        }
    end
    error("unexpected module call: " .. tostring(moduleName) .. "." .. tostring(action))
end

local staticData = {
    registry = {
        moods = {
            rejection = { id = "rejection", order = 1 },
            suspicion = { id = "suspicion", order = 2 },
            ignore = { id = "ignore", order = 3 },
            confusion = { id = "confusion", order = 4 },
            compliance = { id = "compliance", order = 5 },
        },
    },
    cards = {},
    characters = {
        tester = { id = "tester" },
    },
    traits = {},
    perks = {},
    environments = {
        quiet = {
            id = "quiet",
            triggers = {},
        },
    },
}

local function makeEvent(turnId, sequence, eventType, phase, source, payload, side, cause)
    local event = {
        eventId = turnId .. "-event-" .. string.format("%03d", sequence),
        sequence = sequence,
        type = eventType,
        phase = phase,
        source = source,
        payload = payload,
    }
    if side ~= nil then event.side = side end
    if cause ~= nil then event.cause = cause end
    return event
end

local function cleanupSnapshot(turnNumber)
    return {
        turnNumber = turnNumber,
        player = {
            used = {},
            hand = {},
            discard = {},
            planSlots = {},
        },
        character = {
            used = {},
            hand = {},
            discard = {},
            planSlots = {},
        },
    }
end

local function makeSideStates(stealth, mood)
    return {
        player = {
            stealth = stealth,
            planCapacity = 1,
            planSlots = {},
            perkIds = {},
        },
        character = {
            characterId = "tester",
            resistance = 20,
            mood = mood,
            moodTokens = zeros(),
            planCapacity = 1,
            planSlots = {},
            traitIds = {},
        },
    }
end

local function buildScenario(spec)
    local turnNumber = 2
    local turnId = "battle-001-turn-002"
    local beforeSides = makeSideStates(spec.startingStealth, spec.mood)
    local startEvents = {
        makeEvent(
            turnId,
            1,
            "turn_start",
            "turn_start",
            { kind = "system", id = "turn_initializer" },
            { turnNumber = turnNumber },
            nil,
            { kind = "turn_rule" }
        ),
        makeEvent(
            turnId,
            2,
            "cards_drawn",
            "turn_start",
            { kind = "system", id = "card_zones", side = "player" },
            { requested = 0, drawnCount = 0 },
            "player",
            { kind = "turn_rule" }
        ),
        makeEvent(
            turnId,
            3,
            "cards_drawn",
            "turn_start",
            { kind = "system", id = "card_zones", side = "character" },
            { requested = 0, drawnCount = 0 },
            "character",
            { kind = "turn_rule" }
        ),
        makeEvent(
            turnId,
            4,
            "character_intent_selected",
            "turn_start",
            { kind = "system", id = "character_selector", side = "character" },
            { selected = false },
            "character",
            { kind = "turn_rule" }
        ),
    }

    local beforeState = {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "battle-001",
        status = "active",
        turnNumber = turnNumber,
        turnLimit = 5,
        environmentId = "quiet",
        player = beforeSides.player,
        character = beforeSides.character,
        characterIntent = {
            cardInstanceIds = {},
        },
        cardInstances = {},
        turnStartReceipt = {
            turnId = turnId,
            baseline = {
                stealth = spec.startingStealth,
                resistance = 20,
                mood = spec.mood,
                moodTokens = zeros(),
            },
            events = deepCopy(startEvents),
            draws = {
                player = { requested = 0, drawnInstanceIds = {} },
                character = { requested = 0, drawnInstanceIds = {} },
            },
            transient = {
                forcedMoodRequests = {},
            },
        },
    }

    local events = deepCopy(startEvents)
    events[#events + 1] = makeEvent(
        turnId,
        #events + 1,
        "mood_evaluated",
        "turn_end",
        { kind = "system", id = "mood_tokens" },
        {
            before = spec.mood,
            after = spec.mood,
            applied = false,
            forcedCount = 0,
            forceCancelled = false,
            resolution = "none",
            tokensBefore = zeros(),
            tokensAfter = zeros(),
        },
        "character",
        { kind = "turn_rule" }
    )

    local endingStealth = spec.startingStealth
    if spec.effect ~= nil then
        endingStealth = endingStealth + spec.effect.delta
        events[#events + 1] = makeEvent(
            turnId,
            #events + 1,
            "effect_applied",
            "turn_end",
            { kind = "system", id = "mood_state" },
            {
                index = 1,
                op = spec.effect.op,
                target = "player",
                amount = spec.effect.amount,
                cause = "moodState",
                before = spec.startingStealth,
                after = endingStealth,
                changed = true,
            },
            "player",
            { kind = "mood_state" }
        )
    end

    if spec.status == "defeat" then
        events[#events + 1] = makeEvent(
            turnId,
            #events + 1,
            "outcome_latched",
            "turn_end",
            { kind = "system", id = "turn_resolver" },
            {
                status = "defeat",
                reasonCode = "mood_state_checkpoint",
                stealth = endingStealth,
                resistance = 20,
            },
            nil,
            { kind = "turn_rule" }
        )
    end

    local afterTurnNumber = spec.status == "active" and turnNumber + 1 or turnNumber
    events[#events + 1] = makeEvent(
        turnId,
        #events + 1,
        "turn_cleanup",
        "cleanup",
        { kind = "system", id = "card_zones" },
        {
            before = cleanupSnapshot(turnNumber),
            after = cleanupSnapshot(afterTurnNumber),
            movedInstanceIds = {},
            resolvedTurnNumber = turnNumber,
        },
        nil,
        { kind = "turn_rule" }
    )

    if spec.status == "defeat" then
        events[#events + 1] = makeEvent(
            turnId,
            #events + 1,
            "session_end",
            "session_end",
            { kind = "system", id = "turn_resolver" },
            { status = "defeat" },
            nil,
            { kind = "turn_rule" }
        )
    end

    local afterSides = makeSideStates(endingStealth, spec.mood)
    local afterState = {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "battle-001",
        status = spec.status,
        turnNumber = afterTurnNumber,
        turnLimit = 5,
        environmentId = "quiet",
        player = afterSides.player,
        character = afterSides.character,
        characterIntent = {
            cardInstanceIds = {},
        },
        cardInstances = {},
        lastCommittedTurnId = turnId,
    }

    return beforeState, {
        schemaVersion = 1,
        kind = "turnResolution",
        battleId = "battle-001",
        turnId = turnId,
        turnNumber = turnNumber,
        source = {
            kind = "turnDraftProjection",
            mode = "pass",
        },
        selectedCards = {
            player = {},
            character = {},
        },
        events = events,
        afterState = afterState,
    }
end

local function assertOk(label, report)
    if report.ok ~= true then
        local first = type(report.errors) == "table" and report.errors[1] or nil
        error(label .. ": " .. tostring(first and first.code) .. " " .. tostring(first and first.message))
    end
    return report
end

local function findEvent(envelope, eventType)
    for _, event in ipairs(envelope.events) do
        if event.type == eventType then return event end
    end
    return nil
end

local complianceBefore, complianceResolution = buildScenario({
    mood = "compliance",
    startingStealth = 10,
    status = "active",
    effect = {
        op = "recover_stealth",
        amount = 2,
        delta = 2,
    },
})
local compliance = assertOk(
    "compliance mood tail",
    projector("mood-tail-check", "projectTurn", complianceBefore, staticData, complianceResolution)
)
local complianceEffect = assert(findEvent(compliance.publicResult, "effect_applied"))
assert(complianceEffect.payload.op == "recover_stealth")
assert(complianceEffect.payload.amount == 2)
assert(complianceEffect.payload.source.kind == "system")
assert(complianceEffect.payload.source.id == "mood_state")

local rejectionBefore, rejectionResolution = buildScenario({
    mood = "rejection",
    startingStealth = 5,
    status = "defeat",
    effect = {
        op = "lose_stealth",
        amount = 6,
        delta = -6,
    },
})
local rejection = assertOk(
    "rejection mood defeat tail",
    projector("mood-tail-check", "projectTurn", rejectionBefore, staticData, rejectionResolution)
)
local outcome = assert(findEvent(rejection.publicResult, "outcome"))
assert(outcome.payload.status == "defeat")
assert(outcome.payload.reasonCode == "mood_state_checkpoint")

local ignoreBefore, ignoreResolution = buildScenario({
    mood = "ignore",
    startingStealth = 10,
    status = "active",
})
assertOk(
    "ignore mood direct cleanup",
    projector("mood-tail-check", "projectTurn", ignoreBefore, staticData, ignoreResolution)
)

local tampered = deepCopy(complianceResolution)
local tamperedEffect = tampered.events[6]
tamperedEffect.payload.amount = 3
tamperedEffect.payload.after = 13
tampered.afterState.player.stealth = 13
local rejected = projector("mood-tail-check", "projectTurn", complianceBefore, staticData, tampered)
assert(rejected.ok == false)
assert(rejected.errors[1].code == "invalid_mood_state_effect")

print("mood tail projector check: ok")
