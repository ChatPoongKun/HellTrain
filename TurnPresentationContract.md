# 턴 공개 표시 계약

이 문서는 확정된 `pendingTurn.turnResult.publicResult` 사건을 Battle UI가 표시할 수 있는 짧은 문장으로 바꾸는 `System/turnPresentation.lua` 스키마 버전 1의 경계를 정의한다.

## 1. 책임과 경계

`turnPresentation` 모듈은 다음만 한다.

- 저장된 `pendingTurn`을 `stateSchema.validatePendingTurn` 전체 참조 검증으로 다시 확인한다.
- `afterState.lastCommittedTurnId == pendingTurn.turnId`인 확정 결과만 받는다.
- `publicResult.events`의 사건 종류와 payload 필드를 다시 strict allowlist로 검증한다.
- 입력 객체를 복사하지 않고 `{ sequence, type, text }`만 빈 출력에 새로 쓴다.
- 카드·행동 태그·무드 표시명은 검증된 정적 DB의 공개 `name` 또는 `label`만 사용한다.

이 모듈은 다음을 하지 않는다.

- 권위 `battleState`, `pendingTurn`, 채팅 변수를 저장하거나 수정하지 않는다.
- `llmEvent`, 원본 resolver 사건, 캐릭터 선택·RNG 감사 자료를 표시 입력으로 사용하지 않는다.
- `main.lua`, RisuAI 훅, CBS HTML을 조작하지 않는다.
- 전달받은 마지막 `pendingTurn`이 현재 외부 권위 상태의 `lastCommittedTurnId`와 같은지는 호출자가 검증한다. 모듈은 외부 상태를 읽지 않는 순수 경계다.

## 2. API

```lua
runScript(
    triggerId,
    "turnPresentation",
    "build",
    lastCommittedPendingTurn,
    staticData
)
```

`lastCommittedPendingTurn == nil`이면 정적 데이터 없이도 다음을 반환한다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    lastTurn = { available = false },
}
```

표시할 확정 턴이 있으면 다음을 반환한다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    lastTurn = {
        available = true,
        turnNumber = 1,
        summaries = {
            {
                sequence = 1,
                type = "turn_mode",
                text = "등록한 카드 행동을 실행했습니다.",
            },
        },
    },
}
```

실패는 `ok = false`, `schemaVersion = 1`, 하나 이상의 `{ code, path, message }`만 반환한다. 실패 반환에는 `lastTurn`이 없다. 오류 문장에 거부한 필드명의 값, 카드 ID, runtime ID, 비공개 문자열을 인용하지 않는다.

## 3. 표시 허용 사건

| 사건 | 표시에 사용하는 공개 정보 |
|---|---|
| `turn_mode` | `pass`, `chain_pass`, `action` 중 하나 |
| `turn_started` | 확정 턴 번호 |
| `player_cards_drawn` | 요청 매수와 실제 드로우 매수 |
| `character_intent` | 선택 여부, 선택된 경우 캐릭터 행동 태그 라벨 |
| `card_declared` | 진영, 행동 태그, 은폐 비용. 플레이어 카드만 DB 카드명 |
| `effect_applied` | 투영기가 허용한 자원·드로우·행동 생략·무드 효과의 수치와 결과 |
| `trigger_suppressed` | 이미 정체가 알려진 계획의 DB 카드명과 `insight` 억제 |
| `plan_changed` | 진영, 배치·발동·교체·만료, 공개 여부, 선택적 남은 지속 턴 |
| `actions_stopped` | 진영, 검증된 중단 사유, 미처리 매수 |
| `card_removed` | 진영. 플레이어 카드만 DB 카드명 |
| `outcome` | 승리·패배, 검증된 사유, 최종 은폐·저항 |
| `mood_evaluated` | 성과, 이전·이후 DB 무드 라벨, 적용 방향·기준 또는 미적용 사유 |
| `turn_ended` | 확정 턴 번호 |
| `session_ended` | 승리·패배 |

