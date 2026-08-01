; ui/changelog/init.ahk

; ==============================================================================
; MODULE: Changelog Window
; DESCRIPTION:
; Shared-UI webview changelog for the Windows driver.
; Renders the same HTML/CSS/JS from _shared/ui/changelog/ that macOS uses,
; via WebView2 — so both platforms have an identical two-column interface:
; release list sidebar on the left, markdown content pane on the right.
;
; FEATURES & RATIONALE:
; 1. Shared assets: no duplicated UI code between Windows and macOS.
; 2. Native fetch bridge: AHK fetches GitHub releases via WinHTTP and injects
;    them with ExecuteScript("injectReleases(...)") so the page never makes
;    its own network call (corporate-proxy safe).
; 3. JS bridge: chrome.webview.postMessage is used by the page to request
;    channel changes and to open URLs in the default browser.
; 4. Singleton: a second call while the window is already open brings it to
;    the front instead of opening a duplicate.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ Module-level State =======
; =====================================
; =====================================

global _CLW_Gui        := unset
global _CLW_WebView    := unset
global _CLW_Controller := unset
global _CLW_MsgSub     := unset
global _CLW_Ready      := false
global _CLW_Queue      := []
global _CLW_Channel    := "dev"

; True once _CLW_Reset() has torn the controller down. Close and Escape are wired
; to the SAME handler, and Controller.Close() pumps messages — so a second Close
; dispatched during that pump would re-enter Reset and close a controller that is
; already mid-teardown. Same guard as every other WebView2 host in the driver.
global _CLW_ResetDone  := false

; Virtual host mapped to _SharedDir so the document and its relative assets
; and the locale fetch resolve over https:// -- file:// is an opaque origin
; and the chrome.webview JS->AHK channel does not reliably deliver from it
; (see PROJECT_MEMORY project-webview2-bridge-gotchas).
global CHANGELOG_VHOST := "ergopti.changelog"   ; -> _SharedDir
; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW.
global CHANGELOG_HOST_ACCESS_ALLOW := 1





; =====================================
; =====================================
; ======= 2/ Public Entry Point =======
; =====================================
; =====================================

/**
 * Opens (or brings to front) the shared changelog webview window.
 * @param {string} Channel - "main" or "dev" (default "dev").
 */
Changelog_Open(Channel := "dev") {
	global _CLW_Gui, _CLW_Channel

	; Singleton: reuse the existing window.
	if IsSet(_CLW_Gui) {
		try _CLW_Gui.Restore()
		try WinActivate(_CLW_Gui.Hwnd)
		_CLW_Channel := Channel
		_CLW_FetchAndInject(Channel)
		return
	}

	_CLW_Channel := Channel
	_CLW_Ready   := false
	_CLW_Queue   := []

	; Bail early if WebView2 is unavailable, or if free RAM is too low to absorb
	; the Chromium cold start — fall back to the lighter native changelog window.
	if (!_CLW_WebView2Available() || WebView_ShouldUseNativeFallback()) {
		_Updater_OpenChangelogWindow(Channel)
		return
	}

	_CLW_BuildWindow(Channel)
}

/**
 * Closes the changelog window if open.
 */
Changelog_Close() {
	global _CLW_Gui
	; Same reorder as _CLW_OnClose -- close the WebView2 controller before
	; destroying the Gui (WebView2 spec requirement).
	saved_gui := IsSet(_CLW_Gui) ? _CLW_Gui : 0
	_CLW_Reset()
	try {
		if saved_gui
			saved_gui.Destroy()
	}
	_CLW_Gui := unset   ; Always clear the reference, even if Destroy threw
}






; =================================
; =================================
; ======= 3/ Window Builder =======
; =================================
; =================================

