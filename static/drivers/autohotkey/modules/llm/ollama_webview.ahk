; modules/llm/ollama_webview.ahk

; ==============================================================================
; MODULE: Ollama WebView2 Install/Download Window
; DESCRIPTION:
; Hosts the shared download_window HTML UI inside a WebView2 control for
; the Windows driver. Provides the same visual experience as the Hammerspoon
; counterpart — bootstrap mode during Ollama engine install, download mode
; during model pull — by evaluating the same JS API (setKind, setStep,
; setDetail, addLog, update, done) from AHK.
;
; FEATURES & RATIONALE:
; 1. Shared HTML/CSS/JS: loads _shared/ui/download_window/index.html so both
;    platforms converge on a single UI source of truth.
; 2. WebView2-based: uses the vendored WebView2.ahk wrapper; gracefully
;    aborts if WebView2 Runtime is absent (should never happen on Win 10+).
; 3. Message bridge: JS buttons (cancel, retry) post messages received by
;    OllamaWV_OnWebMessage and forwarded to registered callbacks.
; 4. Deferred navigation: EvalJS calls are queued until the page signals
;    readiness via chrome.webview.postMessage("ready"), preventing lost
;    updates during the WebView2 bootstrap race.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 1/ Module State =======
; ==========================================
; ==========================================

; Window dimensions — matches the Hammerspoon download_window proportions
global _OllamaWV_W      := 460
global _OllamaWV_H      := 380
global _OllamaWV_Margin := 16   ; gap from screen edge (bottom-right)

; Internal state
global _OllamaWV_Gui        := unset
global _OllamaWV_Controller := unset
global _OllamaWV_WebView    := unset
global _OllamaWV_Ready      := false   ; true once JS signals "ready"
global _OllamaWV_Queue      := []      ; JS calls buffered before page ready
global _OllamaWV_OnCancel   := unset
global _OllamaWV_OnRetry    := unset




; ====================================
; ====================================
; ======= 2/ Public API =======
; ====================================
; ====================================

/**
 * Opens (or focuses) the download window in bootstrap mode.
 * @param {string} kind      - "ollama_install" or "ollama_model".
 * @param {string} subtitle  - Subtitle shown in bootstrap mode (unused in download mode).
 * @param {Func}   on_cancel - Optional callback fired when the user clicks Cancel.
 * @param {Func}   on_retry  - Optional callback fired when the user clicks Retry.
 */
OllamaWV_Show(kind := "ollama_install", subtitle := "", on_cancel := unset, on_retry := unset) {
	global _OllamaWV_OnCancel, _OllamaWV_OnRetry

	if IsSet(on_cancel)
		_OllamaWV_OnCancel := on_cancel
	if IsSet(on_retry)
		_OllamaWV_OnRetry := on_retry

	if OllamaWV_IsAlive() {
		OllamaWV_EvalJS("setKind(" OllamaWV_JSStr(kind) "," OllamaWV_JSStr("") "," OllamaWV_JSStr(subtitle) ")")
		return
	}

	OllamaWV_Create(kind, subtitle)
}

/**
 * Updates the bootstrap step label.
 * @param {string} text - French step label.
 */
OllamaWV_SetStep(text) {
	OllamaWV_EvalJS("setStep(" OllamaWV_JSStr(text) ")")
}

/**
 * Updates the bootstrap detail line (raw subprocess output).
 * @param {string} text - Raw output line; ANSI stripping handled by JS.
 */
OllamaWV_SetDetail(text) {
	OllamaWV_EvalJS("setDetail(" OllamaWV_JSStr(text) ")")
}

/**
 * Appends a line to the terminal log area.
 * @param {string} line - Log line (ANSI codes stripped by JS).
 */
OllamaWV_AddLog(line) {
	OllamaWV_EvalJS("addLog(" OllamaWV_JSStr(line) ")")
}

/**
 * Switches to download mode and updates progress stats.
 * @param {integer} pct           - Completion percentage 0–99.
 * @param {string}  downloaded    - Formatted size string e.g. "847 Mo / 2.3 Go".
 * @param {string}  speed         - Speed string e.g. "2.5 MB/s".
 * @param {string}  eta           - ETA string e.g. "2m 15s".
 */
