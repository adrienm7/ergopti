; static/ergopti_plus/windows/tests/unit/test_keylogger_mouse_coordinates.ahk

_KMC_NewState() {
	return {
		prev_initialized: false,
		prev_x: 0,
		prev_y: 0,
		park_initialized: false,
		park_last_x: 0,
		park_last_y: 0,
		park_still_since: 0,
		park_fired: false,
		park_fired_x: 0,
		park_fired_y: 0,
		park_fired_at: 0
	}
}

_KMC_RecordEvent(Recorder, Event) {
	Recorder.Events.Push(Event)
}

_KMC_RecordDistance(Recorder, Distance) {
	Recorder.Distance += Distance
}

_KMC_Process(State, Recorder, X, Y, Tick, Suspended := false, Filtered := false, Initialized := true) {
	return _KL_Mouse_ProcessParkSample(
		State,
		X,
		Y,
		Tick,
		Suspended,
		Filtered,
		Initialized,
		_KMC_RecordEvent.Bind(Recorder),
		_KMC_RecordDistance.Bind(Recorder),
		"negative-monitor.exe"
	)
}

_KMC_NegativeCoordinatesAreOrdinarySamples() {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}

	_KMC_Process(State, Recorder, -1920, -240, 1000)
	_KMC_Process(State, Recorder, -1910, -240, 1250)
	AssertEqual(10, Recorder.Distance,
		"(ahk5-01-negative-mouse-coordinates) distance must accumulate while both samples remain on a negative-coordinate monitor")

	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, -1920, -240, 1000)
	_KMC_Process(State, Recorder, -1920, -240, 1000 + KLMouseConst.PARK_IDLE_MS + 1)
	AssertEqual(1, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) a negative-coordinate park must fire once after the idle threshold")
	AssertEqual(-1920, Recorder.Events[1]["x"])
	AssertEqual(-240, Recorder.Events[1]["y"])
	_KMC_Process(State, Recorder, -1920, -240, 1000 + (2 * KLMouseConst.PARK_IDLE_MS) + 2)
	AssertEqual(1, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) an unchanged parked cursor must not emit duplicate events")
}
Test("keylogger mouse: negative screen coordinates remain valid samples (ahk5-01-negative-mouse-coordinates)",
	_KMC_NegativeCoordinatesAreOrdinarySamples)

_KMC_InitializationDoesNotCollideWithRealCoordinates() {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, -9999, -9999, 500)
	_KMC_Process(State, Recorder, -9999, -9999, 500 + KLMouseConst.PARK_IDLE_MS + 1)
	AssertEqual(1, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) the former -9999 sentinel is a legal first park position")

	_KMC_Process(State, Recorder, -9959, -9999, 4000)
	_KMC_Process(State, Recorder, -9959, -9999, 4000 + KLMouseConst.PARK_IDLE_MS + 1)
	AssertEqual(2, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) moving far enough on the same negative monitor permits one new park")
}
Test("keylogger mouse: initialization flags cannot collide with virtual-screen coordinates (ahk5-01-negative-mouse-coordinates)",
	_KMC_InitializationDoesNotCollideWithRealCoordinates)

_KMC_FilterResetPreservesOwnership() {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, 100, 100, 1000)
	_KMC_Process(State, Recorder, 110, 100, 1250)
	AssertEqual(10, Recorder.Distance,
		"(ahk5-01-negative-mouse-coordinates) positive-coordinate distance remains unchanged")

	_KMC_Process(State, Recorder, -2000, -300, 1500, false, true)
	AssertEqual(10, Recorder.Distance,
		"(ahk5-01-negative-mouse-coordinates) filtered motion never contributes distance")
	_KMC_Process(State, Recorder, -2000, -300, 1750)
	AssertEqual(10, Recorder.Distance,
		"(ahk5-01-negative-mouse-coordinates) the first resumed sample only re-arms park ownership")
	AssertEqual(0, Recorder.Events.Length)
	_KMC_Process(State, Recorder, -2000, -300, 1750 + KLMouseConst.PARK_IDLE_MS + 1)
	AssertEqual(1, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) park detection resumes exactly once after the filter clears")
}
Test("keylogger mouse: filter reset re-arms explicit park ownership (ahk5-01-negative-mouse-coordinates)",
	_KMC_FilterResetPreservesOwnership)

_KMC_TickWrapKeepsIdleAndDedupExact() {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	StartTick := 0xFFFFFF00
	AfterIdleWrap := StartTick + KLMouseConst.PARK_IDLE_MS + 1
	_KMC_Process(State, Recorder, -1920, -240, StartTick)
	_KMC_Process(State, Recorder, -1920, -240, AfterIdleWrap)
	AssertEqual(1, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) idle ownership must retain the native high word across the DWORD boundary")

	State.park_still_since := StartTick + 40000 - KLMouseConst.PARK_IDLE_MS - 1
	State.park_fired := true
	State.park_fired_x := -1920
	State.park_fired_y := -240
	State.park_fired_at := 0xFFFFFF00
	_KMC_Process(State, Recorder, -1920, -240, StartTick + 40000)
	AssertEqual(2, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) a prior park must expire after 30 seconds on a chronological native clock")
}
Test("keylogger mouse: native chronological crossing preserves coordinate ownership (ahk5-01-negative-mouse-coordinates)",
	_KMC_TickWrapKeepsIdleAndDedupExact)

