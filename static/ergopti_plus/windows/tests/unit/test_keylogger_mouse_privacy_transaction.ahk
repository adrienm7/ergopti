; tests/unit/test_keylogger_mouse_privacy_transaction.ahk

#Requires AutoHotkey v2.0


_KLMP_DownUpPrivacyMatrix() {
	Cases := [
		[true, 10, 4, 10, 4, false, false, true, "same authorized context"],
		[false, 10, 4, 10, 4, false, false, false, "private down"],
		[true, 10, 4, 10, 4, true, false, false, "private up"],
		[true, 10, 4, 11, 4, false, false, false, "different target HWND"],
		[true, 10, 4, 10, 5, false, false, false, "changed focus generation"],
		[true, 10, 4, 10, 4, false, true, false, "suspended release"]
	]
	for Row in Cases {
		Actual := _KL_Mouse_GestureAuthorized(
			Row[1], Row[2], Row[3], Row[4], Row[5], Row[6], Row[7])
		AssertEqual(Actual, Row[8], Row[9])
	}
}
Test("keylogger mouse: both gesture endpoints require one authorized context (mouse-cross-privacy-drag)",
	_KLMP_DownUpPrivacyMatrix)

; Actual claim, measure and event construction share the production path.
_KLMR_Record(Recorder, Event) {
	Recorder.Events.Push(Event)
	return true
}

_KLMR_WithGesture(Button, StartTick, Action, InitialCritical := 0) {
	Prefix := Button = "left" ? "lbtn_" : "rbtn_"
	Fields := ["down_x", "down_y", "down_tick", "held", "authorized", "hwnd", "focus_gen"]
	Saved := Map()
	for Field in Fields {
		Name := Prefix . Field
		Saved[Name] := KLMouse.%Name%
	}
	PreviousApp := Keylogger.session_app
	PreviousCritical := A_IsCritical
	Recorder := {Events: []}
	try {
		Critical(InitialCritical)
		KLMouse.%(Prefix . "down_x")% := -100
		KLMouse.%(Prefix . "down_y")% := -200
		KLMouse.%(Prefix . "down_tick")% := StartTick
		KLMouse.%(Prefix . "held")% := true
		KLMouse.%(Prefix . "authorized")% := true
		KLMouse.%(Prefix . "hwnd")% := 20
		KLMouse.%(Prefix . "focus_gen")% := 4
		Keylogger.session_app := "owned-gesture.exe"
		Gesture := _KL_Mouse_ClaimGesture(Button)
		AssertTrue(IsObject(Gesture), "the actual held receipt must be claimed")
		AssertEqual(InitialCritical, A_IsCritical, "claim must restore caller Critical")
		AssertFalse(KLMouse.%(Prefix . "held")%, "the claim retires held state")
		AssertFalse(KLMouse.%(Prefix . "authorized")%, "the claim retires admission")
		AssertFalse(_KL_Mouse_ClaimGesture(Button), "one release cannot claim twice")
		AssertEqual(StartTick, Gesture.tick, "the actual receipt preserves its native origin")
		Action.Call(Gesture, Recorder)
		AssertEqual(InitialCritical, A_IsCritical, "measurement and append must preserve caller Critical")
	} finally {
		for Name, Value in Saved
			KLMouse.%Name% := Value
		Keylogger.session_app := PreviousApp
		Critical(PreviousCritical)
	}
}

_KLMR_EmitExpected(Button, EndTick, Expected, Gesture, Recorder) {
	Measurement := _KL_Mouse_MeasureGesture(Gesture, -70, -160, EndTick)
	AssertEqual(50, Measurement.distance, "the actual geometry must remain unchanged")
	Result := KL_Mouse_LogDrag(Button, Gesture.x, Gesture.y, -70, -160,
		Round(Measurement.distance), Measurement.duration, _KLMR_Record.Bind(Recorder))
	AssertEqual("", Result, "the append port must preserve the legacy void result")
	AssertEqual(1, Recorder.Events.Length, "one actual event must be published")
	Event := Recorder.Events[1]
	AssertEqual("mouse_drag", Event["type"])
	AssertEqual("owned-gesture.exe", Event["app"])
	AssertEqual(Button, Event["button"])
	AssertEqual(-100, Event["x1"])
	AssertEqual(-200, Event["y1"])
	AssertEqual(-70, Event["x2"])
	AssertEqual(-160, Event["y2"])
	AssertEqual(50, Event["dist_px"])
	AssertEqual(Expected, Event["duration_ms"], "the final event must retain the complete native interval")
	AssertEqual("Integer", Type(Event["duration_ms"]))
}

