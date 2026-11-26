; tests/fixtures/takenote_pause_lifecycle_owner_body.ahk

; ==============================================================================
; MODULE: TakeNote Pause Lifecycle Child
; DESCRIPTION:
; Runs real suspend and resume with deterministic TakeNote IO boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0
class _TNLC_Ops extends _TakeNoteFakeOps {
 static InlineSchedule := false
 static InlineCalls := 0
 static Schedule(Callback, DelayMs) {
  if _TNLC_Ops.InlineSchedule {
   _TNLC_Ops.InlineSchedule := false
   _TNLC_Ops.InlineCalls += 1
   Callback.Call()
   return true
  }
  return _TakeNoteFakeOps.Schedule(Callback, DelayMs)
 }
 static PauseAtFile := false
 static PauseAtClock := false
 static PauseCompleted := false
 static NowTick() {
  if _TNLC_Ops.PauseAtClock {
   _TNLC_Ops.PauseAtClock := false
   PreviousCritical := Critical("Off")
   try _TNLC_RunLifecycle()
   finally Critical(PreviousCritical)
   _TNLC_Ops.PauseCompleted := true
  }
  return _TakeNoteFakeOps.NowTick()
 }
 static IsSuspended() => A_IsSuspended
 static FileExists(Path) {
  if _TNLC_Ops.PauseAtFile {
   _TNLC_Ops.PauseAtFile := false
   _TNLC_RunLifecycle()
   _TNLC_Ops.PauseCompleted := true
  }
  return _TakeNoteFakeOps.FileExists(Path)
 }
}
Assert(Value, Message := "") {
 if !Value
  throw Error(Message)
}
_TNLC_RunLifecycle() {
 global _LCPC_World, _UserProgramPaused
 Suspend(true)
 _LCPC_Require(A_IsSuspended, "Native Suspend must precede the actual lifecycle entry")
 Enter := Ergopti_OnSuspendEnter()
 _LCPC_Require(Enter == 1 && LifecycleTransitionDebtSnapshot("suspend").Length == 0
  && _LCPC_World.Ports.Count == 16, "The genuine suspend owner and unrelated teardown ports must settle")
 Suspend(false)
 _LCPC_Require(!A_IsSuspended, "Native Resume must precede the actual lifecycle resume")
 Resume := Ergopti_OnSuspendResume()
 ResumeDebt := LifecycleTransitionDebtSnapshot("resume")
 for Debt in ResumeDebt
  FileAppend("OBSERVATION takenote-resume-debt owner=" . Debt.owner . " message=" . Debt.message . "`n", "*")
 FileAppend("OBSERVATION takenote-resume result=" . Resume . " debt=" . ResumeDebt.Length
  . " keyboard_port=" . _LCPC_World.Ports.Get("keyboard-ledger", 0) . "`n", "*")
 _LCPC_Require(Resume == 1 && ResumeDebt.Length == 0 && !_UserProgramPaused
  && _LCPC_World.Ports.Get("keyboard-ledger", 0) == 1 && _LCPC_World.Ports.Count == 17,
  "The real resume transition and counted unrelated keyboard port must settle before old note work continues")
}
_TNLC_Main() {
 global _LCPC_World, _ConfigDir, _UserProgramPaused, _TakeNotePending, _TakeNoteNextId
 _LCPC_Require(A_Args.Length == 3, "A private mode, directory and shared source are required")
 Mode := A_Args[1]
 _LCPC_Require(Mode == "queued" || Mode == "waiting" || Mode == "same-epoch" || Mode == "in-flight" || Mode == "acquire-in-flight" || Mode == "same-epoch-inline", "Unknown mode")
 _LCPC_World := {Ports: Map()}
 _ConfigDir := A_Args[2]
 TimingsLoadShared(A_Args[3])
 KeystatsWalkerLoadTimings()
 LoggerSetTestSink((*) => 0)
 _LCPC_Require(!A_IsSuspended && !_UserProgramPaused && _TakeNotePending.Count == 0,
  "The private lifecycle and note owners must start empty")
 _TakeNoteFakeOps.Reset(), _TakeNotePending := Map(), _TakeNoteNextId := 0
 try {
  if Mode == "acquire-in-flight"
   _TNLC_Ops.PauseAtClock := true
  if Mode == "same-epoch-inline" {
   _TNLC_Ops.InlineSchedule := true
   _TakeNoteFakeOps.file_exists := true, _TakeNoteFakeOps.window_exists := true
  }
  JobId := TakeNoteRequest(false, A_Args[2], true, _TNLC_Ops)
  if Mode == "same-epoch-inline" {
   FileAppend("OBSERVATION takenote-inline id=" . JobId . " calls=" . _TNLC_Ops.InlineCalls
    . " pending=" . _TakeNotePending.Count . " maximize=" . _TakeNoteFakeOps.maximize_count
    . " errors=" . _TakeNoteFakeOps.errors.Length . "`n", "*")
   _LCPC_Require(_TNLC_Ops.InlineCalls == 1 && JobId > 0 && _TakeNotePending.Count == 0
    && _TakeNoteFakeOps.maximize_count == 1 && _TakeNoteFakeOps.launch_count == 0
    && _TakeNoteFakeOps.send_count == 0 && _TakeNoteFakeOps.errors.Length == 0,
    "A callback that completes in its original epoch must preserve the public request ID")
   return
  }
  if Mode == "acquire-in-flight" {
   FileAppend("OBSERVATION takenote-acquire-in-flight id=" . JobId . " pause=" . _TNLC_Ops.PauseCompleted
    . " pending=" . _TakeNotePending.Count . " timers=" . _TakeNoteFakeOps.timers.Length
    . " launch=" . _TakeNoteFakeOps.launch_count . " errors=" . _TakeNoteFakeOps.errors.Length . "`n", "*")
   _LCPC_Require(_TNLC_Ops.PauseCompleted && _LCPC_World.Ports.Count == 17,
    "The real suspend and resume must complete within the genuine acquisition callout")
   _LCPC_Require(JobId == 0 && _TakeNotePending.Count == 0 && _TakeNoteFakeOps.timers.Length == 0
    && _TakeNoteFakeOps.launch_count == 0 && _TakeNoteFakeOps.errors.Length == 0,
    "The pre-pause request may not insert or schedule an owner after the resume")
   return
  }
  _LCPC_Require(JobId > 0 && _TakeNotePending.Has(JobId) && _TakeNoteFakeOps.timers.Length == 1,
   "The actual public request must publish its owned deferred callback")
  if Mode == "waiting" {
   _TakeNoteFakeOps.RunNext()
   _LCPC_Require(_TakeNoteFakeOps.launch_count == 1 && _TakeNoteFakeOps.send_count == 0
    && _TakeNotePending.Has(JobId) && _TakeNoteFakeOps.timers.Length == 1,
    "The genuine first tick must launch and retain its exact waiting job")
  }
  FrozenCallback := _TakeNoteFakeOps.timers.RemoveAt(1)
  _LCPC_Require(HasMethod(FrozenCallback, "Call"), "The exact scheduled callback must be retained by the test")
  if Mode == "in-flight"
   _TNLC_Ops.PauseAtFile := true
  else if Mode != "same-epoch"
   _TNLC_RunLifecycle()
  if Mode == "waiting"
   _TakeNoteFakeOps.window_exists := true
  FrozenCallback.Call()
  if Mode == "in-flight"
   _LCPC_Require(_TNLC_Ops.PauseCompleted, "The actual file-existence callout must contain the real suspend and resume")
  if Mode != "waiting" && _TakeNoteFakeOps.timers.Length {
   _TakeNoteFakeOps.window_exists := true
   _TakeNoteFakeOps.RunNext()
  }
  if Mode == "waiting" && _TakeNoteFakeOps.timers.Length
   _TakeNoteFakeOps.RunNext()
  FileAppend("OBSERVATION takenote-lifecycle mode=" . Mode . " launch=" . _TakeNoteFakeOps.launch_count
   . " maximize=" . _TakeNoteFakeOps.maximize_count . " send=" . _TakeNoteFakeOps.send_count
   . " created=" . _TakeNoteFakeOps.file_exists . " pending=" . _TakeNotePending.Count
   . " ports=" . _LCPC_World.Ports.Count . " errors=" . _TakeNoteFakeOps.errors.Length . "`n", "*")
  _LCPC_Require(_TakeNoteFakeOps.errors.Length == 0, "The real job cannot fail on an omitted dependency")
  if Mode == "same-epoch"
   _LCPC_Require(_TakeNoteFakeOps.launch_count == 1 && _TakeNoteFakeOps.maximize_count == 1
    && _TakeNoteFakeOps.send_count == 1 && _TakeNotePending.Count == 0,
    "A request kept in its capture epoch must complete exactly once")
  else if Mode == "queued" || Mode == "in-flight"
   _LCPC_Require(_TakeNoteFakeOps.launch_count == 0 && !_TakeNoteFakeOps.file_exists
    && _TakeNoteFakeOps.maximize_count == 0 && _TakeNoteFakeOps.send_count == 0,
    "A queued pre-pause request may not create, launch, focus or send after resume")
  else
   _LCPC_Require(_TakeNoteFakeOps.launch_count == 1 && _TakeNoteFakeOps.maximize_count == 0
    && _TakeNoteFakeOps.send_count == 0,
    "A pre-pause waiting request may not focus, maximize or send after resume")
 } finally {
  Suspend(false)
  ProgramActions_Stop(false)
  LoggerClearTestSink()
  _TakeNotePending := Map(), _TakeNoteFakeOps.timers := []
 }
}
try {
 _TNLC_Main()
 FileAppend("PASS takenote-lifecycle " . A_Args[1] . "`n", "*")
 ExitApp(0)
} catch Any as _TNLC_EntryFailure {
 FileAppend("FAIL takenote-lifecycle " . _TNLC_EntryFailure.Message . " [" . _TNLC_EntryFailure.File . ":" . _TNLC_EntryFailure.Line . "]`n", "*")
 ExitApp(1)
}
