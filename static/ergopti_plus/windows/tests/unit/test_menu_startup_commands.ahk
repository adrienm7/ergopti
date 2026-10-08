; tests/unit/test_menu_startup_commands.ahk

; ==============================================================================
; MODULE: Early Configured Menu Command Tests
; DESCRIPTION:
; Exercise command admission, identity retirement, cancellation and lifecycle
; precedence while the complete root is visible before input initialization.
; ==============================================================================

#Requires AutoHotkey v2.0

; The unit runner deliberately excludes infra/lifecycle.ahk: its suspension
; globals and timers belong to the real boot. The builders still require both
; native callback identities. Record and refuse their fallback effects so even
; a caught dispatch cannot conceal an accidental runner reload or termination.
global _MSC_UnexpectedLifecycleCalls := []

_MSC_UnexpectedLifecycleCommand(Id) {
	global _MSC_UnexpectedLifecycleCalls
	_MSC_UnexpectedLifecycleCalls.Push(Id)
	throw Error("Startup fixtures must not execute native lifecycle effects")
}

ActivateReload(*) {
	return _MSC_UnexpectedLifecycleCommand("reload")
}

ActivateExitApp(*) {
	return _MSC_UnexpectedLifecycleCommand("quit")
}

_MSC_InitializationOwnership() {
	global _MenuStartupCommands
	Saved := _MenuStartupCommands
	try {
		_MenuStartupCommands := false
		AssertFalse(MenuStartupCommands_Defer((*) => 0, []), "ordinary contexts have no startup admission")
		MenuStartupCommands_Begin(() => false)
		Owner := _MenuStartupCommands
		Threw := false
		try MenuStartupCommands_Begin(() => true)
		catch
			Threw := true
		AssertTrue(Threw, "duplicate initialization cannot replace accepted selection ownership")
		AssertTrue(_MenuStartupCommands == Owner)
		_MenuStartupCommands := Map()
		Threw := false
		try MenuStartupCommands_Defer((*) => 0, [])
		catch
			Threw := true
		AssertTrue(Threw, "invalid injected state cannot masquerade as a completed startup")
	} finally _MenuStartupCommands := Saved
}
Test("menu startup: absent, duplicate and invalid initialization retain explicit ownership", _MSC_InitializationOwnership)

_MSC_WithOwner(Body) {
	global _MenuStartupCommands, _TrayStartupCommands, _SuspendPending
	Saved := _MenuStartupCommands
	SavedTray := IsSet(_TrayStartupCommands) ? _TrayStartupCommands : false
	SavedPause := IsSet(_SuspendPending) ? _SuspendPending : false
	State := {Ready: false, Timers: [], Calls: []}
	Owner := MenuStartupCommands(() => State.Ready,
		(Fn, Delay) => State.Timers.Push(Fn))
	try {
		_MenuStartupCommands := Owner
		_TrayStartupCommands := false
		_SuspendPending := false
		Body.Call(Owner, State)
	} finally {
		_MenuStartupCommands := Saved
		_TrayStartupCommands := SavedTray
		_SuspendPending := SavedPause
	}
}

_MSC_RetainsAndReleases(Owner, State) {
	Args := ["first"]
	MenuCommandRun((Value) => State.Calls.Push(Value), Args)
	Args[1] := "changed"
	MenuCommandRun((*) => State.Calls.Push("second"), [])
	AssertEqual(0, State.Calls.Length)
	Threw := false
	try Owner.NotifyReady()
	catch
		Threw := true
	AssertTrue(Threw, "a visible menu must not counterfeit input readiness")
	State.Ready := true
	AssertTrue(Owner.NotifyReady())
	AssertFalse(Owner.NotifyReady())
	AssertEqual(1, State.Timers.Length)
	State.Timers[1].Call()
	AssertEqual(2, State.Calls.Length)
	AssertEqual("first", State.Calls[1], "accepted arguments are copied")
	AssertEqual("second", State.Calls[2], "accepted selections keep FIFO order")
	MenuCommandRun((*) => State.Calls.Push("live"), [])
	AssertEqual(3, State.Calls.Length, "normal dispatch resumes after release")
}
Test("menu startup: selections wait for input readiness and run once in order",
	(*) => _MSC_WithOwner(_MSC_RetainsAndReleases))

