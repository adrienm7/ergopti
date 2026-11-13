; tests/unit/layouts/engine/registry/test_watch.ahk

; ==============================================================================
; MODULE: Keyboard Layout Registry Watch
; DESCRIPTION:
; A keyboard-layout registry change runs the layout poll's capture at once
; (maintainer decision of 2026-11-11), not at the poll's next tick. A fake port
; replays a notification; the native case watches a private HKCU key under
; Software\ErgoptiTests, never the real layout keys, and deletes it.
; ==============================================================================

#Requires AutoHotkey v2.0




; A port that records every native call; "pending" holds the events the test
; signals, "fail_open" the key name whose open is refused.
_LRWT_Port(State) {
	Open(Root, SubKey) {
		if (State["fail_open"] == SubKey)
			throw OSError(5, -1, "RegOpenKeyExW " . SubKey)
		State["log"].Push("open " . SubKey)
		State["open_keys"][SubKey] := true
		return SubKey
	}
	Event() {
		State["next_event"] += 1
		Id := "event" . State["next_event"]
		State["open_events"][Id] := true
		return Id
	}
	Arm(Handle, Event) {
		State["log"].Push("arm " . Handle)
	}
	Signaled(Event) {
		if !State["pending"].Has(Event)
			return false
		State["pending"].Delete(Event)
		return true
	}
	CloseKey(Handle) {
		State["open_keys"].Delete(Handle)
	}
	CloseEvent(Handle) {
		State["open_events"].Delete(Handle)
	}
	Schedule(Fn, Ms) {
		State["timer"] := Ms == 0 ? 0 : Fn
		State["timer_ms"] := Ms
	}
	return Map("open", Open, "event", Event, "arm", Arm, "signaled", Signaled,
		"close_key", CloseKey, "close_event", CloseEvent, "schedule", Schedule)
}

_LRWT_State() {
	return Map("log", [], "pending", Map(), "open_keys", Map(), "open_events", Map(),
		"next_event", 0, "timer", 0, "timer_ms", -1, "fail_open", "")
}

_LRWT_Keys() {
	return [Map("root", 1, "subkey", "user", "name", "user layouts"),
		Map("root", 2, "subkey", "machine", "name", "machine layouts")]
}

; A synthetic notification runs the capture in the same tick, once, after the
; signaled key is armed again; an unchanged tick captures nothing.
_LRWT_NotificationCapturesAtOnce() {
	State := _LRWT_State()
	Captures := []
	Capture() {
		State["log"].Push("capture")
		Captures.Push(A_TickCount)
	}
	AssertTrue(LayoutRegistryWatch_Start(Capture, _LRWT_Keys(), _LRWT_Port(State)))
	try {
		AssertTrue(LayoutRegistryWatch_IsRunning())
		AssertEqual(TimingsGet("adapters", "layout_registry_watch_poll_ms"), State["timer_ms"],
			"the events are polled at the registry delay")
		AssertTrue(TimingsGet("adapters", "layout_registry_watch_poll_ms") < 1000,
			"the watch sees a change sooner than the one-second layout poll")
		State["timer"].Call()
		AssertEqual(0, Captures.Length, "no change, no capture")
		State["log"] := []
		State["pending"]["event2"] := true
		State["timer"].Call()
		AssertEqual(1, Captures.Length, "the notification runs the capture in the same tick")
		AssertEqual("arm machine|capture", _LRWT_Join(State["log"]),
			"the changed key is armed again before the capture, and only it")
		State["pending"]["event1"] := true
		State["pending"]["event2"] := true
		State["timer"].Call()
		AssertEqual(2, Captures.Length, "two keys changed in one tick capture once")
		AssertThrows(() => LayoutRegistryWatch_Start(Capture, _LRWT_Keys(), _LRWT_Port(State)),
			"a second start is refused")
	} finally LayoutRegistryWatch_Stop()
	AssertFalse(LayoutRegistryWatch_IsRunning())
	AssertEqual(0, State["timer"], "the stop ends the poll")
	AssertEqual(0, State["open_keys"].Count, "the stop closes every key")
	AssertEqual(0, State["open_events"].Count, "the stop closes every event")
}

