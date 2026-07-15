# 카드 데이터 계약 v1

상태: 0단계 확정

이 문서는 정적 Lua 카드 DB, 전투 엔진, 세이브 상태, UI View와 LLM 사건 사이의 경계를 정의한다. 아래 여섯 장은 밸런스나 최종 콘텐츠가 아니라 데이터 구조와 엔진 경로를 검증하기 위한 프로토타입이다.

## 1. 결정된 원칙

- 카드·특징·환경과 캐릭터 같은 정적 정의는 Lua 테이블로 작성한다.
- 진행 상태와 세이브는 함수가 없는 JSON 직렬화 가능한 값만 사용한다.
- 내부 ID와 스키마 키는 ASCII를 사용한다.
- 카드·태그·메커니즘·사건·효과 명령 같은 ID 값은 `lower_snake_case`, `cardId` 같은 스키마 필드명은 lowerCamelCase를 사용한다.
- 카드명, 규칙 설명과 LLM 묘사는 한글을 사용한다.
- 카드 함수는 실제 Lua 함수로 작성할 수 있다.
- 카드 함수는 상태를 직접 변경하지 않고 구조화된 효과 명령 목록을 반환한다.
- 공통 엔진이 효과 명령을 검증하고 환경·퍽·특징을 적용한 뒤 상태와 이벤트 로그를 변경한다.
- 모든 카드는 행동 태그 하나를 가지며 메커니즘은 0개 이상 가질 수 있다.
- 메커니즘 배열의 작성 순서는 처리 순서를 결정하지 않는다.

## 2. 데이터 경계

```text
정적 Lua 카드 정의
→ 읽기 전용 판정 컨텍스트로 함수 실행
→ 구조화된 효과 명령
→ 공통 전투 엔진
→ 런타임 상태와 사건 로그
→ 화면별 View / LLM 턴 사건
```

정적 정의는 세이브 데이터에 복사하지 않는다. 세이브에는 다음처럼 카드 ID와 변화 가능한 값만 기록한다.

```lua
local cardInstanceState = {
    instanceId = "card-0007",
    cardId = "accidental_brush",
    zone = "hand",
    temporaryModifiers = {},
}
```

`temporaryModifiers`는 선택 필드다. 내부 명령 스키마가 전투 엔진 단계에서 확정되기 전에는 생략하거나 빈 배열로만 두며, 임의 필드를 가진 payload는 허용하지 않는다.

계획 슬롯도 원본 함수 대신 ID와 수명 상태만 저장한다.

```lua
local planState = {
    cardInstanceId = "card-0003",
    cardId = "subtle_approach",
    placedTurn = 2,
    remainingTurns = 1,
    remainingCharges = 1,
    revealed = false,
}
```

## 3. 정적 DB 모듈 형식

한 DB 로어북은 `.db` 이름을 사용하지만 다음 형태의 Lua 청크를 반환한다.

```lua
return {
    schemaVersion = 1,
    kind = "cardDatabase",
    cards = {
        card_id = {
            id = "card_id",
            -- 카드 정의
        },
    },
}
```

여러 DB 로어북을 합칠 때 `card.id`를 기준으로 병합하며 중복 ID는 오류로 처리한다. Lua DB는 로딩 이외의 부수효과를 만들면 안 된다. 전역 상태 변경, 채팅 변수 변경, 무작위 실행과 다른 스크립트 호출은 금지한다.

정적 DB 로더는 제한된 환경에서 청크를 실행해야 한다. 카드 콜백에 필요한 읽기 전용 표준 함수만 제공하고 RisuAI 상태 변경 함수는 제공하지 않는다.

## 4. 카드 공통 필드

