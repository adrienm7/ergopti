; tests/unit/infra/config/scope/test_tap_hold_semantic_consumers.ahk

; The source is authored independently of the serializer under test. The same
; file reaches the real runtime loader, onboarding report and detached owners.
_THS_Source(Shape, Recommended := false) {
	Tap := Recommended ? "enter" : "escape", Seconds := Recommended ? "0.35" : "0.375"
	Fields := 'tap_action = "' . Tap . '"`nhold_modifier = "ctrl"`ntime_activation_seconds = ' . Seconds . '`n'
	switch Shape {
		case "dotted": Source := "tap_hold.keys.caps_lock." . StrReplace(RTrim(Fields, "`n"), "`n", "`ntap_hold.keys.caps_lock.") . "`n"
		case "quoted": Source := '["tap_hold"."keys"."caps_lock"]`n' . Fields
		case "inline": Source := '[tap_hold]`nkeys = { caps_lock = { tap_action = "' . Tap
			. '", hold_modifier = "ctrl", time_activation_seconds = ' . Seconds . ', future_note = "keep" } }`n'
		default: throw ValueError("Unknown tap-hold source shape")
	}
	return Source . '["tap_hold.keys.caps_lock"]`ntap_action = "literal-dot-owner" # foreign namespace`n'
		. '[Tap_hold.keys.caps_lock]`ntap_action = "case-owner" # foreign case`n'
		. '[[future.items]]`nname = "first"`n[[future.items]]`nname = "second"`n'
		. '[private]`ntext = "001" # exact foreign data`n'
}

_THS_AssertForeign(Source) {
	AssertContains(Source, '["tap_hold.keys.caps_lock"]`ntap_action = "literal-dot-owner" # foreign namespace')
	AssertContains(Source, '[Tap_hold.keys.caps_lock]`ntap_action = "case-owner" # foreign case')
	AssertContains(Source, '[[future.items]]`nname = "first"`n[[future.items]]`nname = "second"')
	AssertContains(Source, 'text = "001" # exact foreign data')
}

_THS_Fixture(Source) {
	Fixture := _ScopeOwnerFixture('[category_enabled]`ntap_holds = true`nshortcuts = true`n')
	Fixture.tap := TapHoldConfigPathBeside(Fixture.path)
	Fixture.paths := [Fixture.path, Fixture.tap, Fixture.tap . ".restart"]
	AssertTrue(FSWriteDurable(Fixture.tap, Source))
	return Fixture
}

_THS_Cleanup(Fixture) {
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache] {
		for Path in Fixture.paths {
			if Store.Has(Path)
				Store.Delete(Path)
		}
	}
	_ScopeOwnerCleanup(Fixture)
}

