; tests/unit/test_layout_extension_menu.ahk

; The rendered callbacks use the real writer and conditional reload rollback.
_L4M_MenuDesired() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		global Features, CategoryEnabled, _HotstringExtensionPacks, _HS_ExtensionsCacheLoaded, _MenuDispatchCallbacks
		global _FmtCountCache
		SavedCountCache := IsSet(_FmtCountCache) ? _FmtCountCache : Map()
		_FmtCountCache := Map()
		SavedFeatures := Features, SavedCategories := CategoryEnabled, SavedPacks := _HotstringExtensionPacks
		State := MasterGateState(), SavedState := State.Clone()
		Fixture := _ScopeOwnerFixture(), Bundle := 0, Refusal := 0
		Fixture.source .= '[hotstrings.groups]`n"ext:sample:words" = true`n'
		Assert(FSWriteDurable(Fixture.path, Fixture.source))
		Launch(_Success, Borrowed, Refused) {
			Bundle := Borrowed
			Refusal := Refused
			return true
		}
		Fixture.options["reload"] := Launch
		Fixture.options["roots"] := (*) => [Root]
		try {
			Features := ManifestBuildFeaturesMap()
			_HotstringExtensionPacks := HotstringExtensions_Prepare(Features, [Root])
			Features["hotstrings"]["groups"]["ext:sample:words"] := true
			State["initialized"] := false
			CategoryEnabled := Map("Hotstrings", false)
			MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
			_HS_ExtensionsCacheLoaded := false
			RowsFn := "_HS_ExtensionRows"
			Rows := %RowsFn%(Fixture.options)
			Leaves := Rows[1]["items"][1]["items"]
			GroupRow := Leaves[3], SectionRow := 0
			for Row in Leaves {
				if InStr(Row.Get("label", ""), "Wanted (") == 1
					SectionRow := Row
			}
			Assert(SectionRow is Map)
			Assert(GroupRow["checked"], "group checkmark must retain desired state under master OFF")
			Assert(!GroupRow.Get("disabled", false))
			Assert(!SectionRow["checked"])
			Assert(!SectionRow.Get("disabled", false), "child editing remains available under master OFF")
			Rendered := Menu()
			try {
				MenuRenderer_AppendRows(Rendered, "hotstrings_menu", "hotstring_extensions", [SectionRow])
				AssertEqual(TrayMenuItemCount(Rendered), 1)
				ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
				Assert(_MenuDispatchCallbacks.Has(ItemId))
				Receipt := (_MenuDispatchCallbacks[ItemId])()
			} finally Rendered.Delete()
			AssertEqual(Receipt["status"], "pending")
			Published := TOML_ParseFreshFile(Fixture.path)
			AssertEqual(Published['hotstrings.modules."ext:sample:words"']["wanted"], true)
			AssertEqual(Published["private"]["credential"], "keep")
			Assert(!ReadFeatureStateV2("hotstrings.modules.ext:sample:words.wanted")["enabled"],
				"pending reload does not publish desired state early")
			Refusal.Call("native close refused")
			AssertEqual(Receipt["status"], "refused")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
			Fixture.options["stamp"] := "group-off"
			Receipt := (GroupRow["action"])()
			AssertEqual(Receipt["status"], "pending")
			Assert(!TOML_ParseFreshFile(Fixture.path)["hotstrings.groups"].Has("ext:sample:words"))
			Assert(ReadFeatureStateV2("hotstrings.groups.ext:sample:words")["enabled"])
			Refusal.Call("native close refused")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
			Fixture.options["stamp"] := "removed-content"
			DirDelete(Root . "\sample", true)
			Receipt := (SectionRow["action"])()
			AssertEqual(Receipt["status"], "refused", "a stale menu cannot activate removed content")
			Assert(!FileExist(Receipt["backup"]))
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
		} finally {
			_FmtCountCache := SavedCountCache
			Features := SavedFeatures, CategoryEnabled := SavedCategories, _HotstringExtensionPacks := SavedPacks
			State.Clear()
			for Key, Value in SavedState
				State[Key] := Value
			_HS_ExtensionsCacheLoaded := false
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
Test("layout-extension-menu: real section callback preserves desired state and compensates native refusal", _L4M_MenuDesired)

_L4M_RejectUnknown() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		Fixture := _ScopeOwnerFixture(), Calls := 0
		Launch(*) {
			Calls += 1
			return false
		}
		Fixture.options["roots"] := (*) => [Root]
		Fixture.options["reload"] := Launch
		try {
			Setter := "HotstringExtensions_SetEnabled"
			Receipt := %Setter%("hotstrings.modules.ext:sample:words.unknown", true, Fixture.options)
			AssertEqual(Receipt["status"], "refused")
			AssertEqual(Calls, 0)
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
			Assert(!FileExist(Receipt["backup"]))
			AssertThrows(() => %Setter%("hotstrings.groups.ext:sample:words", "true", Fixture.options))
		} finally _ScopeOwnerCleanup(Fixture)
	}
}
Test("layout-extension-menu: fresh owner inventory refuses unknown sections and nonboolean values", _L4M_RejectUnknown)

_L4M_EffectiveCount() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		Target := ManifestBuildFeaturesMap()
		Packs := HotstringExtensions_Prepare(Target, [Root])
		Target["hotstrings"]["groups"]["ext:sample:words"] := true
		Target["hotstrings"]["modules"]["ext:sample:words"]["wanted"] := true
		CountFn := "HotstringExtensions_Count"
		AssertEqual(%CountFn%(Target, Packs, true), 2)
		AssertEqual(%CountFn%(Target, Packs, false), 0)
		Target["hotstrings"]["groups"]["ext:sample:words"] := false
		AssertEqual(%CountFn%(Target, Packs, true), 0)
	}
}
Test("layout-extension-menu: counters include only effective discovered sections", _L4M_EffectiveCount)
