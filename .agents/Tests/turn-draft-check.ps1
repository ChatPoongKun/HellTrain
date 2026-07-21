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
local loreOverrides = {}

function getLoreBooks(triggerId, name)
    local path = lorePaths[name]
    if not path then
        return {}
    end
    return { { content = loreOverrides[name] or readFile(path) } }
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
    if valueType == "nil" then
        return "null"
    end
    if valueType == "boolean" or valueType == "number" then
        return tostring(value)
    end
    if valueType == "string" then
        return string.format("%q", value)
    end
    assert(valueType == "table", "non-data value in canonical fixture: " .. valueType)

    active = active or {}
    assert(not active[value], "cycle in canonical fixture")
    active[value] = true

    local numericCount = 0
    local maximum = 0
    local hasNumeric = false
    local hasOther = false
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
        if type(key) == "number" and key % 1 == 0 and key >= 1 then
            hasNumeric = true
            numericCount = numericCount + 1
            maximum = math.max(maximum, key)
        else
            hasOther = true
        end
    end

    local parts = {}
    if hasNumeric and not hasOther and numericCount == maximum then
        for index = 1, maximum do
            table.insert(parts, canonical(value[index], active))
        end
        active[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end

    table.sort(keys, function(left, right)
        local leftKey = type(left) .. ":" .. tostring(left)
        local rightKey = type(right) .. ":" .. tostring(right)
        return leftKey < rightKey
    end)
    for _, key in ipairs(keys) do
        table.insert(parts, canonical(tostring(key), active) .. ":" .. canonical(value[key], active))
    end
    active[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
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

local function assertFailed(label, report)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(type(report.errors) == "table" and #report.errors > 0, label .. " did not return structured errors")
    for _, item in ipairs(report.errors) do
        assert(type(item.code) == "string" and item.code ~= "", label .. " error has no code")
        assert(type(item.path) == "string" and item.path ~= "", label .. " error has no path")
    end
    return report
end

local function assertHasError(label, report, expectedCode)
    assertFailed(label, report)
    for _, item in ipairs(report.errors) do
        if item.code == expectedCode then
            return item
        end
    end
    failReport(label .. " (missing " .. expectedCode .. ")", report)
end

local function assertIds(label, actual, expected)
    assert(type(actual) == "table", label .. " is not an array")
    assert(#actual == #expected, label .. " length mismatch: " .. tostring(#actual) .. " ~= " .. tostring(#expected))
    for index, expectedId in ipairs(expected) do
        assert(actual[index] == expectedId, label .. " mismatch at " .. index .. ": " .. tostring(actual[index]))
    end
end

local function invoke(label, action, battleState, draft, instanceId)
    local stateSnapshot = canonical(battleState)
    local draftSnapshot = canonical(draft)
    local report = runScript(
        "turn-draft-check",
        "turnDraft",
        action,
        battleState,
        staticData,
        draft,
        instanceId
    )
    assert(canonical(battleState) == stateSnapshot, label .. " mutated authoritative battleState")
    assert(canonical(draft) == draftSnapshot, label .. " mutated input draft")
    return report
end

local function draftAction(label, action, battleState, draft, instanceId)
    local report = assertOk(label, invoke(label, action, battleState, draft, instanceId))
    assert(type(report.draft) == "table", label .. " did not return a draft")
    if draft ~= nil then
        assert(report.draft ~= draft, label .. " returned the input draft reference")
    end
    return report.draft
end

local function project(label, battleState, draft)
    local report = assertOk(label, invoke(label, "project", battleState, draft, nil))
    assert(type(report.projection) == "table", label .. " did not return a projection")
    assert(type(report.projection.workingState) == "table", label .. " projection has no workingState")
    assert(report.projection.workingState ~= battleState, label .. " projection returned authoritative state by reference")
    return report.projection
end

local function validateProjectedTurn(label, battleState, projection)
    local report = assertOk(
        label,
        invoke(label, "validateProjection", battleState, projection, nil)
    )
    assert(type(report.projection) == "table", label .. " did not return a projection")
    assert(report.projection ~= projection, label .. " returned the input projection reference")
    assert(
        canonical(report.projection) == canonical(projection),
        label .. " changed a valid projection"
    )
    return report.projection
end

local function assertProjectionRejected(label, battleState, projection, expectedCode)
    local report = invoke(label, "validateProjection", battleState, projection, nil)
    if expectedCode ~= nil then
        return assertHasError(label, report, expectedCode)
    end
    return assertFailed(label, report)
end

local function makeCard(instanceId, cardId, owner, zone, position)
    return {
        instanceId = instanceId,
        cardId = cardId,
        owner = owner,
        zone = zone,
        position = position,
    }
end

local function makeState(cardInstances, seed)
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "battle-draft-001",
        status = "active",
        turnNumber = 1,
        turnLimit = 10,
        environmentId = "uncrowded",
        rng = { seed = seed or 42, cursor = 0 },
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
        cardInstances = cardInstances,
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local EYE = "eye"
local BASE_A = "base-a"
local BASE_B = "base-b"
local PREVIEW_MAIN = "preview-main"

local function standardState()
    return makeState({
        makeCard(EYE, "read_the_room", "player", "hand", 1),
        makeCard(BASE_A, "accidental_brush", "player", "hand", 2),
        makeCard(BASE_B, "pin_down", "player", "hand", 3),
        makeCard(PREVIEW_MAIN, "play_it_cool", "player", "deck", 1),
        makeCard("deck-extra", "hypnotic_whisper", "player", "deck", 2),
    }, 42)
end

local function zoneIds(state, owner, zone)
    local items = {}
    for index, item in ipairs(state.cardInstances) do
        if item.owner == owner and item.zone == zone then
            table.insert(items, { id = item.instanceId, position = item.position, index = index })
        end
    end
    table.sort(items, function(left, right)
        if left.position ~= right.position then
            return left.position < right.position
        end
        return left.index < right.index
    end)
    local ids = {}
    for _, item in ipairs(items) do
        table.insert(ids, item.id)
    end
    return ids
end

local function findCard(state, instanceId)
    for _, item in ipairs(state.cardInstances) do
        if item.instanceId == instanceId then
            return item
        end
    end
    return nil
end

local function assertState(label, state)
    assertOk(label, runScript("turn-draft-check", "stateSchema", "validateBattleState", state, staticData))
end

local function assertConserved(label, beforeState, afterState)
    assertOk(
        label,
        runScript("turn-draft-check", "cardZones", "validateConservation", beforeState, afterState)
    )
end

local function assertPreview(label, preview, drawnIds, availableIds)
    assert(type(preview) == "table", label .. " preview is missing")
    assert(type(preview.events) == "table", label .. " preview.events is missing")
    assertIds(label .. " drawn", preview.drawnInstanceIds, drawnIds)
    assertIds(label .. " available", preview.availableDrawnInstanceIds, availableIds or drawnIds)
    assert(type(preview.rng) == "table", label .. " preview.rng is missing")
end

local function assertEmptyPreview(label, preview)
    assertPreview(label, preview, {}, {})
    assert(#preview.events == 0, label .. " retained preview events")
end

local staticLoad = assertOk(
    "static lore load",
    runScript("turn-draft-check", "staticData", "loadAll")
)
staticData = staticLoad.data
assert(staticLoad.counts.cards == 30, "turn draft fixture did not load all thirty cards")

local eyeDefinition = staticData.cards.read_the_room
assert(type(eyeDefinition) == "table", "read_the_room definition is missing")
assert(eyeDefinition.resolve == nil, "read_the_room duplicated selectionPreview in resolve")
assert(type(eyeDefinition.selectionPreview) == "table")
assert(type(eyeDefinition.selectionPreview.effects) == "table")
assert(#eyeDefinition.selectionPreview.effects == 1)
local eyePreviewEffect = eyeDefinition.selectionPreview.effects[1]
assert(eyePreviewEffect.id == "draw_one")
assert(eyePreviewEffect.op == "draw_cards")
assert(eyePreviewEffect.target == "player")
assert(eyePreviewEffect.amount == 1)

-- selectionPreview is the single effect source. The static loader rejects a
-- duplicated resolve callback and malformed preview metadata before runtime.
local playerCardsSource = readFile("DB/PlayerCards.db")
local resolveConflictSource, resolveConflictCount = string.gsub(
    playerCardsSource,
    "            selectionPreview = {",
    [[            resolve = function(context)
                return {}
            end,
            selectionPreview = {]],
    1
)
assert(resolveConflictCount == 1, "failed to build resolve-conflict fixture")
loreOverrides["PlayerCards.db"] = resolveConflictSource
local resolveConflictReport = runScript("turn-draft-check", "staticData", "loadAll")
loreOverrides["PlayerCards.db"] = nil
assertHasError("preview plus resolve static rejection", resolveConflictReport, "preview_with_resolve")

local invalidAmountSource, invalidAmountCount = string.gsub(
    playerCardsSource,
    '(id = "draw_one",%s*op = "draw_cards",%s*target = "player",%s*amount = )1,',
    function(prefix)
        return prefix .. "0,"
    end,
    1
)
assert(invalidAmountCount == 1, "failed to build invalid preview amount fixture")
loreOverrides["PlayerCards.db"] = invalidAmountSource
local invalidAmountReport = runScript("turn-draft-check", "staticData", "loadAll")
loreOverrides["PlayerCards.db"] = nil
assertHasError("invalid preview amount static rejection", invalidAmountReport, "invalid_preview_amount")

local baseState = standardState()
assertState("standard authority state", baseState)
local authoritySnapshot = canonical(baseState)

local evaluatedEyePreview = assertOk(
    "evaluate eye preview metadata",
    runScript(
        "turn-draft-check",
        "effectEngine",
        "evaluateSelectionPreview",
        staticData,
        baseState,
        EYE
    )
)
assert(#evaluatedEyePreview.commands == 1)
assert(evaluatedEyePreview.commands[1].id == "draw_one")
assert(evaluatedEyePreview.commands[1].op == "draw_cards")
assert(evaluatedEyePreview.commands[1].target == "player")
assert(evaluatedEyePreview.commands[1].amount == 1)

local runtimeTamperedStatic = clone(staticData)
runtimeTamperedStatic.cards.read_the_room.selectionPreview.effects[1].op = "lose_stealth"
assertHasError(
    "runtime tampered preview op rejection",
    runScript(
        "turn-draft-check",
        "effectEngine",
        "evaluateSelectionPreview",
        runtimeTamperedStatic,
        baseState,
        EYE
    ),
    "unsupported_preview_op"
)

local emptyDraft = draftAction("new draft", "newDraft", baseState, nil, nil)
assert(emptyDraft.focusedInstanceId == nil, "new draft unexpectedly focused a card")
assertIds("new draft registration", emptyDraft.registeredCardInstanceIds, {})
assertEmptyPreview("new draft", emptyDraft.preview)

local validatedDraft = draftAction("validate new draft", "validate", baseState, emptyDraft, nil)
assert(canonical(validatedDraft) == canonical(emptyDraft), "draft validation changed a valid draft")
local emptyInteractionToken = assertOk(
    "empty draft interaction token",
    invoke("empty draft interaction token", "interactionToken", baseState, emptyDraft, nil)
).interactionToken
local repeatedInteractionToken = assertOk(
    "repeat empty draft interaction token",
    invoke("repeat empty draft interaction token", "interactionToken", baseState, emptyDraft, nil)
).interactionToken
assert(type(emptyInteractionToken) == "string"
    and string.match(emptyInteractionToken, "^draftv1_%d+_%d+_%d+$") ~= nil,
    "interaction token format is invalid")
assert(repeatedInteractionToken == emptyInteractionToken, "equal drafts produced different interaction tokens")

-- The controller-facing boundary validates authority, draft, token, and transition once.
local atomicRequest = {
    action = "register",
    instanceId = BASE_A,
    expectedInteractionToken = emptyInteractionToken,
}
local atomicRequestSnapshot = canonical(atomicRequest)
local atomicRegister = assertOk(
    "atomic register",
    invoke("atomic register", "applyInteraction", baseState, emptyDraft, atomicRequest)
)
assert(canonical(atomicRequest) == atomicRequestSnapshot, "atomic interaction mutated its request")
assert(atomicRegister.applied == true and atomicRegister.stale == false
    and atomicRegister.changed == true and atomicRegister.interactionAction == "register",
    "atomic register did not return its transition receipt")
assertIds("atomic register selection", atomicRegister.draft.registeredCardInstanceIds, { BASE_A })
assert(type(atomicRegister.interactionToken) == "string"
    and atomicRegister.interactionToken ~= emptyInteractionToken,
    "atomic register did not rotate its interaction token")

local staleAtomicRegister = assertOk(
    "stale atomic register",
    invoke("stale atomic register", "applyInteraction", baseState, atomicRegister.draft, atomicRequest)
)
assert(staleAtomicRegister.applied == false and staleAtomicRegister.stale == true
    and staleAtomicRegister.changed == false,
    "stale atomic interaction applied a second transition")
assert(canonical(staleAtomicRegister.draft) == canonical(atomicRegister.draft)
    and staleAtomicRegister.interactionToken == atomicRegister.interactionToken,
    "stale atomic interaction did not return the current validated draft")

local atomicCancel = assertOk(
    "atomic cancel",
    invoke("atomic cancel", "applyInteraction", baseState, atomicRegister.draft, {
        action = "cancel",
        instanceId = BASE_A,
        expectedInteractionToken = atomicRegister.interactionToken,
    })
)
assert(atomicCancel.applied == true and atomicCancel.stale == false
    and atomicCancel.interactionAction == "cancel")
assertIds("atomic cancel selection", atomicCancel.draft.registeredCardInstanceIds, {})
assertHasError(
    "atomic interaction rejects unknown fields",
    invoke("atomic interaction rejects unknown fields", "applyInteraction", baseState, emptyDraft, {
        action = "register",
        instanceId = BASE_A,
        expectedInteractionToken = emptyInteractionToken,
        trusted = true,
    }),
    "unexpected_field"
)

local zeroSeedState = standardState()
zeroSeedState.rng.seed = 0
assertState("zero-seed authority state", zeroSeedState)
local zeroSeedDraft = draftAction("zero-seed new draft", "newDraft", zeroSeedState, nil, nil)
draftAction("zero-seed validate draft", "validate", zeroSeedState, zeroSeedDraft, nil)
local zeroSeedProjection = project("zero-seed pass projection", zeroSeedState, zeroSeedDraft)
local zeroSeedReceipt = assertOk(
    "zero-seed seal projection",
    invoke("zero-seed seal projection", "sealProjection", zeroSeedState, zeroSeedProjection, nil)
).receipt
assert(zeroSeedReceipt.projectedRng.seed == 0)
assertOk(
    "zero-seed replay receipt",
    invoke("zero-seed replay receipt", "validateProjectionReceipt", zeroSeedState, zeroSeedReceipt, nil)
)

-- Focus only opens details. It never registers or speculatively draws.
local focusedBase = draftAction("focus base", "focusCard", baseState, emptyDraft, BASE_A)
assert(focusedBase.focusedInstanceId == BASE_A)
assertIds("focus base registration", focusedBase.registeredCardInstanceIds, {})
assertEmptyPreview("focus base", focusedBase.preview)
local focusedInteractionToken = assertOk(
    "focused draft interaction token",
    invoke("focused draft interaction token", "interactionToken", baseState, focusedBase, nil)
).interactionToken
assert(focusedInteractionToken ~= emptyInteractionToken, "changed draft reused the previous interaction token")

local focusedEye = draftAction("focus eye", "focusCard", baseState, emptyDraft, EYE)
assert(focusedEye.focusedInstanceId == EYE)
assertIds("focus eye registration", focusedEye.registeredCardInstanceIds, {})
assertEmptyPreview("focus eye", focusedEye.preview)
assert(focusedEye.preview.rng.cursor == baseState.rng.cursor, "focus consumed projected RNG")

-- clickCard is the actual two-step UX: focus, register, then cancel when clicked again.
local clickBaseFocus = draftAction("click base focus", "clickCard", baseState, emptyDraft, BASE_A)
assert(clickBaseFocus.focusedInstanceId == BASE_A)
assertIds("click base focus registration", clickBaseFocus.registeredCardInstanceIds, {})
local clickBaseRegister = draftAction("click base register", "clickCard", baseState, clickBaseFocus, BASE_A)
assertIds("click base registered", clickBaseRegister.registeredCardInstanceIds, { BASE_A })
local clickBaseCancel = draftAction("click base cancel", "clickCard", baseState, clickBaseRegister, BASE_A)
assertIds("click base cancelled", clickBaseCancel.registeredCardInstanceIds, {})

local clickEyeFocus = draftAction("click eye focus", "clickCard", baseState, emptyDraft, EYE)
assertEmptyPreview("first eye click", clickEyeFocus.preview)
local clickEyeRegister = draftAction("click eye register", "clickCard", baseState, clickEyeFocus, EYE)
assertIds("click eye registered", clickEyeRegister.registeredCardInstanceIds, { EYE })
assertPreview("click eye", clickEyeRegister.preview, { PREVIEW_MAIN })
local clickEyeCancel = draftAction("click eye cancel", "clickCard", baseState, clickEyeRegister, EYE)
assertIds("click eye cancelled", clickEyeCancel.registeredCardInstanceIds, {})
assertEmptyPreview("click eye cancelled", clickEyeCancel.preview)

-- One base main is allowed. Re-registering is idempotent and a new base replaces it.
local baseA = draftAction("register base A", "registerCard", baseState, emptyDraft, BASE_A)
assertIds("base A", baseA.registeredCardInstanceIds, { BASE_A })
local baseAAgain = draftAction("re-register base A", "registerCard", baseState, baseA, BASE_A)
assertIds("base A idempotent", baseAAgain.registeredCardInstanceIds, { BASE_A })
local baseB = draftAction("replace base A with B", "registerCard", baseState, baseA, BASE_B)
assertIds("base main replacement", baseB.registeredCardInstanceIds, { BASE_B })
assertEmptyPreview("base main replacement", baseB.preview)

-- Registering eye evaluates one deterministic, public preview without changing authority.
local eyeOnly = draftAction("register eye", "registerCard", baseState, emptyDraft, EYE)
assertIds("eye only registration", eyeOnly.registeredCardInstanceIds, { EYE })
assertPreview("eye only", eyeOnly.preview, { PREVIEW_MAIN })
assert(#eyeOnly.preview.events > 0, "eye preview did not retain its public effect event")
assert(eyeOnly.preview.rng.seed == baseState.rng.seed)
assert(eyeOnly.preview.rng.cursor == baseState.rng.cursor, "ordinary top-deck preview consumed RNG")
assert(canonical(baseState) == authoritySnapshot, "eye preview changed authority")

local eyeAgain = draftAction("re-register eye", "registerCard", baseState, eyeOnly, EYE)
assert(canonical(eyeAgain) == canonical(eyeOnly), "re-registering eye rerolled or changed the draft")

-- A preview card follows the same focus/register click behavior.
local previewFocused = draftAction("focus visible preview", "clickCard", baseState, eyeOnly, PREVIEW_MAIN)
assert(previewFocused.focusedInstanceId == PREVIEW_MAIN)
assertIds("preview focus registration", previewFocused.registeredCardInstanceIds, { EYE })
assertPreview("preview focus", previewFocused.preview, { PREVIEW_MAIN })
local eyePreviewByClick = draftAction(
    "register visible preview by click",
    "clickCard",
    baseState,
    previewFocused,
    PREVIEW_MAIN
)
assertIds("eye plus preview click", eyePreviewByClick.registeredCardInstanceIds, { EYE, PREVIEW_MAIN })
assertPreview("eye plus preview click", eyePreviewByClick.preview, { PREVIEW_MAIN })

-- eye+base converges regardless of which independent card was registered first.
local baseThenEye = draftAction("base then eye", "registerCard", baseState, baseA, EYE)
assertIds("base then eye order", baseThenEye.registeredCardInstanceIds, { EYE, BASE_A })
assertPreview("base then eye", baseThenEye.preview, { PREVIEW_MAIN })
local eyeThenBase = draftAction("eye then base", "registerCard", baseState, eyeOnly, BASE_A)
assertIds("eye then base order", eyeThenBase.registeredCardInstanceIds, { EYE, BASE_A })
assertPreview("eye then base", eyeThenBase.preview, { PREVIEW_MAIN })

local eyePreview = draftAction("eye then preview", "registerCard", baseState, eyeOnly, PREVIEW_MAIN)
assertIds("eye plus preview", eyePreview.registeredCardInstanceIds, { EYE, PREVIEW_MAIN })
assertPreview("eye plus preview", eyePreview.preview, { PREVIEW_MAIN })
local eyePreviewAgain = draftAction(
    "re-register preview",
    "registerCard",
    baseState,
    eyePreview,
    PREVIEW_MAIN
)
assert(canonical(eyePreviewAgain) == canonical(eyePreview), "re-registering preview changed the draft")

-- Focusing another base does not reset. Registering it from eye+preview resets the whole speculative branch.
local branchFocusedBase = draftAction("focus base from speculative branch", "focusCard", baseState, eyePreview, BASE_B)
assertIds("focus preserved speculative selection", branchFocusedBase.registeredCardInstanceIds, { EYE, PREVIEW_MAIN })
assertPreview("focus preserved speculative preview", branchFocusedBase.preview, { PREVIEW_MAIN })
local resetToBase = draftAction("reset speculative branch to base", "registerCard", baseState, eyePreview, BASE_B)
assertIds("speculative reset registration", resetToBase.registeredCardInstanceIds, { BASE_B })
assertEmptyPreview("speculative reset", resetToBase.preview)
assert(resetToBase.preview.rng.cursor == baseState.rng.cursor, "speculative reset retained projected RNG")

-- Replacing an independent base while eye remains does not reset eye or its preview.
local eyeBaseReplacement = draftAction("replace independent base", "registerCard", baseState, eyeThenBase, BASE_B)
assertIds("eye base replacement", eyeBaseReplacement.registeredCardInstanceIds, { EYE, BASE_B })
assertPreview("eye base replacement", eyeBaseReplacement.preview, { PREVIEW_MAIN })

-- Cancelling preview retains the visible branch; cancelling eye removes its dependants only.
local previewCancelled = draftAction("cancel preview", "cancelCard", baseState, eyePreview, PREVIEW_MAIN)
assertIds("preview cancellation registration", previewCancelled.registeredCardInstanceIds, { EYE })
assertPreview("preview cancellation visibility", previewCancelled.preview, { PREVIEW_MAIN })
local previewReselected = draftAction("reselect cancelled preview", "registerCard", baseState, previewCancelled, PREVIEW_MAIN)
assertIds("preview reselection", previewReselected.registeredCardInstanceIds, { EYE, PREVIEW_MAIN })
assert(canonical(previewReselected.preview) == canonical(eyePreview.preview), "preview reselection rerolled")

local eyeCancelledFromPreview = draftAction("cancel eye with preview main", "cancelCard", baseState, eyePreview, EYE)
assertIds("eye cancellation removed dependent preview", eyeCancelledFromPreview.registeredCardInstanceIds, {})
assertEmptyPreview("eye cancellation removed preview display", eyeCancelledFromPreview.preview)
local eyeReselectedAfterCancel = draftAction(
    "reselect eye after branch cancellation",
    "registerCard",
    baseState,
    eyeCancelledFromPreview,
    EYE
)
assertPreview("eye reselection after cancellation", eyeReselectedAfterCancel.preview, { PREVIEW_MAIN })
assert(canonical(eyeReselectedAfterCancel.preview) == canonical(eyeOnly.preview), "eye cancellation enabled a reroll")

local eyeCancelledFromBase = draftAction("cancel eye with independent base", "cancelCard", baseState, eyeThenBase, EYE)
assertIds("eye cancellation kept independent base", eyeCancelledFromBase.registeredCardInstanceIds, { BASE_A })
assertEmptyPreview("eye cancellation with base", eyeCancelledFromBase.preview)
local baseCancelledFromEye = draftAction("cancel independent base", "cancelCard", baseState, eyeThenBase, BASE_A)
assertIds("base cancellation kept eye", baseCancelledFromEye.registeredCardInstanceIds, { EYE })
assertPreview("base cancellation kept preview", baseCancelledFromEye.preview, { PREVIEW_MAIN })

-- Projection modes: no selection passes, eye-only draws then passes, and any main is an action.
local noSelectionProjection = project("project no selection pass", baseState, emptyDraft)
assert(noSelectionProjection.mode == "pass")
assertIds("no selection projection", noSelectionProjection.selectedCardInstanceIds, {})
assertEmptyPreview("no selection projection", noSelectionProjection.preview)
assert(noSelectionProjection.projectedRng.seed == baseState.rng.seed)
assert(noSelectionProjection.projectedRng.cursor == baseState.rng.cursor)
assert(canonical(noSelectionProjection.workingState) == canonical(baseState), "no-selection pass changed working state")
assertConserved("no-selection conservation", baseState, noSelectionProjection.workingState)
assertState("no-selection projected state", noSelectionProjection.workingState)
validateProjectedTurn("validate no-selection pass projection", baseState, noSelectionProjection)

local eyeOnlyProjection = project("project eye-only chain pass", baseState, eyeOnly)
assert(eyeOnlyProjection.mode == "chain_pass")
assertIds("eye-only projected selection", eyeOnlyProjection.selectedCardInstanceIds, { EYE })
assertPreview("eye-only projection", eyeOnlyProjection.preview, { PREVIEW_MAIN })
assert(eyeOnlyProjection.projectedRng.cursor == baseState.rng.cursor)
assert(findCard(eyeOnlyProjection.workingState, EYE).zone == "used", "eye was not moved to used before drawing")
assert(findCard(eyeOnlyProjection.workingState, PREVIEW_MAIN).zone == "hand", "preview was not drawn into hand")
assertConserved("eye-only projection conservation", baseState, eyeOnlyProjection.workingState)
validateProjectedTurn("validate eye-only chain-pass projection", baseState, eyeOnlyProjection)

local eyeCleanup = assertOk(
    "eye-only cleanup",
    runScript("turn-draft-check", "cardZones", "endTurnCleanup", eyeOnlyProjection.workingState)
)
assertConserved("eye-only cleanup conservation", baseState, eyeCleanup.state)
assertState("eye-only cleanup committed state", eyeCleanup.state)
assertIds(
    "eye-only cleanup discard order",
    zoneIds(eyeCleanup.state, "player", "discard"),
    { EYE, BASE_A, BASE_B, PREVIEW_MAIN }
)

local baseProjection = project("project base action", baseState, baseA)
assert(baseProjection.mode == "action")
assertIds("base projected selection", baseProjection.selectedCardInstanceIds, { BASE_A })
assertEmptyPreview("base projection", baseProjection.preview)
assertConserved("base projection conservation", baseState, baseProjection.workingState)
validateProjectedTurn("validate base action projection", baseState, baseProjection)

local eyeBaseProjection = project("project eye plus base", baseState, eyeThenBase)
assert(eyeBaseProjection.mode == "action")
assertIds("eye plus base projected selection", eyeBaseProjection.selectedCardInstanceIds, { EYE, BASE_A })
assertPreview("eye plus base projection", eyeBaseProjection.preview, { PREVIEW_MAIN })
assertConserved("eye plus base conservation", baseState, eyeBaseProjection.workingState)
validateProjectedTurn("validate eye plus base action projection", baseState, eyeBaseProjection)

local eyePreviewProjection = project("project eye plus preview", baseState, eyePreview)
assert(eyePreviewProjection.mode == "action")
assertIds("eye plus preview projected selection", eyePreviewProjection.selectedCardInstanceIds, { EYE, PREVIEW_MAIN })
assertPreview("eye plus preview projection", eyePreviewProjection.preview, { PREVIEW_MAIN })
assertConserved("eye plus preview conservation", baseState, eyePreviewProjection.workingState)
validateProjectedTurn("validate eye plus preview action projection", baseState, eyePreviewProjection)

-- A persisted projection receipt keeps only the replay inputs and derived RNG
-- boundary. Preview cards are proven by replay instead of storing workingState.
local sealedPreview = assertOk(
    "seal eye plus preview projection",
    invoke("seal eye plus preview projection", "sealProjection", baseState, eyePreviewProjection, nil)
)
local previewReceipt = sealedPreview.receipt
assert(type(previewReceipt) == "table" and previewReceipt.kind == "turnDraftProjectionReceipt")
assert(previewReceipt.mode == "action")
assertIds("sealed preview selection", previewReceipt.selectedCardInstanceIds, { EYE, PREVIEW_MAIN })
assert(previewReceipt.preview == nil and previewReceipt.workingState == nil
    and previewReceipt.focusedInstanceId == nil, "projection receipt retained non-minimal state")
assert(previewReceipt.source ~= sealedPreview.projection.source
    and previewReceipt.projectedRng ~= sealedPreview.projection.projectedRng,
    "projection receipt aliases the returned projection")

local replayedReceipt = assertOk(
    "validate eye plus preview receipt",
    invoke("validate eye plus preview receipt", "validateProjectionReceipt", baseState, previewReceipt, nil)
)
assert(canonical(replayedReceipt.receipt) == canonical(previewReceipt), "valid receipt changed during replay")
assert(canonical(replayedReceipt.projection) == canonical(eyePreviewProjection), "receipt did not rebuild full projection")
assert(findCard(replayedReceipt.projection.workingState, PREVIEW_MAIN).zone == "used",
    "receipt replay did not prove the preview-only selected card")
local receiptSnapshot = canonical(previewReceipt)
replayedReceipt.receipt.selectedCardInstanceIds[1] = BASE_B
replayedReceipt.projection.preview.drawnInstanceIds[1] = BASE_B
assert(canonical(previewReceipt) == receiptSnapshot, "receipt replay returned aliases into its input")

local receiptExtra = clone(previewReceipt)
receiptExtra.preview = clone(eyePreviewProjection.preview)
assertHasError(
    "projection receipt rejects preview payload",
    invoke("projection receipt rejects preview payload", "validateProjectionReceipt", baseState, receiptExtra, nil),
    "unexpected_field"
)
local receiptWorking = clone(previewReceipt)
receiptWorking.workingState = clone(eyePreviewProjection.workingState)
assertHasError(
    "projection receipt rejects working state",
    invoke("projection receipt rejects working state", "validateProjectionReceipt", baseState, receiptWorking, nil),
    "unexpected_field"
)
local receiptModeTamper = clone(previewReceipt)
receiptModeTamper.mode = "chain_pass"
assertHasError(
    "projection receipt mode tamper",
    invoke("projection receipt mode tamper", "validateProjectionReceipt", baseState, receiptModeTamper, nil),
    "projection_receipt_mismatch"
)
local receiptRngTamper = clone(previewReceipt)
receiptRngTamper.projectedRng.cursor = receiptRngTamper.projectedRng.cursor + 1
assertHasError(
    "projection receipt rng tamper",
    invoke("projection receipt rng tamper", "validateProjectionReceipt", baseState, receiptRngTamper, nil),
    "projection_receipt_mismatch"
)
local receiptSourceTamper = clone(previewReceipt)
receiptSourceTamper.source.fingerprint.hashA = receiptSourceTamper.source.fingerprint.hashA + 1
assertHasError(
    "projection receipt source tamper",
    invoke("projection receipt source tamper", "validateProjectionReceipt", baseState, receiptSourceTamper, nil),
    "projection_receipt_stale"
)

local resetProjection = project("project reset base", baseState, resetToBase)
assert(resetProjection.mode == "action")
assertIds("reset base projected selection", resetProjection.selectedCardInstanceIds, { BASE_B })
assertEmptyPreview("reset base projection", resetProjection.preview)
assert(resetProjection.projectedRng.cursor == baseState.rng.cursor)
validateProjectedTurn("validate reset action projection", baseState, resetProjection)

-- A projection is an untrusted commit request. Validation replays only its selected
-- IDs and rejects every caller-supplied derived field that differs from that replay.
local zoneTamperedProjection = clone(baseProjection)
local zoneTamperedCard = assert(findCard(zoneTamperedProjection.workingState, BASE_A))
zoneTamperedCard.zone = "removed"
zoneTamperedCard.position = 1
assertProjectionRejected(
    "working-state zone tamper rejection",
    baseState,
    zoneTamperedProjection,
    "projection_mismatch"
)

local rngTamperedProjection = clone(eyeOnlyProjection)
rngTamperedProjection.workingState.rng.cursor = rngTamperedProjection.workingState.rng.cursor + 1
assertProjectionRejected(
    "working-state rng tamper rejection",
    baseState,
    rngTamperedProjection,
    "projection_mismatch"
)

local selectionTamperedProjection = clone(baseProjection)
selectionTamperedProjection.workingState.selection.playerCardInstanceIds = { BASE_B }
assertProjectionRejected(
    "working-state selection tamper rejection",
    baseState,
    selectionTamperedProjection,
    "projection_mismatch"
)

local projectedRngTamperedProjection = clone(eyeOnlyProjection)
projectedRngTamperedProjection.projectedRng.cursor = projectedRngTamperedProjection.projectedRng.cursor + 1
assertProjectionRejected(
    "projected rng tamper rejection",
    baseState,
    projectedRngTamperedProjection,
    "projection_mismatch"
)

local previewTamperedProjection = clone(eyeOnlyProjection)
previewTamperedProjection.preview.drawnInstanceIds[1] = BASE_B
previewTamperedProjection.preview.availableDrawnInstanceIds[1] = BASE_B
assertProjectionRejected(
    "projection preview tamper rejection",
    baseState,
    previewTamperedProjection,
    "projection_mismatch"
)

local selectedIdsTamperedProjection = clone(baseProjection)
selectedIdsTamperedProjection.selectedCardInstanceIds = { BASE_B }
assertProjectionRejected(
    "projection selected ids tamper rejection",
    baseState,
    selectedIdsTamperedProjection,
    "projection_mismatch"
)

local modeTamperedProjection = clone(baseProjection)
modeTamperedProjection.mode = "pass"
assertProjectionRejected(
    "projection mode tamper rejection",
    baseState,
    modeTamperedProjection,
    "projection_mismatch"
)

local mainFlagTamperedProjection = clone(baseProjection)
mainFlagTamperedProjection.hasMainAction = false
assertProjectionRejected(
    "projection main flag tamper rejection",
    baseState,
    mainFlagTamperedProjection,
    "projection_mismatch"
)

local passFlagTamperedProjection = clone(eyeOnlyProjection)
passFlagTamperedProjection.passAfterChain = false
assertProjectionRejected(
    "projection pass flag tamper rejection",
    baseState,
    passFlagTamperedProjection,
    "projection_mismatch"
)

local sourceTamperedProjection = clone(baseProjection)
sourceTamperedProjection.source.fingerprint = "tampered"
assertProjectionRejected(
    "projection source tamper rejection",
    baseState,
    sourceTamperedProjection,
    "projection_stale"
)

local unknownFieldProjection = clone(baseProjection)
unknownFieldProjection.untrustedExtra = true
assertProjectionRejected(
    "projection unknown field rejection",
    baseState,
    unknownFieldProjection,
    "unexpected_field"
)

-- At maximum hand size, eye leaves hand before its draw, so the preview fills exactly that one slot.
local maxHandState = makeState({
    makeCard(EYE, "read_the_room", "player", "hand", 1),
    makeCard(BASE_A, "accidental_brush", "player", "hand", 2),
    makeCard(BASE_B, "pin_down", "player", "hand", 3),
    makeCard("hand-four", "subtle_approach", "player", "hand", 4),
    makeCard("hand-five", "play_it_cool", "player", "hand", 5),
    makeCard(PREVIEW_MAIN, "hypnotic_whisper", "player", "deck", 1),
}, 42)
assertState("maximum-hand authority", maxHandState)
local maxHandDraft = draftAction("maximum-hand eye", "registerCard", maxHandState, draftAction(
    "maximum-hand new draft",
    "newDraft",
    maxHandState,
    nil,
    nil
), EYE)
assertPreview("maximum-hand preview", maxHandDraft.preview, { PREVIEW_MAIN })
local maxHandProjection = project("maximum-hand projection", maxHandState, maxHandDraft)
assert(#zoneIds(maxHandProjection.workingState, "player", "hand") == 5, "preview exceeded or failed to refill max hand")
assert(findCard(maxHandProjection.workingState, EYE).zone == "used")
assert(findCard(maxHandProjection.workingState, PREVIEW_MAIN).zone == "hand")
assertConserved("maximum-hand conservation", maxHandState, maxHandProjection.workingState)
validateProjectedTurn("validate maximum-hand chain-pass projection", maxHandState, maxHandProjection)

-- An empty deck reshuffles discard deterministically only in the draft branch.
local shuffleState = makeState({
    makeCard(EYE, "read_the_room", "player", "hand", 1),
    makeCard("discard-p1", "accidental_brush", "player", "discard", 1),
    makeCard("discard-p2", "pin_down", "player", "discard", 2),
    makeCard("discard-p3", "play_it_cool", "player", "discard", 3),
}, 42)
assertState("reshuffle authority", shuffleState)
local shuffleSnapshot = canonical(shuffleState)
local shuffleDraft = draftAction("reshuffle eye", "registerCard", shuffleState, draftAction(
    "reshuffle new draft",
    "newDraft",
    shuffleState,
    nil,
    nil
), EYE)
assertPreview("reshuffle preview", shuffleDraft.preview, { "discard-p2" })
assert(shuffleDraft.preview.rng.seed == 42 and shuffleDraft.preview.rng.cursor == 2)
assert(canonical(shuffleState) == shuffleSnapshot, "reshuffle preview mutated authority")
local shuffleAgain = draftAction("reshuffle eye idempotence", "registerCard", shuffleState, shuffleDraft, EYE)
assert(canonical(shuffleAgain) == canonical(shuffleDraft), "reshuffle eye consumed RNG twice")
local shuffleProjection = project("reshuffle projection", shuffleState, shuffleDraft)
assert(shuffleProjection.projectedRng.seed == 42 and shuffleProjection.projectedRng.cursor == 2)
assert(findCard(shuffleProjection.workingState, "discard-p2").zone == "hand")
assert(canonical(shuffleState) == shuffleSnapshot, "reshuffle projection mutated authority")
assertConserved("reshuffle projection conservation", shuffleState, shuffleProjection.workingState)
validateProjectedTurn("validate reshuffle chain-pass projection", shuffleState, shuffleProjection)

-- used, plan and removed are never candidates for a speculative draw.
local exclusionState = makeState({
    makeCard(EYE, "read_the_room", "player", "hand", 1),
    makeCard("discard-only", "play_it_cool", "player", "discard", 1),
    makeCard("used-decoy", "accidental_brush", "player", "used", 1),
    makeCard("plan-decoy", "subtle_approach", "player", "plan", 1),
    makeCard("removed-decoy", "hypnotic_whisper", "player", "removed", 1),
}, 17)
exclusionState.player.planSlot = {
    occupied = true,
    cardInstanceId = "plan-decoy",
    cardId = "subtle_approach",
    placedTurn = 1,
    remainingTurns = 1,
    remainingCharges = 1,
    revealed = false,
}
assertState("excluded-zone authority", exclusionState)
local exclusionDraft = draftAction("excluded-zone eye", "registerCard", exclusionState, draftAction(
    "excluded-zone new draft",
    "newDraft",
    exclusionState,
    nil,
    nil
), EYE)
assertPreview("excluded-zone preview", exclusionDraft.preview, { "discard-only" })
for _, forbiddenId in ipairs({ "used-decoy", "plan-decoy", "removed-decoy" }) do
    for _, drawnId in ipairs(exclusionDraft.preview.drawnInstanceIds) do
        assert(drawnId ~= forbiddenId, forbiddenId .. " leaked into preview draw")
    end
end

local emptySupplyState = clone(exclusionState)
for _, item in ipairs(emptySupplyState.cardInstances) do
    if item.instanceId == "discard-only" then
        item.zone = "removed"
        item.position = 2
    end
end
assertState("empty draw supply authority", emptySupplyState)
local emptySupplyDraft = draftAction("empty draw supply eye", "registerCard", emptySupplyState, draftAction(
    "empty draw supply new draft",
    "newDraft",
    emptySupplyState,
    nil,
    nil
), EYE)
assertPreview("empty draw supply", emptySupplyDraft.preview, {}, {})
assert(emptySupplyDraft.preview.rng.cursor == emptySupplyState.rng.cursor, "empty supply consumed RNG")
local emptySupplyProjection = project("empty supply chain pass", emptySupplyState, emptySupplyDraft)
assert(emptySupplyProjection.mode == "chain_pass")
assertIds("empty supply selected eye", emptySupplyProjection.selectedCardInstanceIds, { EYE })
assert(findCard(emptySupplyProjection.workingState, "used-decoy").zone == "used")
assert(findCard(emptySupplyProjection.workingState, "plan-decoy").zone == "plan")
assert(findCard(emptySupplyProjection.workingState, "removed-decoy").zone == "removed")
assertConserved("empty supply conservation", emptySupplyState, emptySupplyProjection.workingState)
validateProjectedTurn("validate empty-supply chain-pass projection", emptySupplyState, emptySupplyProjection)

-- A draft is anchored to an exact authoritative state and may not be silently rebased.
local function assertStale(label, changedState, draft)
    local report = invoke(label, "project", changedState, draft, nil)
    assertFailed(label, report)
end

local otherBattle = clone(baseState)
otherBattle.battleId = "battle-draft-other"
assertState("other battle fixture", otherBattle)
assertStale("battle id mismatch", otherBattle, eyeOnly)

local laterTurn = clone(baseState)
laterTurn.turnNumber = 2
assertState("later turn fixture", laterTurn)
assertStale("stale turn mismatch", laterTurn, eyeOnly)

local laterCommit = clone(baseState)
laterCommit.lastCommittedTurnId = "battle-draft-001-turn-001"
assertState("later commit fixture", laterCommit)
assertStale("last committed turn mismatch", laterCommit, eyeOnly)

local changedRng = clone(baseState)
changedRng.rng.cursor = 1
assertState("changed rng fixture", changedRng)
assertStale("stale rng mismatch", changedRng, eyeOnly)

local changedZones = clone(baseState)
findCard(changedZones, BASE_A).position = 3
findCard(changedZones, BASE_B).position = 2
assertState("changed card ordering fixture", changedZones)
assertStale("stale card zone fingerprint", changedZones, eyeOnly)

local staleValidation = invoke("validate stale draft", "validate", changedRng, eyeOnly, nil)
assertFailed("validate stale draft", staleValidation)

local duplicateSelection = clone(eyeOnly)
duplicateSelection.registeredCardInstanceIds = { EYE, EYE }
assertFailed(
    "duplicate draft registration",
    invoke("duplicate draft registration", "validate", baseState, duplicateSelection, nil)
)

local tamperedPreview = clone(eyeOnly)
tamperedPreview.preview.drawnInstanceIds[1] = BASE_B
tamperedPreview.preview.availableDrawnInstanceIds[1] = BASE_B
assertFailed(
    "tampered preview projection",
    invoke("tampered preview projection", "project", baseState, tamperedPreview, nil)
)

-- Referencing a non-visible deck card before eye registration is rejected atomically.
assertFailed(
    "register hidden deck card",
    invoke("register hidden deck card", "registerCard", baseState, emptyDraft, PREVIEW_MAIN)
)

assert(canonical(baseState) == authoritySnapshot, "turn draft test suite changed its shared authority fixture")

print(
    "VECTOR"
        .. "|eye=" .. table.concat(eyeOnly.preview.drawnInstanceIds, ",")
        .. "|eye-rng=" .. tostring(eyeOnly.preview.rng.cursor)
        .. "|eye-base=" .. table.concat(eyeThenBase.registeredCardInstanceIds, ",")
        .. "|eye-preview=" .. table.concat(eyePreview.registeredCardInstanceIds, ",")
        .. "|reset=" .. table.concat(resetToBase.registeredCardInstanceIds, ",")
        .. "|shuffle=" .. table.concat(shuffleDraft.preview.drawnInstanceIds, ",")
        .. "|shuffle-rng=" .. tostring(shuffleDraft.preview.rng.cursor)
        .. "|no-selection=" .. noSelectionProjection.mode
        .. "|eye-only=" .. eyeOnlyProjection.mode
        .. "|cleanup=" .. table.concat(zoneIds(eyeCleanup.state, "player", "discard"), ",")
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[turn-draft-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua turnDraft 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua turnDraft 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 turnDraft 결과를 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if (-not $firstText.StartsWith('VECTOR|eye=preview-main|eye-rng=0|eye-base=eye,base-a|eye-preview=eye,preview-main|reset=base-b|shuffle=discard-p2|shuffle-rng=2|no-selection=pass|eye-only=chain_pass|')) {
        throw "turnDraft 결정성 표식이 예상과 다릅니다: $firstText"
    }

    Write-Output 'turn-draft-check: ok'
    Write-Output 'NOTE: 실제 RisuAI 로어북 및 UI 통합 환경에서는 아직 검증하지 않았습니다.'
}
finally {
    Pop-Location
}
