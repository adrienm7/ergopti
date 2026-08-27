# vendor/ergopti_crash_worker.ps1

# ==============================================================================
# MODULE: Ergopti Crash Report Worker
# DESCRIPTION:
# Reads one bounded JSON snapshot from a pagefile-backed named mapping, enriches
# independent system fields without making the whole report contingent on CIM,
# and writes the canonical crash artifact outside the AutoHotkey interpreter.
# ==============================================================================

param(
	[Parameter(Mandatory = $true)]
	[string]$MappingName,
	[int]$DelayMs = 0,
	[string]$Faults = ""
)

$ErrorActionPreference = "Stop"
$MaxPayloadBytes = 1048576

function Set-CrashField {
	param(
		[Parameter(Mandatory = $true)]$Snapshot,
		[Parameter(Mandatory = $true)][string]$Name,
		[AllowNull()]$Value
	)
	$Snapshot | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Test-CrashFault {
	param([string]$Name)
	return ($Faults -split ",") -contains $Name
}

function Protect-CrashReportPrivacy {
	param([Parameter(Mandatory = $true)]$Snapshot)
	$redactions = @{
		error_msg = "[redacted error message]"
		error_extra = "[redacted error context]"
		error_what = "[redacted error context]"
		error_file = "[redacted source path]"
		stack_trace = "[redacted stack]"
		script_dir = "[redacted path]"
		active_window_title = "[redacted window title]"
		active_window_process = "[redacted process]"
		config_dir = "[redacted path]"
		log_tail = "[redacted log]"
	}
	foreach ($name in $redactions.Keys) {
		$property = $Snapshot.PSObject.Properties[$name]
		if ($null -ne $property -and [string]$property.Value -ne "") {
			Set-CrashField $Snapshot $name $redactions[$name]
		}
	}
	$Snapshot.PSObject.Properties.Remove("_transport_script_dir")
	$Snapshot.PSObject.Properties.Remove("_transport_config_dir")
}

$mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
	$MappingName,
	[IO.MemoryMappedFiles.MemoryMappedFileRights]::Read
)
$view = $mapping.CreateViewAccessor(
	0,
	0,
	[IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read
)
try {
	$payloadLength = $view.ReadInt32(0)
	if ($payloadLength -lt 1 -or $payloadLength -gt $MaxPayloadBytes) {
		throw "Invalid crash payload length: $payloadLength"
	}
	$payloadBytes = New-Object byte[] $payloadLength
	$readCount = $view.ReadArray(4, $payloadBytes, 0, $payloadLength)
	if ($readCount -ne $payloadLength) {
		throw "Crash payload was truncated: $readCount/$payloadLength"
	}
} finally {
	$view.Dispose()
	$mapping.Dispose()
}

$snapshot = [Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
$transportScriptDir = [string]$snapshot._transport_script_dir
$transportConfigDir = [string]$snapshot._transport_config_dir
if ([string]::IsNullOrWhiteSpace($transportConfigDir)) {
	throw "Crash-report transport has no destination directory"
}
$enrichmentErrors = [Collections.Generic.List[string]]::new()
if ($DelayMs -gt 0) {
	Start-Sleep -Milliseconds ([Math]::Min($DelayMs, 2000))
}

try {
	if (Test-CrashFault "environment") { throw "Injected environment fault" }
	Set-CrashField $snapshot "os_name" ([Environment]::OSVersion.VersionString)
} catch { $enrichmentErrors.Add("environment: " + $_.Exception.Message) }

try {
	if (Test-CrashFault "architecture") { throw "Injected architecture fault" }
	Set-CrashField $snapshot "os_arch" $env:PROCESSOR_ARCHITECTURE
} catch { $enrichmentErrors.Add("architecture: " + $_.Exception.Message) }

try {
	if (Test-CrashFault "locale") { throw "Injected locale fault" }
	Set-CrashField $snapshot "locale" ([Globalization.CultureInfo]::CurrentCulture.Name)
} catch { $enrichmentErrors.Add("locale: " + $_.Exception.Message) }

$operatingSystem = $null
try {
	if (Test-CrashFault "os") { throw "Injected operating-system CIM fault" }
	$operatingSystem = Get-CimInstance Win32_OperatingSystem
	Set-CrashField $snapshot "os_build" ([string]$operatingSystem.BuildNumber)
	Set-CrashField $snapshot "ram_total_gb" ([string][math]::Round($operatingSystem.TotalVisibleMemorySize / 1MB, 2))
	Set-CrashField $snapshot "ram_free_gb" ([string][math]::Round($operatingSystem.FreePhysicalMemory / 1MB, 2))
} catch { $enrichmentErrors.Add("os: " + $_.Exception.Message) }

try {
	if (Test-CrashFault "cpu") { throw "Injected processor CIM fault" }
	$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
	Set-CrashField $snapshot "cpu_name" ([string]$processor.Name)
	Set-CrashField $snapshot "cpu_cores" ([string]$processor.NumberOfLogicalProcessors)
} catch { $enrichmentErrors.Add("cpu: " + $_.Exception.Message) }

try {
	if (Test-CrashFault "git") { throw "Injected git fault" }
	$gitHash = & git -C $transportScriptDir rev-parse --short HEAD 2>$null
	if ($LASTEXITCODE -eq 0) {
		Set-CrashField $snapshot "git_hash" ([string]$gitHash).Trim()
	}
} catch { $enrichmentErrors.Add("git: " + $_.Exception.Message) }

Set-CrashField $snapshot "enrichment_errors" $enrichmentErrors.ToArray()

$reportDir = Join-Path $transportConfigDir "autohotkey\crash_reports"
[IO.Directory]::CreateDirectory($reportDir) | Out-Null
$reportName = "{0}_{1}.json" -f (Get-Date -Format "yyyy-MM-ddTHH-mm-ss"), [guid]::NewGuid().ToString("N")
$reportPath = Join-Path $reportDir $reportName
Protect-CrashReportPrivacy $snapshot
[IO.File]::WriteAllText(
	$reportPath,
	($snapshot | ConvertTo-Json -Depth 8),
	[Text.UTF8Encoding]::new($false)
)
Write-Output ("OK:" + $reportPath)
