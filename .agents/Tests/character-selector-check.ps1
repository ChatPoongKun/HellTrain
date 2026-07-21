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
    effectEngine = loadLore("System/effectEngine.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
    staticData = loadLore("System/staticData.lua"),
    characterSelector = loadLore("System/characterSelector.lua"),
}

function runScript(triggerId, name, ...)
    return assert(modules[name], "unknown module: " .. tostring(name))(triggerId, ...)
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
local loreOverrides = {}

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    if not path then
        return {}
    end
    return { { content = loreOverrides[name] or readFile(path) } }
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

local function assertHasError(label, report, code)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    for _, item in ipairs(type(report.errors) == "table" and report.errors or {}) do
        if item.code == code then
            return item
        end
    end
    failReport(label .. " missing " .. code, report)
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
    if value == nil then return "nil" end
    if valueType == "number" or valueType == "boolean" then return tostring(value) end
    if valueType == "string" then return string.format("%q", value) end
    assert(valueType == "table", "unsupported canonical value: " .. valueType)
    active = active or {}
    assert(not active[value], "cycle in canonical fixture")
    active[value] = true
    local keys = {}
    for key in pairs(value) do table.insert(keys, key) end
    table.sort(keys, function(left, right)
        return type(left) .. ":" .. tostring(left) < type(right) .. ":" .. tostring(right)
    end)
    local values = {}
    for _, key in ipairs(keys) do
        table.insert(values, canonical(key, active) .. "=" .. canonical(value[key], active))
    end
    active[value] = nil
    return "{" .. table.concat(values, ",") .. "}"
end

local function instance(instanceId, cardId, zone, position)
    return {
        instanceId = instanceId,
        cardId = cardId,
        owner = "character",
        zone = zone,
        position = position,
    }
end

local IDS = {
    close_collar = "character-close",
    quiet_warning = "character-warning",
    turn_to_corner = "character-turn",
    silent_glare = "character-glare",
}

local function fixture()
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "character-selector-battle",
        status = "active",
        turnNumber = 1,
        turnLimit = 10,
        environmentId = "uncrowded",
        rng = { seed = 42, cursor = 0 },
        player = {
            stealth = 10,
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
            instance(IDS.close_collar, "close_collar", "hand", 1),
            instance(IDS.quiet_warning, "quiet_warning", "hand", 2),
            instance(IDS.turn_to_corner, "turn_to_corner", "hand", 3),
            instance(IDS.silent_glare, "silent_glare", "hand", 4),
        },
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local function call(state, staticData)
    return runScript("character-selector-check", "characterSelector", "selectIntent", state, staticData)
end

local function candidateMap(report)
    local values = {}
    for _, candidate in ipairs(report.receipt.candidates) do
        values[candidate.cardId] = candidate
    end
    return values
end

local staticReport = assertOk("load static data", runScript("character-selector-check", "staticData", "loadAll"))
local staticData = staticReport.data
local plan = staticData.cards.silent_glare.mechanismData.plan
assert(plan.selectionAssumption.event.type == "card_declared", "plan selection event type changed")
assert(plan.selectionAssumption.event.side == "player", "plan selection event side changed")
assert(plan.selectionAssumption.chargePolicy == "all", "plan charge policy changed")

-- The static loader owns the function-free plan assumption contract.
local invalidLore, replacementCount = readFile("DB/CharacterCards.db"):gsub(
    'chargePolicy = "all"',
    'chargePolicy = "first"',
    1
)
assert(replacementCount == 1, "plan assumption fixture replacement failed")
loreOverrides["CharacterCards.db"] = invalidLore
assertHasError(
    "invalid plan charge policy loader",
    runScript("character-selector-check", "staticData", "loadAll"),
    "invalid_plan_selection_charge_policy"
)
loreOverrides["CharacterCards.db"] = nil

