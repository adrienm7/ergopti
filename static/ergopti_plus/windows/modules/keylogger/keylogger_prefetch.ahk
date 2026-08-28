; modules/keylogger/keylogger_prefetch.ahk

; ==============================================================================
; MODULE: Keylogger Prefetch (AHK)
; DESCRIPTION:
; Builds the JSON blob the metrics_typing / metrics_apps webview pages
; consume on load. Mirrors the « load_and_inject » codepath of
; ui/metrics_typing/init.lua on macOS, except that we cannot push JS
; into Edge --app= externally (no JS bridge without WebView2). Instead
; we serialise the projection to a sidecar file the page reads via
; ``fetch('./prefetch.json')`` on load.
;
; FEATURES & RATIONALE:
; 1. Single chokepoint: every dashboard launch goes through
;    KLPF_BuildAndWrite which (a) materialises an in-memory SQLite
;    database from data.sql, (b) projects the manifest + range data,
;    (c) writes a single JSON file the page picks up.
; 2. Per-asset prefetch: each dashboard reads its own prefetch file
;    located alongside its index.html. This avoids a stale "typing"
;    blob being served to the "apps" dashboard or vice versa.
; 3. Atomic write: the JSON is written to a .tmp sibling and renamed
;    so a half-flushed file can never reach the page mid-fetch.
; 4. Disposable build: we do NOT cache the in-memory db across opens.
;    A fresh build of <100 MB of data.sql still completes in well under
;    a second on a modern SSD; cache invalidation would buy nothing
;    that's worth the bookkeeping.
; ==============================================================================

#Requires Autohotkey v2.0+





; ==================================
; ==================================
; ======= 1/ Path resolution =======
; ==================================
; ==================================

; Resolve the dashboard assets folder for a given page key (« typing »
; or « apps »). The dashboards live under
; ``<repo>/static/ergopti_plus/_shared/ui/metrics_<key>/``.
KLPF_AssetsDir(which) {
		global _SharedDir
		base := _SharedDir . "\ui\metrics_" . which . "\"
		loop files, base, "D"
				return A_LoopFileFullPath . "\"
		return base
}

; The prefetch file is written to the system temp folder to avoid
; polluting the repository with generated runtime data. The page reads
; it via a file:// URL extracted from the #prefetch= hash fragment
; injected into the --app= URL by KLUI_ResolveAssetUrl.
KLPF_PrefetchPath(which) {
		return A_Temp . "\ergopti_metrics_prefetch_" . which . ".json"
}

; Background projection protocol.  A projection is CPU/SQLite heavy enough to
; exceed the keyboard hook timeout, so the foreground driver only starts a
; disposable AHK worker and atomically publishes its finished staging file.
; The monotonic generation is the ownership fence: a cancelled/late worker can
; finish, but can never replace a newer dashboard result.
KLPF_NewOwnerId() {
	Guid := Buffer(16, 0)
	Result := DllCall("Ole32\CoCreateGuid", "Ptr", Guid.Ptr, "HRESULT")
	if Result != 0
		throw OSError(Result, "CoCreateGuid failed")
	TextBuffer := Buffer(78, 0)
	if DllCall("Ole32\StringFromGUID2", "Ptr", Guid.Ptr,
		"Ptr", TextBuffer.Ptr, "Int", 39, "Int") <= 0
		throw Error("StringFromGUID2 failed")
	return StrReplace(StrReplace(StrGet(TextBuffer, "UTF-16"), "{"), "}")
}

class KLPFWorker {
		static generation := 0
		static owner_id := KLPF_NewOwnerId()
		static jobs := Map()
		; Test seam: production leaves this at 0 and always uses ShellRunner.
		static spawn_fn := 0
		; Test seam for atomic-publication failure; production uses KLPF_MoveAtomic.
		static publish_fn := 0
		; Range-only deterministic seams. Production uses FileDelete/KL_JsonEncode.
		static range_delete_fn := 0
		static range_encode_fn := 0
}

KLPF_IsWorkerInvocation() {
		for _, arg in A_Args {
				if (arg = "--keylogger-prefetch-worker")
						return true
		}
		return false
}

_KLPF_DeleteRangeStage(Path) {
	try FileDelete(Path)
	return true
}

_KLPF_EncodeRangeApps(Apps) {
	return KL_JsonEncode(Apps)
}

