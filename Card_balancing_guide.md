---
title: "HellTrain 카드 밸런싱 가이드"
document_id: "helltrain-card-balancing-guide"
schema_version: "1.1"
document_version: "0.2-agent"
language: "ko-KR"
status: "draft"
status_meaning: "현행 룰에 맞춘 초기 밸런스 가설이며 플레이테스트 데이터로 보정해야 함"
reviewed_at: "2026-08-01T01:08:00+09:00"
repository: "ChatPoongKun/HellTrain"
baseline_branch: "main"
baseline_commit: "08752b934d2ee65440fde9ca3fc818591b6592f4"
previous_baseline_commit: "6101215d002fb0fd40bb10a2bc3050e99225a08b"
reviewed_commits:
  - sha: "8434631f55667b9f9430c5a024583eb2ed64cfa4"
    change: "확정 무드에 따른 턴 종료 은폐 피해·회복"
    balance_impact: "major"
  - sha: "8912153c66557f20c3b269d1a4d212ca70545c8a"
    change: "승리 시에만 보상 제안, 보상 건너뛰기 허용"
    balance_impact: "progression"
  - sha: "08752b934d2ee65440fde9ca3fc818591b6592f4"
    change: "권위 전투 이력 및 상세 전투 로그"
    balance_impact: "telemetry_only"
source_of_truth:
  - "Design.txt"
  - "System/turnResolver.lua"
  - "System/characterSelector.lua"
  - "System/gameSetup.lua"
  - "System/runProgression.lua"
  - "System/subwayJourney.lua"
  - "System/battleHistory.lua"
scope:
  - "플레이어 카드"
  - "캐릭터 카드"
  - "연계"
  - "계획"
  - "간파"
  - "무드"
  - "행동 방해"
  - "승리 조건부 카드 보상"
excluded_evidence:
  - "기존 임시 테스트 카드의 수치"
  - "기존 임시 테스트 카드의 선택률"
  - "기존 임시 테스트 카드의 성능"
primary_unit: "BP"
---

# HellTrain 카드 밸런싱 가이드 — AI Agent Edition

## 0. 문서 목적

이 문서는 AI 에이전트가 HellTrain의 신규 카드를 생성·검토·수정할 때 사용할 공통 판단 기준이다.

이 문서는 다음 작업을 지원한다.

1. 카드 효과를 `BP(Balance Point)`로 환산한다.
2. 카드의 전투 내 총 기대가치를 계산한다.
3. 무드가 만드는 턴 종료 은폐 증감의 기대가치를 계산한다.
4. 행동 경제 우회, 선공 프리미엄, 런 스노볼 위험을 식별한다.
5. 과성능·무한 반복·죽은 카드 위험을 탐지한다.
6. 카드별 플레이테스트 가설과 필수 로그를 생성한다.

> **중요:** 기존 임시 테스트 카드의 수치와 성능은 어떠한 경우에도 밸런스 기준으로 사용하지 않는다.

---

## 1. 이번 개정의 결론

### 1.1 변경 필요 여부

`REQUIRED`: 가이드 수정이 필요하다.

| 변경 | 기존 가이드와의 충돌 | 수정 결과 |
|---|---|---|
| 확정 무드가 턴 종료마다 은폐를 직접 증감 | 기존 가이드는 무드를 주로 조건 조성 수단으로 평가했으며 고정 토큰·강제 변경 BP를 사용함 | 무드 가치를 남은 유효 턴의 은폐 증감 기대값으로 계산하도록 변경 |
| 승리한 세션만 카드 보상 제안 | 기존 가이드는 획득 맥락을 승패와 분리해 다룸 | 승리 조건부 획득, 생존자 편향, 런 스노볼 테스트 추가 |
| 보상 카드 선택 생략 가능 | 기존 선택률 기준이 반드시 1장을 고르는 전제에 가까움 | `skip`을 독립 선택지로 기록하고 보상 선택률 분모를 수정 |
| 패배 시 보상 RNG 미소비 | 승패가 런의 미래 제안 순서에도 영향을 줌 | 승리·패배 RNG 경로를 분리해 검증하도록 변경 |
| 상세 전투 로그 추가 | 전투 수치 자체는 바뀌지 않음 | BP 기준은 유지하고 필수 텔레메트리 수집 경로만 갱신 |

### 1.2 폐기된 휴리스틱

다음 v0.1 휴리스틱은 더 이상 사용하지 않는다.

```yaml
deprecated_heuristics:
  mood_token_1_bp: [0.5, 1.0]
  mood_token_2_bp: [1.5, 2.5]
  mood_token_3_bp: [3.0, 4.0]
  force_mood_bp: [2.5, 4.0]
```

폐기 이유:

- 무드 자체가 반복적인 은폐 피해·회복을 만든다.
- 현재 무드, 직전 턴 무드, 남은 유효 턴, 재변경 확률에 따라 가치가 크게 달라진다.
- 특히 연속 `거절`에서 `순응`으로 바꾸는 효과는 한 번의 턴 종료만 보아도 은폐 `8`의 차이를 만들 수 있다.

---

## 2. 규범 키워드와 판정 우선순위

| 키워드 | 의미 |
|---|---|
| `MUST` | 반드시 지켜야 한다. 위반 시 승인하지 않는다. |
| `MUST NOT` | 절대 허용하지 않는다. |
| `SHOULD` | 특별한 근거가 없으면 지킨다. |
| `SHOULD NOT` | 특별한 근거가 없으면 피한다. |
| `MAY` | 선택적으로 적용할 수 있다. |
| `FACT` | 현재 설계 문서 또는 구현에서 확인된 사실이다. |
| `HEURISTIC` | 현행 규칙에서 도출한 초기 가설이다. 데이터로 보정할 수 있다. |

판정 우선순위:

1. 현재 `main`의 런타임 구현
2. 현재 `main`의 `Design.txt`
3. 이 문서의 `FACT`
4. 이 문서의 `HEURISTIC`
5. 카드 제작자의 개별 판단

구현과 이 문서가 충돌하면 구현을 우선하고 문서를 개정한다.

---

## 3. 현행 규칙의 불변 조건

### 3.1 전투·자원

| ID | 구분 | 규칙 |
|---|---|---|
| `RULE-001` | FACT | 플레이어의 기본 시작 은폐는 `30`이다. 퍽 등에 따라 달라질 수 있다. |
| `RULE-002` | FACT | 캐릭터의 기본 저항은 `30`이다. 캐릭터에 따라 달라질 수 있다. |
| `RULE-003` | FACT | 세션 제한은 `7~12턴`의 균등 분포다. |
| `RULE-004` | FACT | 플레이어와 캐릭터의 기본 드로우는 `3장`이다. |
| `RULE-005` | FACT | 기본 최대 손패는 `5장`이다. |
| `RULE-006` | FACT | `baseDrawCount`와 `maxHandSize`는 서로 독립적이며 캐릭터 정의나 효과로 달라질 수 있다. |
| `RULE-007` | FACT | 턴 종료 시 미사용 손패를 버린다. |
| `RULE-008` | FACT | 이번 턴에 사용한 카드는 턴 종료 전까지 별도 사용 영역에 있어 같은 턴 재드로우되지 않는다. |
| `RULE-009` | FACT | 플레이어와 캐릭터의 기본 주 행동 횟수는 각각 `1회`다. |
| `RULE-010` | FACT | `연계` 카드는 주 행동을 소비하지 않는다. |
| `RULE-011` | FACT | 플레이어 카드가 캐릭터 카드보다 먼저 해결된다. |
| `RULE-012` | FACT | 카드와 사용 후 트리거가 끝날 때마다 승패를 확인한다. |
| `RULE-013` | FACT | 저항과 은폐가 같은 확인 시점에 `0 이하`이면 플레이어 승리를 우선한다. |
| `RULE-014` | FACT | 현재 은폐는 최종 카드 비용보다 커야 한다. 비용 지불로 은폐가 `0`이 되는 카드는 사용할 수 없다. |
| `RULE-015` | FACT | 은폐에는 명시적 최대치가 없다. |

