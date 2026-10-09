; infra/reload_terminal_handoff.ahk

; ==============================================================================
; MODULE: Reload Terminal Hand-off
; DESCRIPTION:
; Bridges an authorized global configuration-transition bundle across a Reload.
; Launching the successor returns in the same tick (measured on AutoHotkey
; v2.0.26): OnExit runs with reason "Reload" only later, once the successor has
; loaded and asks this instance to close. A launched record is therefore
; PENDING. It owns the bundle until OnExit claims it, publishes durable intent
; and reports success. A refusal is only ever a real event: the launch raised,
; an OnExit gate vetoed the successor's close request, or the successor exited
; without asking. It is then delivered to the caller, who takes the bundle back.
; ==============================================================================

#Requires AutoHotkey v2.0

; Period of the successor liveness probe while a reload is pending. It only has
; to notice a successor that died while loading (a syntax error, a missing
; include); a successor that loads normally asks to close within about a second.
global RELOAD_SUCCESSOR_POLL_MS := 500

; A successor that has neither asked this instance to close nor exited after
; this long is reported once. It is not killed: its close request may already be
; queued behind the probe, and terminating it then would leave no driver at all.
global RELOAD_SUCCESSOR_STALL_MS := 15000





; =====================================
; =====================================
; ======= 1/ Terminal ownership =======
; =====================================
; =====================================

global _ReloadTerminalHandoff := false
global _ReloadTerminalHandoffNextId := 0
global _ReloadTerminalRetirements := Map()

ReloadTerminalHandoffPrepare(Bundle, SuccessFn := 0, CommitFn := 0,
		AbortFn := 0, RefusedFn := 0, ReleaseFn := 0, RetractFn := 0) {
	global _ReloadTerminalHandoff, _ReloadTerminalHandoffNextId, _ReloadTerminalRetirements
	if !(Bundle is Object)
		return false
	for Callback in [SuccessFn, CommitFn, AbortFn, RefusedFn, ReleaseFn, RetractFn] {
		if !((Callback is Integer) && Callback == 0) && !HasMethod(Callback, "Call")
			return false
	}
	if !_ConfigWriteTerminalAuthorize(Bundle)
		return false
	PreviousCritical := Critical("On")
	try {
		if (_ReloadTerminalHandoff is Map) || _ReloadTerminalRetirements.Count
			return false
		_ReloadTerminalHandoffNextId += 1
		Record := Map("id", _ReloadTerminalHandoffNextId, "bundle", Bundle,
			"success", SuccessFn, "commit", CommitFn, "abort", AbortFn,
			"refused", RefusedFn, "release", ReleaseFn, "retract", RetractFn,
			"port", 0, "successor", 0, "launch_tick", 0,
			"stall_reported", false, "probe_failure_reported", false,
			"state", "authorized", "stop_mode", "", "stop_origin", "",
			"stop_reason", "", "stop_requested", false, "stop_request_ok", false,
			"stop_acknowledged", false, "stop_busy", false,
			"stop_deferred", false,
			"stop_watch_armed", false, "stop_error_reported", false,
			"stop_probe_reported", false, "compensation_done", false,
			"compensation_ok", false, "resume_exit", 0, "resume_armed", false,
			"delivery_armed", false, "delivery_done", false,
			"close_attempted", false, "close_acknowledged", false)
		_ReloadTerminalHandoff := Record
		return Record
	} finally Critical(PreviousCritical)
}

; Only a launched successor can send the close request that runs OnExit with
; reason "Reload", so only a pending record is claimable.
ReloadTerminalHandoffClaim(ExitReason) {
	global _ReloadTerminalHandoff
	if !(ExitReason is String)
			|| StrCompare(ExitReason, "Reload", true) != 0
		return false
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
			return false
		Record := _ReloadTerminalHandoff
		if (Record["state"] != "pending")
			return false
		if !_ConfigWriteTerminalClaimShutdown(Record["bundle"])
			return false
		Record["state"] := "claimed"
		return Record
	} finally Critical(PreviousCritical)
}