KLPF_RequestBuild(which, metrics_dir, mode := "full", epoch := 0, on_terminal := unset, replace_active := true) {
		global _ConfigDir
		terminal := IsSet(on_terminal) ? on_terminal : 0
		if A_IsSuspended || (which != "typing" && which != "apps") || (metrics_dir = "")
				|| (mode != "full" && mode != "live" && mode != "manifest") {
				KLPF_InvokeTerminal(terminal, A_IsSuspended ? "canceled" : "failed")
				return false
		}

		; Live ingest uses replace_active=false: an in-flight full/history or live
		; projection owns its generation until terminal publication. The caller keeps
		; one dirty bit and coalesces every intervening ingest behind that owner.
		if KLPFWorker.jobs.Has(which) {
				if !replace_active
						return false
				KLPF_CancelBuild(which)
				; A terminal callback is allowed to install a newer owner. Never let the
				; older request which triggered cancellation overwrite that re-entrant job.
				if KLPFWorker.jobs.Has(which) {
						KLPF_InvokeTerminal(terminal, "canceled")
						return false
				}
		}

		generation := ++KLPFWorker.generation
		stage := KLPF_PrefetchPath(which) . ".stage."
				. KLPFWorker.owner_id . "." . generation
		; Reserve the scheduler slot before any filesystem/process work. A timer may
		; interrupt FileDelete or ShellRunner construction; it must observe this job
		; and coalesce rather than start a sibling worker in that window.
		job := Map(
				"generation", generation,
				"epoch", epoch,
				"stage", stage,
				"handle", 0,
				"kind", "prefetch",
				"mode", mode,
				"on_terminal", terminal
		)
		KLPFWorker.jobs[which] := job
		try FileDelete(stage)
		executable := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
		args := A_IsCompiled
				? ["/force", "--keylogger-prefetch-worker", which, metrics_dir, mode, stage, _ConfigDir,
						KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
						KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS]
				: ["/force", A_ScriptFullPath, "--keylogger-prefetch-worker", which, metrics_dir, mode, stage, _ConfigDir,
						KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
						KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS]
		done := KLPF_OnWorkerDone.Bind(which, generation)
		spawn := IsObject(KLPFWorker.spawn_fn)
				? KLPFWorker.spawn_fn : ShellRunner_SpawnTreeOwned
		try handle := spawn.Call(executable, args, done)
		catch as err {
				try LoggerError("KLReader", "Could not spawn background metrics projection for '{1}': {2}", which, err.Message)
				KLPF_CompleteJob(which, generation, "failed")
				return false
		}
		; Cancellation may have won while ShellRunner_Spawn yielded. Validate the
		; reservation and publish its process handle without an interruptible gap:
		; cancellation must observe either no owner or the exact terminable handle.
		PreviousCritical := Critical("On")
		try {
			if !KLPFWorker.jobs.Has(which)
					|| KLPFWorker.jobs[which]["generation"] != generation {
				try handle.terminate()
				return false
			}
			job["handle"] := handle
		} finally {
			Critical(PreviousCritical)
		}
		try started := handle.start()
		catch as err {
				try LoggerError("KLReader", "Could not start background metrics projection for '{1}': {2}", which, err.Message)
				KLPF_CompleteJob(which, generation, "failed")
				return false
		}
		if !KLPFWorker.jobs.Has(which)
				return true
		if !started {
				KLPF_CompleteJob(which, generation, "failed")
				return false
		}
		return true
}

