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

$initSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'System\init.lua')
if (-not $initSource.Contains('runScript(triggerId, "gameSetupController", action, ...)')) {
    throw 'init.lua is not a thin gameSetupController route'
}
if ($initSource.Contains('setState(') -or $initSource.Contains('setChatVar(') -or $initSource.Contains('reloadDisplay(')) {
    throw 'init.lua directly owns setup host state instead of delegating it'
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
    battleController = function(triggerId, action, setupState)
        if action ~= "startFromSetup" then
            return {
                ok = false,
                schemaVersion = 1,
                errors = { { code = "unknown_action", path = "$.action", message = "unexpected battle action" } },
            }
        end
        local authorityKey = "battleRuntimeV1.authority"
        local existing = getState(triggerId, authorityKey)
        local reused = existing ~= nil
        if not reused then
            setState(triggerId, authorityKey, {
                kind = "battleState",
                battleId = setupState.battleSpec.battleId,
                turnNumber = 1,
                status = "active",
            })
            setState(triggerId, "battleRuntimeV1.draft", { kind = "turnDraft", turnNumber = 1 })
            setState(triggerId, "battleRuntimeV1.pending", nil)
            setState(triggerId, "battleRuntimeV1.lastCommittedPending", nil)
            setState(triggerId, "battleRuntimeV1.activeRequest", nil)
        end
        local view = {
            schemaVersion = 1,
            kind = "battleView",
            battleId = setupState.battleSpec.battleId,
            turnNumber = 1,
            phase = "selecting",
        }
        setChatVar(triggerId, "battleView", "mock-battle-view:" .. setupState.battleSpec.battleId)
        setChatVar(triggerId, string.char(240, 159, 148, 175):rep(3), "mock-battle-ui:" .. setupState.battleSpec.battleId)
        return {
            ok = true,
            schemaVersion = 1,
            errors = {},
            applied = not reused,
            reused = reused,
            recovered = false,
            battleId = setupState.battleSpec.battleId,
            setupId = setupState.setupId,
            turnNumber = 1,
            view = view,
        }
    end,
    gameSetupController = loadLore("System/gameSetupController.lua"),
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
    ["CharacterList.db"] = "Char/CharacterList.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
    ["YoonSeoa.db"] = "Char/YoonSeoa.db",
    ["HanJenny.db"] = "Char/HanJenny.db",
    ["SeoMiryeong.db"] = "Char/SeoMiryeong.db",
    ["SisterAgnes.db"] = "Char/SisterAgnes.db",
    ["sideBar.html"] = "html/sideBar.html",
    ["cardDraft.html"] = "html/cardDraft.html",
    ["characterSelect.html"] = "html/characterSelect.html",
}
local loreContentTransform
local loreLoadCounts = {}
function getLoreBooks(triggerId, name)
    loreLoadCounts[name] = (loreLoadCounts[name] or 0) + 1
    local path = lorePaths[name]
    if not path then return {} end
    local content = readFile(path)
    if type(loreContentTransform) == "function" then
        content = loreContentTransform(name, content)
    end
    return { { content = content } }
end
function loadLores(triggerId, name)
    local content = ""
    for _, lore in ipairs(getLoreBooks(triggerId, name)) do
        content = content .. lore.content
    end
    return content ~= "" and content or nil
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

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local messages = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path) .. ": " .. tostring(item.message)
        end
        error(label .. " failed | " .. table.concat(messages, " | "))
    end
    assert(report.schemaVersion == 1 and type(report.errors) == "table" and #report.errors == 0,
        label .. " returned an invalid success envelope")
    return report
end

local function hasError(report, code)
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        if item.code == code then return true end
    end
    return false
end

local function assertFailed(label, report, expectedCode)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.schemaVersion == 1 and type(report.errors) == "table" and #report.errors > 0,
        label .. " must return a structured failure")
    for _, item in ipairs(report.errors) do
        assert(type(item.code) == "string" and item.code ~= "", label .. " error code missing")
        assert(type(item.path) == "string" and item.path ~= "", label .. " error path missing")
        assert(type(item.message) == "string" and item.message ~= "", label .. " error message missing")
    end
    assert(hasError(report, expectedCode), label .. " missing error code " .. expectedCode)
    return report