### 3.2 계획

| ID | 구분 | 규칙 |
|---|---|---|
| `RULE-016` | FACT | 기본 계획 용량은 `1`, 구현 하드캡은 `16`이다. |
| `RULE-017` | FACT | 계획 슬롯이 가득 차면 가장 오래된 계획이 교체된다. |
| `RULE-018` | FACT | 계획은 발동 횟수, 지속 턴, 별도 폐기 조건 중 하나 이상을 가진다. |
| `RULE-019` | FACT | 자동 발동한 계획은 새 카드 사용으로 취급하지 않으며 다른 계획을 재귀적으로 발동시키지 않는다. |
| `RULE-020` | FACT | 계획 지속시간은 배치 다음 턴부터 턴 종료에 감소한다. |
| `RULE-021` | FACT | 한 번 발동해 공개된 계획은 활성 목록에서 벗어날 때까지 공개 상태를 유지한다. |

### 3.3 무드

| ID | 구분 | 규칙 |
|---|---|---|
| `RULE-022` | FACT | 무드는 `거절/의심/무시/혼란/순응`의 5단계다. |
| `RULE-023` | FACT | 기본 시작 무드는 `무시`이며 캐릭터 설정·특징으로 바뀔 수 있다. |
| `RULE-024` | FACT | 무드 토큰은 턴 사이에 누적되고 턴 종료에 한 번 평가된다. |
| `RULE-025` | FACT | 단독 최다 토큰이 `3개 이상`이면 해당 무드로 변경하고 해당 토큰을 0으로 만든다. |
| `RULE-026` | FACT | 3개 이상인 공동 최다 무드가 둘 이상이면 각 토큰을 1개씩 줄이고 무드는 유지한다. |
| `RULE-027` | FACT | `force_mood`가 정확히 1회면 적용된다. 2회 이상이면 모두 상쇄되고 일반 토큰 평가를 수행한다. |
| `RULE-028` | FACT | 무드 변경은 효과 발생 즉시가 아니라 턴 종료의 단일 무드 판정에서 처리한다. |
| `RULE-029` | FACT | 무드 판정 뒤 전투가 계속되면 확정 무드에 따라 플레이어 은폐를 증감하고 즉시 승패를 확인한다. |
| `RULE-030` | FACT | `의심`: 은폐 피해 1. 직전 턴 최종 무드도 의심이면 피해 2. |
| `RULE-031` | FACT | `거절`: 은폐 피해 3. 직전 턴 최종 무드도 거절이면 피해 6. |
| `RULE-032` | FACT | `무시`: 은폐 변화 없음. |
| `RULE-033` | FACT | `혼란`: 은폐 회복 1. 연속 유지 보너스 없음. |
| `RULE-034` | FACT | `순응`: 은폐 회복 2. 연속 유지 보너스 없음. |
| `RULE-035` | FACT | 첫 턴의 의심·거절은 연속 상태로 보지 않는다. 같은 부정 무드가 3턴 이상 이어져도 2배를 초과해 증가하지 않는다. |
| `RULE-036` | FACT | 카드 체크포인트, 턴 종료 트리거, 제한 턴 규칙으로 이미 승패가 확정됐으면 무드 은폐 효과를 적용하지 않는다. |
| `RULE-037` | FACT | 마지막 허용 턴에 카드와 사용 후 트리거 뒤 승리하지 못하면 턴 종료 트리거와 무드 판정 전에 패배한다. |

### 3.4 덱과 보상

| ID | 구분 | 규칙 |
|---|---|---|
| `RULE-038` | FACT | 초기 덱은 10장, 최소 10장, 알파 최대 20장이다. |
| `RULE-039` | FACT | 동일 카드는 최대 2장까지 보유할 수 있다. |
| `RULE-040` | FACT | 현재 v1에서는 승리한 세션만 카드 보상을 제안한다. |
| `RULE-041` | FACT | 보상은 보유량이 2장 미만인 플레이어 카드 중 최대 3장이다. |
| `RULE-042` | FACT | 플레이어는 승리 보상 카드를 선택하지 않고 현재 덱을 유지할 수 있다. |
| `RULE-043` | FACT | 패배한 세션은 보상 제안과 보상 RNG 처리를 생략한다. |
| `RULE-044` | FACT | 덱이 20장이거나 적격 카드가 없으면 카드 없이 계속한다. |

---

## 4. 핵심 설계 원칙

### 4.1 카드 역할

각 카드는 다음 역할 중 **주 역할을 정확히 1개** 가져야 한다.

- `attack`: 저항 감소
- `survival`: 은폐 보존·회복
- `search`: 드로우·탐색
- `mood_setup`: 무드 토큰·무드 전환
- `plan`: 지연·반응형 효과
- `control`: 행동 스킵·계획 억제

보조 역할은 허용하지만 한 카드가 공격·생존·탐색·통제를 동시에 해결해서는 안 된다.

### 4.2 기본 결론

- 일반 주 행동 1회의 기준 가치는 `4~6 BP`다. `HEURISTIC`
- 직접 피해는 선공과 중간 승패 판정 때문에 같은 수치의 회복·유틸리티보다 강하다.
- 은폐는 생명력·카드 비용·패배 조건을 겸하므로 일반 마나처럼 취급하지 않는다.
- 무드는 이제 카드 조건만이 아니라 반복 자원 엔진이다.
- 연계, 드로우, 행동 스킵, 반복 계획은 행동 경제를 우회하므로 보수적으로 평가한다.
- 승리 조건부 보상은 강한 덱이 더 빠르게 성장하는 런 스노볼을 만들 수 있다.
- 카드 단위 검토 후 반드시 전투 단위와 런 단위 테스트를 수행한다.

---

## 5. BP 정의와 기본 계산식

### 5.1 BP 정의

```text
저항 피해 1 = 1.0 BP
```

BP는 절대값이 아니라 카드 간 일관성을 확보하고 검토 이유를 설명하기 위한 내부 단위다.

### 5.2 세션 진행 속도

```text
required_net_damage_per_turn = character_starting_resistance / session_turns
```

기본 저항 30 기준:

| 세션 길이 | 최소 평균 순저항 피해/턴 |
|---:|---:|
| 7 | 4.29 |
| 9.5 | 3.16 |
| 12 | 2.50 |

