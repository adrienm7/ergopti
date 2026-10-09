; tests/unit/test_lifecycle_transition.ahk

#Requires AutoHotkey v2.0

_LT_Succeed(State, Owner) {
	State.calls.Push(Owner)
	return true
}

_LT_Throw(State, Owner) {
	State.calls.Push(Owner)
	throw Error("forced " . Owner . " failure")
}

_LT_ReturnFalse(State, Owner) {
	State.calls.Push(Owner)
	return false
}

_LT_EveryRequiredOwnerCreatesExactDebt() {
	for Phase, Owners in LIFECYCLE_REQUIRED_OWNERS {
		for FailedOwner in Owners {
			State := { calls: [] }
			Transaction := LifecycleTransitionBegin(Phase)
			if Phase == "suspend"
				LifecycleTransitionMarkStarted(Transaction)
			for Owner in Owners {
				Action := Owner == FailedOwner
					? _LT_Throw.Bind(State, Owner)
					: _LT_Succeed.Bind(State, Owner)
				_LifecycleRunRequiredStep(Transaction, Owner, Action)
			}
			AssertFalse(LifecycleTransitionFinish(Transaction),
				Phase . " must fail when required owner '" . FailedOwner . "' throws")
			Debt := LifecycleTransitionDebtSnapshot(Phase)
			AssertEqual(1, Debt.Length,
				Phase . " must expose exactly the failed owner")
			AssertEqual(FailedOwner, Debt[1].owner,
				Phase . " debt must retain the exact failed owner")
			Assert(InStr(Debt[1].message, "forced " . FailedOwner . " failure") > 0,
				Phase . " debt must retain the original failure message")
		}
	}
}

_LT_ExplicitFalseIsFailure() {
	State := { calls: [] }
	Transaction := LifecycleTransitionBegin("resume")
	Owner := LIFECYCLE_REQUIRED_OWNERS["resume"][1]
	AssertFalse(_LifecycleRunRequiredStep(Transaction, Owner,
		_LT_ReturnFalse.Bind(State, Owner), true),
		"an explicit false acknowledgement must be lifecycle debt")
	AssertFalse(LifecycleTransitionFinish(Transaction),
		"a false acknowledgement must prevent transition success")
	Debt := LifecycleTransitionDebtSnapshot("resume")
	AssertEqual(1, Debt.Length, "false acknowledgement must create one debt record")
	AssertEqual("returned false", Debt[1].message,
		"false acknowledgement must have a stable diagnostic")
}

_LT_SuspendDebtRequiresCompensationOnlyAfterTeardownStarts() {
	Owner := LIFECYCLE_REQUIRED_OWNERS["suspend"][1]
	State := { calls: [] }
	Preflight := LifecycleTransitionBegin("suspend")
	_LifecycleRunRequiredStep(Preflight, Owner, _LT_Throw.Bind(State, Owner))
	LifecycleTransitionFinish(Preflight)
	AssertFalse(LifecycleTransitionNeedsCompensation("suspend"),
		"a failed preflight must not invent a resume transition")

	Teardown := LifecycleTransitionBegin("suspend")
	LifecycleTransitionMarkStarted(Teardown)
	_LifecycleRunRequiredStep(Teardown, Owner, _LT_Throw.Bind(State, Owner))
	LifecycleTransitionFinish(Teardown)
	AssertTrue(LifecycleTransitionNeedsCompensation("suspend"),
		"a partial teardown must request compensation after native suspend is lifted")

	Resume := LifecycleTransitionBegin("resume")
	LifecycleTransitionMarkStarted(Resume)
	LifecycleTransitionFinish(Resume)
	SuspendDebt := LifecycleTransitionDebtSnapshot("suspend")
	AssertEqual(1, SuspendDebt.Length,
		"resume compensation must not erase the suspend debt it is repairing")
	AssertEqual(Owner, SuspendDebt[1].owner,
		"post-compensation diagnostics must retain the exact suspend owner")
}

_LT_LifecycleUsesEveryCataloguedOwnerAndGatesSuccess() {
	for Phase, FunctionName in Map(
		"suspend", "Ergopti_OnSuspendEnter",
		"resume", "Ergopti_OnSuspendResume") {
		Body := _DriverFuncBody(FunctionName)
		Assert(Body != "", FunctionName . " must exist")
		for Owner in LIFECYCLE_REQUIRED_OWNERS[Phase]
			Assert(InStr(Body, '"' . Owner . '"') > 0,
				FunctionName . " must register required owner '" . Owner . "'")
		FinishPos := InStr(Body, "LifecycleTransitionFinish(")
		SuccessPos := InStr(Body, "LoggerSuccess(")
		Assert(FinishPos > 0 and SuccessPos > FinishPos,
			FunctionName . " must prove zero lifecycle debt before logging success")
	}
}

