# RisuAI 게임 시작→전투 수동 검사

이 문서는 로컬 계약 검사를 통과한 현재 빌드를 최신 웹 RisuAI에 반영하고, 첫 메시지에서 캐릭터 선택과 실제 전투 턴까지 확인하는 최소 절차다. 기존 진행 채팅을 덮어쓰지 말고 새 테스트 채팅에서 실행한다.

## 1. 배포 전 갱신

1. RisuAI의 단일 Lua 트리거를 저장소의 `System/main.lua` 내용으로 갱신한다.
2. 다음 수정 Lua를 파일명과 정확히 같은 이름의 개별 로어북으로 갱신한다.

   - `battleController.lua`
   - `gameSetup.lua`
   - `gameSetupController.lua`
   - `gameSetupView.lua`

3. 신규 `html/characterSelect.html`을 정확히 `characterSelect.html`이라는 새 개별 로어북으로 등록한다. 경로 전체나 다른 표시명을 사용하지 않는다.
4. 기존 `cardDraft.html`, `battleui.html`, `sideBar.html`, `init.lua`, `battleBootstrap.lua`, `turnInitializer.lua`, `staticData.lua`, `dataBridge.lua`와 그 전투 의존 모듈이 파일명 그대로 등록되어 있는지 확인한다.
5. 캐릭터 선택 풀을 위해 다음 정적 DB 로어를 확인한다.

   - `CharacterList.db`
   - `YooJiyoung.db`
   - `YoonSeoa.db`
   - `HanJenny.db`
   - `SeoMiryeong.db`
   - `SisterAgnes.db`
   - `GameRegistry.db`, `PlayerCards.db`, `CharacterCards.db`, `CharTraits.db`, `Environments.db`

6. first message가 현재 `Prompt/firstmsg.html` 내용과 상시 UI sentinel `@@HELLTRAIN_UI_ANCHOR_V1@@`을 포함하는지 확인한다.

Lua 모듈·HTML·DB는 모두 로어북이지만 `main.lua`만 트리거 스크립트다. 신규 HTML을 등록하지 않으면 열 번째 카드 뒤 `missing_lore`로 중단된다.

## 2. 시작과 카드 드래프트

1. 새 채팅을 열어 첫 메시지 하단에 게임 시작 UI가 나타나는지 확인한다.
2. `게임 시작`을 한 번 누른다.
3. 카드 제안이 정확히 3장인지 확인한다.
4. 카드를 한 번 눌러 상세를 열고, 상세의 확정 버튼으로 선택한다.
5. 같은 방식으로 정확히 10장을 선택한다. 같은 카드는 최대 2장까지만 선택되어야 한다.
6. 열 번째 선택 직후 별도 완료 버튼 없이 캐릭터 선택 화면으로 바뀌는지 확인한다.

오래된 카드 버튼을 빠르게 두 번 누르거나 이전 화면의 버튼이 늦게 전달되어도 카드가 두 번 추가되거나 setup이 초기화되면 안 된다.

## 3. 캐릭터 선택과 전투 진입

1. 서로 다른 캐릭터가 정확히 3명 표시되는지 확인한다.
2. 후보 카드의 첫 클릭으로 다음 공개 상세가 열리는지 확인한다.

   - 이름, 나이, 직업, 외형 요약
   - 시작 저항과 무드
   - 기본 드로우와 최대 손패
   - 공개 특징

3. 비공개 프로필, 캐릭터 카드 ID, setup/battle seed가 화면에 나타나지 않는지 확인한다.
4. 열린 후보 아래의 선택 확정 버튼을 누른다.
5. 캐릭터 선택 화면이 전투 UI로 바뀌고 선택한 캐릭터가 표시되는지 확인한다.
6. 전투가 1턴이며 플레이어 기본 손패가 3장인지 확인한다. 별도 턴 종료 버튼은 없어야 한다.

