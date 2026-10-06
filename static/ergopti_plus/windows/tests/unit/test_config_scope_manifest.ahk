; tests/unit/test_config_scope_manifest.ahk

; Runtime owners supply known identities, never arbitrary keys read from disk.
_ScopeManifestInventory() {
	Providers := Map("packs", (*) => ["hotstrings.modules.ext:ergopti:rolls.fast", "hotstrings.groups.ext:ergopti:rolls",
		"hotstrings.modules.ext:ergopti:rolls.fast", "shortcuts.personal.other", "hotstrings.personal.autocorrection.enabled"])
	Paths := ManifestScopeInventory("hotstrings", Providers)
	AssertEqual(Paths.Length, 2)
	AssertEqual(Paths[1], "hotstrings.groups.ext:ergopti:rolls")
	AssertEqual(Paths[2], "hotstrings.modules.ext:ergopti:rolls.fast")
	Rejected := false
	try ManifestScopeInventory("hotstrings", Map("unknown", (*) => ["private.credentials.token"]))
	catch
		Rejected := true
	Assert(Rejected, "unknown inventory must refuse before persistence")
	Rejected := false
	try ManifestScopeInventory("hotstrings", Map("missing", (*) => 0))
	catch
		Rejected := true
	Assert(Rejected, "an unavailable owner is not an empty inventory")
	Sparse := []
	Sparse.Length := 2
	Sparse[2] := "hotstrings.groups.real"
	Rejected := false
	try ManifestScopeInventory("hotstrings", Map("sparse", (*) => Sparse))
	catch
		Rejected := true
	Assert(Rejected, "an incomplete inventory must refuse")
}
Test("config-scope: explicit inventory validates and separates owners", _ScopeManifestInventory)

_ScopeManifestPlan() {
	for Mode in ["clear", "recommended"] {
		Plan := ManifestScopePlan("global", Mode)
		AssertEqual(Plan.presets.Length, 1)
		AssertEqual(Plan.presets[1].scope, "tap_holds")
		AssertEqual(Plan.presets[1].preset, "tap_hold")
		AssertEqual(Plan.presets[1].mode, Mode)
		AssertEqual(ManifestScopePlan("gestures", Mode).presets.Length, 0)
	}
	Paths := ["hotstrings.groups.ext:ergopti:rolls", "hotstrings.modules.ext:ergopti:rolls.fast",
		"shortcuts.personal.other"]
	Rows := ManifestScopePlan("hotstrings", "recommended", Paths).operations
	Found := 0
	for Row in Rows {
		Assert(Row.Section != "shortcuts.personal", "another scope must never leak into this plan")
		if Row.Section == 'hotstrings.modules."ext:ergopti:rolls"' {
			AssertEqual(Row.Key, "fast")
			AssertEqual(Row.Value, true)
			Found += 1
		}
		Assert(Row.Section . "." . Row.Key != "hotstrings.preview_ai_enabled", "recommendations preserve AI consent")
	}
	AssertEqual(Found, 1)
}
Test("config-scope: plans preserve preset ownership and consent boundaries", _ScopeManifestPlan)

