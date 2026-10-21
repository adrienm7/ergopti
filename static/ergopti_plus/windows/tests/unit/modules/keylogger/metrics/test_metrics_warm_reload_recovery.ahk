; tests/unit/modules/keylogger/metrics/test_metrics_warm_reload_recovery.ahk
; No driver reload/process is performed. Real handoff publishers and callbacks
; use the existing successor OS port; warm jobs retain genuine FS publication.
#Requires AutoHotkey v2.0

_MWRL_Refused(World, Reason) {
	World.Refusals += 1
	World.Reason := Reason
}

_MWRL_EndPending(World) {
	World.Port["probe"]["alive"] := false
	AssertEqual(1, _RTP_RunArmed(World.Port), "the actual successor watcher must observe exit")
	AssertEqual(1, _RTP_RunArmed(World.Port), "the actual refusal must be delivered on its deferred stack")
	AssertEqual("refused", World.Record["state"])
	AssertEqual(1, World.Refusals)
	AssertTrue(InStr(World.Reason, "successor exited", true) > 0)
	AssertEqual(1, World.Port["probe"]["closed"])
	AssertEqual(0, World.Port["probe"]["terminated"], "an already exited successor is not terminated")
	AssertEqual(0, World.Port["probe"]["armed"].Length)
	AssertFalse(ReloadTerminalHandoffActive())
	AssertFalse(_ConfigWriteTerminalIsActive(), "the genuine release callback must return the barrier")
}

_MWRL_PrepareWaitingWindow(World) {
	AssertTrue(KLWV_WarmRun(KLWV.WARM_ORDER.Length))
	AssertEqual(1, World.Handles.Length)
	AssertTrue(KLWV_WarmSchedule(World.NextRoot, KLWV.WARM_START_DELAY_MS))
	World.Timers := [] ; Only capture B's recovery, not the separate idle warm-up.
	KLWV.windows[World.Which] := World.Entry
	; Deliver both public first-paint callbacks while the actual A slot is held.
	; The native Open/DOM and physical timer delay are not exercised here.
	loop 2 {
		World.View.Scripts := 0, World.View.SettledScripts := 0
		World.ScriptPending := true
		KLWV_DelayedFirstPush(World.Which, World.Epoch)
		_MWR_DrainScript(World)
		AssertEqual(1, World.Handles.Length)
		AssertFalse(World.Entry["first_paint_done"])
	}
	_MWR_Complete(World.Handles[1], "A")
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertEqual(1, World.Timers.Length)
	AssertTrue(FSStrictExists(World.Paths[1]))
	AssertFalse(FSStrictExists(World.Paths[2]))
	AssertFalse(World.Entry["full_build_done"])
	AssertEqual(0, World.View.Messages.Length)
	AssertTrue(World.Entry.Get("full_build_retry_owner", 0) is Map)
	World.Owner := World.Entry["full_build_retry_owner"]
	AssertEqual(0, World.Owner["attempt"])
}

