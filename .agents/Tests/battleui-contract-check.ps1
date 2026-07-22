$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$htmlPath = Join-Path $root 'html\battleui.html'
$contractPath = Join-Path $root '.agents\Docs\StateViewContract.md'

function Assert-Contract {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw "battleui contract failed: $Message"
    }
}

$html = Get-Content -Raw -LiteralPath $htmlPath
$contract = Get-Content -Raw -LiteralPath $contractPath
$bodyMatch = [regex]::Match($html, '(?s)<body>(.*)</body>')
$hasBodyOpen = $html.Contains('<body>')
$hasBodyClose = $html.Contains('</body>')
Assert-Contract ($hasBodyOpen -eq $hasBodyClose) 'body wrapper is only partially present'
$body = if ($bodyMatch.Success) { $bodyMatch.Groups[1].Value } else { $html }

Assert-Contract ($body.Contains('{{getvar::battleView}}')) 'battleView chat variable is not read'
foreach ($node in @(
    'bv_turn',
    'bv_environment',
    'bv_player',
    'bv_character',
    'bv_hand',
    'bv_selection',
    'bv_zones',
    'bv_last_turn',
    'bv_outcome'
)) {
    Assert-Contract ($body.Contains("{{settempvar::$node::")) "dynamic node $node is not bound"
}

$eachOpen = [regex]::Matches($body, '\{\{#each::keep ').Count
$eachClose = [regex]::Matches($body, '\{\{/each\}\}').Count
$allEachOpen = [regex]::Matches($body, '\{\{#each').Count
Assert-Contract ($eachOpen -gt 0) 'no keep-preserving CBS loop exists'
Assert-Contract ($eachOpen -eq $allEachOpen) 'every CBS loop must use #each::keep ARRAY as alias syntax'
Assert-Contract ($eachOpen -eq $eachClose) 'CBS each blocks are not balanced'
Assert-Contract (-not $body.Contains('{{#each::keep::')) '#each keep syntax has an extra argument delimiter'

$whenOpen = [regex]::Matches($body, '\{\{#when').Count
$whenClose = [regex]::Matches($body, '\{\{/when\}\}').Count
Assert-Contract ($whenOpen -eq $whenClose) 'CBS when blocks are not balanced'
Assert-Contract (-not $body.Contains('{{element::')) 'deep element traversal is not allowed'
Assert-Contract ($contract.Contains('{{#each::keep ')) 'StateViewContract CBS loop example is stale'

$registerRoute = 'risu-btn="battleController|registerCard|{{dictelement::{{slot::hand_card}}::instanceId}}|{{dictelement::{{tempvar::bv}}::interactionToken}}"'
$cancelRoute = 'risu-btn="battleController|cancelCard|{{dictelement::{{slot::hand_card}}::instanceId}}|{{dictelement::{{tempvar::bv}}::interactionToken}}"'
Assert-Contract ($body.Contains($registerRoute)) 'explicit register route does not include instanceId and interactionToken'
Assert-Contract ($body.Contains($cancelRoute)) 'explicit cancel route does not include instanceId and interactionToken'
$unplayableCondition = '{{#when::keep::{{dictelement::{{slot::hand_card}}::playable}}::isnot::true}}'
Assert-Contract ($body.Contains($unplayableCondition)) 'unplayable card branches are missing'
Assert-Contract ([regex]::Matches($body, '<button class="hand-card-action(?: is-cancel)?" type="button" disabled>').Count -eq 2) 'unplayable register/cancel branches do not render literal disabled buttons'
Assert-Contract (-not [regex]::IsMatch($body, '(?s)<button[^>]*\{\{#when')) 'CBS control syntax must not appear inside a button opening tag'
Assert-Contract (-not $body.Contains('{{:else}}')) 'CBS else remains despite the current keep/else newline ambiguity'
Assert-Contract ([regex]::Matches($body, 'risu-btn=').Count -eq 2) 'battle UI must expose only register and cancel routes'
Assert-Contract ($body.Contains('data-selected="{{dictelement::{{slot::hand_card}}::selected}}"')) 'selected state is not bound to card markup'
Assert-Contract ($body.Contains('<details class="hand-card"')) 'card detail is not a native local disclosure'
Assert-Contract ($body.Contains('<summary class="hand-card-summary"')) 'card detail has no keyboard-accessible summary'
Assert-Contract (-not $body.Contains('aria-label="카드 상세 열기"')) 'generic summary label hides the projected card name'
$cancelAccessibleName = '<span class="sr-only">{{dictelement::{{slot::hand_card}}::name}} 카드 </span>등록 취소'
$registerAccessibleName = '<span class="sr-only">{{dictelement::{{slot::hand_card}}::name}} </span>카드 등록'
Assert-Contract ($body.Contains($cancelAccessibleName) -and $body.Contains($registerAccessibleName)) 'card action accessible names do not include the projected card name'
Assert-Contract (-not $body.Contains('focusedInstanceId')) 'server-side focus leaked into the local detail UI'
Assert-Contract (-not $body.Contains('battleController|clickCard|')) 'legacy two-click server focus route remains in the UI'

