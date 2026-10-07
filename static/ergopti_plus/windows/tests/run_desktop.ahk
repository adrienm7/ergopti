; static/ergopti_plus/windows/tests/run_desktop.ahk

; MODULE: Canonical Native Desktop Test Runner
; DESCRIPTION: Loads the shared console and AltGr cohorts without the unrelated
; full-suite auto-execute namespace. Every warning remains on stdout and refuses
; the exact canonical receipt comparison in the native desktop harness.

#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off

_RejectRunnerArguments(Message) {
	FileAppend("Invalid test runner arguments: " . Message . "`n", "**")
	ExitApp(2)
}

_DesktopRunnerArguments() {
	global _AHK_DRY_RUN, _AHK_ONLY_FILTER, _AHK_INTERACTIVE
	_AHK_DRY_RUN := false
	_AHK_ONLY_FILTER := ""
	_AHK_INTERACTIVE := false
	_riArgIndex := 1
	while (_riArgIndex <= A_Args.Length) {
		_riArg := A_Args[_riArgIndex]
		if (_riArg == "--dry-run")
			_AHK_DRY_RUN := true
		else if (_riArg == "--interactive")
			_AHK_INTERACTIVE := true
		else if (_riArg == "--only" || SubStr(_riArg, 1, 7) == "--only=") {
			if StrLen(_AHK_ONLY_FILTER) > 0
				_RejectRunnerArguments("--only may be supplied only once")
			if (_riArg == "--only") {
				if (_riArgIndex >= A_Args.Length)
					_RejectRunnerArguments("--only requires a non-empty filter")
				_riArgIndex += 1
				_AHK_ONLY_FILTER := A_Args[_riArgIndex]
				if (SubStr(_AHK_ONLY_FILTER, 1, 2) == "--")
					_RejectRunnerArguments("a filter starting with -- requires the --only= form")
			} else
				_AHK_ONLY_FILTER := SubStr(_riArg, 8)
			if (Trim(_AHK_ONLY_FILTER, " `t`r`n") == "")
				_RejectRunnerArguments("--only requires a non-empty filter")
		} else
			_RejectRunnerArguments("unknown option or unexpected positional argument")
		_riArgIndex += 1
	}

}
_DesktopRunnerArguments()

#Include test_framework.ahk
_TestResultsBeginRun()

; These are the same controlled seeds as test_stubs. No physical event is claimed.
global _SharedDir := A_ScriptDir . "\..\..\_shared"
global TapHold := Map("keys", Map())
global CategoryEnabled := Map("Layout", true, "Shortcuts", true, "Hotstrings", true, "TapHolds", true)
global LayerEnabled := false
global _ALTGR_KANA_FIXUP := false
global _OB_ALTGR_PASSTHROUGH := false

; All exercised policy and release owners are actual production includes.
#Include ../infra/tick_count.ahk
#Include ../infra/wall_clock.ahk
#Include ../infra/logger.ahk
#Include ../infra/toml/toml_helpers.ahk
#Include ../platform/remap/tap_hold_loader.ahk
#Include ../platform/remap/tap_hold_writer.ahk
#Include ../adapters/key_state.ahk
#Include ../adapters/text_sender.ahk
#Include ../adapters/shell_runner.ahk
#Include ../platform/remap/constants.ahk
#Include ../platform/remap/altgr_criteria.ahk
#Include ../infra/key_combinations.ahk

; The original full suite installs these same no-op send ports after adapters.
global _AHK_SendText := (Text) => 0
global _AHK_SendInput := (Keys) => 0

_TestSetAltGrFamily(Kana, AltGrLevel := !Kana) {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	Saved := { Kana: _ALTGR_KANA_FIXUP, Probe: _ALTGR_LAYOUT_PROBE }
	_ALTGR_KANA_FIXUP := Kana
	_ALTGR_LAYOUT_PROBE := Map("hkl", Kana ? 0xFC06040C : 0x040C040C,
		"rmenu_sc", Kana ? 0 : 0xE038, "altgr_vk", Kana ? 0xDF : 0xA5,
		"valid", true, "kana", Kana, "altgr_level", AltGrLevel, "source", "probe")
	return Saved
}

_TestRestoreAltGrFamily(Saved) {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	_ALTGR_KANA_FIXUP := Saved.Kana
	_ALTGR_LAYOUT_PROBE := Saved.Probe
}

#Include support/console_capture_cohort.ahk
#Include support/altgr_suffix_cohort.ahk

; Both cohorts retain the original full-suite 22-minute outer ceiling. Native
; child budgets and the 25-minute CI step remain owned by their original sources.
global _SUITE_TIMEOUT_MS := 1320000
_WatchdogFire() {
	try _CopyTestResultsForCi()
	try FileAppend("`n[WATCHDOG] Test suite timed out after " . _SUITE_TIMEOUT_MS . " ms - force-exiting.`n", "*")
	ExitApp(2)
}
SetTimer(_WatchdogFire, -_SUITE_TIMEOUT_MS)
RunTests()
