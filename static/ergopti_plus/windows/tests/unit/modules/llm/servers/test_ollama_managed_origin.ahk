; tests/unit/modules/llm/servers/test_ollama_managed_origin.ahk

; ==============================================================================
; MODULE: Ollama Managed Origin and Native Dispatch
; DESCRIPTION:
; Strict tags, chat warmup and menu pulls keep the exact owned listener
; origin, a dead or stale listener is refused, absent callbacks are
; tolerated, native dispatch failures keep the bootstrap observer, and the
; managed origin survives foreign readers and replacements.
; ==============================================================================

#Requires AutoHotkey v2.0





_G4B_ProbeOrigin(State) {
	global _LLM_ManagedBootstrap
	Saved := _LLM_ManagedBootstrap
	F := _G4B_Fixture()
	try {
		F.Start()
		F.Flow.AuxPrefix := "ollama_managed_fixture_"
		F.Runtime.PublishReady()
		_LLM_ManagedBootstrap := F.Flow
		Owner := LLM_AuxBegin(F.Flow.AuxPrefix . "models", Map("endpoint", F.Flow.Target["origin"]))
		AssertEqual(_LLM_OllamaTagsOrigin(Owner, true), "http://127.0.0.1:23456", "Managed tags use the retained native IPv4 listener.")
		AssertTrue(LLM_ManagedBootstrapOriginIsCurrent(Owner, F.Flow.Target["origin"]))
		AssertFalse(LLM_ManagedBootstrapOriginIsCurrent(Owner, "http://127.0.0.1:23457"))
		Foreign := LLM_AuxBegin("unowned_tags", Map("endpoint", "http://127.0.0.1:23457"))
		AssertThrows(() => _LLM_OllamaTagsOrigin(Foreign, true), "Ordinary owners cannot grant a selected-origin override.")
		F.Runtime.Record["ready"] := false
		AssertFalse(LLM_ManagedBootstrapOriginIsCurrent(Owner, F.Flow.Target["origin"]))
		AssertThrows(() => _LLM_OllamaTagsOrigin(Owner, true), "A pending native runtime cannot grant ready origin authority.")
		LLM_AuxFinish(Owner)
		LLM_AuxFinish(Foreign)
	} finally {
		F.Close()
		_LLM_ManagedBootstrap := Saved
	}
}
_G4B_ProbeOriginCase() {
	_LEA_WithFixture(_G4B_ProbeOrigin)
}
Test("managed bootstrap: strict tags retain only exact owned listener origin (groups247-managed)", _G4B_ProbeOriginCase)

_G4B_RequestOrigin(State) {
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	Saved := _LLM_ManagedBootstrap
	F := _G4B_Fixture()
	try {
		F.Start()
		F.Runtime.PublishReady()
		_LLM_ManagedBootstrap := F.Flow
		AssertEqual(LLM_OllamaRequestOrigin(), "http://127.0.0.1:23456")
		AssertEqual(_LLM_Menu_EnableSnapshot()["origin"], "http://127.0.0.1:23456")
		Owner := _LLM_OllamaAuxOwner(0, "g4_managed_consumer")
		AssertEqual(Owner["endpoint"], "http://127.0.0.1:23456", "Post-enable auxiliary consumers capture the admitted listener.")
		Custody := LLM_OllamaCaptureOriginCustody()
		AssertTrue(_LLM_Ollama_PresenceStillCurrent(Map("origin_custody", Custody, "presence_admitted", true,
			"presence_generation", LLM_AuxGeneration(), "base_url", "http://127.0.0.1:23456")))
		AssertFalse(_LLM_Ollama_PresenceStillCurrent(Map("origin_custody", Custody, "presence_admitted", true,
			"presence_generation", LLM_AuxGeneration(), "base_url", LLM_OLLAMA_BASE_URL)))
		Handle := { Origin: "http://127.0.0.1:23456", OriginCustody: Custody, OriginGeneration: LLM_AuxGeneration(), OriginOwned: true }
		AssertTrue(_LLM_Ollama_StreamOriginCurrent(Handle), "Actual streaming dispatch retains its admitted listener.")
		F.CurrentValue := false
		AssertFalse(_LLM_Ollama_StreamOriginCurrent(Handle))
		AssertFalse(LLM_OllamaOriginMatches(Handle.Origin))
		AssertThrows(LLM_OllamaRequestOrigin, "A retained withdrawn runtime cannot fall back to a foreign localhost listener.")
		F.Flow._Tick()
		AssertEqual(LLM_OllamaRequestOrigin(), LLM_OLLAMA_BASE_URL, "Only settled managed ownership permits external selection again.")
		LLM_AuxFinish(Owner)
	} finally {
		F.Close()
		_LLM_ManagedBootstrap := Saved
	}
}
_G4B_RequestOriginCase() {
	_LEA_WithFixture(_G4B_RequestOrigin)
}
Test("managed bootstrap: chat warmup and post-enable owners share native origin (groups247-managed)", _G4B_RequestOriginCase)

