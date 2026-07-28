; tests/meta/test_preview_never_wiped_alone.ahk

; ==============================================================================
; MODULE: Regression — the preview buffer is never wiped on its own
;         (preview-never-wiped-alone)
; DESCRIPTION:
; _PrefixBuffer (what the tooltip describes) and HSE_Buffer (what the engine
; will match) must always describe the same screen. Four sites broke that by
; touching one side only, each in a different direction:
;
;   1. The tooltip's auto-hide timer wiped the preview while the engine kept the
;      word. Any mid-word pause longer than the display duration killed the
;      suggestion for text that would still have expanded — and killed it for
;      the rest of that word, because the preview restarted from empty while the
;      engine kept accumulating.
;   2. A raw callback that DECLINED still had its preview wiped by an
;      unconditional finally, even though nothing reached the screen and the
;      engine buffer was deliberately left untouched.
;   3. Backspacing over a word terminator re-exposed the previous word on the
;      engine side, while the preview — reset when that terminator was typed —
;      had nothing left to shrink and stayed empty.
;   4. Win+L reset the preview unconditionally but called HSE_FeedReset without
;      IsPhysical, which is a NO-OP inside the post-expansion suppress window.
;      Stale left-context survived the lock, and the first expansion after
;      unlock backspaced into unrelated text.
;
; ROOT CAUSE ENCODED: the preview was being maintained as an independent copy
; rather than derived from the engine. Every one of these is the same mistake —
; deciding what the preview should hold without asking what the engine holds.
;
; SCOPE: behavioural for the recovery helper (the engine is in the runner's
; include graph); source-level for the three call sites, which live on
; InputHook callbacks and timers that cannot be driven headlessly.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ The preview can be recovered from the engine ==========
; ==================================================================
; ==================================================================

; The reconciliation primitive: given what the engine holds, what word is the
; preview supposed to be showing?
_PNW_TailFrom(EngineBuffer) {
	global HSE_Buffer
	Prev := HSE_Buffer
	HSE_Buffer := EngineBuffer
	Tail := _PrefixWordTailFromEngine()
	HSE_Buffer := Prev
	return Tail
}

_PNW_RecoversTheCurrentWord() {
	AssertEqual("monde", _PNW_TailFrom("bonjour monde"),
		"the preview must be recoverable as the engine buffer's trailing word — that is what the tooltip describes")
	AssertEqual("bonjour", _PNW_TailFrom("bonjour"),
		"a single word with no boundary before it is entirely the current word")
	AssertEqual("", _PNW_TailFrom("bonjour "),
		"a buffer ending on a terminator has no current word — the tooltip must show nothing rather than the previous word")
	AssertEqual("", _PNW_TailFrom(""),
		"an empty engine buffer recovers nothing")
}

; The exact shape of finding 3: the engine re-exposes a word the preview lost.
_PNW_RecoversAfterDeletingATerminator() {
	; "bonjour " → user backspaces the space → engine holds "bonjour".
	AssertEqual("bonjour", _PNW_TailFrom("bonjour"),
		"deleting the terminator that ended a word must let the preview describe that word again. Left empty, the tooltip stays silent for a trigger the engine would still expand, and cannot recover for the rest of the word")
}




; ==================================================================
; ==================================================================
; ======= 2/ No site wipes the preview on its own ==================
; ==================================================================
; ==================================================================

; The auto-hide timer means "this has been on screen a while", not "the word was
; abandoned". Nothing was typed and nothing moved the caret, so the engine still
; holds the word and the preview must too.
_PNW_ExpiryTimerDoesNotWipeThePreview() {
	Body := _DriverFuncBody("_TooltipTimerFn")
	Assert(Body != "", "_TooltipTimerFn() must exist in the driver source")
	Assert(InStr(Body, "_ResetPrefixBuffer") == 0,
		"the tooltip auto-hide timer must not reset the preview buffer. It fires precisely when NOTHING happened — no keystroke, no caret move — so the engine still holds the word, and wiping the preview alone makes the two describe different text after any mid-word pause")
	Assert(InStr(Body, "TooltipHide") > 0,
		"the timer must still hide the tooltip — that is its actual job")
}

; A declined raw callback changed nothing on screen, and the engine buffer is
; deliberately left untouched in that case, so the preview must be too.
_PNW_DeclinedRawCallbackKeepsThePreview() {
	Body := _DriverFuncBody("_HSE_DispatchRawCallback")
	Assert(Body != "", "_HSE_DispatchRawCallback() must exist in the driver source")
	ResetPos := InStr(Body, "_ResetPrefixBuffer")
	Assert(ResetPos > 0, "the raw-callback dispatch must still reset the preview when it DOES fire")
	; The reset must be conditional on the callback's own verdict.
	Window := SubStr(Body, Max(1, ResetPos - 200), 200)
	Assert(InStr(Window, "Fired") > 0,
		"the preview reset in the raw-callback finally must be gated on Fired. Unconditional, it wipes the preview for a callback that expanded nothing, while the engine keeps the trigger characters — so the tooltip stops offering a suggestion the engine would still fire")
}

; Win+L is a real user action, and the reset must survive the suppress window.
_PNW_LockWorkstationResetIsPhysical() {
	Body := _DriverFuncBody("_LockWorkstationEmit")
	Assert(Body != "", "_LockWorkstationEmit() must exist in the driver source")
	Assert(InStr(Body, "HSE_FeedReset(false, true)") > 0,
		"the lock must reset the engine buffer with IsPhysical=true. Without it the reset is a no-op whenever the lock lands inside the post-expansion suppress window — while the preview is reset unconditionally on the next line — so stale left-context survives the lock and the first expansion after unlock backspaces into unrelated text")
	Assert(InStr(Body, "_ResetPrefixBuffer") > 0,
		"the lock must still reset the preview too — both sides or neither")
}

; And the recovery must actually be wired into the backspace path, not merely
; available.
_PNW_BackspaceRecoveryIsWired() {
	Body := _DriverFuncBody("_PrefixFeedBackspace")
	Assert(Body != "", "_PrefixFeedBackspace() must exist in the driver source")
	Assert(InStr(Body, "_PrefixWordTailFromEngine") > 0,
		"the backspace path must recover the preview from the engine when its own buffer is empty — an empty preview does not mean there is nothing on screen, only that a terminator reset it earlier")
}


Test("meta preview-never-wiped-alone: the preview is recoverable from the engine",
	_PNW_RecoversTheCurrentWord)
Test("meta preview-never-wiped-alone: it recovers after deleting a terminator",
	_PNW_RecoversAfterDeletingATerminator)
Test("meta preview-never-wiped-alone: the expiry timer does not wipe the preview",
	_PNW_ExpiryTimerDoesNotWipeThePreview)
Test("meta preview-never-wiped-alone: a declined raw callback keeps the preview",
	_PNW_DeclinedRawCallbackKeepsThePreview)
Test("meta preview-never-wiped-alone: the lock reset is physical",
	_PNW_LockWorkstationResetIsPhysical)
Test("meta preview-never-wiped-alone: the backspace recovery is wired",
	_PNW_BackspaceRecoveryIsWired)
