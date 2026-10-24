; tests/fixtures/healthcheck_collection_publish_owner_body.ahk

; ==============================================================================
; MODULE: Diagnostics Collection Publication Component
; DESCRIPTION:
; Actual PowerShell workers produce archives and complete through ShellRunner.
; A native logger timer closes/reopens the real host and publicly admits B.
; The SDK port records submitted scripts; no DOM, Edge or input is certified.
; ==============================================================================

#Requires AutoHotkey v2.0

; The unchanged donor prefix calls these hoisted diagnostics before owner loading.
_EDOS_Phase(Phase, Failure := 0, Mode := "") {
	static Ordinal := 0, FirstException := 0, LastPhase := "", FirstExceptionPhase := ""
	if IsObject(Failure) {
		if IsObject(FirstException)
			return
		FirstException := Failure, FirstExceptionPhase := LastPhase
	} else
		LastPhase := Phase
	Line := 'PHASE collection-publish {"ordinal":' . ++Ordinal . ',"tick":' . A_TickCount
		. ',"phase":' . JsonStringLiteral(Phase) . ',"critical":' . A_IsCritical
		. ',"first_exception_phase":' . (IsObject(FirstException) ? JsonStringLiteral(FirstExceptionPhase) : "null")
	if IsObject(Failure)
		Line .= ',"exception_type":' . JsonStringLiteral(Type(FirstException))
			. ',"message":' . JsonStringLiteral(FirstException.Message)
			. ',"file":' . JsonStringLiteral(FirstException.File) . ',"line":' . FirstException.Line
			. ',"mode":' . JsonStringLiteral(Mode)
	FileAppend(Line . "}`n", "*", "UTF-8")
}

_EDOS_BootError(Failure, Mode) {
	try _EDOS_Phase("first-exception", Failure, Mode)
	return false
}

_HCPO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_HCPO_Failure(Failure) {
	global _HCPO
	if !IsObject(_HCPO.Failure)
		_HCPO.Failure := Failure
}

_HCPO_OnError(Failure, Mode) {
	try _EDOS_Phase("async-first-exception", Failure, Mode)
	_HCPO_Failure(Failure)
	return true
}

class _HCPO_Core {
	__New() {
		this.Settings := {}, this.Url := "", this.Subscriptions := 0, this.CacheCalls := 0
	}
	WebMessageReceived(Callback) {
		this.Subscriptions += 1
		return {Callback: Callback}
	}
	AddScriptToExecuteOnDocumentCreated(*) => 0
	SetVirtualHostNameToFolderMapping(*) => 0
	CallDevToolsProtocolMethodAsync(Method, Parameters) {
		_HCPO_Require(Method == "Network.clearBrowserCache" && Parameters == "{}",
			"Only the actual document-cache request is expected at this SDK port.")
		this.CacheCalls += 1
		return Promise.resolve("{}")
	}
	Navigate(Url) {
		_HCPO_Require(InStr(Url, "https://ergopti.healthcheck/") == 1,
			"The genuine diagnostics page must be selected.")
		this.Url := Url
	}
	ExecuteScriptAsync(Script) {
		global _HCPO, _HC_Collection, _HC_WindowEpoch, _HC_Session
		try {
			Marker := "&&window.receiveDiagnostics)window.receiveDiagnostics("
			Position := InStr(Script, Marker, true)
			if Position {
				Prefix := "if(location.href==="
				_HCPO_Require(SubStr(Script, 1, StrLen(Prefix)) == Prefix && SubStr(Script, -1) == ")",
					"The real send owner must retain its location guard.")
				Url := JsonParse(SubStr(Script, StrLen(Prefix) + 1, Position - StrLen(Prefix) - 1))
				Start := Position + StrLen(Marker)
				Message := JsonParse(SubStr(Script, Start, StrLen(Script) - Start))
				_HCPO_Require(_HC_Session is Map && Url == _HC_Session["page_url"] && Url == this.Url,
					"The observed submission must target the genuine current page URL.")
				if Message is Map && Message.Get("type", "") == "collection" {
					Value := Message["collection"]
					_HCPO_Require(Value is Map && Value.Has("session_id"), "The real collection projection must carry its Id.")
					_HCPO.Rows.Push({Id: Value["session_id"], Phase: Value["phase"], Pending: Value["owner_pending"],
						Epoch: _HC_WindowEpoch, Url: Url, Core: this, Current: IsObject(_HC_Collection) ? _HC_Collection.Id : ""})
				}
			}
		} catch Any as Failure {
			_HCPO_Failure(Failure)
		}
		return Promise.resolve("null")
	}
}

