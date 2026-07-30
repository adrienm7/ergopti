; static/ergopti_plus/windows/tests/unit/test_build_inserts_covers_emitted_types.ahk

; ==============================================================================
; MODULE: Regression — every emitted metrics event must survive ingest
;         (build-inserts-covers-emitted-types)
; DESCRIPTION:
; `llm_generation_failed` exists to answer one question: are predictions
; silently dropping? It was itself silently dropped. KL_LogLlmFailed wrote it to
; today.log, KL_BuildInserts had no case for it, control reached the default
; "unknown type — skip; return []", and it never appeared in data.sql or on the
; dashboard.
;
; ROOT CAUSE ENCODED: the ingest switch and the emitters are two lists that must
; agree, and nothing checked that they did. The default branch is deliberately
; permissive — a future schema may replay an unknown type — so a MISSING case is
; indistinguishable from a deliberately-ignored one, and adding an emitter
; without its case produces no error anywhere.
;
; The macOS twin routes this event to events_system; the AHK port never mirrored
; that. A naive route into events_llm would fail differently: that table's CHECK
; constraint does not admit a failure kind, so the insert would be rejected
; rather than skipped.
;
; The guard is written as an enumeration over the EMITTERS rather than a check
; of the one type that was found, so the next event class added to the keylogger
; cannot inherit the same silent drop.
;
; SCOPE: behavioural — KL_BuildInserts is a pure function of the event Map and
; is in the headless runner's include graph.
; ==============================================================================

#Requires AutoHotkey v2.0

; Type literals that are NOT metrics event types and must be excluded from the
; enumeration, with the reason each is spelled that way in the source:
;   llm_       — a prefix fragment concatenated with a variant suffix, never an
;                event type on its own.
;   shortcut   — a per-keystroke classification stored INSIDE a typing event's
;                payload, not a standalone row.
global _BICE_NOT_EVENT_TYPES := ["llm_", "shortcut"]





; ==================================================================
; ==================================================================
; ======= 1/ Every emitted type produces at least one insert =======
; ==================================================================
; ==================================================================

; Event type literals as the keylogger actually emits them.
_BICE_EmittedTypes() {
	global _BICE_NOT_EVENT_TYPES
	Src := _StripFullLineComments(_DriverDirConcat("modules/keylogger"))
	Types := Map()
	Pos := 1
	while (F := RegExMatch(Src, '"type",\s*"([a-z_]+)"', &M, Pos)) {
		Pos := F + M.Len
		Name := M[1]
		Skip := false
		for Excluded in _BICE_NOT_EVENT_TYPES
			if (Excluded == Name)
				Skip := true
		if !Skip
			Types[Name] := true
	}
	return Types
}

; A minimal but well-formed event of the given type. KL_BuildInserts reads
; timestamp unconditionally, so it must be present for every type.
_BICE_Event(EventType) {
	return Map(
		"type", EventType,
		"timestamp", "2026-07-21T12:00:00",
		"app", "TestApp",
		"action", EventType,
		"predictions", []
	)
}

_BICE_EveryEmittedTypeIsIngested() {
	Types := _BICE_EmittedTypes()
	Count := 0
	for _, _ in Types
		Count++
	; Non-vacuity floor: the keylogger emits well over half a dozen distinct
	; classes. A scan that matched nothing would pass every assertion below.
	Assert(Count >= 6,
		"the scan must reach the keylogger's real event emitters (found only " . Count . " type(s)) — a scan that matches nothing cannot fail")

	for EventType, _ in Types {
		Inserts := ""
		try {
			Inserts := KL_BuildInserts(_BICE_Event(EventType))
		} catch as Err {
			Assert(false,
				"KL_BuildInserts threw on the emitted type '" . EventType . "': " . Err.Message)
		}
		Assert(IsObject(Inserts) and Inserts.Length >= 1,
			"the keylogger emits '" . EventType . "' but KL_BuildInserts produces no row for it, so it reaches today.log and then vanishes: never in data.sql, never on the dashboard. The default branch is deliberately permissive for forward-compatible replay, which is exactly why a missing case is indistinguishable from a deliberate skip and fails silently")
	}
}

; The event that prompted this guard, asserted specifically — including the
; table it must land in, because the obvious alternative fails differently.
_BICE_LlmFailureLandsInEventsSystem() {
	Inserts := KL_BuildInserts(_BICE_Event("llm_generation_failed"))
	Assert(IsObject(Inserts) and Inserts.Length >= 1,
		"llm_generation_failed must produce a row — the one event class whose purpose is to reveal silently-dropped predictions cannot itself be silently dropped")
	Assert(InStr(Inserts[1], "events_system") > 0,
		"llm_generation_failed must be routed to events_system, mirroring the macOS twin. events_llm would be rejected by its CHECK constraint, trading a silent skip for a failed insert. Got: " . Inserts[1])
}

; The permissive default must survive: it is what lets a future schema replay a
; type this build does not know about.
_BICE_UnknownTypeIsStillSkipped() {
	Inserts := KL_BuildInserts(_BICE_Event("some_future_event_type"))
	Assert(IsObject(Inserts) and Inserts.Length == 0,
		"a genuinely unknown type must still be skipped rather than throwing — replaying a newer log against an older build has to stay possible")
}


Test("build-inserts-covers-emitted-types: every emitted type produces an insert",
	_BICE_EveryEmittedTypeIsIngested)
Test("build-inserts-covers-emitted-types: the LLM failure event lands in events_system",
	_BICE_LlmFailureLandsInEventsSystem)
Test("build-inserts-covers-emitted-types: an unknown type is still skipped",
	_BICE_UnknownTypeIsStillSkipped)
