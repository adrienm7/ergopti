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
; 2. Native fetch bridge: AHK fetches GitHub releases in a curl child routed
;    through the Windows proxy (static or PAC), trying the API and then the
;    public Atom feed, and hands the text to the page as a JS string
;    (injectReleasesJson / injectReleasesFeed) so the page never makes its own
;    network call and never evaluates a response.
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
global _CLW_Request    := unset
global _CLW_BridgeSessionToken := ""
global _CLW_BridgeRejectionReported := false

; Every asynchronous fetch owns both the WebView session that started it and a
; monotonically increasing request epoch.  A channel switch invalidates the
; request epoch; close/reopen also invalidates the window epoch.  Keeping both
; identities is necessary because deferred ExecuteScript timers otherwise use
; whichever global WebView happens to exist when they finally run.
global _CLW_WindowEpoch        := 0
global _CLW_RequestEpoch       := 0
global _CLW_ActiveRequest      := 0
global _CLW_ActiveRequestEpoch := 0

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

; Release sources, tried in order: the REST API, then the public Atom feed on
; github.com, which corporate proxies usually leave reachable when they block
; or throttle api.github.com. Mirrors release_sources in
; _shared/modules/updater/defaults.json (pinned by
; tools/test/test-changelog-network-resilience.cjs).
global CHANGELOG_API_URL_TEMPLATE  := "https://api.github.com/repos/{owner}/{repo}/releases?per_page=20"
global CHANGELOG_FEED_URL_TEMPLATE := "https://github.com/{owner}/{repo}/releases.atom"
global CHANGELOG_SOURCE_TIMEOUT_MS := 15000
; Share of the source budget allowed for DNS, proxy and TCP/TLS connection.
global CHANGELOG_CONNECT_TIMEOUT_MS := 10000
; Test seam: replaces the deferred start of the Atom feed request (0 = SetTimer).
global _CLW_FeedStarter := 0





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
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if A_IsSuspended
		return _Updater_RefuseManualWhileSuspended()
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	return _CLW_OpenCapturedRequest(Channel, Request)
}

