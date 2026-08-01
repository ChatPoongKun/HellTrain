from __future__ import annotations
import re
from dataclasses import dataclass
from pathlib import Path

TURN_EXPR = '{{dict_element::{{getvar::battleView}}::turnId}}'
TOKEN_EXPR = '{{dict_element::{{getvar::battleView}}::interactionToken}}'
KIND_EXPR = '{{getvar::battlePopoverKind}}'
ID_EXPR = '{{getvar::battlePopoverId}}'

STYLE = '''<style>
.ht-shared-popover-layer {
position: fixed;
z-index: 2147483646;
inset: 0;
}
.ht-shared-popover-backdrop {
position: fixed;
inset: 0;
width: 100%;
height: 100%;
margin: 0;
padding: 0;
border: 0;
background: rgba(4, 4, 6, .30);
cursor: default;
}
.ht-popover.ht-shared-popover.is-open {
display: block;
pointer-events: auto;
}
.ht-shared-popover-close {
position: absolute;
z-index: 2;
top: 8px;
right: 8px;
display: flex;
align-items: center;
justify-content: center;
width: 25px;
height: 25px;
min-height: 0;
margin: 0;
padding: 0;
border: 1px solid rgba(255, 255, 255, .13);
border-radius: 50%;
color: #aaa39d;
background: rgba(255, 255, 255, .04);
font-size: 15px;
line-height: 1;
cursor: pointer;
pointer-events: auto;
}
.ht-shared-popover .ht-popover-dismiss,
.ht-shared-popover .ht-choice-option,
.ht-shared-popover .ht-choice-close,
.ht-shared-popover summary {
pointer-events: auto;
}
</style>

'''

DIV_OPEN = re.compile(r'<div\b', re.I)
DIV_CLOSE = re.compile(r'</div\s*>', re.I)
CLASS_ATTR = re.compile(r'class="([^"]*)"')
ID_ATTR = re.compile(r'id="([^"]+)"')
TARGET_ATTR = re.compile(r'\s+popovertarget="([^"]+)"')
TARGET_ACTION_ATTR = re.compile(r'\s+popovertargetaction="hide"')

@dataclass(frozen=True)
class Popup:
    start: int
    end: int
    target: str
    kind: str
    item_id: str
    body: tuple[str, ...]
    open_scopes: tuple[str, ...]
    close_scopes: tuple[str, ...]


def classes(line: str) -> set[str]:
    match = CLASS_ATTR.search(line)
    return set(match.group(1).split()) if match else set()


def div_delta(line: str) -> int:
    return len(DIV_OPEN.findall(line)) - len(DIV_CLOSE.findall(line))


def container_end(lines: list[str], start: int) -> int:
    depth = 0
    for index in range(start, len(lines)):
        depth += div_delta(lines[index])
        if depth == 0:
            return index
    raise RuntimeError(f'unclosed div at line {start + 1}')


def infer_target(target: str) -> tuple[str, str]:
    markers = (
        ('-station-', 'station'),
        ('-trait-', 'trait'),
        ('-resource-', 'resource'),
        ('-enemy-plan-', 'enemy_plan'),
        ('-player-plan-', 'player_plan'),
        ('-mood-', 'mood'),
        ('-choice-', 'choice'),
        ('-change-', 'change'),
        ('-tag-', 'tag'),
    )
    if target.endswith('-environment'):
        return 'environment', 'current'
    for marker, kind in markers:
        if marker in target:
            return kind, target.split(marker, 1)[1]
    raise RuntimeError(f'unknown popover target: {target}')


