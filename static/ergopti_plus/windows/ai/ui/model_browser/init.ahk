; ai/ui/model_browser/init.ahk

; ==============================================================================
; MODULE: LLM Model Browser
; DESCRIPTION:
; Visual model browser with rich per-model specs (parameters, RAM footprint,
; speed, type). Replaces the "flat list of Ollama tags" picker for users who
; want to compare models side by side before picking one. Mirrors the HS
; ui/menu/menu_llm/models_manager visual catalogue so both drivers expose
; the same level of metadata at selection time.
;
; FEATURES & RATIONALE:
; 1. Catalogue-first — the list comes from the shared models.json (not from
;    ``ollama list``), so the user can survey models they have not installed
;    yet and decide based on specs. Each row states whether it is already on
;    disk.
; 2. One shared page — the sortable, filterable table is the shared web page
;    _shared/ui/model_browser/index.html, identical to the macOS browser. It
;    has no native substitute: without a usable WebView2 the opening refuses
;    with the one recovery message (maintainer decision 2026-11-21).
; 3. Selection = the menu's path — a picked row flows through the same
;    ``LLM_Menu_SetModel`` path as the menu picker, so the deps checker is
;    triggered when the user picks something not yet installed. No special-
;    case install flow lives in this file.
; ==============================================================================

#Include %A_LineFile%\..\..\..\..\_generated\identifiers.ahk

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Public Entry Point =======
; =====================================
; =====================================

/**
 * Opens (or brings forward) the shared web model browser. Without a usable
 * WebView2 nothing opens: the user gets the one localized refusal instead.
 *
 * @returns {Gui|Integer} The browser window, or 0 when nothing opened.
 */
LLM_ModelBrowser_Show() {
	global _LLM_MBW_SessionEpoch, _LLM_MBW_ResetDone, _LLM_MBW_Gui
	if !WebView_RequireAvailable("model browser")
		return 0
	web := "", RefusalEpoch := 0, Failure := ""
	try web := _LLM_ModelBrowser_ShowWeb(&RefusalEpoch)
	catch as Err
		Failure := Err.Message
	if IsObject(web)
		return web
	; Error reporting and failed-startup cleanup can both admit B. This old
	; attempt stays silent over its newer web session: B owns the outcome.
	if RefusalEpoch && (_LLM_MBW_SessionEpoch != RefusalEpoch
			|| !_LLM_MBW_ResetDone || IsSet(_LLM_MBW_Gui)) {
		if Failure != ""
			try LoggerError("LLM.browser", "WebView2 model browser failed: {1} — a newer opening owns the browser.", Failure)
		return 0
	}
	WebView_RefuseUnavailable("model browser",
		Failure != "" ? "the browser failed: " . Failure : "WebView2 could not create the browser")
	return 0
}





; ====================================
; ====================================
; ======= 2/ Catalogue Helpers =======
; ====================================
; ====================================

/**
 * Heuristic family grouping by name prefix. We do not have a "family"
 * field in the AHK model index, so reuse the model's display-name prefix
 * (everything before the first digit run) as the family — produces the
 * intuitive groups: "Qwen3-Coder-30B" → "Qwen3-Coder", "Gemma-3n-E4B" →
 * "Gemma-3n", "Llama-3.2-1B" → "Llama-3.2".
 */
_LLM_ModelBrowser_GuessFamily(name) {
	if RegExMatch(name, "^(.*?)-?\d", &m) and m.Pos == 1
		return RTrim(m[1], "-")
	return name
}

/**
 * Returns the asynchronously maintained installed-tag snapshot. A missing or
 * stale snapshot is intentionally shown as "available" until the existing
 * async menu probe refreshes it; opening or filtering a browser must never
 * initiate synchronous HTTP on the AHK message/input thread.
 */
_LLM_ModelBrowser_GetInstalledTags() {
	return _LLM_GetInstalledTagsCached()
}




; ==========================================
; ==========================================
; ======= 3/ WebView2 Shared Browser ========
; ==========================================
; ==========================================

; Module-level state of the one WebView2 browser window.
global _LLM_MBW_Gui        := unset
global _LLM_MBW_WebView    := unset
global _LLM_MBW_Controller := unset
global _LLM_MBW_MsgSub     := unset
global _LLM_MBW_Ready      := false
global _LLM_MBW_Queue      := []
; Monotonic owner token for every WebView instance. Deferred timers carry the
; value captured at scheduling time and cannot resolve a successor WebView.
global _LLM_MBW_SessionEpoch := 0

; True once _LLM_MBW_Reset() has torn the controller down. Close, Escape and the
; deferred _LLM_MBW_ApplyModel all reach the same teardown, and Controller.Close()
; pumps messages — so a second trigger dispatched during that pump would re-enter
; Reset and close a controller that is already mid-teardown. Same guard as every
; other WebView2 host in the driver.
global _LLM_MBW_ResetDone  := false
global _LLM_MBW_SubscriptionOwner := 0
global _LLM_MBW_RetiredHosts := []

; Virtual host mapped to _SharedDir so the document and its relative assets
; and the locale fetch resolve over https:// -- file:// is an opaque origin
; and the chrome.webview JS->AHK channel does not reliably deliver from it
; (see docs/memory project-webview2-bridge-gotchas).
global LLM_MBW_VHOST := "ergopti.modelbrowser"   ; -> _SharedDir
; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW.
global LLM_MBW_HOST_ACCESS_ALLOW := 1

/**
 * Builds (or brings forward) the shared web model browser in a WebView2 window.
 * Returns the Gui on success, or "" to ask the caller to refuse the opening
 * with the WebView2 message (e.g. WebView2 create failed).
 * @returns {Gui|string}
 */
