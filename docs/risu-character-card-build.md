# RisuAI 캐릭터 카드 빌드

HellTrain 저장소의 소스 파일을 RisuAI의 **네이티브 CHARX export 구조와 같은 형태**로 묶는다.

## 출력

```text
dist/HellTrain.charx
dist/HellTrain.jpg
```

- `HellTrain.charx`: Character Card V3 CHARX ZIP
- `HellTrain.jpg`: JPEG 앞부분 뒤에 동일한 CHARX ZIP을 붙인 RisuAI 하이브리드 카드

## 기준 구조

RisuAI에서 직접 export한 HellTrain CHARX를 기준으로 다음 레이아웃을 유지한다.

```text
x_meta/<asset-name>.json
assets/other/image/<filename>.<ext>
x_meta/main.json
assets/icon/image/main.<ext>
module.risum
card.json
```

이미지 파일은 RisuAI의 기본 image compression과 같은 정책으로 WebP quality 75로 다시 인코딩한다. 원래 확장자와 asset 이름은 `card.json`에 그대로 남기며 `x_meta/*.json`에 원본 이미지 형식을 기록한다.

예를 들어 `imgs/서미령.png`는 다음처럼 들어간다.

```text
x_meta/서미령.png.json
assets/other/image/서미령.png.png
```

`card.json`의 asset record도 RisuAI native export처럼 `name: "서미령.png"`, `ext: "png"`를 사용한다.

## 런타임 매핑

### 첫 메시지

`Prompt/firstmsg.html`은 `data.first_mes`가 된다.

### background embedding

`html/embeddings.css`는 lore가 아니라 `data.extensions.risuai.backgroundHTML`에 그대로 저장한다. HellTrain UI 스타일은 이 필드에 의존하므로 일반 lore로 넣으면 원본 카드와 동작이 달라진다.

### lorebook

RisuAI native export와 동일하게 다음 4개 folder entry를 만들고 파일을 그 아래에 배치한다.

```text
DB
Chars
HTML
System
```

매핑은 다음과 같다.

- `DB/*.db` → `DB`
- `Char/*.db` → `Chars`
- `html/*.html` → `HTML`
- `System/*.lua` → `System`

`System/main.lua`는 lore에서 제외한다. 나머지 lore의 `comment`/`name`은 파일 basename을 그대로 사용하고, `insertorder`는 100, `alwaysActive`는 false로 유지한다.

HellTrain runtime의 `getLoreBooks(triggerId, "battleController.lua")` 같은 조회는 lore `comment`의 정확한 이름을 사용하므로 basename을 변경하면 안 된다.

### `module.risum`

RisuAI native CHARX는 trigger와 lorebook을 `module.risum`에도 저장한다. 따라서 빌더도 legacy Risu module framing과 RPack byte map을 사용해 `module.risum`을 생성한다.

`module.risum`에는 다음이 들어간다.

- `System/main.lua`를 실행하는 `triggerlua` 1개
- low-level access 활성화
- regex 목록
- 전체 lorebook
- module metadata

RisuAI importer는 CHARX에서 `module.risum`을 발견하면 여기의 trigger/lorebook을 읽어 character import에 적용한다. 따라서 `card.json`의 `extensions.risuai`에는 `triggerscript`/`customScripts`를 중복 기록하지 않는다.

### Character Card V3 lore 복제

RisuAI native export 자체가 `module.risum`의 lorebook과 같은 내용을 `card.json.data.character_book.entries`에도 기록한다. 빌더 역시 이 중복 구조를 유지한다.

## 원본 카드와의 비교에서 확인한 차이

참조 CHARX를 구조적으로 다시 생성한 fixture에서는 folder UUID를 정규화했을 때 `card.json`의 의미 있는 차이는 export 시각을 나타내는 `modification_date`뿐이었다. `module.risum`도 module UUID와 일부 optional false 필드를 제외하면 같은 구조로 재구성된다.

완전한 byte-for-byte 동일성은 목표가 아니다. RisuAI native export에는 실행 시각, UUID, ZIP writer 세부사항, 브라우저 WebP encoder 결과처럼 export 환경에 따라 달라지는 값이 있기 때문이다. 대신 RisuAI가 읽는 필드, lore 구조, module framing, asset naming, background embedding과 import 결과가 같도록 맞춘다.

## 로컬 빌드

Python 3.10 이상과 Pillow가 필요하다.

```bash
python -m pip install -r tools/requirements-card-build.txt
python tools/build_risu_card.py
```

다른 manifest 또는 출력 디렉터리를 사용할 수 있다.

```bash
python tools/build_risu_card.py \
  --manifest card/manifest.json \
  --output dist
```

## 검증

빌더는 생성 직후 다음을 검사한다.

- CHARX ZIP 무결성
- JPEG + appended CHARX 구조
- `chara_card_v3` / `3.0`
- `extensions.risuai.lowLevelAccess`
- `backgroundHTML` 존재
- `card.json`에 trigger가 중복되지 않았는지
- `module.risum` magic/version/RPack payload
- `module.risum`의 `triggerlua`
- module/card lore entry 수 일치
- `System/main.lua`가 lore에 잘못 포함되지 않았는지
- 모든 embedded asset과 대응 `x_meta` 존재
- 필수 HellTrain lore 존재

## GitHub Actions

`.github/workflows/build-risu-character-card.yml`은 관련 소스 변경 PR, `main` push, 수동 실행에서 빌드를 수행한다. 성공하면 `HellTrain-risu-card` artifact로 `.charx`와 `.jpg`를 업로드한다.
