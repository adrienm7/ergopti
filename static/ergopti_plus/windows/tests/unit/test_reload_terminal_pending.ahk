; tests/unit/test_reload_terminal_pending.ahk

; ==============================================================================
; MODULE: Reload Terminal Pending Contract Tests
; DESCRIPTION:
; Pins the measured AutoHotkey v2.0.26 behaviour of a reload: launching the
; successor returns in the same tick, and OnExit(reason "Reload") runs only
; later, once the successor has loaded and asks this instance to close. The
; hand-off used to read that return as a refusal, cancel its record and report
; failure on every successful reload (reload-returns-pending). Every way a
; launched reload can end is driven here through a fake successor port: the
; accepted OnExit, a successor that dies while loading, an OnExit veto, a launch
; that raises, and an ordinary exit that supersedes the reload.
; ==============================================================================

#Requires AutoHotkey v2.0

global _RTP_Events := []
global RTP_FAKE_SUCCESSOR_PID := 4242





; ==================================
; ==================================
; ======= 1/ Shared fixtures =======
; ==================================
; ==================================

_RTP_Record(Kind, Result := 1, *) {
	global _RTP_Events
	_RTP_Events.Push(Kind)
	return Result
}

; A fake successor port: liveness, termination and timers are driven by the
; test instead of the OS and the message loop.
_RTP_NewPort() {
	Probe := Map("alive", true, "terminated", 0, "closed", 0, "armed", [],
		"now", 1000, "terminate_result", true, "terminate_throw", false,
		"alive_throw", false, "delivery_throw", false)
	return Map(
		"probe", Probe,
		"alive", _RTP_PortAlive.Bind(Probe),
		"terminate", _RTP_PortTerminate.Bind(Probe),
		"close", _RTP_PortClose.Bind(Probe),
		"arm", _RTP_PortArm.Bind(Probe),
		"now", () => Probe["now"])
}

_RTP_PortTerminate(Probe, Successor) {
	Probe["terminated"] += 1
	if Probe["terminate_throw"]
		throw Error("Injected native termination failure.")
	return Probe["terminate_result"]
}

_RTP_PortAlive(Probe, Successor) {
	if Probe["alive_throw"]
		throw Error("Injected native liveness failure.")
	return Probe["alive"]
}

_RTP_PortClose(Probe, Successor) {
	Probe["closed"] += 1
	return true
}

_RTP_PortArm(Probe, Callback, DelayMs) {
	if DelayMs == 1 && Probe["delivery_throw"]
		throw Error("Injected deferred callback arming failure.")
	Probe["armed"].Push(Map("fn", Callback, "ms", DelayMs))
}

; Runs every callback armed so far, as the message loop would.
_RTP_RunArmed(Port) {
	Armed := Port["probe"]["armed"]
	Port["probe"]["armed"] := []
	for Entry in Armed
		Entry["fn"].Call()
	return Armed.Length
}

; Models the real launcher: the successor process starts and the call returns
; at once, long before the successor asks this instance to close.
_RTP_LaunchReturnsAtOnce(*) {
	global _RTP_Events, RTP_FAKE_SUCCESSOR_PID
	_RTP_Events.Push("launch")
	return Map("pid", RTP_FAKE_SUCCESSOR_PID)
}

_RTP_LaunchRaises(*) {
	global _RTP_Events
	_RTP_Events.Push("launch")
	throw Error("injected launch failure")
}

; Launches a fake successor through the real hand-off and returns the pending
; record, as every production caller reaches it.
_RTP_Pending(Bundle, Port, SuccessFn := 0, CommitFn := 0, AbortFn := 0,
		RefusedFn := 0, ReleaseFn := 0, RetractFn := 0) {
	AssertTrue(ReloadTerminalInvoke(Bundle, SuccessFn, _RTP_LaunchReturnsAtOnce,
		Port, CommitFn, AbortFn, RefusedFn, ReleaseFn, RetractFn),
		"a launched successor is a pending success, not a refusal")
	Record := ReloadTerminalHandoffPending()
	AssertTrue(Record is Map, "the launched reload must stay pending")
	return Record
}

