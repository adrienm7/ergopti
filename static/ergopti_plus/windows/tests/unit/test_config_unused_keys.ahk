; tests/unit/test_config_unused_keys.ahk

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

_CUK_WriteFixture(Dir) {
	global _CUK_FIXTURE
	Path := Dir . "\config.toml"
	AssertTrue(FSWriteDurable(Path, _CMJFixtureCurrentSource(StrReplace(_CUK_FIXTURE, "`r`n", "`n"))),
		"the fixture config must be written")
	ConfigMigrateBoot(Path)
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


; The physical fixture is exclusively owned, including its verified backups.
_CUK_RetiredNewDir() {
	static Sequence := 0
	Sequence += 1
	Folder := A_Temp . "\ergopti_retired_cleanup_" . A_ScriptHwnd
		. "_" . A_TickCount . "_" . Sequence
	AssertTrue(DllCall("CreateDirectoryW", "Str", Folder, "Ptr", 0, "Int"),
		"the fixture must exclusively own its native directory")
	return Folder
}

_CUK_RetiredRows(Scan) {
	AssertEqual("ok", Scan["status"])
	Rows := []
	for Entry in Scan["keys"] {
		if _ConfigUnusedKeysRetiredSection(Entry["section"])
			Rows.Push(Entry)
	}
	return Rows
}

_CUK_RetiredPrefixActualCleanup() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Retired := "# Retired namespace preview.`n[ahk]`n`n"
		. "[ahk.layout]`nflag = true`n`n"
		. "[ahk.layout.deep]`n" . 'label = "retain until cleanup"' . "`n`n"
		. "[ahk.empty]`n`n"
	Kept := "[_meta]`nschema_version = 11`n`n"
		. "[updater]`n" . 'channel = "stable"' . "`n`n"
		. "[hotstrings.personal.mine]`nenabled = true`n`n"
		. '["ahk.foo"]' . "`n" . 'keep = "literal"' . "`n`n"
		. "[AHK.layout]`n" . 'keep = "case"' . "`n`n"
		. "[future_extension]`nkeep = 42 # preserve exact comment`n"
	Source := Retired . Kept
	Expected := Chr(0xFEFF) . "# Retired namespace preview.`n`n`n`n`n" . Kept
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		_CUK_AssertIds("ahk.=section|ahk.layout.flag=section|ahk.layout.deep.label=section|ahk.empty.=section",
			Rows)
		RootRow := _CUK_RequireId(Rows, "ahk.=section")
		EmptyRow := _CUK_RequireId(Rows, "ahk.empty.=section")
		AssertTrue(RootRow["section_only"] is Integer)
		AssertEqual(1, RootRow["section_only"])
		AssertTrue(EmptyRow["section_only"] is Integer)
		AssertEqual(1, EmptyRow["section_only"])
		AssertEqual(Source, FSReadUtf8Exact(Path), "scanning never accepts cleanup")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000201", 0, 0, Source)
		AssertEqual("removed", Result["status"])
		AssertEqual(4, Result["removed"])
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]),
			"the actual native backup contains the exact preview generation")
		AssertEqual(Expected, FSReadUtf8Exact(Path),
			"actual semantic cleanup drops only explicitly offered retired identities")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Document.Has("ahk"))
		AssertEqual("literal", Document["ahk.foo"]["keep"])
		AssertEqual("case", Document["AHK"]["layout"]["keep"])
		AssertEqual("stable", Document["updater"]["channel"])
		AssertEqual(11, Document["_meta"]["schema_version"])
		AssertTrue(Document["hotstrings"]["personal"]["mine"]["enabled"] is TOML_Bool)
		AssertEqual(true, Document["hotstrings"]["personal"]["mine"]["enabled"].Value)
		AssertEqual(42, Document["future_extension"]["keep"])
		AssertEqual(0, _CUK_RetiredRows(ConfigUnusedKeysFind(Path)).Length)
	} finally DirDelete(Folder, true)
}
Test("config cleanup: actual retired prefix removal preserves reserved literal and case twins "
	. "(config-retired-explicit-cleanup)", _CUK_RetiredPrefixActualCleanup)

_CUK_RetiredEmptyTablesActualCleanup() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk]`n`n[ahk.empty]`n`n[updater]`n" . 'channel = "stable"' . "`n"
	Expected := Chr(0xFEFF) . "`n`n[updater]`n" . 'channel = "stable"' . "`n"
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual("ahk.=section|ahk.empty.=section", _CUK_Join(_CUK_Ids(Rows)))
		AssertEqual("{}", Rows[1]["value"])
		AssertTrue(_ConfigUnusedKeysSectionOnly(Rows[1]))
		AssertTrue(_ConfigUnusedKeysSectionOnly(Rows[2]))
		Session := ConfigCleanupSession(Path)
		try {
			AssertEqual("ready", Session.Handle("ready")["status"])
			Page := JsonParse(Session.Json())
			AssertEqual(2, Page["keys"].Length)
			AssertEqual("", Page["keys"][1]["key"])
			AssertEqual("{}", Page["keys"][1]["value"])
			AssertFalse(Page["keys"][1].Has("section_only"),
				"the private whole-section authorization never enters the page contract")
			Result := Session.Handle(Map("action", "clean", "session", Session.Token))
			AssertEqual("removed", Result["status"])
			AssertEqual(2, Result["removed"])
			AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
			AssertEqual(Expected, FSReadUtf8Exact(Path))
		} finally Session.Close()
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length)
	} finally DirDelete(Folder, true)
}
Test("config cleanup: empty retired tables use real preview backup and semantic deletion "
	. "(config-retired-explicit-cleanup)", _CUK_RetiredEmptyTablesActualCleanup)

