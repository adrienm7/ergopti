; tests/unit/infra/dispatch/test_timer_scheduler_lifetime.ahk

; ==============================================================================
; MODULE: TimerScheduler Callback Lifetime Tests
; DESCRIPTION:
; Real native timers own a callable destructor probe. Active and restartable
; handles retain it; terminal helpers drop every fixture edge before observing
; reclamation. No RSS measurement, garbage collection or SUT field clearing.
; ==============================================================================

#Requires AutoHotkey v2.0+

class _TSRL_Probe {
	__New(Ledger, Key) {
		this.Ledger := Ledger
		this.Key := Key
	}

	Call() {
		if A_IsCritical or A_IsSuspended {
			if !IsObject(this.Ledger["failure"])
				this.Ledger["failure"] := Error("The genuine timer callback must run outside Critical and suspension.")
			return
		}
		this.Ledger["calls"] += 1
	}

	__Delete() {
		this.Ledger[this.Key] += 1
	}
}

_TSRL_Ordinary(Ledger) {
	Probe := _TSRL_Probe(Ledger, "ordinary")
}

_TSRL_Log(Ledger, Line) {
	if InStr(Line, "ERROR") and !IsObject(Ledger["failure"])
		Ledger["failure"] := Error("A timer prerequisite logged an error: " . Line)
}

_TSRL_RequireHealthy(Ledger) {
	if IsObject(Ledger["failure"])
		throw Ledger["failure"]
	AssertFalse(A_IsCritical or A_IsSuspended,
		"native callback waits require an interruptible, unsuspended fixture")
}

_TSRL_Wait(Ledger, Needed) {
	_TSRL_RequireHealthy(Ledger)
	Started := A_TickCount
	while (Ledger["calls"] < Needed and A_TickCount - Started < 500) {
		Sleep(1)
		_TSRL_RequireHealthy(Ledger)
	}
	AssertTrue(Ledger["calls"] >= Needed,
		"the real native timer must deliver its callable before the bounded deadline")
}

_TSRL_AssertActive(Handle, Ledger) {
	global _TIMER_ADAPTER_REGISTRY
	AssertTrue(Handle is Map)
	Id := Handle["Id"]
	AssertTrue(_TIMER_ADAPTER_REGISTRY.Has(Id)
		and _TIMER_ADAPTER_REGISTRY[Id] == Handle,
		"the public native timer must publish the exact active handle")
	AssertEqual(0, Ledger["retired"],
		"active timer ownership must retain the callable probe")
	Ledger["active_retained"] := 1
	Ledger["id"] := Id
}

_TSRL_Cancel(Handle) {
	global _TIMER_ADAPTER_REGISTRY
	AssertTrue(TimerCancel(Handle),
		"the actual native cancellation must acknowledge exact callback retirement")
	AssertFalse(_TIMER_ADAPTER_REGISTRY.Has(Handle["Id"]),
		"the exact cancelled handle must leave the active registry")
}

