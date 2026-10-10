; tests/unit/test_ollama_install_files_port.ahk

#Requires AutoHotkey v2.0

Test("Ollama file port: captured authorizer precedes construction and start", _OIFP_CapturedAuthority)
Test("Ollama file port: reentry cannot replace the retained claim", _OIFP_Reentry)
Test("Ollama file port: lazy bridge preserves canonical ShellRunner slots", _OIFP_Bridge)
Test("Ollama file port: false start retains terminal and file debt", _OIFP_FalseStart)
Test("Ollama file port: thrown start retains exact callback capability", _OIFP_ThrowStart)
Test("Ollama file port: cancellation ACK cannot publish revoked success", _OIFP_Cancel)
Test("Ollama file port: stale terminal cannot retire successor", _OIFP_Stale)
Test("Ollama file port: mismatched returned task retains adopted task", _OIFP_Mismatch)
Test("Ollama file port: logical result follows actual physical acknowledgement", _OIFP_Physical)

class _OIFP_Fixture {
	__New() {
		this.Events := []
		this.Errors := []
		this.Ack := true
		this.StartMode := "true"
		this.Results := 0
		this.Physical := 0
		this.Starts := 0
		this.Cancels := 0
		this.ConstructorCalls := 0
		this.ReplacementCalls := 0
		this.Reentry := false
		this.Mismatch := false
		this.Bridge := false
		this.Authority := Map("authorize", ObjBindMethod(this, "Authorize"),
			"is_current", ObjBindMethod(this, "Current"))
		this.Port := OllamaInstallFilesPort(Map("helper", "C:\owned\files.ps1",
			"powershell", "C:\owned\powershell.exe", "capture_bytes", 4096,
			"spawn", ObjBindMethod(this, "Spawn"), "on_physical", ObjBindMethod(this, "Observe"),
			"on_error", ObjBindMethod(this, "Error")))
	}
	Run() {
		return this.Port.Run("prepare", Map("TicketId", "captured"), this.Authority, ObjBindMethod(this, "Result"))
	}
	Current(*) {
		this.Authority["authorize"] := ObjBindMethod(this, "Replacement")
		if this.Reentry {
			this.Reentry := false
			Assert(!this.Run(), "Reentrant admission is refused.")
		}
		return true
	}
	Authorize(Action, Request) {
		this.Events.Push("authorize")
		AssertEqual(Request["TicketId"], "captured", "Captured request reaches its authorizer.")
		return true
	}
	Replacement(*) {
		this.ReplacementCalls += 1
		return false
	}
	Spawn(Exe, Args, Done, Adopt, Capture) {
		this.Done := Done
		if this.Bridge
			return OllamaInstallFiles_Spawn(Exe, Args, Done, Adopt, Capture, ObjBindMethod(this, "Factory"))
		Task := this.NewTask()
		this.Task := Task
		Adopt.Call(Task)
		this.Events.Push("adopt")
		return this.Mismatch ? this.NewTask() : Task
	}
	Factory(Exe, Args, Done, Chunk?, NativeAdopt?, Capture := 0, CaptureOutput := false, Private := false) {
		this.ConstructorCalls += 1
		AssertEqual(Exe, "C:\owned\powershell.exe", "Exact executable forwarded.")
		AssertEqual(Args[7], "C:\owned\files.ps1", "Exact helper argv forwarded.")
		Assert(!IsSet(Chunk) && !IsSet(NativeAdopt), "Native fault seam is not construction adoption.")
		AssertEqual(Capture, 4096, "Capture limit occupies the sixth slot.")
		Assert(CaptureOutput && Private, "Bounded capture and private diagnostics are requested.")
		AssertEqual(this.Starts, 0, "Lazy construction never starts native work.")
		this.Task := this.NewTask()
		return this.Task
	}
	NewTask() {
		Task := {}
		Task.start := ObjBindMethod(this, "Start")
		Task.requestTerminate := ObjBindMethod(this, "Terminate")
		return Task
	}
	Start(*) {
		Assert(this.Port.Record["task"] == this.Task, "Exact task is adopted before start.")
		this.Starts += 1
		this.Events.Push("start")
		if this.StartMode == "throw"
			throw Error("Injected start refusal.")
		return this.StartMode == "true"
	}
	Terminate(*) {
		this.Cancels += 1
		return false
	}
	Observe(Action, Request, Terminal) {
		this.Physical += 1
		this.LastTerminal := Terminal.Clone()
		return this.Ack
	}
	Error(Phase, Err) {
		this.Errors.Push(Phase)
	}
	Result(Terminal) {
		this.Results += 1
		Assert(Terminal["dispatched"], "Result follows dispatched terminal evidence.")
	}
}

