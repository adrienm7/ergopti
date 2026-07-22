; tests/meta/test_keylogger_session_watcher_synth.ahk

; ==============================================================================
; MODULE: Keylogger Session-Watcher Synthetic-Guard Meta Test
; DESCRIPTION:
; Static source guard for the session-watcher-fed-synthetic finding.
;
; KL_Hook_NoteActivity() drives KL_Watchers_OnKeystroke(), which runs the
; session/idle state machine (idle_end, retroactive session_end, session_start).
; Both InputHook callbacks (KL_Hook_OnChar / KL_Hook_OnKeyDown) call
; KL_Hook_NoteActivity BEFORE the synthetic check. So hotstring-expansion and
; LLM inline-autotype output — each tagged s=1 — was fed to the session/idle
; watcher as if the human pressed a key: the FIRST synthetic char of a burst
; fabricated an idle_end / session_start from pure machine output, corrupting
; the active-time and idle/session aggregates the dashboard is built on.
;
; The fix gates KL_Watchers_OnKeystroke() behind `if !Keylogger.synth_active`,
; mirroring the ergo/ROI/WPM synth guard already present in KL_Hook_OnChar.
;
; Meta-static (scans source text) because modules/keylogger/keylogger_hook.ahk
; installs a real InputHook and is not #Included by the headless runner. If the
; guard regresses (NoteActivity drives the watcher unconditionally), this fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_KSW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_KSW_WatcherGatedBySynth() {
	Src := _KSW_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Body := _DriverFuncBody("KL_Hook_NoteActivity")
	Assert(Body != "", "KL_Hook_NoteActivity() must exist in keylogger_hook.ahk")
	Assert(InStr(Body, "KL_Watchers_OnKeystroke") > 0,
		"KL_Hook_NoteActivity must still drive KL_Watchers_OnKeystroke for real keystrokes")
	; Anchor on the guard CODE literal (not comment wording): the call must be
	; the statement guarded by `if !Keylogger.synth_active`.
	GuardIdx := InStr(Body, "if !Keylogger.synth_active")
	Assert(GuardIdx > 0,
		"KL_Hook_NoteActivity must guard the KL_Watchers_OnKeystroke call with `if !Keylogger.synth_active` — synthetic auto-typed keystrokes (hotstring / LLM) must not fabricate session/idle activity (session-watcher-fed-synthetic)")
	AfterGuard := SubStr(Body, GuardIdx, 120)
	Assert(InStr(AfterGuard, "KL_Watchers_OnKeystroke") > 0,
		"the statement immediately guarded by `if !Keylogger.synth_active` must be the KL_Watchers_OnKeystroke call so synthetic keystrokes never reach the session/idle machine")
}
Test("keylogger: session/idle watcher is gated by !synth_active so auto-typed output cannot fabricate activity (session-watcher-fed-synthetic)", _KSW_WatcherGatedBySynth)
