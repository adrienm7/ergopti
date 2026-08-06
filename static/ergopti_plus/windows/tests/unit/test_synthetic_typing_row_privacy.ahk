; tests/unit/test_synthetic_typing_row_privacy.ahk

; ==============================================================================
; MODULE: Regression — the TYPING row must not carry an expansion the fired-
;         hotstring row redacts (personal-info-typing-row-leak)
; DESCRIPTION:
; The first pass at the personal-info leak redacted the ``hotstring`` row and
; stopped there. The secret went out anyway: same file, roughly 90 ms earlier,
; different row. The keylogger's InputHook observes the driver's OWN injected
; expansion — that is the entire reason KL_MarkSynthetic exists — and
; KL_Hook_OnChar pushed every character of it into Keylogger.buffer_events and
; Keylogger.buffer_text unconditionally. The synthetic branch TAGGED the
; character (s=1, st="hotstring") while the two lines that persist its CONTENT
; ran outside any guard.
;
; The ordering makes it worse rather than better: KL_LogHotstring calls
; KL_FlushBuffer BEFORE writing its own redacted row, so a single call published
; the plaintext and then the redaction of the same value.
;
; ROOT CAUSE ENCODED: "synthetic" answers WHERE a character came from, and was
; mistaken for an answer to WHETHER it may be persisted. The fix gives
; KL_MarkSynthetic the privacy flag the fire paths already hold and routes both
; sinks through KL_Hook_RecordedChar — the shape Linux's recorded_char(char,
; is_private) has had all along, against a sink macOS had already closed.
;
; WHY THESE ASSERTIONS AND NOT A ROW THE TEST BUILDS ITSELF: the previous test
; asserted on the Map handed to KL_AppendLog by KL_LogHotstring and nothing
; else, while tests/test_stubs.ahk replaces KL_FlushBuffer — the very call that
; publishes the leaking row — with a counter. So this file drives the REAL
; KL_Hook_OnChar / KL_Hook_OnKeyDown (modules/keylogger/keylogger_hook.ahk
; declares classes and functions only, so the headless runner can load it) and
; reads back Keylogger.buffer_text and Keylogger.buffer_events, which ARE the
; persisted row's "text" and "events": KL_FlushBuffer snapshots both without
; transforming either, and section 4 pins exactly that so the seam cannot
; quietly stop being the row.
; ==============================================================================

#Requires AutoHotkey v2.0

; Real-shaped but nobody's data — a leak is a leak whether or not it validates.
global _STRP_IBAN := "FR7630006000011234567890189"

; Runs Body against a clean typing buffer on an "initialised" keylogger
; (KL_Hook_OnChar early-returns otherwise, and a test that silently exercised
; nothing would pass against the leaking code), then RETURNS what the buffer
; holds — the assertions read that snapshot, not the live fields, because every
; field this touches is restored on the way out so no later test inherits a
; driver stuck mid-expansion.
; @param Body {Func} Drives the hook callbacks.
; @return {Object} { text, events } exactly as KL_FlushBuffer would snapshot them.
_STRP_WithCleanBuffer(Body) {
	PrevInit    := Keylogger.initialized
	PrevEvents  := Keylogger.buffer_events
	PrevText    := Keylogger.buffer_text
	PrevDepth   := Keylogger.synth_active
	PrevType    := Keylogger.synth_type
	PrevPrivate := Keylogger.synth_private
	Keylogger.initialized   := true
	Keylogger.buffer_events := []
	Keylogger.buffer_text   := ""
	Keylogger.synth_active  := 0
	Keylogger.synth_type    := "none"
	Keylogger.synth_private := false
	Captured := { text: "", events: [] }
	try {
		Body()
		Captured := { text: Keylogger.buffer_text, events: Keylogger.buffer_events }
	} finally {
		Keylogger.initialized   := PrevInit
		Keylogger.buffer_events := PrevEvents
		Keylogger.buffer_text   := PrevText
		Keylogger.synth_active  := PrevDepth
		Keylogger.synth_type    := PrevType
		Keylogger.synth_private := PrevPrivate
	}
	return Captured
}

