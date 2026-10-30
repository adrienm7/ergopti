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
	[Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$DeadlineMs,
	[Parameter(Mandatory = $true)][string]$ServeEnvironmentPath,
	[Parameter(Mandatory = $true)][string]$ServeEnvironmentSha256,
	[Parameter(Mandatory = $true)][string]$VendorDirectory,
	[Parameter(Mandatory = $true)][string]$VendorSha256,
	[Parameter(Mandatory = $true)][string]$ProxyPolicyPath,
	[Parameter(Mandatory = $true)][string]$ProxyPolicySha256,
	[Parameter(Mandatory = $true)][string]$UpdaterDefaultsPath,
	[Parameter(Mandatory = $true)][string]$UpdaterDefaultsSha256,
	[Parameter(Mandatory = $true)][string]$RouteOriginsPath,
	[Parameter(Mandatory = $true)][string]$RouteOriginsSha256
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

# The shared serve environment (managed_ollama_environment.json) keeps the owned
# server on local models only: OLLAMA_NO_CLOUD stops its ollama.com contact. The
# listener address and the model store stay with this launcher.
function Read-OllamaServeEnvironment([string]$Path, [string]$ExpectedHash) {
	if ($Path -cnotmatch '^[A-Za-z]:\\' -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}\z') {
		throw 'The serve environment requires its captured absolute source and digest.'
	}
	$bytes = [IO.File]::ReadAllBytes($Path)
	if ($bytes.Length -le 0 -or $bytes.Length -gt 65536) { throw 'The serve environment size is invalid.' }
	$hash = [Security.Cryptography.SHA256]::Create()
	try { $actual = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $hash.Dispose() }
	if ($actual -cne $ExpectedHash) { throw 'The captured serve environment changed.' }
	$policy = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
	$fields = @($policy.PSObject.Properties | ForEach-Object { $_.Name })
	if ($fields.Count -ne 2 -or $fields -cnotcontains 'schema_version' -or $fields -cnotcontains 'serve_environment' -or
		$policy.schema_version -isnot [int] -or $policy.schema_version -ne 1 -or
		$policy.serve_environment -isnot [Management.Automation.PSCustomObject]) {
		throw 'The serve environment declaration is invalid.'
	}
	$environment = [ordered]@{}
	foreach ($entry in $policy.serve_environment.PSObject.Properties) {
		if ($entry.Name -cnotmatch '^[A-Z][A-Z0-9_]*\z' -or $entry.Name -ceq 'OLLAMA_HOST' -or $entry.Name -ceq 'OLLAMA_MODELS' -or
			$entry.Value -isnot [string] -or $entry.Value -match "[`0`r`n]") {
			throw 'The serve environment declaration is invalid.'
		}
		$environment[$entry.Name] = $entry.Value
	}
	if ($environment.Count -eq 0) { throw 'The serve environment declaration is empty.' }
	return $environment
}

# The proxy dependencies the launcher reads, in inventory order: the AHK owner
# hashes the same names (OllamaManagedBootstrap RuntimeVendorInventory).
function Get-OllamaRuntimeVendorNames {
	return @('ergopti_route_plan.ps1', 'ergopti_network_routes.ps1', 'ergopti_windows_proxy_config.ps1',
		'ergopti_native_proxy_ex.ps1', 'ergopti_network_pac.ps1')
}

