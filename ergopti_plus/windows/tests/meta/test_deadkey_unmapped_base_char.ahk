; tests/meta/test_deadkey_unmapped_base_char.ahk

; ==============================================================================
; MODULE: DeadKey Unmapped Key Base Char Guard Meta Test
; DESCRIPTION:
; Static source guard for the "deadkey-unmapped-absorbs-base-char" bug in
; modules/keymap/layout.ahk.
;
; ROOT CAUSE ENCODED:
; When a dead-key sequence receives a follow key that is NOT in the mapping
; (e.g. ¨ + q where q is not mapped), the `else` branch previously sent only
; `PressedKey` (q), silently dropping the dead-key base character (¨). The
; standard OS behaviour for an unmapped follow key is to emit the base char
; first, then the raw key: ¨q, not just q.
;
; The fix: in the `else` branch, check whether `Mapping.Has(" ")` (the space
; key conventionally holds the base char) and emit it before PressedKey.
; ==============================================================================

#Requires AutoHotkey v2.0

_DKUBC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_DKUBC_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ============================================================================
; ============================================================================
; ======= 1/ DeadKey else branch emits the base char before PressedKey =======
; ============================================================================
; ============================================================================

_DKUBC_UnmappedKeyEmitsBaseChar() {
	Raw := _DKUBC_ReadSource("modules/keymap/layout.ahk")
	Src := _DKUBC_StripComments(Raw)
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey(Mapping) must exist in modules/keymap/layout.ahk")

	; Negative: bare else that only sends PressedKey (drops the dead-key base char)
	Assert(!RegExMatch(Body, "i)\} else \{\s*\n\s*SendNewResult\(PressedKey\)"),
		"DeadKey else branch must not send only PressedKey — the base char would be silently dropped (deadkey-unmapped-absorbs-base-char)")

	; Positive: the else branch must check Mapping.Has(" ") before PressedKey
	Assert(InStr(Body, 'Mapping.Has(" ")') > 0,
		"DeadKey else branch must call Mapping.Has(" . Chr(34) . " " . Chr(34) . ") to test for a base char (deadkey-unmapped-absorbs-base-char)")

	; Positive: the base-char send must precede the PressedKey send in the body
	BaseIdx := InStr(Body, 'Mapping.Has(" ")')
	PkIdx   := InStr(Body, "SendNewResult(PressedKey)")
	; PressedKey is sent in the if-branch too -- pick the occurrence AFTER the else
	ElseIdx := InStr(Body, "} else {")
	PkAfterElse := InStr(Body, "SendNewResult(PressedKey)", false, ElseIdx)
	Assert(BaseIdx > 0 and PkAfterElse > 0 and BaseIdx < PkAfterElse,
		"DeadKey else branch must emit Mapping[" . Chr(34) . " " . Chr(34) . "] before PressedKey (deadkey-unmapped-absorbs-base-char)")
}
Test("layout: DeadKey else branch emits base char before unmapped PressedKey (deadkey-unmapped-absorbs-base-char)", _DKUBC_UnmappedKeyEmitsBaseChar)
