; tests/meta/test_menu_prune_keeps_detached_registrations.ahk

; ==============================================================================
; MODULE: Menu-Prune Detached-Registration Guard Meta Test
; DESCRIPTION:
; Static source guard for menu-prune-kills-detached-registrations.
;
; MenuDispatcher_PruneMenu used to derive liveness purely from tray topology: it
; collected every id reachable from A_TrayMenu and deleted the dispatch
; registration of every tracked id outside that set. But this driver builds its
; submenus DETACHED on purpose - InitSubMenus and initMenu register hundreds of
; items into fresh Menu() objects and only attach them at TrayMenuStage_Publish
; - so for the whole duration of a tray build every freshly registered id is
; unreachable from the tray and looks dead.
;
; LLM_Menu_Build calls the prune from a SetTimer thread, and the tray build is
; deliberately NOT Critical, so the timer lands inside that window on a normal
; boot. Production logs show the prune running strictly between two
; InitSubMenus/initMenu progress marks and reporting "Pruned 856 dead menu-item
; ID(s)" on a FRESH boot, i.e. 856 registrations of items that were being built
; at that very moment.
;
; The damage is total rather than partial because _TrackedDispatch gates the
; original callback on the item still owning its token, with no else branch and
; no log, and _OnMenuCommandWmCommand returns before arming the 60 ms retry when
; the callback entry is missing. So a pruned item swallows the click and emits
; nothing at any log level.
;
; THE FIX (the contract this test pins): liveness is OWNERSHIP, not tray
; reachability. Every registrar records the HMENU it registered into, and the
; prune folds those owning menus into its live set before deciding what is dead.
; A menu that has been released fails GetMenuItemCount, so genuinely freed ids
; are still pruned and the two dispatch Maps stay bounded.
;
; Source-level (like its sibling menu-dispatch meta tests): menu_dispatcher.ahk
; installs an OnMessage(0x0111) hook at include time, so the headless runner
; cannot #Include it and exercise the prune against a live tray HMENU.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================================
; =================================================================
; ======= 1/ Every registrar records its owning menu handle =======
; =================================================================
; =================================================================

; The class is derived from source rather than named, so a future sibling
; registrar joins this guarantee automatically. Forgetting one is the whole
; failure mode: an incomplete ownership set is indistinguishable from the old
; tray-only liveness test for the items it misses.
_MPDR_RegistrarsRecordTheirOwningMenu() {
	Src := _DriverSourceNoComments()
	Names := Map()
	Pos := 1
	while (Found := RegExMatch(Src, "m)^(RegisterMenuItem\w*)\([^\r\n]*\)\s*\{", &M, Pos)) {
		Names[M[1]] := true
		Pos := Found + StrLen(M[0])
	}
	Assert(Names.Count >= 2,
		"the registrar class must be derived from driver source and hold at least "
		. "RegisterMenuItem and RegisterMenuItemInsert - an empty class would make this test vacuous")
	for Name in Names {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must be defined in the driver")
		Assert(InStr(Body, "_MenuDispatchTrackOwner(") > 0,
			Name . " must record the menu it registered the item into. MenuDispatcher_PruneMenu "
			. "decides liveness from that ownership set; an item registered into a still-detached "
			. "submenu is invisible to the tray walk and its registration is deleted while it is "
			. "live, after which the click is silently swallowed (menu-prune-kills-detached-registrations)")
	}
}
Test("menu_dispatcher: every registrar records its owning menu (menu-prune-kills-detached-registrations)",
	_MPDR_RegistrarsRecordTheirOwningMenu)





; =======================================================
; =======================================================
; ======= 2/ The prune walks the owning menus too =======
; =======================================================
; =======================================================

_MPDR_PruneFoldsOwningMenusBeforeDeleting() {
	Body := _DriverFuncBody("MenuDispatcher_PruneMenu")
	Assert(Body != "", "MenuDispatcher_PruneMenu must be defined in menu_dispatcher.ahk")

	LoopPos := InStr(Body, "for Id in _MenuDispatchCallbacks")
	Assert(LoopPos > 0, "MenuDispatcher_PruneMenu must iterate _MenuDispatchCallbacks to find dead IDs")

	FoldPos := InStr(Body, "for OwnerHandle in _MenuDispatchOwnerHandles")
	Assert(FoldPos > 0 and FoldPos < LoopPos,
		"MenuDispatcher_PruneMenu must fold the menus items were registered INTO into its live set "
		. "BEFORE deciding what is dead - a walk that starts at A_TrayMenu cannot see the submenus "
		. "InitSubMenus/initMenu are still building detached, and deleting their registrations kills "
		. "the click permanently and silently (menu-prune-kills-detached-registrations)")

	; More than one walk root is the guarantee: the tray alone is not enough.
	SecondWalk := InStr(Body, "_MenuDispatchCollectLiveIds(", , 1, 2)
	Assert(SecondWalk > 0 and SecondWalk < LoopPos,
		"MenuDispatcher_PruneMenu must collect live IDs from more than one root - the tray walk plus "
		. "the owning menus - and must do it before the prune loop")
}
Test("menu_dispatcher: PruneMenu treats detached-but-owned items as live (menu-prune-kills-detached-registrations)",
	_MPDR_PruneFoldsOwningMenusBeforeDeleting)





; ==================================================
; ==================================================
; ======= 3/ The ownership set is real state =======
; ==================================================
; ==================================================

_MPDR_OwnershipSetIsDeclaredAndReset() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "global _MenuDispatchOwnerHandles := Map()") > 0,
		"the ownership set must be declared as a module-level Map in menu_dispatcher.ahk")

	Reset := _DriverFuncBody("MenuDispatcher_Reset")
	Assert(Reset != "", "MenuDispatcher_Reset must be defined in menu_dispatcher.ahk")
	Assert(InStr(Reset, "_MenuDispatchOwnerHandles := Map()") > 0,
		"MenuDispatcher_Reset must clear the ownership set with the dispatch Maps - it tracks nothing "
		. "after a reset, so retaining handles from the retired generation would make the prune walk "
		. "them for the rest of the session")
}
Test("menu_dispatcher: the ownership set is declared and cleared on reset (menu-prune-kills-detached-registrations)",
	_MPDR_OwnershipSetIsDeclaredAndReset)
