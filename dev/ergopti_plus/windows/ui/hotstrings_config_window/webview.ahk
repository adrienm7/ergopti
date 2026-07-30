; ui/hotstrings_config_window/webview.ahk

; ==============================================================================
; MODULE: Hotstrings Config Window WebView2 Host
; DESCRIPTION:
; Renders the per-group hotstring delay / color / priority / tooltip editor on
; Windows via WebView2, loading the shared frontend at
; _shared/ui/hotstrings_config_window/ so the AHK and Hammerspoon drivers show an
; identical UI. It reuses the data layer of the native window (ui/
; hotstrings_config_window/init.ahk) — _HCW_BuildCategoryList, _HCW_Resolve,
; _HCW_TomlDefaults, _HCW_UserOverride, _HCW_SetOverride / _HCW_ClearOverride and
; _HCW_PatchTomlMeta — and only swaps the presentation tier for a webview.
;
; FEATURES & RATIONALE:
; 1. Shared frontend — same index.html/script.js/style.css as macOS, resolved
;    through a virtual-host mapping over _SharedDir; file:// is an opaque origin
;    that breaks the JS->AHK channel, so the document is served over https.
; 2. Round-trip via the bridge — the page posts {action, …} messages; the host
;    applies the mutation through the shared data layer and pushes a freshly
;    rebuilt state with setData() so the UI never keeps a divergent local copy.
; 3. State parity — _HCWWeb_BuildStateJson mirrors the macOS build_state() shape
;    exactly (categories / groups / presets / global_default_delay_ms) so a
;    single frontend renders both drivers.
; 4. Safe teardown — subscription handles are released BEFORE Controller.Close()
;    (their __Delete unsubscribes on the live controller; reversing the order
;    raises a COM error that, uncaught in the Close thread, quits the script).
; 5. Singleton + graceful fallback — a second open focuses the existing window;
;    when WebView2 is unavailable the caller falls back to the native Gui.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================================
; ===================================
; ======= 1/ Lifecycle / open =======
; ===================================
; ==============================================================

; Singleton window + WebView2 plumbing. Subscription handles live in globals so
; the binding does not GC them (which silently drops the JS->AHK channel); they
; are released BEFORE Controller.Close() in _HCWWeb_Reset.
global _HCWWeb_Gui        := 0
global _HCWWeb_Controller := unset
global _HCWWeb_WebView    := unset
global _HCWWeb_MsgSub     := unset
global _HCWWeb_NavSub     := unset
; True once _HCWWeb_Reset() has torn the controller down. Both the frontend
; "close" message (_HCWWeb_Dispatch) and the native Gui Close event route
; through the SAME _HCWWeb_Close() -> _HCWWeb_Reset() call, and a second
; pass's unsubscribe line calls remove_WebMessageReceived via ComCall against
; a CoreWebView2 pointer already invalidated by the first pass's
; Controller.Close() — a genuine SEH access violation no AHK try/catch can
; intercept (see personal_toml_editor_webview.ahk _HsEdWeb_ResetDone for the
; crash this mirrors). The flag makes the second call a true no-op instead.
global _HCWWeb_ResetDone  := false

; Virtual host that maps to _SharedDir so the document and its relative assets
; (style.css, ../i18n.js) and the locale fetch all resolve over https.
global HCWWEB_VHOST             := "ergopti.hotstringsconfig"
global HCWWEB_HOST_ACCESS_ALLOW := 1

; Window geometry — mirrors the macOS utility panel (720x640) with a little slack.
global HCWWEB_WIDTH  := 740
global HCWWEB_HEIGHT := 660

; Grey applied by the "set all grey" bulk action — kept in sync with the native
; _HCW_SetAllGrey and the macOS host.
global HCWWEB_GREY := "#6e6e73"

