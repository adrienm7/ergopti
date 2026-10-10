; tests/unit/test_layout_extension_menu.ahk

; Reads an actual native callback rather than reconstructing provider behavior.
_L4M_MenuAction(TargetMenu, Label) {
	global _MenuDispatchCallbacks
	loop TrayMenuItemCount(TargetMenu) {
		if _CTC_LabelAt(TargetMenu, A_Index - 1) != Label
			continue
		Id := DllCall("GetMenuItemID", "ptr", TargetMenu.Handle, "int", A_Index - 1, "uint")
		Assert(_MenuDispatchCallbacks.Has(Id), "the visible extension command must have a native handler")
		return _MenuDispatchCallbacks[Id]
	}
	throw Error("The extension menu has no requested native command.")
}

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
		Fixture := _ScopeOwnerFixture(), Bundle := 0, Refusal := 0, FileMenu := 0
		Fixture.source .= '[hotstrings.groups]`n"ext:sample:words" = true`n'
		Fixture.source := _CMJFixtureCurrentSource(Fixture.source)
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
			FileRow := Rows[1]["items"][1]
			FileMenu := FileRow["submenu"]
			Assert(FileRow["checked"], "the category title retains desired state under master OFF")
			AssertEqual(t("menu.hotstrings.scope_enable_all"), _CTC_LabelAt(FileMenu, 0))
			AssertEqual(t("menu.hotstrings.scope_disable_all"), _CTC_LabelAt(FileMenu, 1))
			AssertEqual(0, _CTC_CountLabel(FileMenu, t("menu.hotstrings.category_enable")))
			SectionAction := _L4M_MenuAction(FileMenu, "Wanted (2)")
			Receipt := SectionAction.Call()
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
			Receipt := _L4M_MenuAction(FileMenu, t("menu.hotstrings.scope_disable_all")).Call()
			AssertEqual(Receipt["status"], "pending")
			Assert(!TOML_ParseFreshFile(Fixture.path)["hotstrings.groups"].Has("ext:sample:words"))
			Assert(ReadFeatureStateV2("hotstrings.groups.ext:sample:words")["enabled"])
			Refusal.Call("native close refused")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
			Fixture.options["stamp"] := "removed-content"
			DirDelete(Root . "\sample", true)
			Receipt := SectionAction.Call()
			AssertEqual(Receipt["status"], "refused", "a stale menu cannot activate removed content")
			Assert(!FileExist(Receipt["backup"]))
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
		} finally {
			if FileMenu is Menu
				_CTC_ReleaseMenu(FileMenu)
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

; The new file-wide owner writes every discovered child through the same sparse
; schema and reload journal as single-section edits. Native refusal compensates
; the complete batch, never just its category gate.
_L4M_CategoryScope(Enabled, Immediate) {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		Fixture := _ScopeOwnerFixture(), Refusal := 0, Bundle := 0, Launches := 0
		OriginalPack := FSReadUtf8Exact(Path)
		Fixture.source := '[category_enabled]`nhotstrings = false`nrolls = true`n[hotstrings.groups]`n"ext:sample:words" = true`n"ext:other:keep" = true`n[hotstrings.modules."ext:sample:words"]`nwanted = false`nhidden = true`n[private]`ncredential = "extension-scope-fixture"`n'
		Fixture.source := _CMJFixtureCurrentSource(Fixture.source)
		Assert(FSWriteDurable(Fixture.path, Fixture.source))
		Launch(_Success, Borrowed, Refused) {
			Launches += 1
			if Immediate
				return false
			Bundle := Borrowed
			Refusal := Refused
			return true
		}
		Fixture.options["reload"] := Launch
		Fixture.options["roots"] := (*) => [Root]
		try {
			Receipt := HotstringExtensions_SetCategoryEnabled("ext:sample:words", Enabled, Fixture.options)
			AssertEqual(1, Launches, "one category plan hands off one native replacement")
			if Immediate {
				AssertEqual("refused", Receipt["status"])
			} else {
				AssertEqual("pending", Receipt["status"])
				Target := ManifestBuildFeaturesMap()
				HotstringExtensions_Prepare(Target, [Root])
				ApplyConfigToml(Target, Fixture.path)
				AssertEqual(Enabled, Target["hotstrings"]["groups"]["ext:sample:words"])
				for Section in ["wanted", "hidden"]
					AssertEqual(Enabled, Target["hotstrings"]["modules"]["ext:sample:words"][Section],
						"every discovered section reaches the real canonical reader")
				Source := TOML_ParseFreshFile(Fixture.path)
				AssertEqual(false, Source["category_enabled"]["hotstrings"], "the engine master stays off")
				AssertEqual(true, Source["category_enabled"]["rolls"])
				AssertEqual(true, Source["hotstrings.groups"]["ext:other:keep"])
				AssertEqual("extension-scope-fixture", Source["private"]["credential"])
				Refusal.Call("native extension category reload refused")
				AssertEqual("refused", Receipt["status"])
			}
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path), "refusal restores the complete source")
			AssertEqual(OriginalPack, FSReadUtf8Exact(Path), "selection never rewrites extension content")
		} finally {
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
for _L4M_Enabled in [true, false] {
	for _L4M_Immediate in [true, false]
		Test("layout-extension-category: target " . _L4M_Enabled . " immediate refusal " . _L4M_Immediate,
			_L4M_CategoryScope.Bind(_L4M_Enabled, _L4M_Immediate))
}

_L4M_UnknownCategoryScope() {
	_L4R_WithPack(Check)
	Check(Root, Path) {
		Fixture := _ScopeOwnerFixture(), Launches := 0
		Fixture.options["reload"] := (*) => Launches += 1
		Fixture.options["roots"] := (*) => [Root]
		try {
			Receipt := HotstringExtensions_SetCategoryEnabled("ext:sample:missing", true, Fixture.options)
			AssertEqual("refused", Receipt["status"])
			AssertEqual(0, Launches)
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
			Assert(!FSStrictExists(Receipt["backup"]), "an unknown category owns no write or backup")
		} finally _ScopeOwnerCleanup(Fixture)
	}
}
Test("layout-extension-category: an unknown namespace never launches or writes", _L4M_UnknownCategoryScope)
