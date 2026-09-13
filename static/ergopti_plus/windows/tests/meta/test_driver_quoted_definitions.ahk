; tests/meta/test_driver_quoted_definitions.ahk

; ==============================================================================
; MODULE: Quoted Function Definition Tests
; DESCRIPTION:
; Continuation data cannot impersonate executable functions in source guards.
; ==============================================================================

#Requires AutoHotkey v2.0

_DSQD_NativeTarget() {
	return 42
}

_DSQD_NativeContinuation() {
	Text := "
	(
	_DSQD_NativeTarget() {
	return 7
	}
	)"
	AssertContains(Text, "return 7")
	AssertEqual(42, _DSQD_NativeTarget(), "a native continuation string cannot redefine a function")
}
Test("driver source: native continuation is data (driver-quoted-definitions)", _DSQD_NativeContinuation)

_DSQD_Extract(Kind, Indexed) {
	Literal := 'Text := "`n(`nQuotedSubject() {`n return 7`n}`n)"`n'
	Live := "QuotedSubject() {`n return 42`n}"
	switch Kind {
		case "shadow":
			Source := Literal . Live
		case "only":
			Source := Literal
		case "call before shadow":
			Source := "QuotedSubject()`n" . Literal . Live
		case "body literal":
			Source := "QuotedSubject() {`n" . Literal . " return 42`n}"
	}
	Original := Source
	if Indexed {
		Cache := _DriverFunctionBodyCache(() => Source)
		Body := Cache.Get("QuotedSubject")
		AssertEqual(Body, Cache.Get("quotedsubject"))
	} else {
		Definition := _DriverFindFunctionDefinition(&Source, "QuotedSubject")
		if Kind == "only"
			AssertFalse(IsObject(Definition), "quoted data must not define a function")
		else if Kind != "body literal"
			AssertEqual(InStr(Source, Live), Definition.Idx, "signature lookup must select executable code")
		Body := _DriverExtractFunctionBody(&Source, "QuotedSubject")
	}
	AssertEqual(Original, Source)
	if Kind == "only" {
		AssertEqual("", Body)
		return
	}
	AssertContains(Body, "return 42")
	if Kind == "body literal"
		AssertContains(Body, Literal, "returned live bodies must retain their string contents")
	else
		AssertFalse(InStr(Body, "return 7"), "the quoted decoy must not replace the live body")
}
for Indexed in [false, true]
	for Kind in ["shadow", "only", "call before shadow", "body literal"]
		Test("driver source: quoted " . Kind . " indexed=" . Indexed . " (driver-quoted-definitions)",
			_DSQD_Extract.Bind(Kind, Indexed))

_DSQD_UnicodeOffsets(Glyph, InComment) {
	Live := "UnicodeSubject() {`n return 42`n}"
	Source := (InComment ? "/* " . Glyph . " */`n" : 'Text := "' . Glyph . '"`n') . Live
	Masked := _DriverMaskNonCode(&Source)
	AssertEqual(StrLen(Source), StrLen(Masked), "mask positions must use native UTF-16 code units")
	Definition := _DriverFindFunctionDefinition(&Source, "UnicodeSubject")
	AssertEqual(InStr(Source, Live), Definition.Idx)
	AssertContains(_DriverExtractFunctionBody(&Source, "UnicodeSubject"), "return 42")
	Cache := _DriverFunctionBodyCache(() => Source)
	AssertContains(Cache.Get("UnicodeSubject"), "return 42")
}
for InComment in [false, true]
	for Glyph in ["é", "😀", "𝄞"]
		Test("driver source: Unicode offsets " . Glyph . " comment=" . InComment . " (driver-mask-unicode-offsets)",
			_DSQD_UnicodeOffsets.Bind(Glyph, InComment))
