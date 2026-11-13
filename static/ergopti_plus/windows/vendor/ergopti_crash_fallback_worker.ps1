# vendor/ergopti_crash_fallback_worker.ps1

# ==============================================================================
# MODULE: Ergopti Crash Report Minimal Writer
# DESCRIPTION:
# Isolated fallback of ergopti_crash_worker.ps1. When the enrichment worker
# cannot start, fails or misses its deadline, this writer reads the same
# length-prefixed UTF-8 snapshot from the named mapping and writes it as the
# crash artifact without any enrichment, so a crash still leaves its report.
# It prints OK:<artifact path> on success.
# ==============================================================================

param(
	[Parameter(Mandatory = $true)]
	[string]$MappingName,
	[Parameter(Mandatory = $true)]
	[int]$MaxPayloadBytes,
	[switch]$DeadlineExpired
)

$ErrorActionPreference = "Stop"

# The shared crash document (_shared/diagnostics/engine/reports/crash_report.lua): the fields in the order
# the driver serialized them, two spaces deep, one line per field.
function ConvertTo-CrashDocument {
	param([Parameter(Mandatory = $true)]$Snapshot)
	$lines = foreach ($field in $Snapshot.PSObject.Properties) {
		"  " + (ConvertTo-Json -InputObject $field.Name -Compress) + ": " +
			(ConvertTo-Json -InputObject $field.Value -Compress -Depth 8)
	}
	return "{`n" + ($lines -join ",`n") + "`n}"
}

# Writes the complete document to a fresh hidden staging file this call created.
# A write or close refusal deletes only that exclusively created staging file and
# rethrows, so no truncated report ever carries a canonical .json name.
function Write-CrashStagingFile {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][byte[]]$Bytes
	)
	$stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
	try {
		try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
	} catch {
		[IO.File]::Delete($Path)
		throw
	}
}

# Writes the document under the shared name, <timestamp>.json then <timestamp>-2.json
# for a second report within the same second. The bytes are staged first and only a
# complete file is published; File.Move never replaces an existing destination, so a
# concurrent writer can never be replaced either.
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
	$staging = Join-Path $Directory (".$stem." + [Guid]::NewGuid().ToString("N") + ".partial")
	Write-CrashStagingFile -Path $staging -Bytes $bytes
	try {
		$attempt = 1
		while ($true) {
			$name = if ($attempt -eq 1) { "$stem.json" } else { "$stem-$attempt.json" }
			$path = Join-Path $Directory $name
			try {
				[IO.File]::Move($staging, $path)
			} catch [IO.IOException] {
				if (-not [IO.File]::Exists($path)) { throw }
				$attempt += 1
				continue
			}
			return $path
		}
	} catch {
		[IO.File]::Delete($staging)
		throw
	}
}

$mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
	$MappingName,
	[IO.MemoryMappedFiles.MemoryMappedFileRights]::Read
)
$view = $mapping.CreateViewAccessor(0, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
$payloadLength = $view.ReadInt32(0)
if ($payloadLength -lt 1 -or $payloadLength -gt $MaxPayloadBytes) { throw "invalid payload length" }
$payloadBytes = New-Object byte[] $payloadLength
$null = $view.ReadArray(4, $payloadBytes, 0, $payloadLength)
$view.Dispose()
$mapping.Dispose()

$snapshot = [Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json
if ($DeadlineExpired) {
	$snapshot | Add-Member -NotePropertyName enrichment_errors -NotePropertyValue @("primary worker deadline exceeded") -Force
}
$reportsDir = [string]$snapshot._transport_reports_dir
if ([string]::IsNullOrWhiteSpace($reportsDir)) { throw "no crash reports folder" }
[IO.Directory]::CreateDirectory($reportsDir) | Out-Null
$snapshot.PSObject.Properties.Remove("_transport_script_dir")
$snapshot.PSObject.Properties.Remove("_transport_reports_dir")
$artifactPath = Write-CrashDocument $reportsDir ([string]$snapshot.timestamp) (ConvertTo-CrashDocument $snapshot)
# This receipt contains a native Unicode path. Its explicit byte preamble lets
# the parent's FileRead detect UTF-8 regardless of console/ANSI code pages.
$ReceiptEncoding = [Text.UTF8Encoding]::new($true)
[byte[]]$ReceiptBytes = $ReceiptEncoding.GetPreamble() +
	$ReceiptEncoding.GetBytes("OK:" + $artifactPath + [Environment]::NewLine)
$ReceiptOutput = [Console]::OpenStandardOutput()
try {
	$ReceiptOutput.Write($ReceiptBytes, 0, $ReceiptBytes.Length)
	$ReceiptOutput.Flush()
} finally { $ReceiptOutput.Dispose() }