_KLMR_Pipeline(Button, StartTick, EndTick, Expected, InitialCritical := 0) {
	_KLMR_WithGesture(Button, StartTick,
		_KLMR_EmitExpected.Bind(Button, EndTick, Expected), InitialCritical)
}

_KLMR_ExpectInvalid(EndTick, Gesture, Recorder) {
	Caught := false
	try _KL_Mouse_MeasureGesture(Gesture, -70, -160, EndTick)
	catch ValueError as Failure {
		AssertEqual("ValueError", Type(Failure))
		Caught := true
	}
	AssertTrue(Caught, "invalid native endpoints require the canonical ValueError")
	AssertEqual(0, Recorder.Events.Length, "invalid measurement must not publish an event")
}

_KLMR_Invalid(Button, StartTick, EndTick) {
	_KLMR_WithGesture(Button, StartTick, _KLMR_ExpectInvalid.Bind(EndTick), 17)
}

_KLMR_ObserveDefault(Button, StartTick, Gesture, Recorder) {
	Before := A_TickCount
	Measurement := _KL_Mouse_MeasureGesture(Gesture, -70, -160)
	After := A_TickCount
	KL_Mouse_LogDrag(Button, Gesture.x, Gesture.y, -70, -160,
		Round(Measurement.distance), Measurement.duration, _KLMR_Record.Bind(Recorder))
	AssertEqual(1, Recorder.Events.Length)
	AssertEqual(50, Recorder.Events[1]["dist_px"])
	AssertTrue(Recorder.Events[1]["duration_ms"] >= Before - StartTick,
		"omitted final time must not precede the native observation bracket")
	AssertTrue(Recorder.Events[1]["duration_ms"] <= After - StartTick,
		"omitted final time must not exceed the native observation bracket")
}

