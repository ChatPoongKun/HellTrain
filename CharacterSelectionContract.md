# 캐릭터 행동 선택 계약 v1

## 1. 역할과 경계

`System/characterSelector.lua`는 턴 시작 효과와 양측 기본 드로우가 끝난 권위 `battleState`에서 캐릭터의 비공개 주 행동 한 장을 결정한다. 입력 상태와 정적 DB를 변경하지 않고, 의도와 공유 RNG가 반영된 새 상태 및 함수 없는 선택 영수증을 반환한다.

```text
turn_start 처리 완료 상태
→ 플레이어·캐릭터 기본 드로우 완료 상태
→ characterSelector.selectIntent
→ characterIntent가 채워진 턴 선택 권위 상태
→ action_tag_revealed 처리와 player turnDraft
```

이 모듈은 카드를 실제로 사용하거나 수치를 변경하지 않는다. 선택된 카드의 `hand → used`, 효과 적용과 계획 배치는 `turnResolver`가 수행한다. `main.lua`, UI, View와 LLM 사건 변환도 이 모듈의 책임이 아니다.

## 2. API

```lua
runScript(
    triggerId,
    "characterSelector",
    "selectIntent",
    stateAfterDraw,
    staticData
)
```

입력 상태는 다음 조건을 만족해야 한다.

- `stateSchema.validateBattleState(stateAfterDraw, staticData)`의 전체 참조 검증을 통과한다.
- 전투 상태는 `active`다.
- `characterIntent.cardInstanceIds`는 비어 있고 `publicActionTag`가 없다.
- 턴 시작 효과와 이번 턴 기본 드로우는 이미 한 번만 처리되어 있다.
- `state.rng`는 드로우 중 발생한 discard 재섞기까지 반영한 공유 RNG다.

이미 의도가 있는 상태를 다시 선택하면 `character_intent_already_selected`로 거부한다. 이는 같은 턴의 가중 추첨을 다시 실행해 결과를 바꾸는 것을 막는다.

성공 결과는 다음 형식이다.

```lua
{
    ok = true,
    schemaVersion = 1,
    errors = {},

    state = nextState,
    intent = {
        cardInstanceIds = { "character-003" },
        publicActionTag = "evade",
    },
    receipt = {
        schemaVersion = 1,
        kind = "characterIntentSelection",
        battleId = "battle-0001",
        turnNumber = 1,
        characterId = "yoo_jiyoung",
        selectionContext = {
            turnNumber = 1,
            player = { stealth = 30, handCount = 3 },
            character = { resistance = 30, mood = "ignore" },
            characterHand = {
                {
                    instanceId = "character-001",
                    cardId = "close_collar",
                    actionTag = "block",
                    handPosition = 1,
                },
                -- 나머지 선택 시점 손패도 안정 순서대로 기록
            },
        },
        candidates = {}, -- 문서 예시에서는 네 후보의 상세 감사 값을 생략
        weightedPoolInstanceIds = {
            "character-001",
            "character-002",
            "character-003",
            "character-004",
        },
        lethalPriorityApplied = false,
        weightOffset = 0,
        rngBefore = { seed = 42, cursor = 0 },
        rngAfter = { seed = 42, cursor = 1 },
        draw = { kind = "weighted", totalWeight = 12, roll = 6 },
        selectedInstanceId = "character-003",
        selectedCardId = "turn_to_corner",
        publicActionTag = "evade",
    },
}
```

`state`, `intent`, `receipt`와 그 하위 테이블은 입력 상태를 참조하지 않는 새 JSON 값이다. 영수증은 판정·재현용 비공개 데이터이며 View에 그대로 전달하지 않는다.

`selectionContext`는 행동 태그 공개 트리거가 실행되기 직전의 턴 번호, 플레이어 은폐·손패 수, 캐릭터 저항·무드와 캐릭터 손패 전체를 보존한다. `characterHand`는 후보 안정 순서와 같은 순서이며 각 항목을 `instanceId`, `cardId`, `actionTag`, `handPosition`에 결합한다. 공개 트리거가 이후 수치나 손패를 바꾸더라도 이 컨텍스트로 선택 효과를 정확히 재평가한다.

## 3. 버전 1의 선택 장수

