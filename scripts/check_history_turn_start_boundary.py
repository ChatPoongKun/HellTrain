#!/usr/bin/env python3
"""Regression check for completed-history validation after turn-start effects."""

import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HISTORY = (ROOT / "System" / "battleHistory.lua").read_text(encoding="utf-8")
RUNTIME = (ROOT / "System" / "runtime.lua").read_text(encoding="utf-8")

validation = HISTORY[
    HISTORY.index("    local function validateHistory") : HISTORY.index("    local function findInstance")
]
baseline = validation.index("local baseline =")
stealth_check = validation.index('addError(errors, "battle_history_stealth_mismatch"')
assert baseline < stealth_check
assert "isInteger(state.turnNumber, 1)" in validation
assert "count == state.turnNumber - 1" in validation
assert "state.lastCommittedTurnId == last.turnId" in validation
assert 'type(receipt) == "table"' in validation
assert "receipt.turnNumber == state.turnNumber" in validation
assert "currentStealth = baseline.stealth" in validation
assert "currentResistance = baseline.resistance" in validation
assert "currentMood = baseline.mood" in validation

policy = RUNTIME[
    RUNTIME.index("local function projectHistoryValidationState") : RUNTIME.index("function getRunScriptCacheDiagnostics")
]
assert "baseline.stealth ~= finish.stealth" in policy
assert "baseline.resistance ~= finish.resistance" in policy
assert "baseline.mood ~= finish.mood" in policy

with zipfile.ZipFile(ROOT / "build" / "HellTrain.charx") as archive:
    card = json.loads(archive.read("card.json"))
entries = {entry["name"]: entry["content"] for entry in card["data"]["character_book"]["entries"]}
assert entries["battleHistory.lua"] == (ROOT / "System" / "battleHistory.lua").read_text(encoding="utf-8")

print("history turn-start boundary check passed")
