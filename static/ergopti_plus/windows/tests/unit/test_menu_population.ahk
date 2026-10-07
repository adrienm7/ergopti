; tests/unit/test_menu_population.ahk

; ==============================================================================
; MODULE: Native Leaf Menu Population Tests
; DESCRIPTION:
; A boot root can publish before every leaf choice is registered. Native popup
; initialization must finish those choices without a loading row, replaceable
; command identity, broken separators or retained menus from a retired root.
; ==============================================================================

#Requires AutoHotkey v2.0

_MP_TestRows() {
	return [Map("separator", true), Map("label", "Disable", "checked", true,
		"action", (*) => 0), Map("separator", true), Map("separator", true),
		Map("label", "A", "action", (*) => 0), Map("label", "B", "disabled", true,
		"action", (*) => 0), Map("separator", true)]
}

_MP_AssertComplete(Leaf, SeedId := 0, SeedToken := 0) {
	global _MenuDispatchTokens
	AssertEqual(4, _MenuItemCount(Leaf), "the final leaf has three real choices and one separator")
	AssertEqual("Disable", _MP_ReadLabel(Leaf, 0))
	AssertEqual("A", _MP_ReadLabel(Leaf, 2))
	AssertEqual("B", _MP_ReadLabel(Leaf, 3))
	AssertTrue(TrayMenuIsSeparatorAt(Leaf, 1))
	if SeedId {
		AssertEqual(SeedId, _MenuItemIdAtPosition(Leaf, 0), "the seed keeps its native command ID")
		AssertEqual(SeedToken, _MenuDispatchTokens[SeedId], "the seed keeps its dispatcher token")
	}
	State := DllCall("GetMenuState", "ptr", Leaf.Handle, "uint", 0, "uint", 0x400, "uint")
	AssertTrue((State & 8) != 0, "the seed's checkmark survives completion")
	State := DllCall("GetMenuState", "ptr", Leaf.Handle, "uint", 3, "uint", 0x400, "uint")
	AssertTrue((State & 3) != 0, "a disabled choice remains disabled")
}

_MP_ReadLabel(MenuObj, Position) {
	BufferObj := Buffer(256, 0)
	DllCall("GetMenuStringW", "ptr", MenuObj.Handle, "uint", Position,
		"ptr", BufferObj, "int", 128, "uint", 0x400)
	return StrGet(BufferObj, "UTF-16")
}

_MP_RenderAndComplete(UseMessage) {
	global _MenuPopulationBuilding, _MenuPopulationPublished, _MenuDispatchTokens
	SavedBuild := _MenuPopulationBuilding
	SavedPublished := _MenuPopulationPublished
	Owner := MenuPopulation()
	Root := Menu()
	try {
		_MenuPopulationBuilding := Owner
		_MR_RenderRows(Root, [Map("label", "Picker", "items", _MP_TestRows())], "test_leaf", 1)
		LeafHandle := DllCall("GetSubMenu", "ptr", Root.Handle, "int", 0, "ptr")
		AssertEqual(1, DllCall("GetMenuItemCount", "ptr", LeafHandle, "int"),
			"publishing the parent must not register every leaf choice first")
		Leaf := Owner.Pending[LeafHandle].MenuObj
		SeedId := _MenuItemIdAtPosition(Leaf, 0)
		SeedToken := _MenuDispatchTokens[SeedId]
		AssertEqual("Disable", _MP_ReadLabel(Leaf, 0), "the seed is a real choice, never a loading item")
		MenuPopulation_Publish(Root)
		_MenuPopulationBuilding := false
		if UseMessage {
			; A click may arrive immediately after publication, before timer arming.
			DllCall("SendMessageW", "ptr", A_ScriptHwnd, "uint", 0x117, "ptr", LeafHandle, "ptr", 0)
		} else {
			Owner.Pump()
		}
		_MP_AssertComplete(Leaf, SeedId, SeedToken)
		AssertEqual(0, Owner.Pending.Count)
		AssertFalse(Owner.Complete(LeafHandle), "later opening does not append choices twice")
	} finally {
		Owner.Stop()
		_MenuPopulationBuilding := SavedBuild
		_MenuPopulationPublished := SavedPublished
	}
}
Test("menu population: native popup initialization finishes real choices before paint (menu-leaf-perf-2026-10-02)",
	_MP_RenderAndComplete.Bind(true))
