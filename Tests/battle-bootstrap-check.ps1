$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
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
    battleBootstrap = loadLore("System/battleBootstrap.lua"),
}

local moduleCalls = {}
function runScript(triggerId, name, ...)
    moduleCalls[name] = (moduleCalls[name] or 0) + 1
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
    for _, item in ipairs(report.errors or {}) do
        if item.code == code and (path == nil or item.path == path) then
            return item
        end
    end
    failReport(label .. " missing " .. code, report)
end

local staticData = assertOk(
    "static data",
    runScript("battle-bootstrap-check", "staticData", "loadAll")
).data

local expectedCards = {
    { "player-001", "subtle_approach", "player", 1 },
    { "player-002", "accidental_brush", "player", 2 },
    { "player-003", "play_it_cool", "player", 3 },
    { "player-004", "read_the_room", "player", 4 },
    { "player-005", "pin_down", "player", 5 },
    { "player-006", "hypnotic_whisper", "player", 6 },
    { "character-001", "close_collar", "character", 1 },
    { "character-002", "quiet_warning", "character", 2 },
    { "character-003", "turn_to_corner", "character", 3 },
    { "character-004", "silent_glare", "character", 4 },
}

local spec = {
    battleId = "bootstrap-battle",
    seed = 20260719,
}
local specSnapshot = canonical(spec)
local staticDeckSnapshot = canonical(staticData.characters.yoo_jiyoung.battle.deck)
local staticTraitSnapshot = canonical(staticData.characters.yoo_jiyoung.battle.traitIds)

local first = assertOk(
    "vertical slice",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", spec, staticData)
)
assert(first.referencesValidated == true, "bootstrap did not require static reference validation")
assert(canonical(spec) == specSnapshot, "bootstrap mutated its explicit spec")
assert(canonical(staticData.characters.yoo_jiyoung.battle.deck) == staticDeckSnapshot,
    "bootstrap mutated the static character deck")
assert(canonical(staticData.characters.yoo_jiyoung.battle.traitIds) == staticTraitSnapshot,
    "bootstrap mutated static character traits")
assert(hostWrites == 0, "bootstrap wrote host state")
assert(moduleCalls.stateSchema == 1, "bootstrap must call stateSchema.newBattleState exactly once")
assert(moduleCalls.cardZones == nil and moduleCalls.deterministicRng == nil,
    "bootstrap unexpectedly shuffled or consumed RNG")

local state = first.state
assert(state.schemaVersion == 1 and state.kind == "battleState", "battleState identity changed")
assert(state.battleId == spec.battleId and state.status == "active", "battle identity/status changed")
assert(state.turnNumber == 1 and state.turnLimit == 10, "vertical slice turn bounds changed")
assert(state.environmentId == "uncrowded", "vertical slice environment changed")
assert(state.lastCommittedTurnId == nil and state.turnStartReceipt == nil,
    "bootstrap returned post-initializer or committed state")
assert(state.rng.seed == spec.seed and state.rng.cursor == 0,
    "bootstrap consumed or changed deterministic RNG")

assert(state.player.stealth == 30, "player starting stealth changed")
assert(state.player.baseDrawCount == 3 and state.player.maxHandSize == 5,
    "player draw settings changed")
assert(#state.player.perkIds == 0 and state.player.planSlot.occupied == false,
    "player starting perks/plan changed")

local characterBattle = staticData.characters.yoo_jiyoung.battle
assert(state.character.characterId == "yoo_jiyoung", "vertical slice character changed")
assert(state.character.resistance == characterBattle.startingResistance, "character resistance not derived from static data")
assert(state.character.mood == characterBattle.startingMood, "character mood not derived from static data")
assert(state.character.baseDrawCount == characterBattle.baseDrawCount
    and state.character.maxHandSize == characterBattle.maxHandSize,
    "character draw settings not derived from static data")
assert(canonical(state.character.traitIds) == canonical(characterBattle.traitIds),
    "character traits not derived from static data")
assert(state.character.planSlot.occupied == false, "character started with an occupied plan")