_LLM_ModelBrowser_ShowWeb(&RefusalEpoch := unset) {
	global _LLM_MBW_Gui, _LLM_MBW_Controller, _LLM_MBW_WebView, _LLM_MBW_MsgSub
	global _LLM_MBW_Ready, _LLM_MBW_Queue, _LLM_MBW_ResetDone, _LLM_MBW_SessionEpoch
	global _VendorDir, _SharedDir, _I18nLocale

	RefusalEpoch := 0
	EntryEpoch := _LLM_MBW_SessionEpoch
	_LLM_MBW_RetryRetiredHosts()
	if _LLM_MBW_SessionEpoch != EntryEpoch {
		; Retirement consumed this older opening; forbid its refusal too.
		RefusalEpoch := -1
		return 0
	}
	if IsSet(_LLM_MBW_Gui) {
		Window := _LLM_MBW_Gui, SessionEpoch := _LLM_MBW_SessionEpoch
		WMPresentWindow(Window)
		if IsSet(_LLM_MBW_Controller)
			WebView_TakeFocus(_LLM_MBW_Controller)
		; A page still loading gets its catalogue from _LLM_MBW_OnPageReady, as
		; LLM_ModelBrowser_Refresh assumes: injecting here would only queue a
		; payload the ready handler rebuilds, and a failure to build it would make
		; the caller refuse an opening whose page is already open.
		if _LLM_MBW_Ready && _LLM_MBW_StartupCurrent(SessionEpoch, Window)
			_LLM_MBW_InjectCatalogue(SessionEpoch)
		return Window
	}
	PreviousCritical := Critical("On")
	try {
		_LLM_MBW_SessionEpoch += 1
		SessionEpoch := _LLM_MBW_SessionEpoch
		_LLM_MBW_ResetDone := false
		_LLM_MBW_Ready := false
		_LLM_MBW_Queue := []
	} finally Critical(PreviousCritical)

	g := Gui_Create("+Resize +MinSize780x460", t("model_browser.window_title"))
	Installed := false, FactoryFailed := false, ResetForRefusal := false, Host := 0
	try {
		if !_LLM_MBW_StartupCurrent(SessionEpoch)
			return g
		g.BackColor := "0x1e1e1e"
		g.MarginX := 0
		g.MarginY := 0
		Placeholder := g.Add("Text", "x0 y0 w900 h580", "")
		g.OnEvent("Close", _LLM_MBW_SessionCall.Bind(SessionEpoch, _LLM_MBW_OnClose))
		g.OnEvent("Escape", _LLM_MBW_SessionCall.Bind(SessionEpoch, _LLM_MBW_OnClose))
		g.OnEvent("Size", _LLM_MBW_SessionCall.Bind(SessionEpoch, _LLM_MBW_OnResize))
		; Show pumps native Close. Publish before that call, never after it.
		PreviousCritical := Critical("On")
		try {
			if !_LLM_MBW_StartupCurrent(SessionEpoch)
				return g
			_LLM_MBW_Gui := g
		} finally Critical(PreviousCritical)
		g.Show("w900 h580")
		if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
			return g

		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		try {
			Environment := WebView_SharedEnvironment(loader)
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			Controller := WebView2.create(Placeholder.Hwnd, , Environment)
		} catch as Err {
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			try LoggerError("LLM.browser", "WebView2 create failed: {1}.", Err.Message)
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			FactoryFailed := true
		}
		if !FactoryFailed {
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			View := Controller.CoreWebView2
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			Host := _LLM_MBW_BeginSubscriptions(SessionEpoch, g, Controller, View)
			if !IsObject(Host)
				return g
			try {
				s := View.Settings
				for Setting in ["AreDevToolsEnabled", "AreDefaultContextMenusEnabled", "IsStatusBarEnabled",
					"AreBrowserAcceleratorKeysEnabled", "IsSwipeNavigationEnabled"] {
					if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
						return g
					s.%Setting% := false
				}
			}
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			if !_LLM_MBW_Subscribe(Host, _LLM_MBW_OnWebMessage.Bind(SessionEpoch))
				return g
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			try View.SetVirtualHostNameToFolderMapping(LLM_MBW_VHOST, _SharedDir, LLM_MBW_HOST_ACCESS_ALLOW)
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			seed := "window.__i18n_base='" . _LLM_MBW_LocalesUrl() . "';"
				. "window._i18n_locale='" . _I18nLocale . "';"
				. ReadingPrefs_SeedScript()
			ReadingPrefs_Track(View)
			try View.AddScriptToExecuteOnDocumentCreated(seed)
			PreviousCritical := Critical("On")
			try {
				if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
					return g
				_LLM_MBW_Controller := Controller
				_LLM_MBW_WebView := View
				_LLM_MBW_MsgSub := Host.message
				Installed := true
			} finally Critical(PreviousCritical)
			try View.Navigate(_LLM_MBW_HtmlUrl())
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			try Controller.Fill()
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			WebView_TakeFocus(Controller)
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			SetTimer(_LLM_MBW_SafetyFlush.Bind(SessionEpoch), -TimingsGet("ui", "webview_page_safety_flush_ms"))
			Script := _LLM_MBW_I18nApplyScript()
			_LLM_MBW_Eval(Script, SessionEpoch)
			return g
		}
	} finally {
		if !Installed {
			; Only this frame's captured resources retire, even if Close reopens.
			ResetForRefusal := _LLM_MBW_Reset(SessionEpoch, g)
			if IsObject(Host) {
				_LLM_MBW_RetireSubscriptionHost(Host)
			} else {
				if IsSet(Controller)
					try Controller.Close()
				try g.Destroy()
			}
			; Only this frame's exact detach ACK admits the refusal. A Close
			; consumed before Reset must remain terminal even at epoch + 1.
			; The public catch rechecks this old token after its own logger.
			RefusalEpoch := ResetForRefusal ? SessionEpoch + 1 : -1
		}
	}
	; A retired constructor is handled. Only a still-owned factory failure
	; may ask the public entry to refuse with the WebView2 message.
	return FactoryFailed && ResetForRefusal && _LLM_MBW_SessionEpoch == SessionEpoch + 1
		&& !IsSet(_LLM_MBW_Gui) ? "" : g
}

; A subscription is returned after add_Event has pumped native messages. The
; exact host retains its HWND/controller until that returned handle is released.
_LLM_MBW_BeginSubscriptions(Epoch, Window, Controller, View) {
	global _LLM_MBW_SubscriptionOwner
	Host := {epoch: Epoch, gui: Window, controller: Controller, view: View, message: 0, in_flight: false, retired: false, closing: false, closed: false}
	PreviousCritical := Critical("On")
	try {
		if !_LLM_MBW_StartupCurrent(Epoch, Window) || IsObject(_LLM_MBW_SubscriptionOwner)
			return 0
		_LLM_MBW_SubscriptionOwner := Host
		return Host
	} finally Critical(PreviousCritical)
}

_LLM_MBW_Subscribe(Host, Handler) {
	global _LLM_MBW_SubscriptionOwner
	PreviousCritical := Critical("On")
	try {
		if Host.retired || _LLM_MBW_SubscriptionOwner != Host
				|| !_LLM_MBW_StartupCurrent(Host.epoch, Host.gui)
			return false
		Host.in_flight := true
	} finally Critical(PreviousCritical)
	Subscription := 0, Failed := false, FailureType := "", FailureValue := 0
	try {
		Subscription := Host.view.WebMessageReceived(Handler)
	} catch Any as Failure {
		Failed := true, FailureType := Type(Failure), FailureValue := Failure
	} finally {
		PreviousCritical := Critical("On")
		try {
			Host.message := Subscription
			Subscription := 0
			Host.in_flight := false
			Current := !Host.retired && _LLM_MBW_SubscriptionOwner == Host
				&& _LLM_MBW_StartupCurrent(Host.epoch, Host.gui)
		} finally Critical(PreviousCritical)
	}
	; Preserve the original caller's current-startup error policy (including
	; the public model browser's WebView2 refusal). A retired constructor must
	; consume its late failure instead of reopening a canceled or newer UI.
	if Failed && Current && !Host.retired
		throw FailureValue
	if Host.retired
		_LLM_MBW_RetryRetiredHosts()
	if Failed
		try LoggerError("LLM.browser", "Browser subscription failed (error_type={1}).", FailureType)
	return !Failed && Current && !Host.retired
}

_LLM_MBW_RetireSubscriptionHost(Host) {
	global _LLM_MBW_RetiredHosts
	PreviousCritical := Critical("On")
	try {
		if !IsObject(Host.gui)
			return
		Host.retired := true
		Found := false
		for Pending in _LLM_MBW_RetiredHosts
			if Pending == Host
				Found := true
		if !Found
			_LLM_MBW_RetiredHosts.Push(Host)
	} finally Critical(PreviousCritical)
	; Hide can pump a replacement; all subsequent operations use this old record.
	try Host.gui.Hide()
	_LLM_MBW_RetryRetiredHosts()
}

