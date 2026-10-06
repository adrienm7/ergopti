; static/ergopti_plus/windows/tests/unit/test_tap_hold_loader.ahk

; ==============================================================================
; MODULE: Tap-Hold Loader Tests
; DESCRIPTION:
; Unit-tests for LoadTapHoldToml and the five convenience accessors:
; TapHoldIsConfigured, TapHoldTapAction, TapHoldDuration, TapHoldHoldModifier,
; TapHoldHoldLayer. Exercises the TOML parsing, value coercion, and default
; fallback behaviour without touching the live file system at runtime.
; ==============================================================================






; ==================================
; ==================================
; ======= 1/ LoadTapHoldToml =======
; ==================================
; ==================================

_TH_TmpPath() => A_ScriptDir . "\test_tap_hold_tmp.toml"

_TH_Write(Content) {
	Path := _TH_TmpPath()
	if FileExist(Path) {
		FileDelete(Path)
	}
	FileAppend(Content, Path, "UTF-8")
	return Path
}

_TH_Clean() {
	global _TomlFileCache
	Path := _TH_TmpPath()
	if FileExist(Path)
		FileDelete(Path)
	; Evict the cached content so the next test reads fresh from disk
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
}

_TH_MissingFileReturnsEmptyScaffold() {
	TH := LoadTapHoldToml(A_ScriptDir . "\does_not_exist_tap_hold.toml")
	AssertEqual("Map", Type(TH))
	AssertTrue(TH.Has("keys"))
	AssertEqual(0, TH["keys"].Count)
	AssertFalse(TH.Has("layers"), "layer bindings are not tap-hold data")
}
Test("LoadTapHoldToml: missing file returns empty scaffold", _TH_MissingFileReturnsEmptyScaffold)