Test("menu population: background pump preserves choices, state and command tokens (menu-leaf-perf-2026-10-02)",
	_MP_RenderAndComplete.Bind(false))

_MP_Retirement(Reuse) {
	global _MenuPopulationBuilding, _MenuPopulationPublished
	SavedBuild := _MenuPopulationBuilding
	SavedPublished := _MenuPopulationPublished
	Old := MenuPopulation()
	Next := MenuPopulation()
	Leaf := Old.Create(_MP_TestRows(), "retired", 1)
	Root := Menu()
	try {
		_MenuPopulationPublished := Old
		_MenuPopulationBuilding := Next
		if Reuse
			Root.Add("retained", Leaf)
		else
			Root.Add("new command", (*) => 0)
		MenuPopulation_Publish(Root)
		AssertEqual(0, Old.Pending.Count, "the retired owner retains no native Menu objects")
		AssertEqual(Reuse ? 1 : 0, Next.Pending.Count)
		if Reuse {
			Next.Pump()
			_MP_AssertComplete(Leaf)
		} else {
			Next.Pump()
			AssertEqual(1, _MenuItemCount(Leaf), "retired pending menus are never populated")
		}
	} finally {
		Old.Stop()
		Next.Stop()
		_MenuPopulationBuilding := SavedBuild
		_MenuPopulationPublished := SavedPublished
	}
}
Test("menu population: replacing the root releases retired pending choices (menu-leaf-perf-2026-10-02)",
	_MP_Retirement.Bind(false))
Test("menu population: root projections retain surviving native leaf choices (menu-leaf-perf-2026-10-02)",
	_MP_Retirement.Bind(true))

_MP_BoundedPump() {
	Owner := MenuPopulation()
	First := Owner.Create(_MP_TestRows(), "first", 1)
	Second := Owner.Create(_MP_TestRows(), "second", 1)
	Owner.Pump()
	AssertEqual(1, Owner.Pending.Count, "one timer callback completes at most one picker")
	AssertEqual(5, _MenuItemCount(First) + _MenuItemCount(Second))
	Owner.Pump()
	AssertEqual(0, Owner.Pending.Count)
	_MP_AssertComplete(First)
	_MP_AssertComplete(Second)
}
Test("menu population: background work is bounded to one leaf per tick (menu-leaf-perf-2026-10-02)", _MP_BoundedPump)

_MP_NestedAndDepth() {
	global _MenuPopulationBuilding, MR_MAX_LIST_DEPTH
	Saved := _MenuPopulationBuilding
	Owner := MenuPopulation()
	Root := Menu()
	try {
		_MenuPopulationBuilding := Owner
		_MR_RenderRows(Root, [Map("label", "outer", "items", [
			Map("label", "inner", "items", _MP_TestRows())])], "nested", 1)
		Parent := DllCall("GetSubMenu", "ptr", Root.Handle, "int", 0, "ptr")
		Leaf := DllCall("GetSubMenu", "ptr", Parent, "int", 0, "ptr")
		AssertEqual(1, Owner.Pending.Count, "only a leaf is deferred, never a nested parent")
		AssertTrue(Owner.Pending.Has(Leaf))
		Owner.Pump()
		AssertEqual(4, DllCall("GetMenuItemCount", "ptr", Leaf, "int"))
		Truncated := Owner.Create(_MP_TestRows(), "depth", MR_MAX_LIST_DEPTH + 1)
		AssertEqual(0, _MenuItemCount(Truncated))
		AssertEqual(0, Owner.Pending.Count, "truncated rows cannot be deferred beyond the renderer depth limit")
	} finally _MenuPopulationBuilding := Saved
}
Test("menu population: nested ownership and maximum depth remain enforced (menu-leaf-perf-2026-10-02)",
	_MP_NestedAndDepth)

