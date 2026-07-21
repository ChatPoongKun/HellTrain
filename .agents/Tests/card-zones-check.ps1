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

local function call(action, ...)
    return runScript("card-zones-check", "cardZones", action, ...)
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

local function canonical(value)
    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    end
    if valueType == "number" or valueType == "boolean" then
        return tostring(value)
    end
    if valueType == "string" then
        return string.format("%q", value)
    end
    assert(valueType == "table", "unsupported canonical value: " .. valueType)

    local numericCount = 0
    local maximum = 0
    local stringKeys = {}
    for key in pairs(value) do
        if type(key) == "number" then
            numericCount = numericCount + 1
            maximum = math.max(maximum, key)
        else
            table.insert(stringKeys, key)
        end
    end
    if numericCount > 0 then
        assert(#stringKeys == 0 and numericCount == maximum, "fixture must be a dense array or object")
        local items = {}
        for index = 1, maximum do
            items[index] = canonical(value[index])
        end
        return "[" .. table.concat(items, ",") .. "]"
    end

    table.sort(stringKeys)
    local fields = {}
    for index, key in ipairs(stringKeys) do
        fields[index] = string.format("%q", key) .. ":" .. canonical(value[key])
    end
    return "{" .. table.concat(fields, ",") .. "}"
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

local function assertFailed(label, report)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors > 0, label .. " must return a structured error")
    return report
end

local function card(instanceId, owner, zone, position)
    return {
        instanceId = instanceId,
        cardId = "fixture_card",
        owner = owner,
        zone = zone,
        position = position,
    }
end

local function fixture(cards, seed, turnNumber)
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "zone-test-battle",
        status = "active",
        turnNumber = turnNumber or 1,
        turnLimit = 20,
        environmentId = "fixture_environment",
        rng = { seed = seed or 42, cursor = 0 },
        player = {
            stealth = 30,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = {},
            planSlot = { occupied = false },
        },
        character = {
            characterId = "fixture_character",
            resistance = 30,
            mood = "ignore",
            traitIds = {},
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = { occupied = false },
        },
        cardInstances = cards or {},
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local function appendCards(target, owner, zone, prefix, count)
    for position = 1, count do
        table.insert(target, card(prefix .. string.format("%02d", position), owner, zone, position))
    end
end

local function findInstance(state, instanceId)
    for _, instance in ipairs(state.cardInstances) do
        if instance.instanceId == instanceId then
            return instance
        end
    end
    return nil
end

local function zoneIds(state, owner, zone)
    local entries = {}
    for _, instance in ipairs(state.cardInstances) do
        if instance.owner == owner and instance.zone == zone then
            table.insert(entries, instance)
        end
    end
    table.sort(entries, function(left, right)
        if left.position ~= right.position then
            return left.position < right.position
        end
        return left.instanceId < right.instanceId
    end)
    local ids = {}
    for index, instance in ipairs(entries) do
        ids[index] = instance.instanceId
    end
    return ids
end

local function assertIds(label, actual, expected)
    assert(
        table.concat(actual, ",") == table.concat(expected, ","),
        label .. " expected " .. table.concat(expected, ",") .. " but got " .. table.concat(actual, ",")
    )
end

local function assertPositions(state)
    for _, owner in ipairs({ "player", "character" }) do
        for _, zone in ipairs({ "deck", "hand", "used", "discard", "removed", "plan" }) do
            local positions = {}
            for _, instance in ipairs(state.cardInstances) do
                if instance.owner == owner and instance.zone == zone then
                    table.insert(positions, instance.position)
                end
            end
            table.sort(positions)
            for index, position in ipairs(positions) do
                assert(position == index, owner .. "/" .. zone .. " positions are not contiguous")
            end
        end
    end
end

local function assertConserved(label, beforeState, afterState)
    assertOk(label .. " conservation", call("validateConservation", beforeState, afterState))
end

local function assertBattleState(label, state)
    assertOk(label, runScript("card-zones-check", "stateSchema", "validateBattleState", state, nil))
end

