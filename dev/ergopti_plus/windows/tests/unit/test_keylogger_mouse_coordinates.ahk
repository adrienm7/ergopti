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
	AfterIdleWrap := (StartTick + KLMouseConst.PARK_IDLE_MS + 1) & 0xFFFFFFFF
	_KMC_Process(State, Recorder, -1920, -240, StartTick)
	_KMC_Process(State, Recorder, -1920, -240, AfterIdleWrap)
	AssertEqual(1, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) idle ownership must survive the 32-bit tick wrap")

	State.park_still_since := 40000 - KLMouseConst.PARK_IDLE_MS - 1
	State.park_fired := true
	State.park_fired_x := -1920
	State.park_fired_y := -240
	State.park_fired_at := 0xFFFFFF00
	_KMC_Process(State, Recorder, -1920, -240, 40000)
	AssertEqual(2, Recorder.Events.Length,
		"(ahk5-01-negative-mouse-coordinates) a prior park before tick wrap must expire after 30 seconds")
}
Test("keylogger mouse: explicit coordinate ownership remains tick-wrap safe (ahk5-01-negative-mouse-coordinates)",
	_KMC_TickWrapKeepsIdleAndDedupExact)
