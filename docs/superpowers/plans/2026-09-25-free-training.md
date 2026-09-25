# 자유조교 Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox syntax. 이 문서는 계획이며 구현 착수 지시가 아니다. 저장소 지침에 따라 회귀 검사와 빌드는 사용자가 명시적으로 실행을 지시하기 전에는 실행하지 않는다.

**Goal:** 같은 캐릭터를 3회 이상 함락한 뒤 전투 사이 캐릭터 선택 화면에서 해당 캐릭터와 자유 입력 세션을 시작하고, 종료 후 회차별 요약을 캐릭터 상세정보에서 조회한다.

**Architecture:** `runProgressionV1`의 전투 진행은 유지하고 독립된 `freeTrainingV1` 상태로 대화 모드를 덮어쓴다. `hostFlow`가 모드에 따라 기본 Risu 송수신을 통과시키며, 종료 경계에서만 세션 기록을 확정하고 기존 선택 UI를 다시 게시한다.

**Tech Stack:** RisuAI Lua 5.4, JSON 상태, HTML/CSS/CBS, 기존 Python/Lupa 호스트 테스트 하네스.

**Spec:** 이 문서의 「기능 설계」가 구현 기준이다. 사용자는 대상 선택 방식을 **조건을 충족한 캐릭터 중 1명 선택**으로 확정했다. 나머지 기본 결정은 아래에 명시한다.

## Global Constraints

- 버튼 이름은 `자유조교`, 세션 종료 버튼 이름은 `자유조교 종료`로 고정한다.
- 활성 조건은 현재 run의 `phase == "characterSelect"`이고, 확정된 서로 다른 승리 전투가 같은 캐릭터에 3개 이상 있는 것이다.
- 승리 후 `aftermath`, 보상 `reward`, 전투, 초기 덱 구성에서는 진입할 수 없다.
- 자유 입력 중 전투 검증, 턴 계산, 카드 처리, RNG 소비, 전투 요청 주입, 전투 출력 commit, 정산을 호출하지 않는다.
- 자유 입력은 Risu 기본 전송과 출력으로 처리한다. 매 입력을 별도 `LLM()` 호출로 대체하지 않는다.
- 검증은 진입·종료·기록 게시 경계에 한정한다. 일반 입력/출력에서는 모드 확인과 UI target 이동에 필요한 최소 읽기만 허용한다.
- 권위 상태에서 View를 생성한다. HTML/CBS에서 자격이나 횟수를 계산하지 않는다.
- 상태는 함수가 없는 JSON 값으로 저장하고, 내부 키와 ID는 ASCII를 사용한다.
- 실행 로어는 기존 함수 표현식 래퍼를 유지하며 새 모듈은 `(function(triggerId, action, ...) ... end)` 형태로 작성한다.
- 실제 `html/*.html`의 모든 줄은 첫 열에서 시작한다. 사용자 입력과 요약은 `dataBridge`의 안전한 wire 인코딩을 통과한다.
- `System/main.lua`의 변경은 `RUNTIME_BUNDLE_REVISION` 갱신만 한다.
- 회귀 검사와 배포 빌드는 사용자가 직접 수행하며, 명시적 실행 지시가 없으면 에이전트가 실행하지 않는다.
- 계획 작성 시 이미 수정된 `README.md`, `build/HellTrain.charx`를 덮어쓰거나 되돌리지 않는다.

## Review Focus

1. 일반 전송뿐 아니라 Continue·리롤·중단 후 재전송도 전투 훅을 호출하지 않아야 한다 — Task 3.
2. 과거 UI의 버튼, 연속 클릭, 새로고침은 다른 모드 진입이나 기록 중복을 만들면 안 된다 — Tasks 2, 4.
3. 요약 실패·저장 직후 실패·복귀 UI 실패가 있어도 종료와 기록 재시도가 가능해야 한다 — Task 4.
4. 리롤·메시지 삭제와 긴 세션 때문에 이전 전투나 다른 캐릭터 대화가 요약에 섞이면 안 된다 — Task 4.
5. 세션 중 사이드바 열기와 종료 후 다음 전투 시작이 기존 게임 상태·후보·검증 경계를 훼손하면 안 된다 — Tasks 3, 5, 6.

