# tools/diagnostics/notepad-callers.ps1
#Requires -Version 7.0
# Manual owned-window experiment; absent applications and admission refusals fail.
param(
    [switch]$Interactive,
    [string]$Repository = (Join-Path $PSScriptRoot '../..'),
    [string]$Runtime = 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe'
)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'The native Notepad receiving diagnostic requires Windows.' }
if (!$Interactive) { throw 'Pass -Interactive only when foreground testing is authorized and the keyboard is idle.' }
$Repository = (Resolve-Path -LiteralPath $Repository).Path
$ProbeRoot = Join-Path $Repository ('build/.codex-notepad-work/notepad-callers-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($ProbeRoot) | Out-Null
$WorkerDll = Join-Path $Repository 'static/ergopti_plus/windows/vendor/ergopti_nav_owner.dll'
$SeedName = 'owned-notepad-' + [Guid]::NewGuid().ToString('N') + '.txt'
$SeedPath = Join-Path $ProbeRoot $SeedName
$Launcher = $null
$Target = $null
$Sender = $null
$SafeToRetireTarget = $false
$Receipt = [ordered]@{ phase='prelaunch'; source_root=$ProbeRoot; clipboard='none'; keyboard='none'; cases=6; mode='actual-hse-llm-caller-dll' }
function Save-Receipt {
    $Json = ($Receipt | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'receipt.json'), $Json, [Text.UTF8Encoding]::new($false))
}
function ConvertTo-AhkLiteral([string]$Value) {
    if ($Value.Contains("`r") -or $Value.Contains("`n")) { throw 'A diagnostic path contains a newline.' }
    return '"' + $Value.Replace('`','``').Replace('"','`"') + '"'
}