KLPF_RequestRange(which, metrics_dir, query, epoch := 0, on_terminal := unset) {
		global _ConfigDir
		terminal := IsSet(on_terminal) ? on_terminal : 0
		if A_IsSuspended || (which != "typing") || (metrics_dir = "") || !(query is Map)
				|| !query.Has("apps") || !(query["apps"] is Array)
				|| !query.Has("start_date") || !query.Has("end_date") {
				KLPF_InvokeTerminal(terminal, A_IsSuspended ? "canceled" : "failed")
				return false
		}
		job_key := "range:" . which
		if KLPFWorker.jobs.Has(job_key) {
				KLPF_CancelBuild(job_key)
				if KLPFWorker.jobs.Has(job_key) {
						KLPF_InvokeTerminal(terminal, "canceled")
						return false
				}
		}
		generation := ++KLPFWorker.generation
		stage := A_Temp . "\ergopti_metrics_range_" . which . ".stage."
				. KLPFWorker.owner_id . "." . generation . ".json"
		job := Map(
				"generation", generation,
				"epoch", epoch,
				"stage", stage,
				"handle", 0,
				"kind", "range",
				"on_terminal", terminal
		)
		KLPFWorker.jobs[job_key] := job

		DeleteFn := IsObject(KLPFWorker.range_delete_fn)
				? KLPFWorker.range_delete_fn : _KLPF_DeleteRangeStage
		try DeleteFn.Call(stage)
		catch as err {
				try LoggerError("KLReader", "Could not clear selected-range stage: {1}", err.Message)
				KLPF_CompleteJob(job_key, generation, "failed")
				return false
		}
		if !KLPFWorker.jobs.Has(job_key)
				|| KLPFWorker.jobs[job_key]["generation"] != generation
				return false

		EncodeFn := IsObject(KLPFWorker.range_encode_fn)
				? KLPFWorker.range_encode_fn : _KLPF_EncodeRangeApps
		try apps_json := EncodeFn.Call(query["apps"])
		catch as err {
				try LoggerError("KLReader", "Could not encode selected-range projection request: {1}", err.Message)
				KLPF_CompleteJob(job_key, generation, "failed")
				return false
		}
		if !KLPFWorker.jobs.Has(job_key)
				|| KLPFWorker.jobs[job_key]["generation"] != generation
				return false
		executable := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
		args := A_IsCompiled
				? ["/force", "--keylogger-prefetch-worker", which, metrics_dir, "range", stage, _ConfigDir,
						KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
						KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS,
						query["start_date"], query["end_date"], apps_json]
				: ["/force", A_ScriptFullPath, "--keylogger-prefetch-worker", which, metrics_dir, "range", stage, _ConfigDir,
						KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
						KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS,
						query["start_date"], query["end_date"], apps_json]
		done := KLPF_OnWorkerDone.Bind(job_key, generation)
		spawn := IsObject(KLPFWorker.spawn_fn)
				? KLPFWorker.spawn_fn : ShellRunner_SpawnTreeOwned
		try handle := spawn.Call(executable, args, done)
		catch as err {
				try LoggerError("KLReader", "Could not spawn selected-range projection worker: {1}", err.Message)
				KLPF_CompleteJob(job_key, generation, "failed")
				return false
		}
		PreviousCritical := Critical("On")
		try {
				if !KLPFWorker.jobs.Has(job_key)
						|| KLPFWorker.jobs[job_key]["generation"] != generation {
						try handle.terminate()
						return false
				}
				job["handle"] := handle
		} finally {
				Critical(PreviousCritical)
		}
		try started := handle.start()
		catch as err {
				try LoggerError("KLReader", "Could not start selected-range projection worker: {1}", err.Message)
				KLPF_CompleteJob(job_key, generation, "failed")
				return false
		}
		; start() may synchronously drive the completion seam. The missing job is
		; proof that its terminal already won; never reinterpret the handle's return
		; value and emit a contradictory second terminal afterward.
		if !KLPFWorker.jobs.Has(job_key)
				return true
		if !started {
				KLPF_CompleteJob(job_key, generation, "failed")
				return false
		}
		return true
}

KLPF_CancelBuild(which) {
		if !KLPFWorker.jobs.Has(which)
				return true
		job := KLPFWorker.jobs[which]
		if job.Get("terminal_claimed", false) {
				; Completion keeps the registry entry through atomic publish and callback.
				; Record a suspend/replacement that interrupts that yielded region; the
				; completing owner will downgrade its terminal before delivery.
				job["cancel_requested"] := true
				HasProcessOwner := IsObject(job["handle"])
						&& HasMethod(job["handle"], "terminate")
				Terminated := !HasProcessOwner
				if HasProcessOwner
						try Terminated := job["handle"].terminate()
				return (Terminated is Integer) && Terminated == true
		}
		; Claim terminal ownership before terminate(): a process handle is allowed
		; to invoke done synchronously while being killed. Tree-owned terminate()
		; confirms ActiveProcesses=0; an unconfirmed result retains this exact job
		; so OnExit can refuse and retry instead of orphaning a detached worker.
		job["terminal_claimed"] := true
		job["cancel_requested"] := true
		HasProcessOwner := IsObject(job["handle"])
				&& HasMethod(job["handle"], "terminate")
		Terminated := !HasProcessOwner
		if HasProcessOwner
				try Terminated := job["handle"].terminate()
		if !((Terminated is Integer) && Terminated == true)
				return false
		FSDelete(job["stage"])
		KLPF_InvokeTerminal(job["on_terminal"], "canceled")
		if KLPFWorker.jobs.Has(which)
				&& KLPFWorker.jobs[which]["generation"] = job["generation"]
				KLPFWorker.jobs.Delete(which)
		return true
}

