; tests/unit/test_clipboard_paste_transaction_ownership.ahk
#Requires AutoHotkey v2.0

_CPT_ProducerPairsRemainExclusive() {
	Assert(IsSet(CB_TryBeginPasteTransaction),
		"clipboard paste producers need an atomic exclusive lease")
	Assert(IsSet(CB_IsPasteTransactionActive),
		"clipboard paste busy state must be derived from the exact live lease")
	Producers := ["hotstring_send_instant", "gesture_paste_plain", "paste_without_formatting"]
	for FirstSource in Producers {
		for SecondSource in Producers {
			if (SecondSource == FirstSource)
				continue
			FirstToken := CB_TryBeginPasteTransaction(FirstSource)
			Assert(FirstToken > 0,
				FirstSource . " must acquire the idle clipboard transaction")
			try {
				AssertEqual(0, CB_TryBeginPasteTransaction(SecondSource),
					SecondSource . " must be refused before it can snapshot over " . FirstSource)
				AssertTrue(CB_IsPasteTransactionActive(),
					"a refused contender must not clear the first owner's busy state")
			} finally {
				CB_EndOwnedTransaction(FirstToken)
			}
			AssertFalse(CB_IsPasteTransactionActive(),
				"the exact owner must release the lease after its terminal path")
		}
	}
}

_CPT_StaleTerminalCannotAdmitThirdProducer() {
	Clipboard := "O"
	Sequence := 100
	FirstToken := CB_TryBeginPasteTransaction("hotstring_send_instant")
	Assert(FirstToken > 0)
	FirstSnapshot := Clipboard
	Clipboard := "PA"
	Sequence += 1
	FirstSequence := Sequence
	AssertEqual(0, CB_TryBeginPasteTransaction("gesture_paste_plain"),
		"the second producer cannot snapshot the first producer's payload")
	if (Sequence == FirstSequence) {
		Clipboard := FirstSnapshot
		Sequence += 1
	}
	AssertTrue(CB_EndOwnedTransaction(FirstToken))

	SecondToken := CB_TryBeginPasteTransaction("gesture_paste_plain")
	Assert(SecondToken > FirstToken)
	SecondSnapshot := Clipboard
	Clipboard := "PB"
	Sequence += 1
	SecondSequence := Sequence
	try {
		; Replay the first timer after the second owner has published. Its sequence
		; fence skips restore and its stale token cannot release the second lease.
		if (Sequence == FirstSequence)
			Clipboard := FirstSnapshot
		AssertFalse(CB_EndOwnedTransaction(FirstToken),
			"an out-of-order stale terminal must not release a newer transaction")
		AssertTrue(CB_IsPasteTransactionActive(),
			"the newer owner must remain busy after stale cleanup")
		AssertEqual(0, CB_TryBeginPasteTransaction("paste_without_formatting"),
			"a third producer must remain excluded while the exact owner is live")
	} finally {
		if (Sequence == SecondSequence)
			Clipboard := SecondSnapshot
		CB_EndOwnedTransaction(SecondToken)
	}
	AssertEqual("O", Clipboard,
		"serialized owners must restore the user's original clipboard after out-of-order terminals")

	ThirdToken := CB_TryBeginPasteTransaction("paste_without_formatting")
	Assert(ThirdToken > SecondToken,
		"the third producer may acquire only after the exact second owner releases")
	AssertTrue(CB_EndOwnedTransaction(ThirdToken))
	AssertFalse(CB_IsPasteTransactionActive())
}

Test("clipboard: every paste producer pair is exclusive before snapshot (clipboard-paste-transaction-ownership)",
	_CPT_ProducerPairsRemainExclusive)
Test("clipboard: stale terminal cannot release owner or admit third producer (clipboard-paste-transaction-ownership)",
	_CPT_StaleTerminalCannotAdmitThirdProducer)

_CPT_CrossFamilyOwnersRemainExclusive() {
	GenericToken := CB_TryBeginOwnedTransaction("text_sender", true)
	PasteToken := 0
	try {
		PasteToken := CB_TryBeginPasteTransaction("hotstring_send_instant")
		AssertEqual(0, PasteToken,
			"a paste producer must not snapshot over a generic clipboard owner")
	} finally {
		if PasteToken
			CB_EndOwnedTransaction(PasteToken)
		CB_EndOwnedTransaction(GenericToken)
	}

	PasteToken := CB_TryBeginPasteTransaction("hotstring_send_instant")
	GenericToken := 0
	try {
		GenericToken := CB_TryBeginOwnedTransaction("text_sender", true)
		AssertEqual(0, GenericToken,
			"a generic clipboard owner must not snapshot over a paste producer")
	} finally {
		if GenericToken
			CB_EndOwnedTransaction(GenericToken)
		CB_EndOwnedTransaction(PasteToken)
	}
}

