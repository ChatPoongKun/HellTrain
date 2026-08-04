local function loadModule(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()

    local loader = load or loadstring
    local chunk
    local loadError
    if _VERSION == "Lua 5.1" then
        chunk, loadError = loader(source, "@" .. path)
    else
        chunk, loadError = loader(source, "@" .. path, "t", {
            ipairs = ipairs,
            pairs = pairs,
            tonumber = tonumber,
            tostring = tostring,
            type = type,
        })
    end
    assert(chunk, loadError)
    return chunk()
end

local database = loadModule("DB/CharacterCards.db")
local registry = loadModule("DB/GameRegistry.db")
local characterList = loadModule("Char/CharacterList.db")

assert(database.schemaVersion == 1)
assert(database.kind == "cardDatabase")
assert(type(database.cards) == "table")

local expectedByCharacter = {
    seoa = {
        "seoa_document_bag_guard",
        "seoa_measured_warning",
        "seoa_scan_for_witnesses",
        "seoa_cold_stare",
        "seoa_calculated_gaze",
    },
    jenny = {
        "jenny_slip_away_laughing",
        "jenny_phone_camera_feint",
        "jenny_crossed_joke",
        "jenny_fake_livestream",
        "jenny_redirect_attention",
    },
    miryeong = {
        "miryeong_draw_cardigan_closed",
        "miryeong_gentle_boundary",
        "miryeong_move_beside_door",
        "miryeong_draw_line_at_door",
        "miryeong_close_heart",
    },
    agnes = {
        "agnes_cover_with_sleeves",
        "agnes_quiet_admonition",
        "agnes_change_carriage",
        "agnes_ask_nearby_passenger",
        "agnes_complete_break",
    },
}

local expected = {}
local expectedCount = 0
for characterId, cardIds in pairs(expectedByCharacter) do
    assert(#cardIds == 5, "character must have exactly five cards: " .. characterId)
    for _, cardId in ipairs(cardIds) do
        assert(expected[cardId] == nil, "duplicate expected card id: " .. cardId)
        expected[cardId] = characterId
        expectedCount = expectedCount + 1
    end
end
assert(expectedCount == 20)

assert(characterList.schemaVersion == 1)
assert(characterList.kind == "characterList")
assert(type(characterList.characters) == "table")
assert(characterList.characters.yoo_jiyoung == nil, "prototype character remains in manifest")

local characterSources = {
    seoa = {
        characterId = "yoon_seoa",
        database = "YoonSeoa.db",
        path = "Char/YoonSeoa.db",
    },
    jenny = {
        characterId = "han_jenny",
        database = "HanJenny.db",
        path = "Char/HanJenny.db",
    },
    miryeong = {
        characterId = "seo_miryeong",
        database = "SeoMiryeong.db",
        path = "Char/SeoMiryeong.db",
    },
    agnes = {
        characterId = "sister_agnes",
        database = "SisterAgnes.db",
        path = "Char/SisterAgnes.db",
    },
}

local manifestCount = 0
for _ in pairs(characterList.characters) do manifestCount = manifestCount + 1 end
assert(manifestCount == 4, "active character count mismatch")

local assigned = {}
for characterKey, source in pairs(characterSources) do
    local manifest = assert(characterList.characters[source.characterId])
    assert(manifest.id == source.characterId)
    assert(manifest.database == source.database)

    local module = loadModule(source.path)
    assert(module.schemaVersion == 1)
    assert(module.kind == "characterDatabase")
    local character = assert(module.characters[source.characterId])
    local deck = assert(character.battle and character.battle.deck)
    assert(#deck == 5, "character deck must contain five cards: " .. source.characterId)

    local expectedDeck = {}
    for _, cardId in ipairs(expectedByCharacter[characterKey]) do
        expectedDeck[cardId] = true
    end
    for _, cardId in ipairs(deck) do
        assert(expectedDeck[cardId], "unexpected deck card: " .. source.characterId .. "/" .. cardId)
        assert(assigned[cardId] == nil, "character card assigned more than once: " .. cardId)
        assigned[cardId] = source.characterId
    end
end
for cardId in pairs(expected) do
    assert(assigned[cardId] ~= nil, "character card is not assigned to a deck: " .. cardId)
end

local deprecatedIds = {
    "close_collar",
    "quiet_warning",
    "turn_to_corner",
    "silent_glare",
    "jenny_teasing_counter",
    "miryeong_calm_request_for_help",
}

local validCharacterTags = {
    evade = true,
    block = true,
    vigilance = true,
    intimidate = true,
    expose = true,
}

local validMechanisms = {
    plan = true,
    remove = true,
}

local publicTagIds = {}
for tagId, entry in pairs(registry.actionTags) do
    publicTagIds[tagId] = true
    assert(type(entry.label) == "string" and entry.label ~= "")
    assert(not string.find(entry.label, "%a"), "action tag label must be Korean: " .. tagId)
end
for mechanismId, entry in pairs(registry.mechanisms) do
    publicTagIds[mechanismId] = true
    assert(type(entry.label) == "string" and entry.label ~= "")
    assert(not string.find(entry.label, "%a"), "mechanism label must be Korean: " .. mechanismId)
end

local function assertLocalizedString(value, path)
    if type(value) ~= "string" then return end
    local visible = string.gsub(value, "::tag%[[a-z][a-z0-9_]*%]::", "")
    for tagId in pairs(publicTagIds) do
        assert(
            not string.find(visible, "%f[%a]" .. tagId .. "%f[^%a]"),
            "raw tag id leaked into user-facing text: " .. path .. "/" .. tagId
        )
    end
end

local function assertLocalizedValue(value, path)
    if type(value) == "string" then
        assertLocalizedString(value, path)
    elseif type(value) == "table" then
        for key, item in pairs(value) do
            assertLocalizedValue(item, path .. "." .. tostring(key))
        end
    end
end

local function assertCommand(command, op, target, amount, mood)
    assert(type(command) == "table")
    assert(command.op == op, tostring(command.op) .. " ~= " .. op)
    assert(command.target == target)
    assert(command.amount == amount)
    assert(command.mood == mood)
end

local count = 0
local countByCharacter = { seoa = 0, jenny = 0, miryeong = 0, agnes = 0 }

for cardId, card in pairs(database.cards) do
    count = count + 1
    local characterId = expected[cardId]
    assert(characterId ~= nil, "unexpected character card: " .. tostring(cardId))
    countByCharacter[characterId] = countByCharacter[characterId] + 1

    assert(card.id == cardId)
    assert(card.owner == "character")
    assert(card.prototype == nil, "prototype flag remains: " .. cardId)
    assert(validCharacterTags[card.actionTag], "invalid character action tag: " .. tostring(card.actionTag))
    assert(card.base.stealthCost == 0)
    assert(card.base.resistanceDamage == 0)
    assert(card.canPlay == nil, "character card cannot use canPlay: " .. cardId)
    assert(card.effectChoices == nil, "character card cannot use effectChoices: " .. cardId)

    assert(type(card.description) == "string" and card.description ~= "")
    assert(
        string.find(card.description, "::tag[" .. card.actionTag .. "]::", 1, true),
        "missing action tag token: " .. cardId
    )
    assert(type(card.rules) == "table" and #card.rules > 0)

    local hasPlan = false
    local hasRemove = false
    assert(type(card.mechanisms) == "table")
    for _, mechanismId in ipairs(card.mechanisms) do
        assert(validMechanisms[mechanismId], "invalid mechanism: " .. tostring(mechanismId))
        assert(
            string.find(card.description, "::tag[" .. mechanismId .. "]::", 1, true),
            "missing mechanism tag token: " .. cardId .. "/" .. mechanismId
        )
        if mechanismId == "plan" then hasPlan = true end
        if mechanismId == "remove" then hasRemove = true end
    end
    assert(not (hasPlan and hasRemove), "plan and remove cannot coexist: " .. cardId)

    if hasPlan then
        assert(card.resolve == nil, "plan card should not define immediate resolve: " .. cardId)
        local plan = assert(card.mechanismData and card.mechanismData.plan)
        assert(type(plan.durationTurns) == "number" and plan.durationTurns >= 1)
        assert(type(plan.charges) == "number" and plan.charges >= 1)
        local assumption = assert(plan.selectionAssumption)
        assert(assumption.event.type == "card_declared")
        assert(assumption.event.side == "player")
        assert(assumption.chargePolicy == "all")
        assert(plan.trigger({}, { type = "card_declared", side = "player" }) == true)
        assert(plan.trigger({}, { type = "card_declared", side = "character" }) == false)
        assert(type(plan.resolve({}, { type = "card_declared", side = "player" })) == "table")
        assert(type(card.narration.planPlaced) == "table")
        assert(type(card.narration.planTriggered) == "table")
    else
        assert(type(card.resolve) == "function", "missing resolve: " .. cardId)
        assert(type(card.narration.play) == "table")
    end

    assertLocalizedValue(card.description, cardId .. ".description")
    assertLocalizedValue(card.rules, cardId .. ".rules")
    assertLocalizedValue(card.narration, cardId .. ".narration")
end

assert(count == 20, "character card count mismatch")
for characterId, characterCount in pairs(countByCharacter) do
    assert(characterCount == 5, "character card count mismatch: " .. characterId)
end
for cardId in pairs(expected) do
    assert(database.cards[cardId] ~= nil, "missing character card: " .. cardId)
end
for _, cardId in ipairs(deprecatedIds) do
    assert(database.cards[cardId] == nil, "deprecated character card remains: " .. cardId)
end

local calculatedGaze = database.cards.seoa_calculated_gaze.mechanismData.plan.resolve({}, {})
assertCommand(calculatedGaze[1], "lose_stealth", "player", 1, nil)
assertCommand(calculatedGaze[2], "add_mood_token", "character", 1, "suspicion")

local crossedJoke = database.cards.jenny_crossed_joke.resolve({ mood = "ignore" })
assertCommand(crossedJoke[1], "lose_stealth", "player", 1, nil)
assertCommand(crossedJoke[2], "add_mood_token", "character", 1, "suspicion")
assertCommand(crossedJoke[3], "add_mood_token", "character", 1, "confusion")

local redirectAttention = database.cards.jenny_redirect_attention.resolve({ mood = "suspicion" })
assertCommand(redirectAttention[1], "remove_mood_token", "character", 1, "suspicion")
assertCommand(redirectAttention[2], "add_mood_token", "character", 1, "ignore")

local lineAtDoor = database.cards.miryeong_draw_line_at_door.mechanismData.plan.resolve({}, {})
assertCommand(lineAtDoor[1], "add_mood_token", "character", 2, "rejection")

local closeHeartCompliance = database.cards.miryeong_close_heart.resolve({ mood = "compliance" })
assertCommand(closeHeartCompliance[1], "remove_mood_token", "character", 1, "compliance")
assertCommand(closeHeartCompliance[2], "add_mood_token", "character", 2, "rejection")

local closeHeartOther = database.cards.miryeong_close_heart.resolve({ mood = "ignore" })
assertCommand(closeHeartOther[1], "add_mood_token", "character", 1, "rejection")

local completeBreak = database.cards.agnes_complete_break.resolve({ mood = "ignore" })
assertCommand(completeBreak[1], "lose_stealth", "player", 2, nil)
assertCommand(completeBreak[2], "force_mood", "character", nil, "rejection")

print("character card catalog check: ok")
