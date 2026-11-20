; tests/unit/core/ui/webview/test_reading_preferences.ahk

; ==============================================================================
; MODULE: Reading Preferences of the Windows (Windows)
; DESCRIPTION:
; Drives core/ui/engine/webview/reading_preferences.ahk: the boot read of
; config.toml's [script] reading_font and reading_spacing, the seed every
; window's host adds beside _i18n_locale (only the non-default choices, and
; none before the boot read), a value outside the manifest's enum, which is
; refused, and the menu's save through the config transaction.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with fresh preferences read from a config cache, then forgets them.
_TRP_With(Script, Body) {
	global _ReadingPrefsValues
	Saved := _ReadingPrefsValues
	_ReadingPrefsValues := 0
	try {
		Assert(ReadingPrefs_Init(Map("script", Script)), "the preferences initialise once")
		Body()
	} finally {
		_ReadingPrefsValues := Saved
	}
}

_TRP_SeedsTheChoices() {
	_TRP_With(Map(ConfigLeaf.READING_FONT, "dyslexic", ConfigLeaf.READING_SPACING, "wide"), () => (
		AssertEqual('window.__ergopti_reading={"font":"dyslexic","spacing":"wide"};', ReadingPrefs_SeedScript()),
		AssertEqual("dyslexic", ReadingPrefs_Get(ConfigLeaf.READING_FONT))))
	_TRP_With(Map(ConfigLeaf.READING_FONT, "hyperlegible"), () => (
		AssertEqual('window.__ergopti_reading={"font":"hyperlegible"};', ReadingPrefs_SeedScript(),
			"the default spacing is left out of the seed")))
	_TRP_With(Map(), () => (
		AssertEqual("window.__ergopti_reading={};", ReadingPrefs_SeedScript(), "nothing configured seeds nothing"),
		AssertEqual("default", ReadingPrefs_Get(ConfigLeaf.READING_SPACING))))
}
Test("reading preferences: the seed carries the configured font and spacing (reading-preferences-seed)",
	_TRP_SeedsTheChoices)

_TRP_BeforeTheBootRead() {
	global _ReadingPrefsValues
	Saved := _ReadingPrefsValues
	_ReadingPrefsValues := 0
	try AssertEqual("window.__ergopti_reading={};", ReadingPrefs_SeedScript(),
		"a window shown before the boot read seeds no choice")
	finally _ReadingPrefsValues := Saved
}
Test("reading preferences: no seed before the boot read (reading-preferences-seed)", _TRP_BeforeTheBootRead)

_TRP_UnknownValues() {
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		_TRP_With(Map(ConfigLeaf.READING_FONT, "comic"), () => (
			AssertEqual("default", ReadingPrefs_Get(ConfigLeaf.READING_FONT), "an unknown configured font keeps the default"),
			AssertEqual("window.__ergopti_reading={};", ReadingPrefs_SeedScript())))
	} finally {
		LoggerClearTestSink()
	}
	Logged := false
	for Line in Lines
		if InStr(Line, "script.reading_font") && InStr(Line, "ERROR")
			Logged := true
	Assert(Logged, "the unknown configured value is logged as an error")
	Writes := 0
	Writer := (*) => (Writes += 1, true)
	Assert(!ReadingPrefs_Set(ConfigLeaf.READING_FONT, "comic", Writer, (*) => 0, (*) => 0),
		"a menu value outside the enum is refused")
	AssertEqual(0, Writes, "nothing is written for a refused value")
}
Test("reading preferences: a value outside the enum is refused (reading-preferences-seed)", _TRP_UnknownValues)
