; tests/unit/test_hotstring_idle_click_reset.ahk

; ==============================================================================
; MODULE: Idle and Click Word-Reset Tests
; DESCRIPTION:
; After a pause without typing, or after a mouse click, the engine kept the
; previous word: the next key was read as the middle of that word and every
; word-start hotstring stayed silent until a delimiter. These tests pin
; hotstrings.idle_reset_seconds (a pause starts a new word, 0 disables it) and
; hotstrings.click_resets_word (a click starts a new word, or only empties the
; buffer), their menu commands and the choice row's free-entry caption.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Pure idle rule ============
; ======================================
; ======================================

_HICR_IdleRuleVectors() {
	AssertFalse(HSE_IdleResetsWord("", 50000, 3), "no previous key is no pause")
	AssertFalse(HSE_IdleResetsWord(1000, 3999, 3), "a gap below the delay keeps the word")
	AssertTrue(HSE_IdleResetsWord(1000, 4000, 3), "the configured delay is inclusive")
	AssertFalse(HSE_IdleResetsWord(1000, 999999, 0), "0 disables the reset")
	AssertTrue(HSE_IdleResetsWord(1000, 2500, 1.5), "fractional delays are honoured")
	AssertFalse(HSE_IdleResetsWord(1000, 2499, 1.5))
	Refused := false
	try HSE_IdleResetsWord(1000, 9000, -1)
	catch ValueError
		Refused := true
	AssertTrue(Refused, "a negative delay is refused, never read as disabled")
}

_HICR_ValidValues() {
	for Value in [0, 3, 4.5, 3600]
		AssertTrue(HSE_ValidIdleResetSeconds(Value), "valid: " . Value)
	for Value in [-1, -0.5, "3", "", Map()]
		AssertFalse(HSE_ValidIdleResetSeconds(Value), "invalid value accepted")
}

_HICR_PromptParsing() {
	AssertEqual(3, ParseHotstringsIdleResetSeconds("3"))
	AssertTrue(ParseHotstringsIdleResetSeconds("3") is Integer, "an integral entry stays an integer")
	AssertEqual(4.5, ParseHotstringsIdleResetSeconds("4,5"), "a decimal comma is accepted")
	AssertEqual(4.5, ParseHotstringsIdleResetSeconds(" 4.5 "))
	AssertEqual(0, ParseHotstringsIdleResetSeconds("0"))
	for Raw in ["-1", "abc", "", "1e3", "3s"]
		AssertEqual("", ParseHotstringsIdleResetSeconds(Raw), "refused entry: " . Raw)
}

Test("hotstring idle reset: pure rule vectors", _HICR_IdleRuleVectors)
Test("hotstring idle reset: valid delay values", _HICR_ValidValues)
Test("hotstring idle reset: prompt parsing", _HICR_PromptParsing)





; =============================================
; =============================================
; ======= 2/ Watcher behaviour ================
; =============================================
; =============================================

; Types a mid-word "x", pauses for Gap ms under Seconds, then types the
; word-start trigger "ct★". Returns whether the trigger matched.
_HICR_TriggerAfterPause(Seconds, Gap) {
	global HSE_IdleResetSeconds, _PrefixLastKeyTick, _PrefixFocusedControlToken
	SavedSeconds := HSE_IdleResetSeconds
	SavedToken := _PrefixFocusedControlToken
	try {
		HSE_TestReset()
		HSE_IdleResetSeconds := Seconds
		_PrefixFocusedControlToken := 1
		HSE_Register("*", "ct★", 0, Map("Replacement", "c’était", "OnlyText", true,
			"Category", "magickey", "Section", "replace"))
		_PrefixApplyIdleReset(1000)
		HSE_FeedChar("x", true)
		_PrefixApplyIdleReset(1000 + Gap)
		HSE_FeedChar("c", true)
		_PrefixApplyIdleReset(1000 + Gap + 50)
		HSE_FeedChar("t", true)
		_PrefixApplyIdleReset(1000 + Gap + 100)
		return IsObject(HSE_FeedChar("★", true))
	} finally {
		HSE_IdleResetSeconds := SavedSeconds
		_PrefixFocusedControlToken := SavedToken
		HSE_TestReset()
	}
}

