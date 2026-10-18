; tests/unit/infra/config/transition/test_config_transition_windows_port.ahk

; ==============================================================================
; MODULE: Configuration Transition Windows Port Tests
; DESCRIPTION:
; Exercises the real create-only, bounded-read, no-replace rename, strict probe,
; strict delete, and SHA binding used by the multi-file transition journal.
; Every destructive operation is confined to a unique test-owned directory.
;
; FEATURES & RATIONALE:
; 1. Collisions must preserve both source and destination bytes.
; 2. A zero-byte WAL is readable data, then rejected by the strict WAL parser.
; 3. UTF-8 limits count bytes rather than decoded characters.
; 4. Windows-only methods never expand the portable FileSystem contract.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../../../test_framework.ahk
#Include ../../../../../adapters/file_system.ahk
#Include ../../../../../adapters/crypto.ahk
#Include ../../../../../infra/config_write_lease.ahk
#Include ../../../../../infra/config_transition.ahk
#Include ../../../../../infra/config_transition_runtime.ahk





; ======================================
; ======================================
; ======= 1/ Isolated Test Paths =======
; ======================================
; ======================================

_CTWP_NewDir(Label) {
	static Sequence := 0
	Sequence += 1
	Path := A_Temp . "\ergopti-config-transition-port-"
		. A_ScriptHwnd . "-" . A_TickCount . "-" . Sequence . "-" . Label
	DirCreate(Path)
	return Path
}

_CTWP_CleanupDir(Path) {
	if !(Path is String) || Path == ""
		return
	try DirDelete(Path, true)
}





; ===============================================
; ===============================================
; ======= 2/ Contract and Collision Tests =======
; ===============================================
; ===============================================

_CTWP_ProductionPortIsExact() {
	Port := ConfigTransitionProductionPort()
	Expected := Map(
		"exists", FSStrictExists,
		"read", FSReadUtf8Exact,
		"read_bounded", FSReadUtf8ExactBounded,
		"write_create_durable", FSWriteCreateDurable,
		"move_create", FSAtomicMoveCreate,
		"move_replace", FSAtomicMoveReplace,
		"delete", FSDeleteStrict,
		"hash", CryptoSha256)
	AssertEqual(8, Port.Count,
		"the production transition port must expose exactly eight methods")
	for Name, Callback in Expected {
		AssertTrue(Port.Has(Name), "missing transition method: " . Name)
		AssertTrue(Port[Name] == Callback,
			"transition method is bound to the wrong production adapter: " . Name)
	}
	AssertEqual(5, ADAPTER_FILE_SYSTEM.Count,
		"Windows transaction primitives must not pollute the portable port")
	for Name in ["read_bounded", "write_create_durable", "move_create",
			"move_replace", "hash"]
		AssertFalse(ADAPTER_FILE_SYSTEM.Has(Name),
			"portable FileSystem unexpectedly exposes Windows transaction method "
			. Name)
}
Test("config transition port: exact eight-call production binding "
	. "(config-transition-port-exact-binding)", _CTWP_ProductionPortIsExact)

_CTWP_CryptoChecksEveryNativeStatus() {
	PublicBody := _DriverFuncBody("CryptoSha256")
	Body := _DriverFuncBody("_CryptoSha256Cng")
	AssertContains(PublicBody, "_CryptoSha256WithProvider(Data, _CryptoSha256Cng)")
	AssertContains(Body, "ObjectStatus := DllCall")
	AssertContains(Body, "DigestStatus := DllCall")
	AssertContains(Body, "ObjectStatus != 0 || DigestStatus != 0")
	AssertContains(Body, "HashStatus := DllCall")
	AssertContains(Body, "if HashStatus != 0")
	AssertContains(Body, "FinishStatus := DllCall")
	AssertContains(Body, "if FinishStatus != 0")
	AssertContains(Body, "DigestLength != 32")
}
Test("config transition port: SHA-256 validates every CNG status before trust "
	. "(config-transition-port-strict-cng-status)",
	_CTWP_CryptoChecksEveryNativeStatus)

_CTWP_CreateOnlyPreservesCollision() {
	Dir := _CTWP_NewDir("create")
	Path := Dir . "\private.stage"
	try {
		First := FSWriteCreateDurable(Path, "first")
		Second := FSWriteCreateDurable(Path, "second")
		AssertTrue((First is Integer) && First == 1,
			"the first create-only durable write must return exact Integer 1")
		AssertTrue((Second is Integer) && Second == 0,
			"a create-only collision must return exact Integer 0")
		AssertEqual("first", FSRead(Path),
			"a create-only collision must preserve the incumbent bytes")
	} finally _CTWP_CleanupDir(Dir)
}
Test("config transition port: create-only write preserves collision bytes "
	. "(config-transition-port-create-collision)",
	_CTWP_CreateOnlyPreservesCollision)

_CTWP_MoveCreateNeverReplaces() {
	Dir := _CTWP_NewDir("move")
	Source := Dir . "\source.stage"
	Destination := Dir . "\destination.wal"
	try {
		AssertTrue(FSWriteCreateDurable(Source, "new") == 1)
		AssertTrue(FSWriteCreateDurable(Destination, "old") == 1)
		Refused := FSAtomicMoveCreate(Source, Destination)
		AssertTrue((Refused is Integer) && Refused == 0,
			"no-replace move must return exact Integer 0 on collision")
		AssertEqual("new", FSRead(Source),
			"a refused no-replace move must retain its source")
		AssertEqual("old", FSRead(Destination),
			"a refused no-replace move must retain its destination")
		AssertTrue(FSDeleteStrict(Destination) == 1)
		Moved := FSAtomicMoveCreate(Source, Destination)
		AssertTrue((Moved is Integer) && Moved == 1,
			"no-replace move to an absent destination must return Integer 1")
		AssertTrue(FSStrictExists(Source) == 0)
		AssertEqual("new", FSRead(Destination))
	} finally _CTWP_CleanupDir(Dir)
}
Test("config transition port: no-replace move is collision preserving "
	. "(config-transition-port-move-collision)", _CTWP_MoveCreateNeverReplaces)





; ===========================================
; ===========================================
; ======= 3/ Strict Probe and Bounds ========
; ===========================================
; ===========================================

_CTWP_StrictProbeAndDeleteAreTyped() {
	Dir := _CTWP_NewDir("strict")
	Path := Dir . "\target.toml"
	try {
		Missing := FSStrictExists(Path)
		AssertTrue((Missing is Integer) && Missing == 0)
		AssertTrue(FSDeleteStrict(Path) == 1,
			"strict delete must be idempotent for an absent path")
		AssertTrue(FSWriteCreateDurable(Path, "value") == 1)
		Present := FSStrictExists(Path)
		AssertTrue((Present is Integer) && Present == 1)
		AssertTrue(FSDeleteStrict(Path) == 1)
		AssertTrue(FSStrictExists(Path) == 0)
	} finally _CTWP_CleanupDir(Dir)
}
Test("config transition port: strict probe/delete return exact integers "
	. "(config-transition-port-strict-status)",
	_CTWP_StrictProbeAndDeleteAreTyped)

