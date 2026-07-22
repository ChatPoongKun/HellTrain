# 전투 호스트 컨트롤러 계약 v1

## 1. 범위

`System/battleController.lua`는 순수 전투 모듈과 RisuAI 호스트 저장소·대화·View 게시 경계를 연결하는 어댑터다. 컨트롤러는 전투 규칙을 다시 판정하지 않고 다음 모듈의 성공 결과만 조정한다.

- `staticData.loadAll`
- `gameSetup.validate`
- `battleBootstrap.fromSetup`, `battleBootstrap.verticalSlice`
- `turnInitializer.prepareTurn`
- `turnDraft.applyInteraction`, `turnDraft.inspect`, `turnDraft.project`, `turnDraft.validate`
- `battleRuntime.preparePending`, `battleRuntime.reusePending`, `battleRuntime.commitPending`
- `turnPromptFormatter.formatPending`
- `viewBuilder.buildBattleView`
- `dataBridge._publishCanonical` (함수 capability가 있는 내부 경로)

LLM을 직접 호출하거나 전송을 자동화하지 않는다. Continue, 프롬프트 미리보기와 출력 재생성은 v1에서 지원하지 않는다. 새 턴은 마지막의 전용 user UI anchor를 사용자가 빈 입력으로 전송했을 때만 준비한다.

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
    schemaVersion = 3,
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
        schemaVersion = 2,
        kind = "battleChatAnchor",
        prefixMessageCount = 3,
        responseIndex = 3,
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
        responseIndex = 3,
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
        responseIndex = 3,
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

binding의 식별자·턴 번호는 선택한 pending과 같아야 한다. `message`와 `publicMarker`는 `turnPromptFormatter.formatPending`을 다시 호출한 결과와 정확히 같아야 한다. 이름을 유지한 `publicMarker`는 이제 실제 채팅이 아니라 `editRequest`에만 넣는 user 장면 지시다. `committed` phase는 반드시 `lastCommittedPending` source를 사용한다. `attemptNumber`는 같은 pending의 생성 재시도 횟수이며 최초는 1이다. 응답이 하나도 생기지 않은 무출력 재시도 또는 미관측 출력을 정리한 재시도에서만 1씩 증가한다. 판정·pending·RNG 결과는 다시 만들지 않는다.

`chatAnchor.prefixMessageCount`는 제출용 UI anchor와 trailing filler를 제외한 메시지 수다. 다음 캐릭터 응답의 RisuAI 0-based 위치인 `responseIndex`와 같은 값이어야 한다. prefix fingerprint는 자료형·길이·정렬된 객체 키를 포함하는 canonical 직렬화를 서로 다른 두 다항 해시와 길이로 요약한다. 이는 저장 손상과 우발적 오인 삭제를 막는 비암호학적 무결성 식별자이지 보안용 해시는 아니다. 삭제 권한은 fingerprint 하나가 아니라 고정 prefix, 정확한 응답 위치와 허용된 suffix 구조, 삭제 뒤 전체 prefix 재검증을 모두 통과해야 생긴다.

phase 의미는 다음과 같다.

- `preparing`: pending·binding·잠긴 View는 저장됐지만 trailing filler/UI anchor 제거가 아직 완료되지 않았거나 확인되지 않았다.
- `inFlight`: 채팅 전환까지 확인되어 `editRequest` 주입만 허용한다. 아직 출력 commit의 근거는 아니다.
- `requestInjected`: `injectRequest`가 formatter의 비공개 사건 system 메시지와 user 장면 지시를 프롬프트에 정확히 한 번씩 포함하고 같은 binding에 영속 영수증을 썼다. 최초 출력 commit은 이 phase에서만 허용한다. `outputObserved`가 있으면 `onOutput`이 저장된 응답 위치의 캐릭터 메시지를 확인했고 commit을 시작했다는 뜻이다.
- `committed`: 출력이 이미 권위 상태에 반영됐다. 카드 선택은 허용하고 같은 turn의 늦은 `commitOutput`만 멱등 no-op으로 허용한다. `chatAnchor`와 `attemptNumber`는 보존하지만 `outputObserved`와 `recoveringCleanup`은 제거한다.

`outputObserved`는 `requestInjected`에만, `recoveringCleanup`은 `inFlight` 또는 `requestInjected`에만 존재할 수 있다. `retry` cleanup에는 `outputObserved`가 없어야 하고 `resumeCommit` cleanup에는 반드시 있어야 한다.

## 4. 저장 내구성

모든 영속 상태 쓰기는 다음 순서를 지킨다.