### 5.3 조건부 효과 기대값

```text
conditional_ev_bp = effect_bp * trigger_probability
```

### 5.4 계획·지속 효과 기대값

```text
persistent_ev_bp = effect_bp_per_trigger
                 * expected_trigger_count
                 * trigger_probability
```

### 5.5 카드 총 기대가치

```text
raw_bp = immediate_bp
       + conditional_ev_bp
       + persistent_ev_bp
       + mood_ev_bp

adjusted_bp = raw_bp
            + real_cost_credit_bp
            + real_delay_credit_bp
            + real_exhaust_credit_bp
            - first_mover_premium_bp
            - action_economy_premium_bp
            - deck_compression_value_bp
            - run_snowball_premium_bp
```

`run_snowball_premium_bp`는 전투 내 효과를 직접 줄이는 값이 아니다. 승리율을 크게 높여 보상 접근 빈도까지 증가시키는 카드에 부여하는 **런 평가 보정값**이다. 전투 BP와 런 영향 점수를 별도 표시하는 것이 바람직하다.

---

## 6. 카드 유형별 초기 예산

| 카드 유형 | 권장 총 기대가치 | 요구 조건 |
|---|---:|---|
| 일반 주 행동 | `4~6 BP` | 비용 0~1, 넓은 조건, 반복 가능 |
| 강한 주 행동 | `6~8 BP` | 비용 2~5, 좁은 조건, 지연 등 명확한 기회비용 |
| 제거·세션 제한 카드 | `7~10 BP` | 재사용 불가가 실제 단점일 때 |
| 연계 카드 | `0.5~2 BP` | 주 행동 미소모 가치 포함 |
| 계획 카드 | `총 기대 5~8 BP` | 모든 충전과 발동 확률 합산 |
| 다중 턴 준비 보상 | `8~12 BP` | 2턴 이상 준비, 7턴 세션 사장률 검증 |

승인 규칙:

- `MUST`: 일반 주 행동이 `6 BP`를 넘으면 실제 비용·조건·지연 중 하나 이상을 명시한다.
- `MUST`: `8 BP`를 넘는 카드는 반복 가능성, 선공 가치, 덱 순환, 무드 엔진 가치를 별도 검토한다.
- `MUST NOT`: 준비 없이 반복 가능한 카드가 `10 BP` 이상을 제공해서는 안 된다.
- `MUST NOT`: 카드 1장 또는 쉽게 반복되는 조합이 한 턴에 저항 30을 제거해서는 안 된다.

---

## 7. 효과별 초기 환산

| 효과 | 초기 환산 | 적용 규칙 |
|---|---:|---|
| 저항 피해 1 | `1.0 BP` | 치명 구간은 선공 프리미엄 추가 |
| 은폐 회복 1 | `0.8~1.0 BP` | 상한 부재와 미래 비용 지불 능력 반영 |
| 외부 은폐 피해 1 | `0.8~1.0 BP` | 저은폐·치명 구간은 1.0 이상으로 평가 가능 |
| 은폐 비용 1 | `+0.8~1.2 BP` 허용 | 실제 사용 제한으로 작동할 때만 |
| 드로우 1 | `1.2~1.8 BP` | 작은 덱, 같은 턴 사용, 탐색 반영 |
| 간파 | `0.5~1.5 BP` | 보호하는 카드가 클수록 상승 |
| 캐릭터 행동 스킵 | `3.5~5.5 BP` | 선택된 행동 전체를 제거 |
| 1턴 지연 | 효과 예산 `+15~25%` | 지연이 실제 실패 위험일 때만 |
| 제거 | 강한 카드에 `+30~50%` | 제거가 실질적 단점일 때만 |
| 무드 토큰·강제 변경 | 고정값 사용 금지 | §11의 상태 기반 기대값 사용 |

### 7.1 직접 피해 상한

| 상황 | 한 턴 총 저항 피해 권장 상한 |
|---|---:|
| 준비 없는 일반 턴 | `6~8` |
| 정상적인 강한 턴 | `8~10` |
| 사전 준비 보상 턴 | `11~14` |
| 첫 턴 또는 쉽게 반복 가능한 조합 | `<10` |
| 한 턴 30 피해 | `MUST NOT` |

직접 피해가 높은 카드에는 다음을 적용한다.

- `MUST`: 선공으로 캐릭터 행동이 취소될 확률을 기록한다.
- `MUST`: 피니시 성공 횟수를 별도 로그로 남긴다.
- `SHOULD NOT`: 큰 피해와 행동 스킵·강제 무드 변경·대량 회복을 동시에 제공한다.

---

## 8. 은폐 비용과 회복

### 8.1 은폐 비용 등급

| 최종 비용 | 해석 | 권장 용도 |
|---:|---|---|
| 0 | 기본 | 낮은 효율, 유틸리티, 조건 카드 |
| 1 | 가벼운 부담 | 일반 공격, 소규모 복합 효과 |
| 2~3 | 강한 비용 | 명확한 고효율 또는 안정성 |
| 4~5 | 고위험 | 큰 공격, 강한 통제, 피니시 보조 |
| 6 이상 | 세션 결정급 | 제거, 세션 제한, 매우 좁은 조건 필요 |

### 8.2 비용 판정 규칙

- `MUST`: 비용 지불 후 미래 카드 사용 가능성이 얼마나 감소하는지 평가한다.
- `MUST`: 무드 회복으로 비용을 상쇄할 수 있다면 실제 순비용으로 평가한다.
- `MUST`: 비용 감소 효과가 있다면 최종 비용 분포를 기준으로 평가한다.
- `MUST NOT`: 비용 3을 단순히 피해 +3과 교환하지 않는다.

### 8.3 회복 판정 규칙

- 회복 `1`: 작은 부가 효과
- 회복 `2`: 유의미한 부가 효과
- 회복 `3`: 주 행동의 주요 효과
- 회복 `4~5`: 조건 또는 큰 기회비용 필요
- 회복 `6+`: 제거·계획·희귀 조건 필요

다음 조합은 승인 전 특별 검토 대상이다.

- 연계 + 자기 대체 드로우 + 은폐 순증가
- 비용보다 회복량이 크면서 직접 피해도 주는 반복 카드
- 조건 없이 매 턴 은폐 4 이상 회복
- `순응` 유지와 결합해 매 턴 총 은폐 회복이 4 이상인 반복 구조
- 반복 계획을 통한 대량 은폐 회복

---

## 9. 연계와 드로우

### 9.1 연계

- `MUST`: 총 기대가치를 `0.5~2 BP`에서 시작한다.
- `SHOULD`: 직접 저항 피해는 `0~1`로 제한한다.
- `MUST NOT`: 직접 저항 피해가 `2`를 초과해서는 안 된다.
- `SHOULD`: 한 턴 연계 카드들의 직접 피해 합계는 `3 이하`로 설계한다.
- `MUST`: 드로우가 붙으면 자기 대체와 덱 압축 가치를 추가 계산한다.
- `MUST NOT`: 반복 가능한 행동 스킵을 연계에 부여하지 않는다.
- `SHOULD NOT`: 연계 한 장이 큰 피해, 대량 회복, 강제 무드 변경 중 둘 이상을 제공하지 않는다.

