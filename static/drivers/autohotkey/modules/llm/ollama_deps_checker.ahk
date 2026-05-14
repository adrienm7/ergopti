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
; 5. Tri-state lifecycle: callers read LLM_Deps_GetState() — "pending" /
;    "ready" / "failed" — identical to the Lua pattern.
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
 * @param {string} default_model - Ollama tag to pull if not yet available (e.g. "qwen2.5:3b").
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

	; Fast path: server already running
	LoggerInfo("LLM", "Checking if Ollama is running…")
	if LLM_OllamaIsRunning() {
		LoggerInfo("LLM", "Ollama already running — fast path, state → ready.")
		_LLM_Deps_State    := "ready"
		_LLM_Deps_Checking := false
		if IsSet(on_ready)
			on_ready()
		return
	}

	; Slow path: run the PowerShell installer in a background thread
	LoggerInfo("LLM", "Ollama not running — launching installer…")
	LLM_Deps_RunInstaller(default_model, on_ready, on_failed)
}




; =============================================
; =============================================
; ======= 4/ Installer Execution =======
; =============================================
; =============================================

/**
 * Locates the shared PS1 installer and runs it in a hidden PowerShell process.
 * Streams stdout line-by-line to update the WebView UI.
 * @param {string} model - Model tag to pass to the installer.
 * @param {Func} on_ready - Callback on success.
 * @param {Func} on_failed - Callback on failure.
 */
LLM_Deps_RunInstaller(model, on_ready, on_failed) {
	ps1_path := LLM_GetSharedPath("install\ollama_install.ps1")
	LoggerInfo("LLM", "PS1 path resolved: '" ps1_path "'.")
	if (ps1_path == "") {
		LoggerError("LLM", "ollama_install.ps1 not found in _shared/llm/install/ — aborting.")
		LLM_Deps_Fail("Installeur ollama_install.ps1 introuvable dans _shared/llm/install/.", on_failed)
		return
	}

	; Show WebView progress window before launching so user sees feedback immediately
	OllamaWV_Show("ollama_install", "", , (*) => LLM_Deps_RunInstaller(model, on_ready, on_failed))

	; Build PowerShell command: run script hidden, capture output line-by-line
	cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps1_path '" -Model "' model '"'
	LoggerInfo("LLM", "Launching PS1: " cmd ".")

	; Run asynchronously via a ComObject shell exec + polling timer
	try {
		shell := ComObject("WScript.Shell")
		proc  := shell.Exec(cmd)
		LoggerInfo("LLM", "PS1 process launched (Status=" proc.Status ").")
	} catch as err {
		LoggerError("LLM", "Failed to launch PowerShell: " err.Message ".")
		LLM_Deps_Fail("Impossible de lancer PowerShell : " err.Message, on_failed)
		return
	}

	; Poll every 500 ms for new output lines and process completion.
	; Store the lambda reference so PollProcess can cancel it explicitly —
	; SetTimer(, 0) only works when the caller IS the timer function, not
	; when it is a helper called from a lambda wrapper.
	global _LLM_Deps_PollTimer
	_LLM_Deps_PollTimer := () => LLM_Deps_PollProcess(proc, on_ready, on_failed)
	SetTimer(_LLM_Deps_PollTimer, 500)
	LoggerInfo("LLM", "Poll timer started.")
}

/**
 * Polling callback: reads pending output from the process, updates WebView UI,
 * and detects completion.
 * @param {Object} proc - WScript.Shell Exec object.
 * @param {Func} on_ready - Callback on success.
 * @param {Func} on_failed - Callback on failure.
 */
