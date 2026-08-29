; tests/unit/test_llm_temp_artifact_terminal_ownership.ahk

; ==============================================================================
; MODULE: LLM Temporary Artifact Terminal Ownership Regression Tests
; DESCRIPTION:
; Proves that every failure before a curl poller accepts ownership leaves the
; request's payload, response, status, exit, and credential artifacts absent.
; The writer case injects a real prefix write followed by a short count, while
; the transport cases inject launch and poll-admission failures without starting
; a process or reaching the network.
; ==============================================================================




; =========================================================
; =========================================================
; ======= 1/ Deterministic Artifact Failure Ports =========
; =========================================================
; =========================================================

class _LTATO_PartialFile {
	__New(Path, State) {
		this.Handle := FileOpen(Path, "w", "UTF-8-RAW")
		this.State := State
	}

	Write(Content) {
		return this.Handle.Write(SubStr(Content, 1, 7))
	}

	Close() {
		if IsObject(this.Handle) {
			this.Handle.Close()
			this.Handle := 0
		}
		this.State["close_calls"] += 1
	}
}

_LTATO_OpenPartial(State, Path, Mode, Encoding) {
	return _LTATO_PartialFile(Path, State)
}

_LTATO_UniqueDir(Suffix) {
	Path := A_Temp . "\ergopti_ahk006_" . Suffix . "_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	DirCreate(Path)
	return Path
}

_LTATO_DeleteDir(Path) {
	if InStr(Path, A_Temp . "\ergopti_ahk006_") != 1
		throw Error("refusing to delete unexpected test directory")
	if DirExist(Path)
		DirDelete(Path, true)
}

_LTATO_RecordFailure(State, *) {
	State["fail_calls"] += 1
}

_LTATO_RecordDeleteResult(State, Result) {
	State["callback_calls"] += 1
	State["callback_value"] := Result
}

_LTATO_RemoteRunWritesThenThrows(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["run_calls"] += 1
	Pid := 0
	for Path in State["launch_paths"]
		FileAppend("partial", Path, "UTF-8-RAW")
	throw Error("injected remote launch failure")
}

_LTATO_CreateOllamaLaunchArtifacts(State) {
	Payload := ""
	loop files State["dir"] . "\ergopti_ollama_delete_*.json", "F" {
		Payload := A_LoopFileFullPath
		break
	}
	if Payload == ""
		throw Error("delete payload was not created before launch")
	Output := RegExReplace(Payload, "\.json$", ".out")
	State["paths"] := [Payload, Output, Output . ".status", Output . ".exit"]
	for Index, Path in State["paths"] {
		if Index > 1
			FileAppend("partial", Path, "UTF-8-RAW")
	}
}

_LTATO_OllamaRunThrows(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["run_calls"] += 1
	Pid := 0
	_LTATO_CreateOllamaLaunchArtifacts(State)
	throw Error("injected Ollama launch failure")
}

_LTATO_OllamaRunSucceeds(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["run_calls"] += 1
	Pid := 4242
	ProcessOwner := Map("pid", Pid, "handle", 9242, "released", false)
	_LTATO_CreateOllamaLaunchArtifacts(State)
}

_LTATO_OllamaPollThrows(*) {
	throw Error("injected Ollama poll-admission failure")
}

_LTATO_AssertAbsent(Paths, Label) {
	for Path in Paths
		AssertFalse(FileExist(Path), Label . " must delete " . Path)
}




; ====================================================
; ====================================================
; ======= 2/ Complete-or-Absent Writer ================
; ====================================================
; ====================================================

_LTATO_WriterDeletesShortPrefix() {
	Dir := _LTATO_UniqueDir("writer")
	Path := Dir . "\remote-token.conf"
	State := Map("close_calls", 0)
	try {
		Result := FSWrite(Path, "Authorization: Bearer secret-token", _LTATO_OpenPartial.Bind(State), FileDelete)
		AssertFalse(Result, "a short UTF-8 write must report failure")
		AssertEqual(1, State["close_calls"], "the partial handle must close exactly once")
		AssertFalse(FileExist(Path), "a partial credential file must be absent after failure")
	} finally {
		_LTATO_DeleteDir(Dir)
	}
}
Test("AHK-006 temp artifact ownership: a short writer deletes its credential prefix (ahk-006-temp-artifact-terminal-ownership)", _LTATO_WriterDeletesShortPrefix)


