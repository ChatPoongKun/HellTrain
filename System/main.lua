--기본 변수
DEBUG = 1 --디버그 메시지 depth. 숫자가 클수록 덜 중요하고 디테일 한 메시지.

--전역 상수
DEFAULT_LORE_OPTION = { alwaysActive = false, insertOrder = 100, key = "", secondKey = "", regex = false }


--====================================
-- 유틸리티 함수
--====================================

--디버깅용
function debug(depth, ...)
    if DEBUG =< depth then
        print(...)
    end
end

--tonumber를 콤마제거후 숫자로 인식하도록 오버라이딩
old_tonumber = tonumber
tonumber = function(str, base)
    if type(str) == "string" then
        local cleaned_str = string.gsub(str, ",", "")
        return old_tonumber(cleaned_str, base)
    else
        return str, base
    end
end

--json을 chatVar 형식으로 저장
function toChatVar(triggerId, data)

    setChatVar(triggerId, )
end

--chatVar를 lua테이블 형식으로 저장
function toTable(triggerId, data)
    
end

--로어북에서 내용을 불러와 return
function loadLores(triggerId, lore)
    local targetLores = getLoreBooks(triggerId, lore)
    local returnContents = ""
    for k, v in ipairs(targetLores) do
        returnContents = returnContents .. v.content
    end

    --주석 제거
    returnContents = returnContents
        :gsub("%-%-.*\n", "\n")
        :gsub("%-%-.*", "")

    if returnContents == "" then
        debug(1, "로어북 로드 오류: ".. lore .."로어북이 존재하지 않음.")
        return nil
    else
        return returnContents
    end
end

--로어북에서 스크립트를 호출해 실행
function runScript(triggerId, script)
    local functionString = loadLores(triggerId, script)
    local returnFunc = "return " .. functionString

    local chunk, err = load(returnFunc, "lore_function", "t", _G)
    if not chunk then
        debug(1, "컴파일 오류: " .. (err or "알 수 없음"))
        return nil
    end

    local success, result = pcall(chunk)
    if success and type(result) == "function" then
        return result
    else
        debug(1, "실행 오류: " .. tostring(result))
        return nil
    end
end

--로어북에서 db를 호출해 저장
function saveDB(triggerId, db)
    local data = "return " .. loadLores(triggerId, db)

    local chunk, err = load(data, db, "t", _G)
    if not chunk then
        debug(1, err)
        return nil
    end

    local ok, result = pcall(chunk)
    if not ok then
        debug(1, result)
        return nil
    end

    setChatVar = toChatVar(triggerId, data)
end