; Returns true when the WebView2 runtime binding + loader DLL are present.
_HCWWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Attempts to show the config window in a WebView2 window. Returns true on success
; (the caller must NOT also build the native Gui), false to fall back.
_HCWWeb_TryOpen() {
	global _HCWWeb_Gui, _HCWWeb_Controller, _HCWWeb_WebView
	global _HCWWeb_MsgSub, _HCWWeb_NavSub, _HCWWeb_ResetDone, _VendorDir, _SharedDir

	if !_HCWWeb_Available()
		return false

	; Singleton — bring the existing editor to the front.
	if (_HCWWeb_Gui != 0) {
		try WinActivate("ahk_id " . _HCWWeb_Gui.Hwnd)
		return true
	}

	; Build the canonical data model up front so the first push has content and
	; the locale-dependent labels / color presets are populated.
	_HCW_InitLocaleStrings()
	_HCW_BuildCategoryList()
	_HCW_BuildGroupList()

	g := Gui("+Resize +MinSize560x320", t("hs_config.window_title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w" . HCWWEB_WIDTH . " h" . HCWWEB_HEIGHT, "")
	g.OnEvent("Close", _HCWWeb_OnClose)
	g.OnEvent("Size",  _HCWWeb_OnResize)

	; Show BEFORE creating the control — a hidden Gui has a zero client rect, so
	; the control lays out blank and never recovers.
	g.Show("w" . HCWWEB_WIDTH . " h" . HCWWEB_HEIGHT . " Center")
	_HCWWeb_Gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_HCWWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("HotstringsConfigWindow", "WebView2 create failed: {1} — falling back to native Gui.", Err.Message)
		try g.Destroy()
		_HCWWeb_Reset()
		_HCWWeb_Gui := 0
		return false
	}

	_HCWWeb_WebView := _HCWWeb_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a
	; flag left behind by an earlier _HCWWeb_Reset() call.
	_HCWWeb_ResetDone := false

	try {
		s := _HCWWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; Store the subscription handles in persistent globals (see header note).
	global _HCWWeb_MsgSub := _HCWWeb_WebView.WebMessageReceived(_HCWWeb_OnWebMessage)
	global _HCWWeb_NavSub := _HCWWeb_WebView.NavigationCompleted(_HCWWeb_OnNavigationCompleted)

	; Map the virtual host BEFORE navigating so the document and every relative
	; asset resolve through it; seed the i18n base + active locale before page
	; scripts run so the shared i18n.js fetches the right locale JSON.
	try _HCWWeb_WebView.SetVirtualHostNameToFolderMapping(HCWWEB_VHOST, _SharedDir, HCWWEB_HOST_ACCESS_ALLOW)
	try _HCWWeb_WebView.AddScriptToExecuteOnDocumentCreated(_HCWWeb_I18nSeed())
	try _HCWWeb_WebView.Navigate(_HCWWeb_HtmlUrl())
	try _HCWWeb_Controller.Fill()

	try LoggerSuccess("HotstringsConfigWindow", "Hotstrings config window shown via WebView2.")
	return true
}





; ==============================================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ==============================================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 channel, so each message is an object {action, …}. Work is
; deferred out of the COM callback (SetTimer -1) so the follow-up push never runs
; re-entrantly inside the event callback.
_HCWWeb_OnWebMessage(Handler, Args) {
	try Msg := Args.TryGetWebMessageAsString()
	if !IsSet(Msg)
		return
	try Payload := JsonParse(Msg)
	if (!IsSet(Payload) || !(Payload is Map))
		return

	Action := Payload.Has("action") ? Payload["action"] : ""
	; WebMessageReceived is a COM callback: it bypasses native Suspend, which only
	; disarms hotkeys. Without this a paused driver still lets a page click write
	; config, re-register hotstrings or launch an elevated install.
	; Page-lifecycle signals are deliberately NOT gated — dropping `ready` strands
	; the SafetyFlush and leaves the page permanently un-initialised.
	if (A_IsSuspended && Action != "ready")
		return
	if (Action == "ready") {
		SetTimer(_HCWWeb_PushState, -1)
		return
	}
	SetTimer(_HCWWeb_Dispatch.Bind(Payload), -1)
}

; Push the initial state once the page has finished loading (the frontend also
; emits a best-effort "ready", so this fires whichever arrives — both idempotent).
_HCWWeb_OnNavigationCompleted(Handler, Args) {
	SetTimer(_HCWWeb_PushState, -1)
}

; Apply one mutation message, then push the rebuilt state. Mirrors the macOS
; on_message dispatch: bulk actions hit every category, per-entry actions resolve
; the entry by its key and route through the shared write helpers.
_HCWWeb_Dispatch(Payload) {
	Action := Payload.Has("action") ? Payload["action"] : ""

	if (Action == "close") {
		_HCWWeb_Close()
		return
	}
	if (Action == "reset_all") {
		_HCWWeb_ResetAll()
		_HCWWeb_PushState()
		return
	}
	if (Action == "set_all_grey") {
		_HCWWeb_SetAllGrey()
		_HCWWeb_PushState()
		return
	}

	CatKey := Payload.Has("category") ? Payload["category"] : ""
	Entry  := _HCWWeb_FindEntry(CatKey)
	if !IsObject(Entry)
		return
	Sec := (Payload.Has("section") && Payload["section"] != "") ? Payload["section"] : ""

	switch Action {
		case "set_delay":
			if Payload.Has("ms")
				_HCW_SetOverride(Entry, Sec, "delay", Payload["ms"] / 1000)
		case "clear_delay":
			_HCW_ClearOverride(Entry, Sec, "delay")
		case "set_color":
			if (Payload.Has("hex") && Payload["hex"] != "")
				_HCW_SetOverride(Entry, Sec, "color", Payload["hex"])
		case "clear_color":
			_HCW_ClearOverride(Entry, Sec, "color")
		case "set_priority":
			if Payload.Has("priority")
				_HCW_SetOverride(Entry, Sec, "priority", Payload["priority"])
		case "clear_priority":
			_HCW_ClearOverride(Entry, Sec, "priority")
		case "set_tooltip":
			_HCW_SetOverride(Entry, Sec, "show_tooltip",
				Payload.Has("show_tooltip") && Payload["show_tooltip"] == true)
		case "clear_tooltip":
			_HCW_ClearOverride(Entry, Sec, "show_tooltip")
		default:
			return
	}
	_HCWWeb_PushState()
}

; Clear every override across all categories (common / personal / extension),
; matching the native _HCW_ResetAll loop minus the Gui teardown.
_HCWWeb_ResetAll() {
	global _HCW_CATEGORY_LIST
	; Same two steps as the native _HCW_ResetAll, and for the same reasons — this
	; twin had neither.
	;
	; FLUSH FIRST: a numeric edit armed up to _HCW_NUMERIC_DEBOUNCE_MS ago would
	; otherwise land AFTER the loop below and persist on top of the override it just
	; cleared, silently un-resetting that one field.
	_HCW_FlushNumericWrite()
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			_HCW_PatchTomlMeta(E.Path, "", "delay", "")
			_HCW_PatchTomlMeta(E.Path, "", "color", "")
			_HCW_PatchTomlMeta(E.Path, "", "priority", "")
			for _, Sec in _HCW_GetSections(E) {
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "delay", "")
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "priority", "")
			}
		} else if E.IsExtension {
			HotstringsClearOverride("ext." . E.ExtId, "", "")
			for _, Sec in _HCW_GetSections(E)
				HotstringsClearOverride("ext." . E.ExtId, Sec.Name, "")
		} else {
			HotstringsClearOverride(E.Key, "", "")
			for _, Sec in _HCW_GetSections(E)
				HotstringsClearOverride(E.Key, Sec.Name, "")
		}
	}
	; REPUBLISH AFTER: the loop clears delay and priority through the storage
	; primitives DIRECTLY, bypassing the _HCW_SetOverride / _HCW_ClearOverride choke
	; point where the republish lives. Both fields are baked into every Spec at
	; registration, so clearing them only bumps the resolve generation: without this,
	; the window and the TOOLTIP advertise the default delay while the engine keeps
	; gating on the value the user had set — the tooltip promising an expansion the
	; engine will refuse (hcw-webview-reset-does-not-republish). One rebuild for the
	; whole reset, because the reset is a single user action rather than N of them.
	_HCW_RepublishIfBakedField("delay")
	try TrayTip(t("hs_config.notify_reset_all"), t("hs_config.btn_reset_all"), "Iconi Mute")
}

