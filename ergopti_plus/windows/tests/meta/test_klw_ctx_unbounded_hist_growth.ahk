; tests/meta/test_klw_ctx_unbounded_hist_growth.ahk

; ==============================================================================
; MODULE: Walker hist-cap Meta Test
; DESCRIPTION:
; Static source guard for finding klw-ctx-unbounded-hist-growth.
;
; KLW_WalkTypingEntry maintains a per-app backspace-attribution ring,
; ctx["hist"] (alias backtrack). It is pushed on every keystroke but only
; popped on backspace, so during a long burst with few corrections it grows
; ~linearly with chars typed since the last pause-break. The whole context is
; JSON-serialised into state.json every ingest tick, so the unbounded array
; turns into O(chars) RAM plus O(chars) JSON work per tick.
;
; The fix caps the ring at KLWConst.HIST_CAP entries (>= the heptagram depth
; the walker reads back, so backspace attribution at the cap boundary is
; unaffected) by trimming the oldest entry with backtrack.RemoveAt(1) after
; each push, mirroring the existing recent_typing trim. Both push sites (the
; [BS] entry and the regular keystroke entry) must enforce the cap.
;
; This is a meta-static test (it scans source text via FileRead). A behavioral
; test would have to call KLW_WalkTypingEntry, but that needs KLW.batch
; initialised and the registry timing constants loaded (they default to 0,
; which would force a pause-break on every char and reset hist), so calling it
; in the headless runner is unsafe. If either cap guard is removed, this fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helper =====================
; ===================================================
; ===================================================

; Counts non-overlapping occurrences of Needle in Hay.
_KLWHIST_Count(Hay, Needle) {
	n := 0
	pos := 1
	while (pos := InStr(Hay, Needle, false, pos)) {
		n += 1
		pos += StrLen(Needle)
	}
	return n
}


; ===================================================
; ===================================================
; ======= 2/ Cap assertions =========================
; ===================================================
; ===================================================

_KLWHIST_HasCapConstant() {
	Src := _DriverDirConcat("modules/keylogger")
	Assert(InStr(Src, "static HIST_CAP") > 0,
		"KLWConst must declare a HIST_CAP constant bounding the backspace-attribution ring ctx[hist]")
}
Test("keylogger_walker: KLWConst declares HIST_CAP (klw-ctx-unbounded-hist-growth)", _KLWHIST_HasCapConstant)

_KLWHIST_TrimsBothPushSites() {
	Src := _DriverDirConcat("modules/keylogger")
	; The distinctive fix: trim the oldest entry once the ring exceeds the cap.
	Assert(InStr(Src, "backtrack.Length > KLWConst.HIST_CAP") > 0,
		"hist must be capped at KLWConst.HIST_CAP - without the trim it grows linearly with chars typed and is re-serialised every tick")
	Assert(InStr(Src, "backtrack.RemoveAt(1)") > 0,
		"the cap must trim the oldest entry via backtrack.RemoveAt(1), mirroring the recent_typing trim")
	; Both push sites (the [BS] entry and the regular keystroke entry) must
	; enforce the cap, otherwise one path still grows unbounded.
	Assert(_KLWHIST_Count(Src, "backtrack.Length > KLWConst.HIST_CAP") >= 2,
		"both backtrack.Push sites must enforce the HIST_CAP trim, not just one")
}
Test("keylogger_walker: both hist push sites enforce HIST_CAP trim (klw-ctx-unbounded-hist-growth)", _KLWHIST_TrimsBothPushSites)
