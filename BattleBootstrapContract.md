# 전투 부트스트랩 계약

이 문서는 `System/battleBootstrap.lua`가 현재 수직 슬라이스의 최초 `battleState`를 순수하게 만드는 방식을 정의한다. 스키마 버전은 1이다.

## 1. 책임과 경계

`battleBootstrap`은 전투 시작 전의 권위 상태 하나만 만든다.

```text
명시적 battleId + 명시적 RNG seed + 전체 staticData
→ 고정 수직 슬라이스 사양 조립
→ stateSchema.newBattleState 전체 참조 검증
→ pre-initializer battleState
```

이 모듈은 채팅 변수, 로어북, UI, 메시지와 `main.lua`를 쓰지 않는다. 첫 턴 드로우, 캐릭터 의도 선택, `turn_start` 효과와 `turnStartReceipt` 생성은 `turnInitializer`의 책임이다. 생성한 상태를 저장할지 여부도 호출 계층의 책임이다.

## 2. `verticalSlice`

유일하게 지원하는 action은 다음과 같다.

```lua
runScript(
    triggerId,
    "battleBootstrap",
    "verticalSlice",
    {
        battleId = "battle-0001",
        seed = 12345,
    },
    staticData
)
```

생성 사양은 정확히 `battleId`, `seed`만 허용한다.

- `battleId`는 비어 있지 않은 runtime ID이며 `[A-Za-z0-9][A-Za-z0-9_-]*` 형식이다.
- `seed`는 0 이상이고 IEEE-754 안전 정수 범위 안에 있는 명시적 정수다.
- 두 값 모두 필수다. 현재 시간, 전역 변수나 임의 기본 시드로 대신하지 않는다.
- `staticData`는 `staticData.loadAll` 성공 결과의 전체 `data`처럼 registry, 카드, 특징, 환경과 캐릭터 컬렉션을 모두 가진 정적 데이터다.
- 다른 action은 이 수직 슬라이스 기본값을 암묵적으로 사용하지 않는다.

