$ErrorActionPreference = 'Stop'
$ResultPath = '/workspace/scratch/deep-parity/windows-gestures/worker.result'
$ResultStage = $ResultPath + '.stage'
$ErgoptiExitCode = 1
$Reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'
if (-not (Test-Path $Reg)) { New-Item -Path $Reg -Force | Out-Null }
$V = [ordered]@{
  'ThreeFingerSlideEnabled' = 65535
  'ThreeFingerTapEnabled' = 65535
  'FourFingerSlideEnabled' = 65535
  'FourFingerTapEnabled' = 65535
  'CustomThreeFingerTap' = 7
  'CustomThreeFingerTapKeyParams' = 7340039
  'ThreeFingerTapAction' = 65535
  'ThreeFingerUp' = 65535
  'ThreeFingerUpKeyParams' = 7405575
  'ThreeFingerSlideUpAction' = 65535
  'ThreeFingerDown' = 65535
  'ThreeFingerDownKeyParams' = 7471111
  'ThreeFingerSlideDownAction' = 65535
  'ThreeFingerLeft' = 65535
  'ThreeFingerLeftKeyParams' = 7536647
  'ThreeFingerSlideLeftAction' = 65535
  'ThreeFingerRight' = 65535
  'ThreeFingerRightKeyParams' = 7602183
  'ThreeFingerSlideRightAction' = 65535
  'CustomFourFingerTap' = 7
  'CustomFourFingerTapKeyParams' = 7667719
  'FourFingerTapAction' = 65535
  'FourFingerUp' = 65535
  'FourFingerUpKeyParams' = 7733255
  'FourFingerSlideUpAction' = 65535
  'FourFingerDown' = 65535
  'FourFingerDownKeyParams' = 7798791
  'FourFingerSlideDownAction' = 65535
  'FourFingerLeft' = 65535
  'FourFingerLeftKeyParams' = 7864327
  'FourFingerSlideLeftAction' = 65535
  'FourFingerRight' = 65535
  'FourFingerRightKeyParams' = 7929863
  'FourFingerSlideRightAction' = 65535
}
try {
  foreach ($n in $V.Keys) {
    New-ItemProperty -Path $Reg -Name $n -Value $V[$n] -PropertyType DWord -Force | Out-Null
  }
  $devs = Get-PnpDevice -PresentOnly | Where-Object {
    $_.Class -eq 'HIDClass' -and $_.FriendlyName -match 'Input Configuration|I2C HID'
  }
  foreach ($d in $devs) {
    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 500
  foreach ($d in $devs) {
    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
  }
  $ErgoptiExitCode = 0
} catch {
}
try {
  [System.IO.File]::WriteAllText($ResultStage, [string]$ErgoptiExitCode, [System.Text.Encoding]::ASCII)
  [System.IO.File]::Move($ResultStage, $ResultPath)
} catch { Remove-Item -LiteralPath $ResultStage -Force -ErrorAction SilentlyContinue; exit 1 }
exit $ErgoptiExitCode
