; static/ergopti_plus/windows/tests/unit/test_metrics_seed_header.ahk

; ==============================================================================
; MODULE: Metrics Seed Header Tests
; DESCRIPTION: Provenance reads stay bounded and reject incomplete owned headers.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSH_Seed() {
	return Map("version", 2, "store", ConfigTransitionNormalizeConfigDir(A_Temp),
		"day", "2026-01-02", "ledgers", Map(), "walker_timings", KL_JsonEncode(KLW_TimingValues()))
}

_MSH_HeaderAtLimit(Extra := 0) {
	Base := '{"_history_seed":' . KL_JsonEncode(_MSH_Seed())
	Padding := KLPFWorker.MAX_SEED_HEADER_CHARS - StrLen(Base) - 1 + Extra
	Assert(Padding > 0, "fixture must leave room for valid JSON whitespace")
	return Base . Format("{:" . Padding . "}", "") . ",`n"
}

_MSH_ExactBoundary() {
	Header := _MSH_HeaderAtLimit()
	AssertEqual(KLPFWorker.MAX_SEED_HEADER_CHARS + 1, StrLen(Header))
	Seed := KLPF_ParseHistorySeedPrefix(Header)
	AssertEqual(2, Seed["version"])
	AssertEqual("2026-01-02", Seed["day"])
	AssertEqual(0, Seed["ledgers"].Count)
	AssertThrows(() => KLPF_ParseHistorySeedPrefix(_MSH_HeaderAtLimit(1)),
		"one character beyond the owned header budget must be rejected")
}
Test("metrics provenance: exact header budget admits no extra character (metrics-seed-header)",
	_MSH_ExactBoundary)

_MSH_MalformedHeaders() {
	for Prefix in ['{"_history_seed":{},', '{"_history_seed":{}`n',
		'{"_history_seed":false,`n', '{"_history_seed":{},"extra":1,`n',
		'{"_history_seed":{broken},`n'] {
		AssertThrows(KLPF_ParseHistorySeedPrefix.Bind(Prefix),
			"recognized but malformed provenance must not become a legacy cache miss")
	}
	AssertEqual(0, KLPF_ParseHistorySeedPrefix('{"_prefetch_data":{}}'),
		"a legacy payload has no trusted provenance, not a fabricated receipt")
}
Test("metrics provenance: malformed owned headers fail explicitly (metrics-seed-header)",
	_MSH_MalformedHeaders)

_MSH_FileReadIsBounded() {
	_KLRDC_Reset()
	try {
		Path := _KLRDC_Root() . "bounded-header.json"
		Header := _MSH_HeaderAtLimit()
		AssertTrue(FSWriteDurable(Path, Header . "not a JSON body"))
		Seed := KLPF_ReadHistorySeed(Path)
		AssertEqual("2026-01-02", Seed["day"],
			"reading provenance must not parse or depend on the historical body")
		AssertTrue(FSWriteDurable(Path, _MSH_HeaderAtLimit(1) . "{}"))
		AssertThrows(KLPF_ReadHistorySeed.Bind(Path), "bounded read must reject a missing terminator")
	} finally _KLRDC_Cleanup()
}
Test("metrics provenance: file reads stop at the header boundary (metrics-seed-header)",
	_KLRDC_CheckTeardown.Bind(_MSH_FileReadIsBounded))
