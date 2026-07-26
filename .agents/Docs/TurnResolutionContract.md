# 턴 해결과 사건 로그 계약 v1

## 1. 범위와 권위 경계

`System/turnResolver.lua`는 사용자가 전송한 선택을 UI와 LLM 없이 결정적으로 해결하는 순수 모듈이다. 버전 1의 진입점은 다음 형태다.

```text
resolveTurn(authoritativeState, staticData, projection, { turnId = "battle-0001-turn-001" })
```

입력 `authoritativeState`는 현재 확정된 `active` 전투 상태이고 `projection`은 같은 상태에서 만든 `turnDraftProjection`이다. 해결기는 옵션과 `turnStartReceipt`의 턴 식별자를 먼저 대조한 뒤 `turnDraft.validateProjection(authoritativeState, staticData, projection)`을 호출해 projection을 권위 상태에서 다시 재생한다. 호출자가 넘긴 `projection.workingState`를 단독으로 신뢰하거나 현재 상태에 맞춰 자동 보정하지 않는다.

```text
권위 battleState(+ turnStartReceipt) + 정적 DB + turnDraftProjection
→ projection 전체 재생 검증
→ 플레이어 카드 해결
→ 캐릭터 의도 카드 해결
→ 턴 종료 판정·무드·구조 정리
→ turnResolution(JSON) + afterState(JSON)
```

- 모든 성공·실패 경로는 입력 상태, 정적 DB와 projection을 변경하지 않는다.
- 같은 입력과 `turnId`는 사건 배열까지 같은 결과를 만든다. 콜백에서 현재 시각, 전역 난수와 RisuAI 상태 함수를 사용하지 않는다.
- 하나의 콜백, 명령 또는 최종 상태 검증이 실패하면 부분 상태나 부분 로그를 성공 결과로 반환하지 않는다.
- projection에서 이미 적용한 선택 단계 드로우와 플레이어 등록 카드의 `hand → used` 이동은 다시 적용하지 않는다.
- `turn_start` 트리거, 기본 드로우와 캐릭터 의도 선택은 projection보다 앞선 턴 초기화 단계의 책임이다. `resolveTurn`은 `turn_start`를 다시 만들지 않는다. initializer는 그 결과를 적용한 권위 상태에 함수 없는 `turnStartReceipt`를 함께 저장한다.
- 영수증이 있으면 `turnId`가 해결 옵션과, `turnNumber`가 현재 상태와 정확히 일치해야 한다. `authorityFingerprint`는 receipt를 제외한 현재 권위 상태 전체와 같아야 하고, `draws`·`characterSelection`은 RNG 순서 및 실제 `characterIntent`와 일치해야 한다. 영수증 사건·기준값·일시 상태는 재실행할 명령이 아니라 initializer가 이미 적용한 결과의 인계값이다. 불일치는 자동 보정하지 않고 해결을 거부한다.
- 영수증이 없는 상태는 기존 저장 상태와 독립 모듈 fixture를 위한 하위 호환 경로다. 이 경우 사건은 빈 배열, 일시 상태는 기본값, 성과 기준은 권위 상태의 현재 수치에서 시작한다. initializer가 연결된 실제 턴은 영수증 경로를 사용한다.
- `main.lua`, UI, `pendingTurn`, 공개 사건과 LLM 사건 변환은 이 순수 해결기의 책임이 아니다.

## 2. 내부 working state와 해결 순서

projection 재생 검증이 반환한 복제본을 다음 내부 값과 함께 사용한다.

```lua
local receipt = authoritativeState.turnStartReceipt -- 없으면 legacy fallback
local working = {
    state = validatedProjection.workingState,
    transient = {
        skipRemaining = receipt and receipt.transient.skipRemaining
            or { player = false, character = false },
        forcedMoodRequests = receipt and receipt.transient.forcedMoodRequests or {},
        halted = false,
        haltReason = nil,
    },
    startValues = receipt and receipt.baseline or currentAuthorityValues,
    events = receipt and clone(receipt.events) or {},
    nextResolutionOrdinal = 1,
    nextEventOrdinal = #(receipt and receipt.events or {}) + 1,
}
```

`receipt.events`는 `turn_start` phase의 연속 사건 배열이어야 하며 `turnId-event-001..n`을 이미 점유한다. 해결기가 만드는 첫 사건은 `n + 1`부터 이어진다. `forcedMoodRequests`는 턴 시작 트리거에서 발생한 강제 변경 요청을 카드 해결 단계로 인계한다.

