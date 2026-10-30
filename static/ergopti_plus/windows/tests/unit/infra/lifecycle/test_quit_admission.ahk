; tests/unit/infra/lifecycle/test_quit_admission.ahk

; ==============================================================================
; MODULE: Quit Admission Tests (Windows)
; DESCRIPTION:
; The cases of _shared/lua/test/quit_admission_contract.lua on the Windows port,
; the tray's request with an OnExit veto, the notice, and the feature notices'
; contract of _shared/lua/test/feature_notice_contract.lua.
; ==============================================================================

#Requires AutoHotkey v2.0

_TQA_Facts(Overrides := 0) {
	Facts := Map("owner_available", 1, "exit_pending", 0, "reload_pending", 0, "writer_active", 0, "publication_pending", 0)
	if (Overrides is Map) {
		for Name, Value in Overrides
			Facts[Name] := Value
	}
	return Facts
}

_TQA_Decide() {
	Plain := QuitAdmission_Decide(_TQA_Facts())
	AssertTrue(Plain["admitted"])
	AssertFalse(Plain["abandon_reload"])
	Reload := QuitAdmission_Decide(_TQA_Facts(Map("reload_pending", 1)))
	AssertTrue(Reload["admitted"] && Reload["abandon_reload"], "Quit wins over a reload in flight")
	Missing := QuitAdmission_Decide(_TQA_Facts(Map("owner_available", 0)))
	AssertFalse(Missing["admitted"] || Missing["deferred"])
	AssertEqual("owner_unavailable", Missing["cause"])
	Exiting := QuitAdmission_Decide(_TQA_Facts(Map("exit_pending", 1, "reload_pending", 1)))
	AssertFalse(Exiting["admitted"] || Exiting["deferred"])
	AssertEqual("exit_pending", Exiting["cause"])
	for Name in ["writer_active", "publication_pending"] {
		Deferred := QuitAdmission_Decide(_TQA_Facts(Map(Name, 1, "reload_pending", 1)))
		AssertFalse(Deferred["admitted"], Name)
		AssertTrue(Deferred["deferred"], Name . " defers, never refuses")
		AssertEqual(Name, Deferred["cause"])
	}
	All := _TQA_Facts(Map("owner_available", 0, "exit_pending", 1, "writer_active", 1, "publication_pending", 1))
	AssertEqual("owner_unavailable", QuitAdmission_Decide(All)["cause"], "the first cause is named")
	All["owner_available"] := 1
	AssertEqual("exit_pending", QuitAdmission_Decide(All)["cause"])
	All["exit_pending"] := 0
	AssertEqual("writer_active", QuitAdmission_Decide(All)["cause"])
	All["writer_active"] := 0
	AssertEqual("publication_pending", QuitAdmission_Decide(All)["cause"])
	for Name in QUIT_ADMISSION_FACTS {
		Incomplete := _TQA_Facts()
		Incomplete[Name] := "no"
		AssertThrows(() => QuitAdmission_Decide(Incomplete), Name . " must be a boolean")
		Incomplete.Delete(Name)
		AssertThrows(() => QuitAdmission_Decide(Incomplete), Name . " must not be missing")
	}
	AssertThrows(() => QuitAdmission_Decide(0), "the facts are required")
}
Test("quit admission: the shared decision on Windows (PAR-45)", _TQA_Decide)

; The causes and their log lines are the Lua owner's, word for word.
_TQA_SameWording() {
	global _SharedDir, _DriverDir
	Lua := FileRead(_SharedDir . "\lua\quit_admission.lua", "UTF-8")
	for Cause, Text in QUIT_ADMISSION_MESSAGES {
		Assert(InStr(Lua, '"' . Cause . '"', true) > 0, "the Lua owner names " . Cause)
		Assert(InStr(Lua, '"' . Text . '"', true) > 0, "the Lua owner words " . Text)
	}
	for Name in QUIT_ADMISSION_FACTS
		Assert(InStr(Lua, '"' . Name . '"', true) > 0, "the Lua owner names the fact " . Name)
	Toml := FileRead(_SharedDir . "\modules\timings\constants.toml", "UTF-8")
	Assert(RegExMatch(Toml, "m)^user_quit_deadline_ms = (\d+)", &Deadline) > 0, "the shared deadline is declared")
	Body := FileRead(_DriverDir . "\infra\lifecycle.ahk", "UTF-8")
	Assert(InStr(Body, "global LIFECYCLE_USER_QUIT_DEADLINE_MS := " . Deadline[1]) > 0,
		"the Windows deadline mirrors [ui] user_quit_deadline_ms")
}
Test("quit admission: the wording and the deadline are the shared ones (PAR-45)", _TQA_SameWording)

