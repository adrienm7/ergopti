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


_MSC_ReloadDuringStalledStartup(Owner, State) {
	global _TrayStartupCommands
	_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
		(Id) => State.Calls.Push(Id), (Fn, Delay) => State.Timers.Push(Fn))
	Safe := MenuStartupSafeCommand(MenuStartupLifecycleDispatch.Bind("reload", (*) => _MSC_UnexpectedLifecycleCommand("reload")))
	AssertTrue(MenuCommandRun(Safe, [], 0, () => false))
	AssertEqual("reload", _TrayStartupCommands.Pending)
	AssertEqual(0, Owner.Pending.Length, "the ordinary feature queue does not own recovery")
	AssertEqual(1, State.Timers.Length, "a stalled startup still schedules its retained reload intent")
	AssertEqual(0, State.Calls.Length, "menu acceptance is not reload completion")
	AssertFalse(State.Ready)
	AssertTrue(State.Timers[1].Call(), "the guarded command owner receives reload before input readiness")
	AssertEqual(1, State.Calls.Length)
	AssertEqual("reload", State.Calls[1])
	AssertEqual("", _TrayStartupCommands.Pending)
	AssertFalse(State.Timers[1].Call(), "the retained command dispatches once")
	AssertEqual(1, State.Calls.Length)
	AssertFalse(State.Ready, "recovery must not fabricate input readiness")
}
Test("menu startup: reload recovers before input readiness through its ordinary owner (startup-menu-reload)",
	(*) => _MSC_WithOwner(_MSC_ReloadDuringStalledStartup))

_MSC_ReloadRetiredBeforeDelivery(Owner, State) {
	global _TrayStartupCommands
	_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
		(Id) => State.Calls.Push(Id), (Fn, Delay) => State.Timers.Push(Fn))
	AssertTrue(MenuStartupLifecycleDispatch("reload", (*) => _MSC_UnexpectedLifecycleCommand("reload")))
	AssertEqual(1, State.Timers.Length)
	_TrayStartupCommands.Retire()
	AssertFalse(State.Timers[1].Call())
	AssertFalse(_TrayStartupCommands.Request("reload"))
	AssertEqual(0, State.Calls.Length, "retired command ownership cannot restart the driver")
}
Test("menu startup: retired early reload refuses delivery without lifecycle effects (startup-menu-reload-retire)",
	(*) => _MSC_WithOwner(_MSC_ReloadRetiredBeforeDelivery))

_MSC_ReloadRespectsEarlierIntent(Owner, State) {
	global _TrayStartupCommands
	for Earlier in ["suspend", "quit"] {
		_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
			(Id) => State.Calls.Push(Id), (Fn, Delay) => State.Timers.Push(Fn))
		AssertTrue(_TrayStartupCommands.Request(Earlier))
		AssertFalse(_TrayStartupCommands.Request("reload"), "recovery cannot replace an accepted lifecycle intent")
		AssertEqual(Earlier, _TrayStartupCommands.Pending)
		AssertFalse(_TrayStartupCommands.Dispatch())
		AssertEqual(0, State.Timers.Length, "pause and quit retain their existing readiness requirement")
		_TrayStartupCommands.Retire()
	}
	AssertEqual(0, State.Calls.Length)
}
Test("menu startup: recovery reload preserves pending pause quit and readiness ownership (startup-menu-reload-priority)",
	(*) => _MSC_WithOwner(_MSC_ReloadRespectsEarlierIntent))

_MSC_ReloadWaitsForConfigWrite(Owner, State) {
	global _TrayStartupCommands
	Busy := true, Retries := []
	_TrayStartupCommands := TrayStartupCommands(() => State.Ready,
		(Id) => State.Calls.Push(Id), (Fn, Delay) => State.Timers.Push(Fn))
	Safe := MenuStartupSafeCommand(MenuStartupLifecycleDispatch.Bind("reload", (*) => _MSC_UnexpectedLifecycleCommand("reload")))
	AssertEqual("", MenuCommandRun(Safe, [], 0, () => Busy, (Fn, Delay) => Retries.Push(Fn)))
	AssertEqual(1, Retries.Length, "the existing configuration write keeps ordinary command deferral")
	AssertEqual("", _TrayStartupCommands.Pending)
	AssertEqual(0, State.Timers.Length)
	Busy := false
	Retries[1].Call()
	AssertEqual("reload", _TrayStartupCommands.Pending)
	AssertEqual(1, State.Timers.Length)
	AssertEqual(0, State.Calls.Length)
	State.Timers[1].Call()
	AssertEqual(1, State.Calls.Length)
	AssertEqual("reload", State.Calls[1])
}
Test("menu startup: early reload retains configuration transaction deferral (startup-menu-reload-write)",
	(*) => _MSC_WithOwner(_MSC_ReloadWaitsForConfigWrite))





