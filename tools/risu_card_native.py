from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
import uuid
import zipfile
from pathlib import Path

from risu_rpack import RPackError, pack_module, unpack_module

JPEG_SOI = b"\xff\xd8"
JPEG_EOI = b"\xff\xd9"
ZIP_LOCAL = b"PK\x03\x04"
FOLDER_PREFIX = "\uf000folder:"

SD_DATA = [
    ["always", "solo, 1girl"],
    ["negative", ""],
    ["|character's appearance", ""],
    ["current situation", ""],
    ["$character's pose", ""],
    ["$character's emotion", ""],
    ["current location", ""],
]
NEW_GEN_DATA = {
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
        "CharacterCards.db", "CharTraits.db", "Environments.db",
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


def text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError(f"UTF-8 text required: {path}") from exc


def manifest(path: Path) -> dict:
    try:
        value = json.loads(text(path))
    except json.JSONDecodeError as exc:
        raise BuildError(f"invalid manifest: {exc}") from exc
    if not isinstance(value, dict):
        raise BuildError("manifest root must be an object")
    return value


def ordered(paths: list[Path], names: list[str]) -> list[Path]:
    rank = {name: i for i, name in enumerate(names)}
    return sorted(paths, key=lambda p: (rank.get(p.name, len(rank)), p.name))


def folder_key(label: str) -> str:
    folder_uuid = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"https://github.com/ChatPoongKun/HellTrain/lore/{label}",
    )
    return FOLDER_PREFIX + str(folder_uuid)


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
                "content": text(path),
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
    entries = []
    for lore in lores:
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
                width2 = 3000
                height2 = round(width2 / (width / height))
            else:
                height2 = 3000
                width2 = round(height2 * (width / height))
            image = image.resize((width2, height2))
        if image.mode not in ("RGB", "RGBA"):
            image = image.convert("RGBA" if "A" in image.getbands() else "RGB")
        output = io.BytesIO()
        image.save(output, format="WEBP", quality=75)
        return output.getvalue()


def assets(root: Path, cfg: dict) -> tuple[list[dict], list[tuple[str, bytes]]]:
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


def module_bytes(name: str, main_lua: str, lores: list[dict]) -> bytes:
    module = {
        "name": f"{name} Module",
        "description": f"Module for {name}",
        "id": str(uuid.uuid5(
            uuid.NAMESPACE_URL,
            "https://github.com/ChatPoongKun/HellTrain/module",
        )),
        "trigger": [{
            "comment": "",
            "type": "start",
            "conditions": [],
            "effect": [{"type": "triggerlua", "code": main_lua}],
            "lowLevelAccess": True,
        }],
        "regex": [],
        "lorebook": lores,
        "assets": [],
    }
    return pack_module(module)


def card_payload(root: Path, cfg: dict) -> tuple[dict, bytes, list[tuple[str, bytes]]]:
    lores = runtime_lore(root)
    required = set(cfg.get("required_lore", []))
    present = {x["comment"] for x in lores if x["mode"] != "folder"}
    missing = sorted(required - present)
    if missing:
        raise BuildError("required lore missing: " + ", ".join(missing))

    asset_records, asset_members = assets(root, cfg)
    risu = {
        "bias": [],
        "viewScreen": "none",
        "utilityBot": False,
        "sdData": SD_DATA,
        "backgroundHTML": text(root / cfg.get("background_html", "html/embeddings.css")),
        "additionalText": "",
        "virtualscript": "",
        "largePortrait": False,
        "lorePlus": False,
        "newGenData": NEW_GEN_DATA,
        "vits": {},
        "lowLevelAccess": True,
        "defaultVariables": "",
        "prebuiltAssetCommand": "",
        "prebuiltAssetExclude": cfg.get("prebuilt_asset_exclude", []),
        "prebuiltAssetStyle": "",
        "toggles": "",
    }
    now = int(os.environ.get("SOURCE_DATE_EPOCH", str(int(time.time()))))
    data = {
        "name": cfg["name"],
        "description": cfg.get("description", ""),
        "personality": cfg.get("personality", ""),
        "scenario": cfg.get("scenario", ""),
        "first_mes": text(root / cfg.get("first_message", "Prompt/firstmsg.html")),
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
            "risuai": risu,
            "depth_prompt": {"depth": 0, "prompt": ""},
        },
        "group_only_greetings": [],
        "nickname": "",
        "source": cfg.get("source", []),
        "creation_date": int(cfg.get("creation_date", 0)),
        "modification_date": now,
        "assets": asset_records,
    }
    card = {"spec": "chara_card_v3", "spec_version": "3.0", "data": data}
    main_lua = text(root / cfg.get("entry_script", "System/main.lua"))
    return card, module_bytes(cfg["name"], main_lua, lores), asset_members


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
        write_member(zf, "card.json", json.dumps(
            card, ensure_ascii=False, indent=4
        ).encode("utf-8"))
    return output.getvalue()


def jpeg_cover(root: Path, cfg: dict) -> bytes:
    try:
        from PIL import Image
    except ImportError as exc:
        raise BuildError("Pillow is required") from exc
    raw = (root / cfg.get("icon", "imgs/game_icon.png")).read_bytes()
    with Image.open(io.BytesIO(raw)) as image:
        output = io.BytesIO()
        image.convert("RGB").save(output, format="JPEG", quality=95)
        return output.getvalue()


def verify(raw: bytes, hybrid: bool) -> None:
    payload = raw
    if hybrid:
        eoi = raw.find(JPEG_EOI)
        start = raw.find(ZIP_LOCAL, eoi + 2)
        if not raw.startswith(JPEG_SOI) or eoi < 0 or start < 0:
            raise BuildError("invalid JPEG+CHARX hybrid")
        payload = raw[start:]
    with zipfile.ZipFile(io.BytesIO(payload), "r") as zf:
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
        for asset in card["data"].get("assets", []):
            uri = asset.get("uri", "")
            if not uri.startswith("embeded://") or uri[10:] not in names:
                raise BuildError(f"missing embedded asset: {uri}")
            meta = (
                "x_meta/main.json" if asset.get("type") == "icon"
                else f"x_meta/{asset.get('name', '')}.json"
            )
            if meta not in names:
                raise BuildError(f"missing asset metadata: {meta}")


def build(root: Path, cfg_path: Path, out_dir: Path) -> tuple[Path, Path]:
    cfg = manifest(cfg_path)
    card, module, members = card_payload(root, cfg)
    charx = make_charx(card, module, members)
    hybrid = jpeg_cover(root, cfg) + charx
    verify(charx, False)
    verify(hybrid, True)

    out_dir.mkdir(parents=True, exist_ok=True)
    base = cfg.get("output_basename", "HellTrain")
    charx_path = out_dir / f"{base}.charx"
    jpg_path = out_dir / f"{base}.jpg"
    charx_path.write_bytes(charx)
    jpg_path.write_bytes(hybrid)
    return charx_path, jpg_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv or sys.argv[1:])
    root = args.root.resolve()
    cfg = (args.manifest or root / "card" / "manifest.json").resolve()
    out = (args.output or root / "dist").resolve()
    try:
        charx, jpg = build(root, cfg, out)
    except (BuildError, RPackError, KeyError, OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"built {charx}")
    print(f"built {jpg}")
    return 0
