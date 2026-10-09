; tests/meta/test_corpus_logger_behaviour.ahk

; ==============================================================================
; MODULE: Logger Behaviour Corpus Consumer (AHK)
; DESCRIPTION:
; Replays _shared/tests/corpus/logger/behaviour_vectors.json against this
; driver's logger. The sibling corpus (_shared/modules/logger/test_vectors.json)
; pins the LINE FORMAT; this one pins the parts that decide whether a line exists
; at all -- severity filtering (spec section 4) and the ring buffer (section 5).
;
; WHY IT EXISTS: the macOS driver used levels 1/2/3/4 while this driver's
; LOGGER_SEVERITY and the shared Lua core used 10/20/30/40, and nothing compared
; them. A level NUMBER meant two different things depending on who read it. This
; corpus is the one file all three now answer to.
;
; CONTRACT:
; 1. The corpus is readable and every section is non-empty -- a truncated file
;    must not make the whole consumer pass over nothing.
; 2. LOGGER_SEVERITY matches the corpus numbering exactly, in both directions.
; 3. At each threshold, exactly the listed variants are emitted and exactly the
;    listed ones are dropped, measured through the test sink.
; 4. trace/done and start/success can never be split by a threshold.
; 5. The ring buffer holds its capacity, reads oldest-first across a wrap, and
;    handles both boundaries either side of capacity.
; 6. The consecutive dedup, replayed alone with repeat collapsing disarmed.
; 7. Repeat collapsing: every "repeat" case replayed on a driven clock and clock
;    face, with the exact delivered lines and summaries, then disarmed again.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================
; ======================================
; ======= 1/ Corpus Loader =============
; ======================================
; ======================================

; Emits one variant through the test sink and reports whether it got through.
; Every probe message is unique: the logger suppresses a line identical to the
; previous one inside a short window, so a reused string would make the second
; probe of a variant read as "dropped" -- a false failure that looks exactly like
; a broken threshold.
global _LOGCORPUS_PROBE_SEQ := 0

_LogCorpus_Emits(Variant) {
	global _LOGCORPUS_PROBE_SEQ

	Seen := false
	_LOGCORPUS_PROBE_SEQ += 1
	LoggerSetTestSink((*) => (Seen := true))
	Msg := "Ligne de test " . _LOGCORPUS_PROBE_SEQ . "."
	switch Variant {
		case "debug":   LoggerDebug("corpus", Msg)
		case "trace":   LoggerTrace("corpus", Msg)
		case "done":    LoggerDone("corpus", Msg)
		case "info":    LoggerInfo("corpus", Msg)
		case "start":   LoggerStart("corpus", Msg)
		case "success": LoggerSuccess("corpus", Msg)
		case "warn":    LoggerWarn("corpus", Msg)
		case "error":   LoggerError("corpus", Msg)
		default:        throw Error("unknown variant in corpus: " . Variant)
	}
	LoggerClearTestSink()
	return Seen
}

; Sets the active threshold by NAME and recomputes the fast-path flags, which is
; the only supported way to change it at runtime in this driver.
_LogCorpus_SetLevel(Name) {
	global LOGGER_MIN_LEVEL
	LOGGER_MIN_LEVEL := StrUpper(Name)
	_LoggerRefreshFastFlags()
}

; Emits N distinctly-numbered lines into an emptied ring buffer. Each call gets
; its own salt for the same dedup reason as the probes above.
global _LOGCORPUS_RING_RUN := 0

_LogCorpus_EmitNumbered(N) {
	global LOGGER_MIN_LEVEL, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, _LOGCORPUS_RING_RUN

	_LOGCORPUS_RING_RUN += 1
	Saved := LOGGER_MIN_LEVEL
	_LogCorpus_SetLevel("DEBUG")
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LoggerSetTestSink((*) => "")
	loop N {
		LoggerInfo("corpus", "run " . _LOGCORPUS_RING_RUN . " ligne " . A_Index)
	}
	LoggerClearTestSink()
	LOGGER_MIN_LEVEL := Saved
	_LoggerRefreshFastFlags()
}