_LLM_MBW_RetryRetiredHosts() {
	global _LLM_MBW_RetiredHosts
	PreviousCritical := Critical("On")
	try Pending := _LLM_MBW_RetiredHosts.Clone()
	finally Critical(PreviousCritical)
	for Host in Pending {
		PreviousCritical := Critical("On")
		try {
			if Host.in_flight || Host.closing
				continue
			Host.closing := true
		} finally Critical(PreviousCritical)
		Settled := false
		try {
			Host.message := 0
			if !Host.closed {
				Host.controller.Close()
				Host.closed := true
			}
			Host.gui.Destroy()
			Host.gui := 0, Host.controller := 0, Host.view := 0
			Settled := true
		} catch Any as Failure {
			try LoggerWarn("LLM.browser", "Browser retirement remains pending (error_type={1}).", Type(Failure))
		} finally {
			PreviousCritical := Critical("On")
			try {
				Host.closing := false
				if Settled {
					Count := _LLM_MBW_RetiredHosts.Length
					Loop Count {
						Index := Count - A_Index + 1
						if _LLM_MBW_RetiredHosts[Index] == Host
							_LLM_MBW_RetiredHosts.RemoveAt(Index)
					}
				}
			} finally Critical(PreviousCritical)
		}
	}
}

_LLM_MBW_StartupCurrent(SessionEpoch, Window := unset) {
	global _LLM_MBW_SessionEpoch, _LLM_MBW_ResetDone, _LLM_MBW_Gui
	return SessionEpoch == _LLM_MBW_SessionEpoch && !_LLM_MBW_ResetDone
		&& (!IsSet(Window) || (IsSet(_LLM_MBW_Gui) && _LLM_MBW_Gui == Window))
}

_LLM_MBW_SessionCall(SessionEpoch, Callback, Params*) {
	if _LLM_MBW_StartupCurrent(SessionEpoch)
		return Callback.Call(Params*)
}

/**
 * Builds the selector payload and injects it via injectModels(). The rows come
 * from the shared model index (projected field by field as
 * _shared/ai/engine/local_servers/model_catalogue.lua projects them on macOS and Linux, pinned
 * by tools/test/test-model-selector-page.cjs), the installed-tag cache, the API
 * entries and the local servers' rows. Each row's actions are the tray's own
 * closures, held in _LLM_MBW_Rows for the session; the page names a row, never
 * a command.
 *
 * The catalogue is STATIC (_shared/ai/data/models.json), so it is ALWAYS
 * injected in full. The installed state reads the asynchronously maintained tag
 * cache: InjectCatalogue runs inside the WebView2 WebMessageReceived (STA COM)
 * callback, and a synchronous /api/tags WinHttp probe against a down daemon
 * stalls that callback so the injectModels() ExecuteScript never fires.
 */
_LLM_MBW_InjectCatalogue(ExpectedEpoch := unset) {
	js := "injectModels(" . _LLM_MBW_BuildPayload() . ")"
	if IsSet(ExpectedEpoch)
		_LLM_MBW_Eval(js, ExpectedEpoch)
	else
		_LLM_MBW_Eval(js)
}

/** Re-sends the payload to an open page after a menu rebuild changed its state. */
LLM_ModelBrowser_Refresh() {
	global _LLM_MBW_Gui, _LLM_MBW_SessionEpoch, _LLM_MBW_Ready
	if !IsSet(_LLM_MBW_Gui) || !_LLM_MBW_Ready
		return false
	_LLM_MBW_InjectCatalogue(_LLM_MBW_SessionEpoch)
	return true
}

; The rows of the payload last injected, by "<backend>`n<name>", with their actions.
global _LLM_MBW_Rows := Map()
; The group tools of that payload, by "<backend>`n<id>".
global _LLM_MBW_Tools := Map()
; The provider model listing of each API entry for the open page, by entry id
; (LLM_ApiListingPlan states), and the entries still to ask, one at a time.
global _LLM_MBW_Listings := Map()
global _LLM_MBW_ListingQueue := []
global _LLM_MBW_ListingEpoch := 0

/**
 * Asks each API entry's provider for its models once per page session, one
 * request at a time, and re-sends the payload after each answer. Only an entry
 * whose key its endpoint accepts and whose provider lists models is asked; the
 * key stays in the request (api_remote.ahk), never in the payload or a log.
 * @param {Integer} ExpectedEpoch The page session.
 */
_LLM_MBW_StartListings(ExpectedEpoch) {
	global _LLM_Menu, _LLM_MBW_Listings, _LLM_MBW_ListingQueue, _LLM_MBW_ListingEpoch
	global LLM_API_LISTING_MAX_ENTRIES, LLM_LOCAL_API_SERVERS
	if (_LLM_MBW_ListingEpoch == ExpectedEpoch)
		return false
	_LLM_MBW_ListingEpoch := ExpectedEpoch
	_LLM_MBW_Listings := Map(), _LLM_MBW_ListingQueue := []
	for Entry in _LLM_Menu.Get("api_entries", []) {
		if (_LLM_MBW_ListingQueue.Length >= LLM_API_LISTING_MAX_ENTRIES)
			break
		Id := _LLM_MenuApiEntryGet(Entry, "Id", ""), ProviderId := _LLM_MenuApiEntryGet(Entry, "Provider", "")
		if (Id == "" || !LLM_ApiListingSupported(LLM_RemoteProviderFormat(ProviderId))
				|| LLM_ApiToken_Unusable(_LLM_MenuApiEntryGet(Entry, "Token", ""))
				|| !LocalServerAuthEntryTokenAllowed(ProviderId, _LLM_MenuApiEntryGet(Entry, "Token", ""),
					_LLM_MenuApiEntryGet(Entry, "BaseUrl", ""), LLM_LOCAL_API_SERVERS))
			continue
		_LLM_MBW_Listings[Id] := Map("state", "pending")
		_LLM_MBW_ListingQueue.Push(Entry)
	}
	LoggerInfo("LLM.browser", "Model selector page lists the models of {1} API entry(ies).", _LLM_MBW_ListingQueue.Length)
	return _LLM_MBW_NextListing(ExpectedEpoch)
}

; The percentage of each running menu pull, by Ollama tag, for the open page.
global _LLM_MBW_PullPercents := Map()

/**
 * Shows a menu pull's percentage on the open page's row of that tag, and keeps
 * it for the next payload; "" clears it once the pull ended.
 * @param {String} Tag Ollama tag being pulled.
 * @param {Integer|String} Percent 0-100, or "".
 * @returns {Boolean} True when the page was told.
 */
LLM_ModelBrowser_PullPercent(Tag, Percent) {
	global _LLM_MBW_PullPercents, _LLM_MBW_Rows, _LLM_MBW_Ready, _LLM_MBW_Gui, _LLM_MBW_SessionEpoch
	if !(Tag is String) || Tag == ""
		return false
	if (Percent == "") {
		if _LLM_MBW_PullPercents.Has(Tag)
			_LLM_MBW_PullPercents.Delete(Tag)
		return false
	}
	_LLM_MBW_PullPercents[Tag] := Percent
	if !IsSet(_LLM_MBW_Gui) || !_LLM_MBW_Ready
		return false
	for Key, Row in _LLM_MBW_Rows {
		if (Row["backend"] == "ollama" && Row.Has("tag") && StrLower(Row["tag"]) == StrLower(Tag)) {
			_LLM_MBW_Eval("injectProgress({backend:" . JsonStringLiteral("ollama") . ",name:" . JsonStringLiteral(Row["name"])
				. ",percent:" . Integer(Percent) . "})", _LLM_MBW_SessionEpoch)
			return true
		}
	}
	return false
}

