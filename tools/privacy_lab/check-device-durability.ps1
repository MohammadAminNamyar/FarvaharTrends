# Isolated native crash-storage checks; no APK, radio or host-network changes.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Serial)
$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$adb = Join-Path $project '.tooling/android-sdk/platform-tools/adb.exe'
$go = Join-Path $project '.tooling/privacy-research/go/bin/go.exe'
if ((& $adb -s $Serial get-state) -ne 'device') { throw 'Device unavailable.' }
$abi = (& $adb -s $Serial shell getprop ro.product.cpu.abi).Trim()
$arch = switch ($abi) { 'arm64-v8a' {'arm64'} 'x86_64' {'amd64'} default { throw 'Unsupported ABI' } }
$runId = [Guid]::NewGuid().ToString('N')
$output = Join-Path $project ('artifacts/privacy-lab/device-journal-' + $runId)
[IO.Directory]::CreateDirectory($output) | Out-Null
$hashes = [ordered]@{}
foreach ($module in @('roundprobe','setupprobe','verdictprobe')) {
 $root = Join-Path $PSScriptRoot $module
 Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Extension -eq '.go' -or $_.Name -in @('go.mod','go.sum') } | Sort-Object FullName | ForEach-Object {
  $relative = $module + '/' + [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\','/')
  $hashes[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  $target = Join-Path $output ('source/' + $relative)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
  Copy-Item -LiteralPath $_.FullName -Destination $target
 }
}
$env:GOPATH = Join-Path $project '.tooling/privacy-research/gopath'
$env:GOCACHE = Join-Path $project '.tooling/privacy-research/gocache'
$env:CGO_ENABLED='0'
$env:GOOS='android'
$env:GOARCH=$arch
$binary=Join-Path $output ('journal-tests-' + $arch)
& $go -C (Join-Path $PSScriptRoot 'roundprobe') test -c -o $binary .
if ($LASTEXITCODE) { throw 'Native test build failed' }
$manifest=[ordered]@{schema=1;serial=$Serial;model=(& $adb -s $Serial shell getprop ro.product.model).Trim();androidVersion=(& $adb -s $Serial shell getprop ro.build.version.release).Trim();abi=$abi;sourceSha256=$hashes;binarySha256=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant();binaryFile=[IO.Path]::GetFileName($binary);sourceSnapshot='source';scope='Native Android process-crash and encrypted journal checks as adb shell user; not APK integration, physical transport, battery, power loss or malicious rollback'}
$remoteDir='/data/local/tmp/farvahar-journal-' + $runId
$remoteBinary=$remoteDir + '/probe'
$created=$false
try {
 & $adb -s $Serial shell mkdir $remoteDir
 if ($LASTEXITCODE) { throw 'Cannot create private temporary test directory' }
 $created=$true
 & $adb -s $Serial shell mkdir ($remoteDir + '/tmp')
 if ($LASTEXITCODE) { throw 'Cannot create test scratch directory' }
 & $adb -s $Serial push $binary $remoteBinary | Out-Null
 if ($LASTEXITCODE) { throw 'Cannot transfer native tests' }
 & $adb -s $Serial shell chmod 700 $remoteBinary
 if ($LASTEXITCODE) { throw 'Cannot make native tests executable' }
 $manifest.startedUtc=[DateTime]::UtcNow.ToString('o')
 # shell-v2 returns the native process status; exec-out can return transport
 # success even when the test process exits nonzero. Require the PASS marker too.
 $raw=(& $adb -s $Serial shell -T env ('TMPDIR=' + $remoteDir + '/tmp') $remoteBinary '-test.v' '-test.timeout' '90s' | Out-String)
 $manifest.exitCode=$LASTEXITCODE
 $manifest.endedUtc=[DateTime]::UtcNow.ToString('o')
 Set-Content -LiteralPath (Join-Path $output 'test-output.txt') -Value $raw -Encoding utf8NoBOM
 if ($manifest.exitCode -ne 0 -or $raw -notmatch '(?m)^PASS\s*$') { throw 'Native crash-storage tests failed; inspect saved output' }
 $manifest.passed=$true
} catch {
 $manifest.failure=$_.Exception.Message
 throw
} finally {
 if ($created -and $remoteDir -match '^/data/local/tmp/farvahar-journal-[a-f0-9]{32}$') {
  & $adb -s $Serial shell rm $remoteBinary
  $binaryRemoved=$LASTEXITCODE -eq 0
  & $adb -s $Serial shell rmdir ($remoteDir + '/tmp')
  $scratchRemoved=$LASTEXITCODE -eq 0
  & $adb -s $Serial shell rmdir $remoteDir
  $manifest.deviceTemporaryFilesRemoved=$binaryRemoved -and $scratchRemoved -and $LASTEXITCODE -eq 0
 }
 $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'manifest.json') -Encoding utf8NoBOM
}
Write-Output ([pscustomobject]@{directory=$output;passed=$manifest.passed;temporaryFilesRemoved=$manifest.deviceTemporaryFilesRemoved} | ConvertTo-Json)
