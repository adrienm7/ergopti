; tests/meta/test_config_shortcuts_array_escape.ahk

; ==============================================================================
; MODULE: Config Shortcuts Array-Escape Meta Test
; DESCRIPTION:
; Behavioral guard for the config-shortcuts-array-parse-escape-bug finding.
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
; The headless harness now loads config_shortcuts.ahk, so exercise the real
; decoder instead of inspecting the spelling of its local scanner variables.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Tokenizer guard assertions ============
; ==================================================
; ==================================================

_CSAE_TokenizerTracksRawEscape() {
	Values := CS_CoerceValue('["a\\", "b"]')
	AssertTrue(Values is Array)
	AssertEqual(2, Values.Length)
	AssertEqual("a\", Values[1])
	AssertEqual("b", Values[2])
}
Test("config_shortcuts: array tokenizer tracks raw-stream escape flag (config-shortcuts-array-parse-escape-bug)", _CSAE_TokenizerTracksRawEscape)

_CSAE_ElementsUnescapedExactlyOnce() {
	Values := CS_CoerceValue('["a\\n", "a\n"]')
	AssertEqual(2, Values.Length)
	AssertEqual("a\n", Values[1], "a literal backslash must not become another escape pass")
	AssertEqual("a`n", Values[2])
}
Test("config_shortcuts: array elements unescaped exactly once via CS_CoerceElement (config-shortcuts-array-parse-escape-bug)", _CSAE_ElementsUnescapedExactlyOnce)
