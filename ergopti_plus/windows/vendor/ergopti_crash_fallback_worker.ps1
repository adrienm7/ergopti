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
$artifactPath = Join-Path $reportsDir ((Get-Date -Format "yyyy-MM-ddTHH-mm-ss") + "_" + [guid]::NewGuid().ToString("N") + ".json")
[IO.File]::WriteAllText($artifactPath, ($snapshot | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output ("OK:" + $artifactPath)