_MWRL_Exercise(World, Root) {
	_MWRL_PrepareWaitingWindow(World)
	; A genuine private terminal bundle, not a forged reload/global busy flag.
	World.Bundle := _ConfigWriteTerminalTryAcquire([Root . "\reload.toml"])
	AssertTrue(World.Bundle is Object)
	World.Port := _RTP_NewPort()
	World.Record := _RTP_Pending(World.Bundle, World.Port, 0, 0, 0,
		_MWRL_Refused.Bind(World), _ConfigWriteTerminalRelease.Bind(World.Bundle))
	AssertTrue(ReloadTerminalHandoffActive())
	AssertTrue(KLPF_ReloadKeepsWorkersOut())
	AssertTrue(KLWV.windows[World.Which] == World.Entry)
	Callback := World.Timers[1]
	if World.Mode == "accepted-terminal" {
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertTrue(Claimed == World.Record)
		AssertTrue(ReloadTerminalHandoffCommit(Claimed))
		AssertTrue(ReloadTerminalHandoffFinish(Claimed, KLWV_Close.Bind(World.Which)),
			"the accepted terminal seam retires only the private session")
		AssertEqual("finished", World.Record["state"])
		AssertFalse(KLWV.windows.Has(World.Which))
		AssertEqual(1, _RTP_RunArmed(World.Port), "an old watcher must retire after accepted completion")
		AssertFalse(ReloadTerminalHandoffActive())
		Callback.Call()
		AssertEqual(1, World.Handles.Length, "a finished session must never rebuild B")
		AssertFalse(FSStrictExists(World.Paths[2]))
		AssertFalse(World.Entry.Has("full_build_retry_owner"))
		AssertEqual(0, World.Refusals)
		return
	}
	if World.Mode != "early-refusal" {
		if World.Mode == "pause"
			Suspend(true)
		Callback.Call()
		AssertTrue(ReloadTerminalHandoffActive(), "the retry runs during a real pending handoff")
		AssertEqual(1, World.Handles.Length, "no worker may run beside a successor")
		AssertEqual(0, KLPFWorker.jobs.Count)
	}
	_MWRL_EndPending(World)
	_TestPrint("# metrics-warm-reload mode=" . World.Mode . " handoff=" . World.Record["state"]
		. " reload_active=" . ReloadTerminalHandoffActive() . " debt="
		. IsObject(World.Entry.Get("full_build_retry_owner", 0)) . " arms=" . World.Timers.Length
		. " first_done=" . World.Entry["first_paint_done"] . " full_done=" . World.Entry["full_build_done"])
	AssertTrue(KLWV.windows[World.Which] == World.Entry, "refusal keeps the exact same live session")
	AssertTrue(World.Entry.Get("full_build_retry_owner", 0) == World.Owner,
		"a reload that is later refused must not consume the waiting window's recovery debt")
	AssertEqual(0, World.Owner["attempt"], "reload exclusion consumes no projection failure budget")
	if World.Mode == "pause" {
		AssertTrue(World.Entry["pending_full_build_retry"]["owner"] == World.Owner)
		AssertEqual(1, World.Timers.Length)
		Suspend(false)
		KLWV_FlushPendingFullBuildRetries()
	}
	AssertEqual(World.Mode == "early-refusal" ? 1 : 2, World.Timers.Length)
	World.Timers[World.Timers.Length].Call()
	AssertEqual(2, World.Handles.Length, "the existing owned retry must reserve exactly one B projection")
	AssertEqual(World.NextRoot, World.Handles[2].Root)
	AssertEqual(1, World.Handles[2].Starts)
	AssertEqual(0, World.Handles[2].Terminations)
	_MWR_Complete(World.Handles[2], "B")
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertTrue(World.Entry["first_paint_done"])
	AssertTrue(World.Entry["full_build_done"])
	AssertFalse(World.Entry.Has("full_build_retry_owner"))
	AssertFalse(World.Entry.Has("pending_full_build_retry"))
	AssertEqual(1, World.View.Messages.Length)
	AssertTrue(InStr(World.View.Messages[1], '"store":"B"', true) > 0)
	AssertTrue(InStr(FSReadStrict(World.Paths[2]), '"store":"B"', true) > 0,
		"full_done must follow actual B publication and delivery")
}