## 확인한 현재 구조

| 위치 | 현재 역할과 변경 이유 |
|---|---|
| `System/hostFlow.lua:665` | `editDisplay`가 최신 UI target에 shell/body/popup을 합성한다. 자유조교 UI도 이 경로를 사용한다. |
| `System/hostFlow.lua:709` | 버튼 allowlist와 인수 개수 검사. 새 라우트 및 모드별 차단이 필요하다. |
| `System/hostFlow.lua:851`, `:893`, `:953` | 요청 주입, 전송 준비, 출력 commit이 현재 전투로 연결된다. 자유조교 분기를 이보다 먼저 둔다. |
| `System/main.lua:179` | 출력 결과가 `{ok=true}`여야 전투 오류 경고가 발생하지 않는다. 기존 target 복구도 활용한다. |
| `System/gameSetupController.lua:1371` | 저장된 run을 `start`로 다시 게시할 수 있다. 자유조교 종료 시 선택 화면 복원에 활용한다. |
| `System/runProgressionView.lua:1503` | 캐릭터 기록은 sessions와 현재 전투를 battleId로 중복 제거한다. 자유조교 자격은 정산된 sessions만 사용한다. |
| `html/postBattle.html:282` | 전투 사이 다음 캐릭터 선택 UI다. 진입 버튼은 이 분기에 추가한다. |
| `html/characterSelect.html` | 최초 게임 준비용 캐릭터 선택 UI다. 이번 기능의 진입 위치가 아니다. |
| `System/캐릭터 프로필.lua` | 캐릭터 기록 View를 게시한 다음 상세 HTML을 읽는다. 자유조교 기록도 동일 순서로 연결한다. |
| `System/dataBridge.lua` | View allowlist와 CBS wire 인코딩을 담당한다. 새 View 등록과 상세 기록 검증이 필요하다. |

줄 번호는 계획 작성 시점 기준이다. 구현할 때 함수명과 분기로 위치를 다시 찾는다.

## 기능 설계

### 1. 사용자 흐름과 자격

```text
전투 → 승리 후 자유행동 → 보상 확정 → 다음 조우 대상 선택
                                      │
                                      └─ 자유조교 → 대상 1명 선택 → 자유 입력
                                            ↑                       │
                                            └─ 다음 조우 대상 선택 ← 종료·기록
```

- 다음 캐릭터 선택 화면에는 버튼을 표시한다. 적격자가 없으면 disabled 상태로 `같은 캐릭터를 3회 이상 함락하면 해금됩니다`를 표시한다.
- 보상 화면과 전투 화면에는 버튼을 표시하지 않는다. 과거 버튼을 직접 호출해도 상태 검사에서 거부한다.
- 대상 선택 목록은 **이번 전투 후보 3명과 무관하게**, 현재 run의 확정 승리 기록에서 조건을 충족한 모든 캐릭터를 포함한다.
- 횟수는 연승이 아닌 누적 승리이며, 동일 `battleId`를 두 번 세지 않는다. 별도 승리 카운터를 저장하지 않는다.
- 대상 선택에서 취소하면 원래 다음 조우 대상 선택 화면으로 복귀한다. 이 단계만 열었다 닫은 것은 자유조교 이력이 아니다.
- 자유조교를 마쳐도 후보 3명, 선택 토큰, 덱, 퍽, RNG, 진행 회차와 함락 횟수는 변하지 않는다.

### 2. 권장 구현 방식과 대안

**권장: 독립 세션 상태 + hostFlow 우회.** 전투 진행의 재생 검증을 바꾸지 않고 별도 대화 모드를 추가한다. 전투 코드와 자유 입력을 분리할 수 있고 종료 후 복귀도 명확하다.

대안으로 `runProgression.phase`에 모드를 추가하면 `replaySessions`, 허용 phase, canonical 검증까지 확장해야 한다. 기존 aftermath를 재사용하면 제한 행동 수와 전투 상태 검증이 계속 연결된다. 두 방식 모두 이번 요구의 “종료 전까지 기본 Risu 대화”와 맞추기 위해 변경 범위가 커진다.

### 3. 상태와 모듈 경계

