; tests/fixtures/prompt_navigation_custody_body.ahk

; ==============================================================================
; MODULE: Prompt Navigation Native Host Child
; DESCRIPTION:
; Real configuration admission, public profile editing, native GUI and shipped
; SDK creation run unchanged. Browser effects retain the actual subscriptions;
; a native timer delivers their captured callback and the declared defer seam
; permits exact draining of production initialization callbacks.
; ==============================================================================

#Requires AutoHotkey v2.0

_PNAV_Require(Value, Message := "") {
	if !Value
		throw Error(Message)
}

t(Key) => Key
WindowTitle(Label := "") => Label

_PNAV_Queue(Callback) {
	global _PNAV
	_PNAV.Deferred.Push(Callback)
}

_PNAV_Evaluate(Script) {
	global _PNAV
	_PNAV.Scripts.Push(Script)
}

_PNAV_Drain() {
	global _PNAV
	while _PNAV.Deferred.Length {
		_PNAV_Require(A_Index <= 8, "Initialization must not recursively replenish its own queue.")
		_PNAV.Deferred.RemoveAt(1).Call()
	}
}

class _PNAV_View {
	__New() {
		this.Settings := {}, this.Messages := 0, this.Navigations := 0
	}
	WebMessageReceived(Callback) {
		this.Messages += 1
		return {Callback: Callback}
	}
	NavigationCompleted(Callback) {
		_PNAV_Require(!HasProp(this, "NavigationCallback"), "Each exact view registers one native navigation callback.")
		this.NavigationCallback := Callback
		return {Callback: Callback}
	}
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
}

