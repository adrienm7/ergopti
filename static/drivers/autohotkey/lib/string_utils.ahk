; drivers/autohotkey/lib/string_utils.ahk

; ==============================================================================
; MODULE: String Utilities
; DESCRIPTION:
; Pure string-manipulation helpers shared across AHK modules. Extracted here
; so they can be exercised by unit tests without loading any hotkey-registration
; code from modules/.
;
; FEATURES & RATIONALE:
; 1. UriDecode: percent-decodes a URI-encoded string byte by byte. Used by
;    the Win-shortcuts module to convert file:// URLs returned by the browser
;    location bar into standard Windows paths.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ String utilities =======
; ===================================
; ===================================

; Percent-decode a URI-encoded string. Each %XX sequence is replaced by the
; character whose code point is the hexadecimal value XX.
UriDecode(s) {
	Pos := 1
	Out := ""
	while (Pos <= StrLen(s)) {
		Ch := SubStr(s, Pos, 1)
		if (Ch == "%" and Pos + 2 <= StrLen(s)) {
			Hex := SubStr(s, Pos + 1, 2)
			Out .= Chr("0x" . Hex)
			Pos += 3
		} else {
			Out .= Ch
			Pos += 1
		}
	}
	return Out
}
