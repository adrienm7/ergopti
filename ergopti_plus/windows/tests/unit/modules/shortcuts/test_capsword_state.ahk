; tests/unit/modules/shortcuts/test_capsword_state.ahk

; ==============================================================================
; MODULE: CapsWord State Tests
; DESCRIPTION:
; Drives infra/capsword_state.ahk, the state machine behind ToggleCapsWord,
; DisableCapsWord and UpdateCapsLockLED, with its ports replaced: no hotkey is
; registered and the real CapsLock LED is never written. The auto-off listeners
; behind it are the real ones, so a delimiter typed through the HookDispatcher
; walks the whole path from the keystroke to the LED. These behaviour tests
; replace the former meta tests that read capsword.ahk as text.
; ==============================================================================

#Requires AutoHotkey v2.0




; Ports that record their calls in Log and model a held gesture click. The
; auto-off listeners are the real ones and end CapsWord through the state
; machine, as the module's end callback does.
; @param Log {Array} Receives one line per effect.
; @param Held {Map} "left" / "right" -> whether a gesture click-hold is active.
_CWS_Ports(Log, Held) {
	Ports := Map()
	Ports["set_led"] := (State) => Log.Push("led:" . State)
	Ports["nav_indicator"] := (Active) => Log.Push("nav:" . (Active ? "on" : "off"))
	Ports["left_held"] := () => Held["left"]
	Ports["right_held"] := () => Held["right"]
	Ports["release_left"] := () => (Log.Push("release_left"), Held["left"] := false)
	Ports["release_right"] := () => (Log.Push("release_right"), Held["right"] := false)
	Ports["arm"] := (Fn) => CapsWordAutoOffArm((Reason, Kind) => CapsWordHandleAutoOff(Reason, Kind, Ports))
	return Ports
}

; Runs Body with the manifest-default auto-off settings configured and the
; state globals clean, and restores everything.
_CWS_With(Body) {
	global CapsWordEnabled, LayerEnabled, _HardwareCapsLockOn, _TimingsCache
	if !IsSet(_TimingsCache) || Type(_TimingsCache) != "Map"
		TimingsLoadShared()
	SavedConfigured := CapsWordAutoOff.Configured
	SavedCaps := CapsWordEnabled, SavedLayer := LayerEnabled, SavedHardware := _HardwareCapsLockOn
	try {
		CapsWordAutoOffDisarm()
		CapsWordAutoOff.Configured := CapsWordAutoOffCompileConfig(Map())
		CapsWordEnabled := false, LayerEnabled := false, _HardwareCapsLockOn := false
		Body.Call()
	} finally {
		CapsWordEnabled := false
		CapsWordAutoOffDisarm()
		CapsWordAutoOff.Configured := SavedConfigured
		CapsWordEnabled := SavedCaps, LayerEnabled := SavedLayer, _HardwareCapsLockOn := SavedHardware
	}
}

_CWS_Join(Log) {
	Out := ""
	for Entry in Log
		Out .= (Out == "" ? "" : "|") . Entry
	return Out
}

_CWS_Count(Log, Line) {
	Count := 0
	for Entry in Log
		Count += Entry == Line ? 1 : 0
	return Count
}





; ==============================
; ==============================
; ======= 1/ Toggle, LED =======
; ==============================
; ==============================

_CWS_ToggleArmsAndDisarms() {
	Body() {
		global CapsWordEnabled
		Log := [], Held := Map("left", false, "right", false)
		Ports := _CWS_Ports(Log, Held)
		Ports["arm"] := (Fn) => Log.Push("arm:" . (Fn == CapsWordEndCallback() ? "end-callback" : "other"))
		Ports["disarm"] := () => Log.Push("disarm")
		CapsWordActivationToggle(Ports)
		AssertTrue(CapsWordEnabled, "the first toggle turns CapsWord on")
		AssertEqual("arm:end-callback", Log[1], "it arms the auto-off listeners with the module's end callback")
		AssertEqual("led:On", Log[2], "and lights the LED")
		CapsWordActivationToggle(Ports)
		AssertFalse(CapsWordEnabled, "the second toggle turns it off")
		AssertEqual("arm:end-callback|led:On|nav:off|disarm|led:Off|nav:off", _CWS_Join(Log),
			"the off toggle disarms the listeners and puts the LED out")
	}
	_CWS_With(Body)
}
Test("capsword state: a toggle arms with the end callback, lights the LED, and off disarms (capsword-state)",
	_CWS_ToggleArmsAndDisarms)

