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

_BundleSkip_MatchingMarkerRequiresCompleteLiveTree() {
	global BUNDLE_VERSION
	PreviousVersion := BUNDLE_VERSION
	BUNDLE_VERSION := "bundle-skip-test-version"
	Root := _BundleSkip_TestRoot()
	DirCreate(Root)
	try {
		Assert(!_Bundle_LiveTreeCanSkip(Root, BUNDLE_VERSION),
			"a matching marker must not accept a live tree whose static directory is missing")
		DirCreate(Root . "\\static")
		Assert(_Bundle_LiveTreeCanSkip(Root, BUNDLE_VERSION),
			"a matching marker may skip extraction only after the live tree verifies")
		Assert(!_Bundle_LiveTreeCanSkip(Root, "another-version"),
			"a structurally complete live tree must still reject a stale marker")
		Assert(!_Bundle_LiveTreeCanSkip(Root, ""),
			"an absent marker must still force extraction")
	} finally {
		BUNDLE_VERSION := PreviousVersion
		try DirDelete(Root, true)
	}
}

Test("AHK-005: matching bundle marker skips only a verified live tree",
	_BundleSkip_MatchingMarkerRequiresCompleteLiveTree)
