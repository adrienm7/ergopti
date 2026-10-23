; static/ergopti_plus/windows/tests/unit/infra/input_probe/test_input_probe.ahk

; ==============================================================================
; MODULE: Input Probe Tests
; DESCRIPTION:
; Pins the pure cores of the two Debug-menu checks (send comparison, hook
; order): how the text that reached the target is judged, the statistics, the
; hook verdict and the evidence records. It also pins what the menu promises:
; both rows are declared once in the shared manifest for AutoHotkey only with a
; translated reason, the Windows menu supplies a command for each, every text
; the module shows exists in English, and no log call can carry typed content.
; No key is sent: the run functions are only called where they refuse to start.
; ==============================================================================





; ======================================
; ======================================
; ======= 1/ Pure helpers ==============
; ======================================
; ======================================

_IPT_Percentiles() {
	Assert(InputProbe_Percentile([], 50) == 0, "an empty series has percentile 0")
	Assert(InputProbe_Percentile([5], 95) == 5, "a single value is every percentile")
	Series := [30, 10, 50, 20, 40]
	Assert(InputProbe_Percentile(Series, 50) == 30, "the median of five values is the third")
	Assert(InputProbe_Percentile(Series, 100) == 50, "the 100th percentile is the maximum")
	Assert(InputProbe_Percentile(Series, 95) == 50, "the 95th percentile of five values is the maximum")
	Assert(Series[1] == 30, "the input series is not reordered")
}
Test("input probe: percentiles are nearest-rank and leave the input alone", _IPT_Percentiles)

_IPT_Classify() {
	Expected := "abcdef"
	Assert(InputProbe_ClassifyText(Expected, "abcdef")["kind"] == "ok", "an exact text is ok")
	Lost := InputProbe_ClassifyText(Expected, "abcd")
	Assert(Lost["kind"] == "lost" && Lost["lost"] == 2, "two missing keys are two lost keys")
	Assert(InputProbe_ClassifyText(Expected, "abcdefgh")["kind"] == "garbled", "extra keys are garbled")
	Assert(InputProbe_ClassifyText(Expected, "abXdef")["kind"] == "garbled", "a substituted key is garbled")
	Assert(InputProbe_ClassifyText(Expected, "abcdef#", "#")["kind"] == "ok",
		"a rival key after the whole burst is not an interleave")
	Assert(InputProbe_ClassifyText(Expected, "abc#def", "#")["kind"] == "interleaved",
		"a rival key inside the burst is an interleave")
	Assert(InputProbe_ClassifyText(Expected, "#abcdef", "#")["kind"] == "interleaved",
		"a rival key before the burst's text is an interleave")
	Assert(InputProbe_ClassifyText(Expected, "ab#", "#")["kind"] == "lost",
		"a rival key does not hide lost keys")
}
Test("input probe: the received text is classified ok, lost, interleaved or garbled", _IPT_Classify)

_IPT_Summary() {
	Reps := [
		Map("kind", "ok", "lost", 0, "ret_us", 10, "settle_us", 100),
		Map("kind", "ok", "lost", 0, "ret_us", 20, "settle_us", 300),
		Map("kind", "lost", "lost", 3, "ret_us", 30, "settle_us", -1),
		Map("kind", "interleaved", "lost", 0, "ret_us", 40, "settle_us", 200)]
	Row := InputProbe_SummarizeRow("expansion", "SendEvent", Reps)
	Assert(Row["n"] == 4 && Row["exact"] == 2, "two of four repetitions are exact")
	Assert(Row["lost"] == 3 && Row["interleaved"] == 1 && Row["timeout"] == 1,
		"lost keys are summed, interleaves and timeouts counted")
	Assert(Row["settle_max_us"] == 300 && Row["settle_med_us"] == 200,
		"latency statistics ignore the repetition that never settled")
	Assert(!InputProbe_RowPasses(Row), "a row with a lost key does not pass")
	Rival := InputProbe_SummarizeRow("rival", "SendEvent", Reps)
	Assert(InputProbe_RowPasses(Rival), "the rival scenario is evidence, never a failure")
	Clean := InputProbe_SummarizeRow("paste", "SendInput", [Reps[1], Reps[2]])
	Assert(InputProbe_RowPasses(Clean), "a row of exact repetitions passes")
}
Test("input probe: a row folds its repetitions and judges them", _IPT_Summary)