_CTWP_StrictDeleteSurfacesSharingViolation() {
	Dir := _CTWP_NewDir("locked")
	Path := Dir . "\locked.toml"
	Handle := -1
	try {
		AssertTrue(FSWriteCreateDurable(Path, "keep") == 1)
		static GENERIC_READ := 0x80000000
		static OPEN_EXISTING := 3
		static FILE_ATTRIBUTE_NORMAL := 0x00000080
		Handle := DllCall("kernel32\CreateFileW", "Str", Path,
			"UInt", GENERIC_READ, "UInt", 1, "Ptr", 0,
			"UInt", OPEN_EXISTING, "UInt", FILE_ATTRIBUTE_NORMAL,
			"Ptr", 0, "Ptr")
		AssertTrue(Handle != -1, "the test must own a non-delete-sharing handle")
		AssertThrows(() => FSDeleteStrict(Path),
			"a sharing violation must throw instead of impersonating absence")
		AssertEqual("keep", FSRead(Path),
			"a refused strict delete must preserve target bytes")
	} finally {
		if (Handle != -1)
			try DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition port: strict delete surfaces sharing violations "
	. "(config-transition-port-delete-sharing)",
	_CTWP_StrictDeleteSurfacesSharingViolation)

_CTWP_BoundedReadHandlesEmptyAndUtf8Bytes() {
	Dir := _CTWP_NewDir("bounded")
	EmptyPath := Dir . "\empty.wal"
	Utf8Path := Dir . "\utf8.wal"
	try {
		AssertTrue(FSWriteCreateDurable(EmptyPath, "") == 1)
		Empty := FSReadBounded(EmptyPath, 1)
		AssertTrue(Empty is String)
		AssertEqual("", Empty,
			"an empty readable WAL must reach the parser as an empty String")
		AssertTrue(FSWriteCreateDurable(Utf8Path, "é") == 1)
		AssertEqual("é", FSReadBounded(Utf8Path, 2),
			"the two-byte UTF-8 value must fit a two-byte budget")
		AssertFalse(FSReadBounded(Utf8Path, 1) is String,
			"the two-byte UTF-8 value must exceed a one-byte budget")
	} finally _CTWP_CleanupDir(Dir)
}
Test("config transition port: bounded reads count UTF-8 bytes and admit empty "
	. "(config-transition-port-bounded-utf8)",
	_CTWP_BoundedReadHandlesEmptyAndUtf8Bytes)

_CTWP_RawHex(Path) {
	FH := FileOpen(Path, "r", "UTF-8-RAW")
	if !IsObject(FH)
		return false
	try {
		ByteCount := FH.Length
		FH.Pos := 0
		Raw := Buffer(ByteCount > 0 ? ByteCount : 1, 0)
		if ByteCount > 0 && FH.RawRead(Raw, ByteCount) != ByteCount
			return false
		Hex := ""
		loop ByteCount
			Hex .= Format("{:02x}", NumGet(Raw, A_Index - 1, "UChar"))
		return Hex
	} finally FH.Close()
}

_CTWP_ExactReadPreservesBomThroughRollback() {
	Dir := _CTWP_NewDir("bom-rollback")
	PathsFile := Dir . "\paths.toml"
	Target := Dir . "\config.toml"
	OldContent := Chr(0xFEFF) . "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n[old]`nvalue = 1`n"
	Bundle := false
	try {
		AssertTrue(FSWriteCreateDurable(Target, OldContent) == 1)
		AssertEqual("current", ConfigMigrateBoot(Target)["status"])
		OldHex := _CTWP_RawHex(Target)
		AssertTrue(SubStr(OldHex, 1, 6) == "efbbbf",
			"test prerequisite: old target carries a physical UTF-8 BOM")
		AssertEqual(OldContent, FSReadUtf8Exact(Target),
			"transaction reader must preserve BOM as U+FEFF")
		AssertFalse(CryptoSha256(OldContent) == CryptoSha256(SubStr(OldContent, 2)),
			"BOM and no-BOM byte images must never share transition authority")
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Target])
		AssertTrue(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Target, "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n[new]`nvalue = 2`n")],
			Bundle, ConfigTransitionProductionPort())
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle,
			ConfigTransitionProductionPort())
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertEqual(OldHex, _CTWP_RawHex(Target),
			"all-old recovery must restore every original byte including EF BB BF")
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition port: BOM-bearing old bytes survive apply and rollback "
	. "(config-transition-port-bom-rollback)",
	_CTWP_ExactReadPreservesBomThroughRollback)

_CTWP_ExactReadRejectsInvalidUtf8AndBomWal() {
	Dir := _CTWP_NewDir("utf8-refusal")
	InvalidPath := Dir . "\invalid.bin"
	PathsFile := Dir . "\paths.toml"
	Target := Dir . "\config.toml"
	try {
		Raw := Buffer(2, 0)
		NumPut("UChar", 0xC3, Raw, 0)
		NumPut("UChar", 0x28, Raw, 1)
		FH := FileOpen(InvalidPath, "w", "UTF-8-RAW")
		AssertTrue(IsObject(FH))
		FH.RawWrite(Raw, 2)
		FH.Close()
		AssertFalse(FSReadUtf8Exact(InvalidPath) is String,
			"invalid UTF-8 must not collapse to a replacement-character snapshot")

		AssertTrue(FSWriteCreateDurable(Target, "old") == 1)
		Port := ConfigTransitionProductionPort()
		Prepared := ConfigTransitionPrepare(PathsFile,
			[ConfigTransitionPresentTarget(Target, "new")], Port)
		AssertTrue(ConfigTransitionResultIs(Prepared, "prepared"))
		WalPath := ConfigTransitionWalPath(PathsFile)
		WalContent := FSReadUtf8ExactBounded(WalPath, 65536)
		AssertTrue(WalContent is String)
		AssertTrue(FSDeleteStrict(WalPath) == 1)
		AssertTrue(FSWriteCreateDurable(WalPath,
			Chr(0xFEFF) . WalContent) == 1)
		Inspected := ConfigTransitionInspect(PathsFile, Port)
		AssertEqual("quarantine", Inspected["status"])
		AssertEqual("wal_malformed", Inspected["kind"],
			"a BOM-prefixed live WAL is not the exact canonical frame")
	} finally _CTWP_CleanupDir(Dir)
}
Test("config transition port: invalid UTF-8 and BOM-mutated WAL are refused "
	. "(config-transition-port-exact-utf8-refusal)",
	_CTWP_ExactReadRejectsInvalidUtf8AndBomWal)

_CTWP_ExpectedOldRefusesBuildCommitGap() {
	Dir := _CTWP_NewDir("expected-old")
	PathsFile := Dir . "\paths.toml"
	Target := Dir . "\config.toml"
	Bundle := false
	try {
		Header := "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n"
		V1 := Header . "[existing]`nvalue = 1`n"
		V2 := Header . '[existing]`nvalue = 2`nunrelated = "keep"`n'
		AssertTrue(FSWriteCreateDurable(Target, V1) == 1)
		Expected := Map("present", 1, "hash", CryptoSha256(V1))
		AssertTrue(FSDeleteStrict(Target) == 1)
		AssertTrue(FSWriteCreateDurable(Target, V2) == 1)
		AssertEqual("current", ConfigMigrateBoot(Target)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Target])
		AssertTrue(Bundle is Object)
		Result := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Target, Header . "[candidate]`nvalue = 1`n",
				Expected)], Bundle, ConfigTransitionProductionPort())
		AssertEqual("retry", Result["status"])
		AssertEqual("expected_old_conflict", Result["kind"])
		AssertEqual(V2, FSReadUtf8Exact(Target),
			"an external write between build and commit must remain untouched")
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(PathsFile)) == 1,
			"optimistic conflict must refuse before WAL publication")
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition port: optimistic old authority closes build/commit race "
	. "(config-transition-port-expected-old-conflict)",
	_CTWP_ExpectedOldRefusesBuildCommitGap)





; ===================================
; ===================================
; ======= 4/ Direct-run Entry =======
; ===================================
; ===================================

if A_LineFile = A_ScriptFullPath
	RunTests()


_CTWP_NativePortConstructorRejectsClone() {
	Port := ConfigTransitionProductionPort(), Clone := Port.Clone()
	AssertTrue(ConfigTransitionProductionPort(Port))
	AssertFalse(ConfigTransitionProductionPort(Clone), "an equivalent public native-method map is not actual constructor issuance")
	Original := Port["read"]
	try {
		Port["read"] := (*) => "not a native observation"
		AssertFalse(ConfigTransitionProductionPort(Port), "in-place callback replacement loses native port authentication")
	} finally Port["read"] := Original
	AssertTrue(ConfigTransitionProductionPort(Port))
	AssertTrue(ConfigTransitionProductionPort(Port, "retire"))
	AssertFalse(ConfigTransitionProductionPort(Port), "constructor retirement cannot be undone through a copied map")
}
Test("config transition native source: genuine port issuance rejects copies and in-place callback replacement", _CTWP_NativePortConstructorRejectsClone)

_CTWP_SchemaSource(Marker) {
	return '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion()
		. '`n[future]`nmarker = "' . Marker . '"`nkeep = { truth=false, number=1, text="1" }`n'
}

