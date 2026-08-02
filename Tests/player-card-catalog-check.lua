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
        chunk, loadError = loader(source, "@" .. path, "t", { pairs = pairs })
    end
    assert(chunk, loadError)
    return chunk()
end

local database = loadModule("DB/PlayerCards.db")
assert(database.schemaVersion == 1)
assert(database.kind == "cardDatabase")
assert(type(database.cards) == "table")

local expectedIds = {
    "p002_trail_off",
    "p004_measure_distance",
    "p005_safe_topic",
    "p007_keep_composure",
    "p008_change_the_mood",
    "p009_agree_along",
    "p010_empathetic_opening",
    "p011_quiet_agreement",
    "p012_mirror_emotion",
    "p014_room_to_breathe",
    "p015_circle_of_trust",
    "p016_put_at_ease",
    "p017_turn_suspicion",
    "p018_draw_line_approach",
    "p020_steady_gaze",
    "p021_room_for_misunderstanding",
    "p024_stay_calm_to_end",
    "p025_silent_promise",
    "p026_shaken_balance",
    "p027_emotional_fuse",
    "p028_no_retreat_conversation",
    "p029_answer_at_next_stop",
    "p031_rewind_impression",
    "p033_read_hidden_reaction",
    "p034_analyze_tone",
    "p035_direction_of_gaze",
    "p036_question_for_reaction",
    "p038_silent_understanding",
    "p039_catch_contradiction",
    "p041_break_balance",
    "p043_push_past_limit",
    "p044_no_time_to_breathe",
    "p045_lowered_guard",
    "p047_unhesitating_touch",
}

local expected = {}
for _, cardId in ipairs(expectedIds) do
    expected[cardId] = true
end

local deprecatedIds = {
    "subtle_approach",
    "accidental_brush",
    "play_it_cool",
    "clear_the_air",
    "read_the_room",
    "pin_down",
    "hypnotic_whisper",
    "persistent_press",
    "dangerous_whisper",
    "cut_off_escape",
    "cross_the_line",
}

local validPlayerTags = {
    observation = true,
    approach = true,
    deception = true,
    threat = true,
    contact = true,
    violation = true,
}

local validMechanisms = {
    chain = true,
    remove = true,
    plan = true,
    insight = true,
}

local count = 0
for cardId, card in pairs(database.cards) do
    count = count + 1
    assert(expected[cardId], "unexpected player card: " .. tostring(cardId))
    assert(card.id == cardId)
    assert(card.owner == "player")
    assert(validPlayerTags[card.actionTag], "invalid player action tag: " .. tostring(card.actionTag))
    assert(type(card.description) == "string" and card.description ~= "")
    assert(
        string.find(card.description, "::tag[" .. card.actionTag .. "]::", 1, true),
        "missing action tag token: " .. cardId
    )
    assert(type(card.mechanisms) == "table")
    for _, mechanismId in ipairs(card.mechanisms) do
        assert(validMechanisms[mechanismId], "invalid mechanism: " .. tostring(mechanismId))
        assert(
            string.find(card.description, "::tag[" .. mechanismId .. "]::", 1, true),
            "missing mechanism tag token: " .. cardId .. "/" .. mechanismId
        )
    end
end

assert(count == #expectedIds, "player card count mismatch")
for _, cardId in ipairs(expectedIds) do
    assert(database.cards[cardId], "missing player card: " .. cardId)
end
for _, cardId in ipairs(deprecatedIds) do
    assert(database.cards[cardId] == nil, "deprecated test card remains: " .. cardId)
end

print("player card catalog check: ok")