_MWRL_Case(Mode) {
	global _SharedDir, KLPF_LAST_JSON, _RTP_Events, _ReloadTerminalHandoff, _ReloadTerminalRetirements
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	static Serial := 0
	PreviousCritical := Critical("On")
	try {
		SavedLogger := _TLOG_CaptureLoggerState(), Extra := Map()
		for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
			"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
			Extra[Name] := %Name%
		Saved := {Windows: KLWV.windows, Jobs: KLPFWorker.jobs, Generation: KLPFWorker.generation,
			Spawn: KLPFWorker.spawn_fn, Publish: KLPFWorker.publish_fn, WarmDir: KLWV.warm_metrics_dir,
			WarmTimer: KLWV.warm_timer, WarmFn: KLWV.warm_timer_fn, First: KLWV.first_paint_timer_fn,
			Full: KLWV.full_build_timer_fn, Push: KLWV.first_paint_push_fn, Events: _RTP_Events,
			HadJson: IsSet(KLPF_LAST_JSON), HadShared: IsSet(_SharedDir), Suspended: A_IsSuspended}
		Saved.Json := Saved.HadJson ? KLPF_LAST_JSON : 0, Saved.Shared := Saved.HadShared ? _SharedDir : 0
		Root := A_Temp . "\ergopti_warm_reload_" . A_ScriptHwnd . "_" . ++Serial
		World := {Mode: Mode, Which: "apps", OldRoot: Root . "\old", NextRoot: Root . "\next",
			Handles: [], Timers: [], Inline: false, Failure: 0, View: _MWR_View(), ScriptPending: false,
			Epoch: -(0x50000000 + Serial), Owner: 0, Bundle: 0, Port: 0, Record: 0, Refusals: 0, Reason: ""}
		World.Entry := Map("epoch", World.Epoch, "webview", World.View, "metrics_dir", World.NextRoot,
			"first_paint_done", false, "full_build_done", false)
		World.Paths := [KLPF_PrefetchPath(World.Which, World.OldRoot), KLPF_PrefetchPath(World.Which, World.NextRoot)]
		Owned := false, Installed := false, SidecarsReady := false, Primary := 0, CleanupError := 0
		try {
			AssertFalse(A_IsSuspended)
			AssertFalse(_ReloadTerminalHandoff is Map, "never replace an incumbent handoff")
			AssertEqual(0, _ReloadTerminalRetirements.Count, "never replace retained physical successor debt")
			AssertFalse(_ConfigWriteTerminalIsActive())
			for SavedWhich, SavedEntry in Saved.Windows
				if SavedEntry is Map
					AssertTrue(SavedEntry.Get("epoch", 0) != World.Epoch)
			_KLRDC_EnsureSharedDir()
			FSCreateDirectoryExclusiveStrict(Root), Owned := true
			FSCreateDirectoryExclusiveStrict(World.OldRoot), FSCreateDirectoryExclusiveStrict(World.NextRoot)
			for Path in World.Paths
				AssertFalse(FSStrictExists(Path))
			SidecarsReady := true
			_ResetLogger()
			LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
			_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
			KLWV.windows := Map(), KLPFWorker.jobs := Map(), KLPF_LAST_JSON := Map(), _RTP_Events := [], Installed := true
			KLPFWorker.spawn_fn := _MWA_Spawn.Bind(World), KLPFWorker.publish_fn := 0
			KLWV.warm_metrics_dir := World.OldRoot, KLWV.warm_timer := 0
			KLWV.warm_timer_fn := _MWR_Timer.Bind(World), KLWV.full_build_timer_fn := _MWR_Timer.Bind(World)
			KLWV.first_paint_timer_fn := (*) => true, KLWV.first_paint_push_fn := 0
			_MWRL_Exercise(World, Root)
		} catch as Failure {
			Primary := Failure
		} finally {
			try {
				if Installed {
					try _MWR_DrainScript(World)
					catch as Failure
						CleanupError := Failure
					KLWV.windows := Map()
					AssertTrue(KLPF_CancelAll())
				}
				if IsObject(World.Bundle)
					_RTP_Cleanup(World.Bundle)
				if IsObject(World.Port)
					AssertEqual(0, World.Port["probe"]["armed"].Length, "retire every owned successor callback")
				if Installed {
					AssertFalse(ReloadTerminalHandoffActive())
					AssertFalse(_ReloadTerminalHandoff is Map)
					AssertEqual(0, _ReloadTerminalRetirements.Count)
				}
				if SidecarsReady
					for Path in World.Paths
						if FSStrictExists(Path)
							AssertTrue(FSDelete(Path))
			} catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			} finally {
				Suspend(Saved.Suspended)
				KLWV.windows := Saved.Windows, KLPFWorker.jobs := Saved.Jobs, KLPFWorker.generation := Saved.Generation
				KLPFWorker.spawn_fn := Saved.Spawn, KLPFWorker.publish_fn := Saved.Publish
				KLWV.warm_metrics_dir := Saved.WarmDir, KLWV.warm_timer := Saved.WarmTimer
				KLWV.warm_timer_fn := Saved.WarmFn, KLWV.first_paint_timer_fn := Saved.First
				KLWV.full_build_timer_fn := Saved.Full, KLWV.first_paint_push_fn := Saved.Push
				KLPF_LAST_JSON := Saved.HadJson ? Saved.Json : unset, _SharedDir := Saved.HadShared ? Saved.Shared : unset
				_RTP_Events := Saved.Events
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Value in Extra
					%Name% := Value
				for Handle in World.Handles
					Handle.start := 0, Handle.terminate := 0, Handle.Done := 0
				World.Timers := [], World.Entry.Clear()
				if IsObject(World.Record) && !_ReloadTerminalHandoffOwns(World.Record)
					World.Record.Clear()
			}
			if Owned {
				try DirDelete(Root, true)
				catch as Failure {
					if !IsObject(CleanupError)
						CleanupError := Failure
				}
			}
		}
		if IsObject(Primary)
			throw Primary
		if IsObject(CleanupError)
			throw CleanupError
	} finally Critical(PreviousCritical)
}

for _MWRL_Mode in ["pending-refusal", "early-refusal", "pause", "accepted-terminal"]
	Test("Metrics warm reload recovery: " . _MWRL_Mode . " keeps the window's outcome (metrics-warm-reload-recovery)",
		_MWRL_Case.Bind(_MWRL_Mode))
