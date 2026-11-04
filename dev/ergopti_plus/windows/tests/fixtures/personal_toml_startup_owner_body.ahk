; tests/fixtures/personal_toml_startup_owner_body.ahk

; ==============================================================================
; MODULE: Personal TOML Browser Startup Owner Child
; DESCRIPTION:
; The genuine public editor and shipped Promise observe native Close after GUI
; publication, before browser construction returns. Browser, theme, translation
; and logging are passive; no page-ready/navigation callback or save is delivered.
; Real configured file paths remain isolated and byte-checked in the private root.
; ==============================================================================

#Requires AutoHotkey v2.0

_PTSO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; Translation/theming and browser construction are explicit passive ports. The
; public editor/path owners stay genuine. Page data/init/save is not delivered.
t(Key) => Key
LoggerSuccess(*) => 0
LoggerError(*) => 0
WebView_SharedEnvironment(Loader) => { Passive: true }

Gui_Create(Options := "", Title := "") {
	global _PTSO
	Window := Gui(Options, Title)
	_PTSO.Windows.Push(Window), _PTSO.Hwnds.Push(Window.Hwnd)
	; Every acquired HWND is owned even on an unexpected fallback. These three
	; success modes do not qualify the native fallback's preceding data path;
	; a prerequisite failure there remains a failure, not a business receipt.
	Limit := InStr(_PTSO.Mode, "reopen") ? 2 : 1
	if _PTSO.Windows.Length > Limit {
		_PTSO.FallbackAttempts += 1
		throw Error("Business oracle: a retired web opening attempted native fallback.")
	}
	return Window
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		_PTSO_Require(!IsSet(Callback) && Environment.Passive,
			"The production call must use its synchronous constructor contract.")
		return _PTSO_Create(Hwnd)
	}
}