1. 입력을 함수·메타테이블·순환 참조·비유한 숫자가 없는 JSON 데이터로 복제한다.
2. `setState(triggerId, key, value)`를 호출한다.
3. 즉시 `getState(triggerId, key)`로 다시 읽는다.
4. 쓰려던 값과 구조적으로 정확히 같지 않으면 `state_write_not_persisted`로 실패한다.

따라서 RisuAI 권한 문제로 쓰기가 조용히 무시되는 경우를 성공으로 취급하지 않는다. 읽은 테이블도 그대로 반환하거나 수정하지 않고 먼저 복제한다.

`battleView`는 같은 transaction에서 `viewBuilder.buildBattleView`가 schema allowlist 검증을 끝낸 값이다. 따라서 컨트롤러는 `purpose == "dataBridgeCanonicalV1"`이고 `viewName == "battleView"`일 때만 승인하는 private 함수 capability와 함께 `dataBridge._publishCanonical`을 호출한다. bridge의 JSON-safe 검사는 유지하며, 일반 외부 `publish` 경로에는 이 우회를 노출하지 않는다.

게시 뒤에는 `getChatVar("battleView")`가 반환한 wire와 encoder 결과가 정확히 같은지 항상 검사한다. hook·명시적 `publishCurrentView`처럼 버튼 밖에서 게시하면 확인 뒤 `refreshGameUi`의 대상 `reloadChat(-1)`을 사용하고 불가능할 때만 `reloadDisplay`로 복구한다. `registerCard`/`cancelCard`/`clickCard`는 RisuAI button host가 클릭 message를 자동 remount하므로 수동 reload를 중복하지 않는다. 저장되지 않은 View에는 controller reload를 요청하지 않는다.

전투 UI body도 같은 현재 View에 결합한다. `battleView` wire의 write-read 검증이 끝난 뒤에만 CBS를 평가하는 `battleui.html`을 로드하고, 그 결과를 동적 UI body `🔯🔯🔯`에 쓴 뒤 다시 읽어 exact-equal을 확인한다. setup의 캐릭터 확정 버튼에서 호출되는 `startFromSetup`은 button host remount를 사용하므로 이 게시에서 refresh를 억제한다. 훅과 명시적 게시 경로는 검증 뒤 기존 refresh 규칙을 따른다.

채팅의 제거·추가도 `getFullChat`으로 다시 읽어 길이, 기존 prefix와 마지막 메시지를 확인한다. RisuAI 채팅 index는 0부터 시작하므로 Lua 배열의 마지막 항목은 `removeChat(triggerId, #chat - 1)`로 제거한다.

자동 복구 삭제는 반드시 `recoveringCleanup`을 먼저 write-read 검증한 뒤 시작한다. filler 또는 미관측 응답을 한 항목 지울 때마다 길이가 정확히 1 줄었고 나머지 모든 메시지가 구조적으로 그대로인지 다시 읽어 검사한다. 삭제 도중 오류·권한 거부·조용한 쓰기 유실이 발생하면 cleanup 영수증을 지우지 않으므로 다음 `onStart`가 이미 끝난 단계부터 재개한다. 영수증과 현재 채팅이 다르면 어떤 메시지도 추가로 삭제하지 않는다.

## 5. UI anchor, request-only 지시와 생성 분류

formatter가 반환하는 다음 문구는 모델 요청에만 들어가는 user 지시다. 실제 RisuAI 채팅에는 저장하지 않는다.

```text
[전투 턴 N] 이번 턴에 실제로 벌어진 일을 하나의 장면으로 이어서 묘사한다.
```

`N` 외에는 카드, 선택, 수치 결과, RNG, 캐릭터 의도와 내부 ID를 넣지 않는다. 화면의 제출 신호는 별도의 exact user 메시지 `@@HELLTRAIN_UI_ANCHOR_V1@@`다. `main.lua`의 `editDisplay`가 이 메시지를 UI로 렌더하므로 사용자는 입력창을 비운 채 Risu 전송 버튼을 누를 수 있다.

`prepareGeneration`은 저장 요청 phase를 먼저 확인하고, 그 다음 대화 suffix를 fail-closed 분류한다.

