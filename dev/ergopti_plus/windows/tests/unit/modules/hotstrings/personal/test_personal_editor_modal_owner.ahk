; tests/unit/modules/hotstrings/personal/test_personal_editor_modal_owner.ahk

; Real InputBox dialogs, and the suite's MsgBox stub answered by a responder,
; return into the production section handlers. Only the replies are automated:
; source admission, writes and Close are real.

_PEMO_OnClose(Window, Epoch, *) {
	return _OnEditorClose(Window, Epoch)
}

_PEMO_Open(State, SectionName) {
	global _PersonalEditorData, _PersonalEditorSection, _PersonalEditorOpeningSource
	global _PersonalEditorGui, _PersonalEditorSessionEpoch
	Window := Gui_Create("", "Private editor modal owner")
	Drop := Window.Add("DropDownList", "w240", ["Alpha", "Beta"])
	List := Window.Add("ListView", "w400 r2", ["Trigger", "Output", "Word", "Auto", "Case", "Final", "Priority"])
	Controls := []
	loop 2
		Controls.Push(Window.Add("Edit", "w240"))
	loop 4
		Controls.Push(Window.Add("CheckBox", , "Private control"))
	Status := Window.Add("Text", "w400", "")
	Source := Map(), Data := ReadPersonalToml(false, Source)
	AssertTrue(Source["admitted"], "the exact real file must grant its opening image")
	AssertTrue(Data["sections"].Has("alpha") && Data["sections"].Has("beta"))
	_PersonalEditorSessionEpoch += 1
	Source["kind"] := "native", Source["epoch"] := _PersonalEditorSessionEpoch, Source["window"] := Window
	_PersonalEditorOpeningSource := Source, _PersonalEditorGui := Window
	_PersonalEditorData := Data, _PersonalEditorSection := SectionName
	CloseFn := _PEMO_OnClose.Bind(Window, _PersonalEditorSessionEpoch)
	Window.OnEvent("Close", CloseFn)
	State["windows"].Push({ Window: Window, Close: CloseFn })
	Window.Show("Hide")
	Drop.Choose(SectionName == "alpha" ? 1 : 2)
	_PopulateList(List, Data, SectionName)
	List.Modify(1, "Select Focus")
	return { Window: Window, Drop: Drop, List: List, Controls: Controls, Status: Status, Source: Source, Data: Data }
}

_PEMO_Respond(State, Hwnd, Kind) {
	Mode := State["mode"]
	Target := State["boundary"] == "new-name" ? "name" : State["boundary"] == "new-description" ? "description"
		: State["boundary"] == "rename" ? "rename" : "delete"
	if Mode == "cancel" && Kind == Target && !State["acted"] {
		State["acted"] := true
		PostMessage(0x111, Kind == "delete" ? 7 : 2, 0, , "ahk_id " . Hwnd)
		return
	}
	if Kind != "delete"
		ControlSetText(Kind == "name" ? "gamma" : "Renamed by original dialog", "Edit1", "ahk_id " . Hwnd)
	PostMessage(0x111, Kind == "delete" ? 6 : 1, 0, , "ahk_id " . Hwnd)
}

; The successor event that happens while the modal is open. Returns false while
; a posted Close is still pending, so the pump retries on its next tick; Wait
; lets a synchronous caller (the MsgBox responder) pump messages until it lands.
; The editor window is hidden, which WinTitle lookups skip: its Close goes
; straight to the HWND.
_PEMO_Act(State, Wait) {
	global _PersonalEditorGui, _PersonalEditorSection, _PersonalEditorSessionEpoch
	Old := State["old"]
	if State["mode"] == "closed" || State["mode"] == "reopened" {
		if !State["close_posted"] {
			State["close_posted"] := true
			AssertTrue(DllCall("PostMessage", "Ptr", Old.Window.Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0),
				"the editor window must receive its real WM_CLOSE")
		}
		while Wait && _PersonalEditorGui == Old.Window {
			if A_TickCount - State["started"] > 5000
				throw Error("The real editor Close did not run within its fixture deadline")
			Sleep(10)
		}
		if _PersonalEditorGui == Old.Window
			return false
		AssertTrue(_PersonalEditorSessionEpoch > Old.Source["epoch"], "the real Close event must revoke its epoch")
		State["closed"] := true
		if State["mode"] == "reopened" {
			State["successor"] := _PEMO_Open(State, "beta")
			State["successor_json"] := KL_JsonEncode(State["successor"].Data)
		}
	} else if State["mode"] == "section" {
		; The native dropdown's published selected-section state changed
		; while its owner remained live; the old confirmation still names alpha.
		Old.Drop.Choose(2)
		_PersonalEditorSection := "beta"
	} else if State["mode"] == "external" {
		State["expected_source"] .= "# An independent file edit won during the modal.`n"
		AssertTrue(FSWriteDurable(State["path"], State["expected_source"]))
	}
	State["acted"] := true
	return true
}

; The suite replaces MsgBox with a non-blocking stub (test_framework.ahk), so a
; confirmation never reaches a native window. The responder stands in for the
; user at the moment the production handler asks, with the same successor
; events as the native InputBox cases.
_PEMO_Confirm(State, Text, Title, Options) {
	AssertEqual(WindowTitle(t("editor.hotstrings.title_confirm")), Title, "the production confirmation caption")
	AssertTrue(InStr(Options, "YesNo") > 0, "the production confirmation offers Yes and No")
	State["dialogs"] += 1
	if State["mode"] == "cancel"
		return "No"
	if State["mode"] != "live"
		_PEMO_Act(State, true)
	return "Yes"
}

_PEMO_Pump(State) {
	global _PersonalEditorGui, _PersonalEditorSection, _PersonalEditorSessionEpoch
	try {
		if A_TickCount - State["started"] > 5000
			throw Error("The real editor modal exceeded its fixture deadline")
		for Hwnd in WinGetList("ahk_pid " . DriverPid) {
			if WinGetClass("ahk_id " . Hwnd) != "#32770"
				continue
			Title := WinGetTitle("ahk_id " . Hwnd)
			Kind := State["titles"].Get(Title, "")
			if Kind == "" || State["seen"].Has(Hwnd . ":" . Title)
				continue
			Target := State["boundary"] == "new-name" ? "name" : State["boundary"] == "new-description" ? "description"
				: State["boundary"] == "rename" ? "rename" : "delete"
			if Kind == Target && !State["acted"] && State["mode"] != "live" && State["mode"] != "cancel" {
				if !_PEMO_Act(State, false)
					return
			}
			State["seen"][Hwnd . ":" . Title] := true
			State["dialogs"] += 1
			_PEMO_Respond(State, Hwnd, Kind)
		}
	} catch as Err {
		State["error"] := Err
		; A failing observation must release the real blocking dialog as well.
		for Hwnd in WinGetList("ahk_class #32770 ahk_pid " . DriverPid) {
			; Yes/No boxes have no cancel action, so WM_CLOSE can be ignored.
			if DllCall("GetDlgItem", "Ptr", Hwnd, "Int", 7, "Ptr")
				PostMessage(0x111, 7, 0, , "ahk_id " . Hwnd)
			else
				PostMessage(0x10, 0, 0, , "ahk_id " . Hwnd)
		}
	}
}

_PEMO_Invoke(Boundary, Old) {
	if Boundary == "rename"
		return _RenameSection(Old.Window, Old.Drop)
	if Boundary == "delete-entry"
		return _DeleteEntry(Old.Window, Old.List, Old.Status)
	Args := [Old.Window, Old.Drop, Old.List]
	for Control in Old.Controls
		Args.Push(Control)
	Args.Push(Old.Status)
	return Boundary == "delete-section" ? _DeleteSection(Args*) : _NewSection(Args*)
}

