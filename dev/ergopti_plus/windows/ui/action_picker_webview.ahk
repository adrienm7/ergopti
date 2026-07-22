; ui/action_picker_webview.ahk

; ==============================================================================
; MODULE: Action Picker WebView2 Host
; DESCRIPTION:
; Renders the action chooser on Windows via WebView2, loading the shared frontend
; at _shared/ui/action_picker/ so the AHK and Hammerspoon drivers show an
; identical searchable, categorised picker. Backs ShowActionPicker
; (ui/action_picker/init.ahk), whose native ListBox remains as a fallback.
; fallback when the WebView2 runtime is unavailable.
;
; FEATURES & RATIONALE:
; 1. Shared frontend — same index.html/script.js/style.css as macOS, resolved
;    through a virtual-host mapping over _SharedDir (file:// is an opaque origin
;    that breaks the JS->AHK channel, so the document is served over https).
; 2. Caller-agnostic — _ActPickWeb_TryOpen takes a pre-built action list
;    ({Id,Label,Cat}) + the OnConfirm callback that every ShowActionPicker call
;    site already supplies; the synthetic "native" pick maps back to "" exactly
;    like the native dialog did.
; 3. Safe teardown — subscription handles are released BEFORE Controller.Close()
;    (their __Delete unsubscribes on the live controller; reversing the order
;    raises a COM error that, uncaught in the Close thread, quits the script).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================================
; ===================================
; ======= 1/ Lifecycle / open =======
; ===================================
; ==============================================================

; Singleton window + WebView2 plumbing. Subscription handles live in globals so
; the binding does not GC them; they are released BEFORE Controller.Close() in
; _ActPickWeb_Reset.
global _ActPickWeb_Gui        := 0
global _ActPickWeb_Controller := unset
global _ActPickWeb_WebView    := unset
global _ActPickWeb_MsgSub     := unset
global _ActPickWeb_NavSub     := unset
; True once _ActPickWeb_Reset() has torn the controller down. _ActPickWeb_Close()
; (and therefore Reset()) is reachable from THREE independent triggers for the
; same window — the native Gui Close event, the frontend "cancel" message, and
; the frontend "confirm" message (_ActPickWeb_Confirm) — plus a re-open of the
; singleton while one is already showing (_ActPickWeb_TryOpen). A second pass's
; unsubscribe line calls remove_WebMessageReceived via ComCall against a
; CoreWebView2 pointer already invalidated by the first pass's
; Controller.Close() — a genuine SEH access violation no AHK try/catch can
; intercept (see personal_toml_editor_webview.ahk _HsEdWeb_ResetDone for the
; crash this mirrors). The flag makes the second call a true no-op instead.
global _ActPickWeb_ResetDone  := false

; The chosen-action callback + the init payload captured at open time.
global _ActPickWeb_OnConfirm  := 0
global _ActPickWeb_InitJs     := ""

; Virtual host that maps to _SharedDir so the document and its relative assets
; (style.css, ../i18n.js) and the locale fetch all resolve over https.
global ACTPICK_VHOST             := "ergopti.actionpicker"
global ACTPICK_HOST_ACCESS_ALLOW := 1

; Window geometry — mirrors the macOS picker panel.
global ACTPICK_WIDTH  := 460
global ACTPICK_HEIGHT := 560