; Emits one variant with an explicit body, for the dedup probes which need to
; control the exact text rather than have it salted unique.
_LogCorpus_EmitBody(Variant, Body) {
	switch Variant {
		case "debug":   LoggerDebug("corpus", Body)
		case "trace":   LoggerTrace("corpus", Body)
		case "done":    LoggerDone("corpus", Body)
		case "info":    LoggerInfo("corpus", Body)
		case "start":   LoggerStart("corpus", Body)
		case "success": LoggerSuccess("corpus", Body)
		case "warn":    LoggerWarn("corpus", Body)
		case "error":   LoggerError("corpus", Body)
		default:        throw Error("unknown variant in corpus: " . Variant)
	}
}

; Forgets the current suppression streak without emitting its summary, so one
; case cannot leave a streak open across into the next.
_LogCorpus_ResetDedup() {
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT, _LOGGER_DEDUP_LEVEL, _LastErrTime
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_COUNT := 0
	_LOGGER_DEDUP_LEVEL := ""
	_LastErrTime := 0
}

; Reads back the emission index a ring entry carries, or -1 when it carries none.
_LogCorpus_IndexOf(Line) {
	if RegExMatch(Line, "ligne (\d+)", &M)
		return M[1] + 0
	return -1
}

; Emits one variant with a template and optional format arguments, for the repeat
; cases, whose key is the unformatted template.
_LogCorpus_EmitTemplate(Variant, Tag, Template, Args*) {
	switch Variant {
		case "debug":   LoggerDebug(Tag, Template, Args*)
		case "trace":   LoggerTrace(Tag, Template, Args*)
		case "done":    LoggerDone(Tag, Template, Args*)
		case "info":    LoggerInfo(Tag, Template, Args*)
		case "start":   LoggerStart(Tag, Template, Args*)
		case "success": LoggerSuccess(Tag, Template, Args*)
		case "warn":    LoggerWarn(Tag, Template, Args*)
		case "error":   LoggerError(Tag, Template, Args*)
		default:        throw Error("unknown variant in corpus: " . Variant)
	}
}

; Expands a repeat case's steps into one flat, timed action list: "times"/"every"
; repeat a step, "range" substitutes each number for "<n>" in the template.
_LogCorpus_ExpandRepeatSteps(Steps) {
	Actions := []
	for _, Step in Steps {
		if Step.Has("flush") {
			Actions.Push(Map("at", Step["at"], "flush", Step["flush"]))
		} else if Step.Has("range") {
			From := Step["range"][1]
			loop Step["range"][2] - From + 1 {
				N := From + A_Index - 1
				Actions.Push(Map("at", Step["at"] + (N - From) * Step["every"],
					"variant", Step["variant"], "module", Step["module"],
					"template", StrReplace(Step["template"], "<n>", N)))
			}
		} else {
			Every := Step.Has("every") ? Step["every"] : 0
			loop (Step.Has("times") ? Step["times"] : 1) {
				Action := Map("at", Step["at"] + (A_Index - 1) * Every,
					"variant", Step["variant"], "module", Step["module"], "template", Step["template"])
				if Step.Has("arg")
					Action["arg"] := Step["arg"]
				Actions.Push(Action)
			}
		}
	}
	return Actions
}

; Splits one delivered line into its four spec section 3 fields.
_LogCorpus_ParseLine(Line) {
	if !RegExMatch(Line, "^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d{3}) \[([A-Z]+)\] \[([^\]]*)\] (.*)$", &M)
		throw Error("every delivered line must follow spec section 3, got: " . Line)
	return Map("stamp", M[1], "label", M[2], "module", M[3], "body", M[4])
}

