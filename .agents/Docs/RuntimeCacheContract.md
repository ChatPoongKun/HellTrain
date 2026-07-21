# Runtime Cache Contract

## 목적

`System/main.lua`의 `runScript`와 `System/staticData.lua`는 RisuAI의 반복적인
`getLoreBooks`·CBS 처리·JSON bridge·Lua compile 비용을 줄인다. 캐시는 권위 상태나
진행 상태를 저장하지 않으며, 저장 상태의 검증·write-read 계약을 대체하지 않는다.

## 배포 revision

- `RUNTIME_BUNDLE_REVISION`은 production warm cache의 source epoch이다.
- `RUNTIME_BUNDLE_REVISION`은 실행 리소스 전체의 정규화된 content hash이다.
  `.agents/Tests/runtime-bundle-contract-check.ps1`이 `System/*.lua`, `DB/*.db`,
  `Char/*.db` 변경 시 revision 갱신을 강제한다.
- production은 같은 revision의 warm handler와 성공한 static snapshot을 재사용하며
  매 이벤트에 lore source를 다시 읽지 않는다. revision을 올리지 않은 로어 편집이
  즉시 보일 것이라고 가정하면 안 된다.
- revision 변경은 다음 이벤트에서 새로운 warm key를 사용하게 한다. 캐시 entry는
  상한 내에서 LRU로 제거된다.
- 같은 검사는 실행 Lua/DB의 동적 `{{...}}` literal을 금지하고, 정적 sidebar shell의
  별도 content hash revision도 검증한다.

## 이벤트 및 context 경계

- 모든 host hook은 진입 시 `beginRunScriptEvent(triggerId, mode)`를 호출한다.
- 한 이벤트 안에서 같은 script 이름의 nested `runScript`는 transaction handler를
  재사용하므로 lore 조회가 unique module 수를 넘지 않는다.
- 이벤트 간 warm key는 `bundle revision + mode + chat namespace + character identity
  + script`로 구성한다.
- `triggerId`는 이벤트별 access key이므로 영속 context key로 사용하지 않는다.
  chat namespace는 `runtimeModuleCacheV1.namespace` chatVar에 저장하고 exact readback을
  확인한다. 권한 때문에 저장할 수 없으면 해당 이벤트의 volatile namespace로
  fail-safe 동작하며 이벤트 간 warm hit를 포기한다.
- exact source cache는 handler closure가 아니라 compiled chunk만 공유하고, 서로
  다른 namespace는 chunk로부터 별도의 handler를 만든다.
- RisuAI의 채팅 복제·branch는 chatVar도 복제하며 Lua API는 고유 chat ID를
  노출하지 않는다. 따라서 복제 직후의 두 채팅은 같은 namespace를 잠시
  공유할 수 있다. persistent handler outer local에 authority·턴 진행·세션
  순번을 두면 안 된다. 예외는 입력 content가 key에 완전히 반영되고
  출력을 deep clone하는 상한 있는 파생 캐시뿐이다. 현재 예외는
  `staticData`, `viewBuilder`다.

## 개발 및 수동 무효화

- `setRunScriptCacheDevelopmentMode(true)`는 이벤트 간 warm path를 우회한다.
  각 이벤트의 첫 모듈 호출은 lore source를 다시 읽고, 같은 이벤트의 nested 호출만
  transaction cache를 사용한다.
- RisuAI engine과 전역은 mode별이므로 개발 모드 전환과 수동 clear도 현재 mode
  engine에 적용된다. 전체 host 검증에서는 사용하는 각 mode를 cold/warm으로 확인한다.
- 개발 모드 진입·종료 시 warm handler를 비운다. compiled exact-source chunk는
  재사용할 수 있다.
- `clearRunScriptCache()`는 전체 compiled/warm cache를 비우고,
  `clearRunScriptCache(script)`는 해당 script만 비운다.
- `staticData`의 `clearCache`는 성공 snapshot을 비운다. `reloadAll`은 production에서도
  DB source를 강제로 다시 읽고 검증하는 진단/개발용 action이다.

## 배포 트리거 계약

- RisuAI는 같은 mode에서 실행할 `triggerlua` code 문자열이 바뀌면 Lua
  engine을 새로 만든다. button dispatcher는 character와 module의 모든
  `triggerlua`를 순회하므로, 서로 다른 Lua trigger 코드를 동시 등록하면
  매 클릭마다 engine이 재생성되어 warm cache가 사라질 수 있다.
- 배포에서는 `System/main.lua` 하나만 trigger code로 등록하고 나머지
  `System/*.lua`, DB와 HTML은 로어북으로 등록한다. 패키징 설정은 이
  저장소에 없으므로 실제 host console에서 mode별 engine 생성 log가 cold
  첫 1회에만 나오는지 확인해야 한다.

## 정적 데이터

- 성공적으로 전체 검증된 snapshot만 캐시한다. compile 또는 validation 실패는
  캐시하지 않는다.
- production의 같은 staticData handler는 성공 snapshot을 반환할 때 DB lore를 다시
  읽지 않는다. development bypass 또는 새 bundle revision에서는 새 handler가 DB를
  다시 읽고 검증한다.
- 호출자에게는 항상 table deep clone을 반환한다. 함수 callback identity만 유지하며,
  호출자가 카드·레지스트리 table을 변경해도 canonical snapshot은 변하지 않는다.
- 진행 상태와 save에는 static 함수나 cache table을 직렬화하지 않는다.

## 상한과 진단

- compiled source chunk: 최대 64 entry
- production warm handler: 최대 128 entry
- 현재 transaction handler: 최대 64 entry
- `getRunScriptCacheDiagnostics()`는 transaction/warm/source hit, source fetch, compile,
  eviction, 오류 수를 반환하지만 source 원문이나 실행 함수는 노출하지 않는다.
- `staticData.cacheStats`는 snapshot hit, source capture, validation, 실패 수를 반환한다.

## 필수 검사

`.agents/Tests/runtime-cache-check.ps1`은 다음을 고정한다.

- 한 이벤트의 50회 동일 호출이 lore를 한 번만 읽는지
- 다음 production 이벤트가 lore를 읽지 않는지
- bundle revision 및 development bypass가 source 변경을 반영하는지
- 명시적으로 다른 namespace·캐릭터 context 사이에 mutable handler
  closure가 공유되지 않는지
- `staticData`, `viewBuilder` 외의 런타임 모듈이 persistent outer state를
  만들지 않는지
- compile/load/validation 실패가 캐시되지 않는지
- 두 번째 production `staticData.loadAll`의 DB lore fetch 증가가 0인지
- 반환된 static table 변조가 canonical snapshot을 오염시키지 않는지
- source 64개와 warm handler 128개의 LRU 상한을 넘지 않는지

로컬 Lua 검사는 실제 RisuAI의 mode별 engine 수명, chatVar 권한과 hook 순서를
대체하지 않는다. 배포 전 실제 host에서 cold/warm 이벤트를 모두 확인해야 한다.