local baseState = fixture()
assertOk("base state", runScript("character-selector-check", "stateSchema", "validateBattleState", baseState, staticData))
local baseSnapshot = canonical(baseState)
local selected = assertOk("select current hand", call(baseState, staticData))
assert(canonical(baseState) == baseSnapshot, "selection mutated its input state")
assert(selected.state ~= baseState and selected.intent ~= baseState.characterIntent, "selection result aliases input state")
assert(selected.intent ~= selected.state.characterIntent, "selection intent aliases its sibling state")
assert(selected.intent.cardInstanceIds[1] == IDS.turn_to_corner, "fixed-seed score-weighted selection changed")
assert(selected.intent.publicActionTag == "evade", "public action tag must come from the selected main action")
assert(selected.receipt.draw.kind == "weighted", "multi-card pool must use weighted RNG")
assert(selected.receipt.draw.totalWeight == 12 and selected.receipt.draw.roll == 6,
    "score-weighted draw receipt changed")
assert(selected.receipt.weightOffset == 0, "positive-score pool must not shift weights")
assert(selected.state.rng.cursor == 1 and selected.receipt.rngAfter.cursor == 1,
    "score-weighted selection did not consume RNG exactly once")
assertOk("selected state", runScript("character-selector-check", "stateSchema", "validateBattleState", selected.state, staticData))

local scores = candidateMap(selected)
assert(scores.close_collar.score == 3, "close_collar score changed")
assert(scores.quiet_warning.score == 2, "quiet_warning score changed")
assert(scores.turn_to_corner.score == 4, "turn_to_corner score changed")
assert(scores.silent_glare.score == 3, "silent_glare all-charge plan score changed")
assert(scores.close_collar.weight == 3 and scores.quiet_warning.weight == 2
    and scores.turn_to_corner.weight == 4 and scores.silent_glare.weight == 3,
    "positive total effects were not used directly as weights")
assert(scores.close_collar.affinity == nil and scores.quiet_warning.affinity == nil,
    "removed affinity data leaked into the receipt")
assert(scores.silent_glare.planChargesEvaluated == 1, "silent_glare charge count changed")
assert(scores.close_collar.totals.recoverResistance == 3, "recover_resistance total changed")
assert(scores.quiet_warning.totals.loseStealth == 2, "lose_stealth total changed")

local replayedReceipt = assertOk("replay selection receipt", runScript(
    "character-selector-check",
    "characterSelector",
    "validateReceipt",
    staticData,
    selected.receipt,
    baseState
))
assert(replayedReceipt.valid == true, "selection receipt replay did not return valid")

-- validateReceipt must remain below stateSchema in the dependency graph.
local realStateSchema = modules.stateSchema
modules.stateSchema = function()
    error("validateReceipt must not call stateSchema")
end
assertOk("receipt replay without stateSchema", runScript(
    "character-selector-check",
    "characterSelector",
    "validateReceipt",
    staticData,
    selected.receipt,
    baseState
))
modules.stateSchema = realStateSchema

local alteredPlanAudit = clone(selected.receipt)
candidateMap({ receipt = alteredPlanAudit }).silent_glare.planChargesEvaluated = 2
assertHasError("plan charge replay", runScript(
    "character-selector-check",
    "characterSelector",
    "validateReceipt",
    staticData,
    alteredPlanAudit,
    baseState
), "selection_candidate_replay_mismatch")

-- Lethal projected stealth is considered before a larger non-lethal total score.
local lethalState = fixture()
lethalState.player.stealth = 3
local lethal = assertOk("lethal priority", call(lethalState, staticData))
assert(lethal.intent.cardInstanceIds[1] == IDS.silent_glare, "lethal plan did not outrank larger non-lethal recovery")
assert(lethal.receipt.lethalPriorityApplied == true, "lethal priority receipt missing")
assert(candidateMap(lethal).silent_glare.projectedPlayerStealth == 0, "lethal projected stealth changed")
assert(#lethal.receipt.weightedPoolInstanceIds == 1
    and lethal.receipt.weightedPoolInstanceIds[1] == IDS.silent_glare,
    "lethal pool was not isolated")
