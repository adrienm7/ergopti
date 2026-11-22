; tests/meta/suite/test_ahk_os_purity_ratchet.ahk

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
; This test counts the direct-OS-call lines outside adapters/ per file and fails
; when a file's count differs from its line in os_purity_ledger.txt: a rise, a
; fall the line must follow, or a new file. New OS access must be routed through
; windows/adapters/ (or, if truly adapter-worthy, a line changed with an explicit
; note). Lower is better; the long-term target is zero. Comment
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
; DllCalls to ui/ for free. Each tree therefore carries its own ledger, and since
; 2026-11-22 each file its own line, so one file cannot pay for another either.
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
		Src := _DriverMaskBlockComments(&Src)
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
	; The token holds the needle verbatim, so most lines need no regex at all.
	return InStr(Line, Needle) && RegExMatch(Line, "i)(?<![\p{L}\p{N}_])" . Needle . "(?![\p{L}\p{N}_])") > 0
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

; True for a UI source: a file under a ui\ folder of any feature. The core\ui
; feature's own name is no such folder: its adapters and engine are not UI
; sources, its ui\ role folder is. The ratchets partition by this role, so a
; structure move keeps a file in its tree whichever feature folder it lands in.
_AOPR_IsUiSource(Path) {
	Relative := SubStr(Path, StrLen(_AOPR_DriverRoot()) + 2)
	if SubStr(Relative, 1, 8) = "core\ui\"
		Relative := SubStr(Relative, 9)
	return InStr("\" . Relative, "\ui\") > 0
}

; The structure plan's platform domains (tools/audit/structure/rules.cjs
; PLATFORM_DOMAINS, held equal by tools/test/test-ahk-os-purity-platform.cjs):
; platform\<domain>\ is the home of a driver's OS bindings and has no adapters\
; role folder, so its files are the isolation layer as adapters\ is (decided by
; the coordinator on 2026-11-14, to review by the maintainer). Today's
; platform\remap\ and tray\adapters\ are layer folders, not platform domains.
_AOPR_PLATFORM_DOMAINS := ["desktop_focus", "focus", "input", "native", "system"]

_AOPR_IsPlatformAdapter(Path) {
	global _AOPR_PLATFORM_DOMAINS
	Relative := SubStr(Path, StrLen(_AOPR_DriverRoot()) + 2)
	for Domain in _AOPR_PLATFORM_DOMAINS
		if SubStr(Relative, 1, StrLen(Domain) + 10) = "platform\" . Domain . "\"
			return true
	return false
}