_CUK_RetiredEmptyTableCannotOwnLateChild(ChildSource) {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk]`n`n[updater]`n" . 'channel = "stable"' . "`n"
	Concurrent := Source . ChildSource
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		AssertTrue(_ConfigUnusedKeysSectionOnly(Rows[1]))
		AssertEqual(1, FSWriteDurable(Path, Concurrent))
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000202")
		AssertEqual("changed", Result["status"],
			"a direct old empty-table scan cannot own an unlisted semantic child")
		AssertEqual(0, Result["removed"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "refusal precedes backup and publication")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000203", 0, 0, Source)
		AssertEqual("changed", Result["status"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "stale preview bytes cannot authorize any transaction")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: retired empty-table preview cannot own late descendants or stale bytes "
	. "(config-retired-explicit-cleanup)",
	_CUK_RetiredEmptyTableCannotOwnLateChild.Bind("`n[ahk.late]`nflag = true`n"))
Test("config cleanup: retired empty-table preview cannot own an unlisted empty child header "
	. "(config-retired-explicit-cleanup)",
	_CUK_RetiredEmptyTableCannotOwnLateChild.Bind("`n[ahk.late]`n"))

_CUK_RetiredBackupRaceUsesExactSource() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk.layout]`nflag = true`n`n[future_extension]`nkeep = 42`n"
	Concurrent := "[ahk.layout]`nflag = true`n`n[future_extension]`nkeep = 43`n"
	Seen := Map("backup_calls", 0, "lease_blocked", false)
	Backup(Target, Content) {
		Seen["backup_calls"] += 1
		Owner := _ConfigWriteLeaseTryAcquire(Path, "foreign-backup-probe")
		Seen["lease_blocked"] := !(Owner is Object)
		if Owner is Object
			_ConfigWriteLeaseRelease(Owner)
		Written := FSWriteCreateDurable(Target, Content)
		if !(Written is Integer) || Written != 1
			return Written
		Changed := FSWriteDurable(Path, Concurrent)
		if !(Changed is Integer) || Changed != 1
			throw Error("the actual native fixture could not publish its foreign source generation")
		return Written
	}
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000204", Backup, 0, Source)
		AssertEqual("write_failed", Result["status"],
			"the actual default writer must refuse a source changed during verified backup")
		AssertEqual(0, Result["removed"])
		AssertEqual(1, Seen["backup_calls"])
		AssertTrue(Seen["lease_blocked"], "one source lease spans native backup and publication refusal")
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(Concurrent, FSReadUtf8Exact(Path),
			"a foreign generation remains byte-exact, including its retired entries")
		Owner := _ConfigWriteLeaseTryAcquire(Path, "post-cleanup-probe")
		try AssertTrue(Owner is Object, "refusal must release its original source lease")
		finally {
			if Owner is Object
				_ConfigWriteLeaseRelease(Owner)
		}
	} finally DirDelete(Folder, true)
}
Test("config cleanup: actual default writer binds the exact verified backup generation "
	. "(config-retired-backup-source-race)", _CUK_RetiredBackupRaceUsesExactSource)

_CUK_RetiredUnsupportedProjection(Source, Mode) {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		; These requests have no privately captured whole-root capability. Actual
		; typed producers are qualified separately; metadata cannot substitute.
		switch Mode {
			case "unproven": Rows := [Map("section", "ahk", "key", "layout.flag", "kind", "section", "value", "true")]
			case "forged": Rows := [Map("section", "ahk", "key", "", "kind", "section", "value", "{}", "retired_root_receipt", Map())]
			case "partial": Rows := [Map("section", "ahk.items", "key", "flag", "kind", "section", "value", "true")]
			default: throw ValueError("Unknown unsupported root fixture")
		}
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000300", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"],
			"an unproved flat retired projection cannot manufacture whole-section authorization")
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "refusal precedes backup and publication")
		AssertFalse(ConfigUnusedKeysOffer(Path, (*) => Map("status", "unsupported", "keys", []), (*) => false))
		AssertEqual(Source, FSReadUtf8Exact(Path))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: retired dotted assignments refuse unproved flat ownership (config-retired-unsupported)",
	_CUK_RetiredUnsupportedProjection.Bind("[ahk]`nlayout.flag = true`n", "unproven"))
Test("config cleanup: retired inline root refuses forged whole-root authority (config-retired-unsupported)",
	_CUK_RetiredUnsupportedProjection.Bind("ahk = {layout = {flag = true}}`n", "forged"))
Test("config cleanup: retired table-array generations refuse partial flat ownership (config-retired-unsupported)",
	_CUK_RetiredUnsupportedProjection.Bind("[[ahk.items]]`nflag = true`n", "partial"))

_CUK_RetiredWarningAndRuntimeNeutrality() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[ahk.layout]`nergopti_base = true`n"
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		AssertEqual(0, ApplyConfigToml(Target, Path, &Rejected))
		AssertEqual(0, Rejected)
		AssertEqual(false, Target["layout"]["ergopti_base"])
		Errors := 0, Named := 0
		for Line in Lines {
			if InStr(Line, "[ERROR]")
				Errors += 1
			if InStr(Line, "[WARNING]") && InStr(Line, "obsolete [ahk.*]")
					&& InStr(Line, "remain until explicit cleanup")
				Named += 1
			AssertFalse(InStr(Line, "next canonical save removes") > 0)
		}
		AssertEqual(0, Errors)
		AssertEqual(1, Named)
		AssertEqual(Source, FSReadUtf8Exact(Path), "the warning never performs cleanup")
		AssertEqual(1, _CUK_RetiredRows(ConfigUnusedKeysFind(Path)).Length)
	} finally {
		LoggerClearTestSink()
		DirDelete(Folder, true)
	}
}
Test("config cleanup: retired entries warn truthfully remain runtime neutral and await explicit cleanup "
	. "(config-retired-explicit-cleanup)", _CUK_RetiredWarningAndRuntimeNeutrality)


_CUK_RetiredCaseTwinScanIsIndependent() {
	Folder := _CUK_RetiredNewDir()
	Path := Folder . "\config.toml"
	Source := "[AHK.layout]`nflag = true`n"
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"],
			"a differently cased source segment cannot enter retired-prefix admission")
		AssertEqual(0, Scan["keys"].Length,
			"the existing skipped case twin must not be manufactured into retired cleanup ownership")
		AssertEqual(Source, FSReadUtf8Exact(Path))
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Document.Has("ahk"))
		AssertTrue(Document.Has("AHK"))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: differently cased source segment never enters retired admission "
	. "(config-retired-case-identity)", _CUK_RetiredCaseTwinScanIsIndependent)

