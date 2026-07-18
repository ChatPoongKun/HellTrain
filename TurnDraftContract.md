# 턴 선택 초안 계약 v1

## 1. 역할과 권위 경계

`System/turnDraft.lua`는 카드 상세 열기, 사용 등록·취소와 눈치보기의 현재 턴 드로우 프리뷰를 처리하는 순수 선택 모듈이다. 입력 `battleState`, 카드 영역과 RNG를 직접 변경하지 않으며 모든 action은 새 JSON 테이블을 반환한다.

```text
권위 battleState + 정적 DB
→ turnDraft(JSON 선택 초안)
→ turnDraftProjection(전송 시 다시 계산하는 내부 workingState)
→ turnDraftProjectionReceipt(pendingTurn에 보관하는 최소 재생 영수증)
→ 후속 순수 턴 해결기(`TurnResolutionContract.md`)
→ 정리된 afterState
```

`turnDraft`와 projection의 `workingState`는 확정 전투 상태가 아니다. 특히 projection에서는 등록 카드를 `used`로 옮긴 뒤에도 해결 순서를 나타내기 위해 `selection`이 그 ID를 가리킬 수 있다. 후속 턴 해결과 `endTurnCleanup`을 마친 최종 상태만 `stateSchema.validateBattleState`로 검증·저장한다.

프리뷰는 새 카드 zone을 만들지 않는다. 권위 상태의 카드는 계속 기존 `deck`, `hand`, `discard` 등에 있고 draft에는 인스턴스 ID만 저장한다.

## 2. 선택 단계 효과

같은 턴에 뽑은 카드를 다시 선택하려면 일반 카드 해결보다 앞선 공개 선택 단계가 필요하다. 이 효과는 임의 Lua 콜백을 미리 실행하지 않고 카드 DB의 선언형 `selectionPreview.effects`를 단일 원본으로 사용한다.

```lua
selectionPreview = {
    effects = {
        {
            id = "draw_one",
            op = "draw_cards",
            target = "player",
            amount = 1,
        },
    },
}
```

v1에서는 플레이어 `chain` 카드의 `draw_cards`만 허용한다. 선택 단계 효과와 일반 `resolve`를 한 카드에 함께 두지 않는다. `effectEngine`과 정적 로더가 ID, 작업, 대상, 양의 정수 수량과 허용 필드를 모두 검사한다.

선택 단계에서는 환경, 상대 계획, 특징, 캐릭터 의도와 `card_declared` 트리거를 실행하지 않는다. 따라서 숨은 정보는 프리뷰 결과에 영향을 주거나 프리뷰를 통해 노출되지 않는다.

## 3. `turnDraft` 버전 1

```lua
{
    schemaVersion = 1,
    kind = "turnDraft",
    source = {
        battleId = "battle-0001",
        status = "active",
        turnNumber = 1,
        lastCommittedTurnId = nil, -- nil이면 필드 생략
        rng = { seed = 12345, cursor = 0 },
        fingerprint = {
            algorithm = "canonical_poly131_137_v1",
            length = 1234,
            hashA = 123,
            hashB = 456,
        },
    },
    focusedInstanceId = "player-001", -- 없으면 생략
    registeredCardInstanceIds = { "player-001", "player-004" },
    preview = {
        events = {
            {
                sourceInstanceId = "player-001",
                drawnInstanceIds = { "player-004" },
            },
        },
        drawnInstanceIds = { "player-004" },
        availableDrawnInstanceIds = { "player-004" },
        rng = { seed = 12345, cursor = 0 },
    },
}
```

- `focusedInstanceId`는 상세 표시만 제어하며 사용 등록이나 프리뷰를 만들지 않는다.
- `registeredCardInstanceIds`는 연계 카드들 뒤에 주 행동 0장 또는 1장이 오는 정규 순서다.
- `preview.events`와 RNG는 캐시일 뿐이다. 모든 action과 projection은 같은 권위 상태에서 다시 계산해 저장값과 대조한다.
- `availableDrawnInstanceIds`는 현재 draft UI에 계속 표시할 프리뷰 카드다. 등록되어 내부 `used`로 투영된 카드도 재클릭 취소를 위해 이 목록에 남는다.
- `source.fingerprint`는 RNG뿐 아니라 권위 `battleState` 전체의 정규 표현을 기준으로 한다. 같은 전투·턴·RNG라도 카드 위치나 순서가 바뀌면 stale 오류다.
- stale draft는 자동으로 새 상태에 맞추지 않고 `draft_stale`로 거부한다.

함수, 정적 카드 정의, 전체 workingState와 비공개 콜백은 draft에 저장하지 않는다.

## 4. action

공통 호출 형식은 다음과 같다.

```text
runScript(triggerId, "turnDraft", action, battleState, staticData, draft, instanceId)
```

| action | 역할 |
|---|---|
| `newDraft` | 현재 권위 상태에서 빈 draft 생성 |
| `validate` | 스키마, source, 등록 순서와 프리뷰 재계산 결과 검사 |
| `focusCard` | 상세 표시 카드만 변경 |
| `registerCard` | 카드를 사용 목록에 정규 순서로 등록 |
| `cancelCard` | 등록 카드 취소와 의존 프리뷰 연쇄 정리 |
| `clickCard` | 실제 UI의 첫 클릭 focus, 두 번째 등록, 등록 카드 재클릭 취소 |
| `project` | 전송 시 사용할 선택 단계 workingState를 권위 상태에서 다시 계산 |
| `validateProjection` | 권위 상태에서 선택을 재생해 projection 전체가 변조되지 않았는지 검사 |
| `sealProjection` | 전체 projection 검증 후 pending 저장용 최소 영수증 생성 |
| `validateProjectionReceipt` | 영수증의 선택 ID를 권위 상태에서 다시 재생해 projection과 영수증을 재구성·대조 |