assert(#state.cardInstances == #expectedCards, "vertical slice card count changed")
for index, expected in ipairs(expectedCards) do
    local instance = state.cardInstances[index]
    assert(instance.instanceId == expected[1], "stable instance ID changed at " .. index)
    assert(instance.cardId == expected[2], "card ID changed at " .. index)
    assert(instance.owner == expected[3], "card owner changed at " .. index)
    assert(instance.zone == "deck", "bootstrap must leave every card in deck")
    assert(instance.position == expected[4], "deck position changed at " .. index)
    assert(instance.temporaryModifiers == nil, "bootstrap added unsupported temporary modifiers")
end
assert(#state.selection.playerCardInstanceIds == 0, "bootstrap preselected player cards")
assert(#state.characterIntent.cardInstanceIds == 0 and state.characterIntent.publicActionTag == nil,
    "bootstrap preselected character intent")

local validated = assertOk(
    "state schema validation",
    runScript("battle-bootstrap-check", "stateSchema", "validateBattleState", state, staticData)
)
assert(validated.referencesValidated == true, "constructed state references were not validated")

local second = assertOk(
    "repeat vertical slice",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", spec, staticData)
)
assert(canonical(second.state) == canonical(state), "same explicit spec produced different state")
state.player.stealth = -999
state.character.traitIds[1] = "mutated"
assert(second.state.player.stealth == 30, "bootstrap results alias each other")
assert(canonical(staticData.characters.yoo_jiyoung.battle.traitIds) == staticTraitSnapshot,
    "bootstrap result aliases static data")

local zeroSeed = assertOk(
    "zero seed",
    runScript(
        "battle-bootstrap-check",
        "battleBootstrap",
        "verticalSlice",
        { battleId = "bootstrap-zero", seed = 0 },
        staticData
    )
)
assert(zeroSeed.state.rng.seed == 0 and zeroSeed.state.rng.cursor == 0, "seed zero was not preserved")
for index, expected in ipairs(expectedCards) do
    assert(zeroSeed.state.cardInstances[index].instanceId == expected[1],
        "instance IDs depend on RNG seed")
end

assertError(
    "missing spec",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", nil, staticData),
    "invalid_spec",
    "$"
)
assertError(
    "missing battle id",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", { seed = 1 }, staticData),
    "invalid_battle_id",
    "$.battleId"
)
assertError(
    "missing seed",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", { battleId = "missing-seed" }, staticData),
    "invalid_rng_seed",
    "$.seed"
)
assertError(
    "fractional seed",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", { battleId = "bad-seed", seed = 1.5 }, staticData),
    "invalid_rng_seed",
    "$.seed"
)
assertError(
    "unknown spec field",
    runScript(
        "battle-bootstrap-check",
        "battleBootstrap",
        "verticalSlice",
        { battleId = "unknown-field", seed = 1, turnLimit = 99 },
        staticData
    ),
    "unknown_spec_field",
    "$.turnLimit"
)

local incompleteStatic = clone(staticData)
incompleteStatic.registry = nil
assertError(
    "incomplete static data",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", spec, incompleteStatic),
    "invalid_static_data",
    "$"
)

local missingCardStatic = clone(staticData)
missingCardStatic.cards.subtle_approach = nil
assertError(
    "missing fixed card",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", spec, missingCardStatic),
    "unknown_card",
    "$.cardInstances[1].cardId"
)

local changedDeckStatic = clone(staticData)
changedDeckStatic.characters.yoo_jiyoung.battle.deck[1] = "quiet_warning"
assertError(
    "changed character deck",
    runScript("battle-bootstrap-check", "battleBootstrap", "verticalSlice", spec, changedDeckStatic),
    "vertical_slice_character_deck_mismatch",
    "$.staticData.characters.yoo_jiyoung.battle.deck[1]"
)

assertError(
    "unknown action",
    runScript("battle-bootstrap-check", "battleBootstrap", "notAnAction", spec, staticData),
    "unknown_action",
    "$.action"
)
assert(hostWrites == 0, "failure paths wrote host state")

local signature = canonical(second.state)
print("BATTLE_BOOTSTRAP|hash=" .. stableHash(signature) .. "|cards=" .. #second.state.cardInstances .. "|cursor=" .. second.state.rng.cursor)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[battle-bootstrap-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua battle bootstrap check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua battle bootstrap check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different battle bootstrap results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -cne 'BATTLE_BOOTSTRAP|hash=1068093683|cards=10|cursor=0') {
        throw "Unexpected battle bootstrap determinism vector: $firstText"
    }

    Write-Output 'battle-bootstrap-check: ok'
    Write-Output 'NOTE: initial draw/turn receipt, persistent storage, RisuAI hooks, and UI remain outside this pure bootstrap check.'
}
finally {
    Pop-Location
}
