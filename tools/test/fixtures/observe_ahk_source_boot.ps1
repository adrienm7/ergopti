# tools/test/fixtures/observe_ahk_source_boot.ps1

# Hold the source successor's exact process handle until its readiness and exit
# are proven. All process capabilities belong to the caller's private clone.
param(
    [Parameter(Mandatory)][string] $Entry,
    [Parameter(Mandatory)][string] $Ahk,
    [Parameter(Mandatory)][string] $Root,
    [Parameter(Mandatory)][string] $Nonce,
    [switch] $ExpectReload,
    [switch] $LibraryOnly,
    [ValidateRange(1, 90)][int] $ReadyTimeoutSeconds = 90,
    [ValidateRange(1, 30000)][int] $ExitTimeoutMs = 30000,
    [ValidateRange(1, 5000)][int] $CleanupTimeoutMs = 5000
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class SourceBootProcess {
    [StructLayout(LayoutKind.Sequential)]
    public struct NativeTime { public uint Low; public uint High; }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetExitCodeProcess(IntPtr handle, out uint exit);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool TerminateProcess(IntPtr handle, uint exit);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetProcessTimes(IntPtr handle, out NativeTime created,
        out NativeTime exited, out NativeTime kernel, out NativeTime user);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool QueryFullProcessImageName(IntPtr handle, uint flags,
        StringBuilder image, ref int size);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr allocation);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetLongPathName(string path, StringBuilder result, uint capacity);
    public static string CanonicalEntry(string entry) {
        if (!Path.IsPathFullyQualified(entry) || !File.Exists(entry))
            throw new InvalidOperationException("The private source entry must be an existing absolute file.");
        string full = Path.GetFullPath(entry);
        StringBuilder canonical = new StringBuilder(32768);
        uint size = GetLongPathName(full, canonical, (uint)canonical.Capacity);
        if (size == 0 || size >= canonical.Capacity || !File.Exists(canonical.ToString()))
            throw new InvalidOperationException("Could not normalize the existing private source entry.");
        return canonical.ToString();
    }
    public static bool HasExactEntry(string command, string entry) {
        int count;
        IntPtr arguments = CommandLineToArgvW(command, out count);
        if (arguments == IntPtr.Zero) throw new InvalidOperationException("Could not parse owned command line.");
        try {
            for (int index=1; index<count; index++) {
                string argument = Marshal.PtrToStringUni(Marshal.ReadIntPtr(arguments, index*IntPtr.Size));
                if (String.Equals(argument, "/ErrorStdOut", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(argument, "/restart", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(argument, "/script", StringComparison.OrdinalIgnoreCase)) continue;
                // Only the interpreter's script argument grants cleanup authority.
                return String.Equals(argument, entry, StringComparison.OrdinalIgnoreCase);
            }
            return false;
        } finally { LocalFree(arguments); }
    }
    public static bool MatchesSnapshot(IntPtr handle, long creationFileTime, string interpreter) {
        NativeTime created, exited, kernel, user;
        if (!GetProcessTimes(handle, out created, out exited, out kernel, out user))
            throw new InvalidOperationException("Could not verify the owned process generation.");
        ulong actual = ((ulong)created.High << 32) | created.Low;
        // CIM serializes creation time to microseconds; compare at that resolution.
        if (actual/10 != (ulong)creationFileTime/10) return false;
        int size=32768;
        StringBuilder image = new StringBuilder(size);
        if (!QueryFullProcessImageName(handle, 0, image, ref size))
            throw new InvalidOperationException("Could not verify the owned process image.");
        return String.Equals(image.ToString(), interpreter, StringComparison.OrdinalIgnoreCase);
    }
}
'@

# An acquired handle grants no termination authority until its identity is proven.
function Get-AdmittedSourceHandle {
    param(
        [uint32] $ProcessId,
        [long] $CreationFileTime,
        [string] $Interpreter,
        [scriptblock] $Open = { param($Id) [SourceBootProcess]::OpenProcess(0x101001, $false, $Id) },
        [scriptblock] $Matches = { param($Handle, $Created, $Image)
            [SourceBootProcess]::MatchesSnapshot($Handle, $Created, $Image) },
        [scriptblock] $Close = { param($Handle) [void][SourceBootProcess]::CloseHandle($Handle) }
    )
    $candidateHandle = & $Open $ProcessId
    if ($candidateHandle -eq [IntPtr]::Zero) {
        throw 'Could not own the source successor terminal receipt.'
    }
    try {
        if (!(& $Matches $candidateHandle $CreationFileTime $Interpreter)) {
            throw 'The readiness PID changed ownership before its native handle was acquired.'
        }
        $admitted = $candidateHandle
        $candidateHandle = [IntPtr]::Zero
        return $admitted
    } finally {
        if ($candidateHandle -ne [IntPtr]::Zero) { & $Close $candidateHandle }
    }
}
function Get-SourceOwnerEvidence {
    param($Native, [string] $Interpreter, [string] $Entry)
    # These booleans explain refusal; they never grant process cleanup authority.
    # Keep command lines, source paths and unrelated process metadata private.
    $nativePresent = $null -ne $Native
    $imagePresent = $nativePresent -and ![string]::IsNullOrEmpty($Native.ExecutablePath)
    $commandPresent = $nativePresent -and ![string]::IsNullOrEmpty($Native.CommandLine)
    return [ordered]@{
        schema_version = 1
        native_present = [bool]$nativePresent
        image_present = [bool]$imagePresent
        image_exact = [bool]($imagePresent -and $Native.ExecutablePath -ieq $Interpreter)
        command_present = [bool]$commandPresent
        script_argument_exact = [bool]($commandPresent -and
            [SourceBootProcess]::HasExactEntry($Native.CommandLine, $Entry))
    }
}
if ($LibraryOnly) { return }

# AHK normalizes its source filename before Reload, including 8.3 aliases.
# Normalize the caller-selected file before launch; exact argument admission stays intact.
$requestedEntry = $Entry
$Entry = [SourceBootProcess]::CanonicalEntry($Entry)

$env:LOCALAPPDATA = Join-Path $Root 'localappdata'
$env:ERGOPTI_STARTUP_SMOKE_DIR = $Root
$env:ERGOPTI_STARTUP_SMOKE_NONCE = $Nonce
$env:ERGOPTI_STARTUP_SMOKE_BOOTSTRAP = '1'
$env:ERGOPTI_STARTUP_SMOKE_ACK = '1'
$initial = $null
$successor = [IntPtr]::Zero
$receipt = $null
$deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
$lastParseFailure = ''
try {
    $initial = Start-Process -FilePath $Ahk -ArgumentList @('/ErrorStdOut', ('"' + $Entry + '"')) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Root 'stdout.txt') `
        -RedirectStandardError (Join-Path $Root 'stderr.txt')
    $null = $initial.Handle
    $ready = Join-Path $Root 'ready.json'
    while ([DateTime]::UtcNow -lt $deadline) {
        $initial.Refresh()
        if ($initial.HasExited -and $initial.ExitCode -ne 0) {
            throw "Source bootstrap exited with $($initial.ExitCode)."
        }
        if (Test-Path -LiteralPath $ready) {
            try { $receipt = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json }
            catch { $lastParseFailure = $_.Exception.Message }
            if ($null -ne $receipt) { break }
        }
        Start-Sleep -Milliseconds 30
    }
    if ($null -eq $receipt) { throw "Source boot published no complete readiness receipt: $lastParseFailure" }
    if (@($receipt.PSObject.Properties).Count -ne 11 -or
        $receipt.pid -isnot [long] -or $receipt.pid -le 0 -or
        $receipt.schema_version -isnot [long] -or
        $receipt.compiled -isnot [bool] -or $receipt.driver_ready -isnot [bool] -or
        $receipt.menu_ready -isnot [bool] -or $receipt.logs_flushed -isnot [bool] -or
        $receipt.nonce -cne $Nonce -or $receipt.compiled -ne $false -or
        $receipt.schema_version -ne 1 -or $receipt.phase -cne 'ready' -or
        $receipt.driver_ready -ne $true -or $receipt.menu_ready -ne $true -or
        $receipt.logs_flushed -ne $true -or $receipt.executable -ine $Ahk) {
        throw 'Source readiness belongs to another process or an incomplete boot.'
    }
    if (($receipt.pid -ne $initial.Id) -ne $ExpectReload.IsPresent) {
        throw 'Source readiness did not come from the expected bootstrap generation.'
    }
    $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($receipt.pid)"
    if ($null -eq $native -or $native.ExecutablePath -ine $Ahk -or
        ![SourceBootProcess]::HasExactEntry($native.CommandLine, $Entry)) {
        $ownerEvidence = Get-SourceOwnerEvidence -Native $native -Interpreter $Ahk -Entry $Entry
        throw ('The readiness owner is not executing the private cloned source. source-owner-evidence=' +
            ($ownerEvidence | ConvertTo-Json -Compress))
    }
    $successor = Get-AdmittedSourceHandle -ProcessId $receipt.pid `
        -CreationFileTime $native.CreationDate.ToFileTimeUtc() -Interpreter $Ahk
    $ackStage = Join-Path $Root 'ack.txt.stage'
    $ack = [IO.File]::Open($ackStage, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Nonce)
        $ack.Write($bytes, 0, $bytes.Length)
        $ack.Flush($true)
    } finally { $ack.Dispose() }
    [IO.File]::Move($ackStage, (Join-Path $Root 'ack.txt'))
    if ([SourceBootProcess]::WaitForSingleObject($successor, $ExitTimeoutMs) -ne 0) {
        throw 'The ready source successor did not exit within its native bound.'
    }
    [uint32]$exitCode = 259
    if (![SourceBootProcess]::GetExitCodeProcess($successor, [ref]$exitCode) -or $exitCode -ne 0) {
        throw "The source successor exited with $exitCode."
    }
    if (!$initial.WaitForExit($ExitTimeoutMs) -or $initial.ExitCode -ne 0) {
        throw 'The source bootstrap parent did not exit cleanly.'
    }
    $logs = @(Get-ChildItem -LiteralPath $Root -Filter '*.log' -File -Recurse)
    if ($logs.Count -eq 0) { throw 'Source readiness has no durable logs.' }
    $errors = @($logs | Select-String -Pattern '\[(ERROR|FATAL)\]|the error window for')
    if ($errors.Count -ne 0) { throw "Source startup logged failures: $errors" }
    $observation = [ordered]@{
        initial_pid = $initial.Id; ready_pid = $receipt.pid; reloaded = $ExpectReload.IsPresent
        initial_exit_code = $initial.ExitCode; exit_code = $exitCode
        entry = $requestedEntry; log_files = $logs.Count; receipt = $receipt
        source_owner = [ordered]@{
            script_argument_supplied_exact = [SourceBootProcess]::HasExactEntry($native.CommandLine, $requestedEntry)
            script_argument_canonical_exact = [SourceBootProcess]::HasExactEntry($native.CommandLine, $Entry)
        }
    }
    [IO.File]::WriteAllText((Join-Path $Root 'observation.json'),
        ($observation | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
} finally {
    if ($successor -ne [IntPtr]::Zero) {
        if ([SourceBootProcess]::WaitForSingleObject($successor, 0) -ne 0) {
            if (![SourceBootProcess]::TerminateProcess($successor, 1)) {
                Write-Warning 'The owned source successor could not be terminated.'
            }
            if ([SourceBootProcess]::WaitForSingleObject($successor, $CleanupTimeoutMs) -ne 0) {
                throw 'The owned source successor could not be reaped.'
            }
        }
        if (![SourceBootProcess]::CloseHandle($successor)) {
            Write-Warning 'The owned source successor handle could not be closed.'
        }
    }
    if ($null -ne $initial) {
        $initial.Refresh()
        if (!$initial.HasExited) {
            $initial.Kill()
            if (!$initial.WaitForExit($CleanupTimeoutMs)) { throw 'The owned source parent could not be reaped.' }
        }
        $initial.Dispose()
    }
    # A failed reload may never publish its PID. Reap only processes whose native
    # image and command line name the caller's unique private source path.
    foreach ($process in @(Get-CimInstance Win32_Process)) {
        if ($process.ExecutablePath -ine $Ahk -or $null -eq $process.CommandLine -or
            ![SourceBootProcess]::HasExactEntry($process.CommandLine, $Entry)) { continue }
        $handle = [SourceBootProcess]::OpenProcess(0x101001, $false, [uint32]$process.ProcessId)
        if ($handle -eq [IntPtr]::Zero) { continue }
        try {
            # A terminal candidate needs no cleanup authority. CIM may still
            # return its earlier snapshot while the exact native handle exits.
            $cleanupWait = [SourceBootProcess]::WaitForSingleObject($handle, 0)
            if ($cleanupWait -eq 0) { continue } # WAIT_OBJECT_0
            if ($cleanupWait -ne 0x102) { # WAIT_TIMEOUT is the only live result.
                throw 'Could not observe the failed source candidate terminal state.'
            }
            try {
                $cleanupMatches = [SourceBootProcess]::MatchesSnapshot($handle,
                    $process.CreationDate.ToFileTimeUtc(), $Ahk)
            } catch {
                # Image metadata can disappear after the first live check.
                # Discard only a physically terminal handle; never admit it.
                $cleanupWait = [SourceBootProcess]::WaitForSingleObject($handle, 0)
                if ($cleanupWait -eq 0) { continue } # WAIT_OBJECT_0
                if ($cleanupWait -ne 0x102) {
                    throw 'Could not observe the failed source candidate terminal state.'
                }
                throw
            }
            if (!$cleanupMatches) { continue }
            if (![SourceBootProcess]::TerminateProcess($handle, 1)) {
                Write-Warning 'An owned failed source reload could not be terminated.'
            }
            if ([SourceBootProcess]::WaitForSingleObject($handle, $CleanupTimeoutMs) -ne 0) {
                throw 'An owned failed source reload could not be reaped.'
            }
        } finally { [void][SourceBootProcess]::CloseHandle($handle) }
    }
}