_THS_ReportAndImport(Shape, Recommended) {
	global _SharedDir, _OnboardingCatalogue
	SavedCatalogue := _OnboardingCatalogue
	Source := _THS_Source(Shape, Recommended), Fixture := _THS_Fixture(Source)
	Defaults := _SharedDir . "\tap_hold\defaults.toml"
	try {
		Loaded := LoadTapHoldToml(Fixture.tap, Defaults)
		AssertEqual(Recommended ? "enter" : "escape", TapHoldTapAction(Loaded, "caps_lock"))
		AssertEqual("ctrl", TapHoldHoldModifier(Loaded, "caps_lock"))
		AssertEqual(Recommended ? 0.35 : 0.375, TapHoldDuration(Loaded, "caps_lock"))
		AssertTrue(TapHoldIsActive(Loaded, "caps_lock"), "the independent source is genuinely admitted at runtime")
		Report := TapHoldKeyReport(Fixture.tap, Defaults)
		AssertTrue(Report is Map)
		AssertEqual(1, Report.Count, "foreign namespaces and future arrays cannot invent configured keys")
		AssertEqual(Recommended ? "recommended" : "customised", Report["caps_lock"])
		Values := OnboardingReadCurrentValues(OnboardingCatalogue(), Fixture.path)
		AssertTrue(Values is Map)
		AssertContains(OnboardingValuesJson(Values), Recommended ? '"tap_holds.keys.caps_lock":true'
			: '"tap_holds.keys.caps_lock":"customised"', "the actual wizard shows the active key's choice")
		if Recommended {
			Same := TapHoldImportImage(Fixture.tap, Defaults, ["caps_lock"])
			AssertTrue(Same["preserve_source"], "reimporting the same recommendation is an exact no-op")
			AssertEqual(Source, Same["content"])
		} else {
			Failure := ""
			try TapHoldImportImage(Fixture.tap, Defaults, ["caps_lock"])
			catch as Err
				Failure := Err.Message
			AssertContains(Failure, "holds the user's own setting", "the actual custom-key guard refuses before rendering")
		}
		Image := TapHoldImportImage(Fixture.tap, Defaults, ["left_alt"])
		AssertEqual(Source, Image["source_content"])
		_THS_AssertForeign(Image["content"])
		AssertFalse(TOML_ParseDocument(Image["content"]).Has("_meta"), "tap-hold imports do not stamp config.toml metadata")
		Backup := TapHoldImportBackup(Fixture.tap, Image)
		AssertTrue(FSUtf8ExactMatches(Backup, Source), "the real import backup retains the complete original image")
		AssertTrue(FSUtf8ExactMatches(Fixture.tap, Source), "report, refusal and detached rendering never publish")
		AssertTrue(FSWriteDurable(Fixture.tap . ".restart", Image["content"]))
		Reloaded := LoadTapHoldToml(Fixture.tap . ".restart", Defaults)
		AssertEqual(Recommended ? "enter" : "escape", TapHoldTapAction(Reloaded, "caps_lock"), "an unchecked key is kept")
		Preset := LoadTapHoldToml(Defaults)
		for Field, Value in Preset["keys"]["left_alt"]
			AssertEqual(Value, Reloaded["keys"]["left_alt"][Field], "the checked key imports its real preset")
	} finally {
		_OnboardingCatalogue := SavedCatalogue
		_THS_Cleanup(Fixture)
	}
}

_THS_Scope(Shape, Mode) {
	global _SharedDir, TapHold
	Source := _THS_Source(Shape), Fixture := _THS_Fixture(Source)
	Saved := IsSet(TapHold) ? TapHold : unset
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused
		return true
	}
	try {
		Defaults := _SharedDir . "\tap_hold\defaults.toml"
		TapHold := LoadTapHoldToml(Fixture.tap, Defaults), Before := TapHold
		AssertEqual("escape", TapHoldTapAction(TapHold, "caps_lock"))
		Fixture.options["tap_hold_path"] := Fixture.tap
		Fixture.options["tap_hold_defaults"] := Defaults
		Fixture.options["reload"] := Launch
		Commands := _TH_ScopeCommands(Fixture.options)
		Receipt := (Commands[Mode == "clear" ? "scope_clear" : "scope_restore"])()
		AssertEqual("pending", Receipt["status"], "the real submenu command reaches its two-file handoff")
		AssertEqual(ObjPtr(Before), ObjPtr(TapHold), "pending publication preserves the running remapping map")
		After := FSReadUtf8Exact(Fixture.tap)
		_THS_AssertForeign(After)
		if Shape == "inline"
			AssertContains(After, 'future_note = "keep"', "scope ownership never removes a future key field")
		AssertTrue(FSWriteDurable(Fixture.tap . ".restart", After))
		Reloaded := LoadTapHoldToml(Fixture.tap . ".restart", Defaults)
		if Mode == "clear" {
			AssertEqual(0, Reloaded["keys"].Count, "clear cannot acknowledge while an admitted alias still remaps keys")
			AssertFalse(TapHoldIsActive(Reloaded, "caps_lock"))
		} else {
			Preset := LoadTapHoldToml(Defaults)
			AssertEqual(Preset["keys"].Count, Reloaded["keys"].Count)
			for KeyId, Entry in Preset["keys"] {
				for Field, Value in Entry
					AssertEqual(Value, Reloaded["keys"][KeyId][Field], KeyId . "." . Field)
			}
		}
		Refusal.Call("native close refused")
		AssertEqual("refused", Receipt["status"])
		AssertTrue(FSUtf8ExactMatches(Fixture.tap, Source), "late refusal restores the exact authored tap-hold source")
		AssertTrue(FSUtf8ExactMatches(Fixture.path, Fixture.source), "the master switch source also rolls back exactly")
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		TapHold := IsSet(Saved) ? Saved : unset
		_THS_Cleanup(Fixture)
	}
}