_CLW_BuildWindow(Channel) {
	global _CLW_Gui, _CLW_Controller, _CLW_WebView, _CLW_ResetDone, _VendorDir

	WinTitle := t("changelog_window.window_title")
	g := Gui_Create("+Resize +MinSize860x540", WinTitle)
	g.BackColor := "0x1c1c1e"
	g.MarginX   := 0
	g.MarginY   := 0

	; Full-window placeholder that WebView2.Fill() will cover.
	; Geometry mirrors _shared/ui/apps.manifest.json (changelog 860x580, SSoT);
	; pinned by tools/test/test-webview-geometry-single-source.cjs.
	Placeholder := g.Add("Text", "x0 y0 w860 h580", "")

	g.OnEvent("Close",  _CLW_OnClose)
	g.OnEvent("Escape", _CLW_OnClose)
	g.OnEvent("Size",   _CLW_OnResize)

	g.Show("w860 h580")
	_CLW_Gui := g

	; Spin up WebView2 now that the Hwnd is valid.
	loader := _VendorDir . "\64bit\WebView2Loader.dll"

	try {
		; Reuse the shared session environment (infra/webview_utils.ahk) so no
		; second Chromium process boots and reopens are near-instant.
		_CLW_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("Changelog", "WebView2 create failed: {1}.", Err.Message)
		try g.Destroy()
		_CLW_Reset()
		; Clear the handle explicitly: the reset above short-circuits when a
		; previous session already latched _CLW_ResetDone, and a _CLW_Gui left
		; pointing at the Gui just destroyed would make Changelog_Open take its
		; singleton branch forever.
		_CLW_Gui := unset
		; Graceful degradation to the old AHK-native changelog window.
		_Updater_OpenChangelogWindow(Channel)
		return
	}

	_CLW_WebView := _CLW_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a flag
	; left behind by an earlier _CLW_Reset() call.
	_CLW_ResetDone := false

	; Harden the webview — no devtools, no context menu, no status bar.
	try {
		s := _CLW_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; JS → AHK bridge. Store the subscription handle in a persistent global --
	; discarding it lets the binding GC it and silently unsubscribe the handler.
	global _CLW_MsgSub := _CLW_WebView.WebMessageReceived(_CLW_OnWebMessage)

	; Map the virtual host BEFORE navigating so the document and every relative
	; asset and the locale fetch resolve through it instead of an opaque file://
	; origin.
	try _CLW_WebView.SetVirtualHostNameToFolderMapping(CHANGELOG_VHOST, _SharedDir, CHANGELOG_HOST_ACCESS_ALLOW)

	; Inject i18n base URL and active locale BEFORE the page scripts run,
	; exactly as ollama_webview.ahk does. Also inject repo config and channel.
	locales_url := _CLW_LocalesUrl()
	locale_code := _I18nLocale
	gh_owner    := UPDATER_GH_OWNER
	gh_repo     := UPDATER_GH_REPO
	seed := "window.__i18n_base='" . locales_url . "';"
		. "window._i18n_locale='" . locale_code . "';"
		. "window.__changelog_gh_owner='" . gh_owner . "';"
		. "window.__changelog_gh_repo='"  . gh_repo  . "';"
		. "window.__changelog_channel='"  . Channel  . "';"
	try _CLW_WebView.AddScriptToExecuteOnDocumentCreated(seed)

	; Navigate to the shared HTML file.
	html_url := _CLW_HtmlUrl()
	try LoggerStart("Changelog", "Navigating to {1}…", html_url)
	NavOk := false
	try {
		_CLW_WebView.Navigate(html_url)
		NavOk := true
	} catch as e {
		try LoggerError("Changelog", "Navigate failed for {1}: {2}.", html_url, e.Message)
	}
	; Close the pair on both paths. The START above had no reachable SUCCESS
	; anywhere in this file, so a Navigate that threw — swallowed by the bare try
	; it used to sit in — looked exactly like one still in flight, forever.
	if NavOk
		try LoggerSuccess("Changelog", "Navigation issued for {1}.", html_url)

	; Fill the WebView2 to cover the entire window client area.
	try _CLW_Controller.Fill()

	; Safety flush in case the "ready" message from JS never fires.
	SetTimer(_CLW_SafetyFlush, -2000)

	; Inject i18n strings once the page is ready (via the flush queue).
	_CLW_Eval(_CLW_I18nApplyScript())
}






; ====================================
; ====================================
; ======= 4/ JS Bridge & Queue =======
; ====================================
; ====================================

/**
 * Evaluates JS in the WebView, queuing it until the page signals "ready".
 * @param {string} Js - JavaScript expression.
 */
_CLW_Eval(Js) {
	global _CLW_WebView, _CLW_Ready, _CLW_Queue
	if (_CLW_Ready && IsSet(_CLW_WebView)) {
		; Run OUTSIDE the current call stack via a one-shot timer. ExecuteScript
		; is ExecuteScriptAsync().await(), which spins a NESTED message loop;
		; calling it synchronously from inside the WebMessageReceived COM
		; callback (as the "ready" handler does) re-enters the STA apartment
		; and wedges further WebView2 message delivery -- the channel then
		; delivers exactly one message then goes silent.
		SetTimer(_CLW_RunScript.Bind(Js), -1)
	} else {
		_CLW_Queue.Push(Js)
		; Cap the queue to avoid unbounded growth if the page never becomes ready.
		if (_CLW_Queue.Length > 200)
			_CLW_Queue.RemoveAt(1)
	}
}

/**
 * Executes a queued script on a fresh call stack (scheduled by _CLW_Eval via a
 * -1 timer). Uses ExecuteScriptAsync fire-and-forget (no .await()) -- we do
 * not need the script's return value, and awaiting it here would reintroduce
 * the same nested-message-loop wedge _CLW_Eval's deferral avoids.
 * @param {string} Js - JavaScript expression.
 */
_CLW_RunScript(Js) {
	global _CLW_WebView
	if !IsSet(_CLW_WebView)
		return
	try {
		_CLW_WebView.ExecuteScriptAsync(Js)
	} catch as Err {
		try LoggerError("Changelog", "ExecuteScriptAsync failed (len={1}): {2}.", StrLen(Js), Err.Message)
	}
}

/**
 * Flushes all queued JS calls now that the page is ready.
 */
_CLW_FlushQueue() {
	global _CLW_Ready, _CLW_Queue, _CLW_WebView
	_CLW_Ready := true
	; Defer each queued script (see _CLW_Eval) so none runs re-entrantly inside
	; the WebMessageReceived callback that typically triggers this flush.
	for _, Js in _CLW_Queue {
		if IsSet(_CLW_WebView)
			SetTimer(_CLW_RunScript.Bind(Js), -1)
	}
	_CLW_Queue := []
}

/**
 * Everything the page becoming ready must trigger, in one place.
 *
 * Flushing the queue LATCHES _CLW_Ready, and no later message re-triggers the
 * fetch — so an entry point that flushed without fetching left the window
 * permanently empty, styled and localised but with no releases in it. That is
 * the exact defect the model browser hit and fixed by routing both of its entry
 * points through a single handler (_LLM_MBW_OnPageReady); the two paths here go
 * through this one for the same reason.
 */
_CLW_OnPageReady() {
	global _CLW_Channel
	_CLW_FlushQueue()
	; Kick off the first fetch from AHK so the page receives data immediately.
	_CLW_FetchAndInject(_CLW_Channel)
}

/**
 * Safety-net flush: fires 2 s after window creation in case the "ready"
 * postMessage from JS never arrives (e.g. navigation error).
 */
_CLW_SafetyFlush() {
	if (_CLW_Ready)
		return
	try LoggerWarn("Changelog", "No 'ready' message from the page after the safety delay — flushing and fetching anyway.")
	_CLW_OnPageReady()
}

/**
 * Receives messages from the page via chrome.webview.postMessage.
 * Expected payloads (JSON strings):
 *   "ready"                           — page bootstrap complete
 *   {"action":"fetch","channel":"dev"} — user switched channel
 *   {"action":"open_url","url":"…"}   — open a URL in the browser
 */
_CLW_OnWebMessage(Handler, Args) {
	global _CLW_Channel
	try Msg := Args.TryGetWebMessageAsString()
	if !IsSet(Msg)
		return
	; WebMessageReceived is a COM callback that bypasses native Suspend, so
	; without this guard a paused driver would still dispatch a network fetch
	; and mutate _CLW_Channel ("pause = tout éteint" invariant).
	; Page-lifecycle signals are deliberately NOT gated — the page posts "ready"
	; exactly once, so dropping it while suspended stranded the window forever:
	; the SafetyFlush then latched _CLW_Ready without fetching, and resuming the
	; driver could not re-trigger anything. Same exemption as every hardened
	; sibling host.
	if (A_IsSuspended && Msg != "ready")
		return

	if (Msg == "ready") {
		_CLW_OnPageReady()
		return
	}

	; Try to parse as JSON action payload.
	try Payload := JsonParse(Msg)
	if !IsSet(Payload)
		return
	if !IsObject(Payload)
		return

	Action := Payload.Has("action") ? Payload["action"] : ""

	if (Action == "fetch") {
		Ch := Payload.Has("channel") ? Payload["channel"] : _CLW_Channel
		_CLW_Channel := Ch
		_CLW_FetchAndInject(Ch)
	} else if (Action == "open_url") {
		Url := Payload.Has("url") ? Payload["url"] : ""
		if (Url != "")
			try Run(Url)
	}
}






; ========================================
; ========================================
; ======= 5/ GitHub Fetch & Inject =======
; ========================================
; ========================================

/**
 * Fetches releases from GitHub (asynchronous WinHTTP) and injects them via JS.
 * Defers to next message-loop tick; fetch is non-blocking async WinHttp.
 * @param {string} Channel - "main" or "dev".
 */
_CLW_FetchAndInject(Channel) {
	; Defer to a fresh call stack so the WebMessage callback returns immediately.
	SetTimer(() => _CLW_DoFetch(Channel), -1)
}

_CLW_DoFetch(Channel) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS

	try LoggerTrace("Changelog", "Fetching releases (channel={1})…", Channel)

	Url := "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases?per_page=20"

	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		; Open async (true) so Send returns immediately and a slow or stalled
		; network can never block the AHK main thread — and therefore never freeze
		; keyboard remapping. Completion is harvested via a non-blocking SetTimer
		; poll, mirroring _Updater_FetchLatestJsonAsync / _Updater_PollAsync.
		Req.Open("GET", Url, true)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Changelog/1.0")
		; Resolve timeout was 0 (infinite) — on a captive network this would stall
		; the timer thread indefinitely, blocking all subsequent timer callbacks.
		; Reuse the shared updater constants so all network calls have the same budget.
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		Req.Send()
	} catch as Err {
		try LoggerWarn("Changelog", "GitHub API request failed: {1}.", Err.Message)
		ErrMsg := _CLW_JsStr(t("changelog_window.error_network"))
		_CLW_Eval("injectError(" . ErrMsg . ")")
		return
	}

	; Arm the non-blocking completion poll for this request.
	_CLW_PollFetch(Req, Channel, 0)
}

