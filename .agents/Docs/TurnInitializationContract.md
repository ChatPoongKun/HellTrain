# 턴 초기화 계약 v1

## 1. 범위와 진입점

`System/turnInitializer.lua`는 이전 턴 정리가 끝난 권위 `battleState`에서 다음 선택 화면에 필요한 상태를 한 번에 만든다.

```text
prepareTurn(authoritativeState, staticData, { turnId = "battle-0001-turn-002" })
```

성공 결과에는 초기화된 `state`, 빈 플레이어 선택으로 만든 `turnDraft`, `turnStartReceipt`, 비공개 캐릭터 선택 영수증과 양측 드로우 영수증이 들어간다. 이 모듈은 UI, chatVar, LLM 요청과 `main.lua`를 호출하지 않는다.

- 입력 상태와 정적 DB는 변경하지 않는다.
- 하나의 하위 단계라도 실패하면 부분 상태를 성공 결과로 반환하지 않는다.
- 같은 입력과 `turnId`는 상태, RNG, 캐릭터 의도와 사건 순서까지 같은 결과를 만든다.
- 같은 `turnId`의 유효한 `turnStartReceipt`가 이미 있으면 드로우·선택·트리거를 다시 실행하지 않고 같은 상태에서 draft만 재구성하며, receipt에 보존된 드로우·선택 영수증도 같은 값으로 반환한다.
- 다른 `turnId`로 이미 초기화된 상태는 `turn_already_initialized` 오류로 거부한다.

## 2. 선행 상태

새 초기화를 시작하려면 다음 조건을 만족해야 한다.

- `status == "active"`
- 전체 정적 데이터 참조 검증 성공
- `selection.playerCardInstanceIds`가 빈 배열
- `characterIntent.cardInstanceIds`가 빈 배열이고 `publicActionTag`가 없음
- `turnId`가 유효한 런타임 ID이고 `lastCommittedTurnId`와 다름
- 기존 `turnStartReceipt`가 없음

턴 종료 정리는 양측의 `used`와 남은 `hand`를 버리고 선택·의도와 이전 `turnStartReceipt`를 제거한다. 따라서 정상적인 다음 턴 상태는 위 조건을 자연스럽게 만족한다.

## 3. 고정 처리 순서

초기화 순서는 다음과 같다.

1. 입력 상태·정적 참조·옵션 검증
2. 턴 시작 전 은폐·저항·무드를 baseline으로 기록
3. 진영이 없는 `turn_start` 사건을 한 번 생성
4. 공용 트리거 파이프라인으로 `turn_start` 계획·특징·퍽·환경 처리
5. 플레이어 기본 드로우
6. 캐릭터 기본 드로우
7. 캐릭터 손패에서 의도 카드 선택
8. 선택 직전 상태와 `selectionContext`를 대조하고 정적 효과·RNG로 선택 영수증 재생 검증
9. 선택된 주 행동 태그를 공개하고 `action_tag_revealed` 트리거 처리
10. 초기화 영수증을 상태에 부착
11. 전체 상태·카드 보존을 검증하고 빈 `turnDraft` 생성

기본 드로우는 최대 손패를 채우는 동작이 아니라 각 진영의 `baseDrawCount`만큼 뽑는 동작이다. `cardZones.draw`가 `maxHandSize`의 남은 자리까지만 허용한다. 두 진영은 하나의 RNG를 공유하므로 재섞기 난수 소비 순서는 반드시 플레이어 다음 캐릭터다.

`turn_start`는 전역 생명주기 사건이므로 player·character 사건을 따로 만들지 않는다. 진영이 없는 사건에 반응하는 후보의 내부 순서는 공용 트리거 계약의 `player → character → ownerless`를 따른다.

## 4. 캐릭터 카드 선택

`System/characterSelector.lua`는 캐릭터 손패의 현재 카드마다 다음 총효과 점수를 계산한다.

```text
총효과 점수
= recover_resistance
+ lose_stealth
- damage_resistance
- recover_stealth
```

