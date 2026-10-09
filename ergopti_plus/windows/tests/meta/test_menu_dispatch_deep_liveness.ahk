; tests/meta/test_menu_dispatch_deep_liveness.ahk

; ==============================================================================
; MODULE: Menu-Dispatch Deep Liveness Guard Meta Test
; DESCRIPTION:
; Static source guard for the F07 deep-liveness regression in
; infra/menu_dispatcher.ahk.
;
; BACKGROUND:
; MenuDispatcher_PruneMenu must decide whether each tracked item is still present
; somewhere in the tray hierarchy. Before the F07 fix the walker descended only
; ONE level of submenus, so items registered at depth 2-3 (e.g. Shortcuts →
; modifier_combos → items) were always reported "not found" and PruneMenu wrongly
; deleted them from _MenuDispatchCallbacks, permanently disabling click recovery.
;
; THE FIX:
; Fully recursive, depth-unlimited traversal with a Seen Map guarding HMENU cycles.
; The traversal now lives in _MenuDispatchCollectLiveIds(HMENU, LiveSet, Seen),
; which PruneMenu seeds once with Map(). It replaced the old per-ID
; _MenuDispatchIdIsLiveAnywhere / _MenuDispatchHandleHasId search (a full tray
; descent PER tracked ID — see menu-prune-quadratic-tray-walk). The depth-unlimited
; + cycle-guard guarantee is unchanged; only the shape (collect-all in one pass vs
; find-one) changed.
;
; This meta-static test asserts the fix is structurally present and cannot
; silently regress.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_MDDL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ==================================================================
; ==================================================================
; ======= 2/ Depth-unlimited traversal structural assertions =======
; ==================================================================
; ==================================================================

_MDDL_NoOneLevelCap() {
	Src := _MDDL_ReadSource("infra/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_MenuDispatchCollectLiveIds")
	Assert(Body != "", "_MenuDispatchCollectLiveIds must be defined in menu_dispatcher.ahk")
	; The old one-level cap called the walker with a trailing ', false)'. That literal
	; must not reappear anywhere in the traversal — it was the bounded descent (F07).
	Assert(InStr(Body, ", false)") == 0,
		"_MenuDispatchCollectLiveIds body must NOT contain ', false)' — that was the one-level cap that prevented deep-menu items from being found")
}
Test("menu_dispatcher: _MenuDispatchCollectLiveIds has no one-level-cap call (F07 deep-liveness)", _MDDL_NoOneLevelCap)

_MDDL_CycleGuardPresent() {
	Src := _MDDL_ReadSource("infra/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_MenuDispatchCollectLiveIds")
	Assert(Body != "", "_MenuDispatchCollectLiveIds must be defined in menu_dispatcher.ahk")
	Assert(InStr(Body, "Seen.Has(") > 0,
		"_MenuDispatchCollectLiveIds must use a Seen Map (Seen.Has()) to guard against HMENU cycles — without it an infinite loop is possible")
}
Test("menu_dispatcher: _MenuDispatchCollectLiveIds has cycle guard via Seen.Has() (F07 deep-liveness)", _MDDL_CycleGuardPresent)

_MDDL_RecursiveCall() {
	Src := _MDDL_ReadSource("infra/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_MenuDispatchCollectLiveIds")
	Assert(Body != "", "_MenuDispatchCollectLiveIds must be defined in menu_dispatcher.ahk")
	Assert(InStr(Body, "_MenuDispatchCollectLiveIds(Sub") > 0,
		"_MenuDispatchCollectLiveIds must call itself recursively with the Sub handle to achieve depth-unlimited traversal")
}
Test("menu_dispatcher: _MenuDispatchCollectLiveIds calls itself recursively (F07 deep-liveness)", _MDDL_RecursiveCall)

_MDDL_CallerPassesMap() {
	Src := _MDDL_ReadSource("infra/menu_dispatcher.ahk")
	Body := _DriverFuncBody("MenuDispatcher_PruneMenu")
	Assert(Body != "", "MenuDispatcher_PruneMenu must be defined in menu_dispatcher.ahk")
	Assert(InStr(Body, "_MenuDispatchCollectLiveIds(TrayHandle, LiveIds, Map())") > 0,
		"MenuDispatcher_PruneMenu must seed _MenuDispatchCollectLiveIds with Map() as the initial Seen argument — without it the cycle guard is never seeded")
}
Test("menu_dispatcher: MenuDispatcher_PruneMenu seeds the walk with Map() as Seen (F07 deep-liveness)", _MDDL_CallerPassesMap)
