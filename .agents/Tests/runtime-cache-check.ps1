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

local scriptSources = {}
local loreOverrides = {}
local scriptLoreFetches = {}
local dbLoreFetchCount = 0
local eventChats = {}
local eventCharacters = {}
local chatVariables = {}
local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
}

local function chatIdForEvent(triggerId)
    return eventChats[triggerId] or triggerId
end

function getChatVar(triggerId, name)
    local chatId = chatIdForEvent(triggerId)
    local values = chatVariables[chatId]
    return values and values[name] or nil
end

function setChatVar(triggerId, name, value)
    local chatId = chatIdForEvent(triggerId)
    chatVariables[chatId] = chatVariables[chatId] or {}
    chatVariables[chatId][name] = value
end

function getName(triggerId)
    return eventCharacters[triggerId] or "character-a"
end

function getCharacterFirstMessage(triggerId)
    return "first-message:" .. (eventCharacters[triggerId] or "character-a")
end

function getLoreBooks(triggerId, loreName)
    local scriptName = string.match(loreName, "^(.-)%.lua$")
    if scriptName ~= nil then
        scriptLoreFetches[scriptName] = (scriptLoreFetches[scriptName] or 0) + 1
        local source = scriptSources[scriptName]
        if source == nil and scriptName == "staticData" then
            source = readFile("System/staticData.lua")
        end
        return source and { { content = source } } or {}
    end

    local path = lorePaths[loreName]
    if path == nil then
        return {}
    end
    dbLoreFetchCount = dbLoreFetchCount + 1
    return { { content = loreOverrides[loreName] or readFile(path) } }
end

local function beginEvent(triggerId, chatId, characterId, mode)
    eventChats[triggerId] = chatId
    eventCharacters[triggerId] = characterId or "character-a"
    beginRunScriptEvent(triggerId, mode or "onButtonClick")
end

assert(load(readFile("System/main.lua"), "@System/main.lua", "t", _G))()
DEBUG = 0

local nativeLoad = load
local loreCompileCount = 0
local staticDbCompileCount = 0
load = function(source, chunkName, mode, environment)
    if type(chunkName) == "string" and string.find(chunkName, "lore_function:", 1, true) == 1 then
        loreCompileCount = loreCompileCount + 1
    elseif type(chunkName) == "string" and string.find(chunkName, "static_db:", 1, true) == 1 then
        staticDbCompileCount = staticDbCompileCount + 1
    end
    return nativeLoad(source, chunkName, mode, environment)
end

local versionOne = "(function(triggerId, value) return tostring(value) .. ':v1' end)"
local versionTwo = "(function(triggerId, value) return tostring(value) .. ':v2' end)"
local versionThree = "(function(triggerId, value) return tostring(value) .. ':v3' end)"
local versionFour = "(function(triggerId, value) return tostring(value) .. ':v4' end)"
scriptSources.fixture = versionOne

beginEvent("event-a1", "chat-a", "character-a")
for index = 1, 50 do
    assert(runScript("event-a1", "fixture", index) == tostring(index) .. ":v1")
end
assert(scriptLoreFetches.fixture == 1,
    "nested runScript calls fetched lore more than once in one host transaction")
assert(loreCompileCount == 1, "same transaction compiled its module more than once")

beginEvent("event-a2", "chat-a", "character-a")
assert(runScript("event-a2", "fixture", "warm") == "warm:v1")
assert(scriptLoreFetches.fixture == 1,
    "production warm path fetched lore again across events")

-- production에서는 lore source 편집만으로 기존 warm handler를 바꾸지 않는다.
-- 배포 revision을 올리거나 development bypass를 사용해야 한다.
scriptSources.fixture = versionTwo
beginEvent("event-a3", "chat-a", "character-a")
assert(runScript("event-a3", "fixture", "stale-contract") == "stale-contract:v1")
assert(scriptLoreFetches.fixture == 1, "production warm contract unexpectedly re-read lore")

RUNTIME_BUNDLE_REVISION = "runtime-cache-test-v2"
beginEvent("event-a4", "chat-a", "character-a")
assert(runScript("event-a4", "fixture", "revision") == "revision:v2")
assert(scriptLoreFetches.fixture == 2, "bundle revision did not invalidate the warm handler")
assert(loreCompileCount == 2, "hot-reloaded source did not compile separately")

