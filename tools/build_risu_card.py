#!/usr/bin/env python3
"""Build HellTrain in the same CHARX shape produced by RisuAI's native exporter."""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import struct
import sys
import time
import uuid
import zipfile
from pathlib import Path

JPEG_SOI = b"\xff\xd8"
JPEG_EOI = b"\xff\xd9"
ZIP_LOCAL = b"PK\x03\x04"
FOLDER_PREFIX = "\uf000folder:"
RPACK_MAP_B64 = (
    "xA0eC70rP1X8RW71ZlNPGuC7MJSGumu/QVBvm+/etxBhFyDfMomonW2ryZAA"
    "DF2v0sFW5RZkkYJldJfKI9ZS0f+0oOgvilg4WmAZlknb18g7PkNLpWNHqmop"
    "kvQVz2I0eNMdPOIFjipXDhvNTC3yQCwleUgPsnq1p2w35px7VH7+h9yaAuQz"
    "ouuxLgPdmaaw59WIGIN89r7hXJ/DIUYfCE7QdhJf7v2PROqjXosoCTWeacwK"
    "x4UHrUrzd+ln1NqEgJO2TXP6JyZ/BMb78XI5UcI2qWis+O3FucvOdaQ9gdlC"
    "cByVEbzYjJj5WaETxR9s+xxwOON8AGuWzEGJCI6uCz3hIvJZfu2n66zAy0B"
    "aXQf5KPs7lw0IZNKD2riYgKeIpz9PPxxx8atWWcFcG2KRBL6JIZfr9F6R87+"
    "UGPdUQZvGOBSqAmdVnNMuFNsw6AOGc8+DX4HMmhG6kj5mS6rpEkgXlU1OAy8"
    "07FYFnkoChrh8s3EOduiumBydn2V73/IwN43lL+1FIGSJUWs5/Vmpys2WsET"
    "40s66I2DG3wnsJpC64eq3FSOeCbSVynUt/gvj4l18EF3wh7/2BUR5QSXF/Mx"
    "0JsA18q0Tyo72bJr2l2hPzBhvZE9Tubfvk2CjB0jEJhk9IUze5BDu6mI8dal"
    "HPbMbrlbC5bt1enFywimgEA="
)
DEFAULT_SD_DATA = [
    ["always", "solo, 1girl"],
    ["negative", ""],
    ["|character's appearance", ""],
    ["current situation", ""],
    ["$character's pose", ""],
    ["$character's emotion", ""],
    ["current location", ""],
]
DEFAULT_NEW_GEN_DATA = {
    "prompt": "",
    "negative": "",
    "instructions": "",
    "emotionInstructions": "",
}
LORE_GROUPS = (
    ("DB", "DB", "*.db"),
    ("Chars", "Char", "*.db"),
    ("HTML", "html", "*.html"),
    ("System", "System", "*.lua"),
)
LORE_ORDER_HINTS = {
    "DB": [
        "CharacterCards.db",
        "CharTraits.db",
        "Environments.db",
        "GameRegistry.db",
        "PlayerCards.db",
        "TokyoSubwayLines.db",
    ],
    "Chars": [
        "CharacterList.db",
        "HanJenny.db",
        "SeoMiryeong.db",
        "SisterAgnes.db",
        "YooJiyoung.db",
        "YoonSeoa.db",
    ],
    "HTML": [
        "battleui.html",
        "battleui-interaction.html",
        "cardDraft.html",
        "characterSelect.html",
        "postBattle.html",
        "sideBar.html",
        "도감.html",
        "덱 확인.html",
        "설정.html",
        "캐릭터 리스트.html",
        "캐릭터 프로필.html",
        "플레이 가이드.html",
    ],
}


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


def ordered_paths(paths: list[Path], order_hint: list[str]) -> list[Path]:
    rank = {name: index for index, name in enumerate(order_hint)}
    return sorted(paths, key=lambda p: (rank.get(p.name, len(rank)), p.name))


def folder_id(label: str) -> str:
    token = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"https://github.com/ChatPoongKun/HellTrain/lore/{label}",
    )
    return FOLDER_PREFIX + str(token)


def make_runtime_lore(root: Path) -> list[dict]:
    entries: list[dict] = []
    for label, directory, pattern in LORE_GROUPS:
        folder = folder_id(label)
        entries.append(
            {
                "key": folder,
                "comment": label,
                "content": "",
                "mode": "folder",
                "insertorder": 100,
                "alwaysActive": False,
                "secondkey": "",
                "selective": False,
                "bookVersion": 2,
            }
        )
        paths = [p for p in (root / directory).glob(pattern) if p.is_file()]
        paths = ordered_paths(paths, LORE_ORDER_HINTS.get(label, []))
        if directory == "System":
            paths = [p for p in paths if p.name != "main.lua"]
        if not paths:
            raise BuildError(f"No lore sources found in {directory}/{pattern}")
        for path in paths:
            entries.append(
                {
                    "key": "",
                    "comment": path.name,
                    "content": read_text(path),
                    "mode": "normal",
                    "insertorder": 100,
                    "alwaysActive": False,
                    "secondkey": "",
                    "selective": False,
                    "folder": folder,
                    "useRegex": False,
                    "bookVersion": 2,
                }
            )
    return entries


