# 게임 시작 드래프트·캐릭터 선택 계약

이 문서는 `System/gameSetup.lua`와 `System/gameSetupView.lua`가 새 게임의 초기 플레이어 덱, 캐릭터 후보와 전투 인계 사양을 만드는 순수 상태 전이를 정의한다. 스키마 버전은 1이다.

## 1. 범위와 경계

현재 구현 범위는 다음과 같다.

```text
명시적 setupId + 명시적 setup RNG seed + 전체 staticData
→ 3장 제안
→ 1장 선택을 정확히 10회 반복
→ 10장 플레이어 덱 확정
→ 서로 다른 캐릭터 3명 제안
→ 캐릭터 1명 확정
→ setup에 결합된 전투 사양 확정
```

- 같은 카드 ID는 최대 2장까지 선택할 수 있다.
- 한 라운드의 제안은 서로 다른 플레이어 카드 3종이다.
- 희귀도와 출현 가중치는 아직 확정되지 않았으므로 v1은 모든 eligible 카드 종류를 같은 확률로 취급한다.
- 캐릭터 풀은 서로 다른 유효 캐릭터가 최소 3명이어야 한다. ASCII ID로 정렬한 풀에서 비복원 추첨해 항상 서로 다른 후보 3명을 만든다.
- `deckComplete`는 순수 카드 드래프트가 끝났음을 나타내는 중간 상태다. 호스트 컨트롤러는 이를 즉시 `characterSelect`로 전진시켜 사용자에게 `deckComplete` 화면을 최종 화면처럼 노출하지 않는다.
- 호스트 상태 저장, 채팅 변수, HTML, 메시지, 리로드와 `main.lua`는 순수 모듈의 책임이 아니다.

## 2. 권위 상태

권위 상태는 함수가 없는 JSON-safe 데이터만 가진다.

다음 블록은 공통 필드와 phase별 선택 필드를 함께 보여 주는 합성 예시다. 실제 상태에는 현재 phase에 허용된 선택 필드만 존재한다.

```lua
{
    schemaVersion = 1,
    kind = "gameSetupV1",
    setupId = "setup-0001",
    phase = "deckDraft", -- deckComplete | characterSelect | battleReady
    rng = {
        seed = 12345,
        cursor = 3,
    },
    selectedCardIds = {},
    offer = { -- deckDraft에서만 존재
        round = 1,
        cardIds = { "...", "...", "..." },
        interactionToken = "...",
    },

    characterOffer = { -- characterSelect에서만 존재
        characterIds = { "...", "...", "..." },
        interactionToken = "...",
    },

    selectedCharacterId = "yoo_jiyoung", -- battleReady에서만 존재
    battleSpec = { -- battleReady에서만 존재
        battleId = "battle-setup-0001",
        seed = 117074,
        environmentId = "uncrowded",
        turnLimit = 10,
    },
}
```

- `setupId`는 `[A-Za-z0-9][A-Za-z0-9_-]*` 형식의 명시적 runtime ID다.
- `rng.seed`와 `rng.cursor`는 0 이상인 IEEE-754 안전 정수다.
- `selectedCardIds`는 선택한 순서를 보존한다.
- `deckDraft`에서는 선택 수가 0..9이고 `offer.round == #selectedCardIds + 1`이다.
- `deckComplete`에서는 선택 수가 정확히 10이며 `offer`가 없다.
- `characterSelect`에서는 선택 수가 정확히 10이고 카드 `offer` 대신 서로 다른 3명의 `characterOffer`만 존재한다.
- `battleReady`에서는 모든 제안을 제거하고 `selectedCharacterId`와 정확한 `battleSpec`만 추가한다.
- 카드별 보유 수, eligible 목록과 미래 제안은 저장하지 않고 선택 이력에서 파생한다.
- 현재 `rng`는 저장된 현재 카드 또는 캐릭터 제안을 이미 생성한 뒤의 상태다. 화면 재게시, 캐릭터 확정과 검증은 RNG를 다시 소비하지 않는다.

## 3. action

### `start`

```lua
runScript(triggerId, "gameSetup", "start", {
    setupId = "setup-0001",
    seed = 12345,
}, staticData)
```

사양은 정확히 `setupId`, `seed`만 허용한다. 플레이어 카드 ID를 ASCII 순서로 정렬하고 첫 제안을 생성한다. 10회 동안 어떤 합법적인 선택 경로에서도 3종 제안을 유지하려면 플레이어 카드 종류가 최소 7개여야 한다.

