; modules/llm/ollama_deps_checker.ahk

; ==============================================================================
; MODULE: Ollama Dependencies Checker
; DESCRIPTION:
; Windows equivalent of the Hammerspoon ollama_deps_checker.lua.
; Ensures the Ollama binary is installed and the local inference server is
; reachable on the configured local Ollama endpoint.
;
; FEATURES & RATIONALE:
; 1. Self-bootstrapping: hands install off to winget (native Ollama installer
;    with its own progress UI) or opens the download page as a fallback — zero
;    manual setup for the user.
; 2. Silent fast path: when Ollama is already running, the check exits in
;    milliseconds with no UI shown.
; 3. No-block execution: the Ollama reachability check runs from a SetTimer
;    callback — never from the main AHK thread — so the keyboard and hotkeys
;    remain fully responsive during install.
; 4. Epoch-guarded async: every async callback captures the epoch at dispatch
;    time and discards itself when a newer check or Cancel() has bumped the
;    counter, preventing stale callbacks from corrupting shared state.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ State & Constants =======
; ====================================
; ====================================

; AHK-30: ceiling for the daemon-reachability poll to prevent AHK from being
; held at High priority indefinitely when the user installs Ollama via the
; browser fallback and then abandons the install without clicking Cancel.
global LLM_DEPS_POLL_TIMEOUT_MS := 1800000      ; 30 min; matches typical installer upper bound

global _LLM_Deps_State          := "pending"   ; "pending" | "ready" | "failed"
global _LLM_Deps_FailureMessage := ""
global _LLM_Deps_Checking       := false        ; guard against concurrent calls
; AHK-14: epoch counter — bumped every time a new check starts (or is cancelled).
; Async callbacks capture the epoch at dispatch time and discard themselves when
; the captured epoch no longer matches the global, preventing a preempted silent
; check's late callback from clearing _LLM_Deps_Checking that now belongs to a
; newer check.
global _LLM_Deps_Epoch          := 0
global _LLM_Deps_PollTimer      := unset        ; lambda reference kept for explicit cancellation
global _LLM_Deps_PollStartTick  := 0            ; TickCount when RunInstaller armed the poll timer
; PID of the running PowerShell installer, or 0 when no install is in
; flight. LLM_Deps_Cancel reads this to terminate the process tree when
; the user clicks Cancel in the WebView — without it, closing the
; window would leave a hidden powershell.exe downloading qwen2.5:3b
; in the background indefinitely.
global _LLM_Deps_InstallerPid   := 0





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
	SetTimer(() => LLM_Deps_AsyncCheck(default_model, on_ready, on_failed,
		show_ui, captured_epoch), -50)
}

/**
 * Phase 1 of the async bootstrap: shows the UI (which calls WebView2.create
 * synchronously and blocks ~1 s), then defers the blocking HTTP check to a
 * second timer so the window gets at least one paint cycle before freezing.
 * For the silent auto-boot path (show_ui=false) the UI is skipped and the
 * HTTP check runs immediately (no window to paint anyway).
 */
