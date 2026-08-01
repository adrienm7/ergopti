; tests/meta/test_tapholdwriter_int_before_bool.ahk

; ==============================================================================
; MODULE: TapHoldWriter Integer/Float Before Boolean Guard
; DESCRIPTION:
; Static source guard for the _TH_TomlFormatLine Integer/Float type-check
; ordering fix in infra/tap_hold/tap_hold_writer.ahk.
;
; ROOT CAUSE ENCODED:
; In AHK v2, integer 0 satisfies (Value == false) because AHK uses truthiness
; comparison. If the boolean branch ran before the numeric branch, any config
; value of 0 (e.g. a key-delay set to 0 ms) would be serialised as "false"
; rather than as the integer 0. This silently corrupted the config file on the
; next write cycle.
;
; The fix adds a comment and moves the Integer/Float Type() check BEFORE the
; boolean comparison, ensuring that numeric values (including 0) are formatted
; as numbers and only actual boolean true/false reach the boolean branch.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTIB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TTIB_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ===========================================================================
; ===========================================================================
; ======= 1/ Integer/Float check precedes boolean comparison in formatter ====
; ===========================================================================
; ===========================================================================

_TTIB_IntBeforeBool() {
	Src := _TTIB_StripLineComments(_TTIB_ReadSource("infra/tap_hold/tap_hold_writer.ahk"))
	Assert(Src != "", "infra/tap_hold/tap_hold_writer.ahk must be readable")

	Body := _DriverFuncBody("_TH_TomlFormatLine")
	Assert(Body != "", "_TH_TomlFormatLine must be defined in infra/tap_hold/tap_hold_writer.ahk")

	; Both checks must be present
	IntPos  := InStr(Body, "Type(Value) == " . Chr(0x22) . "Integer" . Chr(0x22))
	BoolPos := InStr(Body, "Value == true")
	Assert(IntPos > 0,
		'_TH_TomlFormatLine must check Type(Value) == "Integer" to guard numeric values from boolean coercion')
	Assert(BoolPos > 0,
		"_TH_TomlFormatLine must check Value == true for boolean serialisation")

	; The Integer/Float check must come first
	Assert(IntPos < BoolPos,
		"_TH_TomlFormatLine must check Integer/Float BEFORE checking Value == true — AHK 0 satisfies == false so ordering matters")
}
Test("tap_hold_writer: _TH_TomlFormatLine checks Integer/Float type before boolean comparison", _TTIB_IntBeforeBool)
