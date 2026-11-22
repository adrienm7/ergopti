; tests/unit/core/i18n/test_neutral_value.ahk

; ==============================================================================
; MODULE: Locale Neutral Value Tests
; DESCRIPTION:
; The maintainer's decision of 2026-11-21: the locale's neutral value is the
; absent row ("", the system language, else English). A chosen locale, French
; included, is always written and never deleted as neutral. Before, the
; manifest default was "fr", so the sparse writer deleted a chosen French
; locale and the next start read the system language instead.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLNV_SparseKeepsAChosenFrench() {
	AssertEqual("", ManifestDefaultFor("script.locale"), "the neutral value is the absent row")
	Row := ManifestConfigSparseOperation("script", "locale", "fr")
	AssertFalse(Row.HasOwnProp("Delete"), "a chosen French locale is never deleted as neutral")
	AssertEqual("fr", Row.Value, "it is written")
	AssertTrue(ManifestConfigSparseOperation("script", "locale", "").HasOwnProp("Delete"),
		"only the empty value, the system language, removes the row")
}
Test("locale: a chosen French locale is written, never deleted as neutral (locale-neutral-2026-11-21)",
	_TLNV_SparseKeepsAChosenFrench)

_TLNV_DetectedLanguageIsWrittenWhenChosen() {
	global _I18nLocale, _I18nConfiguredLocale, ConfigurationFile
	HadPath := IsSet(ConfigurationFile), SavedPath := HadPath ? ConfigurationFile : ""
	Saved := {Locale: _I18nLocale, Configured: _I18nConfiguredLocale}
	Fixture := 0
	try {
		Fixture := _ScopeOwnerFixture("[hotstrings]`nenabled = true`n")
		ConfigurationFile := Fixture.path
		; The system language is French and no row is written yet.
		_I18nLocale := "fr", _I18nConfiguredLocale := ""
		Seen := []
		Writer := (Path, Updates) => (Seen.Push(Updates), true)
		Quiet := (*) => 0
		AssertTrue(I18nSetLocale("fr", Writer, Quiet, Quiet), "the choice is saved")
		AssertEqual(1, Seen.Length, "choosing the detected language writes it")
		AssertEqual("locale", Seen[1][1].Key)
		AssertEqual("fr", Seen[1][1].Value)
		AssertEqual("fr", I18nConfiguredLocale(), "the choice is now the configured locale")
		AssertTrue(I18nSetLocale("fr", Writer, Quiet, Quiet))
		AssertEqual(1, Seen.Length, "choosing it again writes nothing")
	} finally {
		_I18nLocale := Saved.Locale, _I18nConfiguredLocale := Saved.Configured
		ConfigurationFile := HadPath ? SavedPath : unset
		if IsObject(Fixture)
			_ScopeOwnerCleanup(Fixture)
	}
}
Test("locale: choosing the detected language writes it (locale-neutral-2026-11-21)",
	_TLNV_DetectedLanguageIsWrittenWhenChosen)

_TLNV_InitReadsTheAbsentRowAsDetected() {
	global _I18nLocale, _I18nConfiguredLocale
	Saved := {Locale: _I18nLocale, Configured: _I18nConfiguredLocale}
	Probe := {Ui: (*) => "de-DE"}
	try {
		I18nInit(Map(), Probe)
		AssertEqual("de", I18nGetLocale(), "an absent row reads the system language")
		AssertEqual("", I18nConfiguredLocale(), "and is no configured choice, so a full save writes none")
		I18nInit(Map("script", Map("locale", "fr")), Probe)
		AssertEqual("fr", I18nGetLocale())
		AssertEqual("fr", I18nConfiguredLocale(), "a written French locale stays the choice")
		I18nInit(Map(), {Ui: (*) => "xx-XX"})
		AssertEqual(Identifiers.Locales.SYSTEM_FALLBACK, I18nGetLocale(), "an unmatched system language is English")
	} finally {
		_I18nLocale := Saved.Locale, _I18nConfiguredLocale := Saved.Configured
	}
}
Test("locale: an absent row is the system language and no choice (locale-neutral-2026-11-21)",
	_TLNV_InitReadsTheAbsentRowAsDetected)

; The full save writes the configured locale, never the detected one.
_TLNV_FullSaveWritesTheChoice() {
	Body := _DriverFuncBody("_ConfigCollectFullSaveUpdates")
	AssertTrue(InStr(Body, 'Key: "locale", Value: I18nConfiguredLocale()') > 0,
		"the full save writes the configured locale")
	AssertEqual(0, InStr(Body, 'Key: "locale", Value: I18nGetLocale()'), "never the detected one")
}
Test("locale: the full save writes the configured locale only (locale-neutral-2026-11-21)",
	_TLNV_FullSaveWritesTheChoice)

; The maintainer's decision of 2026-11-22: a locale chosen while config.toml
; does not exist creates the file with the locale row. Windows already did
; through its configuration writer (the boot creates the folder); this pins it
; with the real writer, as macOS and Linux now do.
_TLNV_ChoiceCreatesAnAbsentConfig() {
	global _I18nLocale, _I18nConfiguredLocale, ConfigurationFile
	HadPath := IsSet(ConfigurationFile), SavedPath := HadPath ? ConfigurationFile : ""
	Saved := {Locale: _I18nLocale, Configured: _I18nConfiguredLocale}
	Dir := A_Temp . "\ergopti_tlnv_" . A_TickCount . "_" . Random(1, 1000000)
	try {
		DirCreate(Dir)
		ConfigurationFile := Dir . "\config.toml"
		_I18nLocale := "fr", _I18nConfiguredLocale := ""
		Quiet := (*) => 0
		AssertFalse(FileExist(ConfigurationFile) != "", "config.toml starts absent")
		AssertTrue(I18nSetLocale("de", 0, Quiet, Quiet), "the choice is saved")
		AssertTrue(FileExist(ConfigurationFile) != "", "config.toml is created")
		AssertTrue(InStr(FileRead(ConfigurationFile, "UTF-8"), 'locale = "de"') > 0, "with the locale row")
		AssertEqual("de", I18nConfiguredLocale())
	} finally {
		_I18nLocale := Saved.Locale, _I18nConfiguredLocale := Saved.Configured
		ConfigurationFile := HadPath ? SavedPath : unset
		try DirDelete(Dir, true)
	}
}
Test("locale: a choice creates an absent config.toml (locale-creates-config-2026-11-22)",
	_TLNV_ChoiceCreatesAnAbsentConfig)
