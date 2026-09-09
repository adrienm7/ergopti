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

_MPHP_CapturedProjectionDay() {
	global KLPF_MANIFEST_CACHE, Features
	SavedFeatures := Features
	HadCache := IsSet(KLPF_MANIFEST_CACHE)
	SavedCache := HadCache ? KLPF_MANIFEST_CACHE : 0
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Features := Map("layout", Map("ergopti_base", false))
		KLPF_MANIFEST_CACHE := unset
		Day := FormatTime(DateAdd(A_Now, -1, "Days"), "yyyy-MM-dd")
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 23:59:59.000", Day, "code.exe", ["a"]))
		Db := _KLRDC_BuildAsWorker()
		; Model a projection that captured its day before midnight, while
		; nested queries now see the following calendar day from the clock.
		Live := KLPF_BuildTyping(Db, "live", false, Day)
		Today := JsonParse(Live["__klpf_today_json"])
		AssertTrue(Live["metrics_manifest"].Has(Day))
		AssertTrue(Today.Has("code.exe"), "live data must use the outer captured day")
		AssertEqual(1, Today["code.exe"]["c"]["a"]["c"])
		Full := KLPF_BuildTyping(Db, "full", false, Day)["_prefetch_data"]
		AssertEqual(1, Full["today"]["code.exe"]["c"]["a"]["c"])
		AssertEqual(0, Full["historical"]["c"].Count,
			"captured-day typing must not also migrate into history")
		Complete := JsonParse(KLPF_BuildTyping(Db, "full", true, Day)["__klpf_prefetch_json"])
		AssertEqual(KL_JsonEncode(Full), KL_JsonEncode(Complete))
	} finally {
		Features := SavedFeatures
		KLPF_MANIFEST_CACHE := HadCache ? SavedCache : unset
		_KLRDC_Cleanup()
	}
}
Test("metrics prefetch: all projections use one captured day (metrics-projection-midnight)",
	_KLRDC_CheckTeardown.Bind(_MPHP_CapturedProjectionDay))

_MPHP_DeliverDelta(Root, Mode) {
	SavedJobs := KLPFWorker.jobs
	SavedSpawn := KLPFWorker.spawn_fn
	SavedWindows := KLWV.windows
	SavedPush := KLWV.first_paint_push_fn
	Stage := ""
	try {
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := (*) => {start: (*) => true, terminate: (*) => true}
		KLWV.first_paint_push_fn := 0
		View := _MCR_View(() => 0)
		KLWV.windows := Map("typing", Map("epoch", 71, "webview", View,
			"metrics_dir", Root, "first_paint_done", true, "full_build_done", true))
		Path := KLPF_PrefetchPath("typing", Root)
		KLWV.windows["typing"]["history_seed"] := KLPF_ReadHistorySeed(Path)
		Before := FileRead(Path, "UTF-8")
		AssertTrue(KLPF_RequestBuild("typing", Root, Mode, 71,
			KLWV_OnBuildTerminal.Bind("typing", 71)))
		Job := KLPFWorker.jobs["typing"]
		Stage := Job["stage"]
		AssertTrue(KLPF_BuildAndWriteToPath("typing", Root, Stage, Root . "probe.log", Mode))
		KLPF_OnWorkerDone("typing", Job["generation"], 0, "", "")
		AssertEqual(1, View.Messages.Length, "the actual terminal must deliver the private delta")
		Delta := JsonParse(View.Messages[1])["blob"]
		for Day, Apps in Delta["metrics_manifest"]
			AssertTrue(Apps.Has("__KLPF_TODAY_PLACEHOLDER__"),
				"an application key must not be interpreted as a serialization marker")
		if Mode = "live" {
			AssertTrue(Delta.Has("_prefetch_data"))
			AssertFalse(Delta["_prefetch_data"].Has("historical"),
				"delivery must read the delta stage, not the full RAM snapshot")
		} else {
			AssertFalse(Delta.Has("_prefetch_data"))
		}
		AssertEqual(Before, FileRead(Path, "UTF-8"), "a delta cannot replace the reusable full snapshot")
		AssertFalse(FSExists(Stage), "synchronous delivery must retire its private stage")
		AssertEqual(0, KLPFWorker.jobs.Count)
	} finally {
		if Stage != "" && FSExists(Stage)
			AssertTrue(FSDelete(Stage))
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.spawn_fn := SavedSpawn
		KLWV.windows := SavedWindows
		KLWV.first_paint_push_fn := SavedPush
	}
}

