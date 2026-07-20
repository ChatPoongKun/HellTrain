# 전투 호스트 컨트롤러 계약 v1

## 1. 범위

`System/battleController.lua`는 순수 전투 모듈과 RisuAI 호스트 저장소·대화·View 게시 경계를 연결하는 어댑터다. 컨트롤러는 전투 규칙을 다시 판정하지 않고 다음 모듈의 성공 결과만 조정한다.

- `staticData.loadAll`
- `battleBootstrap.verticalSlice`
- `turnInitializer.prepareTurn`
- `turnDraft.clickCard`, `turnDraft.interactionToken`, `turnDraft.project`, `turnDraft.validate`
- `battleRuntime.preparePending`, `battleRuntime.reusePending`, `battleRuntime.commitPending`
- `turnPromptFormatter.formatPending`
- `viewBuilder.buildBattleView`
- `dataBridge.publish`

LLM을 직접 호출하거나 전송을 자동화하지 않는다. Continue, 프롬프트 미리보기와 과거 여러 턴의 임의 재생성은 v1에서 지원하지 않는다. 지원하는 재생성은 공개 마커로 식별할 수 있는 직전 확정 턴 하나뿐이다.

이 파일 자체는 훅에 연결할 동작만 정의한다. 별도 승인된 `System/main.lua`가 controller action을 실제 Lua 훅에 연결한다.

## 2. 공통 결과 envelope

모든 action은 다음 중 하나를 반환한다.

```lua
-- 성공
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    -- action별 결과
}

-- 실패
{
    ok = false,
    schemaVersion = 1,
    errors = {
        { code = "...", path = "...", message = "..." },
    },
}
```

하위 모듈의 예외, 잘못된 envelope와 상세 없는 실패는 각각 구조화된 컨트롤러 오류로 바꾼다. 실패를 `nil`, 불리언 하나 또는 일반 문자열로 축약하지 않는다.

## 3. 영속 키

컨트롤러는 `getState`와 `setState`에 다음 다섯 키만 사용한다.

| 역할 | 정확한 키 | 값 |
|---|---|---|
| 권위 상태 | `battleRuntimeV1.authority` | 현재 검증된 `battleState` |
| 선택 draft | `battleRuntimeV1.draft` | 선택 중인 현재 턴의 `turnDraft`; 출력 대기·종료 시 없음 |
| 출력 대기 | `battleRuntimeV1.pending` | 아직 출력으로 확정하지 않은 `pendingTurn` |
| 직전 확정 결과 | `battleRuntimeV1.lastCommittedPending` | 직전 출력에 사용한 원본 `pendingTurn` |
| 프롬프트 binding | `battleRuntimeV1.activeRequest` | 아래의 `battleActiveRequest` |

`lastCommittedPending.turnResult.publicResult`가 직전 공개 결과의 권위 원본이다. 별도 공개 결과 복제본을 저장하지 않으며 `getSnapshot`이 이를 `lastPublicResult`로 투영한다. 직전 pending 전체는 재생성 무결성 검증에 필요하므로 공개 View나 일반 사용자 메시지로 내보내지 않는다.

`battleActiveRequest`의 strict shape는 다음과 같다.

```lua
{
    schemaVersion = 2,
    kind = "battleActiveRequest",
    battleId = "...",
    turnId = "...",
    turnNumber = 1,
    source = "pending" | "lastCommittedPending",
    phase = "preparing" | "inFlight" | "requestInjected" | "committed",
    attemptNumber = 1,
    publicMarker = "...",
    message = {
        role = "system",
        content = "...",
    },
    chatAnchor = {
        schemaVersion = 1,
        kind = "battleChatAnchor",
        prefixMessageCount = 3,
        markerIndex = 3,
        prefixFingerprint = {
            algorithm = "canonical_poly131_137_chat_v1",
            length = 123,
            hashA = 123456789,
            hashB = 987654321,
        },
    },

    -- onOutput이 완성 응답을 확인한 뒤에만 존재한다.
    outputObserved = {
        schemaVersion = 1,
        kind = "battleOutputObserved",
        attemptNumber = 1,
        responseIndex = 4,
        responseFingerprint = {
            algorithm = "canonical_poly131_137_chat_v1",
            length = 45,
            hashA = 123456789,
            hashB = 987654321,
        },
    },

    -- 실패한 onStart 채팅 정리를 재개하는 동안에만 존재한다.
    recoveringCleanup = {
        schemaVersion = 1,
        kind = "battleRecoveringCleanup",
        mode = "retry" | "resumeCommit",
        originalPhase = "inFlight" | "requestInjected",
        attemptNumber = 1,
        responseIndex = 4,
        responsePresent = true,
        responseFingerprint = {
            algorithm = "canonical_poly131_137_chat_v1",
            length = 45,
            hashA = 123456789,
            hashB = 987654321,
        },
        initialFillerCount = 1,
    },
}
```

