; static/ergopti_plus/windows/tests/unit/test_bundle_skip_validation.ahk

; ==============================================================================
; MODULE: Compiled-bundle skip validation regression
; DESCRIPTION:
; A matching version marker is only metadata. The live extraction tree must
; still satisfy the same structural verifier as a newly staged tree before a
; compiled boot may skip self-repair.
; ==============================================================================

#Requires AutoHotkey v2.0

_BundleSkip_TestRoot() {
	return A_Temp . "\\ergopti_bundle_skip_" . A_TickCount . "_" . Random(1000, 9999)
}

_BundleSkip_AssetFixture(Root) {
	DirCreate(Root . "\static")
	FileAppend("runtime", Root . "\static\asset.bin", "UTF-8-RAW")
	return [["static/asset.bin", 7, _CryptoSha256Cng(FileRead(Root . "\static\asset.bin", "RAW"))]]
}

_BundleSkip_MatchingMarkerRequiresCompleteLiveTree() {
	global BUNDLE_VERSION, BUNDLE_COMMIT
	PreviousVersion := BUNDLE_VERSION
	PreviousCommit := BUNDLE_COMMIT
	BUNDLE_VERSION := "bundle-skip-test-version"
	BUNDLE_COMMIT := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	Marker := _Bundle_BuildMarker()
	Root := _BundleSkip_TestRoot()
	DirCreate(Root)
	try {
		Assert(!_Bundle_LiveTreeCanSkip(Root, Marker),
			"a matching marker must not accept a live tree whose static directory is missing")
		DirCreate(Root . "\\static")
		Inventory := _BundleSkip_AssetFixture(Root)
		Assert(_Bundle_LiveTreeCanSkip(Root, Marker, Inventory),
			"a matching marker may skip extraction only after the live tree verifies")
		Assert(!_Bundle_LiveTreeCanSkip(Root, "another-version", Inventory),
			"a structurally complete live tree must still reject a stale marker")
		Assert(!_Bundle_LiveTreeCanSkip(Root, "", Inventory),
			"an absent marker must still force extraction")
	} finally {
		BUNDLE_VERSION := PreviousVersion
		BUNDLE_COMMIT := PreviousCommit
		try DirDelete(Root, true)
	}
}

Test("AHK-005: matching bundle marker skips only a verified live tree",
	_BundleSkip_MatchingMarkerRequiresCompleteLiveTree)

_BundleSkip_SameVersionDifferentCommitRepairsAssets() {
	global BUNDLE_VERSION, BUNDLE_COMMIT
	PreviousVersion := BUNDLE_VERSION
	PreviousCommit := BUNDLE_COMMIT
	Root := _BundleSkip_TestRoot()
	DirCreate(Root . "\\static")
	Inventory := _BundleSkip_AssetFixture(Root)
	try {
		BUNDLE_VERSION := "0.0.0-dev"
		BUNDLE_COMMIT := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		AssertTrue(_Bundle_WriteMarker(Root), "the first compiled build writes its marker")
		FirstMarker := _Bundle_ReadMarker(Root)
		AssertTrue(_Bundle_LiveTreeCanSkip(Root, FirstMarker, Inventory), "an identical build may reuse its assets")
		BUNDLE_COMMIT := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		AssertFalse(_Bundle_LiveTreeCanSkip(Root, FirstMarker, Inventory),
			"another commit with the same development version must re-extract its own assets")
		AssertTrue(_Bundle_WriteMarker(Root), "the replacement build publishes its own identity")
		SecondMarker := _Bundle_ReadMarker(Root)
		AssertFalse(FirstMarker == SecondMarker, "persisted identity distinguishes same-version builds")
		AssertTrue(_Bundle_LiveTreeCanSkip(Root, SecondMarker, Inventory), "the repaired build may use the fast path")
		AssertFalse(_Bundle_LiveTreeCanSkip(Root, BUNDLE_VERSION, Inventory), "a legacy version-only marker forces repair")
		BUNDLE_COMMIT := "__BUNDLE_COMMIT__"
		AssertTrue(_Bundle_WriteMarker(Root), "an unstamped local compile can still extract assets")
		AssertFalse(_Bundle_LiveTreeCanSkip(Root, _Bundle_ReadMarker(Root), Inventory),
			"an unstamped build cannot prove asset identity for a future fast path")
	} finally {
		BUNDLE_VERSION := PreviousVersion
		BUNDLE_COMMIT := PreviousCommit
		try DirDelete(Root, true)
	}
}
Test("compiled bundle distinguishes commits sharing a version (bundle-build-identity)",
	_BundleSkip_SameVersionDifferentCommitRepairsAssets)