_MSC_IdentityAndCancel(Owner, State) {
	global _MenuDispatchTokens
	ItemId := 987654
	Token := 12345
	_MenuDispatchTokens[ItemId] := Token
	try {
		Owner.Retain((*) => State.Calls.Push(1), [], {ItemId: ItemId, Token: Token})
		_MenuDispatchTokens[ItemId] := Token + 1
		State.Ready := true
		Owner.NotifyReady()
		State.Timers[1].Call()
		AssertEqual(0, State.Calls.Length, "retired native registration cannot run")
		Owner.Released := false
		Owner.Retain((*) => State.Calls.Push(2), [])
		Owner.NotifyReady()
		Owner.Cancel()
		State.Timers[2].Call()
		AssertEqual(0, State.Calls.Length, "shutdown cancels already scheduled selections")
	} finally {
		_MenuDispatchTokens.Delete(ItemId)
	}
}
Test("menu startup: native token retirement and shutdown refuse retained callbacks",
	(*) => _MSC_WithOwner(_MSC_IdentityAndCancel))

_MSC_LifecycleWins(Owner, State) {
	global _TrayStartupCommands, _SuspendPending
	_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
		(Id) => State.Calls.Push(Id), (Fn, Delay) => State.Timers.Push(Fn))
	MenuCommandRun((*) => State.Calls.Push("feature"), [])
	Safe := MenuStartupSafeCommand(MenuStartupLifecycleDispatch.Bind("suspend", (*) => 0))
	MenuCommandRun(Safe, [])
	AssertEqual("suspend", _TrayStartupCommands.Pending)
	AssertEqual(1, Owner.Pending.Length, "safe lifecycle dispatch uses its own owner")
	State.Ready := true
	Owner.NotifyReady()
	_TrayStartupCommands.NotifyReady()
	for Fn in State.Timers
		Fn.Call()
	AssertEqual(1, State.Calls.Length)
	AssertEqual("suspend", State.Calls[1], "accepted pause supersedes early feature selections")
	Owner.Released := false
	Owner.Retain((*) => State.Calls.Push("late"), [])
	_SuspendPending := true
	Owner.NotifyReady()
	State.Timers[State.Timers.Length].Call()
	AssertEqual(1, State.Calls.Length, "physical-prefix pause deferral also refuses selection")
}
Test("menu startup: accepted lifecycle commands and pending pause precede feature actions",
	(*) => _MSC_WithOwner(_MSC_LifecycleWins))

_MSC_SchedulingFailure(Owner, State) {
	Owner.Retain((*) => State.Calls.Push(1), [])
	Owner.ScheduleFn := (*) => _MSC_Throw()
	State.Ready := true
	Threw := false
	try Owner.NotifyReady()
	catch
		Threw := true
	AssertTrue(Threw)
	AssertFalse(Owner.Released)
	AssertEqual(1, Owner.Pending.Length, "failed scheduling retains ownership")
	Owner.ScheduleFn := (Fn, Delay) => State.Timers.Push(Fn)
	Owner.NotifyReady()
	State.Timers[1].Call()
	AssertEqual(1, State.Calls.Length)
}
_MSC_Throw() {
	throw Error("injected startup scheduling refusal")
}
Test("menu startup: scheduling failure cannot lose the accepted selection",
	(*) => _MSC_WithOwner(_MSC_SchedulingFailure))

_MSC_DiagnosticsAdmission(Owner, State) {
	global _MenuDispatchCallbacks, _MenuDispatchOwnerHandles
	Window := MenuStartupUiCommand((*) => State.Calls.Push("diagnostic"), () => true)
	NativeMenu := Menu()
	try {
		_MR_RenderRows(NativeMenu, [Map("label", "diagnostic", "action", Window)], "diagnostic", 1)
		ItemId := _MenuItemIdAtPosition(NativeMenu, 0)
		AssertTrue(_MenuDispatchCallbacks.Has(ItemId) && _MenuDispatchCallbacks[ItemId] == Window,
			"the actual native renderer must retain the certified window callback")
		Flags := DllCall("GetMenuState", "Ptr", NativeMenu.Handle, "UInt", 0, "UInt", 0x400, "UInt")
		AssertTrue(Flags != 0xFFFFFFFF && !(Flags & 3), "early window row is enabled")
	} finally {
		NativeMenu.Delete()
		MenuDispatcher_PruneMenu(NativeMenu)
		if _MenuDispatchOwnerHandles.Has(NativeMenu.Handle)
			_MenuDispatchOwnerHandles.Delete(NativeMenu.Handle)
	}
	MenuCommandRun(Window, [])
	AssertEqual(1, State.Calls.Length, "certified diagnostic does not await input registration")
	MenuCommandRun((*) => State.Calls.Push("mutation"), [])
	AssertEqual(1, State.Calls.Length, "mutations still await full readiness")
	Unready := MenuStartupUiCommand((*) => State.Calls.Push("unready"), () => false)
	MenuCommandRun(Unready, [])
	AssertEqual(2, Owner.Pending.Length, "a window without its cleanup owner remains retained")
	Owner.Cancel()
}
Test("menu startup: diagnostic admission uses its own cleanup milestone (early-ui-admission)",
	(*) => _MSC_WithOwner(_MSC_DiagnosticsAdmission))

