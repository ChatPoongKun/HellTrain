# 전투 런타임 트랜잭션 계약

이 문서는 `System/battleRuntime.lua`가 선택 projection, 턴 해결, 사건 투영과 출력 뒤 상태 반영을 하나의 대기 트랜잭션 경계로 묶는 방식을 정의한다. 스키마 버전은 1이다.

## 1. 책임과 경계

`battleRuntime`은 다음 순서만 조정하며 카드 규칙을 직접 판정하지 않는다.

```text
확정 battleState + turnDraftProjection
→ turnDraft.sealProjection
→ turnResolver.resolveTurn
→ turnEventProjector.projectTurn
→ stateSchema.newPendingTurn
→ pendingTurn(awaitingOutput)
→ 정상 출력 도착
→ commitPending
→ 확정 battleState
```

- 새 판정은 `preparePending`에서만 만든다.
- 생성 실패, 재시도와 출력 재생성은 `reusePending`으로 저장 결과를 그대로 재사용한다.
- 정상 출력 뒤 상태 승격은 `commitPending`에서만 수행한다.
- 세 작업 모두 입력을 변경하지 않고 JSON 저장 가능한 새 복제본을 반환한다.
- 전체 정적 데이터가 필요하며 모든 하위 검증의 정적 참조 확인이 성공해야 한다.
- 턴 ID는 호출자가 새로 정하지 않고 `beforeState.turnStartReceipt.turnId`에서 가져온다.

RisuAI 훅, 채팅 변수 저장, 요청 편집, UI 메시지 교체와 다음 턴 초기화는 이 모듈의 책임이 아니다.

## 2. `preparePending`

```lua
runScript(triggerId, "battleRuntime", "preparePending", beforeState, staticData, projection)
```

성공 보고서는 다음 필드를 가진다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    pendingTurn = pendingTurn,
    turnId = pendingTurn.turnId,
    reused = false,
}
```

처리 순서는 고정한다.

1. `stateSchema.validateBattleState`로 active 권위 상태와 전체 정적 참조를 검증한다.
2. 봉인된 `turnStartReceipt`에서 이번 `turnId`를 읽는다.
3. `turnDraft.sealProjection`으로 full projection 전체를 권위 상태에서 다시 재생하고 최소 `projectionReceipt`를 만든다.
4. 검증된 full projection을 `turnResolver.resolveTurn`에 한 번 전달한다.
5. resolver의 `turnResolution`을 `turnEventProjector.projectTurn`에 한 번 전달한다.
6. resolver의 사건·선택·`afterState`와 projector의 `publicResult`·`llmEvent`를 변형하지 않고 `stateSchema.newPendingTurn`에 넣는다.
7. 생성한 pending의 strict shape와 projection 영수증 재생을 다시 검증한 뒤 반환한다.

어느 단계든 실패하면 `pendingTurn`을 반환하지 않는다. `beforeState`, projection과 RNG는 변경하지 않는다. 같은 입력으로 다시 호출하면 별도 Lua 프로세스에서도 같은 pending이 나와야 한다.

## 3. `reusePending`

```lua
runScript(triggerId, "battleRuntime", "reusePending", currentState, staticData, pendingTurn)
```

성공 보고서 형식은 `preparePending`과 같고 `reused = true`다.

- `stateSchema.validatePendingTurn`과 `turnDraft.validateProjectionReceipt`를 호출할 때마다 다시 수행한다.
- 아직 반영 전이면 현재 확정 상태는 `pendingTurn.beforeState`와 정확히 같아야 한다.
- 이미 `currentState.lastCommittedTurnId == pendingTurn.turnId`이면 출력 재생성으로 보고 같은 pending을 반환한다. 이 뒤의 `commitPending`은 no-op이므로 상태를 두 번 적용하지 않는다.
- 현재 상태가 위 두 관계 중 어느 쪽도 아니면 오래된 pending으로 보고 거부한다.
- resolver와 projector는 다시 호출하지 않는다. 저장된 `turnResult`, `llmEvent`와 `afterState`를 그대로 복제한다.
- 반환 복제본을 변경해도 저장 pending과 현재 상태가 바뀌지 않아야 한다.

따라서 생성 실패나 재생성은 난수를 다시 소비하거나 캐릭터 카드를 다시 고르지 않는다.

## 4. `commitPending`

```lua
runScript(triggerId, "battleRuntime", "commitPending", currentState, staticData, pendingTurn)
```

최초 반영 성공:

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    state = pendingTurn.afterState,
    turnId = pendingTurn.turnId,
    applied = true,
}
```

