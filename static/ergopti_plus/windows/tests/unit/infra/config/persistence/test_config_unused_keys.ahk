; tests/unit/infra/config/persistence/test_config_unused_keys.ahk

; ==============================================================================
; MODULE: Unused Configuration Key Cleanup Tests
; DESCRIPTION:
; Behavioural proof for the tray cleanup of config.toml keys the boot loader
; reports as unknown: detection agrees with the loader's rule, removal deletes
; exactly those keys after a byte-exact backup, and a refused backup or writer
; leaves the configuration file untouched.
; ==============================================================================

#Requires AutoHotkey v2.0

; One key of each shape the loader must keep, plus two it rejects: an unknown
; leaf in a known section and a key under a section path the manifest lacks.
global _CUK_FIXTURE := '
(
[_meta]
version = 2

[ahk.layout]
ergopti_base = true

[hotstrings.personal.mine]
enabled = true

[layout]
ergopti_base = false

[llm]
api_entry_id = "entry_1"

[metrics]
enabled = true
metrics_encrypt = 0

[stale.section]
label = "old"

[updater]
channel = "stable"
)'

_CUK_NewDir() {
	static Seq := 0
	Seq += 1
	Dir := A_Temp . "\ergopti_unused_keys_" . A_TickCount . "_" . Seq
	DirCreate(Dir)
	return Dir
}

; Independently authored writable subjects exist before their one native Boot.
; A cleanup test cannot borrow an unknown or unversioned destination's authority.
_CUK_CurrentMetadata() {
	return "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n"
}

_CUK_AdmitCurrentSource(Path) {
	Before := FSReadUtf8Exact(Path)
	AssertEqual(ConfigMigrateCurrentVersion(), TOML_ParseDocument(Before)["_meta"]["schema_version"],
		"the independently authored cleanup subject already owns its current stamp")
	Boot := ConfigMigrateBoot(Path)
	AssertEqual("current", Boot["status"])
	AssertEqual(0, Boot["read_only"])
	AssertTrue(ConfigSchemaCanPrepareWrite(Path))
	AssertEqual("", TOML_WriteRefusal(Path))
	AssertTrue(FSUtf8ExactMatches(Path, Before), "native Boot preserves every source byte before preview and backup")
}

_CUK_WriteFixture(Dir) {
	global _CUK_FIXTURE
	Path := Dir . "\config.toml"
	Source := StrReplace(_CUK_FIXTURE, "`r`n", "`n")
	; Extend the existing metadata table rather than defining its namespace twice.
	Source := StrReplace(Source, "[_meta]`n", _CUK_CurrentMetadata())
	AssertTrue(FSWriteDurable(Path, Source),
		"the fixture config must be written")
	_CUK_AdmitCurrentSource(Path)
	return Path
}

_CUK_Ids(Keys) {
	Ids := []
	for Entry in Keys
		Ids.Push(Entry["section"] . "." . Entry["key"] . "=" . Entry["kind"])
	return Ids
}

_CUK_SortedIds(Keys) {
	return _CUK_CanonicalIds(_CUK_Ids(Keys))
}

; Cleanup promises identities, not the native parser Map's enumeration order.
; Compare hand-written identities case-exactly without discarding duplicates.
_CUK_CanonicalIds(Items) {
	Sorted := Map()
	Sorted.CaseSense := "On"
	for Id in Items {
		AssertFalse(Sorted.Has(Id), "cleanup preview identities must not repeat")
		Sorted[Id] := true
	}
	Ids := []
	for Id in Sorted
		Ids.Push(Id)
	return Ids
}

_CUK_AssertIds(Expected, Keys) {
	ExpectedIds := StrSplit(Expected, "|")
	ActualIds := _CUK_Ids(Keys)
	AssertEqual(ExpectedIds.Length, ActualIds.Length, "every hand-written cleanup identity occurs exactly once")
	AssertEqual(_CUK_Join(_CUK_CanonicalIds(ExpectedIds)), _CUK_Join(_CUK_CanonicalIds(ActualIds)),
		"the complete cleanup identities match case-exactly")
}

_CUK_RequireId(Keys, Id) {
	Matches := []
	for Entry in Keys {
		if (Entry["section"] . "." . Entry["key"] . "=" . Entry["kind"]) == Id
			Matches.Push(Entry)
	}
	AssertEqual(1, Matches.Length, "the independently named cleanup identity occurs exactly once")
	return Matches[1]
}

_CUK_Join(Items) {
	Out := ""
	for Index, Item in Items
		Out .= (Index > 1 ? "|" : "") . Item
	return Out
}





; ============================
; ============================
; ======= 1/ Detection =======
; ============================
; ============================

_CUK_DetectsExactlyTheUnknownKeys() {
	Dir := _CUK_NewDir()
	try {
		Scan := ConfigUnusedKeysFind(_CUK_WriteFixture(Dir))
		AssertEqual("ok", Scan["status"])
		AssertEqual("ahk.layout.ergopti_base=section|metrics.metrics_encrypt=leaf|stale.section.label=section",
			_CUK_Join(_CUK_Ids(Scan["keys"])),
			"the retired section, unknown leaf and unknown section path are offered; metadata, "
			. "updater, dynamic personal and foreign-owned keys are not")
		AssertEqual("true", Scan["keys"][1]["value"])
		AssertEqual("0", Scan["keys"][2]["value"])
		AssertEqual('"old"', Scan["keys"][3]["value"])
	} finally DirDelete(Dir, true)
}
Test("config unused keys: detection reports exactly the keys boot rejects as unknown "
	. "(config-unused-keys-detect)", _CUK_DetectsExactlyTheUnknownKeys)

