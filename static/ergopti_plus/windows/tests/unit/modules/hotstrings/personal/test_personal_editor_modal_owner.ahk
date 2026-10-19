; tests/unit/modules/hotstrings/personal/test_personal_editor_modal_owner.ahk

; Real InputBox/MsgBox return into the production section handlers. Only their
; native controls are automated: source admission, writes and Close are real.

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

_PEMO_Pump(State) {
	global _PersonalEditorGui, _PersonalEditorSection, _PersonalEditorSessionEpoch
	try {
		if A_TickCount - State["started"] > 5000
			throw Error("The real editor modal exceeded its fixture deadline")
		for Hwnd in WinGetList("ahk_pid " . A_Pid) {
			if WinGetClass("ahk_id " . Hwnd) != "#32770"
				continue
			Title := WinGetTitle("ahk_id " . Hwnd)
			Kind := State["titles"].Get(Title, "")
			if Kind == "" || State["seen"].Has(Hwnd . ":" . Title)
				continue
			Target := State["boundary"] == "new-name" ? "name" : State["boundary"] == "new-description" ? "description"
				: State["boundary"] == "rename" ? "rename" : "delete"
			if Kind == Target && !State["acted"] && State["mode"] != "live" && State["mode"] != "cancel" {
				Old := State["old"]
				if State["mode"] == "closed" || State["mode"] == "reopened" {
					if !State["close_posted"] {
						State["close_posted"] := true
						PostMessage(0x10, 0, 0, , "ahk_id " . Old.Window.Hwnd)
						return
					}
					if _PersonalEditorGui == Old.Window
						return
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
			}
			State["seen"][Hwnd . ":" . Title] := true
			State["dialogs"] += 1
			_PEMO_Respond(State, Hwnd, Kind)
		}
	} catch as Err {
		State["error"] := Err
		; A failing observation must release the real blocking dialog as well.
		for Hwnd in WinGetList("ahk_class #32770 ahk_pid " . A_Pid) {
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
