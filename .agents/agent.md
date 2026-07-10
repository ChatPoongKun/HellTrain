# 덱빌딩 치한전철

## 🛠️ 기술 스택
- 플랫폼: [RisuAI](https://risuai.xyz)
- 스크립팅: Lua 5.4 (JS 런타임 위에서 실행)
- 템플릿: CBS (Curly Braced Syntaxes)
- UI: HTML + CSS (RisuAI 내장 렌더러)
- 데이터: JSON 기반 DB 파일

- ⚠️ HTML/CSS 스타일링 주의사항
> 리수플랫폼에서는 CSS 클래스명에 자동으로 `risu-x-` 등의 접두사가 붙습니다. 따라서 HTML에서 `class="my-style"`이라고 정의했더라도, CSS에서는 `.x-risu-my-style` (또는 개발자 도구에서 확인된 접두사)로 스타일을 정의해야 적용될 수 있습니다.


## 📖 문서
- [CBS.md] - RisuAI CBS 문법 완전 가이드 (v166)
- [Lua.md] - RisuAI Lua 트리거 가이드 (v166)

## 기타 주요사항.
- 명시적 지시 없이 main.lua파일을 수정해서는 안됨