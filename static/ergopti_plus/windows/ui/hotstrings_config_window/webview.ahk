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





; ===================================
; ===================================
; ======= 1/ Lifecycle / open =======
; ===================================
; ===================================

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
global _HCWWeb_SessionEpoch := 0

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
	global _HCWWeb_MsgSub, _HCWWeb_NavSub, _HCWWeb_ResetDone, _HCWWeb_SessionEpoch
	global _VendorDir, _SharedDir

	if !_HCWWeb_Available()
		return false

	; Refresh only the captured singleton. Any data/page callout may close it.
	if (_HCWWeb_Gui != 0) {
		Window := _HCWWeb_Gui, SessionEpoch := _HCWWeb_SessionEpoch
		_HCW_InitLocaleStrings()
		if !_HCWWeb_StartupCurrent(SessionEpoch, Window)
			return true
		_HCW_BuildCategoryList()
		if !_HCWWeb_StartupCurrent(SessionEpoch, Window)
			return true
		_HCW_BuildGroupList()
		if !_HCWWeb_StartupCurrent(SessionEpoch, Window)
			return true
		_HCWWeb_PushState()
		if _HCWWeb_StartupCurrent(SessionEpoch, Window)
			WMPresentWindow(_HCWWeb_Gui)
		return true
	}
	PreviousCritical := Critical("On")
	try {
		if _HCWWeb_Gui != 0
			return true
		_HCWWeb_SessionEpoch += 1
		SessionEpoch := _HCWWeb_SessionEpoch
		_HCWWeb_ResetDone := false
	} finally Critical(PreviousCritical)

	; Keep the delivered data builders, but stop a retired opening before it
	; acquires a native window or publishes resources into a replacement.
	_HCW_InitLocaleStrings()
	if !_HCWWeb_OpeningCurrent(SessionEpoch)
		return true
	_HCW_BuildCategoryList()
	if !_HCWWeb_OpeningCurrent(SessionEpoch)
		return true
	_HCW_BuildGroupList()
	if !_HCWWeb_OpeningCurrent(SessionEpoch)
		return true

	g := Gui_Create("+Resize +MinSize560x320", t("hs_config.window_title"))
	Installed := false, FactoryFailed := false, ResetForFallback := false
	try {
		if !_HCWWeb_OpeningCurrent(SessionEpoch)
			return true
		g.BackColor := "0x1e1e1e"
		g.MarginX := 0
		g.MarginY := 0
		Placeholder := g.Add("Text", "x0 y0 w" . HCWWEB_WIDTH . " h" . HCWWEB_HEIGHT, "")
		g.OnEvent("Close", _HCWWeb_SessionCall.Bind(SessionEpoch, _HCWWeb_OnClose))
		g.OnEvent("Size", _HCWWeb_SessionCall.Bind(SessionEpoch, _HCWWeb_OnResize))

		; Native Show can dispatch Close. Publish the exact GUI first; a retired
		; Show frame must never re-publish it after that native pump returns.
		Published := false
		PreviousCritical := Critical("On")
		try {
			if _HCWWeb_OpeningCurrent(SessionEpoch) {
				_HCWWeb_Gui := g
				Published := true
			}
		} finally Critical(PreviousCritical)
		if !Published || !_HCWWeb_StartupCurrent(SessionEpoch, g)
			return true
		g.Show("w" . HCWWEB_WIDTH . " h" . HCWWEB_HEIGHT . " Center")
		if !_HCWWeb_StartupCurrent(SessionEpoch, g)
			return true

		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		try {
			Environment := WebView_SharedEnvironment(loader)
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			Controller := WebView2.create(Placeholder.Hwnd, , Environment)
		} catch as Err {
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			try LoggerError("HotstringsConfigWindow", "WebView2 create failed: {1} — falling back to native Gui.", Err.Message)
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			FactoryFailed := true
		}
		if !FactoryFailed {
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			View := Controller.CoreWebView2
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true

			try {
				s := View.Settings
				if !_HCWWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.AreDevToolsEnabled := false
				if !_HCWWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.AreDefaultContextMenusEnabled := false
				if !_HCWWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.IsStatusBarEnabled := false
				if !_HCWWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.AreBrowserAcceleratorKeysEnabled := false
				if !_HCWWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.IsSwipeNavigationEnabled := false
			}
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true

			MsgSub := View.WebMessageReceived(_HCWWeb_OnWebMessage.Bind(SessionEpoch))
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			NavSub := View.NavigationCompleted(_HCWWeb_OnNavigationCompleted.Bind(SessionEpoch))
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			try View.SetVirtualHostNameToFolderMapping(HCWWEB_VHOST, _SharedDir, HCWWEB_HOST_ACCESS_ALLOW)
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			Seed := _HCWWeb_I18nSeed()
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			try View.AddScriptToExecuteOnDocumentCreated(Seed)

			; Globals retain subscription references before the aliases leave this
			; RAM-only transaction; no COM call or final reference release occurs inside it.
			PreviousCritical := Critical("On")
			try {
				if _HCWWeb_StartupCurrent(SessionEpoch, g) {
					_HCWWeb_Controller := Controller
					_HCWWeb_WebView := View
					_HCWWeb_MsgSub := MsgSub
					_HCWWeb_NavSub := NavSub
					MsgSub := unset
					NavSub := unset
					Installed := true
				}
			} finally Critical(PreviousCritical)
			if !Installed || !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true

			try View.Navigate(_HCWWeb_HtmlUrl())
			if !_HCWWeb_StartupCurrent(SessionEpoch, g)
				return true
			try Controller.Fill()
			if _HCWWeb_StartupCurrent(SessionEpoch, g)
				try LoggerSuccess("HotstringsConfigWindow", "Hotstrings config window shown via WebView2.")
			return true
		}
	} finally {
		if !Installed {
			; Revoke only this opening before private unsubscribe/Close/Destroy
			; can pump callbacks. A stale frame never Reset()s its successor.
			ResetForFallback := _HCWWeb_Reset(SessionEpoch, g)
			try MsgSub := unset
			try NavSub := unset
			if IsSet(Controller) {
				try Controller.Close()
				catch as Err
					try LoggerError("HotstringsConfigWindow", "Retired browser cleanup failed: {1}.", Err.Message)
			}
			try g.Destroy()
		}
	}
	; Only now have all private cleanup callouts completed. A later session
	; cannot lend its authority to this failed opening's native fallback.
	return !(FactoryFailed && ResetForFallback && _HCWWeb_FallbackCurrent(SessionEpoch + 1))
}





