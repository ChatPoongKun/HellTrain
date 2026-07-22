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
    staticData = loadLore("System/staticData.lua"),
    gameSetup = loadLore("System/gameSetup.lua"),
    viewBuilder = loadLore("System/viewBuilder.lua"),
    gameSetupView = loadLore("System/gameSetupView.lua"),
    dataBridge = loadLore("System/dataBridge.lua"),
}

local moduleCalls = {}
function runScript(triggerId, name, ...)
    moduleCalls[name] = (moduleCalls[name] or 0) + 1
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

local published = {}
local publishCount = 0
function setChatVar(triggerId, name, value)
    publishCount = publishCount + 1
    published[name] = value
end

local function rejectHostWrite(name)
    return function()
        error("unexpected host write: " .. name)
    end
end
setState = rejectHostWrite("setState")
setFullChat = rejectHostWrite("setFullChat")
addChat = rejectHostWrite("addChat")
reloadDisplay = rejectHostWrite("reloadDisplay")
upsertLocalLoreBook = rejectHostWrite("upsertLocalLoreBook")

local function clone(value, active)
    if type(value) ~= "table" then return value end
    active = active or {}
    assert(not active[value], "cycle in clone fixture")
    active[value] = true
    local copy = {}
    for key, item in pairs(value) do
        copy[clone(key, active)] = clone(item, active)
    end
    active[value] = nil
    return copy
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
    return report
end