성공 보고서는 다음 형식이다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    referencesValidated = true,
    state = battleState,
}
```

실패 보고서는 다음 형식이며 `state`를 반환하지 않는다.

```lua
{
    ok = false,
    schemaVersion = 1,
    errors = {
        { code = "...", path = "...", message = "..." },
    },
}
```

## 3. 고정 수직 슬라이스 사양

`verticalSlice`는 현재 프로토타입에만 다음 값을 사용한다.

| 항목 | 값 |
|---|---|
| 상태 | `active` |
| 현재 턴 / 제한 턴 | `1 / 10` |
| 환경 | `uncrowded` |
| 플레이어 은폐 | `30` |
| 플레이어 기본 드로우 / 최대 손패 | `3 / 5` |
| 플레이어 퍽 | 빈 목록 |
| 캐릭터 | `yoo_jiyoung` |
| 캐릭터 전투 수치 | 정적 캐릭터 정의의 `startingResistance`, `startingMood`, `traitIds`, `baseDrawCount`, `maxHandSize` |
| 양측 계획 슬롯 | `{ occupied = false }` |
| 플레이어 선택 / 캐릭터 의도 | 빈 목록 |

플레이어 덱 순서는 고정한다.

1. `subtle_approach`
2. `accidental_brush`
3. `play_it_cool`
4. `read_the_room`
5. `pin_down`
6. `hypnotic_whisper`

유지영 덱 순서는 정적 정의와 다음 고정 사양이 일치해야 한다.

1. `close_collar`
2. `quiet_warning`
3. `turn_to_corner`
4. `silent_glare`

정적 캐릭터 덱이 이 목록 또는 순서와 달라지면 새 구성을 조용히 채택하지 않고 `vertical_slice_character_deck_mismatch`로 거부한다. 수직 슬라이스 구성을 바꾸려면 코드, 계약과 검사를 함께 변경한다.

## 4. 카드 인스턴스와 최초 영역

인스턴스 ID는 난수나 테이블 순회 순서에 의존하지 않는다.

```text
player-001 ... player-006
character-001 ... character-004
```

모든 인스턴스는 최초에 `deck`에 있으며 각 소유자 덱의 계약 순서대로 `position = 1..N`을 가진다. `hand`, `used`, `discard`, `removed`, `plan`에는 카드가 없다. `temporaryModifiers`는 스키마 v1 기본 상태에서 생략한다.

인스턴스 ID는 전투 상태 안에서만 참조되는 안정 ID다. 같은 사양을 다시 생성하면 같은 ID와 위치를 만들며 seed나 Lua 프로세스에 따라 달라지지 않는다.

## 5. RNG와 셔플하지 않는 이유

부트스트랩은 RNG를 소비하지 않는다.

```lua
rng = {
    seed = spec.seed,
    cursor = 0,
}
```

현재 카드 영역 계약에서 셔플은 `cardZones.shuffleDeck`의 명시적 action이며 덱이 빈 뒤 discard를 되돌리는 드로우 과정도 같은 모듈이 처리한다. 최초 부트스트랩에서 임의로 셔플하면 이후 캐릭터 선택과 재섞기가 공유하는 RNG 커서의 기준을 바꾸므로 수행하지 않는다. 첫 드로우는 위에 기록한 덱 순서에서 시작한다.

향후 최초 셔플을 도입하려면 다음을 함께 계약해야 한다.

- 플레이어와 캐릭터 중 어느 덱을 어떤 순서로 셔플하는지
- 각 덱 크기에 따라 정확히 소비되는 RNG 커서
- 셔플 뒤 위치 정규화
- 별도 프로세스 재현 벡터와 기존 턴 선택 결과의 변경 승인

## 6. 정적 참조 검증

모듈은 조립한 사양을 반드시 다음 경계에 전달한다.

```lua
runScript(triggerId, "stateSchema", "newBattleState", stateSpec, staticData)
```

성공하려면 `report.ok == true`, `report.referencesValidated == true`, `report.value`가 모두 필요하다. 따라서 고정 카드 소유자, 환경, 캐릭터, 무드와 특징 참조가 전체 정적 데이터에서 검증되지 않은 구조 전용 상태는 반환하지 않는다. `stateSchema`의 구조화 오류는 코드와 경로를 보존해 호출자에게 전달한다.

## 7. 순수성과 결정성

- 입력 `spec`과 `staticData`를 변경하지 않는다.
- 같은 입력은 같은 `battleState`를 반환한다.
- 반환 상태끼리 또는 반환 상태와 정적 데이터 사이에 변경 가능한 배열 alias를 공유하지 않는다.
- 시간, UUID, 전역 세션 값, 호스트 저장소와 저수준 LLM을 사용하지 않는다.
- 오류 경로에서도 호스트 상태를 쓰지 않는다.

## 8. 로컬 검증 범위

`Tests/battle-bootstrap-check.ps1`은 다음을 검사한다.

- 명시적 `battleId`와 seed 필수 조건 및 엄격한 사양 필드
- 현재 6장 플레이어 덱과 유지영 4장 덱의 안정 ID·소유자·영역·위치
- `active`, 1/10턴, `uncrowded`, 시작 수치와 빈 선택/계획 상태
- RNG seed 보존, `cursor = 0`, 셔플 모듈 미호출
- `stateSchema.newBattleState` 호출과 전체 정적 참조 검증
- 입력 불변성, 반환 alias 차단과 별도 Lua 프로세스 결정성
- 누락 카드, 불완전 정적 데이터, 캐릭터 덱 변경과 알 수 없는 action의 fail-closed 처리
- 호스트 쓰기 API 미호출

실제 RisuAI 로어북 등록, 생성 상태의 채팅 변수 저장, 첫 턴 initializer 호출, 훅 연결과 UI 표시는 이 검사 범위에 포함되지 않는다.
