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

; Escape, the arrows, Delete, Home/End, Page Up/Down and F1-F12 end CapsWord
; whatever the delimiters, as macOS's fixed exits do (capsword-fixed-exits).
_CWAO_FixedExits() {
	for Vk in [0x1B, 0x25, 0x26, 0x2E, 0x24, 0x23, 0x21, 0x22, 0x74, 0x7B] {
		try {
			_CWAO_ArmWith([], Map(), 0)
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, 0, Vk, 0)
			AssertFalse(CapsWordEnabled, Format("VK {:#x} ends CapsWord with no delimiter or delay", Vk))
		} finally _CWAO_Reset()
	}
	try {
		_CWAO_ArmWith([], Map(), 0)
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, 0, 0x08, 0x0E)
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, 0, 0x41, 0x1E)
		AssertTrue(CapsWordEnabled, "control: Backspace and a letter keep CapsWord on")
	} finally _CWAO_Reset()
}
Test("capsword auto-off: the editing and navigation keys always end CapsWord (capsword-fixed-exits)", _CWAO_FixedExits)

; A modifier pressed alone is no keystroke for the delay, as on macOS and
; Linux (capsword-modifier-activity).
_CWAO_ModifierIsNoActivity() {
	try {
		_CWAO_ArmWith([], Map(), 0.3)
		Sleep(150)
		HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, 0, 0xA0, 0x2A)
		Sleep(250)
		AssertFalse(CapsWordEnabled, "a lone Shift does not restart the delay")
	} finally _CWAO_Reset()
}
Test("capsword auto-off: a lone modifier does not restart the delay (capsword-modifier-activity)", _CWAO_ModifierIsNoActivity)

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
		AssertEqual(10000, CapsWordAutoOffIdleDelayMs(Policy), "10 s by default (maintainer decision of 2026-10-20)")
		for Key in ManifestDefaultFor("shortcuts.caps_word.terminators")
			AssertTrue(CapsWordAutoOffEndsOnKey(Policy, Key), Key . " is a default delimiter")
		for Kind in CapsWordAutoOffPointerKinds()
			AssertTrue(CapsWordAutoOffEndsOnPointer(Policy, Kind), Kind . " is on by default")
		CapsWordAutoOffReadConfig(Map(
			"shortcuts.caps_word", Map("idle_timeout_seconds", "5", "terminators", ["hyphen", "comma", "comma"]),
			"shortcuts.caps_word.pointer", Map("middle_click", 0, "left_click", "yes")))
		Policy := CapsWordAutoOff.Configured
		AssertEqual(10000, CapsWordAutoOffIdleDelayMs(Policy), "a quoted delay is outdated and reads as the default")
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





; ==========================================
; ==========================================
; ======= 6/ Output the driver sends =======
; ==========================================
; ==========================================

; Before the auto-off owned what the driver sends, a period, comma or
; semicolon typed by the layout emulation's layers or dead keys, a hotstring,
; the magic key or an accepted prediction went out at SendLevel 0, through
; SendInput or a paste, and CapsWord stayed on: the InputHook never saw them.

; Runs Emit with CapsWord armed on the shipped delimiters and every send seam
; recording instead of typing; returns whether CapsWord survived.
_CWAO_SurvivesEmit(Emit) {
	global _SendHook, CapsWordEnabled
	SavedHook := _SendHook
	try {
		_SendHook := (*) => true
		_CWAO_ArmWith(ManifestDefaultFor("shortcuts.caps_word.terminators"))
		Emit()
		return CapsWordEnabled
	} finally {
		_SendHook := SavedHook
		_CWAO_Reset()
	}
}

_CWAO_ObservedOutput() {
	for Text in [".", ",", ";"] {
		AssertTrue(_CWAO_SurvivesEmit(() => 0), "nothing sent keeps CapsWord")
		AssertFalse(_CWAO_SurvivesEmit(CapsWordAutoOffObserveOutput.Bind("etc" . Text)),
			"sent output ending in '" . Text . "' ends CapsWord")
	}
	AssertTrue(_CWAO_SurvivesEmit(CapsWordAutoOffObserveOutput.Bind("ABC")), "letters keep CapsWord")
	AssertTrue(_CWAO_SurvivesEmit(CapsWordAutoOffObserveOutput.Bind("Space")),
		"a key name the ring records is no delimiter")
}
Test("capsword auto-off: a delimiter in the driver's own output ends CapsWord", _CWAO_ObservedOutput)

