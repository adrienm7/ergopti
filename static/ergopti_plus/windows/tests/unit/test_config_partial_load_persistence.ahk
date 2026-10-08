; tests/unit/test_config_partial_load_persistence.ahk

; ==============================================================================
; MODULE: Partial Configuration Load Persistence Tests
; DESCRIPTION:
; A value boot ignores as outdated configuration must survive a full-save
; request after boot without blocking it: it is a WARNING the cleanup offers,
; never an ERROR, a partial load or a refused save. Valid neighboring
; preferences still apply.
; ==============================================================================

#Requires AutoHotkey v2.0

; The outdated exemplar is an out-of-domain integer: bare 0/1 for a boolean key
; is the legacy writer spelling and migrates with user intent instead (see the
; llm-toggle-deadlock test), so it can no longer play the outdated role here.
_CPL_FullSavePreservesRejectedPreference(Invalid := true, Literal := "2") {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	OldRejected := _ConfigBootRejectedOverrides
	OldOutdated := _ConfigBootOutdatedEntries
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
		_ConfigBootOutdatedEntries := Map()
		AssertTrue(FSWrite(Path, Original))
		AssertEqual(Invalid ? 1 : 2, ApplyBootConfigToml(Target, Path))
		Errors := 0
		ErrorNamespaces := "", ErrorNamespaceCount := 0
		PartialLogged := false
		SuccessLogged := false
		OutdatedNamed := false
		for Line in Logs {
			Errors += InStr(Line, "[ERROR]", true) ? 1 : 0
			if InStr(Line, "[ERROR]", true) && ErrorNamespaceCount < 8 {
				Namespace := RegExMatch(Line, "\[ERROR\] \[([A-Za-z][A-Za-z0-9_.:-]{0,47})\]", &NamespaceMatch)
					? NamespaceMatch[1] : "unclassified"
				ErrorNamespaces .= (ErrorNamespaceCount ? ", " : "") . Namespace
				ErrorNamespaceCount += 1
			}
			PartialLogged := PartialLogged || InStr(Line, "v2 config only partially applied")
			SuccessLogged := SuccessLogged || InStr(Line, "v2 config applied (")
			OutdatedNamed := OutdatedNamed || (InStr(Line, "[WARNING]", true)
				&& InStr(Line, "outdated configuration value(s)") && InStr(Line, "[shortcuts].screen"))
		}
		AssertEqual(0, Errors, "an outdated value is never an ERROR (config-outdated-windows); "
			. "captured error namespaces: " . ErrorNamespaces)
		AssertFalse(PartialLogged, "an outdated value is not a partial load")
		AssertTrue(SuccessLogged, "the load of every other value completes")
		AssertEqual(Invalid, !!OutdatedNamed, "the outdated value is named in one warning")
		AssertEqual(0, _ConfigBootRejectedOverrides, "an outdated value never blocks full saves")
		AssertEqual(Invalid ? DefaultScreen : false, Target["shortcuts"]["screen"])
		AssertFalse(Target["layout"]["ergopti_base"])
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(Writer, (*) => true,
			true, 0, Collect), "an outdated value must not refuse the full save")
		AssertEqual(1, Writes.Length)
		if Invalid {
			AssertEqual(0, Writes[1].Length,
				"the neutral value boot kept must not erase the outdated entry")
			AssertEqual(Original, FSRead(Path), "the cleanup still finds the outdated entry")
		} else
			AssertFalse(TOML_ParseFreshFile(Path)["shortcuts"]["screen"])
	} finally {
		LoggerClearTestSink()
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigBootOutdatedEntries := OldOutdated
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		FSDelete(Path)
	}
}
Test("config: an outdated value neither blocks nor erases a full save (config-partial-load-persistence)",
	_CPL_FullSavePreservesRejectedPreference)
Test("config: complete load still permits full persistence (config-partial-load-positive)",
	_CPL_FullSavePreservesRejectedPreference.Bind(false))
Test("config: an empty known preference is outdated, not a blocked save (config-partial-load-empty)",
	_CPL_FullSavePreservesRejectedPreference.Bind(true, ""))

_CPL_LocalDiagnosticsCannotChangeBootAuthority() {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	OldRejected := _ConfigBootRejectedOverrides
	OldOutdated := _ConfigBootOutdatedEntries
	Path := _CTU_NewPath()
	ValidPath := Path . ".valid.toml"
	try {
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		AssertTrue(FSWrite(Path, "[shortcuts]`nscreen = 2`n"))
		AssertEqual(0, ApplyConfigToml(ManifestBuildFeaturesMap(), Path, &Rejected, , &Outdated))
		AssertEqual(0, Rejected, "an outdated value is not a rejected override")
		AssertTrue(Outdated.Has("shortcuts`nscreen"), "the load reports the outdated entry")
		AssertEqual(0, _ConfigBootOutdatedEntries.Count,
			"a local candidate load must not change boot authority")
		ApplyBootConfigToml(ManifestBuildFeaturesMap(), Path)
		AssertTrue(_ConfigBootOutdatedEntries.Has("shortcuts`nscreen"))
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertTrue(FSWrite(ValidPath, "[shortcuts]`nscreen = false`n[ahk.layout]`nergopti_base = 0`n"))
		AssertEqual(1, ApplyConfigToml(ManifestBuildFeaturesMap(), ValidPath, &Rejected, , &Outdated))
		AssertEqual(0, Rejected, "each diagnostic starts fresh; obsolete silos do not block migration")
		AssertEqual(0, Outdated.Count, "each diagnostic starts fresh")
		AssertTrue(_ConfigBootOutdatedEntries.Has("shortcuts`nscreen"),
			"a later valid read must not forget what the live tree ignored")
	} finally {
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigBootOutdatedEntries := OldOutdated
		FSDelete(Path)
		FSDelete(ValidPath)
	}
}
Test("config: local load diagnostics cannot change boot authority (config-partial-load-diagnostics)",
	_CPL_LocalDiagnosticsCannotChangeBootAuthority)
