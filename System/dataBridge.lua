(function(triggerId, action, ...)
    local WIRE_FORMAT = "cbs-json-nodes-v1"
    local SUPPORTED_VIEWS = {
        battleView = {
            moduleName = "viewBuilder",
            action = "validateBattleView",
            errorCode = "battle_view_invalid",
            errorMessage = "battleView 스키마 검증에 실패했습니다.",
            validatorMessage = "viewBuilder.validateBattleView 검증을 통과하지 못했습니다.",
        },
        gameSetupView = {
            moduleName = "gameSetupView",
            action = "validate",
            errorCode = "game_setup_view_invalid",
            errorMessage = "gameSetupView 스키마 검증에 실패했습니다.",
            validatorMessage = "gameSetupView.validate 검증을 통과하지 못했습니다.",
        },
        runProgressionView = {
            moduleName = "runProgressionView",
            action = "validate",
            errorCode = "run_progression_view_invalid",
            errorMessage = "runProgressionView 스키마 검증에 실패했습니다.",
            validatorMessage = "runProgressionView.validate 검증을 통과하지 못했습니다.",
        },
    }

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
            wireFormat = WIRE_FORMAT,
            errors = errors,
        }
    end

    local function isFinite(value)
        return value == value
            and value ~= math.huge
            and value ~= -math.huge
    end

    local function objectPath(path, key)
        if string.match(key, "^[A-Za-z_][A-Za-z0-9_]*$") then
            return path .. "." .. key
        end
        return path .. "[" .. string.format("%q", key) .. "]"
    end

    local function inspectTable(value, path, errors)
        local numericKeys = {}
        local stringKeys = {}
        local hasNumeric = false
        local hasString = false
        local hasInvalid = false
        local maximum = 0

        for key in pairs(value) do
            local keyType = type(key)
            if keyType == "number" then
                hasNumeric = true
                table.insert(numericKeys, key)
                if not isFinite(key) or key < 1 or key % 1 ~= 0 then
                    hasInvalid = true
                    table.insert(
                        errors,
                        makeError(
                            "invalid_array_index",
                            path,
                            "배열 인덱스는 1 이상의 유한한 정수여야 합니다: " .. tostring(key)
                        )
                    )
                elseif key > maximum then
                    maximum = key
                end
            elseif keyType == "string" then
                hasString = true
                table.insert(stringKeys, key)
            else
                hasInvalid = true
                table.insert(
                    errors,
                    makeError(
                        "invalid_object_key",
                        path,
                        "객체 키는 문자열이어야 합니다: " .. keyType
                    )
                )
            end
        end

        if hasNumeric and hasString then
            hasInvalid = true
            table.insert(
                errors,
                makeError(
                    "mixed_table",
                    path,
                    "숫자 인덱스와 문자열 키를 같은 테이블에서 함께 사용할 수 없습니다."
                )
            )
        end

        if hasInvalid then
            return nil
        end

        if hasNumeric then
            if #numericKeys ~= maximum then
                table.insert(
                    errors,
                    makeError(
                        "sparse_array",
                        path,
                        "배열 인덱스는 1부터 빈틈없이 이어져야 합니다."
                    )
                )
                return nil
            end
            return "array", maximum
        end

        if hasString then
            table.sort(stringKeys)
            return "object", stringKeys
        end

        -- Lua의 빈 테이블은 형상을 구분할 수 없으므로 이 브리지에서는 빈 배열이다.
        return "array", 0
    end

    local function validateJsonSafe(root)
        local errors = {}
        local active = {}

        local function visit(value, path)
            local valueType = type(value)

            if valueType == "string" or valueType == "boolean" then
                return
            end

            if valueType == "number" then
                if not isFinite(value) then
                    table.insert(
                        errors,
                        makeError("non_finite_number", path, "숫자는 NaN이나 무한대일 수 없습니다.")
                    )
                end
                return
            end

            if valueType ~= "table" then
                table.insert(
                    errors,
                    makeError(
                        "unsupported_type",
                        path,
                        "JSON View에 저장할 수 없는 자료형입니다: " .. valueType
                    )
                )
                return
            end

            if getmetatable(value) ~= nil then
                table.insert(
                    errors,
                    makeError("metatable_not_allowed", path, "View 테이블에는 메타테이블을 사용할 수 없습니다.")
                )
                return
            end

            if active[value] then
                table.insert(
                    errors,
                    makeError(
                        "circular_reference",
                        path,
                        "순환 참조가 있는 테이블은 직렬화할 수 없습니다."
                    )
                )
                return
            end

            active[value] = true
            local kind, shape = inspectTable(value, path, errors)

            if kind == "array" then
                for index = 1, shape do
                    visit(value[index], path .. "[" .. index .. "]")
                end
            elseif kind == "object" then
                for _, key in ipairs(shape) do
                    visit(value[key], objectPath(path, key))
                end
            end

            active[value] = nil
        end

        if type(root) ~= "table" then
            table.insert(
                errors,
                makeError("invalid_view_root", "$", "View의 최상위 값은 테이블이어야 합니다.")
            )
        else
            visit(root, "$")
        end

        return errors
    end

    local function appendSchemaErrors(target, schemaResult, config)
        if type(schemaResult) == "table" and type(schemaResult.errors) == "table" then
            for index, schemaError in ipairs(schemaResult.errors) do
                if type(schemaError) == "table" then
                    table.insert(
                        target,
                        makeError(
                            tostring(schemaError.code or config.errorCode),
                            tostring(schemaError.path or "$"),
                            tostring(schemaError.message or config.errorMessage)
                        )
                    )
                else
                    table.insert(
                        target,
                        makeError(
                            config.errorCode,
                            "$",
                            config.errorMessage .. " 오류 " .. index .. ": " .. tostring(schemaError)
                        )
                    )
                end
            end
        end

        if #target == 0 then
            table.insert(
                target,
                makeError(
                    config.errorCode,
                    "$",
                    config.validatorMessage
                )
            )
        end
    end

    local function validateView(viewName, view)
        local config = SUPPORTED_VIEWS[viewName]
        if config == nil then
            return failure({
                makeError(
                    "unsupported_view",
                    "$",
                    "지원하지 않는 View입니다: " .. tostring(viewName)
                ),
            })
        end

        local errors = validateJsonSafe(view)
        if #errors > 0 then
            return failure(errors)
        end

        if type(runScript) ~= "function" then
            return failure({
                makeError(
                    "view_validator_unavailable",
                    "$.runtime." .. config.moduleName,
                    "View 스키마 검증기를 호출할 수 없습니다."
                ),
            })
        end
        local callOk, schemaResult = pcall(
            runScript,
            triggerId,
            config.moduleName,
            config.action,
            view
        )
        if not callOk then
            return failure({
                makeError(
                    "view_validator_call_failed",
                    "$.runtime." .. config.moduleName,
                    "View 스키마 검증기 호출에 실패했습니다: " .. tostring(schemaResult)
                ),
            })
        end
        local schemaPassed = schemaResult == true
            or (type(schemaResult) == "table" and schemaResult.ok == true)

        if not schemaPassed then
            appendSchemaErrors(errors, schemaResult, config)
            return failure(errors)
        end

        return {
            ok = true,
            wireFormat = WIRE_FORMAT,
        }
    end

    local function encodeJsonString(value, protectCbsSyntax)
        local parts = { '"' }

        for index = 1, #value do
            local byte = string.byte(value, index)
            local character = string.char(byte)

            if byte == 34 then
                table.insert(parts, '\\"')
            elseif byte == 92 then
                table.insert(parts, "\\\\")
            elseif byte == 8 then
                table.insert(parts, "\\b")
            elseif byte == 12 then
                table.insert(parts, "\\f")
            elseif byte == 10 then
                table.insert(parts, "\\n")
            elseif byte == 13 then
                table.insert(parts, "\\r")
            elseif byte == 9 then
                table.insert(parts, "\\t")
            elseif byte < 32 then
                table.insert(parts, string.format("\\u%04X", byte))
            elseif protectCbsSyntax and character == ":" then
                table.insert(parts, "\\u003A")
            elseif protectCbsSyntax and character == "{" then
                table.insert(parts, "\\u007B")
            elseif protectCbsSyntax and character == "}" then
                table.insert(parts, "\\u007D")
            else
                table.insert(parts, character)
            end
        end

        table.insert(parts, '"')
        return table.concat(parts)
    end

    local function encodeNumber(value)
        -- IEEE-754 double 값을 JSON으로 왕복할 수 있는 유효 자릿수를 유지한다.
        local encoded = string.format("%.17g", value)
        if encoded == "-0" then
            return "0"
        end
        return encoded
    end

    local HTML_TEXT_ENTITIES = {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;",
        ["'"] = "&#39;",
        ["{"] = "&#123;",
        ["}"] = "&#125;",
        ["("] = "&#40;",
        [")"] = "&#41;",
        [":"] = "&#58;",
    }

    local function escapeHtmlText(value)
        local escaped = string.gsub(value, "[&<>\"'{}():]", function(character)
            return HTML_TEXT_ENTITIES[character]
        end)

        -- RisuAI는 Markdown 렌더링 뒤 U+E9B8..U+E9BF를 자체 escape
        -- 문자로 복원한다. 원본 표시 문자열의 같은 private-use 문자가
        -- 그 경계에 소비되지 않도록 브라우저 단계까지 숫자 엔티티로 둔다.
        for offset = 0, 7 do
            local character = string.char(238, 166, 184 + offset)
            local entity = "&#" .. tostring(59832 + offset) .. ";"
            escaped = string.gsub(escaped, character, entity)
        end

        return escaped
    end

    local encodeTable

    local function encodeScalar(value)
        local valueType = type(value)
        if valueType == "string" then
            -- battleView wire is consumed inside an HTML/CBS template.  Encode
            -- display text as entities before JSON quoting so allowed HTML tags
            -- cannot change the template structure and a decoded CBS result
            -- cannot introduce a fresh CBS directive or :: sequence.
            return encodeJsonString(escapeHtmlText(value), true)
        elseif valueType == "number" then
            return encodeNumber(value)
        elseif valueType == "boolean" then
            return value and "true" or "false"
        elseif valueType == "nil" then
            return "null"
        end
        error("validated View contained an unsupported scalar: " .. valueType)
    end

    local function encodeChild(value)
        if type(value) == "table" then
            -- 중첩 노드는 자신의 JSON을 문자열로 한 층 감싸 CBS가 한 단계씩 읽게 한다.
            return encodeJsonString(encodeTable(value), true)
        end
        return encodeScalar(value)
    end

    encodeTable = function(value)
        local classificationErrors = {}
        local kind, shape = inspectTable(value, "$", classificationErrors)
        if not kind then
            error("validated View table shape changed before encoding")
        end

        local parts = {}
        if kind == "array" then
            for index = 1, shape do
                table.insert(parts, encodeChild(value[index]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        for _, key in ipairs(shape) do
            table.insert(parts, encodeJsonString(key, true) .. ":" .. encodeChild(value[key]))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    local function encodeValidatedView(viewName, view)
        local ok, encoded = pcall(encodeTable, view)
        if not ok then
            return failure({
                makeError("encode_failed", "$", "View 직렬화에 실패했습니다: " .. tostring(encoded)),
            })
        end

        return {
            ok = true,
            wireFormat = WIRE_FORMAT,
            encoded = encoded,
            bytes = #encoded,
        }
    end

    local function encodeView(viewName, view)
        local validation = validateView(viewName, view)
        if not validation.ok then
            return validation
        end
        return encodeValidatedView(viewName, view)
    end

    local function authorizeCanonical(permit, viewName)
        if type(permit) ~= "function" then
            return false
        end
        local ok, allowed = pcall(permit, "dataBridgeCanonicalV1", viewName)
        return ok and allowed == true
    end

    local function encodeCanonicalView(viewName, view, permit)
        if SUPPORTED_VIEWS[viewName] == nil then
            return failure({
                makeError("unsupported_view", "$", "지원하지 않는 View입니다: " .. tostring(viewName)),
            })
        end
        if not authorizeCanonical(permit, viewName) then
            return failure({
                makeError("internal_action_denied", "$.action", "검증된 View 전용 내부 작업에 접근할 수 없습니다."),
            })
        end

        -- 이 경로는 같은 controller transaction에서 공식 View builder가
        -- 이미 schema allowlist를 검증한 값만 받는다. JSON-safe 검사는
        -- 유지해 함수, 메타테이블, 순환 참조가 bridge 밖으로 나가지 않게 한다.
        local errors = validateJsonSafe(view)
        if #errors > 0 then
            return failure(errors)
        end
        return encodeValidatedView(viewName, view)
    end

    local function publishView(viewName, view)
        local result = encodeView(viewName, view)
        if not result.ok then
            return result
        end

        local writeOk, writeError = pcall(setChatVar, triggerId, viewName, result.encoded)
        if not writeOk then
            return failure({
                makeError(
                    "publish_failed",
                    "$",
                    "View 채팅 변수 저장에 실패했습니다: " .. tostring(writeError)
                ),
            })
        end

        return result
    end

    local function publishCanonicalView(viewName, view, permit)
        local result = encodeCanonicalView(viewName, view, permit)
        if not result.ok then
            return result
        end

        local writeOk, writeError = pcall(setChatVar, triggerId, viewName, result.encoded)
        if not writeOk then
            return failure({
                makeError(
                    "publish_failed",
                    "$",
                    "View 채팅 변수 저장에 실패했습니다: " .. tostring(writeError)
                ),
            })
        end
        return result
    end

    local arguments = { ... }
    local viewName = arguments[1]
    local view = arguments[2]

    if action == "_encodeCanonical" then
        return encodeCanonicalView(viewName, view, arguments[3])
    elseif action == "_publishCanonical" then
        return publishCanonicalView(viewName, view, arguments[3])
    end

    local actions = {
        validate = validateView,
        encode = encodeView,
        publish = publishView,
    }

    local handler = actions[action]
    if not handler then
        return failure({
            makeError(
                "unknown_action",
                "$",
                "지원하지 않는 데이터 브리지 작업입니다: " .. tostring(action)
            ),
        })
    end

    return handler(viewName, view)
end)
