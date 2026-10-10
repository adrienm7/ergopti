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
; Close preceding suppression through its genuine observer before observing this
; fixture. The real logger keeps every prior summary in its ring/file/queues;
; installing an observer alone would attribute that deferred ERROR to this test.
_CPL_WithLogCohort(Logs, Callback) {
	global _LOGGER_TEST_SINK
	PreviousSink := _LOGGER_TEST_SINK
	try {
		_LoggerFlushRepeats(true)
		LoggerSetTestSink((Line) => Logs.Push(Line))
		return Callback.Call()
	} finally {
		; The current cohort also owns its final deferred ERROR/repeat evidence.
		; Even a failed drain must restore the exact previous observer.
		try {
			_LoggerFlushRepeats(true)
		} finally {
			LoggerSetTestSink(PreviousSink)
		}
	}
}

_CPL_FullSavePreservesRejectedPreference(Invalid := true, Literal := "2") {
	Logs := []
	return _CPL_WithLogCohort(Logs,
		_CPL_FullSavePreservesRejectedPreferenceBody.Bind(Invalid, Literal, Logs))
}

_CPL_FullSavePreservesRejectedPreferenceBody(Invalid, Literal, Logs) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	OldRejected := _ConfigBootRejectedOverrides
	OldOutdated := _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	Path := _CTU_NewPath()
	Original := "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n[shortcuts]`nscreen = " . (Invalid ? Literal : "false")
		. "`n[layout]`nergopti_base = false`n"
	Target := ManifestBuildFeaturesMap()
	DefaultScreen := Target["shortcuts"]["screen"]
	Target["layout"]["ergopti_base"] := true
	Writes := []
	Writer := (FilePath, Updates) =>
		(Writes.Push(Updates), TOML_BatchWrite(FilePath, Updates))
	Collect := () => [{ Section: "shortcuts", Key: "screen",
		Value: Target["shortcuts"]["screen"] }]
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		AssertTrue(FSWrite(Path, Original))
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "the genuine fresh native fixture now has an independently current source before full persistence")
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
		ConfigSchemaPrepareSource(Path)
		AssertEqual(0, ApplyConfigToml(ManifestBuildFeaturesMap(), Path, &Rejected, , &Outdated))
		AssertEqual(0, Rejected, "an outdated value is not a rejected override")
		AssertTrue(Outdated.Has("shortcuts`nscreen"), "the load reports the outdated entry")
		AssertEqual(0, _ConfigBootOutdatedEntries.Count,
			"a local candidate load must not change boot authority")
		ApplyBootConfigToml(ManifestBuildFeaturesMap(), Path)
		AssertTrue(_ConfigBootOutdatedEntries.Has("shortcuts`nscreen"))
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertTrue(FSWrite(ValidPath, "[shortcuts]`nscreen = false`n[ahk.layout]`nergopti_base = 0`n"))
		ConfigSchemaPrepareSource(ValidPath)
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