| 필드 | 필수 | 의미 |
|---|---|---|
| `id` | 필수 | 저장과 참조에 사용하는 고정 ASCII ID |
| `owner` | 필수 | `player` 또는 `character` |
| `name` | 필수 | UI에 표시할 한글 카드명 |
| `description` | 필수 | 행동 태그와 메커니즘을 인라인 토큰으로 포함한 사용자용 규칙 설명 |
| `actionTag` | 필수 | 행동을 분류하는 ASCII 태그 하나 |
| `mechanisms` | 필수 | 메커니즘 ID 배열, 없으면 빈 배열 |
| `mechanismData` | 선택 | 설정값이 필요한 메커니즘별 데이터 테이블 |
| `base` | 필수 | 기본 은폐 비용과 기본 저항 피해 |
| `rules` | 필수 | UI에 순서대로 표시할 규칙 문장 배열 |
| `canPlay` | 선택 | 사용 가능 여부와 사유 코드를 반환하는 함수 |
| `resolve` | 선택 | 기본 효과 뒤에 적용할 효과 명령을 반환하는 함수 |
| `moodEffects` | 선택 | 현재 무드별 추가 효과 함수 |
| `narration` | 필수 | LLM 턴 사건에 넣을 행동·생각 묘사 |
| `prototype` | 임시 | 프로토타입 카드임을 표시, 최종 DB에서는 제거 가능 |

기본 수치는 화면에서 바로 비교하고 환경·퍽 보정의 대상을 구분할 수 있도록 함수 밖에 둔다.

```lua
base = {
    stealthCost = 0,       -- 양수, 카드 선언 비용
    resistanceDamage = 3, -- 양수, 상대 저항 기본 피해
}
```

캐릭터 카드도 같은 스키마를 사용한다. 캐릭터 카드가 기본 저항 피해나 은폐 비용을 사용하지 않으면 0을 기록하고, 실제 효과는 구조화 명령으로 반환한다.

## 5. 내부 식별자

내부 식별자와 스키마 필드명은 역할을 구분한다.

- 레지스트리 키, `id`, `event.type`, 환경 트리거의 `event`와 효과 명령의 `op`: `lower_snake_case`
- Lua/JSON 테이블의 필드명과 런타임 API 작업명: lowerCamelCase
- 사용자에게 보이는 이름과 설명: 한글

예를 들어 `cardDeclared`라는 필드명을 만들지 않고 사건 ID 값으로 `card_declared`를 사용하며, 카드 참조 필드는 `cardId`로 유지한다. 레지스트리 키와 내부 `id`는 항상 같아야 한다.

초기 알파의 내부 ID는 다음 값부터 시작한다.

```text
player action tags: observation, approach, deception, threat, contact, violation
character action tags: evade, block, vigilance, intimidate, expose
mechanisms: chain, remove, plan, insight
moods: rejection, suspicion, ignore, confusion, compliance
```

UI에는 중앙 표시명 사전을 통해 `관찰`, `접근`, `연계`, `거절` 같은 한글 이름을 보여준다. DB 함수와 세이브 상태에서 한글 표시명을 조건값으로 사용하지 않는다.

### 설명 속 태그 토큰

카드의 `description`은 자신의 `actionTag`와 모든 `mechanisms`를 문장 안에 포함한다. 태그 표시는 `¤접촉¤` 대신 다음 ASCII 토큰 형식을 사용한다.

```text
::tag[contact]::
::tag[insight]::
```

`::tag[ASCII_ID]::`는 CBS의 `{{...}}`, HTML의 `<...>`와 Lua 장문 문자열의 `[[...]]`를 사용하지 않아 각 파서와 충돌할 가능성이 낮다. 태그 ID는 `^[a-z][a-z0-9_]*$` 형식만 허용한다. 내부 ID와 한글 표시명을 분리할 수 있어 번역이나 표시명 변경도 카드 문장을 깨뜨리지 않는다.

```lua
description = "::tag[observation]:: 행동입니다. ::tag[chain]::으로 주 행동을 남기고, ::tag[insight]::로 이 해결에 반응하는 상대 ::tag[plan]::을 억제합니다."
```

태그 토큰은 표시용이며 판정의 원본이 아니다. 엔진은 계속 `actionTag`, `mechanisms`와 효과 함수를 사용한다. 설명에는 카드가 보유하지 않은 태그도 규칙의 대상으로 언급할 수 있지만 등록되지 않은 ID는 오류로 처리한다.

