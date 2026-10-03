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

_KJS_PreInitializationShutdown() {
	Fields := ["initialized", "buffer_events", "buffer_text", "rich_chunks", "session_clicks",
		"session_scrolls", "mouse_distance", "_retry_snapshots", "_pending_entries", "_flush_in_progress"]
	Saved := Map()
	for Name in Fields
		Saved[Name] := Keylogger.%Name%
	try {
		Keylogger.initialized := false
		Keylogger.buffer_events := []
		Keylogger.buffer_text := ""
		Keylogger.rich_chunks := []
		Keylogger.session_clicks := 0
		Keylogger.session_scrolls := 0
		Keylogger.mouse_distance := 0
		Keylogger._retry_snapshots := []
		Keylogger._pending_entries := []
		Keylogger._flush_in_progress := false
		Port := Map("owner", KL_JournalOwner())
		AssertTrue(KL_FlushShutdownReady(Port), "empty pre-initialization owner has no persistence debt")
		Keylogger._pending_entries := [Map("type", "system_event")]
		AssertFalse(KL_FlushShutdownReady(Port), "accepted queue must not be discarded after failed initialization")
		Keylogger._pending_entries := []
		Token := Port["owner"].Acquire()
		AssertFalse(KL_FlushShutdownReady(Port), "active journal ownership still refuses shutdown")
		Port["owner"].Rollback(Token, {}, 0, (*) => false)
		Port["owner"].Release(Token)
		AssertFalse(KL_FlushShutdownReady(Port), "uninitialized compensation debt is never bypassed")
	} finally {
		for Name, Value in Saved
			Keylogger.%Name% := Value
	}
}
Test("keylogger: early UI shutdown accepts only an empty owner (early-ui-admission)", _KJS_PreInitializationShutdown)