; Force every category/extension to grey at file level and clear per-section
; colour overrides so the grey cascades down. Mirrors the native _HCW_SetAllGrey.
_HCWWeb_SetAllGrey() {
	global _HCW_CATEGORY_LIST, HCWWEB_GREY
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			_HCW_PatchTomlMeta(E.Path, "", "color", HCWWEB_GREY)
			for _, Sec in _HCW_GetSections(E)
				_HCW_PatchTomlMeta(E.Path, Sec.Name, "color", "")
		} else if E.IsExtension {
			HotstringsSetOverride("ext." . E.ExtId, "", "color", HCWWEB_GREY)
			for _, Sec in _HCW_GetSections(E)
				HotstringsClearOverride("ext." . E.ExtId, Sec.Name, "color")
		} else {
			HotstringsSetOverride(E.Key, "", "color", HCWWEB_GREY)
			for _, Sec in _HCW_GetSections(E)
				HotstringsClearOverride(E.Key, Sec.Name, "color")
		}
	}
}

; Find a category entry by its unique key (the "name" the frontend echoes back).
_HCWWeb_FindEntry(Key) {
	global _HCW_CATEGORY_LIST
	for _, E in _HCW_CATEGORY_LIST {
		if (E.Key == Key)
			return E
	}
	return 0
}





; ==============================================================
; ===================================
; ======= 3/ State serializer =======
; ===================================
; ==============================================================

