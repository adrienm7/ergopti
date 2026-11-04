; tests/fixtures/layer_editor_ready_delivery_body.ahk

; ==============================================================================
; MODULE: Layer Editor Ready Delivery Child
; DESCRIPTION:
; The real public layer editor registers its real ready callbacks at a passive
; SDK. Their genuine native one-shot dispatch is observed, never called by Main.
; Native Suspend and the genuine resume/menu reactor remain real. No DOM or
; ordinary browser timing is certified by this component.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRDS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

t(Key) => Key
WindowTitle(Label := "") => Label

Gui_Create(Options := "", Title := "") {
	global _LRDS
	Window := Gui(Options, Title)
	_LRDS.Windows.Push(Window)
	return Window
}

class WebView2 {
	static CreateEnvironmentAsync(BrowserFolder, UserDataFolder, Options, Loader) {
		global _LRDS, WEBVIEW_SHARED_UDIR
		_LRDS_Require(BrowserFolder == 0 && UserDataFolder == WEBVIEW_SHARED_UDIR
			&& UserDataFolder == A_Args[2] . "\profile" && Options == ""
			&& Loader == A_Args[2] . "\64bit\WebView2Loader.dll",
			"The actual shared environment may acquire only this private passive SDK.")
		_LRDS.Environments += 1
		Resolved := Promise.withResolvers()
		Resolved.resolve.Call({Passive: true})
		return Resolved.promise
	}
	static create(Hwnd, Callback?, Environment := 0) {
		global _LRDS
		_LRDS_Require(!IsSet(Callback) && Environment.Passive
			&& DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"),
			"The passive SDK must receive the genuine native placeholder.")
		Controller := _LRDS_Controller()
		_LRDS.Controllers.Push(Controller)
		return Controller
	}
}

class _LRDS_Settled {
	onSettled(Success, Failure) {
		Success.Call("")
	}
}

class _LRDS_Subscription {
	__New(View, Kind, Callback) {
		this.View := View, this.Kind := Kind
		View.Active += 1
		View.Callbacks[Kind] := Callback
	}
	__Delete() {
		this.View.Active -= 1
		this.View.Callbacks.Delete(this.Kind)
	}
}

class _LRDS_View {
	__New() {
		this.Settings := {}, this.Callbacks := Map(), this.Active := 0
		this.Scripts := [], this.Init := [], this.Navigations := 0
	}
	WebMessageReceived(Callback) => _LRDS_Subscription(this, "message", Callback)
	NavigationCompleted(Callback) => _LRDS_Subscription(this, "navigation", Callback)
	SetVirtualHostNameToFolderMapping(*) => 0
	AddScriptToExecuteOnDocumentCreated(*) => 0
	Navigate(Url) {
		this.Navigations += 1
	}
	ExecuteScriptAsync(Js) {
		global _LRDS
		this.Scripts.Push(Js)
		Prefix := "if(window.init)window.init("
		if SubStr(Js, 1, StrLen(Prefix)) == Prefix {
			_LRDS_Require(SubStr(Js, -1) == ")", "The actual init projection must preserve its JSON envelope.")
			Data := JsonParse(SubStr(Js, StrLen(Prefix) + 1, StrLen(Js) - StrLen(Prefix) - 1))
			_LRDS_Require(Data is Map && Data["os"] == "windows"
				&& Data["path"] == _LRDS.LayerPath && Data["text"] == _LRDS.LayerText
				&& Data["errors"] is Array && Data["errors"].Length == 0,
				"Only the genuine layer projection of the exact private file can qualify as initialization.")
			this.Init.Push(Data)
		}
		return _LRDS_Settled()
	}
}

class _LRDS_Controller {
	__New() {
		this.CoreWebView2 := _LRDS_View(), this.Closed := 0, this.Fills := 0, this.ActiveAtClose := -1
	}
	Close() {
		this.Closed += 1
		this.ActiveAtClose := this.CoreWebView2.Active
	}
	Fill() {
		this.Fills += 1
	}
}

; Observe the actual timer's dynamically bound method while delegating once to
; the genuine production method. Main never invokes a ready dispatch directly.
_LRDS_Dispatch(Record, Host, Params*) {
	global _LRDS
	Record.Calls += 1, Record.InFlight := true
	try {
		_LRDS_Require(Host == Record.Host && Params.Length == 1,
			"The actual SDK-triggered timer must retain its exact host and epoch ABI.")
		Record.LastEpoch := Params[1]
		Record.Paused := A_IsSuspended
		if A_IsSuspended
			Record.PausedCalls += 1
		WebViewHost.Prototype._DispatchReady.Call(Host, Params*)
	} catch as Failure {
		if !IsObject(_LRDS.Failure)
			_LRDS.Failure := Failure
		throw
	} finally {
		Record.InFlight := false
		Record.Settled += 1
	}
}

