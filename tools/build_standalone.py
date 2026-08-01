#!/usr/bin/env python3
"""Generate a standalone root main.lua from System/main.lua and System/*.lua."""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEM_DIR = ROOT / "System"
SOURCE_MAIN = SYSTEM_DIR / "main.lua"
OUTPUT_MAIN = ROOT / "main.lua"

LOAD_SCRIPT_START = "local function loadScriptLore(triggerId, script)"
LOAD_SCRIPT_END = "-- 배포 시 executable Lua lore"
REVISION_PATTERN = re.compile(
    r'(RUNTIME_BUNDLE_REVISION\s*=\s*RUNTIME_BUNDLE_REVISION\s*\n\s*or\s*)"[^"]+"'
)


def lua_long_string(source: str) -> str:
    """Return a Lua long-bracket string with a collision-free delimiter."""
    for equals_count in range(0, 32):
        equals = "=" * equals_count
        closing = f"]{equals}]"
        if closing not in source:
            return f"[{equals}[\n{source}\n]{equals}]"
    raise ValueError("could not find a safe Lua long-string delimiter")


def collect_modules() -> list[tuple[str, str]]:
    modules: list[tuple[str, str]] = []
    for path in sorted(SYSTEM_DIR.glob("*.lua"), key=lambda item: item.name):
        if path.name == "main.lua":
            continue

        source = path.read_text(encoding="utf-8")
        if not source.strip():
            raise ValueError(f"empty runtime module: {path.relative_to(ROOT)}")
        if not source.lstrip().startswith("("):
            raise ValueError(
                f"runtime module must remain a function expression: {path.relative_to(ROOT)}"
            )

        modules.append((path.stem, source.rstrip() + "\n"))

    if not modules:
        raise ValueError("no runtime modules found under System/")
    return modules


def replace_script_loader(main_source: str) -> str:
    start = main_source.find(LOAD_SCRIPT_START)
    if start < 0:
        raise ValueError("loadScriptLore start marker not found in System/main.lua")

    end = main_source.find(LOAD_SCRIPT_END, start)
    if end < 0:
        raise ValueError("loadScriptLore end marker not found in System/main.lua")

    replacement = """local function loadScriptLore(_triggerId, script)\n    return __HELLTRAIN_BUNDLED_SCRIPT_SOURCES[script]\nend\n\n"""
    return main_source[:start] + replacement + main_source[end:]


def build_output() -> str:
    main_source = SOURCE_MAIN.read_text(encoding="utf-8")
    modules = collect_modules()

    digest = hashlib.sha256()
    digest.update(main_source.encode("utf-8"))
    for module_name, module_source in modules:
        digest.update(b"\0")
        digest.update(module_name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(module_source.encode("utf-8"))
    revision = f"runtime-bundle-standalone-{digest.hexdigest()[:16]}"

    main_source = replace_script_loader(main_source)
    main_source, replacement_count = REVISION_PATTERN.subn(
        lambda match: match.group(1) + f'"{revision}"',
        main_source,
        count=1,
    )
    if replacement_count != 1:
        raise ValueError("RUNTIME_BUNDLE_REVISION assignment not found or ambiguous")

    bundle_lines = [
        "-- GENERATED FILE. DO NOT EDIT DIRECTLY.",
        "-- Sources: System/main.lua and every other System/*.lua runtime module.",
        "-- Executable Lua modules are embedded here, so runScript never reads *.lua lore entries.",
        f"-- Bundle revision: {revision}",
        "",
        "local __HELLTRAIN_BUNDLED_SCRIPT_SOURCES = {",
    ]
    for module_name, module_source in modules:
        bundle_lines.append(
            f"    [{lua_long_string(module_name)}] = {lua_long_string(module_source)},"
        )
    bundle_lines.extend(["}", "", main_source.rstrip(), ""])

    output = "\n".join(bundle_lines)
    if "getLoreBooks(triggerId, loreName)" in output:
        raise ValueError("generated main.lua still reads executable Lua lore entries")
    if "__HELLTRAIN_BUNDLED_SCRIPT_SOURCES[script]" not in output:
        raise ValueError("generated main.lua does not use the embedded module table")
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when root main.lua is missing or differs from generated output",
    )
    args = parser.parse_args()

    generated = build_output()
    if args.check:
        if not OUTPUT_MAIN.exists():
            raise SystemExit("main.lua is missing; run tools/build_standalone.py")
        current = OUTPUT_MAIN.read_text(encoding="utf-8")
        if current != generated:
            raise SystemExit("main.lua is stale; run tools/build_standalone.py")
        print("main.lua is up to date")
        return 0

    OUTPUT_MAIN.write_text(generated, encoding="utf-8", newline="\n")
    print(f"generated {OUTPUT_MAIN.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
