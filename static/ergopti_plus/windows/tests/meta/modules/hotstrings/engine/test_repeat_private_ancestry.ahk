; tests/meta/modules/hotstrings/engine/test_repeat_private_ancestry.ahk

; ==============================================================================
; MODULE: Repeat Private Ancestry Meta Test
; DESCRIPTION:
; Static source guard for URW-001. A nonfinal private output (a programmable
; user-code result) stays in the matcher, so a later magic-key repeat can derive
; its scalar from it. The repeat Spec used to carry no IsPrivate, which published
; that scalar to metrics, the AI context and the queued events as public text.
; The engine now keeps HSE_PrivateAncestry, the repeat Spec inherits from it, and
; every buffer commit and reset owner maintains it.
;
; Meta-static: the headless runner cannot drive the user-code worker and the
; dispatcher together; native AHK execution remains to be qualified.
; ==============================================================================

#Requires AutoHotkey v2.0

_RPA_RepeatSpecInheritsPrivacy() {
	Body := _DriverFuncBody("HSE_TryRepeatKey")
	Assert(InStr(Body, "HSE_PrivateAncestry") > 0 and InStr(Body, "IsPrivate:") > 0,
		"HSE_TryRepeatKey must derive the repeat Spec's IsPrivate from the retained private ancestry")
	Assert(InStr(Body, "SubStr(HSE_PrivateAncestry, 1, StrLen(Before)) == Before") > 0,
		"only a scalar read from a prefix of the private output is private (case-sensitive comparison)")
}
Test("repeat: the transient Spec inherits private ancestry (URW-001)", _RPA_RepeatSpecInheritsPrivacy)

_RPA_ApplyExpansionTracksAncestry() {
	Body := _DriverFuncBody("HSE_ApplyExpansion")
	Assert(InStr(Body, "HSE_PrivateAncestry := Effect.IsPrivate ? HSE_Buffer : " . Chr(34) . Chr(34)) > 0,
		"HSE_ApplyExpansion must record the buffer a private output left, and clear it otherwise")
	Assert(InStr(Body, "HSE_PrivateAncestry := " . Chr(34) . Chr(34)) > 0,
		"a ClearAll expansion must drop the ancestry")
}
Test("repeat: HSE_ApplyExpansion maintains the private ancestry (URW-001)", _RPA_ApplyExpansionTracksAncestry)

_RPA_DeferredCommitsTrackAncestry() {
	for Name in ["_HSE_CommitTerminalOwner", "_HSE_CommitNotepadOwner"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "HSE_PrivateAncestry := Effect.IsPrivate ? HSE_Buffer : " . Chr(34) . Chr(34)) > 0,
			Name . " commits the buffer itself and must maintain the private ancestry")
		Assert(InStr(Body, "HSE_PrivateAncestry := PreviousAncestry") > 0,
			Name . " must restore the ancestry when its buffer commit rolls back")
	}
}
Test("repeat: deferred owners maintain the private ancestry (URW-001)", _RPA_DeferredCommitsTrackAncestry)

_RPA_ResetsDropAncestry() {
	for Name in ["HSE_FeedReset", "HSE_HardReset", "_HSE_ForgetFinalOutput"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "HSE_PrivateAncestry := " . Chr(34) . Chr(34)) > 0,
			Name . " empties the buffer and must drop the private ancestry with it")
	}
}
Test("repeat: every buffer reset drops the private ancestry (URW-001)", _RPA_ResetsDropAncestry)