플레이어 카드는 `projection.selectedCardInstanceIds` 순서로 먼저 해결한다. 그 다음 `working.state.characterIntent.cardInstanceIds` 순서로 캐릭터 카드를 해결한다. 자동으로 발동한 계획, 특징, 퍽과 환경은 카드 사용이 아니므로 별도의 `card_declared` 또는 `card_resolved` 입력 사건을 만들지 않으며 다른 계획을 재귀적으로 발동시키지 않는다.

`skip_actions`의 `scope = "remainingTurn"`은 지정한 진영에서 아직 선언하지 않은 카드만 생략한다. 이미 끝난 카드와 반대 진영에는 영향을 주지 않는다. 플레이어 선택은 projection에서 영역 이동이 끝난 상태이므로 생략되거나 사용할 수 없어진 플레이어 카드는 5절의 복원 규칙을 따른다.

## 3. 비용과 수치 계약

버전 1 콘텐츠의 카드 비용, 기본 피해와 명령 수치는 DB에 기록한 값을 그대로 사용한다.

- 최종 은폐 비용은 `max(0, base.stealthCost)`다.
- 플레이어 카드는 선언 직전의 현재 은폐가 최종 비용보다 **클 때만** 사용할 수 있다. `stealth == finalCost`도 사용할 수 없다.
- 사용 가능한 카드의 비용을 먼저 지불한 뒤 `card_declared` 입력 사건을 만든다.
- 은폐와 저항에는 회복 상한을 두지 않는다. 회복 결과가 시작값보다 커져도 그대로 유지한다.
- 기본 저항 피해와 효과 명령의 양은 유한한 0 이상 수다. `draw_cards`의 수량은 양의 정수다.
- 특징의 일반 수치 보정은 현재 지원하지 않는다. 비용·피해의 일반 가산, 배율과 반올림 파이프라인은 실제 보정 콘텐츠가 생길 때 확정한다.
- 지원하지 않는 비어 있지 않은 수치 보정 목록을 발견하면 임의 해석하지 않고 전체 해결을 구조화 오류로 거부한다. 현재 `stateSchema`가 권위 상태와 projection의 비어 있지 않은 `temporaryModifiers`를 먼저 거부하며, 해결기도 이 경계를 다시 확인한다.
- 캐릭터 카드의 `base.stealthCost`와 `base.resistanceDamage`는 버전 1에서 모두 0이어야 한다. 이 두 수치의 캐릭터 측 의미가 승인되기 전에는 비영(非零) 값을 임의 해석하지 않는다.

카드에 `canPlay`가 있다면 읽기 전용 컨텍스트 복사본으로 보호 호출한다. 콜백 오류, 잘못된 반환형과 `lower_snake_case`가 아닌 사유 코드는 원자적 해결 오류다. 플레이어 카드가 정상적으로 `false, reasonCode`를 반환하면 비용 부족과 같은 “현재 카드 사용 불가” 흐름으로 처리한다. 캐릭터 의도 카드가 해결 도중 `false`가 된 경우의 대체 행동·중단 정책은 아직 승인되지 않았으므로 버전 1 해결기는 `character_card_unavailable_policy_pending` 구조화 오류를 반환한다.

## 4. 카드 한 장의 해결 파이프라인

각 카드에는 `turnId` 안에서 단조 증가하는 고유 `resolutionId`를 부여한다. 한 장은 다음 순서로 끝까지 처리한 뒤에만 중간 승패를 확인한다.

1. 현재 상태에서 최종 은폐 비용과 `canPlay`를 계산한다.
2. 플레이어 카드라면 엄격한 `stealth > finalCost`를 확인하고 비용을 지불한다. 캐릭터 카드라면 손패에서 `used`로 옮긴다.
3. `card_declared` 입력 사건을 만들고 공용 `triggerPipeline.run`으로 사건 시작 snapshot에서 반응할 사용 전 트리거를 수집·해결한다.
4. 현재 카드에 `insight`가 있으면 수집한 상대 계획 중 이 `resolutionId`에 인과적으로 속한 계획만 억제한다.
5. 억제하지 않은 사용 전 트리거를 7절의 고정 순서로 적용한다.
6. `base.resistanceDamage`를 적용한다.
7. `resolve(context)`가 반환한 일반 효과 명령을 검증하고 순서대로 적용한다.
8. 그 시점의 현재 무드에 해당하는 `moodEffects[currentMood]`를 보호 호출하고 반환 명령을 적용한다.
9. `card_resolved` 입력 사건을 만들고 공용 `triggerPipeline.run`으로 사용 후 트리거 batch를 수집·해결한다.
10. `plan` 배치, `remove` 이동 또는 일반 `used` 유지 등 카드의 완료 영역을 확정한다.
11. 카드와 모든 사용 후 트리거가 끝난 상태에서만 8절의 중간 승패 checkpoint를 실행한다.

