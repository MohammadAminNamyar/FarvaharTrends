$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$signingDir = Join-Path $projectRoot '.signing'
$keyPath = Join-Path $signingDir 'pilot.jks'
$propertiesPath = Join-Path $signingDir 'key.properties'
if ((Test-Path -LiteralPath $keyPath) -or (Test-Path -LiteralPath $propertiesPath)) {
    throw 'Pilot signing material already exists. Keep it to preserve APK update continuity.'
}
$javaOutput = (& java -XshowSettings:properties -version 2>&1 | Out-String)
$javaHomeMatch = [regex]::Match($javaOutput, 'java.home\s*=\s*([^\r\n]+)')
if (-not $javaHomeMatch.Success) { throw 'A JDK with keytool is required.' }
$keytool = Join-Path $javaHomeMatch.Groups[1].Value.Trim() 'bin\keytool.exe'
if (-not (Test-Path -LiteralPath $keytool)) { throw 'Cannot find the JDK keytool.' }
New-Item -ItemType Directory -Force -Path $signingDir | Out-Null
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$passwordBytes = New-Object byte[] 32
$random.GetBytes($passwordBytes)
$random.Dispose()
$password = [Convert]::ToBase64String($passwordBytes)
$env:FARVAHARTRENDS_STORE_PASSWORD = $password
try {
    & $keytool -genkeypair -keystore $keyPath -storetype JKS -alias pilot -keyalg RSA -keysize 3072 -validity 3650 -dname 'CN=FarvaharTrends Pilot, OU=Testing, O=FarvaharTrends' -storepass:env FARVAHARTRENDS_STORE_PASSWORD -keypass:env FARVAHARTRENDS_STORE_PASSWORD -noprompt
    if ($LASTEXITCODE -ne 0) { throw 'Pilot key generation failed.' }
    @('storeFile=../../.signing/pilot.jks', 'keyAlias=pilot', ('storePassword=' + $password), ('keyPassword=' + $password)) |
        Set-Content -LiteralPath $propertiesPath -Encoding ascii
} finally { Remove-Item Env:FARVAHARTRENDS_STORE_PASSWORD -ErrorAction SilentlyContinue }
Write-Output 'Pilot signing key created in .signing. Do not distribute that directory.'
