; ai/engine/ollama/deps_checker.ahk

; ==============================================================================
; MODULE: Ollama Dependencies Checker
; DESCRIPTION:
; Windows equivalent of the Hammerspoon ollama_deps_checker.lua.
; Ensures the Ollama binary is installed and the local inference server is
; reachable on the configured local Ollama endpoint.
;
; Production bootstrap consumes exact app-owned file/runtime components with
; independent installation, start and model consent. Only that owned runtime
; is ever used: a listener Ergopti does not own is refused, never adopted, stopped
; or modified. Deferred callbacks retain their captured epoch.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\_generated\identifiers.ahk
#Include managed_bootstrap.ahk





; ====================================
; ====================================
; ======= 1/ State & Constants =======
; ====================================
; ====================================

; Ceiling of the dependency bootstrap.
; Sentinel 0 — sourced at boot from [llm].dependency_bootstrap_timeout_ms.
global LLM_DEPS_POLL_TIMEOUT_MS := 0

global _LLM_Deps_State          := "pending"   ; "pending" | "ready" | "failed"
global _LLM_Deps_FailureMessage := ""
global _LLM_Deps_Checking       := false        ; guard against concurrent calls
; AHK-14: epoch counter — bumped every time a new check starts (or is cancelled).
; Async callbacks capture the epoch at dispatch time and discard themselves when
; the captured epoch no longer matches the global, preventing a preempted silent
; check's late callback from clearing _LLM_Deps_Checking that now belongs to a
; newer check.
global _LLM_Deps_Epoch          := 0





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

/**
 * Returns the current bootstrap state.
 * @returns {string} "pending" | "ready" | "failed"
 */
LLM_Deps_GetState() {
	global _LLM_Deps_State
	return _LLM_Deps_State
}

/**
 * Returns true only when the Ollama server is confirmed reachable.
 * @returns {boolean}
 */
LLM_Deps_IsReady() {
	global _LLM_Deps_State
	return _LLM_Deps_State == "ready"
}

/**
 * Returns true when the bootstrap definitively failed.
 * @returns {boolean}
 */
LLM_Deps_HasFailed() {
	global _LLM_Deps_State
	return _LLM_Deps_State == "failed"
}

/**
 * Returns true while a bootstrap check or install runs.
 * @returns {boolean}
 */
LLM_Deps_IsChecking() {
	global _LLM_Deps_Checking
	return _LLM_Deps_Checking
}

/**
 * Returns the last failure message captured from the installer, or "".
 * @returns {string}
 */
LLM_Deps_GetFailureMessage() {
	global _LLM_Deps_FailureMessage
	return _LLM_Deps_FailureMessage
}





; ========================================
; ========================================
; ======= 3/ Bootstrap Entry Point =======
; ========================================
; ========================================

/**
 * Asynchronously verifies and bootstraps the Ollama backend.
 * Safe to call repeatedly: fast-paths silently when already running.
 * The reachability check itself runs from a one-shot timer so the
 * main AHK thread (and therefore the keyboard) is never blocked.
 * @param {string} default_model - Ollama tag to pull if not yet available.
 * @param {Func}   on_ready      - Optional callback fired when the server is confirmed ready.
 * @param {Func}   on_failed     - Optional callback fired on permanent failure.
 * @param {boolean} show_ui      - When false, suppresses the install window on auto-boot.
 *                                 Pass true only when the user explicitly triggered the install.
 */
LLM_Deps_CheckAndInstall(default_model := "", on_ready := unset, on_failed := unset, show_ui := true) {
	global _LLM_Deps_Checking, _LLM_Deps_State, _LLM_Deps_Epoch

	LoggerInfo("LLM", "CheckAndInstall — state: " _LLM_Deps_State ", checking: " (_LLM_Deps_Checking ? "true" : "false") " show_ui=" (show_ui ? "true" : "false") ".")

	; Guard: only one concurrent bootstrap — EXCEPT when the user
	; explicitly asked for a visible install (show_ui=true). The boot
	; sequence kicks off a silent reachability check (show_ui=false)
	; that can take up to 20 s to time out when Ollama isn't installed.
	; During that window the warning-row click used to silently skip
	; here, leaving the user waiting forever for ``nothing happens''.
	; Now we cancel the in-flight silent check and continue with the
	; explicit install.
	if _LLM_Deps_Checking {
		if show_ui {
			LoggerInfo("LLM", "Preempting silent check in progress — user asked for visible install.")
			try LLM_Deps_Cancel()
		} else {
			LoggerInfo("LLM", "CheckAndInstall — already in progress, skipping.")
			return
		}
	}
	; AHK-14: bump epoch so any in-flight async callback from the preempted
	; check recognises itself as stale and discards its result without clearing
	; _LLM_Deps_Checking that now belongs to this newer check.
	_LLM_Deps_Epoch   += 1
	captured_epoch := _LLM_Deps_Epoch
	_LLM_Deps_Checking := true

	; Reset failure state so a re-try after a failed install can proceed
	if (_LLM_Deps_State == "failed")
		_LLM_Deps_State := "pending"

	; Defer everything to a timer so the menu can close and the message loop
	; can process pending paint events before any blocking call (WinHTTP, WebView2).
	LoggerInfo("LLM", "Scheduling async Ollama reachability check…")
	SetTimer(() => LLM_Deps_AsyncCheck(default_model, on_ready?, on_failed?,
		show_ui, captured_epoch), -50)
}