_MP_FailureRender(Target, Rows, ListId, Depth) {
	RegisterMenuItem(Target, "partially appended", (*) => 0)
	throw Error("forced native population failure")
}

_MP_FailureIsTerminal() {
	Owner := MenuPopulation()
	Leaf := Owner.Create(_MP_TestRows(), "failure", 1)
	AssertThrows(ObjBindMethod(Owner, "Complete", Leaf.Handle, "test", _MP_FailureRender))
	AssertEqual(1, Owner.Pending.Count, "a failed leaf remains owned, never falsely completed")
	AssertTrue(Owner.Failed)
	AssertFalse(Owner.Start(), "failed preparation cannot rearm a repeating error timer")
	Count := _MenuItemCount(Leaf)
	AssertThrows(ObjBindMethod(Owner, "Complete", Leaf.Handle))
	AssertEqual(Count, _MenuItemCount(Leaf), "failed remainders are never replayed over partially appended rows")
	AssertEqual(0, Owner.Completed)
}
Test("menu population: failed append retains ownership without false success or replay (menu-leaf-perf-2026-10-02)",
	_MP_FailureIsTerminal)

_MP_ReentryRender(Owner, Target, Rows, ListId, Depth) {
	AssertThrows(ObjBindMethod(Owner, "Complete", Target.Handle), "synchronous completion reentry must be refused")
	AssertTrue(Owner.Pending[Target.Handle].Busy, "a refused nested request cannot release the outer owner")
	_MR_RenderRows(Target, Rows, ListId, Depth, 0, true)
}

_MP_ReentryIsFenced() {
	Owner := MenuPopulation()
	Leaf := Owner.Create(_MP_TestRows(), "reentry", 1)
	AssertTrue(Owner.Complete(Leaf.Handle, "test", _MP_ReentryRender.Bind(Owner)))
	_MP_AssertComplete(Leaf)
	AssertFalse(Owner.Failed)
	AssertEqual(1, Owner.Completed, "nested requests cannot append the same remainder twice")
}
Test("menu population: synchronous reentry cannot release or duplicate an active leaf (menu-leaf-perf-2026-10-02)",
	_MP_ReentryIsFenced)

_MP_PauseAndShutdown() {
	global _MenuPopulationPublished
	SavedOwner := _MenuPopulationPublished
	SavedSuspend := A_IsSuspended
	Owner := MenuPopulation()
	Leaf := Owner.Create(_MP_TestRows(), "paused", 1)
	try {
		_MenuPopulationPublished := Owner
		Suspend(true)
		AssertFalse(Owner.Start())
		Owner.Pump()
		AssertEqual(1, _MenuItemCount(Leaf), "background mutation stops while paused")
		Suspend(false)
		MenuPopulation_Resume()
		AssertTrue(Owner.Started, "resume rearms retained background work")
		MenuPopulation_Shutdown()
		AssertFalse(Owner.Started)
		AssertEqual(0, Owner.Pending.Count, "terminal shutdown releases native menu references")
		AssertFalse(_MenuPopulationPublished)
	} finally {
		Owner.Stop()
		Suspend(SavedSuspend)
		_MenuPopulationPublished := SavedOwner
	}
}
Test("menu population: pause retains choices for resume and terminal shutdown releases them (menu-leaf-perf-2026-10-02)",
	_MP_PauseAndShutdown)

_MP_RealBackgroundTimer() {
	Owner := MenuPopulation()
	Leaves := []
	loop 3
		Leaves.Push(Owner.Create(_MP_TestRows(), "timer", 1))
	try {
		AssertTrue(Owner.Start())
		Sleep(50)
		AssertEqual(3, Owner.Pending.Count,
			"background preparation cannot interrupt a foreground thread")
		; The headless runner is itself a foreground thread. Lower its priority
		; to model an idle driver while exercising actual one-shot callbacks.
		Thread("Priority", -2)
		Deadline := A_TickCount + 1500
		while Owner.Pending.Count > 0 && A_TickCount < Deadline
			Sleep(5)
		AssertEqual(0, Owner.Pending.Count, "background callbacks finish every prepared leaf")
		AssertEqual(3, Owner.Completed)
		AssertFalse(Owner.Started, "completed preparation owns no idle timer")
		AssertFalse(HasMethod(Owner.Timer, "Call"), "completion releases the timer callback's self-reference")
		for Leaf in Leaves
			_MP_AssertComplete(Leaf)
	} finally {
		Thread("Priority", 0)
		Owner.Stop()
	}
}
Test("menu population: one-shot background callbacks drain and release timer ownership (menu-leaf-perf-2026-10-02)",
	_MP_RealBackgroundTimer)