기본 은폐 비용과 기본 저항 피해도 사건 로그에는 효과 적용으로 기록하지만 카드의 `resolve`를 통해 다시 만들지 않는다. `mechanisms` 배열의 작성 순서는 규칙 우선순위를 바꾸지 않는다. `insight`는 현재 해결의 트리거 filtering 단계, `plan`과 `remove`는 카드 완료 단계처럼 각 메커니즘의 고정 시점에서 처리한다.

계획이 성공적으로 발동하면 명령을 모두 적용한 뒤에만 공개하고 충전을 1 소비한다. 충전이 0이면 즉시 버린다. 간파로 억제한 계획은 공개하지 않고 명령과 충전을 소비하지 않으며, 턴 종료 지속시간은 정상적으로 흐른다.

## 5. 뒤 카드가 사용할 수 없어진 경우

플레이어 등록 카드의 사용 가능 여부는 projection 시점이 아니라 각 카드의 선언 직전에 다시 계산한다. 앞 카드의 비용, 환경 또는 계획 때문에 뒤 카드의 현재 은폐가 비용 이하가 될 수 있기 때문이다.

현재 카드가 사용할 수 없으면 다음 규칙을 원자적 rollback 없이 적용한다.

1. 앞에서 이미 해결한 카드, 효과, 트리거, 선택 단계 드로우와 RNG 소비는 그대로 유지한다.
2. 현재 카드와 그 뒤의 플레이어 등록 카드는 선언하지 않는다. 이 카드들 때문에 `card_declared`, 계획 발동, 기본 피해와 카드 효과가 생기지 않는다.
3. 아직 해결하지 않은 등록 카드 인스턴스를 `used → hand`로 선택 순서대로 복원한다. 기존 손패 뒤에 현재 카드부터 차례로 붙이고 `position`을 다시 연속화한다.
4. 복원 카드는 사용하지 않은 카드로 취급하므로 같은 턴의 일반 `endTurnCleanup`에서 남은 손패 순서대로 버린다.
5. 플레이어 행동열만 중단한다. 승패가 아직 확정되지 않았고 캐릭터가 `skip_actions` 대상이 아니라면 캐릭터 행동열은 계속 해결한다.

projection 전체나 이미 해결한 접두 구간을 되돌리지 않는다. 대표적으로 은폐 4, `uncrowded` 환경에서 `read_the_room → pin_down`을 등록하면 눈치보기 선언으로 은폐가 3이 된 뒤 비용 3인 제압은 `3 > 3`을 만족하지 못한다. 눈치보기만 사용되고 제압은 복원 후 턴 종료에 버려지며 캐릭터 행동은 계속된다.

앞 효과의 드로우가 손패 빈자리를 먼저 채운 뒤 여러 등록 카드를 복원하면 내부 working state에서만 손패가 일시적으로 상한을 넘을 수 있다. 이 예외는 `selection.playerCardInstanceIds`에 여전히 등록되어 있고 실제로 손패에 복원된 카드 수가 초과분을 덮는다는 구조 영수증으로만 허용한다. 새 드로우나 임의 카드 삽입에 이 예외를 사용할 수 없으며, 같은 해결의 구조 정리에서 모두 버려 최종 저장 상태는 반드시 상한을 다시 만족한다.

## 6. 효과 명령과 무드 요청

콜백 반환값은 상태에 적용하기 전에 전체 배열과 모든 명령을 먼저 검증한다. 명령은 DB 배열 순서대로 적용하며 각 실제 변화와 no-op 여부를 사건으로 남길 수 있어야 한다.

