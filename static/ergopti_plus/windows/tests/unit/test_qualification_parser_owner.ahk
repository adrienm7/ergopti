; tests/unit/test_qualification_parser_owner.ahk

; ==============================================================================
; MODULE: Qualification Parser Registration Ownership
; DESCRIPTION:
; The assertion library must load without JSON, while only the principal runner
; registers its actual parser. Invalid and duplicate calls retain the exact owner.
; Existing include-only and source-reader children cover real load-time warnings.
; ==============================================================================

#Requires AutoHotkey v2.0+

_TQPO_Parser(Text) {
	return Text
}

_TQPO_PrincipalRetainsActualParser() {
	global _TEST_QUALIFICATION_PARSER
	AssertTrue(_TEST_QUALIFICATION_PARSER == JsonParse, "the principal registers its actual loaded parser")
	AssertThrows(TestQualificationRegisterParser.Bind(_TQPO_Parser), "a test parser cannot replace principal ownership")
	AssertTrue(_TEST_QUALIFICATION_PARSER == JsonParse, "duplicate refusal preserves the actual production parser")
}

_TQPO_InvalidAndDuplicateRegistration() {
	global _TEST_QUALIFICATION_PARSER
	Saved := _TEST_QUALIFICATION_PARSER
	try {
		_TEST_QUALIFICATION_PARSER := 0
		for Invalid in [0, "parser", {}, Map()]
			AssertThrows(TestQualificationRegisterParser.Bind(Invalid),
				"an observation or callable-shaped value cannot register the parser")
		AssertEqual(0, _TEST_QUALIFICATION_PARSER, "invalid registration cannot acquire ownership")
		AssertEqual(1, TestQualificationRegisterParser(_TQPO_Parser))
		AssertTrue(_TEST_QUALIFICATION_PARSER == _TQPO_Parser, "registration retains the exact function")
		AssertEqual("owned", _TEST_QUALIFICATION_PARSER.Call("owned"))
		AssertThrows(TestQualificationRegisterParser.Bind(_TQPO_Parser), "even the same owner cannot register twice")
		AssertThrows(TestQualificationRegisterParser.Bind(Saved), "a second parser cannot replace the registered owner")
		AssertTrue(_TEST_QUALIFICATION_PARSER == _TQPO_Parser, "duplicate refusal preserves the exact first owner")
	} finally _TEST_QUALIFICATION_PARSER := Saved
}

_TQPO_UnregisteredQualificationRefuses() {
	global _TEST_QUALIFICATION_PARSER, _AHK_QUALIFICATION_PROFILE, _AHK_ONLY_FILTER, _AHK_DRY_RUN
	Saved := [_TEST_QUALIFICATION_PARSER, _AHK_QUALIFICATION_PROFILE, _AHK_ONLY_FILTER, _AHK_DRY_RUN]
	try {
		_TEST_QUALIFICATION_PARSER := 0, _AHK_ONLY_FILTER := "", _AHK_DRY_RUN := false
		_AHK_QUALIFICATION_PROFILE := ""
		AssertEqual("", _TestDevQualificationName(), "ordinary helper-only use needs no parser")
		_AHK_QUALIFICATION_PROFILE := "unregistered-owned-control"
		AssertThrows(_TestDevQualificationName, "an explicit qualification cannot borrow an absent parser")
		AssertEqual(0, _TEST_QUALIFICATION_PARSER, "refusal cannot fabricate parser registration")
	} finally {
		_TEST_QUALIFICATION_PARSER := Saved[1], _AHK_QUALIFICATION_PROFILE := Saved[2]
		_AHK_ONLY_FILTER := Saved[3], _AHK_DRY_RUN := Saved[4]
	}
}

Test("qualification parser owner: principal retains its actual loaded parser (qualification-parser-owner)",
	_TQPO_PrincipalRetainsActualParser)
Test("qualification parser owner: invalid and duplicate registration preserve exact ownership (qualification-parser-owner)",
	_TQPO_InvalidAndDuplicateRegistration)
Test("qualification parser owner: helper-only use stays independent and explicit unregistered admission refuses (qualification-parser-owner)",
	_TQPO_UnregisteredQualificationRefuses)
