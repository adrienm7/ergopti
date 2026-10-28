# tools/test/fixtures/windows_dev_interpreter_controls.ps1
#
# Executes actual interpreter selection with real private files. Native mode runs
# the complete launcher and substitutes only process discovery and launch effects.

param([string]$Mode, [string]$Launcher, [string]$Scratch, [string]$Case)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ControlReceipt([string]$Path, $Value) {
	[IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

if ($Mode -eq 'selection') {
	$tokens = $null
	$errors = $null
	$ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors)
	if ($errors.Count -ne 0) { throw 'The real developer launcher must parse.' }
	$statements = @($ast.EndBlock.Statements)
	$start = @($statements | Where-Object {
		$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$ProcessName'
	})
	$end = @($statements | Where-Object {
		$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Running'
	})
	if ($start.Count -ne 1 -or $end.Count -ne 1) { throw 'The actual selection region must be unique.' }
	$source = [IO.File]::ReadAllText($Launcher)
	$selection = [ScriptBlock]::Create($source.Substring($start[0].Extent.EndOffset,
		$end[0].Extent.StartOffset - $start[0].Extent.EndOffset))
	# Only the terminal failure effect changes: a real refusal is observed as an
	# exception so all cases execute. Candidate selection and filesystem are real.
	function Fail([string]$Message) { throw $Message }
	$rows = @()
	foreach ($choice in @('default-machine', 'default-user', 'explicit-existing', 'explicit-missing', 'explicit-directory')) {
		$directory = Join-Path $Scratch $choice
		[void][IO.Directory]::CreateDirectory($directory)
		$env:ProgramFiles = Join-Path $directory 'program-files'
		$env:LOCALAPPDATA = Join-Path $directory 'local-appdata'
		$machine = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
		$user = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe'
		$explicit = Join-Path $directory 'requested interpreter.exe'
		if ($choice -ne 'default-user') {
			[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($machine))
			[IO.File]::WriteAllText($machine, 'inert machine interpreter')
		}
		[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($user))
		[IO.File]::WriteAllText($user, 'inert user interpreter')
		if ($choice -eq 'explicit-existing') { [IO.File]::WriteAllText($explicit, 'inert requested interpreter') }
		if ($choice -eq 'explicit-directory') { [void][IO.Directory]::CreateDirectory($explicit) }
		$AutoHotkey = $(if ($choice.StartsWith('explicit-')) { $explicit } else { '' })
		$Interpreter = $null
		$refused = $false
		try { . $selection } catch { $refused = $true }
		$expectedRefusal = $choice -eq 'explicit-missing' -or $choice -eq 'explicit-directory'
		$expected = $(if ($choice -eq 'default-user') { $user } elseif ($choice -eq 'explicit-existing') { $explicit } else { $machine })
		$passed = $(if ($expectedRefusal) { $refused -and $null -eq $Interpreter } else { -not $refused -and $Interpreter -ceq $expected })
		$rows += @{name=$choice;passed=$passed;refused=$refused;expected_refusal=$expectedRefusal;selected=$Interpreter;expected=$expected}
	}
	Write-ControlReceipt (Join-Path $Scratch 'selection.json') $rows
	return
}

if ($Mode -ne 'entry' -and $Mode -ne 'host-entry') { throw 'An entry control mode is required.' }
$nativeWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (($Mode -eq 'entry') -ne $nativeWindows) { throw 'Entry mode must match the real operating system.' }
$fixture = Join-Path $Scratch ('clone space ' + [char]0xe9)
$developer = Join-Path $fixture 'tools\dev'
$shared = Join-Path $fixture 'static\ergopti_plus\_shared\data'
[void][IO.Directory]::CreateDirectory($developer)
[void][IO.Directory]::CreateDirectory($shared)
$identifiersPath = Join-Path (Split-Path (Split-Path $Launcher)) '..\static\ergopti_plus\_shared\data\identifiers.json'
$identifiersPath = [IO.Path]::GetFullPath($identifiersPath)
[IO.File]::Copy($identifiersPath, (Join-Path $shared 'identifiers.json'), $false)
$identifiers = [IO.File]::ReadAllText((Join-Path $shared 'identifiers.json')) | ConvertFrom-Json
$driver = Join-Path $fixture 'static\ergopti_plus\windows'
[void][IO.Directory]::CreateDirectory($driver)
$entry = Join-Path $driver $identifiers.app.ahk
[IO.File]::WriteAllText($entry, 'inert private driver fixture')
$copy = Join-Path $developer 'run-windows-dev.ps1'
[IO.File]::Copy($Launcher, $copy, $false)
if ($Mode -eq 'host-entry') {
	# Only the platform admission boundary is unavailable on this host. Keep
	# native Windows entry controls byte-for-byte; this body probe is not them.
	$tokens = $null
	$errors = $null
	$ast = [Management.Automation.Language.Parser]::ParseFile($copy, [ref]$tokens, [ref]$errors)
	if ($errors.Count -ne 0) { throw 'The copied real launcher must parse.' }
	$guards = @($ast.EndBlock.Statements | Where-Object {
		$_ -is [Management.Automation.Language.IfStatementAst] -and
		$_.Extent.Text.Contains('[Environment]::OSVersion.Platform')
	})
	if ($guards.Count -ne 1) { throw 'The real platform admission boundary must be unique.' }
	$body = [IO.File]::ReadAllText($copy)
	$body = $body.Remove($guards[0].Extent.StartOffset, $guards[0].Extent.EndOffset - $guards[0].Extent.StartOffset)
	[IO.File]::WriteAllText($copy, $body, [Text.UTF8Encoding]::new($false))
}
$env:ProgramFiles = Join-Path $Scratch 'program-files'
$env:LOCALAPPDATA = Join-Path $Scratch 'local-appdata'
$machine = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
$user = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe'
$explicit = Join-Path $Scratch 'requested interpreter.exe'
if ($Case -notin @('default-user', 'default-none')) {
	[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($machine))
	[IO.File]::WriteAllText($machine, 'inert machine interpreter')
}
if ($Case -ne 'default-none') {
	[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($user))
	[IO.File]::WriteAllText($user, 'inert user interpreter')
}
if ($Case -eq 'explicit-existing' -or $Case -eq 'environment-existing') {
	[IO.File]::WriteAllText($explicit, 'inert requested interpreter')
}
if ($Case -eq 'explicit-directory') { [void][IO.Directory]::CreateDirectory($explicit) }
$script:effects = Join-Path $Scratch 'effects.txt'
$script:launchReceipt = Join-Path $Scratch 'launch.json'
$script:developerVariable = $identifiers.dev_source.environment
function Get-Process {
	param([string]$Name, [string]$ErrorAction)
	[IO.File]::AppendAllText($script:effects, 'observe:' + $Name + [Environment]::NewLine)
	return @()
}
function taskkill.exe {
	throw 'The fixture must never ask a real application to close.'
}
function Start-Process {
	param([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory)
	Write-ControlReceipt $script:launchReceipt @{interpreter=$FilePath;arguments=$ArgumentList;working_directory=$WorkingDirectory;
		developer_root=[Environment]::GetEnvironmentVariable($script:developerVariable)}
}
# Dot-sourced scripts publish their explicit exit through LASTEXITCODE.
$global:LASTEXITCODE = 0
if ($Case.StartsWith('environment-')) {
	$env:ERGOPTI_AUTOHOTKEY_EXE = $explicit
	. $copy
} elseif ($Case.StartsWith('explicit-')) {
	. $copy -AutoHotkey $explicit
} else {
	. $copy -AutoHotkey ''
}
exit $LASTEXITCODE