_HICR_PauseStartsWord() {
	AssertTrue(_HICR_TriggerAfterPause(3, 3000),
		"after the configured pause a word-start trigger must fire")
}

_HICR_ShortPauseKeepsWord() {
	AssertFalse(_HICR_TriggerAfterPause(3, 2999),
		"a pause below the delay keeps the word in progress")
}

_HICR_ZeroDisables() {
	AssertFalse(_HICR_TriggerAfterPause(0, 600000),
		"0 keeps the buffer forever, the behaviour before the setting")
}

; The menu default is the manifest's, read when nothing was published.
_HICR_DefaultIsTheManifests() {
	global HSE_IdleResetSeconds, HSE_ClickResetsWord
	SavedSeconds := HSE_IdleResetSeconds, SavedClick := HSE_ClickResetsWord
	try {
		HSE_IdleResetSeconds := "", HSE_ClickResetsWord := ""
		AssertEqual(ManifestDefaultFor("hotstrings.idle_reset_seconds"), HSE_IdleResetSecondsCurrent())
		AssertEqual(3, HSE_IdleResetSecondsCurrent(), "the requested default is 3 s")
		AssertTrue(HSE_ClickResetsWordCurrent(), "a click starts a new word by default")
	} finally {
		HSE_IdleResetSeconds := SavedSeconds, HSE_ClickResetsWord := SavedClick
	}
}

; Clicking with Value published, then typing into a newly focused control.
_HICR_ClickBoundary(Value) {
	global HSE_ClickResetsWord, HSE_Buffer, HSE_StartIsWordBoundary
	global _PrefixFocusedControlToken
	SavedClick := HSE_ClickResetsWord, SavedToken := _PrefixFocusedControlToken
	try {
		HSE_TestReset()
		HSE_ClickResetsWord := Value
		_PrefixFocusedControlToken := 1
		HSE_FeedChar("a", true)
		HSE_FeedChar("b", true)
		_OnMouseClickReset()
		AssertEqual("", HSE_Buffer, "a click always empties the buffer")
		AssertEqual(Value, HSE_StartIsWordBoundary, "the click's word-start verdict")
		AssertTrue(_PrefixEnsureInputContext(7), "the next control is admitted")
		AssertEqual(Value, HSE_StartIsWordBoundary,
			"binding the new control must keep the click's verdict")
	} finally {
		HSE_ClickResetsWord := SavedClick
		_PrefixFocusedControlToken := SavedToken
		HSE_TestReset()
	}
}

Test("hotstring idle reset: a pause starts a new word", _HICR_PauseStartsWord)
Test("hotstring idle reset: a short pause keeps the word", _HICR_ShortPauseKeepsWord)
Test("hotstring idle reset: 0 disables the reset", _HICR_ZeroDisables)
Test("hotstring idle reset: defaults come from the manifest", _HICR_DefaultIsTheManifests)
Test("hotstring click reset: on, a click starts a new word", (*) => _HICR_ClickBoundary(true))
Test("hotstring click reset: off, a click leaves the word start unknown", (*) => _HICR_ClickBoundary(false))





; =========================================
; =========================================
; ======= 3/ Menu and persistence =========
; =========================================
; =========================================

global _HICR_Writes := []

_HICR_Writer(Path, Updates) {
	global _HICR_Writes
	_HICR_Writes.Push(Updates[1])
	return true
}

_HICR_Rebuild() => 1