Test("lifecycle transition: every required owner failure creates exact debt",
	_LT_EveryRequiredOwnerCreatesExactDebt)
Test("lifecycle transition: explicit false acknowledgement blocks success",
	_LT_ExplicitFalseIsFailure)
Test("lifecycle transition: only partial suspend teardown requires compensation",
	_LT_SuspendDebtRequiresCompensationOnlyAfterTeardownStarts)
Test("lifecycle transition: reactors cover the owner catalog and gate success",
	_LT_LifecycleUsesEveryCataloguedOwnerAndGatesSuccess)

_LT_SystemIntervalsOwnerIsAdmitted() {
	global _LifecycleLatestTransition, _LifecycleTransitionsByPhase
	SavedLatest := _LifecycleLatestTransition
	SavedPhases := _LifecycleTransitionsByPhase
	try {
		_LifecycleTransitionsByPhase := Map()
		State := { calls: [] }
		Transaction := LifecycleTransitionBegin("suspend")
		AssertTrue(_LifecycleRunRequiredStep(Transaction, "keylogger-system-intervals",
			_LT_Succeed.Bind(State, "keylogger-system-intervals")))
		AssertEqual(1, State.calls.Length, "the system interval suspension action must actually run")
		AssertTrue(LifecycleTransitionFinish(Transaction))
	} finally {
		_LifecycleLatestTransition := SavedLatest
		_LifecycleTransitionsByPhase := SavedPhases
	}
}
Test("lifecycle transition: system interval suspension is admitted (system-intervals-lifecycle)",
	_LT_SystemIntervalsOwnerIsAdmitted)

_LT_EveryCalledOwnerIsRegistered() {
	for Phase, Name in Map("suspend", "Ergopti_OnSuspendEnter", "resume", "Ergopti_OnSuspendResume") {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", "the lifecycle entry point must exist")
		Count := 0
		Position := 1
		while RegExMatch(Body, '_LifecycleRunRequiredStep\(\s*Transition\s*,\s*"([^"]+)"', &Match, Position) {
			Count += 1
			AssertTrue(_LifecycleOwnerIsRequired(Phase, Match[1]),
				Name . " calls an unregistered owner: " . Match[1])
			Position := Match.Pos + Match.Len
		}
		Assert(Count > 0, "the registration scan must inspect actual lifecycle calls")
	}
}
Test("lifecycle transition: every called owner is registered (system-intervals-lifecycle)",
	_LT_EveryCalledOwnerIsRegistered)

; Regression for resume-updater-nothing-pending (2026-10-01). The updater's
; resume answers false when it retained neither a manual terminal nor a menu
; rebuild, which is every ordinary resume. The reactor required true: each
; resume logged « resume transition owner 'updater' failed: returned false »,
; opened the error window and never reported the driver resumed. The test runs
; the updater's real answer through the reactor's own spelling of the step.
_LT_ResumeAcceptsAnUpdaterWithNothingRetained() {
	global _UpdaterPendingManualPauseNoticeCount, _UpdaterMenuRebuildPending
	global _LifecycleLatestTransition, _LifecycleTransitionsByPhase
	Body := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(Body != "", "Ergopti_OnSuspendResume must exist")
	Assert(RegExMatch(Body,
		'_LifecycleRunRequiredStep\(\s*Transition\s*,\s*"updater"\s*,\s*Updater_OnSuspendResume\s*(,\s*true\s*)?\)',
		&Step) > 0, "the resume reactor must run the updater owner")
	RequireTrue := Step[1] != ""
	SavedCount := _UpdaterPendingManualPauseNoticeCount
	SavedPending := _UpdaterMenuRebuildPending
	SavedLatest := _LifecycleLatestTransition
	SavedPhases := _LifecycleTransitionsByPhase
	try {
		_LifecycleTransitionsByPhase := Map()
		_UpdaterPendingManualPauseNoticeCount := 0
		_UpdaterMenuRebuildPending := false
		AssertEqual(false, Updater_OnSuspendResume(),
			"an updater that retained nothing answers false")
		Transition := LifecycleTransitionBegin("resume")
		_LifecycleRunRequiredStep(Transition, "updater", Updater_OnSuspendResume, RequireTrue)
		AssertEqual(0, Transition.debt.Length,
			"a resume with nothing retained by the updater must leave no debt (resume-updater-nothing-pending)")
		_LifecycleRunRequiredStep(Transition, "updater", () => _LT_ThrowUpdaterFailure(), RequireTrue)
		AssertEqual(1, Transition.debt.Length,
			"an updater resume that throws is still a debt")
	} finally {
		_UpdaterPendingManualPauseNoticeCount := SavedCount
		_UpdaterMenuRebuildPending := SavedPending
		_LifecycleLatestTransition := SavedLatest
		_LifecycleTransitionsByPhase := SavedPhases
	}
}

