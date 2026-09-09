; static/ergopti_plus/windows/tests/unit/test_metrics_cached_ready.ahk

; ==============================================================================
; MODULE: Cached Metrics Ready Tests
; DESCRIPTION: Successful disk delivery must complete first paint without a rebuild.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MCR_ReadyMessage {
	TryGetWebMessageAsString() {
		return '{"action":"ready"}'
	}
}

class _MCR_View {
	__New(Action) {
		this.Action := Action
		this.Messages := []
	}
	PostWebMessageAsString(Message) {
		this.Messages.Push(Message)
		this.Action.Call()
	}
}

_MCR_Refuse() {
	throw Error("fixture delivery refused")
}

_MCR_CachedReady(Outcome) {
	global KLPF_LAST_JSON
	SavedWindows := KLWV.windows
	SavedTimer := KLWV.full_build_timer_fn
	SavedJobs := KLPFWorker.jobs
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	Which := "cached_ready_" . A_ScriptHwnd . "_" . Outcome
	Path := KLPF_PrefetchPath(Which)
	AssertFalse(FSExists(Path), "fixture must not replace another owner's sidecar")
	Timers := []
	Successor := Map("epoch", 82, "first_paint_done", false)
	Action := Outcome = "refused" ? _MCR_Refuse
		: Outcome = "replaced" ? () => (KLWV.windows[Which] := Successor) : () => 0
	View := _MCR_View(Action)
	Entry := Map("epoch", 81, "webview", View, "first_paint_done", false, "full_build_done", false)
	try {
		_KLRDC_EnsureSharedDir()
		AssertTrue(FSWrite(Path, '{"metrics_manifest":{}}'))
		KLPF_LAST_JSON := Map()
		KLWV.windows := Map(Which, Entry)
		KLPFWorker.jobs := Outcome = "inflight" ? Map(Which, Map("epoch", 81)) : Map()
		KLWV.full_build_timer_fn := (Args*) => Timers.Push(Args)
		KLWV_OnWebMessage(Which, 81, View, _MCR_ReadyMessage())
		AssertEqual(1, View.Messages.Length, "ready must attempt the real disk-backed delivery")
		if (Outcome = "delivered") {
			AssertTrue(Entry["first_paint_done"], "successful disk delivery must own first-paint completion")
			AssertFalse(Entry["full_build_done"], "a sidecar is not proof of a fresh full projection")
			AssertEqual(1, Timers.Length, "cached paint must still schedule background full refresh")
			AssertEqual(-KLWV.FULL_BUILD_DELAY_MS, Timers[1][2])
			KLWV_DelayedFirstPush(Which, 81)
			AssertEqual(1, View.Messages.Length, "fallback must not repeat a completed cached first paint")
			KLWV_OnWebMessage(Which, 81, View, _MCR_ReadyMessage())
			AssertEqual(1, Timers.Length, "duplicate ready must not schedule duplicate full refreshes")
		} else {
			AssertFalse(Entry["first_paint_done"])
			AssertFalse(Successor["first_paint_done"])
			AssertEqual(0, Timers.Length, "failed or stale delivery must retain fallback ownership")
		}
	} finally {
		KLWV.windows := SavedWindows
		KLWV.full_build_timer_fn := SavedTimer
		KLPFWorker.jobs := SavedJobs
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		AssertTrue(FSDelete(Path))
	}
}
for Outcome in ["delivered", "refused", "replaced", "inflight"]
	Test("metrics cached ready: " . Outcome . " (metrics-cached-ready)", _MCR_CachedReady.Bind(Outcome))
