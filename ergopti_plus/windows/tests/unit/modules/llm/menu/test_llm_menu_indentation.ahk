; tests/unit/modules/llm/menu/test_llm_menu_indentation.ahk

; ==============================================================================
; MODULE: LLM Menu Indentation Choice
; DESCRIPTION:
; The indentation choice keeps its source, strict acknowledgement, numeric
; boundaries and closed diagnostics, and refuses withdrawn owners.
; ==============================================================================

#Requires AutoHotkey v2.0





_LMT_IndentCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\indentation_control.json"))
}

; The production writer still owns its lease/source fence; only the terminal
; native write is injected for refusal cases, like the other setting fixtures.
_LMT_IndentCommit(Value, Expected, WriterFn := 0, Seen := 0) {
	if !(Seen is Map)
		return LLM_Menu_CommitMutation("the native indentation regression",
			(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "pred_indent", Value),
			_LMT_Apply, (Path, Updates) => _LLM_Menu_IndentWrite(Expected, Path, Updates, WriterFn),
			_LMT_Notify, _LMT_Acquire, _LMT_Settle)
	return LLM_Menu_CommitMutation("the native indentation regression",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "pred_indent", Value),
		_LMT_Apply, _LMT_IndentObserveWrite.Bind(Seen, Expected, WriterFn),
		_LMT_IndentObserveNotify.Bind(Seen), _LMT_Acquire, _LMT_Settle,
		_LMT_IndentObserveCollect.Bind(Seen))
}

_LMT_IndentObservedCommit(WriterFn, Seen, Value, Expected) {
	return _LMT_IndentCommit(Value, Expected, WriterFn, Seen)
}

; Observers delegate to the unchanged full collector and borrowed writer. Closed
; stage facts distinguish a pre-writer refusal without printing source or errors.
_LMT_IndentObserveCollect(Seen, CandidateFeatures, CandidateMenu) {
	Seen["collector_entered"] := true
	try {
		Updates := _ConfigCollectFullSaveUpdates(CandidateFeatures, CandidateMenu)
		Seen["collector_returned"] := true
		Seen["collector_array"] := Updates is Array
		return Updates
	} catch as Err {
		Seen["collector_threw"] := true
		throw Err
	}
}

_LMT_IndentObserveWrite(Seen, Expected, WriterFn, Path, Updates) {
	Seen["borrowed_writer_entered"] := true
	Current := _LLM_Menu_IndentSnapshot()
	Seen["snapshot_blocked"] := Current["blocked"]
	Seen["source_matches"] := _LLM_Menu_EnableSourceMatches(Expected["source"], Current["source"])
	Seen["intent_admitted"] := LLM_DisplayIndentIntent(Expected, Current,
		Expected["indentation"], LLM_MENU_INDENT_OPTIONS)["admitted"]
	Owned := 0
	for Update in Updates {
		if Update.Section == "llm.display" && Update.Key == "pred_indent"
			Owned += 1
	}
	Seen["single_owned_leaf"] := Owned == 1
	try {
		Result := _LLM_Menu_IndentWrite(Expected, Path, Updates, WriterFn)
		Seen["borrowed_writer_returned"] := true
		Seen["borrowed_writer_ack"] := (Result is Integer) && Result == 1
		return Result
	} catch as Err {
		Seen["borrowed_writer_threw"] := true
		throw Err
	}
}

_LMT_IndentObserveNotify(Seen, Message, Options) {
	Seen["notified"] := true
	return _LMT_Notify(Message, Options)
}

; Values outside the fixed Boolean observation contract are never interpolated.
_LMT_IndentObservation(Seen) {
	Summary := ""
	for Field in ["collector_entered", "collector_returned", "collector_array", "collector_threw",
			"borrowed_writer_entered", "snapshot_blocked", "source_matches", "intent_admitted",
			"single_owned_leaf", "borrowed_writer_returned", "borrowed_writer_ack",
			"borrowed_writer_threw", "notified"] {
		Value := Seen.Get(Field, "")
		Summary .= (Summary == "" ? "" : ";") . Field . "="
			. ((Value is Integer) && (Value == 0 || Value == 1) ? Value : "unobserved")
	}
	return Summary
}

