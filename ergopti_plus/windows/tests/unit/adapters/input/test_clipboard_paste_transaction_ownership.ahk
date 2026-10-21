; tests/unit/adapters/input/test_clipboard_paste_transaction_ownership.ahk
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

_CPT_CrossFamilyOwnersRemainExclusive(AfterGenericOwnerFn?) {
	GenericToken := CB_TryBeginOwnedTransaction("text_sender", true)
	PasteToken := 0
	try {
		Assert(GenericToken > 0, "the first generic owner must acquire the idle clipboard lease")
		PasteToken := CB_TryBeginPasteTransaction("hotstring_send_instant")
		AssertEqual(0, PasteToken,
			"a paste producer must not snapshot over a generic clipboard owner")
	} finally {
		if PasteToken
			CB_EndOwnedTransaction(PasteToken)
		CB_EndOwnedTransaction(GenericToken)
	}

	; Tests may inject an actual competing lease between these separate transactions.
	if IsSet(AfterGenericOwnerFn)
		AfterGenericOwnerFn.Call()

	PasteToken := CB_TryBeginPasteTransaction("hotstring_send_instant")
	GenericToken := 0
	try {
		Assert(PasteToken > 0, "the first paste owner must acquire the idle clipboard lease")
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





; ==============================================================================
; ==============================================================================
; ======= Cross-family oracle requires an acquired first clipboard owner =======
; ==============================================================================
; ==============================================================================

_CPT_CrossFamilyOracleRejectsForeignOwner(UsePasteOwner) {
	ForeignToken := UsePasteOwner ? CB_TryBeginPasteTransaction("cpt_foreign_paste_fixture")
		: CB_TryBeginOwnedTransaction("cpt_foreign_generic_fixture", true)
	Assert(ForeignToken > 0, "the oracle fixture must acquire its own foreign lease")
	try {
		ForeignActive := CBClipboardOwner.active
		ForeignRecord := ForeignActive[ForeignToken]
		ForeignGeneration := CBClipboardOwner.generation
		ForeignPasteSlot := CBClipboardOwner.paste_transaction
		ForeignSource := ForeignRecord["source"]
		ForeignSuppressPaste := ForeignRecord["suppress_paste"]
		ForeignPreserve := ForeignRecord["preserve_provenance"]
		Caught := 0
		try _CPT_CrossFamilyOwnersRemainExclusive()
		catch as Failure
			Caught := Failure

		; The callback must diagnose refusal without releasing or replacing another owner.
		Assert(CBClipboardOwner.active == ForeignActive,
			"the tested callback must preserve the exact foreign owner map")
		AssertEqual(1, CBClipboardOwner.active.Count,
			"a refused cross-family callback must neither clear nor admit an owner")
		Assert(CBClipboardOwner.active.Has(ForeignToken),
			"the fixture's preexisting foreign token must remain live")
		Assert(CBClipboardOwner.active[ForeignToken] == ForeignRecord,
			"the fixture's exact foreign record must remain unchanged")
		AssertEqual(ForeignGeneration, CBClipboardOwner.generation,
			"refusal must not mint a hidden cross-family lease")
		AssertEqual(ForeignPasteSlot, CBClipboardOwner.paste_transaction,
			"refusal must preserve the existing foreign paste slot")
		AssertEqual(ForeignSource, ForeignRecord["source"])
		AssertEqual(ForeignSuppressPaste, ForeignRecord["suppress_paste"])
		AssertEqual(ForeignPreserve, ForeignRecord["preserve_provenance"])
		Assert(Caught is Error,
			"the cross-family callback must fail when its first generic lease is refused")
		AssertEqual("Error", Type(Caught),
			"an unrelated runtime exception must not satisfy the acquisition oracle")
		AssertEqual("the first generic owner must acquire the idle clipboard lease", Caught.Message,
			"the actual callback must name its first acquisition failure")
	} finally {
		; Release only this fixture's acquired identity; never reset shared foreign state.
		if !CB_EndOwnedTransaction(ForeignToken)
			throw Error("The oracle fixture's exact foreign lease could not be released.")
	}
}

Test("clipboard: cross-family oracle rejects a preexisting generic owner",
	_CPT_CrossFamilyOracleRejectsForeignOwner.Bind(false))
Test("clipboard: cross-family oracle rejects a preexisting paste owner",
	_CPT_CrossFamilyOracleRejectsForeignOwner.Bind(true))


_CPT_AdmitForeignOwnerBetweenFamilies(State) {
	AssertEqual(0, State.Calls, "the competing-owner seam must run exactly once")
	State.Calls += 1
	State.Token := CB_TryBeginOwnedTransaction("cpt_between_families_fixture", true)
	Assert(State.Token > 0, "the between-family fixture must acquire its own competing lease")
	State.Active := CBClipboardOwner.active
	State.Record := State.Active[State.Token]
	State.Generation := CBClipboardOwner.generation
	State.PasteSlot := CBClipboardOwner.paste_transaction
}

_CPT_CrossFamilyOracleRejectsSecondOwnerRefusal() {
	State := {Calls: 0, Token: 0, Active: 0, Record: 0, Generation: 0, PasteSlot: 0}
	Caught := 0
	try {
		try _CPT_CrossFamilyOwnersRemainExclusive(_CPT_AdmitForeignOwnerBetweenFamilies.Bind(State))
		catch as Failure
			Caught := Failure
		AssertEqual(1, State.Calls,
			"the first real generic owner must finish before the competing lease is admitted")
		Assert(State.Token > 0, "the second-branch fixture must retain its actual competing token")
		Assert(CBClipboardOwner.active == State.Active,
			"the second refusal must preserve the exact competing owner map")
		AssertEqual(1, CBClipboardOwner.active.Count)
		Assert(CBClipboardOwner.active.Has(State.Token),
			"the second refusal must not release the competing lease")
		Assert(CBClipboardOwner.active[State.Token] == State.Record,
			"the second refusal must preserve the exact competing owner record")
		AssertEqual(State.Generation, CBClipboardOwner.generation)
		AssertEqual(State.PasteSlot, CBClipboardOwner.paste_transaction)
		AssertEqual("cpt_between_families_fixture", State.Record["source"])
		AssertTrue(State.Record["suppress_paste"])
		AssertTrue(State.Record["preserve_provenance"])
		Assert(Caught is Error,
			"the cross-family callback must fail when its first paste lease is refused")
		AssertEqual("Error", Type(Caught),
			"an unrelated second-branch exception must not satisfy the acquisition oracle")
		AssertEqual("the first paste owner must acquire the idle clipboard lease", Caught.Message,
			"the actual callback must name its second acquisition failure")
	} finally {
		if State.Token && !CB_EndOwnedTransaction(State.Token)
			throw Error("The second-branch fixture's exact competing lease could not be released.")
	}
}

Test("clipboard: cross-family oracle rejects a competing owner between transactions",
	_CPT_CrossFamilyOracleRejectsSecondOwnerRefusal)





; ===============================================================================
; ===============================================================================
; ======= Observable clipboard ownership fences the first restore attempt =======
; ===============================================================================
; ===============================================================================

class _CPT_FirstFenceRecording {
	__New(Sequences, Restores) {
		this.Sequences := Sequences
		this.Restores := Restores
		this.SequenceReads := 0
		this.RestoreCalls := 0
		this.Snapshots := []
	}

	Sequence() {
		this.SequenceReads += 1
		Value := this.Sequences[this.SequenceReads]
		if Value == "throw_sequence"
			throw Error("recording sequence unavailable")
		return Value
	}

	Restore(Snapshot) {
		this.RestoreCalls += 1
		this.Snapshots.Push(Snapshot)
		Value := this.Restores[this.RestoreCalls]
		if Value == "throw_restore"
			throw Error("recording restore unavailable")
		return Value
	}
}

_CPT_AssertFirstFence(ExpectedSequence, Force, Sequences, Restores, Stages, ReleaseOwner := true) {
	PreviousCritical := Critical("On")
	SavedHook := CBClipboardOwner.settle_hook
	OwnerToken := 0
	DebtIdentity := 0
	Recording := _CPT_FirstFenceRecording(Sequences, Restores)
	Snapshot := Map("fixture", "opaque_saved_snapshot")
	try {
		AssertEqual(0, CBClipboardOwner.active.Count, "the fixture requires an idle owner registry")
		AssertEqual(0, CBClipboardOwner.paste_transaction, "the fixture refuses a foreign paste slot")
		AssertEqual(0, CBClipboardOwner.restore_debt, "the fixture refuses foreign restoration debt")
		CBClipboardOwner.settle_hook := 0
		OwnerToken := CB_TryBeginPasteTransaction("clipboard_first_fence_fixture")
		Assert(OwnerToken > 0, "the recording fixture must acquire its exact owner")
		OwnerRecord := CBClipboardOwner.active[OwnerToken]
		for StageIndex, Stage in Stages {
			if StageIndex == 1
				Result := CB_RestoreOwnedAllEventually(Snapshot, ExpectedSequence,
					OwnerToken, "clipboard_first_fence_fixture", ReleaseOwner, Force,
					Recording.Restore.Bind(Recording), Recording.Sequence.Bind(Recording))
			else
				Result := CB_RetryRestoreDebt()
			AssertEqual(Stage[1], Result, "the actual retry must report settlement precisely")
			AssertEqual(Stage[2], Recording.RestoreCalls,
				"an unfenced first restore must preserve positive observable clipboard content")
			AssertEqual(StageIndex, Recording.SequenceReads, "every attempt must observe its recording sequence")
			if Stage[3] {
				AssertTrue(CB_HasRestoreDebtForOwner(OwnerToken), "a blocked attempt retains the exact snapshot owner")
				Debt := CBClipboardOwner.restore_debt
				if StageIndex == 1
					DebtIdentity := Debt
				else
					Assert(Debt == DebtIdentity, "retries must retain the original debt receipt")
				Assert(Debt["saved"] == Snapshot, "debt must retain the exact opaque snapshot")
				AssertEqual(StageIndex, Debt["attempts"], "the actual owner records each attempted observation")
				AssertFalse(Debt["attempting"], "a failed attempt must reopen its retry gate")
			}
			else
				AssertFalse(CB_HasRestoreDebtForOwner(OwnerToken), "settlement must retire only this debt")
			OwnerExpected := Stage[3] or !ReleaseOwner
			AssertEqual(OwnerExpected ? 1 : 0, CBClipboardOwner.active.Count,
				"the owner must remain live exactly while debt or explicit caller ownership remains")
			AssertEqual(OwnerExpected ? OwnerToken : 0, CBClipboardOwner.paste_transaction,
				"the exact paste slot must follow its acquired owner")
			if OwnerExpected
				Assert(CBClipboardOwner.active[OwnerToken] == OwnerRecord, "restoration must preserve the exact live record")
		}
		for _, SeenSnapshot in Recording.Snapshots
			Assert(SeenSnapshot == Snapshot, "the recording restore may receive only the acquired snapshot")
	} finally {
		; No callback can run while the recording case holds Critical. Cancel the
		; real retry timer before restoring the caller, including assertion failures.
		try {
			if OwnerToken {
				try SetTimer(CB_RetryRestoreDebt, 0)
				Debt := CBClipboardOwner.restore_debt
				if Debt is Map and Debt["owner_token"] == OwnerToken
					_CB_SettleRestoreDebt(Debt)
			}
		} finally {
			if OwnerToken
				CB_EndOwnedTransaction(OwnerToken)
			CBClipboardOwner.settle_hook := SavedHook
			Critical(PreviousCritical)
		}
	}
}

_CPT_FirstUnfencedPositive() {
	_CPT_AssertFirstFence(0, true, [777], [true], [[true, 0, false]])
}

_CPT_FirstKnownMatching() {
	_CPT_AssertFirstFence(501, false, [501], [true], [[true, 1, false]])
}

_CPT_FirstKnownForeign() {
	_CPT_AssertFirstFence(501, false, [777], [true], [[true, 0, false]])
}

_CPT_KnownSequenceSecondAttempt() {
	_CPT_AssertFirstFence(501, false, [501, 501], [false, true],
		[[false, 1, true], [true, 2, false]])
}

_CPT_UnfencedZeroThenObservable() {
	_CPT_AssertFirstFence(0, true, [0, 777], [false, true],
		[[false, 1, true], [true, 1, false]])
}

_CPT_UnfencedZeroImmediateLegacyControl() {
	; This preserves the existing fallback; zero is not an ownership proof.
	_CPT_AssertFirstFence(0, true, [0], [true], [[true, 1, false]])
}

_CPT_KnownSequenceZeroObservation() {
	_CPT_AssertFirstFence(501, false, [0, 777], [true],
		[[false, 0, true], [true, 0, false]])
}

_CPT_SequenceThrowRetainsDebt() {
	_CPT_AssertFirstFence(0, true, ["throw_sequence", 777], [true],
		[[false, 0, true], [true, 0, false]])
}

_CPT_RestoreThrowRetainsDebt() {
	_CPT_AssertFirstFence(501, false, [501, 501], ["throw_restore", true],
		[[false, 1, true], [true, 2, false]])
}

_CPT_FirstRetirementKeepsCallerOwner() {
	_CPT_AssertFirstFence(501, false, [777], [true], [[true, 0, false]], false)
}

Test("clipboard: unfenced first attempt yields to positive observable sequence (clipboard-first-restore-fence)",
	_CPT_FirstUnfencedPositive)
Test("clipboard: known matching sequence restores the exact snapshot (clipboard-first-restore-fence)",
	_CPT_FirstKnownMatching)
Test("clipboard: known foreign sequence retires without restoration (clipboard-first-restore-fence)",
	_CPT_FirstKnownForeign)
Test("clipboard: matching second attempt preserves debt identity (clipboard-first-restore-fence)",
	_CPT_KnownSequenceSecondAttempt)
Test("clipboard: blocked zero-sequence restore yields on second observation (clipboard-first-restore-fence)",
	_CPT_UnfencedZeroThenObservable)
Test("clipboard: immediate forced zero retains existing unfenced behavior (clipboard-first-restore-fence)",
	_CPT_UnfencedZeroImmediateLegacyControl)
Test("clipboard: zero observation cannot authorize a known-sequence restore (clipboard-first-restore-fence)",
	_CPT_KnownSequenceZeroObservation)
Test("clipboard: sequence refusal retains debt before observable retirement (clipboard-first-restore-fence)",
	_CPT_SequenceThrowRetainsDebt)
Test("clipboard: restore refusal retains snapshot until matching retry (clipboard-first-restore-fence)",
	_CPT_RestoreThrowRetainsDebt)
Test("clipboard: caller-owned token survives explicit debt-only retirement (clipboard-first-restore-fence)",
	_CPT_FirstRetirementKeepsCallerOwner)

; The shortcut lives in a conditional hotkey include. Run both unchanged entry
; definitions and the complete real ownership registry in one owned native
; child; only clipboard contents, the active-app query and sends are passive.
_PPH_Script(Entry, Mode) {
	Source := FileRead(_DriverDir . "\adapters\clipboard.ahk", "UTF-8")
	Boundary := _DriverFindFunctionDefinition(&Source, "CB_Read")
	AssertTrue(IsObject(Boundary), "the real clipboard registry must precede its OS read adapter")
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`nOnError(_PPH_Error)`n" . SubStr(Source, 1, Boundary.Idx - 1)
	Code .= '_PPH_Error(Err, *) {`nFileAppend(Err.Message, "**")`nExitApp(1)`n}`n'
	for Name in ["GesturePastePlain", "_GesturePastePlainRestore", "PasteWithoutFormatting", "_PasteWithoutFormattingRestore"]
		Code .= _DriverFuncBody(Name) . "`n"
	Code .= 'global SEND_INSTANT_PASTE_DELAY_MS := ' . SEND_INSTANT_PASTE_DELAY_MS . "`n"
	Code .= 'global S := Map("text", "genuine copy", "rich", true, "seq", 42, "reads", 0, "saves", 0, "writes", 0, "restores", 0, "warnings", 0, "errors", 0, "sent", [], "sent_text", [], "active_at_send", 0, "excel", false, "fail_save", false)`n'
	Code .= 'CB_Read() {`nglobal S`nS["reads"] += 1`nreturn S["text"]`n}`n'
	Code .= 'CB_SaveAll() {`nglobal S`nS["saves"] += 1`nreturn S["fail_save"] ? "__CB_SAVE_ERROR__" : Map("text", S["text"], "rich", S["rich"])`n}`n'
	Code .= 'CB_Write(Text) {`nglobal S`nS["writes"] += 1`nS["text"] := Text`nS["rich"] := false`nS["seq"] += 1`nreturn true`n}`n'
	Code .= 'CB_RestoreAll(Saved) {`nglobal S`nS["restores"] += 1`nS["text"] := Saved["text"]`nS["rich"] := Saved["rich"]`nS["seq"] += 1`nreturn true`n}`n'
	Code .= 'CB_GetSequenceNumber() {`nglobal S`nreturn S["seq"]`n}`n'
	Code .= 'WinActive(*) {`nglobal S`nreturn S["excel"]`n}`n'
	Code .= 'SendFinalResult(Keys) {`nglobal S`nS["sent"].Push(Keys)`nS["sent_text"].Push(S["text"])`nS["active_at_send"] := CBClipboardOwner.active.Count`nreturn true`n}`n'
	Code .= 'LoggerWarn(*) {`nglobal S`nS["warnings"] += 1`n}`nLoggerError(*) {`nglobal S`nS["errors"] += 1`n}`nLoggerDebug(*) => 0`n'
	Code .= 'Check(Condition, Message) {`nif !Condition`nthrow Error(Message)`n}`n'
	Code .= 'Mode := "' . Mode . '"`nBusy := InStr(Mode, "busy-") == 1`nOtherToken := 0`n'
	Code .= 'if Busy {`nOtherToken := CB_TryBeginOwnedTransaction("other temporary producer")`nCheck(OtherToken > 0, "contender setup")`nOtherRecord := CBClipboardOwner.active[OtherToken]`nS["text"] := Mode == "busy-clear" ? "" : Mode == "busy-external" ? "new external copy" : "temporary payload"`nS["seq"] := Mode == "busy-external" ? 77 : 42`n}`n'
	Code .= 'S["excel"] := Mode == "excel" or Mode == "busy-excel"`nS["fail_save"] := Mode == "snapshot-failure"`nif Mode == "non-text"`nS["text"] := ""`nBefore := S["text"]`n'
	Code .= Entry . "()`n"
	Code .= 'if Busy {`nCheck(S["sent"].Length == 0, "busy plain paste must emit no key, including native fallbacks")`nCheck(S["reads"] == 0 && S["saves"] == 0 && S["writes"] == 0 && S["restores"] == 0, "busy plain paste must not inspect or mutate another owner")`nCheck(S["text"] == Before, "temporary or externally replaced payload must survive")`nCheck(CBClipboardOwner.active.Count == 1 && CBClipboardOwner.active[OtherToken] == OtherRecord, "exact other owner remains live")`nCheck(S["warnings"] == 1, "busy refusal must be explicit")`nCB_EndOwnedTransaction(OtherToken)`n} else {`n'
	Code .= 'Check(S["sent"].Length == 1, "normal paste must emit once")`nCheck(S["sent"][1] == (Mode == "excel" ? "^+v" : "^v"), "native paste chord")`nCheck(S["sent_text"][1] == Before, "normal paste payload")`nCheck(S["active_at_send"] == 1, "native fallback must retain its exact owner through emission")`n'
	Code .= 'if Mode == "text" {`nCheck(S["writes"] == 1, "plain text coercion")`nCheck(CBClipboardOwner.active.Count == 1, "deferred restore owns the snapshot")`nStarted := A_TickCount`nwhile CBClipboardOwner.active.Count && A_TickCount - Started < 2000`nSleep(10)`nCheck(S["restores"] == 1, "native timer restores through actual debt coordinator")`n} else {`nCheck(S["writes"] == 0 && S["restores"] == 0, "native bypass must preserve formats")`nCheck(S["saves"] == (Mode == "snapshot-failure" ? 1 : 0), "only failed snapshot fallback attempts a save")`n}`nCheck(S["text"] == Before && S["rich"], "original clipboard formats must survive")`n}`n'
	Code .= 'Check(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.restore_debt, "all exact owners retire")`nCheck(S["errors"] == 0, "no hidden failure may be accepted")`nFileAppend("plain-paste-ok", "*")`nExitApp(0)`n'
	return Code
}

_PPH_Completed(State, Code, Output, ErrorText) {
	State.Code := Code
	State.Output := Output
	State.ErrorText := ErrorText
	State.Calls += 1
}

_PPH_ActualPlainPaste(Entry, Mode) {
	Script := A_Temp . "\ergopti_plain_paste_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".ahk"
	AssertFalse(FileExist(Script))
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PPH_Script(Entry, Mode)) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }
	Handle := 0
	Primary := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], _PPH_Completed.Bind(State))
		AssertTrue(Handle.start())
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 5000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the exact native fixture must settle")
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("plain-paste-ok", State.Output)
		AssertEqual("", State.ErrorText)
	} catch as Err {
		Primary := Err
	}
	Retired := false
	try Retired := !IsObject(Handle) || ((Result := Handle.terminate()) is Integer && Result == 1)
	catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	if Retired {
		try FileDelete(Script)
		catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "retain the source until its exact native tree retires")
}

for Entry in ["GesturePastePlain", "PasteWithoutFormatting"] {
	for Mode in ["busy-text", "busy-clear", "busy-external", "busy-excel", "text", "non-text", "excel", "snapshot-failure"] {
		Test("clipboard: actual " . Entry . " respects " . Mode . " (plain-paste-owner-refusal)",
			_PPH_ActualPlainPaste.Bind(Entry, Mode))
	}
}

#Include test_clipboardall_external_lock.ahk
