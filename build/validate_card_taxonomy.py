#!/usr/bin/env python3
"""Validate the card type/role contract directly from the two Lua card databases."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAYER_ROLES = {"pressure", "deception", "violation"}
CHARACTER_ROLES = {"response", "exposure", "recovery"}
SPECIALS = {"remove", "insight"}


def validate_runtime_type_contract(errors: list[str]) -> None:
    stale_patterns = {
        "plan/chain mechanism helper call": re.compile(
            r'\b(?:cardHasMechanism|hasMechanism)\s*\([^)]*["\'](?:plan|chain)["\']',
            re.S,
        ),
        "plan/chain mechanism comparison": re.compile(
            r'\b(?:mechanism|mechanismId|currentId)\s*==\s*["\'](?:plan|chain)["\']'
        ),
    }
    for path in (ROOT / "System").glob("*.lua"):
        text = path.read_text(encoding="utf-8")
        for label, pattern in stale_patterns.items():
            if pattern.search(text):
                errors.append(f"{path.relative_to(ROOT)}: stale {label}")

    required_checks = {
        "System/stateSchema.lua": {
            'card.cardType ~= "plan"': 1,
            'card.cardType == "plan"': 1,
            'card.cardType ~= "chain"': 2,
        },
        "System/viewBuilder.lua": {'item.cardType.id == "chain"': 1},
    }
    for relative_path, snippets in required_checks.items():
        text = (ROOT / relative_path).read_text(encoding="utf-8")
        for snippet, minimum in snippets.items():
            count = text.count(snippet)
            if count < minimum:
                errors.append(
                    f"{relative_path}: expected at least {minimum} cardType checks for {snippet}, found {count}"
                )


def card_blocks(path: Path, id_pattern: str) -> list[tuple[str, str, str]]:
    text = path.read_text(encoding="utf-8")
    starts = list(re.finditer(rf"(?m)^\s+({id_pattern})\s*=\s*(card|planCard)\(", text))
    blocks = []
    for index, match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        blocks.append((match.group(1), match.group(2), text[match.end():end]))
    return blocks


def quoted_ids(value: str) -> list[str]:
    return re.findall(r'"([a-z][a-z0-9_]*)"', value)


def player_header(block: str, constructor: str) -> tuple[list[str], str, list[str]]:
    if constructor == "planCard":
        match = re.match(r'\s*"[^"]+",\s*"[^"]+",\s*(\{[^}]+\}|"[^"]+")', block, re.S)
        return (quoted_ids(match.group(1)) if match else [], "plan", [])
    match = re.match(
        r'\s*"[^"]+",\s*"[^"]+",\s*(\{[^}]+\}|"[^"]+")\s*,\s*\d+\s*,\s*(\d+)\s*,\s*(\{[^}]*\})',
        block,
        re.S,
    )
    if not match:
        return [], "invalid", []
    mechanisms = quoted_ids(match.group(3))
    card_type = "chain" if "chain" in mechanisms else "action"
    return quoted_ids(match.group(1)), card_type, [item for item in mechanisms if item != "chain"]


def character_header(block: str, constructor: str) -> tuple[list[str], str, list[str]]:
    if constructor == "planCard":
        match = re.match(r'\s*"[^"]+",\s*"[^"]+",\s*"([^"]+)"', block, re.S)
        return ([match.group(1)] if match else [], "plan", [])
    match = re.match(r'\s*"[^"]+",\s*"[^"]+",\s*"([^"]+)"\s*,\s*(\{[^}]*\})', block, re.S)
    if not match:
        return [], "invalid", []
    mechanisms = quoted_ids(match.group(2))
    return [match.group(1)], "chain" if "chain" in mechanisms else "action", [item for item in mechanisms if item != "chain"]


def player_effect_roles(block: str, base_damage: int) -> set[str]:
    roles = set()
    if base_damage > 0 or re.search(r"\bdamage\(", block):
        roles.add("violation")
    if re.search(r"\brecoverStealth\(", block):
        roles.add("deception")
    if re.search(r"\b(?:addMood|removeMood|forceMood|manipulate|backlash|calm|cool)\(", block):
        roles.add("pressure")
    return roles


def character_effect_roles(block: str) -> set[str]:
    roles = set()
    if re.search(r"\brecoverResistance\(", block):
        roles.add("recovery")
    if re.search(r"\bloseStealth\(", block):
        roles.add("exposure")
    if re.search(r"\b(?:addMood|removeMood|forceMood|manipulate|backlash|calm|cool)\(", block):
        roles.add("response")
    return roles


def response_strength(block: str) -> int | None:
    if re.search(r"\bforceMood\(", block):
        return None
    amounts = [int(value) for value in re.findall(r"\b(?:manipulate|backlash|calm|cool)\(context,\s*(\d+)", block)]
    amounts += [int(value) for value in re.findall(r"\b(?:addMood|removeMood)\([^,]+,\s*(\d+)", block)]
    return sum(amounts)


def main() -> int:
    errors: list[str] = []
    validate_runtime_type_contract(errors)
    player = card_blocks(ROOT / "DB" / "PlayerCards.db", r"p\d+_[a-z0-9_]+")
    character = card_blocks(ROOT / "DB" / "CharacterCards.db", r"[a-z][a-z0-9_]+")
    if len(player) != 34 or len(character) != 50:
        errors.append(f"card count mismatch: player={len(player)}, character={len(character)}")

    for card_id, constructor, block in player:
        roles, card_type, specials = player_header(block, constructor)
        damage_match = re.match(
            r'\s*"[^"]+",\s*"[^"]+",\s*(?:\{[^}]+\}|"[^"]+")\s*,\s*\d+\s*,\s*(\d+)',
            block,
            re.S,
        )
        base_damage = int(damage_match.group(1)) if damage_match and constructor == "card" else 0
        detected = player_effect_roles(block, base_damage)
        if not (1 <= len(roles) <= 2) or len(set(roles)) != len(roles) or not set(roles) <= PLAYER_ROLES:
            errors.append(f"{card_id}: invalid player roles {roles}")
        if set(roles) != detected:
            errors.append(f"{card_id}: declared roles {roles} != effect roles {sorted(detected)}")
        if card_type not in {"action", "chain", "plan"} or not set(specials) <= SPECIALS:
            errors.append(f"{card_id}: invalid type/specials {card_type}/{specials}")

    for card_id, constructor, block in character:
        roles, card_type, specials = character_header(block, constructor)
        detected = character_effect_roles(block)
        if len(roles) != 1 or roles[0] not in CHARACTER_ROLES:
            errors.append(f"{card_id}: invalid character roles {roles}")
        if set(roles) != detected:
            errors.append(f"{card_id}: declared role {roles} != effect role {sorted(detected)}")
        if roles == ["response"]:
            strength = response_strength(block)
            if strength is not None and strength < 3:
                errors.append(f"{card_id}: response mood strength is {strength}, expected at least 3")
        if card_type not in {"action", "chain", "plan"} or not set(specials) <= SPECIALS:
            errors.append(f"{card_id}: invalid type/specials {card_type}/{specials}")

    if errors:
        print("card taxonomy validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"validated {len(player) + len(character)} cards: {len(player)} player, {len(character)} character")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
