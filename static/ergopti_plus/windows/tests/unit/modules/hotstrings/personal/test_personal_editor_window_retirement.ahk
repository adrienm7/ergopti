; tests/unit/modules/hotstrings/personal/test_personal_editor_window_retirement.ahk

; The public editor opens genuine native controls from private TOML files.
; An unavailable private loader selects the supported native fallback; no browser
; port or replacement editor handler participates in these Close assertions.

_PENR_Open(State) {
	global _PersonalEditorGui, _PersonalEditorOpeningSource, _PersonalEditorSessionEpoch
	OpenPersonalEditor("alpha")
	AssertTrue(_PersonalEditorGui is Gui, "the public entry must publish the real native editor")
	Window := _PersonalEditorGui, Hwnd := Window.Hwnd
	Owned := { Window: Window, Hwnd: Hwnd, Source: _PersonalEditorOpeningSource,
		Epoch: _PersonalEditorSessionEpoch, Controls: WinGetControlsHwnd("ahk_id " . Hwnd) }
	State.Windows.Push(Owned)
	AssertTrue(DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int"), "the actual editor must be visible")
	AssertTrue(Owned.Source is Map && Owned.Source["admitted"]
		&& Owned.Source["kind"] == "native" && Owned.Source["window"] == Window,
		"the real file reader must admit this exact public window")
	AssertTrue(_PersonalTomlOpeningSessionCurrent(Owned.Source), "its genuine session authority must be live")
	AssertTrue(Owned.Controls.Length > 0, "the constructor must build real controls")
	List := GuiCtrlFromHwnd(ControlGetHwnd("SysListView321", "ahk_id " . Hwnd))
	Trigger := GuiCtrlFromHwnd(ControlGetHwnd("Edit1", "ahk_id " . Hwnd))
	Output := GuiCtrlFromHwnd(ControlGetHwnd("Edit2", "ahk_id " . Hwnd))
	AssertEqual(1, List.GetCount(), "the real native list must show the private parsed entry")
	AssertEqual("private_alpha", List.GetText(1, 1), "the genuine parser must populate the expected native row")
	_PENR_SelectNative(List, Trigger, Output)
	return Owned
}

_PENR_SelectionObserved(Seen, Control, Row, Selected) {
	Seen.Calls += 1, Seen.Hwnd := Control.Hwnd
	Seen.Row := Row, Seen.Selected := Selected
}

_PENR_SelectNative(List, Trigger, Output) {
	static LVM_SETITEMSTATE := 0x102B, LVIS_FOCUSED := 0x1, LVIS_SELECTED := 0x2
	Seen := { Calls: 0, Hwnd: 0, Row: 0, Selected: false }
	Observer := _PENR_SelectionObserved.Bind(Seen)
	List.OnEvent("ItemSelect", Observer)
	try {
		; Gui.ListView.Modify intentionally suppresses its own ItemSelect event.
		; Send the native state request instead: the real common control emits
		; LVN_ITEMCHANGED and AHK dispatches the existing production callback.
		; LVITEMW is 88/60 bytes on Win64/Win32; state and stateMask are DWORDs
		; at offsets 12 and 16 on both architectures.
		Item := Buffer(A_PtrSize == 8 ? 88 : 60, 0)
		Flags := LVIS_FOCUSED | LVIS_SELECTED
		NumPut("UInt", Flags, Item, 16)
		AssertTrue(DllCall("User32\SendMessageW", "Ptr", List.Hwnd, "UInt", LVM_SETITEMSTATE,
			"Ptr", -1, "Ptr", Item.Ptr, "Int"), "the real ListView must accept clearing prior selection")
		AssertEqual(0, List.GetNext(0), "the native precondition must leave no selected row")
		NumPut("UInt", Flags, Item, 12)
		AssertTrue(DllCall("User32\SendMessageW", "Ptr", List.Hwnd, "UInt", LVM_SETITEMSTATE,
			"Ptr", 0, "Ptr", Item.Ptr, "Int"), "the real ListView must accept selecting its first row")
		Started := A_TickCount
		while (Seen.Calls == 0 || Seen.Hwnd != List.Hwnd || Seen.Row != 1 || !Seen.Selected
				|| Trigger.Value != "private_alpha" || Output.Value != "Private output")
				&& A_TickCount - Started < 1000
			Sleep(10)
		_TestPrint("# personal-editor-native-selection selected=" . List.GetNext(0)
			. " events=" . Seen.Calls . " event_hwnd=" . Seen.Hwnd
			. " event_row=" . Seen.Row . " event_selected=" . Seen.Selected
			. " trigger_match=" . (Trigger.Value == "private_alpha")
			. " output_match=" . (Output.Value == "Private output"))
		AssertEqual(1, List.GetNext(0), "the genuine native control must retain its selected row")
		AssertTrue(Seen.Calls > 0 && Seen.Hwnd == List.Hwnd && Seen.Row == 1 && Seen.Selected,
			"the actual ItemSelect event must observe this native selection")
		AssertEqual("private_alpha", Trigger.Value, "actual native selection must populate the trigger")
		AssertEqual("Private output", Output.Value, "the real selection callback must populate the result")
	} finally List.OnEvent("ItemSelect", Observer, 0)
}

_PENR_Close(Owned) {
	global _PersonalEditorSessionEpoch
	AssertTrue(DllCall("User32\PostMessageW", "Ptr", Owned.Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Int"),
		"the genuine native window must accept WM_CLOSE")
	Started := A_TickCount
	while _PersonalEditorSessionEpoch == Owned.Epoch && A_TickCount - Started < 1000
		Sleep(10)
	AssertTrue(_PersonalEditorSessionEpoch > Owned.Epoch, "the real Close event must revoke the opening epoch")
	AssertFalse(_PersonalTomlOpeningSessionCurrent(Owned.Source), "the closed window must lose source authority")
	; Observe native destruction before fixture cleanup can destroy anything.
	_TestPrint("# personal-editor-window-close hwnd=" . Owned.Hwnd
		. " window_exists=" . DllCall("User32\IsWindow", "Ptr", Owned.Hwnd, "Int")
		. " visible=" . DllCall("User32\IsWindowVisible", "Ptr", Owned.Hwnd, "Int"))
	AssertFalse(DllCall("User32\IsWindow", "Ptr", Owned.Hwnd, "Int"),
		"public native Close must destroy its window, rather than abandon a hidden owner")
	for Hwnd in Owned.Controls
		AssertFalse(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "retirement must destroy every original control")
}

_PENR_Case(Mode) {
	SavedCritical := A_IsCritical, SavedSuspend := A_IsSuspended
	try _PENR_CaseOwned(Mode)
	finally {
		Suspend(SavedSuspend)
		Critical(SavedCritical)
	}
}

_PENR_CaseOwned(Mode) {
	global ScriptInformation, ConfigurationFile, _VendorDir, _HsEdWeb_Gui
	global _PersonalEditorData, _PersonalEditorSection, _PersonalEditorOpeningSource
	global _PersonalEditorGui, _PersonalEditorSessionEpoch, _PersonalEditorPrioCtrl
	global _ReadPersonalTomlCache, _PersonalTomlReadGeneration, _HS_GrandTotalCache
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache, _TomlUnreadableFiles, _TomlReadFailures
	AssertFalse(IsObject(_PersonalEditorGui), "this fixture must not adopt a foreign native editor")
	AssertFalse(IsObject(_HsEdWeb_Gui), "this fixture must not adopt a foreign web editor")
	Saved := { Path: ScriptInformation["PersonalTomlPath"], Config: ConfigurationFile, Vendor: _VendorDir,
		Data: _PersonalEditorData, Section: _PersonalEditorSection, Source: _PersonalEditorOpeningSource,
		Window: _PersonalEditorGui, Epoch: _PersonalEditorSessionEpoch, Priority: _PersonalEditorPrioCtrl,
		ReadCache: _ReadPersonalTomlCache, ReadGeneration: _PersonalTomlReadGeneration,
		Snapshots: _ConfigTomlSnapshots, Parsed: _ParseTomlCache, Files: _TomlFileCache,
		Unreadable: _TomlUnreadableFiles, Failures: _TomlReadFailures, HasTotal: IsSet(_HS_GrandTotalCache) }
	if Saved.HasTotal
		Saved.Total := _HS_GrandTotalCache
	Fixture := 0, State := { Windows: [] }, Primary := 0, CleanupFailure := 0
	try {
		Critical("Off"), Suspend(false)
		_ConfigTomlSnapshots := Saved.Snapshots.Clone(), _ParseTomlCache := Saved.Parsed.Clone()
		_TomlFileCache := Saved.Files.Clone(), _TomlUnreadableFiles := Saved.Unreadable.Clone()
		_TomlReadFailures := Saved.Failures.Clone()
		Fixture := _ScopeOwnerFixture()
		ConfigurationFile := Fixture.path
		ScriptInformation["PersonalTomlPath"] := Fixture.directory . "\personal.toml"
		_VendorDir := Fixture.directory . "\unavailable-browser"
		AssertFalse(_HsEdWeb_Available(), "a genuinely absent loader must select the real native fallback")
		Source := '[_meta]`nsections_order = ["alpha"]`n'
			. '[_meta.sections.alpha]`ndescription = "Private alpha"`n'
			. '[[alpha]]`n"private_alpha" = { output = "Private output", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		AssertTrue(FSWriteDurable(ScriptInformation["PersonalTomlPath"], Source))
		Cycles := Mode == "current" ? 1 : 3
		loop Cycles {
			Owned := _PENR_Open(State)
			if Mode != "current"
				_PENR_Close(Owned)
		}
		AssertTrue(FSUtf8ExactMatches(ScriptInformation["PersonalTomlPath"], Source), "opening and closing must preserve the actual personal source")
		AssertTrue(FSUtf8ExactMatches(Fixture.path, Fixture.source), "native Close must not rewrite configuration preferences")
	} catch as Failure {
		Primary := Failure
	} finally {
		; Retire only windows acquired by this fixture, including a hidden owner
		; that the product left behind. Assertions above precede this safety net.
		for Owned in State.Windows {
			try {
				try {
					if _PersonalEditorGui == Owned.Window
						_OnEditorClose(Owned.Window, Owned.Epoch)
				} finally Owned.Window.Destroy()
			} catch as Failure {
				if !IsObject(CleanupFailure)
					CleanupFailure := Failure
			}
		}
		_PersonalEditorData := Saved.Data, _PersonalEditorSection := Saved.Section
		_PersonalEditorOpeningSource := Saved.Source, _PersonalEditorGui := Saved.Window
		_PersonalEditorSessionEpoch := Saved.Epoch, _PersonalEditorPrioCtrl := Saved.Priority
		_ReadPersonalTomlCache := Saved.ReadCache, _PersonalTomlReadGeneration := Saved.ReadGeneration
		_HS_GrandTotalCache := Saved.HasTotal ? Saved.Total : unset
		_ConfigTomlSnapshots := Saved.Snapshots, _ParseTomlCache := Saved.Parsed
		_TomlFileCache := Saved.Files, _TomlUnreadableFiles := Saved.Unreadable
		_TomlReadFailures := Saved.Failures
		ScriptInformation["PersonalTomlPath"] := Saved.Path, ConfigurationFile := Saved.Config
		_VendorDir := Saved.Vendor
		if IsObject(Fixture) {
			try _ScopeOwnerCleanup(Fixture)
			catch as Failure {
				if !IsObject(CleanupFailure)
					CleanupFailure := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

Test("Personal native window: current public editor accepts actual selection (personal-editor-window-retirement)",
	_PENR_Case.Bind("current"))
Test("Personal native window: repeated public Close destroys every owner (personal-editor-window-retirement)",
	_PENR_Case.Bind("close-reopen"))
