; tests/unit/modules/hotstrings/engine/test_hotstring_chaining.ahk

; ==============================================================================
; MODULE: Hotstring chaining (hotstring-chaining)
; DESCRIPTION:
; The engine's matching buffer follows the screen, so the text a hotstring
; produced takes part in the next match: « ab » gives « cd » and « cde » gives
; « xyz », hence typing « abe » gives « xyz »; « at★ » gives « att », « att★ »
; gives « attention » and « attention★ » gives a warning sign, hence typing the
; magic key three times after « at » ends on the sign. Only a typed keystroke
; completes a trigger: a trigger that lies wholly inside an expansion's output
; fires nothing until the user types again, so no loop is possible.
;
; SCOPE:
;   1/ Headless (CI): the real engine and dispatcher with a virtual screen that
;      applies the injected burst, so the final document is asserted.
;   2/ Interactive (--interactive): the real engine, the real prefix watcher
;      InputHook and the real SendInput or SendEvent, typing into a window the
;      test owns.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Headless harness =======
; ===================================
; ===================================

global _HCH_Screen := ""
global _HCH_Bursts := 0

; Applies one injected burst to the virtual screen: {BackSpace N}, {Text}...
_HCH_ApplyBurst(Keys) {
	global _HCH_Screen, _HCH_Bursts
	_HCH_Bursts += 1
	Pos := 1
	while (Pos <= StrLen(Keys)) {
		if RegExMatch(Keys, "^\{BackSpace (\d+)\}", &Backspace, Pos) {
			Count := Integer(Backspace[1])
			loop Count
				_HCH_Screen := SubStr(_HCH_Screen, 1, StrLen(_HCH_Screen) - _TextTailCodeUnits(_HCH_Screen, 1))
			Pos += StrLen(Backspace[0])
		} else if (SubStr(Keys, Pos, 6) == "{Text}") {
			_HCH_Screen .= SubStr(Keys, Pos + 6)
			break
		} else {
			_HCH_Screen .= SubStr(Keys, Pos)
			break
		}
	}
}

_HCH_SendInput(Keys) {
	_HCH_ApplyBurst(Keys)
	return 1
}

; Runs Callback on a clean engine with the send primitive on the virtual screen.
_HCH_Run(Callback) {
	_AHK04_RunIsolated(_HCH_Body.Bind(Callback))
}

_HCH_Body(Callback) {
	global _AHK_SendInput, _SendHook, _HotstringRegistrar, _HCH_Screen, _HCH_Bursts
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
	SavedLevel := A_SendLevel
	_HCH_Screen := ""
	_HCH_Bursts := 0
	_SendHook := 0
	_HotstringRegistrar := 0
	_AHK_SendInput := _HCH_SendInput
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

; Types Text the way the prefix watcher sees it: the character reaches the screen,
; is timed, is fed to the engine, and the match it completes is dispatched.
_HCH_Type(Text) {
	global _HCH_Screen
	for Char in StrSplit(Text) {
		_HCH_Screen .= Char
		AppState_TouchLastSentKey(Char)
		Match := HSE_FeedChar(Char, true)
		if !IsObject(Match)
			continue
		Effect := 0
		HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect)
	}
}

_HCH_Register(Flags, Trigger, Text, Gate := 0) {
	Opts := Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON)
	if Gate > 0
		Opts["TimeActivationSeconds"] := Gate
	CreateHotstring(Flags, Trigger, Text, Opts)
}





; ============================================
; ============================================
; ======= 2/ Headless regression tests =======
; ============================================
; ============================================

; The maintainer's first definition: ab gives cd, cde gives xyz.
_HCH_PlainChainImpl() {
	global _HCH_Screen, _HCH_Bursts
	_HCH_Register("*?", "ab", "cd")
	_HCH_Register("*?", "cde", "xyz")
	_HCH_Type("abe")
	AssertEqual("xyz", _HCH_Screen, "the typed e must complete cde from the expansion's output")
	AssertEqual(2, _HCH_Bursts, "each completed trigger is one burst")
	AssertEqual("xyz", HSE_Buffer, "the buffer must follow the screen")
}

_HCH_PlainChain() {
	_HCH_Run(_HCH_PlainChainImpl)
}