# Opens every proxy dependency under one inventory digest. The streams stay
# open, so a dependency the route module dot-sources by path cannot change.
function Open-OllamaRuntimeVendor([string]$Directory, [string]$ExpectedHash) {
	if ($Directory -cnotmatch '^[A-Za-z]:\\' -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}\z') {
		throw 'The runtime proxy dependencies require their captured directory and digest.'
	}
	$sources = [ordered]@{}
	try {
		$inventory = ''
		foreach ($name in (Get-OllamaRuntimeVendorNames)) {
			$path = [IO.Path]::Combine($Directory, $name)
			$stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
			$sources.Add($name, @{ stream = $stream; block = $null })
			$hash = [Security.Cryptography.SHA256]::Create()
			try { $actual = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
			finally { $hash.Dispose(); $stream.Position = 0 }
			$reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
			try { $code = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Position = 0 }
			$tokens = $null; $errors = $null
			# The real path keeps PSScriptRoot, which the route module dot-sources by
			$ast = [Management.Automation.Language.Parser]::ParseInput($code, $path, [ref]$tokens, [ref]$errors)
			if ($errors.Count -ne 0) { throw 'A runtime proxy dependency cannot be parsed.' }
			$sources[$name].block = $ast.GetScriptBlock()
			$inventory += $name + "`n" + $actual + "`n"
		}
		$hash = [Security.Cryptography.SHA256]::Create()
		try { $actual = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($inventory)))).Replace('-', '').ToLowerInvariant() }
		finally { $hash.Dispose() }
		if ($actual -cne $ExpectedHash) { throw 'The runtime proxy dependency inventory changed.' }
		return $sources
	} catch {
		foreach ($source in $sources.Values) { $source.stream.Dispose() }
		throw
	}
}

# Reads one captured JSON declaration after checking its digest.
function Read-OllamaRuntimeJson([string]$Path, [string]$ExpectedHash) {
	if ($Path -cnotmatch '^[A-Za-z]:\\' -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}\z') {
		throw 'A runtime declaration requires its captured absolute source and digest.'
	}
	$bytes = [IO.File]::ReadAllBytes($Path)
	$hash = [Security.Cryptography.SHA256]::Create()
	try { $actual = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $hash.Dispose() }
	if ($actual -cne $ExpectedHash) { throw 'A captured runtime declaration changed.' }
	return [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
}