; Executes the only refusal-capable terminal callback. Keeping this separate
; from Finish lets OnExit publish durable transition authority before it tears
; down the last live OS hooks, while still deferring UI success until teardown
; has completed.
ReloadTerminalHandoffCommit(Record) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffCommitNonCritical(Record)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffCommitNonCritical(Record) {
	global _ReloadTerminalHandoff
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "claimed"
			return false
		Record["state"] := "committing"
	} finally Critical(PreviousCritical)
	CommitOk := true
	try {
		CommitFn := Record["commit"]
		if HasMethod(CommitFn, "Call") {
			CommitResult := CommitFn.Call()
			CommitOk := (CommitResult is Integer) && CommitResult == 1
		}
	} catch as Err {
		CommitOk := false
		try LoggerError("Lifecycle",
			"Reload terminal commit failed: {1}.", Err.Message)
	}
	if !CommitOk {
		PreviousCritical := Critical("On")
		try {
			if (_ReloadTerminalHandoff is Map)
					&& (_ReloadTerminalHandoff == Record)
				Record["state"] := "commit_failed"
		} finally Critical(PreviousCritical)
		return false
	}
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "committing"
			return false
		Record["state"] := "committed"
	} finally Critical(PreviousCritical)
	return true
}

ReloadTerminalHandoffFinish(Record, BeforeSuccessFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffFinishNonCritical(Record, BeforeSuccessFn)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffFinishNonCritical(Record, BeforeSuccessFn) {
	global _ReloadTerminalHandoff
	if !((BeforeSuccessFn is Integer) && BeforeSuccessFn == 0)
			&& !HasMethod(BeforeSuccessFn, "Call")
		return false
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
			return false
		State := Record["state"]
	} finally Critical(PreviousCritical)
	; Tests and non-OnExit clients may use Finish as the complete terminal seam.
	; The live OnExit path commits explicitly before destructive teardown.
	if (State == "claimed") {
		if !ReloadTerminalHandoffCommit(Record)
			return false
	} else if (State != "committed")
		return false
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "committed"
			return false
		; All validation that may refuse happens before the teardown callback.
		; Clearing the global makes the accepted record terminal and single-use.
		Record["state"] := "finishing"
		_ReloadTerminalHandoff := false
	} finally Critical(PreviousCritical)
	try {
		if HasMethod(BeforeSuccessFn, "Call")
			BeforeSuccessFn.Call()
	} catch as Err {
		try LoggerError("Lifecycle",
			"Reload terminal teardown callback failed after acceptance: {1}.",
			Err.Message)
	}
	Record["state"] := "finished"
	try {
		SuccessFn := Record["success"]
		if HasMethod(SuccessFn, "Call")
			SuccessFn.Call()
	} catch as Err {
		try LoggerError("Lifecycle",
			"Reload terminal callback failed after every refusal gate accepted: {1}.",
			Err.Message)
	}
	return true
}

; Withdraws a record whose successor was never launched. The caller still owns
; the bundle and runs its own refusal branch; a launched record is withdrawn
; through ReloadTerminalHandoffRefuse instead.
ReloadTerminalHandoffCancel(Record) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffCancelNonCritical(Record)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffCancelNonCritical(Record) {
	global _ReloadTerminalHandoff
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map) || (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "authorized"
				|| _ReloadTerminalSuccessorValid(Record["successor"])
			return false
		Record["state"] := "canceling"
	} finally Critical(PreviousCritical)
	AbortOk := _ReloadTerminalHandoffRunAbort(Record)
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map) || (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "canceling"
			return false
		if !_ConfigWriteTerminalCancelShutdown(Record["bundle"]) {
			Record["state"] := "cancel_failed"
			return false
		}
		Record["state"] := AbortOk ? "canceled" : "cancel_failed"
		_ReloadTerminalHandoff := false
		return AbortOk
	} finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffRunAbort(Record) {
	AbortFn := Record["abort"]
	if !HasMethod(AbortFn, "Call")
		return true
	try {
		AbortResult := AbortFn.Call()
		return (AbortResult is Integer) && AbortResult == 1
	} catch as Err {
		try LoggerError("Lifecycle",
			"Reload terminal abort failed: {1}.", Err.Message)
		return false
	}
}