로드 검증기는 `description`에 자신의 `actionTag`와 모든 `mechanisms` 토큰이 각각 한 번 이상 존재하는지 확인한다. 문장에서 같은 태그를 여러 번 언급하는 것은 허용한다. `rules`에서 태그를 언급할 때도 같은 토큰 형식을 사용할 수 있다.

View 생성기는 원문을 HTML 문자열로 직접 치환하지 않고 다음과 같은 `descriptionSegments`로 토큰화한다.

```lua
descriptionSegments = {
    {
        kind = "tag",
        id = "contact",
        label = "접촉",
        tagKind = "action",
        tooltip = "신체 접촉을 시도하는 행동",
    },
    {
        kind = "text",
        value = " 행동으로 열차의 흔들림을 이용해 우연을 가장합니다.",
    },
}
```

CBS/HTML은 `tag` 조각만 신뢰된 `span`으로 만들고 `text` 조각은 이스케이프해 출력한다. 결과 요소의 의미 구조는 다음과 같다.

```html
<span class="card-tag card-tag--action" data-tag-id="contact" title="신체 접촉을 시도하는 행동">접촉</span>
```

태그는 본문과 구분되면서 줄 높이를 흔들지 않는 작은 인라인 라벨로 표시한다. 기본 스타일은 다음 값을 기준으로 하며, 실제 RisuAI 접두사가 붙은 CSS 선택자는 전투 UI 연결 단계에서 확인한다.

```css
.card-tag {
    display: inline-flex;
    align-items: center;
    padding: 0.08em 0.35em;
    border: 1px solid currentColor;
    border-radius: 3px;
    font-size: 0.82em;
    font-weight: 700;
    line-height: 1.25;
    letter-spacing: 0;
    vertical-align: baseline;
    white-space: nowrap;
}

.card-tag--action {
    color: #124e48;
    background: #dff7f4;
}

.card-tag--mechanism {
    color: #663c00;
    background: #fff0d6;
}
```

표시명, `tagKind`, 툴팁은 카드 문장이 아니라 중앙 태그 표시 레지스트리에서 가져온다. 행동 태그와 메커니즘 ID는 이 표시 레지스트리 안에서 서로 중복될 수 없다.

메커니즘 ID는 카드가 임의로 새로 만들지 않고 중앙 메커니즘 레지스트리에 먼저 등록한다. 레지스트리는 표시명, 개입 타이밍, 필요한 카드 데이터 검증과 다른 메커니즘과의 충돌 규칙을 정의한다. 카드의 `mechanisms`는 등록된 ID만 나열하고, 카드별 설정이 필요한 경우 `mechanismData` 아래에서 같은 ID를 키로 사용한다.

```lua
mechanisms = { "plan", "remove" },
mechanismData = {
    plan = {
        -- 계획 전용 설정
    },
}
```

`chain`, `remove`, `insight`처럼 카드별 설정이 필요 없는 메커니즘은 `mechanismData` 항목을 만들지 않는다. 새 메커니즘을 추가할 때는 다음 항목을 함께 정의한다.

- 안정적인 ASCII ID와 한글 표시명
- 개입할 사건과 해결 타이밍
- 카드별 설정 스키마와 검증 규칙
- 카드 영역, 행동 횟수와 숨겨진 정보에 미치는 영향
- 이벤트 로그, View와 LLM 사건에 노출할 정보
- 다른 메커니즘과 조합한 대표 테스트

## 6. 카드 함수 계약

### 읽기 전용 컨텍스트

카드 함수는 현재 판정에 필요한 읽기 전용 컨텍스트를 받는다. 초기 컨텍스트는 다음 범위를 제공한다.

```lua
local context = {
    turn = 3,
    phase = "playerCard",
    mood = "suspicion",
    player = {
        stealth = 24,
        handCount = 3,
    },
    character = {
        resistance = 18,
        publicActionTag = "vigilance",
    },
    card = {
        id = "accidental_brush",
        instanceId = "card-0007",
    },
    plan = nil,
}
```