assert(lethal.receipt.draw.kind == "single", "unique lethal pool must use single selection")
assert(lethal.state.rng.cursor == 0, "unique lethal selection consumed RNG")

-- Every plan charge is evaluated through the protected trigger callback and summed.
local doublePlanStatic = clone(staticData)
doublePlanStatic.cards.silent_glare.mechanismData.plan.charges = 2
local doublePlan = assertOk("all plan charges", call(fixture(), doublePlanStatic))
local doublePlanScore = candidateMap(doublePlan).silent_glare
assert(doublePlanScore.score == 6, "two plan charges were not fully summed")
assert(doublePlanScore.totals.loseStealth == 6 and doublePlanScore.planChargesEvaluated == 2,
    "plan charge receipt changed")
assert(doublePlanScore.weight == 6 and doublePlan.receipt.draw.totalWeight == 15,
    "all-charge plan score was not used as its weight")
assert(doublePlan.receipt.draw.roll == 9, "all-charge fixed-seed roll changed")
assert(doublePlan.intent.cardInstanceIds[1] == IDS.turn_to_corner,
    "weighted draw unexpectedly collapsed to the maximum-score card")

-- When every eligible score is non-positive, a single parallel shift makes every weight positive.
local shiftedStatic = clone(staticData)
shiftedStatic.cards.close_collar.resolve = function()
    return { { op = "damage_resistance", target = "character", amount = 1, cause = "test" } }
end
shiftedStatic.cards.quiet_warning.resolve = function()
    return { { op = "damage_resistance", target = "character", amount = 3, cause = "test" } }
end
shiftedStatic.cards.turn_to_corner.resolve = function()
    return { { op = "damage_resistance", target = "character", amount = 2, cause = "test" } }
end
shiftedStatic.cards.silent_glare.mechanismData.plan.resolve = function()
    return { { op = "damage_resistance", target = "character", amount = 4, cause = "test" } }
end
local shiftedState = fixture()
local shiftedSnapshot = canonical(shiftedState)
local shiftedA = assertOk("shifted weights A", call(shiftedState, shiftedStatic))
local shiftedB = assertOk("shifted weights B", call(shiftedState, shiftedStatic))
assert(canonical(shiftedState) == shiftedSnapshot, "shifted selection mutated input")
assert(canonical(shiftedA) == canonical(shiftedB), "same shifted input produced a different result")
local shiftedScores = candidateMap(shiftedA)
assert(shiftedA.receipt.weightOffset == 5, "all-non-positive offset changed")
assert(shiftedScores.close_collar.weight == 4 and shiftedScores.quiet_warning.weight == 2
    and shiftedScores.turn_to_corner.weight == 3 and shiftedScores.silent_glare.weight == 1,
    "parallel score shift did not preserve less-bad ordering")
assert(shiftedA.receipt.draw.totalWeight == 10 and shiftedA.receipt.draw.roll == 4,
    "shifted weighted draw receipt changed")
assert(shiftedA.intent.cardInstanceIds[1] == IDS.close_collar,
    "shifted fixed-seed mapping changed")
assert(shiftedA.state.rng.cursor == 1 and shiftedState.rng.cursor == 0,
    "shifted weighted draw RNG cursor changed incorrectly")

-- A single held card is selected without consuming RNG regardless of its score.
local singleState = fixture()
local deckPosition = 1
for _, cardInstance in ipairs(singleState.cardInstances) do
    if cardInstance.instanceId == IDS.quiet_warning then
        cardInstance.position = 1
    else
        cardInstance.zone = "deck"
        cardInstance.position = deckPosition
        deckPosition = deckPosition + 1
    end
end
local single = assertOk("single candidate", call(singleState, staticData))
assert(single.intent.cardInstanceIds[1] == IDS.quiet_warning, "single held card was not selected")
assert(single.receipt.draw.kind == "single" and single.receipt.draw.totalWeight == 2,
    "single draw receipt changed")