; Sends the next queued listing of this page session.
_LLM_MBW_NextListing(ExpectedEpoch) {
	global _LLM_MBW_ListingQueue, _LLM_MBW_SessionEpoch
	if (ExpectedEpoch != _LLM_MBW_SessionEpoch || A_IsSuspended || _LLM_MBW_ListingQueue.Length == 0)
		return false
	Entry := _LLM_MBW_ListingQueue.RemoveAt(1)
	Id := _LLM_MenuApiEntryGet(Entry, "Id", "")
	try {
		LLM_RemoteListModels_Async(Entry, _LLM_MBW_ListingDone.Bind(ExpectedEpoch, Id))
	} catch as Err {
		LoggerError("LLM.browser", "Remote model listing dispatch failed: {1}.", Err.Message)
		_LLM_MBW_ListingDone(ExpectedEpoch, Id, Map("state", "failed", "reason", "unavailable"))
	}
	return true
}

; Records one entry's listing state, refreshes the page, asks the next entry.
_LLM_MBW_ListingDone(ExpectedEpoch, EntryId, Listing) {
	global _LLM_MBW_Listings, _LLM_MBW_SessionEpoch
	if (ExpectedEpoch != _LLM_MBW_SessionEpoch)
		return false
	_LLM_MBW_Listings[EntryId] := Listing is Map ? Listing : Map("state", "failed", "reason", "unavailable")
	LLM_ModelBrowser_Refresh()
	return _LLM_MBW_NextListing(ExpectedEpoch)
}

/**
 * The selector payload as a JSON object literal. Ollama is the local backend,
 * MLX is listed greyed with its reason (it needs Apple silicon), and the API
 * group holds the saved entries and the local servers that answer.
 * @returns {String}
 */
_LLM_MBW_BuildPayload() {
	global _LLM_Menu, _LLM_MBW_Rows, _LLM_MBW_Tools, _LLM_MBW_Listings
	Rows := Map(), Tools := Map(), Models := []
	Backend := _LLM_Menu.Get("backend", "ollama")
	Active := _LLM_Menu_ModelDisplayText()

	; ===== Ollama =====
	OllamaFailed := IsSet(LLM_Deps_HasFailed) && LLM_Deps_HasFailed()
	Installed := Map()
	for Tag in _LLM_ModelBrowser_GetInstalledTags()
		Installed[StrLower(Tag)] := Tag
	; The page's "Install Ollama" button posts the group action "install".
	Tools["ollama`ninstall"] := (*) => _LLM_MBW_InstallOllama()
	OllamaTools := []
	PortDisplay := _LLM_Menu.Has("ollama_port") ? _LLM_Menu["ollama_port"] : _LLM_DefaultFor("llm_ollama_owned_port")
	OllamaTools.Push(_LLM_MBW_Tool(Tools, "ollama", "ollama_port",
		StrReplace(t("menu.llm.ollama_port_label"), "%s", "" . PortDisplay), (*) => LLM_Menu_PromptOllamaPort()))
	DefaultPort := _LLM_DefaultFor("llm_ollama_owned_port")
	if !(PortDisplay = DefaultPort)
		OllamaTools.Push(_LLM_MBW_Tool(Tools, "ollama", "ollama_port_reset",
			Trim(StrReplace(t("menu.llm.reset_label"), "%s", "" . DefaultPort)),
			(*) => LLM_Menu_ResetOllamaPort(DefaultPort)))
	DefaultModel := _LLM_DefaultFor("llm_model", "")
	Seen := Map()
	for Name, Info in LLM_GetModelIndex() {
		Tag := (Info is Map && Info.Has("ollama")) ? Info["ollama"] : ""
		if (Tag == "")
			continue
		IsInstalled := Installed.Has(StrLower(Tag))
		if IsInstalled
			Seen[StrLower(Tag)] := true
		Row := _LLM_MBW_LocalRow(Name, Tag, Info, IsInstalled, Name == DefaultModel, false, Backend == "ollama")
		Models.Push(Row["json"])
		Rows["ollama`n" . Name] := Row
	}
	; Installed tags outside the catalogue are the user's own models.
	for Lower, Tag in Installed {
		if Seen.Has(Lower)
			continue
		Row := _LLM_MBW_LocalRow(Tag, Tag, Map(), true, false, true, Backend == "ollama")
		Models.Push(Row["json"])
		Rows["ollama`n" . Tag] := Row
	}

	; ===== API =====
	ApiTools := [_LLM_MBW_Tool(Tools, "api", "add_api", t("menu.llm.api_add_entry"), (*) => _LLM_Menu_PromptApiEntry(""))]
	_LLM_Menu_ApiEntryPageRows(Rows, Models, _LLM_MBW_Listings)
	_LLM_MBW_LocalServerRows(Rows, Tools, Models, ApiTools)

	; A config.toml that refuses writes greys every backend with that cause.
	; Until Ollama is installed (its owned runtime on disk, or a server that
	; answered) its rows stay greyed and its group offers the install.
	Blocked := _LLM_Menu_ConfigBlockReason()
	; Like LLM_Deps_HasFailed above, the bootstrap owner is optional in the
	; page-only children that load this owner without ollama_deps_checker.ahk.
	OllamaInstalled := !OllamaFailed && ((IsSet(LLM_Deps_IsReady) && LLM_Deps_IsReady())
		|| Installed.Count > 0 || _LLM_MBW_OllamaRuntimePresent())
	OllamaReason := Blocked != "" ? Blocked : (OllamaInstalled ? "" : "model_browser.reason_ollama_missing")
	OllamaInstall := _LLM_MBW_OllamaInstallJson(Blocked, OllamaInstalled)
	MlxInstall :="{state:" . JsonStringLiteral("unsupported") . ",reason_key:"
		. JsonStringLiteral("model_browser.reason_mlx_unsupported_os") . "}"
	Backends := _LLM_MBW_BackendJson("ollama", OllamaReason == "", OllamaReason, OllamaTools, OllamaReason == "", OllamaInstall)
		. "," . _LLM_MBW_BackendJson("mlx", false, "model_browser.reason_mlx_unsupported_os", [], false, MlxInstall)
		. "," . _LLM_MBW_BackendJson("api", Blocked == "", Blocked, ApiTools, false)
	ModelsJson := ""
	for Json in Models
		ModelsJson .= (ModelsJson == "" ? "" : ",") . Json
	_LLM_MBW_Rows := Rows
	_LLM_MBW_Tools := Tools
	return "{backend:" . JsonStringLiteral(Backend) . ",active:" . JsonStringLiteral(Active)
		. ",capabilities:{disable:true},backends:[" . Backends . "],models:[" . ModelsJson . "]}"
}

/**
 * One local (Ollama) row: the catalogue fields the page's columns read. The
 * tray's delete runs only on the Ollama backend, so the page offers it there.
 */
