; tests/fixtures/prompt_startup_repoint_body.ahk

; ==============================================================================
; MODULE: Prompt Startup Profile Repoint Control
; DESCRIPTION:
; A native timer re-enters the public profile editor while its genuine host is
; awaiting a passive browser. The same native GUI serves profile B after the
; original construction returns; source capture and init projection stay real.
; ==============================================================================

#Requires AutoHotkey v2.0

_PRRP_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; These are explicit presentation/browser ports, not source admission helpers.
t(Key) => Key
WindowTitle(Label := "") => Label

Gui_Create(Options := "", Title := "") {
	global _PRRP
	Window := Gui(Options, Title)
	_PRRP.Windows.Push(Window), _PRRP.Hwnds.Push(Window.Hwnd)
	return Window
}

class WebView2 {
	static CreateEnvironmentAsync(BrowserFolder, UserDataFolder, Options, Loader) {
		global _PRRP, WEBVIEW_SHARED_UDIR
		_PRRP_Require(BrowserFolder == 0 && UserDataFolder == WEBVIEW_SHARED_UDIR
			&& UserDataFolder == A_Args[2] . "\profile" && Options == ""
			&& Loader == A_Args[2] . "\64bit\WebView2Loader.dll",
			"The actual shared environment helper must use only this private passive browser boundary.")
		_PRRP.Environments += 1
		Resolved := Promise.withResolvers()
		Resolved.resolve.Call({ Passive: true })
		return Resolved.promise
	}
	static create(Hwnd, Callback?, Environment := 0) {
		_PRRP_Require(!IsSet(Callback) && Environment.Passive,
			"The genuine prompt host must use its synchronous constructor contract.")
		return _PRRP_Create(Hwnd)
	}
}

class _PRRP_View {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) {
		this.Subscriptions += 1
		return { Callback: Callback }
	}
	NavigationCompleted(Callback) {
		this.Subscriptions += 1
		return { Callback: Callback }
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}

class _PRRP_Controller {
	__New() {
		this.CoreWebView2 := _PRRP_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

_PRRP_Input(*) {
	global _PRRP
	_PRRP.FallbackInputs += 1
	throw Error("Business oracle: a consumed prompt opening reached native fallback input.")
}

_PRRP_Log(Line) {
	global _PRRP
	if InStr(Line, "[ERROR]")
		_PRRP.Errors.Push(Line)
}

_PRRP_Open(Profile) {
	global _PRRP
	_PRRP.PublicCalls += 1
	LLM_Menu_PromptEditProfile(Profile, Map("input", _PRRP_Input))
}

_PRRP_Create(Hwnd) {
	global _PRRP, _PromptEdWeb_Gui, _PromptEdWeb_OpeningSource, _PromptEdWeb_ContextEpoch
	_PRRP_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		&& IsObject(_PromptEdWeb_Gui)
		&& DllCall("User32\IsWindowVisible", "Ptr", _PromptEdWeb_Gui.Hwnd, "Int"),
		"The public constructor must receive a genuinely published visible native GUI.")
	_PRRP_Require(_PromptEdWeb_OpeningSource is Map
		&& _LLM_Menu_ProfileSourceBound(_PromptEdWeb_OpeningSource)
		&& _PromptEdWeb_OpeningSource["present"] == 1
		&& _PromptEdWeb_OpeningSource["content"] == _PRRP.Source,
		"The original profile must own the genuine private boot-admitted source.")
	_PRRP_Require(_PRRP.Controllers.Length == 0, "Repointing must reuse this host, never start a second constructor.")
	_PRRP.InitialWindow := _PromptEdWeb_Gui
	_PRRP.InitialEpoch := _PromptEdWeb_ContextEpoch
	_PRRP.SourceA := _PromptEdWeb_OpeningSource
	Controller := _PRRP_Controller()
	_PRRP.Controllers.Push(Controller)
	_PRRP.Pending := Promise.withResolvers()
	_PRRP.Pending.promise.onSettled((*) => 0, (*) => 0)
	_PRRP.Boundary := _PRRP_RepointDuringCreate
	SetTimer(_PRRP.Boundary, -1)
	return _PRRP.Pending.promise.await(3000)
}

_PRRP_NativeClose(Hwnd) {
	global _PromptEdWeb_ContextEpoch, _PromptEdWeb_OpeningSource
	Epoch := _PromptEdWeb_ContextEpoch
	_PRRP_Require(Epoch > 0 && DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int"),
		"Native WM_CLOSE must address this exact live prompt context.")
	DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while (DllCall("User32\IsWindow", "Ptr", Hwnd, "Int") || _PromptEdWeb_ContextEpoch != 0)
		&& TickElapsed(Started) < 1000
		Sleep(10)
	_PRRP_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		&& _PromptEdWeb_ContextEpoch == 0 && _PromptEdWeb_OpeningSource == 0,
		"The genuine Close must destroy the exact HWND and revoke its source/context before browser completion.")
}

