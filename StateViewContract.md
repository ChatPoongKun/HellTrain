# 전투 상태와 View 계약

이 문서는 정적 Lua DB, 저장 가능한 전투 상태, 출력 대기 트랜잭션과 CBS 화면 데이터 사이의 경계를 정의한다. 스키마 버전 1의 목표는 전투 엔진을 구현하기 전에 함수와 비공개 정보가 세이브나 화면으로 새지 않는 최소 기반을 고정하는 것이다.

## 1. 데이터 경계

데이터는 다음 방향으로만 흐른다.

```text
정적 Lua DB(함수·비공개 정보 포함)
→ 공통 전투 엔진
→ battleState(JSON 저장 가능)
→ turnDraft(JSON 선택 초안) / 전송 projection
→ turnResolution(JSON 판정 원본)
→ pendingTurn(JSON 저장 가능)
→ 명시적 허용 목록 View 생성기
→ battleView(공개 데이터만 포함)
→ CBS 전용 데이터 브리지
→ battleView 채팅 변수
```

- 정적 DB 테이블을 상태나 View에 복사하지 않는다.
- 게임 ID와 레지스트리 열거값은 `lower_snake_case`, `cardId` 같은 스키마 필드명은 lowerCamelCase를 사용한다.
- `battleState`, `turnDraft`와 `pendingTurn`은 문자열, 유한한 숫자, 불리언, 연속 배열과 문자열 키 객체만 가진다.
- 함수, 스레드, userdata, 메타테이블, 순환 참조, 희소 배열과 혼합 키 테이블은 오류다.
- `battleView`는 빈 테이블에서 시작해 화면에 허용한 필드만 새로 조립한다.
- 채팅 변수는 화면 출력물이며 게임 상태의 원본이나 세이브 입력으로 다시 읽지 않는다.

## 2. `battleState` 버전 1

카드의 위치는 `cardInstances` 한 배열에서 `zone`과 `position`으로만 기록한다. 같은 정보를 영역별 배열에도 중복 저장하지 않는다.

```lua
{
    schemaVersion = 1,
    kind = "battleState",
    battleId = "battle-0001",
    status = "active", -- active | victory | defeat
    turnNumber = 1,
    turnLimit = 10,
    environmentId = "uncrowded",
    lastCommittedTurnId = nil,

    rng = {
        seed = 12345,
        cursor = 0,
    },

    player = {
        stealth = 30,
        baseDrawCount = 3,
        maxHandSize = 5,
        perkIds = {},
        planSlot = { occupied = false },
    },

    character = {
        characterId = "yoo_jiyoung",
        resistance = 30,
        mood = "ignore",
        traitIds = { "reserved" },
        baseDrawCount = 3,
        maxHandSize = 5,
        planSlot = { occupied = false },
    },

    cardInstances = {
        {
            instanceId = "player-001",
            cardId = "read_the_room",
            owner = "player",
            zone = "hand", -- deck | hand | used | discard | removed | plan
            position = 1,
            temporaryModifiers = {}, -- 선택 필드, 현재 버전에서는 빈 배열만 허용
        },
    },

    selection = {
        playerCardInstanceIds = {},
    },

    characterIntent = {
        cardInstanceIds = {}, -- 비공개
        publicActionTag = nil,
    },
}
```

`characterIntent.cardInstanceIds`는 판정용 비공개 값이다. 화면에는 `publicActionTag`만 전달한다.

`rng.seed`와 `rng.cursor`는 0 이상이면서 IEEE-754 안전 정수 범위 안에 있어야 한다. `baseDrawCount`는 턴 시작에 시도할 기본 드로우 수이고 `maxHandSize`는 어떤 드로우로도 넘을 수 없는 손패 상한이다. 양측 기본값은 각각 3과 5지만 캐릭터 정의와 효과에 따라 서로 독립적으로 달라질 수 있다. 점유된 계획의 `remainingTurns`와 `remainingCharges`는 존재한다면 항상 1 이상이어야 하며 0이 된 계획은 같은 연산에서 버림 영역으로 이동한 완료 상태만 저장한다.

