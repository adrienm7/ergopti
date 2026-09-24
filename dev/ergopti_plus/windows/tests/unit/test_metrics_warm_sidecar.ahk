; tests/unit/test_metrics_warm_sidecar.ahk

; ==============================================================================
; MODULE: Metrics Warm Sidecar Tests
; DESCRIPTION:
; Regression guard for metrics-first-paint-waits-for-cold-build. Opening the
; typing-metrics window showed « 0 activations / Calcul en cours... » for the
; length of a cold projection.
;
; ROOT CAUSES ENCODED:
; 1. The sidecar a dashboard paints from was written only by a finished full
;    build, started 2 s after the window opened (and cancelled by a quit): no
;    warm-up existed. KLWV_WarmRun now publishes it in a background worker at
;    keylogger start and once ingest goes idle, never replacing a running build.
; 2. KLWV_DelayedFirstPush decided to build by checking KLPF_LAST_JSON, which
;    the resident driver never fills, so even with a sidecar on disk it started
;    a manifest build carrying no tables. It now paints the sidecar at once.
; 3. The metrics pages post no "ready", so the paint waited for a 1.5 s timer;
;    NavigationCompleted now arms it as soon as the page can receive it.
;
; The detached worker is stubbed through KLPFWorker.spawn_fn: its start() writes
; the private stage and reports exit 0, so the real publication path runs.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MWS_Spawns := []

; KLWV_InjectI18n queues its script on a -1 timer, which may run while the
; fixture window is still registered, so every fixture carries a script sink.
class _MWS_FakeWebView {
	ExecuteScriptAsync(Script) {
		return Promise.resolve("null")
	}
	PostWebMessageAsString(Message) {
	}
}
global _MWS_Timers := []

_MWS_StubStart(done, *) {
	global _MWS_Spawns
	Args := _MWS_Spawns[_MWS_Spawns.Length]["args"]
	; The stage path follows the mode argument in both argument layouts.
	for Index, Value in Args {
		if (Value = "full" || Value = "manifest" || Value = "live") {
			Stage := Args[Index + 1]
			try FileDelete(Stage)
			FileAppend('{"metrics_manifest":{}}', Stage, "UTF-8")
			break
		}
	}
	done.Call(0, "", "")
	return true
}

_MWS_StubSpawn(executable, args, done) {
	global _MWS_Spawns
	_MWS_Spawns.Push(Map("args", args))
	Handle := {}
	Handle.start := _MWS_StubStart.Bind(done)
	Handle.terminate := (*) => true
	return Handle
}

_MWS_RecordTimer(Callback, Period) {
	global _MWS_Timers
	_MWS_Timers.Push(Map("callback", Callback, "period", Period))
	return true
}

_MWS_ModeOf(Spawn) {
	for _, Value in Spawn["args"] {
		if (Value = "full" || Value = "manifest" || Value = "live")
			return Value
	}
	return ""
}

; Runs Body with every KLWV/KLPF seam and registry isolated and restored.
_MWS_Isolated(Body) {
	global _MWS_Spawns, _MWS_Timers, KLPF_LAST_JSON
	Saved := Map(
		"windows", KLWV.windows, "jobs", KLPFWorker.jobs, "spawn", KLPFWorker.spawn_fn,
		"publish", KLPFWorker.publish_fn, "warm_dir", KLWV.warm_metrics_dir,
		"warm_timer", KLWV.warm_timer, "warm_fn", KLWV.warm_timer_fn,
		"first_fn", KLWV.first_paint_timer_fn, "full_fn", KLWV.full_build_timer_fn,
		"push_fn", KLWV.first_paint_push_fn)
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	MetricsDir := A_Temp . "\ergopti_warm_sidecar_" . A_ScriptHwnd . "_" . A_TickCount
	Paths := [KLPF_PrefetchPath("typing", MetricsDir), KLPF_PrefetchPath("apps", MetricsDir)]
	_MWS_Spawns := []
	_MWS_Timers := []
	try {
		KLWV.windows := Map()
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := _MWS_StubSpawn
		KLPFWorker.publish_fn := 0
		KLWV.warm_timer := 0
		KLWV.warm_timer_fn := _MWS_RecordTimer
		KLWV.first_paint_timer_fn := _MWS_RecordTimer
		KLWV.full_build_timer_fn := _MWS_RecordTimer
		KLPF_LAST_JSON := Map()
		for _, Path in Paths
			AssertFalse(FSExists(Path), "fixture must not reuse another owner's sidecar")
		Body.Call(MetricsDir, Paths)
	} finally {
		KLWV.windows := Saved["windows"]
		KLPFWorker.jobs := Saved["jobs"]
		KLPFWorker.spawn_fn := Saved["spawn"]
		KLPFWorker.publish_fn := Saved["publish"]
		KLWV.warm_metrics_dir := Saved["warm_dir"]
		KLWV.warm_timer := Saved["warm_timer"]
		KLWV.warm_timer_fn := Saved["warm_fn"]
		KLWV.first_paint_timer_fn := Saved["first_fn"]
		KLWV.full_build_timer_fn := Saved["full_fn"]
		KLWV.first_paint_push_fn := Saved["push_fn"]
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		for _, Path in Paths
			try FileDelete(Path)
	}
}

