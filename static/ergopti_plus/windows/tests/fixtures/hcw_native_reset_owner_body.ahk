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
		if InStr(Line, "[ERROR]") || InStr(Line, "[WARNING]")
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
	_HNRC_Require(Seed["magickey"]["delay"] == 0.321, "Independent native decode must confirm the durable override")
	_HNRC.SeedHash := CryptoSha256Bytes(FSReadBytesStrict(_HNRC.OverridePath))
	OpenHotstringsConfigWindow()
	_HNRC.A := _HCWGui, _HNRC.AHwnd := _HCWGui.Hwnd
	_HNRC_Require(_HNRC.A is Gui && _HNRC_Visible(_HNRC.AHwnd) && _HCWWidgets.Gui == _HNRC.A,
		"The actual public fallback must publish visible native A and real widgets")
	_HNRC_Require(_HCW_PendingNumericWrites.Length == 0 && !_HCW_NumericDrainActive && !_HSLR_Active,
		"No numeric candidate or live rebuild may predate this component")
	Found := 0
	for Control in _HNRC.A {
		if Control.Type == "Button" && Control.Text == t("hs_config.btn_reset_all") {
			Found += 1
			_HNRC.Button := Control
		}
	}
	_HNRC_Require(Found == 1, "The actual native reset button must be uniquely identified")
	_HNRC.Button.OnEvent("Click", _HNRC_Entry, -1)
	_HNRC.Running := true
	Result := RebuildHotstringsLive(_HNRC_Worker)
	_HNRC.Running := false
	if IsObject(_HNRC.Failure)
		throw _HNRC.Failure
	_HNRC_Require((Result is Integer) && Result == false && !_HSLR_Active && !HSE_RebuildInProgress,
		"The real coordinator must finish with the external worker refused and its ownership released")
	_HNRC_Require(_HNRC.ClickSends == 1 && _HNRC.ClickEntries == 1 && _HNRC.ClearLogs > 0 && _HNRC.Errors.Length == 0,
		"The native event and genuine durable clear logs must be reached without contained prerequisites")
	Final := TOML_ParseDocument(FSReadUtf8Exact(_HNRC.OverridePath))
	FinalHash := CryptoSha256Bytes(FSReadBytesStrict(_HNRC.OverridePath))
	Cleared := !Final.Has("magickey") || !Final["magickey"].Has("delay")
	AfterB := _HNRC.Mode == "reopen" && _HCWGui == _HNRC.B && _HNRC_Visible(_HNRC.BHwnd)
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
	if _HNRC.Mode == "current" {
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

_HNRC_Main() {
	global _HNRC
	_HNRC := {Mode: A_Args[1], A: 0, AHwnd: 0, B: 0, BHwnd: 0, BWidgets: 0, Button: 0,
		Running: false, ClickEntries: 0, ClickSends: 0, WorkerCalls: 0, ClearLogs: 0, ActorCalls: 0,
		ActorArmed: false, ActorDone: false, AClosed: false, BeforeB: false, Errors: [], Failure: 0}
	_HNRC_Require(A_Args.Length == 2 && (_HNRC.Mode == "current" || _HNRC.Mode == "reopen"), "The private mode and root must be explicit")
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
		for Callback in [_HNRC_Click, _HNRC_Actor] {
			try SetTimer(Callback, 0)
			catch Any as Failure {
				if !IsObject(Cleanup)
					Cleanup := Failure
			}
		}
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

_HNRC_Main()
