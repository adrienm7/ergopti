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
	_HOF_Sends.Push({ Keys: Keys, Level: A_SendLevel })
	return 1
}

; Runs Callback with the real send call sites reaching _HOF_SendInput, on a clean
; engine, and gives every global back afterwards.
_HOF_Run(Callback) {
	_AHK04_RunIsolated(_HOF_Body.Bind(Callback))
}

_HOF_Body(Callback) {
	global _AHK_SendInput, _SendHook, _HotstringRegistrar, _HOF_Sends
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
	SavedLevel := A_SendLevel
	_HOF_Sends := []
	_SendHook := 0
	_HotstringRegistrar := 0
	_AHK_SendInput := _HOF_SendInput
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

; One session in a window the test owns, on the real watcher InputHook.
; @param Primitive {String} "SendInput" or "SendEvent", the burst primitive.
; @param Origin {String} "watcher": the whole text is typed at level 2. "tap":
;        the trigger is typed, a level-2 hotkey thread completes it.
; @return {Map} document, buffer, document and buffer after one Backspace.
_HOF_RealSession(Primitive, Origin) {
	global _PrefixInputHook, _SendHook, _HotstringRegistrar, _AHK_SendInput
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
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
		HSE_RegistryClear()
		HSE_HardReset()
		HSE_FeedReset(true)
		Opts := Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON)
		if (Origin == "watcher") {
			CreateHotstring("*?", "qzx", "foo qzy", Opts)
		} else {
			; An end-character trigger: only the Space completes it.
			CreateHotstring("?", "qzs", "foo qzy", Opts)
		}
		CreateHotstring("*?", "qzy", "bar qzz", Opts)
		CreateHotstring("*?", "qzz", "final", Opts)
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
		HSE_RegistryClear()
		HSE_HardReset()
		try Window.Destroy()
	}
	return Result
}

; The final text and the engine buffers must be the same with either primitive and
; from either entry point, and no link may fire a second time.
_HOF_RealChainOfThree() {
	global _AHK_INTERACTIVE
	Assert(_AHK_INTERACTIVE, "foreground input requires explicit --interactive admission")
	for Origin in ["watcher", "tap"] {
		Expected := (Origin == "watcher") ? "foo qzy" : "foo qzy "
		Baseline := 0
		for Primitive in ["SendEvent", "SendInput"] {
			Run := _HOF_RealSession(Primitive, Origin)
			Label := Origin . " + " . Primitive
			AssertEqual(Expected, Run["doc"],
				Label . ": the expansion must stay as the first link left it (output is final)")
			AssertEqual(Run["doc"], Run["buffer"],
				Label . ": the engine buffer must equal the screen")
			AssertEqual(SubStr(Run["doc"], 1, StrLen(Run["doc"]) - 1), Run["doc_after_backspace"],
				Label . ": one Backspace must remove one character")
			AssertEqual(Run["doc_after_backspace"], Run["buffer_after_backspace"],
				Label . ": the buffer must follow the Backspace")
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
