(function(triggerId, action, ...)
    local SCHEMA_VERSION = 1
    local ALGORITHM = "tokyo_subway_segment_v1"
    local MIN_TURNS = 7
    local MAX_TURNS = 12
    local SEED_MODULUS = 2147483646
    local ROUTE_DOMAIN_OFFSET = 130363
    local MAX_SAFE_INTEGER = 9007199254740991

    local function makeError(code, path, message)
        return {
            code = code,
            path = path,
            message = message,
        }
    end

    local function failure(errors)
        return {
            ok = false,
            schemaVersion = SCHEMA_VERSION,
            algorithm = ALGORITHM,
            errors = errors,
        }
    end

    local function success(value)
        value.ok = true
        value.schemaVersion = SCHEMA_VERSION
        value.algorithm = ALGORITHM
        value.errors = {}
        return value
    end

    local function isSafeInteger(value, minimum)
        return type(value) == "number"
            and value == value
            and value ~= math.huge
            and value ~= -math.huge
            and value % 1 == 0
            and math.abs(value) <= MAX_SAFE_INTEGER
            and (minimum == nil or value >= minimum)
    end

    local function normalizeStaticData(staticData)
        if type(staticData) == "table" and type(staticData.data) == "table" then
            return staticData.data
        end
        return staticData
    end

    local function deriveRouteSeed(seed)
        local normalized = seed % SEED_MODULUS
        return ((normalized + ROUTE_DOMAIN_OFFSET) % SEED_MODULUS) + 1
    end

    local function sortedKeys(collection)
        local keys = {}
        for key in pairs(type(collection) == "table" and collection or {}) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        return keys
    end

    local function copyArray(source)
        local copy = {}
        for index, value in ipairs(source or {}) do
            copy[index] = value
        end
        return copy
    end

    local function nextInteger(rng, minimum, maximum, path)
        if type(runScript) ~= "function" then
            return nil, nil, makeError(
                "runtime_unavailable",
                "$.runtime.deterministicRng",
                "여정 추첨에 필요한 결정적 RNG를 호출할 수 없습니다."
            )
        end
        local ok, report = pcall(
            runScript,
            triggerId,
            "deterministicRng",
            "nextInteger",
            rng,
            minimum,
            maximum
        )
        if not ok then
            return nil, nil, makeError(
                "rng_call_failed",
                "$.runtime.deterministicRng",
                "여정 추첨 RNG 호출에 실패했습니다: " .. tostring(report)
            )
        end
        if type(report) ~= "table" or report.ok ~= true
            or not isSafeInteger(report.value, minimum)
            or report.value > maximum
            or type(report.rng) ~= "table"
            or report.rng.seed ~= rng.seed
            or not isSafeInteger(report.rng.cursor, rng.cursor + 1) then
            return nil, nil, makeError(
                "invalid_rng_result",
                path,
                "여정 추첨 RNG가 올바른 값과 다음 상태를 반환하지 않았습니다."
            )
        end
        return report.value, report.rng, nil
    end

    local function linearCandidates(routePath, turnLimit)
        local candidates = {}
        local stations = routePath.stations
        local lastStart = #stations - turnLimit
        if lastStart < 1 then
            return candidates
        end
        for startIndex = 1, lastStart do
            local forward = {}
            local reverse = {}
            for offset = 0, turnLimit do
                forward[#forward + 1] = stations[startIndex + offset].id
                reverse[#reverse + 1] = stations[startIndex + turnLimit - offset].id
            end
            candidates[#candidates + 1] = forward
            candidates[#candidates + 1] = reverse
        end
        return candidates
    end

    local function circularCandidates(routePath, turnLimit)
        local candidates = {}
        local stations = routePath.stations
        local stationCount = #stations
        if stationCount < turnLimit + 1 then
            return candidates
        end
        for startIndex = 1, stationCount do
            for _, direction in ipairs({ 1, -1 }) do
                local stationIds = {}
                local cursor = startIndex
                for _ = 0, turnLimit do
                    stationIds[#stationIds + 1] = stations[cursor].id
                    cursor = ((cursor - 1 + direction) % stationCount) + 1
                end
                candidates[#candidates + 1] = stationIds
            end
        end
        return candidates
    end

    local function collectLineCandidates(line, turnLimit)
        local candidates = {}
        for _, routePath in ipairs(type(line) == "table" and line.paths or {}) do
            local pathCandidates
            if routePath.circular == true then
                pathCandidates = circularCandidates(routePath, turnLimit)
            else
                pathCandidates = linearCandidates(routePath, turnLimit)
            end
            for _, stationIds in ipairs(pathCandidates) do
                candidates[#candidates + 1] = {
                    pathId = routePath.id,
                    stationIds = stationIds,
                }
            end
        end
        return candidates
    end

    local function build(seed, staticInput, requestedTurnLimit)
        if not isSafeInteger(seed, 0) then
            return failure({
                makeError("invalid_seed", "$.seed", "여정 생성 seed는 0 이상의 안전 정수여야 합니다."),
            })
        end
        if not isSafeInteger(requestedTurnLimit, MIN_TURNS) or requestedTurnLimit > MAX_TURNS then
            return failure({
                makeError("invalid_turn_limit", "$.turnLimit", "제한 턴은 7 이상 12 이하의 정수여야 합니다."),
            })
        end
        local staticData = normalizeStaticData(staticInput)
        local subwayLines = type(staticData) == "table" and staticData.subwayLines or nil
        if type(subwayLines) ~= "table" or next(subwayLines) == nil then
            return failure({
                makeError("missing_subway_lines", "$.staticData.subwayLines", "여정 생성에 필요한 지하철 노선 DB가 없습니다."),
            })
        end

        local rng = {
            seed = deriveRouteSeed(seed),
            cursor = 0,
        }
        local turnLimit, nextRng, rngError = nextInteger(
            rng,
            requestedTurnLimit,
            requestedTurnLimit,
            "$.turnLimit"
        )
        if rngError then
            return failure({ rngError })
        end
        rng = nextRng

        local eligible = {}
        for _, lineId in ipairs(sortedKeys(subwayLines)) do
            local candidates = collectLineCandidates(subwayLines[lineId], turnLimit)
            if #candidates > 0 then
                eligible[#eligible + 1] = {
                    lineId = lineId,
                    candidates = candidates,
                }
            end
        end
        if #eligible == 0 then
            return failure({
                makeError("no_eligible_subway_line", "$.staticData.subwayLines", "추첨된 턴 수에 맞는 지하철 노선이 없습니다."),
            })
        end

        local lineIndex
        lineIndex, nextRng, rngError = nextInteger(
            rng,
            1,
            #eligible,
            "$.lineIndex"
        )
        if rngError then
            return failure({ rngError })
        end
        rng = nextRng
        local selectedLine = eligible[lineIndex]

        local candidateIndex
        candidateIndex, nextRng, rngError = nextInteger(
            rng,
            1,
            #selectedLine.candidates,
            "$.candidateIndex"
        )
        if rngError then
            return failure({ rngError })
        end
        rng = nextRng
        local selected = selectedLine.candidates[candidateIndex]

        return success({
            turnLimit = turnLimit,
            transit = {
                algorithm = ALGORITHM,
                lineId = selectedLine.lineId,
                stationIds = copyArray(selected.stationIds),
            },
            receipt = {
                routeSeed = rng.seed,
                rngCursor = rng.cursor,
                pathId = selected.pathId,
                eligibleLineCount = #eligible,
                candidateCount = #selectedLine.candidates,
            },
        })
    end

    local arguments = { ... }
    if action == "build" then
        return build(arguments[1], arguments[2], arguments[3])
    end
    return failure({
        makeError("unknown_action", "$.action", "지원하지 않는 지하철 여정 작업입니다: " .. tostring(action)),
    })
end)
