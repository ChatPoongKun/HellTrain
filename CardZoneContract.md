# 카드 영역과 결정적 난수 계약 v1

## 1. 범위

`System/deterministicRng.lua`와 `System/cardZones.lua`는 UI, LLM, 카드 효과 해석과 승패 판정을 알지 못하는 순수 전투 기반 모듈이다. 모든 action은 입력 테이블을 변경하지 않고 새 결과를 반환한다.

카드 해결 도중의 `state`는 선택된 카드가 이미 `used`, `removed` 또는 `plan`으로 이동했어도 턴의 원래 선택 ID를 유지하는 내부 `workingState`다. 따라서 중간 결과를 저장, View 생성이나 `stateSchema.validateBattleState`에 사용하지 않는다. `endTurnCleanup`이 선택과 의도를 비운 뒤 전투 엔진이 나머지 턴 필드를 정리한 최종 상태만 확정 `battleState`로 검증·저장한다.

이 모듈의 카드 영역은 다음 여섯 가지다.

```text
deck, hand, used, discard, removed, plan
```

각 카드는 `cardInstances`에 정확히 한 번만 존재한다. 영역 내부 순서는 `position = 1..n`으로 연속되며 `deck`의 1번이 다음 드로우 카드다.

## 2. 결정적 난수

RNG 상태는 다음 두 안전 정수만 저장한다.

```lua
{ seed = 12345, cursor = 0 }
```

`seed`는 전투 중 바뀌지 않고 표본을 소비할 때마다 `cursor`만 증가한다. 구현은 `park_miller_schrage_v1` 알고리즘과 rejection sampling을 사용하며 `math.random`이나 전역 난수 상태를 사용하지 않는다.

지원 action은 다음과 같다.

| action | 입력 | 결과 `value` |
|---|---|---|
| `validate` | `rng` | 복제한 RNG 상태 |
| `nextInteger` | `rng, minimum, maximum` | 닫힌 범위 정수 |
| `shuffle` | `rng, array` | Fisher-Yates로 섞은 새 배열 |

같은 RNG 상태와 같은 배열은 Lua 프로세스가 달라도 같은 결과와 다음 커서를 만들어야 한다. 양측이 RNG 하나를 공유하므로 실제 세션 시작 조립기는 셔플 호출 순서를 고정해야 한다. 카드 영역 v1은 저수준 셔플만 제공하며 세션 초기화 연결과 진영 순서는 아직 확정하지 않았다.

## 3. 카드 영역 action

