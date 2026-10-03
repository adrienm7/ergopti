# tests/fixtures/screen_brightness_provider.ps1
# Replays the actual shipped worker in a native PowerShell child. Provider doubles
# do not touch physical screens; they assert the real WMI ABI and readback protocol.
param([string]$Worker, [string]$FixturePolicyPath, [string]$Action, [string]$Mode)
$script:Calls = 0
$script:Written = $false
$script:Stage = 'before_provider'
function Get-CimInstance {
    param([string]$Namespace, [string]$ClassName)
    if ($Namespace -cne 'root/WMI') { throw 'Wrong native namespace.' }
    $script:Stage = switch -CaseSensitive ($ClassName) {
        'WmiMonitorBrightness' { if ($script:Written) { 'readback' } else { 'enumerate_monitors' } }
        'WmiMonitorBrightnessMethods' { 'enumerate_methods' }
        default { throw 'Wrong native class.' }
    }
    if ($Mode -eq 'unsupported') { return @() }
    switch -CaseSensitive ($ClassName) {
        'WmiMonitorBrightness' {
            $Value = if ($script:Written -and $Mode -ne 'readback-refused') { 45 } else { 40 }
            return [pscustomobject]@{ Active = $true; InstanceName = 'owned-display'; CurrentBrightness = $Value }
        }
        'WmiMonitorBrightnessMethods' {
            return [pscustomobject]@{ Active = $true; InstanceName = 'owned-display' }
        }
        default { throw 'Wrong native class.' }
    }
}
function Invoke-CimMethod {
    param($InputObject, [string]$MethodName, [hashtable]$Arguments)
    if ($InputObject.InstanceName -cne 'owned-display' -or $MethodName -cne 'WmiSetBrightness' -or
        $Arguments.Timeout -isnot [uint32] -or $Arguments.Brightness -isnot [byte] -or
        $Arguments.Timeout -ne 0 -or $Arguments.Brightness -ne 45 -or $Arguments.Count -ne 2) {
        throw 'Wrong native method or brightness target.'
    }
    $script:Stage = 'write'
    $script:Calls++
    if ($script:Calls -ne 1) { throw 'Duplicated native write.' }
    $script:Written = $true
    return [pscustomobject]@{ ReturnValue = $(if ($Mode -eq 'write-refused') { 1 } else { 0 }) }
}
# Dot sourcing keeps these WMI doubles in scope. Its local variable constraints
# also apply to the worker: reintroduce the original typed Policy collision only
# in the negative control, never in an ordinary native provider replay.
if ($Mode -eq 'typed-policy-collision') { [string]$Policy = $FixturePolicyPath }
# A nested script's exit updates LASTEXITCODE but does not become this -File
# process's exit. Retain that exact native result before any receipt formatting.
$global:LASTEXITCODE = 0
$WorkerOutput = @(. $Worker -PolicyPath $FixturePolicyPath -Action $Action)
$WorkerExit = $LASTEXITCODE
if ($WorkerExit -isnot [int] -or $WorkerOutput.Count -ne 1) {
    throw 'The actual worker must provide one native exit and JSON receipt.'
}
$ProbeReceipt = $WorkerOutput[0] | ConvertFrom-Json
$PolicyType = if ($Policy -is [string]) { 'string' } elseif ($Policy -is [pscustomobject]) { 'object' } else { 'unavailable' }
# These fixture-only fields are bounded closed observations, never provider data.
$ProbeReceipt | Add-Member -NotePropertyName fixture_calls -NotePropertyValue $script:Calls
$ProbeReceipt | Add-Member -NotePropertyName fixture_stage -NotePropertyValue $script:Stage
$ProbeReceipt | Add-Member -NotePropertyName fixture_policy_type -NotePropertyValue $PolicyType
$ProbeReceipt | ConvertTo-Json -Depth 5 -Compress
exit $WorkerExit