### 9.2 드로우

10장 덱에서 기본 3장 드로우:

```text
P(특정 1장 보유) = 30%
P(동일 카드 2장 중 1장 이상 보유) ≈ 53.3%
P(서로 다른 특정 2장 동시 보유) ≈ 6.7%
```

- `MUST`: 같은 턴 사용 가능성을 포함해 평가한다.
- `MUST`: 사용 카드 영역 때문에 이번 턴 사용 카드가 같은 턴 재드로우되지 않는다는 규칙을 시뮬레이션에 반영한다.
- `MUST`: `baseDrawCount`와 `maxHandSize`가 3/5가 아닌 캐릭터·효과 조합을 별도 테스트한다.
- `MUST`: 자기 대체 여부를 기록한다.
- `MUST`: 덱 크기 10과 20에서 각각 순환 속도를 테스트한다.
- `SHOULD`: 반복 가능한 드로우 2 이상에는 높은 비용·제거·지연 중 하나를 부여한다.

---

## 10. 계획·간파·제거

### 10.1 계획

```text
plan_ev_bp = trigger_probability
           * expected_trigger_count
           * effect_bp_per_trigger
```

| 계획 유형 | 권장 총 기대가치 |
|---|---:|
| 거의 확정 1회 | `5~6 BP` |
| 보통 조건 1회 | `6~7 BP` |
| 좁은 조건 1회 | `7~8 BP` |
| 2회 이상 | 회당 `2~4 BP`, 총합 `8 BP 이하` |
| 반복 유지형 | 턴당 `1~2 BP` |

- `MUST`: 7, 9.5, 12턴에서 예상 발동 횟수를 각각 계산한다.
- `MUST`: 무드 기반 계획은 카드 효과뿐 아니라 유발한 무드 은폐 틱까지 포함한다.
- `MUST`: 미발동률, 교체율, 공개 시점, 실제 충전 소모를 기록한다.
- `MUST`: 계획 용량 1, 2, 4 환경을 별도 테스트한다.
- `MUST NOT`: 반복 행동 스킵 계획을 허용하지 않는다.
- `MUST`: 계획이 다른 계획을 재귀적으로 발동시키지 않는 현재 규칙을 시뮬레이션에 반영한다.

### 10.2 간파

- `MUST`: 간파 가치를 보호하는 카드 효과 크기에 비례해 평가한다.
- `SHOULD NOT`: 최고 피해 카드에 간파를 무료 부가 효과로 제공한다.
- `MUST`: 큰 공격 + 간파 조합은 피해, 비용, 반복성 중 하나를 낮춘다.

### 10.3 제거

- `MUST`: 제거 전후 덱 평균 품질을 비교한다.
- `MUST`: 제거 후 강한 카드 재등장 확률 변화를 계산한다.
- `MUST NOT`: `remove` 키워드만으로 자동 보너스를 지급하지 않는다.
- `SHOULD`: 강한 제거 카드에는 일반 카드보다 `30~50%` 높은 총가치를 허용할 수 있다.
- `SHOULD`: 약한 연계·드로우 카드의 제거는 장점으로 평가한다.

---

## 11. 무드 가치 모델

### 11.1 턴 종료 무드 은폐 변화

플레이어 관점의 은폐 변화 `ΔS`:

| 확정 무드 | 첫/비연속 틱 | 연속 틱 | 플레이어 관점 |
|---|---:|---:|---|
| 거절 | `-3` | `-6` | 매우 불리 |
| 의심 | `-1` | `-2` | 불리 |
| 무시 | `0` | `0` | 중립 |
| 혼란 | `+1` | `+1` | 유리 |
| 순응 | `+2` | `+2` | 매우 유리 |

### 11.2 유효 무드 틱 수

마지막 허용 턴에 승리하지 못하면 무드 판정 전에 제한 턴 패배가 확정된다.

따라서 전투가 끝까지 지속되는 단순 상한은 다음과 같다.

```text
max_eligible_mood_ticks = max(0, turn_limit - 1)
```

실제 기대 틱 수는 조기 승리·패배와 무드 재변경 확률을 반영해야 한다.

```text
expected_mood_ticks = Σ P(battle_active_at_turn_end_t)
                        * P(target_mood_active_at_t)
```

### 11.3 무드 틱 BP

```text
mood_tick_bp = stealth_delta
             * stealth_point_bp
```

권장 `stealth_point_bp`:

```yaml
normal_state: [0.8, 1.0]
low_stealth_or_lethal_state: [1.0, 1.25]
```

캐릭터 카드 관점에서는 플레이어 은폐 피해가 양의 가치이고 회복이 음의 가치다.

### 11.4 무드 전환 기대값

```text
mood_transition_ev_bp = Σ_t P(battle_active_at_turn_end_t)
                          * P(new_mood_persists_at_t)
                          * (new_mood_tick_bp_t - old_mood_tick_bp_t)
                        + conditional_card_bonus_ev_bp
```

예시:

```text
연속 거절 -> 순응
이번 틱 은폐 차이 = (+2) - (-6) = +8
즉시 1틱 가치만 약 6.4~10 BP
```

이 값은 이후 턴 지속 가치와 카드의 무드 조건부 효과를 포함하지 않은 값이다.

### 11.5 토큰 가치

토큰 1개의 고정 BP는 사용하지 않는다.

```text
mood_token_ev_bp = ΔP(target_mood_at_each_eligible_tick)
                 * mood_transition_ev_per_tick
```

평가 절차:

1. 토큰 추가 전 무드별 토큰 분포를 기록한다.
2. 토큰 추가 후 단독 최다·공동 최다·3개 임계 도달 확률을 계산한다.
3. 목표 무드가 적용될 각 유효 틱의 확률 변화를 계산한다.
4. 해당 무드의 은폐 틱과 카드 조건부 효과를 합산한다.
5. 반대 무드 토큰 동률 해소 또는 지연 가치도 포함한다.

보조 휴리스틱:

- 임계에 도달하지 않는 초기 토큰은 보통 작은 준비 가치만 가진다.
- 세 번째 토큰 또는 단독 최다를 만드는 토큰은 한 번의 무드 틱보다 클 수 있다.
- 연속 거절·의심을 끊는 토큰은 피해 방지 가치가 추가된다.
- 순응·혼란을 유지시키는 토큰은 반복 회복 가치가 추가된다.

### 11.6 강제 무드 변경

- `MUST`: 고정 `2.5~4 BP`를 사용하지 않는다.
- `MUST`: 현재 무드, 직전 무드, 남은 유효 틱, 재변경 확률을 입력으로 계산한다.
- `MUST`: 강제 변경이 2회 이상이면 상쇄된다는 규칙을 조합 테스트에 반영한다.
- `MUST NOT`: 상쇄 가능성만을 충분한 페널티로 간주하지 않는다.
- `SHOULD NOT`: 큰 직접 피해와 큰 긍정 무드 전환을 같은 카드에 제공한다.
- `SHOULD NOT`: 캐릭터 카드가 큰 은폐 피해와 `거절` 강제 변경을 동시에 반복 제공한다.

