; tests/unit/platform/remap/tap_hold/test_tap_hold_one_shot_timeout.ahk

; ==============================================================================
; MODULE: One-shot Shift timeout setting
; DESCRIPTION:
; How long a one-shot Shift waits for its key (tap_holds.sticky_timeout_ms, the
; leaf macOS reads, one-shot-timeout-setting): the boot reader of config.toml,
; the tray row's caption, and the commit on a file of its own with a recorded
; reload. 0 is no time limit (decision of 2026-11-13): the hooks then carry no
; T option. A negative or fractional value is refused, as on macOS and Linux.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with the timeout restored afterwards.
_THOS_With(Body) {
	global ONE_SHOT_SHIFT_TIMEOUT_SEC
	Saved := ONE_SHOT_SHIFT_TIMEOUT_SEC
	try Body.Call()
	finally ONE_SHOT_SHIFT_TIMEOUT_SEC := Saved
}

_THOS_ReaderFollowsTheConfig() {
	_THOS_With(_THOS_ReaderBody)
}
_THOS_ReaderBody() {
	Default := TimingsGet("tap_hold", "one_shot_shift_timeout_ms")
	TapHoldOneShotTimeoutReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.STICKY_TIMEOUT_MS, 3500)))
	AssertEqual(3500, TapHoldOneShotTimeoutMs(), "a stored timeout applies")
	AssertEqual(3.5, ONE_SHOT_SHIFT_TIMEOUT_SEC, "the capture waits the stored timeout")
	TapHoldOneShotTimeoutReadConfig(Map())
	AssertEqual(Default, TapHoldOneShotTimeoutMs(), "an absent timeout is the registry default")
	TapHoldOneShotTimeoutReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.STICKY_TIMEOUT_MS, 0)))
	AssertEqual(0, TapHoldOneShotTimeoutMs(), "0 is read as no time limit")
	AssertEqual("", TapHoldOneShotHookTimeoutOption(), "no time limit: the hook has no T option")
	TapHoldOneShotTimeoutReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.STICKY_TIMEOUT_MS, 1)))
	AssertEqual(" T0.001", TapHoldOneShotHookTimeoutOption(), "1 ms is a valid timeout, no other minimum")
	for _, Bad in [-5, 2.5, "soon"] {
		TapHoldOneShotTimeoutReadConfig(Map(ConfigLeaf.TAP_HOLDS, Map(ConfigLeaf.STICKY_TIMEOUT_MS, Bad)))
		AssertEqual(Default, TapHoldOneShotTimeoutMs(), "a refused timeout leaves the default: " . String(Bad))
	}
}
Test("tap-hold: the boot reads the one-shot timeout, an absent or invalid one leaves the default (one-shot-timeout-setting)",
	_THOS_ReaderFollowsTheConfig)

_THOS_RowCaptionsTheTimeout() {
	_THOS_With(_THOS_RowBody)
}
_THOS_RowBody() {
	global ONE_SHOT_SHIFT_TIMEOUT_SEC
	ONE_SHOT_SHIFT_TIMEOUT_SEC := 1.5
	Rows := _TH_OneShotDelayRows()
	AssertEqual(1, Rows.Length, "one row")
	AssertEqual(StrReplace(t("menu.tapholds.sticky_title"), "%s", "1500 ms"), Rows[1]["label"], "the caption carries the value")
	Assert(HasMethod(Rows[1]["action"], "Call"), "the row asks for a new value")
	ONE_SHOT_SHIFT_TIMEOUT_SEC := 0
	AssertEqual(StrReplace(t("menu.tapholds.sticky_title"), "%s", t("menu.tapholds.sticky_no_limit")),
		_TH_OneShotDelayRows()[1]["label"], "0 is captioned as no time limit")
}
Test("tap-hold menu: the one-shot timeout row captions the value in force (one-shot-timeout-setting)",
	_THOS_RowCaptionsTheTimeout)

