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
; 1. WebViewHost singleton under the manifest id layout_editor_window (named in
;    the one TryOpen call, which reads its size from apps.manifest.json): a
;    second request brings the open editor to the front and keeps its unsaved
;    work.
; 2. On ready the page receives initData (its strings, the platform, the
;    host's capabilities), then the last saved source with the editor's
;    strings (sourceData), since this host does not seed window._i18n_strings.
; 3. An install or an emulation from the editor refreshes an open layout
;    manager window, which lists the composed layout.
; 4. The editor's downloads (XKB archive, KLC, DLL images, macOS bundle) are
;    built in the page with the export data the app ships; source_export hands
;    their bytes to SourceStore_Export, which writes them to the Downloads folder.
; 5. Ergopti Studio reads the user's own typing (keystats_ngrams), only when the
;    user asks: a keystats worker projects the local store read only
;    (KLPF_RequestStudio, mode "studio") and its JSON is pushed to this window
;    alone as keystatsNgrams; an absent store or a failed read answers with the
;    refusal codes of _shared/metrics/data/studio_ngrams.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ State and actions =======
; ====================================
; ====================================

; The only actions the page may send (the page declares the same list;
; tools/test/test-layout-manager-page.cjs pins both).
; The last complete Ergopti Studio projection: Map("stamp", "json"), or 0.
global _LayEdWin_StudioCache := 0

global LAYOUT_EDITOR_WINDOW_ACTIONS := Map("ready", true, "close", true,
	"composer_open", true, "composer_save", true, "composer_emulate", true,
	"source_open", true, "source_save", true, "source_pick", true, "source_export", true,
	"nav_save", true, "keystats_ngrams", true, "open_link", true,
	"studio_layouts", true, "studio_layout_save", true, "studio_layout_remove", true, "studio_corpus", true,
	"studio_profile_load", true, "studio_profile_save", true, "studio_workspace_load", true,
	"studio_workspace_save", true, "lua_export", true)





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
			"nav_apply", LayMgrJsonBool_Of(true), "emulate", LayMgrJsonBool_Of(true),
			"source_export", LayMgrJsonBool_Of(true), "keystats", LayMgrJsonBool_Of(true),
			"studio_store", LayMgrJsonBool_Of(true), "studio_workspace", LayMgrJsonBool_Of(true)))
		return LayoutManager_HandleEditorAction("source_open", Map("action", "source_open"), Deps)
	}
	if (Action == "close") {
		Deps["close"].Call()
		return true
	}
	if (Action == "keystats_ngrams")
		return LayoutEditorWindow_ReadKeystats(Deps)
	if (Action == "studio_layouts" || Action == "studio_layout_save" || Action == "studio_layout_remove")
		return LayoutEditorWindow_StudioLayouts(Action, Payload, Deps)
	if (Action == "studio_corpus")
		return LayoutEditorWindow_StudioCorpus(Payload, Deps)
	if (Action == "studio_profile_load" || Action == "studio_profile_save")
		return LayoutEditorWindow_StudioProfile(Action, Payload, Deps)
	if (Action == "studio_workspace_load" || Action == "studio_workspace_save")
		return LayoutEditorWindow_StudioWorkspace(Action, Payload, Deps)
	; The macOS and Linux hosts run the downloads' export adapter with their own
	; Lua (lua_export); this host has none and offers no lua_export in initData:
	; its WebView2 pages carry no content policy that refuses the page's fengari
	; VM, so the page builds XKB and KLC itself and never asks.
	if (Action == "lua_export") {
		LoggerWarn("LayoutEditorWindow", "Refused an export step: the Windows host runs no Lua; the page builds its downloads.")
		return false
	}
	; The Studio's analysis panels open their « i » links in the system browser:
	; an https URL only.
	if (Action == "open_link") {
		Url := Payload.Get("url", "")
		if !(Url is String) || !RegExMatch(Url, "^https://\S+$") {
			LoggerWarn("LayoutEditorWindow", "Refused a Studio link that is not an https URL.")
			return false
		}
		return Deps["open_url"].Call(Url)
	}
	return LayoutManager_HandleEditorAction(Action, Payload, Deps)
}

/**
 * Reads Ergopti Studio's « My typing » counts for this window. The keystats
 * folder is never written: a worker projects it read only, and its staged JSON
 * goes to this window alone.
 * @param {Map} Deps - "metrics_dir", "stamp" (MetricsDir), "request_studio"
 *   (MetricsDir, OnTerminal), "push_raw" (FunctionName, Json) and "read_stage" (Path).
 * @returns {Boolean} Whether the read was accepted.
 */
