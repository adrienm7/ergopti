; tests/meta/modules/hotstrings/prefix/test_prefix_keydown_ctrl_backspace_reset.ahk

; ==============================================================================
; MODULE: Ctrl context resets for hotstring buffers
; DESCRIPTION:
; _OnPrefixKeyDown's CtrlHeld block handled Ctrl+A/X/V/Z/Y but not Ctrl+Backspace,
; which fell through to the plain VK==0x08 branch that models exactly ONE char
; removed. But Ctrl+Backspace deletes a whole WORD on screen, so the engine buffer
; ended up ahead of the screen; a later trigger match then fired an expansion whose
; {BackSpace N} chewed into unrelated text. Ctrl+Backspace destroys an unknown
; amount left of the cursor, so it must wipe both buffers like Ctrl+X, not
; decrement them by one (F20, audit 2026-07-20). Since 2026-10-21 the wipe
; starts a word, as the caret then sits where the deleted word began; its
; behaviour is pinned in test_hotstring_backspace_word_start.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

; A physical key going down under the named modifiers, through the live callback.
_PKCB_KeyOnWord(VK, SC, Word, Down*) {
	global _PrefixModifierIsDown, HSE_Buffer, _PrefixBuffer
	SavedEngine := HSE_Buffer
	SavedPreview := _PrefixBuffer
	Held := Map()
	for _, Name in Down
		Held[Name] := true
	HSE_Buffer := Word
	_PrefixBuffer := Word
	_PrefixModifierIsDown := (Name) => Held.Has(Name)
	try {
		_OnPrefixKeyDown(0, VK, SC)
		return { Engine: HSE_Buffer, Preview: _PrefixBuffer }
	} finally {
		_PrefixModifierIsDown := (*) => false
		HSE_Buffer := SavedEngine
		_PrefixBuffer := SavedPreview
	}
}

_PKCB_CtrlBackspaceResetsBuffer() {
	Word := _PKCB_KeyOnWord(0x08, 0x0E, "abc", "LControl")
	AssertEqual("", Word.Engine, "Ctrl+Backspace deletes a whole word, so the engine buffer must be wiped")
	AssertEqual("", Word.Preview, "Ctrl+Backspace deletes a whole word, so the preview buffer must be wiped")
	; Whatever the settings say: the generic shortcut branch would keep the word here.
	global HSE_ShortcutResetsWord
	SavedFlag := HSE_ShortcutResetsWord
	HSE_ShortcutResetsWord := false
	try {
		Word := _PKCB_KeyOnWord(0x08, 0x0E, "abc", "LControl")
		AssertEqual("", Word.Engine, "Ctrl+Backspace wipes the engine with hotstrings.shortcut_resets_word off")
		Kept := _PKCB_KeyOnWord(0x56, 0x2F, "abc", "LControl")
		AssertEqual("abc", Kept.Engine, "Ctrl+V keeps the word with hotstrings.shortcut_resets_word off")
	} finally {
		HSE_ShortcutResetsWord := SavedFlag
	}
	; The plain key is what proves the chord took another branch.
	Plain := _PKCB_KeyOnWord(0x08, 0x0E, "abc")
	AssertEqual("ab", Plain.Engine, "a plain Backspace removes exactly one character from the engine")
	AssertEqual("ab", Plain.Preview, "a plain Backspace removes exactly one character from the preview")
}
Test("hotstrings: Ctrl+Backspace resets the buffer as a word-delete, not a one-char decrement",
	_PKCB_CtrlBackspaceResetsBuffer)

