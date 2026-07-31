from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old[:160]!r}")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


def replace_count(path: str, old: str, new: str, expected: int) -> None:
    target = ROOT / path
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != expected:
        raise RuntimeError(f"{path}: expected {expected} matches, found {count}: {old[:160]!r}")
    target.write_text(text.replace(old, new), encoding="utf-8")


replace_once(
    "System/battleController.lua",
    '    local VIEW_NAME = "battleView"\n    local UI_BODY_NAME = "🔯🔯🔯"',
    '    local VIEW_NAME = "battleView"\n    local BATTLE_LOG_VIEW_NAME = "battleLogView"\n    local UI_BODY_NAME = "🔯🔯🔯"',
)
replace_once(
    "System/battleController.lua",
    '''    local function permitCanonicalBattleView(purpose, viewName)
        return purpose == "dataBridgeCanonicalV1" and viewName == VIEW_NAME
    end''',
    '''    local function permitCanonicalBattleView(purpose, viewName)
        return purpose == "dataBridgeCanonicalV1"
            and (viewName == VIEW_NAME or viewName == BATTLE_LOG_VIEW_NAME)
    end''',
)
replace_once(
    "System/battleController.lua",
    '''    local function validateBattleReadySetup(setupState, staticData)
''',
    '''    local function publishTerminalBattleLog(authority, staticData)
        if type(authority) ~= "table"
            or (authority.status ~= "victory" and authority.status ~= "defeat") then
            return nil, {
                makeError("battle_log_requires_terminal", "$.authority.status", "종료된 전투에서만 상세 로그를 게시할 수 있습니다."),
            }
        end
        local built, buildErrors = callModule(
            "battleHistory",
            "buildPublicView",
            authority.history,
            staticData
        )
        if buildErrors then return nil, buildErrors end
        if type(built.view) ~= "table" or built.view.available ~= true then
            return nil, {
                makeError("missing_terminal_battle_log", "$.runtime.battleHistory.view", "종료 전투의 공개 상세 로그를 만들지 못했습니다."),
            }
        end
        local published, publishErrors = callModule(
            "dataBridge",
            "_publishCanonical",
            BATTLE_LOG_VIEW_NAME,
            built.view,
            permitCanonicalBattleView
        )
        if publishErrors then return nil, publishErrors end
        if type(published.encoded) ~= "string" or published.encoded == "" then
            return nil, {
                makeError("missing_published_battle_log", "$.runtime.dataBridge.encoded", "상세 전투 로그 게시 문자열이 없습니다."),
            }
        end
        if type(getChatVar) ~= "function" then
            return nil, {
                makeError("battle_log_verify_unavailable", "$.host.getChatVar", "게시한 상세 전투 로그를 검증할 수 없습니다."),
            }
        end
        local readOk, storedWire = pcall(getChatVar, triggerId, BATTLE_LOG_VIEW_NAME)
        if not readOk then
            return nil, {
                makeError("battle_log_verify_failed", "$.chatVar.battleLogView", "게시한 상세 전투 로그를 다시 읽지 못했습니다: " .. tostring(storedWire)),
            }
        end
        if storedWire ~= published.encoded then
            return nil, {
                makeError("battle_log_write_not_persisted", "$.chatVar.battleLogView", "게시 뒤 읽은 상세 전투 로그가 인코딩 결과와 다릅니다."),
            }
        end
        return built.view, nil
    end

    local function validateBattleReadySetup(setupState, staticData)
''',
)
replace_count(
    "System/battleController.lua",
    '''            if summaryErrors then return failure(summaryErrors) end
            local settled, settlementErrors = callModule(''',
    '''            if summaryErrors then return failure(summaryErrors) end
            local _, battleLogErrors = publishTerminalBattleLog(authority, staticData)
            if battleLogErrors then return failure(battleLogErrors) end
            local settled, settlementErrors = callModule(''',
    2,
)

