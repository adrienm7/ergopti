; ui/personal_toml_editor_webview.ahk

; ==============================================================================
; MODULE: Personal Hotstring Editor / WebView2 Host
; DESCRIPTION:
; Renders the personal-hotstring editor with an embedded WebView2 control that
; loads the cross-driver frontend at _shared/ui/hotstring_editor/ — the SAME
; HTML/JS/CSS the macOS driver uses — instead of the native AHK Gui in
; personal_toml_editor.ahk. The native Gui remains as a graceful fallback: when
; WebView2 is unavailable, OpenPersonalEditor falls through to it.
;
; FEATURES & RATIONALE:
; 1. Shared UX: one editor frontend for both drivers — fixing a wording or a
;    behaviour there updates Windows and macOS at once. The bridge mirrors the
;    proven onboarding WebView2 host (infra/webview_utils + vendor/WebView2), and
;    carries the same four hard-won gotcha fixes (see PROJECT_MEMORY
;    project-webview2-bridge-gotchas): show-before-create, virtual-host origin,
;    stored WebMessageReceived subscription, and fire-and-forget ExecuteScript.
; 2. Reuses the native I/O: ReadPersonalToml / WritePersonalToml /
;    ReloadPersonalSection (personal_toml_editor.ahk) are the single source of
;    truth for the on-disk format and the live re-registration, so the webview
;    and native editors write byte-identical TOML and reload identically.
; 3. i18n via the shared i18n.js fetch model (like model_browser): the locale
;    base + active locale are seeded before page scripts run, and i18n.js fetches
;    the matching JSON over the same virtual host.
;
; Functions/globals are hoisted; #Include'd from ui/personal_toml_editor.ahk's
; neighbour list in ErgoptiPlus.ahk.
; ==============================================================================

; Virtual host mapped to the _shared tree so the editor loads from a stable
; origin (https://<host>/…) instead of an opaque file:// origin — file:// pages
; are unique security origins and the chrome.webview JS->AHK channel does not
; reliably deliver from them (see PROJECT_MEMORY project-webview2-bridge-gotchas).
; One host covers the frontend (ui/hotstring_editor/), the shared i18n.js
; (ui/i18n.js) and the locale JSON (data/locales/).
global HSED_VHOST := "ergopti.hotstrings"   ; -> _SharedDir
; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW.
global HSED_HOST_ACCESS_ALLOW := 1

; WebView2 host state. The editor is a singleton: re-opening focuses the live
; window instead of spawning a second one (mirrors the native _PersonalEditorGui).
global _HsEdWeb_Gui        := 0
global _HsEdWeb_Controller := unset
global _HsEdWeb_WebView    := unset
; Subscription handles returned by WebMessageReceived/NavigationCompleted. The
; binding ties each event subscription to its handle's LIFETIME (its __Delete
; unsubscribes), so both MUST be kept alive in persistent globals.
global _HsEdWeb_MsgSub     := unset
global _HsEdWeb_NavSub     := unset
; True once _HsEdWeb_Reset() has torn the controller down. Both the JS "close"
; message and the Gui "Close" event route through _HsEdWeb_Close(), so a
; double-close (e.g. the frontend's close button firing, followed by Windows
; delivering the native Close event for the same destroy) can invoke Reset()
; twice against a controller that is already gone — the second pass's
; remove_WebMessageReceived ComCall then dereferences a freed COM pointer,
; which is a hard access violation no AHK try/catch can intercept. The flag
; makes the second call a true no-op instead of reaching that ComCall at all.
global _HsEdWeb_ResetDone  := false
global _HsEdWeb_SessionEpoch := 0




; ==============================================================
; =========================================
; ======= 1/ Availability + launch ========
; =========================================
; ==============================================================

