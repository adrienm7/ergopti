; tests/meta/test_altgr_detect_hkl_fallback.ahk

; ==============================================================================
; MODULE: AltGrDetect single-probe meta test
; DESCRIPTION:
; The boot decided the AltGr family from one read of the keyboard layout, then
; read the layout again for the AltGrDetect log line, again for the magic-key
; scan and again for the layout poll's baseline, each through its own fallback
; chain. A layout switch during the seconds of boot therefore left the family
; decided on one layout while the poll's baseline held the next: the poll saw no
; change and never reloaded, and the log named a layout that decided nothing
; (altgr-single-probe-2026-09-26). Every boot consumer now reads the record
; HotstringEngineInit keeps in _ALTGR_LAYOUT_PROBE, and the VK_RMENU probe
; lives in adapters/key_state.ahk only.
;
; SCOPE: source introspection of the entry and the driver tree.
; ==============================================================================

#Requires AutoHotkey v2.0

_AGHF_EntrySource() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk", "UTF-8")
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")
	return _StripFullLineComments(Src)
}

_AGHF_BootConsumersReadTheProbe() {
	Src := _AGHF_EntrySource()
	AssertTrue(RegExMatch(Src, 'm)^global _LAYOUT_REMAP_HKL := _ALTGR_LAYOUT_PROBE\["hkl"\]') > 0,
		"the layout the boot registrations are built for must be the layout the boot probe decided the AltGr family on")
	AssertTrue(RegExMatch(Src, 'm)^global _LAST_KEYBOARD_HKL := _LAYOUT_REMAP_HKL') > 0,
		"the layout poll's baseline must be the layout the boot registrations are built for")
	AssertTrue(InStr(Src, '_HKL := _LAYOUT_REMAP_HKL') > 0,
		"the magic-key scan must scan the layout the boot probe read")
	Detect := InStr(Src, 'LoggerInfo("AltGrDetect"')
	AssertTrue(Detect > 0, "the AltGrDetect line must still be logged")
	Block := SubStr(Src, Detect, 600)
	AssertTrue(InStr(Block, '_ALTGR_LAYOUT_PROBE["hkl"]') > 0 and InStr(Block, '_ALTGR_LAYOUT_PROBE["source"]') > 0,
		"the AltGrDetect line must log the probe that decided the family and what decided it")
	for _, Second in ["KS_ResolveKeyboardLayout()", "KS_ProbeAltGrLayout("] {
		AssertFalse(InStr(Src, Second) > 0,
			"the entry must not read or probe the layout a second time at boot: " . Second)
	}
	; The poll's own tick is the one foreground read left in the entry.
	StrReplace(Src, "GetForegroundKeyboardLayout()", , , &Reads)
	AssertEqual(1, Reads, "the entry must read the foreground layout only in the poll's tick")
	AssertTrue(InStr(_DriverFuncBody("CheckKeyboardLayoutChange"), "GetForegroundKeyboardLayout()") > 0,
		"the poll's tick must read the foreground layout to notice a switch")
}
Test("meta altgr-detect: every boot consumer reads the one layout probe (altgr-single-probe-2026-09-26)",
	_AGHF_BootConsumersReadTheProbe)

_AGHF_RMenuProbeLivesInKeyState() {
	Found := []
	SplitPath(A_ScriptDir, , &Root)
	Loop Files, Root . "\*.ahk", "FR" {
		P := StrReplace(A_LoopFileFullPath, "\", "/")
		if (InStr(P, "/tests/") or InStr(P, "/vendor/") or InStr(P, "/_generated/"))
			continue
		Src := _StripFullLineComments(FileRead(A_LoopFileFullPath, "UTF-8"))
		if RegExMatch(Src, 'i)MapVirtualKeyExW"\s*,\s*"UInt"\s*,\s*(0xA5|_?VK_RMENU|KS_VK_RMENU)\b')
			Found.Push(P)
	}
	AssertEqual(0, Found.Length, "the VK_RMENU layout probe must be the adapter's KS_ProbeAltGrLayout only; found a copy in "
		. (Found.Length ? Found[1] : ""))
	Body := _DriverFuncBody("KS_ProbeAltGrLayout")
	AssertTrue(InStr(Body, "KS_VK_RMENU") > 0, "KS_ProbeAltGrLayout must probe VK_RMENU through its named constant")
	AssertFalse(_DriverFuncBodyOrEmpty("DetectAltGrKanaRemap") != "",
		"the second probe DetectAltGrKanaRemap must stay deleted")
}
Test("meta altgr-detect: the VK_RMENU probe lives in the KeyState adapter only (altgr-single-probe-2026-09-26)",
	_AGHF_RMenuProbeLivesInKeyState)
