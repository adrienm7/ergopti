; lib/text_utils.ahk

; ==============================================================================
; MODULE: Text Utilities
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

; Percent-decode a URI-encoded string. Percent-encoding is defined over BYTES,
; not codepoints: a non-ASCII character is encoded as several %XX octets that
; together form one UTF-8 multibyte sequence (e.g. "%C3%A9" is U+00E9). We must
; therefore reassemble the raw bytes into a buffer and decode the whole run as
; UTF-8 in one pass — decoding each %XX straight to Chr(0xXX) would emit one
; UTF-16 code unit per octet and corrupt every accented/non-Latin path. Literal
; characters are themselves re-encoded to their UTF-8 bytes so ASCII round-trips
; unchanged and any stray non-ASCII literal still survives the round-trip. A
; lone "%" not followed by two characters is passed through verbatim.
UriDecode(s) {
	Len := StrLen(s)
	; A UTF-8 sequence never expands beyond 4 bytes per source character, so a
	; buffer sized to the byte length of the input as UTF-8 is always sufficient.
	Buf := Buffer(StrPut(s, "UTF-8"))
	ByteLen := 0
	Pos := 1
	while (Pos <= Len) {
		Ch := SubStr(s, Pos, 1)
		if (Ch == "%" and Pos + 2 <= Len) {
			Hex := SubStr(s, Pos + 1, 2)
			; Validate hex digits before Integer() to avoid TypeError on malformed input
			if !RegExMatch(Hex, "^[0-9A-Fa-f]{2}$") {
				ByteLen += StrPut(Ch, Buf.Ptr + ByteLen, Buf.Size - ByteLen, "UTF-8") - 1
				Pos += 1
				continue
			}
			NumPut("UChar", Integer("0x" . Hex) & 0xFF, Buf, ByteLen)
			ByteLen += 1
			Pos += 3
		} else {
			; Re-encode the literal character to UTF-8 bytes. StrPut writes the
			; encoded bytes followed by a NUL terminator, so the appended length
			; is the return value minus one byte for that terminator.
			Written := StrPut(Ch, Buf.Ptr + ByteLen, Buf.Size - ByteLen, "UTF-8")
			ByteLen += Written - 1
			Pos += 1
		}
	}
	return StrGet(Buf, ByteLen, "UTF-8")
}