실제 구현에서는 콜백이 컨텍스트를 변경하지 못하도록 읽기 전용 프록시 또는 복사본을 전달한다. 콜백은 무작위 함수를 직접 호출하지 않는다. 무작위 결과가 필요하면 엔진이 시드와 결과를 정해 컨텍스트로 제공한다.

### 사용 조건

`canPlay`는 상태를 변경하지 않고 두 값을 반환한다.

```lua
canPlay = function(context)
    if context.player.stealth <= 3 then
        return false, "insufficient_stealth"
    end
    return true, nil
end
```

두 번째 값은 UI 표시 문구가 아니라 안정적인 사유 코드다. View 생성기가 사유 코드를 한글 문구로 변환한다.

### 효과 함수

`resolve`와 무드·계획 효과 함수는 효과 명령 배열을 반환한다.

```lua
resolve = function(context)
    return {
        {
            op = "recover_stealth",
            target = "player",
            amount = 3,
            cause = "cardEffect",
        },
    }
end
```

콜백은 다음 작업을 하면 안 된다.

- `context` 또는 전투 상태 직접 변경
- `setState`, `setChatVar`, `addChat` 등 RisuAI 함수 호출
- 카드 영역을 직접 이동
- 이벤트 로그 직접 작성
- LLM 호출
- 현재 시각이나 비결정적 난수 사용

## 7. 초기 효과 명령

모든 효과 명령은 최소한 `op`, `target`과 명령별 필수 값을 가진다. `cause`는 비용, 기본 효과, 무드 추가효과, 계획 등 발생 원인을 구분한다.

| `op` | 주요 값 | 의미 |
|---|---|---|
| `damage_resistance` | `amount` | 캐릭터 저항 피해 |
| `recover_resistance` | `amount` | 캐릭터 저항 회복 |
| `lose_stealth` | `amount` | 비용과 구분되는 외부 은폐 손실 |
| `recover_stealth` | `amount` | 은폐 회복 |
| `draw_cards` | `amount` | 대상 덱에서 카드 드로우 |
| `skip_actions` | `scope` | 이번 턴 대상의 남은 카드 행동 생략 |
| `shift_mood` | `amount` | 현재 무드를 지정 단계만큼 직접 이동 |
| `set_mood` | `mood` | 무드를 특정 단계로 직접 설정 |
| `lock_mood` | `mood`, `until` | 조건이 맞는 동안 무드 변경 방지 |

기본 은폐 비용과 기본 저항 피해는 `base`에서 엔진이 효과 사건으로 만든다. 카드 함수가 같은 기본 효과를 다시 반환하지 않는다.

새로운 `op`를 추가할 때는 다음 항목을 함께 구현한다.

- 명령 데이터 검증
- 환경·퍽·특징의 개입 시점
- 상태 적용
- 이벤트 로그
- 예상 결과 View
- LLM 턴 사건 변환
- 대표 테스트

## 8. 해결 순서

카드 한 장은 다음 순서로 해결한다.

1. 최종 은폐 비용 계산과 사용 가능 여부 검사
2. 최종 비용 지불
3. 카드 선언 사건을 만들고 해당 카드 때문에 발동할 사용 전 트리거 수집
4. `insight`가 있다면 수집된 상대 계획을 억제
5. 억제되지 않은 계획과 나머지 사용 전 트리거 적용
6. `base.resistanceDamage` 적용
7. `resolve`가 반환한 일반 효과 적용
8. 현재 무드에 해당하는 `moodEffects` 적용
9. 카드 사용 후 트리거 적용
10. 카드 영역 이동과 중간 승패 확인

메커니즘의 처리 순서는 `mechanisms` 배열 순서와 무관하다. 예를 들어 `chain+insight`를 `insight+chain`으로 작성해도 같은 결과가 나와야 한다.

엔진은 카드 한 장의 해결마다 고유한 해결 ID를 만들고 그 카드가 직접 만든 효과 사건에 같은 원본 해결 ID를 붙인다. `insight`는 이 원본 해결 ID를 가진 사건 때문에 발동할 상대 계획에만 적용한다. 드로우한 카드를 나중에 별도로 사용하거나 다른 카드가 독립적으로 만든 사건은 새로운 해결이므로 억제 범위에 포함하지 않는다.