LayoutEditorWindow_ReadKeystats(Deps) {
	global _LayEdWin_StudioCache
	Codes := KLR_StudioContract()["codes"]
	MetricsDir := Deps["metrics_dir"]
	if (MetricsDir == "") || !DirExist(MetricsDir) {
		_LayEdWin_StudioCache := 0
		_LayEdWin_PushRefusal(Deps, Codes["absent"])
		return true
	}
	; An unchanged keystats folder answers from the last projection, at once.
	Stamp := Deps["stamp"].Call(MetricsDir)
	if (Stamp != "") && (_LayEdWin_StudioCache is Map) && (_LayEdWin_StudioCache["stamp"] == Stamp) {
		Deps["push_raw"].Call("keystatsNgrams", '{"ok":true,"ngrams":' . _LayEdWin_StudioCache["json"] . "}")
		return true
	}
	return Deps["request_studio"].Call(MetricsDir, _LayEdWin_OnStudioTerminal.Bind(Deps, Codes, Stamp))
}

; The worker's one terminal: its staged JSON, read before the stage is deleted.
_LayEdWin_OnStudioTerminal(Deps, Codes, Stamp, Status, Stage) {
	global _LayEdWin_StudioCache
	if (Status != "ok") || (Stage == "") {
		LoggerWarn("LayoutEditorWindow", "Ergopti Studio could not read the typing statistics ({1}).", Status)
		_LayEdWin_PushRefusal(Deps, Codes["unreadable"])
		return
	}
	Json := Deps["read_stage"].Call(Stage)
	if !(Json is String) || (SubStr(Json, 1, 1) != "{") {
		LoggerError("LayoutEditorWindow", "The Ergopti Studio projection staged no JSON object.")
		_LayEdWin_PushRefusal(Deps, Codes["unreadable"])
		return
	}
	_LayEdWin_StudioCache := Stamp != "" ? Map("stamp", Stamp, "json", Json) : 0
	Deps["push_raw"].Call("keystatsNgrams", '{"ok":true,"ngrams":' . Json . "}")
}

/**
 * Answers one of the Studio's personal-layout messages (the Comparer's
 * LAYOUT_ANALYSIS_HOST.store), through StudioStore_* (source_store.ahk).
 * @param {String} Action - studio_layouts, studio_layout_save or studio_layout_remove.
 * @param {Map} Payload - The message; request is the page's request number.
 * @param {Map} Deps - "push" (FunctionName, Payload),
 *   "config_dir" and optionally "studio_ports" (the store's file ports).
 * @returns {Boolean} Whether the message was accepted.
 */
LayoutEditorWindow_StudioLayouts(Action, Payload, Deps) {
	Request := Payload.Get("request", 0)
	if !(Request is Integer) || Request < 1 {
		LoggerWarn("LayoutEditorWindow", "Refused an Ergopti Studio layout message without its request number.")
		return false
	}
	Settings := StudioStore_SharedSettings()
	Ports := Deps.Get("studio_ports", 0)
	if (Action == "studio_layouts") {
		Result := StudioStore_List(Settings, Deps["config_dir"], Ports)
		Answer := Map("request", Request, "ok", LayMgrJsonBool_Of(Result["ok"]))
		if Result["ok"]
			Answer["layouts"] := Result["layouts"]
		else
			Answer["code"] := Result["code"], Answer["detail"] := Result["detail"]
		return Deps["push"].Call("studioLayouts", Answer)
	}
	Result := (Action == "studio_layout_save")
		? StudioStore_Save(Settings, Deps["config_dir"], Payload, Ports)
		: StudioStore_Remove(Settings, Deps["config_dir"], Payload, Ports)
	Answer := Map("request", Request, "ok", LayMgrJsonBool_Of(Result["ok"]), "detail", Result.Get("detail", ""))
	if !Result["ok"]
		Answer["code"] := Result["code"]
	return Deps["push"].Call("studioLayoutResult", Answer)
}

/**
 * Runs one built-in corpus's generated tables in the Studio page, then
 * answers studioCorpus (the Comparer's LAYOUT_ANALYSIS_HOST.loadCorpus).
 * @param {Map} Payload - { request, id }.
 * @param {Map} Deps - "push", "run_script" (Text), "shared_dir" and optionally "studio_ports".
 * @returns {Boolean} Whether the message was accepted.
 */
LayoutEditorWindow_StudioCorpus(Payload, Deps) {
	Request := Payload.Get("request", 0)
	if !(Request is Integer) || Request < 1 {
		LoggerWarn("LayoutEditorWindow", "Refused an Ergopti Studio corpus request without its request number.")
		return false
	}
	Settings := StudioStore_SharedSettings()
	Result := StudioStore_Corpus(Settings, Deps["shared_dir"], Payload, Deps.Get("studio_ports", 0))
	if !Result["ok"]
		return Deps["push"].Call("studioCorpus", Map("request", Request, "ok", LayMgrJsonBool_Of(false),
			"code", Result["code"], "detail", Result["detail"]))
	; WebView2 runs the tables before the push that follows.
	Deps["run_script"].Call(Result["text"])
	return Deps["push"].Call("studioCorpus", Map("request", Request, "ok", LayMgrJsonBool_Of(true)))
}