_PRRP_RepointDuringCreate() {
	global _PRRP, _PromptEdWeb_Gui, _PromptEdWeb_ContextEpoch, _PromptEdWeb_OpeningSource
	global _PromptEdWeb_Controller, _PromptEdWeb_EditId
	try {
		_PRRP_Require(!IsSet(_PromptEdWeb_Controller) && _PRRP.Controllers[1].Closed == 0,
			"The repoint must occur during the genuine pending constructor, before global browser publication.")
		_PRRP.TimerCalls += 1
		_PRRP_Open(_PRRP.Profiles[2])
		_PRRP_Require(_PRRP.Windows.Length == 1 && _PRRP.Controllers.Length == 1
			&& _PromptEdWeb_Gui == _PRRP.InitialWindow
			&& _PromptEdWeb_ContextEpoch > _PRRP.InitialEpoch && _PromptEdWeb_EditId == "user_private_b",
			"The genuine public re-entry must re-point the same native GUI to a fresh profile context.")
		_PRRP.SourceB := _PromptEdWeb_OpeningSource
		_PRRP.SuccessorEpoch := _PromptEdWeb_ContextEpoch
		_PRRP_Require(_PRRP.SourceB is Map && _PRRP.SourceB != _PRRP.SourceA
			&& _LLM_Menu_ProfileSourceBound(_PRRP.SourceB)
			&& _PRRP.SourceB["content"] == _PRRP.Source,
			"Profile B must capture its own actual source receipt, never borrow profile A's Map.")
		_PRRP.Pending.resolve.Call(_PRRP.Controllers[1])
	} catch as Failure {
		if !IsObject(_PRRP.Failure)
			_PRRP.Failure := Failure
		_PRRP.Pending.reject.Call(Failure)
	}
}

