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
 * @param {Func} on_ready - Optional callback fired when the server is confirmed ready.
 * @param {Func} on_failed - Optional callback fired on permanent failure.
 */
LLM_Deps_CheckAndInstall(default_model := "qwen2.5:3b", on_ready := unset, on_failed := unset) {
	global _LLM_Deps_Checking, _LLM_Deps_State

	LoggerInfo("LLM", "CheckAndInstall — state: " _LLM_Deps_State ", checking: " (_LLM_Deps_Checking ? "true" : "false") ".")

	; Guard: only one concurrent bootstrap
	if _LLM_Deps_Checking {
		LoggerInfo("LLM", "CheckAndInstall — already in progress, skipping.")
		return
	}
	_LLM_Deps_Checking := true

	; Reset failure state so a re-try after a failed install can proceed
	if (_LLM_Deps_State == "failed")
		_LLM_Deps_State := "pending"

	; Defer the blocking HTTP check to a timer so the main thread stays free.
	; The lambda captures the parameters for the slow path.
	LoggerInfo("LLM", "Scheduling async Ollama reachability check…")
	SetTimer(() => LLM_Deps_AsyncCheck(default_model, on_ready, on_failed), -1)
}

/**
 * Runs inside a one-shot timer: checks Ollama reachability then either
 * fast-paths or launches the installer. Called on a timer so the main
 * AHK thread is not blocked by the synchronous WinHTTP call.
 */
LLM_Deps_AsyncCheck(default_model, on_ready, on_failed) {
	global _LLM_Deps_Checking, _LLM_Deps_State

	LoggerInfo("LLM", "AsyncCheck — checking if Ollama is running…")
	if LLM_OllamaIsRunning() {
		LoggerInfo("LLM", "Ollama already running — fast path, state → ready.")
		_LLM_Deps_State    := "ready"
		_LLM_Deps_Checking := false
		if IsSet(on_ready)
			on_ready()
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
 * Locates the shared PS1 installer and launches it completely hidden by
 * redirecting its stdout to a temp file. A poll timer tails the file
 * every 500 ms to feed lines to the WebView UI.
 * @param {string} model - Model tag to pass to the installer.
 * @param {Func} on_ready - Callback on success.
 * @param {Func} on_failed - Callback on failure.
 */
LLM_Deps_RunInstaller(model, on_ready, on_failed) {
	global _LLM_Deps_OutFile, _LLM_Deps_OutPos, _LLM_Deps_PollTimer

	ps1_path := LLM_GetSharedPath("install\ollama_install.ps1")
	LoggerInfo("LLM", "PS1 path resolved: '" ps1_path "'.")
	if (ps1_path == "") {
		LoggerError("LLM", "ollama_install.ps1 not found — aborting.")
		LLM_Deps_Fail("Installeur ollama_install.ps1 introuvable.", on_failed)
		return
	}

	; Show WebView progress window before launching
	OllamaWV_Show("ollama_install", t("ollama.install_title"),
		, (*) => LLM_Deps_RunInstaller(model, on_ready, on_failed))

	; Temp file that receives PS1 stdout (avoids a visible console window)
	_LLM_Deps_OutFile := A_Temp . "\ergopti_ollama_out_" . A_TickCount . ".txt"
	_LLM_Deps_OutPos  := 0

	; Build command: redirect both stdout and stderr to the temp file.
	; AHK Run with "Hide" suppresses the console window and returns a reliable PID.
	cmd := 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass'
		. ' -File "' ps1_path '" -Model "' model '"'
		. ' > "' _LLM_Deps_OutFile '" 2>&1'
	LoggerInfo("LLM", "Launching (hidden): " cmd ".")

	pid := 0
	try {
		Run(cmd, , "Hide", &pid)
		LoggerInfo("LLM", "PS1 process launched, PID=" pid ".")
	} catch as err {
		LoggerError("LLM", "Failed to launch PowerShell: " err.Message ".")
		LLM_Deps_Fail("Impossible de lancer PowerShell : " err.Message, on_failed)
		return
	}
	if (pid == 0) {
		LoggerError("LLM", "Run() returned PID=0 — cannot track process.")
		LLM_Deps_Fail("Impossible de démarrer l'installeur (PID=0).", on_failed)
		return
	}

	; Poll every 500 ms: read new lines from the temp file, detect completion
	; by checking whether the powershell.exe process is still alive.
	_LLM_Deps_PollTimer := () => LLM_Deps_PollFile(pid, on_ready, on_failed)
	SetTimer(_LLM_Deps_PollTimer, 500)
	LoggerInfo("LLM", "Poll timer started (file: " _LLM_Deps_OutFile ").")
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

	; We cannot read the exit code from shell.Run. Instead we verify
	; Ollama reachability directly — if the server answers, install succeeded.
	LoggerInfo("LLM", "Verifying Ollama reachability after PS1 exit…")
	if LLM_OllamaIsRunning() {
		LoggerInfo("LLM", "Ollama confirmed running — state → ready.")
		OllamaWV_Done(true, "✅ Ollama prêt")
		global _LLM_Deps_State := "ready"
		if IsSet(on_ready)
			on_ready()
	} else {
		LoggerError("LLM", "PS1 exited but Ollama is not reachable.")
		LLM_Deps_Fail("Installeur terminé mais le serveur Ollama ne répond pas.", on_failed)
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
		f := FileOpen(_LLM_Deps_OutFile, "r", "UTF-8-RAW")
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
		OllamaWV_SetStep("⬇️ Téléchargement d'Ollama…")
		return
	}
	if (line == "OLLAMA_STARTING") {
		LoggerInfo("LLM", "Marker: OLLAMA_STARTING.")
		OllamaWV_SetStep("🚀 Démarrage du serveur…")
		return
	}
	if (line == "OLLAMA_READY") {
		LoggerInfo("LLM", "Marker: OLLAMA_READY.")
		OllamaWV_SetStep("✅ Serveur prêt")
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
