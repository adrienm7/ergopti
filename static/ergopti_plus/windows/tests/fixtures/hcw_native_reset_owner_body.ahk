; tests/fixtures/hcw_native_reset_owner_body.ahk

; ==============================================================================
; MODULE: Native Hotstrings Reset Owned Child
; DESCRIPTION:
; Actual reset button and durable override writers run inside a real coalescing
; coordinator. Its external worker refuses publication; registry/tray are absent.
; The logger is genuine; its existing sink observes a durable clear and pumps a
; native close/reopen actor. No old completion is manually called or rewritten.
; ==============================================================================

#Requires AutoHotkey v2.0

; Labels are a declared passive presentation port, as in the startup component.
t(Key) => Key

_HNRC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_HNRC_Fail(Failure) {
	global _HNRC
	if !IsObject(_HNRC.Failure)
		_HNRC.Failure := Failure
}

_HNRC_OnError(Failure, Mode) {
	_HNRC_Fail(Failure)
	return true
}

_HNRC_Visible(Hwnd) => DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
	&& DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int")

_HNRC_Entry(*) {
	global _HNRC
	; Inserted passive observer runs before the real registered Reset callback.
	; It returns no value and never invokes/replaces that callback.
	_HNRC.ClickEntries += 1
}

_HNRC_Click() {
	global _HNRC
	try {
		_HNRC.ClickSends += 1
		_HNRC_Require(_HNRC_Visible(_HNRC.AHwnd), "The genuine button command must address visible A")
		DllCall("User32\SendMessageW", "Ptr", _HNRC.Button.Hwnd, "UInt", 0xF5, "UPtr", 0, "Ptr", 0, "Ptr")
	} catch Any as Failure
		_HNRC_Fail(Failure)
}

_HNRC_Actor() {
	global _HNRC, _HCWGui, _HCWWidgets, _HCW_PendingNumericWrites, _HCW_NumericDrainActive
	try {
		_HNRC.ActorCalls += 1
		_HNRC_Require(_HNRC.ActorCalls == 1 && _HNRC.ClickEntries == 1
			&& _HCWGui == _HNRC.A && _HCW_PendingNumericWrites.Length == 0 && !_HCW_NumericDrainActive,
			"The native close actor must own the exact current A without pending numeric writes")
		DllCall("User32\SendMessageW", "Ptr", _HNRC.AHwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while (_HCWGui != 0 || _HNRC_Visible(_HNRC.AHwnd)) && TickElapsed(Started) < 1000
			Sleep(10)
		_HNRC.AClosed := _HCWGui == 0 && _HCWWidgets == 0 && !_HNRC_Visible(_HNRC.AHwnd)
		_HNRC_Require(_HNRC.AClosed, "The real Close callback and native default Hide must retire A before reopen")
		OpenHotstringsConfigWindow()
		_HNRC.B := _HCWGui
		_HNRC_Require(_HNRC.B is Gui, "A real public reopen must publish B")
		_HNRC.BHwnd := _HNRC.B.Hwnd, _HNRC.BWidgets := _HCWWidgets
		_HNRC.BeforeB := _HNRC.B != _HNRC.A && _HNRC_Visible(_HNRC.BHwnd)
			&& _HCWWidgets.Gui == _HNRC.B && DllCall("User32\IsWindow", "Ptr", _HCWWidgets.DelayEdit.Hwnd, "Int")
		_HNRC_Require(_HNRC.BeforeB, "Distinct B and its actual native widgets must be usable before old completion")
	} catch Any as Failure {
		_HNRC_Fail(Failure)
	} finally {
		_HNRC.ActorDone := true
	}
}

_HNRC_Log(Line) {
	global _HNRC, _HSLR_Active, HSE_RebuildInProgress
	try {
		ExpectedFault := _HNRC_FaultMode() && _HNRC.FaultInjected
			&& InStr(Line, "[WARNING] [HotstringsConfigWindow] Native reset retirement remains pending (error_type=Error).")
		if ExpectedFault
			_HNRC.FaultWarnings += 1
		else if InStr(Line, "[ERROR]") || InStr(Line, "[WARNING]")
			_HNRC.Errors.Push(Line)
		if !_HNRC.Running || !InStr(Line, "[DEBUG] [HotstringsConfig] Override cleared:")
			return
		_HNRC.ClearLogs += 1
		_HNRC_Require(_HSLR_Active && HSE_RebuildInProgress && _HNRC.ClickEntries == 1,
			"The actual durable clear must be inside the old native reset and live coordinator")
		if _HNRC.Mode != "reopen" || _HNRC.ActorArmed
			return
		_HNRC.ActorArmed := true
		SetTimer(_HNRC_Actor, -1)
		Started := A_TickCount
		while !_HNRC.ActorDone && TickElapsed(Started) < 2000
			Sleep(10)
		_HNRC_Require(_HNRC.ActorDone, "The real close/reopen timer must complete while the writer logger is suspended")
	} catch Any as Failure
		_HNRC_Fail(Failure)
}

_HNRC_Worker() {
	global _HNRC, _HSLR_Active, HSE_RebuildInProgress
	_HNRC.WorkerCalls += 1
	_HNRC_Require(_HSLR_Active && HSE_RebuildInProgress, "The genuine coordinator must own this refused work port")
	if _HNRC.WorkerCalls == 1 {
		SetTimer(_HNRC_Click, -1)
		Started := A_TickCount
		while _HNRC.ClickEntries == 0 && !IsObject(_HNRC.Failure) && TickElapsed(Started) < 5000
			Sleep(10)
		_HNRC_Require(_HNRC.ClickEntries == 1, "One native button event must run its actual registered reset")
	}
	; Explicit refusal, never a fake success for omitted registry/tray work.
	return false
}

_HNRC_DestroyProc(Hwnd, Message, WParam, LParam, Id, Data) {
	global _HNRC, _HCWGui, _HCWWidgets
	_HNRC.DestroyActive += 1
	try {
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message, "Ptr", WParam, "Ptr", LParam, "Ptr")
		if !_HNRC.Running || _HNRC.DestroySeen || Hwnd != _HNRC.AHwnd || Message != 0x2
			return Result
		_HNRC.DestroySeen := true
		if _HNRC.Mode == "destroy-reopen" || _HNRC_FaultMode() {
			_HNRC.ReopenCalls += 1
			try {
				OpenHotstringsConfigWindow()
				_HNRC.B := _HCWGui
				if _HNRC.B is Gui {
					_HNRC.BHwnd := _HNRC.B.Hwnd, _HNRC.BWidgets := _HCWWidgets
					_HNRC.BeforeB := _HNRC.B != _HNRC.A && _HNRC_Visible(_HNRC.BHwnd)
						&& IsObject(_HCWWidgets) && _HCWWidgets.Gui == _HNRC.B
				}
			} catch Any as Failure
				_HNRC.ReopenFailure := Failure
		}
		return Result
	} catch Any as Failure {
		_HNRC_Fail(Failure)
		return 0
	} finally _HNRC.DestroyActive -= 1
}