local function operation(label, action, beforeState, ...)
    local inputSnapshot = canonical(beforeState)
    local report = assertOk(label, call(action, beforeState, ...))
    assert(type(report.state) == "table", label .. " did not return a state")
    assert(canonical(beforeState) == inputSnapshot, label .. " mutated its input state")
    assert(report.state ~= beforeState, label .. " returned its input state")
    assertPositions(report.state)
    assertConserved(label, beforeState, report.state)
    return report
end

local integrationStaticData = assertOk(
    "cleanup receipt static load",
    runScript("card-zones-check", "staticData", "loadAll")
).data

local configured = fixture()
assert(configured.player.baseDrawCount == 3 and configured.player.maxHandSize == 5)
assert(configured.character.baseDrawCount == 3 and configured.character.maxHandSize == 5)
assertBattleState("configured battleState", configured)

local overLimitCards = {}
appendCards(overLimitCards, "player", "hand", "over", 6)
local overLimitState = fixture(overLimitCards)
local overLimitSnapshot = canonical(overLimitState)
assertFailed("over-limit hand input", call("draw", overLimitState, "player", 0))
assert(canonical(overLimitState) == overLimitSnapshot, "failed over-limit draw mutated its input")

local duplicatePositionState = fixture({
    card("duplicate01", "player", "deck", 1),
    card("duplicate02", "player", "deck", 1),
})
local duplicatePositionSnapshot = canonical(duplicatePositionState)
assertFailed("duplicate position input", call("shuffleDeck", duplicatePositionState, "player"))
assert(canonical(duplicatePositionState) == duplicatePositionSnapshot, "failed duplicate-position shuffle mutated its input")

-- These ten arbitrary instances are a zone-engine test fixture. They are not
-- the game's initial ten-card deck composition and must not be treated as one.
local initialCards = {}
appendCards(initialCards, "player", "deck", "p", 10)
appendCards(initialCards, "character", "deck", "c", 4)
local initialState = fixture(initialCards, 42)
local initialSnapshot = canonical(initialState)
local initialShuffle = operation("fixed initial shuffle", "shuffleDeck", initialState, "player")
local expectedInitialOrder = { "p10", "p03", "p06", "p05", "p08", "p07", "p02", "p09", "p01", "p04" }
assertIds("fixed initial shuffle order", zoneIds(initialShuffle.state, "player", "deck"), expectedInitialOrder)
assert(initialShuffle.state.rng.seed == 42 and initialShuffle.state.rng.cursor == 9)
assertIds("other owner untouched", zoneIds(initialShuffle.state, "character", "deck"), { "c01", "c02", "c03", "c04" })
assert(canonical(initialState) == initialSnapshot, "initial shuffle mutated its input")
local replayShuffle = operation("fixed initial shuffle replay", "shuffleDeck", initialState, "player")
assert(canonical(replayShuffle.state) == canonical(initialShuffle.state), "fixed shuffle was not reproducible")

local enoughCards = {}
appendCards(enoughCards, "player", "deck", "d", 4)
local enoughState = fixture(enoughCards, 71)
local enoughDraw = operation("sufficient deck draw", "draw", enoughState, "player", 3)
assertIds("sufficient drawn ids", enoughDraw.drawnInstanceIds, { "d01", "d02", "d03" })
assertIds("sufficient hand", zoneIds(enoughDraw.state, "player", "hand"), { "d01", "d02", "d03" })
assertIds("sufficient deck remainder", zoneIds(enoughDraw.state, "player", "deck"), { "d04" })
assert(enoughDraw.state.rng.cursor == 0, "ordinary draw consumed RNG")