end

local AUTHORITY = "gameSetupV1.authority"
local VIEW = "gameSetupView"
local READY = "gameSetupReady"
-- Keep this byte-exact when PowerShell pipes the Lua fixture to a fallback host.
local UI = string.char(240, 159, 148, 175):rep(3)
local UI_SHELL = "helltrainUiShellV1"
local UI_SHELL_REVISION = "helltrainUiShellRevision"
local states = {}
local chatVars = {}
local events = {}
local stateWrites = 0
local reloads = 0
local cbsCalls = 0
local cbsValue = "12345"
local cbsThrows = false
local dropStateWrite = false
local authorityReadReplacement
local dropChatKey
local dropReadyValue
local lastAlert
DEBUG = 0

local function record(value) events[#events + 1] = value end
function setState(triggerId, key, value)
    stateWrites = stateWrites + 1
    record("state:" .. key)
    if dropStateWrite then dropStateWrite = false return end
    states[key] = clone(value)
end
function getState(triggerId, key)
    record("get-state:" .. key)
    if key == AUTHORITY and type(authorityReadReplacement) == "table" then
        authorityReadReplacement.remaining = authorityReadReplacement.remaining - 1
        if authorityReadReplacement.remaining == 0 then
            states[key] = clone(authorityReadReplacement.value)
            authorityReadReplacement = nil
        end
    end
    return clone(states[key])
end
function setChatVar(triggerId, key, value)
    record("chat:" .. key .. ":" .. (key == READY and tostring(value) or "value"))
    if dropChatKey == key then dropChatKey = nil return end
    if key == READY and dropReadyValue == value then dropReadyValue = nil return end
    chatVars[key] = value
end
function getChatVar(triggerId, key)
    record("get-chat:" .. key)
    return chatVars[key]
end
function reloadDisplay(triggerId)
    reloads = reloads + 1
    record("reload")
end
function cbs(source)
    cbsCalls = cbsCalls + 1
    assert(source == "{{randint::1::2147483646}}", "controller used an unexpected seed macro")
    if cbsThrows then error("injected cbs failure") end
    return cbsValue
end
function alertError(triggerId, message)
    lastAlert = message
end

local originalHosts = {
    setState = setState,
    getState = getState,
    setChatVar = setChatVar,
    getChatVar = getChatVar,
    reloadDisplay = reloadDisplay,
    cbs = cbs,
    loadLores = loadLores,
}

local function reset(seed)
    moduleCalls = {}
    states = {}
    chatVars = {}
    events = {}
    stateWrites = 0
    reloads = 0
    cbsCalls = 0
    cbsValue = seed or "12345"
    cbsThrows = false
    dropStateWrite = false
    authorityReadReplacement = nil
    dropChatKey = nil
    dropReadyValue = nil
    lastAlert = nil
    loreContentTransform = nil
    loreLoadCounts = {}
    setState = originalHosts.setState
    getState = originalHosts.getState
    setChatVar = originalHosts.setChatVar
    getChatVar = originalHosts.getChatVar
    reloadDisplay = originalHosts.reloadDisplay
    cbs = originalHosts.cbs
    loadLores = originalHosts.loadLores
end

local function controller(action, ...)
    return modules.gameSetupController("game-setup-controller-check", action, ...)
end

local function writeEvents()
    local selected = {}
    for _, event in ipairs(events) do
        if string.sub(event, 1, 6) == "state:"
            or string.sub(event, 1, 5) == "chat:"
            or event == "reload" then
            selected[#selected + 1] = event
        end
    end
    return selected
end

local function assertWriteOrder(label, expected)
    local actual = writeEvents()
    assert(#actual == #expected, label .. " write count changed: " .. table.concat(actual, ","))
    for index, value in ipairs(expected) do
        assert(actual[index] == value,
            label .. " write order mismatch at " .. index .. ": " .. tostring(actual[index]) .. " ~= " .. value)
    end
end

local freshWriteOrder = {
    "chat:" .. READY .. ":updating",
    "state:" .. AUTHORITY,
    "chat:" .. VIEW .. ":value",
    "chat:" .. UI_SHELL .. ":value",
    "chat:" .. UI_SHELL_REVISION .. ":value",
    "chat:" .. UI .. ":value",
    "chat:" .. READY .. ":ready",
}
local fullWriteOrder = {
    "chat:" .. READY .. ":updating",
    "state:" .. AUTHORITY,
    "chat:" .. VIEW .. ":value",
    "chat:" .. UI .. ":value",
    "chat:" .. READY .. ":ready",
}
local publishOnlyOrder = {
    "chat:" .. READY .. ":updating",
    "chat:" .. VIEW .. ":value",
    "chat:" .. UI .. ":value",
    "chat:" .. READY .. ":ready",
}

-- Static DB header failures expose the exact lore entry in the modal even when
-- the browser console is unavailable or filtered.
do
reset("12000")
local consoleDiagnostics = {}
local previousPrint = print
local previousDebug = DEBUG
DEBUG = 2
print = function(message)
    consoleDiagnostics[#consoleDiagnostics + 1] = tostring(message)
end
loreContentTransform = function(name, content)
    if name ~= "CharacterList.db" then return content end
    local replaced, count = string.gsub(
        content,
        'kind = "characterList"',
        'kind = "characterDatabase"',
        1
    )
    assert(count == 1, "character list controller diagnostic fixture replacement failed")
    return replaced
end
local headerMismatch = assertFailed("static header mismatch", controller("start"), "unexpected_kind")
print = previousPrint
DEBUG = previousDebug
assert(headerMismatch.errors[1].path == "CharacterList.db[1].kind",
    "static header mismatch did not remain the first actionable error")
assert(type(lastAlert) == "string"
        and lastAlert:find("expected=characterList", 1, true)
        and lastAlert:find("actual=characterDatabase", 1, true)
        and lastAlert:find("CharacterList.db[1].kind", 1, true),
    "static header mismatch alert did not include kinds and path")
local sawControllerFailureDiagnostic = false
local sawControllerErrorDiagnostic = false
for _, diagnostic in ipairs(consoleDiagnostics) do
    if type(diagnostic) == "string"
        and diagnostic:find("[helltrain.gameSetupController]", 1, true)
        and diagnostic:find("event=request_failed", 1, true)
        and diagnostic:find("action=start", 1, true) then
        sawControllerFailureDiagnostic = true
    end
    if type(diagnostic) == "string"
        and diagnostic:find("[helltrain.gameSetupController]", 1, true)
        and diagnostic:find("event=request_error", 1, true)
        and diagnostic:find("code=unexpected_kind", 1, true)
        and diagnostic:find("path=CharacterList.db[1].kind", 1, true) then
        sawControllerErrorDiagnostic = true
    end
end
assert(sawControllerFailureDiagnostic, "controller failure did not emit its structured error list")
assert(sawControllerErrorDiagnostic, "controller failure did not print its actionable error path")
end

-- RisuAI getLoreBooks parses lore CBS before returning its content. The draft
-- lore must therefore be loaded after the new View is published, both on the
-- initial start and after every choice.
reset("12001")
local parsedDraftPrefix = "[host-parsed-card-draft:"
loreContentTransform = function(name, content)
    if name ~= "cardDraft.html" then return content end
    record("lore:" .. name)
    return parsedDraftPrefix .. tostring(chatVars[VIEW]) .. "]"
end
local hostParsedStart = assertOk("host-parsed fresh start", controller("start"))
assert(hostParsedStart.view.phase == "deckDraft", "host-parsed start did not build a deckDraft View")
assert(chatVars[UI] == parsedDraftPrefix .. chatVars[VIEW] .. "]",
    "card draft lore was parsed before the fresh gameSetupView was published")
assert(chatVars[UI_SHELL] == readFile("html/sideBar.html"), "sidebar shell was not installed separately")
local function assertDraftLoreOrder(label)
    local viewWriteIndex
    local loreLoadIndex
    local uiWriteIndex
    local viewWrites = 0
    local loreLoads = 0
    local uiWrites = 0
    for index, event in ipairs(events) do
        if event == "chat:" .. VIEW .. ":value" then
            viewWrites = viewWrites + 1
            viewWriteIndex = viewWriteIndex or index
        end
        if event == "lore:cardDraft.html" then
            loreLoads = loreLoads + 1
            loreLoadIndex = loreLoadIndex or index
        end
        if event == "chat:" .. UI .. ":value" then
            uiWrites = uiWrites + 1
            uiWriteIndex = uiWriteIndex or index
        end
    end
    assert(viewWrites == 1 and loreLoads == 1 and uiWrites == 1,
        label .. " duplicated or omitted a View/lore/UI boundary")
    assert(type(viewWriteIndex) == "number" and type(loreLoadIndex) == "number" and type(uiWriteIndex) == "number",
        label .. " did not record the View/lore/UI boundaries")
    assert(viewWriteIndex < loreLoadIndex and loreLoadIndex < uiWriteIndex,
        label .. " must publish View, parse draft lore, then write UI")
end
assertDraftLoreOrder("host-parsed fresh start")

local hostParsedState = clone(states[AUTHORITY])
local hostParsedBeforeChoiceWire = chatVars[VIEW]
events = {}
local hostParsedChoice = assertOk("host-parsed choose", controller(
    "choose",
    hostParsedState.offer.cardIds[1],
    hostParsedState.offer.interactionToken
))
assert(hostParsedChoice.applied == true and #states[AUTHORITY].selectedCardIds == 1,
    "host-parsed choose did not advance authority")
assert(hostParsedChoice.view.progress.selectedCount == 1 and chatVars[VIEW] ~= hostParsedBeforeChoiceWire,
    "host-parsed choose did not publish the advanced View")
assert(chatVars[UI] == parsedDraftPrefix .. chatVars[VIEW] .. "]",
    "card draft lore used the previous gameSetupView after a choice")
assert((loreLoadCounts["sideBar.html"] or 0) == 1, "sidebar shell was reloaded for a setup choice")
assertDraftLoreOrder("host-parsed choose")

-- Fresh start consumes exactly one CBS randint and publishes only verified data.
reset("12345")
local started = assertOk("fresh start", controller("start"))
assert(started.action == "start" and started.applied == true and started.stale == false)
assert(cbsCalls == 1, "fresh start must call cbs exactly once")
assert(states[AUTHORITY].setupId == "setup-12345" and states[AUTHORITY].rng.seed == 12345,
    "generated seed/setupId were not persisted")
assert(chatVars[READY] == "ready" and type(chatVars[VIEW]) == "string" and chatVars[VIEW] ~= "",
    "fresh start did not publish a ready View")
assert(chatVars[UI] == readFile("html/cardDraft.html"),
    "fresh start UI body is not the card draft; actual=" .. tostring(type(chatVars[UI]) == "string" and #chatVars[UI] or -1)
        .. ", expected=" .. tostring(#readFile("html/cardDraft.html")))
assert(chatVars[UI_SHELL] == readFile("html/sideBar.html")
        and chatVars[UI_SHELL_REVISION] == "sidebar-e3f104ae8f3037cd",
    "fresh start did not install the versioned sidebar shell")
assert(reloads == 0, "fresh start duplicated the host's automatic button remount")
assert(moduleCalls.gameSetup == 1 and moduleCalls.gameSetupView == 1 and moduleCalls.deterministicRng == 1,
    "fresh start repeated gameSetup validation/View generation or failed to batch its offer: gameSetup="
        .. tostring(moduleCalls.gameSetup) .. ", gameSetupView=" .. tostring(moduleCalls.gameSetupView)
        .. ", deterministicRng=" .. tostring(moduleCalls.deterministicRng))
assertWriteOrder("fresh start", freshWriteOrder)
local storedSnapshot = canonical(states[AUTHORITY])
local storedWrites = stateWrites
started.state.selectedCardIds[1] = "mutated_result_canary"
assert(canonical(states[AUTHORITY]) == storedSnapshot, "returned start state aliases host authority")

-- Restart/recovery validates and republishes without a new seed or authority write.
events = {}
moduleCalls = {}
local restarted = assertOk("idempotent restart", controller("start"))
assert(restarted.applied == false and restarted.stale == false)
assert(cbsCalls == 1, "restart consumed another CBS seed")
assert(stateWrites == storedWrites and canonical(states[AUTHORITY]) == storedSnapshot,
    "restart rewrote or changed authority")
assert(reloads == 0, "restart duplicated the host's automatic button remount")
assert(moduleCalls.gameSetup == 1 and moduleCalls.gameSetupView == 1 and moduleCalls.deterministicRng == 1,
    "restart must validate authority once and reuse it for canonical View projection")
assertWriteOrder("idempotent restart", publishOnlyOrder)

-- A valid choice is stored once. Repeating the old token is a state-write-free stale recovery.
local beforeChoice = clone(states[AUTHORITY])
local chosenCard = beforeChoice.offer.cardIds[1]
local oldToken = beforeChoice.offer.interactionToken
events = {}
moduleCalls = {}
local chosen = assertOk("valid choose", controller("choose", chosenCard, oldToken))
assert(chosen.applied == true and chosen.stale == false and #states[AUTHORITY].selectedCardIds == 1,
    "valid choose was not persisted once")
assert(cbsCalls == 1, "choose consumed a setup seed")
assert(moduleCalls.gameSetup == 1 and moduleCalls.gameSetupView == 1 and moduleCalls.deterministicRng == 2,
    "first choose must replay current authority once and generate only the next offer")
assertWriteOrder("valid choose", fullWriteOrder)
local afterChoiceSnapshot = canonical(states[AUTHORITY])
local writesAfterChoice = stateWrites
events = {}
moduleCalls = {}
local stale = assertOk("stale double click", controller("choose", chosenCard, oldToken))
assert(stale.applied == false and stale.stale == true, "old token was not a successful stale no-op")
assert(canonical(states[AUTHORITY]) == afterChoiceSnapshot and stateWrites == writesAfterChoice,
    "stale double click wrote authority")
assert(cbsCalls == 1, "stale recovery consumed a setup seed")
assert(moduleCalls.gameSetup == 1 and moduleCalls.gameSetupView == 1 and moduleCalls.deterministicRng == 2,
    "stale recovery repeated authority validation or View replay")
assertWriteOrder("stale double click", publishOnlyOrder)

-- Finish all ten rounds. The tenth choice skips persistent deckComplete and
-- publishes the deterministic three-character selection directly.
local finalCard
local finalToken
while states[AUTHORITY].phase == "deckDraft" do
    local current = clone(states[AUTHORITY])
    finalCard = current.offer.cardIds[1]
    finalToken = current.offer.interactionToken
    local report = assertOk("choose round " .. current.offer.round,
        controller("choose", finalCard, finalToken))
    assert(report.applied == true and report.stale == false, "draft round was not applied")
end
assert(states[AUTHORITY].phase == "characterSelect" and #states[AUTHORITY].selectedCardIds == 10,
    "controller did not move the completed deck directly to characterSelect")
assert(states[AUTHORITY].offer == nil and type(states[AUTHORITY].characterOffer) == "table",
    "character selection retained a card offer or omitted its character offer")
local offeredCharacters = states[AUTHORITY].characterOffer.characterIds
assert(#offeredCharacters == 3
        and offeredCharacters[1] ~= offeredCharacters[2]
        and offeredCharacters[1] ~= offeredCharacters[3]
        and offeredCharacters[2] ~= offeredCharacters[3],
    "character selection did not contain three distinct candidates")
assert(chatVars[UI] == readFile("html/characterSelect.html"),
    "tenth choice did not replace the draft body with characterSelect.html")
assert(cbsCalls == 1, "ten-round draft consumed another setup seed")
local completedSnapshot = canonical(states[AUTHORITY])
local completedWrites = stateWrites
events = {}
local finalStale = assertOk("tenth choice double click", controller("choose", finalCard, finalToken))
assert(finalStale.applied == false and finalStale.stale == true,
    "tenth choice double click was not a successful stale no-op")
assert(canonical(states[AUTHORITY]) == completedSnapshot and stateWrites == completedWrites,
    "tenth choice double click rewrote characterSelect authority")
assertWriteOrder("tenth choice double click", publishOnlyOrder)
local completed = assertOk("restart character selection", controller("start"))
assert(completed.view.phase == "characterSelect"
        and completed.view.characterOffer ~= nil
        and completed.view.deck.count == 10,
    "completed deck did not recover as the same characterSelect View")
assert(cbsCalls == 1, "character selection recovery consumed another setup seed")

-- Character confirmation durably stores battleReady before starting the
-- battle runtime. Repeated routes and start recovery must reuse, never reset.
local characterId = offeredCharacters[1]
local characterToken = states[AUTHORITY].characterOffer.interactionToken
local selected = assertOk(
    "choose character",
    controller("chooseCharacter", characterId, characterToken)
)
assert(selected.applied == true and selected.stale == false,
    "valid character choice was not applied")
assert(states[AUTHORITY].phase == "battleReady"
        and states[AUTHORITY].selectedCharacterId == characterId,
    "character choice did not persist battleReady authority")
assert(selected.view.phase == "battleReady"
        and selected.battleView.phase == "selecting"
        and selected.battle.applied == true
        and selected.battle.reused == false,
    "character choice did not hand off to the first selecting battle View")
assert(type(states["battleRuntimeV1.authority"]) == "table"
        and type(states["battleRuntimeV1.draft"]) == "table",
    "character choice did not create the first battle authority and draft")
assert(chatVars[UI] == "mock-battle-ui:" .. states[AUTHORITY].battleSpec.battleId,
    "battle handoff did not replace the character UI body")
assert(cbsCalls == 1, "character choice consumed another setup seed")

local battleReadySnapshot = canonical(states[AUTHORITY])
local runtimeSnapshot = canonical(states["battleRuntimeV1.authority"])
local writesAfterBattleStart = stateWrites
local repeatedCharacter = assertOk(
    "character double click",
    controller("chooseCharacter", characterId, characterToken)
)
assert(repeatedCharacter.applied == false
        and repeatedCharacter.stale == true
        and repeatedCharacter.battle.reused == true,
    "character double click was not a stale setup no-op with battle reuse")
assert(canonical(states[AUTHORITY]) == battleReadySnapshot
        and canonical(states["battleRuntimeV1.authority"]) == runtimeSnapshot
        and stateWrites == writesAfterBattleStart,
    "character double click rewrote setup or battle authority")

local resumedBattle = assertOk("restart battleReady", controller("start"))
assert(resumedBattle.applied == false
        and resumedBattle.stale == false
        and resumedBattle.battle.reused == true,
    "start did not idempotently resume the battleReady handoff")
assert(canonical(states[AUTHORITY]) == battleReadySnapshot
        and canonical(states["battleRuntimeV1.authority"]) == runtimeSnapshot,
    "battleReady recovery changed persistent authority")

-- Optimistic authority check rejects a competing valid transition that lands
-- after the command read but before its write.
reset("13579")
assertOk("concurrency fixture start", controller("start"))
local concurrentBase = clone(states[AUTHORITY])
local concurrentWinner = assertOk("concurrency winner fixture", modules.gameSetup(
    "game-setup-controller-check",
    "choose",
    concurrentBase,
    {
        cardId = concurrentBase.offer.cardIds[2],
        interactionToken = concurrentBase.offer.interactionToken,
    },
    assertOk("concurrency static fixture", modules.staticData(
        "game-setup-controller-check",
        "loadAll"
    )).data
)).state
local writesBeforeConflict = stateWrites
authorityReadReplacement = { remaining = 2, value = concurrentWinner }
local concurrentLoser = assertFailed(
    "concurrent setup transition",
    controller(
        "choose",
        concurrentBase.offer.cardIds[1],
        concurrentBase.offer.interactionToken
    ),
    "authority_concurrent_change"
)
assert(stateWrites == writesBeforeConflict
        and canonical(states[AUTHORITY]) == canonical(concurrentWinner),
    "concurrent loser overwrote the winning authority transition")
assert(chatVars[READY] == "ready",
    "known concurrent conflict disturbed the already published ready UI")

-- Authority may be committed before a later publication failure. Restart must reuse it.
reset("24680")
dropChatKey = VIEW
local failedView = assertFailed("dropped View publication", controller("start"), "view_write_not_persisted")
assert(type(states[AUTHORITY]) == "table" and states[AUTHORITY].rng.seed == 24680,
    "publication failure lost its verified authority")
assert((loreLoadCounts["cardDraft.html"] or 0) == 0,
    "failed View verification must not parse card draft lore")
assert(cbsCalls == 1 and reloads == 0 and chatVars[READY] ~= "ready",
    "failed publication reloaded/marked ready or consumed the wrong seed count")
local failedAuthority = canonical(states[AUTHORITY])
local failedWrites = stateWrites
local recovered = assertOk("recover persisted start", controller("start"))
assert(recovered.applied == false and canonical(states[AUTHORITY]) == failedAuthority,
    "publication recovery replaced authority")
assert(cbsCalls == 1 and stateWrites == failedWrites,
    "publication recovery generated a new seed or rewrote authority")

local function assertFailureBoundary(label, report, expectedCode)
    assertFailed(label, report, expectedCode)
    assert(reloads == 0, label .. " reloaded the display")
    assert(chatVars[READY] ~= "ready", label .. " marked setup ready")
end

-- Seed provider boundaries: no fallback randomness and no persisted authority.
local function seedFailure(label, value, throws, missing, expectedCode)
    reset(value)
    cbsThrows = throws == true
    if missing then cbs = nil end
    assertFailureBoundary(label, controller("start"), expectedCode)
    assert(states[AUTHORITY] == nil and stateWrites == 0, label .. " persisted authority")
    assert(cbsCalls == (missing and 0 or 1), label .. " called cbs an unexpected number of times")
end
seedFailure("missing cbs", "1", false, true, "cbs_unavailable")
seedFailure("throwing cbs", "1", true, false, "seed_generation_failed")
seedFailure("NaN seed", "NaN", false, false, "invalid_generated_seed")
seedFailure("fraction seed", "1.5", false, false, "invalid_generated_seed")
seedFailure("zero seed", "0", false, false, "invalid_generated_seed")
seedFailure("out of range seed", "2147483647", false, false, "generated_seed_out_of_range")

-- Corrupt authority is rejected without replacement or a seed retry.
reset("333")
assertOk("corruption fixture", controller("start"))
states[AUTHORITY].rng.cursor = states[AUTHORITY].rng.cursor + 1
local corruptSnapshot = canonical(states[AUTHORITY])
chatVars[READY] = nil
reloads = 0
local callsBeforeCorrupt = cbsCalls
local writesBeforeCorrupt = stateWrites
assertFailureBoundary("corrupt authority", controller("start"), "setup_state_replay_mismatch")
assert(canonical(states[AUTHORITY]) == corruptSnapshot and stateWrites == writesBeforeCorrupt,
    "corrupt authority was overwritten")
assert(cbsCalls == callsBeforeCorrupt, "corrupt authority triggered a new seed")

-- Every host persistence boundary is read back; mismatch never reloads or marks ready.
reset("444")
dropStateWrite = true
assertFailureBoundary("authority write mismatch", controller("start"), "state_write_not_persisted")

reset("445")
dropChatKey = VIEW
assertFailureBoundary("View write mismatch", controller("start"), "view_write_not_persisted")

reset("446")
dropChatKey = UI
assertFailureBoundary("UI write mismatch", controller("start"), "chat_var_write_not_persisted")

reset("447")
dropReadyValue = "ready"
assertFailureBoundary("ready write mismatch", controller("start"), "chat_var_write_not_persisted")

-- Once CBS has issued a seed, even build/View/lore failures retain that exact
-- authority so retry never rolls a different initial offer.
reset("448")
local realGameSetupView = modules.gameSetupView
modules.gameSetupView = function() error("injected module exception") end
assertFailureBoundary("module exception", controller("start"), "module_call_error")
assert(type(states[AUTHORITY]) == "table" and states[AUTHORITY].rng.seed == 448,
    "module exception did not retain the generated authority")
assert(cbsCalls == 1, "module exception consumed an unexpected seed count")
local moduleFailureState = canonical(states[AUTHORITY])
local moduleFailureWrites = stateWrites
modules.gameSetupView = realGameSetupView
local moduleRecovered = assertOk("module exception retry", controller("start"))
assert(moduleRecovered.applied == false and canonical(states[AUTHORITY]) == moduleFailureState,
    "module exception retry replaced authority")
assert(cbsCalls == 1 and stateWrites == moduleFailureWrites,
    "module exception retry rerolled or rewrote authority")

reset("4481")
local realLoadLores = loadLores
loadLores = function() error("injected lore exception") end
assertFailureBoundary("lore exception", controller("start"), "lore_load_failed")
assert(type(states[AUTHORITY]) == "table" and states[AUTHORITY].rng.seed == 4481,
    "lore exception did not retain the generated authority")
assert(cbsCalls == 1, "lore exception consumed an unexpected seed count")
local loreFailureState = canonical(states[AUTHORITY])
local loreFailureWrites = stateWrites
loadLores = realLoadLores
local loreRecovered = assertOk("lore exception retry", controller("start"))
assert(loreRecovered.applied == false and canonical(states[AUTHORITY]) == loreFailureState,
    "lore exception retry replaced authority")
assert(cbsCalls == 1 and stateWrites == loreFailureWrites,
    "lore exception retry rerolled or rewrote authority")

-- Absent host functions are contained in structured failures.
reset("449")
setState = nil
assertFailureBoundary("missing state host", controller("start"), "host_function_unavailable")
assert(states[AUTHORITY] == nil, "missing host persisted authority")

reset("450")
getChatVar = nil
assertFailureBoundary("missing chat host", controller("start"), "host_function_unavailable")
assert(states[AUTHORITY] == nil, "missing chat host persisted authority")

-- Failed commands and returned values do not mutate the authority input supplied by the host.
reset("451")
local immutabilityStart = assertOk("immutability fixture", controller("start"))
local immutableSnapshot = canonical(states[AUTHORITY])
local badCard = "not_in_offer"
chatVars[READY] = nil
reloads = 0
assertFailureBoundary("invalid card", controller("choose", badCard,
    states[AUTHORITY].offer.interactionToken), "card_not_in_current_offer")
assert(canonical(states[AUTHORITY]) == immutableSnapshot, "failed choose mutated stored authority")
immutabilityStart.view.phase = "mutated_view_canary"
assert(canonical(states[AUTHORITY]) == immutableSnapshot, "returned View aliases stored authority")

print("game-setup-controller-check: ok")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[game-setup-controller-check]],[[t]],_G))()'
    $output = $luaTest | & $luaHost -e $luaEntry 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    $output
}
finally {
    Pop-Location
}
