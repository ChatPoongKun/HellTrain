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
    triggerPipeline = loadLore("System/triggerPipeline.lua"),
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

local function clone(value, active)
    if type(value) ~= "table" then
        return value
    end
    active = active or {}
    assert(not active[value], "cycle in fixture")
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
    if value == nil then return "nil" end
    if valueType == "number" or valueType == "boolean" then return tostring(value) end
    if valueType == "string" then return string.format("%q", value) end
    assert(valueType == "table", "unsupported canonical value: " .. valueType)
    active = active or {}
    assert(not active[value], "cycle in canonical fixture")
    active[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        return type(left) .. ":" .. tostring(left) < type(right) .. ":" .. tostring(right)
    end)
    local values = {}
    for _, key in ipairs(keys) do
        values[#values + 1] = canonical(key, active) .. "=" .. canonical(value[key], active)
    end
    active[value] = nil
    return "{" .. table.concat(values, ",") .. "}"
end

local function failReport(label, report)
    local messages = {}
    for _, item in ipairs(type(report) == "table" and report.errors or {}) do
        messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path)
            .. ": " .. tostring(item.message)
    end
    error(label .. " failed\n" .. table.concat(messages, "\n"))
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        failReport(label, report)
    end
    assert(report.schemaVersion == 1, label .. " schema version changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    assert(type(report.state) == "table", label .. " omitted state")
    assert(type(report.transient) == "table", label .. " omitted transient")
    assert(type(report.records) == "table", label .. " omitted records")
    return report
end

local function assertHasError(label, report, code)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.state == nil and report.transient == nil and report.records == nil,
        label .. " leaked a partial result")
    for _, item in ipairs(type(report.errors) == "table" and report.errors or {}) do
        if item.code == code then
            return item
        end
    end
    failReport(label .. " missing " .. code, report)
end

local staticLoad = runScript("trigger-pipeline-check", "staticData", "loadAll")
if type(staticLoad) ~= "table" or staticLoad.ok ~= true then
    failReport("static data load", staticLoad)
end
local staticData = staticLoad.data

local function card(instanceId, cardId, owner, zone, position)
    return {
        instanceId = instanceId,
        cardId = cardId,
        owner = owner,
        zone = zone,
        position = position,
    }
end

local function planSlot(instanceId, cardId, charges)
    return {
        occupied = true,
        cardInstanceId = instanceId,
        cardId = cardId,
        placedTurn = 1,
        remainingTurns = 1,
        remainingCharges = charges or 1,
        revealed = false,
    }
end

local function makeState(options)
    options = options or {}
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = options.battleId or "pipeline-battle",
        status = "active",
        turnNumber = 1,
        turnLimit = 10,
        environmentId = "uncrowded",
        rng = { seed = 77, cursor = 0 },
        player = {
            stealth = options.stealth or 30,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = clone(options.perkIds or {}),
            planSlot = clone(options.playerPlan or { occupied = false }),
        },
        character = {
            characterId = "yoo_jiyoung",
            resistance = 30,
            mood = options.mood or "ignore",
            traitIds = clone(options.traitIds == nil and { "reserved" } or options.traitIds),
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = clone(options.characterPlan or { occupied = false }),
        },
        cardInstances = clone(options.cards or {}),
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local function run(label, data, state, transient, inputEvent, options)
    local beforeState = canonical(state)
    local beforeTransient = canonical(transient)
    local beforeEvent = canonical(inputEvent)
    local beforeOptions = canonical(options)
    local report = runScript(
        "trigger-pipeline-check",
        "triggerPipeline",
        "run",
        data,
        { state = state, transient = transient },
        inputEvent,
        options
    )
    assert(canonical(state) == beforeState, label .. " mutated input state")
    assert(canonical(transient) == beforeTransient, label .. " mutated input transient")
    assert(canonical(inputEvent) == beforeEvent, label .. " mutated input event")
    assert(canonical(options) == beforeOptions, label .. " mutated input options")
    return report
end

