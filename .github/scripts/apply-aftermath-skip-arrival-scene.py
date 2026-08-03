from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


controller_path = Path("System/battleController.lua")
controller = controller_path.read_text(encoding="utf-8")

controller = replace_once(
    controller,
    '''                    recoveringCleanup = true,
                    skipToDestination = true,
                }''',
    '''                    recoveringCleanup = true,
                    skipToDestination = true,
                    manualSubmitPending = true,
                }''',
    "allow manual submit receipt",
)

controller = replace_once(
    controller,
    '''                if request.skipToDestination ~= nil and request.skipToDestination ~= true then
                    errors[#errors + 1] = makeError("invalid_aftermath_skip_request", path .. ".request.skipToDestination", "목적지 바로가기 요청 표시는 true여야 합니다.")
                end
                validateFingerprint(request.userFingerprint, path .. ".request.userFingerprint", errors)''',
    '''                if request.skipToDestination ~= nil and request.skipToDestination ~= true then
                    errors[#errors + 1] = makeError("invalid_aftermath_skip_request", path .. ".request.skipToDestination", "목적지 바로가기 요청 표시는 true여야 합니다.")
                end
                if request.manualSubmitPending ~= nil and request.manualSubmitPending ~= true then
                    errors[#errors + 1] = makeError("invalid_aftermath_manual_submit", path .. ".request.manualSubmitPending", "수동 전송 대기 표시는 true여야 합니다.")
                elseif request.manualSubmitPending == true
                    and (request.skipToDestination ~= true or value.phase ~= "inFlight") then
                    errors[#errors + 1] = makeError("invalid_aftermath_manual_submit_phase", path .. ".request.manualSubmitPending", "목적지 바로가기의 inFlight 요청만 수동 전송을 기다릴 수 있습니다.")
                end
                validateFingerprint(request.userFingerprint, path .. ".request.userFingerprint", errors)''',
    "validate manual submit receipt",
)

controller = replace_once(
    controller,
    '''                requestInFlight = true,
                status = authority.status,''',
    '''                requestInFlight = true,
                manualSubmitRequired = aftermath.request.manualSubmitPending == true,
                status = authority.status,''',
    "report reused manual submit",
)

controller = replace_once(
    controller,
    '''            attemptNumber = 1,
            skipToDestination = true,
        }''',
    '''            attemptNumber = 1,
            skipToDestination = true,
            manualSubmitPending = true,
        }''',
    "queue manual submit",
)

controller = replace_once(
    controller,
    '''        return success({
            generationReady = true,
            outputCommitted = false,
            aftermathComplete = false,
            aftermath = true,
            skipped = true,
            reused = false,
            skipToDestination = true,
            skippedTurnCount = authority.turnLimit - aftermath.completedTurnNumber,
            turnNumber = aftermath.request.turnNumber,
            attemptNumber = aftermath.request.attemptNumber,
            view = published.view,
        })''',
    '''        return success({
            generationReady = false,
            outputCommitted = false,
            aftermathComplete = false,
            aftermath = true,
            skipped = true,
            reused = false,
            skipToDestination = true,
            manualSubmitRequired = true,
            skippedTurnCount = authority.turnLimit - aftermath.completedTurnNumber,
            turnNumber = aftermath.request.turnNumber,
            attemptNumber = aftermath.request.attemptNumber,
            view = published.view,
        })''',
    "queue result",
)

controller = replace_once(
    controller,
    '''    -- 기존 battleController 직접 호출과 새 전용 어댑터 호출을 모두 지원한다.
    -- 실제 LLM·채팅 호스트 작업은 aftermathSkipScene이 담당하고,
    -- 전투 상태와 영수증 전이는 이 컨트롤러의 공개 action만 거친다.
    local function skipAftermath(expectedBattleId, expectedViewTurnId)
        local delegated, delegateErrors = callModule(
            "aftermathSkipScene",
            "run",
            expectedBattleId,
            expectedViewTurnId
        )
        if delegateErrors then return failure(delegateErrors) end
        return delegated
    end''',
    '''    -- 버튼은 목적지 바로가기 요청만 대기열에 올린다.
    -- 실제 생성은 사용자가 전송할 때 main.onStart/editRequest/onOutput 경계가 처리한다.
    local function skipAftermath(expectedBattleId, expectedViewTurnId)
        return prepareAftermathSkip(expectedBattleId, expectedViewTurnId)
    end''',
    "remove direct generation delegation",
)

manual_branch_anchor = '''        if aftermath.phase == "inFlight" or aftermath.phase == "requestInjected" then
            local chat, chatErrors = readChat()
            if chatErrors then return failure(chatErrors) end
            local response, topologyErrors = validateAftermathRequestChat(aftermath, chat, false, true)'''
