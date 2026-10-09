; static/ergopti_plus/windows/tests/meta/test_audit_2026_07_20_batch3.ahk

; ==============================================================================
; MODULE: Audit 2026-07-20 (second pass) — F-07, F-08, F-11, F-19, F-21
; DESCRIPTION:
; Data-integrity and lost-work defects. Four of the five are the same shape: a
; guard that was right to skip work while paused, but wrong to DROP it.
;
; F-07  KL_Stop() raised Keylogger._shutting_down only just before its trailing
;       KL_FlushBuffer(), i.e. AFTER six module drains that each emit a closing
;       lifecycle event through KL_AppendLog. Quitting or reloading while paused
;       therefore discarded session_end / idle_end / vpn_disconnected /
;       screen_recording_end / the final roi_snapshot, leaving events_session
;       with a dangling session_start — which poisons every active-time
;       aggregate downstream. Reload is the standard apply-settings path, so
;       this fired routinely. The old guard test asserted only that the flag
;       precedes the BOTTOM flush, which stayed true.
;
; F-08  KL_Hook_RefreshContext bailed bare on A_IsSuspended, freezing
;       app_entered_at / title_entered_at while wall-clock kept running. The
;       first refresh after resume then emitted an app_switch whose duration
;       spanned the whole pause, and KLW_WalkAppSwitch adds duration_ms verbatim
;       with no clamp — an overnight pause credited hours of screen time to
;       whichever app was focused, on the RESUME day. The existing gap
;       compensation in KL_Watchers_OnKeystroke cannot help: it is driven by the
;       first post-resume KEYSTROKE and the 250 ms timer always beats it.
;
; F-19  KL_AppCat_DeferredSave returned bare while paused, but that one-shot IS
;       the only write path: its sole other arm site registers the app key
;       BEFORE arming, so once the key exists that branch is unreachable for the
;       same app, and there is no periodic save and no KL_AppCat_Stop. A pause
;       inside the 5 s window stranded dirty=true forever.
;
; F-21  LLM_Ollama_WarmupRetryTick is a one-shot whose only re-arm sits at the
;       tail of the schedule function, so any early return ended the retry chain
;       for the session — including the in-flight-prediction guard, which is the
;       NORMAL state while typing.
;
; F-11  TAIL_CORRECTED was captured unbounded and fed to an O(n^2) allocating
;       token diff on the keystroke thread; only NEXT_WORDS was word-capped.
; ==============================================================================

#Requires AutoHotkey v2.0

; Root cause: the bypass flag must precede EVERY drain, not just the trailing
; flush. Enumerates the drains rather than asserting one position.
_A0720B3_ShutdownFlagPrecedesEveryDrain() {
	Body := _DriverFuncBody("KL_Stop")
	Assert(Body != "", "KL_Stop must exist in modules/keylogger/keylogger.ahk")

	FlagIdx := InStr(Body, "KL_BeginShutdown()")
	Assert(FlagIdx > 0, "KL_Stop must publish its shutdown lease through KL_BeginShutdown")
	BeginBody := _DriverFuncBody("KL_BeginShutdown")
	Assert(InStr(BeginBody, "_shutting_down := true") > 0,
		"KL_BeginShutdown must publish Keylogger._shutting_down := true")

	for _, Drain in ["KL_Hook_Stop()", "KL_Watchers_Stop()", "KL_Mouse_Stop()"
	               , "KL_AV_Stop()", "KL_Net_Stop()", "KL_Roi_Stop()"] {
		Idx := InStr(Body, Drain)
		if (Idx == 0)
			continue
		Assert(FlagIdx < Idx,
			"KL_Stop must publish _shutting_down BEFORE " . Drain . " — that drain emits a closing lifecycle event through KL_AppendLog, whose pause guard drops it while the flag is still false, leaving a dangling session_start after a quit or reload issued while paused")
	}
}
Test("keylogger: KL_Stop raises the shutdown bypass before every drain (F-07)",
	_A0720B3_ShutdownFlagPrecedesEveryDrain)


