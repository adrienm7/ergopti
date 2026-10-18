; tests/unit/infra/config/transition/test_config_transition_core.ahk

; ==============================================================================
; MODULE: Bounded Configuration Transition Core Tests
; DESCRIPTION:
; Exercises the multi-target transition journal through a fully in-memory file
; system and deterministic hash adapter. The tests cover strict framing,
; create-only publication, ordered apply, every durable crash direction,
; quarantine honesty, conflict refusal, hard bounds, and idempotent cleanup.
;
; FEATURES & RATIONALE:
; 1. No production file is opened, replaced, or deleted by the subject.
; 2. Pause callbacks model process loss immediately after durable boundaries.
; 3. Mutation logs prove quarantine and conflict paths are genuinely read-only.
; 4. Direct-run support keeps this file testable before run_all integration.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../../../test_framework.ahk
#Include ../../../../../infra/config_transition.ahk





; =====================================
; =====================================
; ======= 1/ In-memory Adapters =======
; =====================================
; =====================================

; Creates isolated in-memory filesystem state.
; @return {Map} Mutable adapter state.
_CTT_NewStore() {
	return Map(
		"files", Map(),
		"unreadable", Map(),
		"calls", [],
		"mutation_count", 0)
}

; Canonicalizes an in-memory path using Windows case/slash semantics.
; @param Path {String} Physical path.
; @return {String} Canonical storage key.
_CTT_Key(Path) {
	return StrLower(StrReplace(Path, "/", "\"))
}

; Seeds or externally changes a file without recording a port mutation.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @param Content {String} Exact content.
_CTT_SetFile(Store, Path, Content) {
	Store["files"][_CTT_Key(Path)] := Content
}

; Returns exact in-memory content, or false when absent.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @return {String|false} Stored content or false.
_CTT_GetFile(Store, Path) {
	Key := _CTT_Key(Path)
	return Store["files"].Has(Key) ? Store["files"][Key] : false
}

; Marks one path unreadable without changing its bytes.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @param Value {Boolean} Whether reads must fail.
_CTT_SetUnreadable(Store, Path, Value := true) {
	Key := _CTT_Key(Path)
	if Value
		Store["unreadable"][Key] := true
	else if Store["unreadable"].Has(Key)
		Store["unreadable"].Delete(Key)
}

; Implements the strict exists adapter.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @return {Integer} Exact 0 or 1.
_CTT_Exists(Store, Path) {
	Store["calls"].Push(Map("method", "exists", "path", Path))
	return Store["files"].Has(_CTT_Key(Path)) ? 1 : 0
}

; Implements exact target and artifact reads.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @return {String|false} Exact content or false.
_CTT_Read(Store, Path) {
	Store["calls"].Push(Map("method", "read", "path", Path))
	Key := _CTT_Key(Path)
	if Store["unreadable"].Has(Key) || !Store["files"].Has(Key)
		return false
	return Store["files"][Key]
}

; Implements bounded live-journal reads.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @param MaxBytes {Integer} Hard byte budget.
; @return {String|false} Content only when readable and in budget.
_CTT_ReadBounded(Store, Path, MaxBytes) {
	Store["calls"].Push(Map("method", "read_bounded", "path", Path))
	Content := _CTT_Read(Store, Path)
	if !(Content is String) || StrPut(Content, "UTF-8") - 1 > MaxBytes
		return false
	return Content
}

; Implements durable create-only private writes for the model.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @param Content {String} Exact content.
; @return {Integer} Exact success status.
_CTT_Write(Store, Path, Content) {
	Store["calls"].Push(Map("method", "write_create_durable", "path", Path))
	Key := _CTT_Key(Path)
	if Store["files"].Has(Key)
		return 0
	Store["mutation_count"] += 1
	Store["files"][Key] := Content
	return 1
}

; Injects a competing private file immediately before a create-only write.
; @param Store {Map} In-memory filesystem state.
; @param ForeignContent {String} Bytes owned by the simulated competitor.
; @param Path {String} Requested private path.
; @param Content {String} Subject content, intentionally refused.
; @return {Integer} Exact refusal status from the create-only adapter.
_CTT_WriteWithRace(Store, ForeignContent, Path, Content) {
	_CTT_SetFile(Store, Path, ForeignContent)
	return _CTT_Write(Store, Path, Content)
}

; Implements atomic no-replace publication.
; @param Store {Map} In-memory filesystem state.
; @param Source {String} Existing private stage.
; @param Destination {String} Absent authoritative name.
; @return {Integer} Exact success or refusal status.
_CTT_MoveCreate(Store, Source, Destination) {
	Store["calls"].Push(Map("method", "move_create", "source", Source,
		"destination", Destination))
	SourceKey := _CTT_Key(Source)
	DestinationKey := _CTT_Key(Destination)
	if !Store["files"].Has(SourceKey) || Store["files"].Has(DestinationKey)
		return 0
	Store["mutation_count"] += 1
	Store["files"][DestinationKey] := Store["files"][SourceKey]
	Store["files"].Delete(SourceKey)
	return 1
}

; Implements atomic replace publication.
; @param Store {Map} In-memory filesystem state.
; @param Source {String} Existing verified stage.
; @param Destination {String} Target to replace or create.
; @return {Integer} Exact success or refusal status.
_CTT_MoveReplace(Store, Source, Destination) {
	Store["calls"].Push(Map("method", "move_replace", "source", Source,
		"destination", Destination))
	SourceKey := _CTT_Key(Source)
	if !Store["files"].Has(SourceKey)
		return 0
	Store["mutation_count"] += 1
	Store["files"][_CTT_Key(Destination)] := Store["files"][SourceKey]
	Store["files"].Delete(SourceKey)
	return 1
}

; Implements idempotent deletion.
; @param Store {Map} In-memory filesystem state.
; @param Path {String} Physical path.
; @return {Integer} Exact success status.
_CTT_Delete(Store, Path) {
	Store["calls"].Push(Map("method", "delete", "path", Path))
	Store["mutation_count"] += 1
	Key := _CTT_Key(Path)
	if Store["files"].Has(Key)
		Store["files"].Delete(Key)
	return 1
}

; Produces a deterministic canonical digest for adapter-level behavior tests.
; @param Content {String} Text to hash.
; @return {String} 64-character lowercase digest-shaped value.
_CTT_Hash(Content) {
	HashValue := 17
	Loop Parse, Content
		HashValue := Mod((HashValue * 131) + Ord(A_LoopField), 0x7FFFFFFF)
	Part := Format("{:08x}", HashValue)
	return Part . Part . Part . Part . Part . Part . Part . Part
}

; Builds the injected port map bound to one store.
; @param Store {Map} In-memory filesystem state.
; @return {Map} Complete config-transition port.
_CTT_Port(Store) {
	return Map(
		"exists", _CTT_Exists.Bind(Store),
		"read", _CTT_Read.Bind(Store),
		"read_bounded", _CTT_ReadBounded.Bind(Store),
		"write_create_durable", _CTT_Write.Bind(Store),
		"move_create", _CTT_MoveCreate.Bind(Store),
		"move_replace", _CTT_MoveReplace.Bind(Store),
		"delete", _CTT_Delete.Bind(Store),
		"hash", _CTT_Hash)
}

; Repeats text without relying on an external helper.
; @param Text {String} Unit to repeat.
; @param Count {Integer} Repetition count.
; @return {String} Concatenated result.
_CTT_Repeat(Text, Count) {
	Result := ""
	Loop Count
		Result .= Text
	return Result
}

; Captures pause seams and throws at one requested durable point.
; @param Seen {Array} Receives every observed point.
; @param StopPoint {String} Point at which to simulate process loss.
; @param Point {String} Current callback point.
_CTT_PauseAt(Seen, StopPoint, Point) {
	Seen.Push(Point)
	if Point == StopPoint
		throw Error("simulated config-transition crash at " . Point)
}

; Returns the directory prefix of a normalized Windows path.
; @param Path {String} Physical path.
; @return {String} Directory without a trailing separator.
_CTT_Directory(Path) {
	LastSlash := InStr(Path, "\", , -1)
	return LastSlash > 0 ? SubStr(Path, 1, LastSlash - 1) : ""
}





; ======================================
; ======================================
; ======= 2/ Strict Format Tests =======
; ======================================
; ======================================

; Proves strict round-trip framing and rejection of schema drift.
_CTT_StrictSchemaAndBounds() {
	Locator := "C:\stable\paths.toml"
	Path := "D:\config\config.toml"
	Hash := _CTT_Hash("old")
	Record := Map(
		"version", CONFIG_TRANSITION_WAL_VERSION,
		"phase", CONFIG_TRANSITION_PHASE_PREPARED,
		"tx_id", "schema_1",
		"locator", Locator,
		"targets", [Map(
			"path", Path,
			"old_present", 1,
			"old_hash", Hash,
			"new_present", 0,
			"new_hash", CONFIG_TRANSITION_HASH_ABSENT)])
	Serialized := _ConfigTransitionSerialize(Record, Locator)
	AssertTrue(Serialized is String, "a valid record must serialize")
	Parsed := _ConfigTransitionParse(Serialized, Locator)
	AssertTrue(Parsed is Map, "the canonical frame must parse")
	AssertEqual(Path, Parsed["targets"][1]["path"])
	AssertFalse(_ConfigTransitionParse(Serialized,
		"C:\other\paths.toml") is Map,
		"a copied WAL must remain bound to its recorded stable locator")
	AssertFalse(_ConfigTransitionParse(StrReplace(Serialized, "version=" . CONFIG_TRANSITION_WAL_VERSION,
		"version=" . (CONFIG_TRANSITION_WAL_VERSION + 1)), Locator) is Map,
		"an unknown WAL version must be rejected")
	AssertFalse(_ConfigTransitionParse(StrReplace(Serialized,
		"phase=prepared", "phase=guessed"), Locator) is Map,
		"an unknown phase must be rejected")
	AssertFalse(_ConfigTransitionParse(StrReplace(Serialized,
		"old_hash=" . Hash, "old_hash=" . StrUpper(Hash)), Locator) is Map,
		"hashes must remain canonical lowercase SHA-256")
	AssertFalse(_ConfigTransitionParse(Serialized . "`nunknown=value", Locator)
		is Map, "unknown trailing fields must be rejected")
	AssertFalse(_ConfigTransitionParse(_CTT_Repeat("X",
		CONFIG_TRANSITION_MAX_WAL_BYTES + 1), Locator) is Map,
		"the parser must reject a WAL beyond 64 KiB")
	AssertEqual(Locator . CONFIG_TRANSITION_WAL_SUFFIX,
		ConfigTransitionWalPath(Locator),
		"the WAL must be derived beside paths.toml")
	LongLocator := "C:\stable\" . _CTT_Repeat("x", 250) . ".toml"
	AssertFalse(ConfigTransitionWalPath(LongLocator) is String,
		"the derived WAL path must satisfy the same component bounds")
	AssertFalse(_ConfigTransitionNormalizePath("C:\config\..\target.toml")
		is String, "parent traversal must be rejected")
	AssertFalse(_ConfigTransitionNormalizePath("C:\config\CON.toml")
		is String, "reserved Windows device basenames must be rejected")
	GeneratedId := _ConfigTransitionNewId()
	AssertTrue(_ConfigTransitionTxIdIsValid(GeneratedId),
		"the standalone ID source must stay inside the strict tx-id grammar")
	AssertTrue(GeneratedId != _ConfigTransitionNewId(),
		"the process-local sequence must distinguish adjacent transitions")
	LocatorTarget := Map(
		"path", Locator,
		"old_present", 1,
		"old_hash", Hash,
		"new_present", 1,
		"new_hash", Hash)
	OutOfOrder := Map(
		"version", CONFIG_TRANSITION_WAL_VERSION,
		"phase", CONFIG_TRANSITION_PHASE_PREPARED,
		"tx_id", "bad_order",
		"locator", Locator,
		"targets", [LocatorTarget, Record["targets"][1]])
	AssertFalse(_ConfigTransitionSerialize(OutOfOrder, Locator) is String,
		"paths.toml must be the final declared target of a relocation")
	CollisionTx := "locator_collision"
	CollisionTarget := "C:\stable\base"
	CollidingLocator := _ConfigTransitionArtifactPaths(CollisionTarget,
		CollisionTx)["old"]
	LocatorCollision := Map(
		"version", CONFIG_TRANSITION_WAL_VERSION,
		"phase", CONFIG_TRANSITION_PHASE_PREPARED,
		"tx_id", CollisionTx,
		"locator", CollidingLocator,
		"targets", [Map(
			"path", CollisionTarget,
			"old_present", 1,
			"old_hash", Hash,
			"new_present", 1,
			"new_hash", Hash)])
	AssertFalse(_ConfigTransitionSerialize(LocatorCollision,
		CollidingLocator) is String,
		"a derived artifact must never alias the stable locator")
}
Test("config transition: strict schema and hard WAL bound "
	. "(config-transition-core-schema)", _CTT_StrictSchemaAndBounds)

; Proves the target-count bound is enforced before any artifact mutation.
_CTT_TargetCountBoundIsPreMutation() {
	Store := _CTT_NewStore()
	Specs := []
	Loop CONFIG_TRANSITION_MAX_TARGETS + 1 {
		Specs.Push(Map("path", "D:\config\target" . A_Index . ".toml",
			"new_present", 1, "new_content", "value=" . A_Index))
	}
	Result := ConfigTransitionPrepare("C:\stable\paths.toml", Specs,
		_CTT_Port(Store), "too_many")
	AssertEqual("fatal", Result["status"])
	AssertEqual("target_count_invalid", Result["kind"])
	AssertEqual(0, Store["mutation_count"],
		"a count beyond the frame-derived bound must be refused before any write")
}
Test("config transition: target count bound precedes I/O "
	. "(config-transition-core-target-bound)",
	_CTT_TargetCountBoundIsPreMutation)

; Proves a legal target count cannot push framing past 64 KiB after artifacts start.
_CTT_WalSizeBoundIsPreMutation() {
	Store := _CTT_NewStore()
	Specs := []
	LongTail := ""
	Loop 42
		LongTail .= "\" . _CTT_Repeat(Chr(96 + Mod(A_Index, 20) + 1), 96)
	; Eight long paths already exceed the byte budget; the test does not need
	; hundreds of redundant paths after capacity becomes frame-derived.
	Loop 8 {
		Specs.Push(Map("path", "D:\config" . LongTail . "\target"
			. A_Index . ".toml", "new_present", 1, "new_content", "x"))
	}
	Result := ConfigTransitionPrepare("C:\stable\paths.toml", Specs,
		_CTT_Port(Store), "wal_too_large")
	AssertEqual("fatal", Result["status"])
	AssertEqual("wal_size_invalid", Result["kind"])
	AssertEqual(0, Store["mutation_count"],
		"an oversized frame must fail before backup or stage publication")
}
Test("config transition: WAL byte bound precedes artifact writes "
	. "(config-transition-core-wal-size-bound)",
	_CTT_WalSizeBoundIsPreMutation)

; New frames accept a complete wide cohort; old durable frames remain recoverable.
_CTT_WideFramesAndLegacyRecovery() {
	Store := _CTT_NewStore(), Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Specs := []
	Loop 12 {
		Path := "D:\config\personal" . A_Index . ".toml"
		_CTT_SetFile(Store, Path, "old-" . A_Index)
		Specs.Push(Map("path", Path, "new_present", 1, "new_content", "new-" . A_Index))
	}
	Prepared := ConfigTransitionPrepare(Locator, Specs, Port, "wide_frame")
	AssertEqual("prepared", Prepared["kind"])
	Wal := _CTT_GetFile(Store, ConfigTransitionWalPath(Locator))
	Parsed := _ConfigTransitionParse(Wal, Locator)
	AssertEqual(CONFIG_TRANSITION_WAL_VERSION, Parsed["version"])
	AssertEqual(12, Parsed["targets"].Length)
	for InvalidCount in ["012", "-12", "99999999999999999999999999999999"] {
		AssertFalse(_ConfigTransitionParse(StrReplace(Wal, "target_count=12",
			"target_count=" . InvalidCount), Locator) is Map)
	}
	AssertFalse(_ConfigTransitionParse(StrReplace(Wal,
		"version=" . CONFIG_TRANSITION_WAL_VERSION,
		"version=" . CONFIG_TRANSITION_LEGACY_WAL_VERSION), Locator) is Map,
		"a v1 frame cannot silently claim the v2 target capacity")
	AssertEqual("recovered_old", ConfigTransitionRecover(Locator, Port)["kind"])
	for Index, Spec in Specs
		AssertEqual("old-" . Index, _CTT_GetFile(Store, Spec["path"]))
	Prepared := ConfigTransitionPrepare(Locator, [Specs[1], Specs[2]], Port, "legacy_frame")
	AssertEqual("prepared", Prepared["kind"])
	Wal := _CTT_GetFile(Store, ConfigTransitionWalPath(Locator))
	Legacy := StrReplace(Wal, "version=" . CONFIG_TRANSITION_WAL_VERSION,
		"version=" . CONFIG_TRANSITION_LEGACY_WAL_VERSION)
	_CTT_SetFile(Store, ConfigTransitionWalPath(Locator), Legacy)
	AssertEqual(CONFIG_TRANSITION_LEGACY_WAL_VERSION, _ConfigTransitionParse(Legacy, Locator)["version"])
	AssertEqual("recovered_old", ConfigTransitionRecover(Locator, Port)["kind"])
	AssertEqual("old-1", _CTT_GetFile(Store, Specs[1]["path"]))
	AssertEqual("old-2", _CTT_GetFile(Store, Specs[2]["path"]))
}
Test("config transition: versioned wide frames and legacy recovery (config-transition-core-capacity)", _CTT_WideFramesAndLegacyRecovery)





; ===============================================
; ===============================================
; ======= 3/ Prepare, Apply, and Recovery =======
; ===============================================
; ===============================================

; Proves the prepared WAL precedes artifacts and makes their partial absence safe.
_CTT_PreparedCommitIsWriteAhead() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\write-ahead.toml"
	_CTT_SetFile(Store, Target, "old")
	Crashed := false
	try ConfigTransitionPrepare(Locator,
		[Map("path", Target, "new_present", 1, "new_content", "new")],
		Port, "write_ahead", _CTT_PauseAt.Bind([], "phase:prepared"))
	catch
		Crashed := true
	AssertTrue(Crashed, "the prepared journal boundary must be crash-testable")
	AssertTrue(_CTT_GetFile(Store, ConfigTransitionWalPath(Locator)) is String,
		"the WAL must be durable at the prepared seam")
	Artifacts := _ConfigTransitionArtifactPaths(Target, "write_ahead")
	AssertFalse(_CTT_GetFile(Store, Artifacts["old"]) is String,
		"content artifacts must not precede write-ahead authority")
	AssertFalse(_CTT_GetFile(Store, Artifacts["new"]) is String,
		"content artifacts must not precede write-ahead authority")
	AssertEqual("old", _CTT_GetFile(Store, Target))
	AssertEqual("recovered_old", ConfigTransitionRecover(Locator, Port)["kind"])
	AssertEqual("old", _CTT_GetFile(Store, Target))
}
Test("config transition: prepared commit is write-ahead of artifacts "
	. "(config-transition-core-write-ahead)", _CTT_PreparedCommitIsWriteAhead)

; Proves prepare isolation, ordered apply, create-only artifacts, and cleanup.
_CTT_PrepareApplyRecoverNew() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	First := "D:\config\config.toml"
	Second := Locator
	_CTT_SetFile(Store, First, "old-first")
	_CTT_SetFile(Store, Second, "old-second")
	Specs := [
		Map("path", First, "new_present", 1, "new_content", "new-first"),
		Map("path", Second, "new_present", 1, "new_content", "new-second")]
	Prepared := ConfigTransitionPrepare(Locator, Specs, Port, "happy_path")
	AssertEqual("prepared", Prepared["kind"])
	AssertEqual("old-first", _CTT_GetFile(Store, First),
		"prepare must not publish a target")
	AssertEqual("old-second", _CTT_GetFile(Store, Second),
		"prepare must keep the stable locator unchanged")
	WalPath := ConfigTransitionWalPath(Locator)
	AssertTrue(_CTT_GetFile(Store, WalPath) is String,
		"prepared intent must be durable before apply")
	for Target in Prepared["record"]["targets"] {
		Artifacts := _ConfigTransitionArtifactPaths(Target["path"], "happy_path")
		for _, ArtifactPath in Artifacts {
			AssertEqual(_CTT_Directory(Target["path"]),
				_CTT_Directory(ArtifactPath),
				"every backup, stage, and publish image must be a sibling")
			AssertEqual(_CTT_Directory(Target["path"]),
				_CTT_Directory(ArtifactPath . ".tmp"),
				"every private create-only temp must remain a sibling")
		}
	}
	for Phase in _ConfigTransitionPhases() {
		WalStage := _ConfigTransitionWalStagePath(WalPath, "happy_path", Phase)
		AssertEqual(_CTT_Directory(WalPath), _CTT_Directory(WalStage),
			"every phase stage must remain beside the live WAL")
	}
	Applied := ConfigTransitionApply(Locator, Port)
	AssertEqual("committed_new", Applied["kind"])
	AssertEqual("new-first", _CTT_GetFile(Store, First))
	AssertEqual("new-second", _CTT_GetFile(Store, Second))
	TargetOrder := []
	for Call in Store["calls"] {
		if Call["method"] == "move_replace"
			&& (Call["destination"] == First || Call["destination"] == Second)
			TargetOrder.Push(Call["destination"])
	}
	AssertEqual(2, TargetOrder.Length,
		"each changed target must publish exactly once")
	AssertEqual(First, TargetOrder[1], "the first declared target must publish first")
	AssertEqual(Second, TargetOrder[2], "the second declared target must publish second")
	Recovered := ConfigTransitionRecover(Locator, Port)
	AssertEqual("recovered_new", Recovered["kind"])
	AssertFalse(_CTT_GetFile(Store, WalPath) is String,
		"cleanup must remove the authoritative WAL last")
	AssertEqual("new-first", _CTT_GetFile(Store, First))
	AssertEqual("new-second", _CTT_GetFile(Store, Second))
	Absent := ConfigTransitionRecover(Locator, Port)
	AssertEqual("absent", Absent["kind"],
		"recovery must be idempotent after cleanup")
	MoveCreateCount := 0
	for Call in Store["calls"] {
		if Call["method"] == "move_create"
			MoveCreateCount += 1
	}
	AssertTrue(MoveCreateCount >= 5,
		"backups, stages, publish images, and the live WAL must use no-replace moves")
}
Test("config transition: prepare isolates and apply preserves declared order "
	. "(config-transition-core-happy-path)", _CTT_PrepareApplyRecoverNew)

; Proves an applying-phase crash deterministically restores every old state.
_CTT_ApplyingCrashRecoversAllOld() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	First := "D:\config\a.toml"
	Second := "D:\config\b.toml"
	_CTT_SetFile(Store, First, "old-a")
	_CTT_SetFile(Store, Second, "old-b")
	Specs := [
		Map("path", First, "new_present", 1, "new_content", "new-a"),
		Map("path", Second, "new_present", 1, "new_content", "new-b")]
	AssertEqual("prepared", ConfigTransitionPrepare(Locator, Specs, Port,
		"crash_apply")["kind"])
	Seen := []
	Crashed := false
	try ConfigTransitionApply(Locator, Port,
		_CTT_PauseAt.Bind(Seen, "target:new:1"))
	catch
		Crashed := true
	AssertTrue(Crashed, "the test seam must stop after the first target commit")
	AssertEqual("phase:applying", Seen[1],
		"the applying marker must commit before any target publication")
	AssertEqual("target:new:1", Seen[2],
		"the first ordered target must expose its post-commit seam")
	AssertEqual("new-a", _CTT_GetFile(Store, First))
	AssertEqual("old-b", _CTT_GetFile(Store, Second))
	Recovered := ConfigTransitionRecover(Locator, Port)
	AssertEqual("recovered_old", Recovered["kind"])
	AssertEqual("old-a", _CTT_GetFile(Store, First))
	AssertEqual("old-b", _CTT_GetFile(Store, Second))
	AssertFalse(_CTT_GetFile(Store, ConfigTransitionWalPath(Locator)) is String)
}
Test("config transition: applying crash restores all old targets "
	. "(config-transition-core-applying-crash)",
	_CTT_ApplyingCrashRecoversAllOld)

