; tests/unit/hotstrings/engine/engine/test_backspace_undo.ahk

; ==============================================================================
; MODULE: Immediate-Backspace Trigger Restoration (Windows)
; DESCRIPTION:
; A plain Backspace pressed right after a literal expansion brings its trigger
; back, as on Linux and macOS (decision of 2026-11-06, backspace-undo). The
; physical Backspace has already removed the last character the expansion
; typed, so the restore erases the rest and types the trigger. Before, Windows
; only shortened its buffers by one character and left the replacement.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Fixture =======
; ==========================
; ==========================

; Fires « adn » + Space through the production dispatcher.
; @returns {Object} The undo record the fire kept.
_BSU_FireAdn() {
	global HSE_Undoable, _PrefixFocusedControlToken
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	_PrefixFocusedControlToken := 1
	CreateHotstring("C", "adn", "ADN")
	HSE_FeedReset(true)
	HSE_FeedChar("a")
	HSE_FeedChar("d")
	HSE_FeedChar("n")
	Match := HSE_FeedChar(" ")
	Assert(IsObject(Match), "control: adn + Space matches")
	AssertTrue(HSE_DispatchMatch(Match, " "), "control: the expansion fires")
	return HSE_Undoable
}

_BSU_LastBurst() {
	global _Stub_RecordedSends
	return _Stub_RecordedSends.Length ? _Stub_RecordedSends[_Stub_RecordedSends.Length].args[1] : ""
}





; ==============================
; ==============================
; ======= 2/ Restoration =======
; ==============================
; ==============================

_BSU_BackspaceRestoresTheTrigger() {
	global HSE_Undoable, HSE_Buffer
	try {
		Undo := _BSU_FireAdn()
		Assert(IsObject(Undo), "a literal expansion keeps its undo record")
		AssertEqual("adn", Undo.Trigger, "the trigger is the text the fire erased")
		AssertEqual("ADN ", Undo.Typed, "the typed text includes the replayed Space")
		HSE_Undoable := ""
		Sent := _Stub_RecordedSends.Length
		AssertTrue(HSE_UndoExpansion(Undo, 1), "the immediate Backspace restores the trigger")
		AssertEqual(Sent + 1, _Stub_RecordedSends.Length, "one burst restores it")
		AssertEqual("{BackSpace 3}{Text}adn ", _BSU_LastBurst(),
			"the Space is already gone: the rest of the replacement is erased, then the trigger and its Space typed")
		AssertEqual("", HSE_Buffer, "the restored trigger stays out of the buffer")
		AssertTrue(HSE_StartIsWordBoundary, "and the Space typed back ends the word")
	} finally HSE_TestReset()
}
Test("hotstrings: an immediate Backspace restores the trigger and its Space (backspace-undo)",
	_BSU_BackspaceRestoresTheTrigger)

; Fires « pce » + Space into a host whose focused control has ControlClass,
; then restores it, and returns the burst.
_BSU_UndoBurstIn(Replacement, ControlClass) {
	global HSE_Undoable, _PrefixFocusedControlToken
	HSE_BackspaceStepsConfigure((Hwnd) => ControlClass)
	try {
		ResetHotstringRecorders()
		SimulateRegularApp()
		HSE_TestReset()
		_PrefixFocusedControlToken := 1
		CreateHotstring("C", "pce", Replacement)
		HSE_FeedReset(true)
		HSE_FeedChar("p")
		HSE_FeedChar("c")
		HSE_FeedChar("e")
		Match := HSE_FeedChar(" ")
		Assert(IsObject(Match), "control: pce + Space matches")
		AssertTrue(HSE_DispatchMatch(Match, " "), "control: the expansion fires")
		Undo := HSE_Undoable
		Assert(IsObject(Undo), "control: the expansion keeps its undo")
		HSE_Undoable := ""
		AssertTrue(HSE_UndoExpansion(Undo, 1), "the immediate Backspace restores the trigger")
		return _BSU_LastBurst()
	} finally {
		HSE_BackspaceStepsConfigure(0)
		HSE_TestReset()
	}
}

