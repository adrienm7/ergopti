; tests/fixtures/metrics/wpm_graph_native_reentry_body.ahk
#Requires AutoHotkey v2.0
_WPMG_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_WPMG_Store(Key, Value) => true
_WPMG_Rebuild() => true
_WPMG_Notify(*) => 0
_WPMG_DestroyControl(State, This, Args*) {
	if This == State.Old && !State.Refused {
		State.Refused := true
		if State.Mode == "destroy-after"
			State.RealDestroy.Call(This, Args*)
		throw Error("private fixture injected destroy refusal")
	}
	return State.RealDestroy.Call(This, Args*)
}
_WPMG_WindowProc(State, Hwnd, Message, WParam, LParam, Id, Data) {
	State.Active += 1
	try {
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message, "Ptr", WParam, "Ptr", LParam, "Ptr")
		if State.Armed && !State.Seen && Hwnd == State.OldHwnd && Message == 2 {
			State.Seen := true
			if State.Mode == "hide-during-destroy" {
				WPMWidget_Hide()
				State.NewHide := true
			} else if State.Mode == "reopen" {
				WPMWidget_Show()
				State.Successor := WPMWidget._graph_gui
				if State.Successor is Gui {
					State.SuccessorHwnd := State.Successor.Hwnd
					State.Before := !!DllCall("IsWindow", "Ptr", State.SuccessorHwnd, "Int")
				}
			}
		}
		return Result
	} catch Any as Failure {
		State.Failure := Failure
		return 0
	} finally State.Active -= 1
}
_WPMG_Main() {
	global ConfigurationFile, Features, STORAGE_REG_BASE
	_WPMG_Require(A_Args.Length == 2 && (A_Args[1] == "current" || A_Args[1] == "reopen" || A_Args[1] == "destroy-before" || A_Args[1] == "destroy-after" || A_Args[1] == "hide-during-destroy"), "private test mode and root are required")
	State := {Mode: A_Args[1], Armed: false, Seen: false, Active: 0, Failure: 0,
		Old: 0, OldHwnd: 0, Proc: 0, Installed: false, Successor: 0, SuccessorHwnd: 0, Before: false, Refused: false, RealDestroy: 0, NewHide: false}
	DestroyDescriptor := Gui.Prototype.GetOwnPropDesc("Destroy"), State.RealDestroy := DestroyDescriptor.Call
	try {
		Creation := FSCreateDirectoryExclusiveStrict(A_Args[2] . "\config")
		_WPMG_Require(Creation is Integer && Creation == 1, "the private configuration directory must be exclusively owned")
		ConfigurationFile := A_Args[2] . "\config\config.toml"
		Content := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[metrics]`nwpm_widget_graph = false`n"
		_WPMG_Require(FSWriteCreateDurable(ConfigurationFile, Content), "the private source must be created exclusively")
		Boot := ConfigMigrateBoot(ConfigurationFile)
		_WPMG_Require(Boot["status"] == "current" && Boot["read_only"] == 0, "the real boot must admit the source")
		Features := ManifestBuildFeaturesMap()
		_WPMG_Require(ApplyBootConfigToml(Features, ConfigurationFile, &Snapshot) >= 0 && ConfigFullStateCanPersist(),
			"the real boot must admit complete configuration state")
		if !IsSet(STORAGE_REG_BASE)
			STORAGE_REG_BASE := "fixture-not-used"
		WPMWidgetConst.STORE_PAIR := "fixture-pair"
		WPMWidget.show_graph := false, WPMWidget.visible := false, WPMWidget.pos_x := 200, WPMWidget.pos_y := 300
		State.Old := WPMWidget_BuildCompact(), State.OldHwnd := State.Old.Hwnd
		_WPMWidget_ApplySurfaceGeometry(State.Old)
		WPMWidget.visible := true
		_WPMG_Require(DllCall("IsWindow", "Ptr", State.OldHwnd, "Int") && WPMWidget._gui == State.Old,
			"the real compact constructor must publish its own actual native HWND")
		Pid := 0
		_WPMG_Require(DllCall("GetWindowThreadProcessId", "Ptr", State.OldHwnd, "UInt*", &Pid, "UInt") && Pid == ProcessExist(),
			"the native callback must target the exact child-owned compact window")
		State.Proc := CallbackCreate(_WPMG_WindowProc.Bind(State), , 6)
		_WPMG_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", State.OldHwnd, "Ptr", State.Proc,
			"UPtr", 0x57504D47, "UPtr", 0, "Int"), "the compact HWND must own its destruction observer")
		State.Installed := true, State.Armed := true
		if InStr(State.Mode, "destroy-") == 1
			Gui.Prototype.DefineProp("Destroy", {Call: _WPMG_DestroyControl.Bind(State)})
		Result := _ToggleWpmWidgetGraph(0, _WPMG_Notify, 0, 0, _WPMG_Rebuild, _WPMG_Store)
		if InStr(State.Mode, "destroy-") == 1 {
			AliveBeforeRetry := !!DllCall("IsWindow", "Ptr", State.OldHwnd, "Int")
			DebtBeforeRetry := _METWpmRetiredSurfaces.pending.Length
			FileAppend("OBSERVATION wpm-graph-destroy mode=" . State.Mode . " refused=" . State.Refused
				. " old_alive=" . AliveBeforeRetry . " debt=" . DebtBeforeRetry . "`n", "*")
			_WPMG_Require(State.Refused && (State.Mode == "destroy-before" ? (AliveBeforeRetry && DebtBeforeRetry == 1)
				: (!AliveBeforeRetry && DebtBeforeRetry == 0)), "failed Destroy must keep exact live custody and recognize actual destruction")
			Gui.Prototype.DefineProp("Destroy", DestroyDescriptor)
			_MET_WpmRetirePending()
			_WPMG_Require(!_METWpmRetiredSurfaces.pending.Length
				&& !DllCall("IsWindow", "Ptr", State.OldHwnd, "Int"), "exact old native owner must retire on retry")
		}
		State.Armed := false
		Current := WPMWidget._graph_gui
		After := State.Successor is Gui && Current == State.Successor
			&& DllCall("IsWindow", "Ptr", State.SuccessorHwnd, "Int")
		FileAppend("OBSERVATION wpm-graph-native mode=" . State.Mode . " result=" . Result . " destroy_seen=" . State.Seen
			. " before=" . State.Before . " after=" . After . " successor_alive="
			. (State.SuccessorHwnd ? DllCall("IsWindow", "Ptr", State.SuccessorHwnd, "Int") : 0)
			. " graph=" . WPMWidget.show_graph . " visible=" . WPMWidget.visible . " newer_hide=" . State.NewHide . " callback_failed=" . IsObject(State.Failure) . "`n", "*")
		if IsObject(State.Failure)
			throw State.Failure
		if State.Mode == "hide-during-destroy"
			_WPMG_Require(State.Seen && State.NewHide && Result is Integer && Result == 1
				&& WPMWidget.show_graph && !WPMWidget.visible && !IsObject(Current),
				"the newer public Hide during native destruction must remain in force")
		else
			_WPMG_Require(State.Seen && Result is Integer && Result == 1 && WPMWidget.show_graph && Current is Gui
				&& DllCall("IsWindow", "Ptr", Current.Hwnd, "Int"), "the real graph toggle must commit and retain an actual graph surface")
		if State.Mode == "reopen"
			_WPMG_Require(State.Seen && State.Before && After, "the old toggle cannot destroy the exact newer graph surface")
	} finally {
		Gui.Prototype.DefineProp("Destroy", DestroyDescriptor)
		State.Armed := false
		WPMWidget_Hide()
		Removed := !State.Installed || !DllCall("IsWindow", "Ptr", State.OldHwnd, "Int")
		if !Removed
			Removed := !!DllCall("Comctl32\RemoveWindowSubclass", "Ptr", State.OldHwnd, "Ptr", State.Proc, "UPtr", 0x57504D47, "Int")
		if Removed && !State.Active && State.Proc
			CallbackFree(State.Proc)
		for Window in [State.Old, State.Successor, WPMWidget._gui, WPMWidget._graph_gui]
			if Window is Gui
				try Window.Destroy()
		_WPMG_Require(Removed && !State.Active, "the exact native callback must retire before child exit")
	}
	FileAppend("PASS wpm-graph-native " . State.Mode . "`n", "*")
}
try _WPMG_Main()
catch Any as _WPMG_ChildFailure {
	FileAppend("FAIL wpm-graph-native " . _WPMG_ChildFailure.Message . " [" . _WPMG_ChildFailure.File . ":" . _WPMG_ChildFailure.Line . "]`n", "*")
	ExitApp(1)
}
ExitApp(0)