; ====================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ====================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 channel, so each message is an object {action, …}. Work is
; deferred out of the COM callback (SetTimer -1) so the follow-up push never runs
; re-entrantly inside the event callback.
_HCWWeb_OnWebMessage(SessionEpoch, Handler, Args) {
	if !_HCWWeb_SessionCurrent(SessionEpoch)
		return
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
		SetTimer(_HCWWeb_SessionCall.Bind(SessionEpoch, _HCWWeb_PushState), -1)
		return
	}
	SetTimer(_HCWWeb_SessionCall.Bind(SessionEpoch, _HCWWeb_Dispatch, Payload), -1)
}

; Push the initial state once the page has finished loading (the frontend also
; emits a best-effort "ready", so this fires whichever arrives — both idempotent).
_HCWWeb_OnNavigationCompleted(SessionEpoch, Handler, Args) {
	SetTimer(_HCWWeb_SessionCall.Bind(SessionEpoch, _HCWWeb_PushState), -1)
}

_HCWWeb_SessionCurrent(SessionEpoch) {
	global _HCWWeb_SessionEpoch
	return SessionEpoch == _HCWWeb_SessionEpoch
}

; An opening without a published native owner cannot borrow another session.
_HCWWeb_OpeningCurrent(SessionEpoch) {
	global _HCWWeb_Gui, _HCWWeb_ResetDone
	return _HCWWeb_SessionCurrent(SessionEpoch) && !_HCWWeb_ResetDone && _HCWWeb_Gui == 0
}

; Every yielding startup operation must retain the exact native session owner.
_HCWWeb_StartupCurrent(SessionEpoch, Window) {
	global _HCWWeb_Gui, _HCWWeb_ResetDone
	return _HCWWeb_SessionCurrent(SessionEpoch) && !_HCWWeb_ResetDone && _HCWWeb_Gui == Window
}

; Only a failed opening's exact retired epoch may admit the native fallback.
_HCWWeb_FallbackCurrent(SessionEpoch) {
	global _HCWWeb_Gui, _HCWWeb_ResetDone
	return _HCWWeb_SessionCurrent(SessionEpoch) && _HCWWeb_ResetDone && _HCWWeb_Gui == 0
}

_HCWWeb_SessionCall(SessionEpoch, Callback, Params*) {
	if !_HCWWeb_SessionCurrent(SessionEpoch)
		return false
	Callback(Params*)
	return true
}

