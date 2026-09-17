#!/usr/bin/env python3
"""Small regression check for RisuAI error-response rerolls."""

from copy import deepcopy
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CONTROLLER = (ROOT / "System" / "battleController.lua").read_text(encoding="utf-8")
HOST_FLOW = (ROOT / "System" / "hostFlow.lua").read_text(encoding="utf-8")
MARKER = "@@HELLTRAIN_TURN_SUBMIT_V1@@"
ERROR = "```risuerror\nrequest failed\n```"


def inlay_error(chat):
    if chat and chat[-1]["role"] == "char":
        chat[-1]["data"] += "\n" + ERROR
    else:
        chat.append({"role": "char", "data": ERROR, "saying": "hero"})


def risu_reroll(chat):
    result = deepcopy(chat)
    saying = result[-1].get("saying")
    same_speaker_limit = 2
    while result[-1]["role"] != "user":
        if result[-1].get("saying") == saying:
            same_speaker_limit -= 1
            if same_speaker_limit == 0:
                break
        result.pop()
        if not result:
            return result
    return result


previous = [
    {"role": "char", "data": "approach scene"},
]

unsafe = deepcopy(previous)
unsafe.append({"role": "char", "data": "censored", "saying": "hero"})
assert risu_reroll(unsafe) == [], "the first-turn regression must exhaust the chat"

safe = deepcopy(previous) + [{"role": "user", "data": MARKER}]
safe.append({"role": "char", "data": "censored", "saying": "hero"})
assert risu_reroll(safe) == previous + [{"role": "user", "data": MARKER}]

successful = deepcopy(previous) + [
    {"role": "user", "data": MARKER},
    {"role": "char", "data": "turn two", "saying": "hero"},
]
assert risu_reroll(successful) == previous + [{"role": "user", "data": MARKER}]

prepare_start = CONTROLLER.index("    local function prepareGeneration()")
prepare = CONTROLLER[prepare_start:]
assert "while logicalLength > 0 and isExactSayNothing" in CONTROLLER
assert "or not isExactSayNothing(last) then" in CONTROLLER
locked_request = prepare.index('storedBinding.phase == "inFlight"')
recover_locked = prepare.index("return recoverLockedRequest", locked_request)
cleanup_after_locked = prepare.index(
    "chat, removedCount, chatErrors = removeTrailingSayNothing(chat)", recover_locked
)
assert locked_request < recover_locked < cleanup_after_locked
assert prepare.index("chat, markerAdded, boundaryErrors = ensureTurnBoundary(chat)") < prepare.index(
    "local chatAnchor, anchorErrors = createPlannedChatAnchor(chat)"
)
assert 'makeError("battle_output_error"' in CONTROLLER
assert "removeSuccessfulTurnBoundary" not in CONTROLLER
retry = CONTROLLER[CONTROLLER.index("    local function retryCommittedOutput") : prepare_start]
assert "ensureTurnBoundary(repairedChat)" in retry
assert "nextBinding.chatAnchor = anchor" in retry
assert "uiTargetIndex = committedBinding.chatAnchor.responseIndex" in CONTROLLER
assert "if data == TURN_SUBMIT_MARKER then" in HOST_FLOW

print("reroll recovery check passed")
