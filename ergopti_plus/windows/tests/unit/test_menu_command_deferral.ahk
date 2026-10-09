; tests/unit/test_menu_command_deferral.ahk

; ==============================================================================
; MODULE: A menu command clicked during a configuration write waits for it
; DESCRIPTION:
; AutoHotkey runs no timer while a tray menu is open, so a save that came due
; meanwhile starts the moment the menu closes, and the clicked row's command
; then interrupts it. The interrupted writer keeps its lease until the command
; returns, so the command could only be refused: « Could not persist the
; 'FrenchMagicKey' category toggle: another configuration transaction is
; already in progress », with an error window, and the setting was lost
; (menu-click-during-config-write, seen on 2026-10-01 thirty seconds after a
; start). The dispatcher now runs the command once the write has ended. The
; wait is driven here with a captured timer instead of the message loop.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MCD_Armed := []
global _MCD_Busy := false
global _MCD_Runs := []

_MCD_Reset(Busy) {
	global _MCD_Armed := []
	global _MCD_Busy := Busy
	global _MCD_Runs := []
}

_MCD_Arm(Callback, DelayMs) {
	global _MCD_Armed
	_MCD_Armed.Push(Map("fn", Callback, "ms", DelayMs))
	return true
}

_MCD_IsBusy() {
	global _MCD_Busy
	return _MCD_Busy
}

_MCD_Command(Args*) {
	global _MCD_Runs
	Text := ""
	for Value in Args
		Text .= (Text == "" ? "" : "|") . Value
	_MCD_Runs.Push(Text)
	return "done"
}

; Runs the timers armed so far, as the message loop would.
_MCD_RunArmed() {
	global _MCD_Armed
	Armed := _MCD_Armed
	_MCD_Armed := []
	for Entry in Armed
		Entry["fn"].Call()
}

_MCD_RunsAtOnceWhenFree() {
	global _MCD_Armed, _MCD_Runs
	_MCD_Reset(false)
	AssertEqual("done", MenuCommandRun(_MCD_Command, ["Row", 3, "menu"], 0, _MCD_IsBusy, _MCD_Arm),
		"a command with no write in progress runs in the click's own thread")
	AssertEqual(1, _MCD_Runs.Length)
	AssertEqual("Row|3|menu", _MCD_Runs[1], "with the arguments AutoHotkey gave the row")
	AssertEqual(0, _MCD_Armed.Length, "and arms no timer")
}
Test("menu command deferral: a command runs at once when no write is in progress (menu-click-during-config-write)",
	_MCD_RunsAtOnceWhenFree)

_MCD_WaitsForTheWrite() {
	global _MCD_Armed, _MCD_Busy, _MCD_Runs, MENU_COMMAND_DEFERRAL_RETRY_MS
	_MCD_Reset(true)
	MenuCommandRun(_MCD_Command, ["Row", 3, "menu"], 0, _MCD_IsBusy, _MCD_Arm)
	AssertEqual(0, _MCD_Runs.Length, "a command clicked during a write is not run against the lease it interrupted")
	AssertEqual(1, _MCD_Armed.Length, "one retry is scheduled")
	AssertEqual(MENU_COMMAND_DEFERRAL_RETRY_MS, _MCD_Armed[1]["ms"])
	_MCD_RunArmed()
	AssertEqual(0, _MCD_Runs.Length, "a write still in progress keeps the command waiting")
	AssertEqual(1, _MCD_Armed.Length, "on one timer")
	_MCD_Busy := false
	_MCD_RunArmed()
	AssertEqual(1, _MCD_Runs.Length, "the command runs once the write has ended")
	AssertEqual("Row|3|menu", _MCD_Runs[1], "with the arguments of the click")
	AssertEqual(0, _MCD_Armed.Length, "and nothing is left armed")
}
Test("menu command deferral: a command clicked during a write runs when it ends (menu-click-during-config-write)",
	_MCD_WaitsForTheWrite)