assert(setRunScriptCacheDevelopmentMode(true) == true)
scriptSources.fixture = versionThree
beginEvent("event-a5", "chat-a", "character-a")
assert(runScript("event-a5", "fixture", "dev") == "dev:v3")
assert(runScript("event-a5", "fixture", "nested") == "nested:v3")
assert(scriptLoreFetches.fixture == 3,
    "development transaction fetched the same module more than once")
scriptSources.fixture = versionFour
beginEvent("event-a6", "chat-a", "character-a")
assert(runScript("event-a6", "fixture", "edited") == "edited:v4")
beginEvent("event-a7", "chat-a", "character-a")
assert(runScript("event-a7", "fixture", "same") == "same:v4")
assert(scriptLoreFetches.fixture == 5,
    "development mode did not re-read source once per event")
assert(loreCompileCount == 4,
    "development exact-source cache did not reuse unchanged compiled source")

assert(setRunScriptCacheDevelopmentMode(false) == false)
beginEvent("event-a8", "chat-a", "character-a")
assert(runScript("event-a8", "fixture", "production-again") == "production-again:v4")
assert(scriptLoreFetches.fixture == 6,
    "leaving development mode reused a stale production warm handler")
assert(loreCompileCount == 4, "production warm rebuild did not reuse compiled v4 source")

local statefulSource = [[(function()
    local calls = 0
    return function()
        calls = calls + 1
        return calls
    end
end)()]]
scriptSources.stateful = statefulSource
beginEvent("event-state-a1", "chat-a", "character-a")
assert(runScript("event-state-a1", "stateful") == 1)
beginEvent("event-state-a2", "chat-a", "character-a")
assert(runScript("event-state-a2", "stateful") == 2,
    "same context did not reuse its warm handler")
beginEvent("event-state-b1", "chat-b", "character-a")
assert(runScript("event-state-b1", "stateful") == 1,
    "mutable handler closure leaked into another chat")
beginEvent("event-state-a3", "chat-a", "character-b")
assert(runScript("event-state-a3", "stateful") == 1,
    "mutable handler closure leaked into another character context")
assert(scriptLoreFetches.stateful == 3 and loreCompileCount == 5,
    "context isolation did not share only the compiled chunk")

local beforeBroken = getRunScriptCacheDiagnostics()
scriptSources.broken = "(function("
beginEvent("event-error-1", "chat-a", "character-a")
assert(runScript("event-error-1", "broken") == nil)
assert(runScript("event-error-1", "broken") == nil)
local afterBroken = getRunScriptCacheDiagnostics()
assert(afterBroken.compileFailures == beforeBroken.compileFailures + 2,
    "compile failures were cached")

scriptSources.invalid = "({})"
beginEvent("event-error-2", "chat-a", "character-a")
assert(runScript("event-error-2", "invalid") == nil)
assert(runScript("event-error-2", "invalid") == nil)
local afterInvalid = getRunScriptCacheDiagnostics()
assert(afterInvalid.invalidHandlers == 2, "non-handler results were cached")

scriptSources.loadFailure = "(function() error('load boom') end)()"
beginEvent("event-error-3", "chat-a", "character-a")
assert(runScript("event-error-3", "loadFailure") == nil)
assert(runScript("event-error-3", "loadFailure") == nil)
local afterLoadFailure = getRunScriptCacheDiagnostics()
assert(afterLoadFailure.loadFailures == 2, "handler load failures were cached")

scriptSources.execFailure = "(function() error('exec boom') end)"
beginEvent("event-error-4", "chat-a", "character-a")
assert(runScript("event-error-4", "execFailure") == nil)
assert(runScript("event-error-4", "execFailure") == nil)
local execFetches = scriptLoreFetches.execFailure
beginEvent("event-error-5", "chat-a", "character-a")
assert(runScript("event-error-5", "execFailure") == nil)
local afterExecFailure = getRunScriptCacheDiagnostics()
assert(afterExecFailure.executionFailures == 3, "execution failures were not diagnosed")
assert(scriptLoreFetches.execFailure == execFetches,
    "valid throwing handler was not retained in the warm cache")

for _, entry in ipairs(afterExecFailure.sources) do
    assert(entry.source == nil and entry.handler == nil, "diagnostics leaked executable source or handler")
    assert(type(entry.sourceFingerprint) == "string" and type(entry.sourceLength) == "number")
end

