# tests/fixtures/updater_staged_custody.ps1
# Real child-side stream custody controls over parent-retained native files.
param([string]$Module, [string]$Path, [string]$ExpectedIdentity,
    [string]$ExpectedDirectoryIdentity, [string]$Mode)
$ErrorActionPreference = 'Stop'
. $Module
$DirectoryLease = $null
$Output = $null
try {
    $DirectoryLease = [ErgoptiUpdaterMonotonicClock]::OpenStagingDirectory([IO.Path]::GetDirectoryName($Path))
    if ([ErgoptiUpdaterMonotonicClock]::StagingIdentity($DirectoryLease, $true) -cne $ExpectedDirectoryIdentity) {
        throw 'The child must observe the actual parent-retained directory identity.'
    }
    $Caught = $null
    try { $Output = Open-ErgoptiParentStagedOutput $Path $ExpectedIdentity }
    catch { $Caught = $_ }
    if ($Mode -ceq 'accept') {
        if ($null -ne $Caught -or $null -eq $Output) { throw 'Exact empty parent-owned output must be admitted.' }
        Assert-ErgoptiOwnedArtifactOutputCurrent $Output
        $Bytes = [Text.Encoding]::UTF8.GetBytes('abc')
        $Output.stream.Write($Bytes, 0, $Bytes.Length)
        $Output.stream.Flush($true)
        Assert-ErgoptiOwnedArtifactOutputCurrent $Output
        $Output.stream.Dispose()
        $Output = $null
        if ([IO.File]::ReadAllText($Path) -cne 'abc') { throw 'The actual retained file must receive the exact child bytes.' }
    } elseif ($Mode -in @('nonempty', 'foreign')) {
        if ($null -eq $Caught -or $null -ne $Output -or
            $Caught.Exception.Message -cne 'Parent staged file identity or initial bytes were refused.') {
            throw 'Foreign or nonempty output must be refused before any byte is overwritten.'
        }
        $ExpectedBytes = if ($Mode -ceq 'nonempty') { 'abc' } else { '' }
        if ([IO.File]::ReadAllText($Path) -cne $ExpectedBytes) { throw 'Refusal must preserve independently known bytes.' }
        $Exclusive = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $Exclusive.Dispose()
    } else { throw 'Unknown custody control.' }
    [Console]::WriteLine('PASS: real staged native custody ' + $Mode)
} finally {
    if ($null -ne $Output) { $Output.stream.Dispose() }
    if ($null -ne $DirectoryLease) { $DirectoryLease.Dispose() }
}
