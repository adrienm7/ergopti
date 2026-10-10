; tests/unit/test_tap_hold_scope.ahk

_TapHoldScopeCase(Mode, RefuseBackup := false, ExternalEdit := false) {
	global TapHold, GestureActionParameters, _SharedDir, _MenuDispatchCallbacks
	OldTapHold := IsSet(TapHold) ? TapHold : unset
	OldParameters := GestureActionParameters
	; Author the intended current-source subject before the genuine native boot.
	OriginalConfigBody := '[category_enabled]`ntap_holds = true`nshortcuts = true`n[action_parameters]`ntap_hold__space__open_url = "https://hold.test"`ngesture__tap_4__open_url = "https://gesture.test"`n'
	Fixture := _ScopeOwnerFixture(OriginalConfigBody)
	ConfigSource := Fixture.source
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
		AssertEqual(OriginalConfigBody, SubStr(ConfigSource, InStr(ConfigSource, "`n") + 1),
			"current positive boot retains every independently authored original config byte")
		TapHold := LoadTapHoldToml(TapPath)
		RuntimeBefore := TapHold
		GestureActionParameters := TOML_ParseFreshFile(Fixture.path)["action_parameters"]
		Factory := "_TH_ScopeCommands"
		Commands := %Factory%(Fixture.options)
		Id := Mode == "clear" ? "scope_clear" : "scope_restore"
		Rendered.Delete()
		Rendered := MenuRenderer_Build("tap_holds_menu", "TapHolds", "", "",
			Map("tap_hold_keys_left", (*) => [], "tap_hold_keys_right", (*) => []),
			Commands, Map("tapholds_enabled", (*) => false))
		ItemId := 0, Position := -1
		Loop TrayMenuItemCount(Rendered) {
			CandidateId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", A_Index - 1, "uint")
			if _MenuDispatchCallbacks.Has(CandidateId) && ObjPtr(_MenuDispatchCallbacks[CandidateId]) == ObjPtr(Commands[Id])
				ItemId := CandidateId, Position := A_Index - 1
		}
		Assert(ItemId != 0, "the actual manifest menu must register the terminal scope command")
		; The first group (menu-first-group): the switch, the restore, the clear,
		; then a separator.
		AssertEqual(Mode == "clear" ? 2 : 1, Position, "the scope rows follow the switch")
		Assert(TrayMenuIsSeparatorAt(Rendered, 3), "a separator closes the first group")
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
				; The clear once deleted the switch with the keys, so the next key
				; the user set did nothing until the switch was found again.
				AssertEqual(true, Parsed["category_enabled"]["tap_holds"],
					"the clear owns the keys, not the Tap-Holds switch (tap-hold-clear-keeps-switch)")
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
Test("tap-hold-scope: clear preset keeps the switch and compensates native refusal (tap-hold-clear-keeps-switch)", _TapHoldScopeCase.Bind("clear"))

; The manifest plan itself: a clear of the Tap-Holds, alone or composed in the
; global one, names no row for the switch, and a restore still switches it on.
_TapHoldClearPlanKeepsSwitch() {
	for Scope in ["tap_holds", "global"] {
		for Row in ManifestScopeOperations(Scope, "clear")
			Assert(!(Row.Section == "category_enabled" && Row.Key == "tap_holds"), Scope . " clear rewrites the switch")
		Restored := false
		for Row in ManifestScopeOperations(Scope, "recommended") {
			if Row.Section == "category_enabled" && Row.Key == "tap_holds"
				Restored := Row.HasOwnProp("Value") && Row.Value == true
		}
		Assert(Restored, Scope . " restore still switches the Tap-Holds on")
	}
}
Test("tap-hold-scope: no clear plans a row for the Tap-Holds switch (tap-hold-clear-keeps-switch)", _TapHoldClearPlanKeepsSwitch)
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

; A fresh install has no layers.toml, which binds no key: the restored left_alt
; entered an empty navigation layer. A restore given the configuration folder
; now owns its layers.toml, created from the recommended layer only when absent.
_TapHoldScopeLayerImport() {
	global _SharedDir
	Fixture := _ScopeOwnerFixture()
	Path := Fixture.directory . "\tap_hold.toml"
	LayersPath := Fixture.directory . "\layers.toml"
	Defaults := _SharedDir . "\tap_hold\defaults.toml"
	try {
		AssertEqual(1, TapHoldScopeOwner(Path, Defaults, "clear", Fixture.directory).paths.Length,
			"clear never owns the layer file")
		AssertEqual(1, TapHoldScopeOwner(Path, Defaults, "recommended").paths.Length,
			"without a folder no layer file is owned")
		Owner := TapHoldScopeOwner(Path, Defaults, "recommended", Fixture.directory)
		AssertEqual(2, Owner.paths.Length)
		AssertEqual(LayersPath, Owner.paths[2])
		Images := Owner.Build()
		AssertEqual(2, Images.Length, "one candidate per owned path")
		AssertEqual(LayersPath, Images[2].path)
		AssertEqual(0, Images[2].image["source_present"])
		AssertEqual(FSReadUtf8Exact(_SharedDir . "\keymap\layers.recommended.toml"), Images[2].image["content"],
			"an absent layers.toml becomes the recommended layer's exact bytes")
		Assert(!FileExist(LayersPath), "building a candidate publishes nothing")
		Own := "# the user's own layer`n"
		Assert(FSWriteDurable(LayersPath, Own))
		Kept := TapHoldScopeOwner(Path, Defaults, "recommended", Fixture.directory).Build()
		AssertEqual(Own, Kept[2].image["source_content"])
		AssertEqual(Own, Kept[2].image["content"], "an existing layers.toml is unchanged, so no transition writes it")
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("tap-hold-scope: a restore owns the recommended layer only where layers.toml is absent (nav-layer-fresh-install-default)",
	_TapHoldScopeLayerImport)

; The restore publishes the layer in the tap-hold cohort and a refused reload
; takes it back with the other files.
_TapHoldScopeRestoreCreatesLayer() {
	global TapHold, GestureActionParameters, _SharedDir
	OldTapHold := IsSet(TapHold) ? TapHold : unset
	OldParameters := GestureActionParameters
	Fixture := _ScopeOwnerFixture()
	TapPath := Fixture.directory . "\tap_hold.toml"
	LayersPath := Fixture.directory . "\layers.toml"
	Fixture.options["tap_hold_path"] := TapPath
	Fixture.options["tap_hold_defaults"] := _SharedDir . "\tap_hold\defaults.toml"
	Fixture.options["layers_config_dir"] := Fixture.directory
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Assert(FSWriteDurable(TapPath, '[tap_hold]`ninherit_defaults = true`n'))
		TapHold := LoadTapHoldToml(TapPath)
		GestureActionParameters := Map()
		Receipt := TapHoldScopeApply("recommended", Fixture.options)
		AssertEqual("pending", Receipt["status"])
		AssertEqual(FSReadUtf8Exact(_SharedDir . "\keymap\layers.recommended.toml"), FSReadUtf8Exact(LayersPath),
			"the restore creates the recommended layer beside the preset")
		Assert(!_ConfigWriteLeaseTryAcquire(LayersPath, "intruder"), "the layer file is held with the cohort")
		Refusal.Call("native close refused")
		AssertEqual("refused", Receipt["status"])
		Assert(!FileExist(LayersPath), "a refused restore takes the layer it created back")
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		TapHold := IsSet(OldTapHold) ? OldTapHold : unset
		GestureActionParameters := OldParameters
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("tap-hold-scope: the restore publishes the layer with the preset and a refusal takes it back (nav-layer-fresh-install-default)",
	_TapHoldScopeRestoreCreatesLayer)

; Picking the navigation layer as a key's hold wrote hold_layer and nothing
; else. In a folder with no layers.toml the key then entered a layer that binds
; no key, which only lights CapsLock while held: every letter came out in
; capitals and the hold read as Shift. The picker's write brings the
; recommended layer along, as the restore does.
_TapHoldPickerBringsLayer() {
	global _SharedDir
	Fixture := _ScopeOwnerFixture()
	LayersPath := Fixture.directory . "\layers.toml"
	Preset := TapHoldRecommendedLayer(_SharedDir)
	LayerOpt := Map("kind", "layer", "id", Preset["layer_id"])
	Writes := []
	Accept(KeyId, HoldOpt) {
		Writes.Push(KeyId . ":" . HoldOpt["kind"] . ":" . HoldOpt["id"] . ":" . (FileExist(LayersPath) ? "layer" : "none"))
		return 1
	}
	Refuse(KeyId, HoldOpt) => false
	try {
		AssertEqual(1, TapHoldSetHold("space", Map("kind", "modifier", "id", "shift"), Fixture.directory, Accept))
		Assert(!FileExist(LayersPath), "a modifier hold brings no layer file")
		AssertEqual(1, TapHoldSetHold("space", Map("kind", "layer", "id", "not_the_recommended_layer"), Fixture.directory, Accept))
		Assert(!FileExist(LayersPath), "a layer the recommended file does not bind brings nothing")
		AssertEqual(1, TapHoldSetHold("space", LayerOpt, "", Accept))
		Assert(!FileExist(LayersPath), "without a configuration folder no layer file is written")

		Assert(!TapHoldSetHold("space", LayerOpt, Fixture.directory, Refuse), "a refused key write is reported")
		Assert(!FileExist(LayersPath), "a refused key write takes the layer it created back")

		AssertEqual(1, TapHoldSetHold("space", LayerOpt, Fixture.directory, Accept))
		AssertEqual(Preset["text"], FSReadUtf8Exact(LayersPath),
			"picking the layer creates layers.toml with the recommended layer's exact bytes")
		AssertEqual("space:layer:" . Preset["layer_id"] . ":layer", Writes[Writes.Length],
			"the layer file is there before the key that enters it is written")
		Assert(_ConfigWriteLeaseTryAcquire(LayersPath, "probe") is Object, "the import releases the layer file")

		Own := "# the user's own layer`n"
		Assert(FSDeleteStrict(LayersPath))
		Assert(FSWriteDurable(LayersPath, Own))
		AssertEqual(1, TapHoldSetHold("space", LayerOpt, Fixture.directory, Accept))
		AssertEqual(Own, FSReadUtf8Exact(LayersPath), "an existing layers.toml is the user's and is never replaced")
		Assert(!TapHoldSetHold("space", LayerOpt, Fixture.directory, Refuse))
		AssertEqual(Own, FSReadUtf8Exact(LayersPath), "a refused key write removes only a file the picker created")
	} finally {
		Current := _ConfigWriteLeaseCurrent(LayersPath)
		if Current is Object
			_ConfigWriteLeaseRelease(Current)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("tap-hold-scope: picking the layer as a hold brings the recommended layer along (hold-picker-brings-the-layer-2026-10-01)",
	_TapHoldPickerBringsLayer)

; The tray's hold picker is the caller: it hands the configuration folder to
; the owner above, never to the bare key writer.
_TapHoldPickerCallsLayerOwner() {
	Body := _DriverFuncBody("_TH_ApplyHold")
	Assert(RegExMatch(Body, "TapHoldSetHold\(KeyId,\s*HoldOpt,\s*_ConfigDir\)"),
		"the hold picker must write through TapHoldSetHold with the configuration folder")
	Assert(!RegExMatch(Body, "[^A-Za-z_]WriteTapHoldHold\("),
		"the hold picker must not call the bare key writer, which brings no layer")
	Assert(InStr(_DriverSourceNoComments(), "return _TH_ApplyHold(this.KeyId, this.HoldOpt)"),
		"the picker row's callback must reach _TH_ApplyHold")
}
Test("tap-hold-scope: the hold picker writes through the layer owner (hold-picker-brings-the-layer-2026-10-01)",
	_TapHoldPickerCallsLayerOwner)