_CTWP_SchemaForwardRollbackRestoresExactSource() {
	Dir := _CTWP_NewDir("schema-forward-rollback")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := Chr(0xFEFF) . _CTWP_SchemaSource("old"), NewSource := _CTWP_SchemaSource("new")
	Bundle := false
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		BeforeHex := _CTWP_RawHex(Path)
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		AssertEqual(NewSource, FSReadUtf8Exact(Path))
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertEqual(BeforeHex, _CTWP_RawHex(Path), "native guarded rollback restores the independent complete original byte image")
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(PathsFile)))
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition native source: genuine current-source publication and exact rollback stay live", _CTWP_SchemaForwardRollbackRestoresExactSource)

_CTWP_FreshSchemaRollbackRemovesOnlyOwnedTarget() {
	Dir := _CTWP_NewDir("schema-fresh-rollback")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml", Foreign := Dir . "\foreign.txt"
	Bundle := false
	try {
		AssertEqual(1, FSWriteCreateDurable(Foreign, "foreign`n"))
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, _CTWP_SchemaSource("fresh"))], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		AssertTrue(FSStrictExists(Path))
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertFalse(FSStrictExists(Path), "genuine missing-source rollback invokes guarded actual native target removal")
		AssertTrue(FSUtf8ExactMatches(Foreign, "foreign`n"), "unowned sibling bytes remain untouched")
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition native source: actual fresh-target rollback preserves absence and foreign files", _CTWP_FreshSchemaRollbackRemovesOnlyOwnedTarget)

_CTWP_SchemaWithdrawalRefusesNativeBoundary(Noop := false) {
	global _ConfigTransitionRetainedBarrier
	PreviousRetained := _ConfigTransitionRetainedBarrier
	Dir := _CTWP_NewDir(Noop ? "schema-noop-withdrawal" : "schema-stage-withdrawal")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("old"), NewSource := Noop ? OldSource : _CTWP_SchemaSource("new")
	Registry := ConfigMigrateShippedRegistry(), Version := Registry["current"], Withdrawals := 0
	Bundle := false
	Pause(Label) {
		if Label == (Noop ? "noop:new:1" : "phase:applying") {
			Registry["current"] := Version + 1
			Withdrawals += 1
		}
	}
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Result := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle, 0, Pause)
		AssertEqual(1, Withdrawals, "the actual real native stage/noop checkpoint must execute once")
		AssertFalse(ConfigTransitionResultIs(Result, "committed_new"), "withdrawn canonical source ownership cannot acknowledge native publication")
		AssertEqual(OldSource, FSReadUtf8Exact(Path), "all original target bytes remain after actual native boundary refusal")
		AssertTrue(Result.Has("barrier_retained") && Result["barrier_retained"] == 1)
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Registry["current"] := Version
		Recovered := ConfigTransitionRecoverOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(Recovered, "recovered_old"), "restored genuine source ownership resolves the real held WAL")
		AssertEqual(OldSource, FSReadUtf8Exact(Path))
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(PathsFile)))
	} finally {
		Registry["current"] := Version
		_ConfigTransitionRetainedBarrier := PreviousRetained
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition native source: real staged publication refuses withdrawn schema owner", _CTWP_SchemaWithdrawalRefusesNativeBoundary)
Test("config transition native source: real unchanged-target acknowledgment refuses withdrawn schema owner", _CTWP_SchemaWithdrawalRefusesNativeBoundary.Bind(true))

_CTWP_GenuinePortObserver(Name) {
	Port := ConfigTransitionProductionPort(), Hits := { count: 0 }
	try {
		if Name == "Count" {
			Count := Port.Count
			Port.DefineProp(Name, { Get: (*) => (Hits.count += 1, Count) })
		} else {
			Port.DefineProp(Name, { Call: (This, Arity) =>
				(Hits.count += 1, Map.Prototype.__Enum.Call(This, Arity)) })
		}
		AssertFalse(ConfigTransitionProductionPort(Port), "the original issued native map requires pure original container shape")
		AssertEqual(0, Hits.count, "native issuance invokes no exported map observer")
		Port.DeleteProp(Name)
		AssertTrue(ConfigTransitionProductionPort(Port), "exact original map repair preserves its actual native issuance")
		AssertTrue(ConfigTransitionProductionPort() == Port, "canonical native method owner is reused without accumulating private issuances")
		AssertTrue(ConfigTransitionProductionPort(Port, "retire"))
		AssertFalse(ConfigTransitionProductionPort(Port), "actual retirement is terminal for the same old native map")
		Fresh := ConfigTransitionProductionPort()
		AssertFalse(Fresh == Port), AssertTrue(ConfigTransitionProductionPort(Fresh))
		AssertEqual(0, Hits.count)
	} finally {
		if Object.Prototype.HasOwnProp.Call(Port, Name)
			Port.DeleteProp(Name)
	}
}
for Name in ["Count", "__Enum"]
	Test("config transition native source: genuine native port observer refuses before execution " . Name,
		_CTWP_GenuinePortObserver.Bind(Name))

_CTWP_GuardedNativePortLifetime(Mode) {
	Dir := _CTWP_NewDir("native-port-lifetime"), PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	Source := _CTWP_SchemaSource("actual native port lifetime")
	Bundle := false, Native := ConfigTransitionProductionPort(), Hits := { count: 0 }
	OriginalCase := Native.CaseSense, OriginalCallbacks := Native.Clone()
	RepairCase() {
		Native.Clear()
		Native.CaseSense := OriginalCase
		for Name, Callback in OriginalCallbacks
			Native[Name] := Callback
	}
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source) == 1)
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Captured := _ConfigTransitionGuardedProductionPort(PathsFile, Bundle,
			[ConfigTransitionPresentTarget(Path, Source)])
		AssertTrue(Captured.noop.Call(Path, Source, 1) == 1, "the genuine captured native source permits its actual noop")
		switch Mode {
		case "observer":
			Native.DefineProp("__Item", { Get: (This, Key) =>
				(Hits.count += 1, OriginalCallbacks[Key]) })
		case "case":
			Native.Clear()
			Native.CaseSense := OriginalCase == "On" ? "Off" : "On"
			for Name, Callback in OriginalCallbacks
				Native[Name] := Callback
		case "retire":
			AssertTrue(ConfigTransitionProductionPort(Native, "retire"))
		}
		AssertFalse(Captured.noop.Call(Path, Source, 1),
			"genuine native port shape/image/retirement withdrawal reaches the actual captured native noop owner")
		AssertThrows(() => _ConfigTransitionRuntimePort(Native),
			"the same withdrawn original native identity refuses before any custom portable dispatch")
		AssertThrows(() => Captured.port["read"].Call(Path),
			"withdrawn original native read owner refuses before any exported callback")
		AssertEqual(0, Hits.count), AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(PathsFile)))
		if Mode == "observer"
			Native.DeleteProp("__Item")
		else if Mode == "case"
			RepairCase()
		if Mode != "retire"
			AssertTrue(Captured.noop.Call(Path, Source, 1) == 1, "exact original genuine descriptor/image repair re-admits the same captured owner")
		else {
			Fresh := ConfigTransitionProductionPort()
			AssertFalse(Fresh == Native), AssertTrue(ConfigTransitionProductionPort(Fresh))
			AssertFalse(Captured.noop.Call(Path, Source, 1), "fresh port construction never resurrects the retired original captured owner")
			Recaptured := _ConfigTransitionGuardedProductionPort(PathsFile, Bundle,
				[ConfigTransitionPresentTarget(Path, Source)])
			AssertTrue(Recaptured.noop.Call(Path, Source, 1) == 1, "genuine new native owner plus same still-active source/bundle permits a new actual noop")
		}
		AssertEqual(0, Hits.count), AssertEqual(Source, FSReadUtf8Exact(Path))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Native, "__Item")
			Native.DeleteProp("__Item")
		if Mode == "case"
			RepairCase()
		if Bundle is Object
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		_CTWP_CleanupDir(Dir)
	}
}
for Mode in ["observer", "case", "retire"]
	Test("config transition native source: actual guarded native port withdrawal " . Mode,
		_CTWP_GuardedNativePortLifetime.Bind(Mode))