### 11.7 무드 카드 승인 기준

- `PASS`: 무드 전환 EV를 포함한 조정 BP가 카드 유형 범위 안에 있다.
- `REVISE`: 긍정 무드 유지로 반복 회복이 과도하거나 부정 무드 연속 피해가 카드 비용 없이 고착된다.
- `REJECT`: 반복 가능한 카드가 상대의 무드 회복 수단 없이 연속 거절을 사실상 고정하거나, 무드 전환만으로 세션의 자원 압박을 무효화한다.

---

## 12. 행동 통제

### 12.1 캐릭터 행동 스킵

| 항목 | 기준 |
|---|---|
| 기본 가치 | `3.5~5.5 BP` |
| 직접 피해 병행 | `2~3 이하` 권장 |
| 반복 가능 | `MUST NOT` |
| 연계 부여 | `MUST NOT` |
| 반복 계획 부여 | `MUST NOT` |
| 필수 제약 | 제거, 높은 은폐 비용, 특정 무드 조건 중 하나 이상 |

추가 규칙:

- `MUST`: 취소된 캐릭터 카드의 AI 점수를 기록한다.
- `MUST`: 스킵이 치명 피해와 부정 무드 유발을 동시에 막았는지 기록한다.
- `SHOULD NOT`: 큰 피해와 행동 스킵을 동시에 제공한다.

---

## 13. 캐릭터 카드 밸런싱

### 13.1 AI 기본 점수식

```text
ai_score = resistance_recovery
         + player_stealth_damage
         - self_resistance_damage
         - player_stealth_recovery
```

현재 AI는 치명 피해 후보를 우선한다.

### 13.2 캐릭터 카드 예산

| 카드 등급 | 권장 AI 총효과 점수 |
|---|---:|
| 일반 행동 | `3~5` |
| 강한 행동 | `5~6` |
| 위험 행동 | `6~7` |
| 7 초과 | 원칙적으로 제한 |

| 효과 | 권장 범위 |
|---|---:|
| 반복 은폐 피해 | `2~4` |
| 강한 은폐 피해 | `5~6` |
| 은폐 피해 7+ | 계획·세션 제한·긴 준비 필요 |
| 반복 저항 회복 | `3~4` |
| 일반 캐릭터 평균 회복 | 턴당 `0.5~1.5` |
| 방어형 평균 회복 | 턴당 `1.5~2.5` |
| 극단적 방어형 | 턴당 `3 미만` 권장 |

### 13.3 무드가 있는 캐릭터 카드

현재 AI 기본 점수식은 미래 무드 틱의 기대값을 자동으로 완전히 반영하지 못할 수 있다.

- `MUST`: `add_mood_token`·`force_mood`가 있는 캐릭터 카드에는 별도의 무드 EV를 계산한다.
- `MUST`: 해당 무드 EV를 AI 선택 점수에 반영하거나 카드별 보정치를 둔다.
- `MUST`: `거절`·`의심` 유발 카드의 연속 틱 기대 피해를 AI 점수와 밸런스 평가에 포함한다.
- `MUST`: `혼란`·`순응` 상태에서 캐릭터 카드 선택이 비합리적으로 되는지 검증한다.
- `SHOULD`: 높은 직접 은폐 피해와 연속 거절 유도를 같은 반복 카드에 결합하지 않는다.

### 13.4 신규 효과 규칙

- `MUST`: 신규 캐릭터 효과를 추가할 때 AI 점수 규칙도 함께 정의한다.
- `MUST`: AI가 해석하지 못하는 효과는 카드별 보정 또는 전용 점수 함수를 가진다.
- `MUST`: 사용 가능 조건이 선택기에서 지원되는지 확인한다.
- `MUST`: 저은폐 구간에서 특정 카드가 사실상 확정 선택이 되는지 테스트한다.

---

## 14. 조건부 효과 가격 책정

| 실제 발동률 | 허용 가능한 추가 가치 |
|---:|---:|
| 80% 이상 | `0~10%` |
| 60~80% | `10~20%` |
| 40~60% | `20~35%` |
| 20~40% | `35~50%` |
| 20% 미만 | 큰 보너스 가능, 죽은 카드 위험 우선 검토 |

- `MUST`: 조건 보너스는 실제 발동률로 계산한다.
- `MUST`: 무드 조건은 무드 틱 EV와 중복 계산하지 않도록 분리한다.
- `MUST NOT`: 문장이 길거나 복잡하다는 이유로 보너스를 지급하지 않는다.
- `MUST`: 플레이어가 직접 조성할 수 있는 조건은 발동률을 높게 추정한다.
- `SHOULD NOT`: 특정 카드 ID 두 장 이상을 동시에 요구하는 조건을 기본 시너지로 사용한다.

---

## 15. 승리 조건부 보상과 런 밸런스

### 15.1 현행 보상 흐름

```text
승리 -> 최대 3장 보상 제안 -> 1장 선택 또는 건너뛰기 -> 다음 상대
패배 -> 보상 제안 없음 -> 보상 RNG 미소비 -> 다음 상대
```

### 15.2 전투 BP와 런 가치를 분리

승리 보상 변경은 카드 1회의 전투 BP를 직접 바꾸지 않는다. 그러나 승률이 높은 카드가 다음 세션의 덱 성장 기회까지 늘리므로 런 전체 가치가 비선형적으로 증가할 수 있다.

```text
run_value = combat_value
          + P(victory_added_by_card)
          * expected_reward_value
          * expected_remaining_sessions
```

- `MUST`: 전투 BP와 런 성장 기여도를 별도 필드로 출력한다.
- `MUST`: 승률 상승이 보상 접근 횟수를 얼마나 늘렸는지 계산한다.
- `MUST`: 패배 세션을 보상 선택률 분모에 포함하지 않는다.
- `MUST`: 보상 제안에서 `skip`을 독립 선택지로 기록한다.
- `MUST`: 패배 시 보상 RNG를 소비하지 않으므로 승패별 RNG 경로를 동일 경로로 가정하지 않는다.

### 15.3 선택률 정의

```text
initial_draft_pick_rate = initial_draft_picks / initial_draft_offers
reward_pick_rate = reward_card_picks / reward_card_offers_in_victorious_sessions
reward_skip_rate = reward_skips / reward_offers_in_victorious_sessions
```

카드가 보상으로 제안되지 않은 패배 세션은 `reward_pick_rate`와 `reward_skip_rate`의 분모에서 제외한다.

### 15.4 런 스노볼 위험

다음 상황은 `RISK-020`을 부여한다.

- 특정 카드 보유가 승률을 크게 올린다.
- 증가한 승률로 보상 접근 횟수도 늘어난다.
- 보상에서 해당 카드의 시너지 카드가 높은 빈도로 선택된다.
- 이후 세션 승률이 다시 상승한다.

검증 지표:

```yaml
run_progression_metrics:
  expected_rewards_after_3_sessions: 0.0
  expected_rewards_after_5_sessions: 0.0
  reward_skip_rate: 0.0
  victory_conditioned_pick_rate: 0.0
  win_rate_before_acquisition: 0.0
  win_rate_after_acquisition: 0.0
  snowball_slope_per_reward: 0.0
```