카드가 `shift_mood`, `set_mood` 또는 `lock_mood`를 실제로 적용하면 해당 턴의 공통 무드 성과 판정을 생략한다.

## 9. 계획 계약

`plan` 메커니즘이 있는 카드는 `mechanismData.plan` 필드를 가진다.

```lua
mechanismData = {
    plan = {
        durationTurns = 1,
        charges = 1,

        trigger = function(context, event)
            return event.type == "turn_start"
                and event.side == "player"
                and context.mood == "ignore"
        end,

        resolve = function(context, event)
            return {
                {
                    op = "lock_mood",
                    target = "character",
                    mood = "ignore",
                    ["until"] = "turn_end",
                    cause = "plan",
                },
            }
        end,
    },
}
```

계획 데이터는 `durationTurns`, `charges`, `expires` 중 하나 이상으로 수명이 제한되어야 한다. `durationTurns`는 배치한 턴에는 감소하지 않고 다음 턴 종료부터 감소한다.

`trigger`는 발동 가능 여부만 반환하고 상태를 변경하지 않는다. `resolve`가 반환한 명령을 엔진이 적용한 뒤에만 충전을 소비한다. 간파로 억제되면 충전을 소비하지 않지만 지속 턴은 정상적으로 흐른다.

상대 View에는 슬롯 점유 여부를 항상 전달하고, `durationTurns`가 있는 계획은 남은 지속 턴도 전달한다. 이름, 규칙과 조건은 첫 발동 또는 별도 관찰 효과 전에는 넣지 않으며, 공개된 뒤에는 슬롯에서 벗어날 때까지 전달한다. 남은 충전은 공개 여부와 무관하게 숨기고 이를 확인하는 별도 효과가 있을 때만 전달한다. 함수는 어떤 View에도 넣지 않는다. 발동하지 않고 만료되거나 교체된 계획은 공개하지 않는다.

## 10. LLM 묘사 계약

규칙 문장과 LLM 묘사는 분리한다.

```lua
narration = {
    planPlaced = {
        actorAction = "다음 기회를 위해 상대의 움직임을 관찰한다.",
    },
    planTriggered = {
        actorAction = "미리 살핀 움직임을 바탕으로 태도를 유지한다.",
    },
    planExpired = {
        actorAction = "기회를 잡지 못한 채 준비를 거둔다.",
    },
}
```

일반 카드는 `play`가 필수다. 계획 카드는 `planPlaced`와 `planTriggered`가 필수이며 일반 `play`는 사용하지 않는다. 만료 장면을 실제로 묘사해야 할 때만 `planExpired`를 사용한다.

상대의 계획이 아직 공개되지 않았다면 `planPlaced`와 `planExpired` 같은 카드별 문장을 LLM 사건에 넣지 않는다. 이때는 메커니즘 레지스트리가 제공하는 공용의 중립적인 계획 배치·소멸 사건만 사용하며 카드 ID, 조건, 효과와 카드별 생각을 전달하지 않는다. 자기 계획이나 이미 관찰로 공개된 계획처럼 정체를 아는 관점에서만 카드별 문장을 사용한다. `planTriggered`는 발동과 함께 계획이 공개될 때 전달할 수 있다.

문장에는 카드 이름, 수치와 `카드를 사용했다` 같은 규칙 표현을 넣지 않는다. 행위자와 대상은 사건 데이터가 별도로 지정하므로 DB 문장에 RisuAI CBS 이름 치환자를 직접 넣지 않는다.

## 11. 프로토타입 플레이어 카드 6장

다음 코드는 계약 검증용 정적 DB 초안이다.

