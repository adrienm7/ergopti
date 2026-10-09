; static/ergopti_plus/windows/tests/unit/test_metrics_store_publication.ahk

; ==============================================================================
; MODULE: Metrics Store Publication Tests
; DESCRIPTION: Worker publication and cache clearing retain their captured store.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MSP_ClearMessage {
	TryGetWebMessageAsString() {
		return '{"action":"clear_cache"}'
	}
}

_MSP_StoreTransaction(Mode) {
	global KLPF_LAST_JSON, KLPF_MANIFEST_CACHE, _ConfigDir
	SavedConfig := _ConfigDir
	SavedWindows := KLWV.windows
	SavedDir := KLWV.metrics_dir
	SavedJobs := KLPFWorker.jobs
	SavedGeneration := KLPFWorker.generation
	SavedSpawn := KLPFWorker.spawn_fn
	SavedPublish := KLPFWorker.publish_fn
	LockHandle := 0
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	HadManifest := IsSet(KLPF_MANIFEST_CACHE)
	SavedManifest := HadManifest ? KLPF_MANIFEST_CACHE : 0
	StoreA := A_Temp . "\ergopti_store_tx_a_" . A_ScriptHwnd . "_" . Mode
	StoreB := A_Temp . "\ergopti_store_tx_b_" . A_ScriptHwnd . "_" . Mode
	PathA := KLPF_PrefetchPath("typing", StoreA)
	PathB := KLPF_PrefetchPath("typing", StoreB)
	for Path in [PathA, PathB]
		AssertFalse(FSExists(Path), "fixture must not overwrite another store's snapshot")
	CreatedPaths := []
	SpawnArgs := []
	Terminals := []
	Deliveries := []
	MemoryA := '{"metrics_manifest":{},"revision":"memory-A"}'
	NewA := '{"metrics_manifest":{},"revision":"new-A"}'
	OnTerminal(Status, *) {
		Terminals.Push(Status)
		Deliveries.Push(KLWV_PushPrefetch("typing", (*) => 0, 41))
	}
	Spawn(Exe, Args, Done) {
		SpawnArgs.Push(Args)
		return {start: (*) => true, terminate: (*) => true}
	}
	try {
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := Spawn
		KLPFWorker.publish_fn := 0
		KLPF_LAST_JSON := Map(PathA, MemoryA, PathB, "memory-B")
		AssertTrue(FSWrite(PathA, "disk-A"))
		CreatedPaths.Push(PathA)
		AssertTrue(FSWrite(PathB, "disk-B"))
		CreatedPaths.Push(PathB)
		if Mode != "clear" {
			View := _MCR_View(() => 0)
			KLWV.windows := Map("typing", Map("epoch", 41, "webview", View,
				"metrics_dir", StoreA))
			if Mode = "publish-refused"
				KLPFWorker.publish_fn := (*) => false
			if Mode = "publish-locked" {
				LockHandle := DllCall("CreateFileW", "Str", PathA,
					"UInt", 0x80000000, "UInt", 3, "Ptr", 0, "UInt", 3,
					"UInt", 0x80, "Ptr", 0, "Ptr")
				Assert(LockHandle && LockHandle != -1, "the native target handle must deny replacement")
			}
			AssertTrue(KLPF_RequestBuild("typing", StoreA, "full", 0,
				OnTerminal))
			Job := KLPFWorker.jobs["typing"]
			CreatedPaths.Push(Job["stage"])
			AssertTrue(FSWrite(Job["stage"], NewA))
			KLWV.metrics_dir := StoreB
			_ConfigDir := StoreB . "\"
			KLPF_OnWorkerDone("typing", Job["generation"], 0, "", "")
			AssertEqual(1, Terminals.Length)
			Published := Mode = "publish"
			AssertEqual(Published ? "ok" : "failed", Terminals[1])
			AssertEqual(Published ? NewA : "disk-A", FileRead(PathA, "UTF-8"),
				"completion must publish to the store captured before configuration changed")
			AssertEqual("disk-B", FileRead(PathB, "UTF-8"))
			AssertEqual("memory-B", KLPF_LAST_JSON[PathB], "publication must preserve another store's RAM")
			AssertEqual(1, Deliveries.Length, "the terminal must attempt delivery before completion returns")
			AssertTrue(Deliveries[1])
			AssertEqual(1, View.Messages.Length)
			AssertEqual(Published ? "new-A" : "memory-A", JsonParse(View.Messages[1])["blob"]["revision"],
				"terminal delivery must see the new publication, or retain the last good RAM on failure")
			if !Published
				AssertEqual(MemoryA, KLPF_LAST_JSON[PathA], "failed publication must preserve the owning store's RAM")
			AssertFalse(KLPFWorker.jobs.Has("typing"))
			AssertFalse(FSExists(Job["stage"]), "terminal publication must retire its private stage")
			if Mode = "publish-locked" {
				Assert(DllCall("CloseHandle", "Ptr", LockHandle, "Int"))
				LockHandle := 0
				AssertTrue(KLPF_RequestBuild("typing", StoreA, "full", 0, OnTerminal))
				Retry := KLPFWorker.jobs["typing"]
				CreatedPaths.Push(Retry["stage"])
				AssertTrue(Retry["generation"] != Job["generation"])
				AssertTrue(FSWrite(Retry["stage"], NewA))
				KLPF_OnWorkerDone("typing", Job["generation"], 0, "", "")
				AssertEqual(1, Terminals.Length, "late completion must not deliver another failure or steal the retry")
				AssertTrue(KLPFWorker.jobs["typing"] == Retry)
				AssertTrue(FSExists(Retry["stage"]))
				KLPF_OnWorkerDone("typing", Retry["generation"], 0, "", "")
				AssertEqual(2, Terminals.Length)
				AssertEqual("ok", Terminals[2], "the real rename must recover after the target handle closes")
				AssertEqual(NewA, FileRead(PathA, "UTF-8"))
				AssertEqual("disk-B", FileRead(PathB, "UTF-8"))
				AssertEqual("memory-B", KLPF_LAST_JSON[PathB])
				AssertEqual(2, View.Messages.Length)
				AssertEqual("new-A", JsonParse(View.Messages[2])["blob"]["revision"])
				AssertFalse(FSExists(Retry["stage"]))
				AssertFalse(KLPFWorker.jobs.Has("typing"))
			}
		} else {
			AssertEqual(0, KLRCache.db, "clear fixture must not close an unrelated reader")
			View := _MCR_View(() => 0)
			KLWV.windows := Map("typing", Map("epoch", 41, "webview", View,
				"metrics_dir", StoreB, "first_paint_done", true))
			KLWV.metrics_dir := StoreA
			KLWV_OnWebMessage("typing", 41, View, _MSP_ClearMessage())
			AssertFalse(FSExists(PathB), "clear must remove only its window's disk snapshot")
			AssertFalse(KLPF_LAST_JSON.Has(PathB))
			AssertEqual("disk-A", FileRead(PathA, "UTF-8"))
			AssertEqual(MemoryA, KLPF_LAST_JSON[PathA])
			AssertEqual(1, SpawnArgs.Length)
			AssertEqual(StoreB, SpawnArgs[1][6], "refresh must use the window's store, not the global")
			AssertEqual(PathB, KLPFWorker.jobs["typing"]["destination"])
		}
	} finally {
		if LockHandle && LockHandle != -1
			Assert(DllCall("CloseHandle", "Ptr", LockHandle, "Int"))
		; Retire the fake worker after removing its window so cancellation arms no retry.
		KLWV.windows := Map()
		KLPF_CancelAll()
		KLWV.windows := SavedWindows
		KLWV.metrics_dir := SavedDir
		_ConfigDir := SavedConfig
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.generation := SavedGeneration
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.publish_fn := SavedPublish
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		KLPF_MANIFEST_CACHE := HadManifest ? SavedManifest : unset
		for Path in CreatedPaths {
			if FSExists(Path)
				AssertTrue(FSDelete(Path))
		}
	}
}
for Mode in ["publish", "publish-refused", "publish-locked", "clear"]
	Test("metrics cache: " . Mode . " retains its store owner (metrics-store-isolation)",
		_MSP_StoreTransaction.Bind(Mode))
