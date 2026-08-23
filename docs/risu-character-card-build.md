# RisuAI 캐릭터 카드 빌드

HellTrain 저장소의 소스 파일을 RisuAI에서 바로 임포트할 수 있는 Character Card V3 패키지로 묶는다.

## 출력 형식

빌더는 한 번의 실행으로 다음 두 파일을 생성한다.

- `dist/HellTrain.charx`: 표준 CHARX ZIP 아카이브
- `dist/HellTrain.jpg`: `card/cover.jpg` JPEG 뒤에 동일한 CHARX ZIP을 붙인 RisuAI JPEG 하이브리드 카드

JPEG 하이브리드는 사람이 보면 일반 JPEG이고, RisuAI에서는 뒤에 붙은 ZIP payload를 캐릭터 카드로 읽을 수 있다.

CHARX 내부에는 다음 항목이 들어간다.

```text
card.json
assets/icon/cover.jpg
assets/x-risu-asset/...
```

`card.json`은 `chara_card_v3` / `3.0` 스키마를 사용한다.

## HellTrain 런타임 매핑

HellTrain은 일반 캐릭터 프롬프트만으로 동작하지 않고 RisuAI의 Lua low-level access와 로어북 조회를 사용한다. 빌더는 저장소 구조를 다음처럼 카드 구조에 매핑한다.

- `Prompt/firstmsg.html` → `data.first_mes`
- `System/main.lua` → `extensions.risuai.triggerscript`의 `triggerlua` 진입점
- `System/*.lua`, `DB/*.db`, `Char/*.db`, `html/*.html`, `html/*.css` → `data.character_book.entries`
- `imgs/*` → `x-risu-asset`
- `card/cover.jpg` → 카드 메인 아이콘 + JPEG 하이브리드의 앞부분

로어 항목의 `name`/`comment`는 파일 basename을 그대로 사용한다. 예를 들어 `System/battleController.lua`는 `battleController.lua`라는 로어가 된다. HellTrain 런타임이 `getLoreBooks(triggerId, "battleController.lua")`처럼 이름으로 조회하므로 이 규칙을 바꾸면 안 된다.

런타임 소스 로어는 LLM 프롬프트에 우연히 활성화되지 않도록 `constant: false`이며 저장소 경로 기반의 전용 sentinel key를 사용한다. Lua low-level API의 직접 로어 조회는 활성화 여부와 관계없이 `comment`가 정확히 일치하는 항목을 읽는다.

이미지 asset의 이름은 확장자를 뺀 파일명으로 등록한다. 따라서 `imgs/서미령.png`는 `{{raw::서미령}}`, `imgs/서미령_함락.png`는 `{{raw::서미령_함락}}`에서 사용할 수 있다.

## `module.risum`을 만들지 않는 이유

RisuAI의 CHARX는 선택적으로 `module.risum`을 포함할 수 있지만 필수는 아니다. 현재 빌드는 공개 Character Card V3 필드인 `character_book`과 `extensions.risuai.triggerscript`에 로어와 트리거를 직접 기록한다. RisuAI importer가 이 두 필드를 네이티브로 읽으므로 HellTrain에 필요한 기능은 유지하면서 별도의 RPack/`.risum` 인코더 의존성을 피할 수 있다.

## 로컬 빌드

Python 3.10 이상만 필요하며 외부 패키지는 사용하지 않는다.

```bash
python tools/build_risu_card.py
```

다른 manifest 또는 출력 디렉터리를 사용할 수도 있다.

```bash
python tools/build_risu_card.py \
  --manifest card/manifest.json \
  --output dist
```

빌더는 생성 직후 다음을 검증하고 하나라도 어긋나면 실패한다.

- CHARX ZIP 무결성
- JPEG SOI/EOI와 appended ZIP 존재 여부
- `card.json` Character Card V3 스키마 표식
- RisuAI low-level access 플래그
- `triggerlua` 진입점
- 필수 로어 파일 존재 여부
- 로어 basename 및 asset 이름 중복 여부

## GitHub Actions

`.github/workflows/build-risu-character-card.yml`은 관련 소스가 변경된 PR, `main` push, 수동 실행에서 카드 빌드를 수행한다. 성공하면 `HellTrain-risu-card` artifact에 `.charx`와 `.jpg`를 함께 업로드한다.

CI에서는 `HELLTRAIN_CARD_VERSION`에 현재 Git commit SHA를 넣어 `character_version`을 자동 기록한다. 로컬 빌드는 `card/manifest.json`의 fallback 값을 사용한다.

## 커버 교체

`card/cover.jpg`를 다른 JPEG로 교체하면 다음 빌드부터 카드 아이콘과 JPEG 하이브리드의 보이는 이미지가 함께 변경된다. PNG를 그대로 지정하지 말고 JPEG로 저장해야 한다.