버전 1은 일반 수치 보정 파이프라인을 지원하지 않으므로 `temporaryModifiers`를 생략하거나 빈 배열로만 둔다. 비어 있지 않은 임의 JSON payload는 상태·projection 경계와 턴 해결기에서 구조화 오류로 거부하며, 실제 보정 콘텐츠를 추가할 때 별도 형식과 연산 순서를 승인한다.

`stateSchema.validateBattleState`와 `validatePendingTurn`은 정적 데이터를 생략하면 구조만 검사하고 `referencesValidated = false`를 반환한다. 전체 정적 데이터를 전달하면 참조까지 검사해 `true`를 반환한다. 일부 컬렉션만 있거나 메타테이블이 섞인 정적 데이터는 구조화 오류이며, 생성 API도 이 값을 그대로 보존한다.

점유된 계획 슬롯은 다음 형식을 사용한다.

```lua
{
    occupied = true,
    cardInstanceId = "character-004",
    cardId = "silent_glare",
    placedTurn = 1,
    remainingTurns = 1,   -- 해당 수명 형식이 있을 때만
    remainingCharges = 1, -- 내부 상태 전용
    revealed = false,
}
```

계획 카드는 `zone = "plan"`인 같은 카드 인스턴스와 일치해야 한다. `remainingTurns`, `remainingCharges` 또는 이후 버전에 추가할 명시적 만료 조건 중 하나 이상으로 수명이 제한되어야 한다.

## 3. `turnDraft` 버전 1

`turnDraft`는 카드 상세 focus, 등록 목록과 결정적 선택 프리뷰를 권위 `battleState`에서 분리한다. 카드 클릭은 입력 상태와 권위 RNG를 변경하지 않고 매번 같은 권위 상태에서 프리뷰를 다시 계산한다. 권위 상태 전체의 결정적 fingerprint가 다르면 stale draft를 자동 보정하지 않고 거부한다.

전송 projection만 권위 상태의 복제본에 등록 카드 이동과 선언형 선택 단계 드로우를 적용한다. 후속 턴 해결기는 권위 상태와 projection을 함께 받아 `turnDraft.validateProjection`으로 선택, preview, RNG와 workingState 전체를 재생·대조한 뒤에만 그 복제본을 사용한다. 이 중간 `workingState`는 카드 해결과 턴 종료 정리가 끝나기 전에는 확정 상태로 저장하거나 일반 View 입력으로 사용하지 않는다. 선택 스키마와 상태 전이는 `TurnDraftContract.md`, 카드 해결과 사건 원본은 `TurnResolutionContract.md`를 따른다.

## 4. `pendingTurn` 버전 1

대기 트랜잭션은 턴 판정 결과를 정상 출력 전까지 확정 상태와 분리한다.

```lua
{
    schemaVersion = 1,
    kind = "pendingTurn",
    battleId = "battle-0001",
    turnId = "battle-0001-turn-001",
    status = "awaitingOutput",

    beforeState = battleStateSnapshot,
    selectedCards = {
        player = { "player-001" },
        character = { "character-004" },
    },

    turnResult = {
        events = {},
        publicResult = {
            schemaVersion = 1,
            events = {},
        },
        llmEvent = {
            schemaVersion = 1,
            events = {},
        },
    },

    afterState = battleStateSnapshot,
}
```

- `beforeState`는 현재 확정 상태의 스냅숏이다.
- `afterState.lastCommittedTurnId`는 이 트랜잭션의 `turnId`다.
- 재시도와 재생성에서는 저장된 `afterState`와 `llmEvent`를 재사용하고 판정하지 않는다.
- `turnResult.events`는 검증된 `turnResolution.events`에서 가져오며 개별 판정 사건은 `TurnResolutionContract.md`의 사건 로그 스키마를 따른다. `publicResult`와 `llmEvent`는 그 원본을 그대로 복사하지 않고 각각의 공개 허용 목록으로 변환한다. 현재 `stateSchema`의 pending v1 validator는 아직 개별 사건의 허용 필드를 전부 검사하지 않고 JSON 저장 가능한 연속 배열 경계만 검사한다.
- 같은 해결 시점에 저항과 은폐가 모두 0 이하라면 `afterState.status`는 `victory`다.