_IPT_RowRecordHasNoContent() {
	Row := InputProbe_SummarizeRow("expansion", "SendInput",
		[Map("kind", "ok", "lost", 0, "ret_us", 1, "settle_us", 2)])
	Record := InputProbe_RowRecord(Row)
	Assert(InStr(Record, "scenario=expansion mode=SendInput n=1 exact=1") == 1 + StrLen("send_compare "),
		"the record names the scenario, the primitive and the counts")
	Assert(!RegExMatch(Record, "[^\x20-\x7E]"), "the record is plain ASCII")
	for Scenario in _IP_Scenarios() {
		Payload := Scenario["spec"]["expected"]
		Assert(!InStr(Record, Payload), "the record never holds the " . Scenario["id"] . " payload")
	}
}
Test("input probe: the send record holds counts and timings only", _IPT_RowRecordHasNoContent)





; ======================================
; ======================================
; ======= 2/ Hook verdict ==============
; ======================================
; ======================================

_IPT_Phase(Seen, Fired) => Map("seen", Seen, "fired", Fired)

_IPT_HookVerdicts() {
	Assert(InputProbe_HookPhaseOrder(1, 1) == "test_first", "a key the test hook saw ran test-first")
	Assert(InputProbe_HookPhaseOrder(0, 1) == "ahk_first", "a key only the hotkey saw ran AutoHotkey-first")
	Assert(InputProbe_HookPhaseOrder(0, 0) == "inconclusive", "no hotkey firing proves nothing")
	Assert(InputProbe_HookPhaseOrder(1, 0) == "inconclusive", "a key the hotkey missed proves nothing")

	; SendInput moved AutoHotkey's hook to the front.
	Moved := InputProbe_HookVerdict(_IPT_Phase(1, 1), _IPT_Phase(1, 0), _IPT_Phase(0, 1), _IPT_Phase(1, 1))
	Assert(Moved["changed"] == "yes" && Moved["rehook"] == "yes" && Moved["conclusive"],
		"a rehook that moved the hook is a conclusive 'yes'")
	; Another AutoHotkey keyboard hook: SendInput fell back to SendEvent.
	Fallback := InputProbe_HookVerdict(_IPT_Phase(1, 1), _IPT_Phase(1, 1), _IPT_Phase(1, 1), _IPT_Phase(1, 1))
	Assert(Fallback["changed"] == "no" && Fallback["rehook"] == "no" && Fallback["conclusive"],
		"a hotkey firing during SendInput means it fell back and nothing moved")
	; The control failing makes the method unsound.
	Broken := InputProbe_HookVerdict(_IPT_Phase(1, 1), _IPT_Phase(1, 0), _IPT_Phase(0, 1), _IPT_Phase(0, 1))
	Assert(!Broken["conclusive"], "a control that does not see the key makes the run inconclusive")
	Silent := InputProbe_HookVerdict(_IPT_Phase(1, 1), _IPT_Phase(1, 0), _IPT_Phase(0, 0), _IPT_Phase(1, 1))
	Assert(Silent["changed"] == "unknown" && !Silent["conclusive"],
		"a phase without its hotkey leaves the order unknown")
}
Test("input probe: the hook verdict names the order, the rehook and its soundness", _IPT_HookVerdicts)

_IPT_HookRecord() {
	Before := _IPT_Phase(1, 1)
	During := _IPT_Phase(1, 0)
	After := _IPT_Phase(0, 1)
	Control := _IPT_Phase(1, 1)
	Record := InputProbe_HookRecord(Before, During, After, Control,
		InputProbe_HookVerdict(Before, During, After, Control))
	Assert(InStr(Record, "hook_order before=test_first(seen=1,fired=1)") == 1,
		"the record starts with the first phase")
	Assert(InStr(Record, "after=ahk_first(seen=0,fired=1)") && InStr(Record, "changed=yes")
		&& InStr(Record, "rehook=yes") && InStr(Record, "conclusive=1"),
		"the record carries every phase and the verdict")
}
Test("input probe: the hook record names every phase", _IPT_HookRecord)





; ==========================================
; ==========================================
; ======= 3/ Refusal and privacy ===========
; ==========================================
; ==========================================

_IPT_RefusesWhileBusy() {
	global _InputProbeBusy
	Saved := _InputProbeBusy
	_InputProbeBusy := true
	try {
		Send := InputProbe_RunSendComparison()
		Hook := InputProbe_RunHookOrder()
	} finally
		_InputProbeBusy := Saved
	Assert(Send["state"] == "aborted" && Send["reason"] == "busy", "a second send comparison is refused")
	Assert(Hook["state"] == "aborted" && Hook["reason"] == "busy", "a second hook check is refused")
	Assert(_InputProbeBusy == Saved, "a refused run leaves the busy flag as it found it")
}
Test("input probe: a check refuses to start while another runs", _IPT_RefusesWhileBusy)