; Withdraws whatever record a failed assertion left behind.
_RTP_Cleanup(Bundle) {
	global _ReloadTerminalHandoff, _ReloadTerminalRetirements
	Records := []
	if (_ReloadTerminalHandoff is Map) && _ReloadTerminalHandoff["bundle"] == Bundle
		Records.Push(_ReloadTerminalHandoff)
	for Id, Record in _ReloadTerminalRetirements {
		if Record["bundle"] == Bundle && !((_ReloadTerminalHandoff is Map) && _ReloadTerminalHandoff == Record)
			Records.Push(Record)
	}
	for Record in Records {
		if Record["state"] == "authorized"
			ReloadTerminalHandoffCancel(Record)
		else {
			Port := Record["port"]
			AssertTrue(Port.Get("probe", 0) is Map, "Direct cleanup must own its data-only successor model.")
			Port["probe"]["alive_throw"] := false
			Port["probe"]["delivery_throw"] := false
			Port["probe"]["alive"] := false
			if Record["state"] != "stopping" && Record["state"] != "refusal_ready" && Record["state"] != "abandon_ready"
				ReloadTerminalHandoffRefuse(Record, "direct test cleanup")
			loop 4
				_RTP_RunArmed(Port)
			if Record["state"] == "abandon_ready"
				ReloadTerminalHandoffAbandon(Record, "direct test cleanup")
		}
		AssertFalse(_ReloadTerminalHandoffOwns(Record), "Cleanup cannot release a still-owned successor or callback.")
	}
	_ConfigWriteTerminalRelease(Bundle)
}

_RTP_Join(Items) {
	Out := ""
	for Item in Items
		Out .= (Out == "" ? "" : ",") . Item
	return Out
}

_RTP_Acquire(Slug) {
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\reload-pending-" . Slug . ".toml"])
	AssertTrue(Bundle is Object, "the test must own a terminal bundle")
	return Bundle
}





; ======================================
; ======================================
; ======= 2/ The accepted reload =======
; ======================================
; ======================================

_RTP_LaunchReturnIsPendingSuccess() {
	global _RTP_Events
	_RTP_Events := []
	Bundle := _RTP_Acquire("success")
	Port := _RTP_NewPort()
	try {
		Record := _RTP_Pending(Bundle, Port, _RTP_Record.Bind("success"),
			_RTP_Record.Bind("commit"), _RTP_Record.Bind("abort"),
			_RTP_Record.Bind("refused"), _RTP_Record.Bind("release"))
		AssertEqual("launch", _RTP_Join(_RTP_Events),
			"nothing but the launch may run before OnExit")
		AssertEqual(1, Port["probe"]["armed"].Length,
			"a pending reload must watch its successor")
		AssertTrue(_ConfigWriteTerminalIsActive(),
			"the pending reload keeps the configuration barrier until OnExit")
		AssertEqual(1, _RTP_RunArmed(Port))
		AssertEqual(Record, ReloadTerminalHandoffPending(),
			"a live successor that has not asked yet keeps the reload pending")
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertEqual(Record, Claimed,
			"the later OnExit(Reload) must claim the pending record")
		AssertTrue(ReloadTerminalHandoffCommit(Claimed),
			"the terminal commit must run from OnExit")
		AssertTrue(ReloadTerminalHandoffFinish(Claimed),
			"the accepted reload must report success from OnExit")
		AssertEqual("launch,commit,success", _RTP_Join(_RTP_Events),
			"a successful reload commits then succeeds, never aborts or refuses")
		AssertEqual(0, Port["probe"]["terminated"],
			"an accepted reload must never stop its successor")
		AssertEqual(1, _RTP_RunArmed(Port))
		AssertEqual(0, Port["probe"]["armed"].Length,
			"a probe that finds the record finished must stop")
	} finally _RTP_Cleanup(Bundle)
}
Test("reload terminal: a returned launch is pending success until OnExit "
	. "(reload-returns-pending)", _RTP_LaunchReturnIsPendingSuccess)

