#!/usr/bin/env python3
"""Build HellTrain as a RisuAI Character Card V3 archive and JPEG hybrid."""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import zipfile
from pathlib import Path
from typing import Iterable

FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
JPEG_SOI = b"\xff\xd8"
JPEG_EOI = b"\xff\xd9"
ZIP_LOCAL = b"PK\x03\x04"


class BuildError(RuntimeError):
    pass


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError(f"UTF-8 text required: {path}") from exc


def load_manifest(path: Path) -> dict:
    try:
        data = json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise BuildError(f"Invalid JSON manifest {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise BuildError("Manifest root must be a JSON object")
    return data


def iter_globs(root: Path, patterns: Iterable[str]) -> list[Path]:
    found: dict[str, Path] = {}
    for pattern in patterns:
        matches = [p for p in root.glob(pattern) if p.is_file()]
        if not matches:
            raise BuildError(f"Manifest glob matched no files: {pattern}")
        for path in matches:
            rel = path.relative_to(root).as_posix()
            found[rel] = path
    return [found[key] for key in sorted(found)]


def ensure_unique(items: Iterable[tuple[str, Path]], label: str) -> None:
    seen: dict[str, Path] = {}
    for key, path in items:
        if key in seen:
            raise BuildError(
                f"Duplicate {label} '{key}': {seen[key].as_posix()} and {path.as_posix()}"
            )
        seen[key] = path


def make_lore_entries(root: Path, manifest: dict) -> list[dict]:
    paths = iter_globs(root, manifest["lore_globs"])
    ensure_unique(((p.name, p) for p in paths), "lore name")

    entries: list[dict] = []
    for order, path in enumerate(paths, start=1):
        rel = path.relative_to(root).as_posix()
        name = path.name
        entries.append(
            {
                "keys": [f"__helltrain_runtime_asset__/{rel}"],
                "secondary_keys": [],
                "content": read_text(path),
                "extensions": {"risu_case_sensitive": True},
                "enabled": True,
                "insertion_order": order,
                "constant": False,
                "selective": False,
                "name": name,
                "comment": name,
                "case_sensitive": True,
                "mode": "normal",
            }
        )

    required = set(manifest.get("required_lore", []))
    present = {entry["name"] for entry in entries}
    missing = sorted(required - present)
    if missing:
        raise BuildError("Required lore missing: " + ", ".join(missing))
    return entries


def make_asset_records(root: Path, manifest: dict) -> tuple[list[dict], list[tuple[str, bytes]]]:
    records: list[dict] = []
    payloads: list[tuple[str, bytes]] = []

    cover_path = root / manifest["cover"]
    cover = cover_path.read_bytes()
    if not cover.startswith(JPEG_SOI) or JPEG_EOI not in cover:
        raise BuildError(f"Cover must be a JPEG file: {cover_path}")

    cover_arc = "assets/icon/cover.jpg"
    records.append(
        {
            "type": "icon",
            "uri": f"embeded://{cover_arc}",
            "name": "main",
            "ext": "jpg",
        }
    )
    payloads.append((cover_arc, cover))

    asset_paths = iter_globs(root, manifest.get("asset_globs", []))
    ensure_unique(((p.stem, p) for p in asset_paths), "asset name")
    for path in asset_paths:
        name = path.stem
        ext = path.suffix.lower().lstrip(".") or "bin"
        arc = f"assets/x-risu-asset/{path.name}"
        records.append(
            {
                "type": "x-risu-asset",
                "uri": f"embeded://{arc}",
                "name": name,
                "ext": ext,
            }
        )
        payloads.append((arc, path.read_bytes()))

    return records, payloads


def build_card(root: Path, manifest: dict) -> tuple[dict, list[tuple[str, bytes]], bytes]:
    first_message_path = root / manifest["first_message"]
    main_lua_path = root / manifest.get("entry_script", "System/main.lua")
    first_message = read_text(first_message_path)
    main_lua = read_text(main_lua_path)
    if not main_lua.strip():
        raise BuildError(f"Entry script is empty: {main_lua_path}")

    lore_entries = make_lore_entries(root, manifest)
    assets, payloads = make_asset_records(root, manifest)

    risu_extension = {
        "lowLevelAccess": True,
        "triggerscript": [
            {
                "comment": manifest.get("trigger_name", "HellTrain Runtime"),
                "type": "start",
                "conditions": [],
                "effect": [{"type": "triggerlua", "code": main_lua}],
                "lowLevelAccess": True,
            }
        ],
        "defaultVariables": manifest.get("default_variables", ""),
        "additionalText": manifest.get("additional_text", ""),
    }

    version = os.environ.get("HELLTRAIN_CARD_VERSION", manifest.get("character_version", ""))
    if len(version) > 12 and all(ch in "0123456789abcdefABCDEF" for ch in version):
        version = version[:12]

    data = {
        "name": manifest["name"],
        "description": manifest.get("description", ""),
        "personality": manifest.get("personality", ""),
        "scenario": manifest.get("scenario", ""),
        "first_mes": first_message,
        "mes_example": manifest.get("mes_example", ""),
        "creator_notes": manifest.get("creator_notes", ""),
        "system_prompt": manifest.get("system_prompt", ""),
        "post_history_instructions": manifest.get("post_history_instructions", ""),
        "alternate_greetings": manifest.get("alternate_greetings", []),
        "tags": manifest.get("tags", []),
        "creator": manifest.get("creator", ""),
        "character_version": version,
        "source": manifest.get("source", []),
        "character_book": {
            "name": f"{manifest['name']} Runtime",
            "description": "Runtime source files packed as non-activating RisuAI lore entries.",
            "scan_depth": 1,
            "token_budget": 1,
            "recursive_scanning": False,
            "extensions": {},
            "entries": lore_entries,
        },
        "assets": assets,
        "extensions": {"risuai": risu_extension},
    }

    card = {"spec": "chara_card_v3", "spec_version": "3.0", "data": data}
    cover = (root / manifest["cover"]).read_bytes()
    return card, payloads, cover


def deterministic_zip(card: dict, payloads: list[tuple[str, bytes]]) -> bytes:
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        write_zip_member(
            zf,
            "card.json",
            json.dumps(card, ensure_ascii=False, indent=2, sort_keys=False).encode("utf-8") + b"\n",
        )
        for arcname, payload in sorted(payloads, key=lambda item: item[0]):
            write_zip_member(zf, arcname, payload)
    return stream.getvalue()


def write_zip_member(zf: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def verify_archive(archive: bytes, *, jpeg_hybrid: bool) -> dict:
    payload = archive
    if jpeg_hybrid:
        if not archive.startswith(JPEG_SOI):
            raise BuildError("JPEG hybrid does not start with SOI")
        eoi = archive.find(JPEG_EOI)
        if eoi < 0:
            raise BuildError("JPEG hybrid has no EOI marker")
        zip_start = archive.find(ZIP_LOCAL, eoi + 2)
        if zip_start < 0:
            raise BuildError("JPEG hybrid has no appended ZIP payload")
        payload = archive[zip_start:]
    elif not archive.startswith(ZIP_LOCAL):
        raise BuildError("CHARX does not start with a ZIP local header")

    with zipfile.ZipFile(io.BytesIO(payload), "r") as zf:
        bad = zf.testzip()
        if bad:
            raise BuildError(f"Corrupt ZIP member: {bad}")
        names = set(zf.namelist())
        if "card.json" not in names:
            raise BuildError("card.json missing from archive")
        card = json.loads(zf.read("card.json").decode("utf-8"))
        if card.get("spec") != "chara_card_v3" or card.get("spec_version") != "3.0":
            raise BuildError("card.json is not Character Card V3")
        risu = card.get("data", {}).get("extensions", {}).get("risuai", {})
        if risu.get("lowLevelAccess") is not True:
            raise BuildError("RisuAI low-level access flag is missing")
        triggers = risu.get("triggerscript", [])
        if len(triggers) != 1 or triggers[0].get("effect", [{}])[0].get("type") != "triggerlua":
            raise BuildError("RisuAI Lua trigger is missing")
        return card


def build(root: Path, manifest_path: Path, output_dir: Path) -> tuple[Path, Path]:
    manifest = load_manifest(manifest_path)
    card, payloads, cover = build_card(root, manifest)
    charx = deterministic_zip(card, payloads)
    hybrid = cover + charx

    verify_archive(charx, jpeg_hybrid=False)
    verify_archive(hybrid, jpeg_hybrid=True)

    output_dir.mkdir(parents=True, exist_ok=True)
    basename = manifest.get("output_basename", manifest["name"])
    charx_path = output_dir / f"{basename}.charx"
    jpeg_path = output_dir / f"{basename}.jpg"
    charx_path.write_bytes(charx)
    jpeg_path.write_bytes(hybrid)
    return charx_path, jpeg_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--output", type=Path, default=None)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    root = args.root.resolve()
    manifest = (args.manifest or (root / "card" / "manifest.json")).resolve()
    output = (args.output or (root / "dist")).resolve()
    try:
        charx, jpeg = build(root, manifest, output)
    except (BuildError, KeyError, OSError, zipfile.BadZipFile) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"built {charx.relative_to(root) if charx.is_relative_to(root) else charx}")
    print(f"built {jpeg.relative_to(root) if jpeg.is_relative_to(root) else jpeg}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
