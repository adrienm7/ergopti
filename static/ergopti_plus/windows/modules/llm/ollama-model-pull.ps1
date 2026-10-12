# modules/llm/ollama-model-pull.ps1
# Pulls only through the admitted app-owned runtime; never PATH or ambient env.
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$ManagedHelperPath,
	[Parameter(Mandatory = $true)][string]$ManagedHelperSha256,
	[Parameter(Mandatory = $true)][string]$RuntimeLauncherPath,
	[Parameter(Mandatory = $true)][string]$RuntimeLauncherSha256,
	[Parameter(Mandatory = $true)][string]$ManagedRoot,
	[Parameter(Mandatory = $true)][string]$RootIdentity,
	[Parameter(Mandatory = $true)][string]$PublishedPath,
	[Parameter(Mandatory = $true)][string]$StageIdentity,
	[Parameter(Mandatory = $true)][string]$TicketId,
	[Parameter(Mandatory = $true)][string]$ManifestSha256,
	[Parameter(Mandatory = $true)][string]$RuntimeTicket,
	[Parameter(Mandatory = $true)][string]$ReadyFileIdentity,
	[Parameter(Mandatory = $true)][string]$ReadyImageSha256,
	[Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
	[Parameter(Mandatory = $true)][string]$Model
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Open-OllamaModelSource([string]$Path, [string]$ExpectedHash) {
	if ($Path -cnotmatch '^[A-Za-z]:\\' -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}\z') { throw 'Model source identity is invalid.' }
	$stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		$hash = [Security.Cryptography.SHA256]::Create()
		try { $actual = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
		finally { $hash.Dispose(); $stream.Position = 0 }
		if ($actual -cne $ExpectedHash) { throw 'The admitted model source changed.' }
		$reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
		try { $code = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Position = 0 }
		$tokens = $null; $errors = $null
		$ast = [Management.Automation.Language.Parser]::ParseInput($code, $Path, [ref]$tokens, [ref]$errors)
		if ($errors.Count -ne 0) { throw 'The admitted model source cannot be parsed.' }
		return @{ stream = $stream; block = $ast.GetScriptBlock() }
	} catch { $stream.Dispose(); throw }
}

function New-OllamaModelStart([string]$Executable, [string]$ModelsPath, [int]$Port, [string]$Model) {
	if ($Model -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_./:-]*\z' -or $Port -lt 1 -or $Port -gt 65535) {
		throw 'The model child requires a canonical literal request.'
	}
	$start = [Diagnostics.ProcessStartInfo]::new($Executable)
	$start.UseShellExecute = $false
	$start.Arguments = 'pull "' + $Model + '"'
	$start.EnvironmentVariables['OLLAMA_HOST'] = '127.0.0.1:' + $Port
	$start.EnvironmentVariables['OLLAMA_MODELS'] = $ModelsPath
	return $start
}

function Assert-OllamaModelProcess($Process, $Created, [int]$Port) {
	if (($Created -isnot [long] -and $Created -isnot [int]) -or $Created -le 0) {
		throw 'The originating server requires its typed native creation identity.'
	}
	if ([Ergopti.Ollama.RuntimeObservation]::CreationTime($Process.Handle) -ne $Created) {
		throw 'The originating server PID was replaced by another process object.'
	}
	Assert-OllamaOwnedListener $Process $Port
}