_PEMO_Case(Boundary, Mode) {
	global ScriptInformation, ConfigurationFile, Features, _ReadPersonalTomlCache
	global _PersonalEditorData, _PersonalEditorSection, _PersonalEditorOpeningSource
	global _PersonalEditorGui, _PersonalEditorSessionEpoch, _PersonalEditorPrioCtrl
	global _PersonalEditorEntryCohort, _PersonalEditorEntryBusy
	global _HS_GrandTotalCache, _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	HadTotal := IsSet(_HS_GrandTotalCache)
	SavedTotal := HadTotal ? _HS_GrandTotalCache : unset
	Saved := { Path: ScriptInformation["PersonalTomlPath"], Config: ConfigurationFile, Features: Features,
		Cache: _ReadPersonalTomlCache, Data: _PersonalEditorData, Section: _PersonalEditorSection,
		Source: _PersonalEditorOpeningSource, Window: _PersonalEditorGui, Epoch: _PersonalEditorSessionEpoch,
		EntryCohort: _PersonalEditorEntryCohort, EntryBusy: _PersonalEditorEntryBusy,
		Priority: _PersonalEditorPrioCtrl, Critical: A_IsCritical, Suspended: A_IsSuspended,
		Desired: MasterGateState()["features"] }
	Fixture := _ScopeOwnerFixture(), Timer := 0
	Source := '[_meta]`ndescription = "Private modal proof"`nsections_order = ["alpha", "beta"]`n'
		. '[_meta.sections.alpha]`ndescription = "Alpha"`n[_meta.sections.beta]`ndescription = "Beta"`n'
		. '[[alpha]]`n"private_alpha" = { output = "Alpha output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. '[[beta]]`n"private_beta" = { output = "Beta output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	State := Map("boundary", Boundary, "mode", Mode, "windows", [], "seen", Map(),
		"acted", false, "close_posted", false, "closed", false, "dialogs", 0,
		"started", A_TickCount, "error", 0, "path", Fixture.directory . "\personal.toml", "expected_source", Source,
		"titles", Map(WindowTitle(t("editor.hotstrings.new_section_title")), "name",
			WindowTitle(t("editor.hotstrings.desc_title")), "description",
			WindowTitle(t("editor.hotstrings.rename_title")), "rename",
			WindowTitle(t("editor.hotstrings.title_confirm")), "delete"))
	try {
		Critical("Off"), Suspend(false)
		_PersonalEditorEntryCohort := 0, _PersonalEditorEntryBusy := false
		ConfigurationFile := Fixture.path
		ScriptInformation["PersonalTomlPath"] := State["path"]
		Features := _PersonalTomlCloneDetached(Saved.Features)
		MasterGateState()["features"] := _PersonalTomlCloneDetached(Saved.Desired)
		AssertTrue(FSWriteDurable(State["path"], Source))
		Old := _PEMO_Open(State, "alpha"), State["old"] := Old
		Original := KL_JsonEncode(Old.Data)
		Timer := _PEMO_Pump.Bind(State)
		State["started"] := A_TickCount
		if Boundary == "delete-section" || Boundary == "delete-entry"
			TestMsgBoxResponder(_PEMO_Confirm.Bind(State))
		SetTimer(Timer, 10)
		Result := _PEMO_Invoke(Boundary, Old)
		SetTimer(Timer, 0)
		if IsObject(State["error"])
			throw State["error"]
		AssertTrue(State["dialogs"] > 0, "the production handler must show an actual native modal")
		if Boundary == "new-description" || ((Boundary == "new-name") && Mode == "live")
			AssertEqual(2, State["dialogs"], "the second InputBox must really run")
		if Mode != "live" {
			AssertTrue(FSUtf8ExactMatches(State["path"], State["expected_source"]), "a cancelled/stale/refused modal cannot replace the real source")
			AssertTrue(FSUtf8ExactMatches(Fixture.path, Fixture.source), "a stale action cannot update default_section")
			AssertEqual(Original, KL_JsonEncode(Old.Data), "refusal leaves the original mutable model untouched")
			AssertFalse(Features["hotstrings"]["personal"].Has("gamma"), "refusal cannot seed the abandoned feature")
			if Mode == "closed" || Mode == "reopened"
				AssertTrue(State["closed"], "the real WM_CLOSE must run while the modal is open")
			if Mode == "reopened" {
				AssertTrue(_PersonalEditorGui == State["successor"].Window)
				AssertTrue(_PersonalEditorOpeningSource == State["successor"].Source)
				AssertEqual(State["successor_json"], KL_JsonEncode(State["successor"].Data), "the old dialog cannot mutate its successor")
				AssertEqual("beta", _PersonalEditorSection)
			}
		} else {
			AssertTrue(Result, "a current native dialog still commits through the actual writer")
			Fresh := ReadPersonalToml(true)
			if Boundary == "rename"
				AssertEqual("Renamed by original dialog", Fresh["sections"]["alpha"]["description"])
			else if Boundary == "delete-section"
				AssertFalse(Fresh["sections"].Has("alpha"))
			else {
				AssertTrue(Fresh["sections"].Has("gamma"))
				AssertEqual("Renamed by original dialog", Fresh["sections"]["gamma"]["description"])
				AssertTrue(Features["hotstrings"]["personal"].Has("gamma"))
			}
			AssertEqual("Beta", Fresh["sections"]["beta"]["description"], "a current action still touches only its named section")
			AssertEqual(Original, KL_JsonEncode(Old.Data), "the committed model is detached from its captured predecessor")
		}
	} finally {
		TestMsgBoxResponder("")
		if IsObject(Timer)
			SetTimer(Timer, 0)
		for Owned in State["windows"] {
			Owned.Window.OnEvent("Close", Owned.Close, 0)
			Owned.Window.Destroy()
		}
		_PersonalEditorData := Saved.Data, _PersonalEditorSection := Saved.Section
		_PersonalEditorOpeningSource := Saved.Source, _PersonalEditorGui := Saved.Window
		_PersonalEditorSessionEpoch := Saved.Epoch, _PersonalEditorPrioCtrl := Saved.Priority
		_PersonalEditorEntryCohort := Saved.EntryCohort, _PersonalEditorEntryBusy := Saved.EntryBusy
		ScriptInformation["PersonalTomlPath"] := Saved.Path, ConfigurationFile := Saved.Config
		Features := Saved.Features, MasterGateState()["features"] := Saved.Desired
		_PersonalTomlInvalidateCaches(State["path"])
		_ReadPersonalTomlCache := Saved.Cache
		_HS_GrandTotalCache := HadTotal ? SavedTotal : unset
		for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache] {
			if Store.Has(Fixture.path)
				Store.Delete(Fixture.path)
		}
		_ScopeOwnerCleanup(Fixture)
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
}

for _PEMO_Boundary in ["new-name", "new-description", "rename", "delete-section"]
	for _PEMO_Mode in ["live", "cancel", "closed", "reopened", "section", "external"]
		Test("personal native editor: " . _PEMO_Boundary . " returns to " . _PEMO_Mode . " owner (personal-native-modal-owner)",
			_PEMO_Case.Bind(_PEMO_Boundary, _PEMO_Mode))
for _PEMO_Mode in ["cancel", "closed", "reopened", "section"]
	Test("personal native editor: entry confirmation returns to " . _PEMO_Mode . " owner (personal-native-modal-owner)",
		_PEMO_Case.Bind("delete-entry", _PEMO_Mode))


; Entry receipt regressions share the real source/session/private-config fixture.


_PECASE_RegistryScope(Restore := 0) {
	global _PrefixInputHook, _PrefixVisibleFireDecisions, HS_PERSONAL_RELOAD_INDEX_DELAY_MS
	global HSE_MAX_BUFFER_LEN, HSE_WORD_TERMINATORS, HSE_RebuildInProgress, HSE_CONSUMED_DELIMITERS, HSE_PRIORITY_COMMON
	global HSE_PRIORITY_PACKAGE, HSE_PRIORITY_PERSONAL, HSE_Buffer, HSE_FinalNoOpPending, HSE_FinalNoOpFound
	global HSE_StartIsWordBoundary, HSE_StartIsLineStart, HSE_RegistryByLastChar, HSE_RegistryByGroup, HSE_DisabledGroups
	global HSE_SeqCounter, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration, HSE_RegistryTransitionDepth, HSE_StarSpecs
	global HSE_StarPrefixSetCI, HSE_StarPrefixSetCS, HSE_StarByTriggerCI, HSE_StarByTriggerCS, HSE_MaxStarTriggerLen
	global HSE_EndByTriggerCI, HSE_EndByTriggerCS, HSE_MaxEndTriggerLen, HSE_Suppressed, HSE_LastMatch
	global HSE_LastEndChar, HSE_RepeatEnabled, HSE_IdleResetSeconds, HSE_ClickResetsWord, HSE_CascadeMaxArrows
	global HSE_CASCADE_MIN_ARROWS, HSE_CASCADE_MAX_ARROWS, HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord
	global HSE_PersonalInfoCombosEnabled, HSE_TypoNbspStripped
	Names := ["HSE_MAX_BUFFER_LEN", "HSE_WORD_TERMINATORS", "HSE_RebuildInProgress", "HSE_CONSUMED_DELIMITERS", "HSE_PRIORITY_COMMON", "HSE_PRIORITY_PACKAGE", "HSE_PRIORITY_PERSONAL", "HSE_Buffer", "HSE_FinalNoOpPending", "HSE_FinalNoOpFound", "HSE_StartIsWordBoundary", "HSE_StartIsLineStart", "HSE_RegistryByLastChar", "HSE_RegistryByGroup", "HSE_DisabledGroups", "HSE_SeqCounter", "HSE_RegistryGeneration", "HSE_RuntimeDecisionGeneration", "HSE_RegistryTransitionDepth", "HSE_StarSpecs", "HSE_StarPrefixSetCI", "HSE_StarPrefixSetCS", "HSE_StarByTriggerCI", "HSE_StarByTriggerCS", "HSE_MaxStarTriggerLen", "HSE_EndByTriggerCI", "HSE_EndByTriggerCS", "HSE_MaxEndTriggerLen", "HSE_Suppressed", "HSE_LastMatch", "HSE_LastEndChar", "HSE_RepeatEnabled", "HSE_IdleResetSeconds", "HSE_ClickResetsWord", "HSE_CascadeMaxArrows", "HSE_CASCADE_MIN_ARROWS", "HSE_CASCADE_MAX_ARROWS", "HSE_ArrowResetsWord", "HSE_ShortcutResetsWord", "HSE_TapHoldResetsWord", "HSE_PersonalInfoCombosEnabled", "HSE_TypoNbspStripped"]
	if IsObject(Restore) {
		; Real section publications arm the auxiliary 120 ms index timer.
		; Its genuine callback returns before touching state while no watcher
		; exists. Drain it while our detached registry remains installed.
		Sleep(HS_PERSONAL_RELOAD_INDEX_DELAY_MS + 40)
		SetTimer(HotstringPrefixWatcherRebuildIndex, 0)
		for Name, State in Restore
			%Name% := State.had ? State.value : unset
		return
	}
	; This unit runner does not start a keyboard watcher. Fail before any
	; mutation if a host instead owns one: its prior timers are not ours.
	AssertTrue(!_PrefixInputHook, "The native case fixture requires the runner's inactive keyboard watcher")
	AssertTrue(_PrefixVisibleFireDecisions is Array && _PrefixVisibleFireDecisions.Length == 0,
		"No host registry projection may be retired by this fixture")
	Saved := Map()
	for Name in Names {
		Had := IsSet(%Name%)
		Saved[Name] := Had ? {had: true, value: %Name%} : {had: false}
	}
	; Install detached indexes before genuine native publications can mutate
	; buckets. Saving references alone would not preserve the host's maps.
	HSE_MAX_BUFFER_LEN := 256
	HSE_WORD_TERMINATORS := " `t`r`n.,;:?!" . Chr(0x27) . Chr(0x2019)
	HSE_RebuildInProgress := false
	HSE_CONSUMED_DELIMITERS := ""
	HSE_PRIORITY_COMMON := 10
	HSE_PRIORITY_PACKAGE := 30
	HSE_PRIORITY_PERSONAL := 50
	HSE_Buffer := ""
	HSE_FinalNoOpPending := false
	HSE_FinalNoOpFound := false
	HSE_StartIsWordBoundary := true
	HSE_StartIsLineStart := false
	HSE_RegistryByLastChar := Map()
	HSE_RegistryByGroup := Map()
	HSE_DisabledGroups := Map()
	HSE_SeqCounter := 0
	HSE_RegistryGeneration := 0
	HSE_RuntimeDecisionGeneration := 0
	HSE_RegistryTransitionDepth := 0
	HSE_StarSpecs := []
	HSE_StarPrefixSetCI := Map()
	HSE_StarPrefixSetCS := Map()
	HSE_StarByTriggerCI := Map()
	HSE_StarByTriggerCS := Map()
	HSE_MaxStarTriggerLen := 0
	HSE_EndByTriggerCI := Map()
	HSE_EndByTriggerCS := Map()
	HSE_MaxEndTriggerLen := 0
	HSE_Suppressed := 0
	HSE_LastMatch := ""
	HSE_LastEndChar := ""
	HSE_RepeatEnabled := true
	HSE_IdleResetSeconds := ""
	HSE_ClickResetsWord := ""
	HSE_CascadeMaxArrows := ""
	HSE_CASCADE_MIN_ARROWS := 1
	HSE_CASCADE_MAX_ARROWS := 10
	HSE_ArrowResetsWord := ""
	HSE_ShortcutResetsWord := ""
	HSE_TapHoldResetsWord := ""
	HSE_PersonalInfoCombosEnabled := true
	HSE_TypoNbspStripped := false
	return Saved
}