LLM_Deps_AsyncCheck(default_model, on_ready, on_failed, show_ui,
		captured_epoch) {
	global _LLM_Deps_Epoch
	if captured_epoch != _LLM_Deps_Epoch
		return false

	; No more WebView2 + hidden-PowerShell UI. We hand the install off to
	; winget (or the Ollama download page in the browser); the user gets
	; the official installer's native UI, which is more familiar AND
	; doesn't contest CPU/disk with the AHK input pipeline. Run the
	; reachability check directly — there's nothing left to "paint" first.
	LLM_Deps_DoCheck(default_model, captured_epoch, on_ready, on_failed, show_ui)
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

_LLM_Deps_DoCheck_Result(running, t_start, captured_epoch, default_model, on_ready?, on_failed?, show_ui?) {
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
	if running {
		LoggerInfo("LLM", "Ollama already running — fast path, state → ready.")
		_LLM_Deps_State    := "ready"
		_LLM_Deps_Checking := false
		if IsSet(on_ready)
			on_ready()
		return
	}

	; When called from the auto-boot path (show_ui=false), do not open the
	; install window — the user has not asked for an installation.
	if IsSet(show_ui) && !show_ui {
		LoggerInfo("LLM", "Ollama not running but show_ui=false — silent abort, state stays pending.")
		_LLM_Deps_Checking := false
		return
	}

	LoggerInfo("LLM", "Ollama not running — launching installer…")
	LLM_Deps_RunInstaller(default_model, captured_epoch, on_ready?, on_failed?)
}





; ======================================
; ======================================
; ======= 4/ Installer Execution =======
; ======================================
; ======================================

/**
 * Hands Ollama installation off to the OS-native installer flow, then
 * polls every 3 s until the daemon answers.
 *
 * Why the simpler approach:
 *   - The previous in-process PS1 installer downloaded a ~1.5 GB exe
 *     via ``Invoke-WebRequest -OutFile`` (no progress streaming), then
 *     ran ``Start-Process -Wait``. The hidden powershell process spent
 *     10+ minutes contesting CPU + disk with the AHK input pipeline,
 *     causing the user's keystrokes to be swallowed mid-typing. Worse,
 *     the WebView never showed download progress (Invoke-WebRequest
 *     doesn't stream stdout), so the user thought it was frozen.
 *   - winget is the supported Microsoft package manager on every
 *     Win 10 / 11 machine. It runs the OFFICIAL Ollama installer with
 *     a normal UAC prompt and progress UI. The download is throttled
 *     to a separate process tree so AHK's keystroke handling stays
 *     responsive.
 *   - Fallback to opening https://ollama.com/download in the default
 *     browser when winget is not available. The user keeps full
 *     control over the install experience and we don't have to babysit
 *     a hidden subprocess.
 *
 * After the installer has been handed off, we keep a 3 s poll timer
 * pinging the configured local Ollama endpoint. Once Ollama answers, the state
 * flips to "ready" and on_ready fires.
 *
 * @param {string} model - Model tag to pull AFTER the daemon is up.
 *                         Currently the responsibility is on the user
 *                         (Ollama's first-run flow handles it via the
 *                         installer's wizard), so this argument is
 *                         only kept for future use.
 * @param {Func} on_ready - Callback on success.
 * @param {Func} on_failed - Callback on failure (rare — only when we
 *                           can't even launch the installer).
 */
LLM_Deps_RunInstaller(model, captured_epoch, on_ready?, on_failed?) {
	global _LLM_Deps_PollTimer, _LLM_Deps_Checking, _LLM_Deps_Epoch
	if captured_epoch != _LLM_Deps_Epoch
		return false

	; Boost AHK's own priority BEFORE we kick the installer off. Any heavy
	; download — winget, the browser's download manager, the OllamaSetup
	; exe itself — contests CPU and disk with the AHK message loop. If
	; AHK loses scheduling slots, the PrefixWatcher's InputHook misses
	; OnChar callbacks and characters get silently dropped from the
	; user's typing. Pinning AHK to High keeps the keyboard responsive
	; even when the OS is otherwise saturated.
	try ProcessSetPriority("High")

	; Launch winget directly. A prior ``where winget`` RunWait blocked the menu
	; action on AHK's sole thread just to answer this question. Run already gives
	; us the authoritative result: success yields the installer PID; a missing
	; command throws and immediately selects the browser fallback below.
	winget_available := true
	LoggerInfo("LLM", "Handing off to winget install Ollama.Ollama (BelowNormal priority)…")
	try {
		; Launch winget directly so the captured PID is the real process tree root.
		; taskkill /F /T can then reach it on Cancel. We deliberately omit cmd /c
		; start so the PID is not an ephemeral shell that leaves winget detached.
		global _LLM_Deps_InstallerPid
		Run('winget install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements', , "Hide", &_LLM_Deps_InstallerPid)
		LoggerInfo("LLM", "winget command launched (PID=" _LLM_Deps_InstallerPid ").")
	} catch as err {
		LoggerInfo("LLM", "winget is unavailable; opening browser fallback: " err.Message ".")
		winget_available := false
	}

	if !winget_available {
		LoggerInfo("LLM", "Opening https://ollama.com/download in the default browser.")
		try {
			Run('https://ollama.com/download')
		} catch as err {
			LoggerError("LLM", "Could not open the download page: " err.Message ".")
			LLM_Deps_Fail(t("menu.llm.deps_download_page_failed"),
				on_failed, captured_epoch)
			return
		}
		; Surface a tray tip so the user knows what to do — without it,
		; the browser opening out of nowhere can feel disconnected from
		; their click in the menu.
		try TrayTip("Ergopti — IA", t("llm.deps.browser_install_tip"), 0x1)
	}

	; Poll the daemon every 3 s. When it answers, fire on_ready.
	global LLM_OLLAMA_BASE_URL
	LoggerInfo("LLM", "Polling {1} every 3 s until Ollama responds…",
		LLM_OLLAMA_BASE_URL)
	global _LLM_Deps_PollStartTick := A_TickCount
	_LLM_Deps_PollTimer := () => LLM_Deps_PollServerReady(
		on_ready?, on_failed?, captured_epoch)
	SetTimer(_LLM_Deps_PollTimer, 3000)
}

/**
 * Poll callback set up by LLM_Deps_RunInstaller. Fires every 3 s; checks
 * whether Ollama is reachable. As soon as it answers, the install is
 * considered done (regardless of HOW the user installed it — via winget,
 * a manual download, or anything else).
 */
LLM_Deps_PollServerReady(on_ready?, on_failed?, captured_epoch := 0) {
	if A_IsSuspended
		return
	global _LLM_Deps_State, _LLM_Deps_Checking, _LLM_Deps_PollTimer, _LLM_Deps_Epoch
	global _LLM_Deps_PollStartTick, LLM_DEPS_POLL_TIMEOUT_MS
	if captured_epoch != _LLM_Deps_Epoch
		return false
	; AHK-30: bound the poll so a user who installs via the browser fallback
	; and then abandons the install without clicking Cancel does not leave AHK
	; pinned at High priority indefinitely.
	elapsed := (A_TickCount - _LLM_Deps_PollStartTick) & 0xFFFFFFFF
	if (elapsed >= LLM_DEPS_POLL_TIMEOUT_MS) {
		LoggerWarn("LLM", "Daemon poll timed out after " Round(elapsed / 60000) " min — aborting.")
		if IsSet(_LLM_Deps_PollTimer)
			SetTimer(_LLM_Deps_PollTimer, 0)
		LLM_Deps_Fail(t("llm.deps.fail_timeout"), on_failed?, captured_epoch)
		return
	}
	; ASYNC probe — never call the sync LLM_OllamaIsRunning here. When
	; Ollama isn't installed yet, that sync call blocks the message loop
	; for ~4 s (4 × 1 s WinHTTP phases) at every poll tick. With the
	; timer firing every 3 s, AHK was effectively frozen the entire
	; install — the user's typing lagged hard for as long as the install
	; ran. The async version dispatches the probe to WinHTTP's
	; background thread and the result lands in a separate callback.
	; AHK-14: capture epoch so the poll callback can detect preemption.
	captured_epoch := _LLM_Deps_Epoch
	try LLM_OllamaIsRunning_Async((reachable) => _LLM_Deps_OnPollProbeResult(reachable, captured_epoch, on_ready?, on_failed?))
}

/**
 * Callback for the async probe scheduled by LLM_Deps_PollServerReady.
 * Fires once Ollama answers (or fails to) on a given tick. When
 * reachable, we finalise the install; otherwise we just wait for the
 * next 3 s tick — no work done on the main thread.
 */
_LLM_Deps_OnPollProbeResult(reachable, captured_epoch, on_ready?, on_failed?) {
	global _LLM_Deps_State, _LLM_Deps_Checking, _LLM_Deps_PollTimer, _LLM_Deps_Epoch, DRIVER_BASELINE_PRIORITY_CLASS
	; AHK-14: discard stale poll callbacks from a preempted or cancelled check.
	if (captured_epoch != _LLM_Deps_Epoch) {
		LoggerInfo("LLM", "OnPollProbeResult — stale epoch " captured_epoch " (current=" _LLM_Deps_Epoch "), discarding.")
		return
	}
	if !reachable
		return    ; still not up — next tick will probe again
	LoggerInfo("LLM", "Ollama is now reachable — install complete.")
	if IsSet(_LLM_Deps_PollTimer)
		SetTimer(_LLM_Deps_PollTimer, 0)
	_LLM_Deps_State    := "ready"
	_LLM_Deps_Checking := false
	; Restore the driver baseline (not a hardcoded "Normal") — must stay in
	; sync with the boot-time boost class (driver-baseline-priority-reverted-to-normal).
	try ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)
	if IsSet(on_ready)
		on_ready()
}

