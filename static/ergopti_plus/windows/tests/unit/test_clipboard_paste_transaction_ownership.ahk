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