_KLMR_Default(Button) {
	StartTick := A_TickCount
	_KLMR_WithGesture(Button, StartTick, _KLMR_ObserveDefault.Bind(Button, StartTick))
}
Test("mouse-release-native64: left zero", _KLMR_Pipeline.Bind("left", 1000, 1000, 0))
Test("mouse-release-native64: left one", _KLMR_Pipeline.Bind("left", 1000, 1001, 1))
Test("mouse-release-native64: left ordinary", _KLMR_Pipeline.Bind("left", 1000, 1499, 499))
Test("mouse-release-native64: left legal-crossing", _KLMR_Pipeline.Bind("left", 0xFFFFFFFE, 0x100000001, 3))
Test("mouse-release-native64: left long-exact", _KLMR_Pipeline.Bind("left", 1000, 1000 + 0x100000000, 0x100000000))
Test("mouse-release-native64: left long-one", _KLMR_Pipeline.Bind("left", 1000, 1001 + 0x100000000, 1 + 0x100000000))
Test("mouse-release-native64: left long-second", _KLMR_Pipeline.Bind("left", 1000, 2000 + 0x100000000, 1000 + 0x100000000))
Test("mouse-release-native64: left two-long-gaps", _KLMR_Pipeline.Bind("left", 1000, 1123 + 0x200000000, 123 + 0x200000000))
Test("mouse-release-native64: left negative-origin typed refusal", _KLMR_Invalid.Bind("left", -1, 0))
Test("mouse-release-native64: left string-origin typed refusal", _KLMR_Invalid.Bind("left", "1000", 1100))
Test("mouse-release-native64: left fractional-origin typed refusal", _KLMR_Invalid.Bind("left", 1000.5, 1100.5))
Test("mouse-release-native64: left backwards typed refusal", _KLMR_Invalid.Bind("left", 1100, 1000))
Test("mouse-release-native64: left negative-final typed refusal", _KLMR_Invalid.Bind("left", 0, -1))
Test("mouse-release-native64: left omitted native clock", _KLMR_Default.Bind("left"))
Test("mouse-release-native64: left Critical caller", _KLMR_Pipeline.Bind("left", 1000, 1499, 499, 17))
Test("mouse-release-native64: right zero", _KLMR_Pipeline.Bind("right", 1000, 1000, 0))
Test("mouse-release-native64: right one", _KLMR_Pipeline.Bind("right", 1000, 1001, 1))
Test("mouse-release-native64: right ordinary", _KLMR_Pipeline.Bind("right", 1000, 1499, 499))
Test("mouse-release-native64: right legal-crossing", _KLMR_Pipeline.Bind("right", 0xFFFFFFFE, 0x100000001, 3))
Test("mouse-release-native64: right long-exact", _KLMR_Pipeline.Bind("right", 1000, 1000 + 0x100000000, 0x100000000))
Test("mouse-release-native64: right long-one", _KLMR_Pipeline.Bind("right", 1000, 1001 + 0x100000000, 1 + 0x100000000))
Test("mouse-release-native64: right long-second", _KLMR_Pipeline.Bind("right", 1000, 2000 + 0x100000000, 1000 + 0x100000000))
Test("mouse-release-native64: right two-long-gaps", _KLMR_Pipeline.Bind("right", 1000, 1123 + 0x200000000, 123 + 0x200000000))
Test("mouse-release-native64: right negative-origin typed refusal", _KLMR_Invalid.Bind("right", -1, 0))
Test("mouse-release-native64: right string-origin typed refusal", _KLMR_Invalid.Bind("right", "1000", 1100))
Test("mouse-release-native64: right fractional-origin typed refusal", _KLMR_Invalid.Bind("right", 1000.5, 1100.5))
Test("mouse-release-native64: right backwards typed refusal", _KLMR_Invalid.Bind("right", 1100, 1000))
Test("mouse-release-native64: right negative-final typed refusal", _KLMR_Invalid.Bind("right", 0, -1))
Test("mouse-release-native64: right omitted native clock", _KLMR_Default.Bind("right"))
Test("mouse-release-native64: right Critical caller", _KLMR_Pipeline.Bind("right", 1000, 1499, 499, 17))

; Actual scroll owners run with inert ports; no cursor, timer or log is touched.
_KLMS_WithState(Ticks, HTicks, Start, Last, Action, InitialCritical := 0, Initialized := true) {
	Fields := ["scroll_ticks", "scroll_h_ticks", "scroll_start", "scroll_last"]
	Saved := Map()
	for Field in Fields
		Saved[Field] := KLMouse.%Field%
	SavedInitialized := Keylogger.initialized
	SavedApp := Keylogger.session_app
	SavedCritical := A_IsCritical
	Recorder := {Calls: [], Events: [], Bumps: 0, Arms: []}
	try {
		Critical(InitialCritical)
		KLMouse.scroll_ticks := Ticks
		KLMouse.scroll_h_ticks := HTicks
		KLMouse.scroll_start := Start
		KLMouse.scroll_last := Last
		Keylogger.initialized := Initialized
		Keylogger.session_app := "owned-scroll.exe"
		Action.Call(Recorder)
		AssertEqual(InitialCritical, A_IsCritical, "scroll processing restores the caller Critical state")
	} finally {
		for Field, Value in Saved
			KLMouse.%Field% := Value
		Keylogger.initialized := SavedInitialized
		Keylogger.session_app := SavedApp
		Critical(SavedCritical)
	}
}

_KLMS_Filter(Recorder, Name, Result := false) {
	Recorder.Calls.Push(Name)
	return Result
}

_KLMS_Bump(Recorder) {
	Recorder.Calls.Push("bump")
	Recorder.Bumps += 1
}

_KLMS_Arm(Recorder, Delay) {
	Recorder.Calls.Push("arm")
	Recorder.Arms.Push(Delay)
}

_KLMS_Refresh(Recorder) {
	Recorder.Calls.Push("refresh")
}

_KLMS_Position(Recorder) {
	Recorder.Calls.Push("position")
	return {x: -400, y: 125}
}

_KLMS_Append(Recorder, Event) {
	Recorder.Calls.Push("append")
	Recorder.Events.Push(Event)
}