_OIFP_CapturedAuthority() {
	F := _OIFP_Fixture()
	Assert(F.Run(), "Dispatch accepted.")
	AssertEqual(F.ReplacementCalls, 0, "Mutation of caller authority cannot replace captured authorizer.")
	AssertEqual(F.Events[1], "authorize", "Authorization is before construction.")
	AssertEqual(F.Events[2], "adopt", "Task is adopted before start.")
	AssertEqual(F.Events[3], "start", "Start follows exact task publication.")
	F.Done.Call(0, "", "")
	Assert(!F.Port.HasOwner(), "Acknowledged exact owner retires.")
}

_OIFP_Reentry() {
	F := _OIFP_Fixture()
	F.Reentry := true
	Assert(F.Run(), "Original dispatch accepted.")
	AssertEqual(F.Starts, 1, "Only original task starts.")
	F.Done.Call(0, "", "")
	AssertEqual(F.Results, 1, "Original owner publishes once.")
}

_OIFP_Bridge() {
	F := _OIFP_Fixture()
	F.Bridge := true
	Assert(F.Run(), "Canonical bridge dispatch accepted.")
	AssertEqual(F.ConstructorCalls, 1, "Constructor called exactly once.")
	F.Done.Call(0, "", "")
	AssertEqual(F.Results, 1, "Bridge retains exact physical callback.")
}

_OIFP_FalseStart() {
	F := _OIFP_Fixture()
	F.StartMode := "false"
	F.Ack := false
	Assert(!F.Run(), "False start is refused.")
	Assert(F.Port.HasOwner() && F.Port.Record["task"] == F.Task, "No terminal receipt means retained exact task.")
	AssertEqual(F.Physical, 0, "Cancellation request is not terminal ACK.")
	F.Done.Call(1, "", "")
	Assert(F.Port.HasOwner(), "Unacknowledged file debt remains after actual terminal.")
	F.Ack := true
	Assert(F.Port.Cancel(), "Retry acknowledges actual file debt.")
	AssertEqual(F.Results, 0, "Failed start never publishes logical success.")
}

_OIFP_ThrowStart() {
	F := _OIFP_Fixture()
	F.StartMode := "throw"
	Assert(!F.Run(), "Thrown start is refused.")
	AssertEqual(F.Errors[1], "dispatch", "Start failure is reported.")
	Assert(F.Port.HasOwner(), "Task stays retained until its terminal callback.")
	F.Done.Call(1, "", "")
	Assert(!F.Port.HasOwner() && F.Results == 0, "Terminal ACK retires without revoked publication.")
}

_OIFP_Cancel() {
	F := _OIFP_Fixture()
	Assert(F.Run(), "Dispatch accepted.")
	Assert(!F.Port.Cancel(), "Termination request is not physical ACK.")
	AssertEqual(F.Cancels, 1, "Exact retained cancellation reached once.")
	F.Done.Call(0, "", "")
	Assert(!F.Port.HasOwner() && F.Results == 0, "Late ACK cannot revive cancellation.")
}

_OIFP_Stale() {
	F := _OIFP_Fixture()
	Assert(F.Run(), "First dispatch accepted.")
	OldDone := F.Done
	OldDone.Call(0, "", "")
	F.Authority["authorize"] := ObjBindMethod(F, "Authorize")
	Assert(F.Run(), "Successor dispatch accepted after exact retirement.")
	Successor := F.Port.Record
	OldDone.Call(0, "", "")
	Assert(F.Port.Record == Successor, "Stale terminal cannot retire successor.")
	F.Done.Call(0, "", "")
	AssertEqual(F.Results, 2, "Each actual owner publishes once.")
}

