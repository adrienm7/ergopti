; tests/unit/test_config_transition_windows_port.ahk

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
#Include ../test_framework.ahk
#Include ../../adapters/file_system.ahk
#Include ../../adapters/crypto.ahk
#Include ../../infra/config_write_lease.ahk
#Include ../../infra/config_transition.ahk
#Include ../../infra/config_transition_runtime.ahk





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
