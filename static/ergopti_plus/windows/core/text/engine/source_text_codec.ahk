; core/text/engine/source_text_codec.ahk

; ==============================================================================
; MODULE: Exact Native Source Text Codec
; DESCRIPTION:
; Decodes one captured UTF-8 or UTF-16LE byte image without replacing malformed
; units or unsupported native NUL. Pure decoding is available during early boot.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Decodes captured source bytes with UTF-8/UTF-16LE BOM handling. */
SourceTextDecodeExact(Bytes) {
	if !(Bytes is Buffer)
		throw TypeError("A text source must be raw bytes.")
	if Bytes.Size == 0
		return ""
	if Bytes.Size >= 2 && NumGet(Bytes, 0, "UChar") == 0xFF && NumGet(Bytes, 1, "UChar") == 0xFE {
		if Mod(Bytes.Size - 2, 2)
			throw ValueError("The text UTF-16 source has an incomplete code unit.")
		Units := (Bytes.Size - 2) // 2
		SourceTextRequireUnicodeScalars(Bytes, 2, Units)
		return Units ? StrGet(Bytes.Ptr + 2, -Units, "UTF-16") : ""
	}
	Offset := Bytes.Size >= 3 && NumGet(Bytes, 0, "UChar") == 0xEF
		&& NumGet(Bytes, 1, "UChar") == 0xBB && NumGet(Bytes, 2, "UChar") == 0xBF ? 3 : 0
	Length := Bytes.Size - Offset
	if Length == 0
		return ""
	if Length > 0x7FFFFFFF
		throw ValueError("The text UTF-8 source exceeds the native decoder domain.")
	; MB_ERR_INVALID_CHARS refuses invalid, overlong and non-scalar UTF-8;
	; neither pass reads the path again or modifies the original source Buffer.
	Units := DllCall("Kernel32\MultiByteToWideChar", "UInt", 65001, "UInt", 8,
		"Ptr", Bytes.Ptr + Offset, "Int", Length, "Ptr", 0, "Int", 0, "Int")
	if Units <= 0
		throw ValueError("The text UTF-8 source is malformed.")
	Wide := Buffer((Units + 1) * 2, 0)
	Written := DllCall("Kernel32\MultiByteToWideChar", "UInt", 65001, "UInt", 8,
		"Ptr", Bytes.Ptr + Offset, "Int", Length, "Ptr", Wide, "Int", Units, "Int")
	if Written != Units
		throw ValueError("The text UTF-8 source could not be decoded completely.")
	SourceTextRequireUnicodeScalars(Wide, 0, Units)
	return StrGet(Wide, -Units, "UTF-16")
}

/** Requires complete native UTF-16 scalars, excluding unsupported NUL. */
SourceTextRequireUnicodeScalars(Bytes, Offset, Units) {
	Index := 0
	while Index < Units {
		Code := NumGet(Bytes, Offset + Index * 2, "UShort")
		if Code == 0
			throw ValueError("The text source contains an unsupported Unicode scalar.")
		if Code >= 0xD800 && Code <= 0xDBFF {
			if Index + 1 >= Units
				throw ValueError("The text source contains an unpaired UTF-16 surrogate.")
			Low := NumGet(Bytes, Offset + (Index + 1) * 2, "UShort")
			if Low < 0xDC00 || Low > 0xDFFF
				throw ValueError("The text source contains an unpaired UTF-16 surrogate.")
			Index += 2
			continue
		}
		if Code >= 0xDC00 && Code <= 0xDFFF
			throw ValueError("The text source contains an unpaired UTF-16 surrogate.")
		Index += 1
	}
}
