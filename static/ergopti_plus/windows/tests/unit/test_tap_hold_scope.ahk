; tests/unit/test_tap_hold_scope.ahk

_TapHoldScopeCase(Mode, RefuseBackup := false, ExternalEdit := false) {
	global TapHold, GestureActionParameters, _SharedDir, _MenuDispatchCallbacks
	OldTapHold := IsSet(TapHold) ? TapHold : unset
	OldParameters := GestureActionParameters
	Fixture := _ScopeOwnerFixture()
	ConfigSource := '[category_enabled]`ntap_holds = true`nshortcuts = true`n[action_parameters]`ntap_hold__space__open_url = "https://hold.test"`ngesture__tap_4__open_url = "https://gesture.test"`n'
	TapPath := Fixture.path . ".tap.toml"
	TapSource := '[tap_hold]`ninherit_defaults = true`n[tap_hold.keys.space]`ntap_action = "open_url"`nhold_modifier = "shift"`ntime_activation_seconds = 0.9`n[private]`ncredential = "keep"`n'
	Assert(FSWriteDurable(Fixture.path, ConfigSource))
	Assert(FSWriteDurable(TapPath, TapSource))
	Fixture.options["tap_hold_path"] := TapPath
	Fixture.options["tap_hold_defaults"] := _SharedDir . "\tap_hold\defaults.toml"
	Bundle := 0, Refusal := 0, Launches := 0, Backups := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused, Launches += 1
		return true
	}
	Backup(Path, Content) {
		Backups += 1
		if RefuseBackup && Backups == 2
			return false
		Result := FSWriteCreateDurable(Path, Content)
		if ExternalEdit && Backups == 2
			Assert(FSWriteDurable(TapPath, TapSource . "# external edit`n"))
		return Result
	}
	Fixture.options["reload"] := Launch, Fixture.options["backup"] := Backup
	Rendered := Menu()
	try {
		TapHold := LoadTapHoldToml(TapPath)
		RuntimeBefore := TapHold
		GestureActionParameters := TOML_ParseFreshFile(Fixture.path)["action_parameters"]
		Factory := "_TH_ScopeCommands"
		Commands := %Factory%(Fixture.options)
		Id := Mode == "clear" ? "disable_all" : "reset_defaults"
		Rendered.Delete()
		Rendered := MenuRenderer_Build("tap_holds_menu", "TapHolds", "", "",
			Map("tap_hold_keys", (*) => []), Commands, Map("tapholds_enabled", (*) => false))
		ItemId := 0
		Loop TrayMenuItemCount(Rendered) {
			CandidateId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", A_Index - 1, "uint")
			if _MenuDispatchCallbacks.Has(CandidateId) && ObjPtr(_MenuDispatchCallbacks[CandidateId]) == ObjPtr(Commands[Id])
				ItemId := CandidateId
		}
		Assert(ItemId != 0, "the actual manifest menu must register the terminal scope command")
		Receipt := (_MenuDispatchCallbacks[ItemId])()
		if RefuseBackup || ExternalEdit {
			AssertEqual(2, Backups)
			AssertEqual(0, Launches)
			AssertEqual("refused", Receipt["status"])
		} else {
			AssertEqual("pending", Receipt["status"])
			AssertEqual(1, Launches)
			AssertEqual(2, Backups)
			Parsed := TOML_ParseFreshFile(Fixture.path)
			AssertEqual(true, Parsed["category_enabled"]["shortcuts"])
			Assert(!Parsed["action_parameters"].Has("tap_hold__space__open_url"))
			AssertEqual("https://gesture.test", Parsed["action_parameters"]["gesture__tap_4__open_url"])
			; The current process deliberately retains its old read cache until
			; terminal acknowledgement. A fresh path models the next boot's cache.
			RestartPath := TapPath . ".restart"
			Assert(FSWriteDurable(RestartPath, FSReadUtf8Exact(TapPath)))
			Reloaded := LoadTapHoldToml(RestartPath, Fixture.options["tap_hold_defaults"])
			if Mode == "clear" {
				Assert(!Parsed["category_enabled"].Has("tap_holds"))
				AssertEqual(0, Reloaded["keys"].Count)
			} else {
				AssertEqual(ManifestRecommendedFor("category_enabled.tap_holds"), Parsed["category_enabled"]["tap_holds"])
				Recommended := LoadTapHoldToml(Fixture.options["tap_hold_defaults"])
				Assert(Recommended["keys"].Count > 0)
				AssertEqual(Recommended["keys"].Count, Reloaded["keys"].Count)
				for KeyId, Entry in Recommended["keys"] {
					for Field, Value in Entry
						AssertEqual(Value, Reloaded["keys"][KeyId][Field], KeyId . "." . Field)
				}
			}
			AssertEqual("keep", TOML_ParseFreshFile(TapPath)["private"]["credential"])
			AssertEqual(ObjPtr(RuntimeBefore), ObjPtr(TapHold), "pending publication cannot mutate the live remapping map")
			Assert(!_ConfigWriteLeaseTryAcquire(TapPath, "intruder"))
			Refusal.Call("native close refused")
			AssertEqual("refused", Receipt["status"])
		}
		AssertEqual(ConfigSource, FSReadUtf8Exact(Fixture.path))
		AssertEqual(TapSource . (ExternalEdit ? "# external edit`n" : ""), FSReadUtf8Exact(TapPath))
	} finally {
		Rendered.Delete()
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		TapHold := IsSet(OldTapHold) ? OldTapHold : unset
		GestureActionParameters := OldParameters
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("tap-hold-scope: recommended preset and master compensate native refusal", _TapHoldScopeCase.Bind("recommended"))
Test("tap-hold-scope: clear preset and master compensate native refusal", _TapHoldScopeCase.Bind("clear"))
Test("tap-hold-scope: refused second backup leaves both original stores", _TapHoldScopeCase.Bind("recommended", true))
Test("tap-hold-scope: external preset edit refuses both-file publication", _TapHoldScopeCase.Bind("recommended", false, true))

_TapHoldDetachedImage() {
	global _SharedDir
	Fixture := _ScopeOwnerFixture()
	Path := Fixture.directory . "\tap_hold.toml"
	Source := '[tap_hold.keys.space]`ntap_action = "open_url"`n[private]`ncredential = "keep"`n'
	Assert(FSWriteDurable(Path, Source))
	try {
		Owner := TapHoldScopeOwner(Path, _SharedDir . "\tap_hold\defaults.toml", "clear")
		Images := Owner.Build()
		AssertEqual(1, Images.Length)
		AssertEqual(Path, Images[1].path)
		AssertEqual(Source, Images[1].image["source_content"])
		Assert(!InStr(Images[1].image["content"], "open_url"))
		AssertEqual(Source, FSReadUtf8Exact(Path), "building a candidate has no publication side effect")
		AssertEqual(2, FSListDirectoryStrict(Fixture.directory).Length, "no backup or stage is created by the file owner")
		Fixture.options["preset_owner"] := Owner
		AssertThrows(() => ConfigScopeApply("tap_holds", "recommended", Map(), Fixture.options),
			"a preset for the opposite action must refuse before admission")
		AssertThrows(() => ConfigScopeApply("global", "clear", Map(), Fixture.options))
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("tap-hold-scope: detached file owner has no effects and rejects mismatched scope mode", _TapHoldDetachedImage)