_LMT_IndentChild(Built) {
	Prefix := t("menu.llm.indent_label")
	Count := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int")
	Loop Count {
		Position := A_Index - 1
		if InStr(_CTC_LabelAt(Built, Position), Prefix) == 1 {
			Handle := _MCR_SubMenuAt(Built, Position)
			AssertEqual(15, DllCall("GetMenuItemCount", "ptr", Handle, "int"))
			return {Handle: Handle, Position: Position}
		}
	}
	throw Error("The actual native indentation submenu is absent.")
}

_LMT_IndentWriteMode(Mode, Seen, Path, Updates, Content := unset, Presence := unset) {
	return _LMT_IndentWriteObserved(Path, Updates, Mode, Seen, Content?, Presence?)
}

_LMT_IndentWriteObserved(Path, Updates, Mode, Seen, Content := unset, Presence := unset) {
	Seen["calls"] += 1
	Seen["updates"] := LLM_Menu_DeepClone(Updates)
	if Mode == "throw"
		throw Error("native indentation writer refused")
	if Mode == "nil"
		return ""
	if Mode == "false"
		return false
	if Mode == "truthy integer"
		return 2
	if Mode == "truthy string"
		return "ack"
	return TOML_ConfigBatchWrite(Path, Updates, [], 0, Content?, Presence?)
}

; Uses the actual Win32 menu, native dispatcher, configuration lease and strict
; TOML writer. Private file ownership is retired in finally, even on assertions.
_LMT_IndentNativeOwners() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, _LMT_ApplyCalls, _MenuDispatchCallbacks
	Path := A_Temp . "\ergopti-indent-choice-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "this fixture must acquire a new private path")
	Previous := _LMT_InstallFixture(Path)
	PreviousEngine := _LLM_Engine
	SavedSuspend := A_IsSuspended
	ConfigurationFile := Path
	try {
		Corpus := _LMT_IndentCorpus()
		AssertEqual(15, Corpus["choices"].Length)
		for Mode in ["false", "nil", "throw", "truthy integer", "truthy string", "ack"] {
			for Position in [0, 7, 14] {
				_LLM_Menu := _LMT_Menu()
				_LLM_Menu["enabled"] := true
				_LLM_Menu["n_predictions"] := 3
				_LLM_Menu["pred_indent"] := 1
				_LLM_Menu["show_all_at_once"] := false
				_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
				Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n'
					. "[llm.profiles]`nnum_predictions = 3`n[llm.display]`npred_indent = 1`nstreaming_multi = true`n"
					. "[llm.generation]`ntemperature = 0.9`n[private]`nfuture = 42`n"
				if FileExist(Path)
					FileDelete(Path)
				Initial := _CMJFixtureCurrentSource(Initial)
				FileAppend(Initial, Path, "UTF-8-RAW")
				Seen := Map("calls", 0)
				Writer := _LMT_IndentWriteMode.Bind(Mode, Seen)
				Command := _LMT_IndentObservedCommit.Bind(Writer, Seen)
				Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, (*) => false, Command)
				try {
					Child := _LMT_IndentChild(Built)
					State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Child.Position, "uint", 0x400, "uint")
					Assert(State != 0xFFFFFFFF, "the actual native indentation row must exist")
					AssertEqual(0, State & 0x3, "an admitted indentation row is enabled")
					for Index, Choice in Corpus["choices"] {
						AssertEqual(Choice["prefix"] . t(Choice["i18n"]), _CTC_LabelAt(Child, Index - 1))
						AssertEqual(Choice["value"] == 1, _CTC_IsChecked(Child, Index - 1))
					}
					Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", Position, "uint")
					Assert(_MenuDispatchCallbacks.Has(Id), "the actual native choice must own its dispatcher callback")
					Callback := _MenuDispatchCallbacks[Id]
					_LMT_ApplyCalls := 0
					AssertEqual(Mode == "ack", Callback.Call())
					AssertEqual(1, Seen["calls"], "closed native stages: " . _LMT_IndentObservation(Seen))
					AssertEqual(1, Seen["updates"].Length, "the native choice may own only one leaf")
					AssertEqual("llm.display", Seen["updates"][1].Section)
					AssertEqual("pred_indent", Seen["updates"][1].Key)
					Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
					AssertEqual(42, Document["private"]["future"])
					AssertEqual(0.9, Document["llm"]["generation"]["temperature"], "one display leaf cannot overwrite a foreign temperature")
					Value := Corpus["choices"][Position + 1]["value"]
					if Mode == "ack" {
						AssertEqual(Value, _LLM_Menu["pred_indent"])
						Read := _TOML_DocumentLookup(Document, ["llm", "display", "pred_indent"])
						AssertEqual(Value, Read["found"] ? Read["value"] : ManifestDefaultFor("llm.display.pred_indent"))
						AssertEqual(1, _LMT_ApplyCalls)
						AssertFalse(Callback.Call(), "published menu identity retires the held choice")
						AssertEqual(1, Seen["calls"])
					} else {
						AssertEqual(1, _LLM_Menu["pred_indent"])
						AssertEqual(Initial, FSReadUtf8Exact(Path))
						AssertEqual(0, _LMT_ApplyCalls)
					}
				} finally _CTC_ReleaseMenu(Built)
			}
		}
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: actual native indentation choices retain source, strict ACK and numeric boundaries", _LMT_IndentNativeOwners)