새 권위 키 `freeTrainingV1.authority`를 한 개 사용한다. 활성 세션과 완료 기록을 함께 저장해 종료 중 부분 저장 문제를 줄인다.

```lua
{
    kind = "freeTrainingV1", schemaVersion = 1,
    setupId = "current-setup-id", nextSessionNumber = 2,
    active = {
        sessionId = "current-setup-id:free:1",
        phase = "active", -- selecting / active / closing / returning
        characterId = "CharacterId", -- selecting에서는 생략
        returnToken = "original-character-offer-token",
        interactionToken = "session-and-phase-specific-token",
        startChatIndex = 12, -- Risu의 0-based index
        boundary = { role = "user", data = "세션 시작 안내 원문" },
        context = "진입 시 한 번 준비한 대상 및 모드 설명",
        journalSnapshot = {}, -- 진입 전에 만든 공개 캐릭터 기록 View
    },
    records = {
        -- 종료된 세션만 추가하며 sessionId로 중복을 제거한다.
        -- {sessionId, characterId, startChatIndex, endChatIndex,
        --  summary, summaryStatus = "complete" | "failed" | "empty"}
    },
}
```

- 상태가 없으면 미사용 상태로 취급한다. 다른 `setupId`의 기록을 현재 run에 섞지 않는다.
- `selecting`은 대상 선택 UI이며 일반 전송을 안내와 함께 막는다. `active`에서만 기본 대화를 허용한다.
- `closing`은 종료 시점의 대화 스냅샷과 요약 처리 중인 상태다. `returning`은 기록 확정 후 선택 UI 복원 중이다.
- 영속 이력 전체를 매 입력마다 읽지 않도록 활성 모드용 작은 routing chatVar를 별도로 게시한다. 이는 권위 원본이 아닌 dispatch용 투영이며 진입·종료 저장 경계와 재게시 때 일치시킨다.
- 상세정보의 자유조교 횟수는 `records`를 캐릭터별로 필터한 길이에서 파생한다. 진행 중 회차는 완료 횟수에 더하지 않는다.
- 새 `freeTraining.lua`: 순수 자격 집계와 상태 전이. 새 `freeTrainingController.lua`: 호스트 저장, UI 게시, 세션 종료 조정. 새 `freeTrainingView.lua`: 공개 View 구성·검증. 새 `freeTrainingSummary.lua`: 대화 구간 추출과 요약 요청.
- 기존 `runProgression`과 `battleRuntime` 상태에 자유조교 결과를 삽입하지 않는다. 자유조교로 능력치나 전투 규칙이 바뀌는 기능은 이번 범위에 포함하지 않는다.

### 4. 자유 입력 중 훅 동작

| 훅/동작 | active 모드 처리 |
|---|---|
| `onStart` | 경량 모드 확인 후 true 반환. 선택 화면 전송 금지 안내와 prepareGeneration을 건너뛴다. |
| `editRequest` | 기존 Risu prompt를 유지하고 저장된 자유조교 context만 덧붙인다. 전투 사건 주입, 데이터 검증, 대화 해석은 하지 않는다. |
| `onOutput` | `{ok=true}` 반환. commitOutput을 호출하지 않는다. 기존 main.lua의 target 동기화로 종료 버튼이 최신 응답에 붙는다. |
| `editDisplay` | 게시된 자유조교 body와 기존 shell/popup만 합성한다. 계산·저장·요약은 하지 않는다. |
| 과거 전투·선택 버튼 | 모드 가드에서 거부한다. 자유조교 종료와 허용된 조회/닫기만 통과한다. |
| 리롤·Continue | 기본 Risu 동작을 허용한다. 별도의 전투 submit marker와 영수증을 만들지 않는다. |

context는 대상 캐릭터의 기존 프롬프트용 프로필, 현재 대화 모드, 과거 관계의 짧은 배경만 진입 시 한 번 준비한다. 사용자 인풋을 다시 쓰거나 출력에 상태 JSON을 요구하지 않는다. 이를 요청에만 추가하므로 사용자가 설정한 Risu 기본 프롬프트·로어·모델 선택은 그대로 사용한다.

