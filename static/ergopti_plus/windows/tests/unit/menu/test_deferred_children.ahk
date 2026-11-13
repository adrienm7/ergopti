; tests/unit/menu/test_deferred_children.ahk

; ==============================================================================
; MODULE: A submenu built at its first open
; DESCRIPTION:
; A tray rebuild publishes the root and leaves each heavy submenu as one
; placeholder row, built before Windows paints it. Rows are therefore read from
; the state of the moment the user looks, and a failed build must neither lose
; the row nor leave a placeholder nothing will ever fill.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with an empty registry, restoring the published owner and SubMenus.
_MDC_Run(Body) {
	global _MenuDeferredChildren, _MenuPopulationPublished, _MenuPopulationBuilding, SubMenus
	SavedPublished := _MenuPopulationPublished, SavedBuilding := _MenuPopulationBuilding
	SavedChildren := _MenuDeferredChildren
	SavedSubMenus := IsSet(SubMenus) ? SubMenus : unset
	_MenuDeferredChildren := Map(), _MenuPopulationPublished := false, _MenuPopulationBuilding := false
	SubMenus := Map()
	try Body.Call()
	finally {
		_MenuDeferredChildren := SavedChildren
		_MenuPopulationPublished := SavedPublished, _MenuPopulationBuilding := SavedBuilding
		SubMenus := IsSet(SavedSubMenus) ? SavedSubMenus : unset
	}
}

_MDC_FirstCaption(Child) {
	return TrayMenuItemCount(Child) ? TrayMenuHandleItemCaption(Child.Handle, 0) : ""
}

_MDC_BuildsOnceAtFirstOpen() {
	Builds := 0, Seen := "before"
	Fill(Target) {
		Builds += 1
		Target.Add(Seen, (*) => 0)
	}
	Child := MenuDeferred_Create(Fill, "test_list")
	AssertEqual(1, TrayMenuItemCount(Child), "a published child keeps one row, so its parent is drawn")
	AssertTrue(TrayMenuHandleItemState(Child.Handle, 0) & 0x3, "the placeholder cannot be clicked")
	AssertEqual(0, Builds, "nothing is built before the open")
	Seen := "after"
	AssertTrue(MenuDeferred_Build(Child.Handle))
	AssertEqual("after", _MDC_FirstCaption(Child), "rows come from the state at the open, and replace the placeholder")
	AssertEqual(1, TrayMenuItemCount(Child))
	AssertFalse(MenuDeferred_Build(Child.Handle), "a second open has nothing to build")
	AssertEqual(1, Builds)
}
Test("menu deferred: a child is built once, from the state at its first open", () => _MDC_Run(_MDC_BuildsOnceAtFirstOpen))

_MDC_FailureKeepsPlaceholderAndRetries() {
	Fails := true
	Fill(Target) {
		Target.Add("partial", (*) => 0)
		if Fails
			throw Error("refused")
		Target.Add("complete", (*) => 0)
	}
	Child := MenuDeferred_Create(Fill, "test_list")
	Caption := _MDC_FirstCaption(Child)
	AssertThrows(() => MenuDeferred_Build(Child.Handle), "a refused build reaches its caller")
	AssertEqual(Caption, _MDC_FirstCaption(Child), "no partial row stays: the placeholder is back")
	AssertEqual(1, TrayMenuItemCount(Child))
	Fails := false
	AssertTrue(MenuDeferred_Build(Child.Handle), "the next open tries again")
	AssertEqual(2, TrayMenuItemCount(Child))
}
Test("menu deferred: a failed build leaves no partial row and the next open retries", () => _MDC_Run(_MDC_FailureKeepsPlaceholderAndRetries))

_MDC_ReentryIsRefused() {
	Child := 0, Refused := false
	Fill(Target) {
		try MenuDeferred_Build(Child.Handle)
		catch MenuPopulationReentryError
			Refused := true
		Target.Add("row", (*) => 0)
	}
	Child := MenuDeferred_Create(Fill, "test_list")
	AssertTrue(MenuDeferred_Build(Child.Handle))
	AssertTrue(Refused, "an open during its own build is refused, never a second build")
}
Test("menu deferred: a build cannot reenter itself", () => _MDC_Run(_MDC_ReentryIsRefused))

_MDC_NestedPickersStayDeferred() {
	global _MenuPopulationPublished, _MenuPopulationBuilding
	Owner := MenuPopulation(), _MenuPopulationPublished := Owner
	During := 0
	Fill(Target) {
		During := _MenuPopulationBuilding
		Target.Add("row", (*) => 0)
	}
	Child := MenuDeferred_Create(Fill, "test_list")
	MenuDeferred_Build(Child.Handle)
	AssertEqual(Owner, During, "nested pickers belong to the published owner during the build")
	AssertEqual(false, _MenuPopulationBuilding, "the build restores what it interrupted")
}
Test("menu deferred: a build works under the published owner and restores the previous one", () => _MDC_Run(_MDC_NestedPickersStayDeferred))