; The public page of a model tag in the Ollama library.
_LLM_ModelLibraryUrl(Tag) {
	return "https://" . Identifiers.Hosts.OLLAMA . "/library/" . Tag
}

_LLM_MBW_LocalRow(Name, Tag, Info, IsInstalled, IsDefault, Custom, Deletable) {
	global _LLM_MBW_PullPercents
	Params := Info.Has("params_b") ? Info["params_b"] : 0
	ActiveB := Info.Has("active_b") ? Info["active_b"] : 0
	if (ActiveB <= 0)
		ActiveB := Params
	Url := Custom ? "" : _LLM_ModelLibraryUrl(Tag)
	Json := "{backend:" . JsonStringLiteral("ollama")
		. ",name:" . JsonStringLiteral(Name)
		. ",runtime_name:" . JsonStringLiteral(Tag)
		. ",family:" . JsonStringLiteral(Custom ? "" : _LLM_ModelBrowser_GuessFamily(Name))
		. ",provider:" . JsonStringLiteral(Custom || !Info.Has("provider") ? "" : Info["provider"])
		. ",params_b:" . _LLM_MBW_Num(Params)
		. ",active_b:" . _LLM_MBW_Num(ActiveB)
		. ",is_moe:" . ((ActiveB > 0 && ActiveB < Params) ? "true" : "false")
		. ",ram_gb:" . _LLM_MBW_Num(Info.Has("ram_gb") ? Info["ram_gb"] : 0)
		. ",disk_gb:" . _LLM_MBW_Num(Info.Has("disk_gb") ? Info["disk_gb"] : 0)
		. ",type:" . JsonStringLiteral(Info.Has("type") ? Info["type"] : "chat")
		. ",installed:" . (IsInstalled ? "true" : "false")
		. ",is_default:" . (IsDefault ? "true" : "false")
		. ",custom:" . (Custom ? "true" : "false")
		. ",deletable:" . (Deletable ? "true" : "false")
		. (_LLM_MBW_PullPercents.Has(Tag) ? ",pending:" . JsonStringLiteral("download")
			. ",progress:" . Integer(_LLM_MBW_PullPercents[Tag]) : "")
		. ",url:" . JsonStringLiteral(Url) . "}"
	return Map("backend", "ollama", "name", Name, "tag", Tag, "installed", IsInstalled, "custom", Custom,
		"url", Url, "json", Json, "row_actions", Map())
}

/** Registers one group tool and returns its JSON. */
_LLM_MBW_Tool(Tools, Backend, Id, Text, Action) {
	Tools[Backend . "`n" . Id] := Action
	return "{id:" . JsonStringLiteral(Id) . ",text:" . JsonStringLiteral(Text) . "}"
}

/**
 * Whether Ergopti's own Ollama runtime is published on this computer: a
 * directory lookup under the managed root (a version folder holding
 * ollama.exe), never a process launch. The bootstrap still verifies it.
 * @returns {Boolean}
 */
_LLM_MBW_OllamaRuntimePresent() {
	return LLM_OllamaManagedRuntimePresent()
}

/**
 * The page's "Install Ollama" button state: running while the owned
 * bootstrap runs, installed once Ollama can run, else available.
 * @param {Boolean} Installed
 * @returns {String}
 */
_LLM_MBW_OllamaInstallState(Installed) {
	if IsSet(LLM_Deps_IsChecking) && LLM_Deps_IsChecking()
		return "running"
	return Installed ? "installed" : "available"
}

; Why the last install click did not start, as a locale key the group shows.
global _LLM_MBW_InstallRefusedKey := ""

/**
 * The install state the payload carries: a config.toml refusal or a pause
 * greys the button with that reason, and an offered install names why the
 * last click did not start.
 * @param {String} Blocked The config.toml refusal key, or "".
 * @param {Boolean} Installed
 * @returns {String} A JSON object literal.
 */
_LLM_MBW_OllamaInstallJson(Blocked, Installed) {
	global _LLM_MBW_InstallRefusedKey
	Unsupported := (Key) => "{state:" . JsonStringLiteral("unsupported") . ",reason_key:" . JsonStringLiteral(Key) . "}"
	if (Blocked != "")
		return Unsupported(Blocked)
	State := _LLM_MBW_OllamaInstallState(Installed)
	if (State == "available" && A_IsSuspended)
		return Unsupported("model_browser.install_paused")
	Failed := (State == "available" && _LLM_MBW_InstallRefusedKey != "")
		? ",failed_key:" . JsonStringLiteral(_LLM_MBW_InstallRefusedKey) : ""
	return "{state:" . JsonStringLiteral(State) . Failed . "}"
}

/** One backend entry of the payload, brand and emoji from backends.json. */
_LLM_MBW_BackendJson(Id, Available, ReasonKey, Tools, AddModel, InstallJson := "") {
	Brands := LLM_GetBackendBrands()
	ToolsJson := ""
	for Json in Tools
		ToolsJson .= (ToolsJson == "" ? "" : ",") . Json
	return "{id:" . JsonStringLiteral(Id) . ",brand:" . JsonStringLiteral(Brands[Id]["brand"])
		. ",emoji:" . JsonStringLiteral(Brands[Id]["emoji"]) . ",kind:" . JsonStringLiteral(Brands[Id]["kind"])
		. ",available:" . (Available ? "true" : "false")
		. (ReasonKey != "" ? ",reason_key:" . JsonStringLiteral(ReasonKey) : "")
		. (AddModel ? ",add_model:true" : "")
		. (InstallJson != "" ? ",install:" . InstallJson : "")
		. ",actions:[" . ToolsJson . "]}"
}

/**
 * The local servers that answer, as API rows: one per model they serve, the
 * server's key and address as row actions, the sweep and the other addresses
 * as group tools. The closures are the local-server panel's own.
 */
_LLM_MBW_LocalServerRows(Rows, Tools, Models, ApiTools) {
	KeyLabel := t("menu.llm.local_servers.api_key")
	RescanLabel := t("menu.llm.local_servers.rescan")
	OtherLabel := t("menu.llm.local_servers.other_address")
	for Top in LLM_Menu_LocalServersLiveRows() {
		if !(Top is Map) || Top.Get("separator", false)
			continue
		Label := Top.Get("label", "")
		if (Label == RescanLabel && Top.Has("action")) {
			ApiTools.Push(_LLM_MBW_Tool(Tools, "api", "rescan", Label, Top["action"]))
			continue
		}
		if !Top.Has("items") || !(Top["items"] is Array)
			continue
		if (Label == OtherLabel) {
			for Index, Child in Top["items"]
				if Child is Map && Child.Has("action")
					ApiTools.Push(_LLM_MBW_Tool(Tools, "api", "address_" . Index,
						OtherLabel . " — " . Child.Get("label", ""), Child["action"]))
			continue
		}
		Server := Trim(StrSplit(Label, " 🖥️")[1])
		RowActions := Map(), ActionsJson := "", ModelRows := [], AfterSeparator := false
		for Child in Top["items"] {
			if !(Child is Map)
				continue
			if Child.Get("separator", false) {
				AfterSeparator := true
				continue
			}
			if !Child.Has("action")
				continue
			ChildLabel := Child.Get("label", "")
			if (ChildLabel == KeyLabel || AfterSeparator) {
				ActionId := ChildLabel == KeyLabel ? "set_key" : "address"
				RowActions[ActionId] := Child["action"]
				ActionsJson .= (ActionsJson == "" ? "" : ",") . "{id:" . JsonStringLiteral(ActionId) . ",text:" . JsonStringLiteral(ChildLabel) . "}"
				continue
			}
			ModelRows.Push(Child)
		}
		if ModelRows.Length == 0 {
			Name := Server
			Row := Map("backend", "api", "name", Name, "installed", true, "row_actions", RowActions)
			Row["json"] := "{backend:" . JsonStringLiteral("api") . ",name:" . JsonStringLiteral(Name)
				. ",provider:" . JsonStringLiteral(Server) . ",installed:true,available:false"
				. ",hint_key:" . JsonStringLiteral("model_browser.hint_api_no_key") . ",actions:[" . ActionsJson . "]}"
			Models.Push(Row["json"])
			Rows["api`n" . Name] := Row
			continue
		}
		for Child in ModelRows {
			Name := Server . "/" . Child.Get("label", "")
			Row := Map("backend", "api", "name", Name, "installed", true, "select", Child["action"], "row_actions", RowActions)
			Row["json"] := "{backend:" . JsonStringLiteral("api") . ",name:" . JsonStringLiteral(Name)
				. ",runtime_name:" . JsonStringLiteral(Child.Get("label", "")) . ",provider:" . JsonStringLiteral(Server)
				. ",installed:true,actions:[" . ActionsJson . "]}"
			Models.Push(Row["json"])
			Rows["api`n" . Name] := Row
		}
	}
}

