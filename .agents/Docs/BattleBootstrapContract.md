# 전투 부트스트랩 계약

이 문서는 `System/battleBootstrap.lua`가 고정 수직 슬라이스 또는 완료된 게임 설정으로부터 최초 `battleState`를 순수하게 만드는 방식을 정의한다. 스키마 버전은 1이다.

## 1. 책임과 경계

`battleBootstrap`은 전투 시작 전의 권위 상태 하나만 만든다. `verticalSlice`는 기존 고정 프로토타입을 보존하고, `fromSetup`은 드래프트 결과와 선택한 정적 정의를 받아 양측 초기 덱까지 결정적으로 섞는다.

```text
명시적 battleId + 명시적 RNG seed + 전체 staticData
→ 고정 수직 슬라이스 사양 조립
→ stateSchema.newBattleState 전체 참조 검증
→ pre-initializer battleState
```

```text
완료된 10장 플레이어 덱 + 선택 캐릭터/환경 + 전투 전용 seed + 전체 staticData
→ stateSchema.newBattleState 전체 참조 검증
→ 플레이어 덱 셔플
→ 캐릭터 덱 셔플
→ stateSchema.validateBattleState 전체 참조 재검증
→ pre-initializer battleState
```

이 모듈은 채팅 변수, 로어북, UI, 메시지와 `main.lua`를 쓰지 않는다. 첫 턴 드로우, 캐릭터 의도 선택, `turn_start` 효과와 `turnStartReceipt` 생성은 `turnInitializer`의 책임이다. 생성한 상태를 저장할지 여부도 호출 계층의 책임이다.

## 2. `verticalSlice`

고정 수직 슬라이스 action은 다음과 같다.

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

## 5. `verticalSlice` RNG와 셔플하지 않는 이유

`verticalSlice`는 RNG를 소비하지 않는다.

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

## 6. `verticalSlice` 정적 참조 검증

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

`.agents/Tests/battle-bootstrap-check.ps1`은 다음을 검사한다.

- 명시적 `battleId`와 seed 필수 조건 및 엄격한 사양 필드
- 현재 6장 플레이어 덱과 유지영 4장 덱의 안정 ID·소유자·영역·위치
- `active`, 1/10턴, `uncrowded`, 시작 수치와 빈 선택/계획 상태
- RNG seed 보존, `cursor = 0`, 셔플 모듈 미호출
- `stateSchema.newBattleState` 호출과 전체 정적 참조 검증
- 입력 불변성, 반환 alias 차단과 별도 Lua 프로세스 결정성
- 누락 카드, 불완전 정적 데이터, 캐릭터 덱 변경과 알 수 없는 action의 fail-closed 처리
- 호스트 쓰기 API 미호출

실제 RisuAI 로어북 등록, 생성 상태의 채팅 변수 저장, 첫 턴 initializer 호출, 훅 연결과 UI 표시는 이 검사 범위에 포함되지 않는다.

## 9. `fromSetup`

완료된 초기 카드 드래프트를 전투 상태로 바꾸는 action은 다음과 같다.

```lua
runScript(
    triggerId,
    "battleBootstrap",
    "fromSetup",
    {
        battleId = "battle-0002",
        seed = 20260721,
        playerCardIds = {
            -- 드래프트 선택 순서의 카드 ID 정확히 10개
        },
        characterId = "yoo_jiyoung",
        environmentId = "uncrowded",
        turnLimit = 10,
    },
    staticData
)
```

사양은 위 여섯 필드만 허용하며 모두 필수다.

- `battleId`는 `verticalSlice`와 같은 runtime ID 형식이다.
- `seed`는 0 이상인 안전 정수이며 게임 설정 드래프트 RNG 상태를 이어받는 값이 아니라 **전투 전용 seed**다. 설정에서 난수를 얼마나 소비했는지가 전투 셔플과 이후 전투 난수열을 암묵적으로 바꾸지 않게 호출자가 별도로 제공한다.
- `playerCardIds`는 정확히 10개인 연속 배열이다. 모든 ID는 `lower_snake_case` ASCII ID이고 정적 DB에서 `owner = "player"`인 카드여야 하며 같은 카드 ID는 최대 2회까지만 허용한다.
- `characterId`는 정적 캐릭터 전투 정의를, `environmentId`는 정적 환경 정의를 참조해야 한다.
- `turnLimit`는 1 이상의 안전 정수이며 생성 상태에 그대로 기록한다.
- 알 수 없는 필드, 누락·잘못된 참조, 캐릭터 카드를 플레이어 덱에 넣은 입력은 부분 상태를 반환하지 않고 거부한다.

