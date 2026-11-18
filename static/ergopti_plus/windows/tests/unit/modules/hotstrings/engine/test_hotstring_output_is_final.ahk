; tests/unit/modules/hotstrings/engine/test_hotstring_output_is_final.ahk

; ==============================================================================
; MODULE: Regression — a hotstring's output is final (hotstring-output-is-final)
; DESCRIPTION:
; A hotstring's own output never comes back through the prefix watcher: the
; engine commits the expansion to its buffers itself, and the text, whatever it
; ends with, completes no second hotstring until the user types again. That is
; what makes SendInput (atomic, fast) the right primitive for every expansion.
;
; The contract was never carried by SendMode("Event") (that mode only governs
; Send, Click and MouseMove); it is carried by provenance. The prefix watcher
; and the hook dispatcher are armed "I1" and ignore SendLevel 0, and every
; expansion goes out at TEXT_SENDER_SEND_LEVEL. The Space tap-hold completes a
; trigger from its #InputLevel 2 hotkey thread, where the burst used to inherit
; level 2: SendInput falls back to SendEvent whenever another AutoHotkey
; keyboard hook runs, and the burst then re-entered the watcher as typed input
; and cascaded A -> B -> C with an engine buffer that no longer matched the
; screen.
;
; SCOPE:
;   1/ Headless (CI): the level and the primitive of every expansion output,
;      with the injectable _AHK_SendInput standing in for the keyboard.
;   2/ Interactive (--interactive): the real engine, the real prefix watcher
;      InputHook and the real SendInput or SendEvent, typing into a window the
;      test owns. The same chain of three hotstrings, entered from the watcher
;      and from a level-2 hotkey thread, must give the same document and the
;      same buffers with either primitive.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Headless harness =======
; ===================================
; ===================================

global _HOF_Sends := []

; Stands in for the OS keyboard: records what was sent and at which level.
_HOF_SendInput(Keys) {
	global _HOF_Sends
	_HOF_Sends.Push({ Keys: Keys, Level: A_SendLevel, KeyDelay: A_KeyDelay, KeyDuration: A_KeyDuration })
	return 1
}

; Runs Callback with the real send call sites reaching _HOF_SendInput, on a clean
; engine, and gives every global back afterwards.
_HOF_Run(Callback) {
	_AHK04_RunIsolated(_HOF_Body.Bind(Callback))
}

_HOF_Body(Callback) {
	global HSE_CascadeMaxArrows, _AHK_SendInput, _SendHook, _HotstringRegistrar, _HOF_Sends
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
	SavedLevel := A_SendLevel
	SavedArrows := HSE_CascadeMaxArrows
	_HOF_Sends := []
	_SendHook := 0
	_HotstringRegistrar := 0
	_AHK_SendInput := _HOF_SendInput
	; One arrow is a single expansion: this contract is that no output re-enters
	; the watcher; the in-engine cascade is pinned by test_hotstring_cascade.ahk.
	HSE_CascadeMaxArrows := 1
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	try
		Callback.Call()
	finally {
		SendLevel(SavedLevel)
		_AHK_SendInput := SavedInput
		_SendHook := SavedHook
		_HotstringRegistrar := SavedRegistrar
		HSE_CascadeMaxArrows := SavedArrows
		HSE_RegistryClear()
		HSE_HardReset()
	}
}

; A trigger completes a hotstring whose text ends with the next trigger: three
; links, A -> B -> C, all star triggers that may match inside a word.
_HOF_RegisterChain(FirstText := "foo qzy") {
	Opts := Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON)
	CreateHotstring("*?", "qzx", FirstText, Opts)
	CreateHotstring("*?", "qzy", "bar qzz", Opts)
	CreateHotstring("*?", "qzz", "final", Opts)
}

; Feeds Text the way the watcher does and dispatches the match the last
; character completes, the way _OnPrefixChar and the Space tap-hold do.
; @return {Boolean|Map} The dispatch verdict, false when nothing matched.
_HOF_TypeAndFire(Text) {
	Match := ""
	for Char in StrSplit(Text)
		Match := HSE_FeedChar(Char, true)
	if !IsObject(Match)
		return false
	Effect := 0
	return HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect)
}





; ============================================
; ============================================
; ======= 2/ Headless regression tests =======
; ============================================
; ============================================

