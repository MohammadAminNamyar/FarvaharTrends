param(
    [string]$AdvertiseIPv4,
    [ValidateRange(1,65535)][int]$Port,
    [ValidateRange(1,65535)][int]$AdvertisePort,
    [string]$DataDir,
    [string]$PublicOutput,
    [string]$Name,
    [string[]]$Bootstrap = @(),
    [string[]]$Seed = @(),
    [switch]$AcceptEnrollment,
    [switch]$PrepareOnly,
    [ValidateRange(1,86400)][int]$RunForSeconds,
    [switch]$SelfTest,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$dart = Join-Path $projectRoot '.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path -LiteralPath $dart)) {
    $installedDart = Get-Command dart -ErrorAction SilentlyContinue
    if (-not $installedDart) { throw 'Install the documented Flutter/Dart SDK and run flutter pub get first.' }
    $dart = $installedDart.Source
}
$packageConfig = Join-Path $projectRoot '.dart_tool\package_config.json'
if (-not (Test-Path -LiteralPath $packageConfig)) { throw 'Run flutter pub get in this checkout first.' }
$peerArguments = @()
if ($Help) { $peerArguments += '--help' }
elseif ($SelfTest) { $peerArguments += '--self-test' }
else {
    if ([string]::IsNullOrWhiteSpace($DataDir)) { $DataDir = Join-Path $projectRoot '.tooling\volunteer-peer' }
    $peerArguments += @('--data-dir', $DataDir)
    if ($AdvertiseIPv4) { $peerArguments += @('--advertise', $AdvertiseIPv4) }
    if ($PSBoundParameters.ContainsKey('Port')) { $peerArguments += @('--port', "$Port") }
    if ($PSBoundParameters.ContainsKey('AdvertisePort')) { $peerArguments += @('--advertise-port', "$AdvertisePort") }
    if ($PSBoundParameters.ContainsKey('RunForSeconds')) { $peerArguments += @('--run-for', "$RunForSeconds") }
    if ($PublicOutput) { $peerArguments += @('--public-output', $PublicOutput) }
    if ($Name) { $peerArguments += @('--name', $Name) }
    if ($AcceptEnrollment) { $peerArguments += '--accept-enrollment' }
    if ($PrepareOnly) { $peerArguments += '--prepare-only' }
    foreach ($path in $Bootstrap) { $peerArguments += @('--bootstrap', $path) }
    foreach ($path in $Seed) { $peerArguments += @('--seed', $path) }
}
Push-Location $projectRoot
try {
    & $dart "--packages=$packageConfig" (Join-Path $PSScriptRoot 'volunteer_peer.dart') @peerArguments
    $peerExit = $LASTEXITCODE
} finally { Pop-Location }
exit $peerExit
