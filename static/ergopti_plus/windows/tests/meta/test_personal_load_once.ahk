; tests/meta/test_personal_load_once.ahk

; ==============================================================================
; MODULE: Personal Hotstring Single-Load Guard
; DESCRIPTION:
; Regression for the B1 boot double-load. Personal hotstrings were loaded twice
; at startup: once by an inline forward loop in ErgoptiPlus.ahk (a pre-HSE
; leftover at #InputLevel 0) and again inside RegisterAllHotstrings. Because
; personal hotstrings register through HSE (CreateHotstring -> HSE_Register), not
; AHK-native Hotstring(), the #InputLevel was inert — the inline loop only
; re-parsed every personal TOML and double-registered all ~263 personal specs
; into HSE on every boot/reload, for ~80 ms of pure waste.
;
; The fix removes the inline loop and loads personal forward inside
; RegisterAllHotstrings (so first-declared sections keep winning HSE's
; first-registered-wins collision tiebreak). This guard fails if any inline
; personal load creeps back into the boot file.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Personal load guard =======
; ======================================
; ======================================

_MetaCheckPersonalLoadedOnce() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	BootFile := WindowsDir . "\ErgoptiPlus.ahk"

	try {
		Body := FileRead(BootFile)
	} catch {
		return
	}

	Assert(!InStr(Body, 'LoadHotstringsSection("personal"'),
		"ErgoptiPlus.ahk must NOT load personal hotstrings inline — RegisterAllHotstrings "
		. "already loads them. A second inline load double-registers every personal spec "
		. "into HSE and re-parses their TOML on each boot (the B1 double-load).")
}

Test("meta boot: personal hotstrings are loaded once, not inline-duplicated",
	_MetaCheckPersonalLoadedOnce)