; The caller's level is level 2, the Space tap-hold's thread: the burst must
; still go out at level 0, and the caller must get its level back.
_HOF_DispatchLevelImpl() {
	global _HOF_Sends
	_HOF_RegisterChain()
	SendLevel(2)
	AssertTrue(_HOF_TypeAndFire("qzx"), "the first link must dispatch")
	AssertEqual(2, A_SendLevel, "the dispatch must give the caller its own SendLevel back")
	AssertEqual(1, _HOF_Sends.Length, "one trigger must produce exactly one injected burst")
	AssertEqual(0, _HOF_Sends[1].Level,
		"the expansion burst must go out below the watcher's I1 threshold, whatever the caller's level")
	AssertEqual("{BackSpace 3}{Text}foo qzy", _HOF_Sends[1].Keys,
		"the burst must erase the trigger and type the replacement in one SendInput")
	AssertEqual("foo qzy", HSE_Buffer,
		"the engine must commit the expansion to its own buffer")
}

_HOF_DispatchPinsSendLevel() {
	_HOF_Run(_HOF_DispatchLevelImpl)
}

; The text ends with the trigger of the next link; nothing re-feeds it.
_HOF_OutputIsFinalImpl() {
	global _HOF_Sends
	_HOF_RegisterChain()
	AssertTrue(_HOF_TypeAndFire("qzx"), "the first link must dispatch")
	AssertEqual(1, _HOF_Sends.Length,
		"text ending with another trigger must not be fed back: the output is final")
	AssertEqual("foo qzy", HSE_Buffer, "the buffer must stop at the first expansion")
}

_HOF_OutputIsFinal() {
	_HOF_Run(_HOF_OutputIsFinalImpl)
}

; The output stops in the middle of the next trigger and the user finishes it:
; the engine buffer must hold the screen so the typed character completes it.
_HOF_MidWordImpl() {
	global _HOF_Sends
	_HOF_RegisterChain("foo qz")
	AssertTrue(_HOF_TypeAndFire("qzx"), "the first link must dispatch")
	AssertEqual("foo qz", HSE_Buffer, "the buffer must hold the text that is on screen")
	AssertTrue(_HOF_TypeAndFire("y"), "the typed character must complete the next trigger")
	AssertEqual(2, _HOF_Sends.Length, "each completed trigger is one burst")
	AssertEqual("{BackSpace 3}{Text}bar qzz", _HOF_Sends[2].Keys,
		"the second burst must erase the three characters the first left in the buffer")
	AssertEqual("foo bar qzz", HSE_Buffer, "the buffer must follow the second expansion")
}

_HOF_OutputEndingMidWord() {
	_HOF_Run(_HOF_MidWordImpl)
}

; A trigger the user types is not special: its own expansion is final too.
_HOF_TypedTriggerImpl() {
	global _HOF_Sends
	_HOF_RegisterChain()
	AssertTrue(_HOF_TypeAndFire("qzy"), "a typed trigger must dispatch")
	AssertEqual(1, _HOF_Sends.Length, "a typed trigger must produce one burst")
	AssertEqual("{BackSpace 3}{Text}bar qzz", _HOF_Sends[1].Keys,
		"a typed trigger must expand with its own replacement")
}

_HOF_UserTypedTrigger() {
	_HOF_Run(_HOF_TypedTriggerImpl)
}

; Both AltGr families: the burst goes through the owner that lifts a Kana AltGr,
; and stays one burst at level 0 either way.
_HOF_AltGrFamilyImpl(Kana) {
	global _HOF_Sends, _ALTGR_KANA_FIXUP
	_ALTGR_KANA_FIXUP := Kana
	_HOF_RegisterChain()
	SendLevel(2)
	AssertTrue(_HOF_TypeAndFire("qzx"), "the first link must dispatch")
	AssertEqual(1, _HOF_Sends.Length, "the AltGr lift must not split the expansion")
	AssertEqual(0, _HOF_Sends[1].Level, "the expansion must stay at level 0 on an AltGr family")
}

_HOF_AltGrFamilies() {
	_HOF_Run(_HOF_AltGrFamilyImpl.Bind(false))
	_HOF_Run(_HOF_AltGrFamilyImpl.Bind(true))
}

