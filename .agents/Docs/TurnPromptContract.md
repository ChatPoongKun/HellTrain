# 턴 프롬프트 조립 계약

이 문서는 확정 대기 중인 `pendingTurn`을 모델 요청에만 넣을 한 개의 system 메시지와 user 장면 지시로 바꾸는 스키마 버전 1의 경계를 정의한다. 구현은 `System/turnPromptFormatter.lua`다. 이 모듈은 원본 런타임 로그를 요약하지 않고, `turnEventProjector`가 이미 만든 `llmEvent`를 다시 검증한 뒤 허용 필드만 새 객체로 조립한다.

## 1. 호출과 책임

로어북 호출 형식은 다음과 같다.

```lua
runScript(triggerId, "turnPromptFormatter", "formatPending", pendingTurn, staticData)
```

`staticData`에는 `staticData.loadAll` 성공 결과의 `data` 또는 그 성공 결과 전체를 전달할 수 있다.

포맷터의 책임은 다음과 같다.

- `pendingTurn`의 전체 스키마, 참조와 무결성 영수증을 `stateSchema.validatePendingTurn`으로 검증한다.
- 저장된 `projectionReceipt`를 `turnDraft.validateProjectionReceipt`로 권위 상태에 대해 재생한다.
- `llmEvent`의 envelope, 사건 순서, 허용 type과 type별 payload를 fail-closed로 검사한다.
- 허용 필드만 새 테이블에 복사해 키 정렬 canonical JSON으로 직렬화한다.
- 기존 프리셋을 보존하면서 이번 턴의 확정 사실만 기계적으로 반영하라는 고정 지침을 만든다.
- request-only user 메시지에 사용할, 사건 세부정보가 없는 고정 형식 장면 지시를 만든다.

이 모듈은 상태 저장, `editRequest`, 채팅 추가, UI 변경, 턴 확정과 재판정을 하지 않는다. 입력 객체도 변경하지 않는다. 실제 훅은 성공 반환값을 사용해 요청 복사본을 조립해야 한다.

## 2. 성공과 실패 반환