; Types Text through the REAL OnChar callback one character at a time, exactly
; as the OS delivers the driver's own send burst back to the InputHook.
_STRP_TypeThroughHook(Text) {
	Loop Parse Text {
		KL_Hook_OnChar(0, A_LoopField)
	}
}

; Every character the ``events`` column would persist, concatenated. That row is
; an array of [char, delay, meta] triples and the leak lives in position 1 of
; each, so a check against the text column alone would see half of it.
_STRP_EventChars(Row) {
	Out := ""
	for _, Ev in Row.events {
		Out .= Ev[1]
	}
	return Out
}

; True when Haystack contains ANY single character of Needle. Stronger than
; asserting the whole secret is absent: a redaction that kept every third digit
; would satisfy an InStr on the full string.
_STRP_SharesAnyChar(Haystack, Needle) {
	Loop Parse Needle {
		if InStr(Haystack, A_LoopField)
			return true
	}
	return false
}

; The source line starting at Pos, without running past the end of the body.
_STRP_LineAt(Body, Pos) {
	NlPos := InStr(Body, "`n", , Pos)
	return NlPos ? SubStr(Body, Pos, NlPos - Pos) : SubStr(Body, Pos)
}





; ===================================================================
; ===================================================================
; ======= 1/ A private expansion leaves nothing in the buffer =======
; ===================================================================
; ===================================================================

_STRP_DrivePrivateExpansion() {
	global _STRP_IBAN
	KL_MarkSynthetic("hotstring", true)
	_STRP_TypeThroughHook(_STRP_IBAN)
	KL_ClearSynthetic()
}

_STRP_PrivateExpansionIsNotRecorded() {
	global _STRP_IBAN, PI_MASK_FALLBACK_CHAR
	Row := _STRP_WithCleanBuffer(_STRP_DrivePrivateExpansion)

	Assert(!InStr(Row.text, _STRP_IBAN),
		"the typing row's text field must not carry the expansion: it reaches the same today.log as the hotstring row, is ingested into the metrics store, replicated to every device and kept fourteen days")
	Assert(!_STRP_SharesAnyChar(Row.text, _STRP_IBAN),
		"and not one CHARACTER of it either — this sink is per character, so a redaction that leaks per character has to be caught per character")
	Assert(!_STRP_SharesAnyChar(_STRP_EventChars(Row), _STRP_IBAN),
		"the events column is the SECOND place every character is written, and the one the n-gram walker reads. Redacting the text column alone leaves the value in the log one column across — the same two-sink trap the hotstring row's tag field was")

	; The metric survives the redaction, which is why the substitution is
	; length-preserving rather than a drop. These are also what makes a run that
	; recorded NOTHING fail: every assertion above is an absence, and an absence
	; over an empty buffer is green for the wrong reason.
	AssertEqual(StrLen(_STRP_IBAN), StrLen(Row.text),
		"the redaction preserves length: the row's own arithmetic is StrLen-based, and shortening it would trade a privacy bug for a metrics bug")
	AssertEqual(StrLen(_STRP_IBAN), Row.events.Length,
		"one event per typed character still reaches the row — the keystrokes happened and the driver still has to account for them")
	AssertEqual(PI_MASK_FALLBACK_CHAR, SubStr(Row.text, 1, 1),
		"and what it keeps is the shared mask character, not a redaction this module invented for itself")
}
Test("keylogger: a private expansion writes no character of itself into the typing row (personal-info-typing-row-leak)",
	_STRP_PrivateExpansionIsNotRecorded)


_STRP_DriveOrdinaryExpansion() {
	KL_MarkSynthetic("hotstring", false)
	_STRP_TypeThroughHook("par exemple")
	KL_ClearSynthetic()
}

_STRP_DriveManualTyping() {
	_STRP_TypeThroughHook("bonjour")
}