; Actual pure park samples publish their full native dwell duration.
_KMC_Native64Idle(Elapsed) {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, -1920, -240, 100)
	_KMC_Process(State, Recorder, -1920, -240, 100 + Elapsed)
	Expected := Elapsed >= KLMouseConst.PARK_IDLE_MS
	AssertEqual(Expected ? 1 : 0, Recorder.Events.Length, "native dwell time cannot be reduced to a DWORD remainder")
	if Expected {
		Event := Recorder.Events[1]
		AssertEqual("mouse_idle_park", Event["type"])
		AssertEqual("negative-monitor.exe", Event["app"])
		AssertEqual(-1920, Event["x"])
		AssertEqual(-240, Event["y"])
		AssertEqual(Elapsed, Event["still_ms"], "the actual emitted Map must retain the full dwell")
		AssertEqual(100 + Elapsed, State.park_fired_at)
		AssertEqual(100 + Elapsed, State.park_still_since)
	}
	AssertEqual(0, Recorder.Distance, "stationary samples add no movement")
}
for _KMC_Native64Elapsed in [2999, 3000, 3001, 4294970295, 4294970296, 4294970297, 8589937592]
	Test("keylogger mouse native64: dwell " . _KMC_Native64Elapsed, _KMC_Native64Idle.Bind(_KMC_Native64Elapsed))

_KMC_Native64Dedup(Gap) {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, -1920, -240, 100)
	First := 100 + KLMouseConst.PARK_IDLE_MS
	_KMC_Process(State, Recorder, -1920, -240, First)
	AssertEqual(1, Recorder.Events.Length, "the first sample owns a real initial park")
	_KMC_Process(State, Recorder, -1920, -240, First + Gap)
	AssertEqual(Gap >= 30000 ? 2 : 1, Recorder.Events.Length,
		"the same-position dedup interval cannot become fresh after a full native cycle")
	if Gap >= 30000 {
		AssertEqual(Gap, Recorder.Events[2]["still_ms"])
		AssertEqual(First + Gap, State.park_fired_at)
	}
}
for _KMC_Native64Gap in [29999, 30000, 30001, 4294997295, 4294997296, 4294997297]
	Test("keylogger mouse native64: dedup gap " . _KMC_Native64Gap, _KMC_Native64Dedup.Bind(_KMC_Native64Gap))

_KMC_Native64Refusal(Mode) {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, -1920, -240, 100)
	Now := 4294997396
	_KMC_Process(State, Recorder, -1920, -240, Now, Mode = "paused", Mode = "filtered", Mode != "uninitialized")
	AssertEqual(0, Recorder.Events.Length)
	AssertFalse(State.park_initialized, "inadmissible samples retire only their local park admission")
	_KMC_Process(State, Recorder, -1920, -240, Now + 1)
	AssertEqual(0, Recorder.Events.Length, "the first resumed sample only re-arms ownership")
	_KMC_Process(State, Recorder, -1920, -240, Now + 1 + KLMouseConst.PARK_IDLE_MS)
	AssertEqual(1, Recorder.Events.Length)
	AssertEqual(KLMouseConst.PARK_IDLE_MS, Recorder.Events[1]["still_ms"])
}
for _KMC_Native64Mode in ["paused", "filtered", "uninitialized"]
	Test("keylogger mouse native64: refusal and re-arm " . _KMC_Native64Mode, _KMC_Native64Refusal.Bind(_KMC_Native64Mode))

_KMC_Native64Moved() {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, -1920, -240, 100)
	_KMC_Process(State, Recorder, -1920, -240, 3100)
	Now := 4294970397
	_KMC_Process(State, Recorder, -1820, -240, Now)
	AssertEqual(1, Recorder.Events.Length, "movement must reset dwell before it can emit a park")
	AssertEqual(Now, State.park_still_since)
	_KMC_Process(State, Recorder, -1820, -240, Now + KLMouseConst.PARK_IDLE_MS)
	AssertEqual(2, Recorder.Events.Length)
	AssertEqual(KLMouseConst.PARK_IDLE_MS, Recorder.Events[2]["still_ms"])
	AssertEqual(100, Recorder.Distance)
}
Test("keylogger mouse native64: movement resets dwell without changing distance accounting", _KMC_Native64Moved)

_KMC_Native64Invalid(Start, Now) {
	State := _KMC_NewState()
	Recorder := {Distance: 0, Events: []}
	_KMC_Process(State, Recorder, -1920, -240, 100)
	State.park_still_since := Start
	Refused := false
	try _KMC_Process(State, Recorder, -1920, -240, Now)
	catch ValueError
		Refused := true
	AssertTrue(Refused, "invalid native dwell must fail with ValueError")
	AssertEqual(0, Recorder.Events.Length)
	AssertEqual(0, Recorder.Distance)
}
for _KMC_Native64Row in [[100, 99], [-1, 100], [0, -1]]
	Test("keylogger mouse native64: rejects invalid dwell " . _KMC_Native64Row[1] . "/" . _KMC_Native64Row[2],
		_KMC_Native64Invalid.Bind(_KMC_Native64Row*))
