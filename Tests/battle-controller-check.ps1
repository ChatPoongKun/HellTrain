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
    deterministicRng = loadLore("System/deterministicRng.lua"),
    cardZones = loadLore("System/cardZones.lua"),
    effectEngine = loadLore("System/effectEngine.lua"),
    staticData = loadLore("System/staticData.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
    triggerPipeline = loadLore("System/triggerPipeline.lua"),
    characterSelector = loadLore("System/characterSelector.lua"),
    turnInitializer = loadLore("System/turnInitializer.lua"),
    turnDraft = loadLore("System/turnDraft.lua"),
    turnResolver = loadLore("System/turnResolver.lua"),
    turnEventProjector = loadLore("System/turnEventProjector.lua"),
    battleRuntime = loadLore("System/battleRuntime.lua"),
    turnPresentation = loadLore("System/turnPresentation.lua"),
    viewBuilder = loadLore("System/viewBuilder.lua"),
    dataBridge = loadLore("System/dataBridge.lua"),
    battleBootstrap = loadLore("System/battleBootstrap.lua"),
    turnPromptFormatter = loadLore("System/turnPromptFormatter.lua"),
    battleController = loadLore("System/battleController.lua"),
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
    if not path then return {} end
    return { { content = readFile(path) } }
end

local function clone(value, active)
    if type(value) ~= "table" then return value end
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
        for index = 1, maximum do parts[index] = canonical(value[index], active) end
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
        messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path) .. ": " .. tostring(item.message)
    end
    error(label .. " failed | " .. table.concat(messages, " | "))
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then failReport(label, report) end
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    return report
end

local function assertFails(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.schemaVersion == 1 and type(report.errors) == "table" and #report.errors > 0,
        label .. " must return a strict error envelope")
    for _, item in ipairs(report.errors) do
        assert(type(item.code) == "string" and type(item.path) == "string" and type(item.message) == "string",
            label .. " returned a malformed error")
        if item.code == expectedCode then return report end
    end
    failReport(label .. " (missing " .. tostring(expectedCode) .. ")", report)
end

local AUTHORITY = "battleRuntimeV1.authority"
local DRAFT = "battleRuntimeV1.draft"
local PENDING = "battleRuntimeV1.pending"
local LAST = "battleRuntimeV1.lastCommittedPending"
local ACTIVE = "battleRuntimeV1.activeRequest"

local states = {}
local stateWriteCount = 0
local failNextStateWrite
local failStateWriteOnOccurrence
function setState(triggerId, key, value)
    stateWriteCount = stateWriteCount + 1
    if failNextStateWrite == key then
        failNextStateWrite = nil
        return
    end
    if type(failStateWriteOnOccurrence) == "table"
        and failStateWriteOnOccurrence.key == key then
        failStateWriteOnOccurrence.remaining = failStateWriteOnOccurrence.remaining - 1
        if failStateWriteOnOccurrence.remaining == 0 then
            failStateWriteOnOccurrence = nil
            return
        end
    end
    states[key] = clone(value)
end
function getState(triggerId, key)
    return clone(states[key])
end

local chatVars = {}
local failNextChatVarWrite
function setChatVar(triggerId, key, value)
    if failNextChatVarWrite == key then
        failNextChatVarWrite = nil
        return
    end
    chatVars[key] = value
end
function getChatVar(triggerId, key)
    return chatVars[key]
end
local reloadDisplayCount = 0
function reloadDisplay(triggerId)
    reloadDisplayCount = reloadDisplayCount + 1
end

local chat = {
    { role = "char", data = "intro", time = 1 },
}
function getFullChat(triggerId)
    return clone(chat)
end
local failRemoveChatOnOccurrence
function removeChat(triggerId, zeroBasedIndex)
    assert(type(zeroBasedIndex) == "number" and zeroBasedIndex % 1 == 0, "removeChat index must be integer")
    if type(failRemoveChatOnOccurrence) == "number" then
        failRemoveChatOnOccurrence = failRemoveChatOnOccurrence - 1
        if failRemoveChatOnOccurrence == 0 then
            failRemoveChatOnOccurrence = nil
            error("injected removeChat failure")
        end
    end
    table.remove(chat, zeroBasedIndex + 1)
