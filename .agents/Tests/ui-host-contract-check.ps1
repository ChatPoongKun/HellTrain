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
if (-not $luaHost) { throw 'A Lua host is required.' }

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

local chatVars = {}
local states = {}
local calls = {}
json = { encode = function() return "{}" end }

function debug() end
function getChatVar(_, name) return chatVars[name] end
function setChatVar(_, name, value) chatVars[name] = value end
function getState(_, name) return states[name] end
function setState(_, name, value) states[name] = value end
function loadLores(_, name) return "<" .. tostring(name) .. ">" end

local modules = {
    uiRender = loadLore("System/uiRender.lua"),
    popupManage = loadLore("System/popupManage.lua"),
    ["캐릭터 프로필"] = function(triggerId, characterName)
        assert(characterName == "유지영")
        setChatVar(triggerId, "helltrainUiPopupV1", "<캐릭터 프로필.html>")
    end,
}

function runScript(triggerId, name, ...)
    calls[#calls + 1] = name
    local module = assert(modules[name], "unexpected module: " .. tostring(name))
    return module(triggerId, ...)
end

local function invoke(name, ...)
    return runScript("ui-host-contract", name, ...)
end

invoke("uiRender", "set", "battleui")
assert(chatVars["🔯🔯🔯"] == "<battleui.html>", "base UI was not set")
assert(chatVars.helltrainUiPopupV1 == nil, "base UI write polluted popup slot")

invoke("uiRender", "append", "도감")
assert(chatVars["🔯🔯🔯"] == "<battleui.html>", "popup append copied or changed base UI")
assert(chatVars.helltrainUiPopupV1 == "<도감.html>", "legacy append route did not use popup slot")

invoke("popupManage", "root", "uiRender", "append", "설정")
assert(chatVars.helltrainUiPopupV1 == "<설정.html>", "allowed root popup was not rendered")
assert(states.popupState.current.script == "uiRender", "allowed root popup state was not stored")

local previousState = states.popupState
chatVars.helltrainUiPopupV1 = "keep"
invoke("popupManage", "root", "dataBridge", "publish", "battleView")
assert(chatVars.helltrainUiPopupV1 == "keep", "disallowed popup target changed markup")
assert(states.popupState == previousState, "disallowed popup target changed state")

invoke("popupManage", "push", "캐릭터 프로필", "유지영")
assert(chatVars.helltrainUiPopupV1 == "<캐릭터 프로필.html>", "profile popup did not use isolated slot")
assert(#states.popupState.history == 1, "profile push did not retain popup history")

invoke("popupManage", "back")
assert(chatVars.helltrainUiPopupV1 == "<설정.html>", "popup back did not restore previous markup")
invoke("popupManage", "close")
assert(chatVars.helltrainUiPopupV1 == "", "popup close did not clear isolated slot")
assert(states.popupState.current == nil and #states.popupState.history == 0, "popup close did not clear state")

print("ui-host-contract-check: ok")
'@

Push-Location $projectRoot
$luaTestPath = Join-Path ([System.IO.Path]::GetTempPath()) ("risu-ui-host-" + [guid]::NewGuid().ToString('N') + '.lua')
try {
    [System.IO.File]::WriteAllText($luaTestPath, $luaTest, [System.Text.UTF8Encoding]::new($false))
    $env:RISU_UI_HOST_LUA_PATH = $luaTestPath
    $luaEntry = 'assert(loadfile(os.getenv([[RISU_UI_HOST_LUA_PATH]])) or error([[missing UI host test file]]))()'
    $output = @(& $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "ui host contract check failed.`n$($output -join "`n")" }
    $output
} finally {
    Remove-Item Env:RISU_UI_HOST_LUA_PATH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $luaTestPath -Force -ErrorAction SilentlyContinue
    Pop-Location
}