_MCD_WaitIsBounded() {
	global _MCD_Armed, _MCD_Runs, MENU_COMMAND_DEFERRAL_MAX_ATTEMPTS
	_MCD_Reset(true)
	MenuCommandRun(_MCD_Command, [], 0, _MCD_IsBusy, _MCD_Arm)
	Loop MENU_COMMAND_DEFERRAL_MAX_ATTEMPTS - 1 {
		_MCD_RunArmed()
		AssertEqual(0, _MCD_Runs.Length, "attempt " . A_Index . " still waits")
	}
	_MCD_RunArmed()
	AssertEqual(1, _MCD_Runs.Length,
		"a lease that is never released ends the wait: the command runs and reports its own refusal")
	AssertEqual(0, _MCD_Armed.Length, "no retry outlives it")
}
Test("menu command deferral: the wait is bounded and ends in the command's own report (menu-click-during-config-write)",
	_MCD_WaitIsBounded)

_MCD_ArmThrows(Callback, DelayMs) {
	throw Error("no timer")
}

_MCD_FailedTimerRunsNow() {
	global _MCD_Runs
	_MCD_Reset(true)
	MenuCommandRun(_MCD_Command, ["Row"], 0, _MCD_IsBusy, _MCD_ArmThrows)
	AssertEqual(1, _MCD_Runs.Length, "a command that cannot be deferred must not be lost")
	AssertThrows(() => MenuCommandRun(0, [], 0, _MCD_IsBusy, _MCD_Arm), "a menu command must be callable")
}
Test("menu command deferral: a timer that cannot be armed runs the command now (menu-click-during-config-write)",
	_MCD_FailedTimerRunsNow)

; What « a write in progress » is: some configuration path is owned and no
; terminal transition holds the table. A pending reload owns everything until
; the process ends, so waiting for it would only delay the refusal.
_MCD_BusyIsAnOwnedPath() {
	Path := A_Temp . "\ergopti_mcd_" . A_ScriptHwnd . "\config.toml"
	AssertFalse(ConfigWriteLeaseBusy(), "no write is in progress in an idle suite")
	Owner := _ConfigWriteLeaseTryAcquire(Path, "test")
	Assert(Owner is Object)
	try {
		AssertTrue(ConfigWriteLeaseBusy(), "an owned path is a write in progress")
	} finally _ConfigWriteLeaseRelease(Owner)
	AssertFalse(ConfigWriteLeaseBusy(), "a released lease ends it")
	Body := _DriverFuncBody("ConfigWriteLeaseBusy")
	Assert(InStr(Body, "State.terminal is Object") > 0,
		"a terminal transition is not a write to wait for: its owner never resumes")
}
Test("menu command deferral: a write in progress is an owned path outside a terminal transition (menu-click-during-config-write)",
	_MCD_BusyIsAnOwnedPath)

; The call sites: the native dispatch and the retry that rescues a dropped click.
_MCD_DispatcherDefersBothPaths() {
	Native := _DriverFuncBody("_TrackedDispatch")
	Assert(Native != "", "native dispatch must exist")
	Assert(InStr(Native, "MenuCommandRun(TrackedObj.Callback, Args, 0, 0, 0, TrackedObj)") > 0,
		"a native menu dispatch must go through the deferral")
	Assert(!InStr(Native, "TrackedObj.Callback.Call("), "and must not call the command directly")
	Bypass := _DriverFuncBody("_DispatchIfMissed")
	Assert(Bypass != "", "fallback dispatch must exist")
	Assert(InStr(Bypass, 'MenuCommandRun(Callback, ["", 0, 0], 0, 0, 0, Registration)') > 0,
		"the bypass dispatch of a dropped click must go through the deferral too")
	Assert(!InStr(Bypass, "Callback.Call("), "and must not call the command directly")
}
Test("menu command deferral: both dispatch paths defer behind a write (menu-click-during-config-write)",
	_MCD_DispatcherDefersBothPaths)





; =================================================
; =================================================
; ======= 2/ Deferred Registration Identity =======
; =================================================
; =================================================

/** Records arguments without retaining a native Menu in its own callback. */
_MCDR_Command(ActionState, ItemName, ItemPosition, NativeMenu) {
	ActionState.Runs.Push({Name: ItemName, Position: ItemPosition,
		Third: NativeMenu is Menu ? NativeMenu.Handle : NativeMenu})
	return "done"
}

/** Captures the real retry callback; no message-loop timer is created. */
_MCDR_Arm(ScheduleState, Callback, DelayMs) {
	ScheduleState.Armed.Push({Fn: Callback, Delay: DelayMs})
	return true
}

