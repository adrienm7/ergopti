; tests/meta/test_config_shortcuts_array_escape.ahk

; ==============================================================================
; MODULE: Config Shortcuts Array-Escape Meta Test
; DESCRIPTION:
; Static source guard for the config-shortcuts-array-parse-escape-bug finding.
;
; CS_CoerceValue() in infra/config_shortcuts.ahk hand-rolls a TOML array
; tokenizer for the metrics_disabled_apps privacy filter. The original
; tokenizer probed the ACCUMULATED string (SubStr(cur, -1)) to decide whether
; a quote was escaped. That lookbehind is unreliable: an escaped backslash
; (\\) just before a closing quote fools the probe into treating the quote as
; escaped, so the string never closes and a following comma is swallowed -
; merging two array elements into one. A merged/corrupted disabled-apps key
; then silently fails to suppress keystroke metrics for the targeted app.
;
; The fix tracks escape state from the RAW character stream via a dedicated
; ``escaped`` flag (not the accumulator) and unescapes each extracted element
; EXACTLY ONCE through a CS_CoerceElement helper instead of recursing back into
; CS_CoerceValue's quote-detection path.
;
; This is a meta-static test (scans source text) because config_shortcuts.ahk
; is NOT part of the headless run_all.ahk include graph - calling CS_CoerceValue
; directly would be a load-time "nonexistent function" error that hangs the
; runner. If the raw-stream escape flag or the single-unescape element helper
; is removed, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_CSAE_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Tokenizer guard assertions ============
; ==================================================
; ==================================================

_CSAE_TokenizerTracksRawEscape() {
	Src := _CSAE_ReadSource("infra/config_shortcuts.ahk")
	Seg := _DriverFuncBody("CS_CoerceValue")
	Assert(Seg != "", "CS_CoerceValue(raw) declaration must exist in config_shortcuts.ahk")
	; The fixed tokenizer carries a dedicated raw-stream escape flag.
	Assert(InStr(Seg, "escaped := false") > 0,
		"CS_CoerceValue array tokenizer must track escape state from the raw stream via an escaped flag - accumulator lookbehind (SubStr(cur, -1)) breaks on an escaped backslash before a closing quote and merges elements")
	; The buggy accumulator probe must be gone so it cannot regress.
	Assert(InStr(Seg, "SubStr(cur, -1)") = 0,
		"CS_CoerceValue must NOT decide quote-escaping from the accumulator (SubStr(cur, -1)) - that lookbehind is the root cause of the array-split bug")
}
Test("config_shortcuts: array tokenizer tracks raw-stream escape flag (config-shortcuts-array-parse-escape-bug)", _CSAE_TokenizerTracksRawEscape)

_CSAE_ElementsUnescapedExactlyOnce() {
	Src := _CSAE_ReadSource("infra/config_shortcuts.ahk")
	; A dedicated element coercer guarantees each quoted element is unescaped
	; exactly once instead of recursing through CS_CoerceValue again.
	Assert(InStr(Src, "CS_CoerceElement(token) {") > 0,
		"config_shortcuts.ahk must define CS_CoerceElement to unescape each array element exactly once")
	Seg := _DriverFuncBody("CS_CoerceValue")
	Assert(InStr(Seg, "CS_CoerceElement(") > 0,
		"CS_CoerceValue array tokenizer must push elements through CS_CoerceElement, not re-coerce them via CS_CoerceValue")
}
Test("config_shortcuts: array elements unescaped exactly once via CS_CoerceElement (config-shortcuts-array-parse-escape-bug)", _CSAE_ElementsUnescapedExactlyOnce)