/**
 * The owned Ollama install, from the page's "Install Ollama" button: the click
 * is the consent. It runs the visible bootstrap directly and leaves the backend
 * alone: a backend selection restarts Ollama without its window and never
 * installs it, so with another backend active this click used to do nothing.
 * The page shows it running; its outcome re-sends the payload, which unlocks
 * the Ollama rows once installed.
 * @returns {Boolean} True when the install started.
 */
_LLM_MBW_InstallOllama() {
	global _LLM_Menu, _LLM_MBW_InstallRefusedKey
	; The runtime install starts what serves predictions, so it waits for the
	; resume like the bridge (EDD-1): the page greys its button with
	; model_browser.install_paused, as on macOS, and a click a page painted
	; before the pause still sends is told, never run.
	if A_IsSuspended {
		NotifyPausedRefusal("An Ollama install")
		LLM_ModelBrowser_Refresh()
		return false
	}
	_LLM_MBW_InstallRefusedKey := ""
	try {
		LoggerInfo("LLM.browser", "Installing Ollama from the model selector page.")
		Settled := (*) => LLM_ModelBrowser_Refresh()
		LLM_Deps_CheckAndInstall(_LLM_Menu.Get("model", ""), Settled, Settled)
		LLM_ModelBrowser_Refresh()
		return true
	} catch as Err {
		_LLM_MBW_InstallRefusedKey := "model_browser.install_not_started"
		LoggerError("LLM.browser", "The Ollama install from the page did not start: {1}.", Err.Message)
		LLM_ModelBrowser_Refresh()
		return false
	}
}

/**
 * Evaluates JS in the WebView, queuing it until the page signals "ready".
 * @param {string} Js
 */
_LLM_MBW_Eval(Js, ExpectedEpoch := unset) {
	global _LLM_MBW_WebView, _LLM_MBW_Ready, _LLM_MBW_Queue, _LLM_MBW_SessionEpoch
	EvalCritical := Critical("On")
	try {
		SessionEpoch := _LLM_MBW_SessionEpoch
		if IsSet(ExpectedEpoch) && ExpectedEpoch != SessionEpoch
			return
		if (_LLM_MBW_Ready && IsSet(_LLM_MBW_WebView)) {
			; Run OUTSIDE the current call stack via a one-shot timer. ExecuteScript
			; is ExecuteScriptAsync().await(), which spins a NESTED message loop;
			; calling it synchronously from inside the WebMessageReceived COM
			; callback (as the "ready" handler does) re-enters the STA apartment
			; and wedges further WebView2 message delivery.
			SetTimer(_LLM_MBW_RunScript.Bind(Js, SessionEpoch), -1)
		} else {
			_LLM_MBW_Queue.Push({ Js: Js, Epoch: SessionEpoch })
			if (_LLM_MBW_Queue.Length > 50)
				_LLM_MBW_Queue.RemoveAt(1)
		}
	} finally {
		Critical(EvalCritical)
	}
}

; Executes a queued script on a fresh call stack (scheduled by _LLM_MBW_Eval
; via a -1 timer). Fire-and-forget ExecuteScriptAsync (no .await()) -- we do
; not need the return value, and awaiting it here would reintroduce the same
; nested-message-loop wedge _LLM_MBW_Eval's deferral avoids.
_LLM_MBW_RunScript(Js, ExpectedEpoch) {
	global _LLM_MBW_WebView, _LLM_MBW_SessionEpoch
	RunCritical := Critical("On")
	try {
		if (ExpectedEpoch != _LLM_MBW_SessionEpoch || !IsSet(_LLM_MBW_WebView))
			return
		; Retain the exact owner before restoring interruptibility. Reset may close
		; it afterwards, but this work can never resolve the successor global.
		TargetWebView := _LLM_MBW_WebView
	} finally {
		Critical(RunCritical)
	}
	WebView_RunScriptAsync(TargetWebView, Js, "LLM.browser")
}

_LLM_MBW_FlushQueue(ExpectedEpoch) {
	global _LLM_MBW_Ready, _LLM_MBW_Queue, _LLM_MBW_WebView, _LLM_MBW_SessionEpoch
	FlushCritical := Critical("On")
	try {
		if (ExpectedEpoch != _LLM_MBW_SessionEpoch)
			return
		_LLM_MBW_Ready := true
		Pending := _LLM_MBW_Queue
		_LLM_MBW_Queue := []
	} finally {
		Critical(FlushCritical)
	}
	; Defer each queued script (see _LLM_MBW_Eval) so none runs re-entrantly
	; inside the WebMessageReceived callback that typically triggers this flush.
	for _, Work in Pending {
		if (Work.Epoch == ExpectedEpoch)
			SetTimer(_LLM_MBW_RunScript.Bind(Work.Js, Work.Epoch), -1)
	}
}

; Fallback when the page never signals `ready`. It MUST do exactly what the real
; ready handler does. It previously flushed the queue but omitted
; _LLM_MBW_InjectCatalogue(), while still latching _LLM_MBW_Ready — so no later
; message could re-trigger the injection and the model table stayed permanently
; EMPTY. Trivially reachable, because the suspend guard used to drop the `ready`
; message outright.
_LLM_MBW_SafetyFlush(ExpectedEpoch) {
	global _LLM_MBW_SessionEpoch
	if (ExpectedEpoch != _LLM_MBW_SessionEpoch)
		return
	if (_LLM_MBW_Ready)
		return
	_LLM_MBW_OnPageReady(ExpectedEpoch)
}

; The single definition of "the page is up" — shared by the real ready message
; and by the safety flush, so the two can never drift apart again.
_LLM_MBW_OnPageReady(ExpectedEpoch) {
	global _LLM_MBW_SessionEpoch, LLM_PULL_PERCENT_LISTENER
	if (ExpectedEpoch != _LLM_MBW_SessionEpoch)
		return
	_LLM_MBW_FlushQueue(ExpectedEpoch)
	_LLM_MBW_InjectCatalogue(ExpectedEpoch)
	_LLM_MBW_StartListings(ExpectedEpoch)
	; A menu pull's percentage reaches this page (ollama_managed_bootstrap.ahk).
	LLM_PULL_PERCENT_LISTENER := LLM_ModelBrowser_PullPercent
}

