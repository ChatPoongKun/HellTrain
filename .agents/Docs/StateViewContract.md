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
→ turnEventProjector(publicResult / llmEvent 허용 목록)
→ battleRuntime(봉인·조립·재사용·멱등 확정)
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

    -- 턴 초기화가 끝난 active 상태에서만 존재하는 선택 필드
    turnStartReceipt = nil,
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

### 턴 시작 영수증

`turnStartReceipt`는 현재 턴의 `turn_start` batch, 기본 드로우와 캐릭터 의도 선택을 마친 권위 상태임을 나타내는 함수 없는 영수증이다. 아직 초기화하지 않은 active 상태와 전투 종료 상태에는 이 필드를 두지 않는다. 같은 `turnId`로 initializer를 다시 호출할 때는 저장된 영수증을 재사용하며, 다른 `turnId`로 같은 턴을 다시 초기화하지 않는다.

```lua
turnStartReceipt = {
    schemaVersion = 1,
    kind = "turnStartReceipt",
    turnId = "battle-0001-turn-001",
    turnNumber = 1,

    -- 이 receipt 필드를 제외한 초기화 완료 battleState의 canonical fingerprint
    authorityFingerprint = {
        algorithm = "canonical_poly131_137_receipt_v2",
        length = 1842,
        hashA = 123456789,
        hashB = 987654321,
    },

    draws = {
        player = {
            requested = 3,
            drawnInstanceIds = { "player-001", "player-002", "player-003" },
            rngBefore = { seed = 42, cursor = 0 },
            rngAfter = { seed = 42, cursor = 0 },
        },
        character = {
            requested = 3,
            drawnInstanceIds = { "character-001", "character-002", "character-003" },
            rngBefore = { seed = 42, cursor = 0 },
            rngAfter = { seed = 42, cursor = 0 },
        },
    },

    -- CharacterSelectionContract의 비공개 판정 영수증
    characterSelection = {
        schemaVersion = 1,
        kind = "characterIntentSelection",
        battleId = "battle-0001",
        turnNumber = 1,
        characterId = "yoo_jiyoung",
        selectionContext = {
            turnNumber = 1,
            player = { stealth = 30, handCount = 3 },
            character = { resistance = 30, mood = "ignore" },
            characterHand = {
                {
                    instanceId = "character-003",
                    cardId = "turn_to_corner",
                    actionTag = "evade",
                    handPosition = 1,
                },
            },
        },
        candidates = {
            {
                instanceId = "character-003",
                cardId = "turn_to_corner",
                actionTag = "evade",
                handPosition = 1,
                score = 3,
                projectedPlayerStealth = 30,
                lethal = false,
                weight = 3,
                totals = {
                    recoverResistance = 3,
                    loseStealth = 0,
                    damageResistance = 0,
                    recoverStealth = 0,
                },
                planChargesEvaluated = 0,
            },
        },
        weightedPoolInstanceIds = { "character-003" },
        lethalPriorityApplied = false,
        weightOffset = 0,
        rngBefore = { seed = 42, cursor = 0 },
        rngAfter = { seed = 42, cursor = 0 },
        draw = { kind = "single", totalWeight = 3 },
        selectedInstanceId = "character-003",
        selectedCardId = "turn_to_corner",
        publicActionTag = "evade",
    },

    baseline = {
        stealth = 30,
        resistance = 30,
        mood = "ignore",
        moodTokens = { rejection = 0, suspicion = 0, ignore = 0, confusion = 0, compliance = 0 },
    },

    transient = {
        skipRemaining = {
            player = false,
            character = false,
        },
        forcedMoodRequests = {},
    },

    events = {
        {
            eventId = "battle-0001-turn-001-event-001",
            sequence = 1,
            type = "trigger_resolved",
            phase = "turn_start",
            side = "player",
            source = {
                kind = "plan",
                id = "subtle_approach",
                side = "player",
                instanceId = "player-plan-001",
            },
            cause = { kind = "turn_event" },
            payload = {
                inputEventType = "turn_start",
                commandCount = 1,
            },
        },
    },
}
```

