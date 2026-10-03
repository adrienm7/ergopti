; tests/unit/test_script_control_submenu.ahk

; ==============================================================================
; MODULE: Script-Control Submenu
; DESCRIPTION:
; « Raccourcis de gestion du script » showed a title check mark nobody could
; change: the submenu held only its four slots. It follows the maintainer's
; first-group rule now (2026-09-30): the switch of the chords, the restore of
; their preset, the clear to the system's behaviour, a separator, then the four
; slots, and its title in the Shortcuts submenu is ticked while the switch is
; on. These tests draw the real submenu and click its rows
; (script-chords-switch-2026-09-30).
; ==============================================================================

global _SCSM_SLOTS := ["script_altgr_enter", "script_altgr_backspace", "script_altgr_delete",
	"script_altgr_escape"]

; The text of the row at a zero-based position of a native menu.
_SCSM_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Text := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Text, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Text, "UTF-16")
}

; The MF_* state bits of the row at a zero-based position.
_SCSM_StateAt(TargetMenu, Position) {
	return DllCall("GetMenuState", "ptr", TargetMenu.Handle, "uint", Position, "uint", 0x400, "uint")
}

; Runs Body with the script shortcut state a boot builds: the slots, their
; labels, every slot on its preset, and the switch at ChordsOn.
_SCSM_WithState(ChordsOn, Body) {
	global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, ScriptShortcutChordsOn
	global _SCSM_SLOTS
	SavedSlots := IsSet(SCRIPT_SHORTCUT_SLOTS) ? SCRIPT_SHORTCUT_SLOTS : unset
	SavedLabels := IsSet(SCRIPT_SHORTCUT_LABELS) ? SCRIPT_SHORTCUT_LABELS : unset
	SavedAssignments := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedOn := IsSet(ScriptShortcutChordsOn) ? ScriptShortcutChordsOn : unset
	SCRIPT_SHORTCUT_SLOTS := _SCSM_SLOTS
	SCRIPT_SHORTCUT_LABELS := Map()
	ScriptShortcutAssignments := Map()
	for Slot in _SCSM_SLOTS {
		SCRIPT_SHORTCUT_LABELS[Slot] := "sg_labels." . Slot
		ScriptShortcutAssignments[Slot] := ManifestRecommendedFor("shortcuts.script_control." . Slot)
	}
	ScriptShortcutChordsOn := ChordsOn
	try Body.Call()
	finally {
		SCRIPT_SHORTCUT_SLOTS := IsSet(SavedSlots) ? SavedSlots : unset
		SCRIPT_SHORTCUT_LABELS := IsSet(SavedLabels) ? SavedLabels : unset
		ScriptShortcutAssignments := IsSet(SavedAssignments) ? SavedAssignments : unset
		ScriptShortcutChordsOn := IsSet(SavedOn) ? SavedOn : unset
	}
}

; The drawn submenu: switch, restore, clear, separator, then the four slots, and
; the switch's tick and the title's tick follow the switch.
_SCSM_FirstGroupOrder() {
	_SCSM_WithState(true, _SCSM_AssertOrder.Bind(true))
	_SCSM_WithState(false, _SCSM_AssertOrder.Bind(false))
}
_SCSM_AssertOrder(ChordsOn) {
	global _SCSM_SLOTS
	static MF_CHECKED := 0x8, MF_SEPARATOR := 0x800
	Rendered := _SC_ScriptControlSubmenu(Map())
	try {
		AssertEqual(8, DllCall("GetMenuItemCount", "ptr", Rendered.Handle, "int"),
			"switch, restore, clear, separator and four slots")
		AssertEqual(t("menu.shortcuts.script_shortcuts_enable"), _SCSM_LabelAt(Rendered, 0), "the switch comes first")
		AssertEqual(ChordsOn, (_SCSM_StateAt(Rendered, 0) & MF_CHECKED) != 0, "the switch is ticked while it is on")
		AssertEqual(t("common.restore_recommended"), _SCSM_LabelAt(Rendered, 1), "the restore comes second")
		AssertEqual(t("common.clear_to_system"), _SCSM_LabelAt(Rendered, 2), "the clear comes third")
		Assert((_SCSM_StateAt(Rendered, 3) & MF_SEPARATOR) != 0, "a separator closes the first group")
		for Index, Slot in _SCSM_SLOTS {
			AssertEqual(1, InStr(_SCSM_LabelAt(Rendered, 3 + Index), t("sg_labels." . Slot) . " : "),
				Slot . " keeps its row, in order")
		}
	} finally Rendered.Delete()
	AssertEqual(ChordsOn, MenuRenderer_ResolveCheckedWhen("shortcuts_menu", "script_control", _SC_Getters()),
		"the Shortcuts submenu ticks the group's title while the switch is on")
}
Test("script-control submenu: switch, restore, clear, then the slots, and the title follows the switch (script-chords-switch-2026-09-30)",
	_SCSM_FirstGroupOrder)