- `damage_resistance`, `recover_resistance`, `lose_stealth`, `recover_stealth`는 상한 없이 정확한 양을 적용한다.
- `draw_cards`는 `cardZones.draw`를 사용해 최대 손패의 빈자리까지만 뽑고 같은 RNG를 전진시킨다.
- `skip_actions`는 지정 진영의 아직 선언하지 않은 행동만 중단한다.
- `add_mood_token`은 등록된 `mood`에 1 이상의 정수 `amount`를 즉시 누적한다.
- `force_mood`는 등록된 목표 `mood`를 `forcedMoodRequests`에 추가한다. 명령 실행 시점에는 현재 무드를 변경하지 않는다.
- 모든 무드 변경과 토큰 소비는 9절의 턴 종료 판정 한 곳에서만 수행한다.

## 7. 트리거 snapshot과 고정 순서

트리거의 입력 사건과 결과 로그 사건은 서로 다른 자료형이다. 트리거 입력 사건은 현재 batch의 조건 판정에만 쓰는 읽기 전용 값이며 `GameRegistry.db.events`에 등록된 ID를 사용한다. 결과 로그를 다시 트리거 입력으로 공급하지 않는다.

initializer와 resolver는 후보 수집·정렬·조건 판정·명령 적용·계획 공개 및 충전 소비를 각자 복제하지 않고 `System/triggerPipeline.lua`의 `run` 진입점 하나를 사용한다. resolver는 `card_declared`, `card_resolved`, `turn_end`, `session_end`를 이 경로로 보낸다. 현재 카드, 간파 진영과 phase는 옵션으로 전달하며 `session_end`에는 `allowGameplayCommands = false`를 전달한다.

하나의 입력 사건이 시작되면 상태 snapshot을 한 번 만들고 그 snapshot에서 모든 후보의 조건을 수집한다. 앞 트리거의 효과로 뒤 트리거의 이번 batch 참가 여부를 다시 계산하지 않는다. 수집한 후보는 다음 키로 정렬한다.

```text
source category: plan → trait → perk → environment
side within category: event의 acting side → opposing side → ownerless
stable source: sourceId ASCII 오름차순 → 같은 source 안의 선언 index
```

Lua 테이블의 `pairs` 순서는 안정 순서로 사용하지 않는다. `sourceId`와 정적 DB 배열 index를 명시적으로 정렬키에 넣는다. `side`가 없는 사건은 소유 진영 순서를 `player → character → ownerless`로 고정한다.

정렬용 `sourceId`는 계획의 `cardId`, 특징의 `traitId`, 퍽의 `perkId`, 환경의 `environmentId`다. 하나의 source에 트리거가 여러 개면 정적 정의 배열의 1-based index를 마지막 키로 사용한다.

`perk` 순서 lane과 실행 경계는 예약되어 있지만 현재 수직 슬라이스에는 실제 퍽 콘텐츠, `Perks.db`와 정적 로더가 없다. 테스트 전용 정적 데이터로 순서를 검증하고, 실제 퍽을 추가할 때 DB·로더·상태 참조 검증을 함께 연결한다.

환경처럼 `event`와 `side`만 선언한 후보는 그 필드로 일치 여부를 판정한다. 계획 등 추가 `trigger(context, inputEvent)`가 있는 후보는 동일한 snapshot과 같은 입력 사건을 받는다. 조건 콜백 오류나 불리언이 아닌 반환값은 전체 턴 해결 오류다. 실제 명령 적용은 수집·filter가 끝난 뒤 위 순서대로 한다.

`insight`는 현재 카드 해결의 `card_declared` batch에서 수집한 **opposing plan**만 제거한다. 같은 사건의 특징, 퍽과 환경은 억제하지 않는다. 다른 카드의 해결, `turn_start`, `turn_end`와 독립 사건의 계획에도 전파되지 않는다. 억제 사실 때문에 숨은 계획 ID나 조건을 공개 사건으로 누출하지 않는다.

파이프라인이 반환한 `records`는 배열 순서 그대로 해결기의 `appendEvent`를 거친다. 이 단계에서 기존 `turn_start` 사건 뒤의 `eventId`와 `sequence`, 현재 `phase`, 카드 `resolutionId` 및 인과를 붙인다. 트리거의 `effect_applied`는 출처 종류에 맞는 `plan_trigger`, `trait_trigger`, `perk_trigger`, `environment_trigger` 인과를 사용하고, 같은 카드 batch의 나머지 기록은 해당 `card_resolution`, 턴 전체 batch는 `turn_event` 인과를 사용한다.