_LRDS_Open() {
	global _LRDS, LAYER_EDITOR_APP_ID
	_LRDS.PublicCalls += 1
	_LRDS_Require(LayerEditor_Open(), "The genuine public layer editor must open its native host.")
	_LRDS_Require(WebViewHost._Instances.Has(LAYER_EDITOR_APP_ID),
		"A live genuine singleton must be published after public construction.")
	Host := WebViewHost._Instances[LAYER_EDITOR_APP_ID]
	for Record in _LRDS.Records
		if Record.Host == Host
			return Record
	_LRDS_Require(Host.HasOwnProp("Controller") && Host.HasOwnProp("WebView")
		&& Host.Gui == _LRDS.Windows[_LRDS.Windows.Length]
		&& Host.Controller == _LRDS.Controllers[_LRDS.Controllers.Length]
		&& Host.WebView.Active == 2 && Host.WebView.Navigations == 1 && Host.Controller.Fills > 0,
		"The public native host must retain its genuine SDK registrations and browser publication.")
	Record := {Host: Host, View: Host.WebView, Controller: Host.Controller,
		Window: Host.Gui, Epoch: Host.Epoch, Calls: 0, Settled: 0, InFlight: false, LastEpoch: 0, Paused: false, PausedCalls: 0, EventSent: false}
	Record.Dispatch := _LRDS_Dispatch.Bind(Record)
	Host.DefineProp("_DispatchReady", {Call: Record.Dispatch})
	_LRDS.Records.Push(Record)
	return Record
}

_LRDS_ReadyEvent(Record) {
	global _LRDS
	_LRDS_Require(Record.View.Callbacks.Has("navigation"), "The SDK must retain the actual navigation callback.")
	Callback := Record.View.Callbacks["navigation"]
	_LRDS.NavigationEvents += 1
	Record.EventSent := true
	Callback.Call(Record.View, {})
}

_LRDS_Pump(Record, WantedDispatch, WantedInit) {
	global _LRDS
	Started := A_TickCount
	while !IsObject(_LRDS.Failure)
		&& (Record.Settled < WantedDispatch || Record.View.Init.Length < WantedInit)
		&& TickElapsed(Started) < 3000
		Sleep(5)
	if IsObject(_LRDS.Failure)
		throw _LRDS.Failure
}

_LRDS_Resume() {
	global _LRDS, _LifecycleLatestTransition, _LLM_MenuBuildCoordinator
	Suspend(false)
	_LRDS_Require(Ergopti_OnSuspendResume(), "The actual resume reactor must complete without retained owner debt.")
	_LRDS.Resumes += 1
	_LRDS_Require(_LifecycleLatestTransition.phase == "resume" && _LifecycleLatestTransition.finished
		&& _LifecycleLatestTransition.debt.Length == 0
		&& _LLM_MenuBuildCoordinator is LLMMenuBuildCoordinator,
		"The real resume/menu service graph must execute; an absent service cannot create a false stranded init.")
}


class _LRDS_SourceArgs {
	__New(Text) {
		this.Text := Text
	}
	TryGetWebMessageAsString() => this.Text
}

_LRDS_RefuseApply() {
	global _LRDS
	_LRDS.ApplyCalls += 1
	return false
}

_LRDS_SaveMessage(Host, Payload) {
	global _LRDS
	_LRDS.SaveEntered += 1
	try _LayerEditor_OnMessage(Host, Payload, _LRDS_RefuseApply)
	finally _LRDS.SaveReturned += 1
}