OllamaWV_Update(pct, downloaded := "", speed := "", eta := "") {
	OllamaWV_EvalJS("update(" pct "," OllamaWV_JSStr(downloaded) ","
		OllamaWV_JSStr(speed) "," OllamaWV_JSStr(eta) ",null)")
}

/**
 * Sets the model name shown in download mode.
 * @param {string} name - Model tag e.g. "qwen2.5:3b".
 */
OllamaWV_SetModel(name) {
	OllamaWV_EvalJS("setModel(" OllamaWV_JSStr(name) ")")
}

/**
 * Switches to error state (bootstrap or download).
 * @param {string} msg - Short French error message.
 */
OllamaWV_SetError(msg) {
	OllamaWV_EvalJS("setError(" OllamaWV_JSStr(msg) ")")
}

/**
 * Transitions the window to its final state and schedules auto-close.
 * @param {boolean} is_success - True for success, false for error.
 * @param {string}  msg        - Final message shown to the user.
 */
OllamaWV_Done(is_success, msg := "") {
	js_bool := is_success ? "true" : "false"
	OllamaWV_EvalJS("done(" js_bool "," OllamaWV_JSStr(msg) ")")
	if is_success
		SetTimer(() => OllamaWV_Close(), -1800)
}

/**
 * Hides and destroys the window.
 */
OllamaWV_Close() {
	global _OllamaWV_Gui, _OllamaWV_Controller, _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue
	_OllamaWV_Ready := false
	_OllamaWV_Queue := []
	if IsSet(_OllamaWV_Controller)
		try _OllamaWV_Controller.Close()
	if IsSet(_OllamaWV_Gui)
		try _OllamaWV_Gui.Destroy()
	_OllamaWV_Gui        := unset
	_OllamaWV_Controller := unset
	_OllamaWV_WebView    := unset
}

/**
 * Returns true when the window exists and is visible.
 * @returns {boolean}
 */
OllamaWV_IsAlive() {
	global _OllamaWV_Gui
	if !IsSet(_OllamaWV_Gui)
		return false
	try return WinExist("ahk_id " _OllamaWV_Gui.Hwnd) ? true : false
	return false
}




; ============================================
; ============================================
; ======= 3/ WebView2 Lifecycle =======
; ============================================
; ============================================

/**
 * Creates the Gui + WebView2 control and navigates to the shared HTML.
 * @param {string} kind     - Initial kind preset ("ollama_install" | "ollama_model").
 * @param {string} subtitle - Subtitle for bootstrap mode.
 */
OllamaWV_Create(kind, subtitle) {
	global _OllamaWV_Gui, _OllamaWV_Controller, _OllamaWV_WebView
	global _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_W, _OllamaWV_H, _OllamaWV_Margin

	_OllamaWV_Ready := false
	_OllamaWV_Queue := []

	if !OllamaWV_WebView2Available() {
		LoggerError("LLM", "WebView2 not available — cannot show install window.")
		return
	}

	g := Gui("+AlwaysOnTop -Caption +ToolWindow", "Ergopti — IA")
	g.MarginX := 0
	g.MarginY := 0
	g.OnEvent("Close", (*) => OllamaWV_Close())

	; Position bottom-right of the primary monitor (same as the old AHK Gui)
	MonitorGetWorkArea(, , &mx2, , &my2)
	pos_x := mx2 - _OllamaWV_W - _OllamaWV_Margin
	pos_y := my2 - _OllamaWV_H - _OllamaWV_Margin

	g.Show("w" _OllamaWV_W " h" _OllamaWV_H " NoActivate x" pos_x " y" pos_y)
	_OllamaWV_Gui := g

	; Spin up WebView2
	loader := A_ScriptDir . "\vendor\64bit\WebView2Loader.dll"
	udir   := A_Temp . "\ergopti_ollama_wv_" . A_TickCount
	try DirCreate(udir)

	try {
		_OllamaWV_Controller := WebView2.create(g.Hwnd, , 0, udir, "", 0, loader)
	} catch as err {
		LoggerError("LLM", "WebView2 controller creation failed: " err.Message ".")
		try g.Destroy()
		_OllamaWV_Gui := unset
		return
	}

	_OllamaWV_WebView := _OllamaWV_Controller.CoreWebView2

	; Suppress Edge chrome surfaces
	try {
		s := _OllamaWV_WebView.Settings
		s.AreDevToolsEnabled              := true
		s.AreDefaultContextMenusEnabled   := true
		s.IsStatusBarEnabled              := false
		s.AreBrowserAcceleratorKeysEnabled := false
	}

	; JS → AHK message bridge (cancel / retry buttons)
	_OllamaWV_WebView.WebMessageReceived := OllamaWV_OnWebMessage

	; Navigate to shared HTML
	html_url := OllamaWV_HtmlUrl()
	LoggerInfo("LLM", "WebView navigating to: " html_url ".")
	try _OllamaWV_WebView.Navigate(html_url)

	; Fit the WebView to fill the Gui
	try _OllamaWV_Controller.Fill()

	; The "ready" message from JS triggers OllamaWV_OnWebMessage which
	; flushes the queue. As a safety net, also flush after 2 s in case
	; the message bridge misfires.
	SetTimer(OllamaWV_FlushQueue, -2000)

	; Queue the initial setKind so it fires once the page is ready
	OllamaWV_EvalJS("setKind(" OllamaWV_JSStr(kind) "," OllamaWV_JSStr("") "," OllamaWV_JSStr(subtitle) ")")
}

