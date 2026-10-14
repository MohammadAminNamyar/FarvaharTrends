param(
    [ValidateSet('Show','Install','Update','Remove')][string]$Action = 'Show',
    [string]$HostIPv4 = '192.168.0.43'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
# This SDK launches dartvm.exe as the process that owns the listening sockets.
$program = Join-Path $projectRoot '.tooling\flutter\bin\cache\dart-sdk\bin\dartvm.exe'
$address = $null
if (![System.Net.IPAddress]::TryParse($HostIPv4, [ref]$address) -or
    $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
    $HostIPv4 -notmatch '^192\.168\.0\.(?:[1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$') {
    throw 'This local-test script is limited to a PC IPv4 in 192.168.0.0/24.'
}
if (!(Test-Path -LiteralPath $program -PathType Leaf)) { throw 'Project-local Dart executable was not found.' }
$group = 'FarvaharTrends local test peer'
$rules = @(
    @{ Name = 'FarvaharTrends.LocalTest.TCP.45871'; DisplayName = 'FarvaharTrends local test TCP45871'; Protocol = 'TCP'; LocalPort = 45871 },
    @{ Name = 'FarvaharTrends.LocalTest.UDP.45872'; DisplayName = 'FarvaharTrends local test UDP45872'; Protocol = 'UDP'; LocalPort = 45872 }
)
if ($Action -eq 'Show') {
    $rules | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name; Program = $program; Direction = 'Inbound'; Action = 'Allow'
            Protocol = $_.Protocol; LocalPort = $_.LocalPort; LocalAddress = $HostIPv4
            RemoteAddress = '192.168.0.0/24'; Profile = 'Any'; EdgeTraversal = 'Block'
        }
    } | Format-List
    Write-Output 'No firewall changes made. Install, Update or Remove requires an administrator PowerShell.'
    return
}
$principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (!$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Windows requires administrator permission to change firewall rules. This script does not elevate itself.'
}
if ($Action -eq 'Remove') {
    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if ($null -eq $existing) { continue }
        if ($existing.Group -ne $group) { throw 'An existing rule belongs to another group; it was not changed.' }
        Remove-NetFirewallRule -Name $rule.Name
    }
    Write-Output 'Removed only the two named FarvaharTrends local test rules, if present.'
    return
}
if ($Action -eq 'Update') {
    # Validate both named rules before modifying either. No rule outside this
    # group/name pair is authority to broaden or replace an application rule.
    foreach ($rule in $rules) {
        $existing = @(Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue)
        if ($existing.Count -ne 1 -or $existing[0].Group -ne $group) {
            throw 'Both existing test rules must belong to the FarvaharTrends local test peer group. No rules were updated.'
        }
    }
    foreach ($rule in $rules) {
        Set-NetFirewallRule -Name $rule.Name -Program $program -Direction Inbound -Action Allow `
            -Protocol $rule.Protocol -LocalPort $rule.LocalPort -LocalAddress $HostIPv4 `
            -RemoteAddress '192.168.0.0/24' -Profile Any -Enabled True -EdgeTraversalPolicy Block | Out-Null
    }
    Write-Output 'Updated only the two named local test rules for project dartvm.exe with the same narrow port/address/subnet scopes.'
    return
}
foreach ($rule in $rules) {
    if ($null -ne (Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue)) {
        throw "Rule $($rule.Name) already exists. Review or remove the named test rules before installing again."
    }
}
$created = @()
try {
    foreach ($rule in $rules) {
        New-NetFirewallRule @rule -Group $group -Program $program -Direction Inbound -Action Allow `
            -LocalAddress $HostIPv4 -RemoteAddress '192.168.0.0/24' -Profile Any -Enabled True -EdgeTraversalPolicy Block | Out-Null
        $created += $rule.Name
    }
} catch {
    foreach ($name in $created) { Remove-NetFirewallRule -Name $name }
    throw
}
Write-Output 'Installed two inbound rules limited to this project Dart program, PC address, ports and local /24 subnet.'