- `turnNumber`는 같은 `battleState.turnNumber`와 일치하고, `turnId`는 `lastCommittedTurnId`와 달라야 한다.
- `authorityFingerprint`는 초기화 완료 `battleState`와 `turnStartReceipt` 전체를 정렬 canonical 형식으로 직렬화하되, 자기참조를 피하기 위해 `turnStartReceipt.authorityFingerprint` 필드 하나만 제외하고 131/137 다항 해시를 적용한 결과다. 필드는 정확히 `algorithm`, `length`, `hashA`, `hashB`이며 알고리즘은 `canonical_poly131_137_receipt_v2`다. `validateBattleState`는 같은 경계로 재계산하여 상태·후보 감사·selectionContext·사건 payload 중 하나라도 달라지면 `receipt_authority_mismatch`로 거부한다.
- initializer만 사용하는 `stateSchema.sealTurnStartReceipt`는 `authorityFingerprint`가 아직 없는 영수증만 받는다. 전체 canonical fingerprint를 계산해 복제 상태에 삽입한 뒤 정적 참조를 포함한 `validateBattleState`를 통과한 봉인 상태만 반환한다. 일반 `fingerprintBattleState`는 미봉인 영수증을 허용하지 않는다.
- `draws.player`와 `draws.character`는 각각 정확히 `requested`, `drawnInstanceIds`, `rngBefore`, `rngAfter`를 가진다. `requested`는 해당 진영의 `baseDrawCount`와 같고, 실제 드로우 ID는 중복 없는 연속 runtime-ID 배열이다. 모든 RNG는 `seed`, `cursor`만 가진 안전한 비음수 정수 객체이며 `player.rngAfter == character.rngBefore`여야 한다.
- `characterSelection`은 `CharacterSelectionContract`의 함수 없는 비공개 영수증을 그대로 보존하되, 모든 top-level·`selectionContext`·candidate·`totals`·`draw`·RNG 필드를 엄격한 allowlist로 검증한다. `battleId`, `turnNumber`, `characterId`는 현재 상태와 같아야 하고 `draws.character.rngAfter == characterSelection.rngBefore`여야 한다.
- 선택 영수증에 카드가 있으면 현재 `characterIntent`는 그 인스턴스와 공개 태그 한 장에 정확히 일치하며, 인스턴스·카드 ID·정적 카드의 `actionTag`도 서로 일치해야 한다. 치명 우선에 따른 `weightedPoolInstanceIds`, 점수 기반 `weightOffset`·후보 가중치와 고정 시드 `draw`도 서로 재계산 가능해야 한다. 패스 영수증은 후보·가중 풀·선택 필드를 갖지 않고 `characterIntent`도 비어 있어야 한다. 선택/패스 선택 필드를 섞은 모순된 영수증은 거부한다.
- `characterSelection.rngAfter`는 선택 직후 RNG다. 그 뒤 `action_tag_revealed` 트리거가 카드 드로우나 재섞기로 RNG를 더 소비할 수 있으므로 최종 `battleState.rng`와 같다고 강제하지 않는다. 최종 RNG를 포함한 전체 권위 상태는 `authorityFingerprint`가 별도로 묶는다.
- persisted receipt 검증은 `selectionContext`로 모든 후보의 정적 효과를 `effectEngine`에서 재평가하고 `deterministicRng.nextInteger`로 roll과 `rngAfter` 전체를 재생한다. 공개 태그 트리거가 수치·무드·손패를 바꿨다면 해당 `effect_applied` 기록을 역산해 선택 시점을 복원한다.
- `baseline`은 `turn_start` 명령을 적용하기 전의 은폐·저항·무드와 무드 토큰이다.
- `transient`에는 `skipRemaining`과 `forcedMoodRequests`만 둔다. 각 강제 요청은 등록된 `mood`와 `lower_snake_case` `cause`를 가진다.
- `events`는 `sequence = 1..n`인 연속 배열이다. `eventId`는 `turnId-event-%03d`, `phase`는 모두 `turn_start`이며 `type`, `source.kind`, `source.id`, 선택적 `cause.kind`는 `lower_snake_case`다.
- `draws`와 `characterSelection`은 같은 턴 재호출의 판정·재현을 위한 비공개 감사 자료다. 일반 사건 payload나 `battleView`·LLM 입력에 그대로 복사하지 않는다. 공개 가능한 캐릭터 선택 정보는 별도 projection의 `publicActionTag`뿐이다.
- `turnDraft`는 receipt를 포함한 권위 상태 전체를 fingerprint한다. `turnResolver`는 receipt의 사건·baseline·transient를 이어받고, 해결을 마치면 receipt를 제거한 뒤 다음 턴 또는 종료 상태를 저장한다.

