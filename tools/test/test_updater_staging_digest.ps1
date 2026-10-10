# tools/test/test_updater_staging_digest.ps1
# Actual generated digest/integrity controls: owned bytes, no transport or trust.
param([string]$WorkerSourcePath, [string]$OwnedFilePath)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5 is required.' }
$Source = [IO.File]::ReadAllText($WorkerSourcePath)
$Start = $Source.IndexOf('_Updater_BuildStagingWorkerScript() {', [StringComparison]::Ordinal)
if ($Start -lt 0) { throw 'Actual staging generator is required.' }
$Body = $Source.Substring($Start).Split([string[]]@("`n}"), [StringSplitOptions]::None)[0]
$Parts = [regex]::Matches($Body, "(?:return |\. )'([^']*)'")
if ($Parts.Count -ne 36) { throw 'The actual staging expression changed.' }
$Worker = (@($Parts | ForEach-Object { $_.Groups[1].Value }) -join "`n") + "`n"
$From = $Worker.IndexOf('  if ($ExpectedSha256 -cnotmatch ', [StringComparison]::Ordinal)
$To = $Worker.IndexOf('  $SwapSource=', [StringComparison]::Ordinal)
if ($From -lt 0 -or $To -le $From) { throw 'Actual digest and comparison must be present.' }
$DigestSource = $Worker.Substring($From, $To - $From)
$Digest = [ScriptBlock]::Create($DigestSource)
$NewExe = $OwnedFilePath
$ExpectedSha256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
$StartedTick = [long]101
$DeadlineMs = [int]5000
$script:BudgetCalls = 0
function Get-ErgoptiUpdaterRemainingMilliseconds($Started, $Budget, $ObservedState) {
    if ($Started -ne 101 -or $Budget -ne 5000 -or $ObservedState.Stage -cne 'file_read') {
        throw 'The original budget arguments must be forwarded unchanged.'
    }
    $script:BudgetCalls++
    return 4999
}
function Assert-ExactFileReleased {
    $Exclusive = [IO.File]::Open($NewExe, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { if ($Exclusive.Length -ne 3) { throw 'The exact owned bytes must remain.' } }
    finally { $Exclusive.Dispose() }
}
function Assert-VerificationRefusal($ExpectedMessage) {
    $Caught = $null
    try { . $Digest }
    catch { $Caught = $_ }
    if ($null -eq $Caught -or $Caught.Exception.Message -cne $ExpectedMessage -or $State.Reason -cne 'verify') {
        throw 'The original integrity refusal must remain exact.'
    }
    Assert-ExactFileReleased
}
if ([IO.File]::Exists($NewExe)) { throw 'The controlled byte file must be fresh.' }
[IO.File]::WriteAllBytes($NewExe, [byte[]](97, 98, 99))
# The digest must work without lazy loading Microsoft.PowerShell.Utility.
$global:PSModuleAutoLoadingPreference = 'None'
$Utility = Get-Module Microsoft.PowerShell.Utility
if ($null -ne $Utility) { Remove-Module Microsoft.PowerShell.Utility -ErrorAction Stop }
if ($null -ne $ExecutionContext.InvokeCommand.GetCommand('Get-FileHash', [Management.Automation.CommandTypes]::Cmdlet)) {
    throw 'The unavailable-command premise must be genuine.'
}
# 1. Real generated code computes the independently known SHA-256 of abc.
$State = @{ Stage = 'file_read'; Reason = 'download' }
$ActualDigest = $null
$Result = @(. $Digest)
if ($Result.Count -ne 0 -or $ActualDigest -isnot [string] -or $ActualDigest -cne $ExpectedSha256 -or $script:BudgetCalls -ne 1) {
    throw 'Actual generated digest must match independent abc bytes without extra output.'
}
Assert-ExactFileReleased
# 2. Real tampered bytes cannot publish the old expected digest.
[IO.File]::WriteAllBytes($NewExe, [byte[]](97, 98, 100))
$State = @{ Stage = 'file_read'; Reason = 'download' }
Assert-VerificationRefusal 'SHA-256 digest mismatch'
# 3. A wrong but correctly shaped expected digest remains refused.
[IO.File]::WriteAllBytes($NewExe, [byte[]](97, 98, 99))
$ExpectedSha256 = '0' * 64
$State = @{ Stage = 'file_read'; Reason = 'download' }
Assert-VerificationRefusal 'SHA-256 digest mismatch'
# 4. Missing or malformed trusted digests preserve the existing refusal.
$ExpectedSha256 = 'BAD'
$State = @{ Stage = 'file_read'; Reason = 'download' }
Assert-VerificationRefusal 'Missing or invalid trusted SHA-256 digest'
# 5. A real open refusal retains the original stage and cannot produce a digest.
$ExpectedSha256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
$State = @{ Stage = 'file_read'; Reason = 'download' }
$Lock = [IO.File]::Open($NewExe, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$Caught = $null
try { try { . $Digest } catch { $Caught = $_ } }
finally { $Lock.Dispose() }
if ($null -eq $Caught -or $State.Stage -cne 'file_read' -or $State.Reason -cne 'download') {
    throw 'The real locked-file digest must refuse without changing classification.'
}
Assert-ExactFileReleased
# 6. Source-linked disposal guards cannot disappear behind process-exit cleanup.
if ($DigestSource -notmatch '\$HashStream\.Dispose\(\)' -or $DigestSource -notmatch '\$Hasher\.Dispose\(\)') {
    throw 'Both real digest resources require unconditional disposal.'
}
[Console]::WriteLine('PASS: actual staging digest checks=6 network=0 certificate=0')
