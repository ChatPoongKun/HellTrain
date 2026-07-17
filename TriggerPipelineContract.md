# Trigger Pipeline Contract v1

`System/triggerPipeline.lua`는 `turnInitializer`와 `turnResolver`가 같은 트리거 규칙을 사용하도록 만든 공용 batch 실행기다. 이 모듈은 입력 사건 하나에 반응하는 트리거만 해결한다. 턴 생성, 기본 드로우, 캐릭터 의도 선택, 승패 판정, 턴 정리와 최종 사건 ID 부여는 호출자의 책임이다.

## 1. 호출과 반환

로어북 action은 `run` 하나다.

```lua
local report = runScript(
    triggerId,
    "triggerPipeline",
    "run",
    staticData,
    {
        state = state,
        transient = transient, -- 생략하면 {}
    },
    {
        type = "turn_start",
        -- side = "player" | "character" -- 진영 없는 사건이면 생략
    },
    {
        phase = "turn_start", -- 생략하면 inputEvent.type
        currentCard = {        -- 카드 사건이 아니면 생략
            id = "accidental_brush",
            instanceId = "player-001",
            owner = "player",
            actionTag = "contact",
        },
        insightSide = "player",       -- 간파가 없으면 생략
        allowGameplayCommands = true, -- 생략 시 true
    }
)
```

