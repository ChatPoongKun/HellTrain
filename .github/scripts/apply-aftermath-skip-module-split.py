from pathlib import Path
import subprocess


ROOT = Path(".")
MAIN = ROOT / "System/main.lua"
CONTROLLER = ROOT / "System/battleController.lua"
CORE = ROOT / "System/battleControllerCore.lua"
SCENE = ROOT / "System/aftermathSkipScene.lua"


def git_show(spec: str) -> str:
    result = subprocess.run(
        ["git", "show", spec],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return result.stdout


controller_source = CONTROLLER.read_text(encoding="utf-8")
required_controller_markers = [
    'local AFTERMATH_SKIP_INPUT = "[목적지 바로가기] 남은 자유행동을 건너뛴다."',
    'skipToDestination = true',
    'local function cancelAftermathSkip',
]
missing = [marker for marker in required_controller_markers if marker not in controller_source]
if missing:
    raise SystemExit("modified battleController markers missing: " + ", ".join(missing))

# main.lua는 현재 기본 브랜치의 원본을 그대로 복원한다.
MAIN.write_text(git_show("origin/main:System/main.lua"), encoding="utf-8")

# 상태 머신과 검증 로직은 core로 보존하고, 공개 모듈 이름에는 얇은 라우터만 둔다.
CORE.write_text(controller_source, encoding="utf-8")

wrapper = r'''(function(triggerId, action, ...)
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
end)'''
CONTROLLER.write_text(wrapper, encoding="utf-8")

scene = r'''(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local UI_ANCHOR_MARKER = "@@HELLTRAIN_UI_ANCHOR_V1@@"
    local SAY_NOTHING = "*says nothing*"

    local function makeError(code, path, message)
        return {
            code = code,
            path = path,
            message = message,
        }
    end

    local function failure(errors, fields)
        local report = {
            ok = false,
            schemaVersion = SCHEMA_VERSION,
            errors = errors,
        }
        for key, value in pairs(fields or {}) do report[key] = value end
        return report
    end

    local function success(fields)
        local report = {
            ok = true,
            schemaVersion = SCHEMA_VERSION,
            errors = {},
        }
        for key, value in pairs(fields or {}) do report[key] = value end
        return report
    end

    local function callCore(coreAction, ...)
        if type(runScript) ~= "function" then
            return nil, {
                makeError("runtime_unavailable", "$.runtime", "runScript 실행기를 찾을 수 없습니다."),
            }
        end
        local ok, report = pcall(
            runScript,
            triggerId,
            "battleControllerCore",
            coreAction,
            ...
        )
        if not ok then
            return nil, {
                makeError(
                    "controller_call_failed",
                    "$.runtime.battleControllerCore",
                    "battleControllerCore." .. coreAction .. " 호출 중 오류가 발생했습니다: " .. tostring(report)
                ),
            }
        end
        if type(report) ~= "table"
            or report.schemaVersion ~= SCHEMA_VERSION
            or type(report.errors) ~= "table"
            or (report.ok ~= true and report.ok ~= false) then
            return nil, {
                makeError(
                    "invalid_controller_result",
                    "$.runtime.battleControllerCore",
                    "battleControllerCore." .. coreAction .. " 결과 envelope가 올바르지 않습니다."
                ),
            }
        end
        if report.ok ~= true then
            return nil, report.errors
        end
        return report, nil
    end

    local function readChat()
        if type(getFullChat) ~= "function" then
            return nil, "getFullChat 호스트 함수를 사용할 수 없습니다."
        end
        local ok, chat = pcall(getFullChat, triggerId)
        if not ok or type(chat) ~= "table" then
            return nil, "대화 기록을 읽지 못했습니다: " .. tostring(chat)
        end
        return chat, nil
    end

    local function buildPrompt()
        local chat, chatError = readChat()
        if chatError then return nil, chatError end
        local history = {}
        for _, message in ipairs(chat) do
            local role = type(message) == "table" and message.role or nil
            local content = type(message) == "table" and message.data or nil
            if type(content) == "string"
                and string.match(content, "%S") ~= nil
                and content ~= UI_ANCHOR_MARKER
                and content ~= SAY_NOTHING
                and (role == "user" or role == "char") then
                history[#history + 1] = {
                    role = role == "char" and "assistant" or "user",
                    content = content,
                }
            end
        end
        if #history == 0 or history[#history].role ~= "user" then
            return nil, "목적지 바로가기 합성 입력을 찾을 수 없습니다."
        end
        local prompt = {}
        local first = math.max(1, #history - 11)
        for index = first, #history do prompt[#prompt + 1] = history[index] end
        return prompt, nil
    end

    local function appendCharacterOutput(content)
        if type(addChat) ~= "function" then
            return "addChat 호스트 함수를 사용할 수 없습니다."
        end
        local before, readError = readChat()
        if readError then return readError end
        local ok, addError = pcall(addChat, triggerId, "char", content)
        if not ok then
            return "도착 장면을 대화에 추가하지 못했습니다: " .. tostring(addError)
        end
        local after, afterError = readChat()
        if afterError then return afterError end
        local appended = after[#after]
        if #after ~= #before + 1
            or type(appended) ~= "table"
            or appended.role ~= "char"
            or appended.data ~= content then
            return "도착 장면이 대화에 정확히 저장되지 않았습니다."
        end
        return nil
    end

    local function refreshAnchor()
        if type(ensureGameUiAnchor) == "function" then
            pcall(ensureGameUiAnchor, triggerId)
        end
    end

    local function alert(message)
        if type(alertError) == "function" then
            pcall(alertError, triggerId, message)
        end
    end

    local function cancelAndRestore(battleId, viewTurnId, detail)
        local _, cancelErrors = callCore(
            "cancelAftermathSkip",
            battleId,
            viewTurnId
        )
        refreshAnchor()
        local cancelDetail = cancelErrors and " 취소 복구에도 실패했습니다." or " 기존 자유행동 화면으로 복구했습니다."
        alert("목적지 바로가기 장면을 생성하지 못했습니다.\n" .. tostring(detail) .. cancelDetail)
        local errors = {
            makeError("aftermath_skip_scene_failed", "$.llm", tostring(detail)),
        }
        if cancelErrors then
            for _, item in ipairs(cancelErrors) do errors[#errors + 1] = item end
        end
        return failure(errors, {
            restored = cancelErrors == nil,
            outputPersisted = false,
        })
    end

    local function run(battleId, viewTurnId)
        if type(LLM) ~= "function" then
            return cancelAndRestore(
                battleId,
                viewTurnId,
                "LLM 함수를 사용할 수 없습니다. Lua 스크립트의 low-level access를 활성화해야 합니다."
            )
        end

        local prompt, promptError = buildPrompt()
        if promptError then
            return cancelAndRestore(battleId, viewTurnId, promptError)
        end
        local injected, injectErrors = callCore("injectRequest", prompt)
        if injectErrors or type(injected.promptArray) ~= "table" then
            return cancelAndRestore(
                battleId,
                viewTurnId,
                "목적지 바로가기 장면 지시를 준비하지 못했습니다."
            )
        end

        local requestOk, response = pcall(
            LLM,
            triggerId,
            injected.promptArray,
            false,
            { streaming = true }
        )
        if not requestOk
            or type(response) ~= "table"
            or response.success ~= true
            or type(response.result) ~= "string"
            or string.match(response.result, "%S") == nil then
            local detail = requestOk and type(response) == "table"
                and tostring(response.result or "빈 LLM 응답")
                or tostring(response)
            return cancelAndRestore(battleId, viewTurnId, detail)
        end

        local appendError = appendCharacterOutput(response.result)
        if appendError then
            return cancelAndRestore(battleId, viewTurnId, appendError)
        end

        local committed, commitErrors = callCore("commitOutput")
        if commitErrors then
            committed, commitErrors = callCore("commitOutput")
        end
        if commitErrors
            or type(committed) ~= "table"
            or committed.outputCommitted ~= true then
            refreshAnchor()
            alert(
                "도착 장면은 저장됐지만 정산을 완료하지 못했습니다.\n"
                    .. "전송 버튼을 눌러 정산을 다시 시도하세요."
            )
            return failure(
                commitErrors or {
                    makeError("aftermath_skip_commit_failed", "$.runtime", "도착 장면 정산을 완료하지 못했습니다."),
                },
                {
                    outputPersisted = true,
                    restored = false,
                }
            )
        end

        refreshAnchor()
        return success({
            generationReady = false,
            outputCommitted = true,
            aftermathComplete = true,
            skipped = true,
            skippedSceneGenerated = true,
            skippedTurnCount = committed.skippedTurnCount,
            status = committed.status,
            view = committed.view,
            progressionState = committed.progressionState,
        })
    end

    local arguments = { ... }
    if action == "run" then
        return run(arguments[1], arguments[2])
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 aftermathSkipScene 작업입니다: " .. tostring(action)),
    })
end)'''
SCENE.write_text(scene, encoding="utf-8")

# main.lua가 기본 브랜치와 바이트 단위로 같고, 기능이 별도 모듈에만 있는지 확인한다.
if MAIN.read_text(encoding="utf-8") != git_show("origin/main:System/main.lua"):
    raise SystemExit("main.lua was not restored exactly")
if "runAftermathSkipScene" in MAIN.read_text(encoding="utf-8"):
    raise SystemExit("aftermath skip orchestration remains in main.lua")
if '"aftermathSkipScene"' not in CONTROLLER.read_text(encoding="utf-8"):
    raise SystemExit("wrapper does not route to aftermathSkipScene")
if '"battleControllerCore"' not in CONTROLLER.read_text(encoding="utf-8"):
    raise SystemExit("wrapper does not route to battleControllerCore")
if "LLM" not in SCENE.read_text(encoding="utf-8"):
    raise SystemExit("scene module does not own LLM execution")