```lua
return {
    schemaVersion = 1,
    kind = "cardDatabase",
    cards = {
        subtle_approach = {
            id = "subtle_approach",
            owner = "player",
            name = "은밀한 접근",
            description = "::tag[approach]:: 행동으로 상대의 반응을 살피고, ::tag[plan]::을 배치해 다음 턴을 준비합니다.",
            actionTag = "approach",
            mechanisms = { "plan" },
            base = {
                stealthCost = 0,
                resistanceDamage = 0,
            },
            rules = {
                "다음 턴 시작 무드가 무시라면 그 턴 동안 무드를 고정합니다.",
            },
            mechanismData = {
                plan = {
                    durationTurns = 1,
                    charges = 1,
                    trigger = function(context, event)
                        return event.type == "turn_start"
                            and event.side == "player"
                            and context.mood == "ignore"
                    end,
                    resolve = function(context, event)
                        return {
                            {
                                op = "lock_mood",
                                target = "character",
                                mood = "ignore",
                                ["until"] = "turn_end",
                                cause = "plan",
                            },
                        }
                    end,
                },
            },
            narration = {
                planPlaced = {
                    actorAction = "상대의 움직임을 관찰하며 다음 기회를 준비한다.",
                },
                planTriggered = {
                    actorAction = "미리 살핀 반응을 바탕으로 분위기가 흔들리지 않게 행동한다.",
                },
            },
            prototype = true,
        },

        accidental_brush = {
            id = "accidental_brush",
            owner = "player",
            name = "우연한 스침",
            description = "::tag[contact]:: 행동으로 열차의 흔들림을 이용해 우연을 가장하고 저항을 낮춥니다.",
            actionTag = "contact",
            mechanisms = {},
            base = {
                stealthCost = 0,
                resistanceDamage = 3,
            },
            rules = {
                "의심 무드에서 사용하면 은폐를 3 잃습니다.",
            },
            moodEffects = {
                suspicion = function(context)
                    return {
                        {
                            op = "lose_stealth",
                            target = "player",
                            amount = 3,
                            cause = "moodEffect",
                        },
                    }
                end,
            },
            narration = {
                play = {
                    actorAction = "열차가 흔들리는 순간에 맞춰 우연인 듯 움직인다.",
                },
            },
            prototype = true,
        },

        play_it_cool = {
            id = "play_it_cool",
            owner = "player",
            name = "능청떨기",
            description = "::tag[deception]:: 행동으로 아무런 관심이 없는 척하며 은폐를 회복합니다.",
            actionTag = "deception",
            mechanisms = {},
            base = {
                stealthCost = 0,
                resistanceDamage = 0,
            },
            rules = {
                "은폐를 3 회복합니다.",
                "거절 무드라면 대신 1 회복합니다.",
            },
            resolve = function(context)
                local amount = 3
                if context.mood == "rejection" then
                    amount = 1
                end
                return {
                    {
                        op = "recover_stealth",
                        target = "player",
                        amount = amount,
                        cause = "cardEffect",
                    },
                }
            end,
            narration = {
                play = {
                    actorAction = "혼잣말을 하며 주변 일에 관심 없는 듯 태연하게 행동한다.",
                },
            },
            prototype = true,
        },

        read_the_room = {
            id = "read_the_room",
            owner = "player",
            name = "눈치보기",
            description = "::tag[observation]:: 행동입니다. ::tag[chain]::으로 주 행동을 남기고, ::tag[insight]::로 이 해결에 반응하는 상대 ::tag[plan]::을 억제합니다.",
            actionTag = "observation",
            mechanisms = { "chain", "insight" },
            base = {
                stealthCost = 0,
                resistanceDamage = 0,
            },
            rules = {
                "카드를 1장 뽑습니다.",
                "이 카드 때문에 발동할 상대 ::tag[plan]::을 억제하지만 그 정보는 공개하지 않습니다.",
            },
            resolve = function(context)
                return {
                    {
                        op = "draw_cards",
                        target = "player",
                        amount = 1,
                        cause = "cardEffect",
                    },
                }
            end,
            narration = {
                play = {
                    actorAction = "곧바로 움직이지 않고 상대의 시선과 주변 상황을 살핀다.",
                },
            },
            prototype = true,
        },

        pin_down = {
            id = "pin_down",
            owner = "player",
            name = "제압",
            description = "::tag[threat]:: 행동으로 상대를 강하게 압박합니다. ::tag[insight]::로 이 해결에 반응하는 상대 ::tag[plan]::을 억제합니다.",
            actionTag = "threat",
            mechanisms = { "insight" },
            base = {
                stealthCost = 3,
                resistanceDamage = 7,
            },
            rules = {
                "이 카드 때문에 발동할 상대 ::tag[plan]::을 억제하지만 그 정보는 공개하지 않습니다.",
            },
            narration = {
                play = {
                    actorAction = "상대가 쉽게 움직이지 못하도록 강하게 압박한다.",
                },
            },
            prototype = true,
        },

        hypnotic_whisper = {
            id = "hypnotic_whisper",
            owner = "player",
            name = "최면의 속삭임",
            description = "::tag[deception]:: 행동으로 상대의 판단을 흐리고, 사용 후 ::tag[remove]::되어 이번 세션에서 제외됩니다.",
            actionTag = "deception",
            mechanisms = { "remove" },
            base = {
                stealthCost = 0,
                resistanceDamage = 0,
            },
            rules = {
                "캐릭터는 이번 턴 남은 카드 행동을 수행하지 않습니다.",
                "무드를 순응 방향으로 한 단계 직접 이동합니다.",
                "사용 후 이번 세션에서 ::tag[remove]::됩니다.",
            },
            resolve = function(context)
                return {
                    {
                        op = "skip_actions",
                        target = "character",
                        scope = "remainingTurn",
                        cause = "cardEffect",
                    },
                    {
                        op = "shift_mood",
                        target = "character",
                        amount = 1,
                        cause = "cardEffect",
                    },
                }
            end,
            narration = {
                play = {
                    actorAction = "낮은 목소리로 짧은 암시를 건네 상대의 판단을 흐린다.",
                },
            },
            prototype = true,
        },
    },
}
```