; Returns true when the WebView2 runtime binding + loader DLL are present.
_ActPickWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Attempts to show the action picker in a WebView2 window. Returns true on success
; (the caller must NOT also build the native ListBox), false to fall back.
; Items is an ordered array of headings ({ Type:"heading", Level, Text }) and
; actions ({ Type:"action", Id, Label }); Current is the assigned id ("" means the
; synthetic native pick); OnConfirm(id) is invoked with the chosen id.
_ActPickWeb_TryOpen(Title, Current, Items, OnConfirm, ShowNative := false) {
	global _ActPickWeb_Gui, _ActPickWeb_Controller, _ActPickWeb_WebView
	global _ActPickWeb_MsgSub, _ActPickWeb_NavSub, _ActPickWeb_OnConfirm, _ActPickWeb_InitJs
	global _ActPickWeb_ResetDone
	global _VendorDir, _SharedDir

	if !_ActPickWeb_Available()
		return false

	; Singleton — a second open replaces the previous picker (its callback is
	; superseded), matching the native dialog which only ever shows one.
	if (_ActPickWeb_Gui != 0)
		_ActPickWeb_Close()

	_ActPickWeb_OnConfirm := OnConfirm
	_ActPickWeb_InitJs    := _ActPickWeb_BuildInitJs(Title, Current, Items, ShowNative)

	g := Gui("+Resize +MinSize360x360", Title)
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w" . ACTPICK_WIDTH . " h" . ACTPICK_HEIGHT, "")
	g.OnEvent("Close", _ActPickWeb_OnClose)
	g.OnEvent("Size",  _ActPickWeb_OnResize)

	; Show BEFORE creating the control — a hidden Gui has a zero client rect, so
	; the control lays out blank and never recovers.
	g.Show("w" . ACTPICK_WIDTH . " h" . ACTPICK_HEIGHT . " Center")
	_ActPickWeb_Gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_ActPickWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("ActionPicker", "WebView2 create failed: {1} — falling back to native dialog.", Err.Message)
		try g.Destroy()
		_ActPickWeb_Reset()
		_ActPickWeb_Gui := 0
		return false
	}

	_ActPickWeb_WebView := _ActPickWeb_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a
	; flag left behind by an earlier _ActPickWeb_Reset() call.
	_ActPickWeb_ResetDone := false

	try {
		s := _ActPickWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; Store the subscription handles in persistent globals (see header note).
	global _ActPickWeb_MsgSub := _ActPickWeb_WebView.WebMessageReceived(_ActPickWeb_OnWebMessage)
	global _ActPickWeb_NavSub := _ActPickWeb_WebView.NavigationCompleted(_ActPickWeb_OnNavigationCompleted)

	; Map the virtual host BEFORE navigating; seed the i18n base + active locale
	; before page scripts run so the shared i18n.js fetches the right locale JSON.
	try _ActPickWeb_WebView.SetVirtualHostNameToFolderMapping(ACTPICK_VHOST, _SharedDir, ACTPICK_HOST_ACCESS_ALLOW)
	try _ActPickWeb_WebView.AddScriptToExecuteOnDocumentCreated(_ActPickWeb_I18nSeed())
	try _ActPickWeb_WebView.Navigate(_ActPickWeb_HtmlUrl())
	try _ActPickWeb_Controller.Fill()

	try LoggerSuccess("ActionPicker", "Action picker shown via WebView2 ({1} item(s)).", Items.Length)
	return true
}





; ==============================================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ==============================================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 channel, so each message is an object {action, …}. Work is
; deferred out of the COM callback (SetTimer -1) so the callback + window teardown
; never run re-entrantly inside the event callback.
_ActPickWeb_OnWebMessage(Handler, Args) {
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
		SetTimer(_ActPickWeb_PushInit, -1)
	} else if (Action == "cancel") {
		SetTimer(_ActPickWeb_Close, -1)
	} else if (Action == "confirm") {
		Id := Payload.Has("id") ? Payload["id"] : ""
		SetTimer(_ActPickWeb_Confirm.Bind(Id), -1)
	}
}

; Push the init payload once the page has finished loading.
_ActPickWeb_OnNavigationCompleted(Handler, Args) {
	SetTimer(_ActPickWeb_PushInit, -1)
}

_ActPickWeb_PushInit() {
	global _ActPickWeb_InitJs
	_ActPickWeb_Eval(_ActPickWeb_InitJs)
}

; Apply the chosen action: map the synthetic native pick back to "" (as the
; native dialog did), close the window, then invoke the caller's callback.
_ActPickWeb_Confirm(Id) {
	global _ActPickWeb_OnConfirm
	cb := _ActPickWeb_OnConfirm
	Mapped := (Id == "__native__") ? "" : Id
	_ActPickWeb_Close()
	if (cb != 0 && cb != "")
		try cb(Mapped)
}





; ==============================================================
; ===================================
; ======= 3/ initData builder =======
; ===================================
; ==============================================================

