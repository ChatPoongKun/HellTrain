$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mainPath = Join-Path $root 'System\main.lua'
$setupControllerPath = Join-Path $root 'System\gameSetupController.lua'
function Get-BundleRelativePath {
    param([string]$Path)
    return $Path.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
}
$main = Get-Content -Raw -Encoding UTF8 -LiteralPath $mainPath
$revisionMatch = [regex]::Match(
    $main,
    'RUNTIME_BUNDLE_REVISION\s*=\s*RUNTIME_BUNDLE_REVISION\s+or\s+"runtime-bundle-([0-9a-f]{16})"'
)
if (-not $revisionMatch.Success) {
    throw 'runtime bundle contract failed: main.lua does not contain a 16-hex content revision'
}

$files = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'System') -File -Filter '*.lua'
    Get-ChildItem -LiteralPath (Join-Path $root 'DB') -File -Filter '*.db'
    Get-ChildItem -LiteralPath (Join-Path $root 'Char') -File -Filter '*.db'
) | Sort-Object { Get-BundleRelativePath $_.FullName }

# Chat clone/branch는 namespace chatVar를 복제할 수 있다. 권위·순번 상태가
# warm handler outer local로 승격되지 않도록, content-keyed 파생 캐시만
# 명시적으로 예외 허용한다.
$persistentHandlerAllowlist = @(
    'System/staticData.lua'
    'System/viewBuilder.lua'
)
foreach ($systemFile in @($files | Where-Object Extension -EQ '.lua')) {
    $relative = Get-BundleRelativePath $systemFile.FullName
    if ($relative -eq 'System/main.lua') { continue }
    $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $systemFile.FullName
    $isPersistentOuterClosure = [regex]::IsMatch($source, '^\s*\(function\s*\(\s*\)')
    if ($persistentHandlerAllowlist -contains $relative) {
        if (-not $isPersistentOuterClosure) {
            throw "runtime bundle contract failed: allowed content cache lost its persistent handler boundary: $relative"
        }
    }
    elseif ($isPersistentOuterClosure) {
        throw "runtime bundle contract failed: unauthorized persistent handler state in $relative"
    }
}

$builder = [Text.StringBuilder]::new()
foreach ($file in $files) {
    $relative = Get-BundleRelativePath $file.FullName
    $content = (Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($file.FullName -ceq $mainPath) {
        $content = [regex]::Replace(
            $content,
            'RUNTIME_BUNDLE_REVISION\s*=\s*RUNTIME_BUNDLE_REVISION\s+or\s+"runtime-bundle-[0-9a-f]{16}"',
            'RUNTIME_BUNDLE_REVISION = RUNTIME_BUNDLE_REVISION or "runtime-bundle-CONTENT-HASH"'
        )
    }
    [void]$builder.Append($relative.Length).Append(':').Append($relative).Append("`n")
    [void]$builder.Append($content.Length).Append(':').Append($content).Append("`n")

    if ($file.Extension -in @('.lua', '.db')) {
        # RisuAI applies CBS before Lua parsing, so comments and quoted strings
        # are not safe places for a directive literal either.
        if ($content.Contains('{{')) {
            throw "runtime bundle contract failed: executable CBS literal found in $relative"
        }
    }
}

$bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 16)
} finally {
    $sha.Dispose()
}

if ($revisionMatch.Groups[1].Value -cne $digest) {
    throw "runtime bundle contract failed: expected runtime-bundle-$digest, found runtime-bundle-$($revisionMatch.Groups[1].Value)"
}

$sideBarContent = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'html\sideBar.html')).Replace("`r`n", "`n").Replace("`r", "`n")
$sideBarSha = [Security.Cryptography.SHA256]::Create()
try {
    $sideBarDigest = ([BitConverter]::ToString($sideBarSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sideBarContent)))).Replace('-', '').ToLowerInvariant().Substring(0, 16)
} finally {
    $sideBarSha.Dispose()
}
$setupController = Get-Content -Raw -Encoding UTF8 -LiteralPath $setupControllerPath
if (-not $setupController.Contains('local UI_SHELL_REVISION = "sidebar-' + $sideBarDigest + '"')) {
    throw "runtime bundle contract failed: sidebar revision must be sidebar-$sideBarDigest"
}

Write-Output "runtime-bundle-contract-check: ok | revision=runtime-bundle-$digest | sidebar=sidebar-$sideBarDigest | files=$($files.Count)"
