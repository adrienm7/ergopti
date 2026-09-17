; tests/meta/test_driver_block_comment_extraction.ahk

; ==============================================================================
; MODULE: Driver Block Comment Extraction Tests
; DESCRIPTION:
; Disabled definitions and delimiters cannot replace or truncate live functions.
; ==============================================================================

#Requires AutoHotkey v2.0

_DBCE_Extract(Kind, Indexed) {
	Live := "CommentSubject() {`n`treturn 42`n}"
	switch Kind {
		case "definition":
			Source := "/*`nCommentSubject() {`n`treturn 7`n}`n*/`n" . Live
		case "closing brace":
			Source := "CommentSubject() {`n/*`n}`n*/`n`treturn 42`n}"
		case "opening brace":
			Source := "CommentSubject() {`n/*`n{`n*/`n`treturn 42`n}`nSibling() {`n`treturn 7`n}"
		case "comment only":
			Source := "/*`n" . Live . "`n*/"
		case "literal":
			Source := 'CommentSubject() {`n`tValue := "/* literal */"`n`treturn 42`n}'
	}
	Original := Source
	Definition := _DriverFindFunctionDefinition(&Source, "CommentSubject")
	if Kind == "comment only"
		AssertFalse(IsObject(Definition), "direct signature lookup must ignore disabled definitions")
	else if Kind == "definition"
		AssertEqual(InStr(Source, Live), Definition.Idx, "direct signature lookup must select the live definition")
	if Indexed {
		Cache := _DriverFunctionBodyCache(() => Source)
		Body := Cache.Get("CommentSubject")
		AssertEqual(Body, Cache.Get("CommentSubject"), "cached results must retain the same live body")
	} else {
		Body := _DriverExtractFunctionBody(&Source, "CommentSubject")
	}
	AssertEqual(Original, Source, "comment masking must not mutate borrowed input")
	if Kind == "comment only" {
		AssertEqual("", Body, "a disabled definition must remain absent")
		return
	}
	AssertContains(Body, "return 42", "the complete live body must be selected")
	AssertFalse(InStr(Body, "return 7"), "a comment or sibling cannot replace the live body")
	AssertFalse(InStr(Body, "Sibling"), "comment braces cannot consume a sibling function")
	if Kind == "literal"
		AssertContains(Body, '"/* literal */"', "comment-looking string data must remain available to assertions")
}

for Indexed in [false, true]
	for Kind in ["definition", "closing brace", "opening brace", "comment only", "literal"]
		Test("driver source: block " . Kind . " indexed=" . Indexed . " (driver-block-comment-extraction)",
			_DBCE_Extract.Bind(Kind, Indexed))

_DBCE_MaskPreservesPositions() {
	Literal := 'Value := "`n/* this belongs to string data */`n"`n'
	Before := Literal . "/* ignored`n not */ a closing boundary`n */ CallAfter()`n"
	Masked := _DriverMaskBlockComments(&Before)
	AssertEqual(StrLen(Before), StrLen(Masked), "masking must preserve source offsets")
	AssertEqual(InStr(Before, "CallAfter"), InStr(Masked, "CallAfter"))
	AssertEqual(RegExReplace(Before, "[^`r`n]", ""), RegExReplace(Masked, "[^`r`n]", ""))
	AssertContains(Masked, Literal, "quoted multiline data cannot become a block comment")
	AssertFalse(InStr(Masked, "closing boundary"), "a middle-of-line marker must not terminate the comment")
	Unterminated := "CallBefore()`n/* disabled to EOF`nPhantom() {}"
	AssertEqual("CallBefore()", RTrim(_DriverMaskBlockComments(&Unterminated), " `r`n"),
		"an unclosed block must hide the rest of the source without deleting earlier code")
}
Test("driver source: block masks retain literal data and offsets (driver-block-comment-extraction)",
	_DBCE_MaskPreservesPositions)
