; static/ergopti_plus/windows/tests/unit/modules/hotstrings/engine/test_build_inserts_covers_emitted_types.ahk

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
; of the one type that was found, so the next event class added to the keystats
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

; The bracket that directly encloses each position, read outside string
; literals. An emitter writes its type as a key/value pair of a Map(...) call;
; a builder lists the entry fields it keeps out of meta_json as an array
; ["type", "timestamp", ...], whose pair of literals is no event type.
; @param Src {String} Comment-stripped source.
; @param Positions {Map} 1-based positions to classify (keys).
; @returns {Map} Position -> "(", "[", "{" or "" at top level.
_BICE_EnclosingBrackets(Src, Positions) {
	Result := Map()
	Stack := []
	Quote := ""
	Idx := 1
	Len := StrLen(Src)
	while (Idx <= Len) {
		Ch := SubStr(Src, Idx, 1)
		if (Quote != "") {
			; A literal never spans a line, so a stray quote cannot run on.
			if (Ch == Chr(96))
				Idx += 1
			else if (Ch == Quote || Ch == "`n")
				Quote := ""
			Idx += 1
			continue
		}
		if Positions.Has(Idx)
			Result[Idx] := Stack.Length ? Stack[Stack.Length] : ""
		; An inline comment (whitespace then ";") may hold an apostrophe.
		if (Ch == ";" && Idx > 1 && InStr(" `t", SubStr(Src, Idx - 1, 1))) {
			Next := InStr(Src, "`n", true, Idx)
			Idx := Next ? Next : Len + 1
			continue
		}
		if (Ch == '"' || Ch == "'")
			Quote := Ch
		else if (Ch == "(" || Ch == "[" || Ch == "{")
			Stack.Push(Ch)
		else if ((Ch == ")" || Ch == "]" || Ch == "}") && Stack.Length)
			Stack.Pop()
		Idx += 1
	}
	return Result
}

; Event type literals as written by an emitter Map in the given source.
; @param Src {String} Comment-stripped source.
; @returns {Map} Type -> true.
_BICE_TypesIn(Src) {
	global _BICE_NOT_EVENT_TYPES
	Found := []
	Positions := Map()
	Pos := 1
	while (F := RegExMatch(Src, '"type",\s*"([a-z_]+)"', &M, Pos)) {
		Pos := F + M.Len
		Found.Push({pos: F, name: M[1]})
		Positions[F] := true
	}
	Enclosing := _BICE_EnclosingBrackets(Src, Positions)
	Types := Map()
	for Match in Found {
		if (Enclosing[Match.pos] == "[")
			continue
		Name := Match.name
		Skip := false
		for Excluded in _BICE_NOT_EVENT_TYPES
			if (Excluded == Name)
				Skip := true
		if !Skip
			Types[Name] := true
	}
	return Types
}

; Event type literals as the keystats actually emits them.
_BICE_EmittedTypes() {
	return _BICE_TypesIn(_StripFullLineComments(_DriverDirConcat("modules/keystats")))
}

; The scan reads emitter Maps, not a builder's list of excluded entry fields:
; KL_BuildInsertKindRow's callers once made "timestamp" look like an emitted
; type. A string or an inline comment holding a bracket or an apostrophe must
; not shift the reading either.
_BICE_ScanSeparatesEmittersFromFieldLists() {
	Src := 'e := Map("type", "mouse_click", "note", "a [ and a (") `; don' . "'" . 't`n'
		. 'return Build("events_mouse", e, id, ["type", "timestamp", "app"])`n'
		. 'KL_AppendLog(Map(`n`t"app", App,`n`t"type", "vpn_connected"))`n'
	Types := _BICE_TypesIn(Src)
	AssertTrue(Types.Has("mouse_click"), "a one-line emitter Map is read")
	AssertTrue(Types.Has("vpn_connected"), "a multi-line emitter Map is read")
	AssertFalse(Types.Has("timestamp"), "an excluded-field array is no emitter")
	AssertEqual(2, Types.Count)
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
	; Non-vacuity floor: the keystats emits well over half a dozen distinct
	; classes. A scan that matched nothing would pass every assertion below.
	Assert(Count >= 6,
		"the scan must reach the keystats's real event emitters (found only " . Count . " type(s)) — a scan that matches nothing cannot fail")

	for EventType, _ in Types {
		Inserts := ""
		try {
			Inserts := KL_BuildInserts(_BICE_Event(EventType))
		} catch as Err {
			Assert(false,
				"KL_BuildInserts threw on the emitted type '" . EventType . "': " . Err.Message)
		}
		Assert(IsObject(Inserts) and Inserts.Length >= 1,
			"the keystats emits '" . EventType . "' but KL_BuildInserts produces no row for it, so it reaches today.log and then vanishes: never in data.sql, never on the dashboard. The default branch is deliberately permissive for forward-compatible replay, which is exactly why a missing case is indistinguishable from a deliberate skip and fails silently")
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
Test("build-inserts-covers-emitted-types: the scan reads emitter maps, not excluded-field lists",
	_BICE_ScanSeparatesEmittersFromFieldLists)
Test("build-inserts-covers-emitted-types: the LLM failure event lands in events_system",
	_BICE_LlmFailureLandsInEventsSystem)
Test("build-inserts-covers-emitted-types: an unknown type is still skipped",
	_BICE_UnknownTypeIsStillSkipped)