; Independent whole source images; the production renderer never creates these expectations.
_CUK_RetiredRootVector(Kind) {
	switch Kind {
		case "dotted":
			Source := "# retired dotted root`n" . 'ahk.layout.flag = true' . "`n"
				. 'ahk.layout.label = "retired"' . "`n`n"
		case "inline":
			Source := "# retired inline root`n" . 'ahk = {layout = {flag = true}, items = [{id = "a"}, {id = "b"}]}' . "`n`n"
		case "array":
			Source := "# retired array root`n[[ahk.items]]`nflag = true`n"
				. 'id = "first"' . "`n[[ahk.items]]`nflag = 0`n" . 'id = "second"' . "`n`n"
		default: throw ValueError("Unknown retired root fixture")
	}
	Root := "# exact root neighbors`n" . '"ahk.literal" = {keep = "literal", empty = []} # root comment' . "`n"
		. 'AHK = {keep = "case", flag = false}' . "`n`n"
	Tables := "[_meta]`nschema_version = 11`n`n[updater]`n" . 'channel = "stable" # updater comment' . "`n`n"
		. "[hotstrings.personal.mine]`nenabled = true`ntime_activation_seconds = 0.75`n`n"
		. "[_future]`nflag = false`nzero = 0`nvalues = [1, 2]`nempty = []`n"
		. "stamp = 2026-10-05T10:20:30Z`n" . '"literal.dot" = "keep" # exact future comment' . "`n"
	return Map("source", Root . Source . Tables,
		"expected", Chr(0xFEFF) . Root . "# retired " . Kind . " root`n`n" . Tables)
}

_CUK_RetiredRootTypedNeighbors(Document) {
	AssertFalse(Document.Has("ahk"), "only the exact retired root is gone")
	AssertEqual("literal", Document["ahk.literal"]["keep"])
	AssertTrue(Document["ahk.literal"]["empty"] is Array)
	AssertEqual(0, Document["ahk.literal"]["empty"].Length)
	AssertEqual("case", Document["AHK"]["keep"])
	AssertTrue(Document["AHK"]["flag"] is TOML_Bool)
	AssertEqual(false, Document["AHK"]["flag"].Value)
	AssertEqual(11, Document["_meta"]["schema_version"])
	AssertEqual("stable", Document["updater"]["channel"])
	AssertTrue(Document["hotstrings"]["personal"]["mine"]["enabled"] is TOML_Bool)
	AssertEqual(true, Document["hotstrings"]["personal"]["mine"]["enabled"].Value)
	AssertEqual(0.75, Document["hotstrings"]["personal"]["mine"]["time_activation_seconds"])
	AssertTrue(Document["_future"]["flag"] is TOML_Bool)
	AssertEqual(false, Document["_future"]["flag"].Value)
	AssertTrue(Document["_future"]["zero"] is Integer)
	AssertFalse(Document["_future"]["zero"] is TOML_Bool)
	AssertEqual(0, Document["_future"]["zero"])
	Values := Document["_future"]["values"]
	AssertTrue(Values is Array, "the unrelated future array keeps its native shape")
	AssertEqual(2, Values.Length, "both unrelated numeric elements survive cleanup")
	AssertTrue(Values[1] is Integer)
	AssertTrue(Values[2] is Integer)
	AssertEqual(1, Values[1], "the first independently supplied element is retained")
	AssertEqual(2, Values[2], "the second independently supplied element is retained")
	AssertEqual("1|2", _CUK_Join(Values), "the existing diagnostic joiner uses a pipe separator")
	AssertTrue(Document["_future"]["empty"] is Array)
	AssertEqual(0, Document["_future"]["empty"].Length)
	AssertEqual("2026-10-05T10:20:30Z", Document["_future"]["stamp"])
	AssertEqual("keep", Document["_future"]["literal.dot"])
}

_CUK_RetiredRootActualCleanup(Kind) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector(Kind), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length, "the complete retired namespace is one explicit native preview")
		if Rows.Length != 1
			return
		Entry := Rows[1]
		AssertEqual("ahk", Entry["section"])
		AssertEqual("", Entry["key"])
		AssertEqual("section", Entry["kind"])
		AssertEqual("_ConfigUnusedKeysRetiredRootReceipt", Type(Entry["retired_root_receipt"]))
		AssertFalse(_ConfigUnusedKeysSectionOnly(Entry), "a whole root is not an empty-table marker")
		AssertEqual(Source, FSReadUtf8Exact(Path), "collection never accepts cleanup")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000301", 0, 0, Source)
		AssertEqual("removed", Result["status"])
		AssertEqual(1, Result["removed"])
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(Vector["expected"], FSReadUtf8Exact(Path), "independent complete physical image")
		_CUK_RetiredRootTypedNeighbors(TOML_ParseDocument(FSReadUtf8Exact(Path)))
		AssertEqual(0, _CUK_RetiredRows(ConfigUnusedKeysFind(Path)).Length)
	} finally DirDelete(Folder, true)
}
Test("config cleanup: privately captured root dotted namespace uses actual verified publication (config-retired-root)",
	_CUK_RetiredRootActualCleanup.Bind("dotted"))
Test("config cleanup: privately captured inline namespace uses actual verified publication (config-retired-root)",
	_CUK_RetiredRootActualCleanup.Bind("inline"))
Test("config cleanup: privately captured table-array root removes all exact generations (config-retired-root)",
	_CUK_RetiredRootActualCleanup.Bind("array"))

_CUK_RetiredRootPrivatePage() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("array")
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Vector["source"]))
		Session := ConfigCleanupSession(Path)
		try {
			Status := Session.Handle("ready")["status"]
			AssertEqual("ready", Status)
			if Status != "ready"
				return
			Page := JsonParse(Session.Json())
			AssertEqual(1, Page["keys"].Length)
			if Page["keys"].Length != 1
				return
			AssertEqual(3, Page["keys"][1].Count, "only descriptive source fields reach the page")
			AssertFalse(Page["keys"][1].Has("retired_root_receipt"))
			AssertFalse(Page["keys"][1].Has("Source"))
			AssertFalse(Session.Handle(Map("action", "clean", "session", "foreign")))
			AssertEqual(Vector["source"], FSReadUtf8Exact(Path))
			Result := Session.Handle(Map("action", "clean", "session", Session.Token,
				"keys", [Map("section", "updater", "key", "channel")]))
			AssertEqual("removed", Result["status"], "page metadata cannot choose another removal")
			AssertEqual(Vector["source"], FSReadUtf8Exact(Result["backup"]))
			AssertEqual(Vector["expected"], FSReadUtf8Exact(Path))
			AssertFalse(Session.Handle(Map("action", "clean", "session", Session.Token)))
		} finally Session.Close()
	} finally DirDelete(Folder, true)
}
Test("config cleanup: actual host keeps the complete retired source receipt private and action-only (config-retired-root)",
	_CUK_RetiredRootPrivatePage)

