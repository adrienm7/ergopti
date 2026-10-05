# Qualify the packaged interpreter and its extracted worker dependencies together.
# The startup step supplies its admitted private bundle; this probe never substitutes
# the downloaded source interpreter or re-extracts a different package.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Executable,
    [Parameter(Mandatory)][string] $Checkout,
    [Parameter(Mandatory)][AllowEmptyString()][string] $BundleRoot,
    [Parameter(Mandatory)][AllowEmptyString()][string] $LocalAppData,
    [Parameter(Mandatory)][string] $StartupEvidence,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [ValidateRange(1, 240)][int] $TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
$evidenceFile = Join-Path $EvidenceDirectory 'evidence.json'
$tapFile = Join-Path $EvidenceDirectory 'results.tap'
$manifestFile = Join-Path $EvidenceDirectory 'manifest.json'
$receipt = [ordered]@{
    schema_version = 1
    scenario = 'compiled-programmable-hotstrings'
    sha = $env:GITHUB_SHA
    package_sha256 = $null
    dependency_sha256 = @{}
    native = $null
    timed_out = $false
    cleanup_acknowledged = $false
    complete = $false
    failure = 'not_started'
}
function Write-Evidence {
    [IO.File]::WriteAllText($evidenceFile, ($receipt | ConvertTo-Json -Depth 8) + "`n", $utf8)
}
function Get-AdmittedWorkerDependencies {
    param([string] $SourceRoot, [string] $RuntimeRoot, [string] $Identity, [string] $Sha)
    if ($Sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid package commit.' }
    # FileAppend(..., "UTF-8") writes a BOM; ReadAllText removes it like the
    # native UTF-8 reader. Match _Bundle_ReadMarker's explicit ASCII trimming.
    $marker = [IO.File]::ReadAllText((Join-Path $RuntimeRoot '.bundle-version')).Trim([char[]]" `t`r`n")
    if ($marker -cne $Identity -or $marker -cnotmatch ("^(?!__BUNDLE_VERSION__)[^\r\n]+\n" + $Sha + '$')) {
        throw 'The extracted runtime bundle differs from native startup.'
    }
    $digests = @{}
    # Bundle destinations are deliberately independent of repository paths.
    foreach ($pair in @(
        @{ bundle = 'static/ergopti_plus/_shared/modules/hotstrings/user_code.ahk';
           source = 'static/ergopti_plus/_shared/modules/hotstrings/user_code.ahk' },
        @{ bundle = 'vendor/ergopti_user_hotstrings.ahk';
           source = 'static/ergopti_plus/windows/vendor/ergopti_user_hotstrings.ahk' }
    )) {
        $runtimeDigest = (Get-FileHash -LiteralPath (Join-Path $RuntimeRoot $pair.bundle) -Algorithm SHA256).Hash.ToLowerInvariant()
        $sourceDigest = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $pair.source) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($runtimeDigest -cne $sourceDigest) { throw 'A packaged worker dependency differs from this checkout.' }
        $digests[$pair.bundle] = $runtimeDigest
    }
    return $digests
}
Write-Evidence
[IO.File]::WriteAllText($tapFile, '', $utf8)