local function assertFailed(label, report)
    assert(type(report) == "table" and report.ok == false, label .. " unexpectedly succeeded")
    assert(type(report.errors) == "table" and #report.errors > 0, label .. " returned no structured errors")
    return report
end

local function hasError(report, code)
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        if item.code == code then return true end
    end
    return false
end

local function assertNoPrivateFields(label, value)
    local text = canonical(value)
    local forbidden = {
        "PRIVATE_SETUP_CANARY",
        "918273645",
        "setupId",
        "selectedCardIds",
        "rng",
        "seed",
        "battleSpec",
        "privateProfile",
        "PRIVATE_CHARACTER_CANARY",
        "characterIntent",
        "NARRATION_CANARY",
        "PROTOTYPE_CANARY",
        "FUNCTION_CANARY",
        "narration",
        "prototype",
        "resolver",
    }
    for _, canary in ipairs(forbidden) do
        assert(not string.find(text, canary, 1, true), label .. " leaked private value/field: " .. canary)
    end
end

local staticData = assertOk(
    "static data",
    runScript("game-setup-view-check", "staticData", "loadAll")
).data

-- A seed fixture whose second offer contains the first selected card gives a
-- deterministic duplicate, so first-seen deck grouping is tested meaningfully.
local fixtureState
local fixtureSeed
for seed = 0, 1000 do
    local started = assertOk(
        "fixture start",
        runScript("game-setup-view-check", "gameSetup", "start", {
            setupId = "PRIVATE_SETUP_CANARY",
            seed = seed,
        }, staticData)
    ).state
    local firstCard = started.offer.cardIds[1]
    local nextState = assertOk(
        "fixture first choice",
        runScript("game-setup-view-check", "gameSetup", "choose", started, {
            cardId = firstCard,
            interactionToken = started.offer.interactionToken,
        }, staticData)
    ).state
    local duplicateSlot
    for index, cardId in ipairs(nextState.offer.cardIds) do
        if cardId == firstCard then duplicateSlot = index end
    end
    if duplicateSlot then
        fixtureSeed = seed
        fixtureState = assertOk(
            "fixture duplicate choice",
            runScript("game-setup-view-check", "gameSetup", "choose", nextState, {
                cardId = nextState.offer.cardIds[duplicateSlot],
                interactionToken = nextState.offer.interactionToken,
            }, staticData)
        ).state
        break
    end
end
assert(fixtureState and fixtureSeed, "could not find deterministic duplicate fixture")
assert(fixtureState.selectedCardIds[1] == fixtureState.selectedCardIds[2], "duplicate fixture changed")

local initial = assertOk(
    "initial start",
    runScript("game-setup-view-check", "gameSetup", "start", {
        setupId = "PRIVATE_SETUP_CANARY",
        seed = 918273645,
    }, staticData)
).state
local initialStateSnapshot = canonical(initial)
local staticSnapshot = canonical(staticData)
local initialBuilt = assertOk(
    "initial View build",
    runScript("game-setup-view-check", "gameSetupView", "build", initial, staticData)
)
local initialView = initialBuilt.view
assert(canonical(initial) == initialStateSnapshot and canonical(staticData) == staticSnapshot,
    "initial View build mutated authority or static data")
assert(initialView.kind == "gameSetupView" and initialView.phase == "deckDraft" and initialView.locked == false)
assert(initialView.progress.selectedCount == 0 and initialView.progress.currentRound == 1)
assert(initialView.progress.totalRounds == 10 and initialView.progress.remainingRounds == 10)
assert(initialView.deck.count == 0 and initialView.deck.limit == 10 and #initialView.deck.items == 0)
assert(type(initialView.offer) == "table" and #initialView.offer.cards == 3)
assertOk("initial View validate", runScript("game-setup-view-check", "gameSetupView", "validate", initialView))
assertNoPrivateFields("initial View", initialView)

local deniedCanonical = assertFailed(
    "canonical View without controller capability",
    runScript("game-setup-view-check", "gameSetupView", "_buildCanonical", initial, staticData)
)
assert(hasError(deniedCanonical, "internal_action_denied"),
    "canonical View fast path was exposed to string-only button callers")
local internalBuilt = assertOk(
    "canonical View with controller capability",
    runScript("game-setup-view-check", "gameSetupView", "_buildCanonical", initial, staticData, function(purpose)
        return purpose == "gameSetupViewCanonicalV1"
    end)
)
assert(canonical(internalBuilt.view) == canonical(initialView),
    "canonical View fast path differs from the public validating build")

-- Add a distinct third selection after the forced duplicate. This yields
-- [A, A, B], whose View must group as A x2 followed by B x1.
local distinctCard
for _, cardId in ipairs(fixtureState.offer.cardIds) do
    if cardId ~= fixtureState.selectedCardIds[1] then
        distinctCard = cardId
        break
    end
end
assert(distinctCard, "distinct third-card fixture missing")
fixtureState = assertOk(
    "fixture distinct choice",
    runScript("game-setup-view-check", "gameSetup", "choose", fixtureState, {
        cardId = distinctCard,
        interactionToken = fixtureState.offer.interactionToken,
    }, staticData)
).state

local riskyText = "한글 CBS :: 위험 {{literal}} <img src=x onerror=alert(1)> & \"quoted\" 'single' (끝):"
local hostileStatic = clone(staticData)
local riskyCardId = fixtureState.offer.cardIds[2]
hostileStatic.cards[riskyCardId].name = riskyText
hostileStatic.cards[riskyCardId].description = riskyText .. " ::tag[contact]::"
hostileStatic.cards[riskyCardId].narration = "NARRATION_CANARY"
hostileStatic.cards[riskyCardId].prototype = "PROTOTYPE_CANARY"
hostileStatic.cards[riskyCardId].resolver = function() return "FUNCTION_CANARY" end
for _, character in pairs(hostileStatic.characters) do
    character.privateProfile.viewLeakCanary = "PRIVATE_CHARACTER_CANARY"
end

local authoritySnapshot = canonical(fixtureState)
local hostileStaticSnapshot = canonical(hostileStatic)
assertOk(
    "clear presentation cache",
    runScript("game-setup-view-check", "viewBuilder", "clearPresentationCache")
)
local partialReport = assertOk(
    "partial View build",
    runScript("game-setup-view-check", "gameSetupView", "build", fixtureState, hostileStatic)
)
local partialView = partialReport.view
local repeatedPartial = assertOk(
    "repeat partial View build",
    runScript("game-setup-view-check", "gameSetupView", "build", fixtureState, hostileStatic)
).view
assert(canonical(partialView) == canonical(repeatedPartial), "same authority produced a different View")
local presentationStats = assertOk(
    "presentation cache stats",
    runScript("game-setup-view-check", "viewBuilder", "presentationCacheStats")
).cache
assert(presentationStats.entries > 0 and presentationStats.hits >= #repeatedPartial.offer.cards,
    "repeated View build did not reuse immutable card presentation fragments")
assert(canonical(fixtureState) == authoritySnapshot, "partial View build mutated authority")
assert(canonical(hostileStatic) == hostileStaticSnapshot, "partial View build mutated static data")

assert(partialView.progress.selectedCount == 3 and partialView.progress.currentRound == 4)
assert(partialView.progress.remainingRounds == 7 and partialView.deck.count == 3)
assert(#partialView.deck.items == 2, "deck did not group duplicate selections")
assert(partialView.deck.items[1].cardId == fixtureState.selectedCardIds[1]
    and partialView.deck.items[1].copies == 2,
    "first-seen duplicate deck group changed")
assert(partialView.deck.items[2].cardId == fixtureState.selectedCardIds[3]
    and partialView.deck.items[2].copies == 1,
    "second first-seen deck group changed")

local owned = {}
for _, cardId in ipairs(fixtureState.selectedCardIds) do
    owned[cardId] = (owned[cardId] or 0) + 1
end
for slot, cardView in ipairs(partialView.offer.cards) do
    local cardId = fixtureState.offer.cardIds[slot]
    local card = hostileStatic.cards[cardId]
    assert(cardView.slot == slot and cardView.cardId == cardId, "offer order or slot changed at " .. slot)
    assert(cardView.name == card.name, "offer display name changed at " .. slot)
    assert(type(cardView.descriptionSegments) == "table" and #cardView.descriptionSegments > 0,
        "description display segments missing at " .. slot)
    assert(type(cardView.ruleLines) == "table" and #cardView.ruleLines == #card.rules,
        "rule display lines missing at " .. slot)
    assert(cardView.actionTag.id == card.actionTag and cardView.actionTag.tagKind == "action",
        "action tag display changed at " .. slot)
    assert(type(cardView.mechanisms) == "table" and #cardView.mechanisms == #card.mechanisms,
        "mechanism display list changed at " .. slot)
    assert(cardView.baseStealthCost == card.base.stealthCost
        and cardView.baseResistanceDamage == card.base.resistanceDamage,
        "base display values changed at " .. slot)
    assert(cardView.ownedCopies == (owned[cardId] or 0), "ownedCopies changed at " .. slot)
end
assert(partialView.offer.cards[2].name == riskyText, "hostile display fixture was not used")
assertOk("partial View validate", runScript("game-setup-view-check", "gameSetupView", "validate", partialView))
assertNoPrivateFields("partial View", partialView)

-- Returned View tables must not alias authority or static card/tag tables.
partialView.deck.items[1].name = "VIEW_ALIAS_TAMPER"
partialView.offer.cards[1].name = "VIEW_ALIAS_TAMPER"
partialView.offer.cards[1].actionTag.label = "VIEW_ALIAS_TAMPER"
if partialView.offer.cards[1].descriptionSegments[1] then
    partialView.offer.cards[1].descriptionSegments[1].kind = "VIEW_ALIAS_TAMPER"
end
assert(canonical(fixtureState) == authoritySnapshot, "mutating View changed authority")
assert(canonical(hostileStatic) == hostileStaticSnapshot, "mutating View changed static data")
local postMutationView = assertOk(
    "post-mutation cached View build",
    runScript("game-setup-view-check", "gameSetupView", "build", fixtureState, hostileStatic)
).view
assert(canonical(postMutationView) == canonical(repeatedPartial),
    "caller mutation poisoned the presentation cache")

local revisedStatic = clone(hostileStatic)
local firstOfferId = fixtureState.offer.cardIds[1]
local firstActionId = revisedStatic.cards[firstOfferId].actionTag
revisedStatic.registry.actionTags[firstActionId].label = "REVISION_CANARY"
local revisedView = assertOk(
    "revision-keyed presentation build",
    runScript("game-setup-view-check", "gameSetupView", "build", fixtureState, revisedStatic)
).view
assert(revisedView.offer.cards[1].actionTag.label == "REVISION_CANARY",
    "registry revision reused a stale presentation fragment")

-- Array boundaries are part of the presentation key. Without explicit field
-- counts these two legal cards collapse to the same key ("rules", "rules").
local collisionRegistry = clone(hostileStatic.registry)
collisionRegistry.mechanisms.rules = {
    id = "rules",
    label = "경계 메커니즘",
    tooltip = "캐시 필드 경계 검사용",
}
local collisionCard = clone(hostileStatic.cards[firstOfferId])
collisionCard.mechanisms = { "rules" }
collisionCard.rules = {}
assertOk("clear collision cache", runScript(
    "game-setup-view-check", "viewBuilder", "clearPresentationCache"
))
local mechanismPresentation = assertOk(
    "mechanism-side cache boundary",
    runScript("game-setup-view-check", "viewBuilder", "buildCardPresentation",
        collisionCard, collisionRegistry, "$.collision")
).card
collisionCard.mechanisms = {}
collisionCard.rules = { "rules" }
local rulePresentation = assertOk(
    "rule-side cache boundary",
    runScript("game-setup-view-check", "viewBuilder", "buildCardPresentation",
        collisionCard, { data = { registry = collisionRegistry } }, "$.collision")
).card
assert(#mechanismPresentation.mechanisms == 1 and #mechanismPresentation.ruleLines == 0,
    "mechanism-side collision fixture was not represented")
assert(#rulePresentation.mechanisms == 0 and #rulePresentation.ruleLines == 1,
    "presentation cache aliased mechanism and rule array boundaries")
partialView = repeatedPartial

-- Authority replay failures must stop View construction.
local rngTamper = clone(fixtureState)
rngTamper.rng.cursor = rngTamper.rng.cursor + 1
assertFailed("tampered authority rng", runScript(
    "game-setup-view-check", "gameSetupView", "build", rngTamper, hostileStatic
))
local offerTamper = clone(fixtureState)
offerTamper.offer.cardIds[1], offerTamper.offer.cardIds[2] = offerTamper.offer.cardIds[2], offerTamper.offer.cardIds[1]
assertFailed("tampered authority offer", runScript(
    "game-setup-view-check", "gameSetupView", "build", offerTamper, hostileStatic
))
local historyTamper = clone(fixtureState)
historyTamper.selectedCardIds[1] = historyTamper.offer.cardIds[1]
assertFailed("tampered authority history", runScript(
    "game-setup-view-check", "gameSetupView", "build", historyTamper, hostileStatic
))

local unknownView = clone(partialView)
unknownView.privateAuthority = "NARRATION_CANARY"
assert(hasError(assertFailed(
    "unknown View field",
    runScript("game-setup-view-check", "gameSetupView", "validate", unknownView)
), "unknown_field"), "unknown View field did not report unknown_field")

local metatableView = setmetatable({}, { __pairs = function() error("PAIR_CANARY") end })
assert(hasError(assertFailed(
    "metatable View",
    runScript("game-setup-view-check", "gameSetupView", "validate", metatableView)
), "metatable_not_allowed"), "metatable View did not report metatable_not_allowed")

local cycleView = clone(partialView)
cycleView.cycle = cycleView
assert(hasError(assertFailed(
    "cycle View",
    runScript("game-setup-view-check", "gameSetupView", "validate", cycleView)
), "circular_reference"), "cycle View did not report circular_reference")

local functionView = clone(partialView)
functionView.offer.cards[1].resolver = function() return "FUNCTION_CANARY" end
assert(hasError(assertFailed(
    "function View",
    runScript("game-setup-view-check", "gameSetupView", "validate", functionView)
), "unsupported_type"), "function View did not report unsupported_type")

assertOk(
    "bridge validate gameSetupView",
    runScript("game-setup-view-check", "dataBridge", "validate", "gameSetupView", partialView)
)
local encodedReport = assertOk(
    "bridge encode gameSetupView",
    runScript("game-setup-view-check", "dataBridge", "encode", "gameSetupView", partialView)
)
assert(encodedReport.wireFormat == "cbs-json-nodes-v1" and type(encodedReport.encoded) == "string")
assert(encodedReport.bytes == #encodedReport.encoded, "encoded byte count changed")
assertNoPrivateFields("encoded gameSetupView", encodedReport.encoded)
assert(not string.find(encodedReport.encoded, "<img", 1, true), "HTML risk remained active in encoded View")
assert(not string.find(encodedReport.encoded, "{{literal}}", 1, true), "CBS braces remained active in encoded View")
assert(not string.find(encodedReport.encoded, ":: 위험", 1, true), "CBS colon pair remained active in encoded View")

local publishReport = assertOk(
    "bridge publish gameSetupView",
    runScript("game-setup-view-check", "dataBridge", "publish", "gameSetupView", partialView)
)
assert(publishCount == 1 and published.gameSetupView == publishReport.encoded,
    "publish did not write exactly one gameSetupView payload")
local publishedSnapshot = published.gameSetupView
assertFailed(
    "bridge rejects invalid publish",
    runScript("game-setup-view-check", "dataBridge", "publish", "gameSetupView", unknownView)
)
assert(publishCount == 1 and published.gameSetupView == publishedSnapshot,
    "failed publish changed the host payload")

assert(hasError(assertFailed(
    "canonical bridge requires capability",
    runScript("game-setup-view-check", "dataBridge", "_publishCanonical", "gameSetupView", partialView, "forged")
), "internal_action_denied"), "canonical bridge accepted a string capability")
local function permitCanonical(purpose, viewName)
    return purpose == "dataBridgeCanonicalV1" and viewName == "gameSetupView"
end
local canonicalPublish = assertOk(
    "canonical bridge publish",
    runScript(
        "game-setup-view-check",
        "dataBridge",
        "_publishCanonical",
        "gameSetupView",
        partialView,
        permitCanonical
    )
)
assert(publishCount == 2 and published.gameSetupView == canonicalPublish.encoded,
    "canonical bridge did not publish exactly once")
assertFailed(
    "canonical bridge keeps JSON-safe boundary",
    runScript(
        "game-setup-view-check",
        "dataBridge",
        "_encodeCanonical",
        "gameSetupView",
        functionView,
        permitCanonical
    )
)

local realGameSetupView = modules.gameSetupView
modules.gameSetupView = function()
    error("VALIDATOR_THROW_CANARY")
end
assert(hasError(assertFailed(
    "bridge contains validator exception",
    runScript("game-setup-view-check", "dataBridge", "validate", "gameSetupView", partialView)
), "view_validator_call_failed"), "validator exception escaped dataBridge")
modules.gameSetupView = realGameSetupView

assertFailed(
    "bridge rejects function View",
    runScript("game-setup-view-check", "dataBridge", "encode", "gameSetupView", functionView)
)
assertFailed(
    "bridge rejects cycle View",
    runScript("game-setup-view-check", "dataBridge", "encode", "gameSetupView", cycleView)
)
assertFailed(
    "bridge rejects metatable View",
    runScript("game-setup-view-check", "dataBridge", "encode", "gameSetupView", metatableView)
)

-- The new bridge route must coexist with the established battleView route.
local battleCallsBefore = moduleCalls.viewBuilder or 0
local invalidBattleView = assertFailed(
    "battleView route remains registered",
    runScript("game-setup-view-check", "dataBridge", "validate", "battleView", {})
)
assert(not hasError(invalidBattleView, "unsupported_view"), "battleView route was removed")
assert((moduleCalls.viewBuilder or 0) == battleCallsBefore + 1,
    "battleView validation did not route to viewBuilder")

-- Finish all ten choices and verify the terminal View is locked and contains no offer.
local completeState = fixtureState
local trace = {}
while completeState.phase == "deckDraft" do
    local chosen = completeState.offer.cardIds[1]
    trace[#trace + 1] = table.concat(completeState.offer.cardIds, ",") .. ">" .. chosen
    completeState = assertOk(
        "complete draft round " .. completeState.offer.round,
        runScript("game-setup-view-check", "gameSetup", "choose", completeState, {
            cardId = chosen,
            interactionToken = completeState.offer.interactionToken,
        }, hostileStatic)
    ).state
end
assert(completeState.phase == "deckComplete" and #completeState.selectedCardIds == 10)
assert(completeState.offer == nil, "completed authority retained an offer")
local completeSnapshot = canonical(completeState)
local completeView = assertOk(
    "complete View build",
    runScript("game-setup-view-check", "gameSetupView", "build", completeState, hostileStatic)
).view
assert(canonical(completeState) == completeSnapshot, "complete View build mutated authority")
assert(completeView.phase == "deckComplete" and completeView.locked == true)
assert(completeView.offer == nil, "complete View retained an offer")
assert(completeView.progress.selectedCount == 10 and completeView.progress.currentRound == 10)
assert(completeView.progress.remainingRounds == 0 and completeView.deck.count == 10)
assertOk("complete View validate", runScript("game-setup-view-check", "gameSetupView", "validate", completeView))
assertOk(
    "complete bridge encode",
    runScript("game-setup-view-check", "dataBridge", "encode", "gameSetupView", completeView)
)
assertNoPrivateFields("complete View", completeView)

local characterState = assertOk(
    "begin character selection",
    runScript(
        "game-setup-view-check",
        "gameSetup",
        "beginCharacterSelect",
        completeState,
        hostileStatic
    )
).state
local characterView = assertOk(
    "character selection View build",
    runScript("game-setup-view-check", "gameSetupView", "build", characterState, hostileStatic)
).view
assert(characterView.phase == "characterSelect"
        and characterView.locked == false
        and characterView.offer == nil
        and type(characterView.characterOffer) == "table"
        and #characterView.characterOffer.characters == 3,
    "characterSelect View shape changed")
local seenCharacters = {}
for slot, candidate in ipairs(characterView.characterOffer.characters) do
    local sourceId = characterState.characterOffer.characterIds[slot]
    local source = hostileStatic.characters[sourceId]
    assert(candidate.slot == slot
            and candidate.characterId == sourceId
            and candidate.name == source.name
            and candidate.age == source.publicProfile.age
            and candidate.occupation == source.publicProfile.occupation
            and type(candidate.appearanceSummary) == "string"
            and candidate.appearanceSummary ~= ""
            and candidate.startingResistance == source.battle.startingResistance
            and candidate.startingMood.id == source.battle.startingMood
            and candidate.baseDrawCount == source.battle.baseDrawCount
            and candidate.maxHandSize == source.battle.maxHandSize,
        "character candidate projection differs from public source data")
    assert(not seenCharacters[candidate.characterId], "character View duplicated a candidate")
    seenCharacters[candidate.characterId] = true
    assert(#candidate.traits == #source.battle.traitIds,
        "character View omitted or invented a public trait")
    for traitIndex, trait in ipairs(candidate.traits) do
        local sourceTrait = hostileStatic.traits[source.battle.traitIds[traitIndex]]
        assert(sourceTrait.visibility == "public"
                and trait.id == sourceTrait.id
                and trait.name == sourceTrait.name
                and trait.description == sourceTrait.description,
            "character View trait is not the allowlisted public trait")
    end
end
assert(characterView.characterOffer.interactionToken
        == characterState.characterOffer.interactionToken,
    "character View changed the current interaction token")
assertNoPrivateFields("characterSelect View", characterView)
assertOk("characterSelect View validate", runScript(
    "game-setup-view-check", "gameSetupView", "validate", characterView
))
assertOk("characterSelect bridge encode", runScript(
    "game-setup-view-check", "dataBridge", "encode", "gameSetupView", characterView
))

local readyState = assertOk(
    "choose character for View",
    runScript(
        "game-setup-view-check",
        "gameSetup",
        "chooseCharacter",
        characterState,
        {
            characterId = characterState.characterOffer.characterIds[1],
            interactionToken = characterState.characterOffer.interactionToken,
        },
        hostileStatic
    )
).state
local readyView = assertOk(
    "battleReady View build",
    runScript("game-setup-view-check", "gameSetupView", "build", readyState, hostileStatic)
).view
assert(readyView.phase == "battleReady"
        and readyView.locked == true
        and readyView.offer == nil
        and readyView.characterOffer == nil
        and readyView.selectedCharacter.characterId == readyState.selectedCharacterId
        and readyView.selectedCharacter.name
            == hostileStatic.characters[readyState.selectedCharacterId].name,
    "battleReady View did not expose only the minimal selected character receipt")
assertNoPrivateFields("battleReady View", readyView)
assertOk("battleReady View validate", runScript(
    "game-setup-view-check", "gameSetupView", "validate", readyView
))

local leakedCharacterView = clone(characterView)
leakedCharacterView.characterOffer.characters[1].privateProfile = {
    secret = "PRIVATE_CHARACTER_CANARY",
}
assertFailed("reject private character View field", runScript(
    "game-setup-view-check", "gameSetupView", "validate", leakedCharacterView
))

local wirePath = os.getenv("RISU_GAME_SETUP_VIEW_WIRE_PATH")
assert(type(wirePath) == "string" and wirePath ~= "", "wire output path missing")
local wireFile = assert(io.open(wirePath, "wb"))
wireFile:write(encodedReport.encoded)
wireFile:close()

print("GAME_SETUP_VIEW|seed=" .. fixtureSeed
    .. "|selected=" .. completeView.progress.selectedCount
    .. "|deckGroups=" .. #completeView.deck.items
    .. "|traceHash=" .. stableHash(table.concat(trace, "|"))
    .. "|viewHash=" .. stableHash(canonical(completeView)))
'@

Push-Location $projectRoot
$luaTestPath = $null
$firstWirePath = $null
$secondWirePath = $null
try {
    $luaTestPath = [IO.Path]::GetTempFileName()
    $firstWirePath = [IO.Path]::GetTempFileName()
    $secondWirePath = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($luaTestPath, $luaTest, [Text.UTF8Encoding]::new($false))
    $env:RISU_GAME_SETUP_VIEW_LUA_PATH = $luaTestPath

    $env:RISU_GAME_SETUP_VIEW_WIRE_PATH = $firstWirePath
    $firstOutput = @(& $luaHost -e 'assert(loadfile(os.getenv([[RISU_GAME_SETUP_VIEW_LUA_PATH]]),[[t]],_G))()' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua gameSetupView 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }
    $firstWire = [IO.File]::ReadAllText($firstWirePath, [Text.UTF8Encoding]::new($false))

    $env:RISU_GAME_SETUP_VIEW_WIRE_PATH = $secondWirePath
    $secondOutput = @(& $luaHost -e 'assert(loadfile(os.getenv([[RISU_GAME_SETUP_VIEW_LUA_PATH]]),[[t]],_G))()' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua gameSetupView 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }
    $secondWire = [IO.File]::ReadAllText($secondWirePath, [Text.UTF8Encoding]::new($false))

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 gameSetupView 결과를 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if (-not ($firstWire -ceq $secondWire)) {
        throw '별도 Lua 프로세스가 서로 다른 gameSetupView wire를 만들었습니다.'
    }
    if ($firstText -notmatch '^GAME_SETUP_VIEW\|seed=[0-9]+\|selected=10\|deckGroups=[0-9]+\|traceHash=[0-9]{10}\|viewHash=[0-9]{10}$') {
        throw "gameSetupView 결정성 표식 형식이 예상과 다릅니다: $firstText"
    }

    function Assert-Contract {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { throw "gameSetupView wire contract failed: $Message" }
    }

    $root = ConvertFrom-Json -InputObject $firstWire
    Assert-Contract ($root.kind -ceq 'gameSetupView') 'root kind changed'
    Assert-Contract ($root.locked -is [bool] -and $root.locked -eq $false) 'root boolean changed'
    $offer = ConvertFrom-Json -InputObject ([string]$root.offer)
    [object[]]$cardNodes = ConvertFrom-Json -InputObject ([string]$offer.cards)
    Assert-Contract ($cardNodes.Count -eq 3) 'offer card count changed after nested wire decode'
    $riskyCard = ConvertFrom-Json -InputObject ([string]$cardNodes[1])
    $expectedRiskyText = '한글 CBS :: 위험 {{literal}} <img src=x onerror=alert(1)> & "quoted" ''single'' (끝):'
    Assert-Contract (-not $riskyCard.name.Contains('<img')) 'HTML remained active after wire decode'
    Assert-Contract (-not $riskyCard.name.Contains('{{literal}}')) 'CBS braces remained active after wire decode'
    Assert-Contract (-not $riskyCard.name.Contains(':: 위험')) 'CBS colons remained active after wire decode'
    Assert-Contract ([System.Net.WebUtility]::HtmlDecode([string]$riskyCard.name) -ceq $expectedRiskyText) 'escaped display text did not decode to its original value'

    Write-Output 'game-setup-view-check: ok'
    Write-Output 'NOTE: 실제 RisuAI CBS/HTML 렌더링과 호스트 저장은 별도 통합 검사가 필요합니다.'
}
finally {
    Remove-Item Env:RISU_GAME_SETUP_VIEW_LUA_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:RISU_GAME_SETUP_VIEW_WIRE_PATH -ErrorAction SilentlyContinue
    foreach ($path in @($luaTestPath, $firstWirePath, $secondWirePath)) {
        if ($path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    Pop-Location
}
