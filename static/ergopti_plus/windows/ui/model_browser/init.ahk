; ui/model_browser/init.ahk

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
;    yet and decide based on specs. The "Status" column tells them what is
;    already on disk so they can sort installed-first.
; 2. Sortable ListView — clicking a column header sorts ascending /
;    descending, exactly like a file manager. Useful to find the smallest
;    model that still fits in RAM, or the fastest among the chat-type ones.
; 3. Double-click = select — the row's display name flows through the same
;    ``LLM_Menu_SetModel`` path as the menu picker, so the deps checker is
;    triggered when the user picks something not yet installed. No special-
;    case install flow lives in this file.
; ==============================================================================

#Requires AutoHotkey v2.0


; Module-level Gui handle so a second call brings the existing window to
; the front instead of stacking duplicates.
global _LLM_ModelBrowser_Gui := unset

; Column index of "params" in the ListView — kept as a constant so the
; sort-on-header handler can resolve it without a magic number. Indices
; match the Add() order below.
global LLM_MB_COL_NAME      := 1
global LLM_MB_COL_FAMILY    := 2
global LLM_MB_COL_PARAMS    := 3
global LLM_MB_COL_RAM       := 4
global LLM_MB_COL_SPEED     := 5
global LLM_MB_COL_TYPE      := 6
global LLM_MB_COL_STATUS    := 7





; =====================================
; =====================================
; ======= 1/ Public Entry Point =======
; =====================================
; =====================================

/**
 * Opens (or brings forward) the visual model browser. The Gui is built
 * once and reused — closing it hides it instead of destroying so the
 * next call is instantaneous. Returns the Gui handle for chained tests.
 *
 * @returns {Gui} The browser window handle.
 */
LLM_ModelBrowser_Show() {
	global _LLM_ModelBrowser_Gui, _LLM_Menu
	; Prefer the shared web table (sortable/filterable, identical to the macOS
	; browser) when WebView2 is available and there is enough free RAM to boot it;
	; fall back to the native ListView below when WebView2 is unavailable, the
	; webview fails to spin up, or free RAM is too low for the Chromium cold start.
	if (_LLM_MBW_WebView2Available() && !WebView_ShouldUseNativeFallback()) {
		web := ""
		try web := _LLM_ModelBrowser_ShowWeb()
		catch as Err
			try LoggerError("LLM.browser", "WebView2 model browser failed: {1} — falling back to ListView.", Err.Message)
		if IsObject(web)
			return web
	}
	if IsSet(_LLM_ModelBrowser_Gui) {
		; A reused Gui that fails to refresh (e.g. models.json was edited
		; and re-parses badly) used to fall through to rebuild a SECOND
		; Gui without destroying the first — Gui handle leak. Catch the
		; failure, destroy the stale Gui, and let the rebuild path run.
		try {
			_LLM_ModelBrowser_Gui.Show()
			_LLM_ModelBrowser_RefreshRows(_LLM_ModelBrowser_Gui.ListView)
			return _LLM_ModelBrowser_Gui
		} catch {
			try _LLM_ModelBrowser_Gui.Destroy()
			_LLM_ModelBrowser_Gui := unset
		}
	}
	_LLM_ModelBrowser_Gui := _LLM_ModelBrowser_Build()
	_LLM_ModelBrowser_Gui.Show()
	return _LLM_ModelBrowser_Gui
}





; ====================================
; ====================================
; ======= 2/ Gui Construction ========
; ====================================
; ====================================

/**
 * Builds the browser Gui with a sortable ListView and a footer of action
 * buttons. The Gui itself is hidden until the caller invokes Show().
 *
 * @returns {Gui} New browser window.
 */