class _PTSO_View {
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

class _PTSO_Controller {
	__New() {
		this.CoreWebView2 := _PTSO_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

_PTSO_Create(Hwnd) {
	global _PTSO, _HsEdWeb_Gui
	_PTSO_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
		"The controlled browser receives a genuine native placeholder.")
	_PTSO_Require(IsObject(_HsEdWeb_Gui)
		&& DllCall("User32\IsWindowVisible", "Ptr", _HsEdWeb_Gui.Hwnd, "Int"),
		"The browser wait begins only after the genuine personal editor is visible and published.")
	Controller := _PTSO_Controller()
	_PTSO.Controllers.Push(Controller)
	if _PTSO.Controllers.Length > 1 || _PTSO.Mode == "current"
		return Controller
	_PTSO.Pending := Promise.withResolvers()
	; The timer port has an independent settlement consumer so Promise.task does
	; not report an unobserved rejection before the suspended await resumes.
	; These callbacks never change its state or replace the rejecting await.
	_PTSO.Pending.promise.onSettled((*) => 0, (*) => 0)
	_PTSO.Boundary := _PTSO_CloseDuringCreate
	SetTimer(_PTSO.Boundary, -1)
	return _PTSO.Pending.promise.await(3000)
}

_PTSO_NativeClose(Hwnd) {
	global _HsEdWeb_SessionEpoch
	Epoch := _HsEdWeb_SessionEpoch
	_PTSO_Require(DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int"),
		"Native WM_CLOSE must address this visible admitted personal editor.")
	DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while (DllCall("User32\IsWindow", "Ptr", Hwnd, "Int") || _HsEdWeb_SessionEpoch <= Epoch)
		&& ((A_TickCount - Started) & 0xFFFFFFFF) < 1000
		Sleep(10)
	_PTSO_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int") && _HsEdWeb_SessionEpoch > Epoch,
		"The actual Close event must destroy the window and revoke its session.")
}

_PTSO_CloseDuringCreate() {
	global _PTSO, _HsEdWeb_SessionEpoch
	try {
		_PTSO.OldEpoch := _HsEdWeb_SessionEpoch
		_PTSO.CloseSent += 1
		_PTSO_NativeClose(_PTSO.Hwnds[1])
		if InStr(_PTSO.Mode, "reopen") {
			OpenPersonalEditor("alpha")
			_PTSO_Require(_PTSO.Windows.Length == 2 && _PTSO.Controllers.Length == 2,
				"A replacement must use the same genuine public constructor.")
		}
		_PTSO.Pending.resolve.Call(_PTSO.Controllers[1])
	} catch as Failure {
		if !IsObject(_PTSO.Failure)
			_PTSO.Failure := Failure
		_PTSO.Pending.reject.Call(Failure)
	}
}

; An asynchronous exception cannot cross the suspended Main try/catch. Suppress
; its modal only after retaining it as a mandatory failure, never as success.
_PTSO_OnError(Failure, Mode) {
	global _PTSO
	OwnerFile := "UNKNOWN", OwnerLine := 0
	if Failure is Error {
		SplitPath(Failure.File, &OwnerFile)
		OwnerLine := Failure.Line
	}
	if !IsObject(_PTSO.Failure)
		_PTSO.Failure := Failure is Error ? Failure
			: Error("An asynchronous child failure was observed: " . Type(Failure))
	try FileAppend("DIAG personal-toml-startup async type=" . Type(Failure)
		. " file=" . OwnerFile . " line=" . OwnerLine . " mode=" . Mode . "`n", "*", "UTF-8")
	Stack := Error("Observer frame").Stack
	for Line in StrSplit(SubStr(Stack, 1, 2048), "`n", "`r")
		try FileAppend("DIAG personal-toml-startup observer-stack " . Line . "`n", "*", "UTF-8")
	return true
}

_PTSO_FilesUnchanged() {
	global _PTSO
	for FilePath in _PTSO.Files
		if !_PTSO.Images.Has(FilePath)
			|| !(CryptoSha256Bytes(FSReadBytesStrict(FilePath)) == _PTSO.Images[FilePath])
			return false
	return true
}

_PTSO_Observe() {
	global _PTSO, _HsEdWeb_Gui, _HsEdWeb_ResetDone, _HsEdWeb_SessionEpoch
	global _HsEdWeb_Controller, _HsEdWeb_WebView, _HsEdWeb_MsgSub, _HsEdWeb_NavSub
	global _PersonalEditorSessionEpoch
	FileAppend("RECEIPT personal-toml-startup mode=" . _PTSO.Mode
		. " windows=" . _PTSO.Windows.Length . " controllers=" . _PTSO.Controllers.Length
		. " boundary_failure=" . IsObject(_PTSO.Failure) . " fallback_attempts=" . _PTSO.FallbackAttempts . " close_sent=" . _PTSO.CloseSent . " old_closed=" . _PTSO.Controllers[1].Closed
		. " old_subscriptions=" . _PTSO.Controllers[1].CoreWebView2.Subscriptions
		. " old_navigations=" . _PTSO.Controllers[1].CoreWebView2.Navigations
		. " reset=" . _HsEdWeb_ResetDone . " epoch=" . _HsEdWeb_SessionEpoch
		. " has_controller=" . IsSet(_HsEdWeb_Controller) . " has_view=" . IsSet(_HsEdWeb_WebView)
		. " has_message=" . IsSet(_HsEdWeb_MsgSub) . " has_navigation=" . IsSet(_HsEdWeb_NavSub)
		. " native_epoch=" . _PersonalEditorSessionEpoch . " files_unchanged=" . _PTSO_FilesUnchanged()
		. " gui=" . IsObject(_HsEdWeb_Gui) . "`n", "*", "UTF-8")
}

_PTSO_Check() {
	global _PTSO, _HsEdWeb_Gui, _HsEdWeb_ResetDone
	global _HsEdWeb_Controller, _HsEdWeb_WebView, _HsEdWeb_MsgSub, _HsEdWeb_NavSub
	global _PersonalEditorSessionEpoch, _PersonalEditorGui
	_PTSO_Require(_PersonalEditorSessionEpoch == 0 && !IsObject(_PersonalEditorGui),
		"The web startup controls do not admit a native fallback window.")
	_PTSO_Require(_PTSO_FilesUnchanged(), "No startup or Close path may mutate the private source/preferences.")
	if IsObject(_PTSO.Failure)
		throw _PTSO.Failure
	if _PTSO.Mode == "current" {
		_PTSO_Require(_PTSO.Controllers.Length == 1 && _PTSO.Windows.Length == 1,
			"The current positive must open exactly one web personal editor without native fallback.")
		_PTSO_Require(_HsEdWeb_Controller == _PTSO.Controllers[1]
			&& _HsEdWeb_WebView == _PTSO.Controllers[1].CoreWebView2
			&& _PTSO.Controllers[1].CoreWebView2.Subscriptions == 2,
			"A current construction must retain its real message and navigation subscriptions.")
		_PTSO_Require(_PTSO.Controllers[1].CoreWebView2.Navigations == 1
			&& _PTSO.Controllers[1].Fills >= 1 && !_HsEdWeb_ResetDone,
			"The current positive must navigate/fill its admitted controller.")
		_PTSO_NativeClose(_PTSO.Hwnds[1])
		_PTSO_Require(_PTSO.Controllers[1].Closed == 1,
			"The genuine current Close must retire its published controller.")
	} else {
		Reopened := InStr(_PTSO.Mode, "reopen") != 0
		_PTSO_Require(_PTSO.CloseSent == 1 && _PTSO.Windows.Length == (Reopened ? 2 : 1),
			"A consumed Close must never reopen the legacy native fallback.")
		_PTSO_Require(_PTSO.Controllers[1].Closed == 1,
			"A controller returned after its native window closed must retire exactly once.")
		_PTSO_Require(_PTSO.Controllers[1].CoreWebView2.Subscriptions == 0
			&& _PTSO.Controllers[1].CoreWebView2.Navigations == 0,
			"An old constructor must never subscribe or navigate after its owner retired.")
		if Reopened {
			_PTSO_Require(_HsEdWeb_Gui == _PTSO.Windows[2]
				&& DllCall("User32\IsWindowVisible", "Ptr", _PTSO.Hwnds[2], "Int")
				&& _HsEdWeb_Controller == _PTSO.Controllers[2]
				&& _HsEdWeb_WebView == _PTSO.Controllers[2].CoreWebView2
				&& !_HsEdWeb_ResetDone && _PTSO.Controllers[2].Closed == 0,
				"The resumed old frame must preserve the entire replacement session.")
			_PTSO_Require(_PTSO.Controllers[2].CoreWebView2.Subscriptions == 2
				&& _PTSO.Controllers[2].CoreWebView2.Navigations == 1 && _PTSO.Controllers[2].Fills >= 1,
				"The replacement must retain both subscriptions and its current navigation.")
			_PTSO_NativeClose(_PTSO.Hwnds[2])
			_PTSO_Require(_PTSO.Controllers[2].Closed == 1,
				"The replacement remains independently closable after the old frame resumes.")
		} else {
			_PTSO_Require(!IsObject(_HsEdWeb_Gui) && _HsEdWeb_ResetDone
				&& !IsSet(_HsEdWeb_Controller) && !IsSet(_HsEdWeb_WebView)
				&& !IsSet(_HsEdWeb_MsgSub) && !IsSet(_HsEdWeb_NavSub),
				"A canceled constructor must leave no published browser, subscriptions or callback.")
		}
	}
	_PTSO_Require(_PTSO_FilesUnchanged(), "The actual native Close must preserve every private source byte.")
}

_PTSO_Main() {
	global _PTSO, _SharedDir, ScriptInformation, ConfigurationFile
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	_PTSO := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Pending: 0,
		Boundary: 0, Failure: 0, CloseSent: 0, OldEpoch: 0, FallbackAttempts: 0, Images: Map() }
	_PTSO_Require(_PTSO.Mode == "current" || _PTSO.Mode == "close-create" || _PTSO.Mode == "reopen-create",
		"Only the three declared successful-constructor modes are admitted.")
	global _VendorDir := A_Args[2], _SharedDir := A_Args[2], _I18nLocale := "en"
	ConfigurationFile := A_Args[2] . "\config.toml"
	ScriptInformation := Map("PersonalTomlPath", A_Args[2] . "\personal_hotstrings.toml",
		"PersonalInfoTomlPath", A_Args[2] . "\personal_info.toml",
		"PersonalHotstringsDir", A_Args[2] . "\", "MagicKey", Chr(0x2605))
	_PTSO.Files := Map(ConfigurationFile, "[personal_editor]`nclose_on_add = false`n",
		ScriptInformation["PersonalTomlPath"], '[_meta]`nsections_order = ["alpha"]`n[[alpha]]`n"private_alpha" = "Private output"`n',
		ScriptInformation["PersonalInfoTomlPath"], '[information]`nprivate_name = "Private value"`n')
	Primary := 0, Observed := false
	OnError(_PTSO_OnError)
	try {
		for FilePath, Content in _PTSO.Files {
			_PTSO_Require(FSWriteCreateDurable(FilePath, Content) != 0, "Every private sentinel must be created exclusively.")
			_PTSO.Images[FilePath] := CryptoSha256Bytes(FSReadBytesStrict(FilePath))
		}
		_PTSO_Require(PersonalTomlPath() == ScriptInformation["PersonalTomlPath"]
			&& PersonalInfoTomlPath() == ScriptInformation["PersonalInfoTomlPath"],
			"The genuine path helpers must resolve only the configured private files.")
		OpenPersonalEditor("alpha")
		_PTSO_Observe()
		Observed := true
		_PTSO_Check()
	} catch as Failure {
		; An unexpected boundary failure may lead the old frame to fallback. Keep
		; that earlier transport/prerequisite failure above the fallback oracle.
		Primary := IsObject(_PTSO.Failure) ? _PTSO.Failure : Failure
	} finally {
		; Preserve a forbidden fallback attempt as a business observation before
		; any safety cleanup changes the subject's published resource counters.
		if !Observed && _PTSO.Controllers.Length > 0 {
			try _PTSO_Observe()
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			if HasMethod(_PTSO.Boundary, "Call")
				SetTimer(_PTSO.Boundary, 0)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try _HsEdWeb_Close()
		catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		for Controller in _PTSO.Controllers {
			try {
				if Controller.Closed == 0
					Controller.Close()
			} catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		for Index, Window in _PTSO.Windows {
			try {
				if DllCall("User32\IsWindow", "Ptr", _PTSO.Hwnds[Index], "Int")
					Window.Destroy()
			} catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		for Hwnd in _PTSO.Hwnds {
			try _PTSO_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every private native window must retire.")
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		_PTSO.Pending := 0, _PTSO.Boundary := 0
		OnError(_PTSO_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_PTSO.Failure)
		Primary := _PTSO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS personal-toml-startup " . _PTSO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_PTSO_Main()