- 저장 `activeRequest.phase == "preparing"`이면 새 suffix보다 앞선 실패 복구를 우선한다. binding이 가리키는 동일 pending과 formatter 결과만 다시 검증·사용한다.
- 저장 `activeRequest.phase == "inFlight"` 또는 `"requestInjected"`이고 cleanup·출력 관측 영수증이 없으며 저장 prefix 뒤 응답이 없으면 같은 요청을 무출력 재시도한다.
- 잠긴 요청의 응답 위치에 메시지가 있는데 exact filler가 없으면 추가 `onStart`를 `request_already_in_flight`로 거부한다. 다른 suffix는 삭제하거나 재시도하지 않는다.
- 잠긴 요청 뒤에 새 exact filler가 있으면 실패한 생성의 수동 재시도로 분류한다. cleanup 영수증이 이미 있으면 앞선 삭제가 중단된 것으로 보고 새 filler가 없어도 정리를 재개한다.
- 저장 `activeRequest.phase == "committed"`인데 같은 `turnId`의 낡은 pending이 남아 있으면 새 전송 분류 전에 멱등 commit으로 이동·삭제를 끝낸다.
- 마지막 exact UI anchor와 그 뒤의 선택적 exact filler는 새 수동 전송이다. 부분 문자열, 다른 role과 다른 메시지는 anchor로 인정하지 않는다.
- committed 응답 뒤 UI anchor가 없으면 새 턴을 만들지 않고 `uiAnchorRequired = true`, `generationReady = false`로 UI 복구만 요청한다.
- 나머지는 `unsupported_generation_source`다. 출력 재생성은 이 UI anchor 구조에서 지원하지 않는다.

새 전송에 이미 `pending`이 있으면 생성 실패 뒤 재시도로 보고 `battleRuntime.reusePending`을 사용한다. pending이 없을 때만 저장 draft를 projection으로 만들고 `battleRuntime.preparePending`을 호출한다.

잠긴 요청의 무출력 재시도가 허용하는 채팅 구조는 정확히 다음뿐이다.

```text
저장 chatAnchor와 fingerprint가 같은 전체 prefix
→ 저장된 responseIndex에 메시지 없음
```

`outputObserved`와 `recoveringCleanup`이 모두 없어야 하며, source가 `pending`이면 같은 턴의 authority commit 또는 `lastCommittedPending` 흔적도 없어야 한다. 이 경로는 채팅을 삭제하거나 추가하지 않고 같은 binding을 `inFlight`로 되돌려 `attemptNumber`만 증가시킨 뒤 `generationReady = true`, `zeroOutputRetry = true`를 반환한다. pending, formatter message, request-only 지시와 RNG 결과는 그대로 재사용한다. 상태 쓰기가 확인되지 않으면 attempt도 소비하지 않는다.

잠긴 요청의 삭제 복구가 허용하는 채팅 구조는 정확히 다음뿐이다.

```text
저장 chatAnchor와 fingerprint가 같은 전체 prefix
→ responseIndex의 캐릭터 메시지 0개 또는 1개
→ trailing exact filler 1개 이상
```

prefix가 달라졌거나 캐릭터 응답이 둘 이상이거나 다른 role·메시지가 섞였으면 삭제하지 않고 실패한다. source가 `pending`인데 같은 turn의 authority commit 또는 `lastCommittedPending` 흔적이 있는 예외 상태도 `outputObserved` 없이 삭제하거나 재시도하지 않는다.

- `outputObserved`가 없으면 cleanup mode는 `retry`다. 영수증을 먼저 저장하고 trailing filler와 있을 수 있는 캐릭터 부분 응답 하나를 검증하며 삭제한다. 같은 binding을 `inFlight`로 되돌리고 `attemptNumber`만 증가시킨다.
- `outputObserved`가 있으면 cleanup mode는 `resumeCommit`이다. trailing filler만 삭제하고 fingerprint가 같은 완성 캐릭터 응답은 보존한 채 `commitOutput`을 멱등 재개한다. filler가 없는 경우에는 `prepareGeneration`이 commit을 직접 재개한다. 두 경우 모두 `generationReady = false`, `commitRecovered = true`다.

현재 Lua `onStart`에는 수동 빈 전송과 프롬프트 미리보기·자동 계속을 구분할 source 정보가 없다. 전투 UI가 활성화된 동안 프롬프트 미리보기와 자동 계속을 사용하지 않고, 생성 중 새 전송이 직렬화된다는 전제를 실제 웹 통합 검사에서 확인해야 한다.

## 6. Action 계약

### `startFromSetup(setupState)`

일반 게임 시작의 내부 인계 action이다. 전달받은 전체 설정 상태를 복제한 뒤 `gameSetup.validate`로 처음부터 재생하고, 입력이 canonical `battleReady`와 exact-equal일 때만 진행한다. 여기서 다음 전투 사양을 꺼내 `battleBootstrap.fromSetup`에 전달한다.

