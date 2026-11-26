; tests/unit/gestures/engine/test_system_action_inflight_lifecycle.ahk

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
 for Symbol in ["GestureSysToggleDarkMode", "GestureSysMicMuteToggle", "GestureSysQuitRefusal", "GestureSysIsSharedHost", "GestureSysQuitFrontmostApp", "GestureSysEjectAllDisks"] {
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
for _SAIL_Action in ["theme", "quit", "mic", "eject", "ejectnamespace", "ejectitem", "ejectbetween"] {
 Test("System action in-flight lifecycle: " . _SAIL_Action . " retires its pre-pause read (system-action-inflight-lifecycle)", _SAIL_Case.Bind(_SAIL_Action . "-pulse"))
 Test("System action in-flight lifecycle: " . _SAIL_Action . " preserves its same-epoch effect (system-action-inflight-lifecycle)", _SAIL_Case.Bind(_SAIL_Action . "-same"))
}


_SIB_Source() {
 global _DriverDir
 Source := _SAIL_Source()
 Footer := "#Include " . _DriverDir . "\tests\fixtures\system_action_inflight_lifecycle_body.ahk`n"
 AssertEqual(Footer, SubStr(Source, -StrLen(Footer)), "The existing genuine composition must retain its fixture boundary")
 Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
 Owner := _DriverProductionFileForSymbol("GestureSysCenterMouse", _DriverDir)
 Text := FSReadStrict(Owner)
 for Symbol in ["GestureSysCenterMouse", "GestureSysMonitorCenter", "GestureSysOpenTerminalHere",
  "GestureSysNewTextFileHere", "GestureSysCreateTextFile", "_GestureSysActiveFolder", "_GestureSysActiveExplorer",
  "GestureSysExplorerWindowFor", "GestureSysExplorerFolderPath", "GestureSysIsFileSystemPath"] {
  Body := _DriverExtractFunctionBody(&Text, Symbol)
  AssertTrue(Body != "", "Every sibling action and geometry/discovery helper must retain its genuine complete body: " . Symbol)
  Source .= Body . "`n"
 }
 LocaleOwner := _DriverProductionFileForSymbol("t", _DriverDir)
 AssertTrue(LocaleOwner != "" && _DriverFuncBody("t") != "", "The isolated display port must correspond to the actual production translator")
 return Source . "#Include " . _DriverDir . "\tests\fixtures\system_action_sibling_lifecycle_body.ahk`n"
}

_SIB_Case(Mode) {
 global _DriverDir
 static Debt := 0
 AssertFalse(IsObject(Debt), "A retained child prevents another timer case")
 Root := A_Temp . "\ergopti_system_sibling_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
 FSCreateDirectoryExclusiveStrict(Root)
 State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
 PreviousCritical := Critical("Off")
 try {
  Script := Root . "\subject.ahk"
  AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _SIB_Source()))
  _TestPrint("# system-action-sibling-lifecycle source=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
  Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root, _DriverDir . "\..\_shared"], _LCPC_Done.Bind(State))
  AssertTrue(Handle.start(), "The exact private timer child must really start")
  Started := A_TickCount
  while !State.Calls && TickElapsed64(Started) < 15000 {
   _SR_TreePoll()
   Sleep(10)
  }
  _TestPrint("# system-action-sibling-lifecycle mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
  AssertEqual(1, State.Calls)
  AssertEqual("", State.ErrorText)
  AssertEqual(0, State.Code, State.Output)
  AssertContains(State.Output, "PASS system-action-sibling-lifecycle " . Mode)
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
for _SIB_Action in ["center", "terminal", "newfile", "newfilecreated", "newfilecollision"] {
 Test("System action sibling lifecycle: " . _SIB_Action . " retires its original authority (system-action-sibling-lifecycle)", _SIB_Case.Bind(_SIB_Action . "-pulse"))
 Test("System action sibling lifecycle: " . _SIB_Action . " retains its exact same-epoch effects (system-action-sibling-lifecycle)", _SIB_Case.Bind(_SIB_Action . "-same"))
}


_SCL_Source() {
 global _DriverDir
 Source := _SAIL_Source()
 Footer := "#Include " . _DriverDir . "\tests\fixtures\system_action_inflight_lifecycle_body.ahk`n"
 AssertEqual(Footer, SubStr(Source, -StrLen(Footer)), "The existing genuine composition must retain its fixture boundary")
 Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
 for Symbol in ["_GestureScheduleConfirmedSystemAction", "_GestureRunConfirmedSystemAction",
  "_GestureInvokeConfirmedSystemAction", "_GestureConfirmedTargetIsLive", "_GestureReleaseProcessTarget",
  "GestureSysForceQuitTarget", "GestureSysForceQuitFrontmost", "GestureSysUnblockFileSelection",
  "_GestureSysActiveExplorer", "GestureSysExplorerWindowFor", "GestureSysExplorerSelectedPaths", "GestureSysIsFileSystemPath"] {
  Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
  AssertTrue(Owner != "", "Every confirmed source symbol must retain its unique production owner: " . Symbol)
  Text := FSReadStrict(Owner)
  Body := _DriverExtractFunctionBody(&Text, Symbol)
  AssertTrue(Body != "", "Every confirmed runner, action and target validator must retain its complete genuine body: " . Symbol)
  Source .= Body . "`n"
 }
 return Source . "#Include " . _DriverDir . "\tests\fixtures\system_action_confirmed_lifecycle_body.ahk`n"
}

_SCL_Case(Mode) {
 global _DriverDir
 static Debt := 0
 AssertFalse(IsObject(Debt), "A retained child prevents another timer case")
 Root := A_Temp . "\ergopti_system_confirmed_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
 FSCreateDirectoryExclusiveStrict(Root)
 State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
 PreviousCritical := Critical("Off")
 try {
  Script := Root . "\subject.ahk"
  AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _SCL_Source()))
  _TestPrint("# system-action-confirmed-lifecycle source=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
  Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root, _DriverDir . "\..\_shared"], _LCPC_Done.Bind(State))
  AssertTrue(Handle.start(), "The exact private timer child must really start")
  Started := A_TickCount
  while !State.Calls && TickElapsed64(Started) < 15000 {
   _SR_TreePoll()
   Sleep(10)
  }
  _TestPrint("# system-action-confirmed-lifecycle mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
  AssertEqual(1, State.Calls)
  AssertEqual("", State.ErrorText)
  AssertEqual(0, State.Code, State.Output)
  AssertContains(State.Output, "PASS system-action-confirmed-lifecycle " . Mode)
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
for _SCL_Action in ["wrapper", "forcefinal", "unblockdirectory"] {
 Test("System action confirmed lifecycle: " . _SCL_Action . " retires its original authority (system-action-confirmed-lifecycle)", _SCL_Case.Bind(_SCL_Action . "-pulse"))
 Test("System action confirmed lifecycle: " . _SCL_Action . " preserves its exact same-epoch target (system-action-confirmed-lifecycle)", _SCL_Case.Bind(_SCL_Action . "-same"))
}
