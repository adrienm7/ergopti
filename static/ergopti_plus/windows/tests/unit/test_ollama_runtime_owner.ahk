; tests/unit/test_ollama_runtime_owner.ahk

#Requires AutoHotkey v2.0

Test("Ollama runtime: canonical lazy task adopted before start", _ORT_Adoption)
Test("Ollama runtime: failed start strict physical ACK without callback", _ORT_FailedStart)
Test("Ollama runtime: nonBoolean termination cannot release leases", _ORT_FalseAck)
Test("Ollama runtime: retained file retirement debt blocks successors", _ORT_RetirementDebt)
Test("Ollama runtime: exact source process receipt publishes once", _ORT_ReadyOnce)
Test("Ollama runtime: foreign or stale readiness receipt refuses", _ORT_ReadyForeign)
Test("Ollama runtime: cancellation withdraws readiness publication", _ORT_CancelReady)
Test("Ollama runtime: callback during terminate preserves exact owner", _ORT_TerminalReentry)
Test("Ollama runtime: models cannot point outside managed root", _ORT_Models)
Test("Ollama runtime: constructing cancellation adopts old task", _ORT_ConstructCancel)
Test("Ollama runtime: mismatched constructor cannot replace task", _ORT_Mismatch)
Test("Ollama runtime: native spawn forwards canonical private slots", _ORT_CanonicalSpawn)
Test("Ollama runtime: native architecture uses closed host machine observation", _ORT_Architecture)
Test("Ollama runtime: terminal during refused start cannot publish exit", _ORT_EarlyTerminal)
Test("Ollama runtime: receipt read cannot renew the original readiness deadline", _ORT_Deadline)