; The loader and the scan share TomlConfigUnknownKind. Pin the loader half:
; applying the fixture must still apply the known keys and skip both unknown
; ones without counting them as rejected overrides.
_CUK_LoaderAgrees() {
	Dir := _CUK_NewDir()
	try {
		Target := ManifestBuildFeaturesMap()
		Applied := ApplyConfigToml(Target, _CUK_WriteFixture(Dir), &Rejected)
		AssertEqual(0, Rejected, "unknown keys are skipped, not rejected")
		AssertEqual(false, Target["layout"]["ergopti_base"])
		AssertFalse(Target["metrics"].Has("metrics_encrypt"),
			"the unknown leaf must not reach the Features tree")
		AssertFalse(Target.Has("stale"),
			"the unknown section path must not be vivified")
		AssertEqual(true, Target["hotstrings"]["personal"]["mine"]["enabled"],
			"the dynamic personal namespace is still applied")
		AssertEqual(3, Applied)
	} finally DirDelete(Dir, true)
}
Test("config unused keys: the boot loader skips the same keys through the shared rule "
	. "(config-unused-keys-loader-parity)", _CUK_LoaderAgrees)

_CUK_MissingFileHasNothingToClean() {
	Dir := _CUK_NewDir()
	try {
		Scan := ConfigUnusedKeysFind(Dir . "\absent.toml")
		AssertEqual("ok", Scan["status"])
		AssertEqual(0, Scan["keys"].Length)
	} finally DirDelete(Dir, true)
}
Test("config unused keys: a missing config has nothing to clean "
	. "(config-unused-keys-missing)", _CUK_MissingFileHasNothingToClean)

_CUK_LanguageCategoryGatesHaveAnOwner() {
	Target := ManifestBuildFeaturesMap()
	Count := 0
	for _, Pack in HotstringsLanguageCategories() {
		for _, Category in Pack["categories"] {
			Owner := ""
			AssertEqual("", TomlConfigUnknownKind(Target, "category_enabled", Category["v2"], &Owner),
				"FeatureState reads the language gate " . Category["v2"])
			AssertEqual("FeatureState", Owner, "the generic feature loader must leave this value to its actual reader")
			Count += 1
		}
	}
	AssertTrue(Count > 0, "the shipped language packs must exercise at least one category gate")
	AssertEqual("leaf", TomlConfigUnknownKind(Target, "category_enabled", "french_autocorection"),
		"a language-looking typo must remain an unknown key")
}
Test("config language category gates remain owned and cannot be cleaned as unused (language-category-owner)",
	_CUK_LanguageCategoryGatesHaveAnOwner)

_CUK_UnknownKeysWarnOnceWithoutErrors() {
	Dir := _CUK_NewDir()
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		Path := Dir . "\config.toml"
		AssertTrue(FSWriteDurable(Path, "[metrics]`nenabled = true`nobsolete_metric = true`n[old.section]`nenabled = true`n"))
		_CMJFixtureReadonly(Path)
		ApplyConfigToml(ManifestBuildFeaturesMap(), Path)
		Errors := 0, Warnings := 0
		for Line in Lines {
			if InStr(Line, "[TomlConfigLoader]") {
				if InStr(Line, "[ERROR]")
					Errors += 1
				if InStr(Line, "[WARNING]")
					Warnings += 1
			}
		}
		AssertEqual(0, Errors, "unused keys are cleanup candidates, not runtime failures")
		AssertEqual(1, Warnings, "one warning summarizes the whole file")
	} finally {
		LoggerClearTestSink()
		DirDelete(Dir, true)
	}
}
Test("config unused keys: obsolete entries produce one warning and no error (unused-config-warning)",
	_CUK_UnknownKeysWarnOnceWithoutErrors)

; A known key holding a value this build no longer accepts (a narrowed enum, a
; boolean spelled "yes", a scalar where a table lives) used to log two ERRORs,
; latch the boot authority that refuses every later full save, and stay
; invisible to the cleanup. It is outdated configuration: one WARNING that
; names it, no rejection, and a cleanup offer (config-outdated-windows).
_CUK_OutdatedValuesWarnAndAreOffered() {
	Dir := _CUK_NewDir()
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		Path := Dir . "\config.toml"
		AssertTrue(FSWriteDurable(Path, "[script]`nlocale = " . '"es"'
			. "`nlog_level = " . '"VERBOSE"' . "`nalt_gr_is_kana_remap = " . '"yes"' . "`n"
			. "[layout]`nergopti_base = false`n"))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		Applied := ApplyConfigToml(Target, Path, &Rejected, , &Outdated)
		AssertEqual(2, Applied, "the accepted neighbours still apply")
		AssertEqual(0, Rejected, "an outdated value never blocks full saves")
		AssertEqual(2, Outdated.Count)
		AssertEqual("INFO", Target["script"]["log_level"], "the setting keeps its manifest value")
		Errors := 0, Named := 0
		for Line in Lines {
			if InStr(Line, "[ERROR]")
				Errors += 1
			if InStr(Line, "[WARNING]") && InStr(Line, "outdated configuration value(s)")
					&& InStr(Line, "[script].log_level") && InStr(Line, "[script].alt_gr_is_kana_remap")
				Named += 1
		}
		AssertEqual(0, Errors, "an outdated value is never an ERROR")
		AssertEqual(1, Named, "one warning names every outdated value")
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		AssertEqual("script.alt_gr_is_kana_remap=leaf|script.log_level=leaf",
			_CUK_Join(_CUK_SortedIds(Scan["keys"])),
			"the cleanup offers exactly the values boot warned about")
	} finally {
		LoggerClearTestSink()
		DirDelete(Dir, true)
	}
}
Test("config unused keys: an outdated value warns once and is offered (config-outdated-windows)",
	_CUK_OutdatedValuesWarnAndAreOffered)