_OIFP_Mismatch() {
	F := _OIFP_Fixture()
	F.Mismatch := true
	Assert(!F.Run(), "Foreign returned task is refused.")
	Assert(F.Port.HasOwner() && F.Port.Record["task"] == F.Task, "Previously adopted task remains exact debt.")
	AssertEqual(F.Starts, 0, "Mismatch refuses before start.")
	F.Done.Call(1, "", "")
	Assert(!F.Port.HasOwner() && F.Results == 0, "Physical ACK retires exact adopted task only.")
}

_OIFP_Physical() {
	F := _OIFP_Fixture()
	F.Ack := false
	Assert(F.Run(), "Dispatch accepted.")
	F.Done.Call(0, "", "")
	Assert(F.Port.HasOwner() && F.Results == 0, "Unacknowledged file evidence blocks publication.")
	F.Ack := true
	Assert(F.Port.Cancel(), "Exact physical retry acknowledged.")
	AssertEqual(F.Results, 0, "Cancellation during retry stays sticky.")
}

Test("Ollama file port: canonical failed-start quiescence preserves file debt without fake exit", _OIFP_QuiescedFailure)
Test("Ollama file port: canonical thrown-start quiescence retires without logical success", _OIFP_QuiescedThrow)
Test("Ollama file port: refused native quiescence retains the exact task until retry", _OIFP_QuiescenceRetry)
Test("Ollama file port: termination callback evidence wins over quiescence ACK", _OIFP_QuiescenceCallback)
Test("Ollama file port: thrown native termination preserves cancellation debt", _OIFP_QuiescenceThrow)

/** Models the public canonical tree state after a failed-start native boundary. */
class _OIFP_QuiescedFixture extends _OIFP_Fixture {
	__New() {
		super.__New()
		this.Quiesced := true
		this.ThrowTermination := false
		this.CallbackOnTermination := false
	}
	Observe(Action, Request, Terminal) {
		Assert(!A_IsCritical, "Independent file retirement must run outside Critical.")
		return super.Observe(Action, Request, Terminal)
	}
	Terminate(*) {
		Assert(!A_IsCritical, "Canonical native retirement must run outside Critical.")
		this.Cancels += 1
		if this.ThrowTermination
			throw Error("Injected native retirement refusal.")
		if this.CallbackOnTermination
			this.Done.Call(17, "captured native output", "captured native error")
		; These are the actual canonical owner's fields after terminal claiming;
		; no callback is available and no native tuple can be acquired here.
		State := Map("Starting", false, "TerminalClaimed", true,
			"TerminationRequested", true, "TreeQuiesced", this.Quiesced,
			"FinalizationPending", false)
		return _SR_TreeHandleTerminate(State, true)
	}
}

_OIFP_QuiescedFailure() {
	F := _OIFP_QuiescedFixture()
	F.StartMode := "false"
	F.Ack := false
	Assert(!F.Run(), "Failed dispatch remains refused.")
	Assert(F.Port.HasOwner(), "Native quiescence cannot acknowledge file debt.")
	AssertEqual(F.Port.Record["task"], 0, "Actual native ACK releases only the task.")
	AssertEqual(F.LastTerminal["kind"], "native_quiescence", "Receipt names its exact proof scope.")
	Assert(!F.LastTerminal["dispatched"] && !F.LastTerminal["exit_observed"]
		&& !F.LastTerminal["output_observed"], "No dispatched result or exit/output is inferred.")
	Assert(!F.LastTerminal.Has("exit") && !F.LastTerminal.Has("stdout")
		&& !F.LastTerminal.Has("stderr"), "No synthetic successful child evidence is created.")
	F.Ack := true
	Assert(F.Port.Cancel(), "Independent file retirement can acknowledge on retry.")
	Assert(!F.Port.HasOwner() && F.Results == 0, "Failed dispatch never publishes logical success.")
}

_OIFP_QuiescedThrow() {
	F := _OIFP_QuiescedFixture()
	F.StartMode := "throw"
	Assert(!F.Run(), "Thrown start remains refused.")
	AssertEqual(F.Errors[1], "dispatch", "Original error remains visible.")
	Assert(!F.Port.HasOwner() && F.Physical == 1 && F.Results == 0,
		"Native and file ACK retire the failed owner without any artificial Done callback.")
}

