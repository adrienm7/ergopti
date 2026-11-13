; tests/fixtures/core/system_action_lifecycle_timer_body.ahk

#Requires AutoHotkey v2.0

class _SALTC_System extends SystemControl {
 __New() {
  this.ClipboardEffects := 0, this.DisplayEffects := 0
 }
 ClearClipboard() {
  this.ClipboardEffects += 1
  return true
 }
 PostBroadcast(Msg, WParam, LParam) {
  _LCPC_Require(Msg == 0x112 && WParam == 0xF170 && LParam == 2, "The real display message must reach only the private effect port")
  this.DisplayEffects += 1
  return true
 }
}

_SALTC_Main() {
 global _LCPC_World, _ConfigDir, _UserProgramPaused
 global GESTURE_SYS_DISPLAY_SLEEP_DELAY_MS, GESTURE_SYS_WM_SYSCOMMAND, GESTURE_SYS_SC_MONITORPOWER, GESTURE_SYS_MONITOR_OFF
 _LCPC_Require(A_Args.Length == 3, "Mode, private directory and shared source are required")
 Mode := A_Args[1]
 _LCPC_Require(Mode == "queued" || Mode == "display-queued" || Mode == "same-epoch" || Mode == "display-same-epoch", "Unknown timer mode")
 _LCPC_World := {Ports: Map()}, _ConfigDir := A_Args[2]
 TimingsLoadShared(A_Args[3]), KeystatsWalkerLoadTimings()
 LoggerSetTestSink((*) => 0)
 Sys := _SALTC_System(), Done := {Value: false}
 Display := InStr(Mode, "display-") == 1
 Pauses := Mode == "queued" || Mode == "display-queued"
 GESTURE_SYS_DISPLAY_SLEEP_DELAY_MS := 1000
 GESTURE_SYS_WM_SYSCOMMAND := 0x112, GESTURE_SYS_SC_MONITORPOWER := 0xF170, GESTURE_SYS_MONITOR_OFF := 2
 PriorCritical := Critical("On")
 Barrier := (*) => Done.Value := true
 try {
  _LCPC_Require(!A_IsSuspended && !_UserProgramPaused, "The genuine lifecycle must begin resumed")
  if Display
   GestureSysSleepDisplays(Sys)
  else
   _GestureMakeSystemRunner("clear_clipboard", GestureSysClearClipboard.Bind(Sys), Sys).Call()
  _LCPC_Require(Sys.ClipboardEffects == 0 && Sys.DisplayEffects == 0, "The default native scheduler must defer all private effects")
  if Pauses
   _TNLC_RunLifecycle()
  _LCPC_Require(!A_IsSuspended && (!Pauses || _LCPC_World.Ports.Count == 17), "The complete real resume must precede native timer delivery")
  SetTimer(Barrier, -1500)
 } finally Critical(PriorCritical)
 Started := A_TickCount
 try {
  while !Done.Value && A_TickCount - Started < 7000
   Sleep(10)
  _LCPC_Require(Done.Value, "The real timer barrier must be delivered")
  Effects := Display ? Sys.DisplayEffects : Sys.ClipboardEffects
  FileAppend("RECEIPT system-action-lifecycle mode=" . Mode . " clipboard=" . Sys.ClipboardEffects . " display=" . Sys.DisplayEffects . " ports=" . _LCPC_World.Ports.Count . " barrier=" . Done.Value . " suspended=" . A_IsSuspended . "`n", "*")
  _LCPC_Require(Effects == (Pauses ? 0 : 1), "Pre-pause system actions must not gain effect authority after resume; same-epoch actions must run exactly once")
 } finally {
  SetTimer(Barrier, 0)
  LoggerClearTestSink()
  Suspend(false)
 }
}
try {
 _SALTC_Main()
 FileAppend("PASS system-action-lifecycle " . A_Args[1] . "`n", "*")
 ExitApp(0)
} catch Any as _SALTC_Failure {
 FileAppend("FAIL system-action-lifecycle " . _SALTC_Failure.Message . " [" . _SALTC_Failure.File . ":" . _SALTC_Failure.Line . "]`n", "*")
 ExitApp(1)
}
