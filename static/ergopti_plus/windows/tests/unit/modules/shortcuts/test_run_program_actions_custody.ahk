; tests/unit/modules/shortcuts/test_run_program_actions_custody.ahk

; ==============================================================================
; MODULE: User Program Poll and Constructor Custody
; DESCRIPTION:
; The native fixture owns an unset keyboard map, the one-shot poll keeps
; refused acquisition and callback debt, and constructor failures keep
; their exact debt with or without a root.
; ==============================================================================

#Requires AutoHotkey v2.0





_RPA_UnsetKeyboardBody(Context) {
	global KeyboardShortcutAssignments
	Assert(KeyboardShortcutAssignments is Map, "fixture initializes the actual keyboard assignment owner")
	AssertEqual("run_program", KeyboardShortcutAssignments.Get("ctrl_p", ""), "fixture initializes the keyboard binding")
	AssertEqual(Context["scalar"], GestureGetActionParameter("gesture__tap_3", "run_program"),
		"fixture uses the actual acknowledged action parameter owner")
}

_RPA_UnsetKeyboardRestored() {
	global KeyboardShortcutAssignments
	Saved := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	try {
		KeyboardShortcutAssignments := unset
		_RPA_WithFixture(_RPA_UnsetKeyboardBody)
		AssertFalse(IsSet(KeyboardShortcutAssignments), "fixture restores an originally unset owner")
	} finally KeyboardShortcutAssignments := IsSet(Saved) ? Saved : unset
}
Test("user program: native fixture owns and restores an unset keyboard map", _RPA_UnsetKeyboardRestored)

_RPA_PollPort(State, Callback, Period) {
	Assert(HasMethod(Callback, "Call"), "poll retains one callable native identity")
	State["calls"].Push(Map("callback", Callback, "period", Period))
	if Period == 0 {
		if State["cancel"] == "throw"
			throw Error("controlled poll cancellation refusal")
		return State["cancel"]
	}
	Assert(Period < 0, "poll schedules one-shot cleanup instead of a repeating typing-thread stall")
	if State["schedule"] == "throw"
		throw Error("controlled poll schedule refusal")
	if State["schedule"] == "early" {
		State["early_receipt"] := Callback.Call()
		return true
	}
	if State["schedule"] == "stop" {
		State["stop_receipt"] := ProgramActions_Stop(true)
		return true
	}
	return State["schedule"]
}

class _RPA_ControlledPollHandle {
	__New(State) {
		this.State := State
	}
	terminate() {
		this.State["terminations"] += 1
		return this.State["retire"]
	}
}

