; tests/unit/ui/menu/test_menu_reload_replay.ahk

; ==============================================================================
; MODULE: Menu commands that land after a reload are replayed by the successor
; DESCRIPTION:
; Tray clicks retained during a slow start ran when the configuration write they
; waited for ended. That write was a hotstring intent asking for a reload, so the
; terminal barrier already owned every path and each retained toggle was refused
; with an error toast and lost (`terminal_barrier_busy`, four toasts in one
; session, Windows log of 2026-10-17). A command that lands while a reload is
; pending now waits for it; OnExit hands its tray row to the successor, which
; consumes the hand-off once and replays the row after input readiness. The
; reload successor and its tray are simulated in-process with real native menus,
; the real dispatcher tables and a real hand-off file.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Records one command run without retaining its native Menu. */
_MRR_Command(Runs, Who, ItemName, ItemPosition, NativeMenu) {
	Runs.Push({Who: Who, Name: ItemName, Position: ItemPosition,
		Handle: NativeMenu is Menu ? NativeMenu.Handle : NativeMenu})
	return "ran"
}

/** Builds "Features > Toggle" with a tracked row, as the tray builders do. */
_MRR_BuildTray(Fixture, Who) {
	global _MenuDispatchTokens
	Root := Menu(), Sub := Menu()
	Command := _MRR_Command.Bind(Fixture.Runs, Who)
	AssertEqual(1, RegisterMenuItem(Sub, "Other", NoAction))
	AssertEqual(1, RegisterMenuItem(Sub, "Toggle", Command), "the actual dispatcher tracks the row")
	Root.Add("Features", Sub)
	Fixture.Menus.Push(Sub, Root)
	ItemId := _MenuItemIdAtPosition(Sub, 1)
	AssertTrue(ItemId > 0)
	return {Root: Root, Sub: Sub, Command: Command,
		Identity: {ItemId: ItemId, Token: _MenuDispatchTokens[ItemId]}}
}

_MRR_Arm(Fixture, Callback, DelayMs) {
	Fixture.Armed.Push(Callback)
	return true
}

_MRR_RunArmed(Fixture) {
	Armed := Fixture.Armed
	Fixture.Armed := []
	for Callback in Armed
		Callback.Call()
}

_MRR_Notify(Fixture, Message, Options) {
	Fixture.Notices.Push({Message: Message, Level: Options["level"]})
}

