; tests/meta/test_deps_installer_pid_captured.ahk

; ==============================================================================
; MODULE: Ollama Installer Exact-Owner Regression
; DESCRIPTION:
; A numeric PID can be reused after winget exits while the daemon readiness poll
; remains active. Cancellation must therefore retain the exact ShellRunner task,
; not reopen a long-lived PID with taskkill. These tests cover both the source
; wiring and the ABA case where an old completion arrives after a replacement
; owner was published.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_DIPC_InstallerUsesExactTreeOwner() {
	RunBody := _DriverFuncBody("LLM_Deps_RunInstaller")
	CancelBody := _DriverFuncBody("LLM_Deps_Cancel")
	Assert(RunBody != "", "LLM_Deps_RunInstaller must remain reachable")
	Assert(CancelBody != "", "LLM_Deps_Cancel must remain reachable")
	AssertContains(RunBody, "ShellRunner_SpawnTreeOwned",
		"winget must launch inside an exact process-tree owner")
	AssertContains(RunBody, "_LLM_Deps_InstallerOwner",
		"the exact owner must be published before start")
	Assert(RegExMatch(RunBody,
		"s)SpawnFn\.Call\(.*?,\s*,\s*,\s*0,\s*false\s*\)") > 0,
		"the long-running installer must discard unused output instead of growing a staging file (AHK-086)")
	Assert(!InStr(RunBody . CancelBody, "_LLM_Deps_InstallerPid"),
		"no long-lived numeric PID owner may survive")
	Assert(!InStr(CancelBody, "taskkill") && !InStr(CancelBody, "ProcessClose("),
		"cancellation must never reopen a recyclable PID")
}

_DIPC_CancelRetainsFailedOwner() {
	Body := _DriverFuncBody("_LLM_Deps_CancelInstallerOwner")
	Assert(Body != "", "the exact installer cancellation helper must exist")
	TerminatePos := InStr(Body, '.terminate()')
	ExpectedPos := InStr(Body, "Owner != ExpectedOwner")
	ReceiptPos := InStr(Body, "if Terminated")
	ClearPos := InStr(Body, "_LLM_Deps_InstallerOwner := 0", true, ReceiptPos)
	RetainPos := InStr(Body, 'Owner["state"] := "running"', true, ReceiptPos)
	Assert(ExpectedPos > 0 && TerminatePos > ExpectedPos && ReceiptPos > TerminatePos,
		"a stale launch failure must not terminate a replacement owner")
	Assert(ReceiptPos > TerminatePos,
		"cancellation must consume the exact task's terminal receipt")
	Assert(ClearPos > ReceiptPos && RetainPos > ReceiptPos,
		"only a true receipt may clear ownership; failure must retain it")
}

_DIPC_StaleTerminalCannotRetireReplacement() {
	Body := _DriverFuncBody("_LLM_Deps_RetireInstallerOwner")
	Assert(Body != "", "the exact installer retirement helper must exist")
	IdentityPos := InStr(Body, "_LLM_Deps_InstallerOwner != ExpectedOwner")
	ClearPos := InStr(Body, "_LLM_Deps_InstallerOwner := 0")
	Assert(IdentityPos > 0 && ClearPos > IdentityPos,
		"an old completion must compare exact owner identity before clearing")
}

_DIPC_PublicCancelPreservesExactReceipt() {
	Body := _DriverFuncBody("LLM_Deps_Cancel")
	Assert(Body != "", "LLM_Deps_Cancel must remain source-visible")
	ReceiptPos := InStr(Body,
		"InstallerStopped := _LLM_Deps_CancelInstallerOwner()", true)
	ReturnPos := InStr(Body, "return InstallerStopped", true)
	Assert(ReceiptPos > 0 && ReturnPos > ReceiptPos,
		"the public cancellation boundary must return the exact tree receipt")
}