멱등 재호출 성공은 현재 상태를 그대로 복제해 반환하고 `applied = false`다.

- pending shape와 projection 영수증은 반영 직전에도 다시 검증한다.
- `battleId`가 다르면 거부한다.
- `currentState.lastCommittedTurnId == pendingTurn.turnId`이면 이미 반영한 것으로 보고 아무 상태도 덮어쓰지 않는다. 다음 턴 initializer가 실행된 뒤 늦게 같은 출력 훅이 다시 와도 현재 상태를 보존한다.
- 아직 반영하지 않았다면 현재 상태가 `pendingTurn.beforeState`와 정확히 같을 때만 `afterState`를 반환한다.
- 위 두 경우가 아니면 stale/conflict로 거부한다. 오래된 pending으로 더 새로운 상태를 되돌리지 않는다.
- `commitPending`은 다음 턴 initializer를 호출하거나 pending 저장값을 삭제하지 않는다. 훅 연결 계층이 성공 보고서를 저장한 뒤 그 작업을 수행한다.

## 5. 실패와 하위 오류

실패 보고서는 다음 형식이다.

```lua
{
    ok = false,
    schemaVersion = 1,
    errors = {
        { code = "...", path = "...", message = "..." },
    },
}
```

하위 모듈의 구조화 오류 코드는 보존한다. 예외, 비테이블 반환, 불완전한 정적 데이터, stale projection, malformed pending, 영수증 재생 실패와 권위 상태 충돌은 모두 fail-closed다.

## 6. 저장 무결성과 신뢰 경계

`preparePending`은 같은 호출 안에서 성공한 resolver와 projector의 출력을 직접 조립하므로 새 pending을 만드는 동안 의미가 연결된다. `stateSchema.newPendingTurn`은 마지막에 자신을 제외한 pending 전체를 정규화해 `canonical_poly131_137_pending_v1` 무결성 영수증을 붙인다. `validatePendingTurn`은 저장 뒤 `turnResult.events`, `publicResult`, `llmEvent`, `beforeState`, `afterState` 또는 다른 필드 하나라도 달라지면 거부한다.

`reusePending`과 `commitPending`은 이 영수증을 검증하므로 재판정하지 않고도 처음 만든 묶음이 그대로인지 확인할 수 있다. 단, 이 fingerprint는 비밀 키가 없는 결정적 손상 탐지 수단이다. `stateSchema.newPendingTurn`을 직접 호출할 권한이 있는 악성 코드가 값을 바꾸고 영수증까지 다시 만드는 공격을 막는 인증 수단은 아니며, 그런 위협 모델이 필요하면 keyed seal을 별도로 도입한다.

## 7. 로컬 검증 범위

`.agents/Tests/battle-runtime-check.ps1`은 다음을 검사한다.

- projection 봉인 → resolver 1회 → projector 1회 → pending 조립 순서
- 직접 실행한 resolver/projector 출력과 pending 필드의 동일성
- 같은 입력과 별도 Lua 프로세스의 결정성
- 입력 불변성과 반환 alias 차단
- 재사용 시 resolver/projector 미호출
- malformed pending, 변조된 projection 영수증·`afterState`·LLM 사건, stale 상태와 다른 전투의 거부
- projector 실패 시 pending 미생성
- 최초 반영과 같은 `turnId`의 두 번째·늦은 반영 no-op

실제 RisuAI 로어북 호출, 채팅 변수 지속성, 제한된 `onStart`, `editRequest`, `onOutput`, 프롬프트와 UI 교체는 이 검사에 포함되지 않는다.
