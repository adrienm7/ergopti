$ErrorActionPreference = 'Stop'
$ResultPath = '/workspace/scratch/deep-parity/windows-gestures/worker.result'
$ResultStage = $ResultPath + '.stage'
$ErgoptiExitCode = 1
$disabled = @()
try {
  $devs = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq 'HIDClass' -and $_.FriendlyName -match 'Input Configuration|I2C HID' })
  if ($devs.Count -eq 0) { throw 'No Precision Touchpad HID device found.' }
  foreach ($d in $devs) { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop; $disabled += $d }
  Start-Sleep -Milliseconds 500
  foreach ($d in $devs) { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop }
  $ErgoptiExitCode = 0
} catch {} finally { foreach ($d in $disabled) { try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop } catch {} } }
try {
  [System.IO.File]::WriteAllText($ResultStage, [string]$ErgoptiExitCode, [System.Text.Encoding]::ASCII)
  [System.IO.File]::Move($ResultStage, $ResultPath)
} catch { Remove-Item -LiteralPath $ResultStage -Force -ErrorAction SilentlyContinue; exit 1 }
exit $ErgoptiExitCode
