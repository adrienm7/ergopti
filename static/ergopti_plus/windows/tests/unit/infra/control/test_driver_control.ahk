; tests/unit/infra/control/test_driver_control.ahk

; ==============================================================================
; MODULE: Local Driver Control
; DESCRIPTION:
; Replays the shared driver-control corpus through the AutoHotkey port, then
; drives a genuine session against a temporary folder: an authenticated
; request reaches the reload owner and names its successor, a stale token or
; a refusing owner is reported as refused, and the successor completes the
; request once it starts.
; ==============================================================================

#Requires AutoHotkey v2.0





_TDC_Spec() {
	global _SharedDir
	return DriverControl_LoadSpec(_SharedDir . "\modules\control\driver_control.json")
}

_TDC_Corpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\control\driver_control.json"))
}

_TDC_CorpusRequests() {
	Spec := _TDC_Spec(), Corpus := _TDC_Corpus()
	AssertEqual(13, Corpus["requests"].Length, "complete request vectors")
	for Row in Corpus["requests"] {
		Id := DriverControl_ParseRequest(Spec, Row["text"], Corpus["token"], &Reason, &Echoed)
		AssertEqual(Row.Get("request_id", ""), Id, Row["name"])
		AssertEqual(Row.Get("reason", ""), Reason, Row["name"] . " reason")
		AssertEqual(Row.Get("echoed", ""), Echoed, Row["name"] . " echoed identifier")
	}
}
Test("driver-control: the shared corpus admits only a request carrying the session token", _TDC_CorpusRequests)

_TDC_CorpusResults() {
	Spec := _TDC_Spec(), Corpus := _TDC_Corpus()
	AssertEqual(16, Corpus["results"].Length, "complete result vectors")
	for Row in Corpus["results"] {
		Fields := Map()
		for Key, Value in Row["fields"]
			Fields[Key] := Value
		if Row.Get("invalid", false) {
			Threw := false
			try DriverControl_ResultText(Spec, Fields)
			catch
				Threw := true
			AssertTrue(Threw, Row["name"] . " is refused")
		} else
			AssertEqual(Row["text"], DriverControl_ResultText(Spec, Fields), Row["name"])
	}
}
Test("driver-control: the shared corpus pins every result text", _TDC_CorpusResults)

_TDC_CorpusCompletions() {
	Spec := _TDC_Spec(), Corpus := _TDC_Corpus()
	AssertEqual(7, Corpus["completions"].Length, "complete completion vectors")
	for Row in Corpus["completions"]
		AssertEqual(Row.Get("completed", ""), DriverControl_Completion(Spec, Row["text"], Row["pid"]), Row["name"])
}
Test("driver-control: only the named successor completes a pending request", _TDC_CorpusCompletions)

_TDC_CorpusResolutions() {
	Spec := _TDC_Spec(), Corpus := _TDC_Corpus()
	AssertEqual(12, Corpus["resolutions"].Length, "complete resolution vectors")
	for Row in Corpus["resolutions"] {
		Owed := DriverControl_Resolve(Spec, Row["text"], Row["pid"], Row["now"], &Kind)
		AssertEqual(Row.Get("kind", ""), Kind, Row["name"] . " kind")
		AssertEqual(Row.Get("result", ""), Owed, Row["name"] . " result")
	}
	AssertEqual(120, Spec["pending_ttl_seconds"])
	AssertEqual("deadline", Spec["timeout_reason"])
}
Test("driver-control: a pending record is claimed, completed or timed out exactly as the corpus says", _TDC_CorpusResolutions)

