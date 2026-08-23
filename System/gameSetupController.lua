(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991
    local AUTHORITY_KEY = "gameSetupV1.authority"
    local VIEW_NAME = "gameSetupView"
    local RUN_AUTHORITY_KEY = "runProgressionV1.authority"
    local RUN_VIEW_NAME = "runProgressionView"
    local READY_NAME = "gameSetupReady"
    local UI_NAME = "🔯🔯🔯"
    local UI_SHELL_NAME = "helltrainUiShellV1"
    local UI_SHELL_REVISION_NAME = "helltrainUiShellRevision"
    local UI_SHELL_REVISION = "sidebar-e3f104ae8f3037cd"
    local DIAGNOSTIC_SCOPE = "helltrain.gameSetupController"
    local arguments = { ... }
    local argumentCount = select("#", ...)

    local function diagnosticText(value)
        return tostring(value):gsub("[\r\n]+", " ")
    end

    local function emitDiagnostic(depth, event, fields)
        if type(DEBUG) ~= "number" or depth > DEBUG then
            return
        end

        if type(print) ~= "function" then
            return
        end

        local parts = {
            "[" .. DIAGNOSTIC_SCOPE .. "]",
            "depth=" .. tostring(depth),
            "event=" .. diagnosticText(event),
        }
        for _, key in ipairs({ "action", "errorCount", "code", "path", "message" }) do
            local value = type(fields) == "table" and fields[key] or nil
            if value ~= nil then
                parts[#parts + 1] = key .. "=" .. diagnosticText(value)
            end
        end
        pcall(print, table.concat(parts, " | "))

        for index, item in ipairs(type(fields) == "table" and type(fields.errors) == "table" and fields.errors or {}) do
            local errorParts = {
                "[" .. DIAGNOSTIC_SCOPE .. "]",
                "depth=" .. tostring(depth),
                "event=request_error",
                "index=" .. tostring(index),
            }
            for _, key in ipairs({ "code", "path", "message" }) do
                if type(item) == "table" and item[key] ~= nil then
                    errorParts[#errorParts + 1] = key .. "=" .. diagnosticText(item[key])
                end
            end
            pcall(print, table.concat(errorParts, " | "))
        end
    end

    local function makeError(code, path, message)
        return {
            code = code,
            path = path,
            message = message,
        }
    end

    local function failure(errors)
        return {
            ok = false,
            schemaVersion = SCHEMA_VERSION,
            errors = errors,
        }
    end

    local function success(fields)
        local report = {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
        }
        for key, value in pairs(fields or {}) do
            report[key] = value
        end
        return report
    end

    local function isFinite(value)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
    end

    local function isSafeInteger(value, minimum)
        return isFinite(value)
            and value % 1 == 0
            and math.abs(value) <= MAX_SAFE_INTEGER
            and (minimum == nil or value >= minimum)
    end

    local function objectPath(path, key)
        if type(key) == "string" and string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", tostring(key)) .. "]"
    end

    local function cloneJson(value, path, active)
        local valueType = type(value)
        if valueType == "nil" or valueType == "string" or valueType == "boolean" then
            return value, nil
        end
        if valueType == "number" then
            if not isFinite(value) then
                return nil, makeError("non_finite_number", path, "유한하지 않은 숫자는 컨트롤러 데이터에 사용할 수 없습니다.")
            end
            return value, nil
        end
        if valueType ~= "table" then
            return nil, makeError(
                "unsupported_type",
                path,
                "JSON 컨트롤러 데이터에 사용할 수 없는 자료형입니다: " .. valueType
            )
        end
        if getmetatable(value) ~= nil then
            return nil, makeError("metatable_not_allowed", path, "컨트롤러 데이터에는 메타테이블을 사용할 수 없습니다.")
        end

        active = active or {}
        if active[value] then
            return nil, makeError("circular_reference", path, "순환 참조는 컨트롤러 데이터에 사용할 수 없습니다.")
        end
        active[value] = true

        local hasNumeric = false
        local hasString = false
        local numericCount = 0
        local maximum = 0
        for key in pairs(value) do
            if type(key) == "number" then
                hasNumeric = true
                if not isSafeInteger(key, 1) then
                    active[value] = nil
                    return nil, makeError("invalid_array_index", path, "배열 인덱스는 1 이상의 정수여야 합니다.")
                end
                numericCount = numericCount + 1
                if key > maximum then
                    maximum = key
                end
            elseif type(key) == "string" then
                hasString = true
            else
                active[value] = nil
                return nil, makeError("invalid_object_key", path, "객체 키는 문자열이어야 합니다.")
            end
        end
        if hasNumeric and hasString then
            active[value] = nil
            return nil, makeError("mixed_table", path, "숫자 인덱스와 문자열 키를 함께 사용할 수 없습니다.")
        end
        if hasNumeric and numericCount ~= maximum then
            active[value] = nil
            return nil, makeError("sparse_array", path, "배열 인덱스는 1부터 빈틈없이 이어져야 합니다.")
        end

        local copy = {}
        if hasNumeric then
            for index = 1, maximum do
                local itemCopy, itemError = cloneJson(value[index], path .. "[" .. index .. "]", active)
                if itemError then
                    active[value] = nil
                    return nil, itemError
                end
                copy[index] = itemCopy
            end
        else
            for key, item in pairs(value) do
                local itemCopy, itemError = cloneJson(item, objectPath(path, key), active)
                if itemError then
                    active[value] = nil
                    return nil, itemError
                end
                copy[key] = itemCopy
            end
        end
        active[value] = nil
        return copy, nil
    end

    local function deepEqual(left, right, active)
        if type(left) ~= type(right) then
            return false
        end
        if type(left) ~= "table" then
            return left == right
        end
        if getmetatable(left) ~= nil or getmetatable(right) ~= nil then
            return false
        end
        active = active or {}
        if active[left] ~= nil then
            return active[left] == right
        end
        active[left] = right
        for key, value in pairs(left) do
            if not deepEqual(value, right[key], active) then
                active[left] = nil
                return false
            end
        end
        for key in pairs(right) do
            if left[key] == nil then
                active[left] = nil
                return false
            end
        end
        active[left] = nil
        return true
    end

    local function appendNestedErrors(target, moduleName, report)
        if type(report) == "table" and type(report.errors) == "table" then
            for index, item in ipairs(report.errors) do
                if type(item) == "table"
                    and type(item.code) == "string"
                    and type(item.path) == "string"
                    and type(item.message) == "string" then
                    target[#target + 1] = makeError(item.code, item.path, item.message)
                else
                    target[#target + 1] = makeError(
                        "invalid_nested_error",
                        "$.runtime." .. moduleName .. ".errors[" .. index .. "]",
                        "하위 모듈 오류 항목이 올바른 구조가 아닙니다."
                    )
                end
            end
        end
        if #target == 0 then
            target[1] = makeError(
                "module_failed_without_errors",
                "$.runtime." .. moduleName,
                moduleName .. "이 오류 상세 없이 실패했습니다."
            )
        end
    end

    local function validateErrorArray(moduleName, errors)
        if type(errors) ~= "table" or getmetatable(errors) ~= nil then
            return false
        end
        local count = 0
        local maximum = 0
        for key, item in pairs(errors) do
            if type(key) ~= "number" or not isSafeInteger(key, 1) then
                return false
            end
            count = count + 1
            if key > maximum then maximum = key end
            if type(item) ~= "table"
                or getmetatable(item) ~= nil
                or type(item.code) ~= "string"
                or type(item.path) ~= "string"
                or type(item.message) ~= "string" then
                return false
            end
        end
        return count == maximum
    end

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError("runtime_unavailable", "$.runtime", "runScript 실행기를 찾을 수 없습니다."),
            }
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok then
            return nil, {
                makeError(
                    "module_call_error",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. " 호출 중 오류가 발생했습니다: " .. tostring(report)
                ),
            }
        end
        if type(report) ~= "table" or getmetatable(report) ~= nil then
            return nil, {
                makeError(
                    "invalid_module_result",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. "이 일반 테이블 결과를 반환하지 않았습니다."
                ),
            }
        end

        local isBridge = moduleName == "dataBridge"
        local versionOk = report.schemaVersion == SCHEMA_VERSION
            or (isBridge and report.schemaVersion == nil and report.wireFormat == "cbs-json-nodes-v1")
        local errorsOk = validateErrorArray(moduleName, report.errors)
            or (isBridge and report.ok == true and report.errors == nil)
        if (report.ok ~= true and report.ok ~= false) or not versionOk or not errorsOk then
            return nil, {
                makeError(
                    "invalid_module_envelope",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. " 결과 envelope가 올바르지 않습니다."
                ),
            }
        end
        if report.ok ~= true then
            local errors = {}
            appendNestedErrors(errors, moduleName, report)
            return nil, errors
        end
        if type(report.errors) == "table" and #report.errors ~= 0 then
            return nil, {
                makeError(
                    "success_with_errors",
                    "$.runtime." .. moduleName .. ".errors",
                    "성공한 하위 모듈 결과에 오류가 포함되어 있습니다."
                ),
            }
        end
        return report, nil
    end

    local function loadStaticData()
        local report, errors = callModule("staticData", "loadAll")
        if errors then return nil, errors end
        if type(report.data) ~= "table" or getmetatable(report.data) ~= nil then
            return nil, {
                makeError("missing_static_data", "$.runtime.staticData.data", "검증된 전체 정적 데이터가 없습니다."),
            }
        end
        return report.data, nil
    end

    local function readAuthority(required)
        if type(HostCompat) ~= "table" or type(HostCompat.readState) ~= "function" then
            return nil, {
                makeError("state_read_unavailable", "$.host.getState", "상태 읽기 호환 함수를 찾을 수 없습니다."),
            }
        end
        local ok, value = pcall(HostCompat.readState, triggerId, AUTHORITY_KEY)
        if not ok then
            return nil, {
                makeError("state_read_failed", "$.state.authority", "게임 설정 상태를 읽지 못했습니다: " .. tostring(value)),
            }
        end
        if value == nil then
            if required then
                return nil, {
                    makeError("missing_authority", "$.state.authority", "먼저 게임 설정을 시작해야 합니다."),
                }
            end
            return nil, nil
        end
        local copy, copyError = cloneJson(value, "$.state.authority")
        if copyError then return nil, { copyError } end
        return copy, nil
    end

    local function readRunAuthority(required)
        if type(HostCompat) ~= "table" or type(HostCompat.readState) ~= "function" then
            return nil, {
                makeError("state_read_unavailable", "$.host.getState", "상태 읽기 호환 함수를 찾을 수 없습니다."),
            }
        end
        local ok, value = pcall(HostCompat.readState, triggerId, RUN_AUTHORITY_KEY)
        if not ok then
            return nil, {
                makeError("state_read_failed", "$.state.runAuthority", "진행 상태를 읽지 못했습니다: " .. tostring(value)),
            }
        end
        if value == nil then
            if required then
                return nil, {
                    makeError("missing_run_authority", "$.state.runAuthority", "전투 후 진행 상태가 없습니다."),
                }
            end
            return nil, nil
        end
        local copy, copyError = cloneJson(value, "$.state.runAuthority")
        if copyError then return nil, { copyError } end
        return copy, nil
    end

    local function generateSetupSeed()
        if type(cbs) ~= "function" then
            return nil, {
                makeError("cbs_unavailable", "$.host.cbs", "초기 seed를 만들 CBS 함수를 찾을 수 없습니다."),
            }
        end
        -- getLoreBooks가 Lua 로어를 반환하기 전에 CBS를 평가하므로,
        -- 소스에 완성된 동적 매크로를 두면 컴파일 캐시가 첫 seed를
        -- 고정할 수 있다. 호스트 cbs 호출 직전에만 문자열을 조립한다.
        local seedMacro = string.rep("{", 2)
            .. "randint::1::2147483646"
            .. string.rep("}", 2)
        local ok, rendered = pcall(cbs, seedMacro)
        if not ok then
            return nil, {
                makeError("seed_generation_failed", "$.host.cbs", "초기 seed 생성에 실패했습니다: " .. tostring(rendered)),
            }
        end
        if type(rendered) ~= "string" or string.match(rendered, "^[1-9][0-9]*$") == nil then
            return nil, {
                makeError(
                    "invalid_generated_seed",
                    "$.host.cbs.result",
                    "CBS randint 결과는 앞뒤 문자가 없는 양의 십진 정수여야 합니다."
                ),
            }
        end
        local seed = tonumber(rendered)
        if not isSafeInteger(seed, 1) or seed > 2147483646 then
            return nil, {
                makeError(
                    "generated_seed_out_of_range",
                    "$.host.cbs.result",
                    "초기 seed는 1부터 2147483646 사이의 정수여야 합니다."
                ),
            }
        end
        return seed, nil
    end

    local function loadSetupUi(phase)
        if type(loadLores) ~= "function" then
            return nil, {
                makeError("lore_loader_unavailable", "$.host.loadLores", "UI 로어북을 읽을 loadLores 함수를 찾을 수 없습니다."),
            }
        end
        local loreName
        local lorePath
        if phase == "deckDraft" or phase == "deckComplete" then
            loreName = "cardDraft.html"
            lorePath = "$.lore.cardDraft"
        elseif phase == "characterSelect" then
            loreName = "characterSelect.html"
            lorePath = "$.lore.characterSelect"
        else
            return nil, {
                makeError("invalid_setup_ui_phase", "$.state.phase", "이 설정 phase에는 setup UI를 게시할 수 없습니다."),
            }
        end
        local loadOk, setupUi = pcall(loadLores, triggerId, loreName)
        if not loadOk then
            return nil, {
                makeError("lore_load_failed", lorePath, loreName .. "을 읽지 못했습니다: " .. tostring(setupUi)),
            }
        end
        if type(setupUi) ~= "string" or setupUi == "" then
            return nil, {
                makeError("missing_lore", lorePath, loreName .. " 로어북 내용이 없습니다."),
            }
        end
        return setupUi, nil
    end

    local function loadRunUi()
        if type(loadLores) ~= "function" then
            return nil, {
                makeError("lore_loader_unavailable", "$.host.loadLores", "UI 로어북을 읽을 loadLores 함수를 찾을 수 없습니다."),
            }
        end
        local loadOk, runUi = pcall(loadLores, triggerId, "postBattle.html")
        if not loadOk then
            return nil, {
                makeError("lore_load_failed", "$.lore.postBattle", "postBattle.html을 읽지 못했습니다: " .. tostring(runUi)),
            }
        end
        if type(runUi) ~= "string" or runUi == "" then
            return nil, {
                makeError("missing_lore", "$.lore.postBattle", "postBattle.html 로어북 내용이 없습니다."),
            }
        end
        return runUi, nil
    end

    local function permitCanonicalOperation(purpose, viewName)
        if purpose == "gameSetupViewCanonicalV1" then
            return true
        end
        if purpose == "runProgressionViewCanonicalV1" then
            return true
        end
        if purpose == "battleControllerCanonicalSetupV1"
            or purpose == "battleControllerCanonicalRunV1" then
            return true
        end
        return purpose == "dataBridgeCanonicalV1"
            and (viewName == VIEW_NAME or viewName == RUN_VIEW_NAME)
    end

    local function buildTarget(state, staticData)
        local stateCopy, stateCopyError = cloneJson(state, "$.target.state")
        if stateCopyError then return nil, { stateCopyError } end

        -- stateCopy는 이 controller transaction에서 gameSetup.start/choose/validate가
        -- 반환한 canonical state이다. 버튼 문자열로 위조할 수 없는
        -- 함수 capability를 넘겨 View의 전체 authority replay만 중복 제거한다.
        local viewReport, viewErrors = callModule(
            "gameSetupView",
            "_buildCanonical",
            stateCopy,
            staticData,
            permitCanonicalOperation
        )
        if viewErrors then return nil, viewErrors end
        if type(viewReport.view) ~= "table" or getmetatable(viewReport.view) ~= nil then
            return nil, {
                makeError("missing_setup_view", "$.runtime.gameSetupView.view", "gameSetupView 생성 결과에 View가 없습니다."),
            }
        end
        local viewCopy, viewCopyError = cloneJson(viewReport.view, "$.target.view")
        if viewCopyError then return nil, { viewCopyError } end

        return {
            state = stateCopy,
            view = viewCopy,
        }, nil
    end

    local function buildRunTarget(runState, setupState, staticData)
        local runCopy, runCopyError = cloneJson(runState, "$.target.runState")
        if runCopyError then return nil, { runCopyError } end
        local setupCopy, setupCopyError = cloneJson(setupState, "$.target.setupState")
        if setupCopyError then return nil, { setupCopyError } end

        local viewReport, viewErrors = callModule(
            "runProgressionView",
            "_buildCanonical",
            runCopy,
            setupCopy,
            staticData,
            permitCanonicalOperation
        )
        if viewErrors then return nil, viewErrors end
        if type(viewReport.view) ~= "table" or getmetatable(viewReport.view) ~= nil then
            return nil, {
                makeError(
                    "missing_run_progression_view",
                    "$.runtime.runProgressionView.view",
                    "runProgressionView 생성 결과에 View가 없습니다."
                ),
            }
        end
        local viewCopy, viewCopyError = cloneJson(viewReport.view, "$.target.runView")
        if viewCopyError then return nil, { viewCopyError } end

        return {
            state = runCopy,
            setupState = setupCopy,
            view = viewCopy,
        }, nil
    end

    local function preflightHost(writeAuthority)
        local required = {
            { name = "writeChatVar", value = type(HostCompat) == "table" and HostCompat.writeChatVar or nil },
            { name = "getChatVar", value = getChatVar },
        }
        if writeAuthority then
            required[#required + 1] = { name = "writeState", value = type(HostCompat) == "table" and HostCompat.writeState or nil }
            required[#required + 1] = { name = "readState", value = type(HostCompat) == "table" and HostCompat.readState or nil }
        end
        local errors = {}
        for _, entry in ipairs(required) do
            if type(entry.value) ~= "function" then
                errors[#errors + 1] = makeError(
                    "host_function_unavailable",
                    "$.host." .. entry.name,
                    entry.name .. " 호스트 함수를 찾을 수 없습니다."
                )
            end
        end
        if #errors > 0 then return errors end
        return nil
    end

    local function writeChatVarStored(name, value, path)
        local writeOk, writeError = pcall(HostCompat.writeChatVar, triggerId, name, value)
        if not writeOk then
            return {
                makeError("chat_var_write_failed", path, "채팅 변수 쓰기에 실패했습니다: " .. tostring(writeError)),
            }
        end
        return nil
    end

    local function ensureUiShell()
        local revisionOk, currentRevision = pcall(getChatVar, triggerId, UI_SHELL_REVISION_NAME)
        if not revisionOk then
            return {
                makeError("chat_var_verify_failed", "$.chatVar.uiShellRevision", "UI shell revision을 읽지 못했습니다: " .. tostring(currentRevision)),
            }
        end
        local shellOk, currentShell = pcall(getChatVar, triggerId, UI_SHELL_NAME)
        if not shellOk then
            return {
                makeError("chat_var_verify_failed", "$.chatVar.uiShell", "UI shell을 읽지 못했습니다: " .. tostring(currentShell)),
            }
        end
        if currentRevision == UI_SHELL_REVISION
            and type(currentShell) == "string"
            and currentShell ~= "" then
            return nil
        end

        local loadOk, sideBar = pcall(loadLores, triggerId, "sideBar.html")
        if not loadOk then
            return {
                makeError("lore_load_failed", "$.lore.sideBar", "sideBar.html을 읽지 못했습니다: " .. tostring(sideBar)),
            }
        end
        if type(sideBar) ~= "string" or sideBar == "" then
            return {
                makeError("missing_lore", "$.lore.sideBar", "sideBar.html 로어북 내용이 없습니다."),
            }
        end
        local shellErrors = writeChatVarStored(UI_SHELL_NAME, sideBar, "$.chatVar.uiShell")
        if shellErrors then return shellErrors end
        return writeChatVarStored(
            UI_SHELL_REVISION_NAME,
            UI_SHELL_REVISION,
            "$.chatVar.uiShellRevision"
        )
    end

    local function verifyExpectedAuthority(expectedAuthority, expectMissing)
        local beforeOk, before = pcall(HostCompat.readState, triggerId, AUTHORITY_KEY)
        if not beforeOk then
            return {
                makeError(
                    "state_verify_read_failed",
                    "$.state.authority",
                    "권위 상태 쓰기 직전 현재 값을 읽지 못했습니다: " .. tostring(before)
                ),
            }
        end
        if expectMissing == true then
            if before ~= nil then
                return {
                    makeError(
                        "authority_concurrent_change",
                        "$.state.authority",
                        "새 설정을 저장하기 전에 다른 요청이 권위 상태를 만들었습니다."
                    ),
                }
            end
        elseif type(expectedAuthority) ~= "table" or not deepEqual(before, expectedAuthority) then
            return {
                makeError(
                    "authority_concurrent_change",
                    "$.state.authority",
                    "설정 전이를 저장하기 전에 권위 상태가 다른 요청에 의해 변경되었습니다."
                ),
            }
        end
        return nil
    end

    local function writeAuthorityVerified(state, expectedAuthority, expectMissing)
        local concurrentErrors = verifyExpectedAuthority(expectedAuthority, expectMissing)
        if concurrentErrors then return concurrentErrors end

        local storedCopy, copyError = cloneJson(state, "$.state.authority")
        if copyError then return { copyError } end
        local writeOk, writeError = pcall(HostCompat.writeState, triggerId, AUTHORITY_KEY, storedCopy)
        if not writeOk then
            return {
                makeError("state_write_failed", "$.state.authority", "게임 설정 상태 저장에 실패했습니다: " .. tostring(writeError)),
            }
        end
        local readOk, stored = pcall(HostCompat.readState, triggerId, AUTHORITY_KEY)
        if not readOk then
            return {
                makeError("state_verify_read_failed", "$.state.authority", "쓰기 뒤 게임 설정 상태를 읽지 못했습니다: " .. tostring(stored)),
            }
        end
        if not deepEqual(storedCopy, stored) then
            return {
                makeError("state_write_not_persisted", "$.state.authority", "쓰기 뒤 읽은 상태가 저장하려던 상태와 다릅니다."),
            }
        end
        -- 동일 transaction에서 gameSetup이 만든 canonical snapshot과
        -- host readback이 exact-equal이므로 또 전체 replay할 필요는 없다.
        -- 다음 이벤트에서 저장소를 다시 읽을 때는 다시 검증한다.
        return nil
    end

    local function verifyExpectedRunAuthority(expectedAuthority, expectMissing)
        local beforeOk, before = pcall(HostCompat.readState, triggerId, RUN_AUTHORITY_KEY)
        if not beforeOk then
            return {
                makeError(
                    "state_verify_read_failed",
                    "$.state.runAuthority",
                    "진행 상태 쓰기 직전 현재 값을 읽지 못했습니다: " .. tostring(before)
                ),
            }
        end
        if expectMissing == true then
            if before ~= nil then
                return {
                    makeError(
                        "run_authority_concurrent_change",
                        "$.state.runAuthority",
                        "첫 전투 정산을 저장하기 전에 다른 요청이 진행 상태를 만들었습니다."
                    ),
                }
            end
        elseif type(expectedAuthority) ~= "table" or not deepEqual(before, expectedAuthority) then
            return {
                makeError(
                    "run_authority_concurrent_change",
                    "$.state.runAuthority",
                    "진행 전이를 저장하기 전에 상태가 다른 요청에 의해 변경되었습니다."
                ),
            }
        end
        return nil
    end

    local function writeRunAuthorityVerified(state, expectedAuthority, expectMissing)
        local concurrentErrors = verifyExpectedRunAuthority(expectedAuthority, expectMissing)
        if concurrentErrors then return concurrentErrors end

        local storedCopy, copyError = cloneJson(state, "$.state.runAuthority")
        if copyError then return { copyError } end
        local writeOk, writeError = pcall(HostCompat.writeState, triggerId, RUN_AUTHORITY_KEY, storedCopy)
        if not writeOk then
            return {
                makeError("state_write_failed", "$.state.runAuthority", "진행 상태 저장에 실패했습니다: " .. tostring(writeError)),
            }
        end
        local readOk, stored = pcall(HostCompat.readState, triggerId, RUN_AUTHORITY_KEY)
        if not readOk then
            return {
                makeError("state_verify_read_failed", "$.state.runAuthority", "쓰기 뒤 진행 상태를 읽지 못했습니다: " .. tostring(stored)),
            }
        end
        if not deepEqual(storedCopy, stored) then
            return {
                makeError("state_write_not_persisted", "$.state.runAuthority", "쓰기 뒤 읽은 진행 상태가 저장하려던 상태와 다릅니다."),
            }
        end
        return nil
    end

    local function beginPublish(writeAuthority, expectedAuthority, expectMissing)
        local hostErrors = preflightHost(writeAuthority)
        if hostErrors then return failure(hostErrors) end

        if writeAuthority then
            local concurrentErrors = verifyExpectedAuthority(expectedAuthority, expectMissing)
            if concurrentErrors then return failure(concurrentErrors) end
        end

        local updatingErrors = writeChatVarStored(READY_NAME, "updating", "$.chatVar.gameSetupReady")
        if updatingErrors then return failure(updatingErrors) end

        return nil
    end

    local function beginRunPublish(writeAuthority, expectedAuthority, expectMissing)
        local hostErrors = preflightHost(writeAuthority)
        if hostErrors then return failure(hostErrors) end

        if writeAuthority then
            local concurrentErrors = verifyExpectedRunAuthority(expectedAuthority, expectMissing)
            if concurrentErrors then return failure(concurrentErrors) end
        end

        local updatingErrors = writeChatVarStored(READY_NAME, "updating", "$.chatVar.gameSetupReady")
        if updatingErrors then return failure(updatingErrors) end

        return nil
    end

    local function publishState(
        state,
        writeAuthority,
        actionName,
        applied,
        stale,
        staticData,
        expectedAuthority,
        expectMissing
    )

        if writeAuthority then
            local authorityErrors = writeAuthorityVerified(
                state,
                expectedAuthority,
                expectMissing
            )
            if authorityErrors then return failure(authorityErrors) end
        end

        local target, targetErrors = buildTarget(state, staticData)
        if targetErrors then return failure(targetErrors) end

        local published, publishErrors = callModule(
            "dataBridge",
            "_publishCanonical",
            VIEW_NAME,
            target.view,
            permitCanonicalOperation
        )
        if publishErrors then return failure(publishErrors) end
        if type(published.encoded) ~= "string" or published.encoded == "" then
            return failure({
                makeError("missing_published_view", "$.runtime.dataBridge.encoded", "게시 결과에 gameSetupView 문자열이 없습니다."),
            })
        end
        local shellErrors = ensureUiShell()
        if shellErrors then return failure(shellErrors) end

        -- getLoreBooks는 로어 내용을 반환하기 전에 CBS를 평가하므로
        -- gameSetupView를 먼저 쓴 뒤 setup HTML을 로드한다.
        local ui, loadUiErrors = loadSetupUi(state.phase)
        if loadUiErrors then return failure(loadUiErrors) end
        local uiErrors = writeChatVarStored(UI_NAME, ui, "$.chatVar.ui")
        if uiErrors then return failure(uiErrors) end
        local readyErrors = writeChatVarStored(READY_NAME, "ready", "$.chatVar.gameSetupReady")
        if readyErrors then return failure(readyErrors) end

        -- start/choose는 risu-btn 호출 전용이다. RisuAI가 button trigger
        -- 완료 직후 클릭된 message pointer를 한 번 remount하므로 여기서
        -- 또 reload하면 같은 HTML/CBS를 두 번 파싱하게 된다.

        local returnState, stateError = cloneJson(target.state, "$.result.state")
        if stateError then return failure({ stateError }) end
        local returnView, viewError = cloneJson(target.view, "$.result.view")
        if viewError then return failure({ viewError }) end
        return success({
            action = actionName,
            applied = applied,
            stale = stale,
            state = returnState,
            view = returnView,
        })
    end

    local function publishRunState(
        runState,
        setupState,
        writeAuthority,
        actionName,
        applied,
        stale,
        staticData,
        expectedAuthority,
        expectMissing
    )
        local beginErrors = beginRunPublish(
            writeAuthority,
            expectedAuthority,
            expectMissing
        )
        if beginErrors then return beginErrors end

        if writeAuthority then
            local authorityErrors = writeRunAuthorityVerified(
                runState,
                expectedAuthority,
                expectMissing
            )
            if authorityErrors then return failure(authorityErrors) end
        end

        local target, targetErrors = buildRunTarget(runState, setupState, staticData)
        if targetErrors then return failure(targetErrors) end

        local published, publishErrors = callModule(
            "dataBridge",
            "_publishCanonical",
            RUN_VIEW_NAME,
            target.view,
            permitCanonicalOperation
        )
        if publishErrors then return failure(publishErrors) end
        if type(published.encoded) ~= "string" or published.encoded == "" then
            return failure({
                makeError(
                    "missing_published_view",
                    "$.runtime.dataBridge.encoded",
                    "게시 결과에 runProgressionView 문자열이 없습니다."
                ),
            })
        end
        local shellErrors = ensureUiShell()
        if shellErrors then return failure(shellErrors) end
        local ui, loadUiErrors = loadRunUi()
        if loadUiErrors then return failure(loadUiErrors) end
        local uiErrors = writeChatVarStored(UI_NAME, ui, "$.chatVar.ui")
        if uiErrors then return failure(uiErrors) end
        local readyErrors = writeChatVarStored(READY_NAME, "ready", "$.chatVar.gameSetupReady")
        if readyErrors then return failure(readyErrors) end

        local returnState, stateError = cloneJson(target.state, "$.result.state")
        if stateError then return failure({ stateError }) end
        local returnView, viewError = cloneJson(target.view, "$.result.view")
        if viewError then return failure({ viewError }) end
        return success({
            action = actionName,
            applied = applied,
            stale = stale,
            state = returnState,
            view = returnView,
        })
    end

    local function validateTransitionResult(report, previousState, moduleAction)
        if type(report) ~= "table"
            or type(report.state) ~= "table"
            or type(report.applied) ~= "boolean"
            or type(report.stale) ~= "boolean" then
            return nil, {
                makeError(
                    "invalid_transition_result",
                    "$.runtime.gameSetup." .. tostring(moduleAction),
                    "설정 전이 결과에 state/applied/stale가 올바르게 포함되지 않았습니다."
                ),
            }
        end
        if report.stale == true and report.applied ~= false then
            return nil, {
                makeError(
                    "invalid_stale_result",
                    "$.runtime.gameSetup." .. tostring(moduleAction),
                    "stale 설정 전이는 적용 상태일 수 없습니다."
                ),
            }
        end
        if report.stale == true and not deepEqual(report.state, previousState) then
            return nil, {
                makeError(
                    "stale_state_changed",
                    "$.runtime.gameSetup." .. tostring(moduleAction) .. ".state",
                    "stale 설정 전이가 권위 상태를 변경했습니다."
                ),
            }
        end
        return report, nil
    end

    local function validateRunTransitionResult(report, previousState, moduleAction)
        if type(report) ~= "table"
            or type(report.state) ~= "table"
            or type(report.applied) ~= "boolean"
            or type(report.stale) ~= "boolean" then
            return nil, {
                makeError(
                    "invalid_transition_result",
                    "$.runtime.runProgression." .. tostring(moduleAction),
                    "진행 전이 결과에 state/applied/stale가 올바르게 포함되지 않았습니다."
                ),
            }
        end
        if report.stale == true and report.applied ~= false then
            return nil, {
                makeError(
                    "invalid_stale_result",
                    "$.runtime.runProgression." .. tostring(moduleAction),
                    "stale 진행 전이는 적용 상태일 수 없습니다."
                ),
            }
        end
        if report.stale == true
            and (type(previousState) ~= "table" or not deepEqual(report.state, previousState)) then
            return nil, {
                makeError(
                    "stale_state_changed",
                    "$.runtime.runProgression." .. tostring(moduleAction) .. ".state",
                    "stale 진행 전이가 권위 상태를 변경했습니다."
                ),
            }
        end
        return report, nil
    end

    local function advanceDeckComplete(state, staticData)
        if state.phase ~= "deckComplete" then
            return state, false, nil
        end
        local advanced, advanceErrors = callModule(
            "gameSetup",
            "beginCharacterSelect",
            state,
            staticData
        )
        if advanceErrors then return nil, false, advanceErrors end
        local checked, checkedErrors = validateTransitionResult(
            advanced,
            state,
            "beginCharacterSelect"
        )
        if checkedErrors then return nil, false, checkedErrors end
        if checked.applied ~= true
            or checked.stale ~= false
            or checked.state.phase ~= "characterSelect" then
            return nil, false, {
                makeError(
                    "invalid_character_select_transition",
                    "$.runtime.gameSetup.beginCharacterSelect",
                    "deckComplete는 적용된 characterSelect 상태로 정확히 한 번 전환되어야 합니다."
                ),
            }
        end
        return checked.state, true, nil
    end

    local function handoffBattle(
        state,
        writeAuthority,
        actionName,
        applied,
        stale,
        staticData,
        expectedAuthority,
        expectMissing
    )
        local target, targetErrors = buildTarget(state, staticData)
        if targetErrors then return failure(targetErrors) end
        if target.state.phase ~= "battleReady" then
            return failure({
                makeError("setup_not_battle_ready", "$.state.phase", "battleReady 설정만 전투로 인계할 수 있습니다."),
            })
        end

        local beginErrors = beginPublish(
            writeAuthority,
            expectedAuthority,
            expectMissing
        )
        if beginErrors then return beginErrors end
        if writeAuthority then
            local authorityErrors = writeAuthorityVerified(
                target.state,
                expectedAuthority,
                expectMissing
            )
            if authorityErrors then return failure(authorityErrors) end
        end

        -- 저장된 battleReady 복구에서 UI chatVar만 사라졌을 수도 있으므로
        -- 전투 body를 게시하기 전에 shell을 항상 보장한다.
        local shellErrors = ensureUiShell()
        if shellErrors then return failure(shellErrors) end

        local battle, battleErrors = callModule(
            "battleController",
            "_startFromCanonicalSetup",
            target.state,
            permitCanonicalOperation
        )
        if battleErrors then return failure(battleErrors) end
        if type(battle.applied) ~= "boolean"
            or type(battle.reused) ~= "boolean"
            or type(battle.recovered) ~= "boolean"
            or battle.applied == battle.reused
            or battle.battleId ~= target.state.battleSpec.battleId
            or battle.setupId ~= target.state.setupId
            or not isSafeInteger(battle.turnNumber, 1)
            or type(battle.view) ~= "table" then
            return failure({
                makeError(
                    "invalid_battle_handoff_result",
                    "$.runtime.battleController.startFromSetup",
                    "전투 인계 결과가 setup identity와 필수 결과 계약을 만족하지 않습니다."
                ),
            })
        end

        local readyErrors = writeChatVarStored(READY_NAME, "ready", "$.chatVar.gameSetupReady")
        if readyErrors then return failure(readyErrors) end

        local returnState, stateError = cloneJson(target.state, "$.result.state")
        if stateError then return failure({ stateError }) end
        local returnView, viewError = cloneJson(target.view, "$.result.view")
        if viewError then return failure({ viewError }) end
        local returnBattle, battleError = cloneJson(battle, "$.result.battle")
        if battleError then return failure({ battleError }) end
        local returnBattleView, battleViewError = cloneJson(battle.view, "$.result.battleView")
        if battleViewError then return failure({ battleViewError }) end
        return success({
            action = actionName,
            applied = applied,
            stale = stale,
            state = returnState,
            view = returnView,
            battle = returnBattle,
            battleView = returnBattleView,
        })
    end

    local function handoffRunBattle(
        runState,
        setupState,
        writeAuthority,
        actionName,
        applied,
        stale,
        staticData,
        expectedAuthority,
        expectMissing
    )
        local target, targetErrors = buildRunTarget(runState, setupState, staticData)
        if targetErrors then return failure(targetErrors) end
        if target.state.phase ~= "battleReady" then
            return failure({
                makeError(
                    "run_not_battle_ready",
                    "$.state.runAuthority.phase",
                    "다음 상대 선택까지 끝난 battleReady 진행 상태만 전투로 인계할 수 있습니다."
                ),
            })
        end

        local beginErrors = beginRunPublish(
            writeAuthority,
            expectedAuthority,
            expectMissing
        )
        if beginErrors then return beginErrors end
        if writeAuthority then
            local authorityErrors = writeRunAuthorityVerified(
                target.state,
                expectedAuthority,
                expectMissing
            )
            if authorityErrors then return failure(authorityErrors) end
        end

        local shellErrors = ensureUiShell()
        if shellErrors then return failure(shellErrors) end
        local battle, battleErrors = callModule(
            "battleController",
            "_startFromCanonicalRun",
            target.state,
            target.setupState,
            permitCanonicalOperation
        )
        if battleErrors then return failure(battleErrors) end
        local battleSpec = target.state.battleSpec
        if type(battleSpec) ~= "table"
            or type(battle.applied) ~= "boolean"
            or type(battle.reused) ~= "boolean"
            or type(battle.recovered) ~= "boolean"
            or battle.applied == battle.reused
            or battle.battleId ~= battleSpec.battleId
            or battle.setupId ~= target.setupState.setupId
            or not isSafeInteger(battle.turnNumber, 1)
            or type(battle.view) ~= "table" then
            return failure({
                makeError(
                    "invalid_battle_handoff_result",
                    "$.runtime.battleController.startFromRun",
                    "다음 전투 인계 결과가 진행 상태 identity와 필수 결과 계약을 만족하지 않습니다."
                ),
            })
        end

        local readyErrors = writeChatVarStored(READY_NAME, "ready", "$.chatVar.gameSetupReady")
        if readyErrors then return failure(readyErrors) end

        local returnState, stateError = cloneJson(target.state, "$.result.state")
        if stateError then return failure({ stateError }) end
        local returnView, viewError = cloneJson(target.view, "$.result.view")
        if viewError then return failure({ viewError }) end
        local returnBattle, battleError = cloneJson(battle, "$.result.battle")
        if battleError then return failure({ battleError }) end
        local returnBattleView, battleViewError = cloneJson(battle.view, "$.result.battleView")
        if battleViewError then return failure({ battleViewError }) end
        return success({
            action = actionName,
            applied = applied,
            stale = stale,
            state = returnState,
            view = returnView,
            battle = returnBattle,
            battleView = returnBattleView,
        })
    end

    local function settleProgression(setupState, currentRun, summary, staticData, actionName)
        local settled, settleErrors = callModule(
            "runProgression",
            "settle",
            currentRun,
            setupState,
            summary,
            staticData
        )
        if settleErrors then return failure(settleErrors) end
        local checked, checkedErrors = validateRunTransitionResult(
            settled,
            currentRun,
            "settle"
        )
        if checkedErrors then return failure(checkedErrors) end
        return publishRunState(
            checked.state,
            setupState,
            checked.applied == true,
            actionName,
            checked.applied,
            checked.stale,
            staticData,
            currentRun,
            currentRun == nil
        )
    end

    local function inspectTerminalBattle()
        local inspected, inspectErrors = callModule(
            "battleController",
            "getTerminalSummary"
        )
        if inspectErrors then return nil, inspectErrors end
        if type(inspected.terminal) ~= "boolean" then
            return nil, {
                makeError(
                    "invalid_terminal_inspection",
                    "$.runtime.battleController.getTerminalSummary",
                    "전투 종료 점검 결과에 terminal 불리언이 없습니다."
                ),
            }
        end
        if type(inspected.settlementAvailable) ~= "boolean" then
            return nil, {
                makeError(
                    "invalid_terminal_inspection",
                    "$.runtime.battleController.getTerminalSummary.settlementAvailable",
                    "전투 종료 점검 결과에 settlementAvailable 불리언이 없습니다."
                ),
            }
        end
        if inspected.terminal == true
            and inspected.settlementAvailable == true
            and (type(inspected.summary) ~= "table" or getmetatable(inspected.summary) ~= nil) then
            return nil, {
                makeError(
                    "missing_terminal_summary",
                    "$.runtime.battleController.getTerminalSummary.summary",
                    "종료된 전투 점검 결과에 정산 요약이 없습니다."
                ),
            }
        end
        if inspected.terminal == true
            and (type(inspected.battleId) ~= "string"
                or type(inspected.status) ~= "string") then
            return nil, {
                makeError(
                    "invalid_terminal_identity",
                    "$.runtime.battleController.getTerminalSummary",
                    "종료된 전투 점검 결과에 battleId와 status가 없습니다."
                ),
            }
        end
        return inspected, nil
    end

    local function validateInvocation()
        if action == "completeBattle" then
            if argumentCount ~= 1 then
                return nil, {
                    makeError(
                        "invalid_argument_count",
                        "$.arguments",
                        "completeBattle 작업에는 종료 요약 하나가 필요합니다."
                    ),
                }
            end
            if type(arguments[1]) ~= "table" or getmetatable(arguments[1]) ~= nil then
                return nil, {
                    makeError(
                        "invalid_battle_summary",
                        "$.arguments[1]",
                        "종료 요약은 메타테이블 없는 객체여야 합니다."
                    ),
                }
            end
            local summaryCopy, summaryError = cloneJson(arguments[1], "$.arguments[1]")
            if summaryError then return nil, { summaryError } end
            return { summary = summaryCopy }, nil
        end
        if action == "start" then
            if argumentCount ~= 0 then
                return nil, {
                    makeError("unexpected_arguments", "$.arguments", "start 작업은 인자를 받지 않습니다."),
                }
            end
            return {}, nil
        end
        if action == "choose" then
            if argumentCount ~= 2 then
                return nil, {
                    makeError("invalid_argument_count", "$.arguments", "choose 작업에는 cardId와 interactionToken이 필요합니다."),
                }
            end
            local cardId = arguments[1]
            local interactionToken = arguments[2]
            if type(cardId) ~= "string" or type(interactionToken) ~= "string" then
                return nil, {
                    makeError("invalid_choose_arguments", "$.arguments", "cardId와 interactionToken은 문자열이어야 합니다."),
                }
            end
            return { cardId = cardId, interactionToken = interactionToken }, nil
        end
        if action == "chooseCharacter" then
            if argumentCount ~= 2 then
                return nil, {
                    makeError(
                        "invalid_argument_count",
                        "$.arguments",
                        "chooseCharacter 작업에는 characterId와 interactionToken이 필요합니다."
                    ),
                }
            end
            local characterId = arguments[1]
            local interactionToken = arguments[2]
            if type(characterId) ~= "string" or type(interactionToken) ~= "string" then
                return nil, {
                    makeError(
                        "invalid_choose_character_arguments",
                        "$.arguments",
                        "characterId와 interactionToken은 문자열이어야 합니다."
                    ),
                }
            end
            return { characterId = characterId, interactionToken = interactionToken }, nil
        end
        return nil, {
            makeError("unknown_action", "$.action", "지원하지 않는 게임 설정 컨트롤러 작업입니다: " .. tostring(action)),
        }
    end

    local function execute()
        local command, invocationErrors = validateInvocation()
        if invocationErrors then return failure(invocationErrors) end

        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end

        if action == "completeBattle" then
            local setupState, setupErrors = readAuthority(true)
            if setupErrors then return failure(setupErrors) end
            local currentRun, runErrors = readRunAuthority(false)
            if runErrors then return failure(runErrors) end
            return settleProgression(
                setupState,
                currentRun,
                command.summary,
                staticData,
                "completeBattle"
            )
        end

        if action == "start" then
            local currentRun, runReadErrors = readRunAuthority(false)
            if runReadErrors then return failure(runReadErrors) end
            if currentRun ~= nil then
                local setupState, setupReadErrors = readAuthority(true)
                if setupReadErrors then return failure(setupReadErrors) end
                local validatedRun, validationErrors = callModule(
                    "runProgression",
                    "validate",
                    currentRun,
                    setupState,
                    staticData
                )
                if validationErrors then return failure(validationErrors) end
                if type(validatedRun.state) ~= "table"
                    or not deepEqual(currentRun, validatedRun.state) then
                    return failure({
                        makeError(
                            "run_authority_validation_mismatch",
                            "$.state.runAuthority",
                            "저장된 진행 상태의 정규 검증 결과가 원본과 일치하지 않습니다."
                        ),
                    })
                end
                currentRun = validatedRun.state
                if currentRun.phase == "battleReady" then
                    local inspected, inspectErrors = inspectTerminalBattle()
                    if inspectErrors then return failure(inspectErrors) end
                    if inspected.terminal == true
                        and type(currentRun.battleSpec) == "table"
                        and inspected.battleId == currentRun.battleSpec.battleId then
                        if inspected.settlementAvailable ~= true then
                            return failure({
                                makeError(
                                    "missing_terminal_settlement_receipt",
                                    "$.state.battleRuntime",
                                    "현재 종료 전투를 정산할 마지막 확정 턴 영수증이 없습니다."
                                ),
                            })
                        end
                        return settleProgression(
                            setupState,
                            currentRun,
                            inspected.summary,
                            staticData,
                            "start"
                        )
                    end
                    return handoffRunBattle(
                        currentRun,
                        setupState,
                        false,
                        "start",
                        false,
                        false,
                        staticData,
                        currentRun,
                        false
                    )
                end
                return publishRunState(
                    currentRun,
                    setupState,
                    false,
                    "start",
                    false,
                    false,
                    staticData,
                    currentRun,
                    false
                )
            end

            local stored, readErrors = readAuthority(false)
            if readErrors then return failure(readErrors) end
            local expectedAuthority = stored
            local expectMissing = stored == nil
            local state
            local writeAuthority = false
            local applied = false
            local publishBegun = false
            if stored ~= nil then
                local validated, validationErrors = callModule("gameSetup", "validate", stored, staticData)
                if validationErrors then return failure(validationErrors) end
                if type(validated.state) ~= "table" or not deepEqual(stored, validated.state) then
                    return failure({
                        makeError("authority_validation_mismatch", "$.state.authority", "저장된 설정 상태의 정규 검증 결과가 원본과 일치하지 않습니다."),
                    })
                end
                state = validated.state
            else
                local beginErrors = beginPublish(true, expectedAuthority, expectMissing)
                if beginErrors then return beginErrors end
                publishBegun = true

                local seed, seedErrors = generateSetupSeed()
                if seedErrors then return failure(seedErrors) end
                local setupId = "setup-" .. string.format("%.0f", seed)
                local started, startErrors = callModule(
                    "gameSetup",
                    "start",
                    { setupId = setupId, seed = seed },
                    staticData
                )
                if startErrors then return failure(startErrors) end
                if type(started.state) ~= "table" then
                    return failure({
                        makeError("missing_started_state", "$.runtime.gameSetup.state", "새 게임 설정 상태가 반환되지 않았습니다."),
                    })
                end
                state = started.state
                writeAuthority = true
                applied = true
            end

            local advancedState, advanced, advanceErrors = advanceDeckComplete(state, staticData)
            if advanceErrors then return failure(advanceErrors) end
            state = advancedState
            if advanced then
                writeAuthority = true
                applied = true
            end

            if state.phase == "battleReady" then
                local inspected, inspectErrors = inspectTerminalBattle()
                if inspectErrors then return failure(inspectErrors) end
                if inspected.terminal == true
                    and type(state.battleSpec) == "table"
                    and inspected.battleId == state.battleSpec.battleId then
                    if inspected.settlementAvailable ~= true then
                        return failure({
                            makeError(
                                "missing_terminal_settlement_receipt",
                                "$.state.battleRuntime",
                                "현재 종료 전투를 정산할 마지막 확정 턴 영수증이 없습니다."
                            ),
                        })
                    end
                    if writeAuthority then
                        local authorityErrors = writeAuthorityVerified(
                            state,
                            expectedAuthority,
                            expectMissing
                        )
                        if authorityErrors then return failure(authorityErrors) end
                        writeAuthority = false
                    end
                    return settleProgression(
                        state,
                        nil,
                        inspected.summary,
                        staticData,
                        "start"
                    )
                end
                return handoffBattle(
                    state,
                    writeAuthority,
                    "start",
                    applied,
                    false,
                    staticData,
                    expectedAuthority,
                    expectMissing
                )
            end
            if not publishBegun then
                local beginErrors = beginPublish(
                    writeAuthority,
                    expectedAuthority,
                    expectMissing
                )
                if beginErrors then return beginErrors end
            end
            return publishState(
                state,
                writeAuthority,
                "start",
                applied,
                false,
                staticData,
                expectedAuthority,
                expectMissing
            )
        end

        local stored, readErrors = readAuthority(true)
        if readErrors then return failure(readErrors) end
        local currentRun, runReadErrors = readRunAuthority(false)
        if runReadErrors then return failure(runReadErrors) end
        if currentRun ~= nil then
            local runAction = action == "chooseCharacter"
                and "chooseCharacter"
                or "claimReward"
            local transitioned, transitionErrors = callModule(
                "runProgression",
                runAction,
                currentRun,
                stored,
                command,
                staticData
            )
            if transitionErrors then return failure(transitionErrors) end
            local checked, checkedErrors = validateRunTransitionResult(
                transitioned,
                currentRun,
                runAction
            )
            if checkedErrors then return failure(checkedErrors) end

            local runState = checked.state
            local writeRun = checked.applied == true
            if runState.phase == "battleReady" then
                return handoffRunBattle(
                    runState,
                    stored,
                    writeRun,
                    action,
                    checked.applied,
                    checked.stale,
                    staticData,
                    currentRun,
                    false
                )
            end
            return publishRunState(
                runState,
                stored,
                writeRun,
                action,
                checked.applied,
                checked.stale,
                staticData,
                currentRun,
                false
            )
        end
        local moduleAction = action == "chooseCharacter" and "chooseCharacter" or "choose"
        -- 저장소에서 읽은 authority를 gameSetup이 처음부터 재생 검증한 뒤
        -- 현재 카드 또는 캐릭터 interaction token만 적용한다.
        local transitioned, transitionErrors = callModule(
            "gameSetup",
            moduleAction,
            stored,
            command,
            staticData
        )
        if transitionErrors then return failure(transitionErrors) end
        local checked, checkedErrors = validateTransitionResult(
            transitioned,
            stored,
            moduleAction
        )
        if checkedErrors then return failure(checkedErrors) end

        local state = checked.state
        local applied = checked.applied
        local stale = checked.stale
        local advancedState, advanced, advanceErrors = advanceDeckComplete(state, staticData)
        if advanceErrors then return failure(advanceErrors) end
        if advanced then
            state = advancedState
            applied = true
            stale = false
        end

        local writeAuthority = applied == true
        if state.phase == "battleReady" then
            return handoffBattle(
                state,
                writeAuthority,
                action,
                applied,
                stale,
                staticData,
                stored,
                false
            )
        end
        local beginErrors = beginPublish(writeAuthority, stored, false)
        if beginErrors then return beginErrors end
        return publishState(
            state,
            writeAuthority,
            action,
            applied,
            stale,
            staticData,
            stored,
            false
        )
    end

    local callOk, result = pcall(execute)
    if not callOk then
        result = failure({
            makeError("controller_error", "$", "게임 설정 컨트롤러 실행 중 오류가 발생했습니다: " .. tostring(result)),
        })
    elseif type(result) ~= "table" or (result.ok ~= true and result.ok ~= false) then
        result = failure({
            makeError("invalid_controller_result", "$", "게임 설정 컨트롤러가 올바른 결과를 반환하지 않았습니다."),
        })
    end

    if result.ok ~= true then
        local first = type(result.errors) == "table" and result.errors[1] or nil
        local diagnosticErrors = {}
        for index, item in ipairs(type(result.errors) == "table" and result.errors or {}) do
            diagnosticErrors[index] = {
                code = type(item) == "table" and tostring(item.code) or "invalid_error",
                path = type(item) == "table" and tostring(item.path) or "$",
                message = type(item) == "table" and tostring(item.message) or tostring(item),
            }
        end
        emitDiagnostic(1, "request_failed", {
            action = tostring(action),
            errorCount = #diagnosticErrors,
            errors = diagnosticErrors,
        })

        local message = "게임 설정을 처리하지 못했습니다."
        if type(first) == "table" then
            message = message
                .. "\n[" .. tostring(first.code) .. "] "
                .. tostring(first.message)
                .. "\n경로: " .. tostring(first.path)
            if #diagnosticErrors > 1 then
                message = message .. "\n전체 오류 수: " .. tostring(#diagnosticErrors)
            end
        end
        if type(alertError) == "function" then
            pcall(alertError, triggerId, message)
        end
    end
    return result
end)
