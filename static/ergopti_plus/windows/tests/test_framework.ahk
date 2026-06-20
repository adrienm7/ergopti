; static/ergopti_plus/windows/tests/test_framework.ahk

; ==============================================================================
; MODULE: Test Framework
; DESCRIPTION:
; Minimal in-process test runner for ErgoptiPlus AHK code. Provides Assert /
; AssertEqual / AssertTrue / AssertFalse helpers, a ``Test`` registration
; function and a ``RunTests`` driver that prints a TAP-like report to stdout
; and exits with code 0 on success or 1 on any failure.
;
; FEATURES & RATIONALE:
; 1. Zero-dependency: pure AHK v2, no Hotkey/Hotstring registration so the
;    process exits cleanly after RunTests returns. This is what makes the
;    runner usable from CI (GitHub Actions) where AHK would otherwise stay
;    resident waiting for hotkeys.
; 2. Single global registry keeps tests cheap to author — wrap a closure
;    in ``Test("name", () => assertion)`` and the runner discovers it.
; 3. TAP-ish output (``ok N - name`` / ``not ok N - name``) is parseable by
;    GitHub Actions matchers and humans alike.
; 4. Assertions print the offending value alongside the expectation so a
;    CI failure log immediately shows what the regression looks like.
;
; KNOWN GOTCHA — SILENT MID-FILE PARSE ABORT:
; AHK v2's parser silently stops registering top-level statements partway
; through a test file when the file's encoding is inconsistent (e.g. LF
; line endings appended via ``cat >>`` into a CRLF/BOM source). The runner
; then plans ``1..N`` for only the first batch of ``Test()`` calls and
; reports green — passing tests are real, missing ones are silently
; dropped. If a new test_*.ahk file shows fewer registrations than its
; ``Test(...)`` count, check the file with ``file <path>``; it must read
; ``UTF-8 (with BOM) text, with CRLF line terminators``. Use the Edit
; tool, not ``cat >>``, to extend test files. The v2 config-refactor
; suite (test_features_manifest.ahk) carries an ASCII-only convention
; for the same reason.
; ==============================================================================





; ============================================
; =============================================
; ======= 1/ Constants and shared state =======
; =============================================
; ============================================

; Registry of all Test() calls. Each entry is { name, callback }.
global TEST_REGISTRY := []

; Counters updated by RunTests.
global TEST_PASS_COUNT := 0
global TEST_FAIL_COUNT := 0

; Results file for CI live tailing (same pattern as E2E to guarantee progress logs even
; when stdout is buffered or the process has no console handle).
global _TEST_RESULTS_FILE := A_ScriptDir . "\test_results.txt"
; Ensure a fresh file at the very start of the run (before any Test() registrations).
try FileDelete(_TEST_RESULTS_FILE)

; Default false when no runner pre-declares it (run_all sets true for --dry-run).
if !IsSet(_AHK_DRY_RUN)
	global _AHK_DRY_RUN := false





; ==================================
; =============================
; ======= 2/ Assertions =======
; =============================
; ==================================

; Throw a TestFailure when ``Condition`` is falsy. The accompanying message
; describes the property being checked, for use in the CI failure log.
Assert(Condition, Message := "assertion failed") {
	if !Condition {
		throw Error(Message)
	}
}

; Append a line to the results file (for CI tailing) and also to stdout when possible.
_TestAppendProgress(line) {
	try FileAppend(line . "`r`n", _TEST_RESULTS_FILE)
	try FileAppend(line . "`r`n", "*")
}

AssertEqual(Expected, Actual, Message := "values differ") {
	if (Expected != Actual) {
		throw Error(Message . " - expected: <" . _DescribeValue(Expected)
			. ">, actual: <" . _DescribeValue(Actual) . ">")
	}
}

AssertTrue(Value, Message := "expected true") {
	Assert(Value, Message . " - actual: <" . _DescribeValue(Value) . ">")
}

AssertFalse(Value, Message := "expected false") {
	if Value {
		throw Error(Message . " - actual: <" . _DescribeValue(Value) . ">")
	}
}

AssertContains(Haystack, Needle, Message := "substring not found") {
	if !InStr(Haystack, Needle) {
		throw Error(Message . " — needle <" . Needle . "> not in <" . Haystack . ">")
	}
}

AssertThrows(Callback, Message := "expected exception") {
	Threw := false
	try {
		Callback()
	} catch {
		Threw := true
	}
	if !Threw {
		throw Error(Message)
	}
}

; Pretty-print a value for failure diagnostics. Falls back to ``Type``
; for compound values where ``.` "" `` would just yield ``Map`` / ``Array``.
_DescribeValue(V) {
	try {
		if (V is Number or V is String) {
			return V . ""
		}
		if (V == "") {
			return ""
		}
		if (Type(V) == "Map") {
			return "Map(size=" . V.Count . ")"
		}
		if (Type(V) == "Array") {
			return "Array(length=" . V.Length . ")"
		}
		return Type(V)
	} catch {
		return "?"
	}
}

; Reads ErgoptiPlus.ahk concatenated with every .ahk file it directly #Includes,
; so source-introspection tests find a function regardless of which lib/ or ui/
; file the entrypoint decomposition (P4/P5) moved it into. Cached after first use.
_DriverSourceConcat() {
	static cache := ""
	if (cache != "")
		return cache
	SplitPath(A_ScriptDir, , &Root)
	Root := StrReplace(Root, "\", "/")
	Entry := FileRead(Root . "/ErgoptiPlus.ahk")
	Combined := Entry
	for Line in StrSplit(Entry, "`n", "`r") {
		if RegExMatch(Line, "^\s*#Include\s+(?:\*i\s+)?(.+?)\s*$", &m) {
			Inc := StrReplace(Trim(m[1]), "\", "/")
			if !RegExMatch(Inc, "i)\.ahk$")
				continue
			Path := RegExMatch(Inc, "^([A-Za-z]:/|/)") ? Inc : Root . "/" . Inc
			try Combined .= "`n" . FileRead(Path)
		}
	}
	cache := Combined
	return cache
}