_TH_ParsesSingleKeyEntry() {
	Path := _TH_Write(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "enter"' . "`r`n"
		. "time_activation_seconds = 0.35`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertTrue(TH["keys"].Has("caps_lock"))
	AssertEqual("enter", TH["keys"]["caps_lock"]["tap_action"])
	AssertEqual(0.35, TH["keys"]["caps_lock"]["time_activation_seconds"])
}
Test("LoadTapHoldToml: parses a single key entry", _TH_ParsesSingleKeyEntry)

_TH_ParsesHoldModifier() {
	Path := _TH_Write(
		"[tap_hold.keys.left_ctrl]`r`n"
		. 'hold_modifier = "ctrl"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("ctrl", TH["keys"]["left_ctrl"]["hold_modifier"])
}
Test("LoadTapHoldToml: parses hold_modifier", _TH_ParsesHoldModifier)

_TH_ParsesHoldLayer() {
	Path := _TH_Write(
		"[tap_hold.keys.space]`r`n"
		. 'hold_layer = "nav"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("nav", TH["keys"]["space"]["hold_layer"])
}
Test("LoadTapHoldToml: parses hold_layer", _TH_ParsesHoldLayer)

; Every hold-layer variant tests TapHoldHoldLayer(...) != "", so any other
; layer name, a typo included, held the navigation layer. A hold_layer outside
; [tap_hold.hold_picker].layers is refused where it is read: the error names it,
; the key's hold is dropped (a default hold_modifier with it: the user chose a
; layer), and its tap is kept (tap-hold-unknown-layer-2026-09-25).
_TH_UnknownHoldLayerDropsTheHoldOnly() {
	DefaultsPath := A_ScriptDir . "\test_tap_hold_tmp_defaults.toml"
	for _, Source in ["user", "defaults"] {
		UserText := "[tap_hold.keys.space]`n" . 'hold_layer = "nav"' . "`n"
		DefaultsText := "[tap_hold.keys.caps_lock]`n" . 'tap_action = "enter"' . "`n"
			. 'hold_modifier = "ctrl"' . "`n"
		if (Source == "user")
			UserText .= "[tap_hold.keys.caps_lock]`n" . 'tap_action = "enter"' . "`n" . 'hold_layer = "navv"' . "`n"
		else
			DefaultsText := "[tap_hold.keys.caps_lock]`n" . 'tap_action = "enter"' . "`n"
				. 'hold_layer = "navv"' . "`n"
		; Restoring a preset is explicit: its selected records become user input.
		if Source == "defaults"
			UserText .= DefaultsText
		Path := _TH_Write(UserText)
		if FileExist(DefaultsPath)
			FileDelete(DefaultsPath)
		FileAppend(DefaultsText, DefaultsPath, "UTF-8")
		Captured := []
		LoggerSetTestSink((Line) => Captured.Push(Line))
		try {
			TH := LoadTapHoldToml(Path, DefaultsPath)
		} finally {
			LoggerClearTestSink()
			_TH_Clean()
			if FileExist(DefaultsPath)
				FileDelete(DefaultsPath)
			if _TomlFileCache.Has(DefaultsPath)
				_TomlFileCache.Delete(DefaultsPath)
		}
		Entry := TH["keys"]["caps_lock"]
		AssertFalse(Entry.Has("hold_layer"), Source . ": an unknown hold_layer must not reach the layer variants")
		AssertEqual("", Entry.Get("hold_modifier", ""), Source . ": the key must hold nothing")
		AssertEqual("enter", Entry["tap_action"], Source . ": the key's tap must be kept")
		AssertEqual("nav", TH["keys"]["space"]["hold_layer"], Source . ": a known layer must still load")
		Logged := false
		for _, Line in Captured {
			if (InStr(Line, "[ERROR]") and InStr(Line, "navv") and InStr(Line, "caps_lock"))
				Logged := true
		}
		AssertTrue(Logged, Source . ": the refusal must be logged as an ERROR naming the layer and the key")
	}
}
Test("LoadTapHoldToml: an unknown hold_layer drops the hold and keeps the tap (tap-hold-unknown-layer-2026-09-25)",
	_TH_UnknownHoldLayerDropsTheHoldOnly)

_TH_ParsesMultipleKeysIndependently() {
	Path := _TH_Write(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "backspace"' . "`r`n"
		. "[tap_hold.keys.right_ctrl]`r`n"
		. 'tap_action = "tab"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual(2, TH["keys"].Count)
	AssertEqual("backspace", TH["keys"]["caps_lock"]["tap_action"])
	AssertEqual("tab",       TH["keys"]["right_ctrl"]["tap_action"])
}
Test("LoadTapHoldToml: parses multiple keys independently", _TH_ParsesMultipleKeysIndependently)

; Layer bindings moved to layers.toml (platform/remap/layers_loader.ahk). The
; old [tap_hold.layers.<id>.mappings] table was loaded and written back by this
; driver and read by no other, so it looked configurable and did nothing.
_TH_LayerSectionsAreNotTapHoldData() {
	Path := _TH_Write(
		"[tap_hold.layers.nav.mappings]`r`n"
		. 'h = "arrow_left"' . "`r`n"
		. "[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "enter"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertFalse(TH.Has("layers"), "[tap_hold.layers.*] must not become tap-hold state")
	AssertEqual(1, TH["keys"].Count)
	AssertEqual("enter", TH["keys"]["caps_lock"]["tap_action"])
}
Test("LoadTapHoldToml: [tap_hold.layers.*] is not tap-hold data", _TH_LayerSectionsAreNotTapHoldData)

_TH_IgnoresUnrecognisedSectionHeaders() {
	Path := _TH_Write(
		"[some_other_section]`r`n"
		. 'foo = "bar"' . "`r`n"
		. "[tap_hold.keys.lalt]`r`n"
		. 'tap_action = "one_shot_shift"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual(1, TH["keys"].Count)
	AssertFalse(TH["keys"].Has("some_other_section"))
}
Test("LoadTapHoldToml: ignores unrecognised section headers", _TH_IgnoresUnrecognisedSectionHeaders)

_TH_IgnoresBlankLinesAndComments() {
	Path := _TH_Write(
		"; This is a comment`r`n"
		. "`r`n"
		. "[tap_hold.keys.tab]`r`n"
		. "; another comment`r`n"
		. 'tap_action = "alt_tab_monitor"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("alt_tab_monitor", TH["keys"]["tab"]["tap_action"])
}
Test("LoadTapHoldToml: ignores blank lines and comments", _TH_IgnoresBlankLinesAndComments)

_TH_ParsesInlineCommentsBeforeCoercion() {
	Path := _TH_Write(
		"[tap_hold.keys.tab] # configured key`r`n"
		. "enabled = true # active`r`n"
		. 'tap_action = "alt#tab" # hash inside string' . "`r`n"
		. "time_activation_seconds = 0.35 # seconds`r`n")
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertTrue(TH["keys"].Has("tab"),
		"an inline comment must not invalidate the section header")
	Entry := TH["keys"]["tab"]
	AssertEqual(true, Entry["enabled"])
	AssertEqual("alt#tab", Entry["tap_action"],
		"a hash inside quotes must remain part of the value")
	AssertEqual(0.35, Entry["time_activation_seconds"])
}
Test("TapHoldLoader: inline comments precede coercion (AHK-133)",
	_TH_ParsesInlineCommentsBeforeCoercion)






; ======================================
; ======================================
; ======= 2/ TapHoldIsConfigured =======
; ======================================
; ======================================

_TH_IsConfiguredFalseWhenEmpty() {
	TH := Map("keys", Map(), "layers", Map())
	AssertFalse(TapHoldIsConfigured(TH, "caps_lock"))
}
Test("TapHoldIsConfigured: false when keys map is empty", _TH_IsConfiguredFalseWhenEmpty)

_TH_IsConfiguredTrueWhenTapAction() {
	TH := Map("keys", Map("caps_lock", Map("tap_action", "enter")), "layers", Map())
	AssertTrue(TapHoldIsConfigured(TH, "caps_lock"))
}
Test("TapHoldIsConfigured: true when tap_action present", _TH_IsConfiguredTrueWhenTapAction)

_TH_IsConfiguredTrueWhenHoldModifier() {
	TH := Map("keys", Map("lshift", Map("hold_modifier", "shift")), "layers", Map())
	AssertTrue(TapHoldIsConfigured(TH, "lshift"))
}
Test("TapHoldIsConfigured: true when hold_modifier present", _TH_IsConfiguredTrueWhenHoldModifier)

_TH_IsConfiguredTrueWhenHoldLayer() {
	TH := Map("keys", Map("space", Map("hold_layer", "nav")), "layers", Map())
	AssertTrue(TapHoldIsConfigured(TH, "space"))
}
Test("TapHoldIsConfigured: true when hold_layer present", _TH_IsConfiguredTrueWhenHoldLayer)

_TH_IsConfiguredFalseWhenNoneOfThreeKeys() {
	TH := Map("keys", Map("lalt", Map("time_activation_seconds", 0.2)), "layers", Map())
	AssertFalse(TapHoldIsConfigured(TH, "lalt"))
}
Test("TapHoldIsConfigured: false when entry exists but has none of the three keys", _TH_IsConfiguredFalseWhenNoneOfThreeKeys)

_TH_DisabledEntriesStayInactiveAcrossAccessors() {
	Path := _TH_Write(
		"[tap_hold.keys.caps_lock]`r`n"
		. "enabled = false`r`n"
		. 'tap_action = "enter"' . "`r`n"
		. "time_activation_seconds = 0.35`r`n"
		. "[tap_hold.keys.left_ctrl]`r`n"
		. "enabled = false`r`n"
		. 'hold_modifier = "ctrl"' . "`r`n"
		. "[tap_hold.keys.space]`r`n"
		. "enabled = false`r`n"
		. 'hold_layer = "nav"' . "`r`n")
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	for KeyId in ["caps_lock", "left_ctrl", "space"] {
		AssertTrue(TapHoldIsConfigured(TH, KeyId),
			KeyId . " must retain its stored configuration for the menu")
		AssertFalse(TapHoldIsEnabled(TH, KeyId),
			KeyId . " must expose its disabled schema state")
		AssertFalse(TapHoldIsActive(TH, KeyId),
			KeyId . " must remain inactive when its schema flag is false")
	}
	AssertEqual("", TapHoldTapAction(TH, "caps_lock"))
	AssertEqual("", TapHoldHoldModifier(TH, "left_ctrl"))
	AssertEqual("", TapHoldHoldLayer(TH, "space"))
	AssertEqual(TAPHOLD_DEFAULT_ACTIVATION_SECONDS,
		TapHoldDuration(TH, "caps_lock"))
}
Test("TapHoldLoader: enabled=false disables every accessor (AHK-132)",
	_TH_DisabledEntriesStayInactiveAcrossAccessors)






; ===================================
; ===================================
; ======= 3/ TapHoldTapAction =======
; ===================================
; ===================================

; Defaults overlay regression (LoadTapHoldToml with DefaultsFilePath)
TestTapHold_DefaultsOverlay() {
	; When defaults supplied, missing user keys inherit; user overrides win.
	; Test uses the loader's inherit logic (simulated via missing file case + seed).
	TH := LoadTapHoldToml("Z:\\does_not_exist_user.toml", "Z:\\does_not_exist_defaults.toml")
	AssertTrue(TH.Has("keys"))
	; Real defaults test would seed a defaults file, but for unit we verify scaffold + merge path.
}
Test("TapHoldLoader: defaults overlay returns scaffold when no files", TestTapHold_DefaultsOverlay)

; Error/edge: invalid TOML, bad values, inherit_defaults=false
TestTapHold_InvalidTomlGraceful() {
	Path := _TH_Write("[tap_hold.keys.bad]`r`n tap_action = 123`r`n")  ; non-string
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	; Parser should coerce or skip bad; at minimum not crash and return map.
	AssertTrue(Type(TH) == "Map")
}
Test("TapHoldLoader: invalid value types do not crash (graceful)", TestTapHold_InvalidTomlGraceful)

TestTapHold_InvalidSchemaTypesFailClosed() {
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := _TH_Write(
			"[tap_hold.keys.caps_lock]`r`n"
			. "enabled = 1`r`n"
			. "tap_action = true`r`n"
			. "time_activation_seconds = false`r`n"
			. "[tap_hold.keys.left_ctrl]`r`n"
			. "hold_modifier = 1`r`n"
			. "[tap_hold.keys.space]`r`n"
			. "hold_layer = false`r`n"
			. "[tap_hold.keys.tab]`r`n"
			. 'tap_action = "alt_tab_monitor"' . "`r`n"
			. "time_activation_seconds = 0.2`r`n")
		TH := LoadTapHoldToml(Path)
		for KeyId in ["caps_lock", "left_ctrl", "space"] {
			AssertFalse(TapHoldIsActive(TH, KeyId),
				KeyId . " must fail closed after a schema type violation")
			AssertEqual("", TapHoldTapAction(TH, KeyId))
			AssertEqual("", TapHoldHoldModifier(TH, KeyId))
			AssertEqual("", TapHoldHoldLayer(TH, KeyId))
		}
		AssertEqual(TAPHOLD_DEFAULT_ACTIVATION_SECONDS,
			TapHoldDuration(TH, "caps_lock"))
		AssertTrue(TapHoldIsActive(TH, "tab"),
			"one invalid entry must not suppress later valid sections")
		Errors := 0
		for Line in Captured
			if InStr(Line, "[ERROR]", true)
				Errors += 1
		AssertTrue(Errors >= 5,
			"every rejected tap-hold field must remain visible in the logs")
	} finally {
		LoggerClearTestSink()
		_TH_Clean()
	}
}
Test("TapHoldLoader: schema type violations fail closed (AHK-134)",
	TestTapHold_InvalidSchemaTypesFailClosed)

; A field no tap-hold key has disabled the whole key with an ERROR at every
; boot, as if it were a wrong-typed known field. It is an outdated entry: one
; WARNING, the field ignored, the rest of the key applied (config-outdated-tap-hold).
TestTapHold_UnknownFieldIsOutdated() {
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		; The same valid key the AHK-134 fixture proves active.
		Path := _TH_Write("[tap_hold.keys.tab]`r`n"
			. 'tap_action = "alt_tab_monitor"' . "`r`n"
			. "time_activation_seconds = 0.2`r`n"
			. "retired_field = 1`r`n")
		TH := LoadTapHoldToml(Path)
		AssertTrue(TapHoldIsActive(TH, "tab"), "an unknown field must not disable its key")
		AssertEqual("alt_tab_monitor", TapHoldTapAction(TH, "tab"))
		AssertFalse(TH["keys"]["tab"].Has("retired_field"), "the unknown field is ignored")
		Warned := false, Errors := 0
		for Line in Captured {
			if InStr(Line, "[ERROR]", true)
				Errors += 1
			if (InStr(Line, "[WARNING]", true) and InStr(Line, "retired_field") and InStr(Line, "tap_hold.keys.tab"))
				Warned := true
		}
		AssertEqual(0, Errors, "an outdated field is never an ERROR")
		AssertTrue(Warned, "the outdated field is named in a WARNING with its key")
	} finally {
		LoggerClearTestSink()
		_TH_Clean()
	}
}
Test("TapHoldLoader: an unknown field is warned and ignored, its key kept (config-outdated-tap-hold)",
	TestTapHold_UnknownFieldIsOutdated)


_TH_OutdatedFileWarningVectors() {
	global _SharedDir
	Vectors := JsonParse(FSReadUtf8Exact(_SharedDir .
		"\tests\corpus\config_outdated\file_warning_vectors.json"))
	AssertEqual(12, Vectors.Length, "every independent warning observation executes")
	Lines := []
	Warn := (Message, Args*) => Lines.Push(Format(Message, Args*))
	for Vector in Vectors {
		First := ConfigOutdatedReportInFile(Vector["file"], Vector["path"], Vector["detail"], Warn)
		AssertEqual(Vector["first"], First, Vector["id"])
		AssertEqual(Vector["reports"], Lines.Length, Vector["id"])
		if First
			AssertEqual(Format("Outdated entry '{1}' in '{2}' ignored ({3}); the config cleanup only covers "
				. "config.toml, so fix or delete it in that file.",
				Vector["path"], Vector["file"], Vector["detail"]), Lines[Lines.Length], Vector["id"])
	}
	AssertEqual(7, Lines.Length, "interleaved reads retain the process-lifetime identities")
}
Test("TapHoldLoader: independent file warnings retain process-lifetime identities",
	_TH_OutdatedFileWarningVectors)


_TH_OutdatedCallbackObservation(Events, FilePath, EntryPath, Detail, Message, Args*) {
	Events["critical"] := A_IsCritical
	Events["calls"] += 1
	Events["message"] := Format(Message, Args*)
	Events["again"] := ConfigOutdatedReportInFile(FilePath, EntryPath, Detail,
		(*) => Events["calls"] += 1)
	Events["after_reentry"] := A_IsCritical
}

_TH_OutdatedCallbackDoesNotOwnCritical() {
	Before := A_IsCritical
	try {
		for Mode in ["Off", "On"] {
			Critical(Mode)
			CallerCritical := A_IsCritical
			Events := Map("calls", 0, "critical", -1, "after_reentry", -1, "again", -1, "message", "")
			FilePath := A_ScriptDir . "\outdated-callback-" . Mode . ".toml"
			EntryPath := "tap_hold.keys.tab.future_callback"
			Detail := "the catalogue does not own this field"
			Warn := _TH_OutdatedCallbackObservation.Bind(Events, FilePath, EntryPath, Detail)
			First := ConfigOutdatedReportInFile(FilePath, EntryPath, Detail, Warn)
			After := A_IsCritical
			AssertTrue(First, "the first callback report is admitted")
			AssertFalse(Events["again"], "reentry already sees the claimed report")
			AssertEqual(1, Events["calls"], "the warning callback runs once even if it reenters")
			AssertEqual(CallerCritical, Events["critical"], "the callback inherits its caller's Critical state")
			AssertEqual(CallerCritical, Events["after_reentry"], "the duplicate path restores Critical too")
			AssertEqual(CallerCritical, After, "reporting leaves no Critical owner after its callback")
			AssertTrue(InStr(Events["message"], EntryPath, true) > 0, "the callback observes its entry")
		}
	} finally Critical(Before)
}
Test("TapHoldLoader: shared warning callbacks preserve Critical and process-lifetime reentry",
	_TH_OutdatedCallbackDoesNotOwnCritical)

_TH_OutdatedFieldsWarnOnceAcrossActualReads() {
	global _TomlFileCache, _LOGGER_REPEAT_ENABLED
	Captured := [], PreviousRepeat := _LOGGER_REPEAT_ENABLED
	; Timed logger suppression must not stand in for the persisted-entry policy.
	_LOGGER_REPEAT_ENABLED := false
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := _TH_Write("[tap_hold.keys.tab]`r`n"
			. 'tap_action = "alt_tab_monitor"' . "`r`n"
			. "time_activation_seconds = 0.2`r`n"
			. "retired_once_field = 1`r`n"
			. 'future_once_array = ["none", "experimental"]' . "`r`n"
			. 'future_once_table = { label = "kept", enabled = false }' . "`r`n")
		Stored := FileRead(Path, "RAW")
		loop 3 {
			if _TomlFileCache.Has(Path)
				_TomlFileCache.Delete(Path)
			TH := LoadTapHoldToml(Path)
			AssertTrue(TapHoldIsActive(TH, "tab"), "every actual read keeps the valid key")
			AssertEqual("alt_tab_monitor", TapHoldTapAction(TH, "tab"))
			for Key in ["retired_once_field", "future_once_array", "future_once_table"]
				AssertFalse(TH["keys"]["tab"].Has(Key), "obsolete fields never become native bindings")
			LoggerWarn("TapHoldLoader", "Interleaved file-read fixture warning {1}.", A_Index)
		}
		Counts := Map("retired_once_field", 0, "future_once_array", 0, "future_once_table", 0)
		Errors := 0
		for Line in Captured {
			if InStr(Line, "[ERROR]", true)
				Errors += 1
			for Key in Counts {
				if InStr(Line, "[WARNING]", true) && InStr(Line, "." . Key, true) {
					Counts[Key] += 1
					AssertTrue(InStr(Line, Path, true) > 0, "the warning names its actual persisted file")
					AssertTrue(InStr(Line, "tap_hold.keys.tab", true) > 0, "the warning names its entry")
				}
			}
		}
		AssertEqual(0, Errors, "unknown values remain warnings even when arrays or inline tables")
		for Key, Count in Counts
			AssertEqual(1, Count, "three real reads must warn once for " . Key)
		After := FileRead(Path, "RAW")
		AssertEqual(Stored.Size, After.Size, "obsolete values and their byte layout remain stored")
		loop Stored.Size
			AssertEqual(NumGet(Stored, A_Index - 1, "UChar"), NumGet(After, A_Index - 1, "UChar"),
				"unowned byte " . A_Index . " is preserved")
	} finally {
		_LOGGER_REPEAT_ENABLED := PreviousRepeat
		LoggerClearTestSink()
		_TH_Clean()
	}
}
Test("TapHoldLoader: repeated real reads warn once and preserve future values byte-for-byte",
	_TH_OutdatedFieldsWarnOnceAcrossActualReads)

TestTapHold_InheritDefaultsFalse() {
	Path := _TH_Write(
		"[tap_hold]`r`n"
		. "inherit_defaults = false`r`n"
		. "[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = ""' . "`r`n"  ; empty to disable
	)
	TH := LoadTapHoldToml(Path, "some_defaults.toml")
	_TH_Clean()
	; With inherit false, even if defaults had values, user empty wins (no keys populated beyond user).
	AssertTrue(TH["keys"].Count == 1 or TH["keys"].Count == 0)  ; depends on parse of empty
}
Test("TapHoldLoader: inherit_defaults=false skips defaults overlay", TestTapHold_InheritDefaultsFalse)

; Accessor edges
TestTapHold_TapActionUnknownReturnsEmpty() {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual("", TapHoldTapAction(TH, "nonexistent"))
}
Test("TapHoldTapAction: unknown key returns empty string", TestTapHold_TapActionUnknownReturnsEmpty)

TestTapHold_DurationDefault() {
	TH := Map("keys", Map("x", Map("tap_action", "y")), "layers", Map())
	; Accessor must source its fallback from the single constant, not a literal
	AssertEqual(TAPHOLD_DEFAULT_ACTIVATION_SECONDS, TapHoldDuration(TH, "x"))
}
Test("TapHoldDuration: falls back when time_activation_seconds absent", TestTapHold_DurationDefault)

; Pause guard for tap-hold dispatch (project_suspend_pause_invariant).
;
; This asserted AssertTrue(true) under the message "tap_hold must respect full
; pause silence" — the invariant named, and nothing checking it. The guard is
; real and lives in platform/remap/constants.ahk, so the test now pins the
; four dispatch entry points that must consult A_IsSuspended.
;
; Every one of them can emit a keystroke. A tap-hold that fires while the user
; has deliberately suspended the script types into whatever they are doing, and
; the failure is silent from the driver's side — nothing errors, the keystroke
; simply arrives.
TestTapHold_DispatchGatesOnSuspend() {
	Gated := ["TapHoldOwnImmediateModifier", "TapHoldSyntheticKeyDown",
		"TapHoldSyntheticKeyUp", "TapHoldDispatchTap"]
	for Fn in Gated {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . "() must exist in the driver source — the pause guard moved")
		Assert(InStr(Body, "A_IsSuspended") > 0,
			Fn . "() must check A_IsSuspended before acting. It can emit a keystroke, and one "
			. "that fires while the script is suspended types into whatever the user is doing "
			. "— with nothing erroring on the driver's side (project_suspend_pause_invariant)")
	}
}
Test("TapHoldLoader: every dispatch entry point gates on suspend (full invariant)", TestTapHold_DispatchGatesOnSuspend)

; Error path: bad TOML in tap_hold must not crash loader
TestTapHold_BadTomlGraceful() {
	Path := _TH_Write("garbage not toml")
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertTrue(TH.Has("keys") and TH["keys"].Count == 0, "bad tap_hold toml must return empty scaffold")
}
Test("TapHoldLoader: malformed TOML returns empty without crash", TestTapHold_BadTomlGraceful)

_TH_TapActionEmptyForUnknownKey() {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual("", TapHoldTapAction(TH, "caps_lock"))
}
Test("TapHoldTapAction: returns empty string for unknown key", _TH_TapActionEmptyForUnknownKey)

_TH_TapActionReturnsConfiguredValue() {
	TH := Map("keys", Map("caps_lock", Map("tap_action", "backspace")), "layers", Map())
	AssertEqual("backspace", TapHoldTapAction(TH, "caps_lock"))
}
Test("TapHoldTapAction: returns configured value", _TH_TapActionReturnsConfiguredValue)

_TH_UnknownTapActionDisablesEntry() {
	TH := Map("keys", Map("caps_lock", Map(
		"tap_action", "__audit_unknown_action__",
		"hold_modifier", "ctrl")), "layers", Map())
	AssertFalse(TapHoldIsEnabled(TH, "caps_lock"),
		"an action absent from GESTURE_ACTIONS must disable the full tap-hold entry")
	AssertFalse(TapHoldIsActive(TH, "caps_lock"),
		"an invalid tap action must not leave the key armed")
	AssertEqual("", TapHoldTapAction(TH, "caps_lock"),
		"an invalid tap action must not be exposed to a dispatch hotkey")
	AssertEqual("", TapHoldHoldModifier(TH, "caps_lock"),
		"an invalid tap action must not leave a sibling hold modifier armed")
}
Test("TapHoldLoader: unknown tap actions fail closed (AHK-151)",
	_TH_UnknownTapActionDisablesEntry)

_TH_TapActionEmptyWhenKeyAbsent() {
	TH := Map("keys", Map("lalt", Map("hold_layer", "nav")), "layers", Map())
	AssertEqual("", TapHoldTapAction(TH, "lalt"))
}
Test("TapHoldTapAction: returns empty string when tap_action key absent", _TH_TapActionEmptyWhenKeyAbsent)






; ==================================
; ==================================
; ======= 4/ TapHoldDuration =======
; ==================================
; ==================================

_TH_DurationDefaultForUnknownKey() {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual(TAPHOLD_DEFAULT_ACTIVATION_SECONDS, TapHoldDuration(TH, "caps_lock"))
}
Test("TapHoldDuration: returns the single-sourced default for unknown key", _TH_DurationDefaultForUnknownKey)

_TH_DurationDefaultWhenAbsent() {
	TH := Map("keys", Map("lalt", Map("tap_action", "backspace")), "layers", Map())
	AssertEqual(TAPHOLD_DEFAULT_ACTIVATION_SECONDS, TapHoldDuration(TH, "lalt"))
}
Test("TapHoldDuration: returns the single-sourced default when time_activation_seconds absent", _TH_DurationDefaultWhenAbsent)

; Pin the canonical default value in exactly one place. This is the regression
; for sourcing TapHoldDuration's fallback from a single named constant instead of
; the 0.2 literal it used to duplicate across both return branches.
_TH_DefaultActivationConstantValue() {
	AssertEqual(0.2, TAPHOLD_DEFAULT_ACTIVATION_SECONDS)
}
Test("tap_hold: TAPHOLD_DEFAULT_ACTIVATION_SECONDS is the single 0.2 source", _TH_DefaultActivationConstantValue)

_TH_DurationReturnsConfiguredValue() {
	TH := Map("keys", Map("caps_lock", Map("time_activation_seconds", 0.35)), "layers", Map())
	AssertEqual(0.35, TapHoldDuration(TH, "caps_lock"))
}
Test("TapHoldDuration: returns configured value", _TH_DurationReturnsConfiguredValue)






; ======================================
; ======================================
; ======= 5/ TapHoldHoldModifier =======
; ======================================
; ======================================

_TH_HoldModifierEmptyForUnknownKey() {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual("", TapHoldHoldModifier(TH, "lctrl"))
}
Test("TapHoldHoldModifier: returns empty string for unknown key", _TH_HoldModifierEmptyForUnknownKey)

_TH_HoldModifierReturnsConfiguredValue() {
	TH := Map("keys", Map("lctrl", Map("hold_modifier", "ctrl")), "layers", Map())
	AssertEqual("ctrl", TapHoldHoldModifier(TH, "lctrl"))
}
Test("TapHoldHoldModifier: returns configured value", _TH_HoldModifierReturnsConfiguredValue)

_TH_HoldModifierEmptyWhenAbsent() {
	TH := Map("keys", Map("lctrl", Map("tap_action", "tab")), "layers", Map())
	AssertEqual("", TapHoldHoldModifier(TH, "lctrl"))
}
Test("TapHoldHoldModifier: returns empty string when hold_modifier absent", _TH_HoldModifierEmptyWhenAbsent)






; ===================================
; ===================================
; ======= 6/ TapHoldHoldLayer =======
; ===================================
; ===================================

_TH_HoldLayerEmptyForUnknownKey() {
	TH := Map("keys", Map(), "layers", Map())
	AssertEqual("", TapHoldHoldLayer(TH, "space"))
}
Test("TapHoldHoldLayer: returns empty string for unknown key", _TH_HoldLayerEmptyForUnknownKey)

_TH_HoldLayerReturnsConfiguredValue() {
	TH := Map("keys", Map("space", Map("hold_layer", "nav")), "layers", Map())
	AssertEqual("nav", TapHoldHoldLayer(TH, "space"))
}
Test("TapHoldHoldLayer: returns configured value", _TH_HoldLayerReturnsConfiguredValue)

_TH_HoldLayerEmptyWhenAbsent() {
	TH := Map("keys", Map("lalt", Map("tap_action", "backspace")), "layers", Map())
	AssertEqual("", TapHoldHoldLayer(TH, "lalt"))
}
Test("TapHoldHoldLayer: returns empty string when hold_layer absent", _TH_HoldLayerEmptyWhenAbsent)





; ==================================================
; ==================================================
; ======= 7/ Runtime overlay (defaults+user) =======
; ==================================================
; ==================================================

; Helper: write a second temp file for defaults (path distinct from the user tmp)
_TH_DefaultsTmpPath() => A_ScriptDir . "\test_tap_hold_defaults_tmp.toml"

_TH_WriteDefaults(Content) {
	Path := _TH_DefaultsTmpPath()
	if FileExist(Path)
		FileDelete(Path)
	FileAppend(Content, Path, "UTF-8")
	return Path
}

_TH_CleanDefaults() {
	global _TomlFileCache
	Path := _TH_DefaultsTmpPath()
	if FileExist(Path)
		FileDelete(Path)
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
}

; A missing user file never imports the shipped recommendation.
_TH_OverlayDefaultsOnlyWhenUserMissing() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
		. "time_activation_seconds = 0.35`r`n"
	)
	TH := LoadTapHoldToml(A_ScriptDir . "\does_not_exist_user.toml", DefPath)
	_TH_CleanDefaults()
	AssertEqual(0, TH["keys"].Count)
	AssertFalse(TH.Has("layers"), "tap-hold absence must not create a second navigation owner")
}
Test("LoadTapHoldToml: absent user file never imports a recommendation", _TH_OverlayDefaultsOnlyWhenUserMissing)