## 3. `turnDraft` 버전 1

`turnDraft`는 v1 호환 카드 focus, 등록 목록과 결정적 선택 프리뷰를 권위 `battleState`에서 분리한다. 현재 HTML의 상세 disclosure는 로컬 DOM 상태이므로 draft나 View를 갱신하지 않는다. 명시 등록·취소는 입력 상태와 권위 RNG를 변경하지 않고 매번 같은 권위 상태에서 프리뷰를 다시 계산한다. 권위 상태 전체의 결정적 fingerprint가 다르면 stale draft를 자동 보정하지 않고 거부한다.

전송 projection만 권위 상태의 복제본에 등록 카드 이동과 선언형 선택 단계 드로우를 적용한다. 후속 턴 해결기는 권위 상태와 projection을 함께 받아 `turnDraft.validateProjection`으로 선택, preview, RNG와 workingState 전체를 재생·대조한 뒤에만 그 복제본을 사용한다. 이 중간 `workingState`는 카드 해결과 턴 종료 정리가 끝나기 전에는 확정 상태로 저장하거나 일반 View 입력으로 사용하지 않는다.

pending 저장에는 전체 projection 대신 `turnDraft.sealProjection`이 만든 최소 `turnDraftProjectionReceipt`를 사용한다. 영수증은 `schemaVersion`, `kind`, `mode`, `selectedCardInstanceIds`, `source`, `projectedRng`만 가지며 preview·workingState·focus는 포함하지 않는다. 다시 사용할 때는 `turnDraft.validateProjectionReceipt`로 선택을 권위 상태에서 재생해 전체 projection을 복원한다. 선택 스키마와 상태 전이는 `TurnDraftContract.md`, 카드 해결과 사건 원본은 `TurnResolutionContract.md`를 따른다.

## 4. `pendingTurn` 버전 1

대기 트랜잭션은 턴 판정 결과를 정상 출력 전까지 확정 상태와 분리한다.

```lua
{
    schemaVersion = 1,
    kind = "pendingTurn",
    battleId = "battle-0001",
    turnId = "battle-0001-turn-001",
    status = "awaitingOutput",

    beforeState = battleStateSnapshot, -- selection.playerCardInstanceIds = {}
    projectionReceipt = {
        schemaVersion = 1,
        kind = "turnDraftProjectionReceipt",
        mode = "action",
        selectedCardInstanceIds = { "player-001", "player-preview-001" },
        source = projectionSource,
        projectedRng = { seed = 12345, cursor = 1 },
    },
    selectedCards = {
        player = { "player-001", "player-preview-001" },
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
    integrity = {
        algorithm = "canonical_poly131_137_pending_v1",
        length = 12345,
        hashA = 123456789,
        hashB = 987654321,
    },
}
```

