; tests/unit/test_suppress_refcount.ahk

; ==============================================================================
; MODULE: Suppression Refcount Tests
; DESCRIPTION:
; Regression tests for the boolean-suppression-released-early-on-overlapping-fires
; finding. HSE_Suppressed, _PrefixWatcherSuppressed, and synth_active were plain
; booleans. When two hotstring fires overlapped (second fire begins before the
; first fire's deferred HSE_Suppress(false) timer fires), the first timer set the
; flag to false even though the second burst was still in flight, allowing
; keystrokes to leak into the engine mid-burst.
;
; The fix converts all three to depth counters (increment on suppress, decrement
; on release, floor at 0). These tests verify the counter semantics so the bug
; cannot silently revert to boolean behaviour.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ HSE_Suppressed refcount tests ========
; =================================================
; =================================================

_SRC_HSESuppressDepth() {
	global HSE_Suppressed
	HSE_Suppressed := 0
	HSE_Suppress(true)
	Assert(HSE_Suppressed = 1, "First HSE_Suppress(true) must set depth to 1")
	HSE_Suppress(true)
	Assert(HSE_Suppressed = 2, "Second HSE_Suppress(true) must increment to 2")
	HSE_Suppress(false)
	Assert(HSE_Suppressed > 0,
		"After one release from depth 2, HSE_Suppressed must remain > 0 (boolean-suppression-released-early-on-overlapping-fires)")
	HSE_Suppress(false)
	Assert(HSE_Suppressed = 0,
		"After matching releases HSE_Suppressed must reach 0 (boolean-suppression-released-early-on-overlapping-fires)")
	HSE_Suppressed := 0
}
Test("suppress: HSE_Suppress uses depth counter — early release does not expose engine (boolean-suppression-released-early-on-overlapping-fires)", _SRC_HSESuppressDepth)

_SRC_HSESuppressFloorZero() {
	global HSE_Suppressed
	HSE_Suppressed := 0
	HSE_Suppress(false)
	Assert(HSE_Suppressed = 0, "HSE_Suppress(false) when already 0 must not go negative")
}
Test("suppress: HSE_Suppress(false) on a zeroed counter stays at 0 (boolean-suppression-released-early-on-overlapping-fires)", _SRC_HSESuppressFloorZero)


; ====================================================
; ====================================================
; ======= 2/ PrefixWatcherSuppress refcount tests ====
; ====================================================
; ====================================================

_SRC_PWSuppressDepth() {
	global _PrefixWatcherSuppressed
	_PrefixWatcherSuppressed := 0
	PrefixWatcherSuppress(true)
	Assert(_PrefixWatcherSuppressed > 0, "PrefixWatcherSuppress(true) must increment _PrefixWatcherSuppressed")
	PrefixWatcherSuppress(true)
	Assert(_PrefixWatcherSuppressed = 2, "Second PrefixWatcherSuppress(true) must increment to 2")
	PrefixWatcherSuppress(false)
	Assert(_PrefixWatcherSuppressed > 0,
		"After one release from depth 2, _PrefixWatcherSuppressed must remain > 0 (boolean-suppression-released-early-on-overlapping-fires)")
	PrefixWatcherSuppress(false)
	Assert(_PrefixWatcherSuppressed = 0,
		"After matching releases _PrefixWatcherSuppressed must reach 0 (boolean-suppression-released-early-on-overlapping-fires)")
	_PrefixWatcherSuppressed := 0
}
Test("suppress: PrefixWatcherSuppress uses depth counter — early release does not expose watcher (boolean-suppression-released-early-on-overlapping-fires)", _SRC_PWSuppressDepth)







; ==============================================
; ==============================================
; ======= 3/ synth_active refcount tests =======
; ==============================================
; ==============================================

_SRC_SynthActiveDepth() {
	Keylogger.synth_active := 0
	KL_MarkSynthetic("hotstring")
	Assert(Keylogger.synth_active = 1, "First KL_MarkSynthetic must set synth_active to 1")
	KL_MarkSynthetic("hotstring")
	Assert(Keylogger.synth_active = 2, "Second KL_MarkSynthetic must increment to 2")
	KL_ClearSynthetic()
	Assert(Keylogger.synth_active > 0,
		"After one ClearSynthetic from depth 2, synth_active must remain > 0 (boolean-suppression-released-early-on-overlapping-fires)")
	Assert(Keylogger.synth_type = "hotstring",
		"synth_type must remain set while synth_active > 0")
	KL_ClearSynthetic()
	Assert(Keylogger.synth_active = 0,
		"After matching ClearSynthetic calls synth_active must reach 0 (boolean-suppression-released-early-on-overlapping-fires)")
	Assert(Keylogger.synth_type = "none",
		"synth_type must be reset to 'none' when synth_active reaches 0")
	Keylogger.synth_active := 0
}
Test("suppress: KL_MarkSynthetic/ClearSynthetic use depth counter — type not cleared until depth 0 (boolean-suppression-released-early-on-overlapping-fires)", _SRC_SynthActiveDepth)
