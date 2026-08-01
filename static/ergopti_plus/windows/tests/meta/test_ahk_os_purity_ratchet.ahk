; tests/meta/test_ahk_os_purity_ratchet.ahk

; ==============================================================================
; MODULE: Windows OS-Call Purity Ratchet Meta Test
; DESCRIPTION:
; The AHK twin of the macOS purity ratchet (test_port_adapter_coverage.lua).
; Dependency-Inversion guard: production feature/infra code should reach the OS
; through windows/adapters/, not via direct DllCall / COM / file built-ins. The
; macOS driver hard-ratchets hs.* and io.open/os.execute; the AHK driver had NO
; equivalent guard, so 100+ DllCall and 100+ FileRead calls outside adapters/
; were completely unwatched.
;
; This test counts the direct-OS-call lines outside adapters/ and fails only if
; a total INCREASES beyond its captured baseline. New OS access must be routed
; through windows/adapters/ (or, if truly adapter-worthy, the baseline updated
; with an explicit note). Lower is better; the long-term target is zero. Comment
; lines (leading ``;``) are skipped so a comment mentioning DllCall does not
; inflate the count.
;
; THREE TREES, THREE BASELINES:
; The ratchet used to scan modules/ and infra/ only, against one combined total.
; Both halves of that were holes. ui/ was unwatched and carries 130 direct OS
; calls — 108 of them DllCall, nearly as many as modules/ and infra/ together —
; and the entry point carries 8 more; a WebView2 host is exactly the kind of
; code that accumulates raw COM and window handles, so leaving the UI tree out
; excluded the most OS-bound code in the driver. And a single combined total
; means an improvement in one tree silently pays for a regression in another:
; route ten FileReads through an adapter in modules/ and you may add ten
; DllCalls to ui/ for free. Each tree therefore carries its own frozen number.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Direct-OS-call counter =======
; =========================================
; =========================================

; A_ScriptDir is .../windows/tests when launched via run_all.ahk; its parent is
; the windows/ driver root.
_AOPR_DriverRoot() {
	SplitPath(A_ScriptDir, , &Root)
	return Root
}

