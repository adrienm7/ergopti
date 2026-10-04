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
