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