/**
 * Receives messages from the page. Expected payloads:
 *   "ready"                                            — page bootstrap complete
 *   {"action":"select_model","backend":"…","name":"…"} — activate a model
 *   {"action":"download_model"|"delete_model"|"remove_custom_model", …}
 *   {"action":"add_model","backend":"ollama","name":"…"} — pull a named model
 *   {"action":"group_action"|"row_action","id":"…", …}  — a tool of the payload
 *   {"action":"disable_model"}                         — no model
 *   {"action":"open_url","url":"…"}                    — open the model page
 *   {"action":"close"}                                 — the page's Escape
 */
_LLM_MBW_OnWebMessage(ExpectedEpoch, Handler, Args) {
	global _LLM_MBW_SessionEpoch
	if (ExpectedEpoch != _LLM_MBW_SessionEpoch)
		return
	try Msg := Args.TryGetWebMessageAsString()
	if !IsSet(Msg)
		return

	; `ready` is a page-lifecycle signal, not a user action: it must be honoured
	; even while paused. Gating it here is what made the SafetyFlush path
	; reachable, and that fallback then left the model table permanently empty.
	if (Msg == "ready") {
		_LLM_MBW_OnPageReady(ExpectedEpoch)
		return
	}
	; A pause stops typing, not configuration (EDD-1): a paused driver still
	; chooses, downloads and removes a model. The work that serves predictions
	; (warmups, streaming) waits for the resume in its own owners.
	try Payload := JsonParse(Msg)
	if !IsSet(Payload)
		return
	if !(Payload is Map)
		return

	Action := Payload.Has("action") ? Payload["action"] : ""
	if !(Action is String)
		return
	; The page's Escape (PCK-19): closing writes nothing, so no config block
	; applies. Deferred out of this COM callback, as every teardown is.
	if (Action == "close") {
		SetTimer(_LLM_MBW_SessionCall.Bind(ExpectedEpoch, _LLM_MBW_OnClose), -1)
		return
	}
	; Every page action writes config.toml, as the tray rows it replaces did.
	if (Action != "open_url") {
		BlockReason := _LLM_Menu_ConfigBlockReason()
		if (BlockReason != "") {
			try LoggerWarn("LLM.browser", "Model selector action '{1}' refused: {2}.", Action, BlockReason)
			_LLM_MBW_RepaintRefusal(ExpectedEpoch)
			return
		}
	}
	if (Action == "open_url") {
		Url := Payload.Has("url") ? Payload["url"] : ""
		if (_LLM_MBW_IsCatalogueSourceUrl(Url)
				&& ExpectedEpoch == _LLM_MBW_SessionEpoch)
			ExternalUrl_OpenHttp(Url)
		return
	}
	; Defer every action out of this COM callback. _LLM_MBW_OnClose ->
	; _LLM_MBW_Reset releases the WebMessageReceived subscription that is
	; CURRENTLY DISPATCHING, then closes the controller and destroys the host
	; Gui — all synchronously on the callback stack. That is the
	; access-violation class ui/onboarding/webview.ahk documents and solves
	; with SetTimer(-1); an SEH fault of this kind is uncatchable.
	Deferred := _LLM_MBW_RunAction.Bind(Payload, ExpectedEpoch)
	if (Action == "select_model" && !Payload.Has("backend")) {
		Name := Payload.Has("name") ? Payload["name"] : ""
		if !_LLM_MBW_IsCatalogueModelName(Name)
			return
		Deferred := _LLM_MBW_ApplyModel.Bind(Name, ExpectedEpoch)
	}
	SetTimer(Deferred, -1)
}

/**
 * Sends a refused click's outcome to the page off this COM callback: the page
 * already drew an install click as running, and only a new payload brings the
 * reason back.
 * @param {Integer} ExpectedEpoch The browser session that sent the click.
 */
_LLM_MBW_RepaintRefusal(ExpectedEpoch) {
	SetTimer(() => (ExpectedEpoch == _LLM_MBW_SessionEpoch && LLM_ModelBrowser_Refresh()), -1)
}

/**
 * Runs one page action through the tray's own code path, on a fresh call
 * stack. The page names a row or a tool of the payload last injected; anything
 * else is refused, so the bridge never becomes a second, unvalidated model or
 * process-launch input channel.
 * @param {Map} Payload The page message.
 * @param {Integer} ExpectedEpoch The browser session that sent it.
 */
_LLM_MBW_RunAction(Payload, ExpectedEpoch) {
	global _LLM_MBW_SessionEpoch, _LLM_MBW_Rows, _LLM_MBW_Tools, _LLM_Menu
	if ExpectedEpoch != _LLM_MBW_SessionEpoch
		return
	Action := Payload["action"]
	Backend := Payload.Has("backend") && Payload["backend"] is String ? Payload["backend"] : ""
	Name := Payload.Has("name") && Payload["name"] is String ? Payload["name"] : ""
	try {
		if (Action == "disable_model") {
			if (LLM_Menu_SetModel("") == 1 && ExpectedEpoch == _LLM_MBW_SessionEpoch)
				_LLM_MBW_OnClose()
			return
		}
		if (Action == "group_action") {
			Id := Payload.Has("id") && Payload["id"] is String ? Payload["id"] : ""
			if _LLM_MBW_Tools.Has(Backend . "`n" . Id) {
				_LLM_MBW_Tools[Backend . "`n" . Id].Call()
				return
			}
			try LoggerWarn("LLM.browser", "Refused the unknown group action '{1}' of '{2}'.", Id, Backend)
			LLM_ModelBrowser_Refresh()
			return
		}
		if (Action == "add_model") {
			if (Backend != "ollama" || !LLM_ValidModelIdentifier("ollama", Name)) {
				try LoggerWarn("LLM.browser", "Refused adding '{1}': not a valid Ollama name.", Name)
				return
			}
			if (IsSet(LLM_Deps_HasFailed) && LLM_Deps_HasFailed())
				return
			try LoggerInfo("LLM.browser", "Model added via the selector page: {1}.", Name)
			_LLM_Menu_PullModel(Name, true)
			return
		}
		Key := Backend . "`n" . Name
		if !_LLM_MBW_Rows.Has(Key) {
			try LoggerWarn("LLM.browser", "Refused model selector action '{1}' for an unknown row.", Action)
			return
		}
		Row := _LLM_MBW_Rows[Key]
		OllamaReady := !(IsSet(LLM_Deps_HasFailed) && LLM_Deps_HasFailed())
		if (Action == "row_action") {
			Id := Payload.Has("id") && Payload["id"] is String ? Payload["id"] : ""
			if Row["row_actions"].Has(Id)
				Row["row_actions"][Id].Call()
			return
		}
		if (Backend == "ollama") {
			if !OllamaReady
				return
			if (Action == "select_model") {
				if !Row["installed"]
					return
				Applied := LLM_Menu_SetModel(Row["custom"] ? Row["tag"] : Row["name"])
				if (Applied == 1 && _LLM_Menu.Get("backend", "") != "ollama")
					Applied := LLM_Menu_SetBackend("ollama")
				if (Applied == 1 && ExpectedEpoch == _LLM_MBW_SessionEpoch)
					_LLM_MBW_OnClose()
			} else if (Action == "download_model") {
				if !Row["installed"]
					_LLM_Menu_PullModel(Row["custom"] ? Row["tag"] : Row["name"], Row["custom"])
			} else if (Action == "delete_model" || Action == "remove_custom_model") {
				if Row["installed"]
					_LLM_Menu_PromptDeleteCachedModel(Row["custom"] ? Row["tag"] : Row["name"])
			}
			return
		}
		if (Backend == "api" && Action == "select_model" && Row.Has("select")) {
			Applied := Row["select"].Call()
			if (Applied == 1 && ExpectedEpoch == _LLM_MBW_SessionEpoch)
				_LLM_MBW_OnClose()
		}
	} catch as Err {
		LoggerError("LLM.browser", "Model selector action '{1}' failed: {2}.", Action, Err.Message)
	}
}

