; tests/unit/test_uridecode_multibyte_utf8_corruption.ahk

; ==============================================================================
; MODULE: UriDecode Multibyte UTF-8 Regression Test
; DESCRIPTION:
; Behavioral regression test for the finding
; "uridecode-multibyte-utf8-corruption".
;
; Percent-encoding is defined over BYTES, not codepoints. A non-ASCII character
; is encoded as several %XX octets that together form one UTF-8 multibyte
; sequence (e.g. "%C3%A9" is the two-byte UTF-8 form of U+00E9). The original
; UriDecode decoded each %XX straight to Chr(0xXX), emitting one UTF-16 code
; unit per octet and corrupting every accented or non-Latin path, breaking the
; Win-shortcuts "open containing folder" feature for the French-speaking user
; base whenever a path contains an accent.
;
; The fix reassembles the raw bytes into a buffer and decodes the whole run as
; UTF-8. This test asserts the correct codepoints come back. It would FAIL
; before the fix (mojibake of two/three code units) and PASS after, while the
; existing ASCII / space / lone-% cases in test_text_utils.ahk still hold.
;
; infra/text_utils.ahk is #Included by run_all.ahk and UriDecode is a pure
; function with no OS/COM/network side effects, so a behavioral test is safe.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Multibyte decode assertions ============
; ===================================================
; ===================================================

; %C3%A9 is the UTF-8 encoding of U+00E9 (LATIN SMALL LETTER E WITH ACUTE).
_UriMB_DecodesTwoByteAccent() {
	AssertEqual(Chr(0x00E9), UriDecode("%C3%A9"),
		"%C3%A9 must decode to U+00E9 (e-acute) as a single UTF-8 codepoint, not two mojibake code units")
}
Test("UriDecode: %C3%A9 decodes to U+00E9 (uridecode-multibyte-utf8-corruption)", _UriMB_DecodesTwoByteAccent)

; %E2%82%AC is the UTF-8 encoding of U+20AC (EURO SIGN).
_UriMB_DecodesThreeByteSymbol() {
	AssertEqual(Chr(0x20AC), UriDecode("%E2%82%AC"),
		"%E2%82%AC must decode to U+20AC (euro sign) as a single UTF-8 codepoint, not three mojibake code units")
}
Test("UriDecode: %E2%82%AC decodes to U+20AC (uridecode-multibyte-utf8-corruption)", _UriMB_DecodesThreeByteSymbol)

; Realistic file:// path segment: "Telechargements" with two accented e's.
_UriMB_DecodesAccentedPathSegment() {
	Expected := "T" . Chr(0x00E9) . "l" . Chr(0x00E9) . "chargements"
	AssertEqual(Expected, UriDecode("T%C3%A9l%C3%A9chargements"),
		"An accented folder name in a file:// URL must round-trip to the real path, otherwise the open-folder shortcut targets a nonexistent path")
}
Test("UriDecode: accented path segment round-trips (uridecode-multibyte-utf8-corruption)", _UriMB_DecodesAccentedPathSegment)

; ASCII mixed with a multibyte run: ensure ASCII bytes stay 1:1 and the
; multibyte run is still reassembled correctly within the same string.
_UriMB_MixedAsciiAndMultibyte() {
	Expected := "caf" . Chr(0x00E9) . "/x"
	AssertEqual(Expected, UriDecode("caf%C3%A9%2Fx"),
		"ASCII bytes must stay 1:1 while the embedded multibyte sequence is reassembled to a single codepoint")
}
Test("UriDecode: mixed ASCII and multibyte sequence decodes correctly (uridecode-multibyte-utf8-corruption)", _UriMB_MixedAsciiAndMultibyte)
