# tools/test/test_updater_staging_observation.ps1
param([string]$OriginalScriptPath, [string]$HelperPath, [string]$OwnedDirectory,
    [string]$WorkerSourcePath = '')
$ErrorActionPreference = 'Stop'
. $HelperPath
if ($WorkerSourcePath -ne '') {
    $WorkerText = [IO.File]::ReadAllText($WorkerSourcePath)
    $Start = $WorkerText.IndexOf('_Updater_BuildStagingWorkerScript() {', [StringComparison]::Ordinal)
    if ($Start -lt 0) { throw 'Actual staging generator is required.' }
    $Body = $WorkerText.Substring($Start).Split([string[]]@("`n}"), [StringSplitOptions]::None)[0]
    $Parts = [regex]::Matches($Body, "(?:return |\. )'([^']*)'")
    if ($Parts.Count -ne 35) { throw 'Actual staging expression changed.' }
    $Source = (@($Parts | ForEach-Object { $_.Groups[1].Value }) -join "`n") + "`n"
} else { $Source = [IO.File]::ReadAllText($OriginalScriptPath) }
$Observed = New-ErgoptiObservedStagingScript $Source ''
$Reversed = $Observed.Source
foreach ($Seam in @($Observed.Seams)[($Observed.Seams.Count - 1)..0]) {
    $Reversed = $Reversed.Replace($Seam.after, $Seam.before)
}
if ($Reversed -cne $Source) { throw 'Whole original staging source must reverse exactly.' }
$ArrayFact = Get-ErgoptiStagingScalarFact @('PRIVATE_ONE', 'PRIVATE_TWO')
if ($ArrayFact.type -cne 'array' -or $ArrayFact.arity -ne 2 -or $ArrayFact.ContainsKey('size')) { throw 'Array is not scalar size.' }
$Path = Join-Path $OwnedDirectory 'pure-fact.json'
if ([IO.File]::Exists($Path)) { throw 'The observation control namespace must be fresh.' }
Write-ErgoptiStagingDiagnostic $Path 'content_length' ([long]524289) ([long]524288) ([InvalidOperationException]::new('PRIVATE_NONCE_OR_PATH')) 'file_read'
$Text = [IO.File]::ReadAllText($Path)
if ($Text.Length -gt 2048 -or $Text.Contains('PRIVATE')) { throw 'Fact must be bounded and private-content-free.' }
$Fact = $Text | ConvertFrom-Json
if ($Fact.operation -cne 'content_length' -or $Fact.expected.size -ne 524289 -or $Fact.actual.size -ne 524288) { throw 'Actual observation must preserve numeric facts.' }
Write-ErgoptiStagingDiagnostic $Path 'metadata' $null $null ([Exception]::new('PRIVATE')) 'file_read'
if ([IO.File]::ReadAllText($Path) -cne $Text -or $script:StagingDiagnosticHealth -cne 'unavailable') { throw 'Duplicate capture refuses without overwrite.' }
Write-Output 'PASS: staging observation checks=5 native_watch=0 network=0 certificate=0'