; Exercise all admitted native operations with their genuine current signatures.
; The generic eight-method port remains unchanged for unrelated native owners.
_CTWP_GuardedConfigurationOperationsUseActualProducers() {
	Dir := _CTWP_NewDir("admitted-configuration-producers")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	Stage := Dir . "\config.stage", ArtifactStage := Dir . "\artifact.stage", Artifact := Dir . "\artifact"
	OldSource := _CTWP_SchemaSource("old admitted native image")
	NewSource := _CTWP_SchemaSource("new admitted native image")
	Bundle := false
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Captured := _ConfigTransitionGuardedProductionPort(PathsFile, Bundle,
			[ConfigTransitionPresentTarget(Path, NewSource)])
		AssertEqual(1, Captured.noop.Call(Path, OldSource, 1), "captured actual native acknowledgement accepts its old image")
		AssertEqual(1, FSWriteCreateDurable(ArtifactStage, "owned artifact"))
		AssertEqual(1, Captured.port["move_create"].Call(ArtifactStage, Artifact),
			"guarded artifact publication calls the admitted wrapper without extending the generic producer signature")
		AssertFalse(FSStrictExists(ArtifactStage))
		AssertEqual("owned artifact", FSReadUtf8Exact(Artifact))
		AssertEqual(1, Captured.port["delete"].Call(Artifact), "guarded artifact cleanup retains the actual strict native delete receipt")
		AssertFalse(FSStrictExists(Artifact))
		AssertEqual(1, FSWriteCreateDurable(Stage, NewSource))
		AssertEqual(1, Captured.port["move_replace"].Call(Stage, Path),
			"guarded configuration publication consumes admission through the actual retained native replacement")
		AssertFalse(FSStrictExists(Stage))
		AssertEqual(NewSource, Captured.port["read"].Call(Path))
		AssertEqual(1, Captured.noop.Call(Path, NewSource, 1), "the same issued owner acknowledges its genuine new native image")
	} finally {
		if Bundle is Object
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition native source: guarded operations retain genuine generic producer signatures",
	_CTWP_GuardedConfigurationOperationsUseActualProducers)


_CTWP_GuardedAdmittedProducerObserver(Producer) {
	Dir := _CTWP_NewDir("admitted-producer-observer")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml", Stage := Dir . "\config.stage"
	Source := _CTWP_SchemaSource("admitted observer old image")
	Candidate := _CTWP_SchemaSource("admitted observer new image")
	Bundle := false, Hits := { count: 0 }
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Captured := _ConfigTransitionGuardedProductionPort(PathsFile, Bundle,
			[ConfigTransitionPresentTarget(Path, Candidate)])
		AssertEqual(1, FSWriteCreateDurable(Stage, Candidate))
		Producer.DefineProp("Call", { Call: (*) => (Hits.count += 1, 1) })
		AssertFalse(Captured.noop.Call(Path, Source, 1), "altered actual admitted producer refuses the already captured owner")
		AssertFalse(Captured.port["move_replace"].Call(Stage, Path), "altered actual producer cannot publish through its own fabricated acknowledgement")
		AssertEqual(0, Hits.count, "the captured native guard invokes no altered producer observer")
		AssertTrue(FSUtf8ExactMatches(Path, Source)), AssertTrue(FSUtf8ExactMatches(Stage, Candidate))
		Producer.DeleteProp("Call")
		AssertEqual(1, Captured.noop.Call(Path, Source, 1), "exact producer descriptor repair restores its original captured ownership")
		AssertEqual(1, Captured.port["move_replace"].Call(Stage, Path))
		AssertTrue(FSUtf8ExactMatches(Path, Candidate))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Producer, "Call")
			Producer.DeleteProp("Call")
		if Bundle is Object
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		_CTWP_CleanupDir(Dir)
	}
}
for Producer in [FSConfigAtomicMoveReplace, FSConfigAtomicMoveCreate, FSConfigDeleteStrict, FSNativeAcknowledge]
	Test("config transition native source: admitted producer observer refuses without invocation " . Producer.Name,
		_CTWP_GuardedAdmittedProducerObserver.Bind(Producer))


_CTWP_GenuineNativeCallbackObserver(Callback) {
	Dir := _CTWP_NewDir("native-callback-observer")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	Source := _CTWP_SchemaSource("original generic producer observer")
	Bundle := false, Hits := { count: 0 }
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Native := ConfigTransitionProductionPort()
		AssertEqual(8, Native.Count, "the entire native callback class remains enumerated")
		Captured := _ConfigTransitionGuardedProductionPort(PathsFile, Bundle,
			[ConfigTransitionPresentTarget(Path, Source)])
		Callback.DefineProp("Call", { Call: (*) => (Hits.count += 1, 1) })
		AssertFalse(ConfigTransitionProductionPort(Native), "an altered genuine generic producer has no native port admission")
		AssertFalse(Captured.noop.Call(Path, Source, 1), "an altered original callback cannot lend acknowledgement authority")
		AssertThrows(() => Captured.port["read"].Call(Path), "altered original native callbacks refuse before source dispatch")
		AssertEqual(0, Hits.count, "the complete callback class is inspected intrinsically before any observer executes")
		Callback.DeleteProp("Call")
		AssertTrue(ConfigTransitionProductionPort(Native))
		AssertEqual(1, Captured.noop.Call(Path, Source, 1), "exact callback repair restores the same original native port")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Callback, "Call")
			Callback.DeleteProp("Call")
		if Bundle is Object
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		_CTWP_CleanupDir(Dir)
	}
}
for Callback in [FSStrictExists, FSReadUtf8Exact, FSReadUtf8ExactBounded, FSWriteCreateDurable,
	FSAtomicMoveCreate, FSAtomicMoveReplace, FSDeleteStrict, CryptoSha256]
	Test("config transition native source: every original native callback observer refuses " . Callback.Name,
		_CTWP_GenuineNativeCallbackObserver.Bind(Callback))


; A real committed native WAL supplies both independent images before injection.
; Each original producer must refuse its own Call observer without executing it.
_CTWP_RecoveryProducerObserver(Producer) {
	Dir := _CTWP_NewDir("recovery-producer-observer")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("old native recovery producer image")
	NewSource := _CTWP_SchemaSource("new native recovery producer image")
	Bundle := false, Hits := { count: 0 }
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"), "the subject owns an actual committed native WAL")
		WalPath := ConfigTransitionWalPath(PathsFile)
		BeforeWal := FSReadUtf8Exact(WalPath)
		AssertTrue(BeforeWal is String && BeforeWal != "")
		BeforeTarget := _CTWP_RawHex(Path)
		Facts := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		AssertTrue(Facts is Object, "genuine original recovery producers supply actual native facts")
		AssertEqual(OldSource, Facts.old.source), AssertEqual(1, Facts.old.present)
		AssertEqual(NewSource, Facts.new.source), AssertEqual(1, Facts.new.present)
		Producer.DefineProp("Call", { Call: (*) => (Hits.count += 1, 1) })
		Refused := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		AssertFalse(Refused, "a same-identity recovery producer observer cannot forge recovery facts")
		AssertEqual(0, Hits.count, "all actual recovery producer observers refuse before dispatch")
		Producer.DeleteProp("Call")
		AssertEqual(BeforeTarget, _CTWP_RawHex(Path), "observer refusal changes no actual target bytes")
		AssertTrue(FSUtf8ExactMatches(WalPath, BeforeWal), "observer refusal preserves the authoritative native WAL")
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Repaired := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		AssertTrue(Repaired is Object, "exact original descriptor repair restores native recovery fact ownership")
		AssertEqual(OldSource, Repaired.old.source), AssertEqual(NewSource, Repaired.new.source)
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertEqual(OldSource, FSReadUtf8Exact(Path))
		AssertFalse(FSStrictExists(WalPath))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Producer, "Call")
			Producer.DeleteProp("Call")
		if Bundle is Object
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		_CTWP_CleanupDir(Dir)
	}
}
for Producer in [ConfigTransitionProductionPort, ConfigTransitionInspect, _ConfigTransitionPreflightOwnedNamespace,
	_ConfigTransitionReadArtifact, _ConfigTransitionArtifactPaths, _ConfigTransitionReadSnapshot,
	_ConfigWriteTerminalOwnsExact, _ConfigWriteLeaseKey, ConfigTransitionResultIs]
	Test("config transition native recovery: every actual producer Call observer refuses " . Producer.Name,
		_CTWP_RecoveryProducerObserver.Bind(Producer))