_PRRP_OnError(Failure, Mode) {
	global _PRRP
	if !IsObject(_PRRP.Failure)
		_PRRP.Failure := Failure is Error ? Failure : Error("An asynchronous prompt failure was observed.")
	try FileAppend("DIAG prompt-repoint async type=" . Type(Failure) . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

_PRRP_Observe() {
	global _PRRP, _PromptEdWeb_ContextEpoch
	FileAppend("RECEIPT prompt-repoint windows=" . _PRRP.Windows.Length . " controllers=" . _PRRP.Controllers.Length
		. " public_calls=" . _PRRP.PublicCalls . " timer_calls=" . _PRRP.TimerCalls
		. " boundary_failure=" . IsObject(_PRRP.Failure) . " fallback_inputs=" . _PRRP.FallbackInputs
		. " environments=" . _PRRP.Environments . " current_epoch=" . _PromptEdWeb_ContextEpoch
		. " init_scripts=" . _PRRP.InitScripts.Length . "`n", "*", "UTF-8")
}

; Existing eval hook is a passive delivery observer, not a page-ready signal.
_PRRP_CaptureInit(Js) {
	global _PRRP
	_PRRP.InitScripts.Push(Js)
	return true
}

_PRRP_Check() {
	global _PRRP, _PromptEdWeb_Gui, _PromptEdWeb_ContextEpoch, _PromptEdWeb_EditId
	global _PromptEdWeb_Controller, _PromptEdWeb_WebView, _PromptEdWeb_ResetDone
	global _PromptEdWeb_MsgSub, _PromptEdWeb_NavSub, _PromptEdWeb_OpeningSource, ConfigurationFile
	if IsObject(_PRRP.Failure)
		throw _PRRP.Failure
	_PRRP_Require(_PRRP.TimerCalls == 1 && _PRRP.PublicCalls == 2 && _PRRP.Errors.Length == 0
		&& _PRRP.FallbackInputs == 0 && _PRRP.Environments == 1,
		"The actual native timer and both real public openings must complete without a boundary or fallback refusal.")
	_PRRP_Require(_PRRP.Windows.Length == 1 && _PRRP.Controllers.Length == 1
		&& _PromptEdWeb_Gui == _PRRP.InitialWindow && _PromptEdWeb_EditId == "user_private_b"
		&& _PromptEdWeb_ContextEpoch == _PRRP.SuccessorEpoch && !_PromptEdWeb_ResetDone,
		"Returning the original constructor must preserve the same visible GUI with profile B's exact context.")
	_PRRP_Require(_PromptEdWeb_Controller == _PRRP.Controllers[1]
		&& _PromptEdWeb_WebView == _PRRP.Controllers[1].CoreWebView2
		&& _PRRP.Controllers[1].Closed == 0 && _PRRP.Controllers[1].CoreWebView2.Subscriptions == 2
		&& _PRRP.Controllers[1].CoreWebView2.Navigations == 1 && _PRRP.Controllers[1].Fills >= 1
		&& IsSet(_PromptEdWeb_MsgSub) && IsSet(_PromptEdWeb_NavSub),
		"The one shared host must become fully published, subscribed and navigated without canceling its controller.")
	_PRRP_Require(_PromptEdWeb_OpeningSource == _PRRP.SourceB
		&& _PromptEdWeb_OpeningSource != _PRRP.SourceA && _LLM_Menu_ProfileSourceBound(_PRRP.SourceB),
		"The old constructor cannot reinstall A's source receipt after B's actual capture.")
	_PRRP_Require(_PromptEdWeb_PushInit("user_private_b", _PRRP.SuccessorEpoch)
		&& _PRRP.InitScripts.Length > 0, "The real init projection must remain deliverable for the current B context.")
	Prefix := "if(window.init)window.init("
	for Js in _PRRP.InitScripts {
		_PRRP_Require(SubStr(Js, 1, StrLen(Prefix)) == Prefix && SubStr(Js, -1) == ")",
			"The observed init payload must use the real host projection envelope.")
		Data := JsonParse(SubStr(Js, StrLen(Prefix) + 1, StrLen(Js) - StrLen(Prefix) - 1))
		_PRRP_Require(Data["edit_id"] == "user_private_b" && Data["epoch"] == _PRRP.SuccessorEpoch
			&& Data["name"] == "Private B" && Data["prompt"] == "Second private prompt" && Data["mode"] == "parallel",
			"Every actual init projection must describe B's exact profile, never the original A form.")
	}
	_PRRP_Require(FSConfigReadUtf8Exact(ConfigurationFile) == _PRRP.Source,
		"The public re-entry and init projection cannot write the private source.")
	_PRRP_NativeClose(_PRRP.Hwnds[1])
	_PRRP_Require(_PRRP.Controllers[1].Closed == 1, "The repointed shared host must close independently exactly once.")
	_PRRP_Require(FSConfigReadUtf8Exact(ConfigurationFile) == _PRRP.Source,
		"Real native Close must also preserve the exact source.")
}

_PRRP_Main() {
	global _PRRP, _VendorDir, _LLM_Menu, ConfigurationFile, WEBVIEW_SHARED_UDIR, _PromptEdWeb_EvalHook
	if A_Args.Length != 2 || A_Args[1] != "same-gui"
		ExitApp(2)
	Persistent(true)
	_PRRP := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Profiles: [], Source: "",
		Pending: 0, Boundary: 0, Failure: 0, Errors: [], PublicCalls: 0, CloseSent: 0,
		OldEpoch: 0, SuccessorEpoch: 0, FallbackInputs: 0, Environments: 0, TimerCalls: 0,
		InitialWindow: 0, InitialEpoch: 0, SourceA: 0, SourceB: 0, InitScripts: [] }
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_PRRP_OnError)
	LoggerSetTestSink(_PRRP_Log)
	_PromptEdWeb_EvalHook := _PRRP_CaptureInit
	_VendorDir := A_Args[2]
	WEBVIEW_SHARED_UDIR := A_Args[2] . "\profile"
	Primary := 0, Observed := false
	try {
		DirCreate(A_Args[2] . "\config")
		ConfigurationFile := A_Args[2] . "\config\config.toml"
		_PRRP.Profiles := [Map("id", "user_private_a", "label", "Private A", "system_single", "First private prompt",
			"system_multi", "", "batch", false), Map("id", "user_private_b", "label", "Private B",
			"system_single", "Second private prompt", "system_multi", "", "batch", false)]
		Payload := _LLM_Menu_SerializeUserProfiles(_PRRP.Profiles)
		_PRRP_Require(Payload is String && SubStr(Payload, 1, 3) == "v1:", "The real profile codec must serialize the private model.")
		_PRRP.Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion()
			. '`n[llm]`nenabled = false`nuser_profiles = "' . Payload . '"`n'
		_PRRP_Require(FSWriteCreateDurable(ConfigurationFile, _PRRP.Source), "The private current source must be created exclusively.")
		Boot := ConfigMigrateBoot(ConfigurationFile)
		_PRRP_Require(Boot["status"] == "current" && Boot["read_only"] == 0 && ConfigFullStateCanPersist(),
			"Actual native boot must admit this exact private file before the public editor opens.")
		_LLM_Menu := Map("user_profiles", _PRRP.Profiles, "profile_id", "user_private_a", "enabled", false)
		_PRRP_Open(_PRRP.Profiles[1])
		_PRRP_Observe(), Observed := true
		_PRRP_Check()
	} catch as Failure {
		Primary := IsObject(_PRRP.Failure) ? _PRRP.Failure : Failure
	} finally {
		if !Observed && _PRRP.Controllers.Length > 0 {
			try _PRRP_Observe()
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			if HasMethod(_PRRP.Boundary, "Call")
				SetTimer(_PRRP.Boundary, 0)
			_PromptEdWeb_Close()
			for Controller in _PRRP.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Index, Window in _PRRP.Windows
				if DllCall("User32\IsWindow", "Ptr", _PRRP.Hwnds[Index], "Int")
					Window.Destroy()
			for Hwnd in _PRRP.Hwnds
				_PRRP_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every exact private HWND must retire.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		_PRRP.Pending := 0, _PRRP.Boundary := 0
		_PromptEdWeb_EvalHook := 0
		LoggerClearTestSink()
		OnError(_PRRP_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_PRRP.Failure)
		Primary := _PRRP.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS prompt-repoint " . _PRRP.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_PRRP_Main()
