; static/ergopti_plus/windows/tests/unit/test_synthetic_sends_declare_buffer_effect.ahk

; ==============================================================================
; MODULE: Regression — every synthetic key press declares its buffer effect
;         (synthetic-sends-declare-buffer-effect)
; DESCRIPTION:
; Type "bonjour attention", press AltGr+LAlt (default-on, mapped to
; ctrl_backspace), then type "ct" and the magic key. The word "attention"
; vanished from the screen but both hotstring buffers still held it, so the
; expansion backspaced over three characters of "bonjour" — text that had
; nothing to do with the trigger.
;
; ROOT CAUSE ENCODED: HSE_Buffer and _PrefixBuffer answer "what sits immediately
; left of the caret?", and every expansion backspaces over exactly that many
; characters. hotstring_buffer_effects.ahk exists as the declaration channel for
; keystrokes the prefix watcher cannot see — its InputHook is armed "V L0 I1",
; so it filters out every SendInput the driver makes at SendLevel 0. That channel
; had three callers while roughly forty synthetic emissions reached the same
; funnel without it. Hardening any of the existing reset sites could not have
; helped: the emission bypasses all of them by construction.
;
; The fix declares at _TextSenderSendInput, the single funnel every TextPressKey
; emission passes through, so a new caller is covered the day it is written.
;
; The NEGATIVE cases matter as much as the positive one. The engine's own
; expansion backspaces ("erase character") and its clipboard injection
; ("clipboard paste") go through the same funnel and are already accounted for
; by the engine; declaring those would decrement the buffers a second time and
; corrupt typing in the opposite direction. Modifier Down/Up changes modifier
; state only. Those three must stay silent, and are asserted below.
;
; SCOPE: behavioural — drives the real TextPressKey/TextEraseChars entry points
; with the injectable send primitive stubbed, so no keystroke reaches the OS.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================================
; ==========================
; ======= 1/ Harness =======
; ==========================
; ==============================================================

; Runs Action with the OS send primitive replaced by a no-op recorder, starting
; from a known engine-buffer state, and reports what the buffer became.
; @param Start  {String} Buffer contents before the synthetic emission.
; @param Action {Func}   Zero-arity closure performing the emission.
; @returns {String} HSE_Buffer after the emission.
_SSDB_BufferAfter(Start, Action) {
	global HSE_Buffer, HSE_Suppressed, _AHK_SendInput, _AHK_SendText
	SavedInput := _AHK_SendInput
	SavedText := _AHK_SendText
	; Never let a test fire a real keystroke at the developer's desktop.
	_AHK_SendInput := (Keys) => true
	_AHK_SendText := (Text) => true
	HSE_Suppressed := 0
	HSE_Buffer := Start
	try {
		Action()
	} finally {
		_AHK_SendInput := SavedInput
		_AHK_SendText := SavedText
	}
	return HSE_Buffer
}





; ==============================================================
; ==================================================
; ======= 2/ The emissions that MUST declare =======
; ==================================================
; ==============================================================

; The finding's own repro, reduced to the emission that caused it.
_SSDB_CtrlBackspaceInvalidatesTheBuffer() {
	After := _SSDB_BufferAfter("bonjour attention", () => TextPressKey("BackSpace", ["Ctrl"]))
	Assert(After == "",
		"a synthetic Ctrl+Backspace deletes a whole word on screen, so both hotstring buffers must be invalidated. Leaving them holding the deleted text makes the next expansion backspace over characters that belong to an earlier word — the buffer describes a screen that no longer exists")
}

; A caret move with no modifier takes the other TextPressKey branch, so it needs
; its own case: the two branches call the funnel from different places.
_SSDB_UnmodifiedCaretMoveInvalidatesTheBuffer() {
	After := _SSDB_BufferAfter("bonjour", () => TextPressKey("Home", []))
	Assert(After == "",
		"a synthetic Home moves the caret, so what sits left of it is no longer what the buffer holds. The unmodified branch of TextPressKey reaches the send funnel by its own path and must declare just like the modified one")
}





; ==============================================================
; ======================================================
; ======= 3/ The emissions that MUST NOT declare =======
; ======================================================
; ==============================================================

; The engine backspacing over its own trigger during an expansion. It already
; accounts for those characters; a second decrement here corrupts typing in the
; opposite direction, which is why the funnel is gated on the operation name.
_SSDB_EngineEraseDoesNotDoubleCount() {
	After := _SSDB_BufferAfter("bonjour", () => TextEraseChars(2))
	Assert(After == "bonjour",
		"TextEraseChars is the engine deleting its OWN trigger mid-expansion and it already accounts for those characters. Declaring them at the send funnel as well would decrement both buffers twice and make the expansion overshoot")
}

; Arming a hold modifier touches neither the caret nor the document.
_SSDB_ModifierHoldLeavesTheBufferAlone() {
	After := _SSDB_BufferAfter("bonjour", () => TextPressKey("Shift", "Down"))
	Assert(After == "bonjour",
		"pressing a modifier down changes modifier state only. Resetting the buffers there would throw away a live trigger prefix every time a tap-hold armed its modifier")
}





; ==============================================================
; ===================================================
; ======= 4/ The wiring that makes it general =======
; ===================================================
; ==============================================================

; The behavioural cases above prove the two branches in use today. This one
; states WHY the fix generalises: it lives at the funnel, not at the call sites,
; so the ~40 emissions that never declared are covered without being touched.
_SSDB_DeclarationLivesAtTheFunnel() {
	Body := _DriverFuncBody("_TextSenderSendInput")
	Assert(Body != "", "_TextSenderSendInput() must exist in the driver source")

	Assert(InStr(Body, "HS_DeclareSyntheticEffect(") > 0,
		"the declaration must happen inside _TextSenderSendInput. Moving it back out to individual callers re-creates the original defect the moment someone adds the forty-first emission")

	DeclareAt := InStr(Body, "HS_DeclareSyntheticEffect(")
	SendAt := InStr(Body, "_AHK_SendInput.Call(")
	Assert(SendAt > 0, "_TextSenderSendInput must still perform the send")
	Assert(DeclareAt < SendAt,
		"the effect must be declared BEFORE the send. hotstring_buffer_effects.ahk documents this ordering: if the send throws, buffers that were already invalidated cost the user a tooltip suggestion, whereas buffers left stale cost them the characters the next expansion backspaces over")
}

Test("synthetic sends: a synthetic Ctrl+Backspace invalidates the hotstring buffer (synthetic-sends-declare-buffer-effect)",
	_SSDB_CtrlBackspaceInvalidatesTheBuffer)
Test("synthetic sends: an unmodified synthetic caret move invalidates the hotstring buffer (synthetic-sends-declare-buffer-effect)",
	_SSDB_UnmodifiedCaretMoveInvalidatesTheBuffer)
Test("synthetic sends: the engine's own expansion erase is not counted twice (synthetic-sends-declare-buffer-effect)",
	_SSDB_EngineEraseDoesNotDoubleCount)
Test("synthetic sends: arming a hold modifier leaves the buffer alone (synthetic-sends-declare-buffer-effect)",
	_SSDB_ModifierHoldLeavesTheBufferAlone)
Test("synthetic sends: the declaration lives at the send funnel, before the send (synthetic-sends-declare-buffer-effect)",
	_SSDB_DeclarationLivesAtTheFunnel)
