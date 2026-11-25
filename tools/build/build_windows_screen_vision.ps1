# tools/build/build_windows_screen_vision.ps1
<#
==============================================================================
MODULE: Windows Screen Vision Assembly Builder
DESCRIPTION:
Compiles the screen vision worker's C# (capture and matcher, under
static/ergopti_plus/windows/native) into vendor/ergopti_screen_vision.dll,
the assembly vendor/ergopti_screen_vision_worker.ps1 loads. The Windows CI
jobs run it before the AHK suites and before the static bundle; a source run
on Windows runs it once after a checkout or a change to the C# sources.

FEATURES & RATIONALE:
1. Build time, not run time: a worker that compiled C# on its first start
	put the PowerShell compiler stage in the exe bundle, which antivirus
	engines score (tools/ci/windows-exe-av-surface.json).
2. Same compiler as before: the .NET Framework 4 csc.exe every Windows has,
	the one Windows PowerShell 5.1 compiled these sources with, so the
	language level (C# 5) and the referenced framework stay what they were.
3. Explicit references: /noconfig and the framework assemblies by path, so the
	compiler's default response file cannot add a reference the worker does
	not load itself.
4. Fail fast: a missing compiler, a compile error or an absent output throws,
	and a stale assembly is removed before the compile so it cannot survive one.
==============================================================================
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$NativeDir = Join-Path $RepoRoot "static\ergopti_plus\windows\native"
$Output = Join-Path $RepoRoot "static\ergopti_plus\windows\vendor\ergopti_screen_vision.dll"
$Sources = @("ergopti_screen_vision_matcher.cs", "ergopti_screen_vision_capture.cs") |
	ForEach-Object { Join-Path $NativeDir $_ }

$FrameworkDir = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$Compiler = Join-Path $FrameworkDir "csc.exe"
if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) {
	throw "The .NET Framework 4 compiler is missing at $Compiler."
}
$References = @(
	(Join-Path $FrameworkDir "mscorlib.dll"),
	(Join-Path $FrameworkDir "System.dll"),
	(Join-Path $FrameworkDir "System.Drawing.dll"),
	(Join-Path $FrameworkDir "System.Xaml.dll"),
	(Join-Path $FrameworkDir "WPF\PresentationCore.dll"),
	(Join-Path $FrameworkDir "WPF\WindowsBase.dll")
)
foreach ($Path in @($Sources) + $References) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The screen vision build input is missing: $Path." }
}

if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
$Arguments = @("/nologo", "/noconfig", "/nostdlib+", "/target:library", "/optimize+", "/langversion:5",
	"/out:$Output") + ($References | ForEach-Object { "/reference:$_" }) + $Sources
Write-Host "[screen-vision] Compiling $($Sources.Count) source(s) with $Compiler."
& $Compiler @Arguments
if ($LASTEXITCODE -ne 0) { throw "The screen vision assembly failed to compile (exit $LASTEXITCODE)." }
if (-not (Test-Path -LiteralPath $Output -PathType Leaf)) { throw "The compiler wrote no $Output." }

# Resolve every type in a child Windows PowerShell, the worker's host, so a
# reference the framework cannot bind fails here instead of on a user's PC.
$Check = "`$ErrorActionPreference = 'Stop'; `$a = [Reflection.Assembly]::LoadFrom('$($Output -replace "'", "''")'); " +
	"`$null = `$a.GetTypes(); `$null = `$a.GetType('Ergopti.ScreenVision.Capture', `$true)"
& (Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe") -NoProfile -NonInteractive -Command $Check
if ($LASTEXITCODE -ne 0) { throw "The built $Output does not load (exit $LASTEXITCODE)." }
Write-Host "[screen-vision] Built and loaded $Output."