class _HCPO_Controller {
	__New() {
		this.CoreWebView2 := _HCPO_Core(), this.Closed := 0, this.Fills := 0, this.IsVisible := false
	}
	Close() {
		this.Closed += 1
		_HCPO_Require(this.Closed == 1, "An exact private controller must retire only once.")
	}
	Fill() {
		this.Fills += 1
	}
}

class _HCPO_Environment {
	CreateCoreWebView2ControllerAsync(Hwnd) {
		global _HCPO
		_HCPO_Require(DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "The SDK must receive a native placeholder.")
		Parent := DllCall("User32\GetParent", "Ptr", Hwnd, "Ptr")
		_HCPO_Require(DllCall("User32\IsWindowVisible", "Ptr", Parent, "Int"), "The actual host must be shown before create.")
		Controller := _HCPO_Controller()
		_HCPO.Pages.Push({Hwnd: Parent, Window: GuiFromHwnd(Parent), Controller: Controller})
		return Promise.resolve(Controller)
	}
}

_HCPO_EnvironmentFactory(Sdk, Options, UserData, Arguments, Loader) {
	global _HCPO, WEBVIEW_SHARED_UDIR, _VendorDir
	_HCPO_Require(Sdk == WebView2 && Options == 0 && Arguments == "" && UserData == WEBVIEW_SHARED_UDIR
		&& Loader == _VendorDir . "\64bit\WebView2Loader.dll", "The existing SDK factory ABI must remain intact.")
	_HCPO.EnvironmentCalls += 1
	return Promise.resolve(_HCPO.Environment)
}

_HCPO_Ready() {
	global _HC_Gui, _HC_Controller, _HC_WebView, _HC_ResetDone, _HC_Session, _HC_Opening, _HC_Retiring
	return !_HC_Opening && !_HC_Retiring && !_HC_ResetDone && _HC_Session is Map
		&& IsSet(_HC_Gui) && IsSet(_HC_Controller) && IsSet(_HC_WebView)
		&& _HC_Controller.CoreWebView2 == _HC_WebView && _HC_Controller.Closed == 0
		&& _HC_WebView.Url == _HC_Session["page_url"] && _HC_Controller.Fills > 0
		&& DllCall("User32\IsWindowVisible", "Ptr", _HC_Gui.Hwnd, "Int")
}

_HCPO_HasSubmission(Id, Terminal := false) {
	global _HCPO
	for Row in _HCPO.Rows
		if Row.Id == Id && (!Terminal || !Row.Pending)
			return true
	return false
}

_HCPO_CheckArchive(Owner) {
	_HCPO_Require(Owner.Terminal && Owner.Result.Get("worker_tree_retired", false) && !Owner.Result["owner_pending"],
		"Only actual native completion may qualify terminal worker retirement.")
	_HCPO_Require(Owner.Result.Get("archive_created", false) && FileExist(Owner.Archive) && Owner.HasProp("ArchiveDigest")
		&& CryptoSha256Bytes(FSReadBytesStrict(Owner.Archive)) == Owner.ArchiveDigest,
		"The unchanged collector must commit an archive with a genuine native acknowledgement.")
}

