; tests/unit/modules/gestures/test_system_action_inflight_lifecycle.ahk

#Requires AutoHotkey v2.0

_SAIL_Source() {
 global _DriverDir
 Source := _SALTC_Source()
 Footer := "#Include " . _DriverDir . "\tests\fixtures\system_action_lifecycle_timer_body.ahk`n"
 AssertEqual(Footer, SubStr(Source, -StrLen(Footer)), "The original real-timer composition must retain its exact footer")
 Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
 Owner := _DriverProductionFileForSymbol("GestureSysToggleDarkMode", _DriverDir)
 Text := FSReadStrict(Owner)
 ; Retain the original module constants, including the protected shell classes.
 Stop := InStr(Text, "_GestureSys(Sys)")
 AssertTrue(Stop > 0, "The genuine constants prefix must precede the adapter resolver")
 Prefix := SubStr(Text, 1, Stop - 1)
 AssertTrue(InStr(Prefix, 'global GESTURE_SYS_SHELL_CLASSES := Map(') > 0,
  "The private quit action must use the authentic protected-class list")
 Source .= Prefix . "`n"
 for Symbol in ["GestureSysToggleDarkMode", "GestureSysMicMuteToggle", "GestureSysQuitRefusal", "GestureSysIsSharedHost", "GestureSysQuitFrontmostApp"] {
  Body := _DriverExtractFunctionBody(&Text, Symbol)
  AssertTrue(Body != "", "Every in-flight action must retain its actual production body: " . Symbol)
  Source .= Body . "`n"
 }
 return Source . "#Include " . _DriverDir . "\tests\fixtures\system_action_inflight_lifecycle_body.ahk`n"
}

_SAIL_Case(Mode) {
 global _DriverDir
 static Debt := 0
 AssertFalse(IsObject(Debt), "A retained child prevents another timer case")
 Root := A_Temp . "\ergopti_system_inflight_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
 FSCreateDirectoryExclusiveStrict(Root)
 State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
 PreviousCritical := Critical("Off")
 try {
  Script := Root . "\subject.ahk"
  AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _SAIL_Source()))
  _TestPrint("# system-action-inflight-lifecycle source=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
  Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root, _DriverDir . "\..\_shared"], _LCPC_Done.Bind(State))
  AssertTrue(Handle.start(), "The exact private timer child must really start")
  Started := A_TickCount
  while !State.Calls && TickElapsed64(Started) < 15000 {
   _SR_TreePoll()
   Sleep(10)
  }
  _TestPrint("# system-action-inflight-lifecycle mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
  AssertEqual(1, State.Calls)
  AssertEqual("", State.ErrorText)
  AssertEqual(0, State.Code, State.Output)
  AssertContains(State.Output, "PASS system-action-inflight-lifecycle " . Mode)
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
for _SAIL_Action in ["theme", "quit", "mic"] {
 Test("System action in-flight lifecycle: " . _SAIL_Action . " retires its pre-pause read (system-action-inflight-lifecycle)", _SAIL_Case.Bind(_SAIL_Action . "-pulse"))
 Test("System action in-flight lifecycle: " . _SAIL_Action . " preserves its same-epoch effect (system-action-inflight-lifecycle)", _SAIL_Case.Bind(_SAIL_Action . "-same"))
}