class _ORT_Fixture {
	__New() {
		this.Starts := 0
		this.Stops := 0
		this.ReadyCalls := 0
		this.ExitCalls := 0
		this.RetireCalls := 0
		this.Errors := []
		this.CurrentValue := true
		this.StartValue := true
		this.StopValue := true
		this.RetireValue := true
		this.CancelConstruction := false
		this.Mismatch := false
		this.TerminalOnStop := false
		this.TerminalOnStart := false
		this.Now := 1010
		this.ExpireOnRead := false
		this.Target := Map("managed_root", "C:\managed", "version_path", "C:\managed\versions\captured",
			"executable", "C:\managed\versions\captured\ollama.exe", "models_dir", "C:\managed\models",
			"root_identity", "12345678:1234567890123456", "version_identity", "23456789:2345678901234567",
			"ticket", "11111111111111111111111111111111", "runtime_ticket", "22222222222222222222222222222222",
			"manifest_sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"origin", "http://127.0.0.1:23456", "port", 23456, "started_tick", 1000, "deadline_ms", 9000)
		this.Authority := Map("authorize", ObjBindMethod(this, "Authorize"), "is_current", ObjBindMethod(this, "Current"))
		this.Owner := OllamaRuntimeOwner(Map("launcher", "C:\bundled\runtime.ps1", "helper", "C:\bundled\files.ps1",
			"helper_sha256", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			"spawn", ObjBindMethod(this, "Spawn"), "read_ready", ObjBindMethod(this, "Read"),
			"clock", ObjBindMethod(this, "Clock"),
			"on_retired", ObjBindMethod(this, "Retire"), "on_error", ObjBindMethod(this, "Error")))
		this.Receipt := Map("launcher_pid", 5001, "child_pid", 5002, "leases_held", 1,
			"ready_file_identity", "34567890:3456789012345678")
		for Name in ["runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256", "origin"]
			this.Receipt[Name] := this.Target[Name]
	}
	Run() {
		return this.Owner.Start(this.Target, this.Authority, ObjBindMethod(this, "Ready"), ObjBindMethod(this, "Exit"))
	}
	Authorize(Target) {
		AssertEqual(Target["manifest_sha256"], this.Target["manifest_sha256"], "The actual captured manifest reaches admission.")
		return true
	}
	Current(*) {
		Assert(!this.Owner.Record["target"].Has("ready_file_identity"), "Observed retirement metadata cannot mutate the captured source target.")
		return this.CurrentValue
	}
	Spawn(Executable, Arguments, Done, Adopt) {
		this.Done := Done
		this.Arguments := Arguments.Clone()
		this.Task := this.NewTask()
		if this.CancelConstruction
			Assert(!this.Owner.Stop(), "Interrupted construction retains its owner.")
		Adopt.Call(this.Task)
		return this.Mismatch ? this.NewTask() : this.Task
	}
	NewTask() {
		Task := {}
		Task.start := ObjBindMethod(this, "Start")
		Task.requestTerminate := ObjBindMethod(this, "Stop")
		Task.processId := (*) => 5001
		return Task
	}
	Factory(Exe, Args, Done, Chunk?, NativeAdopt?, MaxBytes := 0, Capture := true, Private := false) {
		Assert(!IsSet(Chunk) && !IsSet(NativeAdopt), "Production never substitutes a native adoption fault seam.")
		Assert(MaxBytes == 0 && !Capture && Private, "Serve has no unbounded capture and uses private diagnostics.")
		AssertEqual(this.Starts, 0, "Canonical factory construction is lazy.")
		this.Arguments := Args.Clone()
		this.Done := Done
		this.Task := this.NewTask()
		return this.Task
	}
	Start(*) {
		Assert(this.Owner.Record["task"] == this.Task, "The task is adopted before native start.")
		this.Starts += 1
		if this.TerminalOnStart
			this.Done.Call(78, "", "not started")
		return this.StartValue
	}
	Stop(*) {
		Assert(!A_IsCritical, "Tree retirement runs outside Critical.")
		this.Stops += 1
		if this.TerminalOnStop
			this.Done.Call(78, "", "refusal")
		return this.StopValue
	}
	Read(*) {
		if this.ExpireOnRead
			this.Now := 10000
		return Map("receipt", this.Receipt.Clone(), "image_sha256", "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
	}
	Clock() {
		return this.Now
	}
	Ready(Target, Receipt) {
		AssertEqual(Target["origin"], Receipt["origin"], "Only this managed endpoint is published.")
		this.ReadyCalls += 1
	}
	Exit(Code, Target) {
		this.ExitCalls += 1
	}
	Retire(*) {
		Assert(!A_IsCritical, "File retirement runs outside Critical.")
		this.RetireCalls += 1
		return this.RetireValue
	}
	Error(Kind, Err) {
		this.Errors.Push(Kind)
	}
}

_ORT_Adoption() {
	F := _ORT_Fixture()
	Assert(F.Run(), "Actual start is admitted.")
	AssertEqual(F.Starts, 1, "Only one exact task starts.")
	Assert(InStr(_ORT_Args(F.Arguments), "-ManifestSha256"), "The source manifest is passed to the actual launcher.")
	Assert(F.Owner.Stop(), "Strict physical ACK releases owner.")
}

_ORT_FailedStart() {
	F := _ORT_Fixture()
	F.StartValue := false
	Assert(!F.Run(), "False start cannot be accepted.")
	AssertEqual(F.Stops, 1, "Failed start requests exact retained task retirement.")
	Assert(!F.Owner.HasOwner(), "True physical ACK requires no fabricated callback.")
	AssertEqual(F.ExitCalls, 0, "Unobserved exit is not operation success.")
}

_ORT_FalseAck() {
	F := _ORT_Fixture()
	F.StartValue := false
	F.StopValue := "1"
	Assert(!F.Run() && F.Owner.HasOwner(), "Truthy text is not the canonical native ACK.")
	AssertEqual(F.RetireCalls, 0, "Leases remain retained before physical ACK.")
	F.StopValue := true
	Assert(F.Owner.Stop(), "Later exact physical ACK releases debt.")
}

_ORT_RetirementDebt() {
	F := _ORT_Fixture()
	Assert(F.Run(), "Runtime admitted.")
	F.RetireValue := false
	Assert(!F.Owner.Stop(), "File retirement refusal remains visible.")
	Assert(F.Owner.HasOwner() && !F.Run(), "Debt cannot be overwritten by a successor.")
	F.RetireValue := true
	Assert(F.Owner.Stop(), "Exact retry finally acknowledges retirement.")
}

_ORT_ReadyOnce() {
	F := _ORT_Fixture()
	Assert(F.Run(), "Runtime admitted.")
	Assert(F.Owner.ObserveReady(), "Actual source/process receipt admitted.")
	Assert(!F.Owner.ObserveReady(), "Ready callback is one-shot.")
	AssertEqual(F.ReadyCalls, 1, "Exactly one ready publication.")
	Assert(F.Owner.Stop(), "Runtime retired.")
}

_ORT_ReadyForeign() {
	for Name in ["runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256", "origin", "launcher_pid", "child_pid", "leases_held", "ready_file_identity"] {
		F := _ORT_Fixture()
		Assert(F.Run(), "Runtime admitted before foreign receipt.")
		F.Receipt[Name] := Name == "child_pid" ? 5001 : Name == "leases_held" ? "1" : "foreign"
		Assert(!F.Owner.ObserveReady(), "Mismatched receipt must refuse: " . Name)
		AssertEqual(F.ReadyCalls, 0, "Foreign evidence cannot publish readiness.")
		Assert(F.Owner.Stop(), "Only owned runtime is retired.")
	}
	F := _ORT_Fixture()
	Assert(F.Run(), "Runtime admitted before invalid extra evidence.")
	F.Receipt["extra"] := "unexpected"
	Assert(!F.Owner.ObserveReady() && F.ReadyCalls == 0, "Unknown receipt fields cannot be forwarded as provenance.")
	Assert(F.Owner.Stop(), "Exact owned runtime still retires.")
}

_ORT_CancelReady() {
	F := _ORT_Fixture()
	Assert(F.Run(), "Runtime admitted.")
	F.StopValue := false
	Assert(!F.Owner.Stop(), "Native debt remains.")
	Assert(!F.Owner.ObserveReady() && F.ReadyCalls == 0, "Canceled owner cannot publish a leftover receipt.")
	F.StopValue := true
	Assert(F.Owner.Stop(), "Owned task ACK finally settles.")
}

_ORT_TerminalReentry() {
	F := _ORT_Fixture()
	Assert(F.Run(), "Runtime admitted.")
	F.TerminalOnStop := true
	Assert(F.Owner.Stop(), "Real callback can retire during requestTerminate.")
	AssertEqual(F.ExitCalls, 0, "Cancellation never publishes operation success.")
	AssertEqual(F.RetireCalls, 1, "Physical observer is not duplicated.")
}

_ORT_Models() {
	F := _ORT_Fixture()
	F.Target["models_dir"] := "C:\personal\models"
	try {
		F.Run()
		throw Error("Expected managed models refusal.")
	} catch TypeError {
		AssertEqual(F.Starts, 0, "No task runs against a personal models directory.")
	}
}

_ORT_ConstructCancel() {
	F := _ORT_Fixture()
	F.CancelConstruction := true
	Assert(!F.Run(), "Construction cancellation is sticky.")
	AssertEqual(F.Starts, 0, "Canceled construction cannot start.")
	AssertEqual(F.Stops, 1, "Returned old task is still retired.")
	Assert(!F.Owner.HasOwner(), "ACK closes the exact interrupted owner.")
}

_ORT_Mismatch() {
	F := _ORT_Fixture()
	F.Mismatch := true
	Assert(!F.Run(), "Different returned handle is refused.")
	AssertEqual(F.Starts, 0, "Mismatch cannot launch anything.")
	AssertEqual(F.Stops, 1, "Only actually adopted handle retires.")
}

_ORT_Args(Args) {
	Text := ""
	for Item in Args
		Text .= Item . "`n"
	return Text
}

_ORT_CanonicalSpawn() {
	F := _ORT_Fixture()
	F.Owner.Options.Delete("spawn")
	F.Owner.Options["factory"] := ObjBindMethod(F, "Factory")
	Assert(F.Run(), "Actual native wrapper is received with only its factory port inert.")
	Assert(F.Owner.Stop(), "The exact lazy task is retired.")
}

_ORT_Architecture() {
	AssertEqual(OllamaRuntime_HostArchitecture(_ORT_Machine.Bind(0x8664)), "x86_64", "AMD64 native host is admitted.")
	AssertEqual(OllamaRuntime_HostArchitecture(_ORT_Machine.Bind(0xaa64)), "arm64", "ARM64 host is independent of interpreter bitness.")
	for Machine in [0, 0x014c] {
		try {
			OllamaRuntime_HostArchitecture(_ORT_Machine.Bind(Machine))
			throw Error("Expected unsupported architecture refusal.")
		} catch ValueError as Err {
			Assert(InStr(Err.Message, "no admitted managed Ollama asset"), "Unsupported native machine is a real refusal.")
		}
	}
}

_ORT_Machine(Machine) {
	return Machine
}

_ORT_EarlyTerminal() {
	F := _ORT_Fixture()
	F.TerminalOnStart := true
	Assert(!F.Run(), "Terminal construction cannot become accepted.")
	AssertEqual(F.ExitCalls, 0, "No business exit callback publishes before start acceptance.")
	AssertEqual(F.ReadyCalls, 0, "No readiness callback publishes during construction.")
	Assert(!F.Owner.HasOwner(), "Actual quiescent callback permits exact file retirement.")
}

_ORT_Deadline() {
	for LateRead in [false, true] {
		F := _ORT_Fixture()
		Assert(F.Run(), "Runtime admitted before receipt budget test.")
		F.Now := LateRead ? 9999 : 10000
		F.ExpireOnRead := LateRead
		Assert(!F.Owner.ObserveReady(), "Equality at original deadline refuses both pre-read and post-read publication.")
		AssertEqual(F.ReadyCalls, 0, "Expired readiness never reaches the business callback.")
		Assert(F.Owner.Stop(), "Cleanup remains independent of the readiness budget.")
	}
}
