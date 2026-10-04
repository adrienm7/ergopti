; tests/unit/test_screen_brightness.ahk

; ==============================================================================
; MODULE: Native Screen Brightness Ownership Tests
; DESCRIPTION:
; Replays the independent shared corpus and actual asynchronous adapter owner.
; Process doubles expose acquisition and retirement refusal; no physical screen
; change is inferred from these tests. The provider worker has a separate native
; PowerShell fixture through the same Job-owned shell runner.
; ==============================================================================

#Requires AutoHotkey v2.0

_SBT_Data() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\modules\actions\brightness.json", "UTF-8"))
}

_SBT_Corpus() {
	global _SharedDir
	Data := _SBT_Data()
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\brightness_actions.json", "UTF-8"))
	AssertTrue(Corpus["cases"].Length >= 9, "the independent positive and refusal corpus must run")
	for Vector in Corpus["cases"] {
		AssertEqual(Vector["target"], BrightnessTarget(Data, Vector["action"], Vector["before"]), Vector["name"])
		AssertEqual(Vector["acknowledged"],
			BrightnessAcknowledged(Data, Vector["action"], Vector["receipt"]), Vector["name"])
	}
}
Test("screen brightness: independent native percentage and refusal corpus", _SBT_Corpus)

class _SBT_Process {
	__New() {
		this.starts := 0
		this.retirements := 0
		this.retired := true
		this.started := true
		this.args := []
		this.callback := 0
		this.start_fn := 0
	}
	spawn(Executable, Args, Done, OnChunk?, BeforeAdopt?, MaxOutput := 0) {
		this.executable := Executable
		this.args := Args
		this.callback := Done
		this.max_output := MaxOutput
		return this
	}
	start() {
		this.starts++
		return IsObject(this.start_fn) ? this.start_fn.Call(this) : this.started
	}
	requestTerminate() => (++this.retirements, this.retired)
}

_SBT_Owned(Action, Body, Configure := 0, ExpectedStart := true) {
	Saved := [ScreenBrightnessOwner.job, ScreenBrightnessOwner.generation,
		ScreenBrightnessOwner.spawn_fn, ScreenBrightnessOwner.notify_fn, ScreenBrightnessOwner.data]
	AssertFalse(IsObject(Saved[1]), "the fixture may not replace an existing native owner")
	Fake := _SBT_Process()
	Observed := [], Notices := []
	try {
		ScreenBrightnessOwner.spawn_fn := ObjBindMethod(Fake, "spawn")
		ScreenBrightnessOwner.notify_fn := (Id) => Notices.Push(Id)
		ScreenBrightnessOwner.data := _SBT_Data()
		if IsObject(Configure)
			Configure.Call(Fake)
		AssertEqual(ExpectedStart, ScreenBrightnessRequest(Action, (Result) => Observed.Push(Result)),
			"only an exact native start acknowledgement acquires the injected process")
		Body.Call(Fake, Observed, Notices)
	} finally {
		Fake.retired := true
		ScreenBrightnessCancel("fixture-finally")
		SetTimer(ScreenBrightnessPoll, 0)
		ScreenBrightnessOwner.job := Saved[1]
		ScreenBrightnessOwner.generation := Saved[2]
		ScreenBrightnessOwner.spawn_fn := Saved[3]
		ScreenBrightnessOwner.notify_fn := Saved[4]
		ScreenBrightnessOwner.data := Saved[5]
	}
}

_SBT_Terminal(Fake, Observed, Notices) {
	AssertEqual("powershell.exe", Fake.executable)
	AssertEqual("brightness_up", Fake.args[Fake.args.Length])
	AssertEqual("-ExecutionPolicy", Fake.args[5])
	AssertEqual("Bypass", Fake.args[6], "only the owned process receives the native worker policy")
	AssertEqual("-File", Fake.args[7])
	AssertTrue(InStr(Fake.args[8], "\ergopti_brightness_worker.ps1") > 0,
		"the real worker, rather than an unsupported Send key, owns the effect")
	AssertEqual(8192, Fake.max_output, "native output is bounded")
	AssertEqual(0, Observed.Length, "acquisition is not target acknowledgement")
	AssertFalse(ScreenBrightnessRequest("brightness_down"), "a concurrent request cannot replace the native owner")
	Fake.callback.Call(0, '{"version":1,"action":"brightness_up","status":"applied","displays":[{"before":40,"target":45,"after":45}]}', "")
	AssertEqual(1, Observed.Length)
	AssertTrue(Observed[1])
	AssertFalse(IsObject(ScreenBrightnessOwner.job))
	Fake.callback.Call(0, "", "")
	AssertEqual(1, Observed.Length, "the terminal callback is claimed exactly once")
	AssertEqual(0, Notices.Length)
}
Test("screen brightness: acquires one real native action and requires readback", () => _SBT_Owned("brightness_up", _SBT_Terminal))