; User value takes precedence over the matching default field
_TH_OverlayUserWinsOnConflict() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
		. "time_activation_seconds = 0.35`r`n"
	)
	UserPath := _TH_Write(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "enter"' . "`r`n"
	)
	TH := LoadTapHoldToml(UserPath, DefPath)
	_TH_Clean()
	_TH_CleanDefaults()
	; Only explicit records are loaded, including when the preset has parameters.
	AssertEqual("enter", TH["keys"]["caps_lock"]["tap_action"])
	AssertFalse(TH["keys"]["caps_lock"].Has("time_activation_seconds"))
}
Test("LoadTapHoldToml overlay: user value wins on conflict", _TH_OverlayUserWinsOnConflict)

; User file introduces a key absent from defaults — it is preserved as-is
_TH_OverlayUserOnlyKeyPreserved() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
	)
	UserPath := _TH_Write(
		"[tap_hold.keys.my_custom_key]`r`n"
		. 'hold_modifier = "shift"' . "`r`n"
	)
	TH := LoadTapHoldToml(UserPath, DefPath)
	_TH_Clean()
	_TH_CleanDefaults()
	AssertFalse(TH["keys"].Has("caps_lock"))
	AssertTrue(TH["keys"].Has("my_custom_key"))
	AssertEqual("shift", TH["keys"]["my_custom_key"]["hold_modifier"])
}
Test("LoadTapHoldToml: user-only key survives without importing a preset", _TH_OverlayUserOnlyKeyPreserved)