_HCPO_Actor() {
	global _HCPO, _HC_Collection, _HC_Gui, _HC_Session, _HC_WindowEpoch, _HC_Opening, _HC_Retiring
	try {
		_HCPO.ActorCalls += 1
		_HCPO_Require(_HCPO.ActorCalls == 1 && !A_IsCritical, "One actual interruptible timer must run at the terminal log.")
		A := _HCPO.A
		_HCPO_Require(_HC_Collection == A && A.Terminal, "A must still own the published collection at the native cut.")
		_HCPO_CheckArchive(A)
		Window := _HC_Gui, Hwnd := Window.Hwnd, OldEpoch := _HC_WindowEpoch, OldSession := _HC_Session
		DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0x10, "UPtr", 0, "Ptr", 0, "Ptr")
		Started := A_TickCount
		while (_HC_Session is Map || _HC_Retiring || _HC_Opening
			|| DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int")) && TickElapsed64(Started) < 1000
			Sleep(10)
		_HCPO_Require(!(_HC_Session is Map) && !_HC_Retiring && !_HC_Opening && _HC_WindowEpoch > OldEpoch
			&& !DllCall("User32\IsWindowVisible", "Ptr", Hwnd, "Int"), "The genuine native Close must return before reopen.")
		_HCPO.CloseAck += 1
		HealthCheck_ShowWindow()
		_HCPO_Require(_HCPO_Ready() && _HC_Session != OldSession && _HC_WindowEpoch > OldEpoch,
			"A real public reopen must establish a fresh usable diagnostics session.")
		Admitted := HealthCheck_CollectWindows(), B := _HC_Collection
		if B != A
			_HCPO.B := B
		_HCPO_Require(Admitted, "The documented public frontdoor must really admit B after A retired.")
		_HCPO.BPid := IsObject(B.Task) ? B.Task.processId() : 0
		_HCPO_Require(B != A && B.Id != A.Id && !B.Terminal && _HCPO.BPid > 0 && _HCPO_HasSubmission(B.Id),
			"A distinct live native B and its actual submission must precede A's resumption.")
		_HCPO.BFirst := 0
		for Index, Row in _HCPO.Rows
			if Row.Id == B.Id && !_HCPO.BFirst
				_HCPO.BFirst := Index
		_HCPO.BSession := _HC_Session, _HCPO.BEpoch := _HC_WindowEpoch
		_HCPO.ActorDone := true
	} catch Any as Failure {
		_HCPO_Failure(Failure)
	}
}

_HCPO_Log(Line) {
	global _HCPO, _HC_Collection, _LOGGER_DEBUG_ENABLED
	try {
		if _HCPO.Retiring || _HCPO.CutEntered || _HCPO.Mode == "current"
			return
		if !InStr(Line, "[DONE] [DiagnosticsCollection] Local diagnostic collection retired", true)
			return
		_HCPO.CutEntered := true
		_HCPO_Require(_LOGGER_DEBUG_ENABLED && !A_IsCritical && _HC_Collection == _HCPO.A,
			"The actual DEBUG terminal logger boundary must belong to A and be interruptible.")
		_HCPO_CheckArchive(_HCPO.A)
		SetTimer(_HCPO_Actor, -1)
		Started := A_TickCount
		while !_HCPO.ActorDone && !IsObject(_HCPO.Failure) && TickElapsed64(Started) < 5000
			Sleep(10)
		_HCPO_Require(_HCPO.ActorDone, "The real timer actor must finish before old A's logger returns.")
	} catch Any as Failure {
		_HCPO_Failure(Failure)
	}
}

_HCPO_WaitTerminal(Owner, Limit) {
	Started := A_TickCount
	while !Owner.Terminal && TickElapsed64(Started) < Limit {
		_SR_TreePoll()
		Sleep(10)
	}
	_HCPO_Require(Owner.Terminal, "The actual worker must reach its native completion within its test bound.")
}

_HCPO_Observe() {
	global _HCPO, _HC_Collection
	LateA := 0
	if _HCPO.BFirst {
		for Index, Row in _HCPO.Rows
			if Index > _HCPO.BFirst && Row.Id == _HCPO.A.Id
				LateA += 1
	}
	_HCPO.LateA := LateA
	FileAppend("RECEIPT collection-publish mode=" . _HCPO.Mode . " a_id=" . (IsObject(_HCPO.A) ? _HCPO.A.Id : "unknown")
		. " a_pid=" . _HCPO.APid . " b_id=" . (IsObject(_HCPO.B) ? _HCPO.B.Id : "unknown") . " b_pid=" . _HCPO.BPid
		. " rows=" . _HCPO.Rows.Length . " timer_calls=" . _HCPO.ActorCalls . " cut_entered=" . _HCPO.CutEntered
		. " actor_done=" . _HCPO.ActorDone . " close_ack=" . _HCPO.CloseAck . " b_first=" . _HCPO.BFirst
		. " late_a=" . LateA . " errors=" . IsObject(_HCPO.Failure)
		. " a_archive=" . (IsObject(_HCPO.A) ? _HCPO.A.Result.Get("archive_created", false) : -1)
		. " current_id=" . (IsObject(_HC_Collection) ? _HC_Collection.Id : "unknown") . "`n", "*", "UTF-8")
}