_RPA_PollCustody() {
	global _UserProgramPollOwner, _UserProgramEntries, _UserProgramPaused
	AssertEqual(0, _UserProgramEntries.Count, "controlled timer test borrows no native program")
	AssertFalse(IsObject(_UserProgramPollOwner), "controlled timer test borrows no timer")
	SavedPaused := _UserProgramPaused
	State := Map("calls", [], "schedule", true, "cancel", true, "retire", false, "terminations", 0)
	Port := _RPA_PollPort.Bind(State)
	try {
		AssertTrue(_ProgramActions_EnsurePoll(Port), "literal timer admission owns its bound callback")
		Owner := _UserProgramPollOwner
		Callback := Owner["callback"]
		for Refusal in [false, "", "throw"] {
			State["cancel"] := Refusal
			AssertFalse(_ProgramActions_StopPoll(), "false unknown and throwing cancellation retains debt")
			Assert(_UserProgramPollOwner == Owner, "exact refused timer capability remains retained")
			AssertFalse(ProgramActions_Run("gesture__tap_3"), "timer debt blocks successor acquisition")
		}
		State["cancel"] := true
		Owner["active"] := true
		AssertFalse(_ProgramActions_StopPoll(), "an active callback prevents terminal acknowledgement")
		Assert(_UserProgramPollOwner == Owner, "active native callback retains the same owner")
		Owner["active"] := false
		AssertTrue(_ProgramActions_StopPoll(), "fresh exact cancellation settles the inactive owner")
		AssertFalse(IsObject(_UserProgramPollOwner), "acknowledged timer capability retires")
		for Call in State["calls"]
			Assert(Call["callback"] == Callback, "every inverse uses the original exact native callback")
		for Refusal in [false, "", "throw"] {
			State["schedule"] := Refusal, State["cancel"] := false
			AssertFalse(_ProgramActions_EnsurePoll(Port), "refused timer acquisition cannot become success")
			Assert(IsObject(_UserProgramPollOwner), "ambiguous schedule retains its exact cancellation capability")
			State["cancel"] := true
			AssertTrue(_ProgramActions_StopPoll(), "strict compensation retires a refused schedule")
		}
		State["schedule"] := "early"
		AssertFalse(_ProgramActions_EnsurePoll(Port), "callback before same-call timer admission cannot become success")
		AssertEqual(false, State["early_receipt"], "early native callback cannot run cleanup before admission")
		AssertFalse(IsObject(_UserProgramPollOwner), "exact compensation retires an early consumed callback")
		State["schedule"] := "stop"
		AssertFalse(_ProgramActions_EnsurePoll(Port), "cancellation during timer acquisition refuses activation")
		AssertEqual(false, State["stop_receipt"], "acquiring timer cannot acknowledge early shutdown")
		AssertFalse(IsObject(_UserProgramPollOwner), "acquisition compensation retires the exact timer")
		State["schedule"] := true
		AssertTrue(_ProgramActions_EnsurePoll(Port), "a fresh timer can start after physical compensation")
		Current := _UserProgramPollOwner
		AssertFalse(Callback.Call(), "old retired callback cannot act on the new owner")
		Assert(_UserProgramPollOwner == Current, "old callback preserves the fresh exact owner")
		AssertTrue(_ProgramActions_StopPoll(), "the final owned timer retires")
		AssertTrue(_ProgramActions_EnsurePoll(Port), "physical retirement debt owns a cleanup callback")
		DebtOwner := _UserProgramPollOwner
		DebtCallback := DebtOwner["callback"]
		Entry := Map("binding", "gesture__controlled-poll", "cancelled", false,
			"handle", _RPA_ControlledPollHandle(State), "snapshot", 0, "started", A_TickCount)
		_UserProgramEntries[Entry["binding"]] := Entry
		AssertFalse(ProgramActions_Stop(true), "refused physical retirement cannot acknowledge stop")
		Assert(_UserProgramEntries.Get(Entry["binding"], 0) == Entry, "the exact refused handle remains owned")
		Assert(_UserProgramPollOwner == DebtOwner && DebtOwner["scheduled"],
			"refused physical retirement preserves an actually scheduled cleanup callback")
		AssertFalse(DebtOwner["cancelled"], "physical debt must not cancel its only retry callback")
		Assert(State["calls"][-1]["callback"] == DebtCallback && State["calls"][-1]["period"] < 0,
			"stop rearms the same exact one-shot callback while physical debt remains")
		State["retire"] := true
		AssertTrue(DebtCallback.Call(), "the retained exact callback retries physical retirement")
		AssertEqual(2, State["terminations"], "physical termination is retried after the refused attempt")
		AssertFalse(_UserProgramEntries.Has(Entry["binding"]), "strict physical receipt retires the exact entry")
		AssertFalse(IsObject(_UserProgramPollOwner), "physical retirement also settles its exact callback")
	} finally {
		State["cancel"] := true
		State["retire"] := true
		AssertTrue(ProgramActions_Stop(SavedPaused), "controlled program cleanup must actually acknowledge")
		AssertTrue(_ProgramActions_StopPoll(), "controlled timer cleanup must actually acknowledge")
		_UserProgramPaused := SavedPaused
	}
}
Test("user program: exact one-shot poll retains refused acquisition and callback debt", _RPA_PollCustody)

; Explicit surrounding State fixture; native operations are production functions.
_RPA_ConstructorFixtureState(Context) {
	global _SR_TaskCounter
	return Map("TaskId", ++_SR_TaskCounter, "Executable", A_AhkPath,
		"Command", _SR_BuildDirectCommandLine(A_AhkPath, [Context["script"], Context["output"], "must-not-run106"]),
		"TmpFile", "", "CaptureDir", "", "CaptureOutput", false,
		"PrivateDiagnostics", true, "MaxOutputBytes", 0, "BadArgIndex", 0,
		"ValidationError", "", "OnDone", 0, "BeforeNativeAdopt", 0,
		"Starting", false, "Started", false, "TerminationRequested", false,
		"PendingTerminationCallback", 0, "TerminalClaimed", false,
		"TerminalClaim", 0, "TreeQuiesced", false, "FinalizationPending", false,
		"AccountingDiagnosticLogged", false, "AccountingFailureCount", 0,
		"RootReaped", false, "ExitQueryDiagnostic", "", "ExitCode", 0,
		"Detached", false, "ProcessHandle", 0, "ThreadHandle", 0,
		"JobHandle", 0, "Pid", 0)
}

