from pathlib import Path

path = Path("System/battleController.lua")
source = path.read_text(encoding="utf-8")
old = '''        aftermath = migrated

        if aftermath.phase == "complete" then
'''
new = '''        aftermath = migrated

        if aftermath.phase == "settling" then
            local settled = settleAftermath(authority, aftermath, staticData)
            if type(settled) == "table" and settled.ok == true then
                settled.skipped = true
                settled.reused = true
            end
            return settled
        end
        if aftermath.phase == "complete" then
'''
count = source.count(old)
if count != 1:
    raise SystemExit(f"settling recovery anchor count: {count}")
path.write_text(source.replace(old, new, 1), encoding="utf-8")
