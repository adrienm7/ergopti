; tests/unit/modules/shortcuts/test_capsword_auto_off.ahk

; ==============================================================================
; MODULE: CapsWord Auto-Off Listeners
; DESCRIPTION:
; Drives modules/shortcuts/capsword_auto_off.ahk through the real
; HookDispatcher fan-out. Before [shortcuts.caps_word] existed, Windows ended
; CapsWord on Space, Enter and a left or right click only, whatever the user
; wanted: a middle click, an X button, a typed Tab or no-break space, the wheel
; and a pause left it latched, and an unchecked Space still ended it.
; ==============================================================================

#Requires AutoHotkey v2.0




global _CWAO_Ended := []

; Arms the listeners with a policy built for the test, every pointer kind off
; unless named, as ToggleCapsWord arms them, and records how CapsWord ends.
; @param Terminators {Array} Checked delimiter keys.
; @param Pointer {Map} Pointer kind -> 1 for the kinds to check.
; @param IdleSeconds {Number} The delay, 0 for never.
_CWAO_ArmWith(Terminators, Pointer := Map(), IdleSeconds := 0) {
	global CapsWordEnabled, _CWAO_Ended, _TimingsCache
	if !IsSet(_TimingsCache) || Type(_TimingsCache) != "Map"
		TimingsLoadShared()
	Kinds := CapsWordAutoOffPointerKinds()
	Values := Map()
	for Kind in Kinds
		Values[Kind] := Pointer.Get(Kind, 0)
	Policy := CapsWordAutoOffCompile(Map("idle_timeout_seconds", IdleSeconds,
		"terminators", Terminators, "pointer", Values), Kinds, &Reason)
	Assert(Policy is Map, "the test policy must compile: " . Reason)
	_CWAO_Ended := []
	CapsWordEnabled := true
	Saved := CapsWordAutoOff.Configured
	CapsWordAutoOff.Configured := Policy
	try CapsWordAutoOffArm(_CWAO_Recorder())
	finally CapsWordAutoOff.Configured := Saved
}

_CWAO_Recorder() {
	static Bound := _CWAO_Record.Bind()
	return Bound
}

; The test's DisableCapsWord: the stub clears the flag only.
_CWAO_Record(Reason, Kind) {
	global _CWAO_Ended, CapsWordEnabled
	_CWAO_Ended.Push(Map("reason", Reason, "kind", Kind))
	CapsWordEnabled := false
}

_CWAO_Reset() {
	global CapsWordEnabled := false
	CapsWordAutoOffDisarm()
}

_CWAO_ClearFlag() {
	global CapsWordEnabled := false
}

_CWAO_Char(Text) => HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, 0, Text)





; ======================================
; ======================================
; ======= 1/ Delimiters and keys =======
; ======================================
; ======================================

_CWAO_DefaultTabEnds() {
	try {
		_CWAO_ArmWith(ManifestDefaultFor("shortcuts.caps_word.terminators"))
		_CWAO_Char("a")
		AssertTrue(CapsWordEnabled, "a letter keeps CapsWord")
		_CWAO_Char("`t")
		AssertFalse(CapsWordEnabled, "a typed Tab ends CapsWord with the default delimiters")
		AssertEqual(1, _CWAO_Ended.Length, "CapsWord ends exactly once")
	} finally _CWAO_Reset()
}
Test("capsword auto-off: a typed Tab ends CapsWord by default", _CWAO_DefaultTabEnds)

_CWAO_UncheckedSpaceKeeps() {
	try {
		_CWAO_ArmWith(["enter"])
		AssertFalse(CapsWordAutoOffEndsOnNativeKey("space"),
			"an unchecked Space must leave its CapsWord hotkey ineligible, the key native")
		AssertTrue(CapsWordAutoOffEndsOnNativeKey("enter"), "a checked Enter keeps its hotkey")
		_CWAO_Char(" ")
		AssertTrue(CapsWordEnabled, "a typed space keeps CapsWord while space is unchecked")
	} finally _CWAO_Reset()
	AssertFalse(CapsWordAutoOffEndsOnNativeKey("enter"), "an inactive CapsWord claims no key")
}
Test("capsword auto-off: an unchecked Space keeps CapsWord", _CWAO_UncheckedSpaceKeeps)

