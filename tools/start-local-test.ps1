param(
    [string]$HostIPv4 = '192.168.0.43',
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'local-test-process.ps1')
$address = $null
if (![System.Net.IPAddress]::TryParse($HostIPv4, [ref]$address) -or
    $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Supply the PC numeric Wi-Fi IPv4.'
}
$assigned = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq $HostIPv4 })
if ($assigned.Count -eq 0) {
    throw "This PC no longer has $HostIPv4. Rebuild the local Wi-Fi APK/bootstrap for its current Wi-Fi address before testing."
}
$distribution = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'distribution\FarvaharTrends-local-test'))
$apk = Get-ChildItem -LiteralPath $distribution -Filter '*-local-wifi.apk' -File -ErrorAction Stop |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if ($null -eq $apk -or !([System.IO.Path]::GetFullPath($apk.FullName).StartsWith($distribution + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'No local Wi-Fi APK exists inside distribution/FarvaharTrends-local-test.'
}
$peer = Get-VerifiedLocalTestPeer -ProjectRoot $projectRoot
$bluetoothPython = $null
$pythonReference = Join-Path $projectRoot '.tooling\ble-python-executable.txt'
if ((Test-Path -LiteralPath $pythonReference) -and (Test-Path -LiteralPath (Join-Path $projectRoot '.tooling\ble-python\bleak'))) {
    $candidatePython = (Get-Content -LiteralPath $pythonReference -Raw).Trim()
    if ([System.IO.Path]::IsPathRooted($candidatePython) -and (Test-Path -LiteralPath $candidatePython -PathType Leaf)) { $bluetoothPython = $candidatePython }
}
if ($null -ne $peer -and $peer.CommandLine -notmatch ('--host\s+"?' + [regex]::Escape($HostIPv4) + '(?:"|\s|$)')) {
    throw 'The verified local peer uses another host address. Stop it explicitly before restarting this local test.'
}
if ($CheckOnly) {
    Write-Output "Validated PC IPv4: $HostIPv4"
    Write-Output ('Local test APK: ' + $apk.FullName)
    if ($null -ne $peer) { Write-Output ('Verified relay PID: ' + $peer.ProcessId) }
    else { Write-Output 'No relay is listening; a normal start would launch it.' }
    Write-Output 'Check only: no processes or firewall settings changed.'
    return
}
$logDirectory = Join-Path $projectRoot 'artifacts\local-test'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($null -eq $peer) {
    $launcher = Join-Path $PSScriptRoot 'start-local-peer.ps1'
    $launcherArguments = @('-NoProfile','-File',('"' + $launcher + '"'),'-HostIPv4',$HostIPv4)
    if ($null -ne $bluetoothPython) { $launcherArguments += @('-BluetoothPython', ('"' + $bluetoothPython + '"')) }
    $process = Start-Process -FilePath $powerShell -ArgumentList $launcherArguments `
        -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $logDirectory ($stamp + '-peer.stdout.log')) `
        -RedirectStandardError (Join-Path $logDirectory ($stamp + '-peer.stderr.log'))
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $peer = Get-VerifiedLocalTestPeer -ProjectRoot $projectRoot
        if ($null -ne $peer) { break }
        if ($process.HasExited) { throw 'Local peer startup failed. See artifacts/local-test logs.' }
    }
    if ($null -eq $peer) { throw 'Local peer did not become ready. See artifacts/local-test logs.' }
}
Write-Output ('Using verified local peer PID ' + $peer.ProcessId + ' at ' + $HostIPv4 + ':45871.')
$emulatorLauncher = Join-Path $PSScriptRoot 'start-emulator.ps1'
foreach ($device in @(@{Name='FarvaharTrends_Android16';Port=5554}, @{Name='FarvaharTrends_Peer';Port=5556})) {
    # The wrapper is hidden; start-emulator opens the interactive Android window.
    # Installing with -r preserves each emulator's existing app identity/data.
    Start-Process -FilePath $powerShell -ArgumentList @('-NoProfile','-File',('"' + $emulatorLauncher + '"'),'-DeviceName',$device.Name,'-Port',$device.Port,'-ApkPath',('"' + $apk.FullName + '"')) `
        -WorkingDirectory $projectRoot -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logDirectory ($stamp + '-' + $device.Port + '.stdout.log')) `
        -RedirectStandardError (Join-Path $logDirectory ($stamp + '-' + $device.Port + '.stderr.log')) | Out-Null
    Write-Output ('Starting/reusing ' + $device.Name + ' on emulator-' + $device.Port + '.')
}
Write-Output 'Keep this PC awake and connect the Android phone to the same Wi-Fi. Emulator setup continues in the local-test logs.'
Write-Output 'Firewall settings were not changed. Stop-Local-Peer.cmd stops only the verified PC relay.'
