; tests/meta/test_tooltip_teardown_on_keyboard_thread.ahk

; ==============================================================================
; MODULE: LLM Bridge OnChar Deferred Teardown Meta Test
; DESCRIPTION:
; Static source guard for the tooltip-teardown-on-keyboard-thread finding.
;
; LLM_Bridge_OnChar runs inline on the PrefixWatcher InputHook thread. When a
; keystroke dismisses a shown prediction, the old code called
; LLM_Tooltip_Hide(true) synchronously -- tearing down a multi-window layered
; overlay (DeferWindowPos batch + Gui Destroy) on the very thread that must
; return promptly for the next physical key. Under DWM contention this can
; exceed Windows' LowLevelHooksTimeout and drop the in-flight or next key.
;
; The fix defers the teardown off the hook via SetTimer(..., -1), so the GDI/DWM
; work runs on a fresh thread after the hook returns. This test scans the
; LLM_Bridge_OnChar body and asserts the dismiss branch schedules a deferred
; hide rather than calling LLM_Tooltip_Hide synchronously in-line.
;
; Meta-static because modules/keymap/llm_bridge.ahk registers top-level state and
; is not part of the headless run_all include graph.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Deferred-teardown assertion ===========
; ==================================================
; ==================================================

_TtkbOnCharDefersHide() {
	; Move-resilient: extract LLM_Bridge_OnChar()'s body by name via the framework
	; helper instead of a pinned modules/keymap/llm_bridge.ahk read.
	Seg := _DriverFuncBody("LLM_Bridge_OnChar")
	Assert(Seg != "", "LLM_Bridge_OnChar(ch) declaration must exist in llm_bridge.ahk")
	; The dismiss branch must hand the teardown to a fresh timer thread, not run
	; it inline on the InputHook thread.
	Assert(InStr(Seg, "LLM_Bridge_DeferTooltipHide(true)") > 0,
		"LLM_Bridge_OnChar must defer the dismiss teardown so DWM/GDI window destruction does not run on the InputHook thread and risk a dropped keystroke")
	Helper := _DriverFuncBody("LLM_Bridge_DeferTooltipHide")
	Worker := _DriverFuncBody("_LLM_Bridge_DeferredTooltipHide")
	Assert(Helper != "" and Worker != "", "LLM bridge deferred tooltip hide helper and worker must exist")
	Assert(InStr(Helper, "Epoch := IsSet(_TooltipGeneration)") > 0
		and InStr(Helper, "SetTimer(_LLM_Bridge_DeferredTooltipHide.Bind(Epoch, accepted), -1)") > 0,
		"deferred tooltip teardown must capture the current generation before scheduling")
	Assert(InStr(Worker, "Epoch != _TooltipGeneration") > 0,
		"deferred tooltip teardown must discard a stale timer instead of hiding a newer prediction")
}
Test("LLM: LLM_Bridge_OnChar defers tooltip teardown off the hook thread (tooltip-teardown-on-keyboard-thread)", _TtkbOnCharDefersHide)
