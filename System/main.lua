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
        data = getState(triggerId, name)
    end

    if type(data) ~= "table" then
        setChatVar(triggerId, name, tostring(data))
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
    setChatVar(triggerId, name, encoded)
    return encoded
end

--chatVar를 state 형식으로 저장
function toState(triggerId, name)
    local source = getChatVar(triggerId, name)

    if not source or source == "" then
        debug(1, "toState error: chat var " .. tostring(name) .. " is empty.")
        setState(triggerId, name, {})
        return getState(triggerId, name)
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
        setState(triggerId, name, source)
        return source
    end

    local decoded = decodeFromChatVar(root)
    setState(triggerId, name, decoded)
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
    or "runtime-bundle-battle-history-v3-20260731"
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
    if type(setChatVar) == "function" then
        local writeOk = pcall(setChatVar, triggerId, RUN_SCRIPT_NAMESPACE_VAR, generated)
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

function getRunScriptCacheDiagnostics()
    local diagnostics = {
        bundleRevision = currentRunScriptBundleRevision(),
        developmentBypass = RUNTIME_CACHE_DEVELOPMENT_BYPASS,
        cacheEpoch = runScriptCacheEpoch,
        currentMode = currentRuntimeMode,
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

function runScript(triggerId, script, ...)
    runScriptCacheStats.requests = runScriptCacheStats.requests + 1
    local event = ensureRunScriptEvent(triggerId)
    local transactionHandler = event.handlers[script]
    if transactionHandler ~= nil then
        runScriptCacheStats.transactionHits = runScriptCacheStats.transactionHits + 1
        return invokeRunScriptHandler(transactionHandler, triggerId, ...)
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

    return invokeRunScriptHandler(handler, triggerId, ...)
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

local function controllerSucceeded(label, report)
    if type(report) ~= "table" then
        debug(1, label .. ": battleController가 결과를 반환하지 않았습니다.")
        return false
    end
    if report.ok == true then
        return true
    end

    local errors = type(report.errors) == "table" and report.errors or {}
    if #errors == 0 then
        debug(1, label .. ": battleController가 상세 오류 없이 실패했습니다.")
        return false
    end
    for _, item in ipairs(errors) do
        if type(item) == "table" then
            debug(
                1,
                label
                    .. ": " .. tostring(item.code)
                    .. " at " .. tostring(item.path)
                    .. ": " .. tostring(item.message)
            )
        else
            debug(1, label .. ": " .. tostring(item))
        end
    end
    return false
end

local UI_ANCHOR_MARKER = "@@HELLTRAIN_UI_ANCHOR_V1@@"
local UI_BODY_VAR = "🔯🔯🔯"
local UI_SHELL_VAR = "helltrainUiShellV1"
local UI_POPUP_VAR = "helltrainUiPopupV1"
local UI_ANCHOR_INDEX_VAR = "helltrainUiAnchorIndexV1"
local UI_READY_VAR = "gameSetupReady"
local APPROACH_RETRY_VAR = "helltrainApproachRetryV1"
local RUN_PROGRESSION_AUTHORITY_KEY = "runProgressionV1.authority"
local APPROACH_REQUEST_ATTEMPTS = 1
local SETUP_START_MARKUP = [[<section class="helltrain-setup" aria-labelledby="helltrain-start-title">
<p class="helltrain-setup-label">BOARDING PROTOCOL</p>
<h2 class="helltrain-setup-title" id="helltrain-start-title">지옥철에 탑승하시겠습니까?</h2>
<p class="helltrain-setup-copy" id="helltrain-start-copy">게임을 시작하면 초기 상태를 만들고, 덱을 구성하기 위한 카드 드래프트를 엽니다.</p>
<button class="helltrain-start" type="button" risu-btn="init|start" aria-describedby="helltrain-start-copy">게임 시작</button>
</section>]]
local APPROACH_PROCESSING_MARKUP = [[<style>
.helltrain-approach-processing,
.helltrain-approach-processing * {
box-sizing: border-box;
}
.helltrain-approach-processing {
--approach-bg: #0d0c12;
--approach-panel: rgba(22, 19, 28, .96);
--approach-line: rgba(220, 204, 176, .2);
--approach-text: #ece6dc;
--approach-muted: #afa69d;
--approach-accent: #e06a70;
display: grid;
width: min(100%, 600px);
min-height: 180px;
margin: 8px auto;
place-items: center;
overflow: hidden;
border: 1px solid var(--approach-line);
border-radius: 16px;
background:
radial-gradient(circle at 50% 0%, rgba(224, 106, 112, .12), transparent 48%),
var(--approach-bg);
color: var(--approach-text);
box-shadow: 0 18px 48px rgba(0, 0, 0, .32);
font-family: Pretendard, "Noto Sans KR", system-ui, sans-serif;
}
.helltrain-approach-processing__body {
display: flex;
align-items: center;
flex-direction: column;
padding: 34px 24px;
text-align: center;
}
.helltrain-approach-processing__spinner {
position: relative;
width: 34px;
height: 34px;
margin-bottom: 16px;
border: 2px solid rgba(255, 255, 255, .1);
border-top-color: var(--approach-accent);
border-radius: 50%;
animation: helltrain-approach-spin .85s linear infinite;
}
.helltrain-approach-processing__spinner::after {
position: absolute;
inset: 6px;
border: 1px solid rgba(224, 106, 112, .22);
border-radius: inherit;
content: "";
}
.helltrain-approach-processing__label {
margin: 0;
font-size: 15px;
font-weight: 850;
letter-spacing: .04em;
}
.helltrain-approach-processing__dot {
display: inline-block;
animation: helltrain-approach-dot 1.2s ease-in-out infinite;
}
.helltrain-approach-processing__dot:nth-child(2) {
animation-delay: .15s;
}
.helltrain-approach-processing__dot:nth-child(3) {
animation-delay: .3s;
}
.helltrain-approach-processing__copy {
margin: 9px 0 0;
color: var(--approach-muted);
font-size: 11px;
}
@keyframes helltrain-approach-spin {
to { transform: rotate(360deg); }
}
@keyframes helltrain-approach-dot {
0%, 70%, 100% { opacity: .28; transform: translateY(0); }
35% { opacity: 1; transform: translateY(-2px); }
}
@media (prefers-reduced-motion: reduce) {
.helltrain-approach-processing__spinner,
.helltrain-approach-processing__dot {
animation: none;
}
}
</style>
<section class="helltrain-approach-processing" role="status" aria-live="polite" aria-label="처리중...">
<div class="helltrain-approach-processing__body">
<span class="helltrain-approach-processing__spinner" aria-hidden="true"></span>
<p class="helltrain-approach-processing__label">처리중<span aria-hidden="true"><span class="helltrain-approach-processing__dot">.</span><span class="helltrain-approach-processing__dot">.</span><span class="helltrain-approach-processing__dot">.</span></span></p>
<p class="helltrain-approach-processing__copy">선택한 상대에게 접근하는 장면을 만들고 있습니다.</p>
</div>
</section>]]

local function readUiFragment(triggerId, name)
    if type(getChatVar) ~= "function" then
        return ""
    end
    local ok, value = pcall(getChatVar, triggerId, name)
    return ok and type(value) == "string" and value ~= "null" and value or ""
end

local function parseUiAnchorIndex(rawIndex)
    local index = tonumber(rawIndex)
    if index == nil or index % 1 ~= 0 or index < -1 then
        return nil
    end
    return index
end

local function isExactUiAnchorMessage(message)
    return type(message) == "table"
        and message.role == "user"
        and message.data == UI_ANCHOR_MARKER
end

-- 현재 UI 전용 사용자 메시지만 다시 그린다. 초기 진입 전에는 first message의
-- -1 anchor를 사용하고, 게임 시작 뒤에는 실제 채팅 인덱스를 chatVar로 추적한다.
function refreshGameUi(triggerId)
    local rawIndex = readUiFragment(triggerId, UI_ANCHOR_INDEX_VAR)
    local index = parseUiAnchorIndex(rawIndex)
    if index == nil then
        index = -1
        if rawIndex ~= "" then
            debug(2, "invalid UI anchor index; falling back to first message: " .. tostring(rawIndex))
        end
    end
    if type(reloadChat) == "function" then
        local targetedOk, targetedError = pcall(reloadChat, triggerId, index)
        if targetedOk then
            return true
        end
        debug(2, "targeted UI reload failed: " .. tostring(targetedError))
    end
    if type(reloadDisplay) ~= "function" then
        error("reloadChat/reloadDisplay host functions are unavailable")
    end
    reloadDisplay(triggerId)
    return true
end

-- 게임 UI를 장면 채팅과 분리된 마지막 user 메시지에 둔다. 같은 anchor가 이미
-- 마지막에 있으면 재사용하므로 onOutput/복구 훅이 중복 호출돼도 메시지가 늘지 않는다.
function ensureGameUiAnchor(triggerId)
    if type(getFullChat) ~= "function" or type(addChat) ~= "function" then
        error("getFullChat/addChat host functions are unavailable")
    end
    local readOk, chat = pcall(getFullChat, triggerId)
    if not readOk or type(chat) ~= "table" then
        error("failed to read chat for UI anchor: " .. tostring(chat))
    end

    local previousIndex = parseUiAnchorIndex(readUiFragment(triggerId, UI_ANCHOR_INDEX_VAR))
    if previousIndex == nil then
        previousIndex = -1
    end
    local anchorIndex
    if isExactUiAnchorMessage(chat[#chat]) then
        anchorIndex = #chat - 1
    else
        local addOk, addError = pcall(addChat, triggerId, "user", UI_ANCHOR_MARKER)
        if not addOk then
            error("failed to add UI anchor: " .. tostring(addError))
        end
        local verifyOk, after = pcall(getFullChat, triggerId)
        if not verifyOk
            or type(after) ~= "table"
            or #after ~= #chat + 1
            or not isExactUiAnchorMessage(after[#after]) then
            error("UI anchor write was not persisted")
        end
        anchorIndex = #after - 1
    end

    if type(setChatVar) ~= "function" then
        error("setChatVar host function is unavailable")
    end
    setChatVar(triggerId, UI_ANCHOR_INDEX_VAR, tostring(anchorIndex))
    if readUiFragment(triggerId, UI_ANCHOR_INDEX_VAR) ~= tostring(anchorIndex) then
        error("UI anchor index write was not persisted")
    end

    -- 새 anchor를 활성화한 뒤 이전 UI가 있던 메시지도 다시 그려 잔상을 없앤다.
    if previousIndex ~= nil and previousIndex ~= anchorIndex and type(reloadChat) == "function" then
        local retiredOk, retiredError = pcall(reloadChat, triggerId, previousIndex)
        if not retiredOk then
            debug(2, "previous UI anchor reload failed: " .. tostring(retiredError))
        end
    end
    refreshGameUi(triggerId)
    return anchorIndex
end

local function writeUiFragmentVerified(triggerId, name, value)
    if type(setChatVar) ~= "function" or type(getChatVar) ~= "function" then
        error("setChatVar/getChatVar host functions are unavailable")
    end
    setChatVar(triggerId, name, value)
    local stored = getChatVar(triggerId, name)
    if stored ~= value then
        error("UI fragment write was not persisted: " .. tostring(name))
    end
end

local function readApproachRetry(triggerId)
    if type(getChatVar) ~= "function" then
        error("getChatVar host function is unavailable")
    end
    local readOk, value = pcall(getChatVar, triggerId, APPROACH_RETRY_VAR)
    if not readOk then
        error("failed to read approach retry state: " .. tostring(value))
    end
    if value == nil or value == "" or value == "null" then
        return nil, nil
    end
    if type(value) ~= "string" then
        error("invalid approach retry state")
    end
    local separator = string.find(value, "|", 1, true)
    local phase = separator and string.sub(value, 1, separator - 1) or nil
    local characterId = separator and string.sub(value, separator + 1) or nil
    if (phase ~= "pending" and phase ~= "generated")
        or type(characterId) ~= "string"
        or string.match(characterId, "^[a-z][a-z0-9_]*$") == nil then
        error("invalid approach retry state")
    end
    return phase, characterId
end

local function writeApproachRetryVerified(triggerId, phase, characterId)
    local value = ""
    if phase ~= nil then
        value = phase .. "|" .. characterId
    end
    writeUiFragmentVerified(triggerId, APPROACH_RETRY_VAR, value)
end

local function showApproachProcessing(triggerId)
    writeUiFragmentVerified(triggerId, UI_BODY_VAR, APPROACH_PROCESSING_MARKUP)
    writeUiFragmentVerified(triggerId, UI_POPUP_VAR, "")
    writeUiFragmentVerified(triggerId, UI_READY_VAR, "ready")
    refreshGameUi(triggerId)
end

local function selectedApproachCharacter(triggerId, report, characterId)
    local selected = type(report) == "table"
        and type(report.view) == "table"
        and report.view.selectedCharacter
        or nil
    local name = type(selected) == "table" and selected.name or nil
    local profile = selected

    local staticOk, staticReport = pcall(
        runScript,
        triggerId,
        "staticData",
        "loadAll"
    )
    if staticOk
        and type(staticReport) == "table"
        and staticReport.ok == true
        and type(staticReport.data) == "table"
        and type(staticReport.data.characters) == "table"
        and type(staticReport.data.characters[characterId]) == "table" then
        profile = staticReport.data.characters[characterId]
        if type(profile.name) == "string" and profile.name ~= "" then
            name = profile.name
        end
    end

    if type(name) ~= "string" or name == "" then
        name = "선택한 캐릭터"
    end
    return name, profile
end

local function pastApproachEncounters(triggerId, report, characterId)
    local runState = type(report) == "table"
        and type(report.state) == "table"
        and report.state.kind == "runProgressionV1"
        and report.state
        or nil
    if runState == nil and type(getState) == "function" then
        local readOk, stored = pcall(getState, triggerId, RUN_PROGRESSION_AUTHORITY_KEY)
        if readOk and type(stored) == "table" and stored.kind == "runProgressionV1" then
            runState = stored
        end
    end

    local encounters = {}
    for sessionNumber, session in ipairs(
        type(runState) == "table" and type(runState.sessions) == "table" and runState.sessions or {}
    ) do
        if type(session) == "table" and session.characterId == characterId then
            encounters[#encounters + 1] = {
                sessionNumber = sessionNumber,
                result = session.status,
                reasonCode = session.reasonCode,
                turnNumber = session.turnNumber,
                turnLimit = session.turnLimit,
                finalStealth = session.finalStealth,
                finalResistance = session.finalResistance,
                environmentId = session.environmentId,
                transit = session.transit,
            }
        end
    end
    return encounters
end

local function encodeApproachData(value, fallback)
    if type(value) == "table" and type(json) == "table" and type(json.encode) == "function" then
        local encodeOk, result = pcall(json.encode, value)
        if encodeOk and type(result) == "string" then return result end
    end
    return fallback
end

local function buildApproachPrompt(characterName, profile, encounters)
    local encodedProfile = encodeApproachData(profile, "{}")
    local encodedEncounters = encodeApproachData(encounters, "[]")
    return {
        {
            role = "system",
            content = table.concat({
                "당신은 성인용 한국어 다크 픽션 롤플레이의 장면 서술자다.",
                "무한히 반복되는 지하철 안에서 플레이어가 선택한 성인 캐릭터에게 다가가는 순간을 2~4문단으로 묘사하라.",
                "캐릭터의 성격과 배경을 지키고, 아직 카드·수치·전투 UI나 게임 규칙은 언급하지 마라.",
                "플레이어가 입력하지 않은 추가 행동·대사·생각은 만들어내지 마라.",
                "선택한 캐릭터의 자연스러운 행동과 반응, 객실의 분위기에 집중하라.",
                "과거 조우 정보가 있으면 캐릭터는 플레이어를 분명히 알아보고, 이전 결과에 맞는 기억과 태도를 자연스럽게 드러내라. 정보가 없으면 초면으로 묘사하라.",
                "과거 결과의 victory는 플레이어가 캐릭터의 저항을 무너뜨린 경우이고, defeat는 캐릭터가 플레이어를 물리친 경우다.",
                "과거 조우 정보의 내부 ID와 수치는 직접 나열하지 말고 관계의 기억으로만 반영하라.",
                "대상 캐릭터: " .. characterName,
                "캐릭터 자료(JSON): " .. encodedProfile,
                "과거 조우 정보(JSON): " .. encodedEncounters,
            }, "\n"),
        },
        {
            role = "user",
            content = characterName .. "에게 접근한다.",
        },
    }
end

local function appendChatVerified(triggerId, role, content)
    if type(getFullChat) ~= "function" or type(addChat) ~= "function" then
        error("getFullChat/addChat host functions are unavailable")
    end
    local before = getFullChat(triggerId)
    if type(before) ~= "table" then
        error("failed to read chat before append")
    end
    addChat(triggerId, role, content)
    local after = getFullChat(triggerId)
    local appended = type(after) == "table" and after[#after] or nil
    if type(after) ~= "table"
        or #after ~= #before + 1
        or type(appended) ~= "table"
        or appended.role ~= role
        or appended.data ~= content then
        error("chat append was not persisted")
    end
end

local function generateApproachScene(triggerId, report, characterId)
    if type(LLM) ~= "function" then
        return nil, "LLM 함수를 사용할 수 없습니다. Lua 스크립트의 low-level access를 활성화해야 합니다."
    end
    local characterName, profile = selectedApproachCharacter(triggerId, report, characterId)
    local approachMessage = characterName .. "에게 접근한다."
    local chat = getFullChat(triggerId)
    local last = type(chat) == "table" and chat[#chat] or nil
    local previous = type(chat) == "table" and chat[#chat - 1] or nil
    if type(last) == "table"
        and last.role == "char"
        and type(last.data) == "string"
        and last.data:match("%S") ~= nil
        and type(previous) == "table"
        and previous.role == "user"
        and previous.data == approachMessage then
        return last.data, nil
    end
    if type(last) ~= "table"
        or last.role ~= "user"
        or last.data ~= approachMessage then
        appendChatVerified(triggerId, "user", approachMessage)
    end

    local encounters = pastApproachEncounters(triggerId, report, characterId)
    local prompt = buildApproachPrompt(characterName, profile, encounters)
    local lastError = "알 수 없는 LLM 오류"
    for _ = 1, APPROACH_REQUEST_ATTEMPTS do
        local requestOk, response = pcall(LLM, triggerId, prompt, false, { streaming = true })
        if requestOk
            and type(response) == "table"
            and response.success == true
            and type(response.result) == "string"
            and response.result:match("%S") ~= nil then
            appendChatVerified(triggerId, "char", response.result)
            return response.result, nil
        end
        if requestOk and type(response) == "table" and response.result ~= nil then
            lastError = tostring(response.result)
        elseif not requestOk then
            lastError = tostring(response)
        end
    end
    return nil, lastError
end

local function removeApproachRetryFiller(triggerId)
    if type(getFullChat) ~= "function" then
        error("getFullChat host function is unavailable")
    end
    local chat = getFullChat(triggerId)
    local last = type(chat) == "table" and chat[#chat] or nil
    if type(last) ~= "table"
        or last.role ~= "user"
        or last.data ~= "*says nothing*" then
        return
    end
    if type(removeChat) ~= "function" then
        error("removeChat host function is unavailable")
    end
    removeChat(triggerId, #chat - 1)
    local after = getFullChat(triggerId)
    if type(after) ~= "table" or #after ~= #chat - 1 then
        error("approach retry filler removal was not persisted")
    end
end

local function finishApproachTransition(triggerId)
    local report = runScript(triggerId, "init", "start")
    if not controllerSucceeded("approach.init.start", report) then
        return false
    end
    local anchorOk, anchorError = pcall(ensureGameUiAnchor, triggerId)
    if not anchorOk then
        debug(1, "approach: Battle UI anchor 생성 실패: " .. tostring(anchorError))
        return false
    end
    return true
end

local function resumeApproachTransition(triggerId, report, characterId, phase)
    removeApproachRetryFiller(triggerId)
    if phase == "pending" then
        showApproachProcessing(triggerId)
        local output, generationError = generateApproachScene(
            triggerId,
            report,
            characterId
        )
        if output == nil then
            return false, generationError
        end
        writeApproachRetryVerified(triggerId, "generated", characterId)
    end
    if not finishApproachTransition(triggerId) then
        return false, "전투 화면으로 전환하지 못했습니다."
    end
    writeApproachRetryVerified(triggerId, nil, nil)
    return true, nil
end

local function resumeApproachWithAlert(triggerId, report, characterId, phase)
    local runOk, completed, detail = pcall(
        resumeApproachTransition,
        triggerId,
        report,
        characterId,
        phase
    )
    if runOk and completed then
        return true
    end
    detail = runOk and detail or completed
    debug(1, "character approach: 생성 또는 전환 실패: " .. tostring(detail))
    if type(alertError) == "function" then
        pcall(
            alertError,
            triggerId,
            "접근 장면을 생성하지 못했습니다. 전송 버튼을 눌러 다시 시도하세요.\n"
                .. tostring(detail)
        )
    end
    return false
end

-- outer CBS가 이미 계산된 msgDisplay를 특정 메시지만 remount해도 최신 UI로
-- 바꿀 수 있도록, exact sentinel을 editDisplay 단계에서 렌더된 fragment로 치환한다.
listenEdit("editDisplay", function(triggerId, data, meta)
    beginRunScriptEvent(triggerId, "editDisplay")
    if type(data) ~= "string" then
        return data
    end
    local markerStart = string.find(data, UI_ANCHOR_MARKER, 1, true)
    if markerStart == nil then
        return data
    end

    local index = type(meta) == "table" and meta.index or nil
    local dedicatedAnchor = data == UI_ANCHOR_MARKER and type(index) == "number" and index >= 0
    local activeIndex = parseUiAnchorIndex(readUiFragment(triggerId, UI_ANCHOR_INDEX_VAR))
    local renderHere = (dedicatedAnchor and activeIndex == index)
        or (index == -1 and (activeIndex == nil or activeIndex == -1))
    if not renderHere then
        local markerEnd = markerStart + #UI_ANCHOR_MARKER - 1
        return string.sub(data, 1, markerStart - 1)
            .. string.sub(data, markerEnd + 1)
    end

    local rendered = SETUP_START_MARKUP
    if readUiFragment(triggerId, UI_READY_VAR) == "ready" then
        rendered = readUiFragment(triggerId, UI_SHELL_VAR)
            .. readUiFragment(triggerId, UI_BODY_VAR)
            .. readUiFragment(triggerId, UI_POPUP_VAR)
    end
    local markerEnd = markerStart + #UI_ANCHOR_MARKER - 1
    return string.sub(data, 1, markerStart - 1)
        .. rendered
        .. string.sub(data, markerEnd + 1)
end)

--전투 중 입력은 filler로 정규화하되, 조기 승리 뒤 자유행동은 원문을 보존
listenEdit("editInput", function(triggerId, data)
    beginRunScriptEvent(triggerId, "editInput")
    local readOk, authority = pcall(
        getState,
        triggerId,
        "battleRuntimeV1.authority"
    )
    if readOk
        and type(authority) == "table"
        and authority.kind == "battleState" then
        local aftermathOk, aftermath = pcall(
            getState,
            triggerId,
            "battleRuntimeV1.aftermath"
        )
        if aftermathOk
            and type(aftermath) == "table"
            and aftermath.kind == "battleAftermath"
            and aftermath.battleId == authority.battleId
            and aftermath.phase == "ready" then
            return data
        end
        return "*says nothing*"
    end
    return data
end)

--버튼 클릭시 동작
local BUTTON_ACTIONS = {
    init = { start = true, choose = true, chooseCharacter = true },
    battleController = { clickCard = true, registerCard = true, cancelCard = true },
    popupManage = { root = true, push = true, replace = true, back = true, close = true },
}

local function isAllowedButtonRoute(script, arguments)
    local actions = BUTTON_ACTIONS[script]
    local action = arguments[1]
    if type(actions) ~= "table" or actions[action] ~= true then
        return false
    end
    if script == "init" then
        return (action == "start" and #arguments == 1)
            or (action == "choose" and #arguments == 3)
            or (action == "chooseCharacter" and #arguments == 3)
    elseif script == "battleController" then
        return #arguments == 3
    elseif action == "back" or action == "close" then
        return #arguments == 1
    end
    return #arguments >= 3 and #arguments <= 5
end

onButtonClick = async(function(triggerId, data)
    beginRunScriptEvent(triggerId, "onButtonClick")
    --risu-btn 값을 "스크립트|인자1|인자2" 형식으로 해석
    local parts = splitByDelimiter(data, "|")
    local script = table.remove(parts, 1)

    if not script or script == "" then
        debug(1, "button dispatch error: empty script.")
        return
    end
    if not isAllowedButtonRoute(script, parts) then
        debug(1, "button dispatch error: disallowed route " .. tostring(script) .. ".")
        return
    end
    debug(3, "Button route: " .. tostring(script) .. "|" .. tostring(parts[1]))

    local report = runScript(triggerId, script, table.unpack(parts))
    if script == "init" and parts[1] == "start" then
        if controllerSucceeded("onButtonClick.init.start", report) then
            local anchorOk, anchorError = pcall(ensureGameUiAnchor, triggerId)
            if not anchorOk then
                debug(1, "onButtonClick.init.start: UI anchor 생성 실패: " .. tostring(anchorError))
            end
        end
    elseif script == "init"
        and parts[1] == "chooseCharacter"
        and type(report) == "table"
        and report.ok == true
        and report.applied == true then
        local stateOk, stateError = pcall(
            writeApproachRetryVerified,
            triggerId,
            "pending",
            parts[2]
        )
        if not stateOk then
            debug(1, "character approach: 재시도 상태 저장 실패: " .. tostring(stateError))
            if type(alertError) == "function" then
                pcall(alertError, triggerId, "접근 장면의 재시도 상태를 저장하지 못했습니다.")
            end
            return
        end
        resumeApproachWithAlert(
            triggerId,
            report,
            parts[2],
            "pending"
        )
    end
end)

--정상 요청에 저장된 비공개 턴 사건과 사용자 장면 지시를 request에만 추가
listenEdit("editRequest", function(triggerId, data)
    beginRunScriptEvent(triggerId, "editRequest")
    local report = runScript(
        triggerId,
        "battleController",
        "injectRequest",
        data
    )
    if not controllerSucceeded("editRequest", report) then
        return data
    end
    if type(report.promptArray) ~= "table" then
        debug(1, "editRequest: 주입된 promptArray가 없습니다.")
        return data
    end
    return report.promptArray
end)

--수동 전송의 턴 준비·실패 복구·commit-only 복구
onStart = async(function(triggerId)
    beginRunScriptEvent(triggerId, "onStart")
    local retryReadOk, retryPhase, retryCharacterId = pcall(
        readApproachRetry,
        triggerId
    )
    if not retryReadOk then
        debug(1, "onStart: 접근 장면 재시도 상태 읽기 실패: " .. tostring(retryPhase))
        if type(alertError) == "function" then
            pcall(alertError, triggerId, "접근 장면의 재시도 상태가 올바르지 않습니다.")
        end
        return false
    end
    if retryPhase ~= nil then
        resumeApproachWithAlert(
            triggerId,
            nil,
            retryCharacterId,
            retryPhase
        )
        return false
    end
    local report = runScript(
        triggerId,
        "battleController",
        "prepareGeneration"
    )
    if not controllerSucceeded("onStart", report) then
        return false
    end

    if report.commitRecovered == true or report.uiAnchorRequired == true then
        local anchorOk, anchorError = pcall(ensureGameUiAnchor, triggerId)
        if not anchorOk then
            debug(1, "onStart: 복구 UI anchor 생성 실패: " .. tostring(anchorError))
            return false
        end
    end

    -- 관측된 출력을 보존하고 commit만 복구한 경우 새 HTTP 요청은 취소한다.
    return report.generationReady == true
end)

--완성 응답을 관측한 뒤 턴을 한 번만 확정
onOutput = async(function(triggerId)
    beginRunScriptEvent(triggerId, "onOutput")
    local report = runScript(
        triggerId,
        "battleController",
        "commitOutput"
    )
    if controllerSucceeded("onOutput", report) and report.outputCommitted == true then
        local anchorOk, anchorError = pcall(ensureGameUiAnchor, triggerId)
        if not anchorOk then
            debug(1, "onOutput: 다음 턴 UI anchor 생성 실패: " .. tostring(anchorError))
        end
    end
end)

--[[
게임 시작시 필요한 db를 챗변수로 저장하는 프로세스 필요
    퍼메를 세팅용으로 구성하고 세팅이 완료되기 전에는 onStart에서 return false로 채팅 보내는것을 막을 것.
]]