foreach ($legacyAction in @('planDetail|', 'showDeck', 'showDiscard', 'playCard|')) {
    Assert-Contract (-not $html.Contains($legacyAction)) "legacy action remains: $legacyAction"
}

foreach ($fixtureText in @('한소희', '시선 흘리기', '가까이 서기', '우연한 접촉', 'glance_away', 'stand_close', 'accidental_contact')) {
    Assert-Contract (-not $body.Contains($fixtureText)) "hardcoded fixture remains in body: $fixtureText"
}

Assert-Contract (-not $html.Contains('.ui-radio')) 'legacy radio CSS remains'
Assert-Contract (-not [regex]::IsMatch($html, '#card-[123]')) 'legacy fixed-slot selectors remain'
Assert-Contract (-not [regex]::IsMatch($body, '<(?:button|a)[^>]*(?:턴 종료|카드 사용|사용 확정)')) 'a separate submit or turn-end control remains'
Assert-Contract (-not [regex]::IsMatch($body, '(?:aria-label|title)="[^"]*\{\{')) 'display text is interpolated into a label/title attribute'
Assert-Contract ($body.Contains('<progress class="route-native"')) 'turn progress is not value/max driven'
Assert-Contract ($body.Contains('<progress class="meter-native"')) 'resistance progress is not value/max driven'
Assert-Contract (-not [regex]::IsMatch($html, '(?m)^width:\s*(?:33\.33|60|80)%;')) 'a hardcoded mock progress ratio remains'

Assert-Contract ($body.Contains('선택을 마쳤다면 Risu 전송 버튼으로 제출 또는 패스')) 'Risu send button is not documented as the only submit/pass control'
Assert-Contract ($body.Contains('입력창은 비워 둔 채 Risu 전송 버튼을 누르세요.')) 'blank-send instruction is missing'
Assert-Contract (-not $body.Contains('마침표(.)')) 'legacy period-submit instruction remains'
Assert-Contract (-not $body.Contains('*says nothing*')) 'internal filler text leaked into the battle UI'
Assert-Contract ($body.Contains('{{dictelement::{{tempvar::bv_public_action}}::status}}')) 'public action status is not projected'
Assert-Contract ($body.Contains('{{dictelement::{{tempvar::bv_public_tag}}::label}}')) 'public action tag label is not projected'
Assert-Contract ($body.Contains('{{dictelement::{{tempvar::bv_last_turn}}::summaries}}')) 'lastTurn public summaries are not projected'
Assert-Contract ($body.Contains('카드 정보와 발동 조건은 공개되지 않습니다.')) 'hidden character plan boundary is not represented'

foreach ($zoneField in @('deckCount', 'usedCount', 'discardCount', 'removedCount')) {
    Assert-Contract ($body.Contains("{{dictelement::{{tempvar::bv_zones}}::$zoneField}}")) "zone count is missing: $zoneField"
}

$voidElements = @('area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr')
$stack = New-Object System.Collections.Generic.List[string]
foreach ($match in [regex]::Matches($body, '</?([A-Za-z][A-Za-z0-9-]*)(?:\s[^<>]*?)?>')) {
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

Write-Output 'battleui-contract-check: ok'