_CUK_StartupOffersTheExistingCleanupWithoutWriting() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		Before := FSReadUtf8Exact(Path)
		Offered := []
		AssertTrue(ConfigUnusedKeysOffer(Path, ConfigUnusedKeysFind, (FilePath) => Offered.Push(FilePath)))
		AssertEqual(1, Offered.Length, "one file produces one cleanup proposal")
		AssertEqual(Path, Offered[1], "the proposal targets the exact configuration file")
		AssertEqual(Before, FSReadUtf8Exact(Path), "offering the tool does not accept cleanup for the user")
		AssertFalse(ConfigUnusedKeysOffer(Dir . "\absent.toml", ConfigUnusedKeysFind, (*) => Offered.Push("unexpected")))
		AssertTrue(FSWriteDurable(Path, "[metrics]`nenabled = true`n"))
		AssertFalse(ConfigUnusedKeysOffer(Path, ConfigUnusedKeysFind, (*) => Offered.Push("unexpected")))
		AssertEqual(1, Offered.Length, "a clean or absent configuration needs no proposal")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: startup offers cleanup once without accepting it (unused-config-warning)",
	_CUK_StartupOffersTheExistingCleanupWithoutWriting)





; ==========================
; ==========================
; ======= 2/ Removal =======
; ==========================
; ==========================

_CUK_RemovesExactlyThemAfterBackup() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		Original := FSReadUtf8Exact(Path)
		Keys := ConfigUnusedKeysFind(Path)["keys"]
		Result := ConfigUnusedKeysRemove(Path, Keys, "20990101-000000")
		AssertEqual("removed", Result["status"])
		AssertEqual(3, Result["removed"])
		AssertEqual(Dir . "\config.backup-20990101-000000.toml", Result["backup"])
		AssertEqual(Original, FSReadUtf8Exact(Result["backup"]),
			"the backup must hold the exact pre-cleanup bytes")

		After := TOML_ParseFreshFile(Path)
		AssertFalse(After["metrics"].Has("metrics_encrypt"))
		AssertFalse(After.Has("stale.section"),
			"an unknown section emptied by the cleanup loses its header")
		AssertEqual(true, After["metrics"]["enabled"])
		AssertEqual(false, After["layout"]["ergopti_base"])
		AssertEqual("entry_1", After["llm"]["api_entry_id"])
		AssertEqual(true, After["hotstrings.personal.mine"]["enabled"])
		AssertEqual(2, After["_meta"]["version"])
		AssertEqual("stable", After["updater"]["channel"])
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length,
			"a second check finds nothing left to clean")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: cleanup removes exactly the unused keys after a byte-exact backup "
	. "(config-unused-keys-remove)", _CUK_RemovesExactlyThemAfterBackup)

_CUK_KeepsSectionWithUnlistedKey() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		Keys := ConfigUnusedKeysFind(Path)["keys"]
		; A key written after the scan was never shown to the user.
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "stale.section", Key: "late", Value: 1 }]))
		Result := ConfigUnusedKeysRemove(Path, Keys, "20990101-000001")
		AssertEqual("removed", Result["status"])
		After := TOML_ParseFreshFile(Path)
		AssertFalse(After["stale.section"].Has("label"))
		AssertEqual(1, After["stale.section"]["late"],
			"only keys the user confirmed may be removed")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: cleanup never removes a key the user was not shown "
	. "(config-unused-keys-unlisted)", _CUK_KeepsSectionWithUnlistedKey)

; The writer drops sections without regard to case. An unknown [Layout] must not
; take the known [layout] with it when its header is removed.
_CUK_CaseVariantSectionKeepsKnownTwin() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		AssertTrue(TOML_BatchWrite(Path, [{ Section: "Layout", Key: "stale", Value: 1 }]))
		Keys := ConfigUnusedKeysFind(Path)["keys"]
		_CUK_AssertIds("ahk.layout.ergopti_base=section|Layout.stale=section|metrics.metrics_encrypt=leaf|stale.section.label=section",
			Keys)
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, Keys, "20990101-000004")["status"])
		After := TOML_ParseFreshFile(Path)
		AssertEqual(false, After["layout"]["ergopti_base"],
			"the known section must survive the removal of its case variant")
		AssertFalse(After.Has("Layout") && After["Layout"].Has("stale"))
	} finally DirDelete(Dir, true)
}
Test("config unused keys: removing an unknown case variant keeps the known section "
	. "(config-unused-keys-case-variant)", _CUK_CaseVariantSectionKeepsKnownTwin)

