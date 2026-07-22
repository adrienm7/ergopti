; tests/meta/test_near_miss_scan_bounded.ahk

; ==============================================================================
; MODULE: Near-Miss Scan Hot-Path Guard Meta Test
; DESCRIPTION:
; Static source guard for finding near-miss-on-hotpath-scan (F-M04).
;
; _CheckNearMiss runs an O(n) linear walk over the whole ~3180-entry _TriggerSet
; (StrLen per entry, _EditDistance1 per length-matched entry) to detect a typed
; word within edit distance 1 of a known hotstring trigger. The result is pure
; keylogger analytics (KL_LogHotstringNearMiss), which itself no-ops when the
; keylogger is inactive. The buggy form called this scan SYNCHRONOUSLY from
; _ResetPrefixBuffer on every word-boundary keystroke, inside the Critical region
; of _OnPrefixChar, even when the keylogger was off — so every space/punctuation
; during normal prose paid an uninterruptible full-corpus walk for nothing.
;
; The fix: _ResetPrefixBuffer gates the scan on Keylogger.initialized (so the
; default non-logging case pays zero) AND defers it off the Critical keystroke
; thread via SetTimer(-1); _CheckNearMiss keeps a defense-in-depth keylogger gate
; before the walk. Meta-static because the prefix watcher registers a top-level
; InputHook and cannot be #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0


_NMSB_AssertGatedAndDeferred() {
	; _CheckNearMiss must early-return when the keylogger is off, before the O(n) walk.
	Body := _DriverFuncBody("_CheckNearMiss")
	Assert(Body != "", "_CheckNearMiss(Buf) must exist")
	GatePos := InStr(Body, "Keylogger.initialized")
	ScanPos := InStr(Body, "for trig, Entry in _TriggerSet")
	Assert(GatePos > 0, "_CheckNearMiss must check Keylogger.initialized")
	Assert(ScanPos > 0, "_CheckNearMiss must scan _TriggerSet for the edit-distance check")
	Assert(GatePos < ScanPos,
		"_CheckNearMiss must early-return on !Keylogger.initialized BEFORE the O(n) _TriggerSet walk (near-miss-on-hotpath-scan)")

	; _ResetPrefixBuffer must NOT run the scan synchronously on the (Critical) keystroke
	; thread: it must gate on Keylogger.initialized and DEFER via SetTimer, never call
	; _CheckNearMiss( directly.
	Reset := _DriverFuncBody("_ResetPrefixBuffer")
	Assert(Reset != "", "_ResetPrefixBuffer must exist")
	Assert(InStr(Reset, "Keylogger.initialized") > 0,
		"_ResetPrefixBuffer must gate the near-miss scan on Keylogger.initialized so non-logging sessions pay zero (near-miss-on-hotpath-scan)")
	Assert(InStr(Reset, "SetTimer(_CheckNearMiss.Bind(") > 0,
		"_ResetPrefixBuffer must DEFER _CheckNearMiss off the Critical keystroke thread via SetTimer (near-miss-on-hotpath-scan)")
	Assert(!InStr(Reset, "_CheckNearMiss(Buf)"),
		"_ResetPrefixBuffer must not call _CheckNearMiss(Buf) synchronously on the keystroke path — defer it (near-miss-on-hotpath-scan)")
}
Test("watcher: near-miss scan is keylogger-gated and deferred off the keystroke thread (near-miss-on-hotpath-scan)", _NMSB_AssertGatedAndDeferred)
