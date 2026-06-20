; tests/meta/test_magic_key_probe_deadkey_safe.ahk

; ==============================================================================
; MODULE: Magic-Key Probe Dead-Key Safety Guard
; DESCRIPTION:
; Static source guard for the ToUnicodeEx wFlags=0x4 fix in ErgoptiPlus.ahk.
;
; ROOT CAUSE ENCODED:
; The layout probe calls ToUnicodeEx in a loop over all scancodes to find the
; physical key that produces the magic-key character. Without wFlags=0x4, each
; call may consume or corrupt the internal Win32 dead-key state. If the probe
; runs while a dead key is pending (e.g. a dead-accent on ISO layouts), subsequent
; ToUnicodeEx calls see a polluted keyboard state and the probe returns wrong
; results. wFlags=0x4 (UNICODE_NOCHAR) instructs the API not to modify dead-key
; state, making the probe side-effect-free.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers ====================
; ====================================================
; ====================================================

; Reads a windows/-relative source file. A_ScriptDir is tests/ when included
; by run_all.ahk; SplitPath steps up one level to the driver root.
_MKPDS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Strips full-line ; comments so patterns are not matched inside comment text.
_MKPDS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ==============================================================
; ==============================================================
; ======= 2/ ToUnicodeEx wFlags=0x4 assertion ==================
; ==============================================================
; ==============================================================

_MKPDS_AssertWFlags() {
	Src := _MKPDS_StripLineComments(_DriverSourceConcat())
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; The DllCall must pass 0x4 as the wFlags argument to ToUnicodeEx so that
	; the layout probe cannot corrupt pending dead-key state in the Win32 IME.
	Assert(InStr(Src, "ToUnicodeEx") > 0,
		"ErgoptiPlus.ahk must contain a ToUnicodeEx DllCall in the layout probe")
	Assert(RegExMatch(Src, "i)ToUnicodeEx[\s\S]{0,400}UInt[^,]*,\s*0x4") > 0,
		"ToUnicodeEx DllCall must pass wFlags=0x4 to prevent dead-key state corruption")
}
Test("magic-key probe: ToUnicodeEx DllCall passes wFlags=0x4 (dead-key state safe)", _MKPDS_AssertWFlags)