현재 유지영 카드 네 장에는 `chain`이 없다. 따라서 캐릭터는 손패가 있으면 비연계 주 행동 정확히 한 장만 선택하고, 현재 콘텐츠의 최대 선택 장수도 한 장이다.

`stateSchema`는 장기적으로 `연계 0장 이상 → 비연계 주 행동 정확히 1장` 형식을 표현할 수 있지만, 캐릭터가 어떤 연계를 몇 장 사용하고 어떤 순서로 놓는지는 아직 확정하지 않았다. 손패에서 캐릭터 `chain` 카드를 발견하면 임의로 전부 사용하거나 한 장을 고르지 않고 `unsupported_character_chain_selection`으로 중단한다.

캐릭터 손패가 비어 있으면 정상 패스다.

```lua
intent = { cardInstanceIds = {} }
receipt.draw = { kind = "pass" }
```

패스는 RNG를 소비하지 않고 `publicActionTag`도 만들지 않는다.

## 4. 후보의 안정 순서

캐릭터 손패는 다음 키로 안정 정렬한다.

1. `position` 오름차순
2. `instanceId` 사전순
3. `cardInstances` 원본 배열 index

정상 상태에서는 영역 안의 `position`이 중복되지 않으므로 첫 번째 키가 실제 순서다. 나머지는 잘못된 중간 상태가 안정 순서에 의존하지 않게 하는 방어 키다.

모든 비연계 캐릭터 손패 카드는 점수 후보다. 계획 카드도 `chain`이 없다면 별도 추가 행동이 아니라 주 행동 후보 한 장이다. 따라서 `silent_glare`를 선택하면 의도에는 그 인스턴스 하나만 들어가고 공개 행동 태그는 `intimidate`다.

## 5. 총효과 점수

후보 한 장의 총효과 점수는 다음 네 효과 명령의 합으로 계산한다.

```text
총효과 점수
= recover_resistance 총량
+  lose_stealth 총량
-  damage_resistance 총량
-  recover_stealth 총량
```

다음 세 출처가 모두 점수에 들어간다.

1. `card.resolve(context)`
2. 선택 시점의 현재 무드에 해당하는 `card.moodEffects[currentMood](context)`
3. 계획이라면 6절의 모든 충전 발동 효과

선택 컨텍스트는 드로우 완료 직후 상태의 턴 번호, 무드, 플레이어 은폐·손패 수, 캐릭터 저항과 해당 카드 정보를 사용한다. 플레이어가 아직 행동하기 전의 사전 선택이므로 이후 플레이어 카드로 변할 상태를 예측하지 않는다.

모든 콜백은 `effectEngine`의 읽기 전용 복사본과 보호 호출 경계를 거친다. 콜백 오류, 잘못된 반환형, 잘못된 명령 대상·수치와 미등록 효과 작업은 선택 전체를 원자적으로 실패시킨다.

선택 점수 v1이 해석하는 작업은 다음 네 개뿐이다.

```text
recover_resistance, lose_stealth, damage_resistance, recover_stealth
```

`draw_cards`, `skip_actions`, 무드 변경·고정처럼 위 네 작업에 없는 명령은 임의의 점수나 0점으로 바꾸지 않고 `unsupported_character_score_op`로 거부한다. 실제 콘텐츠가 생기면 사용자 승인 후 점수 의미를 추가한다.

캐릭터 카드의 `base.stealthCost`와 `base.resistanceDamage`는 현재 해결 계약과 같이 둘 다 0이어야 한다. `canPlay`가 있는 캐릭터 카드의 사전 후보 제외·대체 선택 정책도 미정이므로 현재 선택기는 `unsupported_character_can_play_selection`으로 중단한다.

## 6. 계획의 선택 가정과 모든 충전

계획은 미래 사건에 반응하므로 선택 시점에는 어떤 사건을 기준으로 기대 효과를 계산할지 함수 본문만 보고 추측할 수 없다. 캐릭터 계획은 `mechanismData.plan.selectionAssumption`에 함수 없는 최소 가정을 명시한다.

```lua
selectionAssumption = {
    event = {
        type = "card_declared",
        side = "player",
    },
    chargePolicy = "all",
}
```

`staticData` 로더는 다음을 검증한다.

