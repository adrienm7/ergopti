# Native PnP/registry fixture ONLY: never touches real hardware or registry.
param([string]$Worker)
$ErrorActionPreference='Stop'
function Test-Path { param($Path) return $true }
function New-ItemProperty { param($Path,$Name,$Value,$PropertyType,[switch]$Force) }
function Get-PnpDevice {
  param([switch]$PresentOnly)
  if ($env:ERGOPTI_GESTURE_SCENARIO -eq 'none') { return @() }
  return [pscustomobject]@{Class='HIDClass';FriendlyName='I2C HID Device';InstanceId='fixture-device'}
}
function Disable-PnpDevice {
  [CmdletBinding()] param($InstanceId,[switch]$Confirm)
  if ($env:ERGOPTI_GESTURE_SCENARIO -eq 'disable_fail') { Write-Error 'Fixture disable refusal'; return }
}
function Enable-PnpDevice {
  [CmdletBinding()] param($InstanceId,[switch]$Confirm)
  if ($env:ERGOPTI_GESTURE_SCENARIO -eq 'enable_fail') { Write-Error 'Fixture enable refusal'; return }
}
function Start-Sleep { param($Milliseconds) }
& $Worker
exit $LASTEXITCODE