_ScopeManifestQuotedRoundTrip() {
	Path := A_Temp . "\\ergopti-scope-quoted-" . A_TickCount . ".toml"
	try {
		Source := '[hotstrings.modules."ext:ergopti:rolls"]`nfast = true`nneighbor = true`n[private]`ncredential = "keep"`n'
		Assert(FSWriteDurable(Path, Source))
		Rows := [ManifestSparseOperation("hotstrings.modules.ext:ergopti:rolls.fast", false)]
		Assert(TOML_BatchWrite(Path, Rows))
		Parsed := ParseTomlFile(Path)
		Assert(!Parsed['hotstrings.modules."ext:ergopti:rolls"'].Has("fast"))
		AssertEqual(Parsed['hotstrings.modules."ext:ergopti:rolls"']["neighbor"], true)
		AssertEqual(Parsed["private"]["credential"], "keep")
		Row := ManifestSparseOperation("hotstrings.modules.ext:ergopti:rolls.fast", true)
		Assert(TOML_BatchWrite(Path, _ConfigPrepareTypedUpdates([Row])))
		AssertContains(FSReadUtf8Exact(Path), "fast = true", "dynamic Boolean intent must survive admitted serialization")
		Candidate := Map("hotstrings", Map("modules", Map("ext:ergopti:rolls", Map("fast", false))))
		ApplyConfigToml(Candidate, Path)
		AssertEqual(Candidate["hotstrings"]["modules"]["ext:ergopti:rolls"]["fast"], true,
			"real loader must address the same unquoted runtime identity")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("config-scope: quoted extension paths round trip through the real owner", _ScopeManifestQuotedRoundTrip)

; A lifecycle owner must keep exclusive authority after every borrowed outcome.
_ScopeBuiltBorrowedOwner() {
	Path := A_Temp . "\ergopti-scope-owner.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	Assert(Bundle is Object)
	Calls := 0
	Build() {
		Calls += 1
		return { updates: [{ Section: "gestures", Key: "enabled", Delete: 1 }] }
	}
	try {
		Assert(ConfigCommitBuilt(Path, "borrowed scope test", Build, (*) => 1, (*) => 0, Bundle))
		AssertEqual(Calls, 1)
		Assert(_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object, "success must not release borrowed authority")
		Assert(!_ConfigWriteLeaseTryAcquire(Path, "intruder"), "no sibling may enter before reload")
		Assert(!ConfigCommitBuilt(Path, "borrowed refusal", Build, (*) => 0, (*) => 0, Bundle))
		Assert(_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object, "writer refusal must not release borrowed authority")
		Assert(!ConfigCommitBuilt(Path . ".other", "wrong path", Build, (*) => 1, (*) => 0, Bundle))
		AssertEqual(Calls, 2, "wrong-path ownership is rejected before the builder")
	} finally _ConfigWriteTerminalRelease(Bundle)
	Assert(!ConfigCommitBuilt(Path, "stale scope", Build, (*) => 1, (*) => 0, Bundle))
	AssertEqual(Calls, 2, "stale ownership is rejected before the builder")
}
Test("config-scope: borrowed candidate admission retains exact lifecycle ownership", _ScopeBuiltBorrowedOwner)

; The filesystem and WAL are real; only replacement-process launch is injected.
_ScopeOwnerFixture() {
	Directory := A_Temp . "\ergopti-scope-" . A_TickCount . "-" . Random(10000, 99999)
	DirCreate(Directory)
	Source := '[layout]`nergopti_base = true`nergopti_altgr = true`n[llm]`nenabled = true`n[private]`ncredential = "keep"`n'
	Path := Directory . "\config.toml"
	Assert(FSWriteDurable(Path, Source))
	Options := Map("path", Path, "locator", Directory . "\paths.toml", "stamp", "scope-test",
		"settle", (*) => 1, "notify", (*) => 0)
	return { directory: Directory, path: Path, source: Source, options: Options }
}

_ScopeOwnerCleanup(Fixture) {
	Assert(InStr(Fixture.directory, A_Temp . "\ergopti-scope-") == 1)
	if DirExist(Fixture.directory)
		DirDelete(Fixture.directory, true)
}

_ScopeOwnerPendingThenRefused() {
	Fixture := _ScopeOwnerFixture()
	Cached := ParseTomlFile(Fixture.path)
	Refusal := 0, Bundle := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		AssertEqual(Receipt["status"], "pending", "accepted launch is never reported as completed reload")
		AssertEqual(FSReadUtf8Exact(Receipt["backup"]), Fixture.source)
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Assert(!Parsed["layout"].Has("ergopti_base"))
		AssertEqual(Parsed["private"]["credential"], "keep")
		AssertEqual(Parsed["llm"]["enabled"], true, "another scope's consent is preserved")
		Assert(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object)
		Refusal.Call("native close refused")
		AssertEqual(Receipt["status"], "refused")
		AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source, "late refusal restores exact prior bytes")
		Assert(ObjPtr(ParseTomlFile(Fixture.path)) == ObjPtr(Cached), "the pending image must not replace cached desired authority")
		Assert(!(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object))
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config-scope: pending reload retains the backup and rolls back late refusal", _ScopeOwnerPendingThenRefused)

_ScopeOwnerImmediateRefusal() {
	Fixture := _ScopeOwnerFixture()
	Fixture.options["reload"] := (*) => false
	try {
		Receipt := ConfigScopeApply("keyboard_layout", "recommended", Map(), Fixture.options)
		AssertEqual(Receipt["status"], "refused")
		AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
		AssertEqual(FSReadUtf8Exact(Receipt["backup"]), Fixture.source)
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("config-scope: refused native launch restores exact desired state", _ScopeOwnerImmediateRefusal)

_ScopeOwnerBackupAndExternalRefusals() {
	for Scenario in ["collision", "external"] {
		Fixture := _ScopeOwnerFixture()
		Launches := 0
		Launch(*) {
			Launches += 1
			return false
		}
		Fixture.options["reload"] := Launch
		Backup := ConfigUnusedKeysBackupPath(Fixture.path, "scope-test")
		Changed := Fixture.source . '`n[external]`nvalue = "new"`n'
		if Scenario == "collision"
			Assert(FSWriteDurable(Backup, "do not overwrite"))
		else {
			BackupAndEdit(Path, Content) {
				Assert(FSWriteCreateDurable(Path, Content))
				Assert(FSWriteDurable(Fixture.path, Changed))
				return true
			}
			Fixture.options["backup"] := BackupAndEdit
		}
		try {
			Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
			AssertEqual(Receipt["status"], "refused")
			AssertEqual(Launches, 0, "a failed precondition must never launch a successor")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Scenario == "collision" ? Fixture.source : Changed)
			AssertEqual(FSReadUtf8Exact(Backup), Scenario == "collision" ? "do not overwrite" : Fixture.source)
		} finally _ScopeOwnerCleanup(Fixture)
	}
}
Test("config-scope: backup collisions and external edits refuse before publication", _ScopeOwnerBackupAndExternalRefusals)

; One scope and mode per call, so the refused call reads parameters. A closure
; never sees a for-loop variable: built in the loops, it threw an UnsetError
; before ConfigScopeApply ran, which satisfied both AssertThrows and the
; zero-admission count below.
; @param Scope {String} A scope declaring a separate-file preset.
; @param Mode {String} "recommended" or "clear".
; @param Acquire {Func} The counting admission port.
_ScopeOwnerRejectsPresetCase(Scope, Mode, Acquire) {
	AssertThrows(() => ConfigScopeApply(Scope, Mode, Map(), Map("acquire", Acquire)),
		Scope . " " . Mode . " must refuse without its separate-file preset owner")
}

_ScopeOwnerRejectsPreset() {
	Calls := 0
	Acquire(*) {
		Calls += 1
		return false
	}
	for Scope in ["global", "tap_holds"] {
		for Mode in ["recommended", "clear"]
			_ScopeOwnerRejectsPresetCase(Scope, Mode, Acquire)
	}
	AssertEqual(Calls, 0, "preset scopes must refuse before any admission or disk effect")
}
Test("config-scope: separate-file presets refuse before any effects", _ScopeOwnerRejectsPreset)

; The text of a native menu row at a zero-based position.
_SGM_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Buffer_ := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Buffer_, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Buffer_, "UTF-16")
}

; The real Gestures submenu opens with its switch, « Restaurer les valeurs
; conseillées », « Tout effacer », then a separator (menu-first-group), and a
; click on either scope row runs the gesture scope owner over the fixture.
_ScopeGestureMenuOwnsParameters() {
	global GestureActionParameters, _MenuDispatchCallbacks
	SavedParameters := GestureActionParameters
	Fixture := _ScopeOwnerFixture()
	Source := '[gestures]`nenabled = true`ntap_4 = "open_url"`n[action_parameters]`ngesture__tap_4__open_url = "https://example.com/old"`nkeyboard__win_a__open_url = "https://example.com/keep"`nunknown_user_key = "keep"`n[llm]`nenabled = true`n'
	Assert(FSWriteDurable(Fixture.path, Source))
	GestureActionParameters := Map("gesture__tap_4__open_url", "https://example.com/old",
		"keyboard__win_a__open_url", "https://example.com/keep", "unknown_user_key", "keep")
	Refusal := 0, Bundle := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		for Mode in ["recommended", "clear"] {
			Fixture.options["stamp"] := Mode
			GMenu := BuildGesturesMenu(Fixture.options)
			try {
				AssertEqual(t("menu.gestures.enable"), _SGM_LabelAt(GMenu, 0), "the switch opens the menu")
				AssertEqual(t("common.restore_recommended"), _SGM_LabelAt(GMenu, 1), "the restore follows it")
				AssertEqual(t("common.clear_to_system"), _SGM_LabelAt(GMenu, 2), "the clear follows the restore")
				Assert(TrayMenuIsSeparatorAt(GMenu, 3), "a separator closes the first group")
				loop TrayMenuItemCount(GMenu) - 4 {
					Label := TrayMenuIsSeparatorAt(GMenu, A_Index + 3) ? "" : _SGM_LabelAt(GMenu, A_Index + 3)
					Assert(Label != t("common.restore_recommended") && Label != t("common.clear_to_system"),
						"no scope row follows the first group")
				}
				ItemId := DllCall("GetMenuItemID", "ptr", GMenu.Handle, "int", Mode == "clear" ? 2 : 1, "uint")
				Assert(_MenuDispatchCallbacks.Has(ItemId), "the scope row is a dispatched menu item")
				Receipt := (_MenuDispatchCallbacks[ItemId])()
			} finally {
				GMenu.Delete()
				MenuDispatcher_PruneMenu(GMenu)
			}
			AssertEqual(Receipt["status"], "pending")
			Parsed := TOML_ParseFreshFile(Fixture.path)
			Assert(!Parsed["action_parameters"].Has("gesture__tap_4__open_url"), "old binding parameters leave with their scope")
			AssertEqual(Parsed["action_parameters"]["keyboard__win_a__open_url"], "https://example.com/keep")
			AssertEqual(Parsed["action_parameters"]["unknown_user_key"], "keep")
			AssertEqual(Parsed["llm"]["enabled"], true)
			if Mode == "clear" {
				; The clear once deleted the switch with the assignments
				; (gestures-clear-keeps-switch).
				AssertEqual(true, Parsed["gestures"]["enabled"], "clear removes the assignments and keeps the switch")
				Assert(!Parsed["gestures"].Has("tap_4"), "clear removes the assignment")
			} else
				AssertEqual(Parsed["gestures"]["enabled"], ManifestRecommendedFor("gestures.enabled"))
			AssertEqual(GestureActionParameters["gesture__tap_4__open_url"], "https://example.com/old",
				"pending reload preserves current runtime authority")
			Refusal.Call("refused")
			AssertEqual(Receipt["status"], "refused")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Source)
		}
	} finally {
		GestureActionParameters := SavedParameters
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config-scope: the gesture menu's restore owns the master, its clear keeps it, and both own only its action parameters",
	_ScopeGestureMenuOwnsParameters)