_LTATO_DurableWriterRejectsShortStage() {
	Dir := _LTATO_UniqueDir("durable_writer")
	Destination := Dir . "\config.toml"
	Stage := Destination . ".stage"
	State := Map("close_calls", 0, "flush_calls", 0)
	FlushFn := (Fh) => (State["flush_calls"] += 1, true)
	try {
		AssertTrue(FSWrite(Destination, "user-owned"))
		Result := FSWriteDurable(Stage, "replacement config bytes",
			_LTATO_OpenPartial.Bind(State), FileDelete, FlushFn)
		AssertFalse(Result, "a short durable UTF-8 stage write must report failure")
		AssertEqual(1, State["close_calls"],
			"the partial durable handle must close exactly once")
		AssertEqual(0, State["flush_calls"],
			"a short write must fail before a flush can bless its prefix")
		AssertFalse(FileExist(Stage),
			"a partial durable stage must be deleted before returning")
		AssertEqual("user-owned", FSRead(Destination),
			"a rejected stage must preserve the destination bytes")
	} finally {
		_LTATO_DeleteDir(Dir)
	}
}
Test("filesystem: durable short writes never publish stages (AHK-059)",
	_LTATO_DurableWriterRejectsShortStage)




; ====================================================
; ====================================================
; ======= 3/ Remote Curl Pre-Poll Ownership ===========
; ====================================================
; ====================================================

_LTATO_RemoteLaunchFailureDeletesEveryArtifact() {
	global _LLM_Remote_Async
	Dir := _LTATO_UniqueDir("remote")
	ReqId := "ahk006_remote"
	Tick := 61006
	Base := Dir . "\ergopti_remote_" . ReqId . "_" . Tick
	Paths := [Base . ".json", Base . ".out", Base . ".conf", Base . ".out.status", Base . ".out.exit"]
	State := Map("fail_calls", 0, "run_calls", 0, "launch_paths", [Paths[2], Paths[4], Paths[5]])
	Port := Map(
		"file_exists", (*) => true,
		"temp_dir", (*) => Dir,
		"write", FSWrite,
		"delete", FSDelete,
		"run", _LTATO_RemoteRunWritesThenThrows.Bind(State),
		"tick", (*) => Tick)
	Resolved := Map("Format", "openai", "Token", "secret-token", "Model", "model")
	try {
		Owned := _LLMRemote_DispatchCurl(ReqId, Resolved, "https://example.invalid/v1", '{"input":"private"}',
			(*) => 0, _LTATO_RecordFailure.Bind(State), 1000, Port)
		AssertTrue(Owned, "curl availability transfers terminal failure to the dispatcher callback")
		AssertEqual(1, State["run_calls"], "remote dispatch must invoke its child-process port exactly once")
		AssertEqual(1, State["fail_calls"], "launch failure must invoke on_fail exactly once")
		_LTATO_AssertAbsent(Paths, "remote launch failure")
		AssertFalse(_LLM_Remote_Async.Has(ReqId), "a pre-poll failure must not publish a registry owner")
	} finally {
		if _LLM_Remote_Async.Has(ReqId)
			_LLM_Remote_Async.Delete(ReqId)
		_LTATO_DeleteDir(Dir)
	}
}
Test("AHK-006 temp artifact ownership: remote launch failure deletes payload stdout token status and exit (ahk-006-temp-artifact-terminal-ownership)", _LTATO_RemoteLaunchFailureDeletesEveryArtifact)




; ====================================================
; ====================================================
; ======= 4/ Ollama Delete Pre-Poll Ownership =========
; ====================================================
; ====================================================

_LTATO_OllamaPort(State, RunFn, PollFn := 0, WriteFn := 0) {
	Port := Map(
		"temp_dir", (*) => State["dir"],
		"write", HasMethod(WriteFn, "Call") ? WriteFn : FSWrite,
		"delete", FSDelete,
		"run", RunFn,
		"terminate_process", (*) => true,
		"close_process", (*) => true,
		"tick", (*) => 62006)
	if PollFn
		Port["poll"] := PollFn
	return Port
}

