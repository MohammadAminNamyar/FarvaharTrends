$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $projectRoot 'artifacts\local-test\firewall-update-result.json'
try {
    & (Join-Path $PSScriptRoot 'local-peer-firewall.ps1') -Action Update -HostIPv4 '192.168.0.43'
    @{ status='updated'; time=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
} catch {
    @{ status='failed'; reason=$_.Exception.Message; time=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    exit 1
}
