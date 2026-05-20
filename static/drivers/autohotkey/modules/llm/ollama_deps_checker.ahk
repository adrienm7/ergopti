; modules/llm/ollama_deps_checker.ahk

; ==============================================================================
; MODULE: Ollama Dependencies Checker
; DESCRIPTION:
; Windows equivalent of the Hammerspoon ollama_deps_checker.lua.
; Ensures the Ollama binary is installed and the local inference server is
; reachable on http://localhost:11434. The heavy lifting is done by the shared
; PowerShell installer (_shared/llm/install/ollama_install.ps1); this module
; handles async invocation, output parsing, and drives the shared WebView2
; download_window UI (ollama_webview.ahk) — the same HTML/CSS/JS used on macOS.
;
; FEATURES & RATIONALE:
; 1. Self-bootstrapping: runs the shared PS1 installer silently, pulling the
;    configured default model automatically — zero manual setup for the user.
; 2. Silent fast path: when Ollama is already running, the check exits in
;    milliseconds with no UI shown.
; 3. Shared WebView UI: drives setKind / setStep / setDetail / addLog / update /
;    done via OllamaWV_* so macOS and Windows show the same window.
; 4. Rich progress parsing: extracts percentage, downloaded/total size, speed,
;    and ETA from ollama pull output lines and pushes them to the UI.
; 5. No-block execution: the Ollama reachability check and PS1 process are run
;    from a SetTimer callback — never from the main AHK thread — so the
;    keyboard and hotkeys remain fully responsive during install.
; 6. Hidden PowerShell: stdout is redirected to a temp file so no console
;    window appears; the poll timer tails that file every 500 ms.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 1/ State & Constants =======
; ==========================================
; ==========================================

global _LLM_Deps_State          := "pending"   ; "pending" | "ready" | "failed"
global _LLM_Deps_FailureMessage := ""
global _LLM_Deps_Checking       := false        ; guard against concurrent calls
global _LLM_Deps_PollTimer      := unset        ; lambda reference kept for explicit cancellation
global _LLM_Deps_OutFile        := ""           ; temp file path for PS1 stdout
global _LLM_Deps_OutPos         := 0            ; byte offset already consumed from OutFile
; PID of the running PowerShell installer, or 0 when no install is in
; flight. LLM_Deps_Cancel reads this to terminate the process tree when
; the user clicks Cancel in the WebView — without it, closing the
; window would leave a hidden powershell.exe downloading qwen2.5:3b
; in the background indefinitely.
global _LLM_Deps_InstallerPid   := 0




; ====================================
; ====================================
; ======= 2/ Public API =======
; ====================================
; ====================================

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




; ============================================
; ============================================
; ======= 3/ Bootstrap Entry Point =======
; ============================================
; ============================================

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
LLM_Deps_CheckAndInstall(default_model := "qwen2.5:3b", on_ready := unset, on_failed := unset, show_ui := true) {
	global _LLM_Deps_Checking, _LLM_Deps_State

	LoggerInfo("LLM", "CheckAndInstall — state: " _LLM_Deps_State ", checking: " (_LLM_Deps_Checking ? "true" : "false") " show_ui=" (show_ui ? "true" : "false") ".")

	; Guard: only one concurrent bootstrap
	if _LLM_Deps_Checking {
		LoggerInfo("LLM", "CheckAndInstall — already in progress, skipping.")
		return
	}
	_LLM_Deps_Checking := true

	; Reset failure state so a re-try after a failed install can proceed
	if (_LLM_Deps_State == "failed")
		_LLM_Deps_State := "pending"

	; Defer everything to a timer so the menu can close and the message loop
	; can process pending paint events before any blocking call (WinHTTP, WebView2).
	LoggerInfo("LLM", "Scheduling async Ollama reachability check…")
	SetTimer(() => LLM_Deps_AsyncCheck(default_model, on_ready, on_failed, show_ui), -50)
}

/**
 * Phase 1 of the async bootstrap: shows the UI (which calls WebView2.create
 * synchronously and blocks ~1 s), then defers the blocking HTTP check to a
 * second timer so the window gets at least one paint cycle before freezing.
 * For the silent auto-boot path (show_ui=false) the UI is skipped and the
 * HTTP check runs immediately (no window to paint anyway).
 */