_CWAO_SendNewResultEnds() {
	AssertFalse(_CWAO_SurvivesEmit(() => SendNewResult("M.", true)),
		"a layer, AltGr or dead-key emit through SendNewResult ends CapsWord on its period")
	AssertTrue(_CWAO_SurvivesEmit(() => SendNewResult(" ", true, false)),
		"a temporary poke the ring does not record (ActivateHotstrings) never ends it")
	AssertTrue(_CWAO_SurvivesEmit(() => SendNewResult("{BackSpace}", false)), "key syntax is no text")
}
Test("capsword auto-off: SendNewResult's recorded text ends CapsWord", _CWAO_SendNewResultEnds)

_CWAO_SendFinalResultEnds() {
	AssertFalse(_CWAO_SurvivesEmit(() => SendFinalResult("a, b", true)),
		"text sent through SendInput ends CapsWord on its comma")
	AssertTrue(_CWAO_SurvivesEmit(() => SendFinalResult("!{Tab}", false)),
		"a chord in key syntax is no exclamation mark")
}
Test("capsword auto-off: SendFinalResult's text ends CapsWord", _CWAO_SendFinalResultEnds)

_CWAO_SendInstantEnds() {
	AssertFalse(_CWAO_SurvivesEmit(() => SendInstant("voilà`; fin", "{BackSpace}")),
		"a pasted expansion ends CapsWord on its semicolon")
}
Test("capsword auto-off: SendInstant's pasted text ends CapsWord", _CWAO_SendInstantEnds)

_CWAO_TextSendEnds() {
	AssertFalse(_CWAO_SurvivesEmit(() => TextSend("oui.", Map("mode", "direct"), 0)),
		"TextSender output (magic key, correction, prediction) ends CapsWord on its period")
	AssertTrue(_CWAO_SurvivesEmit(() => TextSend("oui", Map("mode", "direct"), 0)),
		"TextSender letters keep CapsWord")
}
Test("capsword auto-off: TextSender output ends CapsWord", _CWAO_TextSendEnds)

_CWAO_HotstringEffectEnds() {
	Emit() {
		Previous := Critical("On")
		try _HSE_MirrorCanonicalEffectToLlm({ IsPrivate: false, DeleteFromEnd: 3, InsertedText: "c'est-à-dire," })
		finally Critical(Previous)
	}
	AssertFalse(_CWAO_SurvivesEmit(Emit), "a hotstring expansion ends CapsWord on the comma it inserts")
}
Test("capsword auto-off: a hotstring expansion's inserted text ends CapsWord", _CWAO_HotstringEffectEnds)

; The ring owner the layout emulation feeds is stubbed in this runner, so its
; reporting is held by source: every emit that reached the screen passes there.
_CWAO_RingReportsOutput() {
	Body := _StripFullLineComments(_DriverFuncBody("UpdateLastSentCharacter"))
	Assert(Body != "", "UpdateLastSentCharacter must exist")
	Assert(InStr(Body, "CapsWordAutoOffObserveOutput(Character)") > InStr(Body, "_LSCPush(Character)"),
		"the ring of sent characters must report each recorded character to the CapsWord auto-off")
}
Test("capsword auto-off: the ring of sent characters reports to CapsWord", _CWAO_RingReportsOutput)

#Include test_capsword_auto_off_ownership.ahk