## 12. 로드 시 검증 항목

- DB `schemaVersion`과 `kind`가 지원되는 값인지 검사
- 테이블 키, `card.id`와 저장 ID가 일치하는지 검사
- 카드 ID 중복 검사
- `owner`, 행동 태그와 메커니즘 ID 검사
- 행동 태그가 정확히 하나인지 검사
- `mechanisms`가 배열이며 순서가 의미를 만들지 않는지 검사
- 기본 비용과 피해가 0 이상의 유한한 숫자인지 검사
- `mechanismData`의 모든 키가 `mechanisms`에도 존재하는지 검사
- 설정값이 필요한 메커니즘에 대응하는 `mechanismData`가 있는지 검사
- `plan` 메커니즘과 `mechanismData.plan`이 함께 존재하는지 검사
- 계획에 제한된 수명이 있는지 검사
- `canPlay`, `resolve`, 무드 효과와 계획 콜백이 함수인지 검사
- 규칙 설명과 필수 묘사가 비어 있지 않은지 검사
- `description`의 태그 토큰 문법과 등록된 ID를 검사
- 자신의 행동 태그와 모든 메커니즘 토큰이 `description`에 한 번 이상 있는지 검사
- 태그 표시 레지스트리에서 행동 태그와 메커니즘 ID가 중복되지 않는지 검사
- 알 수 없는 효과 `op`를 반환하면 적용 전에 오류 처리
- 함수나 비공개 계획 데이터가 세이브와 View에 포함되지 않는지 검사

## 13. 아직 열려 있는 계약

다음 항목은 전투 엔진 구현 전에 공동 결정한다.

- 동일 타이밍 트리거의 소유자·출처별 우선순위
- 고정 수치, 배율, 최소값과 반올림 적용 순서
- 카드 콜백이 현재 이벤트와 과거 이벤트를 어느 범위까지 읽을 수 있는지
- 새로 드로우한 연계 카드의 같은 턴 사용 가능 여부
- 계획의 `durationTurns`와 이벤트별 감소 시점 세부 규칙
- 캐릭터 카드가 공통 `base` 필드를 어떻게 표시할지
- 예상 결과가 숨겨진 계획 때문에 달라질 수 있을 때 UI에 보여줄 범위
- 희귀도, 드래프트 가중치와 도감 정보의 별도 메타데이터 구조
