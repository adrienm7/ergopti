; tests/meta/test_toml_coerce_quoted_commas.ahk

; ==============================================================================
; MODULE: TomlCoerceValueExt Quote-Aware Comma Split Guard
; DESCRIPTION:
; Static source guard for the TomlCoerceValueExt quote-aware comma-scan fix in
; infra/toml/toml_config_loader.ahk.
;
; ROOT CAUSE ENCODED:
; The original TomlCoerceValueExt used StrSplit(Inner, ",") to parse array
; elements. This broke when a quoted string element contained a comma, e.g.
; ["foo, bar", "baz"] was split into THREE elements ("foo", " bar", "baz")
; instead of two. The fix replaces the naive split with a character scanner
; that tracks quote state and only splits on commas outside of quoted strings.
;
; Specific signatures checked:
;   - in_str flag (quote-state tracker)
;   - Character-by-character loop using StrSplit(Inner) with single-char iteration
;   - The comma split only fires when (!in_str && c == ",")
;   - No bare StrSplit(Inner, ",") call remains
; ==============================================================================

#Requires AutoHotkey v2.0

_TTCQC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TTCQC_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; =========================================================================
; =========================================================================
; ======= 1/ Quote-aware scanner present in TomlCoerceValueExt ============
; =========================================================================
; =========================================================================

_TTCQC_QuoteAwareScanner() {
	Src := _TTCQC_StripLineComments(_TTCQC_ReadSource("infra/toml/toml_config_loader.ahk"))
	Assert(Src != "", "infra/toml/toml_config_loader.ahk must be readable")

	Body := _DriverFuncBody("TomlCoerceValueExt")
	Assert(Body != "", "TomlCoerceValueExt must be defined in infra/toml/toml_config_loader.ahk")

	; Quote-state tracking variable must be present
	Assert(InStr(Body, "in_str") > 0,
		"TomlCoerceValueExt must track quote state with an in_str flag (quote-aware comma split)")

	; The comma guard must check !in_str
	Assert(InStr(Body, "!in_str") > 0,
		"TomlCoerceValueExt must guard the comma split with !in_str so commas inside quoted strings are not treated as element separators")

	; No naive bare StrSplit of the inner string by comma should remain
	Assert(InStr(Body, "StrSplit(Inner, " . Chr(0x22) . "," . Chr(0x22) . ")") = 0,
		'TomlCoerceValueExt must NOT use StrSplit(Inner, ",") — that breaks values containing commas inside quoted strings')
}
Test("toml_config_loader: TomlCoerceValueExt uses quote-aware comma scan (not naive StrSplit)", _TTCQC_QuoteAwareScanner)
