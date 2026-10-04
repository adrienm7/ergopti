# tools/test/fixtures/test_source_boot_ownership.ps1

# Exercise the observer's actual admission helpers without terminating processes.
param(
    [Parameter(Mandatory)][string] $Observer,
    [Parameter(Mandatory)][string] $Ahk,
    [Parameter(Mandatory)][string] $Root
)
$ErrorActionPreference = 'Stop'
# Dot-source parameter binding shares this scope; keep the actual native inputs.
$fixtureAhk = $Ahk
$fixtureRoot = $Root
. $Observer -Entry 'unused' -Ahk $fixtureAhk -Root $fixtureRoot -Nonce 'unused' -LibraryOnly
if ($Ahk -cne $fixtureAhk -or $Root -cne $fixtureRoot) {
    throw 'The library import changed the native Reload fixture inputs.'
}
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
# Exercise the real AHK Reload filename, rather than a synthesized command line.
$controlRoot = Join-Path $Root 'native-reload-path'
[void][IO.Directory]::CreateDirectory($controlRoot)
$sourceRoot = Join-Path $controlRoot 'owned source'
[void][IO.Directory]::CreateDirectory($sourceRoot)
$controlEntry = Join-Path $sourceRoot 'reload owner.ahk'
$controlScript = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
ProbeStart := A_TickCount
ProbeRoot := EnvGet("ERGOPTI_STARTUP_SMOKE_DIR")
ParentMarker := ProbeRoot "\parent.pid"
if !FileExist(ParentMarker) {
    FileAppend(ProcessExist(), ParentMarker, "UTF-8-RAW")
    Reload()
    Sleep(10000)
    ExitApp(91)
}
FileAppend("[INFO] Native Reload control reached readiness.`n", ProbeRoot "\native.log", "UTF-8-RAW")
Executable := StrReplace(StrReplace(A_AhkPath, "\", "\\"), '"', '\"')
Ready := '{"schema_version":1,"pid":' ProcessExist()
    . ',"compiled":false,"driver_ready":true,"menu_ready":true,"logs_flushed":true'
    . ',"nonce":"' EnvGet("ERGOPTI_STARTUP_SMOKE_NONCE") '","phase":"ready"'
    . ',"executable":"' Executable '","fixture":"native-reload","elapsed_ms":' (A_TickCount - ProbeStart) '}'
FileAppend(Ready, ProbeRoot "\ready.json", "UTF-8-RAW")
SetTimer(CheckReloadAcknowledgment, 10)
CheckReloadAcknowledgment() {
    if FileExist(EnvGet("ERGOPTI_STARTUP_SMOKE_DIR") "\ack.txt")
        ExitApp(0)
}
'@
[IO.File]::WriteAllText($controlEntry, $controlScript.Replace("`r", '') + "`n", [Text.UTF8Encoding]::new($true))
# Dot segments reliably differ without assuming that the volume enables 8.3 names.
$noncanonicalEntry = $sourceRoot + '\..\owned source\reload owner.ahk'
$canonicalEntry = [SourceBootProcess]::CanonicalEntry($noncanonicalEntry)
if ($canonicalEntry -ieq $noncanonicalEntry) { throw 'The native Reload path control is vacuous.' }
foreach ($invalid in @((Join-Path $sourceRoot 'missing.ahk'), $sourceRoot, 'relative.ahk')) {
    $refused = $false
    try { $null = [SourceBootProcess]::CanonicalEntry($invalid) }
    catch { $refused = $true }
    if (!$refused) { throw 'An absent, directory or relative source entry was admitted.' }
}
$pwsh = (Get-Process -Id $PID).Path
$controlOutput = & $pwsh -NoProfile -NonInteractive -File $Observer -Entry $noncanonicalEntry `
    -Ahk $Ahk -Root $controlRoot -Nonce ('b' * 32) -ExpectReload `
    -ReadyTimeoutSeconds 10 -ExitTimeoutMs 5000 -CleanupTimeoutMs 1000 2>&1
if ($LASTEXITCODE -ne 0 -or @($controlOutput).Count -ne 0) {
    throw ('The bounded native Reload control failed: ' + ($controlOutput -join "`n"))
}
$control = Get-Content -LiteralPath (Join-Path $controlRoot 'observation.json') -Raw | ConvertFrom-Json
if ($control.source_owner.script_argument_supplied_exact -ne $false -or
    $control.source_owner.script_argument_canonical_exact -ne $true -or
    $control.entry -cne $noncanonicalEntry -or
    $control.ready_pid -eq $control.initial_pid -or $control.reloaded -ne $true -or
    $control.initial_exit_code -ne 0 -or $control.exit_code -ne 0 -or
    $control.receipt.nonce -cne ('b' * 32)) {
    throw 'Actual Reload did not prove original-path refusal and canonical exact admission.'
}
$remaining = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -ieq $Ahk -and $null -ne $_.CommandLine -and
    [SourceBootProcess]::HasExactEntry($_.CommandLine, $canonicalEntry)
})
if ($remaining.Count -ne 0) { throw 'An owned native Reload control survived retirement.' }
Write-Output '[OK] Actual AHK Reload refuses the supplied dot-segment spelling and admits its canonical exact source; both generations retired.'
Write-Output '[OK] Source observer admits only the exact script and proven process generation; refusal evidence remains closed.'