_LRDS_StaleSource(Record) {
	global _LRDS, _SharedDir
	_LRDS_Pump(Record, 1, 1)
	_LRDS_Require(Record.View.Init.Length == 1, "The old page must genuinely receive its original file before another editor publishes.")
	Original := Record.View.Init[1]["text"]
	_LRDS_Require(Original == _LRDS.LayerText, "The candidate comes from the actual original init projection.")
	; The canonical corpus round-trips byte-identically through the genuine
	; LayerModel.readLayerFile/serialize used by the shared page's Save button.
	; A no-edit save is an ordinary reachable producer, without invented fields.
	External := StrReplace(Original, '"KeyS" = "arrow_up"', '"KeyS" = "arrow_down"', , &Changed)
	_LRDS_Require(Changed == 1 && External != Original, "The independent edit changes an actual navigation binding.")
	Ctx := KeymapLayers_LoadContext(_SharedDir)
	_LRDS_Require(LayerEditor_Validate(External, Ctx).Length == 0, "The newer durable configuration must be valid on every OS.")
	_LRDS_Require(FSWriteDurable(_LRDS.LayerPath, External), "The independent editor must really publish the changed binding.")
	Record.Host.Opts["OnMessage"] := _LRDS_SaveMessage
	Message := '{"action":"save","text":' . JsonStringLiteral(Original) . '}'
	_LRDS_Require(Record.View.Callbacks.Has("message"), "The live SDK retains the genuine host bridge.")
	Callback := Record.View.Callbacks["message"]
	Callback.Call(Record.View, _LRDS_SourceArgs(Message))
	Started := A_TickCount
	while _LRDS.SaveReturned == 0 && !IsObject(_LRDS.Failure) && TickElapsed(Started) < 3000
		Sleep(5)
	if IsObject(_LRDS.Failure)
		throw _LRDS.Failure
	FileAppend("RECEIPT layer-source save_entered=" . _LRDS.SaveEntered . " save_returned=" . _LRDS.SaveReturned
		. " apply_calls=" . _LRDS.ApplyCalls . " newer_bytes_preserved=" . FSUtf8ExactMatches(_LRDS.LayerPath, External) . "`n", "*", "UTF-8")
	_LRDS_Require(_LRDS.SaveEntered == 1 && _LRDS.SaveReturned == 1, "Exactly one actual deferred message must settle.")
	_LRDS_Require(FSUtf8ExactMatches(_LRDS.LayerPath, External), "A stale layer page must not erase another editor's newer navigation binding.")
	_LRDS_Require(_LRDS.ApplyCalls == 0, "Refused stale source cannot request applying stale content.")
	Prefix := "if(window.saveResult)window.saveResult("
	Found := 0
	for Script in Record.View.Scripts {
		if SubStr(Script, 1, StrLen(Prefix)) != Prefix
			continue
		Found += 1
		Result := JsonParse(SubStr(Script, StrLen(Prefix) + 1, StrLen(Script) - StrLen(Prefix) - 1))
		_LRDS_Require(!Result["saved"] && !Result["applied"] && Result["errors"].Length > 0,
			"The same live page must receive an explained failure rather than a false durable receipt.")
	}
	_LRDS_Require(Found == 1 && Record.Controller.Closed == 0 && !Record.Host.ResetDone,
		"One refusal must preserve the actual editor for recovery.")
	; A fresh public host must admit this same physical file. This positive
	; control proves a source conflict, rather than a broken writer or path.
	Record.Host.Close()
	_LRDS.LayerText := External
	Fresh := _LRDS_Open()
	_LRDS_ReadyEvent(Fresh)
	_LRDS_Pump(Fresh, 1, 1)
	Fresh.Host.Opts["OnMessage"] := _LRDS_SaveMessage
	Message := '{"action":"save","text":' . JsonStringLiteral(External) . '}'
	Callback := Fresh.View.Callbacks["message"]
	Callback.Call(Fresh.View, _LRDS_SourceArgs(Message))
	Started := A_TickCount
	while _LRDS.SaveReturned < 2 && !IsObject(_LRDS.Failure) && TickElapsed(Started) < 3000
		Sleep(5)
	if IsObject(_LRDS.Failure)
		throw _LRDS.Failure
	_LRDS_Require(_LRDS.SaveEntered == 2 && _LRDS.SaveReturned == 2 && _LRDS.ApplyCalls == 1,
		"The fresh real source must publish through the actual writer and reach the isolated postcommit apply port once.")
	Found := 0
	for Script in Fresh.View.Scripts {
		if SubStr(Script, 1, StrLen(Prefix)) != Prefix
			continue
		Found += 1
		Result := JsonParse(SubStr(Script, StrLen(Prefix) + 1, StrLen(Script) - StrLen(Prefix) - 1))
		_LRDS_Require(Result["saved"] && !Result["applied"] && Result["errors"].Length == 0,
			"Only the fresh positive-control source may receive a real durable receipt.")
	}
	_LRDS_Require(Found == 1 && FSUtf8ExactMatches(_LRDS.LayerPath, External),
		"The positive control must preserve the exact newer binding without stage debris.")
	return Fresh
}