/** Isolates every owner the hand-off touches and restores it afterwards. */
_MRR_Run(Body) {
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
	global _ReloadTerminalHandoff, _MenuStartupCommands, _TrayStartupCommands, _SuspendPending
	global _MenuReloadReplayHeld, _MenuReloadReplayNextKey, _MenuReloadReplayPublished
	global _MenuReloadReplayConsumed, _MenuReloadReplayRoot, _MenuReloadReplayIdentities
	global _MenuPopulationPublished, _MenuPopulationBuilding
	AssertTrue((_MenuStartupCommands is Integer) && _MenuStartupCommands == 0,
		"the fixture cannot adopt live startup selections")
	AssertFalse(ReloadTerminalHandoffActive(), "the fixture cannot adopt a live reload")
	Saved := {Callbacks: _MenuDispatchCallbacks, LastFire: _MenuDispatchLastFire,
		Tokens: _MenuDispatchTokens, Clicks: _MenuDispatchClickSequences,
		Handles: _MenuDispatchOwnerHandles, Handoff: _ReloadTerminalHandoff,
		Held: _MenuReloadReplayHeld, NextKey: _MenuReloadReplayNextKey,
		Published: _MenuReloadReplayPublished, Consumed: _MenuReloadReplayConsumed,
		Root: _MenuReloadReplayRoot, Identities: _MenuReloadReplayIdentities,
		Population: _MenuPopulationPublished, Building: _MenuPopulationBuilding,
		Tray: IsSet(_TrayStartupCommands) ? _TrayStartupCommands : false,
		Pause: IsSet(_SuspendPending) ? _SuspendPending : false}
	Dir := A_Temp . "\ergopti_mrr_" . A_ScriptHwnd . "_" . A_TickCount
	DirCreate(Dir)
	Fixture := {Runs: [], Menus: [], Armed: [], Notices: [], Dir: Dir,
		File: Dir . "\menu_reload_replay.json", Populations: []}
	try {
		_MenuDispatchCallbacks := _MenuDispatchCallbacks.Clone()
		_MenuDispatchLastFire := _MenuDispatchLastFire.Clone()
		_MenuDispatchTokens := _MenuDispatchTokens.Clone()
		_MenuDispatchClickSequences := _MenuDispatchClickSequences.Clone()
		_MenuDispatchOwnerHandles := _MenuDispatchOwnerHandles.Clone()
		_MenuReloadReplayIdentities := _MenuReloadReplayIdentities.Clone()
		_MenuPopulationPublished := false, _MenuPopulationBuilding := false
		_MenuReloadReplayHeld := Map()
		_MenuReloadReplayPublished := false
		_MenuReloadReplayConsumed := false
		_TrayStartupCommands := false
		_SuspendPending := false
		Body.Call(Fixture)
	} finally {
		Fixture.Armed := []
		_MenuStartupCommands := 0
		_ReloadTerminalHandoff := Saved.Handoff
		_MenuReloadReplayRoot := Saved.Root
		for Population in Fixture.Populations {
			Population.Stop()
			Population.Pending.Clear()
		}
		_MenuPopulationPublished := Saved.Population, _MenuPopulationBuilding := Saved.Building
		for NativeMenu in Fixture.Menus {
			NativeMenu.Delete()
			MenuDispatcher_PruneMenu(NativeMenu)
		}
		_MenuReloadReplayIdentities := Saved.Identities
		_MenuDispatchCallbacks := Saved.Callbacks
		_MenuDispatchLastFire := Saved.LastFire
		_MenuDispatchTokens := Saved.Tokens
		_MenuDispatchClickSequences := Saved.Clicks
		_MenuDispatchOwnerHandles := Saved.Handles
		_MenuReloadReplayHeld := Saved.Held
		_MenuReloadReplayNextKey := Saved.NextKey
		_MenuReloadReplayPublished := Saved.Published
		_MenuReloadReplayConsumed := Saved.Consumed
		_TrayStartupCommands := Saved.Tray
		_SuspendPending := Saved.Pause
		DirDelete(Dir, true)
	}
}

/** A launched successor makes ReloadTerminalHandoffActive() true, as in production. */
_MRR_ReloadPending() {
	global _ReloadTerminalHandoff
	_ReloadTerminalHandoff := Map("state", "pending")
}

_MRR_ReloadEnded() {
	global _ReloadTerminalHandoff
	_ReloadTerminalHandoff := false
}

/** Starts the successor's startup owner on the consumed rows and releases it. */
_MRR_SuccessorDrains(Fixture, Paths) {
	global _MenuStartupCommands
	State := {Ready: false, Timers: []}
	Owner := MenuStartupCommands(() => State.Ready, (Fn, Delay) => State.Timers.Push(Fn))
	_MenuStartupCommands := Owner
	AssertTrue(Owner.AdoptReplay(Paths))
	AssertEqual(Paths.Length, Owner.Pending.Length, "handed-over rows wait for input readiness")
	State.Ready := true
	AssertTrue(Owner.NotifyReady())
	AssertEqual(Paths.Length ? 1 : 0, State.Timers.Length)
	for Timer in State.Timers
		Timer.Call()
	return Owner
}





; ======================================================
; ======================================================
; ======= 1/ A click during a reload is replayed =======
; ======================================================
; ======================================================