성공 형식은 정확히 다음 의미를 가진다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    message = {
        role = "system",
        content = "<고정 지침과 canonical 사건 JSON>",
    },
    publicMarker = "[전투 턴 1] 이번 턴에 실제로 벌어진 일을 하나의 장면으로 이어서 묘사한다.",
}
```

`publicMarker`라는 호환 필드 이름을 유지하지만 실제 채팅 마커가 아니다. 숫자는 `pendingTurn.beforeState.turnNumber`이며 형식은 문자 하나까지 고정한다.

```text
[전투 턴 N] 이번 턴에 실제로 벌어진 일을 하나의 장면으로 이어서 묘사한다.
```

지시에는 `battleId`, `turnId`, 카드, 행동, 수치나 승패를 넣지 않는다. 기술 식별자나 재처리 키도 아니며, `editRequest`가 모델에게만 보내는 이번 턴 묘사 요청이다.

실패 결과는 `ok = false`, `schemaVersion = 1`, 하나 이상의 `{ code, path, message }`만 가진다. 부분 `message`나 `publicMarker`를 반환하지 않는다.

## 3. system 메시지

`message.role`은 항상 `system`이다. `content`는 다음 고정 지침 뒤에 검증·재조립한 `llmEvent`의 canonical JSON을 붙인다.

```text
[전투 사건 전달]
기존 프리셋의 문체, 시점, 인물 표현과 응답 형식을 그대로 유지하십시오.
아래 JSON은 이번 응답에 반영해야 하는, 이미 확정된 시간순 사건입니다.
사건의 순서, 행동 주체, 수치 변화, 무드와 승패를 바꾸거나 다시 판정하지 마십시오.
actorAction은 장면 속 실제 행동으로 자연스럽게 반영하고, actorThought가 있을 때만 캐릭터의 내면에 반영하십시오.
type, action, op, reasonCode 같은 기계 필드명을 독자에게 그대로 나열하지 마십시오.
이 지침은 기존 프리셋을 대체하지 않고 이번 턴의 확정 사실만 추가합니다.
사건 JSON:
```

포맷터는 프리셋의 문체, 시점, 응답 형식을 새로 지정하지 않는다. 사건을 창작하거나 해석해 자연어 요약으로 바꾸지도 않는다. 동일 입력은 별도 Lua 프로세스에서도 byte 단위로 같은 메시지를 만들어야 한다.

## 4. 허용 사건

envelope는 정확히 `schemaVersion`, `events`만 가진다. 각 사건은 정확히 `sequence`, `type`, `payload`만 가지며 `sequence`는 1부터 빈틈없이 이어진다. 첫 사건은 `turn_mode`, 두 번째는 `turn_context`여야 하고 `character_intent`는 정확히 하나 있어야 한다. `turn_mode`, `turn_context`, `outcome`, `session_ended`는 중복할 수 없으며 `session_ended`는 종료 턴의 마지막 사건이어야 한다.

| type | 허용 payload |
|---|---|
| `turn_mode` | `mode` |
| `turn_context` | `turnNumber` |
| `character_intent` | `selected`, 선택된 경우 `actionTag` |
| `action` | `actor`, `action`, `identityKnown`, `actionTag`, `actorAction`, 캐릭터에만 선택적 `actorThought` |
| `plan` | `actor`, `action`, `identityKnown`, 알려진 사건의 선택적 `actorAction`·`actorThought` |
| `plan_suppressed` | `actor`, `reasonCode`, `identityKnown` |
| `effect_applied` | op별 공개 수치와 상태 |
| `actions_stopped` | `side`, `reasonCode`, `count` |
| `outcome` | `status`, `reasonCode` |
| `mood_changed` | `before`, `after`, `direction` |
| `session_ended` | `status` |

세부 의미는 `TurnEventProjectionContract.md`의 LLM 사건 계약을 따른다. 여기에 더해 포맷터는 다음 교차 검증을 수행한다.

- mode와 턴 번호는 각각 `projectionReceipt`와 `beforeState`에 일치해야 한다.
- 캐릭터 의도의 `actionTag`는 등록된 캐릭터 태그이며 `beforeState.characterIntent.publicActionTag`와 같아야 한다.
- 일반 행동과 알려진 계획 narration은 정적 카드 DB의 해당 narration과 byte 단위로 같아야 한다.
- 숨은 계획에는 narration이 없어야 한다. 알려진 계획 배치·발동에는 narration이 필수다. `planExpired`가 정의되지 않은 알려진 만료·교체만 중립 사건을 허용한다.
- 효과 op, 대상, 수치 산술, 상태 전이와 등록 mood를 검사한다. 실제 변화나 명시적으로 차단된 효과만 허용한다.
- 종료 상태에는 일치하는 `outcome`과 마지막 `session_ended`가 모두 있어야 하고 active 상태에는 둘 다 없어야 한다.

알 수 없는 사건, 효과 op, payload 필드와 envelope canary는 버리지 않고 전체 포맷을 실패시킨다.

## 5. 비공개 경계

system 메시지와 request-only user 지시 양쪽에 다음 자료를 넣지 않는다.

- `battleId`, `turnId`, `eventId`, `resolutionId`
- 카드 인스턴스 ID, 카드 ID와 선택 카드 배열
- `beforeState`, `afterState`, `projectionReceipt` 원문
- RNG seed·cursor, fingerprint와 무결성 영수증
- 캐릭터 후보, 점수, 가중치와 추첨 감사 자료
- 정적 DB 함수, 규칙 구현과 캐릭터 `privateProfile`
- `publicResult`와 resolver 원본 `events`

이 경계는 문자열 블랙리스트로 원본을 지우는 방식이 아니다. type별 allowlist를 통과한 값을 새 출력 객체에 명시적으로 복사한다. 그러므로 후속 훅이 `pendingTurn`, 원본 사건이나 정적 DB를 별도로 메시지에 직렬화해서는 안 된다.

## 6. 훅 통합 규칙

정상 요청 조립기는 다음 순서를 따른다.

1. 현재 권위 상태와 같은 `pendingTurn`을 재사용하거나 새로 준비한다.
2. `formatPending`이 성공한 경우에만 진행한다.
3. 기존 `request.messages`를 복사하고 반환된 system `message`를 추가한다.
4. 기존 프리셋 메시지를 삭제하거나 수정하지 않는다.
5. `{ role = "user", content = publicMarker }`를 system 사건 뒤에 추가하되, 두 메시지는 request 배열에만 두고 실제 사용자 채팅에는 저장하지 않는다.
6. 정상 모델 출력이 도착하기 전에는 `afterState`나 `publicResult`를 확정·공개하지 않는다.

포맷터 실패를 무시하고 원본 `llmEvent` 또는 `pendingTurn`으로 대체 프롬프트를 만들어서는 안 된다.

## 7. 로컬 검증

`.agents/Tests/turn-prompt-formatter-check.ps1`은 실제 초기화, 드래프트, 해결과 사건 투영을 거쳐 만든 `pendingTurn`으로 다음을 검사한다.

- 고정 system 지침, 카드 narration과 request-only user 지시 완전 일치
- runtime ID, 카드 ID, 캐릭터 비공개 프로필과 내부 상태 비누출
- 일반 정적 데이터와 `loadAll` wrapper의 동일 결과
- payload·사건 canary, 알 수 없는 type·effect op, 위조 narration과 중복 필수 사건 거부
- `pendingTurn` 무결성 변조와 알 수 없는 formatter action 거부
- 성공·실패 양쪽의 입력 불변성과 호스트 쓰기 부재
- 두 독립 Lua 프로세스의 전체 메시지 결정성

이 검사는 실제 RisuAI `onStart`/`onOutput` 순서, `editRequest` 적용, request-only 지시의 raw-chat 비노출과 모델 응답 품질을 대신하지 않는다.
