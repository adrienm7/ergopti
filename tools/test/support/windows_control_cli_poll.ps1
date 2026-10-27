# tools/test/support/windows_control_cli_poll.ps1
# Build the actual public poll receiver without executing its Windows endpoint.
param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'The actual control CLI cannot be parsed.' }
$definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
if ($definitions.Count -lt 1) { throw 'The actual CLI functions are absent.' }
$statements = @($ast.EndBlock.Statements)
$starts = @(for ($index = 0; $index -lt $statements.Count; $index++) {
	$statement = $statements[$index]
	if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
		$statement.Left -is [Management.Automation.Language.VariableExpressionAst] -and
		$statement.Left.VariablePath.UserPath -ceq 'resultPath') { $index }
})
if ($starts.Count -ne 1) { throw 'The actual public result receiver is not unique.' }
$prelude = @'
param([string]$Folder, [string]$SpecPath, [string]$RequestId, [int]$DriverPid, [int]$TimeoutMs)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$spec = Get-Content -Raw -Encoding UTF8 -LiteralPath $SpecPath | ConvertFrom-Json
'@
$body = $prelude + "`n" + (($definitions | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" +
	(($statements[$starts[0]..($statements.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n"
[IO.File]::WriteAllText($Destination, $body, [Text.UTF8Encoding]::new($false))
