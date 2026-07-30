; tests/meta/test_menu_prune_quadratic_tray_walk.ahk

; ==============================================================================
; MODULE: Menu-Prune Quadratic Tray-Walk Guard Meta Test
; DESCRIPTION:
; Regression guard for the IA tray submenu taking seconds to appear. Per-step
; timing proved the entire cost was MenuDispatcher_PruneMenu: delete 0 ms, rest
; 0 ms, prune 594 ms warm and up to 6172 ms at boot.
;
; Root cause: the prune iterated every tracked dispatch ID and, for each, called
; _MenuDispatchIdIsLiveAnywhere(Id) — a FULL recursive descent of the whole tray
; menu tree. With hundreds of tracked items (hotstrings / shortcuts / settings all
; RegisterMenuItem in loops) and a deep tray, that is O(tracked x tray): tens of
; thousands of Win32 GetMenuItemID calls on every single LLM_Menu_Build rebuild.
;
; THE FIX (the contract this test pins): collect EVERY live tray ID in ONE
; recursive walk (_MenuDispatchCollectLiveIds) BEFORE the prune loop, then test
; each tracked ID with an O(1) Map lookup. That is O(tray + tracked). The per-ID
; walker is removed so the quadratic path cannot return.
;
; Source-level (mirrors the sibling menu-dispatch meta tests) — exercising the prune
; would need a live tray HMENU and the OnMessage hook the dispatcher installs.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Prune stays linear =======
; =====================================
; =====================================

_MPQT_PruneIsLinear() {
	Body := _DriverFuncBody("MenuDispatcher_PruneMenu")
	Assert(Body != "", "MenuDispatcher_PruneMenu must be defined in menu_dispatcher.ahk")

	; The quadratic per-ID tray walker must be gone — its very presence is the
	; regression (a full tray descent invoked once per tracked ID).
	Assert(_DriverFuncBodyOrEmpty("_MenuDispatchIdIsLiveAnywhere") == "",
		"_MenuDispatchIdIsLiveAnywhere must be removed — it walked the whole tray PER tracked "
		. "ID, making the prune O(tracked x tray) (~6 s at boot; menu-prune-quadratic-tray-walk)")

	; The live-ID set must be built ONCE, BEFORE the per-callback loop.
	CollectPos := InStr(Body, "_MenuDispatchCollectLiveIds(")
	Assert(CollectPos > 0,
		"MenuDispatcher_PruneMenu must build the live-ID set via _MenuDispatchCollectLiveIds (one walk)")
	LoopPos := InStr(Body, "for Id in _MenuDispatchCallbacks")
	Assert(LoopPos > 0, "MenuDispatcher_PruneMenu must iterate _MenuDispatchCallbacks to find dead IDs")
	Assert(CollectPos < LoopPos,
		"the live-ID collection must run BEFORE the prune loop (hoisted out), not once per iteration")

	; And NO tray walk may appear from the loop onward — that would restore the
	; per-ID O(tracked x tray) cost the menu-latency fix removed.
	Assert(InStr(Body, "_MenuDispatchCollectLiveIds(", , LoopPos) == 0,
		"no tray walk may run inside the per-callback loop — the prune must stay O(tray + tracked)")
}
Test("menu_dispatcher: PruneMenu collects live IDs once, not per tracked ID (menu-prune-quadratic-tray-walk)",
	_MPQT_PruneIsLinear)