; Proves a crash during rollback resumes from a mixed but fully-known image.
_CTT_PartialRollbackResumesIdempotently() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	First := "D:\config\rollback-a.toml"
	Second := "D:\config\rollback-b.toml"
	_CTT_SetFile(Store, First, "old-a")
	_CTT_SetFile(Store, Second, "old-b")
	Specs := [
		Map("path", First, "new_present", 1, "new_content", "new-a"),
		Map("path", Second, "new_present", 1, "new_content", "new-b")]
	ConfigTransitionPrepare(Locator, Specs, Port, "partial_rollback")
	ApplyCrashed := false
	try ConfigTransitionApply(Locator, Port,
		_CTT_PauseAt.Bind([], "target:new:2"))
	catch
		ApplyCrashed := true
	AssertTrue(ApplyCrashed,
		"the setup crash must leave both targets new under applying authority")
	RollbackCrashed := false
	try ConfigTransitionRecover(Locator, Port,
		_CTT_PauseAt.Bind([], "target:old:1"))
	catch
		RollbackCrashed := true
	AssertTrue(RollbackCrashed, "rollback must expose each durable target boundary")
	AssertEqual("old-a", _CTT_GetFile(Store, First))
	AssertEqual("new-b", _CTT_GetFile(Store, Second))
	AssertEqual("recovered_old", ConfigTransitionRecover(Locator, Port)["kind"])
	AssertEqual("old-a", _CTT_GetFile(Store, First))
	AssertEqual("old-b", _CTT_GetFile(Store, Second))
}
Test("config transition: partial rollback resumes idempotently "
	. "(config-transition-core-partial-rollback)",
	_CTT_PartialRollbackResumesIdempotently)

