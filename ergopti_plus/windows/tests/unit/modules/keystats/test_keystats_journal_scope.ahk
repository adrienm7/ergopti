; tests/unit/modules/keystats/test_keystats_journal_scope.ahk

; ==============================================================================
; MODULE: Keystats Journal Scope Tests
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

Test("keystats: nested journal scope retains outer authority (keystats-journal-scope)", _KJS_NestedScope)

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

Test("keystats: unresolved repair refuses nested journal access (keystats-journal-scope)", _KJS_DebtRefusesBorrower)

_KJS_PreInitializationShutdown() {
	Fields := ["initialized", "buffer_events", "buffer_text", "rich_chunks", "session_clicks",
		"session_scrolls", "mouse_distance", "_retry_snapshots", "_pending_entries", "_flush_in_progress"]
	Saved := Map()
	for Name in Fields
		Saved[Name] := Keystats.%Name%
	try {
		Keystats.initialized := false
		Keystats.buffer_events := []
		Keystats.buffer_text := ""
		Keystats.rich_chunks := []
		Keystats.session_clicks := 0
		Keystats.session_scrolls := 0
		Keystats.mouse_distance := 0
		Keystats._retry_snapshots := []
		Keystats._pending_entries := []
		Keystats._flush_in_progress := false
		Port := Map("owner", KL_JournalOwner())
		AssertTrue(KL_FlushShutdownReady(Port), "empty pre-initialization owner has no persistence debt")
		Keystats._pending_entries := [Map("type", "system_event")]
		AssertFalse(KL_FlushShutdownReady(Port), "accepted queue must not be discarded after failed initialization")
		Keystats._pending_entries := []
		Token := Port["owner"].Acquire()
		AssertFalse(KL_FlushShutdownReady(Port), "active journal ownership still refuses shutdown")
		Port["owner"].Rollback(Token, {}, 0, (*) => false)
		Port["owner"].Release(Token)
		AssertFalse(KL_FlushShutdownReady(Port), "uninitialized compensation debt is never bypassed")
		; The shutdown log names the refusal; an in-progress flush is told apart.
		Reason := "unset"
		AssertFalse(KL_FlushShutdownReady(Port, , &Reason))
		AssertEqual("uninitialized_owner_debt", Reason)
		Keystats._flush_in_progress := true
		AssertFalse(KL_FlushShutdownReady(Port, , &Reason))
		AssertEqual("flush_in_progress", Reason, "a busy flush is reported as such, not as debt")
		Keystats._flush_in_progress := false
	} finally {
		for Name, Value in Saved
			Keystats.%Name% := Value
	}
}
Test("keystats: early UI shutdown accepts only an empty owner (early-ui-admission)", _KJS_PreInitializationShutdown)

_KJS_AwaitFlushHandoff() {
	SavedFlush := Keystats._flush_in_progress
	try {
		Port := Map("owner", KL_JournalOwner())
		Polls := []
		Arm := (Callback, DelayMs) => Polls.Push(Map("callback", Callback, "delay", DelayMs))
		Outcome := []
		Settled := (*) => Outcome.Push("settled")
		Expired := (*) => Outcome.Push("expired")
		; A running flush keeps the exit waiting, then releases it once it ends.
		Keystats._flush_in_progress := true
		AssertFalse(KL_FlushHandoffSettled(Port), "a running flush is not settled")
		KL_AwaitFlushHandoff(Settled, Expired, A_TickCount + 60000, 100, Arm, Port)
		AssertEqual(1, Polls.Length, "a running flush schedules the next poll")
		AssertEqual(100, Polls[1]["delay"])
		AssertEqual(0, Outcome.Length, "nothing runs while the flush holds persistence")
		Keystats._flush_in_progress := false
		Token := Port["owner"].Acquire()
		Polls[1]["callback"].Call()
		AssertEqual(2, Polls.Length, "a journal handoff in progress still waits")
		AssertEqual(0, Outcome.Length)
		Port["owner"].Release(Token)
		Polls[2]["callback"].Call()
		AssertEqual("settled", Outcome.Length ? Outcome[1] : "", "the settled handoff releases the exit")
		AssertEqual(2, Polls.Length, "a settled handoff arms no further poll")
		; A flush that never ends expires instead of polling forever.
		Outcome := []
		Polls := []
		Keystats._flush_in_progress := true
		KL_AwaitFlushHandoff(Settled, Expired, A_TickCount - 1, 100, Arm, Port)
		AssertEqual("expired", Outcome.Length ? Outcome[1] : "", "an elapsed deadline abandons the retry")
		AssertEqual(0, Polls.Length)
	} finally {
		Keystats._flush_in_progress := SavedFlush
	}
}
Test("keystats: a deferred exit waits for the flush handoff, then runs once (flush-exit-retry)", _KJS_AwaitFlushHandoff)