manual_branch = '''        if aftermath.phase == "inFlight" or aftermath.phase == "requestInjected" then
            local chat, chatErrors = readChat()
            if chatErrors then return failure(chatErrors) end

            -- 목적지 바로가기 버튼은 생성 요청을 시작하지 않는다. 버튼 뒤 사용자가
            -- 수동 전송하면 editInput이 만든 exact filler를 승인 신호로 소비한다.
            if aftermath.phase == "inFlight"
                and type(aftermath.request) == "table"
                and aftermath.request.skipToDestination == true
                and aftermath.request.manualSubmitPending == true then
                if not isExactFiller(chat[#chat]) then
                    return failure({
                        makeError("aftermath_manual_submit_required", "$.chat", "목적지 바로가기 장면은 입력 없이 전송 버튼을 눌러 생성해야 합니다."),
                    })
                end
                local cleaned, removedFillers, cleanupErrors = removeTrailingSayNothing(
                    chat,
                    aftermath.request.userLuaIndex
                )
                if cleanupErrors then return failure(cleanupErrors) end
                chat = cleaned

                -- risu-btn host가 클릭한 UI anchor를 remount할 수 있으므로 존재할 때만
                -- 제거한다. anchor가 없는 host에서도 같은 수동 전송 계약으로 동작한다.
                local afterAnchor, removedAnchor, anchorErrors = removeUiAnchorAt(
                    chat,
                    aftermath.request.userLuaIndex + 1
                )
                if anchorErrors then return failure(anchorErrors) end
                chat = afterAnchor

                local response, topologyErrors = validateAftermathRequestChat(
                    aftermath,
                    chat,
                    false
                )
                if topologyErrors then return failure(topologyErrors) end
                if response ~= nil then
                    return failure({
                        makeError("aftermath_manual_submit_response_exists", "$.chat", "수동 전송 대기 중에는 기존 캐릭터 응답이 없어야 합니다."),
                    })
                end

                aftermath.request.manualSubmitPending = nil
                local validationErrors = validateAftermath(aftermath, authority)
                if #validationErrors > 0 then return failure(validationErrors) end
                local writeErrors = writeStored(KEYS.aftermath, aftermath)
                if writeErrors then return failure(writeErrors) end
                return success({
                    generationReady = true,
                    aftermath = true,
                    reused = true,
                    manualSubmitConsumed = true,
                    zeroOutputRetry = false,
                    commitRecovered = false,
                    turnNumber = aftermath.request.turnNumber,
                    attemptNumber = aftermath.request.attemptNumber,
                    removedSayNothing = removedFillers > 0,
                    removedSayNothingCount = removedFillers,
                    removedUiAnchor = removedAnchor,
                    removedUncommittedOutput = false,
                })
            end

            local response, topologyErrors = validateAftermathRequestChat(aftermath, chat, false, true)'''
controller = replace_once(
    controller,
    manual_branch_anchor,
    manual_branch,
    "consume manual submit",
)

controller = replace_once(
    controller,
    '''    local function injectAftermathRequest(promptArray, authority, aftermath)
        if aftermath.phase ~= "inFlight" and aftermath.phase ~= "requestInjected" then
            return failure({
                makeError("aftermath_request_not_in_flight", "$.aftermath.phase", "생성 중인 자유행동 요청이 없습니다."),
            })
        end''',
    '''    local function injectAftermathRequest(promptArray, authority, aftermath)
        if aftermath.phase ~= "inFlight" and aftermath.phase ~= "requestInjected" then
            return failure({
                makeError("aftermath_request_not_in_flight", "$.aftermath.phase", "생성 중인 자유행동 요청이 없습니다."),
            })
        end
        if type(aftermath.request) == "table"
            and aftermath.request.manualSubmitPending == true then
            return failure({
                makeError("aftermath_manual_submit_not_consumed", "$.aftermath.request.manualSubmitPending", "전송 버튼으로 수동 전송 대기를 먼저 해제해야 합니다."),
            })
        end''',
    "guard request injection",
)

if "aftermathSkipScene" in controller:
    raise SystemExit("battleController still references aftermathSkipScene")
if controller.count("manualSubmitPending") < 6:
    raise SystemExit("manual submit state was not wired through all boundaries")
controller_path.write_text(controller, encoding="utf-8")

html_path = Path("html/battleui.html")
html = html_path.read_text(encoding="utf-8")
html = replace_once(
    html,
    'risu-btn="aftermathSkipScene|run|',
    'risu-btn="battleController|skipAftermath|',
    "restore allowed button route",
)
html = replace_once(
    html,
    '''<div class="ht-processing" role="status" aria-live="polite" aria-label="처리중...">
<span class="ht-processing-spinner" aria-hidden="true"></span>
<span>장면을 이어가는 중<span aria-hidden="true"><span class="ht-processing-dot">.</span><span class="ht-processing-dot">.</span><span class="ht-processing-dot">.</span></span></span>
</div>''',
    '''<div class="ht-processing" role="status" aria-live="polite" aria-label="목적지 바로가기 전송 대기">
<span>목적지 바로가기 준비 완료 · 입력 없이 전송 버튼을 눌러 장면을 생성하세요.</span>
</div>''',
    "manual send UI copy",
)
html_path.write_text(html, encoding="utf-8")

main_path = Path("System/main.lua")
main = main_path.read_text(encoding="utf-8")
main = replace_once(
    main,
    'or "runtime-bundle-9c1d7e4f3a6b2e10"',
    'or "runtime-bundle-6f4c2a8d1e7b9035"',
    "runtime revision",
)
main_path.write_text(main, encoding="utf-8")

Path("System/aftermathSkipScene.lua").unlink(missing_ok=True)
Path(".github/workflows/fix-pr16-manual-send.yml").unlink(missing_ok=True)
Path(".github/pr16-manual-send-trigger").unlink(missing_ok=True)

assert 'risu-btn="battleController|skipAftermath|' in html
assert "aftermathSkipScene|run" not in html
assert "입력 없이 전송 버튼을 눌러" in html
assert "return prepareAftermathSkip(expectedBattleId, expectedViewTurnId)" in controller
assert "generationReady = false" in controller
assert "manualSubmitConsumed = true" in controller
assert "runtime-bundle-6f4c2a8d1e7b9035" in main
