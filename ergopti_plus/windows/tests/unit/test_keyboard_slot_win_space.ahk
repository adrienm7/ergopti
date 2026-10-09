; static/ergopti_plus/windows/tests/unit/test_keyboard_slot_win_space.ahk

; ==============================================================================
; MODULE: Ordinary Keyboard Slot Ownership Regressions
; DESCRIPTION:
; Windows binds Win+Space to "generate an AI prediction" through an ordinary
; keyboard slot (win_space), replacing the AI menu's own trigger shortcut. The
; slot must resolve to a native hotkey WITHOUT the "~" pass-through prefix:
; that prefix would let the press through, and Windows would still switch the
; input language on every prediction request.
;
; ROOT CAUSE ENCODED: the chord a slot id names and the native spec the
; registrar builds from it are two translations; this pins both for win_space,
; and the menu label the slot shows. The default binding itself lives in
; infra/feature_state.ahk, which the suite does not load; the JS gate
; test-keyboard-slot-recommended-bindings.cjs pins it to the manifest.
; Explicit editor assignments follow the same owner: existing assignments win,
; an explicit removal persists, and the action can move to another chord.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ The chord and its spec =======
; =========================================
; =========================================

_KSWS_WinSpaceResolvesToASuppressingSpec() {
	Chord := _KeyboardSlotChord("win_space")
	Parsed := ChordParse(Chord)
	Assert(Parsed["ok"], "win_space must resolve to a chord, got '" . Chord . "'")
	Spec := HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"])
	AssertEqual("#space", Spec,
		"win_space must register as #space, with no ~ prefix: the key must never reach Windows")
	AssertEqual("Win + " . t("common.key_space"), _FormatSlotLabel("win_space"),
		"the menu must name the chord in the user's language")
}
Test("Keyboard slots: win_space is a suppressing Win+Space hotkey (win-space-slot)",
	_KSWS_WinSpaceResolvesToASuppressingSpec)





; ================================================
; ================================================
; ======= 2/ User-owned editor assignments =======
; ================================================
; ================================================

_KSWS_EditorSlotRowsCount(Slot) {
	Count := 0
	Prefix := _FormatSlotLabel(Slot) . " : "
	for Group in KeyboardSlotRows() {
		for Row in Group["items"]
			if InStr(Row["label"], Prefix) == 1
				Count += 1
	}
	return Count
}

