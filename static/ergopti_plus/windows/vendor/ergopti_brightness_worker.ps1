# vendor/ergopti_brightness_worker.ps1
# A Job-owned child contains potentially stalled WMI providers off the input thread.
param(
    [Parameter(Mandatory = $true)][string]$PolicyPath,
    [Parameter(Mandatory = $true)][string]$Action
)
# This child loads only modules belonging to its actual PowerShell runtime.
# A PS7 parent can pass incompatible module paths through the native launcher.
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Receipt = @{ version = 1; action = $Action; status = 'refused'; displays = @() }
try {
    $Policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Direction = $Policy.actions.PSObject.Properties[$Action].Value.direction
    if ($Policy.version -ne 1 -or $Direction -notin @(-1, 1)) {
        throw 'Invalid screen brightness action policy.'
    }
    $Monitors = @(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness |
        Where-Object { $_.Active })
    $Methods = @(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods |
        Where-Object { $_.Active })
    if ($Monitors.Count -eq 0 -or $Methods.Count -eq 0) {
        $Receipt.status = 'unsupported'
    } else {
        if ($Monitors.Count -gt $Policy.max_displays) { throw 'Too many native backlight providers.' }
        # Resolve the entire cohort before any write; a provider mismatch may not
        # silently adjust only the first screen or an unrelated keyboard LED.
        $Cohort = @()
        foreach ($Monitor in $Monitors) {
            $Matching = @($Methods | Where-Object { $_.InstanceName -ceq $Monitor.InstanceName })
            if ($Matching.Count -ne 1) { throw 'Ambiguous native backlight provider.' }
            $Before = [int]$Monitor.CurrentBrightness
            if ($Before -lt 0 -or $Before -gt 100) { throw 'Invalid native backlight reading.' }
            [int]$Target = [Math]::Max(0, [Math]::Min(100, $Before + $Direction * $Policy.step_percent))
            $Cohort += @{ instance = $Monitor.InstanceName; method = $Matching[0]; before = $Before; target = $Target }
        }
        foreach ($Item in $Cohort) {
            $Result = Invoke-CimMethod -InputObject $Item.method -MethodName WmiSetBrightness `
                -Arguments @{ Timeout = [uint32]0; Brightness = [byte]$Item.target }
            if ($Result.ReturnValue -ne 0) { throw 'Native backlight write refused.' }
        }
        $Readback = @(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness |
            Where-Object { $_.Active })
        foreach ($Item in $Cohort) {
            $Actual = @($Readback | Where-Object { $_.InstanceName -ceq $Item.instance })
            if ($Actual.Count -ne 1 -or [int]$Actual[0].CurrentBrightness -ne $Item.target) {
                throw 'Native backlight target was not acknowledged.'
            }
            $Receipt.displays += @{ before = $Item.before; target = $Item.target; after = [int]$Actual[0].CurrentBrightness }
        }
        $Receipt.status = 'applied'
    }
} catch {
    # Invalid-class/no-provider is a truthful capability refusal. Other failures,
    # including readback mismatch after a write, must never become success.
    if ($_.Exception.GetType().FullName -ceq 'Microsoft.Management.Infrastructure.CimException' -and
        $_.Exception.NativeErrorCode.ToString() -ceq 'InvalidClass') { $Receipt.status = 'unsupported' }
}
$Receipt | ConvertTo-Json -Depth 5 -Compress
if ($Receipt.status -eq 'refused') { exit 1 }
