; tests/meta/test_run_all_include_integrity.ahk

; ==============================================================================
; MODULE: Run-All Include Integrity Meta Test
; DESCRIPTION:
; Regression guard for the headless-CI hang introduced when a test added to
; run_all.ahk referenced things outside the suite's include graph.
;
; Root cause (commit "Fix clipboard ram leak"): meta/test_clipboard_ram_leak.ahk
; did `#Include ../../infra/testing.ahk` (a file that does not exist) and called
; _KL_Clip_CharCountFromByteSize (defined only in keylogger_clipboard.ahk, which
; run_all.ahk did not include). In AHK v2 BOTH are load-time errors, and a
; load-time error pops a modal dialog the headless runner can never dismiss — the
; suite produced zero output and the CI step hung until its 15 min timeout.
;
; This test encodes the invariants that prevent it from recurring:
;   1. No test file pulled in by run_all.ahk may #Include the production entry
;      point ErgoptiPlus.ahk (it registers every hotkey at load) nor the
;      nonexistent infra/testing.ahk — test files rely on test_framework.ahk, which
;      run_all.ahk includes once up front.
;   2. run_all.ahk must include keylogger_clipboard.ahk so the clipboard test's
;      direct call to _KL_Clip_CharCountFromByteSize resolves at load time.
; ==============================================================================

; Pulls every `#Include <path>` target out of a source blob, skipping the
; optional-include (`*i`) and library-search (`<...>`) forms.
_RAI_IncludeTargets(Source) {
	Targets := []
	for Line in StrSplit(Source, "`n", "`r") {
		Trimmed := Trim(Line)
		if (SubStr(Trimmed, 1, 8) != "#Include")
			continue
		Rest := Trim(SubStr(Trimmed, 9))
		if (Rest = "" || SubStr(Rest, 1, 2) = "*i" || SubStr(Rest, 1, 1) = "<")
			continue
		Targets.Push(Rest)
	}
	return Targets
}

_RAI_TestSuiteIncludeIntegrity() {
	TestsDir := A_ScriptDir  ; = .../windows/tests when launched via run_all.ahk
	RunAllSrc := FileRead(TestsDir . "\run_all.ahk", "UTF-8")
	RunAllIncludes := _RAI_IncludeTargets(RunAllSrc)

	; (2) keylogger_clipboard.ahk must be in the graph so the clipboard test loads.
	FoundClip := false
	for Inc in RunAllIncludes {
		if InStr(Inc, "keylogger_clipboard.ahk")
			FoundClip := true
	}
	Assert(FoundClip, "run_all.ahk must #Include keylogger_clipboard.ahk so _KL_Clip_CharCountFromByteSize resolves (clipboard-ram-leak-test load-time hang)")

	; (1) No test file run_all pulls in may include the entry point or a phantom framework.
	Checked := 0
	for Inc in RunAllIncludes {
		if !InStr(Inc, "test_")
			continue
		if (SubStr(Inc, -3) != "ahk")
			continue
		; Resolve the test file relative to the tests/ dir (run_all only references
		; them as `meta/test_x.ahk` or `test_x.ahk`, never via a variable).
		TestPath := TestsDir . "\" . StrReplace(Inc, "/", "\")
		Assert(FileExist(TestPath), "run_all.ahk includes a test file that does not exist: " . Inc)

		TestSrc := FileRead(TestPath, "UTF-8")
		for SubInc in _RAI_IncludeTargets(TestSrc) {
			Assert(!InStr(SubInc, "ErgoptiPlus.ahk"), "Test file " . Inc . " must not #Include the production entry point ErgoptiPlus.ahk (registers every hotkey, hangs the headless runner)")
			Assert(!InStr(SubInc, "infra/testing.ahk") && !InStr(SubInc, "infra\testing.ahk"), "Test file " . Inc . " #Includes the nonexistent infra/testing.ahk — use test_framework.ahk via run_all instead")
		}
		Checked += 1
	}
	Assert(Checked > 0, "Expected run_all.ahk to include at least one test file")
}

Test("meta: run_all.ahk test files never pull in the entry point or a phantom framework (headless CI hang regression)", _RAI_TestSuiteIncludeIntegrity)
