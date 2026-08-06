; tests/unit/test_hotstring_fire_log_privacy.ahk

; ==============================================================================
; MODULE: Regression — a fired personal-info hotstring must not be written to
;         the metrics log (personal-info-fire-log-leak)
; DESCRIPTION:
; Firing @iban★ wrote the user's IBAN into today.log. So did @cb★ (credit card),
; @ss★ (social-security number), every generated @-combo, and the phone / SSN /
; IBAN prefix triggers — whose replacement is a callable the funnel already
; blanks, but whose TRIGGER is literally the first digits of the number.
;
; ROOT CAUSE ENCODED: the personal-info registrations carried no privacy marker
; at all, so nothing downstream could tell an IBAN from an abbreviation. Windows
; was the only one of the three drivers with no is_private concept on this path:
; macOS (modules/keymap/expander.lua) skips both of its sinks for a private
; mapping "including the trigger, which is itself a fragment of the secret", and
; Linux (modules/keylogger/keylogger.lua) substitutes a placeholder per
; character. The marker now rides the Spec from CreateHotstring through the
; three fire paths into KL_LogHotstring.
;
; WHY THE ROW AND NOT A RETURN VALUE: the sink writes the replacement TWICE —
; once as the "replacement" field and once inside the "tag" marker — so a fix
; that redacts the obvious field and forgets the marker leaves the value in the
; log, one column to the right. These tests read back the Map that reaches
; KL_AppendLog and check every field of it.
;
; AND THE COUNTERS MUST SURVIVE: the WPM widget and the ROI accumulator need
; LENGTHS, not text. Skipping the call outright would trade a privacy bug for a
; metrics bug, which is why macOS forwards its flag rather than returning early
; where a metric still has to move.
; ==============================================================================

#Requires AutoHotkey v2.0

; The vectors under test. Real-shaped but nobody's data: a leak is a leak
; whether or not the digits check out.
global _HFLP_IBAN    := "FR7630006000011234567890189"
global _HFLP_TRIGGER := "@iban" . Chr(0x2605)

; Runs Body with the keylogger "initialised" (KL_LogHotstring early-returns
; otherwise, and a test that silently exercised nothing would pass against the
; leaking code) and every recording stub emptied. Restores the flag afterwards
; so no other test observes an initialised keylogger.
_HFLP_WithRecordingSink(Body) {
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls, _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	PrevInit := Keylogger.initialized
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	Keylogger.initialized := true
	try {
		Body()
	} finally {
		Keylogger.initialized := PrevInit
	}
}

; The single recorded row, with a clear failure when the sink was never reached.
_HFLP_OnlyRow() {
	global _Stub_AppendLogRows
	AssertEqual(1, _Stub_AppendLogRows.Length,
		"exactly one row must reach KL_AppendLog — zero means the sink was never exercised and every assertion on its content would be vacuous")
	return _Stub_AppendLogRows[1]
}

; Concatenates every value of the recorded row so a leak can be hunted across
; ALL fields at once, including ones added later. Field-by-field assertions miss
; the field nobody thought of; this one cannot.
_HFLP_RowText(Row) {
	Text := ""
	for Key, Val in Row {
		Text .= Key . "=" . (Val is String ? Val : String(Val)) . "`n"
	}
	return Text
}

; Occurrences of a needle in a haystack. Used to count registration sites in
; driver source, where the assertion is "all of them", not "at least one".
_HFLP_CountOccurrences(Haystack, Needle) {
	Count := 0
	Pos := 1
	while (Pos := InStr(Haystack, Needle, , Pos)) {
		Count += 1
		Pos += 1
	}
	return Count
}





; ==========================================================
; ==========================================================
; ======= 1/ A private fire leaves no content behind =======
; ==========================================================
; ==========================================================