def scope_for(kind: str, body_text: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if kind == 'station':
        return (
            ('{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::subway}}::stations}} station}}',),
            ('{{/each}}',),
        )
    if kind == 'trait':
        return (
            ('{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::character}}::traits}} trait}}',),
            ('{{/each}}',),
        )
    if kind == 'enemy_plan':
        status = 'hidden' if '아직 공개되지 않음' in body_text else 'revealed'
        return (
            (
                '{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::character}}::plans}} plan}}',
                '{{#if {{equal::{{dict_element::{{slot::plan}}::status}}::' + status + '}}}}',
            ),
            ('{{/if}}', '{{/each}}'),
        )
    if kind == 'player_plan':
        return (
            (
                '{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::player}}::plans}} playerPlan}}',
                '{{#if {{equal::{{dict_element::{{slot::playerPlan}}::status}}::revealed}}}}',
            ),
            ('{{/if}}', '{{/each}}'),
        )
    if kind == 'choice':
        return (
            (
                '{{#each {{dict_element::{{dict_element::{{getvar::battleView}}::hand}}::items}} card}}',
                '{{#if {{equal::{{dict_element::{{slot::card}}::hasEffectChoices}}::true}}}}',
            ),
            ('{{/if}}', '{{/each}}'),
        )
    if kind == 'change':
        if 'resistanceChangePopup' in body_text:
            collection = 'resistance'
            alias = 'resistanceChangePopup'
        elif 'stealthChangePopup' in body_text:
            collection = 'stealth'
            alias = 'stealthChangePopup'
        else:
            raise RuntimeError('cannot infer resource-change popup scope')
        return (
            (
                '{{#if {{equal::{{dict_element::{{dict_element::{{getvar::battleView}}::lastTurn}}::available}}::true}}}}',
                '{{#each {{dict_element::{{dict_element::{{dict_element::{{getvar::battleView}}::lastTurn}}::resourceChanges}}::' + collection + '}} ' + alias + '}}',
            ),
            ('{{/each}}', '{{/if}}'),
        )
    if kind == 'tag':
        return (
            ('{{#each {{dict_element::{{getvar::battleView}}::tagGlossary}} glossaryTag}}',),
            ('{{/each}}',),
        )
    return (), ()


def parse_popup(lines: list[str], start: int, end: int) -> Popup:
    outer = lines[start]
    match = ID_ATTR.search(outer)
    if not match:
        raise RuntimeError(f'popover without id at line {start + 1}')
    target = match.group(1)
    kind, item_id = infer_target(target)
    body = list(lines[start + 1:end])
    cleaned: list[str] = []
    for line in body:
        if 'ht-popover-close' in classes(line):
            continue
        line = TARGET_ATTR.sub('', line)
        if TARGET_ACTION_ATTR.search(line):
            line = TARGET_ACTION_ATTR.sub('', line)
        if ('ht-popover-dismiss' in classes(line) or 'ht-choice-close' in classes(line)) and 'risu-btn=' not in line:
            line = line.replace('>', ' risu-btn="popoverController|close">', 1)
        cleaned.append(line)
    body_text = ''.join(cleaned)
    open_scopes, close_scopes = scope_for(kind, body_text)
    return Popup(start, end, target, kind, item_id, tuple(cleaned), open_scopes, close_scopes)


def open_command(target: str) -> str:
    kind, item_id = infer_target(target)
    return f' risu-btn="popoverController|open|{kind}|{item_id}|{TURN_EXPR}|{TOKEN_EXPR}"'


def transform(source: str) -> str:
    lines = source.splitlines(keepends=True)
    bank_start = next(i for i, line in enumerate(lines) if 'ht-popover-bank' in classes(line))
    bank_end = container_end(lines, bank_start)

    popups: list[Popup] = []
    popup_ranges: dict[int, int] = {}
    index = 0
    while index < len(lines):
        line = lines[index]
        if 'ht-popover' in classes(line):
            end = container_end(lines, index)
            popup = parse_popup(lines, index, end)
            popups.append(popup)
            popup_ranges[index] = end
            index = end + 1
        else:
            index += 1

    prefix: list[str] = []
    index = 0
    while index < bank_start:
        if index in popup_ranges:
            index = popup_ranges[index] + 1
            continue
        line = lines[index]
        match = TARGET_ATTR.search(line)
        if match:
            target = match.group(1)
            line = TARGET_ATTR.sub(open_command(target), line, count=1)
            line = TARGET_ACTION_ATTR.sub('', line)
        prefix.append(line)
        index += 1

    shared: list[str] = [
        '<div class="ht-popover-bank">\n',
        '{{#if {{not::{{equal::{{getvar::battlePopoverKind}}::none}}}}}}\n',
        '{{#if {{equal::{{getvar::battlePopoverTurnId}}::' + TURN_EXPR + '}}}}\n',
        '{{#if {{equal::{{getvar::battlePopoverToken}}::' + TOKEN_EXPR + '}}}}\n',
        '<div class="ht-shared-popover-layer">\n',
        '<button type="button" class="ht-shared-popover-backdrop" risu-btn="popoverController|close" aria-label="상세정보 닫기"></button>\n',
        '<div id="ht-shared-popover" class="ht-popover ht-shared-popover is-open" role="dialog" aria-modal="true" aria-label="상세정보">\n',
        '<button type="button" class="ht-shared-popover-close" risu-btn="popoverController|close" aria-label="상세정보 닫기">×</button>\n',
    ]
    for popup in popups:
        shared.extend(scope + '\n' for scope in popup.open_scopes)
        shared.append('{{#if {{equal::' + KIND_EXPR + '::' + popup.kind + '}}}}\n')
        shared.append('{{#if {{equal::' + ID_EXPR + '::' + popup.item_id + '}}}}\n')
        shared.extend(popup.body)
        shared.extend(('{{/if}}\n', '{{/if}}\n'))
        shared.extend(scope + '\n' for scope in popup.close_scopes)
    shared.extend([
        '</div>\n',
        '</div>\n',
        '{{/if}}\n',
        '{{/if}}\n',
        '{{/if}}\n',
        '</div>\n',
    ])

    return STYLE + ''.join(prefix + shared + lines[bank_end + 1:])


def validate(before: str, after: str) -> None:
    if after.count('id="ht-shared-popover"') != 1:
        raise RuntimeError('shared popover must be defined exactly once')
    if re.search(r'\bpopover="|\bpopovertarget=', after):
        raise RuntimeError('native popover attributes remain')
    if re.search(r'<script\b|javascript\s*:|\son[a-z]+\s*=', after, re.I):
        raise RuntimeError('JavaScript or inline event handler found')
    if after.count('risu-btn="popoverController|open|') != 22:
        raise RuntimeError('unexpected open-trigger count')
    for tag in ('div', 'section', 'button', 'article', 'span', 'details'):
        opening = len(re.findall(fr'<{tag}\b', after, re.I))
        closing = len(re.findall(fr'</{tag}\s*>', after, re.I))
        if opening != closing:
            raise RuntimeError(f'unbalanced {tag}: {opening}/{closing}')
    for block in ('if', 'each'):
        opening = after.count('{{#' + block)
        closing = after.count('{{/' + block + '}}')
        if opening != closing:
            raise RuntimeError(f'unbalanced CBS {block}: {opening}/{closing}')
    if len(after.encode()) >= len(before.encode()):
        raise RuntimeError('template did not shrink')


def main() -> None:
    path = Path('html/battleui.html')
    before = path.read_text(encoding='utf-8')
    after = transform(before)
    validate(before, after)
    path.write_text(after, encoding='utf-8')
    print({
        'before_bytes': len(before.encode()),
        'after_bytes': len(after.encode()),
        'byte_delta': len(after.encode()) - len(before.encode()),
        'shared_popovers': after.count('id="ht-shared-popover"'),
        'open_commands': after.count('risu-btn="popoverController|open|'),
    })

if __name__ == '__main__':
    main()
