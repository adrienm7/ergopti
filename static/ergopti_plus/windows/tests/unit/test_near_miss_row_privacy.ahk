; tests/unit/test_near_miss_row_privacy.ahk

; ==============================================================================
; MODULE: Regression — the near-miss row is the one trigger sink that had no
;         privacy concept at all (near-miss-row-unguarded)
; DESCRIPTION:
; _CheckNearMiss writes a PERSISTED row — it reaches today.log, the metrics store
; and every replicated device — carrying BOTH columns of a mapping: the trigger
; the user typed by hand, and the replacement they did not get. Every sibling
; sink learned to read IsPrivate during the personal-info work; this one was
; never touched, because it was never on the list. It was found by DERIVING the
; sink list from the source instead of recalling it, which is also why
; tools/test/test-personal-info-log-sinks-are-judged.cjs now exists.
;
; ROOT CAUSE ENCODED: withholding must be WHOLE. Redacting the trigger and
; keeping the replacement leaves the IBAN in the row one column to the right,
; which is exactly the mistake the suggested/dismissed pair was fixed for. So the
; assertion is that NOTHING reaches KL_AppendLog, not that the trigger changed.
;
; HONEST SCOPE: today _TriggerSet is built only by _AddTriggerToIndex, which sets
; no IsPrivate property, and the personal-info family reaches the preview through
; a separate PROVIDER that never enters _TriggerSet — so no private entry can
; arrive here as the code stands. These tests pin the guard against the
; registration change that would make it live, and pin the other half too: a
; guard that withheld everything would silently end the near-miss analytics, and
; a suite that only checked the private case would report green over that.
; ==============================================================================

#Requires AutoHotkey v2.0

; A trigger long enough to clear the >= 2 length floor in _CheckNearMiss, and a
; replacement standing in for the secret. Real-shaped, nobody's data.
global _NMRP_TRIGGER := "iban"
global _NMRP_SECRET  := "FR7630006000011234567890189"





; ==========================
; ==========================
; ======= 1/ Harness =======
; ==========================
; ==========================

; Runs Body against a _TriggerSet holding exactly one entry, with the keylogger
; "initialised" so _CheckNearMiss does not early-return — a test that exercised
; nothing would pass against the unguarded code. Restores both afterwards so no
; later test observes a one-entry index or an initialised keylogger.
_NMRP_WithTriggerSet(Entry, Body) {
	global _TriggerSet, _Stub_AppendLogRows, _NMRP_TRIGGER
	PrevSet := _TriggerSet
	PrevInit := Keylogger.initialized
	_Stub_AppendLogRows := []
	_TriggerSet := Map(_NMRP_TRIGGER, Entry)
	Keylogger.initialized := true
	try {
		Body()
	} finally {
		_TriggerSet := PrevSet
		Keylogger.initialized := PrevInit
	}
}

; Concatenates every value of every recorded row, so the secret is hunted across
; ALL fields at once — including any added later. Checking only the two fields we
; happen to know about is how the sibling sink's leak survived its first fix.
_NMRP_AllRowText() {
	global _Stub_AppendLogRows
	Text := ""
	for _, Row in _Stub_AppendLogRows {
		for Key, Val in Row {
			Text .= Key . "=" . (Val is String ? Val : String(Val)) . "`n"
		}
	}
	return Text
}





; =============================================================
; =============================================================
; ======= 2/ A private entry produces no row whatsoever =======
; =============================================================
; =============================================================

; The exact-match arm: the user typed a known trigger by hand instead of letting
; it expand. This is the arm that fires most often in practice.
_NMRP_PrivateExactMatchWritesNothing() {
	global _NMRP_TRIGGER, _NMRP_SECRET, _Stub_AppendLogRows
	Entry := { Trigger: _NMRP_TRIGGER, Output: _NMRP_SECRET,
	           Category: "personal", IsPrivate: true }
	_NMRP_WithTriggerSet(Entry, () => _CheckNearMiss(_NMRP_TRIGGER))
	AssertEqual(0, _Stub_AppendLogRows.Length,
		"a private mapping must be withheld WHOLE — a row that redacts the trigger still carries the replacement, and the replacement IS the secret")
	Assert(!InStr(_NMRP_AllRowText(), _NMRP_SECRET),
		"the replacement reached a persisted field — withholding must cover every column of the row, not the trigger alone")
}
Test("near-miss: a private exact match writes no row at all (near-miss-row-unguarded)",
	_NMRP_PrivateExactMatchWritesNothing)