_CWS_EndCallbackIsParseTimeSafe() {
	Body() {
		global CapsWordEnabled
		First := CapsWordEndCallback()
		Assert(HasMethod(First, "Call"), "the end callback must be callable")
		Assert(First == CapsWordEndCallback(),
			"the end callback must be the same object every call: the auto-off listeners compare identities")
		; A key combination can toggle CapsWord before the configuration read.
		CapsWordAutoOff.Configured := ""
		Log := [], Held := Map("left", false, "right", false)
		Ports := _CWS_Ports(Log, Held)
		CapsWordActivationToggle(Ports)
		AssertTrue(CapsWordEnabled, "CapsWord turns on before the configuration was read")
		AssertTrue(CapsWordAutoOff.Armed is Map, "it arms with the manifest defaults instead of throwing")
		AssertTrue(CapsWordAutoOff.Subscriptions.Length > 0, "and the listeners are subscribed")
	}
	_CWS_With(Body)
}
Test("capsword state: the end callback is identity-stable and a toggle before the config read arms (capsword-parse-time)",
	_CWS_EndCallbackIsParseTimeSafe)

_CWS_DeactivateAlwaysDisarms() {
	Body() {
		global CapsWordEnabled
		Log := [], Held := Map("left", false, "right", false)
		Ports := _CWS_Ports(Log, Held)
		Ports["disarm"] := () => Log.Push("disarm")
		CapsWordEnabled := false
		CapsWordDeactivate(Ports)
		AssertEqual(1, _CWS_Count(Log, "disarm"), "disarming is unconditional so no listener or timer leaks")
		CapsWordEnabled := true
		CapsWordDeactivate(Ports)
		AssertFalse(CapsWordEnabled, "deactivation clears the flag the #HotIf criteria read")
		AssertEqual(2, _CWS_Count(Log, "disarm"))
		AssertEqual("led:Off", Log[Log.Length - 1], "and refreshes the LED")
	}
	_CWS_With(Body)
}
Test("capsword state: DisableCapsWord clears the flag, disarms and refreshes the LED (capsword-reset-on-suspend)",
	_CWS_DeactivateAlwaysDisarms)

_CWS_LedMatrix() {
	Body() {
		global CapsWordEnabled, LayerEnabled, _HardwareCapsLockOn
		for CapsWord in [false, true] {
			for Hardware in [false, true] {
				for Layer in [false, true] {
					CapsWordEnabled := CapsWord, _HardwareCapsLockOn := Hardware, LayerEnabled := Layer
					Log := []
					CapsWordSyncLed(_CWS_Ports(Log, Map("left", false, "right", false)))
					Name := "capsword=" . CapsWord . " hardware=" . Hardware . " layer=" . Layer
					AssertEqual((CapsWord || Hardware) ? "led:On" : "led:Off", Log[1],
						"the LED follows CapsWord or the genuine CapsLock intent only (" . Name . ")")
					AssertEqual(Layer ? "nav:on" : "nav:off", Log[2],
						"the navigation layer has its own indicator and never lights the LED (" . Name . ")")
				}
			}
		}
	}
	_CWS_With(Body)
}
Test("capsword state: the LED is lit by CapsWord or genuine CapsLock intent, never by the nav layer (capslock-led)",
	_CWS_LedMatrix)