_SBT_RefusedReadback(Fake, Observed, Notices) {
	Fake.callback.Call(0, '{"version":1,"action":"brightness_up","status":"applied","displays":[{"before":40,"target":45,"after":40}]}', "")
	AssertEqual(1, Observed.Length)
	AssertFalse(Observed[1], "exit zero and accepted write do not acknowledge an unchanged display")
	AssertEqual(0, Notices.Length)
}
Test("screen brightness: refuses missing native target acknowledgement", () => _SBT_Owned("brightness_up", _SBT_RefusedReadback))

_SBT_Unsupported(Fake, Observed, Notices) {
	Fake.callback.Call(0, '{"version":1,"action":"brightness_up","status":"unsupported","displays":[]}', "")
	AssertFalse(Observed[1])
	AssertEqual(1, Notices.Length)
	AssertEqual("brightness_up", Notices[1], "unsupported capability has the existing translated reason")
}
Test("screen brightness: unsupported providers produce a truthful localized refusal", () => _SBT_Owned("brightness_up", _SBT_Unsupported))


/** Malformed native status still settles exactly once without a capability notice. */
_SBT_MalformedStatus(Payload, ExpectedType, Fake, Observed, Notices) {
	Decoded := JsonParse(Payload)
	AssertEqual(ExpectedType, Type(Decoded["status"]), "the actual JSON decoder supplies the independent malformed native type")
	Failure := 0
	try Fake.callback.Call(0, Payload, "")
	catch as Err {
		Failure := Err
	}
	AssertFalse(IsObject(Failure), "malformed native status cannot throw between owner retirement and terminal acknowledgement")
	AssertEqual(1, Observed.Length, "the settled malformed receipt must deliver Done exactly once")
	AssertFalse(Observed[1], "a malformed receipt cannot acknowledge a physical backlight change")
	AssertEqual(0, Notices.Length, "malformed status is not evidence of an unsupported provider")
	AssertFalse(IsObject(ScreenBrightnessOwner.job), "the exact settled native owner is retired")
	Fake.callback.Call(0, '{"version":1,"action":"brightness_up","status":"unsupported","displays":[]}', "")
	AssertEqual(1, Observed.Length, "a late same-generation callback cannot repeat terminal delivery")
	AssertEqual(0, Notices.Length, "a late unsupported receipt cannot publish after malformed settlement")
}
Test("screen brightness: object status refuses without losing terminal acknowledgement", () => _SBT_Owned("brightness_up",
	_SBT_MalformedStatus.Bind('{"version":1,"action":"brightness_up","status":{},"displays":[]}', "Map")))
Test("screen brightness: array status refuses without losing terminal acknowledgement", () => _SBT_Owned("brightness_up",
	_SBT_MalformedStatus.Bind('{"version":1,"action":"brightness_up","status":[],"displays":[]}', "Array")))
Test("screen brightness: numeric status refuses without losing terminal acknowledgement", () => _SBT_Owned("brightness_up",
	_SBT_MalformedStatus.Bind('{"version":1,"action":"brightness_up","status":42,"displays":[]}', "Integer")))