def lore_to_character_book(lorebook: list[dict]) -> dict:
    entries: list[dict] = []
    for lore in lorebook:
        item = {
            "keys": [lore["key"]],
            "content": lore["content"],
            "extensions": {},
            "enabled": True,
            "insertion_order": lore["insertorder"],
            "constant": lore["alwaysActive"],
            "selective": lore["selective"],
            "name": lore["comment"],
            "comment": lore["comment"],
            "case_sensitive": False,
            "use_regex": lore.get("useRegex", False),
            "mode": lore["mode"],
        }
        if lore.get("folder"):
            item["folder"] = lore["folder"]
        entries.append(item)
    return {
        "extensions": {"risu_fullWordMatching": False},
        "entries": entries,
    }


def detect_image_type(raw: bytes) -> str:
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return "PNG"
    if raw.startswith(JPEG_SOI):
        return "JPEG"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "WEBP"
    if raw[4:12] in (b"ftypavif", b"ftypavis"):
        return "AVIF"
    return "Unknown"


def risu_lossy_image(raw: bytes) -> bytes:
    image_type = detect_image_type(raw)
    if image_type in ("Unknown", "WEBP", "AVIF"):
        return raw
    try:
        from PIL import Image
    except ImportError as exc:
        raise BuildError("Pillow is required for RisuAI-compatible image export") from exc
    with Image.open(io.BytesIO(raw)) as image:
        width, height = image.size
        if width > 3000 or height > 3000:
            if width > height:
                new_width = 3000
                new_height = round(new_width / (width / height))
            else:
                new_height = 3000
                new_width = round(new_height * (width / height))
            image = image.resize((new_width, new_height))
        if image.mode not in ("RGB", "RGBA"):
            image = image.convert("RGBA" if "A" in image.getbands() else "RGB")
        out = io.BytesIO()
        image.save(out, format="WEBP", quality=75)
        return out.getvalue()


def build_assets(
    root: Path,
    manifest: dict,
) -> tuple[list[dict], list[tuple[str, bytes]]]:
    icon_path = root / manifest.get("icon", "imgs/game_icon.png")
    if not icon_path.is_file():
        raise BuildError(f"Icon missing: {icon_path}")

    source_paths = [
        p for p in (root / "imgs").glob("*") if p.is_file() and p != icon_path
    ]
    source_paths = ordered_paths(source_paths, manifest.get("asset_order", []))
    records: list[dict] = []
    zip_members: list[tuple[str, bytes]] = []

    def add_image(name: str, original_ext: str, source: bytes, base_dir: str) -> None:
        image_type = detect_image_type(source)
        if image_type == "Unknown":
            raise BuildError(f"Unsupported image asset: {name}")
        compressed = risu_lossy_image(source)
        meta_path = f"x_meta/{name}.json"
        zip_members.append(
            (
                meta_path,
                json.dumps(
                    {"type": image_type},
                    separators=(",", ":"),
                ).encode("utf-8"),
            )
        )
        asset_path = f"{base_dir}/{name}.{original_ext}"
        zip_members.append((asset_path, compressed))

    for path in source_paths:
        ext = path.suffix.lower().lstrip(".")
        name = path.name
        asset_path = f"assets/other/image/{name}.{ext}"
        records.append(
            {
                "type": "x-risu-asset",
                "uri": f"embeded://{asset_path}",
                "name": name,
                "ext": ext,
            }
        )
        add_image(name, ext, path.read_bytes(), "assets/other/image")

    icon_ext = icon_path.suffix.lower().lstrip(".")
    icon_asset_path = f"assets/icon/image/main.{icon_ext}"
    records.append(
        {
            "type": "icon",
            "uri": f"embeded://{icon_asset_path}",
            "name": "main",
            "ext": icon_ext,
        }
    )
    add_image("main", icon_ext, icon_path.read_bytes(), "assets/icon/image")
    return records, zip_members


def rpack_maps() -> tuple[bytes, bytes]:
    data = base64.b64decode(RPACK_MAP_B64)
    if len(data) != 512:
        raise BuildError("Invalid embedded RPack map")
    return data[:256], data[256:]