_ScopeOwnerRetainsRollbackDebt() {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Fixture := _ScopeOwnerFixture()
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
		Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		AssertEqual(Receipt["status"], "recovery_required")
		Assert(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object)
		Assert(!_ConfigWriteLeaseTryAcquire(Fixture.path, "must remain blocked"))
		AssertEqual(FSReadUtf8Exact(Receipt["backup"]), Fixture.source)
		RefuseMove := false
		Recovered := ConfigTransitionRollbackOwned(Fixture.options["locator"], Bundle, Port)
		Assert(ConfigTransitionResultIs(Recovered, "recovered_old"))
		AssertEqual(FSReadUtf8Exact(Fixture.path), Fixture.source)
	} finally {
		try {
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
		} finally {
			; Recovered fixture debt retires its exact registry marker even when
			; its terminal release has already completed. Foreign markers survive.
			PreviousCritical := Critical("On")
			try {
				if (Bundle is Object) && _ConfigTransitionRetainedBarrier == Bundle
					_ConfigTransitionRetainedBarrier := PriorRetained
			} finally {
				Critical(PreviousCritical)
				_ScopeOwnerCleanup(Fixture)
			}
		}
	}
}
Test("config-scope: failed rollback retains the exact terminal barrier until recovery", _ScopeOwnerRetainsRollbackDebt)