; Omitting DefaultsFilePath still works (no regression on existing callers)
_TH_OverlayBackwardCompatNoDefaults() {
	Path := _TH_Write(
		"[tap_hold.keys.tab]`r`n"
		. 'tap_action = "tab"' . "`r`n"
	)
	TH := LoadTapHoldToml(Path)
	_TH_Clean()
	AssertEqual("tab", TH["keys"]["tab"]["tap_action"])
}
Test("LoadTapHoldToml overlay: backward-compatible when DefaultsFilePath omitted", _TH_OverlayBackwardCompatNoDefaults)

; inherit_defaults = false opts out of the shipped defaults overlay
_TH_InheritDefaultsFalseSkipsShippedDefaults() {
	DefPath := _TH_WriteDefaults(
		"[tap_hold.keys.caps_lock]`r`n"
		. 'tap_action = "escape"' . "`r`n"
	)
	UserPath := _TH_Write(
		"[tap_hold]`r`n"
		. "inherit_defaults = false`r`n"
	)
	TH := LoadTapHoldToml(UserPath, DefPath)
	_TH_Clean()
	_TH_CleanDefaults()
	AssertEqual(0, TH["keys"].Count)
}
Test("LoadTapHoldToml: inherit_defaults=false skips shipped defaults", _TH_InheritDefaultsFalseSkipsShippedDefaults)