function New-OwnedRunner {
    $WindowsRoot = [IO.Path]::GetFullPath((Join-Path $Repository 'static/ergopti_plus/windows'))
    $SharedModulesRoot = [IO.Path]::GetFullPath((Join-Path $WindowsRoot '../_shared/modules'))
    $TestsRoot = Join-Path $WindowsRoot 'tests'
    $RunnerPath = Join-Path $TestsRoot 'run_all.ahk'
    $ProbeSource = Join-Path $PSScriptRoot 'notepad-callers.ahk'
    $Includes = [Collections.Generic.List[string]]::new()
    foreach ($Line in [IO.File]::ReadAllLines($RunnerPath)) {
        if ($Line -notmatch '^#Include\s+(.+)$') { continue }
        $RelativeInclude = $Matches[1].Trim()
        if ($RelativeInclude -match '^(unit|meta|e2e)/') { continue }
        if ($RelativeInclude -match '[%<>]' -or $RelativeInclude.Contains("`r") -or $RelativeInclude.Contains("`n") -or $RelativeInclude.StartsWith('*')) { throw 'Unsupported dynamic/optional include in the canonical test graph.' }
        $IncludePath = [IO.Path]::GetFullPath((Join-Path $TestsRoot $RelativeInclude))
        if ((!$IncludePath.StartsWith($WindowsRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and !$IncludePath.StartsWith($SharedModulesRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) -or [IO.Path]::GetExtension($IncludePath) -ine '.ahk' -or [IO.Path]::GetFileName($IncludePath) -ieq 'ErgoptiPlus.ahk') { throw 'The canonical include leaves the headless Windows/shared module graph.' }
        if (!(Test-Path -LiteralPath $IncludePath -PathType Leaf)) { throw ('Missing canonical dependency: ' + $IncludePath) }
        if (!$Includes.Contains($IncludePath)) { $Includes.Add($IncludePath) }
    }
    $Framework = Join-Path $TestsRoot 'test_framework.ahk'
    $Stubs = Join-Path $TestsRoot 'test_stubs.ahk'
    if ($Includes.IndexOf($Framework) -ne 0 -or $Includes.IndexOf($Stubs) -le 0) { throw 'The canonical framework/stub initialization order changed.' }
    $Profiler = Join-Path $WindowsRoot 'infra/hotpath_profiler.ahk'
    if (!$Includes.Contains($Profiler)) { $Includes.Add($Profiler) }
    $Fixtures = @('test_llm_accept_injects_exact_text.ahk','test_hse_send_failure_transaction.ahk') | ForEach-Object { Join-Path $TestsRoot ('unit/' + $_) }
    $Lines = [Collections.Generic.List[string]]::new()
    foreach ($Line in @('#Requires AutoHotkey v2.0','#SingleInstance Off','#Warn All, StdOut','#Warn VarUnset, Off','OnError(CallerFatal)','global _OWNED_NOTEPAD_DIAGNOSTIC_RUNNER := true')) { $Lines.Add($Line) }
    $Lines.Add('SetWorkingDir(' + (ConvertTo-AhkLiteral $TestsRoot) + ')')
    $Lines.Add('global _VendorDir := ' + (ConvertTo-AhkLiteral (Join-Path $WindowsRoot 'vendor')))
    foreach ($Line in @('global _ConfigDir := A_ScriptDir . "\config\"','global _AhkSubDir := ""','global _LogsDir := A_ScriptDir . "\logs\"','global _DefaultLogsDir := _LogsDir')) { $Lines.Add($Line) }
    foreach ($IncludePath in $Includes) { $Lines.Add('#Include ' + $IncludePath) }
    $Lines.Add('InstallHotstringHooks()')
    $Lines.Add('InstallSendNoOps()')
    foreach ($IncludePath in $Fixtures) { $Lines.Add('#Include ' + $IncludePath) }
    $Lines.Add('#Include ' + $ProbeSource)
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'probe.ahk'),(($Lines -join "`n") + "`n"),[Text.UTF8Encoding]::new($true))
    $References = @($RunnerPath,$ProbeSource,$PSCommandPath) + $Includes.ToArray() + $Fixtures
    return @($References | Select-Object -Unique | ForEach-Object {
        [ordered]@{path=$_;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()}
    })
}

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class OwnedNotepadInventory {
    public delegate bool EnumProc(IntPtr h, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder value, int count);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder value, int count);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr h, out long created, out long exited, out long kernel, out long user);
    public static long Created(IntPtr h) {long c,e,k,u; if (!GetProcessTimes(h,out c,out e,out k,out u)) throw new System.ComponentModel.Win32Exception(); return c;}
    public static long[] Find(uint pid, string exclusiveName) {
        var found = new List<long>();
        EnumWindows((window, ignored) => {
            uint actual; GetWindowThreadProcessId(window,out actual);
            if (actual != pid) return true;
            var title = new StringBuilder(4096); GetWindowTextW(window,title,title.Capacity);
            if (!title.ToString().Contains(exclusiveName)) return true;
            EnumChildWindows(window,(control, unused) => {
                uint childPid; GetWindowThreadProcessId(control,out childPid);
                var kind = new StringBuilder(256); GetClassNameW(control,kind,kind.Capacity);
                if (childPid == pid && kind.ToString() == "RichEditD2DPT") { found.Add(window.ToInt64()); found.Add(control.ToInt64()); }
                return true;
            },IntPtr.Zero);
            return true;
        },IntPtr.Zero);
        return found.ToArray();
    }
}
'@
try {
    $Package = Get-AppxPackage Microsoft.WindowsNotepad
    if (!$Package) { throw 'Microsoft.WindowsNotepad is unavailable; the receiving diagnostic cannot run.' }
    $NotepadExe = Join-Path $Package.InstallLocation 'Notepad/Notepad.exe'
    if (@(Get-CimInstance Win32_Process -Filter "Name='Notepad.exe'").Count -ne 0) { throw 'Existing Notepad process prevents exclusive acquisition.' }
    $SourceRefs = New-OwnedRunner
    $Receipt.sources_before = $SourceRefs
    $Receipt.supervisor_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
    $Receipt.generated_runner_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ProbeRoot 'probe.ahk')).Hash.ToLowerInvariant()
    $Receipt.runtime_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $Runtime).Hash.ToLowerInvariant()
    $Receipt.notepad_exe=$NotepadExe
    $Receipt.notepad_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $NotepadExe).Hash.ToLowerInvariant()
    $Receipt.notepad_version=[string]$Package.Version
    $Receipt.worker_dll=$WorkerDll
    $Receipt.worker_dll_sha256_before=(Get-FileHash -Algorithm SHA256 -LiteralPath $WorkerDll).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($SeedPath,'owned-fixture-ready',[Text.UTF8Encoding]::new($true))
    $Start = [Diagnostics.ProcessStartInfo]::new($NotepadExe)
    $Start.UseShellExecute=$false
    $Start.ArgumentList.Add($SeedPath)
    $Launcher=[Diagnostics.Process]::Start($Start)
    $LauncherHandle=$Launcher.Handle
    $LauncherCreated=[OwnedNotepadInventory]::Created($LauncherHandle)
    $Receipt.launcher_pid=$Launcher.Id
    $Receipt.launcher_creation=[string]$LauncherCreated
    $Deadline=[Diagnostics.Stopwatch]::StartNew()
    while ($Deadline.ElapsedMilliseconds -lt 8000) {
        if ($Launcher.HasExited) { throw 'Retained package launcher exited before child admission.' }
        $Candidates=@(Get-CimInstance Win32_Process -Filter "Name='Notepad.exe'" | Where-Object { $_.ProcessId -ne $Launcher.Id })
        if ($Candidates.Count -gt 1) { throw 'Multiple Notepad candidates are not admissible.' }
        if ($Candidates.Count -eq 1) {
            $Candidate=$Candidates[0]
            if ($Candidate.ParentProcessId -ne $Launcher.Id -or $Candidate.ExecutablePath -ine $NotepadExe) { throw 'Foreign Notepad candidate is not admissible.' }
            $Target=[Diagnostics.Process]::GetProcessById($Candidate.ProcessId)
            $TargetHandle=$Target.Handle
            $TargetCreated=[OwnedNotepadInventory]::Created($TargetHandle)
            $Requery=@(Get-CimInstance Win32_Process -Filter "Name='Notepad.exe'" | Where-Object { $_.ProcessId -ne $Launcher.Id })
            if ($Launcher.HasExited -or $Target.HasExited -or $TargetCreated -lt $LauncherCreated -or $Requery.Count -ne 1 -or $Requery[0].ProcessId -ne $Target.Id -or $Requery[0].ParentProcessId -ne $Launcher.Id -or $Requery[0].ExecutablePath -ine $NotepadExe) { throw 'Retained native creation/parent/path admission failed.' }
            $SafeToRetireTarget=$true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if (!$SafeToRetireTarget) { throw 'No exact package child was acquired.' }
    $Receipt.target_pid=$Target.Id
    $Receipt.target_creation=[string]$TargetCreated
    $OwnedHandles=@()
    $Deadline.Restart()
    while ($Deadline.ElapsedMilliseconds -lt 8000) {
        if ($Target.HasExited) { throw 'Acquired Notepad exited before control admission.' }
        $OwnedHandles=@([OwnedNotepadInventory]::Find([uint32]$Target.Id,$SeedName))
        if ($OwnedHandles.Count -eq 2) { break }
        if ($OwnedHandles.Count -gt 2) { throw 'Multiple synthetic RichEdit controls are not admissible.' }
        Start-Sleep -Milliseconds 50
    }
    if ($OwnedHandles.Count -ne 2) { throw 'No unique synthetic RichEdit editor admitted.' }
    $Receipt.window=[string]$OwnedHandles[0]
    $Receipt.control=[string]$OwnedHandles[1]
    $Receipt.control_class='RichEditD2DPT'
    $Receipt.phase='owned-control-admitted'
    Save-Receipt
    $ChildStart=[Diagnostics.ProcessStartInfo]::new($Runtime)
    $ChildStart.UseShellExecute=$false
    $ChildStart.Environment['TEMP']=$ProbeRoot
    $ChildStart.Environment['TMP']=$ProbeRoot
    $ChildStart.Environment['ERGOPTI_AHK_RESULTS_FILE']=(Join-Path $ProbeRoot 'tap-sidecar.txt')
    $ChildStart.RedirectStandardOutput=$true
    $ChildStart.RedirectStandardError=$true
    foreach ($Argument in @('/ErrorStdOut',(Join-Path $ProbeRoot 'probe.ahk'),$ProbeRoot,[string]$Target.Id,[string]$TargetCreated,[string]$OwnedHandles[0],[string]$OwnedHandles[1],$SeedName,$WorkerDll)) { $ChildStart.ArgumentList.Add($Argument) }
    $Sender=[Diagnostics.Process]::Start($ChildStart)
    $SenderHandle=$Sender.Handle
    $SenderOutput=$Sender.StandardOutput.ReadToEndAsync()
    $SenderError=$Sender.StandardError.ReadToEndAsync()
    $Receipt.sender_pid=$Sender.Id
    $Receipt.phase='sender-active'
    Save-Receipt
    if (!$Sender.WaitForExit(20000)) {
        $SafeToRetireTarget=$false
        $Receipt.phase='retained-sync-message-debt'
        Save-Receipt
        while (!$Sender.WaitForExit(1000)) { }
    }
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'stdout.log'),$SenderOutput.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $ProbeRoot 'stderr.log'),$SenderError.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
    $Receipt.sender_exit=$Sender.ExitCode
    $Receipt.natural_sender_exit=$true
    $Receipt.worker_dll_sha256_after=(Get-FileHash -Algorithm SHA256 -LiteralPath $WorkerDll).Hash.ToLowerInvariant()
    if ($Receipt.worker_dll_sha256_after -ne $Receipt.worker_dll_sha256_before) { throw 'Production DLL changed during the observation.' }
    $Receipt.sources_after = @($SourceRefs | ForEach-Object {
        $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.path).Hash.ToLowerInvariant()
        if ($ActualHash -ne $_.sha256) { throw ('Diagnostic dependency changed: ' + $_.path) }
        [ordered]@{path=$_.path;sha256=$ActualHash}
    })
    $OutputText = [IO.File]::ReadAllText((Join-Path $ProbeRoot 'stdout.log'))
    $ErrorText = [IO.File]::ReadAllText((Join-Path $ProbeRoot 'stderr.log'))
    $ExpectedNames = @('llm-insertion','llm-incident-16-50','llm-supplementary-tail','hse-ct-star','hse-uppercase','hse-consumed-delimiter')
    $Rows = [regex]::Matches($OutputText, '(?m)^ok ([1-6]) - ([a-z0-9-]+) actual_caller=(LLM|HSE) phase=4 retired=1\r?$')
    if ($Rows.Count -ne 6 -or $OutputText -notmatch '(?m)^1\.\.6\r?$' -or $OutputText -match '(?m)^not ok ' -or $ErrorText.Length -ne 0) { throw 'The complete six-case receiving protocol did not pass.' }
    for ($RowIndex=0; $RowIndex -lt 6; $RowIndex++) {
        if ([int]$Rows[$RowIndex].Groups[1].Value -ne $RowIndex+1 -or $Rows[$RowIndex].Groups[2].Value -cne $ExpectedNames[$RowIndex]) { throw 'Receiving row identity/order changed.' }
    }
    $Receipt.warning_count = [regex]::Matches($OutputText,'Warning:').Count
    $Receipt.phase=if($Sender.ExitCode -eq 0){'completed'}else{'failed'}
    $SafeToRetireTarget=$true
    Save-Receipt
} catch {
    $Receipt.phase='failed'
    $Receipt.error_type=$_.Exception.GetType().Name
    $Receipt.error=$_.Exception.Message
    Save-Receipt
} finally {
    if ($Sender -and !$Sender.HasExited) {
        $Receipt.phase='retained-live-sender-debt'
        Save-Receipt
        while (!$Sender.WaitForExit(1000)) { }
    }
    if ($Sender -and $Sender.HasExited) { $Sender.Dispose() }
    if ($Target -and $SafeToRetireTarget) {
        if (!$Target.HasExited) { $Target.Kill(); if (!$Target.WaitForExit(8000)) { throw 'Exact owned Notepad retirement refused.' } }
        $Target.Dispose()
        $Receipt.target_retired=$true
    }
    if ($Launcher) {
        if (!$Launcher.HasExited) { $Launcher.Kill(); if (!$Launcher.WaitForExit(8000)) { throw 'Exact owned launcher retirement refused.' } }
        $Launcher.Dispose()
        $Receipt.launcher_retired=$true
    }
    Save-Receipt
}
$Receipt | ConvertTo-Json -Depth 8
if ($Receipt.phase -ne 'completed') { exit 1 }
