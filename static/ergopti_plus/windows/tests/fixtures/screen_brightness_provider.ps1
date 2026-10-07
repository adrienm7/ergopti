# tests/fixtures/screen_brightness_provider.ps1
# Replays the actual shipped worker in a native PowerShell child. Provider doubles
# do not touch physical screens; they assert the real WMI ABI and readback protocol.
param([string]$Worker, [string]$FixturePolicyPath, [string]$Action, [string]$Mode,
    [string]$FixtureDiagnosticPath = '', [switch]$FixturePolicyProbe)
# Optional observation only: last successfully written closed phase. A refused
# diagnostic write stops further observation and never replaces worker outcomes.
$script:DiagnosticAvailable = $FixtureDiagnosticPath -cne ''
function Set-FixtureDiagnosticPhase {
    param([string]$Phase)
    if (-not $script:DiagnosticAvailable) { return }
    try {
        [System.IO.File]::WriteAllText($FixtureDiagnosticPath, $Phase, [System.Text.UTF8Encoding]::new($false))
    } catch {
        $script:DiagnosticAvailable = $false
    }
}
Set-FixtureDiagnosticPhase 'fixture_enter'
# Opt-in phase comparator only. Defining these functions performs no original
# cmdlet lookup/module import or policy read. Module-qualified originals resolve
# lazily only when the unchanged shipped worker reaches each actual command.
# Command lookup differs from the five ordinary native cases; these facts alone
# cannot establish the cause of a previous uninstrumented timeout.
if ($FixturePolicyProbe) {
    $script:PolicyProbeActive = $false
    function Get-Content {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)][string]$LiteralPath,
            [switch]$Raw, [string]$Encoding)
        if (-not $script:PolicyProbeActive -or $LiteralPath -cne $FixturePolicyPath -or
            -not $Raw.IsPresent -or $Encoding -cne 'UTF8') {
            throw 'The policy comparator must retain the exact worker command.'
        }
        # This is the first worker policy command hook, not a script-entry
        # breakpoint: no fact is inferred about earlier parse/binding steps.
        Set-FixtureDiagnosticPhase 'worker_policy_entry'
        Set-FixtureDiagnosticPhase 'policy_read'
        $PolicyProbeRead = @(Microsoft.PowerShell.Management\Get-Content `
            -LiteralPath $LiteralPath -Raw:$Raw -Encoding $Encoding)
        Set-FixtureDiagnosticPhase 'policy_read_done'
        $PolicyProbeRead
    }
    function ConvertFrom-Json {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][string]$InputObject)
        process {
            if ($script:PolicyProbeActive) { Set-FixtureDiagnosticPhase 'policy_decode' }
            Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject
        }
    }
}
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
    Set-FixtureDiagnosticPhase $script:Stage
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
    Set-FixtureDiagnosticPhase 'write'
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
Set-FixtureDiagnosticPhase 'before_worker'
if ($FixturePolicyProbe) {
    $script:PolicyProbeActive = $true
    try {
        $WorkerOutput = @(. $Worker -PolicyPath $FixturePolicyPath -Action $Action)
    } finally {
        $script:PolicyProbeActive = $false
    }
} else {
    $WorkerOutput = @(. $Worker -PolicyPath $FixturePolicyPath -Action $Action)
}
$WorkerExit = $LASTEXITCODE
Set-FixtureDiagnosticPhase 'worker_return'
if ($WorkerExit -isnot [int] -or $WorkerOutput.Count -ne 1) {
    throw 'The actual worker must provide one native exit and JSON receipt.'
}
$ProbeReceipt = $WorkerOutput[0] | ConvertFrom-Json
$PolicyType = if ($Policy -is [string]) { 'string' } elseif ($Policy -is [pscustomobject]) { 'object' } else { 'unavailable' }
# These fixture-only fields are bounded closed observations, never provider data.
$ProbeReceipt | Add-Member -NotePropertyName fixture_calls -NotePropertyValue $script:Calls
$ProbeReceipt | Add-Member -NotePropertyName fixture_stage -NotePropertyValue $script:Stage
$ProbeReceipt | Add-Member -NotePropertyName fixture_policy_type -NotePropertyValue $PolicyType
Set-FixtureDiagnosticPhase 'emit'
$ProbeReceipt | ConvertTo-Json -Depth 5 -Compress
exit $WorkerExit