_SBT_CleanupDebt(Fake, Observed, Notices) {
	Fake.retired := false
	Owner := ScreenBrightnessOwner.job
	AssertFalse(ScreenBrightnessCancel("fixture-refusal"))
	AssertTrue(ScreenBrightnessOwner.job == Owner, "the exact handle and generation survive retirement refusal")
	AssertEqual(0, Observed.Length, "unsettled native cleanup may not deliver a terminal")
	AssertFalse(ScreenBrightnessRequest("brightness_down"), "retained debt closes new acquisition")
	Fake.retired := true
	AssertTrue(ScreenBrightnessCancel("fixture-retry"))
	AssertEqual(1, Observed.Length)
	AssertFalse(Observed[1], "a canceled request cannot publish a late successful readback")
	Fake.callback.Call(0, '{"version":1,"action":"brightness_up","status":"applied","displays":[{"before":40,"target":45,"after":45}]}', "")
	AssertEqual(1, Observed.Length)
	AssertEqual(0, Notices.Length)
}
Test("screen brightness: cleanup refusal retains ownership and rejects stale publication", () => _SBT_Owned("brightness_up", _SBT_CleanupDebt))

_SBT_Deadline(Fake, Observed, Notices) {
	ScreenBrightnessOwner.job["started"] := A_TickCount - _SBT_Data()["worker_timeout_ms"] - 1
	ScreenBrightnessPoll()
	AssertEqual(1, Fake.retirements, "the original bounded deadline retires the exact native child")
	AssertEqual(1, Observed.Length)
	AssertFalse(Observed[1])
	AssertEqual(0, Notices.Length, "a timeout is not an unsupported-provider receipt")
}
Test("screen brightness: native worker deadline cancels rather than acknowledging late work", () => _SBT_Owned("brightness_up", _SBT_Deadline))

_SBT_ForeignUnsupported(Fake, Observed, Notices) {
	Fake.callback.Call(0, '{"version":1,"action":"brightness_down","status":"unsupported","displays":[]}', "")
	AssertFalse(Observed[1])
	AssertEqual(0, Notices.Length, "a foreign action receipt cannot publish a capability explanation")
}
Test("screen brightness: foreign capability receipts cannot publish a reason", () => _SBT_Owned("brightness_up", _SBT_ForeignUnsupported))

_SBT_InvalidHandleAck(Fake) {
	Fake.started := Fake
	Fake.retired := Fake
}

_SBT_InvalidNativeAck(Fake, Observed, Notices) {
	Owner := ScreenBrightnessOwner.job
	AssertTrue(IsObject(Owner), "a returned handle is not a native start or retirement acknowledgement")
	AssertEqual(1, Fake.starts)
	AssertEqual(1, Fake.retirements)
	AssertEqual(0, Observed.Length, "unsettled startup cleanup retains notification")
	AssertFalse(ScreenBrightnessCancel("fixture-object-refusal"))
	AssertTrue(ScreenBrightnessOwner.job == Owner, "truthy objects cannot discharge the exact native debt")
	AssertEqual(0, Observed.Length)
	Fake.retired := true
	AssertTrue(ScreenBrightnessCancel("fixture-exact-retry"))
	AssertEqual(1, Observed.Length)
	AssertFalse(Observed[1], "failed startup cannot later become a successful effect")
	AssertEqual(0, Notices.Length)
}
Test("screen brightness: native handle objects cannot acknowledge start or retirement", () => _SBT_Owned("brightness_up", _SBT_InvalidNativeAck, _SBT_InvalidHandleAck, false))

_SBT_ThrowingNotice(Fake, Observed, Notices) {
	ScreenBrightnessOwner.notify_fn := (Action) => _SBT_NoticeThrow()
	Fake.callback.Call(0, '{"version":1,"action":"brightness_up","status":"unsupported","displays":[]}', "")
	AssertEqual(1, Observed.Length, "a failed notice cannot suppress an already settled terminal")
	AssertFalse(Observed[1])
	AssertFalse(IsObject(ScreenBrightnessOwner.job))
}
_SBT_NoticeThrow() {
	throw Error("Injected unsupported notice refusal.")
}
Test("screen brightness: notice refusal preserves exact terminal settlement", () => _SBT_Owned("brightness_up", _SBT_ThrowingNotice))





; =============================================
; =============================================
; ======= 1/ Native provider worker ABI =======
; =============================================
; =============================================

; Observe the exact acquired state without changing native ownership.
_SBT_ObserveNative(Control, State, Native) {
	Control["state"] := State
}

_SBT_DiagnosticFlag(Value) {
	return (Value is Integer) && (Value == 0 || Value == 1) ? String(Value) : "unavailable"
}

_SBT_DiagnosticCount(Value) {
	return (Value is Integer) && Value >= 0 ? String(Value) : "unavailable"
}

