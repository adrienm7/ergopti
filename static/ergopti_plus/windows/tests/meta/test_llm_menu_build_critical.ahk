; tests/meta/test_llm_menu_build_critical.ahk

; ==============================================================================
; MODULE: LLM Menu-Build Critical Guard Meta Test
; DESCRIPTION:
; Regression guard for the IA tray submenu taking several seconds to appear right
; after a reload. Per-step timing proved the build's own work was ~50 ms (the prune
; is now O(tray+tracked)) — the seconds were pure PREEMPTION: LLM_Menu_Build is not
; the only thing running at boot, and its emit loop (non-Critical) was repeatedly
; interrupted by a deferred boot task, the emoji/symbol hotstring registration, which
; monopolises the thread for up to ~7 s. The build wall-clock folded in that 7 s.
;
; THE FIX (the contract this test pins): LLM_Menu_Build runs under Critical("On") for
; its whole body, so once it starts it finishes its ~50 ms uninterrupted — a boot task
; can no longer preempt the emit loop. It restores the previous Critical state in its
; finally so Critical is never left stuck on. This is safe ONLY because the build holds
; no blocking call: the prune is O(tray+tracked) and the health + installed-tags probes
; are fire-and-forget curl children.
;
; Source-level (mirrors the sibling menu meta tests): exercising the build needs a live
; tray HMENU and the dispatcher's OnMessage hook.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Build runs Critical =======
; ======================================
; ======================================

_LMBC_BuildIsCritical() {
	Body := _DriverFuncBody("LLM_Menu_Build")
	Assert(Body != "", "menu_main.ahk must define LLM_Menu_Build()")
	; The whole build must run under Critical so a deferred boot task (the multi-second
	; emoji/symbol registration) cannot preempt the emit loop and stretch a ~50 ms build
	; into seconds (menu-build-boot-preempt).
	Assert(InStr(Body, 'Critical("On")') > 0,
		"LLM_Menu_Build must run under Critical(On) so a deferred boot task cannot preempt "
		. "its emit loop and stretch the build into seconds")
	; And it must restore the previous Critical state — leaving Critical stuck on would
	; freeze later message processing.
	Assert(InStr(Body, "Critical(_crit)") > 0,
		"LLM_Menu_Build must restore the previous Critical state via Critical(_crit) in its finally")
}
Test("menu_main: LLM_Menu_Build runs under Critical so boot tasks cannot preempt it (menu-build-boot-preempt)",
	_LMBC_BuildIsCritical)