assert(single.state.rng.cursor == 0, "single candidate consumed RNG")

-- Empty character hand is a deterministic pass and consumes no RNG.
local passState = fixture()
for position, cardInstance in ipairs(passState.cardInstances) do
    cardInstance.zone = "deck"
    cardInstance.position = position
end
local passed = assertOk("empty hand pass", call(passState, staticData))
assert(#passed.intent.cardInstanceIds == 0 and passed.intent.publicActionTag == nil, "empty hand did not pass")
assert(passed.receipt.draw.kind == "pass" and passed.state.rng.cursor == 0, "pass consumed RNG")

-- Unsupported character-chain and score operations fail instead of being guessed.
local chainStatic = clone(staticData)
chainStatic.cards.close_collar.mechanisms = { "chain" }
assertHasError("character chain", call(fixture(), chainStatic), "unsupported_character_chain_selection")

local unsupportedStatic = clone(staticData)
unsupportedStatic.cards.close_collar.resolve = function()
    return { { op = "draw_cards", target = "character", amount = 1, cause = "test" } }
end
local failedState = fixture()
local failedSnapshot = canonical(failedState)
assertHasError("unsupported score op", call(failedState, unsupportedStatic), "unsupported_character_score_op")
assert(canonical(failedState) == failedSnapshot, "failed score evaluation mutated input")

local throwingStatic = clone(staticData)
throwingStatic.cards.close_collar.resolve = function() error("boom") end
assertHasError("protected card resolve", call(fixture(), throwingStatic), "card_resolve_error")

local moodStatic = clone(staticData)
moodStatic.cards.close_collar.moodEffects = {
    ignore = function()
        return { { op = "set_mood", target = "character", mood = "rejection", cause = "test" } }
    end,
}
assertHasError("unsupported mood score op", call(fixture(), moodStatic), "unsupported_character_score_op")

local mismatchedPlanStatic = clone(staticData)
mismatchedPlanStatic.cards.silent_glare.mechanismData.plan.selectionAssumption.event.side = "character"
assertHasError(
    "plan assumption mismatch",
    call(fixture(), mismatchedPlanStatic),
    "plan_selection_assumption_not_matched"
)

local preselected = fixture()
preselected.characterIntent = {
    cardInstanceIds = { IDS.turn_to_corner },
    publicActionTag = "evade",
}
assertHasError("reselection", call(preselected, staticData), "character_intent_already_selected")

print(
    "VECTOR"
        .. "|scores=" .. scores.close_collar.score .. "," .. scores.quiet_warning.score .. ","
            .. scores.turn_to_corner.score .. "," .. scores.silent_glare.score
        .. "|selected=" .. selected.receipt.selectedCardId
        .. "|lethal=" .. lethal.receipt.selectedCardId
        .. "|charges=" .. tostring(doublePlanScore.planChargesEvaluated)
        .. "|double=" .. doublePlan.receipt.selectedCardId
        .. "|shift=" .. shiftedA.receipt.selectedCardId
        .. "|roll=" .. tostring(selected.receipt.draw.roll)
        .. "|rng=" .. tostring(selected.state.rng.cursor)
        .. "|pass=" .. passed.receipt.draw.kind
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[character-selector-check]],[[t]],_G))()'
    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua characterSelector 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }
    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua characterSelector 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }
    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 characterSelector 결과를 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -cne 'VECTOR|scores=3,2,4,3|selected=turn_to_corner|lethal=silent_glare|charges=2|double=turn_to_corner|shift=close_collar|roll=6|rng=1|pass=pass') {
        throw "characterSelector 결정성 표식이 예상과 다릅니다: $firstText"
    }
    Write-Output 'character-selector-check: ok'
    Write-Output 'NOTE: 실제 RisuAI 로어북 및 턴 initializer 통합 환경에서는 아직 검증하지 않았습니다.'
}
finally {
    Pop-Location
}