_SBT_DiagnosticWait(ProcessHandle) {
	Result := DllCall("Kernel32\WaitForSingleObject", "ptr", ProcessHandle, "uint", 0, "uint")
	return Result == 0 ? "exited" : (Result == 258 ? "running" : "failed")
}

_SBT_DiagnosticJob(JobHandle) {
	Diagnostic := ""
	return _SR_TreeActiveProcessCount(JobHandle, &Diagnostic)
}

_SBT_DiagnosticSize(Path) {
	return FileGetSize(Path)
}

; Closed observations precede finally's mandatory callback detachment. Queries
; never close handles, retire a task, drain a claim, read output, or wait for work.
_SBT_NativeDiagnostic(Control, Elapsed, Polls, WaitFn := 0, JobFn := 0, SizeFn := 0) {
	if !IsObject(WaitFn)
		WaitFn := _SBT_DiagnosticWait
	if !IsObject(JobFn)
		JobFn := _SBT_DiagnosticJob
	if !IsObject(SizeFn)
		SizeFn := _SBT_DiagnosticSize
	Facts := "elapsed_ms=" . _SBT_DiagnosticCount(Elapsed) . ";polls=" . _SBT_DiagnosticCount(Polls)
		. ";suspended=" . _SBT_DiagnosticFlag(A_IsSuspended)
	State := Control.Get("state", 0)
	if !(State is Map)
		return Facts . ";state=unobserved"
	Facts .= ";state=observed"
	PreviousCritical := Critical("On")
	try {
		for _, Key in ["Starting", "Started", "RootReaped", "TerminalClaimed", "TreeQuiesced", "FinalizationPending", "Detached"]
			Facts .= ";" . Key . "=" . _SBT_DiagnosticFlag(State.Get(Key, "unavailable"))
		Claim := State.Get("TerminalClaim", 0)
		for _, Key in ["Finished", "CompletionBusy"]
			Facts .= ";" . Key . "=" . _SBT_DiagnosticFlag((Claim is Map) ? Claim.Get(Key, "unavailable") : "unavailable")
		Wait := "unavailable", Active := "unavailable", Exit := "unavailable"
		NativeOwner := (Claim is Map) ? Claim : State
		ProcessHandle := NativeOwner.Get("ProcessHandle", 0)
		JobHandle := NativeOwner.Get("JobHandle", 0)
		if (ProcessHandle is Integer) && ProcessHandle > 0 {
			try {
				ObservedWait := WaitFn.Call(ProcessHandle)
				if (ObservedWait is String) && (StrCompare(ObservedWait, "running", true) == 0
					|| StrCompare(ObservedWait, "exited", true) == 0 || StrCompare(ObservedWait, "failed", true) == 0)
					Wait := ObservedWait
			}
		}
		if (JobHandle is Integer) && JobHandle > 0 {
			try Active := _SBT_DiagnosticCount(JobFn.Call(JobHandle))
		}
		if _SBT_DiagnosticFlag(State.Get("RootReaped", "unavailable")) == "1" {
			Value := State.Get("ExitCode", "unavailable")
			if Value is Integer
				Exit := String(Value)
		}
		Facts .= ";native_wait=" . Wait . ";job_active=" . Active . ";exit=" . Exit
		CapturePath := State.Get("TmpFile", "")
	} finally Critical(PreviousCritical)
	Bytes := "unavailable"
	if (CapturePath is String) && CapturePath != "" {
		try Bytes := _SBT_DiagnosticCount(SizeFn.Call(CapturePath))
	}
	return Facts . ";capture_bytes=" . Bytes
}

