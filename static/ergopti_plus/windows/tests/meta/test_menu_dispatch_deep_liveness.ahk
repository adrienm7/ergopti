; tests/meta/test_menu_dispatch_deep_liveness.ahk

; ==============================================================================
; MODULE: Menu-Dispatch Deep Liveness Guard Meta Test
; DESCRIPTION:
; Static source guard for the F07 deep-liveness regression in
; lib/menu_dispatcher.ahk.
;
; BACKGROUND:
; MenuDispatcher_PruneMenu calls _MenuDispatchIdIsLiveAnywhere(Id) to decide
; whether a tracked item is still present somewhere in the tray hierarchy.
; Before the fix, _MenuDispatchHandleHasId(HMENU, ItemId, Recurse) descended
; only ONE level of submenus (called with Recurse=true at depth 0, then
; Recurse=false at depth 1). Items registered at depth 2-3 (e.g. Shortcuts →
; modifier_combos → items) were always reported as "not found", so PruneMenu
; incorrectly deleted them from _MenuDispatchCallbacks and click recovery was
; permanently disabled for those items.
;
; THE FIX:
; Replaced the bounded-recursion helper (Recurse bool) with fully recursive,
; depth-unlimited traversal using a Seen Map to guard against HMENU cycles.
; The new signature is _MenuDispatchHandleHasId(HMENU, ItemId, Seen), and
; _MenuDispatchIdIsLiveAnywhere passes Map() as the initial Seen argument.
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
	Src := _MDDL_ReadSource("lib/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_MenuDispatchHandleHasId")
	Assert(Body != "", "_MenuDispatchHandleHasId must be defined in menu_dispatcher.ahk")
	; The old one-level cap called _MenuDispatchHandleHasId(Sub, ItemId, false).
	; That literal ', false)' must not appear anywhere in the function body after
	; the fix — it is the signature of the bounded descent that caused F07.
	Assert(InStr(Body, ", false)") == 0,
		"_MenuDispatchHandleHasId body must NOT contain ', false)' — that was the one-level cap that prevented deep-menu items from being found")
}
Test("menu_dispatcher: _MenuDispatchHandleHasId has no one-level-cap call (F07 deep-liveness)", _MDDL_NoOneLevelCap)

_MDDL_CycleGuardPresent() {
	Src := _MDDL_ReadSource("lib/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_MenuDispatchHandleHasId")
	Assert(Body != "", "_MenuDispatchHandleHasId must be defined in menu_dispatcher.ahk")
	Assert(InStr(Body, "Seen.Has(") > 0,
		"_MenuDispatchHandleHasId must use a Seen Map (Seen.Has()) to guard against HMENU cycles — without it an infinite loop is possible")
}
Test("menu_dispatcher: _MenuDispatchHandleHasId has cycle guard via Seen.Has() (F07 deep-liveness)", _MDDL_CycleGuardPresent)

_MDDL_RecursiveCall() {
	Src := _MDDL_ReadSource("lib/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_MenuDispatchHandleHasId")
	Assert(Body != "", "_MenuDispatchHandleHasId must be defined in menu_dispatcher.ahk")
	Assert(InStr(Body, "_MenuDispatchHandleHasId(Sub") > 0,
		"_MenuDispatchHandleHasId must call itself recursively with the Sub handle to achieve depth-unlimited traversal")
}
Test("menu_dispatcher: _MenuDispatchHandleHasId calls itself recursively (F07 deep-liveness)", _MDDL_RecursiveCall)

_MDDL_CallerPassesMap() {
	Src := _MDDL_ReadSource("lib/menu_dispatcher.ahk")
	Body := _DriverFuncBody("_MenuDispatchIdIsLiveAnywhere")
	Assert(Body != "", "_MenuDispatchIdIsLiveAnywhere must be defined in menu_dispatcher.ahk")
	Assert(InStr(Body, "Map()") > 0,
		"_MenuDispatchIdIsLiveAnywhere must pass Map() as the initial Seen argument to _MenuDispatchHandleHasId — without it the cycle guard is never seeded")
}
Test("menu_dispatcher: _MenuDispatchIdIsLiveAnywhere passes Map() as Seen argument (F07 deep-liveness)", _MDDL_CallerPassesMap)
