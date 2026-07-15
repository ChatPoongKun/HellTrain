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
    throw 'Lua 실행기를 찾을 수 없습니다. 이 검사는 실제 RisuAI 통합 검사를 대신하지 않습니다.'
}

$luaTest = @'
local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local source = readFile("System/deterministicRng.lua")
assert(not string.find(source, "math.random", 1, true), "deterministicRng must not use math.random")
local deterministicRng = assert(load("return" .. source, "@System/deterministicRng.lua", "t", _G))()

local function call(action, ...)
    return deterministicRng("deterministic-rng-check", action, ...)
end

local function assertOk(label, report)
    assert(type(report) == "table", label .. " must return a table")
    assert(report.ok == true, label .. " must succeed")
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(report.algorithm == "park_miller_schrage_v1", label .. " algorithm changed")
    assert(type(report.errors) == "table" and #report.errors == 0, label .. " returned errors")
    return report
end

local function assertError(label, report, expectedCode, expectedPath)
    assert(type(report) == "table" and report.ok == false, label .. " must fail")
    assert(report.schemaVersion == 1, label .. " schemaVersion changed")
    assert(report.algorithm == "park_miller_schrage_v1", label .. " algorithm changed")
    for _, item in ipairs(type(report.errors) == "table" and report.errors or {}) do
        if item.code == expectedCode and (expectedPath == nil or item.path == expectedPath) then
            return item
        end
    end
    error(label .. " did not return " .. expectedCode .. " at " .. tostring(expectedPath))
end

local inputRng = { seed = 42, cursor = 7 }
local validated = assertOk("validate", call("validate", inputRng))
assert(inputRng.seed == 42 and inputRng.cursor == 7, "validate mutated its input")
assert(validated.value ~= inputRng and validated.rng ~= inputRng, "validate returned the input table")
assert(validated.value ~= validated.rng, "validate aliases value and rng")
validated.value.seed = 99
assert(inputRng.seed == 42 and validated.rng.seed == 42, "validate result aliases an input or sibling result")

local firstFromZero = assertOk(
    "seed zero first value",
    call("nextInteger", { seed = 0, cursor = 0 }, 1, 2147483646)
)
assert(firstFromZero.value == 16807, "seed 0 first Park-Miller value changed")
assert(firstFromZero.rng.seed == 0 and firstFromZero.rng.cursor == 1, "seed 0 state changed incorrectly")

local firstFromOne = assertOk(
    "seed one first value",
    call("nextInteger", { seed = 1, cursor = 0 }, 1, 2147483646)
)
assert(firstFromOne.value == 16807, "seed 1 first Park-Miller value changed")
local secondFromOne = assertOk(
    "seed one second value",
    call("nextInteger", firstFromOne.rng, 1, 2147483646)
)
assert(secondFromOne.value == 282475249 and secondFromOne.rng.cursor == 2, "second Park-Miller value changed")
local thirdFromOne = assertOk(
    "seed one third value",
    call("nextInteger", secondFromOne.rng, 1, 2147483646)
)
assert(thirdFromOne.value == 1622650073 and thirdFromOne.rng.cursor == 3, "third Park-Miller value changed")

local boundedInput = { seed = 42, cursor = 0 }
local bounded = assertOk("bounded integer", call("nextInteger", boundedInput, 10, 20))
assert(bounded.value == 11, "bounded integer value changed")
assert(bounded.value >= 10 and bounded.value <= 20, "bounded integer escaped its range")
assert(bounded.rng.seed == 42 and bounded.rng.cursor == 1, "bounded integer cursor changed incorrectly")
assert(boundedInput.seed == 42 and boundedInput.cursor == 0, "nextInteger mutated its input")

local replayState = { seed = 987654, cursor = 11 }
local replayA = assertOk("replay A", call("nextInteger", replayState, -50, 50))
local replayB = assertOk("replay B", call("nextInteger", replayState, -50, 50))
assert(replayA.value == replayB.value, "same RNG state produced different values")
assert(replayA.rng.seed == replayB.rng.seed and replayA.rng.cursor == replayB.rng.cursor,
    "same RNG state produced different next states")
assert(replayState.seed == 987654 and replayState.cursor == 11, "replay calls mutated their input")

local rejection = assertOk(
    "rejection sampling",
    call("nextInteger", { seed = 100000, cursor = 0 }, 1, 1073741824)
)
assert(rejection.value == 28330345, "rejection sampling result changed")
assert(rejection.rng.cursor == 4, "rejected samples were not counted in the cursor")

local chainedState = { seed = 314159, cursor = 0 }
local chainedValues = {}
for index = 1, 6 do
    local report = assertOk("chained draw " .. index, call("nextInteger", chainedState, 1, 100))
    assert(report.value >= 1 and report.value <= 100, "chained draw escaped its range")
    assert(report.rng.seed == 314159 and report.rng.cursor >= index, "chained cursor did not advance")
    chainedValues[index] = report.value
    chainedState = report.rng
end

local original = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }
local shuffled = assertOk("fixed shuffle", call("shuffle", { seed = 42, cursor = 0 }, original))
assert(table.concat(shuffled.value, ",") == "j,c,f,e,h,g,b,i,a,d", "fixed shuffle order changed")
assert(shuffled.rng.seed == 42 and shuffled.rng.cursor == 9, "shuffle cursor changed")
assert(table.concat(original, ",") == "a,b,c,d,e,f,g,h,i,j", "shuffle mutated its input array")
assert(shuffled.value ~= original, "shuffle returned its input array")

