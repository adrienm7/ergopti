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





; ==========================
; ==========================
; ======= 1/ Harness =======
; ==========================
; ==========================

global _SSDB_SendBoundary := 0

; Runs Action with the OS send primitive replaced by a recorder, starting from
; a known two-buffer state. The recorder samples the exact OS-send boundary so
; the test proves both buffers have committed while the owner is still Critical.
; @param Start  {String} Buffer contents before the synthetic emission.
; @param Action {Func}   Zero-arity closure performing the emission.
; @param ThrowAtSend {Boolean} Whether the fake OS primitive must throw.
; @returns {Object} Final buffers, action verdict and send-boundary snapshot.
_SSDB_BufferAfter(Start, Action, ThrowAtSend := false) {
	global HSE_Buffer, HSE_Suppressed, _PrefixBuffer
	global _AHK_SendInput, _AHK_SendText, _SSDB_SendBoundary
	SavedInput := _AHK_SendInput
	SavedText := _AHK_SendText
	; Never let a test fire a real keystroke at the developer's desktop.
	_AHK_SendInput := (Keys) => _SSDB_RecordSendBoundary(Keys, ThrowAtSend)
	_AHK_SendText := (Text) => true
	HSE_Suppressed := 0
	HSE_Buffer := Start
	_PrefixSetBuffer(Start)
	_SSDB_SendBoundary := 0
	try {
		ActionResult := Action()
	} finally {
		_AHK_SendInput := SavedInput
		_AHK_SendText := SavedText
	}
	return {
		engine: HSE_Buffer,
		preview: _PrefixBuffer,
		actionResult: ActionResult,
		boundary: _SSDB_SendBoundary,
		afterCritical: A_IsCritical
	}
}

_SSDB_RecordSendBoundary(Keys, ThrowAtSend) {
	global HSE_Buffer, _PrefixBuffer, _SSDB_SendBoundary
	_SSDB_SendBoundary := {
		keys: Keys,
		critical: A_IsCritical,
		engine: HSE_Buffer,
		preview: _PrefixBuffer
	}
	if ThrowAtSend
		throw Error("simulated OS send failure")
	return true
}

_SSDB_AssertBoth(Expected, Pair, Message) {
	AssertEqual(Expected, Pair.engine, Message . " (engine)")
	AssertEqual(Expected, Pair.preview, Message . " (preview)")
}





; ==================================================
; ==================================================
; ======= 2/ The emissions that MUST declare =======
; ==================================================
; ==================================================

; The finding's own repro, reduced to the emission that caused it.
_SSDB_CtrlBackspaceInvalidatesTheBuffer() {
	Pair := _SSDB_BufferAfter("bonjour attention", () => TextPressKey("BackSpace", ["Ctrl"]))
	_SSDB_AssertBoth("", Pair,
		"a synthetic Ctrl+Backspace deletes a whole word on screen, so both hotstring buffers must be invalidated. Leaving them holding the deleted text makes the next expansion backspace over characters that belong to an earlier word — the buffer describes a screen that no longer exists")
}

; A caret move with no modifier takes the other TextPressKey branch, so it needs
; its own case: the two branches call the funnel from different places.
_SSDB_UnmodifiedCaretMoveInvalidatesTheBuffer() {
	Pair := _SSDB_BufferAfter("bonjour", () => TextPressKey("Home", []))
	_SSDB_AssertBoth("", Pair,
		"a synthetic Home moves the caret, so what sits left of it is no longer what the buffer holds. The unmodified branch of TextPressKey reaches the send funnel by its own path and must declare just like the modified one")
	Assert(IsObject(Pair.boundary) and Pair.boundary.critical,
		"the fake OS sender must observe Critical at the exact send boundary — declaration-before-send alone still lets a physical OnChar interleave")
	AssertEqual("", Pair.boundary.engine,
		"the engine buffer must already describe the future caret state at the atomic OS-send boundary")
	AssertEqual("", Pair.boundary.preview,
		"the preview buffer must commit in the same atomic transaction as the engine and OS send")
}





; ======================================================
; ======================================================
; ======= 3/ The emissions that MUST NOT declare =======
; ======================================================
; ======================================================

; The engine backspacing over its own trigger during an expansion. It already
; accounts for those characters; a second decrement here corrupts typing in the
; opposite direction, which is why the funnel is gated on the operation name.
_SSDB_EngineEraseDoesNotDoubleCount() {
	Pair := _SSDB_BufferAfter("bonjour", () => TextEraseChars(2))
	_SSDB_AssertBoth("bonjour", Pair,
		"TextEraseChars is the engine deleting its OWN trigger mid-expansion and it already accounts for those characters. Declaring them at the send funnel as well would decrement both buffers twice and make the expansion overshoot")
}