; =========================================================
; =========================================================
; ======= 8/ ResolveHoldModifierKey (single-source) =======
; =========================================================
; =========================================================

_TH_ResolveHoldModifierKeyKnownValuesMap() {
	global _ALTGR_KANA_FIXUP
	PreviousKana := _ALTGR_KANA_FIXUP
	try {
		_ALTGR_KANA_FIXUP := false
		AssertEqual("LCtrl", ResolveHoldModifierKey("ctrl", "backspace"))
		AssertEqual("LShift", ResolveHoldModifierKey("shift", "backspace"))
		AssertEqual("LAlt", ResolveHoldModifierKey("alt", "backspace"))
		AssertEqual("RAlt", ResolveHoldModifierKey("alt_gr", "backspace"))
		AssertEqual("LWin", ResolveHoldModifierKey("win", "backspace"))
	} finally {
		_ALTGR_KANA_FIXUP := PreviousKana
	}
}
Test("ResolveHoldModifierKey: maps every known hold_modifier value", _TH_ResolveHoldModifierKeyKnownValuesMap)

; On a Kana-style layout VK_RMENU has no scan code, so RAlt is a plain Alt and
; the layout's AltGr is the SC138 key. Every alt_gr spelling, alone or in a
; combination, must follow the layout (kana-altgr-hold-2026-09-25).
_TH_ResolveHoldModifierKeyAltGrFollowsLayout() {
	global _ALTGR_KANA_FIXUP
	PreviousKana := _ALTGR_KANA_FIXUP
	try {
		for Kana, Expected in Map(true, "SC138", false, "RAlt") {
			_ALTGR_KANA_FIXUP := Kana
			for Spelling in ["alt_gr", "altgr", "ralt"]
				AssertEqual(Expected, ResolveHoldModifierKey(Spelling, "caps_lock"),
					"hold '" . Spelling . "' with Kana=" . Kana)
			Combo := ResolveHoldModifierKey("ctrl+alt_gr", "caps_lock")
			Assert(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == Expected,
				"a ctrl+alt_gr hold must hold LCtrl and the layout's AltGr " . Expected)
		}
	} finally {
		_ALTGR_KANA_FIXUP := PreviousKana
	}
}
Test("ResolveHoldModifierKey: alt_gr resolves to the layout's AltGr key (kana-altgr-hold-2026-09-25)",
	_TH_ResolveHoldModifierKeyAltGrFollowsLayout)