_HNRC_Run() {
	global _HNRC, ConfigurationFile, ScriptInformation, _VendorDir, _ExtensionsDir
	global _HCWGui, _HCWWidgets, _HCW_PendingNumericWrites, _HCW_NumericDrainActive
	global _HSLR_Active, _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, HSE_RebuildInProgress
	Root := A_Args[2]
	ConfigurationFile := Root . "\config\config.toml"
	_HNRC_Require(FSWriteCreateDurable(ConfigurationFile, "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n"),
		"The private current-schema config is created durably")
	Boot := ConfigMigrateBoot(ConfigurationFile)
	_HNRC_Require(Boot["status"] == "current" && Boot["read_only"] == 0, "The actual boot reader must admit the private current source")
	ScriptInformation["PersonalHotstringsDir"] := Root . "\personal\"
	_VendorDir := Root . "\vendor", _ExtensionsDir := Root . "\extensions"
	_HNRC_Require(!FileExist(_VendorDir . "\64bit\WebView2Loader.dll") && !_HCWWeb_Available(),
		"The real runtime availability branch must select native fallback without a browser stub")
	HotstringsConfigLoadSharedDefaults()
	_HNRC.OverridePath := Root . "\config\hotstrings_config.toml"
	HotstringsConfigInit(_HNRC.OverridePath)
	_HNRC_Require(HotstringsCommonOverrideAdmitted() == true, "The real override migration owner must admit this private source")
	_HNRC_Require(HotstringsSetOverride("magickey", "", "delay", 0.321), "A real native writer must affirmatively seed the reset")
	Seed := TOML_ParseDocument(FSReadUtf8Exact(_HNRC.OverridePath))
	_HNRC_Require(Seed["magickey"]["delay_offset"] == Round(0.321 - HotstringsBaseDelay(), 3),
		"Independent native decode must confirm the durable override, stored as an offset of the base delay")
	_HNRC.SeedHash := CryptoSha256Bytes(FSReadBytesStrict(_HNRC.OverridePath))
	OpenHotstringsConfigWindow()
	_HNRC.A := _HCWGui, _HNRC.AHwnd := _HCWGui.Hwnd
	_HNRC_Require(_HNRC.A is Gui && _HNRC_Visible(_HNRC.AHwnd) && _HCWWidgets.Gui == _HNRC.A,
		"The actual public fallback must publish visible native A and real widgets")
	_HNRC_Require(_HCW_PendingNumericWrites.Length == 0 && !_HCW_NumericDrainActive && !_HSLR_Active,
		"No numeric candidate or live rebuild may predate this component")
	if InStr(_HNRC.Mode, "numeric-") == 1 {
		_HNRC_NumericRun()
		return
	}
	Found := 0
	for Control in _HNRC.A {
		if Control.Type == "Button" && Control.Text == t("hs_config.btn_reset_all") {
			Found += 1
			_HNRC.Button := Control
		}
	}
	_HNRC_Require(Found == 1, "The actual native reset button must be uniquely identified")
	if InStr(_HNRC.Mode, "destroy-") == 1 || _HNRC_FaultMode() {
		_HNRC_Require(WinGetPID("ahk_id " . _HNRC.AHwnd) == ProcessExist(), "The native destruction witness must target this exact child")
		_HNRC.DestroyProc := CallbackCreate(_HNRC_DestroyProc, , 6)
		_HNRC_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", _HNRC.AHwnd, "Ptr", _HNRC.DestroyProc,
			"UPtr", 0x484E5244, "UPtr", 0, "Int"), "The actual current GUI must admit its exact destruction witness")
		_HNRC.DestroyInstalled := true
	}
	if _HNRC_FaultMode()
		_HNRC_InstallDestroyFault()
	_HNRC.Button.OnEvent("Click", _HNRC_Entry, -1)
	_HNRC.Running := true
	Result := RebuildHotstringsLive(_HNRC_Worker)
	_HNRC.Running := false
	if IsObject(_HNRC.Failure)
		throw _HNRC.Failure
	_HNRC_Require((Result is Integer) && Result == false && !_HSLR_Active && !HSE_RebuildInProgress,
		"The real coordinator must finish with the external worker refused and its ownership released")
	_HNRC_Require(_HNRC.ClickSends == 1 && _HNRC.ClickEntries == 1 && _HNRC.ClearLogs > 0
		&& (InStr(_HNRC.Mode, "destroy-") == 1 || _HNRC.Errors.Length == 0),
		"The native event and genuine durable clear logs must be reached without contained prerequisites")
	Final := TOML_ParseDocument(FSReadUtf8Exact(_HNRC.OverridePath))
	FinalHash := CryptoSha256Bytes(FSReadBytesStrict(_HNRC.OverridePath))
	Cleared := !Final.Has("magickey") || !Final["magickey"].Has("delay_offset")
	AfterB := (_HNRC.Mode == "reopen" || _HNRC.Mode == "destroy-reopen") && _HCWGui == _HNRC.B && _HNRC_Visible(_HNRC.BHwnd)
		&& IsObject(_HCWWidgets) && _HCWWidgets.Gui == _HNRC.B
		&& DllCall("User32\IsWindow", "Ptr", _HCWWidgets.DelayEdit.Hwnd, "Int")
	FileAppend("RECEIPT hcw-native-reset-owner mode=" . _HNRC.Mode . " click_sends=" . _HNRC.ClickSends
		. " click_entries=" . _HNRC.ClickEntries . " clear_logs=" . _HNRC.ClearLogs . " worker_calls=" . _HNRC.WorkerCalls
		. " requested=" . _HSLR_RequestedGeneration . " published=" . _HSLR_PublishedGeneration
		. " actor_calls=" . _HNRC.ActorCalls . " a_closed=" . _HNRC.AClosed . " before_b=" . _HNRC.BeforeB
		. " after_b=" . AfterB . " after_b_live=" . DllCall("User32\IsWindow", "Ptr", _HNRC.BHwnd, "Int")
		. " cleared=" . Cleared . " seed_sha=" . _HNRC.SeedHash . " final_sha=" . FinalHash
		. " registry_worker=Refused tray_render=Absent browser=Absent`n", "*", "UTF-8-RAW")
	_HNRC_Require(Cleared && FinalHash != _HNRC.SeedHash && !IsObject(_ConfigWriteLeaseCurrent(_HNRC.OverridePath))
		&& !_ConfigPublicationHasRecoveryDebt(_HNRC.OverridePath), "The real reset must durably clear the source and release its exact writer")
	if _HNRC_FaultMode() {
		_HNRC_CheckRetirementFault(FinalHash)
		return
	}
	if InStr(_HNRC.Mode, "destroy-") == 1 {
		FileAppend("OBSERVATION hcw-native-destroy mode=" . _HNRC.Mode . " destroy_seen=" . _HNRC.DestroySeen
			. " reopen_calls=" . _HNRC.ReopenCalls . " before_b=" . _HNRC.BeforeB . " after_b=" . AfterB
			. " reopen_threw=" . IsObject(_HNRC.ReopenFailure) . " errors=" . _HNRC.Errors.Length
			. " old_alive=" . DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int") . "`n", "*", "UTF-8-RAW")
		if IsObject(_HNRC.ReopenFailure)
			FileAppend("DIAGNOSTIC hcw-native-destroy reopen_type=" . Type(_HNRC.ReopenFailure)
				. " reopen_message=" . JsonStringLiteral(_HNRC.ReopenFailure.Message) . "`n", "*", "UTF-8-RAW")
		for Index, Line in _HNRC.Errors
			FileAppend("DIAGNOSTIC hcw-native-destroy error_index=" . Index . " logger_error=" . JsonStringLiteral(Line) . "`n", "*", "UTF-8-RAW")
		_HNRC_Require(_HNRC.DestroySeen && _HNRC.Errors.Length == 0 && !DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int"),
			"The actual reset completion must destroy A without technical errors")
		if _HNRC.Mode == "destroy-reopen"
			_HNRC_Require(_HNRC.ReopenCalls == 1 && !IsObject(_HNRC.ReopenFailure) && _HNRC.BeforeB && AfterB,
				"The actual public reopen during native Destroy must create and preserve usable B and its widgets")
		else
			_HNRC_Require(_HCWGui == 0 && _HCWWidgets == 0 && _HNRC.ReopenCalls == 0,
				"The unopposed reset destruction must still retire the exact native window and controls")
	} else if _HNRC.Mode == "current" {
		_HNRC_Require(_HSLR_RequestedGeneration >= 2 && _HNRC.WorkerCalls >= 2,
			"The affirmative current reset must really coalesce its default rebuild request")
		_HNRC_Require(_HCWGui == 0 && _HCWWidgets == 0 && !DllCall("User32\IsWindow", "Ptr", _HNRC.AHwnd, "Int"),
			"The affirmative reset must retire its actual current native window")
	} else {
		_HNRC_Require(_HNRC.ActorCalls == 1 && _HNRC.AClosed && _HNRC.BeforeB,
			"Real Close A and independent public B admission must precede the old completion")
		_HNRC_Require(AfterB, "Old native reset completion must preserve the independently reopened B")
	}
}