## 8. 중간 승패, 마지막 턴과 종료 처리

중간 승패는 카드 한 장과 그 카드의 사용 후 트리거가 모두 끝난 뒤 확인한다. 트리거 도중 수치가 0을 지났더라도 batch와 해당 카드는 정해진 파이프라인을 끝낸다.

```text
character.resistance <= 0                         → victory
character.resistance > 0 and player.stealth <= 0 → defeat
둘 다 0 이하                                      → victory 우선
```

한 번 정한 결과는 latch되어 뒤 효과로 다시 `active`가 되거나 반대 결과로 바뀌지 않는다. 중간 결과가 생기면 다음을 적용한다.

- 남은 플레이어·캐릭터 카드 행동을 모두 중단한다.
- 일반 gameplay `turn_end` 트리거와 공통 무드 판정을 생략한다.
- 카드 영역 정리, 남은 손패 버림과 계획 수명 감소 같은 구조적 `endTurnCleanup`은 수행한다.
- `session_end` 입력 사건과 세션 종료 기록 처리는 수행하되 latch된 승패는 바꾸지 않는다.

현재 `turnNumber == turnLimit`인 마지막 허용 턴은 플레이어와 캐릭터의 카드 행동 및 각 카드의 post-trigger까지 전부 해결한다. 그 뒤 승리가 아니면 은폐가 남아 있어도 `defeat`를 latch한다. 이 제한 턴 패배는 gameplay `turn_end` 트리거와 공통 무드보다 먼저 확정한다.

정상 종료 단계의 순서는 다음과 같이 고정한다.

1. 양측 행동열이 끝났고 마지막 허용 턴이 아니면 `turn_end` 입력 사건의 gameplay trigger batch를 해결하고 승패를 한 번 더 확인한다.
2. 여전히 active라면 9절의 공통 무드를 적용하거나 명시적 사유로 생략한다.
3. 현재 `turnNumber`에서 구조적 `endTurnCleanup`을 실행하고 소비가 끝난 `turnStartReceipt`를 제거한다. 정리 결과에 영수증이 남으면 전체 해결을 거부한다.
4. 승패가 latch되었다면 정리된 snapshot에서 `session_end` 입력 사건과 세션 종료 처리를 실행한다. session-end 처리는 latch된 결과를 다시 열거나 반대로 바꿀 수 없다.
5. 최종 상태와 카드 보존을 검증한다.

종료 상태는 해결한 현재 `turnNumber`를 유지한다. active 상태로 끝난 경우에만 현재 번호에서 `endTurnCleanup`을 수행한 뒤 `turnNumber`를 1 증가시킨다. 다음 번호의 `turn_start`, 기본 드로우와 캐릭터 의도 조립은 별도 initializer가 담당한다.

버전 1의 `session_end` 트리거는 종료 기록용으로만 실행하며 gameplay 효과 명령을 반환할 수 없다. 명령이 하나라도 있으면 `unsupported_session_end_commands` 오류로 전체 결과를 거부한다. 빈 명령을 반환한 계획이 해당 사건에 정상 반응했다면 기존 계획 발동 규칙에 따라 공개·충전 소비가 일어날 수 있지만 latch된 승패와 gameplay 수치는 바뀌지 않는다.

## 9. 턴 종료 무드 판정

무드 판정은 승패 상태와 관계없이 해결한 모든 턴의 끝에서 정확히 한 번 실행한다.

1. 강제 변경 요청이 정확히 1개면 토큰을 건드리지 않고 그 목표 무드로 결정한다.
2. 강제 변경 요청이 2개 이상이면 요청을 모두 상쇄하고 토큰 판정으로 진행한다.
3. 토큰이 3개 이상인 무드 중 단독 최다가 있으면 그 무드로 결정하고 해당 토큰만 0으로 만든다.
4. 3개 이상인 최다 무드가 둘 이상이면 동률인 무드의 토큰을 각각 1개 차감하고 현재 무드를 유지한다.
5. 3개 이상인 무드가 없으면 무드와 토큰을 유지한다.

`mood_evaluated` 사건은 `forcedCount`, `forceCancelled`, `resolution`, 판정 전후 토큰과 선택적 `targetMood` 또는 `tiedMoods`를 기록한다.

## 10. `turnResolution` 버전 1