### `choose`

```lua
runScript(triggerId, "gameSetup", "choose", state, {
    cardId = "subtle_approach",
    interactionToken = state.offer.interactionToken,
}, staticData)
```

상태 전체를 먼저 cursor 0부터 한 번 재생 검증한다. 올바른 명령은 재생이 반환한 canonical state의 현재 RNG cursor에서 이어서 다음 제안만 증분 생성한다. 이 증분 경로는 기준 `replay`와 동일한 state·RNG·token을 만들어야 하며, 저장소를 새로 읽는 복구와 `validate`는 항상 전체 `replay`를 사용한다. 열 번째 선택 뒤에는 추가 RNG를 소비하지 않고 `deckComplete`로 전환한다.

유효한 형식의 이전 interaction token으로 다시 클릭한 경우는 오류가 아니라 성공한 no-op이다.

```lua
{
    ok = true,
    applied = false,
    stale = true,
    state = currentStateClone,
}
```

따라서 저장 성공 뒤 UI 갱신 실패나 더블클릭이 발생해도 같은 선택을 두 번 적용하지 않는다. 열 번째 선택으로 `deckComplete`가 된 직후 같은 버튼이 다시 전달되는 경우도 성공한 stale no-op이다. 반면 현재 token과 함께 제안 밖 카드 ID를 보낸 명령은 호출 계약 위반이므로 실패한다.

### `beginCharacterSelect`

```lua
runScript(triggerId, "gameSetup", "beginCharacterSelect", deckCompleteState, staticData)
```

검증된 `deckComplete`에서만 호출한다. 캐릭터 ID를 ASCII 오름차순으로 정렬하고 현재 setup RNG에서 서로 다른 3명을 비복원 추첨해 `characterSelect`로 전환한다. `gameSetupController`는 열 번째 카드 선택 또는 저장된 `deckComplete`의 `start` 복구에서 이 전이를 자동으로 정확히 한 번 적용한다.

### `chooseCharacter`

```lua
runScript(triggerId, "gameSetup", "chooseCharacter", state, {
    characterId = "yoo_jiyoung",
    interactionToken = state.characterOffer.interactionToken,
}, staticData)
```

현재 `characterSelect`의 token과 후보를 검증한 뒤 `battleReady`로 전환한다. 캐릭터 확정은 RNG를 추가 소비하지 않는다. 이전 token 또는 이미 `battleReady`인 상태에 대한 재호출은 `applied = false`, `stale = true`인 성공 no-op이며, 현재 token과 함께 후보 밖 ID를 보낸 호출은 실패한다.

### `validate`

```lua
runScript(triggerId, "gameSetup", "validate", state, staticData)
```

필드 allowlist와 JSON 안전성뿐 아니라 seed와 선택 이력을 cursor 0부터 다시 실행한다. 각 과거 선택이 당시 제안에 실제로 들어 있었는지, 보유 제한을 지켰는지, 현재 카드·캐릭터 제안과 RNG·token이 재생 결과와 정확히 같은지 확인한다. `battleReady`에서는 선택 캐릭터가 재생된 세 후보 중 하나인지와 `battleSpec`이 setup ID·원본 seed에서 파생한 값과 exact-equal인지도 확인한다. 저장된 제안, RNG, 캐릭터 또는 전투 사양만 고쳐 쓴 상태는 거부한다.

## 4. 결정적 제안

각 라운드는 다음 순서를 따른다.

1. 선택 횟수가 2보다 작은 플레이어 카드 ID만 모은다.
2. ID를 ASCII 오름차순으로 정렬한다.
3. 범위 `(N, N-1, N-2)`를 `deterministicRng.nextIntegers`에 한 번 전달해 비복원으로 3개를 뽑는다. batch 내부는 기존 `nextInteger`의 rejection sampling을 같은 순서로 실행하므로 RNG cursor와 추첨 결과는 v1과 정확히 같다.
4. 추첨 순서를 그대로 화면 제안 순서로 보존한다.

Lua의 `pairs` 순서, 현재 시간, 전역 난수, DB의 선언 순서는 결과에 영향을 주지 않는다. 같은 seed, 같은 정적 카드 집합과 같은 선택 이력은 별도 Lua 프로세스에서도 같은 제안과 최종 덱을 만든다.

