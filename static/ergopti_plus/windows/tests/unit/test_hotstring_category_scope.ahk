; tests/unit/test_hotstring_category_scope.ahk

; ==============================================================================
; MODULE: Hotstring Category Selection Parity (Windows)
; DESCRIPTION:
; Replays the independent shared corpus through the native policy port. A
; refused scope cannot emit a partial batch, and every valid category/section
; choice matches both Lua drivers, including the excluded layout remapping.
; ==============================================================================

_HSCS_CheckVector(Vector) {
	Inventory := Vector["inventory"]
	Targets := Vector["targets"].Clone()
	Before := Map()
	for Id, Sections in Inventory
		Before[Id] := Sections.Clone()
	Choices := HotstringsCategoryScopePlan(Inventory, Vector["targets"], Vector["enabled"], &Reason)
	if Vector.Has("refusal") {
		AssertFalse(Choices, "no partial batch may escape a refusal")
		AssertEqual(Vector["refusal"], Reason)
	} else {
		Assert(Choices is Array, "a valid scope must produce its complete choice batch")
		AssertEqual("", Reason)
		Expected := Vector["expected"]
		AssertEqual(Expected.Length, Choices.Length)
		for Index, Want in Expected {
			Got := Choices[Index]
			AssertEqual(Want.Count, Got.Count, "every emitted field must belong to the corpus")
			for Key, Value in Want {
				Assert(Got.Has(Key), "the choice must contain " . Key)
				AssertEqual(Value, Got[Key])
			}
		}
	}
	AssertEqual(Targets.Length, Vector["targets"].Length)
	for Index, Id in Targets
		AssertEqual(Id, Vector["targets"][Index], "the caller's scope must remain unchanged")
	AssertEqual(Before.Count, Inventory.Count)
	for Id, Sections in Before {
		AssertEqual(Sections.Length, Inventory[Id].Length)
		for Index, Name in Sections
			AssertEqual(Name, Inventory[Id][Index], "the discovered catalogue must remain unchanged")
	}
}

; Registered individually so native CI names the exact cross-driver vector.
for _HSCS_Vector in JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\bulk_scope_vectors.json", "UTF-8"))["vectors"]
	Test("hotstring-category-scope: " . _HSCS_Vector["name"], _HSCS_CheckVector.Bind(_HSCS_Vector))

; The existing journal owns runtime admission and conditional rollback. Only
; replacement launch is injected; the typed source, backup and journal are real.
_HSCS_WithSource(Body) {
	global _LegacyTopCategoryMap
	Saved := IsSet(_LegacyTopCategoryMap) ? _LegacyTopCategoryMap : unset
	Fixture := _ScopeOwnerFixture()
	Fixture.source := '[category_enabled]`nhotstrings = false`nrolls = false`nautocorrection = true`n[hotstrings.rolls.hc]`nenabled = false`ntime_activation_seconds = 0.75`n[hotstrings.rolls.sx]`nenabled = true`n[hotstrings.magic_key.replace]`nenabled = true`n[private]`ncredential = "retain-fixture-value"`n'
	try {
		Assert(FSWriteDurable(Fixture.path, Fixture.source))
		_LegacyTopCategoryMap := Map("Rolls", "hotstrings.rolls")
		Body.Call(Fixture)
	} finally {
		_LegacyTopCategoryMap := IsSet(Saved) ? Saved : unset
		_ScopeOwnerCleanup(Fixture)
	}
}

_HSCS_PendingAndNativeRefusal(Enabled) {
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Refusal := 0, Bundle := 0
		Launch(_Success, Borrowed, Refused) {
			Bundle := Borrowed
			Refusal := Refused
			return true
		}
		Fixture.options["reload"] := Launch
		try {
			Receipt := HotstringsCategoryScopeApply(["Rolls"], Enabled, Fixture.options)
			AssertEqual("pending", Receipt["status"], "accepted launch is never completed publication")
			AssertEqual(Enabled ? "enable_all" : "disable_all", Receipt["mode"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
			AssertEqual(Enabled, TOML_Read(Fixture.path, "category_enabled", "rolls",
				ManifestDefaultFor("category_enabled.rolls")))
			Target := ManifestBuildFeaturesMap()
			ApplyConfigToml(Target, Fixture.path)
			for Entry in ManifestFeaturesForSection("hotstrings.rolls") {
				Loc := FeatureLocateV2(Target, Entry["path"])
				AssertEqual(Enabled, Loc["v2_node"][Loc["key"]], "each selected section reaches the real reader")
			}
			Parsed := TOML_ParseFreshFile(Fixture.path)
			AssertEqual(false, Parsed["category_enabled"]["hotstrings"], "the engine master stays disabled")
			AssertEqual(true, Parsed["category_enabled"]["autocorrection"], "another category keeps its choice")
			AssertEqual(0.75, Parsed["hotstrings.rolls.hc"]["time_activation_seconds"])
			AssertEqual(true, Parsed["hotstrings.magic_key.replace"]["enabled"], "layout remapping is retained")
			AssertEqual("retain-fixture-value", Parsed["private"]["credential"])
			Assert(!(_ConfigWriteLeaseTryAcquire(Fixture.path, "concurrent-category")))
			Refusal.Call("native category reload refused")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path), "late refusal restores exact original bytes")
			Assert(!(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object))
		} finally {
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
		}
	}
}

