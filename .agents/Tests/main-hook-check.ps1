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

responder = function()
    return { ok = true, generationReady = false, commitRecovered = true, errors = {} }
end
assert(onStart("main-hook-check") == false, "commit-only recovery did not cancel the new request")
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

responder = function()
    return { ok = true, errors = {} }
end
onOutput("main-hook-check")
lastCall("commitOutput")

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
assert(string.find(logLines[#logLines], "commit_failed", 1, true),
    "onOutput failure was not logged")

responder = function(triggerId, script, action, first, second)
    return { triggerId, script, action, first, second }
end
onButtonClick("main-hook-check", "battleController|clickCard|card-001|draftv1-token")
local buttonCall = lastCall("clickCard")
assert(buttonCall.arguments[1] == "card-001" and buttonCall.arguments[2] == "draftv1-token",
    "button dispatch did not preserve its two arguments")

hostPrint("MAIN_HOOK|scenarios=14")
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
    if ($firstText -notmatch '^MAIN_HOOK\|scenarios=14$') {
        throw "Unexpected main hook vector: $firstText"
    }
    Write-Output 'main-hook-check: ok'
    Write-Output 'NOTE: actual RisuAI hook ordering, editInput routing, permissions, and HTTP cancellation still require host integration testing.'
}
finally {
    Pop-Location
}