function Invoke-OllamaManagedModelPull {
	# Imported scripts have parameter defaults; freeze the exact admitted request.
	$request = @{ root = $ManagedRoot; root_identity = $RootIdentity; path = $PublishedPath;
		identity = $StageIdentity; ticket = $TicketId; manifest = $ManifestSha256;
		runtime = $RuntimeTicket; ready_identity = $ReadyFileIdentity; ready_image = $ReadyImageSha256;
		port = $Port; model = $Model }
	$helper = $null; $launcher = $null; $root = $null; $stage = $null
	$handle = [IntPtr]::Zero; $ready = $null; $server = $null; $child = $null
	try {
		if ($request.model -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_./:-]*\z' -or
			$request.runtime -cnotmatch '^[0-9a-f]{32}\z') { throw 'Model admission requires a literal model and runtime ticket.' }
		$helper = Open-OllamaModelSource $ManagedHelperPath $ManagedHelperSha256
		$launcher = Open-OllamaModelSource $RuntimeLauncherPath $RuntimeLauncherSha256
		. $helper.block
		# This source is a CLI with mandatory parameters. Import only its verified
		# function definitions; importing its entry block would prompt or launch.
		$functions = @($launcher.block.Ast.EndBlock.Statements | Where-Object {
			$_ -is [Management.Automation.Language.FunctionDefinitionAst]
		} | ForEach-Object { $_.Extent.Text })
		if ($functions.Count -eq 0) { throw 'The runtime source exposes no native library functions.' }
		. ([ScriptBlock]::Create(($functions -join "`n")))
		Initialize-OllamaRuntimeObservation
		if ([Ergopti.Ollama.RuntimeObservation]::ActiveProcesses() -ne 1) { throw 'The model worker requires its sole canonical job.' }
		$root = Open-OllamaManagedRoot $request.root $false
		if ($root.identity -cne $request.root_identity) { throw 'The originating model root changed.' }
		$handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($request.path, $true)
		$stage = Open-OllamaPreparedStage $root $request.ticket $request.identity $request.manifest $false $request.path $handle
		$ready = Open-OllamaReadFile ([IO.Path]::Combine($root.path, '.runtime-' + $request.runtime + '.json'))
		if ([Ergopti.Ollama.ManagedNative]::Identity($ready.SafeFileHandle.DangerousGetHandle()) -cne $request.ready_identity -or
			(Get-OllamaStreamHash $ready) -cne $request.ready_image) { throw 'The exact runtime readiness image changed.' }
		$receipt = Read-OllamaJsonStream $ready
		if ($receipt.runtime_ticket -cne $request.runtime -or $receipt.ticket -cne $request.ticket -or
			$receipt.root_identity -cne $root.identity -or $receipt.version_identity -cne $request.identity -or
			$receipt.manifest_sha256 -cne $request.manifest -or $receipt.origin -cne ('http://127.0.0.1:' + $request.port)) {
			throw 'Model admission refuses a foreign runtime receipt.'
		}
		$server = [Diagnostics.Process]::GetProcessById($receipt.child_pid)
		$null = $server.Handle
		Assert-OllamaModelProcess $server $receipt.child_created_filetime $request.port
		$start = New-OllamaModelStart ([IO.Path]::Combine($stage.path, 'ollama.exe')) ([IO.Path]::Combine($root.path, 'models')) $request.port $request.model
		Assert-OllamaModelProcess $server $receipt.child_created_filetime $request.port
		$child = Start-OllamaRuntimeProcess $start
		$null = $child.Handle
		$child.WaitForExit()
		Assert-OllamaModelProcess $server $receipt.child_created_filetime $request.port
		return $child.ExitCode
	} finally {
		if ($null -ne $child) { Wait-OllamaRuntimeDescendants; $child.Dispose() }
		if ($null -ne $server) { $server.Dispose() }
		if ($null -ne $ready) { $ready.Dispose() }
		if ($null -ne $stage) { Close-OllamaPreparedChildren $stage }
		if ($handle -ne [IntPtr]::Zero -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) { throw 'The model image retains its exact lease.' }
		if ($null -ne $root) { Close-OllamaManagedRoot $root }
		if ($null -ne $launcher) { $launcher.stream.Dispose() }
		if ($null -ne $helper) { $helper.stream.Dispose() }
	}
}

if ($MyInvocation.InvocationName -ne '.') {
	try { exit (Invoke-OllamaManagedModelPull) }
	catch { [Console]::Error.WriteLine('Managed model pull refused: ' + $_.Exception.GetType().FullName); exit 1 }
}