; Apply one mutation message, then push the rebuilt state. Mirrors the macOS
; on_message dispatch: bulk actions hit every category, per-entry actions resolve
; the entry by its key and route through the shared write helpers.
_HCWWeb_Dispatch(Payload) {
	if A_IsSuspended
		return false
	Action := Payload.Has("action") ? Payload["action"] : ""

	if (Action == "close") {
		_HCWWeb_Close()
		return
	}
	if (Action == "reset_all") {
		Outcome := _HCWWeb_ResetAll()
		if !Outcome["ok"] && !Outcome["failure_reported"]
			_HCW_ReportWriteFailure(Outcome)
		return Outcome["ok"]
	}
	if (Action == "set_all_grey") {
		Outcome := _HCWWeb_SetAllGrey()
		if !Outcome["ok"] && !Outcome["failure_reported"]
			_HCW_ReportWriteFailure(Outcome)
		return Outcome["ok"]
	}

	CatKey := Payload.Has("category") ? Payload["category"] : ""
	Entry  := _HCWWeb_FindEntry(CatKey)
	if !IsObject(Entry)
		return
	Sec := (Payload.Has("section") && Payload["section"] != "") ? Payload["section"] : ""

	WriteFn := 0
	switch Action {
		case "set_delay":
			if Payload.Has("ms") && (Payload["ms"] is Integer)
					&& TickTryDurationMsFromSeconds(Payload["ms"] / 1000, &DelayMs) {
				WriteFn := _HCW_SetOverride.Bind(Entry, Sec, "delay", DelayMs / 1000)
			}
		case "clear_delay":
			WriteFn := _HCW_ClearOverride.Bind(Entry, Sec, "delay")
		case "set_color":
			if (Payload.Has("hex") && Payload["hex"] != "")
				WriteFn := _HCW_SetOverride.Bind(Entry, Sec, "color", Payload["hex"])
		case "clear_color":
			WriteFn := _HCW_ClearOverride.Bind(Entry, Sec, "color")
		case "set_priority":
			if Payload.Has("priority")
				WriteFn := _HCW_SetOverride.Bind(Entry, Sec, "priority", Payload["priority"])
		case "clear_priority":
			WriteFn := _HCW_ClearOverride.Bind(Entry, Sec, "priority")
		case "set_tooltip":
			if Payload.Has("show_tooltip")
					&& HotstringsTryBooleanOverride(
						Payload["show_tooltip"], &TooltipValue) {
				WriteFn := _HCW_SetOverride.Bind(
					Entry, Sec, "show_tooltip", TooltipValue)
			}
		case "clear_tooltip":
			WriteFn := _HCW_ClearOverride.Bind(Entry, Sec, "show_tooltip")
		default:
			return
	}
	if !HasMethod(WriteFn, "Call")
		return false
	Outcome := _HCW_RunWriteBatch([WriteFn], _HCWWeb_ReconcileState.Bind(),
		0, _HCW_ReportWriteFailure.Bind())
	return Outcome["ok"]
}

_HCWWeb_ReconcileState(Outcome) {
	_HCWWeb_PushState()
}

_HCWWeb_ReconcileReset(Outcome) {
	if Outcome["succeeded"] > 0
		_HCW_RepublishIfBakedField("delay")
	_HCWWeb_PushState()
}

_HCWWeb_ReportResetSuccess(Outcome) {
	TrayTip(t("hs_config.notify_reset_all"), t("hs_config.btn_reset_all"), "Iconi Mute")
}

; Clear every override across all categories (common / personal / extension),
; matching the native _HCW_ResetAll loop minus the Gui teardown.
_HCWWeb_ResetAll() {
	global _HCW_CATEGORY_LIST
	; Match the native action: Reset All supersedes pending numeric candidates,
	; so cancel them without first performing writes that the loop will erase.
	_HCW_CancelAllNumericWrites()
	Writes := _HCW_BuildResetAllWrites(_HCW_CATEGORY_LIST)
	return _HCW_RunWriteBatch(Writes, _HCWWeb_ReconcileReset.Bind(),
		_HCWWeb_ReportResetSuccess.Bind())
}