- `beforeState`는 현재 확정 상태의 스냅숏이며 플레이어 선택 배열은 항상 비어 있다. draft 선택이나 preview 카드를 권위 상태에 끼워 넣지 않는다.
- `projectionReceipt.source`의 전투·상태·턴·마지막 확정 턴·RNG·전체 상태 fingerprint는 `beforeState`와 같아야 한다. `pendingTurn.turnId`는 `beforeState.turnStartReceipt.turnId`와 같아야 한다.
- `selectedCards.player`는 `projectionReceipt.selectedCardInstanceIds`와, `selectedCards.character`는 `beforeState.characterIntent.cardInstanceIds`와 순서까지 같아야 한다.
- `afterState.lastCommittedTurnId`는 이 트랜잭션의 `turnId`다. 해결이 끝난 상태이므로 `turnStartReceipt`는 없고 플레이어 selection과 캐릭터 intent·공개 행동 태그도 모두 비어 있어야 한다.
- `afterState.rng.cursor`는 최소한 `projectionReceipt.projectedRng.cursor` 이상이어야 한다. `battleRuntime.preparePending`이 resolver·projector의 성공 결과를 직접 조립해 `turnResult`와 `afterState` 의미를 연결하고, 생성 뒤에는 전체 무결성 영수증이 그 저장값이 그대로 유지되었는지 확인한다.
- 재시도와 재생성에서는 저장된 `afterState`와 `llmEvent`를 재사용하고 판정하지 않는다.
- `turnResult.events`는 검증된 `turnResolution.events`에서 가져오며 개별 판정 사건은 `TurnResolutionContract.md`의 사건 로그 스키마를 따른다. `publicResult`와 `llmEvent`는 `turnEventProjector`가 원본의 source·side·phase·cause와 값 타입을 검사한 뒤 각각의 공개 허용 목록으로 새로 조립한다. 숨은 계획, runtime ID, RNG와 선택 감사 정보는 이 경계에서 제거하며 세부 규칙은 `TurnEventProjectionContract.md`를 따른다.
- `integrity`는 `stateSchema.newPendingTurn`이 자신을 제외한 pending 전체를 정규화해 만든 이중 다항 fingerprint다. `validatePendingTurn`은 생성 뒤 `events`, 공개·LLM 투영, `beforeState`나 `afterState` 중 어느 한 값이라도 달라지면 `pending_integrity_mismatch`로 거부한다.
- `battleRuntime.preparePending`은 full projection을 다시 봉인하고 resolver와 projector를 각각 한 번 성공시킨 뒤 그 결과를 변형 없이 pending으로 조립한다. `reusePending`은 shape·전체 무결성과 projection 영수증을 다시 검증하고 resolver/projector를 재실행하지 않는다. 아직 대기 중인 실패·재시도뿐 아니라 같은 `turnId`가 이미 반영된 출력 재생성에도 같은 pending을 돌려준다.
- `battleRuntime.commitPending`은 현재 상태가 `beforeState`와 정확히 같을 때만 `afterState`를 반환한다. 현재 상태의 `lastCommittedTurnId`가 같은 `turnId`라면 이미 반영된 호출이므로 현재 상태를 그대로 반환하며, 그 밖의 stale 상태는 거부한다.
- 같은 해결 시점에 저항과 은폐가 모두 0 이하라면 `afterState.status`는 `victory`다.

`stateSchema.validatePendingTurn`은 strict shape, 위 교차 연결과 전체 무결성을 검사하지만 카드 DB 의미에 따른 선택·프리뷰·RNG 재생은 하지 않는다. 성공 보고서의 `projectionReplayValidated = false`가 이 경계를 명시한다. 소비자는 별도로 `turnDraft.validateProjectionReceipt(beforeState, staticData, projectionReceipt)`를 성공시켜야 한다. `battleView`는 출력 대기 View를 만들 때, `battleRuntime`은 저장 결과를 재사용하거나 확정하기 직전에 이를 수행한다.

`integrity`는 우발적 변경과 무단 필드 편집을 탐지하기 위한 결정적 영수증이지 비밀 키를 사용하는 인증이나 암호학적 보안 경계는 아니다. 생성 API를 직접 호출할 권한이 있는 코드까지 신뢰할 수 없다면 별도의 keyed seal이 필요하다. 세부 조정 순서는 `BattleRuntimeContract.md`를 따른다.

## 5. `battleView` 버전 1

최상위 필드는 다음과 같다.

```text
schemaVersion, kind, battleId, turnId, phase, locked, interactionToken?
turn, environment, player, character, hand, selection, zones, lastTurn, outcome
```

`phase`는 `selecting`, `awaitingOutput`, `ended` 중 하나다. `buildBattleView(state, staticData, context)`의 context는 phase에 따라 엄격히 나뉜다.

draft에서 만든 View는 `turnDraft.interactionToken`이 반환한 `interactionToken`을 가진다. 카드 버튼은 이 값을 인스턴스 ID와 함께 컨트롤러에 전달한다. 선택 가능한 View에는 반드시 존재하고, 종료 View에는 존재하지 않는다. 현재 pendingTurn을 표시하는 출력 대기 View에는 없으며, 다음 턴 draft를 보존한 재생성 잠금 View에는 있으나 버튼은 잠겨 있다.

- active 선택 중에는 `{ draft = turnDraft }`가 필수다. draft를 검증해 focus, 등록 순서와 공개 프리뷰를 만든다.
- active 출력 대기에는 `{ pendingTurn = pendingTurn }`을 사용한다. 먼저 `stateSchema.validatePendingTurn`, 다음으로 전달된 현재 확정 `state`에 대한 `turnDraft.validateProjectionReceipt`를 순서대로 성공시킨다.
- 직전 턴을 즉시 재생성하면서 이미 초기화된 다음 턴 draft를 화면에 유지해야 할 때는 `{ draft = turnDraft, generationLocked = true }`를 사용한다. View는 `awaitingOutput`, `locked = true`가 되며 선택·프리뷰는 보존하되 focus와 입력 가능성은 제거한다.
- `generationLocked`는 생성을 기다리는 active draft에서만 생략하거나 정확히 `true`로 지정한다. pendingTurn과 함께 쓰거나 종료 상태에 전달하면 거부한다.
- 종료 상태에는 draft, 현재 pendingTurn, 생성 잠금을 전달하지 않는다.
- draft와 pendingTurn을 동시에 전달하면 모호한 context로 거부한다.