LLM_Deps_AsyncCheck(default_model, on_ready, on_failed, show_ui) {
	global _LLM_Deps_Checking, _LLM_Deps_State

	; No more WebView2 + hidden-PowerShell UI. We hand the install off to
	; winget (or the Ollama download page in the browser); the user gets
	; the official installer's native UI, which is more familiar AND
	; doesn't contest CPU/disk with the AHK input pipeline. Run the
	; reachability check directly — there's nothing left to "paint" first.
	LLM_Deps_DoCheck(default_model, on_ready, on_failed, show_ui)
}

/**
 * Phase 2 of the async bootstrap: performs the blocking HTTP reachability
 * check and either fast-paths (already running) or launches the installer.
 */
LLM_Deps_DoCheck(default_model, on_ready, on_failed, show_ui) {
	global _LLM_Deps_Checking, _LLM_Deps_State

	LoggerInfo("LLM", "DoCheck — checking if Ollama is running…")
	if LLM_OllamaIsRunning() {
		LoggerInfo("LLM", "Ollama already running — fast path, state → ready.")
		_LLM_Deps_State    := "ready"
		_LLM_Deps_Checking := false
		if show_ui && OllamaWV_IsAlive()
			OllamaWV_Close()
		if IsSet(on_ready)
			on_ready()
		return
	}

	; When called from the auto-boot path (show_ui=false), do not open the
	; install window — the user has not asked for an installation.
	if !show_ui {
		LoggerInfo("LLM", "Ollama not running but show_ui=false — silent abort, state stays pending.")
		_LLM_Deps_Checking := false
		return
	}

	LoggerInfo("LLM", "Ollama not running — launching installer…")
	LLM_Deps_RunInstaller(default_model, on_ready, on_failed)
}




; =============================================
; =============================================
; ======= 4/ Installer Execution =======
; =============================================
; =============================================

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
 * pinging http://localhost:11434 . Once Ollama answers, the state
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
LLM_Deps_RunInstaller(model, on_ready, on_failed) {
	global _LLM_Deps_PollTimer, _LLM_Deps_Checking

	; Try winget first — runs the real Ollama installer with its native
	; UI, so the user gets familiar progress and UAC prompts.
	winget_available := _LLM_Deps_HasWinget()
	if winget_available {
		LoggerInfo("LLM", "Handing off to winget install Ollama.Ollama…")
		try {
			Run('winget install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements')
		} catch as err {
			LoggerError("LLM", "winget launch failed: " err.Message ".")
			winget_available := false
		}
	}

	if !winget_available {
		LoggerInfo("LLM", "Opening https://ollama.com/download in the default browser.")
		try {
			Run('https://ollama.com/download')
		} catch as err {
			LoggerError("LLM", "Could not open the download page: " err.Message ".")
			LLM_Deps_Fail("Impossible d'ouvrir la page de téléchargement Ollama.", on_failed)
			return
		}
		; Surface a tray tip so the user knows what to do — without it,
		; the browser opening out of nowhere can feel disconnected from
		; their click in the menu.
		try TrayTip("Ergopti — IA", t("llm.deps.browser_install_tip"), 0x1)
	}

	; Poll the daemon every 3 s. When it answers, fire on_ready.
	LoggerInfo("LLM", "Polling http://localhost:11434 every 3 s until Ollama responds…")
	_LLM_Deps_PollTimer := () => LLM_Deps_PollServerReady(on_ready, on_failed)
	SetTimer(_LLM_Deps_PollTimer, 3000)
}

/**
 * Returns true when winget is on PATH. We use it to decide between the
 * automated install path and the browser fallback.
 */
_LLM_Deps_HasWinget() {
	try {
		out := ""
		; Hide=true and timeout-protected; we only care about the exit code
		RunWait('cmd.exe /c where winget >nul 2>&1', , "Hide")
		return A_LastError == 0
	} catch {
		return false
	}
}

/**
 * Poll callback set up by LLM_Deps_RunInstaller. Fires every 3 s; checks
 * whether Ollama is reachable. As soon as it answers, the install is
 * considered done (regardless of HOW the user installed it — via winget,
 * a manual download, or anything else).
 */
