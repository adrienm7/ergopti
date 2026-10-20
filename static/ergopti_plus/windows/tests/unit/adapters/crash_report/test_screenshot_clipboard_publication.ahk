; tests/unit/adapters/crash_report/test_screenshot_clipboard_publication.ahk

; Exercise the actual bitmap publisher and all-formats rollback. The scheduling
; wrapper performs a genuine foreign copy at the unlocked return boundary;
; neither clipboard sequences nor restoration results are mocked.

_GSCP_Publish(Record, Stage, Args*) {
	Receipt := _GestureScreenshotDefaultPublishClipboard(Stage, Args*)
	Record["receipt"] := Receipt
	Record["sequence_after_publish"] := CB_GetSequenceNumber()
	Record["clipboard_owner"] := DllCall("User32\GetClipboardOwner", "Ptr")
	Mode := Record["mode"]
	if InStr(Mode, "foreign") {
		if Mode == "foreign-image"
			AssertTrue(CB_WriteBitmapFile(Record["foreign_bitmap"]))
		else
			AssertTrue(CB_Write(Record["foreign_text"]))
		Record["foreign_sequence"] := CB_GetSequenceNumber()
		AssertTrue(Record["foreign_sequence"] > 0)
	}
	if Mode == "foreign-cancel" || Mode == "owned-cancel"
		GestureDirectCaptureFinish(1, false, "clipboard publication fixture cancellation")
	return Receipt
}