_THS_InheritanceIntent() {
	global _SharedDir
	Fixture := _THS_Fixture(""), Defaults := _SharedDir . "\tap_hold\defaults.toml"
	try {
		for Index, Literal in ["true", "false", "1", "0", '"true"', '"1"'] {
			Path := Fixture.directory . "\inherit-" . Index . ".toml"
			Fixture.paths.Push(Path)
			AssertTrue(FSWriteDurable(Path, "tap_hold.inherit_defaults = " . Literal . "`n"))
			Loaded := LoadTapHoldToml(Path, Defaults)
			Report := TapHoldKeyReport(Path, Defaults)
			AssertTrue(Report is Map)
			AssertEqual(Loaded["keys"].Count, Report.Count, "only a genuine true literal inherits recommendations: " . Literal)
			AssertEqual(Literal == "true", Report.Count > 0)
		}
	} finally _THS_Cleanup(Fixture)
}

_THS_InvalidNamespaceRefuses() {
	global _SharedDir
	Fixture := _THS_Fixture(""), Defaults := _SharedDir . "\tap_hold\defaults.toml"
	try {
		for Index, Source in ['tap_hold = []`n', '[tap_hold]`nkeys = []`n'] {
			Path := Fixture.directory . "\invalid-" . Index . ".toml"
			Fixture.paths.Push(Path)
			AssertTrue(FSWriteDurable(Path, Source))
			Loaded := LoadTapHoldToml(Path, Defaults)
			AssertEqual(0, Loaded["keys"].Count, "an array cannot lend a scalar key namespace")
			AssertTrue(TapHoldKeyReport(Path, Defaults) is String, "a blocked source is never a neutral import page")
			AssertThrows(() => TapHoldImportImage(Path, Defaults, ["caps_lock"]))
			for Mode in ["clear", "recommended"]
				AssertThrows(ObjBindMethod(TapHoldScopeOwner(Path, Defaults, Mode), "Build"))
			AssertTrue(FSUtf8ExactMatches(Path, Source), "all refused consumers preserve the malformed container")
		}
	} finally _THS_Cleanup(Fixture)
}

for _THS_Shape in ["dotted", "quoted", "inline"] {
	for _THS_Recommended in [false, true]
		Test("tap-hold semantic consumers: " . _THS_Shape . " reports " . (_THS_Recommended ? "recommended" : "customised")
			. " and protects imports (tap-hold-semantic-consumers)", _THS_ReportAndImport.Bind(_THS_Shape, _THS_Recommended))
	for _THS_Mode in ["clear", "recommended"]
		Test("tap-hold semantic consumers: " . _THS_Shape . " " . _THS_Mode . " reaches restart and rollback (tap-hold-semantic-consumers)",
			_THS_Scope.Bind(_THS_Shape, _THS_Mode))
}
Test("tap-hold semantic consumers: inheritance keeps the runtime Boolean contract (tap-hold-semantic-consumers)", _THS_InheritanceIntent)

Test("tap-hold semantic consumers: blocked namespaces refuse without publication (tap-hold-semantic-consumers)", _THS_InvalidNamespaceRefuses)