_SBT_DiagnosticStates() {
	State := Map("Starting", false, "Started", true, "RootReaped", false, "TerminalClaimed", false,
		"TreeQuiesced", false, "FinalizationPending", false, "Detached", false,
		"ProcessHandle", 17, "JobHandle", 29, "ExitCode", 7, "TmpFile", "private fixture capture")
	Control := Map()
	_SBT_ObserveNative(Control, State, Map())
	WaitCalls := [], JobCalls := [], SizeCalls := []
	Wait(Handle) {
		WaitCalls.Push(Handle)
		return "running"
	}
	Job(Handle) {
		JobCalls.Push(Handle)
		return 1
	}
	Size(Path) {
		SizeCalls.Push(Path)
		return 0
	}
	Facts := _SBT_NativeDiagnostic(Control, 5000, 41, Wait, Job, Size)
	AssertEqual(1, WaitCalls.Length)
	AssertEqual(17, WaitCalls[1], "the observer queries the acquired root handle")
	AssertEqual(1, JobCalls.Length)
	AssertEqual(29, JobCalls[1], "the observer queries the acquired job handle")
	AssertEqual(1, SizeCalls.Length)
	AssertTrue(InStr(Facts, ";native_wait=running;job_active=1;exit=unavailable") > 0,
		"a running root cannot project the unacknowledged default exit code")
	AssertTrue(InStr(Facts, ";capture_bytes=0") > 0)
	State["RootReaped"] := true
	State["TerminalClaimed"] := true
	State["TreeQuiesced"] := true
	State["ProcessHandle"] := 0
	State["JobHandle"] := 0
	State["TerminalClaim"] := Map("Finished", true, "CompletionBusy", false,
		"ProcessHandle", 0, "JobHandle", 0)
	Facts := _SBT_NativeDiagnostic(Control, 5000, 42, Wait, Job, Size)
	AssertTrue(InStr(Facts, ";RootReaped=1;TerminalClaimed=1;TreeQuiesced=1") > 0)
	AssertTrue(InStr(Facts, ";Finished=1;CompletionBusy=0;native_wait=unavailable;job_active=unavailable;exit=7") > 0)
	AssertEqual(1, WaitCalls.Length, "an already retired root is not queried through a missing handle")
	AssertEqual(1, JobCalls.Length)
	AssertEqual(17, WaitCalls[1], "observing settlement never rewrites the captured handle")
}
Test("screen brightness: closed diagnostic distinguishes running and retired native stages", _SBT_DiagnosticStates)

_SBT_DiagnosticPrivacy() {
	Secret := "PRIVATE_DIAGNOSTIC_BODY"
	State := Map("Started", "0", "RootReaped", "1", "TerminalClaimed", Map(), "Detached", [],
		"ProcessHandle", 17, "JobHandle", 29, "ExitCode", Secret, "TmpFile", Secret,
		"Command", Secret, "Pid", 987654321)
	Facts := _SBT_NativeDiagnostic(Map("state", State), Secret, -1, (*) => Secret, (*) => Secret, (*) => Secret)
	AssertEqual(0, InStr(Facts, Secret), "neither malformed values nor native capture paths are public diagnostic facts")
	AssertEqual(0, InStr(Facts, "987654321"), "native process identity is never printed")
	AssertTrue(InStr(Facts, "elapsed_ms=unavailable;polls=unavailable") > 0)
	AssertTrue(InStr(Facts, ";Started=unavailable;RootReaped=unavailable;TerminalClaimed=unavailable") > 0)
	AssertTrue(InStr(Facts, ";native_wait=unavailable;job_active=unavailable;exit=unavailable;capture_bytes=unavailable") > 0)
	AssertTrue(InStr(_SBT_NativeDiagnostic(Map(), 0, 0), ";state=unobserved") > 0)
}
Test("screen brightness: closed diagnostic refuses malformed private observations", _SBT_DiagnosticPrivacy)


