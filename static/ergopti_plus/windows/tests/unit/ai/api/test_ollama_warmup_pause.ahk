; tests/unit/ai/api/test_ollama_warmup_pause.ahk

; ==============================================================================
; MODULE: Ollama Warmup Retry Under Pause
; DESCRIPTION:
; Native Suspend does not stop SetTimer callbacks, so the warmup retry tick and
; its scheduler must refuse every attempt while the driver is paused, or a
; paused driver keeps posting to Ollama (warmup-retry-bypasses-suspend, F26).
; The tick is a one-shot whose only other re-arm is on the success path, so it
; must re-arm before any transient skip, a pause included, and must not re-arm
; once the model is ready (F-21). An ordinary cancel keeps the backoff and
; invalidates in-flight callbacks; only a success resets the backoff (T-W05,
; F-12). Each case calls the real functions under a real Suspend, with no
; transport: a guard that let an attempt through would change the backoff or
; the start tick before any request could be built.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ State fixture =======
; ================================
; ================================

; Saves and restores every warmup global these cases write, and cancels the
; recording timer, so no case leaks a retry chain into the rest of the suite.
class _OWP_State {
	__New() {
		global _LLM_Ollama_WarmupRetryFn, _LLM_Ollama_WarmupPendingFn
		global _LLM_Ollama_WarmupHttp, _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupRetryModel
		global _LLM_Ollama_WarmupStartedTick, _LLM_Ollama_IsReady, _LLM_Ollama_WarmupGeneration
		global _LLM_Ollama_Async, _LLM_Menu
		this.HadRetry := IsSet(_LLM_Ollama_WarmupRetryFn)
		this.Retry := this.HadRetry ? _LLM_Ollama_WarmupRetryFn : 0
		this.HadPending := IsSet(_LLM_Ollama_WarmupPendingFn)
		this.Pending := this.HadPending ? _LLM_Ollama_WarmupPendingFn : 0
		this.Saved := [_LLM_Ollama_WarmupHttp, _LLM_Ollama_WarmupRetryIntervalMs,
			_LLM_Ollama_WarmupRetryModel, _LLM_Ollama_WarmupStartedTick, _LLM_Ollama_IsReady,
			_LLM_Ollama_WarmupGeneration, _LLM_Ollama_Async, _LLM_Menu]
		this.WasSuspended := A_IsSuspended
		this.Fired := 0
		this.Recorder := ObjBindMethod(this, "Record")
		_LLM_Ollama_WarmupHttp := 0
		_LLM_Ollama_WarmupPendingFn := 0
		_LLM_Ollama_WarmupRetryModel := "qwen3.5:0.8b"
		_LLM_Ollama_WarmupStartedTick := A_TickCount
		_LLM_Ollama_IsReady := false
		_LLM_Ollama_Async := Map()
		_LLM_Menu := Map("enabled", true)
	}

	Record() {
		this.Fired += 1
	}

	; Waits for the recording timer, which also runs while suspended.
	AwaitFired(TimeoutMs) {
		Started := A_TickCount
		while this.Fired == 0 && A_TickCount - Started < TimeoutMs
			Sleep(10)
		return this.Fired
	}

	Restore() {
		global _LLM_Ollama_WarmupRetryFn, _LLM_Ollama_WarmupPendingFn
		global _LLM_Ollama_WarmupHttp, _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupRetryModel
		global _LLM_Ollama_WarmupStartedTick, _LLM_Ollama_IsReady, _LLM_Ollama_WarmupGeneration
		global _LLM_Ollama_Async, _LLM_Menu
		SetTimer(this.Recorder, 0)
		if A_IsSuspended != this.WasSuspended
			Suspend(this.WasSuspended)
		_LLM_Ollama_WarmupRetryFn := this.HadRetry ? this.Retry : unset
		_LLM_Ollama_WarmupPendingFn := this.HadPending ? this.Pending : unset
		_LLM_Ollama_WarmupHttp := this.Saved[1]
		_LLM_Ollama_WarmupRetryIntervalMs := this.Saved[2]
		_LLM_Ollama_WarmupRetryModel := this.Saved[3]
		_LLM_Ollama_WarmupStartedTick := this.Saved[4]
		_LLM_Ollama_IsReady := this.Saved[5]
		_LLM_Ollama_WarmupGeneration := this.Saved[6]
		_LLM_Ollama_Async := this.Saved[7]
		_LLM_Menu := this.Saved[8]
	}
}





; ===========================
; ===========================
; ======= 2/ The tick =======
; ===========================
; ===========================

