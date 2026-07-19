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

; Optional case-insensitive substring filter on test names (run_all sets it from
; ``--only <substr>``). Empty means "run every registered test". Lets a developer
; replay one failing test by its distinctive slug instead of the whole suite.
if !IsSet(_AHK_ONLY_FILTER)
	global _AHK_ONLY_FILTER := ""





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

; Pretty-print a value for failure diagnostics. Shows the first few entries
; of Map/Array so the failure log immediately shows what the collection
; contains instead of just "Map(size=5)". Strings longer than 200 chars are
; truncated. Nested Maps/Arrays are expanded one level deep.
_DescribeValue(V, Depth := 0) {
	try {
		if (Depth > 1)
			return "{…}"
		if (V == "")
			return '""'
		if (V is Number or V is String) {
			s := V . ""
			if (StrLen(s) <= 200)
				return s
			return SubStr(s, 1, 197) . "..."
		}
		if (Type(V) == "Map") {
			parts := []
			cnt := 0
			for k, val in V {
				cnt++
				if (cnt > 6) {
					parts.Push("…")
					break
				}
				parts.Push(k . "=" . _DescribeValue(val, Depth + 1))
			}
			return "Map{" . _JoinParts(parts) . "}"
		}
		if (Type(V) == "Array") {
			parts := []
			maxItems := Min(V.Length, 6)
			for i in _Enumerate(V, maxItems) {
				parts.Push(_DescribeValue(V[i], Depth + 1))
			}
			if (V.Length > 6)
				parts.Push("…")
			return "[" . _JoinParts(parts) . "]"
		}
		return Type(V)
	} catch {
		return "?"
	}
}

_JoinParts(parts) {
	s := ""
	for i, p in parts {
		if (i > 1)
			s .= " "
		s .= p
	}
	return s
}

_Enumerate(arr, n) {
	enum := []
	Loop Min(arr.Length, n)
		enum.Push(A_Index)
	return enum
}

; Reads the ENTIRE driver source — every .ahk under the windows/ root except the
; tests/, vendor/ and _generated/ trees — concatenated into one string, so
; source-introspection tests find a function regardless of which lib/ or ui/ file
; the entrypoint decomposition (P4/P5) moved it into. Function names are unique in
; the driver's global namespace, so the column-0 anchor in _DriverFuncBody still
; resolves to the single definition. Cached after first use.
_DriverSourceConcat() {
	static cache := ""
	if (cache != "")
		return cache
	SplitPath(A_ScriptDir, , &Root)   ; A_ScriptDir = windows/tests  ->  Root = windows
	Combined := ""
	Loop Files, Root . "\*.ahk", "FR" {
		p := StrReplace(A_LoopFileFullPath, "\", "/")
		if (InStr(p, "/tests/") or InStr(p, "/vendor/") or InStr(p, "/_generated/"))
			continue
		try Combined .= "`n" . FileRead(A_LoopFileFullPath)
	}
	cache := Combined
	return cache
}

; Strips every full-line ";"-comment (a line whose first non-whitespace
; character is ";") from Src, preserving all other lines verbatim. Trailing/
; inline comments (a `code ; comment` line) are left whole — full-line prose
; blocks are the common case this guards against. Single source of truth for
; every source-scan test that counts/matches tokens against driver source: a
; naive raw-substring count is fragile against explanatory comments that
; happen to contain the same token as the real code (see suspend-watchdog-
; no-prefix-keywait, where "; native Suspend() never disarms..." comments
; added by the Pattern-1 hardening campaign inflated a raw "Suspend(" count).
_StripFullLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r")
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	return Out
}

; Returns the whole driver source (see _DriverSourceConcat) with every
; full-line comment stripped. Use for source-scan invariants that count or
; match a token across the ENTIRE driver tree (not just one function body) —
; without this, an explanatory comment anywhere in lib/modules/adapters/ui
; can silently trip a naive substring count. Cached after first use.
_DriverSourceNoComments() {
	static cache := ""
	if (cache != "")
		return cache
	cache := _StripFullLineComments(_DriverSourceConcat())
	return cache
}

; Returns the body (signature through the matching closing brace, full-line
; comments stripped) of a top-level driver function, found across the whole
; driver source. Anchors on the column-0 DEFINITION, so a call site (always
; indented) in an earlier-concatenated file is never mistaken for the body.
_DriverFuncBody(Name) {
	Src := _DriverSourceConcat()
	; Match a function DEFINITION line — the name, its (...) params and the opening
	; brace — optionally indented (nested functions), never a bare call site (a
	; call has no trailing ") {"). This distinguishes def from call without relying
	; on column 0, so nested helpers like _OneShot/_Repeating resolve too.
	if !RegExMatch(Src, "m)^[ \t]*" . Name . "\([^\r\n]*\)\s*\{", &m)
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
	return _StripFullLineComments(Body)
}

