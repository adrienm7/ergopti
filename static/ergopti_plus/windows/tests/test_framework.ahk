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

AssertEqual(Expected, Actual, Message := "values differ") {
	if (Expected != Actual) {
		throw Error(Message . " — expected: <" . _DescribeValue(Expected)
			. ">, actual: <" . _DescribeValue(Actual) . ">")
	}
}

AssertTrue(Value, Message := "expected true") {
	Assert(Value, Message . " — actual: <" . _DescribeValue(Value) . ">")
}

AssertFalse(Value, Message := "expected false") {
	if Value {
		throw Error(Message . " — actual: <" . _DescribeValue(Value) . ">")
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

; Path of the TAP results file. A_Temp avoids repo-checkout paths that
; Windows Defender may scan and momentarily lock between writes.
global TEST_RESULTS_FILE := A_Temp . "\ergopti_test_results.txt"

; Persistent file handle kept open for the entire RunTests() run so that
; Defender cannot acquire an exclusive scan lock between individual writes.
; Opened lazily on first call to _TestPrint.
global _TEST_FILE_HANDLE := 0

; Append a TAP line using a single long-lived file handle opened with
; FILE_FLAG_WRITE_THROUGH so every write goes directly to disk with no OS
; buffering — the CI tail-reader sees each line the instant it is written.
; Keeping one handle open for the whole suite prevents Defender from
; acquiring an exclusive scan lock between individual FileAppend calls,
; which was the root cause of non-deterministic 240 s hangs on CI.
_TestPrint(Line) {
	global _TEST_FILE_HANDLE, TEST_RESULTS_FILE
	if !_TEST_FILE_HANDLE {
		; 0x40000000 = GENERIC_WRITE, 0x3 = FILE_SHARE_READ|WRITE,
		; 0x2 = CREATE_ALWAYS, 0x80000000 = FILE_FLAG_WRITE_THROUGH (no buffer)
		hFile := DllCall("CreateFileW",
			"Str",  TEST_RESULTS_FILE,
			"UInt", 0x40000000,
			"UInt", 0x3,
			"Ptr",  0,
			"UInt", 0x2,
			"UInt", 0x80000000,
			"Ptr",  0, "Ptr")
		if hFile != -1 {
			_TEST_FILE_HANDLE := hFile
		}
	}
	if _TEST_FILE_HANDLE {
		Bytes := Line . "`r`n"
		ByteLen := StrPut(Bytes, "UTF-8") - 1  ; -1 excludes null terminator
		Buf := Buffer(ByteLen)
		StrPut(Bytes, Buf, "UTF-8")
		DllCall("WriteFile",
			"Ptr",  _TEST_FILE_HANDLE,
			"Ptr",  Buf.Ptr,
			"UInt", ByteLen,
			"Ptr",  0,
			"Ptr",  0)
	}
}

; Execute every registered test, print TAP-style results and exit with
; code 0 (all green) or 1 (any failure). Designed to be called from the
; bottom of ``run_all.ahk`` after every test file has been #Included.
; When --dry-run is passed on the command line, exits immediately after
; printing the plan line so the CI warning-check step stays fast.
RunTests() {
	global TEST_REGISTRY, TEST_PASS_COUNT, TEST_FAIL_COUNT, _AHK_DRY_RUN, _TEST_FILE_HANDLE
	_TestPrint("1.." . TEST_REGISTRY.Length)
	if _AHK_DRY_RUN {
		_TestPrint("# dry-run — skipping execution.")
		if _TEST_FILE_HANDLE {
			DllCall("CloseHandle", "Ptr", _TEST_FILE_HANDLE)
		}
		ExitApp(0)
	}
	Index := 0
	for TestEntry in TEST_REGISTRY {
		Index += 1
		Status := "ok"
		Detail := ""
		try {
			TestEntry.callback.Call()
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
	if _TEST_FILE_HANDLE {
		DllCall("CloseHandle", "Ptr", _TEST_FILE_HANDLE)
		_TEST_FILE_HANDLE := 0
	}
	ExitApp(TEST_FAIL_COUNT > 0 ? 1 : 0)
}
