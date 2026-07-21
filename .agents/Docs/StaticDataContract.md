# 정적 게임 데이터 계약 v1

## 1. 공통 모듈 형식

정적 게임 데이터 로어북은 Lua 청크 하나이며 `schemaVersion`, `kind`와 종류별 컬렉션을 가진 테이블을 반환한다. 파일과 로어북 이름은 정적 데이터임을 드러내는 `.db` 확장자를 사용하지만 내용 문법은 Lua다. 작업공간의 `files.associations`가 `*.db`를 Lua로 연결한다. 로딩 이외의 부수효과를 만들지 않는다.

| `kind` | 컬렉션 | 현재 로어북 |
|---|---|---|
| `gameRegistry` | 행동 태그, 메커니즘, 무드, 사건, 효과 명령 | `GameRegistry.db` |
| `cardDatabase` | `cards` | `PlayerCards.db`, `CharacterCards.db` |
| `traitDatabase` | `traits` | `CharTraits.db` |
| `environmentDatabase` | `environments` | `Environments.db` |
| `characterList` | `characters` | `CharacterList.db` |
| `characterDatabase` | `characters` | `CharacterList.db`가 지정한 개별 영문 DB |

모든 컬렉션 키와 항목의 `id`는 같아야 하며 전체 병합 범위에서 종류별 ID가 중복되면 오류다. 게임 ID 값은 종류와 관계없이 `lower_snake_case`를 사용하고, `schemaVersion` 같은 스키마 필드명은 lowerCamelCase를 사용한다.

## 2. 중앙 레지스트리

`GameRegistry.db`는 카드와 다른 정적 DB가 참조할 수 있는 내부 ID를 정의한다. `block`과 `evade`는 캐릭터 행동 태그이며 메커니즘이 아니다. 메커니즘은 `chain`, `remove`, `plan`, `insight`다.

효과 함수가 반환하는 `op`와 트리거가 참조하는 `event`도 레지스트리에 먼저 등록되어야 한다.

## 3. 카드 선택 단계 효과

같은 턴 선택을 확장하는 효과는 일반 콜백을 미리 실행하지 않고 카드의 선언형 `selectionPreview.effects`에 둔다. 이 필드는 화면용 중복 정보가 아니라 선택 단계에서 실제로 한 번 적용할 효과의 단일 원본이다.

v1은 플레이어 `chain` 카드의 `draw_cards`만 허용한다. 각 효과에는 고유 ASCII `id`, 등록된 `op`, `target = "player"`와 양의 정수 `amount`가 필요하다. 같은 카드에 `selectionPreview`와 일반 `resolve`를 함께 두면 정적 검증 오류다.

## 4. 특징

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

## 5. 환경

환경은 `id`, 표시 정보와 `triggers`를 가진다. 트리거는 사건과 진영 조건을 선언하고, `resolve` 함수는 구조화 효과 명령만 반환한다.

`uncrowded` 환경의 은폐 감소는 카드 비용이 아니라 `environmentEffect` 원인의 외부 은폐 손실이다. 비용 감소나 비용 손실 보정의 영향을 받지 않는다.

## 6. 캐릭터

`CharacterList.db`는 캐릭터 ID와 개별 DB 파일명만 보관한다. 같은 이름으로 등록된 여러 목록 로어 엔트리는 하나의 목록으로 병합한다. 각 항목은 `{ id = "yoo_jiyoung", database = "YooJiyoung.db" }` 형태이며, 개별 DB 이름은 영문자로 시작하고 영문자·숫자·밑줄만 사용한 `.db` 파일명이어야 한다. 하나의 개별 DB는 목록의 캐릭터 한 명만 정의한다. 목록에 없는 정의, 목록 ID와 다른 정의, 누락된 DB와 동일 DB의 중복 연결은 전체 로딩 오류다.

개별 캐릭터 DB의 정의는 공개 프로필과 비공개 프로필을 분리한다. 전투 정보에는 시작 저항, 시작 무드, 기본 드로우 수, 최대 손패, 특징 ID, 카드 ID와 선택 성향만 둔다. `battle.baseDrawCount`와 `battle.maxHandSize`는 1 이상의 정수이며 기본 드로우 수는 최대 손패보다 클 수 없다. 유지영의 현재 값은 각각 3과 5다. 모든 개별 DB를 불러와 병합한 캐릭터 컬렉션에서 표시용 `name`은 고유해야 하며, 중복되면 `duplicate_character_name` 오류로 전체 정적 데이터 로딩을 중단한다.

누적 플레이 횟수와 사건 횟수는 정적 캐릭터 정의가 아니라 함수 없는 저장 상태에 둔다. View 생성기는 `privateProfile`을 명시적으로 허용한 화면이나 LLM 사건이 아니면 복사하지 않는다.

## 7. 로드와 검증

정적 DB 청크는 RisuAI 상태 변경 함수가 없는 제한 환경에서 실행한다. 로더는 다음 항목을 검증한다.

- 지원하는 `schemaVersion`과 `kind`
- 컬렉션 키와 내부 ID 일치 및 중복
- 레지스트리의 행동 태그, 메커니즘, 무드, 사건과 효과 명령 컬렉션 구조
- 카드의 필수 필드, 계획 수명, 설명 태그와 묘사
- 선택 단계 효과의 카드 자격, 허용 필드, 효과 ID, 작업, 대상과 양의 정수 수량
- 특징 보정의 타이밍, 연산, 방향과 수치
- 환경 트리거의 사건, 진영과 효과 함수
- 캐릭터가 참조하는 특징, 카드, 무드와 행동 태그 및 손패 설정
- 플레이어 덱과 캐릭터 덱의 카드 소유자 일치

로더는 검증 과정에서 카드·환경 콜백을 임의로 실행하지 않는다. 선언형 선택 단계 효과는 로드할 때 전부 검증한다. 콜백이 반환한 나머지 효과 명령의 `op`, 대상과 필수 값은 전투 엔진이 해당 콜백을 실제로 실행한 직후 상태에 적용하기 전에 검증한다.

실제 진행 상태와 View에는 정적 DB 함수나 비공개 프로필을 통째로 복사하지 않는다.
