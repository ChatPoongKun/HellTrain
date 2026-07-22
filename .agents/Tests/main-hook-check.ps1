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

local listeners = {}
function listenEdit(kind, callback)
    listeners[kind] = listeners[kind] or {}
    listeners[kind][#listeners[kind] + 1] = callback
end

function async(callback)
    return callback
end

assert(load(readFile("System/main.lua"), "@System/main.lua", "t", _G))()

local loreFixture = ""
function getLoreBooks(triggerId, lore)
    return { { content = loreFixture } }
end

loreFixture = "  <section>\n\t<span>LF</span>\r\n    <span>CRLF</span>\r  <span>CR</span>"
assert(loadLores("main-hook-check", "fixture.html")
        == "<section>\n<span>LF</span>\r\n<span>CRLF</span>\r<span>CR</span>",
    "HTML lore retained line-leading indentation")
loreFixture = "  return function()\n    return true\n  end"
assert(loadLores("main-hook-check", "fixture.lua") == loreFixture,
    "non-HTML lore was changed by HTML indentation normalization")

assert(type(onStart) == "function", "onStart was not registered")
assert(type(onOutput) == "function", "onOutput was not registered")
assert(type(onButtonClick) == "function", "onButtonClick was not registered")
assert(type(listeners.editDisplay) == "table" and #listeners.editDisplay == 1,
    "editDisplay listener count changed")
assert(type(listeners.editInput) == "table" and #listeners.editInput == 1,
    "editInput listener was not registered exactly once")
assert(type(listeners.editRequest) == "table" and #listeners.editRequest == 1,
    "editRequest listener was not registered exactly once")

local editInput = listeners.editInput[1]
local editRequest = listeners.editRequest[1]
local editDisplay = listeners.editDisplay[1]
local displayVars = {}
function getChatVar(triggerId, key)
    return displayVars[key]
end
function setChatVar(triggerId, key, value)
    displayVars[key] = value
end
local chat = {}
local dropNextAddChat = false
local function copyChat()
    local copy = {}
    for index, message in ipairs(chat) do
        copy[index] = { role = message.role, data = message.data }
    end
    return copy
end
function getFullChat()
    return copyChat()
end
function addChat(triggerId, role, data)
    if dropNextAddChat then
        dropNextAddChat = false
        return
    end
    chat[#chat + 1] = { role = role, data = data }
end

-- runScript must preserve every handler return, including an interior nil, on
-- both the first execution and the same-event transaction-cache path.
loreFixture = "(function() return function(_, value) return value, nil, 'tail' end end)()"
beginRunScriptEvent("main-hook-multivalue", "contract")
local firstValue, firstNil, firstTail = runScript("main-hook-multivalue", "multivalue", "first")
assert(firstValue == "first" and firstNil == nil and firstTail == "tail",
    "runScript discarded multiple returns on the source-load path")
local cachedValue, cachedNil, cachedTail = runScript("main-hook-multivalue", "multivalue", "cached")
assert(cachedValue == "cached" and cachedNil == nil and cachedTail == "tail",
    "runScript discarded multiple returns on the transaction-cache path")

assert(editDisplay("main-hook-check", "plain display", { index = 3 }) == "plain display",
    "editDisplay changed a message without the UI sentinel")
displayVars.gameSetupReady = "null"
displayVars.helltrainUiShellV1 = "null"
displayVars.helltrainUiPopupV1 = "null"
local unreadyDisplay = editDisplay(
    "main-hook-check",
    "before@@HELLTRAIN_UI_ANCHOR_V1@@after",
    { index = -1 }
)
assert(string.find(unreadyDisplay, 'risu-btn="init|start"', 1, true),
    "editDisplay did not render the start control before setup was ready")
assert(not string.find(unreadyDisplay, "<shell>", 1, true),
    "editDisplay rendered game fragments before setup was ready")
assert(not string.find(unreadyDisplay, "null", 1, true),
    "editDisplay leaked the host's undefined chatVar sentinel")
assert(editDisplay(
        "main-hook-check",
        "before@@HELLTRAIN_UI_ANCHOR_V1@@after",
        { index = 4 }
    ) == "beforeafter",
    "editDisplay did not retire a non-dedicated UI sentinel")
displayVars.helltrainUiShellV1 = "<shell>"
local uiBodyKey = string.char(240, 159, 148, 175):rep(3)
displayVars[uiBodyKey] = "<body>"
displayVars.helltrainUiPopupV1 = "<popup>"
displayVars.gameSetupReady = "ready"
local injectedDisplay = editDisplay(
    "main-hook-check",
    "before@@HELLTRAIN_UI_ANCHOR_V1@@after",
    { index = -1 }
)
assert(injectedDisplay == "before<shell><body><popup>after",
    "editDisplay did not compose the shell, body, and popup slots")
assert(displayVars.helltrainUiAnchorIndexV1 == nil,
    "editDisplay mutated the active UI anchor index")

displayVars.helltrainUiAnchorIndexV1 = "4"
assert(editDisplay(
        "main-hook-check",
        "@@HELLTRAIN_UI_ANCHOR_V1@@",
        { index = 4 }
    ) == "<shell><body><popup>",
    "editDisplay did not render the exact active user UI anchor")
assert(editDisplay(
        "main-hook-check",
        "@@HELLTRAIN_UI_ANCHOR_V1@@",
        { index = 3 }
    ) == "",
    "editDisplay rendered an inactive user UI anchor")
assert(editDisplay(
        "main-hook-check",
        "before@@HELLTRAIN_UI_ANCHOR_V1@@after",
        { index = -1 }
    ) == "beforeafter",
    "editDisplay did not retire the first-message bootstrap UI")

local targetedReloads = {}
local fullReloads = 0
function reloadChat(triggerId, index)
    targetedReloads[#targetedReloads + 1] = index
end
function reloadDisplay() fullReloads = fullReloads + 1 end
displayVars.helltrainUiAnchorIndexV1 = nil
assert(refreshGameUi("main-hook-check") == true and targetedReloads[1] == -1 and fullReloads == 0,
    "refreshGameUi did not fall back to the first-message anchor")
displayVars.helltrainUiAnchorIndexV1 = "7"
assert(refreshGameUi("main-hook-check") == true and targetedReloads[2] == 7 and fullReloads == 0,
    "refreshGameUi did not target the persisted user UI anchor")
displayVars.helltrainUiAnchorIndexV1 = "7.5"
local printBeforeInvalidAnchor = print
print = function() end
assert(refreshGameUi("main-hook-check") == true and targetedReloads[3] == -1 and fullReloads == 0,
    "refreshGameUi accepted a non-integer UI anchor index")
print = printBeforeInvalidAnchor

targetedReloads = {}
displayVars.helltrainUiAnchorIndexV1 = nil
chat = {}
assert(ensureGameUiAnchor("main-hook-check") == 0
    and #chat == 1 and chat[1].role == "user"
    and chat[1].data == "@@HELLTRAIN_UI_ANCHOR_V1@@"
    and displayVars.helltrainUiAnchorIndexV1 == "0"
    and targetedReloads[1] == -1 and targetedReloads[2] == 0,
    "ensureGameUiAnchor did not retire the first-message UI and activate the user chat")
local anchorCountBeforeIdempotent = #chat
assert(ensureGameUiAnchor("main-hook-check") == 0
    and #chat == anchorCountBeforeIdempotent,
    "ensureGameUiAnchor duplicated an existing trailing anchor")

chat = {}
displayVars.helltrainUiAnchorIndexV1 = "0"
dropNextAddChat = true
local droppedAnchorOk = pcall(ensureGameUiAnchor, "main-hook-check")
assert(droppedAnchorOk == false and #chat == 0
    and displayVars.helltrainUiAnchorIndexV1 == "0",
    "ensureGameUiAnchor accepted a silent addChat failure")
assert(ensureGameUiAnchor("main-hook-check") == 0 and #chat == 1,
    "ensureGameUiAnchor did not recover after a silent addChat failure")

local authority
local stateReadFails = false
function getState(triggerId, key)
    assert(triggerId == "main-hook-check", "unexpected getState triggerId")
    assert(key == "battleRuntimeV1.authority", "editInput read an unexpected state key")
    if stateReadFails then error("injected state read failure") end
    return authority
end

assert(editInput("main-hook-check", "ordinary chat") == "ordinary chat",
    "editInput changed text outside a battle")
stateReadFails = true
assert(editInput("main-hook-check", "read failure") == "read failure",
    "editInput did not fail open when authority could not be read")
stateReadFails = false
authority = { schemaVersion = 1, kind = "battleState", status = "active" }
assert(editInput("main-hook-check", "typed battle text") == "*says nothing*",
    "editInput did not normalize active battle text to the exact filler")
authority.status = "victory"
assert(editInput("main-hook-check", "post-battle text") == "*says nothing*",
    "editInput did not keep an initialized battle session input-free")

local calls = {}
local responder
runScript = function(triggerId, script, action, ...)
    calls[#calls + 1] = {
        triggerId = triggerId,
        script = script,
        action = action,
        arguments = { ... },
    }
    return responder(triggerId, script, action, ...)
end

local hostPrint = print
local logLines = {}
print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = tostring(select(index, ...))
    end
    logLines[#logLines + 1] = table.concat(parts, " ")
end

local function lastCall(expectedAction)
    local call = assert(calls[#calls], "missing controller call")
    assert(call.triggerId == "main-hook-check", "controller call used the wrong triggerId")
    assert(call.script == "battleController", "controller call used the wrong lore script")
    assert(call.action == expectedAction, "expected action " .. expectedAction .. ", got " .. tostring(call.action))
    return call
end

responder = function()
    return { ok = true, generationReady = true, errors = {} }
end
assert(onStart("main-hook-check") == true, "generation-ready onStart did not allow the request")
lastCall("prepareGeneration")

chat = { { role = "char", data = "recovered scene" } }
displayVars.helltrainUiAnchorIndexV1 = "0"
targetedReloads = {}
responder = function()
    return { ok = true, generationReady = false, commitRecovered = true, errors = {} }
end
assert(onStart("main-hook-check") == false, "commit-only recovery did not cancel the new request")
lastCall("prepareGeneration")
assert(#chat == 2 and chat[1].role == "char" and chat[2].role == "user"
    and chat[2].data == "@@HELLTRAIN_UI_ANCHOR_V1@@"
    and displayVars.helltrainUiAnchorIndexV1 == "1"
    and targetedReloads[1] == 0 and targetedReloads[2] == 1,
    "commit-only recovery did not append the UI after the preserved scene")

chat = { { role = "char", data = "anchor repair scene" } }
displayVars.helltrainUiAnchorIndexV1 = "0"
responder = function()
    return { ok = true, generationReady = false, uiAnchorRequired = true, errors = {} }
end
assert(onStart("main-hook-check") == false and #chat == 2
    and chat[2].role == "user" and chat[2].data == "@@HELLTRAIN_UI_ANCHOR_V1@@",
    "UI-only repair did not cancel generation and restore the user anchor")
lastCall("prepareGeneration")

responder = function()
    return {
        ok = false,
        errors = {
            { code = "injected_failure", path = "$.test", message = "expected" },
        },
    }
end
assert(onStart("main-hook-check") == false, "failed preparation did not cancel the request")
lastCall("prepareGeneration")
assert(#logLines > 0 and string.find(logLines[#logLines], "injected_failure", 1, true),
    "structured controller failure was not logged")

responder = function() return nil end
assert(onStart("main-hook-check") == false, "missing controller report did not cancel the request")
lastCall("prepareGeneration")

local originalPrompt = {
    { role = "system", content = "preset" },
}
local injectedPrompt = {
    { role = "system", content = "preset" },
    { role = "system", content = "private turn event" },
    { role = "user", content = "private scene request" },
}
responder = function(triggerId, script, action, prompt)
    assert(prompt == originalPrompt, "editRequest did not pass its original prompt object")
    return { ok = true, promptArray = injectedPrompt, errors = {} }
end
assert(editRequest("main-hook-check", originalPrompt) == injectedPrompt,
    "successful editRequest did not return the injected prompt")
lastCall("injectRequest")

responder = function()
    return {
        ok = false,
        errors = {
            { code = "injection_failed", path = "$.test", message = "expected" },
        },
    }
end
assert(editRequest("main-hook-check", originalPrompt) == originalPrompt,
    "failed editRequest did not preserve the original prompt")
lastCall("injectRequest")

responder = function()
    return { ok = true, errors = {} }
end
assert(editRequest("main-hook-check", originalPrompt) == originalPrompt,
    "malformed successful editRequest did not preserve the original prompt")
lastCall("injectRequest")

chat = { { role = "char", data = "normal output scene" } }
displayVars.helltrainUiAnchorIndexV1 = "0"
targetedReloads = {}
responder = function()
    return { ok = true, outputCommitted = true, errors = {} }
end
onOutput("main-hook-check")
lastCall("commitOutput")
assert(#chat == 2 and chat[1].role == "char" and chat[2].role == "user"
    and chat[2].data == "@@HELLTRAIN_UI_ANCHOR_V1@@"
    and displayVars.helltrainUiAnchorIndexV1 == "1"
    and targetedReloads[1] == 0 and targetedReloads[2] == 1,
    "successful onOutput did not place the next UI after the scene")
local chatCountBeforeDuplicateOutput = #chat
onOutput("main-hook-check")
lastCall("commitOutput")
assert(#chat == chatCountBeforeDuplicateOutput,
    "duplicate successful onOutput appended another UI anchor")

chat = { { role = "char", data = "failed commit scene" } }
displayVars.helltrainUiAnchorIndexV1 = "0"
responder = function()
    return {
        ok = false,
        errors = {
            { code = "commit_failed", path = "$.test", message = "expected" },
        },
    }
end
onOutput("main-hook-check")
lastCall("commitOutput")
assert(#chat == 1 and chat[1].data == "failed commit scene",
    "failed onOutput changed the chat or appended a UI anchor")
assert(string.find(logLines[#logLines], "commit_failed", 1, true),
    "onOutput failure was not logged")

chat = {}
displayVars.helltrainUiAnchorIndexV1 = nil
targetedReloads = {}
responder = function(triggerId, script, action)
    assert(script == "init" and action == "start", "unexpected setup start route")
    return { ok = true, errors = {} }
end
onButtonClick("main-hook-check", "init|start")
local startCall = assert(calls[#calls], "missing setup start controller call")
assert(startCall.script == "init" and startCall.action == "start"
    and #chat == 1 and chat[1].role == "user"
    and chat[1].data == "@@HELLTRAIN_UI_ANCHOR_V1@@"
    and displayVars.helltrainUiAnchorIndexV1 == "0",
    "successful game start did not create the deck-building user UI chat")
onButtonClick("main-hook-check", "init|start")
assert(#chat == 1, "repeated successful game start duplicated the UI anchor")

responder = function(triggerId, script, action, first, second)
    return { triggerId, script, action, first, second }
end
onButtonClick("main-hook-check", "battleController|clickCard|card-001|draftv1-token")
local buttonCall = lastCall("clickCard")
assert(buttonCall.arguments[1] == "card-001" and buttonCall.arguments[2] == "draftv1-token",
    "button dispatch did not preserve its two arguments")

onButtonClick("main-hook-check", "battleController|registerCard|card-002|draftv1-register")
local registerCall = lastCall("registerCard")
assert(registerCall.arguments[1] == "card-002" and registerCall.arguments[2] == "draftv1-register",
    "register route did not preserve instanceId/token")
onButtonClick("main-hook-check", "battleController|cancelCard|card-002|draftv1-cancel")
local cancelCall = lastCall("cancelCard")
assert(cancelCall.arguments[1] == "card-002" and cancelCall.arguments[2] == "draftv1-cancel",
    "cancel route did not preserve instanceId/token")

onButtonClick("main-hook-check", "init|chooseCharacter|yoo_jiyoung|game-setup-character-v1:1:2:3")
local characterCall = assert(calls[#calls], "missing character selection controller call")
assert(characterCall.triggerId == "main-hook-check"
        and characterCall.script == "init"
        and characterCall.action == "chooseCharacter"
        and characterCall.arguments[1] == "yoo_jiyoung"
        and characterCall.arguments[2] == "game-setup-character-v1:1:2:3",
    "character selection route did not preserve characterId/token")

local callsBeforeDenied = #calls
onButtonClick("main-hook-check", "dataBridge|_publishCanonical|battleView|forged")
assert(#calls == callsBeforeDenied, "button dispatcher exposed an internal module route")
onButtonClick("main-hook-check", "init|start|unexpected")
assert(#calls == callsBeforeDenied, "button dispatcher accepted an invalid start argument count")
onButtonClick("main-hook-check", "init|chooseCharacter|yoo_jiyoung")
assert(#calls == callsBeforeDenied, "button dispatcher accepted an invalid chooseCharacter argument count")

hostPrint("MAIN_HOOK|scenarios=35")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[main-hook-check]],[[t]],_G))()'
    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The Lua main hook check failed.`n$($firstOutput -join "`n")"
    }
    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The second Lua main hook check failed.`n$($secondOutput -join "`n")"
    }
    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "Separate Lua processes produced different main hook results.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -notmatch '^MAIN_HOOK\|scenarios=35$') {
        throw "Unexpected main hook vector: $firstText"
    }
    Write-Output 'main-hook-check: ok'
    Write-Output 'NOTE: actual RisuAI hook ordering, editInput routing, permissions, and HTTP cancellation still require host integration testing.'
}
finally {
    Pop-Location
}
