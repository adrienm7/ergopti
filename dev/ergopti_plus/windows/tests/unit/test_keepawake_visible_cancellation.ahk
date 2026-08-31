; tests/unit/test_keepawake_visible_cancellation.ahk
#Requires AutoHotkey v2.0

_KAV_KeyDown(VirtualKey) {
	DllCall("keybd_event", "UChar", VirtualKey, "UChar", 0, "UInt", 0, "UPtr", 0)
	Sleep(20)
}

_KAV_KeyUp(VirtualKey) {
	DllCall("keybd_event", "UChar", VirtualKey, "UChar", 0, "UInt", 0x2, "UPtr", 0)
	Sleep(20)
}

_KAV_Press(VirtualKey) {
	_KAV_KeyDown(VirtualKey)
	_KAV_KeyUp(VirtualKey)
}

_KAV_RunInEdit(InitialText, Body) {
	global ActivitySimulation, AwakeInputHook
	if !IsSet(ActivitySimulation)
		ActivitySimulation := false
	if !IsSet(AwakeInputHook)
		AwakeInputHook := ""
	AssertFalse(ActivitySimulation,
		"keep-awake cancellation tests require an idle production state")
	Assert(!IsObject(AwakeInputHook),
		"keep-awake cancellation tests require no pre-existing input hook")

	Target := Gui("+AlwaysOnTop", "ErgoptiPlus KeepAwake Visibility Test")
	TargetEdit := Target.AddEdit("w260 h40", InitialText)
	try {
		Target.Show("w300 h90")
		WinActivate("ahk_id " . Target.Hwnd)
		Assert(WinWaitActive("ahk_id " . Target.Hwnd, , 2),
			"the isolated edit must own focus before injecting a test key")
		TargetEdit.Focus()
		SendMessage(0xB1, -1, -1, TargetEdit.Hwnd)
		ActivitySimulation := true
		AwakeInputHook := AwakeCreateCancellationHook()
		AwakeInputHook.Start()
		Body.Call(TargetEdit)
		Sleep(80)
	} finally {
		; Never leak a synthetic modifier or observer into the shared test process.
		_KAV_KeyUp(0x11)
		if IsObject(AwakeInputHook)
			try AwakeInputHook.Stop()
		AwakeInputHook := ""
		ActivitySimulation := false
		try Target.Destroy()
	}
}

_KAV_PrintableCharacterRemainsVisible() {
	global ActivitySimulation
	_KAV_RunInEdit("", (Edit) => (
		_KAV_Press(0x41),
		AssertEqual("a", Edit.Value,
			"the printable cancellation key must reach the foreground edit"),
		AssertFalse(ActivitySimulation,
			"the printable key must cancel keep-awake")))
}

_KAV_NavigationKeyRemainsVisible() {
	global ActivitySimulation
	_KAV_RunInEdit("ab", (Edit) => (
		_KAV_Press(0x25),
		AssertFalse(ActivitySimulation,
			"the navigation key must cancel keep-awake"),
		_KAV_Press(0x43),
		AssertEqual("acb", Edit.Value,
			"Left must reach the edit before the observer stops")))
}

_KAV_ModifiedShortcutAndLaterCharacterRemainVisible() {
	global ActivitySimulation
	_KAV_RunInEdit("seed", (Edit) => (
		_KAV_KeyDown(0x11),
		_KAV_Press(0x41),
		_KAV_KeyUp(0x11),
		AssertTrue(ActivitySimulation,
			"the configured Ctrl-held path must keep observing"),
		_KAV_Press(0x42),
		AssertEqual("b", Edit.Value,
			"Ctrl+A and the later cancellation character must both reach the edit"),
		AssertFalse(ActivitySimulation,
			"the first unmodified character after Ctrl+A must cancel keep-awake")))
}

Test("keep-awake: printable cancellation remains visible (keepawake-visible-cancellation)",
	_KAV_PrintableCharacterRemainsVisible)
Test("keep-awake: navigation cancellation remains visible (keepawake-visible-cancellation)",
	_KAV_NavigationKeyRemainsVisible)
Test("keep-awake: modified shortcut and later cancellation remain visible (keepawake-visible-cancellation)",
	_KAV_ModifiedShortcutAndLaterCharacterRemainVisible)