_MRR_ReplayedBody(Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRR_BuildTray(Fixture, "predecessor")
	_MenuReloadReplayRoot := Old.Root
	_MRR_ReloadPending()
	AssertEqual("", MenuCommandRun(Old.Command, ["Toggle", 2, Old.Sub], 0, () => false,
		_MRR_Arm.Bind(Fixture), Old.Identity), "a command landing during a reload waits for it")
	AssertEqual(0, Fixture.Runs.Length,
		"the command is not run against the terminal barrier (terminal_barrier_busy, menu-clicks-after-reload)")
	AssertEqual(1, MenuReloadReplay_HeldCount())
	AssertEqual(1, Fixture.Armed.Length, "one look is scheduled in case the reload is refused")
	_MRR_RunArmed(Fixture)
	AssertEqual(0, Fixture.Runs.Length, "a reload still pending keeps the command waiting")
	AssertEqual(1, Fixture.Armed.Length)

	AssertTrue(MenuReloadReplay_Publish(Fixture.File), "the accepted reload publishes the held row")
	AssertTrue(FileExist(Fixture.File) != "")
	AssertEqual(0, MenuReloadReplay_HeldCount())
	_MRR_RunArmed(Fixture)
	AssertEqual(0, Fixture.Runs.Length, "a handed-over command never also runs in the exiting instance")
	AssertEqual(0, Fixture.Armed.Length)

	; The successor: a new process, a new tray with the same rows.
	_MRR_ReloadEnded()
	New := _MRR_BuildTray(Fixture, "successor")
	_MenuReloadReplayRoot := New.Root
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertEqual(1, Paths.Length)
	AssertEqual("Features", Paths[1][1])
	AssertEqual("Toggle", Paths[1][2])
	AssertFalse(FileExist(Fixture.File) != "", "the hand-off is consumed once")
	_MRR_SuccessorDrains(Fixture, Paths)
	AssertEqual(1, Fixture.Runs.Length, "the successor replays the click exactly once")
	AssertEqual("successor", Fixture.Runs[1].Who, "through its own registration of the row")
	AssertEqual("Toggle", Fixture.Runs[1].Name)
	AssertEqual(2, Fixture.Runs[1].Position)
	AssertEqual(New.Sub.Handle, Fixture.Runs[1].Handle, "with the native arguments of its row")
	AssertEqual(0, Fixture.Notices.Length)
}
Test("menu reload replay: a click landing during a reload is replayed by the successor (menu-clicks-after-reload)",
	(*) => _MRR_Run(_MRR_ReplayedBody))

_MRR_RetainedBody(Fixture) {
	global _MenuReloadReplayRoot, _MenuStartupCommands
	Old := _MRR_BuildTray(Fixture, "predecessor")
	_MenuReloadReplayRoot := Old.Root
	; A selection retained by a start that never completed before the reload.
	Owner := MenuStartupCommands(() => false, (Fn, Delay) => 0)
	_MenuStartupCommands := Owner
	AssertEqual("", MenuCommandRun(Old.Command, ["Toggle", 2, Old.Sub], 0, 0, 0, Old.Identity))
	AssertEqual(1, Owner.Pending.Length)
	_MRR_ReloadPending()
	AssertTrue(MenuReloadReplay_Publish(Fixture.File))
	AssertEqual(0, Owner.Pending.Length, "the startup owner hands its retained selection over")
	_MenuStartupCommands := 0
	_MRR_ReloadEnded()
	New := _MRR_BuildTray(Fixture, "successor")
	_MenuReloadReplayRoot := New.Root
	_MRR_SuccessorDrains(Fixture, MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture)))
	AssertEqual(1, Fixture.Runs.Length)
	AssertEqual("successor", Fixture.Runs[1].Who)
}
Test("menu reload replay: a startup selection still retained at the reload is replayed by the successor",
	(*) => _MRR_Run(_MRR_RetainedBody))

