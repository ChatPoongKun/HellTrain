function (triggerId)
    --초기 변수 설정
    local initVars = {
        session = 0, --플레이한 세션의 수
        cummulativeTurns = 0, --플레이한 누적 턴 수
        maxHandSize = 3, --플레이어 기본 최대 손패 수치
        Suppression = 30, --플레이어 기본 경계수치
        perks = {} --플레이어 기본 특성
    }

    --###########################
    --DB 로딩 및 리스트 생성 (JSON 기반 + 정렬)
    --###########################

    for key, value in pairs(initVars) do
        setChatVar(triggerId, key, value)
    end

    --기본 UI 표시
    runScript(triggerId, "uiRender", "set", "sideBar")
end
