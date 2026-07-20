--기본 변수
DEBUG = 2 --디버그 메시지 depth. 숫자가 클수록 덜 중요하고 디테일 한 메시지.

--전역 상수
DEFAULT_LORE_OPTION = { alwaysActive = false, insertOrder = 100, key = "", secondKey = "", regex = false }


--디버깅
function debug(depth, ...)
    if depth <= DEBUG then
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
        return old_tonumber(str, base)
    end
end

--json을 chatVar 형식으로 저장
function toChatVar(triggerId, name, data)
    if data == nil then
        data = getState(triggerId, name)
    end

    if type(data) ~= "table" then
        setChatVar(triggerId, name, tostring(data))
        return tostring(data)
    end

    local function encodeString(value)
        return json.encode(tostring(value))
    end

    local function encodeForChatVar(value)
        local parts = {}

        for k, v in pairs(value) do
            local encodedValue

            if type(v) == "table" then
                encodedValue = encodeString(encodeForChatVar(v))
            else
                encodedValue = encodeString(v)
            end

            table.insert(parts, encodeString(k) .. ":" .. encodedValue)
        end

        return "{" .. table.concat(parts, ",") .. "}"
    end

    local encoded = encodeForChatVar(data)
    setChatVar(triggerId, name, encoded)
    return encoded
end

--chatVar를 state 형식으로 저장
function toState(triggerId, name)
    local source = getChatVar(triggerId, name)

    if not source or source == "" then
        debug(1, "toState error: chat var " .. tostring(name) .. " is empty.")
        setState(triggerId, name, {})
        return getState(triggerId, name)
    end

    local function tryDecode(value)
        if type(value) ~= "string" then
            return nil
        end

        local trimmed = value:match("^%s*(.-)%s*$")
        local first = trimmed:sub(1, 1)
        if first ~= "{" and first ~= "[" then
            return nil
        end

        local ok, decoded = pcall(json.decode, trimmed)
        if ok and type(decoded) == "table" then
            return decoded
        end
        return nil
    end

    local function decodeFromChatVar(value)
        if type(value) == "table" then
            local decoded = {}
            for k, v in pairs(value) do
                decoded[k] = decodeFromChatVar(v)
            end
            return decoded
        end

        local decoded = tryDecode(value)
        if decoded then
            return decodeFromChatVar(decoded)
        end

        return value
    end

    local root = tryDecode(source)
    if not root then
        setState(triggerId, name, source)
        return source
    end

    local decoded = decodeFromChatVar(root)
    setState(triggerId, name, decoded)
    return decoded
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
        :gsub("%-%-%-[^\r\n]*", "")

    if returnContents == "" then
        return nil
    else
        return returnContents
    end
end

--로어북에서 스크립트를 호출해 실행
function runScript(triggerId, script, ...)
    --nil 체크
    local source = loadLores(triggerId, script..".lua")
    if not source then
        debug(1, "runScript error: lorebook '" .. script .. "' not found.")
        return nil
    end

    local functionString = "return" .. source
    debug(3, functionString)

    local chunk, err = load(functionString, "lore_function", "t", _G)
    if not chunk then
        debug(1, "컴파일 오류: " .. (err or "알 수 없음"))
        return nil
    end

    local ok, result = pcall(chunk)
    if not ok then
        debug(1, "스크립트 로드 오류: " .. tostring(result))
        return nil
    end

    if type(result) ~= "function" then
        debug(1, "runScript error: lorebook '" .. script .. "' did not return a function.")
        return nil
    end

    local execOk, execResult = pcall(result, triggerId, ...)
    if not execOk then
        debug(1, "스크립트 실행 오류: " .. tostring(execResult))
        return nil
    end

    return execResult
end

--로어북에서 db를 호출해 return
function loadDB(triggerId, db)
    local lores = getLoreBooks(triggerId, db)

    if #lores == 0 then
        debug(1, "loadDB error: lorebook '" .. db .. "' not found.")
        return nil
    end

    local merged = {}
    local loadedCount = 0

    for _, lore in ipairs(lores) do
        local ok, decoded = pcall(json.decode, lore.content)

        if not ok or decoded == nil then
            debug(1, "loadDB error: invalid json in lorebook '" .. db .. "'.")
            return nil
        end

        if type(decoded) ~= "table" then
            return decoded
        end

        loadedCount = loadedCount + 1
        for k, v in pairs(decoded) do
            if type(k) == "number" then
                table.insert(merged, v)
            else
                merged[k] = v
            end
        end
    end

    if loadedCount == 0 then
        return nil
    end

    return merged