_LLM_ModelBrowser_Build() {
	; Variable name is ``g`` rather than ``gui`` because AHK v2 identifiers
	; are case-insensitive: a local ``gui`` shadows the built-in ``Gui``
	; class, so ``gui := Gui(...)`` resolves the right-hand side against
	; the just-declared (and still unset) local — triggering "This local
	; variable has not been assigned a value" the first time the menu
	; fires. ``g`` (matching the convention used elsewhere in the driver)
	; sidesteps the collision entirely.
	g := Gui_Create("+Resize +MinSize720x420", t("menu.llm.browse_models_window_title"))
	g.OnEvent("Close", _LLM_ModelBrowser_OnClose)
	g.OnEvent("Escape", _LLM_ModelBrowser_OnClose)
	g.MarginX := 10
	g.MarginY := 10

	g.SetFont("s10")

	; Filter row — search the table by typing a substring. Live filter on
	; every keystroke so the list narrows as the user thinks, no Apply
	; button needed. The hint label is dimmed to make the intent obvious.
	g.Add("Text",, t("menu.llm.browse_models_filter"))
	filter_edit := g.Add("Edit", "w560 vFilter")
	; Debounce the refresh: it re-runs the two-key sort over the full catalogue.
	; Installed tags are an in-memory snapshot; never probe Ollama from a GUI
	; open/filter callback because its synchronous HTTP fallback can freeze input.
	; The timer reference is stored
	; on the Gui so SetTimer can cancel-by-identity across keystrokes.
	g.FilterDebounce := () => _LLM_ModelBrowser_RefreshRows(g.ListView, filter_edit.Value)
	filter_edit.OnEvent("Change", (*) => (
		SetTimer(g.FilterDebounce, 0),
		SetTimer(g.FilterDebounce, -120)
	))

	; ListView — columns mirror the metadata extracted in
	; LLM_LoadModelsJSON. Status reads ``ollama list`` so the user can
	; tell installed vs available at a glance, but the column is filled
	; lazily on refresh to avoid blocking the Gui at construction.
	lv := g.Add("ListView",
		"r18 w780 vListView Sort -Multi",
		[ t("menu.llm.browse_col_name")
		, t("menu.llm.browse_col_family")
		, t("menu.llm.browse_col_params")
		, t("menu.llm.browse_col_ram")
		, t("menu.llm.browse_col_speed")
		, t("menu.llm.browse_col_type")
		, t("menu.llm.browse_col_status") ])
	lv.OnEvent("DoubleClick", (LV, RowNumber) => _LLM_ModelBrowser_PickRow(LV, RowNumber))
	g.ListView := lv

	; Action footer — Pick the current selection, Close. Pick mirrors a
	; double-click so users used to right-clicking lists still discover
	; the action.
	g.Add("Button", "w120 Default", t("menu.llm.browse_pick"))
		.OnEvent("Click", (*) => _LLM_ModelBrowser_PickRow(lv, lv.GetNext(0)))
	g.Add("Button", "x+10 w120", t("button.close"))
		.OnEvent("Click", _LLM_ModelBrowser_OnClose)

	_LLM_ModelBrowser_RefreshRows(lv)
	return g
}

/**
 * Refreshes the ListView rows from the current models.json index, applying
 * an optional substring filter. Highlights the row matching the currently
 * selected model so the user can see the baseline before picking another.
 *
 * @param {ListView} lv - Target list-view control.
 * @param {string}   filter - Substring filter (case-insensitive). Empty = no filter.
 */