/**
 * Returns true when the WebView2 loader DLL and class are present.
 * @returns {boolean}
 */
OllamaWV_WebView2Available() {
	loader := A_ScriptDir . "\vendor\64bit\WebView2Loader.dll"
	if !FileExist(loader)
		return false
	if !IsSet(WebView2)
		return false
	return true
}

/**
 * Returns the file:// URL for the shared download_window HTML.
 * @returns {string}
 */
OllamaWV_HtmlUrl() {
	base := A_ScriptDir . "\..\_shared\ui\download_window\index.html"
	loop files, base
		base := A_LoopFileFullPath
	return "file:///" . StrReplace(base, "\", "/")
}




; =============================================
; =============================================
; ======= 4/ JS Bridge =======
; =============================================
; =============================================

/**
 * Evaluates a JS expression in the WebView. Queues the call until the
 * page signals readiness to prevent lost updates during the bootstrap race.
 * @param {string} js - JavaScript expression to evaluate.
 */
OllamaWV_EvalJS(js) {
	global _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue
	if !IsSet(_OllamaWV_WebView) {
		_OllamaWV_Queue.Push(js)
		return
	}
	if !_OllamaWV_Ready {
		_OllamaWV_Queue.Push(js)
		return
	}
	try _OllamaWV_WebView.ExecuteScript(js, 0)
}

/**
 * Drains the queued JS calls in FIFO order.
 * Called when the page posts "ready" or after the 2-second safety timeout.
 */
OllamaWV_FlushQueue() {
	global _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue
	if !IsSet(_OllamaWV_WebView)
		return
	_OllamaWV_Ready := true
	for js in _OllamaWV_Queue
		try _OllamaWV_WebView.ExecuteScript(js, 0)
	_OllamaWV_Queue := []
}

/**
 * Receives messages posted by the page via chrome.webview.postMessage.
 * Handles "ready", "cancel", "retry", "expand".
 */
OllamaWV_OnWebMessage(sender, args) {
	global _OllamaWV_OnCancel, _OllamaWV_OnRetry
	msg := ""
	try msg := args.TryGetWebMessageAsString()
	LoggerInfo("LLM", "WebView message: '" msg "'.")
	switch msg {
		case "ready":
			OllamaWV_FlushQueue()
		case "cancel":
			OllamaWV_Close()
			if IsSet(_OllamaWV_OnCancel)
				_OllamaWV_OnCancel()
		case "retry":
			if IsSet(_OllamaWV_OnRetry)
				_OllamaWV_OnRetry()
		case "terminal":
			Run("cmd.exe")
	}
}




; ==========================================
; ==========================================
; ======= 5/ Helpers =======
; ==========================================
; ==========================================

/**
 * Escapes a string for safe embedding in a JS string literal.
 * Returns the value wrapped in single quotes.
 * @param {string} s - Raw string value.
 * @returns {string} JS single-quoted string literal.
 */
OllamaWV_JSStr(s) {
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, "'", "\'")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "")
	return "'" s "'"
}
