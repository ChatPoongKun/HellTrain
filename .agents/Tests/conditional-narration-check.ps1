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
if (-not $luaHost) { throw 'Lua 실행기를 찾을 수 없습니다.' }

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

local modules = {}
for _, name in ipairs({
    "battleBootstrap", "battleHistory", "battleRuntime", "cardZones", "characterSelector",
    "deterministicRng", "effectEngine", "stateSchema", "staticData", "subwayJourney",
    "triggerPipeline", "turnDraft", "turnEventProjector", "turnInitializer",
    "turnPresentation", "turnPromptFormatter", "turnResolver",
}) do
    modules[name] = loadLore("System/" .. name .. ".lua")
end

function runScript(triggerId, name, ...)
    return assert(modules[name], "unknown module: " .. tostring(name))(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["TokyoSubwayLines.db"] = "DB/TokyoSubwayLines.db",
    ["CharacterList.db"] = "Char/CharacterList.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
    ["YoonSeoa.db"] = "Char/YoonSeoa.db",
    ["HanJenny.db"] = "Char/HanJenny.db",
    ["SeoMiryeong.db"] = "Char/SeoMiryeong.db",
    ["SisterAgnes.db"] = "Char/SisterAgnes.db",
}

function getLoreBooks(_, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end

function loadLores(triggerId, name)
    local chunks = {}
    for _, lore in ipairs(getLoreBooks(triggerId, name)) do chunks[#chunks + 1] = lore.content end
    return #chunks > 0 and table.concat(chunks) or nil
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local errors = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            errors[#errors + 1] = tostring(item.code) .. " at " .. tostring(item.path)
        end
        error(label .. " failed: " .. table.concat(errors, ", "))
    end
    return report
end

local staticData = assertOk("static data", runScript("conditional-narration", "staticData", "loadAll")).data
local card = assert(staticData.cards.pc_glutton_003)
assert(type(card.narrationCondition) == "function", "conditional predicate missing")
assert(type(card.narration.play.conditionMet.actorAction) == "string", "met narration missing")

local function findPlayerCard(state)
    for _, instance in ipairs(state.cardInstances) do
        if instance.owner == "player" and instance.zone == "hand" and instance.cardId == card.id then
            return instance.instanceId
        end
    end
    error("conditional card was not drawn")
end

local function findEvent(events, eventType, predicate)
    for _, event in ipairs(events) do
        if event.type == eventType and predicate(event) then return event end
    end
    error("event missing: " .. eventType)
end

local function runCase(label, characterId, expectedMet)
    local deck = {
        "pc_glutton_001", "pc_glutton_002", "pc_glutton_003", "pc_glutton_004", "pc_glutton_005",
        "pc_glutton_006", "pc_glutton_007", "pc_glutton_008", "pc_glutton_009", "pc_glutton_010",
    }
    local state = assertOk(label .. " bootstrap", runScript("conditional-narration", "battleBootstrap", "fromSetup", {
        battleId = "conditional-narration-" .. label,
        seed = expectedMet and 20260831 or 20260830,
        playerCardIds = deck,
        characterId = characterId,
    }, staticData)).state
    state.player.maxHandSize = #deck
    assertOk(label .. " expanded hand", runScript(
        "conditional-narration", "stateSchema", "validateBattleState", state, staticData
    ))
    state = assertOk(label .. " draw deck", runScript(
        "conditional-narration", "cardZones", "draw", state, "player", #deck
    )).state
    local turnId = state.battleId .. "-turn-001"
    local initialized = assertOk(label .. " initialize", runScript(
        "conditional-narration", "turnInitializer", "prepareTurn", state, staticData, { turnId = turnId }
    ))
    local draft = assertOk(label .. " register", runScript(
        "conditional-narration", "turnDraft", "registerCard", initialized.state, staticData,
        initialized.draft, findPlayerCard(initialized.state)
    )).draft
    local projection = assertOk(label .. " draft", runScript(
        "conditional-narration", "turnDraft", "project", initialized.state, staticData, draft
    )).projection
    local pending = assertOk(label .. " pending", runScript(
        "conditional-narration", "battleRuntime", "preparePending", initialized.state, staticData, projection
    )).pendingTurn

    local raw = findEvent(pending.turnResult.events, "card_declared", function(event)
        return event.side == "player" and event.payload.cardId == card.id
    end)
    assert(raw.payload.narrationConditionMet == expectedMet, label .. " raw condition result changed")

    local action = findEvent(pending.turnResult.llmEvent.events, "action", function(event)
        return event.payload.actor == "player"
    end)
    local expectedAction = expectedMet and card.narration.play.conditionMet.actorAction or card.narration.play.actorAction
    assert(action.payload.actorAction == expectedAction, label .. " projected narration branch changed")

    local public = findEvent(pending.turnResult.publicResult.events, "card_declared", function(event)
        return event.payload.side == "player"
    end)
    assert(public.payload.narrationConditionMet == nil, label .. " leaked internal condition result")

    local formatted = assertOk(label .. " prompt", runScript(
        "conditional-narration", "turnPromptFormatter", "formatPending", pending, staticData
    ))
    assert(string.find(formatted.message.content, expectedAction, 1, true), label .. " prompt omitted narration")
end

runCase("unmet", "yoo_jiyoung", false)
runCase("met", "yoon_seoa", true)
print("CONDITIONAL_NARRATION|unmet=ignore|met=suspicion|prompt=ok")
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[conditional-narration-check]],[[t]],_G))()'
    $output = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "조건부 내러티브 검사가 실패했습니다.`n$($output -join "`n")" }
    if (($output -join "`n") -cne 'CONDITIONAL_NARRATION|unmet=ignore|met=suspicion|prompt=ok') {
        throw "조건부 내러티브 표식이 예상과 다릅니다: $($output -join "`n")"
    }
    Write-Output 'conditional-narration-check: ok'
}
finally {
    Pop-Location
}