`outputObserved`와 `recoveringCleanup`은 선택 필드이며 해당 영수증이 없을 때는 키 자체를 저장하지 않는다. `responsePresent = false`인 cleanup 영수증에도 `responseFingerprint`가 없어야 한다.

binding의 식별자·턴 번호는 선택한 pending과 같아야 한다. `message`와 `publicMarker`는 `turnPromptFormatter.formatPending`을 다시 호출한 결과와 정확히 같아야 한다. `committed` phase는 반드시 `lastCommittedPending` source를 사용한다. `attemptNumber`는 같은 pending의 생성 재시도 횟수이며 최초는 1이다. 공개 마커 뒤에 아무 메시지도 생기지 않은 무출력 재시도 또는 미관측 출력을 정리한 재시도에서만 1씩 증가한다. 판정·pending·RNG 결과는 다시 만들지 않는다.

`chatAnchor.prefixMessageCount`는 공개 마커 앞 메시지 수이고 `markerIndex`는 그 마커가 들어갈 RisuAI 0-based index이므로 두 값은 같다. prefix fingerprint는 자료형·길이·정렬된 객체 키를 포함하는 canonical 직렬화를 서로 다른 두 다항 해시와 길이로 요약한다. 이는 저장 손상과 우발적 오인 삭제를 막는 비암호학적 무결성 식별자이지 보안용 해시는 아니다. 삭제 권한은 fingerprint 하나가 아니라 고정 prefix, 정확한 위치의 공개 마커, 허용된 suffix 구조와 삭제 뒤 전체 prefix 재검증을 모두 통과해야 생긴다. `responseIndex`도 RisuAI 0-based index다.

phase 의미는 다음과 같다.

- `preparing`: pending·binding·잠긴 View는 저장됐지만 채팅 filler 제거와 공개 마커 추가가 아직 완료되지 않았거나 확인되지 않았다.
- `inFlight`: 채팅 전환까지 확인되어 `editRequest` 주입만 허용한다. 아직 출력 commit의 근거는 아니다.
- `requestInjected`: `injectRequest`가 formatter의 비공개 사건을 프롬프트에 정확히 한 번 포함한 결과를 만들고 같은 binding에 영속 영수증을 썼다. 최초 출력 commit은 이 phase에서만 허용한다. `outputObserved`가 있으면 `onOutput`이 anchor 바로 뒤의 캐릭터 응답을 확인했고 commit을 시작했다는 뜻이다.
- `committed`: 출력이 이미 권위 상태에 반영됐다. 카드 선택은 허용하고 같은 turn의 늦은 `commitOutput`만 멱등 no-op으로 허용한다. `chatAnchor`와 `attemptNumber`는 보존하지만 `outputObserved`와 `recoveringCleanup`은 제거한다.

`outputObserved`는 `requestInjected`에만, `recoveringCleanup`은 `inFlight` 또는 `requestInjected`에만 존재할 수 있다. `retry` cleanup에는 `outputObserved`가 없어야 하고 `resumeCommit` cleanup에는 반드시 있어야 한다.

## 4. 저장 내구성

모든 영속 상태 쓰기는 다음 순서를 지킨다.

1. 입력을 함수·메타테이블·순환 참조·비유한 숫자가 없는 JSON 데이터로 복제한다.
2. `setState(triggerId, key, value)`를 호출한다.
3. 즉시 `getState(triggerId, key)`로 다시 읽는다.
4. 쓰려던 값과 구조적으로 정확히 같지 않으면 `state_write_not_persisted`로 실패한다.

따라서 RisuAI 권한 문제로 쓰기가 조용히 무시되는 경우를 성공으로 취급하지 않는다. 읽은 테이블도 그대로 반환하거나 수정하지 않고 먼저 복제한다.