_THOS_HookBoundaryRefusesAlteredValue() {
	_THOS_With(_THOS_HookBoundaryBody)
}
_THOS_HookBoundaryBody() {
	global ONE_SHOT_SHIFT_TIMEOUT_SEC
	for _, Bad in ["2", -1, "soon"] {
		ONE_SHOT_SHIFT_TIMEOUT_SEC := Bad
		Threw := false
		try TapHoldOneShotHookTimeoutOption()
		catch
			Threw := true
		Assert(Threw, "a value altered after load fails fast at the hook: " . String(Bad))
	}
}
Test("tap-hold: the one-shot hook timeout refuses a value altered after load (one-shot-timeout-setting)",
	_THOS_HookBoundaryRefusesAlteredValue)

_THOS_CommitWritesTheLeaf() {
	Path := A_Temp . "\ergopti_thos_one_shot_" . DllCall("GetCurrentProcessId", "UInt") . ".toml"
	if FileExist(Path)
		FileDelete(Path)
	FileAppend("", Path, "UTF-8-RAW")
	Reloads := 0
	Reload := () => (Reloads += 1, "reloaded")
	try {
		for _, Bad in [-1, 2.5, "3000"]
			AssertEqual(false, _TH_CommitOneShotTimeoutMs(Bad, Path, Reload), "refused: " . String(Bad))
		AssertEqual(0, Reloads, "a refused timeout never reloads")
		AssertEqual("", FileRead(Path, "UTF-8"), "a refused timeout writes nothing")
		AssertEqual("reloaded", _TH_CommitOneShotTimeoutMs(3000, Path, Reload), "a commit answers with its reload")
		AssertEqual(1, Reloads, "a commit reloads once")
		Parsed := TOML_ParseFreshFile(Path)
		AssertEqual(3000, Parsed[ConfigLeaf.TAP_HOLDS][ConfigLeaf.STICKY_TIMEOUT_MS], "the timeout reaches the file")
		Answer := { Result: "OK", Value: "4000" }
		AssertEqual("reloaded", _TH_PromptOneShotDelay((*) => Answer, Path, Reload), "the prompt commits its answer")
		Parsed := TOML_ParseFreshFile(Path)
		AssertEqual(4000, Parsed[ConfigLeaf.TAP_HOLDS][ConfigLeaf.STICKY_TIMEOUT_MS], "the prompted timeout reaches the file")
		for _, BadAnswer in ["-5", "1.5", "soon"] {
			Answer := { Result: "OK", Value: BadAnswer }
			AssertEqual(false, _TH_PromptOneShotDelay((*) => Answer, Path, Reload), "refused answer: " . BadAnswer)
		}
		Answer := { Result: "OK", Value: "0" }
		AssertEqual("reloaded", _TH_PromptOneShotDelay((*) => Answer, Path, Reload), "a zero answer is no time limit")
		Parsed := TOML_ParseFreshFile(Path)
		AssertEqual(0, Parsed[ConfigLeaf.TAP_HOLDS][ConfigLeaf.STICKY_TIMEOUT_MS], "0 reaches the file")
		AssertEqual("reloaded", _TH_CommitOneShotTimeoutMs(TimingsGet("tap_hold", "one_shot_shift_timeout_ms"), Path, Reload),
			"the default commits too")
		Parsed := TOML_ParseFreshFile(Path)
		Section := Parsed.Has(ConfigLeaf.TAP_HOLDS) ? Parsed[ConfigLeaf.TAP_HOLDS] : Map()
		AssertFalse(Section.Has(ConfigLeaf.STICKY_TIMEOUT_MS), "the default is an absent leaf, as on macOS")
	} finally FileDelete(Path)
}
Test("tap-hold menu: the one-shot timeout commits its leaf, then reloads once (one-shot-timeout-setting)",
	_THOS_CommitWritesTheLeaf)
