; tests/meta/adapters/test_port_adapter_coverage.ahk

; ==============================================================================
; MODULE: Port-Adapter Coverage Meta-Test
; DESCRIPTION:
; Verifies three structural invariants of the hexagonal architecture:
;
; 1. ADAPTER PRESENCE  --  Every port spec in _shared/core/ports/*.spec.js has a
;    matching adapter file in static/ergopti_plus/windows/adapters/ and in
;    static/ergopti_plus/macos/adapters/. A missing adapter means a port
;    contract exists on paper but is not honoured by a driver.
;
; 2. DOMAIN TEST COVERAGE  --  Every domain spec in _shared/core/domain/*.spec.js
;    has at least one corresponding test file in at least one driver's test
;    suite. An untested domain spec is a dead letter.
;
; 3. SHARED PURITY  --  No file under _shared/ directly calls OS-level APIs
;    (io.open, hs., SendInput, SendEvent, TrayTip). Shared code must be
;    pure logic; OS access must go through port adapters.
; ==============================================================================





; ==========================================
; ==========================================
; ======= 1/ Filesystem scan helpers =======
; ==========================================
; ==========================================

_MetaPACListFiles(Dir, Ext) {
	Files := []
	; Use AHK's built-in Loop Files instead of cmd /c dir so the function works
	; in any execution context without shell-redirection quirks.
	WinDir := StrReplace(Dir, "/", "\")
	try {
		Loop Files, WinDir . "\*." . Ext, "R" {
			Files.Push(StrReplace(A_LoopFileFullPath, "\", "/"))
		}
	}
	return Files
}

; Returns the base name without ALL extensions (e.g. "foo.spec.js" -> "foo").
_MetaPACBaseName(Path) {
	; SplitPath only splits on backslashes — normalise forward slashes first.
	SplitPath(StrReplace(Path, "/", "\"), &Name)
	; Strip compound extension .spec.js in one pass, then any remaining extension
	Name := RegExReplace(Name, "\.spec\.[^.]+$", "")
	return RegExReplace(Name, "\.[^.]+$", "")
}

; Converts PascalCase to snake_case (e.g. "KeyboardHook" -> "keyboard_hook").
_MetaPACToSnake(S) {
	S := RegExReplace(S, "([A-Z])", "_$L1")
	return LTrim(StrLower(S), "_")
}





; =============================================
; =============================================
; ======= 2/ Adapter-presence invariant =======
; =============================================
; =============================================

_MetaRunAdapterPresenceTests() {
	RepoRoot := StrReplace(A_ScriptDir, "\", "/")
	; A_ScriptDir is always the main script's dir (tests/) regardless of which
	; #Include'd file is executing — strip everything from /static/... onward.
	RepoRoot := RegExReplace(RepoRoot, "/static/ergopti_plus/windows/tests(/meta)?$", "")

	SharedPorts := RepoRoot . "/static/ergopti_plus/_shared/core/ports"
	AhkAdapters   := RepoRoot . "/static/ergopti_plus/windows/adapters"
	HsAdapters    := RepoRoot . "/static/ergopti_plus/macos/adapters"
	LinuxAdapters := RepoRoot . "/static/ergopti_plus/linux/adapters"

	SpecFiles    := _MetaPACListFiles(SharedPorts, "js")
	MissingAhk   := 0
	MissingHs    := 0
	MissingLinux := 0
	SpecCount    := 0

	for SpecPath in SpecFiles {
		if not SpecPath ~= "i)\.spec\.js$" {
			continue
		}
		SpecCount++
		RawName   := _MetaPACBaseName(SpecPath)
		SnakeName := _MetaPACToSnake(RawName)
		AhkFile   := AhkAdapters   . "/" . SnakeName . ".ahk"
		HsFile    := HsAdapters    . "/" . SnakeName . ".lua"
		LinuxFile := LinuxAdapters . "/" . SnakeName . ".lua"
		if not FileExist(StrReplace(AhkFile, "/", "\")) {
			MissingAhk++
			OutputDebug("WARN: AHK adapter missing for port '" . RawName . "': " . AhkFile)
		}
		if not FileExist(StrReplace(HsFile, "/", "\")) {
			MissingHs++
			OutputDebug("WARN: HS adapter missing for port '" . RawName . "': " . HsFile)
		}
		; Counted for the report below, not to gate on. See _ResultAdapterLinux.
		if not FileExist(StrReplace(LinuxFile, "/", "\")) {
			MissingLinux++
			OutputDebug("WARN: Linux adapter missing for port '" . RawName . "': " . LinuxFile)
		}
	}

	_ResultAdapterAhk() {
		Assert(SpecCount > 0, "no *.spec.js found in _shared/core/ports  --  check RepoRoot")
		Assert(MissingAhk = 0, "meta: " . MissingAhk . " AHK adapter(s) missing  --  see OutputDebug")
	}
	Test("meta port coverage: every port spec has an AHK adapter (" . SpecCount . " specs)", _ResultAdapterAhk)

	_ResultAdapterHs() {
		Assert(MissingHs = 0, "meta: " . MissingHs . " HS adapter(s) missing  --  see OutputDebug")
	}
	Test("meta port coverage: every port spec has a HS adapter (" . SpecCount . " specs)", _ResultAdapterHs)

	; Deliberately NOT asserted for Linux, and this is the fourth place the same
	; sentence had to be undone. ADR-008 supersedes ADR-001's "adding a new driver
	; requires only implementing the twenty port adapters": a port is a contract
	; for the drivers that need the capability, not a checklist. Requiring a file
	; per spec here is what produced nine Linux adapters with no production caller
	; -- every one of them satisfying this very assertion while nothing reached it.
	;
	; The count is still computed and reported, because "which ports does Linux
	; not implement?" is a useful thing to be able to read. What IS enforced is
	; the other direction, by tools/test/test-adapter-reachability.cjs: an adapter
	; that exists must be required by something, held at zero on all three drivers.
	_ResultAdapterLinux() {
		Assert(SpecCount > 0, "no *.spec.js files found  --  the scan is broken and this reports nothing")
		Assert(MissingLinux >= 0,
			"the Linux coverage count must be computed even though it is not enforced  --  "
			. "an unread number stops being maintained")
		OutputDebug("INFO: Linux implements " . (SpecCount - MissingLinux) . "/" . SpecCount . " port(s).")
	}
	Test("meta port coverage: Linux port coverage is reported, not mandated (" . SpecCount . " specs)", _ResultAdapterLinux)
}
_MetaRunAdapterPresenceTests()





; =================================================
; =================================================
; ======= 3/ Domain-test-coverage invariant =======
; =================================================
; =================================================

_MetaRunDomainCoverageTests() {
	RepoRoot := StrReplace(A_ScriptDir, "\", "/")
	; A_ScriptDir is always the main script's dir (tests/) regardless of which
	; #Include'd file is executing — strip everything from /static/... onward.
	RepoRoot := RegExReplace(RepoRoot, "/static/ergopti_plus/windows/tests(/meta)?$", "")

	DomainDir  := RepoRoot . "/static/ergopti_plus/_shared/core/domain"
	AhkTests   := RepoRoot . "/static/ergopti_plus/windows/tests"
	HsTests    := RepoRoot . "/static/ergopti_plus/macos/tests"

	DomainSpecs  := _MetaPACListFiles(DomainDir, "js")
	AllAhkTests  := _MetaPACListFiles(AhkTests,  "ahk")
	AllHsTests   := _MetaPACListFiles(HsTests,   "lua")

	Uncovered := 0
	SpecCount := 0

	for SpecPath in DomainSpecs {
		if not SpecPath ~= "i)\.spec\.js$" {
			continue
		}
		SpecCount++
		LowerName := StrLower(_MetaPACBaseName(SpecPath))
		; Strip common suffixes so "GestureRecognizer" -> "gesture" matches "test_gestures"
		ShortName := RegExReplace(LowerName, "(recognizer|manager|handler|engine|builder)$", "")
		HasTest   := false

		for TestPath in AllAhkTests {
			TName   := StrLower(_MetaPACBaseName(TestPath))
			Keyword := RegExReplace(TName, "^test_", "")
			if InStr(TName, LowerName) or InStr(TName, ShortName) or (Keyword != "" and InStr(LowerName, Keyword)) {
				HasTest := true
				break
			}
		}
		if not HasTest {
			for TestPath in AllHsTests {
				TName   := StrLower(_MetaPACBaseName(TestPath))
				Keyword := RegExReplace(TName, "^test_", "")
				if InStr(TName, LowerName) or InStr(TName, ShortName) or (Keyword != "" and InStr(LowerName, Keyword)) {
					HasTest := true
					break
				}
			}
		}
		if not HasTest {
			Uncovered++
			OutputDebug("WARN: no driver test for domain spec '" . LowerName . "'")
		}
	}

	_ResultDomainCoverage() {
		Assert(SpecCount > 0, "no *.spec.js found in _shared/core/domain  --  check RepoRoot")
		Assert(Uncovered = 0, "meta: " . Uncovered . " domain spec(s) lack a driver test")
	}
	Test("meta domain coverage: every domain spec has a driver test (" . SpecCount . " specs)", _ResultDomainCoverage)
}
_MetaRunDomainCoverageTests()





; ===============================================
; ===============================================
; ======= 4/ Shared-code purity invariant =======
; ===============================================
; ===============================================

_MetaCheckSharedPurity(SharedDir := unset) {
	if !IsSet(SharedDir) {
		RepoRoot := StrReplace(A_ScriptDir, "\", "/")
		; A_ScriptDir remains the main runner directory through includes.
		RepoRoot := RegExReplace(RepoRoot, "/static/ergopti_plus/windows/tests(/meta)?$", "")
		SharedDir := RepoRoot . "/static/ergopti_plus/_shared"
	}
	if !(SharedDir is String) || SharedDir == "" || !DirExist(SharedDir)
		throw ValueError("The shared purity census requires an existing directory.")
	; ``\bhs\.`` (word boundary) so the Hammerspoon global is matched but not the
	; "hs." inside ordinary words like "months." — the looser ``hs\.`` produced
	; false positives that forced this gate to stay warn-only.
	ForbiddenPatterns := ["io\.open", "\bhs\.", "SendInput", "SendEvent", "TrayTip", "FileAppend", "FileRead"]

	SharedFiles := _MetaPACListFiles(SharedDir, "js")
	Violations  := 0
	ScannedFiles := 0

	for FilePath in SharedFiles {
		; Spec files may name patterns in doc comments  --  skip them
		if FilePath ~= "i)\.spec\.js$" {
			continue
		}
		Body := FileRead(StrReplace(FilePath, "/", "\"), "UTF-8")
		ScannedFiles++
		Rel := SubStr(FilePath, InStr(FilePath, "/_shared/") + 1)
		InBlockComment := false
		LineNum := 0
		for Line in StrSplit(Body, "`n", "`r") {
			LineNum++
			Trimmed := Trim(Line)
			; Skip comments — a forbidden token is only a violation in real code,
			; not when it is named in a JSDoc/block/line comment (the cross-driver
			; webview docs legitimately mention hs.webview etc.).
			if (InBlockComment) {
				if InStr(Trimmed, "*/")
					InBlockComment := false
				continue
			}
			if (SubStr(Trimmed, 1, 2) == "/*") {
				if !InStr(Trimmed, "*/")
					InBlockComment := true
				continue
			}
			if (SubStr(Trimmed, 1, 1) == "*" or SubStr(Trimmed, 1, 2) == "//") {
				continue
			}
			; Strip a trailing line comment so a doc note after code is ignored.
			Code := RegExReplace(Line, "//.*$", "")
			for Pat in ForbiddenPatterns {
				if Code ~= Pat {
					Violations++
					OutputDebug("WARN: forbidden OS API in _shared/ JS: " . Rel . " line " . LineNum)
				}
			}
		}
	}

	; Hard-fail (A6): shared JS must be pure logic; any direct OS-level call has to
	; route through a port adapter. The audit confirmed the only matches were doc
	; comments + a "months." false positive — both handled above — so the real
	; violation count is zero and this can fail the build on any new OS call. The
	; macOS twin (hs.* baseline) already hard-fails; this brings the AHK side level.
	Assert(ScannedFiles > 0, "shared purity scanner found no implementation JS files")
	Assert(Violations == 0, "shared purity scanner found forbidden OS API calls")
	return Map("files", ScannedFiles, "violations", Violations)
}

