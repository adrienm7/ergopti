; tests/meta/test_no_onexit_keylogger_flush.ahk

; ==============================================================================
; MODULE: OnExit Keylogger-Flush Guard Meta Test
; DESCRIPTION:
; Static source guard for the "no-onexit-keylogger-flush" finding.
;
; AHK v2 Reload() and ExitApp() tear the process down WITHOUT running per-module
; destructors — only callbacks registered via OnExit run. The keylogger hot path
; is intentionally RAM-buffered (KL_AppendLog queues into _pending_entries;
; KL_Hook_Tick flushes buffer_events every ~200 ms; KL_IngestOnce drains
; _pending_entries to data.sql every ~5 s). Reload is the driver's standard
; "apply settings" mechanism (also fired by CheckKeyboardLayoutChange on a layout
; switch), so without an OnExit handler the last few seconds of typing metrics are
; silently lost on every restart.
;
; The fix defines Ergopti_OnShutdown(reason, code) (which calls the idempotent
; KL_Stop that flushes + ingests + saves) and registers it via OnExit(...). This
; test encodes the ROOT CAUSE — the missing OnExit wiring — so removing either the
; handler or its registration fails CI. It is meta-static because ErgoptiPlus.ahk
; registers every hotkey at load and cannot be #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_OEKF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertions ======================
; ==================================================
; ==================================================

_OEKF_ShutdownHandlerExists() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(Seg != "", "Ergopti_OnShutdown(reason, code) must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "KL_Stop()") > 0,
		"Ergopti_OnShutdown must call KL_Stop() to flush the RAM-buffered keylogger metrics before the process tears down on Reload/exit")
}
Test("ErgoptiPlus: Ergopti_OnShutdown flushes keylogger via KL_Stop (no-onexit-keylogger-flush)", _OEKF_ShutdownHandlerExists)

_OEKF_OnExitRegistered() {
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "OnExit(Ergopti_OnShutdown, -1)") > 0,
		"ErgoptiPlus.ahk must register OnExit(Ergopti_OnShutdown) — Reload/ExitApp run ONLY OnExit callbacks, so this is the single seam that flushes buffered metrics; removing it silently loses typing data on every restart")
}
Test("ErgoptiPlus: OnExit(Ergopti_OnShutdown) is registered (no-onexit-keylogger-flush)", _OEKF_OnExitRegistered)