_RTP_OnlyALaunchedSuccessorCanBeClaimed() {
	Bundle := _RTP_Acquire("claim")
	Port := _RTP_NewPort()
	try {
		Record := ReloadTerminalHandoffPrepare(Bundle)
		AssertTrue(Record is Map)
		AssertFalse(ReloadTerminalHandoffClaim("Reload"),
			"no successor was launched, so no close request can be ours")
		AssertTrue(ReloadTerminalHandoffCancel(Record))
		Record := _RTP_Pending(Bundle, Port)
		AssertFalse(ReloadTerminalHandoffClaim("Exit"),
			"an ordinary exit must not borrow the pending reload")
		AssertEqual("pending", Record["state"])
		AssertEqual(Record, ReloadTerminalHandoffClaim("Reload"))
		AssertFalse(ReloadTerminalHandoffClaim("Reload"),
			"the pending record may be claimed only once")
	} finally _RTP_Cleanup(Bundle)
}
Test("reload terminal: only a launched successor's Reload can claim "
	. "(reload-returns-pending)", _RTP_OnlyALaunchedSuccessorCanBeClaimed)





; ================================================
; ================================================
; ======= 3/ Refusals hand the bundle back =======
; ================================================
; ================================================

_RTP_LaunchFailureLeavesTheCallerOwner() {
	global _RTP_Events
	_RTP_Events := []
	Bundle := _RTP_Acquire("launch-failure")
	Port := _RTP_NewPort()
	try {
		AssertFalse(ReloadTerminalInvoke(Bundle, _RTP_Record.Bind("success"),
			_RTP_LaunchRaises, Port, _RTP_Record.Bind("commit"),
			_RTP_Record.Bind("abort"), _RTP_Record.Bind("refused"),
			_RTP_Record.Bind("release")),
			"a launch that raised launched nothing")
		AssertEqual("launch,abort", _RTP_Join(_RTP_Events),
			"the caller's synchronous branch owns rollback and release")
		AssertFalse(ReloadTerminalHandoffPending())
		AssertEqual(0, Port["probe"]["armed"].Length)
	} finally _RTP_Cleanup(Bundle)
}
Test("reload terminal: a raised launch refuses synchronously "
	. "(reload-launch-failure)", _RTP_LaunchFailureLeavesTheCallerOwner)

_RTP_SuccessorExitRefusesTheReload() {
	global _RTP_Events
	_RTP_Events := []
	Bundle := _RTP_Acquire("successor-exit")
	Port := _RTP_NewPort()
	try {
		_RTP_Pending(Bundle, Port, _RTP_Record.Bind("success"),
			_RTP_Record.Bind("commit"), _RTP_Record.Bind("abort"),
			_RTP_Record.Bind("refused"), _RTP_Record.Bind("release"))
		Port["probe"]["alive"] := false
		AssertEqual(1, _RTP_RunArmed(Port), "one probe was armed")
		AssertFalse(ReloadTerminalHandoffPending(),
			"a successor that died loading must end the pending reload")
		AssertEqual("launch,abort", _RTP_Join(_RTP_Events),
			"pause intent is retracted before the caller hears of it")
		AssertEqual(1, _RTP_RunArmed(Port),
			"the refusal is delivered on the next thread")
		AssertEqual("launch,abort,refused,release", _RTP_Join(_RTP_Events),
			"the caller's refusal callback runs before the bundle release")
		AssertEqual(0, Port["probe"]["terminated"],
			"a successor that already exited must not be terminated")
		AssertEqual(1, Port["probe"]["closed"])
		AssertFalse(ReloadTerminalHandoffClaim("Reload"))
	} finally _RTP_Cleanup(Bundle)
}
Test("reload terminal: a successor that exits before asking refuses "
	. "(reload-successor-exit)", _RTP_SuccessorExitRefusesTheReload)