_KLMS_Flush(Now, Recorder, Filtered := false) {
	return KL_Mouse_FlushScroll(Now, _KLMS_Filter.Bind(Recorder, "flush-filter", Filtered),
		_KLMS_Refresh.Bind(Recorder), _KLMS_Position.Bind(Recorder), _KLMS_Append.Bind(Recorder))
}

_KLMS_Previous(Now, Recorder) {
	Recorder.Calls.Push("flush")
	_KLMS_Flush(Now, Recorder)
}

_KLMS_Accumulate(Axis, Now, Recorder, Filtered := false) {
	Fn := Axis = "vertical" ? KL_Mouse_AccumScroll : KL_Mouse_AccumScrollH
	return Fn.Call(1, Now, _KLMS_Filter.Bind(Recorder, "accum-filter", Filtered),
		_KLMS_Previous.Bind(Now, Recorder), _KLMS_Bump.Bind(Recorder), _KLMS_Arm.Bind(Recorder))
}

_KLMS_GapAction(Axis, Elapsed, ExpectedFlush, Recorder) {
	Now := 1000 + Elapsed
	_KLMS_Accumulate(Axis, Now, Recorder)
	AssertEqual(ExpectedFlush ? 1 : 0, Recorder.Events.Length,
		"the actual previous burst must be flushed exactly when the full interval exceeds400")
	AssertEqual(1, Recorder.Bumps)
	AssertEqual(1, Recorder.Arms.Length)
	AssertEqual(-400, Recorder.Arms[1], "native timer admission keeps the existing one-shot delay")
	AssertEqual(Now, KLMouse.scroll_last)
	AssertEqual(ExpectedFlush ? Now : 1000, KLMouse.scroll_start)
	AssertEqual(Axis = "vertical" ? (ExpectedFlush ? 1 : 3) : (ExpectedFlush ? 0 : 2),
		KLMouse.scroll_ticks)
	AssertEqual(Axis = "horizontal" ? 1 : 0, KLMouse.scroll_h_ticks)
	if ExpectedFlush {
		Event := Recorder.Events[1]
		AssertEqual(Elapsed, Event["duration_ms"], "the flushed old burst keeps its native64 duration")
		AssertEqual(2, Event["ticks"])
		AssertEqual("up", Event["direction"])
		AssertEqual("accum-filter flush flush-filter refresh position append bump arm",
			_JoinParts(Recorder.Calls), "actual gap handling precedes the new burst and counter/timer")
	} else {
		AssertEqual("accum-filter bump arm", _JoinParts(Recorder.Calls))
	}
}

_KLMS_Gap(Axis, Elapsed, ExpectedFlush) {
	_KLMS_WithState(2, 0, 1000, 1000, _KLMS_GapAction.Bind(Axis, Elapsed, ExpectedFlush))
}

_KLMS_FlushAction(End, Duration, Direction, Total, Velocity, Recorder) {
	_KLMS_Flush(End, Recorder)
	AssertEqual(1, Recorder.Events.Length)
	Event := Recorder.Events[1]
	AssertEqual("mouse_scroll", Event["type"])
	AssertEqual("owned-scroll.exe", Event["app"])
	AssertEqual(Direction, Event["direction"])
	AssertEqual(Total, Event["ticks"])
	AssertEqual(Duration, Event["duration_ms"])
	AssertEqual("Integer", Type(Event["duration_ms"]))
	AssertEqual(Velocity, Event["velocity"], "the actual event must use the complete duration")
	AssertEqual(-400, Event["x"])
	AssertEqual(125, Event["y"])
	AssertEqual("flush-filter refresh position append", _JoinParts(Recorder.Calls))
	for Field in ["scroll_ticks", "scroll_h_ticks", "scroll_start", "scroll_last"]
		AssertEqual(0, KLMouse.%Field%, "the actual claim retires all four burst fields")
}

_KLMS_FlushCase(Ticks, HTicks, End, Duration, Direction, Total, Velocity, InitialCritical := 0) {
	_KLMS_WithState(Ticks, HTicks, 1000, 1000,
		_KLMS_FlushAction.Bind(End, Duration, Direction, Total, Velocity), InitialCritical)
}

