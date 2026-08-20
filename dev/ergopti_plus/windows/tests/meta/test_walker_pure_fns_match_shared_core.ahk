; tests/meta/test_walker_pure_fns_match_shared_core.ahk

; ==============================================================================
; MODULE: Walker Pure Functions vs The Shared Lua Core
; DESCRIPTION:
; macOS aggregation runs on _shared/lua/keylogger — thirteen of the twenty-one
; functions in its core are pure delegations to aggregator_helpers.lua and
; utils.lua. AutoHotkey cannot require a Lua module, so its walker re-implements
; the same functions by hand. Nothing holds the hand-port to the original except
; the constants gate, which pins the bucket EDGES and nothing else.
;
; Reading the two side by side on 2026-08-03 found two divergences. Neither had
; a symptom, which is the only reason they survived.
;
; 1. KLW_PopLast dropped one UTF-16 CODE UNIT. AutoHotkey v2 strings are UTF-16
;    and StrLen counts units, so any non-BMP character — an emoji from Win+. or
;    the macOS picker — occupies two, and removing one left a lone high
;    surrogate in the in-progress word buffer. The Lua side removes a whole
;    codepoint via utf8.offset(s, -1) and never produces that. Every BMP
;    character behaves identically on both, which is why nothing ever failed.
;
; 2. KLW_BurstLengthBucket returned the LITERAL "500+" for an over-cap burst,
;    while the Lua side derives the label from the bucket table it was handed
;    (tostring(buckets[#buckets]) .. "+"). The two agree only while the last
;    edge happens to be 500. test-walker-constants-single-source.cjs would not
;    notice: it pins the edges, so the constants would still match while the
;    overflow LABEL diverged — and every over-cap burst would be filed under two
;    different keys on the two drivers.
;
; WHAT THIS FILE PINS:
; Source-inspection, matching the rest of this suite: the walker cannot be
; executed in isolation, so the guarantee is stated against the two function
; bodies. Both assertions fail against the pre-fix source.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ The Two Cross-Driver Divergences =======
; ===================================================
; ===================================================

_WPF_PopLastHandlesSurrogatePairs() {
	Body := _DriverFuncBody("KLW_PopLast")
	Assert(Body != "", "KLW_PopLast must exist in the walker core")

	; The naive form is the bug: it drops one UTF-16 code unit regardless.
	Naive := InStr(Body, "StrLen(s) - 1") > 0
	Guarded := InStr(Body, "0xDC00") > 0

	Assert(Guarded,
		"KLW_PopLast must recognise a trailing LOW surrogate (0xDC00-0xDFFF) and drop both "
		. "units. AutoHotkey v2 counts UTF-16 code units, so removing one from an emoji leaves "
		. "half a surrogate pair in the word buffer — a broken string the shared Lua core never "
		. "produces, because utf8.offset() there removes a whole codepoint")
	Assert(!Naive or Guarded,
		"KLW_PopLast must not fall back to the unconditional StrLen(s) - 1 truncation")
}


_WPF_BucketOverflowLabelIsDerived() {
	Body := _DriverFuncBody("KLW_BurstLengthBucket")
	Assert(Body != "", "KLW_BurstLengthBucket must exist in the walker core")

	Assert(InStr(Body, Chr(34) . "500+" . Chr(34)) = 0,
		"KLW_BurstLengthBucket must not hardcode the overflow label. The shared Lua core "
		. "derives it from the bucket table, so a literal here agrees only while the last edge "
		. "happens to be 500 — and the constants gate pins the EDGES, so it would keep passing "
		. "while the label diverged and over-cap bursts were filed under two different keys")

	Assert(InStr(Body, "BURST_LENGTH_BUCKETS") > 0,
		"the overflow label must be derived from KLWConst.BURST_LENGTH_BUCKETS, the same table "
		. "the loop above it walks — one source, not two")
}


Test("walker pure fns: KLW_PopLast keeps surrogate pairs whole (walker-shared-core-parity)",
	_WPF_PopLastHandlesSurrogatePairs)
Test("walker pure fns: the bucket overflow label is derived, not literal (walker-shared-core-parity)",
	_WPF_BucketOverflowLabelIsDerived)
