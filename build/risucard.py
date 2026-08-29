#!/usr/bin/env python3
"""Build HellTrain as a RisuAI-compatible Character Card V3."""

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
FOLDER_PREFIX = "\uf000folder:"

RPACK_MAP_B64 = (
    "xA0eC70rP1X8RW71ZlNPGuC7MJSGumu/QVBvm+/etxBhFyDfMomonW2ryZAA"
    "DF2v0sFW5RZkkYJldJfKI9ZS0f+0oOgvilg4WmAZlknb18g7PkNLpWNHqmop"
    "kvQVz2I0eNMdPOIFjipXDhvNTC3yQCwleUgPsnq1p2w35px7VH7+h9yaAuQz"
    "ouuxLgPdmaaw59WIGIN89r7hXJ/DIUYfCE7QdhJf7v2PROqjXosoCTWeacwK"
    "x4UHrUrzd+ln1NqEgJO2TXP6JyZ/BMb78XI5UcI2qWis+O3FucvOdaQ9gdlC"
    "cByVEbzYjJj5WaET9xR9s+xxwOON8AGuWzEGJCI6uCz3hIvJZfu2n66zAy0B"
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
GROUPS = (
    ("DB", "DB", "*.db"),
    ("Chars", "Char", "*.db"),
    ("HTML", "html", "*.html"),
    ("System", "System", "*.lua"),
)
ORDER = {
    "DB": [
        "CharacterCards.db", "CharTraits.db",
        "GameRegistry.db", "PlayerCards.db", "TokyoSubwayLines.db",
    ],
    "Chars": [
        "CharacterList.db", "HanJenny.db", "SeoMiryeong.db",
        "SisterAgnes.db", "YooJiyoung.db", "YoonSeoa.db",
    ],
    "HTML": [
        "battleui.html", "battleui-interaction.html", "cardDraft.html",
        "characterSelect.html", "postBattle.html", "sideBar.html",
        "도감.html", "덱 확인.html", "설정.html", "캐릭터 리스트.html",
        "캐릭터 프로필.html", "플레이 가이드.html",
    ],
}


class BuildError(RuntimeError):
    pass


class RPackError(ValueError):
    pass


def _rpack_maps() -> tuple[bytes, bytes]:
    data = base64.b64decode(RPACK_MAP_B64)
    if len(data) != 512:
        raise RPackError("invalid RPack map")
    return data[:256], data[256:]


def rpack_encode(data: bytes) -> bytes:
    enc, _ = _rpack_maps()
    return bytes(enc[b] for b in data)


def rpack_decode(data: bytes) -> bytes:
    _, dec = _rpack_maps()
    return bytes(dec[b] for b in data)


def pack_module(module: dict) -> bytes:
    raw = json.dumps(
        {"module": module, "type": "risuModule"},
        ensure_ascii=False,
        indent=2,
    ).encode("utf-8")
    payload = rpack_encode(raw)
    return b"o\x00" + struct.pack("<I", len(payload)) + payload + b"\x00"


def unpack_module(data: bytes) -> dict:
    if len(data) < 7 or data[:2] != b"o\x00":
        raise RPackError("invalid module magic/version")
    length = struct.unpack_from("<I", data, 2)[0]
    end = 6 + length
    if end >= len(data) or data[end:] != b"\x00":
        raise RPackError("invalid module framing")
    obj = json.loads(rpack_decode(data[6:end]).decode("utf-8"))
    if obj.get("type") != "risuModule" or not isinstance(obj.get("module"), dict):
        raise RPackError("invalid module payload")
    return obj["module"]


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError(f"UTF-8 text required: {path}") from exc


def load_metadata(path: Path) -> dict:
    try:
        value = json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise BuildError(f"invalid card metadata: {exc}") from exc
    if not isinstance(value, dict):
        raise BuildError("card metadata root must be an object")
    return value


def ordered(paths: list[Path], names: list[str]) -> list[Path]:
    rank = {name: i for i, name in enumerate(names)}
    return sorted(paths, key=lambda p: (rank.get(p.name, len(rank)), p.name))


def folder_key(label: str) -> str:
    value = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"https://github.com/ChatPoongKun/HellTrain/lore/{label}",
    )
    return FOLDER_PREFIX + str(value)


def runtime_lore(root: Path) -> list[dict]:
    result: list[dict] = []
    for label, directory, pattern in GROUPS:
        folder = folder_key(label)
        result.append({
            "key": folder,
            "comment": label,
            "content": "",
            "mode": "folder",
            "insertorder": 100,
            "alwaysActive": False,
            "secondkey": "",
            "selective": False,
            "bookVersion": 2,
        })
        paths = [p for p in (root / directory).glob(pattern) if p.is_file()]
        paths = ordered(paths, ORDER.get(label, []))
        if directory == "System":
            paths = [p for p in paths if p.name != "main.lua"]
        if not paths:
            raise BuildError(f"no sources found in {directory}/{pattern}")
        for path in paths:
            result.append({
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
            })
    return result


