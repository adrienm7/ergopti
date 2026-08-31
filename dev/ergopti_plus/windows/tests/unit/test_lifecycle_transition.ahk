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