_KSWS_EditorSlotAssignmentsRemainUserOwned() {
	global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, _IniCache
	global GestureActionParameters, ConfigurationFile, GESTURE_ACTIONS, _Stub_SentText
	OldAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	OldDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	OldCache := _IniCache, OldParameters := GestureActionParameters
	OldPath := ConfigurationFile, OldActions := GESTURE_ACTIONS, OldSent := _Stub_SentText
	Path := A_Temp . "\ergopti_editor_slot_" . A_TickCount . ".toml"
	Source := '[shortcuts.keyboard]`nwin_d = "copy"`nwin_b = "open_hotstrings_editor"`nfuture_pair = "keep"`n[unowned]`ntext = "preserve"`n'
	EditorCalls := 0, CopyCalls := 0, WriteFailures := 0
	EditorAction(*) {
		EditorCalls += 1
	}
	CopyAction(*) {
		CopyCalls += 1
	}
	RefuseWrite(_Path, _Updates) {
		return false
	}
	ObserveFailure(_Message, _Options) {
		WriteFailures += 1
	}
	try {
		Assert(FSWriteDurable(Path, Source), "the private configuration must be durable")
		ConfigurationFile := Path
		_Stub_SentText := []
		GESTURE_ACTIONS := OldActions.Clone()
		GESTURE_ACTIONS["open_hotstrings_editor"] := { Fn: EditorAction }
		GESTURE_ACTIONS["copy"] := { Fn: CopyAction }
		GestureActionParameters := Map()
		KEYBOARD_SHORTCUT_DEFAULTS := Map("win_d", ManifestDefaultFor("shortcuts.keyboard.win_d"))
		KeyboardShortcutAssignments := Map()
		_IniCache := TOML_ParseFreshFile(Path)
		ReadKeyboardShortcutsConfig()
		AssertEqual("copy", KeyboardShortcutAssignments["win_d"],
			"reading defaults must preserve an existing personal Win+D assignment")
		AssertEqual("open_hotstrings_editor", KeyboardShortcutAssignments["win_b"],
			"the same editor action is accepted on an ordinary user-created slot")
		RunKeyboardShortcutAction("win_d")
		AssertEqual(1, CopyCalls, "the user's existing assignment remains the dispatched action")
		AssertEqual(0, EditorCalls, "the recommendation must never replace that assignment implicitly")
		RunKeyboardShortcutAction("win_b")
		AssertEqual(1, EditorCalls, "the editor action dispatches through its ordinary slot")

		Assert(SetKeyboardShortcutAction("win_d", "open_hotstrings_editor"),
			"explicitly assigning the editor must use the existing durable owner")
		AssertEqual("open_hotstrings_editor", TOML_ParseFreshFile(Path)["shortcuts.keyboard"]["win_d"])
		AssertEqual(1, _KSWS_EditorSlotRowsCount("win_d"),
			"the editor assignment is shown once in the ordinary Win shortcuts group")
		RunKeyboardShortcutAction("win_d")
		AssertEqual(2, EditorCalls, "an explicit assignment invokes the same catalogue action")

		Assert(SetKeyboardShortcutAction("win_d", "none"), "the user can remove the personal assignment")
		KeyboardShortcutAssignments := Map()
		_IniCache := TOML_ParseFreshFile(Path)
		ReadKeyboardShortcutsConfig()
		AssertEqual("none", KeyboardShortcutAssignments["win_d"],
			"a removed assignment survives reload instead of reinstalling the recommendation")
		AssertEqual(0, _KSWS_EditorSlotRowsCount("win_d"), "the removed assignment leaves the Win menu")
		RunKeyboardShortcutAction("win_d")
		AssertEqual(2, EditorCalls, "a removed assignment must never invoke the editor")
		Assert(SetKeyboardShortcutAction("win_b", "none"), "the prior custom editor slot can be removed too")
		Assert(SetKeyboardShortcutAction("win_g", "open_hotstrings_editor"),
			"the user can move the editor to any owned ordinary slot")
		RunKeyboardShortcutAction("win_b")
		RunKeyboardShortcutAction("win_g")
		AssertEqual(3, EditorCalls, "only the newly assigned chord invokes the editor")

		AssertEqual(4, _Stub_SentText.Length, "each committed edit requests the ordinary pause-preserving reload")
		for Event in _Stub_SentText
			AssertEqual("reload_preserving_suspend", Event.kind)
		BeforeRefusal := FSReadUtf8Exact(Path)
		AssertFalse(GestureAssignConfiguredAction(&KeyboardShortcutAssignments, "keyboard",
			"shortcuts.keyboard", "win_d", "open_hotstrings_editor", RefuseWrite, ObserveFailure),
			"a refused assignment must never publish its candidate action")
		AssertEqual(1, WriteFailures, "one refusal must report one persistence failure")
		AssertEqual("none", KeyboardShortcutAssignments["win_d"])
		AssertEqual(BeforeRefusal, FSReadUtf8Exact(Path), "refusal preserves the acknowledged file")
		RunKeyboardShortcutAction("win_d")
		AssertEqual(3, EditorCalls, "a refused candidate never becomes a live action")
		Persisted := TOML_ParseFreshFile(Path)
		AssertEqual("keep", Persisted["shortcuts.keyboard"]["future_pair"],
			"ordinary edits preserve unknown future assignments")
		AssertEqual("preserve", Persisted["unowned"]["text"], "unrelated settings remain untouched")
	} finally {
		KeyboardShortcutAssignments := IsSet(OldAssignments) ? OldAssignments : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(OldDefaults) ? OldDefaults : unset
		_IniCache := OldCache, GestureActionParameters := OldParameters
		ConfigurationFile := OldPath, GESTURE_ACTIONS := OldActions, _Stub_SentText := OldSent
		try FileDelete(Path)
	}
}
Test("Keyboard slots: personal editor assignments can be removed and rebound without replacing user actions (hotstrings-editor-ordinary-slot)",
	_KSWS_EditorSlotAssignmentsRemainUserOwned)
