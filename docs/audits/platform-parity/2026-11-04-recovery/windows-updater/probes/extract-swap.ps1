param([string]$SourcePath,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$Tokens=$null;$Errors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$Tokens,[ref]$Errors)
if($Errors.Count){throw 'Actual swap source did not parse'}
$Names=@('Diag','RemoveBest','WriteTerminal','PublishCopy','WriteClaim')
$Functions=@($Ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $Names})
if($Functions.Count -ne 5){throw 'Expected actual swap helper definitions'}
$Owner=@($Ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
if($Owner.Count -ne 1){throw 'Expected exact outer worker transaction'}
$Statements=$Owner[0].Body.Statements
$Start=-1
for($I=0;$I -lt $Statements.Count;$I++){if($Statements[$I].Extent.Text.StartsWith('$B=$CurrentExe+')){$Start=$I;break}}
if($Start -lt 0){throw 'Post-parent-exit production transaction not found'}
$Body=($Statements[$Start..($Statements.Count-1)] | ForEach-Object {$_.Extent.Text}) -join "`n"
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'actual-swap-helpers.ps1'),($Functions | ForEach-Object {$_.Extent.Text}) -join "`n")
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'actual-post-parent-swap.ps1'),$Body)
Write-Output ('EXTRACTED actual_helpers=5 actual_transaction_statements='+($Statements.Count-$Start)+' event_protocol_executed=0')