interaction token은 비밀 인증 수단이 아니다. 검증된 setup ID, 라운드, 선택 이력, 현재 RNG cursor와 제안을 묶는 결정적 stale-click fingerprint다. 권위 상태의 진위는 token이 아니라 전체 재생 검증으로 확인한다.

wire 형식은 `game-setup-draft-v1:<canonicalLength>:<hashA>:<hashB>`이며 각 가변 부분은 10진수다. 이 형식을 만족하는 이전 token은 stale no-op으로 처리하지만, 임의 문자열이나 빈 token은 잘못된 명령으로 거부한다.

캐릭터 제안도 같은 결정 원칙을 사용한다. ASCII 정렬된 캐릭터 풀에서 범위 `(N, N-1, N-2)`를 한 번에 소비하고, 뽑은 항목을 즉시 후보 풀에서 제거한다. 표시 순서는 추첨 순서를 보존한다. token wire는 `game-setup-character-v1:<canonicalLength>:<hashA>:<hashB>`이며 setup ID, 후보 생성 뒤 RNG와 후보 순서를 묶는다.

## 5. 공개 View

`gameSetupView`는 권위 상태 검증을 통과한 뒤 allowlist 방식으로 새로 만든다.

```lua
{
    schemaVersion = 1,
    kind = "gameSetupView",
    phase = "deckDraft",
    locked = false,
    progress = {
        selectedCount = 0,
        totalRounds = 10,
        currentRound = 1,
        remainingRounds = 10,
    },
    deck = {
        count = 0,
        limit = 10,
        items = {},
    },
    offer = {
        interactionToken = "...",
        cards = { ... },
    },
}
```

제안 카드에는 표시용 이름, 태그로 분해한 설명과 규칙, 행동 태그, 메커니즘, 기본 은폐 비용, 기본 저항 피해와 현재 보유 장수만 들어간다. `characterSelect` View는 후보 3명의 다음 공개 필드만 allowlist로 투영한다.

- `characterId`, 이름, 나이, 직업과 외형 요약
- 시작 저항, 시작 무드의 ID·표시명, 기본 드로우와 최대 손패
- 공개 캐릭터 특징의 ID, 이름과 설명

비공개 프로필, 캐릭터 덱·카드 ID, setup/battle seed, RNG, `battleSpec`, narration과 prototype 필드는 View에 넣지 않는다. `battleReady` View에는 선택한 캐릭터의 ID와 이름만 남고 잠긴다.

## 6. 전투 부트스트랩 경계

`battleReady.battleSpec`은 다음 값으로 고정한다.

```text
battleId     = "battle-" .. setupId
normalized   = (setupSeed - 1) % 2147483646
battleSeed   = ((normalized + 104729) % 2147483646) + 1
environment  = "uncrowded"
turnLimit    = 10
```

전투 seed는 현재 setup RNG cursor가 아니라 원본 setup seed에서 고정 domain offset으로 파생한다. 따라서 드래프트·캐릭터 선택 경로가 전투 난수열을 우발적으로 바꾸지 않으며, setup 재생으로 같은 전투 사양을 복구할 수 있다.

완성한 `selectedCardIds`, `selectedCharacterId`와 `battleSpec`은 `battleController.startFromSetup`이 검증한 뒤 `battleBootstrap.fromSetup`에 전달한다. 컨트롤러는 첫 `turnInitializer.prepareTurn`까지 성공한 authority·draft를 만든 뒤에만 전투 저장을 시작한다.

기존 `verticalSlice`의 고정 6장 경로는 회귀용으로 유지한다. 일반 경로는 중복을 포함한 정확히 10장 선택 순서를 안정 인스턴스 ID로 바꾼 뒤, 세션 시작 규칙에 따라 플레이어 덱과 캐릭터 덱을 그 순서로 결정적 셔플한다.

## 7. 연결 상태와 남은 항목

다음 연결이 완료되어 있다.

- `init.lua`의 얇은 `start`/`choose`/`chooseCharacter` 전달 경계
- `gameSetupController.lua`의 seed 발급, 권위 상태 저장, 공개 View/UI 게시, 캐릭터 확정과 전투 인계 복구
- `cardDraft.html`의 `gameSetupView` CBS 렌더링과 interaction token 라우트
- `characterSelect.html`의 공개 후보 3명 CBS 렌더링과 interaction token 라우트
- 첫 메시지의 시작 버튼에서 카드 10장, 캐릭터 확정과 첫 선택 가능 전투 턴까지의 진입 흐름

