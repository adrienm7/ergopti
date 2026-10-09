; tests/meta/test_toml_coerce_quoted_commas.ahk

; ==============================================================================
; MODULE: TomlCoerceValueExt Quote-Aware Comma Split Guard
; DESCRIPTION:
; Behavioral regression for quoted commas through the feature decoder.
;
; ROOT CAUSE ENCODED:
; The original TomlCoerceValueExt used StrSplit(Inner, ",") to parse array
; elements. This broke when a quoted string element contained a comma, e.g.
; ["foo, bar", "baz"] was split into THREE elements ("foo", " bar", "baz")
; instead of two. The fix replaces the naive split with a character scanner
; that tracks quote state and only splits on commas outside of quoted strings.
;
; Assertions inspect decoded elements, independent of scanner location.
; ==============================================================================

#Requires AutoHotkey v2.0



; =========================================================================
; =========================================================================
; ======= 1/ Quote-aware scanner present in TomlCoerceValueExt ============
; =========================================================================
; =========================================================================

_TTCQC_QuoteAwareScanner() {
	Values := TomlCoerceValueExt('["foo, bar", "baz", "",]')
	AssertTrue(Values is Array)
	AssertEqual(3, Values.Length)
	AssertEqual("foo, bar", Values[1])
	AssertEqual("baz", Values[2])
	AssertEqual("", Values[3])
}
Test("toml_config_loader: TomlCoerceValueExt uses quote-aware comma scan (not naive StrSplit)", _TTCQC_QuoteAwareScanner)
