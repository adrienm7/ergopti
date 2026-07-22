; tests/meta/test_ergo_roi_count_synth.ahk

; ==============================================================================
; MODULE: Ergo ROI Count Synth Meta Test
; DESCRIPTION:
; Static source guard for the "ergo-roi-count-synthetic-keystrokes" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TES_Check() {
	; Move-resilient: scan the keylogger module tree via the framework helper
	; instead of a pinned keylogger_hook path. Both tokens live in that tree, so
	; the scope stays meaningful.
	Src := _DriverDirConcat("modules/keylogger")
	Assert(InStr(Src, "!Keylogger.synth_active") > 0, "keylogger_hook.ahk must check synth_active before Ergo/ROI")
	Assert(InStr(Src, "KLHook.last_tick := 0") > 0, "keylogger_hook.ahk must reset last_tick on synth strokes")
}

Test("Keylogger: synthetic strokes bypass ergo/roi counting", _TES_Check)
