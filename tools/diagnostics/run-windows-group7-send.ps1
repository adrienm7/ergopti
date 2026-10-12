# tools/diagnostics/run-windows-group7-send.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
Measures primitive SendEvent/SendInput receiving under the real native arbiter.
.DESCRIPTION
Runs only on an interactive Windows desktop with an idle keyboard unless the
physical capture exercise is explicitly requested. No production backend policy
is selected. Stale DLL source bindings fail the official MSVC build gate.
#>
[CmdletBinding()]
param(
	[switch]$Interactive,
	[ValidateSet('idle', 'physical')]
	[string]$Mode = 'idle',
	[ValidateSet('ahk-before-native', 'native-before-ahk')]
	[string]$InstallSequence = 'ahk-before-native',
	[ValidateRange(3, 100)]
	[int]$Samples = 5,
	[string]$Runtime = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
	[string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('ergopti-group7-' + [Guid]::NewGuid().ToString('N')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
	throw 'The native receiving measurement requires Windows; Linux and Wine cannot qualify it.'
}
if (!$Interactive -or ![Environment]::UserInteractive) {
	throw 'Pass -Interactive from an authorized foreground desktop session.'
}
if (!(Test-Path -LiteralPath $Runtime -PathType Leaf)) { throw 'Pinned AutoHotkey x64 executable is missing.' }
$RuntimeVersion = (Get-Item -LiteralPath $Runtime).VersionInfo.FileVersion
if ($RuntimeVersion -cnotmatch '^2[.]0[.]26(?:[.]0)?$') { throw 'Use pinned AutoHotkey 2.0.26 x64.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory to preserve existing evidence.' }
$Repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$WindowsRoot = Join-Path $Repository 'static/ergopti_plus/windows'
$Probe = Join-Path $WindowsRoot 'tests/hardware/group7_send_receiving.ahk'
$Dll = Join-Path $WindowsRoot 'vendor/ergopti_nav_owner.dll'
$Manifest = Join-Path $WindowsRoot 'vendor/ergopti_nav_owner.manifest.json'
$Builder = Join-Path $Repository 'tools/build/build_windows_nav_owner.ps1'
$Reader = Join-Path $PSScriptRoot 'windows_group7_receipt.cjs'
$Node = (Get-Command node -ErrorAction Stop).Source
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$ReceiptPath = Join-Path $OutputDirectory 'supervisor.json'
$Stdout = Join-Path $OutputDirectory 'stdout.csv'
$Stderr = Join-Path $OutputDirectory 'stderr.log'
$Native = $null
$Receipt = [ordered]@{
	schema_version = 1
	phase = 'prerequisites'
	mode = $Mode
	requested_install_sequence = $InstallSequence
	samples_per_case = $Samples
	qualification = 'unrun'
	physical_hook_order_qualified = $false
	simultaneous_physical_typing_qualified = $false
	production_qualified = $false
	production_backend_policy_changed = $false
	os_version = [Environment]::OSVersion.VersionString
}

function Save-Receipt {
	$Json = ($Receipt | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"
	[IO.File]::WriteAllText($ReceiptPath, $Json, [Text.UTF8Encoding]::new($false))
}

function Get-SourceBindings {
	$Paths = @($PSCommandPath, $Probe, $Reader, $Builder, $Dll, $Manifest) + @(
		Get-ChildItem -LiteralPath (Join-Path $WindowsRoot 'native/nav_event_owner') -File |
			Where-Object { $_.Extension -cin @('.c', '.h', '.def') -or $_.Name -ceq 'CMakeLists.txt' } |
			ForEach-Object { $_.FullName }
	)
	return @($Paths | Sort-Object -Unique | ForEach-Object {
		[ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
	})
}

try {
	Save-Receipt
	# The default builder validates provenance and never updates tracked output.
	# After a source correction, the operator must explicitly run -UpdateTracked.
	& (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -File $Builder
	if ($LASTEXITCODE -ne 0) { throw 'Official MSVC/provenance gate refused the current native DLL.' }
	$Bindings = Get-SourceBindings
	$Receipt.sources_before = $Bindings
	$Receipt.runtime_sha256 = (Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash
	$Receipt.runtime_version = $RuntimeVersion
	$Receipt.node_version = (& $Node --version)
	if ($LASTEXITCODE -ne 0) { throw 'Node version query failed.' }
	$PinnedNode = 'v' + [IO.File]::ReadAllText((Join-Path $Repository '.node-version')).Trim()
	if ($Receipt.node_version -cne $PinnedNode) { throw ('Use repository-pinned Node ' + $PinnedNode + '.') }
	$Arguments = @('/ErrorStdOut', $Probe, $Dll, $InstallSequence, $Mode, [string]$Samples)
	$Quoted = @($Arguments | ForEach-Object {
		if ($_ -match '["\r\n\x00]') { throw 'A measurement argument contains unsupported characters.' }
		'"' + $_ + '"'
	})
	$Native = Start-Process -FilePath $Runtime -ArgumentList $Quoted -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
	$NativeHandle = $Native.Handle
	$Receipt.native_pid = $Native.Id
	$Receipt.native_started_utc = $Native.StartTime.ToUniversalTime().ToString('o')
	$Receipt.phase = 'native-active'
	Save-Receipt
	# Physical runs reserve three seconds per sample plus emission/settling time.
	$TimeoutMilliseconds = (60 + $Samples * 6 * 8) * 1000
	if (!$Native.WaitForExit($TimeoutMilliseconds)) {
		$Receipt.phase = 'retained-live-native-debt'
		Save-Receipt
		throw ('Native process remains live with PID ' + $Native.Id + '. No timeout kill was performed. Inspect its owned window and release keys before retrying Exit.')
	}
	$Receipt.native_exit_code = $Native.ExitCode
	$Receipt.natural_native_exit = $true
	if ($Native.ExitCode -ne 0) { throw ('Native observation failed with exit code ' + $Native.ExitCode + '.') }
	if ([IO.File]::ReadAllText($Stderr).Length -ne 0) { throw 'Native stderr is nonempty; inspect the retained log.' }
	$After = Get-SourceBindings
	$Receipt.sources_after = $After
	if (($Bindings | ConvertTo-Json -Compress) -cne ($After | ConvertTo-Json -Compress)) {
		throw 'Measurement sources or DLL changed during native execution.'
	}
	& $Node $Reader $Stdout ([string]$Samples) $Mode $InstallSequence (Join-Path $OutputDirectory 'measurement.json')
	if ($LASTEXITCODE -ne 0) { throw 'Strict complete receiving protocol verification failed.' }
	$Receipt.phase = 'completed'
	$Receipt.qualification = 'native-owned-edit-primitives-only'
	Save-Receipt
	Write-Host ('Exact receiving and latency samples saved in ' + $OutputDirectory)
} catch {
	if ($Receipt.phase -ne 'retained-live-native-debt') { $Receipt.phase = 'failed' }
	$Receipt.failure = $_.Exception.Message
	Save-Receipt
	throw
} finally {
	# Keep every live process/module owner after refusal; never erase replay debt.
	if ($Native -and $Native.HasExited) { $Native.Dispose() }
}