```lua
{
    battleId = setupState.battleSpec.battleId,
    seed = setupState.battleSpec.seed,
    playerCardIds = setupState.selectedCardIds,
    characterId = setupState.selectedCharacterId,
    environmentId = setupState.battleSpec.environmentId,
    turnLimit = setupState.battleSpec.turnLimit,
}
```

새 전투는 bootstrap의 pre-initializer 상태에 `<battleId>-turn-001`을 사용해 `turnInitializer.prepareTurn`을 정확히 한 번 적용한다. authority와 draft가 모두 만들어진 뒤 다음 다섯 키를 순서대로 write-read 검증한다.

```text
battleRuntimeV1.authority
→ battleRuntimeV1.draft
→ battleRuntimeV1.pending = nil
→ battleRuntimeV1.lastCommittedPending = nil
→ battleRuntimeV1.activeRequest = nil
```

그 뒤 `battleView`를 게시·재읽기하고, 그 View로 CBS 평가한 `battleui.html`을 동적 UI body에 게시·재읽기한다. 두 게시가 끝나기 전에는 성공을 반환하지 않는다.

재호출은 다음처럼 보수적으로 처리한다.

- 다른 `battleId`의 authority가 있으면 기존 전투를 덮어쓰지 않고 `battle_runtime_conflict`로 실패한다.
- 같은 `battleId`라도 RNG seed, 환경, 턴 제한, 선택 캐릭터 또는 `player-001`부터 이어지는 초기 플레이어 카드 순서가 setup과 다르면 `battle_setup_conflict`로 실패한다.
- 결합이 같은 정상 진행 전투는 authority, draft, pending과 생성 binding을 초기화하지 않는다. 현재 상태에서 View/UI만 다시 게시하고 `applied = false`, `reused = true`를 반환한다.
- 새 시작 중 authority 또는 draft 쓰기만 끝난 부분 상태는 setup에서 결정적으로 다시 만든 초기 값과 각 non-nil 항목이 exact-equal일 때만 나머지를 채운다. 다르면 `unsafe_partial_battle_runtime`으로 실패한다.

이 action은 `gameSetupController`만 호출하는 내부 경계이며 `main.lua` 버튼 allowlist나 HTML route에 직접 노출하지 않는다.

### `startVerticalSlice(battleId, seed)`

`battleId`와 `seed`를 옵션 객체에서 추론하지 않고 명시적 두 인자로 받는다. 컨트롤러는 정적 데이터를 먼저 불러온 뒤 다음을 호출한다.

```lua
runScript(triggerId, "battleBootstrap", "verticalSlice", {
    battleId = battleId,
    seed = seed,
}, staticData)
```

bootstrap은 pre-initializer 상태만 반환한다. 컨트롤러가 `<battleId>-turn-001` 형식의 `turnId`로 `turnInitializer.prepareTurn`을 한 번 호출하고, 초기화된 authority와 draft가 모두 만들어진 뒤에만 저장을 시작한다. `pending`, `lastCommittedPending`, `activeRequest`는 지우고 선택 가능 View를 게시한다.

### `registerCard` / `cancelCard` / `clickCard`

현재 UI는 native `details`로 카드 상세를 로컬에서 즉시 열고, 실제 권위 변경에만 `registerCard(instanceId, expectedInteractionToken)` 또는 `cancelCard(instanceId, expectedInteractionToken)`을 호출한다. `clickCard(instanceId, expectedInteractionToken)`은 첫 호출 focus, 같은 카드 두 번째 호출 등록, 등록 카드 재호출 취소라는 v1 클라이언트 호환 action으로 남는다.

pending이 존재하거나 `activeRequest.phase`가 `preparing`/`inFlight`/`requestInjected`이면 `battle_view_locked`로 거부한다. `committed` binding은 이전 출력의 감사·재생성 자료일 뿐이므로 다음 턴 카드 선택을 막지 않는다.

선택 가능한 `battleView.interactionToken`은 검증된 현재 draft fingerprint에서 만든 비어 있지 않은 `draftv1_...` 문자열이다. 버튼은 instance ID와 화면을 만들 때 받은 token을 함께 보내야 한다. 컨트롤러는 공개 action을 `click`/`register`/`cancel`로 고정한 뒤 저장 authority·draft와 함께 `turnDraft.applyInteraction`에 전달한다. 이 호출 하나가 외부 ingress 검증, 현재 token 계산, stale 판정, 전이와 다음 token 계산을 수행한다.

