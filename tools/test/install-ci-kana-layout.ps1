# tools/test/install-ci-kana-layout.ps1
<#
==============================================================================
MODULE: CI Kana Layout Installation
DESCRIPTION:
Installs the committed KbdEdit layout on an ephemeral Windows runner without
adding it to the language bar. The installer has no documented unattended CLI.
Its exact dialog controls are driven without activating a window or sending
keys. A job object confines discovery and cleanup to the installer descendants.
The AHK suite subsequently probes the installed layout without activating it.
==============================================================================
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or -not $env:RUNNER_TEMP -or -not $env:GITHUB_ENV) {
	throw 'Kana installation is restricted to an ephemeral GitHub Actions runner.'
}
if (-not [Environment]::Is64BitProcess) { throw 'Kana installation requires x64 PowerShell.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	throw 'The layout installer requires an elevated runner.'
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class KanaInstallerJob : IDisposable {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public uint cb;
        public string reserved, desktop, title;
        public uint x, y, width, height, xChars, yChars, fill, flags;
        public ushort show, reservedBytes;
        public IntPtr reservedData, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long processTime, jobTime;
        public uint flags;
        public UIntPtr minWorkingSet, maxWorkingSet;
        public uint activeProcesses;
        public UIntPtr affinity;
        public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits basic;
        public IoCounters io;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    delegate bool EnumCallback(IntPtr window, IntPtr state);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits limits, uint size);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool inside);
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32")] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32", SetLastError = true)] static extern bool EnumWindows(EnumCallback callback, IntPtr state);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32")] public static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32")] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32")] static extern int GetDlgCtrlID(IntPtr control);
    [DllImport("user32")] static extern IntPtr GetParent(IntPtr control);
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern int GetClassName(IntPtr control, StringBuilder name, int capacity);
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, StringBuilder text,
        uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32", SetLastError = true)] static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32")] static extern bool EnumChildWindows(IntPtr parent, EnumCallback callback, IntPtr state);
    IntPtr job;
    public uint RootPid { get; private set; }
    static void Check(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }

    public KanaInstallerJob(string executable) {
        job = CreateJobObject(IntPtr.Zero, null);
        Check(job != IntPtr.Zero);
        try {
            var limits = new ExtendedLimits();
            limits.basic.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
            Check(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(limits)));
            var startup = new StartupInfo();
            startup.cb = (uint)Marshal.SizeOf(startup);
            startup.flags = 1; // STARTF_USESHOWWINDOW, SW_HIDE.
            startup.show = 0;
            ProcessInfo process;
            Check(CreateProcess(executable, new StringBuilder("\"" + executable + "\""), IntPtr.Zero,
                IntPtr.Zero, false, 4, IntPtr.Zero, System.IO.Path.GetDirectoryName(executable), ref startup, out process));
            try {
                if (!AssignProcessToJobObject(job, process.process)) {
                    int error = Marshal.GetLastWin32Error();
                    TerminateProcess(process.process, 1);
                    throw new Win32Exception(error);
                }
                RootPid = process.pid;
                if (ResumeThread(process.thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { CloseHandle(process.thread); CloseHandle(process.process); }
        } catch { Dispose(); throw; }
    }
    public IntPtr[] Windows() {
        var result = new List<IntPtr>();
        Exception callbackError = null;
        bool enumerated = EnumWindows((window, state) => {
            try {
            uint pid;
            GetWindowThreadProcessId(window, out pid);
            IntPtr process = OpenProcess(0x1000, false, pid);
            if (process == IntPtr.Zero) return true;
            try {
                bool inside;
                Check(IsProcessInJob(process, job, out inside));
                if (inside) result.Add(window);
            } finally { CloseHandle(process); }
            return true;
            } catch (Exception error) { callbackError = error; return false; }
        }, IntPtr.Zero);
        if (callbackError != null) throw new InvalidOperationException("Installer window discovery failed", callbackError);
        Check(enumerated);
        return result.ToArray();
    }
    public static string Text(IntPtr window) {
        var text = new StringBuilder(2048);
        UIntPtr result;
        Check(SendMessageTimeout(window, 0xD, (IntPtr)text.Capacity, text, 2, 1000, out result) != IntPtr.Zero);
        return text.ToString();
    }
    public static string[] ChildTexts(IntPtr window) {
        var result = new List<string>();
        Exception callbackError = null;
        EnumChildWindows(window, (child, state) => {
            try { result.Add(Text(child)); return true; }
            catch (Exception error) { callbackError = error; return false; }
        }, IntPtr.Zero);
        if (callbackError != null) throw new InvalidOperationException("Installer dialog inspection failed", callbackError);
        return result.ToArray();
    }
    public static void Uncheck(IntPtr control) {
        UIntPtr result;
        Check(SendMessageTimeout(control, 0xF1, IntPtr.Zero, IntPtr.Zero, 2, 1000, out result) != IntPtr.Zero);
        Check(SendMessageTimeout(control, 0xF0, IntPtr.Zero, IntPtr.Zero, 2, 1000, out result) != IntPtr.Zero);
        if (result.ToUInt64() != 0) throw new InvalidOperationException("Language-bar checkbox stayed checked");
    }
    public static int ButtonId(IntPtr window, string caption) {
        var matches = new List<int>();
        Exception callbackError = null;
        EnumChildWindows(window, (child, state) => {
            try {
                if (GetParent(child) != window) return true;
                var name = new StringBuilder(256);
                Check(GetClassName(child, name, name.Capacity) != 0);
                if (name.ToString() == "Button" && Text(child) == caption) matches.Add(GetDlgCtrlID(child));
                return true;
            } catch (Exception error) { callbackError = error; return false; }
        }, IntPtr.Zero);
        if (callbackError != null) throw new InvalidOperationException("Installer button discovery failed", callbackError);
        if (matches.Count != 1 || matches[0] <= 0) throw new InvalidOperationException("Expected exactly one identified installer button: " + caption);
        return matches[0];
    }
    public static void Click(IntPtr window, int id) {
        IntPtr control = GetDlgItem(window, id);
        if (control == IntPtr.Zero || !IsWindowEnabled(control)) throw new InvalidOperationException("Missing or disabled installer button");
        // WM_COMMAND / BN_CLICKED reaches the handler even for a hidden dialog.
        Check(PostMessage(window, 0x111, (IntPtr)id, control));
    }
    public void Dispose() { if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; } }
}
'@