_CUK_BackupFailureAborts(Seam) {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		Original := FSReadUtf8Exact(Path)
		Keys := ConfigUnusedKeysFind(Path)["keys"]
		Stamp := "20990101-000002"
		BackupFn := 0
		if (Seam == "refused")
			BackupFn := (Target, Content) => 0
		else {
			; A file already at the backup path: CREATE_NEW must refuse rather
			; than overwrite it, and the cleanup must stop there.
			AssertTrue(FSWriteDurable(ConfigUnusedKeysBackupPath(Path, Stamp), "occupied"))
		}
		WriterCalls := 0
		Writer := (Target, Updates) => (WriterCalls += 1, TOML_BatchWrite(Target, Updates))
		Result := ConfigUnusedKeysRemove(Path, Keys, Stamp, BackupFn, Writer)
		AssertEqual("backup_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(0, WriterCalls, "no update may reach the writer without a backup")
		AssertEqual(Original, FSReadUtf8Exact(Path),
			"a backup failure must leave config.toml byte-identical")
		if (Seam == "collision")
			AssertEqual("occupied", FSReadUtf8Exact(Result["backup"]),
				"an existing file at the backup path is never overwritten")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: a refused backup aborts without touching the config "
	. "(config-unused-keys-backup-refused)", _CUK_BackupFailureAborts.Bind("refused"))
Test("config unused keys: an occupied backup path aborts without touching either file "
	. "(config-unused-keys-backup-collision)", _CUK_BackupFailureAborts.Bind("collision"))

_CUK_WriterFailureKeepsConfig() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		Original := FSReadUtf8Exact(Path)
		Keys := ConfigUnusedKeysFind(Path)["keys"]
		Result := ConfigUnusedKeysRemove(Path, Keys, "20990101-000003", 0,
			(Target, Updates) => false)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(Original, FSReadUtf8Exact(Path))
		AssertEqual(Original, FSReadUtf8Exact(Result["backup"]),
			"the backup made before the refused write is still exact")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: a refused write reports failure and keeps the config "
	. "(config-unused-keys-write-refused)", _CUK_WriterFailureKeepsConfig)





; ==============================
; ==============================
; ======= 3/ Menu wiring =======
; ==============================
; ==============================

_CUK_MenuDeclaresTheAction() {
	Found := false
	for Entry in _MM_GetManifestRoot()["configuration_menu"] {
		if (Entry.Get("id", "") != "clean_unused_keys")
			continue
		Found := true
		AssertEqual("command", Entry["type"])
		AssertEqual("menu.global.clean_unused_keys", Entry["i18n"])
		; macOS and Linux run the same cleanup through their own readers' rule, so
		; the row is declared once for every platform.
		AssertFalse(Entry.Has("platforms"), "the cleanup row must not be restricted to one platform")
		AssertFalse(Entry.Has("reason_key"), "an unrestricted row has no platform reason")
	}
	AssertTrue(Found, "configuration_menu must declare clean_unused_keys")
	Body := _DriverFuncBody("_MI_BuildConfigurationMenu")
	AssertTrue(Body != "", "_MI_BuildConfigurationMenu must be found")
	AssertTrue(RegExMatch(Body, '"clean_unused_keys",\s+ShowUnusedConfigKeysCleanup') > 0,
		"the Windows Configuration menu must dispatch clean_unused_keys")
}
Test("config unused keys: the Configuration menu declares and dispatches the cleanup "
	. "(config-unused-keys-menu)", _CUK_MenuDeclaresTheAction)

_CUK_StartupDefersCleanupUntilReady() {
	Source := _DriverSourceNoComments()
	AssertTrue(Source != "", "driver source must be readable")
	; The entry point stays contiguous in the source helper, so these positions
	; prove the timer is armed after readiness even when the entry is relocated.
	Ready := InStr(Source, "_DriverReady := true")
	Offer := InStr(Source, "SetTimer(ConfigUnusedKeysOffer.Bind(ConfigurationFile), -MENU_BUILD_DEFER_MS)")
	AssertTrue(Ready > 0, "the driver must publish readiness")
	AssertTrue(Offer > Ready, "the cleanup prompt must be deferred until after readiness")
}
Test("config unused keys: startup schedules the cleanup offer after readiness (unused-config-warning)",
	_CUK_StartupDefersCleanupUntilReady)

; A nonmodal preview must not authorize deletion of bytes changed after opening.
_CUK_WebPreviewLifecycle() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		Session := ConfigCleanupSession(Path)
		State := Session.Handle("ready")
		AssertEqual("ready", State["status"])
		AssertEqual(3, State["keys"].Length)
		Before := FSReadUtf8Exact(Path)
		AssertEqual(0, Session.Handle(Map("action", "clean", "session", "stale")))
		AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertTrue(FSWriteDurable(Path, Before . "`n# changed after preview`n"))
		Changed := FSReadUtf8Exact(Path)
		AssertEqual("changed", Session.Handle(Map("action", "clean", "session", Session.Token))["status"])
		AssertEqual(Changed, FSReadUtf8Exact(Path))
		AssertEqual(0, Session.Handle(Map("action", "clean", "session", Session.Token)), "refresh is required")
		AssertEqual("ready", Session.Handle(Map("action", "refresh", "session", Session.Token))["status"])
		Result := Session.Handle(Map("action", "clean", "session", Session.Token,
			"path", Dir . "\untrusted.toml", "keys", []))
		AssertEqual("removed", Result["status"])
		AssertEqual(Changed, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(0, Session.Handle(Map("action", "clean", "session", Session.Token)), "one confirmed transaction only")
		Decoded := JsonParse(Session.Json())
		AssertFalse(Decoded.Has("source"), "private source bytes never enter the page contract")
		Session.Close()
		AssertEqual(0, Session.Handle("ready"), "late callbacks cannot reopen a closed session")
	} finally DirDelete(Dir, true)
}
Test("config cleanup webview: changed files require refresh, one backup and no stale action (config-cleanup-webview)",
	_CUK_WebPreviewLifecycle)

