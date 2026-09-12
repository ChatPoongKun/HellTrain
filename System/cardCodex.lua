(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local STATE_KEY = "cardCodexV1"
    local VIEW_NAME = "cardCodexView"
    local POPUP_VAR = "helltrainUiPopupV1"

    local function makeError(code, path, message)
        return { code = code, path = path, message = message }
    end

    local function failure(errors)
        return { ok = false, errors = errors }
    end

    local function success(fields)
        local result = { ok = true, errors = {} }
        for key, value in pairs(fields or {}) do result[key] = value end
        return result
    end

    local function loadStaticData()
        local ok, report = pcall(runScript, triggerId, "staticData", "loadAll")
        if not ok or type(report) ~= "table" or report.ok ~= true or type(report.data) ~= "table" then
            return nil, { makeError("static_data_unavailable", "$.staticData", "도감 카드 데이터를 불러오지 못했습니다.") }
        end
        return report.data, nil
    end

    local function emptyState()
        return {
            schemaVersion = SCHEMA_VERSION,
            kind = "cardCodexState",
            playerCardIds = {},
            characterCardIds = {},
            perkIds = {},
        }
    end

    local function addCardId(found, cardId, staticData)
        local card = type(cardId) == "string" and staticData.cards[cardId] or nil
        if type(card) == "table" and (card.owner == "player" or card.owner == "character") then
            found[card.owner][cardId] = true
        end
    end

    local function addPerkId(found, id, staticData)
        found.perks = found.perks or {}
        if type(id)=="string" and staticData.perks and staticData.perks[id] then found.perks[id]=true end
    end

    local function collectCardIds(value, found, staticData, active)
        if type(value) ~= "table" or active[value] then return end
        active[value] = true
        addCardId(found, value.cardId, staticData)
        addPerkId(found,value.perkId,staticData)
        for _,id in ipairs(type(value.perkIds)=="table" and value.perkIds or {}) do addPerkId(found,id,staticData) end
        for _, child in pairs(value) do
            collectCardIds(child, found, staticData, active)
        end
        active[value] = nil
    end

    local function sortedIds(set)
        local result = {}
        for cardId in pairs(set) do result[#result + 1] = cardId end
        table.sort(result)
        return result
    end

    local function arraysEqual(left, right)
        if #left ~= #right then return false end
        for index, value in ipairs(left) do
            if value ~= right[index] then return false end
        end
        return true
    end

    local function normalizeState(stored, staticData)
        local found = { player = {}, character = {} }
        if type(stored) == "table" then
            for _,id in ipairs(stored.perkIds or {}) do addPerkId(found,id,staticData) end
            for _, cardId in ipairs(type(stored.playerCardIds) == "table" and stored.playerCardIds or {}) do
                addCardId(found, cardId, staticData)
            end
            for _, cardId in ipairs(type(stored.characterCardIds) == "table" and stored.characterCardIds or {}) do
                addCardId(found, cardId, staticData)
            end
        end
        local state = emptyState()
        state.playerCardIds = sortedIds(found.player)
        state.characterCardIds = sortedIds(found.character)
        state.perkIds = sortedIds(found.perks or {})
        return state
    end

    local function mergeAndSave(found, staticData)
        local readOk, stored = pcall(HostCompat.readState, triggerId, STATE_KEY)
        if not readOk then
            return nil, { makeError("state_read_failed", "$.state", "도감 발견 기록을 읽지 못했습니다.") }
        end
        local state = normalizeState(stored, staticData)
        for _,id in ipairs(state.perkIds) do addPerkId(found,id,staticData) end
        for _, cardId in ipairs(state.playerCardIds) do found.player[cardId] = true end
        for _, cardId in ipairs(state.characterCardIds) do found.character[cardId] = true end

        local nextState = emptyState()
        nextState.playerCardIds = sortedIds(found.player)
        nextState.characterCardIds = sortedIds(found.character)
        nextState.perkIds = sortedIds(found.perks or {})
        local unchanged = type(stored) == "table"
            and stored.schemaVersion == SCHEMA_VERSION
            and stored.kind == "cardCodexState"
            and type(stored.playerCardIds) == "table"
            and type(stored.characterCardIds) == "table"
            and arraysEqual(stored.playerCardIds, nextState.playerCardIds)
            and arraysEqual(stored.characterCardIds, nextState.characterCardIds)
            and arraysEqual(stored.perkIds or {}, nextState.perkIds)
        if not unchanged then
            local writeOk = pcall(HostCompat.writeState, triggerId, STATE_KEY, nextState)
            if not writeOk then
                return nil, { makeError("state_write_failed", "$.state", "도감 발견 기록을 저장하지 못했습니다.") }
            end
        end
        return nextState, nil
    end

    local function backfillCurrent(found, staticData)
        local function read(name)
            local ok, value = pcall(HostCompat.readState, triggerId, name)
            return ok and type(value) == "table" and value or nil
        end
        local setup = read("gameSetupV1.authority")
        if setup then
            for _, cardId in ipairs(setup.selectedCardIds or {}) do addCardId(found, cardId, staticData) end
            for _, cardId in ipairs(type(setup.offer) == "table" and setup.offer.cardIds or {}) do addCardId(found, cardId, staticData) end
        end
        local run = read("runProgressionV1.authority")
        if run then
            collectCardIds(run,found,staticData,{})
            for _, cardId in ipairs(run.playerCardIds or {}) do addCardId(found, cardId, staticData) end
            for _, cardId in ipairs(type(run.rewardOffer) == "table" and run.rewardOffer.cardIds or {}) do addCardId(found, cardId, staticData) end
        end
        local battle = read("battleRuntimeV1.authority")
        if battle then
            for _, instance in ipairs(battle.cardInstances or {}) do
                if type(instance) == "table" and instance.owner == "player" then
                    addCardId(found, instance.cardId, staticData)
                end
            end
            collectCardIds(battle.history, found, staticData, {})
        end
    end

    local function buildItem(cardId, owner, staticData, path)
        local card = staticData.cards[cardId]
        local ok, presentation = pcall(
            runScript,
            triggerId,
            "viewBuilder",
            "buildCardPresentation",
            card,
            staticData.registry,
            path
        )
        if not ok or type(presentation) ~= "table" or presentation.ok ~= true
            or type(presentation.card) ~= "table" then
            return nil, makeError("card_presentation_failed", path, "도감 카드 표시 정보를 만들지 못했습니다.")
        end
        local summary = presentation.card
        return {
            cardId = summary.cardId,
            name = summary.name,
            owner = owner,
            rarity = card.rarity or "character",
            draftStyle = card.draftStyle or "character",
            descriptionSegments = summary.descriptionSegments,
            ruleLines = summary.ruleLines,
            cardType = summary.cardType,
            roles = summary.roles,
            mechanisms = summary.mechanisms,
            baseStealthCost = card.base.stealthCost,
            baseResistanceDamage = card.base.resistanceDamage,
        }, nil
    end

    local function buildGroup(owner, ids, staticData, errors)
        local items = {}
        local total = 0
        for _, card in pairs(staticData.cards) do
            if card.owner == owner then total = total + 1 end
        end
        for index, cardId in ipairs(ids) do
            local item, itemError = buildItem(cardId, owner, staticData, "$." .. owner .. ".items[" .. index .. "]")
            if itemError then
                errors[#errors + 1] = itemError
            else
                items[#items + 1] = item
            end
        end
        table.sort(items, function(left, right)
            if left.name == right.name then return left.cardId < right.cardId end
            return left.name < right.name
        end)
        return { count = #items, total = total, items = items }
    end

    local function buildView(state, staticData)
        local errors = {}
        local view = {
            schemaVersion = SCHEMA_VERSION,
            kind = "cardCodexView",
            player = buildGroup("player", state.playerCardIds, staticData, errors),
            character = buildGroup("character", state.characterCardIds, staticData, errors),
            perks = {count=#state.perkIds,total=0,items={}},
        }
        for _ in pairs(staticData.perks) do view.perks.total=view.perks.total+1 end
        for _,id in ipairs(state.perkIds) do
            local perk=staticData.perks[id]
            view.perks.items[#view.perks.items+1]={perkId=id,name=perk.name,description=perk.description}
        end
        if #errors > 0 then return nil, errors end
        return view, nil
    end

    local function validateView(view)
        local errors = {}
        if type(view) ~= "table" or view.schemaVersion ~= SCHEMA_VERSION or view.kind ~= "cardCodexView" then
            errors[#errors + 1] = makeError("invalid_card_codex_view", "$", "도감 View 형식이 올바르지 않습니다.")
        else
            local allowed = { schemaVersion = true, kind = true, player = true, character = true, perks=true }
            for key in pairs(view) do
                if allowed[key] ~= true then
                    errors[#errors + 1] = makeError("unknown_card_codex_field", "$", "도감 View에 허용되지 않은 필드가 있습니다.")
                end
            end
        end
        local perks = type(view)=="table" and view.perks
        if type(perks)~="table" or type(perks.items)~="table" or perks.count~=#perks.items
            or type(perks.total)~="number" or perks.total<perks.count then
            errors[#errors+1]=makeError("invalid_codex_perks","$.perks","퍽 도감이 올바르지 않습니다.")
        else
            for _,item in ipairs(perks.items) do
                if type(item)~="table" or type(item.perkId)~="string" or type(item.name)~="string" or type(item.description)~="string" then
                    errors[#errors+1]=makeError("invalid_codex_perk","$.perks.items","퍽 도감 항목이 올바르지 않습니다.")
                end
            end
        end
        for _, owner in ipairs({ "player", "character" }) do
            local group = type(view) == "table" and view[owner] or nil
            if type(group) ~= "table" or type(group.items) ~= "table"
                or group.count ~= #group.items or type(group.total) ~= "number" or group.total < group.count then
                errors[#errors + 1] = makeError("invalid_card_codex_group", "$." .. owner, "도감 카드 묶음이 올바르지 않습니다.")
            else
                local groupAllowed = { count = true, total = true, items = true }
                for key in pairs(group) do
                    if groupAllowed[key] ~= true then
                        errors[#errors + 1] = makeError("unknown_card_codex_group_field", "$." .. owner, "도감 카드 묶음에 허용되지 않은 필드가 있습니다.")
                    end
                end
                for index, item in ipairs(group.items) do
                    if type(item) ~= "table" or item.owner ~= owner or type(item.cardId) ~= "string"
                        or type(item.name) ~= "string" or type(item.descriptionSegments) ~= "table"
                        or type(item.ruleLines) ~= "table" then
                        errors[#errors + 1] = makeError("invalid_card_codex_item", "$." .. owner .. ".items[" .. index .. "]", "도감 카드 항목이 올바르지 않습니다.")
                    else
                        local itemAllowed = {
                            cardId = true, name = true, owner = true, rarity = true, draftStyle = true,
                            descriptionSegments = true, ruleLines = true, cardType = true, roles = true,
                            mechanisms = true, baseStealthCost = true, baseResistanceDamage = true,
                        }
                        for key in pairs(item) do
                            if itemAllowed[key] ~= true then
                                errors[#errors + 1] = makeError("unknown_card_codex_item_field", "$." .. owner .. ".items[" .. index .. "]", "도감 카드 항목에 허용되지 않은 필드가 있습니다.")
                            end
                        end
                    end
                end
            end
        end
        if #errors > 0 then return failure(errors) end
        return success({ valid = true })
    end

    local function permitCanonicalOperation(purpose, viewName)
        return purpose == "dataBridgeCanonicalV1" and viewName == VIEW_NAME
    end

    local function record(value, staticData)
        local staticErrors = nil
        if type(staticData) ~= "table" or type(staticData.cards) ~= "table" then
            staticData, staticErrors = loadStaticData()
        end
        if staticErrors then return failure(staticErrors) end
        local found = { player = {}, character = {} }
        collectCardIds(value, found, staticData, {})
        local state, stateErrors = mergeAndSave(found, staticData)
        if stateErrors then return failure(stateErrors) end
        return success({ state = state })
    end

    local function open()
        local staticData, staticErrors = loadStaticData()
        if staticErrors then return failure(staticErrors) end
        local found = { player = {}, character = {} }
        backfillCurrent(found, staticData)
        local state, stateErrors = mergeAndSave(found, staticData)
        if stateErrors then return failure(stateErrors) end
        local view, viewErrors = buildView(state, staticData)
        if viewErrors then return failure(viewErrors) end
        local validation = validateView(view)
        if validation.ok ~= true then return validation end
        local publishOk, published = pcall(
            runScript,
            triggerId,
            "dataBridge",
            "_publishCanonical",
            VIEW_NAME,
            view,
            permitCanonicalOperation
        )
        if not publishOk or type(published) ~= "table" or published.ok ~= true then
            return failure(type(published) == "table" and published.errors or {
                makeError("view_publish_failed", "$.view", "도감 View를 게시하지 못했습니다."),
            })
        end
        local loadOk, html = pcall(loadLores, triggerId, "도감.html")
        if not loadOk or type(html) ~= "string" or html == "" then
            return failure({ makeError("missing_codex_html", "$.lore", "도감 화면을 불러오지 못했습니다.") })
        end
        local writeOk = pcall(HostCompat.writeChatVar, triggerId, POPUP_VAR, html)
        if not writeOk then
            return failure({ makeError("popup_write_failed", "$.popup", "도감 화면을 게시하지 못했습니다.") })
        end
        return success({ state = state, view = view })
    end

    local arguments = { ... }
    if action == "record" then
        return record(arguments[1], arguments[2])
    elseif action == "validateView" then
        return validateView(arguments[1])
    elseif action == "open" then
        return open()
    elseif action == "selfCheck" then
        local fake = { cards = {
            pc_test = { owner = "player" },
            cc_test = { owner = "character" },
        } }
        local found = { player = {}, character = {} }
        local cyclic = { cardId = "pc_test", nested = { cardId = "cc_test" } }
        cyclic.self = cyclic
        collectCardIds(cyclic, found, fake, {})
        if found.player.pc_test ~= true or found.character.cc_test ~= true then
            return failure({ makeError("self_check_failed", "$", "도감 발견 수집 자체 검증에 실패했습니다.") })
        end
        return success({ valid = true })
    end
    return failure({ makeError("unknown_action", "$.action", "지원하지 않는 도감 작업입니다: " .. tostring(action)) })
end)