_MetaRunSharedPurityTests() {
	; Count only successful reads at execution time, not a captured partial scan.
	Test("meta shared purity: no direct OS API in _shared/ JS", _MetaCheckSharedPurity)
}
_MetaRunSharedPurityTests()

; Encore plus (diagnostic + keystats/llm/gestures/keymap/karabiner/adapters/timer/active_app/features): these modules + healthcheck collectors must be explicitly pause-guarded and diagnostic-visible (always-readable for paused users troubleshooting). Extend coverage lists and require_state notes accordingly.
; Would have caught: diagnostic missing keystats aggregator counts or LLM profile under pause, or gesture conflicts corrupting after suspend, or timer stats wrong in healthcheck.


_MSP_RequireRefusal(Check, Root, ErrorType, Fragment := "") {
	Observed := false
	try Check.Call(Root)
	catch as Err {
		Observed := true
		AssertEqual(ErrorType, Type(Err), "the actual purity scanner must refuse at its intended boundary")
		if Fragment != ""
			AssertTrue(InStr(Err.Message, Fragment) > 0)
	}
	AssertTrue(Observed, "an unread or absent source cannot certify shared purity")
}

_MSP_ReadCase(Kind) {
	Check := _MetaCheckSharedPurity
	Root := A_Temp . "\ergopti_shared_census_" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	DirCreate(Root)
	Handle := 0
	try {
		if Kind == "empty" {
			_MSP_RequireRefusal(Check, Root, "Error", "no implementation JS files")
			return
		}
		if Kind == "missing" {
			_MSP_RequireRefusal(Check, Root . "\missing", "ValueError", "existing directory")
			return
		}
		; Source fixtures are read as text; none of this JavaScript is executed.
		Pure := 'export const value = 1;`n'
		Impure := 'FileRead("source-only-not-executed");`n'
		Path := Root . "\ordinary.js"
		if Kind == "spec-only" {
			FileAppend(Impure, Root . "\ignored.spec.js", "UTF-8")
			_MSP_RequireRefusal(Check, Root, "Error", "no implementation JS files")
			return
		}
		FileAppend(Kind == "pure" ? Pure : Impure, Path, "UTF-8")
		if Kind == "read-error" || Kind == "mixed-read-error" {
			if Kind == "mixed-read-error"
				FileAppend(Pure, Root . "\peer.js", "UTF-8")
			Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000, "UInt", 0,
				"Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
			AssertTrue(Handle != -1, "the fixture must establish actual native read refusal")
			_MSP_RequireRefusal(Check, Root, "OSError")
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle))
			Handle := 0
			_MSP_RequireRefusal(Check, Root, "Error", "forbidden OS API")
			FileDelete(Path)
			FileAppend(Pure, Path, "UTF-8")
			AssertEqual(Kind == "mixed-read-error" ? 2 : 1, Check.Call(Root)["files"],
				"the same native files must succeed after unlocking and removing the forbidden call")
			return
		}
		if Kind == "impure" {
			_MSP_RequireRefusal(Check, Root, "Error", "forbidden OS API")
			return
		}
		FileAppend(Impure, Root . "\ignored.spec.js", "UTF-8")
		Receipt := Check.Call(Root)
		AssertEqual(1, Receipt["files"], "the count must represent inspected implementation files")
		AssertEqual(0, Receipt["violations"])
	} finally {
		if Handle && Handle != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Handle)
		DirDelete(Root, true)
	}
}
for _MSP_Kind in ["empty", "missing", "read-error", "mixed-read-error", "impure", "pure", "spec-only"]
	Test("shared purity: actual " . _MSP_Kind . " source behavior (shared-purity-read-failure)", _MSP_ReadCase.Bind(_MSP_Kind))