- expected token이 비어 있거나 문자열이 아니면 `invalid_interaction_token`으로 거부한다.
- expected token이 현재 token과 다르면 전이를 적용하지 않는다. 현재 View만 다시 게시하고 `ok = true`, `applied = false`, `stale = true`, 현재 token을 반환한다.
- token이 정확히 같을 때만 선택 전이를 적용한다. 실제 draft가 바뀌면 write-read 검증해 저장한 뒤 View를 게시한다. 성공은 `stale = false`와 다음 View token을 반환하며, 이미 같은 상태인 명시 register/cancel은 `applied = false`인 멱등 no-op이다.
- 게시된 View token은 `applyInteraction`이 계산한 다음 token과 정확히 같아야 한다. 저장 경계를 다시 읽어 만든 View가 다르면 fail-closed한다.

draft 저장 성공 뒤 View 게시만 실패한 경우 카드 전이는 이미 확정됐지만 화면의 버튼은 이전 token을 가진다. 같은 버튼 호출은 stale 분기로 들어가 현재 View만 재게시하므로 register를 cancel로 또는 legacy focus를 register로 두 번 진행하지 않는다. draft write-read와 View wire readback, pending/commit 복구 journal은 이 최적화로 완화하지 않는다.

### `prepareGeneration()`

모든 정적·권위·draft/pending 검증과 formatter 호출을 먼저 끝낸다. 그 뒤 변경 순서는 다음과 같다.

1. 새 전송이면 pending을 저장하고 draft를 지운다.
2. trailing UI anchor/filler를 제외한 prefix fingerprint와 다음 응답 위치를 담은 `chatAnchor`, 최초 `attemptNumber = 1`, `phase = "preparing"`인 `activeRequest`를 저장한다.
3. pending-aware 잠긴 `battleView`를 게시하고 wire를 다시 읽어 확인한다.
4. 끝에 연속된 정확한 `*says nothing*` 사용자 메시지를 모두 제거한다.
5. trailing exact UI anchor를 제거하고 write-read로 확인한다.
6. 채팅이 저장 prefix에서 정확히 끝나는지 확인한 뒤 같은 binding을 `phase = "inFlight"`로 저장·재검증한다.

채팅을 마지막에 바꾸는 이유는 복구성이다. 상태 또는 View 쓰기가 중간에 실패하면 UI anchor/filler가 그대로 남아 다음 수동 시도에 다시 보일 수 있다. 이때 저장 `preparing` binding을 새 전송 분류보다 먼저 복구하므로 source와 pending은 바뀌지 않는다. 성공 경계에서는 연속된 마지막 filler와 exact UI anchor 하나만 제거하고, 중간 또는 과거의 같은 텍스트는 건드리지 않는다. 일부 단계에서 pending만 저장됐어도 다음 시도는 이를 다시 판정하지 않고 `reusePending`으로 복구한다. anchor 제거나 최종 phase 쓰기가 실패하면 durable `preparing` binding으로 채팅 전환을 재개한다.

성공 결과는 선택한 `turnId`, `turnNumber`, `source`, request-only `publicMarker`, `attemptNumber`, `reused`, `generationReady`, `recoveredAbandonedRequest`, `zeroOutputRetry`, `commitRecovered`, `uiAnchorRequired`, `removedSayNothing`, `removedSayNothingCount`, `removedUiAnchor`, `removedUncommittedOutput`와 게시 View를 반환한다. 정상 준비, prefix-only 무출력 재시도와 미관측 출력 정리 재시도는 `generationReady = true`이고, 관측 출력 commit 또는 UI만 복구한 호출은 `generationReady = false`다. 호환 필드 `markerAdded`는 항상 false다.

### `injectRequest(promptArray)`

`editRequest` 경계용 action이다. 프롬프트 배열은 복제본으로만 다루되, 성공한 주입과 이후 `onOutput`을 연결하기 위해 `activeRequest.phase` 영수증 하나를 영속화한다.

- 입력 메시지 배열 전체를 먼저 복제하며 입력을 변경하지 않는다.
- 저장 `activeRequest.phase == "inFlight"` 또는 같은 binding의 `"requestInjected"`와 그 source가 선택한 pending을 읽는다. `preparing`과 `committed`는 주입하지 않는다.
- formatter를 다시 실행해 binding의 system message와 request-only user 지시를 대조한다.
- 기존 배열에서 두 exact 메시지를 모두 제거하고, 다른 메시지의 순서와 내용을 보존한다.
- 마지막에 system 사건 메시지, `{ role = "user", content = publicMarker }` 순서로 각각 정확히 한 번 추가한다.
- 같은 exact 메시지가 둘 이상이면 정규화 결과에는 하나만 남기고 `deduplicated = true`를 반환한다.
- phase가 `inFlight`였으면 반환 전에 같은 binding을 `requestInjected`로 저장하고 즉시 재읽어 검증한다. 영수증 쓰기가 실패하면 성공 프롬프트를 반환하지 않는다. 이미 `requestInjected`이면 같은 binding을 다시 쓰지 않는다.
- `recoveringCleanup` 또는 `outputObserved`가 남은 binding에는 프롬프트를 다시 주입하지 않는다.
- authority, pending, draft, 채팅, `battleView`는 변경하지 않는다.

