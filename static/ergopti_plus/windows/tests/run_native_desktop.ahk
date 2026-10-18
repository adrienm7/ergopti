; static/ergopti_plus/windows/tests/run_native_desktop.ahk

; ==============================================================================
; MODULE: Native Desktop Cohort Entry Point
; DESCRIPTION:
; Loads the unchanged console and AltGr tests with their production dependencies.
; Unrelated unit registration loops cannot become globals in this compilation unit.
; The full unit runner remains a separate mandatory CI step.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Warn VarUnset, Off
SetWorkingDir(A_ScriptDir)

; The native owner supplies one exact cohort. Dry-run is only a parser control.
_NativeDesktopArguments(Arguments) {
	DryRun := Arguments.Length == 4 && Arguments[4] == "--dry-run"
	if (Arguments.Length != 3 && !DryRun) || Arguments[1] != "--interactive"
		|| Arguments[2] != "--only" || (Arguments[3] != "native-console-capture"
		&& Arguments[3] != "todo91-altgr-suffix") {
		FileAppend("Invalid native desktop runner arguments.`n", "**")
		ExitApp(2)
	}
	return {Filter: Arguments[3], DryRun: DryRun}
}
global _NativeDesktopRunArguments := _NativeDesktopArguments(A_Args)
global _AHK_DRY_RUN := _NativeDesktopRunArguments.DryRun
global _AHK_ONLY_FILTER := _NativeDesktopRunArguments.Filter
global _AHK_INTERACTIVE := true
global _AHK_QUALIFICATION_PROFILE := ""

; A refused include must terminate instead of opening a headless error dialog.
_NativeDesktopStartupError(Err, Mode) {
	FileAppend("Native desktop startup refused: " . Err.Message . "`n", "**")
	ExitApp(1)
	return 1
}
OnError(_NativeDesktopStartupError)

#Include test_framework.ahk
_TestResultsBeginRun()
#Include ../infra/app_state.ahk
#Include test_stubs.ahk
#Include ../infra/json.ahk
#Include ../infra/number.ahk
#Include ../infra/wall_clock.ahk
#Include ../_generated/logger_sub_files.ahk
#Include ../_generated/app_dirs.ahk
global _LogsDir := A_Temp . "\ergopti_test_logs\ergopti_plus\"
global _DefaultLogsDir := _LogsDir
#Include ../infra/logger.ahk
#Include ../adapters/file_system.ahk
#Include ../adapters/process_lifecycle.ahk
#Include ../adapters/shell_runner.ahk
#Include ../adapters/key_state.ahk
#Include ../adapters/text_sender.ahk
#Include ../ui/console_window.ahk
#Include ../infra/key_combinations.ahk
#Include ../infra/toml/toml_helpers.ahk
#Include ../platform/remap/tap_hold_loader.ahk
#Include ../platform/remap/tap_hold_writer.ahk
#Include ../platform/remap/constants.ahk
#Include ../platform/remap/altgr_criteria.ahk

; Both complete test modules retain their original registrations and callbacks.
#Include unit/adapters/test_console_window.ahk
#Include unit/platform/remap/key_combinations/test_key_combinations.ahk

RunTests()