; Force every category/extension to grey at file level and clear per-section
; colour overrides so the grey cascades down. Mirrors the native _HCW_SetAllGrey.
_HCWWeb_SetAllGrey() {
	global _HCW_CATEGORY_LIST, HCWWEB_GREY
	Writes := []
	for _, E in _HCW_CATEGORY_LIST {
		if E.IsPersonal {
			Writes.Push(_HCW_PatchTomlMeta.Bind(E.Path, "", "color", HCWWEB_GREY))
			for _, Sec in _HCW_GetSections(E)
				Writes.Push(_HCW_PatchTomlMeta.Bind(E.Path, Sec.Name, "color", ""))
		} else if E.IsExtension {
			Writes.Push(HotstringsSetOverride.Bind("ext." . E.ExtId, "", "color", HCWWEB_GREY))
			for _, Sec in _HCW_GetSections(E)
				Writes.Push(HotstringsClearOverride.Bind("ext." . E.ExtId, Sec.Name, "color"))
		} else {
			Writes.Push(HotstringsSetOverride.Bind(E.Key, "", "color", HCWWEB_GREY))
			for _, Sec in _HCW_GetSections(E)
				Writes.Push(HotstringsClearOverride.Bind(E.Key, Sec.Name, "color"))
		}
	}
	return _HCW_RunWriteBatch(Writes, _HCWWeb_ReconcileState.Bind())
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





; ===================================
; ===================================
; ======= 3/ State serializer =======
; ===================================
; ===================================

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





; =====================================
; =====================================
; ======= 4/ Helpers / teardown =======
; =====================================
; =====================================

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
	return JsonStringLiteral(s)
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
	WebView_RunScriptAsync(_HCWWeb_WebView, Js, "HotstringsConfig")
}

_HCWWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _HCWWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_HCWWeb_Controller)
		try _HCWWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) and the frontend "close" button both land here.
_HCWWeb_OnClose(Window, *) {
	_HCWWeb_Close(0, Window)
}

_HCWWeb_Close(ExpectedEpoch := 0, Window := 0) {
	global _HCWWeb_Gui, _HCWWeb_SessionEpoch
	PreviousCritical := Critical("On")
	try {
		if Window && _HCWWeb_Gui != Window
			return false
		if ExpectedEpoch && ExpectedEpoch != _HCWWeb_SessionEpoch
			return false
		Window := _HCWWeb_Gui
		ExpectedEpoch := _HCWWeb_SessionEpoch
	} finally Critical(PreviousCritical)
	if !_HCWWeb_Reset(ExpectedEpoch, Window)
		return false
	; Reset detached every global before any unsubscribe/controller callout.
	; Destroy may open a successor, so nothing writes the globals afterwards.
	if IsObject(Window)
		try Window.Destroy()
	return true
}

; Detaches the exact current host, then releases only its captured resources.
; The native GUI is not destroyed here; its owner decides whether to destroy it.
_HCWWeb_Reset(ExpectedEpoch := 0, Window := 0) {
	global _HCWWeb_Gui, _HCWWeb_Controller, _HCWWeb_WebView, _HCWWeb_MsgSub, _HCWWeb_NavSub
	global _HCWWeb_ResetDone, _HCWWeb_SessionEpoch
	PreviousCritical := Critical("On")
	try {
		if ExpectedEpoch && !_HCWWeb_StartupCurrent(ExpectedEpoch, Window)
			return false
		if _HCWWeb_ResetDone
			return false
		; Keep all references alive across Critical restoration. Clearing globals
		; cannot invoke COM/GUI finalizers while the retirement is only partial.
		RetiredWindow := _HCWWeb_Gui
		if IsSet(_HCWWeb_Controller)
			RetiredController := _HCWWeb_Controller
		if IsSet(_HCWWeb_WebView)
			RetiredView := _HCWWeb_WebView
		if IsSet(_HCWWeb_MsgSub)
			RetiredMsgSub := _HCWWeb_MsgSub
		if IsSet(_HCWWeb_NavSub)
			RetiredNavSub := _HCWWeb_NavSub
		_HCWWeb_ResetDone := true
		_HCWWeb_SessionEpoch += 1
		_HCWWeb_Gui := 0
		_HCWWeb_MsgSub := unset
		_HCWWeb_NavSub := unset
		_HCWWeb_Controller := unset
		_HCWWeb_WebView := unset
	} finally Critical(PreviousCritical)

	; Actual unsubscribe precedes Controller.Close after restoring the caller's
	; Critical state. These references remain owned if a callout opens a successor.
	try RetiredMsgSub := unset
	try RetiredNavSub := unset
	if IsSet(RetiredController)
		try RetiredController.Close()
	return true
}