_SBT_NativeProvider(Mode, ExpectedStatus, ExpectedExit, ExpectedCalls := 1,
		ExpectedStage := "readback", ExpectedPolicyType := "object") {
	global _DriverDir, _SharedDir, _VendorDir
	Observed := [], Control := Map(), Polls := 0
	Handle := ShellRunner_SpawnTreeOwned("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", _DriverDir . "\tests\fixtures\screen_brightness_provider.ps1",
		"-Worker", _VendorDir . "\ergopti_brightness_worker.ps1",
		"-FixturePolicyPath", _SharedDir . "\modules\actions\brightness.json",
		"-Action", "brightness_up", "-Mode", Mode],
		(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , _SBT_ObserveNative.Bind(Control), 8192)
	try {
		AssertTrue(Handle.start(), "the native owned child must really start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired(Started, 5000) {
			Polls++
			_SR_TreePoll()
			Sleep(10)
		}
		Diagnostic := _SBT_NativeDiagnostic(Control, TickElapsed(Started), Polls)
		AssertEqual(1, Observed.Length, "the actual native provider worker settles once; " . Diagnostic)
		AssertEqual("", Observed[1]["stderr"], "the real provider fixture exposes no hidden native failure")
		Receipt := JsonParse(Observed[1]["stdout"])
		AssertEqual(ExpectedCalls, Receipt["fixture_calls"], "only the exact native WMI writer contributes a call")
		AssertEqual(ExpectedStage, Receipt["fixture_stage"], "the actual provider records its closed terminal stage")
		AssertEqual(ExpectedPolicyType, Receipt["fixture_policy_type"], "the worker retains its real policy type across the fixture scope")
		AssertEqual(ExpectedExit, Observed[1]["exit"])
		AssertEqual(ExpectedStatus, Receipt["status"])
		AssertEqual("brightness_up", Receipt["action"])
		AssertEqual(ExpectedStatus == "applied", BrightnessAcknowledged(_SBT_Data(), "brightness_up", Receipt),
			"the real worker and shared readback policy agree")
	} finally {
		AssertTrue(Handle.terminate(), "the exact native child tree must physically settle")
	}
}
Test("screen brightness: native PowerShell provider uses the actual WMI ABI", () => _SBT_NativeProvider("applied", "applied", 0))
Test("screen brightness: native PowerShell refuses absent backlight providers", () => _SBT_NativeProvider("unsupported", "unsupported", 0, 0, "enumerate_methods"))
Test("screen brightness: native PowerShell refuses an unacknowledged write", () => _SBT_NativeProvider("write-refused", "refused", 1, 1, "write"))
Test("screen brightness: native PowerShell refuses a mismatched readback", () => _SBT_NativeProvider("readback-refused", "refused", 1))
Test("screen brightness: native String-constrained dot-source policy reproduces the original provider refusal",
	() => _SBT_NativeProvider("typed-policy-collision", "refused", 1, 0, "before_provider", "string"))





; ==========================================================
; ==========================================================
; ======= 2/ Reentrant exact native start retirement =======
; ==========================================================
; ==========================================================

_SBT_ReentryAdopt(Control, State, Native) {
	Control["state"] := State
	Control["native_created"] := State["Starting"] && !State["Started"]
		&& Native["Assigned"] && Native["ProcessHandle"] != 0
		&& Native["ThreadHandle"] != 0 && Native["JobHandle"] != 0
	Control["cancel_result"] := ScreenBrightnessCancel("fixture-native-starting")
	Control["during_adopt_results"] := Control["first_results"].Length
}

_SBT_ReentryFakeStart(Control, Fake) {
	Fake.callback.Call(1, "", "")
	if Control["throw_after"]
		throw Error("Injected start failure after exact terminal delivery.")
	return false
}

_SBT_ReentrySpawn(Control, Executable, Args, Done, OnChunk?, BeforeAdopt?, MaxOutput := 0) {
	Handle := Control["native_start"]
		? ShellRunner_SpawnTreeOwned(Executable, Args, Done, , _SBT_ReentryAdopt.Bind(Control), MaxOutput)
		: Control["first"].spawn(Executable, Args, Done, , , MaxOutput)
	Control["first_handle"] := Handle
	return Handle
}

_SBT_ReentryTerminal(Control, Result) {
	Control["first_results"].Push(Result)
	Control["done_before_return"] := !Control["request_returned"]
	ScreenBrightnessOwner.spawn_fn := ObjBindMethod(Control["second"], "spawn")
	Control["successor_started"] := ScreenBrightnessRequest("brightness_down",
		(SuccessorResult) => Control["second_results"].Push(SuccessorResult))
	Control["successor"] := ScreenBrightnessOwner.job
}

