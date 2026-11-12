# tools/build/build_windows_keyboard_layout.ps1
<#
==============================================================================
MODULE: Windows Keyboard Layout DLL Builder
DESCRIPTION:
Compiles the Ergopti keyboard layout DLL from the generated sources
(static/ergopti_plus/windows/native/keyboard_layout/_generated, written by
tools/codegen/codegen-windows-keyboard-layout.cjs) for every architecture
_shared/layouts/data/windows_system_layout.json names, into
static/ergopti_plus/windows/vendor/keyboard_layout/<build>/, where the driver's
installer and the release package take them. No MSKLC: kbd.h comes from the
Windows SDK and MSVC compiles and links.

FEATURES & RATIONALE:
1. One build per directory the installer copies from: amd64, arm64 and x86 go
	to System32 of their own Windows, wow64 (an x86 build with 64-bit table
	pointers, BUILD_WOW6432) to SysWOW64 of a 64-bit Windows.
2. A keyboard DLL has no entry point and no C runtime: /NOENTRY /NODEFAULTLIB,
	no security cookie (/GS-) and the data sections merged (winkbdlayouts'
	settings), so win32k can map it.
3. Fail fast: a missing toolchain, compiler warning, missing export or wrong
	machine type stops the build; nothing is written for a partial build.
4. The DLLs are build outputs, never tracked: each build writes a receipt with
	the SHA-256 of every DLL and of the sources it was built from.
5. -PackagePath zips the same DLLs with the driver's installer scripts into the
	stand-alone release package, so the two ways to install cannot differ.
==============================================================================
#>

[CmdletBinding()]
param(
	[string]$OutputDirectory,
	# Also writes the release package: the DLL builds, the installer scripts,
	# the spec and tools/build/windows_keyboard_layout_package/install.cmd.
	[string]$PackagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# A non-PowerShell launcher can inherit another host's module search path.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$SpecPath = Join-Path $RepoRoot "static\ergopti_plus\_shared\layouts\data\windows_system_layout.json"
$SourceDirectory = Join-Path $RepoRoot "static\ergopti_plus\windows\native\keyboard_layout\_generated"
if (-not $OutputDirectory) {
	$OutputDirectory = Join-Path $RepoRoot "static\ergopti_plus\windows\vendor\keyboard_layout"
}

# vcvarsall.bat argument, cl defines, link machine and the PE machine dumpbin
# reports, per build directory.
$Builds = [ordered]@{
	amd64 = @{ VcVars = "x64"; Defines = @(); Machine = "X64"; Pe = "8664 machine (x64)" }
	arm64 = @{ VcVars = "x64_arm64"; Defines = @(); Machine = "ARM64"; Pe = "AA64 machine (ARM64)" }
	x86 = @{ VcVars = "x64_x86"; Defines = @(); Machine = "X86"; Pe = "14C machine (x86)" }
	wow64 = @{ VcVars = "x64_x86"; Defines = @("/DBUILD_WOW6432", "/D_WOW6432_"); Machine = "X86"; Pe = "14C machine (x86)" }
}





# ======================================
# ======================================
# ======= 1/ Toolchain Discovery =======
# ======================================
# ======================================

<#
.SYNOPSIS
Returns the vcvarsall.bat of the newest Visual Studio with the x64, x86 and
ARM64 C++ build tools.
#>
function Get-VcVarsAll {
	$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
	if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
		throw "vswhere.exe was not found: install Visual Studio with the C++ build tools."
	}
	$installation = @(& $vswhere -latest -products * `
			-requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.Tools.ARM64 `
			-property installationPath) | Select-Object -First 1
	if ($LASTEXITCODE -ne 0 -or -not $installation) {
		throw "No Visual Studio installation has both the x64/x86 and the ARM64 C++ build tools."
	}
	$vcvars = Join-Path $installation "VC\Auxiliary\Build\vcvarsall.bat"
	if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw "vcvarsall.bat is missing: $vcvars" }
	return $vcvars
}

