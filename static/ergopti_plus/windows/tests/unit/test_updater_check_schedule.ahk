; static/ergopti_plus/windows/tests/unit/test_updater_check_schedule.ahk

; ==============================================================================
; MODULE: Updater Check Schedule Tests
; DESCRIPTION:
; The background update check follows the persisted check record
; (last_check_at, failures, seed, last_notified_tag in the Storage port), not the
; process start. The driver used to fire a check min(30 s, interval) after
; every boot and count the interval from there, so a machine powered off every
; evening checked at each boot even on a weekly setting, a Reload re-checked at
; once, and the last notified release lived in memory only, so every restart
; announced the same release again.
;
; The Storage port and the wall clock are injected (_UpdaterCheckStateStore,
; _UpdaterClockFn); the timer scheduler is the injected ScheduleFn the cadence
; tests already use. The harness runs from source, so a due tick never reaches
; the network (_Updater_BackgroundMayDispatch refuses a source run): the tests
; observe the decision through the delay the tick re-arms with.
; ==============================================================================

; An in-memory Storage port recording every write.
_UCSch_Store(Initial := "") {
	Store := { Values: Map(), Writes: 0 }
	if (Initial is Map)
		Store.Values[UpdateSchedule_Timing()["state_storage_key"]] := Initial
	Store.Port := Map(
		"read", (Key) => Store.Values.Get(Key, ""),
		"write", (Key, Value) => (Store.Writes += 1, Store.Values[Key] := Value, true))
	return Store
}

; Every updater test that arms the cadence (here, in test_updater.ahk and in the
; admission tests) loads the check record; without this suite-wide store it
; would read, and seed, the real HKCU Storage key of the driver running on the
; same machine. Assigned at include time, before RunTests starts any test.
global _UpdaterCheckStateStore := _UCSch_Store().Port

_UCSch_SuiteUsesAnInMemoryRecord() {
	global _UpdaterCheckStateStore
	AssertTrue(_UpdaterCheckStateStore is Map, "the suite must never touch the real Storage port")
	AssertTrue(HasMethod(_UpdaterCheckStateStore["read"], "Call")
		&& HasMethod(_UpdaterCheckStateStore["write"], "Call"), "the suite store reads and writes")
}
Test("Updater schedule: the suite runs over an in-memory check record", _UCSch_SuiteUsesAnInMemoryRecord)

_UCSch_Record(Store) {
	return Store.Values.Get(UpdateSchedule_Timing()["state_storage_key"], "")
}

_UCSch_Schedule(State, TimerFn, DelayMs) {
	State.Calls += 1
	if (DelayMs == 0) {
		Loop State.Pending.Length {
			if ObjPtr(State.Pending[A_Index]) == ObjPtr(TimerFn) {
				State.Pending.RemoveAt(A_Index)
				break
			}
		}
		return true
	}
	; The cadence arms negative one-shots; the tests read the delay of each arm.
	State.Delays.Push(Abs(DelayMs))
	State.Pending.Push(TimerFn)
	return true
}

; Runs Body with an isolated schedule: the given record, clock and start time.
_UCSch_With(Record, Now, StartedAt, Interval, Body) {
	global _UpdaterCheckStateStore, _UpdaterClockFn, _UpdaterCheckState
	global _UpdaterStartedAt, UPDATER_CHECK_INTERVAL, UPDATER_LAST_NOTIFIED_TAG
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Saved := { Store: _UpdaterCheckStateStore, Clock: _UpdaterClockFn,
		State: _UpdaterCheckState, StartedAt: _UpdaterStartedAt,
		Interval: UPDATER_CHECK_INTERVAL, Notified: UPDATER_LAST_NOTIFIED_TAG }
	HadFn := IsSet(_UpdaterBackgroundFn)
	if HadFn
		SavedFn := _UpdaterBackgroundFn
	SavedOwner := _UpdaterBackgroundOwner
	Store := _UCSch_Store(Record)
	Clock := { Now: Now }
	try {
		try Updater_StopBackgroundChecks(false)
		_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := 0
		_UpdaterCheckStateStore := Store.Port
		_UpdaterClockFn := () => Clock.Now
		_UpdaterCheckState := 0
		_UpdaterStartedAt := StartedAt
		UPDATER_CHECK_INTERVAL := Interval
		Body.Call(Store, Clock)
	} finally {
		try Updater_StopBackgroundChecks(false)
		_UpdaterCheckStateStore := Saved.Store
		_UpdaterClockFn := Saved.Clock
		_UpdaterCheckState := Saved.State
		_UpdaterStartedAt := Saved.StartedAt
		UPDATER_CHECK_INTERVAL := Saved.Interval
		UPDATER_LAST_NOTIFIED_TAG := Saved.Notified
		if HadFn
			_UpdaterBackgroundFn := SavedFn
		else
			_UpdaterBackgroundFn := unset
		_UpdaterBackgroundOwner := SavedOwner
	}
}

