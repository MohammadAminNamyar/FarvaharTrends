$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$env:ANDROID_HOME = Join-Path $projectRoot '.tooling\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_USER_HOME = Join-Path $projectRoot '.tooling\android-user'
$env:ANDROID_EMULATOR_HOME = $env:ANDROID_USER_HOME
$env:ANDROID_AVD_HOME = Join-Path $projectRoot '.tooling\avd'
$env:ANDROID_SDK_HOME = $null
$env:USERPROFILE = Join-Path $projectRoot '.tooling\android-home'
$env:APPDATA = Join-Path $projectRoot '.tooling\config'
$env:LOCALAPPDATA = Join-Path $projectRoot '.tooling\local'
$env:TEMP = Join-Path $projectRoot '.tooling\temp'
$env:TMP = $env:TEMP
$env:SDKMANAGER_OPTS = '-Duser.home=' + $env:USERPROFILE
$env:AVDMANAGER_OPTS = '-Duser.home=' + $env:USERPROFILE
New-Item -ItemType Directory -Force -Path $env:ANDROID_USER_HOME,$env:ANDROID_AVD_HOME,$env:USERPROFILE,$env:TEMP,$env:APPDATA,$env:LOCALAPPDATA | Out-Null
$adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
$emulator = Join-Path $env:ANDROID_HOME 'emulator\emulator.exe'
$sdkmanager = Join-Path $env:ANDROID_HOME 'cmdline-tools\latest\bin\sdkmanager.bat'
$avdmanager = Join-Path $env:ANDROID_HOME 'cmdline-tools\latest\bin\avdmanager.bat'
