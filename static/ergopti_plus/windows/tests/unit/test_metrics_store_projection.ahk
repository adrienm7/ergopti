; static/ergopti_plus/windows/tests/unit/test_metrics_store_projection.ahk

; ==============================================================================
; MODULE: Metrics Store Projection Tests
; DESCRIPTION: Real SQLite projection publishes RAM under its store-qualified key.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSPR_RealProjectionRetainsStore() {
	global KLPF_LAST_JSON, KLPF_MANIFEST_CACHE, Features
	SavedFeatures := Features
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	HadManifest := IsSet(KLPF_MANIFEST_CACHE)
	SavedManifest := HadManifest ? KLPF_MANIFEST_CACHE : 0
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Features := Map("layout", Map("ergopti_base", false))
		KLPF_LAST_JSON := Map()
		KLPF_MANIFEST_CACHE := unset
		KLRCache.disposable := true
		Root := _KLRDC_Root()
		Path := Root . "snapshot.json"
		AssertTrue(KLPF_BuildAndWriteToPath("typing", Root, Path, Root . "probe.log", "manifest"))
		CacheKey := KLPF_PrefetchPath("typing", Root)
		AssertTrue(KLPF_LAST_JSON.Has(CacheKey), "the real producer must use its store-qualified RAM key")
		AssertFalse(KLPF_LAST_JSON.Has("typing"), "no unqualified RAM copy may survive publication")
		AssertEqual(FileRead(Path, "UTF-8"), KLPF_LAST_JSON[CacheKey])
	} finally {
		Features := SavedFeatures
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		KLPF_MANIFEST_CACHE := HadManifest ? SavedManifest : unset
		_KLRDC_Cleanup()
	}
}
Test("metrics projection: real producer qualifies its RAM snapshot (metrics-store-isolation)",
	_KLRDC_CheckTeardown.Bind(_MSPR_RealProjectionRetainsStore))
