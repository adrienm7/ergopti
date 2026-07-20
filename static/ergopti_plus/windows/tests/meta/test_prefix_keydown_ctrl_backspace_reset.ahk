; tests/meta/test_prefix_keydown_ctrl_backspace_reset.ahk

; ==============================================================================
; MODULE: Ctrl+Backspace resets the hotstring buffer (word-delete desync)
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
	Assert(Body != "", "_OnPrefixKeyDown must exist in lib/hotstrings/hotstring_inputhook.ahk")

	; The Ctrl-combo reset group (which does the context-unknown HSE_FeedReset) must
	; include VK == 0x08 (Backspace), and that reset must precede the plain single-
	; decrement HSE_FeedBackspace branch so Ctrl+Backspace never falls through to it.
	ResetGroupPos := InStr(Body, "HSE_FeedReset(false, true)")
	Assert(ResetGroupPos > 0, "_OnPrefixKeyDown must keep the context-unknown reset for Ctrl+X/V/Z/Y")
	GroupCond := SubStr(Body, 1, ResetGroupPos)
	VkCondPos := InStr(GroupCond, "VK == 0x08", , -1)
	Assert(VkCondPos > 0,
		"the Ctrl-combo reset group must include VK == 0x08 so Ctrl+Backspace (delete-word) wipes the buffer instead of single-decrementing it")

	SingleDecrementPos := InStr(Body, "HSE_FeedBackspace(true)")
	Assert(SingleDecrementPos > 0, "_OnPrefixKeyDown must keep the single-char decrement for a plain Backspace")
	Assert(ResetGroupPos < SingleDecrementPos,
		"the Ctrl+Backspace reset must run BEFORE the plain-Backspace single-decrement branch (a Ctrl+Backspace must never reach the single decrement)")
}
Test("hotstrings: Ctrl+Backspace resets the buffer as a word-delete, not a one-char decrement",
	_PKCB_CtrlBackspaceResetsBuffer)