; These causal controls use the existing canonical snapshot owner. The extra
; fields are precisely those it does not own: observer, repeat state and clocks.
; Closing outstanding production evidence happens BEFORE snapshotting; detached
; control queues cannot erase the preceding suite's ring, pending or dedup debt.
_CPL_WithIsolatedLogger(Callback) {
	global LOGGER_MIN_LEVEL, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_SUB_FILES
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _LOGGER_PATH_DATE, _LOGGER_TEST_SINK, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_REPEAT_ENABLED, _LOGGER_REPEAT_STREAKS, _LOGGER_REPEAT_DATE
	global _LOGGER_REPEAT_OLDEST, _LOGGER_REPEAT_SEQ, _LOGGER_REPEAT_USE
	_LoggerFlushRepeats(true)
	Saved := _TLOG_CaptureLoggerState()
	Extra := { PathDate: _LOGGER_PATH_DATE, Sink: _LOGGER_TEST_SINK,
		Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN,
		Enabled: _LOGGER_REPEAT_ENABLED, Streaks: _LOGGER_REPEAT_STREAKS,
		Date: _LOGGER_REPEAT_DATE, Oldest: _LOGGER_REPEAT_OLDEST,
		Seq: _LOGGER_REPEAT_SEQ, Use: _LOGGER_REPEAT_USE }
	try {
		LOGGER_MIN_LEVEL := "DEBUG"
		_LoggerRefreshFastFlags()
		LOGGER_LOG_PATH := ""
		LOGGER_ERRORS_LOG_PATH := ""
		_LOGGER_PATH_DATE := ""
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
		LOGGER_SUB_FILES := Map()
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		_LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false
		_LOGGER_REPEAT_STREAKS := Map()
		_LOGGER_REPEAT_DATE := ""
		_LOGGER_REPEAT_OLDEST := ""
		_LOGGER_CLOCK_FN := () => 1000
		_LOGGER_STAMP_FN := () => "2026-10-08 12:00:00:000"
		Callback.Call()
	} finally {
		_LOGGER_PATH_DATE := Extra.PathDate
		_LOGGER_TEST_SINK := Extra.Sink
		_LOGGER_CLOCK_FN := Extra.Clock
		_LOGGER_STAMP_FN := Extra.Stamp
		_LOGGER_REPEAT_ENABLED := Extra.Enabled
		_LOGGER_REPEAT_STREAKS := Extra.Streaks
		_LOGGER_REPEAT_DATE := Extra.Date
		_LOGGER_REPEAT_OLDEST := Extra.Oldest
		_LOGGER_REPEAT_SEQ := Extra.Seq
		_LOGGER_REPEAT_USE := Extra.Use
		_TLOG_RestoreLoggerState(Saved)
	}
}

_CPL_LogErrorCount(Lines) {
	Count := 0
	for Line in Lines
		Count += InStr(Line, "[ERROR]", true) ? 1 : 0
	return Count
}

_CPL_LogHasExactLine(Lines, Expected) {
	for Line in Lines {
		if Line == Expected
			return true
	}
	return false
}

_CPL_LogCohortDedup() {
	global _LOGGER_TEST_SINK, _LOGGER_DEDUP_COUNT, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	Previous := [], Current := []
	PreviousSink := (Line) => Previous.Push(Line)
	LoggerSetTestSink(PreviousSink)
	LoggerError("CPLCohort", "preceding cohort dedup evidence")
	LoggerError("CPLCohort", "preceding cohort dedup evidence")
	AssertEqual(1, _LOGGER_DEDUP_COUNT, "the preceding actual ERROR must have suppressed debt")
	AssertEqual(1, Previous.Length, "the repeated ERROR is genuinely deferred")
	First := Previous[1]
	_CPL_WithLogCohort(Current, () => LoggerWarn("CPLCohort", "current cohort warning"))
	AssertEqual(PreviousSink, _LOGGER_TEST_SINK, "successful fixture restores the exact observer")
	AssertEqual(2, Previous.Length, "the preceding observer receives its deferred summary")
	AssertContains(Previous[2], "[ERROR] [logger]", "the genuine summary keeps its ERROR severity")
	AssertEqual(0, _LOGGER_DEDUP_COUNT, "real summary emission settles preceding suppression")
	AssertEqual(1, Current.Length, "the current observer receives only its actual warning")
	AssertEqual(0, _CPL_LogErrorCount(Current), "the unfiltered ERROR counter sees no preceding error")
	for Line in [First, Previous[2]] {
		AssertTrue(_CPL_LogHasExactLine(LoggerRingBufferSnapshot(), Line),
			"the real ring retains preceding ERROR evidence")
		AssertTrue(_CPL_LogHasExactLine(_LOGGER_PENDING, Line),
			"an unresolved file retains preceding ERROR evidence in its real queue")
		AssertTrue(_CPL_LogHasExactLine(_LOGGER_PENDING_ERRORS, Line),
			"the errors-only queue retains the same preceding ERROR evidence")
	}
	Path := _CTU_NewPath(), ErrorsPath := Path . ".errors.log"
	try {
		LOGGER_LOG_PATH := Path
		LOGGER_ERRORS_LOG_PATH := ErrorsPath
		AssertTrue(_LoggerFlush(true), "the real file sink must accept retained ERROR evidence")
		for Line in [First, Previous[2]] {
			AssertContains(FSRead(Path), Line, "the unified native file retains prior evidence")
			AssertContains(FSRead(ErrorsPath), Line, "the errors-only native file retains prior evidence")
		}
	} finally {
		FSDelete(Path)
		FSDelete(ErrorsPath)
	}
}
Test("config: preceding actual ERROR dedup belongs to its observer cohort (config-log-cohort-dedup)",
	_CPL_WithIsolatedLogger.Bind(_CPL_LogCohortDedup))