따라서 같은 원본 입력을 여러 번 호출한 프롬프트 결과는 같고, 첫 결과를 다시 입력하거나 이미 중복된 결과를 전달해도 사건과 장면 지시는 각각 정확히 하나다. 두 메시지는 반환 prompt 배열에만 존재하고 raw chat에는 없다. 성공 결과는 `requestPhase = "requestInjected"`와 실제 추가·중복 정규화 여부를 각각 `injected`, `deduplicated`로 포함한다. 호스트의 `editRequest`가 주입 전에 실패하면 phase는 `inFlight`에 머무르므로 뒤늦은 `onOutput`이 권위 상태를 확정할 수 없다.

### `commitOutput()`

`activeRequest.source`가 지정한 pending만 확정한다. 최초 반영에는 `requestInjected` phase가 필요하다. 같은 turn의 binding이 이미 `committed`이면 중복·늦은 onOutput을 멱등 검증하는 호출만 허용한다. `preparing`과 `inFlight`는 출력과 연결하지 않는다. binding과 formatter 결과가 다르면 출력과 판정을 연결하지 않는다.

최초 `requestInjected` commit은 권위 상태를 쓰기 전에 chat anchor를 다시 확인한다. 저장 prefix 바로 뒤 `responseIndex`에 캐릭터 메시지가 정확히 하나 있고 그 뒤 filler나 다른 메시지가 없어야 한다. 현재 응답 전체의 fingerprint, 위치와 `attemptNumber`를 `outputObserved`로 저장하고 즉시 다시 읽어 검증한다. 이 영수증 쓰기가 실패하면 `lastCommittedPending`, authority, draft와 pending을 전혀 변경하지 않는다. 이미 같은 영수증이 있으면 현재 응답과 다시 대조하고 중복으로 쓰지 않는다. 삭제 mode가 `retry`인 cleanup 중에는 commit하지 않는다.

`battleRuntime.commitPending`이 `applied = true`를 반환하고 전투가 계속 active이면, 반환한 afterState에 다음 턴의 결정적 `turnId`로 `turnInitializer.prepareTurn`을 한 번 호출한다. 다음 상태와 draft가 모두 성공한 뒤 다음 순서로 저장한다.

1. 사용한 pending을 `lastCommittedPending`에 저장한다.
2. 다음 턴까지 초기화한 authority를 저장한다.
3. 다음 draft를 저장한다. 전투가 끝났으면 지운다.
4. 같은 메시지·마커·chat anchor·attempt 번호를 보존하고 임시 영수증은 제거한 binding의 source를 `lastCommittedPending`, phase를 `committed`로 바꾼다.
5. 저장 pending의 `turnId`가 방금 확정한 pending과 같으면 pending을 지운다.
6. 다음 선택 View 또는 종료 View를 refresh 없이 게시한다. `main.onOutput`이 장면 응답 다음에 새 user UI anchor를 추가하고 그 인덱스를 활성화한다.

binding을 보존하므로 늦은 중복 `onOutput`과 부분 commit을 동일한 pending/system/user 지시에 대조할 수 있다. pending 원본을 먼저 `lastCommittedPending`으로 복제하므로 이후 쓰기가 실패해도 두 위치 중 하나로 같은 턴을 찾을 수 있다. committed binding 쓰기가 실패하면 `outputObserved`가 남아 다음 수동 빈 전송에서 응답을 삭제하지 않고 commit을 재개한다. binding 쓰기는 성공하고 pending 삭제가 실패하면 같은 binding으로 멱등 재시도한 뒤 같은 `turnId`의 낡은 pending만 제거한다.

같은 출력을 다시 commit하면 `battleRuntime`의 `lastCommittedTurnId` 경계가 `applied = false`를 반환한다. 이 경우 현재 authority에 유효한 draft가 있으면 검증해서 그대로 보존하며 initializer를 다시 호출하지 않는다. 앞선 쓰기가 authority까지만 성공하고 draft가 없어진 복구 상황에서만 현재 receipt를 사용해 draft를 재구성한다. 이미 선택한 다음 턴 draft를 직전 출력 재생성이 초기화해서는 안 된다.

### `publishCurrentView()`

