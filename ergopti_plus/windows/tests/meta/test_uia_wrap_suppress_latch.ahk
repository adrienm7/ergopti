; tests/meta/test_uia_wrap_suppress_latch.ahk

; ==============================================================================
; MODULE: UIA Wrap Suppress-Release Latch Meta Test
; DESCRIPTION:
; Static source guard for finding uia-wrap-suppress-latch (F-H02).
;
; The "wrap selection with a typed symbol" helper arms the
; PrefixWatcherSuppress depth counter (PrefixWatcherSuppress(true)) then runs a
; status-bearing SendInstant(...) burst that CAN throw (a Send can
; fail on a hook conflict / foreground-window race). The buggy form released the
; suppression (PrefixWatcherSuppress(false)) on the line AFTER the Sends, inside
; the same try as the throwing calls — so a throw skipped the release and latched
; the counter at >=1. Every later _OnPrefixChar / _OnPrefixKeyDown then
; early-returns on the (_PrefixWatcherSuppressed or HSE_Suppressed) guard, so NO
; hotstring ever fires and NO preview ever renders again until a reload.
;
; The fix wraps the transaction in a try and releases the suppression in a
; finally, so the depth counter is always balanced even when a Send throws.
;
; Meta-static (the prefix watcher registers a top-level InputHook and cannot be
; #Included by the headless runner): asserts the suppress(false) release sits in a
; finally that follows the throwing Send burst.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Suppress-release structure guard =======
; ===================================================
; ===================================================

_UWSL_AssertReleaseInFinally() {
	Body := _DriverFuncBody("_PrefixTryWrapSelection")
	Assert(Body != "", "_PrefixTryWrapSelection must exist in the prefix watcher")

	TruePos := InStr(Body, "PrefixWatcherSuppress(true)")
	Assert(TruePos > 0, "the UIA-wrap helper must arm PrefixWatcherSuppress(true)")

	; The throwing send burst must sit in a try that PRECEDES the finally; the
	; suppression release must live in that finally (after it), never inline after
	; the Sends where a throw would skip it.
	SendPos := InStr(Body, "SendInstant(", , TruePos)
	FinallyPos := InStr(Body, "finally", , TruePos)
	FalsePos := InStr(Body, "PrefixWatcherSuppress(false)", , TruePos)

	Assert(SendPos > TruePos, "the wrap send (SendInstant) must follow PrefixWatcherSuppress(true)")
	Assert(FinallyPos > SendPos,
		"a finally must follow the throwing SendInstant transaction so the suppression is always released (uia-wrap-suppress-latch)")
	Assert(FalsePos > FinallyPos,
		"PrefixWatcherSuppress(false) must be released INSIDE the finally (after it), not inline after the Sends where a throw skips it (uia-wrap-suppress-latch)")
}
Test("watcher: UIA wrap releases PrefixWatcherSuppress in a finally so a thrown Send cannot latch the engine dead (uia-wrap-suppress-latch)", _UWSL_AssertReleaseInFinally)