/**
 * Phase 1 of the async bootstrap: shows the UI (which calls WebView2.create
 * synchronously and blocks ~1 s), then defers the blocking HTTP check to a
 * second timer so the window gets at least one paint cycle before freezing.
 * For the silent auto-boot path (show_ui=false) the UI is skipped and the
 * HTTP check runs immediately (no window to paint anyway).
 */
LLM_Deps_AsyncCheck(default_model, on_ready?, on_failed?, show_ui := true,
		captured_epoch := 0) {
	global _LLM_Deps_Epoch
	if captured_epoch != _LLM_Deps_Epoch
		return false

	; Check the owned endpoint before offering a managed installation. A
	; responding foreign server is never adopted, migrated or terminated.
	LLM_Deps_DoCheck(default_model, captured_epoch, on_ready?, on_failed?, show_ui)
	return true
}

/**
 * Phase 2 of the async bootstrap: performs the blocking HTTP reachability
 * check and either fast-paths (already running) or launches the installer.
 */
LLM_Deps_DoCheck(default_model, captured_epoch, on_ready?, on_failed?, show_ui?) {
	global _LLM_Deps_Epoch
	if captured_epoch != _LLM_Deps_Epoch
		return false

	t_start := A_TickCount
	LoggerInfo("LLM", "DoCheck — checking if Ollama is running…")
	LLM_OllamaIsRunning_Async((running) => _LLM_Deps_DoCheck_Result(running, t_start, captured_epoch, default_model, on_ready?, on_failed?, show_ui?))
	return true
}

_LLM_Deps_DoCheck_Result(running, t_start, captured_epoch, default_model, on_ready?, on_failed?, show_ui?, InstallerFn := 0, OwnedFn := 0) {
	global _LLM_Deps_Checking, _LLM_Deps_State, _LLM_Deps_Epoch
	; AHK-14: discard stale callbacks from preempted checks. When Cancel() or a
	; second CheckAndInstall bumps the epoch, any in-flight curl callback fires
	; with a captured_epoch that no longer matches — bail without touching the
	; shared state that now belongs to the newer check.
	if (captured_epoch != _LLM_Deps_Epoch) {
		LoggerInfo("LLM", "DoCheck_Result — stale epoch " captured_epoch " (current=" _LLM_Deps_Epoch "), discarding.")
		return
	}
	LoggerInfo("LLM", "DoCheck — Ollama reachability check took " TickElapsed(t_start) " ms, result=" (running ? "running" : "not running") ".")
	Owned := HasMethod(OwnedFn, "Call") ? OwnedFn.Call() : LLM_OllamaManagedOriginRequired()
	if running && !Owned {
		; Ergopti's daemon dies with its driver, so an answer with no live owner
		; is a foreign server: refused, and an explicit start then names the
		; occupied port instead of chatting to someone else's Ollama.
		LoggerWarn("LLM", "A server Ergopti does not own answers on its Ollama port; it is not used.")
		if IsSet(show_ui) && !show_ui {
			_LLM_Deps_Checking := false
			return
		}
	}
	if running && Owned {
		LoggerInfo("LLM", "Ollama already running — fast path, state → ready.")
		_LLM_Deps_State    := "ready"
		_LLM_Deps_Checking := false
		if IsSet(on_ready)
			on_ready()
		return
	}

	Installer := HasMethod(InstallerFn, "Call") ? InstallerFn : LLM_Deps_RunManagedInstaller
	; The auto-boot path (show_ui=false) restarts the installed runtime with no
	; window; it never installs one, since the user has not asked for that.
	if IsSet(show_ui) && !show_ui {
		LoggerInfo("LLM", "Ollama not running and show_ui=false — restarting the owned runtime silently.")
		return Installer.Call(default_model, captured_epoch, on_ready?, on_failed?, true)
	}

	LoggerInfo("LLM", "Ollama not running — launching installer…")
	return Installer.Call(default_model, captured_epoch, on_ready?, on_failed?)
}





