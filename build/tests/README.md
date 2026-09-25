# 활성 테스트

현재 테스트의 단일 진입점은 다음 명령이다.

```powershell
python build/tests/RuntimeRegression/check_runtime_regressions.py
```

최초 실행 전 `build/setup.bat`으로 `build/requirements.txt`의 의존성(Pillow, Lupa 2.8)을 설치한다. Python 3.12 이상과 PowerShell이 필요하다.

위 실행기는 카드 taxonomy, revision, HTML 형식과 런타임 회귀를 모두 실행한다. `build/release.bat`은 전체 검사를 통과한 뒤 CHARX를 만든다. `build/test.bat`은 `--fast` 핵심 검사만 실행하며 `build/build.bat`은 검사 없이 CHARX만 생성한다.

`check_scoped_static_data.py`는 전체 DB 검증과 함께 목록·단일 캐릭터 로딩의 로어
조회 범위, 캐시 간 격리, 반환값 수정 격리, 미로딩 캐릭터의 도감 발견 기록 보존,
목록 요약 불일치 거부를 검사한다. 가상 캐릭터 200명을 목록에 추가해도 선택하지
않은 개별 DB를 읽지 않는지 Lua 5.4와 LuaJIT에서 확인한다.
`check_common_character_deck.py`는 전용 카드 수에 따른 공용 카드 보충, 시드별 재현,
10장 경계, 전투 시작, 선택적 로딩 및 잘못된 카드 참조의 거부를 두 Lua 런타임에서 확인한다.

자유조교 변경은 다음 개별 검사로 확인한다.

```powershell
python build/tests/RuntimeRegression/check_free_training.py
python build/tests/RuntimeRegression/check_free_training_host_flow.py
python build/tests/RuntimeRegression/check_free_training_summary.py
python build/tests/RuntimeRegression/check_character_context_lore.py
python build/tests/RuntimeRegression/check_character_journal.py
```

`check_free_training.py`는 같은 캐릭터의 서로 다른 승리 전투 3회 조건과 세션 상태 전이의 중복 방지를 확인한다. `check_free_training_host_flow.py`는 자유 입력 중 전투 controller·검증·commit 경로가 호출되지 않는지 확인한다. `check_free_training_summary.py`는 현재 세션의 채팅 경계, 빈 대화, 요약 실패 및 길이 제한을 확인한다. `check_character_context_lore.py`는 활성 캐릭터의 공개·비공개 프로필, 과거 전투 결과와 최신 자유조교 요약 3회만 항상 활성 로컬 로어북에 투영하는지 확인한다. 실제 RisuAI에서는 생성 중 종료, 최신 응답으로 UI target 이동, 리롤과 Continue, 종료 뒤 동일 캐릭터 후보 유지도 수동으로 확인한다.

이 폴더의 테스트 소스와 fixture는 모두 Git에 포함한다. 로컬 `.agents/` 자료나 별도 `.deps` 디렉터리 없이 설치된 Lupa의 Lua 5.4와 LuaJIT 런타임을 사용한다.

활성 폴더에는 다음만 둔다.

- `RuntimeRegression/`: 저장 복구, 전환, 종료, 카드·퍽과 보상 회귀
- `CardTaxonomy/`: 카드 유형·역할의 정적 계약
- `BattleSimulation/StyleDecks/`: 실제 Lua 모듈 로더와 만료·후속 효과 회귀에 필요한 최소 파일
- `setup-to-battle-flow-check.ps1`, `turn-phase-draw-replay-check.ps1`: 최신 Python 회귀가 공통 Lua fixture를 추출하는 공급 파일
- `runtime-bundle-contract-check.ps1`, `html-indent-check.ps1`: revision·캐시 경계와 Risu HTML 형식 검사
- `fixtures/json.lua`: RisuAI 호스트 JSON 동작을 재현하는 rxi/json.lua 0.1.2 (MIT, 라이선스 고지 포함)

`check_player_card_pipeline.py`는 정적 DB의 플레이어 카드 ID와 선택지 ID를 기대 집합으로 삼아 실제 카드 사용·출력 투영·commit 성공 집합과 비교한다. 활성 계획이 필요한 카드에는 계획 fixture를 제공한다. 누락 시 해당 카드/선택지 ID로 실패하며, 성공 횟수는 진단 출력에만 사용한다.

`check_validation_reuse.py`는 실제 `runtime.lua` 디스패처로 카드 클릭·오래된 클릭 거부·전송·commit·프리뷰 셔플 취소를 검사한다. 이벤트 내부의 동일 검증 재사용, 변경된 상태·draft·정적 DB와 다음 이벤트의 캐시 분리, 반환값 변경의 격리를 확인한다. 실행 시간은 7회 중앙값을 출력하며 기기별 시간 임계값으로 성공 여부를 결정하지 않는다. `--baseline <이전 runtime.lua 경로> --snapshot <JSON 경로>`로 이전 구현의 결과와 비교할 수 있다.

선택 경량화 검사에서는 일반 카드 클릭의 전체 상태 검증·이력 스캔·HTML 로어 조회가 없는지, 상태 읽기가 6회 이하인지 확인한다. UI 쓰기 실패 후 오래된 클릭으로 복구할 때의 도감 기록, 선택 취소 후 발견 유지, 전송 시 잘못된 프리뷰 거부도 검사한다. `--baseline`은 디스패처만 교체하므로 다른 모듈까지 변경한 전후 비교에는 각 버전에서 저장한 `--snapshot` 결과를 사용한다.

`check_player_card_pipeline.py`는 모든 카드·효과 선택지의 경량 선택·취소 결과를 기존 엄격 경로와 비교한다. `check_preview_rng.py`는 프리뷰로 뽑힌 카드를 선택한 뒤 원본 드로우 카드를 취소하는 경우도 비교한다. `check_interaction_ui.py`는 Lua 렌더러의 선택·팝오버·잠금·종료 상태와 HTML 이스케이프를 Lua 5.4와 LuaJIT에서 검사한다.

fixture 공급 PS1 두 개는 단독 실행 대상이 아니다. 과거 테스트와 결과는 `.agents/legacy/tests/`에 있으며 실행·검색·현재 판단에서 제외한다.