; Append to tests/unit/modules/shortcuts/test_capsword_auto_off.ahk.
_CWAOD_End(State, Reason, Kind) {
    global CapsWordEnabled
    State["ends"] += 1
    State["reason"] := Reason
    CapsWordEnabled := false
}
_CWAOD_Case(Name, Seconds) {
    global CapsWordEnabled, _TimingsCache
    AssertFalse(CapsWordAutoOff.Armed is Map, "do not borrow an active CapsWord")
    AssertEqual(0, CapsWordAutoOff.Subscriptions.Length)
    Saved := {Enabled: CapsWordEnabled, Configured: CapsWordAutoOff.Configured,
        Values: CapsWordAutoOff.Values, Critical: A_IsCritical, Suspended: A_IsSuspended}
    State := Map("ends", 0, "reason", "")
    Receipt := Map("case", Name, "input_type", Type(Seconds), "input_seconds", String(Seconds))
    Primary := 0, CleanupIssues := []
    try {
        Critical("Off"), Suspend(false)
        if !IsSet(_TimingsCache) || !(_TimingsCache is Map)
            TimingsLoadShared()
        Pointer := Map()
        for Kind in CapsWordAutoOffPointerKinds()
            Pointer[Kind] := 0
        Cache := Map("shortcuts.caps_word", Map("idle_timeout_seconds", Seconds, "terminators", []),
            "shortcuts.caps_word.pointer", Pointer)
        Accepted := CapsWordAutoOffValidateIdleTimeout(Seconds, &Reason)
        Receipt["validator_accepted"] := Accepted
        Receipt["validator_reason"] := Reason
        NativeAccepted := Accepted
        if NativeAccepted && Seconds > 0 {
            NativeMs := TimerDelayMsFromSeconds(Seconds)
            NativeAccepted := NativeMs is Number
            if NativeAccepted {
                try TimerRequireDelayMs(NativeMs, "CapsWord domain fixture expectation")
                catch ValueError
                    NativeAccepted := false
            }
        }
        Receipt["native_period_supported"] := NativeAccepted
        Values := CapsWordAutoOffReadValues(Cache)
        Receipt["read_seconds"] := String(Values["idle_timeout_seconds"])
        ReadError := 0, ArmError := 0
        try CapsWordAutoOffReadConfig(Cache)
        catch Any as Failure
            ReadError := Failure
        Receipt["read_error"] := IsObject(ReadError) ? Type(ReadError) : ""
        if !IsObject(ReadError) {
            Policy := CapsWordAutoOffCurrentPolicy()
            Idle := CapsWordAutoOffIdleDelayMs(Policy)
            Receipt["idle_ms"] := String(Idle)
            Receipt["idle_positive_finite"] := Idle > 0 && Idle - Idle == 0
            Receipt["expires_after_one_ms"] := CapsWordAutoOffIdleExpired(Policy, 1000, 1001)
            CapsWordEnabled := true
            try CapsWordAutoOffArm(_CWAOD_End.Bind(State))
            catch Any as Failure
                ArmError := Failure
            Receipt["arm_error"] := IsObject(ArmError) ? Type(ArmError) : ""
            Receipt["armed"] := CapsWordAutoOff.Armed is Map
            Receipt["idle_running"] := CapsWordAutoOff.IdleRunning
            Receipt["subscriptions"] := CapsWordAutoOff.Subscriptions.Length
            if Name == "ordinary" && !IsObject(ArmError) {
                Started := A_TickCount
                while State["ends"] == 0 && TickElapsed(Started) < 1000
                    Sleep(1)
            }
            Receipt["ends"] := State["ends"]
        }
        _TestPrint("# CAPSWORD_IDLE_DOMAIN " . KL_JsonEncode(Receipt))
        AssertFalse(IsObject(ReadError), "a value admitted or explicitly defaulted by the public reader must compile")
        if NativeAccepted {
            AssertEqual(Seconds, Values["idle_timeout_seconds"], "an accepted value must reach the real policy unchanged")
            AssertTrue(Receipt["idle_positive_finite"], "a positive accepted configuration must not overflow into disabled/negative/nonfinite policy")
            AssertFalse(Receipt["expires_after_one_ms"], "a positive accepted duration above one millisecond cannot immediately expire")
        } else {
            if !Accepted
                AssertEqual("invalid_idle_timeout", Reason, "shared validation retains its stable refusal reason")
            DefaultSeconds := ManifestDefaultFor(ConfigKey.SHORTCUTS_CAPS_WORD_IDLE_TIMEOUT_SECONDS)
            AssertEqual(DefaultSeconds, Values["idle_timeout_seconds"], "the existing reader explicitly defaults a refused duration")
            DefaultPolicy := CapsWordAutoOffCompileConfig(Map())
            AssertEqual(CapsWordAutoOffIdleDelayMs(DefaultPolicy), Idle, "refusal must retain the genuine manifest default policy, including a disabled default")
        }
        AssertFalse(IsObject(ArmError), "a published policy must be armable through the genuine native timer boundary")
        AssertTrue(Receipt["armed"], "the activation must own its real compiled policy")
        AssertEqual(Idle > 0, Receipt["idle_running"], "idle ownership must match the admitted policy; zero explicitly disables the timer")
        if Name == "ordinary"
            AssertEqual(1, State["ends"], "the ordinary control must actually deliver the native timer once")
        else
            AssertEqual(0, State["ends"], "a huge delay cannot turn into an immediate end")
    } catch Any as Failure {
        Primary := Failure
    } finally {
        try {
            CapsWordEnabled := false
            CapsWordAutoOffDisarm()
            AssertFalse(CapsWordAutoOff.Armed is Map)
            AssertEqual(0, CapsWordAutoOff.Subscriptions.Length)
            AssertFalse(CapsWordAutoOff.IdleRunning)
            AssertFalse(CapsWordAutoOff.MotionRunning)
        } catch Any as Failure {
            CleanupIssues.Push(Map("error", Type(Failure), "message", SubStr(Failure.Message, 1, 200)))
            if !IsObject(Primary)
                Primary := Failure
        }
        CapsWordAutoOff.Configured := Saved.Configured
        CapsWordAutoOff.Values := Saved.Values
        CapsWordEnabled := Saved.Enabled
        Suspend(Saved.Suspended), Critical(Saved.Critical)
        if CleanupIssues.Length
            _TestPrint("# CAPSWORD_IDLE_DOMAIN_CLEANUP " . KL_JsonEncode(CleanupIssues))
    }
    if IsObject(Primary)
        throw Primary
}
Test("CapsWord idle domain: ordinary config reaches its native timer (capsword-idle-domain)", _CWAOD_Case.Bind("ordinary", 0.05))
Test("CapsWord idle domain: finite integer seconds cannot wrap into disabled policy (capsword-idle-domain)",
    _CWAOD_Case.Bind("integer_overflow", 1 << 62))