; A Notepad expansion is native (a paste-like edit): it injects no key at all,
; so nothing can come back through the watcher, and it is not chained either.
_HOF_NotepadImpl() {
	global _HOF_Sends, _AHK04_SendCalls, _AHK_SendInput, _SendHook
	global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer
	HSE_Buffer := "xxab"
	_PrefixBuffer := "xxab"
	_LLM_Bridge_Buffer := "xxab"
	_SendHook := 0
	_AHK_SendInput := _HOF_SendInput
	_HOF_Sends := []
	Spec := _AHK04_NormalSpec()
	Spec.Replacement := "foo qzy"
	OutputHostResolverPrimeForTest("notepad.exe")
	_AHK04_SendCalls := []
	Effect := 0
	Verdict := HSE_DispatchMatch(Spec, "", &Effect, false, _HNP_InlineSend.Bind(true))
	AssertTrue(Verdict, "the Notepad expansion must dispatch")
	AssertEqual(0, _HOF_Sends.Length, "a native Notepad edit must inject no key")
	AssertEqual(1, _AHK04_SendCalls.Length, "one Notepad expansion is one native edit")
}

_HOF_PastedOutputIsNotFedBack() {
	_HNP_Run(_HOF_NotepadImpl)
}

; The two hotstrings that still decide at fire time (the ellipsis and the ê dead
; key) used to type with SendEvent at the caller's level.
_HOF_RawCallbacksImpl() {
	global _HOF_Sends
	_LSCResetFrom(["a", ".", ".", "."])
	SendLevel(2)
	Verdict := _EllipsisRawCallback("")
	AssertTrue(Verdict.Ok, "the ellipsis callback must report its expansion")
	AssertEqual(1, _HOF_Sends.Length, "the ellipsis is one burst")
	AssertEqual("{BackSpace 3}…", _HOF_Sends[1].Keys, "the ellipsis must erase the dots and type …")
	AssertEqual(0, _HOF_Sends[1].Level, "the ellipsis burst must go out at level 0")
	AssertEqual("…", GetLastSentCharacterAt(-1), "the ring must record what reached the screen")

	_HOF_Sends := []
	UpdateLastSentCharacter(" ")
	UpdateLastSentCharacter("ê")
	UpdateLastSentCharacter("x")
	Verdict := ShouldActivateDeadkey("êx", "¤", 5)
	AssertTrue(Verdict.Ok, "the dead key callback must report its expansion")
	AssertEqual(1, _HOF_Sends.Length, "the dead key is one burst")
	AssertEqual("{BackSpace 2}{Text}¤", _HOF_Sends[1].Keys, "the dead key must erase êx and type the symbol")
	AssertEqual(0, _HOF_Sends[1].Level, "the dead key burst must go out at level 0")
}

_HOF_RawCallbacksAreAtomicAtLevelZero() {
	_HOF_Run(_HOF_RawCallbacksImpl)
}

Test("hotstring output: the burst goes out at level 0 from a level-2 hotkey thread (hotstring-output-is-final)",
	_HOF_DispatchPinsSendLevel)

; Beside another AutoHotkey hook SendInput falls back to SendEvent, which keeps
; a press duration of 0 unless the key delay is -1: under the driver's global
; SetKeyDelay(0) each key yielded, the burst took 80 to 90 ms, and the next
; word's letters landed inside it (« AaSAASA » for « ASA ASA », 2026-11-18).
_HOF_BurstUnpacedImpl() {
	global _HOF_Sends
	_HOF_RegisterChain()
	PreviousDelay := A_KeyDelay
	PreviousDuration := A_KeyDuration
	SetKeyDelay(0, -1)
	try {
		AssertTrue(_HOF_TypeAndFire("qzx"), "the first link must dispatch")
		AssertEqual(1, _HOF_Sends.Length, "one trigger must produce exactly one injected burst")
		AssertEqual(-1, _HOF_Sends[1].KeyDelay, "the burst must be sent with no key delay")
		AssertEqual(-1, _HOF_Sends[1].KeyDuration,
			"the burst must be sent with no press duration, so a SendEvent fallback never yields inside it")
		AssertEqual(0, A_KeyDelay, "the dispatch must give the caller its key delay back")
		AssertEqual(-1, A_KeyDuration, "the dispatch must give the caller its press duration back")
	} finally SetKeyDelay(PreviousDelay, PreviousDuration)
}

_HOF_BurstIsUnpaced() {
	_HOF_Run(_HOF_BurstUnpacedImpl)
}

; The keyboard while a burst is on its way beside another hook: SendEvent lets a
; key the user strikes reach the window between the burst's own keys. A started
; capture takes the key's text instead, as an InputHook that is not visible does.
global _HOF_Race := 0