`battleView` 게시도 `dataBridge.publish("battleView", view)` 뒤 `getChatVar("battleView")`가 반환한 wire와 encoder 결과가 정확히 같은지 검사한다. 확인이 끝난 뒤에만 `reloadDisplay(triggerId)`를 호출한다. 저장되지 않은 View에는 화면 reload를 요청하지 않는다.

채팅의 제거·추가도 `getFullChat`으로 다시 읽어 길이, 기존 prefix와 마지막 메시지를 확인한다. RisuAI 채팅 index는 0부터 시작하므로 Lua 배열의 마지막 항목은 `removeChat(triggerId, #chat - 1)`로 제거한다.

자동 복구 삭제는 반드시 `recoveringCleanup`을 먼저 write-read 검증한 뒤 시작한다. filler 또는 미관측 응답을 한 항목 지울 때마다 길이가 정확히 1 줄었고 나머지 모든 메시지가 구조적으로 그대로인지 다시 읽어 검사한다. 삭제 도중 오류·권한 거부·조용한 쓰기 유실이 발생하면 cleanup 영수증을 지우지 않으므로 다음 `onStart`가 이미 끝난 단계부터 재개한다. 영수증과 현재 채팅이 다르면 어떤 메시지도 추가로 삭제하지 않는다.

## 5. 공개 턴 마커와 생성 분류

formatter와 컨트롤러가 허용하는 공개 메시지는 정확히 다음 한 줄이다.

```text
[전투 턴 N] 이번 턴에 실제로 벌어진 일을 하나의 장면으로 이어서 묘사한다.
```

`N` 외에는 카드, 선택, 수치 결과, RNG, 캐릭터 의도와 내부 ID를 넣지 않는다.

`prepareGeneration`은 저장 요청 phase를 먼저 확인하고, 그 다음 마지막 대화 메시지로 생성 경로를 fail-closed 분류한다.

- 저장 `activeRequest.phase == "preparing"`이면 새 trailing filler 유무보다 앞선 실패 복구를 우선한다. binding이 가리키는 동일 pending과 formatter 결과만 다시 검증·사용한다. 특히 직전 턴 재생성 복구를 새 현재 턴 전송으로 바꾸지 않는다.
- 저장 `activeRequest.phase == "inFlight"` 또는 `"requestInjected"`이고 cleanup·출력 관측 영수증이 없으며 채팅이 저장된 공개 마커에서 정확히 끝나면, 앞선 요청이 캐릭터 메시지를 하나도 만들지 못한 것으로 보고 같은 요청을 무출력 재시도한다.
- 잠긴 요청 뒤에 exact filler도 없고 마지막 메시지도 저장 마커가 아니면 추가 onStart를 `request_already_in_flight`로 거부한다. 캐릭터 메시지나 다른 suffix가 있는 요청은 이 경로에서 삭제하거나 재시도하지 않는다.
- 잠긴 요청 뒤에 새 exact filler가 있으면 실패한 생성의 수동 재시도로 분류한다. cleanup 영수증이 이미 있으면 앞선 삭제가 중단된 것으로 보고 새 filler가 없어도 정리를 재개한다.
- 저장 `activeRequest.phase == "committed"`인데 같은 `turnId`의 낡은 pending이 남아 있으면 새 전송을 분류하기 전에 멱등 commit으로 그 pending 이동·삭제를 먼저 끝낸다.
- 마지막 메시지가 role `user`, data `*says nothing*`과 정확히 같으면 새 수동 빈 전송이다. 부분 문자열, 공백이 붙은 문자열과 다른 role은 제거하지 않는다.
- filler가 없고 마지막 사용자 메시지가 직전 `lastCommittedPending`에서 formatter로 다시 만든 공개 마커와 정확히 같으면 즉시 재생성이다.
- 나머지는 `unsupported_generation_source`다. Continue나 프롬프트 미리보기를 새 턴으로 오인하지 않는다.

새 전송에 이미 `pending`이 있으면 생성 실패 뒤 재시도로 보고 `battleRuntime.reusePending`을 사용한다. pending이 없을 때만 저장 draft를 projection으로 만들고 `battleRuntime.preparePending`을 호출한다. 즉시 재생성은 `lastCommittedPending`만 재사용한다.

잠긴 요청의 무출력 재시도가 허용하는 채팅 구조는 정확히 다음뿐이다.