; Returns true when the WebView2 runtime binding + loader DLL are present. Like
; onboarding (and unlike model_browser) the editor does not apply the low-RAM
; native fallback: WebView2.create is still wrapped in a try/catch that degrades
; to the native Gui if the control genuinely cannot be created.
_HsEdWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Attempts to show the editor in a WebView2 window. Returns true on success (the
; caller must NOT also build the native Gui), false to fall back. Singleton:
; focuses an already-open editor instead of opening a second one.
; @param DefaultSection string Section to pre-select (currently advisory; the
;        frontend restores its own default-section preference).
_HsEdWeb_TryOpen(DefaultSection := "") {
	global _HsEdWeb_Gui, _HsEdWeb_Controller, _HsEdWeb_WebView, _HsEdWeb_MsgSub, _HsEdWeb_NavSub
	global _HsEdWeb_ResetDone, _HsEdWeb_SessionEpoch
	global _VendorDir, _SharedDir

	if !_HsEdWeb_Available()
		return false

	; Singleton — bring the existing editor to the front.
	if (_HsEdWeb_Gui != 0) {
		try WinActivate("ahk_id " . _HsEdWeb_Gui.Hwnd)
		return true
	}
	_HsEdWeb_SessionEpoch += 1
	SessionEpoch := _HsEdWeb_SessionEpoch
	_HsEdWeb_ResetDone := false

	g := Gui("+Resize +MinSize720x520", t("editor.hotstrings.window_title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w960 h640", "")
	g.OnEvent("Close", _HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_OnClose))
	g.OnEvent("Size",  _HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_OnResize))

	; Show BEFORE creating the control: creating/Fill()-ing against a hidden Gui
	; sizes the control to a zero client rect (blank page that never lays out).
	g.Show("w960 h640 Center")
	_HsEdWeb_Gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_HsEdWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("HsEditor", "WebView2 create failed: {1} — falling back to native editor.", Err.Message)
		try g.Destroy()
		_HsEdWeb_Reset()
		_HsEdWeb_Gui := 0
		return false
	}

	_HsEdWeb_WebView := _HsEdWeb_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so the
	; NEXT close actually tears it down instead of short-circuiting on the flag
	; left behind by a previous editor session.

	; Harden the surface — no devtools, context menu, status bar, accelerators.
	try {
		s := _HsEdWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; JS -> AHK bridge. Store the subscription handle in a persistent global —
	; discarding it lets the binding GC it and silently unsubscribe the handler.
	global _HsEdWeb_MsgSub := _HsEdWeb_WebView.WebMessageReceived(_HsEdWeb_OnWebMessage.Bind(SessionEpoch))
	; The frontend never posts a "ready" action, so push initData once the page
	; has finished loading (and i18n.js has run). Subscription stored for the
	; same lifetime reason as the message handler.
	global _HsEdWeb_NavSub := _HsEdWeb_WebView.NavigationCompleted(_HsEdWeb_OnNavigationCompleted.Bind(SessionEpoch))

	; Map the virtual host BEFORE navigating so the document and every relative
	; asset (style.css, ../i18n.js) and the locale fetch resolve through it.
	try _HsEdWeb_WebView.SetVirtualHostNameToFolderMapping(HSED_VHOST, _SharedDir, HSED_HOST_ACCESS_ALLOW)

	; Seed the i18n base + active locale before page scripts run, so the shared
	; i18n.js fetches the right locale JSON over the virtual host (model_browser
	; pattern). Runs on every document creation.
	try _HsEdWeb_WebView.AddScriptToExecuteOnDocumentCreated(_HsEdWeb_I18nSeed())

	try _HsEdWeb_WebView.Navigate(_HsEdWeb_HtmlUrl())
	try _HsEdWeb_Controller.Fill()

	try LoggerSuccess("HsEditor", "Personal hotstring editor shown via WebView2.")
	return true
}





; ====================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ====================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 channel, so each message is an object {action, data}. Handled
; actions: save, save_pref, window_focus, close.
_HsEdWeb_OnWebMessage(SessionEpoch, Handler, Args) {
	if !_HsEdWeb_SessionCurrent(SessionEpoch)
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
	if (A_IsSuspended && Action != "ready") {
		if (Action == "save") {
			try SetTimer(_HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_ShowSaveFailure), -1)
			catch as Err {
				try LoggerError("HsEditor",
					"Could not defer the suspended save refusal: {1}.",
					Err.Message)
				_HsEdWeb_ShowSaveFailure()
			}
		}
		return
	}
	Data   := Payload.Has("data") ? Payload["data"] : Map()
	; Defer out of the COM callback, like every sibling editor host already does
	; (paths_editor, personal_info_editor, prompt_editor). `save` does file I/O
	; plus an N-section live re-registration on the STA callback thread, and
	; `close` tears the controller down from inside its own dispatch — the
	; access-violation class documented in ui/onboarding/webview.ahk. This was the
	; one host that still called them synchronously.
	if (Action == "save") {
		SetTimer(_HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_Save, Data), -1)
	} else if (Action == "save_pref") {
		SetTimer(_HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_SavePref, Data), -1)
	} else if (Action == "close") {
		SetTimer(_HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_Close), -1)
	}
	; window_focus is intentionally ignored on Windows (the native editor has no
	; focus-driven behaviour to mirror).
}