def rpack_encode(raw: bytes) -> bytes:
    encode_map, _ = rpack_maps()
    return bytes(encode_map[b] for b in raw)


def rpack_decode(raw: bytes) -> bytes:
    _, decode_map = rpack_maps()
    return bytes(decode_map[b] for b in raw)


def build_module(name: str, main_lua: str, lorebook: list[dict]) -> bytes:
    module = {
        "name": f"{name} Module",
        "description": f"Module for {name}",
        "id": str(
            uuid.uuid5(
                uuid.NAMESPACE_URL,
                "https://github.com/ChatPoongKun/HellTrain/module",
            )
        ),
        "trigger": [
            {
                "comment": "",
                "type": "start",
                "conditions": [],
                "effect": [{"type": "triggerlua", "code": main_lua}],
                "lowLevelAccess": True,
            }
        ],
        "regex": [],
        "lorebook": lorebook,
        "assets": [],
    }
    main_json = json.dumps(
        {"module": module, "type": "risuModule"},
        ensure_ascii=False,
        indent=2,
    ).encode("utf-8")
    encoded = rpack_encode(main_json)
    return b"o\x00" + struct.pack("<I", len(encoded)) + encoded + b"\x00"


def parse_module(data: bytes) -> dict:
    if len(data) < 7 or data[:2] != b"o\x00":
        raise BuildError("module.risum magic/version mismatch")
    length = struct.unpack_from("<I", data, 2)[0]
    end = 6 + length
    if end >= len(data) or data[end:] != b"\x00":
        raise BuildError("module.risum framing mismatch")
    decoded = rpack_decode(data[6:end])
    payload = json.loads(decoded.decode("utf-8"))
    if payload.get("type") != "risuModule" or not isinstance(payload.get("module"), dict):
        raise BuildError("module.risum payload is invalid")
    return payload["module"]


def build_card(
    root: Path,
    manifest: dict,
) -> tuple[dict, bytes, list[tuple[str, bytes]]]:
    first_message = read_text(root / manifest.get("first_message", "Prompt/firstmsg.html"))
    main_lua = read_text(root / manifest.get("entry_script", "System/main.lua"))
    background_html = read_text(
        root / manifest.get("background_html", "html/embeddings.css")
    )
    lorebook = make_runtime_lore(root)

    required = set(manifest.get("required_lore", []))
    present = {
        item["comment"] for item in lorebook if item["mode"] != "folder"
    }
    missing = sorted(required - present)
    if missing:
        raise BuildError("Required lore missing: " + ", ".join(missing))

    assets, asset_members = build_assets(root, manifest)
    risu_extension = {
        "bias": [],
        "viewScreen": "none",
        "utilityBot": False,
        "sdData": DEFAULT_SD_DATA,
        "backgroundHTML": background_html,
        "additionalText": "",
        "virtualscript": "",
        "largePortrait": False,
        "lorePlus": False,
        "newGenData": DEFAULT_NEW_GEN_DATA,
        "vits": {},
        "lowLevelAccess": True,
        "defaultVariables": "",
        "prebuiltAssetCommand": "",
        "prebuiltAssetExclude": manifest.get("prebuilt_asset_exclude", []),
        "prebuiltAssetStyle": "",
        "toggles": "",
    }
    now = int(os.environ.get("SOURCE_DATE_EPOCH", str(int(time.time()))))
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
        "character_book": lore_to_character_book(lorebook),
        "tags": manifest.get("tags", []),
        "creator": manifest.get("creator", ""),
        "character_version": manifest.get("character_version", ""),
        "extensions": {
            "risuai": risu_extension,
            "depth_prompt": {"depth": 0, "prompt": ""},
        },
        "group_only_greetings": [],
        "nickname": "",
        "source": manifest.get("source", []),
        "creation_date": int(manifest.get("creation_date", 0)),
        "modification_date": now,
        "assets": assets,
    }
    card = {"spec": "chara_card_v3", "spec_version": "3.0", "data": data}
    module = build_module(manifest["name"], main_lua, lorebook)
    return card, module, asset_members


def write_zip_member(zf: zipfile.ZipFile, name: str, data: bytes) -> None:
    # Native RisuAI CharXWriter uses fflate DEFLATE level 0.
    info = zipfile.ZipInfo(name, date_time=time.localtime()[:6])
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 0
    info.external_attr = 0
    zf.writestr(
        info,
        data,
        compress_type=zipfile.ZIP_DEFLATED,
        compresslevel=0,
    )


def build_charx(
    card: dict,
    module: bytes,
    asset_members: list[tuple[str, bytes]],
) -> bytes:
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as zf:
        for name, payload in asset_members:
            write_zip_member(zf, name, payload)
        write_zip_member(zf, "module.risum", module)
        write_zip_member(
            zf,
            "card.json",
            json.dumps(card, ensure_ascii=False, indent=4).encode("utf-8"),
        )
    return stream.getvalue()