Test("CapsWord idle domain: finite float seconds cannot overflow its compiled delay (capsword-idle-domain)",
    _CWAOD_Case.Bind("float_overflow", 1e308))

; Append one independent case beside the existing domain probes.
_CWAOD_TinyPositive() {
    global CapsWordEnabled, _TimingsCache
    AssertFalse(CapsWordAutoOff.Armed is Map, "do not borrow an active CapsWord")
    Saved := {Enabled: CapsWordEnabled, Configured: CapsWordAutoOff.Configured,
        Values: CapsWordAutoOff.Values, Critical: A_IsCritical, Suspended: A_IsSuspended}
    Results := [], Primary := 0
    try {
        Critical("Off"), Suspend(false)
        if !IsSet(_TimingsCache) || !(_TimingsCache is Map)
            TimingsLoadShared()
        Pointer := Map()
        for Kind in CapsWordAutoOffPointerKinds()
            Pointer[Kind] := 0
        for Seconds in [0, 0.0001] {
            State := Map("ends", 0, "reason", "")
            CapsWordAutoOffReadConfig(Map("shortcuts.caps_word", Map("idle_timeout_seconds", Seconds, "terminators", []),
                "shortcuts.caps_word.pointer", Pointer))
            Delay := CapsWordAutoOffIdleDelayMs(CapsWordAutoOffCurrentPolicy())
            CapsWordEnabled := true
            CapsWordAutoOffArm(_CWAOD_End.Bind(State))
            Started := A_TickCount
            if Seconds == 0
                Sleep(30)
            else {
                while State["ends"] == 0 && TickElapsed(Started) < 500
                    Sleep(1)
            }
            Results.Push(Map("seconds", Seconds, "idle_ms", String(Delay), "ends", State["ends"],
                "idle_running_after_wait", CapsWordAutoOff.IdleRunning, "enabled_after_wait", CapsWordEnabled))
            CapsWordEnabled := false
            CapsWordAutoOffDisarm()
        }
        _TestPrint("# CAPSWORD_TINY_POSITIVE " . KL_JsonEncode(Results))
        AssertEqual("0", Results[1]["idle_ms"], "exact zero alone explicitly disables inactivity")
        AssertEqual(0, Results[1]["ends"], "the zero control has no timer callback")
        AssertFalse(Results[1]["idle_running_after_wait"])
        AssertTrue(Results[1]["enabled_after_wait"], "zero leaves the activation enabled")
        AssertTrue(Number(Results[2]["idle_ms"]) > 0, "a positive stored duration cannot silently disable inactivity")
        AssertEqual(1, Results[2]["ends"], "the tiny positive duration must actually deliver its real native timer once")
        AssertFalse(Results[2]["enabled_after_wait"])
    } catch Any as Failure {
        Primary := Failure
    } finally {
        try {
            CapsWordEnabled := false
            CapsWordAutoOffDisarm()
            AssertEqual(0, CapsWordAutoOff.Subscriptions.Length)
            AssertFalse(CapsWordAutoOff.IdleRunning)
        } catch Any as Failure {
            _TestPrint("# CAPSWORD_TINY_CLEANUP " . Type(Failure) . ": " . Failure.Message)
            if !IsObject(Primary)
                Primary := Failure
        }
        CapsWordAutoOff.Configured := Saved.Configured
        CapsWordAutoOff.Values := Saved.Values
        CapsWordEnabled := Saved.Enabled
        Suspend(Saved.Suspended), Critical(Saved.Critical)
    }
    if IsObject(Primary)
        throw Primary
}
Test("CapsWord idle domain: positive submillisecond delay differs from explicit zero (capsword-tiny-positive)", _CWAOD_TinyPositive)

