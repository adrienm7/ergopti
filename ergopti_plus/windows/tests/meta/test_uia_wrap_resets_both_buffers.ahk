; tests/meta/test_uia_wrap_resets_both_buffers.ahk

; ==============================================================================
; MODULE: Regression — the UIA selection-wrap declares its edit to BOTH buffers
;         (uia-wrap-resets-only-the-preview-buffer)
; DESCRIPTION:
; Typing a wrapping symbol while text is selected replaces the selection with
; « (selection) »: the branch deletes the character the pass-through hook has
; already delivered, then injects the left symbol, the selection and the right
; symbol.
;
; ROOT CAUSE ENCODED: it declared that edit to ONE buffer. The finally reset
; _PrefixBuffer and returned — before Critical, before HSE_FeedChar — so the
; ENGINE buffer still described text that is no longer left of the caret. Every
; other site in the driver pairs the two (mouse click, Ctrl+A, Ctrl+X/V/Z/Y,
; Insert/Delete, Tab/Enter, navigation, Win+L, suspend/resume, live rebuild) and
; hotstring_buffer_effects.ahk states the contract as "both buffers or neither".
; The next expansion then counts its backspaces against the pre-wrap text and
; eats the wrapped selection instead of the trigger.
;
; The preview keeps agreeing with the engine throughout because its canonical
; HSE_PreviewNextDecision reads HSE_Buffer. If the wrap forgets to invalidate
; that one source, both matcher and tooltip faithfully describe the same stale
; pre-wrap world, which is why a G5 agreement check alone cannot detect it.
;
; SCOPE: source-level. The branch needs a live UIA selection and a running
; InputHook, neither of which exists in the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0






; ====================================================================
; ====================================================================
; ======= 1/ The wrap branch invalidates the engine buffer too =======
; ====================================================================
; ====================================================================

_UWB_WrapResetsBothBuffers() {
	Body := _DriverFuncBody("_PrefixTryWrapSelection")
	Assert(Body != "", "_PrefixTryWrapSelection() must be readable")
	Pos := InStr(Body, "Wrapped := SendInstant")
	Assert(Pos > 0, "the UIA selection-wrap branch must exist")
	Window := SubStr(Body, Pos, 400)
	Assert(InStr(Window, "if Wrapped") > 0,
		"the wrap must prove output success before either buffer reset")
	Assert(InStr(Window, "_PrefixInvalidateInputContext(") > 0,
		"the wrap must route both resets through the atomic input-context transaction")
	Assert(InStr(Window, "_ResetPrefixBuffer") == 0 and InStr(Window, "HSE_FeedReset") == 0,
		"the wrap must not restore the old split reset whose GUI yield let the next physical key enter only one buffer")
	Reset := _DriverFuncBody("_PrefixInvalidateInputContext")
	Commit := _DriverFuncBody("_PrefixCommitInputContext")
	EnterCritical := InStr(Reset, 'Critical("On")')
	CommitCall := InStr(Reset, "_PrefixCommitInputContext(FocusToken, KnownBoundary)", true, EnterCritical)
	LeaveCritical := InStr(Reset, "Critical(PreviousCritical)", true, CommitCall)
	ResetEngine := InStr(Commit, "HSE_FeedReset(KnownBoundary, true)")
	ResetPreview := InStr(Commit, '_PrefixSetBuffer("")', true, ResetEngine)
	Assert(EnterCritical > 0 and CommitCall > EnterCritical and LeaveCritical > CommitCall
		and ResetEngine > 0 and ResetPreview > ResetEngine,
		"engine and preview buffers must be invalidated before the Critical transaction is released")
}
Test("meta hotstrings: the UIA selection-wrap resets both buffers (uia-wrap-resets-only-the-preview-buffer)",
	_UWB_WrapResetsBothBuffers)