_HFLP_PrivateRowCarriesNoSecret() {
	global _HFLP_IBAN, _HFLP_TRIGGER
	_HFLP_WithRecordingSink(() => KL_LogHotstring(_HFLP_TRIGGER, _HFLP_IBAN, "personal", "", "dynamic", "personal_info", true))
	Row := _HFLP_OnlyRow()
	Text := _HFLP_RowText(Row)

	Assert(!InStr(Text, _HFLP_IBAN),
		"the resolved replacement is the user's IBAN and must appear in NO field of the persisted row. today.log is ingested into the metrics store, replicated to every other device and kept for fourteen days")
	Assert(!InStr(Text, "iban"),
		"nor may the @-tag trigger survive: '@iban' tells any reader of the log exactly which secret followed it, so the trigger is withheld with the replacement — this is the contract macOS states verbatim")
	Assert(!InStr(Text, Chr(0x2605)),
		"the magic key belongs to the withheld trigger too; leaving it turns the redaction into a shape the trigger can be read off")

	; The trap a naive fix falls into: the replacement is written twice.
	Assert(Row.Has("tag"), "the row must still carry its tag marker")
	Assert(!InStr(Row["tag"], _HFLP_IBAN),
		"the tag field is the SECOND place the replacement is written. Redacting the replacement field and leaving this one intact leaves the IBAN in the log in full, one column to the right")
	Assert(!InStr(Row["replacement"], _HFLP_IBAN),
		"and the replacement field itself carries none of it")
	Assert(!InStr(Row["trigger"], "iban"),
		"and the trigger field carries none of the trigger")
}
Test("keylogger: a private hotstring fire writes no secret to the metrics row (personal-info-fire-log-leak)",
	_HFLP_PrivateRowCarriesNoSecret)


; The other half. A fix that redacts everything is not a fix — it would satisfy
; every assertion above while silently deleting the metric the log exists for.
_HFLP_OrdinaryRowIsUnchanged() {
	_HFLP_WithRecordingSink(() => KL_LogHotstring("pex", "par exemple", "endchar", "", "magickey", "abbreviations"))
	Row := _HFLP_OnlyRow()
	AssertEqual("pex", Row["trigger"],
		"an ordinary fire still records its trigger verbatim")
	AssertEqual("par exemple", Row["replacement"],
		"and its replacement verbatim — the privacy guard must narrow the sink, not close it")
	AssertEqual("<hotstring>par exemple</hotstring>", Row["tag"],
		"and its tag marker is untouched, exactly as the macOS row is")
	AssertEqual("hotstring", Row["type"], "the row type is unchanged")
	AssertEqual(StrLen("par exemple") - StrLen("pex"), Row["net_saved_chars"],
		"and the saved-character arithmetic is unchanged")
}
Test("keylogger: an ordinary hotstring fire is recorded verbatim (personal-info-fire-log-leak)",
	_HFLP_OrdinaryRowIsUnchanged)





; ==========================================
; ==========================================
; ======= 2/ The counters still move =======
; ==========================================
; ==========================================

; Losing the metric would be the wrong fix. macOS forwards is_private rather
; than skipping the call wherever a counter still has to move, because the
; alternative leaves the user's saved-keystroke total quietly wrong.
_HFLP_PrivateFireStillCountsSavedKeystrokes() {
	global _HFLP_IBAN, _HFLP_TRIGGER, _Stub_RoiHotstringCalls, _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	_HFLP_WithRecordingSink(() => KL_LogHotstring(_HFLP_TRIGGER, _HFLP_IBAN, "personal", "", "dynamic", "personal_info", true))
	Row := _HFLP_OnlyRow()
	Expected := StrLen(_HFLP_IBAN) - StrLen(_HFLP_TRIGGER)

	AssertEqual(Expected, Row["net_saved_chars"],
		"a private expansion saved exactly as many keystrokes as a public one, and that saving is why the user runs this driver — redacting the text must not zero the arithmetic")
	AssertEqual(1, _Stub_RoiHotstringCalls.Length,
		"the ROI accumulator must still be fed")
	AssertEqual(Expected, _Stub_RoiHotstringCalls[1].net_saved,
		"with the same saving, computed from the real lengths rather than the redacted ones")
	Assert(!InStr(_Stub_RoiHotstringCalls[1].trigger, "iban"),
		"but the trigger it keys on is redacted too — KL_Roi_OnHotstring stores that key and only ever needs the number")
	AssertEqual(StrLen(_HFLP_IBAN), _Stub_WpmPushCalls.Length,
		"and the WPM widget still gets one push per replacement character: it measures typing speed from lengths and never reads the text")
	AssertEqual(1, _Stub_FlushBufferCalls,
		"the typing buffer is still flushed first, so the fire stays ordered after the characters that produced it")
}
Test("keylogger: a private hotstring fire still counts the keystrokes it saved (personal-info-fire-log-leak)",
	_HFLP_PrivateFireStillCountsSavedKeystrokes)