_CUK_RetiredRootRefusesMutation(Field, Replacement) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("inline"), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		if Field == "extra"
			Rows[1]["forged"] := Replacement
		else if Field == "case_sense" {
			Fields := Rows[1].Clone()
			Rows[1].Clear()
			Rows[1].CaseSense := Replacement
			for Name, Value in Fields
				Rows[1][Name] := Value
		}
		else if Field == "field_case" {
			Rows[1].Delete("section")
			Rows[1]["Section"] := Replacement
		} else
			Rows[1][Field] := Replacement
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000302", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "same-object metadata mutation refuses before backup")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: a same-map section mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("section", "AHK"))
Test("config cleanup: a same-map key mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("key", "layout"))
Test("config cleanup: a same-map kind mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("kind", "leaf"))
Test("config cleanup: a same-map display-value mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("value", "{}"))
Test("config cleanup: a same-map value type mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("value", 1))
Test("config cleanup: extra same-map metadata cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("extra", true))
Test("config cleanup: native map case-policy mutation cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("case_sense", "Off"))
Test("config cleanup: renamed native metadata fields cannot borrow root proof (config-retired-root)",
	_CUK_RetiredRootRefusesMutation.Bind("field_case", "ahk"))

_CUK_RetiredRootRefusesBorrowedRecord(Mode) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml", Foreign := Folder . "\other.toml"
	Vector := _CUK_RetiredRootVector("array"), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		if Mode == "clone"
			Rows := [Rows[1].Clone()]
		else if Mode == "duplicate"
			Rows.Push(Rows[1])
		else {
			AssertEqual(1, FSWriteCreateDurable(Foreign, Source))
			Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Foreign))
		}
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000303", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertEqual(0, Result["removed"])
		AssertFalse(FileExist(Result["backup"]), "a borrowed object or file receipt refuses before backup")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: a cloned native row cannot borrow an original root receipt (config-retired-root)",
	_CUK_RetiredRootRefusesBorrowedRecord.Bind("clone"))
Test("config cleanup: equal bytes at another file cannot borrow root authority (config-retired-root)",
	_CUK_RetiredRootRefusesBorrowedRecord.Bind("foreign"))

_CUK_RetiredRootRefusesStaleSource() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("dotted"), Source := Vector["source"]
	Concurrent := StrReplace(Source, '"literal.dot" = "keep"', '"literal.dot" = "later"')
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		AssertEqual(1, FSWriteDurable(Path, Concurrent))
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000304")
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]), "an unchanged retired root cannot borrow changed foreign source")
		Fresh := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		Result := ConfigUnusedKeysRemove(Path, Fresh, "20990101-000305", 0, 0, Concurrent)
		AssertEqual("removed", Result["status"])
		AssertEqual(Concurrent, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(StrReplace(Vector["expected"], '"literal.dot" = "keep"', '"literal.dot" = "later"'), FSReadUtf8Exact(Path))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: stale whole-file source refuses before backup and fresh retry owns later neighbors (config-retired-root)",
	_CUK_RetiredRootRefusesStaleSource)

_CUK_RetiredRootRefusesReuse() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("inline"), Source := Vector["source"]
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, Rows, "20990101-000306", 0, 0, Source)["status"])
		AssertEqual(1, FSWriteDurable(Path, Source), "even byte-identical restoration cannot revive consumed authority")
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000307", 0, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertFalse(FileExist(Result["backup"]))
		Fresh := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, Fresh, "20990101-000308", 0, 0, Source)["status"])
		AssertEqual(Vector["expected"], FSReadUtf8Exact(Path))
	} finally DirDelete(Folder, true)
}
Test("config cleanup: consumed root authority cannot be replayed after byte-identical external restoration (config-retired-root)",
	_CUK_RetiredRootRefusesReuse)

_CUK_RetiredRootMutationDuringBackup(Mode) {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("array"), Source := Vector["source"]
	Rows := [], Seen := Map("calls", 0)
	Backup(Target, Content) {
		Seen["calls"] += 1
		Written := FSWriteCreateDurable(Target, Content)
		switch Mode {
			case "collection": Rows.RemoveAt(1)
			case "receipt": Rows[1].Delete("retired_root_receipt")
			case "field": Rows[1]["key"] := "items"
			default: throw ValueError("Unknown backup mutation fixture")
		}
		return Written
	}
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000309", Backup, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(1, Seen["calls"])
		AssertEqual(Source, FSReadUtf8Exact(Path))
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]), "an existing verified backup cannot grant later metadata authority")
	} finally DirDelete(Folder, true)
}
Test("config cleanup: backup-time same-map mutation refuses before source publication (config-retired-root)",
	_CUK_RetiredRootMutationDuringBackup.Bind("field"))
Test("config cleanup: backup-time preview collection mutation refuses before source publication (config-retired-root)",
	_CUK_RetiredRootMutationDuringBackup.Bind("collection"))

Test("config cleanup: backup-time removal of private receipt refuses before source publication (config-retired-root)",
	_CUK_RetiredRootMutationDuringBackup.Bind("receipt"))