세 phase 모두 선택적으로 `lastCommittedPending`을 함께 받을 수 있다. 이는 현재 선택 또는 출력 대기 pending과 별개인 직전 확정 턴이다. `battleId`와 `turnId`가 각각 현재 상태의 `battleId`, `lastCommittedTurnId`에 정확히 일치해야 하며, `turnPresentation.build`가 strict 공개 사건 허용 목록으로 만든 `lastTurn`만 View에 넣는다. 원본 `publicResult`나 pendingTurn은 View에 복사하지 않는다. 직전 확정 턴이 없거나 context를 생략하면 `lastTurn = { available = false }`다.

출력 대기 중에는 `locked = true`이며 화면 수치와 zone 수는 항상 첫 번째 인자의 현재 확정 `battleState`를 사용한다. 현재 pendingTurn 대기라면 영수증 재생 결과에서 선택 ID와 공개 프리뷰 ID만 가져오고, 직전 턴 재생성 잠금이라면 현재 draft의 선택과 프리뷰를 그대로 사용한다. 두 경우 모두 focus는 보존하지 않는다. 따라서 대기 View는 필요한 카드 표시를 잠긴 상태로 재현하지만 아직 공개하면 안 되는 판정 결과는 표시하지 않는다.

손패 항목은 다음 공개 필드만 가진다.

```text
slot, origin, instanceId, cardId, name
descriptionSegments, ruleLines
actionTag, mechanisms
baseStealthCost, finalStealthCost
baseResistanceDamage, finalResistanceDamage
playable, reasonCode, selected, selectionOrder
```

`origin`은 권위 손패의 `hand` 또는 재생된 공개 드로우의 `preview`다. 손패를 위치 순서로 먼저 나열하고 아직 권위 zone이 deck·discard에 남아 있는 프리뷰 카드를 그 뒤에 덧붙인다. 등록 카드는 `selected`와 1부터 이어지는 `selectionOrder`로 표시한다.

`selection`은 `count`, `mode`, `hasMainAction`, `canSubmit`, `reasonCode`와 선택 중에만 존재할 수 있는 v1 호환 `focusedInstanceId`를 가진다. 현재 UI는 이 선택적 focus 필드에 의존하지 않는다. `mode`는 `pass`, `chain_pass`, `action` 중 하나다. 잠기지 않았고 등록 카드가 모두 사용 가능하며 연계 뒤 주 행동이 최대 한 장인 정규 순서라면 세 mode 모두 전송할 수 있다. 따라서 무선택 패스와 눈치보기 단독 연계 후 패스도 `canSubmit = true`다.

카드의 `canPlay`, `resolve`, `moodEffects`, `mechanismData`, `narration`과 `prototype`은 View에 들어가지 않는다. 비용과 피해의 최종값은 엔진 보정기가 생기기 전까지 기본값과 같다.

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
- `privateProfile`, `actorThought`, 원본 사건, `beforeState`, `afterState`와 대기 결과는 View에 들어가지 않는다.
- 발동하지 않고 만료되거나 교체된 상대 계획은 `empty`로 돌아가며 과거 정체를 남기지 않는다.
- `lastTurn`은 출력 확정 뒤의 공개 사건만 `{ sequence, type, text }` 요약으로 표시한다. LLM 전용 사건, 캐릭터 일반 카드 ID, 숨은 계획의 카드명과 runtime 식별자는 포함하지 않는다.

## 6. CBS 전용 브리지

RisuAI 채팅 변수는 문자열만 저장한다. 최신 CBS는 JSON 배열·딕셔너리를 읽지만, 중첩 객체를 템플릿에 다시 넣을 때 CBS 인자 구분자 `::`와 중괄호 문장이 충돌할 수 있다.

브리지 버전 1은 다음 규칙을 사용한다.