_CWAO_NoBreakSpaces() {
	try {
		_CWAO_ArmWith(["nbsp"])
		_CWAO_Char(Chr(0x202F))
		AssertTrue(CapsWordEnabled, "an unchecked narrow no-break space keeps CapsWord")
		_CWAO_Char(Chr(0xA0))
		AssertFalse(CapsWordEnabled, "a checked no-break space ends CapsWord")
	} finally _CWAO_Reset()
	try {
		_CWAO_ArmWith(["colon"])
		_CWAO_Char(Chr(0xA0) . ":")
		AssertFalse(CapsWordEnabled, "a spaced colon carrier ends CapsWord through its checked colon")
	} finally _CWAO_Reset()
}
Test("capsword auto-off: the no-break spaces follow their own checkboxes", _CWAO_NoBreakSpaces)





; ================================
; ================================
; ======= 2/ Pointer kinds =======
; ================================
; ================================

_CWAO_PointerKindEnds(Event, Kind) {
	try {
		_CWAO_ArmWith([], Map(Kind, 1))
		HookDispatcher.Dispatch(Event)
		AssertFalse(CapsWordEnabled, Kind . " must end CapsWord when checked")
		AssertEqual(Kind, _CWAO_Ended[1]["kind"], "the end names its pointer kind")
	} finally _CWAO_Reset()
	try {
		_CWAO_ArmWith([], Map())
		HookDispatcher.Dispatch(Event)
		AssertTrue(CapsWordEnabled, Kind . " must keep CapsWord when unchecked")
	} finally _CWAO_Reset()
}

_CWAO_MiddleClick() => _CWAO_PointerKindEnds(HookDispatcherConst.EVT_MS_MDOWN, "middle_click")
Test("capsword auto-off: a middle click follows its checkbox", _CWAO_MiddleClick)

_CWAO_XButtons() {
	_CWAO_PointerKindEnds(HookDispatcherConst.EVT_MS_X1DOWN, "other_buttons")
	_CWAO_PointerKindEnds(HookDispatcherConst.EVT_MS_X2DOWN, "other_buttons")
}
Test("capsword auto-off: the X buttons follow the other-buttons checkbox", _CWAO_XButtons)

_CWAO_Wheel() {
	for Event in [HookDispatcherConst.EVT_MS_WUP, HookDispatcherConst.EVT_MS_WDN,
			HookDispatcherConst.EVT_MS_WLEFT, HookDispatcherConst.EVT_MS_WRIGHT]
		_CWAO_PointerKindEnds(Event, "pointer_motion")
}
Test("capsword auto-off: scrolling follows the pointer-motion checkbox", _CWAO_Wheel)

_CWAO_LeftRight() {
	_CWAO_PointerKindEnds(HookDispatcherConst.EVT_MS_LDOWN, "left_click")
	_CWAO_PointerKindEnds(HookDispatcherConst.EVT_MS_RDOWN, "right_click")
}
Test("capsword auto-off: left and right clicks follow their checkboxes", _CWAO_LeftRight)

; The Windows mapping and the manifest name the same kinds, both directions.
_CWAO_EveryKindIsMapped() {
	Declared := Map()
	for Kind in CapsWordAutoOffPointerKinds()
		Declared[Kind] := true
	Assert(Declared.Count >= 5, "the manifest must declare the Windows pointer kinds")
	Reached := Map(CapsWordAutoOffPolledKind(), true)
	for Event, Kind in CapsWordAutoOffPointerEvents()
		Reached[Kind] := true
	for Kind in Reached
		Assert(Declared.Has(Kind), "Windows maps '" . Kind . "', which the manifest does not declare for it")
	for Kind in Declared
		Assert(Reached.Has(Kind), "the manifest declares '" . Kind . "' for Windows and no Windows event reaches it")
	Assert(!Declared.Has("gesture"), "Windows never sees a touchpad gesture, so the manifest must not declare it here")
}
Test("capsword auto-off: every declared pointer kind has a Windows event, and only those", _CWAO_EveryKindIsMapped)