; The WebView is a presentation of this exact catalogue. Keep its bridge from
; becoming a second, unvalidated model/config or process-launch input channel.
_LLM_MBW_IsCatalogueModelName(Name) {
	if !(Name is String) || Name == ""
		return false
	Index := LLM_GetModelIndex()
	if !(Index is Map)
		return false
	return Index.Has(Name)
}

_LLM_MBW_IsCatalogueSourceUrl(Url) {
	if !(Url is String) || Url == ""
		return false
	Index := LLM_GetModelIndex()
	if !(Index is Map)
		return false
	for _, Info in Index {
		if !(Info is Map) || !Info.Has("ollama")
			continue
		Tag := Info["ollama"]
		if ((Tag is String) && Tag != ""
				&& Url == _LLM_ModelLibraryUrl(Tag))
			return true
	}
	return false
}

; Runs from a SetTimer(-1) hand-off, never on the WebMessageReceived stack, so
; the subscription/controller/Gui teardown below cannot free objects that the
; in-flight COM dispatch is still standing on.
_LLM_MBW_ApplyModel(Name, ExpectedEpoch) {
	global _LLM_MBW_SessionEpoch
	if ExpectedEpoch != _LLM_MBW_SessionEpoch
		return
	; Teardown can pump a pause or a new browser session. Commit the selection
	; before those callouts, and close only the session which requested it.
	try Applied := LLM_Menu_SetModel(Name)
	catch as Err {
		LoggerError("LLM.browser", "Model selection failed: {1}.", Err.Message)
		return
	}
	if (Applied is Integer) && Applied == 1
			&& ExpectedEpoch == _LLM_MBW_SessionEpoch
		_LLM_MBW_OnClose()
}

/**
 * Returns the https:// virtual-host URL for _shared/ui/model_browser/index.html.
 * A per-open cache-buster forces a fresh document each launch instead of a
 * WebView2-cached stale copy from the virtual host.
 */
_LLM_MBW_HtmlUrl() {
	global LLM_MBW_VHOST
	return "https://" . LLM_MBW_VHOST . "/ui/model_browser/index.html?cb=" . A_TickCount
}

/** Returns the https:// virtual-host URL for _shared/core/i18n/data/locales/ (trailing slash). */
_LLM_MBW_LocalesUrl() {
	global LLM_MBW_VHOST
	return "https://" . LLM_MBW_VHOST . "/core/i18n/data/locales/"
}

/** Builds the ExecuteScript call that applies i18n strings (read from disk). */
_LLM_MBW_I18nApplyScript() {
	global _SharedDir, _I18nLocale
	json_path := _SharedDir . "\core\i18n\data\locales\" . _I18nLocale . ".json"
	json_str  := "{}"
	if FileExist(json_path)
		try json_str := FileRead(json_path, "UTF-8")
	return "window._i18n_strings=" . json_str
		. ";if(typeof window.i18n_apply==='function')window.i18n_apply(window._i18n_strings);"
}

/** Formats a number as a clean JS numeric literal (integers without a decimal). */
_LLM_MBW_Num(v) {
	if !IsNumber(v)
		return "0"
	n := v + 0
	if (n == Round(n))
		return String(Integer(n))
	return Format("{:.2f}", n)
}

_LLM_MBW_OnClose(ExpectedWindow := unset, *) {
	global _LLM_MBW_Gui, _LLM_MBW_SubscriptionOwner
	PreviousCritical := Critical("On")
	try {
		Host := _LLM_MBW_SubscriptionOwner
		Window := IsSet(ExpectedWindow) ? ExpectedWindow : (IsSet(_LLM_MBW_Gui) ? _LLM_MBW_Gui : 0)
	} finally Critical(PreviousCritical)
	if !_LLM_MBW_Reset(, Window)
		return
	if !IsObject(Host) && IsObject(Window)
		try Window.Destroy()
}

_LLM_MBW_OnResize(GuiObj, MinMax, Width, Height) {
	global _LLM_MBW_Controller
	if (MinMax == -1)
		return
	if IsSet(_LLM_MBW_Controller)
		try WebView_FitToWindow(_LLM_MBW_Controller)
}

_LLM_MBW_Reset(ExpectedEpoch := unset, ExpectedWindow := unset) {
	global _LLM_MBW_SubscriptionOwner
	global _LLM_MBW_Gui, _LLM_MBW_WebView, _LLM_MBW_Controller, _LLM_MBW_MsgSub
	global _LLM_MBW_Ready, _LLM_MBW_Queue, _LLM_MBW_ResetDone, _LLM_MBW_SessionEpoch
	PreviousCritical := Critical("On")
	try {
		if _LLM_MBW_ResetDone
			return false
		if (IsSet(ExpectedEpoch) && ExpectedEpoch != _LLM_MBW_SessionEpoch)
			|| (IsSet(ExpectedWindow) && IsSet(_LLM_MBW_Gui) && _LLM_MBW_Gui != ExpectedWindow)
			return false
		; Detach RAM before releasing subscriptions or closing COM: either can
		; pump a replacement which owns entirely different global references.
		Host := _LLM_MBW_SubscriptionOwner
		if IsObject(Host)
			Host.retired := true
		_LLM_MBW_SubscriptionOwner := 0
		if IsSet(_LLM_MBW_Gui)
			RetiredWindow := _LLM_MBW_Gui
		if IsSet(_LLM_MBW_WebView)
			RetiredView := _LLM_MBW_WebView
		if IsSet(_LLM_MBW_Controller)
			RetiredController := _LLM_MBW_Controller
		if IsSet(_LLM_MBW_MsgSub)
			RetiredMsgSub := _LLM_MBW_MsgSub
		_LLM_MBW_ResetDone := true
		_LLM_MBW_SessionEpoch += 1
		_LLM_MBW_Gui := unset
		_LLM_MBW_WebView := unset
		_LLM_MBW_Controller := unset
		_LLM_MBW_MsgSub := unset
		_LLM_MBW_Ready := false
		_LLM_MBW_Queue := []
	} finally Critical(PreviousCritical)
	try RetiredMsgSub := unset
	if IsObject(Host) {
		_LLM_MBW_RetireSubscriptionHost(Host)
	} else if IsSet(RetiredController)
		try RetiredController.Close()
	return true
}