authority가 active이고 pending이 있으면 pending context, 없으면 draft context를 사용한다. draft 경로에서 active binding phase가 `preparing`/`inFlight`/`requestInjected`이면 `context.generationLocked = true`도 전달한다. 이는 직전 출력 재생성 중인 현재 draft의 hand·selection을 보존하면서 View를 `awaitingOutput`, `locked = true`로 만들어 버튼을 시각적으로도 잠근다. `committed`/binding 없음은 선택 View를 잠그지 않는다. 종료 상태에는 draft·pending·추가 lock을 전달하지 않으며 종료 View 자체가 잠겨 있다.

저장된 `lastCommittedPending`이 있으면 상태와 함께 `context.lastCommittedPending`으로 전달해 `view.lastTurn`을 만든다. 반대로 authority에 `lastCommittedTurnId`가 있는데 저장된 last pending이 없으면 공개 결과를 추측하지 않고 `missing_last_committed_pending`으로 실패한다. `viewBuilder` 검증, `dataBridge` 게시와 raw wire 재읽기가 필수다. display는 호출 경로에 따라 host button remount 또는 검증 후 `refreshGameUi`로 반영한다.

### `getSnapshot()`

테스트와 진단을 위한 read-only action이다. 다섯 저장 키, authority, draft, pending, last committed pending, active request와 파생된 `lastPublicResult`의 복제본을 반환한다. 값이 없는 선택 필드는 생략된다. 저장이나 View 게시를 수행하지 않는다.

## 7. 입력 불변성과 비공개 경계

모든 테이블 입력은 복제·검증 뒤 사용한다. controller action, 하위 모듈과 호스트 mock이 전달한 원본 테이블을 결과 저장소로 재사용하지 않는다.

일반 요청에는 formatter가 만든 허용 목록 system message와 턴 번호만 가진 request-only user 지시를 각각 하나 추가한다. `pendingTurn`, projection receipt, 선택 카드 인스턴스 ID, RNG와 내부 사건 원본을 직접 직렬화하지 않는다. View는 `viewBuilder`가 검증한 공개 projection만 `dataBridge`에 전달한다.

## 8. 자동 삭제의 호스트 전제와 한계

컨트롤러가 현재 받는 Lua API에는 생성 요청과 채팅 메시지를 서로 대조할 고유 request/message ID가 없으므로, 최초 cleanup 영수증을 만들기 전 저장 `responseIndex`의 단일 `role = "char"` 메시지가 해당 요청의 중단된 스트림인지 정보상 완전히 증명할 수 없다. 컨트롤러는 저장된 active request, 변경되지 않은 전체 prefix, 고정 응답 위치, 단일 char와 trailing filler라는 직렬 구조를 함께 근거로 소유권을 제한한다. 사용자가 그 위치에 캐릭터 메시지를 직접 편집·교체했거나 다른 확장이 삽입한 뒤 빈 전송을 누르면 그 메시지를 실패 출력으로 판단할 위험은 남는다.

따라서 실제 통합에서 다음 전제를 확인해야 한다.

- 새 수동 `onStart`는 이전 생성·스트림이 종료된 뒤 직렬로만 시작한다. 동시 생성이 가능하면 늦은 스트림 쓰기와 cleanup이 경합하므로 자동 삭제를 활성화하지 않는다.
- 저장 prefix 메시지와 생성이 끝난 char 메시지의 host metadata는 사후 변경되지 않는다. 변경되면 fingerprint가 달라져 안전하게 복구를 거부할 수 있다.
- 전투 중 사용자가 요청 prefix와 직후 캐릭터 응답을 수동 편집하지 않고, 다른 스크립트도 그 사이에 메시지를 삽입하지 않는다.

`battleActiveRequest` schema v3와 `battleChatAnchor` schema v2는 실제 채팅 공개 마커를 없앤 경계다. 이전 active request 진행 상태는 자동 마이그레이션하지 않고 fail-closed하므로 전투를 새로 초기화해야 한다.

## 9. 로컬 훅 연결과 실제 검증 범위

승인된 `System/main.lua`의 로컬 연결은 다음 의미를 가진다.