_LLM_ModelBrowser_RefreshRows(lv, filter := "") {
	global _LLM_Menu
	lv.Delete()
	index := LLM_GetModelIndex()
	; The catalogue is static, so every model is listed regardless of state; the
	; Installed status comes from the async-maintained cache. GUI open/filter must
	; never perform live /api/tags I/O, even if the daemon was recently ready.
	installed := Map()
	if (IsSet(LLM_Deps_IsReady) and LLM_Deps_IsReady()) {
		for tag in _LLM_ModelBrowser_GetInstalledTags()
			installed[StrLower(tag)] := true
	}
	filter_lc := StrLower(filter)
	; Two-pass population so families end up grouped together — by sorting
	; on family first, the user can quickly see all Qwen / Gemma / Llama
	; variants next to each other without having to click the column.
	names := []
	for name, _ in index
		names.Push(name)
	names := _LLM_ModelBrowser_Sort(names)
	row_for_active := 0
	active := _LLM_Menu["model"]
	for name in names {
		info := index[name]
		family := _LLM_ModelBrowser_GuessFamily(name)
		; Guard every Map read with .Has() — a partial models.json entry
		; (older revisions of the file, custom user-added entries) would
		; otherwise throw UnsetItemError and kill the browser.
		params := info.Has("params_b")    ? info["params_b"]    : 0
		params_lbl := (params > 0) ? Format("{:.2f} B", params) : "—"
		if info.Has("active_b") and info["active_b"] > 0 and info["active_b"] != params
			params_lbl := params_lbl . " (" . Format("{:.2f} B", info["active_b"]) . " active)"
		ram_val   := info.Has("ram_gb")      ? info["ram_gb"]      : 0
		ram_lbl := (ram_val > 0) ? Format("{:.1f} Go", ram_val) : "—"
		speed_val := info.Has("speed_tok_s") ? info["speed_tok_s"] : 0
		speed_lbl := (speed_val > 0) ? (speed_val . " tok/s") : "—"
		type_lbl   := info.Has("type")   ? info["type"]   : "—"
		ollama_tag := info.Has("ollama") ? info["ollama"] : ""
		status_lbl := installed.Has(StrLower(ollama_tag)) ? t("menu.llm.browse_status_installed") : t("menu.llm.browse_status_available")
		row_text := name . " | " . family . " | " . params_lbl . " | " . ram_lbl . " | " . speed_lbl . " | " . type_lbl . " | " . status_lbl
		if (filter_lc != "" and !InStr(StrLower(row_text), filter_lc))
			continue
		idx := lv.Add(, name, family, params_lbl, ram_lbl, speed_lbl, type_lbl, status_lbl)
		if (name == active)
			row_for_active := idx
	}
	loop 7
		lv.ModifyCol(A_Index, "AutoHdr")
	if (row_for_active > 0) {
		lv.Modify(row_for_active, "Select Focus Vis")
	}
}

/**
 * Returns ``names`` sorted by (family asc, params asc) so families end up
 * grouped and the smallest variant of each family appears first. Pure
 * function — does not mutate the caller's array.
 */
_LLM_ModelBrowser_Sort(names) {
	Snapshot := []
	for Name in names
		Snapshot.Push(Name)
	if (Snapshot.Length < 2)
		return Snapshot
	; Native Array has no Sort method. Sort unique indices instead of model
	; text so delimiters and duplicate names cannot alter the copied entries.
	Indices := ""
	loop Snapshot.Length
		Indices .= (A_Index = 1 ? "" : "`n") . A_Index
	Ordered := Sort(Indices, "", (a, b, *) => _LLM_ModelBrowser_Compare(Snapshot[Integer(a)], Snapshot[Integer(b)]))
	out := []
	for Index in StrSplit(Ordered, "`n")
		out.Push(Snapshot[Integer(Index)])
	return out
}

/**
 * Two-key comparator for model names: family ascending, then params_b
 * ascending. Returns negative / zero / positive per AHK v2 sort convention.
 *
 * @param {string} a - First model name.
 * @param {string} b - Second model name.
 * @returns {number} Comparison result.
 */
_LLM_ModelBrowser_Compare(a, b) {
	af := _LLM_ModelBrowser_GuessFamily(a)
	bf := _LLM_ModelBrowser_GuessFamily(b)
	cmp := StrCompare(af, bf, false)
	if (cmp != 0)
		return cmp
	; Guard the secondary sort key — missing params_b sorts as 0
	info_a := LLM_GetModelInfo(a)
	info_b := LLM_GetModelInfo(b)
	ap := (info_a is Map and info_a.Has("params_b")) ? info_a["params_b"] : 0
	bp := (info_b is Map and info_b.Has("params_b")) ? info_b["params_b"] : 0
	return (ap < bp) ? -1 : (ap > bp ? 1 : 0)
}

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





