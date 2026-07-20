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
    staticData = loadLore("System/staticData.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
    deterministicRng = loadLore("System/deterministicRng.lua"),
    cardZones = loadLore("System/cardZones.lua"),
    battleBootstrap = loadLore("System/battleBootstrap.lua"),
}

local moduleCalls = {}
local callTrace = {}
local stateSchemaStaticInputs = {}
function runScript(triggerId, name, ...)
    local arguments = { ... }
    local action = arguments[1]
    moduleCalls[name] = (moduleCalls[name] or 0) + 1
    local trace = name .. ":" .. tostring(action)
    if name == "cardZones" and action == "shuffleDeck" then
        trace = trace .. ":" .. tostring(arguments[3])
    end
    callTrace[#callTrace + 1] = trace
    if name == "stateSchema"
        and (action == "newBattleState" or action == "validateBattleState") then
        stateSchemaStaticInputs[#stateSchemaStaticInputs + 1] = arguments[3]
    end
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

local hostWrites = 0
local function rejectHostWrite(name)
    return function()
        hostWrites = hostWrites + 1
        error("unexpected host write: " .. name)
    end
end
setState = rejectHostWrite("setState")
setChatVar = rejectHostWrite("setChatVar")
setFullChat = rejectHostWrite("setFullChat")
addChat = rejectHostWrite("addChat")
upsertLocalLoreBook = rejectHostWrite("upsertLocalLoreBook")

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
    if valueType == "function" then return "<function:" .. tostring(value) .. ">" end
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

local function assertError(label, report, code, path)
    assert(type(report) == "table" and report.ok == false, label .. " unexpectedly succeeded")
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(report.state == nil, label .. " exposed a state on failure")
    for _, item in ipairs(report.errors or {}) do
        if item.code == code and (path == nil or item.path == path) then
            return item
        end
    end
    failReport(label .. " missing " .. code, report)
end

local function deckOrder(state, owner)
    local entries = {}
    for _, instance in ipairs(state.cardInstances) do
        if instance.owner == owner and instance.zone == "deck" then
            entries[#entries + 1] = instance
        end
    end
    table.sort(entries, function(left, right)
        return left.position < right.position
    end)
    local ids = {}
    for index, instance in ipairs(entries) do
        assert(instance.position == index, owner .. " deck positions are not contiguous")
        ids[index] = instance.instanceId
    end
    return ids
end

local staticData = assertOk(
    "static data",
    runScript("battle-bootstrap-from-setup-check", "staticData", "loadAll")
).data
moduleCalls = {}
callTrace = {}
stateSchemaStaticInputs = {}

local playerCardIds = {
    "subtle_approach",
    "subtle_approach",
    "accidental_brush",
    "accidental_brush",
    "play_it_cool",
    "play_it_cool",
    "read_the_room",
    "read_the_room",
    "pin_down",
    "pin_down",
}
local spec = {
    battleId = "setup-battle",
    seed = 20260721,
    playerCardIds = clone(playerCardIds),
    characterId = "yoo_jiyoung",
    environmentId = "uncrowded",
    turnLimit = 17,
}
local specSnapshot = canonical(spec)
local staticSnapshot = canonical(staticData)

local first = assertOk(
    "from setup",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", spec, staticData)
)
assert(first.referencesValidated == true, "fromSetup did not require static reference validation")
assert(first.initialDecksShuffled == true, "fromSetup did not report both initial shuffles")
assert(canonical(spec) == specSnapshot, "fromSetup mutated its explicit spec")
assert(canonical(staticData) == staticSnapshot, "fromSetup mutated static data")
assert(hostWrites == 0, "fromSetup wrote host state")

local expectedTrace = {
    "battleBootstrap:fromSetup",
    "stateSchema:newBattleState",
    "cardZones:shuffleDeck:player",
    "deterministicRng:shuffle",
    "cardZones:shuffleDeck:character",
    "deterministicRng:shuffle",
    "stateSchema:validateBattleState",
}
assert(canonical(callTrace) == canonical(expectedTrace),
    "fromSetup call order changed: " .. canonical(callTrace))
assert(moduleCalls.stateSchema == 2, "fromSetup must construct and finally validate through stateSchema")
assert(moduleCalls.cardZones == 2, "fromSetup must shuffle exactly two decks")
assert(moduleCalls.deterministicRng == 2, "fromSetup must perform exactly two deterministic shuffles")
assert(#stateSchemaStaticInputs == 2
    and stateSchemaStaticInputs[1] == staticData
    and stateSchemaStaticInputs[2] == staticData,
    "fromSetup did not use full staticData at both stateSchema boundaries")

local state = first.state
assert(state.schemaVersion == 1 and state.kind == "battleState", "battleState identity changed")
assert(state.battleId == spec.battleId and state.status == "active", "battle identity/status changed")
assert(state.turnNumber == 1 and state.turnLimit == spec.turnLimit, "explicit turn limit was not preserved")
assert(state.environmentId == spec.environmentId, "explicit environment was not preserved")
assert(state.rng.seed == spec.seed and state.rng.cursor == 12,
    "player then character shuffle must consume 9 + 3 RNG samples")
assert(state.character.characterId == spec.characterId, "explicit character was not preserved")

assert(#state.cardInstances == 14, "fromSetup must create ten player and four character cards")
for index = 1, 10 do
    local instance = state.cardInstances[index]
    assert(instance.instanceId == string.format("player-%03d", index), "player instance ID changed")
    assert(instance.cardId == playerCardIds[index], "player instance no longer follows setup deck input")
    assert(instance.owner == "player" and instance.zone == "deck", "invalid player instance owner/zone")
end
local characterSourceDeck = staticData.characters.yoo_jiyoung.battle.deck
for index = 1, #characterSourceDeck do
    local instance = state.cardInstances[10 + index]
    assert(instance.instanceId == string.format("character-%03d", index), "character instance ID changed")
    assert(instance.cardId == characterSourceDeck[index], "character instance no longer follows character DB deck")
    assert(instance.owner == "character" and instance.zone == "deck", "invalid character instance owner/zone")
end

local expectedPlayerOrder = {
    "player-003", "player-007", "player-009", "player-010", "player-002",
    "player-006", "player-004", "player-005", "player-008", "player-001",
}
local expectedCharacterOrder = {
    "character-003", "character-001", "character-002", "character-004",
}
assert(canonical(deckOrder(state, "player")) == canonical(expectedPlayerOrder),
    "player deterministic shuffle vector changed: " .. canonical(deckOrder(state, "player")))
assert(canonical(deckOrder(state, "character")) == canonical(expectedCharacterOrder),
    "character deterministic shuffle vector changed: " .. canonical(deckOrder(state, "character")))

local stateSignature = canonical(state)
local second = assertOk(
    "repeat from setup",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", spec, staticData)
)
assert(canonical(second.state) == stateSignature, "same-process fromSetup result is not deterministic")

state.player.stealth = -999
state.character.traitIds[1] = "mutated"
state.cardInstances[1].position = 999
assert(second.state.player.stealth == 30, "fromSetup results alias each other")
assert(second.state.character.traitIds[1] == staticData.characters.yoo_jiyoung.battle.traitIds[1],
    "fromSetup result traits alias another result or staticData")
assert(second.state.cardInstances[1].position ~= 999, "fromSetup result card instances alias each other")
assert(canonical(staticData) == staticSnapshot, "returned state aliases staticData")
assert(canonical(spec) == specSnapshot, "returned state aliases the input spec")

local validation = assertOk(
    "independent final validation",
    runScript("battle-bootstrap-from-setup-check", "stateSchema", "validateBattleState", second.state, staticData)
)
assert(validation.referencesValidated == true, "final state did not pass full static reference validation")

local generalizedStatic = clone(staticData)
generalizedStatic.characters.yoo_jiyoung.battle.deck = {
    "silent_glare",
    "close_collar",
    "quiet_warning",
}
local generalizedSnapshot = canonical(generalizedStatic)
local generalizedSpec = clone(spec)
generalizedSpec.battleId = "setup-generalized-character-deck"
generalizedSpec.seed = 99
local generalized = assertOk(
    "DB-driven character deck",
    runScript(
        "battle-bootstrap-from-setup-check",
        "battleBootstrap",
        "fromSetup",
        generalizedSpec,
        generalizedStatic
    )
)
assert(#generalized.state.cardInstances == 13, "character DB deck length was not generalized")
assert(generalized.state.cardInstances[11].cardId == "silent_glare"
    and generalized.state.cardInstances[12].cardId == "close_collar"
    and generalized.state.cardInstances[13].cardId == "quiet_warning",
    "character instances did not preserve DB deck source order")
assert(generalized.state.rng.cursor == 11, "three-card character deck should consume 9 + 2 RNG samples")
assert(canonical(generalizedStatic) == generalizedSnapshot, "generalized character DB was mutated")

local nineCards = clone(playerCardIds)
nineCards[10] = nil
local nineSpec = clone(spec)
nineSpec.playerCardIds = nineCards
assertError(
    "nine-card player deck",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", nineSpec, staticData),
    "invalid_player_deck",
    "$.playerCardIds"
)

local elevenSpec = clone(spec)
elevenSpec.playerCardIds[11] = "hypnotic_whisper"
assertError(
    "eleven-card player deck",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", elevenSpec, staticData),
    "invalid_player_deck",
    "$.playerCardIds"
)

local threeCopiesSpec = clone(spec)
threeCopiesSpec.playerCardIds[3] = "subtle_approach"
assertError(
    "third player-card copy",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", threeCopiesSpec, staticData),
    "player_card_copy_limit_exceeded",
    "$.playerCardIds[3]"
)

local ownerMismatchSpec = clone(spec)
ownerMismatchSpec.playerCardIds[10] = "close_collar"
assertError(
    "character card in player deck",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", ownerMismatchSpec, staticData),
    "player_card_owner_mismatch",
    "$.playerCardIds[10]"
)

local unknownPlayerSpec = clone(spec)
unknownPlayerSpec.playerCardIds[10] = "missing_player_card"
assertError(
    "unknown player card",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", unknownPlayerSpec, staticData),
    "unknown_player_card",
    "$.playerCardIds[10]"
)

local unknownCharacterSpec = clone(spec)
unknownCharacterSpec.characterId = "missing_character"
assertError(
    "unknown character",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", unknownCharacterSpec, staticData),
    "missing_character_definition",
    "$.staticData.characters.missing_character"
)

local invalidCharacterDeckStatic = clone(staticData)
invalidCharacterDeckStatic.characters.yoo_jiyoung.battle.deck[2] = "missing_character_card"
assertError(
    "unknown character deck card",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", spec, invalidCharacterDeckStatic),
    "unknown_character_card",
    "$.staticData.characters.yoo_jiyoung.battle.deck[2]"
)

local unknownEnvironmentSpec = clone(spec)
unknownEnvironmentSpec.environmentId = "missing_environment"
assertError(
    "unknown environment",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", unknownEnvironmentSpec, staticData),
    "unknown_environment",
    "$.environmentId"
)

local invalidTurnLimitSpec = clone(spec)
invalidTurnLimitSpec.turnLimit = 0
assertError(
    "invalid turn limit",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", invalidTurnLimitSpec, staticData),
    "invalid_turn_limit",
    "$.turnLimit"
)

local unknownFieldSpec = clone(spec)
unknownFieldSpec.setupSeed = 7
assertError(
    "unknown setup field",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "fromSetup", unknownFieldSpec, staticData),
    "unknown_spec_field",
    "$.setupSeed"
)

assertError(
    "unknown action",
    runScript("battle-bootstrap-from-setup-check", "battleBootstrap", "notAnAction", spec, staticData),
    "unknown_action",
    "$.action"
)
assert(hostWrites == 0, "failure paths wrote host state")
assert(canonical(spec) == specSnapshot and canonical(staticData) == staticSnapshot,
    "failure checks mutated reusable inputs")

print(
    "BATTLE_BOOTSTRAP_FROM_SETUP|hash=" .. stableHash(canonical(second.state))
        .. "|player=" .. table.concat(deckOrder(second.state, "player"), ",")
        .. "|character=" .. table.concat(deckOrder(second.state, "character"), ",")
        .. "|cursor=" .. second.state.rng.cursor
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[battle-bootstrap-from-setup-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua fromSetup bootstrap check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua fromSetup bootstrap check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different fromSetup bootstrap results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }

    $expectedVector = 'BATTLE_BOOTSTRAP_FROM_SETUP|hash=1726705382|player=player-003,player-007,player-009,player-010,player-002,player-006,player-004,player-005,player-008,player-001|character=character-003,character-001,character-002,character-004|cursor=12'
    if ($firstText -cne $expectedVector) {
        throw "Unexpected fromSetup bootstrap determinism vector: $firstText"
    }

    Write-Output 'battle-bootstrap-from-setup-check: ok'
    Write-Output 'NOTE: setup persistence, first-turn initialization, RisuAI hooks, and UI remain outside this pure bootstrap check.'
}
finally {
    Pop-Location
}