; Ctrl+F and Ctrl+L move the focus; AltGr's synthetic Ctrl is typing, not a chord.
_PKCB_RelocationChordPolicy() {
	global _PrefixFocusedControlToken
	Saved := _PrefixFocusedControlToken
	try {
		for VK in [0x46, 0x4C] {
			_PrefixFocusedControlToken := 77
			AssertTrue(_PrefixHandleCtrlContextChord(VK, true, false), "Ctrl+" . Chr(VK) . " relocates the focus")
			AssertEqual(0, _PrefixFocusedControlToken, "Ctrl+" . Chr(VK) . " publishes an unknown focus token")
			_PrefixFocusedControlToken := 77
			AssertFalse(_PrefixHandleCtrlContextChord(VK, true, true), "AltGr+" . Chr(VK) . " is typing")
			AssertEqual(77, _PrefixFocusedControlToken, "AltGr+" . Chr(VK) . " keeps the focus token")
			AssertFalse(_PrefixHandleCtrlContextChord(VK, false, false), "the bare key is typing")
		}
		_PrefixFocusedControlToken := 77
		AssertFalse(_PrefixHandleCtrlContextChord(0x4B, true, false), "Ctrl+K moves no focus")
		AssertEqual(77, _PrefixFocusedControlToken, "Ctrl+K keeps the focus token")
	} finally {
		_PrefixFocusedControlToken := Saved
	}
}
Test("hotstrings input-context-generation: Ctrl+F and Ctrl+L relocate, AltGr does not",
	_PKCB_RelocationChordPolicy)

; AHK-06 cannot be covered by the pure engine alone: the production InputHook
; entry points must consult the WindowInfo adapter and the physical AltGr state.
; Keep this small source guard beside behavior tests that drive the canonical
; generation helpers and assert the resulting match/send/preview state.
_PKCB_FocusedControlGenerationIsWiredToLiveCallbacks() {
	OnChar := _DriverFuncBody("_OnPrefixChar")
	Ensure := _DriverFuncBody("_PrefixEnsureInputContext")
	Invalidate := _DriverFuncBody("_PrefixInvalidateInputContext")
	Commit := _DriverFuncBody("_PrefixCommitInputContext")
	OnKeyDown := _DriverFuncBody("_OnPrefixKeyDown")
	Chord := _DriverFuncBody("_PrefixHandleCtrlContextChord")
	Assert(OnChar != "" and Ensure != "" and Invalidate != "" and Commit != ""
		and OnKeyDown != "" and Chord != "",
		"input-context generation helpers and both live InputHook callbacks must be readable")

	ProbePos := InStr(Ensure, "WIGetFocusedControlToken()")
	Assert(ProbePos > 0,
		"production focus verification must use the WindowInfo focused-control adapter")
	EnsurePos := InStr(OnChar, "_PrefixEnsureInputContext()")
	FeedPos := InStr(OnChar, "HSEMatch := HSE_FeedChar(Char, true)")
	Assert(EnsurePos > 0 and FeedPos > EnsurePos,
		"OnChar must verify the focused-control generation before feeding a character to HSE")

	CriticalPos := InStr(Invalidate, 'Critical("On")')
	CommitCallPos := InStr(Invalidate, "_PrefixCommitInputContext(FocusToken, KnownBoundary, AtLineStart)", true, CriticalPos)
	RestorePos := InStr(Invalidate, "Critical(PreviousCritical)", true, CommitCallPos)
	EngineResetPos := InStr(Commit, "HSE_FeedReset(")
	PreviewResetPos := InStr(Commit, '_PrefixSetBuffer("")')
	GenerationPos := InStr(Commit, "_PrefixInputContextGeneration += 1")
	Assert(CriticalPos > 0 and CommitCallPos > CriticalPos and RestorePos > CommitCallPos
		and EngineResetPos > 0 and PreviewResetPos > EngineResetPos
		and GenerationPos > EngineResetPos and GenerationPos > PreviewResetPos,
		"one Critical transaction must clear engine + preview before publishing the new generation")

	AltGrPos := InStr(OnKeyDown, 'KS_IsDown("RAlt")')
	ChordPos := InStr(OnKeyDown, "_PrefixHandleCtrlContextChord(VK, CtrlHeld, AltGrHeld)")
	Assert(AltGrPos > 0 and ChordPos > AltGrPos,
		"the live keydown callback must resolve AltGr before delegating Ctrl context policy")
}
Test("hotstrings input-context-generation: live callbacks enforce focused-control ownership",
	_PKCB_FocusedControlGenerationIsWiredToLiveCallbacks)