; Pure result observation is inserted immediately before the actual complete
; save-and-apply owner's final return in this isolated child only.
_LRDS_ObserveLayerResult(Result) {
	global _LRDS
	_LRDS.ResultProbeCalls += 1
	_LRDS.ResultProbe := Result.Clone()
}

_LRDS_CloseAtSuccess() {
	global _LRDS
	Record := _LRDS.CloseRecord
	_LRDS_Require(FSUtf8ExactMatches(_LRDS.LayerPath, _LRDS.Candidate),
		"The real successful-save logger must run only after the candidate is durable.")
	_LRDS.CloseHwnd := Record.Window.Hwnd
	_LRDS_Require(DllCall("User32\PostMessageW", "Ptr", _LRDS.CloseHwnd, "UInt", 0x10,
		"Ptr", 0, "Ptr", 0, "Int"), "Only a genuine WM_CLOSE may retire the actual public window.")
	Started := A_TickCount
	while !Record.Host.ResetDone && TickElapsed(Started) < 3000
		Sleep(5)
	_LRDS_Require(Record.Host.ResetDone && Record.Host.Epoch > Record.Epoch
		&& Record.Controller.Closed == 1 && Record.Controller.ActiveAtClose == 0
		&& !DllCall("User32\IsWindow", "Ptr", _LRDS.CloseHwnd, "Int"),
		"The real Close event must revoke the exact GUI epoch and retire its native resources during the logger callout.")
}

_LRDS_CloseAfterSave(Record) {
	global _LRDS
	_LRDS_Pump(Record, 1, 1)
	_LRDS_Require(Record.View.Init.Length == 1, "The actual page must have its original source before saving.")
	Original := Record.View.Init[1]["text"]
	_LRDS.Candidate := StrReplace(Original, '"KeyS" = "arrow_up"', '"KeyS" = "arrow_down"', , &Changed)
	_LRDS_Require(Changed == 1, "The candidate is a real change to one navigation binding.")
	_LRDS.CloseRecord := Record
	Record.Host.Opts["OnMessage"] := _LRDS_SaveMessage
	Message := '{"action":"save","text":' . JsonStringLiteral(_LRDS.Candidate) . '}'
	Callback := Record.View.Callbacks["message"]
	Callback.Call(Record.View, _LRDS_SourceArgs(Message))
	Started := A_TickCount
	while _LRDS.SaveReturned == 0 && !IsObject(_LRDS.Failure) && TickElapsed(Started) < 5000
		Sleep(5)
	if IsObject(_LRDS.Failure)
		throw _LRDS.Failure
	_LRDS_Require(_LRDS.SaveEntered == 1 && _LRDS.SaveReturned == 1 && _LRDS.ResultProbeCalls == 1,
		"Exactly one genuine save handler and observed terminal return must settle.")
	_LRDS_Require(_LRDS.Revoked && _LRDS.SuccessLogs == 1 && IsObject(_LRDS.ResultProbe),
		"A real success log must trigger exactly one native Close before the save-and-apply owner returns.")
	Result := _LRDS.ResultProbe
	FileAppend("RECEIPT layer-apply-retirement saved=" . Result["saved"] . " applied=" . Result["applied"]
		. " apply_calls=" . _LRDS.ApplyCalls . " native_closed=" . Record.Controller.Closed . "`n", "*", "UTF-8")
	_LRDS_Require(Result["saved"] && !Result["applied"] && Result["errors"].Length == 0,
		"Native Close after the durable receipt cannot undo the save or claim an apply.")
	_LRDS_Require(_LRDS.ApplyCalls == 0, "A retired GUI cannot admit apply after its successful-save logger yields.")
	_LRDS_Require(FSUtf8ExactMatches(_LRDS.LayerPath, _LRDS.Candidate)
		&& !FileExist(_LRDS.LayerPath . ".tmp"), "The accepted durable candidate remains intact after retirement.")
	_LRDS_Require(Record.Controller.Closed == 1 && Record.View.Scripts.Length == 1,
		"The retired page must receive neither another native Close nor a late save-result script.")
}


_LRDS_AdmissionApply() {
	global _LRDS
	_LRDS.ApplyCalls += 1
	return 1
}

_LRDS_AdmissionMessage(Host, Payload) {
	global _LRDS
	_LRDS.SaveEntered += 1
	try _LayerEditor_OnMessage(Host, Payload, _LRDS_AdmissionApply)
	finally _LRDS.SaveReturned += 1
}