```text
저장 chatAnchor와 fingerprint가 같은 전체 prefix
→ 저장된 0-based 위치의 정확한 publicMarker
→ 그 뒤 메시지 없음
```

`outputObserved`와 `recoveringCleanup`이 모두 없어야 하며, source가 `pending`이면 같은 턴의 authority commit 또는 `lastCommittedPending` 흔적도 없어야 한다. 이 경로는 채팅을 삭제하거나 추가하지 않고 같은 binding을 `inFlight`로 되돌려 `attemptNumber`만 증가시킨 뒤 `generationReady = true`, `zeroOutputRetry = true`를 반환한다. pending, formatter message, 공개 마커와 RNG 결과는 그대로 재사용한다. 상태 쓰기가 확인되지 않으면 attempt도 소비하지 않는다.

잠긴 요청의 삭제 복구가 허용하는 채팅 구조는 정확히 다음뿐이다.

```text
저장 chatAnchor와 fingerprint가 같은 전체 prefix
→ 저장된 0-based 위치의 정확한 publicMarker
→ 캐릭터 메시지 0개 또는 1개
→ trailing exact filler 1개 이상
```

prefix가 달라졌거나 마커 위치·문구가 다르거나, 캐릭터 응답이 둘 이상이거나, 다른 role·메시지가 섞였으면 삭제하지 않고 실패한다. source가 `pending`인데 같은 turn의 authority commit 또는 `lastCommittedPending` 흔적이 있는 예외 상태도 `outputObserved` 없이 삭제하거나 재시도하지 않는다.

- `outputObserved`가 없으면 cleanup mode는 `retry`다. 영수증을 먼저 저장하고 trailing filler와 있을 수 있는 캐릭터 부분 응답 하나를 검증하며 삭제한다. 같은 binding을 `inFlight`로 되돌리고 `attemptNumber`만 증가시킨다. 같은 pending, formatter message, 공개 마커와 RNG 결과를 재사용하며 `generationReady = true`를 반환한다.
- `outputObserved`가 있으면 cleanup mode는 `resumeCommit`이다. trailing filler만 삭제하고 fingerprint가 같은 완성 캐릭터 응답은 보존한 채 `commitOutput`을 멱등 재개한다. 새 LLM 요청을 보내면 안 되므로 `generationReady = false`, `commitRecovered = true`를 반환한다.

RisuAI는 공개 마커만 남은 상태에서 앞선 HTTP 요청이 실패했는지 아직 실행 중인지 구별할 request ID를 Lua에 제공하지 않는다. 또한 이 구조는 사용자가 마커에서 Continue를 누른 경우와도 구별할 수 없다. 따라서 전투 중 Continue·자동 계속을 사용하지 않고, 생성 중에는 새 전송이 직렬화된다는 전제를 실제 웹 통합 검사에서 확인해야 한다.

## 6. Action 계약

### `startVerticalSlice(battleId, seed)`

`battleId`와 `seed`를 옵션 객체에서 추론하지 않고 명시적 두 인자로 받는다. 컨트롤러는 정적 데이터를 먼저 불러온 뒤 다음을 호출한다.

```lua
runScript(triggerId, "battleBootstrap", "verticalSlice", {
    battleId = battleId,
    seed = seed,
}, staticData)
```

bootstrap은 pre-initializer 상태만 반환한다. 컨트롤러가 `<battleId>-turn-001` 형식의 `turnId`로 `turnInitializer.prepareTurn`을 한 번 호출하고, 초기화된 authority와 draft가 모두 만들어진 뒤에만 저장을 시작한다. `pending`, `lastCommittedPending`, `activeRequest`는 지우고 선택 가능 View를 게시한다.

### `clickCard(instanceId, expectedInteractionToken)`

pending이 존재하거나 `activeRequest.phase`가 `preparing`/`inFlight`/`requestInjected`이면 `battle_view_locked`로 거부한다. `committed` binding은 이전 출력의 감사·재생성 자료일 뿐이므로 다음 턴 카드 선택을 막지 않는다.

선택 가능한 `battleView.interactionToken`은 검증된 현재 draft fingerprint에서 만든 비어 있지 않은 `draftv1_...` 문자열이다. 버튼은 instance ID와 화면을 만들 때 받은 token을 함께 보내야 한다. 컨트롤러는 저장 authority·draft에서 `turnDraft.interactionToken`을 다시 계산한다.

