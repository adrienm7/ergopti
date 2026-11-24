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

; The menu's save: a refused config.toml transaction keeps the live value and
; the menu as they were. The test holds the configuration's write lease, so the
; transaction refuses before any writer runs and nothing reaches the file.
_TRP_SaveConsumesTheCommit() {
	_TRP_With(Map(), _TRP_SaveConsumesTheCommitBody)
}

_TRP_SaveConsumesTheCommitBody() {
	global ConfigurationFile
	Writes := 0, Rebuilds := 0
	Writer := (*) => (Writes += 1, 1)
	Rebuild := (*) => (Rebuilds += 1)
	Owner := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "reading-preferences-refusal")
	AssertTrue(Owner is Object, "the test holds the configuration's write lease")
	try AssertFalse(ReadingPrefs_Set(ConfigLeaf.READING_FONT, "dyslexic", Writer, (*) => 0, Rebuild),
		"a refused config.toml transaction is reported to the menu")
	finally _ConfigWriteLeaseRelease(Owner)
	AssertEqual(0, Writes, "a refused transaction runs no writer")
	AssertEqual("default", ReadingPrefs_Get(ConfigLeaf.READING_FONT), "a refused transaction keeps the live font")
	AssertEqual(0, Rebuilds, "a refused transaction never repaints the menu")
}
Test("reading preferences: the menu's save consumes its config.toml refusal (reading-preferences-seed)",
	_TRP_SaveConsumesTheCommit)

; A retained window host keeps the boot script it was created with, so a reading
; choice changed after it was hidden must retire it. The reuse keys did not carry
; the choice: the dashboards and the diagnostics reopened in the old look (met-03).
_TRP_WarmHostsFollowTheChoice() {
	Keys := Map()
	Capture(Name) {
		Keys[Name] := [KLWV_ReuseKey("store"), _HC_ReuseKeyFor("en")]
	}
	_TRP_With(Map(), () => Capture("plain"))
	_TRP_With(Map(), () => Capture("plain again"))
	_TRP_With(Map(ConfigLeaf.READING_FONT, "dyslexic"), () => Capture("font"))
	_TRP_With(Map(ConfigLeaf.READING_SPACING, "wide"), () => Capture("spacing"))
	AssertEqual(Keys["plain"][1], Keys["plain again"][1], "an unchanged choice keeps the dashboard host")
	AssertEqual(Keys["plain"][2], Keys["plain again"][2], "and the diagnostics host")
	for Name in ["font", "spacing"] {
		AssertFalse(Keys["plain"][1] == Keys[Name][1], "a new " . Name . " retires the dashboard host (met-03)")
		AssertFalse(Keys["plain"][2] == Keys[Name][2], "a new " . Name . " retires the diagnostics host (met-03)")
	}
}
Test("reading preferences: a retained window host follows a changed choice (met-03)", _TRP_WarmHostsFollowTheChoice)

; The personal information editor, the paths editor and the onboarding wizard
; navigate their own WebView2 and seeded neither the language nor the reader's
; choices, so they kept the default font and spacing (LTP-09). The wizard opens
; in its own language, before I18nInit has read the configured one.
_TRP_OwnWindowsSeedTheirPage() {
	global _I18nLocale
	SavedLocale := _I18nLocale
	_I18nLocale := "de"
	try {
		_TRP_With(Map(ConfigLeaf.READING_FONT, "dyslexic"), () => (
			AssertEqual('window._i18n_locale="de";window.__ergopti_reading={"font":"dyslexic"};', _PiEdWeb_SeedScript(),
				"the personal information editor seeds the language and the reading choice"),
			AssertEqual('window._i18n_locale="de";window.__ergopti_reading={"font":"dyslexic"};', _PathsEdWeb_SeedScript(),
				"the paths editor seeds the language and the reading choice"),
			AssertEqual('window._i18n_locale="it";window.__ergopti_reading={"font":"dyslexic"};', _OnbWeb_SeedScript("it"),
				"the onboarding wizard seeds its own language and the reading choice")))
	} finally {
		_I18nLocale := SavedLocale
	}
}
Test("reading preferences: the editors and the wizard seed their own page (ltp-09)", _TRP_OwnWindowsSeedTheirPage)

; A WebView double: an open one answers its address and records each script;
; a closed one throws on every call, as a WebView2 whose window has closed.
class _TRP_FakeView {
	__New(Open) {
		this.Open := Open
		this.Scripts := []
	}

	Source {
		get {
			if !this.Open
				throw OSError("the window has closed")
			return "https://ergopti.test/index.html"
		}
	}

	ExecuteScriptAsync(Script) {
		if !this.Open
			throw OSError("the window has closed")
		this.Scripts.Push(Script)
		return { onSettled: (*) => 0 }
	}
}

; A choice saved while windows were open reached none of them: they kept the
; look they were built with until reopened (field report, 2026-11-24).
_TRP_OpenWindowsFollowTheChoice() {
	global _ReadingPrefsViews
	Saved := _ReadingPrefsViews
	_ReadingPrefsViews := Map()
	Open := _TRP_FakeView(true), Closed := _TRP_FakeView(false)
	try {
		ReadingPrefs_Track(Open)
		ReadingPrefs_Track(Open)
		ReadingPrefs_Track(Closed)
		_TRP_With(Map(ConfigLeaf.READING_FONT, "dyslexic", ConfigLeaf.READING_SPACING, "wide"), () => (
			AssertEqual(1, ReadingPrefs_PushToOpen(), "only the open window is reached, once"),
			AssertEqual(1, Open.Scripts.Length, "a window tracked twice is pushed once"),
			AssertEqual('window.ErgoptiA11yPrefs&&window.ErgoptiA11yPrefs.receiveHost({"font":"dyslexic","spacing":"wide"});',
				Open.Scripts[1], "the page applies the saved choices at once")))
		AssertEqual(1, _ReadingPrefsViews.Count, "the closed window is dropped")
	} finally {
		_ReadingPrefsViews := Saved
	}
}
Test("reading preferences: the open windows take a saved choice at once (reading-preferences-live)",
	_TRP_OpenWindowsFollowTheChoice)
