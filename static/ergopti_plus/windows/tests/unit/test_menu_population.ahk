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