_SBT_Reentry(NativeStart, ThrowAfter := false) {
	Saved := [ScreenBrightnessOwner.job, ScreenBrightnessOwner.generation,
		ScreenBrightnessOwner.spawn_fn, ScreenBrightnessOwner.notify_fn, ScreenBrightnessOwner.data]
	AssertFalse(IsObject(Saved[1]), "reentry may not replace a preexisting native owner")
	Control := Map("native_start", NativeStart, "throw_after", ThrowAfter,
		"first", _SBT_Process(), "second", _SBT_Process(), "first_handle", 0,
		"first_results", [], "second_results", [], "notices", [],
		"request_returned", false, "successor_started", false, "successor", 0,
		"done_before_return", false, "native_created", false, "cancel_result", true,
		"during_adopt_results", -1, "state", 0)
	Control["first"].start_fn := _SBT_ReentryFakeStart.Bind(Control)
	OriginalId := Saved[2] + 1
	try {
		ScreenBrightnessOwner.spawn_fn := _SBT_ReentrySpawn.Bind(Control)
		ScreenBrightnessOwner.notify_fn := (Action) => Control["notices"].Push(Action)
		ScreenBrightnessOwner.data := _SBT_Data()
		Started := ScreenBrightnessRequest("brightness_up", _SBT_ReentryTerminal.Bind(Control))
		Control["request_returned"] := true
		SetTimer(ScreenBrightnessPoll, 0)
		AssertFalse(Started, "the original canceled or failed native start reports false")
		AssertTrue(Control["done_before_return"], "the terminal successor must actually precede start return")
		AssertEqual(1, Control["first_results"].Length)
		AssertFalse(Control["first_results"][1])
		AssertTrue(Control["successor_started"], "the terminal callback legitimately acquires a fresh owner")
		AssertTrue(IsObject(ScreenBrightnessOwner.job), "the old stack may not retire its callback's successor")
		AssertTrue(ScreenBrightnessOwner.job == Control["successor"], "the exact successor identity survives")
		AssertEqual(OriginalId + 1, ScreenBrightnessOwner.job["id"])
		AssertEqual("brightness_down", ScreenBrightnessOwner.job["action"])
		AssertEqual(1, Control["second"].starts)
		AssertEqual(0, Control["second"].retirements, "the first failed-start cleanup may not touch a different handle")
		AssertEqual(0, Control["second_results"].Length)
		if NativeStart {
			State := Control["state"]
			AssertTrue(Control["native_created"], "the real Job/process/thread existed privately before cancellation")
			AssertFalse(Control["cancel_result"], "STARTING cancellation waits for actual native retirement")
			AssertEqual(0, Control["during_adopt_results"], "the pending native child may not deliver early")
			AssertTrue(State["TerminalClaimed"] && State["TreeQuiesced"] && !State["FinalizationPending"])
			AssertEqual(0, State["ProcessHandle"])
			AssertEqual(0, State["ThreadHandle"])
			AssertEqual(0, State["JobHandle"])
			AssertEqual(0, State["Pid"])
			AssertFalse(_SR_TreeOwnedTasks.Has(State["TaskId"]), "the canceled real child is not retained as live")
		}
		AssertFalse(ScreenBrightnessCancel("fixture-stale-owner", OriginalId))
		AssertTrue(ScreenBrightnessOwner.job == Control["successor"], "a stale explicit generation is refused")
		AssertEqual(0, Control["second"].retirements)
		AssertTrue(ScreenBrightnessCancel("fixture-exact-successor", OriginalId + 1))
		AssertEqual(1, Control["second_results"].Length)
		AssertFalse(Control["second_results"][1], "generic cancellation still reports a canceled request")
		AssertEqual(0, Control["notices"].Length)
	} finally {
		try {
			ScreenBrightnessCancel("fixture-reentry-finally")
			if NativeStart && IsObject(Control["first_handle"])
				AssertTrue(Control["first_handle"].terminate(), "the exact real suspended child must physically settle")
		} finally {
			SetTimer(ScreenBrightnessPoll, 0)
			ScreenBrightnessOwner.job := Saved[1]
			ScreenBrightnessOwner.generation := Saved[2]
			ScreenBrightnessOwner.spawn_fn := Saved[3]
			ScreenBrightnessOwner.notify_fn := Saved[4]
			ScreenBrightnessOwner.data := Saved[5]
		}
	}
}
Test("screen brightness: synchronous canceled start preserves its terminal successor", () => _SBT_Reentry(false))
Test("screen brightness: a start throw after terminal delivery preserves its successor", () => _SBT_Reentry(false, true))
Test("screen brightness: actual ShellRunner STARTING retirement preserves a reentrant successor", () => _SBT_Reentry(true))
