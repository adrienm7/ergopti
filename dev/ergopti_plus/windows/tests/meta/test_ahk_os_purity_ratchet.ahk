; tests/meta/test_ahk_os_purity_ratchet.ahk

; ==============================================================================
; MODULE: Windows OS-Call Purity Ratchet Meta Test
; DESCRIPTION:
; The AHK twin of the macOS purity ratchet (test_port_adapter_coverage.lua).
; Dependency-Inversion guard: production feature/infra code in windows/modules
; and windows/lib should reach the OS through windows/adapters/, not via direct
; DllCall / COM / file built-ins. The macOS driver hard-ratchets hs.* and
; io.open/os.execute; the AHK driver had NO equivalent guard, so 100+ DllCall
; and 100+ FileRead calls outside adapters/ were completely unwatched.
;
; This test counts the direct-OS-call lines outside adapters/ and fails only if
; the total INCREASES beyond the captured baseline — exactly like the macOS
; ratchet. New OS access must be routed through windows/adapters/ (or, if truly
; adapter-worthy, the baseline updated with an explicit note). Lower is better;
; the long-term target is zero. Comment lines (leading ``;``) are skipped so a
; comment mentioning DllCall does not inflate the count.
; ==============================================================================

#Requires AutoHotkey v2.0

; A_ScriptDir is .../windows/tests when launched via run_all.ahk; its parent is
; the windows/ driver root.
_AOPR_DriverRoot() {
	SplitPath(A_ScriptDir, , &Root)
	return Root
}

; Counts, per category, the number of NON-comment source lines containing a
; direct-OS-call token in windows/modules and windows/lib (adapters/ excluded —
; OS calls there are the legitimate isolation layer). A line is counted at most
; once per category.
_AOPR_Counts() {
	Categories := Map(
		"DllCall", ["DllCall"],
		"COM",     ["ComObject", "ComCall", "ComObjCreate", "ComObjGet", "ComObjActive"],
		"FileIO",  ["FileRead", "FileOpen", "FileAppend", "FileDelete", "FileMove", "FileCopy"])
	Result := Map("DllCall", 0, "COM", 0, "FileIO", 0)
	Root := _AOPR_DriverRoot()
	for SubDir in ["modules", "lib"] {
		Base := Root . "\" . SubDir
		if !DirExist(Base)
			continue
		Loop Files, Base . "\*.ahk", "R" {
			if InStr(A_LoopFilePath, "\adapters\")
				continue
			Src := ""
			try Src := FileRead(A_LoopFilePath)
			Loop Parse, Src, "`n", "`r" {
				Line := Trim(A_LoopField)
				if (SubStr(Line, 1, 1) == ";")
					continue
				for Cat, Needles in Categories {
					for Needle in Needles {
						if InStr(Line, Needle) {
							Result[Cat] += 1
							break
						}
					}
				}
			}
		}
	}
	return Result
}

; Baseline captured 2026-06-21 from this counter's own first run
; (DllCall=110, COM=19, FileIO=127). Drive toward zero by routing OS access
; through windows/adapters/. NEVER raise this number to make a change pass — that
; defeats the guard.
_AOPR_BASELINE := 256

_AOPR_RatchetTest() {
	global _AOPR_BASELINE
	C := _AOPR_Counts()
	Total := C["DllCall"] + C["COM"] + C["FileIO"]
	Assert(Total <= _AOPR_BASELINE,
		"Direct OS calls outside windows/adapters/ rose to " . Total . " (baseline "
		. _AOPR_BASELINE . "): DllCall=" . C["DllCall"] . " COM=" . C["COM"]
		. " FileIO=" . C["FileIO"]
		. " — route new OS access through windows/adapters/, do not raise the baseline.")
}
Test("meta: windows/ OS-call purity ratchet (DllCall/COM/FileIO outside adapters/)", _AOPR_RatchetTest)