KLPF_CancelAll() {
		Keys := []
		for JobKey in KLPFWorker.jobs
				Keys.Push(JobKey)
		AllTerminated := true
		for JobKey in Keys {
				if !KLPF_CancelBuild(JobKey)
						AllTerminated := false
		}
		return AllTerminated && KLPFWorker.jobs.Count = 0
}

KLPF_InvokeTerminal(on_terminal, status, stage := "") {
		if !IsObject(on_terminal)
				return false
		try {
				on_terminal.Call(status, stage)
				return true
		} catch as err {
				try LoggerError("KLReader", "Background metrics terminal callback failed (status={1}): {2}", status, err.Message)
				return false
		}
}

; Retire any projection job exactly once. The registry entry remains published
; through atomic publication and the terminal callback so re-entrant ingest sees
; the active owner and coalesces behind it. A range callback owns its successful
; private stage only if it returns.
KLPF_CompleteJob(job_key, generation, status, stage := "") {
		if !KLPFWorker.jobs.Has(job_key)
				return false
		job := KLPFWorker.jobs[job_key]
		if (job["generation"] != generation)
				return false
		if job.Get("terminal_claimed", false)
				return false
		job["terminal_claimed"] := true

		owned_stage := job["stage"]
		if (status = "ok") && ((stage = "") || (stage != owned_stage) || !FSExists(owned_stage))
				status := "failed"

		delivery_stage := ""
		if (status = "ok") {
				if (job["kind"] = "range") {
						delivery_stage := owned_stage
				} else {
						publish := IsObject(KLPFWorker.publish_fn) ? KLPFWorker.publish_fn : KLPF_MoveAtomic
						published := false
						try published := publish.Call(owned_stage, KLPF_PrefetchPath(job_key))
						catch as err
								try LoggerError("KLReader", "Background metrics publish threw for '{1}': {2}", job_key, err.Message)
						if !published {
								status := "failed"
								try LoggerError("KLReader", "Background metrics projection could not publish '{1}'.", job_key)
						}
				}
		}
		; File publication can yield to Suspend or a newer explicit request. Keep
		; the old owner discoverable for that whole region, then honor cancellation
		; before any UI callback is allowed to publish stale work.
		if job.Get("cancel_requested", false) || A_IsSuspended
				status := "canceled"
		if (status != "ok")
				FSDelete(owned_stage)
		delivered := KLPF_InvokeTerminal(job["on_terminal"], status, delivery_stage)
		if (job["kind"] = "range") && !delivered && (delivery_stage != "")
				FSDelete(delivery_stage)
		if KLPFWorker.jobs.Has(job_key)
				&& KLPFWorker.jobs[job_key]["generation"] = generation
				KLPFWorker.jobs.Delete(job_key)
		return delivered
}

KLPF_OnWorkerDone(which, generation, exit_code, stdout, stderr) {
		if !KLPFWorker.jobs.Has(which)
				return
		job := KLPFWorker.jobs[which]
		if (job["generation"] != generation)
				return
		stage := job["stage"]
		status := A_IsSuspended ? "canceled" : ((exit_code != 0) || !FSExists(stage) ? "failed" : "ok")
		if (status = "failed")
				try LoggerWarn("KLReader", "Background metrics projection failed for '{1}' (exit={2}).", which, exit_code)
		KLPF_CompleteJob(which, generation, status, stage)
}

; Runs in the detached /force instance.  It exits before the normal boot block,
; so it never registers a hook, hotkey, timer, tray menu, or WebView callback.
KLPF_WorkerMain() {
		if !KLPF_IsWorkerInvocation()
				return false
		if (A_Args.Length < 12)
				ExitApp(2)
		which := A_Args[2]
		metrics_dir := A_Args[3]
		mode := A_Args[4]
		stage := A_Args[5]
		global _ConfigDir, _AhkSubDir
		_ConfigDir := A_Args[6]
		_AhkSubDir := "autohotkey\"
		try {
				KLWConst.MAX_KEYSTROKE_DELAY_MS := Integer(A_Args[7])
				KLWConst.THINK_PAUSE_MS := Integer(A_Args[8])
				KLWConst.BURST_GAP_MS := Integer(A_Args[9])
				KLWConst.SESSION_GAP_MS := Integer(A_Args[10])
				KLWConst.AUTO_REPEAT_MAX_DELAY_MS := Integer(A_Args[11])
				KLWConst.HOLD_THRESHOLD_MS := Integer(A_Args[12])
				if (which != "typing" && which != "apps") || (mode != "full" && mode != "live" && mode != "manifest" && mode != "range")
						ExitApp(2)
				if (mode = "range") {
						if (A_Args.Length < 15)
								ExitApp(2)
						apps := KL_JsonDecode(A_Args[15])
						if !(apps is Array)
								ExitApp(2)
						db := KLR_BuildDatabase(metrics_dir)
						if !db || !KLPF_WriteAtomic(stage, KL_JsonEncode(KLR_ReadRangeSplitToday(db, A_Args[13], A_Args[14], apps)))
								ExitApp(1)
				} else if !KLPF_BuildAndWriteToPath(which, metrics_dir, stage, "", mode) {
						ExitApp(1)
				}
		} catch {
				try FileDelete(stage)
				ExitApp(1)
		}
		ExitApp(0)
}





