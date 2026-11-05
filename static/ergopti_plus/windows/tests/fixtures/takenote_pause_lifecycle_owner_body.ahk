; tests/fixtures/takenote_pause_lifecycle_owner_body.ahk

; ==============================================================================
; MODULE: TakeNote Pause Lifecycle Child
; DESCRIPTION:
; Runs real suspend and resume with deterministic TakeNote IO boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0
class _TNLC_Ops extends _TakeNoteFakeOps {
 static IsSuspended() => A_IsSuspended
}
Assert(Value, Message := "") {
 if !Value
  throw Error(Message)
}
_TNLC_Main() {
 global _LCPC_World, _ConfigDir, _UserProgramPaused, _TakeNotePending, _TakeNoteNextId
 _LCPC_Require(A_Args.Length == 3, "A private mode, directory and shared source are required")
 Mode := A_Args[1]
 _LCPC_Require(Mode == "queued" || Mode == "waiting" || Mode == "same-epoch", "Unknown mode")
 _LCPC_World := {Ports: Map()}
 _ConfigDir := A_Args[2]
 TimingsLoadShared(A_Args[3])
 KeystatsWalkerLoadTimings()
 LoggerSetTestSink((*) => 0)
 _LCPC_Require(!A_IsSuspended && !_UserProgramPaused && _TakeNotePending.Count == 0,
  "The private lifecycle and note owners must start empty")
 _TakeNoteFakeOps.Reset(), _TakeNotePending := Map(), _TakeNoteNextId := 0
 try {
  JobId := TakeNoteRequest(false, A_Args[2], true, _TNLC_Ops)
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
  if Mode != "same-epoch" {
   Suspend(true)
   _LCPC_Require(A_IsSuspended, "Native Suspend must precede the actual lifecycle entry")
   Enter := Ergopti_OnSuspendEnter()
   _LCPC_Require(Enter == 1 && LifecycleTransitionDebtSnapshot("suspend").Length == 0
    && _LCPC_World.Ports.Count == 16, "The genuine suspend owner and unrelated teardown ports must settle")
   Suspend(false)
   _LCPC_Require(!A_IsSuspended, "Native Resume must precede the actual lifecycle resume")
   Resume := Ergopti_OnSuspendResume()
   _LCPC_Require(Resume == 1 && LifecycleTransitionDebtSnapshot("resume").Length == 0
    && !_UserProgramPaused, "The real resume transition must settle before the retained timer")
  }
  if Mode == "waiting"
   _TakeNoteFakeOps.window_exists := true
  FrozenCallback.Call()
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
  else if Mode == "queued"
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