현재 pending v1의 `beforeState.selection`과 `selectedCards.player` 일치 규칙은 권위 손패에 아직 들어오지 않은 프리뷰 카드 선택을 직접 표현할 수 없다. `turnResolution.source`는 권위 `beforeState`와 검증된 projection 영수증을 분리하지만, 실제 전송 연결 전에는 pending 스키마와 validator도 이 영수증을 명시적으로 받도록 개정해야 한다. `beforeState`를 내부 workingState로 몰래 바꾸거나 현재 validator를 우회하지 않는다.

## 5. `battleView` 버전 1

최상위 필드는 다음과 같다.

```text
schemaVersion, kind, battleId, turnId, phase, locked
turn, environment, player, character, hand, selection, zones, outcome
```

`phase`는 `selecting`, `awaitingOutput`, `ended` 중 하나다. 출력 대기 중에는 `locked = true`이며 화면 수치는 `pendingTurn.afterState`가 아니라 View 생성기에 첫 번째 인자로 전달한 현재 확정 `battleState`를 사용한다. View 생성기는 대기 표식에서 `status`와 `turnId`만 읽고 `beforeState`, `afterState`와 `turnResult`를 검증하거나 참조하지 않는다.

손패 항목은 다음 공개 필드만 가진다.

```text
slot, instanceId, cardId, name
descriptionSegments, ruleLines
actionTag, mechanisms
baseStealthCost, finalStealthCost
baseResistanceDamage, finalResistanceDamage
playable, reasonCode, selected, selectionOrder
```

카드의 `canPlay`, `resolve`, `moodEffects`, `mechanismData`, `narration`과 `prototype`은 View에 들어가지 않는다. 비용과 피해의 최종값은 엔진 보정기가 생기기 전까지 기본값과 같다.

현재 `System/viewBuilder.lua`의 battleView v1은 아직 `turnDraft`를 입력으로 받지 않으며 주 행동이 없는 선택을 전송 불가로 계산한다. 이는 승인된 무선택 패스와 눈치보기 단독 패스를 반영하기 전의 임시 UI 계약이다. UI 단계에서 draft focus, 프리뷰 카드, 등록 순서와 세 가지 projection mode를 View 허용 목록에 추가할 때 함께 변경하며, 그 전에는 `battleView.selection.canSubmit`을 새 패스 규칙의 권위 판정으로 사용하지 않는다.

### 태그 조각

카드 설명과 모든 규칙 문장은 `::tag[id]::` 토큰을 다음 조각 배열로 바꾼다.

```lua
{
    { kind = "text", value = " 행동으로 " },
    {
        kind = "tag",
        id = "contact",
        label = "접촉",
        tagKind = "action", -- action | mechanism
        tooltip = "신체 접촉을 시도하는 행동",
    },
}
```

실제로 빈 텍스트 조각은 만들지 않는다. 태그의 표시 정보는 문장이 아니라 `GameRegistry.db`에서 가져온다. 알 수 없거나 잘못 닫힌 토큰, 잘못된 ASCII ID와 행동·메커니즘 레지스트리 충돌은 오류다. View 생성기는 HTML을 만들지 않으며 최종 HTML은 텍스트, 라벨과 툴팁을 모두 이스케이프해야 한다.

### 비공개 정보

- 캐릭터의 미리 선택된 카드는 행동 태그만 공개한다. 카드 ID, 이름, 메커니즘과 규칙은 공개하지 않는다.
- 상대의 미공개 계획은 `status = "hidden"`, 지속시간 존재 여부와 남은 지속 턴만 가진다.
- 공개된 계획도 남은 충전, 조건 함수, 효과 함수와 `mechanismData`를 포함하지 않는다.
- 플레이어 자신의 계획은 정체를 표시할 수 있지만 남은 충전은 버전 1 View에서 표시하지 않는다.
- `privateProfile`, `selectionProfile`, `actorThought`, 원본 사건, `beforeState`, `afterState`와 대기 결과는 View에 들어가지 않는다.
- 발동하지 않고 만료되거나 교체된 상대 계획은 `empty`로 돌아가며 과거 정체를 남기지 않는다.