end

--변수를 로어북으로 저장
function saveDB(triggerId, name, data, ...)
    if data == nil then
        debug(1, "saveDB error: data is nil.")
        return
    end
    upsertLocalLoreBook(triggerId, name, json.encode(data), ...)
    debug(2, "saveDB: "..name.." saved successfully.")
    debug(3, name, json.encode(data))
end

--구분자로 문자열을 나누어 return
function splitByDelimiter(text, delimiter)
    local result = {}
    local source = tostring(text or "")
    local startIndex = 1

    while true do
        local foundStart, foundEnd = string.find(source, delimiter, startIndex, true)

        if not foundStart then
            table.insert(result, string.sub(source, startIndex))
            break
        end

        table.insert(result, string.sub(source, startIndex, foundStart - 1))
        startIndex = foundEnd + 1
    end

    return result
end

local function controllerSucceeded(label, report)
    if type(report) ~= "table" then
        debug(1, label .. ": battleController가 결과를 반환하지 않았습니다.")
        return false
    end
    if report.ok == true then
        return true
    end

    local errors = type(report.errors) == "table" and report.errors or {}
    if #errors == 0 then
        debug(1, label .. ": battleController가 상세 오류 없이 실패했습니다.")
        return false
    end
    for _, item in ipairs(errors) do
        if type(item) == "table" then
            debug(
                1,
                label
                    .. ": " .. tostring(item.code)
                    .. " at " .. tostring(item.path)
                    .. ": " .. tostring(item.message)
            )
        else
            debug(1, label .. ": " .. tostring(item))
        end
    end
    return false
end

--플레이 시작시 한번만 작동
listenEdit("editDisplay", function(triggerId, data)
    --최초 한번만 작동해서 init.lua를 통해 기초 변수들을 설정하도록 할것.
end)

--전투 중 비어 있지 않은 입력도 빈 전송 filler로 정규화
listenEdit("editInput", function(triggerId, data)
    local readOk, authority = pcall(
        getState,
        triggerId,
        "battleRuntimeV1.authority"
    )
    if readOk
        and type(authority) == "table"
        and authority.kind == "battleState" then
        return "*says nothing*"
    end
    return data
end)

--버튼 클릭시 동작
onButtonClick = async(function(triggerId, data)
    --risu-btn 값을 "스크립트|인자1|인자2" 형식으로 해석
    print("Button clicked: " .. tostring(data))

    local parts = splitByDelimiter(data, "|")
    local script = table.remove(parts, 1)

    if not script or script == "" then
        debug(1, "button dispatch error: empty script.")
        return
    end

    runScript(triggerId, script, table.unpack(parts))
end)

--정상 요청에 저장된 비공개 턴 사건을 추가
listenEdit("editRequest", function(triggerId, data)
    local report = runScript(
        triggerId,
        "battleController",
        "injectRequest",
        data
    )
    if not controllerSucceeded("editRequest", report) then
        return data
    end
    if type(report.promptArray) ~= "table" then
        debug(1, "editRequest: 주입된 promptArray가 없습니다.")
        return data
    end
    return report.promptArray
end)

--수동 전송의 턴 준비·실패 복구·commit-only 복구
onStart = async(function(triggerId)
    local report = runScript(
        triggerId,
        "battleController",
        "prepareGeneration"
    )
    if not controllerSucceeded("onStart", report) then
        return false
    end

    -- 관측된 출력을 보존하고 commit만 복구한 경우 새 HTTP 요청은 취소한다.
    return report.generationReady == true
end)

--완성 응답을 관측한 뒤 턴을 한 번만 확정
onOutput = async(function(triggerId)
    local report = runScript(
        triggerId,
        "battleController",
        "commitOutput"
    )
    controllerSucceeded("onOutput", report)
end)

--[[
게임 시작시 필요한 db를 챗변수로 저장하는 프로세스 필요
    퍼메를 세팅용으로 구성하고 세팅이 완료되기 전에는 onStart에서 return false로 채팅 보내는것을 막을 것.
]]