_GSCP_Case(Mode, Configure := 0) {
	global _GestureDirectCaptures, _GSWO_Terminals
	PreviousCritical := Critical("On"), WasSuspended := A_IsSuspended
	Old := _GSWO_Install()
	Stem := A_Temp . "\ergopti_clipboard_publication_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Stage := Stem . "_owned.bmp", ForeignBitmap := Stem . "_foreign.bmp"
	Original := 0, SnapshotTaken := false, Primary := 0, SavedClipboard := 0
	try {
		AssertFalse(CBClipboardOwner.restore_debt is Map, "the fixture must not inherit another owner's restore debt")
		AssertEqual(0, CBClipboardOwner.active.Count, "the native fixture refuses another live clipboard owner")
		AssertEqual(0, CBClipboardOwner.paste_transaction, "the native fixture refuses another paste slot")
		ActiveBefore := CBClipboardOwner.active.Count
		SavedClipboard := {Generation: CBClipboardOwner.generation, MutationId: CBClipboardOwner.mutation_id,
			Pending: CBClipboardOwner.pending, Observer: CBClipboardOwner.observer_active,
			Settle: CBClipboardOwner.settle_hook}
		CBClipboardOwner.pending := []
		CBClipboardOwner.observer_active := false
		CBClipboardOwner.settle_hook := 0
		Original := CB_SaveAll()
		AssertFalse(Type(Original) == "String" && Original == "__CB_SAVE_ERROR__")
		SnapshotTaken := true
		if A_IsSuspended
			Suspend(false)
		AssertTrue(CB_Write("original clipboard publication fixture"))
		if Mode == "foreign-failure" || Mode == "owned-failure" {
			FileAppend("This is not a BMP.", Stage, "UTF-8-RAW")
		} else
			_GSQ_WriteBitmap(Stage, 255, 0)
		_GSQ_WriteBitmap(ForeignBitmap, 0, 255)
		Record := Map("mode", Mode, "foreign_bitmap", ForeignBitmap,
			"foreign_text", "foreign clipboard publication fixture")
		GestureScreenshotWorkerState.file_exists_fn := 0
		GestureScreenshotWorkerState.publish_clipboard_fn := _GSCP_Publish.Bind(Record)
		GestureScreenshotWorkerState.clipboard_save_fn := 0
		GestureScreenshotWorkerState.clipboard_restore_fn := 0
		GestureScreenshotWorkerState.clipboard_sequence_fn := 0
		GestureScreenshotWorkerState.clipboard_has_image_fn := 0
		_GestureDirectCaptures[1] := Map("worker_id", 1, "mode", "clipboard", "path", "",
			"started_tick", A_TickCount, "timeout_ms", 60000, "callback", _GSWO_RecordTerminal)
		Job := Map("stage", Stage, "cancel_requested", false)
		Record["job"] := Job
		if HasMethod(Configure, "Call")
			Configure.Call(Record)
		GestureDirectCaptureWorkerDone(1, 1, Job, 0, "", "")
		Receipt := Record.Get("receipt", Map())
		Diagnostic := " / mode=" . Mode . " receipt=" . Receipt.Get("sequence", 0)
			. " afterPublish=" . Record.Get("sequence_after_publish", 0)
			. " current=" . CB_GetSequenceNumber() . " owner=" . Record.Get("clipboard_owner", 0)
		AssertEqual(1, _GSWO_Terminals.Length, "the real direct owner must settle exactly once" . Diagnostic)
		AssertEqual(Mode == "owned-success", _GSWO_Terminals[1]["ok"],
			"a later foreign copy cannot authorize the original screenshot's success" . Diagnostic)
		if InStr(Mode, "foreign") {
			AssertEqual(Record["foreign_sequence"], CB_GetSequenceNumber(),
				"rollback must never replace the genuine foreign clipboard copy")
			if Mode == "foreign-image"
				AssertTrue(CB_HasImage(), "the foreign bitmap must survive the failed admission")
			else
				AssertEqual(Record["foreign_text"], CB_Read(), "the exact foreign text must survive")
		} else if Mode == "owned-success" {
			AssertTrue(CB_HasImage(), "the admitted bitmap must remain published")
		} else
			AssertEqual("original clipboard publication fixture", CB_Read(),
				"owned cancellation restores the snapshot and an unmutated failure preserves it" . Diagnostic)
		AssertEqual(ActiveBefore, CBClipboardOwner.active.Count, "every real clipboard owner must retire")
		AssertFalse(CBClipboardOwner.restore_debt is Map, "no fixture debt may escape the completed rollback")
	} catch as Err {
		Primary := Err
	} finally {
		Critical("On")
		try {
			if _GestureDirectCaptures.Has(1)
				GestureDirectCaptureFinish(1, false, "clipboard publication fixture cleanup")
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if IsObject(SavedClipboard) {
				OwnedTokens := []
				for Token, Owner in CBClipboardOwner.active
					if Token > SavedClipboard.Generation && Owner["source"] == "gesture_direct_screenshot"
						OwnedTokens.Push(Token)
				for Token in OwnedTokens {
					if CB_HasRestoreDebtForOwner(Token) {
						Started := A_TickCount
						while CB_HasRestoreDebtForOwner(Token) && TickElapsed(Started) < 2000 {
							CB_RetryRestoreDebt()
							Sleep(10)
						}
						; Detach only this fixture's failed debt after recording the
						; failure. Its separate incoming snapshot is restored below.
						if CB_HasRestoreDebtForOwner(Token) {
							Debt := CBClipboardOwner.restore_debt
							_CB_SettleRestoreDebt(Debt)
							throw Error("The native fixture could not retire its exact restore debt.")
						}
					}
					CB_EndOwnedTransaction(Token)
				}
			}
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try _GSWO_Restore(Old)
		catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if SnapshotTaken
				AssertTrue(CB_RestoreAll(Original), "the native fixture must restore its incoming clipboard")
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		for Path in [Stage, ForeignBitmap] {
			try {
				if FileExist(Path)
					FileDelete(Path)
			} catch as Err {
				if !IsObject(Primary)
					Primary := Err
			}
		}
		try {
			if A_IsSuspended != WasSuspended
				Suspend(WasSuspended)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if IsObject(SavedClipboard) {
				CBClipboardOwner.pending := SavedClipboard.Pending
				CBClipboardOwner.observer_active := SavedClipboard.Observer
				CBClipboardOwner.mutation_id := SavedClipboard.MutationId
				CBClipboardOwner.generation := SavedClipboard.Generation
				CBClipboardOwner.settle_hook := SavedClipboard.Settle
			}
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try Critical(PreviousCritical)
		catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
	}
	if IsObject(Primary)
		throw Primary
}

for _GSCP_Mode in ["foreign-cancel", "foreign-failure", "foreign-image", "owned-cancel", "owned-failure", "owned-success"]
	Test("screenshot clipboard publication: " . _GSCP_Mode . " retains exact mutation custody (screenshot-clipboard-publication-custody)",
		_GSCP_Case.Bind(_GSCP_Mode))

#Include test_screenshot_clipboard_admission.ahk