_MPHP_RefreshHistoricalAppend(Root, Mode) {
	SavedJobs := KLPFWorker.jobs
	SavedSpawn := KLPFWorker.spawn_fn
	SavedDrain := KLWV.ingest_drain_timer_fn
	SavedPush := KLWV.first_paint_push_fn
	try {
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := (*) => {start: (*) => true, terminate: (*) => true}
		KLWV.ingest_drain_timer_fn := (*) => true
		KLWV.first_paint_push_fn := 0
		AssertTrue(KLWV_CommitPaint("typing", 71, true))
		Entry := KLWV.windows["typing"]
		BeforeMessages := Entry["webview"].Messages.Length
		AssertTrue(KLWV_MarkIngestDirty("typing", 71, Mode))
		AssertTrue(KLWV_DrainPendingIngest("typing", 71))
		Job := KLPFWorker.jobs["typing"]
		AssertEqual(Mode, Job["mode"])
		Seed := JsonParse(FileRead(Job["request"], "UTF-8"))
		AssertEqual("full_required", KLPF_BuildAndWriteToPath("typing", Root, Job["stage"],
			Root . "probe.log", Mode, Seed))
		KLPF_OnWorkerDone("typing", Job["generation"], KLPFWorker.FULL_REQUIRED_EXIT_CODE, "", "")
		AssertFalse(Entry["full_build_done"])
		AssertEqual("full", Entry["pending_ingest_mode"])
		AssertEqual(BeforeMessages, Entry["webview"].Messages.Length,
			"an incompatible delta must not reach the current page")
		AssertFalse(FSExists(Job["request"]))
		AssertTrue(KLWV_DrainPendingIngest("typing", 71))
		Job := KLPFWorker.jobs["typing"]
		AssertEqual("full", Job["mode"], "the queued successor must rebuild history")
		AssertTrue(KLPF_BuildAndWriteToPath("typing", Root, Job["stage"], Root . "probe.log", "full"))
		KLPF_OnWorkerDone("typing", Job["generation"], 0, "", "")
		AssertTrue(Entry["full_build_done"])
		AssertEqual(BeforeMessages + 1, Entry["webview"].Messages.Length)
		AssertEqual(KL_JsonEncode(Entry["last_delivery_seed"]), KL_JsonEncode(Entry["history_seed"]))
	} finally {
		KLPF_CancelBuild("typing")
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.spawn_fn := SavedSpawn
		KLWV.ingest_drain_timer_fn := SavedDrain
		KLWV.first_paint_push_fn := SavedPush
	}
}