_PEER_Args(State) {
	Old := State.Window
	Args := [Old.Window, Old.List]
	for Control in Old.Controls
		Args.Push(Control)
	return Args
}

_PEER_Event(State, *) {
	State.Entered += 1
	try {
		Old := State.Window
		if State.Operation == "legacy"
			return _SaveData(Old.Window, Old.List, Old.Status)
		if State.Operation == "section-rename"
			return _RenameSection(Old.Window, Old.Drop)
		if State.Operation == "section-delete" || State.Operation == "section-new" {
			Args := [Old.Window, Old.Drop, Old.List]
			for Control in Old.Controls
				Args.Push(Control)
			Args.Push(Old.Status)
			return State.Operation == "section-delete" ? _DeleteSection(Args*) : _NewSection(Args*)
		}
		if State.Operation == "delete"
			return _DeleteEntry(Old.Window, Old.List, Old.Status)
		Args := _PEER_Args(State)
		if State.Operation == "add"
			Args.Push(State.CloseOnAdd)
		Args.Push(Old.Status)
		return State.Operation == "add" ? _AddEntry(Args*) : _SaveEntry(Args*)
	} catch Any as Failure {
		State.Failure := Failure
	} finally State.Returned += 1
}

_PEER_Click(State) {
	Before := State.Returned
	DllCall("User32\SendMessageW", "Ptr", State.Button.Hwnd, "UInt", 0xF5,
		"Ptr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while State.Returned == Before && !IsObject(State.Failure) && TickElapsed(Started) < 3000
		Sleep(10)
	if IsObject(State.Failure)
		throw State.Failure
	AssertEqual(Before + 1, State.Returned, "A genuine BM_CLICK must settle exactly one production producer")
	AssertEqual(State.Entered, State.Returned)
}

_PEER_RowsAgree(State) {
	global _PersonalEditorData, _PersonalEditorSection
	Entries := _PersonalEditorData["sections"][_PersonalEditorSection]["entries"]
	AssertEqual(Entries.Length, State.Window.List.GetCount(), "Native rows must describe the mutable editor model")
	for Index, Entry in Entries {
		AssertEqual(Entry["trigger"], State.Window.List.GetText(Index, 1))
		AssertEqual(StrReplace(Entry["output"], "`n", "↵"), State.Window.List.GetText(Index, 2))
	}
}

; The only stage port is an observation boundary around the genuine durable
; stage writer. No policy, admission, replacement, refusal or reload is faked.
; An independent production owner holds its real lease while native Add events
; enqueue complete snapshots through their unchanged default writer path.
_PEER_CohortStage(State, Path, Text) {
	Written := FSWriteDurable(Path, Text)
	if !Written || State.CohortObserved
		return Written
	State.CohortObserved := true
	Owner := _ConfigWriteLeaseCurrent(PersonalTomlPath())
	AssertTrue(Owner is Object, "The outer actual publisher must hold the native target lease")
	State.Window.Controls[1].Value := "cohort_first"
	State.Window.Controls[2].Value := "first queued output"
	_PEER_Click(State)
	State.FirstStatus := State.Window.Status.Value
	_PEER_RowsAgree(State)
	if State.SwitchSection {
		State.Window.Drop.Choose(2)
		Args := [State.Window.Drop, State.Window.List]
		for Control in State.Window.Controls
			Args.Push(Control)
		Args.Push(State.Window.Status)
		_OnSectionChange(Args*)
	}
	State.Window.Controls[1].Value := "cohort_second"
	State.Window.Controls[2].Value := "second queued output"
	_PEER_Click(State)
	State.SecondStatus := State.Window.Status.Value
	_PEER_RowsAgree(State)
	AssertEqual(State.SwitchSection ? 2 : 4, State.Window.List.GetCount(), "The next section must show the real staged full-model snapshot")
	if State.LockAfterQueue {
		State.TargetLock := FileOpen(PersonalTomlPath(), "r-wd", "UTF-8")
		AssertTrue(IsObject(State.TargetLock), "The final native replacement must really be denied after both requests were admitted")
	}
	return Written
}

_PEER_Reply(State) {
	try {
		Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
		for Hwnd in WinGetList("ahk_class #32770 ahk_pid " . Pid) {
			Title := WinGetTitle("ahk_id " . Hwnd)
			if TickElapsed(State.ReplyStarted) >= 3000 {
				State.Failure := Error("The real section dialog did not settle before its private reply deadline")
				PostMessage(0x10, 0, 0, , "ahk_id " . Hwnd)
				continue
			}
			Key := Hwnd . "|" . Title
			if State.Dialogs.Has(Key)
				continue
			if Title == WindowTitle(t("editor.hotstrings.new_section_title"))
				Value := "gamma"
			else if Title == WindowTitle(t("editor.hotstrings.desc_title"))
				Value := "Gamma native section"
			else if Title == WindowTitle(t("editor.hotstrings.rename_title"))
				Value := "Renamed native section"
			else
				continue
			ControlSetText(Value, "Edit1", "ahk_id " . Hwnd)
			State.Dialogs[Key] := true
			PostMessage(0x111, 1, 0, , "ahk_id " . Hwnd)
		}
	} catch Any as Failure {
		State.Failure := Failure
	}
}

_PEER_Case(Operation) {
	global ScriptInformation, ConfigurationFile, Features, _ReadPersonalTomlCache
	global _PersonalEditorData, _PersonalEditorSection, _PersonalEditorOpeningSource
	global _PersonalEditorGui, _PersonalEditorSessionEpoch, _PersonalEditorPrioCtrl
	global _HS_GrandTotalCache, _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	global PERSONAL_TOML_COMMIT_OK, PERSONAL_TOML_COMMIT_FAILED, _PersonalEditorEntryCohort, _PersonalEditorEntryBusy
	HadTotal := IsSet(_HS_GrandTotalCache), SavedTotal := HadTotal ? _HS_GrandTotalCache : unset
	Saved := {Path: ScriptInformation["PersonalTomlPath"], Config: ConfigurationFile, Features: Features,
		Cache: _ReadPersonalTomlCache, Data: _PersonalEditorData, Section: _PersonalEditorSection,
		Source: _PersonalEditorOpeningSource, Window: _PersonalEditorGui, Epoch: _PersonalEditorSessionEpoch,
		Priority: _PersonalEditorPrioCtrl, Critical: A_IsCritical, Suspended: A_IsSuspended,
		Desired: MasterGateState()["features"]}
	; Proposed production globals are intentionally absent in the red baseline.
	SavedCohort := IsSet(_PersonalEditorEntryCohort) ? _PersonalEditorEntryCohort : 0
	SavedBusy := IsSet(_PersonalEditorEntryBusy) ? _PersonalEditorEntryBusy : false
	RegistryScope := 0
	Fixture := _ScopeOwnerFixture(), Lock := 0
	Source := '[_meta]`ndescription = "Entry receipt fixture"`nsections_order = ["alpha", "beta"]`n'
		. '[_meta.sections.alpha]`ndescription = "Alpha"`n[_meta.sections.beta]`ndescription = "Beta"`n'
		. '[[alpha]]`n"private_alpha" = { output = "Alpha output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. '[[alpha]]`n"private_second" = { output = "Second output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. '[[beta]]`n"private_beta" = { output = "Beta output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	Windows := Map("windows", [])
	State := {Operation: InStr(Operation, "cohort") == 1 ? "add" : Operation, Entered: 0, Returned: 0,
		Failure: 0, CohortObserved: false, FirstStatus: "", SecondStatus: "",
		SwitchSection: Operation == "cohort-section", LockAfterQueue: Operation == "cohort-failure",
		TargetLock: 0, ReplyTimer: 0, ReplyStarted: 0, Dialogs: Map()}
	try {
		Critical("Off"), Suspend(false)
		ConfigurationFile := Fixture.path
		ScriptInformation["PersonalTomlPath"] := Fixture.directory . "\personal.toml"
		Features := _PersonalTomlCloneDetached(Saved.Features)
		MasterGateState()["features"] := _PersonalTomlCloneDetached(Saved.Desired)
		if Operation == "case-uncheck"
			Source := StrReplace(Source, '"private_alpha" = { output = "Alpha output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }', '"private_alpha" = { output = "Alpha output", is_word = true, auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true, final_result = false }')
		AssertTrue(FSWriteDurable(PersonalTomlPath(), Source))
		State.Window := _PEMO_Open(Windows, "alpha")
		Old := State.Window
		_PersonalEditorPrioCtrl := Old.Window.AddEdit("w80", "")
		State.CloseOnAdd := Old.Window.AddCheckbox("", "Close after saved Add")
		State.CloseOnAdd.Value := 0
		State.Button := Old.Window.AddButton("w120", "Private native operation")
		State.Button.OnEvent("Click", _PEER_Event.Bind(State))
		Old.Window.Show("NA")
		RegistryScope := (Operation == "case-add" || Operation == "case-uncheck") ? _PECASE_RegistryScope() : 0
		Original := KL_JsonEncode(_PersonalEditorData)
		if Operation == "case-add" || Operation == "case-uncheck" {
			Features["hotstrings"] := Map("personal", Map("alpha", Map("enabled", true, "time_activation_seconds", 0)))
			State.Operation := Operation == "case-add" ? "add" : "save"
			Old.Controls[1].Value := Operation == "case-add" ? "zzpersonalcaseprobe" : "private_alpha"
			Old.Controls[2].Value := "Private case output"
			Old.Controls[3].Value := 1
			Old.Controls[4].Value := 1
			Old.Controls[5].Value := Operation == "case-add" ? 1 : 0
			_PEER_Click(State)
			Fresh := ReadPersonalToml(true)
			Entries := Fresh["sections"]["alpha"]["entries"]
			Entry := Entries[Operation == "case-add" ? Entries.Length : 1]
			if Operation == "case-add" {
				AssertTrue(Entry["is_case_sensitive"])
				AssertTrue(Entry["is_case_sensitive_strict"], "The native checked case box must persist exact matching, as the shared editor does")
			} else {
				AssertTrue(!Entry["is_case_sensitive"])
				AssertTrue(!Entry["is_case_sensitive_strict"], "Unchecking must retire the old exact-match flag")
			}
			_PEER_RowsAgree(State)
			; Exercise the genuine section loader and matcher after the native
			; durable publication; never dispatch an output into the desktop.
			HSE_HardReset()
			HSE_FeedReset(true)
			Match := ""
			for Char in StrSplit(StrUpper(Entry["trigger"]))
				Match := HSE_FeedChar(Char)
			if Operation == "case-add"
				AssertEqual("", Match, "A checked lowercase native trigger cannot match uppercase input")
			else
				AssertTrue(IsObject(Match), "Unchecked case must restore the ordinary case-conforming match")
			HSE_FeedReset(true)
			for Char in StrSplit(Entry["trigger"])
				Match := HSE_FeedChar(Char)
			AssertTrue(IsObject(Match), "The literal trigger remains reachable")
			return
		}
		if InStr(Operation, "cohort") == 1 {
			Outer := _PersonalTomlCloneDetached(_PersonalEditorData)
			Outer["meta_description"] := "Independent live owner stage"
			Result := PersonalTomlCommitAndReload(Outer, ["alpha"], _PEER_CohortStage.Bind(State),
				0, 0, 0, 0, 0, 0, _PersonalEditorOpeningSource)
			AssertEqual(State.LockAfterQueue ? PERSONAL_TOML_COMMIT_FAILED : PERSONAL_TOML_COMMIT_OK, Result)
			AssertTrue(State.CohortObserved && State.Returned == 2)
			if State.LockAfterQueue {
				AssertTrue(FSUtf8ExactMatches(PersonalTomlPath(), Source), "Failed queued replacements cannot change durable bytes")
				AssertEqual(t("editor.hotstrings.err_write"), Old.Status.Value)
				_PEER_RowsAgree(State)
				AssertEqual(4, Old.List.GetCount(), "A failed deferred cohort retains both visible unsaved edits")
				State.TargetLock.Close(), State.TargetLock := 0
				; Select the actual visible pending second entry, then save it with
				; the real native entry producer: this retries the whole retained image.
				State.Operation := "save"
				Old.List.Modify(4, "Select Focus")
				_PEER_Click(State)
			}

			AssertEqual(t("editor.hotstrings.err_write"), State.FirstStatus, "DEFERRED is not a save receipt")
			AssertEqual(t("editor.hotstrings.err_write"), State.SecondStatus)
			Fresh := ReadPersonalToml(true)
			Alpha := Fresh["sections"]["alpha"]["entries"], Beta := Fresh["sections"]["beta"]["entries"]
			AssertEqual(State.SwitchSection ? 3 : 4, Alpha.Length)
			AssertEqual(State.SwitchSection ? 2 : 1, Beta.Length)
			Found := Map()
			for Section in Fresh["sections"]
				for Entry in Fresh["sections"][Section]["entries"]
					Found[Entry["trigger"]] := Entry["output"]
			AssertEqual("first queued output", Found["cohort_first"])
			AssertEqual("second queued output", Found["cohort_second"])
			_PEER_RowsAgree(State)
			return
		}
		if InStr(Operation, "section-") == 1 || Operation == "legacy" {
			TargetOperation := Operation
			State.Operation := "add"
			Old.Controls[1].Value := "before_other_publication"
			Old.Controls[2].Value := "Durable before publication"
			_PEER_Click(State)
			AssertEqual(3, ReadPersonalToml(true)["sections"]["alpha"]["entries"].Length)
			State.Operation := TargetOperation
			TestMsgBoxResponder((*) => "Yes")
			State.ReplyStarted := A_TickCount
			State.ReplyTimer := _PEER_Reply.Bind(State)
			SetTimer(State.ReplyTimer, 10)
			_PEER_Click(State)
			SetTimer(State.ReplyTimer, 0)
			if InStr(TargetOperation, "section-") == 1
				AssertTrue(!IsSet(_PersonalEditorEntryCohort) || !IsObject(_PersonalEditorEntryCohort), "A durable section publication must retire its predecessor receipt owner")
			Source := FSReadUtf8Exact(PersonalTomlPath())
			Original := KL_JsonEncode(_PersonalEditorData)
			State.Operation := "add"
			Operation := "add"
		}
		BeforeCount := Old.List.GetCount()
		if BeforeCount > 0
			Old.List.Modify(1, "Select Focus")
		Old.Controls[1].Value := Operation == "add" ? "private_added" : "private_alpha"
		Old.Controls[2].Value := Operation == "add" ? "Added output" : "Changed output"
		TestMsgBoxResponder((*) => "Yes")
		; Deny DELETE as well as WRITE: the production path replaces atomically.
		; A byte-range write lock alone would not refuse the final rename.
		Lock := FileOpen(PersonalTomlPath(), "r-wd", "UTF-8")
		AssertTrue(IsObject(Lock))
		AssertTrue(FSUtf8ExactMatches(PersonalTomlPath(), Source), "The held handle must still permit exact source reads")
		_PEER_Click(State)
		AssertEqual(t("editor.hotstrings.err_write"), Old.Status.Value)
		AssertTrue(FSUtf8ExactMatches(PersonalTomlPath(), Source), "The genuine native refusal must preserve the entire source")
		AssertEqual(Original, KL_JsonEncode(_PersonalEditorData), "A failed entry operation must not install a ghost mutable model")
		_PEER_RowsAgree(State)
		AssertEqual(BeforeCount, Old.List.GetCount())
		AssertTrue(DllCall("User32\IsWindowVisible", "Ptr", Old.Window.Hwnd, "Int"))
		Lock.Close(), Lock := 0
		; No retyping, replacement window or source receipt can make this pass.
		_PEER_Click(State)
		Fresh := ReadPersonalToml(true)
		Entries := Fresh["sections"][_PersonalEditorSection]["entries"]
		AssertEqual(Operation == "add" ? BeforeCount + 1 : Operation == "delete" ? BeforeCount - 1 : BeforeCount, Entries.Length)
		if Operation == "add"
			AssertEqual("private_added", Entries[Entries.Length]["trigger"])
		else if Operation == "save"
			AssertEqual("Changed output", Entries[1]["output"])
		else
			AssertEqual("private_second", Entries[1]["trigger"], "Retry must remove the original row, never its successor")
		_PEER_RowsAgree(State)
		AssertTrue(InStr(Old.Status.Value, t("editor.hotstrings.saved_prefix")) == 1)
	} finally {
		if IsObject(Lock)
			Lock.Close()
		if IsObject(State.TargetLock)
			State.TargetLock.Close()
		if IsObject(State.ReplyTimer)
			SetTimer(State.ReplyTimer, 0)
		TestMsgBoxResponder("")
		for Owned in Windows["windows"] {
			Owned.Window.OnEvent("Close", Owned.Close, 0)
			Owned.Window.Destroy()
		}
		_PersonalEditorData := Saved.Data, _PersonalEditorSection := Saved.Section
		_PersonalEditorOpeningSource := Saved.Source, _PersonalEditorGui := Saved.Window
		_PersonalEditorSessionEpoch := Saved.Epoch, _PersonalEditorPrioCtrl := Saved.Priority
		if IsSet(_PersonalEditorEntryCohort)
			_PersonalEditorEntryCohort := SavedCohort
		if IsSet(_PersonalEditorEntryBusy)
			_PersonalEditorEntryBusy := SavedBusy
		ScriptInformation["PersonalTomlPath"] := Saved.Path, ConfigurationFile := Saved.Config
		Features := Saved.Features, MasterGateState()["features"] := Saved.Desired
		_PersonalTomlInvalidateCaches(Fixture.directory . "\personal.toml")
		_ReadPersonalTomlCache := Saved.Cache
		_HS_GrandTotalCache := HadTotal ? SavedTotal : unset
		for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache] {
			if Store.Has(Fixture.path)
				Store.Delete(Fixture.path)
		}
		_ScopeOwnerCleanup(Fixture)
		if IsObject(RegistryScope)
			_PECASE_RegistryScope(RegistryScope)
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
}

for _PEER_Mode in ["add", "delete", "save", "cohort", "cohort-failure", "cohort-section", "section-rename", "section-delete", "section-new", "legacy", "case-add", "case-uncheck"]
	Test("Personal editor entry receipts: native " . _PEER_Mode . " preserves rows and retry (personal-entry-receipts)",
		_PEER_Case.Bind(_PEER_Mode))


; The actual native constructor owns every control and all of its handlers.
_PESORT_Column(State, Control, Column) {
	State.HeaderClicks += 1, State.HeaderColumn := Column
	return
}

_PESORT_Selected(State, Control, Row, Selected) {
	if Selected
		State.Selections += 1
	return
}

_PECT_Phase(Mode, Phase) {
	if Mode == "constructor-current" || Mode == "constructor-successor"
		_TestPrint("# personal-constructor-phase mode=" . Mode . " phase=" . Phase . " critical=" . A_IsCritical)
}

_PESORT_Click(Hwnd, X, Y, Mode := "") {
	Point := (Y << 16) | (X & 0xFFFF)
	_PECT_Phase(Mode, "row-down-before")
	DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x201,
		"Ptr", 1, "Ptr", Point, "Ptr")
	_PECT_Phase(Mode, "row-down-after")
	_PECT_Phase(Mode, "row-up-before")
	DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x202,
		"Ptr", 0, "Ptr", Point, "Ptr")
	_PECT_Phase(Mode, "row-up-after")
}

