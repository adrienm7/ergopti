# tests/fixtures/screen_brightness_provider.ps1
# Replays the actual shipped worker in a native PowerShell child. Provider doubles
# do not touch physical screens; they assert the real WMI ABI and readback protocol.
param([string]$Worker, [string]$Policy, [string]$Action, [string]$Mode)
$script:Calls = 0
$script:Written = $false
function Get-CimInstance {
    param([string]$Namespace, [string]$ClassName)
    if ($Namespace -cne 'root/WMI') { throw 'Wrong native namespace.' }
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
        $Arguments.Timeout -ne 0 -or $Arguments.Brightness -ne 45 -or $Arguments.Count -ne 2) {
        throw 'Wrong native method or brightness target.'
    }
    $script:Calls++
    if ($script:Calls -ne 1) { throw 'Duplicated native write.' }
    $script:Written = $true
    return [pscustomobject]@{ ReturnValue = $(if ($Mode -eq 'write-refused') { 1 } else { 0 }) }
}
. $Worker -PolicyPath $Policy -Action $Action