_OIFP_QuiescenceRetry() {
	F := _OIFP_QuiescedFixture()
	F.StartMode := "false"
	F.Quiesced := false
	Assert(!F.Run(), "Failed dispatch remains refused.")
	Assert(F.Port.HasOwner() && F.Port.Record["task"] == F.Task,
		"Refusal retains the exact task.")
	AssertEqual(F.Physical, 0, "Refused native retirement cannot publish file evidence.")
	F.Quiesced := true
	Assert(F.Port.Cancel(), "Later canonical ACK permits independent file settlement.")
	AssertEqual(F.Cancels, 2, "Only the same retained task is retried.")
	AssertEqual(F.Results, 0, "Cancellation remains sticky.")
}

_OIFP_QuiescenceCallback() {
	F := _OIFP_QuiescedFixture()
	F.StartMode := "false"
	F.CallbackOnTermination := true
	F.Ack := false
	Assert(!F.Run(), "Failed start remains refused.")
	AssertEqual(F.Physical, 2, "Unacknowledged file evidence remains available on both observations.")
	AssertEqual(F.LastTerminal["exit"], 17, "Actual callback exit wins.")
	AssertEqual(F.LastTerminal["stdout"], "captured native output", "Actual output is preserved.")
	AssertEqual(F.LastTerminal["stderr"], "captured native error", "Actual error is preserved.")
	Assert(F.LastTerminal["dispatched"] && !F.LastTerminal.Has("kind"),
		"Native quiescence never overwrites the already delivered terminal.")
	AssertEqual(F.Port.Record["terminal"]["exit"], 17, "Queued terminal remains exact while file debt is pending.")
	F.Ack := true
	Assert(F.Port.Cancel(), "File debt can acknowledge the original terminal.")
	Assert(!F.Port.HasOwner() && F.Results == 0, "Revoked request remains logically silent.")
}

_OIFP_QuiescenceThrow() {
	F := _OIFP_QuiescedFixture()
	F.StartMode := "false"
	F.ThrowTermination := true
	Assert(!F.Run(), "Failed dispatch remains refused.")
	AssertEqual(F.Errors[1], "termination", "Native refusal remains visible.")
	Assert(F.Port.HasOwner() && F.Port.Record["task"] == F.Task && F.Physical == 0,
		"Thrown retirement cannot fabricate a native or file ACK.")
	F.ThrowTermination := false
	Assert(F.Port.Cancel(), "Same task may settle after the refusal clears.")
	AssertEqual(F.Results, 0, "Failure never becomes installation success.")
}


Test("Ollama file port: download preserves captured original argv and owner", _OIFP_Download)
Test("Ollama file port: download rejects incomplete foreign and untyped requests before construction", _OIFP_DownloadRefusal)
Test("Ollama file port: old actions do not acquire a download prerequisite", _OIFP_OldArguments)

class _OIFP_DownloadFixture extends _OIFP_Fixture {
	__New() {
		super.__New()
		this.Port.Options["download_helper"] := "C:\owned\download.ps1"
	}
	Authorize(Action, Request) {
		this.Events.Push("authorize")
		AssertEqual(Action, "download", "Captured action reaches admission.")
		return true
	}
	Spawn(Exe, Args, Done, Adopt, Capture) {
		this.Arguments := Args.Clone()
		this.ConstructorCalls += 1
		return super.Spawn(Exe, Args, Done, Adopt, Capture)
	}
	Request() {
		return Map("ManagedRoot", "C:\owned\root", "CataloguePath", "C:\owned\release.json",
			"CatalogueSha256", StrReplace(Format("{:064}", 0), "0", "a"), "AssetId", "windows-amd64",
			"TicketId", StrReplace(Format("{:032}", 0), "0", "b"),
			"ManagedHelperPath", "C:\owned\files.ps1", "ManagedHelperSha256", StrReplace(Format("{:064}", 0), "0", "c"),
			"AcquisitionHelperPath", "C:\owned\acquire.ps1", "AcquisitionHelperSha256", StrReplace(Format("{:064}", 0), "0", "d"),
			"VendorDirectory", "C:\owned\vendor", "VendorSha256", StrReplace(Format("{:064}", 0), "0", "e"),
			"ProxyPolicyPath", "C:\owned\proxy.json", "ProxyPolicySha256", StrReplace(Format("{:064}", 0), "0", "f"),
			"UpdaterDefaultsPath", "C:\owned\defaults.json", "UpdaterDefaultsSha256", StrReplace(Format("{:064}", 0), "0", "1"),
			"ConnectTimeoutMs", 2000, "DeadlineMs", 30000, "StartedTick", 987654321)
	}
}