; ===============================
; ===============================
; ======= 2/ Public entry =======
; ===============================
; ===============================

; Build and write the prefetch blob for the named dashboard. Returns true
; on success, false on any failure (a failure leaves the previous file
; intact so the page degrades gracefully to the old data rather than to
; an empty state).
; mode: "full" (default) — manifest + n-grams + range data.
;       "manifest" — skip n-grams. Used by the fast 500 ms flush tick
;       so the dashboard’s KPI counters update near-instantly without
;       paying the ~2-3 s n-gram projection + ~1 s JSON encode cost.
KLPF_BuildAndWrite(which, metrics_dir, dbg := "", mode := "full") {
		return KLPF_BuildAndWriteToPath(which, metrics_dir, KLPF_PrefetchPath(which), dbg, mode)
}

KLPF_BuildAndWriteToPath(which, metrics_dir, path, dbg := "", mode := "full") {
		if (dbg = "") {
				global _ConfigDir, _AhkSubDir
				try DirCreate(_ConfigDir . _AhkSubDir . "logs")
				dbg := _ConfigDir . _AhkSubDir . "logs\prefetch_debug.log"
		}
		KLPF_DbgWrite(dbg, "=== " . A_Now . " — which=" . which . " mode=" . mode)
		t0 := A_TickCount

		db := KLR_BuildDatabase(metrics_dir)
		if !db {
				KLPF_DbgWrite(dbg, "FAIL: KLR_BuildDatabase returned 0")
				try LoggerError("KLReader", "Metrics DB build failed (winsqlite3.dll/schema.sql/data.sql) — dashboard '{1}' shows no data.", which)
				return false
		}
		t_db := A_TickCount
		KLPF_DbgWrite(dbg, "PERF db=" . (t_db - t0) . "ms")

		; Cheap sanity probe — count agg_app_day rows so we know the data
		; actually landed. SQLite_Query returns Array<Map>.
		rows := SQLite_Query(db, "SELECT COUNT(*) AS n FROM agg_app_day")
		n := (rows.Length > 0 && rows[1].Has("n")) ? rows[1]["n"] : "?"
		KLPF_DbgWrite(dbg, "agg_app_day row count = " . n)

		blob := Map()
		if (which = "typing") {
				blob := KLPF_BuildTyping(db, mode)
		} else if (which = "apps") {
				blob := KLPF_BuildApps(db)
		}
		; Pull and remove the side-channel today JSON before encoding —
		; it would otherwise leak into the output as "__klpf_today_json"
		; and the placeholder substitution wouldn't fire.
		today_json_raw := ""
		if blob.Has("__klpf_today_json") {
				today_json_raw := blob["__klpf_today_json"]
				blob.Delete("__klpf_today_json")
		}
		t_proj := A_TickCount
		KLPF_DbgWrite(dbg, "PERF projection=" . (t_proj - t_db) . "ms")

		json := KL_JsonEncode(blob)
		if (today_json_raw != "") {
				; Replace the quoted sentinel with the raw object literal so
				; the final output is valid JSON: "today":<...> without the
				; encoder having had to walk thousands of n-gram rows itself.
				json := StrReplace(json, '"__KLPF_TODAY_PLACEHOLDER__"', today_json_raw)
		}
		t_json := A_TickCount
		KLPF_DbgWrite(dbg, "PERF json_encode=" . (t_json - t_proj) . "ms len=" . StrLen(json))

		; Cache JSON in memory so the WebView2 push path can skip the
		; round-trip through disk. The Edge --app= fallback still reads
		; the sidecar file from disk on first paint.
		global KLPF_LAST_JSON
		if !IsSet(KLPF_LAST_JSON)
				KLPF_LAST_JSON := Map()
		KLPF_LAST_JSON[which] := json

		written := KLPF_WriteAtomic(path, json)
		t_write := A_TickCount
		KLPF_DbgWrite(dbg, "PERF write=" . (t_write - t_json) . "ms total=" . (t_write - t0) . "ms")
		return written
}