; A transient hash failure must not become the optional no-precondition sentinel.
_ScopeExpectedOldHashRefusal(AdditionalFile := false) {
	Fixture := AdditionalFile ? _HotstringsScopeFixture() : _ScopeOwnerFixture()
	TargetPath := AdditionalFile ? Fixture.overrides : Fixture.path
	Original := AdditionalFile ? Fixture.overrideSource : Fixture.source
	Changed := Original . "# external edit after candidate read`n"
	Port := ConfigTransitionProductionPort()
	Rejected := false, Launches := 0, Bundle := 0
	Hash(Content) {
		if !Rejected && Content == Original {
			Rejected := true
			Assert(FSWriteDurable(TargetPath, Changed))
			return false
		}
		return CryptoSha256(Content)
	}
	Launch(_Success, Borrowed, _Refused) {
		Launches += 1
		Bundle := Borrowed
		return true
	}
	Port["hash"] := Hash
	Fixture.options["port"] := Port
	Fixture.options["reload"] := Launch
	try {
		Receipt := AdditionalFile ? HotstringsScopeApply("clear", Fixture.options)
			: ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		Assert(Rejected, "the expected-old hash refusal must actually execute")
		AssertEqual(0, Launches, "a refused precondition cannot authorize stale publication")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Changed, FSReadUtf8Exact(TargetPath), "the external edit remains authoritative")
		Assert(!FileExist(Receipt["backup"]), "precondition failure precedes backup effects")
	} finally {
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Fixture.options["locator"], Bundle, Port)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("scope-hash-precondition: config hash refusal never publishes a stale image", _ScopeExpectedOldHashRefusal)
Test("scope-hash-precondition: extra file hash refusal never publishes a stale image", _ScopeExpectedOldHashRefusal.Bind(true))