## 6. CBS 전용 브리지

RisuAI 채팅 변수는 문자열만 저장한다. 최신 CBS는 JSON 배열·딕셔너리를 읽지만, 중첩 객체를 템플릿에 다시 넣을 때 CBS 인자 구분자 `::`와 중괄호 문장이 충돌할 수 있다.

브리지 버전 1은 다음 규칙을 사용한다.

- Wire format 이름은 `cbs-json-nodes-v1`이다.
- 각 중첩 테이블을 그 노드의 JSON 문자열로 한 층 감싼다.
- 배열 순서는 1부터 `n`까지의 인덱스 순서로 보존하고 객체 키는 정렬해 결정적으로 인코딩한다.
- 숫자와 불리언은 JSON 자료형으로 유지한다.
- 문자열 안의 `:`, `{`, `}`는 각각 `\u003A`, `\u007B`, `\u007D`로 이스케이프한다.
- 검증과 인코딩이 모두 성공한 뒤에만 `setChatVar`를 호출한다.
- 디코드하거나 상태로 역변환하는 API는 제공하지 않는다.

Lua의 빈 테이블은 자체적으로 빈 배열과 빈 객체를 구분하지 못하므로 브리지 버전 1에서는 항상 `[]`로 인코딩한다. 따라서 View 스키마는 빈 컬렉션만 빈 테이블로 표현하고, 객체에는 적어도 하나의 필수 필드를 둔다. `publish` 성공은 `setChatVar` 호출이 예외 없이 끝났다는 뜻이며 실제 웹 클라이언트의 저장값 재조회나 화면 렌더링까지 확인했다는 뜻은 아니다.

예상 호출 형식은 다음과 같다.

```lua
runScript(triggerId, "dataBridge", "encode", "battleView", view)
runScript(triggerId, "dataBridge", "publish", "battleView", view)
```

HTML에서는 깊은 `element` 대신 한 단계씩 `dictelement`를 사용한다. `element`는 현재 CBS 구현에서 `0`, `false`와 빈 문자열을 누락값처럼 취급할 수 있기 때문이다.

```html
{{#each {{dictelement::{{dictelement::{{getvar::battleView}}::hand}}::items}} as card}}
  {{dictelement::{{slot::card}}::cardId}}
{{/each}}
```

## 7. 완료 검증

다음은 구현 완료 기준이다. 로컬 순수 함수 검증과 실제 웹 RisuAI의 로어북·CBS 통합 검증을 구분하며, 실제 환경에서 확인하지 않은 항목을 완료로 처리하지 않는다.

- 손패 0·1·3·5장의 순서가 인코딩 후에도 유지된다.
- 숫자 `0`, 불리언 `true`/`false`, 빈 문자열과 빈 배열이 구분된다.
- 같은 View를 반복 인코딩하면 바이트 단위로 같은 결과가 나온다.
- 설명과 규칙의 태그 순서와 한글 원문이 보존된다.
- 함수, 순환 참조, 희소·혼합 키와 알 수 없는 View 필드는 경로를 포함한 오류가 된다.
- 미공개 계획, 캐릭터 선택 카드, 비공개 프로필, 묘사와 충전 수가 인코딩 결과에 없다.
- `awaitingOutput` View에는 `afterState`의 결과가 나타나지 않는다.
- 게시 검증이 실패하면 기존 `battleView` 채팅 변수를 바꾸지 않는다.

`Tests/local-contract-check.ps1`은 위 항목을 로컬 Lua 호스트에서 검사하고 wire를 스키마 경로대로 한 층씩 다시 해제해 자료형과 순서를 확인한다. 이는 실제 RisuAI의 로어북 검색, `setChatVar` 저장 권한, `getvar`·`dictelement`·`#each` 해석이나 HTML 렌더링을 실행한 검사가 아니다.

실제 HTML 렌더링과 훅 연결은 별도 단계다. `System/main.lua`의 변경이 필요하면 변경 건마다 정확한 계획, 의도와 diff를 먼저 제시하고 승인받는다.
