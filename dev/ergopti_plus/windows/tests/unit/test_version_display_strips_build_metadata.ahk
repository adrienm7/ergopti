; tests/unit/test_version_display_strips_build_metadata.ahk

; ==============================================================================
; MODULE: Version Display Strips Build Metadata
; DESCRIPTION:
; A build stamped "3.1.0+abc1234" showed that whole string in the About row and
; in the diagnostics, so the version read differently from the release it came
; from. Semver build metadata is not part of a release's identity (the commit
; has its own diagnostics row), so the single owner, Updater_CurrentVersion via
; Updater_DisplayVersion, drops it, and every display surface reads that owner
; instead of BUNDLE_VERSION.
; ==============================================================================

#Requires AutoHotkey v2.0

_VDSB_OwnerStripsBuildMetadata() {
	AssertEqual("3.1.0", Updater_DisplayVersion("3.1.0+abc1234", false))
	AssertEqual("3.1.0-dev.4", Updater_DisplayVersion("3.1.0-dev.4+ci.77.f58d157", false))
	AssertEqual("3.1.0", Updater_DisplayVersion("3.1.0", false), "a plain version is unchanged")
	AssertEqual("local", Updater_DisplayVersion("3.1.0+abc", true), "a source run reads local")
	AssertEqual("local", Updater_DisplayVersion("__BUNDLE_VERSION__", false))
	AssertEqual("local", Updater_DisplayVersion("", false))
	AssertEqual("local", Updater_DisplayVersion("+abc", false), "metadata alone is no version")
	Body := _DriverFuncBody("Updater_CurrentVersion")
	Assert(Body != "", "Updater_CurrentVersion must be readable")
	Assert(InStr(Body, "Updater_DisplayVersion(BUNDLE_VERSION") > 0,
		"the current version must come from the stripping owner")
}

_VDSB_SurfacesReadTheOwner() {
	for _, Name in ["_MI_AboutUpdateRows", "HealthCheck_Run"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must be readable")
		Assert(InStr(Body, "Updater_CurrentVersion()") > 0,
			Name . " must display the version through Updater_CurrentVersion")
		AssertEqual(0, InStr(Body, "BUNDLE_VERSION"),
			Name . " must never display the raw stamp, which carries +build metadata")
	}
	Snapshot := HealthCheck_Run()
	AssertEqual(Updater_CurrentVersion(), Snapshot["version"],
		"the diagnostics version is the owner's")
	Assert(InStr(HealthCheck_FormatPlain(Snapshot), "Version         : " . Updater_CurrentVersion() . "`r`n") > 0,
		"the copied diagnostics must show exactly the owner's version")
}

Test("version display: build metadata is stripped at the owner (version-display-build-metadata)",
	_VDSB_OwnerStripsBuildMetadata)
Test("version display: About row and diagnostics read the owner (version-display-build-metadata)",
	_VDSB_SurfacesReadTheOwner)