class _HOF_RaceCapture {
	__New(Options) {
		global _HOF_Race
		_HOF_Race.Built += 1
		this.Options := Options
		this.Input := ""
		this.InProgress := false
	}
	Start() {
		global _HOF_Race
		this.InProgress := true
		this.Input := ""
		this.Starts := this.HasOwnProp("Starts") ? this.Starts + 1 : 1
		if this.Starts == 1
			_HOF_Race.Captures.Push(this)
	}
	; The keys struck right after the hook sees the stop reach the window.
	Stop() {
		global _HOF_Race
		this.InProgress := false
		Struck := _HOF_Race.StruckAtStop
		_HOF_Race.StruckAtStop := ""
		_HOF_RaceStrike(Struck)
	}
}

; Keys struck now: a running capture holds them, or they reach the window.
_HOF_RaceStrike(Chars) {
	global _HOF_Race
	for Char in StrSplit(Chars) {
		Held := false
		for Capture in _HOF_Race.Captures
			if Capture.InProgress {
				Capture.Input .= Char
				Held := true
			}
		if !Held
			_HOF_Race.Screen.Push("typed " . Char)
	}
}

; Strikes the user's keys in the middle of the burst, then lets it finish.
_HOF_RaceSendInput(Keys) {
	global _HOF_Race
	_HOF_Race.Screen.Push("burst " . Keys)
	_HOF_RaceStrike(_HOF_Race.Struck)
	_HOF_Race.Screen.Push("burst end")
	if _HOF_Race.Refuse
		throw Error("the burst was refused")
	return 1
}

_HOF_RaceSendEvent(Keys) {
	global _HOF_Race
	_HOF_Race.Screen.Push("replay " . Keys)
	_HOF_Race.Replays.Push({ Keys: Keys, Level: A_SendLevel, KeyDelay: A_KeyDelay, KeyDuration: A_KeyDuration })
	Struck := _HOF_Race.StruckDuringReplay
	_HOF_Race.StruckDuringReplay := ""
	_HOF_RaceStrike(Struck)
	return 1
}

_HOF_RaceRun(Struck, Refuse, Callback) {
	global _HOF_Race, _AHK_SendInput, _AHK_SendEvent, _AHK_InputHook, _HSE_BurstCaptureHook
	SavedInput := _AHK_SendInput
	SavedEvent := _AHK_SendEvent
	SavedHook := _AHK_InputHook
	SavedCapture := _HSE_BurstCaptureHook
	_HOF_Race := { Struck: Struck, Refuse: Refuse, Screen: [], Captures: [], Replays: [], Built: 0,
		StruckDuringReplay: "", StruckAtStop: "" }
	_AHK_SendInput := _HOF_RaceSendInput
	_AHK_SendEvent := _HOF_RaceSendEvent
	_AHK_InputHook := (Options) => _HOF_RaceCapture(Options)
	_HSE_BurstCaptureHook := 0
	try
		Callback.Call()
	finally {
		_AHK_SendInput := SavedInput
		_AHK_SendEvent := SavedEvent
		_AHK_InputHook := SavedHook
		_HSE_BurstCaptureHook := SavedCapture
	}
}

; « asa », Space, « a » typed fast beside another hook gave « AaSA »: the next
; word's letter reached the window inside the expansion.
_HOF_StruckKeyWaitsImpl() {
	global _HOF_Race, HSE_BURST_CAPTURE_OPTIONS, TAPHOLD_ROLL_REPLAY_SEND_LEVEL
	_HOF_RegisterChain()
	_HOF_RaceRun("a", false, () => AssertTrue(_HOF_TypeAndFire("qzx"), "the first link must dispatch"))
	AssertEqual("burst {BackSpace 3}{Text}foo qzy|burst end|replay {Text}a", _HOF_Join(_HOF_Race.Screen),
		"a key struck during the burst must reach the window after it, never inside it")
	AssertEqual(1, _HOF_Race.Captures.Length, "one burst is held by one capture")
	AssertFalse(_HOF_Race.Captures[1].InProgress, "the capture must end with the burst")
	AssertEqual("I" . (TAPHOLD_ROLL_REPLAY_SEND_LEVEL + 1) . " " . HSE_BURST_CAPTURE_OPTIONS,
		_HOF_Race.Captures[1].Options,
		"the capture must let the burst (level 0) and the held text it types again through")
	AssertEqual(TAPHOLD_ROLL_REPLAY_SEND_LEVEL, _HOF_Race.Replays[1].Level,
		"the held text must be typed at a level the watcher sees and no hotkey takes")
	AssertEqual(-1, _HOF_Race.Replays[1].KeyDelay, "the held text must be typed unpaced too")
	AssertEqual("foo qzy", HSE_Buffer, "the engine buffer holds the expansion; the watcher feeds the replay")
}

