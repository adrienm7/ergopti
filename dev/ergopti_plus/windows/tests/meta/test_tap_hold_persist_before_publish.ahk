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
    DisabledBody := _DriverFuncBody("_TH_WriteTapHoldDisabled")
    DisabledWritePos := InStr(DisabledBody, "_TH_WriteTapHoldToml(Candidate)")
    DisabledPublishPos := InStr(DisabledBody, "TapHold := Candidate")
    Assert(DisabledWritePos > 0 && DisabledPublishPos > DisabledWritePos,
        "disable-all must persist its candidate before publishing TapHold")
    Assert(InStr(DisabledBody, "TapHold[" . Chr(34) . "keys" . Chr(34) . "] := Map()") == 0,
        "disable-all must not clear the live TapHold map before persistence")
	MenuSource := _DriverDirConcat("ui/menu")
	Assert(InStr(MenuSource, "WriteTapHoldNative(this.KeyId)") > 0,
        "the Disable action must use the single-write native transaction")
    DisableAllBody := _DriverFuncBody("_TH_DisableAll")
    Assert(InStr(DisableAllBody, "if !_TH_WriteTapHoldDisabled()") > 0,
        "Disable all must not reload after a failed persistence transaction")
}
Test("tap-hold: failed persistence cannot publish partial live state", _THPPP_CandidateCommitsOnlyAfterWrite)