_MRR_RefusedReloadBody(Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRR_BuildTray(Fixture, "predecessor")
	_MenuReloadReplayRoot := Old.Root
	_MRR_ReloadPending()
	MenuCommandRun(Old.Command, ["Toggle", 2, Old.Sub], 0, () => false, _MRR_Arm.Bind(Fixture), Old.Identity)
	AssertEqual(0, Fixture.Runs.Length)
	_MRR_ReloadEnded()
	_MRR_RunArmed(Fixture)
	AssertEqual(1, Fixture.Runs.Length, "a refused reload lets the held command run here")
	AssertEqual("predecessor", Fixture.Runs[1].Who)
	AssertEqual(0, MenuReloadReplay_HeldCount())
	AssertTrue(MenuReloadReplay_Publish(Fixture.File))
	AssertFalse(FileExist(Fixture.File) != "", "a command that ran here is never handed to a later reload")
}
Test("menu reload replay: a refused reload runs the held command in place",
	(*) => _MRR_Run(_MRR_RefusedReloadBody))


; Declared provider actions take no arguments. Observe the actual native delivery
; at the rendered row, then let the real provider wrapper call that domain action.
_MRRF_ProviderDelivery(Receipt, Delivery, Args*) {
	PreviousArgs := Receipt.Args
	Receipt.Args := Args
	try return Delivery.Call(Args*)
	finally Receipt.Args := PreviousArgs
}

_MRRF_ProviderAction(Runs, Who, Receipt) {
	AssertTrue(Receipt.Args is Array, "the real native row must observe its arguments before the zero-argument provider action")
	return _MRR_Command(Runs, Who, Receipt.Args*)
}

_MRRF_ProviderRow(Fixture, Who, CommandId) {
	Receipt := {Args: 0}
	Row := MenuRenderer_CommandRow("script_control_group", CommandId,
		Map(CommandId, _MRRF_ProviderAction.Bind(Fixture.Runs, Who, Receipt)))
	AssertTrue(Row is Map, "the canonical branch uses a real declared action")
	Row["action"] := _MRRF_ProviderDelivery.Bind(Receipt, Row["action"])
	return Row
}

; A detached rebuild keeps the old child alive through the retry's native Args.
; Its token may remain valid, but it no longer owns the command the current tray
; offers. A refused reload must resolve the held row instead of invoking it.
_MRRF_Build(Fixture, Who, Canonical) {
	global _MenuDispatchCallbacks, _MenuDispatchTokens
	if !Canonical {
		Tray := _MRR_BuildTray(Fixture, Who)
		Tray.Position := 2
		return Tray
	}
	Sub := Menu(), Root := Menu()
	Row := _MRRF_ProviderRow(Fixture, Who, "scope_restore")
	Row["label"] := "Toggle"
	AssertEqual(1, MenuRenderer_AppendRows(Sub, "refused reload fixture", "restore", [Row]))
	Root.Add("Features", Sub), Fixture.Menus.Push(Sub, Root)
	Id := _MenuItemIdAtPosition(Sub, 0)
	return {Root: Root, Sub: Sub, Command: _MenuDispatchCallbacks[Id], Position: 1,
		Identity: {ItemId: Id, Token: _MenuDispatchTokens[Id]}}
}

_MRRF_Hold(Fixture, Tray, Canonical) {
	global _MenuReloadReplayRoot
	_MenuReloadReplayRoot := Tray.Root
	Path := MenuReloadReplay_PathOf(Tray.Identity.ItemId)
	AssertEqual(Canonical, Path.HasOwnProp("ReplayIdentity"))
	_MRR_ReloadPending()
	Before := Fixture.Runs.Length
	AssertEqual("", MenuCommandRun(Tray.Command, ["Toggle", Tray.Position, Tray.Sub],
		0, () => false, _MRR_Arm.Bind(Fixture), Tray.Identity))
	AssertEqual(Before, Fixture.Runs.Length, "no configuration command runs while its reload owns the barrier")
	AssertEqual(1, MenuReloadReplay_HeldCount())
	AssertEqual(1, Fixture.Armed.Length)
	return Path
}

