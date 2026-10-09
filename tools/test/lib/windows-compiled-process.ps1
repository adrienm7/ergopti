# Shared native Job/process custody for compiled suite and startup probes.
# The programmable-suite constructor retains its exact original command line.
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
    public CompiledHotstringsProcess(string exe, string script, string cwd, string output, string error)
        : this(exe, new StringBuilder(Quote(exe) + " /script /ErrorStdOut=utf-8 " + Quote(script) + " --only " + Quote("programmable hotstrings")), cwd, output, error) {}
    public static CompiledHotstringsProcess LaunchBoot(string exe, string cwd, string output, string error) {
        return new CompiledHotstringsProcess(exe, new StringBuilder(Quote(exe) + " /ErrorStdOut=utf-8"), cwd, output, error);
    }
    private CompiledHotstringsProcess(string exe, StringBuilder command, string cwd, string output, string error) {
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
    delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder name, int count);
    public bool HasDialog() {
        bool found = false;
        EnumWindows((window, parameter) => {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner == Pid) {
                var name = new StringBuilder(256); GetClassNameW(window, name, name.Capacity);
                if (name.ToString() == "#32770") found = true;
            }
            return true;
        }, IntPtr.Zero);
        return found;
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
