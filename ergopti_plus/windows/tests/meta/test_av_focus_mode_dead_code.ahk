; tests/meta/test_av_focus_mode_dead_code.ahk

; ==============================================================================
; MODULE: AV Focus-Mode Dead-Code Meta Test
; DESCRIPTION:
; Static source guard for the "av-focus-mode-dead-code" finding.
;
; keylogger_av_state.ahk previously shipped a fully wired but permanently
; disabled Focus Assist detector: KL_AV_PollFocusMode() (the only caller in
; KL_AV_SlowTick was commented out), a focus_active state field, and a
; focus_mode_end shutdown emit. The machinery was inert, misleading
; maintainers, and a naive re-enable would reintroduce a documented ~30 s
; keyboard lockup caused by a recursive registry-key walk (loop reg "KR") of
; the deep CloudStore tree blocking the AHK main thread.
;
; The fix removes the dead machinery entirely (per project rule 5.6 - no
; unused fallback code) until a non-blocking focus-state source exists. This
; guard pins three regressions:
;   1. KL_AV_SlowTick must NOT call KL_AV_PollFocusMode.
;   2. The KL_AV_PollFocusMode function definition must be gone.
;   3. No `loop reg` may appear anywhere in the file (the blocking walk the
;      removal note warns about must never return on this hot timer path).
;
; This is a meta-static test (scans source text) because keylogger_av_state.ahk
; is not part of the headless run_all.ahk include graph; calling its functions
; directly would be a load-time error that hangs the CI runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_AVFM_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Dead-code removal assertions ==========
; ==================================================
; ==================================================

_AVFM_SlowTickDoesNotPollFocus() {
	Seg := _DriverFuncBody("KL_AV_SlowTick")
	Assert(Seg != "", "KL_AV_SlowTick() declaration must exist in keylogger_av_state.ahk")
	Assert(InStr(Seg, "KL_AV_PollFocusMode") = 0,
		"KL_AV_SlowTick must NOT call KL_AV_PollFocusMode - its recursive registry walk blocks the AHK main thread for ~30 s, locking the keyboard")
}
Test("Keylogger AV: KL_AV_SlowTick never calls KL_AV_PollFocusMode (av-focus-mode-dead-code)", _AVFM_SlowTickDoesNotPollFocus)

_AVFM_PollFocusModeRemoved() {
	Src := _AVFM_ReadSource("modules/keylogger/keylogger_av_state.ahk")
	Assert(InStr(Src, "KL_AV_PollFocusMode() {") = 0,
		"KL_AV_PollFocusMode() definition must be removed - inert machinery misleads maintainers and risks re-enabling the blocking registry walk (project rule 5.6)")
}
Test("Keylogger AV: KL_AV_PollFocusMode definition is removed (av-focus-mode-dead-code)", _AVFM_PollFocusModeRemoved)

_AVFM_NoBlockingRegistryWalk() {
	Src := _AVFM_ReadSource("modules/keylogger/keylogger_av_state.ahk")
	Assert(InStr(Src, "loop reg") = 0,
		"keylogger_av_state.ahk must contain no loop-reg walk - a recursive registry enumeration on the SLOW_TICK_MS timer path blocks the AHK main thread and locks the keyboard")
}
Test("Keylogger AV: no loop-reg blocking walk on any timer path (av-focus-mode-dead-code)", _AVFM_NoBlockingRegistryWalk)