LLM_Deps_PollServerReady(on_ready, on_failed) {
	global _LLM_Deps_State, _LLM_Deps_Checking, _LLM_Deps_PollTimer
	if !LLM_OllamaIsRunning()
		return    ; still not up — keep polling
	LoggerInfo("LLM", "Ollama is now reachable — install complete.")
	if IsSet(_LLM_Deps_PollTimer)
		SetTimer(_LLM_Deps_PollTimer, 0)
	_LLM_Deps_State    := "ready"
	_LLM_Deps_Checking := false
	try OllamaWV_Close()
	if IsSet(on_ready)
		on_ready()
}

/**
 * User-driven cancel handler — bridges the WebView Cancel button to a
 * full feature deactivation. Cancels the install (LLM_Deps_Cancel) AND
 * flips ``_LLM_Tray["enabled"]`` to false so the tray toggle reflects
 * the user's intent and LLM_Bridge_Stop releases its resources. Saves
 * the new state so the toggle stays OFF across reloads.
 */
LLM_Deps_OnUserCancel() {
	global _LLM_Tray
	LoggerInfo("LLM", "User clicked Cancel — aborting install and disabling feature.")
	LLM_Deps_Cancel()
	if IsSet(_LLM_Tray) and _LLM_Tray["enabled"] {
		_LLM_Tray["enabled"] := false
		try LLM_Bridge_Stop()
		try LLM_Tray_SaveConfig()
		try LLM_Tray_Build()
	}
}

/**
 * Cancels an in-flight Ollama install: kills the hidden PowerShell tree
 * and stops the poll timer. Safe to call when nothing is running — it
 * just resets the state flags.
 *
 * Called from LLM_Deps_OnUserCancel (Cancel button) and from
 * LLM_Tray_OnToggle when the user disables the feature mid-install.
 * Without this, the install kept running in the background even after
 * the user closed every visible cue.
 */
LLM_Deps_Cancel() {
	global _LLM_Deps_InstallerPid, _LLM_Deps_PollTimer, _LLM_Deps_Checking, _LLM_Deps_State

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
	_LLM_Deps_Checking := false
	; State stays "pending" — the user explicitly aborted, but the next
	; toggle ON should be able to retry the install cleanly.
	_LLM_Deps_State := "pending"
}

/**
 * Polling callback: reads new content from the PS1 output file and
 * detects process completion by checking whether the PID is still alive.
 * @param {integer} pid - PID returned by shell.Run.
 * @param {Func} on_ready - Callback on success.
 * @param {Func} on_failed - Callback on failure.
 */
LLM_Deps_PollFile(pid, on_ready, on_failed) {
	global _LLM_Deps_OutFile, _LLM_Deps_OutPos, _LLM_Deps_Checking, _LLM_Deps_PollTimer

	; Read any new bytes from the output file
	LLM_Deps_DrainOutputFile()

	; Check if the process is still running by testing its existence
	still_running := ProcessExist(pid) ? true : false
	if still_running
		return   ; still running — timer will fire again

	; Process finished — do one final drain then evaluate the exit state
	LoggerInfo("LLM", "PS1 process (PID=" pid ") no longer running.")

	; Stop the poll timer
	if IsSet(_LLM_Deps_PollTimer)
		SetTimer(_LLM_Deps_PollTimer, 0)

	; Final drain
	LLM_Deps_DrainOutputFile()

	; Clean up temp file
	try FileDelete(_LLM_Deps_OutFile)

	_LLM_Deps_Checking := false
	; Clear the global installer PID — the process is gone, so a later
	; LLM_Deps_Cancel() must not try to taskkill a recycled PID.
	global _LLM_Deps_InstallerPid := 0

	; We cannot read the exit code from shell.Run. Instead we verify
	; Ollama reachability directly — if the server answers, install succeeded.
	LoggerInfo("LLM", "Verifying Ollama reachability after PS1 exit…")
	if LLM_OllamaIsRunning() {
		LoggerInfo("LLM", "Ollama confirmed running — state → ready.")
		OllamaWV_Done(true, t("llm.deps.done_success"))
		global _LLM_Deps_State := "ready"
		if IsSet(on_ready)
			on_ready()
	} else {
		LoggerError("LLM", "PS1 exited but Ollama is not reachable.")
		LLM_Deps_Fail(t("llm.deps.fail_server_not_responding"), on_failed)
	}
}