; A veto after the terminal commit (the updater's FinalExit, swap and recovery
; gates run later in OnExit) also retracts the pause intent that commit
; published, or the next start re-pauses a driver whose reload never happened
; (reload-refusal-retracts-marker).
_RTP_OnExitVetoStopsTheWaitingSuccessor() {
	global _RTP_Events
	for Stage in ["pending", "claimed", "committed", "commit_failed"] {
		_RTP_Events := []
		Bundle := _RTP_Acquire("veto-" . Stage)
		Port := _RTP_NewPort()
		try {
			_RTP_Pending(Bundle, Port, _RTP_Record.Bind("success"),
				_RTP_Record.Bind("commit", Stage == "commit_failed" ? 0 : 1),
				_RTP_Record.Bind("abort"), _RTP_Record.Bind("refused"),
				_RTP_Record.Bind("release"), _RTP_Record.Bind("retract"))
			if (Stage != "pending") {
				Claimed := ReloadTerminalHandoffClaim("Reload")
				AssertTrue(Claimed is Map)
				if (Stage == "committed")
					AssertTrue(ReloadTerminalHandoffCommit(Claimed))
				if (Stage == "commit_failed")
					AssertFalse(ReloadTerminalHandoffCommit(Claimed))
			}
			AssertFalse(ReloadTerminalHandoffRefuseForShutdown("Exit", "gate"),
				Stage . ": a vetoed ordinary exit leaves the reload pending")
			AssertTrue(ReloadTerminalHandoffRefuseForShutdown("Reload", "gate"),
				Stage . ": a vetoed Reload close request refuses the reload")
			AssertEqual(1, Port["probe"]["terminated"],
				Stage . ": the successor waiting on this window must be stopped")
			AssertEqual(0, Port["probe"]["closed"], "No close occurs on the termination request alone.")
			Port["probe"]["alive"] := false
			_RTP_RunArmed(Port)
			_RTP_RunArmed(Port)
			Expected := (Stage == "committed" || Stage == "commit_failed")
				? "launch,commit,abort,retract,refused,release"
				: "launch,abort,refused,release"
			AssertEqual(Expected, _RTP_Join(_RTP_Events),
				Stage . ": a veto never reports success, retracts only what the commit may have published, and hands the bundle back")
			AssertFalse(ReloadTerminalHandoffPending())
		} finally _RTP_Cleanup(Bundle)
	}
}
Test("reload terminal: an OnExit veto stops the successor and hands back "
	. "(reload-onexit-veto)", _RTP_OnExitVetoStopsTheWaitingSuccessor)

_RTP_ExitSupersedesThePendingReload() {
	global _RTP_Events
	_RTP_Events := []
	Bundle := _RTP_Acquire("superseded")
	Port := _RTP_NewPort()
	try {
		Record := _RTP_Pending(Bundle, Port, _RTP_Record.Bind("success"),
			_RTP_Record.Bind("commit"), _RTP_Record.Bind("abort"),
			_RTP_Record.Bind("refused"), _RTP_Record.Bind("release"))
		AssertFalse(ReloadTerminalHandoffAbandon(Record, "Exit"), "A request cannot acknowledge a still-live process.")
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		AssertTrue(ReloadTerminalHandoffAbandon(Record, "Exit"))
		AssertEqual(1, Port["probe"]["terminated"],
			"an accepted exit must stop the successor it supersedes")
		AssertEqual("launch,abort", _RTP_Join(_RTP_Events),
			"an exit keeps the committed configuration and rolls nothing back")
		AssertFalse(ReloadTerminalHandoffPending())
		AssertEqual(0, _RTP_RunArmed(Port))
		AssertEqual(0, Port["probe"]["armed"].Length,
			"the physical stop poll already drained the stale pending probe")
		AssertEqual(1, Port["probe"]["closed"])
	} finally _RTP_Cleanup(Bundle)
}
Test("reload terminal: an accepted exit supersedes the pending reload "
	. "(reload-superseded-by-exit)", _RTP_ExitSupersedesThePendingReload)

