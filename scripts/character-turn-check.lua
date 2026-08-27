local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadLore(path)
    return assert(load("return" .. readFile(path), "@" .. path, "t", _G))()
end

local modules = {
    battleBootstrap = loadLore("System/battleBootstrap.lua"),
    battleHistory = loadLore("System/battleHistory.lua"),
    cardZones = loadLore("System/cardZones.lua"),
    deterministicRng = loadLore("System/deterministicRng.lua"),
    stateSchema = loadLore("System/stateSchema.lua"),
    staticData = loadLore("System/staticData.lua"),
    subwayJourney = loadLore("System/subwayJourney.lua"),
}

function runScript(triggerId, name, ...)
    return assert(modules[name], "unknown module: " .. tostring(name))(triggerId, ...)
end

local lorePaths = {
    ["GameRegistry.db"] = "DB/GameRegistry.db",
    ["PlayerCards.db"] = "DB/PlayerCards.db",
    ["CharacterCards.db"] = "DB/CharacterCards.db",
    ["CharTraits.db"] = "DB/CharTraits.db",
    ["Environments.db"] = "DB/Environments.db",
    ["TokyoSubwayLines.db"] = "DB/TokyoSubwayLines.db",
    ["CharacterList.db"] = "Char/CharacterList.db",
    ["YooJiyoung.db"] = "Char/YooJiyoung.db",
    ["YoonSeoa.db"] = "Char/YoonSeoa.db",
    ["HanJenny.db"] = "Char/HanJenny.db",
    ["SeoMiryeong.db"] = "Char/SeoMiryeong.db",
    ["SisterAgnes.db"] = "Char/SisterAgnes.db",
}

function getLoreBooks(_, name)
    local path = lorePaths[name]
    return path and { { content = readFile(path) } } or {}
end

function loadLores(triggerId, name)
    local chunks = {}
    for _, lore in ipairs(getLoreBooks(triggerId, name)) do
        chunks[#chunks + 1] = lore.content
    end
    return #chunks > 0 and table.concat(chunks) or nil
end

local function assertOk(label, report)
    if type(report) ~= "table" or report.ok ~= true then
        local messages = {}
        for _, item in ipairs(type(report) == "table" and report.errors or {}) do
            messages[#messages + 1] = tostring(item.code) .. " at " .. tostring(item.path)
        end
        error(label .. " failed: " .. table.concat(messages, ", "))
    end
    return report
end

local expected = {
    han_jenny = 8,
    yoo_jiyoung = 9,
    seo_miryeong = 11,
    sister_agnes = 12,
    yoon_seoa = 12,
}
local expectedResistance = {
    han_jenny = 27,
    yoo_jiyoung = 30,
    seo_miryeong = 33,
    sister_agnes = 34,
    yoon_seoa = 36,
}
local expectedMood = {
    han_jenny = "ignore",
    yoo_jiyoung = "ignore",
    seo_miryeong = "suspicion",
    sister_agnes = "suspicion",
    yoon_seoa = "suspicion",
}
local playerCardIds = {
    "p002_whisper_excuse", "p002_whisper_excuse",
    "p004_press_from_behind", "p004_press_from_behind",
    "p005_blame_the_crowd", "p005_blame_the_crowd",
    "p007_feign_indifference", "p007_feign_indifference",
    "p008_reset_with_apology", "p008_reset_with_apology",
}

local data = assertOk("static data", runScript("character-turn-check", "staticData", "loadAll")).data
data.environments.no_environment = {
    id = "no_environment",
    name = "환경 효과 없음",
    description = "고정 턴 통합 검사 전용 환경입니다.",
    rules = {},
    triggers = {},
}
local minimum, maximum = 12, 7
for characterId, turnLimit in pairs(expected) do
    assert(data.characters[characterId].battle.turnLimit == turnLimit, characterId .. " static turn limit mismatch")
    assert(data.characters[characterId].battle.startingResistance == expectedResistance[characterId], characterId .. " starting resistance mismatch")
    assert(data.characters[characterId].battle.startingMood == expectedMood[characterId], characterId .. " starting mood mismatch")
    minimum = math.min(minimum, turnLimit)
    maximum = math.max(maximum, turnLimit)

    local journey = assertOk(
        characterId .. " journey",
        runScript("character-turn-check", "subwayJourney", "build", 20260827, data, turnLimit)
    )
    assert(journey.turnLimit == turnLimit, characterId .. " journey turn limit mismatch")
    assert(#journey.transit.stationIds == turnLimit + 1, characterId .. " journey station count mismatch")

    local battle = assertOk(
        characterId .. " bootstrap",
        runScript("character-turn-check", "battleBootstrap", "fromSetup", {
            battleId = "turn-check-" .. characterId,
            seed = 20260827,
            playerCardIds = playerCardIds,
            characterId = characterId,
            environmentId = "no_environment",
        }, data)
    )
    assert(battle.state.turnLimit == turnLimit, characterId .. " battle turn limit mismatch")
    assert(#battle.state.transit.stationIds == turnLimit + 1, characterId .. " battle station count mismatch")
end

local scan = data.cards.seoa_scan_for_witnesses.resolve({ mood = "suspicion" })
assert(scan[1].op == "lose_stealth" and scan[1].amount == 4, "seoa conditional witness damage mismatch")
local consequences = data.cards.seoa_state_consequences.resolve({ mood = "rejection" })
assert(consequences[1].op == "lose_stealth" and consequences[1].amount == 3, "seoa conditional consequence damage mismatch")
local courage = data.cards.jiyoung_find_courage.resolve({ mood = "suspicion" })
assert(courage[1].op == "lose_stealth" and courage[1].amount == 4, "jiyoung conditional stealth damage changed")
local joke = data.cards.jenny_turn_joke_back.resolve({ mood = "rejection" })
assert(joke[1].op == "lose_stealth" and joke[1].amount == 4, "jenny conditional stealth damage changed")
local publicRebuke = data.cards.miryeong_calm_public_rebuke.resolve({ mood = "suspicion" })
assert(publicRebuke[1].op == "lose_stealth" and publicRebuke[1].amount == 3, "miryeong conditional stealth damage mismatch")
local conscience = data.cards.agnes_invoke_conscience.resolve({ mood = "rejection" })
assert(conscience[1].op == "lose_stealth" and conscience[1].amount == 3, "agnes conditional stealth damage mismatch")
local helpPlan = data.cards.agnes_ask_nearby_passenger.mechanismData.plan
assert(helpPlan.trigger({}, { type = "card_declared", side = "player", actionTag = "contact" }), "agnes help plan must trigger on contact")
assert(not helpPlan.trigger({}, { type = "card_declared", side = "player", actionTag = "deception" }), "agnes help plan must ignore non-contact")
assert(helpPlan.trigger({}, helpPlan.selectionAssumption.event), "agnes help plan selection assumption must remain scorable")

assert(maximum - minimum == 4, "character turn-limit gap changed")
print("character-turn-check: ok (turns, resistance, mood, pressure conditions)")