; Proves deletion is a first-class target state and rollback restores presence.
_CTT_DeletionCrashRestoresOldPresence() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\delete-me.toml"
	_CTT_SetFile(Store, Target, "old-present")
	Specs := [Map("path", Target, "new_present", 0, "new_content", "")]
	AssertEqual("prepared", ConfigTransitionPrepare(Locator, Specs, Port,
		"delete_crash")["kind"])
	Crashed := false
	try ConfigTransitionApply(Locator, Port,
		_CTT_PauseAt.Bind([], "target:new:1"))
	catch
		Crashed := true
	AssertTrue(Crashed, "the delete commit point must be crash-testable")
	AssertFalse(_CTT_GetFile(Store, Target) is String,
		"the new side must represent target absence exactly")
	AssertEqual("recovered_old", ConfigTransitionRecover(Locator, Port)["kind"])
	AssertEqual("old-present", _CTT_GetFile(Store, Target),
		"applying-phase recovery must restore the immutable backup")
}
Test("config transition: deletion crash restores old presence "
	. "(config-transition-core-delete-rollback)",
	_CTT_DeletionCrashRestoresOldPresence)

; Proves committed-new is the sole authority even when cleanup never began.
_CTT_CommittedNewCrashRecoversAllNew() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\config.toml"
	_CTT_SetFile(Store, Target, "old")
	Specs := [Map("path", Target, "new_present", 1, "new_content", "new")]
	AssertEqual("prepared", ConfigTransitionPrepare(Locator, Specs, Port,
		"commit_new")["kind"])
	Crashed := false
	try ConfigTransitionApply(Locator, Port,
		_CTT_PauseAt.Bind([], "phase:committed_new"))
	catch
		Crashed := true
	AssertTrue(Crashed, "the committed-new pause seam must be reachable")
	WalContent := _CTT_GetFile(Store, ConfigTransitionWalPath(Locator))
	WalRecord := _ConfigTransitionParse(WalContent, Locator)
	AssertEqual(CONFIG_TRANSITION_PHASE_COMMITTED_NEW, WalRecord["phase"])
	AssertEqual("new", _CTT_GetFile(Store, Target))
	_CTT_SetFile(Store, Target, "old")
	AssertEqual("recovered_new", ConfigTransitionRecover(Locator, Port)["kind"])
	AssertEqual("new", _CTT_GetFile(Store, Target))
}
Test("config transition: committed-new crash preserves all new targets "
	. "(config-transition-core-committed-new)",
	_CTT_CommittedNewCrashRecoversAllNew)