; Runs Body against the scope-owner configuration fixture, restoring the
; configuration path, both engine globals and the Features leaves afterwards.
_HICR_WithFixture(Body) {
	global ConfigurationFile, Features, HSE_IdleResetSeconds, HSE_ClickResetsWord
	Hotstrings := Features["hotstrings"]
	Saved := { path: ConfigurationFile, seconds: HSE_IdleResetSeconds, click: HSE_ClickResetsWord,
		leaves: Map() }
	for Key in ["idle_reset_seconds", "click_resets_word"]
		if Hotstrings.Has(Key)
			Saved.leaves[Key] := Hotstrings[Key]
	Fixture := _ScopeOwnerFixture()
	try {
		ConfigurationFile := Fixture.path
		Body()
	} finally {
		ConfigurationFile := Saved.path
		HSE_IdleResetSeconds := Saved.seconds, HSE_ClickResetsWord := Saved.click
		for Key in ["idle_reset_seconds", "click_resets_word"] {
			if Saved.leaves.Has(Key)
				Hotstrings[Key] := Saved.leaves[Key]
			else if Hotstrings.Has(Key)
				Hotstrings.Delete(Key)
		}
		PreviousCritical := Critical("Off")
		try _ScopeOwnerCleanup(Fixture)
		finally Critical(PreviousCritical)
	}
}

_HICR_SettersPersistAndPublish() {
	global _HICR_Writes, HSE_IdleResetSeconds, HSE_ClickResetsWord
	SavedSeconds := HSE_IdleResetSeconds, SavedClick := HSE_ClickResetsWord
	try {
		_HICR_Writes := []
		HSE_ClickResetsWord := true
		AssertTrue(SetHotstringsIdleResetSeconds(5, _HICR_Writer, (*) => 0, _HICR_Rebuild))
		AssertEqual(5, HSE_IdleResetSeconds, "the engine reads the new delay at once")
		AssertTrue(ToggleHotstringsClickResetsWord(_HICR_Writer, (*) => 0, _HICR_Rebuild))
		AssertFalse(HSE_ClickResetsWord)
		AssertEqual(2, _HICR_Writes.Length)
		AssertEqual("hotstrings", _HICR_Writes[1].Section)
		AssertEqual("idle_reset_seconds", _HICR_Writes[1].Key)
		AssertEqual(5, _HICR_Writes[1].Value)
		AssertEqual("click_resets_word", _HICR_Writes[2].Key)
		AssertTrue(_HICR_Writes[2].Value is TOML_Bool, "the toggle is written as a TOML boolean")
		AssertFalse(_HICR_Writes[2].Value.Value)
		AssertFalse(SetHotstringsIdleResetSeconds(-2, _HICR_Writer, (*) => 0, _HICR_Rebuild),
			"a negative delay is never written")
		AssertEqual(2, _HICR_Writes.Length)
	} finally {
		HSE_IdleResetSeconds := SavedSeconds, HSE_ClickResetsWord := SavedClick
	}
}

_HICR_PromptRefusesAndAccepts() {
	global _HICR_Writes, HSE_IdleResetSeconds
	SavedSeconds := HSE_IdleResetSeconds
	try {
		_HICR_Writes := []
		HSE_IdleResetSeconds := 3
		Prefilled := ""
		Notices := []
		Prompt(Text, Title, Options, Default) {
			Prefilled := Default
			return { Result: "OK", Value: "-4" }
		}
		AssertFalse(PromptHotstringsIdleResetSeconds(Prompt, _HICR_Writer,
			(Message, *) => Notices.Push(Message), _HICR_Rebuild))
		AssertEqual("3", Prefilled, "the prompt shows the delay in force")
		AssertEqual(1, Notices.Length, "an invalid entry is explained")
		AssertEqual(t("menu.hotstrings.idle_reset_invalid"), Notices[1])
		AssertEqual(0, _HICR_Writes.Length)
		AssertTrue(PromptHotstringsIdleResetSeconds(
			(*) => ({ Result: "OK", Value: "7,5" }), _HICR_Writer, (*) => 0, _HICR_Rebuild))
		AssertEqual(7.5, HSE_IdleResetSeconds)
		AssertFalse(PromptHotstringsIdleResetSeconds(
			(*) => ({ Result: "Cancel", Value: "9" }), _HICR_Writer, (*) => 0, _HICR_Rebuild))
		AssertEqual(1, _HICR_Writes.Length, "a cancelled prompt writes nothing")
	} finally {
		HSE_IdleResetSeconds := SavedSeconds
	}
}