end
local failNextAddChat = false
function addChat(triggerId, role, value)
    if failNextAddChat then
        failNextAddChat = false
        return
    end
    chat[#chat + 1] = { role = role, data = value, time = #chat + 1 }
end

local function appendChat(role, value)
    chat[#chat + 1] = { role = role, data = value, time = #chat + 1 }
end

local function markerCount(marker)
    local count = 0
    for _, message in ipairs(chat) do
        if message.role == "user" and message.data == marker then
            count = count + 1
        end
    end
    return count
end

local function sayNothingCount()
    local count = 0
    for _, message in ipairs(chat) do
        if message.role == "user" and message.data == "*says nothing*" then
            count = count + 1
        end
    end
    return count
end

local function controller(action, ...)
    return modules.battleController("battle-controller-check", action, ...)
end

local start = assertOk("start vertical slice", controller("startVerticalSlice", "controller-battle", 731))
assert(start.battleId == "controller-battle" and start.turnId == "controller-battle-turn-001")
assert(start.turnNumber == 1 and start.view.phase == "selecting")
assert(states[AUTHORITY].turnNumber == 1 and type(states[AUTHORITY].turnStartReceipt) == "table")
assert(type(states[DRAFT]) == "table" and states[PENDING] == nil and states[LAST] == nil and states[ACTIVE] == nil)
assert(type(chatVars.battleView) == "string" and chatVars.battleView ~= "", "initial view was not published")
assert(reloadDisplayCount == 1, "initial view did not reload the display")

local reloadsBeforeExplicitPublish = reloadDisplayCount
local published = assertOk("publish current view", controller("publishCurrentView"))
assert(published.view.phase == "selecting" and published.bytes > 0)
assert(reloadDisplayCount == reloadsBeforeExplicitPublish + 1,
    "verified explicit publication did not reload the display")

local instanceId = assert(start.view.hand.items[1].instanceId)
local initialInteractionToken = start.view.interactionToken
assert(type(initialInteractionToken) == "string" and initialInteractionToken ~= "",
    "selecting View did not expose an interaction token")
local reloadsBeforeFailedClick = reloadDisplayCount
failNextChatVarWrite = "battleView"
assertFails("focus publish failure", controller("clickCard", instanceId, initialInteractionToken),
    "view_write_not_persisted")
assert(states[DRAFT].focusedInstanceId == instanceId, "failed focus publication did not persist the click transition")
assert(reloadDisplayCount == reloadsBeforeFailedClick, "failed focus publication reloaded the display")

local firstClick = assertOk("recover stale focus click",
    controller("clickCard", instanceId, initialInteractionToken))
assert(firstClick.applied == false and firstClick.stale == true
    and firstClick.draft.focusedInstanceId == instanceId,
    "stale click recovery applied the focus transition twice")
assert(type(firstClick.interactionToken) == "string"
    and firstClick.interactionToken == firstClick.view.interactionToken
    and firstClick.interactionToken ~= initialInteractionToken,
    "stale click recovery did not return the current interaction token")

local secondClick = assertOk("register card",
    controller("clickCard", instanceId, firstClick.interactionToken))
assert(secondClick.applied == true and secondClick.stale == false)
assert(#secondClick.draft.registeredCardInstanceIds == 1
    and secondClick.draft.registeredCardInstanceIds[1] == instanceId)
assert(type(secondClick.interactionToken) == "string"
    and secondClick.interactionToken == secondClick.view.interactionToken
    and secondClick.interactionToken ~= firstClick.interactionToken,
    "applied click did not rotate the interaction token")

appendChat("user", "*says nothing*")
appendChat("char", "historical empty-send response")
appendChat("user", "*says nothing*")
local preparePendingCalls = moduleCalls.battleRuntime or 0
failNextStateWrite = ACTIVE
assertFails("dropped binding write", controller("prepareGeneration"), "state_write_not_persisted")
assert(chat[#chat].role == "user" and chat[#chat].data == "*says nothing*",
    "failed state persistence changed the chat before recovery")
assert(type(states[PENDING]) == "table" and states[DRAFT] == nil and states[ACTIVE] == nil,
    "partial state write did not leave a reusable pending boundary")
local preparePendingCallsAfterFailure = moduleCalls.battleRuntime or 0
assert(preparePendingCallsAfterFailure > preparePendingCalls, "first prepare did not reach battleRuntime")

appendChat("user", "*says nothing*")
local prepared = assertOk("recover generation", controller("prepareGeneration"))
assert(prepared.source == "pending" and prepared.reused == true)
assert(prepared.removedSayNothing == true and prepared.removedSayNothingCount == 2
    and prepared.markerAdded == true)
assert(states[PENDING].turnId == "controller-battle-turn-001" and states[DRAFT] == nil)
assert(states[ACTIVE].source == "pending" and states[ACTIVE].phase == "inFlight"
    and states[ACTIVE].turnId == states[PENDING].turnId)
assert(chat[#chat].role == "user" and chat[#chat].data == prepared.publicMarker)
assert(prepared.publicMarker == states[ACTIVE].publicMarker
    and string.find(prepared.publicMarker, "1", 1, true),
    "prepared marker was not the persisted turn-one marker")
local firstMarker = prepared.publicMarker
assert(markerCount(firstMarker) == 1, "generation recovery duplicated the public marker")
assert(sayNothingCount() == 1, "trailing cleanup removed a historical exact filler or left a trailing filler")
assert(moduleCalls.battleRuntime > preparePendingCallsAfterFailure, "generation recovery did not validate/reuse pending")

local basePrompt = {
    { role = "system", content = "preset-system" },
    { role = "user", content = "normal-context" },
}
local basePromptSnapshot = canonical(basePrompt)
local authorityBeforeInjection = canonical(states[AUTHORITY])
local pendingBeforeInjection = canonical(states[PENDING])
local writesBeforeUninjectedCommit = stateWriteCount
assertFails("commit before request injection", controller("commitOutput"), "request_not_committable")
assert(stateWriteCount == writesBeforeUninjectedCommit
    and canonical(states[AUTHORITY]) == authorityBeforeInjection
    and canonical(states[PENDING]) == pendingBeforeInjection
    and states[ACTIVE].phase == "inFlight",
    "uninjected commit changed authority, pending, or the active request")

failNextStateWrite = ACTIVE
assertFails("dropped request injection receipt", controller("injectRequest", basePrompt),
    "state_write_not_persisted")
assert(canonical(basePrompt) == basePromptSnapshot, "failed injectRequest mutated its input")
assert(canonical(states[AUTHORITY]) == authorityBeforeInjection
    and canonical(states[PENDING]) == pendingBeforeInjection
    and states[ACTIVE].phase == "inFlight",
    "failed request receipt changed authority, pending, or request phase")
local writesAfterDroppedReceipt = stateWriteCount
assertFails("commit after dropped request receipt", controller("commitOutput"),
    "request_not_committable")
assert(stateWriteCount == writesAfterDroppedReceipt
    and canonical(states[AUTHORITY]) == authorityBeforeInjection
    and canonical(states[PENDING]) == pendingBeforeInjection
    and states[ACTIVE].phase == "inFlight",
    "onOutput after a failed editRequest receipt changed battle authority")

local writesBeforeInject = stateWriteCount
local injected = assertOk("inject request", controller("injectRequest", basePrompt))
assert(canonical(basePrompt) == basePromptSnapshot, "injectRequest mutated its input")
assert(#injected.promptArray == #basePrompt + 1 and injected.injected == true)
assert(injected.requestPhase == "requestInjected" and states[ACTIVE].phase == "requestInjected",
    "injectRequest did not persist its requestInjected receipt")
assert(injected.promptArray[1].content == "preset-system" and injected.promptArray[2].content == "normal-context")
assert(injected.promptArray[3].role == "system"
    and injected.promptArray[3].content ~= ""
    and canonical(injected.promptArray[3]) == canonical(states[ACTIVE].message),
    "formatter message was not appended")
assert(stateWriteCount == writesBeforeInject + 1,
    "first injectRequest did not write exactly one persistent receipt")

local injectedSnapshot = canonical(injected.promptArray)
local writesBeforeReinject = stateWriteCount
local reinjected = assertOk("idempotent inject request", controller("injectRequest", injected.promptArray))
assert(reinjected.injected == false and canonical(reinjected.promptArray) == injectedSnapshot,
    "injectRequest duplicated its system message")
assert(canonical(injected.promptArray) == injectedSnapshot, "idempotent injection mutated its input")
assert(reinjected.requestPhase == "requestInjected" and stateWriteCount == writesBeforeReinject,
    "idempotent injectRequest rewrote its persistent receipt")

local duplicatedPrompt = clone(injected.promptArray)
duplicatedPrompt[#duplicatedPrompt + 1] = clone(states[ACTIVE].message)
local deduplicated = assertOk("deduplicate private event prompt",
    controller("injectRequest", duplicatedPrompt))
assert(deduplicated.injected == false and deduplicated.deduplicated == true
    and canonical(deduplicated.promptArray) == injectedSnapshot,
    "duplicate private events were not collapsed to the first exact message")
assert(states[ACTIVE].phase == "requestInjected" and stateWriteCount == writesBeforeReinject,
    "duplicate prompt normalization rewrote the injection receipt")

local firstZeroRetryAttempt = states[ACTIVE].attemptNumber
local firstZeroRetryBinding = canonical(states[ACTIVE])
local firstZeroRetryPending = canonical(states[PENDING])
local firstZeroRetryChat = canonical(chat)
failNextStateWrite = ACTIVE
assertFails("dropped zero-output retry receipt", controller("prepareGeneration"),
    "state_write_not_persisted")
assert(canonical(states[ACTIVE]) == firstZeroRetryBinding
    and canonical(states[PENDING]) == firstZeroRetryPending
    and canonical(chat) == firstZeroRetryChat,
    "failed zero-output retry consumed an attempt or changed chat/pending state")

local firstZeroRetry = assertOk("retry zero-output request after injection",
    controller("prepareGeneration"))
assert(firstZeroRetry.generationReady == true
    and firstZeroRetry.recoveredAbandonedRequest == true
    and firstZeroRetry.zeroOutputRetry == true
    and firstZeroRetry.attemptNumber == firstZeroRetryAttempt + 1
    and firstZeroRetry.removedSayNothing == false
    and firstZeroRetry.removedSayNothingCount == 0
    and firstZeroRetry.removedUncommittedOutput == false
    and firstZeroRetry.markerAdded == false,
    "marker-only request was not resumed as a zero-output retry")
assert(states[ACTIVE].phase == "inFlight"
    and canonical(states[PENDING]) == firstZeroRetryPending
    and canonical(chat) == firstZeroRetryChat
    and chat[#chat].data == firstMarker and markerCount(firstMarker) == 1,
    "zero-output retry changed its pending turn, chat anchor, or public marker")

local reinjectedAfterZeroRetry = assertOk("inject zero-output retry",
    controller("injectRequest", basePrompt))
assert(reinjectedAfterZeroRetry.requestPhase == "requestInjected"
    and states[ACTIVE].attemptNumber == firstZeroRetryAttempt + 1
    and canonical(reinjectedAfterZeroRetry.promptArray[#reinjectedAfterZeroRetry.promptArray])
        == canonical(states[ACTIVE].message),
    "zero-output retry did not reuse and reinject the original private event")

local writesBeforeMissingOutputCommit = stateWriteCount
assertFails("commit without character output", controller("commitOutput"),
    "observed_output_missing")
assert(stateWriteCount == writesBeforeMissingOutputCommit
    and states[ACTIVE].phase == "requestInjected"
    and states[ACTIVE].outputObserved == nil,
    "missing output created an observation receipt or changed request state")

local firstPendingBeforeRecovery = canonical(states[PENDING])
local firstAttempt = states[ACTIVE].attemptNumber
local partialScene = "discarded partial scene"
appendChat("char", partialScene)
local partialSceneIndex = #chat
appendChat("user", "*says nothing*")
local activeBeforeAnchorTamper = canonical(states[ACTIVE])
local writesBeforeAnchorTamper = stateWriteCount
chat[1].data = "tampered intro"
assertFails("reject tampered recovery anchor", controller("prepareGeneration"),
    "chat_anchor_prefix_mismatch")
assert(stateWriteCount == writesBeforeAnchorTamper
    and canonical(states[ACTIVE]) == activeBeforeAnchorTamper
    and #chat == partialSceneIndex + 1
    and chat[#chat].role == "user" and chat[#chat].data == "*says nothing*",
    "anchor tamper rejection wrote state or deleted a message")
chat[1].data = "intro"

failRemoveChatOnOccurrence = 2
assertFails("interrupted unobserved output cleanup", controller("prepareGeneration"),
    "recovery_response_remove_failed")
assert(failRemoveChatOnOccurrence == nil,
    "removeChat failure injection was not consumed")
assert(chat[#chat].role == "char" and chat[#chat].data == partialScene
    and #chat == partialSceneIndex,
    "interrupted cleanup did not remove only the trailing filler")
assert(states[ACTIVE].phase == "requestInjected"
    and states[ACTIVE].attemptNumber == firstAttempt
    and states[ACTIVE].outputObserved == nil
    and type(states[ACTIVE].recoveringCleanup) == "table"
    and states[ACTIVE].recoveringCleanup.mode == "retry"
    and states[ACTIVE].recoveringCleanup.responsePresent == true
    and states[ACTIVE].recoveringCleanup.responseIndex == partialSceneIndex - 1,
    "interrupted cleanup did not retain its retry receipt")
assert(canonical(states[PENDING]) == firstPendingBeforeRecovery,
    "interrupted cleanup changed the pending turn")

local cleanupReceiptSnapshot = canonical(states[ACTIVE])
chat[partialSceneIndex].data = "tampered partial scene"
assertFails("reject tampered cleanup response", controller("prepareGeneration"),
    "cleanup_response_mismatch")
assert(canonical(states[ACTIVE]) == cleanupReceiptSnapshot
    and #chat == partialSceneIndex
    and chat[partialSceneIndex].data == "tampered partial scene",
    "tamper rejection changed the cleanup receipt or deleted a message")
chat[partialSceneIndex].data = partialScene

local resumedRetry = assertOk("resume interrupted output cleanup",
    controller("prepareGeneration"))
assert(resumedRetry.generationReady == true
    and resumedRetry.recoveredAbandonedRequest == true
    and resumedRetry.removedUncommittedOutput == true
    and resumedRetry.removedSayNothingCount == 0
    and resumedRetry.attemptNumber == firstAttempt + 1,
    "interrupted cleanup did not resume as the same-turn retry")
assert(chat[#chat].role == "user" and chat[#chat].data == firstMarker
    and canonical(states[PENDING]) == firstPendingBeforeRecovery
    and states[ACTIVE].phase == "inFlight"
    and states[ACTIVE].recoveringCleanup == nil,
    "resumed cleanup did not leave one marker and the original pending turn")

local recoveredInjected = assertOk("inject recovered request",
    controller("injectRequest", basePrompt))
assert(recoveredInjected.requestPhase == "requestInjected"
    and canonical(recoveredInjected.promptArray[#recoveredInjected.promptArray])
        == canonical(states[ACTIVE].message)
    and states[ACTIVE].attemptNumber == firstAttempt + 1,
    "recovered attempt did not reuse the same private event")

appendChat("char", "second discarded partial scene")
appendChat("user", "*says nothing*")
local automaticRetry = assertOk("delete unobserved output and retry",
    controller("prepareGeneration"))
assert(automaticRetry.generationReady == true
    and automaticRetry.recoveredAbandonedRequest == true
    and automaticRetry.removedUncommittedOutput == true
    and automaticRetry.removedSayNothing == true
    and automaticRetry.removedSayNothingCount == 1
    and automaticRetry.attemptNumber == firstAttempt + 2,
    "unobserved response was not atomically cleaned for retry")
assert(chat[#chat].role == "user" and chat[#chat].data == firstMarker
    and markerCount(firstMarker) == 1
    and canonical(states[PENDING]) == firstPendingBeforeRecovery
    and states[ACTIVE].phase == "inFlight",
    "automatic retry changed the marker or pending turn")

local finalFirstInjected = assertOk("inject final first-turn retry",
    controller("injectRequest", basePrompt))
assert(finalFirstInjected.requestPhase == "requestInjected"
    and states[ACTIVE].attemptNumber == firstAttempt + 2,
    "final retry was not bound to the incremented attempt")
appendChat("char", "first scene")

local authorityBeforeObservedReceipt = canonical(states[AUTHORITY])
local pendingBeforeObservedReceipt = canonical(states[PENDING])
failNextStateWrite = ACTIVE
assertFails("dropped output observation receipt", controller("commitOutput"),
    "state_write_not_persisted")
assert(canonical(states[AUTHORITY]) == authorityBeforeObservedReceipt
    and canonical(states[PENDING]) == pendingBeforeObservedReceipt
    and states[ACTIVE].phase == "requestInjected"
    and states[ACTIVE].outputObserved == nil
    and chat[#chat].role == "char" and chat[#chat].data == "first scene",
    "failed output observation receipt changed battle state or the completed response")

local beforeCommitInitializerCalls = moduleCalls.turnInitializer or 0
local committed = assertOk("commit output", controller("commitOutput"))
assert(committed.applied == true and committed.initializedNextTurn == true)
assert(committed.turnId == "controller-battle-turn-001" and committed.turnNumber == 2)
assert((moduleCalls.turnInitializer or 0) == beforeCommitInitializerCalls + 1,
    "first commit did not initialize exactly one next turn")
local afterFirstCommit = assertOk("snapshot after first commit", controller("getSnapshot")).snapshot
assert(afterFirstCommit.pendingTurn == nil and type(afterFirstCommit.lastCommittedPending) == "table")
assert(afterFirstCommit.authorityState.turnNumber == 2
    and afterFirstCommit.authorityState.lastCommittedTurnId == "controller-battle-turn-001")
assert(type(afterFirstCommit.authorityState.turnStartReceipt) == "table"
    and afterFirstCommit.authorityState.turnStartReceipt.turnId == "controller-battle-turn-002")
assert(type(afterFirstCommit.draft) == "table"
    and afterFirstCommit.activeRequest.source == "lastCommittedPending"
    and afterFirstCommit.activeRequest.phase == "committed")
assert(canonical(afterFirstCommit.lastPublicResult)
    == canonical(afterFirstCommit.lastCommittedPending.turnResult.publicResult),
    "last public result was not projected from the committed pending")
assert(afterFirstCommit.activeRequest.source == "lastCommittedPending"
    and afterFirstCommit.view == nil,
    "snapshot unexpectedly contained a rendered View")
assert(committed.view.lastTurn.available == true and committed.view.lastTurn.turnNumber == 1,
    "committed View did not receive the last-turn presentation")

local savedLastCommitted = clone(states[LAST])
states[LAST] = nil
assertFails("missing last committed pending", controller("publishCurrentView"), "missing_last_committed_pending")
states[LAST] = savedLastCommitted

local turnTwoStateSnapshot = canonical(afterFirstCommit.authorityState)
local turnTwoDraftSnapshot = canonical(afterFirstCommit.draft)
local initializerCallsAfterFirstCommit = moduleCalls.turnInitializer or 0
local duplicateCommit = assertOk("duplicate commit", controller("commitOutput"))
assert(duplicateCommit.applied == false and duplicateCommit.initializedNextTurn == false)
assert((moduleCalls.turnInitializer or 0) == initializerCallsAfterFirstCommit,
    "duplicate commit initialized the next turn again")
local afterDuplicate = assertOk("snapshot after duplicate", controller("getSnapshot")).snapshot
assert(canonical(afterDuplicate.authorityState) == turnTwoStateSnapshot, "duplicate commit changed authority")
assert(canonical(afterDuplicate.draft) == turnTwoDraftSnapshot, "duplicate commit reset the active draft")
assertFails("inject committed request", controller("injectRequest", basePrompt), "request_not_in_flight")

assert(chat[#chat].role == "char" and chat[#chat].data == "first scene",
    "first committed response was not preserved")
table.remove(chat, #chat)
assert(chat[#chat].data == prepared.publicMarker, "reroll fixture did not expose the immediate marker")
failStateWriteOnOccurrence = { key = ACTIVE, remaining = 2 }
assertFails("dropped reroll in-flight phase write", controller("prepareGeneration"),
    "state_write_not_persisted")
assert(states[PENDING] == nil and states[ACTIVE].source == "lastCommittedPending"
    and states[ACTIVE].phase == "preparing",
    "reroll phase failure did not preserve its original preparing source")
local rerollPreparingView = assertOk("publish preparing reroll view",
    controller("publishCurrentView"))
assert(rerollPreparingView.view.phase == "awaitingOutput"
    and rerollPreparingView.view.locked == true,
    "preparing reroll did not remain generation-locked")

appendChat("user", "*says nothing*")
local rerollPrepared = assertOk("prepare immediate reroll", controller("prepareGeneration"))
assert(rerollPrepared.source == "lastCommittedPending" and rerollPrepared.reused == true)
assert(rerollPrepared.removedSayNothing == true and rerollPrepared.removedSayNothingCount == 1
    and rerollPrepared.markerAdded == false)
assert(markerCount(firstMarker) == 1, "immediate reroll duplicated the public marker")
assert(states[PENDING] == nil and states[ACTIVE].source == "lastCommittedPending"
    and states[ACTIVE].phase == "inFlight",
    "reroll did not bind an in-flight request without creating a current pending")
assert(rerollPrepared.view.phase == "awaitingOutput" and rerollPrepared.view.locked == true,
    "immediate reroll did not publish a generation-locked View")
local rerollAttemptBeforeZeroRetry = states[ACTIVE].attemptNumber
local rerollChatBeforeZeroRetry = canonical(chat)
local repeatedReroll = assertOk("retry zero-output reroll while in flight",
    controller("prepareGeneration"))
assert(repeatedReroll.generationReady == true
    and repeatedReroll.recoveredAbandonedRequest == true
    and repeatedReroll.zeroOutputRetry == true
    and repeatedReroll.source == "lastCommittedPending"
    and repeatedReroll.attemptNumber == rerollAttemptBeforeZeroRetry + 1
    and repeatedReroll.removedSayNothingCount == 0
    and repeatedReroll.removedUncommittedOutput == false
    and repeatedReroll.markerAdded == false,
    "marker-only reroll was not resumed without chat cleanup")
assert(canonical(chat) == rerollChatBeforeZeroRetry
    and states[ACTIVE].phase == "inFlight" and states[PENDING] == nil
    and markerCount(firstMarker) == 1,
    "zero-output reroll changed chat, request phase, or pending state")
assertFails("click during reroll", controller("clickCard", instanceId), "battle_view_locked")
local rerollInjected = assertOk("inject reroll request", controller("injectRequest", basePrompt))
assert(canonical(rerollInjected.promptArray[3]) == canonical(injected.promptArray[3]),
    "immediate reroll changed the stored turn prompt")
assert(states[ACTIVE].phase == "requestInjected",
    "reroll injection did not persist its request receipt")
local rerollInjectedView = assertOk("publish injected reroll view",
    controller("publishCurrentView"))
assert(rerollInjectedView.view.phase == "awaitingOutput"
    and rerollInjectedView.view.locked == true,
    "requestInjected reroll did not remain generation-locked")
assertFails("click after reroll injection", controller("clickCard", instanceId),
    "battle_view_locked")
appendChat("char", "rerolled scene")
local writesBeforeInjectedRerollOnStart = stateWriteCount
assertFails("repeated reroll onStart after injection", controller("prepareGeneration"),
    "request_already_in_flight")
assert(stateWriteCount == writesBeforeInjectedRerollOnStart
    and states[ACTIVE].phase == "requestInjected" and states[PENDING] == nil
    and chat[#chat].role == "char" and chat[#chat].data == "rerolled scene",
    "character output without a filler was retried or changed")
local rerollCommit = assertOk("commit reroll output", controller("commitOutput"))
assert(rerollCommit.applied == false and rerollCommit.initializedNextTurn == false)
assert(rerollCommit.view.phase == "selecting" and rerollCommit.view.locked == false
    and states[ACTIVE].phase == "committed",
    "reroll completion did not unlock the current draft")
local afterReroll = assertOk("snapshot after reroll", controller("getSnapshot")).snapshot
assert(canonical(afterReroll.authorityState) == turnTwoStateSnapshot, "reroll changed next-turn authority")
assert(canonical(afterReroll.draft) == turnTwoDraftSnapshot, "reroll changed next-turn draft")

appendChat("user", "*says nothing*")
appendChat("user", "*says nothing*")
failNextAddChat = true
assertFails("dropped second marker write", controller("prepareGeneration"), "public_marker_add_not_persisted")
assert(type(states[PENDING]) == "table" and states[PENDING].turnId == "controller-battle-turn-002"
    and states[ACTIVE].phase == "preparing",
    "marker failure did not leave a resumable preparing binding")
assert(markerCount(firstMarker) == 1 and sayNothingCount() == 1,
    "marker failure left trailing fillers or changed historical filler")
assertFails("inject preparing request", controller("injectRequest", basePrompt), "request_not_in_flight")
assertFails("click while marker recovery pending", controller("clickCard", instanceId), "battle_view_locked")

failStateWriteOnOccurrence = { key = ACTIVE, remaining = 2 }
assertFails("dropped in-flight phase write", controller("prepareGeneration"), "state_write_not_persisted")
local secondMarker = states[ACTIVE].publicMarker
assert(states[ACTIVE].phase == "preparing" and chat[#chat].data == secondMarker,
    "final phase failure did not preserve a preparing binding beside its persisted marker")
assert(markerCount(secondMarker) == 1,
    "final phase failure did not leave exactly one recoverable public marker")
assertFails("inject after dropped in-flight phase", controller("injectRequest", basePrompt),
    "request_not_in_flight")
assertFails("click after dropped in-flight phase", controller("clickCard", instanceId),
    "battle_view_locked")

local secondPrepared = assertOk("resume second marker", controller("prepareGeneration"))
assert(secondPrepared.source == "pending" and secondPrepared.reused == true and secondPrepared.turnNumber == 2)
assert(secondPrepared.removedSayNothingCount == 0 and secondPrepared.markerAdded == false
    and states[ACTIVE].phase == "inFlight",
    "marker recovery did not advance preparing to inFlight")
assert(secondPrepared.publicMarker == states[ACTIVE].publicMarker
    and string.find(secondPrepared.publicMarker, "2", 1, true),
    "second marker was not the persisted turn-two marker")
assert(markerCount(firstMarker) == 1 and markerCount(secondPrepared.publicMarker) == 1,
    "second turn did not add exactly one public marker")
local secondAttemptBeforeZeroRetry = states[ACTIVE].attemptNumber
local secondPendingBeforeZeroRetry = canonical(states[PENDING])
local secondChatBeforeZeroRetry = canonical(chat)
local repeatedSecondTurn = assertOk("retry zero-output second turn",
    controller("prepareGeneration"))
assert(repeatedSecondTurn.generationReady == true
    and repeatedSecondTurn.recoveredAbandonedRequest == true
    and repeatedSecondTurn.zeroOutputRetry == true
    and repeatedSecondTurn.source == "pending"
    and repeatedSecondTurn.attemptNumber == secondAttemptBeforeZeroRetry + 1
    and repeatedSecondTurn.removedSayNothingCount == 0
    and repeatedSecondTurn.removedUncommittedOutput == false
    and repeatedSecondTurn.markerAdded == false,
    "second marker-only request was not resumed as a zero-output retry")
assert(canonical(states[PENDING]) == secondPendingBeforeZeroRetry
    and canonical(chat) == secondChatBeforeZeroRetry
    and states[ACTIVE].phase == "inFlight"
    and markerCount(secondPrepared.publicMarker) == 1,
    "second zero-output retry changed its pending turn or chat")

local secondInjected = assertOk("inject second-turn request", controller("injectRequest", basePrompt))
assert(secondInjected.requestPhase == "requestInjected"
    and canonical(secondInjected.promptArray[#secondInjected.promptArray]) == canonical(states[ACTIVE].message),
    "second-turn request did not persist and return its private event")
appendChat("char", "second scene")

local initializerCallsBeforeCommitRecovery = moduleCalls.turnInitializer or 0
failStateWriteOnOccurrence = { key = ACTIVE, remaining = 2 }
assertFails("dropped committed binding write", controller("commitOutput"), "state_write_not_persisted")
assert(states[AUTHORITY].lastCommittedTurnId == "controller-battle-turn-002"
    and states[AUTHORITY].turnNumber == 3,
    "partial commit did not persist the once-initialized next authority")
assert(type(states[PENDING]) == "table" and states[PENDING].turnId == "controller-battle-turn-002",
    "binding failure cleared the only retry source")
assert(states[ACTIVE].source == "pending" and states[ACTIVE].phase == "requestInjected",
    "dropped binding write unexpectedly changed its source or phase")
assert(type(states[ACTIVE].outputObserved) == "table"
    and states[ACTIVE].outputObserved.attemptNumber == states[ACTIVE].attemptNumber
    and states[ACTIVE].recoveringCleanup == nil,
    "partial commit did not retain its output observation receipt")
assert(chat[#chat].role == "char" and chat[#chat].data == "second scene",
    "partial commit changed the observed response")
assert((moduleCalls.turnInitializer or 0) == initializerCallsBeforeCommitRecovery + 1,
    "partial commit did not initialize the next turn exactly once")

local fillersBeforeObservedRecovery = sayNothingCount()
appendChat("user", "*says nothing*")
local recoveredCommit = assertOk("recover observed output commit",
    controller("prepareGeneration"))
assert(recoveredCommit.applied == false
    and recoveredCommit.initializedNextTurn == false
    and recoveredCommit.generationReady == false
    and recoveredCommit.commitRecovered == true
    and recoveredCommit.removedSayNothing == true
    and recoveredCommit.removedSayNothingCount == 1
    and recoveredCommit.removedUncommittedOutput == false,
    "observed output recovery retried generation instead of resuming commit")
assert(chat[#chat].role == "char" and chat[#chat].data == "second scene"
    and sayNothingCount() == fillersBeforeObservedRecovery,
    "observed output recovery deleted or changed the completed response")
assert(states[PENDING] == nil and states[ACTIVE].source == "lastCommittedPending"
    and states[ACTIVE].phase == "committed"
    and states[ACTIVE].outputObserved == nil
    and states[ACTIVE].recoveringCleanup == nil,
    "commit recovery did not finish the pending-to-last migration")
assert(states[AUTHORITY].turnNumber == 3
    and (moduleCalls.turnInitializer or 0) == initializerCallsBeforeCommitRecovery + 1,
    "commit recovery initialized or advanced the next turn twice")
assert(recoveredCommit.view.lastTurn.available == true and recoveredCommit.view.lastTurn.turnNumber == 2,
    "recovered commit did not publish the second public result")

local initializerCallsBeforePendingClearRecovery = moduleCalls.turnInitializer or 0
states[PENDING] = clone(states[LAST])
failNextStateWrite = PENDING
assertFails("dropped matching pending clear", controller("commitOutput"), "state_write_not_persisted")
assert(type(states[PENDING]) == "table" and states[ACTIVE].phase == "committed",
    "dropped pending clear lost the committed retry binding")
local clearedCommittedPending = assertOk("recover matching pending clear", controller("commitOutput"))
assert(clearedCommittedPending.applied == false and states[PENDING] == nil)
assert((moduleCalls.turnInitializer or 0) == initializerCallsBeforePendingClearRecovery,
    "matching pending cleanup initialized the active turn again")

appendChat("char", "continue-like output")
assertFails("unsupported continue-like source", controller("prepareGeneration"),
    "unsupported_generation_source")

chatVars.battleView = "stale-wire"
failNextChatVarWrite = "battleView"
local reloadsBeforeDroppedView = reloadDisplayCount
assertFails("dropped view publish", controller("publishCurrentView"), "view_write_not_persisted")
assert(reloadDisplayCount == reloadsBeforeDroppedView, "unverified view publication reloaded the display")
assertFails("unknown action", controller("notAnAction"), "unknown_action")

local finalSnapshot = assertOk("final snapshot", controller("getSnapshot")).snapshot
local signature = canonical({
    authority = finalSnapshot.authorityState,
    pending = finalSnapshot.pendingTurn,
    lastCommitted = finalSnapshot.lastCommittedPending,
    activeRequest = finalSnapshot.activeRequest,
    prompt = secondPrepared.publicMarker,
    markerCount = markerCount(firstMarker) + markerCount(secondPrepared.publicMarker),
})
print("BATTLE_CONTROLLER|hash=" .. stableHash(signature) .. "|scenarios=46")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[battle-controller-check]],[[t]],_G))()'

    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The first Lua battle controller check failed.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua battle controller check failed.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different battle controller results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^BATTLE_CONTROLLER\|hash=\d{10}\|scenarios=46$') {
        throw "Unexpected battle controller determinism vector: $firstText"
    }

    Write-Output 'battle-controller-check: ok'
    Write-Output 'NOTE: actual RisuAI hook ordering, permissions, and UI rendering still require host integration testing.'
}
finally {
    Pop-Location
}