_PESORT_Confirmed(State, Text, Title, Options) {
	State.Confirmations += 1
	State.Confirmation := Text
	return "Yes"
}

_PESORT_ButtonEntered(State, *) {
	State.Entered += 1
	if State.HasOwnProp("ConstructorMode")
		_PECT_Phase(State.ConstructorMode, "save-observer-entered")
	return
}


_PESW_Destroy(State, WParam, LParam, Message, Hwnd) {
	global _PersonalEditorGui, _PersonalEditorSessionEpoch, _PersonalEditorSection
	if Hwnd != State.OldHwnd || State.DestroyEvents > 0
		return
	State.DestroyEvents += 1
	try {
		AssertFalse(IsObject(_PersonalEditorGui), "The actual old native owner must retire before its WM_DESTROY")
		AssertEqual(State.OldEpoch + 1, _PersonalEditorSessionEpoch)
		if State.Mode == "switch-successor" {
			OpenPersonalEditor("alpha")
			AssertTrue(_PersonalEditorGui is Gui && _PersonalEditorSection == "alpha")
			State.NewerHwnd := _PersonalEditorGui.Hwnd
			State.NewerEpoch := _PersonalEditorSessionEpoch
			AssertTrue(State.NewerHwnd != State.OldHwnd
				&& DllCall("User32\IsWindow", "Ptr", State.NewerHwnd, "Int"),
				"One genuine public successor must really exist inside the old native Destroy callback")
		}
	} catch as Failure {
		State.Failure := Failure
	}
	return
}


