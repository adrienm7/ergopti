# tools/test/fixtures/test_source_boot_terminal_census.ps1
# Exercise the actual cleanup branch with recording ports and owned native exits.
param(
    [Parameter(Mandatory)][string] $Observer,
    [Parameter(Mandatory)][string] $Executable,
    [Parameter(Mandatory)][string] $Root,
    [switch] $NativeOnly
)
$ErrorActionPreference = 'Stop'
$parseTokens = $null
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($Observer, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The source observer did not parse.' }
$loops = @($tree.FindAll({ param($node)
    $node -is [Management.Automation.Language.ForEachStatementAst] -and
    $node.Variable.VariablePath.UserPath -ceq 'process' -and
    $node.Condition.Extent.Text -ceq '@(Get-CimInstance Win32_Process)'
}, $true))
if ($loops.Count -ne 1) { throw 'The actual failed-source census is absent or ambiguous.' }
$censusText = $loops[0].Extent.Text
foreach ($required in @('OpenProcess', 'MatchesSnapshot', 'TerminateProcess', 'CloseHandle')) {
    if (!$censusText.Contains('[SourceBootProcess]::' + $required)) {
        throw ('The actual cleanup owner omitted ' + $required + '.')
    }
}
# Only native ports change in this extracted executable branch. The original
# control flow, exceptions, continue and unconditional close remain its subject.
$census = [scriptblock]::Create($censusText.Replace('[SourceBootProcess]', '[CensusControlProcess]'))
$nativeDefinitions = @($tree.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Add-Type'
}, $true))
if ($nativeDefinitions.Count -ne 1 -or $nativeDefinitions[0].CommandElements[1] -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
    throw 'The actual native source identity definition is absent or ambiguous.'
}
$nativeSource = $nativeDefinitions[0].CommandElements[1].Value
$recordingSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
public static class CensusControlProcess {
    [DllImport("kernel32.dll", EntryPoint="WaitForSingleObject", SetLastError=true)]
    private static extern uint WaitNative(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", EntryPoint="GetExitCodeProcess", SetLastError=true)]
    private static extern bool ExitNative(IntPtr handle, out uint exit);
    [DllImport("kernel32.dll", EntryPoint="CloseHandle", SetLastError=true)]
    private static extern bool CloseNative(IntPtr handle);
    public static Queue<uint> Waits = new Queue<uint>();
    public static string Mode, Release;
    public static IntPtr Handle;
    public static bool Native, CloseAcknowledged;
    public static int Opened, Queried, Observed, Closed, Terminated;
    public static void Reset(string mode) {
        Mode=mode; Native=false; CloseAcknowledged=false; Handle=new IntPtr(123);
        Opened=Queried=Observed=Closed=Terminated=0; Waits.Clear();
    }
    public static IntPtr OpenProcess(uint access, bool inherit, uint pid) { Opened++; return Handle; }
    public static uint WaitForSingleObject(IntPtr handle, uint milliseconds) {
        Observed++;
        if (Native) return WaitNative(handle, milliseconds);
        if (Waits.Count == 0) throw new InvalidOperationException("Unexpected terminal observation.");
        return Waits.Dequeue();
    }
    public static bool HasExactEntry(string command, string entry) {
        return SourceBootProcess.HasExactEntry(command, entry);
    }
    public static bool MatchesSnapshot(IntPtr handle, long generation, string image) {
        Queried++;
        if (Mode == "native-exit-during-query") {
            File.WriteAllText(Release, "release");
            uint exit;
            if (WaitNative(handle,5000) != 0 || !ExitNative(handle,out exit) || exit != 7)
                throw new InvalidOperationException("Cooperative query barrier did not exit with7.");
        }
        if ((Mode.Contains("query") && !Mode.StartsWith("reap-")) || Mode == "native-terminal")
            throw new InvalidOperationException("Controlled native identity query refusal.");
        return Mode == "accepted" || Mode.StartsWith("reap-");
    }
    public static bool GetExitCodeProcess(IntPtr handle, out uint exit) {
        exit = Mode == "reap-exited-unsignaled" ? 1u : 259u;
        return Mode != "reap-exit-query-refusal";
    }
    public static bool TerminateProcess(IntPtr handle, uint exit) {
        Terminated++;
        if (Native) throw new InvalidOperationException("A terminal native candidate acquired termination authority.");
        return Mode != "reap-terminate-refusal";
    }
    public static bool CloseHandle(IntPtr handle) {
        Closed++;
        if (Mode == "close-refusal") throw new InvalidOperationException("Controlled candidate close refusal.");
        if (Native && !CloseNative(handle)) throw new InvalidOperationException("The exact native candidate handle did not close.");
        CloseAcknowledged=true;
        return true;
    }
}
'@
# Both classes compile together; the actual identity API stays the original
# definition rather than a separately rewritten command-line model.
Add-Type -TypeDefinition ($nativeSource + "`n" + $recordingSource.Replace("using System;", '').Replace("using System.Collections.Generic;", '').Replace("using System.IO;", '').Replace("using System.Runtime.InteropServices;", '').Replace('Queue<uint>', 'System.Collections.Generic.Queue<uint>'))
$Executable = [SourceBootProcess]::CanonicalEntry($Executable)
$Root = [IO.Path]::GetFullPath($Root)
$Entry = Join-Path $Root 'census entry.ahk'
[IO.File]::WriteAllText($Entry, '; Controlled argument, never executed.' + "`n")
$Ahk = $Executable
$CleanupTimeoutMs = 1000
$script:censusSnapshot = [pscustomobject]@{
    ExecutablePath = $Ahk
    CommandLine = '"' + $Ahk + '" /ErrorStdOut "' + $Entry + '"'
    ProcessId = 123
    CreationDate = [DateTime]::UtcNow
}
function Get-CimInstance { param($Class) return $script:censusSnapshot }
function Invoke-CensusControl {
    try {
        try { throw 'Source bootstrap exited with7.' }
        finally { & $census }
    } catch { return $_.Exception.Message }
}
if (!$NativeOnly) { foreach ($case in @(
    @{ mode='terminal'; waits=@(0); queries=0; observations=1; terminations=0; error='exited with7' },
    @{ mode='accepted'; waits=@(0x102,0); queries=1; observations=2; terminations=1; error='exited with7' },
    @{ mode='generation-mismatch'; waits=@(0x102); queries=1; observations=1; terminations=0; error='exited with7' },
    @{ mode='image-mismatch'; waits=@(0x102); queries=1; observations=1; terminations=0; error='exited with7' },
    @{ mode='query-exit'; waits=@(0x102,0); queries=1; observations=2; terminations=0; error='exited with7' },
    @{ mode='query-live'; waits=@(0x102,0x102); queries=1; observations=2; terminations=0; error='Controlled native identity query refusal' },
    @{ mode='wait-failed'; waits=@([uint32]::MaxValue); queries=0; observations=1; terminations=0; error='terminal state' },
    @{ mode='query-wait-failed'; waits=@(0x102,[uint32]::MaxValue); queries=1; observations=2; terminations=0; error='terminal state' },
    @{ mode='unexpected-wait'; waits=@(1); queries=0; observations=1; terminations=0; error='terminal state' }
    @{ mode='close-refusal'; waits=@(0); queries=0; observations=1; terminations=0; error='Controlled candidate close refusal' }
)) {
    [CensusControlProcess]::Reset($case.mode)
    foreach ($wait in $case.waits) { [CensusControlProcess]::Waits.Enqueue([uint32]$wait) }
    $errorText = Invoke-CensusControl
    if (!$errorText.Contains($case.error) -or [CensusControlProcess]::Opened -ne 1 -or
        [CensusControlProcess]::Queried -ne $case.queries -or
        [CensusControlProcess]::Observed -ne $case.observations -or
        [CensusControlProcess]::Terminated -ne $case.terminations -or
        [CensusControlProcess]::CloseAcknowledged -ne ($case.mode -ne 'close-refusal') -or
        [CensusControlProcess]::Closed -ne 1 -or [CensusControlProcess]::Waits.Count -ne 0) {
        throw ('Actual cleanup recording control refused: ' + $case.mode + '; ' + $errorText)
    }
}
Write-Output '[OK] Ten actual census branch controls preserve strict live refusal and terminal discard.'
}
foreach ($mode in @('native-terminal', 'native-exit-during-query')) {
    $nativeRoot = Join-Path $Root ($mode + '-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($nativeRoot)
    $release = Join-Path $nativeRoot 'release.txt'
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add('/ErrorStdOut')
    $start.ArgumentList.Add($Entry)
    $start.Environment['ERGOPTI_STARTUP_SMOKE_DIR'] = $nativeRoot
    $start.Environment['ERGOPTI_SOURCE_CHILD_SCENARIO'] = 'cooperative-exit'
    $child = $null
    $candidate = [IntPtr]::Zero
    try {
        $child = [Diagnostics.Process]::Start($start)
        if ($null -eq $child) { throw 'The exact cooperative child did not launch.' }
        $candidate = [SourceBootProcess]::OpenProcess(0x101001, $false, [uint32]$child.Id)
        if ($candidate -eq [IntPtr]::Zero) { throw 'The cooperative native handle was not acquired.' }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (!(Test-Path -LiteralPath (Join-Path $nativeRoot 'child-ready.txt')) -and [DateTime]::UtcNow -lt $deadline) {
            if ([SourceBootProcess]::WaitForSingleObject($candidate, 0) -ne 0x102) {
                throw 'The cooperative child ended before its live snapshot.'
            }
            Start-Sleep -Milliseconds 10
        }
        if (!(Test-Path -LiteralPath (Join-Path $nativeRoot 'child-ready.txt'))) {
            throw 'The cooperative child did not acknowledge its own readiness.'
        }
        $snapshot = CimCmdlets\Get-CimInstance Win32_Process -Filter ('ProcessId=' + $child.Id)
        if ($null -eq $snapshot -or $snapshot.ExecutablePath -ine $Executable -or
            ![SourceBootProcess]::HasExactEntry($snapshot.CommandLine, $Entry) -or
            ![SourceBootProcess]::MatchesSnapshot($candidate, $snapshot.CreationDate.ToFileTimeUtc(), $Executable) -or
            [SourceBootProcess]::WaitForSingleObject($candidate, 0) -ne 0x102) {
            throw 'The actual live cooperative generation and image were not proven.'
        }
        [CensusControlProcess]::Reset($mode)
        [CensusControlProcess]::Native = $true
        [CensusControlProcess]::Handle = $candidate
        [CensusControlProcess]::Release = $release
        $script:censusSnapshot = $snapshot
        if ($mode -eq 'native-terminal') {
            [IO.File]::WriteAllText($release, 'release')
            [uint32]$nativeExit = 0
            if ([SourceBootProcess]::WaitForSingleObject($candidate, 5000) -ne 0 -or
                ![SourceBootProcess]::GetExitCodeProcess($candidate, [ref]$nativeExit) -or $nativeExit -ne 7) {
                throw 'The cooperative child did not naturally exit with7.'
            }
        }
        $errorText = Invoke-CensusControl
        if ([CensusControlProcess]::CloseAcknowledged) { $candidate = [IntPtr]::Zero }
        $expectedQueries = if ($mode -eq 'native-terminal') { 0 } else { 1 }
        $expectedObservations = if ($mode -eq 'native-terminal') { 1 } else { 2 }
        $child.WaitForExit()
        if (!$errorText.Contains('exited with7') -or $child.ExitCode -ne 7 -or
            [CensusControlProcess]::Opened -ne 1 -or [CensusControlProcess]::Closed -ne 1 -or
            ![CensusControlProcess]::CloseAcknowledged -or
            [CensusControlProcess]::Queried -ne $expectedQueries -or
            [CensusControlProcess]::Observed -ne $expectedObservations -or
            [CensusControlProcess]::Terminated -ne 0) {
            throw ('The native terminal census control refused: ' + $mode + '; ' + $errorText)
        }
    } finally {
        if ($null -ne $child) {
            if (!$child.HasExited) {
                $child.Kill()
                if (!$child.WaitForExit(5000)) { throw 'The exact cooperative child did not retire.' }
            }
            $child.Dispose()
        }
        if ($candidate -ne [IntPtr]::Zero -and ![SourceBootProcess]::CloseHandle($candidate)) {
            throw 'The acquired cooperative candidate handle did not close.'
        }
    }
}
Write-Output '[OK] Two exact native child exits preserve the primary refusal without acquiring termination authority.'

# Additive diagnostic controls exercise the same extracted executable census.
# Neither accepted termination nor an exit code substitutes for a terminal wait.
if (!$NativeOnly) {
    foreach ($case in @(
        @{ mode='reap-timeout'; final=[uint32]0x102; terminated=$true; exit_accepted=$true; exit_code=259 },
        @{ mode='reap-wait-failed'; final=[uint32]::MaxValue; terminated=$true; exit_accepted=$true; exit_code=259 },
        @{ mode='reap-terminate-refusal'; final=[uint32]0x102; terminated=$false; exit_accepted=$true; exit_code=259 },
        @{ mode='reap-exit-query-refusal'; final=[uint32]0x102; terminated=$true; exit_accepted=$false; exit_code=-1 },
        @{ mode='reap-exited-unsignaled'; final=[uint32]0x102; terminated=$true; exit_accepted=$true; exit_code=1 }
    )) {
        [CensusControlProcess]::Reset($case.mode)
        [CensusControlProcess]::Waits.Enqueue([uint32]0x102)
        [CensusControlProcess]::Waits.Enqueue($case.final)
        $errorText = Invoke-CensusControl
        $prefix = 'An owned failed source reload could not be reaped. source-reap-evidence='
        if (!$errorText.StartsWith($prefix)) {
            throw ('The genuine cleanup refusal lost its native diagnostics: ' + $case.mode)
        }
        $record = $errorText.Substring($prefix.Length) | ConvertFrom-Json
        $names = @($record.PSObject.Properties | ForEach-Object Name | Sort-Object)
        $expectedNames = @('schema_version', 'identity_matches', 'before_wait', 'terminate_accepted',
            'terminate_error', 'terminal_wait', 'wait_error', 'exit_query_accepted', 'exit_query_error', 'exit_code') | Sort-Object
        if (@(Compare-Object $names $expectedNames).Count -ne 0 -or
            $record.schema_version -ne 1 -or $record.identity_matches -isnot [bool] -or
            $record.identity_matches -ne $true -or $record.before_wait -ne 0x102 -or
            $record.terminate_accepted -isnot [bool] -or $record.terminate_accepted -ne $case.terminated -or
            $record.terminal_wait -ne $case.final -or $record.exit_query_accepted -isnot [bool] -or
            $record.exit_query_accepted -ne $case.exit_accepted -or $record.exit_code -ne $case.exit_code -or
            [CensusControlProcess]::Opened -ne 1 -or [CensusControlProcess]::Queried -ne 1 -or
            [CensusControlProcess]::Observed -ne 2 -or [CensusControlProcess]::Terminated -ne 1 -or
            [CensusControlProcess]::Closed -ne 1 -or ![CensusControlProcess]::CloseAcknowledged -or
            [CensusControlProcess]::Waits.Count -ne 0) {
            throw ('The exact admitted-handle diagnostic control was refused: ' + $case.mode)
        }
    }
    Write-Output '[OK] Five admitted-handle reap diagnostics distinguish timeout, failed wait, terminate refusal, query refusal and an unsignaled exited handle.'
}
