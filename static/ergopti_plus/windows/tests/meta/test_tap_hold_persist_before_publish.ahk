; tests/meta/test_tap_hold_persist_before_publish.ahk
; Regression guard for atomic tap-hold persistence publication.
#Requires AutoHotkey v2.0

_THPPP_CandidateCommitsOnlyAfterWrite() {
    for _, FnName in ["WriteTapHoldTap", "WriteTapHoldHold", "WriteTapHoldNative"] {
        Body := _DriverFuncBody(FnName)
        WritePos := InStr(Body, "_TH_WriteTapHoldToml(Candidate)")
        PublishPos := InStr(Body, "TapHold := Candidate")
        Assert(WritePos > 0 && PublishPos > WritePos,
            FnName . " must persist its candidate before publishing TapHold")
        Assert(InStr(Body, "if !_TH_WriteTapHoldToml(Candidate)") > 0,
            FnName . " must return failure without publishing a failed write")
    }
    Menu := _DriverDirConcat("ui/menu")
    Assert(InStr(Menu, "WriteTapHoldNative(this.KeyId)") > 0,
        "the Disable action must use the single-write native transaction")
}
Test("tap-hold: failed persistence cannot publish partial live state", _THPPP_CandidateCommitsOnlyAfterWrite)