; One Backspace erases a whole emoji in a RichEdit or Chromium but one code
; point in an EDIT: counting code points everywhere left « ok » plus a lone
; base emoji's worth of Backspaces too many (backspace-steps).
_BSU_EmojiStepsFollowTheHost() {
	Thumb := Chr(0x1F44D) . Chr(0x1F3FD)
	Flag := Chr(0x1F1EB) . Chr(0x1F1F7)
	AssertEqual("{BackSpace 5}{Text}pce ", _BSU_UndoBurstIn("ok " . Thumb, "Edit"),
		"an EDIT erases the skin tone and its base one by one")
	AssertEqual("{BackSpace 4}{Text}pce ", _BSU_UndoBurstIn("ok " . Thumb, "RICHEDIT50W"),
		"a RichEdit erases the toned emoji with one Backspace")
	AssertEqual("{BackSpace 4}{Text}pce ", _BSU_UndoBurstIn("ok " . Thumb, "Chrome_RenderWidgetHostHWND"),
		"Chromium erases the toned emoji with one Backspace")
	AssertEqual("{BackSpace 2}{Text}pce ", _BSU_UndoBurstIn(Flag, "RichEditD2DPT"),
		"the Store Notepad's RichEdit erases a flag one indicator at a time")
	AssertEqual("{BackSpace 1}{Text}pce ", _BSU_UndoBurstIn(Flag, "Chrome_RenderWidgetHostHWND"),
		"Chromium erases a flag with one Backspace")
	AssertEqual("{BackSpace 3}{Text}pce ", _BSU_UndoBurstIn("ok" . Chr(0x2764) . Chr(0xFE0F), "Chrome_WidgetWin_1"),
		"a VS16 heart is one step in the omnibox too")
}
Test("hotstrings: the Backspace undo counts emoji as the focused host erases them (backspace-steps)",
	_BSU_EmojiStepsFollowTheHost)

; A ZWJ family is one step in Chromium, a combining accent two: the Undo
; erases exactly what the expansion left, never a character typed before it.
_BSU_EmojiReplacementErasedByCharacter() {
	Cases := [
		["Z" . Chr(0x1F44D) . Chr(0x1F3FD), "skin tone", 2],
		["Z" . Chr(0x1F468) . Chr(0x200D) . Chr(0x1F469) . Chr(0x200D) . Chr(0x1F467), "ZWJ family", 2],
		["Z" . Chr(0x1F1EB) . Chr(0x1F1F7), "flag", 2],
		["Ze" . Chr(0x301), "combining accent", 3]
	]
	for Row in Cases
		AssertEqual("{BackSpace " . Row[3] . "}{Text}pce ", _BSU_UndoBurstIn(Row[1], "Chrome_RenderWidgetHostHWND"),
			"Chromium: the Space is gone and only the " . Row[2] . " replacement is left to erase")
}
Test("hotstrings: the Backspace undo erases an emoji or accent replacement by character (windows-undo-graphemes)",
	_BSU_EmojiReplacementErasedByCharacter)

_BSU_AnEditVoidsTheUndo() {
	global HSE_Undoable
	try {
		Undo := _BSU_FireAdn()
		HSE_Undoable := ""
		HSE_FeedChar("x")
		Sent := _Stub_RecordedSends.Length
		AssertFalse(HSE_UndoExpansion(Undo, 1), "a character typed after the expansion voids the undo")
		AssertEqual(Sent, _Stub_RecordedSends.Length, "nothing is sent")
		Undo := _BSU_FireAdn()
		HSE_Undoable := ""
		_PrefixInvalidateInputContext(0, true)
		AssertFalse(HSE_UndoExpansion(Undo, 1), "a click or focus reset voids the undo")
		Undo := _BSU_FireAdn()
		HSE_Undoable := ""
		AssertFalse(HSE_UndoExpansion(Undo, 2), "another focused control voids the undo")
	} finally HSE_TestReset()
}
Test("hotstrings: an edit, a click or a focus change voids the Backspace undo (backspace-undo)",
	_BSU_AnEditVoidsTheUndo)

_BSU_OnlyTheNextKeyAndPlainBackspace() {
	global HSE_Undoable, _PrefixModifierIsDown
	SavedIsDown := _PrefixModifierIsDown
	try {
		_BSU_FireAdn()
		AssertFalse(_PrefixTakeUndoOnKeyDown(0x25), "an arrow is no Backspace")
		AssertEqual("", HSE_Undoable, "and it voids the undo")
		_BSU_FireAdn()
		AssertFalse(_PrefixTakeUndoOnKeyDown(0xA0), "a lone Shift neither restores")
		Assert(IsObject(HSE_Undoable), "nor voids the undo, so Shift+Backspace still restores")
		_PrefixModifierIsDown := (Name) => Name == "LControl"
		AssertFalse(_PrefixTakeUndoOnKeyDown(0x08), "Ctrl+Backspace stays the application's")
		AssertEqual("", HSE_Undoable, "and voids the undo")
	} finally {
		_PrefixModifierIsDown := SavedIsDown
		HSE_TestReset()
	}
}
Test("hotstrings: only the next plain or Shift Backspace restores (backspace-undo)",
	_BSU_OnlyTheNextKeyAndPlainBackspace)

