$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$htmlPath = Join-Path $root 'Prompt\firstmsg.html'
$cbsPath = Join-Path $root '.agents\References\CBS.md'

function Assert-Contract {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw "firstmsg contract failed: $Message"
    }
}

$html = Get-Content -Raw -Encoding UTF8 -LiteralPath $htmlPath
$main = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'System\main.lua')
$cbs = Get-Content -Raw -Encoding UTF8 -LiteralPath $cbsPath
$trimmed = $html.Trim()
$displayGuard = '{{#when::keep::{{isfirstmsg}}::is::1}}'
$displayGuardIndex = $html.IndexOf($displayGuard, [System.StringComparison]::Ordinal)

Assert-Contract ($displayGuardIndex -gt 0) 'the display-only UI guard is missing or precedes the narrative'
Assert-Contract ($trimmed.EndsWith('{{/when}}')) 'the display-only first-message guard is not closed last'
Assert-Contract ([regex]::Matches($html, [regex]::Escape($displayGuard)).Count -eq 1) 'there must be exactly one first-message display guard'
Assert-Contract ($cbs.Contains('| `{{isfirstmsg}}`')) 'the local CBS reference does not document isfirstmsg'
Assert-Contract ($cbs.Contains('| `{{getvar::name}}`')) 'the local CBS reference does not document getvar'

$narrative = $html.Substring(0, $displayGuardIndex)
$displayUi = $html.Substring($displayGuardIndex)
Assert-Contract (-not $narrative.Contains('<style')) 'CSS leaked into the prompt-visible narrative'
Assert-Contract (-not $narrative.Contains('risu-btn=')) 'a display button leaked into the prompt-visible narrative'
Assert-Contract ($displayUi.Contains('<style>')) 'the first-message display branch has no UI styling'

$whenOpen = [regex]::Matches($html, '\{\{#when').Count
$whenKeepOpen = [regex]::Matches($html, '\{\{#when::keep::').Count
$whenClose = [regex]::Matches($html, '\{\{/when\}\}').Count
Assert-Contract ($whenOpen -eq $whenKeepOpen) 'every conditional must preserve its intended whitespace'
Assert-Contract ($whenOpen -eq $whenClose) 'CBS when blocks are not balanced'
Assert-Contract (-not $html.Contains('{{:else}}')) 'multi-line CBS else is intentionally avoided'

$startRoute = 'risu-btn="init|start"'
Assert-Contract (-not $html.Contains($startRoute)) 'the initial action must be injected by editDisplay, not frozen in outer CBS'
Assert-Contract ([regex]::Matches($main, [regex]::Escape($startRoute)).Count -eq 1) 'main must expose exactly one init start route'
Assert-Contract ($main.Contains('readUiFragment(triggerId, UI_READY_VAR) == "ready"')) 'editDisplay does not own the readiness boundary'
$uiAnchorMarker = '@@HELLTRAIN_UI_ANCHOR_V1@@'
Assert-Contract ([regex]::Matches($html, [regex]::Escape($uiAnchorMarker)).Count -eq 1) 'the dynamic UI anchor marker must exist exactly once'
Assert-Contract ($displayUi.Contains('.helltrain-entry:has(.helltrain-dynamic-ui:empty)')) 'the retired first-message UI shell is not hidden'
Assert-Contract (-not $displayUi.Contains('{{getvar::gameSetupReady}}')) 'outer CBS must not freeze the setup readiness state'
Assert-Contract (-not $html.Contains('{{getvar::🔯🔯🔯}}')) 'the dynamic UI must be injected by editDisplay so targeted chat reloads cannot reuse stale outer CBS'

Assert-Contract ($narrative.Contains('{{user}}')) 'the player identity macro is missing from the prompt-visible narrative'
Assert-Contract ([regex]::Matches($narrative, '\{\{user\}\}').Count -ge 3) 'the player is not consistently placed in the opening narrative'
foreach ($notice in @('만 19세 이상의 성인', '비동의적 성적 괴롭힘', '범죄적 선택', '치한행위를 상습적으로 저질러 왔고')) {
    Assert-Contract ($narrative.Contains($notice)) "required prompt-visible narrative boundary is missing: $notice"
}

Assert-Contract (-not [regex]::IsMatch($html, '<script(?:\s|>)', 'IgnoreCase')) 'script elements are not allowed in the greeting'
Assert-Contract (-not [regex]::IsMatch($html, '\son[a-z]+\s*=', 'IgnoreCase')) 'inline DOM event handlers are not allowed'
Assert-Contract (-not $html.Contains('risu-trigger=')) 'the Lua dispatcher route must not be bypassed'
Assert-Contract (-not [regex]::IsMatch($html, '\{\{(?:setvar|addvar|setdefaultvar)::')) 'the greeting must not initialize authority state through CBS side effects'

$voidElements = @('area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr')
$stack = New-Object System.Collections.Generic.List[string]
foreach ($match in [regex]::Matches($html, '</?([A-Za-z][A-Za-z0-9-]*)(?:\s[^<>]*?)?>')) {
    $name = $match.Groups[1].Value.ToLowerInvariant()
    if ($match.Value.StartsWith('</')) {
        Assert-Contract ($stack.Count -gt 0) "orphan closing HTML tag: $name"
        $top = $stack[$stack.Count - 1]
        Assert-Contract ($top -eq $name) "HTML tag mismatch: expected </$top>, found </$name>"
        $stack.RemoveAt($stack.Count - 1)
    }
    elseif (($voidElements -notcontains $name) -and (-not $match.Value.EndsWith('/>'))) {
        $stack.Add($name)
    }
}
Assert-Contract ($stack.Count -eq 0) "unclosed HTML tags remain: $($stack -join ', ')"

Write-Output 'firstmsg-contract-check: ok'
