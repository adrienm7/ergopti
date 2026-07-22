; tests/meta/test_config_shortcuts_unescape_ordering.ahk

; ==============================================================================
; MODULE: Config Shortcuts Unescape Ordering Meta Test
; DESCRIPTION:
; Regression guard for AHK-22: CS_Unescape (lib/config_shortcuts.ahk), the
; reader for the metrics-lib persistence layer (MetricsShortcuts + MetricsFilters
; via CS_Load), used the exact sequential-StrReplace ordering bug already fixed
; twice elsewhere in the codebase (TOML_Unescape in toml_helpers.ahk, guarded by
; test_toml_unescape_ordering.ahk; _WS_UnescapeToml, same guard).
;
; The bug: StrReplace(s,"\\","\") runs BEFORE StrReplace(s,"\n",newline). So a
; persisted "ctrl+\\n" (backslash-backslash-n) is decoded as:
;   pass 1 (\\->\): "ctrl+\\n" → "ctrl+\n"
;   pass 2 (\n->newline): "ctrl+\n" → "ctrl+<newline>"
; when the correct decode is "ctrl+\n" (backslash + the letter n).
;
; Patch: rewrite CS_Unescape as a single left-to-right scan, mirroring
; TOML_Unescape (toml_helpers.ahk:251) exactly, so \\ → \ and \\n → \n
; without a second-pass contamination.
;
; This test asserts (source introspection):
;   (a) CS_Unescape uses a while-loop single-pass approach (not StrReplace calls)
;       so the freed-backslash recombination cannot occur.
;   (b) The old buggy first StrReplace pass (StrReplace on "\\" before "\n")
;       is absent from CS_Unescape.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TCSUO_CheckUnescapeOrdering() {
	Body := _DriverFuncBody("CS_Unescape")
	Assert(Body != "", "CS_Unescape must exist in lib/config_shortcuts.ahk")

	; (a) Must be a single-pass while-loop scan, not a chain of StrReplace calls
	Assert(InStr(Body, "while"),
		"AHK-22: CS_Unescape must use a single left-to-right while-loop scan (mirroring TOML_Unescape in toml_helpers.ahk) — sequential StrReplace passes cause the freed-backslash recombination bug where \\n decodes to a newline instead of backslash-n")

	; (b) The old buggy StrReplace-on-backslash-backslash pattern must be gone
	; The bug was: StrReplace(s, "\\", "\") before StrReplace(s, "\n", "`n")
	; Checking for StrReplace with a double-backslash argument (the root cause)
	Assert(!InStr(Body, 'StrReplace(s, "\\\\", "\\")') && !InStr(Body, "StrReplace(s, " Chr(34) "\\\\" Chr(34)),
		"AHK-22: CS_Unescape must not use StrReplace to collapse \\\\ to \\ before the \\n pass — the sequential-StrReplace ordering bug causes \\\\n to decode to a newline character instead of backslash-n")
}


Test("meta ahk-22: CS_Unescape uses single-pass scan to avoid sequential StrReplace ordering bug that decodes \\\\n as newline",
	_TCSUO_CheckUnescapeOrdering)