def character_book(lores: list[dict]) -> dict:
    entries: list[dict] = []
    for lore in lores:
        entry = {
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
            entry["folder"] = lore["folder"]
        entries.append(entry)
    return {"extensions": {"risu_fullWordMatching": False}, "entries": entries}


def image_type(raw: bytes) -> str:
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return "PNG"
    if raw.startswith(JPEG_SOI):
        return "JPEG"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "WEBP"
    if raw[4:12] in (b"ftypavif", b"ftypavis"):
        return "AVIF"
    return "Unknown"


def compress_image(raw: bytes) -> bytes:
    kind = image_type(raw)
    if kind in ("WEBP", "AVIF", "Unknown"):
        return raw
    try:
        from PIL import Image
    except ImportError as exc:
        raise BuildError("Pillow is required") from exc
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
        output = io.BytesIO()
        image.save(output, format="WEBP", quality=75)
        return output.getvalue()


def build_assets(root: Path, cfg: dict) -> tuple[list[dict], list[tuple[str, bytes]]]:
    icon = root / cfg.get("icon", "imgs/game_icon.png")
    if not icon.is_file():
        raise BuildError(f"missing icon: {icon}")

    paths = [p for p in (root / "imgs").glob("*") if p.is_file() and p != icon]
    paths = ordered(paths, cfg.get("asset_order", []))
    records: list[dict] = []
    members: list[tuple[str, bytes]] = []

    def add(name: str, ext: str, source: bytes, directory: str) -> None:
        kind = image_type(source)
        if kind == "Unknown":
            raise BuildError(f"unsupported image: {name}")
        members.append((
            f"x_meta/{name}.json",
            json.dumps({"type": kind}, separators=(",", ":")).encode("utf-8"),
        ))
        members.append((f"{directory}/{name}.{ext}", compress_image(source)))

    for path in paths:
        ext = path.suffix.lower().lstrip(".")
        name = path.name
        uri = f"assets/other/image/{name}.{ext}"
        records.append({
            "type": "x-risu-asset",
            "uri": "embeded://" + uri,
            "name": name,
            "ext": ext,
        })
        add(name, ext, path.read_bytes(), "assets/other/image")

    icon_ext = icon.suffix.lower().lstrip(".")
    records.append({
        "type": "icon",
        "uri": f"embeded://assets/icon/image/main.{icon_ext}",
        "name": "main",
        "ext": icon_ext,
    })
    add("main", icon_ext, icon.read_bytes(), "assets/icon/image")
    return records, members


def build_module(cfg: dict, main_lua: str, lores: list[dict]) -> bytes:
    module_cfg = cfg.get("module", {})
    if not isinstance(module_cfg, dict):
        raise BuildError("module metadata must be an object")
    module_id = module_cfg.get("id") or str(uuid.uuid5(
        uuid.NAMESPACE_URL,
        "https://github.com/ChatPoongKun/HellTrain/module",
    ))
    module = {
        "name": module_cfg.get("name") or f"{cfg['name']} Module",
        "description": module_cfg.get("description") or f"Module for {cfg['name']}",
        "id": module_id,
        "trigger": [{
            "comment": module_cfg.get("trigger_comment", ""),
            "type": "start",
            "conditions": [],
            "effect": [{"type": "triggerlua", "code": main_lua}],
            "lowLevelAccess": True,
        }],
        "regex": module_cfg.get("regex", []),
        "lorebook": lores,
        "assets": [],
    }
    return pack_module(module)


def risu_metadata(root: Path, cfg: dict) -> dict:
    manual = cfg.get("risuai", {})
    if not isinstance(manual, dict):
        raise BuildError("risuai metadata must be an object")
    return {
        "bias": manual.get("bias", []),
        "viewScreen": manual.get("viewScreen", "none"),
        "utilityBot": manual.get("utilityBot", False),
        "sdData": manual.get("sdData", DEFAULT_SD_DATA),
        "backgroundHTML": read_text(root / cfg.get("background_html", "html/embeddings.css")),
        "additionalText": manual.get("additionalText", ""),
        "virtualscript": "",
        "largePortrait": manual.get("largePortrait", False),
        "lorePlus": manual.get("lorePlus", False),
        "newGenData": manual.get("newGenData", DEFAULT_NEW_GEN_DATA),
        "vits": manual.get("vits", {}),
        "lowLevelAccess": True,
        "defaultVariables": manual.get("defaultVariables", ""),
        "prebuiltAssetCommand": manual.get("prebuiltAssetCommand", ""),
        "prebuiltAssetExclude": manual.get(
            "prebuiltAssetExclude", cfg.get("prebuilt_asset_exclude", [])
        ),
        "prebuiltAssetStyle": manual.get("prebuiltAssetStyle", ""),
        "toggles": manual.get("toggles", ""),
    }


def card_payload(root: Path, cfg: dict) -> tuple[dict, bytes, list[tuple[str, bytes]]]:
    lores = runtime_lore(root)
    required = set(cfg.get("required_lore", []))
    present = {x["comment"] for x in lores if x["mode"] != "folder"}
    missing = sorted(required - present)
    if missing:
        raise BuildError("required lore missing: " + ", ".join(missing))

    asset_records, asset_members = build_assets(root, cfg)
    modification_date = cfg.get("modification_date")
    if modification_date in (None, ""):
        modification_date = int(os.environ.get("SOURCE_DATE_EPOCH", str(int(time.time()))))

    data = {
        "name": cfg["name"],
        "description": cfg.get("description", ""),
        "personality": cfg.get("personality", ""),
        "scenario": cfg.get("scenario", ""),
        "first_mes": read_text(root / cfg.get("first_message", "Prompt/firstmsg.html")),
        "mes_example": cfg.get("mes_example", ""),
        "creator_notes": cfg.get("creator_notes", ""),
        "system_prompt": cfg.get("system_prompt", ""),
        "post_history_instructions": cfg.get("post_history_instructions", ""),
        "alternate_greetings": cfg.get("alternate_greetings", []),
        "character_book": character_book(lores),
        "tags": cfg.get("tags", []),
        "creator": cfg.get("creator", ""),
        "character_version": cfg.get("character_version", ""),
        "extensions": {
            "risuai": risu_metadata(root, cfg),
            "depth_prompt": cfg.get("depth_prompt", {"depth": 0, "prompt": ""}),
        },
        "group_only_greetings": cfg.get("group_only_greetings", []),
        "nickname": cfg.get("nickname", ""),
        "source": cfg.get("source", []),
        "creation_date": int(cfg.get("creation_date", 0)),
        "modification_date": int(modification_date),
        "assets": asset_records,
    }
    card = {"spec": "chara_card_v3", "spec_version": "3.0", "data": data}
    main_lua = read_text(root / cfg.get("entry_script", "System/main.lua"))
    return card, build_module(cfg, main_lua, lores), asset_members


def write_member(zf: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=time.localtime()[:6])
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 0
    zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=0)


