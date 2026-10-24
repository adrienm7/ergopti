; tests/fixtures/healthcheck_collection_lifetime_body.ahk

; ==============================================================================
; MODULE: Diagnostics Collection Lifetime Component
; DESCRIPTION:
; Actual workers and native tree acknowledgements precede lifetime observations.
; An acyclic marker observes destruction after public successor replacement.
; The passive SDK records submissions; no RSS, physical input or DOM is certified.
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

class _HCLT_Marker {
	__New(Observer, Kind) {
		this.Observer := Observer, this.Kind := Kind
	}
	__Delete() {
		if this.Kind == "control"
			this.Observer.ControlDeleted += 1
		else
			this.Observer.OwnerDeleted += 1
	}
}

_HCLT_Disposable(Observer) {
	Marker := _HCLT_Marker(Observer, "control")
}

_HCLT_WaitTerminal(Owner) {
	Started := A_TickCount
	while !Owner.Terminal && TickElapsed64(Started) < 10000 {
		_SR_TreePoll()
		Sleep(10)
	}
	_HCPO_Require(Owner.Terminal, "The real native completion must return before lifetime observation.")
}

_HCLT_CompleteA(Observer) {
	global _HC_Collection, _HCPO
	Admitted := HealthCheck_CollectWindows(), Owner := _HC_Collection
	Task := IsObject(Owner.Task) ? Owner.Task : 0
	_HCPO.RetirementTask := Task
	_HCPO_Require(Admitted, "The genuine public frontdoor must admit native A.")
	Observer.AId := Owner.Id, Observer.APid := Task.processId()
	_HCPO_Require(Observer.APid > 0 && !Owner.Terminal, "A must acquire a real live native worker.")
	Owner.LifetimeMarker := _HCLT_Marker(Observer, "owner")
	Owner.Cancel()
	_HCLT_WaitTerminal(Owner)
	; This runs in original Main after Poll/native callbacks return, never in Completed.
	_HCPO_CheckArchive(Owner)
	_HCPO_Require(!Owner.ExitArmed && !IsObject(Owner.Gui) && !Owner.HasProp("Editor")
		&& !Owner.HasProp("Visual") && !Owner.HasProp("Holds"), "No guided control or handler may ever have been acquired.")
	_HCPO_Require(_HCPO_HasSubmission(Owner.Id, true), "A must submit its actual terminal projection.")
	Ack := Task.terminate()
	_HCPO_Require(Ack is Integer && Ack == 1, "A's exact native task must acknowledge complete retirement.")
	Observer.AAck := Ack, Observer.AArchive := 1
	_HCPO.RetirementTask := 0
	; No A, Task, marker or callback reference is returned to the caller.
}

_HCLT_ReplaceA(Observer) {
	global _HC_Collection, _HCPO
	_HCPO_Require(_HC_Collection.Id == Observer.AId && _HC_Collection.Terminal,
		"The public successor must replace the genuine terminal current A.")
	Admitted := HealthCheck_CollectWindows()
	_HCPO.RetirementTask := IsObject(_HC_Collection.Task) ? _HC_Collection.Task : 0
	_HCPO_Require(Admitted, "The same genuine public API must admit native B.")
	Observer.BId := _HC_Collection.Id, Observer.BPid := _HCPO.RetirementTask.processId()
	_HCPO_Require(Observer.BId != Observer.AId && Observer.BPid > 0 && !_HC_Collection.Terminal
		&& _HCPO_HasSubmission(Observer.BId), "B must be a distinct current native collection with its own submission.")
}

_HCLT_Pulse() {
	global _HCPO
	_HCPO.Pulses += 1
}

_HCLT_Turn() {
	global _HCPO
	_HCPO.Pulses := 0
	SetTimer(_HCLT_Pulse, -1)
	Started := A_TickCount
	while _HCPO.Pulses == 0 && TickElapsed64(Started) < 1000
		Sleep(10)
	_HCPO_Require(_HCPO.Pulses == 1, "A real native timer turn must return to original Main.")
}

_HCLT_Observe(Observer) {
	global _HCPO, _HC_Collection
	FileAppend("RECEIPT collection-lifetime mode=" . _HCPO.Mode . " control_deleted=" . Observer.ControlDeleted
		. " owner_deleted=" . Observer.OwnerDeleted . " a_id=" . Observer.AId . " a_pid=" . Observer.APid
		. " a_ack=" . Observer.AAck . " a_archive=" . Observer.AArchive . " b_id=" . Observer.BId
		. " b_pid=" . Observer.BPid . " current_id=" . (IsObject(_HC_Collection) ? _HC_Collection.Id : "unknown")
		. " returned_turns=" . _HCPO.Pulses . " errors=" . IsObject(_HCPO.Failure) . "`n", "*", "UTF-8")
}

