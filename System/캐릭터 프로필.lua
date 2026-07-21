(function (triggerId, characterName)
    local uiAppend = loadLores(triggerId, "캐릭터 프로필.html")
    if type(uiAppend) ~= "string" or uiAppend == "" then
        debug(1, "캐릭터 프로필 UI를 불러오지 못했습니다: " .. tostring(characterName))
        return
    end
    setChatVar(triggerId, "helltrainUiPopupV1", uiAppend)
end)
