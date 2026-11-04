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
	# Assigned in place: the document keeps the order the driver serialized.
	if ($Snapshot.PSObject.Properties[$Name]) {
		$Snapshot.PSObject.Properties[$Name].Value = $Value
	} else {
		$Snapshot | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
	}
}

function Test-CrashFault {
	param([string]$Name)
	return ($Faults -split ",") -contains $Name
}

# The report keeps its full detail on this machine; only the two transport
# paths, which are not report fields, are dropped. Whatever is shared later is
# redacted where it is shared (the error and diagnostics windows).
function Remove-CrashTransportFields {
	param([Parameter(Mandatory = $true)]$Snapshot)
	$Snapshot.PSObject.Properties.Remove("_transport_script_dir")
	$Snapshot.PSObject.Properties.Remove("_transport_reports_dir")
}

# The shared crash document (_shared/lua/crash_report.lua): the fields in the order
# the driver serialized them, two spaces deep, one line per field.
function ConvertTo-CrashDocument {
	param([Parameter(Mandatory = $true)]$Snapshot)
	$lines = foreach ($field in $Snapshot.PSObject.Properties) {
		"  " + (ConvertTo-Json -InputObject $field.Name -Compress) + ": " +
			(ConvertTo-Json -InputObject $field.Value -Compress -Depth 8)
	}
	return "{`n" + ($lines -join ",`n") + "`n}"
}

# Writes the document under the shared name, <timestamp>.json then <timestamp>-2.json
# for a second report within the same second. CreateNew refuses an existing file, so
# a concurrent writer can never be replaced.
function Write-CrashDocument {
	param(
		[Parameter(Mandatory = $true)][string]$Directory,
		[Parameter(Mandatory = $true)][string]$Timestamp,
		[Parameter(Mandatory = $true)][string]$Document
	)
	if ($Timestamp -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
		throw "A crash report timestamp is YYYY-MM-DDTHH:MM:SSZ, got '$Timestamp'"
	}
	$stem = $Timestamp.Replace(":", "-")
	$bytes = [Text.UTF8Encoding]::new($false).GetBytes($Document)
	$attempt = 1
	while ($true) {
		$name = if ($attempt -eq 1) { "$stem.json" } else { "$stem-$attempt.json" }
		$path = Join-Path $Directory $name
		try {
			$stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
		} catch [IO.IOException] {
			if (-not [IO.File]::Exists($path)) { throw }
			$attempt += 1
			continue
		}
		try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
		return $path
	}
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
# The crash-reports folder inside the logs folder, resolved by the driver.
$transportReportsDir = [string]$snapshot._transport_reports_dir
if ([string]::IsNullOrWhiteSpace($transportReportsDir)) {
	throw "Crash-report transport has no destination directory"
}
$enrichmentErrors = [Collections.Generic.List[string]]::new()
if ($DelayMs -gt 0) {
	Start-Sleep -Milliseconds ([Math]::Min($DelayMs, 2000))
}

try {
	if (Test-CrashFault "environment") { throw "Injected environment fault" }
	Set-CrashField $snapshot "os_version" ([Environment]::OSVersion.VersionString)
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

# A compiled build already named its commit from the BUNDLE_COMMIT stamp; a
# release has no checkout, so asking git would only replace that answer with a
# failure. Only a source run arrives without one.
if ([string]::IsNullOrWhiteSpace([string]$snapshot.git_hash)) {
	try {
		if (Test-CrashFault "git") { throw "Injected git fault" }
		$gitHash = & git -C $transportScriptDir rev-parse --short HEAD 2>$null
		if ($LASTEXITCODE -ne 0) {
			throw "Git enrichment exited with code $LASTEXITCODE."
		}
		Set-CrashField $snapshot "git_hash" ([string]$gitHash).Trim()
		Set-CrashField $snapshot "commit_source" "git"
	} catch {
		$enrichmentErrors.Add("git: " + $_.Exception.Message)
		Set-CrashField $snapshot "git_hash" "unknown"
	}
}

Set-CrashField $snapshot "enrichment_errors" $enrichmentErrors.ToArray()

$reportDir = $transportReportsDir
[IO.Directory]::CreateDirectory($reportDir) | Out-Null
Remove-CrashTransportFields $snapshot
$reportPath = Write-CrashDocument $reportDir ([string]$snapshot.timestamp) (ConvertTo-CrashDocument $snapshot)
Write-Output ("OK:" + $reportPath)