진입 시 사람이 읽을 수 있는 짧은 세션 시작 안내를 한 번 채팅에 추가해 대상과 기록 경계를 명확히 한다. 별도 시작 장면 LLM 호출은 하지 않는다. UI만을 위한 빈 채팅도 만들지 않는다. 시작 안내 저장에는 기존 append/readback 패턴을 사용하며 재시도 시 중복 추가하지 않는다.

사이드바 캐릭터 상세 조회는 `journalSnapshot`을 사용해 active 중 `buildCharacterJournal`의 전투 검증을 우회한다. 다른 조회 버튼도 전투 계산·검증을 유발하는 경로인지 확인하고, 이미 게시된 View를 표시하거나 active 동안 비활성화한다. 일반 대화마다 사이드바 전체를 재생성하지 않는다.

### 5. 종료와 요약 기본 결정

1. `자유조교 종료` 클릭 시 현재 세션 토큰을 확인하고 phase를 `closing`으로 저장한다. 이 시점부터 새 입력은 막되, 자유조교 출력이 전투 commit으로 흐르지는 않게 한다.
2. 생성 중 종료는 Risu의 실제 중단 동작과 훅 순서에 맞춰 처리한다. 문서화된 `stopChat`만 사용하고, 존재하지 않는 busy API를 가정하지 않는다. 중단이 확정되지 않은 동안은 `closing`을 유지한다. 늦은 출력도 자유조교로 처리하고, 종료 스냅샷 확정 전 다음 전투 버튼을 열지 않는다. 이 순서는 실제 호스트 수동 검증의 필수 항목이다.
3. 시작 안내의 위치·원문과 현재 채팅을 대조해 이 세션 구간만 추출한다. 리롤로 교체된 응답은 현재 남아 있는 버전을 사용한다. 내부 UI, 전투 submit marker, 요약 응답은 제외한다. 시작 경계가 삭제되어 찾을 수 없으면 전체 채팅을 대신 요약하지 않는다.
4. 종료 시에만 기존 main-model `LLM`을 한 번 호출해 실제 사건과 관계 변화의 **한국어 2~4문장**을 받는다. 별도 보조 모델 설정을 요구하지 않는 기본안이다. 모델이 반환한 요약을 일반 캐릭터 채팅에 추가하지 않는다.
5. 요약 프롬프트는 대상 정보와 세션 대화만 받는다. 대화 본문은 요약 대상 자료로 구획하고, 그 안의 지시를 실행하거나 없는 사건을 추가하지 않도록 지시한다. 전투용 addRequestContext나 scene 복구 루틴을 재사용하지 않는다.
6. 긴 입력은 `getTokens`로 종료 시 확인하고 최대 12,000 입력 토큰 예산으로 발췌한다. 초과 시 초반 2,000, 중간 균등 발췌 4,000, 후반 6,000 이내로 구성하고 기록에 `일부 대화 발췌 요약` 표시를 남긴다. 이 예산은 코드 상수로 관리한다.
7. 정상 요약은 길이를 최대 800자로 제한하고 CBS/HTML을 안전하게 인코딩한다. 실패·빈 응답·경계 유실은 `summaryStatus="failed"`와 구체적인 실패 안내로 기록한다. `empty` 세션은 `대화 없이 종료`로 저장한다. 대상 확정 후 명시적으로 종료한 세션은 이 경우에도 1회로 센다.
8. `sessionId`가 없는 경우에만 record를 추가하고, `returning` 상태와 함께 readback 검증한다. 같은 종료 요청이 반복되어도 1회만 기록한다.
9. `gameSetupController.start`로 원래 `characterSelect` 화면을 재게시한다. 저장된 returnToken과 현재 후보 토큰이 일치해야 하며 후보를 다시 추첨하지 않는다. 복귀 성공 후 active와 routing 투영을 해제한다.

요약 실패는 종료를 막지 않는다. 상세정보에 `요약 재시도`를 제공하되 자유 입력 active 중에는 실행하지 않는다. 재시도는 종료 시 동결한 대화 자료를 사용하고 같은 record의 요약만 갱신한다. 정상 완료 후에는 실패 복구용 자료를 제거한다. 요약 호출이 진행 중이면 `요약 없이 종료`로 실패 기록을 확정할 수 있게 하며, 늦은 요약 결과가 이미 종료된 상태나 새 세션을 덮어쓰지 않도록 sessionId와 phase를 다시 확인한다.