_KLMS_RefusedAction(Mode, Recorder) {
	if InStr(Mode, "filtered-accum") {
		Axis := Mode = "filtered-accum-horizontal" ? "horizontal" : "vertical"
		_KLMS_Accumulate(Axis, 1500, Recorder, true)
		AssertEqual(2, KLMouse.scroll_ticks)
		AssertEqual(1000, KLMouse.scroll_start)
		AssertEqual(1000, KLMouse.scroll_last)
		AssertEqual("accum-filter", _JoinParts(Recorder.Calls))
	} else {
		_KLMS_Flush(1500, Recorder, Mode = "filtered-flush")
		for Field in ["scroll_ticks", "scroll_h_ticks", "scroll_start", "scroll_last"]
			AssertEqual(0, KLMouse.%Field%, "a rejected claimed burst remains retired")
		AssertEqual("flush-filter", _JoinParts(Recorder.Calls))
	}
	AssertEqual(0, Recorder.Events.Length)
	AssertEqual(0, Recorder.Bumps)
	AssertEqual(0, Recorder.Arms.Length)
}

_KLMS_Refused(Mode) {
	_KLMS_WithState(2, 0, 1000, 1000, _KLMS_RefusedAction.Bind(Mode),
		17, Mode != "uninitialized")
}

_KLMS_InvalidAction(Mode, End, Recorder) {
	Caught := false
	try {
		if Mode = "flush"
			_KLMS_Flush(End, Recorder)
		else
			_KLMS_Accumulate(Mode, End, Recorder)
	} catch ValueError as Failure {
		AssertEqual("ValueError", Type(Failure))
		Caught := true
	}
	AssertTrue(Caught, "invalid native endpoints require a genuine ValueError")
	AssertEqual(0, Recorder.Events.Length)
	AssertEqual(0, Recorder.Bumps)
	AssertEqual(0, Recorder.Arms.Length)
}

_KLMS_Invalid(Mode, End) {
	_KLMS_WithState(2, 0, 1000, 1000, _KLMS_InvalidAction.Bind(Mode, End), 17)
}

_KLMS_DefaultAction(Axis, Recorder) {
	Fn := Axis = "vertical" ? KL_Mouse_AccumScroll : KL_Mouse_AccumScrollH
	Before := A_TickCount
	Fn.Call(1, , _KLMS_Filter.Bind(Recorder, "accum-filter"),
		_KLMS_Previous.Bind(Before, Recorder), _KLMS_Bump.Bind(Recorder), _KLMS_Arm.Bind(Recorder))
	After := A_TickCount
	AssertTrue(KLMouse.scroll_start >= Before && KLMouse.scroll_start <= After)
	AssertEqual(KLMouse.scroll_start, KLMouse.scroll_last)
	AssertEqual(0, Recorder.Events.Length)
	AssertEqual(1, Recorder.Bumps)
	AssertEqual(1, Recorder.Arms.Length)
}

_KLMS_Default(Axis) {
	_KLMS_WithState(0, 0, 0, 0, _KLMS_DefaultAction.Bind(Axis))
}

_KLMS_DefaultFlushAction(Start, Recorder) {
	Before := A_TickCount
	KL_Mouse_FlushScroll(, _KLMS_Filter.Bind(Recorder, "flush-filter"),
		_KLMS_Refresh.Bind(Recorder), _KLMS_Position.Bind(Recorder), _KLMS_Append.Bind(Recorder))
	After := A_TickCount
	AssertEqual(1, Recorder.Events.Length)
	AssertTrue(Recorder.Events[1]["duration_ms"] >= Before - Start)
	AssertTrue(Recorder.Events[1]["duration_ms"] <= After - Start)
}

_KLMS_DefaultFlush() {
	Start := A_TickCount
	_KLMS_WithState(5, 0, Start, Start, _KLMS_DefaultFlushAction.Bind(Start))
}

_KLMS_EmptyAction(Recorder) {
	_KLMS_Flush(1500, Recorder)
	AssertEqual(0, Recorder.Calls.Length, "empty bursts do not query, refresh or append")
	AssertEqual(0, Recorder.Events.Length)
}

_KLMS_Empty() {
	_KLMS_WithState(0, 0, 0, 0, _KLMS_EmptyAction)
}

