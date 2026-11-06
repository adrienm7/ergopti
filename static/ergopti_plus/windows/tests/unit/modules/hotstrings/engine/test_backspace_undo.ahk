; tests/unit/modules/hotstrings/engine/test_backspace_undo.ahk

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
		AssertEqual("{BackSpace 3}{Text}adn", _BSU_LastBurst(),
			"the Space is already gone: the rest of the replacement is erased, then the trigger typed")
		AssertEqual("", HSE_Buffer, "the restored trigger stays out of the buffer")
		AssertFalse(HSE_StartIsWordBoundary, "and no word is known to start after it")
	} finally HSE_TestReset()
}
Test("hotstrings: an immediate Backspace restores the trigger (backspace-undo)", _BSU_BackspaceRestoresTheTrigger)

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