; Append two independent public writer regressions; reuses owned existing fixture.
_CWAODS_Body(Seconds, Fixture) {
    BeforeBytes := FSReadUtf8Exact(Fixture.path)
    BeforePolicy := CapsWordAutoOff.Configured, BeforeValues := CapsWordAutoOff.Values
    Raised := 0, Returned := "unset"
    try Returned := CapsWordAutoOffStore("shortcuts.caps_word.idle_timeout_seconds", Seconds, Fixture.path)
    catch Any as Failure
        Raised := Failure
    _TestPrint("# CAPSWORD_IDLE_STORE " . KL_JsonEncode(Map("seconds", String(Seconds),
        "error", IsObject(Raised) ? Type(Raised) : "", "returned", Returned,
        "file_unchanged", FSReadUtf8Exact(Fixture.path) == BeforeBytes,
        "policy_unchanged", CapsWordAutoOff.Configured == BeforePolicy,
        "values_unchanged", CapsWordAutoOff.Values == BeforeValues)))
    AssertTrue(IsObject(Raised) && Raised is ValueError, "an unsupported intrinsic timer delay is refused before writer publication")
    AssertTrue(InStr(Raised.Message, "invalid_idle_timeout", true) > 0, "keep the exact existing stable refusal reason")
    AssertEqual(BeforeBytes, FSReadUtf8Exact(Fixture.path), "the source-owned writer must not persist unarmable settings")
    AssertTrue(CapsWordAutoOff.Configured == BeforePolicy && CapsWordAutoOff.Values == BeforeValues)
}
_CWAODS_Run(Seconds) {
    _CWAO_WithDefaultSettings(_CWAODS_Body.Bind(Seconds))
}
Test("CapsWord idle store: integer overflow is refused before publication (capsword-idle-store-domain)", _CWAODS_Run.Bind(1 << 62))
Test("CapsWord idle store: float overflow is refused before publication (capsword-idle-store-domain)", _CWAODS_Run.Bind(1e308))