_CUK_DeferredCleanArm(State, Callback, Period) {
	global MENU_COMMAND_DEFERRAL_RETRY_MS
	AssertEqual(MENU_COMMAND_DEFERRAL_RETRY_MS, Period)
	AssertFalse(State.Retry is Object, "one confirmation schedules one retry")
	State.Retry := Callback
}

; A confirmation that interrupts a configuration write used to run at once and
; be refused (write_failed) with the setting kept; it now waits for the write.
_CUK_CleanWaitsForRunningWrite() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteFixture(Dir)
		Before := FSReadUtf8Exact(Path)
		Host := ConfigCleanupWindow()
		Host.Session := ConfigCleanupSession(Path)
		Evals := []
		Host.DefineProp("Eval", {Call: (Self, Js) => Evals.Push(Js)})
		Host.Deliver("ready")
		AssertEqual("ready", Host.Session.State["status"])
		Retry := {Retry: 0}
		Lease := _ConfigWriteLeaseTryAcquire(Path, "concurrent-writer")
		AssertTrue(Lease is Object, "the regression needs a real write in progress")
		try {
			Host.Deliver(Map("action", "clean", "session", Host.Session.Token), 0,
				_CUK_DeferredCleanArm.Bind(Retry))
			AssertEqual("ready", Host.Session.State["status"], "a write in progress must defer the cleanup, not refuse it")
			AssertEqual(Before, FSReadUtf8Exact(Path))
			AssertTrue(Retry.Retry is Object, "the cleanup is scheduled for when the write ends")
		} finally _ConfigWriteLeaseRelease(Lease)
		Retry.Retry.Call()
		AssertEqual("removed", Host.Session.State["status"], "the deferred cleanup runs once the write has ended")
		AssertEqual(2, Evals.Length, "the page hears the preview and the deferred outcome")
		Host.Session.Close()
	} finally DirDelete(Dir, true)
}
Test("config cleanup webview: a confirmation during a configuration write waits for it (cleanup-during-write)",
	_CUK_CleanWaitsForRunningWrite)

_CUK_WebPreviewCancelAndLongList() {
	Dir := _CUK_NewDir()
	try {
		Path := Dir . "\config.toml"
		Source := "[obsolete]`n"
		Loop 80
			Source .= "setting_" . A_Index . " = true`n"
		AssertTrue(FSWriteDurable(Path, Source))
		Session := ConfigCleanupSession(Path)
		AssertEqual(80, Session.Handle("ready")["keys"].Length)
		AssertEqual(80, JsonParse(Session.Json())["keys"].Length, "the bridge never truncates at 30")
		Session.Handle(Map("action", "close", "session", Session.Token))
		AssertEqual(0, Session.Handle(Map("action", "clean", "session", Session.Token)))
		AssertEqual(Source, FSReadUtf8Exact(Path), "closing writes nothing")
	} finally DirDelete(Dir, true)
}
Test("config cleanup webview: all 80 entries survive and cancellation preserves bytes (config-cleanup-webview)",
	_CUK_WebPreviewCancelAndLongList)

; Models the message pump inside WebView2.create without creating a native view.
class _CUK_DeferredGui {
	Hidden := false
	Destroyed := false
	Hide() {
		this.Hidden := true
	}
	Destroy() {
		this.Destroyed := true
	}
}

class _CUK_DeferredController {
	Closed := false
	Close() {
		this.Closed := true
	}
}

_CUK_FakeCleanupBuild(Host) {
	Host.Gui := _CUK_DeferredGui()
	Host.ProbeGui := Host.Gui
	Host.Close()
	AssertFalse(Host.ProbeGui.Destroyed, "creation must retain its native parent until the controller returns")
	AssertTrue(Host.ProbeGui.Hidden, "the cancelled window disappears immediately")
	AssertEqual(0, Host.Session.Handle("ready"), "cancellation revokes the session during the await")
	AssertFalse(ConfigCleanupWindow.Open("ignored.toml"), "a cancelled build cannot be reused or replaced")
	Host.Controller := _CUK_DeferredController()
	Host.ProbeController := Host.Controller
	Host.WebView := {}
	Host.ResetDone := false
	return true
}

_CUK_WebWindowDeferredClose() {
	PreviousBuild := WebViewHost.Prototype.GetOwnPropDesc("_Build")
	PreviousCurrent := ConfigCleanupWindow.Current
	Host := ConfigCleanupWindow()
	Host.Session := ConfigCleanupSession("unused-by-this-test.toml")
	Host.AppId := "config_cleanup"
	ConfigCleanupWindow.Current := Host
	WebViewHost.Prototype.DefineProp("_Build", {Call: _CUK_FakeCleanupBuild})
	try {
		Host._Build()
		AssertTrue(Host.Cancelled)
		AssertFalse(Host.Building)
		AssertTrue(Host.ResetDone, "a late controller cannot resurrect a closed host")
		AssertTrue(Host.ProbeGui.Destroyed)
		AssertTrue(Host.ProbeController.Closed)
		AssertEqual(0, Host.Gui)
		AssertEqual(0, ConfigCleanupWindow.Current, "the retired owner releases the singleton")
	} finally {
		WebViewHost.Prototype.DefineProp("_Build", PreviousBuild)
		Host.Building := false
		Host.Close()
		ConfigCleanupWindow.Current := PreviousCurrent
	}
}
Test("config cleanup webview: close during native creation releases the late controller (config-cleanup-webview)",
	_CUK_WebWindowDeferredClose)