; =====================================
; =====================================
; ======= 3/ Delay and teardown =======
; =====================================
; =====================================

_CWAO_IdleTimeout() {
	try {
		_CWAO_ArmWith([], Map(), 0.3)
		Sleep(150)
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, 0, 0x41, 0x1E)
		Sleep(200)
		AssertTrue(CapsWordEnabled, "a keystroke restarts the delay")
		Sleep(400)
		AssertFalse(CapsWordEnabled, "CapsWord ends once the whole delay passes without a keystroke")
		AssertEqual("", _CWAO_Ended[1]["kind"], "the delay names no pointer kind")
	} finally _CWAO_Reset()
}
Test("capsword auto-off: CapsWord ends after the configured delay without a keystroke", _CWAO_IdleTimeout)

_CWAO_DisarmRemovesEverything() {
	try {
		_CWAO_ArmWith(["space"], Map("middle_click", 1), 0.2)
		AssertTrue(CapsWordAutoOff.Subscriptions.Length >= 3, "char, key-down and middle-click listeners are armed")
	} finally _CWAO_Reset()
	AssertEqual(0, CapsWordAutoOff.Subscriptions.Length, "disarming removes every subscription")
	AssertFalse(CapsWordAutoOff.IdleRunning, "disarming stops the delay")
	for Event in [HookDispatcherConst.EVT_KB_CHAR, HookDispatcherConst.EVT_KB_DOWN, HookDispatcherConst.EVT_MS_MDOWN] {
		for Callback in HookDispatcher._subscribers.Get(Event, [])
			for _, Bound in _CapsWordAutoOffCallbacks()
				Assert(Callback != Bound, Event . " still holds an auto-off listener")
	}
	Sleep(300)
	AssertEqual(0, _CWAO_Ended.Length, "a disarmed delay ends nothing")
}
Test("capsword auto-off: disarming removes every listener and timer", _CWAO_DisarmRemovesEverything)

_CWAO_FlagClearedElsewhere() {
	try {
		_CWAO_ArmWith(["space"])
		_CWAO_ClearFlag()
		_CWAO_Char(" ")
		AssertEqual(0, _CWAO_Ended.Length, "a CapsWord cleared elsewhere is not ended twice")
		AssertFalse(CapsWordAutoOff.Armed is Map, "its stale listener disarms itself")
	} finally _CWAO_Reset()
}
Test("capsword auto-off: a flag cleared without DisableCapsWord disarms on the next event", _CWAO_FlagClearedElsewhere)





; =======================================
; =======================================
; ======= 4/ Reading the settings =======
; =======================================
; =======================================

_CWAO_ReadConfigDefaultsAndOutdated() {
	Saved := CapsWordAutoOff.Configured
	try {
		CapsWordAutoOffReadConfig(Map())
		Policy := CapsWordAutoOff.Configured
		AssertEqual(0, CapsWordAutoOffIdleDelayMs(Policy), "no delay by default")
		for Key in ManifestDefaultFor("shortcuts.caps_word.terminators")
			AssertTrue(CapsWordAutoOffEndsOnKey(Policy, Key), Key . " is a default delimiter")
		for Kind in CapsWordAutoOffPointerKinds()
			AssertTrue(CapsWordAutoOffEndsOnPointer(Policy, Kind), Kind . " is on by default")
		CapsWordAutoOffReadConfig(Map(
			"shortcuts.caps_word", Map("idle_timeout_seconds", "5", "terminators", ["hyphen", "comma", "comma"]),
			"shortcuts.caps_word.pointer", Map("middle_click", 0, "left_click", "yes")))
		Policy := CapsWordAutoOff.Configured
		AssertEqual(0, CapsWordAutoOffIdleDelayMs(Policy), "a quoted delay is outdated and reads as the default")
		AssertTrue(CapsWordAutoOffEndsOnKey(Policy, "comma"), "the valid delimiter is kept once")
		AssertFalse(CapsWordAutoOffEndsOnKey(Policy, "space"), "a stored list replaces the default one")
		AssertFalse(CapsWordAutoOffEndsOnPointer(Policy, "middle_click"), "a stored false is read")
		AssertTrue(CapsWordAutoOffEndsOnPointer(Policy, "left_click"), "a non-boolean reads as the default")
	} finally CapsWordAutoOff.Configured := Saved
}
Test("capsword auto-off: settings read with defaults, outdated entries ignored", _CWAO_ReadConfigDefaultsAndOutdated)





