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
    "System/battleController.lua",
    '''            local summary, summaryErrors = buildTerminalSummary(
                nextState,
                selectedPending,
                staticData
            )
            if summaryErrors then return failure(summaryErrors) end
            local _, battleLogErrors = publishTerminalBattleLog(authority, staticData)''',
    '''            local summary, summaryErrors = buildTerminalSummary(
                nextState,
                selectedPending,
                staticData
            )
            if summaryErrors then return failure(summaryErrors) end
            local _, battleLogErrors = publishTerminalBattleLog(nextState, staticData)''',
)

replace_once(
    "System/battleHistory.lua",
    '''    local function turnContext(entry)
        local value = {
            turnNumber = entry.turnNumber,
            turnId = entry.turnId,
            startMood = entry.start.mood,
            endMood = entry.finish.mood,
            status = entry.finish.status,
            playerCards = {},
            characterCards = {},
            playerActionTags = {},
            characterActionTags = {},
        }
        for _, side in ipairs({ "player", "character" }) do
            local outputCards = side == "player" and value.playerCards or value.characterCards
            local outputTags = side == "player" and value.playerActionTags or value.characterActionTags
            for _, record in ipairs(entry.cards[side]) do
                outputCards[#outputCards + 1] = cardContextRecord(record)
                if record.resolved then outputTags[#outputTags + 1] = record.actionTag end
            end
        end
        return value
    end''',
    '''    local function turnContext(entry)
        local value = {
            turnNumber = entry.turnNumber,
            turnId = entry.turnId,
            startMood = entry.start.mood,
            endMood = entry.finish.mood,
            status = entry.finish.status,
            start = {
                stealth = entry.start.stealth,
                resistance = entry.start.resistance,
                mood = entry.start.mood,
            },
            finish = {
                stealth = entry.finish.stealth,
                resistance = entry.finish.resistance,
                mood = entry.finish.mood,
                status = entry.finish.status,
            },
            mood = {
                before = entry.mood.before,
                after = entry.mood.after,
                applied = entry.mood.applied,
                forcedCount = entry.mood.forcedCount,
                forceCancelled = entry.mood.forceCancelled,
                resolution = entry.mood.resolution,
                tokensBefore = copyCounts(entry.mood.tokensBefore),
                tokensAfter = copyCounts(entry.mood.tokensAfter),
            },
            playerCards = {},
            characterCards = {},
            playerActionTags = {},
            characterActionTags = {},
        }
        if entry.mood.targetMood ~= nil then value.mood.targetMood = entry.mood.targetMood end
        if type(entry.mood.tiedMoods) == "table" then
            value.mood.tiedMoods = {}
            for index, moodId in ipairs(entry.mood.tiedMoods) do
                value.mood.tiedMoods[index] = moodId
            end
        end
        for _, side in ipairs({ "player", "character" }) do
            local outputCards = side == "player" and value.playerCards or value.characterCards
            local outputTags = side == "player" and value.playerActionTags or value.characterActionTags
            for _, record in ipairs(entry.cards[side]) do
                outputCards[#outputCards + 1] = cardContextRecord(record)
                if record.resolved then outputTags[#outputTags + 1] = record.actionTag end
            end
        end
        return value
    end''',
)

replace_once(
    "System/battleHistory.lua",
    '''        for window = 1, #turns do
            local windowValue = {
                turns = window,
                player = { declaredTagCounts = {}, resolvedTagCounts = {} },
                character = { declaredTagCounts = {}, resolvedTagCounts = {} },
            }
            local first = math.max(1, #turns - window + 1)
            for index = first, #turns do
                local entry = turns[index]
                for _, side in ipairs({ "player", "character" }) do
                    addCounts(windowValue[side].declaredTagCounts, entry.tagCounts[side].declared)
                    addCounts(windowValue[side].resolvedTagCounts, entry.tagCounts[side].resolved)
                end
            end
            context.windows[window] = windowValue
        end''',
    '''        for window = 1, MAX_TURNS do
            local availableTurns = math.min(window, #turns)
            local windowValue = {
                requestedTurns = window,
                availableTurns = availableTurns,
                player = { declaredTagCounts = {}, resolvedTagCounts = {} },
                character = { declaredTagCounts = {}, resolvedTagCounts = {} },
            }
            local first = math.max(1, #turns - window + 1)
            for index = first, #turns do
                local entry = turns[index]
                for _, side in ipairs({ "player", "character" }) do
                    addCounts(windowValue[side].declaredTagCounts, entry.tagCounts[side].declared)
                    addCounts(windowValue[side].resolvedTagCounts, entry.tagCounts[side].resolved)
                end
            end
            context.windows[window] = windowValue
        end''',
)