replace_once(
    "System/stateSchema.lua",
    '''    local function fingerprintsEqual(left, right)
''',
    '''    local function dataEqual(left, right, seen)
        if type(left) ~= type(right) then return false end
        if type(left) ~= "table" then return left == right end
        if getmetatable(left) ~= nil or getmetatable(right) ~= nil then return false end
        seen = seen or {}
        if seen[left] ~= nil then return seen[left] == right end
        seen[left] = right
        for key, value in pairs(left) do
            if not dataEqual(value, right[key], seen) then return false end
        end
        for key in pairs(right) do
            if left[key] == nil then return false end
        end
        return true
    end

    local function fingerprintsEqual(left, right)
''',
)
replace_once(
    "System/stateSchema.lua",
    '''        if type(pending.beforeState) == "table" and type(pending.afterState) == "table" then
''',
    '''        if type(pending.turnResult) == "table" and type(pending.afterState) == "table" then
            local history = pending.afterState.history
            local turns = type(history) == "table" and history.turns or nil
            local lastEntry = type(turns) == "table" and turns[#turns] or nil
            if type(lastEntry) ~= "table" or lastEntry.turnId ~= pending.turnId then
                addError(errors, "pending_history_turn_mismatch", "$.afterState.history.turns", "afterState 전투 이력의 마지막 턴이 pendingTurn과 다릅니다.")
            elseif not dataEqual(lastEntry.publicResult, pending.turnResult.publicResult) then
                addError(errors, "pending_history_public_result_mismatch", "$.afterState.history.turns", "전투 이력의 공개 로그와 pendingTurn 공개 결과가 다릅니다.")
            end
        end

        if type(pending.beforeState) == "table" and type(pending.afterState) == "table" then
''',
)

replace_once(
    "System/main.lua",
    'or "runtime-bundle-battle-history-v1-20260731"',
    'or "runtime-bundle-battle-history-v2-20260731"',
)

replace_once(
    "html/postBattle.html",
    '''.run-flow .run-section-head {
''',
    '''.run-flow .run-battle-log {
margin-top: 8px;
padding: 8px 10px;
border: 1px solid rgba(223, 174, 63, .24);
border-radius: 8px;
background: rgba(223, 174, 63, .045);
}

.run-flow .run-battle-log > summary {
cursor: pointer;
color: #e7cf8f;
font-size: 9px;
font-weight: 900;
list-style: none;
}

.run-flow .run-battle-log > summary::-webkit-details-marker {
display: none;
}

.run-flow .run-battle-log > summary::before {
display: inline-block;
margin-right: 6px;
content: "＋";
color: #f0dfae;
}

.run-flow .run-battle-log[open] > summary::before {
content: "−";
}

.run-flow .run-battle-log-list {
display: grid;
max-height: 300px;
gap: 4px;
margin: 8px 0 0;
padding: 8px 6px 0 22px;
overflow-y: auto;
color: #aaa39d;
border-top: 1px solid var(--run-line);
font-size: 8px;
line-height: 1.5;
overscroll-behavior: contain;
}

.run-flow .run-section-head {
''',
)
replace_once(
    "html/postBattle.html",
    '''{{settempvar::run_progression_destination::{{dictelement::{{tempvar::run_progression_route}}::destinationStation}}}}
<section class="run-flow" aria-label="전투 결과와 다음 진행">''',
    '''{{settempvar::run_progression_destination::{{dictelement::{{tempvar::run_progression_route}}::destinationStation}}}}
{{settempvar::battle_log_view::{{getvar::battleLogView}}}}
<section class="run-flow" aria-label="전투 결과와 다음 진행">''',
)
replace_once(
    "html/postBattle.html",
    '''</div>
</article>

{{#when::keep::{{dictelement::{{tempvar::run_progression_view}}::phase}}::is::reward}}''',
    '''</div>
</article>

{{#when::keep::{{dictelement::{{tempvar::battle_log_view}}::available}}::is::true}}
<details class="run-battle-log">
<summary>상세 전투 로그 펼쳐보기 · {{dictelement::{{tempvar::battle_log_view}}::turnCount}}턴</summary>
<ol class="run-battle-log-list">
{{#each::keep {{dictelement::{{tempvar::battle_log_view}}::entries}} as battle_log_entry}}
<li>{{dictelement::{{slot::battle_log_entry}}::label}}</li>
{{/each}}
</ol>
</details>
{{/when}}

{{#when::keep::{{dictelement::{{tempvar::run_progression_view}}::phase}}::is::reward}}''',
)

replace_once(
    "docs/battle-history.md",
    '''전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영하고 `battleView.battleLog`에 넣는다. `html/battleui.html`은 이를 접을 수 있는 상세 전투 로그로 표시한다.
''',
    '''전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영한다. 종료 전투의 `battleView.battleLog`와 별도로 컨트롤러가 검증된 `battleLogView`를 게시하므로, 즉시 종료와 조기 승리 후 자유행동 종료 모두 `html/postBattle.html` 정산 화면에서 전체 로그를 펼쳐 볼 수 있다.
''',
)

print("post-battle log patch applied")
