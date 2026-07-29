; tests/unit/test_activate_hotstrings_commits_synchronously.ahk

; ==============================================================================
; MODULE: Regression — the pending end-char hotstring is committed inside
;         ActivateHotstrings (activate-hotstrings-poke-never-round-trips)
; DESCRIPTION:
; ActivateHotstrings runs on every Shift French-punctuation key: the layer emits
; the abbreviation-flushing poke, then the narrow no-break space and the
; punctuation itself.
;
; ROOT CAUSE ENCODED: the commit used to be a HOOK ROUND-TRIP. The poke space
; was injected at the caller's send level, the prefix-watcher InputHook observed
; it, and _OnPrefixChar fired the pending trigger. That design requires the
; message loop to run BETWEEN the two sends — and every caller reaches this
; function from a serialized layer hotkey holding Critical across the poke AND
; the punctuation emit that follows, so no InputHook callback can be delivered
; until all of it has already landed on screen. The deferred OnChar then fired
; the expansion at a caret that had moved past the punctuation, destroying the
; character the user had just typed, while HSE_ApplyExpansion mirrored the same
; wrong edit into HSE_Buffer so no desync alarm could trip. The round-trip the
; whole function was built on had become structurally impossible; production
; logs across a week contain zero end-char fires from this path.
;
; This test pins the property that replaced it: the commit happens INSIDE the
; call, between the poke and its backspace, with no message pump involved.
;
; SCOPE: behavioural, driving the real engine with the send recorder installed.
; ==============================================================================

#Requires AutoHotkey v2.0






; ========================================================================
; ========================================================================
; ======= 1/ The commit happens between the poke and its backspace =======
; ========================================================================
; ========================================================================

_AHCS_CommitsInsideTheCall() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, _Stub_RecordedSends
	global _PrefixWatcherSuppressed
	InstallHotstringHooks()
	ResetHotstringRecorders()
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	if IsSet(_PrefixWatcherSuppressed)
		_PrefixWatcherSuppressed := 0
	HSE_FeedReset(true)
	SimulateRegularApp()
	try {
		; No "*" flag: an end-char-gated, word-anchored trigger — exactly the
		; shape ActivateHotstrings exists to flush before a punctuation symbol.
		HSE_Register("", "ia", 0, Map("Replacement", "IA", "Category", "test", "Section", "activate"))
		HSE_Buffer := "ia"
		HSE_StartIsWordBoundary := true

		ActivateHotstrings()

		Sends := _Stub_RecordedSends
		AssertEqual(3, Sends.Length,
			"the pending end-char hotstring must be committed inside ActivateHotstrings, between the poke and its backspace. A commit that only happens once the InputHook delivers the poked space back can never run while the caller holds Critical, and it then fires against a caret that has already moved past the punctuation")
		Assert(Sends[1].fn == "SendNewResult" and Sends[1].args[1] == " ",
			"the space must still really be emitted — the expansion's own backspace count assumes it is on screen")
		Assert(Sends[2].fn == "SendFinalResult",
			"the expansion burst must be injected between the poke and its backspace")
		Assert(InStr(Sends[2].args[1], "{Text}IA") > 0,
			"and it must carry the replacement the pending trigger resolves to")
		Assert(Sends[3].fn == "SendNewResult" and Sends[3].args[1] == "{BackSpace}",
			"the poke space must then be taken back off the screen")
		Assert(HSE_Buffer == "IA",
			"the engine buffer must describe the same text the screen now holds: the replacement, with the poked space removed again")
	} finally {
		HSE_Suppressed := 0
		if IsSet(_PrefixWatcherSuppressed)
			_PrefixWatcherSuppressed := 0
		HSE_RegistryClear()
		HSE_HardReset()
		ResetHotstringRecorders()
	}
}
Test("hotstrings: ActivateHotstrings commits the pending end-char hotstring synchronously (activate-hotstrings-poke-never-round-trips)",
	_AHCS_CommitsInsideTheCall)

; With nothing pending, the poke must stay exactly what it was: two sends and no
; expansion. This is the common case on every punctuation key, and it is what
; the empty-buffer gate above it protects.
_AHCS_NothingPendingStillJustPokes() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, _Stub_RecordedSends
	global _PrefixWatcherSuppressed
	InstallHotstringHooks()
	ResetHotstringRecorders()
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	SimulateRegularApp()
	try {
		HSE_Buffer := "zzq"
		HSE_StartIsWordBoundary := true
		ActivateHotstrings()
		AssertEqual(2, _Stub_RecordedSends.Length,
			"with no trigger claiming the buffer the dance must stay a bare space + backspace")
	} finally {
		HSE_Suppressed := 0
		if IsSet(_PrefixWatcherSuppressed)
			_PrefixWatcherSuppressed := 0
		HSE_RegistryClear()
		HSE_HardReset()
		ResetHotstringRecorders()
	}
}
Test("hotstrings: ActivateHotstrings still only pokes when nothing is pending",
	_AHCS_NothingPendingStillJustPokes)






; ====================================================================
; ====================================================================
; ======= 2/ The poke is emitted below the watcher input level =======
; ====================================================================
; ====================================================================

; The direct commit is only safe because the poke cannot ALSO come back through
; the InputHook: a level-0 send is below the watcher's I1 minimum, so the space
; and its backspace are never re-ingested on top of the feed done here.
_AHCS_PokeIsBelowTheWatcherLevel() {
	Body := _DriverFuncBody("ActivateHotstrings")
	Assert(Body != "", "ActivateHotstrings() must exist in the driver source")
	Assert(InStr(Body, "HSE_FeedChar") > 0,
		"ActivateHotstrings must commit through a direct engine call — the hook round-trip it used to rely on cannot complete inside the Critical the poke is emitted under")
	Assert(InStr(Body, "SendLevel(0)") > 0,
		"and it must emit the poke below the prefix-watcher InputHook's minimum send level, or the deferred callbacks would feed the same space a second time")
	Assert(InStr(Body, "A_SendLevel") > 0 and InStr(Body, "finally") > 0,
		"the previous send level must be restored in a finally — leaking level 0 into the caller would silence the watcher for the punctuation that follows")
}
Test("meta hotstrings: the activation poke commits directly and stays below the watcher level",
	_AHCS_PokeIsBelowTheWatcherLevel)
