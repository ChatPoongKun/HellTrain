from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECTOR = ROOT / "System" / "turnEventProjector.lua"
MAIN = ROOT / "System" / "main.lua"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


projector = PROJECTOR.read_text(encoding="utf-8")

projector = replace_once(
    projector,
    '''        local sawMoodEvaluation = false
        local sawCleanup = false
        local sawSessionEnd = false
        local latchedOutcome = nil
        local postCleanupSnapshot = nil
        local triggerPhases = {
''',
    '''        local sawMoodEvaluation = false
        local expectedMoodStealthEffect = nil
        local sawMoodStealthEffect = false
        local sawCleanup = false
        local sawSessionEnd = false
        local latchedOutcome = nil
        local postCleanupSnapshot = nil

        local function moodStealthEffect(moodId, repeated)
            local op
            local amount
            if moodId == "rejection" then
                op = "lose_stealth"
                amount = repeated and 6 or 3
            elseif moodId == "suspicion" then
                op = "lose_stealth"
                amount = repeated and 2 or 1
            elseif moodId == "confusion" then
                op = "recover_stealth"
                amount = 1
            elseif moodId == "compliance" then
                op = "recover_stealth"
                amount = 2
            else
                return nil
            end
            return {
                op = op,
                amount = amount,
                delta = op == "recover_stealth" and amount or -amount,
            }
        end

        local triggerPhases = {
''',
    "tail state declarations",
)

projector = replace_once(
    projector,
    '''            elseif sawMoodEvaluation and event.type ~= "turn_cleanup" then
                return failure({ makeError("invalid_turn_tail_order", path, "무드 평가 바로 뒤에 턴 정리가 와야 합니다.") })
            elseif event.phase == "session_end" then
''',
    '''            elseif sawMoodEvaluation then
                local expectedTailType = "turn_cleanup"
                if expectedMoodStealthEffect ~= nil and sawMoodStealthEffect ~= true then
                    expectedTailType = "effect_applied"
                elseif sawMoodStealthEffect == true
                    and trackedStealth <= 0
                    and latchedOutcome == nil then
                    expectedTailType = "outcome_latched"
                end
                if event.type ~= expectedTailType then
                    return failure({
                        makeError(
                            "invalid_turn_tail_order",
                            path,
                            "무드 평가 뒤 사건 순서가 올바르지 않습니다: "
                                .. expectedTailType
                                .. " 사건이 필요합니다."
                        ),
                    })
                end
            elseif event.phase == "session_end" then
''',
    "tail ordering",
)

projector = replace_once(
    projector,
    '''            elseif event.type == "effect_applied" then
                local allowedEffectSources = {
                    card = true,
                    plan = true,
                    trait = true,
                    perk = true,
                    environment = true,
                }
                if allowedEffectSources[event.source.kind] ~= true then
''',
    '''            elseif event.type == "effect_applied" then
                local isMoodStateEffect = event.source.kind == "system"
                    and event.source.id == "mood_state"
                local allowedEffectSources = {
                    card = true,
                    plan = true,
                    trait = true,
                    perk = true,
                    environment = true,
                }
                if allowedEffectSources[event.source.kind] ~= true and not isMoodStateEffect then
''',
    "effect source allowlist",
)