; The other half, twice over. A guard that redacted every synthetic keystroke
; would satisfy section 1 while deleting the n-gram corpus the hotstring source
; histogram is built from; one that redacted everything would delete the typing
; log outright.
_STRP_OrdinaryTypingIsRecordedVerbatim() {
	Manual := _STRP_WithCleanBuffer(_STRP_DriveManualTyping)
	AssertEqual("bonjour", Manual.text,
		"manual typing is recorded verbatim — the guard must narrow the sink, not close it")
	AssertEqual("bonjour", _STRP_EventChars(Manual),
		"in the events column too")

	Public := _STRP_WithCleanBuffer(_STRP_DriveOrdinaryExpansion)
	AssertEqual("par exemple", Public.text,
		"and an ORDINARY expansion is still recorded verbatim: synthetic says where the characters came from, never that they are secret. Conflating the two is what made this leak look guarded")
	AssertEqual(1, Public.events[1][3]["s"],
		"while still being tagged synthetic, so the manual chars count is unaffected")
}
Test("keylogger: ordinary typing and ordinary expansions stay verbatim (personal-info-typing-row-leak)",
	_STRP_OrdinaryTypingIsRecordedVerbatim)


_STRP_DriveOverlappingFires() {
	global _STRP_IBAN
	KL_MarkSynthetic("hotstring", true)
	KL_MarkSynthetic("hotstring", false)
	KL_ClearSynthetic()
	_STRP_TypeThroughHook(_STRP_IBAN)
	KL_ClearSynthetic()
}

; The latch is released by the LAST holder, not the first. Overlapping fires are
; why synth_active is a depth counter at all; a flag released by the outer public
; fire would un-redact the inner private one mid-burst.
_STRP_OverlappingFiresFailClosed() {
	global _STRP_IBAN
	Row := _STRP_WithCleanBuffer(_STRP_DriveOverlappingFires)
	AssertEqual(StrLen(_STRP_IBAN), StrLen(Row.text),
		"the burst must actually have been recorded — an absence assertion over an empty buffer is green for the wrong reason")
	Assert(!_STRP_SharesAnyChar(Row.text, _STRP_IBAN),
		"a public fire released while a private one is still typing must not un-redact it — the conservative answer costs an n-gram, the other one costs the secret")
}
Test("keylogger: the privacy latch survives an overlapping public fire (personal-info-typing-row-leak)",
	_STRP_OverlappingFiresFailClosed)


_STRP_DrivePrivateBackspace() {
	KL_MarkSynthetic("hotstring", true)
	KL_Hook_OnKeyDown(0, 0x08, 14)
	KL_ClearSynthetic()
}

; Bracket markers are the exception Linux states for [BS], and it holds for the
; whole KLHOOK_SPECIAL set: they carry no content, and rewriting them would
; desynchronise the walker's deletion accounting against the events it counts.
_STRP_BracketMarkersSurviveRedaction() {
	Row := _STRP_WithCleanBuffer(_STRP_DrivePrivateBackspace)
	AssertEqual(1, Row.events.Length,
		"the backspace still reaches the row")
	AssertEqual("[BS]", Row.events[1][1],
		"a bracket marker is recorded unchanged even under redaction: it holds none of the secret, and an expansion's own erase count is what the walker nets out of the hotstring characters")
}
Test("keylogger: bracket markers survive the private-expansion redaction (personal-info-typing-row-leak)",
	_STRP_BracketMarkersSurviveRedaction)





; =========================================================
; =========================================================
; ======= 2/ The fire paths actually raise the flag =======
; =========================================================
; =========================================================

