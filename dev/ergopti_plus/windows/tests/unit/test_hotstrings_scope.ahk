; tests/unit/test_hotstrings_scope.ahk

; Real files, admitted publication and recovery; only replacement launch is a port.
_HotstringsScopeFixture(PersonalCount := 1) {
	Fixture := _ScopeOwnerFixture()
	Fixture.overrides := Fixture.directory . "\hotstrings_config.toml"
	Fixture.overrideSource := '[autocorrection]`ndelay = 3.5`nunknown = "keep"`n[autocorrection.words]`npriority = 5`n[__global__]`nword_delimiters = "!"`nunknown = "keep"`n[foreign]`ndelay = 9`n'
	Fixture.personalSource := '[_meta]`ndelay = 2.5`ndescription = "Keep corpus"`nunknown = "keep"`n[_meta.sections.words]`nshow_tooltip = false`nunknown = "keep"`n[[words]]`n"abc" = "replacement"`n'
	Fixture.catalogue := [{ Key: "autocorrection", Path: "", IsPersonal: false, IsExtension: false }]
	Fixture.personal := []
	Loop PersonalCount {
		Path := Fixture.directory . "\personal" . A_Index . ".toml"
		Assert(FSWriteDurable(Path, Fixture.personalSource))
		Fixture.personal.Push(Path)
		Fixture.catalogue.Push({ Key: "personal:personal" . A_Index, Path: Path, IsPersonal: true, IsExtension: false })
	}
	Assert(FSWriteDurable(Fixture.overrides, Fixture.overrideSource))
	Fixture.source := '[category_enabled]`nhotstrings = true`n[hotstrings]`npreview_ai_enabled = true`n[hotstrings.personal.words]`nenabled = true`ntime_activation_seconds = 4`n[private]`ncredential = "keep"`n'
	Assert(FSWriteDurable(Fixture.path, Fixture.source))
	Fixture.options["override_path"] := Fixture.overrides
	Fixture.options["personal_path"] := Fixture.personal[1]
	Fixture.options["catalogue"] := (*) => Fixture.catalogue
	Fixture.options["sections"] := (*) => [{ Name: "words" }]
	Fixture.options["language_paths"] := (*) => []
	return Fixture
}

