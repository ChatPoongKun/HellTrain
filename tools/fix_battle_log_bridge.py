from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(relative_path: str, old: str, new: str) -> None:
    path = ROOT / relative_path
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{relative_path}: expected one match, found {count}\n{old[:500]}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_once(
    "System/dataBridge.lua",
    '''        battleView = {
            moduleName = "viewBuilder",
            action = "validateBattleView",
            errorCode = "battle_view_invalid",
            errorMessage = "battleView 스키마 검증에 실패했습니다.",
            validatorMessage = "viewBuilder.validateBattleView 검증을 통과하지 못했습니다.",
        },
        gameSetupView = {''',
    '''        battleView = {
            moduleName = "viewBuilder",
            action = "validateBattleView",
            errorCode = "battle_view_invalid",
            errorMessage = "battleView 스키마 검증에 실패했습니다.",
            validatorMessage = "viewBuilder.validateBattleView 검증을 통과하지 못했습니다.",
        },
        battleLogView = {
            moduleName = "battleHistory",
            action = "validatePublicView",
            errorCode = "battle_log_view_invalid",
            errorMessage = "battleLogView 스키마 검증에 실패했습니다.",
            validatorMessage = "battleHistory.validatePublicView 검증을 통과하지 못했습니다.",
        },
        gameSetupView = {''',
)

replace_once(
    "System/battleHistory.lua",
    '''        validateSnapshot(entry.start, path .. ".start", errors, staticData, false)
        validateSnapshot(entry.finish, path .. ".finish", errors, staticData, true)

        if type(entry.mood) ~= "table" or getmetatable(entry.mood) ~= nil then
            addError(errors, "invalid_history_mood_result", path .. ".mood", "무드 판정 이력이 일반 객체가 아닙니다.")
        else
            if entry.mood.before ~= entry.start.mood or entry.mood.after ~= entry.finish.mood then''',
    '''        validateSnapshot(entry.start, path .. ".start", errors, staticData, false)
        validateSnapshot(entry.finish, path .. ".finish", errors, staticData, true)
        local startMood = type(entry.start) == "table" and entry.start.mood or nil
        local finishMood = type(entry.finish) == "table" and entry.finish.mood or nil

        if type(entry.mood) ~= "table" or getmetatable(entry.mood) ~= nil then
            addError(errors, "invalid_history_mood_result", path .. ".mood", "무드 판정 이력이 일반 객체가 아닙니다.")
        else
            if entry.mood.before ~= startMood or entry.mood.after ~= finishMood then''',
)

