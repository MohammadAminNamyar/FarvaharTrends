# Local component experiments, not an APK release or a battery test.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Serial,
    [ValidateSet('sphinxprobe','shuffleprobe','roundprobe','verdictprobe','setupprobe')][string]$Module = 'sphinxprobe',
    [ValidateRange(1,20000)][int]$Samples = 1000,
    [ValidateRange(32,8192)][int]$PayloadBytes = 8192,
    [ValidateSet('x25519','xwing')][string]$Scheme = 'x25519',
    [ValidateSet('component','control','control-compare','journal-compare')][string]$ProbeMode = 'component'
)
$ErrorActionPreference = 'Stop'
if ($ProbeMode -like 'control*' -and ($Module -ne 'verdictprobe' -or $PayloadBytes -ne 128)) { throw 'Control mode requires verdictprobe and a 128-byte payload.' }
if ($ProbeMode -eq 'control-compare' -and $Samples % 4 -ne 0) { throw 'Control comparison needs complete ABBA blocks (samples divisible by four).' }
if ($ProbeMode -eq 'journal-compare' -and ($Module -ne 'roundprobe' -or $Samples -gt 40 -or $Samples % 4 -ne 0)) { throw 'Journal comparison needs roundprobe, 4..40 samples and complete ABBA blocks.' }
if ($Module -eq 'shuffleprobe' -and $Samples -gt 50) { throw 'Shuffle probe accepts at most 50 batches.' }
if ($Module -eq 'verdictprobe' -and $Samples -gt 300) { throw 'Verdict component accepts at most 300 slot rounds.' }
if ($Module -eq 'setupprobe' -and ($Samples -gt 50 -or $PayloadBytes -ne 32)) { throw 'Setup probe accepts at most 50 setups with 32-byte public keys.' }
$project = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runtime = Join-Path $project '.tooling/privacy-research'
$go = Join-Path $runtime 'go/bin/go.exe'
$adb = Join-Path $project '.tooling/android-sdk/platform-tools/adb.exe'
if ((& $adb -s $Serial get-state) -ne 'device') { throw 'Selected device is not available.' }
$abi = (& $adb -s $Serial shell getprop ro.product.cpu.abi).Trim()
$architecture = switch ($abi) { 'arm64-v8a' {'arm64'} 'x86_64' {'amd64'} default {throw "Unsupported lab ABI: $abi"} }
$runId = [Guid]::NewGuid().ToString('N')
$output = Join-Path $project ('artifacts/privacy-lab/device-' + $runId)
New-Item -ItemType Directory -Path $output | Out-Null
$binary = Join-Path $output ($Module + '-' + $architecture)
$env:GOPATH = Join-Path $runtime 'gopath'
$env:GOCACHE = Join-Path $runtime 'gocache'
$env:CGO_ENABLED = '0'
$env:GOOS = 'android'
$env:GOARCH = $architecture
$modulePath = Join-Path $PSScriptRoot $Module
$sourceSnapshot = Join-Path $output 'source'
New-Item -ItemType Directory -Path $sourceSnapshot | Out-Null
$hashes = [ordered]@{}
$snapshotModules = @($Module)
if ($Module -eq 'roundprobe') { $snapshotModules += @('setupprobe','verdictprobe') }
foreach ($snapshotModule in $snapshotModules) {
    $snapshotModulePath = Join-Path $PSScriptRoot $snapshotModule
    Get-ChildItem -LiteralPath $snapshotModulePath -File -Recurse | Where-Object { $_.Extension -eq '.go' -or $_.Name -in @('go.mod','go.sum') } | Sort-Object FullName | ForEach-Object {
        $relative = $snapshotModule + '/' + [IO.Path]::GetRelativePath($snapshotModulePath, $_.FullName).Replace('\','/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $target = Join-Path $sourceSnapshot $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target
    }
}
Push-Location $modulePath
try {
    & $go build -o $binary .
    if ($LASTEXITCODE) { throw 'Device probe build failed' }
} finally { Pop-Location }
function Get-LabDeviceState {
    $battery = @(& $adb -s $Serial shell dumpsys battery) | Where-Object {
        $_ -match '^\s*(AC powered|USB powered|Wireless powered|level|scale|voltage|temperature|status|health|Charge counter):'
    }
    return [ordered]@{
        capturedUtc = [DateTime]::UtcNow.ToString('o')
        batteryFields = @($battery)
        wakefulness = @(& $adb -s $Serial shell dumpsys power) | Where-Object { $_ -match '^\s*mWakefulness=' }
    }
}
$manifest = [ordered]@{
    schema = 1
    module = $Module
    serial = $Serial
    model = (& $adb -s $Serial shell getprop ro.product.model).Trim()
    androidVersion = (& $adb -s $Serial shell getprop ro.build.version.release).Trim()
    abi = $abi
    goVersion = (& $go version)
    sourceSha256 = $hashes
    sourceSnapshot = 'source'
    sourceModule = $Module
    probeMode = $ProbeMode
    binarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    samples = $Samples
    payloadBytes = $PayloadBytes
    scope = 'Component computation on a connected device. USB/charging state recorded. Not a radio or battery measurement.'
    before = Get-LabDeviceState
}
$remoteDir = '/data/local/tmp/farvahar-lab-' + $runId
$remoteBinary = $remoteDir + '/probe'
$created = $false
try {
    & $adb -s $Serial shell mkdir $remoteDir
    if ($LASTEXITCODE) { throw 'Temporary device directory could not be created' }
    $created = $true
    & $adb -s $Serial push $binary $remoteBinary | Out-Null
    if ($LASTEXITCODE) { throw 'Device probe transfer failed' }
    & $adb -s $Serial shell chmod 700 $remoteBinary
    if ($LASTEXITCODE) { throw 'Device probe permission failed' }
    $arguments = @('-samples', "$Samples", '-payload', "$PayloadBytes", '-hops', '3')
    if ($Module -eq 'sphinxprobe') { $arguments += @('-scheme',$Scheme) } else { $arguments += @('-cohort','8') }
    if ($ProbeMode -like 'control*' -or $ProbeMode -eq 'journal-compare') { $arguments += @('-mode',$ProbeMode) }
    $manifest['arguments'] = $arguments
    $manifest['startedUtc'] = [DateTime]::UtcNow.ToString('o')
    $raw = (& $adb -s $Serial shell -T env ('TMPDIR=' + $remoteDir) $remoteBinary @arguments | Out-String)
    $runExit = $LASTEXITCODE
    $manifest['endedUtc'] = [DateTime]::UtcNow.ToString('o')
    $manifest['exitCode'] = $runExit
    Set-Content -LiteralPath (Join-Path $output 'result.json') -Value $raw -Encoding utf8NoBOM
    if ($runExit) { throw "Device experiment failed with exit $runExit" }
    $result = $raw | ConvertFrom-Json
    if ($result.os -ne 'android' -or $result.arch -ne $architecture) { throw 'Unexpected device result platform' }
    $manifest['parsedResult'] = $true
} catch {
    $manifest['failure'] = $_.Exception.Message
    throw
} finally {
    $manifest['after'] = Get-LabDeviceState
    # Only remove the exact file in the fresh per-run directory; never recurse.
    if ($created -and $remoteDir -match '^/data/local/tmp/farvahar-lab-[a-f0-9]{32}$') {
        & $adb -s $Serial shell rm $remoteBinary
        $removed = $LASTEXITCODE -eq 0
        & $adb -s $Serial shell rmdir $remoteDir
        $manifest['deviceTemporaryFilesRemoved'] = $removed -and $LASTEXITCODE -eq 0
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'manifest.json') -Encoding utf8NoBOM
}
Write-Output ([PSCustomObject]$manifest | Select-Object module,model,abi,startedUtc,endedUtc,deviceTemporaryFilesRemoved | ConvertTo-Json)
Write-Output ("Results: " + $output)