local empty = {}
local emptyShuffle = assertOk("empty shuffle", call("shuffle", { seed = 8, cursor = 3 }, empty))
assert(#emptyShuffle.value == 0 and emptyShuffle.value ~= empty, "empty shuffle did not return a new empty array")
assert(emptyShuffle.rng.seed == 8 and emptyShuffle.rng.cursor == 3, "empty shuffle consumed RNG")

local singleton = { "only" }
local singletonShuffle = assertOk("singleton shuffle", call("shuffle", { seed = 8, cursor = 3 }, singleton))
assert(#singletonShuffle.value == 1 and singletonShuffle.value[1] == "only", "singleton shuffle changed its value")
assert(singletonShuffle.value ~= singleton, "singleton shuffle returned its input array")
assert(singletonShuffle.rng.seed == 8 and singletonShuffle.rng.cursor == 3, "singleton shuffle consumed RNG")
assert(singleton[1] == "only", "singleton shuffle mutated its input")

assertError("non-table rng", call("validate", nil), "invalid_rng", "$.rng")
assertError("negative seed", call("validate", { seed = -1, cursor = 0 }), "invalid_rng_seed", "$.rng.seed")
assertError("negative cursor", call("validate", { seed = 1, cursor = -1 }), "invalid_rng_cursor", "$.rng.cursor")
assertError(
    "unknown rng field",
    call("validate", { seed = 1, cursor = 0, state = 1 }),
    "unknown_rng_field",
    "$.rng.state"
)
assertError("reversed range", call("nextInteger", { seed = 1, cursor = 0 }, 5, 4), "invalid_range_order", "$.maximum")
assertError(
    "too-wide range",
    call("nextInteger", { seed = 1, cursor = 0 }, 0, 2147483646),
    "range_too_wide",
    "$.maximum"
)
assertError(
    "sparse array",
    call("shuffle", { seed = 1, cursor = 0 }, { [1] = "a", [3] = "c" }),
    "sparse_array",
    "$.array"
)

print(
    "VECTOR|known="
        .. firstFromOne.value .. "," .. secondFromOne.value .. "," .. thirdFromOne.value
        .. "|bounded=" .. bounded.value
        .. "|rejection=" .. rejection.value .. ":" .. rejection.rng.cursor
        .. "|chain=" .. table.concat(chainedValues, ",")
        .. "|shuffle=" .. table.concat(shuffled.value, ",")
        .. "|cursor=" .. shuffled.rng.cursor
)
'@

Push-Location $projectRoot
try {
    $env:RISU_DETERMINISTIC_RNG_TEST = $luaTest

    $firstOutput = @(& $luaHost -e 'assert(load(os.getenv([[RISU_DETERMINISTIC_RNG_TEST]]),[[deterministic-rng-check]],[[t]],_G))()' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "첫 번째 Lua RNG 검사 프로세스가 실패했습니다.`n$($firstOutput -join "`n")"
    }

    $secondOutput = @(& $luaHost -e 'assert(load(os.getenv([[RISU_DETERMINISTIC_RNG_TEST]]),[[deterministic-rng-check]],[[t]],_G))()' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "두 번째 Lua RNG 검사 프로세스가 실패했습니다.`n$($secondOutput -join "`n")"
    }

    $firstText = $firstOutput -join "`n"
    $secondText = $secondOutput -join "`n"
    if (-not ($firstText -ceq $secondText)) {
        throw "별도 Lua 프로세스가 서로 다른 RNG 출력을 만들었습니다.`nFIRST:`n$firstText`nSECOND:`n$secondText"
    }
    if (-not $firstText.StartsWith('VECTOR|known=16807,282475249,1622650073|')) {
        throw "결정적 RNG 출력 표식이 예상과 다릅니다: $firstText"
    }

    Write-Output 'deterministic-rng-check: ok'
    Write-Output 'NOTE: 실제 RisuAI 통합 환경에서는 아직 검증하지 않았습니다.'
}
finally {
    Remove-Item Env:RISU_DETERMINISTIC_RNG_TEST -ErrorAction SilentlyContinue
    Pop-Location
}
