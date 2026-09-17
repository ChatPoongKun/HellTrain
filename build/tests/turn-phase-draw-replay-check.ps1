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
    throw 'A Lua host is required.'
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
    battleHistory = loadLore("System/battleHistory.lua"),
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
    return assert(modules[name], "unknown module: " .. tostring(name))(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Perks.db"] = "DB/Perks.db",
    ["TokyoSubwayLines.db"] = "DB/TokyoSubwayLines.db",
    ["CharacterList.db"] = "Char/CharacterList.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
    ["YoonSeoa.db"] = "Char/YoonSeoa.db",
    ["HanJenny.db"] = "Char/HanJenny.db",
    ["SeoMiryeong.db"] = "Char/SeoMiryeong.db",
    ["SisterAgnes.db"] = "Char/SisterAgnes.db",
}

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local messages = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path)
                .. ": " .. tostring(item.message)
        end
        error(label .. " failed: " .. table.concat(messages, " | "))
    end
    return report
end

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

local function instance(instanceId, cardId, owner, zone, position)
    return { instanceId = instanceId, cardId = cardId, owner = owner, zone = zone, position = position }
end

local function newState(data, battleId, options)
    options = options or {}
    local planCardId = options.planCardId or "pc_deceiver_011"
    local characterPlanCardId = options.characterPlanCardId
    local playerDeck = options.playerDeck or {
        "pc_predator_001",
        "pc_predator_002",
        "pc_predator_003",
        "pc_predator_004",
        "pc_predator_005",
    }
    local characterDeck = options.characterDeck or {
        "jiyoung_close_collar",
        "jiyoung_quiet_warning",
        "jiyoung_turn_to_corner",
        "jiyoung_timid_call_for_help",
    }
    local spec = {
        battleId = battleId,
        status = "active",
        turnNumber = options.turnNumber or 1,
        turnLimit = 9,
        transit = {
            algorithm = "tokyo_subway_segment_v1",
            lineId = "tokyo_metro_ginza",
            stationIds = { "g01", "g02", "g03", "g04", "g05", "g06", "g07", "g08", "g09", "g10" },
        },
        sceneContext = { weekday = "월요일", time = "아침 출근시간", weather = "맑음" },
        rng = { seed = 20260902, cursor = 0 },
        player = {
            stealth = options.stealth or 30,
            baseDrawCount = options.playerBaseDrawCount or 3,
            maxHandSize = 5, perkIds = {}, planCapacity = 1,
            planSlots = { {
                occupied = true, cardInstanceId = battleId .. "-plan", cardId = planCardId,
                placedTurn = 1,
                remainingTurns = options.planRemainingTurns or 4,
                remainingCharges = options.planRemainingCharges or 2,
                revealed = false,
            } },
        },
        character = {
            characterId = "yoo_jiyoung",
            resistance = options.resistance or 30,
            mood = options.mood or "ignore",
            moodTokens = options.moodTokens,
            traitIds = { "reserved" },
            baseDrawCount = 3, maxHandSize = 5, planCapacity = 1,
            planSlots = characterPlanCardId and { {
                occupied = true, cardInstanceId = battleId .. "-cplan", cardId = characterPlanCardId,
                placedTurn = 1,
                remainingTurns = options.characterPlanRemainingTurns or 2,
                remainingCharges = options.characterPlanRemainingCharges or 2,
                revealed = false,
            } } or {},
        },
        cardInstances = {
            instance(battleId .. "-plan", planCardId, "player", "plan", 1),
            instance(battleId .. "-p1", playerDeck[1], "player", "deck", 1),
            instance(battleId .. "-p2", playerDeck[2], "player", "deck", 2),
            instance(battleId .. "-p3", playerDeck[3], "player", "deck", 3),
            instance(battleId .. "-p4", playerDeck[4], "player", "deck", 4),
            instance(battleId .. "-p5", playerDeck[5], "player", "deck", 5),
            instance(battleId .. "-c1", characterDeck[1], "character", "deck", 1),
            instance(battleId .. "-c2", characterDeck[2], "character", "deck", 2),
            instance(battleId .. "-c3", characterDeck[3], "character", "deck", 3),
            instance(battleId .. "-c4", characterDeck[4], "character", "deck", 4),
        },
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
    if characterPlanCardId ~= nil then
        table.insert(spec.cardInstances, instance(
            battleId .. "-cplan",
            characterPlanCardId,
            "character",
            "plan",
            1
        ))
    end
    return assertOk("new state", runScript("turn-phase-draw-replay-check", "stateSchema", "newBattleState", spec, data)).value
end

local function runPass(data, battleId, expectedPhase)
    local state = newState(data, battleId)
    local turnId = battleId .. "-turn-001"
    local initialized = assertOk("initialize", runScript(
        "turn-phase-draw-replay-check", "turnInitializer", "prepareTurn", state, data, { turnId = turnId }
    ))
    local projection = assertOk("draft project", runScript(
        "turn-phase-draw-replay-check", "turnDraft", "project", initialized.state, data, initialized.draft
    )).projection
    local resolution = assertOk("resolve", runScript(
        "turn-phase-draw-replay-check", "turnResolver", "resolveTurn", initialized.state, data, projection, { turnId = turnId }
    )).resolution

    local sawDraw = false
    for _, event in ipairs(resolution.events) do
        local payload = event.payload
        if event.phase == expectedPhase and event.type == "effect_applied"
            and type(payload) == "table" and payload.op == "draw_cards"
            and type(event.source) == "table" and event.source.id == "pc_deceiver_011" then
            sawDraw = #payload.drawnInstanceIds == 1
        end
    end
    assert(sawDraw, expectedPhase .. " plan draw was not recorded")
    assertOk("event projection", runScript(
        "turn-phase-draw-replay-check", "turnEventProjector", "projectTurn", initialized.state, data, resolution
    ))
end

local staticData = assertOk("static load", runScript(
    "turn-phase-draw-replay-check", "staticData", "loadAll"
)).data
local allStartEffectsData = clone(staticData)
allStartEffectsData.cards.pc_deceiver_011.mechanismData.plan.resolve = function()
    return {
        { op = "damage_resistance", target = "character", amount = 1, cause = "plan_effect" },
        { op = "recover_resistance", target = "character", amount = 1, cause = "plan_effect" },
        { op = "lose_stealth", target = "player", amount = 1, cause = "plan_effect" },
        { op = "recover_stealth", target = "player", amount = 1, cause = "plan_effect" },
        { op = "draw_cards", target = "player", amount = 1, cause = "plan_effect" },
        { op = "skip_actions", target = "player", scope = "remainingTurn", cause = "plan_effect" },
        { op = "add_mood_token", target = "character", mood = "suspicion", amount = 1, cause = "plan_effect" },
        { op = "remove_mood_token", target = "character", mood = "suspicion", amount = 1, cause = "plan_effect" },
        { op = "force_mood", target = "character", mood = "compliance", cause = "plan_effect" },
    }
end
runPass(allStartEffectsData, "start-effects-regression", "turn_start")

local turnEndData = clone(staticData)
turnEndData.cards.pc_deceiver_011.mechanismData.plan.event = "turn_end"
runPass(turnEndData, "end-draw-regression", "turn_end")

local operationBattleId = "plan-operation-regression"
local operationState = newState(staticData, operationBattleId, {
    planCardId = "pc_deceiver_010",
    playerDeck = {
        "pc_deceiver_013",
        "pc_predator_002",
        "pc_predator_001",
        "pc_predator_003",
        "pc_predator_004",
    },
})
local operationTurnId = operationBattleId .. "-turn-001"
local operationInitialized = assertOk("operation initialize", runScript(
    "turn-phase-draw-replay-check",
    "turnInitializer",
    "prepareTurn",
    operationState,
    staticData,
    { turnId = operationTurnId }
))
local operationDraft = operationInitialized.draft
for _, instanceId in ipairs({ operationBattleId .. "-p1", operationBattleId .. "-p2" }) do
    operationDraft = assertOk("operation register", runScript(
        "turn-phase-draw-replay-check",
        "turnDraft",
        "registerCard",
        operationInitialized.state,
        staticData,
        operationDraft,
        instanceId
    )).draft
end
local operationProjection = assertOk("operation project", runScript(
    "turn-phase-draw-replay-check",
    "turnDraft",
    "project",
    operationInitialized.state,
    staticData,
    operationDraft
)).projection
local operationResolution = assertOk("operation resolve", runScript(
    "turn-phase-draw-replay-check",
    "turnResolver",
    "resolveTurn",
    operationInitialized.state,
    staticData,
    operationProjection,
    { turnId = operationTurnId }
)).resolution
local sawAdjustment = false
local sawExpensiveTrap = false
for _, event in ipairs(operationResolution.events) do
    local payload = event.payload
    if event.type == "plan_changed" and payload.action == "adjusted" then
        sawAdjustment = payload.before[1].remainingTurns == 4
            and payload.before[1].remainingCharges == 2
            and payload.after[1].remainingTurns == 5
            and payload.after[1].remainingCharges == 3
    elseif event.type == "effect_applied" and event.source.id == "pc_deceiver_010"
        and payload.op == "damage_resistance" and payload.amount == 3 then
        sawExpensiveTrap = true
    end
end
assert(sawAdjustment, "plan operation did not record its full slot transition")
assert(sawExpensiveTrap, "card_declared trigger did not receive finalStealthCost")
assertOk("operation event projection", runScript(
    "turn-phase-draw-replay-check",
    "turnEventProjector",
    "projectTurn",
    operationInitialized.state,
    staticData,
    operationResolution
))

local removeData = clone(staticData)
removeData.cards.pc_deceiver_013.planOperation = { kind = "remove", side = "character" }
local removeBattleId = "cross-side-plan-removal"
local removeState = newState(removeData, removeBattleId, {
    planCardId = "pc_deceiver_010",
    characterPlanCardId = "jiyoung_phone_in_hand",
    playerDeck = {
        "pc_deceiver_013",
        "pc_predator_001",
        "pc_predator_002",
        "pc_predator_003",
        "pc_predator_004",
    },
})
local removeTurnId = removeBattleId .. "-turn-001"
local removeInitialized = assertOk("remove initialize", runScript(
    "turn-phase-draw-replay-check",
    "turnInitializer",
    "prepareTurn",
    removeState,
    removeData,
    { turnId = removeTurnId }
))
local removeDraft = removeInitialized.draft
for _, instanceId in ipairs({ removeBattleId .. "-p1", removeBattleId .. "-p2" }) do
    removeDraft = assertOk("remove register", runScript(
        "turn-phase-draw-replay-check",
        "turnDraft",
        "registerCard",
        removeInitialized.state,
        removeData,
        removeDraft,
        instanceId
    )).draft
end
local removeProjection = assertOk("remove project", runScript(
    "turn-phase-draw-replay-check",
    "turnDraft",
    "project",
    removeInitialized.state,
    removeData,
    removeDraft
)).projection
local removeResolution = assertOk("remove resolve", runScript(
    "turn-phase-draw-replay-check",
    "turnResolver",
    "resolveTurn",
    removeInitialized.state,
    removeData,
    removeProjection,
    { turnId = removeTurnId }
)).resolution
local sawCrossSideRemoval = false
for _, event in ipairs(removeResolution.events) do
    if event.type == "plan_changed" and event.payload.action == "removed"
        and event.side == "character" and event.source.id == "jiyoung_phone_in_hand" then
        sawCrossSideRemoval = #event.payload.before == 1
            and #event.payload.after == 0
            and event.payload.discarded == true
    end
end
assert(sawCrossSideRemoval, "cross-side plan removal was not recorded")
assertOk("remove event projection", runScript(
    "turn-phase-draw-replay-check",
    "turnEventProjector",
    "projectTurn",
    removeInitialized.state,
    removeData,
    removeResolution
))

local rejectionBattleId = "rejection-mood-state-regression"
local rejectionState = newState(staticData, rejectionBattleId, {
    mood = "rejection",
    moodTokens = {
        rejection = 0,
        suspicion = 0,
        ignore = 0,
        confusion = 0,
        compliance = 0,
    },
    planCardId = "pc_deceiver_010",
})
local rejectionTurnId = rejectionBattleId .. "-turn-001"
local rejectionInitialized = assertOk("rejection initialize", runScript(
    "turn-phase-draw-replay-check",
    "turnInitializer",
    "prepareTurn",
    rejectionState,
    staticData,
    { turnId = rejectionTurnId }
))
local rejectionProjection = assertOk("rejection project", runScript(
    "turn-phase-draw-replay-check",
    "turnDraft",
    "project",
    rejectionInitialized.state,
    staticData,
    rejectionInitialized.draft
)).projection
local rejectionResolution = assertOk("rejection resolve", runScript(
    "turn-phase-draw-replay-check",
    "turnResolver",
    "resolveTurn",
    rejectionInitialized.state,
    staticData,
    rejectionProjection,
    { turnId = rejectionTurnId }
)).resolution
assertOk("rejection event projection", runScript(
    "turn-phase-draw-replay-check",
    "turnEventProjector",
    "projectTurn",
    rejectionInitialized.state,
    staticData,
    rejectionResolution
))

local moodBattleId = "mood-state-replay-regression"
local moodState = newState(staticData, moodBattleId, {
    turnNumber = 1,
    stealth = 29,
    resistance = 31,
    mood = "compliance",
    moodTokens = {
        rejection = 2,
        suspicion = 2,
        ignore = 2,
        confusion = 2,
        compliance = 0,
    },
    planCardId = "pc_deceiver_011",
    planRemainingTurns = 4,
    planRemainingCharges = 2,
    characterPlanCardId = "jiyoung_silent_glare",
    characterPlanRemainingTurns = 1,
    characterPlanRemainingCharges = 1,
    playerBaseDrawCount = 4,
    playerDeck = {
        "pc_harmonizer_004",
        "pc_predator_009",
        "pc_harmonizer_006",
        "pc_predator_001",
        "pc_predator_002",
    },
    characterDeck = {
        "jiyoung_hug_bag_close",
        "jiyoung_hug_bag_close",
        "jiyoung_hug_bag_close",
        "jiyoung_hug_bag_close",
    },
})
local moodTurnId = moodBattleId .. "-turn-001"
local moodInitialized = assertOk("mood initialize", runScript(
    "turn-phase-draw-replay-check",
    "turnInitializer",
    "prepareTurn",
    moodState,
    staticData,
    { turnId = moodTurnId }
))
local moodDraft = moodInitialized.draft
for _, instanceId in ipairs({ moodBattleId .. "-p1", moodBattleId .. "-p2" }) do
    moodDraft = assertOk("mood register", runScript(
        "turn-phase-draw-replay-check",
        "turnDraft",
        "registerCard",
        moodInitialized.state,
        staticData,
        moodDraft,
        instanceId
    )).draft
end
local interactionToken = assertOk("mood token", runScript(
    "turn-phase-draw-replay-check",
    "turnDraft",
    "interactionToken",
    moodInitialized.state,
    staticData,
    moodDraft
)).interactionToken
moodDraft = assertOk("mood choose", runScript(
    "turn-phase-draw-replay-check",
    "turnDraft",
    "applyInteraction",
    moodInitialized.state,
    staticData,
    moodDraft,
    {
        action = "choose",
        instanceId = moodBattleId .. "-p3",
        choiceId = "manipulate",
        expectedInteractionToken = interactionToken,
    }
)).draft
local moodProjection = assertOk("mood project", runScript(
    "turn-phase-draw-replay-check",
    "turnDraft",
    "project",
    moodInitialized.state,
    staticData,
    moodDraft
)).projection
local moodResolution = assertOk("mood resolve", runScript(
    "turn-phase-draw-replay-check",
    "turnResolver",
    "resolveTurn",
    moodInitialized.state,
    staticData,
    moodProjection,
    { turnId = moodTurnId }
)).resolution
assertOk("mood event projection", runScript(
    "turn-phase-draw-replay-check",
    "turnEventProjector",
    "projectTurn",
    moodInitialized.state,
    staticData,
    moodResolution
))

print("turn-phase-draw-replay-check: ok")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); assert(load(source,[[turn-phase-draw-replay-check]],[[t]],_G))()'
    $output = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Lua turn phase draw replay check failed.`n$($output -join "`n")"
    }
    $output
}
finally {
    Pop-Location
}