; Pushes the initial editor data once the page has loaded. Deferred out of the
; NavigationCompleted COM callback (SetTimer -1) so the ExecuteScript never runs
; re-entrantly inside the event callback.
_HsEdWeb_OnNavigationCompleted(SessionEpoch, Handler, Args) {
	SetTimer(_HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_PushInitData), -1)
}

_HsEdWeb_SessionCurrent(SessionEpoch) {
	global _HsEdWeb_SessionEpoch
	return SessionEpoch == _HsEdWeb_SessionEpoch
}

_HsEdWeb_SessionCall(SessionEpoch, Callback, Params*) {
	if !_HsEdWeb_SessionCurrent(SessionEpoch)
		return false
	Callback(Params*)
	return true
}

_HsEdWeb_PushInitData() {
	_HsEdWeb_Eval(_HsEdWeb_InitDataJs())
}

; Evaluates JS in the page using ExecuteScriptAsync FIRE-AND-FORGET (no .await()):
; the convenience ExecuteScript() is ExecuteScriptAsync().await(), and that nested
; await loop can wedge the AHK thread. We do not need the result, so we drop the
; promise; WebView2 still runs the script.
_HsEdWeb_Eval(Js) {
	global _HsEdWeb_WebView
	if !IsSet(_HsEdWeb_WebView)
		return
	try {
		_HsEdWeb_WebView.ExecuteScriptAsync(Js)
	} catch as e {
		try LoggerError("HsEditor", "ExecuteScriptAsync failed (len={1}): {2}.", StrLen(Js), e.Message)
	}
}




; ==============================================================
; =====================================
; ======= 3/ Message handlers =========
; =====================================
; ==============================================================

; Persists the editor state to disk and live-reloads the affected sections.
; ``Data`` is the parsed save payload: {sections_order: [...], sections: {name ->
; {description, entries: [...]}}}. That shape already matches WritePersonalToml's
; input (a keyed sections Map + an order Array), so we forward it directly after
; attaching the meta description.
_HsEdWeb_ShowSaveFailure() {
	Message := _HsEdWeb_JsStr(t("editor.hotstrings.err_write"))
	_HsEdWeb_Eval('(function(){const e=document.getElementById("save-toast");'
		. 'if(e){e.textContent="' . Message
		. '";e.classList.add("show");}})();')
}

_HsEdWeb_ReportSaveFailure() {
	try LoggerError("HsEditor",
		"Personal-hotstring durable/live publication failed — the save did not complete.")
	try _HsEdWeb_ShowSaveFailure()
	try NotifierSend(t("editor.hotstrings.err_write"),
		Map("title", t("editor.hotstrings.save_error"), "level", "error"))
}

_HsEdWeb_DeferredSaveCompleted(CommitResult) {
	global PERSONAL_TOML_COMMIT_FAILED
	if (CommitResult == PERSONAL_TOML_COMMIT_FAILED) {
		if A_IsSuspended {
			try LoggerError("HsEditor",
				"The deferred personal-hotstring save was refused after Suspend became active.")
			_HsEdWeb_ShowSaveFailure()
		} else {
			_HsEdWeb_ReportSaveFailure()
		}
		return
	}
	try LoggerSuccess("HsEditor",
		"Deferred personal hotstrings saved and reloaded.")
}

_HsEdWeb_Save(Data) {
	if A_IsSuspended {
		_HsEdWeb_ShowSaveFailure()
		return
	}
	if (!(Data is Map) || !Data.Has("sections_order") || !Data.Has("sections"))
		return
	order := Data["sections_order"]
	secs  := Data["sections"]
	if (!(order is Array) || !(secs is Map))
		return

	WriteData := Map(
		"meta_description", t("editor.hotstrings.meta_desc"),
		"sections_order", order,
		"sections", secs,
	)

	try LoggerStart("HsEditor", "Saving personal hotstrings ({1} section(s))…", order.Length)
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_DEFERRED
	CommitResult := PersonalTomlCommitAndReload(WriteData,
		0, 0, 0, 0, 0, 0, _HsEdWeb_DeferredSaveCompleted.Bind())
	if (CommitResult == PERSONAL_TOML_COMMIT_FAILED) {
		if A_IsSuspended
			_HsEdWeb_ShowSaveFailure()
		else
			_HsEdWeb_ReportSaveFailure()
		return
	}
	if (CommitResult == PERSONAL_TOML_COMMIT_DEFERRED) {
		try LoggerInfo("HsEditor", "Personal-hotstring publication was deferred behind an active writer; the newest full snapshot will be committed next.")
		return
	}
	try LoggerSuccess("HsEditor", "Personal hotstrings saved and reloaded.")
}

