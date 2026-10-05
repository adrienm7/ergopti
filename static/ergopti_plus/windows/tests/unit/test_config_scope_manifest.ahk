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
		if (Bundle is Object) && _ConfigWriteLeaseState().terminal == Bundle {
			_ConfigWriteTerminalRelease(Bundle)
			; Retire only this experiment's marker; preserve an outer owner.
			if _ConfigTransitionRetainedBarrier == Bundle
				_ConfigTransitionRetainedBarrier := PriorRetained
		}
		_ScopeOwnerCleanup(Fixture)
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
