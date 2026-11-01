; tests/meta/suite/test_driver_source_constants.ahk

; ==============================================================================
; MODULE: Source Helpers Read Constants As Their Literals
; DESCRIPTION:
; PAR-74 moves config keys to the generated constants. A test pinning a key in
; driver source must then keep failing when the key changes, so the framework's
; source helpers read each constant as the literal it stands for. These vectors
; are the Node twin's (tools/test/test-config-key-tokens.cjs).
; ==============================================================================

#Requires AutoHotkey v2.0

_DSC_Resolves() {
	AssertEqual('x := Map("max_words", "llm.enabled")',
		_DriverResolveConstants("x := Map(ConfigLeaf.MAX_WORDS, ConfigKey.LLM_ENABLED)"))
	AssertEqual('A("scope_restore") B', _DriverResolveConstants("A(MenuCommand.SCOPE_RESTORE) B"))
}
Test("source helpers: a generated constant reads as its literal (par-74)", _DSC_Resolves)

_DSC_LeavesTheRest() {
	for Untouched in ["x := ConfigLeaf.NOT_A_LEAF", 'x := "ConfigLeaf.MAX_WORDS"', "x := 'ConfigLeaf.MAX_WORDS'",
		"ConfigLeaf.max_words", "MyConfigLeaf.MAX_WORDS", ""]
		AssertEqual(Untouched, _DriverResolveConstants(Untouched))
}
Test("source helpers: a misspelt or quoted constant stays as written (par-74)", _DSC_LeavesTheRest)

; The whole census must resolve, or a pin could read a reference no table holds.
_DSC_NoUnknownReference() {
	Source := _DriverSourceConcat()
	AssertTrue(InStr(Source, '"max_words"') > 0, "the census reads the literal")
	Unknown := []
	Position := 1
	Pattern := "(?<![" . Chr(34) . "'\w])\b(?:ConfigKey|ConfigLeaf|MenuCommand)\.[A-Z][A-Z0-9_]*\b"
	while RegExMatch(Source, Pattern, &Found, Position) {
		Unknown.Push(Found[0])
		Position := Found.Pos + Found.Len
	}
	AssertEqual("", Unknown.Length ? Unknown[1] : "", "every reference names a generated constant")
}
Test("source helpers: every constant in the census is generated (par-74)", _DSC_NoUnknownReference)