저장 실패는 성공으로 표시하지 않고 종료 재시도 화면을 유지한다. 기록 저장 성공 후 UI 게시만 실패하면 이미 저장한 record를 재사용해 복귀만 재시도한다. 새로고침은 세션을 자동 종료하지 않으며 저장된 active/closing/returning 단계의 UI를 복구한다.

## 구현 작업

### Task 1: 자격 집계와 독립 상태 전이

**Files:** Create `System/freeTraining.lua`, `build/tests/RuntimeRegression/check_free_training.py`.

**Interfaces:** `runScript(id,"freeTraining",action,...)` 반환은 `{ok=true,...}` 또는 기존 errors 형태다.

```lua
-- 순수 action: 저장/LLM/UI 호출 없음
-- eligibility(runState) -> {ok, eligibleIds, victoriesById}
-- open(stateOrNil, runState) -> {ok, state, applied}
-- begin(state, characterId, interactionToken, entryContext) -> {ok, state, applied}
-- close(state, sessionId, frozenTranscript) -> {ok, state, applied}
-- finish(state, sessionId, summaryResult) -> {ok, state, applied}
-- returned(state, sessionId) -> {ok, state, applied}
-- validate(state) -> {ok, state}
```

`entryContext`는 startChatIndex, boundary, context, journalSnapshot이다. `frozenTranscript`는 확정한 endChatIndex와 role/content 배열이다. `summaryResult`는 status, text, truncated, 실패 시 reason을 포함한다. 상태 검증은 전이 경계에서만 호출한다.

- [ ] 기존 fixture 로더 방식으로 신규 회귀 소스를 작성하고 아래 자격 사례를 포함한다. 이 단계에서 실행하지 않는다.

```lua
local function eligibility(phase, sessions)
    return runScript('test', 'freeTraining', 'eligibility', {
        phase=phase, sessions=sessions,
    })
end
local records={
    {battleId='b1', characterId='A', status='victory'},
    {battleId='b2', characterId='A', status='victory'},
}
assert(#eligibility('characterSelect', records).eligibleIds==0)
records[3]={battleId='b3', characterId='A', status='victory'}
assert(eligibility('characterSelect', records).eligibleIds[1]=='A')
assert(#eligibility('reward', records).eligibleIds==0)
records[3].battleId='b2'
assert(#eligibility('characterSelect', records).eligibleIds==0)
```

- [ ] 서로 다른 캐릭터의 승리 합계 3은 해금하지 않는 사례, 패배 제외, 4회 이상, 3명 후보 밖 적격자 포함을 추가한다.
- [ ] 위 action을 구현하고 sessionId를 setupId와 독립 자유조교 번호에서 생성한다. 전투 RNG를 소비하지 않는다.
- [ ] begin/finish 반복 호출, 선택 취소, 토큰 불일치, 다른 setupId 혼합 거부의 상태 전이 검사를 작성한다.

**사용자 실행:** `python build/tests/RuntimeRegression/check_free_training.py` — 기대: 자격 및 순수 전이 사례 통과.

### Task 2: 진입 버튼과 대상 선택 UI

**Files:** Create `System/freeTrainingController.lua`, `System/freeTrainingView.lua`, `html/freeTraining.html`; modify `System/hostFlow.lua`, `System/gameSetupController.lua`, `System/runProgressionView.lua`, `System/dataBridge.lua`, `html/postBattle.html`, `html/embeddings.css`.

**Interfaces:** Controller actions `open(token)`, `begin(characterId,token)`, `cancel(token)`, `restore()`, `finish(sessionId,token)`, `skipSummary(sessionId,token)`, `retrySummary(sessionId)`; View actions `build(state,eligibleProfiles)`, `validate(view)`. UI routes are `freeTrainingController|<action>|...` and exact arity is allowlisted.

```lua
-- runProgressionView에 추가할 공개 필드
freeTraining = {
    enabled = true, eligibleCount = 1,
    interactionToken = runState.characterOffer.interactionToken,
}
-- 신규 freeTrainingView: kind, schemaVersion, phase,
-- interactionToken, sessionId?, characterName?, candidates[], message?
-- candidates item: characterId, name, portraitImage, victories
```

