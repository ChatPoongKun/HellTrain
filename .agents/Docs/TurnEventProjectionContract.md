# 턴 사건 공개 투영 계약

이 문서는 `turnResolver`가 만든 내부 판정 로그를 화면용 `publicResult`와 모델 서술용 `llmEvent`로 바꾸는 스키마 버전 1의 경계를 정의한다. 구현은 `System/turnEventProjector.lua`이며, 원본 사건이나 정적 DB를 전달하는 중계기가 아니라 허용한 필드만 새 객체에 다시 조립하는 검증기 겸 sanitizer다.

## 1. 책임과 비책임

`turnEventProjector.projectTurn(beforeState, staticData, turnResolution)`의 책임은 다음과 같다.

- 초기화가 끝난 권위 `beforeState`와 해결된 `turnResolution`의 strict shape 및 핵심 교차 연결을 검사한다.
- 내부 사건의 source, side, phase, cause와 카드·계획 정의가 서로 맞는지 확인한다.
- 각 트리거 batch를 실제 선행 입력 사건에 연결하고, 당시 공개 상태 문맥에서 정적 trigger 조건·resolve 명령을 다시 평가해 누락·중복·수치 위조를 거부한다.
- 공개 가능한 사건만 빈 출력 묶음에 새로 작성한다.
- 숨은 캐릭터 카드와 계획, runtime 인스턴스 ID, RNG, 선택 점수와 판정 감사 자료를 제거한다.
- 카드별 narration은 LLM 사건에만 넣는다.
- 의미를 먼저 설명해야 하는 비용과 계획 효과의 출력 순서를 조정한다.

이 모듈은 다음 작업을 하지 않는다.

- `battleState`나 `pendingTurn`을 저장·확정하지 않는다.
- `turnDraft` projection이나 카드 해결 전체를 재생하지 않는다. 트리거 조건·명령만 사건 감사에 필요한 범위에서 재평가한다.
- 프롬프트 문장이나 기본 묘사 지침을 만들지 않는다.
- `editRequest`, `onStart`, `onOutput`, 채팅 변수 또는 CBS UI를 조작하지 않는다.

이 책임들은 후속 `battleRuntime`과 승인받은 `main.lua` 훅의 범위다.

## 2. 입력 조건

호출 입력은 다음 조건을 만족해야 한다.

1. `beforeState`는 `turnInitializer.prepareTurn`이 만든, 봉인된 `turnStartReceipt`를 가진 active `battleState`다.
2. `staticData`는 카드, 캐릭터, 특징, 환경과 레지스트리를 모두 가진 검증 완료 정적 데이터다.
3. `turnResolution`은 같은 `battleId`, `turnId`, `turnNumber`를 사용하고 유효한 `afterState`를 가진다.
4. `selectedCards.character`는 `beforeState.characterIntent.cardInstanceIds`와 순서까지 같다.
5. 원본 사건의 `sequence`는 1부터 이어지고 `eventId`는 `turnId-event-%03d` 형식과 일치한다.
6. `card_declared`의 비용과 `card_resolved`는 같은 `resolutionId`, 카드 ID와 인스턴스 ID로 연결된다.
7. 종료되지 않은 결과에는 종료 사건이 없고, 종료된 결과에는 일치하는 `outcome_latched`와 마지막 `session_end`가 있다.
8. 턴 시작 드로우 사건은 봉인된 `turnStartReceipt.draws`와 일치하고, 조건을 만족한 활성 계획·특징·퍽·환경 trigger batch는 정확히 한 번 존재한다.

입력은 읽기 전용이다. 성공과 실패 모두 `beforeState`와 `turnResolution`을 변경하지 않는다. 함수, userdata, 메타테이블, 순환 참조, 비유한 숫자와 계약 밖 필드는 구조화 오류다.

## 3. 반환 형식