- expected token이 비어 있거나 문자열이 아니면 `invalid_interaction_token`으로 거부한다.
- expected token이 현재 token과 다르면 클릭 전이를 적용하지 않는다. 현재 View만 다시 게시하고 `ok = true`, `applied = false`, `stale = true`, 현재 token을 반환한다.
- token이 정확히 같을 때만 `turnDraft.clickCard`를 호출하고 draft를 write-read 검증해 저장한 뒤 View를 게시한다. 성공은 `applied = true`, `stale = false`, 다음 View token을 반환한다.

첫 클릭 focus, 같은 카드 두 번째 클릭 등록과 등록 카드 재클릭 취소 의미는 `turnDraft` 계약을 그대로 사용한다.

draft 저장 성공 뒤 View 게시만 실패한 경우 카드 전이는 이미 확정됐지만 화면의 버튼은 이전 token을 가진다. 같은 버튼 호출은 stale 분기로 들어가 현재 View만 재게시하므로 focus를 register로, register를 cancel로 두 번 진행하지 않는다.

### `prepareGeneration()`

모든 정적·권위·draft/pending 검증과 formatter 호출을 먼저 끝낸다. 그 뒤 변경 순서는 다음과 같다.

1. 새 전송이면 pending을 저장하고 draft를 지운다.
2. 현재 prefix fingerprint와 공개 마커의 예정 위치를 담은 `chatAnchor`, 최초 `attemptNumber = 1`, `phase = "preparing"`인 `activeRequest`를 저장한다.
3. pending-aware 잠긴 `battleView`를 게시하고 wire를 다시 읽어 확인한다.
4. 끝에 연속된 정확한 `*says nothing*` 사용자 메시지를 모두 제거한다.
5. 같은 공개 마커가 이미 마지막이면 그대로 두고, 없을 때만 사용자 메시지로 한 번 추가한다.
6. 같은 binding을 `phase = "inFlight"`로 저장·재검증한다.

채팅을 마지막에 바꾸는 이유는 복구성이다. 상태 또는 View 쓰기가 중간에 실패하면 filler가 그대로 남아 다음 수동 시도에 다시 보일 수 있다. 이때 저장 `preparing` binding을 새 전송 분류보다 먼저 복구하므로 source와 pending은 바뀌지 않는다. 사용자가 다시 빈 전송하면 trailing filler가 둘 이상 쌓일 수 있으므로 성공 경계에서 연속된 마지막 filler를 모두 제거한다. 중간 또는 과거에 있는 같은 텍스트는 건드리지 않는다. 일부 단계에서 pending만 저장됐어도 다음 시도는 이를 다시 판정하지 않고 `reusePending`으로 복구한다. filler 제거 뒤 마커 추가나 최종 phase 쓰기가 실패하면 durable `preparing` binding으로 채팅 전환을 재개한다. 이미 추가된 마커는 다시 추가하지 않는다.

성공 결과는 선택한 `turnId`, `turnNumber`, `source`, `publicMarker`, `attemptNumber`, `reused`, `generationReady`, `recoveredAbandonedRequest`, `zeroOutputRetry`, `commitRecovered`, `removedSayNothing`, `removedSayNothingCount`, `removedUncommittedOutput`, 마커 추가 여부와 게시 View를 반환한다. 정상 준비, 마커만 남은 무출력 재시도와 미관측 출력 정리 재시도는 `generationReady = true`이고, 관측 출력의 commit만 복구한 호출은 `generationReady = false`다. `zeroOutputRetry`는 채팅을 전혀 바꾸지 않은 첫 경우에만 `true`다.

### `injectRequest(promptArray)`

`editRequest` 경계용 action이다. 프롬프트 배열은 복제본으로만 다루되, 성공한 주입과 이후 `onOutput`을 연결하기 위해 `activeRequest.phase` 영수증 하나를 영속화한다.