; Section 1 proves the mechanism works when told. This proves it IS told — by
; every path that types an expansion. Source-level because each of the three
; needs a live Spec, a running InputHook and an OS that accepts SendInput.
_STRP_EveryFirePathForwardsTheFlag() {
	Match := _DriverFuncBody("HSE_DispatchMatch")
	Assert(RegExMatch(Match, 'KL_MarkSynthetic\("hotstring",[ \t]*Spec\.'),
		"HSE_DispatchMatch — the path every InputHook fire takes — must hand KL_MarkSynthetic the Spec's privacy flag, or the burst it is about to type lands in the typing row verbatim")

	Raw := _DriverFuncBody("_HSE_DispatchRawCallback")
	Assert(RegExMatch(Raw, 'KL_MarkSynthetic\("hotstring",[ \t]*Spec\.'),
		"the raw-callback path must forward it too: it is a fire like any other, and a marker applied to two paths out of three is the shape this driver keeps repeating")

	Legacy := _DriverFuncBody("_HotstringDispatch")
	Assert(RegExMatch(Legacy, 'KL_MarkSynthetic\("hotstring",[ \t]*IsPrivate\)'),
		"and the end-char dispatch path, which already carries IsPrivate to its own KL_LogHotstring call, must pass the same value here")
}
Test("meta keylogger: every hotstring fire path forwards the privacy flag to the keylogger (personal-info-typing-row-leak)",
	_STRP_EveryFirePathForwardsTheFlag)





; ======================================================
; ======================================================
; ======= 3/ The diagnostic logs carry no secret =======
; ======================================================
; ======================================================

; This one needs no user action at all. HotPath_LogIfSlow logs at WARNING, which
; is ABOVE the default INFO level, so its detail reaches
; <ConfigDir>/autohotkey/logs/ErgoptiPlus_<date>.log — fourteen-day retention —
; on any slow dispatch, unlike the DEBUG sites which at least need the level
; switched on. The guard added by the first fix sat eighteen lines BELOW it.
_STRP_SlowDispatchWarningWithholdsTheTrigger() {
	Body := _DriverFuncBody("_OnPrefixChar")
	DispatchPos := InStr(Body, 'HotPath_LogIfSlow("HSE.Dispatch"')
	Assert(DispatchPos > 0,
		"the slow-dispatch profiler line must still exist — a diagnostic someone relies on gets its argument redacted, not deleted")

	FlagPos := InStr(Body, "HotstringIsPrivate :=")
	Assert(FlagPos > 0 and FlagPos < DispatchPos,
		"the privacy flag must be resolved BEFORE the profiler line, not after it: read afterwards it cannot redact the argument it exists to guard")

	Call := SubStr(Body, DispatchPos, 260)
	Assert(InStr(Call, "PersonalInfoRedactForLog"),
		"and the trigger handed to the profiler must go through the shared redaction — '@iban' names which secret the line is about, which is why the fire row withholds the trigger as well as the replacement")
}
Test("meta hotstrings: the slow-dispatch WARNING withholds a private trigger (personal-info-typing-row-leak)",
	_STRP_SlowDispatchWarningWithholdsTheTrigger)


; The DEBUG sites print the BUFFERS, and after a star fire the watcher takes the
; engine's buffer verbatim — so the buffer holds the resolved IBAN rather than
; the six characters the user typed, and _LookupAndRender prints it without
; another keystroke ever being pressed.
_STRP_DebugBufferPrintsAreGuarded() {
	Guarded := 0
	for _, FnName in ["_OnPrefixChar", "_PrefixAppendTypedChar", "_LookupAndRender"] {
		Body := _DriverFuncBody(FnName)
		Pos := 1
		while (Pos := InStr(Body, "LoggerDebug(", , Pos)) {
			Line := _STRP_LineAt(Body, Pos)
			Pos += 1
			if !InStr(Line, "_PrefixBuffer") and !InStr(Line, "HSE_Buffer") and !InStr(Line, "PrefixSnapshot")
				continue
			Guarded += 1
			Assert(InStr(Line, "_PrefixLogSafe("),
				FnName . ": a DEBUG line that interpolates a keystroke buffer must route it through _PrefixLogSafe — after a private fire that buffer IS the resolved value, and DEBUG is exactly the level a user is asked to switch on when reporting a bug")
		}
	}
	Assert(Guarded >= 4,
		"the four known buffer-printing DEBUG sites must all have been reached: a filter that matches nothing turns every assertion above it into a no-op that still reads green")
}
Test("meta hotstrings: every DEBUG line that prints a keystroke buffer redacts private residue (personal-info-typing-row-leak)",
	_STRP_DebugBufferPrintsAreGuarded)


