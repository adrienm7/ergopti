; tests/fixtures/core/system_action_sibling_lifecycle_body.ahk

#Requires AutoHotkey v2.0

; This explicit display-only port is unrelated to action or lifecycle ownership.
t(Key) {
 _LCPC_Require(Key == "system_actions.new_text_file_name", "Only the exact private filename label is admitted")
 return "owned"
}
class _SIB_Folder {
 __New(Sys) {
  this.Sys := Sys
  this.Self := {Path: Sys.FolderPath}
 }
 ParseName(Name) => {Name: Name, Path: this.Sys.FolderPath . "\" . Name}
}
class _SIB_Document {
 __New(Sys) {
  this.Sys := Sys
  this.Folder := _SIB_Folder(Sys)
 }
 SelectItem(Item, Flags) {
  _LCPC_Require(Item.Path == this.Sys.CreatedPath && Flags == GESTURE_SYS_SVSI_RENAME,
   "Only the exact acknowledged private file may be selected for rename")
  this.Sys.Effects.Push("select:" . Item.Path)
 }
}
class _SIB_Shell {
 __New(Sys) => this.Sys := Sys
 Windows() => [{HWND: 0x4321, Document: _SIB_Document(this.Sys)}]
}
class _SIB_System extends SystemControl {
 __New(Action, Pauses) {
  this.Action := Action, this.Pauses := Pauses
  this.Queries := 0, this.PulseCompleted := false, this.Attempts := 0
  this.Effects := [], this.CreatedPath := "", this.FolderPath := A_Temp . "\sibling_not_created"
 }
 _Read() {
  this.Queries += 1
  _LCPC_Require(this.Queries == 1, "Exactly the selected private query may issue the lifecycle pulse")
  if this.Pauses {
   _TNLC_RunLifecycle()
   this.PulseCompleted := true
  }
 }
 MousePosition() {
  this._Read()
  return {X: 10, Y: 20}
 }
 Monitors() => [{Left: 0, Top: 0, Right: 100, Bottom: 100}]
 MoveMouse(X, Y) {
  _LCPC_Require(X == 50 && Y == 50, "Only the exact genuine geometry result may reach the private move port")
  this.Effects.Push("move:50,50")
 }
 ActiveWindow() {
  if this.Action == "terminal" || this.Action == "newfile"
   this._Read()
  return {Hwnd: 0x4321, Pid: 7001, Class: this.Action == "terminal" ? "Progman" : "CabinetWClass"}
 }
 ShellApplication() => _SIB_Shell(this)
 ActiveExplorerTab(Hwnd) {
  _LCPC_Require(Hwnd == 0x4321, "Only the private Explorer frame may be queried")
  return 0
 }
 WindowsTerminalPath() => ""
 Launch(Target, WorkingDir := "", Options := "") {
  _LCPC_Require(Target == A_ComSpec && WorkingDir == A_Desktop && Options == "",
   "Only the exact desktop command-prompt request may reach the private launch port")
  this.Effects.Push("terminal:" . WorkingDir)
  return 1
 }
 CreateNewFile(Path) {
  this.Attempts += 1
  Expected := this.FolderPath . "\owned" . (this.Attempts == 1 ? "" : " (2)") . ".txt"
  _LCPC_Require(Path == Expected && this.Attempts <= 2, "Only the exact two private creation candidates may be tried")
  if this.Attempts == 1 && (this.Action == "newfilecreated" || this.Action == "newfilecollision")
   this._Read()
  if this.Attempts == 1 && this.Action == "newfilecollision"
   return "exists"
  this.CreatedPath := Path
  this.Effects.Push("create:" . Path)
  return "created"
 }
}
_SIB_Main() {
 global _LCPC_World, _ConfigDir, _UserProgramPaused
 _LCPC_Require(A_Args.Length == 3, "Mode, private directory and shared source are required")
 Mode := A_Args[1], Fields := StrSplit(Mode, "-")
 _LCPC_Require(Fields.Length == 2 && (Fields[1] == "center" || Fields[1] == "terminal"
  || Fields[1] == "newfile" || Fields[1] == "newfilecreated" || Fields[1] == "newfilecollision")
  && (Fields[2] == "pulse" || Fields[2] == "same"), "Unknown sibling lifecycle mode")
 Action := Fields[1], Pauses := Fields[2] == "pulse"
 _LCPC_World := {Ports: Map()}, _ConfigDir := A_Args[2]
 TimingsLoadShared(A_Args[3]), KeystatsWalkerLoadTimings()
 Logs := [], Sys := _SIB_System(Action, Pauses), Done := {Value: false}
 LoggerSetTestSink((Line) => Logs.Push(Line))
 ActionFn := Action == "center" ? GestureSysCenterMouse : Action == "terminal" ? GestureSysOpenTerminalHere : GestureSysNewTextFileHere
 Barrier := (*) => Done.Value := true
 PreviousCritical := Critical("On")
 try {
  _LCPC_Require(!A_IsSuspended && !_UserProgramPaused, "The genuine lifecycle must begin resumed")
  _GestureMakeSystemRunner(Action, ActionFn.Bind(Sys), Sys).Call()
  _LCPC_Require(Sys.Queries == 0 && Sys.Effects.Length == 0 && Sys.Attempts == 0,
   "The genuine action must be deferred before any private query or effect")
  SetTimer(Barrier, -250)
 } finally Critical(PreviousCritical)
 Started := A_TickCount
 try {
  while !Done.Value && A_TickCount - Started < 7000
   Sleep(10)
  Errors := 0
  for Line in Logs
   Errors += InStr(Line, "ERROR") ? 1 : 0
  FileAppend("RECEIPT system-action-sibling-lifecycle mode=" . Mode . " queries=" . Sys.Queries
   . " attempts=" . Sys.Attempts . " effects=" . Sys.Effects.Length . " pulse=" . Sys.PulseCompleted
   . " ports=" . _LCPC_World.Ports.Count . " barrier=" . Done.Value . " suspended=" . A_IsSuspended
   . " errors=" . Errors . "`n", "*")
  for Effect in Sys.Effects
   FileAppend("EFFECT system-action-sibling-lifecycle " . Effect . "`n", "*")
  _LCPC_Require(Done.Value && Sys.Queries == 1 && Errors == 0 && !A_IsSuspended && !_UserProgramPaused,
   "Real timer delivery must reach exactly one query with settled genuine lifecycle and no hidden failures")
  _LCPC_Require(Sys.PulseCompleted == Pauses && _LCPC_World.Ports.Count == (Pauses ? 17 : 0),
   "Only the requested genuine full lifecycle may issue its 17 receipts")
  Expected := []
  ExpectedAttempts := 0
  if !Pauses {
   if Action == "center"
    Expected := ["move:50,50"]
   else if Action == "terminal"
    Expected := ["terminal:" . A_Desktop]
   else {
    ExpectedAttempts := Action == "newfilecollision" ? 2 : 1
    Path := Sys.FolderPath . (Action == "newfilecollision" ? "\owned (2).txt" : "\owned.txt")
    Expected := ["create:" . Path, "select:" . Path]
   }
  } else if Action == "newfilecreated" {
   ExpectedAttempts := 1
   Expected := ["create:" . Sys.FolderPath . "\owned.txt"]
  } else if Action == "newfilecollision"
   ExpectedAttempts := 1
  _LCPC_Require(Sys.Attempts == ExpectedAttempts && Sys.Effects.Length == Expected.Length,
   "Retired query authority cannot authorize a new effect or collision retry; an acknowledged create remains preserved")
  for Index, Effect in Expected
   _LCPC_Require(Sys.Effects[Index] == Effect, "Private effects must preserve their exact original path and order")
 } finally {
  SetTimer(Barrier, 0)
  LoggerClearTestSink()
  Suspend(false)
 }
}
try {
 _SIB_Main()
 FileAppend("PASS system-action-sibling-lifecycle " . A_Args[1] . "`n", "*")
 ExitApp(0)
} catch Any as _SIB_Failure {
 FileAppend("FAIL system-action-sibling-lifecycle " . _SIB_Failure.Message . " [" . _SIB_Failure.File . ":" . _SIB_Failure.Line . "]`n", "*")
 ExitApp(1)
}