_PECT_ParentCreated(State, WParam, LParam, Message, Hwnd) {
	global _PersonalEditorGui, _PersonalEditorSessionEpoch, _PersonalEditorSection, _PersonalEditorPrioCtrl
	if (WParam & 0xFFFF) != 1 || State.Observed > 0 || IsObject(_PersonalEditorGui)
		return
	if _PersonalEditorSessionEpoch != State.BeforeEpoch + 1
		return
	Parent := GuiFromHwnd(Hwnd)
	if !(Parent is Gui) || Parent.Title != WindowTitle(t("editor.hotstrings.window_title"))
		return
	State.Observed += 1, State.OriginalHwnd := Hwnd
	try {
		Edits := 0
		for Control in Parent
			if Control.Type == "Edit"
				Edits += 1
		AssertTrue(Edits < 3, "The native child-create message must precede the pending constructor's priority publication")
		if State.Mode == "constructor-successor" {
			OpenPersonalEditor("beta")
			AssertTrue(_PersonalEditorGui is Gui && _PersonalEditorSection == "beta")
			State.NewerHwnd := _PersonalEditorGui.Hwnd
			State.NewerEpoch := _PersonalEditorSessionEpoch
			State.NewerPriorityHwnd := _PersonalEditorPrioCtrl.Hwnd
			AssertTrue(State.NewerHwnd != State.OriginalHwnd
				&& DllCall("User32\IsWindow", "Ptr", State.NewerHwnd, "Int")
				&& DllCall("User32\IsWindow", "Ptr", State.NewerPriorityHwnd, "Int"),
				"One real public successor and its own priority control must already be native before the old constructor resumes")
		}
	} catch as Failure {
		State.Failure := Failure
	}
	return
}

