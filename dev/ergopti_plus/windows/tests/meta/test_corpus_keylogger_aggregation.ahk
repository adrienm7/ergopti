; static/ergopti_plus/windows/tests/meta/test_corpus_keylogger_aggregation.ahk

; ==============================================================================
; MODULE: Keylogger Aggregation Corpus Consumer (AHK)
; DESCRIPTION:
; Validates the AHK keylogger walker (KLW_WalkTypingEntry / KLW_WalkAppSwitch /
; KLW_WalkWindowSwitch / KLW_WalkSystemEvent) against the cross-driver contract
; defined in _shared/tests/corpus/keylogger/aggregation_vectors.json.
;
; Each vector is a batch of JSONL-style events replayed through the walker, then
; the resulting KLW.batch state is compared against the expected output.
;
; This pins the AHK aggregation logic against the same golden vectors as the
; macOS driver (events.lua walk_typing), so any divergence between the two
; implementations is caught immediately.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Corpus Loading =========================
; ===================================================
; ===================================================

_KlgAggCorpus_LoadCorpus() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\keylogger\aggregation_vectors.json"
	if !FileExist(CorpusPath) {
		return ""
	}
	Raw := FileRead(CorpusPath, "UTF-8")
	return JsonParse(Raw)
}





; ===================================================
; ===================================================
; ======= 2/ Vector Dispatcher ======================
; ===================================================
; ===================================================

; Replays a single corpus event through the correct AHK walker.
_KlgAggCorpus_ReplayEvent(Entry) {
	EType := Entry.Has("type") ? Entry["type"] : ""

	if (EType = "typing") {
		; Convert corpus format to the walker's expected Map shape.
		Events := []
		Evs := Entry.Has("events") ? Entry["events"] : []
		for Ev in Evs {
			Meta := (Ev.Has("meta") && Ev["meta"] is Map) ? Ev["meta"] : Map()
			Events.Push([Ev["char"], Ev["delay"], Meta])
		}
		WalkEntry := Map(
			"app", Entry.Has("app") ? Entry["app"] : "Unknown",
			"timestamp", Entry.Has("timestamp") ? Entry["timestamp"] : "",
			"events", Events
		)
		if Entry.Has("layout")
			WalkEntry["layout"] := Entry["layout"]
		if Entry.Has("title")
			WalkEntry["title"] := Entry["title"]
		KLW_WalkTypingEntry(WalkEntry)
	}
	else if (EType = "app_switch") {
		WalkEntry := Map(
			"prev_app", Entry.Has("prev_app") ? Entry["prev_app"] : "",
			"next_app", Entry.Has("next_app") ? Entry["next_app"] : "",
			"timestamp", Entry.Has("timestamp") ? Entry["timestamp"] : "",
			"duration_ms", Entry.Has("duration_ms") ? Entry["duration_ms"] : 0
		)
		KLW_WalkAppSwitch(WalkEntry)
	}
	else if (EType = "window_switch") {
		WalkEntry := Map(
			"app", Entry.Has("app") ? Entry["app"] : "Unknown",
			"prev_title", Entry.Has("prev_title") ? Entry["prev_title"] : "",
			"timestamp", Entry.Has("timestamp") ? Entry["timestamp"] : "",
			"duration_ms", Entry.Has("duration_ms") ? Entry["duration_ms"] : 0
		)
		KLW_WalkWindowSwitch(WalkEntry)
	}
	else if (EType = "system_event") {
	; system_event entries pass through as-is (they already use the
	; action/keycode/hold_ms/app/timestamp/stat/amount/latency_ms fields
	; that KLW_WalkSystemEvent expects)
		WalkEntry := Map()
		for k, v in Entry {
			if (k != "type")
				WalkEntry[k] := v
		}
		KLW_WalkSystemEvent(WalkEntry)
	}
}