; A restart in the middle of the interval arms for the persisted due time
; (bounded by the re-evaluation period), never for a boot check.
_UCSch_RestartMidIntervalDoesNotCheckAtBoot() {
	Body(Store, Clock) {
		Decision := _Updater_ScheduleDecision()
		AssertEqual(false, Decision.Due, "a check done an hour ago is not due at boot")
		AssertEqual("scheduled", Decision.Reason)
		AssertTrue(Decision.DueAt >= 1700000000 + 86400, "the next check follows the persisted one")
		Timer := { Calls: 0, Delays: [], Pending: [] }
		AssertEqual(true, Updater_StartBackgroundChecks(_UCSch_Schedule.Bind(Timer), false))
		AssertEqual(1, Timer.Delays.Length, "Start arms one timer")
		AssertEqual(UpdateSchedule_Timing()["reevaluate_sec"] * 1000, Timer.Delays[1],
			"a far due time is re-evaluated after the bounded period, not after 30 s")
	}
	_UCSch_With(Map("seed", "7f3a9c21e5b04d68", "last_check_at", 1700000000, "failures", 0),
		1700003600, 1700003600, 86400, Body)
}
Test("Updater schedule: a restart mid-interval arms for the persisted due time", _UCSch_RestartMidIntervalDoesNotCheckAtBoot)

; A machine off past its due time catches up once the boot delay has passed.
_UCSch_OverdueCatchesUpAfterTheBootDelay() {
	Body(Store, Clock) {
		Timer := { Calls: 0, Delays: [], Pending: [] }
		AssertEqual(true, Updater_StartBackgroundChecks(_UCSch_Schedule.Bind(Timer), false))
		AssertEqual(UpdateSchedule_Timing()["boot_check_delay_sec"] * 1000, Timer.Delays[1],
			"an overdue weekly check runs after the boot delay")
		Clock.Now += UpdateSchedule_Timing()["boot_check_delay_sec"]
		Decision := _Updater_ScheduleDecision()
		AssertEqual(true, Decision.Due, "the overdue check is due once the boot delay passed")
		AssertEqual("catch_up", Decision.Reason)
		Tick := Timer.Pending.RemoveAt(1)
		Tick.Call()
		AssertEqual(UpdateSchedule_Timing()["reevaluate_sec"] * 1000, Timer.Delays[Timer.Delays.Length],
			"a due tick re-evaluates after the bounded period; the completion moves the next due time")
		AssertEqual(1, Timer.Pending.Length, "the loop keeps exactly one armed timer")
	}
	_UCSch_With(Map("seed", "7f3a9c21e5b04d68", "last_check_at", 1700000000, "failures", 0),
		1700000000 + 10 * 86400, 1700000000 + 10 * 86400, 604800, Body)
}
Test("Updater schedule: an overdue check catches up after the boot delay", _UCSch_OverdueCatchesUpAfterTheBootDelay)

; A fresh install creates and persists its seed, and checks after the boot delay.
_UCSch_FreshInstallSeedsTheRecord() {
	Body(Store, Clock) {
		Decision := _Updater_ScheduleDecision()
		AssertEqual("first_check", Decision.Reason)
		Record := _UCSch_Record(Store)
		AssertTrue(Record is Map, "the record is created")
		AssertTrue(Record.Has("seed") && StrLen(Record["seed"]) == 16, "a 16-hex install seed is persisted")
		AssertEqual(false, Record.Has("last_check_at"), "no check is recorded before one ran")
	}
	_UCSch_With("", 1700000000, 1700000000, 86400, Body)
}
Test("Updater schedule: a fresh install persists its seed and waits for the boot delay", _UCSch_FreshInstallSeedsTheRecord)