_CUK_RetiredRootBackupSourceRace() {
	Folder := _CUK_RetiredNewDir(), Path := Folder . "\config.toml"
	Vector := _CUK_RetiredRootVector("array"), Source := Vector["source"]
	Concurrent := StrReplace(Source, '"literal.dot" = "keep"', '"literal.dot" = "later"')
	Seen := Map("calls", 0, "lease_blocked", false)
	Backup(Target, Content) {
		Seen["calls"] += 1
		Owner := _ConfigWriteLeaseTryAcquire(Path, "foreign-root-backup-probe")
		Seen["lease_blocked"] := !(Owner is Object)
		if Owner is Object
			_ConfigWriteLeaseRelease(Owner)
		Written := FSWriteCreateDurable(Target, Content)
		if !(Written is Integer) || Written != 1
			return Written
		Changed := FSWriteDurable(Path, Concurrent)
		if !(Changed is Integer) || Changed != 1
			throw Error("The native root fixture could not publish its foreign source generation")
		return Written
	}
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Rows := _CUK_RetiredRows(ConfigUnusedKeysFind(Path))
		AssertEqual(1, Rows.Length)
		if Rows.Length != 1
			return
		Result := ConfigUnusedKeysRemove(Path, Rows, "20990101-000310", Backup, 0, Source)
		AssertEqual("write_failed", Result["status"])
		AssertEqual(0, Result["removed"])
		AssertEqual(1, Seen["calls"])
		AssertTrue(Seen["lease_blocked"])
		AssertEqual(Source, FSReadUtf8Exact(Result["backup"]))
		AssertEqual(Concurrent, FSReadUtf8Exact(Path), "the native default writer preserves the later full source")
		AssertFalse(Rows[1]["retired_root_receipt"].Consumed, "refused publication does not consume source authority")
		Owner := _ConfigWriteLeaseTryAcquire(Path, "post-root-cleanup-probe")
		try AssertTrue(Owner is Object)
		finally {
			if Owner is Object
				_ConfigWriteLeaseRelease(Owner)
		}
	} finally DirDelete(Folder, true)
}
Test("config cleanup: root capability retains the native exact-source and lease fence through backup (config-retired-root)",
	_CUK_RetiredRootBackupSourceRace)

Test("config cleanup: selecting the same whole-root receipt twice refuses before backup (config-retired-root)",
	_CUK_RetiredRootRefusesBorrowedRecord.Bind("duplicate"))


_CUK_RetiredGestureBindingOwnership() {
	Target := ManifestBuildFeaturesMap()
	Owner := ""
	AssertEqual("section", TomlConfigUnknownKind(Target, "action_parameters", "gesture__removed_gesture_slot__open_url", &Owner))
	AssertEqual("", Owner, "retirement never gets a foreign ownership exemption")
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("gesture__removed_gesture_slot__open_url"))
	for Slot in GestureSlotIds() {
		Key := GestureBindingId("gesture", Slot) . "__open_url"
		AssertEqual("", TomlConfigUnknownKind(Target, "action_parameters", Key, &Owner), Slot)
		AssertEqual("Gestures", Owner, Slot)
	}
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("gesture__TAP_3__open_url"))
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("Gesture__tap_3__open_url"))
}
Test("config: retired native gesture parameters share boot and cleanup ownership (gesture-binding-identity-ownership)",
	_CUK_RetiredGestureBindingOwnership)

_CUK_RetiredGestureWarningOwnership() {
	Dir := _CUK_NewDir()
	try {
		Path := Dir . "\config.toml"
		Key := "gesture__removed_gesture_slot__open_url"
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, Key), "first report uses the config.toml owner")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Key), "duplicate boot/reload report is suppressed")
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, "gesture__another_removed_slot__open_url"), "another retired row is independently named")
	} finally DirDelete(Dir, true)
}
Test("config: retired gesture warnings deduplicate in the config.toml owner (gesture-binding-identity-warning)",
	_CUK_RetiredGestureWarningOwnership)

_CUK_RetiredGestureBindingsPreserveWholeSource() {
	global ConfigurationFile, GestureActionParameters, GestureAssignments, _IniCache, _ConfigBootRejectedOverrides
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	PreviousParameters := GestureActionParameters
	PreviousAssignments := GestureAssignments.Clone()
	PreviousCache := _IniCache
	PreviousRejected := _ConfigBootRejectedOverrides
	Dir := _CUK_NewDir()
	Known := "gesture__tap_3__open_url"
	Twin := "Gesture__tap_3__open_url"
	Retired := "gesture__removed_gesture_slot__open_url"
	ParameterSource := "[action_parameters]`n"
		. Retired . ' = "https://obsolete.example" # explicit cleanup owns this row' . "`n"
		. Known . ' = "https://known.example"' . "`n"
		. Twin . ' = "https://unjudged.example"' . "`n"
		. 'keyboard__ctrl_k__open_url = "https://keyboard.example"' . "`n"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n# independent user comment`n" . ParameterSource
		. "`n[future]`nkeep = " . Chr(34) . "independent" . Chr(34) . "`n"
		. "`n[layout]`nergopti_base = true`n"
	try {
		Path := Dir . "\config.toml"
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWriteDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		ApplyConfigToml(Target, Path, &Rejected)
		AssertEqual(0, Rejected, "known retirement is never a schema/native rejection")
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertFalse(GestureActionParameters.Has(Retired))
		AssertEqual("https://known.example", GestureGetActionParameter("gesture__tap_3", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual(3, GestureActionParameters.Count, "both case twins and the other owner remain independent")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Retired), "actual boot and direct reload share one report identity")
		AssertEqual(Source, FSReadUtf8Exact(Path), "admission does not rewrite the source")
		Scan := ConfigUnusedKeysFind(Path)
		RetiredRows := []
		for Entry in Scan["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				RetiredRows.Push(Entry)
		}
		AssertEqual(1, RetiredRows.Length, "the ignored known-retired row is offered exactly once")

		; The preserved unjudged prefix cannot activate a canonical gesture.
		OtherPath := Dir . "\unjudged-only.toml"
		UpperOnlySource := StrReplace(Source, Known . ' = "https://known.example"' . "`n", "", true)
		AssertTrue(FSWriteDurable(OtherPath, UpperOnlySource))
		_CMJFixtureReadonly(OtherPath)
		ConfigurationFile := OtherPath
		_IniCache := ParseConfigTomlFile(OtherPath)
		GesturesReadConfig()
		AssertEqual("", GestureGetActionParameter("gesture__tap_3", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual("On", GestureActionParameters.Clone().CaseSense)
		AssertEqual(UpperOnlySource, FSReadUtf8Exact(OtherPath))
		ConfigurationFile := Path
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertTrue(GestureSetActionParameter("gesture__tap_3", "open_url", "https://changed.example"))
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertEqual("https://changed.example", GestureActionParameters[Known])
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		BeforeRefusal := FSReadUtf8Exact(Path)
		AssertFalse(GestureSetActionParameter("gesture__removed_gesture_slot", "open_url", "https://must-not-publish.example"))
		AssertEqual(BeforeRefusal, FSReadUtf8Exact(Path), "ordinary refusal preserves exact persisted bytes")
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0,
			() => [{ Section: "layout", Key: "ergopti_base", Value: false }]))
		Saved := FSReadUtf8Exact(Path)
		AssertContains(Saved, Retired . ' = "https://obsolete.example" # explicit cleanup owns this row')
		AssertContains(Saved, "# independent user comment")
		Parsed := ConfigTomlDecodeSnapshot(Saved).Document
		AssertEqual(4, Parsed["action_parameters"].Count, "complete handwritten preserved parameter model")
		AssertEqual("https://obsolete.example", Parsed["action_parameters"][Retired])
		AssertEqual("https://changed.example", Parsed["action_parameters"][Known])
		AssertEqual("https://unjudged.example", Parsed["action_parameters"][Twin])
		AssertEqual("https://keyboard.example", Parsed["action_parameters"]["keyboard__ctrl_k__open_url"])
		AssertEqual("independent", Parsed["future"]["keep"])

		FreshRows := []
		for Entry in ConfigUnusedKeysFind(Path)["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				FreshRows.Push(Entry)
		}
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, FreshRows, "20990101-000176")["status"])
		AfterCleanup := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Document
		AssertFalse(AfterCleanup["action_parameters"].Has(Retired), "only explicit cleanup removes retirement")
		AssertEqual("https://changed.example", AfterCleanup["action_parameters"][Known])
		AssertEqual("https://unjudged.example", AfterCleanup["action_parameters"][Twin])
	} finally {
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		GestureActionParameters := PreviousParameters
		GestureAssignments := PreviousAssignments
		_IniCache := PreviousCache
		DirDelete(Dir, true)
	}
}
Test("config: retired gesture source survives native reload, ordinary edit and full save until explicit cleanup (gesture-binding-identity-preservation)",
	_CUK_RetiredGestureBindingsPreserveWholeSource)