_HOF_StruckKeyWaitsForTheBurst() {
	_HOF_Run(_HOF_StruckKeyWaitsImpl)
}

; The held text is typed before the capture stops: a key struck while it is
; typed is held too, and one struck as the capture stops comes after them all.
_HOF_HeldKeysKeepOrderImpl() {
	global _HOF_Race
	_HOF_RaceRun("a", false, _HOF_StrikeAroundTheRelease)
	AssertEqual("burst {Text}x|burst end|replay {Text}a|replay {Text}b|typed c", _HOF_Join(_HOF_Race.Screen),
		"keys struck while the held text is typed, or as the capture stops, must keep their order")
	AssertFalse(_HOF_Race.Captures[1].InProgress, "the capture must stop once it holds nothing more")
}

_HOF_StrikeAroundTheRelease() {
	global _HOF_Race
	_HOF_Race.StruckDuringReplay := "b"
	_HOF_Race.StruckAtStop := "c"
	_HSE_SendBurstUnpaced("{Text}x")
}

_HOF_HeldKeysKeepTheirOrder() {
	_HOF_Run(_HOF_HeldKeysKeepOrderImpl)
}

; A refused burst still gives the user's keys back, an untouched burst types
; nothing more, each burst restarts the one capture, and a burst sent while the
; capture runs leaves the keys to the burst that started it.
_HOF_StruckKeyEdgesImpl() {
	global _HOF_Race
	_HOF_RaceRun("b", true, () => AssertThrows(() => _HSE_SendBurstUnpaced("{Text}x"),
		"a refused burst must still fail its caller"))
	AssertEqual("burst {Text}x|burst end|replay {Text}b", _HOF_Join(_HOF_Race.Screen),
		"a key held during a refused burst must still be typed")
	AssertFalse(_HOF_Race.Captures[1].InProgress, "a refused burst must end its capture")

	_HOF_RaceRun("", false, () => _HSE_SendBurstUnpaced("{Text}x"))
	AssertEqual("burst {Text}x|burst end", _HOF_Join(_HOF_Race.Screen),
		"nothing typed during the burst means nothing to type after it")

	_HOF_RaceRun("c", false, _HOF_TwoBursts)
	AssertEqual(1, _HOF_Race.Built, "every burst must restart the one capture, never build another")
	AssertEqual("burst {Text}x|burst end|replay {Text}c|burst {Text}y|burst end|replay {Text}c",
		_HOF_Join(_HOF_Race.Screen), "a restarted capture must hold only the keys of its own burst")

	_HOF_RaceRun("d", false, _HOF_NestedBurst)
	AssertEqual("burst {Text}y|burst end", _HOF_Join(_HOF_Race.Screen),
		"a burst sent while the capture runs must leave the held keys to its owner")
	AssertTrue(_HOF_Race.Captures[1].InProgress, "the inner burst must not end its owner's capture")
	AssertEqual("d", _HOF_Race.Captures[1].Input, "the owner's capture must still hold the key")
}

_HOF_TwoBursts() {
	_HSE_SendBurstUnpaced("{Text}x")
	_HSE_SendBurstUnpaced("{Text}y")
}

; The owner's capture is already running when the inner burst goes out.
_HOF_NestedBurst() {
	_HSE_BurstCapture().Start()
	_HSE_SendBurstUnpaced("{Text}y")
}

_HOF_StruckKeyEdges() {
	_HOF_Run(_HOF_StruckKeyEdgesImpl)
}

_HOF_Join(Items) {
	Joined := ""
	for Item in Items
		Joined .= (A_Index > 1 ? "|" : "") . Item
	return Joined
}

Test("hotstring output: the burst is sent unpaced, so a SendEvent fallback stays short (asa-space-burst-unpaced)",
	_HOF_BurstIsUnpaced)
Test("hotstring output: a key struck during the burst is typed after it (burst-holds-struck-keys)",
	_HOF_StruckKeyWaitsForTheBurst)
Test("hotstring output: keys struck as the held text is typed keep their order (burst-holds-struck-keys)",
	_HOF_HeldKeysKeepTheirOrder)
