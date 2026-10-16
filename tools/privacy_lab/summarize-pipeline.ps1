# Read-only analysis of completed paired experiments. Never rewrites raw evidence.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Result)
$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $Result).Path
$report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
function Get-Distribution([double[]]$Values) {
 if ($Values.Count -eq 0) { return $null }
 $sorted = @($Values | Sort-Object)
 return [ordered]@{
  count=$sorted.Count
  mean=($sorted | Measure-Object -Average).Average
  p50=$sorted[[Math]::Max(0,[Math]::Ceiling(.50*$sorted.Count)-1)]
  p95=$sorted[[Math]::Max(0,[Math]::Ceiling(.95*$sorted.Count)-1)]
  p99=$sorted[[Math]::Max(0,[Math]::Ceiling(.99*$sorted.Count)-1)]
  max=$sorted[-1]
 }
}
$attempted = @($report.rows | Where-Object { $_.warmup -eq $false })
$valid = @()
$failures = @()
foreach ($row in $attempted) {
 if ($row.direct.received -ne $true -or $row.protected.received -ne $true) {
  $failures += [ordered]@{pair=$row.pair;reason='one or both arms not received'}
  continue
 }
 foreach ($arm in @('direct','protected')) {
  $reading=$row.$arm
  if ($null -eq $reading.lowerMs -or $null -eq $reading.upperMs -or
      $reading.lowerMs -lt 0 -or $reading.upperMs -lt $reading.lowerMs) {
   throw "Invalid receipt interval at pair $($row.pair), $arm"
  }
 }
 $lower=[double]$row.protected.lowerMs-[double]$row.direct.upperMs
 $upper=[double]$row.protected.upperMs-[double]$row.direct.lowerMs
 if ($null -eq $row.additionalLowerMs -or $null -eq $row.additionalUpperMs -or
     [Math]::Abs($lower-[double]$row.additionalLowerMs) -gt .00001 -or
     [Math]::Abs($upper-[double]$row.additionalUpperMs) -gt .00001) {
  throw "Paired interval mismatch at pair $($row.pair)"
 }
 $valid += $row
}
$widths=@(foreach ($row in $valid) { foreach ($arm in @('direct','protected')) {
 [double]$row.$arm.upperMs-[double]$row.$arm.lowerMs
}})
$over=@($valid | Where-Object { $_.additionalUpperMs -gt 5000 })
$output=[ordered]@{
 schema=1
 result=$path
 rawResultSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
 requestedPairs=$report.requestedPairs
 attemptedMeasuredPairs=$attempted.Count
 completedMeasuredPairs=$valid.Count
 failedMeasuredPairs=$failures.Count
 unattemptedMeasuredPairs=[Math]::Max(0,$report.requestedPairs-$attempted.Count)
 warmupRows=@($report.rows | Where-Object {$_.warmup -eq $true}).Count
 failedWarmupRows=@($report.rows | Where-Object {$_.warmup -eq $true -and ($_.direct.received -ne $true -or $_.protected.received -ne $true)}).Count
 fatal=$report.fatal
 workerExitCode=$report.workerExitCode
 workerForcedStop=$report.workerForcedStop -eq $true
 workerErrors=$report.workerErrors
 publicErrorCount=@($report.publicErrors).Count
 proxyErrorCount=@($report.proxyErrors).Count
 additionalConservativeUpperMs=Get-Distribution @($valid | ForEach-Object {[double]$_.additionalUpperMs})
 additionalLowerMs=Get-Distribution @($valid | ForEach-Object {[double]$_.additionalLowerMs})
 directReceiptUpperMs=Get-Distribution @($valid | ForEach-Object {[double]$_.direct.upperMs})
 protectedReceiptUpperMs=Get-Distribution @($valid | ForEach-Object {[double]$_.protected.upperMs})
 receiptObservationWidthMs=Get-Distribution $widths
 observedUpperBoundsOver5000ms=$over.Count
 exceededPairs=@($over | ForEach-Object {$_.pair})
 slotWaitMs=Get-Distribution @($valid | Where-Object {$null -ne $_.protected.mix.queuedMs} | ForEach-Object {[double]$_.protected.mix.queuedMs})
 roleLocalOutboxIncluded=$report.roleLocalOutboxIncluded -eq $true
 localEnqueueAckMs=Get-Distribution @($valid | Where-Object {$null -ne $_.protected.mix.localEnqueueAckMs} | ForEach-Object {[double]$_.protected.mix.localEnqueueAckMs})
 reservationRoundStartOffsetMs=Get-Distribution @($valid | Where-Object {$null -ne $_.protected.mix.reservationRoundStartOffsetMs} | ForEach-Object {[double]$_.protected.mix.reservationRoundStartOffsetMs})
 roundWorkMs=Get-Distribution @($valid | ForEach-Object {[double]$_.protected.mix.roundWorkMs})
 coldSetup=$report.mixConfiguration.anonymousSetup
 elapsedMsIncludingSetup=$report.elapsedMsIncludingSetup
 summaryPercentilesAgree=$true
 physicalRouteEvidence=$false
 securityGatePassed=$false
 productionIntegrationAllowed=$false
 caveats=@(
  'Same-clock local characterization; application-level pacing is not a mobile or domestic-network measurement.',
  'Signed bytes ready to verified/flushed store visibility; excludes composition/signing and UI. Role-local enqueue is included only when roleLocalOutboxIncluded is true.',
  'Local enqueue timing includes private-pipe acknowledgement, not just database commit. Reservation-round start can precede enqueue if the client prepared later within that round.',
  'Cold setup is separate. Sequential samples on one host are not independent evidence for a universal five-second bound.',
  'The controller knows laboratory publishers. This report does not establish anonymity, per-phone CPU, battery or daily traffic.'
 )
 failures=$failures
}
if ($report.summary) {
 foreach ($key in @('p50','p95','p99','max')) {
  if ([Math]::Abs([double]$report.summary.additionalUpperMs.$key-[double]$output.additionalConservativeUpperMs[$key]) -gt .00001) {
   throw "Raw observations disagree with summary percentile $key"
  }
 }
} else { $output.summaryPercentilesAgree=$false }
$output | ConvertTo-Json -Depth 12
