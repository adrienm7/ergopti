; tests/unit/infra/config/transition/test_config_transition_quarantine.ahk

; ==============================================================================
; MODULE: Config Transition Quarantine and Conflicts
; DESCRIPTION:
; Malformed and unreadable WAL bytes are quarantined, conflicting targets
; refuse recovery, and foreign bytes are never overwritten.
; ==============================================================================

#Requires AutoHotkey v2.0





_CTT_QuarantineIsBytePreserving() {
	Locator := "C:\stable\paths.toml"
	WalPath := ConfigTransitionWalPath(Locator)
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Malformed := "ERGOPTI_CONFIG_TRANSITION_WAL`nversion=999"
	_CTT_SetFile(Store, WalPath, Malformed)
	Before := Store["mutation_count"]
	Result := ConfigTransitionRecover(Locator, Port)
	AssertEqual("quarantine", Result["status"])
	AssertEqual("wal_malformed", Result["kind"])
	AssertEqual(Malformed, _CTT_GetFile(Store, WalPath),
		"malformed bytes must remain untouched for forensic quarantine")
	AssertEqual(Before, Store["mutation_count"],
		"malformed inspection must perform zero mutations")
	_CTT_SetUnreadable(Store, WalPath)
	Before := Store["mutation_count"]
	Result := ConfigTransitionRecover(Locator, Port)
	AssertEqual("quarantine", Result["status"])
	AssertEqual("wal_unreadable", Result["kind"])
	AssertEqual(Malformed, _CTT_GetFile(Store, WalPath),
		"unreadable bytes must remain at the exact original path")
	AssertEqual(Before, Store["mutation_count"],
		"unreadable inspection must perform zero mutations")
}
Test("config transition: quarantine preserves malformed and unreadable WAL bytes "
	. "(config-transition-core-quarantine)", _CTT_QuarantineIsBytePreserving)

; Proves a valid WAL never authorizes overwriting an unknown target state.
_CTT_ValidWalConflictIsFatalAndReadOnly() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\config.toml"
	_CTT_SetFile(Store, Target, "old")
	Specs := [Map("path", Target, "new_present", 1, "new_content", "new")]
	AssertEqual("prepared", ConfigTransitionPrepare(Locator, Specs, Port,
		"conflict")["kind"])
	WalPath := ConfigTransitionWalPath(Locator)
	WalBefore := _CTT_GetFile(Store, WalPath)
	_CTT_SetFile(Store, Target, "external-third-state")
	Before := Store["mutation_count"]
	Result := ConfigTransitionRecover(Locator, Port)
	AssertEqual("fatal", Result["status"])
	AssertEqual("target_conflict", Result["kind"])
	AssertEqual("external-third-state", _CTT_GetFile(Store, Target),
		"recovery must never guess over an unknown target hash")
	AssertEqual(WalBefore, _CTT_GetFile(Store, WalPath),
		"the valid conflicting WAL must remain authoritative")
	AssertEqual(Before, Store["mutation_count"],
		"conflict detection must finish before any recovery write")
}
Test("config transition: valid conflicting WAL is typed fatal and read-only "
	. "(config-transition-core-conflict)",
	_CTT_ValidWalConflictIsFatalAndReadOnly)

; Proves a required artifact hash conflict is detected before rollback mutation.
_CTT_ArtifactHashConflictIsFatalAndReadOnly() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	First := "D:\config\hash-a.toml"
	Second := "D:\config\hash-b.toml"
	_CTT_SetFile(Store, First, "old-a")
	_CTT_SetFile(Store, Second, "old-b")
	Specs := [
		Map("path", First, "new_present", 1, "new_content", "new-a"),
		Map("path", Second, "new_present", 1, "new_content", "new-b")]
	Prepared := ConfigTransitionPrepare(Locator, Specs, Port, "hash_conflict")
	ApplyCrashed := false
	try ConfigTransitionApply(Locator, Port,
		_CTT_PauseAt.Bind([], "target:new:1"))
	catch
		ApplyCrashed := true
	AssertTrue(ApplyCrashed,
		"the setup crash must make the first rollback artifact authoritative")
	Artifacts := _ConfigTransitionArtifactPaths(First,
		Prepared["record"]["tx_id"])
	_CTT_SetFile(Store, Artifacts["old"], "tampered-backup")
	WalPath := ConfigTransitionWalPath(Locator)
	WalBefore := _CTT_GetFile(Store, WalPath)
	Before := Store["mutation_count"]
	Result := ConfigTransitionRecover(Locator, Port)
	AssertEqual("fatal", Result["status"])
	AssertEqual("cleanup_hash_conflict", Result["kind"],
		"the complete owned namespace must fail before rollback planning")
	AssertEqual("new-a", _CTT_GetFile(Store, First))
	AssertEqual("old-b", _CTT_GetFile(Store, Second))
	AssertEqual(WalBefore, _CTT_GetFile(Store, WalPath))
	AssertEqual(Before, Store["mutation_count"],
		"all required recovery artifacts must preflight before rollback starts")
}
Test("config transition: artifact hash conflict is fatal before rollback "
	. "(config-transition-core-artifact-hash-conflict)",
	_CTT_ArtifactHashConflictIsFatalAndReadOnly)