; The edit-distance arm reaches the same sink by a DIFFERENT call site, so a
; guard placed on only one of the two leaves the other writing the row.
_NMRP_PrivateEditDistanceWritesNothing() {
	global _NMRP_TRIGGER, _NMRP_SECRET, _Stub_AppendLogRows
	Entry := { Trigger: _NMRP_TRIGGER, Output: _NMRP_SECRET,
	           Category: "personal", IsPrivate: true }
	; "ibam" is one substitution away from "iban" — the edit-distance arm.
	_NMRP_WithTriggerSet(Entry, () => _CheckNearMiss("ibam"))
	AssertEqual(0, _Stub_AppendLogRows.Length,
		"the edit-distance arm is a SECOND call site into KL_LogHotstringNearMiss; guarding only the exact-match arm leaves this one writing the row")
}
Test("near-miss: a private edit-distance-1 match writes no row either (near-miss-row-unguarded)",
	_NMRP_PrivateEditDistanceWritesNothing)





; ===================================================================
; ===================================================================
; ======= 3/ And the analytics must survive for everyone else =======
; ===================================================================
; ===================================================================

; The other half of the contract. A guard that returned early unconditionally
; would pass every assertion above while silently ending the near-miss analytics
; for the whole corpus — a privacy fix traded for a metrics bug, which is the
; trade macOS explicitly refused on the sibling sink.
_NMRP_OrdinaryEntryStillWritesItsRow() {
	global _NMRP_TRIGGER, _Stub_AppendLogRows
	Entry := { Trigger: _NMRP_TRIGGER, Output: "International Bank Account Number",
	           Category: "abbreviations", IsPrivate: false }
	_NMRP_WithTriggerSet(Entry, () => _CheckNearMiss(_NMRP_TRIGGER))
	AssertEqual(1, _Stub_AppendLogRows.Length,
		"the guard must withhold private mappings only — withholding everything ends the near-miss analytics while every assertion about privacy still passes")
	AssertEqual("manual_typed_known_trigger", _Stub_AppendLogRows[1]["type"],
		"the row that survives must be the real near-miss record, not a placeholder")
	AssertEqual(_NMRP_TRIGGER, _Stub_AppendLogRows[1]["trigger"],
		"a non-private trigger is not redacted: the analytics exist to name which trigger was missed")
}
Test("near-miss: a non-private entry still writes its row (guard must narrow the sink, not close it)",
	_NMRP_OrdinaryEntryStillWritesItsRow)


; _TriggerSet entries built by _AddTriggerToIndex have no IsPrivate property at
; all — HasOwnProp is false, not false-valued. A guard written as `Entry.IsPrivate`
; would throw here on EVERY ordinary near-miss, turning a privacy fix into an
; exception on the deferred typing path.
_NMRP_MissingPropertyIsTreatedAsPublic() {
	global _NMRP_TRIGGER, _Stub_AppendLogRows
	Entry := { Trigger: _NMRP_TRIGGER, Output: "International Bank Account Number",
	           Category: "abbreviations" }
	_NMRP_WithTriggerSet(Entry, () => _CheckNearMiss(_NMRP_TRIGGER))
	AssertEqual(1, _Stub_AppendLogRows.Length,
		"the index shape carries NO IsPrivate property — reading it without HasOwnProp throws, and every ordinary near-miss takes this path")
}
Test("near-miss: an entry with no IsPrivate property is public, not an exception",
	_NMRP_MissingPropertyIsTreatedAsPublic)