_MCDR_Drain(ScheduleState) {
	PendingRetry := ScheduleState.Armed
	ScheduleState.Armed := []
	for ScheduledRetry in PendingRetry
		ScheduledRetry.Fn.Call()
}

/** Uses real native item allocation, actual token publication and a real lease. */
_MCDR_Run(Body) {
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles, _MenuStartupCommands
	AssertTrue((_MenuStartupCommands is Integer) && _MenuStartupCommands == 0,
		"the isolated native registration fixture cannot adopt live startup selections")
	AssertFalse(_ConfigWriteTerminalIsActive(), "the fixture cannot adopt a terminal transition")
	AssertEqual(0, _ConfigWriteLeaseOwners().Count, "the fixture begins with no owned writer")
	SavedDispatch := {Callbacks: _MenuDispatchCallbacks, LastFire: _MenuDispatchLastFire,
		Tokens: _MenuDispatchTokens, Clicks: _MenuDispatchClickSequences,
		Handles: _MenuDispatchOwnerHandles}
	ActionState := {Runs: []}
	ScheduleState := {Armed: []}
	NativeMenu := 0, ForeignMenu := 0, WriteOwner := 0
	try {
		; Keep inherited map identities untouched, including detached registrations.
		_MenuDispatchCallbacks := _MenuDispatchCallbacks.Clone()
		_MenuDispatchLastFire := _MenuDispatchLastFire.Clone()
		_MenuDispatchTokens := _MenuDispatchTokens.Clone()
		_MenuDispatchClickSequences := _MenuDispatchClickSequences.Clone()
		_MenuDispatchOwnerHandles := _MenuDispatchOwnerHandles.Clone()
		NativeMenu := Menu(), ForeignMenu := Menu()
		OwnedCommand := _MCDR_Command.Bind(ActionState)
		AssertEqual(1, RegisterMenuItem(NativeMenu, "owned", OwnedCommand),
			"the actual dispatcher must allocate a tracked native item")
		AssertEqual(1, RegisterMenuItem(ForeignMenu, "foreign", NoAction),
			"an independent detached native registration must stay live")
		NativeId := _MenuItemIdAtPosition(NativeMenu, 0)
		ForeignId := _MenuItemIdAtPosition(ForeignMenu, 0)
		AssertTrue(NativeId > 0 && ForeignId > 0 && NativeId != ForeignId)
		Identity := {ItemId: NativeId, Token: _MenuDispatchTokens[NativeId]}
		ForeignToken := _MenuDispatchTokens[ForeignId]
		ForeignCallback := _MenuDispatchCallbacks[ForeignId]
		LeasePath := A_Temp . "\ergopti-menu-registration-" . A_ScriptHwnd . ".toml"
		WriteOwner := _ConfigWriteLeaseTryAcquire(LeasePath, "menu-registration-test")
		AssertTrue(WriteOwner is Object, "the actual config writer must own the busy admission")
		Fixture := {NativeMenu: NativeMenu, Identity: Identity, Command: OwnedCommand,
			Action: ActionState, Schedule: ScheduleState, Lease: WriteOwner}
		Body.Call(Fixture)
		AssertTrue(_MenuDispatchTokens.Has(ForeignId))
		AssertEqual(ForeignToken, _MenuDispatchTokens[ForeignId], "retirement must preserve the foreign token")
		AssertTrue(_MenuDispatchCallbacks[ForeignId] == ForeignCallback,
			"retirement must preserve the foreign command identity")
	} finally {
		; Release retained retry Args before native rows, while exact menus stay owned.
		ScheduleState.Armed := []
		try {
			if WriteOwner is Object
				_ConfigWriteLeaseRelease(WriteOwner)
			if NativeMenu is Menu {
				NativeMenu.Delete()
				MenuDispatcher_PruneMenu(NativeMenu)
			}
			if ForeignMenu is Menu {
				ForeignMenu.Delete()
				MenuDispatcher_PruneMenu(ForeignMenu)
			}
		} finally {
			_MenuDispatchCallbacks := SavedDispatch.Callbacks
			_MenuDispatchLastFire := SavedDispatch.LastFire
			_MenuDispatchTokens := SavedDispatch.Tokens
			_MenuDispatchClickSequences := SavedDispatch.Clicks
			_MenuDispatchOwnerHandles := SavedDispatch.Handles
		}
	}
}