_HCPO_Check() {
	global _HCPO, _HC_Collection, _HC_Session, _HC_WindowEpoch
	if IsObject(_HCPO.Failure)
		throw _HCPO.Failure
	_HCPO_CheckArchive(_HCPO.A)
	_HCPO_Require(_HCPO.APid > 0 && _HCPO.EnvironmentCalls == 1 && _HCPO_HasSubmission(_HCPO.A.Id),
		"The current control must reach its real worker, shared SDK and collection submission.")
	if _HCPO.Mode == "current" {
		_HCPO_Require(_HC_Collection == _HCPO.A && _HCPO_HasSubmission(_HCPO.A.Id, true),
			"An ordinary current terminal owner must genuinely publish its own final projection.")
		return
	}
	_HCPO_Require(_HCPO.CutEntered && _HCPO.ActorDone && _HCPO.ActorCalls == 1 && _HCPO.CloseAck == 1
		&& IsObject(_HCPO.B) && _HCPO.BFirst > 0, "The complete native A-to-B cut must precede the business oracle.")
	_HCPO_Require(_HC_Collection == _HCPO.B && !_HCPO.B.Terminal && _HC_Session == _HCPO.BSession
		&& _HC_WindowEpoch == _HCPO.BEpoch, "The genuine successor task and page must remain current after A returns.")
	_HCPO_Require(_HCPO.LateA == 0, "A retired collection must not replace B's projection after its terminal logger returns.")
}

_HCPO_Cleanup() {
	global _HCPO
	_HCPO.Retiring := true
	SetTimer(_HCPO_Actor, 0)
	for Owner in [_HCPO.A, _HCPO.B] {
		if !IsObject(Owner)
			continue
		try {
			if !Owner.Terminal {
				Owner.Cancel()
				_HCPO_WaitTerminal(Owner, 10000)
			}
		} catch Any as Failure {
			_HCPO_Failure(Failure)
		}
		; A failed/cold worker still owns its native handles after a wait error.
		; Attempt the exact tree ACK independently of archive/business prerequisites.
		try {
			Ack := IsObject(Owner.Task) ? Owner.Task.terminate() : 1
			_HCPO_Require(Ack is Integer && Ack == 1, "Every exact native collection tree must acknowledge retirement.")
			_HCPO.TaskAcks += 1
			if IsObject(Owner.Task)
				_HCPO_CheckArchive(Owner)
		} catch Any as Failure {
			_HCPO_Failure(Failure)
		}
	}
	try _HC_Close()
	catch Any as Failure
		_HCPO_Failure(Failure)
	for Page in _HCPO.Pages {
		try {
			if Page.Controller.Closed == 0
				Page.Controller.Close()
			if DllCall("User32\IsWindow", "Ptr", Page.Hwnd, "Int")
				Page.Window.Destroy()
			_HCPO_Require(Page.Controller.Closed == 1 && !DllCall("User32\IsWindow", "Ptr", Page.Hwnd, "Int"),
				"Every acquired private GUI/controller must independently retire.")
		} catch Any as Failure {
			_HCPO_Failure(Failure)
		}
	}
	try {
		Sleep(10)
		_HCPO_Require(LoggerPrepareShutdown() == true, "The true private logger must flush before exit.")
		SetTimer(_LoggerFlush, 0)
		OnExit(_LoggerOnExitFlush, 0)
	} catch Any as Failure {
		_HCPO_Failure(Failure)
	}
	FileAppend("CLEANUP collection-publish task_acks=" . _HCPO.TaskAcks . " pages=" . _HCPO.Pages.Length
		. " errors=" . IsObject(_HCPO.Failure) . "`n", "*", "UTF-8")
}

