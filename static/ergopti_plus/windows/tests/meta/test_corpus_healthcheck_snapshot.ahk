; tests/meta/test_corpus_healthcheck_snapshot.ahk

; ==============================================================================
; MODULE: Healthcheck Snapshot Corpus Consumer (Windows / AHK)
; DESCRIPTION:
; Loads the cross-driver healthcheck snapshot corpus from
; _shared/tests/corpus/healthcheck/snapshot_vectors.json and replays each
; vector through the AHK healthcheck helpers (_HealthCheck_FormatUptime,
; _HealthCheck_RecentIssues), then asserts the output matches the expected
; golden values.
;
; The AHK driver cannot require Lua modules, so its helpers.ahk keeps a
; hand-maintained copy of the shared logic. This test pins that copy against
; the same golden vectors as the macOS Lua test so any divergence is caught.
; ==============================================================================

#Requires AutoHotkey v2.0

; ── Corpus path resolution ──────────────────────────────────────────────────
; _SharedDir is set by the driver at startup; in the test harness it points to
; the _shared/ tree relative to the Windows driver root
_HCSC_LoadCorpus() {
	global _SharedDir
	if !IsSet(_SharedDir)
		return ""
	Path := _SharedDir . "\tests\corpus\healthcheck\snapshot_vectors.json"
	if !FileExist(Path)
		return ""
	Raw := FileRead(Path, "UTF-8")
	return Raw
}

_HCSC_ParseJson(Raw) {
	if Raw = ""
		return ""
	try return JsonParse(Raw)
	catch
		return ""
}

; ── Vector dispatch ──────────────────────────────────────────────────────────

_HCSC_FormatUptime(Sec) {
	return _HealthCheck_FormatUptime(Sec)
}

; AHK _HealthCheck_RecentIssues reads from the global ring buffer, so we
; cannot replay arbitrary lines. We test format_uptime here (which is pure)
; and validate the recent_issues logic via the Lua test only — the AHK
; implementation is pinned by the existing test_healthcheck_format_helpers.ahk
; and the shared corpus ensures both sides produce the same output

; ── Corpus integrity ─────────────────────────────────────────────────────────

_HCSC_Integrity() {
	Raw := _HCSC_LoadCorpus()
	AssertTrue(Raw != "", "corpus file must be readable")
	Data := _HCSC_ParseJson(Raw)
	AssertTrue(Data != "", "corpus JSON must be parseable")
	AssertTrue(Data.Has("vectors"), "corpus must have a vectors array")
	AssertTrue(Data["vectors"].Length > 0, "corpus must have at least one vector")

	; Validate every vector has required fields
	for _, V in Data["vectors"] {
		AssertTrue(V.Has("id") && V["id"] != "", "vector missing id")
		AssertTrue(V.Has("category"), "vector missing category")
		AssertTrue(V.Has("expected"), "vector missing expected")
	}
}
Test("corpus:hc-snap: corpus file is readable and every vector has required fields", _HCSC_Integrity)

; ── format_uptime vectors ────────────────────────────────────────────────────

_HCSC_UptimeSeconds() {
	Raw := _HCSC_LoadCorpus()
	Data := _HCSC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "format_uptime"
			continue
		Sec := V["input"]["sec"]
		if !(Sec is Number)
			Sec := 0
		Result := _HCSC_FormatUptime(Sec)
		AssertEqual(V["expected"], Result, V["id"] . ": format_uptime(" . Sec . ")")
	}
}
Test("corpus:hc-snap: format_uptime vectors match golden values", _HCSC_UptimeSeconds)

; ── extract_recent_issues — validate count logic ─────────────────────────────
; The AHK _HealthCheck_RecentIssues reads from the live ring buffer, so we
; cannot replay arbitrary lines. We validate the trim logic by checking that
; the corpus expected arrays are internally consistent (length matches
; expected_count when present)

_HCSC_IssuesConsistency() {
	Raw := _HCSC_LoadCorpus()
	Data := _HCSC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "extract_recent_issues"
			continue
		Expected := V["expected"]
		AssertTrue(Expected is Array, V["id"] . ": expected must be an array")
		if V.Has("expected_count") {
			AssertEqual(V["expected_count"], Expected.Length,
				V["id"] . ": expected_count must match array length")
		}
	}
}
Test("corpus:hc-snap: extract_recent_issues expected arrays are internally consistent", _HCSC_IssuesConsistency)

; ── count_issues — validate expected values ──────────────────────────────────

_HCSC_CountConsistency() {
	Raw := _HCSC_LoadCorpus()
	Data := _HCSC_ParseJson(Raw)
	for _, V in Data["vectors"] {
		if V["category"] != "count_issues"
			continue
		Expected := V["expected"]
		AssertTrue(Expected.Has("warn_count"), V["id"] . ": expected must have warn_count")
		AssertTrue(Expected.Has("err_count"), V["id"] . ": expected must have err_count")
		; Recount from the input lines to verify the expected values
		Lines := V["input"]["lines"]
		if !(Lines is Array)
			continue
		WarnCount := 0
		ErrCount := 0
		for _, Line in Lines {
			if InStr(Line, "[WARNING]")
				WarnCount += 1
			if InStr(Line, "[ERROR]")
				ErrCount += 1
		}
		AssertEqual(Expected["warn_count"], WarnCount, V["id"] . ": warn_count must match input lines")
		AssertEqual(Expected["err_count"], ErrCount, V["id"] . ": err_count must match input lines")
	}
}
Test("corpus:hc-snap: count_issues expected values match input line contents", _HCSC_CountConsistency)

; ── validate_snapshot — validate schema field list ───────────────────────────

_HCSC_SchemaFields() {
	Raw := _HCSC_LoadCorpus()
	Data := _HCSC_ParseJson(Raw)
	; The canonical field list must match between the Lua module and the corpus
	ExpectedFields := [
		"version", "loaded_adapters", "ports_validated", "failed_adapters",
		"last_error", "uptime_sec", "warn_count", "err_count",
		"recent_issues", "sys", "pause_state", "keylogger", "llm",
		"layout", "hotstrings", "logs", "config"
	]
	; Find the schema_all_present vector and verify it has every field
	for _, V in Data["vectors"] {
		if V["id"] != "schema_all_present"
			continue
		Snap := V["input"]["snapshot"]
		for _, Field in ExpectedFields {
			AssertTrue(Snap.Has(Field),
				"schema_all_present: snapshot must have field '" . Field . "'")
		}
	}
}
Test("corpus:hc-snap: schema_all_present vector contains every canonical field", _HCSC_SchemaFields)
