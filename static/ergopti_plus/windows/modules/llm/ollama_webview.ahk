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





; ===============================
; ===============================
; ======= 1/ Module State =======
; ===============================
; ===============================

; Window dimensions — matches the Hammerspoon download_window proportions
global _OllamaWV_W      := 460
global _OllamaWV_H      := 380
global _OllamaWV_Margin := 10   ; gap from screen edge and taskbar (physical pixels, -DPIScale)

; Internal state
global _OllamaWV_Gui        := unset
global _OllamaWV_Controller := unset
global _OllamaWV_WebView    := unset
; Subscription handle returned by WebView2.WebMessageReceived(). The thqby
; binding ties the event subscription to this object's LIFETIME: when it is
; garbage-collected its __Delete unsubscribes via remove_WebMessageReceived —
; silently killing the handler the instant it is discarded. It MUST be kept
; alive in a persistent global for the JS->AHK channel to keep delivering
; messages (see ui/onboarding/webview.ahk's _OnbWeb_MsgSub for the sibling
; fix this mirrors).
global _OllamaWV_MsgSub     := unset
global _OllamaWV_Ready      := false   ; true once JS signals "ready"
global _OllamaWV_Queue      := []      ; JS calls buffered before page ready
global _OllamaWV_OnCancel   := unset
global _OllamaWV_OnRetry    := unset
; Every deferred WebView callback is bound to the window instance that armed it.
; A close/reopen must never let an old auto-close, safety flush, or script timer
; mutate the replacement window.
global _OllamaWV_Epoch      := 0





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

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
	global _OllamaWV_Epoch
	js_bool := is_success ? "true" : "false"
	OllamaWV_EvalJS("done(" js_bool "," OllamaWV_JSStr(msg) ")")
	if is_success {
		captured_epoch := _OllamaWV_Epoch
		SetTimer(OllamaWV_CloseIfEpoch.Bind(captured_epoch), -1800)
	}
}

; A terminal state belongs only to the WebView instance that displayed it.  An
; anonymous OllamaWV_Close timer used to close a new window reopened within the
; previous window's 1.8 s grace period.
OllamaWV_CloseIfEpoch(captured_epoch, *) {
	global _OllamaWV_Epoch
	if (captured_epoch != _OllamaWV_Epoch)
		return
	OllamaWV_Close()
}

/**
 * Hides and destroys the window.
 */