_HCPO_Main() {
	global _HCPO, _EDOS_Root, Features, WEBVIEW_SHARED_UDIR, _HC_Collection, _LOGGER_DEBUG_ENABLED
	if A_Args.Length != 2 || A_Args[2] != _EDOS_Root
		ExitApp(2)
	Persistent(true)
	_HCPO := {Mode: A_Args[1], Pages: [], Rows: [], Environment: _HCPO_Environment(), EnvironmentCalls: 0,
		A: 0, B: 0, APid: 0, BPid: 0, BFirst: 0, BSession: 0, BEpoch: 0, LateA: 0, TaskAcks: 0,
		Failure: 0, CutEntered: false, ActorDone: false, ActorCalls: 0, CloseAck: 0, Retiring: false}
	Primary := 0, Observed := false, PreviousCritical := Critical("Off"), PreviousSuspend := A_IsSuspended
	OriginalData := EnvGet("LOCALAPPDATA"), OriginalFactory := WebView2.GetOwnPropDesc("CreateEnvironmentAsync")
	Thread("Interrupt", 0), Suspend(false)
	OnError(_HCPO_OnError)
	try {
		_EDOS_Phase("fixture Main entered")
		_HCPO_Require(_HCPO.Mode == "current" || _HCPO.Mode == "successor-during-terminal-log", "Unknown component mode.")
		EnvSet("LOCALAPPDATA", _EDOS_Root . "\localappdata")
		Features := ManifestBuildFeaturesMap()
		WEBVIEW_SHARED_UDIR := _EDOS_Root . "\profile"
		WebView2.DefineProp("CreateEnvironmentAsync", {Call: _HCPO_EnvironmentFactory})
		_EDOS_Phase("before genuine LoggerInit")
		LoggerInit()
		_HCPO_Require(_LOGGER_DEBUG_ENABLED, "The genuine configured DEBUG level must enable the terminal logger.")
		LoggerSetTestSink(_HCPO_Log)
		_EDOS_Phase("before public HealthCheck_ShowWindow")
		HealthCheck_ShowWindow()
		_HCPO_Require(_HCPO_Ready(), "Actual HealthCheck initialization must succeed before ownership assertions.")
		_EDOS_Phase("before public collection A")
		Admitted := HealthCheck_CollectWindows()
		_HCPO.A := _HC_Collection
		_HCPO_Require(Admitted, "The current collection must be admitted through its public API.")
		_HCPO.APid := _HCPO.A.Task.processId()
		_HCPO_Require(_HCPO.APid > 0 && !_HCPO.A.Terminal, "The current positive requires a genuine live native task.")
		_HCPO.A.Cancel()
		_HCPO_WaitTerminal(_HCPO.A, 10000)
		; Main resumes only after the interrupted native completion/log stack returns.
		_EDOS_Phase("Main resumed after A completion; before business observation")
		_HCPO_Observe(), Observed := true
		_HCPO_Check()
	} catch Any as Failure {
		try _EDOS_Phase("Main first exception", Failure)
		Primary := IsObject(_HCPO.Failure) ? _HCPO.Failure : Failure
	} finally {
		if !Observed {
			try _HCPO_Observe()
			catch Any as Failure
				_HCPO_Failure(Failure)
		}
		try _HCPO_Cleanup()
		catch Any as Failure
			_HCPO_Failure(Failure)
		try LoggerClearTestSink()
		catch Any as Failure
			_HCPO_Failure(Failure)
		try WebView2.DefineProp("CreateEnvironmentAsync", OriginalFactory)
		catch Any as Failure
			_HCPO_Failure(Failure)
		try EnvSet("LOCALAPPDATA", OriginalData)
		catch Any as Failure
			_HCPO_Failure(Failure)
		OnError(_HCPO_OnError, 0), OnError(_EDOS_BootError, 0)
		Suspend(PreviousSuspend), Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_HCPO.Failure)
		Primary := _HCPO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS healthcheck-collection-publish-owner " . _HCPO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_HCPO_Main()
