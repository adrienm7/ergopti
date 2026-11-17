# tools/dev/collect-windows-field-report.ps1

# ==============================================================================
# MODULE: Windows field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Windows PC, the Windows
# counterpart of tools/dev/collect-macos-field-report.sh and
# collect-linux-field-report.sh: it updates the field branch from its base
# (dev unless it was derived from another branch), gathers the evidence the
# coordinator reads (system, toolchain, runtime, input-language, keyboard,
# autostart, privilege, process, memory, listener, proxy, antivirus and crash
# facts, the collector's own checks, today's ErgoptiPlus logs, their digest
# and their analysis), stores it under docs/field-reports/, then commits and
# pushes the branch. The logs are
# gitignored, so they are added with `git add -f`; the logger already masks
# secrets, the home folder, e-mail addresses and personal names, and the branch is
# public, so only copies scrubbed of typed text by tools/dev/field-log-scrub.py
# leave the PC and the digests read those copies. The whole folder then goes
# through tools/dev/field-report-redact.py before the commit, which is refused
# when a trace of the user or the PC remains. The personal hotstrings file
# never travels: tools/dev/hotstring-collisions.py reports which of its triggers
# share a bundled one. The facts have the profile folder and the user name
# replaced, and the proxy facts say only whether a proxy or a PAC file is set,
# never its address.
#
# The analysis: tools/dev/field-log-analyse.py, the analyser the three
# collectors share, reads the scrubbed day logs and writes analysis.md and
# analysis.json at the top of the report (errors grouped by template, every
# measured duration against the budget its code declares, lifecycle events,
# check verdicts, what to fix first) and prints the verdict marks and their
# summary line: the collector's own checks (step collector_checks) and the
# tray checks clicked today.
#
# The branch, the report folder and the base config key are the field_report
# names of static/ergopti_plus/_shared/core/text/data/identifiers.json; the git steps are
# the ones tools/dev/field-report-git.sh runs for the two shell collectors. The
# logs folder and file names, the installed paths.toml and the default
# configuration folder come from _shared/core/fs/data/paths/app_dirs.toml
# ([logs.windows]: %LOCALAPPDATA%\Ergopti\logs, [config.windows]:
# %LOCALAPPDATA%\Ergopti\paths.toml and %LOCALAPPDATA%\Ergopti\config).
#
# The machine facts: every Ergopti instance (the compiled driver, an
# interpreter running an ErgoptiPlus.ahk, any other AutoHotkey script) at the
# start, before the run, every few seconds during it and at the end (a second
# driver is said at once and first in the analysis), the other remappers
# (PowerToys Keyboard Manager, kanata, a Scancode Map, a keyboard filter
# driver, text expanders), the keyboards and layouts, the machine, the idle CPU
# per driver process, the Application and Defender events of Ergopti, and the
# app folders. tools/dev/field-report-facts.py turns their fact lines into
# 0_main/env.json and the step timings into 0_main/timeline.txt; the analysis
# reads both. Every step prints "step k/N" with the previous report's
# duration, a heartbeat every 15 s while it runs (a .NET timer: a PowerShell
# step blocks its thread) and [OK] or [FAIL] with its duration.
#
# NOT COVERED, AND WHY:
# - A PowerShell step cannot be cut short: the CIM and event-log queries of
#   the new steps carry their own timeouts and event caps instead.
# - The driver's log level is not raised: the field run protocol has no
#   request for it and the collector never writes the user's configuration;
#   the analysis says when the logs hold no DEBUG line.
# - The driver's own elevation is not read (querying an elevated process's
#   token needs elevation); the console's and the UAC state are.
# - The field run needs a developer driver of this clone already running
#   (tools/dev/run-windows-dev.ps1): the collector asks it, through the shared
#   protocol (_shared/diagnostics/data/field_run_protocol.json, diagnostics/engine/field_run/field_run.ahk), to
#   run its steps (windows/diagnostics/data/field_run_steps.json: boot cost, network,
#   composer) without their windows, and copies the results. It never starts
#   a driver itself: a second driver beside the maintainer's own spoils both.
#   Without a ready developer driver the field run is a skip in the analysis;
#   the tray checks clicked today are still read from the day log.
# - No services: the driver is a per-user process started from the Startup
#   folder or the Run key, which the autostart step lists.
# - No diagnostics export. The Diagnostics collection keeps its own consent and
#   guided steps in the driver's window, and the local control helper
#   (tools/diagnostics/open_windows_diagnostics.ps1) only opens that window.
#   The boot diagnostic snapshot (the one [Diagnostics] line) is in the day log
#   and digest_snapshot.
# - Not the live checks. tools/maintainer/windows-live-checks.cjs types real
#   keys into a private driver, refuses while the maintainer's own driver runs
#   and needs about 400 MB; run it on its own (docs/tooling/windows-maintainer-checks.md).
# - A LogsDirPath override in paths.toml is not read: pass -LogsDir with the
#   moved folder.
# - Closing the console window cannot be intercepted. Ctrl-C still copies the
#   logs and commits them, marked interrupted.
#
# USAGE (from any branch: outside a field/ branch the collector switches to
# field/win-<today>-<branch>, derived from that branch and created when
# missing; base.txt in the report names the base and the commit). Windows
# PowerShell 5.1 or PowerShell 7:
#   powershell -ExecutionPolicy Bypass -File tools/dev/collect-windows-field-report.ps1
#   ... -NoPush                 same, without the push
#   ... -LogsDir 'D:\logs'      the logs folder, when LogsDirPath moved it
#   ... -ConfigDir 'D:\config'  the configuration folder, instead of the one
#                               paths.toml names
#
# Each step records its exit status in steps.txt; a failed step never hides
# the others. This file stays ASCII: Windows PowerShell 5.1 reads a file
# without a BOM in the ANSI code page.
# ==============================================================================

[CmdletBinding()]
param(
	[switch]$NoPush,
	[string]$LogsDir = '',
	[string]$ConfigDir = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Set by Fail, so the closing block never commits after a fatal error.
$script:Failing = $false
function Fail([string]$Message) {
	$script:Failing = $true
	[Console]::Error.WriteLine("[field-report] ERROR: $Message")
	exit 1
}
# The console, not the pipeline: a function that logs still returns one value.
function Log([string]$Message) { [Console]::Out.WriteLine("[field-report] $Message") }

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Fail 'This collector runs on Windows only.' }

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SharedRoot = [IO.Path]::Combine($RepoRoot, 'static', 'ergopti_plus', '_shared')
$Identifiers = Get-Content -Raw -Encoding UTF8 -LiteralPath (
	[IO.Path]::Combine($SharedRoot, 'core', 'text', 'data', 'identifiers.json')) | ConvertFrom-Json
if (-not $Identifiers.PSObject.Properties['field_report']) { Fail 'identifiers.json has no field_report group.' }
$Names = $Identifiers.field_report
foreach ($Key in 'branch_prefix', 'folder', 'base_config_key') {
	if (-not $Names.PSObject.Properties[$Key] -or -not $Names.$Key) { Fail "identifiers.json names no field_report.$Key." }
}
$AppDirsToml = Get-Content -Raw -Encoding UTF8 -LiteralPath (
	[IO.Path]::Combine($SharedRoot, 'core', 'fs', 'data', 'paths', 'app_dirs.toml'))
$Utf8 = New-Object System.Text.UTF8Encoding $false
$DevTools = [IO.Path]::Combine($RepoRoot, 'tools', 'dev')
$BundledHotstrings = [IO.Path]::Combine($SharedRoot, 'hotstrings', 'data', 'catalogue')

# ===========================================
# ======= 1/ Helpers ========================
# ===========================================

# Runs git and returns its standard output; $script:GitStatus is its exit code.
function Get-Git {
	$ErrorActionPreference = 'Continue'
	$Lines = & git @args 2>$null
	$script:GitStatus = $LASTEXITCODE
	if ($null -eq $Lines) { return '' }
	return (@($Lines) -join "`n").Trim()
}

# Runs git with its output on the console; true when it succeeded.
function Invoke-Git {
	$ErrorActionPreference = 'Continue'
	& git @args | ForEach-Object { [Console]::Out.WriteLine($_) }
	return ($LASTEXITCODE -eq 0)
}

# Writes UTF-8 text without a BOM and with LF line ends, as the repository stores it.
function Write-Text([string]$Path, [string]$Text) {
	[IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $Utf8)
}
function Add-Step([string]$Line) {
	[IO.File]::AppendAllText($script:StepsFile, "$Line`n", $Utf8)
}