; Without its pause guard the tick doubles the backoff and asks the scheduler
; for a new attempt; without the re-arm ahead of the guard the chain ends at
; the first paused tick and never resumes.
_OWP_PausedTickRearmsWithoutAttempt() {
	global _LLM_Ollama_WarmupRetryFn, _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupGeneration
	global _LLM_Ollama_Async
	State := _OWP_State()
	try {
		_LLM_Ollama_WarmupRetryFn := State.Recorder
		_LLM_Ollama_WarmupRetryIntervalMs := 20
		Generation := _LLM_Ollama_WarmupGeneration
		Suspend(true)
		LLM_Ollama_WarmupRetryTick()
		AssertEqual(20, _LLM_Ollama_WarmupRetryIntervalMs, "a paused tick must not consume a warmup attempt")
		AssertEqual(Generation, _LLM_Ollama_WarmupGeneration, "a paused tick must not cancel or restart the warmup")
		AssertEqual(1, State.AwaitFired(2000), "a paused tick must re-arm so the retry chain resumes after the pause")
		; A prediction in flight is the other transient skip, and the normal state while typing.
		Suspend(false)
		State.Fired := 0
		_LLM_Ollama_Async := Map("in-flight", true)
		LLM_Ollama_WarmupRetryTick()
		AssertEqual(20, _LLM_Ollama_WarmupRetryIntervalMs, "a tick behind a prediction must not consume an attempt")
		AssertEqual(1, State.AwaitFired(2000), "a tick behind a prediction must re-arm the retry chain")
	} finally {
		State.Restore()
	}
}
Test("warmup retry: a paused tick re-arms without an attempt (warmup-retry-bypasses-suspend, F-21)",
	_OWP_PausedTickRearmsWithoutAttempt)

_OWP_ReadyTickEndsChain() {
	global _LLM_Ollama_WarmupRetryFn, _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_IsReady
	State := _OWP_State()
	try {
		_LLM_Ollama_WarmupRetryFn := State.Recorder
		_LLM_Ollama_WarmupRetryIntervalMs := 20
		_LLM_Ollama_IsReady := true
		LLM_Ollama_WarmupRetryTick()
		Sleep(150)
		AssertEqual(0, State.Fired, "a ready model must end the retry chain instead of re-arming it (F-21)")
		AssertEqual(20, _LLM_Ollama_WarmupRetryIntervalMs, "a ready model consumes no attempt")
	} finally {
		State.Restore()
	}
}
Test("warmup retry: a ready model ends the chain without a re-arm (F-21)", _OWP_ReadyTickEndsChain)





; ================================
; ================================
; ======= 3/ The scheduler =======
; ================================
; ================================

; The first dispatch is reachable from menu clicks while paused (F26). A ready
; model makes the unguarded path stop before any request, so the start tick and
; the target model alone show whether the scheduler ran.
_OWP_PausedScheduleRunsNothing() {
	global _LLM_Ollama_WarmupStartedTick, _LLM_Ollama_WarmupRetryModel, _LLM_Ollama_IsReady
	global _LLM_Ollama_WarmupRetryFn
	State := _OWP_State()
	try {
		_LLM_Ollama_WarmupRetryFn := 0
		_LLM_Ollama_IsReady := true
		_LLM_Ollama_WarmupStartedTick := 0
		_LLM_Ollama_WarmupRetryModel := ""
		Suspend(true)
		LLM_OllamaScheduleWarmupRetry("qwen3.5:0.8b")
		AssertEqual(0, _LLM_Ollama_WarmupStartedTick, "a paused scheduler must not open a warmup window")
		AssertEqual("", _LLM_Ollama_WarmupRetryModel, "a paused scheduler must not adopt a model")
		Suspend(false)
		LLM_OllamaScheduleWarmupRetry("qwen3.5:0.8b")
		AssertTrue(_LLM_Ollama_WarmupStartedTick != 0, "positive control: the resumed scheduler opens its window")
		AssertTrue(_LLM_Ollama_WarmupRetryModel != "", "positive control: the resumed scheduler adopts the model")
	} finally {
		State.Restore()
	}
}
Test("warmup retry: a paused scheduler runs nothing (F26)", _OWP_PausedScheduleRunsNothing)





; ===============================
; ===============================
; ======= 4/ Cancellation =======
; ===============================
; ===============================

_OWP_CancelKeepsBackoffUnlessReady() {
	global _LLM_Ollama_WarmupRetryFn, _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupGeneration
	State := _OWP_State()
	try {
		_LLM_Ollama_WarmupRetryFn := State.Recorder
		SetTimer(State.Recorder, -60000)
		_LLM_Ollama_WarmupRetryIntervalMs := 40000
		; Generation 0 means « no owner » to the completion, which would accept it.
		_LLM_Ollama_WarmupGeneration += 100
		Generation := _LLM_Ollama_WarmupGeneration
		AssertTrue(LLM_OllamaCancelWarmupRetry(), "a cancel with no request in flight succeeds")
		AssertEqual(40000, _LLM_Ollama_WarmupRetryIntervalMs, "an ordinary cancel must keep the grown backoff (T-W05)")
		AssertEqual(Generation + 1, _LLM_Ollama_WarmupGeneration,
			"a cancel must invalidate in-flight warmup callbacks (F-12)")
		AssertFalse(IsSet(_LLM_Ollama_WarmupRetryFn), "a cancel must release the retry timer")
		AssertTrue(LLM_OllamaCancelWarmupRetry(true), "a success cancel with no request in flight succeeds")
		AssertEqual(5000, _LLM_Ollama_WarmupRetryIntervalMs, "a success resets the backoff to its base")
		AssertEqual(Generation + 2, _LLM_Ollama_WarmupGeneration)
		; A late completion of the cancelled generation must not mark the model ready.
		_LLM_Ollama_OnWarmupDone(200, Generation)
		AssertFalse(LLM_OllamaIsReady(), "a cancelled warmup's late success must be ignored (F-12)")
	} finally {
		State.Restore()
	}
}
Test("warmup retry: the cancel a pause runs keeps the backoff and invalidates callbacks (T-W05, F-12)",
	_OWP_CancelKeepsBackoffUnlessReady)