; Registered native constructor regressions; actual Windows execution is required.
; The surrounding State and handle are explicit fixtures; start/terminate,
; native creation, physical teardown, private logging and ProgramActions_Stop
; are the actual candidate production functions.

_RPA_ConstructorFailure(Mode, Context) {
	global _SR_TaskCounter, _SR_TreeNativeDebts, _SR_TreeOwnedTasks
	global _UserProgramEntries, _UserProgramAcquiring, _UserProgramPaused
	Context["preserve_directory"] := true
	RequestCallback := Mode == "request-before-bind"
	AssertEqual(0, _SR_TreeNativeDebts.Count, "fixture cannot borrow another native debt")
	AssertEqual(0, _SR_TreeOwnedTasks.Count, "fixture cannot borrow another active tree")
	State := _RPA_ConstructorFixtureState(Context)
	Scope := Map("protected", 0, "observer", 0, "job_observer", 0,
		"carrier", 0, "create_reentry", 0, "adopt_reentry", 0, "done", 0)
	ProtectFromClose := 0x0002
	Binding := "gesture__tap_3"
	Entry := Map("binding", Binding, "snapshot", _ProgramActions_Snapshot(Binding),
		"cancelled", false, "started", A_TickCount)
	Handle := {}
	Handle.terminate := (*) => _SR_TreeHandleTerminate(State, false)
	Handle.requestTerminate := (*) => _SR_TreeHandleTerminate(State, true)
	Entry["handle"] := Handle
	OnDone(ExitCode, Stdout, Stderr) {
		Scope["done"] += 1
		Scope["callback_root_signalled"] := _SRTOW_ExactProcessWait(Scope["observer"]) == SRTOW_WAIT_OBJECT_0
		Scope["callback_job_empty"] := _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]) == 0
		Scope["callback_claim_quiesced"] := Scope["carrier"]["Claim"]["TreeQuiesced"]
		Scope["callback_entry_current"] := _UserProgramEntries.Get(Binding, 0) == Entry
		Scope["callback_receipt"] := _ProgramActions_Done(Entry, ExitCode, Stdout, Stderr)
	}
	State["OnDone"] := OnDone
	_UserProgramEntries[Binding] := Entry
	Acquisition := Map("generation", Entry["snapshot"]["generation"])
	_UserProgramAcquiring := Acquisition
	Create(Application, Command, Flags, Startup, ProcessInfo) {
		PLC_CreateProcessWithInheritedHandles(Application, Command, Flags, Startup, ProcessInfo)
		Scope["protected"] := NumGet(ProcessInfo, 0, "Ptr")
		Pid := NumGet(ProcessInfo, 2 * A_PtrSize, "UInt")
		try {
			Scope["observer"] := _SRTOW_OpenExactProcess(Pid)
			if !DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
				"UInt", ProtectFromClose, "UInt", ProtectFromClose, "Int")
				throw OSError(A_LastError, "SetHandleInformation")
			Scope["protection_applied"] := true
			AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Scope["observer"]),
				"actual root remains suspended before construction rollback")
			AssertFalse(_SR_TreeHandleStart(State), "constructor reentry cannot create a second native owner")
			if !RequestCallback
				AssertFalse(ProgramActions_Stop(false), "held constructor cancellation cannot acknowledge unadopted native ownership")
			Assert(_UserProgramEntries.Get(Binding, 0) == Entry, "constructor cancellation retains its exact program entry")
			Scope["create_reentry"] += 1
		} catch Any as Err {
			; CreateFn has not returned PROCESS_INFORMATION to the producer yet.
			; Any failed fixture assertion therefore retains its exact own capsule.
			FaultClaim := Map("ProcessHandle", Scope["protected"],
				"ThreadHandle", NumGet(ProcessInfo, A_PtrSize, "Ptr"),
				"JobHandle", 0, "Assigned", false, "PrivateDiagnostics", true)
			Scope["fault_claim"] := FaultClaim
			if Scope.Get("protection_applied", false)
				DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
					"UInt", ProtectFromClose, "UInt", 0, "Int")
			_SR_TreeQuiesceNative(FaultClaim, true)
			if FaultClaim["ProcessHandle"] == 0
				Scope["protected"] := 0
			throw Err
		}
	}
	RejectStreamClose(*) {
		if Mode == "stream-string"
			throw "private-receipt106"
		return false
	}
	Adopt(Carrier) {
		Assert(Carrier["Published"], "physical tuple is published into its durable per-call capsule before the port")
		AssertEqual(Scope["protected"], Carrier["Claim"]["ProcessHandle"], "handoff retains the exact protected root HANDLE")
		AssertEqual(false, Carrier["Claim"]["Assigned"], "failed pre-assignment creation cannot substitute Job existence for assignment")
		Scope["job_observer"] := _SRTOW_DuplicateNativeHandle(Carrier["Claim"]["JobHandle"])
		Assert(Scope["job_observer"] != 0, "fixture retains the actual native Job independently")
		if InStr(Mode, "after", true)
			AssertTrue(_SR_TreeAttachCreationFailure(Carrier), "fault can occur after exact-State binding")
		if RequestCallback {
			AssertFalse(State["TerminalClaimed"], "independent request occurs before State binding")
			AssertFalse(Handle.requestTerminate(), "requestTerminate cannot acknowledge a still-unbound suspended capsule")
			AssertTrue(State["TerminationRequested"], "published STARTING request latches its cancellation")
			Assert(State["PendingTerminationCallback"] == OnDone, "request retains the actual callable completion owner")
			AssertEqual(0, Scope["done"], "request cannot invoke completion before physical native cleanup")
		} else
			AssertFalse(ProgramActions_Stop(false), "adopter reentry cannot acknowledge protected native debt")
		Assert(_UserProgramEntries.Get(Binding, 0) == Entry, "adopter reentry retains its exact program entry")
		Scope["adopt_reentry"] += 1
		if Mode == "before-string" || Mode == "after-string"
			throw "private-receipt106"
		if InStr(Mode, "throw", true)
			throw Error("private-receipt106")
		if Mode == "malformed"
			return "private-receipt106"
		if InStr(Mode, "refuse", true)
			return false
		return _SR_TreeAttachCreationFailure(Carrier)
	}
	CreateFault(Executable, CommandLine, CapturePath, Carrier) {
		Scope["carrier"] := Carrier
		Carrier["AdoptFn"] := Adopt
		return _SR_TreeCreateSuspended(Executable, CommandLine, CapturePath,
			true, Create, RejectStreamClose, Carrier)
	}
	CanRemove := false
	try {
		AssertFalse(_SR_TreeHandleStart(State, CreateFault), "real protected-HANDLE construction failure refuses start")
		AssertEqual(1, Scope["create_reentry"], "actual native constructor cancellation scenario executes once")
		AssertEqual(1, Scope["adopt_reentry"], "actual fault-adoption cancellation scenario executes once")
		Claim := Scope["carrier"]["Claim"]
		Assert(State["TerminalClaim"] == Claim, "start catches the actual capsule instead of claiming empty State")
		AdoptionFailed := InStr(Mode, "refuse", true) || InStr(Mode, "throw", true)
			|| Mode == "before-string" || Mode == "after-string" || Mode == "malformed"
		AssertEqual(!!AdoptionFailed, Scope["carrier"]["AdoptionFailed"], "refusal and thrown/malformed receipt remain explicit")
		Assert(Claim["OwnerState"] == State, "physical debt retains its exact logical owner")
		AssertTrue(Claim["PrivateDiagnostics"], "failure capsule preserves private diagnostics")
		AssertFalse(Claim["TreeQuiesced"], "signalled root alone cannot acknowledge refused native close")
		AssertTrue(_SR_TreeNativeDebts.Has(ObjPtr(Claim)), "exact protected claim remains registered for native retry")
		if RequestCallback
			AssertFalse(Handle.requestTerminate(), "repeated requests retain callback ownership through physical close refusal")
		else
			AssertFalse(_ProgramActions_Retire(Entry), "program retirement cannot delete an entry whose exact HANDLE still refuses close")
		Assert(_UserProgramEntries.Get(Binding, 0) == Entry, "retirement preserves debt rather than dropping its entry")
		_UserProgramAcquiring := 0
		AssertFalse(_UserProgramPaused, "replacement refusal is not caused by the pause gate")
		AssertFalse(ProgramActions_Run("keyboard__ctrl_p"), "clearing acquisition cannot admit replacement while the retained physical entry owes native cleanup")
		AssertFalse(FileExist(Context["output"]), "failed constructor never resumes payload script")
		Assert(_SRTOW_WaitForExactProcessExit(Scope["observer"]), "rollback stops the exact native root")
		AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]), "the exact pre-assignment Job is physically empty")
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
			"UInt", ProtectFromClose, "UInt", 0, "Int"), "unprotect only the exact retained root HANDLE")
		Scope["protected"] := 0
		_SR_TreePoll()
		AssertEqual(0, Claim["ProcessHandle"], "native polling closes the actual protected root after refusal ends")
		AssertEqual(0, Claim["ThreadHandle"], "native polling retires the constructor thread capability")
		AssertEqual(0, Claim["JobHandle"], "native polling retires the actual Job capability")
		AssertFalse(_SR_TreeNativeDebts.Has(ObjPtr(Claim)), "native debt ends only after exact physical cleanup")
		if RequestCallback {
			AssertEqual(1, Scope["done"], "pending request callback runs exactly once after physical native retirement")
			AssertTrue(Scope["callback_root_signalled"], "callback observes its exact native root signalled")
			AssertTrue(Scope["callback_job_empty"], "callback observes its exact native Job empty")
			AssertTrue(Scope["callback_claim_quiesced"], "callback receives only a genuinely retired native claim")
			AssertTrue(Scope["callback_entry_current"], "actual private completion owns the exact current program entry")
			AssertTrue(Scope["callback_receipt"], "actual ProgramActions completion accepts only the physical owner callback")
			_SR_TreePoll()
			AssertEqual(1, Scope["done"], "later native polling cannot duplicate the retained request callback")
		} else {
			AssertEqual(0, Scope["done"], "hard constructor cancellation suppresses the actual private completion callback")
			AssertTrue(_ProgramActions_Retire(Entry), "the same program entry can retire after actual native debt ends")
		}
		AssertEqual(0, _UserProgramEntries.Count, "proved native cleanup permits exact entry deletion")
		_RPA_ProgramDiagnostics(Context)
		for Line in Context["logs"]
			AssertFalse(InStr(Line, A_AhkPath, true), "constructor failure never reveals the executable path")
		CanRemove := true
	} finally {
		Context["preserve_directory"] := true
		NativeClean := false, ProcessClosed := false, JobClosed := false
		try {
			_UserProgramAcquiring := 0
			try {
				if Scope["protected"]
					AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Scope["protected"],
						"UInt", ProtectFromClose, "UInt", 0, "Int"), "failed assertion retains recovery of exact native close refusal")
			} finally {
				try {
					if Scope.Has("fault_claim")
						AssertTrue(_SR_TreeQuiesceNative(Scope["fault_claim"], true), "failed protection fixture retires its actual process capability")
				} finally {
					Receipt := ProgramActions_Stop(true)
					NativeClean := (Receipt is Integer) && Receipt == 1
						&& (!Scope["observer"] || _SRTOW_WaitForExactProcessExit(Scope["observer"]))
						&& (!Scope["job_observer"] || _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]) == 0)
						&& (!Scope.Has("fault_claim") || Scope["fault_claim"].Get("TreeQuiesced", false))
					AssertTrue(NativeClean, "fixture removal requires strict actual native capability cleanup")
				}
			}
		} finally {
			try {
				ProcessClosed := !Scope["observer"] || DllCall("Kernel32\CloseHandle", "Ptr", Scope["observer"], "Int")
				AssertTrue(ProcessClosed, "close independent exact root observer")
			} finally {
				try {
					JobClosed := !Scope["job_observer"] || DllCall("Kernel32\CloseHandle", "Ptr", Scope["job_observer"], "Int")
					AssertTrue(JobClosed, "close independent exact Job observer")
				} finally {
					if CanRemove && NativeClean && ProcessClosed && JobClosed
						Context["preserve_directory"] := false
				}
			}
		}
	}
}