_DIPC_ShutdownRequiresExactInstallerQuiescence() {
	PrepareBody := _DriverFuncBody("LLM_Deps_PrepareShutdown")
	Assert(PrepareBody != "", "the installer shutdown preflight must exist")
	Assert(InStr(PrepareBody, "return _LLM_Deps_CancelInstallerOwner()", true) > 0,
		"shutdown must return the exact process-tree termination receipt")

	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ShutdownBody != "", "Ergopti_OnShutdown must remain source-visible")
	PreparePos := InStr(ShutdownBody, "LLM_Deps_PrepareShutdown()", true)
	TerminalPos := InStr(ShutdownBody, "ShutdownTerminal := true", true)
	FailurePos := InStr(ShutdownBody, "if !InstallerStopped", true, PreparePos)
	RefusalPos := InStr(ShutdownBody, _SHUTDOWN_REFUSAL_MARKER, true, FailurePos)
	Assert(PreparePos > 0 && FailurePos > PreparePos
		&& RefusalPos > FailurePos && TerminalPos > RefusalPos,
		"an unconfirmed installer tree must refuse exit before terminal teardown")
}


Test("Ollama deps: installer launch and cancellation retain an exact tree owner (AHK-082)",
	_DIPC_InstallerUsesExactTreeOwner)

Test("Ollama deps: failed exact termination retains its owner (AHK-082)",
	_DIPC_CancelRetainsFailedOwner)

Test("Ollama deps: stale terminal cannot retire a replacement owner (AHK-082)",
	_DIPC_StaleTerminalCannotRetireReplacement)

Test("Ollama deps: public cancel preserves the exact termination receipt (AHK-091)",
	_DIPC_PublicCancelPreservesExactReceipt)

Test("Ollama deps: shutdown joins the exact installer tree (AHK-092)",
	_DIPC_ShutdownRequiresExactInstallerQuiescence)


; =====================================================
; =====================================================
; ======= 2/ Retained Installer Debt ==================
; =====================================================
; =====================================================

class _DIPC_InertInstallerTask {
	__New(State) {
		this.State := State
	}
	start() {
		this.State["starts"] += 1
		if this.State["start"] == "throw"
			throw Error("inert installer start refused")
		return this.State["start"] == "ack"
	}
	terminate() {
		this.State["cancels"] += 1
		if this.State["cancel"] == "throw"
			throw Error("inert installer cancellation refused")
		return this.State["cancel"] == "ack"
	}
}

_DIPC_InstallerPortEvent(State, Name, *) {
	State[Name] += 1
	return true
}

_DIPC_InstallerPriority(State, Priority) {
	State["priority"] += 1
	State["priority_values"].Push(Priority)
	return true
}

_DIPC_InstallerPortSpawn(State, Executable, Args, OnDone, OnChunk?, Timeout?, Limit?, Capture?) {
	global _LLM_Deps_InstallerOwner
	State["constructors"] += 1
	AssertEqual(0, Limit, "installer keeps its original no-deadline task argument")
	AssertFalse(Capture, "installer must not capture unused child output")
	State["terminal"] := OnDone
	if State["reenter"]
		_LLM_Deps_InstallerOwner := State["foreign_owner"]
	return State["task"]
}

_DIPC_InstallerPortCall(State, Model, Epoch, OnReady?, OnFailed?) {
	return LLM_Deps_RunInstaller(Model, Epoch, OnReady?, OnFailed?, State["port"])
}