; Diagnostic sink for the prefetch worker. Gated behind the debug level exactly
; like its sibling KLR_PrefetchDebug in the same pipeline: it emits six lines per
; projection, and KLPF_RequestBuild spawns a projection on every ingest tick
; while a dashboard is open (~4 300/day). prefetch_debug.log is written next to
; the dated ErgoptiPlus_*.log files but _LoggerPurgeOldLogs only matches those,
; so nothing ever rotates or ages it out — unbounded growth for the lifetime of
; the install, on top of the open+write+close NTFS/AV tax per line.
; @param path {String} Destination log file.
; @param line {String} Line to append, without a trailing newline.
KLPF_DbgWrite(path, line) {
		if !LoggerIsDebugEnabled()
				return
		try FileAppend(line . "`r`n", path, "UTF-8")
}

; Reap scratch files stranded next to ``path`` by a run that was killed between
; the staged write and the rename. Deliberately a local twin of keylogger.ahk's
; _KL_ReapStaleTemps rather than a shared call: tests/run_all.ahk loads this
; module WITHOUT keylogger.ahk, so a cross-file dependency would be a load-time
; failure in the suite. The file already keeps its own MOVEFILE_* statics and
; its own KLPF_MoveAtomic for the same reason.
; @param path {String} Final destination path whose siblings are scanned.
; @param MaxAgeMs {Integer} Minimum age, in ms, before a scratch file is reaped.
_KLPF_ReapStaleTemps(path, MaxAgeMs) {
		SplitPath(path, &Name, &Dir)
		if (Dir = "" or Name = "")
				return
		try {
				Loop Files, Dir . "\" . Name . ".*.tmp" {
						if (DateDiff(A_Now, A_LoopFileTimeModified, "Seconds") * 1000 >= MaxAgeMs)
								try FileDelete(A_LoopFileFullPath)
				}
		}
}

KLPF_WriteAtomic(path, content) {
		; Publish the tmp file onto ``path`` with the same atomic-rename primitive
		; KL_WriteAtomic (keylogger.ahk) uses: MoveFileExW(MOVEFILE_REPLACE_EXISTING
		; | MOVEFILE_WRITE_THROUGH) is a kernel-level directory-entry swap with NO
		; absent-file window. The previous delete-then-move sequence left
		; a gap where the destination did not exist — a dashboard fetch('./prefetch.json')
		; landing between the two saw a 404, and an AV/indexer transiently holding
		; the freshly-deleted name made the move fail with no retry, stranding the
		; page on stale data. We retry the rename once to ride out a transient AV /
		; indexer lock before giving up.
		;
		; The tmp write stays UTF-8-RAW (no BOM): the JSON is fetched and parsed by
		; the dashboard, and we never want a BOM in the served blob. The function
		; keeps its boolean contract — false leaves the previous prefetch file
		; intact so the page degrades to old data rather than to an empty state.
		; Same per-invocation scratch name as KL_WriteAtomic, and for the same
		; reason: a fixed ``path . ".tmp"`` is a shared resource, and RETRY_DELAY_MS
		; below is a yield point that lets another thread enter, publish its own
		; staged file and consume the name out from under the sleeping caller. That
		; writer then renames a file that no longer exists, or two writers interleave
		; their FileAppend and publish spliced JSON to the dashboard.
		static MOVEFILE_REPLACE_EXISTING := 0x1
		static MOVEFILE_WRITE_THROUGH    := 0x8
		static FLAGS := MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
		static RETRY_DELAY_MS            := 50
		; Older than this, a scratch file can only be debris from a hard kill.
		static STALE_TEMP_MS             := 60000
		static WriteSeq := 0

		WriteSeq += 1
		; A_ScriptHwnd rather than a GetCurrentProcessId DllCall: unique per process
		; all the same, and it keeps the OS-call purity ratchet at its baseline.
		tmp := path . "." . A_ScriptHwnd . "-" . WriteSeq . ".tmp"
		_KLPF_ReapStaleTemps(path, STALE_TEMP_MS)
		try FileAppend(content, tmp, "UTF-8-RAW")
		catch
				return false

		if !KLPF_MoveAtomic(tmp, path, FLAGS) {
				Sleep RETRY_DELAY_MS
				if !KLPF_MoveAtomic(tmp, path, FLAGS) {
						try FileDelete(tmp)
						return false
				}
		}
		return true
}