projector = replace_once(
    projector,
    '''                elseif event.source.kind == "card" then
                    local lookupErrors = {}
                    findCard(staticData, event.source.id, event.source.side, path .. ".source.id", lookupErrors)
                    if #lookupErrors > 0 then
                        return failure(lookupErrors)
                    end
                    if event.phase ~= event.source.side .. "_card" then
                        return failure({ makeError("effect_phase_mismatch", path .. ".phase", "카드 효과 phase가 소유자와 다릅니다.") })
                    end
                end
                if payload.op == "pay_stealth_cost" then
''',
    '''                elseif event.source.kind == "card" then
                    local lookupErrors = {}
                    findCard(staticData, event.source.id, event.source.side, path .. ".source.id", lookupErrors)
                    if #lookupErrors > 0 then
                        return failure(lookupErrors)
                    end
                    if event.phase ~= event.source.side .. "_card" then
                        return failure({ makeError("effect_phase_mismatch", path .. ".phase", "카드 효과 phase가 소유자와 다릅니다.") })
                    end
                elseif isMoodStateEffect then
                    if sawMoodEvaluation ~= true
                        or sawMoodStealthEffect == true
                        or expectedMoodStealthEffect == nil
                        or event.phase ~= "turn_end"
                        or event.side ~= "player"
                        or event.source.side ~= nil
                        or event.source.instanceId ~= nil
                        or event.resolutionId ~= nil
                        or type(event.cause) ~= "table"
                        or event.cause.kind ~= "mood_state"
                        or event.cause.resolutionId ~= nil
                        or event.cause.eventId ~= nil then
                        return failure({
                            makeError(
                                "invalid_mood_state_effect",
                                path,
                                "확정 무드 은폐 효과 사건의 위치 또는 출처가 올바르지 않습니다."
                            ),
                        })
                    end
                end
                if payload.op == "pay_stealth_cost" then
''',
    "mood effect envelope validation",
)

projector = replace_once(
    projector,
    '''                if effectError then
                    return failure({ effectError })
                end
                if payload.op == "add_mood_token" or payload.op == "remove_mood_token" or payload.op == "force_mood" then
''',
    '''                if effectError then
                    return failure({ effectError })
                end
                if isMoodStateEffect then
                    local expected = expectedMoodStealthEffect
                    if payload.index ~= 1
                        or payload.cause ~= "moodState"
                        or effect.op ~= expected.op
                        or effect.target ~= "player"
                        or effect.amount ~= expected.amount
                        or effect.before ~= trackedStealth
                        or effect.after ~= trackedStealth + expected.delta
                        or effect.changed ~= true then
                        return failure({
                            makeError(
                                "invalid_mood_state_effect",
                                path .. ".payload",
                                "확정 무드 은폐 효과가 무드 평가 결과와 다릅니다."
                            ),
                        })
                    end
                    sawMoodStealthEffect = true
                end
                if payload.op == "add_mood_token" or payload.op == "remove_mood_token" or payload.op == "force_mood" then
''',
    "mood effect payload validation",
)

projector = replace_once(
    projector,
    '''                local expectedOutcome = resourceOutcome
                local expectedReason = event.phase == "turn_end" and "turn_end_checkpoint" or "card_checkpoint"
                if resourceOutcome == nil
                    and event.phase == "turn_end"
                    and resolution.turnNumber == beforeState.turnLimit then
                    expectedOutcome = "defeat"
                    expectedReason = "turn_limit"
                end
''',
    '''                local expectedOutcome = resourceOutcome
                local expectedReason = event.phase == "turn_end" and "turn_end_checkpoint" or "card_checkpoint"
                if event.phase == "turn_end"
                    and sawMoodStealthEffect == true
                    and resourceOutcome == "defeat" then
                    expectedReason = "mood_state_checkpoint"
                elseif resourceOutcome == nil
                    and event.phase == "turn_end"
                    and resolution.turnNumber == beforeState.turnLimit then
                    expectedOutcome = "defeat"
                    expectedReason = "turn_limit"
                end
''',
    "mood outcome reason",
)

projector = replace_once(
    projector,
    '''                sawMoodEvaluation = true
                trackedMood = payload.after
                trackedMoodTokens = expectedTokensAfter
                local safe = {
''',
    '''                sawMoodEvaluation = true
                trackedMood = payload.after
                trackedMoodTokens = expectedTokensAfter
                expectedMoodStealthEffect = nil
                if latchedOutcome == nil then
                    expectedMoodStealthEffect = moodStealthEffect(
                        payload.after,
                        resolution.turnNumber > 1 and payload.before == payload.after
                    )
                end
                local safe = {
''',
    "expected mood effect",
)

PROJECTOR.write_text(projector, encoding="utf-8")

main = MAIN.read_text(encoding="utf-8")
main = replace_once(
    main,
    '    or "runtime-bundle-a006c702e7daa0e8"\n',
    '    or "runtime-bundle-e4c8b1f09a72d635"\n',
    "runtime bundle revision",
)
MAIN.write_text(main, encoding="utf-8")