Test("clipboard: ownership is exclusive across producer families (AHK-067)",
	_CPT_CrossFamilyOwnersRemainExclusive)

global _CPT_RESTORE_ATTEMPTS := 0
global _CPT_RESTORE_SEQUENCE := 501
global _CPT_RESTORE_SNAPSHOTS := []

_CPT_RestoreFailsOnce(Snapshot) {
	global _CPT_RESTORE_ATTEMPTS, _CPT_RESTORE_SNAPSHOTS
	_CPT_RESTORE_ATTEMPTS += 1
	_CPT_RESTORE_SNAPSHOTS.Push(Snapshot)
	return _CPT_RESTORE_ATTEMPTS > 1
}

_CPT_CurrentSequence() {
	global _CPT_RESTORE_SEQUENCE
	return _CPT_RESTORE_SEQUENCE
}

_CPT_FailedRestoreRetainsSnapshotAndOwner() {
	global _CPT_RESTORE_ATTEMPTS, _CPT_RESTORE_SEQUENCE, _CPT_RESTORE_SNAPSHOTS
	_CPT_RESTORE_ATTEMPTS := 0
	_CPT_RESTORE_SEQUENCE := 501
	_CPT_RESTORE_SNAPSHOTS := []
	OwnerToken := CB_TryBeginPasteTransaction("ahk_052_test")
	Assert(OwnerToken > 0)

	AssertFalse(CB_RestoreOwnedAllEventually("original", 501, OwnerToken,
		"ahk_052_test", true, false, _CPT_RestoreFailsOnce,
		_CPT_CurrentSequence),
		"the initial lock failure must be reported while retaining restoration debt")
	AssertTrue(CB_HasRestoreDebtForOwner(OwnerToken),
		"the only clipboard snapshot and its exact owner must survive a failed restore")
	AssertEqual(0, CB_TryBeginPasteTransaction("contender"),
		"a new producer must not snapshot the synthetic payload while restoration is owed")

	CB_RetryRestoreDebt()
	AssertFalse(CB_HasRestoreDebtForOwner(OwnerToken),
		"a successful retry must retire the restoration debt")
	AssertFalse(CB_IsPasteTransactionActive(),
		"the exact transaction owner must be released only after the retry succeeds")
	AssertEqual(2, _CPT_RESTORE_ATTEMPTS,
		"the retained snapshot must be retried after the first clipboard lock failure")
	AssertEqual("original", _CPT_RESTORE_SNAPSHOTS[1])
	AssertEqual("original", _CPT_RESTORE_SNAPSHOTS[2])
}

Test("clipboard: failed restore retains snapshot and owner until retry (AHK-052)",
	_CPT_FailedRestoreRetainsSnapshotAndOwner)

_CPT_UnfencedRetryYieldsToObservableClipboard() {
	global _CPT_RESTORE_ATTEMPTS, _CPT_RESTORE_SEQUENCE, _CPT_RESTORE_SNAPSHOTS
	_CPT_RESTORE_ATTEMPTS := 0
	_CPT_RESTORE_SEQUENCE := 0
	_CPT_RESTORE_SNAPSHOTS := []
	OwnerToken := CB_TryBeginPasteTransaction("unfenced_retry_test")
	Assert(OwnerToken > 0)

	AssertFalse(CB_RestoreOwnedAllEventually("original", 0, OwnerToken,
		"unfenced_retry_test", true, true, _CPT_RestoreFailsOnce,
		_CPT_CurrentSequence),
		"an immediately blocked unfenced rollback must retain its snapshot")
	_CPT_RESTORE_SEQUENCE := 777
	CB_RetryRestoreDebt()

	AssertEqual(1, _CPT_RESTORE_ATTEMPTS,
		"a delayed unfenced retry must not overwrite clipboard content that became observable")
	AssertFalse(CB_HasRestoreDebtForOwner(OwnerToken),
		"the newer observable clipboard must retire the unprovable restore debt")
	AssertFalse(CB_IsPasteTransactionActive(),
		"yielding to a newer clipboard must release the exact transaction owner")
}

Test("clipboard: unfenced retry never overwrites newer user copy (clipboard-unfenced-retry-fence)",
	_CPT_UnfencedRetryYieldsToObservableClipboard)

