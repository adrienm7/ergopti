; modules/llm/ollama_deps_checker.ahk

; ==============================================================================
; MODULE: Ollama Dependencies Checker
; DESCRIPTION:
; Windows equivalent of the Hammerspoon ollama_deps_checker.lua.
; Ensures the Ollama binary is installed and the local inference server is
; reachable on http://localhost:11434. The heavy lifting is done by the shared
; PowerShell installer (_shared/llm/install/ollama_install.ps1); this module
; handles async invocation, marker parsing, and a native AHK progress GUI.
;
; FEATURES & RATIONALE:
; 1. Self-bootstrapping: runs the shared PS1 installer silently, pulling the
;    configured default model automatically — zero manual setup for the user.
; 2. Silent fast path: when Ollama is already running, the check exits in
;    milliseconds with no UI shown.
; 3. Granular progress UI: a native AHK Gui mirrors the macOS download_window
;    style (step label, detail line, indeterminate progress bar).
; 4. Tri-state lifecycle: callers read LLM_Deps_GetState() — "pending" /
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
global _LLM_Deps_Gui            := unset        ; progress Gui object, shown only on slow path
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

	; Guard: only one concurrent bootstrap
	if _LLM_Deps_Checking
		return
	_LLM_Deps_Checking := true

	; Reset failure state so a re-try after a failed install can proceed
	if (_LLM_Deps_State == "failed")
		_LLM_Deps_State := "pending"

	; Fast path: server already running
	if LLM_OllamaIsRunning() {
		_LLM_Deps_State    := "ready"
		_LLM_Deps_Checking := false
		if IsSet(on_ready)
			on_ready()
		return
	}

	; Slow path: run the PowerShell installer in a background thread
	LLM_Deps_RunInstaller(default_model, on_ready, on_failed)
}




; =============================================
; =============================================
; ======= 4/ Installer Execution =======
; =============================================
; =============================================

/**
 * Locates the shared PS1 installer and runs it in a hidden PowerShell process.
 * Streams stdout line-by-line to update the progress GUI.
 * @param {string} model - Model tag to pass to the installer.
 * @param {Func} on_ready - Callback on success.
 * @param {Func} on_failed - Callback on failure.
 */