; A completed background check is recorded: a failure backs off, a success
; resets the failures and records the time.
_UCSch_CompletionRecordsTheCheck() {
	Body(Store, Clock) {
		global UPDATER_REQUEST_ORIGIN_BACKGROUND
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		_Updater_HandleBackgroundResult("", "0.0.0-dev.200", Request)
		Record := _UCSch_Record(Store)
		AssertEqual(Clock.Now, Record["last_check_at"], "a failed check is recorded")
		AssertEqual(1, Record["failures"], "a failed check counts one failure")
		AssertEqual(false, Record.Has("last_success_at"), "a failure is not a success")
		Decision := _Updater_ScheduleDecision()
		AssertEqual("retry_after_failure", Decision.Reason, "a failure retries on the shared backoff")
		AssertEqual(Clock.Now + UpdateSchedule_Timing()["failure_backoff_sec"][1], Decision.DueAt)

		Clock.Now += 400
		Latest := '{"tag_name":"v0.0.0-dev.150","body":"","html_url":"https://github.com/adrienm7/ergopti/releases/tag/v0.0.0-dev.150","published_at":"2026-09-01T00:00:00Z","prerelease":true}'
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		_Updater_HandleBackgroundResult(Latest, "0.0.0-dev.200", Request)
		Record := _UCSch_Record(Store)
		AssertEqual(Clock.Now, Record["last_check_at"], "a successful check is recorded")
		AssertEqual(Clock.Now, Record["last_success_at"])
		AssertEqual(0, Record["failures"], "a success resets the failures")
		AssertEqual("7f3a9c21e5b04d68", Record["seed"], "the seed survives every record")
	}
	_UCSch_With(Map("seed", "7f3a9c21e5b04d68"), 1700000000, 1699990000, 86400, Body)
}
Test("Updater schedule: a completed background check updates the persisted record", _UCSch_CompletionRecordsTheCheck)

; The notified release survives a restart: the reservation refuses a release
; announced in a previous session.
_UCSch_NotifiedTagSurvivesARestart() {
	Body(Store, Clock) {
		global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_LAST_NOTIFIED_TAG
		UPDATER_LAST_NOTIFIED_TAG := ""
		_Updater_CheckState()
		AssertEqual("v0.0.0-dev.180", UPDATER_LAST_NOTIFIED_TAG, "the notified tag is restored at load")
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND, false)
		AssertEqual(0, _Updater_TryReserveReleaseNotification(Request, "v0.0.0-dev.180"),
			"a release announced before the restart is not announced again")
		_Updater_RecordNotifiedTag("v0.0.0-dev.181")
		AssertEqual("v0.0.0-dev.181", _UCSch_Record(Store)["last_notified_tag"], "a new announcement is persisted")
		AssertEqual(1700000000, _UCSch_Record(Store)["last_check_at"], "recording the tag keeps the schedule")
	}
	_UCSch_With(Map("seed", "7f3a9c21e5b04d68", "last_check_at", 1700000000, "last_notified_tag", "v0.0.0-dev.180"),
		1700000100, 1700000100, 86400, Body)
}
Test("Updater schedule: the notified release is persisted across restarts", _UCSch_NotifiedTagSurvivesARestart)

; A wake re-evaluates the armed timer at once: the machine may have slept
; through a due check, and a timer counts no sleep.
_UCSch_WakeRearmsTheTimer() {
	Body(Store, Clock) {
		global _UpdaterStartedAt
		Timer := { Calls: 0, Delays: [], Pending: [] }
		AssertEqual(true, Updater_StartBackgroundChecks(_UCSch_Schedule.Bind(Timer), false))
		OldTick := Timer.Pending[1]
		Clock.Now += 2 * 86400
		AssertEqual(true, _Updater_ReevaluateAfterWake(), "a wake re-arms the live owner")
		AssertEqual(Clock.Now, _UpdaterStartedAt, "the boot delay restarts at the wake")
		AssertEqual(1, Timer.Pending.Length, "the superseded timer is disarmed")
		Assert(ObjPtr(Timer.Pending[1]) != ObjPtr(OldTick), "the wake armed a new timer")
		AssertEqual(UpdateSchedule_Timing()["boot_check_delay_sec"] * 1000, Timer.Delays[Timer.Delays.Length],
			"the overdue check runs once the network had the boot delay to come back")
		AssertEqual(false, OldTick.Call(), "the superseded timer is inert")
	}
	_UCSch_With(Map("seed", "7f3a9c21e5b04d68", "last_check_at", 1700000000), 1700003600, 1700003600, 86400, Body)
}
Test("Updater schedule: a wake re-evaluates the armed timer", _UCSch_WakeRearmsTheTimer)

; Only a resume notification re-evaluates; the handler itself does no work.
_UCSch_PowerBroadcastFiltersResume() {
	global UPDATER_PBT_APMRESUMEAUTOMATIC, UPDATER_PBT_APMRESUMESUSPEND
	Calls := { Count: 0 }
	Fn := () => (Calls.Count += 1)
	_Updater_OnPowerBroadcast(0x4, 0, 0x218, 0, Fn)
	AssertEqual(0, Calls.Count, "a suspend notice does not re-evaluate")
	_Updater_OnPowerBroadcast(UPDATER_PBT_APMRESUMEAUTOMATIC, 0, 0x218, 0, Fn)
	_Updater_OnPowerBroadcast(UPDATER_PBT_APMRESUMESUSPEND, 0, 0x218, 0, Fn)
	AssertEqual(2, Calls.Count, "both resume notices defer one re-evaluation")
}
Test("Updater schedule: only a resume broadcast defers a re-evaluation", _UCSch_PowerBroadcastFiltersResume)