; Proves cleanup validates every sibling namespace member before any deletion.
_CTT_CleanupNamespaceConflictIsFatalAndReadOnly() {
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\cleanup.toml"
	TxId := "cleanup_conflict"
	WalPath := ConfigTransitionWalPath(Locator)
	Candidates := []
	for Phase in _ConfigTransitionPhases() {
		Stage := _ConfigTransitionWalStagePath(WalPath, TxId, Phase)
		Candidates.Push(Stage)
	}
	Artifacts := _ConfigTransitionArtifactPaths(Target, TxId)
	for Side in ["old", "new"] {
		for Name in [Side, "publish_" . Side]
			Candidates.Push(Artifacts[Name])
	}
	Loop Candidates.Length {
		CollisionIndex := A_Index
		Store := _CTT_NewStore()
		Port := _CTT_Port(Store)
		_CTT_SetFile(Store, Target, "old")
		Prepared := ConfigTransitionPrepare(Locator,
			[Map("path", Target, "new_present", 1, "new_content", "new")],
			Port, TxId)
		AssertEqual("prepared", Prepared["kind"])
		CollisionPath := Candidates[CollisionIndex]
		ForeignBytes := "foreign-cleanup-bytes-" . CollisionIndex
		_CTT_SetFile(Store, CollisionPath, ForeignBytes)
		Before := Store["mutation_count"]
		Result := ConfigTransitionRecover(Locator, Port)
		AssertEqual("fatal", Result["status"])
		AssertEqual("cleanup_hash_conflict", Result["kind"])
		AssertEqual(ForeignBytes, _CTT_GetFile(Store, CollisionPath),
			"cleanup must preserve every unknown namespace sibling")
		AssertTrue(_CTT_GetFile(Store, WalPath) is String,
			"a cleanup conflict must retain the authoritative WAL")
		AssertEqual(Before, Store["mutation_count"],
			"the full cleanup namespace must validate before its first delete")
	}
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	_CTT_SetFile(Store, Target, "old")
	Prepared := ConfigTransitionPrepare(Locator,
		[Map("path", Target, "new_present", 0, "new_content", "")],
		Port, "cleanup_absent")
	Artifacts := _ConfigTransitionArtifactPaths(Target, "cleanup_absent")
	AbsentTemp := Artifacts["new"] . ".tmp"
	_CTT_SetFile(Store, AbsentTemp, "foreign-absent-state")
	Before := Store["mutation_count"]
	Result := ConfigTransitionRecover(Locator, Port)
	AssertEqual("fatal", Result["status"])
	AssertEqual("cleanup_namespace_conflict", Result["kind"])
	AssertEqual("foreign-absent-state", _CTT_GetFile(Store, AbsentTemp),
		"an absent-state private temp must not authorize any bytes")
	AssertEqual(Before, Store["mutation_count"])
}
Test("config transition: cleanup validates the complete owned namespace "
	. "(config-transition-core-cleanup-conflict)",
	_CTT_CleanupNamespaceConflictIsFatalAndReadOnly)

