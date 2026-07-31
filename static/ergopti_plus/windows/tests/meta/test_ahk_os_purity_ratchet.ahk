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
; The ratchet used to scan modules/ and lib/ only, against one combined total.
; Both halves of that were holes. ui/ was unwatched and carries 130 direct OS
; calls — 108 of them DllCall, nearly as many as modules/ and lib/ together —
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
	_AOPR_AssertTree("windows/modules + windows/lib", _AOPR_FilesIn(["modules", "lib"]), _AOPR_BASELINE_CORE)
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
