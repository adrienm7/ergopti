; tests/fixtures/prompt_startup_owner_body.ahk

; ==============================================================================
; MODULE: Prompt Editor Startup Owner Child
; DESCRIPTION:
; Uses actual migration admission, profile source capture and the public edit
; entry point. A passive browser factory awaits the shipped Promise while a
; native timer closes the exact published GUI and optionally opens a successor.
; No browser engine, save operation, page navigation callback or input is faked.
; ==============================================================================

#Requires AutoHotkey v2.0

_PRSO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; These are explicit presentation/browser ports, not source admission helpers.
t(Key) => Key
WindowTitle(Label := "") => Label

Gui_Create(Options := "", Title := "") {
	global _PRSO
	Window := Gui(Options, Title)
	_PRSO.Windows.Push(Window), _PRSO.Hwnds.Push(Window.Hwnd)
	return Window
}

class WebView2 {
	static CreateEnvironmentAsync(BrowserFolder, UserDataFolder, Options, Loader) {
		global _PRSO, WEBVIEW_SHARED_UDIR
		_PRSO_Require(BrowserFolder == 0 && UserDataFolder == WEBVIEW_SHARED_UDIR
			&& UserDataFolder == A_Args[2] . "\profile" && Options == ""
			&& Loader == A_Args[2] . "\64bit\WebView2Loader.dll",
			"The actual shared environment helper must use only this private passive browser boundary.")
		_PRSO.Environments += 1
		Resolved := Promise.withResolvers()
		Resolved.resolve.Call({ Passive: true })
		return Resolved.promise
	}
	static create(Hwnd, Callback?, Environment := 0) {
		_PRSO_Require(!IsSet(Callback) && Environment.Passive,
			"The genuine prompt host must use its synchronous constructor contract.")
		return _PRSO_Create(Hwnd)
	}
}

