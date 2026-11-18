# tools/build/build_windows_lua_export.ps1
# Build the Windows driver's Lua export host; the executable and its source identity travel together.
# The pinned Lua archive (ergopti_lua_export.pin.json) is downloaded unless -SourceArchive names it;
# -Publish copies the qualified executable, its identity and licence into windows/vendor.
[CmdletBinding()]
param([string]$SourceArchive = '', [switch]$Publish)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$BuildRoot = Join-Path $RepoRoot 'static\ergopti_plus\windows\build\native\lua_export'
$NativeSource = Join-Path $RepoRoot 'static\ergopti_plus\windows\native'
$SharedRoot = Join-Path $RepoRoot 'static\ergopti_plus\_shared'
$NativeBuilder = Join-Path $PSScriptRoot 'build_windows_nav_owner.ps1'
if (Test-Path -LiteralPath $BuildRoot) { Remove-Item -LiteralPath $BuildRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

# Import only the original compiler-environment function, as the PAC build does:
# executing the whole builder would rebuild an artifact with its own provenance.
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
. ([ScriptBlock]::Create($Definitions[0].Extent.Text))
Import-MsvcEnvironment

function Invoke-LuaExportBuildCommand {
	param([string]$Executable, [string[]]$Arguments)
	& $Executable @Arguments
	if ($LASTEXITCODE -ne 0) { throw ('Lua export host build step failed: ' + $Executable) }
}

function Get-TextSha256 {
	param([string]$Text)
	$Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
	return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
}

$Pin = Get-Content -LiteralPath (Join-Path $NativeSource 'ergopti_lua_export.pin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (($Pin.schema_version -isnot [int] -and $Pin.schema_version -isnot [long]) -or $Pin.schema_version -ne 1 -or $Pin.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
	$Pin.url -cnotmatch '^https://www\.lua\.org/ftp/lua-5\.4\.[0-9]+\.tar\.gz$' -or $Pin.archive_root -cnotmatch '^lua-5\.4\.[0-9]+$') {
	throw 'Canonical pinned Lua source refused.'
}
if ($SourceArchive -eq '') {
	$CacheRoot = Join-Path ([IO.Path]::GetTempPath()) ('ergopti-lua-export-' + $Pin.sha256)
	New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
	$SourceArchive = Join-Path $CacheRoot 'lua.tar.gz'
	if (-not (Test-Path -LiteralPath $SourceArchive -PathType Leaf)) {
		$PrivateDownload = Join-Path $CacheRoot ([Guid]::NewGuid().ToString('N') + '.download')
		try {
			# A transient failure is retried; the digest below still admits only the pinned archive.
			for ($Attempt = 1; ; $Attempt++) {
				try {
					Invoke-WebRequest -Uri $Pin.url -OutFile $PrivateDownload -UseBasicParsing
					break
				} catch {
					if ($Attempt -ge 6) { throw }
					Write-Warning ("Lua source download failed (attempt {0} of 6): {1}" -f $Attempt, $_.Exception.Message)
					Start-Sleep -Seconds (10 * $Attempt)
				}
			}
			if ((Get-FileHash -LiteralPath $PrivateDownload -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pin.sha256) {
				throw 'Downloaded Lua source identity refused.'
			}
			[IO.File]::Move($PrivateDownload, $SourceArchive)
		} finally {
			if (Test-Path -LiteralPath $PrivateDownload -PathType Leaf) { Remove-Item -LiteralPath $PrivateDownload }
		}
	}
}
if ((Get-Item -LiteralPath $SourceArchive).Attributes -band [IO.FileAttributes]::ReparsePoint) {
	throw 'Lua source archive reparse point refused.'
}
if ((Get-FileHash -LiteralPath $SourceArchive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Pin.sha256) {
	throw 'Lua source archive identity refused.'
}
Invoke-LuaExportBuildCommand 'tar.exe' @('-xzf', $SourceArchive, '-C', $BuildRoot)
$LuaSource = Join-Path (Join-Path $BuildRoot $Pin.archive_root) 'src'

# The committed licence must be the archive's own notice (the end of src/lua.h).
$License = Join-Path $RepoRoot $Pin.license_file
$LicenseLines = @((Get-Content -LiteralPath $License -Raw -Encoding UTF8).TrimEnd() -split "`n")
$Notice = @($LicenseLines[([Array]::IndexOf($LicenseLines, '') + 1)..($LicenseLines.Count - 1)])
$Header = @((Get-Content -LiteralPath (Join-Path $LuaSource 'lua.h') -Raw -Encoding UTF8) -split "`n" |
	ForEach-Object { ($_ -replace '^\* ?', '').TrimEnd() })
$At = [Array]::IndexOf($Header, $Notice[0])
if ($At -lt 0) { throw 'The archive lua.h carries no licence notice.' }
foreach ($Line in $Notice) {
	if ($At -ge $Header.Count -or $Header[$At] -cne $Line) { throw 'The committed Lua licence differs from the archive notice.' }
	$At++
}

# source_fingerprint: SHA-256 of '<archive sha256>\n<host source sha256>\n' (the pin's rule).
$HostSource = Join-Path $NativeSource 'ergopti_lua_export.c'
$HostSha = (Get-FileHash -LiteralPath $HostSource -Algorithm SHA256).Hash.ToLowerInvariant()
$Fingerprint = Get-TextSha256 ($Pin.sha256 + "`n" + $HostSha + "`n")

# /Tc names each C source: /TC would also read the .obj inputs of a link step as C.
$Common = @('/nologo', '/Brepro', '/std:c11', '/O2', '/MT', '/guard:cf', '/D_CRT_SECURE_NO_WARNINGS', ('/I' + $LuaSource))
$Strict = @('/W4', '/WX', '/wd5105', ('/DERGOPTI_LUA_EXPORT_FINGERPRINT=' + $Fingerprint))
$Link = @('/link', '/Brepro', '/MACHINE:X64', '/DYNAMICBASE', '/HIGHENTROPYVA', '/NXCOMPAT', '/guard:cf')
$Objects = @()
Push-Location -LiteralPath $BuildRoot
try {
	# Only the pinned Lua files: a library left out (io, os, debug, package, coroutine) cannot be reached.
	foreach ($File in $Pin.sources) {
		if ($File -cnotmatch '^l[a-z0-9]+\.c$') { throw ('Pinned Lua source name refused: ' + $File) }
		$Object = [IO.Path]::ChangeExtension($File, '.obj')
		Invoke-LuaExportBuildCommand 'cl.exe' ($Common + @('/W0', '/c', ('/Tc' + (Join-Path $LuaSource $File)), ('/Fo' + $Object)))
		$Objects += $Object
	}
	Invoke-LuaExportBuildCommand 'cl.exe' ($Common + $Strict + @(('/I' + $NativeSource), ('/Tc' + (Join-Path $NativeSource 'ergopti_lua_export_test.c'))) + $Objects + @('/Feergopti_lua_export_test.exe') + $Link)
	$Scratch = Join-Path $BuildRoot 'scratch'
	New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
	Invoke-LuaExportBuildCommand (Join-Path $BuildRoot 'ergopti_lua_export_test.exe') @($SharedRoot, $Scratch)
	Invoke-LuaExportBuildCommand 'cl.exe' ($Common + $Strict + @(('/Tc' + $HostSource)) + $Objects + @('/Feergopti_lua_export.exe') + $Link)
} finally { Pop-Location }

$Executable = Join-Path $BuildRoot 'ergopti_lua_export.exe'
$Identity = (& $Executable --identity) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or ($Identity.schema_version -isnot [int] -and $Identity.schema_version -isnot [long]) -or $Identity.schema_version -ne 1 -or
	$Identity.host -cne 'ergopti_lua_export' -or
	$Identity.lua_release -cne $Pin.lua_release -or $Identity.source_fingerprint -cne $Fingerprint) {
	throw 'Actual compiled Lua export host identity refused.'
}
# Inspect the actual built PE and its static-runtime dependency closure before publishing.
$Bytes = [IO.File]::ReadAllBytes($Executable)
if ($Bytes.Length -lt 64 -or [BitConverter]::ToUInt16($Bytes, 0) -ne 0x5a4d) { throw 'Lua export host DOS header refused.' }
$Pe = [BitConverter]::ToInt32($Bytes, 0x3c)
if ($Pe -lt 64 -or [long]$Pe + 96 -gt $Bytes.LongLength -or [BitConverter]::ToUInt32($Bytes, $Pe) -ne 0x4550 -or
	[BitConverter]::ToUInt16($Bytes, $Pe + 4) -ne 0x8664 -or [BitConverter]::ToUInt16($Bytes, $Pe + 24) -ne 0x20b) {
	throw 'Lua export host x64 PE32+ identity refused.'
}
$Characteristics = [BitConverter]::ToUInt16($Bytes, $Pe + 22)
$Mitigations = [BitConverter]::ToUInt16($Bytes, $Pe + 94)
if (($Characteristics -band 0x2002) -ne 2 -or ($Mitigations -band 0x4160) -ne 0x4160) {
	throw 'Lua export host executable, ASLR, high-entropy ASLR, DEP or CFG contract refused.'
}
$Dependencies = @(& dumpbin.exe /nologo /dependents $Executable)
if ($LASTEXITCODE -ne 0) { throw 'Lua export host dependency inspector failed.' }
$Imports = @($Dependencies | ForEach-Object { if ($_ -match '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { $Matches[1].ToLowerInvariant() } })
if ($Imports.Count -ne 1 -or $Imports[0] -cne 'kernel32.dll') {
	throw 'Lua export host static-runtime system dependency closure refused.'
}
$Artifact = [ordered]@{ schema_version = 1; lua_release = $Pin.lua_release; lua_archive_sha256 = $Pin.sha256;
	source_fingerprint = $Fingerprint; imports = @($Imports); pe_mitigations = $Mitigations;
	license_sha256 = (Get-FileHash -LiteralPath $License -Algorithm SHA256).Hash.ToLowerInvariant();
	exe_sha256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant() }
$ArtifactPath = Join-Path $BuildRoot 'ergopti_lua_export.json'
[IO.File]::WriteAllText($ArtifactPath, ($Artifact | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
if ($Publish) {
	$Vendor = Join-Path $RepoRoot 'static\ergopti_plus\windows\vendor'
	Copy-Item -LiteralPath $Executable -Destination (Join-Path $Vendor 'ergopti_lua_export.exe')
	Copy-Item -LiteralPath $ArtifactPath -Destination (Join-Path $Vendor 'ergopti_lua_export.json')
}
Write-Host ('Lua export host qualified: ' + $Pin.lua_release + ', fingerprint ' + $Fingerprint)