assert(clearRunScriptCache("fixture") == 4, "script-specific clear removed the wrong source entries")
scriptSources.fixture = versionFour
beginEvent("event-a9", "chat-a", "character-a")
assert(runScript("event-a9", "fixture", "cleared") == "cleared:v4")
assert(loreCompileCount == 13, "cleared handler was not compiled again")

beginEvent("event-static-a", "chat-a", "character-a")
local firstStatic = assert(runScript("event-static-a", "staticData", "loadAll"))
assert(firstStatic.ok == true and firstStatic.data.cards.accidental_brush.prototype == true)
local initialDbCompiles = staticDbCompileCount
local initialDbFetches = dbLoreFetchCount
assert(initialDbCompiles == 6, "unexpected first static DB compile count: " .. tostring(initialDbCompiles))
assert(initialDbFetches == 6, "unexpected first static DB lore fetch count")

firstStatic.data.cards.accidental_brush.name = "POISONED_CACHE"
firstStatic.data.registry.actionTags.approach.label = "POISONED_REGISTRY"
beginEvent("event-static-b", "chat-a", "character-a")
local secondStatic = assert(runScript("event-static-b", "staticData", "loadAll"))
assert(secondStatic.data.cards.accidental_brush.name ~= "POISONED_CACHE",
    "caller mutation poisoned cached static card data")
assert(secondStatic.data.registry.actionTags.approach.label ~= "POISONED_REGISTRY",
    "caller mutation poisoned cached registry data")
assert(staticDbCompileCount == initialDbCompiles, "static cache hit recompiled DB chunks")
assert(dbLoreFetchCount == initialDbFetches,
    "production static snapshot hit fetched DB lore again")

beginEvent("event-static-c", "chat-a", "character-a")
local validationOnly = assert(runScript("event-static-c", "staticData", "validateAll"))
assert(validationOnly.ok == true and validationOnly.data == nil)
assert(staticDbCompileCount == initialDbCompiles, "validateAll did not share the successful snapshot")
assert(dbLoreFetchCount == initialDbFetches, "validateAll fetched DB lore on the warm path")
beginEvent("event-static-d", "chat-a", "character-a")
local staticStats = assert(runScript("event-static-d", "staticData", "cacheStats")).cache
assert(staticStats.entries == 1 and staticStats.validations == 1 and staticStats.hits == 2)

loreOverrides["PlayerCards.db"] = "return {"
beginEvent("event-static-e", "chat-a", "character-a")
local badOne = assert(runScript("event-static-e", "staticData", "reloadAll"))
beginEvent("event-static-f", "chat-a", "character-a")
local badTwo = assert(runScript("event-static-f", "staticData", "reloadAll"))
assert(badOne.ok == false and badTwo.ok == false, "invalid DB unexpectedly validated")
beginEvent("event-static-g", "chat-a", "character-a")
local failedStats = assert(runScript("event-static-g", "staticData", "cacheStats")).cache
assert(failedStats.failedValidations == 2 and failedStats.validations == 3,
    "failed DB validation was cached")

loreOverrides["PlayerCards.db"] = nil
beginEvent("event-static-h", "chat-a", "character-a")
local restored = assert(runScript("event-static-h", "staticData", "loadAll"))
assert(restored.ok == true and restored.data.cards.accidental_brush.prototype == true)
local restoredCompileCount = staticDbCompileCount
assert(restoredCompileCount == initialDbCompiles + 12,
    "restored exact DB source did not reuse the prior successful snapshot")
assert(dbLoreFetchCount == initialDbFetches + 12,
    "failed forced validations did not perform their DB source reads")

local changedPlayerCards, replacementCount = string.gsub(
    readFile("DB/PlayerCards.db"),
    "prototype = true",
    "prototype = false",
    1
)
assert(replacementCount == 1, "valid hot-reload fixture replacement failed")
loreOverrides["PlayerCards.db"] = changedPlayerCards
beginEvent("event-static-i", "chat-a", "character-a")
local productionStale = assert(runScript("event-static-i", "staticData", "loadAll"))
assert(productionStale.ok == true and productionStale.data.cards.subtle_approach.prototype == true,
    "production snapshot bypassed the explicit revision/refresh contract")
assert(dbLoreFetchCount == initialDbFetches + 12,
    "production static warm path fetched a changed DB without refresh")