_MSC_SharedLifecycleRows(Owner, State) {
	global _TrayMenuStage, _TrayStartupCommands
	SavedStage := _TrayMenuStage
	try {
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageReload()
		_MI_StageQuit()
		AssertEqual(2, _TrayMenuStage.Length, "the real configured builders stage both declared commands")
		for Index, Id in ["reload", "quit"] {
			State.Ready := false
			_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
				(CommandId) => State.Calls.Push(CommandId), (Fn, Delay) => State.Timers.Push(Fn))
			Row := _TrayMenuStage[Index]
			AssertEqual(t("menu.global." . Id), Row["label"])
			AssertEqual("action", Row["kind"])
			AssertTrue(Row["target"] is MenuStartupSafeCommand,
				"the shared provider wrapper cannot conceal lifecycle admission")
			MenuCommandRun(Row["target"], [])
			AssertEqual(Id, _TrayStartupCommands.Pending)
			AssertEqual(0, Owner.Pending.Length, "lifecycle commands never enter ordinary early-selection debt")
			MenuCommandRun(_TrayMenuStage[Index == 1 ? 2 : 1]["target"], [])
			AssertEqual(Id, _TrayStartupCommands.Pending, "a second terminal intent cannot replace the admitted owner")
			AssertEqual(Index - 1, State.Calls.Length, "the actual startup owner retains the request until readiness")
			State.Ready := true
			_TrayStartupCommands.NotifyReady()
			State.Timers[State.Timers.Length].Call()
			AssertEqual(Index, State.Calls.Length)
			AssertEqual(Id, State.Calls[Index])
			_TrayStartupCommands.Retire()
		}
	} finally {
		_TrayMenuStage := SavedStage
	}
}
Test("menu startup: shared lifecycle rows preserve native early-command precedence (shared-lifecycle)",
	(*) => _MSC_WithOwner(_MSC_SharedLifecycleRows))

_MSC_DeclaredLifecyclePresentation() {
	global _TrayMenuStage
	SavedStage := _TrayMenuStage
	Reload := _MR_FindItemById("top_level", "reload")
	Quit := _MR_FindItemById("top_level", "quit")
	AssertTrue(Reload is Map && Quit is Map, "the real shared root carries both commands")
	SavedReloadLabel := Reload.Get("i18n", "")
	SavedQuitLabel := Quit.Get("i18n", "")
	ReloadHadType := Reload.Has("type")
	QuitHadType := Quit.Has("type")
	SavedReloadType := Reload.Get("type", "")
	SavedQuitType := Quit.Get("type", "")
	try {
		Reload["type"] := "command"
		Quit["type"] := "command"
		Reload["i18n"] := "button.cancel"
		Quit["i18n"] := "button.ok"
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageReload()
		_MI_StageQuit()
		AssertEqual(2, _TrayMenuStage.Length)
		AssertEqual(t("button.cancel"), _TrayMenuStage[1]["label"], "the actual reload stage reads its declaration")
		AssertEqual(t("button.ok"), _TrayMenuStage[2]["label"], "the actual quit stage reads its declaration")
		Reload["type"] := "---"
		Quit["type"] := "---"
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageReload()
		_MI_StageQuit()
		AssertEqual(0, _TrayMenuStage.Length, "a native builder cannot reinterpret a non-command declaration")
	} finally {
		Reload["i18n"] := SavedReloadLabel
		Quit["i18n"] := SavedQuitLabel
		if ReloadHadType
			Reload["type"] := SavedReloadType
		else
			Reload.Delete("type")
		if QuitHadType
			Quit["type"] := SavedQuitType
		else
			Quit.Delete("type")
		_TrayMenuStage := SavedStage
	}
}
Test("menu startup: actual configured lifecycle builders consume labels and command types (shared-lifecycle)",
	_MSC_DeclaredLifecyclePresentation)

