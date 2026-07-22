; tests/meta/test_updater_swap_exit_guard.ahk

; ==============================================================================
; MODULE: Updater Swap Exit Guard Meta Test
; DESCRIPTION:
; Regression guard for AHK-19: _Updater_PollDownloadAsync used a bare
; "try Run('cmd /c ...')" with no success gate, followed unconditionally by
; ExitApp(0). When Run() throws (cmd.exe blocked by AppLocker/SRP/AV), the try
; swallowed the failure and ExitApp ran anyway — the driver exited, the swap
; script never launched, and the old exe was left in place with nothing running.
; The user lost keyboard remapping silently until manual relaunch.
;
; Every other failure branch in _Updater_PollDownloadAsync (download abort,
; size check fail, write fail) logs, shows a MsgBox, resets
; _UpdaterDownloadInProgress, re-arms initMenu, and returns — the swap-launch
; branch was the lone exception (a classic missed-sibling violation of §5.3).
;
; The fix adds a _SwapLaunched flag: Run() sets it true on success; the
; catch branch logs an ERROR and leaves it false; ExitApp is only reached when
; _SwapLaunched is true. On failure the driver resets state, shows the install-
; error MsgBox, re-arms _Updater_RebuildMenu, and returns — staying alive.
;
; This test asserts (source introspection):
;   (a) A launch-success guard variable (_SwapLaunched or equivalent) is
;       present in _Updater_PollDownloadAsync — the fix is not just a bare try.
;   (b) ExitApp(0) is NOT preceded by an unconditional "try Run(" with no
;       intervening if/guard — i.e., there must be an "if" between Run( and
;       ExitApp(0) in the swap-launch tail.
;   (c) A catch block with LoggerError exists for the swap-launch Run call,
;       so the failure is surfaced rather than silently swallowed (§5.3).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TUSEG_CheckSwapExitGuard() {
	Body := _DriverFuncBody("_Updater_PollDownloadAsync")
	Assert(Body != "", "_Updater_PollDownloadAsync must exist in lib/updater/self_update.ahk")

	; (a) A launch-success flag must exist so ExitApp is conditional
	Assert(InStr(Body, "_SwapLaunched"),
		"AHK-19: _Updater_PollDownloadAsync must use a swap-launch guard flag (_SwapLaunched) to gate ExitApp(0) on actual process launch — bare 'try Run(...)' followed by unconditional ExitApp exits the driver even when cmd.exe launch fails")

	; (b) An "if" check must separate Run( from ExitApp(0).
	; Compute position of the last Run( before ExitApp(0) in the body and the
	; first "if !_SwapLaunched" guard — the guard must appear between them.
	RunPos    := InStr(Body, "Run(A_ComSpec")
	ExitPos   := InStr(Body, "ExitApp(0)")
	GuardPos  := InStr(Body, "if !_SwapLaunched")
	Assert(RunPos > 0 && ExitPos > 0 && GuardPos > 0,
		"AHK-19: _Updater_PollDownloadAsync must contain Run(cmd /c...), if !_SwapLaunched guard, and ExitApp(0) — one of these is missing")
	Assert(RunPos < GuardPos && GuardPos < ExitPos,
		"AHK-19: the 'if !_SwapLaunched' guard must appear AFTER Run(cmd /c...) and BEFORE ExitApp(0) in _Updater_PollDownloadAsync — ExitApp must only be reached when the swap process actually launched")

	; (c) A LoggerError call must follow the Run failure path so it is surfaced
	Assert(InStr(Body, "LoggerError") && InStr(Body, "Swap script launch failed"),
		"AHK-19: _Updater_PollDownloadAsync must LoggerError when the swap Run() fails — §5.3 forbids silent error swallowing in a try/catch block")
}


Test("meta ahk-19: _Updater_PollDownloadAsync gates ExitApp on swap-launch success to keep driver alive when cmd.exe is blocked",
	_TUSEG_CheckSwapExitGuard)