_MP_RefusedPublication() {
	global _MenuPopulationBuilding, _MenuPopulationPublished
	SavedBuild := _MenuPopulationBuilding
	SavedPublished := _MenuPopulationPublished
	Previous := MenuPopulation()
	PreviousLeaf := Previous.Create(_MP_TestRows(), "previous", 1)
	Rejected := MenuPopulation()
	RejectedLeaf := Rejected.Create(_MP_TestRows(), "rejected", 1)
	try {
		_MenuPopulationPublished := Previous
		_MenuPopulationBuilding := Rejected
		TrayMenuStage_Begin()
		TrayMenuStage_Add("rejected", RejectedLeaf)
		AssertFalse(TrayMenuStage_Publish((*) => false))
		AssertTrue(_MenuPopulationPublished == Previous, "refusal cannot replace the published owner")
		AssertTrue(Previous.Pending.Has(PreviousLeaf.Handle))
		Rejected.Pending.Clear()
		AssertEqual(1, Previous.Pending.Count, "discarding an unpublished owner cannot retire the live one")
	} finally {
		TrayMenuStage_Abort()
		Previous.Stop()
		Rejected.Stop()
		_MenuPopulationBuilding := SavedBuild
		_MenuPopulationPublished := SavedPublished
	}
}
Test("menu population: refused root publication preserves the live pending owner (menu-leaf-perf-2026-10-02)",
	_MP_RefusedPublication)

_MP_LargeRows() {
	Rows := []
	loop 65 {
		if A_Index == 18 {
			Rows.Push(Map("separator", true))
			Rows.Push(Map("separator", true))
		}
		Rows.Push(Map("label", "Choice " . A_Index, "checked", A_Index == 2,
			"disabled", A_Index == 65, "action", (*) => 0))
	}
	Rows.Push(Map("separator", true))
	return Rows
}

_MP_BackgroundYieldThenNavigate() {
	global _MenuDispatchTokens
	Owner := MenuPopulation()
	Leaf := Owner.Create(_MP_LargeRows(), "yield", 1)
	SeedId := _MenuItemIdAtPosition(Leaf, 0)
	SeedToken := _MenuDispatchTokens[SeedId]
	Owner.Pump()
	AssertTrue(Owner.Pending.Has(Leaf.Handle), "large pickers must yield to input between background batches")
	AssertEqual(17, _MenuItemCount(Leaf), "a background batch appends at most sixteen prepared rows")
	AssertEqual(0, Owner.Completed, "partial preparation never claims a completed leaf")
	Owner.Pump()
	AssertTrue(Owner.Pending.Has(Leaf.Handle))
	AssertTrue(Owner.Complete(Leaf.Handle), "navigation must finish the remaining choices before paint")
	AssertEqual(0, Owner.Pending.Count)
	AssertEqual(66, _MenuItemCount(Leaf), "separator normalization spans batch boundaries")
	AssertEqual(SeedId, _MenuItemIdAtPosition(Leaf, 0))
	AssertEqual(SeedToken, _MenuDispatchTokens[SeedId])
	AssertEqual("Choice 18", _MP_ReadLabel(Leaf, 18))
	AssertEqual("Choice 65", _MP_ReadLabel(Leaf, 65))
	AssertTrue(TrayMenuIsSeparatorAt(Leaf, 17))
	AssertEqual(1, Owner.Completed)
	AssertFalse(Owner.Complete(Leaf.Handle), "navigation cannot replay an already appended batch")
}
Test("menu population: large background leaves yield and navigation finishes once (menu-batch-perf-2026-10-02)",
	_MP_BackgroundYieldThenNavigate)

