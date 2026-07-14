# 정적 게임 데이터 계약 v1

## 1. 공통 모듈 형식

정적 게임 데이터 로어북은 Lua 청크 하나이며 `schemaVersion`, `kind`와 종류별 컬렉션을 가진 테이블을 반환한다. 로딩 이외의 부수효과를 만들지 않는다.

| `kind` | 컬렉션 | 현재 로어북 |
|---|---|---|
| `gameRegistry` | 행동 태그, 메커니즘, 무드, 사건, 효과 명령 | `GameRegistry.lua` |
| `cardDatabase` | `cards` | `PlayerCards.lua`, `CharacterCards.lua` |
| `traitDatabase` | `traits` | `CharTraits.lua` |
| `environmentDatabase` | `environments` | `Environments.lua` |
| `characterDatabase` | `characters` | `YooJiyoung.lua` |

모든 컬렉션 키와 항목의 `id`는 같아야 하며 전체 병합 범위에서 종류별 ID가 중복되면 오류다.

## 2. 중앙 레지스트리

`GameRegistry.lua`는 카드와 다른 정적 DB가 참조할 수 있는 내부 ID를 정의한다. `block`과 `evade`는 캐릭터 행동 태그이며 메커니즘이 아니다. 메커니즘은 `chain`, `remove`, `plan`, `insight`다.

효과 함수가 반환하는 `op`와 트리거가 참조하는 `event`도 레지스트리에 먼저 등록되어야 한다.

## 3. 특징

특징은 다음 필드를 사용한다.

```text
id, owner, name, visibility, description, rules, modifiers
```

`modifiers`는 상태를 직접 변경하지 않는 선언형 보정 목록이다. 유지영의 `reserved` 특징은 다음 보정을 사용한다.

```lua
{
    timing = "moodPerformanceThreshold",
    operation = "add",
    direction = "compliance",
    amount = 1,
}
```

기본 무드 경계 `5-4-4-5`에서 순응 방향으로 이동할 때만 요구 성과를 1 높인다. 따라서 유지영에게 적용되는 순응 방향 경계는 `6-5-5-6`이다. 거절 방향 경계는 바꾸지 않는다.

## 4. 환경

환경은 `id`, 표시 정보와 `triggers`를 가진다. 트리거는 사건과 진영 조건을 선언하고, `resolve` 함수는 구조화 효과 명령만 반환한다.

`uncrowded` 환경의 은폐 감소는 카드 비용이 아니라 `environmentEffect` 원인의 외부 은폐 손실이다. 비용 감소나 비용 손실 보정의 영향을 받지 않는다.

## 5. 캐릭터

캐릭터 정의는 공개 프로필과 비공개 프로필을 분리한다. 전투 정보에는 시작 저항, 시작 무드, 특징 ID, 카드 ID와 선택 성향만 둔다.

누적 플레이 횟수와 사건 횟수는 정적 캐릭터 정의가 아니라 함수 없는 저장 상태에 둔다. View 생성기는 `privateProfile`을 명시적으로 허용한 화면이나 LLM 사건이 아니면 복사하지 않는다.

## 6. 로드와 검증

정적 DB 청크는 RisuAI 상태 변경 함수가 없는 제한 환경에서 실행한다. 로더는 다음 항목을 검증한다.

- 지원하는 `schemaVersion`과 `kind`
- 컬렉션 키와 내부 ID 일치 및 중복
- 레지스트리의 행동 태그, 메커니즘, 무드, 사건과 효과 명령 컬렉션 구조
- 카드의 필수 필드, 계획 수명, 설명 태그와 묘사
- 특징 보정의 타이밍, 연산, 방향과 수치
- 환경 트리거의 사건, 진영과 효과 함수
- 캐릭터가 참조하는 특징, 카드, 무드와 행동 태그
- 플레이어 덱과 캐릭터 덱의 카드 소유자 일치

로더는 검증 과정에서 카드·환경 콜백을 임의로 실행하지 않는다. 콜백이 반환한 효과 명령의 `op`, 대상과 필수 값은 전투 엔진이 해당 콜백을 실제로 실행한 직후 상태에 적용하기 전에 검증한다.

실제 진행 상태와 View에는 정적 DB 함수나 비공개 프로필을 통째로 복사하지 않는다.