_PESORT_Case(Operation) {
	global ScriptInformation, ConfigurationFile, Features, _ReadPersonalTomlCache
	global _PersonalEditorData, _PersonalEditorSection, _PersonalEditorOpeningSource
	global _PersonalEditorGui, _PersonalEditorSessionEpoch, _PersonalEditorPrioCtrl
	global _PersonalEditorEntryCohort, _PersonalEditorEntryBusy
	global _HS_GrandTotalCache, _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	Saved := {Path: ScriptInformation["PersonalTomlPath"], Config: ConfigurationFile,
		Features: Features, Desired: MasterGateState()["features"], Cache: _ReadPersonalTomlCache,
		Data: _PersonalEditorData, Section: _PersonalEditorSection, Source: _PersonalEditorOpeningSource,
		Window: _PersonalEditorGui, Epoch: _PersonalEditorSessionEpoch, Priority: _PersonalEditorPrioCtrl,
		Cohort: _PersonalEditorEntryCohort, Busy: _PersonalEditorEntryBusy,
		Critical: A_IsCritical, Suspended: A_IsSuspended, Responder: TestMsgBoxResponder()}
	HadTotal := IsSet(_HS_GrandTotalCache), SavedTotal := HadTotal ? _HS_GrandTotalCache : unset
	IsDefault := Operation == "default-missing" || Operation == "default-live"
	Fixture := IsDefault ? _ScopeOwnerFixture('[personal_editor]`ndefault_section = "'
		. (Operation == "default-missing" ? "deleted_section" : "alpha") . '"`n') : _ScopeOwnerFixture()
	RegistryScope := 0, Window := 0, CloseHwnd := 0
	Primary := 0, CleanupFailure := 0, WindowEpoch := 0, CtorHook := 0, SwitchHook := 0
	State := {HeaderClicks: 0, HeaderColumn: 0, Selections: 0, Confirmations: 0, Confirmation: "", Entered: 0}
	Source := '[_meta]`ndescription = "Native sort owner fixture"`nsections_order = ["alpha"]`n'
		. '[_meta.sections.alpha]`ndescription = "Alpha"`n'
		. '[[alpha]]`n"zeta_native_sort" = { output = "Zeta unchanged", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. '[[alpha]]`n"alpha_native_sort" = { output = "Alpha unchanged", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
	try {
		Critical("Off"), Suspend(false)
		AssertFalse(_HsEdWeb_Available(), "The delivered runner must take the genuine unavailable-WebView native fallback")
		RegistryScope := _PECASE_RegistryScope()
		ConfigurationFile := Fixture.path
		ScriptInformation["PersonalTomlPath"] := Fixture.directory . "\personal.toml"
		Features := _PersonalTomlCloneDetached(Saved.Features)
		MasterGateState()["features"] := _PersonalTomlCloneDetached(Saved.Desired)
		_PersonalEditorGui := "", _PersonalEditorOpeningSource := false
		_PersonalEditorEntryCohort := 0, _PersonalEditorEntryBusy := false
		IsSwitch := Operation == "switch-current" || Operation == "switch-successor"
		if IsSwitch {
			Source := StrReplace(Source, 'sections_order = ["alpha"]', 'sections_order = ["alpha", "beta"]')
				. '[_meta.sections.beta]`ndescription = "Beta"`n[[beta]]`n'
				. '"beta_native_switch" = { output = "Beta unchanged", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		}
		IsCtor := Operation == "constructor-current" || Operation == "constructor-successor"
		if IsCtor {
			Source := StrReplace(Source, 'sections_order = ["alpha"]', 'sections_order = ["alpha", "beta"]')
				. '[_meta.sections.beta]`ndescription = "Beta"`n[[beta]]`n'
				. '"beta_native_constructor" = { output = "Beta unchanged", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		}
		AssertTrue(FSWriteDurable(PersonalTomlPath(), Source))
		Ctor := 0
		if IsCtor {
			Ctor := {Mode: Operation, BeforeEpoch: _PersonalEditorSessionEpoch, Observed: 0,
				OriginalHwnd: 0, NewerHwnd: 0, NewerEpoch: 0, NewerPriorityHwnd: 0, Failure: 0}
			CtorHook := _PECT_ParentCreated.Bind(Ctor)
			OnMessage(0x210, CtorHook)
		}
		try {
			if IsDefault
				OpenPersonalEditor()
			else
				OpenPersonalEditor("alpha")
		} finally {
			if IsObject(CtorHook)
				OnMessage(0x210, CtorHook, 0), CtorHook := 0
		}
		Window := _PersonalEditorGui
		CloseHwnd := Window.Hwnd, WindowEpoch := _PersonalEditorSessionEpoch
		AssertTrue(Window is Gui && _PersonalEditorOpeningSource["window"] == Window,
			"The production native constructor must publish its own actual source and controls")
		List := 0, Drop := 0, Edits := [], Button := 0, ButtonY := -1
		Caption := t((Operation == "save" || IsCtor) ? "editor.hotstrings.btn_edit" : "editor.hotstrings.btn_delete_entry")
		for Control in Window {
			if Control.Type == "ListView"
				List := Control
			if Control.Type == "DDL"
				Drop := Control
			if Control.Type == "Edit"
				Edits.Push(Control)
			if Control.Type == "Button" && Control.Text == Caption {
				Control.GetPos(, &Y)
				if Y > ButtonY
					Button := Control, ButtonY := Y
			}
		}
		AssertTrue(IsObject(List) && Edits.Length == 3 && IsObject(Button))
		if IsCtor {
			if IsObject(Ctor.Failure)
				throw Ctor.Failure
			AssertEqual(1, Ctor.Observed, "A genuine early native child-create notification must be observable")
			if Operation == "constructor-successor" {
				AssertTrue(Ctor.NewerHwnd != 0 && CloseHwnd == Ctor.NewerHwnd)
				AssertEqual(Ctor.NewerEpoch, _PersonalEditorSessionEpoch)
				AssertEqual("beta", _PersonalEditorSection)
				AssertTrue(DllCall("User32\IsWindow", "Ptr", Ctor.NewerHwnd, "Int"))
				AssertTrue(DllCall("User32\IsWindow", "Ptr", Ctor.NewerPriorityHwnd, "Int"))
				AssertEqual(Ctor.NewerPriorityHwnd, Edits[3].Hwnd)
			} else {
				AssertEqual(0, Ctor.NewerHwnd)
				AssertEqual(Ctor.OriginalHwnd, CloseHwnd)
			}
			PriorityHwnd := 0, PriorityError := ""
			try PriorityHwnd := _PersonalEditorPrioCtrl.Hwnd
			catch as Failure
				PriorityError := Type(Failure)
			_TestPrint("# personal-native-constructor mode=" . Operation . " parent_create=" . Ctor.Observed
				. " newer_seen=" . (Ctor.NewerHwnd != 0) . " native_priority_alive="
				. DllCall("User32\IsWindow", "Ptr", Edits[3].Hwnd, "Int")
				. " global_priority_matches=" . (PriorityHwnd == Edits[3].Hwnd) . " priority_error=" . PriorityError)
			AssertEqual(Edits[3].Hwnd, PriorityHwnd,
				"The current native owner must retain its own live priority control after an older constructor retires")
			; A genuine row click and the unchanged Save button exercise the
			; surviving field through the normal form and durable writer too.
			State.ConstructorMode := Operation
			_PECT_Phase(Operation, "list-reset-before")
			List.Modify(0, "-Select -Focus")
			_PECT_Phase(Operation, "list-reset-after")
			List.OnEvent("ItemSelect", _PESORT_Selected.Bind(State))
			Rect := Buffer(16, 0)
			_PECT_Phase(Operation, "row-rect-before")
			AssertTrue(DllCall("User32\SendMessageW", "Ptr", List.Hwnd, "UInt", 0x100E,
				"Ptr", 0, "Ptr", Rect.Ptr, "Ptr"))
			_PECT_Phase(Operation, "row-rect-after")
			_PESORT_Click(List.Hwnd, NumGet(Rect, 0, "Int") + 20,
				(NumGet(Rect, 4, "Int") + NumGet(Rect, 12, "Int")) // 2, Operation)
			Started := A_TickCount
			while State.Selections == 0 && TickElapsed(Started) < 3000
				Sleep(5)
			_PECT_Phase(Operation, "selection-wait-after")
			AssertTrue(State.Selections >= 1)
			SelectedTrigger := List.GetText(1, 1)
			AssertEqual(SelectedTrigger, Edits[1].Value)
			Edits[2].Value := "Constructor retained owner output"
			Button.OnEvent("Click", _PESORT_ButtonEntered.Bind(State), -1)
			_PECT_Phase(Operation, "save-click-before")
			DllCall("User32\SendMessageW", "Ptr", Button.Hwnd, "UInt", 0xF5,
				"Ptr", 0, "Ptr", 0, "Ptr")
			_PECT_Phase(Operation, "save-click-after")
			Started := A_TickCount
			while State.Entered == 0 && TickElapsed(Started) < 3000
				Sleep(5)
			_PECT_Phase(Operation, "save-wait-after")
			AssertEqual(1, State.Entered)
			_PECT_Phase(Operation, "business-read-before")
			Fresh := ReadPersonalToml(true), Found := false
			_PECT_Phase(Operation, "business-read-after")
			for Entry in Fresh["sections"][_PersonalEditorSection]["entries"] {
				if Entry["trigger"] == SelectedTrigger {
					AssertEqual("Constructor retained owner output", Entry["output"])
					Found := true
				}
			}
			AssertTrue(Found, "The surviving real field must remain usable through a genuine durable save")
			_PECT_Phase(Operation, "business-completed")
			return
		}
		if IsSwitch {
			AssertTrue(_PersonalEditorData["sections"].Has("beta"))
			Transition := {Mode: Operation, OldHwnd: CloseHwnd, OldEpoch: WindowEpoch,
				DestroyEvents: 0, NewerHwnd: 0, NewerEpoch: 0, Failure: 0}
			SwitchHook := _PESW_Destroy.Bind(Transition)
			OnMessage(0x2, SwitchHook)
			try OpenPersonalEditor("beta")
			finally {
				OnMessage(0x2, SwitchHook, 0), SwitchHook := 0
				; Capture the actual live successor for native cleanup even when
				; the old return wrongly replaced the callback's newer window.
				if _PersonalEditorGui is Gui {
					Window := _PersonalEditorGui
					CloseHwnd := Window.Hwnd, WindowEpoch := _PersonalEditorSessionEpoch
				}
			}
			if IsObject(Transition.Failure)
				throw Transition.Failure
			AssertEqual(1, Transition.DestroyEvents, "Only the exact original HWND can trigger this native observer")
			NewerAlive := Transition.NewerHwnd != 0 && DllCall("User32\IsWindow", "Ptr", Transition.NewerHwnd, "Int")
			_TestPrint("# personal-native-switch mode=" . Operation . " destroys=" . Transition.DestroyEvents
				. " newer_seen=" . (Transition.NewerHwnd != 0) . " newer_alive_after=" . NewerAlive
				. " final_section=" . _PersonalEditorSection . " newer_is_current=" . (Transition.NewerHwnd == CloseHwnd))
			if Operation == "switch-successor" {
				AssertTrue(Transition.NewerHwnd != 0 && NewerAlive,
					"The old section switch cannot destroy a newer native window published during its own Destroy")
				AssertEqual(Transition.NewerHwnd, CloseHwnd)
				AssertEqual(Transition.NewerEpoch, _PersonalEditorSessionEpoch)
				AssertEqual("alpha", _PersonalEditorSection, "The newer public section request must retain its exact owner")
			} else {
				AssertEqual(0, Transition.NewerHwnd)
				AssertEqual("beta", _PersonalEditorSection, "The ordinary no-reentry switch must still complete")
				AssertTrue(DllCall("User32\IsWindow", "Ptr", CloseHwnd, "Int"))
			}
			FreshList := 0
			for Control in Window
				if Control.Type == "ListView"
					FreshList := Control
			AssertTrue(IsObject(FreshList))
			AssertEqual(Operation == "switch-successor" ? 2 : 1, FreshList.GetCount())
			AssertTrue(FSUtf8ExactMatches(ConfigurationFile, Fixture.source))
			AssertTrue(FSUtf8ExactMatches(PersonalTomlPath(), Source), "Section presentation cannot mutate personal content")
			return
		}
		if IsDefault {
			AssertTrue(IsObject(Drop))
			AssertEqual(1, Drop.Value, "The genuine dropdown must already display the first live section")
			AssertEqual("Alpha", Drop.Text)
			AssertEqual(2, _PersonalEditorData["sections"]["alpha"]["entries"].Length,
				"The original parser must really load the source entries before the GUI projects them")
			AssertTrue(FSUtf8ExactMatches(ConfigurationFile, Fixture.source), "Opening cannot repair the stale preference by writing config")
			AssertTrue(FSUtf8ExactMatches(PersonalTomlPath(), Source), "Opening cannot modify personal entries")
			_TestPrint("# personal-native-default mode=" . Operation . " pointer=" . _PersonalEditorSection . " dropdown=" . Drop.Text
				. " source_entries=" . _PersonalEditorData["sections"]["alpha"]["entries"].Length . " visible_entries=" . List.GetCount())
			AssertEqual(2, List.GetCount(), "A stale saved section cannot hide every entry of the section already shown by the native dropdown")
			AssertEqual("alpha", _PersonalEditorSection, "The selected model pointer and dropdown must describe the same live section")
			AssertEqual("zeta_native_sort", List.GetText(1, 1))
			AssertEqual("alpha_native_sort", List.GetText(2, 1))
			return
		}
		AssertEqual(2, List.GetCount())
		AssertEqual("zeta_native_sort", List.GetText(1, 1), "The source order must really differ from lexical order")
		AssertEqual("alpha_native_sort", List.GetText(2, 1))
		ColumnObserver := _PESORT_Column.Bind(State), SelectionObserver := _PESORT_Selected.Bind(State)
		ButtonObserver := _PESORT_ButtonEntered.Bind(State)
		List.OnEvent("ColClick", ColumnObserver)
		List.OnEvent("ItemSelect", SelectionObserver)
		Button.OnEvent("Click", ButtonObserver, -1)
		Header := DllCall("User32\SendMessageW", "Ptr", List.Hwnd, "UInt", 0x101F,
			"Ptr", 0, "Ptr", 0, "Ptr")
		AssertTrue(Header != 0 && DllCall("User32\IsWindow", "Ptr", Header, "Int"))
		Rect := Buffer(16, 0)
		AssertTrue(DllCall("User32\SendMessageW", "Ptr", Header, "UInt", 0x1207,
			"Ptr", 0, "Ptr", Rect.Ptr, "Ptr"))
		_PESORT_Click(Header, (NumGet(Rect, 0, "Int") + NumGet(Rect, 8, "Int")) // 2,
			(NumGet(Rect, 4, "Int") + NumGet(Rect, 12, "Int")) // 2)
		Started := A_TickCount
		while State.HeaderClicks == 0 && TickElapsed(Started) < 3000
			Sleep(5)
		AssertEqual(1, State.HeaderClicks, "A genuine header click must reach the native ColClick producer")
		AssertEqual(1, State.HeaderColumn)
		Sleep(20)
		Displayed := List.GetText(1, 1)
		Other := Displayed == "zeta_native_sort" ? "alpha_native_sort" : "zeta_native_sort"
		List.Modify(0, "-Select -Focus")
		NumPut("Int", 0, Rect, 0)
		AssertTrue(DllCall("User32\SendMessageW", "Ptr", List.Hwnd, "UInt", 0x100E,
			"Ptr", 0, "Ptr", Rect.Ptr, "Ptr"))
		_PESORT_Click(List.Hwnd, NumGet(Rect, 0, "Int") + 20,
			(NumGet(Rect, 4, "Int") + NumGet(Rect, 12, "Int")) // 2)
		Started := A_TickCount
		while State.Selections == 0 && TickElapsed(Started) < 3000
			Sleep(5)
		AssertTrue(State.Selections >= 1, "A genuine native row click must invoke the production form projection")
		AssertEqual(1, List.GetNext(0))
		FormTrigger := Edits[1].Value
		if Operation == "save"
			Edits[2].Value := "Changed selected output"
		TestMsgBoxResponder(_PESORT_Confirmed.Bind(State))
		DllCall("User32\SendMessageW", "Ptr", Button.Hwnd, "UInt", 0xF5,
			"Ptr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while State.Entered == 0 && TickElapsed(Started) < 3000
			Sleep(5)
		AssertEqual(1, State.Entered, "The real native button must enter its unchanged production callback chain once")
		Fresh := ReadPersonalToml(true), Entries := Fresh["sections"]["alpha"]["entries"], Found := Map()
		for Entry in Entries
			Found[Entry["trigger"]] := Entry["output"]
		_TestPrint("# personal-native-sort operation=" . Operation . " displayed=" . Displayed . " form=" . FormTrigger
			. " header_clicks=" . State.HeaderClicks . " durable_entries=" . Entries.Length)
		if Operation == "save" {
			AssertEqual(2, Entries.Length)
			AssertEqual("Changed selected output", Found[Displayed], "Save must update the visibly selected entry, never the old model index")
			AssertEqual(Other == "zeta_native_sort" ? "Zeta unchanged" : "Alpha unchanged", Found[Other])
		} else {
			AssertEqual(1, State.Confirmations)
			AssertEqual(1, Entries.Length)
			AssertFalse(Found.Has(Displayed), "Delete must remove the visibly selected entry, never the old model index")
			AssertTrue(Found.Has(Other), "The other original entry must remain durable")
		}
		AssertEqual(Displayed, FormTrigger, "The form must always describe its displayed selection")
	} catch as Failure {
		Primary := Failure
	} finally {
		_PECT_Phase(Operation, "cleanup-entered")
		if IsObject(CtorHook)
			OnMessage(0x210, CtorHook, 0)
		if IsObject(SwitchHook)
			OnMessage(0x2, SwitchHook, 0)
		TestMsgBoxResponder(Saved.Responder)
		try {
			if IsObject(Window) && DllCall("User32\IsWindow", "Ptr", CloseHwnd, "Int") {
				_PECT_Phase(Operation, "cleanup-close-post-before")
				AssertTrue(DllCall("User32\PostMessageW", "Ptr", CloseHwnd, "UInt", 0x10,
					"Ptr", 0, "Ptr", 0, "Int"), "Cleanup must post Close to this exact native editor")
				Started := A_TickCount
				while DllCall("User32\IsWindow", "Ptr", CloseHwnd, "Int") && TickElapsed(Started) < 3000
					Sleep(5)
				_PECT_Phase(Operation, "cleanup-close-wait-after")
				if DllCall("User32\IsWindow", "Ptr", CloseHwnd, "Int")
					throw Error("The private production editor did not retire through its native Close")
			}
		} catch as Failure {
			CleanupFailure := Failure
			; A cleanup failure remains a failed test. Retire only our owned
			; native controls before restoring an unrelated parent UI scope.
			if IsObject(Window) {
				_OnEditorClose(Window, WindowEpoch)
				Window.Destroy()
			}
		}
		_PersonalEditorData := Saved.Data, _PersonalEditorSection := Saved.Section
		_PersonalEditorOpeningSource := Saved.Source, _PersonalEditorGui := Saved.Window
		_PersonalEditorSessionEpoch := Saved.Epoch, _PersonalEditorPrioCtrl := Saved.Priority
		_PersonalEditorEntryCohort := Saved.Cohort, _PersonalEditorEntryBusy := Saved.Busy
		ScriptInformation["PersonalTomlPath"] := Saved.Path, ConfigurationFile := Saved.Config
		Features := Saved.Features, MasterGateState()["features"] := Saved.Desired
		_PersonalTomlInvalidateCaches(Fixture.directory . "\personal.toml")
		_ReadPersonalTomlCache := Saved.Cache
		_HS_GrandTotalCache := HadTotal ? SavedTotal : unset
		for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache]
			if Store.Has(Fixture.path)
				Store.Delete(Fixture.path)
		_PECT_Phase(Operation, "cleanup-files-before")
		_ScopeOwnerCleanup(Fixture)
		_PECT_Phase(Operation, "cleanup-files-after")
		if IsObject(RegistryScope) {
			_PECT_Phase(Operation, "cleanup-registry-before")
			_PECASE_RegistryScope(RegistryScope)
			_PECT_Phase(Operation, "cleanup-registry-after")
		}
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for _PESORT_Mode in ["save", "delete"]
	Test("Personal editor native sort: " . _PESORT_Mode . " retains the visibly selected durable entry (personal-native-sort-owner)",
		_PESORT_Case.Bind(_PESORT_Mode))

for _PEDEFAULT_Mode in ["default-missing", "default-live"]
	Test("Personal editor native default: " . _PEDEFAULT_Mode . " keeps the displayed section entries visible (personal-native-default-owner)",
		_PESORT_Case.Bind(_PEDEFAULT_Mode))

for _PESW_Mode in ["switch-current", "switch-successor"]
	Test("Personal editor native switch: " . _PESW_Mode . " preserves the latest HWND published during Destroy (personal-native-switch-owner)",
		_PESORT_Case.Bind(_PESW_Mode))

for _PECT_Mode in ["constructor-current", "constructor-successor"]
	Test("Personal editor native constructor: " . _PECT_Mode . " retains the current priority control (personal-native-constructor-owner)",
		_PESORT_Case.Bind(_PECT_Mode))
