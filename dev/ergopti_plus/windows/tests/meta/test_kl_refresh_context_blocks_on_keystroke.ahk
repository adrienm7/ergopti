; tests/meta/test_kl_refresh_context_blocks_on_keystroke.ahk

; ==============================================================================
; MODULE: KL-Refresh-Context-Blocks-On-Keystroke Meta Test
; DESCRIPTION:
; Static source guard for the kl-refresh-context-blocks-on-keystroke finding.
;
; KL_Hook_RefreshContext() runs WinGetTitle / WinGetProcessName, which send
; messages (WM_GETTEXT etc.) to the foreground window's thread and can BLOCK
; when that thread is busy or Not Responding (a common Electron/Office cold-
; start state). It used to be called lazily from inside the InputHook callbacks
; (KL_Hook_OnChar / KL_Hook_OnKeyDown) on the keystroke that crossed the 1 s
; context-cache boundary. On the cooperative keyboard-hook thread, that blocking
; Win32 call could stall the in-flight keystroke past LowLevelHooksTimeout and
; drop it - right at an app switch, when the user is starting to type fresh.
;
; The fix moves context refresh OFF the keystroke thread: it is armed by a
; dedicated SetTimer (KLHookConst.CONTEXT_REFRESH_MS) in KL_Hook_Start() and
; torn down in KL_Hook_Stop(). The hook callbacks then read the cached
; Keylogger.session_app / session_title with zero Win32 cost.
;
; This is a meta-static test (scans source text) because keylogger_hook.ahk is
; not part of the headless runner's #Include graph. If a regression re-inlines
; the Win32 probe into a keystroke callback, the "callbacks must not call
; RefreshContext" assertions fail.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_KRCB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Off-thread refresh assertions ==========
; ===================================================
; ===================================================

; The keystroke callbacks must NOT call KL_Hook_RefreshContext directly - the
; blocking Win32 probe must never run on the keyboard-hook thread.
_KRCB_OnCharHasNoInlineRefresh() {
	Src := _KRCB_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Body := _DriverFuncBody("KL_Hook_OnChar")
	Assert(Body != "", "KL_Hook_OnChar must exist in keylogger_hook.ahk")
	Assert(InStr(Body, "KL_Hook_RefreshContext") = 0,
		"KL_Hook_OnChar must NOT call KL_Hook_RefreshContext on the keystroke thread - WinGetTitle/WinGetProcessName can block on a busy foreground window and drop the in-flight keystroke (kl-refresh-context-blocks-on-keystroke)")
}
Test("keylogger_hook: OnChar does not inline the blocking context refresh (kl-refresh-context-blocks-on-keystroke)", _KRCB_OnCharHasNoInlineRefresh)

_KRCB_OnKeyDownHasNoInlineRefresh() {
	Src := _KRCB_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Body := _DriverFuncBody("KL_Hook_OnKeyDown")
	Assert(Body != "", "KL_Hook_OnKeyDown must exist in keylogger_hook.ahk")
	Assert(InStr(Body, "KL_Hook_RefreshContext") = 0,
		"KL_Hook_OnKeyDown must NOT call KL_Hook_RefreshContext on the keystroke thread (kl-refresh-context-blocks-on-keystroke)")
}
Test("keylogger_hook: OnKeyDown does not inline the blocking context refresh (kl-refresh-context-blocks-on-keystroke)", _KRCB_OnKeyDownHasNoInlineRefresh)

; Context refresh must instead be armed on its own SetTimer in KL_Hook_Start.
_KRCB_RefreshArmedByTimer() {
	Src := _KRCB_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Body := _DriverFuncBody("KL_Hook_Start")
	Assert(Body != "", "KL_Hook_Start must exist in keylogger_hook.ahk")
	Assert(InStr(Body, "CONTEXT_REFRESH_MS") > 0,
		"KL_Hook_Start must arm context refresh on a dedicated SetTimer using KLHookConst.CONTEXT_REFRESH_MS (kl-refresh-context-blocks-on-keystroke)")
	Assert(InStr(Body, "KL_Hook_RefreshContext.Bind()") > 0,
		"KL_Hook_Start must bind KL_Hook_RefreshContext for SetTimer so the Win32 probe runs off the keystroke thread (kl-refresh-context-blocks-on-keystroke)")
	Assert(InStr(Body, "SetTimer(KLHook.context_timer") > 0,
		"KL_Hook_Start must SetTimer the bound context_timer reference (kl-refresh-context-blocks-on-keystroke)")
}
Test("keylogger_hook: context refresh is armed by a SetTimer, not the keystroke path (kl-refresh-context-blocks-on-keystroke)", _KRCB_RefreshArmedByTimer)

; The CONTEXT_REFRESH_MS constant must be a finite, bounded period (the whole
; point is a low-frequency off-thread poll, not a per-keystroke probe).
_KRCB_RefreshPeriodConstant() {
	Src := _KRCB_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Assert(InStr(Src, "static CONTEXT_REFRESH_MS :=") > 0,
		"KLHookConst must define CONTEXT_REFRESH_MS as a named constant for the off-thread refresh cadence (kl-refresh-context-blocks-on-keystroke)")
}
Test("keylogger_hook: CONTEXT_REFRESH_MS is a named constant (kl-refresh-context-blocks-on-keystroke)", _KRCB_RefreshPeriodConstant)