_TDC_Folder() {
	Spec := _TDC_Spec()
	AssertEqual("C:\Users\u\AppData\Local\ergopti_plus\control", DriverControl_Folder(Spec, "C:\Users\u\AppData\Local\"))
	AssertThrows(() => DriverControl_Folder(Spec, ""), "an unset base refuses the control")
}
Test("driver-control: the control folder follows the declared Windows base", _TDC_Folder)


; A genuine session over a temporary folder, with the native ports replaced.
_TDC_World(Body, ReloadResult := 1, InFlight := 0) {
	Spec := _TDC_Spec(), Corpus := _TDC_Corpus()
	Folder := A_Temp . "\ergopti-driver-control-" . A_TickCount . "-" . Random(1, 1000000)
	; InFlight: the pid of a successor an earlier reload already launched.
	World := {Calls: [], Refused: 0, Stage: 0, Endpoint: 0, Started: 0, Stopped: 0, Launched: false,
		Successor: 4242, Result: ReloadResult, Spec: Spec, Token: Corpus["token"], Folder: Folder,
		InFlight: InFlight, Observers: Map()}
	Reload(SuccessFn, Bundle, RefusedFn, StageFn) {
		World.Calls.Push([SuccessFn, Bundle])
		World.Refused := Refuse, World.Stage := StageFn
		Refuse(Reason) {
			RefusedFn.Call(Reason)
			for _, Observer in World.Observers.Clone()
				Observer.Call(Reason)
		}
		World.Launched := World.Result == 1
		return World.Result
	}
	; The hand-off record exists from the launch of a successor until OnExit.
	Pending() => World.InFlight ? Map("successor", Map("pid", World.InFlight))
		: World.Launched ? Map("successor", Map("pid", World.Successor)) : false
	Endpoint(Handler) {
		World.Endpoint := Handler
		return {Start: (*) => World.Started += 1, Stop: (*) => World.Stopped += 1}
	}
	Observe(Record, Owner, Callback) {
		World.Observers[Owner] := Callback
		return true
	}
	World.Session := DriverControlSession(Spec, Folder, 1000,
		Map("token", (*) => World.Token, "endpoint", Endpoint, "reload", Reload, "pending", Pending, "observe_refusal", Observe))
	try Body.Call(World)
	finally {
		try World.Session.Stop()
		try DirDelete(Folder, true)
	}
}

_TDC_Read(World, Kind) => FSReadUtf8Exact(World.Folder . "\" . World.Spec["files"][Kind])

_TDC_Request(World, Token, Id) {
	Text := Format('{"schema":1,"token":"{1}","request_id":"{2}"}', Token, Id)
	AssertTrue(FSWriteDurable(World.Folder . "\" . World.Spec["files"]["request"], Text))
}

_TDC_SessionPublishes() {
	_TDC_World(Body)
	Body(World) {
		World.Session.Start()
		AssertEqual('{"schema":1,"driver":"windows","pid":1000,"token":"' . World.Token . '"}`n', _TDC_Read(World, "session"))
		AssertEqual(1, World.Started, "the endpoint is activated exactly once")
		AssertTrue(HasMethod(World.Endpoint, "Call"), "the endpoint runs the session's own handler")
		AssertThrows(() => World.Session.Start(), "a second start is refused")
		World.Session.Stop()
		AssertEqual(1, World.Stopped)
		AssertFalse(FileExist(World.Folder . "\session.json"), "the session withdraws its own file")
	}
}
Test("driver-control: a session publishes its token for an active endpoint", _TDC_SessionPublishes)

_TDC_AuthenticatedRequest() {
	_TDC_World(Body)
	Body(World) {
		World.Session.Start()
		_TDC_Request(World, World.Token, "cli-1")
		AssertTrue(World.Endpoint.Call())
		AssertEqual(1, World.Calls.Length, "the reload owner is asked exactly once")
		AssertEqual(0, World.Calls[1][1], "the successor, not a callback, reports completion")
		AssertTrue(HasMethod(World.Refused, "Call"), "a later refusal is reported")
		AssertFalse(FileExist(World.Folder . "\reload.request"), "the request is consumed")
		AssertEqual('{"schema":1,"request_id":"cli-1","state":"requested","driver_pid":1000,"successor_pid":4242}`n',
			_TDC_Read(World, "result"))
		World.Refused.Call("the successor refused the handoff")
		AssertEqual('{"schema":1,"request_id":"cli-1","state":"refused","driver_pid":1000,"reason":"refused"}`n',
			_TDC_Read(World, "result"), "a refusal after launch replaces the pending result")
		AssertFalse(World.Endpoint.Call(), "a ring without a request does nothing")
		AssertEqual(1, World.Calls.Length)
	}
}
Test("driver-control: an authenticated request reaches the reload owner and names its successor", _TDC_AuthenticatedRequest)

_TDC_StaleToken() {
	_TDC_World(Body)
	Body(World) {
		World.Session.Start()
		_TDC_Request(World, StrReplace(World.Token, "0", "1"), "stale")
		AssertFalse(World.Endpoint.Call())
		AssertEqual(0, World.Calls.Length, "an unauthenticated request never reaches the reload owner")
		AssertEqual('{"schema":1,"request_id":"stale","state":"refused","driver_pid":1000,"reason":"unauthenticated"}`n',
			_TDC_Read(World, "result"))
	}
}
Test("driver-control: a stale token is refused without reloading", _TDC_StaleToken)

_TDC_OwnerRefuses() {
	_TDC_World(Body, 0)
	Body(World) {
		World.Session.Start()
		_TDC_Request(World, World.Token, "busy-1")
		AssertFalse(World.Endpoint.Call())
		AssertEqual(1, World.Calls.Length)
		AssertEqual('{"schema":1,"request_id":"busy-1","state":"refused","driver_pid":1000,"reason":"busy"}`n',
			_TDC_Read(World, "result"))
	}
}
Test("driver-control: a reload the owner does not start is refused", _TDC_OwnerRefuses)

; Linux and macOS join a reload in flight for a menu click (d8f6fbf1d2); the
; local control follows the same rule on Windows instead of answering "busy".
_TDC_JoinsReloadInFlight() {
	_TDC_World(Body, 1, 7777)
	Body(World) {
		World.Session.Start()
		_TDC_Request(World, World.Token, "cli-2")
		AssertTrue(World.Endpoint.Call(), "a request made during a reload is admitted")
		AssertEqual(0, World.Calls.Length, "it never asks the reload owner for a second reload")
		Requested := '{"schema":1,"request_id":"cli-2","state":"requested","driver_pid":1000,"successor_pid":7777}`n'
		AssertEqual(Requested, _TDC_Read(World, "result"),
			"it is reported as requested, naming the successor already launched")
		AssertEqual('{"schema":1,"request_id":"cli-2","state":"completed","driver_pid":7777,"successor_pid":7777}`n',
			DriverControl_Completion(World.Spec, Requested, 7777),
			"the successor in flight completes the joined request")
		AssertFalse(FileExist(World.Folder . "\reload.request"), "the request is consumed")
	}
}
Test("driver-control: a request made during a reload joins it instead of being refused busy (reload-click-joins)",
	_TDC_JoinsReloadInFlight)

_TDC_SuccessorCompletes() {
	_TDC_World(Body)
	Body(World) {
		DirCreate(World.Folder)
		AssertTrue(FSWriteDurable(World.Folder . "\reload.result",
			'{"schema":1,"request_id":"cli-9","state":"requested","driver_pid":900,"successor_pid":1000}`n'))
		AssertTrue(FSWriteDurable(World.Folder . "\session.json",
			'{"schema":1,"driver":"windows","pid":900,"token":"' . StrReplace(World.Token, "0", "9") . '"}`n'))
		World.Session.Start()
		AssertEqual('{"schema":1,"request_id":"cli-9","state":"completed","driver_pid":1000,"successor_pid":1000}`n',
			_TDC_Read(World, "result"), "the ready successor completes the request")
		AssertTrue(InStr(_TDC_Read(World, "session"), World.Token, true), "the successor replaces the old session")
	}
}
Test("driver-control: the ready successor completes the pending request", _TDC_SuccessorCompletes)

_TDC_StopKeepsSuccessorSession() {
	_TDC_World(Body)
	Body(World) {
		World.Session.Start()
		Successor := '{"schema":1,"driver":"windows","pid":2000,"token":"' . StrReplace(World.Token, "0", "2") . '"}`n'
		AssertTrue(FSWriteDurable(World.Folder . "\session.json", Successor))
		World.Session.Stop()
		AssertEqual(Successor, _TDC_Read(World, "session"), "a successor's session survives its predecessor")
	}
}
Test("driver-control: a stopping predecessor keeps its successor's session", _TDC_StopKeepsSuccessorSession)


/** A later request joins the same native successor and takes over its report. */
_TDC_JoinedRequestReceivesRefusal() {
	_TDC_World(Body)
	Body(World) {
		World.Session.Start()
		_TDC_Request(World, World.Token, "first")
		AssertTrue(World.Endpoint.Call())
		_TDC_Request(World, World.Token, "joined")
		AssertTrue(World.Endpoint.Call())
		AssertEqual(1, World.Calls.Length, "the second request shares the exact launched reload")
		AssertEqual(1, World.Observers.Count, "repeated joins retain one observer per session")
		World.Refused.Call("the successor refused the handoff")
		AssertEqual('{"schema":1,"request_id":"joined","state":"refused","driver_pid":1000,"reason":"refused"}`n',
			_TDC_Read(World, "result"), "the latest joined requester receives the terminal refusal")
	}
}
Test("driver-control: a joined request receives its successor refusal (control-joined-refusal)",
	_TDC_JoinedRequestReceivesRefusal)

/** An old reload callback cannot overwrite the result of a later request. */
_TDC_StaleRefusalCannotReplaceLatestResult() {
	_TDC_World(Body)
	Body(World) {
		World.Session.Start()
		_TDC_Request(World, World.Token, "first")
		AssertTrue(World.Endpoint.Call())
		_TDC_Request(World, StrReplace(World.Token, "0", "1"), "stale-token")
		AssertFalse(World.Endpoint.Call())
		Refusal := _TDC_Read(World, "result")
		World.Refused.Call("the old successor refused the handoff")
		AssertEqual(Refusal, _TDC_Read(World, "result"),
			"the earlier reload no longer owns the latest request's result")
	}
}
Test("driver-control: a stale reload refusal keeps the latest result (control-joined-refusal)",
	_TDC_StaleRefusalCannotReplaceLatestResult)


/** A control request can join a reload that originated from the tray. */
_TDC_MenuReloadRefusalIsReported() {
	_TDC_World(Body, 1, 7777)
	Body(World) {
		World.Session.Start()
		_TDC_Request(World, World.Token, "menu-joined")
		AssertTrue(World.Endpoint.Call())
		AssertEqual(0, World.Calls.Length, "joining a tray reload never starts another successor")
		AssertEqual(1, World.Observers.Count, "the admitted request subscribes to the existing owner's refusal")
		World.Observers[World.Session].Call("the tray reload was vetoed")
		AssertEqual('{"schema":1,"request_id":"menu-joined","state":"refused","driver_pid":1000,"reason":"refused"}`n',
			_TDC_Read(World, "result"), "a tray-origin successor refusal settles the joined request too")
	}
}
Test("driver-control: a tray-origin reload refusal settles its joined request (control-joined-refusal)",
	_TDC_MenuReloadRefusalIsReported)


_TDCR_RetireDuringStart(Phase) {
	_TDC_World(_TDCR_RetireDuringStartBody.Bind(Phase))
}

_TDCR_RetireDuringStartBody(Phase, World) {
	State := {Phase: Phase, World: World, FactoryCalls: 0, StartCalls: 0,
		StopCalls: 0, RetiredInPort: false}
	World.Session.Ports["token"] := _TDCR_Token.Bind(State)
	World.Session.Ports["endpoint"] := _TDCR_Endpoint.Bind(State)
	Failure := 0
	try World.Session.Start()
	catch Any as Err
		Failure := Err
	AssertTrue(State.RetiredInPort, "the genuine session must be stopped while its startup collaborator is running")
	AssertFalse(World.Session.Active, "startup cannot publish an active session after its exact owner retired")
	AssertFalse(FileExist(World.Session.Path("session")),
		"startup cannot republish its withdrawn session token after retirement")
	AssertEqual(Phase == "token" ? 0 : 1, State.FactoryCalls,
		"retirement fences later startup phases")
	AssertEqual(Phase == "start" ? 1 : 0, State.StartCalls,
		"a late endpoint factory cannot start its native listener after retirement")
	AssertTrue(IsObject(Failure), "retired startup must fail fast instead of reporting a completed start")
}

_TDCR_Stop(State) {
	State.World.Session.Stop()
	State.RetiredInPort := true
}

_TDCR_Token(State, Length) {
	AssertEqual(StrLen(State.World.Token), Length)
	if State.Phase == "token"
		_TDCR_Stop(State)
	return State.World.Token
}

_TDCR_Endpoint(State, Handler) {
	State.FactoryCalls += 1
	AssertTrue(HasMethod(Handler, "Call"), "the actual session owns its native endpoint callback")
	if State.Phase == "factory"
		_TDCR_Stop(State)
	return {Start: _TDCR_EndpointStart.Bind(State), Stop: _TDCR_EndpointStop.Bind(State)}
}

_TDCR_EndpointStart(State, *) {
	State.StartCalls += 1
	if State.Phase == "start"
		_TDCR_Stop(State)
}

_TDCR_EndpointStop(State, *) {
	State.StopCalls += 1
}

for _TDCR_Phase in ["token", "factory", "start"]
	Test("driver-control: retirement during " . _TDCR_Phase . " startup cannot resurrect the session (driver-control-start-retirement)",
		_TDCR_RetireDuringStart.Bind(_TDCR_Phase))


; Bound only this fixture's native deferred-delivery observation.
global _TDCR_NATIVE_WAIT_MS := 2000

_TDCR_ReadinessListen(State, Message, Callback, Threads) {
	if Threads == 1 {
		State["session_visible_at_registration"] := FileExist(State["world"].Session.Path("session")) != ""
		State["registrations"] += 1
		if State["session_visible_at_registration"]
			State["premature_ack"] := DllCall("SendMessageW", "Ptr", A_ScriptHwnd,
				"UInt", Message, "UPtr", State["world"].Session.Pid, "Ptr", State["creation"], "Ptr")
	}
	return OnMessage(Message, Callback, Threads)
}

_TDCR_ReadinessEndpoint(State, Handler) {
	World := State["world"]
	Endpoint := HealthCheckWindowControl(() => State["message"],
		_TDCR_ReadinessListen.Bind(State), HealthCheck_ControlTimer, Handler,
		() => true, A_ScriptHwnd, World.Session.Pid, State["creation"])
	State["endpoint"] := Endpoint
	return Endpoint
}

_TDCR_ReadinessAfterNativeActivation() {
	_TDC_World(_TDCR_ReadinessAfterNativeActivationBody)
}

_TDCR_ReadinessAfterNativeActivationBody(World) {
	global _TDCR_NATIVE_WAIT_MS
	AssertFalse(A_IsCritical, "native control delivery needs an interruptible fixture")
	World.Session.Pid := ProcessExist()
	Creation := HealthCheck_ControlCreationTime()
	Message := DriverControl_RegisterMessage(World.Spec["windows_message"] . "-fixture-" . ProcessExist())
	State := Map("world", World, "message", Message, "creation", Creation,
		"endpoint", 0, "registrations", 0, "session_visible_at_registration", false, "premature_ack", -1)
	World.Session.Ports["endpoint"] := _TDCR_ReadinessEndpoint.Bind(State)
	World.Session.Start()
	AssertEqual(1, State["registrations"], "the genuine native listener must be installed")
	if State["session_visible_at_registration"]
		AssertEqual(0, State["premature_ack"],
			"an actual early requester sees the token while the native endpoint still refuses it")
	AssertFalse(State["session_visible_at_registration"],
		"a control token cannot announce readiness before the native endpoint is registered")
	AssertTrue(State["endpoint"].Active && World.Session.Active)
	AssertTrue(FileExist(World.Session.Path("session")) != "",
		"the fully active native endpoint must publish its actual readiness receipt")
	_TDC_Request(World, World.Token, "native-ready")
	Ack := DllCall("SendMessageW", "Ptr", A_ScriptHwnd, "UInt", Message,
		"UPtr", World.Session.Pid, "Ptr", Creation, "Ptr")
	AssertEqual(1, Ack, "the actual private native message is admitted after token publication")
	Started := A_TickCount
	while World.Calls.Length == 0 && !TickExpired64(Started, _TDCR_NATIVE_WAIT_MS)
		Sleep(1)
	AssertEqual(1, World.Calls.Length, "the actual native one-shot must dispatch the authenticated request")
	World.Session.Stop()
	AssertFalse(State["endpoint"].Active || World.Session.Active)
	AssertFalse(FileExist(World.Session.Path("session")))
	Ack := DllCall("SendMessageW", "Ptr", A_ScriptHwnd, "UInt", Message,
		"UPtr", World.Session.Pid, "Ptr", Creation, "Ptr")
	AssertEqual(0, Ack, "the retired native listener cannot accept another control request")
}
Test("driver-control: token publication follows actual native endpoint activation (driver-control-endpoint-readiness)",
	_TDCR_ReadinessAfterNativeActivation)

_TDC_RequestSchemaToken(Fields, Expected) {
	Spec := _TDC_Spec(), Corpus := _TDC_Corpus()
	Text := '{' . Fields . ',"token":"' . Corpus["token"] . '","request_id":"schema-token"}'
	Decoded := JsonParse(Text)
	AssertTrue(Decoded is Map, "every candidate must be genuine valid JSON")
	AssertEqual(Corpus["token"], Decoded["token"])
	AssertEqual("schema-token", Decoded["request_id"])
	Id := DriverControl_ParseRequest(Spec, Text, Corpus["token"], &Reason, &Echoed)
	if Expected {
		AssertEqual("schema-token", Id, "the authoritative JSON member must admit the canonical schema token")
		AssertEqual("", Reason)
		AssertEqual("", Echoed)
	} else {
		AssertEqual("", Id, "an earlier numeric member cannot bless a noncanonical authoritative schema token")
		AssertEqual("malformed", Reason)
		AssertEqual("schema-token", Echoed, "the malformed request keeps its own valid diagnostic identity")
	}
}
for _TDC_SchemaCase in [
	["canonical integer", '"schema":1', true],
	["whitespace integer", '"schema" : 1 ', true],
	["escaped schema key", '"sc\u0068ema":1', true],
	["last canonical integer", '"schema":true,"schema":1', true],
	["last escaped canonical integer", '"schema":true,"sc\u0068ema":1', true],
	["boolean", '"schema":true', false],
	["numeric string", '"schema":"1"', false],
	["decimal", '"schema":1.0', false],
	["exponent", '"schema":1e0', false],
	["last boolean", '"schema":1,"schema":true', false],
	["last numeric string", '"schema":1,"schema":"1"', false],
	["last decimal", '"schema":1,"schema":1.0', false],
	["last exponent", '"schema":1,"schema":1e0', false],
	["last escaped boolean", '"schema":1,"sc\u0068ema":true', false]
]
	Test("driver-control: " . _TDC_SchemaCase[1] . " follows the decoded schema member (driver-control-schema-token-identity)",
		_TDC_RequestSchemaToken.Bind(_TDC_SchemaCase[2], _TDC_SchemaCase[3]))

_TDC_ResultSchemaToken(Phase, Fields, Expected) {
	Spec := _TDC_Spec()
	Text := '{' . Fields . ',"request_id":"result-kind","state":"requested","driver_pid":100,"successor_pid":200}'
	Decoded := JsonParse(Text)
	AssertTrue(Decoded is Map)
	AssertTrue(DriverControl_IsRequestId(Decoded["request_id"]))
	AssertEqual("requested", Decoded["state"])
	AssertTrue(Decoded["successor_pid"] is Integer)
	AssertEqual(200, Decoded["successor_pid"])
	Kind := ""
	if Phase == "completion"
		Result := DriverControl_Completion(Spec, Text, 200)
	else
		Result := DriverControl_Resolve(Spec, Text, 200, 1700000000, &Kind)
	if Expected {
		AssertEqual('{"schema":1,"request_id":"result-kind","state":"completed","driver_pid":200,"successor_pid":200}`n', Result,
			"a genuine numeric schema keeps the named successor completion contract")
		if Phase == "resolution"
			AssertEqual("completed", Kind)
	} else {
		AssertEqual("", Result, "only a JSON number schema may authorize a completion")
		AssertEqual("", Kind, "a nonnumeric schema cannot claim a pending result")
	}
}
for _TDC_ResultPhase in ["completion", "resolution"]
	for _TDC_ResultCase in [
		["integer", '"schema":1', true],
		["decimal number", '"schema":1.0', true],
		["exponent number", '"schema":1e0', true],
		["escaped key", '"sc\u0068ema":1', true],
		["boolean", '"schema":true', false],
		["numeric string", '"schema":"1"', false],
		["last boolean", '"schema":1,"schema":true', false],
		["last numeric string", '"schema":1,"schema":"1"', false],
		["last decimal number", '"schema":true,"sc\u0068ema":1.0', true]
	]
		Test("driver-control: " . _TDC_ResultPhase . " " . _TDC_ResultCase[1] . " preserves schema kind (driver-control-result-schema-kind)",
			_TDC_ResultSchemaToken.Bind(_TDC_ResultPhase, _TDC_ResultCase[2], _TDC_ResultCase[3]))

_TDC_PendingSuccessorToken(Fields, HasDeadline, ExpectedKind) {
	Spec := _TDC_Spec()
	Text := '{"schema":1,"request_id":"pending-key","state":"requested","driver_pid":100'
		. (Fields == "" ? "" : "," . Fields)
		. (HasDeadline ? ',"deadline":1700000120}' : "}")
	Decoded := JsonParse(Text)
	AssertTrue(Decoded is Map)
	AssertEqual("pending-key", Decoded["request_id"])
	AssertEqual("requested", Decoded["state"])
	Result := DriverControl_Resolve(Spec, Text, 200, 1700000000, &Kind)
	AssertEqual(ExpectedKind, Kind, "the authoritative decoded successor member owns pending admission")
	if ExpectedKind == "claimed"
		AssertEqual('{"schema":1,"request_id":"pending-key","state":"claimed","driver_pid":200,"successor_pid":200,"deadline":1700000120}`n', Result)
	else if ExpectedKind == "completed"
		AssertEqual('{"schema":1,"request_id":"pending-key","state":"completed","driver_pid":200,"successor_pid":200}`n', Result)
	else
		AssertEqual("", Result, "a missing or non-null unassigned successor cannot claim the pending record")
}
for _TDC_PendingCase in [
	["canonical null", '"successor_pid":null', true, "claimed"],
	["escaped null", '"successor_\u0070id":null', true, "claimed"],
	["last escaped null", '"successor_pid":200,"successor_\u0070id":null', true, "claimed"],
	["last literal null", '"successor_\u0070id":200,"successor_pid":null', true, "claimed"],
	["missing successor", "", true, ""],
	["string null", '"successor_pid":"null"', true, ""],
	["boolean successor", '"successor_pid":false', true, ""],
	["last assigned successor", '"successor_pid":null,"successor_pid":200', false, "completed"],
	["assigned successor", '"successor_pid":200', false, "completed"],
	["escaped assigned successor", '"successor_\u0070id":200', false, "completed"],
	["string assigned successor", '"successor_pid":"200"', false, ""]
]
	Test("driver-control: " . _TDC_PendingCase[1] . " preserves successor source identity (driver-control-pending-successor-source)",
		_TDC_PendingSuccessorToken.Bind(_TDC_PendingCase[2], _TDC_PendingCase[3], _TDC_PendingCase[4]))

_TDC_ClaimedDriverPidKind(TokenKind, Expected) {
	Spec := _TDC_Spec(), Pid := ProcessExist()
	AssertTrue(Pid is Integer && Pid > 1, "the claimed identity must be a genuine native driver process id")
	switch TokenKind {
		case "native": Fields := '"driver_pid":' . Pid
		case "decimal": Fields := '"driver_pid":' . Pid . ".0"
		case "exponent": Fields := '"driver_pid":' . Pid . "e0"
		case "string": Fields := '"driver_pid":"' . Pid . '"'
		case "duplicate-string": Fields := '"driver_pid":' . Pid . ',"driver_pid":"' . Pid . '"'
		case "escaped": Fields := '"driver_\u0070id":' . Pid
		case "boolean": Fields := '"driver_pid":true'
		case "missing": Fields := ""
		default: throw Error("Unknown claimed driver identity fixture")
	}
	Text := '{"schema":1,"request_id":"claimed-kind","state":"claimed","successor_pid":' . Pid
		. ',"deadline":1700000120' . (Fields == "" ? "" : "," . Fields) . "}"
	Decoded := JsonParse(Text)
	AssertEqual("claimed", Decoded["state"])
	AssertEqual(Pid, Decoded["successor_pid"])
	AssertTrue(Decoded["successor_pid"] is Integer)
	AssertEqual(1700000120, Decoded["deadline"])
	Result := DriverControl_Resolve(Spec, Text, Pid, 1700000000, &Kind)
	if Expected {
		AssertEqual("completed", Kind)
		AssertEqual('{"schema":1,"request_id":"claimed-kind","state":"completed","driver_pid":'
			. Pid . ',"successor_pid":' . Pid . '}`n', Result)
	} else {
		AssertEqual("", Result, "a nonnumeric claimant cannot own the actual native process identity")
		AssertEqual("", Kind)
	}
}
for _TDC_ClaimedPidCase in [
	["native", true], ["decimal", true], ["exponent", true], ["string", false],
	["duplicate-string", false], ["escaped", true], ["boolean", false], ["missing", false]
]
	Test("driver-control: claimed " . _TDC_ClaimedPidCase[1] . " keeps numeric process identity (driver-control-claimed-pid-kind)",
		_TDC_ClaimedDriverPidKind.Bind(_TDC_ClaimedPidCase[1], _TDC_ClaimedPidCase[2]))

_TDC_DeadlineKind(Phase, Token, ExpectedKind) {
	Spec := _TDC_Spec(), Pid := ProcessExist()
	AssertTrue(Pid is Integer && Pid > 1)
	Text := '{"schema":1,"request_id":"deadline-kind","state":"'
		. (Phase == "pending" ? "requested" : "claimed") . '","driver_pid":' . Pid
		. ',"successor_pid":' . (Phase == "pending" ? "null" : String(Pid)) . ',"deadline":' . Token . "}"
	Decoded := JsonParse(Text)
	AssertEqual("deadline-kind", Decoded["request_id"])
	AssertEqual(Pid, Decoded["driver_pid"])
	Result := DriverControl_Resolve(Spec, Text, Pid, 1700000000, &Kind)
	AssertEqual(ExpectedKind, Kind, "only an actual JSON number deadline may resolve a pending reload")
	Prefix := '{"schema":1,"request_id":"deadline-kind","state":"'
	if ExpectedKind == "claimed"
		AssertEqual(Prefix . 'claimed","driver_pid":' . Pid . ',"successor_pid":' . Pid . ',"deadline":1700000120}`n', Result)
	else if ExpectedKind == "completed"
		AssertEqual(Prefix . 'completed","driver_pid":' . Pid . ',"successor_pid":' . Pid . '}`n', Result)
	else if ExpectedKind == "timeout"
		AssertEqual(Prefix . 'timeout","driver_pid":' . Pid . ',"reason":"deadline"}`n', Result)
	else if ExpectedKind == ""
		AssertEqual("", Result)
	else
		throw Error("Unknown control deadline fixture outcome")
}
for _TDC_DeadlinePhase in ["pending", "claimed"]
	for _TDC_DeadlineCase in [
		["future integer", "1700000120", "claimed", "completed"],
		["expired integer", "1", "timeout", "timeout"],
		["boolean true", "true", "", ""],
		["boolean false", "false", "", ""],
		["numeric string", '"1700000120"', "", ""],
		["null", "null", "", ""]
	]
		Test("driver-control: " . _TDC_DeadlinePhase . " " . _TDC_DeadlineCase[1] . " preserves deadline kind (driver-control-deadline-kind)",
			_TDC_DeadlineKind.Bind(_TDC_DeadlinePhase, _TDC_DeadlineCase[2],
				_TDC_DeadlineCase[_TDC_DeadlinePhase == "pending" ? 3 : 4]))

_TDC_RequestIdCharacters(Value, Expected, Length) {
	if Value is String
		AssertEqual(Length, StrLen(Value), "the real identifier fixture must preserve every supplied code unit")
	else
		AssertEqual(0, Length)
	if Expected
		AssertTrue(DriverControl_IsRequestId(Value))
	else
		AssertFalse(DriverControl_IsRequestId(Value), "a control identifier cannot contain a final newline or exceed its complete character limit")
}
_TDC_TokenCharacters(Value, Expected, Length) {
	Spec := _TDC_Spec()
	AssertTrue(Value is String)
	AssertEqual(Length, StrLen(Value), "the token fixture must preserve the actual final newline and complete length")
	if Expected
		AssertTrue(DriverControl_IsToken(Spec, Value))
	else
		AssertFalse(DriverControl_IsToken(Spec, Value), "every token code unit must be a lowercase hexadecimal digit")
}
_TDC_MaxIdentifier := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
for _TDC_IdRow in [
	["allowed alphabet", "aZ_09-", true, 6], ["empty", "", false, 0],
	["maximum length", _TDC_MaxIdentifier, true, 64], ["oversize", _TDC_MaxIdentifier . "a", false, 65],
	["LF suffix", "ok`n", false, 3], ["CRLF suffix", "ok`r`n", false, 4], ["CR suffix", "ok`r", false, 3],
	["maximum LF suffix", _TDC_MaxIdentifier . "`n", false, 65],
	["maximum CRLF suffix", _TDC_MaxIdentifier . "`r`n", false, 66],
	["interior LF", "a`nb", false, 3], ["space suffix", "ok ", false, 3], ["number", 23, false, 0]
]
	Test("driver-control: request id " . _TDC_IdRow[1] . " validates every code unit (driver-control-character-boundaries)",
		_TDC_RequestIdCharacters.Bind(_TDC_IdRow[2], _TDC_IdRow[3], _TDC_IdRow[4]))
for _TDC_TokenRow in [
	["valid hexadecimal", _TDC_MaxIdentifier, true, 64],
	["LF suffix", SubStr(_TDC_MaxIdentifier, 1, 63) . "`n", false, 64],
	["CRLF suffix", SubStr(_TDC_MaxIdentifier, 1, 62) . "`r`n", false, 64],
	["uppercase", StrUpper(_TDC_MaxIdentifier), false, 64],
	["short", SubStr(_TDC_MaxIdentifier, 1, 63), false, 63],
	["long", _TDC_MaxIdentifier . "a", false, 65],
	["CR suffix", SubStr(_TDC_MaxIdentifier, 1, 63) . "`r", false, 64],
	["LF prefix", "`n" . SubStr(_TDC_MaxIdentifier, 1, 63), false, 64],
	["interior LF", SubStr(_TDC_MaxIdentifier, 1, 31) . "`n" . SubStr(_TDC_MaxIdentifier, 33), false, 64]
]
	Test("driver-control: token " . _TDC_TokenRow[1] . " validates every code unit (driver-control-character-boundaries)",
		_TDC_TokenCharacters.Bind(_TDC_TokenRow[2], _TDC_TokenRow[3], _TDC_TokenRow[4]))

_TDC_RequestIdSessionBoundary(Id, Expected) {
	_TDC_World(Body)
	Body(World) {
		World.Session.Start()
		Text := '{"schema":1,"token":"' . World.Token . '","request_id":' . JsonStringLiteral(Id) . "}"
		Decoded := JsonParse(Text)
		AssertEqual(StrLen(Id), StrLen(Decoded["request_id"]))
		AssertEqual(0, StrCompare(Id, Decoded["request_id"], true), "the real JSON file must preserve the complete identifier")
		RequestPath := World.Session.Path("request")
		AssertTrue(FSWriteDurable(RequestPath, Text))
		Acknowledged := World.Endpoint.Call()
		if Expected {
			AssertEqual(1, World.Calls.Length)
			AssertTrue(Acknowledged)
			Result := JsonParse(_TDC_Read(World, "result"))
			AssertEqual("requested", Result["state"])
			AssertEqual(Id, Result["request_id"])
		} else {
			AssertEqual(0, World.Calls.Length, "an invalid complete identifier must never reach the actual reload boundary")
			AssertFalse(Acknowledged)
			Result := JsonParse(_TDC_Read(World, "result"))
			AssertEqual("refused", Result["state"])
			AssertEqual("malformed", Result["reason"])
			AssertTrue(Result["request_id"] == JSON_NULL)
		}
		AssertFalse(FileExist(RequestPath), "the real private request file is consumed exactly once")
	}
}
for _TDC_IdSessionRow in [["valid", "line-id", true], ["LF suffix", "line-id`n", false], ["CRLF suffix", "line-id`r`n", false]]
	Test("driver-control: real request file " . _TDC_IdSessionRow[1] . " respects complete identifier validation (driver-control-character-boundaries)",
		_TDC_RequestIdSessionBoundary.Bind(_TDC_IdSessionRow[2], _TDC_IdSessionRow[3]))

_TDC_ResultStateEnum(Phase, Fields, Expected) {
	Spec := _TDC_Spec(), Canonical := 0
	for Declared in Spec["states"] {
		if StrCompare(Declared, "requested", true) == 0
			Canonical += 1
		AssertTrue(StrCompare(Declared, "REQUESTED", true) != 0,
			"the canonical declaration does not name an uppercase requested state")
	}
	AssertEqual(1, Canonical, "the canonical declaration names the exact lowercase requested state")
	Text := '{"schema":1,"request_id":"state-enum","driver_pid":100,"successor_pid":200,' . Fields . "}"
	Decoded := JsonParse(Text)
	AssertTrue(Decoded is Map)
	AssertEqual("state-enum", Decoded["request_id"])
	AssertTrue(Decoded["successor_pid"] is Integer)
	AssertEqual(200, Decoded["successor_pid"])
	Kind := ""
	if Phase == "completion"
		Result := DriverControl_Completion(Spec, Text, 200)
	else
		Result := DriverControl_Resolve(Spec, Text, 200, 1700000000, &Kind)
	if Expected {
		AssertEqual('{"schema":1,"request_id":"state-enum","state":"completed","driver_pid":200,"successor_pid":200}`n', Result)
		if Phase == "resolution"
			AssertEqual("completed", Kind)
	} else {
		AssertEqual("", Result, "only the canonical declared requested enum can complete a named successor")
		AssertEqual("", Kind)
	}
}
for _TDC_StatePhase in ["completion", "resolution"]
	for _TDC_StateRow in [
		["canonical", '"state":"requested"', true],
		["escaped canonical", '"state":"\u0072equested"', true],
		["uppercase", '"state":"REQUESTED"', false],
		["title case", '"state":"Requested"', false],
		["mixed case", '"state":"rEqUeStEd"', false],
		["other declared state", '"state":"claimed"', false],
		["boolean", '"state":true', false],
		["integer", '"state":1', false],
		["array", '"state":[]', false],
		["object", '"state":{}', false],
		["null", '"state":null', false],
		["last uppercase", '"state":"requested","state":"REQUESTED"', false],
		["last canonical", '"state":"REQUESTED","state":"requested"', true]
	]
		Test("driver-control: " . _TDC_StatePhase . " " . _TDC_StateRow[1] . " follows the canonical state enum (driver-control-state-enum)",
			_TDC_ResultStateEnum.Bind(_TDC_StatePhase, _TDC_StateRow[2], _TDC_StateRow[3]))

_TDC_BootStateEnum(StateName, Expected) {
	_TDC_World(Body)
	Body(World) {
		Pid := World.Session.Pid
		Text := '{"schema":1,"request_id":"boot-state-enum","state":' . JsonStringLiteral(StateName)
			. ',"driver_pid":500,"successor_pid":' . Pid . "}"
		Decoded := JsonParse(Text)
		AssertEqual(0, StrCompare(StateName, Decoded["state"], true))
		AssertTrue(Decoded["successor_pid"] is Integer)
		AssertEqual(Pid, Decoded["successor_pid"])
		FSEnsureDirectoryStrict(World.Folder)
		AssertTrue(FSWriteDurable(World.Session.Path("result"), Text))
		World.Session.Start()
		AssertTrue(World.Session.Active)
		AssertEqual(1, World.Started, "the real session must reach its endpoint after reading the private result file")
		Output := _TDC_Read(World, "result")
		if Expected {
			Result := JsonParse(Output)
			AssertEqual("completed", Result["state"])
			AssertEqual("boot-state-enum", Result["request_id"])
			AssertEqual(Pid, Result["driver_pid"])
			AssertEqual(Pid, Result["successor_pid"])
		} else
			AssertEqual(0, StrCompare(Text, Output, true),
				"startup cannot complete or replace a private pending file whose state is not the declared enum")
	}
}
for _TDC_BootStateRow in [["canonical", "requested", true], ["uppercase", "REQUESTED", false], ["title case", "Requested", false]]
	Test("driver-control: boot private result " . _TDC_BootStateRow[1] . " preserves canonical state admission (driver-control-state-enum)",
		_TDC_BootStateEnum.Bind(_TDC_BootStateRow[2], _TDC_BootStateRow[3]))