Test("hotstring output: the burst capture survives refused, empty, repeated and nested bursts (burst-holds-struck-keys)",
	_HOF_StruckKeyEdges)
Test("hotstring output: text ending with another trigger is not fed back (hotstring-output-is-final)",
	_HOF_OutputIsFinal)
Test("hotstring output: text ending mid-trigger is completed by the typed character (hotstring-output-is-final)",
	_HOF_OutputEndingMidWord)
Test("hotstring output: a typed trigger expands once with its own replacement (hotstring-output-is-final)",
	_HOF_UserTypedTrigger)
Test("hotstring output: both AltGr families keep one burst at level 0 (hotstring-output-is-final)",
	_HOF_AltGrFamilies)
Test("hotstring output: a native Notepad edit injects no key (hotstring-output-is-final)",
	_HOF_PastedOutputIsNotFedBack)
Test("hotstring output: the ellipsis and dead key callbacks send one SendInput at level 0 (hotstring-output-is-final)",
	_HOF_RawCallbacksAreAtomicAtLevelZero)

; The Space tap-hold puts its space on screen with the TextSender, then feeds
; it to the engine itself. The send must not also declare the space as a caret
; edit, which empties both buffers before the feed and so completes nothing.
_HOF_SpaceTapImpl() {
	global _HOF_Sends, HSE_LastEndChar
	CreateHotstring("", "qzx", "final", Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON))
	for Char in StrSplit("qzx")
		HSE_FeedChar(Char, true)
	AssertEqual("qzx", HSE_Buffer, "the typed trigger must be in the engine buffer")
	AssertTrue(TextPressKeyFed("Space"), "the space must be sent")
	AssertEqual("{Space}", _HOF_Sends[1].Keys, "the tap must send one space")
	AssertEqual("qzx", HSE_Buffer, "sending the space must not declare an edit that empties the buffer")
	Match := HSE_FeedChar(" ", true)
	AssertTrue(IsObject(Match), "an end-character trigger must complete from the Space tap")
	Effect := 0
	AssertTrue(HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect), "the completed trigger must dispatch")
}

_HOF_SpaceTapCompletesEndCharTrigger() {
	_HOF_Run(_HOF_SpaceTapImpl)
}

Test("hotstring output: an end-character trigger completes from the Space tap (hotstring-output-is-final)",
	_HOF_SpaceTapCompletesEndCharTrigger)

; The maintainer's example: `pr` + Space gives `PR` while the section's delay is
; 0.5 s. The gate runs from the previous letter to the end character the user
; PRESSED. A tap-hold Space is typed when it comes up, so its press tick is the
; moment to measure; measured at the release, the time the key stayed down was
; held against the typist and a normal-speed press missed the delay.
; @param PressedMsAgo {Integer} How long ago Space went down; 0 dispatches at once.
_HOF_PrGateImpl(PressedMsAgo) {
	global _HOF_Sends, HSE_LastEndChar, LastSentCharacterKeyTime
	CreateHotstring("", "pr", "PR", Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON,
		"TimeActivationSeconds", 0.5))
	; The last letter, `r`, was sent 560 ms ago: past the 0.5 s delay now, inside it
	; 100 ms ago (the delay runs from the last letter to the expander).
	LastSentCharacterKeyTime := Map("r", A_TickCount - 560)
	for Char in StrSplit("pr")
		HSE_FeedChar(Char, true)
	Match := HSE_FeedChar(" ", true)
	AssertTrue(IsObject(Match), "pr + Space must complete the trigger")
	Effect := 0
	GateTick := PressedMsAgo > 0 ? A_TickCount - PressedMsAgo : 0
	if (PressedMsAgo > 0) {
		AssertTrue(HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect, false, unset, GateTick),
			"a Space pressed inside the delay must expand pr to PR although it is typed later")
		AssertEqual("{BackSpace 3}{Text}PR ", _HOF_Sends[1].Keys)
	} else {
		AssertFalse(HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect),
			"a Space typed past the delay does not expand")
	}
}

_HOF_PrGateAtThePress() {
	_HOF_Run(_HOF_PrGateImpl.Bind(100))
	_HOF_Run(_HOF_PrGateImpl.Bind(0))
}

Test("hotstring output: the delay gate of a tap-hold Space is measured at its press (space-tap-gate-at-press)",
	_HOF_PrGateAtThePress)





; ============================================================
; ============================================================
; ======= 3/ Interactive: the real engine and keyboard =======
; ============================================================
; ============================================================