replace_once(
    "System/battleHistory.lua",
    '''        if not isDenseArray(value.turns) or not isDenseArray(value.windows) then
            addError(errors, "invalid_history_context_arrays", "$", "컨텍스트 턴 또는 기간 집계가 연속 배열이 아닙니다.")
        elseif #value.turns ~= value.completedTurns or #value.windows ~= value.completedTurns then
            addError(errors, "history_context_count_mismatch", "$", "컨텍스트 완료 턴 수와 배열 길이가 다릅니다.")
        end
        for _, side in ipairs({ "player", "character" }) do''',
    '''        if not isDenseArray(value.turns) or not isDenseArray(value.windows) then
            addError(errors, "invalid_history_context_arrays", "$", "컨텍스트 턴 또는 기간 집계가 연속 배열이 아닙니다.")
        elseif #value.turns ~= value.completedTurns or #value.windows ~= MAX_TURNS then
            addError(errors, "history_context_count_mismatch", "$", "컨텍스트 완료 턴 수 또는 기간 창 개수가 다릅니다.")
        else
            for window = 1, MAX_TURNS do
                local current = value.windows[window]
                if type(current) ~= "table"
                    or current.requestedTurns ~= window
                    or current.availableTurns ~= math.min(window, value.completedTurns) then
                    addError(errors, "invalid_history_window", "$.windows[" .. window .. "]", "기간 창의 요청·가용 턴 수가 올바르지 않습니다.")
                else
                    for _, side in ipairs({ "player", "character" }) do
                        local sideValue = current[side]
                        if type(sideValue) ~= "table"
                            or type(sideValue.declaredTagCounts) ~= "table"
                            or type(sideValue.resolvedTagCounts) ~= "table" then
                            addError(errors, "invalid_history_window_side", "$.windows[" .. window .. "]." .. side, "기간 창의 진영별 태그 집계가 올바르지 않습니다.")
                        end
                    end
                end
            end
        end
        for _, side in ipairs({ "player", "character" }) do''',
)

replace_once(
    "Tests/battle-history-check.lua",
    '''assert(context.context.previousTurn.startMood == "ignore")
assert(context.context.previousTurn.endMood == "suspicion")
assert(context.context.player.lastResolvedActionTag == "contact")
assert(context.context.windows[1].player.resolvedTagCounts.contact == 1)''',
    '''assert(context.context.previousTurn.startMood == "ignore")
assert(context.context.previousTurn.endMood == "suspicion")
assert(context.context.previousTurn.start.stealth == 30)
assert(context.context.previousTurn.finish.resistance == 25)
assert(context.context.previousTurn.mood.resolution == "token")
assert(context.context.player.lastResolvedActionTag == "contact")
assert(context.context.windows[1].player.resolvedTagCounts.contact == 1)
assert(context.context.windows[3].requestedTurns == 3)
assert(context.context.windows[3].availableTurns == 1)
assert(context.context.windows[3].player.resolvedTagCounts.contact == 1)
assert(context.context.windows[12].player.resolvedTagCounts.contact == 1)''',
)

replace_once(
    "docs/battle-history.md",
    '''local previousMood = context.history.previousTurn
    and context.history.previousTurn.endMood''',
    '''local previousMood = context.history.previousTurn
    and context.history.previousTurn.finish.mood

local previousStealth = context.history.previousTurn
    and context.history.previousTurn.finish.stealth''',
)
replace_once(
    "docs/battle-history.md",
    '''카드 사용 횟수는 `declaredTagCounts`와 `resolvedTagCounts`를 구분한다. 일반적인 “사용했다” 조건은 `resolvedTagCounts`를 사용한다. `windows[N]`은 직전 완료 N턴을 포함하며 현재 해결 중인 턴은 포함하지 않는다.''',
    '''카드 사용 횟수는 `declaredTagCounts`와 `resolvedTagCounts`를 구분한다. 일반적인 “사용했다” 조건은 `resolvedTagCounts`를 사용한다. `windows[N]`은 N=1..12에 항상 존재하고 직전 완료 N턴까지 포함하며 현재 해결 중인 턴은 포함하지 않는다. 초반에는 `availableTurns`가 실제 존재하는 완료 턴 수를 나타낸다. `previousTurn.start`, `previousTurn.finish`, `previousTurn.mood`에서 직전 턴의 자원·무드·토큰 판정 상태를 읽을 수 있다.''',
)

replace_once(
    "System/main.lua",
    'or "runtime-bundle-battle-history-v2-20260731"',
    'or "runtime-bundle-battle-history-v3-20260731"',
)

print("final battle history fixes applied")
