from pathlib import Path

helper = Path('.github/scripts/apply-aftermath-skip-module-split.py')
source = helper.read_text(encoding='utf-8')
exec(compile(source, str(helper), 'exec'))
helper.unlink()
