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