replace_once(
    "System/battleHistory.lua",
    '''    local function buildPublicView(history, staticInput)
''',
    '''    local function validatePublicView(view)
        local errors = {}
        if type(view) ~= "table" or getmetatable(view) ~= nil then
            return failure({ makeError("invalid_battle_log_view", "$", "상세 전투 로그 View가 일반 객체가 아닙니다.") })
        end
        local allowedViewKeys = {
            available = true,
            turnCount = true,
            entries = true,
        }
        for key in pairs(view) do
            if type(key) ~= "string" or allowedViewKeys[key] ~= true then
                addError(errors, "unknown_battle_log_view_field", "$", "상세 전투 로그 View에 허용되지 않은 필드가 있습니다.")
            end
        end
        if type(view.available) ~= "boolean" then
            addError(errors, "invalid_battle_log_availability", "$.available", "상세 전투 로그 사용 가능 여부는 불리언이어야 합니다.")
        end
        if not isInteger(view.turnCount, 0) or view.turnCount > MAX_TURNS then
            addError(errors, "invalid_battle_log_turn_count", "$.turnCount", "상세 전투 로그 턴 수가 올바르지 않습니다.")
        end
        if not isDenseArray(view.entries) then
            addError(errors, "invalid_battle_log_entries", "$.entries", "상세 전투 로그 항목이 연속 배열이 아닙니다.")
        else
            if view.available == false and (view.turnCount ~= 0 or #view.entries ~= 0) then
                addError(errors, "unavailable_battle_log_has_content", "$", "사용할 수 없는 상세 전투 로그에는 턴과 항목이 없어야 합니다.")
            elseif view.available == true and (not isInteger(view.turnCount, 1) or #view.entries == 0) then
                addError(errors, "available_battle_log_missing_content", "$", "사용 가능한 상세 전투 로그에는 턴과 항목이 필요합니다.")
            end
            local previousTurnNumber = 0
            for index, entry in ipairs(view.entries) do
                local path = "$.entries[" .. index .. "]"
                if type(entry) ~= "table" or getmetatable(entry) ~= nil then
                    addError(errors, "invalid_battle_log_entry", path, "상세 전투 로그 항목이 일반 객체가 아닙니다.")
                else
                    local allowedEntryKeys = {
                        turnNumber = true,
                        sequence = true,
                        type = true,
                        text = true,
                        label = true,
                    }
                    for key in pairs(entry) do
                        if type(key) ~= "string" or allowedEntryKeys[key] ~= true then
                            addError(errors, "unknown_battle_log_entry_field", path, "상세 전투 로그 항목에 허용되지 않은 필드가 있습니다.")
                        end
                    end
                    if not isInteger(entry.turnNumber, 1)
                        or (isInteger(view.turnCount, 0) and entry.turnNumber > view.turnCount) then
                        addError(errors, "invalid_battle_log_entry_turn", path .. ".turnNumber", "상세 전투 로그 항목의 턴 번호가 올바르지 않습니다.")
                    elseif entry.turnNumber < previousTurnNumber then
                        addError(errors, "unordered_battle_log_entry", path .. ".turnNumber", "상세 전투 로그 턴 순서가 역행합니다.")
                    else
                        previousTurnNumber = entry.turnNumber
                    end
                    if not isInteger(entry.sequence, 0) then
                        addError(errors, "invalid_battle_log_entry_sequence", path .. ".sequence", "상세 전투 로그 사건 순번이 올바르지 않습니다.")
                    end
                    if not isAsciiId(entry.type) then
                        addError(errors, "invalid_battle_log_entry_type", path .. ".type", "상세 전투 로그 사건 종류가 올바르지 않습니다.")
                    end
                    if type(entry.text) ~= "string" or entry.text == "" then
                        addError(errors, "invalid_battle_log_entry_text", path .. ".text", "상세 전투 로그 문장이 비어 있습니다.")
                    end
                    local expectedLabel = tostring(entry.turnNumber) .. "턴 · " .. tostring(entry.text)
                    if entry.label ~= expectedLabel then
                        addError(errors, "battle_log_entry_label_mismatch", path .. ".label", "상세 전투 로그 표시 문장이 턴 번호와 본문에 일치하지 않습니다.")
                    end
                end
            end
        end
        if #errors > 0 then return failure(errors) end
        return success({ valid = true })
    end

    local function buildPublicView(history, staticInput)
''',
)

replace_once(
    "System/battleHistory.lua",
    '''    elseif action == "buildPublicView" then
        return buildPublicView(arguments[1], arguments[2])
    end''',
    '''    elseif action == "buildPublicView" then
        return buildPublicView(arguments[1], arguments[2])
    elseif action == "validatePublicView" then
        return validatePublicView(arguments[1])
    end''',
)

replace_once(
    "Tests/battle-history-check.lua",
    '''assert(view.view.available == true)
assert(view.view.turnCount == 1)
assert(#view.view.entries >= 4)

print("battle-history-check: ok")''',
    '''assert(view.view.available == true)
assert(view.view.turnCount == 1)
assert(#view.view.entries >= 4)
local viewValidation = historyModule(nil, "validatePublicView", view.view)
assert(viewValidation.ok)
local invalidView = {
    available = true,
    turnCount = 1,
    entries = {
        { turnNumber = 1, sequence = 0, type = "turn_start", text = "시작", label = "손상된 라벨" },
    },
}
local invalidValidation = historyModule(nil, "validatePublicView", invalidView)
assert(invalidValidation.ok == false)
assert(invalidValidation.errors[1].code == "battle_log_entry_label_mismatch")

print("battle-history-check: ok")''',
)

replace_once(
    "docs/battle-history.md",
    '''전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영한다. 종료 전투의 `battleView.battleLog`와 별도로 컨트롤러가 검증된 `battleLogView`를 게시하므로, 즉시 종료와 조기 승리 후 자유행동 종료 모두 `html/postBattle.html` 정산 화면에서 전체 로그를 펼쳐 볼 수 있다.''',
    '''전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영한다. `battleHistory.validatePublicView`와 `dataBridge`의 `battleLogView` 허용 계약을 모두 통과한 결과만 게시한다. 종료 전투의 `battleView.battleLog`와 별도로 컨트롤러가 검증된 `battleLogView`를 게시하므로, 즉시 종료와 조기 승리 후 자유행동 종료 모두 `html/postBattle.html` 정산 화면에서 전체 로그를 펼쳐 볼 수 있다.''',
)

replace_once(
    "System/main.lua",
    'or "runtime-bundle-battle-history-v3-20260731"',
    'or "runtime-bundle-battle-history-v4-20260731"',
)

print("battle log bridge fixes applied")
