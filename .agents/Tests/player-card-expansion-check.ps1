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

$playerCardsSource = Get-Content (Join-Path $projectRoot 'DB/PlayerCards.db') -Raw -Encoding UTF8
$expectedNames = @{
    persistent_press = '대담한 밀착'
    dangerous_whisper = '위험한 속삭임'
    cut_off_escape = '퇴로 봉쇄'
    cross_the_line = '선을 넘다'
}
foreach ($entry in $expectedNames.GetEnumerator()) {
    $pattern = '(?s)' + [regex]::Escape($entry.Key) + '\s*=\s*\{.{0,320}?name\s*=\s*"' + [regex]::Escape($entry.Value) + '"'
    if ($playerCardsSource -notmatch $pattern) {
        throw "Expanded player-card name mapping changed: $($entry.Key) / $($entry.Value)"
    }
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
    turnDraft = loadLore("System/turnDraft.lua"),
    turnInitializer = loadLore("System/turnInitializer.lua"),
    turnResolver = loadLore("System/turnResolver.lua"),
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
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
}

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
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
    if valueType == "nil" then return "null" end
    if valueType == "boolean" or valueType == "number" then return tostring(value) end
    if valueType == "string" then return string.format("%q", value) end
    assert(valueType == "table", "unsupported canonical type: " .. valueType)

    active = active or {}
    assert(not active[value], "cycle in canonical value")
    active[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        return type(left) .. ":" .. tostring(left) < type(right) .. ":" .. tostring(right)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = canonical(key, active) .. "=" .. canonical(value[key], active)
    end
    active[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function failReport(label, report)
    local messages = {}
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        messages[#messages + 1] = tostring(item.code)
            .. " at " .. tostring(item.path)
            .. ": " .. tostring(item.message)
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

local staticReport = assertOk(
    "load expanded static data",
    runScript("player-card-expansion-check", "staticData", "loadAll")
)
local staticData = staticReport.data

local expectedDefinitions = {
    persistent_press = {
        actionTag = "contact",
        mechanisms = {},
        cost = 2,
        damage = 5,
    },
    dangerous_whisper = {
        actionTag = "threat",
        mechanisms = {},
        cost = 1,
        damage = 4,
    },
    cut_off_escape = {
        actionTag = "approach",
        mechanisms = { "plan" },
        cost = 1,
        damage = 0,
    },
    cross_the_line = {
        actionTag = "violation",
        mechanisms = { "remove" },
        cost = 8,
        damage = 10,
    },
}

local playerCardCount = 0
for _, card in pairs(staticData.cards) do
    if card.owner == "player" then
        playerCardCount = playerCardCount + 1
    end
end
assert(playerCardCount == 10, "expanded player card pool must contain ten definitions")
assert(staticReport.counts.cards == 14, "combined static card count must be fourteen")

for cardId, expected in pairs(expectedDefinitions) do
    local card = assert(staticData.cards[cardId], "missing expanded card: " .. cardId)
    assert(card.id == cardId and card.owner == "player", cardId .. " identity changed")
    assert(type(card.name) == "string" and card.name ~= "", cardId .. " name is missing")
    assert(card.actionTag == expected.actionTag, cardId .. " action tag changed")
    assert(card.base.stealthCost == expected.cost, cardId .. " stealth cost changed")
    assert(card.base.resistanceDamage == expected.damage, cardId .. " base damage changed")
    assert(canonical(card.mechanisms) == canonical(expected.mechanisms), cardId .. " mechanisms changed")
end

local function evaluate(label, action, ...)
    return assertOk(
        label,
        runScript("player-card-expansion-check", "effectEngine", action, staticData, ...)
    )
end

-- Plain cards have no hidden resolve callback. Dangerous Whisper's conditional
-- damage is a mood effect and therefore composes with its base damage.
local neutralContext = {
    mood = "ignore",
    player = { stealth = 30 },
    character = { resistance = 30 },
}
assert(#evaluate("persistent press resolve", "evaluateCardResolve", "persistent_press", neutralContext).commands == 0)
assert(#evaluate("dangerous whisper resolve", "evaluateCardResolve", "dangerous_whisper", neutralContext).commands == 0)
local dangerousNeutral = evaluate(
    "dangerous whisper neutral mood",
    "evaluateMoodEffect",
    "dangerous_whisper",
    "ignore",
    neutralContext
)
assert(#dangerousNeutral.commands == 0, "dangerous whisper gained bonus outside confusion")
local dangerousConfusion = evaluate(
    "dangerous whisper confusion mood",
    "evaluateMoodEffect",
    "dangerous_whisper",
    "confusion",
    { mood = "confusion", player = { stealth = 30 }, character = { resistance = 30 } }
)
assert(#dangerousConfusion.commands == 1, "dangerous whisper confusion bonus command count changed")
assert(dangerousConfusion.commands[1].op == "damage_resistance"
    and dangerousConfusion.commands[1].target == "character"
    and dangerousConfusion.commands[1].amount == 4,
    "dangerous whisper confusion bonus changed")

local escapePlan = staticData.cards.cut_off_escape.mechanismData.plan
assert(escapePlan.durationTurns == 1 and escapePlan.charges == 1,
    "cut off escape lifetime changed")
assert(escapePlan.durationIncludesPlacementTurn == true,
    "cut off escape must count its placement turn toward duration")
local escapeMiss = evaluate(
    "cut off escape misses player resolution",
    "evaluateTrigger",
    escapePlan,
    neutralContext,
    { type = "card_resolved", side = "player" }
)
assert(escapeMiss.matched == false and #escapeMiss.commands == 0,
    "cut off escape triggered for the player side")
local escapeHit = evaluate(
    "cut off escape matches character resolution",
    "evaluateTrigger",
    escapePlan,
    neutralContext,
    { type = "card_resolved", side = "character" }
)
assert(escapeHit.matched == true and #escapeHit.commands == 1,
    "cut off escape did not match character card_resolved")
assert(escapeHit.commands[1].op == "damage_resistance"
    and escapeHit.commands[1].target == "character"
    and escapeHit.commands[1].amount == 5,
    "cut off escape plan damage changed")

local complianceLine = evaluate(
    "cross the line compliance resolve",
    "evaluateCardResolve",
    "cross_the_line",
    { mood = "compliance", player = { stealth = 30 }, character = { resistance = 30 } }
)
assert(#complianceLine.commands == 0, "cross the line compliance gained a non-mood resolve effect")
local complianceLineMood = evaluate(
    "cross the line compliance mood effect",
    "evaluateMoodEffect",
    "cross_the_line",
    "compliance",
    { mood = "compliance", player = { stealth = 30 }, character = { resistance = 30 } }
)
assert(#complianceLineMood.commands == 1, "cross the line compliance bonus command count changed")
assert(complianceLineMood.commands[1].op == "damage_resistance"
    and complianceLineMood.commands[1].amount == 5,
    "cross the line compliance bonus changed")

for _, mood in ipairs({ "rejection", "suspicion", "ignore", "confusion" }) do
    local noncomplianceLine = evaluate(
        "cross the line noncompliance " .. mood,
        "evaluateCardResolve",
        "cross_the_line",
        { mood = mood, player = { stealth = 30 }, character = { resistance = 30 } }
    )
    assert(#noncomplianceLine.commands == 1,
        "cross the line noncompliance command count changed for " .. mood)
    assert(noncomplianceLine.commands[1].op == "set_mood"
        and noncomplianceLine.commands[1].target == "character"
        and noncomplianceLine.commands[1].mood == "rejection",
        "cross the line must set rejection before its mood effect")
end
local rejectionLineMood = evaluate(
    "cross the line rejection lock mood effect",
    "evaluateMoodEffect",
    "cross_the_line",
    "rejection",
    { mood = "rejection", player = { stealth = 30 }, character = { resistance = 30 } }
)
assert(#rejectionLineMood.commands == 1
    and rejectionLineMood.commands[1].op == "lock_mood"
    and rejectionLineMood.commands[1].target == "character"
    and rejectionLineMood.commands[1].mood == "rejection"
    and rejectionLineMood.commands[1]["until"] == "turn_end",
    "cross the line turn-end rejection lock changed")

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

local function initialState(cardId, mood, suffix, characterPass)
    local cards = {
        makeCard("player-" .. suffix, cardId, "player", "deck", 1),
    }
    if characterPass ~= true then
        cards[#cards + 1] = makeCard(
            "character-" .. suffix,
            "quiet_warning",
            "character",
            "deck",
            1
        )
    end
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "expanded-card-" .. suffix,
        status = "active",
        turnNumber = 1,
        turnLimit = 10,
        environmentId = "uncrowded",
        rng = { seed = 20260721, cursor = 0 },
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
            mood = mood,
            traitIds = { "reserved" },
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = { occupied = false },
        },
        cardInstances = cards,
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local function resolveScenario(cardId, mood, suffix, characterPass)
    local before = initialState(cardId, mood, suffix, characterPass)
    local beforeSnapshot = canonical(before)
    assertOk(
        suffix .. " initial state",
        runScript("player-card-expansion-check", "stateSchema", "validateBattleState", before, staticData)
    )

    local turnId = before.battleId .. "-turn-001"
    local initialized = assertOk(
        suffix .. " initialize",
        runScript(
            "player-card-expansion-check",
            "turnInitializer",
            "prepareTurn",
            before,
            staticData,
            { turnId = turnId }
        )
    )
    assert(canonical(before) == beforeSnapshot, suffix .. " initializer mutated authority")
    assert(#initialized.draws.player.drawnInstanceIds == 1
        and initialized.draws.player.drawnInstanceIds[1] == "player-" .. suffix,
        suffix .. " initializer did not draw the expanded card")
    if characterPass == true then
        assert(#initialized.draws.character.drawnInstanceIds == 0,
            suffix .. " character pass unexpectedly drew a card")
        assert(#initialized.state.characterIntent.cardInstanceIds == 0,
            suffix .. " character pass unexpectedly selected a card")
    else
        assert(#initialized.draws.character.drawnInstanceIds == 1
            and initialized.draws.character.drawnInstanceIds[1] == "character-" .. suffix,
            suffix .. " initializer did not draw the character response")
        assert(#initialized.state.characterIntent.cardInstanceIds == 1
            and initialized.state.characterIntent.cardInstanceIds[1] == "character-" .. suffix,
            suffix .. " initializer did not select the only character card")
    end

    local registered = assertOk(
        suffix .. " register",
        runScript(
            "player-card-expansion-check",
            "turnDraft",
            "registerCard",
            initialized.state,
            staticData,
            initialized.draft,
            "player-" .. suffix
        )
    )
    local projected = assertOk(
        suffix .. " project",
        runScript(
            "player-card-expansion-check",
            "turnDraft",
            "project",
            initialized.state,
            staticData,
            registered.draft
        )
    )
    local resolved = assertOk(
        suffix .. " resolve",
        runScript(
            "player-card-expansion-check",
            "turnResolver",
            "resolveTurn",
            initialized.state,
            staticData,
            projected.projection,
            { turnId = turnId }
        )
    ).resolution
    assert(resolved.afterState.status == "active", suffix .. " unexpectedly ended battle")
    assert(resolved.afterState.turnNumber == 2, suffix .. " did not complete the turn")
    assert(resolved.afterState.lastCommittedTurnId == turnId, suffix .. " lost commit identity")
    assertOk(
        suffix .. " resolved state",
        runScript(
            "player-card-expansion-check",
            "stateSchema",
            "validateBattleState",
            resolved.afterState,
            staticData
        )
    )
    return resolved
end

local persistent = resolveScenario("persistent_press", "ignore", "persistent")
assert(persistent.metrics.resistancePerformance == 5
    and persistent.afterState.character.resistance == 25,
    "persistent press did not deal five total resistance damage")
assert(findCard(persistent.afterState, "player-persistent").zone == "discard",
    "persistent press did not finish in discard")

local dangerousPlain = resolveScenario("dangerous_whisper", "ignore", "dangerous-plain")
assert(dangerousPlain.metrics.resistancePerformance == 4
    and dangerousPlain.afterState.character.resistance == 26,
    "dangerous whisper gained bonus outside confusion")
local dangerousBoosted = resolveScenario("dangerous_whisper", "confusion", "dangerous-boosted")
assert(dangerousBoosted.metrics.resistancePerformance == 8
    and dangerousBoosted.afterState.character.resistance == 22,
    "dangerous whisper did not combine base and confusion damage")

local escape = resolveScenario("cut_off_escape", "ignore", "escape")
assert(escape.metrics.resistancePerformance == 5
    and escape.afterState.character.resistance == 25,
    "cut off escape did not damage after the character card resolved")
assert(escape.afterState.player.planSlot.occupied == false,
    "cut off escape remained in the plan slot after spending its charge")
assert(findCard(escape.afterState, "player-escape").zone == "discard",
    "spent cut off escape did not move to discard")
local escapeTriggerCount = 0
for _, event in ipairs(escape.events) do
    if event.type == "trigger_resolved"
        and event.source.kind == "plan"
        and event.source.id == "cut_off_escape" then
        escapeTriggerCount = escapeTriggerCount + 1
        assert(event.phase == "character_card", "cut off escape triggered outside character resolution")
        assert(event.payload.inputEventType == "card_resolved",
            "cut off escape trigger input changed")
    end
end
assert(escapeTriggerCount == 1, "cut off escape must trigger exactly once")

-- This plan counts its placement turn. If the character passes, no trigger
-- spends its charge, but the duration reaches zero during the same cleanup.
local escapeAfterPass = resolveScenario("cut_off_escape", "ignore", "escape-pass", true)
assert(escapeAfterPass.metrics.resistancePerformance == 0,
    "cut off escape dealt damage without a character card_resolved event")
assert(escapeAfterPass.afterState.player.planSlot.occupied == false,
    "placement-turn pass did not expire cut off escape")
assert(findCard(escapeAfterPass.afterState, "player-escape-pass").zone == "discard",
    "expired cut off escape did not move to discard")

local lineCompliance = resolveScenario("cross_the_line", "compliance", "line-compliance")
assert(lineCompliance.metrics.resistancePerformance == 15
    and lineCompliance.afterState.character.resistance == 15,
    "cross the line compliance total must be fifteen")
assert(lineCompliance.afterState.character.mood == "compliance",
    "cross the line changed compliance mood")
assert(findCard(lineCompliance.afterState, "player-line-compliance").zone == "removed",
    "cross the line was not removed after compliance play")

local lineRejection = resolveScenario("cross_the_line", "ignore", "line-rejection")
assert(lineRejection.metrics.resistancePerformance == 10
    and lineRejection.afterState.character.resistance == 20,
    "cross the line noncompliance total must be ten")
assert(lineRejection.afterState.character.mood == "rejection",
    "cross the line did not leave noncompliance mood at rejection")
assert(findCard(lineRejection.afterState, "player-line-rejection").zone == "removed",
    "cross the line was not removed after noncompliance play")
local moodEvaluation
for _, event in ipairs(lineRejection.events) do
    if event.type == "mood_evaluated" then moodEvaluation = event end
end
assert(type(moodEvaluation) == "table"
    and moodEvaluation.payload.reasonCode == "mood_locked"
    and moodEvaluation.payload.before == "rejection"
    and moodEvaluation.payload.after == "rejection",
    "cross the line did not hold rejection through turn-end mood evaluation")

print(
    "VECTOR"
        .. "|players=" .. tostring(playerCardCount)
        .. "|persistent=" .. tostring(persistent.metrics.resistancePerformance)
        .. "|dangerous=" .. tostring(dangerousPlain.metrics.resistancePerformance)
            .. "/" .. tostring(dangerousBoosted.metrics.resistancePerformance)
        .. "|escape=" .. tostring(escape.metrics.resistancePerformance)
        .. "/" .. findCard(escapeAfterPass.afterState, "player-escape-pass").zone
        .. "|line=" .. tostring(lineCompliance.metrics.resistancePerformance)
            .. "/" .. tostring(lineRejection.metrics.resistancePerformance)
        .. "|mood=" .. lineRejection.afterState.character.mood
        .. "|zone=" .. findCard(lineRejection.afterState, "player-line-rejection").zone
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[player-card-expansion-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first expanded player-card check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second expanded player-card check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different expanded player-card results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    $expected = 'VECTOR|players=10|persistent=5|dangerous=4/8|escape=5/discard|line=15/10|mood=rejection|zone=removed'
    if (-not ($firstText -ceq $expected)) {
        throw "Unexpected expanded player-card vector: $firstText"
    }

    Write-Output 'player-card-expansion-check: ok'
    Write-Output 'NOTE: Actual RisuAI lorebook registration and UI rendering remain untested.'
}
finally {
    Pop-Location
}