- [ ] 실제 run fixture에서 reward/characterSelect View와 활성 조건 테스트를 작성한다. 자격 없는 캐릭터로 직접 begin하는 요청도 검사한다.
- [ ] `buildCanonicalView`와 `validateRunProgressionView`에 새 공개 필드를 함께 추가한다. 새 View를 dataBridge에 등록한다.
- [ ] `postBattle.html`의 characterSelect 분기에 버튼과 비활성 안내를 추가한다. reward에서는 렌더하지 않는다.
- [ ] Controller에서 run을 진입 시 검증하고 적격자만 `staticData.loadCharacters`로 읽는다. 대상 선택 UI 게시 전 freeTrainingView를 먼저 저장한다.
- [ ] begin에서 프로필 context와 공개 journal snapshot을 준비하고 시작 안내를 한 번 저장한 뒤 active UI를 게시한다. 로딩·저장 실패 시 중간 단계부터 재시도 가능하게 한다.
- [ ] active body에는 대상 이름과 `자유조교 종료`를 표시한다. 기존 shell은 유지하고 카드 interaction fragment와 열려 있던 전투 popup은 정리한다.
- [ ] 과거 버튼의 토큰 불일치, 중복 open/begin, 선택 취소가 원래 후보와 RNG를 유지하는 테스트를 추가한다.

**사용자 실행:** `python build/tests/RuntimeRegression/check_free_training.py` — 기대: 진입 UI·저장·stale 버튼 검사 통과.

### Task 3: 기본 송수신 우회와 새로고침 복구

**Files:** Modify `System/hostFlow.lua`, `System/freeTrainingController.lua`, `System/캐릭터 프로필.lua`; create `build/tests/RuntimeRegression/check_free_training_host_flow.py`.

**Interfaces:** 작은 routing 투영을 읽는 hostFlow 로컬 helper를 사용한다. Controller `restore()`는 진행 중 세션 UI만 재게시하며 새 세션이나 LLM 요청을 만들지 않는다.

```lua
-- 기존 handleStart / handleEditRequest / handleOutput 앞의 분기 형태
-- routing.phase == 'active'인 경우:
-- start: return true
-- editRequest: 기존 data를 보존한 배열에 routing.context 한 건 추가
-- output: return {ok=true}
-- selecting/closing/returning: start는 false, output은 {ok=true}
-- routing이 없을 때만 기존 전투 경로로 진행한다.
```

- [ ] `check_send_guidance.py`의 hostFlow 로딩 방식을 사용해 아래와 같은 호출 금지 spy 테스트를 작성한다.

```lua
function runScript(_, module, action)
    assert(module~='battleController', 'free input entered battle controller')
    assert(module~='turnResolver' and module~='stateSchema', 'free input validated battle')
    error('unexpected module call: '..module..'.'..action)
end
-- fixture의 routing var를 active/context로 준비한 뒤:
assert(host('test','start')==true)
local request={{role='user', content='plain input'}}
local result=host('test','editRequest',request)
assert(result[1].content=='plain input')
assert(host('test','output').ok==true)
```

- [ ] 모드 분기는 `selectionSendGuidance`, `prepareGeneration`, `injectRequest`, `addRequestContext`, `commitOutput`보다 먼저 실행되게 한다.
- [ ] main.lua의 onOutput 성공 계약을 유지하고 UI target이 새 출력으로 옮겨지는 통합 사례를 작성한다. body를 채팅 원문에 저장하지 않는다.
- [ ] active에서 전투/보상/일반 캐릭터 확정/접근 재시도 라우트를 막는다. journal 조회는 저장된 공개 snapshot으로 처리한다.
- [ ] 반복 입력, 리롤, Continue, 중단 후 재전송, 늦은 출력, 새로고침에서 전투 호출이 0이며 run/battle/RNG가 동일한 사례를 작성한다.
- [ ] `init|start` 복구 요청은 자유조교 Controller.restore로 먼저 보내고, 종료의 명시적 returning 경로만 일반 gameSetupController.start를 사용한다. 읽기 전용 editDisplay에서 상태 복구를 쓰기로 수행하지 않는다.