; Reads every .ahk under a windows/-relative directory (recursive), concatenated
; into one string. Use for source-introspection tests that scan a specific
; module's files (e.g. "ui/tooltip") regardless of how that module is internally
; split into sub-files. RelDir uses forward slashes.
_DriverDirConcat(RelDir) {
	SplitPath(A_ScriptDir, , &Root)   ; A_ScriptDir = windows/tests  ->  Root = windows
	Dir := Root . "\" . StrReplace(RelDir, "/", "\")
	Combined := ""
	Loop Files, Dir . "\*.ahk", "FR"
		try Combined .= "`n" . FileRead(A_LoopFileFullPath)
	return Combined
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

; True when ``Name`` should run under the active ``--only`` filter. An empty
; filter matches every test; otherwise the match is a case-insensitive substring,
; so a distinctive slug (e.g. a trailing "(my-slug)") selects a single test.
_FilterMatches(Name, Filter) {
	return (Filter == "" || InStr(Name, Filter) > 0)
}

; Returns "file:line" for the first stack frame OUTSIDE test_framework.ahk — the
; failing test's own call site, rather than the assert helper that threw. AHK
; stack lines look like ``C:\...\test_foo.ahk (123) : [Func] <source>``. Returns
; "" when no such frame is found (the stack format varies by AHK build) so the
; caller can fall back to the raw throw location.
_TestCallSite(StackText) {
	if (StackText == "")
		return ""
	for Line in StrSplit(StackText, "`n", "`r") {
		if !RegExMatch(Line, "^\s*(.+?)\s+\((\d+)\)", &m)
			continue
		if (InStr(m[1], "test_framework.ahk") || m[1] == "")
			continue
		SplitPath(m[1], &FileName)
		return FileName . ":" . m[2]
	}
	return ""
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
	global TEST_REGISTRY, TEST_PASS_COUNT, TEST_FAIL_COUNT, _AHK_DRY_RUN, _AHK_ONLY_FILTER
	global TEST_RESULTS_FILE, TEST_RESULTS_CANONICAL
    if (A_IsCritical != 0) {
        throw Error("RunTests started with A_IsCritical=" . A_IsCritical)
    }
	if !IsSet(_AHK_DRY_RUN)
		_AHK_DRY_RUN := false
	if !IsSet(_AHK_ONLY_FILTER)
		_AHK_ONLY_FILTER := ""
	; Per-process results path unless a runner already chose a custom file (e2e).
	if (TEST_RESULTS_FILE = TEST_RESULTS_CANONICAL) {
		TEST_RESULTS_FILE := A_Temp . "\ergopti_test_results_"
			. DllCall("GetCurrentProcessId") . ".txt"
	}
	try FileDelete(TEST_RESULTS_FILE)
	; Apply the optional --only <substr> filter. The plan line (1..N) and the run
	; loop both operate on the selected subset so a filtered run is a valid, fast
	; replay of a single failing test.
	ActiveTests := []
	for TestEntry in TEST_REGISTRY {
		if _FilterMatches(TestEntry.name, _AHK_ONLY_FILTER)
			ActiveTests.Push(TestEntry)
	}
	_TestPrint("1.." . ActiveTests.Length)
	if (_AHK_ONLY_FILTER != "")
		_TestPrint("# --only " . _AHK_ONLY_FILTER . " - " . ActiveTests.Length
			. " of " . TEST_REGISTRY.Length . " test(s) selected.")
	if (_AHK_DRY_RUN) {
		_TestPrint("# dry-run - skipping execution.")
		_CopyTestResultsForCi()
		ExitApp(0)
	}
	if (ActiveTests.Length == 0) {
		_TestPrint("# no test matched --only " . _AHK_ONLY_FILTER . ".")
		_CopyTestResultsForCi()
		ExitApp(1)
	}
	Index := 0
	for TestEntry in ActiveTests {
		Index += 1
		_TestPrint("RUNNING " . Index . "/" . ActiveTests.Length . " - " . TestEntry.name)
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
			; Point [file:line] at the test's own call site, not the assert helper
			; in test_framework.ahk where the throw physically happened.
			Site := ""
			try Site := _TestCallSite(e.Stack)
			if (Site == "") {
				SplitPath(e.File, &EFileName)
				Site := EFileName . ":" . e.Line
			}
			Detail := " — " . e.Message . " [" . Site . "]"
		}
		if (Status == "ok") {
			TEST_PASS_COUNT += 1
		} else {
			TEST_FAIL_COUNT += 1
		}
		_TestPrint(Status . " " . Index . " - " . TestEntry.name . Detail)
		; Print the exact one-test replay command so a red test is reproducible
		; without re-running the whole suite (the JS runner sets this bar).
		if (Status == "not ok")
			_TestPrint("#   replay: AutoHotkey64.exe tests\run_all.ahk --only "
				. Chr(34) . TestEntry.name . Chr(34))
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


; ── Boot progress logging ──
; Called from run_all.ahk between large #Include batches so CI can tail
; the results file and see exactly which phase the runner is in. Writes
; to both the CI-results file (for headless monitoring) and stdout.
_LogBootProgress(msg) {
	try FileAppend("# [boot] " . msg . "`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
	try FileAppend("# [boot] " . msg . "`r`n", "*")
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