; The maintainer's second definition, with the magic key and the shipped time gate.
_HCH_MagicKeyChainImpl() {
	global _HCH_Screen, _HCH_Bursts
	Sign := Chr(0x26A0) . Chr(0xFE0F)
	_HCH_Register("*", "at" . Chr(0x2605), "att", 0.75)
	_HCH_Register("*", "att" . Chr(0x2605), "attention", 0.75)
	_HCH_Register("*", "attention" . Chr(0x2605), Sign, 0.75)
	_HCH_Type("at" . Chr(0x2605) . Chr(0x2605) . Chr(0x2605))
	AssertEqual(Sign, _HCH_Screen, "three magic keys after at must end on the sign")
	AssertEqual(3, _HCH_Bursts, "three keystrokes, three bursts")
	AssertEqual(Sign, HSE_Buffer, "the buffer must hold exactly what the screen holds")
}

_HCH_MagicKeyChain() {
	_HCH_Run(_HCH_MagicKeyChainImpl)
}

; Each step must go through its own keystroke: the output alone completes nothing.
_HCH_OutputAloneFiresNothingImpl() {
	global _HCH_Screen, _HCH_Bursts
	_HCH_Register("*?", "ab", "cde")
	_HCH_Register("*?", "cde", "xyz")
	_HCH_Type("ab")
	AssertEqual("cde", _HCH_Screen, "a trigger wholly inside the output must not fire")
	AssertEqual(1, _HCH_Bursts, "one keystroke, one burst")
}

_HCH_OutputAloneFiresNothing() {
	_HCH_Run(_HCH_OutputAloneFiresNothingImpl)
}

; A replacement ending with its own trigger expands once per keystroke, never in a loop.
_HCH_SelfTriggerImpl() {
	global _HCH_Screen, _HCH_Bursts
	_HCH_Register("*?", "qz", "qz qz")
	_HCH_Type("qz")
	AssertEqual("qz qz", _HCH_Screen, "the self-triggering replacement must expand once")
	AssertEqual(1, _HCH_Bursts, "one keystroke, one burst")
	_HCH_Type("qz")
	AssertEqual(2, _HCH_Bursts, "the next typed trigger expands again, once")
}

_HCH_SelfTrigger() {
	_HCH_Run(_HCH_SelfTriggerImpl)
}

; Backspace over the expansion's output, then typing the rest again, chains again.
_HCH_BackspaceImpl() {
	global _HCH_Screen
	_HCH_Register("*?", "ab", "cd")
	_HCH_Register("*?", "cde", "xyz")
	_HCH_Type("ab")
	AssertEqual("cd", HSE_Buffer, "the buffer must hold the output")
	HSE_FeedBackspace(true, true)
	_HCH_Screen := SubStr(_HCH_Screen, 1, StrLen(_HCH_Screen) - 1)
	AssertEqual("c", HSE_Buffer, "a Backspace must erase one character of the output")
	_HCH_Type("de")
	AssertEqual("xyz", _HCH_Screen, "retyping the erased character must complete the chain")
}

_HCH_Backspace() {
	_HCH_Run(_HCH_BackspaceImpl)
}

Test("hotstring chaining: ab gives cd and cde gives xyz, so abe gives xyz (hotstring-chaining)",
	_HCH_PlainChain)
Test("hotstring chaining: at, att and attention chain through three magic keys (hotstring-chaining)",
	_HCH_MagicKeyChain)
Test("hotstring chaining: an output that holds a whole trigger fires nothing alone (hotstring-chaining)",
	_HCH_OutputAloneFiresNothing)
Test("hotstring chaining: a replacement ending with its own trigger cannot loop (hotstring-chaining)",
	_HCH_SelfTrigger)
Test("hotstring chaining: Backspace unwinds the output and retyping chains again (hotstring-chaining)",
	_HCH_Backspace)





; ============================================================
; ============================================================
; ======= 3/ Interactive: the real engine and keyboard =======
; ============================================================
; ============================================================

global _HCH_SettleMs := 400

; Types into the focused control the way the layout does: SendEvent at level 2,
; the level the prefix watcher accepts, one character at a time like a person.
_HCH_RealType(Text, GapMs) {
	SendLevel(2)
	for Char in StrSplit(Text) {
		SendEvent("{Text}" . Char)
		Sleep(GapMs)
	}
}

