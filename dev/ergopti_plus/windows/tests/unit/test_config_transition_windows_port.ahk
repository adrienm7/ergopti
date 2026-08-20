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
	Body := _DriverFuncBody("CryptoSha256")
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
	OldContent := Chr(0xFEFF) . "[old]`nvalue = 1`n"
	Bundle := false
	try {
		AssertTrue(FSWriteCreateDurable(Target, OldContent) == 1)
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
			[ConfigTransitionPresentTarget(Target, "[new]`nvalue = 2`n")],
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
		V1 := "[existing]`nvalue = 1`n"
		V2 := '[existing]`nvalue = 2`nunrelated = "keep"`n'
		AssertTrue(FSWriteCreateDurable(Target, V1) == 1)
		Expected := Map("present", 1, "hash", CryptoSha256(V1))
		AssertTrue(FSDeleteStrict(Target) == 1)
		AssertTrue(FSWriteCreateDurable(Target, V2) == 1)
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Target])
		AssertTrue(Bundle is Object)
		Result := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Target, "candidate-from-v1",
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