_CTWP_RecoveryActualPortWithdrawal(Callback := 0) {
	Dir := _CTWP_NewDir("recovery-actual-port-withdrawal")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("old original recovery port image")
	NewSource := _CTWP_SchemaSource("new original recovery port image")
	Bundle := false, Hits := { count: 0 }, Native := ConfigTransitionProductionPort()
	try {
		AssertEqual(8, Native.Count, "the complete original native callback class remains the recovery subject")
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		AssertTrue(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		Facts := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		AssertTrue(Facts is Object, "the actual original port first proves both native recovery images")
		AssertEqual(OldSource, Facts.old.source), AssertEqual(NewSource, Facts.new.source)
		WalPath := ConfigTransitionWalPath(PathsFile), BeforeWal := FSReadUtf8Exact(WalPath)
		BeforeTarget := _CTWP_RawHex(Path)
		if HasMethod(Callback, "Call")
			Callback.DefineProp("Call", { Call: (*) => (Hits.count += 1, 1) })
		else
			Native.DefineProp("__Item", { Get: (*) => (Hits.count += 1, 1) })
		Refused := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		AssertFalse(Refused, "withdrawn original callback or canonical port cannot issue recovery facts")
		AssertEqual(0, Hits.count, "native port provenance refuses before its altered descriptor dispatch")
		if IsObject(Callback)
			Callback.DeleteProp("Call")
		else
			Native.DeleteProp("__Item")
		AssertEqual(BeforeTarget, _CTWP_RawHex(Path))
		AssertTrue(FSUtf8ExactMatches(WalPath, BeforeWal))
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Repaired := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		AssertTrue(Repaired is Object, "repair of the exact original port restores genuine native facts")
		AssertEqual(OldSource, Repaired.old.source), AssertEqual(NewSource, Repaired.new.source)
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertEqual(OldSource, FSReadUtf8Exact(Path))
		AssertFalse(FSStrictExists(WalPath))
	} finally {
		if IsObject(Callback) && Object.Prototype.HasOwnProp.Call(Callback, "Call")
			Callback.DeleteProp("Call")
		if Object.Prototype.HasOwnProp.Call(Native, "__Item")
			Native.DeleteProp("__Item")
		if Bundle is Object
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		_CTWP_CleanupDir(Dir)
	}
}
Test("config transition native recovery: original port descriptor cannot lend recovery facts",
	_CTWP_RecoveryActualPortWithdrawal)
for Callback in [FSStrictExists, FSReadUtf8Exact, FSReadUtf8ExactBounded, FSWriteCreateDurable,
	FSAtomicMoveCreate, FSAtomicMoveReplace, FSDeleteStrict, CryptoSha256]
	Test("config transition native recovery: every original callback descriptor withdraws fact ownership " . Callback.Name,
		_CTWP_RecoveryActualPortWithdrawal.Bind(Callback))


; A real AHK timer withdraws custody while the unchanged Win32 reader owns
; its acquired handle. No port, read function or dispatcher is replaced here.
_CTWP_NativeReadCustodyTick(State) {
	if !State.active || State.observed || !FileReadActivityBusy(State.path)
		return
	try {
		Activity := _FileReadActivityState()
		for _, Reader in Activity.owners {
			if Reader.key != State.pathKey || Reader.handle == -1
				continue
			Identity := FSHandleSnapshot(Reader.handle)
			if !Identity.Get("ok", false)
				continue
			State.observed := true
			State.readerHandle := Reader.handle
			State.timerCritical := A_IsCritical
			if State.mode == "hash"
				CryptoSha256.DefineProp("Call", {Call: State.observer})
			else if State.mode == "port"
				State.port.DefineProp("__Item", {Get: State.observer})
			return
		}
	} catch as Err {
		State.failure := Err.Message
		State.active := false
	}
}


; These fixture-only helpers serve the two real acquired-read timer families.
; They do not grant production admission or replace the native journal ports.
_CTWP_TemporalDescriptorMatches(Left, Right) {
	if !(Left is Object) || !(Right is Object)
		return false
	LeftCount := 0, RightCount := 0
	for Name in ObjOwnProps(Left) {
		LeftCount += 1
		if !Object.Prototype.HasOwnProp.Call(Right, Name) || Left.%Name% != Right.%Name%
			return false
	}
	for Name in ObjOwnProps(Right)
		RightCount += 1
	return LeftCount == RightCount
}

_CTWP_TemporalRestoreDescriptor(Owner, Name, HadOriginal, Original, Observer, Field) {
	if !(Owner is Object)
		return
	HasCurrent := Object.Prototype.HasOwnProp.Call(Owner, Name)
	if !HasCurrent {
		if HadOriginal
			throw Error("The original acquired-read descriptor was withdrawn by another owner.")
		return
	}
	Current := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
	if HadOriginal && _CTWP_TemporalDescriptorMatches(Current, Original)
		return
	Expected := {}, Expected.%Field% := Observer
	if !_CTWP_TemporalDescriptorMatches(Current, Expected)
		throw Error("A foreign acquired-read descriptor replacement is retained.")
	Object.Prototype.DeleteProp.Call(Owner, Name)
	if HadOriginal
		Object.Prototype.DefineProp.Call(Owner, Name, Original)
	HasAfter := Object.Prototype.HasOwnProp.Call(Owner, Name)
	if HadOriginal {
		if !HasAfter || !_CTWP_TemporalDescriptorMatches(Object.Prototype.GetOwnPropDesc.Call(Owner, Name), Original)
			throw Error("Exact acquired-read descriptor restoration was not acknowledged.")
	} else if HasAfter
		throw Error("The acquired-read descriptor's original absence was not restored.")
}

_CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native, State, Timer,
		RestoreHash, RestorePort, PriorRetained, ReleaseOwner) {
	global _ConfigTransitionRetainedBarrier
	Receipt := {errors: State.restoreErrors.Clone(), resolved: false, ownerRetired: false, deleted: false,
		timerStopped: false, hashRestored: false, portRestored: false}
	Attempt(Phase, Operation) {
		try Operation.Call()
		catch as Failure
			Receipt.errors.Push({phase: Phase, failure: Failure})
	}
	StopTimer() {
		State.active := false
		SetTimer(Timer, 0)
		Receipt.timerStopped := true
	}
	RestoreHashOnce() {
		RestoreHash.Call()
		Receipt.hashRestored := true
	}
	RestorePortOnce() {
		RestorePort.Call()
		Receipt.portRestored := true
	}
	ResolveJournal() {
		if !Receipt.timerStopped || !Receipt.hashRestored || !Receipt.portRestored
			throw Error("Unsettled acquired-read callback cleanup retains its real journal.")
		if FileReadActivityBusy(Path) || !ConfigTransitionProductionPort(Native)
			throw Error("Actual acquired-read native ownership has not settled.")
		Inspected := ConfigTransitionInspect(PathsFile, Native)
		if ConfigTransitionResultIs(Inspected, "ready") {
			if !(Bundle is Object) || !_ConfigWriteTerminalTryAcquire([], Bundle)
				throw Error("The real acquired-read journal has no held native retirement owner.")
			Resolution := ConfigTransitionRollbackOwned(PathsFile, Bundle, Native)
			if !ConfigTransitionResultIs(Resolution, "recovered_old")
				throw Error("The actual acquired-read journal refused owned rollback.")
			Inspected := ConfigTransitionInspect(PathsFile, Native)
		}
		if !ConfigTransitionResultIs(Inspected, "absent")
			throw Error("The real acquired-read journal is unresolved before retirement.")
		if FSStrictExists(Path) && !FSUtf8ExactMatches(Path, OldSource)
			throw Error("A foreign acquired-read source is retained before retirement.")
		Receipt.resolved := true
	}
	RetireOwner() {
		global _ConfigTransitionRetainedBarrier
		if !Receipt.resolved {
			if Bundle is Object && !ConfigTransitionRetainBarrier(Bundle)
				throw Error("The genuine unresolved acquired-read barrier could not be retained.")
			return
		}
		if Bundle is Object && _ConfigWriteTerminalTryAcquire([], Bundle) {
			ReleaseOwner.Call()
		}
		if _ConfigWriteTerminalIsActive()
			throw Error("A real terminal barrier remains active before acquired-read file retirement.")
		if Bundle is Object && (_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object
				|| _ConfigWriteLeaseSelectOwner(Bundle, PathsFile) is Object)
			throw Error("The acquired-read target or locator lease remains active.")
		Receipt.ownerRetired := true
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if Bundle is Object && _ConfigTransitionRetainedBarrier == Bundle
				_ConfigTransitionRetainedBarrier := PriorRetained
		} finally Critical(PreviousCritical)
	}
	RetainUnresolved() {
		if (!Receipt.resolved || !Receipt.ownerRetired) && Bundle is Object
				&& _ConfigWriteTerminalTryAcquire([], Bundle) && !ConfigTransitionRetainBarrier(Bundle)
			throw Error("The actual acquired-read cleanup debt could not retain its native barrier.")
	}
	RetireFiles() {
		if !Receipt.resolved || !Receipt.ownerRetired
			throw Error("Unresolved acquired-read files remain available for real recovery.")
		if !ConfigTransitionResultIs(ConfigTransitionInspect(PathsFile, Native), "absent")
			throw Error("A successor acquired-read journal is retained.")
		if DirExist(Dir) {
			; Only the two genuine file intentions can belong to this fixture.
			; Foreign entries and subdirectories prevent any destructive cleanup.
			loop files Dir . "\*", "FD" {
				if InStr(A_LoopFileAttrib, "D") || (A_LoopFileName != "config.toml"
						&& A_LoopFileName != "owned-native-repair.txt")
					throw Error("An unowned acquired-read directory entry is retained.")
			}
			if FSStrictExists(Path) && !FSUtf8ExactMatches(Path, OldSource)
				throw Error("A foreign acquired-read source remains after native release.")
			RepairPath := Dir . "\owned-native-repair.txt"
			if FSStrictExists(RepairPath) && !FSUtf8ExactMatches(RepairPath, "owned native repair output")
				throw Error("A foreign acquired-read repair file is retained.")
			if FSStrictExists(Path) && FSDeleteStrict(Path) != 1
				throw Error("The exact acquired-read source could not be retired.")
			if FSStrictExists(RepairPath) && FSDeleteStrict(RepairPath) != 1
				throw Error("The owned acquired-read repair file could not be retired.")
			DirDelete(Dir, false)
			if DirExist(Dir)
				throw Error("The actual acquired-read directory deletion was not acknowledged.")
		}
		Receipt.deleted := true
	}
	State.active := false
	for Pair in [["timer", StopTimer], ["hash", RestoreHashOnce], ["port", RestorePortOnce],
			["journal", ResolveJournal], ["owner", RetireOwner], ["retention", RetainUnresolved], ["files", RetireFiles]]
		Attempt(Pair[1], Pair[2])
	return Receipt
}