KLPF_MoveAtomic(source, destination, flags := unset) {
		static MOVEFILE_REPLACE_EXISTING := 0x1
		static MOVEFILE_WRITE_THROUGH := 0x8
		if !IsSet(flags)
				flags := MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
		return DllCall("Kernel32\MoveFileExW", "Str", source, "Str", destination,
				"UInt", flags, "Int") != 0
}





; ========================================
; ========================================
; ======= 3/ Typing dashboard blob =======
; ========================================
; ========================================

; Manifest cache: historical days never change once persisted, so we keep
; the full projection and only re-query today's row on live ticks. Drops
; the per-tick manifest cost from ~150 ms to ~20 ms.
global KLPF_MANIFEST_CACHE := unset

; Collapse a manifest's date x app grid into the SET of app names the SQL filter
; needs. The manifest lists every app once PER DAY, but the consumers splice the
; result into an ``app IN (...)`` clause that KLR_BuildTodayIdxJson re-parses in
; eleven SELECTs on every ingest tick, so a duplicate member costs SQL text and
; SQLite parse time while selecting exactly the same rows — and the count grows
; with days-of-history x apps, forever, because nothing prunes agg_app_day. This
; is one helper rather than two inline loops because the "live" and "full"
; branches below each carried a copy and only the "full" one de-duplicated.
; @param manifest {Map} manifest[date][app] grid as returned by KLR_ReadManifest.
; @return {Array} Sorted, de-duplicated app names, with "Unknown" excluded.
KLPF_UniqueAppsFromManifest(manifest) {
		apps_set  := Map()
		apps_list := []
		for _, day_data in manifest {
				for app_name, _ in day_data {
						if (app_name = "Unknown")
								continue
						if !apps_set.Has(app_name) {
								apps_set[app_name] := true
								apps_list.Push(app_name)
						}
				}
		}
		KLPF_SortInPlace(apps_list)
		return apps_list
}

KLPF_BuildTyping(db, mode := "full") {
		global KLPF_MANIFEST_CACHE
		today := FormatTime(A_Now, "yyyy-MM-dd")
		use_cache := (mode = "live" || mode = "manifest") && IsSet(KLPF_MANIFEST_CACHE) && KLPF_MANIFEST_CACHE
		if use_cache {
				manifest := KLPF_MANIFEST_CACHE
				; Re-project ONLY today's entry and overwrite that date in the cache.
				today_only := KLR_ReadManifest(db, today, today)
				if today_only.Has(today) {
						manifest[today] := today_only[today]
				} else if manifest.Has(today) {
						manifest.Delete(today)
				}
		} else {
				manifest := KLR_ReadManifest(db)
				KLPF_MANIFEST_CACHE := manifest
		}
		; OS hint — the UI uses this to pick between the macOS keycode
		; layout (kc) and the Windows scancode layout (sc_kb) when rendering
		; the heatmap.
		driver_os := Map("os", "win", "heatmap_id", "sc_kb")

		blob := Map(
				"metrics_manifest", manifest,
				"app_icons", Map(),                      ; icon extraction is HS-only for now.
				"keycode_layout", KLPF_KeycodeLayout(),
				"driver_meta", driver_os
		)

		; The full n-gram projection is the dominant cost (~2-3 s).
		; Mode dispatch:
		;   manifest — KPIs only, ~50 ms. Omits _prefetch_data so the JS
		;              bootstrap keeps the existing n-gram tables.
		;   live     — KPIs + today's top-500 n-grams across the most-
		;              viewed tables (chars/bigrams/.../words). Historical
		;              stays cached client-side from the first paint.
		;              ~150-300 ms.
		;   full     — full projection (default), used at first paint to
		;              seed the historical block.
		if (mode = "manifest") {
				return blob
		}
		if (mode = "live") {
				; Splice the SQL-built today JSON in as a magic placeholder
				; the encoder leaves alone. KLPF_BuildAndWrite detects the
				; sentinel and post-substitutes the real JSON string after
				; KL_JsonEncode runs. This bypasses ~600 ms of per-row Map
				; allocation + ~300 ms of AHK-side JSON encoding for the
				; n-gram tables, dropping live-tick total to under 200 ms.
				today_json := KLR_BuildTodayIdxJson(db, KLPF_UniqueAppsFromManifest(manifest))
				blob["_prefetch_data"] := Map(
						"historical", Map(),
						"today", "__KLPF_TODAY_PLACEHOLDER__"
				)
				blob["__klpf_today_json"] := today_json
				return blob
		}

		first_date := ""
		for date_str, _ in manifest {
				if (first_date = "" || StrCompare(date_str, first_date) < 0)
						first_date := date_str
		}
		apps_list := KLPF_UniqueAppsFromManifest(manifest)

		range_data := Map("historical", Map(), "today", Map())
		if (first_date != "")
				range_data := KLR_ReadRangeSplitToday(db, first_date, today, apps_list)
		blob["_prefetch_data"] := range_data
		return blob
}





