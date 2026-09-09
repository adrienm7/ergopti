; static/ergopti_plus/windows/tests/unit/test_metrics_store_edge.ahk

; ==============================================================================
; MODULE: Metrics Edge Store Tests
; DESCRIPTION: A fallback URL and its worker must retain the same store owner.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSE_LaunchRetainsResolvedStore() {
	global _ConfigDir
	SavedConfig := _ConfigDir
	SavedJobs := KLPFWorker.jobs
	SavedSpawn := KLPFWorker.spawn_fn
	SavedGeneration := KLPFWorker.generation
	SavedPending := KLUI.pending
	SavedTyping := KLUI.typing_url
	SavedApps := KLUI.apps_url
	StoreA := A_Temp . "\ergopti_edge_store_a_" . A_ScriptHwnd
	StoreB := A_Temp . "\ergopti_edge_store_b_" . A_ScriptHwnd
	SpawnArgs := []
	Spawn(Exe, Args, Done) {
		SpawnArgs.Push(Args)
		return {start: (*) => true, terminate: (*) => true}
	}
	try {
		_KLRDC_EnsureSharedDir()
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := Spawn
		KLUI.pending := Map()
		KLUI_EnsureUrls(StoreA)
		UrlA := KLUI.typing_url
		KLUI_EnsureUrls(StoreB)
		AssertFalse(UrlA == KLUI.typing_url, "opening another store must refresh cached Edge URLs")
		AssertContains(KLUI.typing_url, StrReplace(KLPF_PrefetchPath("typing", StoreB), "\", "/"))
		_ConfigDir := StoreB . "\"
		KLUI_LaunchWindow(UrlA, "fixture", StoreA)
		AssertEqual(1, SpawnArgs.Length)
		AssertEqual(StoreA, SpawnArgs[1][6],
			"a config change after URL resolution must not redirect the fallback worker")
		AssertEqual(KLPF_PrefetchPath("typing", StoreA), KLPFWorker.jobs["typing"]["destination"])
	} finally {
		KLUI.pending := Map()
		KLPF_CancelAll()
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.generation := SavedGeneration
		KLUI.pending := SavedPending
		KLUI.typing_url := SavedTyping
		KLUI.apps_url := SavedApps
		_ConfigDir := SavedConfig
	}
}
Test("metrics Edge: launch retains its URL's store (metrics-store-isolation)",
	_MSE_LaunchRetainsResolvedStore)