---

## 16. 위험 플래그

| 플래그 ID | 탐지 조건 | 기본 조치 |
|---|---|---|
| `RISK-001` | 비용 0~1 반복 카드가 7 BP 이상 | 수치 하향 또는 실제 제약 추가 |
| `RISK-002` | 연계 카드 직접 피해가 2 이상 | 피해 하향 |
| `RISK-003` | 연계 + 자기 대체 드로우 + 추가 이득 | 추가 이득 제거 또는 비용·제거 부여 |
| `RISK-004` | 한 카드가 큰 피해와 대량 회복 동시 제공 | 역할 분리 |
| `RISK-005` | 강제 긍정 무드 변경 + 큰 피해 | 비용·제거·좁은 조건 추가 |
| `RISK-006` | 행동 스킵 + 큰 피해 | 피해 2~3 이하로 축소 |
| `RISK-007` | 쉽게 가능한 한 턴 10 피해 이상 | 반복성·선공 가치 재검토 |
| `RISK-008` | 계획 1장 총 기대값이 8 BP 초과 | 충전·발동률·효과 하향 |
| `RISK-009` | 캐릭터 반복 회복 5 이상 | 회복 하향 또는 선택률 제한 |
| `RISK-010` | 캐릭터 반복 은폐 피해 6 이상 | 계획·제한·준비 추가 |
| `RISK-011` | 대부분 상황에서 동일 카드가 최선 | 범용성 또는 효율 하향 |
| `RISK-012` | 단점을 플레이 순서로 쉽게 회피 가능 | 실질적 제약으로 교체 |
| `RISK-013` | 제거 후 덱 평균 품질이 크게 상승 | 제거를 장점으로 재계산 |
| `RISK-014` | 7턴 세션에서 효과가 거의 발동하지 않음 | 즉시 효과·미발동 보상·조건 재설계 |
| `RISK-015` | AI가 카드 효과를 점수화하지 못함 | 점수 함수 구현 전 승인 보류 |
| `RISK-016` | 은폐 순증가와 반복 드로우 결합 | 무한·준무한 루프 검사 |
| `RISK-017` | 카드가 핵심 역할 3개 이상 해결 | 역할 분리 |
| `RISK-018` | 무드 전환 1회 기대 스윙이 5 BP 이상이며 다른 강효과도 가짐 | 무드·부가 효과 중 하나 축소 |
| `RISK-019` | 반복 카드가 연속 거절·의심을 상대 대응 없이 고착 | 조건·지속·충전 제한 추가 |
| `RISK-020` | 승률 상승과 보상 접근 증가가 결합해 런 스노볼 발생 | 전투 수치·획득 빈도·복사 제한 중 하나 조정 |

자동 승인 거부:

```yaml
auto_reject_flags:
  - RISK-016
```

다음은 조건부 자동 거부다.

```yaml
conditional_auto_reject:
  RISK-002: "연계 직접 피해가 2를 초과"
  RISK-006: "스킵이 반복 가능하거나 실질적 제약이 없음"
  RISK-019: "상대에게 현실적인 무드 회복·전환 수단이 없음"
```

---

## 17. AI 에이전트용 카드 입력 스키마

```yaml
card:
  id: "snake_case_unique_id"
  name: "카드명"
  owner: "player | character"
  card_type: "main | chain | plan"
  action_tag: "required_single_tag"
  mechanics:
    chain: false
    plan: false
    insight: false
    remove: false
  primary_role: "attack | survival | search | mood_setup | plan | control"
  secondary_roles: []
  stealth_cost: 0
  effects:
    immediate: []
    conditional: []
    persistent: []
    mood: []
  conditions: []
  expected_trigger_probability: 1.0
  expected_trigger_count:
    turns_7: 1.0
    turns_9_5: 1.0
    turns_12: 1.0
  mood_context:
    current_mood: "ignore"
    previous_final_mood: null
    tokens_before: {}
    expected_persistence_turns: 0.0
  intended_weakness: "플레이어가 쉽게 회피할 수 없는 실제 제약"
  intended_deck: "attack | survival | plan | mood | mixed"
  design_goal: "이 카드가 만드는 의사결정"
```

효과 예시:

```yaml
- op: "damage_resistance"
  amount: 4
  target: "character"

- op: "recover_stealth"
  amount: 2
  target: "player"

- op: "draw"
  amount: 1

- op: "add_mood_token"
  mood: "confusion"
  amount: 1

- op: "force_mood"
  mood: "compliance"

- op: "skip_character_action"
  amount: 1
```

---

## 18. AI 에이전트 평가 절차

### Step 1. 입력 검증

1. 카드 ID가 고유한지 확인한다.
2. 행동 태그가 정확히 1개인지 확인한다.
3. 주 역할이 정확히 1개인지 확인한다.
4. 카드 유형과 메커니즘 플래그가 모순되지 않는지 확인한다.
5. 모든 효과가 현재 엔진 명령으로 표현 가능한지 확인한다.

### Step 2. 기본 BP 계산

1. 즉시 효과를 BP로 환산한다.
2. 조건부 효과에 발동률을 곱한다.
3. 계획·지속 효과에 예상 발동 횟수를 곱한다.
4. 무드 토큰·강제 변경은 §11의 상태 기반 기대값을 사용한다.
5. 비용·지연·제거가 실질적 약점인지 확인한다.
6. 선공·행동 경제·덱 압축 프리미엄을 차감한다.

### Step 3. 세션 길이별 계산

```yaml
session_ev:
  turns_7: 0.0
  turns_9_5: 0.0
  turns_12: 0.0
```

각 길이에서 마지막 허용 턴의 무드 틱이 발생하지 않는 기본 경로를 반영한다.

### Step 4. 무드 상태별 계산

최소 다음 상태를 평가한다.

```yaml
mood_scenarios:
  - current: rejection
    previous_same: true
  - current: rejection
    previous_same: false
  - current: suspicion
    previous_same: true
  - current: suspicion
    previous_same: false
  - current: ignore
  - current: confusion
  - current: compliance
```

### Step 5. 조합 위험 분석

- 동일 카드 2장 보유
- 덱 크기 10·20
- 연계 카드 0~3장 동시 사용
- 계획 용량 1·2·4
- 기본 드로우/손패 3/5 이외 조합
- 은폐가 낮은 상태와 높은 상태
- 각 무드와 연속 부정 무드 상태
- 7턴과 12턴 세션
- 공격형·방어형·계획형·통제형 캐릭터

### Step 6. 런 진행 분석

- 카드가 승률에 주는 변화
- 증가한 승률로 얻는 추가 보상 횟수
- 보상 제안 시 선택·건너뛰기 비율
- 3·5세션 뒤 덱 성장 속도
- 승패별 보상 RNG 경로

### Step 7. 위험 플래그와 판정

```text
PASS:
- 자동 거부 플래그 없음
- 권장 BP 범위 충족
- 실제 제약 존재
- 7턴 세션에서도 의미 있음
- 구현 가능한 효과만 사용
- 무드·런 기대값이 허용 범위

REVISE:
- 수치·조건·획득 빈도 조정으로 해결 가능

HOLD:
- 미확정 규칙 또는 AI 점수 미지원에 의존

REJECT:
- 무한/준무한 루프
- 행동 경제 구조적 무효화
- 상대 대응 없는 연속 부정 무드 고착
- 한 장이 여러 핵심 역할 동시 해결
- 구현 또는 AI 평가 불가능
```