; Builds request ports over a fake clock and a manual scheduler.
_TQA_Fixture(Facts) {
	F := { Clock: 0, Queue: [], Exits: 0, Notices: 0, Warns: [], RetryOwned: false, FactsNow: Facts, ExitFn: 0 }
	Ports := Map("facts", () => F.FactsNow, "now", () => F.Clock, "timeout", 10, "poll", 1,
		"schedule", (Ms, Callback) => (F.Queue.Push(Callback), true),
		"warn", (Text) => F.Warns.Push(Text),
		"exit", () => (F.Exits += 1, IsObject(F.ExitFn) ? F.ExitFn.Call() : 0),
		"retry_owned", () => F.RetryOwned,
		"notify", () => (F.Notices += 1))
	F.Ports := Ports
	return F
}
_TQA_Tick(F, Ms) {
	F.Clock += Ms
	Callback := F.Queue.RemoveAt(1)
	return Callback.Call()
}
_TQA_Reset() {
	global _QuitRequestWaiting, _QuitRequestExitOwed
	_QuitRequestWaiting := false
	_QuitRequestExitOwed := false
}

_TQA_Waits() {
	_TQA_Reset()
	F := _TQA_Fixture(_TQA_Facts(Map("writer_active", 1, "reload_pending", 1)))
	AssertTrue(QuitRequest_Run(F.Ports), "a running write is waited for")
	AssertEqual(0, F.Exits, "nothing exits while the write runs")
	AssertEqual(1, F.Warns.Length, "the wait is logged once")
	_TQA_Tick(F, 1)
	AssertEqual(0, F.Exits, "still running: still waiting")
	AssertEqual(1, F.Warns.Length)
	F.FactsNow := _TQA_Facts()
	AssertEqual("admitted", _TQA_Tick(F, 1))
	AssertEqual(1, F.Exits, "the write ended: the exit starts once")
	AssertEqual(1, F.Notices, "the fake ExitApp returned: a veto is told")
	_TQA_Reset()
}
Test("quit admission: Quit waits out a running write, then starts once (PAR-45)", _TQA_Waits)

_TQA_Expires() {
	_TQA_Reset()
	F := _TQA_Fixture(_TQA_Facts(Map("publication_pending", 1)))
	QuitRequest_Run(F.Ports)
	_TQA_Tick(F, 5)
	AssertEqual(0, F.Notices)
	AssertEqual("refused", _TQA_Tick(F, 5), "the bound passed")
	AssertEqual(0, F.Exits)
	AssertEqual(1, F.Notices, "the expired wait is told")
	AssertFalse(_QuitRequestWaiting)
	_TQA_Reset()
	NoTimer := _TQA_Fixture(_TQA_Facts(Map("writer_active", 1)))
	NoTimer.Ports["schedule"] := (Ms, Callback) => false
	AssertFalse(QuitRequest_Run(NoTimer.Ports), "no poll timer: refused at once")
	AssertEqual(1, NoTimer.Notices)
	AssertEqual(0, NoTimer.Exits)
}
Test("quit admission: an expired or unarmable wait is refused with the notice (PAR-45)", _TQA_Expires)

_TQA_Refusals() {
	_TQA_Reset()
	F := _TQA_Fixture(_TQA_Facts(Map("exit_pending", 1)))
	AssertFalse(QuitRequest_Run(F.Ports))
	AssertEqual(1, F.Notices, "an exit already under way is refused with the notice")
	AssertEqual(0, F.Queue.Length, "without waiting")
	AssertEqual(0, F.Exits)
	_TQA_Reset()
	Waiting := _TQA_Fixture(_TQA_Facts(Map("writer_active", 1)))
	QuitRequest_Run(Waiting.Ports)
	AssertTrue(QuitRequest_Run(Waiting.Ports), "the second click leaves the first wait in place")
	AssertEqual(1, Waiting.Notices, "the second click is told")
	AssertEqual(1, Waiting.Queue.Length, "no second wait starts")
	_TQA_Reset()
}
Test("quit admission: an exit already under way is refused with the notice (PAR-45)", _TQA_Refusals)