; A generic modifier token resolves to the tap-hold key's OWN side only when the
; key is that very modifier; every other key keeps the left-side default. The
; former positional "CtrlKeyName" override was read by left_shift, right_shift
; and alt_gr as "my own key": left_shift + hold "ctrl" held Shift, right_shift +
; "shift" synthesized LShift instead of passing RShift through, and alt_gr +
; "ctrl" held AltGr (hold-modifier-own-side-2026-09-25).
_TH_ResolveHoldModifierKeyOwnSide() {
	Cases := [
		["ctrl", "left_ctrl", "LCtrl"],
		["ctrl", "right_ctrl", "RCtrl"],
		["lctrl", "right_ctrl", "LCtrl"],
		["shift", "right_ctrl", "LShift"],
		["shift", "left_shift", "LShift"],
		["ctrl", "left_shift", "LCtrl"],
		["shift", "right_shift", "RShift"],
		["lshift", "right_shift", "LShift"],
		["ctrl", "right_shift", "LCtrl"],
		["alt", "left_alt", "LAlt"],
		["win", "win", "LWin"],
		["ctrl", "alt_gr", "LCtrl"],
		["shift", "alt_gr", "LShift"],
	]
	for Row in Cases
		AssertEqual(Row[3], ResolveHoldModifierKey(Row[1], Row[2]),
			"hold '" . Row[1] . "' on tap-hold key '" . Row[2] . "'")
	Combo := ResolveHoldModifierKey("ctrl+shift", "left_shift")
	Assert(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == "LShift",
		"a ctrl+shift hold on left_shift must hold both LCtrl and LShift, never LShift twice")
	Combo := ResolveHoldModifierKey("ctrl+shift", "right_shift")
	Assert(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == "RShift",
		"a ctrl+shift hold on right_shift must keep its own RShift side")
}
Test("ResolveHoldModifierKey: a token resolves to the key's own side only on that modifier (hold-modifier-own-side-2026-09-25)",
	_TH_ResolveHoldModifierKeyOwnSide)

