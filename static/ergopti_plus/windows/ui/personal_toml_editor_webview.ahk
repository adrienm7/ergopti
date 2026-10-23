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
global _HsEdWeb_OpeningSource := false




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
	global _HsEdWeb_Gui, _HsEdWeb_Controller, _HsEdWeb_WebView
	global _HsEdWeb_MsgSub, _HsEdWeb_NavSub, _HsEdWeb_ResetDone, _HsEdWeb_SessionEpoch
	global _VendorDir, _SharedDir

	if !_HsEdWeb_Available()
		return false

	; Focus only the captured singleton; presentation may pump native events.
	if (_HsEdWeb_Gui != 0) {
		Window := _HsEdWeb_Gui, SessionEpoch := _HsEdWeb_SessionEpoch
		if _HsEdWeb_StartupCurrent(SessionEpoch, Window)
			WMPresentWindow(Window)
		return true
	}
	PreviousCritical := Critical("On")
	try {
		if _HsEdWeb_Gui != 0
			return true
		_HsEdWeb_SessionEpoch += 1
		SessionEpoch := _HsEdWeb_SessionEpoch
		_HsEdWeb_ResetDone := false
	} finally Critical(PreviousCritical)

	if !_HsEdWeb_OpeningCurrent(SessionEpoch)
		return true

	g := Gui_Create("+Resize +MinSize720x520", t("editor.hotstrings.window_title"))
	Installed := false, FactoryFailed := false, ResetForFallback := false
	try {
		if !_HsEdWeb_OpeningCurrent(SessionEpoch)
			return true
		g.BackColor := "0x1e1e1e"
		g.MarginX := 0
		g.MarginY := 0
		Placeholder := g.Add("Text", "x0 y0 w960 h640", "")
		g.OnEvent("Close", _HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_OnClose))
		g.OnEvent("Size", _HsEdWeb_SessionCall.Bind(SessionEpoch, _HsEdWeb_OnResize))

		; Native Show can dispatch Close. Publish the exact GUI first; a retired
		; Show frame must never re-publish it after that native pump returns.
		Published := false
		PreviousCritical := Critical("On")
		try {
			if _HsEdWeb_OpeningCurrent(SessionEpoch) {
				_HsEdWeb_Gui := g
				Published := true
			}
		} finally Critical(PreviousCritical)
		if !Published || !_HsEdWeb_StartupCurrent(SessionEpoch, g)
			return true
		g.Show("w960 h640 Center")
		if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
			return true

		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		try {
			Environment := WebView_SharedEnvironment(loader)
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			Controller := WebView2.create(Placeholder.Hwnd, , Environment)
		} catch as Err {
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			try LoggerError("HsEditor", "WebView2 create failed: {1} — falling back to native editor.", Err.Message)
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			FactoryFailed := true
		}
		if !FactoryFailed {
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			View := Controller.CoreWebView2
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true

			try {
				s := View.Settings
				if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.AreDevToolsEnabled := false
				if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.AreDefaultContextMenusEnabled := false
				if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.IsStatusBarEnabled := false
				if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.AreBrowserAcceleratorKeysEnabled := false
				if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
					return true
				s.IsSwipeNavigationEnabled := false
			}
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true

			MsgSub := View.WebMessageReceived(_HsEdWeb_OnWebMessage.Bind(SessionEpoch))
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			NavSub := View.NavigationCompleted(_HsEdWeb_OnNavigationCompleted.Bind(SessionEpoch))
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			try View.SetVirtualHostNameToFolderMapping(HSED_VHOST, _SharedDir, HSED_HOST_ACCESS_ALLOW)
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			Seed := _HsEdWeb_I18nSeed()
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			try View.AddScriptToExecuteOnDocumentCreated(Seed)

			; Globals retain subscription references before the aliases leave this
			; RAM-only transaction; no COM call or final reference release occurs inside it.
			PreviousCritical := Critical("On")
			try {
				if _HsEdWeb_StartupCurrent(SessionEpoch, g) {
					_HsEdWeb_Controller := Controller
					_HsEdWeb_WebView := View
					_HsEdWeb_MsgSub := MsgSub
					_HsEdWeb_NavSub := NavSub
					MsgSub := unset
					NavSub := unset
					Installed := true
				}
			} finally Critical(PreviousCritical)
			if !Installed || !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true

			Url := _HsEdWeb_HtmlUrl()
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			try View.Navigate(Url)
			if !_HsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			try Controller.Fill()
			if _HsEdWeb_StartupCurrent(SessionEpoch, g)
				try LoggerSuccess("HsEditor", "Personal hotstring editor shown via WebView2.")
			return true
		}
	} finally {
		if !Installed {
			; Revoke only this opening before private unsubscribe/Close/Destroy
			; can pump callbacks. A stale frame never Reset()s its successor.
			ResetForFallback := _HsEdWeb_Reset(SessionEpoch, g)
			try MsgSub := unset
			try NavSub := unset
			if IsSet(Controller) {
				try Controller.Close()
				catch as Err
					try LoggerError("HsEditor", "Retired browser cleanup failed: {1}.", Err.Message)
			}
			try g.Destroy()
		}
	}
	; Only now have all private cleanup callouts completed. A later session
	; cannot lend its authority to this failed opening's native fallback.
	return !(FactoryFailed && ResetForFallback && _HsEdWeb_FallbackCurrent(SessionEpoch + 1))
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

