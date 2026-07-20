$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$htmlPath = Join-Path $root 'html\cardDraft.html'
$viewPath = Join-Path $root 'System\gameSetupView.lua'
$mainPath = Join-Path $root 'System\main.lua'

function Assert-Contract {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "cardDraft contract failed: $Message" }
}

$html = Get-Content -Raw -Encoding UTF8 -LiteralPath $htmlPath
$viewSource = Get-Content -Raw -Encoding UTF8 -LiteralPath $viewPath
$main = Get-Content -Raw -Encoding UTF8 -LiteralPath $mainPath

Assert-Contract ($html.Contains('{{settempvar::setup_draft_view::{{getvar::gameSetupView}}}}')) 'gameSetupView is not the template input'
Assert-Contract ($html.Contains('{{dictelement::{{tempvar::setup_draft_view}}::kind}}')) 'the public View kind is not checked'
Assert-Contract ($html.Contains('{{dictelement::{{tempvar::setup_draft_view}}::phase}}')) 'the public View phase is not read'
Assert-Contract ($html.Contains('::is::deckDraft')) 'deckDraft branch is missing'
Assert-Contract ($html.Contains('::is::deckComplete')) 'deckComplete branch is missing'
Assert-Contract ($html.Contains('{{dictelement::{{tempvar::setup_draft_view}}::offer}}')) 'offer is not read from gameSetupView'
Assert-Contract ($html.Contains('{{#each::keep {{dictelement::{{tempvar::setup_draft_offer}}::cards}} as setup_offer_card}}')) 'offer.cards is not rendered as a CBS loop'
Assert-Contract (-not $html.Contains('{{#each::keep::')) '#each keep syntax has an extra delimiter'

foreach ($field in @(
    'cardId', 'name', 'descriptionSegments', 'ruleLines', 'actionTag', 'mechanisms',
    'baseStealthCost', 'baseResistanceDamage', 'ownedCopies'
)) {
    Assert-Contract ($html.Contains("{{dictelement::{{slot::setup_offer_card}}::$field}}")) "gameSetupView card field is not rendered: $field"
    Assert-Contract ($viewSource.Contains("$field =")) "gameSetupView no longer projects required field: $field"
}

foreach ($collection in @('descriptionSegments', 'ruleLines', 'mechanisms')) {
    Assert-Contract ([regex]::IsMatch($html, "#each::keep[^\r\n]*::$collection")) "card collection is not iterated: $collection"
}
Assert-Contract ($html.Contains('::kind}}::is::text')) 'text segments are not distinguished from tag segments'
Assert-Contract ($html.Contains('::tooltip}}')) 'tag tooltips are not rendered'

$route = 'risu-btn="init|choose|{{dictelement::{{slot::setup_offer_card}}::cardId}}|{{dictelement::{{tempvar::setup_draft_offer}}::interactionToken}}"'
Assert-Contract ([regex]::Matches($html, [regex]::Escape($route)).Count -eq 1) 'the choose route must carry cardId and the current interaction token exactly once in the loop'
Assert-Contract ([regex]::Matches($html, 'risu-btn=').Count -eq 1) 'the draft template exposes an unexpected Lua route'
Assert-Contract ([regex]::Matches($html, 'type="radio"').Count -eq 2) 'hidden reset plus one loop-scoped radio declaration must implement first-click focus'
Assert-Contract ($html.Contains('<label')) 'the first-click detail control needs a label'
$routeIndex = $html.IndexOf($route, [System.StringComparison]::Ordinal)
$detailsIndex = $html.IndexOf('draft-details', [System.StringComparison]::Ordinal)
Assert-Contract (($detailsIndex -ge 0) -and ($routeIndex -gt $detailsIndex)) 'the Lua choose action must be exposed only inside the expanded detail region'
Assert-Contract ($html.Contains('.draft-choice-state:checked ~ .draft-confirm')) 'the choose route is not gated by first-click focus state'

Assert-Contract ($html.Contains('{{dictelement::{{tempvar::setup_draft_progress}}::totalRounds}}')) 'total draft rounds are not shown'
Assert-Contract ($html.Contains('{{dictelement::{{tempvar::setup_draft_deck}}::count}}')) 'current deck count is not shown'
Assert-Contract ($html.Contains('10장')) 'deckComplete does not identify the ten-card result'
$completeIndex = $html.IndexOf('::is::deckComplete', [System.StringComparison]::Ordinal)
Assert-Contract ($completeIndex -ge 0) 'deckComplete branch not found'
$completeBranch = $html.Substring($completeIndex)
Assert-Contract (-not [regex]::IsMatch($completeBranch, 'risu-btn=')) 'deckComplete invents an actionable character/card selection step'

foreach ($fantasy in @('성기사의 대검', '심연의 수정구', '불사의 방패', 'EPIC', 'LEGENDARY', 'MYTHIC', '희귀도', 'rarity')) {
    Assert-Contract (-not $html.Contains($fantasy)) "fantasy/rarity placeholder remains: $fantasy"
}
Assert-Contract (-not [regex]::IsMatch($html, '<script(?:\s|>)', 'IgnoreCase')) 'JavaScript is not allowed'
Assert-Contract (-not [regex]::IsMatch($html, '\son[a-z]+\s*=', 'IgnoreCase')) 'inline DOM event handlers are not allowed'
Assert-Contract (-not $html.Contains('risu-trigger=')) 'the Lua dispatcher route must not be bypassed'
Assert-Contract (-not [regex]::IsMatch($html, '\{\{(?:setvar|addvar|setdefaultvar)::')) 'the template must not mutate authority/global variables'

Assert-Contract ([regex]::IsMatch($html, '<(?:article|section)[^>]+class="[^"]*setup-draft')) 'a scoped setup-draft root is missing'
$cssMatch = [regex]::Match($html, '<style>([\s\S]*?)</style>', 'IgnoreCase')
Assert-Contract ($cssMatch.Success) 'style block is missing'
$css = $cssMatch.Groups[1].Value
foreach ($selector in [regex]::Matches($css, '(?m)^\s*([^@\r\n][^{\r\n]*)\{')) {
    $text = $selector.Groups[1].Value.Trim()
    if ($text.StartsWith('from') -or $text.StartsWith('to') -or $text.EndsWith('%')) { continue }
    Assert-Contract (($text.Contains('.setup-draft')) -or ($text.StartsWith(':root'))) "unscoped CSS selector: $text"
}
Assert-Contract ($html.Contains('@media (max-width:')) 'mobile layout is missing'
Assert-Contract ($html.Contains('@media (prefers-reduced-motion: reduce)')) 'reduced-motion handling is missing'

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

Assert-Contract (-not $main.Contains('gameSetupController')) 'main.lua was changed to route game setup'
Assert-Contract (-not $main.Contains('gameSetupV1.authority')) 'main.lua was changed to own setup authority'

Write-Output 'card-draft-contract-check: ok'