; Build the `init({...})` call string consumed by the frontend.
_ActPickWeb_BuildInitJs(Title, Current, Items, ShowNative) {
	ItemsJson := ""
	for _, It in Items {
		if (ItemsJson != "")
			ItemsJson .= ","
		if (It.Type == "heading") {
			ItemsJson .= "{"
				. _ActPickWeb_Kv("type", "heading") . ","
				. '"level":' . It.Level . ","
				. _ActPickWeb_Kv("text", It.Text)
				. "}"
		} else {
			ItemsJson .= "{"
				. _ActPickWeb_Kv("type", "action") . ","
				. _ActPickWeb_Kv("id", It.Id) . ","
				. _ActPickWeb_Kv("label", It.Label)
				. "}"
		}
	}

	Json := "{"
		. _ActPickWeb_Kv("title", Title) . ","
		. _ActPickWeb_Kv("label", t("dialog.action_picker.label")) . ","
		. _ActPickWeb_Kv("current", Current) . ","
		. '"allowNative":' . (ShowNative ? "true" : "false") . ","
		. _ActPickWeb_Kv("nativeLabel", t("tap_hold.tap.none")) . ","
		. _ActPickWeb_Kv("noneLabel", t("dialog.action_picker.disabled")) . ","
		. _ActPickWeb_Kv("searchPlaceholder", t("dialog.action_picker.search")) . ","
		. _ActPickWeb_Kv("noResults", t("dialog.action_picker.no_results")) . ","
		. _ActPickWeb_Kv("cancelLabel", t("button.cancel")) . ","
		. '"items":[' . ItemsJson . "]"
		. "}"

	return "if(window.init)window.init(" . Json . ")"
}





; ==============================================================
; =====================================
; ======= 4/ Helpers / teardown =======
; =====================================
; ==============================================================

; Builds one JSON key/value pair (key:"value") with the value safely escaped.
_ActPickWeb_Kv(Key, Value) {
	return '"' . Key . '":' . _ActPickWeb_JsStr(Value)
}

; Quoted, escaped JSON string literal for safe interpolation.
_ActPickWeb_JsStr(s) {
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, '"', '\"')
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`t", "\t")
	return '"' . s . '"'
}

; i18n seed injected before page scripts run: the locale base (served over the
; virtual host) and the active locale, consumed by the shared i18n.js.
_ActPickWeb_I18nSeed() {
	global ACTPICK_VHOST, _I18nLocale
	loc := IsSet(_I18nLocale) ? _I18nLocale : "en"
	return "window.__i18n_base='https://" . ACTPICK_VHOST . "/data/locales/';"
		. "window._i18n_locale='" . loc . "';"
}

; Virtual-host URL for the picker's index.html (served from _SharedDir via the
; vhost). A per-open cache-buster forces a fresh document each launch.
_ActPickWeb_HtmlUrl() {
	global ACTPICK_VHOST
	return "https://" . ACTPICK_VHOST . "/ui/action_picker/index.html?cb=" . A_TickCount
}

; Fire-and-forget script eval. ExecuteScript().await() wedges the thread when
; called from inside a WebView2 callback, so never await here.
_ActPickWeb_Eval(Js) {
	global _ActPickWeb_WebView
	if !IsSet(_ActPickWeb_WebView)
		return
	try _ActPickWeb_WebView.ExecuteScriptAsync(Js)
}

_ActPickWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _ActPickWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_ActPickWeb_Controller)
		try _ActPickWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) and the frontend "cancel" button both land here.
_ActPickWeb_OnClose(*) {
	_ActPickWeb_Close()
}

_ActPickWeb_Close() {
	global _ActPickWeb_Gui
	saved := (_ActPickWeb_Gui != 0) ? _ActPickWeb_Gui : 0
	_ActPickWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_ActPickWeb_Gui := 0
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. the native
; Close event firing after the frontend's "cancel"/"confirm" message already
; tore the same window down) is a true no-op instead of touching the globals
; again.
_ActPickWeb_Reset() {
	global _ActPickWeb_Controller, _ActPickWeb_WebView, _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	global _ActPickWeb_OnConfirm, _ActPickWeb_ResetDone

	; A prior Reset() already released remove_WebMessageReceived/remove_Navigation-
	; Completed against this controller. Re-running the unset lines below would
	; call __Delete's bound ComCall a SECOND time against a COM pointer WebView2
	; has already torn down (Controller.Close() releases CoreWebView2's underlying
	; interfaces) — a genuine SEH access violation that no try/catch can intercept.
	if _ActPickWeb_ResetDone
		return
	_ActPickWeb_ResetDone := true

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
		_ActPickWeb_MsgSub := unset
		_ActPickWeb_NavSub := unset
		if IsSet(_ActPickWeb_Controller)
			_ActPickWeb_Controller.Close()
	}
	_ActPickWeb_Controller := unset
	_ActPickWeb_WebView    := unset
	_ActPickWeb_OnConfirm  := 0
}
