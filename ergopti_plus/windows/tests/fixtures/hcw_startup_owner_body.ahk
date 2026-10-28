; tests/fixtures/hcw_startup_owner_body.ahk

; ==============================================================================
; MODULE: Hotstrings Config Startup Owner Child
; DESCRIPTION:
; Runs the real public config editor, its genuine singleton lifecycle and native GUI and the genuine catalogue builders.
; Browser construction is a passive port that awaits the shipped Promise and
; receives a real WM_CLOSE before returning. No Edge or physical input claim.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCWS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; Translation/theming and browser construction are explicit passive ports. The
; real helper owner builds categories/groups from the actual private TOML index.
t(Key) => Key
LoggerSuccess(*) => 0
LoggerError(*) => 0
WebView_SharedEnvironment(Loader) => { Passive: true }

Gui_Create(Options := "", Title := "") {
	global _HCWS
	Window := Gui(Options, Title)
	_HCWS.Windows.Push(Window), _HCWS.Hwnds.Push(Window.Hwnd)
	; A retired open returning false reaches the public native fallback. Observe
	; its real new HWND, then fail this forbidden path before unrelated native
	; controls/data can introduce a prerequisite failure instead of the oracle.
	Limit := InStr(_HCWS.Mode, "reopen") ? 2 : 1
	if _HCWS.Windows.Length > Limit {
		_HCWS.FallbackAttempts += 1
		throw Error("Business oracle: a retired web opening attempted native fallback.")
	}
	return Window
}

class WebView2 {
	static create(Hwnd, Callback?, Environment := 0) {
		_HCWS_Require(!IsSet(Callback) && Environment.Passive,
			"The production call must use its synchronous constructor contract.")
		return _HCWS_Create(Hwnd)
	}
}

class _HCWS_View {
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

class _HCWS_Controller {
	__New() {
		this.CoreWebView2 := _HCWS_View(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
	}
	Fill() {
		this.Fills += 1
	}
}

_HCWS_Create(Hwnd) {
	global _HCWS, _HCWWeb_Gui
	_HCWS_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
		"The controlled browser receives a genuine native placeholder.")
	_HCWS_Require(IsObject(_HCWWeb_Gui)
		&& DllCall("User32\IsWindowVisible", "Ptr", _HCWWeb_Gui.Hwnd, "Int"),
		"The browser wait begins only after the genuine config editor is visible and published.")
	Controller := _HCWS_Controller()
	_HCWS.Controllers.Push(Controller)
	if _HCWS.Controllers.Length > 1 || _HCWS.Mode == "current"
		return Controller
	_HCWS.Pending := Promise.withResolvers()
	; The timer port has an independent settlement consumer so Promise.task does
	; not report an unobserved rejection before the suspended await resumes.
	; These callbacks never change its state or replace the rejecting await.
	_HCWS.Pending.promise.onSettled((*) => 0, (*) => 0)
	_HCWS.Boundary := _HCWS_CloseDuringCreate
	SetTimer(_HCWS.Boundary, -1)
	return _HCWS.Pending.promise.await(3000)
}

_HCWS_NativeClose(Hwnd) {
	global _HCWWeb_SessionEpoch
	Epoch := _HCWWeb_SessionEpoch
	_HCWS_Require(DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int"),
		"Native WM_CLOSE must address this visible admitted config window.")
	DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while (DllCall("User32\IsWindow", "Ptr", Hwnd, "Int") || _HCWWeb_SessionEpoch <= Epoch)
		&& ((A_TickCount - Started) & 0xFFFFFFFF) < 1000
		Sleep(10)
	_HCWS_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int") && _HCWWeb_SessionEpoch > Epoch,
		"The actual Close event must destroy the window and revoke its session.")
}

_HCWS_CloseDuringCreate() {
	global _HCWS, _HCWWeb_SessionEpoch
	try {
		_HCWS.OldEpoch := _HCWWeb_SessionEpoch
		_HCWS.CloseSent += 1
		_HCWS_NativeClose(_HCWS.Hwnds[1])
		if InStr(_HCWS.Mode, "reopen") {
			OpenHotstringsConfigWindow()
			_HCWS_Require(_HCWS.Windows.Length == 2 && _HCWS.Controllers.Length == 2,
				"A replacement must use the same genuine public constructor.")
		}
		if InStr(_HCWS.Mode, "reject")
			_HCWS.Pending.reject.Call(Error("Controlled retired config browser construction refusal"))
		else
			_HCWS.Pending.resolve.Call(_HCWS.Controllers[1])
	} catch as Failure {
		if !IsObject(_HCWS.Failure)
			_HCWS.Failure := Failure
		_HCWS.Pending.reject.Call(Failure)
	}
}

