# tools/build/build_windows_network_pac.ps1
# Build one bounded PAC worker; compiled input and its source identity travel together.
[CmdletBinding()]
param([string]$SourceArchive = '', [switch]$Publish)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$BuildRoot = Join-Path $RepoRoot 'static\ergopti_plus\windows\build\native\network_pac'
$Prepared = Join-Path $BuildRoot 'prepared'
$NativeSource = Join-Path $RepoRoot 'static\ergopti_plus\windows\native'
$SharedSource = Join-Path $RepoRoot 'static\ergopti_plus\_shared\native\network'
$HelperSource = Join-Path $RepoRoot 'static\ergopti_plus\_shared\modules\network\pac_helpers.js'
$NativeBuilder = Join-Path $PSScriptRoot 'build_windows_nav_owner.ps1'
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

# Import only the original function definition: executing the whole builder
# would mutate a separate artifact whose existing provenance must remain intact.
$Tokens = $null; $Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($NativeBuilder, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count -ne 0) { throw 'Native compiler owner could not be parsed.' }
$Definitions = @($Ast.FindAll({ param($Node)
	$Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
	$Node.Name -ceq 'Import-MsvcEnvironment' -and -not $Node.IsFilter
}, $true))
if ($Definitions.Count -ne 1 -or $Definitions[0].Parent -isnot [Management.Automation.Language.NamedBlockAst]) {
	throw 'The original native compiler function owner is ambiguous.'
}
$FunctionBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Definitions[0].Extent.Text)
$FunctionPath = Join-Path $BuildRoot 'msvc_function.source.ps1'
[IO.File]::WriteAllBytes($FunctionPath, $FunctionBytes)
. ([ScriptBlock]::Create($Definitions[0].Extent.Text))
Import-MsvcEnvironment

function Invoke-PacBuildCommand {
	param([string]$Executable, [string[]]$Arguments)
	& $Executable @Arguments
	if ($LASTEXITCODE -ne 0) { throw 'Native PAC build or receiving failed.' }
}

$Catalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'static\ergopti_plus\_shared\data\linux_native_runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Pin = $Catalog.network_runtime.portable.flatpak_sources.duktape
if ($Pin.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $Pin.url -cnotmatch '^https://github\.com/svaarala/duktape/releases/download/') {
	throw 'Canonical pinned Duktape source refused.'
}
if ($SourceArchive -eq '') {
	$CacheRoot = Join-Path ([IO.Path]::GetTempPath()) ('ergopti-network-pac-' + $Pin.sha256)
	New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
	$SourceArchive = Join-Path $CacheRoot 'duktape.tar.xz'
	if (-not (Test-Path -LiteralPath $SourceArchive -PathType Leaf)) {
		$PrivateDownload = Join-Path $CacheRoot ([Guid]::NewGuid().ToString('N') + '.download')
		try {
			Invoke-WebRequest -Uri $Pin.url -OutFile $PrivateDownload -UseBasicParsing
			if ((Get-FileHash -LiteralPath $PrivateDownload -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pin.sha256) {
				throw 'Downloaded Duktape source identity refused.'
			}
			[IO.File]::Move($PrivateDownload, $SourceArchive)
		} finally {
			if (Test-Path -LiteralPath $PrivateDownload -PathType Leaf) { Remove-Item -LiteralPath $PrivateDownload }
		}
	}
}
if ((Get-Item -LiteralPath $SourceArchive).Attributes -band [IO.FileAttributes]::ReparsePoint) {
	throw 'Duktape source archive reparse point refused.'
}
if ((Get-FileHash -LiteralPath $SourceArchive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pin.sha256) {
	throw 'Duktape source archive identity refused.'
}
Invoke-PacBuildCommand 'python' @((Join-Path $PSScriptRoot 'prepare_network_pac_sources.py'), '--repo', $RepoRoot,
	'--archive', $SourceArchive, '--output', $Prepared, '--msvc-function', $FunctionPath)
$Receipt = Get-Content -LiteralPath (Join-Path $Prepared 'source_receipt.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Receipt.schema_version -ne 1 -or $Receipt.source_fingerprint -cnotmatch '^[0-9a-f]{64}$') {
	throw 'Generated PAC source receipt refused.'
}
$Common = @('/nologo', '/Brepro', '/std:c11', '/O2', '/MT', '/guard:cf', '/D_CRT_SECURE_NO_WARNINGS', '/D_WIN32_WINNT=0x0602', ('/I' + $Prepared), ('/I' + $SharedSource), ('/I' + $NativeSource))
$Strict = @('/W4', '/WX', '/wd5105')
$Link = @('/link', '/Brepro', '/MACHINE:X64', '/DYNAMICBASE', '/HIGHENTROPYVA', '/NXCOMPAT', '/guard:cf', 'ws2_32.lib', 'iphlpapi.lib')
Push-Location $BuildRoot
try {
	Invoke-PacBuildCommand 'cl.exe' ($Common + @('/W0', '/c', (Join-Path $Prepared 'duktape.c'), '/Foduktape.obj'))
	Invoke-PacBuildCommand 'cl.exe' ($Common + $Strict + @('/c', (Join-Path $SharedSource 'pac_runtime.c'), '/Fopac_runtime.obj'))
	Invoke-PacBuildCommand 'cl.exe' ($Common + $Strict + @((Join-Path $SharedSource 'test_pac_runtime.c'), 'pac_runtime.obj', 'duktape.obj', '/Fetest_pac_runtime.exe') + $Link)
	Invoke-PacBuildCommand (Join-Path $BuildRoot 'test_pac_runtime.exe') @($HelperSource)
	Invoke-PacBuildCommand 'cl.exe' ($Common + $Strict + @((Join-Path $NativeSource 'ergopti_network_pac_platform.c'), (Join-Path $NativeSource 'ergopti_network_pac_test_platform.c'), '/Fetest_native_platform.exe') + $Link)
	Invoke-PacBuildCommand (Join-Path $BuildRoot 'test_native_platform.exe') @()
	Invoke-PacBuildCommand 'cl.exe' ($Common + $Strict + @((Join-Path $NativeSource 'ergopti_network_pac_platform.c'), (Join-Path $NativeSource 'ergopti_network_pac.c'), 'pac_runtime.obj', 'duktape.obj', '/Feergopti_network_pac.exe') + $Link)
} finally { Pop-Location }
$Before = $Receipt.source_fingerprint
Invoke-PacBuildCommand 'python' @((Join-Path $PSScriptRoot 'prepare_network_pac_sources.py'), '--repo', $RepoRoot,
	'--archive', $SourceArchive, '--output', $Prepared, '--msvc-function', $FunctionPath)
$Receipt = Get-Content -LiteralPath (Join-Path $Prepared 'source_receipt.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Receipt.source_fingerprint -cne $Before) { throw 'PAC source identity changed during native compilation.' }
$Executable = Join-Path $BuildRoot 'ergopti_network_pac.exe'
$Identity = (& $Executable --identity) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $Identity.schema_version -ne 1 -or $Identity.duktape_version -ne 20700 -or
	$Identity.source_fingerprint -cne $Receipt.source_fingerprint) { throw 'Actual compiled PAC identity refused.' }
# Inspect the actual built PE and its static-runtime dependency closure before publishing.
$Bytes = [IO.File]::ReadAllBytes($Executable)
if ($Bytes.Length -lt 64 -or [BitConverter]::ToUInt16($Bytes, 0) -ne 0x5a4d) { throw 'Native PAC DOS header refused.' }
$Pe = [BitConverter]::ToInt32($Bytes, 0x3c)
if ($Pe -lt 64 -or [long]$Pe + 96 -gt $Bytes.LongLength -or [BitConverter]::ToUInt32($Bytes, $Pe) -ne 0x4550 -or
	[BitConverter]::ToUInt16($Bytes, $Pe + 4) -ne 0x8664 -or [BitConverter]::ToUInt16($Bytes, $Pe + 24) -ne 0x20b) {
	throw 'Native PAC x64 PE32+ identity refused.'
}
$Characteristics = [BitConverter]::ToUInt16($Bytes, $Pe + 22)
$Mitigations = [BitConverter]::ToUInt16($Bytes, $Pe + 94)
if (($Characteristics -band 0x2002) -ne 2 -or ($Mitigations -band 0x4160) -ne 0x4160) {
	throw 'Native PAC executable, ASLR, high-entropy ASLR, DEP or CFG contract refused.'
}
$Dependencies = @(& dumpbin.exe /nologo /dependents $Executable)
if ($LASTEXITCODE -ne 0) { throw 'Native PAC dependency inspector failed.' }
$Imports = @($Dependencies | ForEach-Object { if ($_ -match '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { $Matches[1].ToLowerInvariant() } })
if ($Imports.Count -ne 3 -or @($Imports | Sort-Object -Unique).Count -ne 3 -or
	@($Imports | Where-Object { $_ -cnotin @('kernel32.dll', 'ws2_32.dll', 'iphlpapi.dll') }).Count -ne 0) {
	throw 'Native PAC static-runtime system dependency closure refused.'
}
$Artifact = [ordered]@{ schema_version = 1; source_fingerprint = $Receipt.source_fingerprint;
	duktape_archive_sha256 = $Pin.sha256; imports = @($Imports | Sort-Object); pe_mitigations = $Mitigations; license_sha256 = (Get-FileHash -LiteralPath (Join-Path $Prepared 'LICENSE.txt') -Algorithm SHA256).Hash.ToLowerInvariant(); exe_sha256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant() }
$ArtifactPath = Join-Path $BuildRoot 'artifact_receipt.json'
[IO.File]::WriteAllText($ArtifactPath, ($Artifact | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
if ($Publish) {
	$Vendor = Join-Path $RepoRoot 'static\ergopti_plus\windows\vendor'
	Copy-Item -LiteralPath $Executable -Destination (Join-Path $Vendor 'ergopti_network_pac.exe')
	Copy-Item -LiteralPath $ArtifactPath -Destination (Join-Path $Vendor 'ergopti_network_pac.json')
	Copy-Item -LiteralPath (Join-Path $Prepared 'LICENSE.txt') -Destination (Join-Path $Vendor 'ergopti_network_pac.LICENSE.txt')
}
Write-Host 'Native PAC core and source identity qualified; full system routing receiving remains separate.'
