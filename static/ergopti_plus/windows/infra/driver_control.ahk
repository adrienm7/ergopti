; infra/driver_control.ahk

; ==============================================================================
; MODULE: Local Driver Control (reload command)
; DESCRIPTION:
; A tool run by the same user asks this running driver to reload. The AHK port
; of _shared/lua/control/driver_control.lua, pinned to it by the corpus under
; _shared/tests/corpus/control; the declaration is
; _shared/modules/control/driver_control.json.
;
; FEATURES & RATIONALE:
; 1. One endpoint owner. The registered message rings the same
;    HealthCheckWindowControl owner as Diagnostics: it binds the request to
;    this process lifetime, answers inside SendMessage only "queued" or
;    "refused" and runs the request later on a one-shot timer.
; 2. Authenticated by a private token. The session file in the user's own
;    LocalAppData folder holds a fresh random token; a request file must carry
;    it, compared without stopping at the first difference.
; 3. The reload owner decides. An admitted request goes to
;    ReloadPreservingSuspend, which keeps the pause, the configuration lease
;    and the successor hand-off; nothing here starts or ends a process.
; 4. Three separate outcomes. "requested" names the successor process, a
;    refusal names its reason, and the successor itself writes "completed"
;    once it is ready.
; ==============================================================================

#Include %A_LineFile%\..\..\adapters\driver_control.ahk

global _DriverControl := 0





; ==============================
; ==============================
; ======= 1/ Declaration =======
; ==============================
; ==============================

/**
 * Reads and checks the shared declaration; a malformed one stops the caller.
 * @param {String} Path driver_control.json.
 * @returns {Map}
 */
DriverControl_LoadSpec(Path) {
	Text := FSReadUtf8Exact(Path)
	if !(Text is String)
		throw Error("The driver control declaration could not be read: " . Path)
	Spec := JsonParse(Text)
	if !(Spec is Map)
		throw Error("The driver control declaration is not an object.")
	for Key in ["schema", "max_request_bytes", "token_hex_length", "request_id_pattern", "files",
			"folders", "windows_message", "states", "reasons"]
		if !Spec.Has(Key)
			throw Error("The driver control declaration lacks " . Key . ".")
	if Spec["schema"] != 1 || Spec["token_hex_length"] != 64
			|| !(Spec["max_request_bytes"] is Integer) || Spec["max_request_bytes"] < 128
		throw Error("The driver control declaration has an unsupported shape.")
	if Spec["request_id_pattern"] != "^[A-Za-z0-9_-]{1,64}$"
		throw Error("The driver control request identifier differs from the policy this port enforces.")
	for Key in ["session", "request", "result"]
		if !(Spec["files"] is Map) || !Spec["files"].Has(Key) || !(Spec["files"][Key] ~= "^[A-Za-z0-9_.]+$")
			throw Error("The driver control file " . Key . " must be a plain name.")
	Folder := (Spec["folders"] is Map) ? Spec["folders"].Get("windows", 0) : 0
	if !(Folder is Map) || !(Folder.Get("base", "") is String) || Folder.Get("base", "") == ""
			|| !(Folder.Get("segments", 0) is Array) || Folder["segments"].Length == 0
		throw Error("The driver control declaration has no Windows folder.")
	if !(Spec["windows_message"] is String) || Spec["windows_message"] == ""
		throw Error("The driver control declaration names no window message.")
	for ListKey in ["states", "reasons"] {
		Names := Map()
		for Name in Spec[ListKey] {
			if !(Name is String) || Name == "" || Names.Has(Name)
				throw Error("The driver control " . ListKey . " hold an invalid or duplicate name.")
			Names[Name] := true
		}
		Spec[ListKey . "_set"] := Names
	}
	for Name in ["requested", "refused", "completed"]
		if !Spec["states_set"].Has(Name)
			throw Error("The driver control state " . Name . " is not declared.")
	return Spec
}

/**
 * The Windows control folder: the declared base and segments.
 * @param {Map} Spec
 * @param {String} Base Resolved base folder.
 * @returns {String}
 */
