; tests/unit/test_global_config_scope.ahk

; One real WAL and detached owners; only the terminal replacement is injected.
_GlobalScopeComposition(Mode, Scenario := "late") {
	global _PersonalShortcutsRegistry, KeyboardShortcutAssignments, GestureActionParameters, _SharedDir
	global _MenuDispatchCallbacks
	OldRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	OldKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	OldParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	Fixture := _HotstringsScopeFixture(9)
	TapPath := Fixture.directory . "\tap_hold.toml"
	TapSource := '[tap_hold]`ninherit_defaults = true`n[tap_hold.keys.space]`ntap_action = "open_url"`ntime_activation_seconds = 0.9`n[private]`nunknown = "keep"`n'
	; Real line feeds: escaped backticks once left both switches out of the file,
	; so the clear's assertion on the Tap-Holds switch could not fail.
	Assert(InStr(Fixture.source, "[category_enabled]`n"), "the fixture declares the category switches")
	ConfigSource := StrReplace(Fixture.source, "[category_enabled]`n", "[category_enabled]`nshortcuts = true`ntap_holds = true`n") . '[layout]`nergopti_base = true`n[shortcuts.personal]`n"registered tool" = true`nunknown_user = true`n[shortcuts.keyboard]`nwin_b = "open_url"`nwin_cc = "unknown"`n[gestures]`ntap_4 = "open_url"`n[llm]`nenabled = true`nollama_port = 12345`n[metrics]`nenabled = true`nmetrics_enabled = true`nwpm_widget_visible = true`n[action_parameters]`ngesture__tap_4__open_url = "gesture"`nkeyboard__win_b__open_url = "keyboard"`ntap_hold__space__open_url = "hold"`nunknown_user = "keep"`n'
	if Scenario == "absent"
		ConfigSource := StrReplace(ConfigSource, '`nenabled = true`n', '`n')
	Assert(FSWriteDurable(Fixture.path, ConfigSource))
	Assert(FSWriteDurable(TapPath, TapSource))
	CredentialPath := Fixture.directory . "\api_entries.json"
	Assert(FSWriteDurable(CredentialPath, '{"token":"keep"}'))
	Fixture.options["tap_hold_path"] := TapPath
	Fixture.options["tap_hold_defaults"] := _SharedDir . "\tap_hold\defaults.toml"
	Bundle := 0, Refusal := 0, Launches := 0, Backups := 0, RefuseMove := false
	Port := ConfigTransitionProductionPort()
	Move(Source, Destination) {
		return RefuseMove ? false : FSAtomicMoveReplace(Source, Destination)
	}
	Port["move_replace"] := Move
	Fixture.options["port"] := Port
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused, Launches += 1
		if Scenario == "debt"
			RefuseMove := true
		return Scenario != "immediate" && Scenario != "debt"
	}
	Backup(Path, Content) {
		Backups += 1
		if Scenario == "backup" && Backups == 12
			return false
		if Scenario == "external" && Backups == 12
			Assert(FSWriteDurable(TapPath, TapSource . "# external edit`n"))
		return FSWriteCreateDurable(Path, Content)
	}
	Fixture.options["reload"] := Launch, Fixture.options["backup"] := Backup
	Rendered := Menu()
	try {
		_PersonalShortcutsRegistry := Map("__Order", ["registered tool"], "registered tool", Map())
		KeyboardShortcutAssignments := Map("win_b", "open_url")
		GestureActionParameters := TOML_ParseFreshFile(Fixture.path)["action_parameters"].Clone()
		; Both rows of the Configuration menu's first group dispatch to the
		; global owner: « Restaurer » first, « Tout effacer » second, then a
		; separator (menu-first-group). An inert cleanup row follows it, so the
		; renderer draws the separator.
		Factory := "_MI_GlobalScopeCommands"
		Commands := %Factory%(Fixture.options)
		Commands["clean_unused_keys"] := (*) => ""
		Id := Mode == "clear" ? "scope_clear" : "scope_restore"
		Rendered.Delete()
		Rendered := MenuRenderer_Build("configuration_menu", "Configuration", "", "", "", Commands,
			Map("start_at_login_enabled", (*) => false))
		ItemId := 0, Position := -1
		Loop TrayMenuItemCount(Rendered) {
			Candidate := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", A_Index - 1, "uint")
			if _MenuDispatchCallbacks.Has(Candidate) && ObjPtr(_MenuDispatchCallbacks[Candidate]) == ObjPtr(Commands[Id])
				ItemId := Candidate, Position := A_Index - 1
		}
		Assert(ItemId != 0, "the Configuration " . Id . " row must dispatch to the global owner")
		AssertEqual(Mode == "clear" ? 1 : 0, Position, "the global scope rows open the Configuration menu")
		Assert(TrayMenuIsSeparatorAt(Rendered, 2), "a separator closes the Configuration first group")
		Receipt := (_MenuDispatchCallbacks[ItemId])()
		AssertEqual(12, Backups, "all stores reach one coordinated backup boundary")
		if Scenario == "backup" || Scenario == "external" {
			AssertEqual(0, Launches)
			AssertEqual("refused", Receipt["status"])
		} else if Scenario == "debt" {
			AssertEqual(1, Launches)
			AssertEqual("recovery_required", Receipt["status"])
			for Path in [Fixture.path, Fixture.overrides, TapPath] {
				Assert(_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object)
				Assert(!_ConfigWriteLeaseTryAcquire(Path, "refused-during-recovery"))
			}
			for Path in Fixture.personal
				Assert(!_ConfigWriteLeaseTryAcquire(Path, "refused-personal-recovery"))
			RefuseMove := false
			Recovered := ConfigTransitionRollbackOwned(Fixture.options["locator"], Bundle, Port)
			Assert(ConfigTransitionResultIs(Recovered, "recovered_old"))
		} else if Scenario == "immediate" {
			AssertEqual(1, Launches)
			AssertEqual("refused", Receipt["status"])
		} else {
			AssertEqual(1, Launches)
			AssertEqual("pending", Receipt["status"])
			Parsed := TOML_ParseFreshFile(Fixture.path)
			AssertEqual("keep", Parsed["private"]["credential"])
			AssertEqual(true, Parsed["shortcuts.personal"]["unknown_user"])
			AssertEqual("unknown", Parsed["shortcuts.keyboard"]["win_cc"])
			Assert(!Parsed["shortcuts.personal"].Has("registered tool"))
			Assert(!Parsed["shortcuts.keyboard"].Has("win_b"))
			Assert(!Parsed["llm"].Has("ollama_port"))
			if Mode == "clear" {
				Assert(!Parsed["gestures"].Has("tap_4"))
				AssertEqual(true, Parsed["category_enabled"]["tap_holds"],
					"no clear rewrites the Tap-Holds switch (tap-hold-clear-keeps-switch)")
				Assert(!Parsed["category_enabled"].Has("shortcuts"), "the other category switches are still cleared")
			} else {
				AssertEqual(ManifestRecommendedFor("gestures.tap_4"), Parsed["gestures"]["tap_4"])
				AssertEqual(ManifestRecommendedFor("category_enabled.tap_holds"), Parsed["category_enabled"]["tap_holds"])
			}
			for Key in ["gesture__tap_4__open_url", "keyboard__win_b__open_url", "tap_hold__space__open_url"]
				Assert(!Parsed["action_parameters"].Has(Key))
			AssertEqual("keep", Parsed["action_parameters"]["unknown_user"])
			for Scope in ["llm", "metrics"] {
				if Mode == "clear" || Scenario == "absent"
					Assert(!Parsed[Scope].Has("enabled"), "no consent is created")
				else
					AssertEqual(true, Parsed[Scope]["enabled"], "existing consent is preserved")
			}
			if Mode == "clear"
				Assert(!Parsed["layout"].Has("ergopti_base"))
			else
				AssertEqual(ManifestRecommendedFor("layout.ergopti_base"), Parsed["layout"]["ergopti_base"])
			Assert(!TOML_ParseFreshFile(Fixture.overrides)["autocorrection"].Has("delay"))
			for PersonalPath in Fixture.personal {
				Assert(!TOML_ParseFreshFile(PersonalPath)["_meta"].Has("delay"))
				AssertContains(FSReadUtf8Exact(PersonalPath), '"abc" = "replacement"')
				Assert(!_ConfigWriteLeaseTryAcquire(PersonalPath, "foreign-writer"))
			}
			Assert(FSReadUtf8Exact(TapPath) != TapSource)
			AssertContains(FSReadUtf8Exact(TapPath), 'unknown = "keep"')
			Refusal.Call("native close refused")
			AssertEqual("refused", Receipt["status"])
		}
		AssertEqual(ConfigSource, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
		for PersonalPath in Fixture.personal
			AssertEqual(Fixture.personalSource, FSReadUtf8Exact(PersonalPath))
		AssertEqual(TapSource . (Scenario == "external" ? "# external edit`n" : ""), FSReadUtf8Exact(TapPath))
		AssertEqual('{"token":"keep"}', FSReadUtf8Exact(CredentialPath))
	} finally {
		Rendered.Delete()
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_PersonalShortcutsRegistry := IsSet(OldRegistry) ? OldRegistry : unset
		KeyboardShortcutAssignments := IsSet(OldKeyboard) ? OldKeyboard : unset
		GestureActionParameters := IsSet(OldParameters) ? OldParameters : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("global-config-scope: real Restore dispatch publishes twelve stores and compensates refusal", _GlobalScopeComposition.Bind("recommended"))
Test("global-config-scope: real Clear dispatch removes owned overrides and compensates every file", _GlobalScopeComposition.Bind("clear"))
Test("global-config-scope: recommendations preserve absent consent", _GlobalScopeComposition.Bind("recommended", "absent"))
Test("global-config-scope: late backup refusal publishes nothing", _GlobalScopeComposition.Bind("clear", "backup"))
Test("global-config-scope: external last-file edit preserves the foreign version", _GlobalScopeComposition.Bind("clear", "external"))
Test("global-config-scope: immediate native refusal restores the complete cohort", _GlobalScopeComposition.Bind("clear", "immediate"))

Test("global-config-scope: refused compensation fences every store until exact recovery", _GlobalScopeComposition.Bind("clear", "debt"))

_GlobalScopeRejectsCollision() {
	Rejected := false
	try GlobalScopeFiles("C:\config.toml", [{ paths: ["c:/CONFIG.toml"] }])
	catch as Err
		Rejected := Err is ValueError
	Assert(Rejected, "an additional owner cannot overwrite the primary config image")
	Rejected := false
	try GlobalScopeFiles("C:\config.toml", [{ paths: ["C:\personal.toml"] }, { paths: ["c:/PERSONAL.toml"] }])
	catch as Err
		Rejected := Err is ValueError
	Assert(Rejected, "two additional owners cannot silently win by order")
}
Test("global-config-scope: normalized owner collisions refuse before effects", _GlobalScopeRejectsCollision)