; Models process loss inside WriteFile: the create-only handle has published its
; private name, but neither complete bytes nor the adapter finally block ran.
; Once the live WAL and every authoritative target/artifact validate, only that
; private temp is disposable and recovery must remain bootable.
_CTT_InterruptedPrivateTempsAreRecoverable() {
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\interrupted-temp.toml"
	for TempKind in ["artifact", "wal"] {
		Store := _CTT_NewStore()
		Port := _CTT_Port(Store)
		_CTT_SetFile(Store, Target, "old")
		TxId := "interrupted_" . TempKind
		Prepared := ConfigTransitionPrepare(Locator,
			[Map("path", Target, "new_present", 1, "new_content", "new")],
			Port, TxId)
		AssertEqual("prepared", Prepared["kind"])
		if TempKind == "artifact" {
			Artifacts := _ConfigTransitionArtifactPaths(Target, TxId)
			InterruptedTemp := Artifacts["new"] . ".tmp"
		} else {
			WalPath := ConfigTransitionWalPath(Locator)
			InterruptedTemp := _ConfigTransitionWalStagePath(WalPath, TxId,
				CONFIG_TRANSITION_PHASE_APPLYING) . ".tmp"
		}
		_CTT_SetFile(Store, InterruptedTemp, "truncated-write")
		Result := ConfigTransitionRecover(Locator, Port)
		AssertEqual("ok", Result["status"])
		AssertEqual("recovered_old", Result["kind"])
		AssertEqual("old", _CTT_GetFile(Store, Target))
		AssertFalse(_CTT_GetFile(Store, InterruptedTemp) is String,
			"a WAL-owned interrupted private temp must be discarded")
		AssertFalse(_CTT_GetFile(Store,
			ConfigTransitionWalPath(Locator)) is String)
	}
}
Test("config transition: interrupted private temps recover after full preflight "
	. "(config-transition-core-interrupted-temp)",
	_CTT_InterruptedPrivateTempsAreRecoverable)

; Proves pre-existing deterministic artifacts cannot be overwritten.
_CTT_CreateOnlyNamespaceCollisionIsFatal() {
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\config.toml"
	Artifacts := _ConfigTransitionArtifactPaths(Target, "occupied")
	for CollisionPath in [Artifacts["old"], Artifacts["old"] . ".tmp"] {
		Store := _CTT_NewStore()
		Port := _CTT_Port(Store)
		_CTT_SetFile(Store, Target, "old")
		_CTT_SetFile(Store, CollisionPath, "foreign-bytes")
		Before := Store["mutation_count"]
		Result := ConfigTransitionPrepare(Locator,
			[Map("path", Target, "new_present", 1, "new_content", "new")],
			Port, "occupied")
		AssertEqual("fatal", Result["status"])
		AssertEqual("artifact_conflict", Result["kind"])
		AssertEqual("foreign-bytes", _CTT_GetFile(Store, CollisionPath),
			"pre-WAL namespace collisions must remain byte-preserving")
		AssertEqual(Before, Store["mutation_count"],
			"the whole deterministic namespace must be probed before writes")
		AssertFalse(_CTT_GetFile(Store,
			ConfigTransitionWalPath(Locator)) is String)
	}
}
Test("config transition: create-only artifact collision fails before mutation "
	. "(config-transition-core-create-only)",
	_CTT_CreateOnlyNamespaceCollisionIsFatal)

; Proves create-only publication resumes its own exact temp without replacement.
_CTT_CreateOnlyPublicationResumesExactTemp() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Destination := "D:\config\artifact.stage"
	Content := "verified-content"
	Digest := _CTT_Hash(Content)
	_CTT_SetFile(Store, Destination . ".tmp", Content)
	Result := _ConfigTransitionPublishCreate(Port, Destination, Content, Digest)
	AssertEqual("ok", Result["status"])
	AssertEqual(Content, _CTT_GetFile(Store, Destination))
	AssertFalse(_CTT_GetFile(Store, Destination . ".tmp") is String)
	_CTT_SetFile(Store, Destination, "foreign-content")
	Before := Store["mutation_count"]
	Result := _ConfigTransitionPublishCreate(Port, Destination, Content, Digest)
	AssertEqual("fatal", Result["status"])
	AssertEqual("artifact_conflict", Result["kind"])
	AssertEqual("foreign-content", _CTT_GetFile(Store, Destination),
		"no-replace recovery must never overwrite an unknown destination")
	AssertEqual(Before, Store["mutation_count"])
	RaceStore := _CTT_NewStore()
	RacePort := _CTT_Port(RaceStore)
	RacePort["write_create_durable"] := _CTT_WriteWithRace.Bind(RaceStore,
		"foreign-temp")
	RaceDestination := "D:\config\raced.stage"
	Before := RaceStore["mutation_count"]
	Result := _ConfigTransitionPublishCreate(RacePort, RaceDestination,
		Content, Digest)
	AssertEqual("fatal", Result["status"])
	AssertEqual("artifact_hash_conflict", Result["kind"])
	AssertEqual("foreign-temp", _CTT_GetFile(RaceStore,
		RaceDestination . ".tmp"),
		"a create-only private write race must preserve competing bytes")
	AssertFalse(_CTT_GetFile(RaceStore, RaceDestination) is String)
	AssertEqual(Before, RaceStore["mutation_count"])
}
Test("config transition: create-only publication resumes exact private temp "
	. "(config-transition-core-create-only-resume)",
	_CTT_CreateOnlyPublicationResumesExactTemp)