_MRRF_Refused(Canonical, Mode, Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRRF_Build(Fixture, "obsolete", Canonical)
	HeldPath := _MRRF_Hold(Fixture, Old, Canonical)
	Current := _MRRF_Build(Fixture, "current", Canonical)
	_MenuReloadReplayRoot := Current.Root
	switch Mode {
		case "missing": Current.Sub.Delete("Toggle")
		case "disabled-leaf": Current.Sub.Disable("Toggle")
		case "disabled-parent": Current.Root.Disable("Features")
		case "moved-context": Current.Root.Rename("Features", "Other context")
		case "other-action":
			Row := _MRRF_ProviderRow(Fixture, "wrong action", "scope_clear")
			Row["label"] := "Toggle"
			AssertEqual(1, MenuRenderer_AppendRows(Current.Sub, "refused reload fixture", "clear", [Row]))
			AssertFalse(_MenuReloadReplayIdentityOf(_MenuItemIdAtPosition(Current.Sub, 0)) == HeldPath.ReplayIdentity,
				"the current caption names a different real declared action")
		case "ambiguous":
			Identity := Canonical ? HeldPath.ReplayIdentity : ""
			AssertEqual(1, RegisterMenuItemInsert(Current.Sub, "1&", "Toggle",
				_MRR_Command.Bind(Fixture.Runs, "ambiguous twin"), Identity))
			Matches := 0
			loop _MenuReloadReplayCount(Current.Sub.Handle)
				if _MenuReloadReplayLabel(Current.Sub.Handle, A_Index - 1) == "Toggle"
					Matches += 1
			AssertEqual(2, Matches, "the actual native menu contains two equal captions")
			AssertTrue(_MenuItemIdAtPosition(Current.Sub, 0) != _MenuItemIdAtPosition(Current.Sub, Current.Position),
				"the duplicate rows have different real tracked command IDs")
	}
	MenuDispatcher_PruneMenu(Current.Sub)
	AssertTrue(_MenuCommandRegistrationCurrent(Old.Identity),
		"the retained native Menu is still alive, so the obsolete callback could run before this fix")
	_MRR_ReloadEnded()
	_MRR_RunArmed(Fixture)
	AssertEqual(0, MenuReloadReplay_HeldCount(), "a refused reload releases the exact held intent once")
	AssertEqual(0, Fixture.Armed.Length)
	AssertEqual(Mode == "replaced" ? 1 : 0, Fixture.Runs.Length,
		"only a unique enabled current row may execute; no obsolete callback may run")
	if Mode == "replaced" {
		AssertEqual("current", Fixture.Runs[1].Who)
		AssertEqual("Toggle", Fixture.Runs[1].Name)
		AssertEqual(Current.Position, Fixture.Runs[1].Position)
		AssertEqual(Current.Sub.Handle, Fixture.Runs[1].Handle, "dispatch receives the actual current native arguments")
		; Also cover a real explicit retirement, without deleting dictionary entries
		; or relying on native ID reuse. The next held Menu truly loses its rows.
		_MRRF_Hold(Fixture, Current, Canonical)
		Next := _MRRF_Build(Fixture, "next", Canonical)
		_MenuReloadReplayRoot := Next.Root
		Current.Sub.Delete()
		MenuDispatcher_PruneMenu(Current.Sub)
		AssertFalse(_MenuCommandRegistrationCurrent(Current.Identity), "actual native deletion retires this registration")
		_MRR_ReloadEnded()
		_MRR_RunArmed(Fixture)
		AssertEqual(2, Fixture.Runs.Length)
		AssertEqual("next", Fixture.Runs[2].Who, "a retired predecessor also resolves through the current tray")
		AssertEqual(Next.Sub.Handle, Fixture.Runs[2].Handle)
		AssertEqual(0, MenuReloadReplay_HeldCount())
		AssertEqual(0, Fixture.Armed.Length)
	}
	AssertTrue(MenuReloadReplay_Publish(Fixture.File))
	AssertFalse(FileExist(Fixture.File) != "", "a resolved or refused command cannot leak into a later reload")
}