_MCDR_Queue(Fixture, Args) {
	AssertEqual("", MenuCommandRun(Fixture.Command, Args, 0, 0,
		_MCDR_Arm.Bind(Fixture.Schedule), Fixture.Identity), "a real busy lease defers the actual command")
	AssertEqual(0, Fixture.Action.Runs.Length, "admission has no command effects")
	AssertEqual(1, Fixture.Schedule.Armed.Length, "one real retry callback is retained")
}

_MCDR_Retire(Fixture) {
	global _MenuDispatchTokens
	Fixture.NativeMenu.Delete()
	MenuDispatcher_PruneMenu(Fixture.NativeMenu)
	AssertFalse(_MenuDispatchTokens.Has(Fixture.Identity.ItemId),
		"the actual prune owner must retire the deleted native item")
}

_MCDR_RetiredBody(Fixture) {
	_MCDR_Queue(Fixture, ["owned", 1, Fixture.NativeMenu])
	_MCDR_Retire(Fixture)
	AssertTrue(_ConfigWriteLeaseRelease(Fixture.Lease))
	_MCDR_Drain(Fixture.Schedule)
	AssertEqual(0, Fixture.Action.Runs.Length, "a busy then retired native registration cannot execute after the writer ends")
	AssertEqual(0, Fixture.Schedule.Armed.Length)
}
_MCDR_Retired() {
	_MCDR_Run(_MCDR_RetiredBody)
}
Test("menu registration deferral: actual busy then retired native item refuses the drain", _MCDR_Retired)

_MCDR_LiveBody(Fixture) {
	_MCDR_Queue(Fixture, ["owned", 1, Fixture.NativeMenu])
	AssertTrue(_ConfigWriteLeaseRelease(Fixture.Lease))
	_MCDR_Drain(Fixture.Schedule)
	AssertEqual(1, Fixture.Action.Runs.Length, "a live native registration still executes exactly once")
	AssertEqual("owned", Fixture.Action.Runs[1].Name)
	AssertEqual(1, Fixture.Action.Runs[1].Position)
	AssertEqual(Fixture.NativeMenu.Handle, Fixture.Action.Runs[1].Third)
	AssertEqual(0, Fixture.Schedule.Armed.Length)
}
_MCDR_Live() {
	_MCDR_Run(_MCDR_LiveBody)
}
Test("menu registration deferral: actual live item preserves native arguments after a real write", _MCDR_Live)

_MCDR_BypassBody(Fixture) {
	_MCDR_Queue(Fixture, ["", 0, 0])
	AssertTrue(_ConfigWriteLeaseRelease(Fixture.Lease))
	_MCDR_Drain(Fixture.Schedule)
	AssertEqual(1, Fixture.Action.Runs.Length, "a healthy fallback registration is not lost")
	AssertEqual("", Fixture.Action.Runs[1].Name)
	AssertEqual(0, Fixture.Action.Runs[1].Position)
	AssertEqual(0, Fixture.Action.Runs[1].Third, "bypass third argument remains the exact Integer zero")
}
_MCDR_Bypass() {
	_MCDR_Run(_MCDR_BypassBody)
}
Test("menu registration deferral: live bypass preserves its zero menu argument", _MCDR_Bypass)

_MCDR_MutableBody(Fixture) {
	global _MenuDispatchTokens
	_MCDR_Queue(Fixture, ["owned", 1, 0])
	_MCDR_Retire(Fixture)
	AssertEqual(1, RegisterMenuItem(Fixture.NativeMenu, "replacement", NoAction))
	ReplacementId := _MenuItemIdAtPosition(Fixture.NativeMenu, 0)
	AssertTrue(_MenuDispatchTokens[ReplacementId] != Fixture.Identity.Token,
		"a replacement allocates a distinct canonical token even if its native ID is recycled")
	Fixture.Identity.ItemId := ReplacementId
	Fixture.Identity.Token := _MenuDispatchTokens[ReplacementId]
	AssertTrue(_ConfigWriteLeaseRelease(Fixture.Lease))
	_MCDR_Drain(Fixture.Schedule)
	AssertEqual(0, Fixture.Action.Runs.Length, "mutating the supplied receipt cannot absolve the retired original request")
}
_MCDR_Mutable() {
	_MCDR_Run(_MCDR_MutableBody)
}
Test("menu registration deferral: a later live receipt cannot replace the accepted identity", _MCDR_Mutable)