_CLW_OpenCapturedRequest(Channel, Request) {
	global _CLW_Gui, _CLW_Channel, _CLW_Ready, _CLW_Queue
	global _CLW_Request
	if !_Updater_RequestMayPublish(Request)
		return false

	; Singleton: reuse the existing window.
	if IsSet(_CLW_Gui) {
		try _CLW_Gui.Restore()
		if !_Updater_RequestMayPublish(Request)
			return false
		try WinActivate(_CLW_Gui.Hwnd)
		if !_Updater_RequestMayPublish(Request)
			return false
		_CLW_Channel := Channel
		_CLW_Request := Request
		_CLW_FetchAndInject(Channel, Request)
		return
	}

	_CLW_Channel := Channel
	_CLW_Request := Request
	_CLW_Ready   := false
	_CLW_Queue   := []

	; Bail early if WebView2 is unavailable, or if free RAM is too low to absorb
	; the Chromium cold start — fall back to the lighter native changelog window.
	if (!_CLW_WebView2Available() || WebView_ShouldUseNativeFallback()) {
		_Updater_OpenChangelogWindow(Channel, Request)
		return
	}

	_CLW_BuildWindow(Channel, Request)
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

_CLW_BuildWindow(Channel, Request) {
	global _CLW_Gui, _CLW_Controller, _CLW_WebView, _CLW_ResetDone, _VendorDir
	global _CLW_BridgeSessionToken, _CLW_WindowEpoch
	if !_Updater_RequestMayPublish(Request)
		return false

	; Allocate the session identity before any deferred page work is queued.
	; This also aborts a request retained by an incompletely torn-down session.
	WindowEpoch := _CLW_BeginWindowSession()

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
	if !_Updater_RequestMayPublish(Request) {
		_CLW_OnClose()
		return false
	}

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
		_Updater_OpenChangelogWindow(Channel, Request)
		return
	}
	if !_Updater_RequestMayPublish(Request) {
		_CLW_OnClose()
		return false
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
	session     := _CLW_BridgeSessionToken
	seed := "window.__i18n_base='" . locales_url . "';"
		. "window._i18n_locale='" . locale_code . "';"
		. "window.__changelog_gh_owner='" . gh_owner . "';"
		. "window.__changelog_gh_repo='"  . gh_repo  . "';"
		. "window.__changelog_channel='"  . Channel  . "';"
		. "window.__changelog_session=" . _CLW_JsStr(session) . ";"
	try _CLW_WebView.AddScriptToExecuteOnDocumentCreated(seed)

	; Navigate to the shared HTML file.
	html_url := _CLW_HtmlUrl()
	; Bind immutable document/session provenance into this subscription. A stale
	; controller callback cannot adopt the globals of a reopened changelog.
	global _CLW_MsgSub := _CLW_WebView.WebMessageReceived(
		_CLW_OnWebMessage.Bind(WindowEpoch, session, html_url))
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
	SetTimer(_CLW_SafetyFlush.Bind(WindowEpoch), -2000)

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
 * @param {object|integer} Context - Optional immutable fetch context.
 */
_CLW_Eval(Js, Context := 0, NotifyFn := 0) {
	global _CLW_WebView, _CLW_Ready, _CLW_Queue, _CLW_WindowEpoch
	global UPDATER_REQUEST_POLICY_ALLOW
	ShouldSchedule := false
	AcceptWork := true
	NeedsRequestTerminal := false
	Request := 0
	PreviousCritical := Critical("On")
	try {
		if IsObject(Context) {
			Request := Context.HasProp("Request") ? Context.Request : 0
			NeedsRequestTerminal := _Updater_RequestPolicy(Request) != UPDATER_REQUEST_POLICY_ALLOW
			AcceptWork := !NeedsRequestTerminal && _CLW_RequestEpochIsCurrent(Context)
		}

		if AcceptWork {
			Work := {
				Js: Js,
				WindowEpoch: _CLW_WindowEpoch,
				RequestEpoch: IsObject(Context) ? Context.RequestEpoch : 0,
				Request: Request
			}
			ShouldSchedule := _CLW_Ready && IsSet(_CLW_WebView)
			if !ShouldSchedule {
				_CLW_Queue.Push(Work)
				; Cap the queue to avoid unbounded growth if the page never becomes ready.
				if (_CLW_Queue.Length > 200)
					_CLW_Queue.RemoveAt(1)
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
	if NeedsRequestTerminal {
		_Updater_RequestMayPublish(Request, , NotifyFn)
		return false
	}
	if !AcceptWork
		return false

	if ShouldSchedule {
		; Run OUTSIDE the current call stack via a one-shot timer. ExecuteScript
		; is ExecuteScriptAsync().await(), which spins a NESTED message loop;
		; calling it synchronously from inside the WebMessageReceived COM
		; callback (as the "ready" handler does) re-enters the STA apartment
		; and wedges further WebView2 message delivery -- the channel then
		; delivers exactly one message then goes silent.
		SetTimer(_CLW_RunScript.Bind(Work), -1)
	}
	return true
}

/**
 * Executes a queued script on a fresh call stack (scheduled by _CLW_Eval via a
 * -1 timer). Uses ExecuteScriptAsync fire-and-forget (no .await()) -- we do
 * not need the script's return value, and awaiting it here would reintroduce
 * the same nested-message-loop wedge _CLW_Eval's deferral avoids.
 * @param {object} Work - Script plus its bound window/request epochs.
 */
_CLW_RunScript(Work, NotifyFn := 0) {
	global _CLW_WebView
	global UPDATER_REQUEST_POLICY_ALLOW
	ShouldRun := false
	NeedsRequestTerminal := false
	Request := 0
	PreviousCritical := Critical("On")
	try {
		if IsObject(Work) {
			Request := Work.HasProp("Request") ? Work.Request : 0
			if IsObject(Request)
				NeedsRequestTerminal := _Updater_RequestPolicy(Request) != UPDATER_REQUEST_POLICY_ALLOW
			ShouldRun := !NeedsRequestTerminal
				&& _CLW_ScriptWorkEpochIsCurrent(Work)
				&& IsSet(_CLW_WebView)
			if ShouldRun {
				; Capture the controller-owned WebView in the same atomic read that
				; validates its session.  The COM call itself remains off-Critical.
				WebView := _CLW_WebView
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
	if NeedsRequestTerminal {
		_Updater_RequestMayPublish(Request, , NotifyFn)
		return
	}
	if !ShouldRun
		return
	WebView_RunScriptAsync(WebView, Work.Js, "Changelog")
}

/**
 * Flushes all queued JS calls now that the page is ready.
 */
_CLW_FlushQueue(ExpectedWindowEpoch, OnlyIfUnready := false) {
	global _CLW_WindowEpoch, _CLW_Ready, _CLW_Queue, _CLW_WebView
	PreviousCritical := Critical("On")
	try {
		if ExpectedWindowEpoch != _CLW_WindowEpoch
			return false
		if OnlyIfUnready && _CLW_Ready
			return false
		_CLW_Ready := true
		Pending := _CLW_Queue
		_CLW_Queue := []
	} finally {
		Critical(PreviousCritical)
	}
	; Defer each queued script (see _CLW_Eval) so none runs re-entrantly inside
	; the WebMessageReceived callback that typically triggers this flush.
	for _, Work in Pending
		SetTimer(_CLW_RunScript.Bind(Work), -1)
	return true
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
_CLW_OnPageReady(ExpectedWindowEpoch, OnlyIfUnready := false) {
	global _CLW_WindowEpoch, _CLW_Channel, _CLW_Request
	if !_CLW_FlushQueue(ExpectedWindowEpoch, OnlyIfUnready)
		return false
	PreviousCritical := Critical("On")
	try {
		if ExpectedWindowEpoch != _CLW_WindowEpoch
			return false
		Channel := _CLW_Channel
		Request := IsSet(_CLW_Request) ? _CLW_Request : 0
	} finally {
		Critical(PreviousCritical)
	}
	; Kick off the first fetch from AHK so the page receives data immediately.
	if IsObject(Request) && _Updater_RequestMayPublish(Request)
		return _CLW_FetchAndInject(Channel, Request, ExpectedWindowEpoch)
	return true
}

/**
 * Safety-net flush: fires 2 s after window creation in case the "ready"
 * postMessage from JS never arrives (e.g. navigation error).
 */
_CLW_SafetyFlush(ExpectedWindowEpoch) {
	if !_CLW_OnPageReady(ExpectedWindowEpoch, true)
		return false
	try LoggerWarn("Changelog", "No 'ready' message from the page after the safety delay — flushing and fetching anyway.")
	return true
}

/**
 * Receives messages from the page via chrome.webview.postMessage.
 * Expected payloads (JSON strings), each carrying the injected session token:
 *   {"action":"ready","session":"…"}
 *   {"action":"fetch","channel":"dev","session":"…"}
 *   {"action":"open_url","url":"…","session":"…"}
 */
_CLW_OnWebMessage(ExpectedWindowEpoch, ExpectedSession, ExpectedSource, Handler, Args) {
	global _CLW_Channel
	if !_CLW_BridgeSourceMatches(Args, ExpectedSource) {
		_CLW_ReportRejectedBridgeMessage()
		return
	}
	if !_CLW_BridgeSessionIsCurrent(ExpectedWindowEpoch, ExpectedSession) {
		_CLW_ReportRejectedBridgeMessage()
		return
	}
	; Capture entry-time pause provenance before the COM read can pump messages.
	Envelope := _Updater_ReadManualBridgeMessage(
		() => Args.TryGetWebMessageAsString())
	if (!IsObject(Envelope) or !Envelope.Ok)
		return
	if !_CLW_BridgeSessionIsCurrent(ExpectedWindowEpoch, ExpectedSession)
		return
	Request := Envelope.Request
	Msg := Envelope.Message
	; Try to parse as JSON action payload.
	try Payload := JsonParse(Msg)
	if !IsSet(Payload)
		return
	if !IsObject(Payload)
		return
	if !Payload.Has("session") || !(Payload["session"] is String) {
		_CLW_ReportRejectedBridgeMessage()
		return
	}
	if Payload["session"] !== ExpectedSession {
		_CLW_ReportRejectedBridgeMessage()
		return
	}
	if !_CLW_BridgeSessionIsCurrent(ExpectedWindowEpoch, ExpectedSession)
		return

	Action := Payload.Has("action") ? Payload["action"] : ""
	; Page-lifecycle signals are deliberately NOT pause-gated. The exact source
	; and session checks above still apply before the ready signal can mutate.
	if (Action == "ready") {
		_CLW_OnPageReady(ExpectedWindowEpoch)
		return
	}
	; WebMessageReceived bypasses native Suspend. A click born paused refuses
	; visibly; a click interrupted during TryGet retains one resume terminal.
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return

	if (Action == "fetch") {
		Ch := Payload.Has("channel") ? Payload["channel"] : _CLW_Channel
		_CLW_Channel := Ch
		_CLW_FetchAndInject(Ch, Request)
	} else if (Action == "open_url") {
		Url := Payload.Has("url") ? Payload["url"] : ""
		if !ExternalUrl_IsHttp(Url) {
			LoggerWarn("ExternalUrl", "Refusing external URL: only absolute HTTP and HTTPS URLs are allowed.")
			return
		}
		if (Url != "")
			_Updater_OpenManualUrl(() => Url, Request)
	}
}






; ========================================
; ========================================
; ======= 5/ GitHub Fetch & Inject =======
; ========================================
; ========================================

/**
 * Fetches releases from GitHub in a tree-owned curl child and injects them via JS.
 * Defers to next message-loop tick; every network phase stays off the AHK thread.
 * @param {string} Channel - "main" or "dev".
 */
_CLW_FetchAndInject(Channel, Request := unset, ExpectedWindowEpoch := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if !IsSet(Request)
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if !_Updater_RequestMayPublish(Request)
		return false
	Context := _CLW_BeginFetchRequest(Channel, Request, ExpectedWindowEpoch)
	if !IsObject(Context)
		return false
	; Defer to a fresh call stack so the WebMessage callback returns immediately.
	SetTimer(_CLW_DoFetch.Bind(Context), -1)
	return true
}

_CLW_DoFetch(Context, Proxy := unset) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	global CHANGELOG_SOURCE_TIMEOUT_MS, CHANGELOG_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS
	if !_CLW_RequestIsCurrent(Context)
		return
	Channel := Context.Channel
	Url := _CLW_SourceUrl(Context.Stage)

	; curl ignores the Windows proxy; resolve it first (static settings answer at
	; once, a PAC script in a bounded child) and re-enter with the answer.
	if !IsSet(Proxy) {
		SystemProxy_ResolveAsync([Url],
			(Resolved) => _CLW_DoFetch(Context, Resolved[Url]))
		return
	}

	try LoggerTrace("Changelog", "Fetching releases from {1} (channel={2}, proxy={3})…",
		Context.Stage, Channel, Proxy == "" ? "direct" : "system")

	try {
		Req := CurlAsyncRequest()
		; The child owns DNS, connect, Send and response wait. Completion is
		; harvested via the existing non-blocking SetTimer poll.
		Req.Open("GET", Url, true)
		Req.SetRequestHeader("Accept", Context.Stage == "feed"
			? "application/atom+xml" : "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Changelog/1.0")
		Req.SetProxy(Proxy)
		; One bounded budget per source: connection within
		; CHANGELOG_CONNECT_TIMEOUT_MS, the whole transfer within
		; CHANGELOG_SOURCE_TIMEOUT_MS, so the page watchdog outlasts both sources.
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS,
			CHANGELOG_CONNECT_TIMEOUT_MS - UPDATER_HTTP_RESOLVE_TIMEOUT_MS, 0,
			CHANGELOG_SOURCE_TIMEOUT_MS - CHANGELOG_CONNECT_TIMEOUT_MS)
		; Publish ownership immediately before Send.  A superseding fetch or a
		; close can now abort this exact request even if Send pumps messages.
		if !_CLW_RegisterActiveRequest(Context, Req) {
			_CLW_AbortRequest(Req)
			return
		}
		Req.Send()
	} catch as Err {
		_CLW_ReleaseActiveRequest(Context)
		if !_CLW_RequestIsCurrent(Context)
			return
		_CLW_SourceFailed(Context, 0, "dispatch failed: " . Err.Message)
		return
	}
	if !_CLW_RequestIsCurrent(Context) {
		_CLW_AbortRequest(Req)
		_CLW_ReleaseActiveRequest(Context)
		return
	}

	; Arm the non-blocking completion poll for this request.
	_CLW_PollFetch(Req, Context, 0)
}

/**
 * Expands the URL of one release source from the repository identity.
 * @param {string} Stage - "api" or "feed".
 * @returns {string}
 */
_CLW_SourceUrl(Stage) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	global CHANGELOG_API_URL_TEMPLATE, CHANGELOG_FEED_URL_TEMPLATE
	Template := (Stage == "feed") ? CHANGELOG_FEED_URL_TEMPLATE : CHANGELOG_API_URL_TEMPLATE
	return StrReplace(StrReplace(Template, "{owner}", UPDATER_GH_OWNER), "{repo}", UPDATER_GH_REPO)
}

/**
 * Validates one completed response. A proxy block page served with HTTP 200
 * is a failure, not data.
 * @returns {string} "" when usable, otherwise the failure reason.
 */
_CLW_ClassifySource(Stage, Status, Body) {
	if (Status != 200)
		return (Status == 0) ? "no HTTP response (network, proxy or timeout)" : "HTTP " . Status
	if !(Body is String)
		return "HTTP 200 without a body"
	if (Stage == "feed")
		return RegExMatch(Body, "<feed[\s>]") ? "" : "HTTP 200 without an Atom feed"
	return RegExMatch(Body, "^\x{FEFF}?\s*\[[\s\S]*\]\s*$") ? "" : "HTTP 200 without a JSON release array"
}

/**
 * Routes a failed source: the API falls back to the Atom feed, the feed ends
 * the load with a visible, translated error.
 */
_CLW_SourceFailed(Context, Status, Reason) {
	global _CLW_FeedStarter
	Channel := Context.Channel
	if (Context.Stage == "api") {
		try LoggerWarn("Changelog", "GitHub API release list failed ({1}); trying the Atom feed (channel={2}).",
			Reason, Channel)
		Feed := {
			WindowEpoch: Context.WindowEpoch,
			RequestEpoch: Context.RequestEpoch,
			Channel: Channel,
			Request: Context.Request,
			Stage: "feed",
			ApiFailure: Reason,
			ApiStatus: Status
		}
		if IsObject(_CLW_FeedStarter)
			_CLW_FeedStarter.Call(Feed)
		else
			SetTimer(_CLW_DoFetch.Bind(Feed), -1)
		return
	}
	try LoggerWarn("Changelog", "Release sources exhausted: API failed ({1}), Atom feed failed ({2}) (channel={3}).",
		Context.ApiFailure, Reason, Channel)
	; A rate-limit is not an outage, and telling the user to check their
	; connection sends them after the wrong problem.
	ErrKey := (Context.ApiStatus == 403 or Context.ApiStatus == 429)
		? "changelog_window.error_rate_limited"
		: "changelog_window.error_network"
	_CLW_Eval("injectError(" . _CLW_JsStr(t(ErrKey)) . ")", Context)
}

; Non-blocking completion poll for one in-flight async changelog fetch. Asks
; the curl transport "is the response ready?" via WaitForResponse(0) (0 = do
; not wait) and re-arms itself until ready, then harvests ResponseText and
; either injects it or routes the failure. The poll budget follows the source
; budget so a wedged request can never leave a timer running forever.
_CLW_PollFetch(Req, Context, Polls) {
	global UPDATER_ASYNC_POLL_MS, CHANGELOG_SOURCE_TIMEOUT_MS
	if !_CLW_RequestIsCurrent(Context) {
		_CLW_AbortRequest(Req)
		_CLW_ReleaseActiveRequest(Context)
		return
	}
	Channel := Context.Channel

	ready  := false
	failed := false
	Reason := ""
	try {
		ready := Req.WaitForResponse(0)
	} catch as Err {
		failed := true
		Reason := "transport failed: " . Err.Message
	}
	if !_CLW_RequestIsCurrent(Context) {
		_CLW_AbortRequest(Req)
		_CLW_ReleaseActiveRequest(Context)
		return
	}
	if failed
		_CLW_AbortRequest(Req)

	if (!failed and !ready) {
		Polls += 1
		if (Polls > Ceil(CHANGELOG_SOURCE_TIMEOUT_MS / UPDATER_ASYNC_POLL_MS) + 20) {
			failed := true
			Reason := "poll budget exceeded"
			_CLW_AbortRequest(Req)
		} else {
			SetTimer(_CLW_PollFetch.Bind(Req, Context, Polls), -UPDATER_ASYNC_POLL_MS)
			return
		}
	}

	Json := ""
	Status := 0
	if !failed {
		try {
			Status := Req.Status
			Body := Req.ResponseText
			Reason := _CLW_ClassifySource(Context.Stage, Status, Body)
			if (Reason == "")
				Json := Body
		} catch as Err {
			Reason := "response read failed: " . Err.Message
		}
	}
	_CLW_ReleaseActiveRequest(Context)
	if !_CLW_RequestIsCurrent(Context)
		return

	if (Json == "") {
		; A non-200 used to leave in silence; the HTTP status is what separates a
		; 403 rate-limit from a proxy refusal or an outage, so it is always logged.
		try LoggerWarn("Changelog", "Release source {1} returned HTTP {2}: {3} (channel={4}).",
			Context.Stage, Status, Reason, Channel)
		_CLW_SourceFailed(Context, Status, Reason)
		return
	}

	; The text crosses into the page as a JS string literal and is parsed there
	; (JSON.parse or the Atom reader); a response is never evaluated as script.
	; injectReleases* filters pre-releases for the "main" channel.
	if (Context.Stage == "feed") {
		try LoggerDone("Changelog", "Injecting releases from the Atom feed (channel={1}; API failed: {2})…",
			Channel, Context.ApiFailure)
		_CLW_Eval("injectReleasesFeed(" . _CLW_JsStr(Json) . "," . _CLW_JsStr(Channel) . ")", Context)
		return
	}
	try LoggerDone("Changelog", "Injecting releases from the GitHub API (channel={1})…", Channel)
	_CLW_Eval("injectReleasesJson(" . _CLW_JsStr(Json) . "," . _CLW_JsStr(Channel) . ")", Context)
}






; ==========================
; ==========================
; ======= 6/ Helpers =======
; ==========================
; ==========================

_CLW_NewBridgeSessionToken() {
	Guid := Buffer(16, 0)
	if DllCall("ole32\CoCreateGuid", "Ptr", Guid, "Int") != 0
		throw Error("Could not allocate a changelog bridge session GUID")
	Text := Buffer(78, 0)
	if DllCall("ole32\StringFromGUID2", "Ptr", Guid, "Ptr", Text,
			"Int", 39, "Int") <= 0
		throw Error("Could not format the changelog bridge session GUID")
	return StrLower(RegExReplace(StrGet(Text.Ptr, "UTF-16"), "[{}-]"))
}

_CLW_BridgeSourceMatches(Args, ExpectedSource) {
	if !(ExpectedSource is String) || ExpectedSource == ""
		return false
	try Source := Args.Source
	catch {
		return false
	}
	return (Source is String) && Source == ExpectedSource
}

_CLW_BridgeSessionIsCurrent(ExpectedWindowEpoch, ExpectedSession) {
	global _CLW_WindowEpoch, _CLW_BridgeSessionToken
	PreviousCritical := Critical("On")
	try {
		return Type(ExpectedWindowEpoch) == "Integer"
			&& ExpectedWindowEpoch == _CLW_WindowEpoch
			&& ExpectedSession is String
			&& ExpectedSession != ""
			&& ExpectedSession == _CLW_BridgeSessionToken
	} finally {
		Critical(PreviousCritical)
	}
}

_CLW_ReportRejectedBridgeMessage() {
	global _CLW_BridgeRejectionReported
	ShouldLog := false
	PreviousCritical := Critical("On")
	try {
		if !_CLW_BridgeRejectionReported {
			_CLW_BridgeRejectionReported := true
			ShouldLog := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	if ShouldLog
		try LoggerWarn("Changelog", "Rejected a bridge message with invalid document/session provenance.")
}

/**
 * Starts a distinct WebView lifetime and cancels any retained HTTP request.
 * @returns {integer} The new window epoch.
 */
_CLW_BeginWindowSession() {
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	global _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	global _CLW_BridgeSessionToken, _CLW_BridgeRejectionReported
	NewSession := _CLW_NewBridgeSessionToken()
	OldRequest := 0
	PreviousCritical := Critical("On")
	try {
		_CLW_WindowEpoch += 1
		_CLW_RequestEpoch += 1
		OldRequest := _CLW_ActiveRequest
		_CLW_ActiveRequest := 0
		_CLW_ActiveRequestEpoch := 0
		_CLW_BridgeSessionToken := NewSession
		_CLW_BridgeRejectionReported := false
		WindowEpoch := _CLW_WindowEpoch
	} finally {
		Critical(PreviousCritical)
	}
	_CLW_AbortRequest(OldRequest)
	return WindowEpoch
}

/**
 * Invalidates all work owned by the closing WebView session.
 */
_CLW_InvalidateWindowSession() {
	_CLW_BeginWindowSession()
}

/**
 * Allocates immutable provenance for one channel request and aborts its
 * superseded predecessor outside Critical.
 * @param {string} Channel - "main" or "dev".
 * @returns {object} Bound window/request epochs and channel.
 */
_CLW_BeginFetchRequest(Channel, Request := unset, ExpectedWindowEpoch := 0) {
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	global _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if !IsSet(Request)
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if !_Updater_RequestContextValid(Request)
		throw TypeError("Invalid changelog updater request provenance")
	OldRequest := 0
	PreviousCritical := Critical("On")
	try {
		if ExpectedWindowEpoch && ExpectedWindowEpoch != _CLW_WindowEpoch
			return 0
		_CLW_RequestEpoch += 1
		OldRequest := _CLW_ActiveRequest
		_CLW_ActiveRequest := 0
		_CLW_ActiveRequestEpoch := 0
		Context := {
			WindowEpoch: _CLW_WindowEpoch,
			RequestEpoch: _CLW_RequestEpoch,
			Channel: Channel,
			Request: Request,
			Stage: "api",
			ApiFailure: "",
			ApiStatus: 0
		}
	} finally {
		Critical(PreviousCritical)
	}
	_CLW_AbortRequest(OldRequest)
	return Context
}

_CLW_RequestIsCurrent(Context) {
	if (!IsObject(Context) or !Context.HasProp("Request")
			or !_Updater_RequestMayPublish(Context.Request))
		return false
	return _CLW_RequestEpochIsCurrent(Context)
}

_CLW_ScriptWorkIsCurrent(Work) {
	if !IsObject(Work)
		return false
	if (Work.HasProp("Request") and IsObject(Work.Request)
			and !_Updater_RequestMayPublish(Work.Request))
		return false
	return _CLW_ScriptWorkEpochIsCurrent(Work)
}

; Epoch-only predicates are safe under a caller's short Critical transaction.
; Pause terminals and logging stay in the side-effecting wrappers above.
_CLW_RequestEpochIsCurrent(Context) {
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	if (!IsObject(Context)
			or !Context.HasProp("WindowEpoch")
			or !Context.HasProp("RequestEpoch"))
		return false
	return Context.WindowEpoch == _CLW_WindowEpoch
		&& Context.RequestEpoch == _CLW_RequestEpoch
}

_CLW_ScriptWorkEpochIsCurrent(Work) {
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	if (!IsObject(Work)
			or !Work.HasProp("WindowEpoch")
			or !Work.HasProp("RequestEpoch"))
		return false
	if (Work.WindowEpoch != _CLW_WindowEpoch)
		return false
	return Work.RequestEpoch == 0 || Work.RequestEpoch == _CLW_RequestEpoch
}

_CLW_RegisterActiveRequest(Context, Request) {
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	global _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	PreviousCritical := Critical("On")
	try {
		if (Context.WindowEpoch != _CLW_WindowEpoch
				|| Context.RequestEpoch != _CLW_RequestEpoch)
			return false
		_CLW_ActiveRequest := Request
		_CLW_ActiveRequestEpoch := Context.RequestEpoch
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

_CLW_ReleaseActiveRequest(Context) {
	global _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	PreviousCritical := Critical("On")
	try {
		if (IsObject(Context) && _CLW_ActiveRequestEpoch == Context.RequestEpoch) {
			_CLW_ActiveRequest := 0
			_CLW_ActiveRequestEpoch := 0
		}
	} finally {
		Critical(PreviousCritical)
	}
}

_CLW_AbortRequest(Request) {
	if IsObject(Request)
		try Request.Abort()
}

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
	return JsonStringLiteral(s)
}

/**
 * Resets all module-level state after window close.
 */
_CLW_Reset() {
	global _CLW_Gui, _CLW_WebView, _CLW_Controller, _CLW_MsgSub, _CLW_Ready, _CLW_Queue, _CLW_ResetDone
	global _CLW_Request
	; Close and Escape are wired to the same handler and Controller.Close() pumps
	; messages, so a second dispatch can re-enter this function while the first
	; teardown is still in flight. Short-circuit instead of running the release +
	; Close sequence twice against a controller that is already going away.
	if _CLW_ResetDone
		return
	_CLW_ResetDone := true
	; Invalidate request and script provenance before releasing the controller.
	; Abort is performed outside the helper's short Critical transaction.
	_CLW_InvalidateWindowSession()
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
	_CLW_Request    := unset
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