; Sets up a fresh batch and replays all events in a vector.
_KlgAggCorpus_SetupAndReplay(Vec) {
	KLW_ResetBatch()
	KLW.ctx := Map()
	for Entry in Vec["events"] {
		_KlgAggCorpus_ReplayEvent(Entry)
	}
}





; ===================================================
; ===================================================
; ======= 3/ Batch Reading Helpers ==================
; ===================================================
; ===================================================

_KlgAggCorpus_ReadAppDay(DateStr, App) {
	Key := DateStr . Chr(1) . App
	if KLW.batch["app_day"].Has(Key)
		return KLW.batch["app_day"][Key]
	return ""
}

_KlgAggCorpus_CountEntries(Tbl) {
	if !(Tbl is Map)
		return 0
	return Tbl.Count
}

_KlgAggCorpus_CountNgram(Sub) {
	if !KLW.batch["ngram"].Has(Sub)
		return 0
	return KLW.batch["ngram"][Sub].Count
}

_KlgAggCorpus_ReadCtx(App) {
	if KLW.ctx.Has(App)
		return KLW.ctx[App]
	return ""
}

_KlgAggCorpus_ReadErgo(DateStr, App) {
	Key := DateStr . Chr(1) . App
	if KLW.batch["ergo"].Has(Key)
		return KLW.batch["ergo"][Key]
	return ""
}

_KlgAggCorpus_ReadKcHold(DateStr, App, Kc) {
	Key := DateStr . Chr(1) . App . Chr(1) . String(Kc)
	if KLW.batch["kc_hold"].Has(Key)
		return KLW.batch["kc_hold"][Key]
	return ""
}

_KlgAggCorpus_ReadSystemDay(DateStr) {
	if KLW.batch["system_day"].Has(DateStr)
		return KLW.batch["system_day"][DateStr]
	return ""
}

_KlgAggCorpus_ReadHourly(DateStr, App, Hour) {
	Key := DateStr . Chr(1) . App . Chr(1) . Hour
	if KLW.batch["hourly"].Has(Key)
		return KLW.batch["hourly"][Key]
	return ""
}

_KlgAggCorpus_ReadCharsClass(DateStr, App) {
	Key := DateStr . Chr(1) . App
	if KLW.batch["chars_class"].Has(Key)
		return KLW.batch["chars_class"][Key]
	return ""
}

_KlgAggCorpus_SumAppTimeMs(App) {
	Total := 0
	for _, Row in KLW.batch["app_time"] {
		if (Row["app"] = App)
			Total += Row["ms"]
	}
	return Total
}

_KlgAggCorpus_CountSwitchesTo(App) {
	N := 0
	for _, Row in KLW.batch["switches_to"] {
		if (Row["app_from"] = App)
			N += 1
	}
	return N
}

_KlgAggCorpus_SumTitlesMs() {
	Total := 0
	for _, Row in KLW.batch["titles"] {
		Total += Row["ms"]
	}
	return Total
}





; ===================================================
; ===================================================
; ======= 4/ Corpus Test Registration ===============
; ===================================================
; ===================================================

_KlgAggCorpus_RegisterAll() {
	Data := _KlgAggCorpus_LoadCorpus()
	if (Data = "") {
		Test("keylogger aggregation corpus: file exists", () => AssertTrue(false,
			"Corpus file not found"))
		return
	}
	if !Data.Has("vectors") {
		Test("keylogger aggregation corpus: valid structure", () => AssertTrue(false,
			"No 'vectors' key in corpus JSON"))
		return
	}

	for Vec in Data["vectors"] {
		Id := Vec.Has("id") ? Vec["id"] : "unknown"
		Desc := Vec.Has("description") ? Vec["description"] : Id
		NameCopy := "[corpus:kl-agg:" . Id . "] " . SubStr(Desc, 1, 60)
		; .Bind, never an inline fat-arrow over a loop-scoped copy: the copy is one
		; variable in THIS function, every closure shares it, and they all run after
		; the loop — so all 13 tests replayed the last vector. Measured: corrupting
		; the FIRST vector produced zero failures.
		Test(NameCopy, _KlgAggCorpus_RunVector.Bind(Vec))
	}
}

