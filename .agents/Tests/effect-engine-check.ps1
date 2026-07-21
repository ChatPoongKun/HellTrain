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

local function call(action, ...)
    return runScript("effect-engine-check", "effectEngine", action, ...)
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
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    return report
end

local function assertHasError(label, report, code)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    for _, item in ipairs(type(report.errors) == "table" and report.errors or {}) do
        if item.code == code then
            return item
        end
    end
    failReport(label .. " missing " .. code, report)
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
    for key in pairs(value) do table.insert(keys, key) end
    table.sort(keys, function(left, right)
        return type(left) .. ":" .. tostring(left) < type(right) .. ":" .. tostring(right)
    end)
    local values = {}
    for _, key in ipairs(keys) do
        table.insert(values, canonical(key, active) .. "=" .. canonical(value[key], active))
    end
    active[value] = nil
    return "{" .. table.concat(values, ",") .. "}"
end

local function card(instanceId, owner, zone, position)
    return {
        instanceId = instanceId,
        cardId = "fixture_card",
        owner = owner,
        zone = zone,
        position = position,
    }
end

local function fixture()
    return {
        schemaVersion = 1,
        kind = "battleState",
        battleId = "effect-engine-battle",
        status = "active",
        turnNumber = 1,
        turnLimit = 20,
        environmentId = "uncrowded",
        rng = { seed = 42, cursor = 0 },
        player = {
            stealth = 10,
            baseDrawCount = 3,
            maxHandSize = 5,
            perkIds = {},
            planSlot = { occupied = false },
        },
        character = {
            characterId = "yoo_jiyoung",
            resistance = 10,
            mood = "ignore",
            traitIds = { "reserved" },
            baseDrawCount = 3,
            maxHandSize = 5,
            planSlot = { occupied = false },
        },
        cardInstances = {
            card("player-deck-1", "player", "deck", 1),
            card("character-deck-1", "character", "deck", 1),
        },
        selection = { playerCardInstanceIds = {} },
        characterIntent = { cardInstanceIds = {} },
    }
end

local staticReport = assertOk("load static data", runScript("effect-engine-check", "staticData", "loadAll"))
local staticData = staticReport.data

