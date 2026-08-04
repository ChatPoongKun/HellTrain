(function()
    local installed = false
    local baseRunScript = nil
    local turnInitializationDepth = 0

    local function isFinite(value)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
    end

    local function isInteger(value, minimum)
        return isFinite(value)
            and value % 1 == 0
            and (minimum == nil or value >= minimum)
    end

    local function copyTable(value)
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = item
        end
        return copy
    end

    -- 완료 이력은 직전 턴의 finish를 기록한다. 다음 턴 초기화 중에는
    -- turn_start 효과가 현재 은폐·저항·무드를 합법적으로 바꿀 수 있으므로,
    -- battleHistory의 연속성 비교에만 직전 finish를 투영한다. 실제 state는
    -- 바꾸지 않으며 stateSchema의 나머지 검증은 원본 state를 계속 검사한다.
    local function projectHistoryValidationState(history, state)
        if type(history) ~= "table"
            or type(history.turns) ~= "table"
            or type(state) ~= "table"
            or state.status ~= "active"
            or not isInteger(state.turnNumber, 1) then
            return state, false
        end

        local turnCount = #history.turns
        if turnCount == 0 or state.turnNumber ~= turnCount + 1 then
            return state, false
        end

        local last = history.turns[turnCount]
        local finish = type(last) == "table" and last.finish or nil
        if type(finish) ~= "table"
            or state.lastCommittedTurnId ~= last.turnId
            or not isFinite(finish.stealth)
            or not isFinite(finish.resistance)
            or type(finish.mood) ~= "string"
            or finish.status ~= "active"
            or type(state.player) ~= "table"
            or type(state.character) ~= "table" then
            return state, false
        end

        -- 최종 turnStartReceipt가 이미 만들어진 단계에서는 baseline 자체가
        -- 직전 finish와 정확히 연결된 경우에만 투영을 허용한다.
        local receipt = state.turnStartReceipt
        if receipt ~= nil then
            local baseline = type(receipt) == "table" and receipt.baseline or nil
            if type(baseline) ~= "table"
                or baseline.stealth ~= finish.stealth
                or baseline.resistance ~= finish.resistance
                or baseline.mood ~= finish.mood then
                return state, false
            end
        end

        local projected = copyTable(state)
        projected.player = copyTable(state.player)
        projected.character = copyTable(state.character)
        projected.player.stealth = finish.stealth
        projected.character.resistance = finish.resistance
        projected.character.mood = finish.mood
        return projected, true
    end

    local function callBaseProtected(triggerId, script, arguments)
        local packed = table.pack(pcall(
            baseRunScript,
            triggerId,
            script,
            table.unpack(arguments, 1, arguments.n)
        ))
        if not packed[1] then
            error(packed[2], 0)
        end
        return table.unpack(packed, 2, packed.n)
    end

    local function guardedRunScript(triggerId, script, ...)
        local arguments = table.pack(...)
        local action = arguments[1]

        if script == "turnInitializer" and action == "prepareTurn" then
            turnInitializationDepth = turnInitializationDepth + 1
            local packed = table.pack(pcall(
                callBaseProtected,
                triggerId,
                script,
                arguments
            ))
            turnInitializationDepth = turnInitializationDepth - 1
            if not packed[1] then
                error(packed[2], 0)
            end
            return table.unpack(packed, 2, packed.n)
        end

        if turnInitializationDepth > 0
            and script == "battleHistory"
            and action == "validate" then
            local projected, applied = projectHistoryValidationState(
                arguments[2],
                arguments[3]
            )
            if applied then
                arguments[3] = projected
            end
        end

        return baseRunScript(
            triggerId,
            script,
            table.unpack(arguments, 1, arguments.n)
        )
    end

    return function(_, action)
        if action == "install" then
            if installed then
                return true
            end
            if type(runScript) ~= "function" then
                error("runtimePolicy install requires runScript")
            end
            baseRunScript = runScript
            runScript = guardedRunScript
            installed = true
            return true
        elseif action == "diagnostics" then
            return {
                installed = installed,
                turnInitializationDepth = turnInitializationDepth,
            }
        end
        error("unsupported runtimePolicy action: " .. tostring(action))
    end
end)()