_CTWP_TemporalReport(Receipt, Primary, Family) {
	SecondaryCount := Receipt.errors.Length
	loop SecondaryCount {
		Secondary := Receipt.errors[A_Index]
		try _TestPrint("# ERGOPTI_ACQUIRED_READ_SECONDARY phase=" . Secondary.phase . "; message=" . Secondary.failure.Message)
		catch as ReportingFailure
			Receipt.errors.Push({phase: "secondary_report", failure: ReportingFailure})
	}
	try _TestPrint("# ERGOPTI_ACQUIRED_READ_CLEANUP family=" . Family
		. ";primary_present=" . (Primary is Object ? 1 : 0) . ";secondary_count=" . Receipt.errors.Length
		. ";resolved=" . (Receipt.resolved ? 1 : 0) . ";owner_retired=" . (Receipt.ownerRetired ? 1 : 0)
		. ";files_deleted=" . (Receipt.deleted ? 1 : 0))
	catch as ReportingFailure
		Receipt.errors.Push({phase: "cleanup_report", failure: ReportingFailure})
	if !(Primary is Object) && Receipt.errors.Length
		throw Receipt.errors[1].failure
}

_CTWP_NativeReadTemporalCustody(Mode) {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Dir := _CTWP_NewDir("genuine-native-read-temporal-custody")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("old actual timed recovery source")
	; 8 MiB keeps the native read across a timer tick (1 MiB sometimes missed it)
	; at a quarter of the cost of the former 32 MiB source.
	Padding := "x"
	loop 23
		Padding .= Padding
	NewSource := _CTWP_SchemaSource("new actual timed recovery source") . "# " . Padding . "`n"
	Padding := ""
	Native := ConfigTransitionProductionPort(), HashCallback := Native["hash"]
	Digest := CryptoSha256(NewSource), Bundle := false
	State := {path: Path, pathKey: FileReadActivityKey(Path), port: Native, mode: Mode,
		active: false, observed: false, readerHandle: -1, timerCritical: -1, observerCalls: 0, failure: ""}
	State.observer := Mode == "port" ? ((*) => (State.observerCalls += 1, HashCallback))
		: ((*) => (State.observerCalls += 1, Digest))
	Timer := _CTWP_NativeReadCustodyTick.Bind(State)
	HadHashCall := Object.Prototype.HasOwnProp.Call(CryptoSha256, "Call")
	HashDescriptor := HadHashCall ? CryptoSha256.GetOwnPropDesc("Call") : false
	HadPortItem := Object.Prototype.HasOwnProp.Call(Native, "__Item")
	PortDescriptor := HadPortItem ? Native.GetOwnPropDesc("__Item") : false
	State.restoreErrors := [], Primary := false
	RestoreHash() {
		_CTWP_TemporalRestoreDescriptor(CryptoSha256, "Call", HadHashCall, HashDescriptor, State.observer, "Call")
	}
	RestorePort() {
		_CTWP_TemporalRestoreDescriptor(Native, "__Item", HadPortItem, PortDescriptor, State.observer, "Get")
	}
	Restore() {
		First := false
		try RestoreHash()
		catch as Failure
			First := Failure
		try RestorePort()
		catch as Failure {
			if First is Object
				State.restoreErrors.Push({phase: "body_port_restore", failure: Failure})
			else
				First := Failure
		}
		if First is Object
			throw First
	}
	try {
		AssertEqual(0, A_IsCritical, "the genuine read timer subject requires interruptible native IO")
		AssertEqual(8, Native.Count, "the original canonical native callback class is the subject")
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		Assert(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		WalPath := ConfigTransitionWalPath(PathsFile), BeforeWal := _CTWP_RawHex(WalPath)
		Facts := false
		; Eight genuine invocations bound timing variance. A missing acquired-read
		; timer interval is a failure, never a green skip or modeled observation.
		loop 8 {
			State.active := true
			SetTimer(Timer, 1)
			try Facts := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
			finally {
				State.active := false
				SetTimer(Timer, 0)
			}
			if State.observed
				break
		}
		Restore()
		AssertEqual("", State.failure, "actual timer observer failure is retained rather than swallowed")
		AssertTrue(State.observed, "an actual timer must run during the acquired native exact-read span")
		Assert(State.readerHandle != -1, "the timer observed an actual retained Win32 read handle")
		AssertEqual(0, State.timerCritical, "the original native read remains interruptible")
		AssertFalse(FileReadActivityBusy(Path), "actual native close retires the observed read activity")
		if Mode == "control" {
			Assert(Facts is Object, "the original unmodified acquired-read timer control issues genuine recovery facts")
			AssertEqual(OldSource, Facts.old.source)
			AssertEqual(NewSource, Facts.new.source)
		} else
			AssertFalse(Facts, "custody withdrawn during real IO cannot issue recovery facts")
		AssertEqual(0, State.observerCalls, "same-object ownership withdrawal must refuse before nested hash or port lookup dispatch")
		AssertEqual(BeforeWal, _CTWP_RawHex(WalPath))
		AssertTrue(FSUtf8ExactMatches(Path, NewSource), "the exact genuine target bytes remain unchanged")
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Repaired := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		Assert(Repaired is Object, "repair of original descriptors restores actual native recovery facts")
		AssertEqual(OldSource, Repaired.old.source)
		AssertEqual(NewSource, Repaired.new.source)
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertTrue(FSUtf8ExactMatches(Path, OldSource))
		AssertFalse(FSStrictExists(WalPath))
	} catch as Failure {
		Primary := Failure
		throw Failure
	} finally {
		ReleaseOwned() {
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		}
		Receipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
			State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
		_CTWP_TemporalReport(Receipt, Primary, "recovery:" . Mode)
	}
}

for Mode in ["control", "hash", "port"]
	Test("config transition native recovery: genuine acquired-read timer custody " . Mode,
		_CTWP_NativeReadTemporalCustody.Bind(Mode))


; A real AHK timer withdraws custody while the unchanged Win32 reader owns
; its acquired handle. No port, read function or dispatcher is replaced here.
_CTWP_GuardedReadCustodyTick(State) {
	if !State.active || State.observed || !FileReadActivityBusy(State.path)
		return
	try {
		Activity := _FileReadActivityState()
		for _, Reader in Activity.owners {
			if Reader.key != State.pathKey || Reader.handle == -1
				continue
			Identity := FSHandleSnapshot(Reader.handle)
			if !Identity.Get("ok", false)
				continue
			State.observed := true
			State.readerHandle := Reader.handle
			State.timerCritical := A_IsCritical
			if State.mode == "port"
				State.port.DefineProp("__Item", {Get: State.observer})
			else if State.callback is Object
				State.callback.DefineProp("Call", {Call: State.observer})
			return
		}
	} catch as Err {
		State.failure := Err.Message
		State.active := false
	}
}

_CTWP_GuardedReadTemporalCustody(Mode) {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Dir := _CTWP_NewDir("genuine-guarded-read-temporal-custody")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("old actual timed recovery source")
	; 8 MiB keeps the native read across a timer tick (1 MiB sometimes missed it)
	; at a quarter of the cost of the former 32 MiB source.
	Padding := "x"
	loop 23
		Padding .= Padding
	NewSource := _CTWP_SchemaSource("new actual timed recovery source") . "# " . Padding . "`n"
	Padding := ""
	Native := ConfigTransitionProductionPort(), HashCallback := Native["hash"]
	TargetCallback := false
	switch Mode {
	case "hash": TargetCallback := CryptoSha256
	case "exists": TargetCallback := FSStrictExists
	case "read_bounded": TargetCallback := FSReadUtf8ExactBounded
	case "write_create_durable": TargetCallback := FSWriteCreateDurable
	}
	Digest := CryptoSha256(NewSource), Bundle := false
	State := {path: Path, pathKey: FileReadActivityKey(Path), port: Native, mode: Mode, callback: TargetCallback,
		active: false, observed: false, readerHandle: -1, timerCritical: -1, observerCalls: 0, failure: ""}
	State.observer := Mode == "port" ? ((*) => (State.observerCalls += 1, HashCallback))
		: ((*) => (State.observerCalls += 1, Mode == "hash" ? Digest : 1))
	Timer := _CTWP_GuardedReadCustodyTick.Bind(State)
	HadHashCall := TargetCallback is Object && Object.Prototype.HasOwnProp.Call(TargetCallback, "Call")
	HashDescriptor := HadHashCall ? TargetCallback.GetOwnPropDesc("Call") : false
	HadPortItem := Object.Prototype.HasOwnProp.Call(Native, "__Item")
	PortDescriptor := HadPortItem ? Native.GetOwnPropDesc("__Item") : false
	State.restoreErrors := [], Primary := false
	RestoreHash() {
		_CTWP_TemporalRestoreDescriptor(TargetCallback, "Call", HadHashCall, HashDescriptor, State.observer, "Call")
	}
	RestorePort() {
		_CTWP_TemporalRestoreDescriptor(Native, "__Item", HadPortItem, PortDescriptor, State.observer, "Get")
	}
	Restore() {
		First := false
		try RestoreHash()
		catch as Failure
			First := Failure
		try RestorePort()
		catch as Failure {
			if First is Object
				State.restoreErrors.Push({phase: "body_port_restore", failure: Failure})
			else
				First := Failure
		}
		if First is Object
			throw First
	}
	try {
		AssertEqual(0, A_IsCritical, "the genuine read timer subject requires interruptible native IO")
		AssertEqual(8, Native.Count, "the original canonical native callback class is the subject")
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		Assert(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		WalPath := ConfigTransitionWalPath(PathsFile), BeforeWal := _CTWP_RawHex(WalPath)
		Captured := _ConfigTransitionGuardedProductionPort(PathsFile, Bundle, [], true)
		Assert(Captured is Object && Captured.port is Map)
		AssertEqual(8, Captured.port.Count, "the actual guarded adapter forwards the complete native callback class")
		ProbePath := Dir . "\foreign-timer-probe.txt"
		Facts := false
		; Eight genuine invocations bound timing variance. A missing acquired-read
		; timer interval is a failure, never a green skip or modeled observation.
		loop 8 {
			State.active := true
			SetTimer(Timer, 1)
			try Facts := _ConfigTransitionReadSnapshot(Captured.port, Path)
			finally {
				State.active := false
				SetTimer(Timer, 0)
			}
			if State.observed
				break
		}
		if Mode != "control" {
			if Mode == "write_create_durable"
				AssertThrows(() => Captured.port[Mode].Call(ProbePath, "foreign timer output"))
			else if Mode == "read_bounded"
				AssertThrows(() => Captured.port[Mode].Call(WalPath, CONFIG_TRANSITION_MAX_WAL_BYTES))
			else if Mode == "exists"
				AssertThrows(() => Captured.port[Mode].Call(Path))
			else if Mode == "hash"
				AssertThrows(() => Captured.port[Mode].Call(NewSource))
			else
				AssertThrows(() => Captured.port["hash"].Call(NewSource))
		}
		Restore()
		AssertEqual("", State.failure, "actual timer observer failure is retained rather than swallowed")
		AssertTrue(State.observed, "an actual timer must run during the acquired native exact-read span")
		Assert(State.readerHandle != -1, "the timer observed an actual retained Win32 read handle")
		AssertEqual(0, State.timerCritical, "the original native read remains interruptible")
		AssertFalse(FileReadActivityBusy(Path), "actual native close retires the observed read activity")
		if Mode == "control" {
			AssertTrue(ConfigTransitionResultIs(Facts, "snapshot"), "the original guarded acquired-read control returns a genuine native snapshot")
			AssertEqual(NewSource, Facts["snapshot"]["content"])
		} else
			AssertFalse(ConfigTransitionResultIs(Facts, "snapshot"), "custody withdrawn during real IO cannot acknowledge a guarded snapshot")
		AssertEqual(0, State.observerCalls, "same-object ownership withdrawal must refuse before nested hash or port lookup dispatch")
		AssertFalse(FSStrictExists(ProbePath), "a withdrawn callback never creates foreign native output")
		AssertEqual(BeforeWal, _CTWP_RawHex(WalPath))
		AssertTrue(FSUtf8ExactMatches(Path, NewSource), "the exact genuine target bytes remain unchanged")
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Repaired := _ConfigTransitionReadSnapshot(Captured.port, Path)
		AssertTrue(ConfigTransitionResultIs(Repaired, "snapshot"), "exact descriptor repair restores the same actual guarded adapter")
		AssertEqual(NewSource, Repaired["snapshot"]["content"])
		AssertEqual(1, Captured.port["exists"].Call(Path), "repaired existence uses its actual native producer")
		AssertEqual(Digest, Captured.port["hash"].Call(NewSource), "repaired hash keeps the actual canonical native digest")
		AssertEqual(FSReadUtf8Exact(WalPath), Captured.port["read_bounded"].Call(WalPath, CONFIG_TRANSITION_MAX_WAL_BYTES),
			"repaired bounded read returns actual native WAL bytes")
		RepairPath := Dir . "\owned-native-repair.txt"
		AssertEqual(1, Captured.port["write_create_durable"].Call(RepairPath, "owned native repair output"),
			"repaired creation retains the actual durable native receipt")
		AssertEqual("owned native repair output", FSReadUtf8Exact(RepairPath))
		AssertEqual(1, Captured.port["delete"].Call(RepairPath))
		AssertFalse(FSStrictExists(RepairPath))
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertTrue(FSUtf8ExactMatches(Path, OldSource))
		AssertFalse(FSStrictExists(WalPath))
	} catch as Failure {
		Primary := Failure
		throw Failure
	} finally {
		ReleaseOwned() {
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		}
		Receipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
			State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
		_CTWP_TemporalReport(Receipt, Primary, "guarded:" . Mode)
	}
}

for Mode in ["control", "hash", "port", "exists", "read_bounded", "write_create_durable"]
	Test("config transition guarded native adapter: genuine acquired-read timer custody " . Mode,
		_CTWP_GuardedReadTemporalCustody.Bind(Mode))

; A body error after a real committed journal must not destroy that journal
; before owned rollback, nor replace the exact original error object.
_CTWP_TemporalFailureRetirement(Mode) {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Dir := _CTWP_NewDir("temporal-cleanup-primary-" . Mode)
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("original temporal cleanup source")
	NewSource := _CTWP_SchemaSource("committed temporal cleanup source")
	ForeignSource := _CTWP_SchemaSource("independently written foreign cleanup source")
	Native := false, Bundle := false, HeldLock := false
	Primary := Error("exact owned body failure after actual journal commit")
	OuterPrimary := false, Caught := false, Completed := false
	Hits := {count: 0}, State := {active: false, restoreErrors: []}
	State.observer := (*) => (Hits.count += 1, 0)
	OtherObserver := (*) => (Hits.count += 1, 0)
	Timer := (*) => 0
	HadHashCall := Object.Prototype.HasOwnProp.Call(CryptoSha256, "Call")
	HashDescriptor := HadHashCall ? Object.Prototype.GetOwnPropDesc.Call(CryptoSha256, "Call") : false
	HadPortItem := false, PortDescriptor := false
	RestoreHash() {
		_CTWP_TemporalRestoreDescriptor(CryptoSha256, "Call", HadHashCall, HashDescriptor, State.observer, "Call")
	}
	RestorePort() {
		_CTWP_TemporalRestoreDescriptor(Native, "__Item", HadPortItem, PortDescriptor, State.observer, "Get")
	}
	ReleaseOwned() {
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
	CloseLock() {
		if HeldLock is File {
			HeldLock.Close()
			HeldLock := false
		}
	}
	RepairControlledDescriptor() {
		if Mode == "descriptor_refusal"
			_CTWP_TemporalRestoreDescriptor(CryptoSha256, "Call", HadHashCall, HashDescriptor, OtherObserver, "Call")
		else
			RestoreHash()
	}
	RepairControlledSource() {
		if Mode == "foreign_source" && FSStrictExists(Path) {
			if !FSUtf8ExactMatches(Path, ForeignSource)
				throw Error("The exact independently written foreign subject was superseded; retaining it.")
			AssertEqual(1, FSWriteDurable(Path, NewSource))
		}
	}
	try {
		Native := ConfigTransitionProductionPort()
		HadPortItem := Object.Prototype.HasOwnProp.Call(Native, "__Item")
		PortDescriptor := HadPortItem ? Object.Prototype.GetOwnPropDesc.Call(Native, "__Item") : false
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		Assert(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile, [ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		WalPath := ConfigTransitionWalPath(PathsFile)
		AssertTrue(FSStrictExists(WalPath))
		try {
			if Mode == "body" || Mode == "descriptor_refusal" {
				CryptoSha256.DefineProp("Call", {Call: State.observer})
				Native.DefineProp("__Item", {Get: State.observer})
				if Mode == "descriptor_refusal"
					CryptoSha256.DefineProp("Call", {Call: OtherObserver})
			} else if Mode == "locked_rollback" {
				HeldLock := FileOpen(Path, "r-rwd", "UTF-8")
				Assert(HeldLock is File, "the real non-sharing handle must be held before the native rollback attempt")
			} else if Mode == "foreign_source" {
				AssertEqual(1, FSWriteDurable(Path, ForeignSource))
				AssertTrue(FSUtf8ExactMatches(Path, ForeignSource))
			} else
				throw Error("Unknown genuine temporal cleanup regression subject.")
			throw Primary
		} catch as Failure {
			Caught := Failure
		} finally {
			FirstReceipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
				State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
			_CTWP_TemporalReport(FirstReceipt, Caught, "regression:" . Mode)
		}
		Assert(Caught == Primary, "real cleanup must preserve the exact original primary error object")
		AssertEqual(0, Hits.count, "genuine descriptor refusals and repair observe no foreign callback")
		AssertTrue(FirstReceipt.portRestored, "the original port descriptor is attempted independently of the hash repair")
		if Mode == "body" {
			AssertEqual(0, FirstReceipt.errors.Length)
			AssertTrue(FirstReceipt.resolved && FirstReceipt.ownerRetired && FirstReceipt.deleted)
			AssertFalse(FSStrictExists(WalPath))
			AssertFalse(DirExist(Dir))
			AssertFalse(_ConfigWriteTerminalIsActive())
		} else {
			AssertTrue(FirstReceipt.errors.Length > 0, "real refusal remains a visible secondary cleanup failure")
			AssertFalse(FirstReceipt.resolved)
			AssertFalse(FirstReceipt.ownerRetired)
			AssertFalse(FirstReceipt.deleted)
			AssertTrue(FSStrictExists(WalPath), "the actual unresolved journal survives the failed cleanup")
			AssertTrue(_ConfigWriteTerminalTryAcquire([], Bundle))
			Assert(ConfigTransitionRetainedBarrier() == Bundle, "cleanup retains only the genuine acquired native bundle")
			if Mode == "descriptor_refusal" {
				AssertFalse(FirstReceipt.hashRestored)
				Current := Object.Prototype.GetOwnPropDesc.Call(CryptoSha256, "Call")
				Assert(Current.Call == OtherObserver, "the different exact descriptor is left untouched until its own explicit repair")
			} else if Mode == "foreign_source"
				AssertTrue(FSUtf8ExactMatches(Path, ForeignSource), "owned rollback refuses to replace the independent foreign source")
			CloseLock()
			RepairControlledDescriptor()
			RepairControlledSource()
			State.restoreErrors := []
			Repaired := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
				State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
			_CTWP_TemporalReport(Repaired, Primary, "regression:" . Mode . ":repair")
			AssertEqual(0, Repaired.errors.Length)
			AssertTrue(Repaired.resolved && Repaired.ownerRetired && Repaired.deleted)
			AssertFalse(FSStrictExists(WalPath))
			AssertFalse(DirExist(Dir))
			AssertFalse(_ConfigWriteTerminalIsActive())
			Assert(ConfigTransitionRetainedBarrier() == PriorRetained)
			AssertEqual(0, Hits.count)
		}
		Completed := true
	} catch as Failure {
		OuterPrimary := Failure
		throw Failure
	} finally {
		if !Completed {
			PreCleanupErrors := []
			for Pair in [["close_lock", CloseLock], ["repair_descriptor", RepairControlledDescriptor],
					["restore_port", RestorePort], ["repair_source", RepairControlledSource]] {
				try Pair[2].Call()
				catch as Failure
					PreCleanupErrors.Push({phase: Pair[1], failure: Failure})
			}
			State.restoreErrors := PreCleanupErrors
			LastReceipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
				State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
			_CTWP_TemporalReport(LastReceipt, OuterPrimary, "regression:" . Mode . ":outer_failure")
		}
	}
}
for Mode in ["body", "descriptor_refusal", "locked_rollback", "foreign_source"]
	Test("config transition temporal cleanup: actual body primary and native retirement " . Mode,
		_CTWP_TemporalFailureRetirement.Bind(Mode))