def make_charx(card: dict, module: bytes, members: list[tuple[str, bytes]]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as zf:
        for name, data in members:
            write_member(zf, name, data)
        write_member(zf, "module.risum", module)
        write_member(
            zf,
            "card.json",
            json.dumps(card, ensure_ascii=False, indent=4).encode("utf-8"),
        )
    return output.getvalue()


def verify(raw: bytes) -> None:
    with zipfile.ZipFile(io.BytesIO(raw), "r") as zf:
        if zf.testzip():
            raise BuildError("corrupt CHARX")
        names = zf.namelist()
        if names[-2:] != ["module.risum", "card.json"]:
            raise BuildError("CHARX tail differs from RisuAI export")
        card = json.loads(zf.read("card.json"))
        if card.get("spec") != "chara_card_v3" or card.get("spec_version") != "3.0":
            raise BuildError("not Character Card V3")
        risu = card["data"]["extensions"]["risuai"]
        if risu.get("lowLevelAccess") is not True or not risu.get("backgroundHTML"):
            raise BuildError("missing RisuAI runtime fields")
        if "triggerscript" in risu or "customScripts" in risu:
            raise BuildError("trigger/regex must live in module.risum")

        module = unpack_module(zf.read("module.risum"))
        trigger = module.get("trigger", [])
        if (
            len(trigger) != 1
            or trigger[0].get("effect", [{}])[0].get("type") != "triggerlua"
            or trigger[0].get("lowLevelAccess") is not True
        ):
            raise BuildError("missing RisuAI Lua trigger")
        if len(module.get("lorebook", [])) != len(
            card["data"]["character_book"]["entries"]
        ):
            raise BuildError("module/card lore mismatch")
        if any(x.get("comment") == "main.lua" for x in module.get("lorebook", [])):
            raise BuildError("main.lua must not be duplicated as lore")

        for asset in card["data"].get("assets", []):
            uri = asset.get("uri", "")
            if not uri.startswith("embeded://") or uri[10:] not in names:
                raise BuildError(f"missing embedded asset: {uri}")
            meta = (
                "x_meta/main.json"
                if asset.get("type") == "icon"
                else f"x_meta/{asset.get('name', '')}.json"
            )
            if meta not in names:
                raise BuildError(f"missing asset metadata: {meta}")


def build(root: Path, metadata_path: Path, output_dir: Path) -> Path:
    cfg = load_metadata(metadata_path)
    card, module, members = card_payload(root, cfg)
    charx = make_charx(card, module, members)
    verify(charx)

    output_dir.mkdir(parents=True, exist_ok=True)
    base = cfg.get("output_basename", "HellTrain")
    charx_path = output_dir / f"{base}.charx"
    charx_path.write_bytes(charx)
    return charx_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build the HellTrain RisuAI character card")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--metadata", "--manifest", dest="metadata", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv or sys.argv[1:])

    root = args.root.resolve()
    metadata_path = (args.metadata or root / "build" / "card_metadata.json").resolve()
    output_dir = (args.output or root / "build").resolve()
    try:
        charx = build(root, metadata_path, output_dir)
    except (BuildError, RPackError, KeyError, OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"built {charx}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