_DIPC_WithInertInstaller(Body) {
	global _LLM_Deps_InstallerOwner, _LLM_Deps_Checking, _LLM_Deps_State
	global _LLM_Deps_Epoch, _LLM_Deps_FailureMessage, _LLM_Deps_PollTimer, _LLM_Deps_PollStartTick
	global DRIVER_BASELINE_PRIORITY_CLASS
	Saved := Map()
	Saved["priority_set"] := IsSet(DRIVER_BASELINE_PRIORITY_CLASS)
	if Saved["priority_set"]
		Saved["priority"] := DRIVER_BASELINE_PRIORITY_CLASS
	Saved["owner_set"] := IsSet(_LLM_Deps_InstallerOwner)
	if Saved["owner_set"]
		Saved["owner"] := _LLM_Deps_InstallerOwner
	Saved["checking_set"] := IsSet(_LLM_Deps_Checking)
	if Saved["checking_set"]
		Saved["checking"] := _LLM_Deps_Checking
	Saved["state_set"] := IsSet(_LLM_Deps_State)
	if Saved["state_set"]
		Saved["state"] := _LLM_Deps_State
	Saved["epoch_set"] := IsSet(_LLM_Deps_Epoch)
	if Saved["epoch_set"]
		Saved["epoch"] := _LLM_Deps_Epoch
	Saved["failure_set"] := IsSet(_LLM_Deps_FailureMessage)
	if Saved["failure_set"]
		Saved["failure"] := _LLM_Deps_FailureMessage
	Saved["poll_start_set"] := IsSet(_LLM_Deps_PollStartTick)
	if Saved["poll_start_set"]
		Saved["poll_start"] := _LLM_Deps_PollStartTick
	Saved["poll_set"] := IsSet(_LLM_Deps_PollTimer)
	if Saved["poll_set"]
		Saved["poll"] := _LLM_Deps_PollTimer
	State := Map("constructors", 0, "starts", 0, "cancels", 0, "run", 0,
		"tip", 0, "timer", 0, "priority", 0, "ready", 0, "failed", 0,
		"start", "ack", "cancel", "ack", "reenter", false)
	State["priority_values"] := []
	State["task"] := _DIPC_InertInstallerTask(State)
	State["port"] := Map("priority", _DIPC_InstallerPriority.Bind(State),
		"available", (*) => true, "spawn", _DIPC_InstallerPortSpawn.Bind(State),
		"run", _DIPC_InstallerPortEvent.Bind(State, "run"),
		"tip", _DIPC_InstallerPortEvent.Bind(State, "tip"),
		"timer", _DIPC_InstallerPortEvent.Bind(State, "timer"))
	try {
		Driver := _DriverSourceConcat()
		ActiveDriver := _DriverMaskBlockComments(&Driver)
		Pattern := 'm)^global DRIVER_BASELINE_PRIORITY_CLASS := "([^"`r`n]+)"$'
		Assert(RegExMatch(ActiveDriver, Pattern, &Baseline) > 0,
			"The production baseline priority declaration must remain available.")
		Assert(!RegExMatch(ActiveDriver, Pattern, , Baseline.Pos + Baseline.Len),
			"Only one production baseline declaration may seed this fixture.")
		DRIVER_BASELINE_PRIORITY_CLASS := Baseline[1]
		_LLM_Deps_InstallerOwner := 0
		_LLM_Deps_Checking := true
		_LLM_Deps_State := "pending"
		_LLM_Deps_FailureMessage := ""
		_LLM_Deps_Epoch := 41
		_LLM_Deps_PollTimer := unset
		_LLM_Deps_PollStartTick := 0
		Body.Call(State)
	} finally {
		; Every actor/timer above is an inert retained object, never a native task.
		if Saved["priority_set"]
			DRIVER_BASELINE_PRIORITY_CLASS := Saved["priority"]
		else
			DRIVER_BASELINE_PRIORITY_CLASS := unset
		if Saved["owner_set"]
			_LLM_Deps_InstallerOwner := Saved["owner"]
		else
			_LLM_Deps_InstallerOwner := unset
		if Saved["checking_set"]
			_LLM_Deps_Checking := Saved["checking"]
		else
			_LLM_Deps_Checking := unset
		if Saved["state_set"]
			_LLM_Deps_State := Saved["state"]
		else
			_LLM_Deps_State := unset
		if Saved["epoch_set"]
			_LLM_Deps_Epoch := Saved["epoch"]
		else
			_LLM_Deps_Epoch := unset
		if Saved["failure_set"]
			_LLM_Deps_FailureMessage := Saved["failure"]
		else
			_LLM_Deps_FailureMessage := unset
		if Saved["poll_start_set"]
			_LLM_Deps_PollStartTick := Saved["poll_start"]
		else
			_LLM_Deps_PollStartTick := unset
		if Saved["poll_set"]
			_LLM_Deps_PollTimer := Saved["poll"]
		else
			_LLM_Deps_PollTimer := unset
	}
}

_DIPC_ReceiveInstallerFailure(State) {
	global _LLM_Deps_Epoch
	return _LLM_Deps_DoCheck_Result(false, A_TickCount, _LLM_Deps_Epoch, "model",
		_DIPC_InstallerPortEvent.Bind(State, "ready"),
		_DIPC_InstallerPortEvent.Bind(State, "failed"), true,
		_DIPC_InstallerPortCall.Bind(State))
}