; Startup has no source/save authority: InitData captures the real opening
; image separately. These predicates only retain the exact native owner.
_HsEdWeb_OpeningCurrent(SessionEpoch) {
	global _HsEdWeb_Gui, _HsEdWeb_ResetDone
	return _HsEdWeb_SessionCurrent(SessionEpoch) && !_HsEdWeb_ResetDone && _HsEdWeb_Gui == 0
}

_HsEdWeb_StartupCurrent(SessionEpoch, Window) {
	global _HsEdWeb_Gui, _HsEdWeb_ResetDone
	return _HsEdWeb_SessionCurrent(SessionEpoch) && !_HsEdWeb_ResetDone && _HsEdWeb_Gui == Window
}

; Only the failed opening's own retired epoch can admit a native fallback.
_HsEdWeb_FallbackCurrent(SessionEpoch) {
	global _HsEdWeb_Gui, _HsEdWeb_ResetDone
	return _HsEdWeb_SessionCurrent(SessionEpoch) && _HsEdWeb_ResetDone && _HsEdWeb_Gui == 0
}

_HsEdWeb_SessionCall(SessionEpoch, Callback, Params*) {
	if !_HsEdWeb_SessionCurrent(SessionEpoch)
		return false
	Callback(Params*)
	return true
}

_HsEdWeb_PushInitData() {
	global _HsEdWeb_WebView, _HsEdWeb_OpeningSource, _HsEdWeb_SessionEpoch
	if !IsSet(_HsEdWeb_WebView) || !IsObject(_HsEdWeb_WebView)
		return false
	View := _HsEdWeb_WebView
	SessionEpoch := _HsEdWeb_SessionEpoch
	Js := _HsEdWeb_InitDataJs()
	OpeningSource := _HsEdWeb_OpeningSource
	if SessionEpoch != _HsEdWeb_SessionEpoch
		|| !IsSet(_HsEdWeb_WebView) || !IsObject(_HsEdWeb_WebView)
		|| ObjPtr(View) != ObjPtr(_HsEdWeb_WebView)
		|| !_PersonalTomlOpeningSessionIdentity(OpeningSource)
		return false
	return WebView_RunScriptAsync(View, Js, "HsEditor.init",
		_HsEdWeb_InitSourceSettled.Bind(OpeningSource))
}

_HsEdWeb_InitSourceSettled(OpeningSource, Succeeded) {
	if !_PersonalTomlOpeningSessionIdentity(OpeningSource)
		return
	OpeningSource["ready"] := (Succeeded is Integer) && Succeeded == 1
}