; ====================================================
; ====================================================
; ======= 3/ The marker survives the fire path =======
; ====================================================
; ====================================================

; Requirement one of the fix: the registrations must carry a marker at all, and
; it must land on the Spec the fire paths read. Asserting on the queue or the
; sink alone would pass with the option silently dropped at registration.
_HFLP_OptionReachesTheRegisteredSpec() {
	global HSE_RegistryByGroup, _HFLP_IBAN
	HSE_RegistryClear()
	try {
		CreateHotstring("*", "@iban" . Chr(0x2605), _HFLP_IBAN,
			Map("OnlyText", False).Set("FinalResult", True).Set("IsPrivate", True))
		CreateHotstring("*", "pex" . Chr(0x2605), "par exemple", Map("FinalResult", True))
		Assert(HSE_RegistryByGroup.Has("default"), "both registrations must land in the registry")
		Specs := HSE_RegistryByGroup["default"]
		AssertEqual(2, Specs.Length, "one spec each")
		Assert(Specs[1].HasOwnProp("IsPrivate") and Specs[1].IsPrivate,
			"CreateHotstring must carry an IsPrivate option through to the Spec. The fire paths see a matched Spec and a typed buffer, never the personal_info field the value came from, so a marker that does not survive registration cannot be honoured anywhere downstream")
		Assert(Specs[2].HasOwnProp("IsPrivate") and !Specs[2].IsPrivate,
			"and an ordinary registration must come out NOT private — a marker that is always on redacts the whole corpus")
	} finally {
		HSE_RegistryClear()
	}
}
Test("hotstrings: the IsPrivate registration option reaches the Spec (personal-info-fire-log-leak)",
	_HFLP_OptionReachesTheRegisteredSpec)


; And the wiring in between: the funnel every fire path shares must carry the
; flag onto its record and the drain must hand it to the sink. This is the join
; a fix applied only at the sink, or only at the funnel, gets wrong.
_HFLP_QueueAndDrainCarryTheFlag() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled, _HFLP_IBAN, _HFLP_TRIGGER
	PrevQueue := _HSE_FireLogQueue
	PrevScheduled := _HSE_FireLogScheduled
	_HSE_FireLogQueue := []
	; Declared already armed so this leaves no live timer behind in the runner.
	_HSE_FireLogScheduled := true
	try {
		_HSE_QueueFireLog(_HFLP_TRIGGER, _HFLP_IBAN, "personal", "dynamic", "personal_info", true)
		AssertEqual(1, _HSE_FireLogQueue.Length, "the fire must reach the queue at all")
		Assert(_HSE_FireLogQueue[1].HasOwnProp("IsPrivate") and _HSE_FireLogQueue[1].IsPrivate,
			"the queued record must carry the privacy flag: the drain runs a thread turn later and cannot look it up again")

		_HFLP_WithRecordingSink(() => _HSE_DrainFireLog())
		Row := _HFLP_OnlyRow()
		Assert(!InStr(_HFLP_RowText(Row), _HFLP_IBAN),
			"and the drain must hand the flag to KL_LogHotstring — this is the end-to-end path a real @iban fire takes, and the one place a fix applied at only one end still leaks")
		Assert(!InStr(_HFLP_RowText(Row), "iban"),
			"trigger included")
	} finally {
		_HSE_FireLogQueue := PrevQueue
		_HSE_FireLogScheduled := PrevScheduled
	}
}
Test("hotstrings: the fire-log queue and drain carry the privacy flag to the sink (personal-info-fire-log-leak)",
	_HFLP_QueueAndDrainCarryTheFlag)





