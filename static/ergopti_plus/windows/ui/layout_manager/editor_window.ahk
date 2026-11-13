; ui/layout_manager/editor_window.ahk

; ==============================================================================
; MODULE: Layout Editor Window (WebView2 host)
; DESCRIPTION:
; Hosts the unified layout editor alone in its own window
; (_shared/ui/layout_editor_window), as macOS and Linux do: the menu's « Create
; or edit a layout… » and the layout manager's « Layout editor » button open
; it. The editor's actions are answered by the layout manager's own handler
; (LayoutManager_HandleEditorAction in init.ahk), so both windows apply the
; same rules.
;
; FEATURES & RATIONALE:
; 1. WebViewHost singleton under the manifest id layout_editor_window: a
;    second request brings the open editor to the front and keeps its unsaved
;    work.
; 2. On ready the page receives initData (its strings, the platform, the
;    host's capabilities), then the last saved source with the editor's
;    strings (sourceData), since this host does not seed window._i18n_strings.
; 3. An install or an emulation from the editor refreshes an open layout
;    manager window, which lists the composed layout.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ State and actions =======
; ====================================
; ====================================

; The page's id in _shared/ui/apps.manifest.json.
global LAYOUT_EDITOR_WINDOW_APP_ID := "layout_editor_window"

; The only actions the page may send (the page declares the same list;
; tools/test/test-layout-manager-page.cjs pins both).
global LAYOUT_EDITOR_WINDOW_ACTIONS := Map("ready", true, "close", true,
	"composer_open", true, "composer_save", true, "composer_emulate", true,
	"source_open", true, "source_save", true, "source_pick", true, "nav_save", true)





; ==========================
; ==========================
; ======= 2/ Actions =======
; ==========================
; ==========================

/**
 * The translated strings the page shows itself (strings.json next to the page).
 * @returns {Map} Key -> translation.
 */
LayoutEditorWindow_Strings() {
	global _SharedDir
	Path := _SharedDir . "\ui\layout_editor_window\strings.json"
	Text := FSRead(Path)
	if !(Text is String)
		throw Error("Cannot read " . Path)
	Strings := Map()
	for Key in JsonParse(Text)["keys"]
		Strings[Key] := t(Key)
	return Strings
}

/**
 * Handles one message of the layout editor window.
 * @param {Map} Payload - Decoded message.
 * @param {Map} Deps - "push" (FunctionName, Payload), "local_dir", "close" and
 *   the ports LayoutManager_HandleEditorAction takes.
 * @returns {Boolean} Whether the message was accepted.
 */
LayoutEditorWindow_HandleMessage(Payload, Deps) {
	global LAYOUT_EDITOR_WINDOW_ACTIONS
	if !(Payload is Map) || !(Payload.Get("action", 0) is String)
			|| !LAYOUT_EDITOR_WINDOW_ACTIONS.Has(Payload["action"]) {
		LoggerWarn("LayoutEditorWindow", "Refused a layout editor message outside the allowlist.")
		return false
	}
	Action := Payload["action"]
	if (Action == "ready") {
		Deps["push"].Call("initData", Map("strings", LayoutEditorWindow_Strings(),
			"state", LayoutManager_PageState(Deps["local_dir"]),
			"source_editor", LayMgrJsonBool_Of(true), "source_pick", LayMgrJsonBool_Of(false),
			"nav_apply", LayMgrJsonBool_Of(true), "emulate", LayMgrJsonBool_Of(true)))
		return LayoutManager_HandleEditorAction("source_open", Map("action", "source_open"), Deps)
	}
	if (Action == "close") {
		Deps["close"].Call()
		return true
	}
	return LayoutManager_HandleEditorAction(Action, Payload, Deps)
}





; ===================================
; ===================================
; ======= 3/ Window lifecycle =======
; ===================================
; ===================================

/**
 * Opens the layout editor window, or brings the open one to the front.
 * @returns {Boolean} Whether the window is shown.
 */
LayoutEditorWindow_Open(*) {
	global LAYOUT_EDITOR_WINDOW_APP_ID
	Host := WebViewHost.TryOpen(LAYOUT_EDITOR_WINDOW_APP_ID, Map(
		"Title", t("layout_editor.title"),
		"OnReady", _LayEdWin_OnReady,
		"OnMessage", _LayEdWin_OnMessage))
	if !Host {
		LoggerError("LayoutEditorWindow", "The layout editor could not open: WebView2 is unavailable.")
		return false
	}
	return true
}

; The ports of one window: pushes go to that exact host only.
_LayEdWin_Deps(Host) {
	global _ConfigDir
	return Map(
		"push", _LayEdWin_Push.Bind(Host),
		"local_dir", LayoutRegistry_LocalDir(_ConfigDir),
		"close", () => Host.Close()
	)
}

; Evaluates window.<Name>(Payload) in the host; an install or an emulation
; also refreshes an open layout manager, which lists the composed layout.
_LayEdWin_Push(Host, Name, Payload) {
	global _LayMgrWeb_PresentationDeps
	Host.Eval("if(window." . Name . ")window." . Name . "(" . _LayMgrWeb_Json(Payload) . ")")
	if (Name == "composerResult") && (_LayMgrWeb_PresentationDeps is Map)
		_LayMgrWeb_PushState(_LayMgrWeb_PresentationDeps)
	return true
}

; Both native navigation and the page's own ready reach WebViewHost, which
; calls this once per page.
_LayEdWin_OnReady(Host) {
	try LayoutEditorWindow_HandleMessage(Map("action", "ready"), _LayEdWin_Deps(Host))
	catch as Err
		LoggerError("LayoutEditorWindow", "The layout editor could not be initialized: {1}.", Err.Message)
}

; The page's own ready is already answered by _LayEdWin_OnReady.
_LayEdWin_OnMessage(Host, Payload) {
	if Payload.Get("action", "") == "ready"
		return
	LayoutEditorWindow_HandleMessage(Payload, _LayEdWin_Deps(Host))
}