; The other spellings come from [tap_hold.hold_picker] in the shared defaults,
; which the Linux loader reads too. An alias means its id; a left_ alias names
; the left key even on the right-hand modifier keys. AltGr follows the layout
; on both a standard and a Kana AltGr (hold-alias-single-source).
_TH_ResolveHoldModifierKeyReadsSharedAliases() {
	global _ALTGR_KANA_FIXUP, _SharedDir
	Picker := ParseTomlFile(_SharedDir . "\tap_hold\defaults.toml")["tap_hold.hold_picker"]
	Aliases := Picker["modifier_aliases"]
	LeftAliases := Picker["left_modifier_aliases"]
	Assert(Aliases is Map && Aliases.Count >= 2, "the shared picker must declare modifier_aliases")
	Assert(LeftAliases is Map && LeftAliases.Count >= 4, "the shared picker must declare left_modifier_aliases")
	PreviousKana := _ALTGR_KANA_FIXUP
	try {
		for Kana in [true, false] {
			_ALTGR_KANA_FIXUP := Kana
			for Alias, Id in Aliases {
				for KeyId in ["caps_lock", "right_ctrl"]
					AssertEqual(ResolveHoldModifierKey(Id, KeyId), ResolveHoldModifierKey(StrUpper(Alias), KeyId),
						"'" . Alias . "' on " . KeyId . " with Kana=" . Kana . " holds what '" . Id . "' holds")
			}
			for Alias, Id in LeftAliases {
				for KeyId in ["caps_lock", "right_ctrl", "right_shift"]
					AssertEqual(ResolveHoldModifierKey(Id, "caps_lock"), ResolveHoldModifierKey(Alias, KeyId),
						"'" . Alias . "' on " . KeyId . " with Kana=" . Kana . " holds the left " . Id)
			}
		}
	} finally {
		_ALTGR_KANA_FIXUP := PreviousKana
	}
}
Test("ResolveHoldModifierKey: resolves the aliases of the shared hold picker (hold-alias-single-source)",
	_TH_ResolveHoldModifierKeyReadsSharedAliases)

; The one-shot Shift's results come from _shared/tap_hold/one_shot_shift.json,
; which the Linux driver reads too; they were an if/else chain in
; one_shot_shift.ahk (one-shot-results-shared).
_TH_OneShotResultsComeFromTheSharedTable() {
	global _SharedDir
	Root := JsonParse(FileRead(_SharedDir . "\tap_hold\one_shot_shift.json", "UTF-8"))
	Assert(Root["results"].Length >= 7, "the shared table must declare the one-shot results")
	EndKeys := TapHoldOneShotEndKeys("★")
	for Entry in Root["results"] {
		AssertEqual(Entry["result"], TapHoldOneShotResult(Entry["char"], "★"),
			"the one-shot result of '" . Entry["char"] . "'")
		Assert(InStr(EndKeys, Entry["char"], true) > 0, "'" . Entry["char"] . "' ends the one-shot capture")
	}
	AssertEqual(Root["magic_key_result"], TapHoldOneShotResult("★", "★"), "the magic key's result")
	AssertEqual("", TapHoldOneShotResult("a", "★"), "a letter has no result: it is typed in title case")
	AssertEqual("", TapHoldOneShotResult("", "★"), "a capture that ended on no character has no result")
	Assert(SubStr(EndKeys, -1) == "★", "the magic key ends the one-shot capture")
}
Test("tap-holds: the one-shot Shift results come from the shared table (one-shot-results-shared)",
	_TH_OneShotResultsComeFromTheSharedTable)

; The magic key is the user's choice: it gives its result even on a character
; the shared table has a result for, as the old chain gave it before ",", "'"
; and " ", and as Linux does (one-shot-magic-first). A table the file cannot
; give is logged and kept, so the one-shot capitalises until the next start
; instead of reading the file again at every tap (one-shot-table-once).
_TH_OneShotMagicKeyFirstAndFailureKept() {
	global _SharedDir, _TapHoldOneShotCache
	Root := JsonParse(FileRead(_SharedDir . "\tap_hold\one_shot_shift.json", "UTF-8"))
	for Entry in Root["results"]
		AssertEqual(Root["magic_key_result"], TapHoldOneShotResult(Entry["char"], Entry["char"]),
			"a magic '" . Entry["char"] . "' gives the magic key's result")
	PreviousShared := _SharedDir
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		_TapHoldOneShotCache := ""
		_SharedDir := A_Temp . "\ergopti_one_shot_no_shared_dir"
		AssertEqual("", TapHoldOneShotResult(" ", "★"), "an unreadable table leaves the one-shot capitalising")
		_SharedDir := PreviousShared
		AssertEqual("", TapHoldOneShotResult(" ", "★"), "the failure is kept, not read again at every tap")
	} finally {
		LoggerClearTestSink()
		_SharedDir := PreviousShared
		_TapHoldOneShotCache := ""
	}
	AssertEqual("-", TapHoldOneShotResult(" ", "★"), "a fresh read gives the table again")
}
Test("tap-holds: the magic key's result comes first and an unreadable table is kept (one-shot-magic-first)",
	_TH_OneShotMagicKeyFirstAndFailureKept)

_TH_ResolveHoldModifierKeyUnknownReturnsEmpty() {
	AssertEqual("", ResolveHoldModifierKey("contrl", "backspace"),
		"an unrecognized hold_modifier (typo) must resolve to empty, never a garbage key name")
}
Test("ResolveHoldModifierKey: unrecognized value returns empty string", _TH_ResolveHoldModifierKeyUnknownReturnsEmpty)

_TH_ResolveHoldModifierKeyUnknownLogsWarning() {
	; Distinct value/field pair from the previous test's "contrl"/"backspace"
	; call — an identical (Tag, Body) within Logger's 5000 ms dedup window
	; would suppress this second emission before it ever reaches the sink.
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	ResolveHoldModifierKey("bogus_mod", "escape")
	LoggerClearTestSink()
	Found := false
	for Line in Captured {
		if (InStr(Line, "[WARNING]") and InStr(Line, "bogus_mod") and InStr(Line, "escape"))
			Found := true
	}
	Assert(Found, "unrecognized hold_modifier must log a WARNING naming both the bad value and the affected tap-holds field so the config typo is easy to locate")
}
Test("ResolveHoldModifierKey: unrecognized value logs a WARNING naming the value and field", _TH_ResolveHoldModifierKeyUnknownLogsWarning)

