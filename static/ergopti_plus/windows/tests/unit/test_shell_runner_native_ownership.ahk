; tests/unit/test_shell_runner_native_ownership.ahk

; ==============================================================================
; MODULE: Legacy Native Capability Ownership Tests
; DESCRIPTION:
; AHK-908 requires retaining the process capability through every terminal claim.
; Owned event handles test close refusal and retry without launching or killing
; any process. Public process exit behavior has separate native child coverage.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRNO_Transfer(Route, RefuseTimer := false) {
	global _SR_TaskCounter
	EventHandle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
		"Int", true, "Ptr", 0, "Ptr")
	AssertTrue(EventHandle != 0, "the fixture must own a native event")
	Native := Map("ProcessHandle", EventHandle)
	State := _SR_LegacyNewState(++_SR_TaskCounter, "", 0)
	Claim := 0
	Calls := {Close: 0, Reentered: false, Arm: 0}
	Arm() {
		Calls.Arm += 1
		if RefuseTimer
			throw Error("Native release fixture refuses timer admission.")
		_SR_EnsurePoller()
	}
	Reject(Handle) {
		Calls.Close += 1
		AssertEqual(EventHandle, Handle, "close must target the exact owned capability")
		return false
	}
	Accept(Handle) {
		Calls.Close += 1
		Calls.Reentered := !_SR_LegacyReleaseProcess(Claim, Accept)
		return DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
	}
	PreviousCritical := Critical("On")
	try {
		_SR_LegacyBeginStart(State)
		State["Native"] := Native
		if Route = "private-failure" {
			Claim := _SR_LegacyFailStart(State, 424242)
		} else if Route = "launch-cancel" {
			_SR_LegacyClaimTerminate(State)
			Claim := _SR_LegacyPublishStart(State, 424242)["Claim"]
		} else {
			AssertTrue(_SR_LegacyPublishStart(State, 424242)["Published"])
			switch Route {
				case "completion":
					Claim := _SR_LegacyClaimCompletion(State["TaskId"], State)
				case "terminate":
					Claim := _SR_LegacyClaimTerminate(State)
				case "published-failure":
					Claim := _SR_LegacyFailStart(State, 424242)
				default:
					throw Error("Unknown native ownership fixture route.")
			}
		}
		AssertTrue(Claim is Map, "the terminal route must claim its exact state")
		AssertEqual(0, State["Native"], "the old owner must relinquish its native reference")
		AssertEqual(ObjPtr(Native), ObjPtr(Claim["Native"]), "transfer must preserve the capability object")
		AssertTrue(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)), "physical ownership must survive registry removal")
		AssertFalse(_SR_LegacyReleaseProcess(Claim, Reject, Arm), "a refused close is not a release receipt")
		AssertEqual(1, Calls.Arm, "close refusal must attempt to schedule its retained debt")
		if RefuseTimer
			AssertContains(Claim["ReleaseArmDiagnostic"], "fixture refuses timer admission",
				"timer refusal must be diagnosed without throwing past terminal notification")
		AssertEqual(EventHandle, Native["ProcessHandle"], "refusal must retain the exact handle")
		AssertTrue(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)), "refusal must retain a retry owner")
		AssertTrue(_SR_LegacyReleaseProcess(Claim, Accept), "retry must close the retained handle")
		AssertTrue(Calls.Reentered, "reentrant release must lose the close claim")
		AssertEqual(0, Native["ProcessHandle"], "zero the capability only after native close succeeds")
		AssertFalse(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)), "successful close must retire its retry owner")
		AssertTrue(_SR_LegacyReleaseProcess(Claim, Reject), "duplicate release must be idempotent")
		AssertEqual(2, Calls.Close, "neither reentry nor duplicate release may close a recycled handle")
	} finally {
		; Never invoke a process termination finalizer for this event-only fixture
		try {
			if !IsObject(Claim)
				Claim := _SR_LegacyFailStart(State, 424242)
			if IsObject(Claim)
				AssertTrue(_SR_LegacyReleaseProcess(Claim), "fixture cleanup must confirm native release")
			else if Native["ProcessHandle"] {
				if !DllCall("Kernel32\CloseHandle", "Ptr", Native["ProcessHandle"], "Int")
					throw Error("Native ownership fixture cleanup failed.")
				Native["ProcessHandle"] := 0
			}
		} finally {
			Critical(PreviousCritical)
		}
	}
}

for Route in ["completion", "terminate", "published-failure", "private-failure", "launch-cancel"]
	Test("shell runner: native claim and close retry " . Route . " (shell-native-ownership)",
		_SRNO_Transfer.Bind(Route))
Test("shell runner: retains close debt when timer admission also fails (shell-native-ownership)",
	_SRNO_Transfer.Bind("completion", true))

_SRNO_ObservationFailure() {
	global _SR_TaskCounter
	EventHandle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
		"Int", false, "Ptr", 0, "Ptr")
	AssertTrue(EventHandle != 0, "observation fixture must own a native event")
	State := _SR_LegacyNewState(++_SR_TaskCounter, "", 0)
	ObservedClaim := 0
	ReadCalls := {Count: 0}
	RejectQuery(Handle) {
		ReadCalls.Count += 1
		AssertEqual(EventHandle, Handle, "the status query must use the retained capability")
		throw Error("Injected native exit query refusal.")
	}
	PreviousCritical := Critical("On")
	try {
		_SR_LegacyBeginStart(State)
		State["Native"] := Map("ProcessHandle", EventHandle)
		AssertTrue(_SR_LegacyPublishStart(State, 424242)["Published"])
		AssertEqual(0, _SR_LegacyObserveCompletion(State["TaskId"], State, RejectQuery),
			"a non-signaled capability must remain pending without querying an exit code")
		AssertTrue(DllCall("Kernel32\SetEvent", "Ptr", EventHandle, "Int"))
		AssertEqual(0, _SR_LegacyObserveCompletion(State["TaskId"], State.Clone(), RejectQuery),
			"a copied identity must be rejected before querying its capability")
		AssertEqual(0, ReadCalls.Count, "pending and stale states must not reach the query operation")
		Diagnostic := ""
		try ObservedClaim := _SR_LegacyObserveCompletion(State["TaskId"], State, RejectQuery)
		catch as Err
			Diagnostic := Err.Message
		AssertEqual("Injected native exit query refusal.", Diagnostic,
			"a failed query must not become successful completion")
		AssertEqual(1, ReadCalls.Count, "the current signaled capability must reach the query exactly once")
		AssertEqual(SR_LEGACY_PHASE_RUNNING, State["Phase"], "query failure must not consume completion")
		AssertEqual(ObjPtr(State), ObjPtr(_SR_ActiveTasks[State["TaskId"]]),
			"query failure must retain the exact active owner")
		AssertEqual(EventHandle, State["Native"]["ProcessHandle"], "query failure must retain its capability")
	} finally {
		try {
			Claim := IsObject(ObservedClaim) ? ObservedClaim : _SR_LegacyFailStart(State, 424242)
			AssertTrue(Claim is Map, "fixture must retire its exact active state")
			AssertTrue(_SR_LegacyReleaseProcess(Claim), "fixture must release its native event")
		} finally {
			Critical(PreviousCritical)
		}
	}
}
Test("shell runner: query failure and stale identity preserve native ownership (shell-native-ownership)",
	_SRNO_ObservationFailure)
