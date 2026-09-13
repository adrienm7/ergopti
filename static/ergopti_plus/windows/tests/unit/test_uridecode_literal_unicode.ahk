; tests/unit/test_uridecode_literal_unicode.ahk

; ==============================================================================
; MODULE: URI Literal Unicode Tests
; DESCRIPTION: Literal surrogate pairs must survive mixed URI decoding.
; ==============================================================================

#Requires AutoHotkey v2.0

_URLU_Decode(Input, Expected) {
	AssertEqual(Expected, UriDecode(Input), "literal and escaped Unicode must address the same text")
}

_URLU_Register() {
	Face := Chr(0x1F600)
	Music := Chr(0x1D11E)
	for Index, Fixture in [
		[Face, Face],
		[Face . Music, Face . Music],
		["folder/" . Face . "%20caf%C3%A9", "folder/" . Face . " café"],
		["%F0%9F%98%80/" . Music, Face . "/" . Music],
		["%G1" . Face . "%", "%G1" . Face . "%"],
		["%F0%9F%98%80", Face],
		[UriEncode(Face . Music), Face . Music]
	] {
		Test("UriDecode: literal Unicode case " . Index . " (uri-literal-unicode)",
			_URLU_Decode.Bind(Fixture[1], Fixture[2]))
	}
}
_URLU_Register()

_URLU_File() {
	Path := _CTU_NewPath() . Chr(0x1F600) . " file.txt"
	try {
		AssertTrue(FSWrite(Path, "owned Unicode URI fixture"))
		Decoded := UriDecode(StrReplace(Path, " ", "%20"))
		AssertEqual(Path, Decoded)
		AssertTrue(FSExists(Decoded), "the browser path must still resolve to the existing file")
	} finally FSDelete(Path)
}
Test("UriDecode: mixed literal browser path resolves to its file (uri-literal-unicode)", _URLU_File)