/**
 * Answers the Comparer's fingering profile messages (store.loadProfile and
 * store.saveProfile), through StudioStore_Profile* (source_store.ahk).
 * @param {String} Action - studio_profile_load or studio_profile_save.
 * @param {Map} Payload - { request } and, to save, { text } or { reset: true }.
 * @param {Map} Deps - "push", "config_dir" and optionally "studio_ports".
 * @returns {Boolean} Whether the message was accepted.
 */
LayoutEditorWindow_StudioProfile(Action, Payload, Deps) {
	Request := Payload.Get("request", 0)
	if !(Request is Integer) || Request < 1 {
		LoggerWarn("LayoutEditorWindow", "Refused an Ergopti Studio profile message without its request number.")
		return false
	}
	Settings := StudioStore_SharedSettings()
	Ports := Deps.Get("studio_ports", 0)
	if (Action == "studio_profile_load") {
		Result := StudioStore_ProfileLoad(Settings, Deps["config_dir"], Ports)
		Answer := Map("request", Request, "ok", LayMgrJsonBool_Of(Result["ok"]))
		if !Result["ok"]
			Answer["code"] := Result["code"], Answer["detail"] := Result["detail"]
		else if (Result["profile"] != "")
			Answer["profile"] := Result["profile"]
		return Deps["push"].Call("studioProfile", Answer)
	}
	Result := StudioStore_ProfileSave(Settings, Deps["config_dir"], Payload, Ports)
	Answer := Map("request", Request, "ok", LayMgrJsonBool_Of(Result["ok"]), "detail", Result["detail"])
	if !Result["ok"]
		Answer["code"] := Result["code"]
	return Deps["push"].Call("studioProfileResult", Answer)
}

/**
 * Answers the editor's workspace messages (its tabs and their unsaved edits,
 * layout_editor/workspace.js), through StudioStore_Workspace* (source_store.ahk).
 * @param {String} Action - studio_workspace_load or studio_workspace_save.
 * @param {Map} Payload - { request } and, to save, { text }.
 * @param {Map} Deps - "push", "config_dir" and optionally "studio_ports".
 * @returns {Boolean} Whether the message was accepted.
 */
LayoutEditorWindow_StudioWorkspace(Action, Payload, Deps) {
	Request := Payload.Get("request", 0)
	if !(Request is Integer) || Request < 1 {
		LoggerWarn("LayoutEditorWindow", "Refused an Ergopti Studio workspace message without its request number.")
		return false
	}
	Settings := StudioStore_SharedSettings()
	Ports := Deps.Get("studio_ports", 0)
	if (Action == "studio_workspace_load") {
		Result := StudioStore_WorkspaceLoad(Settings, Deps["config_dir"], Ports)
		Answer := Map("request", Request, "ok", LayMgrJsonBool_Of(Result["ok"]))
		if !Result["ok"]
			Answer["code"] := Result["code"], Answer["detail"] := Result["detail"]
		else if (Result["workspace"] != "")
			Answer["workspace"] := Result["workspace"]
		return Deps["push"].Call("studioWorkspace", Answer)
	}
	; A workspace is never reset from the page: only a text is saved.
	Result := StudioStore_WorkspaceSave(Settings, Deps["config_dir"], Map("text", Payload.Get("text", 0)), Ports)
	Answer := Map("request", Request, "ok", LayMgrJsonBool_Of(Result["ok"]), "detail", Result["detail"])
	if !Result["ok"]
		Answer["code"] := Result["code"]
	return Deps["push"].Call("studioWorkspaceResult", Answer)
}

_LayEdWin_PushRefusal(Deps, Code) {
	Deps["push_raw"].Call("keystatsNgrams", '{"ok":false,"code":' . JsonStringLiteral(Code) . "}")
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
	Host := WebViewHost.TryOpen("layout_editor_window", Map(
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
	global _ConfigDir, _SharedDir
	return Map(
		"push", _LayEdWin_Push.Bind(Host),
		"local_dir", LayoutRegistry_LocalDir(_ConfigDir),
		"close", () => Host.Close(),
		"metrics_dir", KL_MetricsDirFor(_ConfigDir),
		"stamp", KLR_StudioStoreStamp,
		"request_studio", KLPF_RequestStudio,
		"push_raw", _LayEdWin_PushRaw.Bind(Host),
		"read_stage", FSRead,
		"open_url", (Url) => ExternalUrl_OpenHttp(Url),
		"config_dir", _ConfigDir,
		"shared_dir", _SharedDir,
		"run_script", (Text) => Host.Eval(Text)
	)
}

; Evaluates window.<Name>(<Json>) with an already encoded JSON object: the
; Studio's counts arrive encoded by SQLite and are never re-parsed here.
_LayEdWin_PushRaw(Host, Name, Json) {
	Host.Eval("if(window." . Name . ")window." . Name . "(" . Json . ")")
	return true
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
