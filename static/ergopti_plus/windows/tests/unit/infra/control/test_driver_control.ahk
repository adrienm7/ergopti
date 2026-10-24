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
		InFlight: InFlight}
	Reload(SuccessFn, Bundle, RefusedFn, StageFn) {
		World.Calls.Push([SuccessFn, Bundle])
		World.Refused := RefusedFn, World.Stage := StageFn
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
	World.Session := DriverControlSession(Spec, Folder, 1000,
		Map("token", (*) => World.Token, "endpoint", Endpoint, "reload", Reload, "pending", Pending))
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
		AssertEqual(1, World.Started, "the endpoint is rung only after the session exists")
		AssertTrue(HasMethod(World.Endpoint, "Call"), "the endpoint runs the session's own handler")
		AssertThrows(() => World.Session.Start(), "a second start is refused")
		World.Session.Stop()
		AssertEqual(1, World.Stopped)
		AssertFalse(FileExist(World.Folder . "\session.json"), "the session withdraws its own file")
	}
}
Test("driver-control: a session publishes its token, then rings its endpoint", _TDC_SessionPublishes)

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