_LRDS_AdmissionTimer() {
	global _LRDS
	_LRDS.SaveTimerCalls += 1
	try {
		_LRDS_Require(!A_IsCritical, "The actual native timer must execute outside Critical.")
		if _LRDS.Mode == "save-admission-pause-during"
			Suspend(true)
		_LRDS_Require(A_IsSuspended == (_LRDS.Mode == "save-admission-pause-during"),
			"The real timer must preserve its requested native pause state.")
	} catch as Failure {
		if !IsObject(_LRDS.Failure)
			_LRDS.Failure := Failure
	} finally _LRDS.SaveTimerDone := true
}

_LRDS_AdmissionStart(Line) {
	global _LRDS
	if !InStr(Line, "[START] [LayerEditor] Saving the navigation layer")
		return
	_LRDS.SaveLogCalls += 1
	if _LRDS.SaveLogCalls != 1
		return
	try {
		_LRDS_Require(!A_IsCritical, "The real save diagnostic must permit the native timer.")
		SetTimer(_LRDS.SaveTimerFn, -1)
		Started := A_TickCount
		while !_LRDS.SaveTimerDone && !IsObject(_LRDS.Failure) && TickElapsed(Started) < 3000
			Sleep(5)
		_LRDS_Require(_LRDS.SaveTimerDone, "The actual native timer must settle inside the genuine save diagnostic.")
	} catch as Failure {
		if !IsObject(_LRDS.Failure)
			_LRDS.Failure := Failure
	}
}

_LRDS_SaveAdmission(Record) {
	global _LRDS, _SharedDir, _ConfigDir
	_LRDS_Pump(Record, 1, 1)
	_LRDS_Require(Record.View.Init.Length == 1 && Record.Host.HasOwnProp("LayerOpening")
		&& Record.Host.LayerOpening.Offered,
		"The public native ready owner must actually offer its file before this SDK save event.")
	Before := FSReadBytesStrict(_LRDS.LayerPath)
	Record.Host.Opts["OnMessage"] := _LRDS_AdmissionMessage
	_LRDS.SaveTimerFn := _LRDS_AdmissionTimer
	if _LRDS.Mode == "save-admission-already-paused"
		Suspend(true)
	Message := '{"action":"save","text":' . JsonStringLiteral(_LRDS.EditedLayerText) . '}'
	Callback := Record.View.Callbacks["message"]
	Callback.Call(Record.View, _LRDS_SourceArgs(Message))
	ExpectedCalls := _LRDS.Mode == "save-admission-already-paused" ? 0 : 1
	if ExpectedCalls {
		Started := A_TickCount
		while _LRDS.SaveReturned < 1 && !IsObject(_LRDS.Failure) && TickElapsed(Started) < 4000
			Sleep(5)
	} else
		Sleep(30)
	if _LRDS.Mode == "save-admission-live" {
		Started := A_TickCount
		while Record.View.Scripts.Length < 2 && !IsObject(_LRDS.Failure) && TickElapsed(Started) < 3000
			Sleep(5)
	}
	if IsObject(_LRDS.Failure)
		throw _LRDS.Failure
	_LRDS_Require(_LRDS.SaveEntered == ExpectedCalls && _LRDS.SaveReturned == ExpectedCalls
		&& _LRDS.SaveLogCalls == ExpectedCalls && _LRDS.SaveTimerCalls == ExpectedCalls,
		"The actual SDK/dispatch/save/log/timer path must preserve every original admission count.")
	_LRDS_Require(!ExpectedCalls || _LRDS.SaveTimerDone, "Every admitted START must observe its native timer completion.")
	_LRDS_Require(A_IsSuspended == (_LRDS.Mode != "save-admission-live"), "The actual requested pause must remain active after the handler returns.")
	Actual := FSReadBytesStrict(_LRDS.LayerPath)
	if _LRDS.Mode == "save-admission-live" {
		_LRDS_Require(FSUtf8ExactMatches(_LRDS.LayerPath, _LRDS.EditedLayerText)
			&& Actual.Size == StrPut(_LRDS.EditedLayerText, "UTF-8") - 1,
			"The real live public request must publish the complete edited UTF-8 layer bytes.")
		_LRDS_Require(_LRDS.ApplyCalls == 1, "Only a live durable request may reach the passive apply boundary once.")
		Ctx := KeymapLayers_LoadContext(_SharedDir)
		Loaded := KeymapLayers_LoadUserFile(Ctx, _ConfigDir, "windows")
		_LRDS_Require(Loaded["ok"], "The actual durable result must load through the genuine Windows layer loader.")
	} else {
		; Keep the physical oracle before response assertions, as in the
		; historical save-admission fixture; a refusal cannot claim success.
		_LRDS_Require(Before.Size == Actual.Size && (Before.Size == 0
			|| DllCall("ntdll\RtlCompareMemory", "Ptr", Before.Ptr, "Ptr", Actual.Ptr,
				"UPtr", Before.Size, "UPtr") == Before.Size),
			"An actually paused public request cannot replace any original layer byte.")
		_LRDS_Require(_LRDS.ApplyCalls == 0, "A refused paused request cannot ask for apply.")
	}
	Responses := 0, Prefix := "if(window.saveResult)window.saveResult("
	for Script in Record.View.Scripts {
		if SubStr(Script, 1, StrLen(Prefix)) != Prefix
			continue
		Responses += 1
		Result := JsonParse(SubStr(Script, StrLen(Prefix) + 1, StrLen(Script) - StrLen(Prefix) - 1))
		if _LRDS.Mode == "save-admission-live"
			_LRDS_Require(Result["saved"] && Result["applied"] && Result["errors"].Length == 0, "The live SDK receipt must confirm both real save and passive apply.")
		else
			_LRDS_Require(!Result["saved"] && !Result["applied"], "A paused SDK response cannot claim a completed operation.")
	}
	_LRDS_Require(Responses == (_LRDS.Mode == "save-admission-live" ? 1 : 0),
		"A truly ready host submits the live receipt to the SDK; paused hosts must submit none.")
	_LRDS_Require(Record.Host.Queue.Length == 0, "The genuine ready host cannot strand a queued receipt.")
	Stages := 0
	loop files _ConfigDir . "\*.tmp", "F"
		Stages += 1
	loop files _ConfigDir . "\*.stage", "F"
		Stages += 1
	_LRDS_Require(Stages == 0, "The real writer cannot leave an owned stage.")
	FileAppend("RECEIPT layer-save-admission mode=" . _LRDS.Mode . " offered=" . Record.Host.LayerOpening.Offered
		. " saves=" . _LRDS.SaveEntered . " save_returns=" . _LRDS.SaveReturned . " logs=" . _LRDS.SaveLogCalls
		. " timers=" . _LRDS.SaveTimerCalls . " apply_calls=" . _LRDS.ApplyCalls
		. " responses=" . Responses . " paused=" . A_IsSuspended . "`n", "*", "UTF-8")
}

