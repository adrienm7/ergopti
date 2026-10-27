# tools/dev/run-windows-dev.ps1

# ==============================================================================
# MODULE: Windows developer driver runner
# DESCRIPTION:
# Runs ErgoptiPlus from this clone's static/ergopti_plus/windows sources with
# AutoHotkey v2, which is what the built exe embeds: the same vendor helpers
# (ergopti_nav_owner.dll, ergopti_network_pac.exe, sqlite3.dll, WebView2Loader,
# the PowerShell workers), the same config folder and the same AI runtimes. The
# clone root is handed to the driver in the shared developer variable
# (dev_source.environment), so a saved .ahk reloads it (infra/dev_source.ahk);
# the tray's Reload does it on demand. The updater is off: a source run has no
# release to update from (Updater_IsLocalSource).
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File tools\dev\run-windows-dev.ps1
#   ... -AutoHotkey 'D:\AutoHotkey\v2\AutoHotkey64.exe'   another interpreter
#
# A running ErgoptiPlus holds the single-instance mutex, so it is asked to close
# first (WM_CLOSE, as the tray's Quit); one that stays is named, never killed.
# ==============================================================================

[CmdletBinding()]
param([string]$AutoHotkey = $env:ERGOPTI_AUTOHOTKEY_EXE)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
	[Console]::Error.WriteLine("[windows-dev] ERROR: $Message")
	exit 1
}
function Log([string]$Message) { Write-Output "[windows-dev] $Message" }

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
	Fail 'The developer driver runs on Windows only.'
}
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath.TrimEnd('\')
$DriverDir = Join-Path $RepoRoot 'static\ergopti_plus\windows'
$Identifiers = Get-Content -Raw -Encoding UTF8 -LiteralPath (
	Join-Path $RepoRoot 'static\ergopti_plus\_shared\data\identifiers.json') | ConvertFrom-Json
$Variable = $Identifiers.dev_source.environment
if (-not $Variable) { Fail 'identifiers.json names no dev_source.environment.' }
$Entry = Join-Path $DriverDir $Identifiers.app.ahk
if (-not (Test-Path -LiteralPath $Entry -PathType Leaf)) { Fail "No driver at $Entry." }
$ProcessName = $Identifiers.app.name

# AutoHotkey v2, x64 as the built exe: the per-machine then the per-user install.
$Candidates = @()
if ($AutoHotkey) { $Candidates += $AutoHotkey }
$Candidates += (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe')
if ($env:LOCALAPPDATA) { $Candidates += (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe') }
$Interpreter = $Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $Interpreter) {
	Fail ("AutoHotkey v2 (AutoHotkey64.exe) not found in: " + ($Candidates -join ', ') +
		'. Install it from autohotkey.com or pass -AutoHotkey.')
}

$Running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
if ($Running.Count -gt 0) {
	Log "Asking the running $ProcessName to close (pids: $($Running.Id -join ', '))..."
	& taskkill.exe /IM $Identifiers.app.exe | Out-Null
	$Deadline = (Get-Date).AddSeconds(15)
	while ((Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) -and (Get-Date) -lt $Deadline) {
		Start-Sleep -Milliseconds 250
	}
	if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
		Fail "$ProcessName is still running; quit it from its tray menu, then run this again."
	}
}

[Environment]::SetEnvironmentVariable($Variable, $RepoRoot, 'Process')
Log "Starting $Entry with $Interpreter (developer source mode)."
Log 'A saved .ahk reloads the driver; the tray''s Reload does it on demand.'
Start-Process -FilePath $Interpreter -ArgumentList @("`"$Entry`"") -WorkingDirectory $DriverDir