; ===============================================================
; ===============================================================
; ======= 4/ Every personal registration carries the flag =======
; ===============================================================
; ===============================================================

; The behavioural tests above prove the mechanism works. This one proves it is
; APPLIED to the whole class — the @-family and its sibling, the phone / SSN /
; IBAN prefix triggers, whose trigger is a fragment of the number even though
; their replacement is a callable the funnel blanks. Source-level because both
; registration sites need Features, PersonalInformation and a resolved magic key
; that the headless runner has no business building.
_HFLP_EveryPersonalRegistrationIsMarked() {
	; _DriverFuncBody strips full-line comments, so prose mentioning the option
	; cannot inflate the count below.
	Expansion := _DriverFuncBody("_HS_RegisterTextExpansionAndDynamic")
	; Count the CreateHotstring calls that resolve a personal_info value, then
	; require that many privacy markers — rather than asserting a fixed number,
	; which is a hand-written total and rots exactly like a hand-written list.
	; It rotted here already: this read 3 while the hand-listed long combos
	; (CreateHotstringComboAuto) existed, and went stale the moment they were
	; replaced by the fire-time resolver.
	Producers := _HFLP_CountOccurrences(Expansion, 'CreateHotstring("*"')
	Assert(Producers > 0,
		"_HS_RegisterTextExpansionAndDynamic must still register @ triggers — zero producers means this scan is broken and every count below it is vacuous")
	AssertEqual(Producers, _HFLP_CountOccurrences(Expansion, '"IsPrivate", True'),
		"every personal-info REGISTRATION site must set IsPrivate. Marking all but one is the shape this driver keeps repeating — the missed site expands the same secrets into the same log")

	; The fire-time resolver is the fourth producer and is not a registration, so
	; the count above cannot see it. It carries the same obligation for a stronger
	; reason: every field it can reach comes out of personal_info.toml, so its
	; replacement is the user's data unconditionally.
	Resolver := _DriverFuncBody("HSE_TryPersonalInfoCombo")
	Assert(Resolver != "",
		"infra/hotstrings/hotstring_engine_main.ahk must define HSE_TryPersonalInfoCombo — it is what expands every multi-letter @-combo now")
	Assert(InStr(Resolver, "IsPrivate:   true") > 0 or InStr(Resolver, "IsPrivate: true") > 0,
		"the fire-time @-combo resolver must mark its transient Spec private: it resolves arbitrary letter combinations of the user's own fields, so it leaks MORE than any single registration it replaced")

	Dynamic := _DriverFuncBody("_DynHS_RegisterAll")
	Assert(InStr(Dynamic, "IsPrivate") > 0,
		"the phone / SSN / IBAN prefix triggers must be marked private too: their trigger IS the first digits of the number, so the row leaks even though the callable replacement is blanked")
	; Every registration in the phone/SSN/IBAN block takes the marked options
	; Map; the three date triggers keep the unmarked one, because a date is not a
	; secret and a marker applied to everything protects nothing.
	AssertEqual(10, _HFLP_CountOccurrences(Dynamic, "_DynPrivateOpts)"),
		"every phone, SSN and IBAN prefix registration must take the private options Map — one missed call re-opens the leak for that trigger alone")
	AssertEqual(3, _HFLP_CountOccurrences(Dynamic, "_DynOpts)"),
		"and the three date registrations must keep the ordinary one, or the guard above stops distinguishing anything")
}
Test("meta hotstrings: every personal-info registration carries the privacy marker (personal-info-fire-log-leak)",
	_HFLP_EveryPersonalRegistrationIsMarked)
