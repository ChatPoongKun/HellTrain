# 활성 테스트

현재 테스트의 단일 진입점은 다음 명령이다.

```powershell
python build/tests/RuntimeRegression/check_runtime_regressions.py
```

최초 실행 전 `build/setup.bat`으로 `build/requirements.txt`의 의존성(Pillow, Lupa 2.8)을 설치한다. Python 3.12 이상과 PowerShell이 필요하다.

위 실행기는 카드 taxonomy, revision, HTML 형식과 런타임 회귀를 모두 실행한다. `build/release.bat`은 전체 검사를 통과한 뒤 CHARX를 만든다. `build/test.bat`은 `--fast` 핵심 검사만 실행하며 `build/build.bat`은 검사 없이 CHARX만 생성한다.

이 폴더의 테스트 소스와 fixture는 모두 Git에 포함한다. 로컬 `.agents/` 자료나 별도 `.deps` 디렉터리 없이 설치된 Lupa의 Lua 5.4와 LuaJIT 런타임을 사용한다.

활성 폴더에는 다음만 둔다.

- `RuntimeRegression/`: 저장 복구, 전환, 종료, 카드·퍽과 보상 회귀
- `CardTaxonomy/`: 카드 유형·역할의 정적 계약
- `BattleSimulation/StyleDecks/`: 실제 Lua 모듈 로더와 만료·후속 효과 회귀에 필요한 최소 파일
- `setup-to-battle-flow-check.ps1`, `turn-phase-draw-replay-check.ps1`: 최신 Python 회귀가 공통 Lua fixture를 추출하는 공급 파일
- `runtime-bundle-contract-check.ps1`, `html-indent-check.ps1`: revision·캐시 경계와 Risu HTML 형식 검사
- `fixtures/json.lua`: RisuAI 호스트 JSON 동작을 재현하는 rxi/json.lua 0.1.2 (MIT, 라이선스 고지 포함)

`check_player_card_pipeline.py`는 정적 DB의 플레이어 카드 ID와 선택지 ID를 기대 집합으로 삼아 실제 카드 사용·출력 투영·commit 성공 집합과 비교한다. 활성 계획이 필요한 카드에는 계획 fixture를 제공한다. 누락 시 해당 카드/선택지 ID로 실패하며, 성공 횟수는 진단 출력에만 사용한다.

fixture 공급 PS1 두 개는 단독 실행 대상이 아니다. 과거 테스트와 결과는 `.agents/legacy/tests/`에 있으며 실행·검색·현재 판단에서 제외한다.
