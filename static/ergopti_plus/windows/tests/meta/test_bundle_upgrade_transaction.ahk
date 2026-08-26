; tests/meta/test_bundle_upgrade_transaction.ahk
#Requires AutoHotkey v2.0

_BUT_StagesBeforeReplacingLiveBundle() {
	Body := _DriverFuncBody("Bundle_Init")
	StagePos := InStr(Body, "StagingDir := BundleDir")
	UnzipPos := InStr(Body, "_Bundle_Unzip(TmpZip, StagingDir)")
	VerifyPos := InStr(Body, "_Bundle_VerifyStaging(StagingDir)")
	PreservePos := InStr(Body, "DirMove(BundleDir, RollbackDir")
	CommitPos := InStr(Body, "DirMove(StagingDir, BundleDir")
	Assert(StagePos > 0 and UnzipPos > StagePos and VerifyPos > UnzipPos and PreservePos > VerifyPos and CommitPos > PreservePos,
		"Bundle_Init must stage, verify, preserve the live bundle, then commit the replacement in that order")
	Assert(InStr(Body, "DirDelete(BundleDir, true)") = 0,
		"Bundle_Init must never delete the live bundle before staged replacement verification")
	Assert(InStr(Body, "DirMove(RollbackDir, BundleDir") > CommitPos,
		"a failed staging commit must restore the preserved live bundle")
}
Test("bundle: upgrade stages and rolls back before replacing live runtime (bundle-upgrade-transaction)", _BUT_StagesBeforeReplacingLiveBundle)

_BUT_MatchingMarkerValidatesLiveTree() {
	Body := _DriverFuncBody("Bundle_Init")
	Assert(Body != "", "Bundle_Init must exist")
	Assert(InStr(Body, "_Bundle_LiveTreeCanSkip(BundleDir, Existing)") > 0,
		"the marker fast path must delegate to the behaviourally tested live-tree verifier")
	Assert(InStr(Body, 'Existing != "" and Existing == BUNDLE_VERSION) {') == 0,
		"marker equality alone must never return early from compiled-bundle bootstrap")
}
Test("AHK-005: Bundle_Init verifies the live tree before its marker fast path",
	_BUT_MatchingMarkerValidatesLiveTree)