; The declared choice draws the presets, then a free entry ticked when the
; value in force is none of them, with the value and its unit in the caption.
_HICR_ChoiceRowFreeEntry() {
	Chosen := []
	Custom := 0
	Commands := Map("idle_reset", (V) => Chosen.Push(V), "idle_reset_custom", (*) => Custom++)
	Unit := t("menu.hotstrings.idle_reset_unit")
	Row := MenuRenderer_ChoiceRow("hotstrings_params_group", "idle_reset", Commands,
		Map("hotstrings.idle_reset_seconds", () => 4.5))
	AssertTrue(Row is Map, "the idle choice must be declared for Windows")
	Items := Row["items"]
	AssertEqual(8, Items.Length, "six presets, a separator and the free entry")
	AssertEqual(t("menu.hotstrings.idle_reset_off"), Items[1]["label"])
	AssertEqual("3 " . Unit, Items[4]["label"])
	AssertTrue(Items[7].Get("separator", false))
	AssertEqual(t("menu.hotstrings.idle_reset_custom"), Items[8]["label"])
	AssertTrue(Items[8]["checked"], "a free value ticks the free entry")
	for Index in [1, 2, 3, 4, 5, 6]
		AssertFalse(Items[Index]["checked"])
	AssertTrue(InStr(Row["label"], "4.5 " . Unit) > 0, "the caption names the free value")
	Items[5]["action"].Call()
	Items[8]["action"].Call("item", 8, 0)
	AssertEqual(1, Chosen.Length)
	AssertEqual(5, Chosen[1])
	AssertEqual(1, Custom)

	Row := MenuRenderer_ChoiceRow("hotstrings_params_group", "idle_reset", Commands,
		Map("hotstrings.idle_reset_seconds", () => 3))
	AssertTrue(Row["items"][4]["checked"], "a preset value ticks its preset")
	AssertFalse(Row["items"][8]["checked"])
	AssertTrue(InStr(Row["label"], "3 " . Unit) > 0)
}

; The loader reads both settings through one owner and never boots a negative
; delay: an outdated value is a WARNING and the manifest default.
_HICR_LoaderRejectsNegative() {
	Body := _DriverFuncBody("_FeatureStateIdleResetSeconds")
	Assert(Body != "", "_FeatureStateIdleResetSeconds must exist")
	AssertTrue(InStr(Body, "Raw >= 0") > 0, "the loader admits only non-negative delays")
	AssertTrue(InStr(Body, "LoggerWarn(") > 0, "an outdated delay is reported")
	AssertTrue(InStr(Body, 'ManifestDefaultFor("hotstrings.idle_reset_seconds")') > 0)
	Reader := _DriverFuncBody("ReadScriptConfig")
	AssertTrue(InStr(Reader, '_FeatureStateIniGet(Cache, "hotstrings", "idle_reset_seconds")') > 0)
	AssertTrue(InStr(Reader, '"hotstrings.click_resets_word"') > 0)
	Click := _DriverFuncBody("_OnMouseClickReset")
	AssertTrue(InStr(Click, "_PrefixInvalidateInputContext(0, HSE_ClickResetsWordCurrent())") > 0,
		"the click verdict follows the setting")
	for Callback in ["_OnPrefixKeyDown", "_OnPrefixChar"]
		AssertTrue(InStr(_DriverFuncBody(Callback), "_PrefixApplyIdleReset(A_TickCount)") > 0,
			Callback . " must apply the idle rule")
}

Test("hotstring word reset: setters persist and publish", (*) => _HICR_WithFixture(_HICR_SettersPersistAndPublish))
Test("hotstring word reset: the free-entry prompt", (*) => _HICR_WithFixture(_HICR_PromptRefusesAndAccepts))
Test("hotstring word reset: the choice row's free entry", _HICR_ChoiceRowFreeEntry)
Test("hotstring word reset: the loader and the watcher wiring", _HICR_LoaderRejectsNegative)