_MCDR_RearmedBody(Fixture) {
	_MCDR_Queue(Fixture, ["owned", 1, 0])
	_MCDR_Drain(Fixture.Schedule)
	AssertEqual(0, Fixture.Action.Runs.Length, "the genuinely held writer still prevents action")
	AssertEqual(1, Fixture.Schedule.Armed.Length, "the real retry owner rearms exactly once")
	_MCDR_Retire(Fixture)
	AssertTrue(_ConfigWriteLeaseRelease(Fixture.Lease))
	_MCDR_Drain(Fixture.Schedule)
	AssertEqual(0, Fixture.Action.Runs.Length, "every successive retry carries the original registration")
}
_MCDR_Rearmed() {
	_MCDR_Run(_MCDR_RearmedBody)
}
Test("menu registration deferral: registration survives repeated busy checks before retirement", _MCDR_Rearmed)

_MCDR_RevokeDuringRead(Fixture) {
	_MCDR_Retire(Fixture)
	return ConfigWriteLeaseBusy()
}
_MCDR_CalloutBody(Fixture) {
	AssertTrue(_ConfigWriteLeaseRelease(Fixture.Lease))
	AssertEqual(false, MenuCommandRun(Fixture.Command, ["owned", 1, 0], 0,
		_MCDR_RevokeDuringRead.Bind(Fixture), _MCDR_Arm.Bind(Fixture.Schedule), Fixture.Identity))
	AssertEqual(0, Fixture.Action.Runs.Length, "a yielding readiness port cannot retire the item and then publish its action")
	AssertEqual(0, Fixture.Schedule.Armed.Length)
}
_MCDR_Callout() {
	_MCDR_Run(_MCDR_CalloutBody)
}
Test("menu registration deferral: final admission rechecks actual retirement during readiness", _MCDR_Callout)





; ====================================================
; ====================================================
; ======= 3/ Startup Native Registration Retry =======
; ====================================================
; ====================================================

/** Records scheduling while delegating to the real native timer. */
_MCDS_ArmStartup(StartupTrace, StartupCallback, StartupDelay) {
	StartupTrace.Timers.Push(StartupCallback)
	SetTimer(StartupCallback, StartupDelay)
}

/** Observes the actual base drain without replacing its dispatch. */
class _MCDS_ObservedStartup extends MenuStartupCommands {
	__New(StartupTrace) {
		this.Trace := StartupTrace
		super.__New(() => StartupTrace.Ready, _MCDS_ArmStartup.Bind(StartupTrace))
	}

	Drain(Entries, Generation, *) {
		this.Trace.DrainCalls += 1
		try return super.Drain(Entries, Generation)
		finally this.Trace.DrainReturns += 1
	}
}

_MCDS_Wait(StartupCondition, StartupDiagnostic) {
	StartupDeadline := A_TickCount + 3000
	while !StartupCondition.Call() {
		if A_TickCount >= StartupDeadline
			throw Error(StartupDiagnostic)
		Sleep(1)
	}
}

_MCDS_ObserveWindow(StartupTrace, *) {
	StartupTrace.WindowObserved := true
}