---

## 19. AI 에이전트 출력 스키마

```yaml
review:
  card_id: "example_id"
  verdict: "PASS | REVISE | HOLD | REJECT"
  confidence: 0.0
  baseline_commit: "08752b934d2ee65440fde9ca3fc818591b6592f4"
  primary_role_valid: true
  implementation_compatible: true
  bp:
    immediate: 0.0
    conditional_ev: 0.0
    persistent_ev:
      turns_7: 0.0
      turns_9_5: 0.0
      turns_12: 0.0
    mood_ev:
      turns_7: 0.0
      turns_9_5: 0.0
      turns_12: 0.0
    raw_total:
      turns_7: 0.0
      turns_9_5: 0.0
      turns_12: 0.0
    adjusted_total:
      turns_7: 0.0
      turns_9_5: 0.0
      turns_12: 0.0
  premiums:
    first_mover: 0.0
    action_economy: 0.0
    deck_compression: 0.0
  run_impact:
    win_rate_delta: 0.0
    expected_extra_rewards_5_sessions: 0.0
    snowball_risk: "low | medium | high"
  risk_flags: []
  rule_violations: []
  required_changes: []
  test_hypotheses: []
  required_logs: []
  summary: "한 문단 요약"
```

출력 규칙:

- `MUST`: 수치 제안에는 근거 BP를 함께 제공한다.
- `MUST`: 무드 카드에는 무드 EV를 별도 표시한다.
- `MUST`: `REVISE`는 수정 전·후 값을 제시한다.
- `MUST`: `REJECT`는 위반 규칙 또는 위험 플래그를 명시한다.
- `MUST NOT`: 기존 임시 카드와의 비교를 근거로 사용하지 않는다.
- `SHOULD`: 불확실한 발동률과 지속 확률은 범위로 표시한다.

---

## 20. 카드 제작 템플릿

```markdown
### 카드 개요

- ID:
- 이름:
- 소유자: player / character
- 유형: main / chain / plan
- 행동 태그:
- 주 역할:
- 보조 역할:
- 은폐 비용:
- 메커니즘: chain / plan / insight / remove

### 효과

- 기본 효과:
- 조건부 효과:
- 지속/계획 효과:
- 무드 효과:
- 예상 발동률:
- 예상 발동 횟수(7 / 9.5 / 12턴):

### BP 산정

- 즉시 BP:
- 조건부 기대 BP:
- 지속 기대 BP:
- 무드 기대 BP:
- 비용 보상:
- 지연 보상:
- 제거 보상:
- 선공 프리미엄 차감:
- 행동 경제 프리미엄 차감:
- 덱 압축 가치 차감:
- 조정 총 BP(7 / 9.5 / 12턴):

### 런 영향

- 예상 승률 변화:
- 5세션 기대 추가 보상 횟수:
- 보상 선택률:
- 보상 건너뛰기율:
- 런 스노볼 위험:

### 위험 분석

- 위험 플래그:
- 동일 카드 2장 조합:
- 연계 누적:
- 계획 용량 증가:
- 저은폐/고은폐 구간:
- 무드 및 연속 부정 무드 구간:
- 짧은/긴 세션:

### 설계 의도

- 의도된 선택 상황:
- 실제 약점:
- 필요한 테스트:
```

---

## 21. 플레이테스트 기준

### 21.1 초기 전투 목표

| 지표 | 초기 목표 |
|---|---:|
| 숙련 플레이어의 중립 상대 승률 | `55~65%` |
| 평균 승리 턴 | `7~9턴` |
| 승리 시 평균 남은 은폐 | `5~15` |
| 일반 카드 세션당 사용 횟수 | `1~3회` |
| 계획 실제 발동률 | `40~80%` |
| 초기 드래프트 제안 내 선택률 | `25~65%` |
| 단일 카드 추가 승률 상승 | `5~7%p 이하` |
| 단일 카드 전체 피해 기여율 | 일반적으로 `25% 이하` |

### 21.2 보상 목표

보상 선택은 건너뛰기가 존재하므로 초기에는 하드 합격 범위보다 관찰 지표로 사용한다.

```yaml
reward_metrics:
  card_offer_count: 0
  card_pick_count: 0
  skip_count: 0
  reward_pick_rate: 0.0
  reward_skip_rate: 0.0
  post_pick_win_rate_delta: 0.0
```

관찰 경고:

- 특정 카드가 제안될 때 `70% 이상` 선택되고 건너뛰기가 거의 없으면 범용 과성능 가능성이 높다.
- 전체 보상 건너뛰기율이 지나치게 높으면 카드 풀이 현재 덱을 개선하지 못할 가능성이 있다.
- 강한 카드 보유자의 보상 접근 횟수가 계속 증가하면 런 스노볼을 검토한다.

### 21.3 필수 테스트 매트릭스

```yaml
session_lengths: [7, 9, 10, 12]
player_decks: [attack, survival, plan, mood, mixed]
character_archetypes: [attack, defense, plan, control]
player_skill: [novice, informed, optimized]
acquisition_context: [initial_draft, victory_reward, near_deck_cap]
card_copies: [1, 2]
deck_sizes: [10, 15, 20]
plan_capacities: [1, 2, 4]
base_draw_counts: [2, 3, 4]
max_hand_sizes: [4, 5, 6]
starting_moods: [rejection, suspicion, ignore, confusion, compliance]
previous_mood_same: [false, true]
reward_choice: [card, skip]
```

### 21.4 권위 전투 로그 필수 필드

최신 `battleHistory`를 테스트 데이터의 우선 원천으로 사용한다.

| 로그 필드 | 목적 |
|---|---|
| 제안 횟수 / 선택 횟수 | 드래프트·보상 선택률 |
| 보상 건너뛰기 | 보상 풀이 실제 개선인지 확인 |
| 승패 및 보상 RNG 커서 | 승리·패배 경로 분리 검증 |
| 손패 등장 / 실제 사용 | 죽은 카드 비율 |
| 사용 시 은폐·저항·무드 | 상태 구간별 성능 |
| 무드 판정 전·후 상태 | 토큰·강제 변경 효과 검증 |
| 무드로 인한 은폐 증감 | 무드 EV 검증 |
| 직전 턴 동일 부정 무드 여부 | 의심·거절 배수 검증 |
| 직접·간접 피해 기여 | 실제 공격 가치 |
| 회복량 / 이후 비용 지불량 | 회복의 공격 자원 전환량 |
| 계획 설치·발동·교체·미발동 | 계획 기대값 검증 |
| 연계 사용 수 / 한 턴 총효과 | 행동 경제 폭발 탐지 |
| 승패 확정 체크포인트 | 선공·무드·턴 제한 우선순위 검증 |
| 취소된 캐릭터 행동 AI 점수 | 스킵 가치 측정 |

### 21.5 운영 권고