_DIPC_AssertNoInstallerFallback(State, ExpectedOwner) {
	global _LLM_Deps_InstallerOwner, _LLM_Deps_Checking, _LLM_Deps_State, _LLM_Deps_FailureMessage
	global DRIVER_BASELINE_PRIORITY_CLASS
	Assert(_LLM_Deps_InstallerOwner == ExpectedOwner, "the exact unsettled installer stays retained")
	AssertEqual(0, State["run"], "cleanup debt must not open a browser fallback")
	AssertEqual(0, State["tip"], "cleanup debt must not advertise a replacement install")
	AssertEqual(0, State["timer"], "cleanup debt must not arm a readiness poll")
	AssertEqual(0, State["ready"], "cleanup debt cannot publish readiness")
	AssertEqual(1, State["failed"], "the actual callback must publish failure exactly once")
	AssertFalse(_LLM_Deps_Checking, "the real async caller must not leave checking stuck")
	AssertEqual("failed", _LLM_Deps_State, "the real callback must retain a failed business result")
	AssertEqual(t("ollama.deps_failed"), _LLM_Deps_FailureMessage, "failure uses the existing localized message")
	AssertEqual(DRIVER_BASELINE_PRIORITY_CLASS, State["priority_values"][-1], "failure restores the configured driver baseline")
}

_DIPC_PriorInstallerDebt(State) {
	global _LLM_Deps_InstallerOwner
	Owner := Map("task", State["task"], "state", "running")
	_LLM_Deps_InstallerOwner := Owner
	AssertFalse(_DIPC_ReceiveInstallerFailure(State))
	AssertEqual(0, State["constructors"], "retained predecessor must refuse before successor construction")
	AssertEqual(0, State["cancels"], "failure publication must not retry or clear the predecessor")
	_DIPC_AssertNoInstallerFallback(State, Owner)
}

_DIPC_StartCleanupDebt(StartMode, CancelMode, State) {
	global _LLM_Deps_InstallerOwner, _LLM_Deps_Checking, _LLM_Deps_State, _LLM_Deps_Epoch
	State["start"] := StartMode
	State["cancel"] := CancelMode
	AssertFalse(_DIPC_ReceiveInstallerFailure(State))
	Owner := _LLM_Deps_InstallerOwner
	Assert(Owner is Map && Owner["task"] == State["task"], "partial start must keep the original exact task")
	AssertEqual(1, State["constructors"])
	AssertEqual(1, State["starts"])
	AssertEqual(1, State["cancels"], "failure publication must not attempt cancellation twice")
	_DIPC_AssertNoInstallerFallback(State, Owner)
	State["cancel"] := "ack"
	AssertTrue(_LLM_Deps_CancelInstallerOwner(Owner), "only a real exact ACK permits retirement")
	AssertEqual(0, _LLM_Deps_InstallerOwner)
	State["start"] := "ack"
	_LLM_Deps_Checking := true
	_LLM_Deps_State := "pending"
	_LLM_Deps_Epoch += 1
	AssertTrue(_DIPC_ReceiveInstallerFailure(State), "a later explicit attempt may acquire after ACK")
	Replacement := _LLM_Deps_InstallerOwner
	Assert(Replacement is Map && Replacement != Owner)
	_LLM_Deps_OnInstallerTerminal(Owner, 0, "", "")
	Assert(_LLM_Deps_InstallerOwner == Replacement, "stale completion cannot retire the successor")
	AssertEqual(1, State["timer"], "only the post-ACK successor may arm the inert poll")
}

_DIPC_StartCleanupDebtCases() {
	for StartMode in ["refuse", "throw"] {
		for CancelMode in ["refuse", "throw"]
			_DIPC_WithInertInstaller(_DIPC_StartCleanupDebt.Bind(StartMode, CancelMode))
	}
}

_DIPC_StartCleanupAck(State) {
	global _LLM_Deps_InstallerOwner
	State["start"] := "refuse"
	AssertTrue(_DIPC_ReceiveInstallerFailure(State), "a closed failed launch retains the existing browser fallback")
	AssertEqual(1, State["cancels"], "false start must obtain cancellation ACK before retiring ownership")
	AssertEqual(0, _LLM_Deps_InstallerOwner)
	AssertEqual(1, State["run"])
	AssertEqual(1, State["tip"])
	AssertEqual(1, State["timer"])
	AssertEqual(0, State["failed"])
}

