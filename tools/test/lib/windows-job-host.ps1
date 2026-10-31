# tools/test/lib/windows-job-host.ps1
# Runs one command line as the sole member of a new kill-on-close job, the shape
# ShellRunner gives the managed Ollama workers, so an end-to-end test can start the
# real launcher without AutoHotkey. With a NetOnlyUser it runs in a logon session
# whose outbound identity is that test credential (the runas /netonly mechanism,
# no administrator right, nothing stored), so real SSPI signs in as a known user.
#
# The caller ends the tree by creating StopPath; the host also ends it if the
# caller disappears, so a crashed test leaves no daemon behind.
[CmdletBinding()]
param(
	# A file, because CreateProcessWithLogonW refuses a command line over 1024 characters.
	[Parameter(Mandatory = $true)][string]$CommandFile,
	[Parameter(Mandatory = $true)][string]$StdoutPath,
	[Parameter(Mandatory = $true)][string]$StderrPath,
	[Parameter(Mandatory = $true)][string]$ExitPath,
	[Parameter(Mandatory = $true)][string]$StopPath,
	[Parameter(Mandatory = $true)][int]$ParentPid,
	[string]$NetOnlyUser = '',
	[string]$NetOnlyDomain = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Ergopti.Test {
 public static class JobHost {
  const uint CREATE_SUSPENDED=0x4, CREATE_NO_WINDOW=0x08000000, CREATE_UNICODE_ENVIRONMENT=0x400;
  const uint STARTF_USESTDHANDLES=0x100, HANDLE_FLAG_INHERIT=1, WAIT_OBJECT_0=0, LOGON_NETCREDENTIALS_ONLY=2;
  const int JobObjectExtendedLimitInformation=9;
  const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE=0x2000;
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct STARTUPINFO {
   public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
   public int dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
   public short wShowWindow,cbReserved2; public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError;
  }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess,hThread; public int dwProcessId,dwThreadId; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMITS {
   public long PerProcessUserTimeLimit,PerJobUserTimeLimit; public uint LimitFlags;
   public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize; public uint ActiveProcessLimit;
   public UIntPtr Affinity; public uint PriorityClass,SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct EXTENDED_LIMITS {
   public BASIC_LIMITS Basic; public IO_COUNTERS Io;
   public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;
  }
  [DllImport("kernel32",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref STARTUPINFO si,out PROCESS_INFORMATION pi);
  [DllImport("advapi32",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateProcessWithLogonW(string user,string domain,string password,uint logon,string app,StringBuilder cmd,uint flags,IntPtr env,string cwd,ref STARTUPINFO si,out PROCESS_INFORMATION pi);
  [DllImport("kernel32",SetLastError=true,CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string name);
  [DllImport("kernel32",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref EXTENDED_LIMITS info,int size);
  [DllImport("kernel32",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
  [DllImport("kernel32",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint ms);
  [DllImport("kernel32",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
  [DllImport("kernel32",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32",SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);
  static void Check(bool ok,string what) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error(),what); }
  static bool Gone(int pid) { try { using(var p=Process.GetProcessById(pid)) return p.HasExited; } catch(ArgumentException) { return true; } }
  // Runs in the current session under a new job and waits for it.
  public static int RunInJob(string commandLine,string stdoutPath,string stderrPath,string stopPath,int parentPid) {
   IntPtr job=CreateJobObjectW(IntPtr.Zero,null); Check(job!=IntPtr.Zero,"CreateJobObject");
   var limits=new EXTENDED_LIMITS(); limits.Basic.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
   Check(SetInformationJobObject(job,JobObjectExtendedLimitInformation,ref limits,Marshal.SizeOf(limits)),"SetInformationJobObject");
   // FileStream refuses the NUL device: an empty private file is the same end of input.
   File.WriteAllBytes(stdoutPath+".stdin",new byte[0]);
   using(var stdin=new FileStream(stdoutPath+".stdin",FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
   using(var stdout=new FileStream(stdoutPath,FileMode.Create,FileAccess.Write,FileShare.ReadWrite))
   using(var stderr=new FileStream(stderrPath,FileMode.Create,FileAccess.Write,FileShare.ReadWrite)) {
    foreach(var stream in new[]{stdin,stdout,stderr}) Check(SetHandleInformation(stream.SafeFileHandle.DangerousGetHandle(),HANDLE_FLAG_INHERIT,HANDLE_FLAG_INHERIT),"SetHandleInformation");
    var si=new STARTUPINFO(); si.cb=Marshal.SizeOf(si); si.dwFlags=(int)STARTF_USESTDHANDLES;
    si.hStdInput=stdin.SafeFileHandle.DangerousGetHandle(); si.hStdOutput=stdout.SafeFileHandle.DangerousGetHandle(); si.hStdError=stderr.SafeFileHandle.DangerousGetHandle();
    PROCESS_INFORMATION pi;
    Check(CreateProcessW(null,new StringBuilder(commandLine),IntPtr.Zero,IntPtr.Zero,true,CREATE_SUSPENDED|CREATE_NO_WINDOW,IntPtr.Zero,null,ref si,out pi),"CreateProcess");
    Check(AssignProcessToJobObject(job,pi.hProcess),"AssignProcessToJobObject");
    Check(ResumeThread(pi.hThread)!=0xFFFFFFFF,"ResumeThread");
    CloseHandle(pi.hThread);
    while(WaitForSingleObject(pi.hProcess,50)!=WAIT_OBJECT_0) {
     if(File.Exists(stopPath) || Gone(parentPid)) { Check(TerminateJobObject(job,1),"TerminateJobObject"); WaitForSingleObject(pi.hProcess,10000); break; }
    }
    uint code; Check(GetExitCodeProcess(pi.hProcess,out code),"GetExitCodeProcess");
    CloseHandle(pi.hProcess);
    // Closing the job ends any descendant the leader left behind.
    CloseHandle(job);
    return (int)code;
   }
  }
  // Starts this same host again inside a netonly logon session and waits for it.
  public static int RunNetOnly(string powershell,string commandLine,string user,string domain,string password,int parentPid) {
   var block=new StringBuilder();
   var names=new ArrayList(Environment.GetEnvironmentVariables().Keys); names.Sort(StringComparer.OrdinalIgnoreCase);
   foreach(string name in names) { if(name!="ERGOPTI_E2E_NETONLY_PASSWORD") block.Append(name).Append('=').Append(Environment.GetEnvironmentVariable(name)).Append('\0'); }
   block.Append('\0');
   IntPtr env=Marshal.StringToHGlobalUni(block.ToString());
   try {
    var si=new STARTUPINFO(); si.cb=Marshal.SizeOf(si);
    PROCESS_INFORMATION pi;
    Check(CreateProcessWithLogonW(user,domain,password,LOGON_NETCREDENTIALS_ONLY,powershell,new StringBuilder(commandLine),CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT,env,Environment.CurrentDirectory,ref si,out pi),"CreateProcessWithLogon");
    CloseHandle(pi.hThread);
    while(WaitForSingleObject(pi.hProcess,100)!=WAIT_OBJECT_0) { }
    uint code; Check(GetExitCodeProcess(pi.hProcess,out code),"GetExitCodeProcess");
    CloseHandle(pi.hProcess);
    return (int)code;
   } finally { Marshal.FreeHGlobal(env); }
  }
 }
}
'@ | Out-Null

$quote = { param($Text) '"' + $Text + '"' }
if ($NetOnlyUser -cne '') {
	$password = [Environment]::GetEnvironmentVariable('ERGOPTI_E2E_NETONLY_PASSWORD', 'Process')
	if ([string]::IsNullOrEmpty($password)) { throw 'A netonly host needs ERGOPTI_E2E_NETONLY_PASSWORD.' }
	$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
	$inner = (& $quote $powershell) + ' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (& $quote $PSCommandPath) +
		' -CommandFile ' + (& $quote $CommandFile) + ' -StdoutPath ' + (& $quote $StdoutPath) + ' -StderrPath ' + (& $quote $StderrPath) +
		' -ExitPath ' + (& $quote $ExitPath) + ' -StopPath ' + (& $quote $StopPath) + ' -ParentPid ' + $ParentPid
	exit ([Ergopti.Test.JobHost]::RunNetOnly($powershell, $inner, $NetOnlyUser, $NetOnlyDomain, $password, $PID))
}
try {
	$code = [Ergopti.Test.JobHost]::RunInJob([IO.File]::ReadAllText($CommandFile), $StdoutPath, $StderrPath, $StopPath, $ParentPid)
	[IO.File]::WriteAllText($ExitPath, [string]$code)
	exit 0
} catch {
	# A netonly host has no console: the caller reads this beside the exit file.
	[IO.File]::WriteAllText($ExitPath + '.error', $_.Exception.ToString())
	exit 1
}
