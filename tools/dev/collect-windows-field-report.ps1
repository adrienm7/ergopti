# tools/dev/collect-windows-field-report.ps1

# ==============================================================================
# MODULE: Windows field report collector
# DESCRIPTION:
# One command for a maintainer session on a real Windows PC, the Windows
# counterpart of tools/dev/collect-macos-field-report.sh and
# collect-linux-field-report.sh: it updates the field branch from its base
# (dev unless it was derived from another branch), gathers the evidence the
# coordinator reads (system, toolchain, input-language, process, listener,
# proxy and antivirus facts, today's ErgoptiPlus logs and their digest), stores
# it under docs/field-reports/, then commits and pushes the branch. The logs are
# gitignored, so they are added with `git add -f`; the logger already masks
# secrets, the home folder, e-mail addresses and personal names, the facts have
# the profile folder and the user name replaced, and the proxy facts say only
# whether a proxy or a PAC file is set, never its address.
#
# The branch, the report folder and the base config key are the field_report
# names of static/ergopti_plus/_shared/data/identifiers.json; the git steps are
# the ones tools/dev/field-report-git.sh runs for the two shell collectors. The
# logs folder and file names come from _shared/modules/paths/app_dirs.toml
# ([logs.windows]: %LOCALAPPDATA%\ergopti_plus\logs).
#
# NOT COVERED, AND WHY:
# - No field run. The AutoHotkey driver has no request protocol like the macOS
#   developer app's (infra/field_run.lua). Its one-click composer check runs
#   from the tray and writes one "check=<id> verdict=<...>" line to the day
#   log: the checks clicked today are in digest_field_checks.
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
#
# Each step records its exit status in steps.txt; a failed step never hides
# the others. This file stays ASCII: Windows PowerShell 5.1 reads a file
# without a BOM in the ANSI code page.
# ==============================================================================

[CmdletBinding()]
param(
	[switch]$NoPush,
	[string]$LogsDir = ''
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
	[IO.Path]::Combine($SharedRoot, 'data', 'identifiers.json')) | ConvertFrom-Json
if (-not $Identifiers.PSObject.Properties['field_report']) { Fail 'identifiers.json has no field_report group.' }
$Names = $Identifiers.field_report
foreach ($Key in 'branch_prefix', 'folder', 'base_config_key') {
	if (-not $Names.PSObject.Properties[$Key] -or -not $Names.$Key) { Fail "identifiers.json names no field_report.$Key." }
}
$AppDirsToml = Get-Content -Raw -Encoding UTF8 -LiteralPath (
	[IO.Path]::Combine($SharedRoot, 'modules', 'paths', 'app_dirs.toml'))
$Utf8 = New-Object System.Text.UTF8Encoding $false

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

# Runs one named step, captures its output into a file and records its status.
# A native command fails by its exit code, a cmdlet by an error record.
function Invoke-Step([string]$Name, [scriptblock]$Body) {
	$File = Join-Path $script:Out "$Name.txt"
	$Code = 0
	$Text = ''
	$ErrorActionPreference = 'Continue'
	$global:LASTEXITCODE = 0
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
	}
	Write-Text $File (Hide-User $Text)
	Add-Step ('{0,-28} exit={1}' -f $Name, $Code)
	if ($Code -ne 0) { Log "step '$Name' exited $Code (kept in $File)" }
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
$FolderName = Get-AppDir $App 'app' 'folder_name'
$MainPrefix = Get-AppDir $Files 'logs.files' 'unified_prefix'
$ErrorsPrefix = Get-AppDir $Files 'logs.files' 'errors_prefix'
$Extension = Get-AppDir $Files 'logs.files' 'extension'
$BootstrapLog = Get-AppDir $Files 'logs.files' 'bootstrap_log'
$CrashReports = Get-AppDir $Logs 'logs' 'crash_reports_dir'
$LogsBase = Get-AppDir $Windows 'logs.windows' 'base'
$LogsSegments = @(Get-AppDir $Windows 'logs.windows' 'segments')

# ===========================================
# ======= 2/ Field branch and base ==========
# ===========================================

Set-Location -LiteralPath $RepoRoot
$null = Get-Git rev-parse '--git-dir'
if ($script:GitStatus -ne 0) { Fail 'Not inside the Ergopti clone.' }
$Tracked = Get-Git status '--porcelain' '--untracked-files=no'
if ($script:GitStatus -ne 0) { Fail 'git status failed.' }
if ($Tracked) { Fail 'Commit or discard the tracked changes first: the collector commits only its own folder.' }

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

# ===========================================
# ======= 3/ Logs, commit and push ==========
# ===========================================

# The logs folder: -LogsDir, else the app_dirs.toml default.
function Resolve-LogsDir {
	if ($LogsDir) { return $LogsDir }
	$Root = [Environment]::GetEnvironmentVariable($LogsBase)
	if (-not $Root) { return '' }
	$Folder = $Root
	foreach ($Segment in $LogsSegments) { $Folder = Join-Path $Folder ($Segment -replace '\{app\}', $FolderName) }
	return $Folder
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
	$Folder = Resolve-LogsDir
	if (-not $Folder) {
		Add-Step ('{0,-28} unresolved (%{1}% is empty; pass -LogsDir)' -f 'logs', $LogsBase)
	} elseif (Test-Path -LiteralPath $Folder -PathType Container) {
		$DayLogs = @()
		foreach ($Day in $Days) {
			foreach ($Name in "$MainPrefix$Day$Extension", "$ErrorsPrefix$Day$Extension") {
				$Source = Join-Path $Folder $Name
				if (Test-Path -LiteralPath $Source -PathType Leaf) {
					Copy-Item -LiteralPath $Source -Destination $script:Out
					Add-Step ('{0,-28} copied' -f $Name)
				}
			}
			$DayLog = Join-Path $Folder "$MainPrefix$Day$Extension"
			if (Test-Path -LiteralPath $DayLog -PathType Leaf) { $DayLogs += $DayLog }
		}
		# The LLM sub-log keeps the download and server lines of earlier days.
		foreach ($Name in "$($MainPrefix)llm$Extension", $BootstrapLog) {
			$Source = Join-Path $Folder $Name
			if (Test-Path -LiteralPath $Source -PathType Leaf) {
				Copy-Item -LiteralPath $Source -Destination $script:Out
				Add-Step ('{0,-28} copied' -f $Name)
			}
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

	$Subject = "docs(field): Windows field report $Stamp on $Base"
	if ($script:Interrupted) { $Subject = "$Subject (interrupted)" }
	Log "Collected into ${OutRelative}:"
	Get-ChildItem -LiteralPath $script:Out | ForEach-Object { [Console]::Out.WriteLine("  $($_.Name)") }
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