_OIFP_Download() {
	F := _OIFP_DownloadFixture()
	Request := F.Request()
	Assert(F.Port.Run("download", Request, F.Authority, ObjBindMethod(F, "Result")), "Captured download dispatch accepted.")
	AssertEqual(F.Arguments[7], "C:\owned\download.ps1", "Download selects only its captured helper.")
	AssertEqual(F.Arguments[9], "download", "Explicit action is retained.")
	AssertEqual(F.Arguments.Length, 9 + 2 * Request.Count, "All and only captured fields are forwarded.")
	Index := 10
	for Name, Value in Request {
		AssertEqual(F.Arguments[Index], "-" . Name, "Exact argument name retained.")
		AssertEqual(F.Arguments[Index + 1], String(Value), "Exact captured argument value retained.")
		Index += 2
	}
	Request["StartedTick"] := 1
	AssertEqual(F.Port.Record["request"]["StartedTick"], 987654321, "Caller mutation cannot renew or replace the original clock.")
	AssertEqual(F.Events[1], "authorize", "Authorization precedes download construction.")
	F.Done.Call(0, "", "")
	AssertEqual(F.Results, 1, "Result follows the same physical acknowledgement.")
	Assert(!F.Port.HasOwner(), "Exact settled download owner retires.")
}

_OIFP_DownloadRefusal() {
	Reference := _OIFP_DownloadFixture()
	for Name in Reference.Request() {
		F := _OIFP_DownloadFixture()
		Request := F.Request()
		Request.Delete(Name)
		Assert(!F.Port.Run("download", Request, F.Authority, ObjBindMethod(F, "Result")), "Every missing field is refused.")
		AssertEqual(F.ConstructorCalls, 0, "Incomplete request cannot construct a task.")
		Assert(!F.Port.HasOwner(), "Nonconstructed refusal settles without file debt.")
	}
	for Pair in [["Foreign", "C:\owned\unexpected"], ["StartedTick", 0], ["StartedTick", "987654321"],
		["DeadlineMs", -1], ["ConnectTimeoutMs", 2147483648], ["AssetId", "linux-amd64"],
		["TicketId", "b`n"], ["VendorSha256", "bad"], ["CataloguePath", "relative.json"]] {
		F := _OIFP_DownloadFixture()
		Request := F.Request()
		Request[Pair[1]] := Pair[2]
		Assert(!F.Port.Run("download", Request, F.Authority, ObjBindMethod(F, "Result")), "Foreign or untyped request refused.")
		AssertEqual(F.ConstructorCalls, 0, "Argument refusal precedes construction.")
	}
	F := _OIFP_DownloadFixture()
	F.Port.Options.Delete("download_helper")
	Assert(!F.Port.Run("download", F.Request(), F.Authority, ObjBindMethod(F, "Result")), "Missing helper is not silently substituted.")
	AssertEqual(F.ConstructorCalls, 0, "Missing helper cannot construct work.")
}

_OIFP_OldArguments() {
	F := _OIFP_Fixture()
	for Action in ["prepare", "publish", "cleanup", "cleanup_partial"] {
		Args := F.Port._Arguments(Action, Map("TicketId", "captured"))
		AssertEqual(Args.Length, 11, "Old argv inventory remains exact.")
		AssertEqual(Args[7], "C:\owned\files.ps1", "Old helper remains selected without download option.")
		AssertEqual(Args[9], Action, "Old action forwarded exactly.")
		AssertEqual(Args[10], "-TicketId", "Old parameter name unchanged.")
		AssertEqual(Args[11], "captured", "Old parameter value unchanged.")
	}
}
