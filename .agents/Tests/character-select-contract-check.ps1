$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$htmlPath = Join-Path $root 'html\characterSelect.html'
$viewPath = Join-Path $root 'System\gameSetupView.lua'
$mainPath = Join-Path $root 'System\main.lua'

function Assert-Contract {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "characterSelect contract failed: $Message" }
}

$html = Get-Content -Raw -Encoding UTF8 -LiteralPath $htmlPath
$viewSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $viewPath
$main = Get-Content -Raw -Encoding UTF8 -LiteralPath $mainPath

$viewRead = '{{settempvar::setup_character_view::{{getvar::gameSetupView}}}}'
Assert-Contract ($html.Contains($viewRead)) 'gameSetupView is not the single template input'
Assert-Contract ([regex]::Matches($html, '\{\{getvar::').Count -eq 1) 'the template reads a non-View global variable'
Assert-Contract ($html.Contains('::is::characterSelect')) 'characterSelect branch is missing'
Assert-Contract ($html.Contains('::is::battleReady')) 'battleReady recovery branch is missing'
Assert-Contract ($html.Contains('{{#each::keep {{dictelement::{{tempvar::setup_character_offer}}::characters}} as setup_character_item}}')) 'three candidates are not rendered from the public View loop'
Assert-Contract (-not $html.Contains('{{#each::keep::')) '#each keep syntax has an extra delimiter'

foreach ($field in @(
    'characterId', 'name', 'age', 'occupation', 'appearanceSummary',
    'startingResistance', 'startingMood', 'baseDrawCount', 'maxHandSize', 'traits'
)) {
    Assert-Contract ($html.Contains("{{dictelement::{{slot::setup_character_item}}::$field}}")) "public character field is not rendered: $field"
    Assert-Contract ($viewSource.Contains("$field =")) "gameSetupView no longer projects required field: $field"
}
Assert-Contract ($html.Contains('{{#each::keep {{dictelement::{{slot::setup_character_item}}::traits}} as setup_character_trait}}')) 'public traits are not rendered as a loop'
Assert-Contract ($html.Contains('{{dictelement::{{slot::setup_character_trait}}::name}}')) 'trait name is missing'
Assert-Contract ($html.Contains('{{dictelement::{{slot::setup_character_trait}}::description}}')) 'trait description is missing'

$route = 'risu-btn="init|chooseCharacter|{{dictelement::{{slot::setup_character_item}}::characterId}}|{{dictelement::{{tempvar::setup_character_offer}}::interactionToken}}"'
Assert-Contract ([regex]::Matches($html, [regex]::Escape($route)).Count -eq 1) 'chooseCharacter route must carry characterId and current token exactly once'
Assert-Contract ([regex]::Matches($html, 'risu-btn=').Count -eq 1) 'the character template exposes an unexpected Lua route'
Assert-Contract ([regex]::Matches($html, 'type="radio"').Count -eq 2) 'hidden reset plus one loop-scoped radio must implement first-click details'
Assert-Contract ($html.Contains('<label class="character-card"')) 'the first-click detail control needs a label'
Assert-Contract ($html.Contains('.character-choice-state:checked ~ .character-confirm')) 'confirmation is not gated by the selected radio state'
Assert-Contract ($html.IndexOf($route, [StringComparison]::Ordinal) -gt $html.IndexOf('character-details', [StringComparison]::Ordinal)) 'the Lua route appears before the detail interaction'

foreach ($privateText in @(
    'privateProfile', 'battleSpec', 'selectedCardIds', 'cardInstances',
    'characterIntent', 'rng', 'seed', 'narration', 'CharacterCards.db'
)) {
    Assert-Contract (-not $html.Contains($privateText)) "private/internal field is referenced: $privateText"
}
Assert-Contract (-not [regex]::IsMatch($html, '<script(?:\s|>)', 'IgnoreCase')) 'JavaScript is not allowed'
Assert-Contract (-not [regex]::IsMatch($html, '\son[a-z]+\s*=', 'IgnoreCase')) 'inline DOM event handlers are not allowed'
Assert-Contract (-not [regex]::IsMatch($html, '<img(?:\s|>)', 'IgnoreCase')) 'fake or remote portraits are not allowed'
Assert-Contract (-not $html.Contains('risu-trigger=')) 'the Lua dispatcher route must not be bypassed'
Assert-Contract (-not [regex]::IsMatch($html, '\{\{(?:setvar|addvar|setdefaultvar)::')) 'the template must not mutate authority/global variables'

$cssMatch = [regex]::Match($html, '<style>([\s\S]*?)</style>', 'IgnoreCase')
Assert-Contract ($cssMatch.Success) 'style block is missing'
$css = $cssMatch.Groups[1].Value
foreach ($selector in [regex]::Matches($css, '(?m)^\s*([^@\r\n][^{\r\n]*)\{')) {
    $text = $selector.Groups[1].Value.Trim()
    if ($text.StartsWith('from') -or $text.StartsWith('to') -or $text.EndsWith('%')) { continue }
    Assert-Contract ($text.Contains('.setup-character-select')) "unscoped CSS selector: $text"
}
Assert-Contract ($html.Contains('@media (max-width:')) 'mobile layout is missing'
Assert-Contract ($html.Contains('@media (prefers-reduced-motion: reduce)')) 'reduced-motion handling is missing'
Assert-Contract ($html.Contains(':focus-visible')) 'keyboard focus styling is missing'

$whenOpen = [regex]::Matches($html, '\{\{#when').Count
$whenClose = [regex]::Matches($html, '\{\{/when\}\}').Count
$eachOpen = [regex]::Matches($html, '\{\{#each').Count
$eachClose = [regex]::Matches($html, '\{\{/each\}\}').Count
Assert-Contract ($whenOpen -eq $whenClose) 'CBS when blocks are not balanced'
Assert-Contract ($eachOpen -eq $eachClose) 'CBS each blocks are not balanced'

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

Assert-Contract ([regex]::IsMatch($main, 'init\s*=\s*\{[^}]*chooseCharacter\s*=\s*true')) 'main button allowlist does not expose chooseCharacter'
Assert-Contract ($main.Contains('(action == "chooseCharacter" and #arguments == 3)')) 'main does not require the exact chooseCharacter argument count'

Write-Output 'character-select-contract-check: ok'
