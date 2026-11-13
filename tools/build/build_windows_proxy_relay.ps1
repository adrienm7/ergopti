# tools/build/build_windows_proxy_relay.ps1
# Builds ergopti-proxy-relay.exe (docs/design/proxy-auth-relay.md) reproducibly
# from the repository's Go sources; binary and source identity travel together.
#
# The Windows sign-in is SSPI through secur32.dll, standard library only, so the
# build needs no cgo and no network: GOTOOLCHAIN=local never downloads a toolchain
# and GOPROXY=off never fetches a module. Only the repository's one Go pin
# (managed_ollama_runtime.json go_version) builds it, because another compiler
# gives other bytes. The same bytes come out on any host of that pin.
#
# -Publish copies the binary and its manifest into windows/vendor. -Verify rebuilds
# and refuses a difference from the published pair. -Go names the toolchain;
# otherwise %LOCALAPPDATA%\Programs\go-<pin>\bin\go.exe, then PATH.
[CmdletBinding()]
param([switch]$Publish, [switch]$Verify, [string]$Go = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RelaySha256([string]$Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if ($Publish -and $Verify) { throw 'Choose -Publish or -Verify.' }
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Module = Join-Path $RepoRoot 'static/ergopti_plus/_shared/core/network/native/go/native_http'
$Vendor = Join-Path $RepoRoot 'static/ergopti_plus/windows/vendor'
$BuildRoot = Join-Path $RepoRoot 'static/ergopti_plus/windows/build/native/proxy_relay'
$Runtime = Get-Content -LiteralPath (Join-Path $RepoRoot 'static/ergopti_plus/_shared/ai/data/managed_ollama_runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Pin = $Runtime.go_version
if ($Pin -cnotmatch '^go[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Canonical Go pin refused.' }

if ($Go -eq '') {
	$Local = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA ('Programs/go-' + $Pin.Substring(2) + '/bin/go.exe') } else { '' }
	$Go = if ($Local -ne '' -and (Test-Path -LiteralPath $Local -PathType Leaf)) { $Local } else { 'go' }
}
$env:GOTOOLCHAIN = 'local'; $env:GOPROXY = 'off'; $env:GOFLAGS = '-mod=readonly'; $env:GOWORK = 'off'
$env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'
$Version = & $Go env GOVERSION
if ($LASTEXITCODE -ne 0) { throw 'The Go toolchain could not run.' }
if ($Version -cne $Pin) { throw "The relay builds only with the pinned $Pin, not $Version." }

# Everything the binary is compiled from. Test files are excluded: they cannot
# change the bytes, and editing one must not demand a new binary.
$Sources = @(Join-Path $Module 'go.mod') + @(foreach ($Directory in @('proxyrelay', 'cmd/ergopti-proxy-relay')) {
	Get-ChildItem -LiteralPath (Join-Path $Module $Directory) -Filter '*.go' -File |
		Where-Object { $_.Name -cnotlike '*_test.go' } | ForEach-Object { $_.FullName }
})
$Identity = $Pin + "`n"
# Ordinal order on the relative path, as test-windows-proxy-relay-bundle.cjs recomputes it.
$Relatives = [string[]]@($Sources | ForEach-Object { [IO.Path]::GetFullPath($_).Substring([IO.Path]::GetFullPath($Module).Length + 1).Replace('\', '/') })
[Array]::Sort($Relatives, [StringComparer]::Ordinal)
foreach ($Relative in $Relatives) {
	$Identity += $Relative + "`n" + (Get-RelaySha256 (Join-Path $Module $Relative)) + "`n"
}
$Digest = [Security.Cryptography.SHA256]::Create()
try {
	$Fingerprint = ([BitConverter]::ToString($Digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($Identity)))).Replace('-', '').ToLowerInvariant()
} finally { $Digest.Dispose() }

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$Executable = Join-Path $BuildRoot 'ergopti-proxy-relay.exe'
Push-Location -LiteralPath $Module
try {
	& $Go build -trimpath -buildvcs=false '-ldflags=-s -w -buildid=' -o $Executable ./cmd/ergopti-proxy-relay
	if ($LASTEXITCODE -ne 0) { throw 'The relay build failed.' }
} finally { Pop-Location }

# Inspect the actual PE before it can be published: x64 console, ASLR and DEP.
$Bytes = [IO.File]::ReadAllBytes($Executable)
$Pe = [BitConverter]::ToInt32($Bytes, 0x3c)
if ([BitConverter]::ToUInt16($Bytes, 0) -ne 0x5a4d -or [BitConverter]::ToUInt32($Bytes, $Pe) -ne 0x4550 -or
	[BitConverter]::ToUInt16($Bytes, $Pe + 4) -ne 0x8664) { throw 'Relay x64 PE identity refused.' }
if (([BitConverter]::ToUInt16($Bytes, $Pe + 94) -band 0x0160) -ne 0x0160) { throw 'Relay ASLR, high-entropy ASLR or DEP contract refused.' }

# No arguments is the named invalid_arguments refusal with exit 2: it proves the
# binary starts. Only a Windows host can run it.
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
	$Smoke = [Diagnostics.ProcessStartInfo]::new($Executable)
	$Smoke.UseShellExecute = $false; $Smoke.RedirectStandardError = $true; $Smoke.CreateNoWindow = $true
	$Running = [Diagnostics.Process]::Start($Smoke)
	try {
		$Refusal = $Running.StandardError.ReadToEnd()
		$Running.WaitForExit()
		if ($Running.ExitCode -ne 2 -or $Refusal -cnotmatch 'relay_refused invalid_arguments') {
			throw 'The built relay did not answer its smoke run.'
		}
	} finally { $Running.Dispose() }
}

$Manifest = ([ordered]@{ schema_version = 1; go_version = $Pin; goos = 'windows'; goarch = 'amd64';
	source_fingerprint = $Fingerprint; exe_sha256 = (Get-RelaySha256 $Executable) } | ConvertTo-Json -Compress) + "`n"
$PublishedExecutable = Join-Path $Vendor 'ergopti-proxy-relay.exe'
$PublishedManifest = Join-Path $Vendor 'ergopti-proxy-relay.json'
if ($Verify) {
	if ([IO.File]::ReadAllText($PublishedManifest) -cne $Manifest) { throw 'The published relay manifest differs from this build.' }
	if ((Get-RelaySha256 $PublishedExecutable) -cne (Get-RelaySha256 $Executable)) { throw 'The published relay differs from this build.' }
	Write-Host "Published relay reproduced by $Pin."
} elseif ($Publish) {
	Copy-Item -LiteralPath $Executable -Destination $PublishedExecutable -Force
	[IO.File]::WriteAllText($PublishedManifest, $Manifest, [Text.UTF8Encoding]::new($false))
	Write-Host "Relay published: $(Get-RelaySha256 $PublishedExecutable)."
} else {
	Write-Host "Relay built: $Executable."
}