LLM_Deps_RunInstaller(model, on_ready, on_failed) {
	ps1_path := LLM_GetSharedPath("install\ollama_install.ps1")
	if (ps1_path == "") {
		LLM_Deps_Fail("Installeur ollama_install.ps1 introuvable dans _shared/llm/install/.", on_failed)
		return
	}

	; Show progress GUI before launching so the user sees feedback immediately
	LLM_Deps_GuiShow(t("ollama.deps_step_installing"))

	; Build PowerShell command: run script hidden, capture output line-by-line
	cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps1_path '" -Model "' model '"'

	; Run asynchronously via a ComObject shell exec + polling timer
	try {
		shell := ComObject("WScript.Shell")
		proc  := shell.Exec(cmd)
	} catch as err {
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
}

/**
 * Polling callback: reads pending output from the process, updates GUI,
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
		if LLM_OllamaIsRunning() {
			LLM_Deps_GuiStep(t("ollama.deps_step_ready"))
			LLM_Deps_GuiComplete()
			global _LLM_Deps_State := "ready"
			if IsSet(on_ready)
				on_ready()
		} else {
			LLM_Deps_Fail("Installeur terminé mais le serveur Ollama ne répond pas.", on_failed)
		}
	} else {
		LLM_Deps_Fail("L'installeur a échoué (code " exit_code ").", on_failed)
	}
}

/**
 * Routes a single output line to the appropriate GUI update.
 * @param {string} line - Raw line from the installer stdout.
 */
LLM_Deps_HandleLine(line) {
	line := Trim(line)
	if (line == "")
		return

	; Marker lines drive the step label (same protocol as the bash script)
	if (line == "OLLAMA_INSTALLING") {
		LLM_Deps_GuiStep(t("ollama.deps_step_installing"))
		return
	}
	if (line == "OLLAMA_STARTING") {
		LLM_Deps_GuiStep(t("ollama.deps_step_starting"))
		return
	}
	if (line == "OLLAMA_READY") {
		LLM_Deps_GuiStep(t("ollama.deps_step_ready"))
		return
	}

	; All other lines go to the detail line (subprocess progress)
	LLM_Deps_GuiDetail(line)
}

/**
 * Records a permanent failure, updates state, shows error in GUI, fires callback.
 * @param {string} msg - Human-readable failure reason.
 * @param {Func} on_failed - Optional callback.
 */
LLM_Deps_Fail(msg, on_failed) {
	global _LLM_Deps_State, _LLM_Deps_FailureMessage, _LLM_Deps_Checking
	_LLM_Deps_State          := "failed"
	_LLM_Deps_FailureMessage := msg
	_LLM_Deps_Checking       := false
	LLM_Deps_GuiError(msg)
	if IsSet(on_failed)
		on_failed(msg)
}




; ==========================================
; ==========================================
; ======= 5/ Progress GUI =======
; ==========================================
; ==========================================

; Indeterminate bar animation state
global _LLM_Deps_BarPos := 0

/**
 * Creates and shows the bootstrap progress GUI (dark theme, bottom-right).
 * Only called on the slow path — server not running at check time.
 * @param {string} step_text - Initial step label to display.
 */
LLM_Deps_GuiShow(step_text := "") {
	global _LLM_Deps_Gui

	if IsSet(_LLM_Deps_Gui) {
		try _LLM_Deps_Gui.Show()
		return
	}

	g := Gui("+AlwaysOnTop -Caption +ToolWindow", t("menu.llm.title"))
	g.BackColor := "242426"
	g.SetFont("s12 cFFFFFF w600", "Segoe UI")
	g.Add("Text", "x18 y18 w424", t("ollama.install_title"))

	g.SetFont("s11 c73d98c w400", "Segoe UI")
	g.Add("Text", "x18 y44 w424", "✦ Ollama")

	g.SetFont("s10 cAAAAAA w400", "Segoe UI")
	step_ctrl := g.Add("Text", "x18 y72 w424 vStepLine", step_text)

	g.SetFont("s9 c888888 w400", "SF Mono, Consolas, monospace")
	detail_ctrl := g.Add("Text", "x18 y94 w424 vDetailLine", "")

	; Indeterminate progress bar (green accent for Ollama)
	; AHK v2 Progress bar: color via c<hex>, background via Background<hex>
	g.Add("Progress", "x18 y120 w424 h4 vProgressBar c73d98c Background242426 Range0-100")

	g.SetFont("s9 cAAAAAA w400", "Segoe UI")
	g.Add("Button", "x18 y138 w80 vBtnCancel", t("download_window.btn_cancel")).OnEvent("Click",
		(*) => LLM_Deps_GuiCancel())

	_LLM_Deps_Gui := g

	; Position bottom-right of the primary monitor
	MonitorGetWorkArea(, , &mx2, , &my2)
	g.Show("w460 h180 NoActivate x" (mx2 - 476) " y" (my2 - 196))

	; Animate indeterminate bar every 80 ms
	SetTimer(LLM_Deps_GuiAnimate, 80)
}

/**
 * Updates the step label in the progress GUI.
 * @param {string} text - New step label.
 */
LLM_Deps_GuiStep(text) {
	global _LLM_Deps_Gui
	if !IsSet(_LLM_Deps_Gui)
		return
	try _LLM_Deps_Gui["StepLine"].Value := text
}

/**
 * Updates the detail line (subprocess output) in the progress GUI.
 * @param {string} text - Raw output line (ANSI codes stripped).
 */
LLM_Deps_GuiDetail(text) {
	global _LLM_Deps_Gui
	if !IsSet(_LLM_Deps_Gui)
		return
	; Strip ANSI escape sequences
	clean := RegExReplace(text, "\x1b\[[0-9;]*[A-Za-z]", "")
	; Truncate to prevent overflow
	if (StrLen(clean) > 70)
		clean := "…" SubStr(clean, -67)
	try _LLM_Deps_Gui["DetailLine"].Value := clean
}

/**
 * Switches the GUI to success state and auto-hides after 1.5 s.
 */
LLM_Deps_GuiComplete() {
	global _LLM_Deps_Gui
	SetTimer(LLM_Deps_GuiAnimate, 0)   ; stop animation
	if !IsSet(_LLM_Deps_Gui)
		return
	try _LLM_Deps_Gui["ProgressBar"].Value := 100
	try _LLM_Deps_Gui["BtnCancel"].Enabled := false
	SetTimer(() => LLM_Deps_GuiHide(), -1500)
}

/**
 * Switches the GUI to error state (red step, retry hint).
 * @param {string} msg - Error message to display.
 */
LLM_Deps_GuiError(msg) {
	global _LLM_Deps_Gui
	SetTimer(LLM_Deps_GuiAnimate, 0)
	if !IsSet(_LLM_Deps_Gui) {
		MsgBox(msg, t("menu.llm.title") " — Erreur", "Icon!")
		return
	}
	try {
		_LLM_Deps_Gui["StepLine"].Value  := "❌ " msg
		_LLM_Deps_Gui["DetailLine"].Value := "Vérifiez votre connexion et relancez Ergopti."
		_LLM_Deps_Gui["BtnCancel"].Value := t("common.close")
	}
}

/**
 * Hides and destroys the progress GUI.
 */
LLM_Deps_GuiHide() {
	global _LLM_Deps_Gui
	SetTimer(LLM_Deps_GuiAnimate, 0)
	if IsSet(_LLM_Deps_Gui) {
		try _LLM_Deps_Gui.Destroy()
		_LLM_Deps_Gui := unset
	}
}

LLM_Deps_GuiCancel() {
	LLM_Deps_GuiHide()
}

/**
 * Advances the indeterminate progress bar animation frame.
 */
LLM_Deps_GuiAnimate() {
	global _LLM_Deps_Gui, _LLM_Deps_BarPos
	if !IsSet(_LLM_Deps_Gui)
		return
	_LLM_Deps_BarPos := Mod(_LLM_Deps_BarPos + 4, 100)
	try _LLM_Deps_Gui["ProgressBar"].Value := _LLM_Deps_BarPos
}
