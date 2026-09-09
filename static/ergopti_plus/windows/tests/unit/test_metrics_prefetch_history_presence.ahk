; static/ergopti_plus/windows/tests/unit/test_metrics_prefetch_history_presence.ahk

; ==============================================================================
; MODULE: Metrics Prefetch History Presence Tests
; DESCRIPTION: Omitted history preserves the page cache; explicit history replaces it.
; ==============================================================================

#Requires AutoHotkey v2.0

_MPHP_ProducerModes() {
	global KLPF_MANIFEST_CACHE, Features
	SavedFeatures := Features
	HadCache := IsSet(KLPF_MANIFEST_CACHE)
	SavedCache := HadCache ? KLPF_MANIFEST_CACHE : 0
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		; The headless harness does not load the optional Ergopti layout labels.
		Features := Map("layout", Map("ergopti_base", false))
		_KLRDC_WriteLedger(_KLRDC_Header())
		Db := _KLRDC_BuildAsWorker()
		KLPF_MANIFEST_CACHE := unset
		Full := KLPF_BuildTyping(Db, "full")
		AssertTrue(Full["_prefetch_data"].Has("historical"))
		AssertEqual(0, Full["_prefetch_data"]["historical"].Count,
			"a full empty database must explicitly clear old page history")
		Live := KLPF_BuildTyping(Db, "live")
		AssertTrue(Live["_prefetch_data"].Has("today"))
		AssertFalse(Live["_prefetch_data"].Has("historical"),
			"a live delta must omit history rather than impersonating an empty full snapshot")
		AssertFalse(KLPF_BuildTyping(Db, "manifest").Has("_prefetch_data"))
	} finally {
		Features := SavedFeatures
		KLPF_MANIFEST_CACHE := HadCache ? SavedCache : unset
		_KLRDC_Cleanup()
	}
}
Test("metrics prefetch: historical presence distinguishes replacement from delta (metrics-history-presence)",
	_KLRDC_CheckTeardown.Bind(_MPHP_ProducerModes))
