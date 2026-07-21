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
    gameSetup = loadLore("System/gameSetup.lua"),
    staticData = loadLore("System/staticData.lua"),
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

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end

function setChatVar() error("gameSetup must not write chat variables") end
function setState() error("gameSetup must not write host state") end
function reloadDisplay() error("gameSetup must not reload display") end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local lines = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            lines[#lines + 1] = tostring(item.code) .. " at " .. tostring(item.path) .. ": " .. tostring(item.message)
        end
        error(label .. " failed\n" .. table.concat(lines, "\n"))
    end
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    return report
end

local function assertFailed(label, report)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(type(report.errors) == "table" and #report.errors > 0, label .. " must return structured errors")
    for _, item in ipairs(report.errors) do
        assert(type(item.code) == "string" and item.code ~= "", label .. " error code missing")
        assert(type(item.path) == "string" and item.path ~= "", label .. " error path missing")
        assert(type(item.message) == "string" and item.message ~= "", label .. " error message missing")
    end
    return report
end

local function canonical(value, active)
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    if kind == "function" then return "<function>" end
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

local function clone(value, active)
    if type(value) ~= "table" then return value end
    active = active or {}
    assert(not active[value], "cycle in clone fixture")
    active[value] = true
    local copy = {}
    for key, item in pairs(value) do copy[clone(key, active)] = clone(item, active) end
    active[value] = nil
    return copy
end

local function contains(array, expected)
    for _, value in ipairs(array) do
        if value == expected then return true end
    end
    return false
end

local function assertOffer(label, state, data, counts)
    assert(state.phase == "deckDraft", label .. " phase changed")
    assert(type(state.offer) == "table", label .. " offer missing")
    assert(state.offer.round == #state.selectedCardIds + 1, label .. " round mismatch")
    assert(type(state.offer.interactionToken) == "string" and state.offer.interactionToken ~= "", label .. " token missing")
    assert(#state.offer.cardIds == 3, label .. " must offer three cards")
    local seen = {}
    for _, cardId in ipairs(state.offer.cardIds) do
        assert(not seen[cardId], label .. " duplicated an offered card")
        seen[cardId] = true
        assert(type(data.cards[cardId]) == "table" and data.cards[cardId].owner == "player", label .. " offered a non-player card")
        assert((counts[cardId] or 0) < 2, label .. " offered a card already owned twice")
    end
end

local staticReport = assertOk("load static data", runScript("game-setup-check", "staticData", "loadAll"))
local staticData = staticReport.data
local spec = { setupId = "setup-check", seed = 12345 }
local specSnapshot = canonical(spec)
local staticSnapshot = canonical(staticData)
local started = assertOk("start", runScript("game-setup-check", "gameSetup", "start", spec, staticData))
assert(canonical(spec) == specSnapshot, "start mutated its spec")
assert(canonical(staticData) == staticSnapshot, "start mutated staticData")
assert(started.state.kind == "gameSetupV1" and started.state.schemaVersion == 1, "authority identity changed")
assert(started.state.setupId == spec.setupId, "setupId changed")
assert(started.state.rng.seed == spec.seed and started.state.rng.cursor > 0, "first offer did not consume explicit RNG")
assert(#started.state.selectedCardIds == 0, "new setup already selected cards")
assertOffer("first", started.state, staticData, {})
assertOk("validate start", runScript("game-setup-check", "gameSetup", "validate", started.state, staticData))

local sameStart = assertOk("same start", runScript("game-setup-check", "gameSetup", "start", spec, staticData))
assert(canonical(started.state) == canonical(sameStart.state), "same start input produced a different state")
assert(started.state ~= sameStart.state and started.state.offer ~= sameStart.state.offer, "start results alias each other")

assertFailed("unknown start field", runScript(
    "game-setup-check", "gameSetup", "start", { setupId = "setup-check", seed = 1, extra = true }, staticData
))
assertFailed("missing seed", runScript("game-setup-check", "gameSetup", "start", { setupId = "setup-check" }, staticData))

local realDeterministicRng = modules.deterministicRng
modules.deterministicRng = function(triggerId, rngAction, ...)
    local report = realDeterministicRng(triggerId, rngAction, ...)
    if type(report) == "table" and report.ok == true and type(report.rng) == "table" then
        report.rng.seed = report.rng.seed + 1
    end
    return report
end
assertFailed("rng seed change", runScript("game-setup-check", "gameSetup", "start", spec, staticData))
modules.deterministicRng = realDeterministicRng

local sixTypes = clone(staticData)
local playerIds = {}
for cardId, card in pairs(sixTypes.cards) do
    if card.owner == "player" then playerIds[#playerIds + 1] = cardId end
end
table.sort(playerIds)
for index = 7, #playerIds do sixTypes.cards[playerIds[index]] = nil end
assertFailed("insufficient player types", runScript("game-setup-check", "gameSetup", "start", spec, sixTypes))

local unoffered
for cardId, card in pairs(staticData.cards) do
    if card.owner == "player" and not contains(started.state.offer.cardIds, cardId) then
        unoffered = cardId
        break
    end
end
assert(unoffered, "unoffered fixture missing")
local beforeInvalid = canonical(started.state)
assertFailed("malformed token", runScript("game-setup-check", "gameSetup", "choose", started.state, {
    cardId = started.state.offer.cardIds[1],
    interactionToken = "arbitrary-stale-token",
}, staticData))
assertFailed("unoffered choice", runScript("game-setup-check", "gameSetup", "choose", started.state, {
    cardId = unoffered,
    interactionToken = started.state.offer.interactionToken,
}, staticData))
assert(canonical(started.state) == beforeInvalid, "failed choice mutated authority")

local firstApplied = assertOk("first choice", runScript("game-setup-check", "gameSetup", "choose", started.state, {
    cardId = started.state.offer.cardIds[1],
    interactionToken = started.state.offer.interactionToken,
}, staticData))
assert(firstApplied.applied == true and firstApplied.stale == false, "valid choice flags changed")
assert(#firstApplied.state.selectedCardIds == 1, "valid choice was not appended")
assert(firstApplied.state ~= started.state and firstApplied.state.selectedCardIds ~= started.state.selectedCardIds, "choice result aliases input")

local staleSnapshot = canonical(firstApplied.state)
local stale = assertOk("stale choice", runScript("game-setup-check", "gameSetup", "choose", firstApplied.state, {
    cardId = firstApplied.state.offer.cardIds[1],
    interactionToken = started.state.offer.interactionToken,
}, staticData))
assert(stale.applied == false and stale.stale == true, "old token was not a successful no-op")
assert(canonical(stale.state) == staleSnapshot and canonical(firstApplied.state) == staleSnapshot, "stale choice changed authority")
assert(stale.state ~= firstApplied.state and stale.state.offer ~= firstApplied.state.offer, "stale result aliases authority")

local tamperedOffer = clone(firstApplied.state)
tamperedOffer.offer.cardIds[1], tamperedOffer.offer.cardIds[2] = tamperedOffer.offer.cardIds[2], tamperedOffer.offer.cardIds[1]
assertFailed("tampered offer", runScript("game-setup-check", "gameSetup", "validate", tamperedOffer, staticData))
local tamperedRng = clone(firstApplied.state)
tamperedRng.rng.cursor = tamperedRng.rng.cursor + 1
assertFailed("tampered rng", runScript("game-setup-check", "gameSetup", "validate", tamperedRng, staticData))
local unknownState = clone(firstApplied.state)
unknownState.futureOffer = {}
assertFailed("unknown state field", runScript("game-setup-check", "gameSetup", "validate", unknownState, staticData))
local missingStatic = clone(staticData)
missingStatic.cards[firstApplied.state.offer.cardIds[1]] = nil
assertFailed("missing static card", runScript("game-setup-check", "gameSetup", "validate", firstApplied.state, missingStatic))

local trace = {}
local counts = {}
local state = firstApplied.state
local finalCard
local finalToken
counts[state.selectedCardIds[1]] = 1
trace[#trace + 1] = table.concat(started.state.offer.cardIds, ",") .. ">" .. state.selectedCardIds[1]

while state.phase == "deckDraft" do
    assertOffer("round " .. state.offer.round, state, staticData, counts)
    trace[#trace + 1] = table.concat(state.offer.cardIds, ",") .. ">" .. state.offer.cardIds[1]
    local before = canonical(state)
    local chosen = state.offer.cardIds[1]
    finalCard = chosen
    finalToken = state.offer.interactionToken
    local report = assertOk("choose round " .. state.offer.round, runScript("game-setup-check", "gameSetup", "choose", state, {
        cardId = chosen,
        interactionToken = state.offer.interactionToken,
    }, staticData))
    assert(canonical(state) == before, "choice mutated round input")
    assert(report.applied == true and report.stale == false, "round choice flags changed")
    counts[chosen] = (counts[chosen] or 0) + 1
    assert(counts[chosen] <= 2, "copy limit exceeded")
    state = report.state
end

assert(state.phase == "deckComplete", "tenth choice did not complete deck")
assert(#state.selectedCardIds == 10, "completed deck is not ten cards")
assert(state.offer == nil, "completed state retained an offer")
assertOk("validate complete", runScript("game-setup-check", "gameSetup", "validate", state, staticData))
for _, amount in pairs(counts) do assert(amount <= 2, "completed deck exceeded copy limit") end
local completeSnapshot = canonical(state)
local completeStale = assertOk("tenth choice double click", runScript("game-setup-check", "gameSetup", "choose", state, {
    cardId = finalCard, interactionToken = finalToken,
}, staticData))
assert(completeStale.applied == false and completeStale.stale == true,
    "tenth choice double click was not a successful stale no-op")
assert(canonical(completeStale.state) == completeSnapshot and canonical(state) == completeSnapshot,
    "tenth choice double click changed the completed state")
assert(completeStale.state ~= state and completeStale.state.selectedCardIds ~= state.selectedCardIds,
    "tenth choice stale result aliases the completed input")

local function runTraceAgain()
    local current = assertOk("trace restart", runScript("game-setup-check", "gameSetup", "start", spec, staticData)).state
    local replay = {}
    while current.phase == "deckDraft" do
        local chosen = current.offer.cardIds[1]
        replay[#replay + 1] = table.concat(current.offer.cardIds, ",") .. ">" .. chosen
        current = assertOk("trace replay", runScript("game-setup-check", "gameSetup", "choose", current, {
            cardId = chosen,
            interactionToken = current.offer.interactionToken,
        }, staticData)).state
    end
    return table.concat(replay, "|")
end

local traceText = table.concat(trace, "|")
assert(runTraceAgain() == traceText, "same seed and choices produced a different ten-round trace")
print("VECTOR|rounds=" .. tostring(#trace) .. "|cursor=" .. tostring(state.rng.cursor) .. "|trace=" .. traceText)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[game-setup-check]],[[t]],_G))()'
    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua gameSetup 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }
    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua gameSetup 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }
    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 gameSetup 결과를 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^VECTOR\|rounds=10\|cursor=[1-9][0-9]*\|trace=') {
        throw "gameSetup 결정성 표식 형식이 예상과 다릅니다: $firstText"
    }
    Write-Output 'game-setup-check: ok'
    Write-Output 'NOTE: 실제 RisuAI 저장·UI 통합 환경에서는 아직 검증하지 않았습니다.'
}
finally {
    Pop-Location
}
