# tests/fixtures/managed_remote_trust_diagnostic.ps1
# Exercise the real receipt publisher without loading the native fixture body.
param([string]$SourcePath, [string]$StatePath)
$ErrorActionPreference = 'Stop'
$Tokens = $null
$Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count -ne 0) { throw 'Fixture publisher source did not parse.' }
$Functions = @($Ast.FindAll({ param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Publish-State'
}, $true))
if ($Functions.Count -ne 1) { throw 'The real fixture publisher was not uniquely found.' }
. ([scriptblock]::Create($Functions[0].Extent.Text))
$script:NativeReads = 0
$Native = [pscustomobject]@{}
$Native | Add-Member -MemberType ScriptProperty -Name Version -Value {
    $script:NativeReads++
    throw 'Controlled native observation is unavailable.'
}
$Fixture = [pscustomobject]@{ NativeTls = $Native }
$State = @{ version = 1; state = 'ready'; phase = 'untrusted'; sequence = 10;
    root_removed = $false; service_stopped = $false; server_tls_version = 'cached' }
$Steps = @('event_received', 'before_open', 'before_enumeration', 'before_export',
    'before_add', 'after_add', 'before_postcheck', 'before_close')
$Sequence = 10
foreach ($Step in $Steps) {
    Publish-State -TrustStep $Step
    $Sequence++
    $Receipt = [IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
    if ($Receipt.trust_step -cne $Step -or $Receipt.sequence -ne $Sequence -or
        $Receipt.phase -cne 'untrusted' -or $Receipt.state -cne 'ready' -or
        $Receipt.root_removed -or $Receipt.service_stopped -or
        $Receipt.server_tls_version -cne 'cached' -or $script:NativeReads -ne 0) {
        throw 'A trust checkpoint changed acceptance state or read native observations.'
    }
}
$Rejected = $false
try { Publish-State -TrustStep 'PRIVATE_INVALID_STEP' } catch { $Rejected = $true }
if (-not $Rejected -or $State.sequence -ne $Sequence -or $State.trust_step -cne 'before_close') {
    throw 'The checkpoint publisher did not reject an unknown step before mutation.'
}
Publish-State
if ($script:NativeReads -ne 1 -or $State.sequence -ne ($Sequence + 1)) {
    throw 'The original observation publisher no longer retains its behavior.'
}
[Console]::Out.WriteLine('OWNED_TRUST_DIAGNOSTIC_PASS')
