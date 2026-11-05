; tests/meta/platform/remap/tap_hold/test_tap_hold_persist_before_publish.ahk
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
	OwnedPos := InStr(WriterBody, "FSWriteReplaceOwned(BoundPath, Content, StageSuffix")
	LegacyPos := InStr(WriterBody, "FSWriteDurable(StagePath, Content)", true, OwnedPos)
	ReplacePos := InStr(WriterBody, "FSConfigAtomicMoveReplace(StagePath, BoundPath,", true, LegacyPos)
	PublishPos := InStr(WriterBody, "_TH_PublishTapHoldCandidate(Data, RuntimeCandidate, EmptyKeys, OwnerToken", true, ReplacePos)
	Assert(OwnedPos > 0 && LegacyPos > OwnedPos && ReplacePos > LegacyPos && PublishPos > ReplacePos,
		"both the owned native route and the injected legacy route must complete before publishing TapHold")
	Assert(InStr(WriterBody, "BeforePublish := _TH_BeforeHeldPublication.Bind(") > 0
		&& InStr(WriterBody, "FinalAdmission := _TH_FinalHeldAdmission.Bind(") > 0,
		"the native owner requires preflight and final RAM admission")
	Publisher := _DriverFuncBody("_TH_PublishTapHoldCandidate")
	Assert(Publisher != "" && InStr(Publisher, "TapHold := RuntimeCandidate") > 0,
		"one memory-only helper must own live TapHold publication")
	MenuSource := _DriverDirConcat("ui/menu")
	Assert(InStr(MenuSource, "WriteTapHoldNative(this.KeyId)") > 0,
		"the Disable action must use the single-write native transaction")
	DisableAllBody := _DriverFuncBody("_TH_DisableAll")
	Assert(InStr(DisableAllBody, "if !_TH_WriteTapHoldDisabled()") > 0,
		"Disable all must not reload after a failed persistence transaction")
}
Test("tap-hold: failed persistence cannot publish partial live state", _THPPP_CandidateCommitsOnlyAfterWrite)