; Passive subscribers bracket the already-registered production Change handler.
; No function Call property or production callback is replaced/invoked manually.
_HNRC_NumericBefore(Control, *) {
	global _HNRC
	if Control.Hwnd == _HNRC.NumericHwnd && Control.Text == _HNRC.NumericText
		_HNRC.NumericBefore += 1
}
_HNRC_NumericAfter(Control, *) {
	global _HNRC
	if Control.Hwnd == _HNRC.NumericHwnd && Control.Text == _HNRC.NumericText
		_HNRC.NumericAfter += 1
}
_HNRC_NumericInput() {
	global _HNRC, _HCW_PendingNumericWrites, _HCW_NumericDrainActive, _HCW_NUMERIC_DEBOUNCE_MS
	try {
		_HNRC.NumericInputs += 1
		NativePid := 0
		_HNRC_Require(_HNRC.NumericInputs == 1
			&& DllCall("User32\GetWindowThreadProcessId", "Ptr", _HNRC.NumericHwnd, "UInt*", &NativePid, "UInt")
			&& NativePid == ProcessExist() && WinGetClass("ahk_id " . _HNRC.NumericHwnd) == "Edit",
			"Only the exact child-owned native Edit may receive this one WM_CHAR edit")
		_HNRC.NumericEdit.Focus()
		_HNRC_Require(DllCall("User32\GetFocus", "Ptr") == _HNRC.NumericHwnd,
			"The actual numeric Edit must own native focus before editing")
		DllCall("User32\SendMessageW", "Ptr", _HNRC.NumericHwnd, "UInt", 0xB1, "Ptr", 0, "Ptr", -1, "Ptr")
		if _HNRC.NumericEmpty
			DllCall("User32\SendMessageW", "Ptr", _HNRC.NumericHwnd, "UInt", 0x102, "UPtr", 0x08, "Ptr", 1, "Ptr")
		else {
			for Character in StrSplit(_HNRC.NumericText)
				DllCall("User32\SendMessageW", "Ptr", _HNRC.NumericHwnd, "UInt", 0x102, "UPtr", Ord(Character), "Ptr", 1, "Ptr")
		}
		_HNRC.RawNumericText := _HNRC.NumericEdit.Text
		Started := A_TickCount
		; Wait through a real debounce interval even if empty text queued nothing.
		; An OnError capture cannot hide a subsequently persisted false zero.
		while TickElapsed(Started) < 5000 {
			if TickElapsed(Started) >= _HCW_NUMERIC_DEBOUNCE_MS + 150
				&& _HNRC.NumericBefore > 0 && _HCW_PendingNumericWrites.Length == 0 && !_HCW_NumericDrainActive
				break
			Sleep(10)
		}
		_HNRC.NumericDrained := TickElapsed(Started) >= _HCW_NUMERIC_DEBOUNCE_MS + 150
			&& _HCW_PendingNumericWrites.Length == 0 && !_HCW_NumericDrainActive
	} catch Any as Failure {
		_HNRC_Fail(Failure)
	} finally _HNRC.NumericDone := true
}
_HNRC_NumericWorker() {
	global _HNRC, _HSLR_Active, HSE_RebuildInProgress
	_HNRC_Require(_HSLR_Active && HSE_RebuildInProgress,
		"The genuine coordinator must own this explicitly refused external registry/tray work")
	_HNRC.WorkerCalls += 1
	if _HNRC.WorkerCalls == 1 {
		SetTimer(_HNRC_NumericInput, -1)
		Started := A_TickCount
		while !_HNRC.NumericDone && TickElapsed(Started) < 7000
			Sleep(10)
		_HNRC_Require(_HNRC.NumericDone, "The actual native edit and debounce observation must settle before this worker returns")
	}
	return false
}
_HNRC_NumericRun() {
	global _HNRC, _HCWWidgets, _HSLR_Active, HSE_RebuildInProgress
	global _HCW_PendingNumericWrites, _HCW_NumericDrainActive
	Entry := _HCW_SelectedEntry(), Section := _HCW_SelectedSection(Entry)
	_HNRC_Require(!Entry.IsPersonal && !Entry.IsExtension && !Entry.IsVirtual && Entry.Key != "",
		"The real initial selection must use the common override writer, not a virtual/config or personal backend")
	; Both initial values are nonzero through the real source-admitted writer.
	_HNRC_Require(HotstringsSetOverride(Entry.Key, Section, "delay", 0.321)
		&& HotstringsSetOverride(Entry.Key, Section, "priority", 47),
		"The private selected record must acquire genuine positive durable values before native editing")
	_HCW_LoadCurrent()
	_HNRC_Require(_HCW_PendingNumericWrites.Length == 0 && !_HCW_NumericDrainActive,
		"Refreshing actual controls must leave no pre-existing numeric candidate")
	_HNRC.NumericEmpty := _HNRC.Mode == "numeric-empty-delay" || _HNRC.Mode == "numeric-empty-priority"
	_HNRC.NumericField := _HNRC.Mode == "numeric-empty-priority" ? "priority" : "delay"
	_HNRC.NumericEdit := _HNRC.NumericField == "priority" ? _HCWWidgets.PriorityEdit : _HCWWidgets.DelayEdit
	_HNRC.NumericHwnd := _HNRC.NumericEdit.Hwnd
	_HNRC.NumericText := _HNRC.NumericEmpty ? "" : (_HNRC.Mode == "numeric-current" ? "3" : "18446744073709551619")
	_HNRC_Require(_HNRC.NumericEdit.Text != ""
		&& (DllCall("User32\GetWindowLongW", "Ptr", _HNRC.NumericHwnd, "Int", -16, "Int") & 0x2000),
		"The actual nonempty native Edit must expose the shipped ES_NUMBER style")
	Before := FSReadBytesStrict(_HNRC.OverridePath), BeforeHash := CryptoSha256Bytes(Before)
	BeforeResolved := HotstringsResolve(Entry.Key, Section)
	_HNRC_Require(Abs(BeforeResolved.Delay - 0.321) < 0.000000001 && BeforeResolved.Priority == 47,
		"The initial live projection must match both genuine seeded durable values")
	_HNRC.NumericEdit.OnEvent("Change", _HNRC_NumericBefore, -1)
	_HNRC.NumericEdit.OnEvent("Change", _HNRC_NumericAfter)
	try Result := RebuildHotstringsLive(_HNRC_NumericWorker)
	finally {
		_HNRC.NumericEdit.OnEvent("Change", _HNRC_NumericBefore, 0)
		_HNRC.NumericEdit.OnEvent("Change", _HNRC_NumericAfter, 0)
	}
	FinalHash := CryptoSha256Bytes(FSReadBytesStrict(_HNRC.OverridePath))
	FinalDocument := TOML_ParseDocument(FSReadUtf8Exact(_HNRC.OverridePath))
	FinalResolved := HotstringsResolve(Entry.Key, Section)
	Node := FinalDocument.Get(Entry.Key, Map())
	if Section != ""
		Node := Node.Get(Section, Map())
	Offset := Node.Get("delay_offset", "absent")
	WrappedDurable := Offset is Number && Abs((HotstringsBaseDelay() + Offset) - 0.003) < 0.000000001
	FileAppend("OBSERVATION hcw-native-numeric mode=" . _HNRC.Mode . " field=" . _HNRC.NumericField
		. " backend=common key=" . JsonStringLiteral(Entry.Key) . " section=" . JsonStringLiteral(Section)
		. " class=" . WinGetClass("ahk_id " . _HNRC.NumericHwnd)
		. " input_calls=" . _HNRC.NumericInputs . " before_change=" . _HNRC.NumericBefore . " after_change=" . _HNRC.NumericAfter
		. " raw_text=" . JsonStringLiteral(_HNRC.RawNumericText) . " drained=" . _HNRC.NumericDrained
		. " errors=" . _HNRC.Errors.Length . " async_failure=" . IsObject(_HNRC.Failure)
		. " before_delay=" . BeforeResolved.Delay . " final_delay=" . FinalResolved.Delay
		. " before_priority=" . BeforeResolved.Priority . " final_priority=" . FinalResolved.Priority
		. " wrapped_durable=" . WrappedDurable . " unlimited=" . Node.Get("delay_unlimited", false)
		. " bytes_changed=" . (BeforeHash != FinalHash) . "`n", "*", "UTF-8-RAW")
	_HNRC_Require(_HNRC.NumericInputs == 1 && _HNRC.NumericBefore > 0 && _HNRC.NumericDrained
		&& _HNRC.RawNumericText == _HNRC.NumericText && Result is Integer && Result == false
		&& !_HSLR_Active && !HSE_RebuildInProgress,
		"The real native Edit, registered Change event, debounce interval and actual coordinator must all be observed")
	if IsObject(_HNRC.Failure)
		throw _HNRC.Failure
	_HNRC_Require(_HNRC.NumericAfter > 0, "The production Change handler must return to its passive following subscriber")
	if _HNRC.Mode == "numeric-current"
		_HNRC_Require(_HNRC.Errors.Length == 0 && WrappedDurable && Abs(FinalResolved.Delay - 0.003) < 0.000000001
			&& FinalResolved.Priority == 47 && BeforeHash != FinalHash,
			"Ordinary 3ms input must still reach the real durable override writer without changing another field")
	else if _HNRC.NumericEmpty
		_HNRC_Require(_HNRC.Errors.Length == 0 && BeforeHash == FinalHash
			&& FinalResolved.Delay == BeforeResolved.Delay && FinalResolved.Priority == BeforeResolved.Priority,
			"Transient empty editing must neither throw nor publish an implicit zero or alter the durable/live record")
	else
		_HNRC_Require(!WrappedDurable && Abs(FinalResolved.Delay - 0.003) >= 0.000000001,
			"The original wide decimal text must never wrap 2^64+3 into a durable/live 3ms delay")
}