; Replays one repeat case on a driven clock and clock face and returns the
; parsed lines the sink received plus the ring size. The file sinks, the dated
; rollover and the layer itself are restored in `finally`, so one red case can
; neither write fixture dates into a real log folder nor leak suppression into
; every later test of the suite.
_LogCorpus_ReplayRepeat(Section, Vector) {
	global LOGGER_MIN_LEVEL, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE, _LOGGER_SUB_PATHS
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	global _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN

	Base := RegExReplace(Vector.Has("base_time") ? Vector["base_time"] : Section["base_time"], "[^0-9]")
	At := 0
	Lines := []
	Ring := 0
	SavedLevel := LOGGER_MIN_LEVEL
	SavedLog := LOGGER_LOG_PATH
	SavedErrors := LOGGER_ERRORS_LOG_PATH
	SavedDate := _LOGGER_PATH_DATE
	SavedSubPaths := _LOGGER_SUB_PATHS
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_PATH_DATE := ""
	_LOGGER_SUB_PATHS := Map()
	_LogCorpus_SetLevel("DEBUG")
	_LogCorpus_ResetDedup()
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	_LOGGER_CLOCK_FN := () => At * 1000
	_LOGGER_STAMP_FN := () => FormatTime(DateAdd(Base, At, "Seconds"), "yyyy-MM-dd HH:mm:ss") . ":000"
	LoggerSetTestSink((L) => Lines.Push(L))
	try {
		_LoggerRepeatEnable()
		Previous := ""
		for _, Action in _LogCorpus_ExpandRepeatSteps(Vector["steps"]) {
			if (Previous != "" && Action["at"] < Previous)
				throw Error(Vector["id"] . ": corpus steps must be listed in time order")
			Previous := Action["at"]
			At := Action["at"]
			if Action.Has("flush") {
				_LoggerFlushRepeats(Action["flush"] == "terminal")
				continue
			}
			; The corpus writes its single placeholder neutrally; this driver's
			; formatter is Format().
			Template := StrReplace(Action["template"], "<arg>", "{1}")
			if Action.Has("arg")
				_LogCorpus_EmitTemplate(Action["variant"], Action["module"], Template, Action["arg"])
			else
				_LogCorpus_EmitTemplate(Action["variant"], Action["module"], Template)
		}
		Ring := LoggerRingBufferSnapshot().Length
	} finally {
		LoggerClearTestSink()
		_LoggerRepeatDisable()
		_LOGGER_CLOCK_FN := 0
		_LOGGER_STAMP_FN := 0
		_LogCorpus_ResetDedup()
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		LOGGER_LOG_PATH := SavedLog
		LOGGER_ERRORS_LOG_PATH := SavedErrors
		_LOGGER_PATH_DATE := SavedDate
		_LOGGER_SUB_PATHS := SavedSubPaths
		LOGGER_MIN_LEVEL := SavedLevel
		_LoggerRefreshFastFlags()
	}
	return {Lines: Lines, Ring: Ring}
}

; Asserts one parsed line against one expected repeat-corpus entry.
_LogCorpus_AssertRepeatLine(Id, Index, Got, Want) {
	static Labels := Map("debug", "DEBUG", "trace", "TRACE", "done", "DONE", "info", "INFO",
		"start", "START", "success", "SUCCESS", "warn", "WARNING", "error", "ERROR")
	Where := Id . " line " . Index
	AssertEqual(Labels[Want["variant"]], Got["label"], Where . ": level label")
	AssertEqual(Want["module"], Got["module"], Where . ": module tag")
	AssertEqual(StrReplace(Want["body"], "<arg>", "{1}"), Got["body"], Where . ": body")
	if Want.Has("stamp")
		AssertEqual(Want["stamp"], Got["stamp"], Where . ": timestamp")
}




; ======================================
; ======================================
; ======= 2/ Cases =====================
; ======================================
; ======================================

