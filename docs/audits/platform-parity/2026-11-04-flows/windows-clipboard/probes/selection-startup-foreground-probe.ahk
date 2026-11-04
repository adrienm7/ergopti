; Unexecuted test body for the isolated existing Windows test harness.
; Calls actual GetSelectionAsync with recording clipboard/native-copy boundaries.
; This file is not a standalone production-driver entry point.

_WCP_StartupForegroundChange() {
    global _SelectionCaptureJob, _SelectionCaptureNextId
    AssertFalse(IsObject(_SelectionCaptureJob), "requires a private idle harness")
    AssertEqual(0, CBClipboardOwner.active.Count)
    PreviousId := _SelectionCaptureNextId
    State := {Generation: 100, Foreground: 101, Clears: 0, Copies: 0}
    SavedDuringRead() {
        ; A recording native boundary models an external OS foreground change.
        State.Foreground := 202
        return "opaque original snapshot"
    }
    Clear() {
        State.Clears += 1
        return Map("sequence", 42)
    }
    Copy() {
        State.Copies += 1
    }
    Ports := Map("physical_generation", () => State.Generation,
        "foreground", (*) => State.Foreground, "save", SavedDuringRead,
        "clear", Clear, "send", Copy, "sequence", (*) => 42,
        "restore", (*) => true)
    try {
        Accepted := GetSelectionAsync((*) => 0, Ports)
        Job := _SelectionCaptureJob
        AssertTrue(Accepted, "current baseline accepts the stale startup")
        AssertEqual(100, Job["physical_generation"])
        AssertEqual(100, State.Generation, "no physical callback timing assumed")
        AssertEqual(101, Job["foreground"], "original destination retained")
        AssertEqual(202, State.Foreground, "native foreground changed before clear/copy")
        AssertEqual(1, State.Clears, "clear ran after external foreground changed")
        AssertEqual(1, State.Copies, "Ctrl+C ran after external foreground changed")
        ; A root-cause regression must instead assert zero clear/copy after
        ; invalidation and a refused startup, while preserving newest clipboard.
    } finally {
        if IsObject(_SelectionCaptureJob) {
            Job := _SelectionCaptureJob
            if IsObject(Job["timer"])
                SetTimer(Job["timer"], 0)
            if Job["expected_change"]
                CB_CancelExpectedChange(Job["expected_change"])
            CB_EndOwnedTransaction(Job["owner_token"])
            _SelectionCaptureJob := false
        }
        _SelectionCaptureNextId := PreviousId
    }
}
; Native AHK was unavailable: no Test() registration/execution is claimed here.
