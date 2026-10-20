; tests/unit/adapters/crash_report/test_screenshot_clipboard_admission.ahk

; Native bitmap admission must precede the first clipboard mutation. The domain
; cases retire the real screenshot owner and copy actual foreign text at the
; snapshot or publication boundary, without replacing clipboard restoration.

_GSCA_Admission(Record) {
	Record["admission_calls"] += 1
	try {
		AssertTrue(A_IsCritical > 0, "admission must be evaluated inside the native publication critical section")
		AssertEqual(A_ScriptHwnd, DllCall("User32\GetOpenClipboardWindow", "Ptr"),
			"the real clipboard lock must already exclude another process")
		AssertEqual(Record["before_sequence"], CB_GetSequenceNumber(), "admission must precede EmptyClipboard")
		AssertEqual(Record["before_mutation"], CBClipboardOwner.mutation_id,
			"refusal must not reserve an owned clipboard notification")
	} catch as Err {
		Record["admission_error"] := Err
		throw Err
	}
	switch Record["decision"] {
		case "true": return 1
		case "false": return 0
		case "two": return 2
		case "string": return "true"
		case "throw": throw Error("fixture bitmap admission refusal")
	}
	throw Error("Unknown bitmap admission decision")
}

_GSCA_AdapterPublish(Record, Stage, Args*) {
	Allowed := Record["decision"] == "true"
	if !Allowed {
		AssertTrue(CB_Write(Record["foreign_text"]))
		Record["foreign_sequence"] := CB_GetSequenceNumber()
	}
	Record["before_sequence"] := CB_GetSequenceNumber()
	Record["before_mutation"] := CBClipboardOwner.mutation_id
	Published := CB_WriteBitmapFile(Stage, &Sequence, _GSCA_Admission.Bind(Record))
	Record["receipt"] := Map("published", Published, "sequence", Sequence)
	Record["sequence_after_publish"] := CB_GetSequenceNumber()
	Record["clipboard_owner"] := DllCall("User32\GetClipboardOwner", "Ptr")
	if Record.Has("admission_error")
		throw Record["admission_error"]
	AssertEqual(1, Record["admission_calls"], "the loaded native bitmap must reach admission exactly once")
	AssertEqual(Allowed, Published, "only the canonical Integer1 admission may publish")
	AssertEqual(0, DllCall("User32\GetOpenClipboardWindow", "Ptr"), "refusal and success must both release the actual lock")
	if Allowed {
		AssertTrue(Sequence > 0 && Sequence == Record["sequence_after_publish"],
			"a current admitted bitmap retains its authenticated post-close receipt")
		AssertEqual(Record["before_mutation"] + 1, CBClipboardOwner.mutation_id)
	} else {
		AssertEqual(0, Sequence, "refused admission cannot claim clipboard mutation")
		AssertEqual(Record["before_sequence"], CB_GetSequenceNumber(), "refusal preserves the actual foreign sequence")
		AssertEqual(Record["before_mutation"], CBClipboardOwner.mutation_id, "refusal leaves the mutation ledger untouched")
	}
	return Record["receipt"]
}

_GSCA_ConfigureAdapter(Decision, Record) {
	Record["decision"] := Decision
	Record["admission_calls"] := 0
	GestureScreenshotWorkerState.publish_clipboard_fn := _GSCA_AdapterPublish.Bind(Record)
	; The adapter, rather than this fixture's setup, must acquire Critical.
	Critical("Off")
}

_GSCA_AdapterCase(Decision) {
	_GSCP_Case(Decision == "true" ? "owned-success" : "foreign-cancel", _GSCA_ConfigureAdapter.Bind(Decision))
}

_GSCA_SaveAndRevoke(Record) {
	Saved := CB_SaveAll()
	AssertFalse(Saved is String && Saved == "__CB_SAVE_ERROR__", "the actual opaque snapshot must succeed before revocation")
	AssertTrue(CB_Write(Record["foreign_text"]))
	Record["foreign_sequence"] := CB_GetSequenceNumber()
	AssertTrue(GestureDirectCaptureFinish(1, false, "snapshot admission fixture cancellation"),
		"the actual retained screenshot must be retired before publication")
	return Saved
}

_GSCA_RevokeBeforePublish(Record, Stage, Args*) {
	AssertTrue(CB_Write(Record["foreign_text"]))
	Record["foreign_sequence"] := CB_GetSequenceNumber()
	AssertTrue(GestureDirectCaptureFinish(1, false, "loaded admission fixture cancellation"))
	; Variadic forwarding also permits the original one-argument producer. The
	; pre-fix snapshot case therefore fails through mutation, never wrong arity.
	Receipt := _GestureScreenshotDefaultPublishClipboard(Stage, Args*)
	Record["receipt"] := Receipt
	Record["sequence_after_publish"] := CB_GetSequenceNumber()
	Record["clipboard_owner"] := DllCall("User32\GetClipboardOwner", "Ptr")
	return Receipt
}

_GSCA_ConfigureDomain(Mode, Record) {
	GestureScreenshotWorkerState.publish_clipboard_fn := 0
	if Mode == "snapshot"
		GestureScreenshotWorkerState.clipboard_save_fn := _GSCA_SaveAndRevoke.Bind(Record)
	else if Mode == "publication"
		GestureScreenshotWorkerState.publish_clipboard_fn := _GSCA_RevokeBeforePublish.Bind(Record)
	Critical("Off")
}

_GSCA_DomainCase(Mode) {
	_GSCP_Case(Mode == "current" ? "owned-success" : "foreign-cancel", _GSCA_ConfigureDomain.Bind(Mode))
}

for _GSCA_Decision in ["true", "false", "two", "string", "throw"]
	Test("screenshot clipboard admission: native " . _GSCA_Decision . " decision precedes mutation (screenshot-clipboard-admission)",
		_GSCA_AdapterCase.Bind(_GSCA_Decision))
for _GSCA_Mode in ["snapshot", "publication", "current"]
	Test("screenshot clipboard admission: " . _GSCA_Mode . " retains the exact direct owner (screenshot-clipboard-admission)",
		_GSCA_DomainCase.Bind(_GSCA_Mode))