다음 항목은 후속 범위다.

- 후보의 희귀도·상성·누적 만남 기록을 반영하는 가중 추첨
- 전투 종료 뒤 보상과 다음 세션으로 이어지는 메타 진행
- 실제 최신 RisuAI에서의 로어북 등록, CBS 렌더링과 연속 턴 검증

`main.lua`에는 승인된 공개 route `chooseCharacter`와 정확한 인수 개수 검증이 연결되어 있다. 후속 변경도 실제 diff와 각 훅의 의도를 먼저 보고하고 별도 승인을 받은 뒤 수정한다.

## 8. 후속 호스트 컨트롤러 계약

`System/gameSetupController.lua`는 순수 모듈을 RisuAI 호스트에 연결하는 얇은 경계다. `init.lua`는 시작 버튼의 action을 해석하거나 상태를 직접 만들지 않고 `start`, 카드 선택과 캐릭터 선택 action을 이 컨트롤러에 전달한다. `main.lua`는 허용된 버튼 route, 모듈 cache와 상시 `editDisplay` anchor를 제공하지만 setup 규칙을 판정하지 않는다.

컨트롤러가 소유하는 영속 키와 공개 채팅 변수는 다음과 같다.

- 권위 상태: `gameSetupV1.authority`
- 공개 View wire: `gameSetupView`
- 준비 마커: `gameSetupReady`
- 동적 UI body: `🔯🔯🔯`
- 버전된 정적 shell: `helltrainUiShellV1`, `helltrainUiShellRevision`
- 독립 popup slot: `helltrainUiPopupV1`
- 표시 anchor index: `helltrainUiAnchorIndexV1`

새 권위 상태가 없을 때 `start`는 RisuAI의 `cbs('{{randint::1::2147483646}}')`를 정확히 한 번 호출한다. 결과가 1..2147483646 범위의 정수가 아니거나 `cbs`가 없거나 예외를 던지면 다른 난수원으로 대체하지 않고 구조화 오류로 실패한다. 정상 결과가 `seed`라면 `setupId`는 `setup-<seed>`로 정하고 두 값을 권위 상태에 저장한다. 이미 권위 상태가 있는 재시작과 게시 재시도는 `cbs`를 호출하지 않고 저장 상태를 재생 검증하므로 seed와 제안을 바꾸지 않는다.

### 8.1 시작과 게시 순서

정상 시작과 복구는 다음 순서를 지킨다.

```text
gameSetupReady = "updating" 쓰기/재읽기
→ gameSetup 권위 상태 생성 또는 기존 상태 검증
→ 새 시작/적용 전이이면 권위 상태 쓰기/재읽기
→ gameSetupView 생성
→ gameSetupView wire 쓰기/재읽기
→ shell revision이 다를 때만 sideBar shell 쓰기/재읽기
→ phase에 맞는 cardDraft 또는 characterSelect UI body 쓰기/재읽기
→ gameSetupReady = "ready" 쓰기/재읽기
→ controller 반환
→ RisuAI button host가 클릭된 message pointer를 1회 remount
```

각 호스트 쓰기는 즉시 해당 getter로 다시 읽고 방금 쓴 값과 정확히 같은지 확인한다. 읽기 결과가 다르면 `*_write_not_persisted` 계열의 구조화 오류로 실패한다. 동일 transaction에서 이미 검증된 canonical snapshot과 readback이 exact-equal이면 저장 직후에 또 전체 replay하지 않는다. 다음 이벤트에서 저장소를 새로 읽으면 다시 전체 검증한다. controller는 확정된 `ready`까지 게시하고 수동 reload를 호출하지 않는다. RisuAI의 `risu-btn` host가 trigger 반환 뒤 이미 클릭 message를 remount하므로, controller reload를 더하면 같은 HTML/CBS 파싱이 중복된다. `sideBar.html`은 content hash revision이 같으면 다시 읽거나 body와 함께 복사하지 않는다.

RisuAI의 동일 button mode mutex와 controller 내부의 무-yield 실행으로 일반 UI 버튼 전이는 직렬화된다. 그래도 새 시작이나 카드·캐릭터 전이를 쓰기 직전에 처음 읽은 expected authority가 현재 저장값과 정확히 같은지 다시 확인한다. 사라짐·교체·선행 생성이 감지되면 `authority_concurrent_change`로 실패하며 다른 요청의 상태를 덮어쓰지 않는다.