_HCLT_Cleanup() {
	global _HC_Collection, _HCPO
	SetTimer(_HCLT_Pulse, 0)
	Task := _HCPO.RetirementTask
	if !IsObject(Task) && IsObject(_HC_Collection) && _HC_Collection.HasProp("Task") && IsObject(_HC_Collection.Task)
		Task := _HC_Collection.Task
	if IsObject(_HC_Collection) {
		try {
			if !_HC_Collection.Terminal {
				_HC_Collection.Cancel()
				_HCLT_WaitTerminal(_HC_Collection)
			}
		} catch Any as Failure {
			_HCPO_Failure(Failure)
		}
		try {
			Ack := IsObject(Task) ? Task.terminate() : 1
			_HCPO_Require(Ack is Integer && Ack == 1, "The current exact native collection tree must retire during cleanup.")
			_HCPO.CleanupAck := Ack
			_HCPO.RetirementTask := 0
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
				"Every actual acquired private GUI/controller must independently retire.")
		} catch Any as Failure {
			_HCPO_Failure(Failure)
		}
	}
	try {
		Sleep(10)
		_HCPO_Require(LoggerPrepareShutdown() == true, "The real private logger must flush before child exit.")
		SetTimer(_LoggerFlush, 0)
		OnExit(_LoggerOnExitFlush, 0)
	} catch Any as Failure {
		_HCPO_Failure(Failure)
	}
	FileAppend("CLEANUP collection-lifetime task_ack=" . _HCPO.CleanupAck . " pages=" . _HCPO.Pages.Length
		. " errors=" . IsObject(_HCPO.Failure) . "`n", "*", "UTF-8")
}

_HCLT_Main() {
	global _HCPO, _EDOS_Root, Features, WEBVIEW_SHARED_UDIR, _HC_Collection, _LOGGER_DEBUG_ENABLED
	if A_Args.Length != 2 || A_Args[2] != _EDOS_Root
		ExitApp(2)
	Persistent(true)
	_HCPO := {Mode: A_Args[1], Pages: [], Rows: [], Environment: _HCPO_Environment(), EnvironmentCalls: 0,
		Failure: 0, Pulses: 0, CleanupAck: 0, RetirementTask: 0}
	; These fields remain transitively primitive; no observer edge can reach a marker or owner.
	Observer := {ControlDeleted: 0, OwnerDeleted: 0, AId: "", APid: 0, AAck: 0, AArchive: 0, BId: "", BPid: 0}
	Primary := 0, Observed := false, PreviousCritical := Critical("Off"), PreviousSuspend := A_IsSuspended
	OriginalData := EnvGet("LOCALAPPDATA"), OriginalFactory := WebView2.GetOwnPropDesc("CreateEnvironmentAsync")
	Thread("Interrupt", 0), Suspend(false)
	OnError(_HCPO_OnError)
	try {
		_HCPO_Require(_HCPO.Mode == "current-retained" || _HCPO.Mode == "successor-releases", "Unknown lifetime mode.")
		EnvSet("LOCALAPPDATA", _EDOS_Root . "\localappdata")
		Features := ManifestBuildFeaturesMap()
		WEBVIEW_SHARED_UDIR := _EDOS_Root . "\profile"
		WebView2.DefineProp("CreateEnvironmentAsync", {Call: _HCPO_EnvironmentFactory})
		LoggerInit()
		_HCPO_Require(_LOGGER_DEBUG_ENABLED, "The genuine private configured logger must initialize.")
		HealthCheck_ShowWindow()
		_HCPO_Require(_HCPO_Ready(), "The real native host and passive SDK must initialize before worker admission.")
		_HCLT_Disposable(Observer)
		_HCPO_Require(Observer.ControlDeleted == 1, "An ordinary acyclic marker must genuinely receive __Delete after helper return.")
		_HCLT_CompleteA(Observer)
		_HCPO_Require(_HC_Collection.Id == Observer.AId && _HC_Collection.Terminal && Observer.OwnerDeleted == 0
			&& !IsObject(_HCPO.RetirementTask),
			"Terminal A must remain retained while the real global current owner still names it.")
		if _HCPO.Mode == "successor-releases"
			_HCLT_ReplaceA(Observer)
		_HCLT_Turn()
		if IsObject(_HCPO.Failure)
			throw _HCPO.Failure
		_HCPO_Require(Observer.ControlDeleted == 1 && Observer.AAck == 1 && Observer.AArchive == 1
			&& _HCPO.EnvironmentCalls == 1 && !A_IsCritical, "Actual completion, archive and acyclic-control prerequisites must precede business observation.")
		_HCLT_Observe(Observer), Observed := true
		if _HCPO.Mode == "current-retained"
			_HCPO_Require(_HC_Collection.Id == Observer.AId && Observer.OwnerDeleted == 0,
				"A current terminal collection must retain its marker after native task retirement.")
		else {
			_HCPO_Require(_HC_Collection.Id == Observer.BId && Observer.BPid > 0,
				"The genuine public successor must still be current at the release observation.")
			_HCPO_Require(Observer.OwnerDeleted == 1,
				"A terminal collection replaced by public B must release its acyclic marker after all helper and completion frames return.")
		}
	} catch Any as Failure {
		try _EDOS_Phase("lifetime Main first exception", Failure)
		Primary := IsObject(_HCPO.Failure) ? _HCPO.Failure : Failure
	} finally {
		if !Observed {
			try _HCLT_Observe(Observer)
			catch Any as Failure
				_HCPO_Failure(Failure)
		}
		try _HCLT_Cleanup()
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
	FileAppend("PASS healthcheck-collection-lifetime " . _HCPO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_HCLT_Main()
