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
    "System/battleHistory.lua",
    '''        if #turns == 0 then
            return success({ view = { available = false, turnCount = 0, entries = {} } })
        end''',
    '''        if #turns == 0 then
            local emptyView = { available = false, turnCount = 0, entries = {} }
            local emptyValidation = validatePublicView(emptyView)
            if not emptyValidation.ok then return emptyValidation end
            return success({ view = emptyView })
        end''',
)
replace_once(
    "System/battleHistory.lua",
    '''        return success({
            view = {
                available = true,
                turnCount = #turns,
                entries = entries,
            },
        })
    end''',
    '''        local view = {
            available = true,
            turnCount = #turns,
            entries = entries,
        }
        local viewValidation = validatePublicView(view)
        if not viewValidation.ok then return viewValidation end
        return success({ view = view })
    end''',
)

replace_once(
    "Tests/battle-history-check.lua",
    '''local historyModule = loadModule("System/battleHistory.lua")
local staticData = {''',
    '''local historyModule = loadModule("System/battleHistory.lua")
local dataBridgeModule = loadModule("System/dataBridge.lua")
local staticData = {''',
)
replace_once(
    "Tests/battle-history-check.lua",
    '''local viewValidation = historyModule(nil, "validatePublicView", view.view)
assert(viewValidation.ok)
local invalidView = {''',
    '''local viewValidation = historyModule(nil, "validatePublicView", view.view)
assert(viewValidation.ok)
_G.runScript = function(triggerId, moduleName, action, ...)
    assert(moduleName == "battleHistory")
    return historyModule(triggerId, action, ...)
end
local bridgeValidation = dataBridgeModule(nil, "validate", "battleLogView", view.view)
assert(bridgeValidation.ok)
local bridgeEncoding = dataBridgeModule(nil, "encode", "battleLogView", view.view)
assert(bridgeEncoding.ok)
assert(type(bridgeEncoding.encoded) == "string" and #bridgeEncoding.encoded > 0)
local invalidView = {''',
)
replace_once(
    "Tests/battle-history-check.lua",
    '''local invalidValidation = historyModule(nil, "validatePublicView", invalidView)
assert(invalidValidation.ok == false)
assert(invalidValidation.errors[1].code == "battle_log_entry_label_mismatch")

print("battle-history-check: ok")''',
    '''local invalidValidation = historyModule(nil, "validatePublicView", invalidView)
assert(invalidValidation.ok == false)
assert(invalidValidation.errors[1].code == "battle_log_entry_label_mismatch")
local invalidBridgeValidation = dataBridgeModule(nil, "validate", "battleLogView", invalidView)
assert(invalidBridgeValidation.ok == false)

print("battle-history-check: ok")''',
)

replace_once(
    "docs/battle-history.md",
    '''전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영한다. `battleHistory.validatePublicView`와 `dataBridge`의 `battleLogView` 허용 계약을 모두 통과한 결과만 게시한다.''',
    '''전투가 종료되면 `battleHistory.buildPublicView`가 공개 사건만 텍스트로 투영하고 반환 직전에 `validatePublicView`를 반드시 통과시킨다. `dataBridge`에도 `battleLogView` 전용 검증 계약이 등록되어 있으므로 일반 validate/encode 경로에서도 같은 스키마가 적용된다.''',
)

replace_once(
    "System/main.lua",
    'or "runtime-bundle-battle-history-v4-20260731"',
    'or "runtime-bundle-battle-history-v5-20260731"',
)

print("battle log validation closure applied")