/**
 * Reads all new content from the PS1 output file since the last read
 * position, splits it into lines, and routes each line to HandleLine.
 */
LLM_Deps_DrainOutputFile() {
	global _LLM_Deps_OutFile, _LLM_Deps_OutPos

	if !FileExist(_LLM_Deps_OutFile)
		return

	try {
		f := FileOpen(_LLM_Deps_OutFile, "r", "UTF-8")
		if !f
			return
		f.Seek(_LLM_Deps_OutPos, 0)
		new_content := f.Read()
		_LLM_Deps_OutPos := f.Pos
		f.Close()
	} catch {
		return
	}

	if (new_content == "")
		return

	; Split on newlines and process each line
	loop parse, new_content, "`n", "`r" {
		line := A_LoopField
		if (line != "")
			LLM_Deps_HandleLine(line)
	}
}

/**
 * Routes a single output line to the appropriate WebView update.
 * @param {string} line - Raw line from the installer stdout file.
 */
LLM_Deps_HandleLine(line) {
	line := Trim(line)
	if (line == "")
		return

	; Marker lines drive the step label (same protocol as the PS1 script)
	if (line == "OLLAMA_INSTALLING") {
		LoggerInfo("LLM", "Marker: OLLAMA_INSTALLING.")
		OllamaWV_SetStep(t("ollama.deps_step_installing"))
		return
	}
	if (line == "OLLAMA_STARTING") {
		LoggerInfo("LLM", "Marker: OLLAMA_STARTING.")
		OllamaWV_SetStep(t("ollama.deps_step_starting"))
		return
	}
	if (line == "OLLAMA_READY") {
		LoggerInfo("LLM", "Marker: OLLAMA_READY.")
		OllamaWV_SetStep(t("ollama.deps_step_ready"))
		return
	}

	; Progress lines from "ollama pull" — try to parse and push stats
	if LLM_Deps_TryParseProgress(line)
		return

	; All other lines go to the terminal log area
	OllamaWV_SetDetail(line)
	OllamaWV_AddLog(line)
}

/**
 * Attempts to parse an ollama pull progress line and push stats to the WebView.
 * Returns true when the line was a recognised progress line.
 * @param {string} line - Raw output line.
 * @returns {boolean}
 */
LLM_Deps_TryParseProgress(line) {
	; Ollama pull lines look like:
	;   pulling abc123... 47% ▕████  ▏ 1.1 GB/2.3 GB 12 MB/s 1m34s
	; Require at least a percentage match to identify a progress line.
	if !RegExMatch(line, "(\d+)%", &m)
		return false

	pct := Integer(m[1])

	; Extract downloaded/total (e.g. "1.1 GB/2.3 GB")
	dl_str := ""
	if RegExMatch(line, "(\d+\.?\d*\s*[KMGkmg]?B)\s*/\s*(\d+\.?\d*\s*[KMGkmg]?B)", &ms)
		dl_str := ms[1] " / " ms[2]

	; Extract speed (e.g. "12 MB/s")
	speed_str := ""
	if RegExMatch(line, "(\d+\.?\d*\s*[KMGkmg]?B/s)", &mv)
		speed_str := mv[1]

	; Extract ETA (e.g. "1m34s", "45s", "2h5m")
	eta_str := ""
	if RegExMatch(line, "\s(\d+[hms]\d*[ms]?\d*[s]?)\s*$", &me)
		eta_str := me[1]

	; Ignore a bare "0%" with no size — not a real progress line
	if (pct == 0 && dl_str == "" && speed_str == "")
		return false

	OllamaWV_Update(pct, dl_str, speed_str, eta_str)
	return true
}

/**
 * Records a permanent failure, updates state, shows error in WebView, fires callback.
 * @param {string} msg - Human-readable failure reason.
 * @param {Func} on_failed - Optional callback.
 */
LLM_Deps_Fail(msg, on_failed) {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking
	LoggerError("LLM", "Deps failure: " msg)
	_LLM_Deps_State          := "failed"
	_LLM_Deps_FailureMessage := msg
	_LLM_Deps_Checking       := false
	OllamaWV_SetError("❌ " msg)
	OllamaWV_Done(false, "❌ " msg)
	if IsSet(on_failed)
		on_failed(msg)
}