; ======================================
; ======================================
; ======= 4/ Cancel and Failures =======
; ======================================
; ======================================

/**
 * Cancels an in-flight Ollama install through the managed bootstrap owner. Safe
 * to call when nothing is running — it just resets the state flags.
 *
 * Called from LLM_Deps_OnUserCancel (Cancel button) and from
 * LLM_Menu_OnToggle when the user disables the feature mid-install.
 * Without this, the install kept running in the background even after
 * the user closed every visible cue.
 */
LLM_Deps_Cancel() {
	global _LLM_Deps_Checking, _LLM_Deps_State, _LLM_Deps_Epoch, DRIVER_BASELINE_PRIORITY_CLASS

	ManagedStopped := LLM_ManagedBootstrapCancel()
	; AHK-14: bump epoch so in-flight async callbacks from the cancelled check
	; recognise themselves as stale (captured epoch != _LLM_Deps_Epoch) and
	; bail before touching _LLM_Deps_Checking or _LLM_Deps_State.
	_LLM_Deps_Epoch   += 1
	_LLM_Deps_Checking := false
	; State stays "pending" — the user explicitly aborted, but the next
	; toggle ON should be able to retry the install cleanly.
	_LLM_Deps_State := "pending"
	; Restore the driver baseline priority — the install was running with AHK
	; boosted to High. Cancelling means we no longer need the boost. MUST use
	; the shared constant, not a hardcoded "Normal" literal
	; (driver-baseline-priority-reverted-to-normal).
	try ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)
	return ManagedStopped
}

; Stop the managed bootstrap before lifecycle teardown becomes irreversible.
LLM_Deps_PrepareShutdown() {
	return LLM_ManagedBootstrapCancel()
}

/**
 * Records a permanent failure, updates state, shows error in WebView, fires callback.
 * @param {string} msg - Human-readable failure reason.
 * @param {Func} on_failed - Optional callback.
 */
LLM_Deps_Fail(msg, on_failed?, captured_epoch := 0) {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking, _LLM_Deps_Epoch, DRIVER_BASELINE_PRIORITY_CLASS
	if captured_epoch && captured_epoch != _LLM_Deps_Epoch
		return false
	return _LLM_Deps_PublishFailure(msg, on_failed?, captured_epoch, ProcessSetPriority)
}

; Failure publication must not retry cancellation or discard a retained owner.
_LLM_Deps_PublishFailure(msg, on_failed?, captured_epoch := 0, PriorityFn := 0) {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking, _LLM_Deps_Epoch, DRIVER_BASELINE_PRIORITY_CLASS
	if captured_epoch && captured_epoch != _LLM_Deps_Epoch
		return false
	LoggerError("LLM", "Deps failure: " msg)
	; Logging can yield to real cancellation. Only the captured epoch may
	; atomically publish the three dependency-state fields; no I/O runs here.
	PreviousCritical := Critical("On")
	try {
		if captured_epoch && captured_epoch != _LLM_Deps_Epoch
			return false
		_LLM_Deps_State          := "failed"
		_LLM_Deps_FailureMessage := msg
		_LLM_Deps_Checking       := false
	} finally Critical(PreviousCritical)
	; AHK-30: restore the driver baseline priority — the install ran with AHK
	; boosted to High. Mirror of the same restore in LLM_Deps_Cancel. MUST use
	; the shared constant, not a hardcoded "Normal" literal
	; (driver-baseline-priority-reverted-to-normal).
	if !HasMethod(PriorityFn, "Call")
		PriorityFn := ProcessSetPriority
	if captured_epoch && captured_epoch != _LLM_Deps_Epoch
		return false
	try PriorityFn.Call(DRIVER_BASELINE_PRIORITY_CLASS)
	; The priority port is a callout too; a cancellation there must not
	; deliver the old business callback into the new dependency epoch.
	if captured_epoch && captured_epoch != _LLM_Deps_Epoch
		return false
	if IsSet(on_failed)
		on_failed(msg)
	return true
}