<#
.SYNOPSIS
Runs command lines inside one vcvarsall environment and throws on the first
failure, with its output.
#>
function Invoke-InMsvc {
	param(
		[Parameter(Mandatory = $true)][string]$VcVars,
		[Parameter(Mandatory = $true)][string]$Target,
		[Parameter(Mandatory = $true)][string[]]$Commands,
		[Parameter(Mandatory = $true)][string]$WorkDirectory
	)
	$script = Join-Path $WorkDirectory "build.cmd"
	$lines = @("@echo off", "call `"$VcVars`" $Target >nul || exit /b 90")
	foreach ($command in $Commands) { $lines += "$command || exit /b 91" }
	Set-Content -LiteralPath $script -Value $lines -Encoding ascii
	$output = & $env:ComSpec /d /c "`"$script`"" 2>&1
	$code = $LASTEXITCODE
	if ($code -ne 0) {
		throw "MSVC $Target build failed (exit $code):`n$($output -join "`n")"
	}
	return $output
}





# ===================================
# ===================================
# ======= 2/ Build and Checks =======
# ===================================
# ===================================

$spec = Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
$name = [string]$spec.dll_name
if ($name -notmatch '^[a-z][a-z0-9]{0,7}$') { throw "dll_name '$name' is not a keyboard DLL name." }
foreach ($extension in @("c", "h", "rc", "def")) {
	$file = Join-Path $SourceDirectory "$name.$extension"
	if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
		throw "Generated source $file is missing: run npm run codegen:windows-keyboard-layout."
	}
}
$wanted = @()
foreach ($architecture in $spec.architectures.PSObject.Properties) {
	foreach ($placement in $architecture.Value.PSObject.Properties) { $wanted += [string]$placement.Value }
}
$wanted = @($wanted | Sort-Object -Unique)
foreach ($build in $wanted) {
	if (-not $Builds.Contains($build)) { throw "The spec names build '$build', which this builder does not know." }
}

$vcvars = Get-VcVarsAll
$staging = Join-Path ([IO.Path]::GetTempPath()) ("ergopti-kbd-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
	$receipt = [ordered]@{ dll_name = $name; sources = [ordered]@{}; builds = [ordered]@{} }
	foreach ($extension in @("c", "h", "rc", "def")) {
		$receipt.sources["$name.$extension"] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $SourceDirectory "$name.$extension")).Hash.ToLowerInvariant()
	}
	foreach ($build in $wanted) {
		$settings = $Builds[$build]
		$work = Join-Path $staging $build
		New-Item -ItemType Directory -Path $work | Out-Null
		$dll = Join-Path $work "$name.dll"
		$defines = ($settings.Defines + @("/DUNICODE", "/D_UNICODE")) -join " "
		$commands = @(
			"cl /nologo /c /W3 /WX /O1 /GS- /Gy- /Zl /Brepro $defines /I`"$SourceDirectory`" /Fo`"$work\$name.obj`" `"$SourceDirectory\$name.c`"",
			"rc /nologo /fo `"$work\$name.res`" `"$SourceDirectory\$name.rc`"",
			"link /nologo /DLL /NOENTRY /NODEFAULTLIB /RELEASE /Brepro /OPT:REF /OPT:ICF /MERGE:.rdata=.data /MERGE:.bss=.data /IGNORE:4254 /MACHINE:$($settings.Machine) /DEF:`"$SourceDirectory\$name.def`" /OUT:`"$dll`" `"$work\$name.obj`" `"$work\$name.res`"",
			"dumpbin /nologo /exports /headers `"$dll`" > `"$work\dumpbin.txt`""
		)
		Invoke-InMsvc -VcVars $vcvars -Target $settings.VcVars -Commands $commands -WorkDirectory $work | Out-Null
		$report = Get-Content -Raw -LiteralPath (Join-Path $work "dumpbin.txt")
		if ($report -notmatch '\bKbdLayerDescriptor\b') { throw "$build/$name.dll does not export KbdLayerDescriptor." }
		if (-not $report.Contains($settings.Pe)) { throw "$build/$name.dll is not a $($settings.Pe) image." }
		$receipt.builds[$build] = (Get-FileHash -Algorithm SHA256 -LiteralPath $dll).Hash.ToLowerInvariant()
		Write-Host "[keyboard-layout] Built $build/$name.dll ($($settings.Machine))."
	}

	# Publish only once every build passed.
	New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
	foreach ($build in $wanted) {
		$target = Join-Path $OutputDirectory $build
		New-Item -ItemType Directory -Force -Path $target | Out-Null
		Copy-Item -LiteralPath (Join-Path $staging "$build\$name.dll") -Destination (Join-Path $target "$name.dll") -Force
	}
	$receiptPath = Join-Path $OutputDirectory "build_receipt.json"
	$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding utf8
	Write-Host "[keyboard-layout] Wrote $($wanted.Count) DLL builds and $receiptPath."

	if ($PackagePath) {
		$package = Join-Path $staging "package"
		New-Item -ItemType Directory -Path $package | Out-Null
		foreach ($build in $wanted) {
			New-Item -ItemType Directory -Path (Join-Path $package $build) | Out-Null
			Copy-Item -LiteralPath (Join-Path $OutputDirectory "$build\$name.dll") -Destination (Join-Path $package $build)
		}
		foreach ($script in @("install_keyboard_layout.ps1", "add_user_keyboard_layout.ps1")) {
			Copy-Item -LiteralPath (Join-Path $RepoRoot "static\ergopti_plus\windows\vendor\keyboard_layout\$script") -Destination $package
		}
		foreach ($file in @("install.cmd", "install_package.ps1")) {
			Copy-Item -LiteralPath (Join-Path $PSScriptRoot "windows_keyboard_layout_package\$file") -Destination $package
		}
		Copy-Item -LiteralPath $SpecPath -Destination $package
		Copy-Item -LiteralPath $receiptPath -Destination $package
		New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PackagePath) | Out-Null
		Compress-Archive -Path (Join-Path $package "*") -DestinationPath $PackagePath -Force
		Write-Host "[keyboard-layout] Wrote the release package $PackagePath."
	}
} finally {
	Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
