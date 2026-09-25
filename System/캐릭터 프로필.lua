(function(triggerId, characterId)
    local function execute()
        local battle = HostCompat.readState(triggerId, "battleRuntimeV1.authority")
        local setup = HostCompat.readState(triggerId, "gameSetupV1.authority")
        local freeTraining = HostCompat.readState(triggerId, "freeTrainingV1.authority")
        if type(freeTraining) == "table" and type(setup) == "table"
            and freeTraining.setupId ~= setup.setupId then
            freeTraining = nil
        end
        local ids = {}
        if type(battle) == "table" and type(battle.character) == "table" then
            ids[1] = battle.character.characterId
        end
        local built
        if type(freeTraining) == "table" and type(freeTraining.active) == "table"
            and (freeTraining.active.phase == "active" or freeTraining.active.phase == "closing")
            and type(freeTraining.active.journalSnapshot) == "table" then
            local copied, snapshot = pcall(function()
                return json.decode(json.encode(freeTraining.active.journalSnapshot))
            end)
            if not copied or type(snapshot) ~= "table" then
                return { ok = false, errors = { { message = "저장된 캐릭터 기록을 읽지 못했습니다." } } }
            end
            if characterId ~= "list" then
                for _, item in ipairs(snapshot.items or {}) do
                    if type(item.profile) == "table" and item.profile.characterId == characterId then
                        snapshot.selected = item
                        break
                    end
                end
                if snapshot.selected == nil then return { ok = false, errors = { { message = "아직 조우하지 않은 캐릭터입니다." } } } end
            else
                snapshot.selected = nil
            end
            built = runScript(triggerId, "runProgressionView", "validateCharacterJournal", snapshot)
            if built.ok then built = { ok = true, view = snapshot } end
        else
            local data = runScript(triggerId, "staticData", "loadCharacters", ids)
            if not data.ok then return data end
            built = runScript(triggerId, "runProgressionView", "buildCharacterJournal", {
                setupState = setup,
                runState = HostCompat.readState(triggerId, "runProgressionV1.authority"),
                battleState = battle,
                freeTrainingState = freeTraining,
                characterId = characterId ~= "list" and characterId or nil,
            }, data.data)
        end
        if not built.ok then return built end
        local published = runScript(triggerId, "dataBridge", "_publishCanonical", "characterJournalView", built.view,
            function(purpose, name) return purpose == "dataBridgeCanonicalV1" and name == "characterJournalView" end)
        if not published.ok then return published end
        -- HTML 로어의 CBS 평가 전에 View를 게시한다.
        local html = loadLores(triggerId, characterId == "list" and "캐릭터 리스트.html" or "캐릭터 프로필.html")
        if type(html) ~= "string" or html == "" then error("캐릭터 기록 화면을 불러오지 못했습니다.") end
        HostCompat.writeChatVar(triggerId, "helltrainUiPopupV1", html)
        return { ok = true, view = built.view }
    end
    local ok, result = pcall(execute)
    if ok and type(result) == "table" and result.ok then return result end
    debug(1, "캐릭터 기록 조회 실패: " .. tostring(ok and result.errors and result.errors[1] and result.errors[1].message or result))
    HostCompat.writeChatVar(triggerId, "helltrainUiPopupV1",
        '<div class="popup-overlay"><div class="popup-container"><div class="popup-header"><div class="popup-title">캐릭터 기록</div><button class="close-btn" risu-btn="popupManage|close" aria-label="닫기">×</button></div><p>캐릭터 기록을 불러오지 못했습니다. 잠시 후 다시 열어 주세요.</p></div></div>')
    return { ok = false }
end)