; Actual private source, real lifecycle lease/WAL/backup; only reload launch is
; injected, exactly as the existing scope fixture. No boot warning is authority.
_ScopeObsoleteSource(Literal, Parent := false) {
	return Chr(0xFEFF) . (Parent
		? '[hotstrings]`nautocorrection = ' . Literal . ' # retain until explicit cleanup`n[layout]`nergopti_altgr = true`n[private]`n"literal.dot" = { keep = [1, "x"], date = 1979-05-27 }`n'
		: '[layout]`nergopti_base = ' . Literal . ' # retain until explicit cleanup`nergopti_altgr = true`n[private]`n"literal.dot" = { keep = [1, "x"], date = 1979-05-27 }`n')
}

_ScopeObsoleteLeafClear(Literal, Outcome := "complete") {
	Fixture := _ScopeOwnerFixture(), Source := _ScopeObsoleteSource(Literal)
	Assert(FSWriteDurable(Fixture.path, Source))
	Bundle := 0, Accepted := 0, Refusal := 0
	Launch(Success, Borrowed, Refused) {
		Bundle := Borrowed, Accepted := Success, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Seed := ManifestBuildFeaturesMap()
		ApplyConfigToml(Seed, Fixture.path, &Rejected, , &Outdated)
		AssertEqual(0, Rejected)
		Assert(Outdated.Has("layout`nergopti_base"), "the actual native reader must classify the old value")
		AssertEqual(false, Seed["layout"]["ergopti_base"], "outdated source leaves the runtime neutral")
		Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		AssertEqual("pending", Receipt["status"])
		Expected := StrReplace(Source, "ergopti_altgr = true`n", "")
		AssertEqual(Expected, FSReadUtf8Exact(Fixture.path), "clear preserves the complete obsolete/future image while applying a legitimate sibling effect")
		AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]), "the actual exclusive backup is exact")
		Document := TOML_ParseDocument(Expected)
		Assert(TOML_SameValue(Document["private"], Map("literal.dot", Map("keep", [1, "x"], "date", TOML_ParseDocument('date = 1979-05-27')["date"]))))
		if Outcome == "refused" {
			Refusal.Call("native replacement refused")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "inverse restores the original complete source")
		} else {
			Accepted.Call()
			AssertEqual("committed", Receipt["status"])
			_ConfigWriteTerminalRelease(Bundle)
			; New cache/source identity exercises the actual restart reader, without
			; inventing a completed replacement process in this owner fixture.
			Restart := Fixture.directory . "\restart.toml"
			Assert(FSWriteDurable(Restart, Expected))
			RestartSeed := ManifestBuildFeaturesMap()
			ApplyConfigToml(RestartSeed, Restart, &RestartRejected, , &RestartOutdated)
			AssertEqual(0, RestartRejected)
			Assert(RestartOutdated.Has("layout`nergopti_base"))
			AssertEqual(false, RestartSeed["layout"]["ergopti_base"])
			AssertEqual(Expected, FSReadUtf8Exact(Restart))
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("scope-obsolete-source: scalar leaf clear retains full source and reload neutrality", _ScopeObsoleteLeafClear.Bind('"old-shape"'))
Test("scope-obsolete-source: array leaf clear retains full source", _ScopeObsoleteLeafClear.Bind('[false, 1]'))
Test("scope-obsolete-source: map leaf clear retains full source", _ScopeObsoleteLeafClear.Bind('{ future = [1, "x"] }'))
Test("scope-obsolete-source: float Boolean leaf clear retains full source", _ScopeObsoleteLeafClear.Bind('1.0'))
Test("scope-obsolete-source: actual late refusal restores full obsolete source", _ScopeObsoleteLeafClear.Bind('"old-shape"', "refused"))

_ScopeObsoleteConflict(Literal, Parent := false) {
	Fixture := _ScopeOwnerFixture(), Source := _ScopeObsoleteSource(Literal, Parent)
	Assert(FSWriteDurable(Fixture.path, Source))
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
		if Parent {
			; Shipped autocorrection recommendations are neutral. Exercise a
			; genuine explicit nonneutral descendant through the same public
			; scoped commit owner, rather than inventing a recommendation.
			Operations := (*) => [{ Section: "hotstrings.autocorrection.names", Key: "enabled", Value: true }]
			Receipt := ConfigScopeCommitOperations("hotstrings", "recommended", Operations, Fixture.options)
		} else
			Receipt := ConfigScopeApply("keyboard_layout", "recommended", Map(), Fixture.options)
		AssertEqual("refused", Receipt["status"], "recommendation cannot repair or replace an obsolete setting")
		AssertEqual(0, Backups, "source policy refuses before creating a backup")
		AssertEqual(0, Launches)
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
		Assert(!FileExist(Receipt["backup"]))
		Owner := _ConfigWriteLeaseTryAcquire(Fixture.path, "after-obsolete-refusal")
		Assert(Owner is Object, "refusal retires its lifecycle lease")
		_ConfigWriteLeaseRelease(Owner)
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("scope-obsolete-source: nonneutral leaf replacement refuses before backup", _ScopeObsoleteConflict.Bind('"old-shape"'))
Test("scope-obsolete-source: scalar parent nonneutral descendant refuses before backup", _ScopeObsoleteConflict.Bind('false', true))
Test("scope-obsolete-source: array parent nonneutral descendant refuses before backup", _ScopeObsoleteConflict.Bind('[1, "x"]', true))

_ScopeObsoleteParentClear(Literal) {
	Fixture := _ScopeOwnerFixture(), Source := _ScopeObsoleteSource(Literal, true)
	Assert(FSWriteDurable(Fixture.path, Source))
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Seed := ManifestBuildFeaturesMap()
		ApplyConfigToml(Seed, Fixture.path, &Rejected, , &Outdated)
		AssertEqual(0, Rejected)
		Assert(Outdated.Has("hotstrings`nautocorrection"))
		Receipt := ConfigScopeApply("hotstrings", "clear", Map(), Fixture.options)
		AssertEqual("pending", Receipt["status"])
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "neutral descendants cannot replace an obsolete table parent")
		AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]))
		Refusal.Call("native refusal")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("scope-obsolete-source: scalar parent clear preserves genuine source", _ScopeObsoleteParentClear.Bind('false'))