_HotstringsScopeRoundTrip() {
	Fixture := _HotstringsScopeFixture()
	; Injected owners may retain a spelling different from file discovery.
	Fixture.options["personal_path"] := StrReplace(Fixture.personal[1], "\", "/")
	Fixture.catalogue[2].Path := Fixture.options["personal_path"]
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		for Mode in ["clear", "recommended"] {
			Fixture.options["stamp"] := Mode
			Commands := _HS_ScopeCommands(Fixture.options)
			Receipt := (Commands[Mode == "clear" ? "scope_clear" : "scope_restore"])()
			AssertEqual(Receipt["status"], "pending")
			Config := TOML_ParseFreshFile(Fixture.path)
			Assert(!Config["hotstrings.personal.words"].Has("enabled"))
			AssertEqual(Config["hotstrings"]["preview_ai_enabled"], true)
			AssertEqual(Config["private"]["credential"], "keep")
			Overrides := TOML_ParseFreshFile(Fixture.overrides)
			Assert(!Overrides["autocorrection"].Has("delay"))
			Assert(!Overrides["autocorrection.words"].Has("priority"))
			Assert(!Overrides["__global__"].Has("word_delimiters"))
			AssertEqual(Overrides["autocorrection"]["unknown"], "keep")
			AssertEqual(Overrides["foreign"]["delay"], 9)
			Personal := TOML_ParseFreshFile(Fixture.personal[1])
			Assert(!Personal["_meta"].Has("delay"))
			Assert(!Personal["_meta.sections.words"].Has("show_tooltip"))
			AssertEqual(Personal["_meta"]["description"], "Keep corpus")
			AssertContains(FSReadUtf8Exact(Fixture.personal[1]), '"abc" = "replacement"')
			for Path in [Fixture.path, Fixture.overrides, Fixture.personal[1]]
				Assert(!_ConfigWriteLeaseTryAcquire(Path, "concurrent-editor"))
			Refusal.Call("native refusal")
			AssertEqual(Receipt["status"], "refused")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
			AssertEqual(FSReadUtf8Exact(Fixture.overrides), Fixture.overrideSource)
			AssertEqual(FSReadUtf8Exact(Fixture.personal[1]), Fixture.personalSource)
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-scope: all stores publish together and restore exact bytes after native refusal", _HotstringsScopeRoundTrip)

_HotstringsScopeRefusals() {
	for Scenario in ["backup", "inventory", "external"] {
		Fixture := _HotstringsScopeFixture()
		Backups := 0, Launches := 0
		Backup(SelectedScenario, State, Path, Content) {
			Backups += 1
			if SelectedScenario == "backup" && Backups == 2
				return false
			if SelectedScenario == "external" && Backups == 1
				Assert(FSWriteDurable(State.personal[1], State.personalSource . "# foreign edit`n"))
			return FSWriteCreateDurable(Path, Content)
		}
		Launch(*) {
			Launches += 1
			return false
		}
		Fixture.options["backup"] := Backup.Bind(Scenario, Fixture)
		Fixture.options["reload"] := Launch
		if Scenario == "inventory" {
			; The catalogue changes once admission holds the terminal barrier.
			Settle(*) {
				Fixture.catalogue.Push({ Key: "personal:new", Path: Fixture.directory . "\new.toml", IsPersonal: true, IsExtension: false })
				return true
			}
			Fixture.options["settle"] := Settle
		}
		try {
			Apply := "HotstringsScopeApply"
			Receipt := %Apply%("clear", Fixture.options)
			AssertEqual(Receipt["status"], "refused")
			AssertEqual(Launches, 0)
			if Scenario == "inventory"
				AssertEqual(Backups, 0, "unsupported or changed cohorts refuse before backup effects")
			else
				AssertEqual(Backups, Scenario == "backup" ? 2 : 3, "the intended effect boundary was reached")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
			AssertEqual(FSReadUtf8Exact(Fixture.overrides), Fixture.overrideSource)
			for Path in Fixture.personal
				AssertEqual(FSReadUtf8Exact(Path), Fixture.personalSource . (Scenario == "external" ? "# foreign edit`n" : ""), Scenario)
		} finally _ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-scope: inventory backup and foreign edits refuse without partial publication", _HotstringsScopeRefusals)

_HotstringsScopeRecoveryDebt() {
	Fixture := _HotstringsScopeFixture()
	Bundle := 0, RefuseMove := false
	Port := ConfigTransitionProductionPort()
	Move(Source, Destination) {
		return RefuseMove ? false : FSAtomicMoveReplace(Source, Destination)
	}
	Port["move_replace"] := Move
	Launch(_Success, Borrowed, _Refused) {
		Bundle := Borrowed
		RefuseMove := true
		return false
	}
	Fixture.options["port"] := Port
	Fixture.options["reload"] := Launch
	try {
		Receipt := HotstringsScopeApply("clear", Fixture.options)
		AssertEqual(Receipt["status"], "recovery_required")
		for Path in [Fixture.path, Fixture.overrides, Fixture.personal[1]] {
			Assert(_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object)
			Assert(!_ConfigWriteLeaseTryAcquire(Path, "must remain blocked"))
		}
		RefuseMove := false
		Recovered := ConfigTransitionRollbackOwned(Fixture.options["locator"], Bundle, Port)
		Assert(ConfigTransitionResultIs(Recovered, "recovered_old"))
		AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
		AssertEqual(FSReadUtf8Exact(Fixture.overrides), Fixture.overrideSource)
		AssertEqual(FSReadUtf8Exact(Fixture.personal[1]), Fixture.personalSource)
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-scope: failed compensation fences every store until exact recovery", _HotstringsScopeRecoveryDebt)

_HotstringsScopeProductionInventory() {
	_L4R_WithPack(Check)
	Check(Root, SourcePath) {
		global ScriptInformation, _ConfigDir, _ExtensionsDir, _HCW_CATEGORY_LIST
		SavedInformation := ScriptInformation, SavedConfig := _ConfigDir, SavedExtensions := _ExtensionsDir
		SavedList := _HCW_CATEGORY_LIST
		Fixture := _ScopeOwnerFixture()
		DirCreate(Fixture.directory . "\personal")
		Assert(FSWriteDurable(Fixture.directory . "\personal\neighbor.toml", '[[neighbor_only]]`n"other" = "entry"`n'))
		Path := Fixture.directory . "\personal\main.toml"
		Assert(FSWriteDurable(Path, '[[known]]`n"trigger" = "output"`n'))
		try {
			ScriptInformation := SavedInformation.Clone()
			ScriptInformation["PersonalHotstringsDir"] := Fixture.directory . "\personal\"
			; Equivalent spellings must match the canonical discovery identity.
			ScriptInformation["PersonalTomlPath"] := Fixture.directory . "\personal\.\main.toml"
			_ConfigDir := Fixture.directory, _ExtensionsDir := Root
			_HCW_CATEGORY_LIST := [{ Key: "untouched-ui" }]
			Owner := HotstringsScopeFiles(Map("override_path", Fixture.directory . "\overrides.toml"))
			; Populate the ordinary preview cache before the actual source changes.
			Entry := { Path: Path, IsPersonal: true, IsExtension: false }
			_HCW_GetSections(Entry)
			Assert(FSWriteDurable(Path, '[[known]]`n"trigger" = "output"`n[[new_section]]`n"new" = "entry"`n'))
			Found := Map()
			for Item in Owner.Inventory()
				Found[Item] := true
			Assert(Found.Has("hotstrings.groups.ext:sample:words"))
			Assert(Found.Has("hotstrings.modules.ext:sample:words.wanted"))
			Assert(Found.Has("hotstrings.personal.new_section.enabled"), "the scope reads fresh source sections")
			Assert(Found.Has("hotstrings.personal.new_section.time_activation_seconds"))
			Assert(!Found.Has("hotstrings.personal.neighbor_only.enabled"), "another personal file is not the primary source")
			AssertEqual(_HCW_CATEGORY_LIST[1].Key, "untouched-ui")
			Validated := ManifestScopeInventory("hotstrings", Map("catalogue", Owner.Inventory.Bind(Owner)))
			Assert(Validated.Length > 0)
		} finally {
			ScriptInformation := SavedInformation, _ConfigDir := SavedConfig, _ExtensionsDir := SavedExtensions
			_HCW_CATEGORY_LIST := SavedList
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
Test("hotstrings-scope: production discovery inventories fresh personal and canonical extension identities", _HotstringsScopeProductionInventory)

_HotstringsScopeLargeCatalogue() {
	Fixture := _HotstringsScopeFixture(32)
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := HotstringsScopeApply("clear", Fixture.options)
		AssertEqual("pending", Receipt["status"], "all 34 changed stores fit one transaction")
		Journal := ConfigTransitionInspect(Fixture.options["locator"], ConfigTransitionProductionPort())
		Assert(ConfigTransitionResultIs(Journal, "ready"))
		AssertEqual(34, Journal["record"]["targets"].Length)
		AssertEqual(34, Receipt["backups"].Length)
		for Path in Fixture.personal {
			Assert(!InStr(FSReadUtf8Exact(Path), "delay = 2.5"))
			AssertContains(FSReadUtf8Exact(Path), '"abc" = "replacement"')
			Assert(!_ConfigWriteLeaseTryAcquire(Path, "concurrent-editor"))
		}
		Refusal.Call("replacement refused")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
		for Path in Fixture.personal
			AssertEqual(Fixture.personalSource, FSReadUtf8Exact(Path))
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-capacity: 32 personal files publish and roll back as one journal", _HotstringsScopeLargeCatalogue)