; Persists a single UI preference. The frontend uses its own key names
; (compact_view / auto_close / default_section); map them onto the native
; [personal_editor] keys so the native editor and the webview agree.
_HsEdWeb_SavePref(Data) {
	if A_IsSuspended
		return false
	if (!(Data is Map) || !Data.Has("key"))
		return
	key := Data["key"]
	val := Data.Has("value") ? Data["value"] : ""
	if (key == "compact_view") {
		_EditorPrefSet("compact_view", _HsEdWeb_Truthy(val) ? "1" : "0")
	} else if (key == "auto_close") {
		_EditorPrefSet("close_on_add", _HsEdWeb_Truthy(val) ? "1" : "0")
	} else if (key == "default_section") {
		_EditorPrefSet("default_section", val == "" ? "" : String(val))
	}
}

; Closes the editor window (frontend "close" button / Esc).
_HsEdWeb_Close() {
	global _HsEdWeb_Gui
	saved := (_HsEdWeb_Gui != 0) ? _HsEdWeb_Gui : 0
	_HsEdWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_HsEdWeb_Gui := 0
}




; ==============================================================
; ===================================
; ======= 4/ initData source ========
; ===================================
; ==============================================================

; Builds the window.initData({...}) call from the on-disk personal hotstrings.
; Pivots ReadPersonalToml's keyed sections Map + order Array into the frontend's
; ordered sections array, drops AHK-only entry fields (strict_case, line_index),
; and emits per-entry priority ONLY when set (absent == inherit), then attaches
; the seven UI prefs.
_HsEdWeb_InitDataJs() {
	data    := ReadPersonalToml()
	order   := data.Has("sections_order") ? data["sections_order"] : []
	secMap  := data.Has("sections") ? data["sections"] : Map()

	secsJs := "", firstSec := true
	for _, name in order {
		if (name == "-" || name == "")
			continue
		sec     := secMap.Has(name) ? secMap[name] : Map()
		desc    := sec.Has("description") ? sec["description"] : name
		entries := sec.Has("entries") ? sec["entries"] : []

		entriesJs := "", firstEntry := true
		for _, e in entries {
			entry := "{trigger:" . _HsEdWeb_JsStr(e.Has("trigger") ? e["trigger"] : "")
				. ",output:" . _HsEdWeb_JsStr(e.Has("output") ? e["output"] : "")
				. ",is_word:" . ((e.Has("is_word") && e["is_word"]) ? "true" : "false")
				. ",auto_expand:" . ((e.Has("auto_expand") && e["auto_expand"]) ? "true" : "false")
				. ",is_case_sensitive:" . ((e.Has("is_case_sensitive") && e["is_case_sensitive"]) ? "true" : "false")
				. ",final_result:" . ((e.Has("final_result") && e["final_result"]) ? "true" : "false")
			if (e.Has("priority") && e["priority"] != "")
				entry .= ",priority:" . e["priority"]
			entry .= "}"
			entriesJs .= (firstEntry ? "" : ",") . entry
			firstEntry := false
		}

		secObj := "{name:" . _HsEdWeb_JsStr(name)
			. ",description:" . _HsEdWeb_JsStr(desc)
			. ",entries:[" . entriesJs . "]}"
		secsJs .= (firstSec ? "" : ",") . secObj
		firstSec := false
	}

	compact   := (_EditorPrefGet("compact_view", "0") == "1") ? "true" : "false"
	autoClose := (_EditorPrefGet("close_on_add", "0") == "1") ? "true" : "false"
	defSec    := _EditorPrefGet("default_section", "")
	defSecJs  := (defSec == "") ? "null" : _HsEdWeb_JsStr(defSec)
	defPrio   := _GetSharedPersonalDefault()
	defPrioJs := (defPrio != "" && IsNumber(defPrio)) ? defPrio : "null"

	js := "window.initData({sections:[" . secsJs . "]"
		. ",trigger_char:" . _HsEdWeb_JsStr(_HsEdWeb_TriggerChar())
		. ",star:" . _HsEdWeb_JsStr(Chr(0x2605))
		. ",compact_view:" . compact
		. ",auto_close:" . autoClose
		. ",default_section:" . defSecJs
		. ",default_priority:" . defPrioJs
		. ",open_mode:" . _HsEdWeb_JsStr("menu")
		. "})"
	return js
}