Test("scope-obsolete-source: array parent clear preserves genuine source", _ScopeObsoleteParentClear.Bind('[1, "x"]'))

; Fresh admitted bytes supersede the unrelated boot warning cache. Repairing
; the actual old leaf permits a subsequent ordinary clear through the same WAL.
_ScopeObsoleteFreshRepair() {
	global _ConfigBootOutdatedEntries
	SavedOutdated := _ConfigBootOutdatedEntries
	Fixture := _ScopeOwnerFixture(), Source := _ScopeObsoleteSource('"old-shape"')
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Assert(FSWriteDurable(Fixture.path, Source))
		Seed := ManifestBuildFeaturesMap()
		ApplyConfigToml(Seed, Fixture.path, &Rejected, , &Outdated)
		Assert(Outdated.Has("layout`nergopti_base"))
		_ConfigBootOutdatedEntries := Outdated
		Repaired := StrReplace(Source, '"old-shape"', "true")
		Assert(FSWriteDurable(Fixture.path, Repaired))
		Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		AssertEqual("pending", Receipt["status"])
		Expected := '[layout]`n[private]`n"literal.dot" = { keep = [1, "x"], date = 1979-05-27 }`n'
		Actual := TOML_ParseDocument(FSReadUtf8Exact(Fixture.path))
		Assert(Actual["layout"] is Map && Actual["layout"].Count == 0,
			"fresh valid values clear despite stale boot warnings, retaining the existing explicit empty header")
		Assert(TOML_SameValue(TOML_ParseDocument(Expected), Actual))
		AssertEqual(Repaired, FSReadUtf8Exact(Receipt["backup"]))
		Refusal.Call("native refusal")
		AssertEqual(Repaired, FSReadUtf8Exact(Fixture.path))
	} finally {
		_ConfigBootOutdatedEntries := SavedOutdated
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("scope-obsolete-source: actual manual repair retires stale boot warnings", _ScopeObsoleteFreshRepair)

_ScopeObsoleteExternalEdit() {
	Fixture := _ScopeOwnerFixture(), Source := _ScopeObsoleteSource('"old-shape"')
	Assert(FSWriteDurable(Fixture.path, Source))
	External := Source . "# external owner changed the exact generation`n", Launches := 0
	Backup(Path, Content) {
		Assert(FSWriteCreateDurable(Path, Content))
		Assert(FSWriteDurable(Fixture.path, External))
		return true
	}
	Launch(*) {
		Launches += 1
		return false
	}
	Fixture.options["backup"] := Backup, Fixture.options["reload"] := Launch
	try {
		Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual(0, Launches)
		AssertEqual(External, FSReadUtf8Exact(Fixture.path), "existing whole-source CAS preserves the foreign successor")
		AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]))
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("scope-obsolete-source: external edit after backup preserves foreign generation", _ScopeObsoleteExternalEdit)