_LRDS_Log(Line) {
	global _LRDS
	if InStr(_LRDS.Mode, "save-admission-") == 1 {
		_LRDS_AdmissionStart(Line)
		; This is the real expected refusal after the timer paused the save.
		; Startup errors and every other error remain fatal to the child.
		if _LRDS.Mode == "save-admission-pause-during" && _LRDS.SaveTimerDone
			&& A_IsSuspended && InStr(Line, "[ERROR] [LayerEditor]") && InStr(Line, "the driver is suspended")
			return
	}
	if _LRDS.Mode == "source-close-after-save" && !_LRDS.Revoked && InStr(Line, "Navigation layer saved to '") {
		_LRDS.Revoked := true, _LRDS.SuccessLogs += 1
		try _LRDS_CloseAtSuccess()
		catch as Failure {
			if !IsObject(_LRDS.Failure)
				_LRDS.Failure := Failure
		}
	}
	if _LRDS.Mode == "source-stale" || _LRDS.Mode == "source-close-after-save"
		return
	if InStr(Line, "[ERROR]") && !IsObject(_LRDS.Failure)
		_LRDS.Failure := Error("The actual host/data/resume path emitted an error before its business oracle.")
}

_LRDS_OnError(Failure, Mode) {
	global _LRDS
	if !IsObject(_LRDS.Failure)
		_LRDS.Failure := Failure is Error ? Failure : Error("An asynchronous layer readiness failure was observed.")
	try FileAppend("DIAG layer-ready async type=" . Type(Failure) . " mode=" . Mode . "`n", "*", "UTF-8")
	return true
}