; Case twins survive canonicalization; count and uniqueness remain assertions.
_CUK_CanonicalIdentityControls() {
	Upper := Map("section", "Layout", "key", "stale", "kind", "section")
	Lower := Map("section", "layout", "key", "stale", "kind", "section")
	_CUK_AssertIds("layout.stale=section|Layout.stale=section", [Upper, Lower])
	_CUK_AssertIds("layout.stale=section|Layout.stale=section", [Lower, Upper])
	AssertEqual(2, _CUK_CanonicalIds(["Layout.stale=section", "layout.stale=section"]).Length,
		"a case twin is a distinct source identity")
	AssertThrows(_CUK_CanonicalIds.Bind(["layout.stale=section", "layout.stale=section"]),
		"canonicalization must refuse duplicates instead of hiding them")
	AssertThrows(_CUK_AssertIds.Bind("layout.stale=section", []),
		"an empty actual preview cannot satisfy a nonempty independent expectation")
	AssertThrows(_CUK_AssertIds.Bind("layout.stale=section", [Upper]),
		"a case near-miss cannot satisfy the expectation")
	AssertThrows(_CUK_AssertIds.Bind("layout.stale=section|Layout.stale=section", [Lower, Lower]),
		"the right row count cannot conceal a duplicate and missing case twin")
	AssertEqual(ObjPtr(Upper), ObjPtr(_CUK_RequireId([Lower, Upper], "Layout.stale=section")),
		"marker checks select the unique semantic source identity")
	AssertThrows(_CUK_RequireId.Bind([], "Layout.stale=section"),
		"a marker lookup must refuse an absent identity")
	AssertThrows(_CUK_RequireId.Bind([Upper, Upper], "Layout.stale=section"),
		"a marker lookup must refuse ambiguous duplicates")
}
Test("config cleanup fixture: canonical identities keep case twins and reject missing or duplicate rows "
	. "(config-unused-keys-identity-controls)", _CUK_CanonicalIdentityControls)


_CUK_RetiredScriptBindingsPreserveWholeSource() {
	_GSBP_WithPublication(_CUK_RetiredScriptBindingsPreserveWholeSourceBody)
}
_CUK_RetiredScriptBindingsPreserveWholeSourceBody() {
	global ConfigurationFile, GestureActionParameters, GestureAssignments, _IniCache, _ConfigBootRejectedOverrides
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	PreviousParameters := GestureActionParameters
	PreviousAssignments := GestureAssignments.Clone()
	PreviousCache := _IniCache
	PreviousRejected := _ConfigBootRejectedOverrides
	Dir := _CUK_NewDir()
	Known := "script__script_altgr_enter__open_url"
	Twin := "Script__script_altgr_enter__open_url"
	Retired := "script__removed_script_slot__open_url"
	ParameterSource := "[action_parameters]`n"
		. Retired . ' = "https://obsolete.example" # explicit cleanup owns this row' . "`n"
		. Known . ' = "https://known.example"' . "`n"
		. Twin . ' = "https://unjudged.example"' . "`n"
		. 'keyboard__ctrl_k__open_url = "https://keyboard.example"' . "`n"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n# independent user comment`n" . ParameterSource
		. "`n[future]`nkeep = " . Chr(34) . "independent" . Chr(34) . "`n"
		. "`n[layout]`nergopti_base = true`n"
	try {
		Path := Dir . "\config.toml"
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWriteDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		ApplyConfigToml(Target, Path, &Rejected)
		AssertEqual(0, Rejected, "known retirement is never a schema/native rejection")
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertFalse(GestureActionParameters.Has(Retired))
		AssertEqual("https://known.example", GestureGetActionParameter("script__script_altgr_enter", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual(3, GestureActionParameters.Count, "both case twins and the other owner remain independent")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Retired), "actual boot and direct reload share one report identity")
		AssertEqual(Source, FSReadUtf8Exact(Path), "admission does not rewrite the source")
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, "script__another_retired_slot__open_url"), "each retired script key has a separate warning identity")
		Scan := ConfigUnusedKeysFind(Path)
		RetiredRows := []
		for Entry in Scan["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				RetiredRows.Push(Entry)
		}
		AssertEqual(1, RetiredRows.Length, "the ignored known-retired row is offered exactly once")

		; The preserved unjudged prefix cannot activate a canonical gesture.
		OtherPath := Dir . "\unjudged-only.toml"
		UpperOnlySource := StrReplace(Source, Known . ' = "https://known.example"' . "`n", "", true)
		AssertTrue(FSWriteDurable(OtherPath, UpperOnlySource))
		_CMJFixtureReadonly(OtherPath)
		ConfigurationFile := OtherPath
		_IniCache := ParseConfigTomlFile(OtherPath)
		GesturesReadConfig()
		AssertEqual("", GestureGetActionParameter("script__script_altgr_enter", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual("On", GestureActionParameters.Clone().CaseSense)
		AssertEqual(UpperOnlySource, FSReadUtf8Exact(OtherPath))
		ConfigurationFile := Path
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertTrue(GestureSetActionParameter("script__script_altgr_enter", "open_url", "https://changed.example"))
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertEqual("https://changed.example", GestureActionParameters[Known])
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		BeforeRefusal := FSReadUtf8Exact(Path)
		AssertFalse(GestureSetActionParameter("script__removed_script_slot", "open_url", "https://must-not-publish.example"))
		AssertEqual(BeforeRefusal, FSReadUtf8Exact(Path), "ordinary refusal preserves exact persisted bytes")
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0,
			() => [{ Section: "layout", Key: "ergopti_base", Value: false }]))
		Saved := FSReadUtf8Exact(Path)
		AssertContains(Saved, Retired . ' = "https://obsolete.example" # explicit cleanup owns this row')
		AssertContains(Saved, "# independent user comment")
		Parsed := ConfigTomlDecodeSnapshot(Saved).Document
		AssertEqual(4, Parsed["action_parameters"].Count, "complete handwritten preserved parameter model")
		AssertEqual("https://obsolete.example", Parsed["action_parameters"][Retired])
		AssertEqual("https://changed.example", Parsed["action_parameters"][Known])
		AssertEqual("https://unjudged.example", Parsed["action_parameters"][Twin])
		AssertEqual("https://keyboard.example", Parsed["action_parameters"]["keyboard__ctrl_k__open_url"])
		AssertEqual("independent", Parsed["future"]["keep"])

		FreshRows := []
		for Entry in ConfigUnusedKeysFind(Path)["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				FreshRows.Push(Entry)
		}
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, FreshRows, "20990101-000276")["status"])
		AfterCleanup := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Document
		AssertFalse(AfterCleanup["action_parameters"].Has(Retired), "only explicit cleanup removes retirement")
		AssertEqual("https://changed.example", AfterCleanup["action_parameters"][Known])
		AssertEqual("https://unjudged.example", AfterCleanup["action_parameters"][Twin])
	} finally {
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		GestureActionParameters := PreviousParameters
		GestureAssignments := PreviousAssignments
		_IniCache := PreviousCache
		DirDelete(Dir, true)
	}
}
Test("config: retired script parameters survive actual reload, edit and full save until cleanup (script-binding-identity)",
	_CUK_RetiredScriptBindingsPreserveWholeSource)