모든 성공·실패 경로는 입력 `battleState`와 입력 draft를 변경하지 않는다. 등록하려는 카드는 원래 플레이어 손패 또는 앞선 등록 카드가 만든 현재 프리뷰에 있어야 한다.

## 5. 등록과 취소 규칙

- 원래 손패 주 행동 `A` 뒤에 다른 주 행동 `B`를 등록하면 `B`로 교체한다.
- `눈치보기 → 원래 손패 A`는 `{ 눈치보기, A }`를 유지하고 두 카드 모두 사용한다.
- `A → 눈치보기`도 정규 순서 `{ 눈치보기, A }`가 된다.
- `눈치보기 → 프리뷰 카드 P`는 `{ 눈치보기, P }`를 유지하고 두 카드 모두 사용한다.
- `{ 눈치보기, P }`에서 원래 손패 `B`를 등록하면 speculative 가지 전체를 취소하고 `{ B }`만 남긴다.
- `{ 눈치보기, A }`에서 원래 손패 `B`를 등록하면 눈치보기는 유지하고 `{ 눈치보기, B }`가 된다.
- `P`만 취소하면 눈치보기 등록과 같은 프리뷰 표시는 유지한다.
- 눈치보기를 취소하면 그 프리뷰에서만 접근할 수 있던 등록 카드를 연쇄 취소한다. 독립적인 원래 손패 카드는 유지한다.
- 눈치보기를 취소했다가 다시 등록해도 권위 RNG와 덱이 같으므로 같은 카드를 다시 보여준다. 취소로 재추첨할 수 없다.

프리뷰로 다음 카드를 확인한 뒤 눈치보기를 취소하는 정보 이득은 승인된 규칙이다. 이때 권위 덱이나 RNG는 소비하지 않는다.

## 6. 전송 projection과 패스

`project`는 draft를 신뢰하지 않고 권위 상태에서 등록 순서를 재생한다. 등록 카드는 순서대로 `hand → used`로 옮기고 각 선언형 선택 단계 효과를 `cardZones.draw`로 적용한다. 덱이 비면 기존 discard만 결정적으로 섞으며 `used`, `plan`, `removed`는 제외한다.

projection의 `mode`는 다음 셋이다.

| `mode` | 의미 |
|---|---|
| `pass` | 등록 카드 없음. 아무 카드도 사용하지 않고 턴을 넘김 |
| `chain_pass` | 연계 카드만 사용한 뒤 주 행동 없이 넘김 |
| `action` | 연계 0장 이상과 주 행동 1장을 사용 |

따라서 별도 턴 종료 버튼은 필요 없다. RisuAI 전송이 유일한 확정점이며, 무선택 전송도 정상 패스다. 눈치보기만 등록하고 전송하면 눈치보기를 사용해 1장을 실제 드로우한 뒤 주 행동 없이 패스한다. 그 카드는 등록되지 않았다면 턴 종료에 다른 남은 손패와 함께 버린다.

projection은 `selectedCardInstanceIds`, `preview`, `projectedRng`와 내부 `workingState`를 반환한다. 후속 실제 턴 해결기는 이 workingState에서 계속 진행하며 선택 단계 효과를 다시 적용하지 않는다. 검증된 projection에서 카드 비용, 트리거, 중간 승패, 무드와 정리를 처리하는 순서는 `TurnResolutionContract.md`를 따른다.

후속 턴 해결기는 projection의 `workingState`를 그대로 신뢰하지 않는다. `validateProjection(authoritativeState, staticData, projection)`이 같은 권위 상태에서 `selectedCardInstanceIds`를 다시 재생하고 `source`, mode·flags, preview, RNG, 모든 카드 영역과 workingState 전체를 대조한 결과만 입력으로 사용한다. source가 오래됐으면 `projection_stale`, 내부 값이 다르면 `projection_mismatch`로 원자적으로 거부한다.

`sealProjection`은 전체 projection을 먼저 검증한 뒤 다음 필드만 가진 `turnDraftProjectionReceipt`를 만든다.

```text
schemaVersion, kind, mode, selectedCardInstanceIds, source, projectedRng
```

영수증에는 `preview`, `workingState`, focus를 저장하지 않는다. `validateProjectionReceipt`는 `selectedCardInstanceIds`를 권위 `battleState`에서 다시 재생해 전체 projection을 만들고, 그 결과로 영수증을 다시 만들어 입력 영수증과 정확히 비교한다. 따라서 프리뷰 카드 선택도 권위 `beforeState.selection`을 오염시키지 않고 `pendingTurn`에 보존할 수 있다. `battleView`의 출력 대기 경계와 추후 `battleRuntime`의 결과 재사용·확정 경계는 각각 영수증을 다시 검증해야 하며, `stateSchema.validatePendingTurn`의 구조 검증 성공만으로 의미 재생까지 끝났다고 간주하지 않는다.

## 7. 검증

`Tests/turn-draft-check.ps1`은 다음을 검사한다.

- focus, 등록, 교체, 취소와 speculative branch reset 전이
- 무선택 패스, 눈치보기 단독 패스와 눈치보기+주 행동
- 최대 손패, discard 재섞기, 빈 덱과 제외 영역 경계
- preview 및 RNG 변조와 권위 상태 변경의 stale 거부
- projection의 선택, mode, preview, RNG와 workingState 변조 거부
- 최소 projection 영수증의 strict shape, stale source, mode·RNG 변조와 프리뷰 선택 재생
- 모든 action의 입력 불변성과 카드 보존
- 별도 Lua 프로세스 사이의 동일 결정성 벡터

실제 RisuAI 로어북, `main.lua`, UI와 수동 전송 훅 연결은 아직 수행하지 않았다.
