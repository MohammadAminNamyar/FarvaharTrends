$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$lockPath = Join-Path $projectRoot 'pubspec.lock'
$lockText = [IO.File]::ReadAllText($lockPath)
$packages = @()
foreach ($entry in [regex]::Matches($lockText, '(?ms)^  (?<name>[a-zA-Z0-9_]+):\r?\n(?<block>.*?)(?=^  [a-zA-Z0-9_]+:|\z)')) {
    $block = $entry.Groups['block'].Value
    if ($block -notmatch '(?m)^    source: hosted\s*$') { continue }
    $version = [regex]::Match($block, '(?m)^    version: "(?<version>[^"]+)"')
    if (-not $version.Success) { throw 'Unsupported dependency lock format.' }
    $packages += @{ name = $entry.Groups['name'].Value; version = $version.Groups['version'].Value }
}
if ($packages.Count -eq 0) { throw 'No hosted packages were parsed; audit was not performed.' }
$queries = @($packages | ForEach-Object { @{ package = @{name=$_.name; ecosystem='Pub'}; version=$_.version } })
$response = Invoke-RestMethod -Uri 'https://api.osv.dev/v1/querybatch' -Method Post -ContentType 'application/json' -Body (@{ queries=$queries } | ConvertTo-Json -Depth 6) -TimeoutSec 45
if ($response.results.Count -ne $packages.Count) { throw 'Incomplete advisory response.' }
$results = for ($i = 0; $i -lt $packages.Count; $i++) {
    @{ package=$packages[$i].name; version=$packages[$i].version; advisories=@($response.results[$i].vulns | Where-Object { $_ } | ForEach-Object { $_.id }) }
}
$report = @{
    checkedAtUtc=[DateTime]::UtcNow.ToString('o'); source='https://api.osv.dev/v1/querybatch'
    lockSha256=(Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    scope='Hosted Pub lockfile packages; excludes Flutter/Dart SDK, native artifacts and local forks. No returned advisory does not establish absence of vulnerabilities.'
    packages=@($results)
}
$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $projectRoot 'artifacts/dependency-advisories.json') -Encoding utf8
[pscustomobject]@{ packages=$packages.Count; matchedAdvisories=@($results | Where-Object { $_.advisories.Count -gt 0 }).Count }