즉 캐릭터가 자신의 저항을 회복하는 양과 플레이어에게 주는 은폐 피해를 같은 유효 방어 효과로 더한다. 반대로 캐릭터 저항 피해와 플레이어 은폐 회복은 점수에서 뺀다. 카드의 일반 `resolve`, 현재 무드의 `moodEffects`와 계획 효과를 보호 호출해 명령을 합산한다.

계획 카드는 실제 전투에서 즉시 발동시키지 않는다. 선택 점수에서만 `mechanismData.plan.selectionAssumption`의 대표 사건이 발생하며 모든 충전이 정상 발동한다고 가정한다. 현재 `silent_glare`는 다음 플레이어 `card_declared`에서 모든 충전이 발동한다는 선언형 가정을 가진다. 이 가정이 실제 trigger 조건과 맞지 않으면 정적 로드 또는 선택을 오류로 중단한다.

선택 우선순위는 다음과 같다.

1. 예상 결과가 플레이어 은폐를 0 이하로 만드는 후보가 하나라도 있으면 그 후보군만 유지
2. 치명 후보가 없으면 손패 후보 전체를 유지
3. 양수 점수는 그대로 가중치로 사용하고 0 이하 점수는 가중치 0으로 사용
4. 모든 후보 점수가 0 이하라면 가장 낮은 점수가 1이 되도록 같은 값을 더해 모두 양의 정수 가중치로 변환
5. 후보가 둘 이상이면 안정 손패 순서와 고정 시드로 가중 추첨

최고점으로 후보를 좁히거나 행동 태그 성향을 별도 가중치로 사용하지 않는다. 후보 한 장과 빈 손패 패스는 RNG를 소비하지 않는다.

버전 1은 캐릭터 주 행동 한 장만 선택한다. 캐릭터 `chain`, 캐릭터 `canPlay`, 등록되지 않은 점수 연산과 비영(非零) 캐릭터 `base` 수치는 임의 해석하지 않고 구조화 오류로 거부한다.

## 5. `turnStartReceipt`

초기화 결과의 함수 없는 권위 영수증은 `battleState.turnStartReceipt`에 저장한다.

```lua
turnStartReceipt = {
    schemaVersion = 1,
    kind = "turnStartReceipt",
    turnId = "battle-0001-turn-002",
    turnNumber = 2,
    baseline = {
        stealth = 30,
        resistance = 30,
        mood = "ignore",
        moodTokens = { rejection = 0, suspicion = 0, ignore = 0, confusion = 0, compliance = 0 },
    },
    transient = {
        skipRemaining = { player = false, character = false },
        forcedMoodRequests = {},
    },
    authorityFingerprint = {
        algorithm = "canonical_poly131_137_receipt_v2",
        length = 0,
        hashA = 0,
        hashB = 0,
    },
    draws = {
        player = {
            requested = 3,
            drawnInstanceIds = {},
            rngBefore = { seed = 42, cursor = 0 },
            rngAfter = { seed = 42, cursor = 0 },
        },
        character = {
            requested = 3,
            drawnInstanceIds = {},
            rngBefore = { seed = 42, cursor = 0 },
            rngAfter = { seed = 42, cursor = 0 },
        },
    },
    characterSelection = {
        kind = "characterIntentSelection",
        selectionContext = {
            -- 행동 태그 공개 직전 수치와 캐릭터 손패 전체
        },
        -- 후보, 점수 가중 풀·평행이동, 추첨과 선택 결과를 담는 비공개 영수증
    },
    events = {},
}
```

`forcedMoodRequests`는 항상 연속 배열로 저장하며, 턴 시작 트리거에서 발생한 요청을 해결기에 그대로 인계한다.

`draws`와 `characterSelection`은 재시도·감사용 비공개 자료다. `characterSelection`의 선택 ID·태그는 실제 `state.characterIntent`, 캐릭터 손패와 정적 카드 정의에 정확히 결합된다. 플레이어 드로우 뒤 RNG와 캐릭터 드로우 전 RNG, 캐릭터 드로우 뒤 RNG와 선택 전 RNG가 각각 같아야 한다. 선택 뒤 행동 태그 공개 트리거가 별도 드로우로 RNG를 더 소비할 수 있으므로 선택 영수증의 `rngAfter`를 최종 상태 RNG와 같다고 가정하지 않는다.