; Evaluates JS in the page using ExecuteScriptAsync FIRE-AND-FORGET (no .await()):
; the convenience ExecuteScript() is ExecuteScriptAsync().await(), and that nested
; await loop can wedge the AHK thread. The shared observer consumes completion
; without waiting for the result.
_HsEdWeb_Eval(Js) {
	global _HsEdWeb_WebView
	if !IsSet(_HsEdWeb_WebView)
		return
	WebView_RunScriptAsync(_HsEdWeb_WebView, Js, "HsEditor")
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

_HsEdWeb_DeferredSaveCompleted(OpeningSource, Added, CommitResult) {
	if !_PersonalTomlOpeningSessionCurrent(OpeningSource)
		return
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
	_HsEdWeb_EnableAdded(Added)
}

_HsEdWeb_Save(Data) {
	global _HsEdWeb_OpeningSource
	OpeningSource := _HsEdWeb_OpeningSource
	if !_PersonalTomlOpeningSessionCurrent(OpeningSource) {
		_HsEdWeb_ShowSaveFailure()
		return
	}
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
	; Sections this save creates are switched on once it has committed.
	Added := HS_PersonalSectionsAdded(ReadPersonalToml(true)["sections_order"], order)
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_DEFERRED
	CommitResult := PersonalTomlCommitAndReload(WriteData,
		0, 0, 0, 0, 0, 0, _HsEdWeb_DeferredSaveCompleted.Bind(OpeningSource, Added), 0, OpeningSource)
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
	if !_PersonalTomlOpeningSessionCurrent(OpeningSource)
		return
	try LoggerSuccess("HsEditor", "Personal hotstrings saved and reloaded.")
	_HsEdWeb_EnableAdded(Added)
}

; A section the user has just created is meant to be used: enable it.
_HsEdWeb_EnableAdded(Added) {
	if !Added.Length
		return true
	Reason := "refused"
	try {
		if HS_EnableNewPersonalSections(Added) {
			try LoggerSuccess("HsEditor", "{1} new personal section(s) enabled.", Added.Length)
			return true
		}
	} catch as Err
		Reason := Err.Message
	try LoggerError("HsEditor", "The {1} new personal section(s) could not be enabled ({2}); enable them from the tray.",
		Added.Length, Reason)
	try NotifierSend(t("editor.hotstrings.err_write"),
		Map("title", t("editor.hotstrings.save_error"), "level", "error"))
	return false
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
_HsEdWeb_Close(ExpectedWindow := unset) {
	global _HsEdWeb_Gui, _HsEdWeb_SessionEpoch
	PreviousCritical := Critical("On")
	try {
		Window := IsSet(ExpectedWindow) ? ExpectedWindow : _HsEdWeb_Gui
		if !IsObject(Window) || _HsEdWeb_Gui != Window
			return false
		SessionEpoch := _HsEdWeb_SessionEpoch
	} finally Critical(PreviousCritical)
	if !_HsEdWeb_Reset(SessionEpoch, Window)
		return false
	; Reset detached this exact GUI before any unsubscribe/Close could reenter.
	try Window.Destroy()
	return true
}




; ==============================================================
; ===================================
; ======= 4/ initData source ========
; ===================================
; ==============================================================

; Builds the window.initData({...}) call from the on-disk personal hotstrings.
; Pivots ReadPersonalToml's keyed sections Map + order Array into the frontend's
; ordered sections array, maps strict_case to the shared hidden strict flag,
; drops the AHK-only line_index field,
; and emits per-entry priority ONLY when set (absent == inherit), then attaches
; the seven UI prefs.
_HsEdWeb_InitDataJs() {
	global _HsEdWeb_OpeningSource, _HsEdWeb_SessionEpoch, _HsEdWeb_Gui
	SessionEpoch := _HsEdWeb_SessionEpoch
	Window := IsSet(_HsEdWeb_Gui) ? _HsEdWeb_Gui : 0
	OpeningSource := Map()
	data := ReadPersonalToml(false, OpeningSource)
	if SessionEpoch == _HsEdWeb_SessionEpoch
		&& Window is Gui && IsSet(_HsEdWeb_Gui) && _HsEdWeb_Gui is Gui
		&& ObjPtr(Window) == ObjPtr(_HsEdWeb_Gui) {
		OpeningSource["kind"] := "webview"
		OpeningSource["epoch"] := SessionEpoch
		OpeningSource["window"] := Window
		OpeningSource["ready"] := false
		_HsEdWeb_OpeningSource := OpeningSource
	}
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
				. ",is_case_sensitive_strict:" . ((e.Has("strict_case") && e["strict_case"]) ? "true" : "false")
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
_HsEdWeb_OnClose(Window, *) {
	return _HsEdWeb_Close(Window)
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. the JS "close"
; message and the native Gui "Close" event both firing for the same teardown) is
; a true no-op instead of touching the globals again.
_HsEdWeb_Reset(ExpectedEpoch := unset, ExpectedWindow := unset) {
	global _HsEdWeb_Gui, _HsEdWeb_Controller, _HsEdWeb_WebView, _HsEdWeb_MsgSub, _HsEdWeb_NavSub
	global _HsEdWeb_ResetDone, _HsEdWeb_SessionEpoch, _HsEdWeb_OpeningSource

	PreviousCritical := Critical("On")
	try {
		if IsSet(ExpectedEpoch) && ExpectedEpoch != _HsEdWeb_SessionEpoch
			return false
		if IsSet(ExpectedWindow) && _HsEdWeb_Gui != ExpectedWindow
			return false
		if _HsEdWeb_ResetDone
			return false
		; Retain every old reference before removing its globals. No COM release,
		; source-map finalization or native Destroy runs in this RAM transaction.
		RetiredWindow := _HsEdWeb_Gui
		RetiredOpeningSource := _HsEdWeb_OpeningSource
		if IsSet(_HsEdWeb_Controller)
			RetiredController := _HsEdWeb_Controller
		if IsSet(_HsEdWeb_WebView)
			RetiredView := _HsEdWeb_WebView
		if IsSet(_HsEdWeb_MsgSub)
			RetiredMsgSub := _HsEdWeb_MsgSub
		if IsSet(_HsEdWeb_NavSub)
			RetiredNavSub := _HsEdWeb_NavSub
		_HsEdWeb_ResetDone := true
		_HsEdWeb_SessionEpoch += 1
		_HsEdWeb_Gui := 0
		_HsEdWeb_OpeningSource := false
		_HsEdWeb_MsgSub := unset
		_HsEdWeb_NavSub := unset
		_HsEdWeb_Controller := unset
		_HsEdWeb_WebView := unset
	} finally Critical(PreviousCritical)

	; Release subscriptions while their exact controller is still alive. These
	; callouts may open another editor; no old frame writes globals afterward.
	try RetiredMsgSub := unset
	try RetiredNavSub := unset
	if IsSet(RetiredController)
		try RetiredController.Close()
	return true
}