_BundleSkip_EmptyStaticIsNotRuntimeAssets() {
	Root := _BundleSkip_TestRoot()
	DirCreate(Root . "\static")
	try AssertFalse(_Bundle_VerifyStaging(Root),
		"bundle-asset-integrity: an empty static directory cannot prove runtime assets")
	finally DirDelete(Root, true)
}
Test("compiled bundle rejects a directory without its runtime assets (bundle-asset-integrity)",
	_BundleSkip_EmptyStaticIsNotRuntimeAssets)

_BundleSkip_IntegrityRejectsAlteredBytesAndInvalidInventory() {
	Root := _BundleSkip_TestRoot()
	Inventory := _BundleSkip_AssetFixture(Root)
	Asset := Root . "\static\asset.bin"
	try {
		AssertTrue(_Bundle_VerifyStaging(Root, Inventory), "real matching bytes must verify")
		FileAppend("generated cache", Root . "\static\cache.tsv", "UTF-8-RAW")
		AssertTrue(_Bundle_VerifyStaging(Root, Inventory), "extra generated caches are permitted")
		for Invalid in [[], Map(), [[]], [["../asset.bin", 7, Inventory[1][3]]],
				[["static/asset.bin", "7", Inventory[1][3]]],
				[["static/asset.bin", -1, Inventory[1][3]]],
				[["static/asset.bin", 7, "not a digest"]],
				[Inventory[1], Inventory[1]]] {
			AssertFalse(_Bundle_VerifyStaging(Root, Invalid), "malformed inventory must never prove completeness")
		}
		FileDelete(Asset)
		AssertFalse(_Bundle_VerifyStaging(Root, Inventory), "a deleted shipped asset forces repair")
		FileAppend("assets!", Asset, "UTF-8-RAW")
		AssertEqual(Inventory[1][2], FileGetSize(Asset), "the mutation intentionally preserves length")
		AssertFalse(_Bundle_VerifyStaging(Root, Inventory), "matching size is not matching content")
		FileDelete(Asset)
		FileAppend("run", Asset, "UTF-8-RAW")
		AssertFalse(_Bundle_VerifyStaging(Root, Inventory), "truncated bytes force repair")
		FileDelete(Asset)
		DirCreate(Asset)
		AssertFalse(_Bundle_VerifyStaging(Root, Inventory), "a directory cannot replace a readable asset")
	} finally DirDelete(Root, true)
}
Test("compiled bundle verifies exact asset bytes and inventory shape (bundle-asset-integrity)",
	_BundleSkip_IntegrityRejectsAlteredBytesAndInvalidInventory)

; The fixtures reserve their own parent before any recursive cleanup. They call
; real allocation/restoration owners without extracting or starting a driver.
_BundleAcquire_Fixture() {
	static Serial := 0
	Serial += 1
	Root := A_Temp . "\bundle_acquisition_" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_" . A_TickCount . "_" . Serial
	AssertTrue(DllCall("Kernel32\CreateDirectoryW", "WStr", Root, "Ptr", 0, "Int"),
		"the fixture must acquire an exclusive parent before cleanup")
	return Root
}

_BundleAcquire_Fresh() {
	Root := _BundleAcquire_Fixture()
	try {
		Workspace := _Bundle_AcquireWorkspace(Root . "\bundle", 147, 23)
		AssertTrue(Workspace["owned"], "native successful creation grants ownership")
		AssertEqual(Root . "\bundle.workspace-23-147", Workspace["root"], "the clock is sampled once")
		AssertTrue(DirExist(Workspace["staging"]), "the acquired workspace has a fresh staging directory")
		AssertEqual(Workspace["root"] . "\archive.zip", Workspace["zip"], "the archive stays inside the acquired root")
		AssertEqual(Workspace["root"] . "\rollback", Workspace["rollback"], "recovery stays on the bundle volume")
		FileAppend("tiny archive", Workspace["zip"], "UTF-8-RAW")
		_Bundle_CleanupWorkspace(Workspace)
		AssertFalse(DirExist(Workspace["root"]), "cleanup retires the exact owned root")
		AssertFalse(Workspace["owned"], "successful cleanup revokes ownership")
		AssertThrows(() => _Bundle_CleanupWorkspace(Workspace), "a duplicate cleanup must refuse")
	} finally DirDelete(Root, true)
}
Test("bundle: fresh workspace acquires and retires exact ownership (bundle-acquisition)", _BundleAcquire_Fresh)