_HNRC_Main() {
	global _HNRC
	_HNRC := {Mode: A_Args[1], A: 0, AHwnd: 0, B: 0, BHwnd: 0, BWidgets: 0, Button: 0,
		Running: false, ClickEntries: 0, ClickSends: 0, WorkerCalls: 0, ClearLogs: 0, ActorCalls: 0,
		ActorArmed: false, ActorDone: false, AClosed: false, BeforeB: false, Errors: [], Failure: 0,
		DestroyProc: 0, DestroyInstalled: false, DestroyActive: 0, DestroySeen: false, ReopenCalls: 0, ReopenFailure: 0,
		DestroyDescriptor: 0, DestroyPortInstalled: false, DestroyCalls: 0, NativeDestroyReturns: 0,
		FaultInjected: false, FaultWarnings: 0, Fault: Error("Controlled native reset Destroy observer refusal"), LastThrown: 0,
		NumericEdit: 0, NumericHwnd: 0, NumericText: "", RawNumericText: "", NumericBefore: 0, NumericAfter: 0,
		NumericInputs: 0, NumericDone: false, NumericDrained: false, NumericEmpty: false, NumericField: ""}
	_HNRC_Require(A_Args.Length == 2 && (_HNRC.Mode == "current" || _HNRC.Mode == "reopen" || _HNRC.Mode == "destroy-current" || _HNRC.Mode == "destroy-reopen" || _HNRC_FaultMode() || _HNRC.Mode == "numeric-current" || _HNRC.Mode == "numeric-overflow" || _HNRC.Mode == "numeric-empty-delay" || _HNRC.Mode == "numeric-empty-priority"), "The private mode and root must be explicit")
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_HNRC_OnError)
	LoggerSetTestSink(_HNRC_Log)
	; Actual logger flags only; no wrapper replacement or synthetic clock.
	global LOGGER_MIN_LEVEL := "DEBUG"
	_LoggerRefreshFastFlags()
	PreviousCritical := Critical("Off"), WasSuspended := A_IsSuspended, Primary := 0, Cleanup := 0
	Thread("Interrupt", 0)
	try {
		Suspend(false)
		_HNRC_Run()
	} catch Any as Failure {
		Primary := IsObject(_HNRC.Failure) ? _HNRC.Failure : Failure
	} finally {
		_HNRC.Running := false
		if _HNRC.DestroyPortInstalled {
			try {
				Gui.Prototype.DefineProp("Destroy", _HNRC.DestroyDescriptor)
				_HNRC.DestroyPortInstalled := false
			} catch Any as Failure
				Cleanup := Failure
		}
		Removed := !_HNRC.DestroyInstalled || !DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int")
		if !Removed
			Removed := !!DllCall("Comctl32\RemoveWindowSubclass", "Ptr", _HNRC.AHwnd, "Ptr", _HNRC.DestroyProc, "UPtr", 0x484E5244, "Int")
		if Removed && !_HNRC.DestroyActive {
			if _HNRC.DestroyProc
				CallbackFree(_HNRC.DestroyProc)
			_HNRC.DestroyProc := 0
		} else if !IsObject(Cleanup)
			Cleanup := Error("The exact native destruction callback must quiesce before callback memory is released")
		for Callback in [_HNRC_Click, _HNRC_Actor, _HNRC_NumericInput] {
			try SetTimer(Callback, 0)
			catch Any as Failure {
				if !IsObject(Cleanup)
					Cleanup := Failure
			}
		}
		if _HNRC_FaultMode() && IsSet(_HCW_RetryRetiredNativeResets)
			try _HCW_RetryRetiredNativeResets()
		for Pair in [[_HNRC.A, _HNRC.AHwnd], [_HNRC.B, _HNRC.BHwnd]] {
			try {
				if Pair[1] is Gui && DllCall("User32\IsWindow", "Ptr", Pair[2], "Int")
					Pair[1].Destroy()
				_HNRC_Require(!DllCall("User32\IsWindow", "Ptr", Pair[2], "Int"), "Every captured native window must retire exactly")
			} catch Any as Failure {
				if !IsObject(Cleanup)
					Cleanup := Failure
			}
		}
		LoggerClearTestSink()
		OnError(_HNRC_OnError, 0)
		Suspend(WasSuspended)
		Critical(PreviousCritical)
	}
	if IsObject(Primary) {
		if IsObject(Cleanup)
			Primary.Message .= " [cleanup: " . Cleanup.Message . "]"
		FileAppend("FAIL hcw-native-reset-owner " . _HNRC.Mode . " type=" . Type(Primary)
			. " file=" . Primary.File . " line=" . Primary.Line . " message=" . JsonStringLiteral(Primary.Message)
			. " stack=" . JsonStringLiteral(Primary.Stack) . "`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	if IsObject(Cleanup) {
		FileAppend("FAIL hcw-native-reset-owner cleanup=" . JsonStringLiteral(Cleanup.Message) . "`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS hcw-native-reset-owner " . _HNRC.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}


_HNRC_FaultMode() {
	global _HNRC
	return _HNRC.Mode == "retire-pre" || _HNRC.Mode == "retire-post"
}

_HNRC_InstallDestroyFault() {
	global _HNRC, _HCW_RetiredNativeResets
	_HNRC_Require(IsSet(_HCW_RetryRetiredNativeResets) && _HCW_RetiredNativeResets.Length == 0,
		"These postfix controls require the genuine independent native reset retirement protocol")
	_HNRC.DestroyDescriptor := Gui.Prototype.GetOwnPropDesc("Destroy")
	Gui.Prototype.DefineProp("Destroy", {Call: _HNRC_DestroyFault})
	_HNRC.DestroyPortInstalled := true
}

; This is an explicit observer fault, not a claim that Win32 Destroy itself
; refused. Every successful native delegation still uses the original method.
_HNRC_DestroyFault(Window, Params*) {
	global _HNRC
	Native := _HNRC.DestroyDescriptor.Call
	if Window != _HNRC.A
		return Native.Call(Window, Params*)
	_HNRC.DestroyCalls += 1
	if !_HNRC.FaultInjected && _HNRC.Mode == "retire-pre" {
		_HNRC_Require(DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int"),
			"The pre-effect observer must refuse while the exact original window is still native")
		_HNRC.FaultInjected := true, _HNRC.LastThrown := _HNRC.Fault
		throw _HNRC.Fault
	}
	Result := Native.Call(Window, Params*)
	_HNRC.NativeDestroyReturns += 1
	if !_HNRC.FaultInjected {
		_HNRC_Require(!DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int"),
			"The post-effect observer must first delegate genuine native destruction")
		_HNRC.FaultInjected := true, _HNRC.LastThrown := _HNRC.Fault
		throw _HNRC.Fault
	}
	return Result
}

_HNRC_CheckRetirementFault(FinalHash) {
	global _HNRC, _HCW_RetiredNativeResets, _HCWGui, _HCWWidgets
	_HNRC_Require(_HNRC.FaultInjected && _HNRC.LastThrown == _HNRC.Fault
		&& _HNRC.FaultWarnings == 1 && _HNRC.Errors.Length == 0 && _HNRC.DestroyCalls == 1,
		"Exactly the explicit Destroy observer failure must remain visible without other technical errors")
	_HNRC_Require(_HCW_RetiredNativeResets.Length == 1,
		"A failed native retirement must retain one independent cleanup owner")
	Record := _HCW_RetiredNativeResets[1]
	_HNRC_Require(Record.window == _HNRC.A && Record.widgets.Gui == _HNRC.A && !Record.closing,
		"The retained debt must own the exact old form and widgets")
	if _HNRC.Mode == "retire-pre"
		_HNRC_Require(DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int") && !_HNRC_Visible(_HNRC.AHwnd)
			&& _HNRC.NativeDestroyReturns == 0 && _HCWGui == 0 && _HCWWidgets == 0,
			"Pre-effect refusal retains hidden A independently of the detached singleton")
	else
		_HNRC_Require(!DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int") && _HNRC.NativeDestroyReturns == 1
			&& _HNRC.BeforeB && _HCWGui == _HNRC.B,
			"Post-effect refusal retains exact debt without restoring A above the real B")
	_HNRC.Running := true
	try OpenHotstringsConfigWindow()
	finally _HNRC.Running := false
	if IsObject(_HNRC.Failure)
		throw _HNRC.Failure
	AfterB := _HNRC.BeforeB && _HCWGui == _HNRC.B && _HNRC_Visible(_HNRC.BHwnd)
		&& _HCWWidgets.Gui == _HNRC.B && DllCall("IsWindow", "Ptr", _HCWWidgets.DelayEdit.Hwnd, "Int")
	FileAppend("OBSERVATION hcw-retirement-fault mode=" . _HNRC.Mode . " destroy_calls=" . _HNRC.DestroyCalls
		. " native_returns=" . _HNRC.NativeDestroyReturns . " warnings=" . _HNRC.FaultWarnings
		. " debt=" . _HCW_RetiredNativeResets.Length . " reopen_calls=" . _HNRC.ReopenCalls
		. " before_b=" . _HNRC.BeforeB . " after_b=" . AfterB . " errors=" . _HNRC.Errors.Length . "`n", "*", "UTF-8-RAW")
	_HNRC_Require(_HNRC.DestroyCalls == 2 && _HNRC.ReopenCalls == 1 && !IsObject(_HNRC.ReopenFailure)
		&& AfterB && _HNRC.Errors.Length == 0 && _HNRC.FaultWarnings == 1,
		"The next real public Open must retry exact A and preserve the independently reopened B")
	_HNRC_Require(_HCW_RetiredNativeResets.Length == 0 && Record.window == 0 && Record.widgets == 0
		&& !DllCall("IsWindow", "Ptr", _HNRC.AHwnd, "Int")
		&& _HNRC.NativeDestroyReturns == (_HNRC.Mode == "retire-pre" ? 1 : 2),
		"Real retirement or native-idempotent retry must completely release exact cleanup debt")
	_HNRC_Require(CryptoSha256Bytes(FSReadBytesStrict(_HNRC.OverridePath)) == FinalHash,
		"Cleanup retry cannot change the genuine already-cleared durable override")
}

_HNRC_Main()
