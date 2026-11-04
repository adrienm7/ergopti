# tests/unit/modules/llm/servers/test_ollama_model_environment.ps1
# Receives real child and descendant environments from the actual model builder.
[CmdletBinding()]
param([switch]$BuilderOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $BuilderOnly -and [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
	throw 'Native Windows PowerShell is required for declaration admission.'
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../../../../../..'))
$directory = Join-Path $repository 'static/ergopti_plus/windows/modules/llm'
foreach ($file in @('ollama-runtime-launch.ps1', 'ollama-model-pull.ps1')) {
	$tokens = $null; $errors = $null
	$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $directory $file), [ref]$tokens, [ref]$errors)
	if ($errors.Count -ne 0) { throw 'The actual process source must parse.' }
	foreach ($node in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
		. ([ScriptBlock]::Create($node.Extent.Text))
	}
}
$declaration = Join-Path $repository 'static/ergopti_plus/_shared/modules/llm/managed_ollama_environment.json'
if ($BuilderOnly) {
	# PowerShell 7 JSON integer typing differs from the production PS5 reader.
	# This portable mode qualifies only the actual builder and process inheritance.
	$environment = [ordered]@{}
	$policy = [IO.File]::ReadAllText($declaration) | ConvertFrom-Json
	foreach ($property in $policy.serve_environment.PSObject.Properties) { $environment[$property.Name] = $property.Value }
} else {
	$environment = Read-OllamaServeEnvironment $declaration (Get-FileHash -LiteralPath $declaration -Algorithm SHA256).Hash.ToLowerInvariant()
}
$executable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$models = Join-Path ([IO.Path]::GetTempPath()) 'ergopti-owned-models'
function Assert-Environment([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('ASSERTION: ' + $Message) } }
function Encode-EnvironmentCommand([string]$Code) { return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)) }
$leaf = '$ProgressPreference = ''SilentlyContinue''; @{ cloud = $env:OLLAMA_NO_CLOUD; host = $env:OLLAMA_HOST; models = $env:OLLAMA_MODELS } | ConvertTo-Json -Compress'
$leafEncoded = Encode-EnvironmentCommand $leaf
$childCode = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$start = [Diagnostics.ProcessStartInfo]::new([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$start.UseShellExecute = $false
$start.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand __LEAF__'
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$child = [Diagnostics.Process]::new()
$child.StartInfo = $start
try {
	if (-not $child.Start()) { throw 'The descendant did not start.' }
	if (-not $child.WaitForExit(10000)) { $child.Kill(); $child.WaitForExit(); throw 'The descendant timed out.' }
	$stdout = $child.StandardOutput.ReadToEnd()
	$stderr = $child.StandardError.ReadToEnd()
	if ($child.ExitCode -ne 0 -or $stderr.Length -ne 0) { throw ('The descendant refused: ' + $stderr) }
	@{ cloud = $env:OLLAMA_NO_CLOUD; host = $env:OLLAMA_HOST; models = $env:OLLAMA_MODELS;
		descendant = ($stdout | ConvertFrom-Json) } | ConvertTo-Json -Compress
} finally { if ($child.Id -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
'@
$childEncoded = Encode-EnvironmentCommand ($childCode.Replace('__LEAF__', $leafEncoded))
$old = @{}
foreach ($name in @('OLLAMA_NO_CLOUD', 'OLLAMA_HOST', 'OLLAMA_MODELS')) { $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$passed = 0
try {
	foreach ($ambient in @('0', $null)) {
		if ($null -eq $ambient) { Remove-Item Env:OLLAMA_NO_CLOUD -ErrorAction SilentlyContinue }
		else { [Environment]::SetEnvironmentVariable('OLLAMA_NO_CLOUD', $ambient, 'Process') }
		[Environment]::SetEnvironmentVariable('OLLAMA_HOST', 'https://unowned.invalid:4444', 'Process')
		[Environment]::SetEnvironmentVariable('OLLAMA_MODELS', 'unowned-personal-models', 'Process')
		$start = New-OllamaModelStart $executable $models 18148 'qwen3:0.6b' $environment
		Assert-Environment ($start.FileName -ceq $executable -and -not $start.UseShellExecute) 'The actual builder uses the captured executable without shell lookup.'
		Assert-Environment ($start.Arguments -ceq 'pull "qwen3:0.6b"') 'The actual builder retains the literal pull request.'
		# Substitute only the command body with a bounded environment observer.
		# Its native descendant inherits normally; neither observer assigns env.
		$start.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $childEncoded
		$start.RedirectStandardOutput = $true
		$start.RedirectStandardError = $true
		$child = [Diagnostics.Process]::new(); $child.StartInfo = $start
		try {
			Assert-Environment ($child.Start()) 'The native environment observer starts.'
			if (-not $child.WaitForExit(20000)) { $child.Kill(); $child.WaitForExit(); throw 'The environment observer timed out.' }
			$stdout = $child.StandardOutput.ReadToEnd(); $stderr = $child.StandardError.ReadToEnd()
			Assert-Environment ($child.ExitCode -eq 0 -and $stderr.Length -eq 0) ('The native observer completes: ' + $stderr)
			$fact = $stdout | ConvertFrom-Json
			foreach ($observed in @($fact, $fact.descendant)) {
				Assert-Environment ($observed.cloud -ceq $environment['OLLAMA_NO_CLOUD']) ('The actual child and descendant carry the admitted cloud declaration; observed=' + $observed.cloud)
				Assert-Environment ($observed.host -ceq '127.0.0.1:18148') 'The actual child and descendant use the captured loopback origin.'
				Assert-Environment ($observed.models -ceq $models) 'The actual child and descendant use the managed model store.'
			}
		} finally { if ($child.Id -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
		if ($null -eq $ambient) {
			Assert-Environment (-not [Environment]::GetEnvironmentVariables('Process').Contains('OLLAMA_NO_CLOUD')) 'The parent cloud environment remains absent.'
		} else {
			Assert-Environment ([Environment]::GetEnvironmentVariable('OLLAMA_NO_CLOUD', 'Process') -ceq $ambient) 'The parent cloud environment is unchanged.'
		}
		Assert-Environment ($env:OLLAMA_HOST -ceq 'https://unowned.invalid:4444') 'The parent host environment is unchanged.'
		Assert-Environment ($env:OLLAMA_MODELS -ceq 'unowned-personal-models') 'The parent model environment is unchanged.'
		$passed++
		Write-Output ('PASS model child and descendant declaration ambient=' + $(if ($null -eq $ambient) { 'absent' } else { $ambient }))
	}
	$refused = $false
	try { New-OllamaModelStart $executable $models 18148 'qwen3:0.6b' $null | Out-Null } catch { $refused = $true }
	Assert-Environment $refused 'Missing admitted declaration refuses before any process is started.'
	$passed++; Write-Output 'PASS missing model declaration refuses before process creation'
} finally {
	foreach ($name in $old.Keys) {
		if ($null -eq $old[$name]) { Remove-Item ('Env:' + $name) -ErrorAction SilentlyContinue }
		else { [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process') }
	}
}
Write-Output ('RESULT passed=' + $passed + ' failed=0 builder_only=' + $BuilderOnly.IsPresent.ToString().ToLowerInvariant())