local function recordSequence(records, onlyResolved)
    local values = {}
    for _, record in ipairs(records) do
        assert(record.eventId == nil, "pipeline record created eventId")
        assert(record.sequence == nil, "pipeline record created sequence")
        assert(record.phase == nil, "pipeline record created phase")
        assert(record.resolutionId == nil, "pipeline record created resolutionId")
        assert(record.cause == nil, "pipeline record created cause")
        if not onlyResolved or record.type == "trigger_resolved" then
            values[#values + 1] = record.type .. ":" .. record.source.kind .. ":" .. record.source.id
        end
    end
    return table.concat(values, ",")
end

local function onlyRecord(records, recordType, sourceKind)
    local found = nil
    for _, record in ipairs(records) do
        if record.type == recordType and (sourceKind == nil or record.source.kind == sourceKind) then
            assert(found == nil, "multiple " .. recordType .. " records")
            found = record
        end
    end
    return assert(found, "missing " .. recordType .. " record")
end

-- Production character plan and environment both react to a player declaration.
local currentState = makeState({
    battleId = "pipeline-current",
    characterPlan = planSlot("current-glare", "silent_glare", 1),
    cards = {
        card("current-glare", "silent_glare", "character", "plan", 1),
    },
})
local currentTransient = { marker = "unchanged" }
local currentEvent = { type = "card_declared", side = "player", cardId = "accidental_brush" }
local currentOptions = {
    phase = "player_card",
    currentCard = {
        id = "accidental_brush",
        instanceId = "current-brush",
        owner = "player",
        actionTag = "contact",
    },
}
local current = assertOk(
    "current plan and environment",
    run("current plan and environment", staticData, currentState, currentTransient, currentEvent, currentOptions)
)
assert(current.state.player.stealth == 26, "current trigger effects changed")
assert(current.state.character.planSlot.occupied == false, "spent current plan remained occupied")
assert(current.state.cardInstances[1].zone == "discard", "spent current plan was not discarded")
assert(current.transient.marker == "unchanged", "pipeline dropped transient data")
assert(recordSequence(current.records, true)
    == "trigger_resolved:plan:silent_glare,trigger_resolved:environment:uncrowded",
    "current plan/environment order changed")
local currentPlan = onlyRecord(current.records, "plan_changed", "plan")
assert(currentPlan.payload.before.revealed == false, "plan receipt lost hidden before state")
assert(currentPlan.payload.after.occupied == false and currentPlan.payload.discarded == true,
    "plan receipt lost immediate discard")
assert(#currentPlan.payload.movedInstanceIds == 1
        and currentPlan.payload.movedInstanceIds[1] == "current-glare",
    "plan receipt lost moved instance")

-- The production player plan reacts to a side-less turn_start, reveals, consumes
-- one charge, and preserves its remaining lifetime when a charge remains.
local startState = makeState({
    battleId = "pipeline-turn-start",
    playerPlan = planSlot("start-subtle", "subtle_approach", 2),
    cards = {
        card("start-subtle", "subtle_approach", "player", "plan", 1),
    },
})
local startEvent = { type = "turn_start" }
local startOptions = { phase = "turn_start" }
local start = assertOk(
    "production side-less turn_start",
    run("production side-less turn_start", staticData, startState, {}, startEvent, startOptions)
)
assert(start.state.player.planSlot.occupied == true, "charged plan was discarded early")
assert(start.state.player.planSlot.revealed == true, "triggered plan was not revealed")
assert(start.state.player.planSlot.remainingCharges == 1, "plan charge was not consumed")
assert(start.state.character.moodTokens.ignore == 1,
    "production turn_start plan did not create its ignore token")
assert(type(start.transient.forcedMoodRequests) ~= "table"
        or #start.transient.forcedMoodRequests == 0,
    "production turn_start plan unexpectedly queued a force request")
local startChange = onlyRecord(start.records, "plan_changed", "plan")
assert(startChange.payload.discarded == false, "charged plan receipt reported discard")

-- Test-only content makes every category and side lane visible. The z_player ID
-- must precede a_character and m_ownerless by side rank, not ASCII rank. The
-- player trait condition also proves that all matching happens before the first
-- plan changes stealth.
local orderData = clone(staticData)
local function lose(amount, cause)
    return function(context, event)
        return {
            {
                op = "lose_stealth",
                target = "player",
                amount = amount,
                cause = cause,
            },
        }
    end
end
orderData.cards.subtle_approach.mechanismData.plan.event = "turn_start"
orderData.cards.subtle_approach.mechanismData.plan.trigger = nil
orderData.cards.subtle_approach.mechanismData.plan.resolve = lose(1, "order_player_plan")
orderData.cards.silent_glare.mechanismData.plan.event = "turn_start"
orderData.cards.silent_glare.mechanismData.plan.trigger = nil
orderData.cards.silent_glare.mechanismData.plan.resolve = lose(2, "order_character_plan")
orderData.traits = {
    a_character = {
        id = "a_character",
        owner = "character",
        triggers = { { event = "turn_start", resolve = lose(8, "order_character_trait") } },
    },
    m_ownerless = {
        id = "m_ownerless",
        triggers = { { event = "turn_start", resolve = lose(16, "order_ownerless_trait") } },
    },
    z_player = {
        id = "z_player",
        owner = "player",
        triggers = {
            {
                event = "turn_start",
                trigger = function(context, event)
                    return context.player.stealth == 30
                end,
                resolve = lose(4, "order_player_trait"),
            },
        },
    },
}
orderData.perks = {
    a_character = {
        id = "a_character",
        owner = "character",
        triggers = { { event = "turn_start", resolve = lose(32, "order_character_perk") } },
    },
    z_player = {
        id = "z_player",
        owner = "player",
        triggers = { { event = "turn_start", resolve = lose(24, "order_player_perk") } },
    },
}
orderData.environments.uncrowded.triggers = {
    { event = "turn_start", resolve = lose(64, "order_environment") },
}
local orderState = makeState({
    battleId = "pipeline-order",
    playerPlan = planSlot("order-subtle", "subtle_approach", 1),
    characterPlan = planSlot("order-glare", "silent_glare", 1),
    traitIds = { "a_character", "m_ownerless", "z_player" },
    perkIds = { "a_character", "z_player" },
    cards = {
        card("order-subtle", "subtle_approach", "player", "plan", 1),
        card("order-glare", "silent_glare", "character", "plan", 1),
    },
})
local ordered = assertOk(
    "side-less total order and snapshot",
    run("side-less total order and snapshot", orderData, orderState, {}, { type = "turn_start" }, {})
)
local orderedSequence = recordSequence(ordered.records, true)
assert(orderedSequence == table.concat({
    "trigger_resolved:plan:subtle_approach",
    "trigger_resolved:plan:silent_glare",
    "trigger_resolved:trait:z_player",
    "trigger_resolved:trait:a_character",
    "trigger_resolved:trait:m_ownerless",
    "trigger_resolved:perk:z_player",
    "trigger_resolved:perk:a_character",
    "trigger_resolved:environment:uncrowded",
}, ","), "side-less category/side order changed: " .. orderedSequence)
assert(ordered.state.player.stealth == -121, "snapshot/order fixture final stealth changed")

-- Insight suppresses only the opposing plan. It preserves internal source IDs,
-- does not reveal or consume the plan, and still runs the environment.
local insightState = makeState({
    battleId = "pipeline-insight",
    characterPlan = planSlot("insight-glare", "silent_glare", 1),
    cards = {
        card("insight-glare", "silent_glare", "character", "plan", 1),
    },
})
local insight = assertOk(
    "insight",
    run(
        "insight",
        staticData,
        insightState,
        {},
        { type = "card_declared", side = "player" },
        { phase = "player_card", insightSide = "player" }
    )
)
assert(insight.state.player.stealth == 29, "insight suppressed the environment or applied the plan")
assert(insight.state.character.planSlot.occupied == true
        and insight.state.character.planSlot.revealed == false
        and insight.state.character.planSlot.remainingCharges == 1,
    "insight changed the opposing plan")
assert(insight.records[1].type == "trigger_suppressed", "insight suppression order changed")
assert(insight.records[1].source.id == "silent_glare"
        and insight.records[1].source.instanceId == "insight-glare",
    "internal insight receipt lost plan identity")
assert(insight.records[1].payload.hidden == true
        and insight.records[1].payload.reasonCode == "insight",
    "insight receipt payload changed")

-- Disallowed gameplay commands fail atomically. A commandless plan may still
-- resolve, reveal, consume its charge, and be discarded in that mode.
local forbiddenData = clone(staticData)
forbiddenData.environments.uncrowded.triggers = {
    { event = "session_end", resolve = lose(1, "forbidden_session_command") },
}
local forbiddenState = makeState({ battleId = "pipeline-forbidden" })
assertHasError(
    "allowGameplayCommands false",
    run(
        "allowGameplayCommands false",
        forbiddenData,
        forbiddenState,
        {},
        { type = "session_end" },
        { phase = "session_end", allowGameplayCommands = false }
    ),
    "unsupported_session_end_commands"
)

local commandlessData = clone(staticData)
commandlessData.cards.subtle_approach.mechanismData.plan.event = "session_end"
commandlessData.cards.subtle_approach.mechanismData.plan.trigger = nil
commandlessData.cards.subtle_approach.mechanismData.plan.resolve = function(context, event)
    return {}
end
commandlessData.environments.uncrowded.triggers = {}
local commandlessState = makeState({
    battleId = "pipeline-commandless",
    playerPlan = planSlot("commandless-subtle", "subtle_approach", 1),
    cards = {
        card("commandless-subtle", "subtle_approach", "player", "plan", 1),
    },
})
local commandless = assertOk(
    "commandless restricted plan",
    run(
        "commandless restricted plan",
        commandlessData,
        commandlessState,
        {},
        { type = "session_end" },
        { phase = "session_end", allowGameplayCommands = false }
    )
)
assert(commandless.state.player.planSlot.occupied == false, "commandless plan did not consume its charge")
assert(#commandless.records == 2
        and commandless.records[1].type == "plan_changed"
        and commandless.records[2].type == "trigger_resolved",
    "commandless plan record order changed")

-- Invalid specs and callback exceptions become structured failures and cannot
-- mutate any caller-owned input through context/event references.
local invalidData = clone(staticData)
invalidData.environments.uncrowded.triggers[1].resolve = "not_a_function"
local invalidState = makeState({ battleId = "pipeline-invalid" })
assertHasError(
    "invalid trigger spec",
    run(
        "invalid trigger spec",
        invalidData,
        invalidState,
        { keep = true },
        { type = "card_declared", side = "player" },
        { phase = "player_card" }
    ),
    "invalid_trigger"
)

local invalidEventData = clone(staticData)
invalidEventData.environments.uncrowded.triggers[1].event = "missing_event"
assertHasError(
    "invalid trigger event spec",
    run(
        "invalid trigger event spec",
        invalidEventData,
        invalidState,
        {},
        { type = "card_declared", side = "player" },
        { phase = "player_card" }
    ),
    "unknown_trigger_event"
)

local hostileConditionData = clone(staticData)
hostileConditionData.environments.uncrowded.triggers[1].trigger = function(context, event)
    context.player.stealth = -999
    event.type = "turn_end"
    error("condition boom")
end
assertHasError(
    "protected condition",
    run(
        "protected condition",
        hostileConditionData,
        invalidState,
        {},
        { type = "card_declared", side = "player" },
        { phase = "player_card" }
    ),
    "trigger_condition_error"
)

local hostileResolveData = clone(staticData)
hostileResolveData.environments.uncrowded.triggers[1].resolve = function(context, event)
    context.player.stealth = -999
    event.type = "turn_end"
    error("resolve boom")
end
assertHasError(
    "protected resolve",
    run(
        "protected resolve",
        hostileResolveData,
        invalidState,
        {},
        { type = "card_declared", side = "player" },
        { phase = "player_card" }
    ),
    "trigger_resolve_error"
)

print(
    "VECTOR"
        .. "|current=" .. tostring(current.state.player.stealth)
        .. "|turn-start-charge=" .. tostring(start.state.player.planSlot.remainingCharges)
        .. "|ordered=" .. orderedSequence
        .. "|ordered-stealth=" .. tostring(ordered.state.player.stealth)
        .. "|insight=" .. tostring(insight.state.player.stealth)
        .. "|commandless=" .. tostring(commandless.state.player.planSlot.occupied)
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[trigger-pipeline-check]],[[t]],_G))()'
    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua triggerPipeline 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }
    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua triggerPipeline 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }
    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 triggerPipeline 결과를 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    $expected = 'VECTOR|current=26|turn-start-charge=1|ordered=trigger_resolved:plan:subtle_approach,trigger_resolved:plan:silent_glare,trigger_resolved:trait:z_player,trigger_resolved:trait:a_character,trigger_resolved:trait:m_ownerless,trigger_resolved:perk:z_player,trigger_resolved:perk:a_character,trigger_resolved:environment:uncrowded|ordered-stealth=-121|insight=29|commandless=false'
    if ($firstText -cne $expected) {
        throw "triggerPipeline 결정성 표식이 예상과 다릅니다: $firstText"
    }
    Write-Output 'trigger-pipeline-check: ok'
    Write-Output 'NOTE: 실제 RisuAI 로어북 통합 환경에서는 아직 검증하지 않았습니다.'
}
finally {
    Pop-Location
}