_BSU_NonLiteralOutputKeepsNoUndo() {
	global HSE_Undoable, _PrefixFocusedControlToken
	try {
		ResetHotstringRecorders()
		SimulateRegularApp()
		HSE_TestReset()
		_PrefixFocusedControlToken := 1
		CreateHotstring("*", "qkz", "{Left}", Map("OnlyText", false))
		HSE_FeedReset(true)
		HSE_FeedChar("q")
		HSE_FeedChar("k")
		Match := HSE_FeedChar("z")
		Assert(IsObject(Match), "control: the Send-key entry matches")
		HSE_DispatchMatch(Match, "")
		AssertEqual("", HSE_Undoable, "a Send-key payload says nothing of what it typed")
		Dynamic := {Trigger: "qkz", Length: 3, Star: true, Replacement: () => "x", OnlyText: true}
		HSE_FeedReset(true)
		HSE_FeedChar("q")
		HSE_FeedChar("k")
		HSE_FeedChar("z")
		HSE_DispatchMatch(Dynamic, "")
		AssertEqual("", HSE_Undoable, "a dynamic replacement keeps no undo")
	} finally HSE_TestReset()
}
Test("hotstrings: a Send-key or dynamic output keeps no Backspace undo (backspace-undo)",
	_BSU_NonLiteralOutputKeepsNoUndo)

_BSU_KeyDownRoutesBackspace() {
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Body != "", "_OnPrefixKeyDown must be found")
	Take := InStr(Body, "_PrefixTakeUndoOnKeyDown(VK)")
	Assert(Take > 0, "the watcher's key-down offers every key to the undo")
	Assert(Take < InStr(Body, "_PrefixFeedBackspace()"), "before a Backspace shortens the buffers")
}
Test("hotstrings: the watcher's key-down asks the undo first (backspace-undo)", _BSU_KeyDownRoutesBackspace)





; ============================================================
; ============================================================
; ======= 3/ Magic key, terminators, option and window =======
; ============================================================
; ============================================================

; Runs Body with the Backspace undo settings, the magic key and a regular host
; in place, and restores all of them afterwards.
_BSU_WithSettings(Enabled, WindowMs, Body) {
	global HSE_BackspaceRestoreEnabled, HSE_BackspaceRestoreWindowMs, ScriptInformation
	global _PrefixFocusedControlToken
	SavedEnabled := HSE_BackspaceRestoreEnabled
	SavedWindow := HSE_BackspaceRestoreWindowMs
	HadMagic := IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")
	SavedMagic := HadMagic ? ScriptInformation["MagicKey"] : ""
	if !IsSet(ScriptInformation)
		ScriptInformation := Map()
	try {
		HSE_BackspaceRestoreEnabled := Enabled
		HSE_BackspaceRestoreWindowMs := WindowMs
		ScriptInformation["MagicKey"] := "★"
		ResetHotstringRecorders()
		SimulateRegularApp()
		HSE_TestReset()
		_PrefixFocusedControlToken := 1
		Body.Call()
	} finally {
		HSE_BackspaceRestoreEnabled := SavedEnabled
		HSE_BackspaceRestoreWindowMs := SavedWindow
		if HadMagic
			ScriptInformation["MagicKey"] := SavedMagic
		else
			ScriptInformation.Delete("MagicKey")
		HSE_TestReset()
	}
}

; Types Trigger through the production feed, then EndChar ("" for a trigger
; that fires on its last character), and dispatches the match.
; @returns {Object|String} The undo record the fire kept, "" when none.
_BSU_Fire(Options, Trigger, Output, EndChar) {
	global HSE_Undoable
	ResetHotstringRecorders()
	HSE_TestReset()
	CreateHotstring(Options, Trigger, Output)
	HSE_FeedReset(true)
	Match := ""
	Loop Parse Trigger
		Match := HSE_FeedChar(A_LoopField)
	if EndChar != ""
		Match := HSE_FeedChar(EndChar)
	Assert(IsObject(Match), "control: " . Trigger . " matches")
	AssertTrue(HSE_DispatchMatch(Match, EndChar), "control: " . Trigger . " fires")
	return HSE_Undoable
}

; The text the undo burst types back, "" when it typed none.
_BSU_TypedBack(Burst) {
	Position := InStr(Burst, "{Text}")
	return Position ? SubStr(Burst, Position + 6) : ""
}