DriverControl_Folder(Spec, Base) {
	if !(Base is String) || Base == ""
		throw Error("The driver control folder has no base: " . Spec["folders"]["windows"]["base"] . " is not set.")
	Parts := RTrim(Base, "\/")
	for Segment in Spec["folders"]["windows"]["segments"]
		Parts .= "\" . (Segment == "{app}" ? AppDirsFolderName() : Segment)
	return Parts
}





; ===========================
; ===========================
; ======= 2/ Requests =======
; ===========================
; ===========================

DriverControl_IsToken(Spec, Text) {
	return (Text is String) && StrLen(Text) == Spec["token_hex_length"] && RegExMatch(Text, "^[0-9a-f]+$")
}

; Compares every character, so the time taken does not tell how many match.
DriverControl_SameToken(First, Second) {
	if !(First is String) || !(Second is String) || StrLen(First) != StrLen(Second)
		return false
	Diff := 0
	loop StrLen(First)
		Diff += Ord(SubStr(First, A_Index, 1)) != Ord(SubStr(Second, A_Index, 1))
	return Diff == 0
}

DriverControl_IsRequestId(Value) {
	return (Value is String) && RegExMatch(Value, "^[A-Za-z0-9_-]{1,64}$")
}

/**
 * Admits one request text against the session token.
 * @param {Map} Spec
 * @param {String} Text Raw request.
 * @param {String} Token This session's token.
 * @param {VarRef} Reason "malformed" or "unauthenticated" on refusal.
 * @param {VarRef} Echoed The request's own valid identifier, or "".
 * @returns {String} The request identifier, or "" when refused.
 */
DriverControl_ParseRequest(Spec, Text, Token, &Reason, &Echoed) {
	Reason := "", Echoed := ""
	if !DriverControl_IsToken(Spec, Token)
		throw Error("The driver control session token is malformed.")
	if !(Text is String) || Text == "" || StrPut(Text, "UTF-8") - 1 > Spec["max_request_bytes"] {
		Reason := "malformed"
		return ""
	}
	try Request := JsonParse(Text)
	catch {
		Reason := "malformed"
		return ""
	}
	if !(Request is Map) {
		Reason := "malformed"
		return ""
	}
	if DriverControl_IsRequestId(Request.Get("request_id", ""))
		Echoed := Request["request_id"]
	for Key in Request
		if Key != "schema" && Key != "token" && Key != "request_id" {
			Reason := "malformed"
			return ""
		}
	; The raw text must spell the schema as the integer itself: this parser
	; reads true and 1.0 as the same value.
	if !RegExMatch(Text, '"schema"\s*:\s*' . Spec["schema"] . '\s*[,}]') || Request.Get("schema", "") != Spec["schema"]
			|| Echoed == "" || !(Request.Get("token", 0) is String) {
		Reason := "malformed"
		return ""
	}
	if !DriverControl_IsToken(Spec, Request["token"]) || !DriverControl_SameToken(Request["token"], Token) {
		Reason := "unauthenticated"
		return ""
	}
	Id := Echoed, Echoed := ""
	return Id
}





; ==========================
; ==========================
; ======= 3/ Results =======
; ==========================
; ==========================

/** The session file text the requester reads. */
DriverControl_SessionText(Spec, Pid, Token) {
	if !(Pid is Integer) || Pid <= 0 || !DriverControl_IsToken(Spec, Token)
		throw Error("The driver control session needs a process id and a token.")
	return Format('{"schema":{1:d},"driver":"windows","pid":{2:d},"token":"{3}"}`n', Spec["schema"], Pid, Token)
}

/**
 * Builds one result text; an inconsistent result stops the caller.
 * @param {Map} Spec
 * @param {Map} Fields request_id (optional for a refusal), state, driver_pid,
 *     successor_pid (not for a refusal), reason (refusal only).
 * @returns {String}
 */