; Push the freshly rebuilt state to the page via setData(...).
_HCWWeb_PushState() {
	_HCWWeb_Eval("if(window.setData)window.setData(" . _HCWWeb_BuildStateJson() . ")")
}

; Build the JSON state object consumed by the shared frontend. Shape mirrors the
; macOS build_state(): { categories, groups, presets, global_default_delay_ms }.
_HCWWeb_BuildStateJson() {
	global _HCW_CATEGORY_LIST, _HCW_GROUP_LIST, _HCW_COLOR_PRESETS, GLOBAL_DEFAULT_DELAY

	Cats := ""
	for _, E in _HCW_CATEGORY_LIST {
		if (Cats != "")
			Cats .= ","
		Cats .= _HCWWeb_CategoryJson(E)
	}

	Groups := ""
	for _, G in _HCW_GROUP_LIST {
		if (Groups != "")
			Groups .= ","
		Groups .= "{" . _HCWWeb_Kv("key", G.Key) . "," . _HCWWeb_Kv("label", G.Label) . "}"
	}

	; The empty-hex "inherit" preset is dropped here: the frontend clears a colour
	; via the reset (↺) button, and a zero-value <option> would be inert.
	Presets := ""
	for _, P in _HCW_COLOR_PRESETS {
		if (P["Hex"] == "")
			continue
		if (Presets != "")
			Presets .= ","
		Presets .= "{" . _HCWWeb_Kv("label", P["Label"]) . "," . _HCWWeb_Kv("hex", P["Hex"]) . "}"
	}

	GlobalMs := Round(GLOBAL_DEFAULT_DELAY * 1000)
	return "{"
		. '"categories":[' . Cats . "],"
		. '"groups":[' . Groups . "],"
		. '"presets":[' . Presets . "],"
		. '"global_default_delay_ms":' . GlobalMs
		. "}"
}

