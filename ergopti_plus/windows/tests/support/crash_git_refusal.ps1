# tests/support/crash_git_refusal.ps1

# ==============================================================================
# MODULE: Crash Worker Native Git Refusal Fixture
# DESCRIPTION:
# Runs the unchanged production worker with a child-local failing Git command.
# The command writes no stderr, so only the native exit status reports failure.
# ==============================================================================

param(
	[Parameter(Mandatory = $true)]
	[string]$MappingName,
	[int]$DelayMs = 0,
	[string]$Faults = ""
)

$ErrorActionPreference = "Stop"
$env:PATH = (Join-Path $PSScriptRoot "git_refusal") + ";" + $env:PATH
& (Join-Path $PSScriptRoot "..\..\vendor\ergopti_crash_worker.ps1") @PSBoundParameters