- 모든 캐릭터 계획에 `selectionAssumption`이 있다.
- `event`에는 등록된 `type`과 `player` 또는 `character`인 `side`만 있다.
- `chargePolicy`는 `all`이다.
- 선택 점수용 계획에는 양의 정수 `charges`가 있다.
- 플레이어 계획에는 캐릭터 선택용 가정을 넣지 않는다.

선택기는 `remainingCharges = charges, charges - 1, ..., 1`인 계획 컨텍스트를 만들어 각 충전을 `effectEngine.evaluateTrigger`로 별도 보호 평가한다. 모든 충전의 명령을 합산한다. 명시한 사건이 실제 `trigger` 조건과 일치하지 않으면 0점으로 간주하지 않고 `plan_selection_assumption_not_matched`로 거부한다.

현재 `silent_glare`는 `card_declared/player`를 가정하고 충전 한 번마다 `lose_stealth 3`을 반환하므로 계획 점수는 3이다. 충전이 두 번인 같은 정의라면 두 콜백 결과를 합산해 6점이다.

가정 사건에는 현재 `type`과 `side`만 허용한다. 미래 계획이 카드 ID, 행동 태그나 다른 사건 필드에 의존한다면 해당 필드를 임의로 채우지 않고 먼저 이 선언형 계약을 확장한다.

## 7. 즉시 함락 우선과 가중 추첨 풀

각 후보의 누적 은폐 효과로 다음 값을 계산한다.

```text
예상 플레이어 은폐
= 현재 은폐
- lose_stealth 총량
+ recover_stealth 총량
```

예상 플레이어 은폐가 0 이하인 후보가 하나라도 있으면 그 후보들만 다음 단계에 남긴다. 이 우선순위가 적용되면 `receipt.lethalPriorityApplied = true`다. 계획의 경우 6절에서 합산한 모든 충전을 이 예상값에 포함한다.

치명 후보가 없다면 모든 손패 후보가, 치명 후보가 있다면 모든 치명 후보가 안정 손패 순서 그대로 `weightedPoolInstanceIds`에 들어간다. 최고점 후보로 다시 좁히지 않는다. 따라서 즉시 함락 후보는 점수가 더 큰 비함락 후보보다 우선하지만, 같은 풀 안에서는 각 카드의 총효과 점수가 선택 확률을 정한다.

## 8. 총효과 점수 가중 추첨과 RNG

가중 풀에 양수 점수가 하나라도 있으면 각 양수 점수를 그대로 가중치로 사용하고 0 이하 점수는 가중치 0으로 둔다.

```text
weightOffset = 0
weight = max(score, 0)
```

가중 풀의 모든 점수가 0 이하라면 가장 낮은 점수가 1이 되도록 모든 점수에 같은 값을 더한다. 이 평행이동은 점수 차이와 순서를 보존하며 모든 후보에게 양의 정수 가중치를 준다.

```text
weightOffset = 1 - min(pool.score)
weight = score + weightOffset
```

예를 들어 점수가 `-1, -3, -2, -4`라면 `weightOffset = 5`, 가중치는 `4, 2, 3, 1`이다. 덜 나쁜 카드가 더 자주 선택되지만 어느 후보도 임의로 탈락하지 않는다. 현재 버전은 결정적 정수 RNG와 정확히 대응시키기 위해 총효과 점수가 IEEE-754 안전 범위의 정수일 것을 요구한다. 소수 점수가 필요한 콘텐츠는 정밀도 단위를 먼저 계약한 뒤 확장한다.

가중 풀 후보가 한 장이면 그 카드를 바로 선택하고 `draw.kind = "single"`을 기록하며 RNG를 소비하지 않는다. 후보가 둘 이상이면 점수가 다르더라도 항상 안정 손패 순서대로 가중 구간을 만들고 다음 호출을 수행한다.

```lua
runScript(triggerId, "deterministicRng", "nextInteger", state.rng, 1, totalWeight)
```

반환된 `rng` 전체를 새 상태에 저장한다. rejection sampling은 커서를 두 번 이상 전진시킬 수 있으므로 직접 `cursor + 1`로 계산하지 않는다. `receipt.weightOffset`, 후보별 `weight`, `draw.totalWeight`와 `draw.roll`을 비공개 영수증에 남겨 같은 상태와 시드에서 선택을 재검증한다.

