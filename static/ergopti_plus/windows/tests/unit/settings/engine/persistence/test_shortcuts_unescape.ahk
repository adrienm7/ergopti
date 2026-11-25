; tests/unit/settings/engine/persistence/test_shortcuts_unescape.ahk

; ==============================================================================
; MODULE: Config Shortcuts TOML Unescape Behaviour Tests
; DESCRIPTION:
; Regression guard for ahk-22, replacing a source read of CS_Unescape. The
; shortcuts loader decoded escapes with ordered replacements, so an escaped
; backslash followed by a letter (« \\n ») decoded as a backslash and a
; newline. CS_Unescape must decode left to right, as the shared TOML decoder
; does, and cover every basic-string escape.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Left-to-right decoding =======
; =========================================
; =========================================

_TCSU_DecodesLeftToRight() {
	for Vector in [
		["plain", "plain"],
		["\\n", "\n"],
		["\\\n", "\`n"],
		["a\nb", "a`nb"],
		["tab\there", "tab`there"],
		['say \"hi\"', 'say "hi"'],
		["été", Chr(0xE9) . "t" . Chr(0xE9)],
		["\U0001F600", Chr(0x1F600)],
		["\\\\", "\\"]
	] {
		AssertEqual(Vector[2], CS_Unescape(Vector[1]), "CS_Unescape decodes « " . Vector[1] . " » left to right (ahk-22)")
		AssertEqual(TOML_UnescapeBasicStringContents(Vector[1]), CS_Unescape(Vector[1]),
			"CS_Unescape agrees with the shared TOML decoder on « " . Vector[1] . " »")
	}
}
Test("settings: CS_Unescape decodes TOML escapes left to right (ahk-22)", _TCSU_DecodesLeftToRight)