# Replaces the profile folder and the user name in a captured fact.
function Hide-User([string]$Text) {
	$Options = [Text.RegularExpressions.RegexOptions]::IgnoreCase
	if ($HOME -and $HOME.Length -gt 3) {
		$Text = [regex]::Replace($Text, [regex]::Escape($HOME), '~', $Options)
	}
	$User = [Environment]::UserName
	# A one- or two-letter name would mask ordinary words too.
	if ($User -and $User.Length -ge 3) {
		$Text = [regex]::Replace($Text, [regex]::Escape($User), '<user>', $Options)
	}
	return $Text
}

# How often a running step says it is still alive, the budget of a step that
# names none, and the quiet window of the idle CPU step; the contract test
# shortens the period and the window.
$HeartbeatSeconds = 15
if ($env:FIELD_HEARTBEAT_SECONDS_OVERRIDE) { $HeartbeatSeconds = [int]$env:FIELD_HEARTBEAT_SECONDS_OVERRIDE }
$StepDefaultBudgetSeconds = 30
$IdleSeconds = 20
if ($env:FIELD_IDLE_SECONDS_OVERRIDE) { $IdleSeconds = [int]$env:FIELD_IDLE_SECONDS_OVERRIDE }
# How often the field run's wait samples the Ergopti instances.
$SamplerSeconds = 10
$script:StepIndex = 0
$script:StepTotal = 0
$script:StepTimes = ''
$script:PreviousTimes = @{}
# The person-facing hint a step repeats in its heartbeat (set around a step).
$script:StepHint = ''
$Invariant = [Globalization.CultureInfo]::InvariantCulture

# The heartbeat runs on a timer thread: a PowerShell step blocks the pipeline
# thread, so only a .NET timer can print while it runs. Without it (a host
# that refuses Add-Type) the steps still run, and the start and end lines stay.
$script:Heartbeat = $false
try {
	if (-not ('ErgoptiFieldHeartbeat' -as [type])) {
		Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Threading;
public static class ErgoptiFieldHeartbeat {
	static Timer timer;
	static DateTime started;
	static string label;
	static string hint;
	public static void Start(string name, int seconds, string waitHint) {
		Stop();
		label = name;
		hint = waitHint;
		started = DateTime.UtcNow;
		timer = new Timer(Tick, null, seconds * 1000, seconds * 1000);
	}
	static void Tick(object state) {
		int elapsed = (int)(DateTime.UtcNow - started).TotalSeconds;
		Console.Out.WriteLine("[field-report]   ... " + label + " still running (" + elapsed + " s)");
		if (!String.IsNullOrEmpty(hint)) Console.Out.WriteLine("[field-report]   ... waiting for you: " + hint);
	}
	public static void Stop() {
		if (timer != null) { timer.Dispose(); timer = null; }
	}
}
'@
	}
	$script:Heartbeat = $true
} catch {
	Log "WARNING: no heartbeat in this host (Add-Type refused: $($_.Exception.Message)); each step still prints its start and end."
}

# The time now, epoch seconds with milliseconds, in the invariant culture: a
# French Windows writes a decimal comma the timeline cannot read.
function Get-Epoch { return ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0).ToString('F3', $Invariant) }

# Appends one line to step_times.tsv: name, kind, start, end, status, budget.
function Add-StepTime([string]$Name, [string]$Kind, [string]$Start, [string]$End, [string]$Status, [string]$Budget) {
	if (-not $script:StepTimes) { return }
	[IO.File]::AppendAllText($script:StepTimes, "$Name`t$Kind`t$Start`t$End`t$Status`t$Budget`n", $Utf8)
}

# Counts the steps for "step k/N" and reads what the previous report of this
# OS measured for each, its ETA.
function Initialize-StepTimes {
	$script:StepTimes = Join-Path $script:Out 'step_times.tsv'
	Write-Text $script:StepTimes "name`tkind`tstart`tend`tstatus`tbudget`n"
	# The named steps, plus one per digest of the digest table (run in a loop).
	$Source = Get-Content -Raw -Encoding UTF8 -LiteralPath $PSCommandPath
	$script:StepTotal = ([regex]::Matches($Source, "(?m)^\s*Invoke-Step '")).Count +
		([regex]::Matches($Source, "(?m)^\s*digest_\w+ = '")).Count
	$Reports = Join-Path $RepoRoot $Names.folder
	$Previous = @(Get-ChildItem -LiteralPath $Reports -Directory -Filter 'win-*' -ErrorAction SilentlyContinue |
		Where-Object { $_.FullName -ne $script:Out } | Sort-Object Name)
	if (-not $Previous.Count) { return }
	$File = Get-ChildItem -LiteralPath $Previous[-1].FullName -Recurse -Filter 'step_times.tsv' -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $File) { return }
	foreach ($Line in (Get-Content -Encoding UTF8 -LiteralPath $File.FullName)) {
		$Parts = $Line -split "`t"
		$Begin = 0.0
		$Finish = 0.0
		if ($Parts.Count -ge 4 -and [double]::TryParse($Parts[2], [Globalization.NumberStyles]::Float, $Invariant, [ref]$Begin) -and
			[double]::TryParse($Parts[3], [Globalization.NumberStyles]::Float, $Invariant, [ref]$Finish)) {
			$script:PreviousTimes[$Parts[0]] = [int]($Finish - $Begin)
		}
	}
}

# Runs one named step, captures its output into a file and records its status.
# A native command fails by its exit code, a cmdlet by an error record. It
# prints "step k/N" with the previous report's duration, a heartbeat while it
# runs (with the hint when it waits for the person), then [OK] or [FAIL] with
# its duration, and appends its timing to step_times.tsv. $Budget is the
# duration it should stay under; a CIM or event-log query inside a step
# carries its own timeout, since a PowerShell step cannot be cut short.
function Invoke-Step([string]$Name, [scriptblock]$Body, [int]$Budget = 0) {
	$File = Join-Path $script:Out "$Name.txt"
	$Code = 0
	$Text = ''
	$ErrorActionPreference = 'Continue'
	$global:LASTEXITCODE = 0
	$script:StepIndex++
	$Eta = ''
	if ($script:PreviousTimes.ContainsKey($Name)) { $Eta = " (about $($script:PreviousTimes[$Name]) s last time)" }
	Log "> step $($script:StepIndex)/$($script:StepTotal) $Name$Eta"
	if ($script:StepHint) { Log "  waiting for you: $($script:StepHint)" }
	$Started = Get-Epoch
	$Clock = [Diagnostics.Stopwatch]::StartNew()
	if ($script:Heartbeat) { [ErgoptiFieldHeartbeat]::Start($Name, $HeartbeatSeconds, $script:StepHint) }
	try {
		$Items = @(& $Body 2>&1)
		if ($LASTEXITCODE) { $Code = $LASTEXITCODE }
		foreach ($Item in $Items) {
			if ($Item -is [Management.Automation.ErrorRecord] -and
				-not ($Item.Exception -is [Management.Automation.RemoteException])) { $Code = 1 }
		}
		$Text = $Items | Out-String -Width 200
	} catch {
		$Text = $_ | Out-String -Width 200
		$Code = 1
	} finally {
		if ($script:Heartbeat) { [ErgoptiFieldHeartbeat]::Stop() }
	}
	$Seconds = [int]$Clock.Elapsed.TotalSeconds
	Write-Text $File (Hide-User $Text)
	Add-Step ('{0,-28} exit={1}' -f $Name, $Code)
	if ($Budget -le 0) { $Budget = $StepDefaultBudgetSeconds }
	Add-StepTime $Name 'collector' $Started (Get-Epoch) "$Code" "$Budget"
	if ($Code -ne 0) { Log "  [FAIL] $Name exited $Code ($Seconds s, kept in $File)" }
	else { Log "  [OK] $Name ($Seconds s)" }
}