; Non-blocking completion poll for one in-flight async changelog fetch. Asks
; WinHTTP "is the response ready?" via WaitForResponse(0) (0 = do not wait) and
; re-arms itself until ready, then harvests ResponseText and injects it. The
; poll budget mirrors the updater's so a wedged request can never leave a timer
; running forever.
_CLW_PollFetch(Req, Channel, Polls) {
	global UPDATER_ASYNC_POLL_MS, UPDATER_ASYNC_MAX_POLLS

	ready  := false
	failed := false
	try {
		ready := Req.WaitForResponse(0)
	} catch as Err {
		failed := true
		try LoggerWarn("Changelog", "GitHub API request failed: {1}.", Err.Message)
	}

	if (!failed and !ready) {
		Polls += 1
		if (Polls > UPDATER_ASYNC_MAX_POLLS) {
			failed := true
			try LoggerWarn("Changelog", "GitHub API request exceeded its poll budget — aborting.")
		} else {
			SetTimer(() => _CLW_PollFetch(Req, Channel, Polls), -UPDATER_ASYNC_POLL_MS)
			return
		}
	}

	Json := ""
	Status := 0
	if !failed {
		try {
			Status := Req.Status
			if (Status == 200)
				Json := Req.ResponseText
		} catch as Err {
			try LoggerWarn("Changelog", "GitHub API response read failed: {1}.", Err.Message)
		}
	}

	if (Json == "") {
		; Every non-200 used to leave through here in complete silence: the
		; request had succeeded, so none of the catches above fired, and the
		; status was tested but never captured. The user was shown a network
		; error for what is most often a 403 rate-limit, and the log — which had
		; opened a lifecycle line for this fetch — recorded nothing at all.
		try LoggerWarn("Changelog", "GitHub API returned HTTP {1} — no releases injected (channel={2}).",
			Status, Channel)
		; A rate-limit is not an outage, and telling the user to check their
		; connection sends them after the wrong problem.
		ErrKey := (Status == 403 or Status == 429)
			? "changelog_window.error_rate_limited"
			: "changelog_window.error_network"
		ErrMsg := _CLW_JsStr(t(ErrKey))
		_CLW_Eval("injectError(" . ErrMsg . ")")
		return
	}

	; Pass the raw JSON array to the JS side; injectReleases filters pre-releases
	; for the "main" channel. Doing it in JS avoids a fragile AHK JSON parser.
	try LoggerDone("Changelog", "Injecting releases (channel={1})…", Channel)
	_CLW_Eval("injectReleases(" . Json . "," . _CLW_JsStr(Channel) . ")")
}






