; tests/unit/gestures/engine/test_system_action_lifecycle_timer.ahk

#Requires AutoHotkey v2.0

_SALTC_Source() {
 global _DriverDir
 Source := _TNLC_Source()
 Footer := "#Include " . _DriverDir . "\tests\fixtures\takenote_pause_lifecycle_owner_body.ahk`n"
 AssertEqual(Footer, SubStr(Source, -StrLen(Footer)), "The genuine lifecycle composition must retain its exact footer")
 Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
 LifecycleText := FileRead(_DriverDir . "\tests\fixtures\takenote_pause_lifecycle_owner_body.ahk", "UTF-8")
 Helper := _DriverExtractFunctionBody(&LifecycleText, "_TNLC_RunLifecycle")
 AssertTrue(Helper != "", "The actual paired suspend/resume helper must exist")
 Source .= Helper . "`n#Include " . _MEOT_AdapterOwner() . "`n"
 Owner := _DriverProductionFileForSymbol("GestureSysSleepDisplays", _DriverDir)
 Text := FSReadStrict(Owner)
 for Symbol in ["_GestureSys", "_GestureMakeSystemRunner", "_GestureRunSystemAction", "GestureSysClearClipboard", "GestureSysSleepDisplays", "_GestureSysPowerOffDisplays"] {
  Body := _DriverExtractFunctionBody(&Text, Symbol)
  AssertTrue(Body != "", "Every deferred function must retain its actual current production body: " . Symbol)
  Source .= Body . "`n"
 }
 return Source . "#Include " . _DriverDir . "\tests\fixtures\core\system_action_lifecycle_timer_body.ahk`n"
}

_SALTC_Case(Mode) {
 global _DriverDir
 static Debt := 0
 AssertFalse(IsObject(Debt), "A retained child prevents another timer case")
 Root := A_Temp . "\ergopti_system_lifecycle_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
 FSCreateDirectoryExclusiveStrict(Root)
 State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
 PreviousCritical := Critical("Off")
 try {
  Script := Root . "\subject.ahk"
  AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _SALTC_Source()))
  _TestPrint("# system-action-lifecycle source=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
  Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root, _DriverDir . "\..\_shared"], _LCPC_Done.Bind(State))
  AssertTrue(Handle.start(), "The exact private timer child must really start")
  Started := A_TickCount
  while !State.Calls && TickElapsed64(Started) < 15000 {
   _SR_TreePoll()
   Sleep(10)
  }
  _TestPrint("# system-action-lifecycle mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
  AssertEqual(1, State.Calls)
  AssertEqual("", State.ErrorText)
  AssertEqual(0, State.Code, State.Output)
  AssertContains(State.Output, "PASS system-action-lifecycle " . Mode)
 } catch Any as Failure
  Primary := Failure
 try {
  Receipt := IsObject(Handle) ? Handle.terminate() : 1
  Retired := Receipt is Integer && Receipt == 1
 } catch Any as Failure {
  if !IsObject(Primary)
   Primary := Failure
 }
 try {
  if !Retired
   Debt := {Root: Root, Handle: Handle}
  else if !IsObject(Primary)
   DirDelete(Root, true)
 } finally Critical(PreviousCritical)
 if IsObject(Primary)
  throw Primary
 AssertTrue(Retired, "The precise native process tree must retire before private cleanup")
}
for _SALTC_Mode in ["queued", "display-queued", "same-epoch", "display-same-epoch"]
 Test("System action lifecycle: " . _SALTC_Mode . " uses real timer delivery (system-action-lifecycle-timer)", _SALTC_Case.Bind(_SALTC_Mode))