# A suspended process joins this owned Job before any script or child can run.
# All waiting and termination uses retained native handles, never a recycled PID.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class CompiledHotstringsProcess : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES {
        public int Length; public IntPtr Descriptor; public int Inherit;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
        public int Size; public string Reserved; public string Desktop; public string Title;
        public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public ushort ShowWindow, ReservedSize; public IntPtr ReservedData, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION {
        public IntPtr Process, Thread; public uint ProcessId, ThreadId;
    }
    [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT {
        public long ProcessTime, JobTime; public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet; public uint ActiveLimit;
        public UIntPtr Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct EXTENDED_LIMIT {
        public BASIC_LIMIT Basic; public IO_COUNTERS Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)] struct ACCOUNTING {
        public long User, Kernel, PeriodUser, PeriodKernel;
        public uint PageFaults, Total, Active, Terminated;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObjectW(IntPtr attr, IntPtr name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref EXTENDED_LIMIT info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, out ACCOUNTING info, int size, IntPtr length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFileW(string path, uint access, uint share, ref SECURITY_ATTRIBUTES attr, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processAttr, IntPtr threadAttr, bool inherit, uint flags, IntPtr environment, string cwd, ref STARTUPINFO startup, out PROCESS_INFORMATION process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder image, ref uint size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr job, process;
    public uint Pid { get; private set; }
    public string Image { get; private set; }
    public string CreatedUtc { get; private set; }
    public static bool LastLaunchCleanupAcknowledged { get; private set; } = true;
    static void Require(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static string Quote(string text) {
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in text) {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
            result.Append(c); slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    public CompiledHotstringsProcess(string exe, string script, string cwd, string output, string error) {
        IntPtr stdin = IntPtr.Zero, stdout = IntPtr.Zero, stderr = IntPtr.Zero, thread = IntPtr.Zero;
        bool assigned = false;
        LastLaunchCleanupAcknowledged = true;
        try {
            job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero); Require(job != IntPtr.Zero);
            var limits = new EXTENDED_LIMIT(); limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE; no breakaway.
            Require(SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(limits)));
            var attr = new SECURITY_ATTRIBUTES { Length = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), Inherit = 1 };
            stdin = CreateFileW("NUL", 0x80000000, 3, ref attr, 3, 0, IntPtr.Zero);
            stdout = CreateFileW(output, 0x40000000, 1, ref attr, 2, 0, IntPtr.Zero);
            stderr = CreateFileW(error, 0x40000000, 1, ref attr, 2, 0, IntPtr.Zero);
            Require(stdin != new IntPtr(-1) && stdout != new IntPtr(-1) && stderr != new IntPtr(-1));
            var startup = new STARTUPINFO { Size = Marshal.SizeOf(typeof(STARTUPINFO)), Flags = 0x101, Input = stdin, Output = stdout, Error = stderr };
            var command = new StringBuilder(Quote(exe) + " /script /ErrorStdOut=utf-8 " + Quote(script) + " --only " + Quote("programmable hotstrings"));
            PROCESS_INFORMATION info;
            Require(CreateProcessW(exe, command, IntPtr.Zero, IntPtr.Zero, true, 0x08000004, IntPtr.Zero, cwd, ref startup, out info));
            process = info.Process; thread = info.Thread; Pid = info.ProcessId;
            LastLaunchCleanupAcknowledged = false;
            Require(AssignProcessToJobObject(job, process)); assigned = true;
            var image = new StringBuilder(32768); uint size = (uint)image.Capacity;
            Require(QueryFullProcessImageNameW(process, 0, image, ref size)); Image = image.ToString();
            if (!String.Equals(System.IO.Path.GetFullPath(exe), Image, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Native image differs from the admitted package.");
            long created, exited, kernel, user;
            Require(GetProcessTimes(process, out created, out exited, out kernel, out user));
            CreatedUtc = DateTime.FromFileTimeUtc(created).ToString("o");
            Require(ResumeThread(thread) != UInt32.MaxValue);
        } catch {
            // Before resume an unassigned process cannot have descendants.
            try {
                if (process != IntPtr.Zero) {
                    LastLaunchCleanupAcknowledged = assigned ? CancelAndAcknowledge() :
                        (TerminateProcess(process, 2) && WaitForSingleObject(process, 5000) == 0);
                }
            } finally { Dispose(); }
            throw;
        } finally {
            foreach (IntPtr handle in new [] { stdin, stdout, stderr, thread })
                if (handle != IntPtr.Zero && handle != new IntPtr(-1)) CloseHandle(handle);
        }
    }
    public bool Exited(uint milliseconds) {
        uint status = WaitForSingleObject(process, milliseconds);
        if (status == 0) return true;
        if (status == 0x102) return false;
        throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public uint ExitCode() { uint code; Require(GetExitCodeProcess(process, out code)); return code; }
    public uint ActiveProcesses() {
        ACCOUNTING info; Require(QueryInformationJobObject(job, 1, out info, Marshal.SizeOf(typeof(ACCOUNTING)), IntPtr.Zero));
        return info.Active;
    }
    public bool WaitForIdle(uint milliseconds) {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (ActiveProcesses() != 0 && clock.ElapsedMilliseconds < milliseconds) System.Threading.Thread.Sleep(25);
        return ActiveProcesses() == 0;
    }
    public bool CancelAndAcknowledge() {
        Require(TerminateJobObject(job, 2));
        bool exited = Exited(5000);
        return WaitForIdle(5000) && exited;
    }
    public void Dispose() {
        if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
        if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
    }
}
'@

$probe = $null
$sandbox = Join-Path $env:RUNNER_TEMP ('ergopti-programmable-' + [guid]::NewGuid().ToString('N'))
$savedEnvironment = @{}
$failure = 'admission'
try {
    if (!$IsWindows) { throw 'The compiled package probe requires Windows.' }
    $Executable = [IO.Path]::GetFullPath($Executable)
    $Checkout = [IO.Path]::GetFullPath($Checkout)
    $BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
    $LocalAppData = [IO.Path]::GetFullPath($LocalAppData)
    if ($env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$') { throw 'Missing exact CI commit.' }
    $checkoutSha = & git -C $Checkout rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $checkoutSha -cne $env:GITHUB_SHA) { throw 'The probe checkout is from another commit.' }
    $failure = 'package_admission_contract'
    & (Join-Path $Checkout 'tools/test/fixtures/test_compiled_user_hotstrings_package.ps1') -Probe $PSCommandPath -Checkout $Checkout
    $failure = 'admission'
    $startup = Get-Content -LiteralPath $StartupEvidence -Raw -Encoding utf8 | ConvertFrom-Json
    $digest = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt.package_sha256 = $digest
    if ($startup.sha -cne $env:GITHUB_SHA -or $startup.package_sha256 -cne $digest -or
        $startup.native_startup.exit_code -ne 0 -or @($startup.failures).Count -ne 0 -or
        $startup.native_startup.receipt.compiled -ne $true -or
        $startup.native_startup.receipt.build_commit -cne $env:GITHUB_SHA -or
        ![StringComparer]::OrdinalIgnoreCase.Equals($startup.native_startup.executable, $Executable)) {
        throw 'The packaged interpreter lacks same-commit admitted startup evidence.'
    }
    $expectedBundle = Join-Path $LocalAppData 'Ergopti/bundle'
    if (![StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($expectedBundle), $BundleRoot)) {
        throw 'The requested dependencies are not the admitted private runtime bundle.'
    }
    $receipt.dependency_sha256 = Get-AdmittedWorkerDependencies -SourceRoot $Checkout -RuntimeRoot $BundleRoot `
        -Identity $startup.native_startup.receipt.bundle_identity -Sha $env:GITHUB_SHA
    $privateTemp = Join-Path $sandbox 'temp'
    $null = New-Item -ItemType Directory -Path $privateTemp
    foreach ($name in @('TEMP', 'TMP', 'LOCALAPPDATA', 'ERGOPTI_USER_HOTSTRINGS_PACKAGE_ROOT',
        'ERGOPTI_AHK_RESULTS_FILE', 'ERGOPTI_STARTUP_SMOKE_DIR', 'ERGOPTI_STARTUP_SMOKE_NONCE')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $env:TEMP = $privateTemp
    $env:TMP = $privateTemp
    $env:LOCALAPPDATA = $LocalAppData
    $env:ERGOPTI_USER_HOTSTRINGS_PACKAGE_ROOT = $BundleRoot
    $env:ERGOPTI_AHK_RESULTS_FILE = [IO.Path]::GetFullPath($tapFile)
    $env:ERGOPTI_STARTUP_SMOKE_DIR = $null
    $env:ERGOPTI_STARTUP_SMOKE_NONCE = $null
    $runner = Join-Path $Checkout 'static/ergopti_plus/windows/tests/run_all.ahk'
    $failure = 'native_launch'
    $probe = [CompiledHotstringsProcess]::new($Executable, $runner, $Checkout,
        (Join-Path $sandbox 'stdout.txt'), (Join-Path $sandbox 'stderr.txt'))
    $receipt.native = [ordered]@{ pid = $probe.Pid; executable = $probe.Image; created_utc = $probe.CreatedUtc; exit_code = $null }
    $failure = 'native_execution'
    if (!$probe.Exited([uint32]($TimeoutSeconds * 1000))) {
        $receipt.timed_out = $true
        throw 'The compiled programmable suite exceeded its independent hang bound.'
    }
    $receipt.native.exit_code = $probe.ExitCode()
    if (!$probe.WaitForIdle(5000)) { throw 'The native suite left owned descendants alive.' }
    $receipt.cleanup_acknowledged = $true
    $failure = 'execution_manifest'
    & node (Join-Path $Checkout 'tools/test/validate-ahk-suite-manifest.cjs') --input $tapFile --json $manifestFile
    if ($LASTEXITCODE -ne 0) { throw 'The packaged runtime did not produce a complete exact TAP manifest.' }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding utf8 | ConvertFrom-Json
    if (!$manifest.complete -or $manifest.planned -le 0 -or $manifest.executed_count -ne $manifest.planned -or
        $manifest.failed -ne 0 -or $receipt.native.exit_code -ne 0) { throw 'The compiled suite did not pass every selected case.' }
    # Independent required behaviors: a zero-test or preview-only probe cannot pass.
    foreach ($required in @(
        'programmable hotstrings: metadata preview and admission never execute callbacks',
        'programmable hotstrings: source, destination and input receipts fence callbacks and output',
        'programmable hotstrings: typed results, cancellation debt and permanent shutdown',
        'programmable hotstrings: isolated result framing preserves exact UTF-8 and Boolean types',
        'programmable hotstrings: real Windows worker loads metadata and executes Unicode callback',
        'programmable hotstrings: real callbacks own actions and preserve true false zero and multiline text',
        'programmable hotstrings: real worker cancels descendants and withholds private source errors',
        'programmable hotstrings: canonical preview keeps builtin and declined-builtin priority',
        'programmable hotstrings: real live disable cancels a loading factory and its descendants',
        'programmable hotstrings: actual deferred terminal owner fences source control enable and late publication',
        'programmable hotstrings: actual native menu projects shared order and owns explicit create only',
        'programmable hotstrings: actual boot live persistence and cancellation refusal preserve source and preferences',
        'programmable hotstrings: real native ordinary password pause control and source receipts fence publication'
    )) {
        if (@($manifest.executed | Where-Object { $_.name -ceq $required -and $_.status -ceq 'ok' }).Count -ne 1) {
            throw 'The compiled manifest omitted a required native worker behavior.'
        }
    }
    $receipt.complete = $true
    $receipt.failure = $null
} catch {
    $receipt.failure = $failure
    # Errors may contain private factory/script text. Publish only the closed stage.
    Write-Host "Compiled programmable qualification failed at stage: $failure"
} finally {
    if ($null -ne $probe) {
        try {
            if (!$receipt.cleanup_acknowledged) { $receipt.cleanup_acknowledged = $probe.CancelAndAcknowledge() }
        } catch {
            $receipt.cleanup_acknowledged = $false
        } finally { $probe.Dispose() }
    } else {
        # A constructor failure must retain its measured exact-process cleanup ACK.
        $receipt.cleanup_acknowledged = [CompiledHotstringsProcess]::LastLaunchCleanupAcknowledged
    }
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    if ($receipt.cleanup_acknowledged -and (Test-Path -LiteralPath $sandbox)) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force } catch { $receipt.cleanup_acknowledged = $false }
    }
    if (!$receipt.cleanup_acknowledged) { $receipt.complete = $false; $receipt.failure = 'cleanup_debt' }
    if (!(Test-Path -LiteralPath $manifestFile)) {
        try {
            & node (Join-Path $Checkout 'tools/test/validate-ahk-suite-manifest.cjs') --input $tapFile --json $manifestFile *> $null
        } catch { } # The negative native receipt must survive a missing validator.
    }
    Write-Evidence
}
if (!$receipt.complete) { throw 'Compiled programmable package qualification failed; inspect the mandatory evidence.' }
Write-Host "Compiled programmable package qualification passed: $($manifest.passed)/$($manifest.planned) tests, native exit 0 and owned process tree closed."
