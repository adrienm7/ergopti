; static/ergopti_plus/windows/tests/unit/test_updater_constants_single_source.ahk

; ==============================================================================
; MODULE: Updater Constants Single-Source Tests
; DESCRIPTION:
; Regression guard: asserts that the runtime values of the AHK
; updater constants agree with the canonical values committed in
; _shared/modules/updater/defaults.json. Tests check actual global values at
; run-time — NOT source text — so they catch both edit-without-update and
; silent-fallback-override bugs.
; ==============================================================================


; =================================================
; =================================================
; ======= 1/ GitHub owner/repo constants ==========
; =================================================
; =================================================

_UpdaterConst_GithubOwner() {
	AssertEqual("adrienm7", UPDATER_GH_OWNER, "UPDATER_GH_OWNER must equal the value in defaults.json")
}
Test("Updater constants: UPDATER_GH_OWNER matches defaults.json", _UpdaterConst_GithubOwner)

_UpdaterConst_GithubRepo() {
	AssertEqual("ergopti", UPDATER_GH_REPO, "UPDATER_GH_REPO must equal the value in defaults.json")
}
Test("Updater constants: UPDATER_GH_REPO matches defaults.json", _UpdaterConst_GithubRepo)


; ===================================================
; ===================================================
; ======= 2/ Timing constants ========================
; ===================================================
; ===================================================

_UpdaterConst_DefaultInterval() {
	; 86400 s = 24 h — canonical default from defaults.json timing.default_check_interval_sec
	AssertEqual(86400, UPDATER_DEFAULT_INTERVAL, "UPDATER_DEFAULT_INTERVAL must be 86400 (matches defaults.json)")
}
Test("Updater constants: UPDATER_DEFAULT_INTERVAL matches defaults.json", _UpdaterConst_DefaultInterval)
