"""Check one-to-one registration of character DB files and their definitions."""
from pathlib import Path
import re
import sys

from lupa.lua54 import LuaRuntime, lua_type


ROOT = Path(__file__).resolve().parents[3]
DB_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]*\.db\Z")


def registration_errors(root: Path) -> list[str]:
    errors: list[str] = []
    char_dir = root / "Char"
    lua = LuaRuntime(unpack_returned_tuples=True)

    def read_module(path: Path):
        try:
            return lua.execute(path.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            errors.append(f"{path.name}: DB를 읽거나 실행할 수 없습니다: {exc}")
            return None

    support = read_module(root / "DB" / "CharacterCardSupport.db")
    if lua_type(support) != "table":
        return errors or ["CharacterCardSupport.db: 카드 함수 정의가 없습니다."]
    lua.globals().characterCardSupport = support

    listing = read_module(char_dir / "CharacterList.db")
    if lua_type(listing) != "table" or lua_type(listing["characters"]) != "table":
        return errors or ["CharacterList.db: 캐릭터 목록이 없습니다."]

    listed_files: set[str] = set()
    owners: dict[str, str] = {}
    for character_id, entry in sorted(listing["characters"].items(), key=lambda pair: str(pair[0])):
        if lua_type(entry) != "table":
            errors.append(f"CharacterList.db {character_id}: 목록 항목이 올바르지 않습니다.")
            continue
        database = entry["database"]
        if not isinstance(database, str) or not DB_NAME.fullmatch(database):
            errors.append(f"CharacterList.db {character_id}: DB 파일명이 올바르지 않습니다.")
            continue
        listed_files.add(database)
        if database in owners:
            errors.append(f"CharacterList.db: {database}를 {owners[database]}와 {character_id}가 중복 등록했습니다.")
            continue
        owners[database] = str(character_id)
        path = char_dir / database
        if not path.is_file():
            errors.append(f"CharacterList.db {character_id}: {database} 파일이 없습니다.")
            continue
        module = read_module(path)
        if lua_type(module) != "table" or lua_type(module["characters"]) != "table":
            errors.append(f"{database}: 캐릭터 정의가 없습니다.")
            continue
        definitions = module["characters"]
        definition = definitions[character_id]
        if lua_type(definition) != "table":
            errors.append(f"{database}: 목록의 {character_id} 캐릭터 정의가 없습니다.")
        elif definition["id"] != character_id:
            errors.append(f"{database}: {character_id} 정의의 내부 ID가 일치하지 않습니다.")
        for defined_id in definitions:
            if defined_id != character_id:
                errors.append(f"{database}: {defined_id} 캐릭터가 CharacterList.db에 등록되지 않았습니다.")

    actual_files = {path.name for path in char_dir.glob("*.db")
                    if path.is_file() and path.name != "CharacterList.db"}
    for database in sorted(actual_files - listed_files):
        errors.append(f"{database}: CharacterList.db에 등록되지 않은 캐릭터 DB입니다.")
    return errors


def main() -> int:
    errors = registration_errors(ROOT)
    if not errors:
        try:
            sys.path.insert(0, str(ROOT / "build/tests/BattleSimulation/StyleDecks"))
            from simulate_balance import runtime

            runtime("lua54")
        except Exception as exc:
            errors.append(f"등록된 캐릭터 DB의 정적 검증에 실패했습니다: {exc}")
    if errors:
        print("character registry validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: registered character DB files and definitions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
