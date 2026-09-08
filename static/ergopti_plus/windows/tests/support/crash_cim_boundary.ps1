# tests/support/crash_cim_boundary.ps1

# ==============================================================================
# MODULE: Crash Worker CIM Boundary Fixture
# DESCRIPTION:
# Keeps real worker transport and enrichment control flow while controlling only
# the external CIM query boundary in the disposable child process.
# ==============================================================================

param(
	[Parameter(Mandatory = $true)]
	[string]$MappingName,
	[int]$DelayMs = 0,
	[string]$Faults = ""
)

$ErrorActionPreference = "Stop"

function Get-CimInstance {
	param([Parameter(Mandatory = $true, Position = 0)][string]$ClassName)
	switch ($ClassName) {
		"Win32_OperatingSystem" {
			return [pscustomobject]@{
				BuildNumber = "99001"
				TotalVisibleMemorySize = 32 * 1MB
				FreePhysicalMemory = 12 * 1MB
			}
		}
		"Win32_Processor" {
			return [pscustomobject]@{
				Name = "CIM_SENTINEL_CPU"
				NumberOfLogicalProcessors = 16
			}
		}
		default { throw "Unexpected CIM class in crash fixture: $ClassName" }
	}
}

& (Join-Path $PSScriptRoot "..\..\vendor\ergopti_crash_worker.ps1") @PSBoundParameters
