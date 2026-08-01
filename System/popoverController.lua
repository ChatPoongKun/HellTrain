(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local UI_BODY_NAME = "🔯🔯🔯"
    local UI_LORE_NAME = "battleui.html"
    local MAX_ID_LENGTH = 128
    local VARS = {
        kind = "battlePopoverKind",
        id = "battlePopoverId",
        turnId = "battlePopoverTurnId",
        token = "battlePopoverToken",
    }
    local ALLOWED_KINDS = {
        environment = true,
        station = true,
        trait = true,
        resource = true,
        enemy_plan = true,
        player_plan = true,
        mood = true,
        choice = true,
        change = true,
        tag = true,
    }

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

    local function isRuntimeId(value)
        return type(value) == "string"
            and #value >= 1
            and #value <= MAX_ID_LENGTH
            and string.match(value, "^[A-Za-z0-9][A-Za-z0-9_-]*$") ~= nil
    end

    local function isInteractionToken(value)
        return value == ""
            or (type(value) == "string"
                and #value <= MAX_ID_LENGTH
                and string.match(value, "^draftv1_%d+_%d+_%d+$") ~= nil)
    end

    local function writeChatVar(name, value)
        if type(setChatVar) ~= "function" or type(getChatVar) ~= "function" then
            return makeError(
                "chat_var_write_unavailable",
                "$.host.setChatVar",
                "팝오버 선택값을 저장할 setChatVar/getChatVar가 없습니다."
            )
        end
        local normalized = tostring(value or "")
        local writeOk, writeError = pcall(setChatVar, triggerId, name, normalized)
        if not writeOk then
            return makeError(
                "chat_var_write_failed",
                "$.chatVar[" .. string.format("%q", name) .. "]",
                "팝오버 선택값 저장에 실패했습니다: " .. tostring(writeError)
            )
        end
        local readOk, stored = pcall(getChatVar, triggerId, name)
        if not readOk then
            return makeError(
                "chat_var_verify_failed",
                "$.chatVar[" .. string.format("%q", name) .. "]",
                "팝오버 선택값을 저장한 뒤 다시 읽지 못했습니다: " .. tostring(stored)
            )
        end
        if stored ~= normalized then
            return makeError(
                "chat_var_write_not_persisted",
                "$.chatVar[" .. string.format("%q", name) .. "]",
                "팝오버 선택값이 저장되지 않았습니다."
            )
        end
        return nil
    end

    local function renderBattleUi()
        if type(loadLores) ~= "function" then
            return nil, {
                makeError(
                    "lore_loader_unavailable",
                    "$.host.loadLores",
                    "전투 UI를 다시 평가할 loadLores가 없습니다."
                ),
            }
        end
        local loadOk, battleUi = pcall(loadLores, triggerId, UI_LORE_NAME)
        if not loadOk then
            return nil, {
                makeError(
                    "lore_load_failed",
                    "$.lore.battleui",
                    "팝오버 선택 뒤 battleui.html 평가에 실패했습니다: " .. tostring(battleUi)
                ),
            }
        end
        if type(battleUi) ~= "string" or battleUi == "" then
            return nil, {
                makeError(
                    "missing_lore",
                    "$.lore.battleui",
                    "평가된 battleui.html이 비어 있습니다."
                ),
            }
        end
        local writeError = writeChatVar(UI_BODY_NAME, battleUi)
        if writeError then
            return nil, { writeError }
        end
        return battleUi, nil
    end

    local function openPopover(kind, id, turnId, interactionToken)
        kind = tostring(kind or "")
        id = tostring(id or "")
        turnId = tostring(turnId or "")
        interactionToken = tostring(interactionToken or "")

        if not ALLOWED_KINDS[kind] then
            return failure({
                makeError("invalid_popover_kind", "$.kind", "지원하지 않는 팝오버 종류입니다: " .. kind),
            })
        end
        if not isRuntimeId(id) then
            return failure({
                makeError("invalid_popover_id", "$.id", "팝오버 항목 ID가 올바르지 않습니다."),
            })
        end
        if not isRuntimeId(turnId) then
            return failure({
                makeError("invalid_popover_turn", "$.turnId", "팝오버가 연결될 turnId가 올바르지 않습니다."),
            })
        end
        if not isInteractionToken(interactionToken) then
            return failure({
                makeError("invalid_popover_token", "$.interactionToken", "팝오버가 연결될 interaction token이 올바르지 않습니다."),
            })
        end

        -- kind를 마지막에 기록한다. 중간 write에서 실패하면 CBS가 불완전한
        -- 선택값을 열린 팝오버로 해석하지 않는다.
        for _, write in ipairs({
            { VARS.id, id },
            { VARS.turnId, turnId },
            { VARS.token, interactionToken },
            { VARS.kind, kind },
        }) do
            local writeError = writeChatVar(write[1], write[2])
            if writeError then
                local rollbackError = writeChatVar(VARS.kind, "none")
                local errors = { writeError }
                if rollbackError then errors[#errors + 1] = rollbackError end
                return failure(errors)
            end
        end

        local battleUi, renderErrors = renderBattleUi()
        if renderErrors then
            local rollbackError = writeChatVar(VARS.kind, "none")
            if rollbackError then renderErrors[#renderErrors + 1] = rollbackError end
            return failure(renderErrors)
        end
        return success({
            opened = true,
            kind = kind,
            id = id,
            turnId = turnId,
            uiBytes = #battleUi,
        })
    end

    local function closePopover()
        local writeError = writeChatVar(VARS.kind, "none")
        if writeError then return failure({ writeError }) end
        local battleUi, renderErrors = renderBattleUi()
        if renderErrors then return failure(renderErrors) end
        return success({
            opened = false,
            uiBytes = #battleUi,
        })
    end

    local arguments = { ... }
    if action == "open" then
        return openPopover(arguments[1], arguments[2], arguments[3], arguments[4])
    elseif action == "close" then
        return closePopover()
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 popoverController 작업입니다: " .. tostring(action)),
    })
end)