; Clicking the switch writes its new state and reloads: off is written, on is
; the default and leaves no key.
_SCSM_SwitchCase(StartOn) {
	global ConfigurationFile
	Fixture := _ScopeOwnerFixture()
	OldConfig := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	Reloads := 0
	CountReload() {
		Reloads += 1
		return true
	}
	Fixture.options["toggle_reload"] := CountReload
	ClickSwitch() {
		global _MenuDispatchCallbacks
		Rendered := _SC_ScriptControlSubmenu(Fixture.options)
		try {
			ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
			AssertTrue((_MenuDispatchCallbacks[ItemId])(), "the switch row must write and reload")
		} finally Rendered.Delete()
	}
	try {
		ConfigurationFile := Fixture.path
		Assert(FSWriteDurable(Fixture.path, StartOn ? "" : '[shortcuts.script_control]`nchords_enabled = false`n'))
		_SCSM_WithState(StartOn, ClickSwitch)
		AssertEqual(1, Reloads, "the switch reloads so every chord reads it")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Section := Parsed.Has("shortcuts.script_control") ? Parsed["shortcuts.script_control"] : Map()
		if StartOn
			AssertEqual(0, Section.Get("chords_enabled", ""), "switching off is written")
		else
			AssertFalse(Section.Has("chords_enabled"), "switching on returns to the default")
	} finally {
		ConfigurationFile := IsSet(OldConfig) ? OldConfig : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("script-control submenu: the switch row turns the chords off (script-chords-switch-2026-09-30)",
	_SCSM_SwitchCase.Bind(true))
Test("script-control submenu: the switch row turns the chords back on (script-chords-switch-2026-09-30)",
	_SCSM_SwitchCase.Bind(false))

; A directory cannot accept config.toml bytes. The real persistence refusal
; must stop before the reload seam, keeping the current configuration intact.
_SCSM_RefusedSwitchDoesNotReload() {
	Fixture := _ScopeOwnerFixture()
	Reloads := []
	try {
		AssertFalse(SetScriptShortcutChordsOn(false, Fixture.directory,
			() => Reloads.Push("reload")), "the actual writer refuses a directory target")
		AssertEqual(0, Reloads.Length, "a failed commit cannot reload into uncommitted choices")
		AssertEqual(Fixture.source, FSReadStrict(Fixture.path), "the existing configuration stays byte-exact")
		Assert(DirExist(Fixture.directory), "the refusal cannot replace the directory")
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("script-control submenu: refused persistence never reloads the driver",
	_SCSM_RefusedSwitchDoesNotReload)

; The restore and the clear rows publish through the scope owner at once, with
; its backup and its rollback: the restore returns every slot and the switch to
; their preset (absent keys), the clear writes "none" in every slot and keeps
; the switch; both drop the parameters of script bindings only.
_SCSM_ScopeCase(Mode) {
	global GestureActionParameters, _SCSM_SLOTS
	Fixture := _ScopeOwnerFixture()
	Source := '[shortcuts.script_control]`nchords_enabled = false`nscript_altgr_enter = "none"`nscript_altgr_delete = "open_url"`n'
		. '[action_parameters]`nscript__script_altgr_delete__open_url = "https://script.test"`n'
		. 'keyboard__win_b__open_url = "https://keyboard.test"`n'
	Assert(FSWriteDurable(Fixture.path, Source))
	Bundle := 0, Refusal := 0, Receipt := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	ClickScopeRow() {
		global _MenuDispatchCallbacks
		Rendered := _SC_ScriptControlSubmenu(Fixture.options)
		try {
			ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", Mode == "clear" ? 2 : 1, "uint")
			Receipt := (_MenuDispatchCallbacks[ItemId])()
		} finally Rendered.Delete()
	}
	OldParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	try {
		GestureActionParameters := TOML_ParseFreshFile(Fixture.path)["action_parameters"].Clone()
		_SCSM_WithState(false, ClickScopeRow)
		AssertEqual("pending", Receipt["status"], "the row applies at once, without a question")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Section := Parsed.Has("shortcuts.script_control") ? Parsed["shortcuts.script_control"] : Map()
		for Slot in _SCSM_SLOTS {
			if (Mode == "clear")
				AssertEqual("none", Section.Get(Slot, ""), Slot . " is cleared to the system explicitly")
			else
				AssertFalse(Section.Has(Slot), Slot . " returns to its preset, the default")
		}
		if (Mode == "clear")
			AssertEqual(0, Section.Get("chords_enabled", ""), "the clear leaves the switch as it is")
		else
			AssertFalse(Section.Has("chords_enabled"), "the restore switches the chords back on")
		AssertFalse(Parsed["action_parameters"].Has("script__script_altgr_delete__open_url"),
			"a script binding's parameter goes with its slot")
		AssertEqual("https://keyboard.test", Parsed["action_parameters"]["keyboard__win_b__open_url"],
			"other bindings keep their parameters")
		Refusal.Call("native close refused")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "a refused reload puts the file back")
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		GestureActionParameters := IsSet(OldParameters) ? OldParameters : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("script-control submenu: the restore row returns every chord to its preset (script-chords-switch-2026-09-30)",
	_SCSM_ScopeCase.Bind("recommended"))
Test("script-control submenu: the clear row leaves every chord to the system (script-chords-switch-2026-09-30)",
	_SCSM_ScopeCase.Bind("clear"))
