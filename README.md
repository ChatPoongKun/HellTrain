# HellTrain

**HellTrain**은 RisuAI의 Lua 로어북 런타임과 HTML 임베딩을 이용해 동작하는 한국어 카드 전투형 롤플레이 프로젝트입니다.

이 저장소는 독립 실행형 웹사이트나 일반 Lua CLI 프로그램이 아닙니다. `System/main.lua`가 RisuAI 호스트 API와 연결되고, 로어북에 등록된 Lua 모듈과 정적 DB를 불러와 상태를 계산한 뒤 `battleView` 등의 View를 HTML 템플릿에 전달합니다.

> 이 프로젝트에는 성인 대상의 다크 픽션 소재가 포함될 수 있습니다.

## 핵심 원칙

프로젝트를 수정하기 전에 다음 네 가지를 먼저 확인해야 합니다.

1. **RisuAI 호스트 의존 프로젝트입니다.** 저장소 파일만 브라우저나 일반 Lua 인터프리터에서 실행해 전체 동작을 재현할 수 없습니다.
2. **권위 상태와 표시용 View를 구분합니다.** `battleRuntimeV1.authority` 같은 상태가 원본이며, `battleView`와 HTML은 그 상태를 표시하기 위한 파생 결과입니다.
3. **실행 가능한 Lua 로어는 완전한 모듈입니다.** 여러 조각을 이어 붙이는 파일이 아니며 익명 함수 표현식 래퍼를 유지해야 합니다.
4. **런타임 코드나 정적 DB를 변경하면 캐시 revision도 갱신합니다.** 자세한 내용은 [캐시와 배포 revision](#캐시와-배포-revision)을 참고하십시오.

## 실행 환경

HellTrain은 다음 RisuAI 호스트 기능을 전제로 합니다.

- Lua low-level access
- Lorebook 조회
- state 및 chatVar 읽기·쓰기
- 전체 채팅 조회와 메시지 추가·삭제
- 특정 채팅 또는 전체 표시 갱신
- LLM 직접 호출
- JSON encode/decode

코드에서 사용하는 대표 호스트 함수는 다음과 같습니다.

```text
getLoreBooks
getState / setState
getChatVar / setChatVar
setStateChanged / setChatVarChanged (지원 시 자동 사용)
getFullChat / addChat / removeChat
reloadChat / reloadDisplay
LLM
json.encode / json.decode
```

저장소에는 현재 지원하는 RisuAI의 정확한 최소 버전이 명시되어 있지 않습니다. 배포 환경을 변경할 때는 위 API가 동일한 형태로 제공되는지 먼저 확인하십시오.

## RisuAI 등록 원칙

### 메인 스크립트

`System/main.lua`는 RisuAI 이벤트를 등록하고 첫 이벤트에서 호스트 호환층과 런타임을 bootstrap하는 얇은 진입점입니다. `System/hostCompat.lua`는 구·신 RisuAI 상태 및 chatVar API 차이를 흡수하고, `System/runtime.lua`는 로어 조회·컴파일·캐시를, `System/hostFlow.lua`는 editDisplay UI target·캐릭터 접근 장면·버튼 및 생성 훅 연결을 담당합니다.

### 실행 가능한 Lua 로어

`System` 아래의 실행 모듈은 파일명을 그대로 유지한 완전한 로어 항목으로 등록해야 합니다.

예를 들어 다음 호출은 `battleController.lua`라는 로어를 찾습니다.

```lua
runScript(triggerId, "battleController", "getSnapshot")
```

따라서 파일명이나 로어 이름을 바꾸면 모든 호출 지점도 함께 수정해야 합니다.

실행 모듈은 대체로 다음 형태를 사용합니다.

```lua
(function(triggerId, action, ...)
    -- module body
end)
```

또는 인수가 필요 없는 모듈은 다음 형태를 사용할 수 있습니다.

```lua
(function()
    -- module body
end)
```

이 래퍼를 일반 스크립트 형태나 `require()` 기반 모듈로 임의 변경하지 마십시오. `main.lua`는 로어 본문을 함수 표현식으로 로드하여 handler를 생성합니다.

같은 이름의 실행 가능한 로어가 여러 범위에 존재하면 `main.lua`는 마지막으로 발견된 비어 있지 않은 항목을 사용합니다. 중복 등록은 오래된 캐릭터 로어가 최신 모듈을 가리는 원인이 될 수 있으므로 가능한 한 제거하십시오.

### 정적 DB 로어

`System/staticData.lua`는 다음 로어 이름을 기본 정적 데이터 묶음으로 사용합니다.

| 로어 이름 | 용도 |
|---|---|
| `GameRegistry.db` | 정적 데이터 레지스트리와 버전 정보 |
| `PlayerCards.db` | 플레이어 카드 정의 |
| `CharacterCards.db` | 캐릭터 카드 정의 |
| `CharTraits.db` | 캐릭터 특성 정의 |
| `Environments.db` | 전투 환경 정의 |
| `TokyoSubwayLines.db` | 노선과 역 정보 |
| `CharacterList.db` | 캐릭터 프로필 목록 |

DB 이름은 런타임 계약의 일부입니다. 이름을 변경하려면 `staticData.lua`의 로딩 순서와 모든 참조를 함께 수정해야 합니다.

### HTML 임베딩

HTML 파일도 일반 웹 문서가 아니라 RisuAI 템플릿입니다.

- `html/battleui.html`: 턴 동안 고정되는 전투 및 승리 후 행동 UI 프레임
- `html/battleui-interaction.html`: 카드 선택 때 다시 평가하는 손패·선택 상태 UI 조각
- `html/embeddings.css`: 채팅 임베딩에 적용되는 공용 스타일

`{{getvar::...}}`, `{{dict_element::...}}`, `{{#if ...}}`, `{{#each ...}}`, `risu-btn` 같은 표현은 RisuAI가 해석합니다. 따라서 전투 UI 프레임과 상호작용 조각을 브라우저에서 직접 열어도 실제 데이터 바인딩과 버튼 동작은 재현되지 않습니다.

## 전체 아키텍처

```text
RisuAI 이벤트 / risu-btn / LLM 출력
                │
                ▼
        System/main.lua
       이벤트 등록 · bootstrap
                │
                ▼
 System/hostCompat.lua · System/runtime.lua · System/hostFlow.lua
 호스트 API 호환 · 로어 실행·캐시 · editDisplay UI target · 호스트 흐름
                │
                ▼
      상위 컨트롤러 계층
  gameSetupController / battleController
                │
                ▼
         도메인 모듈 계층
  stateSchema · turnInitializer · turnDraft
  turnResolver · effectEngine · characterSelector
  turnEventProjector · staticData · 기타 모듈
                │
                ▼
          권위 상태 저장
 gameSetupV1 / runProgressionV1 / battleRuntimeV1
                │
                ▼
       표시용 View 게시
 gameSetupView / runProgressionView
 battleView / battleLogView
                │
                ▼
      RisuAI HTML 템플릿 렌더링
```

## 주요 파일

| 경로 | 역할 |
|---|---|
| `System/main.lua` | RisuAI 이벤트 등록과 지연 bootstrap |
| `System/hostCompat.lua` | 구·신 RisuAI 상태·chatVar·채팅 읽기 API 호환 |
| `System/runtime.lua` | 로어 조회·컴파일, 이벤트/웜 캐시와 진단 |
| `System/hostFlow.lua` | editDisplay UI target, 접근 장면, 버튼과 생성 훅 연결 |
| `System/gameSetupController.lua` | 게임 준비, 캐릭터 선택, 진행 상태와 설정 View 관리 |
| `System/battleController.lua` | 전투 상태 전이와 요청·출력 복구를 조정하는 상위 컨트롤러 |
| `System/staticData.lua` | 정적 DB 로딩, 검증, 캐시 및 정규화 |
| `System/stateSchema.lua` | 권위 상태와 관련 구조의 스키마 검증 |
| `System/turnInitializer.lua` | 새 턴의 상태와 draft 준비 |
| `System/turnDraft.lua` | 카드 선택, 등록, 취소, 효과 선택과 interaction token 관리 |
| `System/turnResolver.lua` | 선택된 카드와 효과를 턴 결과로 해석 |
| `System/effectEngine.lua` | 카드 효과, modifier 및 상태 변화 계산 |
| `System/characterSelector.lua` | 캐릭터 AI의 행동 후보 평가와 선택 |
| `System/turnEventProjector.lua` | 턴 사건을 표시 및 후속 처리에 필요한 형태로 투영 |
| `html/battleui.html` | 전투와 승리 후 행동 화면의 고정 프레임 |
| `html/battleui-interaction.html` | 카드 선택용 손패·상태 조각 |
| `html/embeddings.css` | 임베딩 공용 스타일 |
| `imgs/` | 캐릭터 등 표시용 이미지 자산 |

위 표는 핵심 경로를 설명하기 위한 것이며 모든 모듈을 열거하지는 않습니다. 기능을 수정할 때는 호출하는 컨트롤러와 그 컨트롤러가 사용하는 도메인 모듈을 함께 추적하십시오.

## 게임 흐름

### 1. 게임 준비

`gameSetupController`가 초기 설정 상태와 진행 상태를 만들고, `gameSetupView` 또는 `runProgressionView`를 게시합니다.

대표 권위 상태 키는 다음과 같습니다.

```text
gameSetupV1.authority
runProgressionV1.authority
```

### 2. 캐릭터 선택과 접근 장면

플레이어가 캐릭터를 선택하면 `main.lua`가 선택한 캐릭터 자료와 과거 조우 기록을 바탕으로 접근 장면용 LLM 요청을 만듭니다. 생성된 장면을 채팅에 기록한 뒤 전투 초기화로 전환합니다.

이 단계는 RisuAI의 `LLM`, `getFullChat`, `addChat` 기능을 사용하므로 low-level access가 비활성화되어 있으면 정상 동작하지 않습니다.

### 3. 전투 시작

`battleController`가 정적 데이터와 setup 또는 run 상태를 받아 첫 전투 상태와 draft를 만듭니다. 같은 전투를 다시 시작하는 요청이 들어오면 기존 상태를 검증하고 재사용하거나 안전한 복구를 수행합니다.

### 4. 카드 상호작용

카드 UI는 draft에 대해 다음 작업을 수행합니다.

```text
click
register
cancel
choose
```

각 상호작용에는 현재 draft와 연결된 `interactionToken`이 필요합니다. 오래된 UI에서 발생한 stale 입력은 상태를 변경하지 않고 현재 View를 다시 게시해야 합니다.

### 5. 생성 요청과 출력 확정

카드 선택이 확정되면 전투 사건을 계산한 뒤 LLM 출력 생명주기로 들어갑니다.

```text
draft
  → submission
  → pending
  → activeRequest.preparing
  → activeRequest.inFlight
  → activeRequest.requestInjected
  → outputObserved
  → committed
  → 다음 턴 또는 aftermath/정산
```

주요 단계는 다음과 같습니다.

- `prepareGeneration`: 현재 draft를 확정 가능한 pending turn으로 준비합니다.
- `submission`: 최신 카드 interaction token에 연결된 생성 의도입니다. 채팅 filler 대신 사용하며 생성 시작 시 소비합니다.
- `injectRequest`: 모델 입력에 확정 사건과 장면 생성 지시를 주입합니다.
- `commitOutput`: 실제 캐릭터 출력이 채팅에 도착한 것을 확인한 뒤 권위 상태를 확정합니다.
- `outputObserved`: 같은 출력을 중복 확정하지 않도록 채팅 위치와 fingerprint를 기록합니다.
- `recoveringCleanup`: 요청 또는 출력 처리 도중 실패했을 때 재시도와 복구 경계를 기록합니다.
- `lastCommittedPending`: 이미 반영한 턴이 다시 적용되는 것을 막습니다.

이 영수증과 phase 검증은 중복 실행, 호스트 훅 재호출, 채팅 쓰기 실패를 견디기 위한 장치입니다. 단순해 보이도록 삭제하거나 하나의 함수로 합치지 마십시오.

### 6. 승리 후 행동과 정산

일부 승리 흐름은 즉시 정산되지 않고 `aftermath` 상태에서 자유행동 출력을 추가로 처리합니다. 완료 후 전투 로그와 진행 상태를 갱신하고 다음 선택 화면 또는 종료 화면으로 이동합니다.

## 권위 상태와 View

### 설정 및 진행 상태

```text
gameSetupV1.authority
runProgressionV1.authority
```

표시용 View:

```text
gameSetupView
runProgressionView
```

### 전투 상태

`battleController`가 관리하는 대표 키는 다음과 같습니다.

```text
battleRuntimeV1.authority
battleRuntimeV1.draft
battleRuntimeV1.pending
battleRuntimeV1.lastCommittedPending
battleRuntimeV1.activeRequest
battleRuntimeV1.aftermath
```

표시용 View:

```text
battleView
battleInteractionView
battleLogView
```

### 수정 규칙

- `authority`는 규칙 계산의 기준이 되는 원본 상태입니다.
- `draft`는 아직 확정되지 않은 플레이어 상호작용 상태입니다.
- `pending`은 LLM 요청과 연결될 확정 대기 턴입니다.
- `activeRequest`는 요청 주입, 출력 관측, 복구 및 확정 영수증을 보관합니다.
- View와 HTML은 원본 상태가 아닙니다.
- HTML에서 전투 규칙을 다시 계산하지 마십시오.
- View를 읽어 권위 상태를 복원하지 마십시오.
- 영속 상태는 가능하면 해당 컨트롤러의 공개 action을 통해서만 변경하십시오.

## 전투 컨트롤러 공개 action

`battleController`는 현재 다음 action을 외부 진입점으로 제공합니다.

| action | 용도 |
|---|---|
| `startVerticalSlice` | 독립 전투 슬라이스 시작 |
| `startFromSetup` | 준비 상태에서 전투 시작 |
| `startFromRun` | 진행 상태에서 전투 시작 |
| `clickCard` | 카드 클릭 처리 |
| `registerCard` | 카드 사용 순서 등록 |
| `cancelCard` | 등록 취소 |
| `selectCardEffect` | 선택형 카드 효과 결정 |
| `armSubmission` | 무선택 패스 또는 리롤 뒤 보존된 선택을 전송 준비 상태로 설정 |
| `prepareGeneration` | 현재 턴을 생성 요청 직전 상태로 준비 |
| `injectRequest` | 모델 프롬프트에 전투 사건과 출력 지시 주입 |
| `commitOutput` | 도착한 출력을 검증하고 턴 확정 |
| `publishCurrentView` | 현재 권위 상태에서 View 재생성 |
| `getSnapshot` | 전투 런타임 진단 snapshot 조회 |
| `getTerminalSummary` | 종료 전투 요약 조회 |

새 action을 추가할 때는 입력 검증, 실패 보고, 저장 순서, 재호출 시 동작, View 게시 여부를 함께 정의해야 합니다.

## 데이터 구조 규칙

컨트롤러에 저장되는 값은 JSON으로 안전하게 표현할 수 있어야 합니다.

- 숫자는 유한값이어야 합니다.
- 배열은 1부터 연속된 정수 인덱스를 사용해야 합니다.
- 숫자 인덱스와 문자열 키를 같은 테이블에 섞지 마십시오.
- 순환 참조를 만들지 마십시오.
- 메타테이블을 붙이지 마십시오.
- 함수, userdata, thread를 권위 상태에 저장하지 마십시오.
- runtime ID와 enum은 기존 패턴을 따르십시오.
- `schemaVersion`과 `kind`는 저장 구조의 계약입니다.

### 신뢰 경계와 canonical 객체

이 프로젝트의 공식 정책은 **경계 검증 후 transaction 내부 신뢰**입니다.

- 버튼·hook·LLM/chat 입력, DB/lore, state/chatVar에서 읽은 값은 외부 경계이므로 전체 스키마와 의미를 검증합니다.
- 공식 validator 또는 domain transition이 현재 transaction에서 반환한 값은 canonical입니다. 같은 transaction의 내부 consumer는 전체 replay를 반복하지 않고 envelope, `kind`, identity와 필수 필드 같은 저렴한 postcondition만 확인합니다.
- canonical 값은 입력 불변으로 취급합니다. 변경이 필요한 모듈은 새 객체를 반환하거나 소유권 경계에서 한 번 복제합니다.
- 저장, 인코딩, host 호출, 다음 hook/event 또는 임의 mutation을 거친 값은 canonical 자격을 잃습니다. 다시 읽을 때 전체 경계 검증을 수행합니다.
- 새 권위 상태, receipt와 공개 View처럼 새로운 경계를 만드는 출력은 경계를 넘기 전에 한 번 검증합니다. 공개 View allowlist와 JSON-safe 검사는 비공개 정보 누출 및 직렬화 방지를 위해 생략하지 않습니다.
- 내부 canonical action은 문자열 route로 호출할 수 없도록 함수 capability를 요구합니다. capability는 호출 경로만 제한하며 저장 가능한 인증 seal로 사용하지 않습니다.

동일 transaction에서 canonical snapshot을 저장하고 readback이 exact-equal인 경우에는 전체 의미 검증을 다시 실행하지 않습니다. exact 비교는 host 쓰기·동시 변경 확인이고, 다음 이벤트의 저장값 검증은 별도의 경계 검사입니다.

상태 필드를 추가하거나 의미를 변경할 때는 생성 코드뿐 아니라 다음 항목을 함께 검토해야 합니다.

1. 스키마의 허용 필드와 타입 검증
2. 기존 저장 상태와의 호환 또는 마이그레이션
3. clone 및 fingerprint 대상
4. View 생성과 View 검증
5. 요청·출력 영수증에 포함되는지 여부
6. 중복 호출과 복구 경로

## UI 규칙

### View에서 계산하고 HTML에서는 표시합니다

`battleui.html`은 `battleView`, `battleui-interaction.html`은 손패·선택 상태만 투영한 `battleInteractionView`의 값을 그대로 표시해야 합니다. 복잡한 조건이나 규칙 계산은 Lua의 View 생성 단계에서 처리하십시오.

### interaction token을 유지합니다

카드 버튼은 현재 `interactionToken`을 전달해야 합니다. token 검증을 제거하면 오래된 렌더의 클릭이 최신 draft를 덮어쓸 수 있습니다.

### editDisplay UI target을 임의 변경하지 않습니다

게임 UI는 채팅에 전용 메시지를 저장하지 않습니다. `editDisplay`가 초기에는 first message(`-1`), 이후에는 최신 캐릭터 응답에 UI를 렌더 시점에만 덧붙입니다.

```text
helltrainUiTargetIndexV1
```

`main.lua`는 완성 응답의 채팅 인덱스를 target으로 저장하고, 이전 target과 새 target만 `reloadChat`합니다. target 인덱스 저장이나 갱신 호출을 변경할 때는 정상 흐름뿐 아니라 훅 재호출과 실패 복구도 확인해야 합니다.

### Risu 템플릿 문법을 보존합니다

중첩된 `{{...}}` 표현식은 일반 Mustache와 완전히 같다고 가정하지 마십시오. 이미지, raw 값, 조건문, 반복문을 변경할 때는 실제 RisuAI 렌더 결과를 확인하십시오.

## 기능별 변경 가이드

### 새 카드 또는 카드 효과 추가

1. 대응하는 정적 DB 항목을 추가합니다.
2. ID와 참조 무결성을 확인합니다.
3. `effectEngine`이 새 효과를 적용하거나 투영할 수 있도록 수정합니다.
4. `turnResolver`와 필요 시 `characterSelector`의 평가 로직을 갱신합니다.
5. `stateSchema`가 추가 필드와 결과를 검증하도록 수정합니다.
6. 사용자에게 보여야 하는 값만 View에 추가합니다.
7. 실행 가능한 Lua 또는 정적 DB가 바뀌었으므로 bundle revision을 갱신합니다.

### 새 상태 필드 추가

1. 권위 상태 생성부에 필드를 추가합니다.
2. 스키마의 허용 필드와 타입 검증을 추가합니다.
3. 기존 상태를 읽을 때의 기본값 또는 마이그레이션을 정합니다.
4. clone, 비교, fingerprint 및 영수증에 영향을 주는지 확인합니다.
5. 필요한 경우에만 View에 파생값을 추가합니다.
6. 재시도 시 같은 결과가 나오는지 확인합니다.

### 전투 UI 변경

1. 필요한 데이터가 이미 `battleView` 또는 `battleInteractionView`에 있는지 확인합니다.
2. 없다면 Lua View 생성부에서 표시용 값을 만듭니다.
3. View 스키마 또는 검증을 갱신합니다.
4. 턴 고정 내용은 `html/battleui.html`, 카드 선택 반응은 `html/battleui-interaction.html`에 표시 로직만 추가합니다.
5. RisuAI에서 카드 클릭, popover, 이미지, aftermath 입력창을 확인합니다.

### 새 컨트롤러 action 추가

1. 입력을 검증합니다.
2. 도메인 모듈 결과의 envelope, identity와 필수 postcondition을 확인합니다. 같은 transaction의 canonical 결과를 전체 replay하지 않습니다.
3. 저장 순서와 실패 시 복구 가능성을 정의합니다.
4. 같은 action이 재호출될 때 멱등적으로 동작할지 명시합니다.
5. 성공 결과는 `{ ok = true, schemaVersion, errors = {} }` 형태를 유지합니다.
6. 실패 결과에는 가능한 한 `code`, `path`, `message`를 제공합니다.
7. action dispatch에 등록합니다.

## 캐시와 배포 revision

`main.lua`는 로어 모듈의 source와 compiled handler를 캐시합니다. `staticData.lua`도 정적 DB snapshot을 캐시합니다.

프로덕션 warm path는 다음 값이 변경되었는지를 기준으로 오래된 캐시를 무효화합니다.

```lua
RUNTIME_BUNDLE_REVISION
```

따라서 다음 항목을 변경하면 `System/main.lua`의 `RUNTIME_BUNDLE_REVISION`도 반드시 새 값으로 바꾸십시오.

- 실행 가능한 `System/*.lua` 로어
- 카드, 캐릭터, 환경, 노선 등 런타임 정적 DB
- 모듈 로딩 결과에 영향을 주는 배포 구성

revision 값의 형식 자체보다 **이전 배포와 다른 값이어야 한다는 점**이 중요합니다.

개발 중 로어 소스를 매 이벤트 다시 확인해야 할 때는 런타임에서 제공하는 개발 모드를 사용할 수 있습니다.

```lua
setRunScriptCacheDevelopmentMode(true)
```

개발 확인이 끝나면 프로덕션 동작과 성능을 확인하기 위해 다시 비활성화하십시오.

## 디버깅

`System/main.lua`의 `DEBUG` 값은 진단 출력 깊이를 조절합니다.

```lua
DEBUG = 2
```

숫자가 클수록 더 세부적인 메시지가 출력됩니다. 정적 DB와 컨트롤러 진단은 원문 데이터 전체 대신 scope, action, 오류 코드와 경로 중심으로 출력하도록 설계되어 있습니다.

컨트롤러 실패는 대체로 다음 형태입니다.

```lua
{
    ok = false,
    schemaVersion = 1,
    errors = {
        {
            code = "error_code",
            path = "$.state.someField",
            message = "오류 설명"
        }
    }
}
```

오류를 조사할 때는 메시지만 보지 말고 `code`와 `path`를 먼저 확인하십시오.

전투 상태를 확인하려면 `battleController`의 snapshot action을 사용합니다.

```lua
runScript(triggerId, "battleController", "getSnapshot")
```

### 자주 확인할 문제

| 증상 | 먼저 확인할 항목 |
|---|---|
| `lorebook ... not found` | 파일명과 로어 이름, 등록 범위, 빈 로어 여부 |
| 코드 수정이 반영되지 않음 | `RUNTIME_BUNDLE_REVISION`, 개발 캐시 모드, 중복 로어 |
| UI가 갱신되지 않음 | View 게시 성공 여부, chatVar, UI target 인덱스, `reloadChat` |
| 오래된 카드 클릭이 상태를 바꿈 | `interactionToken` 전달과 stale 처리 |
| 출력이 중복 반영됨 | `activeRequest.phase`, `outputObserved`, `lastCommittedPending` |
| 복구 중 요청이 반복됨 | `recoveringCleanup`, 요청 prefix 영수증과 response fingerprint |
| 정적 데이터 로딩 실패 | DB 로어 이름, JSON 형식, 레지스트리 참조 |

## 변경 후 확인

변경 성격에 따라 RisuAI에서 다음 흐름을 직접 확인하십시오.

- 최초 게임 화면이 표시되는가
- 게임 시작 후 초기 상태와 선택 화면이 생성되는가
- 캐릭터 선택 후 접근 장면이 한 번만 생성되는가
- 카드 클릭, 등록, 취소, 선택형 효과가 최신 token에서만 적용되는가
- 생성 요청에 전투 사건이 한 번만 주입되는가
- 출력이 한 번만 확정되고 다음 턴 View가 나타나는가
- 새로고침 또는 훅 재호출 후에도 상태가 중복 적용되지 않는가
- 승리, 패배, aftermath, 정산 흐름이 올바르게 이어지는가
- 이미지와 popover가 실제 RisuAI 템플릿에서 표시되는가
- 런타임 또는 정적 DB 변경 시 새 bundle revision이 적용되었는가

## 작업 시 주의사항

- View나 HTML을 권위 상태처럼 사용하지 마십시오.
- 컨트롤러를 우회해 `battleRuntimeV1.*` 값을 직접 쓰지 마십시오.
- 기존 영수증과 fingerprint 검증을 근거 없이 삭제하지 마십시오.
- 실행 모듈을 여러 로어 조각으로 나누지 마십시오.
- 임시 self-modifying GitHub Actions workflow를 일반적인 코드 수정 경로로 남기지 마십시오.
- 성능 최적화로 View 필드를 늘릴 때 직렬화 비용과 로어 토큰 부담도 함께 확인하십시오.
- 오류를 숨기기 위해 검증을 약화하기보다 입력 또는 전이의 원인을 수정하십시오.

## 라이선스

현재 저장소에 별도의 라이선스 파일이 없다면 저작권과 재사용 조건이 명시되지 않은 상태입니다. 외부 배포 또는 재사용 전에 저장소 소유자에게 사용 조건을 확인하십시오.
