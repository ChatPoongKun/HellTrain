(function()
--기본 변수
DEBUG = 2 --디버그 메시지 depth. 숫자가 클수록 덜 중요하고 디테일 한 메시지.

--전역 상수
DEFAULT_LORE_OPTION = { alwaysActive = false, insertOrder = 100, key = "", secondKey = "", regex = false }


--디버깅
function debug(depth, ...)
    if depth <= DEBUG then
        print(...)
    end
end

--tonumber를 콤마제거후 숫자로 인식하도록 오버라이딩
old_tonumber = tonumber
tonumber = function(str, base)
    if type(str) == "string" then
        local cleaned_str = string.gsub(str, ",", "")
        return old_tonumber(cleaned_str, base)
    else
        return old_tonumber(str, base)
    end
end

--json을 chatVar 형식으로 저장
function toChatVar(triggerId, name, data)
    if data == nil then
        data = HostCompat.readState(triggerId, name)
    end

    if type(data) ~= "table" then
        HostCompat.writeChatVar(triggerId, name, tostring(data))
        return tostring(data)
    end

    local function encodeString(value)
        return json.encode(tostring(value))
    end

    local function encodeForChatVar(value)
        local parts = {}

        for k, v in pairs(value) do
            local encodedValue

            if type(v) == "table" then
                encodedValue = encodeString(encodeForChatVar(v))
            else
                encodedValue = encodeString(v)
            end

            table.insert(parts, encodeString(k) .. ":" .. encodedValue)
        end

        return "{" .. table.concat(parts, ",") .. "}"
    end

    local encoded = encodeForChatVar(data)
    HostCompat.writeChatVar(triggerId, name, encoded)
    return encoded
end

--chatVar를 state 형식으로 저장
function toState(triggerId, name)
    local source = getChatVar(triggerId, name)

    if not source or source == "" then
        debug(1, "toState error: chat var " .. tostring(name) .. " is empty.")
        local empty = {}
        HostCompat.writeState(triggerId, name, empty)
        return empty
    end

    local function tryDecode(value)
        if type(value) ~= "string" then
            return nil
        end

        local trimmed = value:match("^%s*(.-)%s*$")
        local first = trimmed:sub(1, 1)
        if first ~= "{" and first ~= "[" then
            return nil
        end

        local ok, decoded = pcall(json.decode, trimmed)
        if ok and type(decoded) == "table" then
            return decoded
        end
        return nil
    end

    local function decodeFromChatVar(value)
        if type(value) == "table" then
            local decoded = {}
            for k, v in pairs(value) do
                decoded[k] = decodeFromChatVar(v)
            end
            return decoded
        end

        local decoded = tryDecode(value)
        if decoded then
            return decodeFromChatVar(decoded)
        end

        return value
    end

    local root = tryDecode(source)
    if not root then
        HostCompat.writeState(triggerId, name, source)
        return source
    end

    local decoded = decodeFromChatVar(root)
    HostCompat.writeState(triggerId, name, decoded)
    return decoded
end

local function stripHtmlLineIndent(source)
    source = source:gsub("^[ \t]+", "")
    source = source:gsub("\r\n[ \t]+", "\r\n")
    source = source:gsub("\n[ \t]+", "\n")
    source = source:gsub("\r[ \t]+", "\r")
    return source
end

--로어북에서 내용을 불러와 return
function loadLores(triggerId, lore)
    local targetLores = getLoreBooks(triggerId, lore)
    if type(targetLores) ~= "table" then
        return nil
    end

    local contents = {}
    for _, loreEntry in ipairs(targetLores) do
        table.insert(contents, loreEntry.content)
    end
    local returnContents = table.concat(contents)

    --주석 제거
    returnContents = returnContents
        :gsub("%-%-%-[^\r\n]*", "")

    if type(lore) == "string" and string.match(lore, "%.html$") then
        returnContents = stripHtmlLineIndent(returnContents)
    end

    if returnContents == "" then
        return nil
    else
        return returnContents
    end
end

-- Executable lore entries are complete modules, not mergeable fragments. RisuAI
-- returns matches in local -> global -> module order. This game's authoritative
-- runtime bundle is the module entry, so the last non-empty match must replace
-- stale character/global copies. Concatenating duplicate modules can turn two
-- adjacent anonymous functions into an accidental function call.
local function loadScriptLore(triggerId, script)
    local loreName = script .. ".lua"
    local targetLores = getLoreBooks(triggerId, loreName)
    if type(targetLores) ~= "table" then
        return nil
    end

    local source = nil
    local sourceCount = 0
    for _, loreEntry in ipairs(targetLores) do
        local content = type(loreEntry) == "table" and loreEntry.content or nil
        if type(content) == "string" and content ~= "" then
            sourceCount = sourceCount + 1
            source = content
        end
    end

    if sourceCount > 1 then
        debug(2, "runScript warning: duplicate lorebook '" .. loreName
            .. "'; using the last match.")
    end
    if source == nil then
        return nil
    end

    return source:gsub("%-%-%-[^\r\n]*", "")
end

-- 배포 시 executable Lua lore 또는 static DB가 바뀌면 이 revision도 반드시 올린다. production
-- warm path는 이 명시적 계약 덕분에 이벤트 사이에서 getLoreBooks/CBS bridge를
-- 생략한다. 개발 중에는 setRunScriptCacheDevelopmentMode(true)를 사용하면 매
-- 이벤트의 첫 모듈 호출에서 source를 다시 확인한다.
RUNTIME_BUNDLE_REVISION = RUNTIME_BUNDLE_REVISION
    or "runtime-bundle-main-split-v1-20260804"
RUNTIME_CACHE_DEVELOPMENT_BYPASS = RUNTIME_CACHE_DEVELOPMENT_BYPASS == true

local RUN_SCRIPT_SOURCE_CACHE_MAX_ENTRIES = 64
local RUN_SCRIPT_WARM_CACHE_MAX_ENTRIES = 128
local RUN_SCRIPT_TRANSACTION_MAX_ENTRIES = 64
local RUN_SCRIPT_NAMESPACE_VAR = "runtimeModuleCacheV1.namespace"

local runScriptSourceBuckets = {}
local runScriptSourceCacheSize = 0
local runScriptWarmCache = {}
local runScriptWarmCacheSize = 0
local runScriptCacheClock = 0
local runScriptCacheEpoch = 0
local currentRuntimeMode = "unscoped"
local activeRuntimeEvent = nil
local runScriptCacheStats = {
    events = 0,
    requests = 0,
    transactionHits = 0,
    transactionCapacitySkips = 0,
    warmHits = 0,
    warmMisses = 0,
    sourceFetches = 0,
    sourceHits = 0,
    sourceMisses = 0,
    compiles = 0,
    sourceEvictions = 0,
    warmEvictions = 0,
    clears = 0,
    developmentModeChanges = 0,
    namespaceReads = 0,
    namespaceWrites = 0,
    namespaceWriteFailures = 0,
    volatileNamespaces = 0,
    missingSources = 0,
    compileFailures = 0,
    loadFailures = 0,
    invalidHandlers = 0,
    executionFailures = 0,
}

local function fingerprintRunScriptIdentity(source)
    local first = 0
    local second = 0
    for index = 1, #source do
        local byte = string.byte(source, index)
        first = (first * 131 + byte) % 2147483647
        second = (second * 137 + byte + index) % 2147483629
    end
    return tostring(#source) .. ":" .. tostring(first) .. ":" .. tostring(second)
end

local function runtimeCacheKeyPart(value)
    local text = tostring(value or "")
    return tostring(#text) .. ":" .. text
end

local function makeRunScriptWarmKey(event, script)
    return table.concat({
        runtimeCacheKeyPart(event.bundleRevision),
        runtimeCacheKeyPart(event.mode),
        runtimeCacheKeyPart(event.namespace),
        runtimeCacheKeyPart(event.characterIdentity),
        runtimeCacheKeyPart(script),
    }, "|")
end

local function touchRunScriptCacheEntry(entry)
    runScriptCacheClock = runScriptCacheClock + 1
    entry.lastUsed = runScriptCacheClock
end

local function currentRunScriptBundleRevision()
    local revision = tostring(RUNTIME_BUNDLE_REVISION or "")
    if revision == "" then
        return "invalid-empty-revision"
    end
    return revision
end

local function resolveRunScriptNamespace(triggerId)
    runScriptCacheStats.namespaceReads = runScriptCacheStats.namespaceReads + 1
    if type(getChatVar) == "function" then
        local readOk, existing = pcall(getChatVar, triggerId, RUN_SCRIPT_NAMESPACE_VAR)
        if readOk
            and type(existing) == "string"
            and string.match(existing, "^runtime%-ns%-v1:%d+:%d+:%d+$") then
            return existing
        end
    end

    local generated = "runtime-ns-v1:" .. fingerprintRunScriptIdentity(tostring(triggerId or ""))
    if type(HostCompat) == "table" and type(HostCompat.writeChatVar) == "function" then
        local writeOk = pcall(HostCompat.writeChatVar, triggerId, RUN_SCRIPT_NAMESPACE_VAR, generated)
        if writeOk then
            runScriptCacheStats.namespaceWrites = runScriptCacheStats.namespaceWrites + 1
            local readOk, stored = pcall(getChatVar, triggerId, RUN_SCRIPT_NAMESPACE_VAR)
            if readOk and stored == generated then
                return generated
            end
        end
        runScriptCacheStats.namespaceWriteFailures = runScriptCacheStats.namespaceWriteFailures + 1
    end

    -- 권한이 없는 mode에서는 event access key fingerprint를 사용한다. access key는
    -- top-level 호출마다 달라 warm hit는 포기하지만 다른 채팅과 섞이지 않는다.
    runScriptCacheStats.volatileNamespaces = runScriptCacheStats.volatileNamespaces + 1
    return "volatile:" .. generated
end

local function resolveRunScriptCharacterIdentity(triggerId)
    local name = ""
    local firstMessage = ""
    if type(getName) == "function" then
        local ok, value = pcall(getName, triggerId)
        if ok and type(value) == "string" then
            name = value
        end
    end
    if type(getCharacterFirstMessage) == "function" then
        local ok, value = pcall(getCharacterFirstMessage, triggerId)
        if ok and type(value) == "string" then
            firstMessage = value
        end
    end
    return fingerprintRunScriptIdentity(name .. "\0" .. firstMessage)
end

-- 모든 host hook의 시작에서 호출한다. namespace/character host read는 실제로
-- runScript가 호출될 때까지 지연하므로 editInput 같은 가벼운 hook에는 비용이 없다.
function beginRunScriptEvent(triggerId, mode)
    currentRuntimeMode = type(mode) == "string" and mode ~= "" and mode or "unscoped"
    activeRuntimeEvent = {
        triggerId = triggerId,
        mode = currentRuntimeMode,
        bundleRevision = currentRunScriptBundleRevision(),
        cacheEpoch = runScriptCacheEpoch,
        handlers = {},
        handlerCount = 0,
    }
    runScriptCacheStats.events = runScriptCacheStats.events + 1
    return currentRuntimeMode
end

local function ensureRunScriptEvent(triggerId)
    local revision = currentRunScriptBundleRevision()
    if activeRuntimeEvent == nil
        or activeRuntimeEvent.triggerId ~= triggerId
        or activeRuntimeEvent.bundleRevision ~= revision
        or activeRuntimeEvent.cacheEpoch ~= runScriptCacheEpoch then
        beginRunScriptEvent(triggerId, currentRuntimeMode)
    end
    if activeRuntimeEvent.namespace == nil then
        activeRuntimeEvent.namespace = resolveRunScriptNamespace(triggerId)
        activeRuntimeEvent.characterIdentity = resolveRunScriptCharacterIdentity(triggerId)
    end
    return activeRuntimeEvent
end

local function evictOldestRunScriptSourceEntry()
    if runScriptSourceCacheSize < RUN_SCRIPT_SOURCE_CACHE_MAX_ENTRIES then
        return
    end
    local oldestScript = nil
    local oldestSource = nil
    local oldestEntry = nil
    for scriptName, bucket in pairs(runScriptSourceBuckets) do
        for source, entry in pairs(bucket) do
            if oldestEntry == nil or entry.lastUsed < oldestEntry.lastUsed then
                oldestScript = scriptName
                oldestSource = source
                oldestEntry = entry
            end
        end
    end
    if oldestEntry ~= nil then
        local bucket = runScriptSourceBuckets[oldestScript]
        bucket[oldestSource] = nil
        if next(bucket) == nil then
            runScriptSourceBuckets[oldestScript] = nil
        end
        runScriptSourceCacheSize = runScriptSourceCacheSize - 1
        runScriptCacheStats.sourceEvictions = runScriptCacheStats.sourceEvictions + 1
    end
end

local function instantiateRunScriptHandler(script, source)
    local bucket = runScriptSourceBuckets[script]
    local entry = bucket and bucket[source] or nil
    local chunk = nil
    if entry ~= nil then
        runScriptCacheStats.sourceHits = runScriptCacheStats.sourceHits + 1
        entry.hits = entry.hits + 1
        touchRunScriptCacheEntry(entry)
        chunk = entry.chunk
    else
        runScriptCacheStats.sourceMisses = runScriptCacheStats.sourceMisses + 1
        local functionString = "return" .. source
        debug(3, functionString)
        local err = nil
        chunk, err = load(functionString, "lore_function:" .. tostring(script), "t", _G)
        if not chunk then
            runScriptCacheStats.compileFailures = runScriptCacheStats.compileFailures + 1
            debug(1, "컴파일 오류: " .. (err or "알 수 없음"))
            return nil
        end
        runScriptCacheStats.compiles = runScriptCacheStats.compiles + 1
    end

    -- compiled chunk는 context 사이에 공유해도 handler closure는 namespace마다 새로
    -- 만든다. 모듈이 outer local cache를 가져도 다른 채팅과 mutable state가 섞이지 않는다.
    local ok, handler = pcall(chunk)
    if not ok then
        runScriptCacheStats.loadFailures = runScriptCacheStats.loadFailures + 1
        debug(1, "스크립트 로드 오류: " .. tostring(handler))
        if entry ~= nil then
            bucket[source] = nil
            runScriptSourceCacheSize = runScriptSourceCacheSize - 1
        end
        return nil
    end
    if type(handler) ~= "function" then
        runScriptCacheStats.invalidHandlers = runScriptCacheStats.invalidHandlers + 1
        debug(1, "runScript error: lorebook '" .. script .. "' did not return a function.")
        if entry ~= nil then
            bucket[source] = nil
            runScriptSourceCacheSize = runScriptSourceCacheSize - 1
        end
        return nil
    end

    if entry == nil then
        evictOldestRunScriptSourceEntry()
        bucket = runScriptSourceBuckets[script]
        if bucket == nil then
            bucket = {}
            runScriptSourceBuckets[script] = bucket
        end
        entry = {
            chunk = chunk,
            sourceLength = #source,
            sourceFingerprint = fingerprintRunScriptIdentity(source),
            hits = 0,
        }
        touchRunScriptCacheEntry(entry)
        bucket[source] = entry
        runScriptSourceCacheSize = runScriptSourceCacheSize + 1
    end
    return handler, entry.sourceFingerprint
end

local function evictOldestRunScriptWarmEntry()
    if runScriptWarmCacheSize < RUN_SCRIPT_WARM_CACHE_MAX_ENTRIES then
        return
    end
    local oldestKey = nil
    local oldestEntry = nil
    for key, entry in pairs(runScriptWarmCache) do
        if oldestEntry == nil or entry.lastUsed < oldestEntry.lastUsed then
            oldestKey = key
            oldestEntry = entry
        end
    end
    if oldestEntry ~= nil then
        runScriptWarmCache[oldestKey] = nil
        runScriptWarmCacheSize = runScriptWarmCacheSize - 1
        runScriptCacheStats.warmEvictions = runScriptCacheStats.warmEvictions + 1
    end
end

local function storeRunScriptWarmHandler(key, event, script, handler, sourceFingerprint)
    evictOldestRunScriptWarmEntry()
    local entry = {
        handler = handler,
        script = script,
        bundleRevision = event.bundleRevision,
        mode = event.mode,
        namespaceFingerprint = fingerprintRunScriptIdentity(event.namespace),
        characterIdentity = event.characterIdentity,
        sourceFingerprint = sourceFingerprint,
        hits = 0,
    }
    touchRunScriptCacheEntry(entry)
    runScriptWarmCache[key] = entry
    runScriptWarmCacheSize = runScriptWarmCacheSize + 1
    return handler
end

function setRunScriptCacheDevelopmentMode(enabled)
    local nextValue = enabled == true
    if RUNTIME_CACHE_DEVELOPMENT_BYPASS ~= nextValue then
        RUNTIME_CACHE_DEVELOPMENT_BYPASS = nextValue
        -- dev에서 관측한 source와 기존 production warm handler가 엇갈리지 않도록
        -- 모드 전환 시 warm layer만 폐기한다. compiled source cache는 안전하게 재사용한다.
        runScriptWarmCache = {}
        runScriptWarmCacheSize = 0
        runScriptCacheEpoch = runScriptCacheEpoch + 1
        activeRuntimeEvent = nil
        runScriptCacheStats.developmentModeChanges = runScriptCacheStats.developmentModeChanges + 1
    end
    return RUNTIME_CACHE_DEVELOPMENT_BYPASS
end

-- 개발 중 로어 교체나 진단 도구에서 명시적으로 캐시를 비울 수 있다.
-- script를 생략하면 전체를, 전달하면 해당 모듈의 compiled/warm entry를 제거한다.
function clearRunScriptCache(script)
    if script ~= nil and type(script) ~= "string" then
        return 0
    end

    local removedSources = 0
    if script == nil then
        removedSources = runScriptSourceCacheSize
        runScriptSourceBuckets = {}
        runScriptSourceCacheSize = 0
        runScriptWarmCache = {}
        runScriptWarmCacheSize = 0
    else
        local bucket = runScriptSourceBuckets[script]
        if bucket ~= nil then
            for _ in pairs(bucket) do
                removedSources = removedSources + 1
            end
            runScriptSourceBuckets[script] = nil
            runScriptSourceCacheSize = runScriptSourceCacheSize - removedSources
        end
        for key, entry in pairs(runScriptWarmCache) do
            if entry.script == script then
                runScriptWarmCache[key] = nil
                runScriptWarmCacheSize = runScriptWarmCacheSize - 1
            end
        end
    end

    runScriptCacheEpoch = runScriptCacheEpoch + 1
    activeRuntimeEvent = nil
    runScriptCacheStats.clears = runScriptCacheStats.clears + 1
    return removedSources
end


local turnInitializationDepth = 0

local function policyIsFinite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function policyIsInteger(value, minimum)
    return policyIsFinite(value)
        and value % 1 == 0
        and (minimum == nil or value >= minimum)
end

local function copyPolicyTable(value)
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = item
    end
    return copy
end

-- 완료 이력은 직전 턴의 finish를 기록한다. 다음 턴 초기화 중에는
-- turn_start 효과가 현재 은폐·저항·무드를 합법적으로 바꿀 수 있으므로,
-- battleHistory의 연속성 비교에만 직전 finish를 투영한다. 실제 state는
-- 바꾸지 않으며 stateSchema의 나머지 검증은 원본 state를 계속 검사한다.
local function projectHistoryValidationState(history, state)
    if type(history) ~= "table"
        or type(history.turns) ~= "table"
        or type(state) ~= "table"
        or state.status ~= "active"
        or not policyIsInteger(state.turnNumber, 1) then
        return state, false
    end

    local turnCount = #history.turns
    if turnCount == 0 or state.turnNumber ~= turnCount + 1 then
        return state, false
    end

    local last = history.turns[turnCount]
    local finish = type(last) == "table" and last.finish or nil
    if type(finish) ~= "table"
        or state.lastCommittedTurnId ~= last.turnId
        or not policyIsFinite(finish.stealth)
        or not policyIsFinite(finish.resistance)
        or type(finish.mood) ~= "string"
        or finish.status ~= "active"
        or type(state.player) ~= "table"
        or type(state.character) ~= "table" then
        return state, false
    end

    local receipt = state.turnStartReceipt
    if receipt ~= nil then
        local baseline = type(receipt) == "table" and receipt.baseline or nil
        if type(baseline) ~= "table"
            or baseline.stealth ~= finish.stealth
            or baseline.resistance ~= finish.resistance
            or baseline.mood ~= finish.mood then
            return state, false
        end
    end

    local projected = copyPolicyTable(state)
    projected.player = copyPolicyTable(state.player)
    projected.character = copyPolicyTable(state.character)
    projected.player.stealth = finish.stealth
    projected.character.resistance = finish.resistance
    projected.character.mood = finish.mood
    return projected, true
end

function getRunScriptCacheDiagnostics()
    local diagnostics = {
        bundleRevision = currentRunScriptBundleRevision(),
        developmentBypass = RUNTIME_CACHE_DEVELOPMENT_BYPASS,
        cacheEpoch = runScriptCacheEpoch,
        currentMode = currentRuntimeMode,
        turnInitializationDepth = turnInitializationDepth,
        maxSourceEntries = RUN_SCRIPT_SOURCE_CACHE_MAX_ENTRIES,
        maxWarmEntries = RUN_SCRIPT_WARM_CACHE_MAX_ENTRIES,
        maxTransactionEntries = RUN_SCRIPT_TRANSACTION_MAX_ENTRIES,
        sourceEntries = runScriptSourceCacheSize,
        warmEntries = runScriptWarmCacheSize,
        events = runScriptCacheStats.events,
        requests = runScriptCacheStats.requests,
        transactionHits = runScriptCacheStats.transactionHits,
        transactionCapacitySkips = runScriptCacheStats.transactionCapacitySkips,
        warmHits = runScriptCacheStats.warmHits,
        warmMisses = runScriptCacheStats.warmMisses,
        sourceFetches = runScriptCacheStats.sourceFetches,
        sourceHits = runScriptCacheStats.sourceHits,
        sourceMisses = runScriptCacheStats.sourceMisses,
        compiles = runScriptCacheStats.compiles,
        sourceEvictions = runScriptCacheStats.sourceEvictions,
        warmEvictions = runScriptCacheStats.warmEvictions,
        clears = runScriptCacheStats.clears,
        developmentModeChanges = runScriptCacheStats.developmentModeChanges,
        namespaceReads = runScriptCacheStats.namespaceReads,
        namespaceWrites = runScriptCacheStats.namespaceWrites,
        namespaceWriteFailures = runScriptCacheStats.namespaceWriteFailures,
        volatileNamespaces = runScriptCacheStats.volatileNamespaces,
        missingSources = runScriptCacheStats.missingSources,
        compileFailures = runScriptCacheStats.compileFailures,
        loadFailures = runScriptCacheStats.loadFailures,
        invalidHandlers = runScriptCacheStats.invalidHandlers,
        executionFailures = runScriptCacheStats.executionFailures,
        sources = {},
        warm = {},
    }
    -- 이전 진단 소비자와 호환되는 alias. 새 코드는 명시적인 source* 필드를 쓴다.
    diagnostics.entries = diagnostics.sourceEntries
    diagnostics.hits = diagnostics.sourceHits
    diagnostics.misses = diagnostics.sourceMisses
    diagnostics.evictions = diagnostics.sourceEvictions

    for scriptName, bucket in pairs(runScriptSourceBuckets) do
        for _, entry in pairs(bucket) do
            table.insert(diagnostics.sources, {
                script = scriptName,
                sourceLength = entry.sourceLength,
                sourceFingerprint = entry.sourceFingerprint,
                hits = entry.hits,
                lastUsed = entry.lastUsed,
            })
        end
    end
    for _, entry in pairs(runScriptWarmCache) do
        table.insert(diagnostics.warm, {
            script = entry.script,
            bundleRevision = entry.bundleRevision,
            mode = entry.mode,
            namespaceFingerprint = entry.namespaceFingerprint,
            characterIdentity = entry.characterIdentity,
            sourceFingerprint = entry.sourceFingerprint,
            hits = entry.hits,
            lastUsed = entry.lastUsed,
        })
    end
    local function sortDiagnostics(left, right)
        if left.script == right.script then
            return (left.sourceFingerprint or "") < (right.sourceFingerprint or "")
        end
        return left.script < right.script
    end
    table.sort(diagnostics.sources, sortDiagnostics)
    table.sort(diagnostics.warm, sortDiagnostics)
    return diagnostics
end

--로어북에서 스크립트를 호출해 실행
local function invokeRunScriptHandler(handler, triggerId, ...)
    local packed = table.pack(pcall(handler, triggerId, ...))
    if not packed[1] then
        runScriptCacheStats.executionFailures = runScriptCacheStats.executionFailures + 1
        debug(1, "스크립트 실행 오류: " .. tostring(packed[2]))
        return nil
    end
    return table.unpack(packed, 2, packed.n)
end

local function invokeRunScriptWithPolicy(handler, triggerId, script, ...)
    local arguments = table.pack(...)
    local action = arguments[1]
    local isTurnInitialization = script == "turnInitializer"
        and action == "prepareTurn"

    if isTurnInitialization then
        turnInitializationDepth = turnInitializationDepth + 1
    end

    local packed = table.pack(pcall(function()
        if turnInitializationDepth > 0
            and script == "battleHistory"
            and action == "validate" then
            local projected, applied = projectHistoryValidationState(
                arguments[2],
                arguments[3]
            )
            if applied then
                arguments[3] = projected
            end
        end
        return invokeRunScriptHandler(
            handler,
            triggerId,
            table.unpack(arguments, 1, arguments.n)
        )
    end))

    if isTurnInitialization then
        turnInitializationDepth = turnInitializationDepth - 1
    end

    if not packed[1] then
        debug(1, "runtime policy execution error: " .. tostring(packed[2]))
        return nil
    end
    return table.unpack(packed, 2, packed.n)
end

function runScript(triggerId, script, ...)
    runScriptCacheStats.requests = runScriptCacheStats.requests + 1
    local event = ensureRunScriptEvent(triggerId)
    local transactionHandler = event.handlers[script]
    if transactionHandler ~= nil then
        runScriptCacheStats.transactionHits = runScriptCacheStats.transactionHits + 1
        return invokeRunScriptWithPolicy(transactionHandler, triggerId, script, ...)
    end

    local handler = nil
    local sourceFingerprint = nil
    local warmKey = makeRunScriptWarmKey(event, script)
    if not RUNTIME_CACHE_DEVELOPMENT_BYPASS then
        local warmEntry = runScriptWarmCache[warmKey]
        if warmEntry ~= nil then
            runScriptCacheStats.warmHits = runScriptCacheStats.warmHits + 1
            warmEntry.hits = warmEntry.hits + 1
            touchRunScriptCacheEntry(warmEntry)
            handler = warmEntry.handler
        else
            runScriptCacheStats.warmMisses = runScriptCacheStats.warmMisses + 1
        end
    end

    if handler == nil then
        runScriptCacheStats.sourceFetches = runScriptCacheStats.sourceFetches + 1
        local source = loadScriptLore(triggerId, script)
        if not source then
            runScriptCacheStats.missingSources = runScriptCacheStats.missingSources + 1
            debug(1, "runScript error: lorebook '" .. script .. "' not found.")
            return nil
        end
        handler, sourceFingerprint = instantiateRunScriptHandler(script, source)
        if handler == nil then
            return nil
        end
        if not RUNTIME_CACHE_DEVELOPMENT_BYPASS then
            storeRunScriptWarmHandler(warmKey, event, script, handler, sourceFingerprint)
        end
    end

    if event.handlerCount < RUN_SCRIPT_TRANSACTION_MAX_ENTRIES then
        event.handlers[script] = handler
        event.handlerCount = event.handlerCount + 1
    else
        runScriptCacheStats.transactionCapacitySkips = runScriptCacheStats.transactionCapacitySkips + 1
    end

    return invokeRunScriptWithPolicy(handler, triggerId, script, ...)
end

--로어북에서 db를 호출해 return
function loadDB(triggerId, db)
    local lores = getLoreBooks(triggerId, db)

    if #lores == 0 then
        debug(1, "loadDB error: lorebook '" .. db .. "' not found.")
        return nil
    end

    local merged = {}
    local loadedCount = 0

    for _, lore in ipairs(lores) do
        local ok, decoded = pcall(json.decode, lore.content)

        if not ok or decoded == nil then
            debug(1, "loadDB error: invalid json in lorebook '" .. db .. "'.")
            return nil
        end

        if type(decoded) ~= "table" then
            return decoded
        end

        loadedCount = loadedCount + 1
        for k, v in pairs(decoded) do
            if type(k) == "number" then
                table.insert(merged, v)
            else
                merged[k] = v
            end
        end
    end

    if loadedCount == 0 then
        return nil
    end

    return merged
end

--변수를 로어북으로 저장
function saveDB(triggerId, name, data, ...)
    if data == nil then
        debug(1, "saveDB error: data is nil.")
        return
    end
    upsertLocalLoreBook(triggerId, name, json.encode(data), ...)
    debug(2, "saveDB: "..name.." saved successfully.")
    debug(3, name, json.encode(data))
end

--구분자로 문자열을 나누어 return
function splitByDelimiter(text, delimiter)
    local result = {}
    local source = tostring(text or "")
    local startIndex = 1

    while true do
        local foundStart, foundEnd = string.find(source, delimiter, startIndex, true)

        if not foundStart then
            table.insert(result, string.sub(source, startIndex))
            break
        end

        table.insert(result, string.sub(source, startIndex, foundStart - 1))
        startIndex = foundEnd + 1
    end

    return result
end

    return function(triggerId, action, ...)
        if action == "install" then
            return true
        elseif action == "beginEvent" then
            return beginRunScriptEvent(triggerId, ...)
        elseif action == "run" then
            return runScript(triggerId, ...)
        elseif action == "diagnostics" then
            return getRunScriptCacheDiagnostics()
        elseif action == "clearCache" then
            return clearRunScriptCache(...)
        elseif action == "setDevelopmentMode" then
            return setRunScriptCacheDevelopmentMode(...)
        end
        error("unsupported runtime action: " .. tostring(action))
    end
end)()
