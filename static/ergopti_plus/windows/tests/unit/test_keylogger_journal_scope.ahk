; tests/unit/test_keylogger_journal_scope.ahk

; ==============================================================================
; MODULE: Keylogger Journal Scope Tests
; DESCRIPTION:
; Nested lifecycle operations borrow authority without releasing their caller.
; Recovery debt refuses even a borrowed token and preserves interruptibility.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJS_NestedScope() {
	Owner := KL_JournalOwner()
	Port := Map("owner", Owner)
	PreviousCritical := Critical("On")
	Outer := 0
	try {
		CallerCritical := A_IsCritical
		Outer := _KL_JournalEnter(0, Port)
		AssertTrue(IsObject(Outer))
		AssertEqual(0, A_IsCritical)
		Inner := _KL_JournalEnter(Outer.Token, Port)
		AssertFalse(Inner.Acquired)
		AssertTrue(Inner.Token = Outer.Token)
		_KL_JournalLeave(Inner)
		Owner.Require(Outer.Token)
		AssertEqual(0, A_IsCritical)
		AssertFalse(IsObject(_KL_JournalEnter(0, Port)))
		_KL_JournalLeave(Outer)
		Outer := 0
		AssertEqual(CallerCritical, A_IsCritical)
		Successor := _KL_JournalEnter(0, Port)
		AssertTrue(IsObject(Successor))
		_KL_JournalLeave(Successor)
	} finally {
		if IsObject(Outer)
			_KL_JournalLeave(Outer)
		Critical(PreviousCritical)
	}
}

Test("keylogger: nested journal scope retains outer authority (keylogger-journal-scope)", _KJS_NestedScope)

_KJS_DebtRefusesBorrower() {
	Owner := KL_JournalOwner()
	Port := Map("owner", Owner)
	Outer := _KL_JournalEnter(0, Port)
	try {
		AssertFalse(Owner.Rollback(Outer.Token, {}, 0, (*) => false))
		AssertFalse(IsObject(_KL_JournalEnter(Outer.Token, Port)))
		Owner.Require(Outer.Token)
		AssertTrue(Owner.HasDebt())
	} finally {
		_KL_JournalLeave(Outer)
	}
}

Test("keylogger: unresolved repair refuses nested journal access (keylogger-journal-scope)", _KJS_DebtRefusesBorrower)