; ==========================
; ==========================
; ======= 6/ Helpers =======
; ==========================
; ==========================

/**
 * Returns true when WebView2 is available and the loader DLL exists.
 * @returns {boolean}
 */
_CLW_WebView2Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

/**
 * Returns the https:// virtual-host URL for _shared/ui/changelog/index.html.
 * A per-open cache-buster forces a fresh document each launch instead of a
 * WebView2-cached stale copy from the virtual host.
 * @returns {string}
 */
_CLW_HtmlUrl() {
	global CHANGELOG_VHOST
	return "https://" . CHANGELOG_VHOST . "/ui/changelog/index.html?cb=" . A_TickCount
}

/**
 * Returns the https:// virtual-host URL for _shared/data/locales/ (trailing slash).
 * @returns {string}
 */
_CLW_LocalesUrl() {
	global CHANGELOG_VHOST
	return "https://" . CHANGELOG_VHOST . "/data/locales/"
}

/**
 * Builds the ExecuteScript call that applies i18n strings to the page.
 * Reads the locale JSON from disk so no network call is needed.
 * @returns {string}
 */
_CLW_I18nApplyScript() {
	global _SharedDir, _I18nLocale
	json_path := _SharedDir . "\data\locales\" . _I18nLocale . ".json"
	json_str  := "{}"
	if FileExist(json_path)
		try json_str := FileRead(json_path, "UTF-8")
	return "window._i18n_strings=" . json_str
		. ";if(typeof window.i18n_apply==='function')window.i18n_apply(window._i18n_strings);"
}