- 입력 메시지 배열 전체를 먼저 복제하며 입력을 변경하지 않는다.
- 저장 `activeRequest.phase == "inFlight"` 또는 같은 binding의 `"requestInjected"`와 그 source가 선택한 pending을 읽는다. `preparing`과 `committed`는 주입하지 않는다.
- formatter를 다시 실행해 binding의 system message와 마커를 대조한다.
- 같은 system message가 배열에 이미 있으면 복제본을 그대로 반환한다.
- 없으면 정상 요청의 기존 순서와 모든 메시지를 보존한 채 마지막에 하나만 추가한다.
- 같은 system message가 둘 이상이면 입력 복제본에서 첫 항목만 같은 위치에 보존하고 나머지만 제거한다. 다른 메시지의 순서와 내용은 보존한다.
- phase가 `inFlight`였으면 반환 전에 같은 binding을 `requestInjected`로 저장하고 즉시 재읽어 검증한다. 영수증 쓰기가 실패하면 성공 프롬프트를 반환하지 않는다. 이미 `requestInjected`이면 같은 binding을 다시 쓰지 않는다.
- `recoveringCleanup` 또는 `outputObserved`가 남은 binding에는 프롬프트를 다시 주입하지 않는다.
- authority, pending, draft, 채팅, `battleView`는 변경하지 않는다.

따라서 같은 원본 입력을 여러 번 호출한 프롬프트 결과는 같고, 첫 결과를 다시 입력하거나 이미 중복된 결과를 전달해도 비공개 사건은 정확히 하나다. 성공 결과는 `requestPhase = "requestInjected"`와 실제 추가·중복 정규화 여부를 각각 `injected`, `deduplicated`로 포함한다. 호스트의 `editRequest`가 주입 전에 실패하면 phase는 `inFlight`에 머무르므로 뒤늦은 `onOutput`이 권위 상태를 확정할 수 없다.

### `commitOutput()`

`activeRequest.source`가 지정한 pending만 확정한다. 최초 반영에는 `requestInjected` phase가 필요하다. 같은 turn의 binding이 이미 `committed`이면 중복·늦은 onOutput을 멱등 검증하는 호출만 허용한다. `preparing`과 `inFlight`는 출력과 연결하지 않는다. binding과 formatter 결과가 다르면 출력과 판정을 연결하지 않는다.

최초 `requestInjected` commit은 권위 상태를 쓰기 전에 chat anchor를 다시 확인한다. 공개 마커 바로 뒤에 캐릭터 메시지가 정확히 하나 있고 그 뒤 filler나 다른 메시지가 없어야 한다. 현재 응답 전체의 fingerprint, 위치와 `attemptNumber`를 `outputObserved`로 저장하고 즉시 다시 읽어 검증한다. 이 영수증 쓰기가 실패하면 `lastCommittedPending`, authority, draft와 pending을 전혀 변경하지 않는다. 이미 같은 영수증이 있으면 현재 응답과 다시 대조하고 중복으로 쓰지 않는다. 삭제 mode가 `retry`인 cleanup 중에는 commit하지 않는다.

`battleRuntime.commitPending`이 `applied = true`를 반환하고 전투가 계속 active이면, 반환한 afterState에 다음 턴의 결정적 `turnId`로 `turnInitializer.prepareTurn`을 한 번 호출한다. 다음 상태와 draft가 모두 성공한 뒤 다음 순서로 저장한다.

1. 사용한 pending을 `lastCommittedPending`에 저장한다.
2. 다음 턴까지 초기화한 authority를 저장한다.
3. 다음 draft를 저장한다. 전투가 끝났으면 지운다.
4. 같은 메시지·마커·chat anchor·attempt 번호를 보존하고 임시 영수증은 제거한 binding의 source를 `lastCommittedPending`, phase를 `committed`로 바꾼다.
5. 저장 pending의 `turnId`가 방금 확정한 pending과 같으면 pending을 지운다.
6. 다음 선택 View 또는 종료 View를 게시한다.

binding을 보존하므로 직전 출력의 즉시 재생성은 동일한 pending과 동일한 system message를 사용할 수 있다.
pending 원본을 먼저 `lastCommittedPending`으로 복제하므로 이후 쓰기가 실패해도 두 위치 중 하나로 같은 턴을 찾을 수 있다. committed binding 쓰기가 실패하면 `outputObserved`가 남아 다음 수동 빈 전송에서 응답을 삭제하지 않고 commit을 재개한다. binding 쓰기는 성공하고 pending 삭제가 실패하면 같은 binding으로 멱등 재시도한 뒤 같은 `turnId`의 낡은 pending만 제거한다. 다른 현재 턴 pending을 직전 턴 재생성이 지우지 않는다.