; Serialize one category (file-level fields + its sections array).
_HCWWeb_CategoryJson(E) {
	PersonalPath := E.IsPersonal ? StrReplace(E.Path, "\", "/") : ""
	ExtId        := E.HasOwnProp("ExtId") ? E.ExtId : ""

	Secs := ""
	for _, S in _HCW_GetSections(E) {
		if (Secs != "")
			Secs .= ","
		Secs .= "{"
			. _HCWWeb_Kv("name", S.Name) . ","
			. _HCWWeb_Kv("title", S.Title) . ","
			. _HCWWeb_FieldsJson(E, S.Name)
			. "}"
	}

	return "{"
		. _HCWWeb_Kv("name", E.Key) . ","
		. _HCWWeb_Kv("group", E.Group) . ","
		. _HCWWeb_Kv("title", E.Label) . ","
		. _HCWWeb_Kv("personal_path", PersonalPath) . ","
		. _HCWWeb_Kv("ext_id", ExtId) . ","
		. _HCWWeb_FieldsJson(E, "") . ","
		. '"sections":[' . Secs . "]"
		. "}"
}

; The shared field block (delay / color / priority / tooltip with their defaults
; and override flags) for an entry at file level (Sec == "") or a section.
_HCWWeb_FieldsJson(E, Sec) {
	Resolved := _HCW_Resolve(E, Sec)
	Defaults := _HCW_TomlDefaults(E, Sec)
	Override := _HCW_UserOverride(E, Sec)
	FbDelay  := _HCW_FallbackDelayMs(E)
	FbPrio   := _HCW_FallbackPriority(E)

	DelayMs  := (Resolved.Delay != "") ? Round(Resolved.Delay * 1000) : FbDelay
	DelayDef := (Defaults.Delay != "") ? Round(Defaults.Delay * 1000) : FbDelay
	DelayOvr := (Override.Delay != "")

	Color    := Resolved.Color
	ColorDef := Defaults.Color
	ColorOvr := (Override.Color != "")

	Tip      := Resolved.HasOwnProp("ShowTooltip") ? Resolved.ShowTooltip : true
	TipOvr   := (Override.ShowTooltip != "")

	PrioDef  := (Defaults.HasOwnProp("Priority") && Defaults.Priority != "") ? Defaults.Priority : FbPrio
	Prio     := (Resolved.HasOwnProp("Priority") && Resolved.Priority != "") ? Resolved.Priority : PrioDef
	PrioOvr  := (Override.Priority != "")

	return '"delay_ms":' . DelayMs
		. ',"delay_default_ms":' . DelayDef
		. ',"delay_overridden":' . _HCWWeb_Bool(DelayOvr)
		. ',' . _HCWWeb_Kv("color", Color)
		. ',' . _HCWWeb_Kv("color_default", ColorDef)
		. ',"color_overridden":' . _HCWWeb_Bool(ColorOvr)
		. ',"show_tooltip":' . _HCWWeb_Bool(Tip)
		. ',"show_tooltip_overridden":' . _HCWWeb_Bool(TipOvr)
		. ',"priority":' . _HCWWeb_Num(Prio)
		. ',"priority_default":' . _HCWWeb_Num(PrioDef)
		. ',"priority_overridden":' . _HCWWeb_Bool(PrioOvr)
}





; ==============================================================
; =====================================
; ======= 4/ Helpers / teardown =======
; =====================================
; ==============================================================

; Builds one JSON key/value pair (key:"value") with the value safely escaped.
_HCWWeb_Kv(Key, Value) {
	return '"' . Key . '":' . _HCWWeb_JsStr(Value)
}

; JSON boolean literal from an AHK truthy value.
_HCWWeb_Bool(V) {
	return V ? "true" : "false"
}

; JSON number, or null when the value is empty so the frontend treats it as
; "inherit" (its bindPriority only honours typeof === "number").
_HCWWeb_Num(V) {
	return (V == "") ? "null" : V
}

; Quoted, escaped JSON string literal for safe interpolation.
_HCWWeb_JsStr(s) {
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, '"', '\"')
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`t", "\t")
	return '"' . s . '"'
}

; i18n seed injected before page scripts run: the locale base (served over the
; virtual host) and the active locale, consumed by the shared i18n.js.
_HCWWeb_I18nSeed() {
	global HCWWEB_VHOST, _I18nLocale
	loc := IsSet(_I18nLocale) ? _I18nLocale : "en"
	return "window.__i18n_base='https://" . HCWWEB_VHOST . "/data/locales/';"
		. "window._i18n_locale='" . loc . "';"
}

; Virtual-host URL for the window's index.html (served from _SharedDir via the
; vhost). A per-open cache-buster forces a fresh document each launch (WebView2
; caches virtual-host resources); the page's own ?v= queries refresh assets.
_HCWWeb_HtmlUrl() {
	global HCWWEB_VHOST
	return "https://" . HCWWEB_VHOST . "/ui/hotstrings_config_window/index.html?cb=" . A_TickCount
}

; Fire-and-forget script eval. ExecuteScript().await() wedges the thread when
; called from inside a WebView2 callback, so never await here.
_HCWWeb_Eval(Js) {
	global _HCWWeb_WebView
	if !IsSet(_HCWWeb_WebView)
		return
	try _HCWWeb_WebView.ExecuteScriptAsync(Js)
}

_HCWWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _HCWWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_HCWWeb_Controller)
		try _HCWWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) and the frontend "close" button both land here.
_HCWWeb_OnClose(*) {
	_HCWWeb_Close()
}

_HCWWeb_Close() {
	global _HCWWeb_Gui
	saved := (_HCWWeb_Gui != 0) ? _HCWWeb_Gui : 0
	_HCWWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_HCWWeb_Gui := 0
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. the frontend
; "close" message and the native Gui Close event both firing for the same
; teardown) is a true no-op instead of touching the globals again.
_HCWWeb_Reset() {
	global _HCWWeb_Controller, _HCWWeb_WebView, _HCWWeb_MsgSub, _HCWWeb_NavSub
	global _HCWWeb_ResetDone

	; A prior Reset() already released remove_WebMessageReceived/remove_Navigation-
	; Completed against this controller. Re-running the unset lines below would
	; call __Delete's bound ComCall a SECOND time against a COM pointer WebView2
	; has already torn down (Controller.Close() releases CoreWebView2's underlying
	; interfaces) — a genuine SEH access violation that no try/catch can intercept.
	if _HCWWeb_ResetDone
		return
	_HCWWeb_ResetDone := true

	; The whole teardown runs under one try: a hard COM access violation can
	; occur mid-sequence, and a bare per-line `try` only catches ordinary AHK
	; exceptions — it does NOT catch that class of failure, but wrapping the
	; sequence still protects the *other* lines from a preceding non-fatal COM
	; error so the globals below are always cleared even when the unsubscribe
	; itself fails.
	try {
		; Release the subscriptions FIRST, while the controller is still alive. Their
		; __Delete unsubscribes via remove_X on the live controller; doing it AFTER
		; Controller.Close() raises a COM error that — uncaught in the window's
		; Close-event thread — terminates the entire AHK script.
		_HCWWeb_MsgSub := unset
		_HCWWeb_NavSub := unset
		if IsSet(_HCWWeb_Controller)
			_HCWWeb_Controller.Close()
	}
	_HCWWeb_Controller := unset
	_HCWWeb_WebView    := unset
}
