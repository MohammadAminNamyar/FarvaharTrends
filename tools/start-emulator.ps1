param([string]$DeviceName = 'PersianTrend_Android16', [int]$Port = 5554, [string]$ApkPath)
. (Join-Path $PSScriptRoot 'android-env.ps1')
$serial = 'emulator-' + $Port
if (-not (Test-Path -LiteralPath $emulator)) { throw 'Android emulator is not installed in the project SDK.' }
$logDirectory = Join-Path $projectRoot 'artifacts\emulator'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
& $adb start-server | Out-Null
$devices = & $adb devices
if (-not ($devices -match ('^' + [regex]::Escape($serial) + '\s'))) {
    # The requested emulator is an interactive window for the user.
    Start-Process -FilePath $emulator -ArgumentList @('-avd',$DeviceName,'-port',$Port,'-no-snapshot','-no-boot-anim','-no-metrics','-camera-back','none','-camera-front','none','-no-audio','-gpu','auto') -WorkingDirectory $projectRoot -RedirectStandardOutput (Join-Path $logDirectory ($serial + '.stdout.log')) -RedirectStandardError (Join-Path $logDirectory ($serial + '.stderr.log')) | Out-Null
}
Write-Output 'Waiting for Android to finish starting...'
$deadline = [DateTime]::UtcNow.AddMinutes(4)
$booted = $false
while ([DateTime]::UtcNow -lt $deadline) {
    $bootState = & $adb -s $serial shell getprop sys.boot_completed 2>$null
    if ($bootState -match '^1$') { $booted = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $booted) { throw 'Emulator has not finished booting. Check artifacts/emulator logs.' }
$actualAvd = @(& $adb -s $serial emu avd name 2>$null) | Where-Object { $_ -ne 'OK' -and $_.Trim().Length -gt 0 } | Select-Object -First 1
if ($LASTEXITCODE -ne 0 -or $null -eq $actualAvd -or $actualAvd.Trim() -ne $DeviceName) {
    throw 'This emulator port belongs to a different or unknown AVD. No APK was installed.'
}
$apk = if ([string]::IsNullOrWhiteSpace($ApkPath)) { Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk' } else { $ApkPath }
if (-not (Test-Path -LiteralPath $apk)) { throw 'Build the release APK before launching.' }
& $adb -s $serial install -r $apk
if ($LASTEXITCODE -ne 0) { throw 'APK installation failed.' }
& $adb -s $serial shell am start -W -n org.persiantrend.persian_trend/.MainActivity
if ($LASTEXITCODE -ne 0) { throw 'Could not launch PersianTrend.' }
Write-Output 'PersianTrend is running. The emulator keeps its app data when closed.'