_HSCS_ImmediateRefusal(Enabled) {
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Fixture.options["reload"] := (*) => false
		Receipt := HotstringsCategoryScopeApply(["Rolls"], Enabled, Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
	}
}

_HSCS_UnknownScope() {
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Launches := 0
		Fixture.options["reload"] := (*) => Launches += 1
		Receipt := HotstringsCategoryScopeApply(["Rolls", "missing"], true, Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual(0, Launches)
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertFalse(FSStrictExists(Receipt["backup"]), "an invalid scope creates no backup or partial write")
	}
}

for _HSCS_Enabled in [true, false] {
	Test("hotstring-category-owner: pending " . _HSCS_Enabled . " rolls back native refusal",
		_HSCS_PendingAndNativeRefusal.Bind(_HSCS_Enabled))
	Test("hotstring-category-owner: immediate " . _HSCS_Enabled . " refusal preserves exact source",
		_HSCS_ImmediateRefusal.Bind(_HSCS_Enabled))
}
Test("hotstring-category-owner: an unknown sibling never launches or writes", _HSCS_UnknownScope)

_HSCS_InventoryOwnsOnlyHotstrings() {
	Requested := []
	Read(Prefix) {
		Requested.Push(Prefix)
		return ManifestFeaturesForSection(Prefix)
	}
	Inventory := _HotstringsCategoryScopeInventory(Map("Layout", "layout", "Shortcuts", "shortcuts",
		"Gestures", "gestures", "Rolls", "hotstrings.rolls"), Read)
	AssertEqual(1, Inventory.Count, "other tray scopes are not hotstring categories")
	Assert(Inventory.Has("Rolls"))
	Assert(Inventory["Rolls"].Length > 1, "the admitted category must expose its real sections")
	AssertEqual(1, Requested.Length, "foreign namespaces are not even queried")
	AssertEqual("hotstrings.rolls", Requested[1])
	AssertFalse(HotstringsCategoryScopePlan(Inventory, ["Rolls", "Layout"], true, &Reason))
	AssertEqual("unknown-category", Reason)
}
Test("hotstring-category-owner: other tray namespaces never enter the selected inventory",
	_HSCS_InventoryOwnsOnlyHotstrings)

; The real Win32 command dispatch reaches the durable scope owner, including
; pending handoff and restoration after native refusal.
_HSCS_MenuOwner(Enabled) {
	global _MenuDispatchCallbacks
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Receipt := 0, Refusal := 0
		Launch(_Success, _Borrowed, Refused) {
			Refusal := Refused
			return true
		}
		Apply(Targets, Requested) {
			Receipt := HotstringsCategoryScopeApply(Targets, Requested, Fixture.options)
		}
		Fixture.options["reload"] := Launch
		Built := _HS_CategoryMenu("Rolls", "", [], Apply)
		try {
			AssertEqual(2, TrayMenuItemCount(Built), "empty providers leave exactly the two declared commands")
			Position := Enabled ? 0 : 1
			AssertEqual(t(Enabled ? "menu.hotstrings.scope_enable_all" : "menu.hotstrings.scope_disable_all"),
				_CTC_LabelAt(Built, Position))
			Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
			Assert(_MenuDispatchCallbacks.Has(Id))
			_MenuDispatchCallbacks[Id].Call()
			AssertEqual("pending", Receipt["status"])
			AssertEqual(Enabled, TOML_Read(Fixture.path, "category_enabled", "rolls", false))
			AssertEqual(false, TOML_Read(Fixture.path, "category_enabled", "hotstrings", true))
			Refusal.Call("native category menu reload refused")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		} finally _CTC_ReleaseMenu(Built)
	}
}
for _HSCS_Enabled in [true, false]
	Test("hotstring-category-menu-owner: native command " . _HSCS_Enabled . " commits through the journal",
		_HSCS_MenuOwner.Bind(_HSCS_Enabled))