_ScopeObsoletePureBoundaries() {
	Delete := { Section: "hotstrings.autocorrection.names", Key: "enabled", Delete: 1 }
	Entry := { parts: ["hotstrings", "autocorrection"], descendants: true }
	Rows := ConfigObsoleteParentsPreserve([{ parts: ["hotstrings", "autocorrection", "names", "enabled"], neutral: true, row: Delete }], [Entry])
	AssertEqual(0, Rows.Length)
	AssertEqual(1, Delete.Delete, "pure policy never mutates original writer intent")
	Ancestor := [{ parts: ["hotstrings"], neutral: true, row: Delete }]
	AssertThrows(ConfigObsoleteParentsPreserve.Bind(Ancestor, [Entry]), "an ancestor delete cannot borrow obsolete cleanup authority")
	MapDescendant := [{ parts: ["hotstrings", "autocorrection", "names"], neutral: true, row: Delete }]
	AssertThrows(ConfigObsoleteParentsPreserve.Bind(MapDescendant, [{ parts: Entry.parts, descendants: false }]), "neutral map descendants do not gain scalar-parent preservation authority")
	Duplicate := [{ parts: Entry.parts, neutral: true, row: Delete }, { parts: Entry.parts.Clone(), neutral: true, row: Delete }]
	AssertThrows(ConfigObsoleteParentsPreserve.Bind(Duplicate, [Entry]), "filtering must not hide duplicate effects")
	Sparse := [], Sparse.Length := 2, Sparse[2] := Duplicate[1]
	AssertThrows(ConfigObsoleteParentsPreserve.Bind(Sparse, [Entry]))
	Twin := { Section: "hotstrings.Autocorrection", Key: "names", Delete: 1 }
	Kept := ConfigObsoleteParentsPreserve([{ parts: ["hotstrings", "Autocorrection", "names"], neutral: true, row: Twin }], [Entry])
	AssertEqual(1, Kept.Length)
	AssertEqual(ObjPtr(Twin), ObjPtr(Kept[1]), "case-twin and original writer identity remain exact")
	Unknown := '[private]`nsetting = "keep"`n'
	AssertEqual(1, ConfigScopePreserveObsoleteSource(Unknown, [{ Section: "private", Key: "setting", Delete: 1 }]).Length,
		"the native classifier never invents obsolescence from unknown source")
}
Test("scope-obsolete-source: pure exact paths and collision boundaries remain strict", _ScopeObsoletePureBoundaries)