initializer는 행동 태그 공개 전에 실제 선택 직전 상태와 `selectionContext`를 정확히 대조하고 `characterSelector.validateReceipt`로 모든 후보 효과를 재생한다. 저장된 상태를 다시 검증할 때 `stateSchema`도 같은 재생 검증과 `deterministicRng.nextInteger`를 수행한다. 공개 트리거가 허용된 `draw_cards`나 자원·무드 명령을 실행했다면 `action_tag_revealed`에 귀속된 `effect_applied` 기록을 역순으로 적용해 선택 시점 컨텍스트와 손패를 복원한다. 현재 공개 트리거는 기존 손패 카드를 버리거나 이동시키는 명령을 허용하지 않으므로, 이후 드로우 ID만 제외하면 선택 시점 손패 전체를 정확히 결합할 수 있다.

initializer는 먼저 `authorityFingerprint`가 없는 receipt를 권위 상태에 붙인 다음 생성 전용 `stateSchema.sealTurnStartReceipt`를 호출한다. 봉인은 초기화 완료 권위 상태와 receipt 전체를 정규화하되 자기 필드 `turnStartReceipt.authorityFingerprint` 하나만 제외해 `canonical_poly131_137_receipt_v2`를 계산하고, 그 값을 넣은 복제 상태의 전체 검증까지 성공해야 반환된다. 일반 fingerprint API에 불완전 상태를 허용하는 우회 옵션은 없다.

따라서 같은 턴 reuse에서 손패, 영역, 계획, 수치, RNG나 의도뿐 아니라 후보 감사, `selectionContext`, 트리거 사건 payload를 단독 또는 서로 맞춰 함께 변조해도 `receipt_authority_mismatch`로 거부한다. 역산에 쓰는 공개 태그 사건 payload와 선택 컨텍스트를 동시에 바꿔 validator 의미를 우회하는 경우도 이 fingerprint 경계가 차단한다.

초기화 사건은 `turnId-event-%03d` 형식의 연속 ID와 `phase = "turn_start"`를 사용한다. `character_intent_selected`는 선택 여부만, `action_tag_revealed`는 공개 행동 태그만 기록하며 후보·카드 ID·인스턴스 ID·점수와 RNG는 사건 payload에 복사하지 않는다. 트리거 사건에는 미공개 계획 ID 같은 내부 정보가 여전히 포함될 수 있으므로 전체 사건 배열은 권위 내부 로그이며 그대로 UI나 LLM에 전달하지 않는다. 후속 공개 projector가 각 관점에 맞게 숨은 필드를 제거해야 한다.

`turnDraft`는 receipt를 포함한 권위 상태 전체를 fingerprint한다. 초기화 뒤 receipt, 캐릭터 의도, RNG 또는 손패를 바꾸면 기존 projection은 stale로 거부된다.

해결기는 receipt의 사건을 최종 턴 사건 앞부분으로 이어 붙이고, baseline 무드 토큰과 transient 강제 요청을 카드 해결에 인계한다. `endTurnCleanup`은 구조 정리 중 receipt를 제거한다.

## 6. 명시적으로 지원하지 않는 경계

현재 프로토타입 콘텐츠에는 턴 시작 또는 행동 태그 공개만으로 승패 수치를 0 이하로 만드는 효과가 없다. 그런 효과가 추가되면 initializer에서 즉시 세션 종료할지, 묘사 대기 트랜잭션을 만들지 먼저 정해야 한다. 버전 1은 이 경우 `turn_start_outcome_policy_pending` 오류로 중단하며 임의로 드로우나 다음 턴을 진행하지 않는다.

실제 RisuAI 훅 연결, 전투 최초 상태 생성, 공개/LLM 사건 변환과 출력 완료 후 commit은 별도 런타임 단계의 책임이다.