_LRDS_Report(Record) {
	global _LRDS
	FileAppend("RECEIPT layer-ready mode=" . _LRDS.Mode . " public_calls=" . _LRDS.PublicCalls
		. " navigation_events=" . _LRDS.NavigationEvents . " resumes=" . _LRDS.Resumes
		. " ready=" . Record.Host.Ready . " ready_fired=" . Record.Host.ReadyFired
		. " dispatch_calls=" . Record.Calls . " dispatch_settled=" . Record.Settled
		. " dispatch_paused=" . Record.Paused . " paused_calls=" . Record.PausedCalls . " dispatch_epoch=" . Record.LastEpoch
		. " initial_epoch=" . Record.Epoch . " init_scripts=" . Record.View.Init.Length
		. " scripts=" . Record.View.Scripts.Length . " native_suspended=" . A_IsSuspended
		. " closed=" . Record.Controller.Closed . " host_records=" . _LRDS.Records.Length
		. " latest_init_scripts=" . _LRDS.Records[_LRDS.Records.Length].View.Init.Length
		. " boundary_failure=" . IsObject(_LRDS.Failure)
		. "`n", "*", "UTF-8")
}

_LRDS_Main() {
	global _LRDS, _VendorDir, _SharedDir, _ConfigDir, WEBVIEW_SHARED_UDIR
	global Features, CategoryEnabled, TapHold, _LayerEditorOsProbe, _LLM_Menu
	if A_Args.Length != 3
		ExitApp(2)
	Persistent(true)
	_LRDS := {Mode: A_Args[1], Windows: [], Controllers: [], Records: [], Failure: 0,
		Environments: 0, PublicCalls: 0, NavigationEvents: 0, Resumes: 0, LayerText: "", LayerPath: "",
		SaveEntered: 0, SaveReturned: 0, ApplyCalls: 0, ResultProbe: 0, ResultProbeCalls: 0,
		Revoked: false, SuccessLogs: 0, CloseRecord: 0, CloseHwnd: 0, Candidate: "",
		EditedLayerText: "", SaveLogCalls: 0, SaveTimerCalls: 0, SaveTimerDone: false, SaveTimerFn: 0}
	OnError(_FeatureStateSmokeFatal, 0)
	OnError(_LRDS_OnError)
	LoggerSetTestSink(_LRDS_Log)
	; The genuine host reads its safety flush from the shared timing registry.
	TimingsLoadShared(A_Args[3])
	_VendorDir := A_Args[2], WEBVIEW_SHARED_UDIR := A_Args[2] . "\profile"
	_SharedDir := A_Args[3], _ConfigDir := A_Args[2] . "\config\"
	; Configuration/legend inputs are passive data. No remap/Hotkey initializer
	; or synthetic input action is started by this child.
	Features := Map("layout", Map("ergopti_base", false, "direct_access_digits", "native",
		"number_row_reorder_edges", false, "emulate_number_row", false,
		"emulate_top_row", false, "emulate_home_row", false, "emulate_bottom_row", false))
	CategoryEnabled := Map("Layout", false)
	TapHold := Map("keys", Map())
	_LayerEditorOsProbe := {Hkl: (*) => 0, ScToVk: (*) => 0, ToUnicode: (*) => {Count: 0, Text: ""}}
	Primary := 0, Observed := false, InheritedCritical := A_IsCritical
	try {
		DirCreate(_ConfigDir)
		Ctx := KeymapLayers_LoadContext(_SharedDir)
		_LRDS.LayerPath := KeymapLayers_UserFilePath(Ctx, _ConfigDir)
		_LRDS.LayerText := FSReadStrict(_SharedDir . "\tests\corpus\layer_editor\edited_layers.toml")
		if InStr(_LRDS.Mode, "save-admission-") == 1 {
			_LRDS.EditedLayerText := _LRDS.LayerText
			; Offer a valid original file with different bytes. The real page's
			; model serialization drops this additional source comment on Save.
			_LRDS.LayerText := "# retained before the click`n" . _LRDS.LayerText
		}
		_LRDS_Require(FSWriteCreateDurable(_LRDS.LayerPath, _LRDS.LayerText) == 1,
			"Only an exclusively created private layer file can be the init source.")
		_LRDS_Require(!_LLM_Menu["enabled"] && !_LLM_Menu["bootstrap_pending"],
			"The real menu starts neutral, without an invented pending bootstrap.")
		Record := _LRDS_Open()
		HeldCritical := Critical("On")
		try {
			_LRDS_ReadyEvent(Record)
			_LRDS_Require(Record.Calls == 0 && Record.View.Scripts.Length == 0,
				"The genuine SDK callback must defer delivery until the native SUT timer runs.")
			if _LRDS.Mode == "paused-dispatch"
				Suspend(true)
			if _LRDS.Mode == "retired-epoch" {
				Record.Host.Close()
				_LRDS_Require(Record.Host.ResetDone && Record.Controller.Closed == 1,
					"The original host must genuinely retire before its delayed timer can run.")
				Successor := _LRDS_Open()
				_LRDS_Require(Successor.Host != Record.Host && Successor.Window != Record.Window,
					"A retired host must not masquerade as the actual public successor.")
				_LRDS_ReadyEvent(Successor)
			}
		} finally Critical(HeldCritical)
		_LRDS_Pump(Record, 1, (_LRDS.Mode == "current" || _LRDS.Mode == "source-stale" || _LRDS.Mode == "source-close-after-save" || InStr(_LRDS.Mode, "save-admission-") == 1) ? 1 : 0)
		_LRDS_Require(Record.Calls >= 1 && Record.Settled == Record.Calls && !Record.InFlight
			&& Record.LastEpoch == Record.Epoch,
			"The real SUT native timer must be observed through its complete captured epoch dispatch.")
		if _LRDS.Mode == "paused-dispatch" {
			_LRDS_Require(Record.Paused && Record.View.Scripts.Length == 0,
				"Actual suspended delivery must perform no browser submission while paused.")
			_LRDS_Resume()
			; Exercise both actual recovery producers; reopening the singleton must
			; not be confused with constructing a second fresh page.
			_LRDS_ReadyEvent(Record)
			_LRDS_Require(_LRDS_Open() == Record && _LRDS.Windows.Length == 1,
				"Public reopen must observe the same live native singleton.")
			_LRDS_Pump(Record, 1, 1)
		}
		if _LRDS.Mode == "retired-epoch"
			_LRDS_Pump(Successor, 1, 1)
		if _LRDS.Mode == "source-stale"
			Record := _LRDS_StaleSource(Record)
		if _LRDS.Mode == "source-close-after-save"
			_LRDS_CloseAfterSave(Record)
		if InStr(_LRDS.Mode, "save-admission-") == 1
			_LRDS_SaveAdmission(Record)
		_LRDS_Report(Record), Observed := true
		if IsObject(_LRDS.Failure)
			throw _LRDS.Failure
		if _LRDS.Mode == "source-close-after-save" {
			_LRDS_Require(Record.View.Init.Length == 1 && Record.Controller.Closed == 1 && Record.Host.ResetDone,
				"The successful-save callout must leave exactly the retired public source owner.")
		} else if _LRDS.Mode == "retired-epoch" {
			_LRDS_Require(Record.View.Init.Length == 0 && Record.Controller.Closed == 1
				&& Successor.View.Init.Length == 1 && Successor.Calls >= 1 && Successor.Settled == Successor.Calls,
				"The old epoch must remain inert while only the new public host initializes once.")
		} else
			_LRDS_Require(Record.View.Init.Length == 1 && Record.Controller.Closed == 0,
				"A live current layer editor must eventually receive exactly one actual init projection after readiness delivery and resume.")
	} catch as Failure {
		Primary := IsObject(_LRDS.Failure) ? _LRDS.Failure : Failure
	} finally {
		if !Observed && _LRDS.Records.Length > 0 {
			try _LRDS_Report(_LRDS.Records[1])
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		if IsObject(_LRDS.SaveTimerFn) {
			try SetTimer(_LRDS.SaveTimerFn, 0)
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
			_LRDS.SaveTimerFn := 0
		}
		Suspend(false)
		Critical("Off")
		try {
			for Item in _LRDS.Records
				Item.Host.Close()
			for Window in _LRDS.Windows
				Window.Destroy()
			for Item in _LRDS.Records {
				; A failure before Main pumps must still let the real outstanding
				; SUT callback settle against its retired host before observer release.
				Started := A_TickCount
				while Item.EventSent && Item.Settled == 0 && TickElapsed(Started) < 1000
					Sleep(5)
				_LRDS_Require(!Item.EventSent || Item.Settled > 0,
					"Every observed pending readiness timer must settle before observer cleanup.")
				_LRDS_Require(Item.Controller.Closed == 1 && Item.Controller.ActiveAtClose == 0,
					"Each exact private controller must close once after unsubscribing its own SDK tokens.")
				_LRDS_Require(!Item.Host.BuildActive && Item.Host.ResetDone,
					"Every actual private host must retire before its instance observer is detached.")
				Item.Host.DeleteProp("_DispatchReady")
				Item.Dispatch := 0
			}
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		LoggerClearTestSink()
		OnError(_LRDS_OnError, 0)
		Critical(InheritedCritical)
	}
	if !IsObject(Primary) && IsObject(_LRDS.Failure)
		Primary := _LRDS.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS layer-ready-delivery " . _LRDS.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_LRDS_Main()
