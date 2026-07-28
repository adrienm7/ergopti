; tests/meta/test_altgr_callbacks_serialized.ahk

; ==============================================================================
; MODULE: Regression — every AltGr callback emits under the same serialization
;         contract (altgr-callbacks-serialized)
; DESCRIPTION:
; SendMode is "Event" driver-wide because the hotstring cascade depends on it,
; which means every remapped key re-sends its character through a NON-atomic,
; interruptible SendEvent. Two fast keys can therefore start overlapping remap
; threads whose injections interleave in the single OS input queue and come out
; reordered — "comme" typed, "cmooe" produced. Critical("On") around each emit
; is what prevents it.
;
; ROOT CAUSE ENCODED: AltGrShiftDispatch applies that Critical to every base-row
; AltGr callback, but the two roll handlers are registered STRAIGHT onto
; Hotkey() by _RegisterRollsAltGrHotkeys and never pass through the dispatcher.
; So the very same callbacks — WrapTextIfSelected, SendNewResult — ran
; serialized when reached from a base row and bare when reached from a roll. One
; function, two concurrency contracts, decided by which key the user pressed.
;
; This is the only confirmed race in the driver: everywhere else the
; single-threaded argument holds, and here it does not, because AHK's
; A_MaxThreads permits the overlap and #MaxThreadsPerHotkey only blocks re-entry
; of the SAME key.
;
; The guard is written over the registration table rather than over the two
; handlers that were found, so a third directly-registered AltGr hotkey cannot
; inherit the bare contract by default.
;
; SCOPE: source-level. These handlers are hotkey callbacks that emit through the
; OS input queue and cannot be exercised headlessly.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ The dispatcher still serializes ==============
; ==================================================================
; ==================================================================

; Everything below compares against this contract, so it has to be real. If the
; dispatcher ever stopped taking Critical, the handlers would match a contract
; that no longer protects anything.
_ACS_DispatcherSerializes() {
	Body := _DriverFuncBody("AltGrShiftDispatch")
	Assert(Body != "", "AltGrShiftDispatch() must exist in the driver source")
	Assert(InStr(Body, 'Critical("On")') > 0,
		"AltGrShiftDispatch must serialize its callback — SendMode Event makes every emit interruptible, and two overlapping remap threads interleave in the single OS input queue and reorder the output")
	Assert(InStr(Body, "finally") > 0,
		"the dispatcher must restore the caller's Critical state in a finally, or a throwing callback leaves the whole message pump uninterruptible")
}




; ==================================================================
; ==================================================================
; ======= 2/ Every directly-registered AltGr hotkey too ============
; ==================================================================
; ==================================================================

; Callback names bound by _RegisterRollsAltGrHotkeys — the registrations that
; bypass AltGrShiftDispatch entirely. Read from source so a third one added
; later is covered without touching this test.
_ACS_DirectlyRegisteredCallbacks() {
	Body := _DriverFuncBody("_RegisterRollsAltGrHotkeys")
	Names := []
	if (Body == "")
		return Names
	Pos := 1
	while (F := RegExMatch(Body, 'Hotkey\(\s*"[^"]*"\s*,\s*([A-Za-z_]\w*)', &M, Pos)) {
		Pos := F + M.Len
		Names.Push(M[1])
	}
	return Names
}

_ACS_DirectRegistrationsSerializeToo() {
	Names := _ACS_DirectlyRegisteredCallbacks()
	; Non-vacuity floor: the chevron/equal and hashtag/quote rolls are both
	; registered here. A scan that matched nothing would pass silently.
	Assert(Names.Length >= 2,
		"the scan must reach the directly-registered AltGr hotkeys (found only " . Names.Length . ") — a scan that matches nothing cannot fail")

	for Name in Names {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Assert(InStr(Body, 'Critical("On")') > 0,
			Name . " is registered directly with Hotkey() and so never passes through AltGrShiftDispatch, which is where every other AltGr callback gets its Critical. Without its own, the emit primitives it shares with the base rows run serialized on one registration and bare on this one, and the bare SendEvent can interleave with a neighbouring remapped key and reorder the output")
		Assert(InStr(Body, "finally") > 0,
			Name . " must restore the previous Critical state in a finally, matching the dispatcher — an early return or a throw would otherwise leave the message pump uninterruptible")
	}
}

; The emit helper the roll handlers share must keep its own Critical: the outer
; wrap above serializes the handler, but AddRollEqual and HashtagOrQuote are
; also reachable on their own.
_ACS_RollEmitKeepsItsOwnCritical() {
	Body := _DriverFuncBody("_RollEmitCritical")
	Assert(Body != "", "_RollEmitCritical() must exist in the driver source")
	Assert(InStr(Body, 'Critical("On")') > 0,
		"the roll emit primitive must serialize on its own account — the handler-level wrap protects the handler path, not every future caller")
	Assert(InStr(Body, "finally") > 0,
		"_RollEmitCritical must restore the caller's Critical state in a finally")
}


Test("meta altgr-callbacks-serialized: the dispatcher still serializes",
	_ACS_DispatcherSerializes)
Test("meta altgr-callbacks-serialized: directly-registered AltGr hotkeys serialize too",
	_ACS_DirectRegistrationsSerializeToo)
Test("meta altgr-callbacks-serialized: the roll emit keeps its own Critical",
	_ACS_RollEmitKeepsItsOwnCritical)