_MSC_RepeatableToggleJoinsOnlyExactRegistration(Owner, State) {
	global _MenuDispatchTokens, _SuspendPending
	ItemId := 987653, Token := 23456
	HadToken := _MenuDispatchTokens.Has(ItemId)
	SavedToken := _MenuDispatchTokens.Get(ItemId, 0)
	Callback := (*) => State.Calls.Push("toggle")
	Toggle := MenuStartupRepeatableToggleCommand("llm_toggle", Callback)
	try {
		_MenuDispatchTokens[ItemId] := Token
		Registration := {ItemId: ItemId, Token: Token}
		AssertTrue(Owner.Retain(Toggle, [], Registration))
		AcceptedAt := Owner.Pending[1].AcceptedAt
		AssertTrue(Owner.Retain(Toggle, [], Registration))
		AssertEqual(1, Owner.Pending.Length, "unchanged early toggle presentation retains one intent")
		AssertEqual(AcceptedAt, Owner.Pending[1].AcceptedAt, "joining does not renew the accepted intent")
		Owner.Retain((*) => State.Calls.Push("first"), [])
		Owner.Retain((*) => State.Calls.Push("second"), [])
		AssertEqual(3, Owner.Pending.Length, "ordinary commands preserve their independent FIFO")
		AssertEqual(0, State.Calls.Length, "joining never bypasses startup readiness")
		State.Ready := true
		Owner.NotifyReady()
		State.Timers[1].Call()
		AssertEqual(3, State.Calls.Length)
		AssertEqual("toggle", State.Calls[1])
		AssertEqual("first", State.Calls[2])
		AssertEqual("second", State.Calls[3])
		Owner.Released := false
		Owner.Retain(Toggle, [], Registration)
		_MenuDispatchTokens[ItemId] := Token + 1
		Owner.Retain(Toggle, [], {ItemId: ItemId, Token: Token + 1})
		AssertEqual(2, Owner.Pending.Length, "refreshed registration cannot join the retired intent")
		Owner.NotifyReady()
		State.Timers[2].Call()
		AssertEqual(4, State.Calls.Length, "only the independently current registration runs")
		Owner.Released := false
		Owner.Retain(Toggle, [], {ItemId: ItemId, Token: Token + 1})
		_SuspendPending := true
		Owner.NotifyReady()
		State.Timers[3].Call()
		AssertEqual(4, State.Calls.Length, "pending pause still refuses the marked selection")
		_SuspendPending := false
		Owner.Released := false
		Owner.Retain(Toggle, [], {ItemId: ItemId, Token: Token + 1})
		Owner.NotifyReady()
		Owner.Cancel()
		State.Timers[4].Call()
		AssertEqual(4, State.Calls.Length, "cancellation still retires a joined intent")
	} finally {
		if HadToken
			_MenuDispatchTokens[ItemId] := SavedToken
		else if _MenuDispatchTokens.Has(ItemId)
			_MenuDispatchTokens.Delete(ItemId)
	}
}
Test("menu startup: explicit AI toggle joins repeated clicks without changing generic FIFO (startup-llm-toggle-coalescence)",
	(*) => _MSC_WithOwner(_MSC_RepeatableToggleJoinsOnlyExactRegistration))

_MSC_RepeatableToggleRequiresExactCallback(Owner, State) {
	Callback := (*) => 0
	OtherCallback := (*) => 0
	Registration := {ItemId: 987652, Token: 34567}
	Owner.Retain(MenuStartupRepeatableToggleCommand("llm_toggle", Callback), [], Registration)
	Owner.Retain(MenuStartupRepeatableToggleCommand("llm_toggle", OtherCallback), [], Registration)
	Owner.Retain(Callback, [], Registration)
	Owner.Retain(Callback, [], Registration)
	AssertEqual(4, Owner.Pending.Length, "different callbacks and unmarked commands never join")
	Owner.Cancel()
}
Test("menu startup: repeat policy requires the same declared callback (startup-llm-toggle-coalescence)",
	(*) => _MSC_WithOwner(_MSC_RepeatableToggleRequiresExactCallback))

_MSC_RendererDeclaresOnlyAIRepeatPolicy() {
	global _MenuDispatchCallbacks, _MenuDispatchOwnerHandles
	NativeMenu := Menu(), Callback := (*) => 0
	try {
		Item := _MR_FindItemById("llm_menu", "llm_toggle")
		AssertTrue(Item is Map, "the declared AI switch must exist")
		AssertEqual(1, _MR_RenderToggle(NativeMenu, Item, "llm_menu",
			Map("llm_toggle", Callback), Map("llm_enabled", (*) => false, "llm_toggle_ready", (*) => true)))
		ItemId := _MenuItemIdAtPosition(NativeMenu, 0)
		Action := _MenuDispatchCallbacks[ItemId]
		AssertTrue(Action is MenuStartupRepeatableToggleCommand,
			"the actual renderer must explicitly declare the startup repeat policy")
		AssertEqual("llm_toggle", Action.Id)
		AssertTrue(Action.Callback == Callback, "the policy retains the exact registered callback")
		AssertFalse(Action is MenuStartupSafeCommand, "repeat policy cannot bypass startup readiness")
	} finally {
		NativeMenu.Delete()
		MenuDispatcher_PruneMenu(NativeMenu)
		if _MenuDispatchOwnerHandles.Has(NativeMenu.Handle)
			_MenuDispatchOwnerHandles.Delete(NativeMenu.Handle)
	}
}
Test("menu startup: actual renderer declares AI toggle repeat policy (startup-llm-toggle-coalescence)",
	_MSC_RendererDeclaresOnlyAIRepeatPolicy)
