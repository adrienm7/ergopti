; tests/fixtures/core/system_action_confirmed_lifecycle_body.ahk

#Requires AutoHotkey v2.0

class _SCL_Document {
 __New(Sys) => this.Sys := Sys
 SelectedItems() => [{Path: this.Sys.Path}]
}
class _SCL_Shell {
 __New(Sys) => this.Sys := Sys
 Windows() => [{HWND: 0x4321, Document: _SCL_Document(this.Sys)}]
}
class _SCL_System extends SystemControl {
 __New(Action, Pauses) {
  this.Action := Action, this.Pauses := Pauses, this.Queries := 0
  this.Snapshots := 0, this.LiveReads := 0, this.Releases := 0, this.PulseCompleted := false
  this.Effects := [], this.Path := "C:\sail_private_not_created\file.txt"
 }
 _Read() {
  this.Queries += 1
  _LCPC_Require(this.Queries == 1, "Only the selected private query may pulse the lifecycle")
  if this.Pauses {
   _TNLC_RunLifecycle()
   this.PulseCompleted := true
  }
 }
 WindowSnapshot(Hwnd) {
  _LCPC_Require(Hwnd == 0x4321, "Only the exact retained private HWND may be inspected")
  this.Snapshots += 1
  if (this.Action == "wrapper" && this.Snapshots == 1)
    || (this.Action == "forcefinal" && this.Snapshots == 3)
   this._Read()
  return {Hwnd: 0x4321, Pid: 7001, Class: this.Action == "forcefinal" ? "Notepad" : "CabinetWClass"}
 }
 ActiveWindow() {
  throw Error("A confirmed action cannot acquire a new native foreground target")
 }
 AcquireProcessTarget(Pid) {
  throw Error("A confirmed action cannot acquire a new native process capability")
 }
 Notify(Text) {
  throw Error("The confirmed happy-path probe must not show a native notification")
 }
 EnumerateUnblockFiles(Path) {
  throw Error("The private selected item is a file and must never enumerate a native directory")
 }
 OwnPid() => 4000
 ShellPid() => 6000
 ShellApplication() => _SCL_Shell(this)
 ActiveExplorerTab(Hwnd) {
  _LCPC_Require(Hwnd == 0x4321, "Only the private approved Explorer frame may be read")
  return 0
 }
 IsDirectory(Path) {
  _LCPC_Require(Path == this.Path, "Only the exact approved private selection may be inspected")
  if this.Action == "unblockdirectory"
   this._Read()
  return false
 }
 DeleteZoneIdentifier(Path) {
  _LCPC_Require(Path == this.Path, "Only the exact private selected path may reach the recording mutation port")
  this.Effects.Push("unblock:" . Path)
  return "removed"
 }
 ProcessTargetIsLive(Lease) {
  _LCPC_Require(Lease.Handle == 0xF00D && Lease.Pid == 7001,
   "Only the unreleased private process capability may be validated")
  this.LiveReads += 1
  return true
 }
 TerminateProcessTarget(Lease) {
  _LCPC_Require(Lease.Handle == 0xF00D && Lease.Pid == 7001,
   "Only the exact retained private capability may reach the recording termination port")
  this.Effects.Push("terminate:7001")
  return true
 }
 ReleaseProcessTarget(Lease) {
  _LCPC_Require(Lease.Handle == 0xF00D && Lease.Pid == 7001 && this.Releases == 0,
   "The private process capability must retire exactly once")
  this.Releases += 1
  Lease.Handle := 0
 }
}
_SCL_Main() {
 global _LCPC_World, _ConfigDir, _UserProgramPaused
 _LCPC_Require(A_Args.Length == 3, "Mode, private directory and shared source are required")
 Mode := A_Args[1], Fields := StrSplit(Mode, "-")
 _LCPC_Require(Fields.Length == 2 && (Fields[1] == "wrapper" || Fields[1] == "forcefinal" || Fields[1] == "unblockdirectory")
  && (Fields[2] == "pulse" || Fields[2] == "same"), "Unknown confirmed lifecycle mode")
 Action := Fields[1], Pauses := Fields[2] == "pulse"
 _LCPC_World := {Ports: Map()}, _ConfigDir := A_Args[2]
 TimingsLoadShared(A_Args[3]), KeystatsWalkerLoadTimings()
 Logs := [], Sys := _SCL_System(Action, Pauses), Done := {Value: false}
 LoggerSetTestSink((Line) => Logs.Push(Line))
 Target := {Hwnd: 0x4321, Pid: 7001, Class: Action == "forcefinal" ? "Notepad" : "CabinetWClass"}
 if Action == "forcefinal" {
  Target.TargetPid := 7001
  Target.ProcessLease := {Handle: 0xF00D, Pid: 7001}
 }
 ActionFn := Action == "forcefinal" ? GestureSysForceQuitFrontmost : GestureSysUnblockFileSelection
 Barrier := (*) => Done.Value := true
 PreviousCritical := Critical("On")
 try {
  _LCPC_Require(!A_IsSuspended && !_UserProgramPaused, "The genuine lifecycle must begin resumed")
  _GestureScheduleConfirmedSystemAction(Action, ActionFn, Target, Sys)
  _LCPC_Require(Sys.Queries == 0 && Sys.Effects.Length == 0 && Sys.Snapshots == 0,
   "The genuine confirmed scheduler must defer every target inspection and effect")
  SetTimer(Barrier, -250)
 } finally Critical(PreviousCritical)
 Started := A_TickCount
 try {
  while !Done.Value && A_TickCount - Started < 7000
   Sleep(10)
  Errors := 0
  for Line in Logs
   Errors += InStr(Line, "ERROR") ? 1 : 0
  FileAppend("RECEIPT system-action-confirmed-lifecycle mode=" . Mode . " queries=" . Sys.Queries
   . " snapshots=" . Sys.Snapshots . " live_reads=" . Sys.LiveReads . " releases=" . Sys.Releases
   . " effects=" . Sys.Effects.Length . " pulse=" . Sys.PulseCompleted . " ports=" . _LCPC_World.Ports.Count
   . " barrier=" . Done.Value . " suspended=" . A_IsSuspended . " errors=" . Errors . "`n", "*")
  for Effect in Sys.Effects
   FileAppend("EFFECT system-action-confirmed-lifecycle " . Effect . "`n", "*")
  _LCPC_Require(Done.Value && Sys.Queries == 1 && Errors == 0 && !A_IsSuspended && !_UserProgramPaused,
   "The selected validation cutpoint must execute once with genuine lifecycle settled and no hidden errors")
  _LCPC_Require(Sys.PulseCompleted == Pauses && _LCPC_World.Ports.Count == (Pauses ? 17 : 0),
   "Only the requested genuine full lifecycle may issue its 17 receipts")
  _LCPC_Require(Sys.Releases == (Action == "forcefinal" ? 1 : 0)
   && (Action != "forcefinal" || !Target.HasOwnProp("ProcessLease")),
   "The confirmed wrapper must preserve exact process capability cleanup independently of cancellation")
  _LCPC_Require(Sys.Effects.Length == (Pauses ? 0 : 1),
   "An unchanged target identity cannot revive the original effect authority after a full lifecycle")
  if !Pauses {
   Expected := Action == "forcefinal" ? "terminate:7001" : "unblock:" . Sys.Path
   _LCPC_Require(Sys.Effects[1] == Expected && Sys.Snapshots == 3,
    "Same-epoch confirmed validation must preserve its exact original target and single effect")
   if Action == "forcefinal"
    _LCPC_Require(Sys.LiveReads == 4, "The genuine force-quit path must validate its retained capability at all four existing boundaries")
  }
 } finally {
  SetTimer(Barrier, 0)
  LoggerClearTestSink()
  Suspend(false)
 }
}
try {
 _SCL_Main()
 FileAppend("PASS system-action-confirmed-lifecycle " . A_Args[1] . "`n", "*")
 ExitApp(0)
} catch Any as _SCL_Failure {
 FileAppend("FAIL system-action-confirmed-lifecycle " . _SCL_Failure.Message . " [" . _SCL_Failure.File . ":" . _SCL_Failure.Line . "]`n", "*")
 ExitApp(1)
}
