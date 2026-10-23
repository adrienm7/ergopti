; tests/fixtures/error_dialog_startup_owner_body.ahk

; ==============================================================================
; MODULE: Error Dialog Startup Owner Component
; DESCRIPTION:
; Actual logger/policy/presenter timers and HealthCheck phase A run in isolation.
; Native WM_CLOSE retires a published GUI during vendored WebView2.create await.
; Only the SDK environment/controller objects are passive. No Edge or boot claim.
; ==============================================================================

#Requires AutoHotkey v2.0

_EDOS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_EDOS_Failure(Failure) {
	global _EDOS
	if !IsObject(_EDOS.Failure)
		_EDOS.Failure := Failure
}

_EDOS_OnError(Failure, Mode) {
	_EDOS_Failure(Failure)
	try FileAppend("DIAG error-startup async type=" . Type(Failure) . " file=" . Failure.File
		. " line=" . Failure.Line . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

; Real SDK calls receive passive typed objects, never synthetic native handles.
class _EDOS_Core {
	__New() {
		this.Settings := {}, this.Subscriptions := 0, this.Navigations := 0, this.Scripts := 0
	}
	WebMessageReceived(Callback) {
		this.Subscriptions += 1
		return {Callback: Callback}
	}
	AddScriptToExecuteOnDocumentCreated(*) => 0
	SetVirtualHostNameToFolderMapping(*) => 0
	Navigate(Url) {
		_EDOS_Require(InStr(Url, "https://ergopti.errordialog/") == 1, "The actual error page must be selected.")
		this.Navigations += 1
	}
	ExecuteScriptAsync(Script) {
		this.Scripts += 1
		return Promise.resolve("null")
	}
}

class _EDOS_Controller {
	__New() {
		this.CoreWebView2 := _EDOS_Core(), this.Closed := 0, this.Fills := 0
	}
	Close() {
		this.Closed += 1
		_EDOS_Require(this.Closed == 1, "An exact passive controller must retire only once.")
	}
	Fill() {
		this.Fills += 1
	}
}

class _EDOS_Environment {
	CreateCoreWebView2ControllerAsync(Hwnd) {
		return _EDOS_Create(Hwnd)
	}
}

_EDOS_EnvironmentFactory(Sdk, Options, UserData, Arguments, Loader) {
	global _EDOS, WEBVIEW_SHARED_UDIR, _VendorDir
	_EDOS_Require(Sdk == WebView2 && Options == 0 && Arguments == ""
		&& UserData == WEBVIEW_SHARED_UDIR && Loader == _VendorDir . "\64bit\WebView2Loader.dll",
		"The real shared helper must call the existing four-argument SDK factory.")
	_EDOS.EnvironmentCalls += 1
	return Promise.resolve(_EDOS.Environment)
}

_EDOS_Log(Line) {
	global _EDOS
	try {
		_EDOS.Logs.Push(Line)
		if InStr(Line, "[SUCCESS] [ErrorDialog] Error window opened.")
			_EDOS.Opened += 1
		if InStr(Line, "[ERROR] [EDStartupA]")
			_EDOS.SourceErrors += 1
	} catch Any as Failure {
		_EDOS_Failure(Failure)
	}
}

_EDOS_Ready(Page) {
	global _ED_Gui, _ED_Controller, _ED_WebView, _ED_Session, _ED_ResetDone
	return IsSet(_ED_Gui) && _ED_Gui == Page.Window && IsSet(_ED_Controller) && _ED_Controller == Page.Controller
		&& IsSet(_ED_WebView) && _ED_WebView == Page.Controller.CoreWebView2 && !_ED_ResetDone
		&& _ED_Session is Map && Page.Controller.Closed == 0
		&& DllCall("User32\IsWindowVisible", "Ptr", Page.Hwnd, "Int")
		&& Page.Controller.CoreWebView2.Subscriptions == 1 && Page.Controller.CoreWebView2.Navigations == 1
		&& Page.Controller.Fills >= 1
}

_EDOS_Create(Hwnd) {
	global _EDOS, _ED_Gui, _ED_WindowEpoch, _ED_Session
	_EDOS_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "The SDK port must receive a real placeholder HWND.")
	Parent := DllCall("User32\GetParent", "Ptr", Hwnd, "Ptr"), Window := GuiFromHwnd(Parent)
	_EDOS_Require(IsSet(_ED_Gui) && _ED_Gui == Window
		&& DllCall("User32\IsWindowVisible", "Ptr", Parent, "Int"),
		"The actual error GUI must already be visible and published before create awaits.")
	Page := {Window: Window, Hwnd: Parent, Controller: _EDOS_Controller(), Epoch: _ED_WindowEpoch}
	_EDOS.Pages.Push(Page)
	if _EDOS.Pages.Length > 1 || _EDOS.Mode == "current"
		return Promise.resolve(Page.Controller)
	_EDOS.Pending := Promise.withResolvers()
	; An independent observer prevents Promise.task's unobserved-rejection error;
	; the original rejecting await and its exact failure are never replaced.
	_EDOS.Pending.promise.onSettled((*) => 0, (*) => 0)
	SetTimer(_EDOS.Timeout, -3000)
	SetTimer(_EDOS.Actor, -1)
	return _EDOS.Pending.promise
}

_EDOS_NativeClose(Page) {
	global _ED_WindowEpoch
	Before := _ED_WindowEpoch
	_EDOS_Require(DllCall("User32\IsWindow", "Ptr", Page.Hwnd, "Int"), "Native Close needs the exact live private HWND.")
	DllCall("User32\SendMessageW", "Ptr", Page.Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while (DllCall("User32\IsWindow", "Ptr", Page.Hwnd, "Int") || _ED_WindowEpoch <= Before)
		&& TickElapsed64(Started) < 1000
		Sleep(10)
	_EDOS_Require(!DllCall("User32\IsWindow", "Ptr", Page.Hwnd, "Int") && _ED_WindowEpoch > Before,
		"The native Close callback must destroy the real GUI and revoke its epoch.")
}

_EDOS_Timeout() {
	global _EDOS
	Failure := Error("The controlled constructor actor did not complete within 3000 ms.")
	_EDOS_Failure(Failure)
	_EDOS.Pending.reject.Call(Failure)
}

_EDOS_Actor() {
	global _EDOS, _ED_ResetDone, _ED_Session, _ED_Busy, _ED_WindowEpoch
	try {
		_EDOS_NativeClose(_EDOS.Pages[1])
		_EDOS.CloseAck += 1
		_EDOS_Require(_ED_ResetDone && !(_ED_Session is Map) && !_ED_Busy,
			"The real Close must retire session and policy ownership before completion.")
		if InStr(_EDOS.Mode, "reopen") {
			LoggerError("EDStartupB", "Controlled successor error B")
			Started := A_TickCount
			while (_EDOS.Pages.Length < 2 || !_EDOS_Ready(_EDOS.Pages[2])) && TickElapsed64(Started) < 2000 {
				if IsObject(_EDOS.Failure)
					throw _EDOS.Failure
				Sleep(10)
			}
			_EDOS_Require(_EDOS.Pages.Length >= 2 && _EDOS_Ready(_EDOS.Pages[2]),
				"The successor must genuinely open through LoggerError and its real presenter timer.")
			_EDOS.Successor := {Page: _EDOS.Pages[2], Epoch: _ED_WindowEpoch, Session: _ED_Session}
		}
		SetTimer(_EDOS.Timeout, 0)
		if InStr(_EDOS.Mode, "reject")
			_EDOS.Pending.reject.Call(Error("Controlled retired error browser construction refusal"))
		else
			_EDOS.Pending.resolve.Call(_EDOS.Pages[1].Controller)
		_EDOS.ActorDone := true
	} catch Any as Failure {
		_EDOS_Failure(Failure)
		_EDOS.Pending.reject.Call(Failure)
	}
}

_EDOS_Observe() {
	global _EDOS, _ED_ResetDone, _ED_WindowEpoch, _ED_Folded
	Page := _EDOS.Pages.Length ? _EDOS.Pages[1] : 0
	FileAppend("RECEIPT error-dialog-startup mode=" . _EDOS.Mode . " pages=" . _EDOS.Pages.Length
		. " environment_calls=" . _EDOS.EnvironmentCalls . " source_errors=" . _EDOS.SourceErrors
		. " actor_done=" . _EDOS.ActorDone . " close_ack=" . _EDOS.CloseAck
		. " boundary_failure=" . IsObject(_EDOS.Failure) . " opened=" . _EDOS.Opened
		. " old_closed=" . (IsObject(Page) ? Page.Controller.Closed : -1)
		. " old_subscriptions=" . (IsObject(Page) ? Page.Controller.CoreWebView2.Subscriptions : -1)
		. " old_navigations=" . (IsObject(Page) ? Page.Controller.CoreWebView2.Navigations : -1)
		. " reset=" . _ED_ResetDone . " epoch=" . _ED_WindowEpoch . " folded=" . _ED_Folded . "`n", "*", "UTF-8")
}

_EDOS_Check() {
	global _EDOS, _ED_WindowEpoch, _ED_Session, _ED_Gui, _ED_Controller, _ED_WebView, _ED_MsgSub, _ED_ResetDone
	if IsObject(_EDOS.Failure)
		throw _EDOS.Failure
	_EDOS_Require(_EDOS.EnvironmentCalls == 1 && _EDOS.SourceErrors == 1 && _EDOS.Pages.Length >= 1,
		"The real public logger, shared SDK helper and GUI constructor must be reached.")
	A := _EDOS.Pages[1]
	_EDOS_Require(InStr(FSReadStrict(LoggerTodayErrorsPath()), "[EDStartupA] Controlled source error A") > 0,
		"The genuine source error must reach the actual private errors file.")
	if _EDOS.Mode == "current" {
		_EDOS_Require(_EDOS.Pages.Length == 1 && _EDOS_Ready(A), "The current positive must retain its complete open session.")
		_EDOS_Require(_ED_Session["snapshot"]["schema_version"] == 2
			&& _ED_Session["snapshot"]["sections"]["issues"]["recent_source"] == "errors_file"
			&& InStr(_ED_Session["report"]["text"], "Controlled source error A") > 0
			&& _ED_Session["log_path"] == LoggerTodayErrorsPath(),
			"The true phase-A report must retain the source error and its private log path.")
		_EDOS_NativeClose(A)
		_EDOS_Require(A.Controller.Closed == 1, "The current controller must retire through actual native Close.")
		return
	}
	_EDOS_Require(_EDOS.ActorDone && _EDOS.CloseAck == 1, "Cancellation must occur at the genuine constructor wait.")
	if InStr(_EDOS.Mode, "reject")
		_EDOS_Require(_EDOS.Pending.promise.status == "rejected" && _EDOS.Pending.promise.result is Error,
			"The controlled failure must remain an actual rejected Promise.")
	if !InStr(_EDOS.Mode, "reject")
		_EDOS_Require(A.Controller.Closed == 1, "A controller returned after Close must retire exactly once.")
	_EDOS_Require(A.Controller.CoreWebView2.Subscriptions == 0 && A.Controller.CoreWebView2.Navigations == 0,
		"A retired constructor must never publish subscriptions or navigate its old page.")
	if InStr(_EDOS.Mode, "reopen") {
		B := _EDOS.Successor
		; A creation failure can legitimately fold another error into B. Its
		; counters/scripts may change; its exact live owner must remain admitted.
		_EDOS_Require(_EDOS_Ready(B.Page) && _ED_WindowEpoch == B.Epoch && _ED_Session == B.Session,
			"The old completion must preserve the successor's exact live GUI/controller/core/session/epoch.")
		_EDOS_NativeClose(B.Page)
		_EDOS_Require(B.Page.Controller.Closed == 1, "The successor must remain independently closable.")
	}
	if _EDOS.Mode == "close-resolve"
		_EDOS_Require(!IsSet(_ED_Gui) && !IsSet(_ED_Controller) && !IsSet(_ED_WebView)
			&& !IsSet(_ED_MsgSub) && _ED_ResetDone && !(_ED_Session is Map),
			"Canceled fulfillment must leave no published old browser or session.")
	if _EDOS.Mode == "close-reject" && _ED_Session is Map
		_EDOS_Require(_ED_Session["record"]["module"] != "EDStartupA",
			"A genuine new error may open, but the rejected A session must stay retired.")
	_EDOS_Require(!DllCall("User32\IsWindow", "Ptr", A.Hwnd, "Int"), "The original native HWND must remain destroyed.")
}

_EDOS_Cleanup() {
	global _EDOS
	SetTimer(_EDOS.Actor, 0), SetTimer(_EDOS.Timeout, 0)
	; This is safety cleanup after the business receipt, not the Close actor.
	try _ErrorDialog_CloseWindow()
	catch Any as Failure
		_EDOS_Failure(Failure)
	for Page in _EDOS.Pages {
		try {
			if Page.Controller.Closed == 0
				Page.Controller.Close()
		} catch Any as Failure {
			_EDOS_Failure(Failure)
		}
		try {
			if DllCall("User32\IsWindow", "Ptr", Page.Hwnd, "Int")
				Page.Window.Destroy()
			_EDOS_Require(!DllCall("User32\IsWindow", "Ptr", Page.Hwnd, "Int"), "Every acquired real error GUI must retire.")
		} catch Any as Failure {
			_EDOS_Failure(Failure)
		}
	}
	try {
		_EDOS_Require(LoggerPrepareShutdown() == true, "The real private logger must flush before child exit.")
		SetTimer(_LoggerFlush, 0)
		OnExit(_LoggerOnExitFlush, 0)
	} catch Any as Failure {
		_EDOS_Failure(Failure)
	}
	_EDOS.Pending := 0
}

_EDOS_Main() {
	global _EDOS, _EDOS_Root, _DriverBootPhase, _DriverStartupSmokeDir, WEBVIEW_SHARED_UDIR, Features, _VendorDir
	if A_Args.Length != 2 || A_Args[2] != _EDOS_Root
		ExitApp(2)
	Persistent(true)
	_EDOS := {Mode: A_Args[1], Pages: [], Logs: [], Environment: _EDOS_Environment(), EnvironmentCalls: 0,
		Failure: 0, Pending: 0, Actor: _EDOS_Actor, Timeout: _EDOS_Timeout, ActorDone: false,
		CloseAck: 0, Successor: 0, Opened: 0, SourceErrors: 0}
	Primary := 0, Observed := false, PreviousCritical := Critical("Off"), PreviousSuspend := A_IsSuspended
	Thread("Interrupt", 0)
	Suspend(false)
	OnError(_EDOS_OnError)
	OriginalFactory := WebView2.GetOwnPropDesc("CreateEnvironmentAsync")
	try {
		; Component inputs only: no driver boot/config writer is being certified.
		_DriverBootPhase := "ready", _DriverStartupSmokeDir := ""
		Features := ManifestBuildFeaturesMap()
		WEBVIEW_SHARED_UDIR := _EDOS_Root . "\profile"
		WebView2.DefineProp("CreateEnvironmentAsync", {Call: _EDOS_EnvironmentFactory})
		LoggerInit()
		LoggerSetTestSink(_EDOS_Log)
		Cache := Map("script", Map("show_error_dialog", 1))
		_EDOS_Require(ErrorDialog_Init(Cache), "The true public initializer must admit the shipped policy.")
		Warm := WebView_SharedEnvironment(_VendorDir . "\64bit\WebView2Loader.dll")
		_EDOS_Require(Warm == _EDOS.Environment, "Only the genuine shared helper may publish the passive environment.")
		LoggerError("EDStartupA", "Controlled source error A")
		Started := A_TickCount
		; Main cannot resume from the presenter's interrupt until its Open stack
		; has unwound. ActorDone alone, observed inside that actor, is not an ACK.
		while _EDOS.Pages.Length == 0 && TickElapsed64(Started) < 5000
			Sleep(10)
		_EDOS_Observe(), Observed := true
		_EDOS_Check()
	} catch Any as Failure {
		Primary := IsObject(_EDOS.Failure) ? _EDOS.Failure : Failure
	} finally {
		if !Observed {
			try _EDOS_Observe()
			catch Any as Failure
				_EDOS_Failure(Failure)
		}
		try _EDOS_Cleanup()
		catch Any as Failure
			_EDOS_Failure(Failure)
		try LoggerClearTestSink()
		catch Any as Failure
			_EDOS_Failure(Failure)
		try WebView2.DefineProp("CreateEnvironmentAsync", OriginalFactory)
		catch Any as Failure
			_EDOS_Failure(Failure)
		OnError(_EDOS_OnError, 0)
		Suspend(PreviousSuspend), Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_EDOS.Failure)
		Primary := _EDOS.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS error-dialog-startup " . _EDOS.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_EDOS_Main()