_CPL_LogCohortRepeat() {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_STREAKS
	Previous := [], Current := []
	PreviousSink := (Line) => Previous.Push(Line)
	LoggerSetTestSink(PreviousSink)
	_LoggerRepeatEnable()
	LoggerError("CPLRepeat", "preceding repeat evidence")
	LoggerInfo("CPLRepeat", "intervening real message")
	LoggerError("CPLRepeat", "preceding repeat evidence")
	AssertEqual(2, Previous.Length, "the third actual emission is withheld by the genuine collapser")
	_CPL_WithLogCohort(Current, () => LoggerWarn("CPLRepeat", "current repeat-cohort warning"))
	AssertEqual(PreviousSink, _LOGGER_TEST_SINK, "repeat closure also restores the exact observer")
	AssertEqual(3, Previous.Length, "the prior observer retains its genuine repeat summary")
	AssertContains(Previous[3], "[ERROR] [CPLRepeat]", "repeat evidence retains its original severity and owner")
	AssertContains(Previous[3], "repeated 1 more time", "the actual withheld occurrence is not discarded")
	AssertEqual(0, _CPL_LogErrorCount(Current), "a prior repeat is excluded by observation timing, never a filter")
	AssertEqual(1, Current.Length, "the actual current warning remains visible")
}
Test("config: preceding genuine ERROR repeat closes before fixture observation (config-log-cohort-repeat)",
	_CPL_WithIsolatedLogger.Bind(_CPL_LogCohortRepeat))

_CPL_LogCurrentErrorAndThrow() {
	global _LOGGER_DEDUP_COUNT
	LoggerError("CPLCurrent", "current genuine ERROR evidence")
	LoggerError("CPLCurrent", "current genuine ERROR evidence")
	AssertEqual(1, _LOGGER_DEDUP_COUNT, "the failing current callback leaves genuine deferred ERROR debt")
	throw Error("expected current-cohort callback failure")
}

_CPL_LogCohortFailureRestoresObserver() {
	global _LOGGER_TEST_SINK
	Previous := [], Current := []
	PreviousSink := (Line) => Previous.Push(Line)
	LoggerSetTestSink(PreviousSink)
	Thrown := false
	try {
		_CPL_WithLogCohort(Current, _CPL_LogCurrentErrorAndThrow)
	} catch as Failure {
		AssertEqual("expected current-cohort callback failure", Failure.Message,
			"the genuine callback failure must propagate")
		Thrown := true
	}
	AssertTrue(Thrown, "the fixture owner must not swallow its callback failure")
	AssertEqual(PreviousSink, _LOGGER_TEST_SINK, "a failed fixture restores the exact previous observer")
	AssertEqual(0, Previous.Length, "current ERROR evidence is delivered to its own observer")
	AssertEqual(2, Current.Length, "both current ERROR and its actual dedup summary remain observable")
	AssertEqual(2, _CPL_LogErrorCount(Current), "the unchanged unfiltered counter counts every current ERROR")
	AssertContains(Current[1], "[ERROR] [CPLCurrent]", "the current producer must remain visible")
	AssertContains(Current[2], "[ERROR] [logger]", "current logger ERROR summaries are never filtered")
	LoggerWarn("CPLCurrent", "after the failed fixture")
	AssertEqual(1, Previous.Length, "the restored exact observer receives subsequent genuine emissions")
	AssertContains(Previous[1], "[WARNING] [CPLCurrent]", "restoration remains operational")
}
Test("config: current ERROR is counted and failed fixture restores its observer (config-log-cohort-failure)",
	_CPL_WithIsolatedLogger.Bind(_CPL_LogCohortFailureRestoresObserver))
