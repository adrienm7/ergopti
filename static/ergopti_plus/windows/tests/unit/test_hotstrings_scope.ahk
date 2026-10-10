; tests/unit/test_hotstrings_scope.ahk

; Real files, admitted publication and recovery; only replacement launch is a port.
_HotstringsScopeFixture(PersonalCount := 1, InitialSuffix := "") {
	Assert(InitialSuffix is String, "the scope cohort's extra current-schema preferences precede genuine native boot")
	Source := '[category_enabled]`nhotstrings = true`n[hotstrings]`npreview_ai_enabled = true`n[hotstrings.personal.words]`nenabled = true`ntime_activation_seconds = 4`n[private]`ncredential = "keep"`n'
	Fixture := _ScopeOwnerFixture(Source . InitialSuffix)
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

; The Hotstrings menu declares both rows and registers them from the same
; provider, so a click reaches the scope owner the round trip above proves.
_HotstringsScopeManifestRows() {
	global _MenuDispatchCallbacks
	Body := _DriverFuncBody("_MI_StageHotstrings")
	Assert(Body != "", "_MI_StageHotstrings must be present in the driver source")
	Assert(InStr(Body, "_HS_ScopeCommands()") > 0,
		"the Hotstrings menu must register its scope rows from the tested provider")
	Fixture := _HotstringsScopeFixture()
	Refusal := 0, Bundle := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Commands := _HS_ScopeCommands(Fixture.options)
		for Mode in ["clear", "recommended"] {
			Fixture.options["stamp"] := Mode
			Id := Mode == "clear" ? "scope_clear" : "scope_restore"
			Rendered := Menu()
			try {
				AssertEqual(1, MenuRenderer_AppendCommand(Rendered, "hotstrings_menu", Id, Commands),
					"hotstrings_menu must declare " . Id)
				ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
				Assert(_MenuDispatchCallbacks.Has(ItemId))
				Receipt := (_MenuDispatchCallbacks[ItemId])()
				AssertEqual(Receipt["status"], "pending")
				Assert(!TOML_ParseFreshFile(Fixture.overrides)["autocorrection"].Has("delay"))
				Refusal.Call("native refusal")
				AssertEqual(Receipt["status"], "refused")
				AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
				AssertEqual(FSReadUtf8Exact(Fixture.overrides), Fixture.overrideSource)
			} finally Rendered.Delete()
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-scope: the Hotstrings menu draws both scope rows and runs the owner", _HotstringsScopeManifestRows)

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
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Fixture := _HotstringsScopeFixture()
	Bundle := 0, Handle := -1
	Port := ConfigTransitionProductionPort()
	AssertTrue(ConfigTransitionProductionPort(Port), "this rollback subject retains the actual native port owner")
	Launch(_Success, Borrowed, _Refused) {
		Bundle := Borrowed
		AssertFalse(FSUtf8ExactMatches(Fixture.path, Fixture.source), "the actual native journal published before physical rollback denial")
		; Share read/write but deny deletion: the real native replacement must fail.
		Handle := DllCall("kernel32\CreateFileW", "Str", Fixture.path,
			"UInt", 0x80000000, "UInt", 3, "Ptr", 0, "UInt", 3,
			"UInt", 0x00000080, "Ptr", 0, "Ptr")
		AssertTrue(Handle != -1, "the real Windows non-delete-sharing handle must be acquired")
		AssertTrue(ConfigTransitionProductionPort(Port), "physical sharing denial does not mutate native callbacks")
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
		AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int"), "the real sharing denial must close before native recovery")
		Handle := -1
		AssertTrue(ConfigTransitionProductionPort(Port), "the same genuine native port admits exact recovery")
		Recovered := ConfigTransitionRollbackOwned(Fixture.options["locator"], Bundle, Port)
		Assert(ConfigTransitionResultIs(Recovered, "recovered_old"))
		AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
		AssertEqual(FSReadUtf8Exact(Fixture.overrides), Fixture.overrideSource)
		AssertEqual(FSReadUtf8Exact(Fixture.personal[1]), Fixture.personalSource)
	} finally {
		if Handle != -1 {
			AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int"), "fixture failure must close its genuine native handle")
			Handle := -1
		}
		try {
			if Bundle is Object {
				Resolution := ConfigTransitionRollbackOwned(Fixture.options["locator"], Bundle, Port)
				AssertTrue(ConfigTransitionResultIs(Resolution, "absent") || ConfigTransitionResultIs(Resolution, "recovered_old"),
					"fixture retirement resolves real native WAL debt before releasing its actual owner")
			}
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
		} finally {
			PreviousCritical := A_IsCritical
			Critical("On")
			try {
				if Bundle is Object && _ConfigTransitionRetainedBarrier == Bundle
					_ConfigTransitionRetainedBarrier := PriorRetained
			} finally Critical(PreviousCritical)
		}
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

; Measure the genuine captured source predicate separately from native WAL I/O.
; The original full transaction and its deadline remain unchanged below.
_HSC_CapturedRegistryGuardNativeTiming() {
	Fixture := _ScopeOwnerFixture()
	Hits := { count: 0 }, ObserverInstalled := false
	try {
		Registry := ConfigMigrateShippedRegistry()
		Guard := ConfigMigrateBoot(Fixture.path, "capture_noop")
		AssertTrue(HasMethod(Guard, "Call"), "genuine current boot issues the actual source guard")
		Accepted := 0
		Started := _TestClockMs()
		loop 32 {
			if Guard.Call(Fixture.source, 1)
				Accepted += 1
		}
		Elapsed := _TestClockMs() - Started
		_TestPrint("# group1-registry-native-phase: phase=captured_guard;calls=32;accepted=" . Accepted
			. ";duration_ms=" . Format("{:.3f}", Elapsed))
		AssertEqual(32, Accepted, "every invocation retains the actual full registry and current source admission")
		OriginalCount := Registry.Count
		Registry.DefineProp("Count", { Get: (*) => (Hits.count += 1, OriginalCount) })
		ObserverInstalled := true
		AssertFalse(Guard.Call(Fixture.source, 1), "the same genuine guard refuses the altered live registry")
		AssertEqual(0, Hits.count, "registry shape refusal executes no foreign Count observer")
		Registry.DeleteProp("Count")
		ObserverInstalled := false
		AssertTrue(Guard.Call(Fixture.source, 1), "exact native registry repair restores the same captured guard")
		AssertEqual(0, Hits.count)
		AssertTrue(FSUtf8ExactMatches(Fixture.path, Fixture.source), "guard measurement and refusal publish no file effects")
	} finally {
		try {
			if ObserverInstalled
				Registry.DeleteProp("Count")
		} finally _ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstrings-capacity: genuine captured registry guard reports native predicate timing", _HSC_CapturedRegistryGuardNativeTiming)

_HotstringsScopeLargeCatalogue() {
	PhaseStarted := _TestClockMs()
	Fixture := _HotstringsScopeFixture(32)
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		_HSC_TraceNativePhase("fixture", PhaseStarted)
		PhaseStarted := _TestClockMs()
		Receipt := HotstringsScopeApply("clear", Fixture.options)
		_HSC_TraceNativePhase("apply", PhaseStarted)
		AssertEqual("pending", Receipt["status"], "all 34 changed stores fit one transaction")
		_ScopeExactOwnerNativeProbe(Bundle, Fixture.path, Fixture.options["locator"], 34)
		PhaseStarted := _TestClockMs()
		Journal := ConfigTransitionInspect(Fixture.options["locator"], ConfigTransitionProductionPort())
		_HSC_TraceNativePhase("inspect", PhaseStarted)
		Assert(ConfigTransitionResultIs(Journal, "ready"))
		AssertEqual(34, Journal["record"]["targets"].Length)
		AssertEqual(34, Receipt["backups"].Length)
		PhaseStarted := _TestClockMs()
		for Path in Fixture.personal {
			Assert(!InStr(FSReadUtf8Exact(Path), "delay = 2.5"))
			AssertContains(FSReadUtf8Exact(Path), '"abc" = "replacement"')
			Assert(!_ConfigWriteLeaseTryAcquire(Path, "concurrent-editor"))
		}
		_HSC_TraceNativePhase("verify_pending", PhaseStarted)
		PhaseStarted := _TestClockMs()
		Refusal.Call("replacement refused")
		_HSC_TraceNativePhase("refusal", PhaseStarted)
		PhaseStarted := _TestClockMs()
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
		for Path in Fixture.personal
			AssertEqual(Fixture.personalSource, FSReadUtf8Exact(Path))
		_HSC_TraceNativePhase("verify_rollback", PhaseStarted)
	} finally {
		try {
			PhaseStarted := _TestClockMs()
		} finally {
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			_ScopeOwnerCleanup(Fixture)
		}
		_HSC_TraceNativePhase("cleanup", PhaseStarted)
	}
	AssertFalse(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path), "the original retired full transaction cannot supply its old selected token")
}
Test("hotstrings-capacity: 32 personal files publish and roll back as one journal", _HotstringsScopeLargeCatalogue)





; =================================================
; =================================================
; ======= 1/ Measured delay recommendations =======
; =================================================
; =================================================

_HotstringsScopeDelayVectorInherited(Vector, *) {
	return Vector["inherited"]
}

_HotstringsScopeDelayVectors() {
	global _SharedDir
	Fixture := JsonParse(FSReadUtf8Exact(_SharedDir .
		"\tests\corpus\hotstrings\scope_override_delay_vectors.json"))
	for Vector in Fixture["vectors"] {
		Rows := HotstringsScopeDelayRecommendations(Vector["mode"], Fixture["features"],
			[Map("id", Vector["id"], "sections", [Vector["section"]],
				"bundled", Vector["bundled"])], _HotstringsScopeDelayVectorInherited.Bind(Vector))
		AssertEqual(Vector.Has("expected") ? 1 : 0, Rows.Length, Vector["name"])
		if Vector.Has("expected") {
			AssertEqual(Vector["id"], Rows[1]["group"], Vector["name"])
			AssertEqual(Vector["section"], Rows[1]["section"], Vector["name"])
			AssertEqual(Vector["expected"], Rows[1]["seconds"], Vector["name"])
			AssertEqual(Vector["inherited"], Rows[1]["inherited"], Vector["name"])
		}
	}
}
Test("hotstrings-scope: independent delay vectors agree with both Lua drivers", _HotstringsScopeDelayVectors)

_HotstringsScopeMeasuredDelayRoundTrip(SelectedFamily) {
	OwnedSection := "autocorrection." . SelectedFamily
	global _HotstringsOverrides, _HSResolveCache, _HSResolveGen, HotstringGroupConfig
	Saved := { overrides: _HotstringsOverrides, cache: _HSResolveCache, generation: _HSResolveGen,
		groups: HotstringGroupConfig }
	Fixture := _HotstringsScopeFixture()
	Fixture.options["sections"] := (Entry) => [{ Name: Entry.IsPersonal ? "words" : SelectedFamily }]
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		; Other resolver fixtures deliberately seed empty metadata. This real-corpus
		; round trip owns a fresh cache so the actual TOML parser supplies inheritance.
		HotstringGroupConfig := Map()
		AssertEqual(1.0, _HotstringsScopeInheritedDelay("autocorrection", SelectedFamily),
			"the real corpus makes deletion inherit 1.0 seconds")
		AssertEqual(0.5, ManifestValueFor("hotstrings." . OwnedSection . ".time_activation_seconds", "recommended"),
			"the real shared manifest recommends 0.5 seconds")
		for Mode in ["recommended", "clear"] {
			Fixture.options["stamp"] := "measured-delay-" . Mode
			Receipt := HotstringsScopeApply(Mode, Fixture.options)
			AssertEqual("pending", Receipt["status"])
			Overrides := TOML_ParseFreshFile(Fixture.overrides)
			if Mode == "recommended"
				AssertEqual(0.5, Overrides[OwnedSection]["delay"],
					"the acknowledged candidate explicitly stores the recommendation")
			else
				Assert(!Overrides.Has(OwnedSection) || !Overrides[OwnedSection].Has("delay"),
					"clear removes the recommendation and returns to corpus inheritance")
			_HotstringsOverrides := _ParseOverrides(Fixture.overrides)
			HotstringsResolveBumpGen()
			AssertEqual(Mode == "recommended" ? 0.5 : 1.0,
				HotstringsResolve("autocorrection", SelectedFamily).Delay,
				"the actual native resolver delivers the requested delay")
			AssertEqual("keep", Overrides["autocorrection"]["unknown"])
			AssertEqual(9, Overrides["foreign"]["delay"])
			Personal := TOML_ParseFreshFile(Fixture.personal[1])
			AssertEqual("Keep corpus", Personal["_meta"]["description"])
			AssertContains(FSReadUtf8Exact(Fixture.personal[1]), '"abc" = "replacement"')
			for Path in [Fixture.path, Fixture.overrides, Fixture.personal[1]]
				Assert(!_ConfigWriteLeaseTryAcquire(Path, "concurrent-delay-editor"))
			Refusal.Call("native replacement refused measured delay")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
			AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
			AssertEqual(Fixture.personalSource, FSReadUtf8Exact(Fixture.personal[1]))
		}
	} finally {
		_HotstringsOverrides := Saved.overrides
		_HSResolveCache := Saved.cache
		_HSResolveGen := Saved.generation
		HotstringGroupConfig := Saved.groups
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
	Assert(HotstringGroupConfig == Saved.groups, "the original metadata cache identity is restored")
}
for _hsScopeFamily in ["names", "abbreviations", "technical_terms"]
	Test("hotstrings-scope: recommended delays differ from clear and restore exact stores on refusal — " . _hsScopeFamily,
		_HotstringsScopeMeasuredDelayRoundTrip.Bind(_hsScopeFamily))


; Native phase timing for the unchanged capacity subject. The real test clock
; and owned TAP reporter supply observations; no source, path or credentials
; are emitted, and no callback, admission or deadline is replaced.
_HSC_TraceNativePhase(Phase, Started) {
	Elapsed := _TestClockMs() - Started
	_TestPrint("# group1-capacity-native-phase: phase=" . Phase
		. ";duration_ms=" . Format("{:.3f}", Elapsed))
}