캐릭터 확정 버튼을 빠르게 더블클릭해도 같은 battle ID의 전투를 다시 초기화하거나 첫 손패를 다시 뽑으면 안 된다. 화면 새로고침 또는 접근 가능한 기존 시작 버튼의 재호출 뒤에도 현재 전투 진행·선택이 보존되어야 한다.

## 4. 실제 턴 진행

1. 손패 카드 하나의 상세를 연다. 이 첫 동작만으로 권위 선택이 바뀌면 안 된다.
2. 상세의 등록 버튼을 눌러 사용 카드로 등록되는지 확인한다.
3. 같은 카드의 취소 버튼을 눌러 등록이 해제되는지 확인한다.
4. 카드를 다시 등록하거나 아무 카드도 등록하지 않은 상태에서 RisuAI의 전송 버튼을 누른다.
5. 공개 채팅에 `[전투 턴 1]` 마커가 하나만 생기고, 모델이 그 턴의 장면을 응답하는지 확인한다.
6. 출력이 끝난 뒤 결과가 한 번만 반영되고 2턴의 선택 가능한 전투 UI가 나타나는지 확인한다.
7. 같은 방식으로 최소 3턴을 진행해 손패·저항·은폐·무드와 카드 영역이 정상적으로 갱신되는지 확인한다.

전투 중 입력 문자열은 공개 사용자 대사로 쓰이지 않는다. 전송은 턴의 유일한 확정점이며, 생성 중 Continue나 병렬 전송은 사용하지 않는다.

## 5. 실패 시 확인할 키

설정·표시 문제는 다음 채팅 변수를 순서대로 확인한다.

| 키 | 기대값 또는 역할 |
|---|---|
| `gameSetupReady` | 게시 중 `updating`, 성공 뒤 `ready` |
| `gameSetupView` | 드래프트 또는 캐릭터 후보의 공개 wire |
| `helltrainUiShellV1` | sidebar를 포함한 고정 shell |
| `helltrainUiShellRevision` | 현재 shell revision |
| `🔯🔯🔯` | 현재 `cardDraft.html`, `characterSelect.html` 또는 `battleui.html` body |
| `battleView` | 첫 턴 이후 전투 공개 wire |

권위·복구 문제는 다음 state 키를 확인한다.

| 키 | 기대값 또는 역할 |
|---|---|
| `gameSetupV1.authority` | `deckDraft` → `characterSelect` → `battleReady`; 전투 중에도 인계 영수증으로 보존 |
| `battleRuntimeV1.authority` | 선택 캐릭터·초기 덱에 결합된 현재 전투 상태 |
| `battleRuntimeV1.draft` | 선택 가능한 현재 턴 draft; 출력 대기 중에는 없음 |
| `battleRuntimeV1.pending` | 전송 뒤 출력 확정 전 pending turn |
| `battleRuntimeV1.lastCommittedPending` | 직전 확정 턴의 재생성·공개 결과 원본 |
| `battleRuntimeV1.activeRequest` | `preparing`/`inFlight`/`requestInjected`/`committed` 요청 binding |

증상별 우선 확인 순서는 다음과 같다.

- 열 번째 카드 뒤 멈춤: `gameSetupV1.authority.phase`, `gameSetupView`, `characterSelect.html` 로어 이름, `🔯🔯🔯`
- 캐릭터 확정 뒤 전투 UI 없음: setup phase가 `battleReady`인지, 전투 authority·draft가 생겼는지, `battleView`, `battleui.html`과 `🔯🔯🔯`
- 전송 뒤 턴이 진행되지 않음: `pending`, `activeRequest.phase`, 공개 턴 마커 바로 뒤의 캐릭터 응답, `lastCommittedPending`
- 재호출로 초기화됨: setup/battle의 `battleId`, 전투 `turnNumber`, draft interaction token이 호출 전후 보존되는지

오류 조사 시 seed, RNG나 비공개 사건을 일반 사용자 메시지에 붙이지 않는다. 필요한 값은 로컬 진단용으로만 확인한다.