_TQA_Veto() {
	_TQA_Reset()
	F := _TQA_Fixture(_TQA_Facts())
	F.RetryOwned := true
	AssertTrue(QuitRequest_Run(F.Ports), "a veto with a retry owner is still on its way")
	AssertEqual(0, F.Notices, "the retry keeps the answer")
	F.RetryOwned := false
	AssertFalse(QuitRequest_ExitReturned(() => F.RetryOwned, () => F.Notices += 1), "the retried exit was vetoed")
	AssertEqual(1, F.Notices, "the veto with nothing left is told")
	AssertFalse(QuitRequest_ExitReturned(() => F.RetryOwned, () => F.Notices += 1), "only once")
	AssertEqual(1, F.Notices)
	_TQA_Reset()
	Abandoned := _TQA_Fixture(_TQA_Facts())
	Abandoned.RetryOwned := true
	QuitRequest_Run(Abandoned.Ports)
	QuitRequest_RetryAbandoned(() => Abandoned.Notices += 1)
	AssertEqual(1, Abandoned.Notices, "a retry that gave up is told")
	QuitRequest_RetryAbandoned(() => Abandoned.Notices += 1)
	AssertEqual(1, Abandoned.Notices, "only once")
	_TQA_Reset()
	Other := 0
	QuitRequest_RetryAbandoned(() => Other += 1)
	AssertEqual(0, Other, "an exit the user did not ask for is not a refused Quit")
}
Test("quit admission: an OnExit veto is told unless a retry owns the exit (PAR-45)", _TQA_Veto)

_TQA_DriverWiring() {
	global _DriverDir
	Activate := _DriverFuncBody("ActivateExitApp")
	Assert(Activate != "", "the tray's Quit exists")
	Assert(InStr(Activate, "QuitRequest_Run(") > 0, "the tray's Quit goes through the admission")
	Assert(InStr(Activate, '"exit", () => ExitApp()') > 0, "ExitApp runs only as the admission's exit port")
	Facts := _DriverFuncBody("_LifecycleQuitFacts")
	for Owner in ["MenuCommandConfigBusy()", "ReloadTerminalHandoffPending()", "_LifecycleQuitRetryOwned()",
			"HSE_TerminalTransactionPending()", "_ConfigFullSaveHasPending()"]
		Assert(InStr(Facts, Owner) > 0, "the facts read " . Owner)
	Assert(InStr(_DriverFuncBody("_LifecycleRetryExitNow"), "QuitRequest_ExitReturned(") > 0,
		"a vetoed flush retry answers the owed Quit")
	Assert(InStr(_DriverFuncBody("_LifecycleRetrySupersededExit"), "QuitRequest_ExitReturned(") > 0,
		"a vetoed superseding retry answers the owed Quit")
	Assert(InStr(_DriverFuncBody("_LifecycleAbandonExitRetry"), "QuitRequest_RetryAbandoned(") > 0,
		"a retry that gave up answers the owed Quit")
	Assert(InStr(FileRead(_DriverDir . "\modules\gestures\actions.ahk", "UTF-8"), "Fn: (*) => ExitApp()") == 0,
		"the script_quit action is a Quit like the tray's row")
}
Test("quit admission: the tray and script_quit reach it, and retries answer it (PAR-45)", _TQA_DriverWiring)

; A captured display, so a toggle in a unit test never reaches the desktop.
global _TQA_Displayed := []
_TQA_Display(Message, Title, Flag) {
	global _TQA_Displayed
	_TQA_Displayed.Push(Map("message", Message, "flag", Flag))
	return 1
}
NotifierSetDisplaySink(_TQA_Display)

_TQA_Notices() {
	global _TQA_Displayed
	Logged := []
	LoggerSetTestSink((Line) => Logged.Push(Line))
	try {
		_TQA_Displayed := []
		NotifyFeature("Hotstrings", true)
		AssertEqual("Hotstrings", _TQA_Displayed[1]["message"])
		Sent := []
		NotifyFeature("Gestures", true, (Text, Opts) => (Sent.Push([Text, Opts["level"]]), true))
		AssertEqual("success", Sent[1][2], "enabled is the success level")
		NotifyFeature("Gestures", false, (Text, Opts) => (Sent.Push([Text, Opts["level"]]), true))
		AssertEqual("error", Sent[2][2], "disabled is the error level")
		NotifyFeature("X", "", (Text, Opts) => (Sent.Push([Text, Opts["level"]]), true))
		AssertEqual("error", Sent[3][2], "a non-boolean state reads as disabled")
		Raising(*) {
			throw Error("no daemon")
		}
		NotifyFeature("Shortcuts", true, Raising)
		NotifyFeature("Shortcuts", true, (*) => false)
		QuitNotice := []
		NotifyQuitRefused((Text, Opts) => (QuitNotice.Push([Text, Opts["level"]]), true))
		AssertEqual(t("notify.quit_refused"), QuitNotice[1][1], "the one locale key")
		AssertEqual("error", QuitNotice[1][2])
	} finally
		LoggerClearTestSink()
	Joined := ""
	for Line in Logged
		Joined .= Line . "`n"
	Assert(InStr(Joined, "Feature toggled from the menu: 'Hotstrings' " . Chr(0x2192) . " enabled.") > 0,
		"the switch is logged, in the shared wording")
	Assert(InStr(Joined, "Feature toggle notification failed: no daemon.") > 0, "a raising notifier is logged")
	Assert(InStr(Joined, "Feature toggle notification was not shown.") > 0, "a refused notice is logged")
	Assert(InStr(Joined, "Quit was refused; the user is notified.") > 0, "the refusal is logged")
}
Test("feature notices: the shared log line, levels and survival of the notifier (PAR-45)", _TQA_Notices)