_LT_ThrowUpdaterFailure() {
	throw Error("simulated updater resume failure")
}
Test("lifecycle transition: a resume accepts an updater with nothing retained (resume-updater-nothing-pending)",
	_LT_ResumeAcceptsAnUpdaterWithNothingRetained)

_LT_BrightnessReturnsNoReceipt(State) {
	State.calls.Push("screen-brightness")
}

_LT_BrightnessAcknowledgesRetirement() {
	global _LifecycleLatestTransition, _LifecycleTransitionsByPhase
	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(RegExMatch(Body,
		'_LifecycleRunRequiredStep\(\s*Transition\s*,\s*"screen-brightness"\s*,\s*\(\) => ScreenBrightnessCancel\("suspended"\)\s*(,\s*true\s*)?\)',
		&Step) > 0, "the actual suspend entry must call the brightness native owner")
	RequireTrue := Step[1] != ""
	SavedLatest := _LifecycleLatestTransition
	SavedPhases := _LifecycleTransitionsByPhase
	try {
		for Mode in ["success", "false", "missing", "throw"] {
			_LifecycleTransitionsByPhase := Map()
			State := { calls: [] }
			Transaction := LifecycleTransitionBegin("suspend")
			LifecycleTransitionMarkStarted(Transaction)
			Action := Mode == "success" ? _LT_Succeed.Bind(State, "screen-brightness")
				: Mode == "false" ? _LT_ReturnFalse.Bind(State, "screen-brightness")
				: Mode == "missing" ? _LT_BrightnessReturnsNoReceipt.Bind(State)
				: _LT_Throw.Bind(State, "screen-brightness")
			Accepted := _LifecycleRunRequiredStep(Transaction, "screen-brightness", Action, RequireTrue)
			Finished := LifecycleTransitionFinish(Transaction)
			Debt := LifecycleTransitionDebtSnapshot("suspend")
			AssertEqual(1, State.calls.Length, Mode . ": the registered native owner must actually run")
			AssertEqual(Mode == "success", Accepted, Mode . ": only exact retirement acknowledgement succeeds")
			AssertEqual(Mode == "success", Finished, Mode . ": native cleanup debt blocks suspend success")
			AssertEqual(Mode != "success", LifecycleTransitionNeedsCompensation("suspend"),
				Mode . ": a started teardown retains the existing compensation requirement")
			AssertEqual(Mode == "success" ? 0 : 1, Debt.Length, Mode . ": exactly this owner records debt")
			if Debt.Length
				AssertEqual("screen-brightness", Debt[1].owner, Mode . ": debt retains exact owner identity")
		}
	} finally {
		_LifecycleLatestTransition := SavedLatest
		_LifecycleTransitionsByPhase := SavedPhases
	}
}
Test("lifecycle transition: brightness retirement acknowledgement and refusal gate suspend",
	_LT_BrightnessAcknowledgesRetirement)


_LT_UserHotstringsOwnerIsAdmitted() {
	global _LifecycleLatestTransition, _LifecycleTransitionsByPhase
	SavedLatest := _LifecycleLatestTransition
	SavedPhases := _LifecycleTransitionsByPhase
	try {
		_LifecycleTransitionsByPhase := Map()
		for Refuses in [false, true] {
			State := { calls: [] }
			Transaction := LifecycleTransitionBegin("suspend")
			Action := Refuses ? _LT_Throw.Bind(State, "user-hotstrings")
				: _LT_Succeed.Bind(State, "user-hotstrings")
			Accepted := _LifecycleRunRequiredStep(Transaction, "user-hotstrings", Action)
			AssertEqual(1, State.calls.Length, "the registered programmable owner must actually run")
			AssertEqual(!Refuses, Accepted, "only the successful owner acknowledges suspension")
			AssertEqual(!Refuses, LifecycleTransitionFinish(Transaction), "owner failure remains lifecycle debt")
			Debt := LifecycleTransitionDebtSnapshot("suspend")
			AssertEqual(Refuses ? 1 : 0, Debt.Length, "exactly the refusing owner creates debt")
			if Refuses {
				AssertEqual("user-hotstrings", Debt[1].owner, "the programmable owner identity must be retained")
				AssertEqual("forced user-hotstrings failure", Debt[1].message, "the original failure must remain visible")
			}
		}
	} finally {
		_LifecycleLatestTransition := SavedLatest
		_LifecycleTransitionsByPhase := SavedPhases
	}
}
Test("lifecycle transition: programmable owner admission retains exact failure debt (user-hotstrings-lifecycle)",
	_LT_UserHotstringsOwnerIsAdmitted)