같은 출력을 다시 commit하면 `battleRuntime`의 `lastCommittedTurnId` 경계가 `applied = false`를 반환한다. 이 경우 현재 authority에 유효한 draft가 있으면 검증해서 그대로 보존하며 initializer를 다시 호출하지 않는다. 앞선 쓰기가 authority까지만 성공하고 draft가 없어진 복구 상황에서만 현재 receipt를 사용해 draft를 재구성한다. 이미 선택한 다음 턴 draft를 직전 출력 재생성이 초기화해서는 안 된다.

### `publishCurrentView()`

authority가 active이고 pending이 있으면 pending context, 없으면 draft context를 사용한다. draft 경로에서 active binding phase가 `preparing`/`inFlight`/`requestInjected`이면 `context.generationLocked = true`도 전달한다. 이는 직전 출력 재생성 중인 현재 draft의 hand·selection을 보존하면서 View를 `awaitingOutput`, `locked = true`로 만들어 버튼을 시각적으로도 잠근다. `committed`/binding 없음은 선택 View를 잠그지 않는다. 종료 상태에는 draft·pending·추가 lock을 전달하지 않으며 종료 View 자체가 잠겨 있다.

저장된 `lastCommittedPending`이 있으면 상태와 함께 `context.lastCommittedPending`으로 전달해 `view.lastTurn`을 만든다. 반대로 authority에 `lastCommittedTurnId`가 있는데 저장된 last pending이 없으면 공개 결과를 추측하지 않고 `missing_last_committed_pending`으로 실패한다. `viewBuilder` 검증, `dataBridge` 게시, raw wire 재읽기와 display reload까지 성공해야 `ok = true`다.

### `getSnapshot()`

테스트와 진단을 위한 read-only action이다. 다섯 저장 키, authority, draft, pending, last committed pending, active request와 파생된 `lastPublicResult`의 복제본을 반환한다. 값이 없는 선택 필드는 생략된다. 저장이나 View 게시를 수행하지 않는다.

## 7. 입력 불변성과 비공개 경계

모든 테이블 입력은 복제·검증 뒤 사용한다. controller action, 하위 모듈과 호스트 mock이 전달한 원본 테이블을 결과 저장소로 재사용하지 않는다.

일반 요청에는 formatter가 만든 허용 목록 system message 하나만 추가한다. `pendingTurn`, projection receipt, 선택 카드 인스턴스 ID, RNG와 내부 사건 원본을 직접 직렬화하지 않는다. 공개 사용자 마커에는 턴 번호만 들어간다. View는 `viewBuilder`가 검증한 공개 projection만 `dataBridge`에 전달한다.

## 8. 자동 삭제의 호스트 전제와 한계

컨트롤러가 현재 받는 Lua API에는 생성 요청과 채팅 메시지를 서로 대조할 고유 request/message ID가 없으므로, 최초 cleanup 영수증을 만들기 전 공개 마커 뒤의 단일 `role = "char"` 메시지가 해당 요청의 중단된 스트림인지 정보상 완전히 증명할 수 없다. 컨트롤러는 저장된 active request, 변경되지 않은 전체 prefix, 고정 마커 위치, 단일 char와 trailing filler라는 직렬 구조를 함께 근거로 소유권을 제한한다. 사용자가 그 위치에 캐릭터 메시지를 직접 편집·교체했거나 다른 확장이 삽입한 뒤 빈 전송을 누르면 그 메시지를 실패 출력으로 판단할 위험은 남는다.

따라서 실제 통합에서 다음 전제를 확인해야 한다.

- 새 수동 `onStart`는 이전 생성·스트림이 종료된 뒤 직렬로만 시작한다. 동시 생성이 가능하면 늦은 스트림 쓰기와 cleanup이 경합하므로 자동 삭제를 활성화하지 않는다.
- 공개 마커 이전 메시지와 생성이 끝난 char 메시지의 host metadata는 사후 변경되지 않는다. 변경되면 fingerprint가 달라져 안전하게 복구를 거부할 수 있다.
- 전투 중 사용자가 공개 마커와 그 직후 캐릭터 응답을 수동 편집하지 않고, 다른 스크립트도 그 사이에 메시지를 삽입하지 않는다.

`battleActiveRequest` schema v2는 아직 실제 훅 배포 전인 로컬 경계다. 기존 schema v1 진행 상태가 있는 환경에서는 자동 마이그레이션하지 않고 fail-closed하므로 전투를 새로 초기화해야 한다.

