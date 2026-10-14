param([switch]$SkipInstall)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $projectRoot '.tooling\overlay-build'
$env:TEMP = Join-Path $projectRoot '.tooling\temp'
$env:TMP = $env:TEMP
$env:NPM_CONFIG_CACHE = Join-Path $projectRoot '.tooling\npm-cache'
$env:NPM_CONFIG_USERCONFIG = Join-Path $toolRoot 'npmrc'
$env:CI = 'true'
New-Item -ItemType Directory -Force -Path $toolRoot,$env:TEMP,$env:NPM_CONFIG_CACHE | Out-Null
if (!(Test-Path -LiteralPath $env:NPM_CONFIG_USERCONFIG)) {
    Set-Content -LiteralPath $env:NPM_CONFIG_USERCONFIG -Value '' -Encoding utf8
}
$node = (Get-Command node -ErrorAction Stop).Source
$npm = Get-Command npm -ErrorAction SilentlyContinue
$npmFallback = Join-Path $projectRoot '.tooling\connectivity-research\npm\package\bin\npm-cli.js'
function Invoke-OverlayNpm([string[]]$Arguments) {
    if ($npm) { & $npm.Source @Arguments }
    elseif (Test-Path -LiteralPath $npmFallback) { & $node $npmFallback @Arguments }
    else { throw 'Install Node.js with npm before building the overlay runtime.' }
    if ($LASTEXITCODE) { throw 'Overlay dependency installation failed.' }
}
if (!$SkipInstall) {
    Push-Location (Join-Path $projectRoot 'packages\flutter_pear\pear-end')
    try { Invoke-OverlayNpm -Arguments @('ci','--no-audit','--no-fund') } finally { Pop-Location }
}
$manifest = '{"name":"farvahartrends-overlay-build","private":true,"version":"1.0.0","dependencies":{"bare-pack":"2.2.0"}}'
Set-Content -LiteralPath (Join-Path $toolRoot 'package.json') -Value $manifest -Encoding utf8
if (!$SkipInstall) {
    Push-Location $toolRoot
    try { Invoke-OverlayNpm -Arguments @('install','--no-audit','--no-fund') } finally { Pop-Location }
}
Push-Location $projectRoot
try {
    $dart = Join-Path $projectRoot '.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe'
    if (!(Test-Path -LiteralPath $dart)) { $dart = (Get-Command dart -ErrorAction Stop).Source }
    & $dart tools/generate_overlay_version.dart
    if ($LASTEXITCODE) { throw 'Transport fingerprint generation failed.' }
    & (Join-Path $toolRoot 'node_modules\.bin\bare-pack.cmd') --linked --host android-arm64 --host android-x64 --host android-arm --host ios-arm64 --host ios-arm64-simulator --host ios-x64-simulator --out packages/flutter_pear/assets/pear-end.bundle packages/flutter_pear/pear-end/farvahartrends.js
    if ($LASTEXITCODE) { throw 'Transport bundle generation failed.' }
} finally { Pop-Location }
Write-Output 'Built the pinned FarvaharTrends overlay runtime.'
