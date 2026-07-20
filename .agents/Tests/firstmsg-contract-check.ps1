$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$htmlPath = Join-Path $root 'html\firstmsg.html'
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

Assert-Contract ($displayUi.Contains('{{#when::keep::{{getvar::gameSetupReady}}::isnot::ready}}')) 'the incomplete setup branch is missing'
Assert-Contract ($displayUi.Contains('{{#when::keep::{{getvar::gameSetupReady}}::is::ready}}')) 'the ready setup branch is missing'
Assert-Contract ([regex]::Matches($displayUi, '\{\{getvar::gameSetupReady\}\}').Count -eq 2) 'the UI readiness boundary must depend only on the final ready marker'
Assert-Contract ($displayUi.Contains('{{settempvar::setup_raw::{{getvar::gameSetupView}}}}')) 'the public setup view is not bound after readiness'
Assert-Contract ($displayUi.Contains('{{dictelement::{{tempvar::setup_raw}}::phase}}')) 'the setup phase is not read from the public view'

foreach ($phase in @('deckDraft', 'deckComplete', 'characterSelect', 'battleReady')) {
    Assert-Contract ($html.Contains("::is::$phase")) "setup phase is not represented: $phase"
}
Assert-Contract ($html.Contains('{{tempvar::setup_phase}}::isnot::complete')) 'the completed setup status panel is not hidden'

$startRoute = 'risu-btn="init|start"'
Assert-Contract ([regex]::Matches($html, [regex]::Escape($startRoute)).Count -eq 1) 'there must be exactly one init start route'
Assert-Contract ([regex]::Matches($html, '<button(?:\s|>)').Count -eq 1) 'the greeting exposes an unexpected button'
Assert-Contract ([regex]::Matches($html, 'risu-btn=').Count -eq 1) 'the greeting exposes an unexpected Lua route'
Assert-Contract ([regex]::Matches($html, '\{\{getvar::🔯🔯🔯\}\}').Count -eq 1) 'the dynamic UI anchor must exist exactly once'

Assert-Contract ($narrative.Contains('{{user}}')) 'the player identity macro is missing from the prompt-visible narrative'
Assert-Contract ([regex]::Matches($narrative, '\{\{user\}\}').Count -ge 3) 'the player is not consistently placed in the opening narrative'
foreach ($notice in @('만 19세 이상의 성인', '비동의적 성적 괴롭힘', '범죄', '동의하지 않았다는 사실', '치한행위를 저지르기로 결심')) {
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
