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
$interpreter = 'C:\private interpreter\AutoHotkey64.exe'
$privateEntry = 'C:\private source secret\ErgoptiPlus.ahk'
$exactCommand = '"' + $interpreter + '" /restart /script "' + $privateEntry + '"'
foreach ($case in @(
    @{ native = $null; expected = @($false, $false, $false, $false, $false) },
    @{ native = @{ ExecutablePath = $null; CommandLine = $exactCommand };
        expected = @($true, $false, $false, $true, $true) },
    @{ native = @{ ExecutablePath = 'C:\foreign.exe'; CommandLine = $exactCommand };
        expected = @($true, $true, $false, $true, $true) },
    @{ native = @{ ExecutablePath = $interpreter; CommandLine = $null };
        expected = @($true, $true, $true, $false, $false) },
    @{ native = @{ ExecutablePath = $interpreter; CommandLine = '' };
        expected = @($true, $true, $true, $false, $false) },
    @{ native = @{ ExecutablePath = $interpreter;
        CommandLine = '"' + $interpreter + '" "other.ahk" "' + $privateEntry + '"' };
        expected = @($true, $true, $true, $true, $false) },
    @{ native = @{ ExecutablePath = $interpreter;
        CommandLine = '"' + $interpreter + '" /unknown "' + $privateEntry + '"' };
        expected = @($true, $true, $true, $true, $false) },
    @{ native = @{ ExecutablePath = $interpreter;
        CommandLine = '"' + $interpreter + '" "' + $privateEntry + '.other"' };
        expected = @($true, $true, $true, $true, $false) },
    @{ native = @{ ExecutablePath = $interpreter; CommandLine = $exactCommand };
        expected = @($true, $true, $true, $true, $true) }
)) {
    $evidence = Get-SourceOwnerEvidence -Native $case.native -Interpreter $interpreter -Entry $privateEntry
    $keys = @('schema_version', 'native_present', 'image_present', 'image_exact',
        'command_present', 'script_argument_exact')
    if (@($evidence.Keys).Count -ne $keys.Count -or $evidence.schema_version -ne 1) {
        throw 'Source-owner evidence has an unexpected shape.'
    }
    for ($index = 1; $index -lt $keys.Count; $index++) {
        if ($evidence[$keys[$index]] -isnot [bool] -or
            $evidence[$keys[$index]] -ne $case.expected[$index - 1]) {
            throw ('Source-owner evidence disagrees at closed predicate ' + $keys[$index] + '.')
        }
    }
    $serialized = $evidence | ConvertTo-Json -Compress
    if ($serialized.Length -gt 200 -or $serialized.Contains('private') -or
        $serialized.Contains('foreign') -or $serialized.Contains('.ahk') -or $serialized.Contains('.exe')) {
        throw 'Source-owner evidence exposed private process metadata.'
    }
}
Write-Output '[OK] Source observer admits only the exact script and proven process generation; refusal evidence remains closed.'