_BundleAcquire_Defaults() {
	Root := _BundleAcquire_Fixture()
	try {
		Before := A_TickCount
		Workspace := _Bundle_AcquireWorkspace(Root . "\bundle")
		After := A_TickCount
		Prefix := Root . "\bundle.workspace-" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "-"
		AssertEqual(Prefix, SubStr(Workspace["root"], 1, StrLen(Prefix)), "ordinary allocation uses the current native process")
		ActualTick := Integer(SubStr(Workspace["root"], StrLen(Prefix) + 1))
		AssertTrue(Before <= ActualTick && ActualTick <= After,
			"ordinary allocation samples the native monotonic clock within the observed interval")
		_Bundle_CleanupWorkspace(Workspace)
	} finally DirDelete(Root, true)
}
Test("bundle: ordinary allocation retains native identity defaults (bundle-acquisition)", _BundleAcquire_Defaults)

_BundleAcquire_Collision(Kind) {
	Root := _BundleAcquire_Fixture()
	Existing := Root . "\bundle.workspace-23-147"
	try {
		if Kind == "root-file" {
			FileAppend("foreign file", Existing, "UTF-8-RAW")
			Sentinel := Existing
		} else {
			DirCreate(Existing . "\" . Kind)
			Sentinel := Kind == "archive" ? Existing . "\archive.zip" : Existing . "\" . Kind . "\sentinel.bin"
			FileAppend("foreign file", Sentinel, "UTF-8-RAW")
		}
		Refused := false
		try _Bundle_AcquireWorkspace(Root . "\bundle", 147, 23)
		catch
			Refused := true
		AssertTrue(Refused, "existing paths must refuse acquisition")
		AssertEqual("foreign file", FileRead(Sentinel, "UTF-8"), "refusal preserves every preexisting byte")
	} finally DirDelete(Root, true)
}
for Kind in ["staging", "archive", "rollback", "root-file"]
	Test("bundle: collision preserves foreign " . Kind . " (bundle-acquisition)", _BundleAcquire_Collision.Bind(Kind))

_BundleAcquire_MissingParent() {
	Root := _BundleAcquire_Fixture()
	try {
		AssertThrows(() => _Bundle_AcquireWorkspace(Root . "\missing\bundle", 147, 23),
			"native path failure must not produce a successful acquisition")
		AssertFalse(DirExist(Root . "\missing"), "refused acquisition must not create or adopt a parent")
	} finally DirDelete(Root, true)
}
Test("bundle: native acquisition failure creates no ownership (bundle-acquisition)", _BundleAcquire_MissingParent)

_BundleAcquire_NoAuthority() {
	Root := _BundleAcquire_Fixture()
	try {
		FileAppend("foreign file", Root . "\sentinel.bin", "UTF-8-RAW")
		Unowned := Map("root", Root, "rollback", Root . "\rollback", "owned", false)
		AssertThrows(() => _Bundle_CleanupWorkspace(Unowned), "an unowned path cannot be cleaned")
		AssertThrows(() => _Bundle_RestoreRollback(Unowned, Root . "\bundle"), "an unowned path cannot be restored")
		AssertEqual("foreign file", FileRead(Root . "\sentinel.bin", "UTF-8"), "refusal leaves foreign bytes intact")
	} finally {
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("bundle: cleanup and restoration reject absent authority (bundle-acquisition)", _BundleAcquire_NoAuthority)

_BundleAcquire_Recovery(RefuseRestore) {
	Root := _BundleAcquire_Fixture()
	try {
		BundleDir := Root . "\bundle"
		Workspace := _Bundle_AcquireWorkspace(BundleDir, 147, 23)
		DirCreate(Workspace["rollback"])
		FileAppend("known good", Workspace["rollback"] . "\asset.bin", "UTF-8-RAW")
		AssertThrows(() => _Bundle_CleanupWorkspace(Workspace), "pending recovery refuses cleanup")
		AssertTrue(Workspace["owned"], "cleanup refusal retains authority")
		if RefuseRestore {
			FileAppend("blocking target", BundleDir, "UTF-8-RAW")
			Message := ""
			try _Bundle_RestoreRollback(Workspace, BundleDir)
			catch as Err
				Message := Err.Message
			AssertContains(Message, Workspace["rollback"], "restoration failure exposes the retained recovery path")
			AssertEqual("known good", FileRead(Workspace["rollback"] . "\asset.bin", "UTF-8"), "failed restore retains exact recovery bytes")
			AssertEqual("blocking target", FileRead(BundleDir, "UTF-8"), "failed restore does not overwrite the target")
			AssertTrue(Workspace["owned"], "restoration refusal retains cleanup authority")
		} else {
			_Bundle_RestoreRollback(Workspace, BundleDir)
			AssertEqual("known good", FileRead(BundleDir . "\asset.bin", "UTF-8"), "successful restoration preserves exact bytes")
			_Bundle_CleanupWorkspace(Workspace)
			AssertFalse(DirExist(Workspace["root"]), "restored workspace may retire")
			AssertEqual("known good", FileRead(BundleDir . "\asset.bin", "UTF-8"), "cleanup must not erase the restored live tree")
		}
	} finally DirDelete(Root, true)
}
Test("bundle: pending recovery refuses cleanup and restores native bytes (bundle-acquisition)", _BundleAcquire_Recovery.Bind(false))
Test("bundle: refused native restore retains known-good recovery (bundle-acquisition)", _BundleAcquire_Recovery.Bind(true))

_BundleAcquire_Committed() {
	Root := _BundleAcquire_Fixture()
	try {
		Workspace := _Bundle_AcquireWorkspace(Root . "\bundle", 147, 23)
		DirCreate(Workspace["rollback"])
		FileAppend("old", Workspace["rollback"] . "\asset.bin", "UTF-8-RAW")
		DirCreate(Root . "\foreign")
		FileAppend("keep", Root . "\foreign\asset.bin", "UTF-8-RAW")
		_Bundle_CleanupWorkspace(Workspace, true)
		AssertFalse(DirExist(Workspace["root"]), "committed cleanup may retire its prior owned recovery")
		AssertEqual("keep", FileRead(Root . "\foreign\asset.bin", "UTF-8"), "cleanup cannot retire a sibling foreign tree")
	} finally DirDelete(Root, true)
}
Test("bundle: committed cleanup retires only its acquired workspace (bundle-acquisition)", _BundleAcquire_Committed)

_BundleAcquire_CleanupRefusal() {
	Root := _BundleAcquire_Fixture()
	Handle := 0
	try {
		Workspace := _Bundle_AcquireWorkspace(Root . "\bundle", 147, 23)
		FileAppend("locked", Workspace["zip"], "UTF-8-RAW")
		Handle := DllCall("Kernel32\CreateFileW", "WStr", Workspace["zip"], "UInt", 0x80000000,
			"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Handle != -1 && Handle != 0, "the fixture must retain a real nonsharing file handle")
		AssertThrows(() => _Bundle_CleanupWorkspace(Workspace), "native cleanup refusal cannot report success")
		AssertTrue(Workspace["owned"], "refused cleanup retains authority for retry")
		AssertTrue(FileExist(Workspace["zip"]), "the locked archive remains under retained ownership")
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int"), "the fixture releases only its exact file handle")
		Handle := 0
		_Bundle_CleanupWorkspace(Workspace)
		AssertFalse(Workspace["owned"], "a real successful retry retires ownership")
	} finally {
		if Handle && Handle != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Handle)
		DirDelete(Root, true)
	}
}
Test("bundle: native cleanup refusal retains authority until retry (bundle-acquisition)", _BundleAcquire_CleanupRefusal)

_BundleAcquire_ActualConnection() {
	Body := _DriverFuncBody("Bundle_Init")
	AssertTrue(Body != "", "the compiled bootstrap owner must exist")
	Code := _DriverMaskNonCode(&Body)
	AcquireAt := InStr(Code, "Workspace := _Bundle_AcquireWorkspace(BundleDir)")
	InstallAt := InStr(Body, 'FileInstall("build\static_bundle.zip", TmpZip, 0)')
	CommitAt := InStr(Code, "DirMove(StagingDir, BundleDir, 0)")
	CleanupAt := InStr(Code, "_Bundle_CleanupWorkspace(Workspace, true)")
	AssertTrue(AcquireAt > 0 && InstallAt > AcquireAt, "actual bootstrap must acquire before installing its literal archive without overwrite")
	AssertEqual("FileInstall(", SubStr(Code, InstallAt, 12), "the literal archive installation must be executable code")
	for Assignment in ['StagingDir := Workspace["staging"]', 'TmpZip := Workspace["zip"]', 'RollbackDir := Workspace["rollback"]'] {
		At := InStr(Body, Assignment)
		AssertTrue(At > AcquireAt && At < InstallAt, "every actual transport path must derive from the acquired workspace")
		PrefixLength := InStr(Assignment, "[")
		AssertEqual(SubStr(Assignment, 1, PrefixLength), SubStr(Code, At, PrefixLength),
			"the owned-path assignment must be executable code")
	}
	AssertTrue(CommitAt > InstallAt && CleanupAt > CommitAt, "committed cleanup must follow the actual publication attempt")
	AssertTrue(InStr(Code, "_Bundle_RestoreRollback(Workspace, BundleDir)") > CommitAt, "failed publication must reach the tested recovery owner")
	AssertEqual(0, InStr(Code, "DirDelete("), "bootstrap may clean only through acquired workspace authority")
}
Test("bundle: actual bootstrap delegates acquisition and cleanup authority (bundle-acquisition)", _BundleAcquire_ActualConnection)

; Native adapter failures must retain their original error and never grant ownership.
_BundleAdapter_ExclusiveFailure(Kind, ExpectedError) {
	Root := _BundleAcquire_Fixture()
	Target := Root . "\target"
	try {
		if Kind == "directory"
			DirCreate(Target)
		else if Kind == "file"
			FileAppend("foreign adapter bytes", Target, "UTF-8-RAW")
		else
			Target := Root . "\missing\target"
		Caught := 0
		try FSCreateDirectoryExclusiveStrict(Target)
		catch as Err
			Caught := Err
		AssertTrue(Caught is OSError, "native creation failure must be an OSError")
		AssertEqual(ExpectedError, Caught.Number, "native error is captured before diagnostic construction")
		if Kind == "file"
			AssertEqual("foreign adapter bytes", FileRead(Target, "UTF-8"), "existing file bytes are preserved")
		else if Kind == "directory"
			AssertTrue(DirExist(Target), "existing directory remains available to its original owner")
		else
			AssertFalse(DirExist(Root . "\missing"), "native failure must not create a missing parent")
	} finally DirDelete(Root, true)
}
Test("bundle: exclusive adapter retains directory collision error (bundle-adapter)", _BundleAdapter_ExclusiveFailure.Bind("directory", 183))
Test("bundle: exclusive adapter retains file collision error (bundle-adapter)", _BundleAdapter_ExclusiveFailure.Bind("file", 183))
Test("bundle: exclusive adapter retains missing-parent error (bundle-adapter)", _BundleAdapter_ExclusiveFailure.Bind("missing", 3))

_BundleAdapter_NativeSuccess() {
	Root := _BundleAcquire_Fixture()
	try {
		Target := Root . "\fresh"
		AssertTrue(FSCreateDirectoryExclusiveStrict(Target), "successful native creation returns explicit ownership")
		AssertTrue(DirExist(Target), "the native directory exists")
		AssertEqual(DllCall("kernel32\GetCurrentProcessId", "UInt"), PLC_CurrentProcessIdStrict(),
			"strict process identity is the actual current native process")
		AssertThrows(() => FSCreateDirectoryExclusiveStrict(""), "an empty path is refused")
		AssertThrows(() => FSCreateDirectoryExclusiveStrict(23), "a non-string path is refused")
	} finally DirDelete(Root, true)
}
Test("bundle: native adapters grant only successful exclusive ownership (bundle-adapter)", _BundleAdapter_NativeSuccess)
