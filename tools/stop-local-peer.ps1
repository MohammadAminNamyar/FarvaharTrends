param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'local-test-process.ps1')
$peer = Get-VerifiedLocalTestPeer -ProjectRoot $projectRoot
if ($null -eq $peer) { Write-Output 'No local test peer is listening. No processes changed.'; return }
if ($CheckOnly) {
    Write-Output ('Would stop only verified project local_test_peer.dart PID ' + $peer.ProcessId + '. No processes changed.')
    return
}
$current = Get-VerifiedLocalTestPeer -ProjectRoot $projectRoot
if ($null -eq $current -or $current.ProcessId -ne $peer.ProcessId -or $current.CreationDate -ne $peer.CreationDate) {
    throw 'Process identity changed while checking; no process was stopped.'
}
Stop-Process -Id $current.ProcessId -ErrorAction Stop
Write-Output 'Stopped the verified PC local test peer. Android emulator windows and firewall rules remain open/unchanged.'
