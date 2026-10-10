# Private inert receiving of the actual launcher entry and its native boundaries.
param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$PrivateRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Actual launcher source must parse before receiving.' }
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
	. ([ScriptBlock]::Create($node.Extent.Text))
}
# All C# methods below record observations; none import or call a native API.
Add-Type @'
using System;
using System.Collections.Generic;
namespace Ergopti.Ollama {
 public static class RuntimeObservation {
  public static ulong Tick=1010;
  public static uint Active=1;
  public static ulong GetTickCount64() { return Tick; }
  public static Queue<uint> Sequence=new Queue<uint>();
  public static uint ActiveProcesses() { uint count=Sequence.Count>0 ? Sequence.Dequeue() : Active; ManagedNative.Events.Add("account:"+count); return count; }
 }
 public static class ManagedNative {
  public static List<string> Events=new List<string>();
  public static IntPtr OpenDirectory(string path,bool retire) { Events.Add("open:"+path+":"+retire); return retire ? new IntPtr(10) : new IntPtr(30); }
  public static bool PathIsAbsent(string path) { return !System.IO.File.Exists(path) && !System.IO.Directory.Exists(path); }
  public static void CreateProtectedDirectory(string path,byte[] security) { throw new Exception("Models already supplied by private fixture."); }
  public static bool CloseHandle(IntPtr h) { Events.Add("close:"+h.ToInt64()); return true; }
  public static System.IO.FileStream CreateOwnedFile(string path) { return new System.IO.FileStream(path,System.IO.FileMode.CreateNew,System.IO.FileAccess.ReadWrite,System.IO.FileShare.Read); }
  public static string Identity(IntPtr h) { return "34567890:3456789012345678"; }
 }
}
'@ | Out-Null
class RuntimeChild {
	[bool]$HasExited = $false
	[int]$Id = 5002
	[int]$Handle = 123
	[int]$ExitCode = 0
	[void]WaitForExit() { $global:CapturedReadyText = [IO.File]::ReadAllText($global:CapturedReadyPath); $this.HasExited = $true; $type = 'Ergopti.Ollama.RuntimeObservation' -as [type]; $type::Active = 1 }
	[void]Dispose() { $type = 'Ergopti.Ollama.ManagedNative' -as [type]; $type::Events.Add('child-dispose') }
}
[IO.Directory]::CreateDirectory($PrivateRoot) | Out-Null
$helperPath = Join-Path $PrivateRoot 'fixture-helper.ps1'
$helperText = @'
function Open-OllamaManagedRoot($Path,$Create) {
 if ($Create) { throw 'The actual launcher cannot create a replacement root.' }
 return @{path=$Path;identity='12345678:1234567890123456';versions=(Join-Path $Path 'versions')}
}
function Open-OllamaPreparedStage($Root,$Ticket,$Identity,$Hash,$Retiring,$Published,$Borrowed) {
 if ($Ticket -cne ('1'*32) -or $Identity -cne '23456789:2345678901234567' -or $Hash -cne ('a'*64) -or $Retiring -or $Published -cne (Join-Path $Root.versions 'captured') -or $Borrowed.ToInt64() -ne 10) { throw 'Actual borrowed publication/source arguments changed.' }
 [Ergopti.Ollama.ManagedNative]::Events.Add('prepared-admitted')
 return @{path=$Published;owned_files=@{'ollama.exe'=$true};manifest=@{files=$global:FixtureRuntimeFiles}}
}
function Assert-OllamaPrivateSecurity($Path) { [Ergopti.Ollama.ManagedNative]::Events.Add('models-security:'+$Path) }
function Close-OllamaPreparedChildren($Stage) { [Ergopti.Ollama.ManagedNative]::Events.Add('prepared-close') }
function Close-OllamaManagedRoot($Root) { [Ergopti.Ollama.ManagedNative]::Events.Add('root-close') }
function Get-OllamaStreamHash($Stream) {
 $position=$Stream.Position; $hash=[Security.Cryptography.SHA256]::Create()
 try { $Stream.Position=0; return ([BitConverter]::ToString($hash.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
 finally { $Stream.Position=$position; $hash.Dispose() }
}
function Open-OllamaReadFile($Path,$Retire) {
 [Ergopti.Ollama.ManagedNative]::Events.Add('receipt-open:'+ $Retire)
 return [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
}
function Remove-OllamaExactFile($Stream) {
 $path=$Stream.Name; $Stream.Dispose(); [IO.File]::Delete($path)
 [Ergopti.Ollama.ManagedNative]::Events.Add('receipt-deleted')
}
'@
[IO.File]::WriteAllText($helperPath, $helperText, [Text.UTF8Encoding]::new($false))
$script:ManagedHelperPath = $helperPath
$script:ManagedHelperSha256 = (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
$script:RootIdentity = '12345678:1234567890123456'
$script:StageIdentity = '23456789:2345678901234567'
$script:TicketId = '1' * 32
$script:ManifestSha256 = 'a' * 64
$script:Port = 23456
$script:StartedTick = 1000
$script:DeadlineMs = 9000
$script:Collision = $false
$script:Foreign = $false
$script:Spawns = 0
$script:HttpCalls = 0
$script:LastStart = $null

function Get-OllamaRuntimeListeners([int]$Port) {
	if ($script:Collision) { return [pscustomobject]@{ LocalPort = $Port; LocalAddress = '127.0.0.1'; OwningProcess = 9999 } }
	if ($script:Spawns -eq 0) { return @() }
	return [pscustomobject]@{ LocalPort = $Port; LocalAddress = '127.0.0.1'; OwningProcess = $(if ($script:Foreign) { 9999 } else { 5002 }) }
}
function Start-OllamaRuntimeProcess($Start) {
	$script:Spawns++
	$script:LastStart = $Start
	[Ergopti.Ollama.RuntimeObservation]::Active = 2
	$child = [RuntimeChild]::new()
	$global:FixtureRuntimeChild = $child
	if ($script:Collision) { $child.HasExited = $true; [Ergopti.Ollama.RuntimeObservation]::Active = 1 }
	return $child
}
function Test-OllamaRuntimeHttp($Request, [int]$Remaining) {
	if ($Remaining -ne 8990) { throw 'Original clock must reach the actual HTTP boundary.' }
	$script:HttpCalls++
	if ($global:FixtureHttpRefusal) {
		# Model external parent retirement: the leader has ended, but another
		# owned descendant remains until the following accounting observation.
		$global:FixtureRuntimeChild.HasExited = $true
		[Ergopti.Ollama.RuntimeObservation]::Active = 1
		[Ergopti.Ollama.RuntimeObservation]::Sequence.Enqueue(2)
		[Ergopti.Ollama.RuntimeObservation]::Sequence.Enqueue(1)
		throw 'Recorded owned HTTP refusal.'
	}
}
function Must([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Reset-Case([string]$Name) {
	$script:ManagedRoot = Join-Path $PrivateRoot $Name
	$script:PublishedPath = Join-Path $script:ManagedRoot 'versions/captured'
	[IO.Directory]::CreateDirectory((Join-Path $script:ManagedRoot 'models')) | Out-Null
	$script:RuntimeTicket = ([Guid]::NewGuid().ToString('N'))
	$global:CapturedReadyPath = Join-Path $script:ManagedRoot ('.runtime-' + $script:RuntimeTicket + '.json')
	$global:CapturedReadyText = ''
	$global:FixtureRuntimeFiles = @(@{ path = 'runner.dll' })
	$global:FixtureHttpRefusal = $false
	$script:Spawns = 0; $script:HttpCalls = 0; $script:Collision = $false; $script:Foreign = $false
	[Ergopti.Ollama.RuntimeObservation]::Active = 1
	[Ergopti.Ollama.RuntimeObservation]::Sequence.Clear()
	[Ergopti.Ollama.ManagedNative]::Events.Clear()
}
$cases = @(
	@('actual entry binds prepared borrowed handle, private models, exact receipt', {
		Reset-Case 'positive'
		Must ((Invoke-OllamaRuntimeEntry) -eq 0) 'Actual recording child exit must be retained.'
		Must ($script:Spawns -eq 1 -and $script:HttpCalls -eq 1) 'Actual entry must hit one owned spawn and one admitted HTTP request.'
		Must ($script:LastStart.FileName -ceq (Join-Path $script:PublishedPath 'ollama.exe')) 'Exact validated executable must be passed.'
		Must ($script:LastStart.EnvironmentVariables['OLLAMA_MODELS'] -ceq (Join-Path $script:ManagedRoot 'models')) 'Models directory must be the same admitted root child.'
		$receipt = $global:CapturedReadyText | ConvertFrom-Json
		Must ($receipt.launcher_pid -eq $PID -and $receipt.child_pid -eq 5002 -and $receipt.manifest_sha256 -ceq $script:ManifestSha256) 'Fresh receipt must bind current launcher, retained child and exact manifest.'
		Must (-not [IO.File]::Exists($global:CapturedReadyPath)) 'Normal exact receipt retirement must leave no file.'
		$events = [Ergopti.Ollama.ManagedNative]::Events
		Must ($events.IndexOf('child-dispose') -lt $events.IndexOf('prepared-close')) 'Native child tree must be ended before releasing image leases.'
		Must (@($events | Where-Object { $_ -ceq 'close:10' }).Count -eq 1) 'Borrowed published handle must close only once.'
	}),
	@('collision refuses without starting or touching the foreign server', {
		Reset-Case 'collision'; $script:Collision = $true
		try { Invoke-OllamaRuntimeEntry; throw 'Expected collision refusal.' }
		catch { Must ($_.Exception.Message -ceq 'Managed runtime refuses a pre-existing listener; its owner is unchanged.') 'Collision must have the exact refusal reason.' }
		Must ($script:Spawns -eq 0 -and $script:HttpCalls -eq 0) 'No foreign HTTP readiness or native process start is allowed.'
	}),
	@('exact self-contained inventory does not invent a required DLL', {
		Reset-Case 'self-contained'; $global:FixtureRuntimeFiles = @(@{path='ollama.exe'})
		Must ((Invoke-OllamaRuntimeEntry) -eq 0) 'An authenticated self-contained executable remains a supported inventory.'
		Must ($script:Spawns -eq 1 -and $script:HttpCalls -eq 1) 'Self-contained images use the same source/process readiness path.'
	}),
	@('HTTP refusal publishes no ready and retains until descendant closure', {
		Reset-Case 'http-refusal'; $global:FixtureHttpRefusal = $true
		try { Invoke-OllamaRuntimeEntry; throw 'Expected owned HTTP refusal.' }
		catch { Must ($_.Exception.Message -ceq 'Recorded owned HTTP refusal.') 'The real entry must preserve the HTTP boundary refusal.' }
		Must (-not [IO.File]::Exists($global:CapturedReadyPath)) 'Failed receiving cannot create a ready receipt.'
		$events = [Ergopti.Ollama.ManagedNative]::Events
		Must ($events.IndexOf('account:2') -lt $events.IndexOf('child-dispose') -and $events.IndexOf('account:1') -lt $events.IndexOf('prepared-close')) 'No image lease can close before the modeled descendant retirement observation.'
	}),
	@('root source mismatch refuses before spawn', {
		Reset-Case 'root'; $saved = $script:RootIdentity; $script:RootIdentity = 'ffffffff:ffffffffffffffff'
		try {
			try { Invoke-OllamaRuntimeEntry; throw 'Expected source refusal.' }
			catch { Must ($_.Exception.Message -ceq 'The originating managed root was replaced.') 'Root mismatch must fail in the real entry.' }
			Must ($script:Spawns -eq 0) 'No runtime can be spawned from a replaced root.'
		} finally { $script:RootIdentity = $saved }
	}),
	@('wrong retained child listener is not readiness', {
		Reset-Case 'listener'; $script:Foreign = $true; $script:Spawns = 1
		$child = [RuntimeChild]::new()
		try { Assert-OllamaOwnedListener $child 23456; throw 'Expected listener refusal.' }
		catch { Must ($_.Exception.Message -ceq 'The loopback listener is not the exact foreground runtime.') 'Listener PID mismatch must fail at the real listener admission.' }
		Must ($script:HttpCalls -eq 0) 'A foreign listener cannot enter HTTP receiving.'
	}),
	@('original elapsed readiness deadline cannot be renewed', {
		[Ergopti.Ollama.RuntimeObservation]::Tick = 10000
		try { Get-OllamaRuntimeRemaining @{started_tick=1000;deadline_ms=9000}; throw 'Expected deadline refusal.' }
		catch { Must ($_.Exception.Message -ceq 'The original runtime readiness deadline expired.') 'Boundary expiration must retain its actual reason.' }
		finally { [Ergopti.Ollama.RuntimeObservation]::Tick = 1010 }
	}),
	@('captured helper digest mismatch fails without code execution', {
		try { Read-OllamaRuntimeSource $helperPath ('0'*64); throw 'Expected source digest refusal.' }
		catch { Must ($_.Exception.Message -ceq 'The captured managed runtime helper changed.') 'Real source stream mismatch must refuse.' }
	}),
	@('unknown job accounting retains until wrapper-only observation', {
		Reset-Case 'accounting'
		[Ergopti.Ollama.RuntimeObservation]::Sequence.Enqueue(0)
		[Ergopti.Ollama.RuntimeObservation]::Sequence.Enqueue(2)
		[Ergopti.Ollama.RuntimeObservation]::Sequence.Enqueue(1)
		Wait-OllamaRuntimeDescendants
		$events = [Ergopti.Ollama.ManagedNative]::Events
		Must ($events.Count -eq 3 -and $events[0] -ceq 'account:0' -and $events[1] -ceq 'account:2' -and $events[2] -ceq 'account:1') 'Unknown accounting cannot be treated as wrapper-only or close a lease.'
	})
)
$failed = 0
foreach ($case in $cases) {
	try { & $case[1]; [Console]::Out.WriteLine('PASS ' + $case[0]) }
	catch { $failed++; [Console]::Error.WriteLine('FAIL ' + $case[0] + ': ' + $_.Exception.Message) }
}
[Console]::Out.WriteLine('RESULT passed=' + ($cases.Count - $failed) + ' failed=' + $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
