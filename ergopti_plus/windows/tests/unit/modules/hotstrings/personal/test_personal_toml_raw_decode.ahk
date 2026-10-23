; tests/unit/modules/hotstrings/personal/test_personal_toml_raw_decode.ahk

; ==============================================================================
; MODULE: Personal Information Raw Decoder Compatibility Tests
; DESCRIPTION:
; AFTER-only qualification of the source-byte decoder against native FileRead.
; Every oracle decodes the same private file, including malformed encodings and
; embedded NUL. This does not establish a BEFORE failure against an absent helper.
; ==============================================================================

#Requires AutoHotkey v2.0

_PIRD_Vectors() {
	return [
		["empty", []],
		["ascii-crlf", [0x41, 0x0D, 0x0A, 0x42]],
		["utf8-nonascii", [0xC2, 0xA7, 0xC3, 0xA9, 0xE2, 0x82, 0xAC]],
		["utf8-astral", [0x41, 0xF0, 0x9F, 0x98, 0x80, 0x42]],
		["utf8-bom-only", [0xEF, 0xBB, 0xBF]],
		["utf8-bom-mixed", [0xEF, 0xBB, 0xBF, 0x41, 0xC2, 0xA7, 0xF0, 0x9F, 0x98, 0x80]],
		["utf8-embedded-nul", [0x41, 0x00, 0x42, 0xC3, 0xA9, 0x00, 0xF0, 0x9F, 0x98, 0x80]],
		["utf8-leading-nul", [0x00, 0x41, 0x42]],
		["utf8-repeated-nul", [0x00, 0x00]],
		["utf8-invalid-lead", [0x41, 0xFF, 0x42]],
		["utf8-isolated-continuation", [0x80, 0xBF, 0x41]],
		["utf8-overlong", [0xC0, 0xAF, 0x41]],
		["utf8-encoded-surrogate", [0xED, 0xA0, 0x80, 0x41]],
		["utf8-truncated-two", [0x41, 0xC3]],
		["utf8-truncated-three", [0x41, 0xE2, 0x82]],
		["utf8-truncated-four", [0x41, 0xF0, 0x9F, 0x98]],
		["one-byte-ascii", [0x41]],
		["one-byte-invalid", [0xFF]],
		["utf16le-bom-only", [0xFF, 0xFE]],
		["utf16le-mixed-even", [0xFF, 0xFE, 0x41, 0x00, 0xA7, 0x00, 0x3D, 0xD8, 0x00, 0xDE]],
		["utf16le-mixed-odd", [0xFF, 0xFE, 0x41, 0x00, 0xA7, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0x7F]],
		["utf16le-single-byte-after-bom", [0xFF, 0xFE, 0x41]],
		["utf16le-embedded-nul", [0xFF, 0xFE, 0x41, 0x00, 0x00, 0x00, 0x42, 0x00]],
		["utf16le-unpaired-high", [0xFF, 0xFE, 0x3D, 0xD8]],
		["utf16le-without-bom", [0x41, 0x00, 0xA7, 0x00]],
		["utf16be-no-auto", [0xFE, 0xFF, 0x00, 0x41, 0x00, 0xA7, 0xD8, 0x3D, 0xDE, 0x00]],
		["utf16be-bom-only-no-auto", [0xFE, 0xFF]]
	]
}

_PIRD_CheckBytes(Bytes, Expected, Label) {
	AssertTrue(Bytes is Buffer, Label . ": the physical image must be a Buffer")
	AssertEqual(Expected.Length, Bytes.Size, Label . ": exact raw byte count")
	for Index, Byte in Expected
		AssertEqual(Byte, NumGet(Bytes, Index - 1, "UChar"),
			Label . ": raw byte " . Index)
}

_PIRD_CheckText(Expected, Actual, Label) {
	AssertTrue(Expected is String, Label . ": native FileRead must return text")
	AssertTrue(Actual is String, Label . ": the real decoder must return text")
	ExpectedUnits := StrLen(Expected)
	AssertEqual(ExpectedUnits, StrLen(Actual), Label . ": native UTF-16 unit count")
	; Compare units rather than case-folded string equality or NUL-terminated
	; conversion. Both local strings remain owned for every pointer read.
	ExpectedPtr := StrPtr(Expected)
	ActualPtr := StrPtr(Actual)
	loop ExpectedUnits
		AssertEqual(NumGet(ExpectedPtr, (A_Index - 1) * 2, "UShort"),
			NumGet(ActualPtr, (A_Index - 1) * 2, "UShort"),
			Label . ": native UTF-16 unit " . A_Index)
}

_PIRD_One(Root, Vector) {
	Name := Vector[1]
	Octets := Vector[2]
	Bytes := Buffer(Octets.Length, 0)
	for Index, Byte in Octets
		NumPut("UChar", Byte, Bytes, Index - 1)
	Path := Root . "\" . Name . ".bin"
	File := FileOpen(Path, "w", "UTF-8-RAW")
	AssertTrue(IsObject(File), Name . ": the private raw file must open")
	try {
		if Bytes.Size
			AssertEqual(Bytes.Size, File.RawWrite(Bytes, Bytes.Size),
				Name . ": the real writer must persist the complete byte vector")
	} finally File.Close()
	AssertEqual(Octets.Length, FileGetSize(Path), Name . ": no BOM or terminator is introduced")
	Raw := FileRead(Path, "RAW")
	_PIRD_CheckBytes(Raw, Octets, Name . " before decode")
	RawPtr := Raw.Ptr
	NativeText := FileRead(Path, "UTF-8")
	Decoded := _PersonalInfoDecodeSourceBytes(Raw)
	_PIRD_CheckText(NativeText, Decoded, Name)
	AssertEqual(RawPtr, Raw.Ptr, Name . ": decoding must not replace or resize its input")
	_PIRD_CheckBytes(Raw, Octets, Name . " after decode")
	_PIRD_CheckBytes(FileRead(Path, "RAW"), Octets, Name . " after native oracle")
	return true
}

_PIRD_MatchesNativeFileRead() {
	Root := A_Temp . "\ergopti-personal-raw-decode-" . A_ScriptHwnd . "-" . A_TickCount . "-" . Random(1, 999999)
	Owned := false
	SavedEncoding := A_FileEncoding
	Completed := 0
	try {
		FSCreateDirectoryExclusiveStrict(Root)
		Owned := true
		FileEncoding("CP1252")
		Ambient := A_FileEncoding
		Vectors := _PIRD_Vectors()
		AssertEqual(27, Vectors.Length, "the complete native compatibility roster must execute")
		for Vector in Vectors {
			AssertTrue(_PIRD_One(Root, Vector), "the native oracle comparison must complete")
			Completed += 1
			AssertEqual(Ambient, A_FileEncoding, "neither decoder nor explicit FileRead may change thread encoding")
		}
		AssertEqual(27, Completed, "all native oracles, including malformed and BOM edge cases, must be reached")
	} finally {
		FileEncoding(SavedEncoding)
		if Owned
			DirDelete(Root, true)
	}
	AssertEqual(SavedEncoding, A_FileEncoding, "the original thread encoding must be restored")
}

Test("personal TOML raw decoder: matches native FileRead on complete byte vectors (personal-info-raw-decode-compat)",
	_PIRD_MatchesNativeFileRead)
