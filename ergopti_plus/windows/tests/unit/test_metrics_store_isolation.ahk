; static/ergopti_plus/windows/tests/unit/test_metrics_store_isolation.ahk

; ==============================================================================
; MODULE: Metrics Store Isolation Tests
; DESCRIPTION: Opening another store must not paint a previous store's sidecar.
; ==============================================================================

#Requires AutoHotkey v2.0

_MSI_ReadyRejectsForeignStore(Mode) {
	global KLPF_LAST_JSON
	SavedWindows := KLWV.windows
	SavedDir := KLWV.metrics_dir
	SavedTimer := KLWV.full_build_timer_fn
	SavedJobs := KLPFWorker.jobs
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	Which := "store_isolation_" . A_ScriptHwnd . "_" . Mode
	StoreA := A_Temp . "\ergopti_metrics_store_a_" . A_ScriptHwnd
	StoreB := A_Temp . "\ergopti_metrics_store_b_" . A_ScriptHwnd
	Path := KLPF_PrefetchPath(Which, StoreA)
	PathB := KLPF_PrefetchPath(Which, StoreB)
	LegacyPath := A_Temp . "\ergopti_metrics_prefetch_" . Which . ".json"
	AssertFalse(FSExists(Path), "fixture must not overwrite another owner's sidecar")
	AssertFalse(FSExists(PathB))
	AssertFalse(FSExists(LegacyPath))
	CreatedPaths := []
	try {
		_KLRDC_EnsureSharedDir()
		KLPF_LAST_JSON := Map()
		BodyA := '{"metrics_manifest":{},"store":"A"}'
		if Mode = "ram"
			KLPF_LAST_JSON[Path] := BodyA
		else {
			AssertTrue(FSWrite(Path, BodyA))
			CreatedPaths.Push(Path)
		}
		if Mode = "legacy" {
			AssertTrue(FSWrite(LegacyPath, BodyA))
			CreatedPaths.Push(LegacyPath)
			KLPF_LAST_JSON[Which] := BodyA
		}
		KLPFWorker.jobs := Map()
		KLWV.full_build_timer_fn := (*) => 0
		ViewA := _MCR_View(() => 0)
		EntryA := Map("epoch", 81, "webview", ViewA, "metrics_dir", StoreA,
			"first_paint_done", false, "full_build_done", false)
		; The mutable last-opened directory must not override this window's owner.
		KLWV.metrics_dir := StoreB
		KLWV.windows := Map(Which, EntryA)
		KLWV_OnWebMessage(Which, 81, ViewA, _MCR_ReadyMessage())
		AssertEqual(1, ViewA.Messages.Length, "positive control must read the owning store's snapshot")
		AssertEqual("A", JsonParse(ViewA.Messages[1])["blob"]["store"])
		ViewB := _MCR_View(() => 0)
		EntryB := Map("epoch", 82, "webview", ViewB, "metrics_dir", StoreB,
			"first_paint_done", false, "full_build_done", false)
		KLWV.metrics_dir := StoreA
		KLWV.windows := Map(Which, EntryB)
		KLWV_OnWebMessage(Which, 82, ViewB, _MCR_ReadyMessage())
		AssertEqual(0, ViewB.Messages.Length,
			"a new store without a snapshot must not receive the previous store's metrics")
		AssertFalse(EntryB["first_paint_done"], "foreign data cannot complete first paint")
		KLPF_LAST_JSON[PathB] := '{"metrics_manifest":{},"store":"B"}'
		KLWV_OnWebMessage(Which, 82, ViewB, _MCR_ReadyMessage())
		AssertEqual(1, ViewB.Messages.Length, "the new store's own snapshot must remain deliverable")
		AssertEqual("B", JsonParse(ViewB.Messages[1])["blob"]["store"])
	} finally {
		KLWV.windows := SavedWindows
		KLWV.metrics_dir := SavedDir
		KLWV.full_build_timer_fn := SavedTimer
		KLPFWorker.jobs := SavedJobs
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		for CreatedPath in CreatedPaths
			AssertTrue(FSDelete(CreatedPath))
	}
}
for Mode in ["disk", "ram", "legacy"]
	Test("metrics ready: reject another store's " . Mode . " snapshot (metrics-store-isolation)",
		_MSI_ReadyRejectsForeignStore.Bind(Mode))

_MSI_PathIdentity() {
	Root := A_Temp . "\ergopti_metrics_store_identity"
	Path := KLPF_PrefetchPath("typing", Root)
	AssertEqual(Path, KLPF_PrefetchPath("typing", StrReplace(Root, "\", "/") . "/"),
		"separator spelling and a trailing separator must preserve store identity")
	AssertFalse(Path == KLPF_PrefetchPath("typing", Root . "_other"))
	AssertFalse(Path == KLPF_PrefetchPath("apps", Root))
	AssertFalse(Path == KLPF_PrefetchPath("typing", StrUpper(Root)),
		"case-sensitive Windows directories must not be merged")
	AssertThrows(() => KLPF_PrefetchPath("typing", "relative\metrics"), "relative stores must be rejected")
	AssertThrows(() => KLPF_PrefetchPath("typing", ""), "empty stores must be rejected")
	AssertThrows(() => KLPF_PrefetchPath("typing", Root, (*) => ""),
		"a hash failure must not collapse all stores into one shared filename")
}
Test("metrics cache: normalized store identity fails closed (metrics-store-isolation)",
	_MSI_PathIdentity)