OllamaWV_Close() {
	global _OllamaWV_Gui, _OllamaWV_Controller, _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_Udir, _OllamaWV_MsgSub, _OllamaWV_Epoch
	_OllamaWV_Epoch += 1
	_OllamaWV_Ready := false
	_OllamaWV_Queue := []
	; Release the subscription handle FIRST, while the controller is still
	; alive — its __Delete unsubscribes via remove_WebMessageReceived on the
	; live controller; doing it AFTER Controller.Close() would raise a COM
	; error against an already-invalidated pointer (see
	; ui/onboarding/webview.ahk's _OnbWeb_Reset for the sibling ordering fix).
	_OllamaWV_MsgSub := unset
	if IsSet(_OllamaWV_Controller)
		try _OllamaWV_Controller.Close()
	if IsSet(_OllamaWV_Gui)
		try _OllamaWV_Gui.Destroy()
	_OllamaWV_Gui        := unset
	_OllamaWV_Controller := unset
	_OllamaWV_WebView    := unset
	if IsSet(_OllamaWV_Udir) {
		UdirToDelete := _OllamaWV_Udir
		_OllamaWV_Udir := unset
		; Edge's child msedgewebview2.exe processes hold an exclusive file lock on
		; the user-data directory for a few hundred ms after Controller.Close().
		; Deleting synchronously here races that lock and fails silently, leaking
		; the temp folder. A 1 s delay lets the children exit before we sweep.
		SetTimer(_OllamaWV_DeferredDirDelete.Bind(UdirToDelete), -1000)
	}
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





; =====================================
; =====================================
; ======= 3/ WebView2 Lifecycle =======
; =====================================
; =====================================

/**
 * Creates the Gui + WebView2 control and navigates to the shared HTML.
 * @param {string} kind     - Initial kind preset ("ollama_install" | "ollama_model").
 * @param {string} subtitle - Subtitle for bootstrap mode.
 */
OllamaWV_Create(kind, subtitle) {
	global _OllamaWV_Gui, _OllamaWV_Controller, _OllamaWV_WebView, _OllamaWV_MsgSub
	global _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_W, _OllamaWV_H, _OllamaWV_Margin, _OllamaWV_Epoch

	_OllamaWV_Epoch += 1
	captured_epoch := _OllamaWV_Epoch
	_OllamaWV_Ready := false
	_OllamaWV_Queue := []

	if !OllamaWV_WebView2Available() {
		LoggerError("LLM", "WebView2 not available — cannot show install window.")
		return
	}

	; -DPIScale: tell AHK to treat all coordinates as logical pixels (no auto-scaling).
	; Without this, AHK v2 in PerMonitorV2 mode interprets Gui dimensions as physical
	; pixels, making the window larger than intended on scaled displays.
	g := Gui_Create("+AlwaysOnTop +Caption +MinimizeBox +Resize +ToolWindow -DPIScale", "IA")
	g.MarginX := 0
	g.MarginY := 0
	g.OnEvent("Close", OllamaWV_CloseIfEpoch.Bind(captured_epoch))

	; Position bottom-right, flush above the taskbar with a small margin.
	; SPI_GETWORKAREA (48) always returns physical pixels.
	; With -DPIScale, Gui.Show() position coords are physical pixels too, but
	; window dimensions (w/h) are logical pixels — AHK scales them up internally.
	; So the physical footprint of the window is w*scale × h*scale; we must
	; subtract that from wa_r/wa_b to keep the window fully on-screen.
	work_rc   := Buffer(16, 0)
	DllCall("SystemParametersInfo", "UInt", 48, "UInt", 0, "Ptr", work_rc, "UInt", 0)
	wa_r      := NumGet(work_rc,  8, "Int")
	wa_b      := NumGet(work_rc, 12, "Int")
	dpi_scale := A_ScreenDPI / 96
	win_w     := _OllamaWV_W
	win_h     := _OllamaWV_H
	phy_w     := Round(win_w * dpi_scale)
	phy_h     := Round(win_h * dpi_scale)
	pos_x     := wa_r - phy_w - _OllamaWV_Margin
	pos_y     := wa_b - phy_h - _OllamaWV_Margin
	LoggerInfo("LLM", "Window position: x=" pos_x " y=" pos_y " logical=" win_w "x" win_h " physical=" phy_w "x" phy_h " (wa_r=" wa_r " wa_b=" wa_b " dpi=" A_ScreenDPI ").")

	g.Show("w" win_w " h" win_h " x" pos_x " y" pos_y)
	_OllamaWV_Gui := g

	; Spin up WebView2
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	global _OllamaWV_Udir := A_Temp . "\ergopti_ollama_wv_" . A_TickCount
	WebView_SweepStaleProfiles("ergopti_ollama_wv_")
	try DirCreate(_OllamaWV_Udir)

	try {
		_OllamaWV_Controller := WebView2.create(g.Hwnd, , 0, _OllamaWV_Udir, "", 0, loader)
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

	; JS → AHK message bridge (cancel / retry buttons).
	; The wrapper's __Call intercepts obj.Method(fn) and routes it to
	; add_WebMessageReceived — the := assignment form does NOT work.
	; The returned subscription handle MUST be stored in a persistent global:
	; discarding it lets AHK garbage-collect it immediately, whose __Delete
	; unsubscribes via remove_WebMessageReceived — silently killing the
	; JS->AHK channel the instant it is created (see ui/onboarding/webview.ahk's
	; _OnbWeb_MsgSub for the sibling fix this mirrors).
	_OllamaWV_MsgSub := _OllamaWV_WebView.WebMessageReceived(OllamaWV_OnWebMessage)

	; Inject i18n base URL and locale code before page scripts run.
	; The JSON strings are pushed later via ExecuteScript in FlushQueue to avoid
	; the AddScriptToExecuteOnDocumentCreated size limit (~100 KB).
	locales_url := OllamaWV_LocalesUrl()
	locale_code := _I18nLocale
	seed_script := "window.__i18n_base='" locales_url "';window._i18n_locale='" locale_code "';"
	try _OllamaWV_WebView.AddScriptToExecuteOnDocumentCreated(seed_script)
	LoggerInfo("LLM", "i18n seed injected: base=" locales_url " locale=" locale_code ".")

	; Navigate to shared HTML
	html_url := OllamaWV_HtmlUrl()
	LoggerInfo("LLM", "WebView navigating to: " html_url ".")
	try _OllamaWV_WebView.Navigate(html_url)

	; Fit the WebView to fill the Gui
	try _OllamaWV_Controller.Fill()

	; The "ready" message from JS triggers OllamaWV_OnWebMessage which
	; flushes the queue. As a safety net, also flush after 2 s in case
	; the message bridge misfires.
	SetTimer(OllamaWV_FlushQueue.Bind(captured_epoch), -2000)

	; Queue the initial setKind so it fires once the page is ready
	OllamaWV_EvalJS("setKind(" OllamaWV_JSStr(kind) "," OllamaWV_JSStr("") "," OllamaWV_JSStr(subtitle) ")")
}

/**
 * Returns true when the WebView2 loader DLL and class are present.
 * @returns {boolean}
 */
OllamaWV_WebView2Available() {
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
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
	global _SharedDir
	base := _SharedDir . "\ui\download_window\index.html"
	loop files, base
		base := A_LoopFileFullPath
	return "file:///" . StrReplace(base, "\", "/")
}

/**
 * Returns the file:// URL for the static/ergopti_plus/_shared/data/locales/ directory (trailing slash).
 * Injected as window.__i18n_base so i18n.js fetches the correct locale file.
 * @returns {string}
 */
OllamaWV_LocalesUrl() {
	global _SharedDir
	base := _SharedDir . "\data\locales\"
	return "file:///" . StrReplace(base, "\", "/")
}

/**
 * Reads the locale JSON from disk and returns a JS ExecuteScript call that
 * populates window._i18n_strings and calls i18n_apply(). Delivered via
 * ExecuteScript (no size limit) rather than AddScriptToExecuteOnDocumentCreated.
 * @param {string} locale_code - BCP-47 locale code e.g. "fr".
 * @returns {string} JS expression to pass to ExecuteScript.
 */
OllamaWV_I18nApplyScript(locale_code) {
	global _SharedDir
	json_path := _SharedDir . "\data\locales\" . locale_code . ".json"
	json_str  := ""
	if FileExist(json_path)
		try json_str := FileRead(json_path, "UTF-8")
	if (json_str == "") {
		LoggerError("LLM", "i18n locale file not found: " json_path ".")
		json_str := "{}"
	}
	return "window._i18n_strings=" json_str
		. ";if(typeof window.i18n_apply==='function')window.i18n_apply(window._i18n_strings);"
}





; ============================
; ============================
; ======= 4/ JS Bridge =======
; ============================
; ============================

/**
 * Evaluates a JS expression in the WebView. Queues the call until the
 * page signals readiness to prevent lost updates during the bootstrap race.
 * @param {string} js - JavaScript expression to evaluate.
 */
OllamaWV_EvalJS(js) {
	global _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue, _OllamaWV_Epoch
	if !IsSet(_OllamaWV_WebView) {
		_OllamaWV_Queue.Push(js)
		return
	}
	if !_OllamaWV_Ready {
		_OllamaWV_Queue.Push(js)
		return
	}
	; Run OUTSIDE the current call stack via a one-shot timer. ExecuteScript is
	; ExecuteScriptAsync().await(), which spins a NESTED message loop; calling
	; it synchronously from inside the WebMessageReceived COM callback (as the
	; "ready" handler does) re-enters the STA apartment and wedges further
	; WebView2 message delivery.
	SetTimer(OllamaWV_RunScript.Bind(_OllamaWV_Epoch, js), -1)
}

/**
 * Executes a queued script on a fresh call stack (scheduled by OllamaWV_EvalJS
 * via a -1 timer). Fire-and-forget ExecuteScriptAsync (no .await()) -- we do
 * not need the return value, and awaiting it here would reintroduce the same
 * nested-message-loop wedge OllamaWV_EvalJS's deferral avoids.
 * @param {string} js - JavaScript expression to evaluate.
 */
OllamaWV_RunScript(captured_epoch, js) {
	global _OllamaWV_WebView, _OllamaWV_Epoch
	if (captured_epoch != _OllamaWV_Epoch or A_IsSuspended)
		return
	if !IsSet(_OllamaWV_WebView)
		return
	try {
		_OllamaWV_WebView.ExecuteScriptAsync(js)
	} catch as Err {
		try LoggerError("LLM", "ExecuteScriptAsync failed (len={1}): {2}.", StrLen(js), Err.Message)
	}
}

/**
 * Drains the queued JS calls in FIFO order.
 * Called when the page posts "ready" or after the 2-second safety timeout.
 * Also pushes the locale JSON at this point — after the DOM is ready —
 * so i18n_apply() can walk live DOM nodes instead of a not-yet-parsed tree.
 */
OllamaWV_FlushQueue(captured_epoch := unset) {
	global _OllamaWV_WebView, _OllamaWV_Ready, _OllamaWV_Queue, _I18nLocale, _OllamaWV_Epoch
	if !IsSet(captured_epoch)
		captured_epoch := _OllamaWV_Epoch
	if (captured_epoch != _OllamaWV_Epoch or A_IsSuspended)
		return
	if !IsSet(_OllamaWV_WebView)
		return
	if _OllamaWV_Ready   ; Guard: flush must only run once
		return
	_OllamaWV_Ready := true
	; Inject the full locale strings now that the DOM exists. Deferred (see
	; OllamaWV_EvalJS) so none of these run re-entrantly inside the
	; WebMessageReceived callback that typically triggers this flush.
	i18n_js := OllamaWV_I18nApplyScript(_I18nLocale)
	SetTimer(OllamaWV_RunScript.Bind(captured_epoch, i18n_js), -1)
	for _, js in _OllamaWV_Queue
		SetTimer(OllamaWV_RunScript.Bind(captured_epoch, js), -1)
	_OllamaWV_Queue := []
}

/**
 * Receives messages posted by the page via chrome.webview.postMessage.
 * Handles "ready", "cancel", "retry", "expand".
 */
OllamaWV_OnWebMessage(sender, args) {
	global _OllamaWV_OnCancel, _OllamaWV_OnRetry, _OllamaWV_WebView, _OllamaWV_Epoch
	if A_IsSuspended or !IsSet(_OllamaWV_WebView) or !(sender == _OllamaWV_WebView)
		return
	msg := ""
	try msg := args.TryGetWebMessageAsString()
	LoggerInfo("LLM", "WebView message: '" msg "'.")
	switch msg {
	case "ready":
			OllamaWV_FlushQueue(_OllamaWV_Epoch)
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





; ==========================
; ==========================
; ======= 5/ Helpers =======
; ==========================
; ==========================

/**
 * Deletes a directory if it still exists. Called via SetTimer so the deletion
 * is deferred until after Edge's child processes release their file locks.
 * @param {string} dir - Absolute path of the user-data directory to remove.
 */
_OllamaWV_DeferredDirDelete(dir) {
	if DirExist(dir)
		try DirDelete(dir, true)
}

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