`effect_applied`는 op별 필드 조합을 정확히 나눈다. 자원은 `amount/before/after`, 드로우는 `requested/drawnCount`, 행동 생략은 `scope/before/after`, 무드 이동·설정·고정은 각 op의 필수 필드만 허용한다. `changed`, 변화량, before/after가 서로 모순되면 실패한다.

## 4. 숨은 캐릭터 정보

- `character_intent` 요약은 `actionTag` DB 라벨만 읽는다. `selectedCards.character`, 캐릭터 카드 ID·카드명·narration을 조회하지 않는다.
- 캐릭터 일반 `card_declared` 및 `card_removed`에 `cardId`가 있으면 전체 표시를 거부한다.
- 캐릭터 숨은 계획의 `placed`, `replaced`, `expired`는 중립적인 "정체가 드러나지 않은 계획"으로만 표시한다.
- `triggered`는 투영 계약상 정체가 공개된 사건이므로 `identityKnown = true` 및 소유자가 일치하는 계획 카드 ID가 필요하다.
- 플레이어 계획은 항상 공개다. 캐릭터 계획 배치는 항상 비공개다. 교체·만료는 이미 드러난 계획인지에 따라 공개 여부가 달라질 수 있다.
- `actorAction`, `actorThought`, `privateProfile`, 캐릭터 카드 narration은 어떤 성공 출력에도 있을 수 없다.

## 5. 턴·종료 교차 검증

투영기의 현재 스키마에서 일반 턴과 종료 턴 모두 다음 공개 사건을 각각 한 번 갖는다.

- `turn_mode`
- `turn_started`
- `player_cards_drawn`
- `character_intent`
- `mood_evaluated`
- `turn_ended`

카드 행동 중 승패가 결정되어도 resolver는 무드 평가와 턴 정리를 완료하므로 종료 턴에도 두 사건이 필요하다.

- `afterState.status == "active"`이면 `outcome`, `session_ended`가 모두 없어야 한다.
- `afterState.status == "victory" | "defeat"`이면 `outcome`, `session_ended`가 각각 한 번 있고 두 status와 `afterState.status`가 모두 같아야 한다.
- `turn_started.turnNumber`, `turn_ended.turnNumber`, `lastTurn.turnNumber`는 `pendingTurn.beforeState.turnNumber`와 같아야 한다.

## 6. fail-closed 및 불변성

다음은 전체 표시 실패다.

- 알 수 없는 사건 종류, op, mode, action, reason code
- 사건·payload 허용 목록 밖 필드
- 비연속 배열, 서로 다른 `sequence`, 중복된 필수·종료 사건
- 등록되지 않은 카드·행동 태그·무드, 소유자가 다른 카드·행동 태그
- 비공개 캐릭터 카드 ID나 `actorAction`, `actorThought` 같은 LLM 전용 필드
- 비유한 수, 메타테이블, 함수·userdata, 순환 참조, 무결성이 달라진 `pendingTurn`

성공과 실패 경로 모두 `pendingTurn` 및 `staticData`를 변경하지 않는다. 출력은 입력 테이블의 참조를 재사용하지 않는다.

## 7. 로컬 검증

`Tests/turn-presentation-check.ps1`은 다음을 검증한다.

- 표시할 턴 부재 shape
- 실제 resolver·projector·battleRuntime으로 만든 active 턴과 카드 checkpoint 종료 턴
- 플레이어 DB 카드명 표시와 캐릭터 카드명·ID·`actorThought`·`privateProfile` canary 비누출
- 숨은 캐릭터 계획의 배치·교체·만료 중립 표시
- 숨은 `triggered` 계획, LLM 전용 필드, 미등록 사건의 거부
- active 상태의 종료 사건과 종료 상태의 종료 사건 누락 거부
- 성공·실패 입력 불변성, 오류 채널 canary 비누출, host write 0회

이 검사는 후속 `viewBuilder` 연결, CBS 텍스트 이스케이프, RisuAI 로어북 컴파일을 대신하지 않는다.