_LMT_IndentPolicyCorpus() {
	Corpus := _LMT_IndentCorpus()
	Owner := Map()
	Other := Map()
	Values := [-7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7]
	for Vector in Corpus["cases"] {
		Expected := LLM_Menu_DeepClone(Corpus["base"])
		Current := LLM_Menu_DeepClone(Corpus["base"])
		for Field, Value in Vector.Get("expected", Map())
			Expected[Field] := Value
		for Field, Value in Vector["current"]
			Current[Field] := Value
		Expected["owner"] := Expected["owner"] == "owned" ? Owner : Other
		Current["owner"] := Current["owner"] == "owned" ? Owner : Other
		Decision := LLM_DisplayIndentIntent(Expected, Current, Vector["value"], Values)
		AssertEqual(Vector["admitted"], Decision["admitted"], Vector["id"])
		if Vector["admitted"]
			AssertEqual(Vector["value"], Decision["value"], Vector["id"])
	}
}
Test("LLM display: shared indentation policy replays independent admission vectors", _LMT_IndentPolicyCorpus)

_LMT_IndentRetainedOwners() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, _LMT_ApplyCalls, _MenuDispatchCallbacks
	Previous := _LMT_InstallFixture()
	PreviousEngine := _LLM_Engine
	SavedSuspend := A_IsSuspended
	Path := A_Temp . "\ergopti-indent-held-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "this fixture must acquire a new private path")
	ConfigurationFile := Path
	try {
		for Condition in ["paused", "master", "count", "sparse runtime", "runtime mismatch", "source", "retired owner"] {
			_LLM_Menu := _LMT_Menu()
			_LLM_Menu["enabled"] := true
			_LLM_Menu["n_predictions"] := 3
			_LLM_Menu["pred_indent"] := 1
			_LLM_Menu["show_all_at_once"] := false
			_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
			Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n'
				. "[llm.profiles]`nnum_predictions = 3`n[llm.display]`npred_indent = 1`nstreaming_multi = true`n"
				. "[llm.generation]`ntemperature = 0.9`n[private]`nfuture = 42`n"
			if FileExist(Path)
				FileDelete(Path)
			FileAppend(Initial, Path, "UTF-8-RAW")
			Seen := Map("calls", 0)
			Writer := _LMT_IndentWriteMode.Bind("ack", Seen)
			Command := (Value, Expected) => _LMT_IndentCommit(Value, Expected, Writer)
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, (*) => false, Command)
			try {
				Child := _LMT_IndentChild(Built)
				Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", 0, "uint")
				Assert(_MenuDispatchCallbacks.Has(Id))
				Callback := _MenuDispatchCallbacks[Id]
				if Condition == "paused"
					Suspend(true)
				if Condition == "master"
					_LLM_Menu["enabled"] := false
				if Condition == "count"
					_LLM_Menu["n_predictions"] := 1
				if Condition == "sparse runtime"
					_LLM_Engine := Map("timer_active", false)
				if Condition == "runtime mismatch"
					_LLM_Engine["pred_indent"] := 2
				if Condition == "source" {
					FileDelete(Path)
					FileAppend(StrReplace(Initial, "temperature = 0.9", "temperature = 0.8"), Path, "UTF-8-RAW")
				}
				if Condition == "retired owner"
					_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
				Physical := FSReadUtf8Exact(Path)
				_LMT_ApplyCalls := 0
				AssertFalse(Callback.Call(), Condition)
				AssertEqual(0, Seen["calls"], Condition . " refuses before the native writer")
				AssertEqual(0, _LMT_ApplyCalls, Condition)
				AssertEqual(Physical, FSReadUtf8Exact(Path), Condition . " preserves exact physical bytes")
			} finally {
				Suspend(SavedSuspend)
				_CTC_ReleaseMenu(Built)
			}
		}
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: held native indentation choices refuse withdrawn or stale owners before write", _LMT_IndentRetainedOwners)