# Reads the string and string-list keys of one [section] of app_dirs.toml.
function Read-TomlSection([string]$Section) {
	$Table = @{}
	$Inside = $false
	foreach ($Line in ($AppDirsToml -split "`r?`n")) {
		if ($Line -match '^\s*\[([^\]]+)\]\s*$') { $Inside = ($Matches[1] -eq $Section); continue }
		if (-not $Inside) { continue }
		if ($Line -match '^\s*(\w+)\s*=\s*"([^"]*)"') { $Table[$Matches[1]] = $Matches[2]; continue }
		if ($Line -match '^\s*(\w+)\s*=\s*\[(.*)\]') {
			$Table[$Matches[1]] = @([regex]::Matches($Matches[2], '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
		}
	}
	return $Table
}

# The one value of a section of app_dirs.toml; a missing key stops the collector.
function Get-AppDir([hashtable]$Table, [string]$Section, [string]$Key) {
	if (-not $Table.ContainsKey($Key)) { Fail "app_dirs.toml names no $Section.$Key." }
	return $Table[$Key]
}

$App = Read-TomlSection 'app'
$Logs = Read-TomlSection 'logs'
$Files = Read-TomlSection 'logs.files'
$Windows = Read-TomlSection 'logs.windows'
$ConfigWindows = Read-TomlSection 'config.windows'
$FolderName = Get-AppDir $App 'app' 'folder_name'
$MainPrefix = Get-AppDir $Files 'logs.files' 'unified_prefix'
$ErrorsPrefix = Get-AppDir $Files 'logs.files' 'errors_prefix'
$Extension = Get-AppDir $Files 'logs.files' 'extension'
$BootstrapLog = Get-AppDir $Files 'logs.files' 'bootstrap_log'
$CrashReports = Get-AppDir $Logs 'logs' 'crash_reports_dir'
$LogsBase = Get-AppDir $Windows 'logs.windows' 'base'
$LogsSegments = @(Get-AppDir $Windows 'logs.windows' 'segments')
$ConfigBase = Get-AppDir $ConfigWindows 'config.windows' 'base'
$ConfigSegments = @(Get-AppDir $ConfigWindows 'config.windows' 'segments')
$PathsFileSegments = @(Get-AppDir $ConfigWindows 'config.windows' 'paths_file')

# ===========================================
# ======= 2/ Field branch and base ==========
# ===========================================

Set-Location -LiteralPath $RepoRoot
$null = Get-Git rev-parse '--git-dir'
if ($script:GitStatus -ne 0) { Fail 'Not inside the Ergopti clone.' }
$Tracked = Get-Git status '--porcelain' '--untracked-files=no'
if ($script:GitStatus -ne 0) { Fail 'git status failed.' }
# A run cut short (window closed, kill) can leave tracked changes, and the next
# run refused to start (macOS field report 2026-11-15). A tester's clone holds
# no work of its own: the changes are stashed (git stash list keeps them) and
# the tree is reset, so the collector always starts.
if ($Tracked) {
	Log 'Tracked changes found (a previous run cut short?): stashed (git stash list) and the clone reset.'
	if (-not (Invoke-Git stash push '-q' '-m' "field-report auto-stash $(Get-Date -Format 'yyyy-MM-dd_HHmmss')")) {
		Fail 'Tracked changes could not be stashed; commit or discard them first.'
	}
	if (-not (Invoke-Git reset '-q' '--hard')) { Fail 'git reset --hard failed.' }
}

# The base is the branch the field branch derives from and is updated from on
# every run; git config remembers it so later runs on the field branch keep it.
$Branch = Get-Git branch '--show-current'
if ($Branch -and $Branch.StartsWith($Names.branch_prefix)) {
	$Base = Get-Git config '--get' "branch.$Branch.$($Names.base_config_key)"
	if ($script:GitStatus -ne 0 -or -not $Base) { $Base = 'dev' }
} else {
	# From dev, main or any other branch (or a detached commit) the report goes
	# to a field branch derived from it; today's branch for that base is reused.
	if ($Branch) { $Base = $Branch } else { $Base = Get-Git rev-parse '--short' HEAD }
	$Branch = $Names.branch_prefix + 'win-' + (Get-Date -Format 'yyyy-MM-dd') + '-' + ($Base -replace '/', '-')
	$null = Get-Git rev-parse '-q' '--verify' "refs/heads/$Branch"
	if ($script:GitStatus -eq 0) {
		if (-not (Invoke-Git switch '-q' $Branch)) { Fail "Cannot switch to $Branch." }
	} else {
		if (-not (Invoke-Git switch '-q' '-c' $Branch)) { Fail "Cannot create $Branch." }
	}
	if (-not (Invoke-Git config "branch.$Branch.$($Names.base_config_key)" $Base)) {
		Fail "Cannot record the base of $Branch."
	}
	Log "Collecting on $Branch, derived from $Base."
}

# A shallow clone (--depth 1) holds no common ancestor of the base and the
# field branch, so the update deepens both until the merge base is known; full
# history is never downloaded. A base that is not a branch on origin (a local
# branch or a commit) is not updated.
$Before = Get-Git rev-parse HEAD
if ($script:GitStatus -ne 0) { Fail 'Cannot read HEAD.' }
$null = Get-Git ls-remote '--exit-code' '--heads' origin $Base
if ($script:GitStatus -eq 0) {
	Log "Fetching $Base and bringing it into $Branch..."
	$Depth = 50
	while ($true) {
		if (-not (Invoke-Git fetch '-q' '--depth' $Depth origin $Base)) { Fail "git fetch of $Base failed." }
		$BaseHead = Get-Git rev-parse FETCH_HEAD
		if ($script:GitStatus -ne 0) { Fail "Cannot read the fetched $Base head." }
		$null = Get-Git merge-base HEAD $BaseHead
		if ($script:GitStatus -eq 0) { break }
		if ($Depth -ge 3200) { Fail "No common history with $Base within $Depth commits; re-clone with --depth 1." }
		$Depth = $Depth * 4
	}
	$null = Get-Git merge '--ff-only' $BaseHead
	if ($script:GitStatus -ne 0 -and -not (Invoke-Git merge '--no-edit' $BaseHead)) {
		Fail "Could not bring $Base into $Branch; resolve the merge and run again."
	}
} else {
	Log "$Base is not a branch on origin: $Branch is not updated."
}
# PowerShell runs the version of this file it parsed at start, so when the
# update moved the branch the updated collector runs instead; it finds HEAD
# current and never reruns, the marker is a guard.
if ((Get-Git rev-parse HEAD) -ne $Before) {
	if ($env:ERGOPTI_FIELD_REPORT_RERUN) { Fail "The rerun moved $Branch again; run the collector again." }
	Log "$Branch updated: running the updated collector."
	$env:ERGOPTI_FIELD_REPORT_RERUN = '1'
	# -File takes plain arguments, not the "-Name:value" form of a splat.
	$Rerun = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
	if ($NoPush) { $Rerun += '-NoPush' }
	if ($LogsDir) { $Rerun += @('-LogsDir', $LogsDir) }
	if ($ConfigDir) { $Rerun += @('-ConfigDir', $ConfigDir) }
	& (Get-Process -Id $PID).Path @Rerun
	exit $LASTEXITCODE
}

$Stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$StartDay = Get-Date -Format 'yyyy-MM-dd'
$OutRelative = "$($Names.folder)/win-$Stamp"
$script:Out = Join-Path $RepoRoot $OutRelative
# Two runs within one second would share a folder and one base.txt.
if (Test-Path -LiteralPath $script:Out) { Fail "$OutRelative already exists; run the collector again." }
$null = New-Item -ItemType Directory -Path $script:Out
$script:StepsFile = Join-Path $script:Out 'steps.txt'
Write-Text $script:StepsFile ''
# The coordinator reads which code the report ran on before anything else.
$Commit = Get-Git rev-parse '--short' HEAD
Write-Text (Join-Path $script:Out 'base.txt') "field_branch: $Branch`nbase: $Base`ncommit: $Commit`n"
Initialize-StepTimes
$RunStarted = Get-Date

# ===========================================
# ======= 3/ Logs, commit and push ==========
# ===========================================

# An app_dirs.toml folder: its base variable followed by its segments, "" when
# the variable is unset.
function Join-AppDir([string]$Base, [string[]]$Segments) {
	$Folder = [Environment]::GetEnvironmentVariable($Base)
	if (-not $Folder) { return '' }
	foreach ($Segment in $Segments) { $Folder = Join-Path $Folder ($Segment -replace '\{app\}', $FolderName) }
	return $Folder
}

# The logs folder: -LogsDir, else the app_dirs.toml default.
function Resolve-LogsDir {
	if ($LogsDir) { return $LogsDir }
	return Join-AppDir $LogsBase $LogsSegments
}

# The configuration folder, resolved like core/lifecycle/engine/boot.ahk: -ConfigDir, else the
# ConfigDirPath of the installed paths.toml or of the source run's, else the default.
function Resolve-ConfigDir {
	if ($ConfigDir) { return $ConfigDir }
	$Driver = [IO.Path]::Combine($SharedRoot, '..', 'windows', '_generated', 'paths.toml')
	foreach ($Candidate in (Join-AppDir $ConfigBase $PathsFileSegments), $Driver) {
		if (-not $Candidate -or -not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { continue }
		$Text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Candidate
		if ($Text -match '(?m)^\s*ConfigDirPath\s*=\s*"([^"]+)"') { return $Matches[1] }
	}
	$Default = Join-AppDir $ConfigBase $ConfigSegments
	if (-not $Default) { Fail "%$ConfigBase% is unset: pass -ConfigDir." }
	return $Default
}

# How long a ready developer driver may take to accept the request (it looks
# every [ui] field_run_poll_ms), how long the collector waits for done after the
# request's own deadline, and how often it looks.
$FieldRunAcceptSeconds = 60
$FieldRunGraceSeconds = 60
$FieldRunPollSeconds = 2
# The results folder of this run's request, copied into the report at the end.
$script:FieldRunResults = ''

# Asks the developer driver of this clone to run its field run steps, waits for
# its done marker and writes one "check=<step> verdict=<...>" line per result
# into field_run_checks.txt, which the analysis marks. A driver that is not
# ready, a refusal or a timeout is a verdict line too, never a prompt.
function Invoke-FieldRun {
	$Protocol = Get-Content -Raw -Encoding UTF8 -LiteralPath (
		[IO.Path]::Combine($SharedRoot, 'diagnostics', 'data', 'field_run_protocol.json')) | ConvertFrom-Json
	$Declared = Get-Content -Raw -Encoding UTF8 -LiteralPath (
		Join-Path $RepoRoot $Protocol.steps_file.windows) | ConvertFrom-Json
	$Files = $Protocol.files
	$Folder = Join-Path $RepoRoot $Protocol.folder.clone
	$Checks = Join-Path $script:Out 'field_run_checks.txt'
	$Ready = Join-Path $Folder $Files.ready
	$DriverPid = 0
	if (Test-Path -LiteralPath $Ready -PathType Leaf) {
		try { $DriverPid = [int](Get-Content -Raw -Encoding UTF8 -LiteralPath $Ready | ConvertFrom-Json).pid }
		catch { $DriverPid = 0 }
	}
	if ($DriverPid -le 0 -or -not (Get-Process -Id $DriverPid -ErrorAction SilentlyContinue)) {
		Log 'No developer driver of this clone is ready (tools/dev/run-windows-dev.ps1 starts one); the field run is skipped.'
		Write-Text $Checks "check=field_run verdict=skip codes=no_ready_driver`n"
		return
	}
	$RequestId = 'win-' + $Stamp
	$Deadline = [int]$Declared.deadline_seconds.default
	$Refused = Join-Path $Folder $Files.refused
	if (Test-Path -LiteralPath $Refused) { Remove-Item -LiteralPath $Refused -Force }
	$Request = '{"schema":' + $Protocol.schema + ',"request_id":"' + $RequestId + '","steps":["' +
		$Protocol.all_steps + '"],"deadline_seconds":' + $Deadline + '}'
	$Stage = Join-Path $Folder ('.' + $Files.request + '.tmp')
	Write-Text $Stage "$Request`n"
	Move-Item -Force -LiteralPath $Stage -Destination (Join-Path $Folder $Files.request)
	$script:FieldRunResults = Join-Path (Join-Path $Folder $Files.results) $RequestId
	Log "Developer driver ready (pid $DriverPid); requesting every field run step within $Deadline s."
	$Seen = @{}
	$Lines = New-Object System.Collections.Generic.List[string]
	# Reads the results written since the last look, in step order.
	$ReadResults = {
		$Found = @(Get-ChildItem -LiteralPath $script:FieldRunResults -File -ErrorAction SilentlyContinue |
			Where-Object { $_.Name -match $Protocol.result_file_pattern } | Sort-Object Name)
		foreach ($File in $Found) {
			if ($Seen.ContainsKey($File.Name)) { continue }
			$Result = Get-Content -Raw -Encoding UTF8 -LiteralPath $File.FullName | ConvertFrom-Json
			$Seen[$File.Name] = $true
			Log "  field run $($File.BaseName): $($Result.verdict)"
			$Lines.Add("check=$($Result.step) verdict=$($Result.verdict) codes=$(@($Result.codes) -join ',')")
		}
	}
	$Sent = Get-Date
	$LastNote = $Sent
	$LastSample = [datetime]::MinValue
	$Timeline = Join-Path $script:Out 'instances_timeline.txt'
	while ($true) {
		# A second driver or a restart during the run is on record.
		if (((Get-Date) - $LastSample).TotalSeconds -ge $SamplerSeconds) {
			$LastSample = Get-Date
			[IO.File]::AppendAllText($Timeline, ((Get-FieldInstances 'sample') -join "`n") + "`n", $Utf8)
		}
		# A step can stay silent for minutes: the heartbeat says how far the run is.
		if (((Get-Date) - $LastNote).TotalSeconds -ge $HeartbeatSeconds) {
			$LastNote = Get-Date
			Log "  ... field run still running: $($Seen.Count) step result(s), $([int]((Get-Date) - $Sent).TotalSeconds) s since the request."
		}
		if (Test-Path -LiteralPath $Refused -PathType Leaf) {
			$Refusal = Get-Content -Raw -Encoding UTF8 -LiteralPath $Refused | ConvertFrom-Json
			Log "The developer driver refused the field run request: $($Refusal.reason)."
			$Lines.Add("check=field_run verdict=fail codes=refused_$($Refusal.reason)")
			break
		}
		& $ReadResults
		if (Test-Path -LiteralPath (Join-Path $script:FieldRunResults $Files.done) -PathType Leaf) {
			# A result written just before done is read once more.
			& $ReadResults
			Log 'Field run done.'
			break
		}
		$Elapsed = ((Get-Date) - $Sent).TotalSeconds
		$Accepted = Test-Path -LiteralPath (Join-Path $script:FieldRunResults $Files.accepted) -PathType Leaf
		if (-not $Accepted -and $Elapsed -ge $FieldRunAcceptSeconds) {
			# Withdrawn, so no run starts after the collector gave up on it.
			$Pending = Join-Path $Folder $Files.request
			if (Test-Path -LiteralPath $Pending) { Remove-Item -LiteralPath $Pending -Force }
			Log "The developer driver did not accept the request within $FieldRunAcceptSeconds s; withdrawn."
			$Lines.Add('check=field_run verdict=fail codes=not_accepted')
			break
		}
		if ($Elapsed -ge ($Deadline + $FieldRunGraceSeconds)) {
			Log "No done marker $($Deadline + $FieldRunGraceSeconds) s after the request; keeping the partial results."
			$Lines.Add('check=field_run verdict=timeout codes=no_done_marker')
			break
		}
		if (-not (Get-Process -Id $DriverPid -ErrorAction SilentlyContinue)) {
			Log 'The developer driver is gone; keeping the partial results.'
			$Lines.Add('check=field_run verdict=fail codes=driver_gone')
			break
		}
		Start-Sleep -Seconds $FieldRunPollSeconds
	}
	Write-Text $Checks (($Lines -join "`n") + "`n")
}

# Prints a tab-separated fact line: its type, then key=value pairs, for
# tools/dev/field-report-facts.py (env.json).
function Format-Fact([string]$Type, [string[]]$Pairs) {
	$Clean = @($Pairs | ForEach-Object { ($_ -replace "[`t`r`n]", ' ') })
	return ((@('fact', $Type) + $Clean) -join "`t")
}

# The Ergopti instances of one phase (start, before_run, sample, end): the
# compiled driver, an interpreter running this clone's or another copy's
# ErgoptiPlus.ahk, and every other AutoHotkey script (another remapper). A
# second driver (an installed one beside a developer run) or a restart is on
# record. The command lines are matched, never printed; a script is named by
# its file name only. A sample skips the signature check, which costs a call.
# Get-Process finds the candidates; WMI, slow on some PCs (2.4 s a query on the
# maintainer's), is asked once per new process for its command line and
# parent, which never change, and the answers are kept for the next phase.
$script:ProcessDetails = @{}
function Get-FieldInstances([string]$Phase) {
	$Now = Get-Epoch
	$Lines = @(Format-Fact 'sample' @("phase=$Phase", "t=$Now"))
	$Ahk = [regex]::Escape($Identifiers.app.ahk)
	$Candidates = @(Get-Process -Name $Identifiers.app.name, 'AutoHotkey*' -ErrorAction SilentlyContinue)
	$Unknown = @($Candidates | Where-Object { -not $script:ProcessDetails.ContainsKey("$($_.Id)@$($_.StartTime)") })
	if ($Unknown.Count) {
		$Filter = (@($Unknown | ForEach-Object { "ProcessId = $($_.Id)" }) -join ' OR ')
		foreach ($Row in @(Get-CimInstance Win32_Process -Filter $Filter -OperationTimeoutSec 20 -ErrorAction SilentlyContinue)) {
			$Match = $Unknown | Where-Object { $_.Id -eq $Row.ProcessId } | Select-Object -First 1
			if ($Match) { $script:ProcessDetails["$($Match.Id)@$($Match.StartTime)"] = @([string]$Row.CommandLine, $Row.ParentProcessId) }
		}
	}
	foreach ($Process in $Candidates) {
		$Key = "$($Process.Id)@$($Process.StartTime)"
		$Command = ''
		$ParentId = ''
		if ($script:ProcessDetails.ContainsKey($Key)) { $Command = $script:ProcessDetails[$Key][0]; $ParentId = $script:ProcessDetails[$Key][1] }
		if ($Process.ProcessName -eq $Identifiers.app.name) { $Role = 'driver'; $Name = $Identifiers.app.name; $Origin = 'release' }
		elseif ($Command -match $Ahk) {
			$Role = 'driver'; $Name = $Identifiers.app.ahk
			if ($Command -match [regex]::Escape($RepoRoot)) { $Origin = 'dev' } else { $Origin = 'other_source' }
		} else {
			$Role = 'remapper'; $Origin = 'other'
			$Script = [regex]::Match($Command, '([^\\/"]+\.ahk)').Groups[1].Value
			if (-not $Script) { $Script = 'unnamed script' }
			$Name = "AutoHotkey script $Script"
		}
		$Path = [string]$Process.Path
		$Version = ''
		$Signer = ''
		if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
			$Version = [string](Get-Item -LiteralPath $Path).VersionInfo.FileVersion
			if ($Phase -ne 'sample') {
				$Signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
				if ($Signature) {
					$Signer = "$($Signature.Status)"
					if ($Signature.SignerCertificate) { $Signer += ' ' + ($Signature.SignerCertificate.Subject -replace '^CN=([^,]+).*$', '$1') }
				}
			}
		}
		$Parent = ''
		# A parent that has exited returns nothing; StrictMode refuses .Name on it.
		if ($ParentId) {
			$ParentProcess = Get-Process -Id $ParentId -ErrorAction SilentlyContinue
			if ($ParentProcess) { $Parent = $ParentProcess.Name }
		}
		$Started = ''
		if ($Process.StartTime) { $Started = $Process.StartTime.ToString('s') }
		$Cpu = ''
		if ($null -ne $Process.TotalProcessorTime) { $Cpu = $Process.TotalProcessorTime.TotalSeconds.ToString('F2', $Invariant) }
		$Lines += Format-Fact 'instance' @("phase=$Phase", "t=$Now", "role=$Role", "name=$Name", "pid=$($Process.Id)",
			"ppid=$ParentId", "parent=$Parent", "started=$Started", "cpu_s=$Cpu",
			"rss_kb=$([int64]($Process.WorkingSet64 / 1KB))", "origin=$Origin", "path=$Path", "version=$Version",
			'bundle_id=', "team=$Signer")
	}
	return $Lines
}

# Says at once, in the console, when one phase saw two drivers: the second
# hook sees every key too, and the run's key checks are spoiled.
function Show-MultipleDrivers([string[]]$Lines, [string]$Phase) {
	$Drivers = @($Lines | Where-Object { $_ -match "^fact`tinstance`t.*`trole=driver`t" })
	if ($Drivers.Count -le 1) { return }
	Log "WARNING: $($Drivers.Count) Ergopti drivers are running at once ($Phase): quit the one you are not testing."
	foreach ($Line in $Drivers) {
		$Fields = @{}
		foreach ($Part in ($Line -split "`t")) { if ($Part -match '^(\w+)=(.*)$') { $Fields[$Matches[1]] = $Matches[2] } }
		Log "   pid $($Fields['pid']) ($($Fields['origin'])): $(Hide-User $Fields['path'])"
	}
}

# The CPU time of every process, by pid, for the idle window.
function Get-CpuTimes {
	$Times = @{}
	foreach ($Process in (Get-Process -ErrorAction SilentlyContinue)) {
		# A protected process (another session, a service) gives no CPU time.
		if ($null -eq $Process.TotalProcessorTime) { continue }
		$Times[$Process.Id] = @($Process.ProcessName, $Process.TotalProcessorTime.TotalMilliseconds)
	}
	return $Times
}

# The first Python that really runs: the python3 of a Windows without Python is
# a Microsoft Store stub that only prints a hint and fails.
function Find-Python {
	$ErrorActionPreference = 'Continue'
	foreach ($Name in 'python3', 'python', 'py') {
		if (-not (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)) { continue }
		$null = & $Name --version 2>&1
		if ($LASTEXITCODE -eq 0) { return $Name }
	}
	return ''
}

# Copies one log into the report without the user's typed text; true when copied.
# Never falls back to the raw log: it would publish the typed text.
function Copy-ScrubbedLog([string]$Source) {
	$Name = Split-Path -Leaf $Source
	$Target = Join-Path $script:Out $Name
	$Code = 1
	if ($script:Python) {
		$ErrorActionPreference = 'Continue'
		& $script:Python (Join-Path $DevTools 'field-log-scrub.py') $Source $Target $BundledHotstrings 2>$null
		$Code = $LASTEXITCODE
	}
	if ($Code -eq 0) {
		Add-Step ('{0,-28} copied (scrubbed)' -f $Name)
		return $true
	}
	if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
	Add-Step ('{0,-28} scrub failed, not copied' -f $Name)
	return $false
}

# Copies the logs and the digest, commits and pushes, once: from the normal end
# and from the closing block after Ctrl-C.
$script:Finalized = $false
$script:Interrupted = $false
function Complete-Report {
	if ($script:Finalized) { return }
	$script:Finalized = $true
	$Days = @($StartDay)
	$Today = Get-Date -Format 'yyyy-MM-dd'
	# A run that crosses midnight spans two day logs: keep both, oldest first.
	if ($Today -ne $StartDay) { $Days += $Today }
	$script:Python = Find-Python
	$DayLogs = @()
	$Folder = Resolve-LogsDir
	if (-not $Folder) {
		Add-Step ('{0,-28} unresolved (%{1}% is empty; pass -LogsDir)' -f 'logs', $LogsBase)
	} elseif (Test-Path -LiteralPath $Folder -PathType Container) {
		foreach ($Day in $Days) {
			foreach ($Name in "$MainPrefix$Day$Extension", "$ErrorsPrefix$Day$Extension") {
				$Source = Join-Path $Folder $Name
				if (Test-Path -LiteralPath $Source -PathType Leaf) { $null = Copy-ScrubbedLog $Source }
			}
			# The digests read the scrubbed copies, never the raw day log.
			$DayLog = Join-Path $script:Out "$MainPrefix$Day$Extension"
			if (Test-Path -LiteralPath $DayLog -PathType Leaf) { $DayLogs += $DayLog }
		}
		# The topical sub-logs keep the download, server, boot, menu, layout,
		# dispatch, tray and gesture lines of earlier days; the hotstring and
		# keystats ones can carry typed text and stay.
		$Topical = @('llm', 'ollama', 'boot', 'menu', 'layout', 'dispatch', 'tray', 'gestures') | ForEach-Object { "$MainPrefix$_$Extension" }
		foreach ($Name in @($Topical) + @($BootstrapLog)) {
			$Source = Join-Path $Folder $Name
			if (Test-Path -LiteralPath $Source -PathType Leaf) { $null = Copy-ScrubbedLog $Source }
		}
		# Crash reports are named, not copied: a dump is read on request.
		$Crashes = Join-Path $Folder $CrashReports
		Invoke-Step 'crash_reports' {
			if (Test-Path -LiteralPath $Crashes) { Get-ChildItem -LiteralPath $Crashes | Select-Object Name, Length, LastWriteTime }
			else { 'no crash report' }
		}
		if ($DayLogs.Count -gt 0) {
			$Digests = [ordered]@{
				digest_boot = 'Boot complete|Boot completed with|Boot stage completed'
				digest_slow = '\[HotPath\]|Slow |Main-thread hold of'
				digest_errors = '\[(ERROR|WARNING)\]'
				digest_snapshot = '\[Diagnostics\]'
				digest_field_checks = 'check=[a-z_]+ verdict='
				digest_input = 'InputHook|KeyboardHook|layout|CapsWord|tap.hold'
			}
			foreach ($Entry in $Digests.GetEnumerator()) {
				$Pattern = $Entry.Value
				Invoke-Step $Entry.Key {
					Select-String -LiteralPath $DayLogs -Pattern $Pattern -CaseSensitive | ForEach-Object { $_.Line }
				}
			}
		} else {
			Add-Step ('{0,-28} missing' -f 'day_log')
		}
	} else {
		Add-Step ('{0,-28} missing' -f 'logs')
		Write-Text (Join-Path $script:Out 'logs_dir.txt') (Hide-User "$Folder`n")
	}

	# The field run's results, even after Ctrl-C cut its wait short.
	if ($script:FieldRunResults -and (Test-Path -LiteralPath $script:FieldRunResults -PathType Container)) {
		Copy-Item -Recurse -Force -LiteralPath $script:FieldRunResults -Destination (Join-Path $script:Out 'field_run')
		Add-Step ('{0,-28} copied' -f 'field_run_results')
	}

	# Which personal triggers share a bundled one, with both sides' flags and no
	# replacement text: the personal file itself never travels.
	Invoke-Step 'hotstring_collisions' {
		if (-not $script:Python) { throw 'No Python interpreter runs on this PC.' }
		& $script:Python (Join-Path $DevTools 'hotstring-collisions.py') (
			[IO.Path]::Combine((Resolve-ConfigDir), 'hotstrings', 'personal_hotstrings.toml')) $BundledHotstrings
	}

	# env.json and the timeline from the fact lines, the step timings, the
	# field run's results and the scrubbed day logs; the analysis reads both.
	if ($script:Python) {
		$ErrorActionPreference = 'Continue'
		& $script:Python (Join-Path $DevTools 'field-report-facts.py') 'build' $script:Out '--os' 'win'
		Add-Step ('{0,-28} exit={1}' -f 'facts', $LASTEXITCODE)
		if ($LASTEXITCODE -ne 0) { Log "step 'facts' exited $LASTEXITCODE" }
	} else {
		Add-Step ('{0,-28} skipped (no Python interpreter runs on this PC)' -f 'facts')
	}

	# Last: it also reads the check verdicts the steps above wrote. Its output
	# goes straight to the console: captured, Windows PowerShell 5.1 would decode
	# the verdict marks in the OEM code page.
	if ($script:Python) {
		$ErrorActionPreference = 'Continue'
		$Analyser = @((Join-Path $DevTools 'field-log-analyse.py'), '--repo', $RepoRoot, '--out', $script:Out)
		& $script:Python @Analyser @DayLogs
		Add-Step ('{0,-28} exit={1}' -f 'analysis', $LASTEXITCODE)
		if ($LASTEXITCODE -ne 0) { Log "step 'analysis' exited $LASTEXITCODE" }
	} else {
		Add-Step ('{0,-28} skipped (no Python interpreter runs on this PC)' -f 'analysis')
	}

	# After every step that reads the flat names: the synthesis goes to 0_main,
	# the rest to numbered subfolders (field-report-tidy.py). Nothing writes
	# steps.txt after this point.
	if ($script:Python) {
		$ErrorActionPreference = 'Continue'
		& $script:Python (Join-Path $DevTools 'field-report-tidy.py') $script:Out
		if ($LASTEXITCODE -eq 0) { Log "Read first: $OutRelative/0_main/analysis.md (index in 0_main/README.md)." }
		else { Log 'WARNING: the report folder could not be sorted into subfolders; it stays flat.' }
	}

	$Subject = "docs(field): Windows field report $Stamp on $Base"
	if ($script:Interrupted) { $Subject = "$Subject (interrupted)" }
	Log "Collected into ${OutRelative}:"
	Get-ChildItem -LiteralPath $script:Out | ForEach-Object { [Console]::Out.WriteLine("  $($_.Name)") }
	# The branch is public and Hide-User only knows the profile folder and the
	# account name: the shared redaction also removes the domain, the host name,
	# the full name and any e-mail address, and refuses a folder it cannot clean.
	if (-not $script:Python) { Fail "No Python interpreter runs on this PC: $OutRelative cannot be redacted, nothing was committed." }
	$ErrorActionPreference = 'Continue'
	& $script:Python (Join-Path $DevTools 'field-report-redact.py') $script:Out
	if ($LASTEXITCODE -ne 0) { Fail "$OutRelative still names this PC or its user; nothing was committed." }
	if (-not (Invoke-Git add '-f' $OutRelative)) { Fail "git add of $OutRelative failed." }
	if (-not (Invoke-Git commit '-q' '-m' $Subject $OutRelative)) { Fail 'git commit failed.' }
	if ($NoPush) {
		Log "Committed on $Branch without pushing."
	} else {
		if (-not (Invoke-Git push '-u' origin HEAD)) { Fail "git push failed; run 'git push -u origin HEAD' by hand." }
		Log "Pushed $Branch. Tell the coordinator: report $OutRelative."
	}
}

# ===========================================
# ======= 4/ System and toolchain ===========
# ===========================================

$Completed = $false
try {
	Invoke-Step 'versions' {
		git rev-parse --short HEAD
		"PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
		[Environment]::OSVersion.VersionString
		Get-CimInstance Win32_OperatingSystem -ErrorAction Stop |
			Format-List Caption, Version, BuildNumber, OSArchitecture, OSLanguage, TotalVisibleMemorySize
		"processors: $([Environment]::ProcessorCount)"
	}
	Invoke-Step 'toolchain' {
		git --version
		if (Get-Command node -ErrorAction SilentlyContinue) { node --version } else { 'node: missing' }
		# The interpreters tools/dev/run-windows-dev.ps1 looks for, x64 as the built exe.
		$Candidates = @(Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe')
		if ($env:LOCALAPPDATA) { $Candidates += Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe' }
		foreach ($Candidate in $Candidates) {
			if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
				"$Candidate $((Get-Item -LiteralPath $Candidate).VersionInfo.FileVersion)"
			} else { "$Candidate missing" }
		}
	}
	Invoke-Step 'input_languages' {
		Get-WinUserLanguageList -ErrorAction Stop | Format-List LanguageTag, InputMethodTips
		Get-ItemProperty -LiteralPath 'HKCU:\Keyboard Layout\Preload' -ErrorAction Stop |
			Select-Object -Property * -ExcludeProperty PS* | Format-List
	}
	Invoke-Step 'processes' {
		Get-Process -Name $Identifiers.app.name, 'AutoHotkey*', 'ollama*', 'llama-server', 'omlx*', 'LM Studio', 'jan' -ErrorAction SilentlyContinue |
			Format-Table -AutoSize Name, Id, StartTime, @{ Name = 'WorkingSetMB'; Expression = { [int]($_.WorkingSet64 / 1MB) } }
	}
	# Loopback listeners show which local AI server runs (process names and ports).
	Invoke-Step 'listeners' {
		Get-NetTCPConnection -State Listen -ErrorAction Stop |
			Where-Object { $_.LocalAddress -in '127.0.0.1', '::1', '0.0.0.0', '::' } |
			Sort-Object LocalPort |
			Format-Table -AutoSize LocalAddress, LocalPort, OwningProcess,
				@{ Name = 'Process'; Expression = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name } }
	}
	# Whether a proxy or a PAC file is set, never its address.
	Invoke-Step 'proxy' {
		$Settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
		foreach ($Name in 'ProxyEnable', 'ProxyServer', 'AutoConfigURL', 'AutoDetect') {
			$Value = $Settings.PSObject.Properties[$Name]
			if ($null -eq $Value) { "${Name}: unset" }
			elseif ($Name -in 'ProxyEnable', 'AutoDetect') { "${Name}: $($Value.Value)" }
			else { "${Name}: set" }
		}
		foreach ($Name in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY') {
			if ([Environment]::GetEnvironmentVariable($Name)) { "${Name}: set" } else { "${Name}: unset" }
		}
	}
	Invoke-Step 'antivirus' {
		Get-MpComputerStatus -ErrorAction Stop |
			Format-List AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureVersion
	}
	# WinHTTP (the system services' proxy): direct or set, never its address. Read
	# from the registry: netsh words its answer in the display language, and a French
	# Windows read as "set". An absent value is the default, direct; the flags are
	# the DWORD at offset 8, where only bit 0 means direct.
	Invoke-Step 'proxy_winhttp' {
		$Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
		$Settings = Get-ItemProperty -LiteralPath $Key -Name 'WinHttpSettings' -ErrorAction SilentlyContinue
		$Bytes = if ($Settings) { $Settings.WinHttpSettings } else { $null }
		if ($Bytes -and $Bytes.Length -lt 12) { throw 'WinHttpSettings is too short to hold its flags.' }
		if (-not $Bytes -or -not ([BitConverter]::ToUInt32($Bytes, 8) -band 0xFFFFFFFE)) { 'WinHTTP: direct' } else { 'WinHTTP: set' }
	}
	Invoke-Step 'runtimes' {
		foreach ($Name in 'python', 'py', 'node', 'curl', 'ollama') {
			$Command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
			if ($Command) { "${Name}: $((& $Command.Source --version 2>&1 | Select-Object -First 1))" } else { "${Name}: missing" }
		}
		# The WebView2 runtime the settings and diagnostics windows need.
		$Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
		$Version = Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue
		if ($Version -and $Version.PSObject.Properties['pv']) { "WebView2: $($Version.pv)" } else { 'WebView2: missing' }
		# A missing tool is a fact here, not a failed step.
		$global:LASTEXITCODE = 0
	}
	Invoke-Step 'memory' {
		Get-CimInstance Win32_OperatingSystem -ErrorAction Stop |
			Format-List FreePhysicalMemory, TotalVisibleMemorySize, FreeVirtualMemory, LastBootUpTime
	}
	# The keyboards the hook sees: names and status, never what they type.
	Invoke-Step 'input_devices' {
		Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction Stop | Format-Table -AutoSize FriendlyName, Status
	}
	# How the driver starts at logon: names only, never a command line.
	Invoke-Step 'autostart' {
		$Startup = [Environment]::GetFolderPath('Startup')
		$Links = @(Get-ChildItem -LiteralPath $Startup -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ergopti' })
		if ($Links.Count) { $Links | ForEach-Object { "Startup folder: $($_.Name)" } } else { 'Startup folder: no Ergopti entry' }
		$Run = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
		$Names = @()
		if ($Run) { $Names = @($Run.PSObject.Properties | Where-Object { $_.Name -match 'ergopti' } | ForEach-Object { $_.Name }) }
		if ($Names.Count) { $Names | ForEach-Object { "Run key: $_" } } else { 'Run key: no Ergopti entry' }
		Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ergopti' } |
			ForEach-Object { "Scheduled task: $($_.TaskName) $($_.State)" }
	}
	# An elevated window refuses the keys of a driver that is not elevated.
	Invoke-Step 'privileges' {
		$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
		$Principal = New-Object Security.Principal.WindowsPrincipal $Identity
		"collector elevated: $($Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
		$Uac = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
		foreach ($Name in 'EnableLUA', 'ConsentPromptBehaviorAdmin') {
			if ($Uac -and $Uac.PSObject.Properties[$Name]) { "${Name}: $($Uac.$Name)" } else { "${Name}: unset" }
		}
	}
	# Crash dumps and application crashes of the last day: named, not copied.
	Invoke-Step 'crash_dumps' {
		$Pattern = 'AutoHotkey|ErgoptiPlus|ollama|python'
		foreach ($Dir in (Join-Path $env:LOCALAPPDATA 'CrashDumps'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')) {
			Get-ChildItem -LiteralPath $Dir -ErrorAction SilentlyContinue |
				Where-Object { $_.Name -match $Pattern -and $_.LastWriteTime -gt (Get-Date).AddDays(-1) } |
				ForEach-Object { "$($_.LastWriteTime.ToString('s')) $($_.Name)" }
		}
		$Since = (Get-Date).AddDays(-1)
		Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001, 1002; StartTime = $Since } -ErrorAction SilentlyContinue |
			Where-Object { $_.Message -match $Pattern } |
			ForEach-Object { "$($_.TimeCreated.ToString('s')) event $($_.Id): $(($_.Message -split "`r?`n")[0])" }
		'(end of the crash list)'
	}
	# The checks that need no person, one "check=<id> verdict=<...>" line each.
	Invoke-Step 'collector_checks' {
		# The interpreters tools/dev/run-windows-dev.ps1 looks for; a root that is
		# not set is skipped, so every verdict below is still written.
		$Interpreters = @()
		if ($env:ProgramFiles) { $Interpreters += Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe' }
		if ($env:LOCALAPPDATA) { $Interpreters += Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe' }
		$Found = @($Interpreters | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
		if ($Found.Count) { 'check=autohotkey verdict=pass codes=v2_x64_found' } else { 'check=autohotkey verdict=fail codes=v2_x64_missing' }
		# The compiled driver, or an interpreter running the source script (a
		# developer run); the command lines are only matched, never printed.
		$Driver = @(Get-Process -Name $Identifiers.app.name -ErrorAction SilentlyContinue)
		$Driver += @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue |
			Where-Object { $_.CommandLine -match [regex]::Escape("$($Identifiers.app.name).ahk") })
		if ($Driver.Count -eq 1) { 'check=driver_running verdict=pass codes=one_instance' }
		elseif ($Driver.Count -gt 1) { 'check=driver_running verdict=fail codes=several_instances' }
		else { 'check=driver_running verdict=fail codes=not_running' }
		if (Find-Python) { 'check=python verdict=pass codes=runs' } else { 'check=python verdict=fail codes=none_runs' }
		$Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
		if (Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue) { 'check=webview2 verdict=pass codes=installed' }
		else { 'check=webview2 verdict=fail codes=missing' }
		# The verdicts above are the result; a probe's exit code is not the step's.
		$global:LASTEXITCODE = 0
	}
	# Every Ergopti instance now, before the run, during it (the field run's
	# wait samples them) and after it.
	Invoke-Step 'instances_start' {
		$Lines = Get-FieldInstances 'start'
		Show-MultipleDrivers $Lines 'start'
		$Lines
	} 30
	# Other remappers and hooks: a second keyboard hook, a Scancode Map or a
	# keyboard filter driver changes what the driver sees.
	Invoke-Step 'remappers' {
		$Known = [ordered]@{
			'PowerToys.KeyboardManagerEngine' = 'PowerToys Keyboard Manager'
			'kanata' = 'kanata'; 'kanata_gui' = 'kanata'; 'kmonad' = 'kmonad'
			'espanso' = 'espanso'; 'TextExpander' = 'TextExpander'; 'PhraseExpress' = 'PhraseExpress'
			'Beeftext' = 'Beeftext'; 'Breevy' = 'Breevy'; 'Clavier' = 'Clavier+'
			'logioptionsplus_agent' = 'Logi Options+'; 'lghub_agent' = 'Logitech G HUB'
			'itype' = 'Microsoft Mouse and Keyboard Center'; 'RazerCentralService' = 'Razer Synapse'
			'AutoHotkeyU64' = 'AutoHotkey v1'; 'AutoHotkeyU32' = 'AutoHotkey v1'
		}
		$Running = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
		foreach ($Key in $Known.Keys) {
			if ($Running -contains $Key) {
				"running: $($Known[$Key])"
				Format-Fact 'remapper' @("name=$($Known[$Key])", 'running=yes', 'conflict=yes', "detail=process $Key")
			}
		}
		Get-FieldInstances 'remappers' | Where-Object { $_ -match "`trole=remapper`t" } | ForEach-Object {
			$Script = [regex]::Match($_, "`tname=([^`t]*)").Groups[1].Value
			"running: $Script"
			Format-Fact 'remapper' @("name=$Script", 'running=yes', 'conflict=yes', 'detail=another AutoHotkey script')
		}
		$Layout = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -ErrorAction SilentlyContinue
		if ($Layout -and $Layout.PSObject.Properties['Scancode Map']) {
			'Scancode Map: set (keys remapped below every application)'
			Format-Fact 'remapper' @('name=Scancode Map (registry)', 'running=yes', 'conflict=yes', 'detail=HKLM Keyboard Layout')
		} else { 'Scancode Map: unset' }
		$Class = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue
		$Filters = @()
		if ($Class -and $Class.PSObject.Properties['UpperFilters']) { $Filters = @($Class.UpperFilters) }
		"keyboard class upper filters: $($Filters -join ', ')"
		foreach ($Filter in ($Filters | Where-Object { $_ -ne 'kbdclass' })) {
			Format-Fact 'remapper' @("name=keyboard filter driver $Filter", 'running=yes', 'conflict=yes', 'detail=keyboard class UpperFilters')
		}
		$Substitutes = Get-ItemProperty -LiteralPath 'HKCU:\Keyboard Layout\Substitutes' -ErrorAction SilentlyContinue
		if ($Substitutes) { 'layout substitutes:'; $Substitutes | Select-Object -Property * -ExcludeProperty PS* | Format-List }
	} 60
	# What the driver needs from the session: no elevated window it cannot
	# reach (UIPI), and the UAC state the elevation check reads.
	Invoke-Step 'permissions' {
		$Principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
		$Elevated = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
		Format-Fact 'permission' @('name=collector_elevated', "state=$(if ($Elevated) { 'yes' } else { 'no' })", 'subject=this console')
		$Uac = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
		$Lua = 'unset'
		if ($Uac -and $Uac.PSObject.Properties['EnableLUA']) { $Lua = "$($Uac.EnableLUA)" }
		Format-Fact 'permission' @('name=uac', "state=$(if ($Lua -eq '0') { 'disabled' } else { 'enabled' })", "subject=EnableLUA=$Lua")
	} 30
	# The keyboards, with their vendor and product ids only (an instance id
	# can carry a serial), and the input languages and layouts.
	Invoke-Step 'keyboards' {
		foreach ($Device in @(Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction SilentlyContinue)) {
			$Ids = [regex]::Match([string]$Device.InstanceId, 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})')
			Format-Fact 'device' @('source=pnp', "name=$($Device.FriendlyName)", "vendor_id=$($Ids.Groups[1].Value)",
				"product_id=$($Ids.Groups[2].Value)", 'keyboard=yes', "status=$($Device.Status)", 'grabbed=unknown')
		}
		foreach ($Language in @(Get-WinUserLanguageList -ErrorAction SilentlyContinue)) {
			foreach ($Tip in @($Language.InputMethodTips)) { Format-Fact 'layout' @("id=$Tip", "language=$($Language.LanguageTag)") }
		}
	} 30
	# The machine env.json summarises: build, model, displays, locale, power,
	# security software, virtualization.
	Invoke-Step 'environment' {
		$Os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 20 -ErrorAction Stop
		$System = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 20 -ErrorAction SilentlyContinue
		$Version = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
		$Displays = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -OperationTimeoutSec 20 -ErrorAction SilentlyContinue).Count
		$Battery = @(Get-CimInstance Win32_Battery -OperationTimeoutSec 20 -ErrorAction SilentlyContinue)
		$Power = 'ac (no battery)'
		if ($Battery.Count) { if ($Battery[0].BatteryStatus -eq 2) { $Power = 'ac' } else { $Power = 'battery' } }
		$Antivirus = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -OperationTimeoutSec 20 -ErrorAction SilentlyContinue |
			ForEach-Object { $_.displayName }) -join ', '
		$Display = ''
		$Ubr = ''
		if ($Version) {
			if ($Version.PSObject.Properties['DisplayVersion']) { $Display = $Version.DisplayVersion }
			if ($Version.PSObject.Properties['UBR']) { $Ubr = ".$($Version.UBR)" }
		}
		$Virtual = 'no'
		if ($System -and ($System.HypervisorPresent -or ($System.Model -match 'Virtual|VMware|VirtualBox|KVM|QEMU'))) { $Virtual = 'yes' }
		Format-Fact 'env' @("os_name=$($Os.Caption)", "os_version=$Display", "os_build=$($Os.BuildNumber)$Ubr",
			"arch=$($Os.OSArchitecture)", "model=$(if ($System) { "$($System.Manufacturer) $($System.Model)" })",
			"memory_gb=$([int]($Os.TotalVisibleMemorySize / 1MB))", "displays=$Displays", "locale=$((Get-Culture).Name)",
			"system_locale=$((Get-WinSystemLocale -ErrorAction SilentlyContinue).Name)", "power=$Power",
			"security_software=$Antivirus", "virtual_machine=$Virtual",
			"uptime=$([int]((Get-Date) - $Os.LastBootUpTime).TotalMinutes) min",
			"powershell=$($PSVersionTable.PSVersion)")
	} 60
	# Ergopti's folders: mode, date and size, never their content.
	Invoke-Step 'app_folders' {
		foreach ($Folder in (Join-AppDir $LogsBase @($FolderName)), (Join-Path $env:ProgramFiles $Identifiers.app.name),
			(Join-Path $env:LOCALAPPDATA "Programs\$($Identifiers.app.name)")) {
			if ($Folder -and (Test-Path -LiteralPath $Folder)) {
				$Size = (Get-ChildItem -LiteralPath $Folder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
				"$Folder  $((Get-Item -LiteralPath $Folder).LastWriteTime.ToString('s'))  $([int]($Size / 1MB)) MB"
			} else { "absent: $Folder" }
		}
	} 60
	Invoke-Step 'instances_before_run' {
		$Lines = Get-FieldInstances 'before_run'
		Show-MultipleDrivers $Lines 'before_run'
		$Lines
	} 30
	# Last of the steps: the field run takes minutes, the facts above are kept
	# if it is interrupted.
	$FieldRunStarted = Get-Epoch
	Log '> field run: the developer driver runs its steps now; each verdict prints here.'
	try { Invoke-FieldRun }
	catch {
		Log "The field run could not be run: $($_.Exception.Message)"
		Add-Step ('{0,-28} failed ({1})' -f 'field_run', $_.Exception.Message)
	}
	Add-StepTime 'field_run' 'phase' $FieldRunStarted (Get-Epoch) 'done' '0'
	Invoke-Step 'instances_end' {
		$Lines = Get-FieldInstances 'end'
		Show-MultipleDrivers $Lines 'end'
		$Lines
	} 30
	# The CPU each driver process spends while nothing is typed, and the
	# busiest processes of the PC meanwhile.
	$script:StepHint = "keep your hands off the keyboard and mouse for $IdleSeconds s (idle CPU)"
	Invoke-Step 'idle_cpu' {
		$Before = Get-CpuTimes
		Start-Sleep -Seconds $IdleSeconds
		$After = Get-CpuTimes
		$Drivers = @(Get-FieldInstances 'idle' | Where-Object { $_ -match "`trole=driver`t" } |
			ForEach-Object { [int][regex]::Match($_, "`tpid=(\d+)").Groups[1].Value })
		"quiet window of $IdleSeconds s"
		$Deltas = foreach ($Id in $After.Keys) {
			if (-not $Before.ContainsKey($Id)) { continue }
			New-Object PSObject -Property @{ Id = $Id; Name = $After[$Id][0]; Ms = [int]($After[$Id][1] - $Before[$Id][1]) }
		}
		foreach ($Delta in @($Deltas | Where-Object { $Drivers -contains $_.Id })) {
			$Percent = (100.0 * $Delta.Ms / ($IdleSeconds * 1000)).ToString('F2', $Invariant)
			"$($Delta.Name) (pid $($Delta.Id)): $($Delta.Ms) ms, $Percent %"
			Format-Fact 'cpu' @('window=idle', "name=$($Delta.Name)", "pid=$($Delta.Id)", "cpu_ms=$($Delta.Ms)",
				"window_ms=$($IdleSeconds * 1000)", "percent=$Percent")
		}
		'== busiest processes over the window'
		$Deltas | Sort-Object Ms -Descending | Select-Object -First 12 | Format-Table -AutoSize Name, Id, Ms
	} ($IdleSeconds + 30)
	$script:StepHint = ''
	# The Application log's errors of the driver and its helpers since the
	# collector started, and what Microsoft Defender did to an Ergopti file
	# this week (a quarantined helper fails without a trace of its own).
	Invoke-Step 'event_log' {
		$Pattern = 'AutoHotkey|ErgoptiPlus|ergopti|ollama'
		$Queries = [ordered]@{
			'Application' = @{ LogName = 'Application'; Level = 1, 2, 3; StartTime = $RunStarted }
			'Defender' = @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117, 1118, 1119; StartTime = (Get-Date).AddDays(-7) }
		}
		foreach ($Log in $Queries.Keys) {
			# Get-WinEvent throws when nothing matches; that answer is a fact here.
			try {
				$Events = @(Get-WinEvent -FilterHashtable $Queries[$Log] -MaxEvents 500 -ErrorAction Stop | Where-Object { $_.Message -match $Pattern })
				"${Log}: $($Events.Count) matching event(s)"
				$Events | ForEach-Object { "$($_.TimeCreated.ToString('s')) $($_.ProviderName) $($_.Id): $(($_.Message -split "`r?`n")[0])" }
			} catch {
				"${Log}: no matching event ($($_.Exception.Message))"
			}
		}
	} 60
	$Completed = $true
} finally {
	# Ctrl-C ends the try block; the evidence collected so far is still committed.
	if (-not $script:Failing -and -not $script:Finalized) {
		if (-not $Completed) {
			$script:Interrupted = $true
			Log 'Interrupted: keeping the evidence collected so far.'
			Add-Step ('{0,-28} interrupted' -f 'collector')
		}
		Complete-Report
	}
}
if ($script:Interrupted) { exit 130 }
exit 0