class _PNAV_Controller {
	__New(Hwnd) {
		global _PNAV, _PromptEdWeb_Gui
		Parent := DllCall("User32\GetParent", "Ptr", Hwnd, "Ptr")
		Window := GuiFromHwnd(Parent)
		_PNAV_Require(Window is Gui && Window == _PromptEdWeb_Gui
			&& DllCall("User32\IsWindowVisible", "Ptr", Parent, "Int"),
			"The actual SDK must name the real published, visible native prompt window.")
		this.Window := Window, this.Hwnd := Parent
		this.CoreWebView2 := _PNAV_View(), this.Closed := 0, this.Fills := 0
		_PNAV.Controllers.Push(this)
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

class _PNAV_Environment {
	CreateCoreWebView2ControllerAsync(Hwnd) {
		return Promise.resolve(_PNAV_Controller(Hwnd))
	}
}

_PNAV_Input(*) {
	throw Error("A genuine admitted prompt opening must not reach the native fallback.")
}

_PNAV_Open(Index) {
	global _PNAV, _PromptEdWeb_Gui, _PromptEdWeb_Controller, _PromptEdWeb_OpeningSource
	LLM_Menu_PromptEditProfile(_PNAV.Profiles[Index], Map("input", _PNAV_Input))
	_PNAV_Require(_PromptEdWeb_Gui is Gui && IsSet(_PromptEdWeb_Controller)
		&& _PromptEdWeb_OpeningSource is Map && _LLM_Menu_ProfileSourceBound(_PromptEdWeb_OpeningSource),
		"The genuine public editor must retain its real admitted configuration and native host.")
	return _PromptEdWeb_Controller
}

_PNAV_Delivery(Callback, View) {
	global _PNAV
	try {
		; TypedHandler forwards the original sender and navigation arguments to
		; this exact callback. The passive browser boundary retains that ABI.
		Callback.Call(View, {})
	} catch Any as Failure {
		_PNAV.Failure := Failure
	} finally _PNAV.Delivered += 1
}

_PNAV_Deliver(View) {
	global _PNAV
	_PNAV_Require(HasProp(View, "NavigationCallback"), "Delivery must use the actual production subscription.")
	Before := _PNAV.Delivered
	Timer := _PNAV_Delivery.Bind(View.NavigationCallback, View)
	try {
		SetTimer(Timer, -1)
		Started := A_TickCount
		while _PNAV.Delivered == Before && TickElapsed(Started) < 3000
			Sleep(10)
		_PNAV_Require(_PNAV.Delivered == Before + 1, "The native timer must deliver the exact browser callback once.")
		if IsObject(_PNAV.Failure)
			throw _PNAV.Failure
	} finally SetTimer(Timer, 0)
	_PNAV_Drain()
}

_PNAV_HasProfile(Index) {
	global _PNAV
	return _PNAV.Scripts.Length == 1
		&& InStr(_PNAV.Scripts[1], '"edit_id":"' . _PNAV.Profiles[Index]["id"] . '"')
}

_PNAV_Main() {
	global _PNAV, _VendorDir, _LLM_Menu, ConfigurationFile
	global _WebView_SharedEnv, _WebView_SharedEnvRetired
	global _PromptEdWeb_EvalHook, _PromptEdWeb_DeferHook, _PromptEdWeb_Gui
	if A_Args.Length != 2
		ExitApp(2)
	Mode := A_Args[1]
	_PNAV_Require(Mode == "current" || Mode == "closed" || Mode == "reopen" || Mode == "repoint")
	_PNAV := {Controllers: [], Profiles: [], Deferred: [], Scripts: [], Delivered: 0, Failure: 0}
	PreviousEnv := _WebView_SharedEnv, PreviousRetired := _WebView_SharedEnvRetired
	PreviousCritical := Critical("Off")
	Primary := 0
	try {
		Thread("Interrupt", 0)
		_VendorDir := A_Args[2]
		_WebView_SharedEnv := _PNAV_Environment(), _WebView_SharedEnvRetired := false
		_PromptEdWeb_EvalHook := _PNAV_Evaluate, _PromptEdWeb_DeferHook := _PNAV_Queue
		DirCreate(A_Args[2] . "\config")
		ConfigurationFile := A_Args[2] . "\config\config.toml"
		_PNAV.Profiles := [Map("id", "user_private_a", "label", "Private A", "system_single", "First private prompt",
			"system_multi", "", "batch", false), Map("id", "user_private_b", "label", "Private B",
			"system_single", "Second private prompt", "system_multi", "", "batch", false)]
		Payload := _LLM_Menu_SerializeUserProfiles(_PNAV.Profiles)
		_PNAV_Require(Payload is String && SubStr(Payload, 1, 3) == "v1:")
		Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion()
			. '`n[llm]`nenabled = false`nuser_profiles = "' . Payload . '"`n'
		_PNAV_Require(FSWriteCreateDurable(ConfigurationFile, Source))
		Boot := ConfigMigrateBoot(ConfigurationFile)
		_PNAV_Require(Boot["status"] == "current" && Boot["read_only"] == 0 && ConfigFullStateCanPersist(),
			"The actual migration owner must admit this private source before the public editor opens.")
		_LLM_Menu := Map("user_profiles", _PNAV.Profiles, "profile_id", "user_private_a", "enabled", false)
		First := _PNAV_Open(1)
		_PNAV_Require(_PNAV.Controllers.Length == 1 && First.Closed == 0 && First.Fills == 1)
		if Mode == "current" {
			_PNAV_Deliver(First.CoreWebView2)
			_PNAV_Require(_PNAV_HasProfile(1), "A current native navigation must initialize its displayed profile once.")
		} else if Mode == "repoint" {
			Second := _PNAV_Open(2)
			_PNAV_Require(First == Second && _PNAV.Controllers.Length == 1,
				"A public profile switch must preserve the same pending or active native host.")
			_PNAV_Require(_PNAV_HasProfile(2), "The real public repoint initializes the new displayed profile.")
			_PNAV.Scripts.Length := 0
			_PNAV_Deliver(First.CoreWebView2)
			_PNAV_Require(_PNAV_HasProfile(2),
				"The same genuine host's navigation remains authorized after a displayed-profile switch.")
		} else {
			_PromptEdWeb_Close(First.Window)
			_PNAV_Require(First.Closed == 1 && !DllCall("User32\IsWindow", "Ptr", First.Hwnd, "Int"))
			if Mode == "reopen" {
				Second := _PNAV_Open(2)
				_PNAV_Require(Second != First && Second.Window != First.Window && _PNAV.Controllers.Length == 2)
				_PNAV_Deliver(Second.CoreWebView2)
				_PNAV_Require(_PNAV_HasProfile(2), "The new genuine host must initialize normally before the retired event arrives.")
				_PNAV.Scripts.Length := 0
			}
			_PNAV_Deliver(First.CoreWebView2)
			_PNAV_Require(_PNAV.Scripts.Length == 0,
				"A retired native navigation callback must not initialize the successor's displayed form.")
			if Mode == "reopen"
				_PNAV_Require(Second.Closed == 0 && _PromptEdWeb_Gui == Second.Window,
					"Rejecting the old callback must preserve the exact current native host.")
		}
	} catch Any as Failure {
		Primary := Failure
	} finally {
		_PromptEdWeb_EvalHook := 0, _PromptEdWeb_DeferHook := 0
		_PromptEdWeb_Close()
		for Controller in _PNAV.Controllers {
			if Controller.Closed == 0
				Controller.Close()
			if DllCall("User32\IsWindow", "Ptr", Controller.Hwnd, "Int")
				Controller.Window.Destroy()
		}
		_WebView_SharedEnv := PreviousEnv, _WebView_SharedEnvRetired := PreviousRetired
		Critical(PreviousCritical)
	}
	if IsObject(Primary) {
		FileAppend("FAIL prompt-navigation " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS prompt-navigation " . Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_PNAV_Main()
