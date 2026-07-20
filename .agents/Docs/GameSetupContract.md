# 게임 시작 드래프트 계약

이 문서는 `System/gameSetup.lua`와 `System/gameSetupView.lua`가 새 게임의 초기 플레이어 덱을 만드는 순수 상태 전이를 정의한다. 스키마 버전은 1이다.

## 1. 범위와 경계

현재 구현 범위는 다음과 같다.

```text
명시적 setupId + 명시적 setup RNG seed + 전체 staticData
→ 3장 제안
→ 1장 선택을 정확히 10회 반복
→ 10장 플레이어 덱 확정
```

- 같은 카드 ID는 최대 2장까지 선택할 수 있다.
- 한 라운드의 제안은 서로 다른 플레이어 카드 3종이다.
- 희귀도와 출현 가중치는 아직 확정되지 않았으므로 v1은 모든 eligible 카드 종류를 같은 확률로 취급한다.
- 캐릭터 3명 중 1명을 선택하는 단계는 이 계약에 포함하지 않는다. 현재 정적 캐릭터가 유지영 한 명뿐이므로 덱을 완성하면 `deckComplete`에서 멈춘다. 가짜 중복 후보나 묵시적 자동 선택을 만들지 않는다.
- 호스트 상태 저장, 채팅 변수, HTML, 메시지, 리로드와 `main.lua`는 순수 모듈의 책임이 아니다.

## 2. 권위 상태

권위 상태는 함수가 없는 JSON-safe 데이터만 가진다.

```lua
{
    schemaVersion = 1,
    kind = "gameSetupV1",
    setupId = "setup-0001",
    phase = "deckDraft", -- 또는 deckComplete
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
}
```

- `setupId`는 `[A-Za-z0-9][A-Za-z0-9_-]*` 형식의 명시적 runtime ID다.
- `rng.seed`와 `rng.cursor`는 0 이상인 IEEE-754 안전 정수다.
- `selectedCardIds`는 선택한 순서를 보존한다.
- `deckDraft`에서는 선택 수가 0..9이고 `offer.round == #selectedCardIds + 1`이다.
- `deckComplete`에서는 선택 수가 정확히 10이며 `offer`가 없다.
- 카드별 보유 수, eligible 목록과 미래 제안은 저장하지 않고 선택 이력에서 파생한다.
- 현재 `rng`는 저장된 현재 제안을 이미 생성한 뒤의 상태다. 화면 재게시나 검증은 RNG를 다시 소비하지 않는다.

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

상태 전체를 먼저 재생 검증한다. 올바른 명령은 제안에 포함된 카드 한 장을 선택하고 다음 제안을 한 번 생성한다. 열 번째 선택 뒤에는 추가 RNG를 소비하지 않고 `deckComplete`로 전환한다.

유효한 형식의 이전 interaction token으로 다시 클릭한 경우는 오류가 아니라 성공한 no-op이다.

```lua
{
    ok = true,
    applied = false,
    stale = true,
    state = currentStateClone,
}
```

따라서 저장 성공 뒤 UI 갱신 실패나 더블클릭이 발생해도 같은 선택을 두 번 적용하지 않는다. 반면 현재 token과 함께 제안 밖 카드 ID를 보낸 명령은 호출 계약 위반이므로 실패한다.

### `validate`

```lua
runScript(triggerId, "gameSetup", "validate", state, staticData)
```

필드 allowlist와 JSON 안전성뿐 아니라 seed와 선택 이력을 cursor 0부터 다시 실행한다. 각 과거 선택이 당시 제안에 실제로 들어 있었는지, 보유 제한을 지켰는지, 현재 제안·RNG·token이 재생 결과와 정확히 같은지 확인한다. 저장된 제안이나 RNG만 고쳐 쓴 상태는 거부한다.

## 4. 결정적 제안

각 라운드는 다음 순서를 따른다.

1. 선택 횟수가 2보다 작은 플레이어 카드 ID만 모은다.
2. ID를 ASCII 오름차순으로 정렬한다.
3. `deterministicRng.nextInteger`를 사용해 비복원으로 3개를 뽑는다.
4. 추첨 순서를 그대로 화면 제안 순서로 보존한다.

Lua의 `pairs` 순서, 현재 시간, 전역 난수, DB의 선언 순서는 결과에 영향을 주지 않는다. 같은 seed, 같은 정적 카드 집합과 같은 선택 이력은 별도 Lua 프로세스에서도 같은 제안과 최종 덱을 만든다.

interaction token은 비밀 인증 수단이 아니다. 검증된 setup ID, 라운드, 선택 이력, 현재 RNG cursor와 제안을 묶는 결정적 stale-click fingerprint다. 권위 상태의 진위는 token이 아니라 전체 재생 검증으로 확인한다.

wire 형식은 `game-setup-draft-v1:<canonicalLength>:<hashA>:<hashB>`이며 각 가변 부분은 10진수다. 이 형식을 만족하는 이전 token은 stale no-op으로 처리하지만, 임의 문자열이나 빈 token은 잘못된 명령으로 거부한다.

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

제안 카드에는 표시용 이름, 태그로 분해한 설명과 규칙, 행동 태그, 메커니즘, 기본 은폐 비용, 기본 저항 피해와 현재 보유 장수만 들어간다. View에는 setup ID, seed/cursor, 미제안 카드, 미래 제안, 함수, narration과 prototype 필드를 넣지 않는다. `deckComplete` View는 잠기며 `offer`가 없다.

## 6. 전투 부트스트랩 경계

완성한 `selectedCardIds`는 별도 명시적 전투 seed와 함께 `battleBootstrap.fromSetup`에 전달한다. setup RNG와 전투 RNG를 분리해 드래프트 선택 경로가 전투 난수열을 우발적으로 바꾸지 않게 한다.

기존 `verticalSlice`의 고정 6장 경로는 회귀용으로 유지한다. 일반 경로는 중복을 포함한 정확히 10장 선택 순서를 안정 인스턴스 ID로 바꾼 뒤, 세션 시작 규칙에 따라 플레이어 덱과 캐릭터 덱을 그 순서로 결정적 셔플한다.

## 7. 아직 연결하지 않는 항목

다음 항목은 후속 호스트/UI 단계에서 다룬다.

- `init.lua`의 시작 action과 setup ID/seed 발급 정책
- 권위 상태의 호스트 저장과 공개 View 게시 순서
- `cardDraft.html`의 실제 CBS 렌더링과 interaction token 라우트
- 캐릭터 데이터 2명 이상을 추가한 뒤 3명 후보 선택
- 캐릭터 선택 완료 뒤 전투 생성과 첫 턴 initializer 호출
- setup 완료 전 정상 생성을 막아야 할 경우의 `main.lua` 훅 변경안

`main.lua` 변경이 필요해지면 실제 diff와 각 훅의 의도를 먼저 보고하고 별도 승인을 받은 뒤 수정한다.