- Wire format 이름은 `cbs-json-nodes-v1`이다.
- 각 중첩 테이블을 그 노드의 JSON 문자열로 한 층 감싼다.
- 배열 순서는 1부터 `n`까지의 인덱스 순서로 보존하고 객체 키는 정렬해 결정적으로 인코딩한다.
- 숫자와 불리언은 JSON 자료형으로 유지한다.
- 원본 `battleView` 문자열은 일반 텍스트지만 HTML/CBS용 wire의 문자열 스칼라는 `&`, `<`, `>`, 따옴표, 중괄호, 괄호, `:`와 RisuAI 내부 escape 범위 U+E9B8..U+E9BF를 HTML 숫자·이름 엔티티로 바꾼다. 브라우저에는 원문으로 보이되 허용 HTML 태그나 새 `{{...}}`/`::` 구문으로 다시 해석되지 않고, 내부 escape 문자도 RisuAI의 `risuUnescape` 단계에 소비되지 않는다.
- 중첩 노드를 감싸는 JSON 문자열 자체의 구조 문자 `:`, `{`, `}`는 각각 `\u003A`, `\u007B`, `\u007D`로 이스케이프한다.
- 검증과 인코딩이 모두 성공한 뒤에만 `setChatVar`를 호출한다.
- 디코드하거나 상태로 역변환하는 API는 제공하지 않는다.

Lua의 빈 테이블은 자체적으로 빈 배열과 빈 객체를 구분하지 못하므로 브리지 버전 1에서는 항상 `[]`로 인코딩한다. 따라서 View 스키마는 빈 컬렉션만 빈 테이블로 표현하고, 객체에는 적어도 하나의 필수 필드를 둔다. `publish` 성공은 `setChatVar` 호출이 예외 없이 끝났다는 뜻이며 실제 웹 클라이언트의 저장값 재조회나 화면 렌더링까지 확인했다는 뜻은 아니다.

예상 호출 형식은 다음과 같다.

```lua
runScript(triggerId, "dataBridge", "encode", "battleView", view)
runScript(triggerId, "dataBridge", "publish", "battleView", view)
```

공식 View builder가 같은 Lua transaction에서 이미 schema allowlist를 검증한 경우에만 함수 capability를 요구하는 `_encodeCanonical`/`_publishCanonical` 내부 경로를 사용할 수 있다. capability는 bridge가 전달한 purpose와 정확한 View 이름을 모두 확인해야 한다. 이 경로도 JSON-safe 검사는 유지하며, 문자열 버튼이나 일반 `encode`/`publish` 호출은 schema 검증을 우회할 수 없다. `battleController`는 내부 게시 뒤에도 채팅 변수를 다시 읽어 wire가 정확히 저장됐는지 확인한다.

HTML에서는 깊은 `element` 대신 한 단계씩 `dictelement`를 사용한다. `element`는 현재 CBS 구현에서 `0`, `false`와 빈 문자열을 누락값처럼 취급할 수 있기 때문이다. wire에서 꺼낸 표시 문자열은 이미 엔티티 처리됐으므로 템플릿은 이를 다시 가공하지 않고 텍스트 위치에 둔다. 동적 속성에는 스키마가 제한한 runtime ID, enum, 숫자와 `interactionToken`만 사용한다.

```html
{{#each::keep {{dictelement::{{dictelement::{{getvar::battleView}}::hand}}::items}} as card}}
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
- 프리뷰 카드는 손패 뒤에 `origin = "preview"`로 나타나며 선택·출력 대기에서 같은 등록 순서를 재현한다.
- 빈 선택 `pass`와 연계만 선택한 `chain_pass`가 전송 가능하고, 출력 대기 View는 모든 카드를 잠그며 focus를 제거한다.
- projection 영수증 변조, 빈 draft 누락, 모호한 context와 View의 origin·mode·focus 불일치를 거부한다.
- 게시 검증이 실패하면 기존 `battleView` 채팅 변수를 바꾸지 않는다.

`.agents/Tests/local-contract-check.ps1`은 위 항목을 로컬 Lua 호스트에서 검사하고 wire를 스키마 경로대로 한 층씩 다시 해제해 자료형과 순서를 확인한다. 이는 실제 RisuAI의 로어북 검색, `setChatVar` 저장 권한, `getvar`·`dictelement`·`#each` 해석이나 HTML 렌더링을 실행한 검사가 아니다.

실제 HTML 렌더링과 훅 연결은 별도 단계다. `System/main.lua`의 변경이 필요하면 변경 건마다 정확한 계획, 의도와 diff를 먼저 제시하고 승인받는다.
