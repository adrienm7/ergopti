; infra/text_utils.ahk

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

; Encode one URI component over UTF-8 bytes, preserving only unreserved ASCII.
UriEncode(Value) {
	Bytes := Buffer(StrPut(Value, "UTF-8"))
	StrPut(Value, Bytes, "UTF-8")
	Encoded := ""
	Loop Bytes.Size - 1 {
		Byte := NumGet(Bytes, A_Index - 1, "UChar")
		if ((Byte >= 0x41 && Byte <= 0x5A) || (Byte >= 0x61 && Byte <= 0x7A)
				|| (Byte >= 0x30 && Byte <= 0x39) || Byte = 0x2D || Byte = 0x2E
				|| Byte = 0x5F || Byte = 0x7E) {
			Encoded .= Chr(Byte)
		} else {
			Encoded .= "%" . Format("{:02X}", Byte)
		}
	}
	return Encoded
}

; Absolute Windows paths retain their drive or UNC authority. Encode literal
; percent signs before restoring path separators, so filenames cannot create
; query strings, fragments or pre-existing escape sequences.
FilePathToUrl(Path) {
	Normalized := StrReplace(Path, "\", "/")
	Encoded := StrReplace(StrReplace(UriEncode(Normalized), "%2F", "/"), "%3A", ":")
	return "file:" . (SubStr(Normalized, 1, 2) = "//" ? "" : "///") . Encoded
}

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
			; Convert a complete literal run so UTF-16 surrogate pairs stay intact.
			; Encoding each code unit separately replaces them and can expand past
			; the buffer sized for the original string's valid UTF-8 representation.
			NextEscape := InStr(s, "%", false, Pos + 1)
			LiteralLength := NextEscape ? NextEscape - Pos : Len - Pos + 1
			Written := StrPut(SubStr(s, Pos, LiteralLength),
				Buf.Ptr + ByteLen, Buf.Size - ByteLen, "UTF-8")
			ByteLen += Written - 1
			Pos += LiteralLength
		}
	}
	return StrGet(Buf, ByteLen, "UTF-8")
}





; =========================================================
; =========================================================
; ======= 2/ Escaping a literal for the Send engine =======
; =========================================================
; =========================================================

; Escape a literal string so Send() types it verbatim.
;
; WHY IT LIVES HERE: an email address of "^a" is a real value a user can put in
; personal_info.toml, and Send() reads "^" as Ctrl. The escaping was written
; inside RegisterAllHotstrings, where only the boot-time registration could
; reach it; the fire-time @-combo resolver needs exactly the same transform on
; exactly the same values, and a second copy of it is a second thing to get
; wrong. Pure string in, pure string out, so a unit test can hold it directly.
;
; ORDER MATTERS: braces are escaped in ONE pass, character by character, before
; anything else. A sequential StrReplace would feed the "}" it just emitted for
; "{" into the next pass and turn "{" into "{{{}}}". The remaining escapes emit
; no braces of their own, so they are safe to apply in sequence afterwards.
; @param Text {String} The literal to type.
; @return {String} The same text with every Send metacharacter neutralised.
SendEscapeLiteral(Text) {
	Escaped := ""
	loop parse, Text {
		Ch := A_LoopField
		if (Ch == "{")
			Escaped .= "{{}"
		else if (Ch == "}")
			Escaped .= "{}}"
		else
			Escaped .= Ch
	}
	; Asc-form for ^ and ~ because "{^}" is not a valid Send key name.
	Escaped := StrReplace(Escaped, "^", "{Asc 94}")
	Escaped := StrReplace(Escaped, "~", "{Asc 126}")
	Escaped := StrReplace(Escaped, "+", "{+}")
	Escaped := StrReplace(Escaped, "!", "{!}")
	Escaped := StrReplace(Escaped, "#", "{#}")
	return Escaped
}


/** Counts Unicode scalars while retaining UTF-16 units for internal offsets. */
_TextCodepointLength(Text) {
	if !(Text is String)
		throw TypeError("_TextCodepointLength expects a string, got " . Type(Text) . ".")
	Units := StrLen(Text)
	Count := 0
	Position := 1
	while (Position <= Units) {
		Count += 1
		Position += _TextCodepointWidth(Text, Position, Units)
	}
	return Count
}

/** Returns the UTF-16 span erased by up to Count native Backspace events. */
_TextTailCodeUnits(Text, Count) {
	if !(Text is String) || !(Count is Integer) || Count < 0
		throw TypeError("_TextTailCodeUnits expects a string and a nonnegative integer.")
	Position := StrLen(Text)
	Start := Position
	loop Count {
		if Position == 0
			break
		Position := _TextCodepointStart(Text, Position) - 1
	}
	return Start - Position
}


/** Returns whole Unicode characters without splitting surrogate pairs. */
_TextCodepoints(Text) {
	if !(Text is String)
		throw TypeError("_TextCodepoints expects a string, got " . Type(Text) . ".")
	Characters := []
	Position := 1
	Units := StrLen(Text)
	while Position <= Units {
		Width := _TextCodepointWidth(Text, Position, Units)
		Characters.Push(SubStr(Text, Position, Width))
		Position += Width
	}
	return Characters
}

; Counting and replay share the same surrogate-pair admission rule.
_TextCodepointWidth(Text, Position, Units) {
	Unit := Ord(SubStr(Text, Position, 1))
	if Unit >= 0xD800 && Unit <= 0xDBFF && Position < Units {
		Next := Ord(SubStr(Text, Position + 1, 1))
		if Next >= 0xDC00 && Next <= 0xDFFF
			return 2
	}
	return 1
}


; Reverse scans use the same complete-pair boundary as native erasure.
_TextCodepointStart(Text, Position) {
	Unit := Ord(SubStr(Text, Position, 1))
	if Unit >= 0xDC00 && Unit <= 0xDFFF && Position > 1 {
		Previous := Ord(SubStr(Text, Position - 1, 1))
		if Previous >= 0xD800 && Previous <= 0xDBFF
			return Position - 1
	}
	return Position
}

/** Returns a contiguous suffix within a UTF-16 budget without splitting a pair. */
_TextTailWithinUnits(Text, MaxUnits) {
	if !(Text is String) || !(MaxUnits is Integer) || MaxUnits < 0
		throw TypeError("_TextTailWithinUnits expects a string and a nonnegative integer.")
	if MaxUnits == 0
		return ""
	Units := StrLen(Text)
	if Units <= MaxUnits
		return Text
	Start := Units - MaxUnits + 1
	; Moving forward drops the complete oldest pair and preserves the bound.
	if _TextCodepointStart(Text, Start) < Start
		Start += 1
	return SubStr(Text, Start)
}


/** Returns the complete scalar immediately before the final scalar, or empty. */
_TextPenultimateCodepoint(Text) {
	if !(Text is String)
		throw TypeError("_TextPenultimateCodepoint expects a string.")
	Units := StrLen(Text)
	if Units == 0
		return ""
	PreviousEnd := _TextCodepointStart(Text, Units) - 1
	if PreviousEnd == 0
		return ""
	PreviousStart := _TextCodepointStart(Text, PreviousEnd)
	return SubStr(Text, PreviousStart, PreviousEnd - PreviousStart + 1)
}
