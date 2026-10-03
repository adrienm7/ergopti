# tools/test/fixtures/test_source_boot_ownership.ps1

# Exercise the observer's actual admission helpers without terminating processes.
param([Parameter(Mandatory)][string] $Observer)
$ErrorActionPreference = 'Stop'
. $Observer -Entry 'unused' -Ahk 'unused' -Root 'unused' -Nonce 'unused' -LibraryOnly
$entry = 'C:\private clone\ErgoptiPlus.ahk'
foreach ($command in @(
    ('"C:\AutoHotkey64.exe" /ErrorStdOut "' + $entry + '"'),
    ('"C:\AutoHotkey64.exe" /restart /script "' + $entry + '"')
)) {
    if (![SourceBootProcess]::HasExactEntry($command, $entry)) {
        throw 'An exact script argument was refused.'
    }
}
foreach ($command in @(
    ('"C:\AutoHotkey64.exe" "other.ahk" "' + $entry + '"'),
    ('"C:\AutoHotkey64.exe" /unknown "' + $entry + '"'),
    ('"C:\AutoHotkey64.exe" "' + $entry + '.other"')
)) {
    if ([SourceBootProcess]::HasExactEntry($command, $entry)) {
        throw 'A data argument or another script granted cleanup authority.'
    }
}
foreach ($mode in @('mismatch', 'query-failure', 'accepted')) {
    $observed = @{ closed = 0; queried = 0; mode = $mode }
    $successor = [IntPtr]::Zero
    $caught = $false
    try {
        $successor = Get-AdmittedSourceHandle -ProcessId 123 -CreationFileTime 0 -Interpreter 'unused' `
            -Open { [IntPtr]123 } -Matches {
                $observed.queried++
                if ($observed.mode -eq 'query-failure') { throw 'Native identity query failed.' }
                return $observed.mode -eq 'accepted'
            } -Close { $observed.closed++ }
    } catch {
        $caught = $true
        $expected = if ($mode -eq 'query-failure') { 'Native identity query failed.' } else { 'changed ownership' }
        if (!$_.Exception.Message.Contains($expected)) { throw }
    }
    if ($observed.queried -ne 1) { throw 'Admission did not query the candidate identity.' }
    if ($mode -eq 'accepted') {
        if ($caught -or $successor -eq [IntPtr]::Zero -or $observed.closed -ne 0) {
            throw 'A proven handle was not transferred to its owner.'
        }
    } elseif (!$caught -or $successor -ne [IntPtr]::Zero -or $observed.closed -ne 1) {
        throw 'An unproven handle escaped into termination cleanup.'
    }
}
Write-Output '[OK] Source observer admits only the exact script and proven process generation.'
