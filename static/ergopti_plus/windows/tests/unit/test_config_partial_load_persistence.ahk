; tests/unit/test_config_partial_load_persistence.ahk

; ==============================================================================
; MODULE: Partial Configuration Load Persistence Tests
; DESCRIPTION:
; Rejected preferences must survive a full-save request after boot. Valid
; neighboring preferences still apply without authorizing default replacement.
; ==============================================================================

#Requires AutoHotkey v2.0

_CPL_FullSavePreservesRejectedPreference(Invalid := true, Literal := "0") {
	global _ConfigBootRejectedOverrides
	OldRejected := _ConfigBootRejectedOverrides
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	Path := _CTU_NewPath()
	Original := "[shortcuts]`nscreen = " . (Invalid ? Literal : "false")
		. "`n[layout]`nergopti_base = false`n"
	Target := ManifestBuildFeaturesMap()
	DefaultScreen := Target["shortcuts"]["screen"]
	Target["layout"]["ergopti_base"] := true
	Writes := []
	Logs := []
	Writer := (FilePath, Updates) =>
		(Writes.Push(Updates), TOML_BatchWrite(FilePath, Updates))
	Collect := () => [{ Section: "shortcuts", Key: "screen",
		Value: Target["shortcuts"]["screen"] }]
	try {
		LoggerSetTestSink((Line) => Logs.Push(Line))
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWrite(Path, Original))
		AssertEqual(Invalid ? 1 : 2, ApplyBootConfigToml(Target, Path))
		PartialLogged := false
		SuccessLogged := false
		for Line in Logs {
			PartialLogged := PartialLogged || InStr(Line, "v2 config only partially applied")
			SuccessLogged := SuccessLogged || InStr(Line, "v2 config applied (")
		}
		AssertEqual(Invalid, !!PartialLogged)
		AssertEqual(!Invalid, !!SuccessLogged,
			"a partial load must not claim a successful configuration lifecycle")
		AssertEqual(Invalid ? DefaultScreen : false, Target["shortcuts"]["screen"])
		AssertFalse(Target["layout"]["ergopti_base"])
		AssertEqual(Invalid ? CONFIG_SAVE_FAILED : CONFIG_SAVE_OK,
			SaveFullConfig(Writer, (*) => true,
			true, 0, Collect), "partial boot state must not replace rejected preferences")
		AssertEqual(Invalid ? 0 : 1, Writes.Length)
		if Invalid
			AssertEqual(Original, FSRead(Path))
		else
			AssertFalse(TOML_ParseFreshFile(Path)["shortcuts"]["screen"])
	} finally {
		LoggerClearTestSink()
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		FSDelete(Path)
	}
}
Test("config: partial load cannot overwrite rejected preferences (config-partial-load-persistence)",
	_CPL_FullSavePreservesRejectedPreference)
Test("config: complete load still permits full persistence (config-partial-load-positive)",
	_CPL_FullSavePreservesRejectedPreference.Bind(false))
Test("config: empty known preference blocks full persistence (config-partial-load-empty)",
	_CPL_FullSavePreservesRejectedPreference.Bind(true, ""))

_CPL_LocalDiagnosticsCannotChangeBootAuthority() {
	global _ConfigBootRejectedOverrides
	OldRejected := _ConfigBootRejectedOverrides
	Path := _CTU_NewPath()
	ValidPath := Path . ".valid.toml"
	try {
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWrite(Path, "[shortcuts]`nscreen = 0`n"))
		AssertEqual(0, ApplyConfigToml(ManifestBuildFeaturesMap(), Path, &Rejected))
		AssertEqual(1, Rejected)
		AssertEqual(0, _ConfigBootRejectedOverrides,
			"a local candidate load must not poison boot authority")
		ApplyBootConfigToml(ManifestBuildFeaturesMap(), Path)
		AssertEqual(1, _ConfigBootRejectedOverrides)
		AssertTrue(FSWrite(ValidPath, "[shortcuts]`nscreen = false`n[ahk.layout]`nergopti_base = 0`n"))
		AssertEqual(1, ApplyConfigToml(ManifestBuildFeaturesMap(), ValidPath, &Rejected))
		AssertEqual(0, Rejected, "each diagnostic starts fresh; obsolete silos do not block migration")
		AssertEqual(1, _ConfigBootRejectedOverrides,
			"a later valid read must not bless the already incomplete live tree")
	} finally {
		_ConfigBootRejectedOverrides := OldRejected
		FSDelete(Path)
		FSDelete(ValidPath)
	}
}
Test("config: local load diagnostics cannot change boot authority (config-partial-load-diagnostics)",
	_CPL_LocalDiagnosticsCannotChangeBootAuthority)