global _HOF_TrailingSettleMs := 350

; Types into the focused control the way the layout does: SendEvent at level 2,
; which the prefix watcher accepts. A timer thread owns its own SendLevel, so
; the watcher callbacks it lets run never inherit it.
_HOF_RealType(Text, Level) {
	SendLevel(Level)
	SendEvent(Text)
}

; The completion of a trigger by a level-2 hotkey thread, the way the Space
; tap-hold's _SpaceTap performs it: put the space on screen, feed the engine,
; dispatch what it completes. The space goes out at level 0 and is fed by hand,
; without the buffer declaration TextPressKey adds (which resets the buffers).
_HOF_RealSpaceTapLike() {
	global HSE_LastEndChar
	SendLevel(2)
	PreviousCritical := Critical("On")
	try {
		SendLevel(0)
		SendInput("{Space}")
		SendLevel(2)
		Match := HSE_FeedChar(" ", true)
		Effect := 0
		if IsObject(Match)
			HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect)
	} finally Critical(PreviousCritical)
}

; Waits until the control holds the same text for the settle time.
_HOF_RealSettle(Edit, Timeout := 4000) {
	global _HOF_TrailingSettleMs
	Started := A_TickCount
	Last := Edit.Value
	Since := A_TickCount
	while (A_TickCount - Started < Timeout) {
		Sleep(25)
		if (Edit.Value != Last) {
			Last := Edit.Value
			Since := A_TickCount
		} else if (Last != "" && A_TickCount - Since >= _HOF_TrailingSettleMs) {
			break
		}
	}
	return A_TickCount - Since
}

; Arms the engine of one interactive session: a clean engine, one cascade
; arrow and the chain of three. This contract is that no output re-enters the
; watcher. With the default three arrows the engine itself resolves qzx > qzy >
; qzz before it sends anything, so the watcher session typed « foo bar final »
; with either primitive, which read as a level-0 SendEvent burst reaching the I1
; watcher (2026-11-17); the in-engine cascade has its own test.
; @param Origin {String} "watcher" (a star first trigger) or "tap" (an
;        end-character first trigger, completed by Space).
_HOF_RealArm(Origin) {
	global HSE_CascadeMaxArrows
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	HSE_CascadeMaxArrows := 1
	Opts := Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON)
	if (Origin == "watcher") {
		CreateHotstring("*?", "qzx", "foo qzy", Opts)
	} else {
		; An end-character trigger: only the Space completes it.
		CreateHotstring("?", "qzs", "foo qzy", Opts)
	}
	CreateHotstring("*?", "qzy", "bar qzz", Opts)
	CreateHotstring("*?", "qzz", "final", Opts)
}

; The interactive session's engine, driven headless from the default cascade
; setting: each origin sends the first link alone, as the interactive test
; expects of the real keyboard.
_HOF_RealArmImpl(Origin) {
	global _HOF_Sends, HSE_CascadeMaxArrows
	HSE_CascadeMaxArrows := ""
	_HOF_RealArm(Origin)
	Verdict := _HOF_TypeAndFire(Origin == "watcher" ? "qzx" : "qzs ")
	AssertTrue(Verdict, Origin . ": the first link must dispatch")
	AssertEqual(1, _HOF_Sends.Length, Origin . ": one trigger must produce one burst")
	Expected := Origin == "watcher" ? "{BackSpace 3}{Text}foo qzy" : "{BackSpace 4}{Text}foo qzy "
	AssertEqual(Expected, _HOF_Sends[1].Keys,
		Origin . ": the session must send the first link alone, not the in-engine cascade")
}

_HOF_RealArmSendsOneLink() {
	_HOF_Run(_HOF_RealArmImpl.Bind("watcher"))
	_HOF_Run(_HOF_RealArmImpl.Bind("tap"))
}

Test("hotstring output: the interactive session arms one cascade arrow (hotstring-output-is-final)",
	_HOF_RealArmSendsOneLink)

