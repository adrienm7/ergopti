# tools/test/test_crash_worker_partial_write.ps1
# Receive the real crash writers of both workers and prove that a refused write
# never leaves a truncated report under a canonical <timestamp>.json name.
param(
	[Parameter(Mandatory = $true)][string]$WorkerSourcePath,
	[Parameter(Mandatory = $true)][string]$Directory,
	[ValidateSet('Publication', 'FileSizeLimit')][string]$Mode = 'Publication'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($WorkerSourcePath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -ne 0) { throw 'The actual crash worker source must parse.' }
foreach ($Name in @('Write-CrashStagingFile', 'Write-CrashDocument')) {
	$Definitions = @($Ast.FindAll({ param($Node)
		$Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $Name
	}, $true))
	if ($Definitions.Count -ne 1) { throw "The actual crash worker must define $Name once." }
	. ([scriptblock]::Create($Definitions[0].Extent.Text))
}
$Stamp = '2026-11-05T10:20:30Z'
$Stem = '2026-11-05T10-20-30Z'
function Get-Entries { @(Get-ChildItem -LiteralPath $Directory -Force | ForEach-Object { $_.Name } | Sort-Object) }
$Large = '{"pad":"' + ('x' * 16384) + '"}'

if ($Mode -ceq 'FileSizeLimit') {
	# The caller runs this mode under a per-process file-size limit with SIGXFSZ
	# ignored: the staging write is genuinely refused part-way by the kernel.
	$Failure = $null
	try { Write-CrashDocument -Directory $Directory -Timestamp $Stamp -Document $Large | Out-Null } catch { $Failure = $_ }
	if ($null -eq $Failure) { throw 'A write refused by the file-size limit must throw.' }
	$Left = @(Get-Entries)
	if ($Left.Count -ne 0) { throw ('A refused write must leave no file, found: ' + ($Left -join ',')) }
	Write-Output 'PASS: kernel-refused crash write left no partial file'
	exit 0
}

$First = Write-CrashDocument -Directory $Directory -Timestamp $Stamp -Document '{"n":1}'
if ((Split-Path -Leaf $First) -cne "$Stem.json") { throw "The first report must use the canonical name, got $First" }
$Second = Write-CrashDocument -Directory $Directory -Timestamp $Stamp -Document '{"n":2}'
if ((Split-Path -Leaf $Second) -cne "$Stem-2.json") { throw "A same-second report must take the next suffix, got $Second" }
if ([IO.File]::ReadAllText($First) -cne '{"n":1}') { throw 'A later report must never replace an earlier one.' }

# A staging refusal after partial bytes reached disk must publish nothing.
${function:Write-CrashStagingFile} = {
	param([string]$Path, [byte[]]$Bytes)
	[IO.File]::WriteAllBytes($Path, $Bytes[0..9])
	[IO.File]::Delete($Path)
	throw [IO.IOException]::new('Injected staging write refusal.')
}
$Failure = $null
try { Write-CrashDocument -Directory $Directory -Timestamp $Stamp -Document $Large | Out-Null } catch { $Failure = $_ }
if ($null -eq $Failure -or $Failure.Exception.Message -cne 'Injected staging write refusal.') {
	throw 'A refused staging write must propagate its exact failure.'
}
$Expected = @("$Stem-2.json", "$Stem.json")
$Left = Get-Entries
if (($Left -join '|') -cne ($Expected -join '|')) { throw ('A refused write must add no report, found: ' + ($Left -join ',')) }
foreach ($Path in @($First, $Second)) {
	$null = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}
Write-Output 'PASS: crash writer publishes only complete reports'