_CUK_RetiredScriptBindingOwnership() {
	_GSBP_WithPublication(_CUK_RetiredScriptBindingOwnershipBody)
}
_CUK_RetiredScriptBindingOwnershipBody() {
	Target := ManifestBuildFeaturesMap()
	Owner := ""
	AssertEqual("section", TomlConfigUnknownKind(Target, "action_parameters", "script__removed_script_slot__open_url", &Owner))
	AssertEqual("", Owner, "obsolete script parameters stay unread")
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("script__removed_script_slot__open_url"))
	for Slot in ["script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"] {
		Key := GestureBindingId("script", Slot) . "__open_url"
		AssertEqual("current", TomlConfigActionParameterBindingStatus(Key), Slot)
		AssertEqual("", TomlConfigUnknownKind(Target, "action_parameters", Key, &Owner), Slot)
		AssertEqual("Gestures", Owner, Slot)
	}
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("Script__script_altgr_enter__open_url"))
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("keyboard__removed_slot__open_url"))
}
Test("config: script boot and cleanup consume the same complete published domain (script-binding-identity)",
	_CUK_RetiredScriptBindingOwnership)

_CUK_RetiredTapBindingsPreserveWholeSource() {
	_GTKP_WithPublication(_CUK_RetiredTapBindingsPreserveWholeSourceBody)
}
_CUK_RetiredTapBindingsPreserveWholeSourceBody() {
	global ConfigurationFile, GestureActionParameters, GestureAssignments, _IniCache, _ConfigBootRejectedOverrides
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator()
	PreviousParameters := GestureActionParameters
	PreviousAssignments := GestureAssignments.Clone()
	PreviousCache := _IniCache
	PreviousRejected := _ConfigBootRejectedOverrides
	Dir := _CUK_NewDir()
	Known := "tap_key__number_row_left__open_url"
	Twin := "Tap_key__number_row_left__open_url"
	Retired := "tap_key__removed_tap_key__open_url"
	ParameterSource := "[action_parameters]`n"
		. Retired . ' = "https://obsolete.example" # explicit cleanup owns this row' . "`n"
		. Known . ' = "https://known.example"' . "`n"
		. Twin . ' = "https://unjudged.example"' . "`n"
		. 'keyboard__ctrl_k__open_url = "https://keyboard.example"' . "`n"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n# independent user comment`n" . ParameterSource
		. "`n[future]`nkeep = " . Chr(34) . "independent" . Chr(34) . "`n"
		. "`n[layout]`nergopti_base = true`n"
	try {
		Path := Dir . "\config.toml"
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		AssertTrue(FSWriteDurable(Path, Source))
		Target := ManifestBuildFeaturesMap()
		_CMJFixtureReadonly(Path)
		ApplyConfigToml(Target, Path, &Rejected)
		AssertEqual(0, Rejected, "known retirement is never a schema/native rejection")
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertFalse(GestureActionParameters.Has(Retired))
		AssertEqual("https://known.example", GestureGetActionParameter("tap_key__number_row_left", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual(3, GestureActionParameters.Count, "both case twins and the other owner remain independent")
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Retired), "actual boot and direct reload share one report identity")
		AssertEqual(Source, FSReadUtf8Exact(Path), "admission does not rewrite the source")
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, "tap_key__another_retired_slot__open_url"), "each retired tap key has a separate warning identity")
		Scan := ConfigUnusedKeysFind(Path)
		RetiredRows := []
		for Entry in Scan["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				RetiredRows.Push(Entry)
		}
		AssertEqual(1, RetiredRows.Length, "the ignored known-retired row is offered exactly once")

		; The preserved unjudged prefix cannot activate a canonical gesture.
		OtherPath := Dir . "\unjudged-only.toml"
		UpperOnlySource := StrReplace(Source, Known . ' = "https://known.example"' . "`n", "", true)
		AssertTrue(FSWriteDurable(OtherPath, UpperOnlySource))
		_CMJFixtureReadonly(OtherPath)
		ConfigurationFile := OtherPath
		_IniCache := ParseConfigTomlFile(OtherPath)
		GesturesReadConfig()
		AssertEqual("", GestureGetActionParameter("tap_key__number_row_left", "open_url"))
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		AssertEqual("On", GestureActionParameters.Clone().CaseSense)
		AssertEqual(UpperOnlySource, FSReadUtf8Exact(OtherPath))
		ConfigurationFile := Path
		_IniCache := ParseConfigTomlFile(Path)
		GesturesReadConfig()
		AssertTrue(GestureSetActionParameter("tap_key__number_row_left", "open_url", "https://changed.example"))
		AssertEqual("On", GestureActionParameters.CaseSense)
		AssertEqual("https://changed.example", GestureActionParameters[Known])
		AssertEqual("https://unjudged.example", GestureActionParameters[Twin])
		BeforeRefusal := FSReadUtf8Exact(Path)
		AssertFalse(GestureSetActionParameter("tap_key__removed_tap_key", "open_url", "https://must-not-publish.example"))
		AssertEqual(BeforeRefusal, FSReadUtf8Exact(Path), "ordinary refusal preserves exact persisted bytes")
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0,
			() => [{ Section: "layout", Key: "ergopti_base", Value: false }]))
		Saved := FSReadUtf8Exact(Path)
		AssertContains(Saved, Retired . ' = "https://obsolete.example" # explicit cleanup owns this row')
		AssertContains(Saved, "# independent user comment")
		Parsed := ConfigTomlDecodeSnapshot(Saved).Document
		AssertEqual(4, Parsed["action_parameters"].Count, "complete handwritten preserved parameter model")
		AssertEqual("https://obsolete.example", Parsed["action_parameters"][Retired])
		AssertEqual("https://changed.example", Parsed["action_parameters"][Known])
		AssertEqual("https://unjudged.example", Parsed["action_parameters"][Twin])
		AssertEqual("https://keyboard.example", Parsed["action_parameters"]["keyboard__ctrl_k__open_url"])
		AssertEqual("independent", Parsed["future"]["keep"])

		FreshRows := []
		for Entry in ConfigUnusedKeysFind(Path)["keys"] {
			if Entry["section"] == "action_parameters" && Entry["key"] == Retired
				FreshRows.Push(Entry)
		}
		AssertEqual("removed", ConfigUnusedKeysRemove(Path, FreshRows, "20990101-000276")["status"])
		AfterCleanup := ConfigTomlDecodeSnapshot(FSReadUtf8Exact(Path)).Document
		AssertFalse(AfterCleanup["action_parameters"].Has(Retired), "only explicit cleanup removes retirement")
		AssertEqual("https://changed.example", AfterCleanup["action_parameters"][Known])
		AssertEqual("https://unjudged.example", AfterCleanup["action_parameters"][Twin])
	} finally {
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		GestureActionParameters := PreviousParameters
		GestureAssignments := PreviousAssignments
		_IniCache := PreviousCache
		DirDelete(Dir, true)
	}
}
Test("config: retired tap parameters survive actual reload, edit and full save until cleanup (tap-binding-identity)",
	_CUK_RetiredTapBindingsPreserveWholeSource)