/**
 * Cancels an in-flight Ollama install: kills the hidden PowerShell tree
 * and stops the poll timer. Safe to call when nothing is running — it
 * just resets the state flags.
 *
 * Called from LLM_Deps_OnUserCancel (Cancel button) and from
 * LLM_Menu_OnToggle when the user disables the feature mid-install.
 * Without this, the install kept running in the background even after
 * the user closed every visible cue.
 */
LLM_Deps_Cancel() {
	global _LLM_Deps_InstallerPid, _LLM_Deps_PollTimer, _LLM_Deps_Checking, _LLM_Deps_State, _LLM_Deps_Epoch, DRIVER_BASELINE_PRIORITY_CLASS

	if _LLM_Deps_InstallerPid {
		LoggerInfo("LLM", "Cancel — killing installer PID=" _LLM_Deps_InstallerPid " and its child tree.")
		; Use taskkill /T to terminate the whole process tree (powershell
		; spawns ollama.exe + curl.exe for the model pull). /F forces
		; termination even when the process is mid-IO.
		try Run('taskkill /F /T /PID ' _LLM_Deps_InstallerPid, , "Hide")
		_LLM_Deps_InstallerPid := 0
	}
	if IsSet(_LLM_Deps_PollTimer) and _LLM_Deps_PollTimer {
		try SetTimer(_LLM_Deps_PollTimer, 0)
		_LLM_Deps_PollTimer := unset
	}
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
}

/**
 * Records a permanent failure, updates state, shows error in WebView, fires callback.
 * @param {string} msg - Human-readable failure reason.
 * @param {Func} on_failed - Optional callback.
 */
LLM_Deps_Fail(msg, on_failed, captured_epoch := 0) {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking, _LLM_Deps_Epoch, DRIVER_BASELINE_PRIORITY_CLASS
	if captured_epoch && captured_epoch != _LLM_Deps_Epoch
		return false
	LoggerError("LLM", "Deps failure: " msg)
	_LLM_Deps_State          := "failed"
	_LLM_Deps_FailureMessage := msg
	_LLM_Deps_Checking       := false
	; AHK-30: restore the driver baseline priority — the install ran with AHK
	; boosted to High. Mirror of the same restore in LLM_Deps_Cancel. MUST use
	; the shared constant, not a hardcoded "Normal" literal
	; (driver-baseline-priority-reverted-to-normal).
	try ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)
	if IsSet(on_failed)
		on_failed(msg)
	return true
}