class _PRSO_View {
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

class _PRSO_Controller {
	__New() {
		this.CoreWebView2 := _PRSO_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

_PRSO_Input(*) {
	global _PRSO
	_PRSO.FallbackInputs += 1
	throw Error("Business oracle: a consumed prompt opening reached native fallback input.")
}

_PRSO_Log(Line) {
	global _PRSO
	if InStr(Line, "[ERROR]")
		_PRSO.Errors.Push(Line)
}

_PRSO_Open(Profile) {
	global _PRSO
	_PRSO.PublicCalls += 1
	LLM_Menu_PromptEditProfile(Profile, Map("input", _PRSO_Input))
}

_PRSO_Create(Hwnd) {
	global _PRSO, _PromptEdWeb_Gui, _PromptEdWeb_OpeningSource
	_PRSO_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		&& IsObject(_PromptEdWeb_Gui)
		&& DllCall("User32\IsWindowVisible", "Ptr", _PromptEdWeb_Gui.Hwnd, "Int"),
		"The controlled wait must begin after a real visible prompt GUI is published.")
	_PRSO_Require(_PromptEdWeb_OpeningSource is Map
		&& _LLM_Menu_ProfileSourceBound(_PromptEdWeb_OpeningSource)
		&& _PromptEdWeb_OpeningSource["present"] == 1
		&& _PromptEdWeb_OpeningSource["content"] == _PRSO.Source,
		"The public edit must capture its real boot-admitted private file, not a fabricated READY receipt.")
	Controller := _PRSO_Controller()
	_PRSO.Controllers.Push(Controller)
	if _PRSO.Controllers.Length > 1 || _PRSO.Mode == "current"
		return Controller
	_PRSO.Pending := Promise.withResolvers()
	; An independent observer prevents the vendor task's unobserved-report path.
	_PRSO.Pending.promise.onSettled((*) => 0, (*) => 0)
	_PRSO.Boundary := _PRSO_CloseDuringCreate
	SetTimer(_PRSO.Boundary, -1)
	return _PRSO.Pending.promise.await(3000)
}

_PRSO_NativeClose(Hwnd) {
	global _PromptEdWeb_ContextEpoch, _PromptEdWeb_OpeningSource
	Epoch := _PromptEdWeb_ContextEpoch
	_PRSO_Require(Epoch > 0 && DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int"),
		"Native WM_CLOSE must address this exact live prompt context.")
	DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while (DllCall("User32\IsWindow", "Ptr", Hwnd, "Int") || _PromptEdWeb_ContextEpoch != 0)
		&& TickElapsed(Started) < 1000
		Sleep(10)
	_PRSO_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
		&& _PromptEdWeb_ContextEpoch == 0 && _PromptEdWeb_OpeningSource == 0,
		"The genuine Close must destroy the exact HWND and revoke its source/context before browser completion.")
}

_PRSO_CloseDuringCreate() {
	global _PRSO, _PromptEdWeb_ContextEpoch, _PromptEdWeb_Gui
	try {
		_PRSO.OldEpoch := _PromptEdWeb_ContextEpoch
		_PRSO.CloseSent += 1
		_PRSO_NativeClose(_PRSO.Hwnds[1])
		if _PRSO.Mode == "reopen-create" {
			_PRSO_Open(_PRSO.Profiles[2])
			_PRSO_Require(_PRSO.Windows.Length == 2 && _PRSO.Controllers.Length == 2
				&& _PromptEdWeb_ContextEpoch > _PRSO.OldEpoch && _PromptEdWeb_Gui == _PRSO.Windows[2],
				"A successor must use the same genuine public edit with an independently captured source.")
			_PRSO.SuccessorEpoch := _PromptEdWeb_ContextEpoch
		}
		_PRSO.Pending.resolve.Call(_PRSO.Controllers[1])
	} catch as Failure {
		if !IsObject(_PRSO.Failure)
			_PRSO.Failure := Failure
		_PRSO.Pending.reject.Call(Failure)
	}
}

_PRSO_OnError(Failure, Mode) {
	global _PRSO
	if !IsObject(_PRSO.Failure)
		_PRSO.Failure := Failure is Error ? Failure : Error("An asynchronous prompt failure was observed.")
	try FileAppend("DIAG prompt-startup async type=" . Type(Failure) . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

_PRSO_Observe() {
	global _PRSO, _PromptEdWeb_Gui, _PromptEdWeb_ContextEpoch, _PromptEdWeb_EditId
	global _PromptEdWeb_Controller, _PromptEdWeb_WebView, _PromptEdWeb_ResetDone
	FileAppend("RECEIPT prompt-startup mode=" . _PRSO.Mode . " public_calls=" . _PRSO.PublicCalls
		. " windows=" . _PRSO.Windows.Length . " controllers=" . _PRSO.Controllers.Length . " environments=" . _PRSO.Environments
		. " close_sent=" . _PRSO.CloseSent . " boundary_failure=" . IsObject(_PRSO.Failure)
		. " fallback_inputs=" . _PRSO.FallbackInputs . " old_closed=" . _PRSO.Controllers[1].Closed
		. " old_subscriptions=" . _PRSO.Controllers[1].CoreWebView2.Subscriptions
		. " old_navigations=" . _PRSO.Controllers[1].CoreWebView2.Navigations
		. " gui=" . IsObject(_PromptEdWeb_Gui) . " controller=" . IsSet(_PromptEdWeb_Controller)
		. " view=" . IsSet(_PromptEdWeb_WebView) . " reset=" . _PromptEdWeb_ResetDone
		. " epoch=" . _PromptEdWeb_ContextEpoch . " edit_b=" . (_PromptEdWeb_EditId == "user_private_b") . "`n", "*", "UTF-8")
}

_PRSO_Check() {
	global _PRSO, _PromptEdWeb_Gui, _PromptEdWeb_Controller, _PromptEdWeb_WebView
	global _PromptEdWeb_MsgSub, _PromptEdWeb_NavSub, _PromptEdWeb_ResetDone
	global _PromptEdWeb_ContextEpoch, _PromptEdWeb_EditId, ConfigurationFile
	if IsObject(_PRSO.Failure)
		throw _PRSO.Failure
	_PRSO_Require(_PRSO.Errors.Length == 0 && _PRSO.FallbackInputs == 0 && _PRSO.Environments == 1,
		"No admission or runtime diagnostic may qualify as prompt cancellation.")
	_PRSO_Require(FSConfigReadUtf8Exact(ConfigurationFile) == _PRSO.Source,
		"Opening and cancellation cannot rewrite the genuine private profile source.")
	if _PRSO.Mode == "current" {
		_PRSO_Require(_PRSO.Controllers.Length == 1 && _PRSO.Windows.Length == 1
			&& _PromptEdWeb_Gui == _PRSO.Windows[1] && _PromptEdWeb_ContextEpoch > 0,
			"The current positive must publish its exact real prompt GUI/context.")
		_PRSO_Require(_PromptEdWeb_Controller == _PRSO.Controllers[1]
			&& _PromptEdWeb_WebView == _PRSO.Controllers[1].CoreWebView2
			&& IsSet(_PromptEdWeb_MsgSub) && IsSet(_PromptEdWeb_NavSub)
			&& _PRSO.Controllers[1].CoreWebView2.Subscriptions == 2
			&& _PRSO.Controllers[1].CoreWebView2.Navigations == 1
			&& _PRSO.Controllers[1].Fills >= 1 && !_PromptEdWeb_ResetDone,
			"A current browser must retain both subscriptions and navigate/fill once admitted.")
		_PRSO_NativeClose(_PRSO.Hwnds[1])
		_PRSO_Require(_PRSO.Controllers[1].Closed == 1, "The current positive must close its own browser exactly once.")
		return
	}
	_PRSO_Require(_PRSO.CloseSent == 1, "One actual native Close must precede the old browser completion.")
	_PRSO_Require(_PRSO.Controllers[1].Closed == 1,
		"A controller returned after native Close must retire exactly once.")
	_PRSO_Require(_PRSO.Controllers[1].CoreWebView2.Subscriptions == 0
		&& _PRSO.Controllers[1].CoreWebView2.Navigations == 0,
		"A retired constructor cannot subscribe or navigate after its native owner closes.")
	if _PRSO.Mode == "reopen-create" {
		_PRSO_Require(_PRSO.Windows.Length == 2 && _PRSO.Controllers.Length == 2
			&& _PromptEdWeb_Gui == _PRSO.Windows[2] && _PromptEdWeb_ContextEpoch == _PRSO.SuccessorEpoch
			&& _PromptEdWeb_EditId == "user_private_b"
			&& _PromptEdWeb_Controller == _PRSO.Controllers[2]
			&& _PromptEdWeb_WebView == _PRSO.Controllers[2].CoreWebView2
			&& !_PromptEdWeb_ResetDone && _PRSO.Controllers[2].Closed == 0,
			"The resumed old frame must preserve the exact successor GUI, profile, epoch, controller and view.")
		_PRSO_Require(_PRSO.Controllers[2].CoreWebView2.Subscriptions == 2
			&& _PRSO.Controllers[2].CoreWebView2.Navigations == 1 && _PRSO.Controllers[2].Fills >= 1,
			"The successor must remain fully published and independently closable.")
		_PRSO_NativeClose(_PRSO.Hwnds[2])
		_PRSO_Require(_PRSO.Controllers[2].Closed == 1, "The successor must retire its own controller once.")
	} else
		_PRSO_Require(!IsObject(_PromptEdWeb_Gui) && _PromptEdWeb_ResetDone
			&& !IsSet(_PromptEdWeb_Controller) && !IsSet(_PromptEdWeb_WebView)
			&& !IsSet(_PromptEdWeb_MsgSub) && !IsSet(_PromptEdWeb_NavSub),
			"A canceled prompt opening cannot republish a browser or subscriptions.")
}

_PRSO_Main() {
	global _PRSO, _VendorDir, _LLM_Menu, ConfigurationFile, WEBVIEW_SHARED_UDIR
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	_PRSO := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Profiles: [], Source: "",
		Pending: 0, Boundary: 0, Failure: 0, Errors: [], PublicCalls: 0, CloseSent: 0,
		OldEpoch: 0, SuccessorEpoch: 0, FallbackInputs: 0, Environments: 0 }
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_PRSO_OnError)
	LoggerSetTestSink(_PRSO_Log)
	_VendorDir := A_Args[2]
	WEBVIEW_SHARED_UDIR := A_Args[2] . "\profile"
	Primary := 0, Observed := false
	try {
		DirCreate(A_Args[2] . "\config")
		ConfigurationFile := A_Args[2] . "\config\config.toml"
		_PRSO.Profiles := [Map("id", "user_private_a", "label", "Private A", "system_single", "First private prompt",
			"system_multi", "", "batch", false), Map("id", "user_private_b", "label", "Private B",
			"system_single", "Second private prompt", "system_multi", "", "batch", false)]
		Payload := _LLM_Menu_SerializeUserProfiles(_PRSO.Profiles)
		_PRSO_Require(Payload is String && SubStr(Payload, 1, 3) == "v1:", "The real profile codec must serialize the private model.")
		_PRSO.Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion()
			. '`n[llm]`nenabled = false`nuser_profiles = "' . Payload . '"`n'
		_PRSO_Require(FSWriteCreateDurable(ConfigurationFile, _PRSO.Source), "The private current source must be created exclusively.")
		Boot := ConfigMigrateBoot(ConfigurationFile)
		_PRSO_Require(Boot["status"] == "current" && Boot["read_only"] == 0 && ConfigFullStateCanPersist(),
			"Actual native boot must admit this exact private file before the public editor opens.")
		_LLM_Menu := Map("user_profiles", _PRSO.Profiles, "profile_id", "user_private_a", "enabled", false)
		_PRSO_Open(_PRSO.Profiles[1])
		_PRSO_Observe(), Observed := true
		_PRSO_Check()
	} catch as Failure {
		Primary := IsObject(_PRSO.Failure) ? _PRSO.Failure : Failure
	} finally {
		if !Observed && _PRSO.Controllers.Length > 0 {
			try _PRSO_Observe()
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			if HasMethod(_PRSO.Boundary, "Call")
				SetTimer(_PRSO.Boundary, 0)
			_PromptEdWeb_Close()
			for Controller in _PRSO.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Index, Window in _PRSO.Windows
				if DllCall("User32\IsWindow", "Ptr", _PRSO.Hwnds[Index], "Int")
					Window.Destroy()
			for Hwnd in _PRSO.Hwnds
				_PRSO_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every exact private HWND must retire.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		_PRSO.Pending := 0, _PRSO.Boundary := 0
		LoggerClearTestSink()
		OnError(_PRSO_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_PRSO.Failure)
		Primary := _PRSO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS prompt-startup " . _PRSO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_PRSO_Main()
