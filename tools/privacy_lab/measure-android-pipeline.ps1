# Isolated native roles on Android; host public stores and one monotonic observer.
# This is a measurement apparatus, not APK tooling or a radio/battery trial.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Serial,
    [ValidateRange(1,1000)][int]$Pairs = 20,
    [ValidateRange(0,1000000)][int]$Kbps = 5000,
    [ValidateRange(0,2000)][int]$RttMs = 80,
    [switch]$EmulatorRegression,
    [switch]$ChecksOnly,
    [switch]$FrozenCompletion,
    [ValidateRange(0,300)][int]$IdleRounds = 0,
    [ValidateSet('json','cbor-v1','cbor-framed-v1')][string]$WireCodec = 'json'
)
$ErrorActionPreference = 'Stop'
if ($EmulatorRegression -and $ChecksOnly) { throw 'Choose regression or scheduled checks, not both' }
if ($EmulatorRegression -and $FrozenCompletion) { throw 'Regression covers both completion policies; do not select a pipeline policy' }
if ($IdleRounds -gt 0 -and ($EmulatorRegression -or $ChecksOnly)) { throw 'Idle measurement must run separately from regression and scheduled checks' }
if ($IdleRounds -gt 0 -and $Serial -notmatch '^emulator-[0-9]+$') { throw 'Idle characterization is currently emulator-only' }
if ($EmulatorRegression -and $Serial -notmatch '^emulator-[0-9]+$') { throw 'Regression mode is reserved for an emulator; no physical device will be used' }
$project = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runtime = Join-Path $project '.tooling/privacy-research'
$go = Join-Path $runtime 'go/bin/go.exe'
$adb = Join-Path $project '.tooling/android-sdk/platform-tools/adb.exe'
$dart = Join-Path $project '.tooling/flutter/bin/cache/dart-sdk/bin/dart.exe'
function Invoke-LabAdb([string[]]$Arguments) {
    $output = @(& $adb -s $Serial @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "ADB failed ($LASTEXITCODE): $($Arguments[0]); $($output -join ' ')" }
    return $output
}
if (((Invoke-LabAdb @('get-state')) -join '').Trim() -ne 'device') { throw 'Selected device is unavailable' }
$abi = ((Invoke-LabAdb @('shell','getprop','ro.product.cpu.abi')) -join '').Trim()
$architecture = switch ($abi) { 'arm64-v8a' {'arm64'} 'x86_64' {'amd64'} default { throw "Unsupported lab ABI: $abi" } }
$runId = [Guid]::NewGuid().ToString('N')
$output = Join-Path $project ('artifacts/privacy-lab/android-pipeline-' + $runId)
[IO.Directory]::CreateDirectory($output) | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $output 'runner.ps1')
$remoteDirectory = '/data/local/tmp/farvahar-protocol-' + $runId
$binary = Join-Path $output ('probe-' + $architecture)
$hashes = [ordered]@{}
foreach ($module in @('roundprobe','setupprobe','verdictprobe')) {
    $modulePath = Join-Path $PSScriptRoot $module
    foreach ($file in Get-ChildItem -LiteralPath $modulePath -File -Recurse | Where-Object { $_.Extension -eq '.go' -or $_.Name -in @('go.mod','go.sum') } | Sort-Object FullName) {
        $relative = $module + '/' + [IO.Path]::GetRelativePath($modulePath, $file.FullName).Replace('\','/')
        $target = Join-Path $output ('source/tools/privacy_lab/' + $relative)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $hashes[$relative] = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$env:GOPATH = Join-Path $runtime 'gopath'
$env:GOCACHE = Join-Path $runtime 'gocache'
$env:CGO_ENABLED = '0'
$env:GOOS = 'android'
$env:GOARCH = $architecture
$linker = $null
if ($architecture -eq 'amd64') {
    # Go's Android x86-64 target requires external linking. ARM64 retains the
    # existing pure-Go build; emulator results are only apparatus validation.
    $clang = Join-Path $project '.tooling/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe'
    if (!(Test-Path -LiteralPath $clang)) { throw 'Android x86-64 validation requires the installed NDK clang' }
    $env:CGO_ENABLED = '1'
    $env:CC = ('"' + $clang + '" --target=x86_64-linux-android24')
    $linker = [ordered]@{command=$env:CC;version=@(& $clang --version);sha256=(Get-FileHash -LiteralPath $clang -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$manifest = [ordered]@{
    schema=1; serial=$Serial; architecture=$architecture; abi=$abi
    model=((Invoke-LabAdb @('shell','getprop','ro.product.model')) -join '').Trim()
    androidVersion=((Invoke-LabAdb @('shell','getprop','ro.build.version.release')) -join '').Trim()
    goVersion=(& $go version); remoteDirectory=$remoteDirectory
    sourceSha256=$hashes; sourceSnapshot='source/tools/privacy_lab'
    pairs=$Pairs; kbps=$Kbps; rttMs=$RttMs; wireCodec=$WireCodec; frozenCompletion=[bool]$FrozenCompletion
    candidate=$(if ($FrozenCompletion) { 'fpp1frozen' } else { 'fpp1atomic' })
    testKind=$(if ($EmulatorRegression) { 'native-emulator-regression' } elseif ($IdleRounds -gt 0) { 'native-emulator-idle-resources' } elseif ($ChecksOnly) { 'native-scheduled-checks' } else { 'scheduled-pipeline' })
    idleRounds=$IdleRounds
    runnerSha256=(Get-FileHash -LiteralPath (Join-Path $output 'runner.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    checksProfile=@{kbps=0;rttMs=0;wireCodec=$WireCodec}
    scope='Eleven native roles on one Android device; host public stores/monotonic observer; USB/ADB overhead retained; not independent-device, mobile-radio, battery or APK evidence'
    productionIntegrationAllowed=$false; deviceTemporaryFilesRemoved=$false
    deviceTemporaryDirectoryCreated=$false; cgoEnabled=$env:CGO_ENABLED; externalLinker=$linker
}
function Save-LabManifest { $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'manifest.json') -Encoding utf8NoBOM }
function Get-LabDeviceState {
    [ordered]@{
        capturedUtc=[DateTime]::UtcNow.ToString('o')
        batteryFields=@(Invoke-LabAdb @('shell','dumpsys','battery')) | Where-Object { $_ -match '^\s*(AC powered|USB powered|Wireless powered|level|scale|voltage|temperature|status|health|Charge counter):' }
        wakefulness=@(Invoke-LabAdb @('shell','dumpsys','power')) | Where-Object { $_ -match '^\s*mWakefulness=' }
    }
}
function Get-LabOwnedProcesses {
    # Android's ARGS column strips executable directories, even with -w. Select
    # the basename, then verify /proc/exe; never use a basename alone to kill.
    $rows = @(Invoke-LabAdb @('shell','ps','-A','-o','PID,NAME'))
    foreach ($row in $rows) {
        if ($row -match '^\s*(\d+)\s+probe\s*$') {
            $candidatePid = $Matches[1]
            $exe = ((& $adb -s $Serial shell readlink ('/proc/'+$candidatePid+'/exe') 2>$null) -join '').Trim()
            if ($LASTEXITCODE -eq 0 -and $exe -ceq $remoteDirectory+'/probe') {
                [pscustomobject]@{pid=$candidatePid;executable=$exe}
            }
        }
    }
}
$created = $false
$failed = $false
Push-Location $project
try {
    Save-LabManifest
    # Compile the archived source tree, so the build cannot race later edits.
    if ($EmulatorRegression) {
        & $go -C (Join-Path $output 'source/tools/privacy_lab/roundprobe') test -c -trimpath -o $binary . > (Join-Path $output 'build.log') 2>&1
    } else {
        & $go -C (Join-Path $output 'source/tools/privacy_lab/roundprobe') build -trimpath -o $binary . > (Join-Path $output 'build.log') 2>&1
    }
    if ($LASTEXITCODE) { throw "Native build failed; see $output/build.log" }
    $manifest['binarySha256'] = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    $config = [ordered]@{schema=1;serial=$Serial;architecture=$architecture;remoteDirectory=$remoteDirectory;binarySha256=$manifest.binarySha256;sourceSha256=$hashes}
    $configPath = Join-Path $output 'worker-config.json'
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    # All interpolated remote values are this fresh UUID path; arguments are
    # passed through exec and separately bounded by android_worker.dart.
    $launcher = "#!/system/bin/sh`ncd '$remoteDirectory' || exit 91`nexport TMPDIR='$remoteDirectory'`nexec '$remoteDirectory/probe' `"`$@`"`n"
    Set-Content -LiteralPath (Join-Path $output 'run-probe') -Value $launcher -NoNewline -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $output '.lab-owner') -Value $runId -NoNewline -Encoding utf8NoBOM
    Invoke-LabAdb @('shell','mkdir',$remoteDirectory) | Out-Null
    $created = $true
    $manifest['deviceTemporaryDirectoryCreated'] = $true
    Invoke-LabAdb @('shell','chmod','700',$remoteDirectory) | Out-Null
    Invoke-LabAdb @('push',(Join-Path $output '.lab-owner'),($remoteDirectory+'/.lab-owner')) | Out-Null
    Invoke-LabAdb @('push',$binary,($remoteDirectory+'/probe')) | Out-Null
    Invoke-LabAdb @('push',(Join-Path $output 'run-probe'),($remoteDirectory+'/run-probe')) | Out-Null
    Invoke-LabAdb @('shell','chmod','700',($remoteDirectory+'/probe'),($remoteDirectory+'/run-probe')) | Out-Null
    Invoke-LabAdb @('shell','mkdir','-p',($remoteDirectory+'/tools/privacy_lab')) | Out-Null
    foreach ($module in @('roundprobe','setupprobe','verdictprobe')) {
        Invoke-LabAdb @('push',(Join-Path $output ('source/tools/privacy_lab/'+$module)),($remoteDirectory+'/tools/privacy_lab/')) | Out-Null
    }
    $remoteHash = (((Invoke-LabAdb @('shell','sha256sum',($remoteDirectory+'/probe'))) -join '').Trim() -split '\s+')[0]
    if ($remoteHash -ne $manifest.binarySha256) { throw 'Transferred Android binary hash mismatch' }
    $manifest['remoteBinaryVerified'] = $true
    $manifest['before'] = Get-LabDeviceState
    $manifest['startedUtc'] = [DateTime]::UtcNow.ToString('o')
    Save-LabManifest
    if ($EmulatorRegression) {
        $manifest['scope'] = 'Native Go regression suite on Android emulator, including controlled clocks and crash subprocesses; not scheduled throughput, physical-device CPU, battery or anonymity acceptance'
        $manifest['regressionTimeout'] = '8m'
        Save-LabManifest
        Invoke-LabAdb @('shell','mkdir','-p',($remoteDirectory+'/.local-only/privacy-lab')) | Out-Null
        & $adb -s $Serial shell -T ($remoteDirectory+'/run-probe') '-test.v' '-test.timeout=8m' > (Join-Path $output 'regression.stdout.log') 2> (Join-Path $output 'regression.stderr.log')
        $testExit = $LASTEXITCODE
        $manifest['regressionExitCode'] = $testExit
        $testOutput = @(Get-Content -LiteralPath (Join-Path $output 'regression.stdout.log'))
        $manifest['passedTopLevel'] = @($testOutput | Where-Object { $_ -match '^--- PASS: ' }).Count
        $manifest['passedIncludingSubtests'] = @($testOutput | Where-Object { $_ -match '^\s*--- PASS: ' }).Count
        $manifest['skippedTopLevel'] = @($testOutput | Where-Object { $_ -match '^--- SKIP: ' }).Count
        $manifest['failedIncludingSubtests'] = @($testOutput | Where-Object { $_ -match '^\s*--- FAIL: ' }).Count
        if ($testExit -ne 0 -or $manifest.passedTopLevel -eq 0 -or $testOutput -notcontains 'PASS') { throw 'Native emulator regression failed; evidence retained' }
    } elseif ($IdleRounds -gt 0) {
        $manifest['scope'] = 'Idle common-schedule native roles on one emulator; private CPU observations and TLS byte counters; not physical-device CPU, daily mobile traffic, battery or anonymity acceptance'
        Save-LabManifest
        $idleMode = if ($FrozenCompletion) { 'network-frozen-idle' } else { 'network-schedule-idle' }
        & $adb -s $Serial shell -T ($remoteDirectory+'/run-probe') -mode $idleMode -samples $IdleRounds -kbps $Kbps -rtt-ms $RttMs -wire $WireCodec > (Join-Path $output 'idle.stdout.log') 2> (Join-Path $output 'idle.stderr.log')
        $manifest['idleExitCode'] = $LASTEXITCODE
        $manifest['idle'] = Get-Content -LiteralPath (Join-Path $output 'idle.stdout.log') -Raw | ConvertFrom-Json
        if ($manifest.idleExitCode -ne 0 -or $manifest.idle.completedMeasuredRounds -ne $IdleRounds -or $manifest.idle.failure) { throw 'Native idle characterization failed; evidence retained' }
    } else {
    $checksMode = if ($FrozenCompletion) { 'network-frozen-checks' } else { 'network-schedule-atomic-checks' }
    & $adb -s $Serial shell -T ($remoteDirectory+'/run-probe') -mode $checksMode -wire $WireCodec > (Join-Path $output 'checks.stdout.log') 2> (Join-Path $output 'checks.stderr.log')
    $manifest['checksExitCode'] = $LASTEXITCODE
    if ($LASTEXITCODE) { throw 'Android separate-process checks failed; evidence retained' }
    $manifest['checks'] = Get-Content -LiteralPath (Join-Path $output 'checks.stdout.log') -Raw | ConvertFrom-Json
    $expectedChecks = if ($FrozenCompletion) { 19 } else { 17 }
    $expectedMessages = if ($FrozenCompletion) { 9 } else { 8 }
    if ($manifest.checks.passed -ne $expectedChecks -or $manifest.checks.receivedMessages -ne $expectedMessages -or [bool]$manifest.checks.frozenCompletion -ne [bool]$FrozenCompletion) { throw 'Incomplete or wrong-policy Android checks' }
    if (!$ChecksOnly) {
    $manifest['beforePipeline'] = Get-LabDeviceState
    Save-LabManifest
    & $dart --packages=.dart_tool/package_config.json tools/privacy_lab/submission_pipeline.dart $Pairs $manifest.candidate $Kbps $RttMs $configPath $WireCodec > (Join-Path $output 'pipeline.stdout.log') 2> (Join-Path $output 'pipeline.stderr.log')
    $manifest['pipelineExitCode'] = $LASTEXITCODE
    $pipelineOutput = Get-Content -LiteralPath (Join-Path $output 'pipeline.stdout.log') -Raw | ConvertFrom-Json
    $manifest['pipelineResult'] = $pipelineOutput.result
    if ($LASTEXITCODE) { throw 'Android paired pipeline failed; evidence retained' }
    }
    }
} catch {
    $failed = $true
    $manifest['failure'] = $_.Exception.Message
} finally {
    $manifest['endedUtc'] = [DateTime]::UtcNow.ToString('o')
    if ($created) {
        try {
            # Kill only still-running executables belonging to this fresh run.
            # Normal completion already reaps every role before this point.
            $owned = @(Get-LabOwnedProcesses)
            $manifest['ownedProcessesAtCleanup'] = @($owned)
            foreach ($process in $owned) {
                $ownedPid = $process.pid
                $exe = ((& $adb -s $Serial shell readlink ('/proc/'+$ownedPid+'/exe') 2>$null) -join '').Trim()
                if ($exe -ceq $remoteDirectory+'/probe') { & $adb -s $Serial shell kill -TERM $ownedPid | Out-Null }
            }
            if ($owned.Count) { Start-Sleep -Seconds 1 }
            $remaining = @(Get-LabOwnedProcesses)
            $manifest['ownedProcessesRemaining'] = @($remaining)
            if ($remaining.Count) { throw 'Owned Android test processes still running; directory retained' }
            $manifest['after'] = Get-LabDeviceState
            & $adb -s $Serial pull ($remoteDirectory+'/.local-only/privacy-lab') (Join-Path $output 'device-runs') > (Join-Path $output 'pull.log') 2>&1
            $manifest['evidencePullExitCode'] = $LASTEXITCODE
            if ($LASTEXITCODE) { throw 'Could not retrieve Android evidence; directory retained' }
            # Resolve the absolute target and verify its ownership before the
            # sole recursive removal. Never remove a computed parent directory.
            $resolved = ((Invoke-LabAdb @('shell','realpath',$remoteDirectory)) -join '').Trim()
            $owner = ((Invoke-LabAdb @('shell','cat',($remoteDirectory+'/.lab-owner'))) -join '').Trim()
            if ($remoteDirectory -notmatch '^/data/local/tmp/farvahar-protocol-[a-f0-9]{32}$' -or $resolved -cne $remoteDirectory -or $owner -cne $runId) { throw 'Temporary-directory ownership check failed' }
            Invoke-LabAdb @('shell','rm','-rf','--',$remoteDirectory) | Out-Null
            & $adb -s $Serial shell test '!' -e $remoteDirectory
            $manifest['deviceTemporaryFilesRemoved'] = $LASTEXITCODE -eq 0
            if (!$manifest.deviceTemporaryFilesRemoved) { throw 'Temporary directory still exists' }
        } catch {
            $failed = $true
            $manifest['cleanupFailure'] = $_.Exception.Message
        }
    }
    Save-LabManifest
    Pop-Location
}
[ordered]@{manifest=(Join-Path $output 'manifest.json');pipelineResult=$manifest.pipelineResult;failure=$manifest.failure;cleanupFailure=$manifest.cleanupFailure;deviceTemporaryFilesRemoved=$manifest.deviceTemporaryFilesRemoved} | ConvertTo-Json
if ($failed) { exit 1 }