_CWS_GenuineIntentSurvivesCapsWord() {
	Body() {
		global CapsWordEnabled, _HardwareCapsLockOn
		Log := [], Held := Map("left", false, "right", false)
		Ports := _CWS_Ports(Log, Held)
		_HardwareCapsLockOn := true
		CapsWordActivationToggle(Ports)
		CapsWordActivationToggle(Ports)
		AssertEqual("led:On", Log[Log.Length - 1], "the user's own CapsLock stays on after CapsWord ends")
		_HardwareCapsLockOn := false
		CapsWordActivationToggle(Ports)
		CapsWordDeactivate(Ports)
		AssertEqual("led:Off", Log[Log.Length - 1],
			"CapsWord alone leaves nothing latched: CapsLock must not survive it")
	}
	_CWS_With(Body)
}
Test("capsword state: CapsWord neither clears a genuine CapsLock nor leaves one behind (capslock-led-does-not-latch)",
	_CWS_GenuineIntentSurvivesCapsWord)





; ============================
; ============================
; ======= 2/ End paths =======
; ============================
; ============================

_CWS_PointerReleasesHeldClicks() {
	Body() {
		Cases := [["left_click"], ["right_click"], ["middle_click"], ["other_buttons"], ["pointer_motion"], [""]]
		for Entry in Cases {
			Log := [], Held := Map("left", true, "right", true)
			Ports := _CWS_Ports(Log, Held)
			CapsWordHandleAutoOff("test", Entry[1], Ports)
			if Entry[1] == "left_click" {
				AssertTrue(_CWS_Count(Log, "release_left") == 1 && _CWS_Count(Log, "release_right") == 1,
					"a click ends CapsWord only after letting go of the gesture click-hold(s)")
			} else if Entry[1] == "right_click" {
				AssertTrue(_CWS_Count(Log, "release_left") == 1 && _CWS_Count(Log, "release_right") == 1,
					"a right click lets go of both holds, as the click handler always did")
			} else {
				AssertEqual(0, _CWS_Count(Log, "release_left") + _CWS_Count(Log, "release_right"),
					"'" . Entry[1] . "' must leave a gesture click-hold alone")
			}
			AssertEqual(1, _CWS_Count(Log, "led:Off"), "every end path puts the LED out ('" . Entry[1] . "')")
		}
		Log := [], Held := Map("left", false, "right", false)
		CapsWordHandleAutoOff("test", "left_click", _CWS_Ports(Log, Held))
		AssertEqual(0, _CWS_Count(Log, "release_left"), "nothing is released when no click is held")
	}
	_CWS_With(Body)
}
Test("capsword state: a click lets go of a held gesture click, other ends leave it (capsword-click-hold)",
	_CWS_PointerReleasesHeldClicks)

; Types every character of a delimiter through the real listeners.
_CWS_TypeKey(Key) {
	Chars := ""
	for Entry in Terminators().all() {
		if Entry.Get("type", "") != "separator" && Entry["key"] == Key
			Chars := Entry["chars"]
	}
	Assert(Chars != "", "the catalogue must define the delimiter '" . Key . "'")
	return Chars
}

_CWS_EightDefaultDelimiters() {
	Body() {
		global CapsWordEnabled
		Defaults := ManifestDefaultFor("shortcuts.caps_word.terminators")
		AssertEqual(8, Defaults.Length, "the manifest ships eight default delimiters")
		for Key in Defaults {
			for Char in _CWS_TypeKey(Key) {
				Log := [], Held := Map("left", false, "right", false)
				Ports := _CWS_Ports(Log, Held)
				CapsWordActivationToggle(Ports)
				HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, 0, "a")
				AssertTrue(CapsWordEnabled, "a letter keeps CapsWord before '" . Key . "'")
				HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, 0, Char)
				AssertFalse(CapsWordEnabled, "the default delimiter '" . Key . "' (U+"
					. Format("{:04X}", Ord(Char)) . ") ends CapsWord")
				AssertEqual("led:Off", Log[Log.Length - 1], "and puts the LED out for '" . Key . "'")
				AssertFalse(CapsWordAutoOff.Armed is Map, "and disarms the listeners for '" . Key . "'")
			}
		}
		for Char in ["a", "Z", "5", "-", "_", "'", "é"] {
			Log := [], Held := Map("left", false, "right", false)
			CapsWordActivationToggle(_CWS_Ports(Log, Held))
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, 0, Char)
			AssertTrue(CapsWordEnabled, "'" . Char . "' is no default delimiter and keeps CapsWord")
			CapsWordDeactivate(_CWS_Ports(Log, Held))
		}
	}
	_CWS_With(Body)
}
Test("capsword state: each of the eight default delimiters ends CapsWord, other characters keep it (capsword-delimiters)",
	_CWS_EightDefaultDelimiters)