엄격한 상태 검증은 `deterministicRng.nextInteger(rngBefore, 1, totalWeight)`를 실제로 다시 호출한다. 기록한 `draw.roll`과 반환 `rng` 전체가 각각 재생 결과와 정확히 같아야 한다. 단순히 cursor가 증가했는지만 확인하지 않는다.

`characterSelector.validateReceipt`는 `selectIntent`나 `stateSchema`를 호출하지 않고 `selectionContext`와 정적 카드 DB로 일반 카드·현재 무드·계획의 모든 충전을 `effectEngine`에서 다시 평가한다. 후보의 효과 합계, 점수, 예상 은폐, 치명 여부와 계획 충전 수가 재생 결과와 정확히 일치해야 한다. 따라서 `stateSchema → characterSelector.validateReceipt → effectEngine` 경로는 `characterSelector.selectIntent → stateSchema`와 런타임 순환을 만들지 않는다.

초기화 receipt가 상태에 저장된 뒤에는 권위 fingerprint가 `authorityFingerprint` 자기 필드만 제외하고 이 선택 영수증 전체를 포함한다. `selectionContext`, 후보 감사와 공개 태그 사건의 역산 payload를 서로 맞춰 함께 변조하더라도 fingerprint 경계에서 거부한다.

## 9. 공개 정보

선택 결과의 `characterIntent.cardInstanceIds`는 판정용 비공개 값이다. `publicActionTag`는 선택된 주 행동 카드의 `actionTag`와 정확히 같아야 한다.

플레이어에게는 `publicActionTag`만 공개한다. 카드 ID, 카드 이름, 규칙, 메커니즘, 점수, 후보 목록, 가중치, 난수 roll과 계획 여부는 `battleView`에 넣지 않는다. `action_tag_revealed` 사건을 처리하는 initializer도 이 비공개 경계를 유지해야 한다.

## 10. 현재 유지영 카드의 기준 점수

현재 무드 `ignore`와 기본 카드 정의에서 점수는 다음과 같다.

| 카드 | 점수 근거 | 총점 |
|---|---|---:|
| `close_collar` | `recover_resistance 3` | 3 |
| `quiet_warning` | `lose_stealth 2` | 2 |
| `turn_to_corner` | `recover_resistance 4` | 4 |
| `silent_glare` | 계획의 모든 충전에서 `lose_stealth 3` | 3 |

은폐가 충분하면 네 카드의 가중치는 `3, 2, 4, 3`, 총합은 12다. 따라서 선택 확률은 각각 `25%, 16.7%, 33.3%, 25%`이며 고정 시드가 실제 결과를 결정한다. 플레이어 은폐가 3이면 `silent_glare`만 치명 풀이 되므로 4점인 비함락 `turn_to_corner`보다 우선하고 RNG를 소비하지 않는다.

## 11. 검증 범위

`Tests/character-selector-check.ps1`은 다음을 두 개의 독립 Lua 프로세스에서 검사한다.

- 실제 정적 DB 로드와 계획 선택 가정 검증
- 현재 네 카드의 `3, 2, 4, 3` 점수
- 즉시 함락 우선과 모든 계획 충전 합산
- 전체 가중 풀과 양수 점수 그대로의 가중치, 최고점 필터 부재
- 모든 점수가 0 이하일 때의 평행이동과 덜 나쁜 카드의 가중치 우위
- 단일 후보·빈 손패의 RNG 미소비
- 안정 손패 순서와 고정 시드 가중 추첨
- roll만 바꾼 영수증과 과다 전진한 `rngAfter`의 결정적 재생 거부
- 후보 제거·순서 변경, 점수와 합계의 동반 변조, 계획 충전 수 변조의 실제 효과 재생 거부
- 입력 상태 불변성과 동일 입력의 전체 결과 결정성
- 캐릭터 연계, 지원하지 않는 효과 작업, 콜백 오류와 가정 불일치의 구조화 실패
- 선택 결과의 `stateSchema` 전체 참조 검증

이 검사는 로컬 Lua 호스트 기준이다. 실제 RisuAI 로어북 검색, 턴 initializer, `action_tag_revealed`, `main.lua` 훅과 UI 연결은 별도 통합 검증이 필요하다.
