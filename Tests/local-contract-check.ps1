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
    staticData = loadLore("System/staticData.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
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
assert(staticLoad.counts.cards == 10)
assert(staticLoad.counts.traits == 1)
assert(staticLoad.counts.environments == 1)
assert(staticLoad.counts.characters == 1)

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
        maxHandSize = 3,
        perkIds = {},
        planSlot = { occupied = false },
    },
    character = {
        characterId = "yoo_jiyoung",
        resistance = 30,
        mood = "ignore",
        traitIds = { "reserved" },
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

assertError(
    "incomplete static data",
    runScript("test", "stateSchema", "validateBattleState", baseState, { cards = staticData.cards }),
    "invalid_static_data",
    "$"
)

local nanState = clone(baseState)
nanState.player.perkIds = { 0 / 0 }
assert(runScript("test", "stateSchema", "validateBattleState", nanState, staticData).ok == false)

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

local view = assertOk(
    "battleView",
    runScript("test", "viewBuilder", "buildBattleView", baseState, staticData)
).view
assert(view.hand.count == 3)
assert(view.hand.items[1].instanceId == "player-001")
assert(view.hand.items[2].instanceId == "player-002")
assert(view.hand.items[3].instanceId == "player-003")
assert(view.selection.canSubmit == true)
assert(view.character.mood.thresholdToCompliance == 5, "reserved must add 1 to compliance threshold")
assert(view.character.mood.thresholdToRejection == 4)
assert(view.character.publicAction.tag.id == "vigilance")
assert(view.character.plan.status == "hidden")
assert(view.character.plan.card == nil)
for _, item in ipairs(view.hand.items) do
    assert(item.finalStealthCost == item.baseStealthCost)
    assert(item.finalResistanceDamage == item.baseResistanceDamage)
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
local canaryText = "한글 CBS canary ::tag[contact]:: {{literal}} 끝:"
canaryView.environment.description = canaryText
local canaryEncoded = assertOk(
    "CBS punctuation canary encode",
    runScript("test", "dataBridge", "encode", "battleView", canaryView)
)
assert(not canaryEncoded.encoded:find("::", 1, true), "wire exposed raw CBS argument delimiter")
assert(not canaryEncoded.encoded:find("{{", 1, true), "wire exposed raw CBS opening braces")
assert(not canaryEncoded.encoded:find("}}", 1, true), "wire exposed raw CBS closing braces")
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

local afterState = clone(baseState)
afterState.character.resistance = 987654
afterState.rng.cursor = 1
afterState.lastCommittedTurnId = "battle-0001-turn-001"
local pending = {
    schemaVersion = 1,
    kind = "pendingTurn",
    battleId = "battle-0001",
    turnId = "battle-0001-turn-001",
    status = "awaitingOutput",
    beforeState = clone(baseState),
    selectedCards = {
        player = { "player-001", "player-002" },
        character = { "character-hand-001" },
    },
    turnResult = {
        events = { { type = "internal_test" } },
        publicResult = { schemaVersion = 1, events = { { type = "public_test" } } },
        llmEvent = { schemaVersion = 1, events = { { type = "llm_test" } } },
    },
    afterState = afterState,
}

assertOk("pendingTurn", runScript("test", "stateSchema", "validatePendingTurn", pending, staticData))
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

local pendingMarkerOnly = {
    status = "awaitingOutput",
    turnId = pending.turnId,
    beforeState = setmetatable({}, {
        __index = function()
            error("PENDING_PRIVATE_READ")
        end,
        __pairs = function()
            error("PENDING_PRIVATE_ITERATION")
        end,
    }),
    afterState = {
        character = { resistance = 987654 },
    },
    turnResult = "PRIVATE_PENDING_CANARY",
}
local waitingView = assertOk(
    "awaiting battleView",
    runScript("test", "viewBuilder", "buildBattleView", baseState, staticData, pendingMarkerOnly)
).view
assert(waitingView.phase == "awaitingOutput" and waitingView.locked == true)
assert(waitingView.character.resistance == 30, "afterState leaked before output")
local waitingEncoded = assertOk(
    "awaiting encode",
    runScript("test", "dataBridge", "encode", "battleView", waitingView)
).encoded
assert(not waitingEncoded:find("987654", 1, true), "afterState value leaked into waiting View")
assert(not waitingEncoded:find("PRIVATE_PENDING_CANARY", 1, true), "pending private marker leaked into View")

local revealedState = clone(baseState)
revealedState.character.planSlot.revealed = true
local revealedView = assertOk(
    "revealed plan View",
    runScript("test", "viewBuilder", "buildBattleView", revealedState, staticData)
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
    local sizedView = assertOk(
        "hand size " .. handSize,
        runScript("test", "viewBuilder", "buildBattleView", handState, staticData)
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
try {
    $firstWirePath = [IO.Path]::GetTempFileName()
    $secondWirePath = [IO.Path]::GetTempFileName()
    $env:RISU_LOCAL_CONTRACT_LUA = $luaTest
    $env:RISU_LOCAL_CONTRACT_WIRE_PATH = $firstWirePath

    $firstOutput = @(& $luaHost -e 'assert(load(os.getenv([[RISU_LOCAL_CONTRACT_LUA]]),[[local-contract-check]],[[t]],_G))()' 2>&1)
    $firstExitCode = $LASTEXITCODE
    if ($firstExitCode -ne 0) {
        $firstOutput | ForEach-Object { Write-Output $_ }
        exit $firstExitCode
    }
    $firstWireOutput = [IO.File]::ReadAllLines($firstWirePath, [Text.UTF8Encoding]::new($false))

    $env:RISU_LOCAL_CONTRACT_WIRE_PATH = $secondWirePath
    $secondOutput = @(& $luaHost -e 'assert(load(os.getenv([[RISU_LOCAL_CONTRACT_LUA]]),[[local-contract-check]],[[t]],_G))()' 2>&1)
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
    Assert-Contract ($canaryEnvironment.description -ceq '한글 CBS canary ::tag[contact]:: {{literal}} 끝:') 'CBS punctuation or Korean canary did not round-trip'

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
    Remove-Item Env:RISU_LOCAL_CONTRACT_LUA -ErrorAction SilentlyContinue
    Remove-Item Env:RISU_LOCAL_CONTRACT_WIRE_PATH -ErrorAction SilentlyContinue
    if ($firstWirePath) {
        Remove-Item -LiteralPath $firstWirePath -Force -ErrorAction SilentlyContinue
    }
    if ($secondWirePath) {
        Remove-Item -LiteralPath $secondWirePath -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
