; tests/meta/test_deps_check_epoch_guard.ahk

; ==============================================================================
; MODULE: Deps Check Epoch Guard Meta Test
; DESCRIPTION:
; Regression guard for the epoch-based async-callback invalidation in the Ollama
; dependency checker (modules/llm/ollama_deps_checker.ahk, AHK-14).
;
; The deps checker fires asynchronous curl probes (LLM_OllamaIsRunning_Async).
; Before the fix, a second CheckAndInstall call or a Cancel() while a probe was
; in flight could cause its callback to run after the newer check had already
; updated state — leading to a stale "Ollama not running" result overwriting a
; successful one, or a cancelled install UI flash appearing after the user
; dismissed it.
;
; The fix introduces a global epoch counter (_LLM_Deps_Epoch). Every new check
; bumps the epoch; async callbacks capture the epoch at dispatch time and compare
; it on arrival. A mismatch means the check has been superseded — the callback
; discards its result and exits without touching shared state.
;
; This test asserts:
;   1. _LLM_Deps_Epoch is declared as a global counter variable.
;   2. The check entry function bumps _LLM_Deps_Epoch before dispatching the async probe.
;   3. The async callback reads _LLM_Deps_Epoch and discards stale results.
;   4. LLM_Deps_Cancel also bumps the epoch so in-flight probes invalidate themselves.
;
; SCOPE: source introspection of modules/llm/ollama_deps_checker.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_DCEG_ReadSource() {
	return _DriverDirConcat("modules/llm")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_DCEG_EpochGlobalDeclared() {
	Src := _DCEG_ReadSource()
	Assert(Src != "", "modules/llm/ source must be readable")

	Assert(InStr(Src, "_LLM_Deps_Epoch") > 0,
		"_LLM_Deps_Epoch must be declared as a global in ollama_deps_checker.ahk — the epoch counter is the single variable that lets all in-flight async callbacks detect that they have been superseded")
}

Test("deps_checker: _LLM_Deps_Epoch global is declared (deps-check-epoch-guard)",
	_DCEG_EpochGlobalDeclared)


_DCEG_CheckBumpsEpoch() {
	Src := _DCEG_ReadSource()
	Assert(Src != "", "modules/llm/ source must be readable")

	Body := _DriverFuncBody("LLM_Deps_CheckAndInstall")
	Assert(Body != "", "LLM_Deps_CheckAndInstall must be defined in ollama_deps_checker.ahk")

	Assert(InStr(Body, "_LLM_Deps_Epoch") > 0,
		"LLM_Deps_CheckAndInstall must reference _LLM_Deps_Epoch to bump the counter before dispatching the async probe — without the bump, a second check cannot invalidate the first check's callback")
	Assert(InStr(Body, "+= 1") > 0 or InStr(Body, "+ 1") > 0,
		"LLM_Deps_CheckAndInstall must increment _LLM_Deps_Epoch so each new check cycle has a unique identity")
}

Test("deps_checker: LLM_Deps_CheckAndInstall bumps _LLM_Deps_Epoch (deps-check-epoch-guard)",
	_DCEG_CheckBumpsEpoch)


_DCEG_CallbackDiscardsOnEpochMismatch() {
	Src := _DCEG_ReadSource()
	Assert(Src != "", "modules/llm/ source must be readable")

	; The result callback must compare captured_epoch to _LLM_Deps_Epoch
	Assert(InStr(Src, "captured_epoch") > 0,
		"ollama_deps_checker.ahk must use a 'captured_epoch' local to snapshot _LLM_Deps_Epoch at dispatch time — the callback compares the snapshot to the global on arrival and discards stale results")
	Assert(InStr(Src, "captured_epoch != _LLM_Deps_Epoch") > 0,
		"The async callback must check 'captured_epoch != _LLM_Deps_Epoch' and return early when they differ — this is the guard that prevents a superseded check from overwriting the state set by the newer check")
}

Test("deps_checker: async callback discards result on epoch mismatch (deps-check-epoch-guard)",
	_DCEG_CallbackDiscardsOnEpochMismatch)


_DCEG_CancelAlsoBumpsEpoch() {
	Src := _DCEG_ReadSource()
	Assert(Src != "", "modules/llm/ source must be readable")

	Body := _DriverFuncBody("LLM_Deps_Cancel")
	Assert(Body != "", "LLM_Deps_Cancel must be defined in ollama_deps_checker.ahk")

	Assert(InStr(Body, "_LLM_Deps_Epoch") > 0,
		"LLM_Deps_Cancel must bump _LLM_Deps_Epoch — a cancel without an epoch bump allows the in-flight probe callback to still execute and modify state after the cancel was requested")
}

Test("deps_checker: LLM_Deps_Cancel bumps _LLM_Deps_Epoch to invalidate in-flight probes (deps-check-epoch-guard)",
	_DCEG_CancelAlsoBumpsEpoch)