_MP_PartialBatchTransfer() {
	global _MenuPopulationBuilding, _MenuPopulationPublished
	SavedBuild := _MenuPopulationBuilding
	SavedPublished := _MenuPopulationPublished
	Old := MenuPopulation()
	Next := MenuPopulation()
	Leaf := Old.Create(_MP_LargeRows(), "transfer", 1)
	Root := Menu()
	Root.Add("retained", Leaf)
	try {
		Old.Pump()
		AssertTrue(Old.Pending.Has(Leaf.Handle))
		_MenuPopulationPublished := Old
		_MenuPopulationBuilding := Next
		MenuPopulation_Publish(Root)
		AssertEqual(0, Old.Pending.Count)
		AssertTrue(Next.Complete(Leaf.Handle))
		AssertEqual(66, _MenuItemCount(Leaf), "publication transfers the cursor without replaying a prepared prefix")
		AssertEqual("Choice 17", _MP_ReadLabel(Leaf, 16))
		AssertEqual("Choice 18", _MP_ReadLabel(Leaf, 18))
	} finally {
		Old.Stop()
		Next.Stop()
		_MenuPopulationBuilding := SavedBuild
		_MenuPopulationPublished := SavedPublished
	}
}
Test("menu population: root projections preserve a partially prepared leaf cursor (menu-batch-perf-2026-10-02)",
	_MP_PartialBatchTransfer)

_MP_PartialBatchFailure() {
	Owner := MenuPopulation()
	Leaf := Owner.Create(_MP_LargeRows(), "batch_failure", 1)
	Owner.Pump()
	AssertTrue(Owner.Pending.Has(Leaf.Handle))
	AssertThrows(ObjBindMethod(Owner, "Complete", Leaf.Handle, "test", _MP_FailureRender, 16))
	AssertTrue(Owner.Failed)
	AssertEqual(0, Owner.Completed)
	Count := _MenuItemCount(Leaf)
	AssertThrows(ObjBindMethod(Owner, "Complete", Leaf.Handle))
	AssertEqual(Count, _MenuItemCount(Leaf), "a failed later batch never replays the prefix or the failing append")
	AssertFalse(Owner.Start())
}
Test("menu population: partial batch failures retain ownership without replay (menu-batch-perf-2026-10-02)",
	_MP_PartialBatchFailure)

_MP_BackgroundTimerPreservesPriority() {
	Source := _DriverSourceNoComments()
	Assert(Source != "" && InStr(Source, "class MenuPopulation") > 0, "the production owner must exist")
	AssertContains(Source, "global MENU_POPULATION_THREAD_PRIORITY := -1")
	AssertEqual(2, StrSplit(Source,
		"SetTimer(this.Timer, -MENU_POPULATION_TICK_MS, MENU_POPULATION_THREAD_PRIORITY)").Length - 1,
		"both initial scheduling and one-shot rearming retain foreground priority")
}
Test("menu population: background timer never interrupts foreground controller initialization (menu-background-priority)",
	_MP_BackgroundTimerPreservesPriority)





; ===========================================
; ===========================================
; ======= 8/ Terminal menu retirement =======
; ===========================================
; ===========================================

_MP_TerminalRetirementFixture(Callback) {
	TerminalRoot := Menu()
	TerminalChild := Menu()
	TerminalPending := Menu()
	TerminalForeign := Menu()
	try {
		TerminalRoot.Add("owned child", TerminalChild)
		TerminalChild.Add("child action", (*) => 0)
		TerminalPending.Add("pending action", (*) => 0)
		TerminalForeign.Add("unrelated action", (*) => 0)
		return Callback.Call(TerminalRoot, TerminalChild, TerminalPending, TerminalForeign)
	} finally {
		; Keep all four native objects alive while each callback list is released.
		for FixtureMenu in [TerminalRoot, TerminalChild, TerminalPending, TerminalForeign]
			FixtureMenu.Delete()
	}
}