## 9. 로컬 훅 연결과 실제 검증 범위

승인된 `System/main.lua`의 로컬 연결은 다음 의미를 가진다.

- 비어 있지 않은 전투 입력 → `editInput`에서 정확한 `*says nothing*`으로 정규화
- 빈 수동 전송 준비 경계 → `battleController.prepareGeneration`
- `prepareGeneration` 성공이어도 `generationReady = false`이면 복구된 commit만 마치고 현재 전송은 취소
- `editRequest` → `battleController.injectRequest`, 성공 시 `report.promptArray` 반환
- 정상 `onOutput` → `battleController.commitOutput`
- 전투 카드 버튼 → `battleController.clickCard(instanceId, battleView.interactionToken)`

정확한 hook 실행 순서, mode별 쓰기 권한과 생성 중 중복 전송 차단은 실제 RisuAI에서 다시 확인해야 한다. 현재 UI 템플릿 변수 `🔯🔯🔯`에 전투 표시 anchor를 설정하는 일과 HTML/CBS가 `battleView`를 렌더링하도록 연결하는 일도 별도 UI 통합 범위다. 컨트롤러는 `battleView` wire 게시와 `reloadDisplay`까지만 책임진다.

## 10. 로컬 검증

`.agents/Tests/battle-controller-check.ps1`은 실제 순수 모듈을 함께 불러와 두 개의 독립 Lua 프로세스에서 다음을 검사한다.

- 명시적 ID·시드 bootstrap, 첫 턴 초기화와 선택 View 게시
- 카드 focus·등록과 draft 저장
- 클릭 뒤 View 게시 실패, 구 interaction token 재호출의 전이 비적용·표시 복구와 token 회전
- 무시된 `activeRequest` 쓰기의 write-read 실패, filler 보존과 저장 pending 재사용 복구
- 연속된 trailing exact filler 전체 제거, 과거 filler 보존, 공개 마커 추가와 중복 억제
- 마커 쓰기 실패 및 마커 확인 뒤 최종 `inFlight` phase 쓰기 유실에서 `preparing` binding 기반 재개
- 직전 턴 재생성의 `preparing` 복구 중 새 filler가 와도 source 유지
- 정확한 마커만 남은 `inFlight`·`requestInjected` 요청의 무삭제 재시도, attempt 영속 쓰기 유실 시 채팅·pending·attempt 보존
- 캐릭터 출력처럼 마커 뒤에 filler 없는 suffix가 있는 잠긴 요청의 추가 onStart 무변경 거부
- 정상 프롬프트 보존, 입력 불변, 멱등 system message 주입과 동일 사건 중복 정규화
- 영수증 쓰기 유실 시 `inFlight` 보존, 주입 전 commit 거부와 authority/pending 불변, 성공 시 `requestInjected` 영수증 영속화
- char 출력 없는 commit 거부와 권위 상태 불변
- 출력 관측 영수증 쓰기 유실 시 authority·pending·완성 응답 불변
- prefix anchor 위변조 시 무삭제 거부, 미관측 부분 응답과 trailing filler의 자동 삭제, 같은 pending·RNG·마커를 쓰는 attempt 재시도
- cleanup 영수증 저장 뒤 filler 삭제와 char 삭제 사이의 중단, 응답 fingerprint 위변조 거부와 다음 호출 재개
- 최초 commit, 다음 active 턴 한 번 초기화와 pending 이동
- output 관측 영수증 뒤 committed binding 쓰기 실패, 다음 빈 전송에서 완성 char를 보존한 commit migration 복구와 다음 턴 중복 초기화 방지
- 중복 commit과 직전 출력 재생성에서 authority·다음 draft 불변
- 직전 재생성 동안 generation-locked View와 카드 클릭 거부, commit 뒤 draft 잠금 해제
- authority의 확정 turnId와 저장 last pending 불일치 시 View fail-closed
- 새 턴 pending 생성과 지원하지 않는 Continue 유사 경로 거부
- battleView wire 재읽기와 확인 뒤 `reloadDisplay`
- strict 오류 envelope와 별도 프로세스 결정성

로컬 검사는 실제 RisuAI의 hook 순서, mode별 권한, 채팅 재생성 UI 동작과 CBS/HTML 렌더링을 대신하지 않는다.
