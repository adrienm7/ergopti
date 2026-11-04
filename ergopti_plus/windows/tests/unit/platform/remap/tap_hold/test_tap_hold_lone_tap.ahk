; tests/unit/platform/remap/tap_hold/test_tap_hold_lone_tap.ahk

; ==============================================================================
; MODULE: Tap-hold lone tap window
; DESCRIPTION:
; How long a key whose hold is a modifier, pressed alone, still types its tap
; (tap_holds.lone_modifier_tap_max_ms, lone-tap-window): the window a press
; takes, the boot reader of config.toml, the tray row's caption and choices,
; and a choice's commit on a file of its own with a recorded reload.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with the window and the tap-hold state restored afterwards.
_THLT_With(Body) {
	global TAP_HOLD_LONE_TAP_MAX_MS, TapHold
	Saved := [TAP_HOLD_LONE_TAP_MAX_MS, TapHold]
	TapHold := Map("keys", Map())
	try Body.Call()
	finally TAP_HOLD_LONE_TAP_MAX_MS := Saved[1], TapHold := Saved[2]
}

_THLT_TapMaxFollowsTheWindow() {
	_THLT_With(_THLT_TapMaxBody)
}
_THLT_TapMaxBody() {
	TapHoldSetLoneTapMaxMs(1000)
	AssertEqual(1000, TapHoldTapMaxMs("caps_lock", 0.2), "a modifier key alone taps up to the window")
	AssertEqual(200, TapHoldTapMaxMs("space", 0.2), "a typing key keeps its threshold")
	TapHoldSetLoneTapMaxMs(0)
	AssertEqual(200, TapHoldTapMaxMs("caps_lock", 0.2), "off: the strict tap-hold threshold applies")
}
Test("tap-hold: a modifier key alone taps up to the window, a typing key never (lone-tap-window)",
	_THLT_TapMaxFollowsTheWindow)

_THLT_ReaderFollowsTheConfig() {
	_THLT_With(_THLT_ReaderBody)
}
_THLT_ReaderBody() {
	Default := ManifestDefaultFor(ConfigKey.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS)
	TapHoldLoneTapReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS, 0)))
	AssertEqual(0, TapHoldLoneTapMaxMs(), "a stored 0 turns the window off")
	TapHoldLoneTapReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS, 750)))
	AssertEqual(750, TapHoldLoneTapMaxMs(), "a stored window applies")
	TapHoldLoneTapReadConfig(Map())
	AssertEqual(Default, TapHoldLoneTapMaxMs(), "an absent window is the manifest default")
	TapHoldLoneTapReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS, -5)))
	AssertEqual(Default, TapHoldLoneTapMaxMs(), "a negative window is refused for the default")
	TapHoldLoneTapReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS, "soon")))
	AssertEqual(Default, TapHoldLoneTapMaxMs(), "a window that is no number is refused for the default")
}
Test("tap-hold: the boot reads the window, an absent or invalid one leaves the default (lone-tap-window)",
	_THLT_ReaderFollowsTheConfig)

_THLT_RowCaptionsTheWindow() {
	Off := _TH_LoneTapRows(0)
	AssertEqual(1, Off.Length, "one row")
	AssertEqual(StrReplace(t("menu.tapholds.lone_tap_title"), "%s", t("menu.tapholds.lone_tap_off")),
		Off[1]["label"], "0 reads as off")
	On := _TH_LoneTapRows(1000)
	AssertEqual(StrReplace(t("menu.tapholds.lone_tap_title"), "%s",
		StrReplace(t("menu.tapholds.lone_tap_up_to"), "%s", "1000 ms")), On[1]["label"], "1000 reads as up to 1000 ms")
	Choices := On[1]["items"]
	AssertEqual(_TH_LoneTapChoicesMs().Length, Choices.Length, "one choice per declared window")
	Checked := []
	for _, Choice in Choices {
		if Choice["checked"]
			Checked.Push(Choice["label"])
		Assert(HasMethod(Choice["action"], "Call"), "every choice commits")
	}
	AssertEqual(1, Checked.Length, "exactly one choice is checked")
	AssertEqual("1000 ms", Checked[1], "the window in force is checked")
	AssertEqual(t("menu.tapholds.lone_tap_off"), Choices[1]["label"], "the first choice is off")
}
Test("tap-hold menu: the row captions the window and checks its choice (lone-tap-window)",
	_THLT_RowCaptionsTheWindow)

_THLT_ChoiceCommitsTheSparseOperation() {
	Path := A_Temp . "\ergopti_thlt_lone_tap_" . DllCall("GetCurrentProcessId", "UInt") . ".toml"
	if FileExist(Path)
		FileDelete(Path)
	FileAppend("", Path, "UTF-8-RAW")
	Reloads := 0
	Reload := () => (Reloads += 1, "reloaded")
	try {
		Owner := _ConfigWriteLeaseTryAcquire(Path, "lone-tap-refusal")
		AssertTrue(Owner is Object, "the test holds the write lease")
		try AssertEqual(false, _TH_CommitLoneTapMaxMs(500, Path, Reload), "a refused commit reports false")
		finally _ConfigWriteLeaseRelease(Owner)
		AssertEqual(0, Reloads, "a refused commit never reloads")
		AssertEqual("", FileRead(Path, "UTF-8"), "a refused commit writes nothing")
		AssertEqual(false, _TH_CommitLoneTapMaxMs(-1, Path, Reload), "a negative window changes nothing")
		AssertEqual(0, Reloads, "a refused window never reloads")
		AssertEqual("reloaded", _TH_CommitLoneTapMaxMs(500, Path, Reload), "a commit answers with its reload")
		AssertEqual(1, Reloads, "a commit reloads once")
		Parsed := TOML_ParseFreshFile(Path)
		Assert(Parsed.Has(ConfigLeaf.TAP_HOLDS), "the commit writes [tap_holds]")
		AssertEqual(500, Parsed[ConfigLeaf.TAP_HOLDS][ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS], "the chosen window reaches the file")
		AssertEqual("reloaded", _TH_CommitLoneTapMaxMs(0, Path, Reload), "off commits too")
		Parsed := TOML_ParseFreshFile(Path)
		AssertEqual(0, Parsed[ConfigLeaf.TAP_HOLDS][ConfigLeaf.LONE_MODIFIER_TAP_MAX_MS], "off reaches the file as 0")
	} finally FileDelete(Path)
}
Test("tap-hold menu: a choice commits its sparse operation, then reloads once (lone-tap-window)",
	_THLT_ChoiceCommitsTheSparseOperation)