DriverControl_ResultText(Spec, Fields) {
	State := Fields.Get("state", "")
	if !Spec["states_set"].Has(State)
		throw Error("Unknown driver control result state: " . State)
	HasId := Fields.Has("request_id")
	if HasId && !DriverControl_IsRequestId(Fields["request_id"])
		throw Error("Invalid driver control result request id.")
	if !HasId && State != "refused"
		throw Error("Only a refusal may lack its request id.")
	DriverPid := Fields.Get("driver_pid", 0)
	if !(DriverPid is Integer) || DriverPid <= 0
		throw Error("The result needs the writing driver's process id.")
	if State == "refused" {
		if Fields.Has("successor_pid")
			throw Error("A refusal names no successor.")
		Reason := Fields.Get("reason", "")
		if !Spec["reasons_set"].Has(Reason)
			throw Error("Unknown driver control refusal reason: " . Reason)
		Tail := Format(',"reason":"{1}"', Reason)
	} else {
		Successor := Fields.Get("successor_pid", 0)
		if !(Successor is Integer) || Successor <= 0
			throw Error("A " . State . " result names its successor.")
		if Fields.Has("reason")
			throw Error("Only a refusal carries a reason.")
		if State == "completed" && Successor != DriverPid
			throw Error("Completion is written by the successor itself.")
		Tail := Format(',"successor_pid":{1:d}', Successor)
	}
	Id := HasId ? '"' . Fields["request_id"] . '"' : "null"
	return Format('{"schema":{1:d},"request_id":{2},"state":"{3}","driver_pid":{4:d}{5}}`n',
		Spec["schema"], Id, State, DriverPid, Tail)
}

/**
 * The completion a freshly ready driver owes, or "".
 * @param {Map} Spec
 * @param {String} Text Current result bytes.
 * @param {Integer} OwnPid
 * @returns {String}
 */
DriverControl_Completion(Spec, Text, OwnPid) {
	if !(Text is String) || Text == "" || StrPut(Text, "UTF-8") - 1 > Spec["max_request_bytes"]
		return ""
	try Result := JsonParse(Text)
	catch
		return ""
	if !(Result is Map)
		return ""
	for Key in Result
		if !(Key ~= "^(schema|request_id|state|driver_pid|successor_pid|reason)$")
			return ""
	if Result.Get("schema", "") != Spec["schema"] || Result.Get("state", "") != "requested"
			|| !DriverControl_IsRequestId(Result.Get("request_id", ""))
			|| !(Result.Get("successor_pid", "") is Integer) || Result["successor_pid"] != OwnPid
		return ""
	return DriverControl_ResultText(Spec, Map("request_id", Result["request_id"], "state", "completed",
		"driver_pid", OwnPid, "successor_pid", OwnPid))
}





; ===========================
; ===========================
; ======= 4/ Session ========
; ===========================
; ===========================

/** Owns one session: its token, files and the endpoint that rings it. */
class DriverControlSession {
	/**
	 * @param {Map} Spec Checked declaration.
	 * @param {String} Folder Control folder.
	 * @param {Integer} Pid This process.
	 * @param {Map} Ports "token", "endpoint" (factory taking the handler),
	 *     "reload" (ReloadPreservingSuspend contract), "pending" (the pending
	 *     hand-off record or false).
	 */
	__New(Spec, Folder, Pid, Ports) {
		for Name in ["token", "endpoint", "reload", "pending"]
			if !(Ports is Map) || !Ports.Has(Name) || !HasMethod(Ports[Name], "Call")
				throw TypeError("The driver control session needs its " . Name . " port.")
		if !(Folder is String) || Folder == "" || !(Pid is Integer) || Pid <= 0
			throw ValueError("The driver control session needs a folder and a process id.")
		this.Spec := Spec, this.Folder := Folder, this.Pid := Pid, this.Ports := Ports
		this.Token := "", this.Endpoint := 0, this.Started := false, this.Active := false
		this.Handled := 0
	}

	Path(Kind) => this.Folder . "\" . this.Spec["files"][Kind]