LLM_Deps_PollProcess(proc, on_ready, on_failed) {
	global _LLM_Deps_Checking

	; Read all available stdout lines
	try {
		while !proc.StdOut.AtEndOfStream {
			line := proc.StdOut.ReadLine()
			LLM_Deps_HandleLine(line)
		}
	}

	; Check if process finished
	if (proc.Status == 0)   ; 0 = running, 1 = finished, 2 = error
		return   ; still running — timer will fire again

	LoggerInfo("LLM", "PS1 process finished — Status=" proc.Status " ExitCode=" proc.ExitCode ".")

	; Stop the polling timer using the stored lambda reference
	global _LLM_Deps_PollTimer
	if IsSet(_LLM_Deps_PollTimer)
		SetTimer(_LLM_Deps_PollTimer, 0)

	; Drain remaining output
	try {
		while !proc.StdOut.AtEndOfStream {
			line := proc.StdOut.ReadLine()
			LLM_Deps_HandleLine(line)
		}
	}

	_LLM_Deps_Checking := false
	exit_code := proc.ExitCode

	if (exit_code == 0) {
		; Verify server is now reachable
		LoggerInfo("LLM", "PS1 exited 0 — verifying Ollama reachability…")
		if LLM_OllamaIsRunning() {
			LoggerInfo("LLM", "Ollama confirmed running — state → ready.")
			OllamaWV_SetStep("✅ Ollama prêt")
			OllamaWV_Done(true, "✅ Ollama prêt")
			global _LLM_Deps_State := "ready"
			if IsSet(on_ready)
				on_ready()
		} else {
			LoggerError("LLM", "PS1 exited 0 but Ollama not reachable.")
			LLM_Deps_Fail("Installeur terminé mais le serveur Ollama ne répond pas.", on_failed)
		}
	} else {
		LoggerError("LLM", "PS1 exited with code " exit_code ".")
		LLM_Deps_Fail("L'installeur a échoué (code " exit_code ").", on_failed)
	}
}

/**
 * Routes a single output line to the appropriate WebView update.
 * Marker lines drive the step label; progress lines are parsed for stats;
 * all other lines go to the log area.
 * @param {string} line - Raw line from the installer stdout.
 */
LLM_Deps_HandleLine(line) {
	line := Trim(line)
	if (line == "")
		return

	; Marker lines drive the step label (same protocol as the bash/PS1 script)
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

	; Progress lines from "ollama pull" look like:
	;   pulling abc123... 100% ▕████████▏ 847 MB/2.3 GB 2.5 MB/s 9m30s
	; or the simpler PS1 echo: "Téléchargement du modèle qwen2.5:3b…"
	if LLM_Deps_TryParseProgress(line)
		return

	; All other lines go to the terminal log area and detail line
	OllamaWV_SetDetail(line)
	OllamaWV_AddLog(line)
}

/**
 * Attempts to parse an ollama pull progress line and push stats to the WebView.
 * Returns true when the line was a progress line and was consumed.
 * @param {string} line - Raw output line.
 * @returns {boolean}
 */
LLM_Deps_TryParseProgress(line) {
	; Match the typical ollama pull streaming output:
	;   "pulling <hash>... <pct>% ▕...▏ <downloaded>/<total> <speed> <eta>"
	; The bar characters (▕▏) may or may not be present.
	; Minimum pattern: something% ... <number><unit> <number><unit>

	; Extract percentage
	pct := 0
	if RegExMatch(line, "(\d+)%", &m)
		pct := Integer(m[1])
	else
		return false   ; not a progress line

	; Extract downloaded/total size (e.g. "847 MB/2.3 GB" or "847 MB / 2.3 GB")
	dl_str := ""
	if RegExMatch(line, "(\d+\.?\d*\s*[KMGkmg]?B)\s*/\s*(\d+\.?\d*\s*[KMGkmg]?B)", &ms)
		dl_str := ms[1] " / " ms[2]

	; Extract speed (e.g. "2.5 MB/s")
	speed_str := ""
	if RegExMatch(line, "(\d+\.?\d*\s*[KMGkmg]?B/s)", &mv)
		speed_str := mv[1]

	; Extract ETA (e.g. "9m30s" or "2h 5m" or "45s")
	eta_str := ""
	if RegExMatch(line, "(\d+[hms]\d*[ms]?\d*[s]?)$", &me)
		eta_str := me[1]

	; Switch to download mode on first progress line if we were in bootstrap mode
	if (pct == 0 && dl_str == "" && speed_str == "")
		return false   ; 0% with no size info — not a real progress line yet

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