/**
 * Escapes a Lua/AHK string for safe injection into a JS string literal.
 * @param {string} s
 * @returns {string} JS double-quoted string.
 */
_CLW_JsStr(s) {
	s := StrReplace(s, "\",  "\\")
	s := StrReplace(s, '"',  '\"')
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`t", "\t")
	return '"' . s . '"'
}

/**
 * Resets all module-level state after window close.
 */
_CLW_Reset() {
	global _CLW_Gui, _CLW_WebView, _CLW_Controller, _CLW_MsgSub, _CLW_Ready, _CLW_Queue, _CLW_ResetDone
	; Close and Escape are wired to the same handler and Controller.Close() pumps
	; messages, so a second dispatch can re-enter this function while the first
	; teardown is still in flight. Short-circuit instead of running the release +
	; Close sequence twice against a controller that is already going away.
	if _CLW_ResetDone
		return
	_CLW_ResetDone := true
	; Release the subscription FIRST, while the controller is still alive. Its
	; __Delete unsubscribes via remove_WebMessageReceived on the live
	; controller; doing it AFTER Controller.Close() raises a COM error.
	try _CLW_MsgSub := unset
	if IsSet(_CLW_Controller)
		try _CLW_Controller.Close()
	_CLW_Gui        := unset
	_CLW_WebView    := unset
	_CLW_Controller := unset
	_CLW_Ready      := false
	_CLW_Queue      := []
}






; ========================================
; ========================================
; ======= 7/ Window Event Handlers =======
; ========================================
; ========================================

_CLW_OnClose(*) {
	global _CLW_Gui
	; Save the Gui reference BEFORE Reset clears the global, then close the
	; WebView2 controller first (while the parent window is still alive) and
	; only destroy the Gui afterwards -- the WebView2 spec requires Controller
	; to be closed before its host HWND is destroyed. Mirrors
	; ui/model_browser/init.ahk's _LLM_MBW_OnClose.
	saved_gui := IsSet(_CLW_Gui) ? _CLW_Gui : 0
	_CLW_Reset()
	try {
		if saved_gui
			saved_gui.Destroy()
	}
	_CLW_Gui := unset   ; Always clear the reference, even if Destroy threw
}

_CLW_OnResize(GuiObj, MinMax, Width, Height) {
	global _CLW_Controller
	if (MinMax == -1)
		return
	if IsSet(_CLW_Controller)
		try _CLW_Controller.Fill()
}