	/** Completes a pending request naming this process, then publishes the session. */
	Start() {
		if this.Started
			throw Error("The driver control session cannot be started twice.")
		this.Started := true
		FSEnsureDirectoryStrict(this.Folder)
		Completed := DriverControl_Completion(this.Spec,
			FSReadUtf8ExactBounded(this.Path("result"), this.Spec["max_request_bytes"]), this.Pid)
		if Completed != "" {
			this.Publish("result", Completed)
			try LoggerSuccess("DriverControl", "Reload request completed in successor pid {1}.", this.Pid)
		}
		Token := this.Ports["token"].Call(this.Spec["token_hex_length"])
		if !DriverControl_IsToken(this.Spec, Token)
			throw Error("The driver control token source returned a malformed token.")
		this.Token := Token
		this.Publish("session", DriverControl_SessionText(this.Spec, this.Pid, Token))
		this.Endpoint := this.Ports["endpoint"].Call(ObjBindMethod(this, "Handle"))
		this.Endpoint.Start()
		this.Active := true
	}

	/** Retires the endpoint, then withdraws the session file it still owns. */
	Stop() {
		this.Active := false
		Failure := 0
		if IsObject(this.Endpoint) {
			try this.Endpoint.Stop()
			catch as Err
				Failure := Err
		}
		Session := this.Token != "" ? FSReadUtf8ExactBounded(this.Path("session"), this.Spec["max_request_bytes"]) : false
		; A successor that already published its own session keeps it.
		if (Session is String) && InStr(Session, '"token":"' . this.Token . '"', true)
				&& !FSDelete(this.Path("session"))
			try LoggerError("DriverControl", "The driver control session file could not be withdrawn.")
		if IsObject(Failure)
			throw Failure
	}

	/** Runs one rung request outside SendMessage; reports its outcome in the result file. */
	Handle() {
		if !this.Active
			return false
		this.Handled += 1
		RequestPath := this.Path("request")
		Text := FSReadUtf8ExactBounded(RequestPath, this.Spec["max_request_bytes"])
		Present := (Text is String) || FSSize(RequestPath) >= 0
		if !Present {
			try LoggerWarn("DriverControl", "Reload control rang without a request file.")
			return false
		}
		; Consumed before it acts, so one request never runs twice.
		if !FSDelete(RequestPath) {
			try LoggerError("DriverControl", "The reload request file could not be consumed; request refused.")
			this.Report(Map("state", "refused", "reason", "failed"))
			return false
		}
		Id := DriverControl_ParseRequest(this.Spec, (Text is String) ? Text : "", this.Token, &Reason, &Echoed)
		if Id == "" {
			try LoggerWarn("DriverControl", "Reload request refused: {1}.", Reason)
			Fields := Map("state", "refused", "reason", Reason)
			if Echoed != ""
				Fields["request_id"] := Echoed
			this.Report(Fields)
			return false
		}
		; A reload already in flight is joined, as on Linux and macOS for a menu
		; click: its successor completes this request too. The result file holds
		; one record, so the newest request takes over the report.
		InFlight := this.InFlightSuccessor()
		if InFlight > 0 {
			try LoggerInfo("DriverControl", "Reload request {1} joined the reload in flight (successor pid {2}); no second reload.",
				Id, InFlight)
			this.Report(Map("request_id", Id, "state", "requested", "successor_pid", InFlight))
			return true
		}
		try LoggerInfo("DriverControl", "Reload request {1} admitted; the reload owner decides.", Id)
		Started := this.Ports["reload"].Call(0, 0, ObjBindMethod(this, "Refused", Id),
			ObjBindMethod(this, "StageRefused", Id))
		PreviousCritical := Critical("On")
		try {
			if !((Started is Integer) && Started == 1) {
				try LoggerWarn("DriverControl", "Reload request {1} refused: the reload owner did not start a successor.", Id)
				this.Report(Map("request_id", Id, "state", "refused", "reason", "busy"))
				return false
			}
			Pending := this.Ports["pending"].Call()
			Successor := (Pending is Map) && (Pending.Get("successor", 0) is Map)
				? Pending["successor"].Get("pid", 0) : 0
			if !(Successor is Integer) || Successor <= 0 {
				try LoggerError("DriverControl", "Reload request {1} started without a named successor.", Id)
				this.Report(Map("request_id", Id, "state", "refused", "reason", "failed"))
				return false
			}
			this.Report(Map("request_id", Id, "state", "requested", "successor_pid", Successor))
			try LoggerInfo("DriverControl", "Reload request {1} requested; successor pid {2} completes it once ready.", Id, Successor)
			return true
		} finally Critical(PreviousCritical)
	}