; An asynchronous exception cannot cross the suspended Main try/catch. Suppress
; its modal only after retaining it as a mandatory failure, never as success.
_HCWS_OnError(Failure, Mode) {
	global _HCWS
	OwnerFile := "UNKNOWN", OwnerLine := 0
	if Failure is Error {
		SplitPath(Failure.File, &OwnerFile)
		OwnerLine := Failure.Line
	}
	if !IsObject(_HCWS.Failure)
		_HCWS.Failure := Failure is Error ? Failure
			: Error("An asynchronous child failure was observed: " . Type(Failure))
	try FileAppend("DIAG hcw-startup async type=" . Type(Failure)
		. " file=" . OwnerFile . " line=" . OwnerLine . " mode=" . Mode . "`n", "*", "UTF-8")
	Stack := Error("Observer frame").Stack
	for Line in StrSplit(SubStr(Stack, 1, 2048), "`n", "`r")
		try FileAppend("DIAG hcw-startup observer-stack " . Line . "`n", "*", "UTF-8")
	return true
}

_HCWS_Observe() {
	global _HCWS, _HCWWeb_Gui, _HCWWeb_ResetDone, _HCWWeb_SessionEpoch
	global _HCWWeb_Controller, _HCWWeb_WebView, _HCWWeb_MsgSub, _HCWWeb_NavSub
	FileAppend("RECEIPT hcw-startup mode=" . _HCWS.Mode
		. " windows=" . _HCWS.Windows.Length . " controllers=" . _HCWS.Controllers.Length
		. " boundary_failure=" . IsObject(_HCWS.Failure) . " fallback_attempts=" . _HCWS.FallbackAttempts . " close_sent=" . _HCWS.CloseSent . " old_closed=" . _HCWS.Controllers[1].Closed
		. " old_subscriptions=" . _HCWS.Controllers[1].CoreWebView2.Subscriptions
		. " old_navigations=" . _HCWS.Controllers[1].CoreWebView2.Navigations
		. " reset=" . _HCWWeb_ResetDone . " epoch=" . _HCWWeb_SessionEpoch
		. " has_controller=" . IsSet(_HCWWeb_Controller) . " has_view=" . IsSet(_HCWWeb_WebView)
		. " has_message=" . IsSet(_HCWWeb_MsgSub) . " has_navigation=" . IsSet(_HCWWeb_NavSub)
		. " gui=" . IsObject(_HCWWeb_Gui) . "`n", "*", "UTF-8")
}

_HCWS_Check() {
	global _HCWS, _HCWWeb_Gui, _HCWWeb_ResetDone
	global _HCWWeb_Controller, _HCWWeb_WebView, _HCWWeb_MsgSub, _HCWWeb_NavSub
	if IsObject(_HCWS.Failure)
		throw _HCWS.Failure
	if _HCWS.Mode == "current" {
		_HCWS_Require(_HCWS.Controllers.Length == 1 && _HCWS.Windows.Length == 1,
			"The current positive must open exactly one web config editor without native fallback.")
		_HCWS_Require(_HCWWeb_Controller == _HCWS.Controllers[1]
			&& _HCWWeb_WebView == _HCWS.Controllers[1].CoreWebView2
			&& _HCWS.Controllers[1].CoreWebView2.Subscriptions == 2,
			"A current construction must retain its real message and navigation subscriptions.")
		_HCWS_Require(_HCWS.Controllers[1].CoreWebView2.Navigations == 1
			&& _HCWS.Controllers[1].Fills >= 1 && !_HCWWeb_ResetDone,
			"The current positive must navigate/fill its admitted controller.")
		_HCWS_NativeClose(_HCWS.Hwnds[1])
		_HCWS_Require(_HCWS.Controllers[1].Closed == 1,
			"The genuine current Close must retire its published controller.")
	} else {
		Reopened := InStr(_HCWS.Mode, "reopen") != 0
		_HCWS_Require(_HCWS.CloseSent == 1 && _HCWS.Windows.Length == (Reopened ? 2 : 1),
			"A consumed Close must never reopen the legacy native fallback.")
		if !InStr(_HCWS.Mode, "reject")
			_HCWS_Require(_HCWS.Controllers[1].Closed == 1,
				"A controller returned after its native window closed must retire exactly once.")
		_HCWS_Require(_HCWS.Controllers[1].CoreWebView2.Subscriptions == 0
			&& _HCWS.Controllers[1].CoreWebView2.Navigations == 0,
			"An old constructor must never subscribe or navigate after its owner retired.")
		if Reopened {
			_HCWS_Require(_HCWWeb_Gui == _HCWS.Windows[2]
				&& DllCall("User32\IsWindowVisible", "Ptr", _HCWS.Hwnds[2], "Int")
				&& _HCWWeb_Controller == _HCWS.Controllers[2]
				&& _HCWWeb_WebView == _HCWS.Controllers[2].CoreWebView2
				&& !_HCWWeb_ResetDone && _HCWS.Controllers[2].Closed == 0,
				"The resumed old frame must preserve the entire replacement session.")
			_HCWS_Require(_HCWS.Controllers[2].CoreWebView2.Subscriptions == 2
				&& _HCWS.Controllers[2].CoreWebView2.Navigations == 1 && _HCWS.Controllers[2].Fills >= 1,
				"The replacement must retain both subscriptions and its current navigation.")
			_HCWS_NativeClose(_HCWS.Hwnds[2])
			_HCWS_Require(_HCWS.Controllers[2].Closed == 1,
				"The replacement remains independently closable after the old frame resumes.")
		} else {
			_HCWS_Require(!IsObject(_HCWWeb_Gui) && _HCWWeb_ResetDone
				&& !IsSet(_HCWWeb_Controller) && !IsSet(_HCWWeb_WebView)
				&& !IsSet(_HCWWeb_MsgSub) && !IsSet(_HCWWeb_NavSub),
				"A canceled constructor must leave no published browser, subscriptions or callback.")
		}
	}
}