def load_hybrid_cover(root: Path, manifest: dict) -> bytes:
    icon = root / manifest.get("icon", "imgs/game_icon.png")
    raw = icon.read_bytes()
    try:
        from PIL import Image
    except ImportError as exc:
        raise BuildError("Pillow is required for JPEG hybrid export") from exc
    with Image.open(io.BytesIO(raw)) as image:
        image = image.convert("RGB")
        out = io.BytesIO()
        image.save(out, format="JPEG", quality=95)
        return out.getvalue()


def verify_archive(archive: bytes, *, jpeg_hybrid: bool) -> dict:
    payload = archive
    if jpeg_hybrid:
        if not archive.startswith(JPEG_SOI):
            raise BuildError("JPEG hybrid does not start with SOI")
        eoi = archive.find(JPEG_EOI)
        zip_start = archive.find(ZIP_LOCAL, eoi + 2)
        if eoi < 0 or zip_start < 0:
            raise BuildError("JPEG hybrid has no appended CHARX ZIP")
        payload = archive[zip_start:]
    elif not archive.startswith(ZIP_LOCAL):
        raise BuildError("CHARX does not start with a ZIP local header")

    with zipfile.ZipFile(io.BytesIO(payload), "r") as zf:
        bad = zf.testzip()
        if bad:
            raise BuildError(f"Corrupt CHARX ZIP member: {bad}")
        names = zf.namelist()
        if names[-2:] != ["module.risum", "card.json"]:
            raise BuildError("RisuAI CHARX tail must be module.risum then card.json")
        card = json.loads(zf.read("card.json"))
        if card.get("spec") != "chara_card_v3" or card.get("spec_version") != "3.0":
            raise BuildError("card.json is not Character Card V3")

        risu = card["data"]["extensions"]["risuai"]
        if risu.get("lowLevelAccess") is not True:
            raise BuildError("RisuAI low-level access flag is missing")
        if "triggerscript" in risu or "customScripts" in risu:
            raise BuildError(
                "Native CHARX stores trigger/regex payload in module.risum, not card.json"
            )
        if risu.get("backgroundHTML", "") == "":
            raise BuildError("RisuAI backgroundHTML embedding is missing")

        module = parse_module(zf.read("module.risum"))
        triggers = module.get("trigger", [])
        if (
            len(triggers) != 1
            or triggers[0].get("effect", [{}])[0].get("type") != "triggerlua"
            or triggers[0].get("lowLevelAccess") is not True
        ):
            raise BuildError("module.risum Lua trigger is missing")
        module_lore = module.get("lorebook", [])
        card_lore = card["data"]["character_book"]["entries"]
        if len(module_lore) != len(card_lore):
            raise BuildError("module/card lorebook entry count differs")
        if any(item.get("comment") == "main.lua" for item in module_lore):
            raise BuildError("System/main.lua must be trigger code, not a lore entry")

        assets = card["data"].get("assets", [])
        for asset in assets:
            uri = asset.get("uri", "")
            if not uri.startswith("embeded://") or uri[10:] not in names:
                raise BuildError(f"Embedded asset is missing: {uri}")
            if asset.get("type") == "icon":
                meta_name = "x_meta/main.json"
            else:
                meta_name = f"x_meta/{asset.get('name', '')}.json"
            if meta_name not in names:
                raise BuildError(f"RisuAI asset metadata is missing: {meta_name}")
        return card


def build(root: Path, manifest_path: Path, output_dir: Path) -> tuple[Path, Path]:
    manifest = load_manifest(manifest_path)
    card, module, asset_members = build_card(root, manifest)
    charx = build_charx(card, module, asset_members)
    hybrid = load_hybrid_cover(root, manifest) + charx

    verify_archive(charx, jpeg_hybrid=False)
    verify_archive(hybrid, jpeg_hybrid=True)

    output_dir.mkdir(parents=True, exist_ok=True)
    basename = manifest.get("output_basename", "HellTrain")
    charx_path = output_dir / f"{basename}.charx"
    jpg_path = output_dir / f"{basename}.jpg"
    charx_path.write_bytes(charx)
    jpg_path.write_bytes(hybrid)
    return charx_path, jpg_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    root = args.root.resolve()
    manifest = (args.manifest or root / "card" / "manifest.json").resolve()
    output = (args.output or root / "dist").resolve()
    try:
        charx, jpg = build(root, manifest, output)
    except (
        BuildError,
        KeyError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        zipfile.BadZipFile,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"built {charx}")
    print(f"built {jpg}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