; Proves recovery itself resumes after committed-old but before artifact cleanup.
_CTT_CommittedOldCrashIsIdempotent() {
	Store := _CTT_NewStore()
	Port := _CTT_Port(Store)
	Locator := "C:\stable\paths.toml"
	Target := "D:\config\config.toml"
	_CTT_SetFile(Store, Target, "old")
	Specs := [Map("path", Target, "new_present", 1, "new_content", "new")]
	ConfigTransitionPrepare(Locator, Specs, Port, "commit_old")
	ApplyCrashed := false
	try ConfigTransitionApply(Locator, Port,
		_CTT_PauseAt.Bind([], "target:new:1"))
	catch
		ApplyCrashed := true
	AssertTrue(ApplyCrashed,
		"the setup crash must leave recovery in the applying phase")
	Crashed := false
	try ConfigTransitionRecover(Locator, Port,
		_CTT_PauseAt.Bind([], "phase:committed_old"))
	catch
		Crashed := true
	AssertTrue(Crashed, "recovery must expose the committed-old boundary")
	WalContent := _CTT_GetFile(Store, ConfigTransitionWalPath(Locator))
	WalRecord := _ConfigTransitionParse(WalContent, Locator)
	AssertEqual(CONFIG_TRANSITION_PHASE_COMMITTED_OLD, WalRecord["phase"])
	AssertEqual("old", _CTT_GetFile(Store, Target))
	_CTT_SetFile(Store, Target, "new")
	AssertEqual("recovered_old", ConfigTransitionRecover(Locator, Port)["kind"])
	AssertEqual("old", _CTT_GetFile(Store, Target),
		"committed-old must override the known opposite side without guessing")
	AssertEqual("absent", ConfigTransitionRecover(Locator, Port)["kind"])
}
Test("config transition: committed-old recovery resumes cleanup idempotently "
	. "(config-transition-core-committed-old)",
	_CTT_CommittedOldCrashIsIdempotent)





; ===================================
; ===================================
; ======= 5/ Direct-run Entry =======
; ===================================
; ===================================

if A_LineFile = A_ScriptFullPath
	RunTests()