_CUK_RetiredTapBindingOwnership() {
	_GTKP_WithPublication(_CUK_RetiredTapBindingOwnershipBody)
}
_CUK_RetiredTapBindingOwnershipBody() {
	Target := ManifestBuildFeaturesMap()
	Owner := ""
	AssertEqual("section", TomlConfigUnknownKind(Target, "action_parameters", "tap_key__removed_tap_key__open_url", &Owner))
	AssertEqual("", Owner, "obsolete script parameters stay unread")
	AssertEqual("retired", TomlConfigActionParameterBindingStatus("tap_key__removed_tap_key__open_url"))
	global TAP_KEY_ORDER
	for Slot in TAP_KEY_ORDER {
		Key := GestureBindingId("tap_key", Slot) . "__open_url"
		AssertEqual("current", TomlConfigActionParameterBindingStatus(Key), Slot)
		AssertEqual("", TomlConfigUnknownKind(Target, "action_parameters", Key, &Owner), Slot)
		AssertEqual("Gestures", Owner, Slot)
	}
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("Tap_key__number_row_left__open_url"))
	AssertEqual("unjudged", TomlConfigActionParameterBindingStatus("keyboard__removed_slot__open_url"))
}
Test("config: tap boot and cleanup consume the same complete published domain (tap-binding-identity)",
	_CUK_RetiredTapBindingOwnership)

_CUK_RetiredTapWarningReason() {
	Dir := _CUK_NewDir()
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		Path := Dir . "\config.toml"
		Key := "tap_key__removed_tap_key__open_url"
		Source := '[action_parameters]`n' . Key . ' = "https://obsolete.example"`n'
		AssertTrue(FSWriteDurable(Path, Source))
		AssertTrue(TomlConfigReportRetiredGestureParameter(Path, Key))
		AssertFalse(TomlConfigReportRetiredGestureParameter(Path, Key), "boot and reload share the same tap warning identity")
		Warnings := 0, Errors := 0
		for Line in Lines {
			if InStr(Line, "[ERROR]")
				Errors += 1
			if InStr(Line, "[WARNING]") && InStr(Line, "[TomlConfigLoader]") && InStr(Line, Key) {
				Warnings += 1
				AssertTrue(InStr(Line, ConfigBindingIdentityTapRetiredReason()) > 0, "the actual native logger names the tap-key domain")
				AssertFalse(InStr(Line, "no gesture slot of this build has this name") > 0)
				AssertTrue(InStr(Line, "explicit cleanup") > 0)
			}
		}
		AssertEqual(1, Warnings, "the actual warning route must execute exactly once")
		AssertEqual(0, Errors)
		AssertEqual(Source, FSReadUtf8Exact(Path), "warning policy never edits the retired source")
	} finally {
		LoggerClearTestSink()
		DirDelete(Dir, true)
	}
}
Test("config: retired tap warnings name the actual number-row domain (tap-binding-identity-warning)",
	_CUK_RetiredTapWarningReason)
