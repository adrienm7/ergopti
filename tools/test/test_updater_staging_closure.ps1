# tools/test/test_updater_staging_closure.ps1
# Receive only the real factory assignments; no worker, output mutation or transport.
param([Parameter(Mandatory=$true)][string]$WorkerSourcePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($WorkerSourcePath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count -ne 0) { throw 'The actual staging source must parse.' }
$Factories = @($Ast.FindAll({param($Node)
    $Node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $Node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $Node.Left.VariablePath.UserPath -ceq 'OpenParentDestination'
}, $true))
if ($Factories.Count -ne 1) { throw 'The actual staging output factory must be unique.' }
# Include the factory's adjacent captured dependencies, never the enclosing
# native directory admission, worker body or module-loading statements.
$Statements = $Factories[0].Parent.Statements
$Index = [Array]::IndexOf([object[]]$Statements, $Factories[0])
if ($Index -lt 0) { throw 'The actual factory statement owner must exist.' }
$Start = $Index
while ($Start -gt 0 -and $Statements[$Start - 1] -is [Management.Automation.Language.AssignmentStatementAst]) { $Start-- }
$Assignments = ($Statements[$Start..$Index] | ForEach-Object { $_.Extent.Text }) -join "`n"
$Receive = {
    param([string]$Assignments, [string]$ExpectedIdentity)
    # A local helper has the same visibility boundary as the real dot-sourced
    # function; its inert result exposes exactly which arguments reached it.
    function Open-ErgoptiParentStagedOutput {
        param([string]$Path, [string]$Identity)
        if ($Path -ceq 'refused') { throw [InvalidOperationException]::new('Exact owned output was refused.') }
        return @{path=$Path; identity=$Identity}
    }
    $ParentExecutableIdentity = $ExpectedIdentity
    . ([scriptblock]::Create($Assignments))
    $ParentExecutableIdentity = 'changed after factory capture'
    ${function:Open-ErgoptiParentStagedOutput} = { throw 'Helper lookup authority changed after capture.' }
    foreach ($Path in @('C:\owned\staged.exe', ('C:\owned\' + [char]0x00e9 + ' space.exe'))) {
        $Received = @(& $OpenParentDestination $Path 524288)
        if ($Received.Count -ne 1 -or $Received[0] -isnot [hashtable] -or
            $Received[0].Count -ne 2 -or $Received[0].path -cne $Path -or
            $Received[0].identity -cne $ExpectedIdentity) {
            throw 'The actual factory must retain its captured helper and exact identity.'
        }
    }
    $Failure = $null
    try { & $OpenParentDestination 'refused' 524288 } catch { $Failure = $_ }
    if ($null -eq $Failure -or $Failure.Exception -isnot [InvalidOperationException] -or
        $Failure.Exception.Message -cne 'Exact owned output was refused.') {
        throw 'The actual factory must propagate its captured helper refusal.'
    }
}
foreach ($Identity in @('11111111:0000000000000001', 'abcdef01:1234567890abcdef')) {
    $Output = @(& $Receive $Assignments $Identity)
    if ($Output.Count -ne 0) { throw 'The factory controls must emit no incidental pipeline output.' }
}
Write-Output 'PASS: actual staging closure checks=6 native=0 network=0 output_io=0'
