$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$htmlRoot = Join-Path $root 'html'
$files = @(Get-ChildItem -LiteralPath $htmlRoot -Filter '*.html' -File -Recurse | Sort-Object FullName)

if ($files.Count -eq 0) {
    throw 'html indent check failed: no game HTML files were found'
}

$violations = New-Object System.Collections.Generic.List[string]
foreach ($file in $files) {
    $lineNumber = 0
    foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $file.FullName) {
        $lineNumber += 1
        if ($line -match '^[\t ]+') {
            $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]'\/')
            $violations.Add("${relative}:${lineNumber}")
        }
    }
}

if ($violations.Count -gt 0) {
    throw "html indent check failed: line-leading whitespace found at $($violations -join ', ')"
}

Write-Output "html-indent-check: ok ($($files.Count) files)"
