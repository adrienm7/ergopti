; tests/meta/test_prefix_keydown_ctrl_backspace_reset.ahk

; ==============================================================================
; MODULE: Ctrl context resets for hotstring buffers
; DESCRIPTION:
; _OnPrefixKeyDown's CtrlHeld block handled Ctrl+A/X/V/Z/Y but not Ctrl+Backspace,
; which fell through to the plain VK==0x08 branch that models exactly ONE char
; removed. But Ctrl+Backspace deletes a whole WORD on screen, so the engine buffer
; ended up ahead of the screen; a later trigger match then fired an expansion whose
; {BackSpace N} chewed into unrelated text. Ctrl+Backspace destroys an unknown
; amount left of the cursor, so it must be treated as a context-unknown wipe like
; Ctrl+X, not a single decrement. (F20, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_PKCB_CtrlBackspaceResetsBuffer() {
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Body != "", "_OnPrefixKeyDown must exist in infra/hotstrings/hotstring_inputhook.ahk")

	; The Ctrl-combo reset group must include VK == 0x08 (Backspace), and its
	; paired context invalidation must precede the plain single-decrement helper
	; so Ctrl+Backspace never falls through to it.
	ResetGroupPos := InStr(Body, "_PrefixInvalidateInputContext(_PrefixFocusedControlToken, false)")
	Assert(ResetGroupPos > 0, "_OnPrefixKeyDown must keep the context-unknown reset for Ctrl+X/V/Z/Y")
	GroupCond := SubStr(Body, 1, ResetGroupPos)
	VkCondPos := InStr(GroupCond, "VK == 0x08", , -1)
	Assert(VkCondPos > 0,
		"the Ctrl-combo reset group must include VK == 0x08 so Ctrl+Backspace (delete-word) wipes the buffer instead of single-decrementing it")

	SingleDecrementPos := InStr(Body, "_PrefixFeedBackspace()")
	Assert(SingleDecrementPos > 0, "_OnPrefixKeyDown must keep the single-char decrement for a plain Backspace")
	Assert(ResetGroupPos < SingleDecrementPos,
		"the Ctrl+Backspace reset must run BEFORE the plain-Backspace single-decrement branch (a Ctrl+Backspace must never reach the single decrement)")
}
Test("hotstrings: Ctrl+Backspace resets the buffer as a word-delete, not a one-char decrement",
	_PKCB_CtrlBackspaceResetsBuffer)

; AHK-06 cannot be covered by the pure engine alone: the production InputHook
; entry points must consult the WindowInfo adapter and the physical AltGr state.
; Keep this small source guard beside behavior tests that drive the canonical
; generation helpers and assert the resulting match/send/preview state.
_PKCB_FocusedControlGenerationIsWiredToLiveCallbacks() {
	OnChar := _DriverFuncBody("_OnPrefixChar")
	Ensure := _DriverFuncBody("_PrefixEnsureInputContext")
	Invalidate := _DriverFuncBody("_PrefixInvalidateInputContext")
	Commit := _DriverFuncBody("_PrefixCommitInputContext")
	OnKeyDown := _DriverFuncBody("_OnPrefixKeyDown")
	Chord := _DriverFuncBody("_PrefixHandleCtrlContextChord")
	Assert(OnChar != "" and Ensure != "" and Invalidate != "" and Commit != ""
		and OnKeyDown != "" and Chord != "",
		"input-context generation helpers and both live InputHook callbacks must be readable")

	ProbePos := InStr(Ensure, "WIGetFocusedControlToken()")
	Assert(ProbePos > 0,
		"production focus verification must use the WindowInfo focused-control adapter")
	EnsurePos := InStr(OnChar, "_PrefixEnsureInputContext()")
	FeedPos := InStr(OnChar, "HSEMatch := HSE_FeedChar(Char, true)")
	Assert(EnsurePos > 0 and FeedPos > EnsurePos,
		"OnChar must verify the focused-control generation before feeding a character to HSE")

	CriticalPos := InStr(Invalidate, 'Critical("On")')
	CommitCallPos := InStr(Invalidate, "_PrefixCommitInputContext(FocusToken, KnownBoundary)", true, CriticalPos)
	RestorePos := InStr(Invalidate, "Critical(PreviousCritical)", true, CommitCallPos)
	EngineResetPos := InStr(Commit, "HSE_FeedReset(")
	PreviewResetPos := InStr(Commit, '_PrefixSetBuffer("")')
	GenerationPos := InStr(Commit, "_PrefixInputContextGeneration += 1")
	Assert(CriticalPos > 0 and CommitCallPos > CriticalPos and RestorePos > CommitCallPos
		and EngineResetPos > 0 and PreviewResetPos > EngineResetPos
		and GenerationPos > EngineResetPos and GenerationPos > PreviewResetPos,
		"one Critical transaction must clear engine + preview before publishing the new generation")

	AltGrPos := InStr(OnKeyDown, 'KS_IsDown("RAlt")')
	ChordPos := InStr(OnKeyDown, "_PrefixHandleCtrlContextChord(VK, CtrlHeld, AltGrHeld)")
	Assert(AltGrPos > 0 and ChordPos > AltGrPos,
		"the live keydown callback must resolve AltGr before delegating Ctrl context policy")
	Assert(InStr(Chord, "0x46") > 0 and InStr(Chord, "0x4C") > 0,
		"the relocation policy must cover Ctrl+F and Ctrl+L")
	Assert(InStr(Chord, "AltGrHeld") > 0,
		"the relocation policy must reject AltGr's synthetic Ctrl state")
}
Test("hotstrings input-context-generation: live callbacks enforce focused-control ownership",
	_PKCB_FocusedControlGenerationIsWiredToLiveCallbacks)