_KlgAggCorpus_RunVector(Vec) {
	_KlgAggCorpus_SetupAndReplay(Vec)
	Expected := Vec["expected"]
	Id := Vec["id"]

	if (Id = "simple_typing_3_chars") {
		Row := _KlgAggCorpus_ReadAppDay("2024-06-01", "TestApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(3, KLW_GetMap(Row, "chars", 0), "chars = 3")
		AssertEqual(330, KLW_GetMap(Row, "time_ms", 0), "time_ms = 330")
		AssertEqual(0, KLW_GetMap(Row, "pauses", 0), "pauses = 0")
		AssertEqual(3, _KlgAggCorpus_CountNgram("ngram_chars"), "3 char ngrams")
		AssertEqual(2, _KlgAggCorpus_CountNgram("ngram_bigrams"), "2 bigrams")
		AssertEqual(1, _KlgAggCorpus_CountNgram("ngram_trigrams"), "1 trigram")
		Hr := _KlgAggCorpus_ReadHourly("2024-06-01", "TestApp", "10")
		AssertTrue(Hr != "", "hourly row exists")
		AssertEqual(3, Hr["c"], "hourly c = 3")
		Cc := _KlgAggCorpus_ReadCharsClass("2024-06-01", "TestApp")
		AssertTrue(Cc != "", "chars_class row exists")
		AssertEqual(3, Cc["letter"], "3 letters")
		Ctx := _KlgAggCorpus_ReadCtx("TestApp")
		AssertTrue(Ctx != "", "context exists")
		AssertEqual("c", Ctx["p1"], "last p1 = 'c'")
	}
	else if (Id = "typing_with_backspace") {
		Row := _KlgAggCorpus_ReadAppDay("2024-06-01", "BSApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(3, KLW_GetMap(Row, "chars", 0), "chars = 3 (h+e+bs — backspace counts as a char)")
		ErKey := "2024-06-01" . Chr(1) . "BSApp"
		AssertTrue(KLW.batch["errors"].Has(ErKey), "errors row exists")
		AssertEqual(1, KLW.batch["errors"][ErKey]["bs_total"], "bs_total = 1")
		Ctx := _KlgAggCorpus_ReadCtx("BSApp")
		AssertTrue(Ctx != "", "context exists")
		AssertEqual("h", Ctx["cur_word"], "cur_word = 'h'")
		AssertEqual("[BS]", Ctx["p1"], "last p1 = '[BS]'")
	}
	else if (Id = "typing_with_word_boundary") {
		Ctx := _KlgAggCorpus_ReadCtx("WordApp")
		AssertTrue(Ctx != "", "context exists")
		AssertEqual("", Ctx["cur_word"], "cur_word reset")
		AssertEqual("hi", Ctx["prev_word"], "prev_word = 'hi'")
		Cc := _KlgAggCorpus_ReadCharsClass("2024-06-01", "WordApp")
		AssertTrue(Cc != "", "chars_class row exists")
		AssertEqual(2, Cc["letter"], "2 letters")
		AssertEqual(1, Cc["space"], "1 space")
	}
	else if (Id = "synthetic_hotstring_trigger") {
		Row := _KlgAggCorpus_ReadAppDay("2024-06-01", "HsApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(1, KLW_GetMap(Row, "chars", 0), "chars = 1")
		AssertEqual(2, KLW_GetMap(Row, "hs_chars", 0), "hs_chars = 2")
		AssertEqual(1, KLW_GetMap(Row, "hs_triggers", 0), "hs_triggers = 1")
	}
	else if (Id = "synthetic_llm_trigger") {
		Row := _KlgAggCorpus_ReadAppDay("2024-06-01", "LlmApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(1, KLW_GetMap(Row, "chars", 0), "chars = 1")
		AssertEqual(2, KLW_GetMap(Row, "llm_chars", 0), "llm_chars = 2")
		AssertEqual(1, KLW_GetMap(Row, "llm_triggers", 0), "llm_triggers = 1")
	}
	else if (Id = "synthetic_hotstring_backspace_keeps_gross_output") {
		Row := _KlgAggCorpus_ReadAppDay("2024-06-01", "GrossHsApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(3, KLW_GetMap(Row, "chars", 0), "manual trigger remains three real chars")
		AssertEqual(8, KLW_GetMap(Row, "hs_chars", 0), "hs_chars is gross generated output")
		AssertEqual(3, KLW_GetMap(Row, "hs_input_chars", 0), "deleted trigger is separate input")
		AssertEqual(5, KLW_GetMap(Row, "hs_chars", 0) - KLW_GetMap(Row, "hs_input_chars", 0),
			"the source-filtered UI sees the net gain once")
	}
	else if (Id = "typing_with_think_pause") {
		Row := _KlgAggCorpus_ReadAppDay("2024-06-01", "PauseApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(3, KLW_GetMap(Row, "chars", 0), "chars = 3")
		AssertEqual(1, KLW_GetMap(Row, "pauses", 0), "1 pause")
		AssertEqual(3000, KLW_GetMap(Row, "think_time_ms", 0), "think_time = 3000")
		AssertEqual(200, KLW_GetMap(Row, "time_ms", 0), "time_ms = 200")
		Ctx := _KlgAggCorpus_ReadCtx("PauseApp")
		AssertTrue(Ctx != "")
		AssertEqual("c", Ctx["p1"], "last p1 = 'c'")
	}
	else if (Id = "long_gap_preserves_chars_and_splits_runs") {
		Row := _KlgAggCorpus_ReadAppDay("2024-06-01", "LongGapApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(5, KLW_GetMap(Row, "chars", 0), "every physical character is counted")
		AssertEqual(600, KLW_GetMap(Row, "time_ms", 0), "short delays stay in active typing time")
		AssertEqual(2, KLW_GetMap(Row, "pauses", 0), "both long gaps are think pauses")
		AssertEqual(310000, KLW_GetMap(Row, "think_time_ms", 0), "long gaps keep their raw delay")
		AssertEqual(5, _KlgAggCorpus_CountNgram("ngram_chars"),
			"long gaps break continuity without dropping the character unigram")
		CharNgrams := KLW.batch["ngram"]["ngram_chars"]
		TotalDelay := 0
		DelayCount := 0
		for _, Item in CharNgrams {
			TotalDelay += KLW_GetMap(Item, "td", 0)
			DelayCount += KLW_GetMap(Item, "cd", 0)
		}
		AssertEqual(Vec["expected"]["ngram_chars_total_delay_ms"], TotalDelay,
			"only short gaps contribute to character n-gram timing")
		AssertEqual(Vec["expected"]["ngram_chars_delay_count"], DelayCount,
			"only short gaps contribute a character n-gram delay sample")
		for Token in Vec["expected"]["ngram_zero_delay_tokens"] {
			NgramKey := "2024-06-01" . Chr(1) . "LongGapApp" . Chr(1) . Token
			AssertTrue(CharNgrams.Has(NgramKey), "long-gap character unigram exists: " . Token)
			AssertEqual(0, KLW_GetMap(CharNgrams[NgramKey], "td", 0),
				"long-gap unigram delay is clamped: " . Token)
			AssertEqual(0, KLW_GetMap(CharNgrams[NgramKey], "cd", 0),
				"long-gap unigram delay sample is absent: " . Token)
		}

		Key := "2024-06-01" . Chr(1) . "LongGapApp"
		AssertTrue(KLW.batch["bursts"].Has(Key), "two closed bursts are aggregated")
		AssertEqual(2, KLW.batch["bursts"][Key]["count_total"],
			"9000 ms and 301000 ms split bursts")
		AssertTrue(KLW.batch["sessions"].Has(Key), "the first session closes after five minutes")
		AssertEqual(1, KLW.batch["sessions"][Key]["count_total"],
			"only the five-minute gap splits sessions")

		Ctx := _KlgAggCorpus_ReadCtx("LongGapApp")
		AssertTrue(Ctx != "", "context exists")
		AssertEqual(2, Ctx["current_burst"]["char_count"], "the final burst stays open with d+e")
		AssertEqual(2, Ctx["current_session"]["char_count"], "the final session stays open with d+e")
		AssertEqual("e", Ctx["p1"], "the newest character remains the context tail")
		AssertEqual(5, Ctx["recent_typing"].Length,
			"long-gap characters remain eligible for trigger attribution")
		AssertEqual(9000, Ctx["recent_typing"][2]["delay"], "trigger attribution keeps the raw burst gap")
		AssertEqual(301000, Ctx["recent_typing"][4]["delay"], "trigger attribution keeps the raw session gap")
	}
	else if (Id = "app_switch_accumulates_duration") {
		AssertEqual(1, _KlgAggCorpus_CountEntries(KLW.batch["app_time"]), "1 app_time entry")
		AssertEqual(8000, _KlgAggCorpus_SumAppTimeMs("AppA"), "app_time total = 8000")
		AssertEqual(2, _KlgAggCorpus_CountSwitchesTo("AppA"), "2 switches_to")
	}
	else if (Id = "window_switch_credits_title_ms") {
		AssertEqual(1, _KlgAggCorpus_CountEntries(KLW.batch["titles"]), "1 title entry")
		AssertEqual(12000, _KlgAggCorpus_SumTitlesMs(), "titles ms = 12000")
	}
	else if (Id = "system_event_wifi_change") {
		Sday := _KlgAggCorpus_ReadSystemDay("2024-06-01")
		AssertTrue(Sday != "", "system_day row exists")
		AssertEqual(2, Sday["wifi_changes"], "wifi_changes = 2")
	}
	else if (Id = "system_event_modifier_hold") {
		R := _KlgAggCorpus_ReadKcHold("2024-06-01", "TestApp", 56)
		AssertTrue(R != "", "kc_hold row exists")
		AssertEqual(2, R["count"], "count = 2")
		AssertEqual(500, R["sum_ms"], "sum_ms = 500")
		AssertEqual(300, R["max_ms"], "max_ms = 300")
	}
	else if (Id = "system_event_manifest_increment_hs") {
		; Accepted divergence: manifest_increment is a macOS-only feature and the AHK
		; walker has no branch for it. Asserting true said nothing — and would keep
		; saying nothing on the day someone implements it, leaving the corpus vector
		; unverified on this driver forever. Assert the divergence instead, so it
		; fails the moment it stops being true.
		Body := _DriverFuncBody("KLW_WalkSystemEvent")
		Assert(InStr(Body, "manifest_increment") == 0,
			"KLW_WalkSystemEvent now handles manifest_increment — the vector is no longer a "
			. "documented divergence and must be asserted like every other one")
	}
	else if (Id = "mixed_batch_typing_and_system") {
		Row := _KlgAggCorpus_ReadAppDay("2024-07-02", "MixedApp")
		AssertTrue(Row != "", "app_day row exists")
		AssertEqual(1, KLW_GetMap(Row, "chars", 0), "chars = 1")
		Eg := _KlgAggCorpus_ReadErgo("2024-07-02", "MixedApp")
		AssertTrue(Eg != "", "ergo row exists")
		; AHK walker does not write focus_to_first_key_* columns — accepted
		; divergence (macOS-only feature, AHK walker handles modifier_hold +
		; system_day but not focus_first_key)
	}
	else {
		; An id with no branch used to fall straight off the end of this chain and
		; report green having asserted nothing. That is how a vector added to the
		; shared corpus would be "consumed" by this driver without being checked —
		; and it is the same silent-coverage shape the loop-capture bug produced,
		; which is why it is closed here too.
		Assert(false,
			"corpus vector '" . Id . "' has no branch in _KlgAggCorpus_RunVector — add one, or this driver silently ignores the case the vector was written for")
	}
}

_KlgAggCorpus_RegisterAll()




; ===============================================
; ===============================================
; ======= 9/ Pure Text Primitives ===============
; ===============================================
; ===============================================

; The vectors above replay whole event batches, which covers the pure text
; primitives only by implication — and an implication is exactly what let
; KLW_PopLast drop half a surrogate pair for years without one failing test.
; These two replay the shared corpus straight through the functions.

_KlgAggCorpus_CharClassVectors() {
	Data := _KlgAggCorpus_LoadCorpus()
	Cases := Data["primitives"]["char_class"]
	Assert(Cases.Length > 0, "the corpus must carry char_class vectors — an empty section asserts nothing")
	for _, Vector in Cases {
		AssertEqual(Vector["expect"], KLW_CharClass(Vector["input"]),
			"KLW_CharClass must agree with the shared core on " . Chr(34) . Vector["input"] . Chr(34)
			. ". This is the classifier every typing metric is bucketed by, and it is a hand-port: "
			. "a drift changes every downstream aggregate and reports nothing")
	}
}

_KlgAggCorpus_PopLastVectors() {
	Data := _KlgAggCorpus_LoadCorpus()
	Cases := Data["primitives"]["pop_utf8"]
	Assert(Cases.Length > 0, "the corpus must carry pop_utf8 vectors")
	for _, Vector in Cases {
		AssertEqual(Vector["expect"], KLW_PopLast(Vector["input"]),
			"KLW_PopLast must remove one whole CODEPOINT, as the shared core does. AutoHotkey "
			. "counts UTF-16 code units, so the astral vector is the one that already diverged: "
			. "dropping a single unit leaves half a surrogate pair in the word buffer")
	}
}

Test("keylogger corpus: char_class matches the shared core on every vector (walker-shared-core-parity)",
	_KlgAggCorpus_CharClassVectors)
Test("keylogger corpus: pop_utf8 removes a whole codepoint on every vector (walker-shared-core-parity)",
	_KlgAggCorpus_PopLastVectors)

_KlgAggCorpus_MalformedMinuteCannotAbortReplay() {
	SavedBatch := KLW.batch
	SavedCtx := KLW.ctx
	try {
		KLW_ResetBatch()
		KLW.ctx := Map()
		KLW_WalkTypingEntry(Map(
			"app", "MalformedTimeApp",
			"timestamp", "2024-06-01 14:xx:00.000",
			"events", [["a", 100, Map()]]))
		AssertTrue(_KlgAggCorpus_ReadHourly(
			"2024-06-01", "MalformedTimeApp", "14") is Map,
			"a malformed minute must not abort the durable replay")
		Min5Key := "2024-06-01" . Chr(1) . "MalformedTimeApp" . Chr(1) . "14:00"
		AssertTrue(KLW.batch["hourly_min5"].Has(Min5Key),
			"the AHK fallback must retain the cross-driver minute-zero policy")
	} finally {
		KLW.batch := SavedBatch
		KLW.ctx := SavedCtx
	}
}
Test("keylogger walker: malformed minutes cannot abort durable replay (walker-timestamp-fallback)",
	_KlgAggCorpus_MalformedMinuteCannotAbortReplay)

_KlgAggCorpus_FallbackTimeUsesOneInstant() {
	Bucket := _KLW_ResolveTypingTime("", "20241231235959")
	AssertEqual("2024-12-31", Bucket["date"])
	AssertEqual("23", Bucket["hour"])
	AssertEqual("23:55", Bucket["min5"],
		"date, hour, and minute fallbacks must derive from one clock snapshot")
}
Test("keylogger walker: fallback buckets sample one instant (walker-timestamp-fallback)",
	_KlgAggCorpus_FallbackTimeUsesOneInstant)