	/** The pid of the successor an earlier reload already launched, 0 when none is in flight. */
	InFlightSuccessor() {
		Pending := this.Ports["pending"].Call()
		Successor := (Pending is Map) && (Pending.Get("successor", 0) is Map)
			? Pending["successor"].Get("pid", 0) : 0
		return (Successor is Integer) && Successor > 0 ? Successor : 0
	}

	/** The reload owner refused after launching the successor. */
	Refused(Id, Reason := "") {
		try LoggerWarn("DriverControl", "Reload request {1} refused by the reload owner: {2}.", Id, Reason)
		this.Report(Map("request_id", Id, "state", "refused", "reason", "refused"))
	}

	/** A stage refused before launch; the result file, not a notice, reports it. */
	StageRefused(Id, Stage, Path := "") {
		try LoggerWarn("DriverControl", "Reload request {1} refused at stage {2}.", Id, Stage)
	}

	Report(Fields) {
		Fields["driver_pid"] := this.Pid
		try this.Publish("result", DriverControl_ResultText(this.Spec, Fields))
		catch as Err
			try LoggerError("DriverControl", "The reload result could not be written: {1}.", Err.Message)
	}

	; Each file is replaced whole, so a reader never sees half a result.
	Publish(Kind, Text) {
		Target := this.Path(Kind)
		Stage := Target . ".tmp-" . this.Pid
		if !FSWriteDurable(Stage, Text)
			throw Error("The driver control " . Kind . " file could not be staged.")
		if !FSAtomicMoveReplace(Stage, Target, &NativeError) {
			FSDelete(Stage)
			throw OSError(NativeError, -1, "The driver control " . Kind . " file could not be published.")
		}
	}
}

/** Starts the local reload control once the driver is ready. */
DriverControl_Start() {
	global _DriverControl, _SharedDir, _DriverStartupSmokeDir
	if IsObject(_DriverControl)
		throw Error("The driver control already has an owner.")
	LoggerStart("DriverControl", "Starting the local reload control…")
	try {
		Spec := DriverControl_LoadSpec(_SharedDir . "\modules\control\driver_control.json")
		Base := (IsSet(_DriverStartupSmokeDir) && _DriverStartupSmokeDir != "")
			? _DriverStartupSmokeDir : EnvGet(Spec["folders"]["windows"]["base"])
		Message := DriverControl_RegisterMessage(Spec["windows_message"])
		Endpoint := (Handler) => HealthCheckWindowControl(() => Message,
			(Id, Callback, Threads) => OnMessage(Id, Callback, Threads),
			HealthCheck_ControlTimer, Handler, _HealthCheck_WindowControlReady,
			A_ScriptHwnd, ProcessExist(), HealthCheck_ControlCreationTime())
		Session := DriverControlSession(Spec, DriverControl_Folder(Spec, Base), ProcessExist(),
			Map("token", DriverControl_RandomHex, "endpoint", Endpoint,
				"reload", ReloadPreservingSuspend, "pending", ReloadTerminalHandoffPending))
		_DriverControl := Session
		Session.Start()
	} catch as FirstError {
		try DriverControl_Stop()
		catch as CleanupError
			FirstError.ControlRetirementError := CleanupError
		LoggerError("DriverControl", "Local reload control could not start: {1}.", FirstError.Message)
		throw FirstError
	}
	LoggerSuccess("DriverControl", "Local reload control ready.")
}

/** Retires the local reload control. */
DriverControl_Stop() {
	global _DriverControl
	; 0 until a session owns the control, so this is the init guard.
	if !_DriverControl
		return
	_DriverControl.Stop()
	_DriverControl := 0
	LoggerInfo("DriverControl", "Local reload control retired.")
}