beginEvent("event-static-i-refresh", "chat-a", "character-a")
local changed = assert(runScript("event-static-i-refresh", "staticData", "reloadAll"))
assert(changed.ok == true and changed.data.cards.subtle_approach.prototype == false,
    "forced valid DB refresh returned a stale snapshot")
assert(staticDbCompileCount == restoredCompileCount + 6,
    "valid forced DB refresh did not perform exactly one new validation")

loreOverrides["PlayerCards.db"] = nil
beginEvent("event-static-j", "chat-a", "character-a")
local changedWarm = assert(runScript("event-static-j", "staticData", "loadAll"))
assert(changedWarm.data.cards.subtle_approach.prototype == false,
    "production warm snapshot unexpectedly self-refreshed")
beginEvent("event-static-j-refresh", "chat-a", "character-a")
local restoredAgain = assert(runScript("event-static-j-refresh", "staticData", "reloadAll"))
assert(restoredAgain.data.cards.subtle_approach.prototype == true,
    "forced DB restore reused another static snapshot")
assert(staticDbCompileCount == restoredCompileCount + 6,
    "return to exact DB source missed its isolated cache entry")

beginEvent("event-static-k", "chat-a", "character-a")
local clearedStatic = assert(runScript("event-static-k", "staticData", "clearCache"))
assert(clearedStatic.ok == true and clearedStatic.removed == 2)
beginEvent("event-static-l", "chat-a", "character-a")
assert(runScript("event-static-l", "staticData", "loadAll").ok == true)
assert(staticDbCompileCount == restoredCompileCount + 12,
    "explicit static cache clear did not force revalidation")

beginEvent("event-static-m", "chat-a", "character-a")
local finalStaticStats = assert(runScript("event-static-m", "staticData", "cacheStats")).cache
assert(dbLoreFetchCount == 36, "unexpected production DB lore fetch total")

local beforeDevelopmentDbFetches = dbLoreFetchCount
assert(setRunScriptCacheDevelopmentMode(true) == true)
beginEvent("event-static-dev-a", "chat-a", "character-a")
assert(runScript("event-static-dev-a", "staticData", "loadAll").ok == true)
beginEvent("event-static-dev-b", "chat-a", "character-a")
assert(runScript("event-static-dev-b", "staticData", "loadAll").ok == true)
assert(dbLoreFetchCount == beforeDevelopmentDbFetches + 12,
    "development bypass did not rebuild static data once per event")
assert(setRunScriptCacheDevelopmentMode(false) == false)

local finalRunStats = getRunScriptCacheDiagnostics()
local summaryCompileCount = loreCompileCount
for index = 1, 140 do
    local scriptName = "limitFixture" .. tostring(index)
    scriptSources[scriptName] = versionOne
    beginEvent("event-limit-" .. tostring(index), "chat-limit", "character-a")
    assert(runScript("event-limit-" .. tostring(index), scriptName, index) == tostring(index) .. ":v1")
end
local limitStats = getRunScriptCacheDiagnostics()
assert(limitStats.sourceEntries == 64 and limitStats.warmEntries == 128,
    "runtime cache entry bounds were not enforced")
assert(limitStats.sourceEvictions > 0 and limitStats.warmEvictions > 0,
    "runtime cache LRU eviction was not exercised")
print(string.format(
    "RUNTIME_CACHE|compiles=%d|txHits=%d|warmHits=%d|sourceFetches=%d|dbValidations=%d|dbHits=%d|devDbReloads=%d",
    summaryCompileCount,
    finalRunStats.transactionHits,
    finalRunStats.warmHits,
    finalRunStats.sourceFetches,
    finalStaticStats.validations,
    finalStaticStats.hits,
    dbLoreFetchCount - beforeDevelopmentDbFetches
))
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[runtime-cache-check]],[[t]],_G))()'
    $output = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The runtime cache check failed.`n$($output -join "`n")"
    }
    $text = $output -join "`n"
    if ($text -notmatch '^RUNTIME_CACHE\|compiles=14\|txHits=51\|warmHits=18\|sourceFetches=20\|dbValidations=5\|dbHits=6\|devDbReloads=12$') {
        throw "Unexpected runtime cache vector: $text"
    }
    Write-Output 'runtime-cache-check: ok'
    Write-Output $text
    Write-Output 'NOTE: actual RisuAI mode lifetime and lore hot reload still require host integration testing.'
}
finally {
    Pop-Location
}
