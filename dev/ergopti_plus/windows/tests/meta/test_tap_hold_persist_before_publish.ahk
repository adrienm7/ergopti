; tests/meta/test_tap_hold_persist_before_publish.ahk
; Regression guard for atomic tap-hold persistence publication.
#Requires AutoHotkey v2.0

_THPPP_CandidateCommitsOnlyAfterWrite() {
	for FnName in ["WriteTapHoldTap", "WriteTapHoldHold", "WriteTapHoldNative",
			"_TH_WriteTapHoldDisabled"] {
		Body := _DriverFuncBody(FnName)
		Assert(Body != "", FnName . " must remain source-visible")
		Assert(InStr(Body, "_TH_CommitTapHoldMutation(") > 0,
			FnName . " must delegate to the single persist-before-publish transaction")
		Assert(InStr(Body, "TapHold :=") == 0,
			FnName . " must never mutate the live Map before persistence")
	}
	WriterBody := _DriverFuncBody("_TH_WriteTapHoldToml")
	WritePos := InStr(WriterBody, "FSWriteDurable(StagePath, Content)")
	ReplacePos := InStr(WriterBody, "FSAtomicMoveReplace(StagePath, BoundPath)")
	PublishPos := InStr(WriterBody, "_TH_PublishTapHoldCandidate(Data, OwnerToken")
	Assert(WritePos > 0 && ReplacePos > WritePos && PublishPos > ReplacePos,
		"the shared writer must durably stage and atomically replace before publishing TapHold")
	Publisher := _DriverFuncBody("_TH_PublishTapHoldCandidate")
	Assert(Publisher != "" && InStr(Publisher, "TapHold := Candidate") > 0,
		"one memory-only helper must own live TapHold publication")
	MenuSource := _DriverDirConcat("ui/menu")
	Assert(InStr(MenuSource, "WriteTapHoldNative(this.KeyId)") > 0,
		"the Disable action must use the single-write native transaction")
	DisableAllBody := _DriverFuncBody("_TH_DisableAll")
	Assert(InStr(DisableAllBody, "if !_TH_WriteTapHoldDisabled()") > 0,
		"Disable all must not reload after a failed persistence transaction")
}
Test("tap-hold: failed persistence cannot publish partial live state", _THPPP_CandidateCommitsOnlyAfterWrite)
