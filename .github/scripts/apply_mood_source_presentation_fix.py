from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESENTATION = ROOT / "System" / "turnPresentation.lua"
VIEW = ROOT / "System" / "viewBuilder.lua"
MAIN = ROOT / "System" / "main.lua"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


presentation = PRESENTATION.read_text(encoding="utf-8")
presentation = replace_once(
    presentation,
    '''    local SOURCE_COLLECTIONS = {
        card = "cards",
        plan = "cards",
        trait = "traits",
        perk = "perks",
        environment = "environments",
    }

    local ACTION_STOP_REASONS = {
''',
    '''    local SOURCE_COLLECTIONS = {
        card = "cards",
        plan = "cards",
        trait = "traits",
        perk = "perks",
        environment = "environments",
    }

    local SYSTEM_EFFECT_SOURCES = {
        mood_state = {
            name = "확정 무드",
            description = "턴 종료 시 확정된 무드가 은폐에 미치는 상태 효과입니다.",
            rules = {
                "확정 무드에 따라 은폐가 감소하거나 회복됩니다.",
            },
            tags = {},
        },
    }

    local ACTION_STOP_REASONS = {
''',
    "system effect source definitions",
)
presentation = replace_once(
    presentation,
    '''    local OUTCOME_REASONS = {
        card_checkpoint = true,
        turn_end_checkpoint = true,
        turn_limit = true,
    }
''',
    '''    local OUTCOME_REASONS = {
        card_checkpoint = true,
        turn_end_checkpoint = true,
        mood_state_checkpoint = true,
        turn_limit = true,
    }
''',
    "mood outcome reason",
)
presentation = replace_once(
    presentation,
    '''        local collectionName = SOURCE_COLLECTIONS[source.kind]
        local collection = collectionName and staticData[collectionName] or nil
        local definition = type(collection) == "table" and collection[source.id] or nil
''',
    '''        if source.kind == "system" then
            local definition = type(source.id) == "string" and SYSTEM_EFFECT_SOURCES[source.id] or nil
            if not isAsciiId(source.id) or type(definition) ~= "table" then
                return nil, makeError("unknown_effect_source", path, "효과 원인의 공개 정보를 확인할 수 없습니다.")
            end
            if source.side ~= nil then
                return nil, makeError("invalid_effect_source_side", path .. ".side", "시스템 상태 효과 원인에는 진영이 없어야 합니다.")
            end
            local rules = {}
            for index, rule in ipairs(definition.rules) do rules[index] = rule end
            local tags = {}
            for index, tag in ipairs(definition.tags) do tags[index] = tag end
            return {
                kind = "system",
                name = definition.name,
                description = definition.description,
                rules = rules,
                tags = tags,
            }, nil
        end

        local collectionName = SOURCE_COLLECTIONS[source.kind]
        local collection = collectionName and staticData[collectionName] or nil
        local definition = type(collection) == "table" and collection[source.id] or nil
''',
    "system effect source projection",
)
PRESENTATION.write_text(presentation, encoding="utf-8")

view = VIEW.read_text(encoding="utf-8")
view = replace_once(
    view,
    '''    local SOURCE_KIND_LABELS = {
        card = "카드",
        plan = "계획",
        trait = "특징",
        perk = "퍽",
        environment = "환경",
    }
''',
    '''    local SOURCE_KIND_LABELS = {
        card = "카드",
        plan = "계획",
        trait = "특징",
        perk = "퍽",
        environment = "환경",
        system = "상태 효과",
    }
''',
    "view source kind label",
)
VIEW.write_text(view, encoding="utf-8")

main = MAIN.read_text(encoding="utf-8")
main = replace_once(
    main,
    '    or "runtime-bundle-e4c8b1f09a72d635"\n',
    '    or "runtime-bundle-7f2c19d8a4e653b1"\n',
    "runtime bundle revision",
)
MAIN.write_text(main, encoding="utf-8")
