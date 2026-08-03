(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1

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

    local function callModule(moduleName, moduleAction, ...)
        if type(runScript) ~= "function" then
            return nil, failure({
                makeError("runtime_unavailable", "$.runtime", "runScript 실행기를 찾을 수 없습니다."),
            })
        end
        local ok, report = pcall(runScript, triggerId, moduleName, moduleAction, ...)
        if not ok then
            return nil, failure({
                makeError(
                    "module_call_failed",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. " 호출 중 오류가 발생했습니다: " .. tostring(report)
                ),
            })
        end
        if type(report) ~= "table"
            or report.schemaVersion ~= SCHEMA_VERSION
            or type(report.errors) ~= "table"
            or (report.ok ~= true and report.ok ~= false) then
            return nil, failure({
                makeError(
                    "invalid_module_result",
                    "$.runtime." .. moduleName,
                    moduleName .. "." .. moduleAction .. " 결과 envelope가 올바르지 않습니다."
                ),
            })
        end
        return report, nil
    end

    local arguments = { ... }
    local core, coreFailure = callModule(
        "battleControllerCore",
        action,
        table.unpack(arguments)
    )
    if coreFailure then return coreFailure end
    if action ~= "skipAftermath"
        or core.ok ~= true
        or core.generationReady ~= true then
        return core
    end

    local scene, sceneFailure = callModule(
        "aftermathSkipScene",
        "run",
        arguments[1],
        arguments[2]
    )
    if sceneFailure then return sceneFailure end
    return scene
end)