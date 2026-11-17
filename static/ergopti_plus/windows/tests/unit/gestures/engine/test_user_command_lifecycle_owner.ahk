; tests/unit/gestures/engine/test_user_command_lifecycle_owner.ahk

#Requires AutoHotkey v2.0

; The real command runner and full lifecycle are included; only unrelated
; teardown and output ports are passive in the private child.
_UCLC_Source() {
	global _DriverDir
	Source := _TNLC_Source()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\takenote_pause_lifecycle_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, -StrLen(Footer)))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Seen := Map()
	for Symbol in ["UserActions_RunCommand", "JsonParse", "SendKeysVocabulary", "TimerSetCallback",
		"PLC_CreateProcessWithInheritedHandles"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The real command composition needs its production owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	for Symbol in ["HTTPIsValidUtf8", "GestureActionParameterKey", "GestureGetActionParameter"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "The actual command graph needs its genuine function: " . Symbol)
		Source .= Body . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\user_command_lifecycle_owner_body.ahk`n"
}

_UCLC_Case(Mode) {
 global _DriverDir
 static RetirementDebt := 0
 AssertFalse(IsObject(RetirementDebt), "A prior unretired child blocks its successor")
 Directory := A_Temp . "\ergopti_usercommand_lifecycle_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
 Created := false, Handle := 0, Retired := false, Primary := 0
 State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
 PreviousCritical := Critical("Off")
 try {
  Creation := FSCreateDirectoryExclusiveStrict(Directory)
  Created := Creation is Integer && Creation == 1
  AssertTrue(Created)
  Script := Directory . "\subject.ahk"
  AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _UCLC_Source()))
  Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
   ["/ErrorStdOut=UTF-8", Script, Mode, Directory, _DriverDir . "\..\_shared"], _LCPC_Done.Bind(State))
  AssertTrue(Handle.start())
  Start := A_TickCount
  while !State.Calls && TickElapsed64(Start) < 15000 {
   _SR_TreePoll()
   Sleep(10)
  }
  _TestPrint("# usercommand-lifecycle mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
  AssertEqual(1, State.Calls)
  AssertEqual(0, State.Code, State.Output . State.ErrorText)
  AssertEqual("", State.ErrorText)
  AssertContains(State.Output, "PASS usercommand-lifecycle " . Mode)
 } catch Any as Failure
  Primary := Failure
 try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
 catch Any as Failure {
  if !IsObject(Primary)
   Primary := Failure
 }
 try {
  if Created && !Retired
   RetirementDebt := {Directory: Directory, Handle: Handle}
  else if Created && Retired && !IsObject(Primary)
   DirDelete(Directory, true)
 } finally Critical(PreviousCritical)
 if IsObject(Primary)
  throw Primary
 AssertTrue(Retired, "The exact child must retire before private cleanup")
}
for _UCLC_Mode in ["current-type", "retired-type", "retired-copy", "acquire-resume"]
	Test("User command lifecycle: " . _UCLC_Mode . " retains its original publication authority (user-command-pause-owner)", _UCLC_Case.Bind(_UCLC_Mode))