for _MRRF_Canonical in [false, true]
	for _MRRF_Mode in ["replaced", "missing", "disabled-leaf", "disabled-parent", "ambiguous"]
		Test("menu reload refusal: " . (_MRRF_Canonical ? "canonical" : "labels") . " " . _MRRF_Mode
			. " resolves the retained current row (menu-refused-reload-rebuild)",
			_MRR_Run.Bind(_MRRF_Refused.Bind(_MRRF_Canonical, _MRRF_Mode)))

Test("menu reload refusal: a changed declared action cannot reuse the retained caption (menu-refused-reload-rebuild)",
	_MRR_Run.Bind(_MRRF_Refused.Bind(true, "other-action")))
Test("menu reload refusal: a moved declared context cannot adopt the held action (menu-refused-reload-rebuild)",
	_MRR_Run.Bind(_MRRF_Refused.Bind(true, "moved-context")))





; ======================================================
; ======================================================
; ======= 2/ Invalid and duplicate state refused =======
; ======================================================
; ======================================================

_MRR_WriteHandoff(Fixture, Text) {
	FileAppend(Text, Fixture.File, "UTF-8-RAW")
}

_MRR_InvalidCase(Fixture, Text, Why) {
	global _MenuReloadReplayConsumed
	_MenuReloadReplayConsumed := false
	Fixture.Notices := []
	_MRR_WriteHandoff(Fixture, Text)
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertEqual(0, Paths.Length, Why . ": nothing is replayed")
	AssertEqual(1, Fixture.Notices.Length, Why . ": the user is told the clicks were lost")
	AssertEqual("error", Fixture.Notices[1].Level)
	AssertFalse(FileExist(Fixture.File) != "", Why . ": the invalid hand-off is not left for a later boot")
}

_MRR_InvalidBody(Fixture) {
	global MENU_RELOAD_REPLAY_SCHEMA, MENU_STARTUP_MAX_PENDING
	Schema := JsonStringLiteral(MENU_RELOAD_REPLAY_SCHEMA)
	_MRR_InvalidCase(Fixture, "not json", "malformed text")
	_MRR_InvalidCase(Fixture, '{"schema":"other","commands":[["A"]]}', "foreign schema")
	_MRR_InvalidCase(Fixture, '{"schema":' . Schema . ',"commands":[]}', "empty command list")
	_MRR_InvalidCase(Fixture, '{"schema":' . Schema . ',"commands":[["A",""]]}', "empty label")
	_MRR_InvalidCase(Fixture, '{"schema":' . Schema . ',"commands":[["A",1]]}', "non-string label")
	_MRR_InvalidCase(Fixture, '{"schema":' . Schema . ',"commands":[["A"]],"extra":1}', "unknown member")
	TooMany := ""
	Loop MENU_STARTUP_MAX_PENDING + 1
		TooMany .= (TooMany == "" ? "" : ",") . '["A"]'
	_MRR_InvalidCase(Fixture, '{"schema":' . Schema . ',"commands":[' . TooMany . ']}', "over capacity")
}
Test("menu reload replay: an invalid hand-off is consumed, refused and reported",
	(*) => _MRR_Run(_MRR_InvalidBody))

_MRR_DuplicateBody(Fixture) {
	global _MenuReloadReplayConsumed
	AssertEqual(0, MenuReloadReplay_Consume(Fixture.File).Length, "no hand-off, nothing to replay")
	AssertThrows(() => MenuReloadReplay_Consume(Fixture.File), "an instance consumes the hand-off once")
	Owner := MenuStartupCommands(() => false, (Fn, Delay) => 0)
	AssertTrue(Owner.AdoptReplay([]))
	AssertThrows(() => Owner.AdoptReplay([]), "handed-over rows are adopted once")
	Late := MenuStartupCommands(() => false, (Fn, Delay) => 0)
	Late.Retain((*) => 0, [])
	AssertThrows(() => Late.AdoptReplay([["A"]]), "handed-over rows precede every startup selection")
	AssertThrows(() => Owner.AdoptReplay("A"), "rows must be an array")
	AssertTrue(MenuReloadReplay_Publish(Fixture.File))
	AssertThrows(() => MenuReloadReplay_Publish(Fixture.File), "an instance hands its commands over once")
}
Test("menu reload replay: consumption, adoption and publication each happen once",
	(*) => _MRR_Run(_MRR_DuplicateBody))