성공 결과의 저장 가능한 본문은 다음 형태다.

```lua
{
    schemaVersion = 1,
    kind = "turnResolution",
    battleId = "battle-0001",
    turnId = "battle-0001-turn-001",
    turnNumber = 1,
    source = {
        kind = "turnDraftProjection",
        mode = "action", -- pass | chain_pass | action
        authority = projection.source,
        projectedRng = projection.projectedRng,
    },
    selectedCards = {
        player = { "player-001", "player-004" },
        character = { "character-002" },
    },
    events = {},
    metrics = {
        startingStealth = 30,
        endingStealth = 26,
        startingResistance = 30,
        endingResistance = 23,
        resistancePerformance = 7,
        stealthSpent = 4,
        moodChanged = false,
        moodResolution = "none",
        forcedMoodCount = 0,
    },
    afterState = battleStateSnapshot,
}
```

- `turnNumber`는 해결한 턴의 번호이며 active `afterState.turnNumber`가 다음 번호로 증가해도 바뀌지 않는다.
- `source.authority`와 `source.projectedRng`는 검증된 projection에서 함수 없이 복제한 영수증이다. `workingState`와 preview 전체를 결과에 중복 저장하지 않는다.
- `selectedCards`는 사용자가 등록한 플레이어 선택과 미리 선택된 캐릭터 의도를 기록한다. 뒤에서 사용할 수 없어진 카드도 선택 영수증에는 남으며 실제 선언 여부는 사건 로그가 구분한다.
- `metrics`는 진단과 공통 무드 계산의 수치다. 영수증이 있으면 시작 수치는 `turnStartReceipt.baseline`, 없으면 권위 상태의 현재 수치다. 공통 무드를 생략해도 성과 세 값은 결정적으로 기록하고 `commonMoodApplied = false`로 둔다.
- `afterState.lastCommittedTurnId = turnId`이고 `afterState.turnStartReceipt`는 존재하지 않는다. 선택과 캐릭터 의도는 비우고, 카드 위치와 계획 슬롯을 정리한 뒤 전체 정적 참조를 포함한 `stateSchema.validateBattleState`를 통과해야 한다.

`turnResolution`은 내부 판정 원본이다. 숨은 계획과 캐릭터 카드가 포함될 수 있으므로 그 자체를 `battleView`, 공개 결과나 LLM 요청에 복사하지 않는다. 공개/LLM 변환기는 별도의 허용 목록으로 새 객체를 조립한다.

## 11. 사건 로그 버전 1

`events`는 발생 순서대로 `sequence = 1..n`인 연속 배열이다. `turnStartReceipt`가 있으면 검증된 `receipt.events`를 복제해 배열 앞에 그대로 두고 해결 사건을 다음 순번부터 덧붙인다. 해결기는 이 사건들을 다시 트리거로 실행하지 않는다. 모든 항목의 공통 형태는 다음과 같다.

```lua
{
    eventId = "battle-0001-turn-001-event-001",
    sequence = 1,
    type = "card_declared",
    phase = "player_card",
    resolutionId = "battle-0001-turn-001-resolution-001", -- 턴 전체 사건이면 생략
    side = "player",                                    -- 진영이 없으면 생략
    source = {
        kind = "card",                                  -- card | plan | trait | perk | environment | system
        id = "read_the_room",
        instanceId = "player-001",                      -- 인스턴스가 없으면 생략
    },
    cause = {
        kind = "card_resolution",
        resolutionId = "battle-0001-turn-001-resolution-001",
        -- eventId는 직접 원인 사건이 따로 있을 때만 둔다.
    },
    payload = {
        cardId = "read_the_room",
        instanceId = "player-001",
        finalStealthCost = 0,
    },
}
```