_RTP_StalledSuccessorIsReportedOnceAndKept() {
	global RELOAD_SUCCESSOR_STALL_MS
	Bundle := _RTP_Acquire("stall")
	Port := _RTP_NewPort()
	try {
		Record := _RTP_Pending(Bundle, Port)
		Port["probe"]["now"] += RELOAD_SUCCESSOR_STALL_MS
		_RTP_RunArmed(Port)
		AssertTrue(Record["stall_reported"],
			"a successor silent past the stall bound must be reported")
		AssertEqual(Record, ReloadTerminalHandoffPending(),
			"a live successor is never killed: its close request may be queued")
		AssertEqual(0, Port["probe"]["terminated"])
		AssertEqual(1, Port["probe"]["armed"].Length,
			"the probe keeps watching the stalled successor")
	} finally _RTP_Cleanup(Bundle)
}
Test("reload terminal: a stalled successor is reported, not killed "
	. "(reload-successor-stall)", _RTP_StalledSuccessorIsReportedOnceAndKept)





; ===============================================
; ===============================================
; ======= 4/ The real successor port owns =======
; ===============================================
; ===============================================

; The production port against a real child process: it must see it alive,
; stop exactly it, and then see it gone through the same owned handle.
_RTP_RealPortOwnsTheSuccessorProcess() {
	PowerShell := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
	Successor := ReloadSuccessorLaunch('"' . PowerShell
		. '" -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"',
		A_Temp, "Hide")
	try {
		AssertTrue(Successor["pid"] > 0 && Successor["handle"] != 0,
			"the launcher must return the successor's pid and an owned handle")
		Port := ReloadSuccessorPort()
		AssertTrue(Port["alive"].Call(Successor),
			"a running successor must probe alive")
		AssertTrue(Port["terminate"].Call(Successor),
			"the port must stop the exact successor")
		AssertEqual(0, PLC_WaitHandle(Successor["handle"], 5000),
			"termination must end the owned process")
		AssertFalse(Port["alive"].Call(Successor),
			"an exited successor must probe dead through the same handle")
	} finally {
		if Successor["handle"] && PLC_WaitHandle(Successor["handle"], 0) != 0
			ReloadSuccessorTerminate(Successor)
		ReloadSuccessorClose(Successor)
	}
	AssertEqual(0, Successor["handle"], "closing must retire the handle slot")
}
Test("reload terminal: the real successor port owns the process "
	. "(reload-successor-port)", _RTP_RealPortOwnsTheSuccessorProcess)





; =====================================
; =====================================
; ======= 5/ Who tells the user =======
; =====================================
; =====================================

; The generic "reload refused" notice once fired on every late refusal: on top
; of the reset dialog, the paths editor and onboarding errors, and once per
; updater recovery retry (reload-refusal-notice-owner). A caller that gives a
; refusal callback owns what the user is told; only one without gets the notice.
_RTP_RefusalNoticeOnlyWithoutACallerCallback() {
	global _RTP_Events
	_RTP_Events := []
	Notice := _RTP_Record.Bind("notice")
	ReloadRefusalDeliver(0, "vetoed", Notice)
	AssertEqual("notice", _RTP_Join(_RTP_Events),
		"a refusal nobody else reports must reach the user once")
	_RTP_Events := []
	loop 3
		ReloadRefusalDeliver(_RTP_Record.Bind("retry"), "vetoed", Notice)
	AssertEqual("retry,retry,retry", _RTP_Join(_RTP_Events),
		"a caller with its own refusal path (dialog, retry) must not get the generic notice on top")
	; The lifecycle entry delivers through this owner, and the language switch,
	; whose own callback only logs, still tells the user.
	Lifecycle := _DriverFuncBody("_ReloadPreservingSuspendRefused")
	AssertTrue(InStr(Lifecycle, "ReloadRefusalDeliver(CallerRefusedFn, Reason)") > 0
		and !InStr(Lifecycle, "NotifierSend("),
		"ReloadPreservingSuspend must deliver late refusals through ReloadRefusalDeliver")
	AssertTrue(InStr(_DriverFuncBody("_I18nReloadRefused"), "ReloadRefusedNotify()") > 0,
		"a refused language switch must still reach the user")
}
Test("reload terminal: the generic refusal notice is only for callers without "
	. "their own (reload-refusal-notice-owner)", _RTP_RefusalNoticeOnlyWithoutACallerCallback)
