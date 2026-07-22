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
if (-not $luaHost) { throw 'A Lua host is required. This check does not replace RisuAI integration testing.' }

$controllerSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'System\gameSetupController.lua')
$dynamicSeedPrefix = [string]::Concat('{', '{', 'randint::')
if ($controllerSource.Contains($dynamicSeedPrefix)) {
    throw 'gameSetupController contains a host-preparsed dynamic CBS seed literal'
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
    gameSetup = loadLore("System/gameSetup.lua"),
    staticData = loadLore("System/staticData.lua"),
}

local rngCalls = 0
function runScript(triggerId, name, ...)
    if name == "deterministicRng" then rngCalls = rngCalls + 1 end
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
function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end

local function canonical(value, active)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    assert(kind == "table", "unsupported canonical type: " .. kind)
    active = active or {}
    assert(not active[value], "cycle in canonical fixture")
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

local function copyArray(array)
    local copy = {}
    for index, item in ipairs(array) do copy[index] = item end
    return copy
end

local function contains(array, target)
    for _, item in ipairs(array) do
        if item == target then return true end
    end
    return false
end

local function buildToken(setupId, round, rng, selectedCardIds, offerCardIds)
    local parts = {
        "setupId=", tostring(#setupId), ":", setupId,
        "|round=", tostring(round),
        "|cursor=", tostring(rng.cursor),
        "|selected=", tostring(#selectedCardIds), ":",
    }
    for _, cardId in ipairs(selectedCardIds) do
        parts[#parts + 1] = tostring(#cardId)
        parts[#parts + 1] = ":"
        parts[#parts + 1] = cardId
        parts[#parts + 1] = ";"
    end
    parts[#parts + 1] = "|offer="
    for _, cardId in ipairs(offerCardIds) do
        parts[#parts + 1] = tostring(#cardId)
        parts[#parts + 1] = ":"
        parts[#parts + 1] = cardId
        parts[#parts + 1] = ";"
    end
    local canonicalToken = table.concat(parts)
    local hashA = 0
    local hashB = 0
    for index = 1, #canonicalToken do
        local byte = string.byte(canonicalToken, index)
        hashA = (hashA * 131 + byte) % 2147483647
        hashB = (hashB * 137 + byte) % 2147483629
    end
    return "game-setup-draft-v1:" .. tostring(#canonicalToken) .. ":" .. tostring(hashA) .. ":" .. tostring(hashB)
end

local function buildCharacterToken(setupId, rng, characterIds)
    local parts = {
        "setupId=", tostring(#setupId), ":", setupId,
        "|cursor=", tostring(rng.cursor),
        "|characters=", tostring(#characterIds), ":",
    }
    for _, characterId in ipairs(characterIds) do
        parts[#parts + 1] = tostring(#characterId)
        parts[#parts + 1] = ":"
        parts[#parts + 1] = characterId
        parts[#parts + 1] = ";"
    end
    local canonicalToken = table.concat(parts)
    local hashA = 0
    local hashB = 0
    for index = 1, #canonicalToken do
        local byte = string.byte(canonicalToken, index)
        hashA = (hashA * 131 + byte) % 2147483647
        hashB = (hashB * 137 + byte) % 2147483629
    end
    return "game-setup-character-v1:" .. tostring(#canonicalToken) .. ":" .. tostring(hashA) .. ":" .. tostring(hashB)
end

-- Pre-optimization reference: rebuild every offer from seed and selection history.
local function legacyReplay(setupId, seed, selectedCardIds, pool)
    local counts = {}
    local rng = { seed = seed, cursor = 0 }
    for round = 1, 10 do
        local eligible = {}
        for _, cardId in ipairs(pool) do
            if (counts[cardId] or 0) < 2 then eligible[#eligible + 1] = cardId end
        end
        local history = {}
        for index = 1, round - 1 do history[index] = selectedCardIds[index] end
        local offered = {}
        for pick = 1, 3 do
            local report = modules.deterministicRng("legacy-reference", "nextInteger", rng, 1, #eligible)
            assert(report.ok == true, "legacy RNG failed")
            offered[pick] = eligible[report.value]
            table.remove(eligible, report.value)
            rng = { seed = report.rng.seed, cursor = report.rng.cursor }
        end
        local offer = {
            round = round,
            cardIds = offered,
            interactionToken = buildToken(setupId, round, rng, history, offered),
        }
        if round <= #selectedCardIds then
            local selectedId = selectedCardIds[round]
            assert(contains(offered, selectedId), "legacy fixture selected outside offer")
            counts[selectedId] = (counts[selectedId] or 0) + 1
        else
            return {
                schemaVersion = 1,
                kind = "gameSetupV1",
                setupId = setupId,
                phase = "deckDraft",
                rng = rng,
                selectedCardIds = copyArray(selectedCardIds),
                offer = offer,
            }
        end
    end
    return {
        schemaVersion = 1,
        kind = "gameSetupV1",
        setupId = setupId,
        phase = "deckComplete",
        rng = rng,
        selectedCardIds = copyArray(selectedCardIds),
    }
end

local staticReport = runScript("incremental-check", "staticData", "loadAll")
assert(staticReport.ok == true, "staticData fixture failed")
local staticData = staticReport.data
local pool = {}
for cardId, card in pairs(staticData.cards) do
    if card.owner == "player" then pool[#pool + 1] = cardId end
end
table.sort(pool)
local characterPool = {}
for characterId in pairs(staticData.characters) do
    characterPool[#characterPool + 1] = characterId
end
table.sort(characterPool)

local seeds = { 1, 2, 3, 7, 42, 12345, 2147483646 }
for index = 1, 64 do
    seeds[#seeds + 1] = ((index * 48271 + index * index * 97) % 2147483646) + 1
end

local traces = 0
local transitions = 0
for seedIndex, seed in ipairs(seeds) do
    local setupId = "property-" .. tostring(seedIndex) .. "-" .. tostring(seed)
    rngCalls = 0
    local started = runScript("incremental-check", "gameSetup", "start", {
        setupId = setupId,
        seed = seed,
    }, staticData)
    assert(started.ok == true, "optimized start failed for seed " .. tostring(seed))
    assert(rngCalls == 1, "start must batch one offer into one RNG module call")
    local selections = {}
    assert(canonical(started.state) == canonical(legacyReplay(setupId, seed, selections, pool)),
        "start differs from legacy replay for seed " .. tostring(seed))

    local state = started.state
    while state.phase == "deckDraft" do
        local selectedBefore = #selections
        local slot = ((seedIndex * 11 + seed + state.offer.round * 7) % 3) + 1
        local chosenCard = state.offer.cardIds[slot]
        local oldToken = state.offer.interactionToken
        selections[#selections + 1] = chosenCard

        rngCalls = 0
        local chosen = runScript("incremental-check", "gameSetup", "choose", state, {
            cardId = chosenCard,
            interactionToken = oldToken,
        }, staticData)
        assert(chosen.ok == true and chosen.applied == true and chosen.stale == false,
            "optimized choose failed for seed/round " .. tostring(seed) .. "/" .. tostring(selectedBefore + 1))
        local expectedOfferCount = selectedBefore + 1
        if #selections < 10 then expectedOfferCount = expectedOfferCount + 1 end
        assert(rngCalls == expectedOfferCount,
            "choose replayed more than current authority plus one offer at seed/round "
                .. tostring(seed) .. "/" .. tostring(selectedBefore + 1)
                .. ": " .. tostring(rngCalls) .. " ~= " .. tostring(expectedOfferCount))

        local legacy = legacyReplay(setupId, seed, selections, pool)
        assert(canonical(chosen.state) == canonical(legacy),
            "incremental state/token/RNG differs from legacy replay at seed/round "
                .. tostring(seed) .. "/" .. tostring(#selections))

        local validated = runScript("incremental-check", "gameSetup", "validate", chosen.state, staticData)
        assert(validated.ok == true and canonical(validated.state) == canonical(chosen.state),
            "incremental output does not pass the retained replay validator")
        state = chosen.state
        transitions = transitions + 1
    end
    assert(#selections == 10 and state.offer == nil, "property trace did not complete")

    local referenceCandidates = copyArray(characterPool)
    local expectedCharacterIds = {}
    local expectedCharacterRng = { seed = state.rng.seed, cursor = state.rng.cursor }
    for pick = 1, 3 do
        local roll = modules.deterministicRng(
            "character-reference",
            "nextInteger",
            expectedCharacterRng,
            1,
            #referenceCandidates
        )
        assert(roll.ok == true, "character reference RNG failed")
        expectedCharacterIds[pick] = referenceCandidates[roll.value]
        table.remove(referenceCandidates, roll.value)
        expectedCharacterRng = roll.rng
    end

    rngCalls = 0
    local characterSelect = runScript(
        "incremental-check",
        "gameSetup",
        "beginCharacterSelect",
        state,
        staticData
    )
    assert(characterSelect.ok == true
            and characterSelect.applied == true
            and characterSelect.stale == false,
        "characterSelect transition failed for seed " .. tostring(seed))
    assert(rngCalls == 11,
        "characterSelect must replay ten deck offers and batch one character offer")
    assert(canonical(characterSelect.state.characterOffer.characterIds) == canonical(expectedCharacterIds)
            and canonical(characterSelect.state.rng) == canonical(expectedCharacterRng)
            and characterSelect.state.characterOffer.interactionToken
                == buildCharacterToken(setupId, expectedCharacterRng, expectedCharacterIds),
        "character offer/RNG/token differs from the independent reference")

    rngCalls = 0
    local characterValidated = runScript(
        "incremental-check",
        "gameSetup",
        "validate",
        characterSelect.state,
        staticData
    )
    assert(characterValidated.ok == true
            and canonical(characterValidated.state) == canonical(characterSelect.state)
            and rngCalls == 11,
        "characterSelect full replay validation changed")

    local characterSlot = ((seedIndex * 13 + seed) % 3) + 1
    rngCalls = 0
    local battleReady = runScript(
        "incremental-check",
        "gameSetup",
        "chooseCharacter",
        characterSelect.state,
        {
            characterId = expectedCharacterIds[characterSlot],
            interactionToken = characterSelect.state.characterOffer.interactionToken,
        },
        staticData
    )
    assert(battleReady.ok == true
            and battleReady.applied == true
            and battleReady.stale == false
            and battleReady.state.phase == "battleReady"
            and battleReady.state.selectedCharacterId == expectedCharacterIds[characterSlot]
            and rngCalls == 11,
        "character choice failed deterministic full replay")
    local expectedBattleSeed = ((((seed - 1) % 2147483646) + 104729) % 2147483646) + 1
    assert(battleReady.state.battleSpec.seed == expectedBattleSeed
            and battleReady.state.battleSpec.battleId == "battle-" .. setupId
            and battleReady.state.battleSpec.environmentId == "uncrowded"
            and battleReady.state.battleSpec.turnLimit == 10,
        "battleSpec differs from its deterministic domain-separated reference")
    rngCalls = 0
    local readyValidated = runScript(
        "incremental-check",
        "gameSetup",
        "validate",
        battleReady.state,
        staticData
    )
    assert(readyValidated.ok == true
            and canonical(readyValidated.state) == canonical(battleReady.state)
            and rngCalls == 11,
        "battleReady full replay validation changed")
    transitions = transitions + 2
    traces = traces + 1
end

print("game-setup-incremental-check: ok | traces=" .. traces .. " | transitions=" .. transitions)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[game-setup-incremental-check]],[[t]],_G))()'
    $output = $luaTest | & $luaHost -e $luaEntry 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    $output
}
finally {
    Pop-Location
}
