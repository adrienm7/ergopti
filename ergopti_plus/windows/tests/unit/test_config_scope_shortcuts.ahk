; tests/unit/test_config_scope_shortcuts.ahk

; @param {String} Mode "recommended" or "clear".
; @param {Boolean} FromManifest True to draw the row the Shortcuts submenu
;   declares (only the restore has one) instead of the agreed command id.
_ScopeShortcutsCase(Mode, FromManifest := false) {
	global _PersonalShortcutsRegistry, Features, KeyboardShortcutAssignments, _IniCache
	global GestureActionParameters, _MenuDispatchCallbacks, KEYBOARD_SHORTCUT_DEFAULTS
	OldRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	OldFeatures := IsSet(Features) ? Features : unset, OldKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset, OldCache := IsSet(_IniCache) ? _IniCache : unset
	OldDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	OldParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	Fixture := _ScopeOwnerFixture()
	Source := '[shortcuts.personal]`n"custom tool" = true`nunknown_user = true`n[shortcuts.keyboard]`nwin_b = "open_url"`nwin_cc = "open_url"`n[category_enabled]`nshortcuts = true`n[llm]`nenabled = true`n[action_parameters]`nkeyboard__win_b__open_url = "https://keyboard.test"`nscript__pause__open_url = "https://script.test"`ntap_key__grave__open_url = "https://tap.test"`ngesture__tap_4__open_url = "https://gesture.test"`ntap_hold__space__open_url = "https://hold.test"`nunknown_user = "keep"`n'
	Assert(FSWriteDurable(Fixture.path, Source))
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	Rendered := Menu()
	try {
		_PersonalShortcutsRegistry := Map("__Order", [])
		Features := Map("shortcuts", Map("personal", Map("custom tool", true)))
		RegisterPersonalFeature("custom tool", false, "scope fixture")
		_IniCache := TOML_ParseFreshFile(Fixture.path)
		KeyboardShortcutAssignments := Map()
		KEYBOARD_SHORTCUT_DEFAULTS := Map("win_space", ManifestDefaultFor("shortcuts.keyboard.win_space"))
		ReadKeyboardShortcutsConfig()
		GestureActionParameters := _IniCache["action_parameters"].Clone()
		AssertEqual(KeyboardShortcutAssignments["win_b"], "open_url")
		Factory := "_SC_ScopeCommands"
		Commands := %Factory%(Fixture.options)
		Id := Mode == "clear" ? "scope_clear" : "scope_restore"
		if FromManifest
			Drawn := MenuRenderer_AppendCommand(Rendered, "shortcuts_menu", Id, Commands)
		else
			Drawn := _ScopeTestRenderCommand(Rendered, "shortcuts_menu", Id, Commands)
		AssertEqual(Drawn, 1, "the Shortcuts submenu must draw " . Id)
		ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
		Assert(ObjPtr(_MenuDispatchCallbacks[ItemId]) == ObjPtr(Commands[Id]),
			"the drawn row must dispatch the scope command the submenu registers")
		Receipt := (_MenuDispatchCallbacks[ItemId])()
		AssertEqual(Receipt["status"], "pending")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Assert(!Parsed["shortcuts.personal"].Has("custom tool"))
		AssertEqual(Parsed["shortcuts.personal"]["unknown_user"], true)
		Assert(!Parsed["shortcuts.keyboard"].Has("win_b"), "the ConfigIO-owned custom slot must be cleared")
		AssertEqual(Parsed["shortcuts.keyboard"]["win_cc"], "open_url", "an unknown slot is preserved")
		for Key in ["keyboard__win_b__open_url", "script__pause__open_url", "tap_key__grave__open_url"]
			Assert(!Parsed["action_parameters"].Has(Key), "selected parameters are removed: " . Key)
		AssertEqual(Parsed["action_parameters"]["gesture__tap_4__open_url"], "https://gesture.test")
		AssertEqual(Parsed["action_parameters"]["tap_hold__space__open_url"], "https://hold.test")
		AssertEqual(Parsed["action_parameters"]["unknown_user"], "keep")
		AssertEqual(Parsed["llm"]["enabled"], true)
		if Mode == "clear"
			Assert(!Parsed["category_enabled"].Has("shortcuts"))
		else
			AssertEqual(Parsed["category_enabled"]["shortcuts"], ManifestRecommendedFor("category_enabled.shortcuts"))
		AssertEqual(Features["shortcuts"]["personal"]["custom tool"], true, "desired state stays untouched before acknowledgement")
		AssertEqual(KeyboardShortcutAssignments["win_b"], "open_url")
		Refusal.Call("native close refused")
		AssertEqual(Receipt["status"], "refused")
		AssertEqual(FSReadUtf8Exact(Fixture.path), Source)
	} finally {
		Rendered.Delete()
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_PersonalShortcutsRegistry := IsSet(OldRegistry) ? OldRegistry : unset
		Features := IsSet(OldFeatures) ? OldFeatures : unset, KeyboardShortcutAssignments := IsSet(OldKeyboard) ? OldKeyboard : unset, _IniCache := IsSet(OldCache) ? OldCache : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(OldDefaults) ? OldDefaults : unset
		GestureActionParameters := IsSet(OldParameters) ? OldParameters : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config-scope-shortcuts: restore owns registered preferences and recovers refusal", _ScopeShortcutsCase.Bind("recommended"))
Test("config-scope-shortcuts: clear owns registered preferences and recovers refusal", _ScopeShortcutsCase.Bind("clear"))

_ScopeShortcutsUnavailableInventory() {
	global _PersonalShortcutsRegistry
	OldRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	Fixture := _ScopeOwnerFixture()
	Source := FSReadUtf8Exact(Fixture.path)
	Backups := 0, Launches := 0
	Backup(*) {
		Backups += 1
		return false
	}
	Launch(*) {
		Launches += 1
		return false
	}
	Fixture.options["backup"] := Backup, Fixture.options["reload"] := Launch
	try {
		_PersonalShortcutsRegistry := Map("__Order", ["not registered"])
		Receipt := (_SC_ScopeCommands(Fixture.options)["scope_clear"])()
		AssertEqual(Receipt["status"], "refused")
		AssertEqual(Backups, 0, "invalid owner inventory is rejected before backup")
		AssertEqual(Launches, 0)
		AssertEqual(FSReadUtf8Exact(Fixture.path), Source)
	} finally {
		_PersonalShortcutsRegistry := IsSet(OldRegistry) ? OldRegistry : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config-scope-shortcuts: invalid owner inventory refuses before publication", _ScopeShortcutsUnavailableInventory)
