(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local MAX_SAFE_INTEGER = 9007199254740991
    local AUTHORITY_KEY = "gameSetupV1.authority"
    local VIEW_NAME = "gameSetupView"
    local READY_NAME = "gameSetupReady"
    local UI_NAME = "🔯🔯🔯"
    local arguments = { ... }
    local argumentCount = select("#", ...)

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
        if type(getState) ~= "function" then
            return nil, {
                makeError("state_read_unavailable", "$.host.getState", "getState 호스트 함수를 찾을 수 없습니다."),
            }
        end
        local ok, value = pcall(getState, triggerId, AUTHORITY_KEY)
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

    local function generateSetupSeed()
        if type(cbs) ~= "function" then
            return nil, {
                makeError("cbs_unavailable", "$.host.cbs", "초기 seed를 만들 CBS 함수를 찾을 수 없습니다."),
            }
        end
        local ok, rendered = pcall(cbs, "{{randint::1::2147483646}}")
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

    local function loadSetupUi()
        if type(loadLores) ~= "function" then
            return nil, {
                makeError("lore_loader_unavailable", "$.host.loadLores", "UI 로어북을 읽을 loadLores 함수를 찾을 수 없습니다."),
            }
        end
        local sideOk, sideBar = pcall(loadLores, triggerId, "sideBar.html")
        if not sideOk then
            return nil, {
                makeError("lore_load_failed", "$.lore.sideBar", "sideBar.html을 읽지 못했습니다: " .. tostring(sideBar)),
            }
        end
        if type(sideBar) ~= "string" or sideBar == "" then
            return nil, {
                makeError("missing_lore", "$.lore.sideBar", "sideBar.html 로어북 내용이 없습니다."),
            }
        end
        local draftOk, cardDraft = pcall(loadLores, triggerId, "cardDraft.html")
        if not draftOk then
            return nil, {
                makeError("lore_load_failed", "$.lore.cardDraft", "cardDraft.html을 읽지 못했습니다: " .. tostring(cardDraft)),
            }
        end
        if type(cardDraft) ~= "string" or cardDraft == "" then
            return nil, {
                makeError("missing_lore", "$.lore.cardDraft", "cardDraft.html 로어북 내용이 없습니다."),
            }
        end
        return sideBar .. cardDraft, nil
    end

    local function buildTarget(state, staticData)
        local stateCopy, stateCopyError = cloneJson(state, "$.target.state")
        if stateCopyError then return nil, { stateCopyError } end

        local viewReport, viewErrors = callModule("gameSetupView", "build", stateCopy, staticData)
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

    local function preflightHost(writeAuthority)
        local required = {
            { name = "setChatVar", value = setChatVar },
            { name = "getChatVar", value = getChatVar },
            { name = "reloadDisplay", value = reloadDisplay },
        }
        if writeAuthority then
            required[#required + 1] = { name = "setState", value = setState }
            required[#required + 1] = { name = "getState", value = getState }
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

    local function writeChatVarVerified(name, value, path)
        local writeOk, writeError = pcall(setChatVar, triggerId, name, value)
        if not writeOk then
            return {
                makeError("chat_var_write_failed", path, "채팅 변수 쓰기에 실패했습니다: " .. tostring(writeError)),
            }
        end
        local readOk, stored = pcall(getChatVar, triggerId, name)
        if not readOk then
            return {
                makeError("chat_var_verify_failed", path, "쓰기 뒤 채팅 변수를 읽지 못했습니다: " .. tostring(stored)),
            }
        end
        if stored ~= value then
            return {
                makeError("chat_var_write_not_persisted", path, "쓰기 뒤 읽은 값이 저장하려던 문자열과 다릅니다."),
            }
        end
        return nil
    end

    local function writeAuthorityVerified(state, staticData)
        local storedCopy, copyError = cloneJson(state, "$.state.authority")
        if copyError then return { copyError } end
        local writeOk, writeError = pcall(setState, triggerId, AUTHORITY_KEY, storedCopy)
        if not writeOk then
            return {
                makeError("state_write_failed", "$.state.authority", "게임 설정 상태 저장에 실패했습니다: " .. tostring(writeError)),
            }
        end
        local readOk, stored = pcall(getState, triggerId, AUTHORITY_KEY)
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
        local validated, validationErrors = callModule("gameSetup", "validate", stored, staticData)
        if validationErrors then return validationErrors end
        if type(validated.state) ~= "table" or not deepEqual(stored, validated.state) then
            return {
                makeError("state_validation_mismatch", "$.state.authority", "저장 상태의 검증 결과가 읽어낸 상태와 일치하지 않습니다."),
            }
        end
        return nil
    end

    local function beginPublish(writeAuthority)
        local hostErrors = preflightHost(writeAuthority)
        if hostErrors then return failure(hostErrors) end

        local updatingErrors = writeChatVarVerified(READY_NAME, "updating", "$.chatVar.gameSetupReady")
        if updatingErrors then return failure(updatingErrors) end

        return nil
    end

    local function publishState(state, writeAuthority, actionName, applied, stale, staticData)

        if writeAuthority then
            local authorityErrors = writeAuthorityVerified(state, staticData)
            if authorityErrors then return failure(authorityErrors) end
        end

        local target, targetErrors = buildTarget(state, staticData)
        if targetErrors then return failure(targetErrors) end

        local published, publishErrors = callModule("dataBridge", "publish", VIEW_NAME, target.view)
        if publishErrors then return failure(publishErrors) end
        if type(published.encoded) ~= "string" or published.encoded == "" then
            return failure({
                makeError("missing_published_view", "$.runtime.dataBridge.encoded", "게시 결과에 gameSetupView 문자열이 없습니다."),
            })
        end
        local viewReadOk, storedView = pcall(getChatVar, triggerId, VIEW_NAME)
        if not viewReadOk then
            return failure({
                makeError("view_verify_read_failed", "$.chatVar.gameSetupView", "게시 뒤 gameSetupView를 읽지 못했습니다: " .. tostring(storedView)),
            })
        end
        if storedView ~= published.encoded then
            return failure({
                makeError("view_write_not_persisted", "$.chatVar.gameSetupView", "게시된 gameSetupView가 인코딩 결과와 다릅니다."),
            })
        end

        -- getLoreBooks는 로어 내용을 반환하기 전에 CBS를 평가한다. 따라서
        -- cardDraft.html은 방금 게시한 gameSetupView를 재읽을 수 있게 View
        -- write-read 검증이 끝난 뒤에만 로드해야 한다.
        local ui, loadUiErrors = loadSetupUi()
        if loadUiErrors then return failure(loadUiErrors) end
        local uiErrors = writeChatVarVerified(UI_NAME, ui, "$.chatVar.ui")
        if uiErrors then return failure(uiErrors) end
        local readyErrors = writeChatVarVerified(READY_NAME, "ready", "$.chatVar.gameSetupReady")
        if readyErrors then return failure(readyErrors) end

        local reloadOk, reloadError = pcall(reloadDisplay, triggerId)
        if not reloadOk then
            return failure({
                makeError("display_reload_failed", "$.host.reloadDisplay", "게임 설정 화면 갱신에 실패했습니다: " .. tostring(reloadError)),
            })
        end

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

    local function validateInvocation()
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
        return nil, {
            makeError("unknown_action", "$.action", "지원하지 않는 게임 설정 컨트롤러 작업입니다: " .. tostring(action)),
        }
    end

    local function execute()
        local command, invocationErrors = validateInvocation()
        if invocationErrors then return failure(invocationErrors) end

        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end

        if action == "start" then
            local stored, readErrors = readAuthority(false)
            if readErrors then return failure(readErrors) end
            local state
            local writeAuthority = false
            local applied = false
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
                local beginErrors = beginPublish(true)
                if beginErrors then return beginErrors end

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

            if not writeAuthority then
                local beginErrors = beginPublish(false)
                if beginErrors then return beginErrors end
            end
            return publishState(state, writeAuthority, "start", applied, false, staticData)
        end

        local stored, readErrors = readAuthority(true)
        if readErrors then return failure(readErrors) end
        local validated, validationErrors = callModule("gameSetup", "validate", stored, staticData)
        if validationErrors then return failure(validationErrors) end
        if type(validated.state) ~= "table" or not deepEqual(stored, validated.state) then
            return failure({
                makeError("authority_validation_mismatch", "$.state.authority", "저장된 설정 상태의 정규 검증 결과가 원본과 일치하지 않습니다."),
            })
        end
        local chosen, chooseErrors = callModule("gameSetup", "choose", validated.state, command, staticData)
        if chooseErrors then return failure(chooseErrors) end
        if type(chosen.state) ~= "table"
            or type(chosen.applied) ~= "boolean"
            or type(chosen.stale) ~= "boolean" then
            return failure({
                makeError("invalid_choose_result", "$.runtime.gameSetup", "카드 선택 결과에 state/applied/stale가 올바르게 포함되지 않았습니다."),
            })
        end
        if chosen.stale == true and chosen.applied ~= false then
            return failure({
                makeError("invalid_stale_result", "$.runtime.gameSetup", "stale 선택 결과는 적용 상태일 수 없습니다."),
            })
        end
        if chosen.stale == true and not deepEqual(chosen.state, validated.state) then
            return failure({
                makeError("stale_state_changed", "$.runtime.gameSetup.state", "stale 선택이 권위 상태를 변경했습니다."),
            })
        end
        local writeAuthority = chosen.applied == true
        local beginErrors = beginPublish(writeAuthority)
        if beginErrors then return beginErrors end
        return publishState(
            chosen.state,
            writeAuthority,
            "choose",
            chosen.applied,
            chosen.stale,
            staticData
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

    if result.ok ~= true and type(alertError) == "function" then
        local first = type(result.errors) == "table" and result.errors[1] or nil
        local message = "게임 설정을 처리하지 못했습니다."
        if type(first) == "table" then
            message = message
                .. "\n[" .. tostring(first.code) .. "] "
                .. tostring(first.message)
        end
        pcall(alertError, triggerId, message)
    end
    return result
end)