_MRR_UnmatchedBody(Fixture) {
	global _MenuReloadReplayRoot
	Tray := _MRR_BuildTray(Fixture, "successor")
	_MenuReloadReplayRoot := Tray.Root
	AssertFalse(MenuReloadReplay_Run(["Features", "Gone"], _MRR_Notify.Bind(Fixture)))
	AssertFalse(MenuReloadReplay_Run(["Toggle"], _MRR_Notify.Bind(Fixture)),
		"a row is matched at its own level only")
	AssertEqual(0, Fixture.Runs.Length)
	AssertEqual(2, Fixture.Notices.Length, "every row that cannot be replayed is reported")
	AssertFalse(MenuReloadReplay_Resolve(["Features"]), "a submenu is not a command row")
	Found := MenuReloadReplay_Resolve(["Features", "Toggle"])
	AssertTrue(IsObject(Found))
	AssertEqual(Tray.Identity.ItemId, Found.ItemId, "the exact path resolves to its own registered row")
	AssertEqual(Tray.Identity.ItemId, MenuReloadReplay_PathOf(Tray.Identity.ItemId) is Array
		? Found.ItemId : 0, "and the row's path round-trips")
}
Test("menu reload replay: a row the successor's tray does not hold once is reported, never guessed",
	(*) => _MRR_Run(_MRR_UnmatchedBody))





; ====================================
; ====================================
; ======= 3/ Production wiring =======
; ====================================
; ====================================

_MRR_WiringBody() {
	OnExitBody := _StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown"))
	Assert(OnExitBody != "", "the lifecycle owner must remain source-visible")
	Terminal := InStr(OnExitBody, "ShutdownTerminal := true", true)
	Publish := InStr(OnExitBody, "MenuReloadReplay_Publish()", true)
	Startup := InStr(OnExitBody, "MenuStartupCommands_Shutdown()", true)
	Menus := InStr(OnExitBody, "MenuDispatcher_Shutdown()", true)
	Assert(Terminal > 0 && Publish > Terminal && Startup > Publish && Menus > Publish,
		"the hand-off is published after the last refusal gate, before the startup owner and the tray retire")
	Guard := SubStr(OnExitBody, Terminal, Publish - Terminal)
	Assert(InStr(Guard, "if (TerminalHandoff is Map)", true) > 0, "only an accepted reload hands commands over")
	AssertFalse(InStr(SubStr(OnExitBody, Publish), "return _LifecycleRefuse", true),
		"no refusal may follow the hand-off")

	SplitPath(A_ScriptDir, , &WindowsDir)
	Entry := _StripFullLineComments(FileRead(WindowsDir . "\ErgoptiPlus.ahk", "UTF-8"))
	Assert(InStr(Entry, "MenuStartupCommands_Begin(() => _DriverReady && _LLM_Menu_RuntimeActivated, MenuReloadReplay_Consume())", true) > 0,
		"the successor consumes the hand-off when its startup owner begins")

	Run := _DriverFuncBody("MenuCommandRun")
	Assert(Run != "", "the dispatch owner must remain source-visible")
	Assert(InStr(Run, "MenuReloadReplay_Hold(0, Registration)", true) > 0,
		"every menu command, native, rescued or retained, meets the reload hand-off")
}
Test("menu reload replay: OnExit publishes, boot consumes and every dispatch meets the hand-off",
	_MRR_WiringBody)

#Include test_menu_reload_replay_identity.ahk

#Include test_menu_reload_replay_hold_owner.ahk