for Mode in ["normal", "before-refuse", "before-throw", "after-refuse", "after-throw", "malformed",
		"before-string", "after-string", "stream-string", "request-before-bind"]
	Test("user program: exact constructor debt survives " . Mode,
		_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_ConstructorFailure.Bind(Mode))))

_RPA_ConstructorNoRootFailure(Port, Context) {
	global _UserProgramEntries, _SR_TreeNativeDebts, _SR_TreeOwnedTasks
	Context["preserve_directory"] := true
	State := _RPA_ConstructorFixtureState(Context)
	Scope := Map("calls", 0, "job_observer", 0)
	Entry := Map("binding", "gesture__tap_3", "snapshot", _ProgramActions_Snapshot("gesture__tap_3"),
		"cancelled", false, "started", A_TickCount)
	Entry["handle"] := {terminate: (*) => _SR_TreeHandleTerminate(State, false)}
	_UserProgramEntries[Entry["binding"]] := Entry
	ThrowBeforeCreate(*) {
		Scope["calls"] += 1
		throw "private-receipt106"
	}
	BindNoRoot(Carrier) {
		AssertEqual(0, Carrier["Claim"]["ProcessHandle"], "CreateFn throws before creating any payload process")
		Scope["job_observer"] := _SRTOW_DuplicateNativeHandle(Carrier["Claim"]["JobHandle"])
		Assert(Scope["job_observer"] != 0, "before-create String fault still retains the real allocated Job")
		return _SR_TreeAttachCreationFailure(Carrier)
	}
	CreateFault(Executable, CommandLine, CapturePath, Carrier) {
		Carrier["AdoptFn"] := BindNoRoot
		return _SR_TreeCreateSuspended(Executable, CommandLine, CapturePath,
			true, ThrowBeforeCreate, _SR_TreeCloseLaunchStream, Carrier)
	}
	CanRemove := false
	try {
		Fn := Port == "start" ? ThrowBeforeCreate : CreateFault
		AssertFalse(_SR_TreeHandleStart(State, Fn), "non-Error creator fault is contained into a closed failed start")
		AssertEqual(1, Scope["calls"], "selected non-Error native boundary actually executes")
		AssertFalse(State["Starting"], "non-Error creation refusal cannot leave Starting permanently latched")
		AssertTrue(State["TreeQuiesced"], "no-root creation fault settles only its actual empty/native Job capabilities")
		AssertEqual(0, State["TerminalClaim"]["ProcessHandle"], "no process capability is manufactured by exception handling")
		AssertEqual(0, State["TerminalClaim"]["ThreadHandle"], "no thread capability remains after no-root refusal")
		AssertEqual(0, State["TerminalClaim"]["JobHandle"], "real allocated Job is retired after before-CreateFn refusal")
		AssertEqual(0, _SR_TreeNativeDebts.Count, "no-root refusal leaves no unpublished native debt")
		AssertEqual(0, _SR_TreeOwnedTasks.Count, "no-root refusal never publishes an active task")
		AssertFalse(FileExist(Context["output"]), "non-Error constructor refusal never executes the payload script")
		if Scope["job_observer"]
			AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(Scope["job_observer"]), "independent actual Job observer proves zero native process count")
		AssertTrue(_ProgramActions_Retire(Entry), "truthfully empty construction permits exact caller retirement")
		_RPA_ProgramDiagnostics(Context)
		CanRemove := true
	} finally {
		try {
			Receipt := ProgramActions_Stop(true)
			Assert((Receipt is Integer) && Receipt == 1, "no-root fixture cleanup retains strict actual caller acknowledgement")
		} finally {
			Closed := !Scope["job_observer"] || DllCall("Kernel32\CloseHandle", "Ptr", Scope["job_observer"], "Int")
			AssertTrue(Closed, "close independently retained no-root Job capability")
			if CanRemove && Closed && (Receipt is Integer) && Receipt == 1
				Context["preserve_directory"] := false
		}
	}
}
for Port in ["start", "create"]
	Test("user program: non-Error " . Port . " refusal has a closed no-root receipt",
		_RPA_WithFixture.Bind(_RPA_WithCapturedProgramLogs.Bind(_RPA_ConstructorNoRootFailure.Bind(Port))))