- 비어 있지 않은 전투 입력 → `editInput`에서 정확한 `*says nothing*`으로 정규화
- 게임 시작 성공 → exact user UI anchor 채팅 추가, first-message UI 은퇴
- UI anchor에서 빈 수동 전송 → `battleController.prepareGeneration`, durable 준비 뒤 해당 anchor 제거
- `prepareGeneration` 성공이어도 `generationReady = false`이면 commit/UI 복구만 마치고 현재 전송은 취소
- `editRequest` → `battleController.injectRequest`, 성공 시 request-only system/user 쌍을 포함한 `report.promptArray` 반환
- 정상 `onOutput` → `battleController.commitOutput`, 성공 뒤 장면 다음에 새 user UI anchor 추가
- 카드 상세 `<details>`/`<summary>` → 브라우저 로컬 상태만 변경, Lua 호출 없음
- 카드 등록 버튼 → `battleController.registerCard(instanceId, battleView.interactionToken)`
- 등록 취소 버튼 → `battleController.cancelCard(instanceId, battleView.interactionToken)`
- 구 UI 카드 버튼 → `battleController.clickCard(instanceId, battleView.interactionToken)` 호환

정확한 hook 실행 순서, mode별 쓰기 권한과 생성 중 중복 전송 차단은 실제 RisuAI에서 다시 확인해야 한다. 시작 전 UI는 first-message sentinel을 사용하고, 시작 후 UI는 `main.lua`가 추적하는 실제 user anchor 인덱스에서 shell·body·popup slot으로 렌더된다. `battleui.html`은 `battleView` wire를 CBS로 표시한다. 컨트롤러는 검증된 wire 게시를 책임지고, button은 host 자동 remount, hook 게시는 현재 user UI anchor refresh를 사용한다.

## 10. 로컬 검증

`.agents/Tests/battle-controller-check.ps1`은 실제 순수 모듈을 함께 불러와 두 개의 독립 Lua 프로세스에서 다음을 검사한다.

- 명시적 ID·시드 bootstrap, 첫 턴 초기화와 선택 View 게시
- canonical `battleReady`의 setup 결합 bootstrap, 첫 전투 UI 게시와 동일 전투 재호출 보존
- 다른 battle ID·seed·환경·턴 제한·캐릭터·초기 카드 순서 충돌 차단과 exact 부분 저장 복구
- legacy 카드 focus·등록 호환, 명시 register/cancel과 draft 저장
- 명령당 atomic draft 전이 1회와 저장 View 재검증 1회만 수행되는 호출 계약
- 클릭 뒤 View 게시 실패, 구 interaction token 재호출의 전이 비적용·표시 복구와 token 회전
- 무시된 `activeRequest` 쓰기의 write-read 실패, UI anchor 보존과 저장 pending 재사용 복구
- trailing exact UI anchor/filler 제거, 과거 filler 보존과 request-only 지시의 raw-chat 비노출
- UI anchor 제거 실패 및 제거 뒤 최종 `inFlight` phase 쓰기 유실에서 `preparing` binding 기반 재개
- response가 없는 `inFlight`·`requestInjected` 요청의 무삭제 재시도, attempt 영속 쓰기 유실 시 채팅·pending·attempt 보존
- 캐릭터 출력처럼 filler 없는 suffix가 있는 잠긴 요청의 추가 onStart 무변경 거부
- 정상 프롬프트 보존, 입력 불변, system 사건/user 장면 지시의 멱등 주입과 중복 정규화
- 영수증 쓰기 유실 시 `inFlight` 보존, 주입 전 commit 거부와 authority/pending 불변, 성공 시 `requestInjected` 영수증 영속화
- char 출력 없는 commit 거부와 권위 상태 불변
- 출력 관측 영수증 쓰기 유실 시 authority·pending·완성 응답 불변
- prefix anchor 위변조 시 무삭제 거부, 미관측 부분 응답과 trailing filler의 자동 삭제, 같은 pending·RNG·request cue를 쓰는 attempt 재시도
- cleanup 영수증 저장 뒤 filler 삭제와 char 삭제 사이의 중단, 응답 fingerprint 위변조 거부와 다음 호출 재개
- 최초 commit, 다음 active 턴 한 번 초기화와 pending 이동
- output 관측 영수증 뒤 committed binding 쓰기 실패, 다음 빈 전송에서 완성 char를 보존한 commit migration 복구와 다음 턴 중복 초기화 방지
- 중복 commit에서 authority·다음 draft 불변
- 다음 턴 preparing/in-flight 동안 generation-locked View와 카드 클릭 거부
- authority의 확정 turnId와 저장 last pending 불일치 시 View fail-closed
- 새 턴 pending 생성, committed UI-only 복구와 모호한 Continue 유사 suffix 거부
- battleView wire 재읽기, button 수동 reload 없음과 비버튼 게시의 검증 후 refresh
- strict 오류 envelope와 별도 프로세스 결정성

로컬 검사는 실제 RisuAI의 hook 순서, mode별 권한, 채팅 재생성 UI 동작과 CBS/HTML 렌더링을 대신하지 않는다.