Test("scroll-native64: vertical ordinary399", _KLMS_Gap.Bind("vertical", 399, false))
Test("scroll-native64: vertical ordinary400", _KLMS_Gap.Bind("vertical", 400, false))
Test("scroll-native64: vertical ordinary401", _KLMS_Gap.Bind("vertical", 401, true))
Test("scroll-native64: vertical long399", _KLMS_Gap.Bind("vertical", 0x100000000 + 399, true))
Test("scroll-native64: vertical long400", _KLMS_Gap.Bind("vertical", 0x100000000 + 400, true))
Test("scroll-native64: vertical long401", _KLMS_Gap.Bind("vertical", 0x100000000 + 401, true))
Test("scroll-native64: vertical two-long-gaps", _KLMS_Gap.Bind("vertical", 0x200000000 + 399, true))
Test("scroll-native64: horizontal ordinary399", _KLMS_Gap.Bind("horizontal", 399, false))
Test("scroll-native64: horizontal ordinary400", _KLMS_Gap.Bind("horizontal", 400, false))
Test("scroll-native64: horizontal ordinary401", _KLMS_Gap.Bind("horizontal", 401, true))
Test("scroll-native64: horizontal long399", _KLMS_Gap.Bind("horizontal", 0x100000000 + 399, true))
Test("scroll-native64: horizontal long400", _KLMS_Gap.Bind("horizontal", 0x100000000 + 400, true))
Test("scroll-native64: horizontal long401", _KLMS_Gap.Bind("horizontal", 0x100000000 + 401, true))
Test("scroll-native64: horizontal two-long-gaps", _KLMS_Gap.Bind("horizontal", 0x200000000 + 399, true))
Test("scroll-native64: flush ordinary up", _KLMS_FlushCase.Bind(5, 0, 2000, 1000, "up", 5, 5))
Test("scroll-native64: flush full64 up", _KLMS_FlushCase.Bind(5, 0, 2000 + 0x100000000, 1000 + 0x100000000, "up", 5, 0))
Test("scroll-native64: flush full64 down", _KLMS_FlushCase.Bind(-5, 0, 2000 + 0x100000000, 1000 + 0x100000000, "down", 5, 0))
Test("scroll-native64: flush full64 horizontal", _KLMS_FlushCase.Bind(0, -3, 2000 + 0x100000000, 1000 + 0x100000000, "horizontal", 3, 0))
Test("scroll-native64: flush mixed keeps horizontal policy", _KLMS_FlushCase.Bind(5, -3, 2000, 1000, "horizontal", 3, 3))
Test("scroll-native64: flush Critical caller", _KLMS_FlushCase.Bind(5, 0, 2000, 1000, "up", 5, 5, 17))
Test("scroll-native64: filtered accumulator unchanged", _KLMS_Refused.Bind("filtered-accum"))
Test("scroll-native64: filtered horizontal accumulator unchanged", _KLMS_Refused.Bind("filtered-accum-horizontal"))
Test("scroll-native64: filtered claimed burst retired", _KLMS_Refused.Bind("filtered-flush"))
Test("scroll-native64: uninitialized claimed burst retired", _KLMS_Refused.Bind("uninitialized"))
Test("scroll-native64: vertical backwards typed refusal", _KLMS_Invalid.Bind("vertical", 999))
Test("scroll-native64: horizontal backwards typed refusal", _KLMS_Invalid.Bind("horizontal", 999))
Test("scroll-native64: flush backwards typed refusal", _KLMS_Invalid.Bind("flush", 999))
Test("scroll-native64: vertical fractional typed refusal", _KLMS_Invalid.Bind("vertical", 1500.5))
Test("scroll-native64: horizontal fractional typed refusal", _KLMS_Invalid.Bind("horizontal", 1500.5))
Test("scroll-native64: flush fractional typed refusal", _KLMS_Invalid.Bind("flush", 1500.5))
Test("scroll-native64: vertical omitted native sample", _KLMS_Default.Bind("vertical"))
Test("scroll-native64: horizontal omitted native sample", _KLMS_Default.Bind("horizontal"))
Test("scroll-native64: flush omitted native sample", _KLMS_DefaultFlush)
Test("scroll-native64: empty burst unchanged", _KLMS_Empty)