_CWS_NativeSpaceAndEnter() {
	Body() {
		global CapsWordEnabled
		Sent := []
		SendFn := (Key, Mods) => Sent.Push(Key)
		WaitFn := (Key, Opts) => Sent.Push("wait:" . Key)
		for Key in ["space", "enter"] {
			Log := [], Held := Map("left", false, "right", false)
			CapsWordActivationToggle(_CWS_Ports(Log, Held))
			AssertTrue(CapsWordAutoOffEndsOnNativeKey(Key), "the default settings make the native " . Key . " hotkey eligible")
			CapsWordAutoOffNativeKey(StrTitle(Key), SendFn, WaitFn)
			AssertFalse(CapsWordEnabled, "the native " . Key . " delimiter ends CapsWord")
			AssertEqual("led:Off", Log[Log.Length - 1], "and puts the LED out")
		}
		AssertEqual("Space|wait:SC039|Enter", _CWS_Join(Sent), "each delimiter is sent once, only Space waiting for its release")
	}
	_CWS_With(Body)
}
Test("capsword state: the native Space and Enter hotkeys end CapsWord through the state machine (capsword-native)",
	_CWS_NativeSpaceAndEnter)

_CWS_EachPointerKindByDefault() {
	Body() {
		global CapsWordEnabled
		for Event, Kind in CapsWordAutoOffPointerEvents() {
			Log := [], Held := Map("left", Kind == "left_click", "right", Kind == "right_click")
			CapsWordActivationToggle(_CWS_Ports(Log, Held))
			HookDispatcher.Dispatch(Event)
			AssertFalse(CapsWordEnabled, "the default settings end CapsWord on a '" . Kind . "' event")
			AssertEqual(Kind == "left_click" ? 1 : 0, _CWS_Count(Log, "release_left"),
				"a '" . Kind . "' end releases a held left click only for the left button")
			AssertEqual("led:Off", Log[Log.Length - 1])
		}
		; The pointer-motion poll sees a move the wheel events never report.
		Log := [], Held := Map("left", false, "right", false)
		CapsWordActivationToggle(_CWS_Ports(Log, Held))
		AssertTrue(CapsWordAutoOff.MotionRunning, "the motion poll runs while CapsWord is active")
		CapsWordAutoOff.LastPointer := "-1,-1"
		CapsWordAutoOff.Callbacks["motion"].Call()
		AssertFalse(CapsWordEnabled, "a moved pointer ends CapsWord")
		AssertFalse(CapsWordAutoOff.MotionRunning, "and the poll stops with it")
	}
	_CWS_With(Body)
}
Test("capsword state: every pointer kind ends CapsWord by default, a poll catches pointer motion (capsword-pointer)",
	_CWS_EachPointerKindByDefault)

_CWS_DefaultDelayIsArmedAndStopsWithIt() {
	Body() {
		Log := [], Held := Map("left", false, "right", false)
		CapsWordActivationToggle(_CWS_Ports(Log, Held))
		AssertEqual(10000, CapsWordAutoOff.Armed["idle_ms"], "the default delay is ten seconds")
		AssertTrue(CapsWordAutoOff.IdleRunning, "the delay timer runs while CapsWord is active")
		CapsWordDeactivate(_CWS_Ports(Log, Held))
		AssertFalse(CapsWordAutoOff.IdleRunning, "a deactivation stops the delay timer")
		AssertFalse(CapsWordAutoOff.MotionRunning, "and the motion poll")
	}
	_CWS_With(Body)
}
Test("capsword state: the default delay arms with CapsWord and stops with it (capsword-delay)",
	_CWS_DefaultDelayIsArmedAndStopsWithIt)