_A0720B3_PausedContextTicksDoNotBillAppTime() {
	Body := _DriverFuncBody("KL_Hook_RefreshContext")
	Assert(Body != "", "KL_Hook_RefreshContext must exist")

	GuardIdx := InStr(Body, "A_IsSuspended")
	Assert(GuardIdx > 0, "KL_Hook_RefreshContext must guard on A_IsSuspended")

	; Assert the ADVANCE form directly. A positional slice will not do here: the
	; suspended branch is itself the first mention of app_entered_at, so anchoring
	; on "the next occurrence" measures an empty span and passes vacuously.
	Assert(InStr(Body, "KLHook.suspend_tick") > 0,
		"KL_Hook_RefreshContext must track a suspend_tick watermark so the advance is per-tick and wrap-safe — a bare return freezes app_entered_at while wall-clock keeps running")
	; The advance is asserted through its OWNER rather than by pinning the `+=`
	; operator. A second compensation for the same span exists in
	; KL_Watchers_OnKeystroke, and after a long pause both fire — applied as two
	; raw `+=` they pushed the watermark past the present and the next app_switch
	; reported a NEGATIVE duration. The two now share one clamped advance, so the
	; invariant this assertion protects is unchanged (the paused interval must be
	; compensated) while its implementation has moved.
	Assert(InStr(Body, "KL_Hook_AdvanceContextWatermarks") > 0,
		"the A_IsSuspended branch must ADVANCE the context watermarks by the paused interval — otherwise the first refresh after resume emits an app_switch whose duration spans the whole pause, and KLW_WalkAppSwitch adds it to app_time with no clamp")

	Advance := _DriverFuncBody("KL_Hook_AdvanceContextWatermarks")
	Assert(Advance != "", "KL_Hook_AdvanceContextWatermarks must exist")
	Assert(RegExMatch(Advance, "app_entered_at\s*:=") > 0,
		"the shared advance must move app_entered_at")
	Assert(RegExMatch(Advance, "title_entered_at\s*:=") > 0,
		"the shared advance must move title_entered_at the same way — the window-switch path bills its duration identically")
	Assert(InStr(Advance, "Min(") > 0,
		"and it must clamp against the present, so two compensations for one paused span cannot push the watermark into the future")
}
Test("keylogger: a paused context tick is not billed as foreground app time (F-08)",
	_A0720B3_PausedContextTicksDoNotBillAppTime)


_A0720B3_DeferredSaveReArmsWhilePaused() {
	Body := _DriverFuncBody("KL_AppCat_DeferredSave")
	ScheduleBody := _DriverFuncBody("_KL_AppCat_ScheduleDeferredSave")
	Assert(Body != "" and ScheduleBody != "",
		"the deferred category save and timer owner must exist")

	GuardIdx := InStr(Body, "A_IsSuspended")
	Assert(GuardIdx > 0, "KL_AppCat_DeferredSave must guard on A_IsSuspended")
	Assert(InStr(Body, "_KL_AppCat_ScheduleDeferredSave()", , GuardIdx) > 0
		and InStr(ScheduleBody, "SetTimer") > 0,
		"the A_IsSuspended branch must RE-ARM its own one-shot rather than returning bare — this timer is the only path that persists a newly discovered app category, so dropping the tick strands KLAppCat.dirty forever")

	; This is WHY the re-arm is mandatory, and the part a symptom-level test
	; would miss: the other arm site cannot fire again for the same app.
	Get := _DriverFuncBody("KL_AppCat_Get")
	Assert(Get != "", "KL_AppCat_Get must exist")
	InsertIdx := InStr(Get, "KLAppCat.categories[key] :=")
	ArmIdx := InStr(Get, "_KL_AppCat_ScheduleDeferredSave()")
	Assert(InsertIdx > 0 and ArmIdx > 0 and InsertIdx < ArmIdx,
		"KL_AppCat_Get registers the app key BEFORE arming the one-shot, so it can never re-arm for that same app — which is exactly why the suspended branch has to re-arm itself")
}
Test("keylogger: a paused deferred save re-arms instead of stranding the write (F-19)",
	_A0720B3_DeferredSaveReArmsWhilePaused)


_A0720B3_WarmupChainSurvivesTransientSkips() {
	Body := _DriverFuncBody("LLM_Ollama_WarmupRetryTick")
	Assert(Body != "", "LLM_Ollama_WarmupRetryTick must exist")

	ReadyIdx := InStr(Body, "LLM_OllamaIsReady()")
	ReArmIdx := InStr(Body, "SetTimer(_LLM_Ollama_WarmupRetryFn")
	SuspendIdx := InStr(Body, "A_IsSuspended")
	AsyncIdx := InStr(Body, "_LLM_Ollama_Async.Count")

	Assert(ReadyIdx > 0 and ReArmIdx > 0 and SuspendIdx > 0 and AsyncIdx > 0,
		"prerequisite: the tick must still have its terminal check, its re-arm and both transient guards")
	Assert(ReadyIdx < ReArmIdx,
		"the TERMINAL condition (warmup already ready) must return BEFORE the re-arm, or the chain would never stop")
	Assert(ReArmIdx < SuspendIdx and ReArmIdx < AsyncIdx,
		"the re-arm must precede every TRANSIENT guard — this is a one-shot timer whose only other re-arm is on the success path, so a tick that merely skips one attempt (a prediction in flight is the normal state while typing) would otherwise end the retry chain for the whole session")
}
Test("llm-ollama: the warmup retry chain survives a transient skip (F-21)",
	_A0720B3_WarmupChainSurvivesTransientSkips)


_A0720B3_TailCorrectedIsWordCapped() {
	Body := _DriverFuncBody("_LLM_Parser_ProcessPredictionImpl")
	Assert(RegExMatch(Body, "tc\s*:=\s*_LLM_Parser_EnforceWordLimits\(tc,\s*max_words\)") > 0,
		"TAIL_CORRECTED must be word-capped like NEXT_WORDS before it reaches _LLM_Parser_TokenDiffOps — that diff is an O(n^2) dynamic program allocating per cell, len2 is unclamped, and it runs on the thread that serves the keyboard hook, so an unbounded correction from a model in a repetition loop stalls typing with nothing logged")
}
Test("llm-parser: TAIL_CORRECTED is capped before the token diff (F-11)",
	_A0720B3_TailCorrectedIsWordCapped)
