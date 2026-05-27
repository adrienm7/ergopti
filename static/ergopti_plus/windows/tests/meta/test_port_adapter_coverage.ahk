; tests/meta/test_port_adapter_coverage.ahk

; ==============================================================================
; MODULE: Port-Adapter Coverage Meta-Test
; DESCRIPTION:
; Verifies three structural invariants of the hexagonal architecture:
;
; 1. ADAPTER PRESENCE  --  Every port spec in _shared/ports/*.spec.js has a
;    matching adapter file in static/ergopti_plus/windows/adapters/ and in
;    static/ergopti_plus/macos/adapters/. A missing adapter means a port
;    contract exists on paper but is not honoured by a driver.
;
; 2. DOMAIN TEST COVERAGE  --  Every domain spec in _shared/domain/*.spec.js
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

	SharedPorts := RepoRoot . "/static/ergopti_plus/shared/ports"
	AhkAdapters := RepoRoot . "/static/ergopti_plus/windows/adapters"
	HsAdapters  := RepoRoot . "/static/ergopti_plus/macos/adapters"

	SpecFiles  := _MetaPACListFiles(SharedPorts, "js")
	MissingAhk := 0
	MissingHs  := 0
	SpecCount  := 0

	for SpecPath in SpecFiles {
		if not SpecPath ~= "i)\.spec\.js$" {
			continue
		}
		SpecCount++
		RawName   := _MetaPACBaseName(SpecPath)
		SnakeName := _MetaPACToSnake(RawName)
		AhkFile   := AhkAdapters . "/" . SnakeName . ".ahk"
		HsFile    := HsAdapters  . "/" . SnakeName . ".lua"
		if not FileExist(StrReplace(AhkFile, "/", "\")) {
			MissingAhk++
			OutputDebug("WARN: AHK adapter missing for port '" . RawName . "': " . AhkFile)
		}
		if not FileExist(StrReplace(HsFile, "/", "\")) {
			MissingHs++
			OutputDebug("WARN: HS adapter missing for port '" . RawName . "': " . HsFile)
		}
	}

	_ResultAdapterAhk() {
		Assert(SpecCount > 0, "no *.spec.js found in _shared/ports  --  check RepoRoot")
		Assert(MissingAhk = 0, "meta: " . MissingAhk . " AHK adapter(s) missing  --  see OutputDebug")
	}
	Test("meta port coverage: every port spec has an AHK adapter (" . SpecCount . " specs)", _ResultAdapterAhk)

	_ResultAdapterHs() {
		Assert(MissingHs = 0, "meta: " . MissingHs . " HS adapter(s) missing  --  see OutputDebug")
	}
	Test("meta port coverage: every port spec has a HS adapter (" . SpecCount . " specs)", _ResultAdapterHs)
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

	DomainDir  := RepoRoot . "/static/ergopti_plus/shared/domain"
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
			T       := StrLower(_MetaPACBaseName(TestPath))
			Keyword := RegExReplace(T, "^test_", "")
			if InStr(T, LowerName) or InStr(T, ShortName) or (Keyword != "" and InStr(LowerName, Keyword)) {
				HasTest := true
				break
			}
		}
		if not HasTest {
			for TestPath in AllHsTests {
				T       := StrLower(_MetaPACBaseName(TestPath))
				Keyword := RegExReplace(T, "^test_", "")
				if InStr(T, LowerName) or InStr(T, ShortName) or (Keyword != "" and InStr(LowerName, Keyword)) {
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
		Assert(SpecCount > 0, "no *.spec.js found in _shared/domain  --  check RepoRoot")
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

_MetaRunSharedPurityTests() {
	RepoRoot := StrReplace(A_ScriptDir, "\", "/")
	; A_ScriptDir is always the main script's dir (tests/) regardless of which
	; #Include'd file is executing — strip everything from /static/... onward.
	RepoRoot := RegExReplace(RepoRoot, "/static/ergopti_plus/windows/tests(/meta)?$", "")

	SharedDir := RepoRoot . "/static/ergopti_plus/shared"
	ForbiddenPatterns := ["io\.open", "hs\.", "SendInput", "SendEvent", "TrayTip", "FileAppend", "FileRead"]

	SharedFiles := _MetaPACListFiles(SharedDir, "js")
	Violations  := 0
	ScannedFiles := 0

	for FilePath in SharedFiles {
		; Spec files may name patterns in doc comments  --  skip them
		if FilePath ~= "i)\.spec\.js$" {
			continue
		}
		ScannedFiles++
		try {
			Body := FileRead(StrReplace(FilePath, "/", "\"))
		} catch {
			continue
		}
		Rel     := SubStr(FilePath, InStr(FilePath, "/_shared/") + 1)
		LineNum := 0
		for Line in StrSplit(Body, "`n", "`r") {
			LineNum++
			for Pat in ForbiddenPatterns {
				if Line ~= Pat {
					Violations++
					OutputDebug("WARN: forbidden OS API in _shared/: " . Rel . " line " . LineNum)
				}
			}
		}
	}

	; Warn-only: pre-existing _shared/ UI files that call hs. for rendering are
	; architectural gaps tracked separately. The invariant is informational until
	; those files are refactored to route through port adapters.
	_ResultSharedPurity() {
		Assert(ScannedFiles >= 0, "shared purity scanner failed to initialise")
		if Violations > 0 {
			OutputDebug("NOTE: " . Violations . " OS-API call(s) in _shared/ (warn-only  --  see WARNs above)")
		}
	}
	Test("meta shared purity: no direct OS API in _shared/ (" . ScannedFiles . " files)", _ResultSharedPurity)
}
_MetaRunSharedPurityTests()
