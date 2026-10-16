# Research dependency preparation only; does not modify app dependencies.
$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$lab = Join-Path $project '.tooling/privacy-research'
$go = Join-Path $lab 'go/bin/go.exe'
if (-not (Test-Path -LiteralPath $go)) { throw 'Install a checksum-verified portable Go SDK under .tooling/privacy-research/go first.' }
$env:GOPATH = Join-Path $lab 'gopath'
$env:GOCACHE = Join-Path $lab 'gocache'
$env:CGO_ENABLED = '0'
$upstream = Join-Path $lab 'katzenpost'
if (-not (Test-Path -LiteralPath $upstream)) {
    & git clone --depth 1 --branch v0.0.90 https://github.com/katzenpost/katzenpost.git $upstream
    if ($LASTEXITCODE) { throw 'Dependency checkout failed' }
}
if ((& git -C $upstream rev-parse HEAD) -ne 'd5a6349a34c4a2d4bca587f4be86ce92f2873b12') { throw 'Unexpected Katzenpost revision' }
Push-Location $upstream
try {
    & $go mod download github.com/katzenpost/hpqc
    if ($LASTEXITCODE) { throw 'Dependency download failed' }
} finally { Pop-Location }
$version = 'hpqc@v0.0.84-0.20260603082753-be60338910ec'
$source = Join-Path $env:GOPATH ('pkg/mod/github.com/katzenpost/' + $version)
$portable = Join-Path $lab 'hpqc-portable'
if (-not (Test-Path -LiteralPath $portable)) {
    Copy-Item -LiteralPath $source -Destination $portable -Recurse
}
# Only registration is narrowed; the Sphinx and selected cryptographic
# implementations remain upstream code. This is NOT an unmodified stock build.
# The upstream registry unconditionally imports C-only CTIDH schemes, even
# when the experiment selects X25519. Keep only portable schemes being measured.
$nike = @'
package schemes
import (
 "strings"
 "github.com/katzenpost/hpqc/nike"
 "github.com/katzenpost/hpqc/nike/x25519"
 "github.com/katzenpost/hpqc/rand"
)
var selected = []nike.Scheme{x25519.Scheme(rand.Reader)}
func ByName(name string) nike.Scheme { for _, s := range selected { if strings.EqualFold(s.Name(), name) { return s } }; return nil }
func All() []nike.Scheme { return append([]nike.Scheme{}, selected...) }
'@
$kem = @'
package schemes
import (
 "strings"
 "github.com/katzenpost/hpqc/kem"
 "github.com/katzenpost/hpqc/kem/adapter"
 "github.com/katzenpost/hpqc/kem/xwing"
 "github.com/katzenpost/hpqc/nike/x25519"
 "github.com/katzenpost/hpqc/rand"
)
var selected = []kem.Scheme{adapter.FromNIKE(x25519.Scheme(rand.Reader)), xwing.Scheme()}
func ByName(name string) kem.Scheme { for _, s := range selected { if strings.EqualFold(s.Name(), name) { return s } }; return nil }
func All() []kem.Scheme { return append([]kem.Scheme{}, selected...) }
'@
foreach ($item in @(@('nike', $nike), @('kem', $kem))) {
    $target = Join-Path $portable ($item[0] + '/schemes/schemes.go')
    (Get-Item -LiteralPath $target).IsReadOnly = $false
    Set-Content -LiteralPath $target -Value $item[1] -Encoding utf8NoBOM
}
Write-Output 'Prepared pinned Sphinx research dependency; only NIKE/KEM scheme registries restricted.'