; Returns the body (signature through the matching closing brace, full-line
; comments stripped) of a top-level driver function, found across the whole
; driver source. Anchors on the column-0 DEFINITION, so a call site (always
; indented) in an earlier-concatenated file is never mistaken for the body.
_DriverFuncBody(Name) {
	Src := _DriverSourceConcat()
	if !RegExMatch(Src, "m)^" . Name . "\(", &m)
		return ""
	Idx := m.Pos
	OpenPos := InStr(Src, "{", , Idx)
	if (!OpenPos)
		return ""
	depth := 0
	i := OpenPos
	Len := StrLen(Src)
	BodyEnd := Len
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0) {
				BodyEnd := i
				break
			}
		}
		i++
	}
	Body := SubStr(Src, Idx, BodyEnd - Idx + 1)
	Out := ""
	for Line in StrSplit(Body, "`n", "`r")
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	return Out
}





; ===============================
; ==============================
; ======= 3/ Test runner =======
; ==============================
; ===============================

; Register a test. ``Callback`` must be a 0-arg callable; it receives no
; setup/teardown — tests should be self-contained.
Test(Name, Callback) {
	global TEST_REGISTRY
	TEST_REGISTRY.Push({ name: Name, callback: Callback })
}

; Path of the TAP results file. Overridden by e2e; otherwise set per-run in
; RunTests() (PID suffix) so parallel AHK runners do not deadlock on one handle.
global TEST_RESULTS_FILE := A_Temp . "\ergopti_test_results.txt"
global TEST_RESULTS_CANONICAL := A_Temp . "\ergopti_test_results.txt"

; Append one TAP line. FileAppend per line avoids a suite-wide exclusive handle
; that blocked when two AutoHotkey.exe instances targeted the same path.
_TestPrint(Line) {
	global TEST_RESULTS_FILE
	try FileAppend(Line . "`r`n", "*")
	try FileAppend(Line . "`r`n", TEST_RESULTS_FILE, "UTF-8")
}

; Execute every registered test, print TAP-style results and exit with
; code 0 (all green) or 1 (any failure). Designed to be called from the
; bottom of ``run_all.ahk`` after every test file has been #Included.
; When --dry-run is passed on the command line, exits immediately after
; printing the plan line so the CI warning-check step stays fast.
RunTests() {
	global TEST_REGISTRY, TEST_PASS_COUNT, TEST_FAIL_COUNT, _AHK_DRY_RUN
	global TEST_RESULTS_FILE, TEST_RESULTS_CANONICAL
    if (A_IsCritical != 0) {
        throw Error("RunTests started with A_IsCritical=" . A_IsCritical)
    }
	if !IsSet(_AHK_DRY_RUN)
		_AHK_DRY_RUN := false
	; Per-process results path unless a runner already chose a custom file (e2e).
	if (TEST_RESULTS_FILE = TEST_RESULTS_CANONICAL) {
		TEST_RESULTS_FILE := A_Temp . "\ergopti_test_results_"
			. DllCall("GetCurrentProcessId") . ".txt"
	}
	try FileDelete(TEST_RESULTS_FILE)
	_TestPrint("1.." . TEST_REGISTRY.Length)
	if (_AHK_DRY_RUN) {
		_TestPrint("# dry-run - skipping execution.")
		_CopyTestResultsForCi()
		ExitApp(0)
	}
	Index := 0
	for TestEntry in TEST_REGISTRY {
		Index += 1
		_TestPrint("RUNNING " . Index . "/" . TEST_REGISTRY.Length . " - " . TestEntry.name)
		Status := "ok"
		Detail := ""
		try {
			TestEntry.callback.Call()
            if (A_IsCritical != 0) {
                Critical("Off") ; Reset for the next tests
                throw Error("Test LEAKED Critical: " . TestEntry.name)
            }
		} catch as e {
			Status := "not ok"
			Detail := " — " . e.Message . " [" . e.File . ":" . e.Line . "]"
		}
		if (Status == "ok") {
			TEST_PASS_COUNT += 1
		} else {
			TEST_FAIL_COUNT += 1
		}
		_TestPrint(Status . " " . Index . " - " . TestEntry.name . Detail)
	}
	_TestPrint("# " . TEST_PASS_COUNT . " passed, " . TEST_FAIL_COUNT . " failed.")
	_CopyTestResultsForCi()
	ExitApp(TEST_FAIL_COUNT > 0 ? 1 : 0)
}

; CI and local tooling read %TEMP%\ergopti_test_results.txt (fixed name).
_CopyTestResultsForCi() {
	global TEST_RESULTS_FILE, TEST_RESULTS_CANONICAL
	if (TEST_RESULTS_FILE = TEST_RESULTS_CANONICAL)
		return
	try {
		if FileExist(TEST_RESULTS_FILE)
			FileCopy(TEST_RESULTS_FILE, TEST_RESULTS_CANONICAL, true)
	}
}


; --- Global UI mocks ---
; Prevent tests from deadlocking or halting the CI runner on headless Windows.
Notify(Title, Text, Icon := "", Options := "") {
    return
}
TrayTip(Text, Title := "", Options := 0) {
    return
}
MsgBox(Text := "", Title := "", Options := "") {
    return
}