_G4B_MenuPull() {
	global _LLM_ManagedBootstrap
	Saved := _LLM_ManagedBootstrap
	F := _G4B_Fixture()
	try {
		F.Start()
		F.Runtime.PublishReady()
		F.Model := "qwen2.5:3b"
		_LLM_ManagedBootstrap := F.Flow
		AssertTrue(_LLM_Menu_PullModel(F.Model, true, "", 0, (*) => true), "The actual managed menu routes to its retained native runtime.")
		AssertEqual(F.Pulls, 1)
		AssertEqual(F.Consents[F.Consents.Length], "model")
		AssertTrue(F.Flow.Ready)
		AssertEqual(F.Runtime.Stops, 0)
		F.Decline := "model"
		AssertFalse(F.Flow.PullModel(F.Model))
		AssertEqual(F.Pulls, 1, "Declined menu download cannot dispatch a second pull.")
	} finally {
		F.Close()
		_LLM_ManagedBootstrap := Saved
	}
}
Test("managed bootstrap: actual menu model pull uses native owner and separate consent (groups247-managed)", _G4B_MenuPull)

_G4B_RejectArrayTags() {
	F := _G4B_Fixture()
	try {
		F.Model := "qwen2.5:3b"
		F.Start()
		F.Flow._ModelsReceived(Map("ok", true, "names", [F.Model]))
		AssertEqual(F.FailedCalls, 1, "An invented array cannot stand in for the strict native parser's set receipt.")
		AssertEqual(F.ReadyCalls, 0)
	} finally F.Close()
}
Test("managed bootstrap: model receipt uses actual normalized-name set contract (groups247-managed)", _G4B_RejectArrayTags)

/** Cleanup ownership must not grant HTTP admission to a replaced listener. */
_G4B_DeadListenerRefuses() {
	global _LLM_ManagedBootstrap
	Saved := _LLM_ManagedBootstrap
	F := _G4B_Fixture()
	try {
		F.Start()
		F.Runtime.PublishReady()
		_LLM_ManagedBootstrap := F.Flow
		AssertEqual(LLM_OllamaRequestOrigin(), F.Flow.Target["origin"])
		F.Runtime.LiveIdentity := false
		AssertTrue(F.Runtime.HasOwner(), "Physical cleanup ownership remains retained.")
		AssertThrows(LLM_OllamaRequestOrigin, "A dead captured server cannot borrow a replacement listener.")
	} finally {
		F.Close()
		_LLM_ManagedBootstrap := Saved
	}
}
Test("managed bootstrap: retained READY refuses dead listener (groups247-live-identity)", _G4B_DeadListenerRefuses)

/** A superseded deferred retry must tolerate callbacks cleared by prior success. */
_G4B_OptionalRetryCallbacks() {
	global _LLM_Deps_Epoch
	AssertFalse(LLM_Deps_AsyncCheck("", , , false, _LLM_Deps_Epoch - 1))
}
Test("managed bootstrap: stale retry accepts absent callbacks (groups247-optional-callbacks)", _G4B_OptionalRetryCallbacks)

