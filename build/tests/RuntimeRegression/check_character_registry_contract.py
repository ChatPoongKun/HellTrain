"""Registration checks must catch both missing and unlisted character DBs."""
from pathlib import Path
from tempfile import TemporaryDirectory

from check_character_registry import registration_errors


with TemporaryDirectory(prefix="helltrain-character-registry-") as temporary:
    root = Path(temporary)
    (root / "Char").mkdir()
    (root / "DB").mkdir()
    support = Path("DB/CharacterCardSupport.db").read_text(encoding="utf-8-sig")
    (root / "DB/CharacterCardSupport.db").write_text(support, encoding="utf-8")
    listing = '''return {
        schemaVersion=1, kind="characterList",
        characters={sample={id="sample", database="Sample.db", name="Sample", turnLimit=8}},
    }'''
    definition = '''return {
        schemaVersion=1, kind="characterDatabase",
        characters={sample={id="sample", name="Sample", battle={turnLimit=8}}},
        cards={},
    }'''
    (root / "Char/CharacterList.db").write_text(listing, encoding="utf-8")
    (root / "Char/Sample.db").write_text(definition, encoding="utf-8")
    assert registration_errors(root) == []

    (root / "Char/Orphan.db").write_text(definition, encoding="utf-8")
    assert any("Orphan.db" in error and "등록" in error for error in registration_errors(root))
    (root / "Char/Orphan.db").unlink()

    (root / "Char/Sample.db").unlink()
    assert any("Sample.db" in error and "없" in error for error in registration_errors(root))
    (root / "Char/Sample.db").write_text(
        definition.replace("characters={sample=", "characters={other="), encoding="utf-8"
    )
    assert any("Sample.db" in error and "sample" in error for error in registration_errors(root))

print("PASS: registered character DB presence and orphan detection")