_MDC_RetireKeepsWhatSubMenusHold() {
	global _MenuDeferredChildren, SubMenus
	Fill(Target) => Target.Add("row", (*) => 0)
	Live := MenuDeferred_Create(Fill, "test_list")
	Held := MenuDeferred_Create(Fill, "test_list")
	Gone := MenuDeferred_Create(Fill, "test_list")
	SubMenus["Held"] := Held
	MenuDeferred_Retire(Map(Live.Handle, true))
	AssertTrue(_MenuDeferredChildren.Has(Live.Handle), "a reachable child stays")
	AssertTrue(_MenuDeferredChildren.Has(Held.Handle),
		"SubMenus outlives a refused publication and reaches the tray through a bare initMenu")
	AssertFalse(_MenuDeferredChildren.Has(Gone.Handle), "an unreachable child is forgotten")
}
Test("menu deferred: retirement spares a child SubMenus can still publish", () => _MDC_Run(_MDC_RetireKeepsWhatSubMenusHold))

_MDC_ReplayBuildsTheWholeTree() {
	global _MenuDeferredChildren
	Fill(Target) => Target.Add("row", (*) => 0)
	First := MenuDeferred_Create(Fill, "test_list"), Second := MenuDeferred_Create(Fill, "test_list")
	Owner := MenuPopulation()
	Owner.CompleteReplayIdentity("@feature:none")
	AssertEqual(0, _MenuDeferredChildren.Count, "a replayed click may name a row of any unbuilt submenu")
	AssertEqual("row", _MDC_FirstCaption(First))
	AssertEqual("row", _MDC_FirstCaption(Second))
}
Test("menu deferred: a reload replay builds every child before it searches", () => _MDC_Run(_MDC_ReplayBuildsTheWholeTree))

_MDC_NoOwnerBuildsAtOnce() {
	global _MenuPopulationBuilding, _MenuDeferredChildren
	Fill(Target) => Target.Add("row", (*) => 0)
	AssertEqual("row", _MDC_FirstCaption(MenuDeferOrBuild(Fill, "test_list")), "with no build owner the rows exist at once")
	AssertEqual(0, _MenuDeferredChildren.Count)
	_MenuPopulationBuilding := MenuPopulation()
	Child := MenuDeferOrBuild(Fill, "test_list")
	AssertTrue(_MenuDeferredChildren.Has(Child.Handle), "inside a build the child waits for its open")
}
Test("menu deferred: only a population build defers", () => _MDC_Run(_MDC_NoOwnerBuildsAtOnce))

; A rebuild once replayed the boot snapshot only to discard it, and that read
; refuses as soon as a save has changed config.toml: the rebuild failed. Once the
; options are restored, no rebuild may read the snapshot at all.
_MDC_RebuildNeverReplaysTheBootSnapshot() {
	Body := _DriverFuncBody("_MI_StageLlm")
	Guard := InStr(Body, "if !_LLM_Menu_Loaded {")
	Read := InStr(Body, "LLM_Menu_BuildSavedOpts(_IniCache)")
	Close := InStr(Body, "}", , Read)
	Init := InStr(Body, "LLM_Menu_Init(_LlmSavedOpts")
	AssertTrue(Guard > 0 && Read > Guard && Close > Read && Init > Close,
		"only the build that restores the options reads the boot snapshot")
}
Test("menu rebuild: restored AI options never read the boot snapshot again (stale-boot-snapshot-replayed-by-rebuild)",
	_MDC_RebuildNeverReplaysTheBootSnapshot)

; The handler ran from a real WM_INITMENUPOPUP inside TrackPopupMenu, with the
; submenu already attached: deleting its placeholder there must not lose the
; handle or the rows. No timer runs in that loop, but WM_ENTERIDLE is sent from
; it: each idle posts the next key, and a bounded count ends the menu whatever
; happens, so this test cannot leave a modal loop open.
_MDC_RealPopupOpenBuildsTheRows() {
	global _MenuPopulationPublished
	Owner := MenuPopulation(), _MenuPopulationPublished := Owner
	Built := 0, RowsAfterBuild := 0
	Fill(Target) {
		Built += 1
		Target.Add("real row one", (*) => 0)
		Target.Add("real row two", (*) => 0)
		RowsAfterBuild := TrayMenuItemCount(Target)
	}
	Root := Menu()
	Child := MenuDeferred_Create(Fill, "test_list")
	Root.Add("opens", Child)
	Handle := Child.Handle
	Keys := [0x28, 0x27], Idles := 0
	OnIdle(*) {
		Idles += 1
		if Idles > 200 || !Keys.Length {
			DllCall("EndMenu")
			return
		}
		PostMessage(0x100, Keys.RemoveAt(1), 0, , "ahk_class #32768")
	}
	PreviousHidden := DetectHiddenWindows(true)
	OnMessage(0x121, OnIdle)
	try Root.Show(0, 0)
	finally {
		OnMessage(0x121, OnIdle, 0)
		DetectHiddenWindows(PreviousHidden)
	}
	AssertEqual(1, Built, "the native open built the rows")
	AssertEqual(2, RowsAfterBuild, "the placeholder went and both rows arrived")
	AssertEqual(Handle, Child.Handle, "the attached child keeps its native identity")
	AssertEqual(Handle, TrayMenuSubmenuHandle(Root.Handle, 0), "the parent row still opens the same menu")
	AssertEqual("real row one", _MDC_FirstCaption(Child))
}
Test("menu deferred: a real native open swaps the placeholder inside WM_INITMENUPOPUP", () => _MDC_Run(_MDC_RealPopupOpenBuildsTheRows))