플레이어의 시작 은폐, 드로우 수, 최대 손패, 빈 퍽과 계획 슬롯은 현재 각각 `30`, `3`, `5`, 빈 목록과 `{ occupied = false }`다. 선택한 캐릭터의 시작 저항·무드·특징·드로우 수·최대 손패는 `staticData.characters[characterId].battle`에서 가져온다. 환경과 턴 제한은 사양의 값을 사용한다.

### 9.1 카드 인스턴스와 캐릭터 덱 일반화

플레이어 인스턴스는 드래프트 선택 순서대로 `player-001 ... player-010`을 부여한다. 캐릭터 인스턴스는 `staticData.characters[characterId].battle.deck`의 현재 길이와 순서대로 `character-001 ... character-N`을 부여한다. `fromSetup`은 유지영의 기존 4장 목록을 고정 사양으로 비교하지 않는다.

캐릭터 덱은 연속 배열이어야 하며 모든 카드 ID가 정적 DB에서 `owner = "character"`여야 한다. 따라서 캐릭터 DB의 합법적인 덱 길이·구성 변경은 `fromSetup` 코드 수정 없이 반영된다. 인스턴스 ID와 `cardId` 연결은 셔플 후에도 바뀌지 않고 `deck.position`만 바뀐다.

### 9.2 최초 셔플 순서와 RNG 커서

최초 상태를 전체 참조 검증으로 만든 다음 아래 순서를 반드시 지킨다.

1. `cardZones.shuffleDeck(state, "player")`
2. 그 결과를 입력으로 `cardZones.shuffleDeck(state, "character")`
3. 양쪽 셔플 결과를 `stateSchema.validateBattleState(state, staticData)`로 최종 검증

두 셔플은 하나의 `battleState.rng`를 이어서 사용한다. 각 셔플은 `deterministicRng.shuffle`의 Fisher-Yates 순서와 거부 표본 규칙에 따라 커서를 소비하므로, 같은 전투 seed와 같은 입력 덱은 같은 프로세스와 별도 프로세스에서 동일한 위치와 최종 커서를 만든다. 현재 고정 회귀 벡터의 10장 플레이어 덱과 4장 캐릭터 덱은 거부 표본 없이 각각 9회와 3회를 소비하여 최종 `cursor = 12`다.

성공 보고서는 기존 필드에 다음 표시를 더한다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    referencesValidated = true,
    initialDecksShuffled = true,
    state = battleState,
}
```

`initialDecksShuffled = true`는 양측 셔플과 셔플 후 전체 정적 참조 검증까지 모두 성공했다는 뜻이다. 중간 상태는 성공 결과로 노출하지 않는다.

## 10. `fromSetup` 로컬 검증 범위

`.agents/Tests/battle-bootstrap-from-setup-check.ps1`은 기존 `verticalSlice` 검사와 별도로 다음을 검사한다.

- 정확히 10장, 카드별 최대 2장과 플레이어 소유권
- 캐릭터 DB 덱의 길이·구성 일반화와 캐릭터 카드 소유권
- 명시적 환경·제한 턴·전투 전용 seed와 엄격한 사양 필드
- 플레이어 다음 캐릭터 셔플 순서, 고정 위치·커서 벡터와 같은/별도 Lua 프로세스 결정성
- `stateSchema.newBattleState` 및 셔플 후 `stateSchema.validateBattleState`의 전체 정적 참조 검증
- 입력·정적 데이터 불변성, 반환 결과 사이와 정적 데이터 사이의 배열 alias 차단
- 잘못된 카드·캐릭터·환경 참조, 세 번째 동일 카드와 알 수 없는 action의 fail-closed 처리
- 성공·실패 경로의 호스트 쓰기 API 미호출

이 검사는 기존 `.agents/Tests/battle-bootstrap-check.ps1`을 변경하지 않으며 `verticalSlice`의 무셔플·`cursor = 0` 계약도 그대로 보존한다.