_MCDS_WriterRetryBody(RetireItem, Fixture) {
	global _MenuStartupCommands, _TrayStartupCommands, _SuspendPending
	global _MenuDispatchTokens, MENU_COMMAND_DEFERRAL_RETRY_MS
	SavedStartup := _MenuStartupCommands
	HadTrayStartup := IsSet(_TrayStartupCommands)
	SavedTrayStartup := HadTrayStartup ? _TrayStartupCommands : false
	HadSuspendPending := IsSet(_SuspendPending)
	SavedSuspendPending := HadSuspendPending ? _SuspendPending : false
	StartupCritical := Critical("On")
	StartupTrace := {Ready: false, DrainCalls: 0, DrainReturns: 0, Timers: [], WindowObserved: false}
	StartupOwner := _MCDS_ObservedStartup(StartupTrace)
	WindowCallback := _MCDS_ObserveWindow.Bind(StartupTrace)
	try {
		_MenuStartupCommands := StartupOwner
		_TrayStartupCommands := false
		_SuspendPending := false
		AssertTrue(StartupOwner.Retain(Fixture.Command, ["owned", 1, Fixture.NativeMenu], Fixture.Identity))
		AssertEqual(1, StartupOwner.Pending.Length)
		AssertEqual(Fixture.Identity.ItemId, StartupOwner.Pending[1].Identity.ItemId)
		AssertEqual(Fixture.Identity.Token, StartupOwner.Pending[1].Identity.Token)
		AssertEqual(0, Fixture.Action.Runs.Length)
		StartupTrace.Ready := true
		AssertTrue(StartupOwner.NotifyReady())
		AssertFalse(StartupOwner.NotifyReady(), "readiness must not schedule the accepted selection twice")
		AssertEqual(1, StartupTrace.Timers.Length, "one actual startup SetTimer is owned")
		Critical("Off")
		_MCDS_Wait(() => StartupTrace.DrainReturns == 1, "the native startup timer must execute the actual drain")
		AssertEqual(1, StartupTrace.DrainCalls)
		AssertTrue(ConfigWriteLeaseBusy(), "the genuine writer still owns retry admission after startup drains")
		AssertEqual(0, Fixture.Action.Runs.Length, "startup must reach a real busy writer without calling the command")
		if RetireItem
			_MCDR_Retire(Fixture)
		AssertTrue(_ConfigWriteLeaseRelease(Fixture.Lease))
		; Observe a real message-loop window after the already armed native retry.
		; The live sibling must actually fire, preventing a dropped-timer false green.
		SetTimer(WindowCallback, -2 * MENU_COMMAND_DEFERRAL_RETRY_MS)
		_MCDS_Wait(() => StartupTrace.WindowObserved, "the native retry observation timer must actually fire")
		if RetireItem {
			AssertEqual(0, Fixture.Action.Runs.Length,
				"startup identity must survive the writer retry and refuse the actually retired native item")
			AssertFalse(_MenuDispatchTokens.Has(Fixture.Identity.ItemId))
		} else {
			AssertEqual(1, Fixture.Action.Runs.Length, "a live startup selection must execute exactly once through the actual writer retry")
			AssertEqual("owned", Fixture.Action.Runs[1].Name)
			AssertEqual(1, Fixture.Action.Runs[1].Position)
			AssertEqual(Fixture.NativeMenu.Handle, Fixture.Action.Runs[1].Third)
			AssertEqual(Fixture.Identity.Token, _MenuDispatchTokens[Fixture.Identity.ItemId])
		}
		AssertEqual(1, StartupTrace.DrainReturns)
		AssertEqual(0, StartupOwner.Pending.Length)
	} finally {
		Critical("On")
		StartupOwner.Cancel()
		for StartupCallback in StartupTrace.Timers
			SetTimer(StartupCallback, 0)
		SetTimer(WindowCallback, 0)
		; Retire the exact item before releasing the real writer, including failures.
		if _MenuDispatchTokens.Has(Fixture.Identity.ItemId)
			_MCDR_Retire(Fixture)
		_ConfigWriteLeaseRelease(Fixture.Lease)
		StartupTrace.WindowObserved := false
		SetTimer(WindowCallback, -2 * MENU_COMMAND_DEFERRAL_RETRY_MS)
		Critical("Off")
		try _MCDS_Wait(() => StartupTrace.WindowObserved, "owned timer cleanup must pump before native fixture maps are restored")
		finally {
			Critical("On")
			SetTimer(WindowCallback, 0)
			_MenuStartupCommands := SavedStartup
			_TrayStartupCommands := HadTrayStartup ? SavedTrayStartup : unset
			_SuspendPending := HadSuspendPending ? SavedSuspendPending : unset
			Critical(StartupCritical)
		}
	}
}

_MCDS_WriterRetry(RetireItem) {
	_MCDR_Run(_MCDS_WriterRetryBody.Bind(RetireItem))
}
Test("menu startup registration: real startup and writer timers refuse an item retired during the write",
	_MCDS_WriterRetry.Bind(true))
Test("menu startup registration: real startup and writer timers execute the live native selection exactly once",
	_MCDS_WriterRetry.Bind(false))
