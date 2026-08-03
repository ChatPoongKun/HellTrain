from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    source = path.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor count: {count}")
    path.write_text(source.replace(old, new, 1), encoding="utf-8")


formatter = Path("System/turnPromptFormatter.lua")
old_ending = '''        if pending.afterState.status == "defeat" then
            instructions[#instructions + 1] = "패배 장면의 끝에서 경찰이 다가와 플레이어를 연행하게 되고 열차 밖으로 끌려나가는 순간 시야가 검게 끊기며 의식을 잃는 모습으로 마무리 하십시오."
        end
'''
new_ending = '''        local outcomeReason
        for _, event in ipairs(sanitized.events) do
            if event.type == "outcome" then
                outcomeReason = event.payload.reasonCode
                break
            end
        end
        if pending.afterState.status == "defeat" then
            local finalStealth = type(pending.afterState.player) == "table"
                and pending.afterState.player.stealth
                or nil
            if outcomeReason == "turn_limit" then
                instructions[#instructions + 1] = "턴 만료로 패배한 장면의 끝에서 열차가 목적지 역에 도착하고 캐릭터가 열차에서 내리는 모습으로 마무리하십시오. 경찰의 접근이나 연행, 열차 밖으로 끌려나감, 암전 또는 의식 상실은 묘사하지 마십시오."
            elseif isFinite(finalStealth) and finalStealth <= 0 then
                instructions[#instructions + 1] = "은폐가 부족해 패배한 장면의 끝에서 경찰이 다가와 플레이어를 연행하게 되고 열차 밖으로 끌려나가는 순간 시야가 검게 끊기며 의식을 잃는 모습으로 마무리 하십시오."
            end
        end
'''
replace_once(formatter, old_ending, new_ending, "defeat ending split")

main = Path("System/main.lua")
replace_once(
    main,
    '    or "runtime-bundle-47e5f3168db056f2"',
    '    or "runtime-bundle-28f0a6d79c4e531b"',
    "runtime bundle revision",
)

formatter_source = formatter.read_text(encoding="utf-8")
main_source = main.read_text(encoding="utf-8")
checks = {
    "turn-limit branch": formatter_source.count('outcomeReason == "turn_limit"') == 1,
    "stealth-only arrest branch": formatter_source.count("finalStealth <= 0") == 1,
    "destination ending": formatter_source.count("캐릭터가 열차에서 내리는 모습") == 1,
    "arrest ending": formatter_source.count("은폐가 부족해 패배한 장면") == 1,
    "turn-limit arrest prohibition": formatter_source.count("경찰의 접근이나 연행") == 1,
    "bundle revision": main_source.count("runtime-bundle-28f0a6d79c4e531b") == 1,
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit("failed static checks: " + ", ".join(failed))