_MSC_HeldLifecycleDeclaration(Owner, State) {
	global _TrayMenuStage, _TrayStartupCommands
	SavedStage := _TrayMenuStage
	Item := _MR_FindItemById("top_level", "reload")
	AssertTrue(Item is Map)
	HadDisabled := Item.Has("disabled_when")
	SavedDisabled := Item.Get("disabled_when", [])
	try {
		if HadDisabled
			Item.Delete("disabled_when")
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageReload()
		AssertEqual(1, _TrayMenuStage.Length)
		Held := _TrayMenuStage[1]["target"]
		_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
			(Id) => State.Calls.Push(Id), (Fn, Delay) => State.Timers.Push(Fn))
		Item["disabled_when"] := ["unregistered_lifecycle_owner"]
		MenuCommandRun(Held, [])
		AssertEqual("", _TrayStartupCommands.Pending, "held delivery rechecks the actual shared declaration")
		AssertEqual(0, Owner.Pending.Length)
		AssertEqual(0, State.Calls.Length)
	} finally {
		if HadDisabled
			Item["disabled_when"] := SavedDisabled
		else if Item.Has("disabled_when")
			Item.Delete("disabled_when")
		_TrayMenuStage := SavedStage
	}
}
Test("menu startup: held shared lifecycle callbacks refuse a newly unregistered readiness owner (shared-lifecycle)",
	(*) => _MSC_WithOwner(_MSC_HeldLifecycleDeclaration))

_MSC_NativeLifecycleFixtureOwnership() {
	global _TrayStartupCommands, _MSC_UnexpectedLifecycleCalls
	SavedTray := IsSet(_TrayStartupCommands) ? _TrayStartupCommands : false
	SavedCalls := _MSC_UnexpectedLifecycleCalls
	try {
		_TrayStartupCommands := false
		_MSC_UnexpectedLifecycleCalls := []
		AssertTrue(ActivateReload is Func && ActivateExitApp is Func,
			"the actual staged builders require typed native callback identities")
		for Entry in [["reload", ActivateReload], ["quit", ActivateExitApp]] {
			Refused := false
			try MenuStartupLifecycleDispatch(Entry[1], Entry[2])
			catch
				Refused := true
			AssertTrue(Refused, "fixture fallbacks refuse native lifecycle effects")
		}
		AssertEqual(2, _MSC_UnexpectedLifecycleCalls.Length)
		AssertEqual("reload", _MSC_UnexpectedLifecycleCalls[1])
		AssertEqual("quit", _MSC_UnexpectedLifecycleCalls[2],
			"both actual fallback callbacks remain observable after refusal")
	} finally {
		_TrayStartupCommands := SavedTray
		_MSC_UnexpectedLifecycleCalls := SavedCalls
	}
}
Test("menu startup: omitted boot callbacks have typed observable fixture ownership (shared-lifecycle)",
	_MSC_NativeLifecycleFixtureOwnership)


; The real lifecycle stages must ignore hidden caption variants in either source order.
_MSC_DisjointLifecycleSource(Mode) {
	global _TrayMenuStage
	Root := _MR_GetManifestRoot()
	Assert(Root is Map && Root.Has("top_level"), "the real canonical root is available")
	Top := Root["top_level"]
	SavedStage := _TrayMenuStage
	NativeRows := Map(), HiddenRows := Map()
	for Item in Top {
		if !(Item is Map) || (Item.Get("id", "") != "reload" && Item.Get("id", "") != "quit")
			continue
		Id := Item["id"]
		if _MR_IsForAhk(Item)
			NativeRows[Id] := Item
		else
			HiddenRows[Id] := Item
	}
	Assert(NativeRows.Count == 2 && HiddenRows.Count == 2,
		"the exact real lifecycle source owns two disjoint native/hidden caption pairs")
	try {
		if Mode == "hidden-first"
			Root["top_level"] := [HiddenRows["reload"], HiddenRows["quit"], NativeRows["reload"], NativeRows["quit"]]
		else
			Root["top_level"] := [NativeRows["reload"], NativeRows["quit"], HiddenRows["reload"], HiddenRows["quit"]]
		Assert(_MR_FindItemById("top_level", "reload") == NativeRows["reload"])
		Assert(_MR_FindItemById("top_level", "quit") == NativeRows["quit"])
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageReload()
		_MI_StageQuit()
		AssertEqual(2, _TrayMenuStage.Length, "both actual native lifecycle builders stage their visible source owners")
		AssertEqual(t("menu.global.reload"), _TrayMenuStage[1]["label"])
		AssertEqual(t("menu.global.quit"), _TrayMenuStage[2]["label"])
		Assert(HasMethod(_TrayMenuStage[1]["target"], "Call") && HasMethod(_TrayMenuStage[2]["target"], "Call"),
			"the actual native startup command wrappers are retained")
	} finally {
		Root["top_level"] := Top
		_TrayMenuStage := SavedStage
	}
}
for Mode in ["hidden-first", "native-first"]
	Test("menu startup: disjoint native lifecycle captions " . Mode . " (native-visible-lookup)", _MSC_DisjointLifecycleSource.Bind(Mode))