; Counts, per category, the number of NON-comment source lines containing a
; direct-OS-call token in the given .ahk files. A line is counted at most once
; per category, so one line calling both DllCall and FileRead counts in each.
_AOPR_CountFiles(Files) {
	Categories := Map(
		"DllCall", ["DllCall"],
		"COM",     ["ComObject", "ComCall", "ComObjCreate", "ComObjGet", "ComObjActive"],
		"FileIO",  ["FileRead", "FileOpen", "FileAppend", "FileDelete", "FileMove", "FileCopy"])
	Result := Map("DllCall", 0, "COM", 0, "FileIO", 0)
	for FilePath in Files {
		Src := ""
		try Src := FileRead(FilePath)
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
	return Result
}

; Every .ahk file under the given driver subdirectories, recursively, with
; adapters/ excluded — OS calls there are the legitimate isolation layer.
_AOPR_FilesIn(SubDirs) {
	Files := []
	Root := _AOPR_DriverRoot()
	for SubDir in SubDirs {
		Base := Root . "\" . SubDir
		if !DirExist(Base)
			continue
		Loop Files, Base . "\*.ahk", "R" {
			if InStr(A_LoopFilePath, "\adapters\")
				continue
			Files.Push(A_LoopFilePath)
		}
	}
	return Files
}

; Sums the three categories into the single number each baseline freezes.
_AOPR_Total(C) {
	return C["DllCall"] + C["COM"] + C["FileIO"]
}

; Shared assertion body: counts one tree and compares it to its own baseline.
_AOPR_AssertTree(Label, Files, Baseline) {
	Assert(Files.Length > 0,
		"OS-purity ratchet found NO .ahk file for '" . Label . "' — the walk is broken, "
		. "not the tree. A ratchet that scans nothing passes forever.")
	C := _AOPR_CountFiles(Files)
	Total := _AOPR_Total(C)
	Assert(Total <= Baseline,
		"Direct OS calls in " . Label . " (outside adapters/) rose to " . Total . " (baseline "
		. Baseline . "): DllCall=" . C["DllCall"] . " COM=" . C["COM"]
		. " FileIO=" . C["FileIO"]
		. " — route new OS access through windows/adapters/, do not raise the baseline.")
}





; ====================================
; ====================================
; ======= 2/ Per-tree ratchets =======
; ====================================
; ====================================

; Baselines captured from this counter's own runs. Drive toward zero by routing
; OS access through windows/adapters/. NEVER raise a number to make a change
; pass — that defeats the guard.
;
; modules+lib: 2026-06-21 at 256 (DllCall=110, COM=19, FileIO=127), re-measured
;              2026-07-31 at 253 and tightened to the real value.
; ui:          2026-07-31, first measurement (DllCall=108, COM=2, FileIO=20).
;              Not a regression — this tree had never been counted.
; entry point: 2026-07-31, first measurement (DllCall=3, FileIO=5).
_AOPR_BASELINE_CORE  := 253
_AOPR_BASELINE_UI    := 130
_AOPR_BASELINE_ENTRY := 8

_AOPR_RatchetCore() {
	global _AOPR_BASELINE_CORE
	_AOPR_AssertTree("windows/modules + windows/lib", _AOPR_FilesIn(["modules", "infra"]), _AOPR_BASELINE_CORE)
}
Test("meta: windows/ OS-call purity ratchet — modules + lib", _AOPR_RatchetCore)

; The UI tree hosts the WebView2 windows, so it accumulates raw COM interfaces
; and window handles faster than anything else in the driver. It was the one
; tree the ratchet did not look at.
_AOPR_RatchetUi() {
	global _AOPR_BASELINE_UI
	_AOPR_AssertTree("windows/ui", _AOPR_FilesIn(["ui"]), _AOPR_BASELINE_UI)
}
Test("meta: windows/ OS-call purity ratchet — ui", _AOPR_RatchetUi)

; The entry point is a single file, but it is the one file every deployment
; runs, and nothing was watching what it calls directly.
_AOPR_RatchetEntry() {
	global _AOPR_BASELINE_ENTRY
	Entry := _AOPR_DriverRoot() . "\ErgoptiPlus.ahk"
	Assert(FileExist(Entry), "OS-purity ratchet: entry point not found at " . Entry)
	_AOPR_AssertTree("windows/ErgoptiPlus.ahk", [Entry], _AOPR_BASELINE_ENTRY)
}
Test("meta: windows/ OS-call purity ratchet — entry point", _AOPR_RatchetEntry)





; ==================================================
; ==================================================
; ======= 3/ Platform-API family ratchets ==========
; ==================================================
; ==================================================

; A SECOND ratchet, deliberately kept apart from the OS-call one above, because
; the two mean different things.
;
; DllCall / COM / FileIO are impurity: the long-term target is zero, because
; every one of them belongs behind an adapter. The families below are not.
; A keyboard driver legitimately binds hotkeys, arms timers and builds menus —
; telling it to stop would be telling it to stop being a keyboard driver.
;
; What makes them worth watching is that they are the surface where the driver's
; BEHAVIOUR is declared, and unbounded growth there is the exact shape of the
; AHK-only logic that ought to be manifest data instead: 312 binding lines and
; 193 timer lines in modules+lib is a lot of behaviour spelled out in code that
; other drivers express as rows. So this ratchet bounds rather than eliminates —
; and it will fall on its own as those rows migrate.
;
; Sharing one total with the OS-call ratchet would let a win in one pay for a
; regression in the other, which is the same reason the three trees already
; carry separate numbers.

_AOPR_CountFamilies(Files) {
	Categories := Map(
		"Timer",    ["SetTimer"],
		"Binding",  ["Hotkey(", "Hotstring(", "#HotIf", "HotIf("],
		"GuiMenu",  ["Gui(", "Menu(", "MenuBar(", "TrayTip"],
		"Process",  ["Run(", "RunWait("],
		"Window",   ["WinActivate", "WinExist", "WinGetTitle", "WinGetClass", "WinGetPos",
		             "WinMove", "WinShow", "WinHide", "WinClose", "WinKill", "WinWaitActive",
		             "WinGetProcessName", "WinSetTransparent", "WinGetID"],
		"KeyState", ["GetKeyState(", "KeyWait"])
	Result := Map("Timer", 0, "Binding", 0, "GuiMenu", 0, "Process", 0, "Window", 0, "KeyState", 0)
	for FilePath in Files {
		Src := ""
		try Src := FileRead(FilePath)
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
	return Result
}

_AOPR_FamilyTotal(C) {
	return C["Timer"] + C["Binding"] + C["GuiMenu"] + C["Process"] + C["Window"] + C["KeyState"]
}

_AOPR_AssertFamilies(Label, Files, Baseline) {
	Assert(Files.Length > 0,
		"family ratchet found NO .ahk file for '" . Label . "' — the walk is broken, not the tree. "
		. "A ratchet that scans nothing passes forever.")
	C := _AOPR_CountFamilies(Files)
	Total := _AOPR_FamilyTotal(C)
	Assert(Total <= Baseline,
		"Platform-API family lines in " . Label . " rose to " . Total . " (baseline " . Baseline
		. "): Timer=" . C["Timer"] . " Binding=" . C["Binding"] . " GuiMenu=" . C["GuiMenu"]
		. " Process=" . C["Process"] . " Window=" . C["Window"] . " KeyState=" . C["KeyState"]
		. " — prefer a manifest row or an existing helper over a new direct binding; "
		. "do not raise the baseline.")
}

; Baselines: 2026-07-31, first measurement of these families. Not regressions —
; nothing had ever counted them. Every number below was read from THIS counter's
; own output rather than reproduced elsewhere, and that distinction earned its
; keep immediately: a cross-check written in another language counted ui at 271
; where this counts 280, because AHK's InStr is CASE-INSENSITIVE. Here that is
; the correct behaviour, not a bug — AHK resolves function names case
; insensitively too, so `gui(` and `Gui(` are the same call and both belong in
; the count. A baseline taken from a case-sensitive tally would have frozen a
; number this rule can never produce.
;
; modules+lib: 773 (Timer=193 Binding=312 GuiMenu=63  Process=43 Window=58 KeyState=104)
; ui:          280 (Timer=76  Binding=17  GuiMenu=156 Process=15 Window=16 KeyState=0)
; entry point:  11 (Timer=8   Binding=1   GuiMenu=0   Process=1  Window=0  KeyState=1)
_AOPR_FAMILY_BASELINE_CORE  := 773
_AOPR_FAMILY_BASELINE_UI    := 280
_AOPR_FAMILY_BASELINE_ENTRY := 11

_AOPR_FamilyRatchetCore() {
	global _AOPR_FAMILY_BASELINE_CORE
	_AOPR_AssertFamilies("windows/modules + windows/lib", _AOPR_FilesIn(["modules", "infra"]), _AOPR_FAMILY_BASELINE_CORE)
}
Test("meta: windows/ platform-API family ratchet — modules + lib", _AOPR_FamilyRatchetCore)

_AOPR_FamilyRatchetUi() {
	global _AOPR_FAMILY_BASELINE_UI
	_AOPR_AssertFamilies("windows/ui", _AOPR_FilesIn(["ui"]), _AOPR_FAMILY_BASELINE_UI)
}
Test("meta: windows/ platform-API family ratchet — ui", _AOPR_FamilyRatchetUi)

_AOPR_FamilyRatchetEntry() {
	global _AOPR_FAMILY_BASELINE_ENTRY
	Entry := _AOPR_DriverRoot() . "\ErgoptiPlus.ahk"
	Assert(FileExist(Entry), "family ratchet: entry point not found at " . Entry)
	_AOPR_AssertFamilies("windows/ErgoptiPlus.ahk", [Entry], _AOPR_FAMILY_BASELINE_ENTRY)
}
Test("meta: windows/ platform-API family ratchet — entry point", _AOPR_FamilyRatchetEntry)