; Every .ahk file under the given driver subdirectories, recursively, with
; adapters/ and the platform domains excluded — OS calls there are the
; legitimate isolation layer. The
; crypto adapter (S02), the boot clock and timer scheduler (S03) and the
; driver control adapter (S06), the one adapter of core/lifecycle, live in
; core/ outside any adapters/ folder: they stay the same isolation layer.
; The UI sources are left to the ui pair, which counts them wherever they live.
_AOPR_FilesIn(SubDirs) {
	Files := []
	Root := _AOPR_DriverRoot()
	for SubDir in SubDirs {
		Base := Root . "\" . SubDir
		if !DirExist(Base)
			throw Error("OS-purity source directory is missing or unavailable: " . Base)
		Loop Files, Base . "\*.ahk", "R" {
			if InStr(A_LoopFilePath, "\adapters\") || _AOPR_IsUiSource(A_LoopFilePath)
				|| _AOPR_IsPlatformAdapter(A_LoopFilePath)
				|| RegExMatch(A_LoopFilePath, "\\core\\(?:crypto\\crypto|events\\(?:boot_clock|timer_scheduler)|lifecycle\\driver_control)\.ahk$")
				continue
			Files.Push(A_LoopFilePath)
		}
	}
	return Files
}

; Every UI source of the driver, adapters/ excluded, wherever its feature keeps
; it; the suite and vendored code are no driver source.
_AOPR_UiFiles() {
	Files := []
	Root := _AOPR_DriverRoot()
	Loop Files, Root . "\*.ahk", "R" {
		Relative := SubStr(A_LoopFilePath, StrLen(Root) + 2)
		if SubStr(Relative, 1, 6) = "tests\" || SubStr(Relative, 1, 7) = "vendor\"
			continue
		if InStr(A_LoopFilePath, "\adapters\") || !_AOPR_IsUiSource(A_LoopFilePath)
			continue
		Files.Push(A_LoopFilePath)
	}
	if Files.Length == 0
		throw Error("OS-purity UI source inventory is empty under " . Root)
	return Files
}

; Sums the three categories into one file's count.
_AOPR_Total(C) {
	return C["DllCall"] + C["COM"] + C["FileIO"]
}

; Per-file counts admitted in os_purity_ledger.txt beside this file, one
; "<ledger> <driver-relative path> <count>" line each. A file whose count
; differs from its line fails: a rise is a regression, a fall lowers the line
; in the same change, and a file without a line makes no such call. Six tree
; totals held this until 2026-11-22; a total let one file pay for another.
; The paths live in a data file so this source does not pin them.

/**
 * Reads one ledger of os_purity_ledger.txt.
 * @param {String} Name - The ledger, such as "calls:core".
 * @returns {Map} Driver-relative path to admitted count.
 */
_AOPR_Ledger(Name) {
	SplitPath(A_LineFile, , &OwnDir)
	Ledger := Map()
	for Line in StrSplit(FileRead(OwnDir . "\os_purity_ledger.txt", "UTF-8"), "`n", "`r") {
		Line := Trim(Line)
		if Line == "" || SubStr(Line, 1, 1) == "#"
			continue
		Parts := StrSplit(Line, " ")
		if Parts.Length != 3 || !IsInteger(Parts[3]) || Parts[3] < 1
			throw Error("os_purity_ledger.txt: malformed line " . Line)
		if Parts[1] != Name
			continue
		if Ledger.Has(Parts[2])
			throw Error("os_purity_ledger.txt lists " . Name . " " . Parts[2] . " twice")
		Ledger[Parts[2]] := Integer(Parts[3])
	}
	return Ledger
}

/**
 * Counts each file apart and compares the counts with one ledger.
 * @param {String} Name - The ledger, such as "calls:core".
 * @param {Array} Files - Absolute paths of the tree.
 * @param {Func} Total - Returns one file's count, given a one-file array.
 * @returns {String} The differences, one "path: measured N, ledger M" per line; "" when none.
 */
_AOPR_LedgerDifferences(Name, Files, Total) {
	Root := _AOPR_DriverRoot()
	Measured := Map()
	for FilePath in Files {
		Count := Total.Call([FilePath])
		if Count
			Measured[StrReplace(SubStr(FilePath, StrLen(Root) + 2), "\", "/")] := Count
	}
	Ledger := _AOPR_Ledger(Name)
	Differences := ""
	for Rel, Count in Measured
		if !Ledger.Has(Rel) || Ledger[Rel] != Count
			Differences .= "`n    " . Rel . ": measured " . Count . ", ledger " . (Ledger.Has(Rel) ? Ledger[Rel] : 0)
	for Rel, Count in Ledger
		if !Measured.Has(Rel)
			Differences .= "`n    " . Rel . ": measured 0, ledger " . Count
	return Differences
}

_AOPR_AssertTree(Label, Files, LedgerName) {
	Assert(Files.Length > 0,
		"OS-purity ratchet found NO .ahk file for '" . Label . "' — the walk is broken, "
		. "not the tree. A ratchet that scans nothing passes forever.")
	Differences := _AOPR_LedgerDifferences(LedgerName, Files, (One) => _AOPR_Total(_AOPR_CountFiles(One)))
	Assert(Differences == "",
		"Direct OS calls in " . Label . " (outside adapters/) differ from os_purity_ledger.txt "
		. LedgerName . " — route new OS access through windows/adapters/; lower a line that fell, "
		. "never raise one:" . Differences)
}





; ====================================
; ====================================
; ======= 2/ Per-tree ratchets =======
; ====================================
; ====================================

; Former tree totals, captured from this counter's own runs, now one ledger line
; per file. Drive toward zero by routing OS access through windows/adapters/.
; NEVER raise a line to make a change pass — that defeats the guard.
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
;              Re-measured 2026-10-27 at 125 (DllCall=107, COM=0, FileIO=18)
;              once the WPM widget's window-ownership check moved into the
;              window_manager adapter, and tightened to that value.
; entry point: 2026-07-31, first measurement (DllCall=3, FileIO=5).
; 2026-11-03: the startup smoke's mutex probe, exit and deadline moved into
; core/process/adapters/lifecycle.ahk; read from this counter at modules+lib 248
; (DllCall=157 COM=2 FileIO=89) and entry 7 (DllCall=6 FileIO=1), tightened.
; 2026-11-12: the layout registry watch and the metrics time zone conversions
; moved into hotstrings/adapters/registry_notify.ahk and platform/system/time_zone.ahk;
; read from this counter at modules+lib 247, tightened.
; 2026-11-22: the deferred menu build probe's thread, module and process
; counters moved into core/events/boot_clock.ahk; read at modules+lib 236
; (DllCall=159 COM=1 FileIO=76), tightened.
; 2026-11-22: the totals became the per-file ledger os_purity_ledger.txt.

; apps\engine holds the app picker and folders the structure plan took out of
; infra\; the bundled apps beside it were never part of this tree's count.
_AOPR_RatchetCore() {
	_AOPR_AssertTree("windows/modules + windows/lib", _AOPR_FilesIn(["modules", "infra", "platform", "core", "settings", "menu", "tray", "ai", "apps\engine"]), "calls:core")
}
Test("meta: windows/ OS-call purity ratchet — modules + lib", _AOPR_RatchetCore)

; The UI tree hosts the WebView2 windows, so it accumulates raw COM interfaces
; and window handles faster than anything else in the driver. It was the one
; tree the ratchet did not look at.
_AOPR_RatchetUi() {
	_AOPR_AssertTree("windows/ui", _AOPR_UiFiles(), "calls:ui")
}
Test("meta: windows/ OS-call purity ratchet — ui", _AOPR_RatchetUi)

; The entry point is a single file, but it is the one file every deployment
; runs, and nothing was watching what it calls directly.
_AOPR_RatchetEntry() {
	Entry := _AOPR_DriverRoot() . "\ErgoptiPlus.ahk"
	Assert(FileExist(Entry), "OS-purity ratchet: entry point not found at " . Entry)
	_AOPR_AssertTree("windows/ErgoptiPlus.ahk", [Entry], "calls:entry")
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
	; The token holds the name verbatim, so most lines need no regex at all.
	if !InStr(Line, Name)
		return false
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
		Src := _DriverMaskBlockComments(&Src)
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

_AOPR_AssertFamilies(Label, Files, LedgerName) {
	Assert(Files.Length > 0,
		"family ratchet found NO .ahk file for '" . Label . "' — the walk is broken, not the tree. "
		. "A ratchet that scans nothing passes forever.")
	Differences := _AOPR_LedgerDifferences(LedgerName, Files, (One) => _AOPR_FamilyTotal(_AOPR_CountFamilies(One)))
	Assert(Differences == "",
		"Platform-API family lines in " . Label . " differ from os_purity_ledger.txt " . LedgerName
		. " — prefer a manifest row or an existing helper over a new direct binding; lower a line "
		. "that fell, never raise one:" . Differences)
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
; 2026-11-03, read from this counter: core 593 (Timer=226 Binding=230 GuiMenu=32
; Process=25 Window=49 KeyState=31), tightened; entry 10 (Timer=9 KeyState=1).
; 2026-11-12: the touchpad, layout registry watch and deferred hotstring
; timers moved onto the timer adapter; read from this counter at core 592 and
; ui 182, tightened.
; 2026-11-22: the totals became the per-file ledger os_purity_ledger.txt.

_AOPR_FamilyRatchetCore() {
	_AOPR_AssertFamilies("windows/modules + windows/lib", _AOPR_FilesIn(["modules", "infra", "platform", "core", "settings", "menu", "tray", "ai", "apps\engine"]), "families:core")
}
Test("meta: windows/ platform-API family ratchet — modules + lib", _AOPR_FamilyRatchetCore)

_AOPR_FamilyRatchetUi() {
	_AOPR_AssertFamilies("windows/ui", _AOPR_UiFiles(), "families:ui")
}
Test("meta: windows/ platform-API family ratchet — ui", _AOPR_FamilyRatchetUi)

_AOPR_FamilyRatchetEntry() {
	Entry := _AOPR_DriverRoot() . "\ErgoptiPlus.ahk"
	Assert(FileExist(Entry), "family ratchet: entry point not found at " . Entry)
	_AOPR_AssertFamilies("windows/ErgoptiPlus.ahk", [Entry], "families:entry")
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