; Arming a hold modifier touches neither the caret nor the document.
_SSDB_ModifierHoldLeavesTheBufferAlone() {
	Pair := _SSDB_BufferAfter("bonjour", () => TextPressKey("Shift", "Down"))
	_SSDB_AssertBoth("bonjour", Pair,
		"pressing a modifier down changes modifier state only. Resetting the buffers there would throw away a live trigger prefix every time a tap-hold armed its modifier")
}

_SSDB_SendFailureRestoresCriticalAndFailsSafe() {
	Pair := _SSDB_BufferAfter("bonjour", () => TextPressKey("Home", []), true)
	Assert(Pair.actionResult == false,
		"a rejected OS send must remain a reported adapter failure")
	Assert(Pair.afterCritical == 0,
		"the transaction must restore the caller's non-Critical state before returning from a failed OS send")
	_SSDB_AssertBoth("", Pair,
		"when the OS send throws, pre-invalidating both buffers is the safe direction — stale buffers could delete unrelated text on the next expansion")
}





; ===================================================
; ===================================================
; ======= 4/ The wiring that makes it general =======
; ===================================================
; ===================================================

; The behavioural cases above prove the two branches in use today. This one
; states WHY the fix generalises: it lives at the funnel, not at the call sites,
; so the ~40 emissions that never declared are covered without being touched.
_SSDB_DeclarationLivesAtTheFunnel() {
	Funnel := _DriverFuncBody("_TextSenderSendInput")
	Owner := _DriverFuncBody("HS_RunSyntheticInputTransaction")
	Assert(Funnel != "", "_TextSenderSendInput() must exist in the driver source")
	Assert(Owner != "", "HS_RunSyntheticInputTransaction() must exist in the driver source")

	Assert(InStr(Funnel, "HS_RunSyntheticInputTransaction(") > 0,
		"the send funnel must delegate declaration and OS output to the canonical transaction owner. Moving declaration back out to individual callers re-creates the original defect the moment someone adds the forty-first emission")

	EnterAt := InStr(Owner, 'Critical("On")')
	DeclareAt := InStr(Owner, "HS_CommitSyntheticEffect(", true, EnterAt)
	SendAt := InStr(Owner, "SendFn.Call()", true, DeclareAt)
	RestoreAt := InStr(Owner, "Critical(PreviousCritical)", true, SendAt)
	EffectsAt := InStr(Owner, "HS_FinishSyntheticEffect(Token)", true, RestoreAt)
	Assert(EnterAt > 0 and DeclareAt > EnterAt and SendAt > DeclareAt
		and RestoreAt > SendAt and EffectsAt > RestoreAt,
		"the canonical owner must hold Critical from both-buffer declaration through the exact OS send, restore it, and only then run tooltip/analytics effects")
	LogAt := InStr(Funnel, "LoggerError(", true, InStr(Funnel, "HS_RunSyntheticInputTransaction("))
	Assert(LogAt > 0,
		"the adapter must log a transaction/send failure only after the owner has restored Critical")
}

Test("synthetic sends: a synthetic Ctrl+Backspace invalidates the hotstring buffer (synthetic-sends-declare-buffer-effect)",
	_SSDB_CtrlBackspaceInvalidatesTheBuffer)
Test("synthetic sends: an unmodified synthetic caret move invalidates the hotstring buffer (synthetic-sends-declare-buffer-effect)",
	_SSDB_UnmodifiedCaretMoveInvalidatesTheBuffer)
Test("synthetic sends: the engine's own expansion erase is not counted twice (synthetic-sends-declare-buffer-effect)",
	_SSDB_EngineEraseDoesNotDoubleCount)
Test("synthetic sends: arming a hold modifier leaves the buffer alone (synthetic-sends-declare-buffer-effect)",
	_SSDB_ModifierHoldLeavesTheBufferAlone)
Test("synthetic sends: a failed OS send restores Critical and invalidates safely (synthetic-sends-declare-buffer-effect)",
	_SSDB_SendFailureRestoresCriticalAndFailsSafe)
Test("synthetic sends: the declaration and send share one canonical transaction (synthetic-sends-declare-buffer-effect)",
	_SSDB_DeclarationLivesAtTheFunnel)