; The completion of a trigger by a level-2 hotkey thread, the way the Space
; tap-hold's _SpaceTap performs it: put the space on screen at level 0, feed the
; engine, dispatch what it completes.
_HCH_RealSpaceTapLike() {
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

_HCH_RealSettle(Edit, Timeout := 6000) {
	global _HCH_SettleMs
	Started := A_TickCount
	Last := Edit.Value
	Since := A_TickCount
	while (A_TickCount - Started < Timeout) {
		Sleep(25)
		if (Edit.Value != Last) {
			Last := Edit.Value
			Since := A_TickCount
		} else if (Last != "" && A_TickCount - Since >= _HCH_SettleMs) {
			break
		}
	}
	return A_TickCount - Since
}

; One session in a window the test owns, on the real watcher InputHook.
; @param Primitive {String} "SendInput" or "SendEvent", the burst primitive.
; @param Typed {String} The text typed, one character at a time.
; @param Gap {Integer} Milliseconds between two typed characters.
; @param Tap {String} Text typed after a Space tap-hold completion, "" for none.
; @return {Map} doc, buffer, then the document and buffer after one Backspace.
_HCH_RealSession(Primitive, Typed, Gap, Tap := "") {
	global _PrefixInputHook, _SendHook, _HotstringRegistrar, _AHK_SendInput
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
	Window := Gui("+AlwaysOnTop", "Ergopti hotstring chaining test")
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
		if (Primitive == "SendInput")
			_AHK_SendInput := (Keys) => SendInput(Keys)
		else
			_AHK_SendInput := (Keys) => SendEvent(Keys)
		HSE_RegistryClear()
		HSE_HardReset()
		HSE_FeedReset(true)
		Star := Chr(0x2605)
		_HCH_Register("*", "at" . Star, "att", 0.75)
		_HCH_Register("*", "att" . Star, "attention", 0.75)
		_HCH_Register("*", "attention" . Star, Chr(0x26A0) . Chr(0xFE0F), 0.75)
		_HCH_Register("*?", "ab", "cd")
		_HCH_Register("*?", "cde", "xyz")
		; An end-character trigger, completed by the Space tap-hold thread.
		_HCH_Register("?", "qzs", "cd")
		_HCH_Register("*?", "cd e", "xyz")
		_StartInputHook()
		try {
			SetTimer(_HCH_RealType.Bind(Typed, Gap), -1)
			if (Tap != "") {
				Sleep(600)
				SetTimer(_HCH_RealSpaceTapLike, -1)
				Sleep(300)
				SetTimer(_HCH_RealType.Bind(Tap, Gap), -1)
			}
			Result["settle"] := _HCH_RealSettle(Edit)
			Result["doc"] := Edit.Value
			Result["buffer"] := HSE_Buffer
			SetTimer(_HCH_RealType.Bind("{Backspace}", 0), -1)
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

_HCH_RealChains() {
	global _AHK_INTERACTIVE
	Assert(_AHK_INTERACTIVE, "foreground input requires explicit --interactive admission")
	Star := Chr(0x2605)
	Sign := Chr(0x26A0) . Chr(0xFE0F)
	Scenarios := [
		{ Name: "plain", Typed: "abe", Doc: "xyz", Tap: "" },
		{ Name: "magic", Typed: "at" . Star . Star . Star, Doc: Sign, Tap: "" },
		{ Name: "tap", Typed: "qzs", Doc: "xyz", Tap: "e" }
	]
	for Primitive in ["SendEvent", "SendInput"] {
		for Scenario in Scenarios {
			for Gap in [120, 20] {
				Label := Scenario.Name . " " . Primitive . " gap=" . Gap
				Run := _HCH_RealSession(Primitive, Scenario.Typed, Gap, Scenario.Tap)
				try FileAppend("# hotstring-chaining " . Label . " doc_len=" . StrLen(Run["doc"]) . " settle_ms=" . Run["settle"] . "`n", "*")
				AssertEqual(Scenario.Doc, Run["doc"], Label . ": the chain must end on the final text")
				AssertEqual(Run["doc"], Run["buffer"], Label . ": the engine buffer must equal the screen")
				AssertEqual(Run["doc_after_backspace"], Run["buffer_after_backspace"],
					Label . ": the buffer must follow the Backspace")
			}
		}
	}
}

Test("hotstring chaining: the real engine chains with SendEvent and with SendInput (hotstring-chaining)",
	_HCH_RealChains, true)
