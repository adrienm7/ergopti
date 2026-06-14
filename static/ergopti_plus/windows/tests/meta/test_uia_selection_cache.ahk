; tests/meta/test_uia_selection_cache.ahk

; ==============================================================================
; MODULE: UIA Selection Cache Meta Test
; DESCRIPTION:
; Static source guard for the uia-selection-query-on-hot-path and
; uia-selection-blocks-keyboard-thread findings.
;
; GetUIASelection() is called on the keyboard thread for every wrap-symbol
; keystroke (from hotstring_prefix_watcher.ahk and layout.ahk). Before this
; fix, the function unconditionally ran UIA.GetFocusedElement() even when:
;   a) the focused process never exposes TextPattern (e.g. games, custom
;      win32 controls, Electron apps beyond VSCode), and
;   b) we just queried 20 ms ago and the selection was empty.
;
; The fix adds two per-process caches in layout.ahk:
;   _UIA_NO_TP_CACHE   — skip UIA entirely for 30 s after IsTextPatternAvailable
;                        returns false for a process.
;   _UIA_EMPTY_SEL_CACHE — skip re-querying for 80 ms after an empty result so
;                        rapid symbol bursts do not pay the full COM cost.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_UIASC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts the body of a named function up to the first unindented closing
; brace, stripping comment lines to avoid false positives.
_UIASC_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ===================================================
; ===================================================
; ======= 2/ Cache globals and constants ============
; ===================================================
; ===================================================

_UIASC_CacheGlobalsDeclared() {
	Src := _UIASC_ReadSource("modules/layout.ahk")
	Assert(InStr(Src, "_UIA_NO_TP_CACHE") > 0,
		"layout.ahk must declare _UIA_NO_TP_CACHE global — the per-process cache that skips UIA for processes with no TextPattern support (uia-selection-query-on-hot-path)")
	Assert(InStr(Src, "_UIA_EMPTY_SEL_CACHE") > 0,
		"layout.ahk must declare _UIA_EMPTY_SEL_CACHE global — the per-process cache that skips rapid re-queries when selection is empty (uia-selection-query-on-hot-path)")
}
Test("layout: _UIA_NO_TP_CACHE and _UIA_EMPTY_SEL_CACHE globals declared (uia-selection-query-on-hot-path)", _UIASC_CacheGlobalsDeclared)

_UIASC_TTLConstantsDeclared() {
	Src := _UIASC_ReadSource("modules/layout.ahk")
	Assert(InStr(Src, "_UIA_NO_TP_TTL_MS") > 0,
		"layout.ahk must declare _UIA_NO_TP_TTL_MS — named constant for the no-TextPattern cache TTL (rule 5.1: no magic numbers)")
	Assert(InStr(Src, "_UIA_EMPTY_SEL_TTL_MS") > 0,
		"layout.ahk must declare _UIA_EMPTY_SEL_TTL_MS — named constant for the empty-selection cache TTL (rule 5.1: no magic numbers)")
}
Test("layout: _UIA_NO_TP_TTL_MS and _UIA_EMPTY_SEL_TTL_MS constants declared (uia-selection-query-on-hot-path)", _UIASC_TTLConstantsDeclared)




; ===================================================
; ===================================================
; ======= 3/ GetUIASelection cache usage ============
; ===================================================
; ===================================================

_UIASC_NoTpCacheChecked() {
	Src := _UIASC_ReadSource("modules/layout.ahk")
	Body := _UIASC_FuncBodyStripped(Src, "GetUIASelection() {")
	Assert(Body != "", "GetUIASelection must exist in modules/layout.ahk")
	; Cache lookup must come BEFORE UIA.GetFocusedElement to avoid the COM call
	NoTpIdx := InStr(Body, "_UIA_NO_TP_CACHE")
	FocusedIdx := InStr(Body, "GetFocusedElement")
	Assert(NoTpIdx > 0,
		"GetUIASelection must read _UIA_NO_TP_CACHE before calling UIA (uia-selection-query-on-hot-path)")
	Assert(FocusedIdx > 0,
		"GetUIASelection must still call GetFocusedElement (non-cached path)")
	Assert(NoTpIdx < FocusedIdx,
		"_UIA_NO_TP_CACHE check must precede UIA.GetFocusedElement so the cache short-circuits the COM call")
}
Test("layout: GetUIASelection checks _UIA_NO_TP_CACHE before UIA.GetFocusedElement (uia-selection-query-on-hot-path)", _UIASC_NoTpCacheChecked)

_UIASC_EmptySelCacheChecked() {
	Src := _UIASC_ReadSource("modules/layout.ahk")
	Body := _UIASC_FuncBodyStripped(Src, "GetUIASelection() {")
	Assert(Body != "", "GetUIASelection must exist in modules/layout.ahk")
	Assert(InStr(Body, "_UIA_EMPTY_SEL_CACHE") > 0,
		"GetUIASelection must use _UIA_EMPTY_SEL_CACHE to skip re-querying when selection was recently empty (uia-selection-blocks-keyboard-thread)")
}
Test("layout: GetUIASelection uses _UIA_EMPTY_SEL_CACHE to skip rapid re-queries (uia-selection-blocks-keyboard-thread)", _UIASC_EmptySelCacheChecked)

_UIASC_NoTpCacheWritten() {
	Src := _UIASC_ReadSource("modules/layout.ahk")
	Body := _UIASC_FuncBodyStripped(Src, "GetUIASelection() {")
	Assert(Body != "", "GetUIASelection must exist in modules/layout.ahk")
	; The function must write _UIA_NO_TP_CACHE when IsTextPatternAvailable is false
	Assert(InStr(Body, "_UIA_NO_TP_CACHE[ProcName]") > 0,
		"GetUIASelection must write _UIA_NO_TP_CACHE[ProcName] when IsTextPatternAvailable is false so future calls skip the COM round-trip (uia-selection-query-on-hot-path)")
}
Test("layout: GetUIASelection writes _UIA_NO_TP_CACHE on TextPattern miss (uia-selection-query-on-hot-path)", _UIASC_NoTpCacheWritten)