; « td★ » fires on its magic key: the star is an action, not text, so the
; Backspace gives « td » back and never « td★ » (decision of 2026-11-19).
_BSU_AssertMagicKeyUndo() {
	global HSE_Undoable
	Undo := _BSU_Fire("*", "td★", "2026", "")
	Assert(IsObject(Undo), "the magic-key expansion keeps its undo record")
	AssertEqual("td★", Undo.Trigger, "the record keeps the typed trigger")
	AssertEqual("td", Undo.Restored, "and types it back without the magic key")
	HSE_Undoable := ""
	AssertTrue(HSE_UndoExpansion(Undo, 1, , , Undo.CommittedTick + 100), "the Backspace undoes the expansion")
	AssertEqual("{BackSpace 3}{Text}td", _BSU_LastBurst(),
		"the physical Backspace took the 6: the rest of 2026 goes and td comes back alone")
	AssertFalse(HSE_StartIsWordBoundary, "td is still the word being typed")
}
Test("hotstrings: a magic-key trigger comes back without the magic key (backspace-restore)",
	_BSU_WithSettings.Bind(true, 500, _BSU_AssertMagicKeyUndo))

; A terminator typed back after the output is part of what the user typed:
; « adn » and a comma, a Space or Enter come back whole, never as « ADN » and it.
_BSU_AssertTerminatorUndo() {
	global HSE_Undoable
	for EndChar in [",", " ", "`n"] {
		Expected := "adn" . EndChar
		Undo := _BSU_Fire("C", "adn", "ADN", EndChar)
		Assert(IsObject(Undo), "control: the expansion keeps its undo record")
		AssertEqual(Expected, Undo.Restored, "the terminator follows the trigger back")
		HSE_Undoable := ""
		AssertTrue(HSE_UndoExpansion(Undo, 1, , , Undo.CommittedTick + 100), "the Backspace undoes the expansion")
		AssertEqual("{BackSpace 3}{Text}" . Expected, _BSU_LastBurst(),
			"the output goes after the terminator the Backspace took, then trigger and terminator")
		AssertTrue(HSE_StartIsWordBoundary, "the terminator typed back ends the word")
	}
}
Test("hotstrings: a Backspace gives trigger and terminator back, not the output (backspace-restore)",
	_BSU_WithSettings.Bind(true, 500, _BSU_AssertTerminatorUndo))

; Within hotstrings.backspace_restore_window_ms the Backspace undoes; past it,
; it is a plain Backspace that deletes the last character.
_BSU_AssertWindow(ElapsedMs, Undoes) {
	global HSE_Undoable
	Undo := _BSU_Fire("C", "adn", "ADN", " ")
	HSE_Undoable := ""
	Sent := _Stub_RecordedSends.Length
	AssertEqual(Undoes, HSE_UndoExpansion(Undo, 1, , , Undo.CommittedTick + ElapsedMs),
		ElapsedMs . " ms after the expansion")
	AssertEqual(Sent + (Undoes ? 1 : 0), _Stub_RecordedSends.Length,
		Undoes ? "the undo goes out" : "past the window nothing is sent: the Backspace deletes the Space")
}
_BSU_TheWindowBoundsTheUndo() {
	_BSU_WithSettings(true, 500, _BSU_AssertWindow.Bind(500, true))
	_BSU_WithSettings(true, 500, _BSU_AssertWindow.Bind(501, false))
	_BSU_WithSettings(true, 2000, _BSU_AssertWindow.Bind(1000, true))
}
Test("hotstrings: the Backspace undo lasts its window, then deletes a character (backspace-restore)",
	_BSU_TheWindowBoundsTheUndo)

; Off, an expansion keeps no undo and an older record no longer restores.
_BSU_AssertOffKeepsNoUndo() {
	AssertEqual("", _BSU_Fire("C", "adn", "ADN", " "), "an expansion keeps no undo while the option is off")
}
_BSU_AssertOffVoidsARecord() {
	global HSE_Undoable, HSE_BackspaceRestoreEnabled
	Undo := _BSU_Fire("C", "adn", "ADN", " ")
	HSE_Undoable := ""
	HSE_BackspaceRestoreEnabled := false
	Sent := _Stub_RecordedSends.Length
	AssertFalse(HSE_UndoExpansion(Undo, 1, , , Undo.CommittedTick + 10), "turned off, the record restores nothing")
	AssertEqual(Sent, _Stub_RecordedSends.Length, "and nothing is sent")
}
_BSU_OptionOffKeepsThePlainBackspace() {
	_BSU_WithSettings(false, 500, _BSU_AssertOffKeepsNoUndo)
	_BSU_WithSettings(true, 500, _BSU_AssertOffVoidsARecord)
}
Test("hotstrings: the Backspace undo option off keeps a plain Backspace (backspace-restore)",
	_BSU_OptionOffKeepsThePlainBackspace)

