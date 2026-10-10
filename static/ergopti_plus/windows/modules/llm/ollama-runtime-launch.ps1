# modules/llm/ollama-runtime-launch.ps1
# Foreground managed serve with exact prepared-image and process-tree custody.
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$ManagedHelperPath,
	[Parameter(Mandatory = $true)][string]$ManagedHelperSha256,
	[Parameter(Mandatory = $true)][string]$ManagedRoot,
	[Parameter(Mandatory = $true)][string]$RootIdentity,
	[Parameter(Mandatory = $true)][string]$PublishedPath,
	[Parameter(Mandatory = $true)][string]$StageIdentity,
	[Parameter(Mandatory = $true)][string]$TicketId,
	[Parameter(Mandatory = $true)][string]$ManifestSha256,
	[Parameter(Mandatory = $true)][string]$RuntimeTicket,
	[Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
	[Parameter(Mandatory = $true)][int64]$StartedTick,
	[Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$DeadlineMs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-OllamaRuntimeSource([string]$Path, [string]$ExpectedHash) {
	if ($Path -cnotmatch '^[A-Za-z]:\\' -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}\z') {
		throw 'Runtime code requires its captured absolute source and digest.'
	}
	$stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		$hash = [Security.Cryptography.SHA256]::Create()
		try { $actual = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
		finally { $hash.Dispose(); $stream.Position = 0 }
		if ($actual -cne $ExpectedHash) { throw 'The captured managed runtime helper changed.' }
		$reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
		try { $code = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Position = 0 }
		$tokens = $null; $errors = $null
		$ast = [Management.Automation.Language.Parser]::ParseInput($code, $Path, [ref]$tokens, [ref]$errors)
		if ($errors.Count -ne 0) { throw 'The captured managed runtime helper cannot be parsed.' }
		return @{ stream = $stream; block = $ast.GetScriptBlock() }
	} catch { $stream.Dispose(); throw }
}

function Initialize-OllamaRuntimeObservation {
	if ('Ergopti.Ollama.RuntimeObservation' -as [type]) { return }
	Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Ergopti.Ollama {
 public static class RuntimeObservation {
  [DllImport("kernel32")] public static extern ulong GetTickCount64();
  [DllImport("kernel32")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32",SetLastError=true)] static extern bool IsProcessInJob(IntPtr p, IntPtr job, out bool inside);
  [DllImport("kernel32",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, byte[] data, uint size, IntPtr length);
  public static uint ActiveProcesses() {
   bool inside;
   if(!IsProcessInJob(GetCurrentProcess(),IntPtr.Zero,out inside)) throw new Win32Exception(Marshal.GetLastWin32Error());
   if(!inside) throw new InvalidOperationException("Managed runtime has no canonical tree owner.");
   var data=new byte[48];
   if(!QueryInformationJobObject(IntPtr.Zero,1,data,48,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return BitConverter.ToUInt32(data,40);
  }
 }
}
'@ | Out-Null
}

function Get-OllamaRuntimeRemaining($Request) {
	$now = [int64][Ergopti.Ollama.RuntimeObservation]::GetTickCount64()
	$elapsed = $now - $Request.started_tick
	if ($elapsed -lt 0 -or $elapsed -ge $Request.deadline_ms) { throw 'The original runtime readiness deadline expired.' }
	return [int]($Request.deadline_ms - $elapsed)
}

function Assert-OllamaOwnedListener($Process, [int]$Port) {
	if ($Process.HasExited) { throw 'The exact foreground runtime exited before readiness.' }
	$rows = @(Get-OllamaRuntimeListeners $Port)
	if ($rows.Count -ne 1 -or $rows[0].LocalAddress -cne '127.0.0.1' -or $rows[0].OwningProcess -ne $Process.Id) {
		throw 'The loopback listener is not the exact foreground runtime.'
	}
	# HasExited uses the retained process handle, not an identity reopened by PID.
	if ($Process.HasExited) { throw 'The retained runtime ended during listener admission.' }
}

function Get-OllamaRuntimeListeners([int]$Port) {
	# An empty table is expected before bind; an observation failure is not.
	return @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $Port })
}

function Start-OllamaRuntimeProcess($Start) {
	return [Diagnostics.Process]::Start($Start)
}

function Test-OllamaRuntimeHttp($Request, [int]$Remaining) {
	$http = [Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Request.port + '/api/version')
	$http.Proxy = $null; $http.Timeout = $Remaining; $http.ReadWriteTimeout = $Remaining
	$response = $http.GetResponse()
	try { if ([int]$response.StatusCode -ne 200) { throw 'The owned runtime readiness response was refused.' } }
	finally { $response.Dispose() }
}

function Wait-OllamaRuntimeDescendants {
	$reported = $false
	while ($true) {
		try {
			$count = [Ergopti.Ollama.RuntimeObservation]::ActiveProcesses()
			if ($count -eq 1) { return }
			if ($count -lt 1) { throw 'Current job accounting cannot exclude its live wrapper.' }
		} catch {
			if (-not $reported) {
				[Console]::Error.WriteLine('Owned runtime retains image leases: exact job accounting is unavailable.')
				$reported = $true
			}
		}
		Start-Sleep -Milliseconds 50
	}
}

function Invoke-OllamaRuntimeEntry {
	$source = $null; $root = $null; $stage = $null; $borrowed = [IntPtr]::Zero
	$models = [IntPtr]::Zero; $child = $null; $ready = $null
	# Dot-sourcing the helper binds its CLI defaults: preserve our admitted values.
	$request = @{ root = $ManagedRoot; root_identity = $RootIdentity; path = $PublishedPath;
		identity = $StageIdentity; ticket = $TicketId; manifest = $ManifestSha256;
		runtime_ticket = $RuntimeTicket; port = $Port; started_tick = $StartedTick; deadline_ms = $DeadlineMs }
	try {
		if ($request.runtime_ticket -cnotmatch '^[0-9a-f]{32}\z' -or $request.started_tick -le 0) {
			throw 'Runtime start requires its fresh admitted ticket and original clock.'
		}
		$source = Read-OllamaRuntimeSource $ManagedHelperPath $ManagedHelperSha256
		. $source.block
		Initialize-OllamaRuntimeObservation
		if ([Ergopti.Ollama.RuntimeObservation]::ActiveProcesses() -ne 1) {
			throw 'Runtime launch must be the sole live member of its new canonical job.'
		}
		$null = Get-OllamaRuntimeRemaining $request
		$root = Open-OllamaManagedRoot $request.root $false
		if ($root.identity -cne $request.root_identity) { throw 'The originating managed root was replaced.' }
		$borrowed = [Ergopti.Ollama.ManagedNative]::OpenDirectory($request.path, $true)
		$stage = Open-OllamaPreparedStage $root $request.ticket $request.identity $request.manifest $false $request.path $borrowed
		if (-not $stage.owned_files.Contains('ollama.exe')) {
			throw 'The exact executable inventory is incomplete.'
		}
		$modelsPath = [IO.Path]::Combine($root.path, 'models')
		if ([Ergopti.Ollama.ManagedNative]::PathIsAbsent($modelsPath)) {
			[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($modelsPath, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
		}
		$models = [Ergopti.Ollama.ManagedNative]::OpenDirectory($modelsPath, $false)
		Assert-OllamaPrivateSecurity $modelsPath
		$readyPath = [IO.Path]::Combine($root.path, '.runtime-' + $request.runtime_ticket + '.json')
		if (-not [Ergopti.Ollama.ManagedNative]::PathIsAbsent($readyPath)) { throw 'The fresh runtime receipt already exists.' }
		$start = [Diagnostics.ProcessStartInfo]::new([IO.Path]::Combine($stage.path, 'ollama.exe'))
		$start.UseShellExecute = $false
		$start.Arguments = 'serve'
		$start.EnvironmentVariables['OLLAMA_HOST'] = '127.0.0.1:' + $request.port
		$start.EnvironmentVariables['OLLAMA_MODELS'] = $modelsPath
		$null = Get-OllamaRuntimeRemaining $request
		if (@(Get-OllamaRuntimeListeners $request.port).Count -ne 0) {
			throw 'Managed runtime refuses a pre-existing listener; its owner is unchanged.'
		}
		$child = Start-OllamaRuntimeProcess $start
		$null = $child.Handle
		# No global HTTP poll authorizes readiness. Each HTTP attempt first admits
		# a listener whose PID belongs to this exact retained foreground child.
		while (-not $child.HasExited) {
			$remaining = Get-OllamaRuntimeRemaining $request
			$listeners = @(Get-OllamaRuntimeListeners $request.port)
			if ($listeners.Count -gt 0) {
				Assert-OllamaOwnedListener $child $request.port
				Test-OllamaRuntimeHttp $request $remaining
				$null = Get-OllamaRuntimeRemaining $request
				Assert-OllamaOwnedListener $child $request.port
				$ready = [Ergopti.Ollama.ManagedNative]::CreateOwnedFile($readyPath)
				$readyIdentity = [Ergopti.Ollama.ManagedNative]::Identity($ready.SafeFileHandle.DangerousGetHandle())
				$receipt = [ordered]@{ runtime_ticket = $request.runtime_ticket; ticket = $request.ticket;
					root_identity = $root.identity; version_identity = $request.identity; manifest_sha256 = $request.manifest;
					origin = 'http://127.0.0.1:' + $request.port; launcher_pid = $PID; child_pid = $child.Id;
					ready_file_identity = $readyIdentity; leases_held = 1 }
				$bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($receipt | ConvertTo-Json -Compress) + "`n")
				$ready.Write($bytes, 0, $bytes.Length); $ready.Flush($true)
				$imageHash = Get-OllamaStreamHash $ready
				$ready.Dispose(); $ready = $null
				# The AHK exact reader shares READ only. Readmit our completed image
				# as read-only before exposing it, retaining its original identity.
				$ready = Open-OllamaReadFile $readyPath $false
				if ([Ergopti.Ollama.ManagedNative]::Identity($ready.SafeFileHandle.DangerousGetHandle()) -cne $readyIdentity -or
					(Get-OllamaStreamHash $ready) -cne $imageHash) { throw 'The exact runtime readiness file was replaced.' }
				Assert-OllamaOwnedListener $child $request.port
				$null = Get-OllamaRuntimeRemaining $request
				$child.WaitForExit()
				return $child.ExitCode
			}
			Start-Sleep -Milliseconds ([Math]::Min(50, $remaining))
		}
		throw 'The foreground runtime ended without an owned readiness receipt.'
	} finally {
		# All code/image/models leases outlive every descendant. If cancellation
		# kills this canonical job, the kernel closes them as part of that fence.
		if ($null -ne $child) {
			Wait-OllamaRuntimeDescendants
			$child.Dispose()
		}
		if ($null -ne $ready) {
			$ready.Dispose(); $ready = $null
			$retireReady = Open-OllamaReadFile $readyPath $true
			try {
				if ([Ergopti.Ollama.ManagedNative]::Identity($retireReady.SafeFileHandle.DangerousGetHandle()) -cne $readyIdentity -or
					(Get-OllamaStreamHash $retireReady) -cne $imageHash) { throw 'Runtime receipt retirement cannot delete a replaced file.' }
				Remove-OllamaExactFile $retireReady
			} finally { $retireReady.Dispose() }
		}
		if ($models -ne [IntPtr]::Zero -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($models)) { throw 'The models directory retains native close debt.' }
		if ($null -ne $stage) { Close-OllamaPreparedChildren $stage }
		# Published validation borrowed this handle. Close it exactly once here.
		if ($borrowed -ne [IntPtr]::Zero -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($borrowed)) { throw 'The published runtime retains native close debt.' }
		if ($null -ne $root) { Close-OllamaManagedRoot $root }
		if ($null -ne $source) { $source.stream.Dispose() }
	}
}

if ($MyInvocation.InvocationName -ne '.') {
	try { exit (Invoke-OllamaRuntimeEntry) }
	catch { [Console]::Error.WriteLine('Owned Ollama runtime refused: ' + $_.Exception.GetType().FullName); exit 1 }
}