_IPT_LogCallsCarryNoContent() {
	for Name in ["InputProbe_RunSendComparison", "InputProbe_RunHookOrder", "_IP_RunRep"] {
		Body := _DriverFuncBody(Name)
		Pos := 1
		Calls := 0
		while RegExMatch(Body, "i)Logger(?:Debug|Info|Evidence|Start|Success|Warn|Error)\(([^\r\n]*)", &Match, Pos) {
			Calls += 1
			Pos := Match.Pos + Match.Len
			Assert(!RegExMatch(Match[1], "i)\.Value|Expected|Actual|Replacement|Prediction|Pasted|Payload"),
				Name . " must not pass typed content to the logger: " . Match[0])
		}
		Assert(Name == "_IP_RunRep" || Calls > 0, Name . " must log its lifecycle")
	}
}
Test("input probe: no logger call carries the typed text", _IPT_LogCallsCarryNoContent)





; ===========================================
; ===========================================
; ======= 4/ Menu rows and texts ============
; ===========================================
; ===========================================

_IPT_EnglishStrings() {
	return JsonParse(FileRead(_SharedDir . "\data\locales\en.json", "UTF-8"))
}

_IPT_MenuRows() {
	Root := JsonParse(FileRead(_SharedDir . "\modules\menu\menu_manifest.json", "UTF-8"))
	Rows := Map()
	for Row in Root["debug_menu"] {
		if Row.Has("id")
			Rows[Row["id"]] := Row
	}
	return Rows
}

_IPT_MenuRowsAreDeclaredForWindowsOnly() {
	Rows := _IPT_MenuRows()
	English := _IPT_EnglishStrings()
	for Id in ["send_probe", "hook_probe"] {
		Assert(Rows.Has(Id), "the shared Debug menu declares '" . Id . "'")
		Row := Rows[Id]
		Assert(Row["type"] == "command", Id . " is a command row")
		Assert(Row["platforms"].Length == 1 && Row["platforms"][1] == "ahk",
			Id . " exists on the AutoHotkey driver only")
		Assert(Row.Has("reason_key") && English.Has(Row["reason_key"]) && English[Row["reason_key"]] != "",
			Id . " names a translated reason for the other drivers")
		Assert(English.Has(Row["i18n"]) && English[Row["i18n"]] != "", Id . " has an English label")
		Body := _DriverFuncBody("_MI_BuildDebuggingMenu")
		Assert(InStr(Body, '"' . Id . '",'), "the Windows Debug menu supplies a command for '" . Id . "'")
	}
	Assert(InStr(_DriverFuncBody("_MI_BuildDebuggingMenu"), "InputProbe_SendComparisonCommand"),
		"the send row runs the send comparison")
	Assert(InStr(_DriverFuncBody("_MI_BuildDebuggingMenu"), "InputProbe_HookOrderCommand"),
		"the hook row runs the hook check")
	Fallback := _DriverFuncBody("_MM_DebugFallback")
	Assert(InStr(Fallback, '"send_probe"') && InStr(Fallback, '"hook_probe"'),
		"the hard-coded fallback order lists both rows")
}
Test("input probe: both Debug rows are declared once for Windows with a reason", _IPT_MenuRowsAreDeclaredForWindowsOnly)

_IPT_EveryShownTextExists() {
	English := _IPT_EnglishStrings()
	Source := _DriverSourceNoComments()
	Keys := Map()
	Pos := 1
	while RegExMatch(Source, 'i)\bt\("(input_probe\.[a-z_.]+)"\)', &Match, Pos) {
		Keys[Match[1]] := true
		Pos := Match.Pos + Match.Len
	}
	for Reason in ["busy", "paused", "foreground", "keys_held"]
		Keys["input_probe.reason." . Reason] := true
	for Scenario in _IP_Scenarios()
		Keys["input_probe.scenario." . Scenario["id"]] := true
	for Order in ["test_first", "ahk_first", "inconclusive"]
		Keys["input_probe.hook_" . Order] := true
	for Changed in ["yes", "no"]
		Keys["input_probe.hook_changed_" . Changed] := true
	Assert(Keys.Count > 15, "the module shows its texts through t(): " . Keys.Count . " key(s) found")
	for Key in Keys {
		Assert(English.Has(Key) && English[Key] != "", "'" . Key . "' exists in en.json")
	}
}
Test("input probe: every text the checks show exists in English", _IPT_EveryShownTextExists)

#Include test_input_probe_rival_owner.ahk