_MWS_WarmPublishesEverySidecar(MetricsDir, Paths) {
	global _MWS_Spawns, _MWS_Timers
	AssertTrue(KLWV_WarmSchedule(MetricsDir, KLWV.WARM_START_DELAY_MS))
	AssertEqual(1, _MWS_Timers.Length, "the boot warm-up must be armed, not run inline")
	AssertEqual(-KLWV.WARM_START_DELAY_MS, _MWS_Timers[1]["period"])
	AssertEqual(0, _MWS_Spawns.Length, "arming must not spawn a worker")

	_MWS_Timers[1]["callback"].Call()
	AssertEqual(1, _MWS_Spawns.Length, "the warm-up must start one background worker")
	AssertEqual("full", _MWS_ModeOf(_MWS_Spawns[1]), "only a full build publishes a complete sidecar")
	AssertTrue(FSExists(Paths[1]), "the typing sidecar must be published before any window opens")
	AssertFalse(KLPFWorker.jobs.Has("typing"), "the finished warm-up job must retire")

	AssertEqual(2, _MWS_Timers.Length, "the next key must be chained one turn later")
	_MWS_Timers[2]["callback"].Call()
	AssertEqual(2, _MWS_Spawns.Length)
	AssertTrue(FSExists(Paths[2]), "the apps sidecar must be published too")
	AssertEqual(2, _MWS_Timers.Length, "the chain ends after the last key")
}

_MWS_WarmNeverReplacesARunningBuild(MetricsDir, Paths) {
	global _MWS_Spawns
	Running := Map("generation", 4242, "stage", Paths[1] . ".stage.fixture",
		"handle", 0, "kind", "prefetch", "on_terminal", 0)
	KLPFWorker.jobs["typing"] := Running
	KLWV.windows["apps"] := Map("epoch", 7, "webview", _MWS_FakeWebView(), "metrics_dir", MetricsDir)
	KLWV.warm_metrics_dir := MetricsDir
	AssertFalse(KLWV_WarmRun(1), "no key is eligible: typing is running and apps is open")
	AssertEqual(0, _MWS_Spawns.Length, "the warm-up must not spawn over a running build or an open dashboard")
	Assert(KLPFWorker.jobs["typing"] == Running, "the running build must keep its registry slot")
}

_MWS_IdleIngestRearmsTheWarmUp(MetricsDir, Paths) {
	global _MWS_Timers
	KLWV.warm_metrics_dir := ""
	AssertFalse(KLWV_WarmOnIngestCommitted(), "no store is known before the boot warm-up")
	AssertEqual(0, _MWS_Timers.Length)
	KLWV.warm_metrics_dir := MetricsDir
	AssertTrue(KLWV_WarmOnIngestCommitted())
	AssertTrue(KLWV_WarmOnIngestCommitted())
	AssertEqual(2, _MWS_Timers.Length)
	AssertEqual(-KLWV.WARM_IDLE_DELAY_MS, _MWS_Timers[2]["period"])
	Assert(_MWS_Timers[1]["callback"] == _MWS_Timers[2]["callback"],
		"every commit must re-arm the SAME timer so the refresh waits for ingest to go idle")
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(Body != "", "KL_IngestOnce must be readable")
	Assert(InStr(Body, "KLWV_WarmOnIngestCommitted()") > 0,
		"a committed ingest must re-arm the idle warm-up")
	Boot := _DriverSourceNoComments()
	Assert(InStr(Boot, "KLWV_WarmSchedule(KL_MetricsDirFor(_ConfigDir), KLWV.WARM_START_DELAY_MS)") > 0,
		"the driver must arm the warm-up when the keylogger starts")
}

