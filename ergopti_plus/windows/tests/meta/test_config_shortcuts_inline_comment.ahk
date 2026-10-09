; tests/meta/test_config_shortcuts_inline_comment.ahk

; ==============================================================================
; MODULE: config_shortcuts inline-comment strip guard
; DESCRIPTION:
; A comment must never invert a recording opt-out or truncate a quoted hash.
; Execute the decoder directly: its old source guard checked double-quote
; mechanics while literal strings were still corrupted at runtime.
; ==============================================================================

#Requires AutoHotkey v2.0

_CSIC_InlineCommentStrippedQuoteAware() {
	AssertEqual(false, CS_CoerceValue("false # recording disabled"))
	AssertEqual("editor#1.exe", CS_CoerceValue('"editor#1.exe" # application'))
	AssertEqual("editor#1.exe", CS_CoerceValue("'editor#1.exe' # literal application"))
	Apps := CS_CoerceValue("['editor#1.exe', 'browser.exe'] # exclusions")
	Assert(Apps is Array, "a comment must not hide the array terminator")
	AssertEqual(2, Apps.Length)
	AssertEqual("editor#1.exe", Apps[1])
	AssertEqual("browser.exe", Apps[2])
	Table := CS_CoerceValue("{name = 'editor#1.exe'} # application metadata")
	Assert(Table is Map, "literal hashes must survive inline-table decoding")
	AssertEqual("editor#1.exe", Table["name"])
}
Test("config_shortcuts: inline TOML comment stripped quote-aware before coercion (no bool inversion)",
	_CSIC_InlineCommentStrippedQuoteAware)