_LTATO_OllamaLaunchFailureDeletesEveryArtifact() {
	Dir := _LTATO_UniqueDir("ollama_launch")
	State := Map("dir", Dir, "paths", [], "run_calls", 0, "callback_calls", 0, "callback_value", true)
	try {
		LLM_OllamaDeleteModel_Async("private-model", _LTATO_RecordDeleteResult.Bind(State),
			_LTATO_OllamaPort(State, _LTATO_OllamaRunThrows.Bind(State)))
		AssertEqual(1, State["run_calls"], "Ollama delete must invoke its child-process port exactly once")
		AssertEqual(1, State["callback_calls"], "launch failure must invoke the delete callback exactly once")
		AssertFalse(State["callback_value"], "launch failure must report false")
		AssertEqual(4, State["paths"].Length, "the fake launch must create every owned delete artifact")
		_LTATO_AssertAbsent(State["paths"], "Ollama launch failure")
	} finally {
		_LTATO_DeleteDir(Dir)
	}
}
Test("AHK-006 temp artifact ownership: Ollama launcher throw deletes every pre-poll path (ahk-006-temp-artifact-terminal-ownership)", _LTATO_OllamaLaunchFailureDeletesEveryArtifact)

_LTATO_OllamaPollFailureDeletesEveryArtifact() {
	Dir := _LTATO_UniqueDir("ollama_poll")
	State := Map("dir", Dir, "paths", [], "run_calls", 0, "callback_calls", 0, "callback_value", true)
	try {
		LLM_OllamaDeleteModel_Async("private-model", _LTATO_RecordDeleteResult.Bind(State),
			_LTATO_OllamaPort(State, _LTATO_OllamaRunSucceeds.Bind(State), _LTATO_OllamaPollThrows))
		AssertEqual(1, State["run_calls"], "Ollama delete must launch exactly once before poll admission")
		AssertEqual(1, State["callback_calls"], "poll-admission failure must invoke the delete callback exactly once")
		AssertFalse(State["callback_value"], "poll-admission failure must report false")
		AssertEqual(4, State["paths"].Length, "the fake poll boundary must own every delete artifact")
		_LTATO_AssertAbsent(State["paths"], "Ollama poll-admission failure")
	} finally {
		_LTATO_DeleteDir(Dir)
	}
}
Test("AHK-006 temp artifact ownership: Ollama poll throw retains pre-poll cleanup ownership (ahk-006-temp-artifact-terminal-ownership)", _LTATO_OllamaPollFailureDeletesEveryArtifact)


_LTATO_OllamaCancelDuringWrite(State, Path, Content) {
	State["write_calls"] += 1
	_LLM_AuxRetireOwner(State["owner"], true)
	return true
}

_LTATO_OllamaRunAfterCancellation(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["run_calls"] += 1
	Pid := 4243
	ProcessOwner := Map("pid", Pid, "handle", 9243, "released", false)
}

_LTATO_OllamaDeleteCancellationBeforeLaunch() {
	Dir := _LTATO_UniqueDir("ollama_cancel_before_launch")
	Owner := LLM_AuxBegin("test_ollama_delete_cancel_" . A_TickCount)
	State := Map("dir", Dir, "owner", Owner, "write_calls", 0,
		"run_calls", 0, "callback_calls", 0, "callback_value", true)
	Port := _LTATO_OllamaPort(State,
		_LTATO_OllamaRunAfterCancellation.Bind(State), 0,
		_LTATO_OllamaCancelDuringWrite.Bind(State))
	try {
		LLM_OllamaDeleteModel_Async("private-model", _LTATO_RecordDeleteResult.Bind(State), Port, Owner)
		AssertEqual(1, State["write_calls"], "the delete payload write seam must run once")
		AssertEqual(0, State["run_calls"], "cancellation during delete payload write must prevent the destructive curl launch")
		AssertEqual(0, State["callback_calls"], "an invalidated delete owner must not publish a stale result")
		AssertFalse(LLM_AuxIsCurrent(Owner), "cancellation during payload write must retire the exact delete owner")
	} finally {
		if LLM_AuxIsCurrent(Owner)
			_LLM_AuxRetireOwner(Owner, true)
		_LTATO_DeleteDir(Dir)
	}
}
Test("LLM Ollama delete: cancellation during payload write prevents destructive curl launch (AHK-154)", _LTATO_OllamaDeleteCancellationBeforeLaunch)
