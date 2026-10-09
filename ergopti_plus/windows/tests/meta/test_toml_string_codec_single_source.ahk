; tests/meta/test_toml_string_codec_single_source.ahk

; ==============================================================================
; MODULE: TOML Basic-String Codec Single-Source Regression Test
; DESCRIPTION:
; Pins every production TOML string wrapper to a complete shared codec and
; exercises the control range that partial replacement lists emitted raw.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSCS_EveryWrapperDelegates() {
	for Name in ["TOML_RenderString", "TOML_RenderKey", "EscapeTomlValue",
			"_EscapeTomlString", "_WS_EscapeToml"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "" && InStr(Body, "TOML_EscapeBasicStringContents(") > 0,
			Name . " must delegate to the complete shared TOML encoder")
	}
	for Name in ["TOML_Unescape", "UnescapeTomlString", "CS_Unescape",
			"_WS_UnescapeToml"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "" && InStr(Body, "TOML_UnescapeBasicStringContents(") > 0,
			Name . " must delegate to the complete shared TOML decoder")
	}
}
Test("TOML strings: every wrapper uses one complete codec (toml-string-codec-single-source)",
	_TSCS_EveryWrapperDelegates)

_TSCS_ControlText() {
	Text := "prefix"
	Loop 31
		Text .= Chr(A_Index)
	return Text . Chr(0x7F) . "suffix"
}

_TSCS_AllControlsRoundTripWithoutRawBytes() {
	Text := _TSCS_ControlText()
	Contents := TOML_EscapeBasicStringContents(Text)
	AssertFalse(RegExMatch(Contents, "[\x00-\x1F\x7F]"),
		"encoded TOML basic-string contents must contain no forbidden raw control")
	AssertEqual(Text, TOML_UnescapeBasicStringContents(Contents),
		"the shared TOML codec must round-trip every representable control")
	AssertEqual(Chr(0x2028) . Chr(0x1F642),
		TOML_UnescapeBasicStringContents("\u2028\U0001f642"),
		"the decoder must support both TOML Unicode escape widths")

	Rendered := TOML_RenderString(Text)
	AssertFalse(RegExMatch(Rendered, "[\x00-\x1F\x7F]"),
		"TOML_RenderString must not publish a forbidden raw control")
	AssertEqual(Text, TOML_CoerceValue(Rendered),
		"the generic TOML writer and reader must share the complete grammar")
}
Test("TOML strings: controls round-trip without raw bytes (toml-string-codec-single-source)",
	_TSCS_AllControlsRoundTripWithoutRawBytes)

_TSCS_PersonalTokensRemainCanonical() {
	AssertEqual("a{Enter}b{Tab}c", EscapeTomlValue("a`nb`tc"),
		"personal hotstrings must retain their Enter/Tab token policy")
	AssertEqual(Chr(8) . Chr(12),
		UnescapeTomlString(EscapeTomlValue(Chr(8) . Chr(12))),
		"other controls must use reversible TOML escapes")
}
Test("TOML strings: personal Enter and Tab policy remains canonical (toml-string-codec-single-source)",
	_TSCS_PersonalTokensRemainCanonical)