_CUK_ActionParameterOwnership() {
	Target := ManifestBuildFeaturesMap()
	for Binding in ["gesture__tap_4", "keyboard__ctrl_k", "script__pause", "tap_hold__caps_lock", "tap_key__number_row_left"] {
		Owner := ""
		AssertEqual("", TomlConfigUnknownKind(Target, "action_parameters", Binding . "__open_url", &Owner),
			"parameterized bindings must remain owned: " . Binding)
		AssertEqual("Gestures", Owner)
	}
	for Key in ["gesture__tap_4__missing_action", "gesture__tap_4__none", "bogus__tap_4__open_url", "gesture____open_url"]
		AssertEqual("section", TomlConfigUnknownKind(Target, "action_parameters", Key), "unknown parameters remain visible: " . Key)
}
Test("action parameters have a declared owner without exempting unknown keys (config-action-parameter-owner)",
	_CUK_ActionParameterOwnership)

_CUK_ActionParameterLabels() {
	global _I18nCache, _I18nCacheLoaded, _SharedDir, GestureActionParameters
	SavedCache := _I18nCache, SavedLoaded := _I18nCacheLoaded, SavedParameters := GestureActionParameters
	try {
		Locales := JsonParse(FileRead(_SharedDir . "\data\locale_order.json", "UTF-8"))["order"]
		AssertEqual(21, Locales.Length)
		for Locale in Locales {
			Strings := JsonParse(FileRead(_SharedDir . "\data\locales\" . Locale . ".json", "UTF-8"))
			_I18nCache := Strings, _I18nCacheLoaded := true
			for Action in ["open_url", "search_web", "wrap_selection", "send_text", "send_key", "send_shortcut"] {
				Label := Strings["sg_actions." . Action]
				Assert(RegExMatch(Label, "\[[^\[\]]*\]$", &Marker), Locale . ": " . Action)
				GestureActionParameters := Map()
				AssertEqual(Label, GestureActionDisplayLabel(Action, "gesture__tap_4"))
				for Value in ["https://apple.com", "https://example.org/?q=%s", "[x] 50% & café"] {
					GestureActionParameters["gesture__tap_4__" . Action] := Value
					AssertEqual(SubStr(Label, 1, Marker.Pos - 1) . "[" . Value . "]",
						GestureActionDisplayLabel(Action, "gesture__tap_4"), Locale . ": " . Action)
				}
			}
		}
	} finally {
		_I18nCache := SavedCache, _I18nCacheLoaded := SavedLoaded, GestureActionParameters := SavedParameters
	}
}
Test("action labels replace the configurable marker in every locale (action-parameter-label)",
	_CUK_ActionParameterLabels)

_CUK_ActionParameterRoundTrip() {
	global ConfigurationFile, GestureActionParameters, GestureAssignments, _IniCache
	OriginalConfig := ConfigurationFile
	OriginalParameters := GestureActionParameters
	OriginalAssignments := GestureAssignments.Clone()
	OriginalCache := _IniCache
	Dir := _CUK_NewDir()
	try {
		ConfigurationFile := Dir . "\config.toml"
		Boot := ConfigMigrateBoot(ConfigurationFile)
		AssertEqual("absent", Boot["status"])
		AssertEqual(0, Boot["read_only"])
		AssertTrue(ConfigSchemaCanPrepareWrite(ConfigurationFile))
		AssertFalse(FileExist(ConfigurationFile))
		GestureActionParameters := Map()
		AssertTrue(GestureSaveAssignment("tap_4", "open_url"))
		AssertTrue(GestureSetActionParameter("gesture__tap_4", "open_url", "https://apple.com"))
		AssertTrue(TOML_BatchWrite(ConfigurationFile, [{ Section: "action_parameters", Key: "obsolete", Value: "unused" }]))
		_IniCache := ParseTomlFile(ConfigurationFile)
		GestureActionParameters := Map()
		GestureAssignments["tap_4"] := "none"
		GesturesReadConfig()
		AssertEqual("open_url", GestureAssignments["tap_4"])
		AssertEqual("https://apple.com", GestureGetActionParameter("gesture__tap_4", "open_url"))
		Found := 0
		for Row in _GES_SlotRows() {
			if InStr(Row.Get("label", ""), "https://apple.com") {
				Found += 1
				AssertTrue(InStr(Row["label"], t("gesture.slots.tap_4")) > 0)
			}
		}
		AssertEqual(1, Found, "the real four-finger menu row shows the chosen URL after reload")
		Scan := ConfigUnusedKeysFind(ConfigurationFile)
		AssertEqual("action_parameters.obsolete=section", _CUK_Join(_CUK_Ids(Scan["keys"])))
		AssertEqual("removed", ConfigUnusedKeysRemove(ConfigurationFile, Scan["keys"], "20990101-000099")["status"])
		_IniCache := ParseTomlFile(ConfigurationFile)
		GesturesReadConfig()
		AssertEqual("https://apple.com", GestureGetActionParameter("gesture__tap_4", "open_url"),
			"cleaning an unrelated obsolete key must preserve the configured URL")
	} finally {
		ConfigurationFile := OriginalConfig
		GestureActionParameters := OriginalParameters
		GestureAssignments := OriginalAssignments
		_IniCache := OriginalCache
		DirDelete(Dir, true)
	}
}
Test("four-finger URL survives real persistence reload cleanup and menu rendering (config-action-parameter-owner)",
	_CUK_ActionParameterRoundTrip)

; A stale native handle must not report that the existing preview was reopened.
_CUK_WebWindowReuseRefusal() {
	Previous := ConfigCleanupWindow.Current
	Host := ConfigCleanupWindow()
	Host.Gui := { Hwnd: 0 }
	Host.ResetDone := false
	ConfigCleanupWindow.Current := Host
	try {
		AssertFalse(ConfigCleanupWindow.Open("unused-by-reuse.toml"),
			"the real window adapter must propagate activation refusal")
		AssertTrue(ConfigCleanupWindow.Current == Host, "refusal must retain the admitted preview owner")
	} finally ConfigCleanupWindow.Current := Previous
}
Test("config cleanup webview: reuse consumes the native activation refusal (config-cleanup-reuse)",
	_CUK_WebWindowReuseRefusal)





; ===================================================
; ===================================================
; ======= 4/ Session Protected Source Preview =======
; ===================================================
; ===================================================

_CUK_ProtectedSourceHasNoCleanupOffer() {
	Dir := _CUK_NewDir()
	Path := Dir . "\protected-config.toml"
	Source := '[_meta]`nschema_version = ' . (ConfigMigrateCurrentVersion() + 1)
		. '`n[layout]`nfuture_layout_owner = "retain exactly"`n'
	Reason := "Controlled newer schema refusal."
	Offers := []
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		TOML_RefuseWrites(Path, Reason)
		Scan := ConfigUnusedKeysFind(Path, Map("layout", Map()))
		AssertEqual("unsupported", Scan["status"], "a protected schema has no admitted cleanup ownership")
		AssertEqual(0, Scan["keys"].Length, "future-owned keys are never disposable rows")
		AssertFalse(ConfigUnusedKeysOffer(Path, ConfigUnusedKeysFind, (Target) => Offers.Push(Target)))
		AssertEqual(0, Offers.Length, "startup cannot offer an unsafe protected-source cleanup")
		AssertEqual(Source, FSReadUtf8Exact(Path), "preview preserves the exact newer source")
		AssertEqual(Reason, TOML_WriteRefusal(Path), "preview never lifts session protection")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: protected schema refuses preview and startup offer (protected-schema-cleanup)",
	_CUK_ProtectedSourceHasNoCleanupOffer)





; ============================================
; ============================================
; ======= 5/ Semantic Source Spellings =======
; ============================================
; ============================================

; Boot reads config.toml through the typed document, so a leaf it warns about
; may be spelled as a root dotted key, an inline table member or a dotted key
; inside a section. The cleanup once scanned a flat [section] key = value view:
; it missed the first two spellings and offered the third under a literal
; dotted name whose deletion changed nothing while reporting "removed".
_CUK_WriteSemanticSubject(Dir, Body) {
	Path := Dir . "\config.toml"
	AssertEqual(1, FSWriteCreateDurable(Path, Body . "`n" . _CUK_CurrentMetadata()))
	_CUK_AdmitCurrentSource(Path)
	return Path
}

_CUK_RootDottedAndInlineLeavesAreOffered() {
	Dir := _CUK_NewDir()
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		Path := _CUK_WriteSemanticSubject(Dir, "metrics.obsolete_metric = true`n"
			. "layout = { ergopti_base = false, retired_flag = 1 } # kept comment`n")
		Target := ManifestBuildFeaturesMap()
		ApplyConfigToml(Target, Path, &Rejected)
		AssertEqual(0, Rejected)
		Warned := 0
		for Line in Lines {
			if InStr(Line, "[WARNING]") && InStr(Line, "unused configuration key")
					&& InStr(Line, "[metrics].obsolete_metric") && InStr(Line, "[layout].retired_flag")
				Warned += 1
		}
		AssertEqual(1, Warned, "control: boot warns about both semantic unknown leaves")
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		_CUK_AssertIds("layout.retired_flag=leaf|metrics.obsolete_metric=leaf", Scan["keys"])
		AssertEqual("1", _CUK_RequireId(Scan["keys"], "layout.retired_flag=leaf")["value"])
		AssertEqual("true", _CUK_RequireId(Scan["keys"], "metrics.obsolete_metric=leaf")["value"])
		Source := FSReadUtf8Exact(Path)
		Result := ConfigUnusedKeysRemove(Path, Scan["keys"], "20990101-000400", 0, 0, Source)
		AssertEqual("removed", Result["status"])
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
		After := FSReadUtf8Exact(Path)
		Doc := TOML_ParseDocument(After)
		AssertFalse(Doc["layout"].Has("retired_flag"))
		AssertFalse(Doc.Has("metrics") && Doc["metrics"].Has("obsolete_metric"))
		AssertEqual(false, Doc["layout"]["ergopti_base"].Value, "the known inline sibling survives")
		AssertTrue(InStr(After, "# kept comment") > 0, "the unrelated comment survives the cleanup")
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length, "a second scan finds nothing left")
	} finally {
		LoggerClearTestSink()
		DirDelete(Dir, true)
	}
}
Test("config unused keys: root dotted and inline leaves warned by boot are offered and removed "
	. "(config-unused-keys-semantic-shapes)", _CUK_RootDottedAndInlineLeavesAreOffered)