/** Failure publication remains usable after the one-shot callback was retired. */
_G4B_OptionalFailureCallback() {
	global _LLM_Deps_Epoch
	AssertFalse(LLM_Deps_Fail("Synthetic superseded failure", , _LLM_Deps_Epoch - 1))
}
Test("managed bootstrap: stale failure accepts absent callback (groups247-optional-callbacks)", _G4B_OptionalFailureCallback)

/** The real deferred callback must not read an unset retired observer. */
_G4B_OptionalDeferredRetry() {
	global _LLM_Deps_Epoch, _LLM_Deps_Checking, _LLM_Deps_State
	Saved := [_LLM_Deps_Epoch, _LLM_Deps_Checking, _LLM_Deps_State]
	Errors := []
	Handler := (Err, *) => Errors.Push(Err.Message)
	OnError(Handler)
	try {
		_LLM_Deps_Checking := false
		LLM_Deps_CheckAndInstall("", , , false)
		_LLM_Deps_Epoch += 1
		Sleep(150)
		AssertEqual(Errors.Length, 0, "A superseded callback must retire before any network dispatch.")
	} finally {
		OnError(Handler, 0)
		_LLM_Deps_Epoch := Saved[1]
		_LLM_Deps_Checking := Saved[2]
		_LLM_Deps_State := Saved[3]
	}
}
Test("managed bootstrap: deferred retry preserves absent callbacks (groups247-optional-callbacks)", _G4B_OptionalDeferredRetry)

