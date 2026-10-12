$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$env:PUB_CACHE = Join-Path $projectRoot '.tooling\pub-cache'
$env:GRADLE_USER_HOME = Join-Path $projectRoot '.tooling\gradle'
$env:ANDROID_HOME = Join-Path $projectRoot '.tooling\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_USER_HOME = Join-Path $projectRoot '.tooling\android-user'
$env:APPDATA = Join-Path $projectRoot '.tooling\config'
$env:LOCALAPPDATA = Join-Path $projectRoot '.tooling\local'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
$env:TEMP = Join-Path $projectRoot '.tooling\temp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force -Path $env:PUB_CACHE,$env:GRADLE_USER_HOME,$env:ANDROID_USER_HOME,$env:TEMP,$env:APPDATA,$env:LOCALAPPDATA | Out-Null
Push-Location $projectRoot
try {
    & (Join-Path $projectRoot '.tooling\flutter\bin\flutter.bat') --suppress-analytics @args
    $buildExit = $LASTEXITCODE
} finally { Pop-Location }
exit $buildExit