_MPHP_ReopenedHistory(Mode) {
	global KLPF_MANIFEST_CACHE, KLPF_LAST_JSON, Features
	SavedFeatures := Features
	SavedWindows := KLWV.windows
	HadManifest := IsSet(KLPF_MANIFEST_CACHE)
	SavedManifest := HadManifest ? KLPF_MANIFEST_CACHE : 0
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	SnapshotPath := ""
	OwnsSnapshot := false
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Features := Map("layout", Map("ergopti_base", false))
		KLPF_MANIFEST_CACHE := unset
		KLPF_LAST_JSON := Map()
		Yesterday := FormatTime(DateAdd(A_Now, -1, "Days"), "yyyy-MM-dd")
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Yesterday . " 10:00:00.000", Yesterday,
				"code.exe", ["a", "b", "c"])
			. _KLRDC_TypingBatch(2, Yesterday . " 10:00:02.000", Yesterday,
				"__KLPF_PREFETCH_PLACEHOLDER__", ["z"])
			. _KLRDC_TypingBatch(3, Yesterday . " 10:00:03.000", Yesterday,
				"__KLPF_TODAY_PLACEHOLDER__", ["q"]))
		Root := _KLRDC_Root()
		SnapshotPath := KLPF_PrefetchPath("typing", Root)
		AssertFalse(FSExists(SnapshotPath), "fixture must exclusively own its snapshot")
		OwnsSnapshot := true
		KLRCache.disposable := true
		AssertTrue(KLPF_BuildAndWrite("typing", Root, Root . "probe.log", "full"))
		Full := JsonParse(FileRead(SnapshotPath, "UTF-8"))
		Seed := KLPF_ReadHistorySeed(SnapshotPath)
		AssertTrue(Seed is Map, "a complete snapshot must carry readable provenance")
		AssertEqual(KL_JsonEncode(Full["_history_seed"]), KL_JsonEncode(Seed),
			"bounded header reading must recover the receipt published with the payload")
		History := Full["_prefetch_data"]["historical"]
		Assert(History.Count > 0, "positive control: yesterday must produce historical tables")
		AssertEqual(1, History["c"]["a"]["c"], "positive control: yesterday's actual typing must survive")
		Assert(Full["metrics_manifest"][Yesterday].Has("__KLPF_PREFETCH_PLACEHOLDER__"),
			"an application named like an internal marker must remain valid JSON")
		_MPHP_DeliverDelta(Root, Mode)
		; A new page has no closure holding the preceding full payload. Drop RAM
		; too so this exercises the durable bytes rather than a same-process cache.
		KLPF_LAST_JSON := Map()
		View := _MCR_View(() => 0)
		KLWV.windows := Map("typing", Map("epoch", 71, "webview", View,
			"metrics_dir", Root))
		AssertTrue(KLWV_PushPrefetch("typing", (*) => 0, 71))
		AssertEqual(1, View.Messages.Length)
		Delivered := JsonParse(View.Messages[1])["blob"]
		Assert(Delivered.Has("_prefetch_data")
			&& Delivered["_prefetch_data"].Has("historical"),
			"a reopened dashboard must receive history before a new full rebuild")
		AssertEqual(KL_JsonEncode(History), KL_JsonEncode(Delivered["_prefetch_data"]["historical"]))
		_TestPrint("# history_snapshot " . Mode . " " . KL_JsonEncode(Delivered))
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(4, Yesterday . " 10:00:04.000", Yesterday,
			"code.exe", ["d"]))
		KLR_ResetCache()
		KLRCache.disposable := true
		_MPHP_RefreshHistoricalAppend(Root, Mode)
		Changed := JsonParse(FileRead(SnapshotPath, "UTF-8"))
		AssertEqual(1, Changed["_prefetch_data"]["historical"]["c"]["d"]["c"],
			"a historical-day append must not reuse stale cached tables")
		_KLRDC_WriteLedger(_KLRDC_Header())
		KLR_ResetCache()
		KLRCache.disposable := true
		AssertTrue(KLPF_BuildAndWrite("typing", Root, Root . "probe.log", "full"))
		_MPHP_DeliverDelta(Root, Mode)
		KLPF_LAST_JSON := Map()
		View.Messages := []
		AssertTrue(KLWV_PushPrefetch("typing", (*) => 0, 71))
		Cleared := JsonParse(View.Messages[1])["blob"]
		AssertEqual(0, Cleared["_prefetch_data"]["historical"]["c"].Count,
			"an explicit empty rebuild must not resurrect old history on later refresh")
		_TestPrint("# history_snapshot " . Mode . "-cleared " . KL_JsonEncode(Cleared))
	} finally {
		Features := SavedFeatures
		KLWV.windows := SavedWindows
		KLPF_MANIFEST_CACHE := HadManifest ? SavedManifest : unset
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		if OwnsSnapshot && FSExists(SnapshotPath)
			AssertTrue(FSDelete(SnapshotPath))
		_KLRDC_Cleanup()
	}
}
for Mode in ["live", "manifest"]
	Test("metrics prefetch: reopen after " . Mode . " retains history (metrics-history-reopen)",
		_KLRDC_CheckTeardown.Bind(_MPHP_ReopenedHistory.Bind(Mode)))