성공 결과는 다음과 같다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},
    state = nextState,
    transient = nextTransient,
    records = { ... },
}
```

실패 결과는 `{ ok=false, schemaVersion=1, errors={...} }`이며 부분 상태나 부분 record를 반환하지 않는다. `staticData`는 `staticData.loadAll`의 `data` 또는 그 report 자체를 받을 수 있다.

`phase`와 `currentCard`는 조건 및 resolve callback에 전달하는 context를 만드는 데만 쓴다. `currentCard`를 주면 네 필드 `id`, `instanceId`, `owner`, `actionTag`만 허용하며 앞의 세 필드는 필수다.

## 2. 입력 불변성과 원자성

`working.state`, `working.transient`와 `inputEvent`는 호출 직후 각각 복제한다. callback에는 이 복제본에서 만든 context와 사건의 보호된 복제본만 전달한다. 성공과 실패 모두 호출자가 넘긴 세 입력을 변경하지 않는다.

하나의 batch가 도중에 실패하면 앞 후보의 명령을 이미 내부 작업 복제본에 적용했더라도 그 복제본과 부분 record를 버린다. 호출자는 성공 report만 새 권위 상태로 채택해야 한다.

정적 DB의 callback 함수 때문에 `staticData` 전체를 data-only 복제할 수는 없다. 파이프라인은 정적 테이블에 쓰지 않으며, DB callback은 context와 input event를 읽기 전용 값으로 취급해야 한다.

## 3. snapshot 후보와 고정 순서

파이프라인은 batch 시작 상태 snapshot 하나에서 다음 후보를 수집한다.

1. `player.planSlot`, `character.planSlot`의 점유 계획
2. `character.traitIds`가 참조하는 특징의 `triggers`
3. `player.perkIds`가 참조하는 퍽의 `triggers`
4. 현재 `environmentId`가 참조하는 환경의 `triggers`

모든 후보의 선언 필터와 `trigger(context, inputEvent)` 조건을 같은 snapshot으로 먼저 평가한다. 모든 조건 평가가 성공한 뒤에만 resolve 및 명령 적용 단계로 넘어간다. 따라서 앞 트리거가 바꾼 자원, 무드 또는 transient 값은 뒤 후보의 이번 batch 참가 여부를 바꾸지 않는다.

정렬 키는 다음 순서다.

```text
source category: plan → trait → perk → environment
side: inputEvent.side → opposing side → ownerless
side-less event: player → character → ownerless
stable source: sourceId ASCII 오름차순 → 선언 배열의 1-based index
```

동일한 정렬 키가 비정상 입력으로 반복된 경우에도 수집 ordinal을 마지막 tie-breaker로 사용한다. Lua `pairs` 순서는 실행 순서에 사용하지 않는다.

트리거 선언이 일반 테이블이 아니거나 `resolve` 함수가 없으면 `invalid_trigger`로 실패한다. 선언된 `event`·`side`, 조건 함수와 반환형, resolve 실행과 명령 배열은 `effectEngine`의 보호된 검사 경계를 통과한다. callback 예외는 Lua 오류로 탈출하지 않고 구조화된 오류가 된다.

## 4. context

각 후보는 같은 상태 snapshot에서 아래 context를 받는다.

```lua
{
    turn = state.turnNumber,
    phase = options.phase,
    mood = state.character.mood,
    player = {
        stealth = state.player.stealth,
        handCount = <player hand 인스턴스 수>,
    },
    character = {
        resistance = state.character.resistance,
        publicActionTag = state.characterIntent.publicActionTag,
    },
    card = options.currentCard, -- 지정한 경우에만
    plan = {                    -- 계획 후보에만
        cardId = ...,
        cardInstanceId = ...,
        side = ...,
        revealed = ...,
        remainingTurns = ...,  -- 슬롯에 있을 때만
        remainingCharges = ...,-- 슬롯에 있을 때만
    },
}
```

## 5. resolve, 명령과 계획 수명

조건에 맞은 후보는 고정 순서대로 resolve한다. 반환 명령은 각 후보 단위로 `effectEngine.applyCommands`에 넘기고, 그 결과의 `state`와 `transient`를 다음 후보가 이어받는다.

계획 후보가 억제되지 않고 성공적으로 resolve되면 명령 수가 0이어도 다음 순서를 반드시 수행한다.

1. 계획 슬롯을 공개한다.
2. `remainingCharges`가 있으면 1 감소시킨다.
3. 충전이 0이 되면 즉시 `discard`로 옮기고 슬롯을 비운다.

이 전이는 `cardZones.consumePlanCharge`가 담당한다. `remainingTurns` 감소와 지속시간 0 계획의 버림은 턴 종료 정리의 책임이므로 이 파이프라인은 수행하지 않는다.

`options.insightSide`가 있으면 그 진영의 반대편 **plan 후보만** 억제한다. 특징, 퍽과 환경은 억제하지 않는다. 호출자는 간파가 유효한 입력 사건 batch에만 이 옵션을 전달해야 한다. 억제된 계획은 resolve, 공개, 충전 소비를 하지 않는다.

`options.allowGameplayCommands=false`인 batch에서 resolve가 명령을 하나라도 반환하면 `unsupported_session_end_commands`로 전체 batch가 원자 실패한다. 명령이 0개면 트리거 해결 record와 계획 공개·충전 처리는 정상 수행한다. 이 옵션은 `session_end`처럼 게임플레이 자원 변경을 금지하는 호출 경계를 위한 것이다.

## 6. 중립 record

`records`는 발생 순서가 권위인 연속 배열이다. 각 항목은 다음 형태다.

```lua
{
    type = "effect_applied" | "plan_changed" | "trigger_resolved" | "trigger_suppressed",
    source = {
        kind = "plan" | "trait" | "perk" | "environment",
        id = "source_id",
        side = "player" | "character", -- 소유 진영이 있을 때
        instanceId = "...",             -- 계획 후보일 때
    },
    side = "player" | "character",     -- 소유 진영이 있을 때
    payload = { ... },
}
```

파이프라인은 `eventId`, `sequence`, `phase`, `resolutionId`와 `cause`를 만들지 않는다. 호출자는 record를 자신의 사건 배열에 붙일 때 전역 sequence와 eventId를 할당하고, 호출 문맥의 phase·resolutionId·cause를 보강한다. 난수, 시각과 테이블 주소는 record 생성에 사용하지 않는다.

record 순서는 후보마다 다음과 같다.

```text
resolve 명령마다 effect_applied
계획 후보면 plan_changed
trigger_resolved
```

간파로 억제된 후보는 위 record 대신 `trigger_suppressed` 하나만 만든다. 그 payload는 `inputEventType`, `reasonCode="insight"`, snapshot 시점의 공개 여부에서 계산한 `hidden`을 가진다. 내부 권위 record의 source에는 억제된 실제 plan ID와 instance ID를 유지한다. 공개 view나 서술로 투영할 때 숨은 계획 ID를 제거하는 것은 public projector의 책임이다.

`plan_changed.payload`는 `action="triggered"`, 슬롯 `before`·`after`, `discarded`, `movedInstanceIds`를 가진다. `trigger_resolved.payload`는 `inputEventType`과 `commandCount`를 가진다. `effect_applied.payload`는 `effectEngine.applyCommands`의 data-only 적용 영수증이다.

## 7. 호출자별 사용

- 턴 initializer는 진영 없는 `{type="turn_start"}`와 `phase="turn_start"`로 먼저 실행하고, 성공 state/transient를 기본 드로우 및 캐릭터 의도 선택의 입력으로 사용한다.
- 턴 resolver는 카드 사건에 `currentCard`를 주고, 해당 카드의 간파 batch에만 `insightSide`를 준다. `session_end`에는 `allowGameplayCommands=false`를 준다.
- 두 호출자 모두 성공 record에 자신의 phase·cause·resolution 문맥과 ID를 붙인 뒤 사건 로그에 append한다. 파이프라인 record를 다시 트리거 입력으로 순회하지 않는다.