local capCards = {
    card("h01", "player", "hand", 1),
    card("h02", "player", "hand", 2),
    card("h03", "player", "hand", 3),
    card("h04", "player", "hand", 4),
    card("d01", "player", "deck", 1),
    card("d02", "player", "deck", 2),
    card("d03", "player", "deck", 3),
}
local capped = operation("maximum hand cap", "draw", fixture(capCards, 9), "player", 3)
assertIds("capped draw ids", capped.drawnInstanceIds, { "d01" })
assert(#zoneIds(capped.state, "player", "hand") == 5, "draw exceeded max hand size 5")
assertIds("capped deck remainder", zoneIds(capped.state, "player", "deck"), { "d02", "d03" })

local refillCards = {
    card("d01", "player", "deck", 1),
    card("x01", "player", "discard", 1),
    card("x02", "player", "discard", 2),
    card("x03", "player", "discard", 3),
}
local refilled = operation("partial deck then discard reshuffle", "draw", fixture(refillCards, 42), "player", 3)
assertIds("partial plus reshuffle draw", refilled.drawnInstanceIds, { "d01", "x02", "x01" })
assertIds("reshuffle deck remainder", zoneIds(refilled.state, "player", "deck"), { "x03" })
assert(#zoneIds(refilled.state, "player", "discard") == 0, "reshuffled discard was not emptied")
assert(refilled.state.rng.cursor == 2, "three-card reshuffle consumed an unexpected RNG count")

local shortageCards = {
    card("d01", "player", "deck", 1),
    card("x01", "player", "discard", 1),
}
local shortage = operation("total card shortage partial draw", "draw", fixture(shortageCards, 8), "player", 5)
assertIds("partial draw ids", shortage.drawnInstanceIds, { "d01", "x01" })
assert(#zoneIds(shortage.state, "player", "hand") == 2, "partial draw did not stop at available total")

local currentTurnCards = {
    card("read", "player", "hand", 1),
    card("h02", "player", "hand", 2),
    card("h03", "player", "hand", 3),
    card("old-used", "player", "used", 1),
    card("refill", "player", "discard", 1),
    card("kept-plan", "player", "plan", 1),
    card("gone", "player", "removed", 1),
}
local currentTurnState = fixture(currentTurnCards, 17)
currentTurnState.player.planSlot = {
    occupied = true,
    cardInstanceId = "kept-plan",
    cardId = "fixture_card",
    placedTurn = 1,
    remainingTurns = 2,
    revealed = false,
}
currentTurnState.selection.playerCardInstanceIds = { "read" }
local played = operation("current turn hand to used", "moveHandToUsed", currentTurnState, "read")
assertIds("used order after play", zoneIds(played.state, "player", "used"), { "old-used", "read" })
local restored = operation("unused selection restored to hand", "moveUsedToHand", played.state, "read")
assertIds("restored card appended to hand", zoneIds(restored.state, "player", "hand"), { "h02", "h03", "read" })
assertIds("resolved prefix remains used", zoneIds(restored.state, "player", "used"), { "old-used" })
assertFailed("restore requires used source", call("moveUsedToHand", currentTurnState, "read"))
local fullHandWithUsed = fixture({
    card("full01", "player", "hand", 1),
    card("full02", "player", "hand", 2),
    card("full03", "player", "hand", 3),
    card("full04", "player", "hand", 4),
    card("full05", "player", "hand", 5),
    card("cannot-restore", "player", "used", 1),
})
fullHandWithUsed.selection.playerCardInstanceIds = { "cannot-restore" }
local fullHandSnapshot = canonical(fullHandWithUsed)
local overCapRestore = operation("structural restore may temporarily exceed hand cap", "moveUsedToHand", fullHandWithUsed, "cannot-restore")
assert(#zoneIds(overCapRestore.state, "player", "hand") == 6, "structural restore did not preserve the unplayed card")
assert(canonical(fullHandWithUsed) == fullHandSnapshot, "structural restore mutated full-hand input")
local overCapCleanup = operation("structural over-cap restore cleanup", "endTurnCleanup", overCapRestore.state)
assert(#zoneIds(overCapCleanup.state, "player", "hand") == 0, "cleanup retained an over-cap hand")
assertBattleState("structural restore final state", overCapCleanup.state)
local workingStateValidation = runScript(
    "card-zones-check",
    "stateSchema",
    "validateBattleState",
    played.state,
    nil
)
assert(workingStateValidation.ok == false, "mid-resolution workingState was treated as a committed battleState")
local currentDraw = operation("current turn draw", "draw", played.state, "player", 4)
assertIds("current turn drawn ids", currentDraw.drawnInstanceIds, { "refill" })
assertIds("current turn used excluded", zoneIds(currentDraw.state, "player", "used"), { "old-used", "read" })
assertIds("current turn plan excluded", zoneIds(currentDraw.state, "player", "plan"), { "kept-plan" })
assertIds("current turn removed excluded", zoneIds(currentDraw.state, "player", "removed"), { "gone" })
local currentTurnCompleted = operation("current turn working state cleanup", "endTurnCleanup", currentDraw.state)
assertBattleState("current turn completed battleState", currentTurnCompleted.state)

local cleanupCards = {
    card("d00", "player", "discard", 1),
    card("u01", "player", "used", 1),
    card("u02", "player", "used", 2),
    card("h01", "player", "hand", 1),
    card("h02", "player", "hand", 2),
    card("cu01", "character", "used", 1),
    card("ch01", "character", "hand", 1),
}
local cleanupState = fixture(cleanupCards, 33)
cleanupState.selection.playerCardInstanceIds = { "h01" }
cleanupState.characterIntent = { cardInstanceIds = { "ch01" }, publicActionTag = "fixture_action" }
assertBattleState("cleanup input battleState", cleanupState)
local cleaned = operation("end turn cleanup order", "endTurnCleanup", cleanupState)
assertIds("player cleanup order", zoneIds(cleaned.state, "player", "discard"), { "d00", "u01", "u02", "h01", "h02" })
assertIds("character cleanup order", zoneIds(cleaned.state, "character", "discard"), { "cu01", "ch01" })
assertIds("cleanup moved order", cleaned.movedInstanceIds, { "u01", "u02", "h01", "h02", "cu01", "ch01" })
assert(#cleaned.state.selection.playerCardInstanceIds == 0, "cleanup did not reset player selection")
assert(#cleaned.state.characterIntent.cardInstanceIds == 0, "cleanup did not reset character intent")
assert(cleaned.state.characterIntent.publicActionTag == nil, "cleanup retained public character intent")
assertBattleState("cleanup completed battleState", cleaned.state)

local receiptAuthority = {
    schemaVersion = 1,
    kind = "battleState",
    battleId = "zone-receipt-battle",
    status = "active",
    turnNumber = 1,
    turnLimit = 20,
    environmentId = "uncrowded",
    rng = { seed = 33, cursor = 0 },
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
    cardInstances = {},
    selection = { playerCardInstanceIds = {} },
    characterIntent = { cardInstanceIds = {} },
}
local receiptInitialized = assertOk(
    "prepare cleanup receipt",
    runScript(
        "card-zones-check",
        "turnInitializer",
        "prepareTurn",
        receiptAuthority,
        integrationStaticData,
        { turnId = "zone-receipt-battle-turn-001" }
    )
)
assert(type(receiptInitialized.state.turnStartReceipt) == "table", "initializer did not attach cleanup receipt")
assertOk(
    "cleanup receipt input battleState",
    runScript(
        "card-zones-check",
        "stateSchema",
        "validateBattleState",
        receiptInitialized.state,
        integrationStaticData
    )
)
local receiptCleaned = operation("end turn cleanup removes receipt", "endTurnCleanup", receiptInitialized.state)
assert(receiptCleaned.state.turnStartReceipt == nil, "cleanup retained turnStartReceipt")
assertOk(
    "cleanup receipt output battleState",
    runScript(
        "card-zones-check",
        "stateSchema",
        "validateBattleState",
        receiptCleaned.state,
        integrationStaticData
    )
)

local removeCards = {
    card("remove-me", "player", "hand", 1),
    card("keep-hand", "player", "hand", 2),
}
local removed = operation("move to removed", "moveToRemoved", fixture(removeCards, 6), "remove-me")
assertIds("removed card", zoneIds(removed.state, "player", "removed"), { "remove-me" })
local removedCleanup = operation("removed survives cleanup", "endTurnCleanup", removed.state)
assertIds("removed preserved", zoneIds(removedCleanup.state, "player", "removed"), { "remove-me" })
assertIds("other hand discarded", zoneIds(removedCleanup.state, "player", "discard"), { "keep-hand" })

local replacementCards = {
    card("old-plan", "player", "plan", 1),
    card("new-plan", "player", "hand", 1),
    card("old-discard", "player", "discard", 1),
}
local replacementState = fixture(replacementCards, 23, 4)
replacementState.player.planSlot = {
    occupied = true,
    cardInstanceId = "old-plan",
    cardId = "fixture_card",
    placedTurn = 2,
    remainingTurns = 2,
    revealed = true,
}
local replacement = operation(
    "plan placement and replacement",
    "placePlan",
    replacementState,
    "player",
    "new-plan",
    { durationTurns = 2, charges = 2 }
)
assertIds("replacement moved order", replacement.movedInstanceIds, { "old-plan", "new-plan" })
assertIds("replaced plan discarded", zoneIds(replacement.state, "player", "discard"), { "old-discard", "old-plan" })
assertIds("new plan zone", zoneIds(replacement.state, "player", "plan"), { "new-plan" })
assert(replacement.state.player.planSlot.cardInstanceId == "new-plan")
assert(replacement.state.player.planSlot.placedTurn == 4)
assert(replacement.state.player.planSlot.remainingTurns == 2)
assert(replacement.state.player.planSlot.remainingCharges == 2)
assert(replacement.state.player.planSlot.revealed == false)

assertFailed(
    "zero duration plan input",
    call("placePlan", fixture({ card("bad-plan", "player", "hand", 1) }), "player", "bad-plan", { durationTurns = 0 })
)
assertFailed(
    "zero charge plan input",
    call("placePlan", fixture({ card("bad-plan", "player", "hand", 1) }), "player", "bad-plan", { charges = 0 })
)
assertFailed(
    "missing plan lifetime input",
    call("placePlan", fixture({ card("bad-plan", "player", "hand", 1) }), "player", "bad-plan", {})
)
assertFailed(
    "invalid placement turn duration flag",
    call(
        "placePlan",
        fixture({ card("bad-plan", "player", "hand", 1) }),
        "player",
        "bad-plan",
        { durationTurns = 1, durationIncludesPlacementTurn = "yes" }
    )
)
local placementPolicyWithoutDuration = assertFailed(
    "placement turn duration flag without duration",
    call(
        "placePlan",
        fixture({ card("bad-plan", "player", "hand", 1) }),
        "player",
        "bad-plan",
        { charges = 1, durationIncludesPlacementTurn = true }
    )
)
assert(placementPolicyWithoutDuration.errors[1].code == "plan_duration_policy_requires_duration",
    "placement-turn policy without duration returned the wrong error")

local durationPlaced = operation(
    "default duration plan placement",
    "placePlan",
    fixture({ card("duration-plan", "player", "hand", 1) }, 5, 3),
    "player",
    "duration-plan",
    { durationTurns = 1 }
)
local placementTurnCleanup = operation("placement turn duration cleanup", "endTurnCleanup", durationPlaced.state)
assert(placementTurnCleanup.state.player.planSlot.occupied == true)
assert(placementTurnCleanup.state.player.planSlot.remainingTurns == 1, "duration decreased on placement turn")
local nextTurnDurationState = clone(placementTurnCleanup.state)
nextTurnDurationState.turnNumber = 4
assertConserved("turn number advance", placementTurnCleanup.state, nextTurnDurationState)
local expiredDuration = operation("next turn duration expiry", "endTurnCleanup", nextTurnDurationState)
assert(expiredDuration.state.player.planSlot.occupied == false, "zero-duration plan remained occupied")
assertIds("expired duration discard", zoneIds(expiredDuration.state, "player", "discard"), { "duration-plan" })
assertIds("expired duration moved", expiredDuration.movedInstanceIds, { "duration-plan" })

local placementTurnCountingPlaced = operation(
    "placement-turn-counting duration plan placement",
    "placePlan",
    fixture({ card("placement-turn-plan", "player", "hand", 1) }, 7, 3),
    "player",
    "placement-turn-plan",
    { durationTurns = 1, durationIncludesPlacementTurn = true }
)
assert(placementTurnCountingPlaced.state.player.planSlot.occupied == true)
assert(placementTurnCountingPlaced.state.player.planSlot.remainingTurns == 1)
assert(placementTurnCountingPlaced.state.player.planSlot.durationIncludesPlacementTurn == true,
    "placement-turn duration flag was not retained in the plan slot")
local placementTurnExpired = operation(
    "placement turn duration expiry",
    "endTurnCleanup",
    placementTurnCountingPlaced.state
)
assert(placementTurnExpired.state.player.planSlot.occupied == false,
    "placement-turn-counting duration-1 plan remained occupied")
assertIds(
    "placement turn duration discard",
    zoneIds(placementTurnExpired.state, "player", "discard"),
    { "placement-turn-plan" }
)
assertIds(
    "placement turn duration moved",
    placementTurnExpired.movedInstanceIds,
    { "placement-turn-plan" }
)

local oneCharge = operation(
    "one charge plan placement",
    "placePlan",
    fixture({ card("charge-one", "player", "hand", 1) }, 10, 2),
    "player",
    "charge-one",
    { durationTurns = 5, charges = 1 }
)
local oneChargeTriggered = operation("one charge immediate discard", "consumePlanCharge", oneCharge.state, "player")
assert(oneChargeTriggered.state.player.planSlot.occupied == false, "zero-charge plan remained occupied")
assertIds("one charge discard", zoneIds(oneChargeTriggered.state, "player", "discard"), { "charge-one" })
assertIds("one charge moved", oneChargeTriggered.movedInstanceIds, { "charge-one" })

local multiCharge = operation(
    "multi charge plan placement",
    "placePlan",
    fixture({ card("charge-many", "player", "hand", 1) }, 10, 2),
    "player",
    "charge-many",
    { charges = 3 }
)
local multiChargeTriggered = operation("multi charge decrement", "consumePlanCharge", multiCharge.state, "player")
assert(multiChargeTriggered.state.player.planSlot.occupied == true)
assert(multiChargeTriggered.state.player.planSlot.remainingCharges == 2)
assert(multiChargeTriggered.state.player.planSlot.revealed == true)
assert(#multiChargeTriggered.movedInstanceIds == 0, "nonzero charge plan was moved")

local durationOnly = operation(
    "duration only plan placement",
    "placePlan",
    fixture({ card("duration-only", "character", "hand", 1) }, 12, 2),
    "character",
    "duration-only",
    { durationTurns = 3 }
)
local durationOnlyTriggered = operation("duration only reveal", "consumePlanCharge", durationOnly.state, "character")
assert(durationOnlyTriggered.state.character.planSlot.occupied == true)
assert(durationOnlyTriggered.state.character.planSlot.remainingTurns == 3)
assert(durationOnlyTriggered.state.character.planSlot.remainingCharges == nil)
assert(durationOnlyTriggered.state.character.planSlot.revealed == true)
assert(#durationOnlyTriggered.movedInstanceIds == 0, "duration-only plan moved after trigger")

local conservationBase = fixture({
    card("a", "player", "deck", 1),
    card("b", "character", "hand", 1),
})
local missingCard = clone(conservationBase)
table.remove(missingCard.cardInstances, 2)
assertFailed("conservation missing card", call("validateConservation", conservationBase, missingCard))
local addedCard = clone(conservationBase)
table.insert(addedCard.cardInstances, card("c", "player", "discard", 1))
assertFailed("conservation added card", call("validateConservation", conservationBase, addedCard))
local changedCard = clone(conservationBase)
changedCard.cardInstances[1].cardId = "changed_fixture_identity"
assertFailed("conservation changed identity", call("validateConservation", conservationBase, changedCard))
local duplicateCard = clone(conservationBase)
table.insert(duplicateCard.cardInstances, clone(duplicateCard.cardInstances[1]))
duplicateCard.cardInstances[3].position = 2
assertFailed("conservation duplicate id", call("validateConservation", conservationBase, duplicateCard))

local soakCards = {}
appendCards(soakCards, "player", "deck", "sp", 10)
appendCards(soakCards, "character", "deck", "sc", 8)
local soakState = fixture(soakCards, 424242, 1)

local function soakOperation(label, action, ...)
    local report = operation(label, action, soakState, ...)
    soakState = report.state
    return report
end

soakOperation("soak initial player shuffle", "shuffleDeck", "player")
soakOperation("soak initial character shuffle", "shuffleDeck", "character")
for turn = 1, 10 do
    assert(soakState.turnNumber == turn, "soak turn number drifted")
    soakOperation("soak player draw " .. turn, "draw", "player", soakState.player.baseDrawCount)
    soakOperation("soak character draw " .. turn, "draw", "character", soakState.character.baseDrawCount)

    local playerHand = zoneIds(soakState, "player", "hand")
    if #playerHand > 0 then
        soakOperation("soak player use " .. turn, "moveHandToUsed", playerHand[1])
        soakOperation("soak current-turn replacement draw " .. turn, "draw", "player", 1)
    end
    local characterHand = zoneIds(soakState, "character", "hand")
    if #characterHand > 0 then
        soakOperation("soak character use " .. turn, "moveHandToUsed", characterHand[1])
    end

    if turn == 3 then
        playerHand = zoneIds(soakState, "player", "hand")
        if #playerHand > 0 then
            soakOperation("soak permanent removal", "moveToRemoved", playerHand[#playerHand])
        end
    end

    if turn == 2 or turn == 6 then
        playerHand = zoneIds(soakState, "player", "hand")
        if #playerHand > 0 then
            soakOperation(
                "soak plan placement " .. turn,
                "placePlan",
                "player",
                playerHand[1],
                { durationTurns = 2, charges = 2 }
            )
        end
    elseif turn % 2 == 1 and soakState.player.planSlot.occupied then
        soakOperation("soak plan trigger " .. turn, "consumePlanCharge", "player")
    end

    playerHand = zoneIds(soakState, "player", "hand")
    soakState.selection.playerCardInstanceIds = #playerHand > 0 and { playerHand[1] } or {}
    soakState.characterIntent.cardInstanceIds = {}
    soakOperation("soak cleanup " .. turn, "endTurnCleanup")
    assert(#soakState.selection.playerCardInstanceIds == 0, "soak cleanup retained selection")
    assertBattleState("soak completed battleState " .. turn, soakState)

    if turn < 10 then
        local advanced = clone(soakState)
        advanced.turnNumber = turn + 1
        assertPositions(advanced)
        assertConserved("soak turn advance " .. turn, soakState, advanced)
        soakState = advanced
    end
end

assert(#soakState.cardInstances == 18, "soak lost or duplicated a card")
assertPositions(soakState)
local finalConservation = assertOk("soak whole-run conservation", call("validateConservation", fixture(soakCards, 424242, 1), soakState))
assert(finalConservation.state ~= soakState, "conservation returned the after-state input")

print(
    "VECTOR|shuffle=" .. table.concat(zoneIds(initialShuffle.state, "player", "deck"), ",")
        .. "|partial=" .. table.concat(refilled.drawnInstanceIds, ",")
        .. "|soak-player=" .. table.concat(zoneIds(soakState, "player", "discard"), ",")
        .. "|soak-rng=" .. tostring(soakState.rng.cursor)
)
'@

Push-Location $projectRoot
try {
    $env:RISU_CARD_ZONES_TEST = $luaTest

    $firstOutput = @(& $luaHost -e 'assert(load(os.getenv([[RISU_CARD_ZONES_TEST]]),[[card-zones-check]],[[t]],_G))()' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua 카드 영역 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @(& $luaHost -e 'assert(load(os.getenv([[RISU_CARD_ZONES_TEST]]),[[card-zones-check]],[[t]],_G))()' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua 카드 영역 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 카드 영역 결과를 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if (-not $firstText.StartsWith('VECTOR|shuffle=p10,p03,p06,p05,p08,p07,p02,p09,p01,p04|')) {
        throw "카드 영역 결정성 표식이 예상과 다릅니다: $firstText"
    }

    Write-Output 'card-zones-check: ok'
    Write-Output 'NOTE: 실제 RisuAI 통합 환경에서는 아직 검증하지 않았습니다.'
}
finally {
    Remove-Item Env:RISU_CARD_ZONES_TEST -ErrorAction SilentlyContinue
    Pop-Location
}