_TSRL_Exercise(Ledger, Mode) {
	global _TIMER_ADAPTER_REGISTRY
	static RefusedCleanup := []
	Handle := 0
	Probe := 0
	Primary := 0
	try {
		; Admission and early cancellation share only a short RAM/native-timer
		; span. No timer delivery or wait is forced to run under Critical.
		PreviousCritical := Critical("On")
		try {
			Probe := _TSRL_Probe(Ledger, "retired")
			Handle := Mode == "every-cancel"
				? TimerEvery(0.001, Probe) : TimerAfter(0.001, Probe)
			Probe := 0
			_TSRL_AssertActive(Handle, Ledger)
			AssertEqual(0, Ledger["calls"])
			if Mode == "after-cancel" {
				_TSRL_Cancel(Handle)
				AssertEqual(0, Ledger["calls"],
					"native cancel before delivery cannot emit the user callback")
			}
		} finally Critical(PreviousCritical)

		if Mode != "after-cancel"
			_TSRL_Wait(Ledger, 1)
		_TSRL_RequireHealthy(Ledger)
		if Mode != "every-cancel" {
			AssertFalse(_TIMER_ADAPTER_REGISTRY.Has(Ledger["id"]),
				"the first one-shot must settle through delivery or cancellation")
			AssertEqual(0, Ledger["retired"],
				"a retained restartable handle must keep its original user callback")
			Needed := Ledger["calls"] + 1
			AssertTrue(TimerRestartAfter(Handle, 0.001) == Handle,
				"the public restart must preserve its opaque handle")
			_TSRL_Wait(Ledger, Needed)
			AssertEqual(Needed, Ledger["calls"],
				"a restart after terminal delivery or cancel must really call the same probe once")
			Ledger["restart_delivered"] := 1
		}
		_TSRL_Cancel(Handle)
		Ledger["terminal_observed"] := 1
	} catch Any as Failure {
		Primary := Failure
	} finally {
		if Handle is Map {
			try _TSRL_Cancel(Handle)
			catch Any as CleanupFailure {
				; Preserve a refused native capability instead of silently dropping
				; it. A later case refuses foreign live registry ownership as well.
				RefusedCleanup.Push(Handle)
				if IsObject(Primary)
					Primary.Message .= " Native timer cleanup also failed: " . CleanupFailure.Message
				else
					Primary := CleanupFailure
			}
		}
		Probe := 0
		Handle := 0
	}
	if IsObject(Primary)
		throw Primary
}

_TSRL_Observe(Ledger, Mode) {
	global _TIMER_ADAPTER_REGISTRY
	_TSRL_Ordinary(Ledger)
	AssertEqual(1, Ledger["ordinary"],
		"an acyclic probe must release once after its helper returns")
	_TSRL_Exercise(Ledger, Mode)
	_TSRL_RequireHealthy(Ledger)
	AssertEqual(1, Ledger["active_retained"])
	AssertEqual(1, Ledger["terminal_observed"])
	AssertFalse(_TIMER_ADAPTER_REGISTRY.Has(Ledger["id"]))
	if Mode != "every-cancel"
		AssertEqual(1, Ledger["restart_delivered"])
	FileAppend("TIMER_LIFETIME_RECEIPT mode=" . Mode
		. " ordinary=" . Ledger["ordinary"]
		. " active=" . Ledger["active_retained"]
		. " calls=" . Ledger["calls"]
		. " terminal=" . Ledger["terminal_observed"]
		. " restart=" . Ledger["restart_delivered"]
		. " retired_deleted=" . Ledger["retired"] . "`n", "*")
	AssertEqual(1, Ledger["retired"],
		"a settled timer must release its callable once after all fixture handle/probe references leave scope")
}

_TSRL_Case(Mode) {
	global _TIMER_ADAPTER_REGISTRY
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	Ledger := Map("ordinary", 0, "retired", 0, "calls", 0, "failure", 0,
		"active_retained", 0, "terminal_observed", 0, "restart_delivered", 0, "id", 0)
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	try {
		AssertFalse(A_IsSuspended, "native timer lifetime tests require an unsuspended process")
		AssertEqual(0, _TIMER_ADAPTER_REGISTRY.Count,
			"the fixture must not cancel or park foreign native timers")
		AssertFalse(SavedLogger.FlushActive,
			"a foreign logger flush cannot be detached by a timer lifetime test")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := _TSRL_Log.Bind(Ledger), _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Critical("Off")
		_TSRL_Observe(Ledger, Mode)
	} finally {
		Critical("On")
		try {
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			for Name, Saved in SavedOptional
				%Name% := Saved.Present ? Saved.Value : unset
		} finally Critical(PreviousCritical)
	}
}

Test("Timer lifetime: fired one-shot releases its callback after restart and drop "
	. "(timer-scheduler-record-lifetime)", _TSRL_Case.Bind("after-fire"))
Test("Timer lifetime: cancelled one-shot releases its callback after restart and drop "
	. "(timer-scheduler-record-lifetime)", _TSRL_Case.Bind("after-cancel"))
Test("Timer lifetime: cancelled repeating timer releases its callback after drop "
	. "(timer-scheduler-record-lifetime)", _TSRL_Case.Bind("every-cancel"))
