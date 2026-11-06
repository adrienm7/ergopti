# tools/build/windows_keyboard_layout_package/install_package.ps1
<#
==============================================================================
MODULE: Ergopti Layout Package Installer (Windows)
DESCRIPTION:
The entry point of the Ergopti_windows_layout.zip release package (install.cmd
starts it). Runs the elevated installer through UAC, then adds the installed
layout to the current user's language list, the two steps the Ergopti Plus
tray menu runs from « Install the Ergopti system layout ».

FEATURES & RATIONALE:
1. The same scripts as the driver: install_keyboard_layout.ps1 (elevated) and
	add_user_keyboard_layout.ps1 (as the user), with windows_system_layout.json.
2. Fail fast: a refused elevation or a failed step exits 1 with its reason.
==============================================================================
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$spec = Join-Path $here "windows_system_layout.json"
$result = Join-Path ([IO.Path]::GetTempPath()) ("ergopti-layout-" + [Guid]::NewGuid().ToString("N") + ".json")
$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $here 'install_keyboard_layout.ps1')`" " +
	"-Action install -SpecPath `"$spec`" -SourceDirectory `"$here`" -ResultPath `"$result`""
try {
	$process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
} catch {
	Write-Host "Administrator rights were refused; nothing was installed."
	exit 1
}
if (-not (Test-Path -LiteralPath $result)) { Write-Host "The installer gave no result (exit $($process.ExitCode))."; exit 1 }
$outcome = Get-Content -Raw -LiteralPath $result | ConvertFrom-Json
Remove-Item -LiteralPath $result -Force
if ($outcome.status -ne "installed") { Write-Host "The installation failed: $($outcome.message)"; exit 1 }
$layout = Get-Content -Raw -LiteralPath $spec | ConvertFrom-Json
& (Join-Path $here "add_user_keyboard_layout.ps1") -Klid $outcome.klid -LanguageId $layout.language_id -LocaleName $layout.locale_name
if ($LASTEXITCODE -ne 0) { Write-Host "The layout is installed but could not be added to your languages: add it in Settings."; exit 1 }
Write-Host "The Ergopti layout is installed ($($outcome.klid))."
