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
			global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT, _LastErrTime

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