Test("Ollama deps: retained predecessor blocks construction and fails the actual callback (installer-debt-admission)",
	(*) => _DIPC_WithInertInstaller(_DIPC_PriorInstallerDebt))
Test("Ollama deps: false and throwing start retain cancellation debt without fallback (installer-debt-admission)",
	_DIPC_StartCleanupDebtCases)
Test("Ollama deps: false start needs exact cancellation ACK before browser fallback (installer-debt-admission)",
	(*) => _DIPC_WithInertInstaller(_DIPC_StartCleanupAck))

; Canonical enrollment is required by the real callback controls above.
_DIPC_CanonicalCheckerEnrollment() {
	global _LLM_Deps_State
	Runner := FileRead(A_ScriptDir . "\run_all.ahk", "UTF-8")
	ActiveRunner := _DriverMaskNonCode(&Runner)
	Assert(RegExMatch(ActiveRunner, "m)^#Include \.\./modules/llm/ollama_deps_checker\.ahk$") > 0,
		"The canonical runner must include the production dependency checker.")
	Stubs := FileRead(A_ScriptDir . "\test_stubs.ahk", "UTF-8")
	Assert(!_DriverFindFunctionDefinition(&Stubs, "LLM_Deps_IsReady"),
		"A permissive dependency readiness stub cannot replace the production subject.")
	Saved := _LLM_Deps_State
	try {
		_LLM_Deps_State := "ready"
		AssertTrue(LLM_Deps_IsReady(), "The real state getter accepts the ready state.")
		_LLM_Deps_State := "pending"
		AssertFalse(LLM_Deps_IsReady(), "The real state getter refuses a pending state.")
	} finally _LLM_Deps_State := Saved
}

Test("Ollama deps: canonical checker is enrolled without a permissive subject stub (installer-debt-enrollment)",
	_DIPC_CanonicalCheckerEnrollment)

_DIPC_BaselineFixtureRestoresExactState() {
	global DRIVER_BASELINE_PRIORITY_CLASS
	PriorSet := IsSet(DRIVER_BASELINE_PRIORITY_CLASS)
	if PriorSet
		Prior := DRIVER_BASELINE_PRIORITY_CLASS
	try {
		for Assigned in [false, true] {
			for ThrowBody in [false, true] {
				DRIVER_BASELINE_PRIORITY_CLASS := Assigned ? "saved-priority-sentinel" : unset
				try {
					_DIPC_WithInertInstaller(_DIPC_BaselineFixtureBody.Bind(ThrowBody))
					AssertFalse(ThrowBody, "A throwing fixture callback cannot be swallowed.")
				} catch Error as Err {
					Assert(ThrowBody && Err.Message == "inert baseline body refusal",
						"Only the exact deliberately injected body refusal is expected.")
				}
				Assert(IsSet(DRIVER_BASELINE_PRIORITY_CLASS) == Assigned,
					"The baseline fixture must preserve set/unset lifetime exactly.")
				if Assigned
					AssertEqual("saved-priority-sentinel", DRIVER_BASELINE_PRIORITY_CLASS,
						"A prior suite baseline must not be replaced by the fixture seed.")
			}
		}
	} finally {
		if PriorSet
			DRIVER_BASELINE_PRIORITY_CLASS := Prior
		else
			DRIVER_BASELINE_PRIORITY_CLASS := unset
	}
}

_DIPC_BaselineFixtureBody(ThrowBody, State) {
	global DRIVER_BASELINE_PRIORITY_CLASS
	Assert(IsSet(DRIVER_BASELINE_PRIORITY_CLASS), "The callback receives the actual production baseline seed.")
	AssertEqual(0, State["constructors"], "Baseline lifetime needs no installer or task acquisition.")
	if ThrowBody
		throw Error("inert baseline body refusal")
}

Test("Ollama deps: baseline fixture preserves assigned and unset state after success or refusal (installer-debt-baseline)",
	_DIPC_BaselineFixtureRestoresExactState)
