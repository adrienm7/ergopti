; tests/meta/test_deadkey_uses_dynamic_magic_key.ahk

; ==============================================================================
; MODULE: ShouldActivateDeadkey Dynamic Magic Key Guard
; DESCRIPTION:
; Static source guard for the ShouldActivateDeadkey dynamic magic-key fix in
; modules/hotstrings.ahk.
;
; ROOT CAUSE ENCODED:
; The original implementation hardcoded the magic key glyph (the star character
; Chr(0x2605)) directly in the regex character class. If the user configured a
; different magic key via ScriptInformation["MagicKey"], the deadkey activation
; logic would still test against the hardcoded star — causing incorrect behaviour
; whenever the configured magic key differed from the default.
;
; The fix reads the magic key at runtime from ScriptInformation["MagicKey"] and
; falls back to the static star only when the key is absent. This test confirms
; that ScriptInformation["MagicKey"] is consulted inside ShouldActivateDeadkey
; rather than a bare hardcoded star literal in the regex.
; ==============================================================================

#Requires AutoHotkey v2.0

_TDUDMK_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TDUDMK_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ==============================================================================
; ==============================================================================
; ======= 1/ ShouldActivateDeadkey reads MagicKey from ScriptInformation =======
; ==============================================================================
; ==============================================================================

_TDUDMK_DynamicMagicKeyUsed() {
	Src := _TDUDMK_StripLineComments(_TDUDMK_ReadSource("modules/hotstrings.ahk"))
	Assert(Src != "", "modules/hotstrings.ahk must be readable")

	Body := _DriverFuncBody("ShouldActivateDeadkey")
	Assert(Body != "", "ShouldActivateDeadkey must be defined in modules/hotstrings.ahk")

	; Must read the magic key from ScriptInformation at runtime
	Assert(InStr(Body, "ScriptInformation[" . Chr(0x22) . "MagicKey" . Chr(0x22) . "]") > 0,
		'ShouldActivateDeadkey must read ScriptInformation["MagicKey"] instead of hardcoding the star glyph')
}
Test("hotstrings: ShouldActivateDeadkey reads MagicKey from ScriptInformation (not hardcoded)", _TDUDMK_DynamicMagicKeyUsed)

; F41 (audit 2026-07-20): two SFB triggers in hotstrings_distances.ahk re-typed the
; DEFAULT magic-key glyph as a literal instead of composing ScriptInformation["MagicKey"],
; so with a custom trigger_char those expansions silently never fired. The glyph may
; only reach a trigger through ScriptInformation (§5.2 — the key lives in one place).
_TDUDMK_NoHardcodedMagicGlyphInTriggers() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\modules\hotstrings\hotstrings_distances.ahk")
	Assert(Src != "", "modules/hotstrings/hotstrings_distances.ahk must be readable")
	Code := _StripFullLineComments(Src)
	Assert(InStr(Code, Chr(0x2605)) = 0,
		"no trigger may hardcode the magic-key glyph — compose it from ScriptInformation[MagicKey] so a custom trigger_char still fires (§5.2)")
}
Test("hotstrings: SFB triggers compose the magic key, never hardcode its glyph", _TDUDMK_NoHardcodedMagicGlyphInTriggers)
