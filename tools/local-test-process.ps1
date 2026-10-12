# Shared read-only identity check. A port number or stale PID file is never
# sufficient authority to reuse or stop a process.
function Get-VerifiedLocalTestPeer {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq 45871 })
    if ($listeners.Count -eq 0) { return $null }
    $processIds = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($processIds.Count -ne 1) { throw 'TCP45871 has multiple owners. No process will be reused or stopped.' }
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $processIds[0]) -ErrorAction Stop
    # Recent Dart SDKs run scripts in a dartvm.exe child of dart.exe. Pin both
    # complete paths, and still require the exact project entrypoint argument.
    $expectedExecutables = @('dart.exe','dartvm.exe') | ForEach-Object {
        [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot ('.tooling\flutter\bin\cache\dart-sdk\bin\' + $_)))
    }
    $expectedScript = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot 'tools\local_test_peer.dart'))
    $scriptPattern = '(?:^|\s|")' + [regex]::Escape($expectedScript) + '(?:"|\s|$)'
    if ($null -eq $process -or [string]::IsNullOrWhiteSpace($process.ExecutablePath) -or
        $expectedExecutables -notcontains [System.IO.Path]::GetFullPath($process.ExecutablePath) -or
        $process.CommandLine -notmatch $scriptPattern) {
        throw 'TCP45871 belongs to a process that is not this project local_test_peer.dart. It was not changed.'
    }
    return $process
}