**사용자 실행:** `python build/tests/RuntimeRegression/check_free_training_host_flow.py` — 기대: 우회와 복구 검사 통과.

### Task 4: 종료·요약·정확히 한 번 기록

**Files:** Create `System/freeTrainingSummary.lua`, `build/tests/RuntimeRegression/check_free_training_summary.py`; modify `System/freeTraining.lua`, `System/freeTrainingController.lua`, `System/hostFlow.lua`, `html/freeTraining.html`.

**Interfaces:** Summary actions `extract(chat,active) -> {ok,messages,endChatIndex}` and `generate(characterName,messages) -> {ok,status,text,truncated,reason?}`. Controller finish/skipSummary/retrySummary가 이를 사용한다.

```lua
-- 테스트용 LLM mock: 일반 입력이 아닌 종료에서만 한 번 호출되어야 한다.
local summaryCalls=0
function LLM(_, prompt)
    summaryCalls=summaryCalls+1
    return {success=true, result='세션에서 확인된 사건을 요약한 기록.'}
end
-- 실제 Controller finish를 두 번 호출한 뒤 assert:
-- summaryCalls == 1
-- 동일 sessionId의 records 개수 == 1
-- 기존 runState.characterOffer와 rng는 시작 전과 동일
```

- [ ] 구간 추출 테스트: 이전 전투 텍스트 제외, 리롤 교체 결과 포함, 삭제된 경계 실패, 빈 세션, 여러 캐릭터 세션 순차 진행을 작성한다.
- [ ] 종료 요청을 먼저 영속화하고 채팅 스냅샷을 확정한다. 로컬 Lua 참조만 보관하지 말고 재실행 가능한 JSON 자료를 남긴다.
- [ ] 요약을 단일 LLM 호출로 구현하고 길이·발췌·실패 정책을 적용한다. 요약 전용 요청이 일반 자유조교 context/전투 주입 경로를 다시 거치지 않는지 hostFlow 통합 fixture로 검사한다.
- [ ] active→closing→returning→inactive 전이를 구현한다. 기록 및 진행 단계 저장 직후 readback 실패를 주입해 재시도 시 중복이 없는지 검사한다.
- [ ] LLM 실패/빈 응답/초과 길이/긴 한국어/HTML 및 CBS 문자/요약 없이 종료/늦은 요약 완료를 검사한다.
- [ ] 요약 재시도는 해당 record만 갱신하고 횟수·다른 기록·전투 상태를 변경하지 않는지 검사한다.
- [ ] UI 게시 실패 후 복귀만 재시도하는 사례와 생성 중 종료의 늦은 출력 차단을 작성한다. 실제 Risu의 중단 완료 순서는 Task 6 수동 검사로 확정한다.

**사용자 실행:** `python build/tests/RuntimeRegression/check_free_training_summary.py` — 기대: 구간, 실패 복구, 중복 방지 검사 통과.

### Task 5: 사이드바 상세 기록

**Files:** Modify `System/캐릭터 프로필.lua`, `System/runProgressionView.lua`, `System/freeTrainingView.lua`, `html/캐릭터 프로필.html`, `html/embeddings.css`, `build/tests/RuntimeRegression/check_character_journal.py`.

**Interfaces:** `buildCharacterJournal` 입력에 `freeTrainingState`를 추가하고 item의 `freeTrainingCount`, `freeTrainingHistory`를 공개한다. `freeTrainingHistory` 항목은 `sessionId`, `number`, `summary`, `summaryStatus`, `truncated`만 사용한다.

```lua
-- buildCharacterJournal 결과에서 확인할 불변식
assert(view.selected.freeTrainingCount==#view.selected.freeTrainingHistory)
-- 자유조교 전후 기존 encounters/victories/defeats는 같아야 한다.
-- 내부 context, journalSnapshot, frozenTranscript는 View로 복사하지 않는다.
```