; Proves oversized live and staged WAL frames never bypass the read budget.
_CTT_OversizedWalFramesAreBounded() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	WalPath := ConfigTransitionWalPath(Locator)
	Oversized := _CTT_Repeat("Z", CONFIG_TRANSITION_MAX_WAL_BYTES + 1)
	_CTT_SetFile(Store, WalPath, Oversized)
	Before := Store["mutation_count"]
	Result := ConfigTransitionRecover(Locator, Port)
	AssertEqual("quarantine", Result["status"])
	AssertEqual("wal_unreadable", Result["kind"])
	AssertEqual(StrLen(Oversized), StrLen(_CTT_GetFile(Store, WalPath)))
	AssertEqual(Before, Store["mutation_count"])
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Target := "D:\config\bounded-stage.toml"
	_CTT_SetFile(Store, Target, "old")
	ConfigTransitionPrepare(Locator,
		[Map("path", Target, "new_present", 1, "new_content", "new")],
		Port, "oversized_stage")
	StagePath := _ConfigTransitionWalStagePath(WalPath, "oversized_stage",
		CONFIG_TRANSITION_PHASE_APPLYING)
	_CTT_SetFile(Store, StagePath, Oversized)
	Before := Store["mutation_count"]
	Result := ConfigTransitionRecover(Locator, Port)
	AssertEqual("fatal", Result["status"])
	AssertEqual("cleanup_hash_conflict", Result["kind"])
	AssertEqual(StrLen(Oversized), StrLen(_CTT_GetFile(Store, StagePath)),
		"oversized phase-stage bytes must remain untouched")
	AssertEqual(Before, Store["mutation_count"])
}
Test("config transition: live and staged WAL reads remain bounded "
	. "(config-transition-core-live-bound)", _CTT_OversizedWalFramesAreBounded)

; Adapter results are authority, so values that are merely truthy must not be
; accepted as the exact Integer status promised by the port contract.
_CTT_MalformedPortStatusesNeverAuthorizeMutation() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\typed.toml"
	Port["exists"] := (Path) => "0"
	Before := Store["mutation_count"]
	Result := ConfigTransitionPrepare(Locator,
		[Map("path", Target, "new_present", 1, "new_content", "new")],
		Port, "string_zero")
	AssertEqual("retry", Result["status"])
	AssertEqual("wal_probe_failed", Result["kind"])
	AssertEqual(Before, Store["mutation_count"],
		"string '0' from exists must not authorize an absent namespace")

	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Port["write_create_durable"] := (Path, Content) => "1"
	Before := Store["mutation_count"]
	Result := ConfigTransitionPrepare(Locator,
		[Map("path", Target, "new_present", 1, "new_content", "new")],
		Port, "string_one")
	AssertEqual("retry", Result["status"])
	AssertEqual("artifact_write_failed", Result["kind"])
	AssertEqual(Before, Store["mutation_count"],
		"string '1' from a mutator must not authorize durable publication")
}
Test("config transition: malformed adapter statuses remain non-authoritative "
	. "(config-transition-core-strict-port-status)",
	_CTT_MalformedPortStatusesNeverAuthorizeMutation)

_CTT_ExpectedOldUsesTheRecordedSnapshot() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\config.toml"
	V1 := "old-v1"
	V2 := "old-v2-with-unrelated-data"
	_CTT_SetFile(Store, Target, V2)
	Spec := Map(
		"path", Target,
		"new_present", 1,
		"new_content", "candidate-built-from-v1",
		"expected_old", Map("present", 1, "hash", _CTT_Hash(V1)))
	Result := ConfigTransitionPrepare(Locator, [Spec], Port, "expected_old_1")
	AssertEqual("retry", Result["status"])
	AssertEqual("expected_old_conflict", Result["kind"])
	AssertEqual(V2, _CTT_GetFile(Store, Target),
		"an intervening external image must remain untouched")
	AssertFalse(_CTT_GetFile(Store, ConfigTransitionWalPath(Locator)) is String,
		"expected-old conflict must refuse before live WAL publication")
	AssertEqual(0, Store["mutation_count"],
		"expected authority must be checked against the exact recorded snapshot")
}
Test("config transition: expected-old authority guards the recorded snapshot "
	. "(config-transition-core-expected-old)",
	_CTT_ExpectedOldUsesTheRecordedSnapshot)