_TQA_ToggleSites() {
	Body := _DriverFuncBody("ToggleFeatureV2")
	Live := InStr(Body, "NotifyFeature(")
	Assert(Live > 0 && InStr(Body, "NotifyFeature(", , Live + 1) > 0, "a feature row notifies on both of its paths")
	Assert(InStr(_DriverFuncBody("ToggleGesturesEnabled"), "NotifyFeature(") > 0, "the gestures switch notifies")
	Assert(InStr(_DriverFuncBody("SetScriptShortcutChordsOn"), "NotifyFeature(") > 0, "the script chords switch notifies")
	Assert(InStr(_DriverFuncBody("ToggleHotstringsPreviewSwitch"), "NotifyFeature(") > 0, "a preview switch notifies")
	Assert(InStr(_DriverFuncBody("_HS_CategorySelectionApply"), "NotifyFeature(") > 0, "a category selection notifies")
	Reload := InStr(_DriverFuncBody("ToggleGesturesEnabled"), "ReloadPreservingSuspend(")
	Assert(InStr(_DriverFuncBody("ToggleGesturesEnabled"), "NotifyFeature(") < Reload,
		"the notice is sent before the reload tears the tray icon down")
}
Test("feature notices: the toggles of the Lua menus notify on Windows (PAR-45)", _TQA_ToggleSites)

; The scopes' « all sections » rows and the word-expander rows went unannounced.
_TQA_ScopeRowsNotify() {
	global _TQA_Displayed, _HotstringsTerminatorRecords
	_TQA_Displayed := []
	AssertEqual(0, _HS_SelectionNotice("Scope", true, 0), "a refused switch answers as it was")
	AssertEqual(0, _TQA_Displayed.Length, "and says nothing")
	AssertEqual(1, _HS_SelectionNotice("Scope", true, 1), "a committed switch answers as it was")
	AssertEqual("Scope", _TQA_Displayed[1]["message"], "and is announced")
	Saved := _HotstringsTerminatorRecords
	Sent := []
	Send := (Text, Opts) => (Sent.Push([Text, Opts["level"]]), true)
	try {
		_HotstringsTerminatorRecords := { Builtin: Map("comma", { Enabled: 0 }) }
		_HS_DelimEntryNotice("comma", "Comma", Send)
		AssertEqual(StrReplace(t("notify.word_expander_prefix"), "%s", "Comma"), Sent[1][1], "the prefix and the row's name")
		AssertEqual("error", Sent[1][2], "off is the disabled level")
	} finally
		_HotstringsTerminatorRecords := Saved
	Language := _DriverFuncBody("_HS_LanguageSwitchRow")
	Assert(Language != "" && InStr(Language, "_HS_SelectionNotice(") > 0, "a language row notifies")
	Assert(InStr(_DriverFuncBody("_BuildDynamicHotstringsSubmenu"), "_HS_SelectionNotice(") > 0, "the dynamic row notifies")
	Assert(InStr(_DriverFuncBody("_HS_PersonalRows"), "_HS_SelectionNotice(") > 0, "the personal row notifies")
	Rows :=_DriverFuncBody("_HS_WordExpanderRows")
	Assert(Rows != "" && InStr(Rows, "_HS_DelimToggleEntry(EntryKey, 0, 0, EntryLabel)") > 0, "a catalogue row names itself")
	Assert(InStr(Rows, "_HS_DelimRecordRowClick(") > 0, "a user delimiter row notifies")
}
Test("feature notices: the language, personal, dynamic and word-expander rows notify (PAR-45)", _TQA_ScopeRowsNotify)
