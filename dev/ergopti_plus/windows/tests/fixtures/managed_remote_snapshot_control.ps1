# tests/fixtures/managed_remote_snapshot_control.ps1
# Literal wrapper ownership controls call the real snapshot helper, not a store.
param([Parameter(Mandatory = $true)][string]$SourcePath)
$ErrorActionPreference = 'Stop'
$Tokens = $null
$Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count -ne 0) { throw 'The snapshot producer source did not parse.' }
$Functions = @($Ast.FindAll({ param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $Node.Name -ceq 'Invoke-OwnedRootSnapshot'
}, $true))
if ($Functions.Count -ne 1) { throw 'The actual snapshot helper was not uniquely found.' }
. ([scriptblock]::Create($Functions[0].Extent.Text))
function New-ControlCertificate([string]$Thumbprint, [string]$Subject, [bool]$RefuseDispose = $false) {
    $Certificate = [pscustomobject]@{ Thumbprint = $Thumbprint; Subject = $Subject;
        Disposals = 0; RefuseDispose = $RefuseDispose }
    $Certificate | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposals++
        if ($this.RefuseDispose) { throw 'CONTROLLED_SNAPSHOT_RETIREMENT_REFUSAL' }
    }
    return $Certificate
}
foreach ($Case in @('absent', 'present', 'remove', 'duplicate', 'subject', 'remove_failure',
    'retirement_failure', 'primary_and_retirement')) {
    $Foreign = New-ControlCertificate 'FOREIGN' 'foreign subject'
    $Owned = New-ControlCertificate 'OWNED' 'owned subject' ($Case -in @('retirement_failure', 'primary_and_retirement'))
    $Certificates = @($Foreign, $Owned)
    if ($Case -ceq 'absent') { $Certificates = @($Foreign) }
    if ($Case -ceq 'duplicate') { $Certificates += New-ControlCertificate 'OWNED' 'owned subject' }
    if ($Case -in @('subject', 'primary_and_retirement')) { $Owned.Subject = 'different subject' }
    $Store = [pscustomobject]@{ Certificates = $Certificates; Removals = @(); Case = $Case }
    $Store | Add-Member -MemberType ScriptMethod -Name Remove -Value {
        param($Certificate)
        $this.Removals += $Certificate
        if ($this.Case -ceq 'remove_failure') { throw 'CONTROLLED_REMOVE_FAILURE' }
    }
    $Caught = $null
    $Count = $null
    try { $Count = Invoke-OwnedRootSnapshot $Store 'OWNED' 'owned subject' ($Case -in @('remove', 'remove_failure')) }
    catch { $Caught = $_ }
    foreach ($Certificate in $Certificates) {
        if ($Certificate.Disposals -ne 1) { throw 'Each acquired wrapper must retire exactly once, including foreign wrappers.' }
    }
    if ($Case -in @('absent', 'present', 'remove')) {
        $ExpectedCount = if ($Case -ceq 'absent') { 0 } else { 1 }
        if ($null -ne $Caught -or $Count -ne $ExpectedCount) { throw 'Exact root count changed during snapshot retirement.' }
    } elseif ($null -eq $Caught) { throw 'An independent snapshot refusal became successful.' }
    $ExpectedRemovals = if ($Case -in @('remove', 'remove_failure')) { 1 } else { 0 }
    if ($Store.Removals.Count -ne $ExpectedRemovals -or
        ($ExpectedRemovals -eq 1 -and -not [object]::ReferenceEquals($Store.Removals[0], $Owned))) {
        throw 'Only the exact owned root wrapper may reach Remove.'
    }
    if ($Case -ceq 'primary_and_retirement' -and
        ($Caught.Exception.Message -cne 'Owned certificate subject changed.' -or
        $Caught.Exception.Data['OwnedRootSnapshotRetirementDebt'] -isnot [bool] -or
        -not $Caught.Exception.Data['OwnedRootSnapshotRetirementDebt'])) {
        throw 'A retirement refusal replaced the primary identity refusal or lost its typed debt.'
    }
}
