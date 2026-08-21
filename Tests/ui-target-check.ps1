$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hostFlow = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'System\hostFlow.lua')
$controller = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'System\battleController.lua')
$firstMessage = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'Prompt\firstmsg.html')
$marker = '@@HELLTRAIN_UI_ANCHOR_V1@@'

if ($hostFlow.Contains($marker) -or $controller.Contains($marker) -or $firstMessage.Contains($marker)) {
    throw 'Physical UI anchor marker remains in a runtime or prompt file.'
}
if (-not $hostFlow.Contains('helltrainUiTargetIndexV1')) {
    throw 'UI target chatVar is missing.'
}
if (-not $hostFlow.Contains('return data .. "\n" .. UI_CONTAINER_OPEN .. rendered .. "</div>"')) {
    throw 'editDisplay no longer appends the UI to its target message.'
}
if (-not $controller.Contains('uiTargetIndex = committedBinding.chatAnchor.responseIndex')) {
    throw 'Normal output no longer reports its UI target index.'
}
if (-not $firstMessage.Contains('<div class="helltrain-dynamic-ui" aria-label="게임 화면"></div>')) {
    throw 'First-message UI container is not empty.'
}

Write-Output 'UI target checks passed.'