; A refused start releases what it opened and leaves no watch; a tick of a
; stopped watch captures nothing.
_LRWT_RefusedStartLeaksNothing() {
	State := _LRWT_State()
	State["fail_open"] := "machine"
	Captured := 0
	Capture() {
		Captured += 1
	}
	AssertFalse(LayoutRegistryWatch_Start(Capture, _LRWT_Keys(), _LRWT_Port(State)))
	AssertFalse(LayoutRegistryWatch_IsRunning())
	AssertEqual(0, State["open_keys"].Count, "the first key is closed again")
	AssertEqual(0, State["open_events"].Count, "the first event is closed again")
	AssertEqual(-1, State["timer_ms"], "a refused start schedules no poll")
	State["fail_open"] := ""
	AssertTrue(LayoutRegistryWatch_Start(Capture, _LRWT_Keys(), _LRWT_Port(State)), "a later start is admitted")
	Tick := State["timer"]
	LayoutRegistryWatch_Stop()
	State["pending"]["event3"] := true
	Tick.Call()
	AssertEqual(0, Captured, "a tick queued before the stop captures nothing")
}

; The real RegNotifyChangeKeyValue on a private key: a value written, then a
; subkey created, are each captured at the next tick.
_LRWT_NativeNotification() {
	global LAYOUT_REGISTRY_WATCH_HKEY_CURRENT_USER
	SubKey := "Software\ErgoptiTests\LayoutRegistryWatch_" . ProcessExist() . "_" . A_TickCount . "_" . Random(1000, 9999)
	Path := "HKCU\" . SubKey
	RegWrite("created", "REG_SZ", Path, "fixture")
	Captured := 0
	Capture() {
		Captured += 1
	}
	try {
		Port := _LayoutRegistryWatchNativePort().Clone()
		Timer := 0
		Port["schedule"] := (Fn, Ms) => (Timer := Ms == 0 ? 0 : Fn)
		AssertTrue(LayoutRegistryWatch_Start(Capture,
			[Map("root", LAYOUT_REGISTRY_WATCH_HKEY_CURRENT_USER, "subkey", SubKey, "name", Path)], Port))
		try {
			Timer.Call()
			AssertEqual(0, Captured, "an unchanged key captures nothing")
			RegWrite("0000040C", "REG_SZ", Path, "1")
			Timer.Call()
			AssertEqual(1, Captured, "a value written is captured at the next tick")
			Timer.Call()
			AssertEqual(1, Captured, "one change is captured once")
			RegWrite("00000409", "REG_SZ", Path . "\Preload", "1")
			Timer.Call()
			AssertEqual(2, Captured, "the key was armed again: a subkey change is captured too")
		} finally LayoutRegistryWatch_Stop()
	} finally RegDeleteKey(Path)
}

; The entry starts the watch on the poll's own capture after the poll timer,
; and shutdown stops it.
_LRWT_DriverWiring() {
	Source := _DriverSourceNoComments()
	Timer := RegExMatch(Source, "m)^SetTimer\(CheckKeyboardLayoutChange, _LAYOUT_POLL_INTERVAL_MS\)")
	Start := RegExMatch(Source, "m)^LayoutRegistryWatch_Start\(CheckKeyboardLayoutChange\)")
	AssertTrue(Timer > 0 && Start > Timer, "the entry starts the watch on the layout poll's capture, the poll kept")
	AssertTrue(InStr(_StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown")), "LayoutRegistryWatch_Stop()") > 0,
		"shutdown must stop the watch")
}

_LRWT_Join(Items) {
	Text := ""
	for Item in Items
		Text .= (A_Index == 1 ? "" : "|") . Item
	return Text
}

Test("layout registry watch: a notification runs the capture at once (layout-registry-watch-2026-11-11)",
	_LRWT_NotificationCapturesAtOnce)
Test("layout registry watch: a refused start leaks nothing (layout-registry-watch-2026-11-11)",
	_LRWT_RefusedStartLeaksNothing)
Test("layout registry watch: a private registry key notifies the capture (layout-registry-watch-2026-11-11)",
	_LRWT_NativeNotification)
Test("layout registry watch: the entry starts it and shutdown stops it (layout-registry-watch-2026-11-11)",
	_LRWT_DriverWiring)
