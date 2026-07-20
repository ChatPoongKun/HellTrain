# 덱빌딩 치한전철

## 🛠️ 기술 스택
- 플랫폼: [RisuAI](https://risuai.xyz)
- 스크립팅: Lua 5.4 (JS 런타임 위에서 실행)
- 템플릿: CBS (Curly Braced Syntaxes)
- UI: HTML + CSS (RisuAI 내장 렌더러)
- 정적 게임 데이터: Lua 테이블 기반 DB 파일
- 진행 상태와 세이브: 함수가 없는 JSON 직렬화 데이터

- ⚠️ HTML/CSS 스타일링 주의사항
> 리수플랫폼에서는 CSS 클래스명에 자동으로 `risu-x-` 등의 접두사가 붙습니다. 따라서 HTML에서 `class="my-style"`이라고 정의했더라도, CSS에서는 `.x-risu-my-style` (또는 개발자 도구에서 확인된 접두사)로 스타일을 정의해야 적용될 수 있습니다.


## 📖 문서
- [References/CBS.md] - RisuAI CBS 문법 완전 가이드 (v166)
- [References/Lua.md] - RisuAI Lua 트리거 가이드 (v166)

## 🗂️ 개발 자료 구조
- `Docs/` - 데이터·상태·턴 처리 계약과 개발 계획
- `Tests/` - 로컬 계약 및 회귀 검사
- `References/` - RisuAI 문법 문서와 로컬 참조 소스
- 실제 게임에 등록하는 파일은 프로젝트 루트의 `System/`, `DB/`, `Char/`, `html/`, `imgs/`, `Prompt/`에 둔다.

## 기타 주요사항.
- 명시적 지시 없이 main.lua파일을 수정해서는 안됨
- main.lua를 제외한 모든 db, html, lua 파일은 loadlore로 불러오는 로어북으로 취급됨.
- DB 스키마 키와 내부 ID는 ASCII를 사용하고 표시 이름, 설명과 LLM 묘사는 한글을 사용할 수 있음.
- 정적 DB의 함수는 상태를 직접 변경하지 않고 구조화된 효과를 반환하며 공통 엔진이 실제 상태 변경을 담당함.
- 사용자용 카드 설명의 태그는 `::tag[ASCII_ID]::` 형식으로 기록하며 실제 판정은 설명이 아니라 구조화된 태그 필드를 사용함.
- 태그 토큰은 View에서 구조화된 조각으로 변환하고 HTML/CBS가 스타일이 적용된 `span`으로 렌더링함. DB 설명에 원시 HTML을 넣지 않음.
