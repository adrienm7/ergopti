; tests/unit/test_keylogger_journal_owner_validation.ahk

; ==============================================================================
; MODULE: Keylogger Journal Owner Validation Tests
; DESCRIPTION:
; Recovery requires an explicit Boolean receipt and cannot release its owner
; from inside a callback. Invalid admissions must not mutate recovery authority.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../modules/keylogger/keylogger_journal_owner.ahk

_KJOV_Receipt(Value) {
	Owner := KL_JournalOwner()
	Token := Owner.Acquire()
	State := Map("receipt", Value)
	AssertFalse(Owner.Rollback(Token, {}, 0, (*) => State["receipt"]))
	AssertTrue(Owner.HasDebt())
	AssertEqual("invalid_receipt", Owner.Failure)
	Owner.Release(Token)
	State["receipt"] := true
	Successor := Owner.Acquire()
	AssertTrue(IsObject(Successor))
	AssertFalse(Owner.HasDebt())
	Owner.Release(Successor)
}

for Value in ["1", 1.0, 2, Map()]
	Test("keylogger: journal rejects coerced repair receipt " . Type(Value) . ":" . A_Index
		. " (keylogger-journal-owner)", _KJOV_Receipt.Bind(Value))

_KJOV_EarlyRelease(Owner, Token, State, *) {
	if State["release"]
		Owner.Release(Token)
	return true
}

_KJOV_CallbackRelease() {
	Owner := KL_JournalOwner()
	Token := Owner.Acquire()
	State := Map("release", true)
	AssertFalse(Owner.Rollback(Token, {}, 0, _KJOV_EarlyRelease.Bind(Owner, Token, State)))
	AssertTrue(Owner.HasDebt())
	AssertEqual("Error", Owner.Failure)
	Owner.Require(Token)
	AssertFalse(IsObject(Owner.Acquire()))
	Owner.Release(Token)
	State["release"] := false
	Successor := Owner.Acquire()
	AssertTrue(IsObject(Successor))
	AssertFalse(Owner.HasDebt())
	Owner.Release(Successor)
}

Test("keylogger: journal repair cannot release its current owner (keylogger-journal-owner)", _KJOV_CallbackRelease)

_KJOV_InvalidDebt() {
	Owner := KL_JournalOwner()
	Token := Owner.Acquire()
	for Boundary in [-1, "0", 0.0] {
		Failure := 0
		try Owner.Rollback(Token, {}, Boundary, (*) => true)
		catch Any as Err
			Failure := Err
		AssertTrue(Failure is ValueError, "invalid boundary must reach value validation")
		AssertFalse(Owner.HasDebt())
	}
	Failure := 0
	try Owner.Rollback(Token, 0, 0, (*) => true)
	catch Any as Err
		Failure := Err
	AssertTrue(Failure is ValueError, "invalid file must reach value validation")
	Failure := 0
	try Owner.Rollback(Token, {}, 0, 0)
	catch Any as Err
		Failure := Err
	AssertTrue(Failure is TypeError, "invalid callback must reach callable validation")
	AssertFalse(Owner.HasDebt())
	AssertTrue(Owner.Rollback(Token, {}, 0, (*) => true))
	Owner.Release(Token)
}

Test("keylogger: invalid journal debt cannot publish recovery state (keylogger-journal-owner)", _KJOV_InvalidDebt)

_KJOV_CriticalRepair(State, *) {
	State["critical"].Push(A_IsCritical)
	if State["mode"] = "throw"
		throw Error("injected repair exception")
	return State["mode"] = "accept"
}

_KJOV_CriticalBoundary(Mode) {
	Owner := KL_JournalOwner()
	State := Map("mode", Mode, "critical", [])
	PreviousCritical := Critical("On")
	Token := 0
	try {
		CallerCritical := A_IsCritical
		Token := Owner.Acquire()
		Result := Owner.Rollback(Token, {}, 0, _KJOV_CriticalRepair.Bind(State))
		AssertEqual(Mode = "accept", Result)
		AssertEqual(CallerCritical, A_IsCritical, "repair must restore the caller's Critical state")
		AssertEqual(1, State["critical"].Length)
		AssertEqual(0, State["critical"][1], "filesystem compensation must be interruptible even for a Critical caller")
	} finally {
		if IsObject(Token)
			Owner.Release(Token)
		Critical(PreviousCritical)
	}
}

for Mode in ["accept", "refuse", "throw"]
	Test("keylogger: journal repair exits Critical for " . Mode . " (keylogger-journal-owner-critical)", _KJOV_CriticalBoundary.Bind(Mode))

_KJOV_InvalidHandoffToken() {
	SavedPending := Keylogger._pending_entries
	Owner := KL_JournalOwner()
	Port := Map("owner", Owner)
	try {
		Queue := []
		Keylogger._pending_entries := Queue
		for Token in ["0", 0.0, 1, -1] {
			Failure := 0
			try _KL_JournalPendingEntries(Port, Token)
			catch Any as Err
				Failure := Err
			AssertTrue(Failure is TypeError, "invalid token must raise TypeError, got " . Type(Failure))
			AssertTrue(Keylogger._pending_entries = Queue)
			Lease := Owner.Acquire()
			AssertTrue(IsObject(Lease), "invalid token must not acquire journal ownership")
			Owner.Release(Lease)
		}
		AssertTrue(_KL_JournalPendingEntries(Port, 0)["ok"])
	} finally {
		Keylogger._pending_entries := SavedPending
	}
}

Test("keylogger: handoff rejects invalid ownership tokens before queue mutation (keylogger-journal-owner-token)", _KJOV_InvalidHandoffToken)