RisuAI의 `getLoreBooks`는 로어북 내용을 반환하기 전에 CBS를 평가한다. 따라서 `cardDraft.html`과 `characterSelect.html`은 `gameSetupView` wire의 쓰기와 재읽기 검증이 모두 끝난 뒤에만 로드해야 한다. View보다 먼저 로드하면 템플릿이 빈 값이나 이전 phase의 View로 선평가된 정적 HTML이 되어, 이후 View를 게시해도 UI가 대기 화면에 머물거나 한 단계 뒤처진다.

`updating`은 성공 표시가 아니다. 게시 과정이 중단되면 controller는 `ready`를 기록하지 않는다. 다음 `start` 호출은 저장된 권위 상태가 유효할 때 새 상태를 덮어쓰지 않고 동일 상태에서 게시를 재개한다. 따라서 권위 저장 뒤 View/UI 게시가 실패해도 재시작이 선택 이력과 RNG를 초기화하지 않는다.

### 8.2 카드 선택

카드 버튼은 View가 공개한 `cardId`와 `interactionToken`을 모두 `gameSetupController.choose`에 전달한다. 컨트롤러는 저장된 권위 상태를 읽고 `gameSetup.choose`에 그대로 전달한다.

- 현재 token이면 선택 전이 결과를 권위 키에 write-read 검증해 저장한 뒤 새 View와 UI를 위 순서대로 게시한다.
- 이전 token이면 `gameSetup.choose`의 `applied = false`, `stale = true`를 보존한다. 이 경로는 권위 상태를 한 번도 쓰지 않고 현재 View/UI만 재게시하므로 더블클릭이 두 장을 선택하지 않는다.
- 유효하지 않은 카드 ID, token 또는 손상된 권위 상태는 실패하며 컨트롤러가 권위 상태를 쓰지 않는다. 클릭 message의 host remount 여부는 이 성공/실패와 무관하다.
- 열 번째 유효 선택 뒤 순수 `deckComplete`를 즉시 `beginCharacterSelect`로 전진시킨다. 컨트롤러는 최종 `characterSelect` 권위 상태와 후보 View만 게시하므로 중간 `deckComplete` UI가 보이지 않는다.

### 8.3 캐릭터 선택과 전투 인계

캐릭터 확정 route는 정확히 `init|chooseCharacter|<characterId>|<interactionToken>`이다. 컨트롤러는 저장된 `characterSelect`를 전체 재생 검증하고 `gameSetup.chooseCharacter`의 결과만 적용한다.

- 현재 token의 후보이면 `battleReady` 권위 상태를 먼저 write-read 검증한다.
- 이전 token 또는 완료 뒤 더블클릭이면 설정 상태를 다시 쓰지 않고 같은 `battleReady`에서 전투 인계 복구를 시도한다.
- setup UI를 게시하지 않고 shell을 보장한 뒤 내부 action `battleController.startFromSetup`에 canonical `battleReady` 전체를 전달한다.
- `startFromSetup`이 전투 authority·draft, `battleView`와 `battleui.html` body를 모두 게시한 뒤에만 `gameSetupReady = "ready"`를 쓴다.
- 인계 중 실패하면 저장된 `battleReady`가 영수증으로 남는다. 다음 `start`는 새 CBS seed를 만들거나 setup을 덮어쓰지 않고 같은 전투를 재개한다.

새 전투 게시 순서는 다음과 같다.

```text
gameSetupReady = "updating" 쓰기/재읽기
→ canonical battleReady 권위 상태 쓰기/재읽기(새 전이일 때)
→ sidebar shell 보장
→ battleController.startFromSetup
   → setup 전체 재생·결합 검증
   → battleBootstrap.fromSetup + 첫 turnInitializer.prepareTurn
   → 전투 런타임 다섯 키 쓰기/재읽기
   → battleView 쓰기/재읽기
   → battleui.html 로드
   → 동적 UI body 쓰기/재읽기
→ gameSetupReady = "ready" 쓰기/재읽기
```