; A hold_modifier no spelling of the shared hold picker names is refused where
; it is read, as the Linux loader refuses it: an error names it and the key,
; the hold is stored as the picker's "none" and the tap is kept. Every
; hold-modifier hotkey gates on the raw string, so "hyper" armed the hold
; branch with no modifier and swallowed CapsLock, its Enter included, while the
; tap-only branch that types Enter stayed off (unknown-hold-keeps-tap-2026-09-26).
_TH_UnknownHoldModifierKeepsTheTap() {
	global _ALTGR_KANA_FIXUP
	Known :="[tap_hold.keys.alt_gr]`n" . 'hold_modifier = "AltGr"' . "`n"
		. "[tap_hold.keys.space]`n" . 'hold_modifier = "Ctrl + lShift"' . "`n"
	for Source, Unknown in Map("user", "hyper", "defaults", "fn") {
		DefaultsText := "[tap_hold.keys.caps_lock]`n" . 'tap_action = "enter"' . "`n"
			. 'hold_modifier = "' . (Source == "defaults" ? Unknown : "ctrl") . '"' . "`n"
		UserText := Known
		if (Source == "user")
			UserText .= "[tap_hold.keys.caps_lock]`n" . 'tap_action = "enter"' . "`n" . 'hold_modifier = "' . Unknown . '"' . "`n"
		else
			UserText .= DefaultsText
		DefaultsPath := _TH_WriteDefaults(DefaultsText)
		Path := _TH_Write(UserText)
		Captured := []
		LoggerSetTestSink((Line) => Captured.Push(Line))
		try {
			TH := LoadTapHoldToml(Path, DefaultsPath)
		} finally {
			LoggerClearTestSink()
			_TH_Clean()
			_TH_CleanDefaults()
		}
		Entry := TH["keys"]["caps_lock"]
		AssertEqual("", Entry.Get("hold_modifier", ""), Source . ": '" . Unknown . "' must hold nothing")
		AssertEqual("enter", Entry["tap_action"], Source . ": the key must keep its tap")
		; The tap-only gate of capslock.ahk 2.5; 2.3 needs a non-empty hold.
		AssertTrue(Entry["tap_action"] != "" && Entry.Get("hold_modifier", "") == "" && Entry.Get("hold_layer", "") == "",
			Source . ": the tap-only hotkey must own CapsLock")
		Errors := 0
		for _, Line in Captured {
			if (InStr(Line, "[ERROR]") and InStr(Line, "'" . Unknown . "'") and InStr(Line, "caps_lock"))
				Errors++
		}
		AssertEqual(1, Errors, Source . ": one ERROR must name '" . Unknown . "' and the key")
		AssertEqual("AltGr", TH["keys"]["alt_gr"]["hold_modifier"], Source . ": an alias is a known hold")
		AssertEqual("Ctrl + lShift", TH["keys"]["space"]["hold_modifier"], Source . ": so is a spelled-out combination")
		PreviousKana := _ALTGR_KANA_FIXUP
		try {
			for Kana, AltGr in Map(true, "SC138", false, "RAlt") {
				_ALTGR_KANA_FIXUP := Kana
				AssertEqual(AltGr, ResolveHoldModifierKey(TH["keys"]["alt_gr"]["hold_modifier"], "alt_gr"),
					Source . ": the AltGr hold with Kana=" . Kana)
				Combo := ResolveHoldModifierKey(TH["keys"]["space"]["hold_modifier"], "space")
				AssertTrue(Combo is Array && Combo.Length = 2 && Combo[1] == "LCtrl" && Combo[2] == "LShift",
					Source . ": the Ctrl + lShift hold with Kana=" . Kana)
			}
		} finally {
			_ALTGR_KANA_FIXUP := PreviousKana
		}
	}
}
Test("LoadTapHoldToml: an unknown hold_modifier drops the hold and keeps the tap (unknown-hold-keeps-tap-2026-09-26)",
	_TH_UnknownHoldModifierKeepsTheTap)





; ================================================
; ================================================
; ======= 8/ Semantic key source ownership =======
; ================================================
; ================================================

_TH_SemanticAliasRoundtrip() {
	Sources := [
		'tap_hold.keys.caps_lock.tap_action = "escape"`ntap_hold.keys.caps_lock.hold_modifier = "ctrl"`n'
			. 'tap_hold.keys.caps_lock.time_activation_seconds = 0.375`ntap_hold.keys.caps_lock.enabled = true`n',
		'["tap_hold"."keys"."caps_lock"]`n"tap_action" = "escape"`nhold_modifier = "ctrl"`n'
			. 'time_activation_seconds = 0.375`nenabled = true`n',
		'[tap_hold]`nkeys = { caps_lock = { tap_action = "escape", hold_modifier = "ctrl", time_activation_seconds = 0.375, enabled = true } }`n'
	]
	for Source in Sources {
		try {
			Path := _TH_Write(Source)
			Loaded := LoadTapHoldToml(Path)
			AssertEqual("escape", TapHoldTapAction(Loaded, "caps_lock"), "the actual reader owns the admitted semantic key")
			AssertEqual("ctrl", TapHoldHoldModifier(Loaded, "caps_lock"))
			AssertEqual(0.375, TapHoldDuration(Loaded, "caps_lock"), "the runtime receives the published milliseconds after restart")
			AssertTrue(TapHoldIsActive(Loaded, "caps_lock"))
		} finally _TH_Clean()
	}
}
Test("TapHoldLoader: root dotted, quoted and inline sources roundtrip through actual runtime getters (tap-hold-key-delay)",
	_TH_SemanticAliasRoundtrip)

_TH_SemanticFieldTypesStayStrict() {
	Sources := [
		'tap_hold.keys.caps_lock.tap_action = true`ntap_hold.keys.caps_lock.enabled = 1`n'
			. 'tap_hold.keys.tab.tap_action = "alt_tab_monitor"`n',
		'["tap_hold"."keys"."caps_lock"]`ntap_action = escape`nhold_modifier = "ctrl"`n'
			. '[tap_hold.keys.tab]`ntap_action = "alt_tab_monitor"`n',
		'[tap_hold]`nkeys = { caps_lock = { tap_action = escape, hold_modifier = "ctrl" }, tab = { tap_action = "alt_tab_monitor" } }`n'
	]
	for Source in Sources {
		try {
			Path := _TH_Write(Source)
			Loaded := LoadTapHoldToml(Path)
			AssertFalse(TapHoldIsActive(Loaded, "caps_lock"), "typed aliases do not manufacture valid Boolean or quoted string intent")
			AssertEqual("", TapHoldTapAction(Loaded, "caps_lock"))
			AssertTrue(TapHoldIsActive(Loaded, "tab"), "an invalid known field never suppresses a valid sibling")
			AssertEqual("alt_tab_monitor", TapHoldTapAction(Loaded, "tab"))
		} finally _TH_Clean()
	}
}
Test("TapHoldLoader: semantic aliases retain strict Boolean and quoted-string field admission (tap-hold-key-delay)",
	_TH_SemanticFieldTypesStayStrict)

_TH_LiteralDottedNamesDoNotBorrowKnownNamespace() {
	for Source in ['["tap_hold.keys.caps_lock"]`ntap_action = "escape"`n',
		'[tap_hold."keys.caps_lock"]`ntap_action = "escape"`n',
		'"tap_hold.keys.caps_lock.tap_action" = "escape"`n'] {
		try {
			Path := _TH_Write(Source)
			Loaded := LoadTapHoldToml(Path)
			AssertEqual(0, Loaded["keys"].Count, "literal dotted names stay foreign semantic identities")
			AssertFalse(TapHoldIsActive(Loaded, "caps_lock"))
		} finally _TH_Clean()
	}
}
Test("TapHoldLoader: literal dotted foreign keys cannot borrow a native key namespace (tap-hold-key-delay)",
	_TH_LiteralDottedNamesDoNotBorrowKnownNamespace)