; ====================================
; ====================================
; ======= 2/ Pending successor =======
; ====================================
; ====================================

; Launches the successor and leaves the record pending. True means the reload
; is under way: the caller must neither release nor roll back Bundle, because
; durable commit, teardown and SuccessFn run later from OnExit. A refusal after
; this point reaches RefusedFn(Reason) and then ReleaseFn; one that follows the
; terminal commit first runs RetractFn, which withdraws what CommitFn published.
; False means no successor was launched and the caller still owns Bundle.
;
; Port is a Map of the OS seams: alive(Successor) -> Boolean,
; terminate(Successor) -> Boolean, close(Successor), arm(Callback, DelayMs) for
; one-shot timers, and now() -> tick count. LaunchFn returns the successor, a
; Map holding at least its positive "pid".
ReloadTerminalInvoke(Bundle, SuccessFn, LaunchFn, Port, CommitFn := 0,
		AbortFn := 0, RefusedFn := 0, ReleaseFn := 0, RetractFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalInvokeNonCritical(Bundle, SuccessFn, LaunchFn,
		Port, CommitFn, AbortFn, RefusedFn, ReleaseFn, RetractFn)
	finally Critical(PreviousCritical)
}

_ReloadTerminalInvokeNonCritical(Bundle, SuccessFn, LaunchFn, Port, CommitFn,
		AbortFn, RefusedFn, ReleaseFn, RetractFn) {
	global _ReloadTerminalHandoff, _ReloadTerminalRetirements
	if !HasMethod(LaunchFn, "Call")
		throw TypeError("Reload terminal hand-off requires a successor launcher.")
	_ReloadTerminalRequirePort(Port)
	Record := ReloadTerminalHandoffPrepare(Bundle, SuccessFn, CommitFn, AbortFn,
		RefusedFn, ReleaseFn, RetractFn)
	if !(Record is Map)
		return false
	PreviousCritical := Critical("On")
	try {
		Record["port"] := Port
		; Cancel cannot give the bundle back while native creation may be yielding.
		Record["state"] := "launching"
	} finally Critical(PreviousCritical)
	try {
		Successor := LaunchFn.Call()
		if !_ReloadTerminalSuccessorValid(Successor)
			throw ValueError("the launcher returned no successor process")
	} catch as Err {
		PreviousCritical := Critical("On")
		try {
			if (_ReloadTerminalHandoff is Map) && (_ReloadTerminalHandoff == Record)
					&& Record["state"] == "launching"
				Record["state"] := "authorized"
		} finally Critical(PreviousCritical)
		ReloadTerminalHandoffCancel(Record)
		try LoggerError("Lifecycle", "Reload successor launch failed: {1}.", Err.Message)
		return false
	}
	; From here the caller must not roll back or release its bundle on false.
	; Even failed publication owns a real process until the same port proves exit.
	Published := false
	PreviousCritical := Critical("On")
	try {
		Record["successor"] := Successor
		if (_ReloadTerminalHandoff is Map) && (_ReloadTerminalHandoff == Record)
				&& Record["state"] == "launching" {
			Record["state"] := "pending"
			Published := true
		} else {
			_ReloadTerminalRetirements[Record["id"]] := Record
			Record["state"] := "pending"
		}
	} finally Critical(PreviousCritical)
	if !Published {
		ReloadTerminalHandoffRefuse(Record,
			"the reload record changed while its successor launched")
		return true
	}
	try Record["launch_tick"] := Port["now"].Call()
	catch as Err {
		ReloadTerminalHandoffRefuse(Record,
			"the successor launch clock failed: " . Err.Message)
		return true
	}
	try LoggerInfo("Lifecycle", "Reload successor pid {1} launched; this instance closes when it asks.", Successor["pid"])
	_ReloadTerminalHandoffArmWatch(Record)
	return true
}