; And the residue latch has to be raised where the value actually enters the
; buffers — on the fire, for BOTH fire shapes, since the end-char branch wipes
; the preview buffer but leaves the engine's holding the replacement.
_STRP_ResidueLatchIsRaisedOnAPrivateFire() {
	Body := _DriverFuncBody("_OnPrefixChar")
	Assert(RegExMatch(Body, "_HseFired and HotstringIsPrivate"),
		"_OnPrefixChar must raise _PrefixPrivateResidue when a private expansion actually fired — a latch nothing sets makes every guard above it a no-op that still reads like a fix")

	Safe := _DriverFuncBody("_PrefixLogSafe")
	Assert(InStr(Safe, "PersonalInfoRedactForLog"),
		"and _PrefixLogSafe must redact through the shared helper rather than truncating or blanking, so the diagnostic keeps the length it is diagnosed by")
}
Test("meta hotstrings: a private fire raises the buffer-residue latch (personal-info-typing-row-leak)",
	_STRP_ResidueLatchIsRaisedOnAPrivateFire)





; ================================================================
; ================================================================
; ======= 4/ The buffer really is the persisted typing row =======
; ================================================================
; ================================================================

; Section 1 asserts on Keylogger.buffer_text / buffer_events because
; tests/test_stubs.ahk replaces KL_FlushBuffer (the rest of
; modules/keylogger/keylogger.ahk installs OS hooks at load and cannot be
; included headless). That is a valid seam only for as long as the flush copies
; those two fields into the row untransformed — so that is asserted here, from
; the real source, rather than assumed. If this test fails, section 1 has
; stopped testing the persisted row and must be re-pointed, never relaxed.
_STRP_FlushPersistsTheBufferVerbatim() {
	Body := _DriverFuncBody("KL_FlushBuffer")
	Assert(RegExMatch(Body, "snap_text[ \t]*:=[ \t]*Keylogger\.buffer_text"),
		"KL_FlushBuffer must snapshot Keylogger.buffer_text — the field this file asserts on")
	Assert(RegExMatch(Body, "snap_events[ \t]*:=[ \t]*Keylogger\.buffer_events"),
		"and Keylogger.buffer_events likewise")
	Assert(RegExMatch(Body, '"text",[ \t]*snap_text'),
		"and write that snapshot into the row's text field with nothing in between — a transformation here would mean the redaction is asserted one step away from what is persisted")
	Assert(RegExMatch(Body, '"events",[ \t]*snap_events'),
		"and into its events field the same way")
}
Test("meta keylogger: the typing buffer is persisted into the typing row verbatim (personal-info-typing-row-leak)",
	_STRP_FlushPersistsTheBufferVerbatim)





; ============================================================
; ============================================================
; ======= 5/ The cache round-trip preserves the marker =======
; ============================================================
; ============================================================

; Nothing routes the @ family through the cache today, which is exactly why an
; option dropped here would be found late — by a user, in a log. The registrar
; rebuilt its options Map from scratch and forwarded one hand-named key.
_STRP_CacheForwardsEveryExtraOption() {
	global _HS_CACHE_ROWS, HSE_RegistryByGroup, HS_CACHE_MARKER
	PrevRows := _HS_CACHE_ROWS
	; [flags, trigger, output, finalResult, isRepeat, isCaseSens, priority]
	_HS_CACHE_ROWS := Map("testpriv.section",
		[["*", "@zz" . HS_CACHE_MARKER, "SECRET", true, false, true, ""]])
	HSE_RegistryClear()
	try {
		_HsCacheRegisterSection("testpriv.section", { TimeActivationSeconds: 0 },
			Map("OnlyText", False).Set("IsPrivate", True), 10)
		; The engine derives the toggle group from the row's Category.Section, so
		; a cached registration lands under its own key, never "default".
		Assert(HSE_RegistryByGroup.Has("testpriv.section"), "the cached row must register at all")
		Specs := HSE_RegistryByGroup["testpriv.section"]
		AssertEqual(1, Specs.Length, "exactly one spec")
		Assert(Specs[1].HasOwnProp("IsPrivate") and Specs[1].IsPrivate,
			"a section registered from the CACHE must keep IsPrivate. The registrar rebuilt its options from scratch and forwarded only OnlyText, so the marker that keeps an IBAN out of a fourteen-day log would be dropped by any entry that ever round-tripped through here")
		Assert(Specs[1].HasOwnProp("OnlyText") and !Specs[1].OnlyText,
			"and still forward the option it always did — the fix is to stop naming keys one by one, not to change which one is named")
	} finally {
		HSE_RegistryClear()
		_HS_CACHE_ROWS := PrevRows
	}
}
Test("hotstrings: the cache registrar forwards every caller option, IsPrivate included (personal-info-typing-row-leak)",
	_STRP_CacheForwardsEveryExtraOption)