_HCWS_Main() {
	global _HCWS, _SharedDir, _HCWS_SourceShared, _HCW_CATEGORY_LIST, _HCW_GROUP_LIST
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	_HCWS := { Mode: A_Args[1], Windows: [], Hwnds: [], Controllers: [], Pending: 0,
		Boundary: 0, Failure: 0, CloseSent: 0, OldEpoch: 0, FallbackAttempts: 0 }
	global _VendorDir := A_Args[2], _SharedDir := A_Args[2] . "\shared", _I18nLocale := "en"
	global _ExtensionsDir := A_Args[2] . "\extensions"
	global ScriptInformation := Map("PersonalHotstringsDir", A_Args[2] . "\personal\")
	Primary := 0, Observed := false
	OnError(_HCWS_OnError)
	try {
		for Directory in [_SharedDir . "\modules\hotstrings", _ExtensionsDir, ScriptInformation["PersonalHotstringsDir"]]
			DirCreate(Directory)
		IndexSource := _HCWS_SourceShared . "\modules\hotstrings\_index.toml"
		IndexTarget := _SharedDir . "\modules\hotstrings\_index.toml"
		FileCopy(IndexSource, IndexTarget, false)
		IndexHash := CryptoSha256Bytes(FSReadBytesStrict(IndexSource))
		_HCWS_Require(RegExMatch(IndexHash, "^[0-9a-f]{64}$")
			&& CryptoSha256Bytes(FSReadBytesStrict(IndexTarget)) == IndexHash,
			"The genuine language index must be copied without changing its source image.")
		OpenHotstringsConfigWindow()
		_HCWS_Require(_HCW_CATEGORY_LIST.Length > 0 && _HCW_GROUP_LIST.Length >= 2,
			"The public path must run the genuine category/group initialization.")
		_HCWS_Observe()
		Observed := true
		_HCWS_Check()
	} catch as Failure {
		; A rejected boundary can cause the old frame to attempt fallback. Keep
		; that earlier transport/prerequisite failure above the fallback oracle.
		Primary := IsObject(_HCWS.Failure) ? _HCWS.Failure : Failure
	} finally {
		; Preserve a forbidden fallback attempt as a business observation before
		; any safety cleanup changes the subject's published resource counters.
		if !Observed && _HCWS.Controllers.Length > 0 {
			try _HCWS_Observe()
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			if HasMethod(_HCWS.Boundary, "Call")
				SetTimer(_HCWS.Boundary, 0)
			_HCWWeb_Close()
			for Controller in _HCWS.Controllers
				if Controller.Closed == 0
					Controller.Close()
			for Index, Window in _HCWS.Windows
				if DllCall("User32\IsWindow", "Ptr", _HCWS.Hwnds[Index], "Int")
					Window.Destroy()
			for Hwnd in _HCWS.Hwnds
				_HCWS_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every private native window must retire.")
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		_HCWS.Pending := 0, _HCWS.Boundary := 0
		OnError(_HCWS_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_HCWS.Failure)
		Primary := _HCWS.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS hcw-startup " . _HCWS.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_HCWS_Main()