; Returns the pending record, or false when no launched reload awaits OnExit.
ReloadTerminalHandoffPending() {
	global _ReloadTerminalHandoff
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
			return false
		Record := _ReloadTerminalHandoff
		return (Record["state"] == "pending"
			|| (Record["state"] == "stopping" && Record["stop_mode"] == "abandon")
			|| Record["state"] == "abandon_ready") ? Record : false
	} finally Critical(PreviousCritical)
}

; Whether a reload hand-off exists, from its authorization to its terminal. A
; successor may then be loading: no detached worker starts meanwhile, because
; one would share the driver's window title with it (LifecycleRetireWorkers).
; A record whose claim could not be rearmed stays published for good and has
; no successor, so it does not count.
ReloadTerminalHandoffActive() {
	global _ReloadTerminalHandoff, _ReloadTerminalRetirements
	PreviousCritical := Critical("On")
	try return _ReloadTerminalRetirements.Count > 0
		|| ((_ReloadTerminalHandoff is Map) && _ReloadTerminalHandoff["state"] != "cancel_failed")
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffArmWatch(Record) {
	global RELOAD_SUCCESSOR_POLL_MS
	try Record["port"]["arm"].Call(_ReloadTerminalHandoffWatch.Bind(Record),
		RELOAD_SUCCESSOR_POLL_MS)
	catch as Err
		try LoggerError("Lifecycle",
			"Reload successor probe could not be armed: {1}. A successor that dies while loading keeps the configuration barrier.",
			Err.Message)
}

; One liveness probe. A successor that exited without asking this instance to
; close failed to load, so the reload is refused and handed back.
_ReloadTerminalHandoffWatch(Record, *) {
	global _ReloadTerminalHandoff, RELOAD_SUCCESSOR_STALL_MS
	PreviousCritical := Critical("On")
	try {
		if !(_ReloadTerminalHandoff is Map)
				|| (_ReloadTerminalHandoff != Record)
				|| Record["state"] != "pending"
			return false
	} finally Critical(PreviousCritical)
	Port := Record["port"]
	Successor := Record["successor"]
	try Alive := Port["alive"].Call(Successor)
	catch as Err {
		if !Record["probe_failure_reported"] {
			Record["probe_failure_reported"] := true
			try LoggerError("Lifecycle",
				"Reload successor pid {1} could not be probed: {2}.",
				Successor["pid"], Err.Message)
		}
		_ReloadTerminalHandoffArmWatch(Record)
		return false
	}
	if !Alive
		return ReloadTerminalHandoffRefuse(Record,
			"the successor exited without asking this instance to close")
	if !Record["stall_reported"] && TickExpired(Record["launch_tick"],
			RELOAD_SUCCESSOR_STALL_MS, Port["now"].Call()) {
		Record["stall_reported"] := true
		try LoggerError("Lifecycle",
			"Reload successor pid {1} has neither asked this instance to close nor exited after {2} ms; configuration writes stay blocked until it does.",
			Successor["pid"], RELOAD_SUCCESSOR_STALL_MS)
	}
	_ReloadTerminalHandoffArmWatch(Record)
	return true
}

; Withdraws a launched reload. The successor is stopped first, while this code
; still runs before any rollback, so no close request of its own can race the
; rollback. Pause intent is withdrawn here: AbortFn removes what was only
; prepared, and once the terminal commit may have published the live marker
; (a later OnExit gate vetoed: the updater's FinalExit, swap or recovery
; gates), RetractFn removes that marker too, or the next start would re-pause
; a driver whose reload never happened. The caller's RefusedFn and the bundle
; release run on the next thread because a refusal can surface inside OnExit,
; which must not block on caller UI.
ReloadTerminalHandoffRefuse(Record, Reason) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffRefuseNonCritical(Record, Reason)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffRefuseNonCritical(Record, Reason) {
	PreviousCritical := Critical("On")
	try {
		if !_ReloadTerminalHandoffOwns(Record)
			return false
		State := Record["state"]
		if State == "stopping" && Record["stop_mode"] == "refuse"
			return Record["stop_request_ok"]
		if !(State == "pending" || State == "claimed" || State == "committed" || State == "commit_failed")
			return false
		Record["stop_origin"] := State
		Record["stop_mode"] := "refuse"
		Record["stop_reason"] := Reason
		Record["state"] := "stopping"
	} finally Critical(PreviousCritical)
	_ReloadTerminalHandoffStopSuccessor(Record)
	; True acknowledges the withdrawal request, never physical termination.
	return Record["stop_acknowledged"] || Record["stop_request_ok"]
}

; Runs RetractFn after a refusal that followed the terminal commit.
_ReloadTerminalHandoffRunRetract(Record) {
	RetractFn := Record["retract"]
	if !HasMethod(RetractFn, "Call")
		return true
	try {
		RetractResult := RetractFn.Call()
		Retracted := (RetractResult is Integer) && RetractResult == 1
	} catch as Err {
		Retracted := false
		try LoggerError("Lifecycle", "Reload retraction raised: {1}.", Err.Message)
	}
	if !Retracted
		try LoggerError("Lifecycle",
			"The pause intent published for the refused reload could not be retracted; the next start restores the pause.")
	return Retracted
}

_ReloadTerminalHandoffDeliverRefusal(Record, Reason, *) {
	PreviousCritical := Critical("On")
	try {
		if !_ReloadTerminalHandoffOwns(Record) || Record["state"] != "refusal_ready"
				|| !Record["stop_acknowledged"] || Record["delivery_done"]
			return false
		if !_ConfigWriteTerminalCancelShutdown(Record["bundle"]) {
			Record["state"] := "rearm_failed"
			return false
		}
		Record["delivery_done"] := true
		Record["state"] := "refused"
		_ReloadTerminalHandoffReleaseOwner(Record)
	} finally Critical(PreviousCritical)
	RefusedFn := Record["refused"]
	if HasMethod(RefusedFn, "Call") {
		try RefusedFn.Call(Reason)
		catch as Err
			try LoggerError("Lifecycle", "Reload refusal callback failed: {1}.", Err.Message)
	}
	ReleaseFn := Record["release"]
	if HasMethod(ReleaseFn, "Call") {
		try ReleaseFn.Call()
		catch as Err
			try LoggerError("Lifecycle", "Reload refusal bundle release failed: {1}.", Err.Message)
	}
	if !_ReloadTerminalHandoffCloseSuccessor(Record)
		_ReloadTerminalHandoffRetainCloseDebt(Record)
	return true
}

; An ordinary exit accepted while the successor is still loading supersedes the
; reload: the user asked this process to end, not to be replaced. OnExit calls
; this only after every refusal gate accepted, so the successor is stopped only
; when this process is certainly exiting. Nothing is rolled back: the committed
; configuration stays on disk for the next start.
ReloadTerminalHandoffAbandon(Record, ExitReason) {
	PreviousCritical := Critical("Off")
	try {
		if !ReloadTerminalHandoffPrepareAbandon(Record, ExitReason)
			return false
		PreviousOwnershipCritical := Critical("On")
		try {
			if !_ReloadTerminalHandoffOwns(Record) || Record["state"] != "abandon_ready"
					|| !Record["stop_acknowledged"]
				return false
			Record["state"] := "abandoned"
			_ReloadTerminalHandoffReleaseOwner(Record)
		} finally Critical(PreviousOwnershipCritical)
		Closed := _ReloadTerminalHandoffCloseSuccessor(Record)
		if !Closed
			_ReloadTerminalHandoffRetainCloseDebt(Record)
		try LoggerInfo("Lifecycle", "Exit reason '{1}' superseded the pending reload.", ExitReason)
		return Closed
	} finally Critical(PreviousCritical)
}

; OnExit vetoed a close request. When it came from the successor of a pending
; reload, that successor now waits on this window and would prompt "Could not
; close the previous instance"; refusing the record stops it and hands the
; transition back to its caller.
ReloadTerminalHandoffRefuseForShutdown(ExitReason, Gate) {
	global _ReloadTerminalHandoff
	if !(ExitReason is String) || StrCompare(ExitReason, "Reload", true) != 0
		return false
	PreviousCritical := Critical("On")
	try Record := _ReloadTerminalHandoff
	finally Critical(PreviousCritical)
	if !(Record is Map)
		return false
	return ReloadTerminalHandoffRefuse(Record,
		"an OnExit gate refused the close request (" . Gate . ")")
}

_ReloadTerminalHandoffStopSuccessor(Record) {
	PreviousCritical := Critical("On")
	try {
		if !_ReloadTerminalHandoffOwns(Record) || Record["state"] != "stopping" || Record["stop_busy"]
			return false
		Record["stop_busy"] := true
	} finally Critical(PreviousCritical)
	try {
		Successor := Record["successor"]
		if !_ReloadTerminalSuccessorValid(Successor)
			throw Error("A stopping reload must retain its exact successor descriptor.")
		Port := Record["port"]
		Alive := _ReloadTerminalHandoffProbeStop(Record)
		if Alive && !Record["stop_requested"] {
			Record["stop_requested"] := true
			try {
				Result := Port["terminate"].Call(Successor)
				Record["stop_request_ok"] := (Result is Integer) && Result == 1
			} catch as Err {
				Record["stop_request_ok"] := false
				_ReloadTerminalHandoffStopError(Record, "termination raised: " . Err.Message)
			}
			if !Record["stop_request_ok"]
				_ReloadTerminalHandoffStopError(Record, "termination was not acknowledged")
			Alive := _ReloadTerminalHandoffProbeStop(Record)
		}
		if Alive {
			Record["stop_deferred"] := true
			_ReloadTerminalHandoffArmStopWatch(Record)
			return false
		}
		Record["stop_acknowledged"] := true
		try LoggerInfo("Lifecycle", "Stopped reload successor pid {1}.", Successor["pid"])
		_ReloadTerminalHandoffCompleteStop(Record)
		return true
	} catch as Err {
		Record["stop_deferred"] := true
		if !Record["stop_probe_reported"] {
			Record["stop_probe_reported"] := true
			try LoggerError("Lifecycle", "Reload successor native retirement remains owned: {1}.", Err.Message)
		}
		_ReloadTerminalHandoffArmStopWatch(Record)
		return false
	} finally {
		PreviousCritical := Critical("On")
		try Record["stop_busy"] := false
		finally Critical(PreviousCritical)
	}
}

_ReloadTerminalHandoffCloseSuccessor(Record) {
	if !Record["stop_acknowledged"] || Record["close_attempted"]
		return Record["close_acknowledged"]
	Record["close_attempted"] := true
	try {
		Closed := Record["port"]["close"].Call(Record["successor"])
		Record["close_acknowledged"] := (Closed is Integer) && Closed == 1
	} catch as Err {
		Record["close_acknowledged"] := false
		try LoggerError("Lifecycle", "Reload successor handle close raised: {1}.", Err.Message)
	}
	if !Record["close_acknowledged"]
		try LoggerError("Lifecycle", "Reload successor handle close remains unacknowledged; its owning record is retained.")
	return Record["close_acknowledged"]
}

_ReloadTerminalRequirePort(Port) {
	if !(Port is Map)
		throw TypeError("Reload terminal hand-off requires a successor port.")
	for Name in ["alive", "terminate", "close", "arm", "now"] {
		if !Port.Has(Name) || !HasMethod(Port[Name], "Call")
			throw TypeError("Reload terminal port lacks a callable '" . Name . "'.")
	}
}

_ReloadTerminalSuccessorValid(Successor) {
	return (Successor is Map) && Successor.Has("pid")
		&& (Successor["pid"] is Integer) && Successor["pid"] > 0
}





; =====================================
; =====================================
; ======= 3/ The refusal notice =======
; =====================================
; =====================================

; Delivers a late refusal to the caller that started the reload. A caller with
; its own refusal path owns what the user is told: its own dialog (the reset,
; the paths editor, onboarding, the LLM save) or a silent retry (the updater
; recovery, the layout poll), so the generic notice would stack on that dialog
; or repeat on every retry. Only a caller without one gets the generic notice.
; @param CallerRefusedFn {Func|Integer} The caller's RefusedFn(Reason), or 0.
; @param NotifyFn {Func|Integer} Notice sender; ReloadRefusedNotify by default.
ReloadRefusalDeliver(CallerRefusedFn, Reason, NotifyFn := 0) {
	if HasMethod(CallerRefusedFn, "Call")
		return CallerRefusedFn.Call(Reason)
	if !HasMethod(NotifyFn, "Call")
		NotifyFn := ReloadRefusedNotify
	NotifyFn.Call()
}

; Tells the user that a launched reload was refused: this instance keeps
; running on its previous in-memory settings.
ReloadRefusedNotify(*) {
	try NotifierSend(t("init.reload_refused_body"),
		Map("title", t("init.reload_refused_title"), "level", "error"))
}

ReloadTerminalHandoffPrepareAbandon(Record, ExitReason, ResumeFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ReloadTerminalHandoffPrepareAbandonNonCritical(Record, ExitReason, ResumeFn)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffPrepareAbandonNonCritical(Record, ExitReason, ResumeFn) {
	if !((ResumeFn is Integer) && ResumeFn == 0) && !HasMethod(ResumeFn, "Call")
		return false
	PreviousCritical := Critical("On")
	try {
		if !_ReloadTerminalHandoffOwns(Record)
			return false
		if Record["state"] == "abandon_ready"
			return true
		if Record["state"] == "pending" {
			Record["stop_origin"] := "pending"
			Record["stop_mode"] := "abandon"
			Record["stop_reason"] := ExitReason
			Record["resume_exit"] := ResumeFn
			Record["state"] := "stopping"
		} else if Record["state"] != "stopping" || Record["stop_mode"] != "abandon"
			return false
	} finally Critical(PreviousCritical)
	_ReloadTerminalHandoffStopSuccessor(Record)
	return Record["state"] == "abandon_ready"
}

_ReloadTerminalHandoffProbeStop(Record) {
	Alive := Record["port"]["alive"].Call(Record["successor"])
	if !(Alive is Integer) || !(Alive == 0 || Alive == 1)
		throw TypeError("The reload successor liveness port did not return a Boolean.")
	return Alive
}

_ReloadTerminalHandoffStopError(Record, Diagnostic) {
	if Record["stop_error_reported"]
		return
	Record["stop_error_reported"] := true
	try LoggerError("Lifecycle", "Reload successor pid {1} stop request failed: {2}; native ownership remains retained.",
		Record["successor"]["pid"], Diagnostic)
}

_ReloadTerminalHandoffArmStopWatch(Record) {
	global RELOAD_SUCCESSOR_POLL_MS
	if Record["stop_watch_armed"]
		return
	Record["stop_watch_armed"] := true
	try Record["port"]["arm"].Call(_ReloadTerminalHandoffStopWatch.Bind(Record), RELOAD_SUCCESSOR_POLL_MS)
	catch as Err {
		Record["stop_watch_armed"] := false
		try LoggerError("Lifecycle", "Reload retirement probe could not be armed: {1}; native ownership remains retained.", Err.Message)
	}
}

_ReloadTerminalHandoffStopWatch(Record, *) {
	Record["stop_watch_armed"] := false
	if !_ReloadTerminalHandoffOwns(Record)
		return false
	if Record["state"] == "stopping"
		return _ReloadTerminalHandoffStopSuccessor(Record)
	if Record["state"] == "refusal_ready"
		return _ReloadTerminalHandoffArmRefusal(Record)
	return false
}

_ReloadTerminalHandoffCompleteStop(Record) {
	if !Record["stop_acknowledged"] || Record["compensation_done"]
		return false
	Record["compensation_done"] := true
	AbortOk := _ReloadTerminalHandoffRunAbort(Record)
	RetractOk := Record["stop_mode"] == "refuse"
		&& (Record["stop_origin"] == "committed" || Record["stop_origin"] == "commit_failed")
		? _ReloadTerminalHandoffRunRetract(Record) : true
	Record["compensation_ok"] := AbortOk && RetractOk
	if !Record["compensation_ok"] {
		Record["state"] := "compensation_failed"
		return false
	}
	if Record["stop_mode"] == "abandon" {
		Record["state"] := "abandon_ready"
		ResumeFn := Record["resume_exit"]
		if HasMethod(ResumeFn, "Call") && Record["stop_deferred"] && !Record["resume_armed"] {
			Record["resume_armed"] := true
			try Record["port"]["arm"].Call(ResumeFn.Bind(Record), 1)
			catch as Err
				try LoggerError("Lifecycle", "The owned exit retry could not be armed: {1}.", Err.Message)
		}
		return true
	}
	Record["state"] := "refusal_ready"
	try LoggerError("Lifecycle", "Reload refused after launch: {1}.", Record["stop_reason"])
	return _ReloadTerminalHandoffArmRefusal(Record)
}

_ReloadTerminalHandoffArmRefusal(Record) {
	if Record["delivery_armed"]
		return true
	Record["delivery_armed"] := true
	try {
		Record["port"]["arm"].Call(_ReloadTerminalHandoffDeliverRefusal.Bind(Record, Record["stop_reason"]), 1)
		return true
	} catch as Err {
		Record["delivery_armed"] := false
		try LoggerError("Lifecycle", "Reload refusal delivery could not be deferred: {1}; its bundle remains owned.", Err.Message)
		_ReloadTerminalHandoffArmStopWatch(Record)
		return false
	}
}

_ReloadTerminalHandoffOwns(Record) {
	global _ReloadTerminalHandoff, _ReloadTerminalRetirements
	if !(Record is Map) || !Record.Has("id")
		return false
	PreviousCritical := Critical("On")
	try return ((_ReloadTerminalHandoff is Map) && _ReloadTerminalHandoff == Record)
		|| (_ReloadTerminalRetirements.Has(Record["id"]) && _ReloadTerminalRetirements[Record["id"]] == Record)
	finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffReleaseOwner(Record) {
	global _ReloadTerminalHandoff, _ReloadTerminalRetirements
	if (_ReloadTerminalHandoff is Map) && _ReloadTerminalHandoff == Record
		_ReloadTerminalHandoff := false
	if _ReloadTerminalRetirements.Has(Record["id"]) && _ReloadTerminalRetirements[Record["id"]] == Record
		_ReloadTerminalRetirements.Delete(Record["id"])
}

_ReloadTerminalHandoffRetainCloseDebt(Record) {
	global _ReloadTerminalRetirements
	PreviousCritical := Critical("On")
	try {
		Record["state"] := "close_failed"
		_ReloadTerminalRetirements[Record["id"]] := Record
	} finally Critical(PreviousCritical)
}

ReloadTerminalHandoffNativeStopPending() {
	global _ReloadTerminalHandoff, _ReloadTerminalRetirements
	PreviousCritical := Critical("On")
	try {
		if (_ReloadTerminalHandoff is Map) && _ReloadTerminalHandoffNativeStopDebt(_ReloadTerminalHandoff)
			return true
		for Id, Record in _ReloadTerminalRetirements {
			if (Record is Map) && Record.Has("id") && Record["id"] == Id
					&& _ReloadTerminalHandoffNativeStopDebt(Record)
				return true
		}
		return false
	} finally Critical(PreviousCritical)
}

_ReloadTerminalHandoffNativeStopDebt(Record) {
	if Record["stop_acknowledged"]
		return false
	; The exact launching reservation covers the interval before its descriptor
	; returns, while acquisition may already own a process inside the launcher.
	if Record["state"] == "launching"
		return true
	return _ReloadTerminalSuccessorValid(Record["successor"])
		&& (Record["state"] == "pending" || Record["state"] == "claimed"
			|| Record["state"] == "committed" || Record["state"] == "commit_failed"
			|| Record["state"] == "stopping")
}
