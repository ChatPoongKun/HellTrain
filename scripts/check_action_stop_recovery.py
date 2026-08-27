#!/usr/bin/env python3
"""Regression checks for conditional-card action-stop recovery."""

import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


cards = source("DB/PlayerCards.db")
presentation = source("System/turnPresentation.lua")
draft = source("System/turnDraft.lua")
view = source("System/viewBuilder.lua")
runtime = source("System/battleRuntime.lua")

assert 'return false, "requires_negative_mood"' in cards
assert 'requires_negative_mood = "현재 무드가 의심 또는 거절이 아니어서"' in presentation
assert 'reason = reason or "카드 사용 조건을 만족하지 못해"' in presentation
assert "or not isAsciiId(payload.reasonCode)" in presentation

register = draft[draft.index("    local function registerValidated") : draft.index("    local function cancelValidated")]
assert register.index('"evaluateCanPlay"') < register.index("targetCard.effectChoices")

hand = view[view.index("        local handItems = {}") : view.index("        local mainActionCount = 0")]
assert hand.index('"evaluateCanPlay"') < hand.index("displayState.player.stealth <= finalStealthCost")
assert '"evaluateEffectChoice"' in hand and hand.count("cardContext") >= 3

pending_validation = runtime[
    runtime.index("    local function validateStoredPending") : runtime.index("    local function preparePending")
]
assert pending_validation.index('"turnPresentation"') < pending_validation.index("return pendingCopy, nil")

bundle = ROOT / "build" / "HellTrain.charx"
with zipfile.ZipFile(bundle) as archive:
    card = json.loads(archive.read("card.json"))
entries = {entry["name"]: entry["content"] for entry in card["data"]["character_book"]["entries"]}
for name in ("battleRuntime.lua", "turnDraft.lua", "turnPresentation.lua", "viewBuilder.lua"):
    assert entries[name] == source(f"System/{name}"), f"stale bundle entry: {name}"

print("action-stop recovery check passed")