성공 결과는 다음 형식이다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    publicResult = {
        schemaVersion = 1,
        events = {},
    },
    llmEvent = {
        schemaVersion = 1,
        events = {},
    },
}
```

실패 결과는 `ok = false`, `schemaVersion = 1`, 하나 이상의 `{ code, path, message }` 오류만 가진다. 비공개 계획 키나 runtime 인스턴스·해결 ID는 오류 문장에도 넣지 않는다.

두 출력 묶음의 각 사건은 정확히 다음 필드만 가진다.

```lua
{
    sequence = 1,
    type = "turn_mode",
    payload = {},
}
```

원본의 `eventId`, `resolutionId`, `phase`, `source`, `cause`를 복사하지 않는다. 출력 `sequence`는 각 묶음 안에서 독립적으로 1부터 다시 매긴다.

## 4. 공개 사건

`publicResult`는 정상 LLM 출력이 도착하고 `onOutput`이 `afterState`를 확정한 뒤 UI와 사용자에게 공개할 판정 결과다. 이름의 `public`은 정보 등급을 뜻하며 대기 중 즉시 표시해도 된다는 뜻이 아니다. `awaitingOutput` View에는 넣지 않는다.

| type | payload |
|---|---|
| `turn_mode` | `mode` |
| `turn_started` | `turnNumber` |
| `player_cards_drawn` | `requested`, `drawnCount` |
| `character_intent` | `selected`, 선택된 경우 `actionTag` |
| `card_declared` | `side`, `actionTag`, `stealthCost`, 플레이어 카드에만 `cardId` |
| `effect_applied` | op별 안전 수치·상태. 드로우는 `requested`, `drawnCount`만 사용 |
| `trigger_suppressed` | 공개 억제에만 `side`, `reasonCode`, `identityKnown`, 알려진 `cardId` |
| `plan_changed` | `side`, `action`, `identityKnown`, 선택적 `remainingTurns`, 알려진 `cardId` |
| `actions_stopped` | `side`, `reasonCode`, `count` |
| `card_removed` | `side`, 플레이어 카드에만 `cardId` |
| `outcome` | `status`, `reasonCode`, `stealth`, `resistance` |
| `mood_evaluated` | `performance`, `before`, `after`, `applied`, 선택적 `direction`, `threshold`, `reasonCode` |
| `turn_ended` | `turnNumber` |
| `session_ended` | `status` |

`plan_changed.action`은 `placed`, `triggered`, `replaced`, `expired` 중 하나다. 남은 충전은 공개하지 않는다. 공개 문장에는 `actorAction`과 `actorThought`를 넣지 않는다.

`effect_applied`는 공통으로 `op`, `target`, `changed`를 가진다. 자원 변화는 `amount`, `before`, `after`; 드로우는 `requested`, `drawnCount`; 행동 생략은 `scope`, `before`, `after`; 무드 이동·설정·고정은 각 op에 필요한 무드, 이동량, `until`, `blocked`, `before`, `after`만 사용한다. 공개 묶음에는 검증된 no-op도 감사 가능한 결과로 남기지만 LLM 묶음에는 실제 변화 또는 차단만 넣는다.

## 5. LLM 사건

`llmEvent`는 정상 모델 요청의 서술 자료다. 규칙 로그 전체가 아니라 한 턴의 의미와 묘사에 필요한 최소 사건만 전달한다.

필드명은 기존 `pendingTurn` 스키마와의 호환 때문에 단수형이지만 값은 단일 사건이 아니라 `events` 배열 envelope다.

| type | payload |
|---|---|
| `turn_mode` | `mode` |
| `turn_context` | `turnNumber` |
| `character_intent` | `selected`, 선택된 경우 `actionTag` |
| `action` | `actor`, `action`, `identityKnown`, `actionTag`, `actorAction`, 캐릭터에만 선택적 `actorThought` |
| `plan` | `actor`, `action`, `identityKnown`, 알려진 사건의 선택적 `actorAction`·`actorThought` |
| `plan_suppressed` | 공개 억제의 `actor`, `reasonCode`, `identityKnown` |
| `effect_applied` | 실제로 변했거나 막힌 효과의 안전 필드 |
| `actions_stopped` | `side`, `reasonCode`, `count` |
| `outcome` | `status`, `reasonCode` |
| `mood_changed` | `before`, `after`, `direction` |
| `session_ended` | `status` |

일반 카드는 `narration.play`, 알려진 계획 배치는 `planPlaced`, 발동은 `planTriggered`를 사용한다. 이 세 narration은 정적 데이터 계약상 필수다. `planExpired`는 선택 사항이므로 없을 때도 중립적인 `plan` 의미 사건으로 정상 투영한다.

캐릭터 `actorThought`는 LLM 사건에만 들어간다. 플레이어 narration의 `actorThought`는 사용하지 않는다.

LLM 사건의 `identityKnown = true`는 카드 ID를 프롬프트에 넣는다는 뜻이 아니라 카드별 narration을 사용할 수 있다는 뜻이다. `action = "played"`와 계획 action은 formatter가 사건을 묶기 위한 내부 enum이며, 모델 지침에 “카드를 사용했다”라는 규칙 문장으로 그대로 옮기지 않는다. 실제 장면 지시는 `actorAction`과 효과·결과 사건을 사용한다.

## 6. 비공개 경계

두 출력에 공통으로 금지하는 정보는 다음과 같다.

- `battleId`, `turnId`, `eventId`, `resolutionId`
- `instanceId`, `cardInstanceId`, `drawnInstanceIds`, 정리·복원·미해결 인스턴스 배열
- RNG `seed`, `cursor`, projection authority와 fingerprint
- `selectedCards`, 캐릭터 후보, 점수, 가중 풀과 추첨 감사 자료
- `beforeState`, `workingState`, `afterState`, `metrics`
- 정적 DB 함수, `privateProfile`, 카드 규칙 함수와 계획 조건

추가 공개 규칙은 다음과 같다.

- 플레이어 카드 ID는 공개한다.
- 일반 캐릭터 카드 ID는 공개하지 않고 `actionTag`와 서술만 전달한다.
- 캐릭터 계획은 배치 시 숨긴다. 첫 정상 발동 때 공개하고 이후 슬롯에 남아 있는 동안 알려진 상태를 유지한다.
- 숨은 채 억제된 계획은 `publicResult`와 `llmEvent` 양쪽에서 사건 자체를 생략한다.
- 숨은 채 만료되거나 교체된 계획은 카드 ID와 카드별 narration 없이 중립 사건만 만든다.
- 공개된 계획이나 플레이어 계획은 만료·교체 시 카드 ID를 공개할 수 있다.

## 7. 의미 순서

원본 로그는 판정 감사 순서를 보존한다. 공개와 서술 출력은 검증 가능한 의미 순서가 필요하므로 두 종류를 버퍼링한다.

1. 플레이어 `pay_stealth_cost`는 원본에서 `card_declared`보다 먼저 발생하지만, 출력에서는 카드 선언·행동 사건 뒤에 둔다.
2. 계획·특징·퍽·환경 트리거 효과는 같은 source의 `trigger_resolved`와 명령 수가 일치할 때까지 보류한다. 계획은 그보다 앞선 `plan_changed(action = "triggered")`까지 확인한 뒤 계획 발동 사건 다음에 효과를 둔다.

짝이 되는 선언이나 계획 발동이 없으면 효과를 임의로 공개하지 않고 전체 투영을 실패시킨다. `trigger_resolved`, `card_resolved`, `card_restored` 같은 내부 감사 사건은 안전한 의미 사건으로 이미 요약되므로 그대로 출력하지 않는다.

## 8. 검증 범위

투영기는 다음을 fail-closed로 검사한다.

- 카드·계획·특징·퍽·환경 source가 실제 정적 정의와 일치하는지
- source kind와 `cause.kind`가 카드 효과 또는 해당 트리거 종류로 일치하는지
- 트리거의 선행 입력 type·side·phase·resolution 연결, 활성 source, 조건 결과와 정적 resolve 명령의 op·target·수치가 일치하는지
- 카드/계획 사건의 `side`, `source.side`, phase와 owner가 일치하는지
- 비용·효과·승패·무드·턴 번호가 유한한 scalar와 등록 enum인지
- 계획 before/after 슬롯, 수명, 배치·발동 action과 moved ID 배열이 올바른지
- 무드 평가와 최종 상태, cleanup과 session end가 서로 모순되지 않는지
- 알 수 없는 원본 사건, 효과 op와 payload 필드가 없는지

`stateSchema.validatePendingTurn`은 저장 경계에서 출력 사건 배열의 JSON shape만 다시 검사한다. 개별 사건 의미와 privacy allowlist의 권위 검증은 이 투영기를 통과한 결과를 `battleRuntime`이 그대로 저장하는 방식으로 유지한다. 후속 코드가 원본 사건에서 `publicResult`나 `llmEvent`를 다시 조립해서는 안 된다.

## 9. 로컬 검증

`.agents/Tests/turn-event-projector-check.ps1`은 다음을 두 개의 독립 Lua 프로세스에서 검사한다.

- 일반 플레이어·캐릭터 행동과 narration 분리
- 제거, 남은 행동 생략, 직접 무드 변화
- 승패 확정, 행동 중단과 세션 종료
- 승패 자원·사유, 무드 성과·방향과 최종 상태의 교차 재현
- 숨은 계획 억제의 완전 생략
- 계획 발동 공개와 계획 효과의 의미 순서
- 숨은 캐릭터 계획 배치
- `planExpired`가 없는 알려진 계획 만료
- 숨은 계획의 만료 비누출과 cleanup 이동·계획 수명 전이
- cleanup 이후 `session_end` 0-command 계획 발동과 최종 상태 재현
- 내부 metrics canary와 runtime ID 비누출
- 잘못된 scalar, 계약 밖 필드, source/cause 위장, 트리거 누락·중복·수치 변경과 오류 채널 비누출의 fail-closed 처리
- 실제 10턴 반복과 별도 프로세스 결정성

이 검사는 실제 RisuAI 로어북 컴파일, 프롬프트 삽입, CBS 렌더링과 훅 호출 순서를 대신하지 않는다.