; =====================================
; =====================================
; ======= 5/ Changing a setting =======
; =====================================
; =====================================

; Runs Body with the settings published as the defaults and restores them.
_CWAO_WithDefaultSettings(Body) {
	global ConfigurationFile
	SavedPolicy := CapsWordAutoOff.Configured, SavedValues := CapsWordAutoOff.Values
	OldConfig := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Fixture := _ScopeOwnerFixture()
	try {
		; The driver's writers own the configured file only.
		ConfigurationFile := Fixture.path
		CapsWordAutoOffReadConfig(Map())
		Body(Fixture)
	} finally {
		ConfigurationFile := IsSet(OldConfig) ? OldConfig : unset
		CapsWordAutoOff.Configured := SavedPolicy
		CapsWordAutoOff.Values := SavedValues
		_ScopeOwnerCleanup(Fixture)
	}
}

_CWAO_StoreWritesAndPublishes() {
	_CWAO_WithDefaultSettings(Body)
	Body(Fixture) {
		AssertTrue(CapsWordAutoOffStore("shortcuts.caps_word.terminators", ["space", "nbsp"], Fixture.path))
		AssertTrue(CapsWordAutoOffStore("shortcuts.caps_word.pointer.middle_click", false, Fixture.path))
		AssertTrue(CapsWordAutoOffStore("shortcuts.caps_word.idle_timeout_seconds", 5, Fixture.path))
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Stored := Parsed["shortcuts.caps_word"]
		AssertEqual("space,nbsp", _CWAOP_Join(Stored["terminators"]), "the delimiter list is written")
		AssertEqual(5, Stored["idle_timeout_seconds"], "the delay is written")
		AssertEqual(0, Parsed["shortcuts.caps_word.pointer"]["middle_click"], "the unchecked kind is written")
		Policy := CapsWordAutoOffCurrentPolicy()
		AssertTrue(CapsWordAutoOffEndsOnKey(Policy, "nbsp"), "the next activation uses the new delimiters")
		AssertFalse(CapsWordAutoOffEndsOnKey(Policy, "tab"), "an unchecked delimiter no longer ends CapsWord")
		AssertFalse(CapsWordAutoOffEndsOnPointer(Policy, "middle_click"), "the new pointer switch is live")
		AssertEqual(5000, CapsWordAutoOffIdleDelayMs(Policy), "the new delay is live")
		AssertTrue(CapsWordAutoOffStore("shortcuts.caps_word.pointer.middle_click", true, Fixture.path))
		AssertFalse(TOML_ParseFreshFile(Fixture.path)["shortcuts.caps_word.pointer"].Has("middle_click"),
			"a value equal to its default leaves the file")
	}
}
Test("capsword auto-off: a menu change is written and used by the next activation", _CWAO_StoreWritesAndPublishes)

_CWAO_StoreRefusals() {
	_CWAO_WithDefaultSettings(Body)
	Body(Fixture) {
		Before := CapsWordAutoOff.Configured
		AssertFalse(CapsWordAutoOffStore("shortcuts.caps_word.idle_timeout_seconds", 3, Fixture.directory),
			"the actual writer refuses a directory target")
		Assert(CapsWordAutoOff.Configured == Before, "a refused write publishes nothing")
		AssertThrows(() => CapsWordAutoOffStore("shortcuts.caps_word.pointer.gesture", true, Fixture.path),
			"Windows has no gesture kind to store")
		AssertThrows(() => CapsWordAutoOffStore("shortcuts.caps_word.terminators", ["hyphen"], Fixture.path),
			"an unknown delimiter is a defect, never written")
	}
}
Test("capsword auto-off: refused or invalid changes publish nothing", _CWAO_StoreRefusals)