/** Uses an actual owned Windows listener; this is not Ollama installation qualification. */
_G4B_NativeListenerIdentity() {
	Root := A_Temp . "\ergopti-native-listener-" . DllCall("GetCurrentProcessId", "UInt") . "-" . A_TickCount
	DirCreate(Root)
	Observed := Map("terminal", false, "exit", -1, "stderr", "")
	PowerShell := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
	Fixture := A_ScriptDir . "\fixtures\ollama_live_identity_listener.ps1"
	Task := ShellRunner_SpawnTreeOwned(PowerShell, ["-NoLogo", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-File", Fixture, "-Directory", Root],
		Observe, , , 4096, true, true)
	Observe(Code, Out, Err) {
		Observed["exit"] := Code
		Observed["stderr"] := Err
		Observed["terminal"] := true
	}
	try {
		AssertTrue(Task.start(), "The owned native listener must launch.")
		Deadline := A_TickCount + 5000
		while !FileExist(Root . "\ready.json") && A_TickCount < Deadline && !Observed["terminal"]
			Sleep(10)
		AssertTrue(FileExist(Root . "\ready.json"), "The real process must publish its listener identity.")
		Native := JsonParse(FileRead(Root . "\ready.json", "UTF-8"))
		Receipt := Map("child_pid", Native["pid"], "child_created_filetime", Native["created_filetime"])
		Target := Map("port", Native["port"], "origin", "http://127.0.0.1:" . Native["port"], "executable", PowerShell)
		AssertTrue(OllamaNativeIdentityReady(Receipt, Target), "PID, birth time, executable and actual listener must agree.")
		Stale := Receipt.Clone()
		Stale["child_created_filetime"] += 1
		AssertFalse(OllamaNativeIdentityReady(Stale, Target), "A live PID cannot substitute for its captured birth identity.")
		ForeignImage := Target.Clone()
		ForeignImage["executable"] := A_AhkPath
		AssertFalse(OllamaNativeIdentityReady(Receipt, ForeignImage), "The listener PID alone cannot admit another executable.")
		ForeignOrigin := Target.Clone()
		ForeignOrigin["origin"] .= "/api"
		AssertFalse(OllamaNativeIdentityReady(Receipt, ForeignOrigin), "Configured origin must be the exact captured authority.")
		FileAppend("stop`n", Root . "\stop", "UTF-8-RAW")
		Deadline := A_TickCount + 5000
		while !Observed["terminal"] && A_TickCount < Deadline
			Sleep(10)
		AssertTrue(Observed["terminal"], "Natural tree retirement must be acknowledged.")
		AssertEqual(0, Observed["exit"], "The actual helper must exit successfully after releasing its listener.")
		AssertEqual("", Observed["stderr"], "Native listener errors cannot become a successful retirement receipt.")
		AssertFalse(OllamaNativeIdentityReady(Receipt, Target), "Retained READY cannot admit a terminated listener.")
	} finally {
		if !Observed["terminal"] {
			FileAppend("stop`n", Root . "\stop", "UTF-8-RAW")
			if !Task.requestTerminate()
				throw Error("Owned native listener cleanup remains pending.")
		}
		DirDelete(Root, true)
	}
}
Test("managed bootstrap: exact native listener identity rejects stale authority (groups247-native-identity)", _G4B_NativeListenerIdentity)

/** The exact native dispatch path remains injected, never a Linux native claim. */
class _G4B_NativeDispatchTask {
	__New(Mode, Retirement) {
		this.Mode := Mode
		this.Retirement := Retirement
		this.Starts := 0
		this.Stops := 0
		this.Done := 0
		this.Withdraw := 0
	}
	start() {
		this.Starts += 1
		if HasMethod(this.Withdraw, "Call")
			this.Withdraw.Call()
		if this.Mode == "start_throw" || this.Mode == "start_withdraw"
			throw Error("Synthetic native start refusal")
		return false
	}
	requestTerminate() {
		this.Stops += 1
		return this.Retirement
	}
	Complete() {
		this.Done.Call(0, "", "")
	}
}

/** Exercises the real menu -> native dispatch -> cancellation -> observer path. */
_G4B_NativeDispatchFailure(Mode, Retirement := true, Bootstrap := false) {
	F := _G4B_Fixture()
	Task := _G4B_NativeDispatchTask(Mode, Retirement)
	Spawns := 0, Published := 0
	Spawn(Executable, Arguments, Done, *) {
		Spawns += 1
		AssertEqual(Executable, A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe")
		AssertEqual(Arguments[Arguments.Length], "qwen3:0.6b", "The native worker receives the exact consented tag.")
		AssertTrue(InStr(Arguments[7], "ollama-model-pull.ps1"), "The managed worker remains the production entry point.")
		if Mode == "factory_throw"
			throw Error("Synthetic lazy native task construction refusal")
		Task.Done := Done
		return Task
	}
	try {
		if Bootstrap
			F.Model := "qwen3:0.6b"
		F.Start()
		F.Flow.Plan["directory"] := "C:\managed-workers"
		F.Flow.Plan["helper"] := "C:\managed-workers\ollama_managed_files.ps1"
		F.Flow.Plan["helper_sha256"] := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		F.Flow.Sources["C:\managed-workers\ollama-runtime-launch.ps1"] := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		F.Flow.Target["ready_file_identity"] := "34567890:3456789012345678"
		F.Flow.Target["ready_image_sha256"] := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		OriginalFailed := F.Flow.OnFailed
		if Mode == "start_withdraw"
			Task.Withdraw := (*) => F.Flow.Cancel()
		F.Flow.Port["pull"] := (Target, Model, Done) => F.Flow._NativePull(Model, Done, Spawn)
		if Bootstrap {
			F.Runtime.PublishReady()
			AssertEqual(0, F.ReadyCalls, "Initial acquisition has not completed its bootstrap.")
			AssertEqual(1, F.FailedCalls, "Initial native dispatch refusal still notifies its original failure observer.")
		} else {
			F.Runtime.PublishReady()
			AssertTrue(F.Flow.Ready)
			AssertFalse(F.Flow.PullModel("qwen3:0.6b", (*) => Published += 1))
			AssertEqual(1, F.ReadyCalls, "The original completed bootstrap remains one-shot.")
			AssertEqual(0, F.FailedCalls, "Later native construction/start failure belongs to its menu operation.")
		}
		AssertEqual(1, Spawns)
		AssertTrue(F.Flow.OnFailed == OriginalFailed, "Routing preserves the bootstrap observer instead of suppressing it globally.")
		AssertTrue(F.Flow.Cancelled)
		AssertFalse(F.Flow.Ready)
		AssertEqual(0, F.Flow.MenuPull)
		AssertEqual(0, Published)
		if Mode == "factory_throw" {
			AssertEqual(0, Task.Starts)
			AssertEqual(0, Task.Stops, "Lazy factory refusal returned no native task to terminate.")
			AssertEqual(0, F.Flow.PullTask)
			AssertTrue(F.Flow.CanReplace())
		} else {
			AssertEqual(1, Task.Starts)
			AssertTrue(Task.Stops >= 1, "Cancellation attempts retirement of the exact returned task.")
			if Retirement is Integer && Retirement == true {
				AssertEqual(0, F.Flow.PullTask)
				AssertTrue(F.Flow.CanReplace(), "Only canonical native closure acknowledges retirement.")
			} else {
				Owner := F.Flow.PullTask
				AssertTrue(Owner is Map && Owner["task"] == Task)
				AssertFalse(F.Flow.CanReplace(), "Refused or string retirement keeps exact native custody.")
				AssertFalse(F.Flow._Pulled(Map("task", Task), 0), "A forged completion cannot retire the captured task owner.")
				AssertTrue(F.Flow.PullTask == Owner)
			}
			Task.Complete()
			Task.Complete()
			AssertEqual(0, F.Flow.PullTask)
			AssertTrue(F.Flow.CanReplace(), "Exact canonical completion settles otherwise unknown physical custody.")
			AssertEqual(0, Published, "Late and duplicate completions cannot publish a cancelled request.")
		}
		AssertEqual(Bootstrap ? 1 : 0, F.FailedCalls)
	} finally F.Close()
}

Test("managed bootstrap: READY native factory throw preserves bootstrap observer (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("factory_throw"))
Test("managed bootstrap: READY native start false preserves bootstrap observer (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("start_false"))
Test("managed bootstrap: READY native start throw preserves bootstrap observer (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("start_throw"))
Test("managed bootstrap: READY native start false retains string retirement debt (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("start_false", "true"))
Test("managed bootstrap: READY native start throw retains refused retirement debt (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("start_throw", false))
Test("managed bootstrap: initial native factory throw still notifies failure (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("factory_throw", true, true))
Test("managed bootstrap: initial native start false still notifies failure (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("start_false", true, true))
Test("managed bootstrap: initial native start throw still notifies failure (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("start_throw", true, true))
Test("managed bootstrap: READY reentrant cancellation retains native failure custody (groups247-native-dispatch)", (*) => _G4B_NativeDispatchFailure("start_withdraw"))

/** Runs the real origin API over explicit managed runtime fixture capabilities. */
_G4O_WithManaged(Body) {
	_LEA_WithFixture(Run)
	Run(State) {
		global _LLM_ManagedBootstrap
		Saved := _LLM_ManagedBootstrap
		F := _G4B_Fixture()
		try {
			F.Start(), F.Runtime.PublishReady()
			_LLM_ManagedBootstrap := F.Flow
			Body.Call(F)
		} finally {
			F.Close()
			_LLM_ManagedBootstrap := Saved
		}
	}
}

_G4O_Replacement(Mode, F) {
	global _LLM_ManagedBootstrap, _LLM_AuxGeneration
	Other := _G4B_Fixture(), Generation := _LLM_AuxGeneration
	try {
		Custody := LLM_OllamaCaptureOriginCustody()
		Origin := Custody.Call("origin")
		AssertTrue(LLM_OllamaOriginCustodyCurrent(Custody, Origin))
		switch Mode {
			case "flow":
				AssertTrue(F.Flow.Cancel())
				Other.Start(), Other.Runtime.PublishReady()
				_LLM_ManagedBootstrap := Other.Flow
				AssertEqual(Origin, LLM_OllamaRequestOrigin(), "Replacement deliberately keeps the exact URL.")
			case "record": F.Runtime.Record := F.Runtime.Record.Clone()
			case "target": F.Flow.Target := F.Flow.Target.Clone()
			case "ticket": F.Flow.Target["runtime_ticket"] := "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
			case "generation": F.Runtime.Generation += 1
			case "task": F.Runtime.Record["task"] := {}
			case "retired": AssertTrue(F.Flow.Cancel())
			case "aux": _LLM_AuxGeneration += 1
		}
		AssertFalse(LLM_OllamaOriginCustodyCurrent(Custody, Origin), "Old currency never borrows a successor owner or tuple.")
	} finally {
		Other.Close()
		_LLM_AuxGeneration := Generation
	}
}
for _G4O_Mode in ["flow", "record", "target", "ticket", "generation", "task", "retired", "aux"]
	Test("Ollama managed origin: exact replacement " . _G4O_Mode . " (managed-origin-custody)",
		_G4O_WithManaged.Bind(_G4O_Replacement.Bind(_G4O_Mode)))

_G4O_BeforeReader(F) {
	global _LLM_ManagedBootstrap
	Other := _G4B_Fixture(), Origin := F.Flow.Target["origin"]
	try {
		AssertThrows(() => LLM_OllamaCaptureOriginCustody(Read), "Capture precedes a reentrant origin reader.")
	} finally Other.Close()
	Read() {
		AssertTrue(F.Flow.Cancel())
		Other.Start(), Other.Runtime.PublishReady()
		_LLM_ManagedBootstrap := Other.Flow
		return Origin
	}
}
Test("Ollama managed origin: captures before foreign origin reader (managed-origin-custody)",
	_G4O_WithManaged.Bind(_G4O_BeforeReader))

_G4O_UnrelatedInventory(F) {
	Custody := LLM_OllamaCaptureOriginCustody(), Origin := Custody.Call("origin")
	Other := LLM_AuxBegin("unrelated_inventory", Map("endpoint", Origin))
	Owner := _LLM_OllamaAuxOwner(0, "ordinary_tags")
	try {
		AssertTrue(LLM_OllamaOriginCustodyCurrent(Custody, Origin), "Inventory does not replace the managed daemon.")
		AssertTrue(Owner.Has("origin_custody"), "The auxiliary owner retains its admitted lexical capability.")
		AssertTrue(LLM_OllamaProbeOriginCurrent(Owner, Origin))
	} finally {
		LLM_AuxFinish(Owner)
		LLM_AuxFinish(Other)
	}
}
Test("Ollama managed origin: unrelated inventory keeps currency (managed-origin-custody)",
	_G4O_WithManaged.Bind(_G4O_UnrelatedInventory))

_G4O_Delivery(Kind, F) {
	global _LLM_ManagedBootstrap
	Other := _G4B_Fixture(), Calls := 0
	Custody := LLM_OllamaCaptureOriginCustody(), Origin := Custody.Call("origin")
	Delivery := LLM_OllamaInvokeOriginCurrent.Bind(Custody, Origin, Observe, Kind)
	try {
		Delivery.Call("original")
		AssertEqual(1, Calls)
		AssertTrue(F.Flow.Cancel())
		Other.Start(), Other.Runtime.PublishReady()
		_LLM_ManagedBootstrap := Other.Flow
		Delivery.Call("late")
		AssertEqual(1, Calls, "A held native delivery cannot cross a same-origin replacement.")
	} finally Other.Close()
	Observe(*) {
		Calls += 1
	}
}
for _G4O_Kind in ["on_result", "on_partial", "on_success", "on_fail"]
	Test("Ollama managed origin: retained " . _G4O_Kind . " delivery (managed-origin-custody)",
		_G4O_WithManaged.Bind(_G4O_Delivery.Bind(_G4O_Kind)))