- `eventId`와 `resolutionId`는 `turnId`와 단조 증가 ordinal로 만든다. 영수증 사건이 `event-001..n`을 사용했다면 해결기의 첫 사건은 `event-(n+1)`이다. 테이블 주소, 현재 시각과 난수를 사용하지 않는다.
- `type`과 `phase`, `source.kind`, `cause.kind`는 `lower_snake_case`다.
- `phase`는 적어도 `player_card`, `character_card`, `turn_end`, `session_end`, `cleanup`을 구분한다.
- `source`는 실제 효과나 상태 전이의 정적 출처다. `cause`는 그 출처가 이번에 실행된 직접 인과를 가리킨다.
- `payload`는 적어도 하나의 사건별 필드를 가진 JSON 객체이며 사건 종류별 허용 목록만 사용한다. 자료가 없는 사건은 빈 `{}`를 배열과 혼동하게 두지 말고 payload 자체를 생략할 수 있는 사건 종류로 명시한다. 정적 DB 함수, 전체 카드 정의, callback context와 비공개 plan 정의를 넣지 않는다.
- 실제 상태 변경 사건은 최소한 변경 대상, 이전 값, 이후 값과 적용량을 payload로 재현할 수 있어야 한다. no-op은 이전 값과 이후 값이 같다는 사실과 사유를 구분한다. 드로우는 대상의 전후 `deck`·`hand`·`discard` 인스턴스 순서와 RNG 영수증을, 제거 이동은 출발·도착 영역을 함께 기록한다.

최소한 다음 판정은 서로 구분되는 사건으로 기록한다.

| 사건 범주 | 필요한 정보 |
|---|---|
| 카드 선언·해결 | 카드 인스턴스, 진영, 비용, 해결 ID |
| 효과 명령 | `op`, 대상, 이전·이후 값, 실제 적용량, `cause` |
| 트리거 | source category/ID, 입력 사건, 해결 또는 억제 결과 |
| 계획 | 배치, 공개 발동, 충전 소비, 즉시 버림 또는 지속시간 만료 |
| 행동열 중단 | 진영, 사유 코드, 선언하지 않은 카드 ID 배열 |
| 무드 | 성과, 적용 기준·방향, 이전·이후 무드, 적용 또는 생략 사유 |
| 승패 | `victory` 또는 `defeat`, 원인과 checkpoint |
| 정리 | `used`·남은 `hand` 버림, 계획 수명, 턴 번호 전이 |

트리거 입력 사건과 로그 사건이 같은 `type` 문자열을 가질 수는 있지만 같은 객체가 아니다. 로그 기록을 순회해 새 트리거를 만들거나 로그의 `payload`를 조건 콜백 컨텍스트로 재사용하지 않는다.

## 12. 실패, 결정성과 완료 검증

실패 결과는 공통 `ok = false`, `schemaVersion = 1`, 구조화 `errors`를 반환하고 `turnResolution` 또는 변경된 상태를 성공값처럼 제공하지 않는다. projection stale/mismatch, 콜백 오류, 잘못된 명령, 알 수 없는 정적 참조, 카드 보존 실패와 최종 상태 검증 실패가 여기에 포함된다.

대표 검증은 다음을 포함한다.

- 무선택 `pass`, 눈치보기 단독 `chain_pass`와 연계+주 행동의 순서
- 같은 `card_declared`에 반응하는 계획과 `uncrowded` 환경의 snapshot·source 순서
- `insight`가 현재 해결의 상대 계획만 숨은 채 억제하고 환경은 적용하는 경우
- 은폐 4에서 눈치보기 뒤 제압이 사용할 수 없어 제압만 복원되는 경우
- 플레이어 카드 전부 해결 후 캐릭터 카드가 실행되거나 `skip_actions`로 생략되는 경우
- 카드 post-trigger 뒤 중간 승패, 동시 0의 승리 우선과 남은 행동 중단
- 마지막 허용 턴의 완전한 카드 해결 뒤 제한 턴 패배와 무드 판정
- 단독 최다 토큰, 최다 동률 차감, 단일 강제 변경과 다중 강제 변경 상쇄
- `turnStartReceipt`의 turnId/turnNumber, authority fingerprint, 드로우 RNG, 캐릭터 의도 불일치와 사건 ID 위변조 거부
- 영수증 사건 보존과 후속 event ordinal 연속성, baseline 토큰, skip/forcedMoodRequests 인계 및 정리 후 제거
- 모든 카드 영역 보존, 연속 position, 0 수명 계획 부재와 입력 불변성
- 같은 입력을 별도 Lua 프로세스에서 반복했을 때 afterState와 사건 로그의 동일성

실제 `pendingTurn` 생성, RisuAI 훅, View와 LLM 사건 변환은 이 계약의 순수 결과가 검증된 다음 단계에서 연결한다. `System/main.lua` 변경이 필요하면 변경 건마다 정확한 계획, 의도와 diff를 먼저 제시하고 승인받는다.