- [ ] 기존 journal fixture에 캐릭터 A의 완료 기록 2개와 B의 기록 1개를 넣고 캐릭터별 분리, 순번, 완료 횟수를 검사한다.
- [ ] 상세 View 검증 allowlist와 안전한 CBS 인코딩을 확장한다. 기존 전투 조우 집계 공식에 자유조교를 더하지 않는다.
- [ ] 상세정보에 `자유조교 2회`와 회차별 요약을 표시한다. 여러 회차는 최신순으로 나열하고 각각 details/summary로 접을 수 있게 한다.
- [ ] 미진행 캐릭터, empty/failed 요약, 실패 후 재시도 갱신, active 중 snapshot 조회를 검사한다.
- [ ] popup root→detail→back→close 동작과 종료 후 다시 연 상세정보의 최신 기록 갱신을 검사한다.

**사용자 실행:** `python build/tests/RuntimeRegression/check_character_journal.py` — 기대: 기존 조우 집계와 새 기록 검사 통과.

### Task 6: 통합·문서·수동 검증 준비

**Files:** Modify `build/tests/RuntimeRegression/check_runtime_regressions.py`, `build/tests/README.md`, `System/main.lua`의 revision. 기존 README 변경과 충돌 없이 별도 기능 설명을 추가할 수 있다. `build/risucard.py`는 새 로어가 glob으로 수집되는지 확인하고 고정 순서가 필요할 때만 ORDER를 보완한다.

- [ ] 신규 테스트 3개를 전체 회귀 실행기에 Lua 5.4와 LuaJIT 모드로 등록한다. 핵심 hostFlow 테스트는 fast 집합에도 포함한다.
- [ ] 신규 모듈의 함수 래퍼, CBS 문자열 금지, HTML 들여쓰기 계약을 반영한다. 신규 Lua 소스에 CBS 원문 리터럴을 넣지 않는다.
- [ ] `runtime-bundle-contract-check.ps1`의 정규화·정렬·SHA256 규칙에 맞춰 bundle revision을 갱신한다. main.lua의 훅 구현은 수정하지 않는다.
- [ ] 사용자가 실행할 회귀 명령과 아래 수동 체크리스트를 `build/tests/README.md`에 추가한다.

```powershell
python build/tests/RuntimeRegression/check_free_training.py
python build/tests/RuntimeRegression/check_free_training_host_flow.py
python build/tests/RuntimeRegression/check_free_training_summary.py
python build/tests/RuntimeRegression/check_character_journal.py
python build/tests/RuntimeRegression/check_runtime_regressions.py
```

명령은 실행 안내다. 테스트 통과나 CHARX 생성은 실제 사용자 실행 결과를 받은 뒤에만 보고한다.

**Risu 수동 수용 기준:**

1. 같은 캐릭터 승리 2회에서는 비활성, 3회에서는 활성. 3번째 승리 직후 aftermath와 reward에서는 진입 불가.
2. 적격자가 현재 전투 후보 3명에 없어도 자유조교 대상으로 선택 가능. 취소하면 동일 후보가 보임.
3. active에서 평문 입력, Continue, 리롤, 중단 후 재전송이 정상 동작하고 카드 확정 요구·전투 오류가 없음.
4. 매 응답의 최신 uianchor 위치에 종료 버튼이 한 개 표시되고 이전 응답에는 남지 않음.
5. active 중 사이드바 상세정보를 열어도 전투 검증·턴 계산이 실행되지 않음.
6. 생성 중 종료·연속 종료 클릭·종료 중 새로고침에서도 늦은 출력이 전투 턴으로 처리되지 않음. 중단 완료 전에는 다음 전투를 시작할 수 없음.
7. 종료 시 한 회차와 2~4문장 요약이 기록되고 원래 후보·토큰·RNG·덱·퍽이 유지됨.
8. 모델 오류나 요약 생략 시에도 선택 화면에 복귀하고, 재시도 성공 시 횟수를 늘리지 않고 요약만 갱신함.
9. 다음 전투를 시작하면 기존 prepare/inject/commit 흐름이 정상 작동하고 자유조교 프롬프트가 더 이상 주입되지 않음.

## 계획 완료 시점의 상태

- 코드와 현재 계약을 읽고 이 계획만 작성했다.
- 구현 코드, 상태, 배포 파일을 변경하지 않았다.
- 회귀 검사와 빌드는 실행하지 않았다.
- 실제 Risu에서의 생성 중 중단 및 늦은 출력 순서는 모의 테스트만으로 보증할 수 없으므로 수동 수용 기준에 포함했다.
