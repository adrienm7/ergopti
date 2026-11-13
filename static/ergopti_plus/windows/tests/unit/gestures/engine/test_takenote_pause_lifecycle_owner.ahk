; tests/unit/gestures/engine/test_takenote_pause_lifecycle_owner.ahk

; ==============================================================================
; MODULE: TakeNote Pause Lifecycle Ownership Tests
; DESCRIPTION:
; Isolates the real note job and lifecycle behind private passive IO ports.
; ==============================================================================

_TNLC_Source() {
 global _DriverDir
 Source := _LCPC_Source()
 Footer := "#Include " . _DriverDir . "\tests\fixtures\suspend_prefetch_receipt_body.ahk`n"
 AssertEqual(Footer, SubStr(Source, -StrLen(Footer)))
 Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
 Passive := FileRead(_DriverDir . "\tests\fixtures\suspend_prefetch_receipt_body.ahk", "UTF-8")
 Start := InStr(Passive, "global _LCPC_World := 0"), Stop := InStr(Passive, "class _LCPC_Handle {")
 AssertTrue(Start > 0 && Stop > Start, "Only explicit unrelated lifecycle ports are copied")
 Source .= SubStr(Passive, Start, Stop - Start) . "`n"
 LedgerOwner := _DriverProductionFileForSymbol("KeyboardArbiterEnsureForLedger", _DriverDir)
 AssertTrue(LedgerOwner != "" && FileExist(LedgerOwner) != "", "The unrelated native resume owner must exist")
 AssertTrue(_DriverFuncBody("KeyboardArbiterEnsureForLedger") != "", "The passive port corresponds to an actual production owner")
 ; This child has no global keyboard hook. Count the unrelated resume request;
 ; never install an owner or substitute TakeNote's lifecycle admission.
 Source .= 'KeyboardArbiterEnsureForLedger(StartFn := 0) {' . "`n"
  . '`tAck := _LCPC_Pass("keyboard-ledger")' . "`n"
  . '`tif !(Ack is Integer) || Ack != 1' . "`n"
  . '`t`tthrow Error("The passive keyboard ledger must acknowledge exactly 1")' . "`n"
  . '`treturn Ack' . "`n}" . "`n"
 Owner := _DriverProductionFileForSymbol("TakeNoteRequest", _DriverDir)
 AssertTrue(Owner != "")
 Source .= "#Include " . Owner . "`n"
 ; Resolve this shared test fixture by its unique basename, independently of
 ; its current suite directory. Production owners still resolve by symbol.
 FixturePaths := []
 Loop Files, _DriverDir . "\tests\*.ahk", "FR" {
  SplitPath(A_LoopFileFullPath, &FixtureName)
  if FixtureName == "test_take_note_async_job.ahk"
   FixturePaths.Push(A_LoopFileFullPath)
 }
 AssertEqual(1, FixturePaths.Length, "The shared deterministic note fixture must have one owner")
 Fake := FileRead(FixturePaths[1], "UTF-8")
 AssertTrue(RegExMatch(Fake, "ms)^class _TakeNoteFakeOps \{.*?^\}", &FixtureClass) > 0)
 Source .= FixtureClass[0] . "`n"
 return Source . "#Include " . _DriverDir . "\tests\fixtures\takenote_pause_lifecycle_owner_body.ahk`n"
}
_TNLC_Case(Mode) {
 global _DriverDir
 static RetirementDebt := 0
 AssertFalse(IsObject(RetirementDebt), "A prior unretired child blocks its successor")
 Directory := A_Temp . "\ergopti_takenote_lifecycle_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
 Created := false, Handle := 0, Retired := false, Primary := 0
 State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
 PreviousCritical := Critical("Off")
 try {
  Creation := FSCreateDirectoryExclusiveStrict(Directory)
  Created := Creation is Integer && Creation == 1
  AssertTrue(Created)
  Script := Directory . "\subject.ahk"
  AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _TNLC_Source()))
  Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
   ["/ErrorStdOut=UTF-8", Script, Mode, Directory, _DriverDir . "\..\_shared"], _LCPC_Done.Bind(State))
  AssertTrue(Handle.start())
  Start := A_TickCount
  while !State.Calls && TickElapsed64(Start) < 15000 {
   _SR_TreePoll()
   Sleep(10)
  }
  _TestPrint("# takenote-lifecycle mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
  AssertEqual(1, State.Calls)
  AssertEqual(0, State.Code, State.Output . State.ErrorText)
  AssertEqual("", State.ErrorText)
  AssertContains(State.Output, "PASS takenote-lifecycle " . Mode)
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
for _TNLC_Mode in ["queued", "waiting", "same-epoch", "in-flight", "acquire-in-flight", "same-epoch-inline"]
 Test("TakeNote lifecycle: " . _TNLC_Mode . " preserves pause ownership (takenote-pause-lifecycle-owner)", _TNLC_Case.Bind(_TNLC_Mode))