_MP_TerminalGraphBody(TerminalRoot, TerminalChild, TerminalPending, TerminalForeign) {
	CapturedHandles := [TerminalRoot.Handle, TerminalChild.Handle, TerminalPending.Handle]
	TerminalOwner := MenuTerminalRetirement(true, Map(TerminalRoot.Handle, true),
		TerminalRoot, [TerminalPending, TerminalPending])
	AssertEqual(3, TerminalOwner.Menus.Length, "registered, unregistered child and detached pending owners must all be retained once")
	for CapturedHandle in CapturedHandles
		Assert(TerminalOwner.Handles.Has(CapturedHandle), "every independent native identity must be retained")
	AssertTrue(TerminalOwner.Retire(true), "terminal retirement must actually clear owned callback lists")
	for CapturedMenu in [TerminalRoot, TerminalChild, TerminalPending]
		AssertEqual(0, _MenuItemCount(CapturedMenu), "holding without deleting must not report terminal retirement")
	AssertEqual(1, _MenuItemCount(TerminalForeign), "an unrelated script-owned menu must stay intact")
	AssertEqual(CapturedHandles[1], TerminalRoot.Handle)
	AssertEqual(CapturedHandles[2], TerminalChild.Handle)
	AssertEqual(CapturedHandles[3], TerminalPending.Handle)
	AssertTrue(TerminalOwner.Retired)
	AssertFalse(TerminalOwner.Retire(true), "an already retired owner must not acquire a second deletion pass")
}

_MP_TerminalGraph() {
	_MP_TerminalRetirementFixture(_MP_TerminalGraphBody)
}
Test("menu terminal retirement: actual registered and unregistered native graph clears items without touching unrelated owners",
	_MP_TerminalGraph)

/** Binds each refused scalar and accepts only the actual constructor admission error. */
_MP_TerminalConstructorRefusal(RefusedAdmission, AdmissionRoot, AdmissionPending) {
	AdmissionError := 0
	try MenuTerminalRetirement(RefusedAdmission, Map(AdmissionRoot.Handle, true), AdmissionRoot, [AdmissionPending])
	catch as ConstructorError
		AdmissionError := ConstructorError
	AssertTrue(AdmissionError is ValueError, "the actual constructor must refuse the bound scalar with ValueError")
	AssertEqual("Menu retirement requires irreversible shutdown admission", AdmissionError.Message)
}

_MP_TerminalAdmissionBody(TerminalRoot, TerminalChild, TerminalPending, TerminalForeign) {
	for RefusedTerminal in [0, "1", 1.0] {
		_MP_TerminalConstructorRefusal.Bind(RefusedTerminal, TerminalRoot, TerminalPending).Call()
		AssertEqual(1, _MenuItemCount(TerminalRoot))
		AssertEqual(1, _MenuItemCount(TerminalChild))
	}
	TerminalOwner := MenuTerminalRetirement(true, Map(TerminalRoot.Handle, true), TerminalRoot, [TerminalPending])
	AssertThrows(ObjBindMethod(TerminalOwner, "Retire", 0),
		"an accepted collection cannot borrow nonterminal deletion authority")
	AssertEqual(1, _MenuItemCount(TerminalChild), "a shutdown veto leaves actual native callbacks intact")
	AssertFalse(TerminalOwner.Retired)
	AssertTrue(TerminalOwner.Retire(true))
}

_MP_TerminalAdmission() {
	_MP_TerminalRetirementFixture(_MP_TerminalAdmissionBody)
}
Test("menu terminal retirement: strict irreversible admission preserves native callbacks after a veto",
	_MP_TerminalAdmission)

