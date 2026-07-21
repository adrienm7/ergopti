; tests/meta/test_prefix_buffer_tracks_engine.ahk

; ==============================================================================
; MODULE: Regression — the watcher buffer must describe what is on screen
; DESCRIPTION:
; The tooltip is rendered from _PrefixBuffer; the expansion is decided from
; HSE_Buffer. Whenever those two stop describing the same text, the tooltip
; either promises an expansion that will not happen or hides one that will.
; This file guards the two ways they were drifting, both found while fixing the
; word-boundary divergence.
;
; ROOT CAUSE ENCODED — 1. BACKSPACE, SKEWED ONE WAY.
; VK_BACK sat in the watcher's ResetVKs, so a backspace WIPED _PrefixBuffer to
; empty. The engine did the opposite: HSE_FeedBackspace decrements by one,
; deliberately — preserving the in-word context is described in its own comment
; as the whole point of the rewrite. So after deleting a single typo the engine
; would still fire a hotstring that the tooltip had stopped offering, and the
; user had to retype the whole word before a suggestion returned.
;
; ROOT CAUSE ENCODED — 2. A DECLINED MATCH, SKEWED THE OTHER WAY.
; A match is not a fire: the time-activation gate, the mixed-case gate and the
; raw-callback guards can all decline one. The code already knew this — it gates
; the metrics pipeline on _HseFired, with a comment saying a declined match must
; not be counted as an expansion — but the buffer resync directly below ran
; unconditionally. It stripped the trigger from _PrefixBuffer and appended the
; Replacement as though the expansion had happened, while the screen still held
; the trigger and the just-typed character. Every later lookup anchored on text
; that had never been typed.
;
; Both are fixed by routing the two cases that leave the screen in the SAME
; state through the same code: _PrefixAppendTypedChar.
;
; SCOPE: source introspection of the watcher, plus behavioural coverage of the
; buffer helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ Backspace shrinks, it does not wipe =======
; ======================================================
; ======================================================

_PBT_BackspaceIsNotAResetKey() {
	Body := _DriverFuncBody("_PrefixWatcherOnKeyDown")
	if (Body == "")
		Body := _DriverDirConcat("lib/hotstrings")
	Assert(Body != "", "the watcher key-down path must be readable")
	Assert(InStr(Body, "_PrefixFeedBackspace()") > 0,
		"backspace must shrink the watcher buffer by one character — wiping it left the engine still able to fire a hotstring the tooltip had stopped offering, because HSE_FeedBackspace only decrements")
}

; The decrement must actually be a decrement, and must not underflow.
_PBT_BackspaceDecrementsByOne() {
	global _PrefixBuffer
	Saved := _PrefixBuffer
	try {
		_PrefixBuffer := "abc"
		_PrefixFeedBackspace()
		Assert(_PrefixBuffer == "ab",
			"one backspace must remove exactly one character — got '" . _PrefixBuffer . "'")

		_PrefixFeedBackspace()
		_PrefixFeedBackspace()
		Assert(_PrefixBuffer == "",
			"backspacing the whole buffer must empty it — got '" . _PrefixBuffer . "'")

		; One more than there are characters must be harmless.
		_PrefixFeedBackspace()
		Assert(_PrefixBuffer == "",
			"backspacing an empty buffer must stay empty rather than underflow")
	} finally {
		_PrefixBuffer := Saved
	}
}

; VK_BACK must not creep back into the reset list, which is where it lived.
_PBT_ResetListExcludesBackspace() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")
	Assert(RegExMatch(Src, "ResetVKs\s*:=\s*Map\(\s*0x08") == 0,
		"VK_BACK must not be the first entry of ResetVKs — a reset wipes the preview buffer, and the engine only decrements")
}





; ===============================================================
; ===============================================================
; ======= 2/ A declined match must not rewrite the buffer =======
; ===============================================================
; ===============================================================

_PBT_DeclinedMatchTakesTheNoMatchPath() {
	Body := _DriverFuncBody("_PrefixWatcherOnChar")
	if (Body == "")
		Body := _DriverDirConcat("lib/hotstrings")
	Assert(Body != "", "the watcher char path must be readable")

	FiredGate := InStr(Body, "if !_HseFired")
	Assert(FiredGate > 0,
		"the char path must branch on _HseFired before touching the buffer — a match that did not fire changed nothing on screen, so rewriting the buffer with its Replacement described text that was never typed")

	; The resync that strips the trigger and appends the Replacement must sit
	; AFTER that gate, or it still runs on a decline.
	Resync := InStr(Body, "_PrefixBuffer .= HSEMatch.Replacement")
	Assert(Resync == 0 or Resync > FiredGate,
		"the post-expansion resync must come after the _HseFired gate")
}

; The two paths that leave the screen in the same state must share one
; implementation — keeping them separate is what let them diverge.
_PBT_OneAppendPath() {
	Body := _DriverFuncBody("_PrefixAppendTypedChar")
	Assert(Body != "", "_PrefixAppendTypedChar() must exist as the single buffer-growth path")
	Assert(InStr(Body, "_PrefixWordBoundaries()") > 0,
		"the append path must start a fresh word on a boundary character, using the shared boundary derivation")
	Assert(InStr(Body, "_PrefixScheduleRender()") > 0,
		"the append path must re-render the preview for the new buffer")

	Src := _DriverSourceNoComments()
	Grows := 0
	Pos := 1
	while (Pos := InStr(Src, "_PrefixBuffer .= Char", false, Pos)) {
		Grows += 1
		Pos += 1
	}
	Assert(Grows <= 1,
		"only _PrefixAppendTypedChar may append a typed character to the watcher buffer (found " . Grows . " site(s)) — a second site is how the declined-match case came to be handled differently from the no-match case")
}

; Behavioural: the append path itself.
_PBT_AppendGrowsAndBoundaryResets() {
	global _PrefixBuffer
	Saved := _PrefixBuffer
	try {
		_PrefixBuffer := "ab"
		_PrefixAppendTypedChar("c")
		Assert(_PrefixBuffer == "abc",
			"a normal character must extend the buffer — got '" . _PrefixBuffer . "'")

		; A single character before the boundary, deliberately: the reset path
		; runs deferred near-miss analytics for buffers of 2+ chars, and that
		; touches the Keylogger singleton, which this harness stubs as a bare
		; class. One char short-circuits that branch and still proves the reset.
		_PrefixBuffer := "a"
		_PrefixAppendTypedChar(" ")
		Assert(_PrefixBuffer == "",
			"a word-boundary character must start a fresh word — got '" . _PrefixBuffer . "'")
	} finally {
		_PrefixBuffer := Saved
	}
}


Test("meta watcher: backspace shrinks the preview buffer", _PBT_BackspaceIsNotAResetKey)
Test("meta watcher: backspace decrements by exactly one", _PBT_BackspaceDecrementsByOne)
Test("meta watcher: VK_BACK is not a reset key", _PBT_ResetListExcludesBackspace)
Test("meta watcher: a declined match takes the no-match path", _PBT_DeclinedMatchTakesTheNoMatchPath)
Test("meta watcher: one path grows the preview buffer", _PBT_OneAppendPath)
Test("meta watcher: the append path grows and resets correctly", _PBT_AppendGrowsAndBoundaryResets)
