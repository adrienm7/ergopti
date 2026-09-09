; static/ergopti_plus/windows/tests/unit/test_metrics_store_projection.ahk

; ==============================================================================
; MODULE: Metrics Store Projection Tests
; DESCRIPTION: Real SQLite projection publishes RAM under its store-qualified key.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSPR_RealProjectionRetainsStore(RefusePublication := false) {
	global KLPF_LAST_JSON, KLPF_MANIFEST_CACHE, Features
	SavedFeatures := Features
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	HadManifest := IsSet(KLPF_MANIFEST_CACHE)
	SavedManifest := HadManifest ? KLPF_MANIFEST_CACHE : 0
	LockHandle := 0
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Features := Map("layout", Map("ergopti_base", false))
		KLPF_LAST_JSON := Map()
		KLPF_MANIFEST_CACHE := unset
		KLRCache.disposable := true
		Root := _KLRDC_Root()
		Path := Root . "snapshot.json"
		CacheKey := KLPF_PrefetchPath("typing", Root)
		if RefusePublication {
			LastGood := '{"metrics_manifest":{},"revision":"last-good"}'
			KLPF_LAST_JSON[CacheKey] := LastGood
			AssertTrue(FSWrite(Path, LastGood))
			LockHandle := DllCall("CreateFileW", "Str", Path,
				"UInt", 0x80000000, "UInt", 3, "Ptr", 0, "UInt", 3,
				"UInt", 0x80, "Ptr", 0, "Ptr")
			Assert(LockHandle && LockHandle != -1,
				"positive control: the snapshot must deny replacement while permitting reads")
			AssertFalse(KLPF_BuildAndWriteToPath("typing", Root, Path, Root . "probe.log", "full"))
			AssertEqual(LastGood, FileRead(Path, "UTF-8"), "failed publication must preserve disk")
			AssertEqual(LastGood, KLPF_LAST_JSON[CacheKey],
				"failed publication must not expose uncommitted JSON through RAM")
			Assert(DllCall("CloseHandle", "Ptr", LockHandle, "Int"))
			LockHandle := 0
		}
		AssertTrue(KLPF_BuildAndWriteToPath("typing", Root, Path, Root . "probe.log", "full"))
		AssertTrue(KLPF_LAST_JSON.Has(CacheKey), "the real producer must use its store-qualified RAM key")
		AssertFalse(KLPF_LAST_JSON.Has("typing"), "no unqualified RAM copy may survive publication")
		AssertEqual(FileRead(Path, "UTF-8"), KLPF_LAST_JSON[CacheKey])
		if RefusePublication
			Assert(KLPF_LAST_JSON[CacheKey] != LastGood,
				"releasing the lock must allow the same producer to publish new data")
	} finally {
		if LockHandle && LockHandle != -1
			Assert(DllCall("CloseHandle", "Ptr", LockHandle, "Int"))
		Features := SavedFeatures
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		KLPF_MANIFEST_CACHE := HadManifest ? SavedManifest : unset
		_KLRDC_Cleanup()
	}
}
Test("metrics projection: real producer qualifies its RAM snapshot (metrics-store-isolation)",
	_KLRDC_CheckTeardown.Bind(_MSPR_RealProjectionRetainsStore))
Test("metrics projection: refused write preserves last good RAM (metrics-projection-write-refusal)",
	_KLRDC_CheckTeardown.Bind(_MSPR_RealProjectionRetainsStore.Bind(true)))