_CUK_InlineFeatureChildrenAreOffered() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteSemanticSubject(Dir, "[hotstrings]`n"
			. 'autocorrection = { names = { enabled = "yes" }, caps = { enabled = false } }' . "`n")
		Target := ManifestBuildFeaturesMap()
		ApplyConfigToml(Target, Path, &Rejected, , &Outdated)
		AssertEqual(0, Rejected)
		AssertTrue(Outdated.Has("hotstrings.autocorrection.names`nenabled"),
			"control: boot classifies the inline child value as outdated")
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		_CUK_AssertIds("hotstrings.autocorrection.caps=leaf|hotstrings.autocorrection.names.enabled=leaf",
			Scan["keys"])
		AssertEqual('"yes"', _CUK_RequireId(Scan["keys"], "hotstrings.autocorrection.names.enabled=leaf")["value"])
		Result := ConfigUnusedKeysRemove(Path, Scan["keys"], "20990101-000401")
		AssertEqual("removed", Result["status"])
		Doc := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Doc["hotstrings"]["autocorrection"].Has("caps"))
		AssertFalse(Doc["hotstrings"]["autocorrection"]["names"].Has("enabled"))
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length)
	} finally DirDelete(Dir, true)
}
Test("config unused keys: inline feature children boot ignores are offered and removed "
	. "(config-unused-keys-semantic-shapes)", _CUK_InlineFeatureChildrenAreOffered)