_LT_UserHotstringsCancellationDebt() {
	global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsLoadEpoch
	global _HSE_TerminalOwner, _HSE_TerminalReplayPending
	global _LifecycleLatestTransition, _LifecycleTransitionsByPhase
	AssertEqual(0, _UserHotstringsJobs.Count, "the lifecycle fixture cannot replace live native jobs")
	AssertFalse(IsObject(_UserHotstringsLoader), "the lifecycle fixture cannot replace a live loader")
	AssertFalse(HSE_TerminalTransactionPending(), "the lifecycle fixture cannot replace pending output")
	Saved := { Owner: _UserHotstringsOwner, Loader: _UserHotstringsLoader,
		Jobs: _UserHotstringsJobs, Epoch: _UserHotstringsLoadEpoch,
		Terminal: _HSE_TerminalOwner, Replay: _HSE_TerminalReplayPending,
		Latest: _LifecycleLatestTransition, Phases: _LifecycleTransitionsByPhase }
	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Body != "", "the actual suspend owner must exist")
	Assert(RegExMatch(Body,
		'_LifecycleRunRequiredStep\(\s*Transition\s*,\s*"user-hotstrings"\s*,\s*UserHotstringsInvalidate\.Bind\("suspend"\)\s*(,\s*true\s*)?\)',
		&Step) > 0, "the actual suspend reactor must call the programmable invalidator")
	RequireTrue := Step[1] != ""
	try {
		_UserHotstringsLoader := 0
		_UserHotstringsJobs := Map()
		_HSE_TerminalOwner := 0
		_HSE_TerminalReplayPending := 0
		_LifecycleTransitionsByPhase := Map()
		for Refuses in [false, true] {
			Fixture := _UCHFixture()
			_UserHotstringsOwner := Fixture.owner
			Assert(Fixture.owner.Request("@clock"), "a genuine programmable task must be pending before suspend")
			AssertEqual(1, Fixture.tasks.Length, "the real owner must acquire its task")
			Fixture.cancelAck := !Refuses
			EpochBefore := _UserHotstringsLoadEpoch
			Transition := LifecycleTransitionBegin("suspend")
			LifecycleTransitionMarkStarted(Transition)
			Accepted := _LifecycleRunRequiredStep(Transition, "user-hotstrings",
				UserHotstringsInvalidate.Bind("suspend"), RequireTrue)
			AssertTrue(Fixture.tasks[1].cancelled, "the actual invalidator must cancel its pending task")
			AssertEqual(EpochBefore + 1, _UserHotstringsLoadEpoch, "the actual invalidator must revoke its load epoch")
			AssertEqual(!Refuses, Accepted, "retained programmable completion debt cannot acknowledge suspension")
			AssertEqual(!Refuses, LifecycleTransitionFinish(Transition), "retained completion debt must block lifecycle success")
			Debt := LifecycleTransitionDebtSnapshot("suspend")
			AssertEqual(Refuses ? 1 : 0, Debt.Length, "only actual cancellation refusal creates lifecycle debt")
			if Refuses {
				Assert(Fixture.owner.debt.Length > 0, "the genuine owner must retain unacknowledged task debt")
				AssertEqual("user-hotstrings", Debt[1].owner, "debt must retain the programmable owner identity")
				AssertEqual("returned false", Debt[1].message, "debt must retain the precise cancellation refusal")
			}
			Fixture.tasks[1].Run()
			AssertEqual(0, Fixture.calls, "cancelled task completion must not execute user code")
			AssertEqual(0, Fixture.output.Length, "cancelled task completion must not publish output")
			Fixture.cancelAck := true
			AssertTrue(UserHotstringsInvalidate("fixture-retry"), "an acknowledged retry must actually settle the retained owner")
			AssertEqual(0, Fixture.owner.debt.Length, "the acknowledged retry must remove genuine task debt")
		}
	} finally {
		try {
			if IsSet(Fixture) {
				Fixture.cancelAck := true
				UserHotstringsInvalidate("fixture-cleanup")
			}
		} finally {
			_UserHotstringsOwner := Saved.Owner
			_UserHotstringsLoader := Saved.Loader
			_UserHotstringsJobs := Saved.Jobs
			_UserHotstringsLoadEpoch := Saved.Epoch
			_HSE_TerminalOwner := Saved.Terminal
			_HSE_TerminalReplayPending := Saved.Replay
			_LifecycleLatestTransition := Saved.Latest
			_LifecycleTransitionsByPhase := Saved.Phases
		}
	}
}
Test("lifecycle transition: real programmable cancellation debt gates suspend acknowledgment (user-hotstrings-lifecycle)",
	_LT_UserHotstringsCancellationDebt)