_LMT_IndentCanonicalTypes() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine
	Previous := _LMT_InstallFixture()
	PreviousEngine := _LLM_Engine
	SavedSuspend := A_IsSuspended
	Path := A_Temp . "\ergopti-indent-types-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path))
	ConfigurationFile := Path
	try {
		Suspend(false)
		_LLM_Menu["enabled"] := true
		_LLM_Menu["n_predictions"] := 3
		_LLM_Menu["pred_indent"] := 1
		_LLM_Menu["show_all_at_once"] := false
		_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
		Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n'
			. "[llm.profiles]`nnum_predictions = 3`n[llm.display]`npred_indent = 1`nstreaming_multi = true`n"
		for Vector in [
			Map("before", "enabled = true", "after", "enabled = 1", "admitted", false),
			Map("before", "streaming_multi = true", "after", "streaming_multi = 1", "admitted", false),
			Map("before", "num_predictions = 3", "after", 'num_predictions = "3"', "admitted", false),
			Map("before", "pred_indent = 1", "after", 'pred_indent = "1"', "admitted", false),
			Map("before", "pred_indent = 1", "after", "pred_indent = 1.0", "admitted", true)] {
			Physical := StrReplace(Initial, Vector["before"], Vector["after"])
			Assert(Physical != Initial, "each canonical type vector must change the real source")
			if FileExist(Path)
				FileDelete(Path)
			FileAppend(Physical, Path, "UTF-8-RAW")
			Snapshot := _LLM_Menu_IndentSnapshot()
			AssertEqual(Vector["admitted"], LLM_DisplayIndentReady(Snapshot), Vector["after"])
			AssertEqual(Physical, FSReadUtf8Exact(Path), "admission observation never changes source bytes")
		}
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: native indentation source requires real scalar types without numeric string coercion", _LMT_IndentCanonicalTypes)


_LMT_IndentObservationIsClosed() {
	Seen := Map("collector_entered", true, "source_matches", false,
		"collector_threw", "private-error-marker", "unknown_future_stage", "private-future-marker")
	Summary := _LMT_IndentObservation(Seen)
	Assert(InStr(Summary, "collector_entered=1") > 0)
	Assert(InStr(Summary, "source_matches=0") > 0)
	Assert(InStr(Summary, "collector_threw=unobserved") > 0)
	AssertFalse(InStr(Summary, "private-error-marker"))
	AssertFalse(InStr(Summary, "private-future-marker"))
	AssertFalse(InStr(Summary, "unknown_future_stage"))
}
Test("LLM display: indentation owner diagnostics retain only closed stage facts", _LMT_IndentObservationIsClosed)

#Include test_llm_menu_indentation_source_owner.ahk
