(function (triggerId, characterName)
    local uiLoad = getChatVar(triggerId, "🔯🔯🔯") or ""
    local uiAppend = loadLores(triggerId, "캐릭터 프로필.html")
    local uiBuilder = uiLoad .. uiAppend
    setChatVar(triggerId, "🔯🔯🔯", uiBuilder)
end)
