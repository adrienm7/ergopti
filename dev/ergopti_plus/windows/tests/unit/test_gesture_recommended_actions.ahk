; tests/unit/test_gesture_recommended_actions.ahk

; ==============================================================================
; MODULE: Recommended Gesture Actions Come From The Manifest
; DESCRIPTION:
; « Restaurer les valeurs conseillées » under Gestures writes
; GESTURE_FACTORY_DEFAULTS to every slot. That map was a hand copy of the
; manifest's Windows values, with a comment promising it mirrored them and
; nothing holding it to the promise; the macOS twin had already drifted. It is
; built from the manifest now, and this checks every slot against the generated
; manifest entry directly.
; ==============================================================================

#Requires AutoHotkey v2.0

_GRA_EverySlotIsTheManifestValue() {
	global GESTURE_FACTORY_DEFAULTS, FEATURES_MANIFEST
	Expected := Map()
	for Entry in FEATURES_MANIFEST["features"] {
		if (Entry["section"] == "gestures" and Entry["type"] == "action")
			Expected[Entry["id"]] := Entry["recommended"]
	}
	Slots := GestureSlotIds()
	Assert(Slots.Length >= 10, "GestureSlotIds() must list every Windows slot, got " . Slots.Length)
	AssertEqual(Slots.Length, GESTURE_FACTORY_DEFAULTS.Count,
		"GESTURE_FACTORY_DEFAULTS must hold exactly the Windows slots")
	for Slot in Slots {
		Assert(Expected.Has(Slot), "the manifest must declare a Windows default for gestures." . Slot)
		Assert(GESTURE_FACTORY_DEFAULTS.Has(Slot), "GESTURE_FACTORY_DEFAULTS must cover " . Slot)
		AssertEqual(Expected[Slot], GESTURE_FACTORY_DEFAULTS[Slot],
			"gestures." . Slot . " must be the manifest's Windows recommended action")
	}
	AssertEqual("none", ManifestDefaultFor("gestures.tap_3"), "startup stays neutral")
	AssertEqual("left_click_toggle", GESTURE_FACTORY_DEFAULTS["tap_3"], "explicit restore remains useful")
}
Test("gestures: the recommended actions are the manifest's Windows values (gesture-defaults-single-source)",
	_GRA_EverySlotIsTheManifestValue)

; The recommendation is a product contract, not just equality between copies.
_GRA_FourFingerTapImportsMonitorSwitch() {
	global GESTURE_FACTORY_DEFAULTS
	AssertEqual("alt_tab_monitor", GESTURE_FACTORY_DEFAULTS["tap_4"])
	AssertEqual("none", ManifestDefaultFor("gestures.tap_4"), "new configurations remain opt-in")
	Index := OnboardingCatalogue()
	Entry := Index["entries"]["gestures.tap_4"]
	AssertEqual("alt_tab_monitor", Entry["value"], "the wizard imports the same monitor action")
	Rows := OnboardingAnswerRows(Index, [Map("path", "gestures.tap_4", "value", Entry["value"])])
	Assert(Rows is Array, "the actual wizard answer must be admitted")
	AssertEqual(1, Rows.Length)
	AssertEqual("gestures", Rows[1].Section)
	AssertEqual("tap_4", Rows[1].Key)
	AssertEqual("alt_tab_monitor", Rows[1].Value)
}
Test("gestures: four-finger tap recommends monitor Alt-Tab in restore and wizard", _GRA_FourFingerTapImportsMonitorSwitch)

_GRA_FourFingerTapKeepsPersonalAssignment() {
	global _IniCache, GestureAssignments, GestureActionParameters
	OldCache := _IniCache, OldAssignments := GestureAssignments, OldParameters := GestureActionParameters
	try {
		_IniCache := Map("gestures", Map("tap_4", "copy"))
		GestureAssignments := Map("tap_4", "none")
		GesturesReadConfig()
		AssertEqual("copy", GestureAssignments["tap_4"], "a changed recommendation never replaces a personal action")
		AssertEqual("copy", _IniCache["gestures"]["tap_4"], "the saved user intent remains unchanged")
	} finally {
		_IniCache := OldCache, GestureAssignments := OldAssignments, GestureActionParameters := OldParameters
	}
}
Test("gestures: loading preserves a personal four-finger tap", _GRA_FourFingerTapKeepsPersonalAssignment)

; Exercise the real catalogue callback and native cycler on two owned windows.
_GRA_FourFingerTapActivatesPreviousWindow() {
	global GESTURE_FACTORY_DEFAULTS
	AssertEqual("alt_tab_monitor", GESTURE_FACTORY_DEFAULTS["tap_4"])
	Prior := WinExist("A"), OldMouseMode := A_CoordModeMouse
	CoordMode("Mouse", "Screen")
	MouseGetPos(&OldX, &OldY)
	First := Gui(, "Monitor tap: previous owned window")
	Second := 0
	try {
		Second := Gui(, "Monitor tap: current owned window")
		MonitorGetWorkArea(MonitorGetPrimary(), &Left, &Top, &Right, &Bottom)
		X := Left + 30, Y := Top + 30
		First.Show("x" . X . " y" . Y . " w320 h220")
		Second.Show("x" . X . " y" . Y . " w320 h220")
		WinActivate(First.Hwnd)
		Assert(WinWaitActive(First.Hwnd, , 2), "the previous window must actually receive focus")
		WinActivate(Second.Hwnd)
		Assert(WinWaitActive(Second.Hwnd, , 2), "the current window must actually receive focus")
		MouseMove(X + 100, Y + 100, 0)
		GestureInvokeAction(GESTURE_FACTORY_DEFAULTS["tap_4"], GestureBindingId("gesture", "tap_4"))
		Assert(WinWaitActive(First.Hwnd, , 2), "the recommended gesture must activate the previous window on this monitor")
	} finally {
		if IsObject(Second)
			Second.Destroy()
		First.Destroy()
		MouseMove(OldX, OldY, 0)
		CoordMode("Mouse", OldMouseMode)
		if Prior && WinExist(Prior)
			WinActivate(Prior)
	}
}
Test("gestures: the four-finger recommendation invokes native monitor Alt-Tab", _GRA_FourFingerTapActivatesPreviousWindow)
