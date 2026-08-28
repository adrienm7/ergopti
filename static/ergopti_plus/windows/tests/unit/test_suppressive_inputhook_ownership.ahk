; tests/unit/test_suppressive_inputhook_ownership.ahk
#Requires AutoHotkey v2.0

class _SIHO_TestHook {
	__New(Name) {
		this.Name := Name
		this.StartCalls := 0
		this.StopCalls := 0
	}

	Start() {
		this.StartCalls += 1
	}

	Stop() {
		this.StopCalls += 1
	}
}

_SIHO_OverlappingOwnersStopAndUnregisterExactly() {
	Assert(IsSet(SIHO_StartOwned),
		"suppressive InputHooks need a shared owner registry")
	Assert(IsSet(SIHO_StopAll) and IsSet(SIHO_Unregister) and IsSet(SIHO_Count),
		"the owner registry must expose stop-all and exact unregister operations")

	First := _SIHO_TestHook("first")
	Second := _SIHO_TestHook("second")
	Successor := _SIHO_TestHook("successor")
	FirstToken := 0
	SecondToken := 0
	SuccessorToken := 0
	try {
		FirstToken := SIHO_StartOwned(First, "observer-a", false)
		SecondToken := SIHO_StartOwned(Second, "observer-b", false)
		Assert(FirstToken > 0 and SecondToken > FirstToken,
			"each overlapping hook must receive a distinct owner token")
		AssertEqual(1, First.StartCalls)
		AssertEqual(1, Second.StartCalls)
		Duplicate := _SIHO_TestHook("duplicate")
		AssertEqual(0, SIHO_StartOwned(Duplicate, "one-shot-shift", true),
			"an exclusive state machine must refuse every concurrent hook")
		AssertEqual(0, Duplicate.StartCalls,
			"a refused duplicate must never arm a hidden suppressive hook")
		AssertEqual(2, SIHO_Count(),
			"both suppressive hooks must remain lifecycle-visible")
		AssertFalse(SIHO_Unregister(FirstToken, Duplicate),
			"a token paired with the wrong hook object must not release ownership")
		AssertEqual(2, SIHO_Count(),
			"an ownership mismatch must retain every live hook")

		AssertEqual(2, SIHO_StopAll(),
			"suspend must stop every live suppressive hook")
		AssertEqual(1, First.StopCalls)
		AssertEqual(1, Second.StopCalls)

		AssertTrue(SIHO_Unregister(SecondToken, Second),
			"the second hook may complete before the first")
		SuccessorToken := SIHO_StartOwned(Successor, "observer-b", false)
		Assert(SuccessorToken > SecondToken,
			"a successor must never reuse an older owner's token")
		AssertTrue(SIHO_Unregister(FirstToken, First),
			"the old hook must unregister only its own owner record")
		FirstToken := 0
		AssertEqual(1, SIHO_Count(),
			"an old finally must not remove the successor hook")
		AssertFalse(SIHO_Unregister(SecondToken, Second),
			"a completed owner cannot unregister twice")
		AssertEqual(1, SIHO_Count(),
			"a stale terminal callback must leave the successor registered")
	} finally {
		if (FirstToken > 0)
			try SIHO_Unregister(FirstToken, First)
		if (SecondToken > 0)
			try SIHO_Unregister(SecondToken, Second)
		if (SuccessorToken > 0)
			try SIHO_Unregister(SuccessorToken, Successor)
	}
}

Test("input hooks: overlapping suppressive owners stop and unregister exactly (suppressive-inputhook-ownership)",
	_SIHO_OverlappingOwnersStopAndUnregisterExactly)

_SIHO_ExclusiveStateMachinesDoNotOverlapAcrossNames() {
	First := _SIHO_TestHook("one-shot")
	Second := _SIHO_TestHook("dead-key")
	FirstToken := 0
	try {
		FirstToken := SIHO_StartOwned(First, "one-shot-shift", true)
		Assert(FirstToken > 0,
			"the first exclusive suppressive state machine must acquire ownership")
		AssertEqual(0, SIHO_StartOwned(Second, "dead-key", true),
			"a differently named exclusive state machine must not overlap an active suppressive capture")
		AssertEqual(0, Second.StartCalls,
			"a rejected cross-owner overlap must never arm its native InputHook")
	} finally {
		if (FirstToken > 0)
			try SIHO_Unregister(FirstToken, First)
	}
}

Test("input hooks: exclusive suppressive state machines serialize across owner names",
	_SIHO_ExclusiveStateMachinesDoNotOverlapAcrossNames)

_SIHO_RefusedOneShotShiftClearsItsLogicalLatch() {
	Body := _DriverFuncBody("OneShotShift")
	Assert(RegExMatch(Body,
		"s)OwnerToken\s*:=\s*SIHO_StartOwned\(ihvText,\s*\x22one-shot-shift\x22,\s*true\).*?if\s*!OwnerToken\s*\{\s*OneShotShiftEnabled\s*:=\s*False\s*return\s*\}"),
		"a refused native one-shot capture must also retire its logical shift latch")
}

Test("input hooks: refused one-shot shift admission clears its logical latch",
	_SIHO_RefusedOneShotShiftClearsItsLogicalLatch)