_MWS_SidecarPaintsWithoutABuild(MetricsDir, Paths) {
	global _MWS_Spawns, _MWS_Timers
	_KLRDC_EnsureSharedDir()
	AssertTrue(FSWrite(Paths[1], '{"metrics_manifest":{}}'))
	Pushes := []
	KLWV.first_paint_push_fn := (Which) => (Pushes.Push(Which), true)
	Entry := Map("epoch", 91, "webview", _MWS_FakeWebView(), "first_paint_done", false, "full_build_done", false,
		"metrics_dir", MetricsDir)
	KLWV.windows["typing"] := Entry
	KLWV_DelayedFirstPush("typing", 91)
	AssertEqual(1, Pushes.Length, "a sidecar on disk must be painted by the first push")
	AssertEqual(0, _MWS_Spawns.Length,
		"with a sidecar on disk no manifest build may be started (it carries no tables)")
	AssertTrue(Entry["first_paint_done"], "the disk paint completes first paint")
	AssertEqual(1, _MWS_Timers.Length, "the historical refresh still follows")
	AssertEqual(-KLWV.FULL_BUILD_DELAY_MS, _MWS_Timers[1]["period"])
}

_MWS_SidecarPaintsWhileWarmUpRuns(MetricsDir, Paths) {
	global _MWS_Spawns
	_KLRDC_EnsureSharedDir()
	AssertTrue(FSWrite(Paths[1], '{"metrics_manifest":{}}'))
	Pushes := []
	KLWV.first_paint_push_fn := (Which) => (Pushes.Push(Which), true)
	KLPFWorker.jobs["typing"] := Map("generation", 4343, "stage", Paths[1] . ".stage.fixture",
		"handle", 0, "kind", "prefetch", "on_terminal", 0)
	Entry := Map("epoch", 92, "webview", _MWS_FakeWebView(), "first_paint_done", false, "metrics_dir", MetricsDir)
	KLWV.windows["typing"] := Entry
	KLWV_DelayedFirstPush("typing", 92)
	AssertEqual(1, Pushes.Length, "the existing sidecar must be shown while the warm-up runs")
	AssertEqual(0, _MWS_Spawns.Length, "the running build keeps ownership")
	AssertFalse(Entry["first_paint_done"], "the running build's terminal owns the commit")
}

_MWS_WarmTerminalPaintsAnOpenWindow(MetricsDir, Paths) {
	Pushes := []
	KLWV.first_paint_push_fn := (Which) => (Pushes.Push(Which), true)
	Entry := Map("epoch", 93, "webview", _MWS_FakeWebView(), "first_paint_done", false, "metrics_dir", MetricsDir)
	KLWV.windows["apps"] := Entry
	KLWV_OnWarmTerminal("apps", KLWV.WARM_ORDER.Length, "ok")
	AssertEqual(1, Pushes.Length, "a window that deferred to the warm-up must be painted by it")
	AssertTrue(Entry["first_paint_done"])
	AssertTrue(Entry["full_build_done"], "the warm-up result is that window's full build")
}

_MWS_NavigationArmsFirstPaint(MetricsDir, Paths) {
	global _MWS_Timers
	KLWV.windows["typing"] := Map("epoch", 94, "webview", _MWS_FakeWebView(), "metrics_dir", MetricsDir)
	AssertTrue(KLWV_OnNavigationCompleted("typing", 94))
	AssertEqual(1, _MWS_Timers.Length, "navigation completion must arm the first paint at once")
	AssertEqual(-1, _MWS_Timers[1]["period"])
	AssertFalse(KLWV_OnNavigationCompleted("typing", 95), "a stale epoch must stay inert")
	Open := _DriverFuncBody("KLWV_Open")
	Assert(Open != "", "KLWV_Open must be readable")
	Assert(InStr(Open, "NavigationCompleted(KLWV_OnNavigationCompleted.Bind(which, Epoch))") > 0,
		"KLWV_Open must subscribe the first paint to NavigationCompleted")
	Assert(InStr(Open, '"nav_sub", nav_sub') > 0,
		"the NavigationCompleted subscription must be retained for the window's life")
}

for Name, Fn in Map(
		"warm-up publishes every sidecar in a background worker", _MWS_WarmPublishesEverySidecar,
		"warm-up never replaces a running build or an open window", _MWS_WarmNeverReplacesARunningBuild,
		"committed ingest re-arms one idle warm-up", _MWS_IdleIngestRearmsTheWarmUp,
		"a sidecar on disk paints without a manifest build", _MWS_SidecarPaintsWithoutABuild,
		"a sidecar paints while the warm-up still runs", _MWS_SidecarPaintsWhileWarmUpRuns,
		"the warm-up terminal paints a window that deferred to it", _MWS_WarmTerminalPaintsAnOpenWindow,
		"navigation completion arms the first paint", _MWS_NavigationArmsFirstPaint)
	Test("metrics warm sidecar: " . Name . " (metrics-first-paint-waits-for-cold-build)",
		_MWS_Isolated.Bind(Fn))
