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
		; A missing/locked source is an incomplete scan, never a lower count.
		Src := FileRead(FilePath, "UTF-8")
		Loop Parse, Src, "`n", "`r" {
			Line := Trim(A_LoopField)
			if (SubStr(Line, 1, 1) == ";")
				continue
			for Cat, Needles in Categories {
				for Needle in Needles {
					if _AOPR_IsOsToken(Line, Needle) {
						Result[Cat] += 1
						break
					}
				}
			}
		}
	}
	return Result
}

;
; A RAM-only helper can contain a built-in's name in its own identifier. Match
; the entire identifier so such helpers cannot masquerade as direct OS access.
; First-class references to real built-ins remain counted even without a call.
_AOPR_IsOsToken(Line, Needle) {
	return RegExMatch(Line, "i)(?<![\p{L}\p{N}_])" . Needle . "(?![\p{L}\p{N}_])") > 0
}

_AOPR_WholeIdentifiers() {
	for Name in ["DllCall", "ComCall", "FileRead", "FileOpen", "FileAppend", "FileDelete", "FileMove", "FileCopy"] {
		AssertTrue(_AOPR_IsOsToken(Name . "(Value)", Name), "Real native calls must remain visible.")
		AssertTrue(_AOPR_IsOsToken("Port := " . Name, Name), "Captured native built-ins remain OS references.")
		for Source in [Name . "Activity(Value)", "Wrapped" . Name . "(Value)", "_" . Name . "(Value)", Name . "É(Value)"]
			AssertFalse(_AOPR_IsOsToken(Source, Name), "An independent helper identifier is not the native built-in.")
	}
}

Test("OS purity counter: whole native identifiers and captured built-ins (os-purity-token-boundaries)", _AOPR_WholeIdentifiers)

; Every .ahk file under the given driver subdirectories, recursively, with
; adapters/ excluded — OS calls there are the legitimate isolation layer.
_AOPR_FilesIn(SubDirs) {
	Files := []
	Root := _AOPR_DriverRoot()
	for SubDir in SubDirs {
		Base := Root . "\" . SubDir
		if !DirExist(Base)
			throw Error("OS-purity source directory is missing or unavailable: " . Base)
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
;              2026-07-31 at 253 and tightened to the real value, re-measured
;              2026-09-30 at 252 (DllCall=154, COM=4, FileIO=94) and tightened
;              again. That last number comes from two independent
;              re-implementations of _AOPR_CountFiles (Python and Node, no
;              AutoHotkey available) that agree on it: the same 255 files, a
;              leading UTF-8 BOM dropped as FileRead does, lines split on LF
;              with CR trimmed, spaces and tabs trimmed, ";" lines skipped,
;              and only A-Z folded as InStr's default CaseSense does. The same
;              re-implementation reproduces the entry-point family baseline
;              below, which was read from this counter's own output, category
;              by category.
; ui:          2026-07-31, first measurement (DllCall=108, COM=2, FileIO=20).
;              Not a regression — this tree had never been counted.
; entry point: 2026-07-31, first measurement (DllCall=3, FileIO=5).
_AOPR_BASELINE_CORE  := 252
_AOPR_BASELINE_UI    := 126
_AOPR_BASELINE_ENTRY := 7

_AOPR_RatchetCore() {
	global _AOPR_BASELINE_CORE
	_AOPR_AssertTree("windows/modules + windows/lib", _AOPR_FilesIn(["modules", "infra", "platform"]), _AOPR_BASELINE_CORE)
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

; Native API identity is a token, not a suffix of a domain helper's name.
; Calls allow whitespace before '('; references such as SetTimer remain visible.
_AOPR_FamilyApiToken(Line, Needle) {
	IsCall := SubStr(Needle, StrLen(Needle), 1) == "("
	Name := IsCall ? SubStr(Needle, 1, StrLen(Needle) - 1) : Needle
	Pattern := "i)(?<![A-Za-z0-9_])" . Name . "(?![A-Za-z0-9_])"
	return RegExMatch(Line, Pattern . (IsCall ? "\s*\(" : "")) != 0
}

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
		; Keep the same failure contract as the direct-OS-call counter.
		Src := FileRead(FilePath, "UTF-8")
		Loop Parse, Src, "`n", "`r" {
			Line := Trim(A_LoopField)
			if (SubStr(Line, 1, 1) == ";")
				continue
			for Cat, Needles in Categories {
				for Needle in Needles {
					if _AOPR_FamilyApiToken(Line, Needle) {
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
; Complete-token census, 2026-10-01: helper suffixes excluded and whitespace
; calls included. Tighten the old substring budgets so they cannot pay for new
; native calls after the corrected detector stops counting domain helpers.
; core: 601 (Timer=202 Binding=241 GuiMenu=30 Process=29 Window=47 KeyState=52)
; ui:   186 (Timer=107 Binding=19 GuiMenu=46 Process=5 Window=7 KeyState=2)
; entry: 10 (Timer=8 Binding=1 GuiMenu=0 Process=0 Window=0 KeyState=1)
_AOPR_FAMILY_BASELINE_CORE  := 601
_AOPR_FAMILY_BASELINE_UI    := 186
_AOPR_FAMILY_BASELINE_ENTRY := 10

_AOPR_FamilyRatchetCore() {
	global _AOPR_FAMILY_BASELINE_CORE
	_AOPR_AssertFamilies("windows/modules + windows/lib", _AOPR_FilesIn(["modules", "infra", "platform"]), _AOPR_FAMILY_BASELINE_CORE)
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

_AOPR_FamiliesCountNativeTokensOnly() {
	Path := A_Temp . "\ergopti_native_tokens_" . A_ScriptHwnd . "_" . A_TickCount . ".txt"
	Lines := [
		"; Menu(), Run(), SetTimer, Hotkey(), WinActivate, KeyWait",
		"_MET_RebuildWidgetMenu()", "RebuildTrayMenu()", "CreateGui()",
		"OwnedRun()", "OwnedRunWait()", "OwnedSetTimer()",
		"OwnedHotkey()", "OwnedHotstring()", "OwnedHotIf()",
		"OwnedWinActivate()", "OwnedGetKeyState()", "OwnedKeyWait()",
		"SetTimer (Callback, 1)", "TimerPort := SetTimer",
		"Hotkey (Key, Callback)", "#HotIf Condition",
		"Target := Menu ()", "Surface := Gui()",
		"Run (Command)", "RunWait (Command)", "WinActivate (Title)",
		"GetKeyState (Key)", "KeyWait (Key)",
	]
	Body := ""
	for Line in Lines
		Body .= Line . "`n"
	try {
		FileAppend(Body, Path, "UTF-8-RAW")
		Counts := _AOPR_CountFamilies([Path])
		for Family, Expected in Map("Timer", 2, "Binding", 2, "GuiMenu", 2,
			"Process", 2, "Window", 1, "KeyState", 2)
			AssertEqual(Expected, Counts[Family],
				Family . " must count native tokens and whitespace calls, excluding domain suffixes and comments")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("OS-purity family census: domain helper suffixes are not native APIs",
	_AOPR_FamiliesCountNativeTokensOnly)