; ======================================
; ======================================
; ======= 4/ Apps dashboard blob =======
; ======================================
; ======================================

KLPF_BuildApps(db) {
		; metrics_apps reads (date, app) totals only — no n-grams. The same
		; manifest projection covers it.
		manifest := KLR_ReadManifest(db)
		return Map(
				"metrics_manifest", manifest,
				"app_icons", Map()
		)
}





; ===========================================
; ===========================================
; ======= 5/ Keycode layout (heatmap) =======
; ===========================================
; ===========================================

; Build the « scancode → printable label » map for the heatmap. When
; the Ergopti base-layer emulation is enabled (Features["layout"]
; ["ergopti_base"]), we read the canonical mapping from
; modules/keymap/layout/layout_ergopti.ahk — the SAME data layout.ahk uses to install
; the actual remaps. Otherwise we resolve each scancode through the
; active Windows keyboard layout using MapVirtualKeyEx(MAPVK_VK_TO_CHAR).
; The latter sidesteps the dead-key state ToUnicodeEx leaves behind —
; passing through a dead key (¨, ^, …) on AZERTY-fr would otherwise
; return the precomposed character of the next call (« Ä » instead
; of « a »).
KLPF_KeycodeLayout() {
		global Features
		out := Map()

		ergopti_active := IsSet(Features)
		&& Features.Has("layout")
		&& Features["layout"].Has("ergopti_base")
		&& Features["layout"]["ergopti_base"] = true
		if ergopti_active {
				for sc, ch in ErgoptiBaseLabels()
						out[String(sc)] := ch
				return out
		}

		; Resolve the active layout for the foreground window. Falls back
		; to the script thread’s layout if the lookup fails.
		hkl := 0
		try {
				hwnd := DllCall("GetForegroundWindow", "ptr")
				tid := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr", 0, "uint")
				hkl := DllCall("GetKeyboardLayout", "uint", tid, "ptr")
		}
		if !hkl
				try hkl := DllCall("GetKeyboardLayout", "uint", 0, "ptr")

		loop 87 {
				sc := A_Index
				; Skip scancodes the JS side overlays (modifiers, whitespace,
				; F-row) so the AHK map stays out of its way.
				if (sc = 1 || sc = 14 || sc = 15 || sc = 28 || sc = 29
						|| sc = 42 || sc = 54 || sc = 56 || sc = 57 || sc = 58
						|| (sc >= 59 && sc <= 68) || sc = 87 || sc = 88)
						continue
				vk := DllCall("MapVirtualKeyExW", "uint", sc, "uint", 3, "ptr", hkl, "uint")
				if !vk
						continue
				; MAPVK_VK_TO_CHAR (uMapType=2) — returns the unshifted Unicode
				; codepoint in the low 16 bits. The top bit signals a dead key
				; (¨, ^, …). The next-higher bits encode the dead-key class on
				; some layouts; mask them all to keep the literal codepoint.
				raw := DllCall("MapVirtualKeyExW", "uint", vk, "uint", 2, "ptr", hkl, "uint")
				if !raw
						continue
				cp := raw & 0xFFFF
				; Strip any pending dead-key flag — the heatmap label is the
				; resting form (¨, ^), not the composed accent.
				if (raw & 0x80000000)
						cp := cp & 0x7FFF
				if (cp <= 0)
						continue
				ch := Chr(cp)
				if (ch = "")
						continue
				out[String(sc)] := ch
		}
		return out
}





; ===============================
; ===============================
; ======= 6/ Tiny helpers =======
; ===============================
; ===============================

; Insertion sort over an Array of Strings (case-insensitive). Plenty fast
; for the typical "few dozen apps" range; AHK has no built-in Array.Sort.
KLPF_SortInPlace(arr) {
		n := arr.Length
		loop n {
				i := A_Index
				j := i
				while (j > 1 && StrCompare(arr[j], arr[j - 1], false) < 0) {
						tmp := arr[j]
						arr[j] := arr[j - 1]
						arr[j - 1] := tmp
						j -= 1
				}
		}
}