$layoutDirectory = Join-Path $PSScriptRoot '../../static/ergopti/windows'
$installer = Get-ChildItem -LiteralPath $layoutDirectory -Filter 'Ergopti_v*.exe' |
	Where-Object { $_.BaseName -match '^Ergopti_v\d+\.\d+\.\d+$' } |
	Sort-Object { [version]($_.BaseName -replace '^Ergopti_v', '') } -Descending |
	Select-Object -First 1
if (-not $installer) { throw 'No committed versioned Ergopti layout installer exists.' }
$version = $installer.BaseName -replace '^Ergopti_v', ''
$expectedText = "Ergopti v$version"
$expectedDll = "KbdEditergopti_v$version.dll"
$trace = [Collections.Generic.List[object]]::new()
$trace.Add(@{ installer = $installer.Name; sha256 = (Get-FileHash -LiteralPath $installer.FullName).Hash })
$owner = $null
try {
	$owner = [KanaInstallerJob]::new($installer.FullName)
	$deadline = [Diagnostics.Stopwatch]::StartNew()
	$main = [IntPtr]::Zero
	while ($deadline.Elapsed.TotalSeconds -lt 30 -and $main -eq [IntPtr]::Zero) {
		foreach ($window in $owner.Windows()) {
			if ([KanaInstallerJob]::GetDlgItem($window, 1246) -ne [IntPtr]::Zero -and
				[KanaInstallerJob]::GetDlgItem($window, 1003) -ne [IntPtr]::Zero) {
				if ($main -ne [IntPtr]::Zero) { throw 'Several owned installer dialogs matched.' }
				$main = $window
			}
		}
		if ($main -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
	}
	if ($main -eq [IntPtr]::Zero) { throw 'The owned layout installer dialog did not appear.' }
	$layoutText = [KanaInstallerJob]::Text([KanaInstallerJob]::GetDlgItem($main, 1000))
	$layoutDll = [KanaInstallerJob]::Text([KanaInstallerJob]::GetDlgItem($main, 1002))
	$trace.Add(@{ layoutText = $layoutText; layoutDll = $layoutDll })
	if ($layoutText -cne $expectedText -or $layoutDll -ine $expectedDll) {
		throw "Installer identity mismatch: $layoutText / $layoutDll"
	}
	[KanaInstallerJob]::Uncheck([KanaInstallerJob]::GetDlgItem($main, 1246))
	[KanaInstallerJob]::Click($main, 1003)
	$installed = $false
	$deadline.Restart()
	while ($deadline.Elapsed.TotalSeconds -lt 60 -and -not $installed) {
		foreach ($window in $owner.Windows()) {
			if ($window -eq $main) { continue }
			$texts = [KanaInstallerJob]::ChildTexts($window)
			if ($texts.Count -eq 0) { continue }
			$trace.Add(@{ dialog = [KanaInstallerJob]::Text($window); texts = $texts })
			if (-not ($texts -match '^Layout successfully installed\.?$')) {
				throw "Unexpected installer result: $($texts -join ' | ')"
			}
			# KbdEdit's success dialog has a private control ID, not Win32 IDOK.
			[KanaInstallerJob]::Click($window, [KanaInstallerJob]::ButtonId($window, 'OK'))
			$installed = $true
		}
		if (-not $installed) { Start-Sleep -Milliseconds 100 }
	}
	if (-not $installed) { throw 'The installer did not confirm success within 60 seconds.' }
	$registeredLayouts = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts' |
		Get-ItemProperty | Where-Object {
			$_.PSObject.Properties['Layout File'] -and $_.PSObject.Properties['Layout Text'] -and
			$_.'Layout File' -ieq $expectedDll -and $_.'Layout Text' -ceq $expectedText
		})
	if ($registeredLayouts.Count -ne 1 -or $registeredLayouts[0].PSChildName -notmatch '^[0-9a-fA-F]{8}$') {
		throw 'Installation did not register exactly one matching keyboard layout.'
	}
	$dll = Get-Item -LiteralPath (Join-Path $env:WINDIR "System32/$expectedDll")
	if ($dll.Length -eq 0) { throw 'The registered layout DLL is empty.' }
	$klid = $registeredLayouts[0].PSChildName
	$trace.Add(@{ klid = $klid; dllSha256 = (Get-FileHash -LiteralPath $dll.FullName).Hash })
	$deadline.Restart()
	while (-not [KanaInstallerJob]::IsWindowEnabled($main) -and $deadline.Elapsed.TotalSeconds -lt 5) {
		Start-Sleep -Milliseconds 100
	}
	if (-not [KanaInstallerJob]::IsWindowEnabled($main)) { throw 'The installation result dialog did not close.' }
	[KanaInstallerJob]::Click($main, 2)
	$deadline.Restart()
	while ($owner.Windows().Count -gt 0 -and $deadline.Elapsed.TotalSeconds -lt 5) {
		Start-Sleep -Milliseconds 100
	}
	if ($owner.Windows().Count -gt 0) { throw 'The installer windows did not close.' }
	[IO.File]::AppendAllText($env:GITHUB_ENV, "ERGOPTI_TEST_KANA_KLID=$klid`n", [Text.UTF8Encoding]::new($false))
} catch {
	$originalFailure = $_
	$trace.Add(@{ failure = $originalFailure.Exception.Message })
	if ($owner) {
		try {
			foreach ($window in $owner.Windows()) {
				$trace.Add(@{ title = [KanaInstallerJob]::Text($window); controls = [KanaInstallerJob]::ChildTexts($window) })
			}
		} catch {
			$trace.Add(@{ diagnosticFailure = $_.Exception.Message })
		}
	}
	throw $originalFailure
} finally {
	if ($owner) { $owner.Dispose() }
	$json = ConvertTo-Json -InputObject @($trace.ToArray()) -Depth 5
	[IO.File]::WriteAllText((Join-Path $env:RUNNER_TEMP 'ergopti-kana-install.json'),
		$json.Replace("`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
	Write-Output $json
}