; ====================================
; ====================================
; ======= 3/ Action Handlers =========
; ====================================
; ====================================

/**
 * Activates the highlighted model. Routes through the standard
 * LLM_Menu_SetModel path so the deps checker and engine re-init fire
 * exactly like a click in the flat menu. Closes the browser on success.
 */
_LLM_ModelBrowser_PickRow(LV, RowNumber) {
	if (!RowNumber or RowNumber < 1)
		return
	name := LV.GetText(RowNumber, 1)
	if (name == "")
		return
	LLM_Menu_SetModel(name)
	_LLM_ModelBrowser_OnClose()
}

_LLM_ModelBrowser_OnClose(*) {
	global _LLM_ModelBrowser_Gui
	if IsSet(_LLM_ModelBrowser_Gui) {
		try _LLM_ModelBrowser_Gui.Hide()
	}
}




; ==========================================
; ==========================================
; ======= 4/ WebView2 Shared Browser ========
; ==========================================
; ==========================================

; Module-level state for the WebView2 variant — separate from the ListView Gui so
; the two paths never clobber each other's handles.
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

; Virtual host mapped to _SharedDir so the document and its relative assets
; and the locale fetch resolve over https:// -- file:// is an opaque origin
; and the chrome.webview JS->AHK channel does not reliably deliver from it
; (see PROJECT_MEMORY project-webview2-bridge-gotchas).
global LLM_MBW_VHOST := "ergopti.modelbrowser"   ; -> _SharedDir
; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW.
global LLM_MBW_HOST_ACCESS_ALLOW := 1

/**
 * Builds (or brings forward) the shared web model browser in a WebView2 window.
 * Returns the Gui on success, or "" to signal the caller to use the ListView
 * fallback (e.g. WebView2 create failed).
 * @returns {Gui|string}
 */