_CUK_SectionDottedLeafIsReallyRemoved() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteSemanticSubject(Dir, "[metrics]`nenabled = true`nold.flag = true`n")
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		_CUK_AssertIds("metrics.old.flag=section", Scan["keys"])
		AssertEqual("metrics.old", Scan["keys"][1]["section"], "the row names the semantic table, not a dotted key")
		AssertEqual("flag", Scan["keys"][1]["key"])
		Result :=ConfigUnusedKeysRemove(Path, Scan["keys"], "20990101-000402")
		AssertEqual("removed", Result["status"])
		Doc := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Doc["metrics"].Has("old"), "a reported removal must change the source")
		AssertEqual(true, Doc["metrics"]["enabled"].Value)
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length)
	} finally DirDelete(Dir, true)
}
Test("config unused keys: a dotted leaf inside a section is offered by its real path and removed "
	. "(config-unused-keys-semantic-shapes)", _CUK_SectionDottedLeafIsReallyRemoved)

; A preview row that names no record of the current source cannot be removed;
; reporting "removed" for an unchanged file hid the defect above.
_CUK_AbsentPreviewPathIsNeverRemoved() {
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteSemanticSubject(Dir, "[metrics]`nenabled = true`n")
		Source := FSReadUtf8Exact(Path)
		Stamp := "20990101-000403"
		Entry := Map("section", "metrics", "key", "absent_leaf", "kind", "leaf", "value", "1")
		Result := ConfigUnusedKeysRemove(Path, [Entry], Stamp)
		AssertEqual("changed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(ConfigUnusedKeysBackupPath(Path, Stamp)), "nothing to remove needs no backup")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: a preview row absent from the source is never reported removed "
	. "(config-unused-keys-semantic-shapes)", _CUK_AbsentPreviewPathIsNeverRemoved)

; A live physical keyboard slot keeps a scan-code spelling (win_SC03A). Its
; action parameter failed the lowercase grammar of the parameter owner, so the
; cleanup offered a live parameter for deletion (keyboard-slot-publication).
_CUK_PhysicalKeyboardSlotParameterIsOwned() {
	Live := "keyboard__win_SC03A__open_url"
	AssertEqual("current", TomlConfigActionParameterBindingStatus(Live), "control: the slot is published")
	AssertTrue(TomlConfigActionParameterIsOwned(Live))
	AssertEqual("keyboard", ConfigScopeActionParameterDomain("action_parameters." . Live))
	Tree := ManifestBuildFeaturesMap()
	AssertEqual("", TomlConfigUnknownKind(Tree, "action_parameters", Live, &Owner))
	AssertEqual("Gestures", Owner)
	AssertFalse(TomlConfigActionParameterIsOwned("keyboard__win_SC0FF__open_url"), "an unpublished scan stays retired")
	AssertFalse(TomlConfigActionParameterIsOwned("keyboard__win_SC03A__no_such_action"))
	AssertFalse(TomlConfigActionParameterIsOwned("keyboard__win_SC03A__Open_url"), "the action keeps its exact spelling")
	AssertFalse(TomlConfigActionParameterIsOwned("gesture__Swipe_up__open_url"),
		"an unpublished domain keeps the lowercase grammar")
	Dir := _CUK_NewDir()
	try {
		Path := _CUK_WriteSemanticSubject(Dir, "[action_parameters]`n" . Live . ' = "https://example.invalid/"`n')
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		AssertEqual(0, Scan["keys"].Length, "a live slot parameter is never offered")
	} finally DirDelete(Dir, true)
}
Test("config unused keys: a physical keyboard slot parameter belongs to the gesture owner "
	. "(keyboard-slot-publication)", _CUK_PhysicalKeyboardSlotParameterIsOwned)

#Include test_config_cleanup_refresh_lifecycle.ahk
