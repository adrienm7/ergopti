; static/ergopti_plus/windows/tests/unit/test_metrics_store_edge.ahk

; ==============================================================================
; MODULE: Metrics Edge Store Tests
; DESCRIPTION: A fallback URL and its worker must retain the same store owner.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSE_LaunchRetainsResolvedStore(Replace := false, Which := "typing") {
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
		UrlA := Which = "typing" ? KLUI.typing_url : KLUI.apps_url
		KLUI_EnsureUrls(StoreB)
		UrlB := Which = "typing" ? KLUI.typing_url : KLUI.apps_url
		AssertFalse(UrlA == UrlB, "opening another store must refresh cached Edge URLs")
		AssertContains(UrlB, StrReplace(KLPF_PrefetchPath(Which, StoreB), "\", "/"))
		_ConfigDir := StoreB . "\"
		KLUI_LaunchWindow(UrlA, "fixture", StoreA)
		AssertEqual(1, SpawnArgs.Length)
		AssertEqual(StoreA, SpawnArgs[1][6],
			"a config change after URL resolution must not redirect the fallback worker")
		AssertEqual(KLPF_PrefetchPath(Which, StoreA), KLPFWorker.jobs[Which]["destination"])
		if Replace {
			Previous := KLPFWorker.jobs[Which]
			KLUI_LaunchWindow(UrlA, "replacement", StoreA)
			AssertEqual(2, SpawnArgs.Length, "the replacement worker must start")
			Assert(KLPFWorker.jobs[Which] != Previous, "the new worker must own a distinct job")
			AssertTrue(KLUI.pending.Has(Which), "the canceled predecessor must not erase its successor's launch")
			CurrentIntent := KLUI.pending[Which]
			Previous["on_terminal"].Call("canceled")
			AssertTrue(KLUI.pending.Has(Which), "a repeated stale terminal must remain inert")
			AssertTrue(KLUI.pending[Which] == CurrentIntent)
		}
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
for Which in ["typing", "apps"]
	Test("metrics Edge: replaced " . Which . " launch retains its own intent (metrics-edge-replace)",
		_MSE_LaunchRetainsResolvedStore.Bind(true, Which))

_MSE_CancelPendingProjection(Which, CloseAll := false) {
	global _ConfigDir
	SavedConfig := _ConfigDir
	SavedJobs := KLPFWorker.jobs
	SavedSpawn := KLPFWorker.spawn_fn
	SavedGeneration := KLPFWorker.generation
	SavedPending := KLUI.pending
	SavedTyping := KLUI.typing_url
	SavedApps := KLUI.apps_url
	SavedWindows := KLWV.windows
	SavedTypingOwner := KLUI.typing_owner
	SavedAppsOwner := KLUI.apps_owner
	HadAvailable := KLWV.HasOwnProp("available")
	SavedAvailable := HadAvailable ? KLWV.available : ""
	Terminals := []
	Attempt := Map()
	Terminal(Status, *) {
		Terminals.Push(Status)
		KLUI_OnPrefetchTerminal(Which, "unused", "fixture", Attempt, Status)
	}
	try {
		_KLRDC_EnsureSharedDir()
		_ConfigDir := A_Temp . "\ergopti_edge_cancel_" . A_ScriptHwnd . "\"
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := (*) => {start: (*) => true, terminate: (*) => true}
		KLWV.available := false
		KLWV.windows := Map()
		KLUI.typing_owner := 0
		KLUI.apps_owner := 0
		KLUI.pending := Map(Which, Attempt)
		AssertTrue(KLPF_RequestBuild(Which, _ConfigDir . "metrics", "full", 0, Terminal))
		AssertTrue(KLPFWorker.jobs.Has(Which))
		if CloseAll
			KLUI_CloseAll()
		else
			KLUI_ToggleDashboard(Which, "fixture")
		AssertEqual(1, Terminals.Length, "cancel must complete the existing worker exactly once")
		AssertEqual("canceled", Terminals[1])
		AssertFalse(KLUI.pending.Has(Which), "the launch intent must be retired")
		AssertFalse(KLPFWorker.jobs.Has(Which), "the worker must be retired without launching Edge")
	} finally {
		KLUI.pending := Map()
		KLPF_CancelAll()
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.generation := SavedGeneration
		KLUI.pending := SavedPending
		KLUI.typing_url := SavedTyping
		KLUI.apps_url := SavedApps
		KLWV.windows := SavedWindows
		KLUI.typing_owner := SavedTypingOwner
		KLUI.apps_owner := SavedAppsOwner
		if HadAvailable
			KLWV.available := SavedAvailable
		else
			KLWV.DeleteProp("available")
		_ConfigDir := SavedConfig
	}
}
for Which in ["typing", "apps"]
	Test("metrics Edge: cancel pending " . Which . " projection once (metrics-edge-cancel)",
		_MSE_CancelPendingProjection.Bind(Which))
for Which in ["typing", "apps"]
	Test("metrics Edge: close all retires pending " . Which . " projection (metrics-edge-close-all)",
		_MSE_CancelPendingProjection.Bind(Which, true))