성공 결과는 다음 공통 필드를 가진다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    state = newWorkingState,
    movedInstanceIds = {},
    drawnInstanceIds = {},
}
```

지원 action은 다음과 같다.

| action | 역할 |
|---|---|
| `shuffleDeck(state, owner)` | 현재 덱만 결정적으로 섞음 |
| `draw(state, owner, amount)` | 최대 손패의 빈자리까지만 현재 턴 손패로 드로우 |
| `moveHandToUsed(state, instanceId)` | 선언한 카드를 턴 종료 전까지 재드로우되지 않는 `used`로 이동 |
| `moveUsedToHand(state, instanceId)` | 아직 선언하지 못한 등록 카드를 `used`에서 현재 손패 끝으로 복원 |
| `moveToRemoved(state, instanceId)` | 카드를 이번 세션에서 제외되는 `removed`로 이동 |
| `placePlan(state, side, instanceId, planSpec)` | 기존 계획을 버리고 새 계획을 단일 슬롯에 배치 |
| `consumePlanCharge(state, side)` | 성공 발동을 공개하고 충전을 소비하며 0이면 즉시 버림 |
| `endTurnCleanup(state)` | `used`, 남은 `hand`, 만료 계획을 정해진 순서로 정리 |
| `validateConservation(beforeState, afterState)` | 카드 보존, 위치와 계획 슬롯 정합성을 검사 |

`owner`와 `side`는 `player` 또는 `character`다.

## 4. 드로우와 턴 종료

양측 기본값은 `baseDrawCount = 3`, `maxHandSize = 5`다. 턴 시작 엔진은 `draw`에 기본 드로우 수를 전달한다. `draw_cards` 효과도 같은 action을 해결 중 호출하므로 눈치보기의 1장은 다음 턴 보너스가 아니라 현재 턴 손패에 즉시 들어간다.

덱이 비면 같은 소유자의 `discard` 전체만 섞어 덱으로 되돌린 뒤 남은 수량을 뽑는다. `hand`, `used`, `removed`, `plan`은 재섞기에 포함하지 않는다. 덱과 버림을 모두 사용해도 부족하면 가능한 수량만 드로우한다.

턴 종료의 버림 순서는 기존 `discard` 뒤에 `used`의 사용 순서, 남은 `hand`의 손패 순서다. `removed`와 점유 중인 `plan`은 유지한다. 플레이어 선택과 캐릭터 의도는 빈 목록으로 초기화한다.

projection에서 미리 `used`로 옮긴 플레이어 카드가 앞선 해결 때문에 사용할 수 없게 되면 턴 해결기는 `moveUsedToHand`를 현재 카드부터 선택 순서대로 호출한다. 복원 카드는 기존 손패 뒤에 붙는다. 앞 효과의 드로우가 빈자리를 이미 채웠다면 이 내부 workingState의 손패는 구조 정리가 끝날 때까지만 `maxHandSize`를 넘을 수 있다. 이는 드로우가 상한을 넘긴 것이 아니라 projection의 미선언 카드를 원래 의미대로 되돌리는 구조적 복원이며, 일반 View나 저장 상태로 노출하지 않는다. 이미 해결한 접두 카드는 `used`에 남고, 복원 카드는 같은 턴 `endTurnCleanup`에서 미사용 손패로 버려져 최종 `battleState`는 다시 손패 상한을 만족해야 한다.

현재 턴에 새로 뽑은 카드를 같은 턴 선택에 추가하는 UI 흐름은 카드 영역 모듈의 책임이 아니다. 승인된 `turnDraft`가 권위 상태와 RNG를 변경하지 않은 채 선택 프리뷰를 다시 계산하고, 전송 projection에서만 이 모듈의 `moveHandToUsed`와 `draw`를 권위 상태의 복제본에 적용한다. 상세 상태 전이는 `TurnDraftContract.md`를 따른다.

## 5. 계획 수명

`placePlan`의 `planSpec`은 `durationTurns`, `charges`, `revealed`만 허용하며 지속시간이나 충전 중 하나 이상은 양의 정수여야 한다.

정적 카드 계약이 허용하는 `expires` 함수만의 계획은 아직 JSON 런타임 표식과 공통 폐기 action이 확정되지 않았다. 카드 영역 v1은 이런 계획을 배치하지 않으며, 현재 프로토타입의 두 계획처럼 `durationTurns` 또는 `charges`가 있는 정의만 지원한다.

- 새 계획을 놓으면 기존 계획은 `discard`로 이동한다.
- 배치 턴에는 지속시간을 감소시키지 않는다.
- 다음 턴부터 턴 종료에 지속시간을 1 감소시킨다.
- 감소 결과가 0이면 그 턴 종료에 즉시 버린다.
- 성공 발동 후 충전이 0이면 다른 수명이 남아 있어도 즉시 버린다.
- 간파로 억제된 발동은 `consumePlanCharge`를 호출하지 않는다. 지속시간은 턴 종료에 정상 감소한다.
- 점유 슬롯에는 0인 `remainingTurns`나 `remainingCharges`를 저장하지 않는다.

## 6. 보존 검사

영역 action 전후에는 필요에 따라 `validateConservation`으로 다음을 확인한다.

- 모든 기존 `instanceId`가 이후 상태에도 정확히 한 번 존재한다.
- 새 인스턴스가 영역 이동 중 생기지 않는다.
- 같은 인스턴스의 `cardId`와 `owner`가 바뀌지 않는다.
- 모든 영역의 `position`이 1부터 중복 없이 이어진다.
- `plan` 영역의 인스턴스와 같은 소유자의 점유 슬롯이 양방향으로 정확히 연결된다.
- 0 수명 계획이 완료 상태에 남지 않는다.

`Tests/deterministic-rng-check.ps1`과 `Tests/card-zones-check.ps1`은 로컬 결정성, 카드 보존과 10턴 영역 순환을 검증한다. 실제 RisuAI 로어북 호출은 별도 통합 단계에서 확인한다.