; One session in a window the test owns, on the real watcher InputHook.
; @param Primitive {String} "SendInput" or "SendEvent", the burst primitive.
; @param Origin {String} "watcher": the whole text is typed at level 2. "tap":
;        the trigger is typed, a level-2 hotkey thread completes it.
; @return {Map} document, buffer, document and buffer after one Backspace.
_HOF_RealSession(Primitive, Origin) {
	global _PrefixInputHook, _SendHook, _HotstringRegistrar, _AHK_SendInput, HSE_CascadeMaxArrows
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
	SavedArrows := HSE_CascadeMaxArrows
	Window := Gui("+AlwaysOnTop", "Ergopti hotstring output test")
	Edit := Window.AddEdit("w420 h90 Multi", "")
	Result := Map()
	try {
		Window.Show("w460 h130")
		WinActivate("ahk_id " . Window.Hwnd)
		Assert(WinWaitActive("ahk_id " . Window.Hwnd, , 3),
			"the owned window must take the foreground before keys are injected")
		Edit.Focus()
		for Key in ["Ctrl", "Alt", "Shift", "LWin", "RWin"]
			AssertFalse(GetKeyState(Key, "P"), "release " . Key . " before the interactive test")
		_SendHook := 0
		_HotstringRegistrar := 0
		; The runner locks the injectable to a no-op: name the real primitive.
		if (Primitive == "SendInput")
			_AHK_SendInput := (Keys) => SendInput(Keys)
		else
			_AHK_SendInput := (Keys) => SendEvent(Keys)
		_HOF_RealArm(Origin)
		_StartInputHook()
		try {
			if (Origin == "watcher") {
				SetTimer(_HOF_RealType.Bind("qzx", 2), -1)
			} else {
				SetTimer(_HOF_RealType.Bind("qzs", 2), -1)
				Sleep(500)
				SetTimer(_HOF_RealSpaceTapLike, -1)
			}
			Result["settle"] := _HOF_RealSettle(Edit)
			Result["doc"] := Edit.Value
			Result["buffer"] := HSE_Buffer
			SetTimer(_HOF_RealType.Bind("{Backspace}", 2), -1)
			Sleep(400)
			Result["doc_after_backspace"] := Edit.Value
			Result["buffer_after_backspace"] := HSE_Buffer
		} finally {
			try _PrefixInputHook.Stop()
			_PrefixInputHook := 0
		}
	} finally {
		_AHK_SendInput := SavedInput
		_SendHook := SavedHook
		_HotstringRegistrar := SavedRegistrar
		HSE_CascadeMaxArrows := SavedArrows
		HSE_RegistryClear()
		HSE_HardReset()
		try Window.Destroy()
	}
	return Result
}

; The final text and the engine buffers must be the same with either primitive and
; from either entry point, and no link may fire a second time. The Backspace
; that follows is the immediate one, which restores the trigger without its end
; character and keeps it out of the buffer (backspace-undo, 2026-11-06); this
; test predates it and expected one character removed, so after the one-arrow
; pin it failed on « qzx » for « foo qz » (2026-11-18).
_HOF_RealChainOfThree() {
	global _AHK_INTERACTIVE
	Assert(_AHK_INTERACTIVE, "foreground input requires explicit --interactive admission")
	for Origin in ["watcher", "tap"] {
		Expected := (Origin == "watcher") ? "foo qzy" : "foo qzy "
		Trigger := (Origin == "watcher") ? "qzx" : "qzs"
		Baseline := 0
		for Primitive in ["SendEvent", "SendInput"] {
			Run := _HOF_RealSession(Primitive, Origin)
			Label := Origin . " + " . Primitive
			AssertEqual(Expected, Run["doc"],
				Label . ": the expansion must stay as the first link left it (output is final)")
			AssertEqual(Run["doc"], Run["buffer"],
				Label . ": the engine buffer must equal the screen")
			AssertEqual(Trigger, Run["doc_after_backspace"],
				Label . ": the immediate Backspace must restore the first trigger, the end character excluded")
			AssertEqual("", Run["buffer_after_backspace"],
				Label . ": the restored trigger must stay out of the buffer")
			try FileAppend("# hotstring-output-is-final " . Label . " settle_ms=" . Run["settle"] . "`n", "*")
			if (Primitive == "SendEvent") {
				Baseline := Run
			} else {
				AssertEqual(Baseline["doc"], Run["doc"], Label . ": same document as the SendEvent baseline")
				AssertEqual(Baseline["buffer"], Run["buffer"], Label . ": same buffer as the SendEvent baseline")
				AssertEqual(Baseline["buffer_after_backspace"], Run["buffer_after_backspace"],
					Label . ": same undo and backspace accounting as the SendEvent baseline")
			}
		}
	}
}

Test("hotstring output: a chain of three in the real engine is final with SendEvent and with SendInput (hotstring-output-is-final)",
	_HOF_RealChainOfThree, true)
