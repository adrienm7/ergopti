; tests/fixtures/core/system_action_inflight_lifecycle_body.ahk

#Requires AutoHotkey v2.0

; These private IO ports model only query results and record requested effects.
; No registry value, application window or audio endpoint is changed.
class _SAIL_EjectItem {
 __New(Sys, Name) {
  this.Sys := Sys
  this.Name := Name
 }
 InvokeVerb(Verb) {
  _LCPC_Require(Verb == "Eject", "The private drive supports only its exact eject request")
  this.Sys.Effects.Push("eject:" . this.Name)
  this.Sys._EjectAt("between")
 }
}
class _SAIL_EjectComputer {
 __New(Sys) => this.Sys := Sys
 ParseName(Name) {
  _LCPC_Require(Name == "E:\" || (this.Sys.Action == "ejectbetween" && Name == "F:\"), "Only the explicitly private E/F drives may be requested")
  this.Sys._EjectAt("item")
  return _SAIL_EjectItem(this.Sys, Name)
 }
}
class _SAIL_EjectShell {
 __New(Sys) => this.Sys := Sys
 Namespace(Id) {
  _LCPC_Require(Id == GESTURE_SYS_CSIDL_DRIVES, "The real drive namespace constant must reach the private port")
  this.Sys._EjectAt("namespace")
  return _SAIL_EjectComputer(this.Sys)
 }
}

class _SAIL_System extends SystemControl {
 __New(Pauses, Action) {
  this.Action := Action
  this.EjectPhase := Action == "ejectnamespace" ? "namespace" : Action == "ejectitem" ? "item" : Action == "ejectbetween" ? "between" : "drives"
  this.Pauses := Pauses, this.Queries := 0, this.PulseCompleted := false
  this.Effects := []
 }
 _Read() {
  this.Queries += 1
  if this.Pauses {
   _LCPC_Require(this.Queries == 1, "Only the first genuine public-action query may pulse lifecycle")
   _TNLC_RunLifecycle()
   this.PulseCompleted := true
  }
 }
 _EjectAt(Phase) {
  if Phase == this.EjectPhase && this.Queries == 0
   this._Read()
 }
 RemovableDrives() {
  this._EjectAt("drives")
  return this.Action == "ejectbetween" ? "EF" : "E"
 }
 ShellApplication() => _SAIL_EjectShell(this)
 ReadDword(Key, Name) {
  _LCPC_Require(Name == "AppsUseLightTheme", "The real theme query must reach its expected registry value")
  this._Read()
  return 1
 }
 WriteDword(Key, Name, Value) {
  this.Effects.Push("write:" . Name . ":" . Value)
 }
 BroadcastSettingChange(Area) {
  this.Effects.Push("broadcast:" . Area)
  return true
 }
 ActiveWindow() {
  this._Read()
  return {Hwnd: 0x4321, Pid: 7001, Class: "Notepad"}
 }
 OwnPid() => 4000
 ShellPid() => 6000
 WindowsOfProcess(Pid) {
  _LCPC_Require(Pid == 7001, "Only the original private window owner can be enumerated")
  return [0x4321]
 }
 PostClose(Hwnd) {
  _LCPC_Require(Hwnd == 0x4321, "Only the explicit private close port can receive a request")
  this.Effects.Push("close")
  return true
 }
 CaptureMuted() {
  this._Read()
  return false
 }
 SetCaptureMuted(Muted) {
  _LCPC_Require(Muted == 1, "The genuine microphone action must request its expected toggle")
  this.Effects.Push("mute")
 }
}

_SAIL_Main() {
 global _LCPC_World, _ConfigDir, _UserProgramPaused
 _LCPC_Require(A_Args.Length == 3, "Mode, private directory and shared source are required")
 Mode := A_Args[1], Fields := StrSplit(Mode, "-")
 _LCPC_Require(Fields.Length == 2 && (Fields[1] == "theme" || Fields[1] == "quit" || Fields[1] == "mic" || Fields[1] == "eject"
  || Fields[1] == "ejectnamespace" || Fields[1] == "ejectitem" || Fields[1] == "ejectbetween")
  && (Fields[2] == "pulse" || Fields[2] == "same"), "Unknown in-flight lifecycle mode")
 Action := Fields[1], Pauses := Fields[2] == "pulse"
 _LCPC_World := {Ports: Map()}, _ConfigDir := A_Args[2]
 TimingsLoadShared(A_Args[3]), KeystatsWalkerLoadTimings()
 Logs := []
 LoggerSetTestSink((Line) => Logs.Push(Line))
 Sys := _SAIL_System(Pauses, Action), Done := {Value: false}
 ActionFn := Action == "theme" ? GestureSysToggleDarkMode : Action == "quit" ? GestureSysQuitFrontmostApp : Action == "mic" ? GestureSysMicMuteToggle : GestureSysEjectAllDisks
 Barrier := (*) => Done.Value := true
 PreviousCritical := Critical("On")
 try {
  _LCPC_Require(!A_IsSuspended && !_UserProgramPaused, "The genuine lifecycle must begin resumed")
  _GestureMakeSystemRunner(Action, ActionFn.Bind(Sys), Sys).Call()
  _LCPC_Require(Sys.Queries == 0 && Sys.Effects.Length == 0, "The default native scheduler must defer the genuine action")
  SetTimer(Barrier, -250)
 } finally Critical(PreviousCritical)
 Started := A_TickCount
 try {
  while !Done.Value && A_TickCount - Started < 7000
   Sleep(10)
  Errors := 0
  for Line in Logs
   Errors += InStr(Line, "ERROR") ? 1 : 0
  FileAppend("RECEIPT system-action-inflight-lifecycle mode=" . Mode . " queries=" . Sys.Queries
   . " effects=" . Sys.Effects.Length . " pulse=" . Sys.PulseCompleted . " ports=" . _LCPC_World.Ports.Count
   . " barrier=" . Done.Value . " suspended=" . A_IsSuspended . " errors=" . Errors . "`n", "*")
  for Effect in Sys.Effects
   FileAppend("EFFECT system-action-inflight-lifecycle " . Effect . "`n", "*")
  _LCPC_Require(Done.Value && Sys.Queries == 1 && Errors == 0, "Real timer delivery must reach exactly one complete query without hidden dependency failures")
  _LCPC_Require(!A_IsSuspended && !_UserProgramPaused && Sys.PulseCompleted == Pauses
   && _LCPC_World.Ports.Count == (Pauses ? 17 : 0), "A pulse must complete the genuine full suspend/resume before the private first effect")
  _LCPC_Require(Sys.Effects.Length == (Pauses ? (Action == "ejectbetween" ? 1 : 0) : (Action == "theme" ? 3 : Action == "ejectbetween" ? 2 : 1)),
   "An in-flight pre-pause read cannot authorize the first native effect after resume; a same-epoch action must retain its full transaction")
  if Pauses && Action == "ejectbetween"
   _LCPC_Require(Sys.Effects[1] == "eject:E:\", "The acknowledged first effect must belong only to private E, never F")
  if !Pauses {
   Expected := Action == "theme" ? ["write:AppsUseLightTheme:0", "write:SystemUsesLightTheme:0", "broadcast:ImmersiveColorSet"] : Action == "ejectbetween" ? ["eject:E:\", "eject:F:\"] : [Action == "quit" ? "close" : Action == "mic" ? "mute" : "eject:E:\"]
   for Index, Effect in Expected
    _LCPC_Require(Sys.Effects[Index] == Effect, "The same-epoch control must request the exact established effects in order")
  }
 } finally {
  SetTimer(Barrier, 0)
  LoggerClearTestSink()
  Suspend(false)
 }
}
try {
 _SAIL_Main()
 FileAppend("PASS system-action-inflight-lifecycle " . A_Args[1] . "`n", "*")
 ExitApp(0)
} catch Any as _SAIL_Failure {
 FileAppend("FAIL system-action-inflight-lifecycle " . _SAIL_Failure.Message . " [" . _SAIL_Failure.File . ":" . _SAIL_Failure.Line . "]`n", "*")
 ExitApp(1)
}
