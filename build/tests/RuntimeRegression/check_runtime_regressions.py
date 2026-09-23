"""Fail the local release build on command, turn, or recovery regressions."""
from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SIM = ROOT / 'build/tests/BattleSimulation/StyleDecks'
powershell = shutil.which('pwsh') or shutil.which('powershell')
if not powershell:
    raise SystemExit('PowerShell is required for the static release checks.')

if sys.argv[1:] not in ([], ['--fast']):
    raise SystemExit('usage: check_runtime_regressions.py [--fast]')
fast = sys.argv[1:] == ['--fast']

checks = [
    ('check_character_registry.py', [sys.executable, HERE / 'check_character_registry.py']),
    ('check_character_registry_contract.py', [sys.executable, HERE / 'check_character_registry_contract.py']),
    ('validate_card_taxonomy.py', [sys.executable, ROOT / 'build/tests/CardTaxonomy/validate_card_taxonomy.py']),
    ('runtime-bundle-contract-check.ps1', [powershell, '-NoProfile', '-File', ROOT / 'build/tests/runtime-bundle-contract-check.ps1']),
    ('html-indent-check.ps1', [powershell, '-NoProfile', '-File', ROOT / 'build/tests/html-indent-check.ps1']),
    *[(Path(args[0]).name, [sys.executable, *args]) for args in [
        [HERE / 'check_scoped_static_data.py'],
        [HERE / 'check_common_character_deck.py'],
        [HERE / 'check_character_images.py'],
        [HERE / 'check_character_switch.py'],
        [HERE / 'check_send_guidance.py'],
        [HERE / 'check_narrative_state_guidance.py'],
        [HERE / 'check_validation_reuse.py'],
        [HERE / 'check_interaction_ui.py'],
        [HERE / 'check_preview_rng.py'],
        [HERE / 'check_mood_presentation.py'],
        [HERE / 'check_skip_scope.py'],
        [HERE / 'check_write_positions.py'],
        [HERE / 'check_surrender.py'],
        [HERE / 'check_terminal_settlement.py'],
        [HERE / 'check_reroll_recovery.py'],
        [HERE / 'check_aftermath_reroll.py'],
        [HERE / 'check_plan_choices.py'],
    ]],
]
if not fast:
    checks += [(Path(args[0]).name, [sys.executable, *args]) for args in [
        [HERE / 'check_scoped_static_data.py', 'jit'],
        [HERE / 'check_common_character_deck.py', 'jit'],
        [HERE / 'check_character_images.py', 'jit'],
        [HERE / 'check_character_switch.py', 'jit'],
        [HERE / 'check_surrender.py', 'jit'],
        [HERE / 'check_validation_reuse.py', 'jit'],
        [HERE / 'check_interaction_ui.py', 'jit'],
        [HERE / 'check_aftermath_reroll.py', 'jit'],
        [HERE / 'check_preview_rng.py', 'luajit21'],
        [HERE / 'check_character_journal.py'],
        [HERE / 'check_character_journal.py', 'jit'],
        [HERE / 'check_card_effect_contracts.py'],
        [HERE / 'check_card_effect_contracts.py', 'jit'],
        [HERE / 'check_character_card_pipeline.py'],
        [HERE / 'check_character_card_pipeline.py', 'jit'],
        [HERE / 'check_mood_presentation.py', 'jit'],
        [HERE / 'check_skip_scope.py', 'jit'],
        [HERE / 'check_terminal_settlement.py', 'jit'],
        [SIM / 'check_simulation.py', '--expiry', '--engine', 'lua54'],
        [SIM / 'check_followup.py', '--engine', 'lua54'],
        [HERE / 'check_plan_choices.py', 'jit'],
        [HERE / 'check_player_card_pipeline.py'],
        [HERE / 'check_perk_rules.py'],
        [HERE / 'check_perk_rewards.py'],
        [HERE / 'check_victory_rewards.py'],
        [HERE / 'check_perk_host_flow.py'],
        [HERE / 'check_perks.py'],
    ]]
for label, command in checks:
    print('CHECK:', label, flush=True)
    result = subprocess.run(list(map(str, command)), cwd=ROOT,
                            env={**os.environ, 'PYTHONIOENCODING': 'utf-8'})
    if result.returncode:
        print('BLOCKED: runtime regression failed; do not build the release.', flush=True)
        raise SystemExit(result.returncode)
print(f'PASS: all {len(checks)} {"fast" if fast else "release"} checks', flush=True)
