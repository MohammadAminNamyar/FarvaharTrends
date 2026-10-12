param(
    [string]$HostIPv4,
    [ValidateRange(1,65535)][int]$Port = 45871,
    [switch]$PrepareOnly,
    [ValidateRange(1,86400)][int]$RunForSeconds,
    [switch]$SelfTest,
    [string]$BluetoothPython,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$env:PUB_CACHE = Join-Path $projectRoot '.tooling\pub-cache'
$env:APPDATA = Join-Path $projectRoot '.tooling\config'
$env:LOCALAPPDATA = Join-Path $projectRoot '.tooling\local'
$env:TEMP = Join-Path $projectRoot '.tooling\temp'
$env:TMP = $env:TEMP
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
New-Item -ItemType Directory -Force -Path $env:PUB_CACHE,$env:APPDATA,$env:LOCALAPPDATA,$env:TEMP | Out-Null
$dart = Join-Path $projectRoot '.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe'
$packageConfig = Join-Path $projectRoot '.dart_tool\package_config.json'
if (!(Test-Path -LiteralPath $dart) -or !(Test-Path -LiteralPath $packageConfig)) {
    throw 'Run tools/flutter.ps1 pub get first; the project-local Dart SDK and package config are required.'
}
$peerArguments = @()
if ($Help) { $peerArguments += '--help' }
elseif ($SelfTest) { $peerArguments += '--self-test' }
else {
    if ([string]::IsNullOrWhiteSpace($HostIPv4)) { throw 'Supply -HostIPv4 with this PC''s numeric LAN IPv4.' }
    $peerArguments += @('--host', $HostIPv4, '--port', "$Port")
    if ($PrepareOnly) { $peerArguments += '--prepare-only' }
    if (![string]::IsNullOrWhiteSpace($BluetoothPython)) { $peerArguments += @('--bluetooth-python', $BluetoothPython) }
    if ($PSBoundParameters.ContainsKey('RunForSeconds')) { $peerArguments += @('--run-for', "$RunForSeconds") }
}
Push-Location $projectRoot
try {
    & $dart "--packages=$packageConfig" (Join-Path $PSScriptRoot 'local_test_peer.dart') @peerArguments
    $peerExit = $LASTEXITCODE
} finally { Pop-Location }
exit $peerExit
