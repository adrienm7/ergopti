; tests/unit/modules/llm/menu/test_llm_menu_display.ahk

; ==============================================================================
; MODULE: LLM Menu Display Settings
; DESCRIPTION:
; The Info Bar, Show-all and token-streaming rows replay the shared
; declarations and publish only through their native transaction owner.
; ==============================================================================

#Requires AutoHotkey v2.0





_LMT_InfoBarCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\info_bar_control.json"))
}

_LMT_InfoBarCollect(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.display", Key: "show_info_bar", Value: CandidateMenu["show_info_bar"] }]
}

_LMT_InfoBarToggle(*) {
	return LLM_Menu_CommitMutation("the native Info Bar control",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, "show_info_bar"),
		_LMT_Apply, _LMT_Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_InfoBarCollect)
}

_LMT_InfoBarCallback(Built, Position := 0) {
	global _MenuDispatchCallbacks
	Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the shared check uses the real native dispatcher")
	return _MenuDispatchCallbacks[Id]
}

_LMT_SharedInfoBarNativeOwner() {
	global _LLM_Menu, _LLM_Engine, ConfigurationFile, LLM_MENU_INDENT_OPTIONS, _LMT_WriterResult
	global _LMT_WriterCalls, _LMT_ApplyCalls
	Path := _LMT_InfoBarPrivatePath()
	Previous := _LMT_InstallFixture(Path)
	PreviousEngine := _LLM_Engine
	PreviousSuspend := A_IsSuspended
	Suspend(false)
	ConfigurationFile := Path
	HadIndent := IsSet(LLM_MENU_INDENT_OPTIONS)
	PreviousIndent := HadIndent ? LLM_MENU_INDENT_OPTIONS : 0
	; The unit graph omits _index.ahk; provide its independent accepted range
	; for the unrelated remaining provider without changing its production owner.
	LLM_MENU_INDENT_OPTIONS := [-7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7]
	try {
		Corpus := _LMT_InfoBarCorpus()
		AssertEqual(2, Corpus["states"].Length)
		for Selected in Corpus["states"] {
			_LLM_Menu["show_info_bar"] := Selected
			_LMT_InfoBarAdmitFixture(Path, Selected)
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle)
			try {
				AssertEqual(t(Corpus["row"]["i18n"]), _CTC_LabelAt(Built, 0))
				AssertEqual(Selected, _CTC_IsChecked(Built, 0))
				Callback := _LMT_InfoBarCallback(Built)
				AssertTrue(Callback.Call())
				AssertEqual(!Selected, _LLM_Menu["show_info_bar"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(1, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		}
		Definitions := _MR_GetManifestRoot()["llm_display_menu"]
		SavedDefinitions := Definitions.Clone()
		InfoRow := Definitions[2]
		OriginalLabel := InfoRow["i18n"]
		try {
			InfoRow["i18n"] := Corpus["alternate_i18n"]
			Definitions.RemoveAt(2)
			Definitions.Push(InfoRow)
			_LLM_Menu["show_info_bar"] := true
			_LMT_InfoBarAdmitFixture(Path, true)
			_LMT_WriterResult := false
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle)
			try {
				Position := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int") - 1
				Assert(Position > 0, "the native remaining provider precedes the moved check")
				AssertEqual(t(Corpus["alternate_i18n"]), _CTC_LabelAt(Built, Position))
				Callback := _LMT_InfoBarCallback(Built, Position)
				AssertFalse(Callback.Call())
				AssertTrue(_LLM_Menu["show_info_bar"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(0, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		} finally {
			InfoRow["i18n"] := OriginalLabel
			for Index, Row in SavedDefinitions
				Definitions[Index] := Row
		}
	} finally {
		if HadIndent
			LLM_MENU_INDENT_OPTIONS := PreviousIndent
		else
			LLM_MENU_INDENT_OPTIONS := unset
		Suspend(PreviousSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: shared Info Bar state and labels retain the native transaction owner", _LMT_SharedInfoBarNativeOwner)

_LMT_ShowAllCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\show_all_control.json"))
}

_LMT_ShowAllCollect(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.display", Key: "streaming_multi",
		Value: CandidateFeatures["llm"]["display"]["streaming_multi"] }]
}

_LMT_ShowAllToggle(Writer := 0, *) {
	if !IsObject(Writer)
		Writer := _LMT_Writer
	return LLM_Menu_CommitMutation("the native Show-all control",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, "show_all_at_once"),
		_LMT_Apply, Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_ShowAllCollect)
}

_LMT_ShowAllThrowWriter(Path, Updates) {
	global _LMT_WriterCalls
	_LMT_WriterCalls += 1
	throw Error("The owned Show-all writer refused.")
}

_LMT_ShowAllPosition(Built, Label) {
	Count := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int")
	Loop Count {
		Position := A_Index - 1
		if _CTC_LabelAt(Built, Position) == Label
			return Position
	}
	throw Error("The actual display menu omitted the shared Show-all check.")
}

_LMT_SharedShowAllNativeOwner() {
	global _LLM_Menu, Features, _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		Corpus := _LMT_ShowAllCorpus()
		AssertEqual(2, Corpus["states"].Length)
		for Expected in Corpus["states"] {
			for Count in Corpus["prediction_counts"] {
				_LLM_Menu["show_all_at_once"] := Expected["show_all"]
				_LLM_Menu["n_predictions"] := Count
				Features["llm"]["display"]["streaming_multi"] := Expected["progressive"]
				Features["llm"]["profiles"]["num_predictions"] := Count
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
				try {
					Position := _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"]))
					AssertEqual(Expected["show_all"], _CTC_IsChecked(Built, Position))
					Flags := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
					Assert(Flags != 0xFFFFFFFF)
					AssertEqual(Count < 2, !!(Flags & 0x3))
					Callback := _LMT_InfoBarCallback(Built, Position)
					AssertEqual(Count >= 2, Callback.Call())
					AssertEqual(Count >= 2 ? !Expected["show_all"] : Expected["show_all"], _LLM_Menu["show_all_at_once"])
					if Count >= 2
						AssertEqual(!Expected["progressive"], Features["llm"]["display"]["streaming_multi"])
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_WriterCalls)
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_ApplyCalls)
				} finally _CTC_ReleaseMenu(Built)
			}
		}
		_LLM_Menu["n_predictions"] := 2
		_LLM_Menu["show_all_at_once"] := false
		Features["llm"]["display"]["streaming_multi"] := true
		Features["llm"]["profiles"]["num_predictions"] := 2
		_LMT_WriterCalls := 0
		Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
		try {
			Callback := _LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"])))
			_LLM_Menu["n_predictions"] := 1
			AssertFalse(Callback.Call(), "a delayed click cannot own a withdrawn second slot")
			AssertFalse(_LLM_Menu["show_all_at_once"])
			AssertEqual(0, _LMT_WriterCalls)
		} finally _CTC_ReleaseMenu(Built)
		_LLM_Menu["n_predictions"] := 2
		SavedSuspend := A_IsSuspended
		Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
		try {
			Callback := _LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"])))
			Suspend(true)
			AssertFalse(Callback.Call(), "a held command cannot publish across a native pause")
			AssertEqual(0, _LMT_WriterCalls)
			AssertFalse(_LLM_Menu["show_all_at_once"])
		} finally {
			Suspend(SavedSuspend)
			_CTC_ReleaseMenu(Built)
		}
		for Refusal in [false, "", Map()] {
			_LMT_WriterResult := Refusal
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
			try {
				Position := _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"]))
				AssertFalse(_LMT_InfoBarCallback(Built, Position).Call())
				AssertFalse(_LLM_Menu["show_all_at_once"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(0, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		}
		_LMT_WriterCalls := 0
		_LMT_ApplyCalls := 0
		Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle.Bind(_LMT_ShowAllThrowWriter))
		try {
			Position := _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"]))
			AssertFalse(_LMT_InfoBarCallback(Built, Position).Call())
			AssertFalse(_LLM_Menu["show_all_at_once"])
			AssertEqual(1, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
		} finally _CTC_ReleaseMenu(Built)
		Definitions := _MR_GetManifestRoot()["llm_display_menu"]
		SavedDefinitions := Definitions.Clone()
		CheckIndex := 0
		for Index, Definition in Definitions {
			if Definition.Get("id", "") == "llm_show_all" {
				CheckIndex := Index
				break
			}
		}
		Assert(CheckIndex > 0, "the shared Show-all declaration must exist before its placement mutation")
		CheckRow := Definitions[CheckIndex]
		OriginalLabel := CheckRow["i18n"]
		try {
			CheckRow["i18n"] := Corpus["alternate_i18n"]
			Definitions.RemoveAt(CheckIndex)
			Definitions.InsertAt(1, CheckRow)
			_LLM_Menu["n_predictions"] := 2
			_LMT_WriterResult := false
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
			try {
				AssertEqual(t(Corpus["alternate_i18n"]), _CTC_LabelAt(Built, 0))
				AssertFalse(_LMT_InfoBarCallback(Built).Call())
				AssertFalse(_LLM_Menu["show_all_at_once"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(0, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		} finally {
			CheckRow["i18n"] := OriginalLabel
			for Index, Row in SavedDefinitions
				Definitions[Index] := Row
		}
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM display: shared Show-all checks keep the native receipt and canonical polarity",
	_LMT_SharedShowAllNativeOwner)

/** Captures the real dispatcher's retry without starting an ambient timer. */
_LMT_ShowAllArmRetry(State, Callback, DelayMs) {
	State["timers"].Push(Map("callback", Callback, "delay", DelayMs))
	return true
}

_LMT_ShowAllRetryBusy(State) {
	return State["busy"]
}

_LMT_ShowAllSetMaster(Value) {
	return LLM_Menu_CommitMutation("the Show-all fixture master",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "enabled", Value),
		_LMT_Apply, _LMT_Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_Collect)
}

_LMT_ShowAllMasterRevokesHeldAndDeferred() {
	global _LLM_Menu, Features, _LMT_WriterCalls, _LMT_ApplyCalls
	global MENU_COMMAND_DEFERRAL_RETRY_MS, _MenuStartupCommands
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	SavedStartupCommands := _MenuStartupCommands
	try {
		Suspend(false)
		_MenuStartupCommands := 0
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		_LLM_Menu["n_predictions"] := 2
		Features["llm"]["profiles"]["num_predictions"] := 2
		_LLM_Menu["show_all_at_once"] := false
		Features["llm"]["display"]["streaming_multi"] := true
		for Deferred in [false, true] {
			AssertTrue(_LMT_ShowAllSetMaster(true))
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
			try {
				Callback := _LMT_InfoBarCallback(Built,
					_LMT_ShowAllPosition(Built, t(_LMT_ShowAllCorpus()["row"]["i18n"])))
				State := Map("busy", true, "timers", [])
				if Deferred {
					Writes := _LMT_WriterCalls
					AssertEqual("", MenuCommandRun(Callback, [], 0,
						_LMT_ShowAllRetryBusy.Bind(State), _LMT_ShowAllArmRetry.Bind(State)))
					AssertEqual(Writes, _LMT_WriterCalls)
					AssertEqual(1, State["timers"].Length)
					AssertEqual(MENU_COMMAND_DEFERRAL_RETRY_MS, State["timers"][1]["delay"])
				}
				AssertTrue(_LMT_ShowAllSetMaster(false), "the real master owner acknowledges withdrawal")
				AssertFalse(_LLM_Menu["enabled"])
				AssertFalse(Features["llm"]["enabled"])
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				if Deferred {
					State["busy"] := false
					State["timers"][1]["callback"].Call()
					AssertEqual(1, State["timers"].Length, "no competing retry is armed after the lease releases")
				} else {
					AssertFalse(Callback.Call(), "a retained native callback refuses the disabled master")
				}
				AssertEqual(0, _LMT_WriterCalls, "held and dispatcher-deferred delivery publish no display setting")
				AssertEqual(0, _LMT_ApplyCalls)
				AssertFalse(_LLM_Menu["show_all_at_once"])
				AssertTrue(Features["llm"]["display"]["streaming_multi"])
			} finally _CTC_ReleaseMenu(Built)
		}
	} finally {
		Suspend(SavedSuspend)
		_MenuStartupCommands := SavedStartupCommands
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: master withdrawal fences held and real dispatcher-deferred Show-all commands",
	_LMT_ShowAllMasterRevokesHeldAndDeferred)

_LMT_ShowAllCanonicalBoundaries() {
	global _LLM_Menu, Features, LLM_Defaults, _LLM_Engine
	Previous := _LMT_InstallFixture()
	SavedDefaults := LLM_Defaults
	SavedEngine := _LLM_Engine
	try {
		for Expected in _LMT_ShowAllCorpus()["states"] {
			LLM_Defaults := Map("llm_streaming_multi", Expected["progressive"])
			_LLM_Engine := SavedEngine.Clone()
			LLM_Engine_ApplySharedDefaults()
			AssertEqual(Expected["show_all"], _LLM_Engine["show_all_at_once"],
				"the real engine default loader projects canonical progressive display")
			Features["llm"]["display"]["streaming_multi"] := Expected["progressive"]
			Opts := LLM_Menu_BuildSavedOpts()
			AssertEqual(Expected["show_all"], Opts["show_all_at_once"],
				"both raw stored polarities load without rewriting historical bytes")
			_LLM_Menu["show_all_at_once"] := Expected["show_all"]
			AssertTrue(_LLM_Menu_SyncToFeatures())
			AssertEqual(Expected["progressive"], Features["llm"]["display"]["streaming_multi"],
				"the acknowledged writer receives canonical progressive display")
		}
	} finally {
		LLM_Defaults := SavedDefaults
		_LLM_Engine := SavedEngine
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: shared defaults and saved values invert only at native boundaries",
	_LMT_ShowAllCanonicalBoundaries)

_LMT_StreamingCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\token_streaming_control.json"))
}

_LMT_StreamingPolicyContract() {
	Corpus := _LMT_StreamingCorpus()
	AssertEqual(9, Corpus["capabilities"].Length)
	AssertEqual(15, Corpus["cases"].Length)
	for Vector in Corpus["capabilities"] {
		AssertEqual(Vector["capable"], LLM_DisplayStreamingCapable(Vector["platform"], Vector["backend"]),
			"actual shared capability matches the independent native transport inventory")
	}
	for Vector in Corpus["cases"] {
		Expected := Corpus["base"].Clone()
		Current := Corpus["base"].Clone()
		for Key, Value in Vector.Get("expected", Map())
			Expected[Key] := Value
		for Key, Value in Vector["current"]
			Current[Key] := Value
		Decision := LLM_DisplayStreamingIntent(Expected, Current)
		AssertEqual(Vector["admitted"], Decision["admitted"], Vector["id"])
		if Vector["admitted"]
			AssertEqual(Vector["value"], Decision["value"], Vector["id"])
	}
}
Test("LLM display: shared token streaming replays independent capabilities and stale intents", _LMT_StreamingPolicyContract)

_LMT_StreamingNativeRefusal() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	try {
		Corpus := _LMT_StreamingCorpus()
		Definitions := _MR_GetManifestRoot()["llm_display_menu"]
		StreamingRow := 0
		for Definition in Definitions {
			if Definition.Get("id", "") == Corpus["row"]["id"]
				StreamingRow := Definition
		}
		Assert(StreamingRow is Map, "the actual shared declaration must own the streaming row")
		AssertEqual("grey", StreamingRow["unavailable"])
		AssertEqual("platform_reason.token_streaming_transport_missing", StreamingRow["reason_key"])
		for Backend in ["ollama", "api", "mlx"] {
			_LLM_Menu["backend"] := Backend
			_LLM_Menu["enabled"] := true
			_LLM_Menu["streaming"] := true
			_LLM_Menu["show_all_at_once"] := false
			State := Map("calls", 0)
			Command := (*) => State["calls"] += 1
			Expected := _LLM_Menu_StreamingSnapshot()
			AssertFalse(LLM_BackendCapabilities(Backend)["streaming"], "Windows has no partial-frame transport")
			AssertFalse(_LLM_Menu_StreamingCommand(Expected, Command), "an unsupported click cannot reach a writer")
			Suspend(true)
			AssertFalse(_LLM_Menu_StreamingCommand(Expected, Command), "a retained click remains refused under native pause")
			Suspend(SavedSuspend)
			_LLM_Menu := _LLM_Menu.Clone()
			AssertFalse(_LLM_Menu_StreamingCommand(Expected, Command), "an old row cannot claim a replacement map owner")
			AssertEqual(0, State["calls"])
			AssertEqual(0, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
			AssertTrue(_LLM_Menu["streaming"], "unavailable native rendering does not strip historical stored intent")
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, Command)
			try {
				Count := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int")
				Matches := 0
				Loop Count {
					Position := A_Index - 1
					Label := _CTC_LabelAt(Built, Position)
					if InStr(Label, t(Corpus["row"]["i18n"])) == 1 {
						Matches += 1
						Assert(Label != t(Corpus["row"]["i18n"]), "the disabled native row explains why it cannot stream")
						AssertContains(Label, "Windows")
						NativeState := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
						Assert(NativeState & 0x3, "the real Win32 row is greyed")
						AssertFalse(_CTC_IsChecked(Built, Position), "a buffered transport never reports effective token streaming")
					}
				}
				AssertEqual(1, Matches, "the native menu projects exactly one shared streaming declaration")
			} finally _CTC_ReleaseMenu(Built)
		}
	} finally {
		Suspend(SavedSuspend)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: the real Windows streaming row remains truthful and cannot reach a writer", _LMT_StreamingNativeRefusal)


_LMT_StreamingCountCommand(State) {
	State["calls"] += 1
	return true
}

_LMT_StreamingSparseOwnerRefusal() {
	global _LLM_Menu, _LLM_Engine, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	HadEngine := IsSet(_LLM_Engine)
	SavedEngine := HadEngine ? _LLM_Engine : 0
	try {
		Suspend(false)
		_LLM_Menu["backend"] := "ollama"
		_LLM_Menu["enabled"] := true
		_LLM_Menu["streaming"] := true
		_LLM_Menu["show_all_at_once"] := false
		_LLM_Menu["future_streaming_neighbor"] := "preserve"
		Owners := [Map("id", "unset"), Map("id", "non-map", "owner", 0),
			Map("id", "empty", "owner", Map()),
			Map("id", "retired debounce", "owner", Map("timer_active", false)),
			Map("id", "missing enabled", "owner", Map("backend", "ollama")),
			Map("id", "missing backend", "owner", Map("enabled", true))]
		for Vector in Owners {
			if Vector.Has("owner")
				_LLM_Engine := Vector["owner"]
			else
				_LLM_Engine := unset
			Failure := ""
			Snapshot := 0
			try {
				Snapshot := _LLM_Menu_StreamingSnapshot()
			} catch as Err {
				Failure := Err.Message
			}
			AssertEqual("", Failure, Vector["id"] . ": a missing runtime owner is a refusal, never an exception")
			Assert(Snapshot is Map, Vector["id"] . ": the real owner returns an admission snapshot")
			AssertTrue(Snapshot["blocked"], Vector["id"] . ": incomplete engine state is unavailable")
			AssertFalse(LLM_DisplayStreamingReady(Snapshot), Vector["id"] . ": unavailable state cannot enable a shared row")
			State := Map("calls", 0)
			Command := _LMT_StreamingCountCommand.Bind(State)
			AssertFalse(_LLM_Menu_StreamingCommand(Snapshot, Command), Vector["id"] . ": unavailable state cannot reach the setting owner")
			AssertEqual(0, State["calls"])
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, Command)
			try {
				Matches := 0
				Loop DllCall("GetMenuItemCount", "ptr", Built.Handle, "int") {
					Position := A_Index - 1
					if InStr(_CTC_LabelAt(Built, Position), t("menu.llm.show_streaming")) == 1 {
						Matches += 1
						NativeState := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
						Assert(NativeState & 0x3, Vector["id"] . ": the actual Win32 row remains disabled")
						AssertFalse(_CTC_IsChecked(Built, Position))
					}
				}
				AssertEqual(1, Matches, Vector["id"] . ": the shared declaration remains visible exactly once")
			} finally _CTC_ReleaseMenu(Built)
			AssertEqual(0, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
			AssertTrue(_LLM_Menu["streaming"], "refusal preserves historical stored intent")
			AssertEqual("preserve", _LLM_Menu["future_streaming_neighbor"])
		}
	} finally {
		if HadEngine
			_LLM_Engine := SavedEngine
		else
			_LLM_Engine := unset
		Suspend(SavedSuspend)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: sparse or retired engine owners refuse streaming without writes or missing-key exceptions", _LMT_StreamingSparseOwnerRefusal)

_LMT_InfoBarPrivatePath() {
	Path := A_Temp . "\ergopti-info-bar-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "this test must acquire an absent private source")
	return Path
}

_LMT_InfoBarAdmitFixture(Path, Selected) {
	global _LLM_Menu, _LLM_Engine
	_LLM_Menu["enabled"] := true
	_LLM_Menu["n_predictions"] := 1
	_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
	Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n[llm.display]`nshow_info_bar = '
		. (Selected ? "true" : "false") . '`n[llm.generation]`ntemperature = 0.9`n[private]`nfuture = 42`n'
	if FileExist(Path)
		FileDelete(Path)
	Initial := _CMJFixtureCurrentSource(Initial)
	FileAppend(Initial, Path, "UTF-8-RAW")
	return Initial
}

_LMT_InfoBarLeaseWrite(Expected, Writer, Path, Updates) {
	return _LLM_Menu_InfoBarWrite(Expected, Path, Updates, Writer)
}

_LMT_InfoBarCommit(Writer, Value, Expected) {
	return LLM_Menu_CommitMutation("the actual retained Info Bar owner",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "show_info_bar", Value),
		_LMT_Apply, _LMT_InfoBarLeaseWrite.Bind(Expected, Writer), _LMT_Notify,
		_LMT_Acquire, _LMT_Settle, _LMT_InfoBarCollect)
}

_LMT_InfoBarWriter(Mode, Seen, Path, Updates, Content, Presence) {
	Seen["calls"] += 1
	Seen["updates"] := LLM_Menu_DeepClone(Updates)
	if Mode == "throw"
		throw Error("Info Bar writer refused")
	if Mode == "nil"
		return ""
	if Mode == "false"
		return false
	if Mode == "source race" {
		Foreign := StrReplace(Content, "temperature = 0.9", "temperature = 0.8")
		Seen["source_race_changed"] := Foreign != Content
		Assert(Foreign != Content, "the terminal port must create an actual different valid source")
		FileDelete(Path)
		FileAppend(Foreign, Path, "UTF-8-RAW")
	}
	return TOML_ConfigBatchWrite(Path, Updates, [], 0, Content, Presence)
}

_LMT_InfoBarRetainedReceipts() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, _LMT_ApplyCalls
	Path := _LMT_InfoBarPrivatePath()
	Previous := _LMT_InstallFixture(Path)
	PreviousEngine := _LLM_Engine
	PreviousSuspend := A_IsSuspended
	ConfigurationFile := Path
	try {
		for Condition in ["ack", "false", "nil", "throw", "source race", "paused", "master", "source", "runtime", "sparse", "retired"] {
			_LLM_Menu := _LMT_Menu()
			Initial := _LMT_InfoBarAdmitFixture(Path, true)
			Seen := Map("calls", 0)
			Mode := Condition == "false" || Condition == "nil" || Condition == "throw" || Condition == "source race" ? Condition : "ack"
			Command := _LMT_InfoBarCommit.Bind(_LMT_InfoBarWriter.Bind(Mode, Seen))
			Built := LLM_Menu_BuildDisplayMenu(Command)
			try {
				Callback := _LMT_InfoBarCallback(Built)
				if Condition == "paused"
					Suspend(true)
				if Condition == "master"
					_LLM_Menu["enabled"] := false
				if Condition == "source" {
					FileDelete(Path)
					FileAppend(StrReplace(Initial, "temperature = 0.9", "temperature = 0.8"), Path, "UTF-8-RAW")
				}
				if Condition == "runtime"
					_LLM_Engine["show_info_bar"] := false
				if Condition == "sparse"
					_LLM_Engine := Map("timer_active", false)
				if Condition == "retired"
					_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
				Before := FSReadUtf8Exact(Path)
				_LMT_ApplyCalls := 0
				AssertEqual(Condition == "ack", Callback.Call(), Condition)
				if Condition == "source race"
					AssertEqual(true, Seen.Get("source_race_changed", false), "the actual terminal port must change the source outside the production-caught callback")
				AssertEqual(Condition == "ack" || Condition == "false" || Condition == "nil" || Condition == "throw" || Condition == "source race" ? 1 : 0, Seen["calls"], Condition)
				AssertEqual(Condition == "ack" ? 1 : 0, _LMT_ApplyCalls, Condition)
				if Condition == "ack" {
					AssertEqual(1, Seen["updates"].Length)
					AssertEqual("llm.display", Seen["updates"][1].Section)
					AssertEqual("show_info_bar", Seen["updates"][1].Key)
					AssertFalse(_LLM_Menu["show_info_bar"])
					Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
					AssertEqual(42, Document["private"]["future"])
					AssertEqual(0.9, Document["llm"]["generation"]["temperature"])
					AssertFalse(Callback.Call(), "the acknowledged publication retires its old menu identity")
					AssertEqual(1, Seen["calls"])
				} else {
					AssertTrue(_LLM_Menu["show_info_bar"])
					AssertEqual(Condition == "source race" ? StrReplace(Before, "temperature = 0.9", "temperature = 0.8") : Before,
						FSReadUtf8Exact(Path), "refusal preserves exact foreign bytes")
				}
			} finally {
				Suspend(PreviousSuspend)
				_CTC_ReleaseMenu(Built)
			}
		}
	} finally {
		Suspend(PreviousSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: real Info Bar commands require retained source and strict leased publication", _LMT_InfoBarRetainedReceipts)

_LMT_InfoBarPolicyCorpus() {
	Corpus := _LMT_InfoBarCorpus()
	Owner := Map()
	Other := Map()
	AssertEqual(15, Corpus["cases"].Length)
	for Vector in Corpus["cases"] {
		Expected := LLM_Menu_DeepClone(Corpus["base"])
		Current := LLM_Menu_DeepClone(Corpus["base"])
		for Field, Value in Vector.Get("expected", Map())
			Expected[Field] := Value
		for Field, Value in Vector["current"]
			Current[Field] := Value
		Expected["owner"] := Expected["owner"] == "owned" ? Owner : Other
		Current["owner"] := Current["owner"] == "owned" ? Owner : Other
		Decision := LLM_DisplayInfoBarIntent(Expected, Current)
		AssertEqual(Vector["admitted"], Decision["admitted"], Vector["id"])
		if Vector["admitted"]
			AssertEqual(Vector["value"], Decision["value"], Vector["id"])
	}
}
Test("LLM display: Info Bar owner policy replays independent source admission vectors", _LMT_InfoBarPolicyCorpus)