-- Actual DB callbacks are protected, normalized, and mood-sensitive.
local context = {
    mood = "rejection",
    player = { stealth = 10 },
    character = { resistance = 10 },
}
local contextSnapshot = canonical(context)
local cool = assertOk("evaluate play_it_cool", call("evaluateCardResolve", staticData, "play_it_cool", context))
assert(#cool.commands == 1 and cool.commands[1].op == "recover_stealth" and cool.commands[1].amount == 1)
assert(canonical(context) == contextSnapshot, "card callback changed caller context")

local neutralCool = assertOk(
    "evaluate play_it_cool neutral",
    call("evaluateCardResolve", staticData, "play_it_cool", { mood = "ignore" })
)
assert(neutralCool.commands[1].amount == 3)
local noResolve = assertOk("evaluate selection-only card", call("evaluateCardResolve", staticData, "read_the_room", context))
assert(#noResolve.commands == 0)

local suspicion = assertOk(
    "evaluate suspicion mood effect",
    call("evaluateMoodEffect", staticData, "accidental_brush", "suspicion", context)
)
assert(#suspicion.commands == 1 and suspicion.commands[1].cause == "moodEffect")
local noMoodEffect = assertOk(
    "evaluate absent mood effect",
    call("evaluateMoodEffect", staticData, "accidental_brush", "ignore", context)
)
assert(#noMoodEffect.commands == 0)

local environmentTrigger = staticData.environments.uncrowded.triggers[1]
local declaredEvent = { type = "card_declared", side = "player" }
local environment = assertOk(
    "evaluate environment trigger",
    call("evaluateTrigger", staticData, environmentTrigger, context, declaredEvent)
)
assert(environment.matched and environment.commands[1].amount == 1)
local environmentMiss = assertOk(
    "declarative environment event mismatch",
    call("evaluateTrigger", staticData, environmentTrigger, context, { type = "turn_end" })
)
assert(not environmentMiss.matched and #environmentMiss.commands == 0)
local planTrigger = staticData.cards.silent_glare.mechanismData.plan
local planMatch = assertOk(
    "evaluate plan match",
    call("evaluateTrigger", staticData, planTrigger, context, declaredEvent)
)
assert(planMatch.matched and planMatch.commands[1].amount == 3)
local planMiss = assertOk(
    "evaluate plan miss",
    call("evaluateTrigger", staticData, planTrigger, context, { type = "turn_end", side = "player" })
)
assert(not planMiss.matched and #planMiss.commands == 0)
local invalidEventTrigger = clone(environmentTrigger)
invalidEventTrigger.event = "missing_event"
assertHasError(
    "trigger references unknown event",
    call("evaluateTriggerCondition", staticData, invalidEventTrigger, context, declaredEvent),
    "unknown_trigger_event"
)
local invalidSideTrigger = clone(environmentTrigger)
invalidSideTrigger.side = "ownerless"
assertHasError(
    "trigger references invalid side",
    call("evaluateTriggerCondition", staticData, invalidSideTrigger, context, declaredEvent),
    "invalid_trigger_side"
)

-- Trigger collection evaluates only conditions. Insight filtering can happen
-- before a surviving trigger's resolve callback is invoked.
local conditionCalls = 0
local resolveCalls = 0
local splitTrigger = {
    trigger = function(callbackContext, event)
        conditionCalls = conditionCalls + 1
        return event.type == "card_declared" and callbackContext.mood == "rejection"
    end,
    resolve = function()
        resolveCalls = resolveCalls + 1
        return {
            { op = "lose_stealth", target = "player", amount = 2, cause = "test" },
        }
    end,
}
local splitCondition = assertOk(
    "evaluate trigger condition only",
    call("evaluateTriggerCondition", staticData, splitTrigger, context, declaredEvent)
)
assert(splitCondition.matched and conditionCalls == 1 and resolveCalls == 0)
local splitResolve = assertOk(
    "evaluate trigger resolve only",
    call("evaluateTriggerResolve", staticData, splitTrigger, context, declaredEvent)
)
assert(#splitResolve.commands == 1 and splitResolve.commands[1].amount == 2)
assert(conditionCalls == 1 and resolveCalls == 1, "split resolve reevaluated trigger condition")

local conditionlessResolveCalls = 0
local conditionlessTrigger = {
    resolve = function()
        conditionlessResolveCalls = conditionlessResolveCalls + 1
        return {
            { op = "lose_stealth", target = "player", amount = 1, cause = "test" },
        }
    end,
}
local conditionless = assertOk(
    "conditionless trigger matches without resolving",
    call("evaluateTriggerCondition", staticData, conditionlessTrigger, context, declaredEvent)
)
assert(conditionless.matched and conditionlessResolveCalls == 0)

local missCondition = assertOk(
    "split trigger miss",
    call("evaluateTriggerCondition", staticData, splitTrigger, context, { type = "turn_end", side = "player" })
)
assert(not missCondition.matched and conditionCalls == 2 and resolveCalls == 1)

-- Conditions and resolvers receive separate clones of one event-start snapshot.
local observedResolveSnapshot = false
local hostileTrigger = {
    trigger = function(callbackContext, event)
        callbackContext.player.stealth = 0
        event.side = "character"
        return true
    end,
    resolve = function(callbackContext, event)
        observedResolveSnapshot = callbackContext.player.stealth == 10 and event.side == "player"
        return {
            { op = "lose_stealth", target = "player", amount = 1, cause = "test" },
        }
    end,
}
local protectedContext = { player = { stealth = 10 } }
local protectedEvent = { type = "card_declared", side = "player" }
assertOk("protected trigger snapshot", call("evaluateTrigger", staticData, hostileTrigger, protectedContext, protectedEvent))
assert(observedResolveSnapshot, "trigger resolve saw condition mutations")
assert(protectedContext.player.stealth == 10 and protectedEvent.side == "player", "trigger changed caller inputs")

-- canPlay is optional, protected, and returns stable reason codes.
local defaultCanPlay = assertOk("default canPlay", call("evaluateCanPlay", staticData, "pin_down", context))
assert(defaultCanPlay.playable and defaultCanPlay.reasonCode == nil)
local callbackStatic = {
    registry = staticData.registry,
    cards = {
        guarded = {
            id = "guarded",
            canPlay = function(callbackContext)
                callbackContext.player.stealth = 0
                return false, "insufficient_stealth"
            end,
        },
    },
}
local canPlayContext = { player = { stealth = 4 } }
local guarded = assertOk("protected canPlay", call("evaluateCanPlay", callbackStatic, "guarded", canPlayContext))
assert(not guarded.playable and guarded.reasonCode == "insufficient_stealth")
assert(canPlayContext.player.stealth == 4, "canPlay changed caller context")

-- Command validation covers every current registry operation and rejects the deferred modifier pipeline.
local allCommands = {
    { op = "damage_resistance", target = "character", amount = 3, cause = "test" },
    { op = "recover_resistance", target = "character", amount = 2, cause = "test" },
    { op = "lose_stealth", target = "player", amount = 1, cause = "test" },
    { op = "recover_stealth", target = "player", amount = 4, cause = "test" },
    { op = "draw_cards", target = "player", amount = 1, cause = "test" },
    { op = "skip_actions", target = "character", scope = "remainingTurn", cause = "test" },
    { op = "shift_mood", target = "character", amount = 1, cause = "test" },
    { op = "set_mood", target = "character", mood = "suspicion", cause = "test" },
    { op = "lock_mood", target = "character", mood = "suspicion", ["until"] = "turn_end", cause = "test" },
}
local validated = assertOk("validate all commands", call("validateCommands", staticData, allCommands))
assert(#validated.commands == #allCommands)
local commandSnapshot = canonical(allCommands)
local working = { state = fixture(), transient = {} }
local workingSnapshot = canonical(working)
local applied = assertOk("apply all commands", call("applyCommands", staticData, working, allCommands))
assert(canonical(working) == workingSnapshot, "applyCommands changed caller working value")
assert(canonical(allCommands) == commandSnapshot, "applyCommands changed caller commands")
assert(applied.state.character.resistance == 9)
assert(applied.state.player.stealth == 13)
assert(applied.state.character.mood == "suspicion")
assert(applied.transient.skipRemaining.character == true)
assert(applied.transient.directMoodChanged == true)
assert(applied.transient.moodLockApplied == true)
assert(applied.transient.moodLock.mood == "suspicion")
assert(#applied.applied[5].drawnInstanceIds == 1 and applied.applied[5].drawnInstanceIds[1] == "player-deck-1")
assert(#applied.applied[5].before.deckInstanceIds == 1
    and applied.applied[5].before.deckInstanceIds[1] == "player-deck-1")
assert(#applied.applied[5].before.handInstanceIds == 0)
assert(#applied.applied[5].after.deckInstanceIds == 0)
assert(#applied.applied[5].after.handInstanceIds == 1
    and applied.applied[5].after.handInstanceIds[1] == "player-deck-1")
assert(applied.applied[5].before.rng.seed == applied.applied[5].after.rng.seed)
assert(applied.applied[5].before.rng.cursor == applied.applied[5].after.rng.cursor)
assert(applied.state.rng.cursor == working.state.rng.cursor, "non-shuffle draw consumed RNG")

local lockCommands = {
    { op = "lock_mood", target = "character", mood = "ignore", ["until"] = "turn_end", cause = "test" },
    { op = "shift_mood", target = "character", amount = 1, cause = "test" },
    { op = "set_mood", target = "character", mood = "compliance", cause = "test" },
}
local locked = assertOk("lock blocks direct mood", call("applyCommands", staticData, { state = fixture(), transient = {} }, lockCommands))
assert(locked.state.character.mood == "ignore")
assert(locked.transient.moodLockApplied == true and locked.transient.directMoodChanged ~= true)
assert(locked.applied[2].blocked == true and locked.applied[3].blocked == true)

local complianceState = fixture()
complianceState.character.mood = "compliance"
local clamped = assertOk(
    "clamped edge shift",
    call("applyCommands", staticData, { state = complianceState, transient = {} }, {
        { op = "shift_mood", target = "character", amount = 1, cause = "test" },
    })
)
assert(clamped.state.character.mood == "compliance" and clamped.transient.directMoodChanged ~= true)

local sameSet = assertOk(
    "set current mood",
    call("applyCommands", staticData, { state = fixture(), transient = {} }, {
        { op = "set_mood", target = "character", mood = "ignore", cause = "test" },
    })
)
assert(sameSet.transient.directMoodChanged ~= true and sameSet.applied[1].changed == false)

assertOk("nil modifiers", call("validateModifiers", nil))
assertOk("empty modifiers", call("validateModifiers", {}))
assertHasError("nonempty modifiers", call("validateModifiers", { { operation = "add", amount = 1 } }), "unsupported_modifiers")
assertHasError(
    "resolve rejects modifiers",
    call("evaluateCardResolve", staticData, "play_it_cool", context, { modifiers = { { amount = 1 } } }),
    "unsupported_modifiers"
)

local invalidCases = {
    { "missing cause", { { op = "lose_stealth", target = "player", amount = 1 } }, "invalid_command_cause" },
    { "wrong target", { { op = "lose_stealth", target = "character", amount = 1, cause = "test" } }, "invalid_command_target" },
    { "negative amount", { { op = "damage_resistance", target = "character", amount = -1, cause = "test" } }, "invalid_command_amount" },
    { "zero draw", { { op = "draw_cards", target = "player", amount = 0, cause = "test" } }, "invalid_command_amount" },
    { "fractional mood shift", { { op = "shift_mood", target = "character", amount = 0.5, cause = "test" } }, "invalid_command_amount" },
    { "unknown mood", { { op = "set_mood", target = "character", mood = "missing", cause = "test" } }, "unknown_mood" },
    { "wrong lock end", { { op = "lock_mood", target = "character", mood = "ignore", ["until"] = "session_end", cause = "test" } }, "invalid_command_until" },
    { "unexpected field", { { op = "lose_stealth", target = "player", amount = 1, cause = "test", extra = true } }, "unexpected_command_field" },
    { "unknown op", { { op = "missing_op", target = "player", cause = "test" } }, "unknown_effect_op" },
}
for _, item in ipairs(invalidCases) do
    assertHasError(item[1], call("validateCommands", staticData, item[2]), item[3])
end

local unsupportedStatic = clone(staticData)
unsupportedStatic.registry.effectOps.future_op = { id = "future_op" }
assertHasError(
    "registered unsupported op",
    call("validateCommands", unsupportedStatic, { { op = "future_op", target = "player", cause = "test" } }),
    "unsupported_effect_op"
)

local wrongLock = fixture()
local wrongLockSnapshot = canonical(wrongLock)
assertHasError(
    "lock mood mismatch",
    call("applyCommands", staticData, { state = wrongLock, transient = {} }, {
        { op = "lock_mood", target = "character", mood = "suspicion", ["until"] = "turn_end", cause = "test" },
    }),
    "mood_lock_mismatch"
)
assert(canonical(wrongLock) == wrongLockSnapshot, "failed apply changed input state")

local callbackFailures = {
    bad_error = {
        id = "bad_error",
        resolve = function() error("boom") end,
    },
    bad_return = {
        id = "bad_return",
        resolve = function() return "not commands" end,
    },
    bad_op = {
        id = "bad_op",
        resolve = function()
            return { { op = "missing_op", target = "player", cause = "test" } }
        end,
    },
}
local badStatic = { registry = staticData.registry, cards = callbackFailures }
assertHasError("callback exception", call("evaluateCardResolve", badStatic, "bad_error", {}), "card_resolve_error")
assertHasError("callback bad return", call("evaluateCardResolve", badStatic, "bad_return", {}), "invalid_commands")
assertHasError("callback unknown op", call("evaluateCardResolve", badStatic, "bad_op", {}), "unknown_effect_op")

print(
    "VECTOR"
        .. "|stealth=" .. tostring(applied.state.player.stealth)
        .. "|resistance=" .. tostring(applied.state.character.resistance)
        .. "|mood=" .. applied.state.character.mood
        .. "|draw=" .. table.concat(applied.applied[5].drawnInstanceIds, ",")
        .. "|locked=" .. locked.state.character.mood
        .. "|clamped=" .. clamped.state.character.mood
)
'@

Push-Location $projectRoot
try {
    $luaEntry = 'local source=io.read([[*a]]); if source:sub(1,3)==string.char(239,187,191) then source=source:sub(4) end; assert(load(source,[[effect-engine-check]],[[t]],_G))()'
    $firstOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua effectEngine 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }
    $secondOutput = @($luaTest | & $luaHost -e $luaEntry 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua effectEngine 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }
    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 effectEngine 결과를 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if ($firstText -cne 'VECTOR|stealth=13|resistance=9|mood=suspicion|draw=player-deck-1|locked=ignore|clamped=compliance') {
        throw "effectEngine 결정성 표식이 예상과 다릅니다: $firstText"
    }
    Write-Output 'effect-engine-check: ok'
    Write-Output 'NOTE: 실제 RisuAI 로어북 통합 환경에서는 아직 검증하지 않았습니다.'
}
finally {
    Pop-Location
}