_MP_TerminalPopulationRoots() {
	global _MenuPopulationBuilding, _MenuPopulationPublished, _MenuDispatchOwnerHandles
	PreviousBuilding := _MenuPopulationBuilding
	PreviousPublished := _MenuPopulationPublished
	PreviousRegistry := _MenuDispatchOwnerHandles
	BuildingOwner := MenuPopulation()
	PublishedOwner := MenuPopulation()
	BuildingLeaf := Menu()
	PublishedLeaf := Menu()
	PopulationCritical := Critical("On")
	try {
		BuildingLeaf.Add("building action", (*) => 0)
		PublishedLeaf.Add("published action", (*) => 0)
		BuildingOwner.Pending[BuildingLeaf.Handle] := {MenuObj: BuildingLeaf}
		PublishedOwner.Pending[PublishedLeaf.Handle] := {MenuObj: PublishedLeaf}
		_MenuPopulationBuilding := BuildingOwner
		_MenuPopulationPublished := PublishedOwner
		_MenuDispatchOwnerHandles := Map()
		HeldPopulationMenus := MenuDispatcher_PrepareTerminalRetirement(true)
		Assert(HeldPopulationMenus.Handles.Has(BuildingLeaf.Handle))
		Assert(HeldPopulationMenus.Handles.Has(PublishedLeaf.Handle))
		; Do not retire the returned owner: it also holds the actual shared tray.
		MenuPopulation_Shutdown()
		BuildingOwner.Pending.Clear()
		AssertEqual(0, PublishedOwner.Pending.Count)
		AssertFalse(_MenuPopulationPublished)
		AssertEqual(1, _MenuItemCount(BuildingLeaf), "collection itself must not remove native items")
		AssertEqual(1, _MenuItemCount(PublishedLeaf))
		Assert(HeldPopulationMenus.Handles.Has(BuildingLeaf.Handle))
		Assert(HeldPopulationMenus.Handles.Has(PublishedLeaf.Handle))
	} finally {
		try {
			BuildingOwner.Stop()
			PublishedOwner.Stop()
			BuildingLeaf.Delete()
			PublishedLeaf.Delete()
		} finally {
			_MenuPopulationBuilding := PreviousBuilding
			_MenuPopulationPublished := PreviousPublished
			_MenuDispatchOwnerHandles := PreviousRegistry
			Critical(PopulationCritical)
		}
	}
}
Test("menu terminal retirement: both actual population owners remain retained across canonical pending-root release",
	_MP_TerminalPopulationRoots)

_MP_TerminalLifecycleOrder() {
	ShutdownSource := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ShutdownSource != "", "the actual shutdown owner must exist")
	ShutdownCode := _DriverMaskNonCode(&ShutdownSource)
	TerminalPosition := InStr(ShutdownCode, "ShutdownTerminal := true", true)
	PreparePosition := InStr(ShutdownCode, "MenuDispatcher_PrepareTerminalRetirement(ShutdownTerminal)", true)
	PopulationPosition := InStr(ShutdownCode, "MenuPopulation_Shutdown()", true)
	RetirePosition := InStr(ShutdownCode, "TerminalMenus.Retire(ShutdownTerminal)", true)
	OrdinaryRefusalPosition := InStr(ShutdownCode, "_LifecycleRefuseShutdown(", true, -1)
	NativeRefusalPosition := InStr(ShutdownCode, "_LifecycleRefuseNativeRetirement(", true, -1)
	Assert(OrdinaryRefusalPosition > 0 && NativeRefusalPosition > 0,
		"both ordinary and exact native retirement refusal gates must exist")
	LastRefusalPosition := Max(OrdinaryRefusalPosition, NativeRefusalPosition)
	Assert(TerminalPosition > LastRefusalPosition && PreparePosition > TerminalPosition,
		"no menu owner may be acquired before every real shutdown veto has accepted")
	Assert(PopulationPosition > PreparePosition && RetirePosition > PopulationPosition,
		"pending roots must be retained before release and deleted only after producer cleanup")
	AssertEqual(1, _MP_TerminalCodeCount(ShutdownCode,
		"\bMenuDispatcher_PrepareTerminalRetirement\(ShutdownTerminal\)"))
	AssertEqual(1, _MP_TerminalCodeCount(ShutdownCode,
		"\bTerminalMenus\.Retire\(ShutdownTerminal\)"))
}
Test("menu terminal retirement: genuine terminal gates precede collection and final callback release",
	_MP_TerminalLifecycleOrder)

_MP_TerminalCodeCount(ShutdownCode, Pattern) {
	RegExReplace(ShutdownCode, Pattern, "", &TerminalMatches)
	return TerminalMatches
}