# The daemon cannot evaluate a PAC or read the Windows proxy settings: each
# origin of route_origins.json "ollama" is looked up natively, the shared route
# plan turns the answers into HTTPS_PROXY and NO_PROXY, and an exported relay
# of the user is inherited untouched. The relay is then asked for a tunnel the
# way the daemon will: one that demands a Windows login (NTLM, Negotiate) is
# never exported, and the receipt says so, so the pull refuses with a named
# reason while local models keep working offline.
# Returns @{ Mode; Tunnel; Environment }; a refused lookup or plan throws.
function Get-OllamaRuntimeProxy($Vendor, $Request) {
	. $Vendor['ergopti_route_plan.ps1'].block
	. $Vendor['ergopti_network_routes.ps1'].block
	$origins = Read-OllamaRuntimeJson $Request.route_origins $Request.route_origins_sha256
	$budgetMs = [int]$origins.route_lookup_budget_seconds * 1000
	if ($budgetMs -le 0) { throw 'The route lookup budget is invalid.' }
	$clock = [Diagnostics.Stopwatch]::StartNew()
	$resolve = {
		param($Origin)
		$remaining = [Math]::Min($budgetMs - $clock.ElapsedMilliseconds, (Get-OllamaRuntimeRemaining $Request))
		return Resolve-ErgoptiNativeNetworkRoutes $Origin ([int]$remaining) $null $null $Request.policy $Request.defaults
	}
	$read = { param($Name) [Environment]::GetEnvironmentVariable($Name, 'Process') }
	$proxy = Get-ErgoptiOwnedProxyEnvironment -Origins @($origins.clients.ollama) -Resolve $resolve -ReadEnvironment $read
	if (-not $proxy.Ok) { throw ('The owned runtime proxy was refused: ' + $proxy.Reason) }
	$tunnel = 'none'
	if ($proxy.Mode -ceq 'relay') {
		$tunnel = 'unprobed'
		if ($proxy.Proxy -cmatch '^http://') {
			$registry = ([Uri](@($origins.clients.ollama)[0])).Host + ':443'
			$tunnel = Test-ErgoptiRelayTunnel -Relay $proxy.Proxy -Target $registry `
				-TimeoutMs ([Math]::Max(1, [Math]::Min(5000, (Get-OllamaRuntimeRemaining $Request))))
		}
		if ($tunnel -ceq 'windows_login') { $proxy.Environment = [ordered]@{} }
	}
	return @{ Mode = $proxy.Mode; Tunnel = $tunnel; Environment = $proxy.Environment }
}

function New-OllamaRuntimeStart([string]$Executable, [int]$Port, [string]$ModelsPath, $ServeEnvironment) {
	if ($ServeEnvironment -isnot [Collections.Specialized.OrderedDictionary] -or $ServeEnvironment.Count -eq 0) {
		throw 'The managed server requires its shared serve environment.'
	}
	$start = [Diagnostics.ProcessStartInfo]::new($Executable)
	$start.UseShellExecute = $false
	$start.Arguments = 'serve'
	$start.EnvironmentVariables['OLLAMA_HOST'] = '127.0.0.1:' + $Port
	$start.EnvironmentVariables['OLLAMA_MODELS'] = $ModelsPath
	foreach ($name in $ServeEnvironment.Keys) { $start.EnvironmentVariables[$name] = $ServeEnvironment[$name] }
	return $start
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
  [DllImport("kernel32",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long ended, out long kernel, out long user);
  public static long CreationTime(IntPtr retainedProcess) {
   long created,ended,kernel,user;
   if(!GetProcessTimes(retainedProcess,out created,out ended,out kernel,out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
   if(created<=0) throw new InvalidOperationException("Retained child has no creation identity.");
   return created;
  }
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
	$models = [IntPtr]::Zero; $child = $null; $ready = $null; $vendor = $null
	# Dot-sourcing the helper binds its CLI defaults: preserve our admitted values.
	$request = @{ root = $ManagedRoot; root_identity = $RootIdentity; path = $PublishedPath;
		identity = $StageIdentity; ticket = $TicketId; manifest = $ManifestSha256;
		runtime_ticket = $RuntimeTicket; port = $Port; started_tick = $StartedTick; deadline_ms = $DeadlineMs;
		policy = $ProxyPolicyPath; defaults = $UpdaterDefaultsPath;
		route_origins = $RouteOriginsPath; route_origins_sha256 = $RouteOriginsSha256 }
	$serveEnvironment = Read-OllamaServeEnvironment $ServeEnvironmentPath $ServeEnvironmentSha256
	try {
		# The route module reads the policy and defaults by path: pin them first
		$null = Read-OllamaRuntimeJson $ProxyPolicyPath $ProxyPolicySha256
		$null = Read-OllamaRuntimeJson $UpdaterDefaultsPath $UpdaterDefaultsSha256
		$vendor = Open-OllamaRuntimeVendor $VendorDirectory $VendorSha256
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
		$start = New-OllamaRuntimeStart ([IO.Path]::Combine($stage.path, 'ollama.exe')) $request.port $modelsPath $serveEnvironment
		$proxy = Get-OllamaRuntimeProxy $vendor $request
		foreach ($name in $proxy.Environment.Keys) { $start.EnvironmentVariables[$name] = $proxy.Environment[$name] }
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
					child_created_filetime = [Ergopti.Ollama.RuntimeObservation]::CreationTime($child.Handle);
					ready_file_identity = $readyIdentity; leases_held = 1;
					proxy_mode = $proxy.Mode; proxy_tunnel = $proxy.Tunnel }
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
		if ($null -ne $vendor) { foreach ($entry in $vendor.Values) { $entry.stream.Dispose() } }
	}
}

if ($MyInvocation.InvocationName -ne '.') {
	try { exit (Invoke-OllamaRuntimeEntry) }
	catch { [Console]::Error.WriteLine('Owned Ollama runtime refused: ' + $_.Exception.GetType().FullName); exit 1 }
}