_LLM_ModelBrowser_ShowWeb() {
	global _LLM_MBW_Gui, _LLM_MBW_Controller, _LLM_MBW_WebView, _LLM_MBW_MsgSub
	global _LLM_MBW_Ready, _LLM_MBW_Queue, _LLM_MBW_ResetDone, _LLM_MBW_SessionEpoch
	global _VendorDir, _SharedDir, _I18nLocale

	if IsSet(_LLM_MBW_Gui) {
		Window := _LLM_MBW_Gui, SessionEpoch := _LLM_MBW_SessionEpoch
		WMPresentWindow(Window)
		; A page still loading gets its catalogue from _LLM_MBW_OnPageReady, as
		; LLM_ModelBrowser_Refresh assumes: injecting here would only queue a
		; payload the ready handler rebuilds, and a failure to build it would send
		; the caller to the native fallback beside the open page.
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
	Installed := false, FactoryFailed := false, ResetForFallback := false
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
			MsgSub := View.WebMessageReceived(_LLM_MBW_OnWebMessage.Bind(SessionEpoch))
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			try View.SetVirtualHostNameToFolderMapping(LLM_MBW_VHOST, _SharedDir, LLM_MBW_HOST_ACCESS_ALLOW)
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			seed := "window.__i18n_base='" . _LLM_MBW_LocalesUrl() . "';"
				. "window._i18n_locale='" . _I18nLocale . "';"
			try View.AddScriptToExecuteOnDocumentCreated(seed)
			PreviousCritical := Critical("On")
			try {
				if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
					return g
				_LLM_MBW_Controller := Controller
				_LLM_MBW_WebView := View
				_LLM_MBW_MsgSub := MsgSub
				MsgSub := unset
				Installed := true
			} finally Critical(PreviousCritical)
			try View.Navigate(_LLM_MBW_HtmlUrl())
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			try Controller.Fill()
			if !_LLM_MBW_StartupCurrent(SessionEpoch, g)
				return g
			SetTimer(_LLM_MBW_SafetyFlush.Bind(SessionEpoch), -2000)
			Script := _LLM_MBW_I18nApplyScript()
			_LLM_MBW_Eval(Script, SessionEpoch)
			return g
		}
	} finally {
		if !Installed {
			; Only this frame's captured resources retire, even if Close reopens.
			ResetForFallback := _LLM_MBW_Reset(SessionEpoch, g)
			try MsgSub := unset
			if IsSet(Controller)
				try Controller.Close()
			try g.Destroy()
		}
	}
	; A retired constructor is handled. Only a still-owned factory failure
	; may ask the public entry to open the native fallback.
	return FactoryFailed && ResetForFallback && _LLM_MBW_SessionEpoch == SessionEpoch + 1
		&& !IsSet(_LLM_MBW_Gui) ? "" : g
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
 * _shared/lua/llm/model_catalogue.lua projects them on macOS and Linux, pinned
 * by tools/test/test-model-selector-page.cjs), the installed-tag cache, the API
 * entries and the local servers' rows. Each row's actions are the tray's own
 * closures, held in _LLM_MBW_Rows for the session; the page names a row, never
 * a command.
 *
 * The catalogue is STATIC (_shared/modules/llm/models.json), so it is ALWAYS
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
	OllamaTools := []
	if OllamaFailed
		OllamaTools.Push(_LLM_MBW_Tool(Tools, "ollama", "install",
			StrReplace(t("model_browser.install_runtime"), "%s", "Ollama"), (*) => _LLM_MBW_InstallOllama()))
	PortDisplay := _LLM_Menu.Has("ollama_port") ? _LLM_Menu["ollama_port"] : _LLM_DefaultFor("llm_ollama_port")
	OllamaTools.Push(_LLM_MBW_Tool(Tools, "ollama", "ollama_port",
		StrReplace(t("menu.llm.ollama_port_label"), "%s", "" . PortDisplay), (*) => LLM_Menu_PromptOllamaPort()))
	DefaultPort := _LLM_DefaultFor("llm_ollama_port")
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
	Blocked := _LLM_Menu_ConfigBlockReason()
	OllamaReason := Blocked != "" ? Blocked : (OllamaFailed ? "model_browser.reason_ollama_missing" : "")
	Backends := _LLM_MBW_BackendJson("ollama", OllamaReason == "", OllamaReason, OllamaTools, OllamaReason == "")
		. "," . _LLM_MBW_BackendJson("mlx", false, "model_browser.reason_mlx_unsupported_os", [], false)
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
_LLM_MBW_LocalRow(Name, Tag, Info, IsInstalled, IsDefault, Custom, Deletable) {
	global _LLM_MBW_PullPercents
	Params := Info.Has("params_b") ? Info["params_b"] : 0
	ActiveB := Info.Has("active_b") ? Info["active_b"] : 0
	if (ActiveB <= 0)
		ActiveB := Params
	Url := Custom ? "" : "https://ollama.com/library/" . Tag
	Json := "{backend:" . JsonStringLiteral("ollama")
		. ",name:" . JsonStringLiteral(Name)
		. ",runtime_name:" . JsonStringLiteral(Tag)
		. ",family:" . JsonStringLiteral(Custom ? "" : _LLM_ModelBrowser_GuessFamily(Name))
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

/** One backend entry of the payload, brand and emoji from backends.json. */
_LLM_MBW_BackendJson(Id, Available, ReasonKey, Tools, AddModel) {
	Brands := LLM_GetBackendBrands()
	ToolsJson := ""
	for Json in Tools
		ToolsJson .= (ToolsJson == "" ? "" : ",") . Json
	return "{id:" . JsonStringLiteral(Id) . ",brand:" . JsonStringLiteral(Brands[Id]["brand"])
		. ",emoji:" . JsonStringLiteral(Brands[Id]["emoji"]) . ",kind:" . JsonStringLiteral(Brands[Id]["kind"])
		. ",available:" . (Available ? "true" : "false")
		. (ReasonKey != "" ? ",reason_key:" . JsonStringLiteral(ReasonKey) : "")
		. (AddModel ? ",add_model:true" : "")
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
	for Top in LLM_Menu_LocalServersRows() {
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

/** The Ollama install the backend selection runs, from the page's Ollama group. */
_LLM_MBW_InstallOllama() {
	global _LLM_Menu
	if (_LLM_Menu.Get("backend", "") != "ollama")
		return LLM_Menu_SetBackend("ollama")
	return LLM_Deps_CheckAndInstall(_LLM_Menu.Get("model", ""))
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
	; WebMessageReceived is a COM callback that bypasses native Suspend, so
	; without this guard a paused driver would still let select_model mutate
	; the live LLM config/engine ("pause = tout éteint" invariant).
	if A_IsSuspended
		return

	try Payload := JsonParse(Msg)
	if !IsSet(Payload)
		return
	if !(Payload is Map)
		return

	Action := Payload.Has("action") ? Payload["action"] : ""
	if !(Action is String)
		return
	; Every page action writes config.toml, as the tray rows it replaces did.
	if (Action != "open_url") {
		BlockReason := _LLM_Menu_ConfigBlockReason()
		if (BlockReason != "") {
			try LoggerWarn("LLM.browser", "Model selector action '{1}' refused: {2}.", Action, BlockReason)
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
 * Runs one page action through the tray's own code path, on a fresh call
 * stack. The page names a row or a tool of the payload last injected; anything
 * else is refused, so the bridge never becomes a second, unvalidated model or
 * process-launch input channel.
 * @param {Map} Payload The page message.
 * @param {Integer} ExpectedEpoch The browser session that sent it.
 */
_LLM_MBW_RunAction(Payload, ExpectedEpoch) {
	global _LLM_MBW_SessionEpoch, _LLM_MBW_Rows, _LLM_MBW_Tools, _LLM_Menu
	if A_IsSuspended || (ExpectedEpoch != _LLM_MBW_SessionEpoch)
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
			if _LLM_MBW_Tools.Has(Backend . "`n" . Id)
				_LLM_MBW_Tools[Backend . "`n" . Id].Call()
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
				&& Url == "https://ollama.com/library/" . Tag)
			return true
	}
	return false
}

; Runs from a SetTimer(-1) hand-off, never on the WebMessageReceived stack, so
; the subscription/controller/Gui teardown below cannot free objects that the
; in-flight COM dispatch is still standing on.
_LLM_MBW_ApplyModel(Name, ExpectedEpoch) {
	global _LLM_MBW_SessionEpoch
	if A_IsSuspended or (ExpectedEpoch != _LLM_MBW_SessionEpoch)
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
 * Returns true when WebView2 is available and the loader DLL exists.
 * @returns {boolean}
 */
_LLM_MBW_WebView2Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
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

/** Returns the https:// virtual-host URL for _shared/data/locales/ (trailing slash). */
_LLM_MBW_LocalesUrl() {
	global LLM_MBW_VHOST
	return "https://" . LLM_MBW_VHOST . "/data/locales/"
}

/** Builds the ExecuteScript call that applies i18n strings (read from disk). */
_LLM_MBW_I18nApplyScript() {
	global _SharedDir, _I18nLocale
	json_path := _SharedDir . "\data\locales\" . _I18nLocale . ".json"
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
	global _LLM_MBW_Gui
	Window := IsSet(ExpectedWindow) ? ExpectedWindow : (IsSet(_LLM_MBW_Gui) ? _LLM_MBW_Gui : 0)
	if !_LLM_MBW_Reset(, Window)
		return
	if IsObject(Window)
		try Window.Destroy()
}

_LLM_MBW_OnResize(GuiObj, MinMax, Width, Height) {
	global _LLM_MBW_Controller
	if (MinMax == -1)
		return
	if IsSet(_LLM_MBW_Controller)
		try _LLM_MBW_Controller.Fill()
}

_LLM_MBW_Reset(ExpectedEpoch := unset, ExpectedWindow := unset) {
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
	if IsSet(RetiredController)
		try RetiredController.Close()
	return true
}
