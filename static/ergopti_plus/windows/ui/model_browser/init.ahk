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
	g := Gui("+Resize +MinSize720x420", t("menu.llm.browse_models_title"))
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
	out := []
	for n in names
		out.Push(n)
	; Two-key comparator: family ascending, then params_b ascending within
	; each family. Missing params_b entries sort as 0 (unknown size first).
	out.Sort((a, b) => _LLM_ModelBrowser_Compare(a, b))
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
	global _LLM_MBW_Gui, _LLM_MBW_Controller, _LLM_MBW_WebView, _LLM_MBW_Ready, _LLM_MBW_Queue, _LLM_MBW_ResetDone, _LLM_MBW_SessionEpoch, _VendorDir, _I18nLocale

	; Singleton: reuse the open window and just refresh the catalogue.
	if IsSet(_LLM_MBW_Gui) {
		try _LLM_MBW_Gui.Restore()
		try WinActivate(_LLM_MBW_Gui.Hwnd)
		_LLM_MBW_InjectCatalogue()
		return _LLM_MBW_Gui
	}

	EpochCritical := Critical("On")
	try {
		_LLM_MBW_SessionEpoch += 1
		SessionEpoch := _LLM_MBW_SessionEpoch
		_LLM_MBW_Ready := false
		_LLM_MBW_Queue := []
	} finally {
		Critical(EpochCritical)
	}

	g := Gui("+Resize +MinSize780x460", t("model_browser.window_title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w900 h580", "")
	g.OnEvent("Close",  _LLM_MBW_OnClose)
	g.OnEvent("Escape", _LLM_MBW_OnClose)
	g.OnEvent("Size",   _LLM_MBW_OnResize)
	g.Show("w900 h580")
	_LLM_MBW_Gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"

	try {
		; Reuse the shared session environment (infra/webview_utils.ahk) so no
		; second Chromium process boots and reopens are near-instant.
		_LLM_MBW_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("LLM.browser", "WebView2 create failed: {1}.", Err.Message)
		try g.Destroy()
		_LLM_MBW_Reset()
		; Clear the handle explicitly: the reset above short-circuits when a
		; previous session already latched _LLM_MBW_ResetDone, and a _LLM_MBW_Gui
		; left pointing at the Gui just destroyed would make every later open take
		; the singleton branch instead of building a window.
		_LLM_MBW_Gui := unset
		return ""
	}

	_LLM_MBW_WebView := _LLM_MBW_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a flag
	; left behind by an earlier _LLM_MBW_Reset() call.
	_LLM_MBW_ResetDone := false

	; Harden the webview — no devtools, context menu, status bar, or accelerators.
	try {
		s := _LLM_MBW_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; JS -> AHK bridge. Store the subscription handle in a persistent global --
	; discarding it lets the binding GC it and silently unsubscribe the handler.
	global _LLM_MBW_MsgSub := _LLM_MBW_WebView.WebMessageReceived(
		_LLM_MBW_OnWebMessage.Bind(SessionEpoch))

	; Map the virtual host BEFORE navigating so the document and every relative
	; asset and the locale fetch resolve through it instead of an opaque file://
	; origin.
	try _LLM_MBW_WebView.SetVirtualHostNameToFolderMapping(LLM_MBW_VHOST, _SharedDir, LLM_MBW_HOST_ACCESS_ALLOW)

	; Seed the i18n base + locale before the page scripts run so i18n.js resolves.
	seed := "window.__i18n_base='" . _LLM_MBW_LocalesUrl() . "';"
		. "window._i18n_locale='" . _I18nLocale . "';"
	try _LLM_MBW_WebView.AddScriptToExecuteOnDocumentCreated(seed)

	try _LLM_MBW_WebView.Navigate(_LLM_MBW_HtmlUrl())
	try _LLM_MBW_Controller.Fill()

	SetTimer(_LLM_MBW_SafetyFlush.Bind(SessionEpoch), -2000)
	; Inject the locale strings (read from disk) once the page is ready.
	_LLM_MBW_Eval(_LLM_MBW_I18nApplyScript())
	return g
}

/**
 * Builds the normalised catalogue (name/family/params/RAM/speed/type/installed/url,
 * MoE-aware) from the shared model index and injects it via injectModels(). The
 * Windows backend is always Ollama, so the install flag reads the Ollama tag list.
 *
 * The catalogue is STATIC (_shared/modules/llm/models.json), so it is ALWAYS injected in
 * full — whether or not the AI feature is enabled. Only the green "installed" dot
 * needs Ollama, so its tag scan is skipped unless the daemon is confirmed ready.
 * This is critical here: InjectCatalogue runs inside the WebView2 WebMessageReceived
 * (STA COM) callback, and a synchronous /api/tags WinHttp probe against a down
 * daemon (the usual state when the feature is OFF) stalls that callback so the
 * injectModels() ExecuteScript never fires — leaving the user with an empty table.
 */
_LLM_MBW_InjectCatalogue(ExpectedEpoch := unset) {
	global _LLM_Menu
	index := LLM_GetModelIndex()
	installed := Map()
	if (IsSet(LLM_Deps_IsReady) and LLM_Deps_IsReady()) {
		for tag in _LLM_ModelBrowser_GetInstalledTags()
			installed[StrLower(tag)] := true
	}
	active := _LLM_Menu.Has("model") ? _LLM_Menu["model"] : ""

	models := "", count := 0
	for name, info in index {
		params   := (info is Map and info.Has("params_b"))    ? info["params_b"]    : 0
		active_b := (info is Map and info.Has("active_b"))     ? info["active_b"]    : 0
		if (active_b <= 0)
			active_b := params
		is_moe   := (active_b > 0 and active_b < params)
		ram      := (info is Map and info.Has("ram_gb"))       ? info["ram_gb"]      : 0
		speed    := (info is Map and info.Has("speed_tok_s"))  ? info["speed_tok_s"] : 0
		mtype    := (info is Map and info.Has("type"))         ? info["type"]        : "chat"
		ollama   := (info is Map and info.Has("ollama"))       ? info["ollama"]      : ""
		inst     := installed.Has(StrLower(ollama))
		family   := _LLM_ModelBrowser_GuessFamily(name)
		url      := (ollama != "") ? ("https://ollama.com/library/" . ollama) : ""

		obj := "{name:" . _LLM_MBW_JsStr(name)
			. ",family:" . _LLM_MBW_JsStr(family)
			. ",provider:" . _LLM_MBW_JsStr("")
			. ",params_b:" . _LLM_MBW_Num(params)
			. ",active_b:" . _LLM_MBW_Num(active_b)
			. ",is_moe:" . (is_moe ? "true" : "false")
			. ",ram_gb:" . _LLM_MBW_Num(ram)
			. ",speed_tok_s:" . _LLM_MBW_Num(speed)
			. ",type:" . _LLM_MBW_JsStr(mtype)
			. ",installed:" . (inst ? "true" : "false")
			. ",url:" . _LLM_MBW_JsStr(url)
			. "}"
		models .= (count > 0 ? "," : "") . obj
		count += 1
	}

	js := "injectModels({backend:" . _LLM_MBW_JsStr("ollama")
		. ",active:" . _LLM_MBW_JsStr(active)
		. ",models:[" . models . "]})"
	if IsSet(ExpectedEpoch)
		_LLM_MBW_Eval(js, ExpectedEpoch)
	else
		_LLM_MBW_Eval(js)
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
	try {
		TargetWebView.ExecuteScriptAsync(Js)
	} catch as Err {
		try LoggerError("LLM.browser", "ExecuteScriptAsync failed (len={1}): {2}.", StrLen(Js), Err.Message)
	}
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
	global _LLM_MBW_SessionEpoch
	if (ExpectedEpoch != _LLM_MBW_SessionEpoch)
		return
	_LLM_MBW_FlushQueue(ExpectedEpoch)
	_LLM_MBW_InjectCatalogue(ExpectedEpoch)
}

/**
 * Receives messages from the page. Expected payloads:
 *   "ready"                                  — page bootstrap complete
 *   {"action":"select_model","name":"…"}     — activate a model
 *   {"action":"open_url","url":"…"}          — open the model page in the browser
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
	if !IsObject(Payload)
		return

	Action := Payload.Has("action") ? Payload["action"] : ""
	if (Action == "select_model") {
		Name := Payload.Has("name") ? Payload["name"] : ""
		if (Name != "") {
			; Defer the teardown out of this COM callback. _LLM_MBW_OnClose ->
			; _LLM_MBW_Reset releases the WebMessageReceived subscription that is
			; CURRENTLY DISPATCHING, then closes the controller and destroys the
			; host Gui — all synchronously on the callback stack. That is the
			; access-violation class ui/onboarding/webview.ahk documents and
			; already solves with SetTimer(-1); it was never applied here, and this
			; path runs on every successful use of the browser (double-click, Enter
			; or the Use button). An SEH fault of this kind is uncatchable and
			; surfaces as a random crash with no link to the click.
			SetTimer(_LLM_MBW_ApplyModel.Bind(Name, ExpectedEpoch), -1)
		}
	} else if (Action == "open_url") {
		Url := Payload.Has("url") ? Payload["url"] : ""
		if (Url != "" && ExpectedEpoch == _LLM_MBW_SessionEpoch)
			try Run(Url)
	}
}

; Runs from a SetTimer(-1) hand-off, never on the WebMessageReceived stack, so
; the subscription/controller/Gui teardown below cannot free objects that the
; in-flight COM dispatch is still standing on.
_LLM_MBW_ApplyModel(Name, ExpectedEpoch) {
	global _LLM_MBW_SessionEpoch
	if A_IsSuspended or (ExpectedEpoch != _LLM_MBW_SessionEpoch)
		return
	_LLM_MBW_OnClose()
	try LLM_Menu_SetModel(Name)
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

/** Escapes a string for safe injection into a JS double-quoted literal. */
_LLM_MBW_JsStr(s) {
	return JsonStringLiteral(s)
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

_LLM_MBW_OnClose(*) {
	global _LLM_MBW_Gui
	; Save the Gui reference BEFORE Reset clears the global, then close the
	; WebView2 controller first (while the parent window is still alive) and
	; only destroy the Gui afterwards — the WebView2 spec requires Controller
	; to be closed before its host HWND is destroyed
	saved_gui := IsSet(_LLM_MBW_Gui) ? _LLM_MBW_Gui : 0
	_LLM_MBW_Reset()
	try {
		if saved_gui
			saved_gui.Destroy()
	}
	_LLM_MBW_Gui := unset   ; Always clear the reference, even if Destroy threw
}

_LLM_MBW_OnResize(GuiObj, MinMax, Width, Height) {
	global _LLM_MBW_Controller
	if (MinMax == -1)
		return
	if IsSet(_LLM_MBW_Controller)
		try _LLM_MBW_Controller.Fill()
}

_LLM_MBW_Reset() {
	global _LLM_MBW_Gui, _LLM_MBW_WebView, _LLM_MBW_Controller, _LLM_MBW_MsgSub, _LLM_MBW_Ready, _LLM_MBW_Queue, _LLM_MBW_ResetDone, _LLM_MBW_SessionEpoch
	; Close, Escape and the deferred model-apply all land here, and
	; Controller.Close() pumps messages — so a second dispatch can re-enter this
	; function while the first teardown is still in flight. Short-circuit instead
	; of running the release + Close sequence twice against a controller that is
	; already going away.
	if _LLM_MBW_ResetDone
		return
	_LLM_MBW_ResetDone := true
	; Invalidate timers and callbacks before releasing any COM owner. A timer that
	; was already queued may still run, but it cannot target a later WebView.
	_LLM_MBW_SessionEpoch += 1
	; Release the subscription FIRST, while the controller is still alive. Its
	; __Delete unsubscribes via remove_WebMessageReceived on the live
	; controller; doing it AFTER Controller.Close() raises a COM error.
	try _LLM_MBW_MsgSub := unset
	if IsSet(_LLM_MBW_Controller)
		try _LLM_MBW_Controller.Close()
	_LLM_MBW_Gui        := unset
	_LLM_MBW_WebView    := unset
	_LLM_MBW_Controller := unset
	_LLM_MBW_Ready      := false
	_LLM_MBW_Queue      := []
}
