; tests/unit/modules/llm/menu/test_llm_menu_generation.ahk

; ==============================================================================
; MODULE: LLM Menu Generation Settings
; DESCRIPTION:
; The automatic temperature and the automatic triggers replay the shared
; declarations and keep native lease refusal and live admission.
; ==============================================================================

#Requires AutoHotkey v2.0





_LMT_AutoTemperatureCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\auto_raise_temperature.json"))
}

_LMT_AutoTemperatureValues(*) {
	return [Map("label", t("menu.llm.temperature_label"), "disabled", true)]
}

_LMT_AutoTemperatureCollect(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.generation", Key: "auto_raise_temp", Value: CandidateMenu["auto_raise_temp"] }]
}

_LMT_AutoTemperatureToggle(*) {
	return LLM_Menu_CommitMutation("the native automatic temperature control",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, "auto_raise_temp"),
		_LMT_Apply, _LMT_Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_AutoTemperatureCollect)
}

_LMT_SharedAutoTemperatureOwner() {
	global _LLM_Menu, _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	try {
		Corpus := _LMT_AutoTemperatureCorpus()
		AssertEqual(2, Corpus["states"].Length)
		AssertEqual(2, Corpus["prediction_counts"].Length)
		for Selected in Corpus["states"] {
			for Count in Corpus["prediction_counts"] {
				_LLM_Menu["auto_raise_temp"] := Selected
				_LLM_Menu["n_predictions"] := Count
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				Built := LLM_Menu_BuildGenerationMenu(_LMT_AutoTemperatureToggle, _LMT_AutoTemperatureValues)
				try {
					AssertEqual(t(Corpus["row"]["i18n"]), _CTC_LabelAt(Built, 1))
					AssertEqual(Selected, _CTC_IsChecked(Built, 1))
					State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 1, "uint", 0x400, "uint")
					Assert(State != 0xFFFFFFFF, "the actual native check must exist")
					AssertEqual(Count < 2, !!(State & 0x3))
					Callback := _LMT_InfoBarCallback(Built, 1)
					AssertEqual(Count >= 2, Callback.Call())
					AssertEqual(Count >= 2 ? !Selected : Selected, _LLM_Menu["auto_raise_temp"])
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_WriterCalls)
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_ApplyCalls)
				} finally _CTC_ReleaseMenu(Built)
			}
		}
		_LLM_Menu["auto_raise_temp"] := true
		_LLM_Menu["n_predictions"] := 2
		_LMT_WriterCalls := 0
		_LMT_ApplyCalls := 0
		Built := LLM_Menu_BuildGenerationMenu(_LMT_AutoTemperatureToggle, _LMT_AutoTemperatureValues)
		try {
			Callback := _LMT_InfoBarCallback(Built, 1)
			_LLM_Menu["n_predictions"] := 1
			AssertFalse(Callback.Call(), "a delayed command rereads the actual prediction-count owner")
			AssertTrue(_LLM_Menu["auto_raise_temp"])
			AssertEqual(0, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
		} finally _CTC_ReleaseMenu(Built)
		Definitions := _MR_GetManifestRoot()["llm_generation_menu"]
		SavedDefinitions := Definitions.Clone()
		CheckRow := Definitions[2]
		OriginalLabel := CheckRow["i18n"]
		try {
			CheckRow["i18n"] := Corpus["alternate_i18n"]
			Definitions[1] := SavedDefinitions[2]
			Definitions[2] := SavedDefinitions[1]
			_LLM_Menu["n_predictions"] := 2
			_LLM_Menu["auto_raise_temp"] := true
			_LMT_WriterResult := false
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildGenerationMenu(_LMT_AutoTemperatureToggle, _LMT_AutoTemperatureValues)
			try {
				AssertEqual(t(Corpus["alternate_i18n"]), _CTC_LabelAt(Built, 0))
				AssertEqual(t("menu.llm.temperature_label"), _CTC_LabelAt(Built, 1))
				Callback := _LMT_InfoBarCallback(Built)
				AssertFalse(Callback.Call())
				AssertTrue(_LLM_Menu["auto_raise_temp"])
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
Test("LLM generation: shared temperature diversity retains native receipts and current count", _LMT_SharedAutoTemperatureOwner)

_LMT_TriggerCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\automatic_trigger_controls.json"))
}

_LMT_TriggerCollect(Key, CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.trigger", Key: Key, Value: CandidateFeatures["llm"]["trigger"][Key] }]
}

_LMT_TriggerToggle(Key, Writer := 0, *) {
	if !IsObject(Writer)
		Writer := _LMT_Writer
	return LLM_Menu_CommitMutation("the native trigger fixture",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, Key),
		_LMT_Apply, Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle,
		_LMT_TriggerCollect.Bind(Key))
}

_LMT_TriggerBuilder(Writer := 0) {
	return LLM_Menu_BuildTriggerMenu(_LMT_TriggerToggle.Bind("instant_on_word_end", Writer),
		_LMT_TriggerToggle.Bind("after_hotstring", Writer))
}

_LMT_SharedTriggerOwner() {
	global _LLM_Menu, Features, _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	try {
		Suspend(false)
		Corpus := _LMT_TriggerCorpus()
		AssertEqual(4, Corpus["states"].Length)
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		for States in Corpus["states"] {
			for Count in Corpus["prediction_counts"] {
				for Index, Expected in Corpus["rows"] {
					_LLM_Menu["instant_on_word_end"] := States[1]
					_LLM_Menu["after_hotstring"] := States[2]
					_LLM_Menu["n_predictions"] := Count
					Features["llm"]["trigger"]["instant_on_word_end"] := States[1]
					Features["llm"]["trigger"]["after_hotstring"] := States[2]
					Features["llm"]["profiles"]["num_predictions"] := Count
					_LMT_WriterCalls := 0
					_LMT_ApplyCalls := 0
					_LMT_WriterResult := 1
					Built := _LMT_TriggerBuilder()
					try {
						Position := _LMT_ShowAllPosition(Built, t(Expected["i18n"]))
						AssertEqual(States[Index], _CTC_IsChecked(Built, Position))
						AssertTrue(_LMT_InfoBarCallback(Built, Position).Call())
						AssertEqual(!States[Index], _LLM_Menu[Expected["native"]])
						AssertEqual(!States[Index], Features["llm"]["trigger"][Expected["native"]])
						Sibling := Index == 1 ? 2 : 1
						AssertEqual(States[Sibling], _LLM_Menu[Corpus["rows"][Sibling]["native"]])
						AssertEqual(States[Sibling], Features["llm"]["trigger"][Corpus["rows"][Sibling]["native"]])
						AssertEqual(1, _LMT_WriterCalls)
						AssertEqual(1, _LMT_ApplyCalls)
					} finally _CTC_ReleaseMenu(Built)
				}
			}
		}
		for Expected in Corpus["rows"] {
			_LMT_WriterResult := 1
			_LLM_Menu[Expected["native"]] := false
			Features["llm"]["trigger"][Expected["native"]] := false
			Built := _LMT_TriggerBuilder()
			try {
				Callback := _LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Expected["i18n"])))
				AssertTrue(Callback.Call())
				_LLM_Menu["n_predictions"] := 1
				Features["llm"]["profiles"]["num_predictions"] := 1
				AssertTrue(Callback.Call(), "variant count does not own a trigger switch")
				AssertFalse(_LLM_Menu[Expected["native"]])
				Writes := _LMT_WriterCalls
				Suspend(true)
				AssertFalse(Callback.Call())
				Suspend(false)
				_LLM_Menu["enabled"] := false
				Features["llm"]["enabled"] := false
				AssertFalse(Callback.Call())
				AssertEqual(Writes, _LMT_WriterCalls)
				_LLM_Menu["enabled"] := true
				Features["llm"]["enabled"] := true
			} finally _CTC_ReleaseMenu(Built)
			for Refusal in [false, "", Map()] {
				_LMT_WriterResult := Refusal
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				Built := _LMT_TriggerBuilder()
				try {
					AssertFalse(_LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Expected["i18n"]))).Call())
					AssertFalse(_LLM_Menu[Expected["native"]])
					AssertEqual(1, _LMT_WriterCalls)
					AssertEqual(0, _LMT_ApplyCalls)
				} finally _CTC_ReleaseMenu(Built)
			}
			Built := _LMT_TriggerBuilder(_LMT_ShowAllThrowWriter)
			try {
				AssertFalse(_LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Expected["i18n"]))).Call())
				AssertFalse(_LLM_Menu[Expected["native"]])
			} finally _CTC_ReleaseMenu(Built)
		}
	} finally {
		Suspend(SavedSuspend)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM trigger: shared bool pairs preserve native lease refusal and live admission", _LMT_SharedTriggerOwner)

_LMT_SharedTriggerDeclaration() {
	global _LLM_Menu, Features, _LMT_WriterResult
	Previous := _LMT_InstallFixture()
	Definitions := _MR_GetManifestRoot()["llm_trigger_menu"]
	SavedDefinitions := Definitions.Clone()
	Row := Definitions[2]
	SavedLabel := Row["i18n"]
	try {
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		_LMT_WriterResult := false
		Row["i18n"] := _LMT_TriggerCorpus()["alternate_i18n"]
		Definitions.RemoveAt(2)
		Definitions.InsertAt(1, Row)
		Built := _LMT_TriggerBuilder()
		try {
			AssertEqual(t(Row["i18n"]), _CTC_LabelAt(Built, 0))
			AssertFalse(_LMT_InfoBarCallback(Built).Call())
		} finally _CTC_ReleaseMenu(Built)
	} finally {
		Row["i18n"] := SavedLabel
		for Index, Entry in SavedDefinitions
			Definitions[Index] := Entry
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM trigger: native command placement follows the shared label and order", _LMT_SharedTriggerDeclaration)
