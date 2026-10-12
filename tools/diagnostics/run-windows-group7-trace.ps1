# tools/diagnostics/run-windows-group7-trace.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
Records actual native/HotIf/InputHook callbacks in an owned synthetic receiver.
.DESCRIPTION
Explicit foreground consent, pinned tools, source-bound DLL and natural cleanup
are mandatory. Two requested installation sequences remain observations rather
than a qualification of physical hook order. No physical capture is performed.
#>
[CmdletBinding()]
param(
	[switch]$Interactive,
	[ValidateSet('ahk-before-native', 'native-before-ahk')]
	[string]$InstallSequence = 'ahk-before-native',
	[ValidateRange(3, 20)]
	[int]$Samples = 3,
	[string]$Runtime = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
	[string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('ergopti-group7-trace-' + [Guid]::NewGuid().ToString('N')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT
	-or !$Interactive -or ![Environment]::UserInteractive) {
	throw 'Pass -Interactive from an authorized native Windows desktop with the keyboard idle.'
}
if (!(Test-Path -LiteralPath $Runtime -PathType Leaf)) { throw 'Pinned AutoHotkey executable is missing.' }
$RuntimeVersion = (Get-Item -LiteralPath $Runtime).VersionInfo.FileVersion
if ($RuntimeVersion -cnotmatch '^2[.]0[.]26(?:[.]0)?$') { throw 'Use pinned AutoHotkey 2.0.26 x64.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a fresh output directory to retain existing evidence.' }
$Repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$WindowsRoot = Join-Path $Repository 'static/ergopti_plus/windows'
$NativeRoot = Join-Path $WindowsRoot 'native/nav_event_owner'
$Probe = Join-Path $WindowsRoot 'tests/hardware/group7_hook_trace.ahk'
$Header = Join-Path $NativeRoot 'nav_event_owner.h'
$Dll = Join-Path $WindowsRoot 'vendor/ergopti_nav_owner.dll'
$Manifest = Join-Path $WindowsRoot 'vendor/ergopti_nav_owner.manifest.json'
$Builder = Join-Path $Repository 'tools/build/build_windows_nav_owner.ps1'
$Reader = Join-Path $PSScriptRoot 'windows_group7_trace.cjs'
$NodePin = Join-Path $Repository '.node-version'
$Node = (Get-Command node -ErrorAction Stop).Source
$NodeVersion = (& $Node --version)
if ($LASTEXITCODE -ne 0 -or $NodeVersion -cne ('v' + [IO.File]::ReadAllText($NodePin).Trim())) {
	throw 'Use the repository-pinned Node runtime.'
}
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$ReceiptPath = Join-Path $OutputDirectory 'supervisor.json'
$Stdout = Join-Path $OutputDirectory 'stdout.jsonl'
$Stderr = Join-Path $OutputDirectory 'stderr.log'
$Native = $null
$Receipt = [ordered]@{
	schema_version = 1
	phase = 'prerequisites'
	mode = 'synthetic'
	requested_install_sequence = $InstallSequence
	samples_per_backend = $Samples
	fixture_codepoint = 97
	hook_order_qualified = $false
	physical_qualified = $false
	production_qualified = $false
	os_version = [Environment]::OSVersion.VersionString
	runtime_version = $RuntimeVersion
	node_version = $NodeVersion
}

function Save-TraceReceipt {
	$Json = ($Receipt | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"
	[IO.File]::WriteAllText($ReceiptPath, $Json, [Text.UTF8Encoding]::new($false))
}

function Get-TraceBindings {
	$Paths = @($PSCommandPath, $Probe, $Header, $Reader, $Builder, $Dll, $Manifest, $NodePin, $Runtime, $Node) + @(
		Get-ChildItem -LiteralPath $NativeRoot -File |
			Where-Object { $_.Extension -cin @('.c', '.h', '.def') -or $_.Name -ceq 'CMakeLists.txt' } |
			ForEach-Object { $_.FullName }
	)
	return @($Paths | Sort-Object -Unique | ForEach-Object {
		[ordered]@{ path=$_; sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
	})
}

try {
	Save-TraceReceipt
	# This gate refuses stale tracked source/recipe bindings without updating them.
	& (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -File $Builder
	if ($LASTEXITCODE -ne 0) { throw 'Official MSVC/provenance gate refused the current native trace DLL.' }
	$Bindings = Get-TraceBindings
	$Receipt.sources_before = $Bindings
	$HeaderText = [IO.File]::ReadAllText($Header)
	if ($HeaderText -notmatch '(?m)^#define[ \t]+ERGOPTI_NAV_AHK_SEND_LEVEL_BASE[ \t]+(0x[0-9A-Fa-f]+)u[ \t]*$') {
		throw 'The canonical native AHK marker declaration was not found.'
	}
	$MarkerBase = [Convert]::ToUInt64($Matches[1].Substring(2), 16)
	if ($MarkerBase -lt 31) { throw 'The canonical marker base cannot represent diagnostic SendLevel 31.' }
	$SendMarker = '0x' + ([uint64]($MarkerBase - 31)).ToString('X16')
	$Receipt.send_level = 31
	$Receipt.send_marker = $SendMarker
	$Arguments = @('/ErrorStdOut', $Probe, $Dll, $InstallSequence, [string]$Samples, $SendMarker)
	$Quoted = @($Arguments | ForEach-Object {
		if ($_ -match '["\r\n\x00]') { throw 'A trace argument contains unsupported characters.' }
		'"' + $_ + '"'
	})
	$Native = Start-Process -FilePath $Runtime -ArgumentList $Quoted -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
	$NativeHandle = $Native.Handle
	$Receipt.native_pid = $Native.Id
	$Receipt.native_started_utc = $Native.StartTime.ToUniversalTime().ToString('o')
	$Receipt.phase = 'native-active'
	Save-TraceReceipt
	if (!$Native.WaitForExit((60 + $Samples * 8) * 1000)) {
		$Receipt.phase = 'retained-live-native-owner'
		Save-TraceReceipt
		throw ('Native trace PID ' + $Native.Id + ' remains live. No kill was performed. Inspect its owned window and retry Close after resolving the retained owner.')
	}
	$Receipt.native_exit_code = $Native.ExitCode
	$Receipt.natural_native_exit = $true
	$After = Get-TraceBindings
	$Receipt.sources_after = $After
	if (($Bindings | ConvertTo-Json -Compress) -cne ($After | ConvertTo-Json -Compress)) {
		throw 'Trace sources, native DLL or executables changed during the observation.'
	}
	if ($Native.ExitCode -ne 0) { throw ('Native trace observation failed with exit code ' + $Native.ExitCode + '.') }
	if ([IO.File]::ReadAllText($Stderr).Length -ne 0) { throw 'Native trace stderr is nonempty; failed evidence is retained.' }
	& $Node $Reader $Stdout ([string]$Samples) $InstallSequence (Join-Path $OutputDirectory 'trace.json')
	if ($LASTEXITCODE -ne 0) { throw 'Strict actual callback trace verification failed; absent observations remain unqualified.' }
	$Receipt.phase = 'completed'
	$Receipt.qualification = 'synthetic-owned-receiver-callback-observations-only'
	Save-TraceReceipt
	Write-Host ('Actual synthetic callback evidence saved in ' + $OutputDirectory)
} catch {
	if ($Receipt.phase -ne 'retained-live-native-owner') { $Receipt.phase = 'failed' }
	$Receipt.failure = $_.Exception.Message
	Save-TraceReceipt
	throw
} finally {
	if ($Native -and $Native.HasExited) { $Native.Dispose() }
}
