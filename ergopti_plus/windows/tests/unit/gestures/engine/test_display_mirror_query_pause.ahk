; tests/unit/gestures/engine/test_display_mirror_query_pause.ahk

#Requires AutoHotkey v2.0

class _DMQP_System extends _MirrorSystem {
 __New(At, Pauses) {
  super.__New(_Mirror_Two(), 0x4)
  this.QueryCalls := 0, this.PauseAt := At, this.Pauses := Pauses
 }
 DisplayConfigCall(Name, Args*) {
  Status := super.DisplayConfigCall(Name, Args*)
  if Name == "QueryDisplayConfig" {
   this.QueryCalls += 1
   if this.Pauses && this.QueryCalls == this.PauseAt
    Suspend(true)
  }
  return Status
 }
}
_DMQP_Case(At, Pauses) {
 global _GestureMirrorPriorTopology
 PreviousSuspend := A_IsSuspended, PreviousTopology := _GestureMirrorPriorTopology
 Sys := _DMQP_System(At, Pauses)
 try {
  Suspend(false), _GestureMirrorPriorTopology := 0
  Result := GestureDisplayMirrorToggle(Sys)
  _TestAppendProgress("# RECEIPT mirror-query-pause at=" . At . " pauses=" . Pauses . " suspended=" . A_IsSuspended . " queries=" . Sys.QueryCalls . " effects=" . Sys.Applied.Length . " result=" . Result)
  AssertEqual(Pauses, A_IsSuspended, "The native query seam must actually suspend before action admission")
  AssertEqual(Pauses ? 0 : 1, Sys.Applied.Length, "A display query that pauses the driver must not apply a topology")
  AssertEqual(!Pauses, !!Result, "The action must report refusal when its query revoked admission")
  AssertEqual(Pauses ? 0 : 0x4, _GestureMirrorPriorTopology, "A cancelled display change cannot acquire remembered topology state")
 } finally {
  Suspend(PreviousSuspend)
  _GestureMirrorPriorTopology := PreviousTopology
 }
}
for _DMQP_At in [1, 2] {
 Test("Display mirror query pause at " . _DMQP_At . " refuses effect (display-mirror-query-pause)", _DMQP_Case.Bind(_DMQP_At, true))
 Test("Display mirror query unchanged at " . _DMQP_At . " preserves effect (display-mirror-query-pause)", _DMQP_Case.Bind(_DMQP_At, false))
}
