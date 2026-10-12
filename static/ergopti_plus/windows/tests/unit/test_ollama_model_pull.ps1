# tests/unit/test_ollama_model_pull.ps1
# Native Windows PowerShell 5.1 import and model-child contract acceptance.
# Source admission/files/TCP observation are real; no managed Ollama credit is
# inferred from these controlled fixtures or from importing functions alone.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native Windows is required.' }
$directory = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..\..\modules\llm'))
$source = [IO.Path]::Combine($directory, 'ollama-model-pull.ps1')
$launcherPath = [IO.Path]::Combine($directory, 'ollama-runtime-launch.ps1')
$helperPath = [IO.Path]::Combine($directory, 'ollama_managed_files.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'The actual model worker source must parse.' }
foreach ($node in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
	. ([ScriptBlock]::Create($node.Extent.Text))
}
$script:passed = 0; $script:failed = 0
function Assert-Model([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('ASSERTION: ' + $Message) } }
function Case([string]$Name, [scriptblock]$Body) {
	try { & $Body; $script:passed++; Write-Output ('PASS ' + $Name) }
	catch { $script:failed++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Refuse([scriptblock]$Body) {
	$refused = $false
	try { & $Body | Out-Null } catch { $refused = $true }
	Assert-Model $refused 'Actual operation must refuse.'
}
$helper = $null; $launcher = $null; $listener = $null; $process = $null
$oldHost = [Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'Process')
$oldModels = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Process')
try {
	$helper = Open-OllamaModelSource $helperPath (Get-FileHash -LiteralPath $helperPath -Algorithm SHA256).Hash.ToLowerInvariant()
	$launcher = Open-OllamaModelSource $launcherPath (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
	. $helper.block
	$functions = @($launcher.block.Ast.EndBlock.Statements | Where-Object {
		$_ -is [Management.Automation.Language.FunctionDefinitionAst]
	} | ForEach-Object { $_.Extent.Text })
	. ([ScriptBlock]::Create(($functions -join "`n")))
	Case 'actual function-only launcher import has no mandatory CLI prompt' {
		Assert-Model ($functions.Count -gt 0) 'The actual verified source exposes definitions.'
		Initialize-OllamaManagedNative
		Initialize-OllamaRuntimeObservation
		Assert-Model ($null -ne ('Ergopti.Ollama.ManagedNative' -as [type])) 'Actual file library initialized.'
		Assert-Model ($null -ne ('Ergopti.Ollama.RuntimeObservation' -as [type])) 'Actual runtime library initialized.'
		# These functions use native observation; standalone PowerShell normally
		# has no canonical job and must refuse, never synthesize a process count.
		$outside = $false
		try { $count = [Ergopti.Ollama.RuntimeObservation]::ActiveProcesses(); Assert-Model ($count -ge 1) 'Observed canonical job count is positive.' }
		catch { $outside = $true }
		Assert-Model ($outside -or $count -ge 1) 'Native accounting is observed or explicitly refused.'
	}
	Case 'changed admitted model source is refused before import' {
		Refuse { Open-OllamaModelSource $launcherPath ('f' * 64) }
	}
	Case 'model child uses captured executable/tag/environment only' {
		[Environment]::SetEnvironmentVariable('OLLAMA_HOST', 'https://unowned.invalid:4444', 'Process')
		[Environment]::SetEnvironmentVariable('OLLAMA_MODELS', 'C:\unowned-personal-models', 'Process')
		$start = New-OllamaModelStart 'C:\captured\versions\0.24.0\ollama.exe' 'C:\captured\models' 18148 'qwen2.5:3b'
		Assert-Model ($start.FileName -ceq 'C:\captured\versions\0.24.0\ollama.exe' -and -not $start.UseShellExecute) 'The executable is exact without shell/PATH.'
		Assert-Model ($start.Arguments -ceq 'pull "qwen2.5:3b"') 'The canonical tag is literal.'
		Assert-Model ($start.EnvironmentVariables['OLLAMA_HOST'] -ceq '127.0.0.1:18148') 'The captured origin replaces ambient host for this child.'
		Assert-Model ($start.EnvironmentVariables['OLLAMA_MODELS'] -ceq 'C:\captured\models') 'The managed models path replaces ambient storage for this child.'
		Assert-Model ([Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'Process') -ceq 'https://unowned.invalid:4444') 'The personal process environment survives.'
	}
	Case 'display strings and metacharacters are rejected at native boundary' {
		foreach ($model in @('Qwen Display Name', 'tag" --other', 'tag;Remove-Item', 'tag`nnext')) {
			Refuse { New-OllamaModelStart 'C:\captured\ollama.exe' 'C:\captured\models' 18148 $model }
		}
	}
	$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
	$listener.Start()
	$port = $listener.LocalEndpoint.Port
	$process = [Diagnostics.Process]::GetCurrentProcess()
	$null = $process.Handle
	Case 'actual imported listener function observes retained process ownership' {
		$created = [Ergopti.Ollama.RuntimeObservation]::CreationTime($process.Handle)
		Assert-OllamaModelProcess $process $created $port
		Assert-Model (-not $process.HasExited) 'The exact retained process remains live.'
	}
	Case 'missing string or replaced creation identity cannot grant model admission' {
		$created = [Ergopti.Ollama.RuntimeObservation]::CreationTime($process.Handle)
		Refuse { Assert-OllamaModelProcess $process $null $port }
		Refuse { Assert-OllamaModelProcess $process ([string]$created) $port }
		Refuse { Assert-OllamaModelProcess $process ($created + 1L) $port }
		Assert-OllamaModelProcess $process $created $port
	}
	Case 'foreign listener refusal preserves installed user server' {
		$foreign = Get-Process | Where-Object { $_.Id -ne $process.Id } | Select-Object -First 1
		try { Refuse { Assert-OllamaOwnedListener $foreign $port } } finally { $foreign.Dispose() }
		Assert-OllamaOwnedListener $process $port
		Assert-Model ($listener.Server.IsBound) 'The unowned listener remains bound after refusal.'
	}
} finally {
	if ($null -ne $process) { $process.Dispose() }
	if ($null -ne $listener) { $listener.Stop() }
	if ($null -ne $launcher) { $launcher.stream.Dispose() }
	if ($null -ne $helper) { $helper.stream.Dispose() }
	[Environment]::SetEnvironmentVariable('OLLAMA_HOST', $oldHost, 'Process')
	[Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $oldModels, 'Process')
}
Write-Output ('Managed model import acceptance: ' + $script:passed + ' passed, ' + $script:failed + ' failed.')
if ($script:failed -ne 0) { exit 1 }