- 최소 `200~500세션`의 자동·수동 테스트 후 BP 범위를 개정한다.
- 평균뿐 아니라 상위 5% 폭발 턴과 하위 5% 죽은 손패를 확인한다.
- 무드 카드는 평균 무드만 보지 말고 연속 거절·연속 의심 구간을 별도 분석한다.
- 런 밸런스는 세션 단위 승률과 3·5세션 뒤 덱 성장 속도를 함께 본다.
- 밸런스 변경은 수치, 획득 빈도, 복사 제한, 매치업 중 한 축씩 조정한다.

---

## 22. 미확정·보류 항목

| ID | 미확정 항목 | 영향 | 권장 조치 |
|---|---|---|---|
| `OPEN-001` | 수정치 연산 순서 | 비용 감소·피해 증폭 중첩 결과 | 가산/승산/최종값 순서 확정 |
| `OPEN-002` | 저항 최대치 | 회복 장기전 가치 | 초기 저항을 최대치로 볼지 명시 |
| `OPEN-003` | 은폐 상한 부재 | 생존·비용 자원 무한 축적 | 의도 확인 및 카드별 내부 상한 검토 |
| `OPEN-004` | 캐릭터 무드 효과 AI 평가 | 실제 강도와 선택률 불일치 | 무드 EV 점수 규칙 구현 |
| `OPEN-005` | 캐릭터 사용 가능 조건 | 불법·비합리 선택 가능 | 선택기 지원 범위 확정 |
| `OPEN-006` | 희귀도·드래프트 가중치 | 획득 빈도가 실전 예산 결정 | 획득 예산 별도 정의 |
| `OPEN-007` | 장기 보상 유형·해금 확률 | 런 성장 곡선 영향 | 카드 강도 티어와 획득 빈도 연동 |
| `OPEN-008` | 보상 건너뛰기 목표 범위 | 선택률 해석 | 카드 풀이 안정된 뒤 기준 수립 |

`OPEN-*`에 직접 의존하는 카드는 `HOLD` 또는 `REVISE`로 유지한다.

---

## 23. 최종 리뷰 체크리스트

```yaml
checklist:
  - id: CHECK-001
    question: "카드의 주 역할이 정확히 하나인가?"
  - id: CHECK-002
    question: "직접 피해에 선공·중간 승패 판정 프리미엄을 반영했는가?"
  - id: CHECK-003
    question: "은폐 비용이 실제 사용 제한으로 작동하는가?"
  - id: CHECK-004
    question: "무드로 얻는 남은 턴 은폐 증감 기대값을 계산했는가?"
  - id: CHECK-005
    question: "마지막 허용 턴에는 일반적으로 무드 틱이 없음을 반영했는가?"
  - id: CHECK-006
    question: "조건의 실제 발동률을 추정했는가?"
  - id: CHECK-007
    question: "연계·드로우가 행동 경제를 과도하게 늘리지 않는가?"
  - id: CHECK-008
    question: "계획의 모든 충전과 반복 횟수를 기대값에 포함했는가?"
  - id: CHECK-009
    question: "제거가 덱 압축이라는 장점으로 바뀌지 않는가?"
  - id: CHECK-010
    question: "7턴 세션에서도 의미가 있는가?"
  - id: CHECK-011
    question: "캐릭터 카드라면 AI가 무드 포함 효과를 올바르게 평가하는가?"
  - id: CHECK-012
    question: "한 카드가 공격·생존·탐색·통제를 동시에 해결하지 않는가?"
  - id: CHECK-013
    question: "승률 상승이 추가 보상 접근과 결합해 스노볼을 만들지 않는가?"
  - id: CHECK-014
    question: "보상 선택률 계산에서 패배 세션을 제외하고 skip을 포함했는가?"
  - id: CHECK-015
    question: "기존 임시 카드가 아니라 현행 규칙과 목표 경험만을 기준으로 판단했는가?"
```

승인 규칙:

```text
모든 CHECK가 true이고 자동 거부 플래그가 없으면 PASS 후보.
하나라도 false이면 REVISE.
미확정 규칙·AI 미지원에 의존하면 HOLD.
무한 루프, 구현 불가, 행동 경제 무효화, 대응 불가 무드 고착이면 REJECT.
```

---

## 24. 에이전트용 요약 규칙

```yaml
agent_summary:
  base_main_action_budget_bp: [4, 6]
  strong_main_action_budget_bp: [6, 8]
  chain_budget_bp: [0.5, 2]
  plan_total_ev_cap_bp: 8
  direct_damage_bp_per_point: 1.0
  stealth_change_bp_per_point: [0.8, 1.0]
  low_stealth_change_bp_per_point: [1.0, 1.25]
  draw_1_bp: [1.2, 1.8]
  insight_bp: [0.5, 1.5]
  skip_character_action_bp: [3.5, 5.5]
  normal_turn_damage_cap: [6, 8]
  strong_turn_damage_cap: [8, 10]
  prepared_turn_damage_cap: [11, 14]
  easy_repeat_turn_damage_cap_exclusive: 10
  one_turn_kill_allowed: false
  chain_direct_damage_recommended: [0, 1]
  chain_direct_damage_hard_cap: 2
  chain_total_damage_per_turn_target_max: 3
  mood_fixed_bp_allowed: false
  mood_stealth_delta:
    rejection_first: -3
    rejection_repeated: -6
    suspicion_first: -1
    suspicion_repeated: -2
    ignore: 0
    confusion: 1
    compliance: 2
  max_eligible_mood_ticks_formula: "max(0, turn_limit - 1)"
  reward_after_victory_only: true
  reward_can_be_skipped: true
  reward_rng_consumed_after_defeat: false
  reward_pick_rate_denominator: "victorious reward offers only"
  duplicate_card_limit: 2
  deck_size: [10, 20]
  session_turns: [7, 12]
  default_base_draw_count: 3
  default_max_hand_size: 5
  base_draw_and_hand_size_can_vary: true
  default_plan_capacity: 1
  plan_capacity_hard_cap: 16
  existing_test_cards_are_valid_balance_evidence: false
```

---

## 25. 최종 원칙

> 좋은 카드는 언제나 강한 카드가 아니라, 특정 상황에서 명확한 선택 이유와 분명한 기회비용을 제공하는 카드다.

현행 룰에서 무드는 단순 조건 태그가 아니다. 은폐를 반복적으로 잃거나 회복하게 만드는 자원 엔진이다. 따라서 무드 카드의 가치는 현재 상태와 남은 턴을 기준으로 계산해야 한다.

또한 승리만 보상 접근을 제공하므로 전투 승률을 크게 높이는 카드는 다음 세션의 성장 기회까지 늘린다. 카드의 전투 BP와 런 스노볼 영향은 반드시 분리해 검토한다.

---

## 26. 변경 이력

| 버전 | 일자 | 기준 커밋 | 변경 내용 |
|---|---|---|---|
| `0.1-agent` | 2026-07-31 | `6101215` | 초기 BP 모델, 위험 플래그, 입출력 스키마 |
| `0.2-agent` | 2026-08-01 | `08752b9` | 턴 종료 무드 은폐 효과, 승리 조건부·선택적 보상, 권위 전투 로그 반영 |