; The display trigger character: the user's configured magic key (the frontend
; renders ★ as this), falling back to the canonical star.
_HsEdWeb_TriggerChar() {
	if (IsSet(ScriptInformation) && ScriptInformation is Map && ScriptInformation.Has("MagicKey")
		&& ScriptInformation["MagicKey"] != "")
		return ScriptInformation["MagicKey"]
	return Chr(0x2605)
}

; Builds the seed script injected before page scripts: the i18n base URL (served
; via the virtual host) and the active locale, consumed by the shared i18n.js.
_HsEdWeb_I18nSeed() {
	global HSED_VHOST, _I18nLocale
	loc := IsSet(_I18nLocale) ? _I18nLocale : "en"
	return "window.__i18n_base='https://" . HSED_VHOST . "/data/locales/';"
		. "window._i18n_locale='" . loc . "';"
}

; Virtual-host URL for the editor's index.html (served from _SharedDir via
; HSED_VHOST). A per-open cache-buster forces a fresh document each launch
; (WebView2 caches virtual-host resources); the page's own ?v= queries on
; script.js/style.css refresh those when they change.
_HsEdWeb_HtmlUrl() {
	global HSED_VHOST
	return "https://" . HSED_VHOST . "/ui/hotstring_editor/index.html?cb=" . A_TickCount
}




; ==============================================================
; =============================
; ======= 5/ Utilities ========
; =============================
; ==============================================================

; Coerces a JSON-decoded value to a boolean (JsonParse may yield real booleans,
; 0/1, or the strings "true"/"false").
_HsEdWeb_Truthy(v) {
	return (v == true || v == 1 || v == "true" || v == "1")
}

; Escapes a string for safe injection into a JS double-quoted literal.
_HsEdWeb_JsStr(s) {
	return JsonStringLiteral(s)
}

_HsEdWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _HsEdWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_HsEdWeb_Controller)
		try _HsEdWeb_Controller.Fill()
}

; Window-close (X / Alt+F4): drop the controller, clear the singleton sentinel.
_HsEdWeb_OnClose(*) {
	_HsEdWeb_Close()
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. the JS "close"
; message and the native Gui "Close" event both firing for the same teardown) is
; a true no-op instead of touching the globals again.
_HsEdWeb_Reset() {
	global _HsEdWeb_Controller, _HsEdWeb_WebView, _HsEdWeb_MsgSub, _HsEdWeb_NavSub
	global _HsEdWeb_ResetDone, _HsEdWeb_SessionEpoch

	; A prior Reset() already released remove_WebMessageReceived/remove_NavigationCompleted
	; against this controller. Re-running the unset lines below would call __Delete's
	; bound ComCall a SECOND time against a COM pointer WebView2 has already torn down
	; (Controller.Close() releases CoreWebView2's underlying interfaces) — that is a
	; genuine SEH access violation (real crash: "[ComCall] ... remove_WebMessageReceived"),
	; which no try/catch can intercept because it never raises an AHK exception.
	if _HsEdWeb_ResetDone
		return
	_HsEdWeb_ResetDone := true
	_HsEdWeb_SessionEpoch += 1

	; The whole teardown runs under one try: a hard COM access violation can occur
	; mid-sequence (e.g. if the controller was invalidated by the host Gui already
	; being destroyed), and a bare per-line `try` only catches ordinary AHK
	; exceptions — it does NOT catch that class of failure, but wrapping the
	; sequence still protects the *other* lines from a preceding non-fatal COM
	; error (e.g. remove_NavigationCompleted throwing a normal exception) so the
	; globals below are always cleared even when the unsubscribe itself fails.
	try {
		; Release the event subscriptions FIRST, while the controller is still alive.
		; Each handle's __Delete unsubscribes via remove_X on the live controller; doing
		; it AFTER Controller.Close() raises a COM error that — uncaught in the window's
		; Close-event thread — terminates the entire AHK script (so closing the editor
		; would also quit Ergopti+).
		_HsEdWeb_MsgSub := unset
		_HsEdWeb_NavSub := unset
		if IsSet(_HsEdWeb_Controller)
			_HsEdWeb_Controller.Close()
	}
	_HsEdWeb_Controller := unset
	_HsEdWeb_WebView    := unset
}