_LogCorpus_RunAll() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\logger\behaviour_vectors.json"

	_LogCorpus_FileExists() {
		AssertTrue(FileExist(CorpusPath) != "", "logger behaviour corpus must exist at: " . CorpusPath)
	}
	Test("logger corpus: file exists", _LogCorpus_FileExists)

	if !FileExist(CorpusPath)
		return

	Data := JsonParse(FileRead(CorpusPath, "UTF-8"))

	_LogCorpus_Sections() {
		; A corpus that lost a section would let this whole file pass while
		; testing a fraction of the behaviour
		AssertTrue(Data.Has("numbering"), "the corpus must declare the spec numbering")
		AssertTrue(Data.Has("aliases"), "the corpus must declare the accepted aliases")
		AssertTrue(Data.Has("filtering") and Data["filtering"].Length > 0, "the filtering section is empty")
		AssertTrue(Data.Has("lifecycle_pairs") and Data["lifecycle_pairs"].Length > 0, "the lifecycle-pair section is empty")
		AssertTrue(Data.Has("ring_buffer") and Data["ring_buffer"]["cases"].Length > 0, "the ring-buffer section is empty")
		AssertTrue(Data.Has("repeat") and Data["repeat"]["cases"].Length > 0,
			"the repeat section is empty -- every repeat case below would pass vacuously")
	}
	Test("logger corpus: all sections present and non-empty", _LogCorpus_Sections)

	if !Data.Has("filtering") || !Data.Has("numbering")
		return


	_LogCorpus_Numbering() {
		global LOGGER_SEVERITY
		Checked := 0
		for VariantName, Level in Data["numbering"] {
			if (SubStr(VariantName, 1, 1) == "_")
				continue
			Key := (VariantName == "warn") ? "WARNING" : StrUpper(VariantName)
			AssertTrue(LOGGER_SEVERITY.Has(Key), "LOGGER_SEVERITY must know the variant '" . Key . "'")
			AssertEqual(LOGGER_SEVERITY[Key], Level,
				"LOGGER_SEVERITY[" . Key . "] must be the spec's " . Level
				. " -- a level number that means something different here than on macOS is a "
				. "threshold nobody can reason about")
			Checked++
		}
		AssertTrue(Checked == 8, "the corpus must pin all eight variants, checked " . Checked)
	}
	Test("logger corpus: LOGGER_SEVERITY matches the spec numbering", _LogCorpus_Numbering)

	_LogCorpus_NoExtraSeverities() {
		global LOGGER_SEVERITY
		; The other direction: a variant this driver knows and the corpus does not
		; is a level nothing cross-driver has ever agreed on
		for Key, _ in LOGGER_SEVERITY {
			Lowered := (Key == "WARNING") ? "warn" : StrLower(Key)
			AssertTrue(Data["numbering"].Has(Lowered),
				"LOGGER_SEVERITY declares '" . Key . "', which the shared corpus does not")
		}
	}
	Test("logger corpus: no severity this driver invented alone", _LogCorpus_NoExtraSeverities)


	_LogCorpus_MakeFilterCase(Vector) {
		_Run() {
			global LOGGER_MIN_LEVEL
			Saved := LOGGER_MIN_LEVEL
			_LogCorpus_SetLevel(Vector["min_level"])
			for _, Variant in Vector["emitted"] {
				AssertTrue(_LogCorpus_Emits(Variant),
					"at threshold '" . Vector["min_level"] . "', " . Variant . " must be emitted")
			}
			for _, Variant in Vector["dropped"] {
				AssertTrue(!_LogCorpus_Emits(Variant),
					"at threshold '" . Vector["min_level"] . "', " . Variant . " must be dropped")
			}
			LOGGER_MIN_LEVEL := Saved
			_LoggerRefreshFastFlags()
		}
		return _Run
	}
	for _, Vector in Data["filtering"] {
		Test("logger corpus filtering: " . Vector["id"], _LogCorpus_MakeFilterCase(Vector))
	}

	_LogCorpus_MakePairCase(Pair) {
		_Run() {
			global LOGGER_MIN_LEVEL
			Saved := LOGGER_MIN_LEVEL
			for _, Threshold in ["DEBUG", "INFO", "WARNING", "ERROR"] {
				_LogCorpus_SetLevel(Threshold)
				AssertEqual(_LogCorpus_Emits(Pair["a"]), _LogCorpus_Emits(Pair["b"]),
					"at threshold '" . Threshold . "', " . Pair["a"] . " and " . Pair["b"]
					. " must be emitted or dropped together -- half a lifecycle pair in the log "
					. "reads as a silent failure that never happened")
			}
			LOGGER_MIN_LEVEL := Saved
			_LoggerRefreshFastFlags()
		}
		return _Run
	}
	for _, Pair in Data["lifecycle_pairs"] {
		Test("logger corpus pairs: " . Pair["id"], _LogCorpus_MakePairCase(Pair))
	}


	_LogCorpus_MakeRingCase(Vector) {
		_Run() {
			global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
			_LogCorpus_EmitNumbered(Vector["emit"])
			if (Vector.Has("clear") and Vector["clear"]) {
				LOGGER_RING_BUFFER := []
				LOGGER_RING_CURSOR := 0
			}

			Snapshot := LoggerRingBufferSnapshot()
			AssertEqual(Snapshot.Length, Vector["expect_size"],
				Vector["id"] . ": the buffer must hold " . Vector["expect_size"] . " entry(ies)")

			if Vector.Has("expect_first") {
				; Order is asserted across the WHOLE snapshot, not just its ends: a
				; circular buffer returned as its raw array has the right first and
				; last entries only by accident, and reads as two shuffled halves in
				; between.
				Previous := -1
				for _, Line in Snapshot {
					Idx := _LogCorpus_IndexOf(Line)
					AssertTrue(Idx > 0, Vector["id"] . ": every entry must carry its emission index")
					if (Previous > 0)
						AssertEqual(Idx, Previous + 1, Vector["id"] . ": the snapshot must read oldest-first with no gaps")
					Previous := Idx
				}
				AssertEqual(_LogCorpus_IndexOf(Snapshot[1]), Vector["expect_first"],
					Vector["id"] . ": the oldest surviving entry must be line " . Vector["expect_first"])
				AssertEqual(_LogCorpus_IndexOf(Snapshot[Snapshot.Length]), Vector["expect_last"],
					Vector["id"] . ": the newest entry must be line " . Vector["expect_last"])
			}

			LOGGER_RING_BUFFER := []
			LOGGER_RING_CURSOR := 0
		}
		return _Run
	}
	for _, Vector in Data["ring_buffer"]["cases"] {
		Test("logger corpus ring: " . Vector["id"], _LogCorpus_MakeRingCase(Vector))
	}

	_LogCorpus_Capacity() {
		global LOGGER_RING_BUFFER_SIZE, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
		AssertEqual(LOGGER_RING_BUFFER_SIZE, Data["ring_buffer"]["capacity"],
			"the declared capacity must be the corpus capacity")
		; Derived as well as declared: a capacity constant that drifted from the
		; real array would agree with itself and with nothing else
		_LogCorpus_EmitNumbered(Data["ring_buffer"]["capacity"] + 25)
		AssertEqual(LoggerRingBufferSnapshot().Length, Data["ring_buffer"]["capacity"],
			"the buffer must cap at the corpus capacity")
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
	}
	Test("logger corpus ring: capacity matches the corpus", _LogCorpus_Capacity)



	; ======================================
	; ======================================
	; ======= 6/ Deduplication =============
	; ======================================
	; ======================================

	_LogCorpus_MakeDedupCase(Vector) {
		_Run() {
			global LOGGER_MIN_LEVEL, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
			global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT, _LastErrTime, _LOGGER_REPEAT_ENABLED

			; These cases pin the consecutive layer ALONE (see the corpus comment):
			; an armed repeat layer would withhold the third line of a,b,a itself
			AssertFalse(_LOGGER_REPEAT_ENABLED, "the dedup cases must replay with repeat collapsing disarmed")
			Saved := LOGGER_MIN_LEVEL
			_LogCorpus_SetLevel("DEBUG")
			_LogCorpus_ResetDedup()
			LOGGER_RING_BUFFER := []
			LOGGER_RING_CURSOR := 0

			Lines := []
			LoggerSetTestSink((L) => Lines.Push(L))
			Variant := Vector.Has("variant") ? Vector["variant"] : "info"
			for _, Body in Vector["emit"] {
				_LogCorpus_EmitBody(Variant, Body)
			}
			LoggerClearTestSink()

			if Vector.Has("expect_delivered") {
				AssertEqual(Lines.Length, Vector["expect_delivered"],
					Vector["id"] . ": " . Vector["expect_delivered"] . " line(s) must reach the sink")
			}
			if Vector.Has("expect_suppressed") {
				AssertEqual(_LOGGER_DEDUP_COUNT, Vector["expect_suppressed"],
					Vector["id"] . ": " . Vector["expect_suppressed"] . " line(s) must have been suppressed "
					. "-- asserting the absence alone would pass against a logger that dropped them for "
					. "any other reason")
			}
			if (Vector.Has("expect_summary") and Vector["expect_summary"]) {
				Summaries := 0
				for _, L in Lines {
					if InStr(L, "identical") {
						Summaries += 1
						AssertTrue(InStr(L, Vector["expect_summary_count"] . " identical") > 0,
							Vector["id"] . ": the summary must carry the suppressed count, got " . L)
					}
				}
				AssertEqual(Summaries, 1, Vector["id"] . ": closing a streak must emit exactly one summary")
			}
			if Vector.Has("expect_summary_variant") {
				; Seed a streak at the variant under test, then close it and read the
				; summary's label back
				_LogCorpus_ResetDedup()
				Wanted := Vector["expect_summary_variant"]
				_LogCorpus_EmitBody(Wanted, "graine")
				_LogCorpus_EmitBody(Wanted, "graine")
				Closing := []
				LoggerSetTestSink((L) => Closing.Push(L))
				_LogCorpus_EmitBody(Wanted, "fermeture")
				LoggerClearTestSink()
				Found := ""
				for _, L in Closing {
					if InStr(L, "identical")
						Found := L
				}
				AssertTrue(Found != "", Vector["id"] . ": closing the streak must emit a summary")
				AssertTrue(InStr(Found, "[" . StrUpper(Wanted) . "]") > 0,
					Vector["id"] . ": the summary must carry the suppressed variant's label, or a "
					. "swallowed error storm never reaches the errors-only log -- got " . Found)
			}
			if Vector.Has("expect_ring_entries") {
				AssertEqual(LoggerRingBufferSnapshot().Length, Vector["expect_ring_entries"],
					Vector["id"] . ": the ring feeds crash reports -- a thousand copies of one line "
					. "would push out everything that explains it")
			}

			_LogCorpus_ResetDedup()
			LOGGER_RING_BUFFER := []
			LOGGER_RING_CURSOR := 0
			LOGGER_MIN_LEVEL := Saved
			_LoggerRefreshFastFlags()
		}
		return _Run
	}
	for _, Vector in Data["dedup"]["cases"] {
		Test("logger corpus dedup: " . Vector["id"], _LogCorpus_MakeDedupCase(Vector))
	}

	_LogCorpus_DedupWindowExpires() {
		global LOGGER_MIN_LEVEL, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, _LastErrTime
		; De-BOUNCED, not permanently silenced. Without this the first occurrence of
		; a recurring line would be the only one ever logged, for the whole session.
		; The window is walked by moving the streak's start backwards rather than by
		; sleeping five seconds, which would add five seconds to every CI run.
		Saved := LOGGER_MIN_LEVEL
		_LogCorpus_SetLevel("DEBUG")
		_LogCorpus_ResetDedup()
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0

		Lines := []
		LoggerSetTestSink((L) => Lines.Push(L))
		_LogCorpus_EmitBody("info", "recurrente")
		_LogCorpus_EmitBody("info", "recurrente")
		_LastErrTime := _LastErrTime - (Data["dedup"]["window_seconds"] * 1000) - 1000
		_LogCorpus_EmitBody("info", "recurrente")
		LoggerClearTestSink()

		Real := 0
		for _, L in Lines {
			if !InStr(L, "identical")
				Real += 1
		}
		AssertEqual(Real, 2, "the line must re-surface once the window has passed")

		_LogCorpus_ResetDedup()
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
		LOGGER_MIN_LEVEL := Saved
		_LoggerRefreshFastFlags()
	}
	Test("logger corpus dedup: a streak that outlives the window re-surfaces", _LogCorpus_DedupWindowExpires)



	; ======================================
	; ======================================
	; ======= 7/ Repeat Collapsing =========
	; ======================================
	; ======================================

	_LogCorpus_RepeatArmingRefusedTwice() {
		global _LOGGER_REPEAT_ENABLED
		; A second arming would otherwise discard every live streak and its count
		_LoggerRepeatEnable()
		Threw := false
		try {
			_LoggerRepeatEnable()
		} catch as ArmErr {
			Threw := InStr(ArmErr.Message, "already") > 0
		} finally {
			_LoggerRepeatDisable()
		}
		AssertTrue(Threw, "a second arming must raise and say why")
		AssertFalse(_LOGGER_REPEAT_ENABLED, "disarming must leave the layer off")
	}
	Test("logger corpus repeat: arming twice is refused", _LogCorpus_RepeatArmingRefusedTwice)

	_LogCorpus_MakeRepeatCase(Vector) {
		_Run() {
			Result := _LogCorpus_ReplayRepeat(Data["repeat"], Vector)
			Id := Vector["id"]
			Got := []
			for _, L in Result.Lines
				Got.Push(_LogCorpus_ParseLine(L))

			if Vector.Has("expect") {
				AssertEqual(Vector["expect"].Length, Got.Length,
					Id . ": exactly the expected lines must reach the sink")
				for I, Want in Vector["expect"]
					_LogCorpus_AssertRepeatLine(Id, I, Got[I], Want)
			}
			if Vector.Has("expect_ring") {
				AssertEqual(Vector["expect_ring"], Result.Ring,
					Id . ": withheld occurrences must stay out of the ring the crash report reads")
			}
			if Vector.Has("expect_line_count") {
				; A repeat summary quotes its streak's text right after the arrow; a
				; dedup summary never does, which is what tells the two apart
				Plain := 0
				Summaries := []
				for I, Line in Got {
					if (SubStr(Line["body"], 1, 3) == Chr(0x2191) . ' "')
						Summaries.Push(Map("line", Line, "next", I < Got.Length ? Got[I + 1]["body"] : ""))
					else if (SubStr(Line["body"], 1, 2) != Chr(0x2191) . " ")
						Plain += 1
				}
				AssertEqual(Vector["expect_line_count"], Plain, Id . ": non-summary line count")
				AssertEqual(Vector["expect_summaries"].Length, Summaries.Length, Id . ": repeat summary count")
				for I, Want in Vector["expect_summaries"] {
					_LogCorpus_AssertRepeatLine(Id, I, Summaries[I]["line"], Want)
					if Want.Has("followed_by")
						AssertEqual(Want["followed_by"], Summaries[I]["next"],
							Id . ": the summary must be emitted right before the line that evicted it")
				}
			}
		}
		return _Run
	}
	for _, Vector in Data["repeat"]["cases"] {
		Test("logger corpus repeat: " . Vector["id"], _LogCorpus_MakeRepeatCase(Vector))
	}


	_LogCorpus_Default() {
		global LOGGER_DEFAULT_LEVEL
		; A starting threshold is a policy, not a behaviour of the filter, so the
		; corpus records one row per driver and each asserts its own. This driver
		; deliberately starts at INFO to keep the log file quiet during normal use;
		; changing it is then a deliberate edit to the shared file, not a surprise
		; in a log that suddenly went quiet.
		Recorded := Data["driver_defaults"]["ahk"]
		AssertEqual(StrUpper(Recorded), LOGGER_DEFAULT_LEVEL,
			"LOGGER_DEFAULT_LEVEL must be the level the shared corpus records for this driver")
	}
	Test("logger corpus: this driver's default matches its recorded row", _LogCorpus_Default)
}

_LogCorpus_RunAll()
