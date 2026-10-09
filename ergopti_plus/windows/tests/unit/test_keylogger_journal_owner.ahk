; tests/unit/test_keylogger_journal_owner.ahk

; ==============================================================================
; MODULE: Keylogger Journal Ownership Tests
; DESCRIPTION:
; Refused compensation pins the exact file and blocks successors until repaired.
; Tokens also exclude reentrant callbacks without holding Critical across I/O.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../modules/keylogger/keylogger_journal_owner.ahk

_KJO_Repair(Owner, State, FileObject, Boundary) {
	State["calls"] += 1
	AssertTrue(FileObject = State["file"], "repair must retain the original file identity")
	AssertEqual(37, Boundary)
	AssertEqual(0, A_IsCritical, "repair must perform I/O outside Critical")
	AssertFalse(IsObject(Owner.Acquire()), "a callback cannot acquire a competing journal owner")
	if State["throws"]
		throw Error("PRIVATE-REPAIR-CANARY")
	return State["accept"]
}

_KJO_Recovery(Throws) {
	Owner := KL_JournalOwner()
	FileObject := {}
	State := Map("calls", 0, "file", FileObject, "accept", false,
		"throws", Throws)
	Token := Owner.Acquire()
	AssertTrue(IsObject(Token))
	AssertFalse(Owner.Rollback(Token, FileObject, 37, _KJO_Repair.Bind(Owner, State)))
	AssertTrue(Owner.HasDebt())
	AssertThrows(() => Owner.__New(), "duplicate initialization must not erase recovery authority")
	AssertTrue(Owner.HasDebt())
	AssertEqual(Throws ? "Error" : "refused", Owner.Failure, "diagnostics must not expose exception payloads")
	AssertThrows(() => Owner.Rollback(Token, {}, 0, (*) => true))
	Owner.Release(Token)
	AssertFalse(IsObject(Owner.Acquire()), "unrepaired debt must reject the next operation")
	AssertEqual(2, State["calls"])
	AssertTrue(Owner.HasDebt())
	State["throws"] := false
	State["accept"] := true
	Successor := Owner.Acquire()
	AssertTrue(IsObject(Successor))
	AssertTrue(Successor != Token)
	AssertFalse(Owner.HasDebt())
	AssertEqual(3, State["calls"])
	Owner.Release(Successor)
}

for Throws in [false, true]
	Test("keylogger: retained journal repair throws=" . Throws . " (keylogger-journal-owner)", _KJO_Recovery.Bind(Throws))

_KJO_Tokens() {
	Owner := KL_JournalOwner()
	Other := KL_JournalOwner()
	Token := Owner.Acquire()
	Foreign := Other.Acquire()
	AssertThrows(() => Owner.Require(0))
	AssertThrows(() => Owner.Release(Foreign))
	AssertFalse(IsObject(Owner.Acquire()))
	Owner.Require(Token)
	Owner.Release(Token)
	AssertThrows(() => Owner.Release(Token))
	Successor := Owner.Acquire()
	AssertThrows(() => Owner.Require(Token))
	Owner.Release(Successor)
	Other.Release(Foreign)
}

Test("keylogger: journal tokens reject stale and foreign owners (keylogger-journal-owner)", _KJO_Tokens)