_CPT_ShutdownRefusesLiveSnapshotBeforeDebt() {
	OwnerToken := CB_TryBeginPasteTransaction("ahk_068_test")
	Assert(OwnerToken > 0)
	try AssertFalse(CB_PrepareShutdown(),
		"shutdown must refuse while a deferred owner holds the only snapshot")
	finally CB_EndOwnedTransaction(OwnerToken)
	AssertTrue(CB_PrepareShutdown(),
		"shutdown may proceed after the exact snapshot owner retires")
}

Test("clipboard: shutdown refuses live snapshots before restore debt (AHK-068)",
	_CPT_ShutdownRefusesLiveSnapshotBeforeDebt)


global _CPT_SETTLE_CLASSIFICATION := ""
global _CPT_SETTLE_WAS_CRITICAL := false

_CPT_RestoreImmediately(*) {
	return true
}

_CPT_ObserveSettledOwnerBoundary(*) {
	global _CPT_SETTLE_CLASSIFICATION, _CPT_SETTLE_WAS_CRITICAL
	_CPT_SETTLE_WAS_CRITICAL := A_IsCritical ? true : false
	MutationId := _CB_BeginOwnedMutation()
	_CPT_SETTLE_CLASSIFICATION := CB_ConsumeOwnedChange()
	return MutationId > 0
}

_CPT_RestoreSettlementIsOneOwnershipTransaction() {
	global _CPT_RESTORE_SEQUENCE
	global _CPT_SETTLE_CLASSIFICATION, _CPT_SETTLE_WAS_CRITICAL
	SavedHook := CBClipboardOwner.settle_hook
	SavedObserverActive := CBClipboardOwner.observer_active
	SavedPending := CBClipboardOwner.pending
	OwnerToken := 0
	CB_SetOwnershipObserverActive(true)
	_CPT_RESTORE_SEQUENCE := 811
	_CPT_SETTLE_CLASSIFICATION := ""
	_CPT_SETTLE_WAS_CRITICAL := false
	CBClipboardOwner.settle_hook := _CPT_ObserveSettledOwnerBoundary
	try {
		OwnerToken := CB_TryBeginPasteTransaction("settle_atomicity_test")
		AssertTrue(OwnerToken > 0, "the settlement fixture must own the paste slot")
		AssertTrue(CB_RestoreOwnedAllEventually("original", 811, OwnerToken,
			"settle_atomicity_test", true, false, _CPT_RestoreImmediately,
			_CPT_CurrentSequence),
			"the immediate restore fixture must settle successfully")
		AssertTrue(_CPT_SETTLE_WAS_CRITICAL,
			"debt and owner retirement must share one non-interruptible transaction")
		AssertEqual("replace", _CPT_SETTLE_CLASSIFICATION,
			"a mutation admitted at the settlement boundary must not inherit the retired temporary owner")
		AssertFalse(CB_IsPasteTransactionActive(),
			"the paste slot must be retired before the settlement boundary is observable")
	} finally {
		CBClipboardOwner.settle_hook := SavedHook
		if OwnerToken
			CB_EndOwnedTransaction(OwnerToken)
		CB_SetOwnershipObserverActive(false)
		CBClipboardOwner.observer_active := SavedObserverActive
		CBClipboardOwner.pending := SavedPending
	}
}

Test("clipboard: restore debt and owner settle atomically",
	_CPT_RestoreSettlementIsOneOwnershipTransaction)


_CPT_InactiveObserverOwnsNoNotificationFifo() {
	SavedObserverActive := CBClipboardOwner.observer_active
	SavedPending := CBClipboardOwner.pending
	CBClipboardOwner.pending := []
	try {
		CB_SetOwnershipObserverActive(false)
		loop 1000
			_CB_BeginOwnedMutation()
		AssertEqual(0, CBClipboardOwner.pending.Length,
			"adapter writes must not accumulate notification records while metrics observation is stopped")

		CB_SetOwnershipObserverActive(true)
		_CB_BeginOwnedMutation()
		AssertEqual(1, CBClipboardOwner.pending.Length,
			"an active observer must receive the exact next mutation owner")
		CB_SetOwnershipObserverActive(false)
		AssertEqual(0, CBClipboardOwner.pending.Length,
			"stopping observation must discard callbacks which can no longer arrive")
	} finally {
		CBClipboardOwner.observer_active := SavedObserverActive
		CBClipboardOwner.pending := SavedPending
	}
}

Test("clipboard: inactive observer cannot accumulate notification ownership",
	_CPT_InactiveObserverOwnsNoNotificationFifo)
