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
	global _HS_GrandTotalCache, _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	HadTotal := IsSet(_HS_GrandTotalCache)
	SavedTotal := HadTotal ? _HS_GrandTotalCache : unset
	Saved := { Path: ScriptInformation["PersonalTomlPath"], Config: ConfigurationFile, Features: Features,
		Cache: _ReadPersonalTomlCache, Data: _PersonalEditorData, Section: _PersonalEditorSection,
		Source: _PersonalEditorOpeningSource, Window: _PersonalEditorGui, Epoch: _PersonalEditorSessionEpoch,
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
		AssertTrue(FSWriteDurable(PersonalTomlPath(), Source))
		State.Window := _PEMO_Open(Windows, "alpha")
		Old := State.Window
		_PersonalEditorPrioCtrl := Old.Window.AddEdit("w80", "")
		State.CloseOnAdd := Old.Window.AddCheckbox("", "Close after saved Add")
		State.CloseOnAdd.Value := 0
		State.Button := Old.Window.AddButton("w120", "Private native operation")
		State.Button.OnEvent("Click", _PEER_Event.Bind(State))
		Old.Window.Show("NA")
		Original := KL_JsonEncode(_PersonalEditorData)
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
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
}

for _PEER_Mode in ["add", "delete", "save", "cohort", "cohort-failure", "cohort-section", "section-rename", "section-delete", "section-new", "legacy"]
	Test("Personal editor entry receipts: native " . _PEER_Mode . " preserves rows and retry (personal-entry-receipts)",
		_PEER_Case.Bind(_PEER_Mode))