_ScopeObsoleteGlobal(Mode) {
	global _PersonalShortcutsRegistry, KeyboardShortcutAssignments, GestureActionParameters, _SharedDir
	OldRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	OldKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	OldParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	Fixture := _HotstringsScopeFixture()
	Source := _ScopeObsoleteSource('"old-shape"')
	Source := StrReplace(Source, "[layout]`n", '[hotstrings]`nautocorrection = [1, "x"] # obsolete namespace`n[layout]`n')
	Assert(FSWriteDurable(Fixture.path, Source))
	TapPath := Fixture.directory . "\tap_hold.toml"
	TapSource := '[tap_hold.keys.space]`ntap_action = "open_url"`n'
	Assert(FSWriteDurable(TapPath, TapSource))
	Fixture.options["tap_hold_path"] := TapPath
	Fixture.options["tap_hold_defaults"] := _SharedDir . "\tap_hold\defaults.toml"
	Bundle := 0, Refusal := 0, Backups := 0, Launches := 0
	Backup(Path, Content) {
		Backups += 1
		return FSWriteCreateDurable(Path, Content)
	}
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused, Launches += 1
		return true
	}
	Fixture.options["backup"] := Backup, Fixture.options["reload"] := Launch
	try {
		_PersonalShortcutsRegistry := Map("__Order", [])
		KeyboardShortcutAssignments := Map(), GestureActionParameters := Map()
		Receipt := ConfigGlobalScopeApply(Mode, Fixture.options)
		if Mode == "recommended" {
			AssertEqual("refused", Receipt["status"])
			AssertEqual(0, Backups, "global conflicting recommendation refuses before any cohort backup")
			AssertEqual(0, Launches)
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
			AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
			AssertEqual(TapSource, FSReadUtf8Exact(TapPath))
		} else {
			AssertEqual("pending", Receipt["status"])
			Assert(Backups >= 4, "the genuine global file cohort crosses its coordinated backup boundary")
			AssertEqual(1, Launches)
			AssertEqual(StrReplace(Source, "ergopti_altgr = true`n", ""), FSReadUtf8Exact(Fixture.path),
				"global clear preserves obsolete leaf and array parent while applying its unrelated effect")
			AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]))
			Refusal.Call("native global replacement refused")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
			AssertEqual(Fixture.overrideSource, FSReadUtf8Exact(Fixture.overrides))
			AssertEqual(TapSource, FSReadUtf8Exact(TapPath))
			AssertEqual(Fixture.personalSource, FSReadUtf8Exact(Fixture.personal[1]))
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_PersonalShortcutsRegistry := IsSet(OldRegistry) ? OldRegistry : unset
		KeyboardShortcutAssignments := IsSet(OldKeyboard) ? OldKeyboard : unset
		GestureActionParameters := IsSet(OldParameters) ? OldParameters : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("scope-obsolete-source: actual global clear retains obsolete source and exact inverse", _ScopeObsoleteGlobal.Bind("clear"))
Test("scope-obsolete-source: actual global recommendation refuses before the cohort backup", _ScopeObsoleteGlobal.Bind("recommended"))

_ScopeObsoleteSessionRefusal() {
	Fixture := _ScopeOwnerFixture(), Source := _ScopeObsoleteSource('"old-shape"')
	Assert(FSWriteDurable(Fixture.path, Source))
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
		TOML_RefuseWrites(Fixture.path, "invalid schema stamp")
		Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual("invalid schema stamp", TOML_WriteRefusal(Fixture.path), "source admission never clears the existing strict session fence")
		AssertEqual(0, Backups)
		AssertEqual(0, Launches)
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
	} finally {
		_TOML_WriteRefusals().Delete(_TOML_WriteRefusalKey(Fixture.path))
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("scope-obsolete-source: strict schema session refusal survives source preparation", _ScopeObsoleteSessionRefusal)

_ScopeObsoletePreparationRace(Scenario) {
	Fixture := _ScopeOwnerFixture(), Source := _ScopeObsoleteSource('"old-shape"')
	Assert(FSWriteDurable(Fixture.path, Source))
	Foreign := Source . "# new external generation during inventory`n", Backups := 0, Launches := 0, Supplements := 0
	Supplement(_Scope, _Mode) {
		Supplements += 1
		if Scenario == "source"
			Assert(FSWriteDurable(Fixture.path, Foreign))
		else
			TOML_RefuseWrites(Fixture.path, "inventory refused the schema session")
		return []
	}
	Backup(*) {
		Backups += 1
		return false
	}
	Launch(*) {
		Launches += 1
		return false
	}
	Fixture.options["supplement"] := Supplement
	Fixture.options["backup"] := Backup, Fixture.options["reload"] := Launch
	try {
		Receipt := ConfigScopeApply("keyboard_layout", "clear", Map(), Fixture.options)
		AssertEqual(1, Supplements, "the genuine operation supplier runs after the initial source admission")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(0, Backups, "fresh native writer admission refuses before backup")
		AssertEqual(0, Launches)
		AssertEqual(Scenario == "source" ? Foreign : Source, FSReadUtf8Exact(Fixture.path))
		if Scenario == "session"
			AssertEqual("inventory refused the schema session", TOML_WriteRefusal(Fixture.path))
	} finally {
		Key := _TOML_WriteRefusalKey(Fixture.path)
		if _TOML_WriteRefusals().Has(Key)
			_TOML_WriteRefusals().Delete(Key)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("scope-obsolete-source: inventory source drift refuses before any backup", _ScopeObsoletePreparationRace.Bind("source"))
Test("scope-obsolete-source: inventory schema refusal is rechecked before backup", _ScopeObsoletePreparationRace.Bind("session"))