버튼 host가 반환 뒤 화면을 remount하므로 이 인계 경로는 별도 display reload를 호출하지 않는다. 동일 `battleId`의 재호출은 setup seed, 환경, 턴 제한, 선택 캐릭터와 초기 플레이어 카드 순서가 기존 authority에 정확히 결합되어 있을 때만 현재 전투를 보존하며 View/UI만 재게시한다. 다른 전투, 다른 결합 또는 결정적으로 재구성한 초기 authority·draft와 다른 부분 저장은 fail-closed한다.

### 8.4 오류와 입력 불변성

컨트롤러의 모든 실패는 `schemaVersion`, `ok = false`, 비어 있지 않은 `errors` 배열을 가진다. 각 오류에는 문자열 `code`, `path`, `message`가 있다. 다음 상황을 최소한 구분한다.

- 필요한 host getter/setter가 없음
- 하위 모듈 호출이 예외를 던짐
- `cbs`가 없음/예외 또는 randint 결과 seed가 정수·범위 계약을 위반함
- 저장된 권위 상태가 재생 검증에 실패함
- 권위 상태 write-read 불일치
- View wire write-read 불일치
- 준비 마커 write-read 불일치

실패 응답은 Lua 예외를 호스트 밖으로 흘리지 않는다. 실패한 호출은 전달받은 command, 기존 권위 상태와 정적 데이터를 직접 수정하지 않는다. View/UI 게시 실패 전에 이미 write-read 검증된 권위 전이는 롤백을 가장하지 않으며, 다음 동일 token 호출은 stale 복구 경로로 현재 화면을 다시 게시한다.

## 9. 카드 드래프트 UI 계약

`html/cardDraft.html`은 `gameSetupView`만 읽는 CBS 템플릿이다. JavaScript, inline DOM event handler, 임의 전역 변수 초기화와 DB 직접 접근을 사용하지 않는다.

- `deckDraft`에서 `offer.cards`의 정확히 3장을 반복 렌더링한다.
- 카드 표시는 `name`, `descriptionSegments`, `ruleLines`, `actionTag`, `mechanisms`, `baseStealthCost`, `baseResistanceDamage`, `ownedCopies`를 View에서 읽는다.
- 첫 클릭은 radio/label만 사용해 상세 정보를 펼치며 Lua를 호출하지 않는다.
- 상세 상태에서 두 번째 클릭만 `cardId`와 현재 `offer.interactionToken`을 포함한 `init|choose|<cardId>|<interactionToken>` route를 보낸다. `init.lua`가 이를 `gameSetupController.choose`로 그대로 전달한다.
- fantasy 장비명, 희귀도와 가짜 확률을 하드코딩하지 않는다.
- 순수 `deckComplete` 렌더링은 잠긴 중간 상태로만 유지하며, 정상 controller 흐름은 곧바로 캐릭터 선택 UI로 전환한다.
- 스타일은 전용 root class 아래로 범위를 제한하고 모바일 폭과 `prefers-reduced-motion`을 지원한다.

이 템플릿은 공개 View를 표시할 뿐 권위 상태를 만들거나 수정하지 않는다. 버튼 action의 최종 route 문법은 `init.lua`의 얇은 전달 계약과 일치해야 한다.

## 10. 캐릭터 선택 UI와 Risu 등록

`html/characterSelect.html`도 `gameSetupView`만 읽는 CBS 템플릿이며 JavaScript, inline event handler, DB 직접 접근과 비공개 필드를 사용하지 않는다.

- `characterSelect`에서 정확히 세 후보를 렌더링한다.
- 첫 클릭은 CSS radio/label로 공개 상세만 펼치고 Lua를 호출하지 않는다.
- 펼친 후보의 확정 버튼만 `init|chooseCharacter|<characterId>|<interactionToken>` route를 보낸다.
- `battleReady` fallback은 선택 완료만 알리며 전투 상태나 seed를 표시하지 않는다. 정상 인계에서는 곧 `battleui.html` body로 교체된다.
- 초상이 없는 후보에게 가짜 이미지나 임시 인물을 붙이지 않는다.

실제 RisuAI에서는 `characterSelect.html`을 파일명과 정확히 같은 이름의 개별 로어북으로 등록해야 한다. 프로젝트의 기존 운영 계약대로 `main.lua`만 트리거 스크립트이며, 이 HTML과 `CharacterList.db`, 각 개별 캐릭터 `.db`, 관련 Lua 모듈은 각각 별도 로어북으로 등록한다. 이름이 다르거나 누락되면 controller는 `missing_lore` 또는 로드 오류로 fail-closed한다.