; The cache reproduces the runtime TOML path 1:1, so the two forward the same
; way or the "fallback" quietly means something else.
_STRP_BothRegistrarsForwardTheSameWay() {
	for _, FnName in ["_HsCacheRegisterSection", "LoadHotstringsSection"] {
		Body := _DriverFuncBody(FnName)
		Assert(InStr(Body, "ExtraOptions.Clone()"),
			FnName . " must start from a copy of the caller's options instead of naming the keys worth forwarding — an enumerated list is a list somebody has to remember to extend, and the one nobody extended was the privacy marker")
		Assert(!RegExMatch(Body, 'Has\("OnlyText"\)'),
			FnName . " must no longer special-case OnlyText: the hand-picked forward IS the defect, and leaving it beside the copy invites the next option to be hand-picked too")
	}
}
Test("meta hotstrings: both hotstring registrars forward caller options wholesale (personal-info-typing-row-leak)",
	_STRP_BothRegistrarsForwardTheSameWay)





; ================================================================
; ================================================================
; ======= 6/ The ROI half-life map is not keyed on bullets =======
; ================================================================
; ================================================================

; The first fix handed KL_Roi_OnHotstring the REDACTED trigger under a comment
; claiming it "only ever needs net_saved". It does not: it stores the trigger as
; a key of trigger_last_use, and KL_Roi_HalflifeTick writes that key back out
; into a trigger_halflife row. Keyed on the redaction, @cb★, @cc★ and @ss★ all
; collapse onto the same four bullets, and one of them firing keeps the other
; two looking fresh forever.
_STRP_PrivateFireIsNotKeyedInTheHalflifeMap() {
	global _Stub_AppendLogRows, _Stub_RoiHotstringCalls, _Stub_WpmPushCalls, _Stub_FlushBufferCalls
	PrevInit := Keylogger.initialized
	_Stub_AppendLogRows := []
	_Stub_RoiHotstringCalls := []
	_Stub_WpmPushCalls := []
	_Stub_FlushBufferCalls := 0
	Keylogger.initialized := true
	try {
		KL_LogHotstring("@iban" . Chr(0x2605), "FR7630006000011234567890189",
			"personal", "", "dynamic", "personal_info", true)
	} finally {
		Keylogger.initialized := PrevInit
	}
	AssertEqual(1, _Stub_RoiHotstringCalls.Length,
		"the ROI accumulator is still called — the saving is real and the user earned it")
	Assert(_Stub_RoiHotstringCalls[1].is_private,
		"and it is TOLD that the trigger it received is a redaction, so it can skip the half-life map instead of merging every private mapping of the same length onto one entry")

	Body := _DriverFuncBody("KL_Roi_OnHotstring")
	Assert(RegExMatch(Body, "if !is_private[\r\n\t ]+KLRoi\.trigger_last_use"),
		"KL_Roi_OnHotstring must skip trigger_last_use for a private mapping: its keys are triggers, a redaction is not a trigger, and KL_Roi_HalflifeTick writes those keys straight back out into a persisted row")
	Assert(RegExMatch(Body, "session_saved_chars[ \t]*\+="),
		"while still accumulating the savings — dropping the metric would be the wrong fix here for exactly the reason it would be at the sink")
}
Test("keylogger: a private fire feeds the ROI savings but never keys the half-life map (personal-info-typing-row-leak)",
	_STRP_PrivateFireIsNotKeyedInTheHalflifeMap)