; Escape, or any other key, between the expansion and the Backspace ends the undo.
_BSU_AssertKeyBetween() {
	global HSE_Undoable
	_BSU_Fire("C", "adn", "ADN", " ")
	AssertFalse(_PrefixTakeUndoOnKeyDown(0x1B), "Escape is no Backspace")
	AssertEqual("", HSE_Undoable, "and it ends the undo")
	Sent := _Stub_RecordedSends.Length
	AssertFalse(_PrefixTakeUndoOnKeyDown(0x08), "the Backspace after it is a plain Backspace")
	AssertEqual(Sent, _Stub_RecordedSends.Length, "nothing is sent")
}
Test("hotstrings: another key between the expansion and Backspace ends the undo (backspace-restore)",
	_BSU_WithSettings.Bind(true, 500, _BSU_AssertKeyBetween))

; One corpus vector through the dispatcher's own undo.
_BSU_ReplayVector(Vector, Replay, KeyBetween) {
	global HSE_Undoable
	Undo := _BSU_Fire(Replay == "" ? "*C" : "C", Vector["trigger"], Vector["output"], Replay)
	if !Vector["enabled"] {
		AssertEqual("", Undo, Vector["id"] . ": off, the expansion keeps no undo")
		return
	}
	if KeyBetween {
		_PrefixTakeUndoOnKeyDown(0x1B)
		AssertEqual("", HSE_Undoable, Vector["id"] . ": the other key ends the undo")
		return
	}
	HSE_Undoable := ""
	Sent := _Stub_RecordedSends.Length
	Restored := HSE_UndoExpansion(Undo, 1, , , Undo.CommittedTick + Vector["elapsed_ms"])
	AssertEqual(Vector["undoes"] ? true : false, Restored ? true : false, Vector["id"] . ": undoes")
	if Vector["undoes"]
		AssertEqual(Vector["screen_after"], _BSU_TypedBack(_BSU_LastBurst()), Vector["id"] . ": the text typed back")
	else
		AssertEqual(Sent, _Stub_RecordedSends.Length, Vector["id"] . ": a plain Backspace sends nothing")
}

; The shared corpus, replayed through the AutoHotkey rule and, for every vector
; a typed hotstring can produce, through the dispatcher's own undo.
_BSU_ReplaysTheSharedCorpus() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\backspace_restore_vectors.json"
	if !FileExist(Path)
		throw Error("shared corpus not found at '" . Path . "'")
	Vectors := JsonParse(FileRead(Path, "UTF-8"))["vectors"]
	AssertTrue(Vectors.Length >= 10, "the corpus lists its vectors")
	Replayed := 0
	for Vector in Vectors {
		Terminator := Vector.Has("terminator") ? Vector["terminator"] : ""
		Consumed := Vector.Has("terminator_consumed") and Vector["terminator_consumed"]
		KeyBetween := Vector.Has("key_between") and Vector["key_between"]
		Replay := Consumed ? "" : Terminator
		Undoes := Vector["enabled"] and !KeyBetween
			and HSE_BackspaceRestoreWithinWindow(0, Vector["elapsed_ms"], Vector["window_ms"])
		Screen := Vector["output"] . Replay
		Screen := Undoes ? HSE_BackspaceRestoredText(Vector["trigger"], Vector["magic_key"], Replay)
			: SubStr(Screen, 1, StrLen(Screen) - _TextTailCodeUnits(Screen, 1))
		AssertEqual(Vector["undoes"] ? true : false, Undoes ? true : false, Vector["id"] . ": undoes")
		AssertEqual(Vector["screen_after"], Screen, Vector["id"] . ": " . Vector["description"])
		; A consumed terminator and the repeat key need their own catalogue: the
		; rule above covers them, the typed hotstrings go through the dispatcher.
		if (Consumed or Vector["trigger"] == Vector["magic_key"])
			continue
		Replayed += 1
		_BSU_WithSettings(Vector["enabled"], Vector["window_ms"],
			_BSU_ReplayVector.Bind(Vector, Replay, KeyBetween))
	}
	AssertTrue(Replayed >= 8, "most vectors go through the dispatcher")
}
Test("hotstrings: the Backspace undo replays the shared backspace_restore_vectors corpus (backspace-restore-vectors)",
	_BSU_ReplaysTheSharedCorpus)
